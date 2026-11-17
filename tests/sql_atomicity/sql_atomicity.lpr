program sql_atomicity;
{ Sprint A (3.5) KALICI REGRESYON KAPISI.
  AFTER ... FOR EACH STATEMENT tetikleyicisi, ana DML COMMIT edilmeden ONCE
  calismalidir. Trigger hata verirse statement'in TUM satir degisiklikleri
  geri alinmalidir. Eski davranis: trigger COMMIT'ten SONRA atesleniyor,
  hata ana DML'i geri alamiyordu. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbErr;

var
  GDir, GDb: string;
  GPass, GFail: Integer;
  GSeq: Integer;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

procedure Wipe(const D: string);
var
  sr: TSearchRec;
  d2: string;
begin
  d2 := IncludeTrailingPathDelimiter(D);
  ForceDirectories(d2);
  if FindFirst(d2 + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(d2 + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function CellQ(Aq: TVSql; const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '<yok>';
  r := Aq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := Trim(r.Rows[0][0]);
end;

function IntQ(Aq: TVSql; const ASql: string): Int64;
var
  s: string;
begin
  s := CellQ(Aq, ASql);
  if not TryStrToInt64(s, Result) then Result := -1;
end;

function TryExec(Aq: TVSql; const ASql: string; out AErr: string): Boolean;
begin
  AErr := '';
  try
    Aq.Exec(ASql);
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
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;
  err: string;

procedure OpenFresh(const AName: string);
begin
  Inc(GSeq);
  GDir := GetTempDir + 'vdb_atom_' + AName + '_' + IntToStr(GetProcessID) +
    '_' + IntToStr(GSeq);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'atom.odb';
  Be := TVdbBackendV3.Create(GDb);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
end;

procedure CloseAll;
begin
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;
end;

{ Ortak kurulum: ana tablo + audit. audit'te 999 PK'si onceden var; trigger
  ayni PK'yi eklemeye calisip hata verir. }
procedure Setup(const ATbl: string; out Ok: Boolean);
begin
  Ok := TryExec(Sq,
    'CREATE TABLE audit (id INTEGER PRIMARY KEY)', err);
  if Ok then Ok := TryExec(Sq,
    'INSERT INTO audit (id) VALUES (999)', err);
  if Ok then Ok := TryExec(Sq,
    'CREATE TABLE ' + ATbl + ' (id INTEGER PRIMARY KEY, v TEXT)', err);
end;

{ 3.5: AFTER INSERT STATEMENT hatasi cok satirli INSERT'i geri alir. }
procedure CaseInsertAtomic;
var
  ok, trig: Boolean;
begin
  OpenFresh('ins');
  Setup('t', ok);
  Chk('AT1 tablolar olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tai AFTER INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT1 AFTER INSERT STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b''), (3, ''c'')', err);
  Chk('AT1 trigger hatasi INSERT''i basarisiz kildi', not ok, err);
  Chk('AT1 hatali INSERT hicbir satir birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('AT1 audit oncesi durumunu korudu',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ 3.5: AFTER UPDATE STATEMENT hatasi tum UPDATE'i geri alir. }
procedure CaseUpdateAtomic;
var
  ok, trig: Boolean;
begin
  OpenFresh('upd');
  Setup('u', ok);
  Chk('AT2 tablolar olustu', ok, err);
  Sq.Exec('INSERT INTO u (id, v) VALUES (1, ''a''), (2, ''b'')');
  trig := TryExec(Sq,
    'CREATE TRIGGER tau AFTER UPDATE ON u FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT2 AFTER UPDATE STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'UPDATE u SET v = ''degisti''', err);
  Chk('AT2 trigger hatasi UPDATE''i basarisiz kildi', not ok, err);
  Chk('AT2 hatali UPDATE id=1 degerini korudu',
    CellQ(Sq, 'SELECT v FROM u WHERE id = 1') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM u WHERE id = 1'));
  Chk('AT2 hatali UPDATE id=2 degerini korudu',
    CellQ(Sq, 'SELECT v FROM u WHERE id = 2') = 'b',
    'v=' + CellQ(Sq, 'SELECT v FROM u WHERE id = 2'));
  CloseAll;
end;

{ 3.5: AFTER DELETE STATEMENT hatasi tum DELETE'i geri alir. }
procedure CaseDeleteAtomic;
var
  ok, trig: Boolean;
begin
  OpenFresh('del');
  Setup('d', ok);
  Chk('AT3 tablolar olustu', ok, err);
  Sq.Exec('INSERT INTO d (id, v) VALUES (1, ''a''), (2, ''b'')');
  trig := TryExec(Sq,
    'CREATE TRIGGER tad AFTER DELETE ON d FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT3 AFTER DELETE STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'DELETE FROM d', err);
  Chk('AT3 trigger hatasi DELETE''i basarisiz kildi', not ok, err);
  Chk('AT3 hatali DELETE iki satiri da korudu',
    IntQ(Sq, 'SELECT COUNT(*) FROM d') = 2,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM d')));
  Chk('AT3 hatali DELETE id=1 satirini korudu',
    CellQ(Sq, 'SELECT v FROM d WHERE id = 1') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM d WHERE id = 1'));
  CloseAll;
end;

{ 3.5: tek satirli INSERT yolu da ayni garantiyi verir. }
procedure CaseInsertSingleAtomic;
var
  ok, trig: Boolean;
begin
  OpenFresh('ins1');
  Setup('t', ok);
  Chk('AT4 tablolar olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tai1 AFTER INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT4 AFTER INSERT STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (5, ''tek'')', err);
  Chk('AT4 trigger hatasi tek satir INSERT''i basarisiz kildi', not ok, err);
  Chk('AT4 hatali tek satir INSERT iz birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ 3.5: COPY yolu da trigger hatasinda geri alinir. }
procedure CaseCopyAtomic;
var
  ok, trig: Boolean;
  sl: TStringList;
  csvPath: string;
begin
  OpenFresh('copy');
  Setup('c', ok);
  Chk('AT5 tablolar olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tac AFTER INSERT ON c FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT5 AFTER INSERT STATEMENT trigger olustu', trig, err);

  csvPath := IncludeTrailingPathDelimiter(GDir) + 'copy.csv';
  sl := TStringList.Create;
  try
    sl.Add('1,a');
    sl.Add('2,b');
    sl.SaveToFile(csvPath);
  finally
    sl.Free;
  end;
  ok := TryExec(Sq,
    'COPY c (id, v) FROM ''' + csvPath + ''' WITH (FORMAT csv)', err);
  Chk('AT5 trigger hatasi COPY''yi basarisiz kildi', not ok, err);
  Chk('AT5 hatali COPY hicbir satir birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM c') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM c')));
  CloseAll;
end;

begin
  GPass := 0;
  GFail := 0;
  GSeq := 0;
  try CaseInsertAtomic except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT1 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseUpdateAtomic except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT2 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseDeleteAtomic except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT3 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseInsertSingleAtomic except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT4 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseCopyAtomic except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT5 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
