program poolsafe;

{ VDB - VDbPool sahiplik ve kapasite sozlesmesi kapisi (R2-B-5 / R2-B-6)

  Kanitlananlar:
    1) Tek surec modu: normal Acquire/Release, FOut 1:1.
    2) Cift Release: ayni ornek ikinci kez Release edilince
       ecInvalidArgument; cift free / sayac bozulmasi yok.
    3) Sahiplenilmeyen ornek: havuzun uretmedigi TVSql Release
       edilince ecInvalidArgument; havuzun canli kaynaklari korunur.
    4) Baska thread'in ornegi: ecInvalidArgument; kaynaklar yanlis
       thread'de birakilmaz, sahibi Release edince temizlenir.
    5) FSize siniri (tek surec): kapasite dolunca Acquire ecPoolTimeout;
       bir Release sonrasi yeni Acquire basarili. Paralel iscilerde
       es zamanli disaridaki ornek sayisi FSize'i asmaz.
    6) Hata yolu: Close sonrasi Acquire ecPoolClosed.
    7) Cok surec (CreateXProc) modu: ayni senaryolar + es zamanli
       Acquire/Release sonrasi slot/mutex/motor sayaclari sifir.

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: poolsafe <gecici_dizin>
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, SyncObjs,
  VDbErr, VDbCore, VDbTable, VDbSql, VDbPool;

type
  { Havuzdan Acquire edip bekleyen, sonra kendi thread'inde Release
    eden isci. Yanlis-thread ve es zamanli erisim senaryolarinda
    kullanilir. }
  TPoolWorker = class(TThread)
  public
    Pool: TVDbPool;
    Iterations: Integer;
    Sql: TVSql;
    MaxSeen: Integer;
    Failed: Boolean;
    Msg: string;
    Acquired: TEvent;
    Go: TEvent;
    Done: TEvent;
    constructor Create(APool: TVDbPool; AIterations: Integer);
    destructor Destroy; override;
    procedure Execute; override;
  end;

var
  gPass, gFail: Int64;
  gDir: string;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

constructor TPoolWorker.Create(APool: TVDbPool; AIterations: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Pool := APool;
  Iterations := AIterations;
  Sql := nil;
  MaxSeen := 0;
  Failed := False;
  Msg := '';
  Acquired := TEvent.Create(nil, True, False, '');
  Go := TEvent.Create(nil, True, False, '');
  Done := TEvent.Create(nil, True, False, '');
end;

destructor TPoolWorker.Destroy;
begin
  Acquired.Free;
  Go.Free;
  Done.Free;
  inherited;
end;

procedure TPoolWorker.Execute;
var
  i, N: Integer;
  Q: TVSql;
begin
  try
    if Iterations = 1 then
    begin
      { Tek tur: Acquire et, ana thread'in Go'sunu bekle, Release et. }
      Sql := Pool.Acquire;
      N := Pool.ActiveCount;
      if N > MaxSeen then MaxSeen := N;
      Acquired.SetEvent;
      Go.WaitFor(10000);
      try
        Pool.Release(Sql);
        Sql := nil;
      except
        on E: Exception do
        begin
          Failed := True;
          Msg := 'Release: ' + E.ClassName + ': ' + E.Message;
        end;
      end;
      Done.SetEvent;
      Exit;
    end;

    for i := 1 to Iterations do
    begin
      Q := Pool.Acquire;
      try
        N := Pool.ActiveCount;
        if N > MaxSeen then MaxSeen := N;
        Sleep(1);
      finally
        Pool.Release(Q);
      end;
    end;
  except
    on E: Exception do
    begin
      Failed := True;
      Msg := E.ClassName + ': ' + E.Message;
      { Ana thread sonsuz beklemesin. }
      Acquired.SetEvent;
    end;
  end;
  Done.SetEvent;
end;

{ Acquire'in EVDbException firlatip firlatmadigini dondurur. }
function ExpectAcquireError(Pool: TVDbPool; out Code: TVDbErrorCode;
  out Msg: string): Boolean;
var
  Q: TVSql;
begin
  Result := False;
  Code := ecNone;
  Msg := '';
  try
    Q := Pool.Acquire;
    Pool.Release(Q);
    Msg := 'beklenmeyen basari';
  except
    on E: EVDbException do
    begin
      Code := E.ErrorCode;
      Msg := E.Message;
      Result := True;
    end;
    on E: Exception do
    begin
      Code := ecGeneral;
      Msg := E.ClassName + ': ' + E.Message;
      Result := True;
    end;
  end;
end;

{ Release'in EVDbException firlatip firlatmadigini dondurur. }
function ExpectReleaseError(Pool: TVDbPool; Sql: TVSql;
  out Code: TVDbErrorCode; out Msg: string): Boolean;
begin
  Result := False;
  Code := ecNone;
  Msg := '';
  try
    Pool.Release(Sql);
  except
    on E: EVDbException do
    begin
      Code := E.ErrorCode;
      Msg := E.Message;
      Result := True;
    end;
    on E: Exception do
    begin
      Code := ecGeneral;
      Msg := E.ClassName + ': ' + E.Message;
      Result := True;
    end;
  end;
end;

procedure CheckActive(Pool: TVDbPool; Want: Integer; const Ctx: string);
begin
  if Pool.ActiveCount = Want then
    Ok(Ctx + ': ActiveCount=' + IntToStr(Want))
  else
    Fail(Ctx + ': ActiveCount=' + IntToStr(Pool.ActiveCount) +
      ' beklenen=' + IntToStr(Want));
end;

procedure CheckXProcClean(Pool: TVDbPool; const Ctx: string);
begin
  if (Pool.ActiveCount = 0) and (Pool.SharedActiveCount = 0) and
     (Pool.SlotId = -1) then
    Ok(Ctx + ': temiz (0/0/-1)')
  else
    Fail(Ctx + ': sizinti ActiveCount=' + IntToStr(Pool.ActiveCount) +
      ' Shared=' + IntToStr(Pool.SharedActiveCount) +
      ' Slot=' + IntToStr(Pool.SlotId));
end;

{ Ortak senaryolar. AMode: 'tek' veya 'cok'. }
procedure TestOwnershipScenarios(Pool: TVDbPool; const AMode: string);
var
  Q: TVSql;
  W: TPoolWorker;
  Code: TVDbErrorCode;
  Msg: string;
begin
  WriteLn('-- ', AMode, ' surec: sahiplik senaryolari');

  { 1) normal }
  Q := Pool.Acquire;
  if Q <> nil then Ok('Acquire ornek verdi') else Fail('Acquire nil');
  CheckActive(Pool, 1, 'Acquire sonrasi');
  Pool.Release(Q);
  CheckActive(Pool, 0, 'Release sonrasi');

  if AMode = 'cok' then CheckXProcClean(Pool, 'normal tur');

  { 2) cift Release }
  Q := Pool.Acquire;
  Pool.Release(Q);
  if ExpectReleaseError(Pool, Q, Code, Msg) and
     (Code = ecInvalidArgument) then
    Ok('cift Release ecInvalidArgument ile reddedildi')
  else
    Fail('cift Release reddedilmedi (code=' + VDbErrorName(Code) +
      ' msg=' + Msg + ')');
  CheckActive(Pool, 0, 'cift Release sonrasi');
  if AMode = 'cok' then CheckXProcClean(Pool, 'cift Release sonrasi');

  { 3) sahipsiz Release(nil) }
  Pool.Release(nil);
  CheckActive(Pool, 0, 'Release(nil) sonrasi');
  if AMode = 'cok' then CheckXProcClean(Pool, 'Release(nil) sonrasi');

  { 4) baska thread'in ornegi }
  W := TPoolWorker.Create(Pool, 1);
  try
    W.Start;
    W.Acquired.WaitFor(10000);
    if W.Failed then
      Fail('worker Acquire hatasi: ' + W.Msg)
    else if W.Sql <> nil then
      Ok('worker Acquire ornek verdi')
    else
      Fail('worker nil');
    CheckActive(Pool, 1, 'worker Acquire sonrasi');

    if ExpectReleaseError(Pool, W.Sql, Code, Msg) and
       (Code = ecInvalidArgument) then
      Ok('baska thread ecInvalidArgument ile reddedildi')
    else
      Fail('baska thread reddedilmedi (code=' + VDbErrorName(Code) +
        ' msg=' + Msg + ')');
    CheckActive(Pool, 1, 'yanlis thread Release sonrasi');

    W.Go.SetEvent;
    W.Done.WaitFor(10000);
    if W.Failed then
      Fail('worker Release hatasi: ' + W.Msg)
    else
      Ok('sahip thread Release etti');
    CheckActive(Pool, 0, 'sahip Release sonrasi');
    if AMode = 'cok' then CheckXProcClean(Pool, 'sahip Release sonrasi');
  finally
    W.Go.SetEvent;
    W.WaitFor;
    W.Free;
  end;
end;

procedure TestSizeLimit(Pool: TVDbPool);
var
  Q1, Q2, Q3: TVSql;
  Code: TVDbErrorCode;
  Msg: string;
begin
  WriteLn('-- tek surec: FSize siniri');
  Q1 := Pool.Acquire;
  Q2 := Pool.Acquire;
  CheckActive(Pool, 2, 'iki ornek');

  if ExpectAcquireError(Pool, Code, Msg) and (Code = ecPoolTimeout) then
    Ok('kapasite doluyken Acquire ecPoolTimeout verdi')
  else
    Fail('kapasite siniri uygulanmadi (code=' + VDbErrorName(Code) +
      ' msg=' + Msg + ')');
  CheckActive(Pool, 2, 'basarisiz Acquire sonrasi');

  Pool.Release(Q1);
  CheckActive(Pool, 1, 'bir Release sonrasi');
  Q3 := Pool.Acquire;
  if Q3 <> nil then Ok('bosalan kapasiteye Acquire basarili')
  else Fail('bosalan kapasiteye Acquire nil');
  CheckActive(Pool, 2, 'yeniden dolan kapasite');

  Pool.Release(Q2);
  Pool.Release(Q3);
  CheckActive(Pool, 0, 'FSize testi sonrasi');
end;

procedure TestConcurrent(Pool: TVDbPool; AThreads, AIterations, ASize: Integer;
  const AMode: string);
var
  W: array of TPoolWorker;
  i, Bad: Integer;
begin
  WriteLn('-- ', AMode, ' surec: es zamanli Acquire/Release (',
    AThreads, ' thread x ', AIterations, ')');
  SetLength(W, AThreads);
  for i := 0 to AThreads - 1 do
    W[i] := TPoolWorker.Create(Pool, AIterations);
  try
    for i := 0 to AThreads - 1 do
      W[i].Start;
    Bad := 0;
    for i := 0 to AThreads - 1 do
    begin
      W[i].WaitFor;
      if W[i].Failed then
      begin
        Inc(Bad);
        Fail('isci ' + IntToStr(i) + ' hatasi: ' + W[i].Msg);
      end;
      if W[i].MaxSeen > ASize then
      begin
        Inc(Bad);
        Fail('isci ' + IntToStr(i) + ' FSize asti: gorulen=' +
          IntToStr(W[i].MaxSeen));
      end;
    end;
    if Bad = 0 then
      Ok('isciler hatasiz, es zamanli ornek sayisi FSize icinde');
  finally
    for i := 0 to AThreads - 1 do
    begin
      W[i].Go.SetEvent;
      W[i].Free;
    end;
  end;
  CheckActive(Pool, 0, 'es zamanli tur sonrasi');
  if AMode = 'cok' then CheckXProcClean(Pool, 'es zamanli tur sonrasi');
end;

procedure TestSingleProcess;
var
  kv: TVDb;
  tb: TVTableDb;
  dir: string;
  P: TVDbPool;
  Code: TVDbErrorCode;
  Msg: string;
begin
  WriteLn('== TEK SUREC MODU ==');
  dir := gDir + 'single';
  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  kv.Open(dir);
  tb.Open(dir);
  P := TVDbPool.Create(tb, 2, 300);
  try
    TestOwnershipScenarios(P, 'tek');
    TestSizeLimit(P);
    TestConcurrent(P, 3, 15, 2, 'tek');

    { 6) hata yolu: kapanmis havuz }
    P.Close;
    if ExpectAcquireError(P, Code, Msg) and (Code = ecPoolClosed) then
      Ok('kapali havuzda Acquire ecPoolClosed verdi')
    else
      Fail('kapali havuz reddetmedi (code=' + VDbErrorName(Code) +
        ' msg=' + Msg + ')');
    CheckActive(P, 0, 'kapanis sonrasi');
  finally
    P.Free;
    tb.Close;
    tb.Free;
    kv.Close;
    kv.Free;
  end;
end;

procedure TestXProc;
var
  dir, fdir, U: string;
  P: TVDbPool;
  fkv: TVDb;
  ftb: TVTableDb;
  Foreign: TVSql;
  Code: TVDbErrorCode;
  Msg: string;
begin
  WriteLn('== COK SUREC MODU (CreateXProc) ==');
  U := IntToHex(Random(MaxInt), 8) + IntToHex(Random(MaxInt), 8);
  dir := gDir + 'xproc_' + U;
  fdir := gDir + 'foreign_' + U;
  ForceDirectories(dir);
  ForceDirectories(fdir);

  P := TVDbPool.CreateXProc('POOLSAFE_' + U, dir, 2, 1500);
  try
    TestOwnershipScenarios(P, 'cok');

    { Yabanci ornek: ayri motor, havuzun uretmedigi TVSql. }
    fkv := TVDb.Create;
    ftb := TVTableDb.Create(fkv);
    try
      fkv.Open(fdir);
      ftb.Open(fdir);
      Foreign := TVSql.Create(ftb);
      try
        if ExpectReleaseError(P, Foreign, Code, Msg) and
           (Code = ecInvalidArgument) then
          Ok('yabanci ornek ecInvalidArgument ile reddedildi')
        else
          Fail('yabanci ornek reddedilmedi (code=' + VDbErrorName(Code) +
            ' msg=' + Msg + ')');
        CheckXProcClean(P, 'yabanci Release sonrasi');
      finally
        Foreign.Free;
      end;
    finally
      ftb.Close;
      ftb.Free;
      fkv.Close;
      fkv.Free;
    end;

    TestConcurrent(P, 2, 5, 2, 'cok');
  finally
    P.Free;
  end;
end;

var
  U: string;
begin
  Randomize;
  if ParamStr(1) = '' then
  begin
    WriteLn('kullanim: poolsafe <gecici_dizin>');
    Halt(2);
  end;
  U := IntToHex(Random(MaxInt), 8);
  gDir := IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));
  ForceDirectories(gDir);

  WriteLn('VDbPool sahiplik ve kapasite kapisi');
  TestSingleProcess;
  TestXProc;

  WriteLn('===============================');
  WriteLn('SONUC: gecen=', gPass, ' kalan=', gFail);
  if gFail > 0 then
  begin
    WriteLn('HAVUZ SAHIPLIK SOZLESMESI BASARISIZ');
    Halt(1);
  end;
  WriteLn('TEMIZ');
  WriteLn('HAVUZ SAHIPLIK SOZLESMESI DOGRULANDI');
end.
