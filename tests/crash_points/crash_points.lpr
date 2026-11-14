program crash_points;
{ SKILL2 §19.2: DETERMINISTIK cokme noktalari.

Eski kapi (`wal_crash`) surec olumunu yalnizca islem sinirinda
(`SimulateCrash`) taklit ediyordu. Bu kapi, checkpoint ve commit'in ICINE
konan enjeksiyon noktalarinda sureci GERCEKTEN oldurur (SIGKILL /
TerminateProcess; Close() hic calismaz) ve ardindan:

  (a) dosya yeniden acilabiliyor mu,
  (b) VERIFY temiz mi,
  (c) onaylanmis commit'ler duruyor mu,
  (d) DB hala yazilabilir mi

sorularini yanitlar.

Cokme noktalari (VDbPageEngine):
  1 CP_BEGIN         checkpoint basi, hicbir sey yazilmadi
  2 CP_BEFORE_FLUSH  pending kuruldu, sayfa yazimi baslamadi
  3 CP_AFTER_FLUSH   sayfalar diske indi, WAL budanmadi
  4 CP_AFTER_TRUNC   WAL budandi, durabil LSN yazilmadi
  5 CP_DONE          checkpoint tamamlandi (kontrol grubu)
  6 COMMIT_PRE_SYNC  commit kaydi WAL'de, fsync yok
  7 COMMIT_POST_SYNC commit durabil (fsync basarili)

Beklenti:
  - 1..5 ve 7: 30 satir (onaylanmis commit kaybolmaz)
  - 6        : 20 veya 30 (fsync yok; kayip SERBEST, tutarsizlik YASAK)

Cocuk surec olarak ayni ikili calisir: `crash_points child <mod> <db> <stage>`.
Cikis kodu cocukta 9 (olduruldu), ebeveynde 0 (tum kontroller gecti). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, StrUtils, Process,
  VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine, VDbPageHeap;

var
  GPass, GFail: Integer;
  GExe: string;
  GCrashCode: Integer = 9;

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

{ ------------------------------------------------------------------ }
{ Cocuk surec: gercek surec olumu. Close/Destroy/finalization CALISMAZ. }

procedure HardExitNow(ACode: Integer);
begin
  {$IFDEF WINDOWS}
  TerminateProcess(GetCurrentProcess, LongWord(ACode));
  {$ELSE}
  fpKill(fpGetPid, SIGKILL);
  {$ENDIF}
  Halt(ACode);   { ulasilmamali }
end;

procedure KillHook;
begin
  HardExitNow(GCrashCode);
end;

function MkVal(AKey: Integer): TBytes;
var
  s: AnsiString;
begin
  s := 'satir-' + IntToStr(AKey);
  SetLength(Result, Length(s));
  if Length(s) > 0 then
    Move(s[1], Result[0], Length(s));
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

function ListArtifacts(const ADir: string): string;
var
  sr: TSearchRec;
  s: string;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
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
{ Cocuk modu. }

procedure RunChild(const AMode, APath: string; AStage: Integer);
var
  Eng: TVdbBackendV3;
  Be: IVdbBackend;
  k: Integer;
begin
  Eng := TVdbBackendV3.Create(APath, False);
  Be := Eng;
  if AMode = 'cp' then
  begin
    { Once checkpoint edilecek malzeme uret: 21..30 onayli commit. }
    Be.BeginBatch;
    for k := 21 to 30 do
      Be.Put(k, MkVal(k));
    Be.CommitBatch;
    Eng.Engine.CrashAtStage := AStage;
    Eng.Engine.OnCrashPoint := @KillHook;
    Eng.Engine.Checkpoint(True);
  end
  else
  begin
    Eng.Engine.CrashAtStage := AStage;
    Eng.Engine.OnCrashPoint := @KillHook;
    Be.BeginBatch;
    for k := 21 to 30 do
      Be.Put(k, MkVal(k));
    Be.CommitBatch;
  end;
  { Buraya gelindiyse enjeksiyon calismadi: acik hata. }
  WriteLn('CHILD SURVIVED mode=', AMode, ' stage=', AStage);
  Flush(Output);
  Halt(3);
end;

{ ------------------------------------------------------------------ }
{ Ebeveyn yardimcilari. }

function StartChild(const AArgs: array of string): TProcess;
var
  i: Integer;
begin
  Result := TProcess.Create(nil);
  Result.Executable := GExe;
  for i := Low(AArgs) to High(AArgs) do
    Result.Parameters.Add(AArgs[i]);
  Result.Options := [poUsePipes, poStderrToOutput];
  Result.Execute;
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

function RunChildSync(const AMode, APath: string; AStage: Integer;
  out AOut: string): Integer;
var
  P: TProcess;
begin
  P := StartChild(['child', AMode, APath, IntToStr(AStage)]);
  try
    AOut := ReadPipe(P);
    P.WaitOnExit;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

function Killed(AExit: Integer): Boolean;
begin
  Result := (AExit = 9) or (AExit = -9);
end;

procedure CreateBase(const APath: string; ARows: Integer);
var
  Be: IVdbBackend;
  k: Integer;
begin
  VdbOpen(APath, Be, True, True);
  try
    Be.BeginBatch;
    for k := 1 to ARows do
      Be.Put(k, MkVal(k));
    Be.CommitBatch;
  finally
    Be := nil;
  end;
end;

function ReopenCount(const APath: string; out AReport: string;
  out AVerified: Boolean): Integer;
var
  Be: IVdbBackend;
begin
  Result := -1;
  AReport := '';
  AVerified := False;
  VdbOpen(APath, Be, False, True);
  try
    { Verify basarili oldugunda rapor BOS DEGILDIR: sayfa/anahtar sayimi
      dondurur, hata metni degil. Bu yuzden hukum bayrakla verilir. }
    AVerified := Be.Verify(AReport);
    if AVerified then
      Result := Be.Count;
  finally
    Be := nil;
  end;
end;

function ReopenCanWrite(const APath: string; AKey: Integer): Boolean;
var
  Be: IVdbBackend;
begin
  Result := False;
  VdbOpen(APath, Be, False, True);
  try
    Be.BeginBatch;
    Be.Put(AKey, MkVal(AKey));
    Be.CommitBatch;
    Result := True;
  finally
    Be := nil;
  end;
end;

{ ------------------------------------------------------------------ }

var
  d, db, out1, rep: string;
  rc: Integer;
  verified: Boolean;

procedure RunStage(const AStage: Integer; const AMode: string;
  AAllowed: array of Integer);
var
  count: Integer;
  okAllowed: Boolean;
  i: Integer;
  tag: string;
begin
  tag := AMode + '-' + IntToStr(AStage);
  { Her asama TEMIZ bir veritabaniyla denenir; aksi halde onceki asamanin
    satirlari sonraki asamanin beklentisini kirletir. }
  d := IncludeTrailingPathDelimiter(TestDir + 'cp_' + tag);
  WipeDir(d);
  ForceDirectories(d);
  db := d + 'veritabani.odb';
  CreateBase(db, 20);
  rc := RunChildSync(AMode, db, AStage, out1);
  Chk('CP ' + tag + '/killed', Killed(rc),
    'rc=' + IntToStr(rc) + ' cikti=' + Trim(out1));
  count := ReopenCount(db, rep, verified);
  okAllowed := False;
  for i := Low(AAllowed) to High(AAllowed) do
    if count = AAllowed[i] then okAllowed := True;
  Chk('CP ' + tag + '/count', okAllowed,
    'COUNT=' + IntToStr(count) + ' beklenen=' + IntToStr(AAllowed[0]) +
    (IfThen(Length(AAllowed) > 1, ' veya ' + IntToStr(AAllowed[High(AAllowed)]), '')));
  Chk('CP ' + tag + '/verify', verified, 'verify=' + rep);
  WriteLn('BILGI ' + tag + ' artefaktlar: ' + ListArtifacts(d));
end;

begin
  GExe := ParamStr(0);
  if (ParamCount >= 3) and (ParamStr(1) = 'child') then
  begin
    RunChild(ParamStr(2), ParamStr(3), StrToIntDef(ParamStr(4), 0));
    Exit;
  end;

  GPass := 0;
  GFail := 0;
  d := IncludeTrailingPathDelimiter(TestDir + 'cp');
  WipeDir(d);
  ForceDirectories(d);
  db := d + 'veritabani.odb';

  CreateBase(db, 20);
  Chk('CP0 taban olustu', True, '20 satir');

  { Checkpoint icinde kesme: onayli commit korunmali. }
  RunStage(1, 'cp', [30]);
  RunStage(2, 'cp', [30]);
  RunStage(3, 'cp', [30]);
  RunStage(4, 'cp', [30]);
  RunStage(5, 'cp', [30]);

  { Commit icinde kesme.
    Stage 6: fsync YOK -> commit kaybi serbest (20 veya 30), tutarsizlik yasak.
    Stage 7: fsync VAR  -> commit DURABIL, 30 sart. }
  RunStage(6, 'commit', [20, 30]);
  RunStage(7, 'commit', [30]);

  { Kurtarilan DB hala yazilabilir mi? }
  Chk('CP-W yazma calisiyor', ReopenCanWrite(db, 101), 'anahtar 101');
  rc := ReopenCount(db, rep, verified);
  Chk('CP-W yazma sonrasi sayim', (rc = 31) and verified,
    'COUNT=' + IntToStr(rc) + ' verify=' + rep);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
