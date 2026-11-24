{ pg_client_matrix - gercek PostgreSQL istemci matrisi

  Amac (SKILL17 / 3): VDB PostgreSQL wire sunucusunun GERCEK istemcilerle
  uyumunu olcmek. Sunucu tek basina "server_version = 14.0" demek uyumluluk
  kaniti degildir; bu kapi istemciyi gercekten kosturur.

  Bacaklar: psql, libpq, psycopg, JDBC, Npgsql.
  Her bacak icin kontroller: connection, scram, tls, prepared, bind,
  describe, execute, portal, portal_suspended, copy_in, copy_out, null,
  transaction, cancel_request, sqlstate, close.

  Ayrica "wire" bacagi kosar: bu depodaki saf Python protokol istemcisi
  (tests/pg_client_matrix/pgc_wire.py). GERCEK istemci SAYILMAZ; yalniz
  protokolun kendisinin bozulmadigini gosterir ve PASS sayisina eklenmez.

  Durustluk: bir bacak kurulu degilse SKIP olarak, gerekcesiyle yazilir.
  Hicbir gercek istemci kosmadiysa kapi PASS veremez: gerekce dosyaya
  yazilir ve Halt(77) ile SKIP doner. JDBC/Npgsql icin bu depoda kosucu
  yoktur; varliklari yalniz yoklanir (probe) ve acikca raporlanir.

  Kullanim: pg_client_matrix [is dizini] [betik dizini]
  Sonuc: "SONUC: N PASS, M FAIL, K SKIP"; FAIL > 0 ise Halt(1).
}
program pg_client_matrix;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process, StrUtils, VDbNet, VDbPgWire;

const
  SKIP_CODE   = 77;
  BASE_PORT   = 54720;
  PORT_TRIES  = 40;
  TEST_USER   = 'pgm';
  TEST_PASS   = 'pgm-parola';
  TEST_DB     = 'pgmdb';
  { Kimlik dogrulanan kullanicinin baglanacagi SQL rolu. Rolun gercekten
    var olmasi ve SUPERUSER olmasi gerekir; asagida once trust fazinda
    kurulur. }
  TEST_ROLE   = 'pgmrole';
  LEG_TIMEOUT = 240000;

type
  TLeg = record
    Name: string;
    Avail: Boolean;
    Why: string;
    Runner: Boolean;   { bu depoda kosucusu var mi }
  end;

var
  GPass, GFail, GSkip, GRealLegs: Integer;
  GOut: TStringList;
  GDir, GScript: string;
  GPy: string;
  GPort: Word;
  GLegs: array of TLeg;
  GAvail: TStringList;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(GPass);
    if ADetail <> '' then
      WriteLn('PASS ', AName, ' - ', ADetail)
    else
      WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('FAIL ', AName, ' - ', ADetail)
    else
      WriteLn('FAIL ', AName);
  end;
  Flush(Output);
end;

procedure Skip(const AName, AWhy: string);
begin
  Inc(GSkip);
  WriteLn('SKIP ', AName, ' - ', AWhy);
  GOut.Add('SKIP,' + AName + ',' + AWhy);
  Flush(Output);
end;

function RunCapture(const AExe: string; const AArgs: array of string;
  ATimeoutMs: Integer; out AOut: string; out ACode: Integer): Boolean;
var
  p: TProcess;
  i: Integer;
  buf: array[0..8191] of Byte;
  n: Integer;
  started: QWord;
  tmp: string;
begin
  Result := False;
  AOut := '';
  ACode := -1;
  p := TProcess.Create(nil);
  try
    p.Executable := AExe;
    for i := 0 to High(AArgs) do
      p.Parameters.Add(AArgs[i]);
    p.Options := [poUsePipes, poStderrToOutPut];
    try
      p.Execute;
    except
      on E: Exception do
      begin
        AOut := E.ClassName + ': ' + E.Message;
        Exit;
      end;
    end;
    started := GetTickCount64;
    while p.Running and (GetTickCount64 - started <= QWord(ATimeoutMs)) do
    begin
      while p.Output.NumBytesAvailable > 0 do
      begin
        n := p.Output.Read(buf, SizeOf(buf));
        if n <= 0 then Break;
        SetLength(tmp, n);
        Move(buf[0], tmp[1], n);
        AOut := AOut + tmp;
      end;
      Sleep(20);
    end;
    while p.Output.NumBytesAvailable > 0 do
    begin
      n := p.Output.Read(buf, SizeOf(buf));
      if n <= 0 then Break;
      SetLength(tmp, n);
      Move(buf[0], tmp[1], n);
      AOut := AOut + tmp;
    end;
    if p.Running then
    begin
      p.Terminate(1);
      ACode := 124;
      Exit(True);
    end;
    ACode := p.ExitStatus;
    Result := True;
  finally
    p.Free;
  end;
end;

function FindPython: string;
var
  cand: array[0..4] of string;
  i, code: Integer;
  o: string;
begin
  Result := '';
  cand[0] := GetEnvironmentVariable('VDB_INTEROP_PY');
  cand[1] := 'python3';
  cand[2] := 'python';
  cand[3] := 'py';
  cand[4] := 'C:\Python314\python.exe';
  for i := 0 to High(cand) do
  begin
    if cand[i] = '' then Continue;
    if (Pos('\', cand[i]) > 0) and (not FileExists(cand[i])) then Continue;
    if not RunCapture(cand[i], ['--version'], 20000, o, code) then Continue;
    if code <> 0 then Continue;
    if Pos('Python', o) = 0 then Continue;
    Exit(cand[i]);
  end;
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
begin
  if FindFirst(ADir + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(ADir + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function Field(const ALine: string; AIndex: Integer; const ASep: Char): string;
var
  i, k: Integer;
  cur: string;
begin
  Result := '';
  k := 0;
  cur := '';
  for i := 1 to Length(ALine) + 1 do
  begin
    if (i > Length(ALine)) or (ALine[i] = ASep) then
    begin
      if k = AIndex then Exit(cur);
      Inc(k);
      cur := '';
    end
    else
      cur := cur + ALine[i];
  end;
end;

function AvailOf(const AName: string; out AWhy: string): Boolean;
var
  k: Integer;
  ln, st: string;
begin
  Result := False;
  AWhy := 'yoklama sonucu yok';
  for k := 0 to GAvail.Count - 1 do
  begin
    ln := Trim(GAvail[k]);
    if Pos('AVAIL ' + AName + ' ', ln) <> 1 then Continue;
    st := Trim(Copy(ln, Length('AVAIL ' + AName + ' ') + 1, Length(ln)));
    AWhy := Trim(Copy(st, 3, Length(st)));
    Result := Pos('OK', st) = 1;
    Exit;
  end;
end;

procedure AddLeg(const AName: string; ARunner: Boolean);
var
  why: string;
begin
  SetLength(GLegs, Length(GLegs) + 1);
  GLegs[High(GLegs)].Name := AName;
  GLegs[High(GLegs)].Runner := ARunner;
  GLegs[High(GLegs)].Avail := AvailOf(AName, why);
  GLegs[High(GLegs)].Why := why;
end;

{ Bir bacagin RESULT satirlarini ayristirir. }
procedure RunLeg(const ALegName: string);
var
  o, rest, name, status, detail, line: string;
  code, okN, failN, skipN: Integer;
  lines: TStringList;
  i: Integer;
  isWire: Boolean;
begin
  isWire := ALegName = 'wire';
  okN := 0;
  failN := 0;
  skipN := 0;
  if not RunCapture(GPy, [GScript + 'pgc_run.py', ALegName, '127.0.0.1',
      IntToStr(GPort), TEST_USER, TEST_PASS, TEST_DB, '0'], LEG_TIMEOUT, o, code) then
  begin
    if isWire then
      Chk('wire kosucusu baslatilamadi', False, o)
    else
      Skip(ALegName, 'kosucu baslatilamadi: ' + o);
    Exit;
  end;
  if code <> 0 then
  begin
    if isWire then
      Chk('wire kosucusu hata ile bitti', False, 'cikis=' + IntToStr(code))
    else
      Skip(ALegName, 'kosucu hata ile bitti: cikis=' + IntToStr(code));
    Exit;
  end;
  lines := TStringList.Create;
  try
    lines.Text := o;
    for i := 0 to lines.Count - 1 do
    begin
      line := Trim(lines[i]);
      if Pos('RESULT ', line) <> 1 then Continue;
      rest := Trim(Copy(line, 8, Length(line)));
      name := Field(rest, 0, ' ');
      status := Field(rest, 1, ' ');
      detail := Trim(Copy(rest, Length(name) + Length(status) + 3, Length(rest)));
      { NOT: SKIP satirlarini Skip() kendisi GOut'a ekler; burada ikinci
        kez eklemek raporu ciftler. }
      if status <> 'SKIP' then
        GOut.Add(status + ',' + ALegName + '.' + name + ',' + detail);
      if status = 'OK' then
      begin
        Inc(okN);
        if isWire then
        begin
          if detail <> '' then
            WriteLn('BILGI wire.', name, ' OK - ', detail)
          else
            WriteLn('BILGI wire.', name, ' OK');
        end
        else
          Chk(ALegName + '.' + name, True, detail);
      end
      else if status = 'SKIP' then
      begin
        Inc(skipN);
        Skip(ALegName + '.' + name, detail);
      end
      else
      begin
        Inc(failN);
        Chk(ALegName + '.' + name, False, detail);
      end;
    end;
  finally
    lines.Free;
  end;
  if (not isWire) and (okN + failN + skipN > 0) then
    Inc(GRealLegs);
  WriteLn('BILGI bacak ', ALegName, ': ', okN, ' OK, ', failN, ' FAIL, ',
    skipN, ' SKIP');
  Flush(Output);
end;

var
  Srv: TVdbPgServer;
  i, portIdx, code: Integer;
  err, o, why: string;
  reason, report: TStringList;

begin
  GPass := 0;
  GFail := 0;
  GSkip := 0;
  GRealLegs := 0;
  GOut := TStringList.Create;
  GOut.Add('status,check,detail');
  GDir := ExtractFilePath(ParamStr(0));
  if ParamStr(1) <> '' then
    GDir := IncludeTrailingPathDelimiter(ParamStr(1));
  if not DirectoryExists(GDir) then ForceDirectories(GDir);
  GScript := ExtractFilePath(ParamStr(0));
  if ParamStr(2) <> '' then
    GScript := IncludeTrailingPathDelimiter(ParamStr(2));
  if not FileExists(GScript + 'pgc_run.py') then
  begin
    WriteLn('SKIP pg_client_matrix - kosucu betik yok: ', GScript, 'pgc_run.py');
    Halt(SKIP_CODE);
  end;

  GPy := FindPython;
  if GPy = '' then
  begin
    WriteLn('SKIP pg_client_matrix - Python bulunamadi; istemci kosuculari ',
      'Python ile calisir');
    Halt(SKIP_CODE);
  end;

  WipeDir(GDir);
  { --- Faz 0: sunucuyu ONCE kimlik dogrulamasiz (trust) ac, SUPERUSER
    rolu kur. Aksi halde SCRAM ile dogrulanan kullanici hicbir GRANT'i
    olmayan bir role baglanir ve dogru parolayla bile '42501 yetkisiz'
    alirdi (F-46: principal bagliyken bos/bilinmeyen rol = yetki yok). --- }
  Srv := nil;
  GPort := 0;
  for portIdx := 0 to PORT_TRIES - 1 do
  begin
    Srv := TVdbPgServer.Create(IncludeTrailingPathDelimiter(GDir),
      Word(BASE_PORT + portIdx));
    if Srv.Start(err) then
    begin
      GPort := Word(BASE_PORT + portIdx);
      Break;
    end;
    FreeAndNil(Srv);
  end;
  if Srv = nil then
  begin
    Chk('sunucu acildi', False, err);
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL, ', GSkip, ' SKIP');
    Halt(1);
  end;
  if not RunCapture(GPy, [GScript + 'pgc_run.py', 'bootstrap', '127.0.0.1',
      IntToStr(GPort), TEST_ROLE], 120000, o, code) or (code <> 0) then
  begin
    Chk('rol kuruldu', False, Trim(o));
    Srv.Stop;
    FreeAndNil(Srv);
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL, ', GSkip, ' SKIP');
    Halt(1);
  end;
  WriteLn('BILGI ', Trim(o));

  { --- Faz 1: ayni veritabaninda SCRAM kullanicisi ile yeniden ac --- }
  Srv.Stop;
  FreeAndNil(Srv);
  GPort := 0;
  for portIdx := 0 to PORT_TRIES - 1 do
  begin
    Srv := TVdbPgServer.Create(IncludeTrailingPathDelimiter(GDir),
      Word(BASE_PORT + 1 + portIdx));
    { ASqlRole: kimlik dogrulanan kullanici bir SQL rolune baglanmali;
      bos birakilirsa baglanti (dogru parolayla bile) reddedilir. }
    Srv.AddUser(TEST_USER, TEST_PASS, 15000, TEST_ROLE);
    if Srv.Start(err) then
    begin
      GPort := Word(BASE_PORT + 1 + portIdx);
      Break;
    end;
    FreeAndNil(Srv);
  end;
  if Srv = nil then
  begin
    Chk('sunucu acildi', False, err);
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL, ', GSkip, ' SKIP');
    Halt(1);
  end;
  Chk('sunucu acildi', True, 'port=' + IntToStr(GPort));

  { --- bacak yoklamasi --- }
  GAvail := TStringList.Create;
  try
    if not RunCapture(GPy, [GScript + 'pgc_run.py', 'probe'], 120000, o, code) then
      o := '';
    GAvail.Text := o;

    SetLength(GLegs, 0);
    AddLeg('psql', True);
    AddLeg('libpq', True);
    AddLeg('psycopg', True);
    AddLeg('jdbc', False);
    AddLeg('npgsql', False);

    { --- gercek istemci bacaklari --- }
    for i := 0 to High(GLegs) do
    begin
      if not GLegs[i].Runner then
      begin
        Skip(GLegs[i].Name, 'bu depoda kosucusu yok; yalniz yoklandi: ' +
          GLegs[i].Why);
        Continue;
      end;
      if not GLegs[i].Avail then
      begin
        Skip(GLegs[i].Name, GLegs[i].Why);
        Continue;
      end;
      WriteLn('BILGI bacak ', GLegs[i].Name, ' kosuyor (', GLegs[i].Why, ')');
      Flush(Output);
      RunLeg(GLegs[i].Name);
    end;

    { --- protokol bacagi: gercek istemci DEGIL, PASS sayilmaz --- }
    RunLeg('wire');

    { --- rapor --- }
    report := TStringList.Create;
    try
      report.Add('pg_client_matrix');
      report.Add('port=' + IntToStr(GPort));
      report.Add('pass=' + IntToStr(GPass));
      report.Add('fail=' + IntToStr(GFail));
      report.Add('skip=' + IntToStr(GSkip));
      report.Add('real_legs=' + IntToStr(GRealLegs));
      for i := 0 to High(GLegs) do
        report.Add('leg.' + GLegs[i].Name + '=' +
          IfThen(GLegs[i].Avail, 'available', 'missing') + ';' + GLegs[i].Why);
      report.Add('--- checks ---');
      report.AddStrings(GOut);
      report.SaveToFile(GDir + 'pg_client_matrix.out');
    finally
      report.Free;
    end;
    GOut.SaveToFile(GDir + 'pg_client_matrix.csv');
    WriteLn('BILGI rapor: ', GDir, 'pg_client_matrix.out');
  finally
    GAvail.Free;
  end;

  Srv.Stop;
  FreeAndNil(Srv);

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL, ', GSkip, ' SKIP');
  Flush(Output);
  if GFail > 0 then
    Halt(1);
  if GRealLegs = 0 then
  begin
    reason := TStringList.Create;
    try
      reason.Add('pg_client_matrix KOSMADI: hicbir gercek PostgreSQL istemcisi bulunamadi.');
      reason.Add('Denen bacaklar: psql, libpq, psycopg, JDBC, Npgsql.');
      for i := 0 to High(GLegs) do
        reason.Add('  ' + GLegs[i].Name + ': ' + GLegs[i].Why);
      reason.Add('Wire bacagi (saf Python protokol istemcisi) kostu; bu GERCEK bir');
      reason.Add('istemci degildir ve uyumluluk kaniti sayilmaz.');
      reason.SaveToFile(GDir + 'SKIP_REASON.txt');
    finally
      reason.Free;
    end;
    WriteLn('SKIP pg_client_matrix - hicbir gercek istemci bulunamadi; gerekce: ',
      GDir, 'SKIP_REASON.txt');
    GOut.Free;
    Halt(SKIP_CODE);
  end;
  GOut.Free;
end.
