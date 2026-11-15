program sql_features;
{ v3.37 KALICI REGRESYON KAPISI - SKILL3 §9.1/§10.1 "eksik ozellik kapilari".
  Bu dosya, parser+executor'da UYGULANMIS ama hicbir kapida denenmemis SQL
  ozelliklerini gercek sonuclarla olcer. Amac "kod var" demek degil: her
  ozellik icin beklenen satir/kume karsilastirilir. Ozellik kirilirsa kapi
  kirmizi olur; boylece "uygulandi ama test edilmedi" listesi kuculur. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbErr;

var
  GDir, GDb: string;
  GPass, GFail: Integer;

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

{ Bir SQL cumlesini calistirir; hata olursa adini ve mesajini yazar. }
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
  GDir := GetTempDir + 'vdb_sf_' + AName + '_' + IntToStr(GetProcessID);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'sf.odb';
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

{ 1-2: SAVEPOINT / ROLLBACK TO / RELEASE SAVEPOINT - kismi geri alma. }
procedure CaseSavepoint;
var
  ok: Boolean;
begin
  OpenFresh('sp');
  ok := TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)', err);
  Chk('SF1 tablo olustu', ok, err);
  Sq.Exec('BEGIN');
  Sq.Exec('INSERT INTO t (id, v) VALUES (1, ''a'')');
  ok := TryExec(Sq, 'SAVEPOINT sp1', err);
  Chk('SF1 SAVEPOINT kabul edildi', ok, err);
  Sq.Exec('INSERT INTO t (id, v) VALUES (2, ''b'')');
  ok := TryExec(Sq, 'ROLLBACK TO SAVEPOINT sp1', err);
  Chk('SF1 ROLLBACK TO SAVEPOINT kabul edildi', ok, err);
  Sq.Exec('COMMIT');
  Chk('SF1 savepoint sonrasi yalniz onceki satir kalir',
    IntQ(Sq, 'SELECT COUNT(*) FROM t') = 1,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  Chk('SF1 savepoint sonrasi id=1 duruyor',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = 'a');
  Chk('SF1 savepoint sonrasi id=2 geri alindi',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id = 2') = 0);

  Sq.Exec('BEGIN');
  Sq.Exec('INSERT INTO t (id, v) VALUES (3, ''c'')');
  ok := TryExec(Sq, 'SAVEPOINT sp2', err);
  Chk('SF2 ikinci SAVEPOINT kabul edildi', ok, err);
  Sq.Exec('INSERT INTO t (id, v) VALUES (4, ''d'')');
  ok := TryExec(Sq, 'RELEASE SAVEPOINT sp2', err);
  Chk('SF2 RELEASE SAVEPOINT kabul edildi', ok, err);
  Sq.Exec('COMMIT');
  Chk('SF2 RELEASE sonrasi iki satir da kalir',
    IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id IN (3, 4)') = 2,
    'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE id IN (3, 4)')));
  CloseAll;
end;

{ 3: ON CONFLICT / UPSERT - cift anahtar veri butunlugu. }
procedure CaseUpsert;
var
  ok: Boolean;
begin
  OpenFresh('up');
  Sq.Exec('CREATE TABLE u (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('INSERT INTO u (id, v) VALUES (1, ''ilk'')');
  ok := TryExec(Sq,
    'INSERT INTO u (id, v) VALUES (1, ''ikinci'') ON CONFLICT DO NOTHING', err);
  Chk('SF3 ON CONFLICT DO NOTHING kabul edildi', ok, err);
  Chk('SF3 DO NOTHING eski degeri korur',
    CellQ(Sq, 'SELECT v FROM u WHERE id = 1') = 'ilk',
    'v=' + CellQ(Sq, 'SELECT v FROM u WHERE id = 1'));
  Chk('SF3 DO NOTHING satir sayisini artirmaz', IntQ(Sq, 'SELECT COUNT(*) FROM u') = 1);

  ok := TryExec(Sq,
    'INSERT INTO u (id, v) VALUES (1, ''guncel'') ' +
    'ON CONFLICT (id) DO UPDATE SET v = ''guncel''', err);
  Chk('SF3 ON CONFLICT DO UPDATE kabul edildi', ok, err);
  Chk('SF3 DO UPDATE degeri gunceller',
    CellQ(Sq, 'SELECT v FROM u WHERE id = 1') = 'guncel',
    'v=' + CellQ(Sq, 'SELECT v FROM u WHERE id = 1'));
  Chk('SF3 DO UPDATE satir sayisini artirmaz', IntQ(Sq, 'SELECT COUNT(*) FROM u') = 1);
  CloseAll;
end;

{ 4-6: VACUUM / REINDEX / ANALYZE - bakim komutlari veriyi bozmamali. }
procedure CaseMaintenance;
var
  i, ok: Integer;
begin
  OpenFresh('mt');
  Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
  for i := 1 to 60 do
    Sq.Exec('INSERT INTO m (id, v) VALUES (' + IntToStr(i) + ', ''v' + IntToStr(i) + ''')');
  Sq.Exec('CREATE INDEX ix_m_v ON m (v)');
  for i := 1 to 40 do
    Sq.Exec('DELETE FROM m WHERE id = ' + IntToStr(i));
  ok := IntQ(Sq, 'SELECT COUNT(*) FROM m');
  Chk('SF4 VACUUM oncesi 20 satir', ok = 20, 'satir=' + IntToStr(ok));

  Chk('SF4 VACUUM calisti', TryExec(Sq, 'VACUUM', err), err);
  ok := IntQ(Sq, 'SELECT COUNT(*) FROM m');
  Chk('SF4 VACUUM sonrasi satir sayisi korunur', ok = 20,
    'satir=' + IntToStr(ok));
  Chk('SF4 VACUUM sonrasi indeksli arama dogru',
    CellQ(Sq, 'SELECT id FROM m WHERE v = ''v50''') = '50',
    'id=' + CellQ(Sq, 'SELECT id FROM m WHERE v = ''v50'''));

  Chk('SF5 REINDEX calisti', TryExec(Sq, 'REINDEX', err), err);
  Chk('SF5 REINDEX sonrasi indeksli arama dogru',
    CellQ(Sq, 'SELECT id FROM m WHERE v = ''v55''') = '55',
    'id=' + CellQ(Sq, 'SELECT id FROM m WHERE v = ''v55'''));

  { ANALYZE tablo adi ister (`ANALYZE [TABLE] <tablo>`); sozdizimi
    parser'da boyle tanimli. Once sozdizimi hatasini, sonra dogru bicimi
    olcelim ki kapi davranisi belgelesin. }
  Chk('SF6 ANALYZE tablosuz reddedildi (kontrollu hata)',
    not TryExec(Sq, 'ANALYZE', err));
  Chk('SF6 ANALYZE calisti', TryExec(Sq, 'ANALYZE m', err), err);
  ok := IntQ(Sq, 'SELECT COUNT(*) FROM m');
  Chk('SF6 ANALYZE sonrasi satir sayisi korunur', ok = 20,
    'satir=' + IntToStr(ok));
  CloseAll;
end;

{ 7-8: WITH (CTE) ve WINDOW - sorgu anlambilimi. }
procedure CaseQueryFeatures;
var
  r: TSqlResult;
  ok: Boolean;
begin
  OpenFresh('qf');
  Sq.Exec('CREATE TABLE q (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('INSERT INTO q (id, v) VALUES (1, ''a'')');
  Sq.Exec('INSERT INTO q (id, v) VALUES (2, ''a'')');
  Sq.Exec('INSERT INTO q (id, v) VALUES (3, ''b'')');

  ok := TryExec(Sq,
    'WITH x AS (SELECT id FROM q WHERE v = ''a'') SELECT COUNT(*) FROM x', err);
  Chk('SF7 WITH (CTE) calisti', ok, err);
  if ok then
    Chk('SF7 CTE sonucu dogru',
      CellQ(Sq, 'WITH x AS (SELECT id FROM q WHERE v = ''a'') ' +
        'SELECT COUNT(*) FROM x') = '2');

  ok := TryExec(Sq,
    'SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM q ORDER BY id', err);
  Chk('SF8 WINDOW/OVER calisti', ok, err);
  if ok then
  begin
    r := Sq.Exec('SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM q ORDER BY id');
    Chk('SF8 WINDOW satir sayisi 3', Length(r.Rows) = 3,
      'satir=' + IntToStr(Length(r.Rows)));
    if Length(r.Rows) = 3 then
      Chk('SF8 WINDOW rn 1..3',
        (Trim(r.Rows[0][1]) = '1') and (Trim(r.Rows[1][1]) = '2') and
        (Trim(r.Rows[2][1]) = '3'),
        Trim(r.Rows[0][1]) + ',' + Trim(r.Rows[1][1]) + ',' + Trim(r.Rows[2][1]));
  end;
  CloseAll;
end;

{ 9: ALTER TABLE RENAME - sema degisikligi veriyi bozmamali. }
procedure CaseAlterTable;
var
  ok: Boolean;
begin
  OpenFresh('at');
  Sq.Exec('CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT)');
  Sq.Exec('INSERT INTO a (id, v) VALUES (1, ''x'')');
  ok := TryExec(Sq, 'ALTER TABLE a RENAME TO a2', err);
  Chk('SF9 ALTER TABLE RENAME calisti', ok, err);
  if ok then
  begin
    Chk('SF9 yeniden adlandirilan tabloda satir duruyor',
      IntQ(Sq, 'SELECT COUNT(*) FROM a2') = 1,
      'satir=' + IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM a2')));
    Chk('SF9 eski ad artik yok',
      not TryExec(Sq, 'SELECT COUNT(*) FROM a', err));
  end;
  CloseAll;
end;

begin
  GPass := 0;
  GFail := 0;
  try CaseSavepoint except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL SF1 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseUpsert except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL SF3 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseMaintenance except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL SF4 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseQueryFeatures except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL SF7 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  try CaseAlterTable except
    on E: Exception do begin Inc(GFail);
      WriteLn('FAIL SF9 beklenmeyen hata: ', E.ClassName, ': ', E.Message); end;
  end;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
