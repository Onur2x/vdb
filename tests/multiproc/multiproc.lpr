program multiproc;
{ SKILL2 §21.3 — SURELER-ARASI (multiprocess) kilitleme ve kurtarma kapisi.

  Skill'in kurali: "bu testler gecmeden coklu surec guvenligi iddia etme".
  Bu kapi, ayni veritabanini AYRI ISLETIM SISTEMI SURECLERINDEN acarak
  su iddialari kanitlar:

    MP1  Temiz kapanis tek dosya birakir (A davranisi bozulmadi).
    MP2  Baska surec salt-okunur acip dogru satiri okur.
    MP3  Iki okuyucu AYNI ANDA acik kalabilir (paylasimli kilit).
    MP4  Iki yazar oturumu AYNI ANDA acilabilir: yazma kilidi oturum
         basina degil ISLEM basina alinir (v3.16/v3.18 tasarim karari).
    MP5  Es zamanli yazar: bir surec yazip kapatirken acik kalan diger
         oturum bayat onbellegi TAZELER (gen sayaci) ve veri kaybi olmaz.
    MP6  Kapanistan sonra yeniden acilis ayni veriyi gorur.
    MP7  Yazar surec ANI OLUM (SIGKILL/TerminateProcess, Close() hic
         calismaz) sonrasi: onayli commit'ler kaybolmaz, kilit kalici
         bloklamaz, VERIFY temiz.
    MP8  Olum sonrasi baska surec yazip kapatabilir (kurtarma dongusu yok).
    MP9  Salt-okunur oturum yazma cagrisini ACIKCA reddeder.
    MP10 Tum bunlardan sonra temiz kapanis hala tek dosya birakir.

  Cocuk surecler bu ayni programdir; mod adi ParamStr(1) ile secilir.
  Boylece ayri bir yardimci ikili uretilmez.

  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Process, VDbFactory, VDbBackendApi, VDbTable, VDbSql,
  VDbErr;

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

function CountArtifacts(const ADir, ABase: string): Integer;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + ABase + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function ListArtifacts(const ADir, ABase: string): string;
var
  sr: TSearchRec;
  s: string;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + ABase + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        s := sr.Name;
        if (sr.Attr and faDirectory) <> 0 then s := s + '/';
        if Result <> '' then Result := Result + ', ';
        Result := Result + s;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ ------------------------------------------------------------------ }
{ Cocuk surec yardimcilari                                          }
{ ------------------------------------------------------------------ }

procedure HardExitNow(ACode: Integer);
begin
  { Amac: Close() HIC calismasin, isletim sistemi handle'lari kapatsin.
    Boylece "surec oldu" durumu gercekci olur (checkpoint/WAL budama yok). }
  Flush(Output);
{$IFDEF UNIX}
  fpKill(fpGetPid, SIGKILL);
  Sleep(2000);
  Halt(ACode);
{$ELSE}
  Flush(StdErr);
  TerminateProcess(GetCurrentProcess, LongWord(ACode));
  Halt(ACode);
{$ENDIF}
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

{ Cocuk modlari: ParamStr(1)=mod, (2)=db dosyasi, (3)=isaret dosyasi }
procedure RunChild(const AMode, ADb, AMarker: string);
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
  i: Integer;
  refused: Boolean;
  base: Integer;
begin
  if AMode = 'ro' then
  begin
    VdbOpenReadOnly(ADb, Be, 0, 0);
    try
      Tb := TVTableDb.CreateBackend(Be);
      try
        Tb.Open(ExtractFileDir(Be.FilePath));
        Sq := TVSql.Create(Tb);
        try
          R := Sq.Exec('SELECT COUNT(*) FROM t');
          WriteLn('CHILD ro COUNT=', R.Rows[0][0]);
        finally
          Sq.Free;
        end;
      finally
        Tb.Free;
      end;
    finally
      Be := nil;
    end;
    Exit;
  end;

  if AMode = 'ro-write' then
  begin
    VdbOpenReadOnly(ADb, Be, 0, 0);
    refused := False;
    try
      Tb := TVTableDb.CreateBackend(Be);
      try
        Tb.Open(ExtractFileDir(Be.FilePath));
        Sq := TVSql.Create(Tb);
        try
          try
            Sq.Exec('INSERT INTO t (id, v) VALUES (9001, ''x'')');
            WriteLn('CHILD ro-write UNEXPECTED-WRITE-SUCCEEDED');
          except
            on E: Exception do
            begin
              refused := True;
              WriteLn('CHILD ro-write REFUSED ', E.ClassName, ': ', E.Message);
            end;
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
    if not refused then
      Halt(3);
    Exit;
  end;

  if AMode = 'rw-open' then
  begin
    VdbOpen(ADb, Be, False, True);
    Be := nil;
    WriteLn('CHILD rw-open RWOPEN');
    Exit;
  end;

  if AMode = 'rw-hold' then
  begin
    VdbOpen(ADb, Be, False, True);
    MarkerTouch(AMarker);
    WriteLn('CHILD rw-hold LOCKED');
    Flush(Output);
    Sleep(900);
    Be := nil;
    WriteLn('CHILD rw-hold RELEASED');
    Exit;
  end;

  if (AMode = 'write') or (AMode = 'write2') then
  begin
    if AMode = 'write' then base := 201 else base := 401;
    VdbOpen(ADb, Be, False, True);
    try
      Tb := TVTableDb.CreateBackend(Be);
      try
        Tb.Open(ExtractFileDir(Be.FilePath));
        Sq := TVSql.Create(Tb);
        try
          for i := base to base + 2 do
            Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) +
              ', ''satir-' + IntToStr(i) + ''')');
          R := Sq.Exec('SELECT COUNT(*) FROM t');
          WriteLn('CHILD ', AMode, ' COUNT=', R.Rows[0][0]);
        finally
          Sq.Free;
        end;
      finally
        Tb.Free;
      end;
    finally
      Be := nil;   { temiz kapanis }
    end;
    Exit;
  end;

  if AMode = 'crash' then
  begin
    VdbOpen(ADb, Be, False, True);
    Tb := TVTableDb.CreateBackend(Be);
    Tb.Open(ExtractFileDir(Be.FilePath));
    Sq := TVSql.Create(Tb);
    for i := 301 to 305 do
      Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''satir-' +
        IntToStr(i) + ''')');
    R := Sq.Exec('SELECT COUNT(*) FROM t');
    WriteLn('CHILD crash COMMITTED COUNT=', R.Rows[0][0]);
    Flush(Output);
    { BILEREK serbest birakma yok: Close() calismayacak. }
    HardExitNow(77);
  end;

  WriteLn('CHILD bilinmeyen mod: ', AMode);
  Halt(2);
end;

{ ------------------------------------------------------------------ }
{ Ebeveyn: cocuk kosumu                                              }
{ ------------------------------------------------------------------ }

procedure AddArgs(P: TProcess; const AArgs: array of string);
var
  i: Integer;
begin
  for i := Low(AArgs) to High(AArgs) do
    P.Parameters.Add(AArgs[i]);
end;

type
  TChild = record
    P: TProcess;
    Mode: string;
  end;

function StartChild(const AArgs: array of string; const AMode: string): TChild;
begin
  Result.Mode := AMode;
  Result.P := TProcess.Create(nil);
  Result.P.Executable := GExe;
  AddArgs(Result.P, AArgs);
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

function RunChildSync(const AArgs: array of string; out AOut: string): Integer;
var
  C: TChild;
begin
  C := StartChild(AArgs, AArgs[0]);
  Result := WaitChild(C, AOut);
end;

function WaitForFile(const APath: string; AMs: Integer): Boolean;
var
  t0: QWord;
begin
  Result := True;
  if FileExists(APath) then Exit;
  t0 := GetTickCount64;
  while (GetTickCount64 - t0) < QWord(AMs) do
  begin
    Sleep(20);
    if FileExists(APath) then Exit;
  end;
  Result := False;
end;

{ ------------------------------------------------------------------ }
{ Ebeveyn: veritabani yardimcilari                                   }
{ ------------------------------------------------------------------ }

function OpenRw(const APath: string; out ABe: IVdbBackend): Boolean;
begin
  Result := False;
  try
    VdbOpen(APath, ABe, False, True);
    Result := True;
  except
    on E: Exception do
    begin
      ABe := nil;
      WriteLn('  acilamadi: ', E.ClassName, ': ', E.Message);
    end;
  end;
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

{ Ebeveyn oturumu UZERINDEN tek SQL calistirir (oturum acik kalir). }
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

var
  d1, db, marker: string;
  be, be2: IVdbBackend;
  tb: TVTableDb;
  sq: TVSql;
  i, rc: Integer;
  out1: string;
  c: TChild;
  opened: Boolean;
  rep: string;
begin
  { Cocuk modu ise buradan devam et, ebeveyn akisina girme. }
  if (ParamCount >= 1) and (ParamStr(1) <> '') then
  begin
    RunChild(ParamStr(1), ParamStr(2), ParamStr(3));
    Exit;
  end;

  GPass := 0;
  GFail := 0;
  GExe := ExpandFileName(ParamStr(0));
  ForceDirectories(TestDir);

  d1 := IncludeTrailingPathDelimiter(TestDir + 'mp_a');
  WipeDir(d1);
  ForceDirectories(d1);
  marker := IncludeTrailingPathDelimiter(TestDir + 'mp_lock.tmp');

  WriteLn('BILGI cocuk ikili: ', GExe);

  { --- MP1: kaynak veritabani --- }
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
  Chk('MP1 temiz kapanis tek dosya birakti',
    CountArtifacts(d1, 'veritabani') = 1,
    'artefakt=' + ListArtifacts(d1, 'veritabani'));

  { --- MP2: baska surec salt-okunur okur --- }
  rc := RunChildSync(['ro', db], out1);
  Chk('MP2 baska surec salt-okunur okudu',
    (rc = 0) and (Pos('CHILD ro COUNT=100', out1) > 0),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));

  { --- MP3: iki okuyucu ayni anda --- }
  { Ebeveyn salt-okunur (paylasimli kilit) tutarken cocuk da okuyabilmeli. }
  opened := False;
  try
    VdbOpenReadOnly(db, be, 0, 0);
    opened := True;
  except
    on E: Exception do
      Chk('MP3 ebeveyn salt-okunur acilisi', False, E.ClassName + ': ' + E.Message);
  end;
  if opened then
  begin
    rc := RunChildSync(['ro', db], out1);
    Chk('MP3 iki okuyucu ayni anda acik kaldi',
      (rc = 0) and (Pos('CHILD ro COUNT=100', out1) > 0),
      'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
    be := nil;
  end;

  { --- MP4: iki yazar oturumu AYNI ANDA acilabilir ---
    Tasarim karari (v3.16/v3.18): yazma kilidi oturum basina degil, ISLEM
    basina alinir. Bu yuzden ikinci yazar oturumu reddedilmez; guvenlik
    kisa exclusive kilit + `.gen` sayaci + RefreshIfStaleForce ile saglanir.
    Asil kanit MP5'tedir (bayat onbellek tazeleniyor). }
  if OpenRw(db, be) then
  begin
    rc := RunChildSync(['rw-open', db], out1);
    Chk('MP4 iki yazar oturumu ayni anda acilabilir (kilit islem basina)',
      (rc = 0) and (Pos('RWOPEN', out1) > 0),
      'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
    be := nil;
  end
  else
    Chk('MP4 iki yazar oturumu ayni anda acilabilir (kilit islem basina)',
      False, 'ebeveyn yazma acilamadi');

  { --- MP5: ES ZAMANLI YAZAR + BAYAT ONBELLEK ---
    Ebeveyn yazabilir acik kalir (onbellegi dolu). Cocuk surec 201..203
    yazar ve kapanir. Ebeveyn HALA ACIKKEN saymali ve 103 gormeli: bu,
    `.gen` sayaci + RefreshIfStaleForce'un bayat onbellegi tazeledigini
    kanitlar. Sonra ebeveyn 204..205 yazar; veri kaybi olmamali. }
  if OpenRw(db, be) then
  begin
    Chk('MP5 ebeveyn baslangic sayimi', CountRows(be) = 100,
      'COUNT=' + IntToStr(CountRows(be)));
    rc := RunChildSync(['write', db], out1);
    Chk('MP5b cocuk yazar baska oturumda yazdi',
      (rc = 0) and (Pos('CHILD write COUNT=103', out1) > 0),
      'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
    Chk('MP5c ebeveyn ACIKKEN cocugun commitlerini gordu (bayat onbellek tazelendi)',
      CountRows(be) = 103, 'COUNT=' + IntToStr(CountRows(be)) + ' beklenen=103');
    ExecOn(be, 'INSERT INTO t (id, v) VALUES (204, ''satir-204'')');
    ExecOn(be, 'INSERT INTO t (id, v) VALUES (205, ''satir-205'')');
    Chk('MP5d iki yazar ardisik yazdi, veri kaybi yok', CountRows(be) = 105,
      'COUNT=' + IntToStr(CountRows(be)) + ' beklenen=105');
    be := nil;
  end
  else
  begin
    Chk('MP5 ebeveyn baslangic sayimi', False, 'ebeveyn yazma acilamadi');
    Chk('MP5b cocuk yazar baska oturumda yazdi', False, 'ebeveyn yazma acilamadi');
    Chk('MP5c ebeveyn ACIKKEN cocugun commitlerini gordu (bayat onbellek tazelendi)',
      False, 'ebeveyn yazma acilamadi');
    Chk('MP5d iki yazar ardisik yazdi, veri kaybi yok', False, 'ebeveyn yazma acilamadi');
  end;

  { --- MP6: kapanistan sonra yeniden acilis ayni veriyi gorur --- }
  if OpenRw(db, be) then
  begin
    Chk('MP6 kapanistan sonra yeniden acilis tutarli', CountRows(be) = 105,
      'COUNT=' + IntToStr(CountRows(be)));
    be := nil;
  end
  else
    Chk('MP6 kapanistan sonra yeniden acilis tutarli', False, 'acilamadi (kalici blok?)');

  { --- MP7: yazar surec ANI OLUM -> commit kaybi yok, kilit kalmaz --- }
  rc := RunChildSync(['crash', db], out1);
  Chk('MP7 cocuk ani oldu (Close calismadi)',
    (rc <> 0) and (Pos('CHILD crash COMMITTED COUNT=110', out1) > 0),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
  if OpenRw(db, be) then
  begin
    Chk('MP7b olum sonrasi kilit kalici bloklamadi', True, 'acildi');
    Chk('MP7c ani olum sonrasi onayli commitler korundu', CountRows(be) = 110,
      'COUNT=' + IntToStr(CountRows(be)) + ' beklenen=110');
    rep := '';
    Chk('MP7d olum sonrasi VERIFY temiz', be.Verify(rep), 'rapor=' + rep);
    be := nil;
  end
  else
  begin
    Chk('MP7b olum sonrasi kilit kalici bloklamadi', False, 'acilamadi');
    Chk('MP7c ani olum sonrasi onayli commitler korundu', False, 'acilamadi');
  end;

  { --- MP8: olum sonrasi baska surec yazip kapatabilir --- }
  rc := RunChildSync(['write2', db], out1);
  Chk('MP8 olum sonrasi baska surec yazdi',
    (rc = 0) and (Pos('CHILD write2 COUNT=113', out1) > 0),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
  if OpenRw(db, be) then
  begin
    Chk('MP8b kurtarma dongusu yok (satirlar kalici)', CountRows(be) = 113,
      'COUNT=' + IntToStr(CountRows(be)) + ' beklenen=113');
    be := nil;
  end
  else
    Chk('MP8b kurtarma dongusu yok (satirlar kalici)', False, 'acilamadi');

  { --- MP9: salt-okunur oturum yazmayi reddeder --- }
  rc := RunChildSync(['ro-write', db], out1);
  Chk('MP9 salt-okunur oturum yazmayi reddetti',
    (rc = 0) and (Pos('REFUSED', out1) > 0),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));

  { --- MP10: hala tek dosya --- }
  Chk('MP10 temiz kapanis hala tek dosya birakti',
    CountArtifacts(d1, 'veritabani') = 1,
    'artefakt=' + ListArtifacts(d1, 'veritabani'));

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
