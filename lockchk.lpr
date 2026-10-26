program lockchk;

{ VDB v3 - cok okuyucu / tek yazici kapisi (v3.2)

  Denetlenenler:
    1) Ayni veritabanina AYNI ANDA iki salt-okunur oturum acilir ve
       birbirinin ayni satirlari okur (paylasimli kilit).
    2) Salt-okunur oturum acikken yazar, busy timeout boyunca bekler ve
       sonunda ACIK "mesgul" hatasi alir.
    3) Iki yazar: busy=0 ise hemen, busy=N ise ~N ms sonra "mesgul".
    4) Salt-okunur oturumda yazma denemesi acik hata verir; VERIFY calisir.
    5) Okuyucu <db>.log dizinini OLUSTURMAZ.
    6) Cokme sonrasi (WAL'de onaylanmis, diske gecmemis cerceveler) salt-okunur
       oturum veriyi WAL katmanindan okur; diskte HICBIR bayt degistirmez.
    7) Yazici kapaninca okuyucu en guncel satir sayisini gorur.

  Cocuk surecler: bu program kendini farkli argumanlarla calistirir.
  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: lockchk <calisma_dizini>
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, Process,
  VDbBackendApi, VDbBackendV3, VDbFactory,
  VDbPage, VDbPageStore, VDbPageEngine;

var
  gPass, gFail: Int64;

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

function MsNow: Int64;
begin
  Result := Trunc(Now * MSecsPerDay);
end;

function LowS(const S: string): string;
begin
  Result := LowerCase(S);
end;

function MakeVal(I: Integer): TBytes;
var
  s: string;
begin
  s := IntToStr(I);
  SetLength(Result, Length(s));
  if Length(s) > 0 then
    Move(s[1], Result[0], Length(s));
end;

{ ------------------------------------------------------------------ dosyalar }

procedure DeleteTree(const Dir: string);
var
  sr: TSearchRec;
  p: string;
begin
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      p := IncludeTrailingPathDelimiter(Dir) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        DeleteTree(p)
      else
        DeleteFile(p);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  RemoveDir(Dir);
end;

procedure WipeDb(const Db: string);
begin
  if FileExists(Db) then DeleteFile(Db);
  if FileExists(Db + '.wal') then DeleteFile(Db + '.wal');
  if FileExists(Db + '.idx') then DeleteFile(Db + '.idx');
  if FileExists(Db + '.bak') then DeleteFile(Db + '.bak');
  DeleteTree(Db + '.log');
  DeleteTree(Db + '.repl');
end;

function FileBytesOf(const P: string): Int64;
var
  f: TFileStream;
begin
  if not FileExists(P) then Exit(-1);
  f := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
  try
    Result := f.Size;
  finally
    f.Free;
  end;
end;

{ ------------------------------------------------------------------ cocuklar }

function StartChild(const AArgs: array of string): TProcess;
var
  i: Integer;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ExpandFileName(ParamStr(0));
  Result.Options := [poUsePipes];
  for i := Low(AArgs) to High(AArgs) do
    Result.Parameters.Add(AArgs[i]);
  Result.Execute;
end;

function FinishChild(p: TProcess; out AOut: string): Integer;
var
  buf: array[0..1023] of Char;
  n: LongInt;
begin
  AOut := '';
  repeat
    n := p.Output.Read(buf, SizeOf(buf));
    if n > 0 then
      AOut := AOut + Copy(buf, 0, n);
  until n <= 0;
  p.WaitOnExit;
  Result := p.ExitStatus;
  p.Free;
end;

function RunChild(const AArgs: array of string; out AOut: string): Integer;
var
  p: TProcess;
begin
  p := StartChild(AArgs);
  Result := FinishChild(p, AOut);
end;

{ --ro <db> <beklenen_sayi> [bekleme_ms]
  Salt-okunur acar, satir sayisini ve 7 numarali anahtari dogrular,
  yazma denemesinin reddedildigini gorur. }
function ChildReadOnly: Integer;
var
  db: string;
  expect, holdMs: Integer;
  be: IVdbBackend;
  v: TBytes;
  wrote: Boolean;
begin
  db := ParamStr(2);
  expect := StrToIntDef(ParamStr(3), -1);
  holdMs := StrToIntDef(ParamStr(4), 0);
  try
    VdbOpenReadOnly(db, be, VDB_DEF_POOL, 0);
    if not be.IsReadOnly then
    begin
      WriteLn('HATA IsReadOnly=False'); Exit(3);
    end;
    if be.Count <> expect then
    begin
      WriteLn(Format('HATA sayi %d (beklenen %d)', [be.Count, expect]));
      Exit(4);
    end;
    if not be.Get(7, v) then
    begin
      WriteLn('HATA anahtar 7 yok'); Exit(5);
    end;
    if (Length(v) <> 1) or (v[0] <> Ord('7')) then
    begin
      WriteLn('HATA anahtar 7 degeri yanlis'); Exit(6);
    end;
    wrote := False;
    try
      be.Put(999999, MakeVal(999999));
      wrote := True;
    except
      on E: Exception do
        if Pos('salt-okunur', LowS(E.Message)) = 0 then
        begin
          WriteLn('HATA yazma reddi nedeni yanlis: ', E.Message);
          Exit(7);
        end;
    end;
    if wrote then
    begin
      WriteLn('HATA salt-okunur oturumda yazma BASARILI oldu'); Exit(8);
    end;
    if holdMs > 0 then
      Sleep(holdMs);
    be := nil;
    WriteLn('TAMAM');
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn('HATA ', E.Message);
      Result := 10;
    end;
  end;
end;

{ --ro-hold <db> <beklenen_sayi> <hazir_dosyasi> <tutma_ms> }
function ChildReadOnlyHold: Integer;
var
  db, ready: string;
  expect, holdMs: Integer;
  be: IVdbBackend;
  f: TFileStream;
begin
  db := ParamStr(2);
  expect := StrToIntDef(ParamStr(3), -1);
  ready := ParamStr(4);
  holdMs := StrToIntDef(ParamStr(5), 1000);
  try
    VdbOpenReadOnly(db, be, VDB_DEF_POOL, 0);
    if be.Count <> expect then
    begin
      WriteLn(Format('HATA sayi %d (beklenen %d)', [be.Count, expect]));
      Exit(4);
    end;
    f := TFileStream.Create(ready, fmCreate);
    try
      f.WriteBuffer(holdMs, SizeOf(holdMs));
    finally
      f.Free;
    end;
    Sleep(holdMs);
    be := nil;
    WriteLn('TAMAM');
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn('HATA ', E.Message);
      Result := 10;
    end;
  end;
end;

{ --writer <db> <busy_ms> : yazan oturum acmayi dener.
  Basariliysa cikis 2, "mesgul" ise cikis 0 ve "MESGUL <gecen_ms>". }
function ChildWriterAttempt: Integer;
var
  db: string;
  busy: Integer;
  t0: Int64;
  be: IVdbBackend;
begin
  db := ParamStr(2);
  busy := StrToIntDef(ParamStr(3), 0);
  t0 := MsNow;
  try
    be := TVdbBackendV3.Create(db, False, VDB_DEF_POOL, busy);
    be.Put(500000, MakeVal(500000));
    be.CommitBatch;
    be := nil;
    WriteLn('BEKLENMEDIK_ACILDI');
    Exit(2);
  except
    on E: Exception do
    begin
      if Pos('mesgul', LowS(E.Message)) > 0 then
      begin
        WriteLn(Format('MESGUL %d', [MsNow - t0]));
        Exit(0);
      end;
      WriteLn('HATA ', E.Message);
      Exit(3);
    end;
  end;
end;

{ --writer-hold <db> <hazir_dosyasi> <tutma_ms> : yazar tutar. }
function ChildWriterHold: Integer;
var
  db, ready: string;
  holdMs: Integer;
  be: IVdbBackend;
  f: TFileStream;
begin
  db := ParamStr(2);
  ready := ParamStr(3);
  holdMs := StrToIntDef(ParamStr(4), 1000);
  try
    be := TVdbBackendV3.Create(db, False, VDB_DEF_POOL, 0);
    be.BeginBatch;
    be.Put(500000, MakeVal(500000));
    be.CommitBatch;
    f := TFileStream.Create(ready, fmCreate);
    try
      f.WriteBuffer(holdMs, SizeOf(holdMs));
    finally
      f.Free;
    end;
    Sleep(holdMs);
    be := nil;
    WriteLn('TAMAM');
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn('HATA ', E.Message);
      Result := 10;
    end;
  end;
end;

{ v3.9: motor kilidi (TVdbGate) - derinlik defteri.
  ONCEDEN FEngCs duz bir TCriticalSection'di ve ic ice cagrilar (ScanAll ->
  ScanCb -> OwnSet, ApplyBatch -> BatchMap ...) yalnizca "kritik bolum
  yeniden girisli" VARSAYIMINA dayaniyordu. Artik gate sahibi is parcacigini
  ve derinligi izler: ayni parcacikdan giris kritik bolume HIC girmez.
  Bu test: (a) her genel islemden sonra derinlik 0'a doner, (b) ic ice yol
  gercekten kullaniliyor (MaxDepth >= 2), (c) 3 is parcacigi ayni backend'de
  karisik okuma/yazma yaparken hata ve derinlik sizintisi olmaz. }
type
  TGateWorker = class(TThread)
  public
    Be: IVDbBackend;
    Mode: Integer;        // 0 = okuyucu, 1 = yazici
    Iters: Integer;
    Err: string;
    procedure Execute; override;
  end;

procedure TGateWorker.Execute;
var
  i: Integer;
  v: TBytes;
  keys: TQWordArray;
  vals: TValArray;
begin
  try
    for i := 1 to Iters do
    begin
      if Mode = 1 then
      begin
        SetLength(v, 12);
        PInt64(@v[0])^ := i;
        PInteger(@v[8])^ := Mode;
        Be.Put(QWord(100000 + i), v);
      end
      else
        case (i mod 4) of
          0: Be.ScanAll(keys, vals, -1);
          1: Be.Count;
          2: Be.Exists(1);
        else
          Be.Get(1, v);
        end;
    end;
  except
    on E: Exception do Err := E.Message;
  end;
end;

procedure TestGateDepth(const Dir: string);
var
  be: TVdbBackendV3;
  ib: IVDbBackend;
  v: TBytes;
  i, ds, dbf: Integer;
  freed: Int64;
  err: string;
  keys: TQWordArray;
  vals: TValArray;
  bad: Integer;
  w1, w2, wr: TGateWorker;
  seqMax: Integer;
begin
  WriteLn;
  WriteLn('7) motor kilidi: derinlik defteri + es zamanli erisim');

  WipeDb(Dir + 'gate.odb');
  be := TVdbBackendV3.Create(Dir + 'gate.odb', True, VDB_DEF_POOL, 0);
  ib := be;
  bad := 0;
  if be.DebugLockDepth <> 0 then
    Fail(Format('acilistan sonra derinlik %d (beklenen 0)', [be.DebugLockDepth]));

  { 200 satir TEK commit'te yazilir: WAL'de gecmis olussun ki ScanAllAt'in
    gercek (taban + WAL) yolu calissin. }
  ib.BeginBatch;
  for i := 1 to 200 do
    ib.Put(i, MakeVal(i));
  ib.CommitBatch;
  if be.DebugLockDepth = 0 then Ok('200 Put + CommitBatch sonrasi derinlik 0')
  else begin Inc(bad); Fail(Format('Put sonrasi derinlik %d', [be.DebugLockDepth])); end;

  if ib.Exists(100) and (ib.Count = 200) then
    Ok('Exists/Count dogru')
  else begin Inc(bad); Fail('Exists/Count yanlis'); end;
  if be.DebugLockDepth = 0 then Ok('okuma sonrasi derinlik 0')
  else begin Inc(bad); Fail(Format('okuma sonrasi derinlik %d', [be.DebugLockDepth])); end;

  { ic ice yol: ScanAll kilit altinda OwnSet cagirir -> derinlik 2 }
  ib.BeginBatch;
  for i := 1 to 50 do
    ib.Put(QWord(500 + i), MakeVal(i));
  ib.ScanAll(keys, vals, -1);
  if Length(keys) = 250 then
    Ok('acik islemde tarama 250 satir (kaplama dahil)')
  else begin Inc(bad); Fail(Format('tarama %d satir (beklenen 250)', [Length(keys)])); end;
  if (be.DebugLockMaxDepth >= 2) and (be.DebugLockDepth = 0) then
    Ok(Format('ic ice giris izlendi (en yuksek derinlik %d), sonra 0',
      [be.DebugLockMaxDepth]))
  else begin Inc(bad); Fail(Format('derinlik defteri yanlis: max=%d anlik=%d',
    [be.DebugLockMaxDepth, be.DebugLockDepth])); end;
  ib.AbortBatch;
  if (be.DebugLockDepth = 0) and (ib.Count = 200) then
    Ok('AbortBatch sonrasi derinlik 0, 200 satir')
  else begin Inc(bad); Fail('AbortBatch sonrasi durum yanlis'); end;

  { v3.9: ScanAllAt ayni FScan* tamponlarini kullanir; artik kilit altinda.
    LogPrune'dan ONCE cagrilir: budama checkpoint tetikleyip WAL gecmisini
    bosaltabilir; o durumda ScanAllAt'in "gecmis yok" yolu calisirdi. }
  seqMax := ib.AsOfMaxSequence;
  if ib.ScanAllAt(-1, seqMax, keys, vals, ds) then
  begin
    if (seqMax > 0) and (ds = seqMax) and (Length(keys) = 200) then
      Ok(Format('ScanAllAt (seq %d/%d): 200 satir birebir', [ds, seqMax]))
    else begin Inc(bad); Fail(Format('ScanAllAt yanlis: seq=%d/%d satir=%d',
      [ds, seqMax, Length(keys)])); end;
  end
  else begin Inc(bad); Fail('ScanAllAt basarisiz'); end;
  if be.DebugLockDepth = 0 then
    Ok('ScanAllAt sonrasi derinlik 0')
  else begin Inc(bad); Fail(Format('ScanAllAt sonrasi derinlik %d', [be.DebugLockDepth])); end;

  { budama ve dogrulama da gate'i kullanir }
  ib.LogPrune(ds, dbf, freed, err);
  if (be.DebugLockDepth = 0) and (err = '') then
    Ok('LogPrune sonrasi derinlik 0, hata yok')
  else begin Inc(bad); Fail(Format('LogPrune sonrasi derinlik %d err=%s',
    [be.DebugLockDepth, err])); end;

  { 2 okuyucu + 1 yazici AYNI backend uzerinde }
  w1 := TGateWorker.Create(True);
  w2 := TGateWorker.Create(True);
  wr := TGateWorker.Create(True);
  try
    w1.Be := ib; w1.Mode := 0; w1.Iters := 300; w1.Err := '';
    w2.Be := ib; w2.Mode := 0; w2.Iters := 300; w2.Err := '';
    wr.Be := ib; wr.Mode := 1; wr.Iters := 300; wr.Err := '';
    w1.Start; w2.Start; wr.Start;
    w1.WaitFor; w2.WaitFor; wr.WaitFor;
    if (w1.Err = '') and (w2.Err = '') and (wr.Err = '') then
      Ok('3 is parcacigi karisik okuma/yazma hatasiz')
    else begin Inc(bad); Fail('is parcacigi hatasi: ' + w1.Err + w2.Err + wr.Err); end;
    if be.DebugLockDepth = 0 then
      Ok(Format('es zamanli erisim sonrasi derinlik 0 (en yuksek %d)',
        [be.DebugLockMaxDepth]))
    else begin Inc(bad); Fail(Format('derinlik sizintisi: %d', [be.DebugLockDepth])); end;
    if ib.Count = 500 then
      Ok('es zamanli yazim: 200 + 300 satir')
    else begin Inc(bad); Fail(Format('es zamanli yazim sonrasi count=%d (beklenen 500)',
      [ib.Count])); end;
  finally
    w1.Free; w2.Free; wr.Free;
  end;

  ib := nil;
  if bad = 0 then
    Ok('kilit defteri tutarli');
end;

{ ------------------------------------------------------------------- ebeveyn }

function TryWriterOpen(const Db: string; BusyMs: Integer;
  out Msg: string; out Elapsed: Int64): Boolean;
var
  t0: Int64;
  be: IVdbBackend;
begin
  t0 := MsNow;
  Result := False;
  Msg := '';
  try
    be := TVdbBackendV3.Create(Db, False, VDB_DEF_POOL, BusyMs);
    be := nil;
    Result := True;
  except
    on E: Exception do
      Msg := E.Message;
  end;
  Elapsed := MsNow - t0;
end;

procedure RunParent;
var
  dir, db, crashDb, ready: string;
  be: IVdbBackend;
  eng: TVdbPageEngine;
  i, rc, expectCount: Integer;
  p1, p2: TProcess;
  aOut, bOut, msg, rep: string;
  t0, elapsed, sz0, sz1, wal0, wal1: Int64;
  wrote, okAll, verified: Boolean;
  v: TBytes;
begin
  dir := ParamStr(1);
  if dir = '' then dir := '.';
  dir := IncludeTrailingPathDelimiter(ExpandFileName(dir));
  if not DirectoryExists(dir) then
    ForceDirectories(dir);
  db := dir + 'lock.odb';
  ready := dir + 'lock.ready';

  WriteLn('VDB v3 lockchk - cok okuyucu / tek yazici kapisi');
  WriteLn('dizin=', dir);
  WriteLn;

  WipeDb(db);
  if FileExists(ready) then DeleteFile(ready);

  { 1) temel veri: 500 satir, temiz kapanis (WAL bos). }
  be := TVdbBackendV3.Create(db, True, VDB_DEF_POOL, 1000);
  be.BeginBatch;
  for i := 1 to 500 do
    be.Put(i, MakeVal(i));
  be.CommitBatch;
  be := nil;
  if FileExists(db) then
    Ok('yazici veritabani olusturdu (500 satir, temiz kapanis)')
  else
    Fail('veritabani olusmadi');

  { Okuyucunun <db>.log olusturmadigini gormek icin gunlugu sil. }
  DeleteTree(db + '.log');

  { 2) iki salt-okunur oturum AYNI ANDA. }
  p1 := StartChild(['--ro', db, '500', '400']);
  p2 := StartChild(['--ro', db, '500', '400']);
  rc := FinishChild(p1, aOut);
  if rc = 0 then
    Ok('okuyucu A: ayni anda 500 satir okudu, yazma reddedildi')
  else
    Fail('okuyucu A (cikis ' + IntToStr(rc) + '): ' + Trim(aOut));
  rc := FinishChild(p2, bOut);
  if rc = 0 then
    Ok('okuyucu B: ayni anda 500 satir okudu (paylasimli kilit)')
  else
    Fail('okuyucu B (cikis ' + IntToStr(rc) + '): ' + Trim(bOut));

  if DirectoryExists(db + '.log') then
    Fail('salt-okunur okuyucu <db>.log dizinini OLUSTURDU')
  else
    Ok('salt-okunur okuyucu <db>.log dizinini olusturmadi');

  { 3) okuyucu tutarken yazar: busy timeout. }
  if FileExists(ready) then DeleteFile(ready);
  p1 := StartChild(['--ro-hold', db, '500', ready, '1500']);
  t0 := MsNow;
  while (not FileExists(ready)) and ((MsNow - t0) < 15000) do
    Sleep(10);
  if not FileExists(ready) then
    Fail('okuyucu hazir isareti birakmadi')
  else
  begin
    if TryWriterOpen(db, 400, msg, elapsed) then
      Fail('okuyucu varken yazar ACILDI (beklenmiyordu)')
    else if (Pos('mesgul', LowS(msg)) > 0) and (elapsed >= 300) then
      Ok(Format('okuyucu varken yazar mesgul: busy=400 ms, olculen %d ms',
        [elapsed]))
    else
      Fail(Format('okuyucu varken yazar: %d ms, %s', [elapsed, msg]));
  end;
  rc := FinishChild(p1, aOut);
  if rc = 0 then
    Ok('okuyucu tutma testi tamamlandi')
  else
    Fail('okuyucu tutma (cikis ' + IntToStr(rc) + '): ' + Trim(aOut));
  if FileExists(ready) then DeleteFile(ready);

  { 4) yazar tutarken ikinci yazar. }
  p1 := StartChild(['--writer-hold', db, ready, '2000']);
  t0 := MsNow;
  while (not FileExists(ready)) and ((MsNow - t0) < 15000) do
    Sleep(10);
  if not FileExists(ready) then
    Fail('yazar hazir isareti birakmadi')
  else
  begin
    if TryWriterOpen(db, 0, msg, elapsed) then
      Fail('busy=0 iken ikinci yazar ACILDI (beklenmiyordu)')
    else if (Pos('mesgul', LowS(msg)) > 0) and (elapsed < 500) then
      Ok(Format('busy=0: ikinci yazar hemen mesgul (%d ms)', [elapsed]))
    else
      Fail(Format('busy=0: %d ms, %s', [elapsed, msg]));

    if TryWriterOpen(db, 350, msg, elapsed) then
      Fail('busy=350 iken ikinci yazar ACILDI (beklenmiyordu)')
    else if (Pos('mesgul', LowS(msg)) > 0) and (elapsed >= 280) then
      Ok(Format('busy=350: beklendi, mesgul (%d ms)', [elapsed]))
    else
      Fail(Format('busy=350: %d ms, %s', [elapsed, msg]));

    { Yazar acikken salt-okunur oturum da acilamaz (paylasimli kilit yok). }
    rc := RunChild(['--ro', db, '500'], aOut);
    if (rc <> 0) and (Pos('mesgul', LowS(aOut)) > 0) then
      Ok('yazar varken salt-okunur oturum mesgul: ' + Trim(aOut))
    else
      Fail('yazar varken salt-okunur oturum: cikis ' + IntToStr(rc) +
        ', ' + Trim(aOut));
  end;
  rc := FinishChild(p1, aOut);
  if rc = 0 then
    Ok('yazar tutma testi tamamlandi (500000 anahtari yazildi)')
  else
    Fail('yazar tutma (cikis ' + IntToStr(rc) + '): ' + Trim(aOut));
  if FileExists(ready) then DeleteFile(ready);

  { 5) yazar kapandi: okuyucu en guncel sayiyi gorur. }
  expectCount := 501;
  be := TVdbBackendV3.CreateReadOnly(db, VDB_DEF_POOL, 0);
  if be.Count = expectCount then
    Ok(Format('yazici kapandiktan sonra okuyucu %d satir gordu', [expectCount]))
  else
    Fail(Format('okuyucu sayisi %d (beklenen %d)', [be.Count, expectCount]));

  wrote := False;
  try
    be.Put(1, MakeVal(1));
    wrote := True;
  except
    on E: Exception do
      if Pos('salt-okunur', LowS(E.Message)) > 0 then
        Ok('salt-okunur oturumda Put acik hatayla reddedildi')
      else
        Fail('yanlis ret nedeni: ' + E.Message);
  end;
  if wrote then
    Fail('salt-okunur oturumda Put BASARILI oldu');

  verified := be.Verify(rep);
  if verified then
    Ok('salt-okunur VERIFY gecti: ' + rep)
  else
    Fail('salt-okunur VERIFY basarisiz: ' + rep);

  if be.Get(500000, v) then
    Ok('okuyucu yazicinin son anahtarini gordu')
  else
    Fail('okuyucu yazicinin son anahtarini goremedi');
  be := nil;

  { 6) cokme sonrasi salt-okunur okuma (WAL katmani) ve disk dokunulmazligi. }
  crashDb := dir + 'crash.odb';
  WipeDb(crashDb);
  eng := TVdbPageEngine.Create(crashDb, VDB_DEF_POOL);
  try
    eng.Open(True);
    for i := 1 to 200 do
      eng.Insert(i, MakeVal(i));
    eng.Commit(True);
    if eng.Wal.HasContent then
      Ok(Format('WAL onaylanmis cerceve iceriyor (%d bayt)',
        [eng.Wal.Bytes]))
    else
      Fail('WAL icerigi yok (test kurulumu gecersiz)');
    eng.SimulateCrash;
  finally
    eng.Free;
  end;

  sz0 := FileBytesOf(crashDb);
  wal0 := FileBytesOf(crashDb + '.wal');

  eng := TVdbPageEngine.Create(crashDb, VDB_DEF_POOL);
  try
    eng.Open(False, True);
    if not eng.ReadOnly then
      Fail('motor salt-okunur isaretlenmedi');
    okAll := eng.GetCount = 200;
    if okAll then
    begin
      v := nil;
      okAll := eng.TryGet(7, v) and (Length(v) = 1) and (v[0] = Ord('7'));
    end;
    if okAll then
      Ok(Format('cokme sonrasi salt-okunur: WAL katmanindan 200 satir ' +
        've deger birebir (kurtarilan cerceve=%d)',
        [eng.RecoveryStats.Frames]))
    else
      Fail(Format('cokme sonrasi okuma yanlis (sayi=%d)', [eng.GetCount]));
    eng.Close;
  finally
    eng.Free;
  end;

  sz1 := FileBytesOf(crashDb);
  wal1 := FileBytesOf(crashDb + '.wal');
  if (sz0 = sz1) and (wal0 = wal1) then
    Ok(Format('salt-okunur oturum diskte HICBIR bayt degistirmedi ' +
      '(odb=%d, wal=%d)', [sz1, wal1]))
  else
    Fail(Format('salt-okunur oturum diski degistirdi: odb %d->%d, wal %d->%d',
      [sz0, sz1, wal0, wal1]));

  { 7) v3.9: motor kilidi defteri + es zamanli erisim. }
  TestGateDepth(dir);

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('COK OKUYUCU / TEK YAZICI DOGRULANDI');
    ExitCode := 0;
  end
  else
  begin
    WriteLn('HATA VAR');
    ExitCode := 1;
  end;
end;

begin
  ExitCode := 0;
  if ParamCount >= 2 then
  begin
    if ParamStr(1) = '--ro' then
    begin
      gPass := 0; gFail := 0;
      ExitCode := ChildReadOnly;
      Exit;
    end;
    if ParamStr(1) = '--ro-hold' then
    begin
      gPass := 0; gFail := 0;
      ExitCode := ChildReadOnlyHold;
      Exit;
    end;
    if ParamStr(1) = '--writer' then
    begin
      gPass := 0; gFail := 0;
      ExitCode := ChildWriterAttempt;
      Exit;
    end;
    if ParamStr(1) = '--writer-hold' then
    begin
      gPass := 0; gFail := 0;
      ExitCode := ChildWriterHold;
      Exit;
    end;
  end;

  RunParent;
end.
