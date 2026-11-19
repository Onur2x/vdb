program maint_lock;
{ SKILL5 7.1-7.4 — SURELER ARASI BAKIM KILIDI kapisi (v3.63).

  SKILL5 kurali: dosya degistirme (VACUUM/Compact/Restore/Rekey) sirasinda
  IKI SUREC FARKLI FIZIKSEL VERITABANI NESNELERINE yazamamalidir. Linux'ta
  acik fd eski inode'a bagli kalir; kilit alinmadan yapilan bir degistirme
  sessiz veri kaybi uretir.

  Bu kapi kanitlar:

    ML1  Tek surecte VACUUM calisir, satirlar korunur (regresyon).
    ML2  ACIK BIR YAZMA ISLEMI varken (baska surecte) bakim REDDEDILIR:
         '.gen' rezervasyonu beklenir, sure asilirsa fail-closed hata.
    ML3  BOSTA bekleyen bir oturum varken bakim ya reddedilir ya da o
         oturum sonraki erisimde 'dosya degistirildi' hatasi alir; BAYAT
         veri OKUMAZ (Linux'ta ayirt edici; Windows'ta rename zaten
         engellendigi icin kosul daha zayif calisir — durustce not edilir).
    ML4  Ikinci surec, bakim bittikten sonra kendi VACUUM'unu yapar.
    ML5  Bakimdan sonra .tmp kalintisi kalmaz.

  Cocuk surecler bu ayni programdir; mod adi ParamStr(1) ile secilir.
  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process, VDbFactory, VDbBackendApi, VDbTable, VDbSql,
  VDbSync;

var
  GPass, GFail: Integer;
  GExe: string;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' | ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' | ', ADetail);
  end;
end;

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp');
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
  p: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        p := IncludeTrailingPathDelimiter(ADir) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
        begin
          WipeDir(p);
          RemoveDir(p);
        end
        else
          SysUtils.DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function CountArtifacts(const ADir, APattern: string): Integer;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + APattern, faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function ListArtifacts(const ADir, APattern: string): string;
var
  sr: TSearchRec;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + APattern, faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + sr.Name;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

procedure MarkerTouch(const APath: string);
var
  f: TFileStream;
  b: Byte;
begin
  if APath = '' then Exit;
  b := 1;
  f := TFileStream.Create(APath, fmCreate);
  try
    f.WriteBuffer(b, 1);
  finally
    f.Free;
  end;
end;

function WaitForFile(const APath: string; AMs: Integer): Boolean;
var
  t0: QWord;
begin
  t0 := GetTickCount64;
  while (GetTickCount64 - t0) < QWord(AMs) do
  begin
    if FileExists(APath) then Exit(True);
    Sleep(20);
  end;
  Result := FileExists(APath);
end;

{ ------------------------------------------------------------------ }
{ Cocuk modlari                                                      }
{ ------------------------------------------------------------------ }

procedure ChildRoHold(const ADb, AMarker: string);
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
begin
  VdbOpenReadOnly(ADb, Be, 0, 0);
  try
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(ExtractFileDir(Be.FilePath));
      Sq := TVSql.Create(Tb);
      try
        { Oturum ACIK ama BOSTA: hicbir dosya kilidi tutulmuyor. }
        MarkerTouch(AMarker);
        WaitForFile(AMarker + '.go', 10000);
        try
          R := Sq.Exec('SELECT COUNT(*) FROM t');
          WriteLn('CHILD ro-hold COUNT=', R.Rows[0][0]);
        except
          on E: Exception do
            WriteLn('CHILD ro-hold ERROR ', E.ClassName, ': ', E.Message);
        end;
      finally
        Sq.Free;
      end;
    finally
      Tb.Free;
    end;
  finally
    Be := nil;
  end;
end;

procedure ChildWriteTxn(const ADb, AMarker: string);
var
  Be: IVdbBackend;
  i: Integer;
  pr: THandleStream;
  tutuldu: Boolean;
begin
  VdbOpen(ADb, Be, False, True);
  try
    { ACIK yazma islemi: rezervasyon islem boyunca `.gen` uzerinde tutulur. }
    Be.BeginBatch;
    { TANI (kalici): rezervasyon gercekten tutuluyor mu? Ikinci bir fd ile
      ayni dosyaya tam kilit denenir; alinabiliyorsa rezervasyon YOKTUR. }
    tutuldu := False;
    try
      pr := VDbOpenProbeStream(ADb + '.gen');
      try
        tutuldu := not VDbLockStream(pr);
        if not tutuldu then VDbUnlockStream(pr);
      finally
        FreeAndNil(pr);
      end;
    except
      on E: Exception do
        WriteLn('CHILD wtxn RESERVE-PROBE-ERR ', E.ClassName, ': ', E.Message);
    end;
    WriteLn('CHILD wtxn RESERVE-HELD=', tutuldu);
    MarkerTouch(AMarker);
    Sleep(5000);
    try
      Be.CommitBatch;
      WriteLn('CHILD wtxn COMMITTED');
    except
      on E: Exception do
        WriteLn('CHILD wtxn COMMIT-ERROR ', E.ClassName, ': ', E.Message);
    end;
  finally
    Be := nil;
  end;
end;

procedure ChildCompact(const ADb, AMarker: string);
var
  Be: IVdbBackend;
  o, n: Int64;
begin
  VdbOpen(ADb, Be, False, True);
  try
    MarkerTouch(AMarker);
    try
      Be.Compact(o, n);
      WriteLn('CHILD compact OK eski=', o, ' yeni=', n);
    except
      on E: Exception do
        WriteLn('CHILD compact ERR ', E.ClassName, ': ', E.Message);
    end;
  finally
    Be := nil;
  end;
end;

procedure RunChild(const AMode, ADb, AMarker: string);
begin
  if AMode = 'ro-hold' then
  begin
    ChildRoHold(ADb, AMarker);
    Exit;
  end;
  if AMode = 'wtxn' then
  begin
    ChildWriteTxn(ADb, AMarker);
    Exit;
  end;
  if AMode = 'compact' then
  begin
    ChildCompact(ADb, AMarker);
    Exit;
  end;
  WriteLn('CHILD bilinmeyen mod: ', AMode);
  Halt(2);
end;

{ ------------------------------------------------------------------ }
{ Ebeveyn yardimcilari                                               }
{ ------------------------------------------------------------------ }

type
  TChild = record
    P: TProcess;
    Mode: string;
  end;

function StartChild(const AArgs: array of string; const AMode: string): TChild;
var
  i: Integer;
begin
  Result.Mode := AMode;
  Result.P := TProcess.Create(nil);
  Result.P.Executable := GExe;
  for i := Low(AArgs) to High(AArgs) do
    Result.P.Parameters.Add(AArgs[i]);
  Result.P.Options := [poUsePipes, poStderrToOutput];
  Result.P.Execute;
end;

function ReadPipe(P: TProcess): string;
var
  buf: array[0..4095] of AnsiChar;
  n: LongInt;
begin
  Result := '';
  repeat
    n := P.Output.Read(buf, SizeOf(buf));
    if n > 0 then
      Result := Result + Copy(buf, 1, n);
  until n <= 0;
end;

function WaitChild(var C: TChild; out AOut: string): Integer;
begin
  AOut := ReadPipe(C.P);
  C.P.WaitOnExit;
  Result := C.P.ExitStatus;
  C.P.Free;
  C.P := nil;
end;

function CountRows(ABe: IVdbBackend): Int64;
var
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
begin
  Result := -1;
  Tb := TVTableDb.CreateBackend(ABe);
  try
    Tb.Open(ExtractFileDir(ABe.FilePath));
    Sq := TVSql.Create(Tb);
    try
      R := Sq.Exec('SELECT COUNT(*) FROM t');
      Result := StrToInt64Def(R.Rows[0][0], -1);
    finally
      Sq.Free;
    end;
  finally
    Tb.Free;
  end;
end;

procedure ExecOn(ABe: IVdbBackend; const ASql: string);
var
  Tb: TVTableDb;
  Sq: TVSql;
begin
  Tb := TVTableDb.CreateBackend(ABe);
  try
    Tb.Open(ExtractFileDir(ABe.FilePath));
    Sq := TVSql.Create(Tb);
    try
      Sq.Exec(ASql);
    finally
      Sq.Free;
    end;
  finally
    Tb.Free;
  end;
end;

function TryCompact(ABe: IVdbBackend; out AErr: string;
  out AOld, ANew: Int64): Boolean;
begin
  AErr := '';
  AOld := 0;
  ANew := 0;
  try
    ABe.Compact(AOld, ANew);
    Result := True;
  except
    on E: Exception do
    begin
      AErr := E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
end;

var
  d1, db, marker, err, out1, rep: string;
  be: IVdbBackend;
  tb: TVTableDb;
  sq: TVSql;
  i, rc, rowsBefore, rowsAfter: Integer;
  c: TChild;
  ok: Boolean;
  o, n: Int64;
  t0: QWord;
begin
  if (ParamCount >= 1) and (ParamStr(1) <> '') then
  begin
    RunChild(ParamStr(1), ParamStr(2), ParamStr(3));
    Exit;
  end;

  GPass := 0;
  GFail := 0;
  GExe := ExpandFileName(ParamStr(0));
  ForceDirectories(TestDir);

  d1 := IncludeTrailingPathDelimiter(TestDir + 'ml_a');
  WipeDir(d1);
  ForceDirectories(d1);
  marker := TestDir + 'ml_marker';

  WriteLn('BILGI cocuk ikili: ', GExe);

  { --- Kaynak veritabani --- }
  VdbOpen(d1, be, True, True);
  tb := TVTableDb.CreateBackend(be);
  tb.Open(d1);
  sq := TVSql.Create(tb);
  sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  for i := 1 to 100 do
    sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''satir-' +
      IntToStr(i) + ''')');
  sq.Free;
  tb.Free;
  db := be.FilePath;
  be := nil;

  { --- ML1: tek surecte VACUUM --- }
  VdbOpen(db, be, False, True);
  try
    rowsBefore := CountRows(be);
  finally
    be := nil;
  end;
  VdbOpen(db, be, False, True);
  try
    ok := TryCompact(be, err, o, n);
    rowsAfter := CountRows(be);
    Chk('ML1 tek surecte VACUUM basarili ve satirlar korundu',
      ok and (rowsAfter = 100) and (rowsBefore = 100),
      'ok=' + BoolToStr(ok, True) + ' once=' + IntToStr(rowsBefore) +
      ' sonra=' + IntToStr(rowsAfter) + ' hata=' + err);
  finally
    be := nil;
  end;

  { --- ML2: baska surecte ACIK yazma islemi varken bakim reddedilir --- }
  DeleteFile(marker);
  c := StartChild(['wtxn', db, marker], 'wtxn');
  ok := WaitForFile(marker, 10000);
  Chk('ML2a cocuk yazma islemi acildi', ok and (c.P <> nil),
    'isaret=' + BoolToStr(ok, True));
  VdbOpen(db, be, False, True);
  try
    t0 := GetTickCount64;
    ok := TryCompact(be, err, o, n);
    Chk('ML2b acik yazma islemi varken bakim REDDEDILDI',
      (not ok) and (Pos('bakim kilidi', err) > 0),
      'sure_ms=' + IntToStr(GetTickCount64 - t0) + ' hata=' + err);
    { Islem hala acikken satirlar yerinde olmali. }
    Chk('ML2c reddedilen bakim veriye dokunmadi', CountRows(be) = 100,
      'COUNT=' + IntToStr(CountRows(be)));
  finally
    be := nil;
  end;
  rc := WaitChild(c, out1);
  Chk('ML2d cocuk islemi commit etti', (rc = 0) and (Pos('COMMITTED', out1) > 0),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
  VdbOpen(db, be, False, True);
  try
    Chk('ML2e commit sonrasi satirlar korundu', CountRows(be) = 100,
      'COUNT=' + IntToStr(CountRows(be)));
  finally
    be := nil;
  end;

  { --- ML3: BOSTA bekleyen oturum + bakim (bayat okuma OLMAMALI) --- }
  DeleteFile(marker);
  DeleteFile(marker + '.go');
  c := StartChild(['ro-hold', db, marker], 'ro-hold');
  ok := WaitForFile(marker, 10000);
  Chk('ML3a cocuk salt-okunur oturum acildi', ok, 'isaret=' +
    BoolToStr(ok, True));
  VdbOpen(db, be, False, True);
  try
    ok := TryCompact(be, err, o, n);
    { Bakim basarili da olabilir (Linux) reddedilmis de (Windows'ta
      rename acik handle yuzunden engellenir). Her iki durumda da veri
      butun olmali. }
    WriteLn('BILGI ML3 bakim ok=', BoolToStr(ok, True), ' hata=', err);
    ExecOn(be, 'INSERT INTO t (id, v) VALUES (101, ''satir-101'')');
    Chk('ML3b bakim sonrasi yeni satir yazildi', CountRows(be) = 101,
      'COUNT=' + IntToStr(CountRows(be)));
  finally
    be := nil;
  end;
  MarkerTouch(marker + '.go');
  rc := WaitChild(c, out1);
  { GUVENLI: ya hata ('degistirildi') ya da 101 (yeni veri).
    GUVENSIZ (bayat): 100 — oturum eski dosyayi okudu ve HABER VERMEDI. }
  Chk('ML3c bosta bekleyen oturum BAYAT veri okumadi',
    (rc = 0) and
    ((Pos('COUNT=101', out1) > 0) or (Pos('degistirildi', out1) > 0)),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));

  { --- ML4: ikinci surec kendi VACUUM'unu yapar --- }
  DeleteFile(marker);
  c := StartChild(['compact', db, marker], 'compact');
  rc := WaitChild(c, out1);
  Chk('ML4 ikinci surec VACUUM yapti',
    (rc = 0) and (Pos('CHILD compact OK', out1) > 0),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
  VdbOpen(db, be, False, True);
  try
    Chk('ML4b ikinci VACUUM satirlari korudu', CountRows(be) = 101,
      'COUNT=' + IntToStr(CountRows(be)));
    ok := be.Verify(rep);
    Chk('ML4c VERIFY temiz', ok, Copy(rep, 1, 160));
  finally
    be := nil;
  end;

  { --- ML5: bakim kalintisi yok --- }
  Chk('ML5 bakimdan sonra .tmp kalintisi kalmadi',
    CountArtifacts(d1, '*.tmp') = 0,
    'kalan=' + ListArtifacts(d1, '*.tmp'));

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
