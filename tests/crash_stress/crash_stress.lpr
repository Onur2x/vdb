program crash_stress;
{ SKILL8 (v3.83) - CRASH RECOVERY STRESS: 100 bagimsiz crash/reopen dongusu.

  Her dongu TEK KULLANIMLIK izole bir veritabani dizininde kosar; kullanicinin
  gercek DB dosyalarina ASLA dokunulmaz.

  Dongu:
    1. Temel DB olusturulur ve 20 anahtar COMMIT edilir.
    2. Cocuk surec ayni ikili ile calisir (`child <mode> <db> <stage>`):
       - uncommitted (%60): 10 anahtar commit edilir; ardindan YENI bir parti
         acilir, 10 anahtar yazilir ama COMMIT EDILMEZ; surec Close() cagirmadan
         zorla oldurulur (exit 9).
       - postcommit  (%20): 10 anahtar commit edilir; commit dondukten hemen
         sonra surec zorla oldurulur.
       - checkpoint  (%20): 10 anahtar commit edilir; checkpoint'in ICINDE
         (asama 1..5) zorla oldurulur.
    3. Ebeveyn yeniden acar ve dogrular:
       - cocuk gercekten exit 9 ile oldu mu,
       - VERIFY temiz mi,
       - commit edilmis toplam 30 anahtar DURUYOR mu,
       - commit edilmemis 10 anahtar YANLISLIKLA commit gorunmuyor mu
         (COUNT 30 ise gorunmuyor),
       - DB hala yazilabiliyor mu (ekleme sonrasi COUNT 31).

  Hedef 100 dongudur. Tamamlanamazsa TAM SAYI raporlanir; hedef sessizce
  dusurulmez. Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Process,
  VDbBackendApi, VDbFactory, VDbBackendV3, VDbPageEngine;

const
  BASE_ROWS = 20;
  ACK_ROWS = 10;
  EXPECTED = BASE_ROWS + ACK_ROWS;

type
  TBytes = array of Byte;

var
  GPass, GFail: Integer;
  GExe: string;
  GCrashCode: Integer = 9;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' - ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' - ', ADetail);
  end;
  Flush(Output);
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
  d: string;
begin
  ForceDirectories(ADir);
  d := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(d + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        if (sr.Attr and faDirectory) <> 0 then
          WipeDir(d + sr.Name)
        else
          SysUtils.DeleteFile(d + sr.Name);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ ---------------------------------------------------------------- cocuk --- }

procedure HardExitNow(ACode: Integer);
begin
  {$IFDEF WINDOWS}
  TerminateProcess(GetCurrentProcess, LongWord(ACode));
  {$ELSE}
  fpKill(fpGetPid, SIGKILL);
  {$ENDIF}
  Halt(ACode);
end;

procedure KillHook;
begin
  HardExitNow(GCrashCode);
end;

procedure RunChild(const AMode, APath: string; AStage: Integer);
var
  Be: IVdbBackend;
  k: Integer;
begin
  VdbOpen(APath, Be, False, True);
  try
    if AMode = 'uncommitted' then
    begin
      Be.BeginBatch;
      for k := 1 to ACK_ROWS do
        Be.Put(100 + k, MkVal(100 + k));
      Be.CommitBatch;
      { Commit edilmemis ikinci parti: surec bunu yazarken olecek. }
      Be.BeginBatch;
      for k := 1 to ACK_ROWS do
        Be.Put(200 + k, MkVal(200 + k));
      WriteLn('CHILD uncommitted batch acik, olduruluyor');
      Flush(Output);
      HardExitNow(GCrashCode);
    end
    else if AMode = 'postcommit' then
    begin
      Be.BeginBatch;
      for k := 1 to ACK_ROWS do
        Be.Put(100 + k, MkVal(100 + k));
      Be.CommitBatch;
      WriteLn('CHILD commit dondu, olduruluyor');
      Flush(Output);
      HardExitNow(GCrashCode);
    end
    else if AMode = 'checkpoint' then
    begin
      Be.BeginBatch;
      for k := 1 to ACK_ROWS do
        Be.Put(100 + k, MkVal(100 + k));
      Be.CommitBatch;
      (Be as TVdbBackendV3).Engine.CrashAtStage := AStage;
      (Be as TVdbBackendV3).Engine.OnCrashPoint := @KillHook;
      WriteLn('CHILD checkpoint asama=', AStage);
      Flush(Output);
      (Be as TVdbBackendV3).Engine.Checkpoint(True);
      WriteLn('CHILD SURVIVED');
      Flush(Output);
      Halt(3);
    end
    else
    begin
      WriteLn('CHILD bilinmeyen mod: ', AMode);
      Flush(Output);
      Halt(2);
    end;
  finally
    Be := nil;
  end;
end;

{ -------------------------------------------------------------- ebeveyn --- }

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
    AVerified := Be.Verify(AReport);
    if AVerified then
      Result := Be.Count;
  finally
    Be := nil;
  end;
end;

function ReopenCanWrite(const APath: string; AKey: Integer; out AReport: string): Boolean;
var
  Be: IVdbBackend;
  before, after: Integer;
begin
  Result := False;
  AReport := '';
  VdbOpen(APath, Be, False, True);
  try
    before := Be.Count;
    Be.BeginBatch;
    Be.Put(AKey, MkVal(AKey));
    Be.CommitBatch;
    after := Be.Count;
    Result := after = before + 1;
    AReport := Format('once=%d sonra=%d', [before, after]);
  finally
    Be := nil;
  end;
end;

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

function Killed(AExit: Integer): Boolean;
begin
  Result := (AExit = 9) or (AExit = -9);
end;

function RunCycle(AIdx: Integer; ACsv: TStringList): Boolean;
var
  mode, d, db, out1, rep: string;
  stage, rc, count, uncommittedPresent: Integer;
  verified, writable, ok: Boolean;
  P: TProcess;
begin
  mode := 'uncommitted';
  stage := 0;
  if (AIdx mod 5) = 3 then
    mode := 'postcommit'
  else if (AIdx mod 5) = 4 then
  begin
    mode := 'checkpoint';
    stage := 1 + (AIdx mod 5);
  end;

  d := IncludeTrailingPathDelimiter(TestDir + 'cs_' + IntToStr(AIdx));
  WipeDir(d);
  ForceDirectories(d);
  db := d + 'veritabani.odb';
  CreateBase(db, BASE_ROWS);

  P := StartChild(['child', mode, db, IntToStr(stage)]);
  try
    out1 := ReadPipe(P);
    P.WaitOnExit;
    rc := P.ExitStatus;
  finally
    P.Free;
  end;

  ok := Killed(rc);
  count := ReopenCount(db, rep, verified);
  uncommittedPresent := count - EXPECTED;
  writable := ReopenCanWrite(db, 5000, rep);

  ok := ok and verified and (count = EXPECTED) and writable;
  Chk(Format('C%d %s', [AIdx, mode]), ok,
    Format('rc=%d count=%d beklenen=%d verify=%s yazilabilir=%s',
      [rc, count, EXPECTED, BoolToStr(verified, 'yes', 'no'),
       BoolToStr(writable, 'yes', 'no')]));

  ACsv.Add(Format('%d,%s,%d,%d,%d,%d,%d,%s',
    [AIdx, mode, EXPECTED, count, uncommittedPresent,
     Ord(verified), Ord(writable), StringReplace(Trim(out1), ',', ';', [rfReplaceAll])]));
  Result := ok;
end;

{ ------------------------------------------------------------------ main --- }

var
  i, target: Integer;
  csv: TStringList;
  allOk: Boolean;
begin
  GPass := 0;
  GFail := 0;
  GExe := ParamStr(0);

  if (ParamCount >= 3) and (ParamStr(1) = 'child') then
  begin
    RunChild(ParamStr(2), ParamStr(3), StrToIntDef(ParamStr(4), 0));
    Exit;
  end;

  target := StrToIntDef(Trim(GetEnvironmentVariable('VDB_CRASH_CYCLES')), 100);
  if target < 1 then target := 1;
  WriteLn('BILGI crash_stress dongu hedefi=', target);
  Flush(Output);

  csv := TStringList.Create;
  try
    csv.Add('cycle,mode,expected_committed,actual,uncommitted_present,verified,writable,child_output');
    allOk := True;
    for i := 1 to target do
    begin
      if not RunCycle(i, csv) then
        allOk := False;
    end;
    csv.SaveToFile(IncludeTrailingPathDelimiter(TestDir) + 'crash_stress.csv');
    Chk('CS SONUC: tum donguler temiz', allOk, Format('%d dongu', [target]));
  finally
    csv.Free;
  end;

  WriteLn(Format('SONUC: %d PASS, %d FAIL', [GPass, GFail]));
  Flush(Output);
  Halt(GFail);
end.
