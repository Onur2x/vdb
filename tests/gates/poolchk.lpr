program poolchk;

{ VDB - VDbPool Release hata yolu kapisi (R2-B-YENI-1)

  Kanitlananlar (cok-surec / CreateXProc modu, SHM slotu gozlenir):
    1) Normal Acquire/Release: ornek, SHM slotu ve ActiveCount 1:1.
    2) Release(nil): sahipsiz cagri hata vermez, slot sizmaz.
    3) Havuzun uretmedigi ornek: ecInvalidArgument; canli ornek varken
       motor/mutex/slot onun altindan cekilmez, sonraki dogru Release
       her seyi temizler.
    4) Baska thread'in ornegi: ecInvalidArgument; kaynaklar yanlis
       thread'de birakilmaz; sahibi Release edince 1:1 kapanir.
    5) Tekrarlanan Acquire/Release dongusu: FOut, SHM ActiveCount ve
       SlotId her turda sifira doner (sizinti yok).

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: poolchk [gecici_dizin]
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, SyncObjs,
  VDbErr, VDbCore, VDbTable, VDbSql, VDbPool;

type
  TPoolWorker = class(TThread)
  public
    Pool: TVDbPool;
    Sql: TVSql;
    Acquired: TEvent;
    Go: TEvent;
    Done: TEvent;
    Failed: Boolean;
    Msg: string;
    constructor Create(APool: TVDbPool);
    destructor Destroy; override;
    procedure Execute; override;
  end;

var
  gPass, gFail: Int64;
  gPool: TVDbPool;
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

constructor TPoolWorker.Create(APool: TVDbPool);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Pool := APool;
  Sql := nil;
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
begin
  try
    Sql := Pool.Acquire;
  except
    on E: Exception do
    begin
      Failed := True;
      Msg := 'Acquire: ' + E.ClassName + ': ' + E.Message;
      Acquired.SetEvent;
      Done.SetEvent;
      Exit;
    end;
  end;
  Acquired.SetEvent;
  Go.WaitFor(10000);
  try
    Pool.Release(Sql);
  except
    on E: Exception do
    begin
      Failed := True;
      Msg := 'Release: ' + E.ClassName + ': ' + E.Message;
    end;
  end;
  Done.SetEvent;
end;

function StateStr: string;
begin
  Result := Format('ActiveCount=%d SharedActiveCount=%d SlotId=%d',
    [gPool.ActiveCount, gPool.SharedActiveCount, gPool.SlotId]);
end;

procedure CheckClean(const Ctx: string);
begin
  if (gPool.ActiveCount = 0) and (gPool.SharedActiveCount = 0) and
     (gPool.SlotId = -1) then
    Ok(Ctx + ': temiz (0/0/-1)')
  else
    Fail(Ctx + ': sizinti -> ' + StateStr);
end;

procedure CheckOneOut(const Ctx: string);
begin
  if (gPool.ActiveCount = 1) and (gPool.SharedActiveCount = 1) and
     (gPool.SlotId > 0) then
    Ok(Ctx + ': 1 ornek / 1 slot')
  else
    Fail(Ctx + ': beklenen 1/1 -> ' + StateStr);
end;

{ Release'in EVDbException firlatip firlatmadigini ve kodunu dondurur. }
function ExpectReleaseError(Sql: TVSql; out Code: TVDbErrorCode;
  out Msg: string): Boolean;
begin
  Result := False;
  Code := ecNone;
  Msg := '';
  try
    gPool.Release(Sql);
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

procedure TestNormal;
var
  Q: TVSql;
begin
  WriteLn('1) normal Acquire / Release');
  Q := gPool.Acquire;
  if Q <> nil then Ok('Acquire ornek verdi') else Fail('Acquire nil');
  CheckOneOut('Acquire sonrasi');
  gPool.Release(Q);
  CheckClean('Release sonrasi');
end;

procedure TestReleaseNil;
var
  Q: TVSql;
begin
  WriteLn('2) Release(nil) sahipsiz yol');
  gPool.Release(nil);
  CheckClean('slot yokken Release(nil)');

  Q := gPool.Acquire;
  if Q <> nil then Ok('Acquire ornek verdi') else Fail('Acquire nil');
  gPool.Release(nil);
  { Canli ornek varken sahipsiz Release motoru/mutex'i cekmemeli. }
  CheckOneOut('canli ornek varken Release(nil)');
  gPool.Release(Q);
  CheckClean('dogru Release sonrasi');
end;

procedure TestForeignInstance;
var
  Q, Foreign: TVSql;
  fkv: TVDb;
  ftb: TVTableDb;
  fdir: string;
  Code: TVDbErrorCode;
  Msg: string;
begin
  WriteLn('3) havuzun uretmedigi ornek');
  fdir := IncludeTrailingPathDelimiter(gDir) + 'foreign';
  ForceDirectories(fdir);
  fkv := TVDb.Create;
  ftb := TVTableDb.Create(fkv);
  try
    fkv.Open(fdir);
    ftb.Open(fdir);
    Foreign := TVSql.Create(ftb);
    try
      Q := gPool.Acquire;
      if Q <> nil then Ok('Acquire ornek verdi') else Fail('Acquire nil');
      if ExpectReleaseError(Foreign, Code, Msg) and (Code = ecInvalidArgument) then
        Ok('yabanci ornek ecInvalidArgument ile reddedildi')
      else
        Fail('yabanci ornek reddedilmedi (code=' + VDbErrorName(Code) +
          ' msg=' + Msg + ')');
      { Yabanci Release, canli Q'nun slotunu/mutex'ini cekmemeli. }
      CheckOneOut('yabanci Release sonrasi');
      gPool.Release(Q);
      CheckClean('dogru Release sonrasi');
    finally
      Foreign.Free;
    end;
  finally
    ftb.Close;
    ftb.Free;
    fkv.Close;
    fkv.Free;
  end;
end;

procedure TestWrongThread;
var
  W: TPoolWorker;
  Code: TVDbErrorCode;
  Msg: string;
begin
  WriteLn('4) baska thread''in ornegi');
  W := TPoolWorker.Create(gPool);
  try
    W.Start;
    W.Acquired.WaitFor(10000);
    if W.Failed then
    begin
      Fail('worker Acquire hatasi: ' + W.Msg);
      Exit;
    end;
    if W.Sql <> nil then Ok('worker Acquire ornek verdi') else Fail('worker nil');

    if ExpectReleaseError(W.Sql, Code, Msg) and (Code = ecInvalidArgument) then
      Ok('yanlis thread ecInvalidArgument ile reddedildi')
    else
      Fail('yanlis thread reddedilmedi (code=' + VDbErrorName(Code) +
        ' msg=' + Msg + ')');
    CheckOneOut('yanlis thread Release sonrasi');

    W.Go.SetEvent;
    W.Done.WaitFor(10000);
    if W.Failed then
      Fail('worker Release hatasi: ' + W.Msg)
    else
      Ok('sahip thread Release etti');
    CheckClean('worker Release sonrasi');
  finally
    W.Go.SetEvent;          // kilitli kalmasin
    W.WaitFor;
    W.Free;
  end;
end;

procedure TestLoop;
var
  i: Integer;
  Q: TVSql;
  Bad: Integer;
begin
  WriteLn('5) tekrarlanan Acquire / Release (10 tur)');
  Bad := 0;
  for i := 1 to 10 do
  begin
    Q := gPool.Acquire;
    if Q = nil then
    begin
      Inc(Bad);
      Break;
    end;
    gPool.Release(Q);
    if (gPool.ActiveCount <> 0) or (gPool.SharedActiveCount <> 0) or
       (gPool.SlotId <> -1) then
      Inc(Bad);
  end;
  if Bad = 0 then
    Ok('10 tur sonunda sayaclar 0/0/-1')
  else
    Fail('dongude sizinti: ' + StateStr);
end;

var
  U: string;
  poolDir: string;
begin
  Randomize;
  if ParamStr(1) <> '' then
    gDir := ExpandFileName(ParamStr(1))
  else
    gDir := IncludeTrailingPathDelimiter(GetTempDir) + 'vdb_poolchk';
  ForceDirectories(gDir);
  gDir := IncludeTrailingPathDelimiter(gDir);

  U := IntToHex(Random(MaxInt), 8) + IntToHex(Random(MaxInt), 8);
  poolDir := gDir + 'pool_' + U;
  ForceDirectories(poolDir);

  WriteLn('VDbPool Release hata yolu kapisi');
  gPool := TVDbPool.CreateXProc('POOLCHK_' + U, poolDir, 2, 2000);
  try
    TestNormal;
    TestReleaseNil;
    TestForeignInstance;
    TestWrongThread;
    TestLoop;
  finally
    gPool.Free;
    gPool := nil;
  end;

  WriteLn('===============================');
  WriteLn('SONUC: gecen=', gPass, ' kalan=', gFail);
  if gFail > 0 then
  begin
    WriteLn('HAVUZ HATA YOLU BASARISIZ');
    Halt(1);
  end;
  WriteLn('HAVUZ HATA YOLU DOGRULANDI');
end.
