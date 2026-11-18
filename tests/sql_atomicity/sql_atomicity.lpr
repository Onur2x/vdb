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

{ Sprint B: ayni dizini yeniden acar (kalicilik kontrolu). }
procedure OpenSame;
begin
  GDb := IncludeTrailingPathDelimiter(GDir) + 'atom.odb';
  Be := TVdbBackendV3.Create(GDb);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
end;

{ Sprint B: BEFORE INSERT STATEMENT trigger'i batch icinde ateslenmeli; bu
  durumda govdesindeki DML statement ile birlikte kalici olur. Onceki kod
  trigger'i batch'ten once calistirdigi icin bu kanit alinamazdi. }
procedure CaseBeforeStmtFires;
var
  ok, trig: Boolean;
begin
  OpenFresh('bsf');
  Setup('t', ok);
  ok := TryExec(Sq, 'CREATE TABLE logt (id INTEGER PRIMARY KEY)', err);
  Chk('AT6 log tablosu olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tbi BEFORE INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO logt (id) VALUES (1); END', err);
  Chk('AT6 BEFORE INSERT STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (1, ''a'')', err);
  Chk('AT6 BEFORE STATEMENT trigger hatasiz calisti', ok, err);
  Chk('AT6 trigger govdesindeki DML kalici',
    IntQ(Sq, 'SELECT COUNT(*) FROM logt') = 1,
    'logt=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM logt')));
  Chk('AT6 ana INSERT de kalici',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 1,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ Sprint B: BEFORE INSERT STATEMENT hatasi cok satirli INSERT'i geri alir. }
procedure CaseBeforeInsertFail;
var
  ok, trig: Boolean;
begin
  OpenFresh('bsi');
  Setup('t', ok);
  trig := TryExec(Sq,
    'CREATE TRIGGER tbi BEFORE INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT7 BEFORE INSERT STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'')', err);
  Chk('AT7 trigger hatasi INSERT''i basarisiz kildi', not ok, err);
  Chk('AT7 hatali INSERT hicbir satir birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('AT7 audit oncesi durumunu korudu',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ Sprint B: BEFORE UPDATE STATEMENT hatasi (eskiden hic ateslenmiyordu). }
procedure CaseBeforeUpdateFail;
var
  ok, trig: Boolean;
begin
  OpenFresh('bsu');
  Setup('u', ok);
  Sq.Exec('INSERT INTO u (id, v) VALUES (1, ''a''), (2, ''b'')');
  trig := TryExec(Sq,
    'CREATE TRIGGER tbu BEFORE UPDATE ON u FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT8 BEFORE UPDATE STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'UPDATE u SET v = ''degisti''', err);
  Chk('AT8 trigger hatasi UPDATE''i basarisiz kildi', not ok, err);
  Chk('AT8 hatali UPDATE id=1 degerini korudu',
    CellQ(Sq, 'SELECT v FROM u WHERE id = 1') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM u WHERE id = 1'));
  Chk('AT8 hatali UPDATE id=2 degerini korudu',
    CellQ(Sq, 'SELECT v FROM u WHERE id = 2') = 'b',
    'v=' + CellQ(Sq, 'SELECT v FROM u WHERE id = 2'));
  CloseAll;
end;

{ Sprint B: BEFORE DELETE STATEMENT hatasi (eskiden hic ateslenmiyordu). }
procedure CaseBeforeDeleteFail;
var
  ok, trig: Boolean;
begin
  OpenFresh('bsd');
  Setup('d', ok);
  Sq.Exec('INSERT INTO d (id, v) VALUES (1, ''a''), (2, ''b'')');
  trig := TryExec(Sq,
    'CREATE TRIGGER tbd BEFORE DELETE ON d FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT9 BEFORE DELETE STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'DELETE FROM d', err);
  Chk('AT9 trigger hatasi DELETE''i basarisiz kildi', not ok, err);
  Chk('AT9 hatali DELETE iki satiri da korudu',
    IntQ(Sq, 'SELECT COUNT(*) FROM d') = 2,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM d')));
  Chk('AT9 hatali DELETE audit''e dokunmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ Sprint B (B4): 0 satir eslesen DELETE'te BEFORE STATEMENT trigger'inin
  yaptigi DML sessizce kaybolmamali. Eskiden dal kosulsuz AbortBatch
  cagiriyordu. }
procedure CaseBeforeDeleteZeroRows;
var
  ok, trig: Boolean;
begin
  OpenFresh('bdz');
  Setup('z', ok);
  Sq.Exec('INSERT INTO z (id, v) VALUES (1, ''a'')');
  ok := TryExec(Sq, 'CREATE TABLE logz (id INTEGER PRIMARY KEY)', err);
  Chk('AT10 log tablosu olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tbz BEFORE DELETE ON z FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO logz (id) VALUES (1); END', err);
  Chk('AT10 BEFORE DELETE STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'DELETE FROM z WHERE id = 999', err);
  Chk('AT10 eslesmeyen DELETE hatasiz', ok, err);
  Chk('AT10 silinen satir yok',
    IntQ(Sq, 'SELECT COUNT(*) FROM z') = 1,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM z')));
  Chk('AT10 trigger DML''i korundu',
    IntQ(Sq, 'SELECT COUNT(*) FROM logz') = 1,
    'logz=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM logz')));
  CloseAll;
end;

{ Sprint B: BEFORE ROW hatasi tum statement'i geri alir. }
procedure CaseBeforeRowFail;
var
  ok, trig: Boolean;
begin
  OpenFresh('brw');
  Setup('t', ok);
  trig := TryExec(Sq,
    'CREATE TRIGGER tbr BEFORE INSERT ON t FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT11 BEFORE INSERT ROW trigger olustu', trig, err);

  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b''), (3, ''c'')', err);
  Chk('AT11 satir trigger hatasi INSERT''i basarisiz kildi', not ok, err);
  Chk('AT11 hatali INSERT hicbir satir birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ Sprint B: AFTER ROW hatasi tum statement'i geri alir. }
procedure CaseAfterRowFail;
var
  ok, trig: Boolean;
begin
  OpenFresh('arw');
  Setup('t', ok);
  trig := TryExec(Sq,
    'CREATE TRIGGER tar AFTER INSERT ON t FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT12 AFTER INSERT ROW trigger olustu', trig, err);

  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'')', err);
  Chk('AT12 satir trigger hatasi INSERT''i basarisiz kildi', not ok, err);
  Chk('AT12 hatali INSERT hicbir satir birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ Sprint B: 2. satirda constraint hatasi -> statement'in tamami geri alinir. }
procedure CaseConstraintFail;
var
  ok: Boolean;
begin
  OpenFresh('con');
  Setup('t', ok);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b''), (2, ''c'')', err);
  Chk('AT13 duplicate PK INSERT''i basarisiz kildi', not ok, err);
  Chk('AT13 hatali INSERT hicbir satir birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ Sprint B: MERGE AFTER STATEMENT hatasi tum MERGE'i geri alir. }
procedure CaseMergeAtomic;
var
  ok, trig: Boolean;
begin
  OpenFresh('mrg');
  Setup('m2', ok);
  ok := TryExec(Sq, 'CREATE TABLE src2 (id INTEGER PRIMARY KEY, v TEXT)', err);
  Chk('AT14 src tablosu olustu', ok, err);
  if ok then ok := TryExec(Sq,
    'INSERT INTO src2 (id, v) VALUES (1, ''yeni''), (2, ''yeni2'')', err);
  Chk('AT14 src dolduruldu', ok, err);
  if ok then ok := TryExec(Sq,
    'INSERT INTO m2 (id, v) VALUES (1, ''eski'')', err);
  Chk('AT14 hedef dolduruldu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tma AFTER UPDATE ON m2 FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT14 MERGE AFTER UPDATE STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq,
    'MERGE INTO m2 USING src2 ON m2.id = src2.id ' +
    'WHEN MATCHED THEN UPDATE SET v = src2.v', err);
  Chk('AT14 trigger hatasi MERGE''i basarisiz kildi', not ok, err);
  Chk('AT14 hatali MERGE hedef satiri korudu',
    CellQ(Sq, 'SELECT v FROM m2 WHERE id = 1') = 'eski',
    'v=' + CellQ(Sq, 'SELECT v FROM m2 WHERE id = 1'));
  Chk('AT14 hatali MERGE satir sayisini korudu',
    IntQ(Sq, 'SELECT COUNT(*) FROM m2') = 1,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM m2')));
  CloseAll;
end;

{ Sprint B: RETURNING yalniz basarili statement'ta satir dondurur. }
procedure CaseReturning;
var
  ok, trig: Boolean;
  r: TSqlResult;
  n, val: string;
begin
  OpenFresh('ret');
  Setup('t', ok);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'') RETURNING id', err);
  Chk('AT15 RETURNING''li INSERT calisti', ok, err);
  n := '<yok>';
  val := '<yok>';
  r := Sq.Exec('SELECT COUNT(*) FROM t');
  if Length(r.Rows) > 0 then n := Trim(r.Rows[0][0]);
  r := Sq.Exec('SELECT v FROM t WHERE id = 2');
  if Length(r.Rows) > 0 then val := Trim(r.Rows[0][0]);
  Chk('AT15 RETURNING sonrasi iki satir yazildi', n = '2', 'n=' + n);
  Chk('AT15 RETURNING sonrasi deger dogru', val = 'b', 'v=' + val);

  trig := TryExec(Sq,
    'CREATE TRIGGER tret AFTER INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT15 AFTER INSERT STATEMENT trigger olustu', trig, err);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (3, ''c'') RETURNING id', err);
  Chk('AT15 trigger hatasi RETURNING''li INSERT''i basarisiz kildi', not ok, err);
  Chk('AT15 hatali RETURNING''li INSERT iz birakmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 2,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ Sprint B: hatali statement yeniden acilista iz birakmaz. }
procedure CaseRestartClean;
var
  ok, trig: Boolean;
begin
  OpenFresh('rst');
  Setup('t', ok);
  trig := TryExec(Sq,
    'CREATE TRIGGER tri AFTER INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT16 AFTER INSERT STATEMENT trigger olustu', trig, err);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'')', err);
  Chk('AT16 trigger hatasi INSERT''i basarisiz kildi', not ok, err);
  CloseAll;

  OpenSame;
  Chk('AT16 yeniden acilista ana tablo bos',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('AT16 yeniden acilista audit temiz',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ Sprint B: explicit transaction icindeki statement hatasi ROLLBACK ile
  tamamen silinir; dis write-set'e dokunulmaz. }
procedure CaseExplicitTxn;
var
  ok, trig: Boolean;
begin
  OpenFresh('txn');
  Setup('t', ok);
  trig := TryExec(Sq,
    'CREATE TRIGGER ttx AFTER INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT17 AFTER INSERT STATEMENT trigger olustu', trig, err);
  ok := TryExec(Sq, 'BEGIN', err);
  Chk('AT17 BEGIN calisti', ok, err);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'')', err);
  Chk('AT17 txn icinde trigger hatasi statement''i basarisiz kildi',
    not ok, err);
  ok := TryExec(Sq, 'ROLLBACK', err);
  Chk('AT17 ROLLBACK calisti', ok, err);
  Chk('AT17 ROLLBACK sonrasi hicbir satir kalmadi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('AT17 ROLLBACK sonrasi audit temiz',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ Sprint B (B1): BEFORE STATEMENT trigger'i eskiden batch ACILMADAN atesleniyordu;
  govdesindeki DML ana statement hatasiyla geri alinamiyordu. }
procedure CaseBeforeStmtRolledBack;
var
  ok, trig: Boolean;
begin
  OpenFresh('bsr');
  Setup('t', ok);
  ok := TryExec(Sq, 'CREATE TABLE logr (id INTEGER PRIMARY KEY)', err);
  Chk('AT18 log tablosu olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tbr2 BEFORE INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO logr (id) VALUES (1); END', err);
  Chk('AT18 BEFORE INSERT STATEMENT trigger olustu', trig, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tar2 AFTER INSERT ON t FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT18 AFTER INSERT ROW trigger olustu', trig, err);

  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (1, ''a'')', err);
  Chk('AT18 satir trigger hatasi INSERT''i basarisiz kildi', not ok, err);
  Chk('AT18 ana tablo bos',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('AT18 BEFORE STATEMENT trigger DML''i de geri alindi',
    IntQ(Sq, 'SELECT COUNT(*) FROM logr') = 0,
    'logr=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM logr')));
  CloseAll;
end;

{ v3.57 / SKILL5 6.1: EXPLICIT TRANSACTION icinde yarida hata veren bir
  statement'in yazimlari once COMMIT ile KALICI hale geliyordu (olculdu:
  BEGIN; cok satirli INSERT (trigger hatasi); COMMIT -> 2 satir kalici).
  AT17 yalnizca ROLLBACK sonrasini denetledigi icin bu acigi goremiyordu.
  Asagidaki AT20-AT24 COMMIT SONRASINI denetler. }
procedure CaseTxnCommitAfterFail;
var
  ok, trig: Boolean;
begin
  OpenFresh('txc1');
  Setup('t', ok);
  Chk('AT20 tablolar olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER ttx20 AFTER INSERT ON t FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT20 AFTER INSERT STATEMENT trigger olustu', trig, err);

  ok := TryExec(Sq, 'BEGIN', err);
  Chk('AT20 BEGIN calisti', ok, err);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'')', err);
  Chk('AT20 txn icinde statement basarisiz oldu', not ok, err);
  Chk('AT20 txn icinde ana tablo bos',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  ok := TryExec(Sq, 'COMMIT', err);
  Chk('AT20 COMMIT calisti', ok, err);
  Chk('AT20 COMMIT sonrasi yarim yazim KALICI OLMADI',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('AT20 COMMIT sonrasi audit oncesi durumunda',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ v3.57: explicit txn icinde BASARILI statement korunur, hatali statement'in
  yarim yazimi COMMIT ile kalici olmaz. Trigger yok: ihlal, onceden var olan
  PK ile cakismadan gelir (motorun kendi kisit yolu). }
procedure CaseTxnGoodStmtSurvives;
var
  ok: Boolean;
begin
  OpenFresh('txg');
  ok := TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)', err);
  Chk('AT21 tablo olustu', ok, err);
  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (5, ''seed'')', err);
  Chk('AT21 tohum satiri eklendi', ok, err);

  ok := TryExec(Sq, 'BEGIN', err);
  Chk('AT21 BEGIN calisti', ok, err);
  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (7, ''ok'')', err);
  Chk('AT21 iyi statement calisti', ok, err);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (8, ''a''), (5, ''dup'')', err);
  Chk('AT21 kotu statement PK cakismasiyla basarisiz oldu', not ok, err);
  ok := TryExec(Sq, 'COMMIT', err);
  Chk('AT21 COMMIT calisti', ok, err);
  Chk('AT21 kotu statement satiri (id=8) kalici OLMADI',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 8') = 0,
    'satir8=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 8')));
  Chk('AT21 onceki iyi statement satiri korundu (id=7)',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 7') = 1,
    'satir7=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 7')));
  Chk('AT21 toplam satir 2 (5 ve 7)',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 2,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ v3.57: geri alma sonrasi cakisma defteri temizlenmeli; aksi halde ayni
  anahtar sonraki statement'ta bosuna cakisma verirdi. }
procedure CaseTxnRollbackCleansConflict;
var
  ok: Boolean;
begin
  OpenFresh('txcl');
  ok := TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)', err);
  Chk('AT22 tablo olustu', ok, err);
  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (5, ''seed'')', err);
  Chk('AT22 tohum satiri eklendi', ok, err);

  ok := TryExec(Sq, 'BEGIN', err);
  Chk('AT22 BEGIN calisti', ok, err);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (8, ''a''), (5, ''dup'')', err);
  Chk('AT22 hatali statement basarisiz oldu', not ok, err);
  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (8, ''a'')', err);
  Chk('AT22 ayni anahtar sonraki statement''ta BASARILI', ok, err);
  ok := TryExec(Sq, 'COMMIT', err);
  Chk('AT22 COMMIT calisti', ok, err);
  Chk('AT22 id=8 tek satir kalici',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 8') = 1,
    'satir8=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 8')));
  CloseAll;
end;

{ v3.57: UPDATE yolu da ayni garanti altinda. Yarida kalan bir UPDATE
  gercekten olmali: PK kolonu guncellenemedigi icin onceki surum yalnizca
  dogrulama hatasi veriyordu ve hicbir degisiklik yapmadan dusuyordu (yanlis
  pozitif). Burada UNIQUE indeks cakismasi ikinci satirda olusur: 1. satir
  yazilir, 2. satir cakisir -> statement geri alinmali, 1. satir ESKI
  degerine donmelidir. }
procedure CaseTxnUpdateCommitAfterFail;
var
  ok: Boolean;
begin
  OpenFresh('txu');
  ok := TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)', err);
  Chk('AT23 tablo olustu', ok, err);
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'')', err);
  Chk('AT23 iki satir eklendi', ok, err);
  ok := TryExec(Sq, 'CREATE UNIQUE INDEX ux23 ON t (v)', err);
  Chk('AT23 UNIQUE indeks olustu', ok, err);

  ok := TryExec(Sq, 'BEGIN', err);
  Chk('AT23 BEGIN calisti', ok, err);
  ok := TryExec(Sq, 'UPDATE t SET v = ''z'' WHERE id = 1', err);
  Chk('AT23 iyi UPDATE calisti', ok, err);
  { 1. satir z -> x yazilir, 2. satir b -> x cakisir. }
  ok := TryExec(Sq, 'UPDATE t SET v = ''x'' WHERE id IN (1, 2)', err);
  Chk('AT23 hatali UPDATE indeks cakismasiyla basarisiz oldu', not ok, err);
  ok := TryExec(Sq, 'COMMIT', err);
  Chk('AT23 COMMIT calisti', ok, err);
  Chk('AT23 onceki UPDATE korundu (v=z)',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = 'z',
    'v=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));
  Chk('AT23 hatali UPDATE 2. satiri bozmadi (v=b)',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 2') = 'b',
    'v=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 2'));
  Chk('AT23 toplam satir 2',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 2,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  CloseAll;
end;

{ v3.57: ortuk statement kapsami kullanicinin SAVEPOINT'ini GOLGELEMEMELI;
  ROLLBACK TO / RELEASE hala calismali. Test yalnizca SQL kullanir: backend
  API'sini dogrudan cagirmak yazma oturumunu ayarlamadigi icin yaniltici
  olurdu. Silent no-op'a karsi koruma: savepoint'ten SONRA BASARILI bir
  satir eklenir; ROLLBACK TO onu silmezse savepoint kaybolmus demektir. }
procedure CaseTxnUserSavepointPreserved;
var
  ok: Boolean;
begin
  OpenFresh('txsp');
  ok := TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)', err);
  Chk('AT24 tablo olustu', ok, err);

  ok := TryExec(Sq, 'BEGIN', err);
  Chk('AT24 BEGIN calisti', ok, err);
  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (10, ''a'')', err);
  Chk('AT24 ilk satir eklendi', ok, err);
  ok := TryExec(Sq, 'SAVEPOINT s1', err);
  Chk('AT24 kullanici SAVEPOINT olustu', ok, err);
  { Savepoint'ten sonra BASARILI yazim: ROLLBACK TO bunu silmeli. }
  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (11, ''b'')', err);
  Chk('AT24 savepoint sonrasi satir eklendi', ok, err);
  { Yarida kalan statement: ortuk kapsam bunu geri almali. }
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (13, ''x''), (10, ''dup'')', err);
  Chk('AT24 hatali statement basarisiz oldu', not ok, err);

  ok := TryExec(Sq, 'ROLLBACK TO SAVEPOINT s1', err);
  Chk('AT24 ROLLBACK TO s1 calisti (savepoint yasiyor)', ok, err);
  Chk('AT24 ROLLBACK TO s1 satir 10''u korudu',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 10') = 1,
    'satir10=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 10')));
  Chk('AT24 ROLLBACK TO s1 savepoint sonrasi satiri (id=11) sildi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 11') = 0,
    'satir11=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 11')));
  Chk('AT24 ROLLBACK TO s1 yarim yazimi (id=13) sildi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 13') = 0,
    'satir13=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 13')));

  ok := TryExec(Sq, 'INSERT INTO t (id, v) VALUES (12, ''c'')', err);
  Chk('AT24 savepoint sonrasi yeni satir eklendi', ok, err);
  ok := TryExec(Sq, 'RELEASE SAVEPOINT s1', err);
  Chk('AT24 RELEASE SAVEPOINT calisti', ok, err);
  ok := TryExec(Sq, 'COMMIT', err);
  Chk('AT24 COMMIT calisti', ok, err);
  Chk('AT24 hatali statement satiri (id=11) yok',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 11') = 0,
    'satir11=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 11')));
  Chk('AT24 sonraki satir (id=12) kalici',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 12') = 1,
    'satir12=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 12')));
  CloseAll;
  { Yeniden acilis: yarim yazim diskte de yok. }
  OpenSame;
  Chk('AT24 yeniden acilista yarim yazim yok',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 11') = 0,
    'satir11=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 11')));
  CloseAll;
end;

{ Sprint B (B1, COPY yolu): ayni garanti COPY icin. }
procedure CaseCopyBeforeStmtRolledBack;
var
  ok, trig: Boolean;
  sl: TStringList;
  csvPath: string;
begin
  OpenFresh('cbr');
  Setup('c', ok);
  ok := TryExec(Sq, 'CREATE TABLE logc (id INTEGER PRIMARY KEY)', err);
  Chk('AT19 log tablosu olustu', ok, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tbc BEFORE INSERT ON c FOR EACH STATEMENT AS ' +
    'BEGIN INSERT INTO logc (id) VALUES (1); END', err);
  Chk('AT19 BEFORE INSERT STATEMENT trigger olustu', trig, err);
  trig := TryExec(Sq,
    'CREATE TRIGGER tac2 AFTER INSERT ON c FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (999); END', err);
  Chk('AT19 AFTER INSERT ROW trigger olustu', trig, err);

  csvPath := IncludeTrailingPathDelimiter(GDir) + 'cbr.csv';
  sl := TStringList.Create;
  try
    sl.Add('1,a');
    sl.SaveToFile(csvPath);
  finally
    sl.Free;
  end;
  ok := TryExec(Sq,
    'COPY c (id, v) FROM ''' + csvPath + ''' WITH (FORMAT csv)', err);
  Chk('AT19 satir trigger hatasi COPY''yi basarisiz kildi', not ok, err);
  Chk('AT19 ana tablo bos',
    IntQ(Sq, 'SELECT COUNT(*) FROM c') = 0,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM c')));
  Chk('AT19 BEFORE STATEMENT trigger DML''i de geri alindi',
    IntQ(Sq, 'SELECT COUNT(*) FROM logc') = 0,
    'logc=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM logc')));
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
  try CaseBeforeStmtFires except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT6 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseBeforeInsertFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT7 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseBeforeUpdateFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT8 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseBeforeDeleteFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT9 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseBeforeDeleteZeroRows except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT10 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseBeforeRowFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT11 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseAfterRowFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT12 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseConstraintFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT13 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseMergeAtomic except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT14 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseReturning except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT15 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseRestartClean except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT16 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseExplicitTxn except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT17 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseBeforeStmtRolledBack except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT18 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseCopyBeforeStmtRolledBack except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT19 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseTxnCommitAfterFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT20 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseTxnGoodStmtSurvives except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT21 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseTxnRollbackCleansConflict except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT22 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseTxnUpdateCommitAfterFail except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT23 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseTxnUserSavepointPreserved except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AT24 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
