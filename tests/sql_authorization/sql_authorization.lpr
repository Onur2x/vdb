program sql_authorization;
{ Sprint A (3.3/3.4) KALICI REGRESYON KAPISI.
  ON CONFLICT DO UPDATE ve MERGE yollarinin, normal INSERT/UPDATE/DELETE
  ile ayni yetki + RLS + tetikleyici kurallarina tabi oldugunu olcer.
  Eski davranis: upsert'te yalniz INSERT yetkisi/RLS kontrol ediliyor,
  MERGE'de RLS ve tetikleyiciler tamamen atlaniyordu. }
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
  GDir := GetTempDir + 'vdb_auth_' + AName + '_' + IntToStr(GetProcessID) +
    '_' + IntToStr(GSeq);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'auth.odb';
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

{ 3.3: ON CONFLICT DO UPDATE bir UPDATE'tir; UPDATE yetkisi ister. }
procedure CaseUpsertUpdatePrivilege;
var
  ok: Boolean;
begin
  OpenFresh('up');
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('INSERT INTO t (id, v) VALUES (1, ''ilk'')');
  Sq.Exec('CREATE ROLE app');
  Sq.Exec('GRANT SELECT ON TABLE t TO app');
  Sq.Exec('GRANT INSERT ON TABLE t TO app');

  Sq.Exec('SET ROLE app');
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''hacked'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''hacked''', err);
  Chk('AU1 UPDATE yetkisi olmadan upsert reddedildi', not ok, err);

  Sq.Exec('SET ROLE NONE');
  Chk('AU1 yetkisiz upsert degeri degistirmedi',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = 'ilk',
    'v=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));

  Sq.Exec('GRANT UPDATE ON TABLE t TO app');
  Sq.Exec('SET ROLE app');
  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (1, ''guncel'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''guncel''', err);
  Chk('AU1 UPDATE yetkisiyle upsert kabul edildi', ok, err);

  Sq.Exec('SET ROLE NONE');
  Chk('AU1 yetkili upsert degeri guncelledi',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = 'guncel',
    'v=' + CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));
  CloseAll;
end;

{ 3.3: upsert UPDATE yolunda UPDATE RLS (USING eski, WITH CHECK yeni)
  uygulanir; catisma YOKSA yalniz INSERT WITH CHECK uygulanir. }
procedure CaseUpsertRls;
var
  ok: Boolean;
begin
  OpenFresh('rls');
  Sq.Exec('CREATE TABLE r (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('INSERT INTO r (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO r (id, v) VALUES (2, ''b'')');
  Sq.Exec('CREATE ROLE rlsr');
  Sq.Exec('GRANT ALL ON TABLE r TO rlsr');
  Sq.Exec('ALTER TABLE r ENABLE ROW LEVEL SECURITY');
  Sq.Exec('CREATE POLICY p_upd ON r FOR UPDATE ' +
    'USING (id = 1) WITH CHECK (v <> ''bad'')');
  Sq.Exec('CREATE POLICY p_ins ON r FOR INSERT ' +
    'WITH CHECK (v <> ''no'')');

  Sq.Exec('SET ROLE rlsr');

  // Gizli hedef satiri (id=2) upsert ile guncellenemez.
  ok := TryExec(Sq,
    'INSERT INTO r (id, v) VALUES (2, ''x'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''x''', err);
  Chk('AU2 RLS USING gizli satiri upsert ile guncellemeyi reddetti',
    not ok, err);

  // Gorunur satirda WITH CHECK ihlali reddedilir.
  ok := TryExec(Sq,
    'INSERT INTO r (id, v) VALUES (1, ''bad'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''bad''', err);
  Chk('AU2 RLS WITH CHECK ihlali upsert ile reddedildi', not ok, err);

  // UPDATE yolu INSERT WITH CHECK'e takilmamali (eski hatali davranis).
  ok := TryExec(Sq,
    'INSERT INTO r (id, v) VALUES (1, ''upd-ok'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''upd-ok''', err);
  Chk('AU2 upsert UPDATE yolunda INSERT WITH CHECK uygulanmadi', ok, err);

  // Catisma yoksa INSERT WITH CHECK uygulanir.
  ok := TryExec(Sq,
    'INSERT INTO r (id, v) VALUES (3, ''no'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''no''', err);
  Chk('AU2 upsert INSERT yolunda INSERT WITH CHECK uygulandi', not ok, err);

  Sq.Exec('SET ROLE NONE');
  Chk('AU2 gizli satir degismedi',
    CellQ(Sq, 'SELECT v FROM r WHERE id = 2') = 'b',
    'v=' + CellQ(Sq, 'SELECT v FROM r WHERE id = 2'));
  Chk('AU2 gecerli upsert yazildi',
    CellQ(Sq, 'SELECT v FROM r WHERE id = 1') = 'upd-ok',
    'v=' + CellQ(Sq, 'SELECT v FROM r WHERE id = 1'));
  Chk('AU2 WITH CHECK ihlali satir eklemedi',
    IntQ(Sq, 'SELECT COUNT(*) FROM r WHERE id = 3') = 0);
  CloseAll;
end;

{ 3.3: upsert'in UPDATE yolunda AFTER UPDATE ROW tetikleyicisi ateslenir. }
procedure CaseUpsertTrigger;
var
  ok: Boolean;
begin
  OpenFresh('trg');
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE audit (id INTEGER PRIMARY KEY)');
  Sq.Exec('INSERT INTO t (id, v) VALUES (7, ''a'')');
  ok := TryExec(Sq,
    'CREATE TRIGGER au AFTER UPDATE ON t FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (NEW.id); END', err);
  Chk('AU3 AFTER UPDATE trigger olustu', ok, err);

  ok := TryExec(Sq,
    'INSERT INTO t (id, v) VALUES (7, ''b'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''b''', err);
  Chk('AU3 upsert UPDATE kabul edildi', ok, err);
  Chk('AU3 upsert UPDATE ROW trigger ateslendi',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit WHERE id = 7') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit WHERE id = 7')));
  CloseAll;
end;

{ 3.4: MERGE eslesmesi RLS USING'e tabidir; gizli hedef satiri eslesmis
  sayilmaz. AFTER UPDATE ROW tetikleyicisi de ateslenir. }
procedure CaseMergeRlsTrigger;
var
  ok: Boolean;
begin
  OpenFresh('merge');
  Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE src (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE audit (id INTEGER PRIMARY KEY)');
  Sq.Exec('INSERT INTO m (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO m (id, v) VALUES (2, ''b'')');
  Sq.Exec('INSERT INTO src (id, v) VALUES (1, ''x'')');
  Sq.Exec('INSERT INTO src (id, v) VALUES (2, ''y'')');
  Sq.Exec('CREATE ROLE mr');
  Sq.Exec('GRANT ALL ON TABLE m TO mr');
  Sq.Exec('GRANT ALL ON TABLE audit TO mr');
  Sq.Exec('ALTER TABLE m ENABLE ROW LEVEL SECURITY');
  Sq.Exec('CREATE POLICY p_m ON m FOR UPDATE ' +
    'USING (id = 1) WITH CHECK (v <> ''bad'')');
  ok := TryExec(Sq,
    'CREATE TRIGGER mau AFTER UPDATE ON m FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (NEW.id); END', err);
  Chk('AU4 MERGE AFTER UPDATE trigger olustu', ok, err);

  Sq.Exec('SET ROLE mr');
  ok := TryExec(Sq,
    'MERGE INTO m USING src ON m.id = src.id ' +
    'WHEN MATCHED THEN UPDATE SET v = src.v', err);
  Chk('AU4 MERGE RLS ile calisti', ok, err);
  Sq.Exec('SET ROLE NONE');

  Chk('AU4 MERGE gorunur satiri guncelledi',
    CellQ(Sq, 'SELECT v FROM m WHERE id = 1') = 'x',
    'v=' + CellQ(Sq, 'SELECT v FROM m WHERE id = 1'));
  Chk('AU4 MERGE gizli satiri guncellemedi',
    CellQ(Sq, 'SELECT v FROM m WHERE id = 2') = 'b',
    'v=' + CellQ(Sq, 'SELECT v FROM m WHERE id = 2'));
  Chk('AU4 MERGE ROW trigger yalniz gorunur satir icin ateslendi',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ 3.4: MERGE UPDATE'te WITH CHECK uygulanir. }
procedure CaseMergeWithCheck;
var
  ok: Boolean;
begin
  OpenFresh('mchk');
  Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE src (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('INSERT INTO m (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO src (id, v) VALUES (1, ''bad'')');
  Sq.Exec('CREATE ROLE mc');
  Sq.Exec('GRANT ALL ON TABLE m TO mc');
  Sq.Exec('ALTER TABLE m ENABLE ROW LEVEL SECURITY');
  Sq.Exec('CREATE POLICY p_mc ON m FOR UPDATE ' +
    'USING (id = 1) WITH CHECK (v <> ''bad'')');

  Sq.Exec('SET ROLE mc');
  ok := TryExec(Sq,
    'MERGE INTO m USING src ON m.id = src.id ' +
    'WHEN MATCHED THEN UPDATE SET v = src.v', err);
  Chk('AU5 MERGE WITH CHECK ihlalini reddetti', not ok, err);
  Sq.Exec('SET ROLE NONE');
  Chk('AU5 MERGE WITH CHECK ihlali degeri degistirmedi',
    CellQ(Sq, 'SELECT v FROM m WHERE id = 1') = 'a',
    'v=' + CellQ(Sq, 'SELECT v FROM m WHERE id = 1'));
  CloseAll;
end;

{ 3.4: MERGE DELETE yolu RLS USING ve DELETE ROW tetikleyicilerine tabi. }
procedure CaseMergeDeleteRls;
var
  ok: Boolean;
begin
  OpenFresh('mdel');
  Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE src (id INTEGER PRIMARY KEY)');
  Sq.Exec('CREATE TABLE audit (id INTEGER PRIMARY KEY)');
  Sq.Exec('INSERT INTO m (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO m (id, v) VALUES (2, ''b'')');
  Sq.Exec('INSERT INTO src (id) VALUES (1)');
  Sq.Exec('INSERT INTO src (id) VALUES (2)');
  Sq.Exec('CREATE ROLE md');
  Sq.Exec('GRANT ALL ON TABLE m TO md');
  Sq.Exec('GRANT ALL ON TABLE audit TO md');
  Sq.Exec('ALTER TABLE m ENABLE ROW LEVEL SECURITY');
  Sq.Exec('CREATE POLICY p_md ON m FOR DELETE USING (id = 1)');
  ok := TryExec(Sq,
    'CREATE TRIGGER mad AFTER DELETE ON m FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (OLD.id); END', err);
  Chk('AU6 MERGE AFTER DELETE trigger olustu', ok, err);

  Sq.Exec('SET ROLE md');
  ok := TryExec(Sq,
    'MERGE INTO m USING src ON m.id = src.id ' +
    'WHEN MATCHED THEN DELETE', err);
  Chk('AU6 MERGE DELETE RLS ile calisti', ok, err);
  Sq.Exec('SET ROLE NONE');

  Chk('AU6 MERGE gizli satiri silmedi',
    IntQ(Sq, 'SELECT COUNT(*) FROM m WHERE id = 2') = 1);
  Chk('AU6 MERGE gorunur satiri sildi',
    IntQ(Sq, 'SELECT COUNT(*) FROM m WHERE id = 1') = 0);
  Chk('AU6 MERGE DELETE ROW trigger yalniz gorunur satir icin ateslendi',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));
  CloseAll;
end;

{ 3.4: MERGE INSERT yolu INSERT WITH CHECK ve INSERT ROW tetikleyicilerine
  tabi; eslesmeyen hedef satiri eklenir. }
procedure CaseMergeInsertRls;
var
  ok: Boolean;
begin
  OpenFresh('mins');
  Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE src (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('CREATE TABLE audit (id INTEGER PRIMARY KEY)');
  Sq.Exec('INSERT INTO src (id, v) VALUES (1, ''new'')');
  Sq.Exec('CREATE ROLE mi');
  Sq.Exec('GRANT ALL ON TABLE m TO mi');
  Sq.Exec('GRANT ALL ON TABLE audit TO mi');
  Sq.Exec('ALTER TABLE m ENABLE ROW LEVEL SECURITY');
  Sq.Exec('CREATE POLICY p_mi ON m FOR INSERT ' +
    'WITH CHECK (id < 10)');
  ok := TryExec(Sq,
    'CREATE TRIGGER mai AFTER INSERT ON m FOR EACH ROW AS ' +
    'BEGIN INSERT INTO audit (id) VALUES (NEW.id); END', err);
  Chk('AU7 MERGE AFTER INSERT trigger olustu', ok, err);

  Sq.Exec('SET ROLE mi');
  ok := TryExec(Sq,
    'MERGE INTO m USING src ON m.id = src.id ' +
    'WHEN NOT MATCHED THEN INSERT (id, v) VALUES (src.id, src.v)', err);
  Chk('AU7 MERGE INSERT WITH CHECK gecerli satiri ekledi', ok, err);
  Sq.Exec('SET ROLE NONE');
  Chk('AU7 MERGE INSERT satiri yazildi',
    CellQ(Sq, 'SELECT v FROM m WHERE id = 1') = 'new',
    'v=' + CellQ(Sq, 'SELECT v FROM m WHERE id = 1'));
  Chk('AU7 MERGE INSERT ROW trigger ateslendi',
    IntQ(Sq, 'SELECT COUNT(*) FROM audit') = 1,
    'audit=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM audit')));

  // WITH CHECK ihlali: id >= 10.
  Sq.Exec('INSERT INTO src (id, v) VALUES (12, ''bad'')');
  Sq.Exec('SET ROLE mi');
  ok := TryExec(Sq,
    'MERGE INTO m USING src ON m.id = src.id ' +
    'WHEN NOT MATCHED THEN INSERT (id, v) VALUES (src.id, src.v)', err);
  Chk('AU7 MERGE INSERT WITH CHECK ihlalini reddetti', not ok, err);
  Sq.Exec('SET ROLE NONE');
  Chk('AU7 MERGE INSERT ihlali satir eklemedi',
    IntQ(Sq, 'SELECT COUNT(*) FROM m WHERE id = 12') = 0);
  CloseAll;
end;

begin
  GPass := 0;
  GFail := 0;
  GSeq := 0;
  try CaseUpsertUpdatePrivilege except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AU1 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseUpsertRls except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AU2 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseUpsertTrigger except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AU3 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseMergeRlsTrigger except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AU4 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseMergeWithCheck except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AU5 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseMergeDeleteRls except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AU6 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseMergeInsertRls except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL AU7 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
