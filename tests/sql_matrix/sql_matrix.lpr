program sql_matrix;

{ Phase 5 - SQL davranis matrisi kapisi
  =====================================
  Tablo-gudumlu kapi: her durum kendi gecici veritabani dizininde kosar.
  Amac "SQL calisiyor mu" degil, DESTEKLENEN YUZEYIN SOZLESMESINI yazili ve
  yurutulebilir hale getirmek: her satir beklenen sonucu (tam izgara) ya da
  beklenen hatayi soyler. Boylece:
    - bilinmeyen bir davranis degisikligi kapiyi kirar,
    - desteklenmeyen bir yol sessizce yanlis sonuc uretemez,
    - docs/engineering/SQL_COVERAGE.md bu ciktidan uretilebilir.

  Durust sinirlar:
    - Kapi yalnizca burada listelenen durumlari kapsar; "tam SQL" iddiasi
      yoktur. Kapsam disi yuzey SQL_COVERAGE.md'de "desteklenmiyor" olarak
      yazilidir.
    - PostgreSQL diferansiyel testi DEGILDIR: beklenen degerler VDB'nin
      kendi sozlesmesidir (PG'den bilincli sapan yerler belgelenmistir).
    - Yalniz surec-ici kosar; es zamanli oturumlar bu kapinin konusu degil.
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbTable, VDbSql, VDbErr, VDbCore;

type
  TCase = record
    Group: string;
    Name: string;
    Setup: TStrArray;      // hepsi basarili olmali
    Probe: string;         // '' ise izgara kontrolu yok
    Expected: string;      // 'hucre,hucre|satir' bicimi
    ErrSql: string;        // '' ise hata kontrolu yok
    ErrName: string;       // '' ise herhangi bir EVDbException yeter
    Plan: string;          // kosumda doldurulur (matris icin)
  end;

var
  GPass, GFail: Integer;
  GBe: IVdbBackend;
  GTb: TVTableDb;
  GSql: TVSql;
  GCases: array of TCase;
  GCurPlan: string;
  GBadPlan: Integer;

const
  TestDirName = 'tmp';

procedure Add(const AGroup, AName: string; const ASetup: array of string;
  const AProbe, AExpected: string); overload;
var
  c: TCase;
  i: Integer;
begin
  c.Group := AGroup;
  c.Name := AName;
  SetLength(c.Setup, Length(ASetup));
  for i := 0 to High(ASetup) do
    c.Setup[i] := ASetup[i];
  c.Probe := AProbe;
  c.Expected := AExpected;
  c.ErrSql := '';
  c.ErrName := '';
  c.Plan := '';
  SetLength(GCases, Length(GCases) + 1);
  GCases[High(GCases)] := c;
end;

procedure AddErr(const AGroup, AName: string; const ASetup: array of string;
  const AErrSql, AErrName: string); overload;
var
  c: TCase;
  i: Integer;
begin
  c.Group := AGroup;
  c.Name := AName;
  SetLength(c.Setup, Length(ASetup));
  for i := 0 to High(ASetup) do
    c.Setup[i] := ASetup[i];
  c.Probe := '';
  c.Expected := '';
  c.ErrSql := AErrSql;
  c.ErrName := AErrName;
  c.Plan := '';
  SetLength(GCases, Length(GCases) + 1);
  GCases[High(GCases)] := c;
end;

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

// ------------------------------------------------------------------
// Ortam
// ------------------------------------------------------------------

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + TestDirName);
end;

function FreshDir(const AName: string): string;
var
  sr: TSearchRec;
  p: string;
begin
  Result := IncludeTrailingPathDelimiter(TestDir + 'mx_' + AName);
  if FindFirst(IncludeTrailingPathDelimiter(Result) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        p := IncludeTrailingPathDelimiter(Result) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
          p := IncludeTrailingPathDelimiter(p);
        DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ForceDirectories(Result);
end;

procedure OpenEnv(const ADir: string);
begin
  VdbOpen(ADir, GBe, True, True);
  GTb := TVTableDb.CreateBackend(GBe);
  GTb.Open(ADir);
  GSql := TVSql.Create(GTb);
end;

procedure CloseEnv;
begin
  FreeAndNil(GSql);
  FreeAndNil(GTb);
  GBe := nil;
end;

// ------------------------------------------------------------------
// Yardimcilar
// ------------------------------------------------------------------

{ Sonucu karsilastirilabilir tek bir metne cevirir: hucreler ',' ile,
  satirlar '|' ile ayrilir. Bos sonuc = ''. }
function GridOf(const r: TSqlResult): string;
var
  i, j: Integer;
  s: string;
begin
  Result := '';
  for i := 0 to High(r.Rows) do
  begin
    s := '';
    for j := 0 to High(r.Rows[i]) do
    begin
      if j > 0 then
        s := s + ',';
      s := s + r.Rows[i][j];
    end;
    if i > 0 then
      Result := Result + '|';
    Result := Result + s;
  end;
end;

procedure DoExec(const ASql: string; out APlan: string);
var
  r: TSqlResult;
begin
  r := GSql.Exec(ASql);
  APlan := r.PlanUsed;
end;

function ExecErr(const ASql: string; out ACode, AMsg: string): Boolean;
begin
  Result := False;
  ACode := '';
  AMsg := '';
  try
    GSql.Exec(ASql);
  except
    on E: EVDbException do
    begin
      Result := True;
      ACode := VDbErrorName(E.ErrorCode);
      AMsg := E.Message;
    end;
  end;
end;

// ------------------------------------------------------------------
// Durumlar
// ------------------------------------------------------------------

procedure DefineCases;
begin
  // ---------------- DDL ----------------
  Add('DDL', 'D1 CREATE TABLE + INSERT + SELECT',
    ['CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)',
     'INSERT INTO t (id, name) VALUES (1, ''ali'')'],
    'SELECT name FROM t WHERE id = 1', 'ali');

  Add('DDL', 'D2 INTEGER/REAL/TEXT kolonlari',
    ['CREATE TABLE t (i INTEGER, r REAL, s TEXT)',
     'INSERT INTO t (i, r, s) VALUES (7, 2.5, ''x'')'],
    'SELECT i, r, s FROM t', '7,2.5,x');

  Add('DDL', 'D3 BLOB kolonu tanimi',
    ['CREATE TABLE t (b BLOB)'],
    'SELECT COUNT(*) FROM t', '0');

  Add('DDL', 'D4 CREATE TABLE IF NOT EXISTS iki kez',
    ['CREATE TABLE IF NOT EXISTS t (id INTEGER)',
     'CREATE TABLE IF NOT EXISTS t (id INTEGER)'],
    'SELECT COUNT(*) FROM t', '0');

  Add('DDL', 'D5 CREATE INDEX + kullanilan plan',
    ['CREATE TABLE t (id INTEGER, v TEXT)',
     'INSERT INTO t (id, v) VALUES (1, ''a'')',
     'CREATE INDEX ix_t_id ON t (id)'],
    'SELECT v FROM t WHERE id = 1', 'a');

  Add('DDL', 'D6 ALTER TABLE ADD COLUMN',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1)',
     'ALTER TABLE t ADD COLUMN name TEXT',
     'UPDATE t SET name = ''n'' WHERE id = 1'],
    'SELECT name FROM t WHERE id = 1', 'n');

  Add('DDL', 'D7 DROP TABLE',
    ['CREATE TABLE t (id INTEGER)',
     'DROP TABLE t'],
    '', '');

  // ---------------- DML ----------------
  Add('DML', 'M1 cok satirli INSERT',
    ['CREATE TABLE t (id INTEGER, v TEXT)',
     'INSERT INTO t (id, v) VALUES (1,''a''),(2,''b''),(3,''c'')'],
    'SELECT COUNT(*) FROM t', '3');

  Add('DML', 'M2 kolon listesiz INSERT',
    ['CREATE TABLE t (id INTEGER, v TEXT)',
     'INSERT INTO t VALUES (1, ''a'')'],
    'SELECT id, v FROM t', '1,a');

  Add('DML', 'M3 UPDATE tek satir',
    ['CREATE TABLE t (id INTEGER, v TEXT)',
     'INSERT INTO t (id, v) VALUES (1,''a''),(2,''b'')',
     'UPDATE t SET v = ''z'' WHERE id = 1'],
    'SELECT v FROM t ORDER BY id', 'z|b');

  Add('DML', 'M4 DELETE WHERE',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1),(2),(3)',
     'DELETE FROM t WHERE id = 2'],
    'SELECT id FROM t ORDER BY id', '1|3');

  Add('DML', 'M5 INSERT ... SELECT',
    ['CREATE TABLE s (id INTEGER)',
     'CREATE TABLE d (id INTEGER)',
     'INSERT INTO s (id) VALUES (5),(6)',
     'INSERT INTO d (id) SELECT id FROM s'],
    'SELECT id FROM d ORDER BY id', '5|6');

  { RETURNING desteklidir (INSERT/UPDATE/DELETE). Bu kapi sozlesmeyi
    kilitler: onceki surumlerde "desteklenmiyor" sanildigi icin
    SQL_STUB_SURFACE.md'de yanlis yazmisti; duzeltildi. }
  Add('DML', 'M6 INSERT RETURNING tek satir',
    ['CREATE TABLE t (id INTEGER, v TEXT)'],
    'INSERT INTO t (id, v) VALUES (1, ''a'') RETURNING id', '1');

  Add('DML', 'M7 INSERT RETURNING cok satir',
    ['CREATE TABLE t (id INTEGER, v TEXT)'],
    'INSERT INTO t (id, v) VALUES (1, ''a''), (2, ''b'') RETURNING id', '1|2');

  // ---------------- SELECT ----------------
  Add('SELECT', 'S1 sabit ifade',
    [], 'SELECT 1 + 2', '3');

  Add('SELECT', 'S2 operator onceligi',
    [], 'SELECT 7 - 2 * 2', '3');

  Add('SELECT', 'S3 ORDER BY DESC',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1),(2),(3)'],
    'SELECT id FROM t ORDER BY id DESC', '3|2|1');

  Add('SELECT', 'S4 LIMIT',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1),(2),(3)'],
    'SELECT id FROM t ORDER BY id LIMIT 2', '1|2');

  Add('SELECT', 'S5 LIMIT + OFFSET',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1),(2),(3)'],
    'SELECT id FROM t ORDER BY id LIMIT 2 OFFSET 1', '2|3');

  Add('SELECT', 'S6 DISTINCT',
    ['CREATE TABLE t (v TEXT)',
     'INSERT INTO t (v) VALUES (''a''),(''a''),(''b'')'],
    'SELECT DISTINCT v FROM t ORDER BY v', 'a|b');

  Add('SELECT', 'S7 COUNT/SUM/MIN/MAX',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (1),(2),(3)'],
    'SELECT COUNT(*), SUM(n), MIN(n), MAX(n) FROM t', '3,6,1,3');

  Add('SELECT', 'S8 AVG',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (1),(2),(3)'],
    'SELECT AVG(n) FROM t', '2');

  Add('SELECT', 'S9 WHERE karsilastirma operatorleri',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1),(2),(3),(4)'],
    'SELECT id FROM t WHERE id > 2 AND id <> 4', '3');

  Add('SELECT', 'S10 BETWEEN',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1),(2),(3),(4),(5)'],
    'SELECT id FROM t WHERE id BETWEEN 2 AND 4 ORDER BY id', '2|3|4');

  Add('SELECT', 'S11 IN listesi',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1),(2),(3)'],
    'SELECT id FROM t WHERE id IN (1,3) ORDER BY id', '1|3');

  Add('SELECT', 'S12 LIKE',
    ['CREATE TABLE t (v TEXT)',
     'INSERT INTO t (v) VALUES (''ali''),(''veli''),(''ayse'')'],
    'SELECT v FROM t WHERE v LIKE ''a%'' ORDER BY v', 'ali|ayse');

  Add('SELECT', 'S13 IS NULL / IS NOT NULL',
    ['CREATE TABLE t (id INTEGER, v TEXT)',
     'INSERT INTO t (id, v) VALUES (1, ''a''),(2, NULL)'],
    'SELECT id FROM t WHERE v IS NULL', '2');

  Add('SELECT', 'S14 GROUP BY',
    ['CREATE TABLE t (g TEXT, n INTEGER)',
     'INSERT INTO t (g, n) VALUES (''a'',1),(''a'',2),(''b'',5)'],
    'SELECT g, SUM(n) FROM t GROUP BY g ORDER BY g', 'a,3|b,5');

  Add('SELECT', 'S15 HAVING',
    ['CREATE TABLE t (g TEXT, n INTEGER)',
     'INSERT INTO t (g, n) VALUES (''a'',1),(''a'',2),(''b'',5)'],
    'SELECT g FROM t GROUP BY g HAVING SUM(n) > 3', 'b');

  Add('SELECT', 'S16 INNER JOIN',
    ['CREATE TABLE a (id INTEGER, v TEXT)',
     'CREATE TABLE b (id INTEGER, w TEXT)',
     'INSERT INTO a (id, v) VALUES (1, ''a1''),(2, ''a2'')',
     'INSERT INTO b (id, w) VALUES (1, ''b1'')'],
    'SELECT a.v, b.w FROM a INNER JOIN b ON a.id = b.id', 'a1,b1');

  Add('SELECT', 'S17 LEFT JOIN',
    ['CREATE TABLE a (id INTEGER, v TEXT)',
     'CREATE TABLE b (id INTEGER, w TEXT)',
     'INSERT INTO a (id, v) VALUES (1, ''a1''),(2, ''a2'')',
     'INSERT INTO b (id, w) VALUES (1, ''b1'')'],
    'SELECT a.id, b.w FROM a LEFT JOIN b ON a.id = b.id ORDER BY a.id', '1,b1|2,');

  Add('SELECT', 'S18 alt sorgu (IN)',
    ['CREATE TABLE a (id INTEGER)',
     'CREATE TABLE b (id INTEGER)',
     'INSERT INTO a (id) VALUES (1),(2),(3)',
     'INSERT INTO b (id) VALUES (2),(3)'],
    'SELECT id FROM a WHERE id IN (SELECT id FROM b) ORDER BY id', '2|3');

  Add('SELECT', 'S19 skaler alt sorgu',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (4),(5)'],
    'SELECT (SELECT MAX(n) FROM t) + 1', '6');

  Add('SELECT', 'S20 UNION (tekrarlari atar)',
    ['CREATE TABLE a (id INTEGER)',
     'CREATE TABLE b (id INTEGER)',
     'INSERT INTO a (id) VALUES (1),(2)',
     'INSERT INTO b (id) VALUES (2),(3)'],
    'SELECT id FROM a UNION SELECT id FROM b ORDER BY id', '1|2|3');

  Add('SELECT', 'S21 UNION ALL (tekrarlari korur)',
    ['CREATE TABLE a (id INTEGER)',
     'CREATE TABLE b (id INTEGER)',
     'INSERT INTO a (id) VALUES (1),(2)',
     'INSERT INTO b (id) VALUES (2),(3)'],
    'SELECT id FROM a UNION ALL SELECT id FROM b', '1|2|2|3');

  Add('SELECT', 'S22 CASE WHEN',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (1),(2),(3)'],
    'SELECT CASE WHEN n = 2 THEN ''iki'' ELSE ''diger'' END FROM t ORDER BY n',
    'diger|iki|diger');

  Add('SELECT', 'S23 UPPER/LOWER/LENGTH',
    ['CREATE TABLE t (v TEXT)',
     'INSERT INTO t (v) VALUES (''AbC'')'],
    'SELECT UPPER(v), LOWER(v), LENGTH(v) FROM t', 'ABC,abc,3');

  { SUBSTR/SUBSTRING/TRIM bu surumde YOK; bilinmeyen fonksiyon
    ecUnsupported ile GURULTULU reddedilir (sessiz yanlis sonuc yok). }
  AddErr('SELECT', 'S24 SUBSTR desteklenmiyor (gurultulu ret)', [],
    'SELECT SUBSTR(''abcdef'', 2, 3)', 'ecUnsupported');

  Add('SELECT', 'S24b desteklenen skaler fonksiyonlar',
    ['CREATE TABLE t (v TEXT)',
     'INSERT INTO t (v) VALUES (''abc'')'],
    'SELECT LENGTH(v), UPPER(v), LOWER(v), ABS(-3), ROUND(2.6) FROM t', '3,ABC,abc,3,3');

  Add('SELECT', 'S25 COALESCE',
    ['CREATE TABLE t (v TEXT)',
     'INSERT INTO t (v) VALUES (NULL),(''x'')'],
    'SELECT COALESCE(v, ''yok'') FROM t', 'yok|x');

  Add('SELECT', 'S26 alias + ORDER BY alias',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (2),(1)'],
    'SELECT n AS k FROM t ORDER BY k', '1|2');

  Add('SELECT', 'S27 WHERE + agregat',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (1),(2),(3),(10)'],
    'SELECT SUM(n) FROM t WHERE n < 5', '6');

  // ---------------- TRANSACTION ----------------
  Add('TXN', 'T1 BEGIN/COMMIT kalici',
    ['CREATE TABLE t (id INTEGER)',
     'BEGIN',
     'INSERT INTO t (id) VALUES (1)',
     'COMMIT'],
    'SELECT COUNT(*) FROM t', '1');

  Add('TXN', 'T2 BEGIN/ROLLBACK geri alir',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (1)',
     'BEGIN',
     'INSERT INTO t (id) VALUES (2)',
     'ROLLBACK'],
    'SELECT COUNT(*) FROM t', '1');

  // ---------------- HATA YOLLARI ----------------
  AddErr('ERR', 'E1 olmayan tablo', [], 'SELECT * FROM yok_boyle_tablo', '');

  AddErr('ERR', 'E2 olmayan kolon',
    ['CREATE TABLE t (id INTEGER)'],
    'SELECT yok_kolon FROM t', '');

  AddErr('ERR', 'E3 PRIMARY KEY ihlali',
    ['CREATE TABLE t (id INTEGER PRIMARY KEY)',
     'INSERT INTO t (id) VALUES (1)'],
    'INSERT INTO t (id) VALUES (1)', '');

  AddErr('ERR', 'E4 NOT NULL ihlali',
    ['CREATE TABLE t (id INTEGER NOT NULL)'],
    'INSERT INTO t (id) VALUES (NULL)', '');

  AddErr('ERR', 'E5 UNIQUE index ihlali',
    ['CREATE TABLE t (v TEXT)',
     'CREATE UNIQUE INDEX ux_t_v ON t (v)',
     'INSERT INTO t (v) VALUES (''a'')'],
    'INSERT INTO t (v) VALUES (''a'')', '');

  AddErr('ERR', 'E6 sozdizimi hatasi', [], 'SELECT FROM', '');

  Add('ERR', 'E7 DROP TABLE IF EXISTS sessiz gecer',
    [], 'DROP TABLE IF EXISTS yok_boyle_tablo', '');

  AddErr('ERR', 'E8 olmayan tabloya INSERT', [],
    'INSERT INTO yok_boyle (id) VALUES (1)', '');

  { ---------------- REF: referans dogrulamasi ----------------
    Phase-5 duzeltmesi: kolon cozumu satir basina yapildigi icin, BOS
    tabloda olmayan kolon sessizce bos kume donduruyordu (SUM icin bos
    hucre). Artik hazirlik asamasinda ecColumnNotFound. Bu durumlar
    duzeltmenin geri gelmemesini kilitler. }
  AddErr('REF', 'R1 bos tabloda olmayan kolon (SELECT)',
    ['CREATE TABLE e (id INTEGER, v TEXT)'],
    'SELECT yok_kolon FROM e', 'ecColumnNotFound');

  AddErr('REF', 'R2 bos tabloda olmayan kolon (WHERE)',
    ['CREATE TABLE e (id INTEGER, v TEXT)'],
    'SELECT id FROM e WHERE yok_kolon = 1', 'ecColumnNotFound');

  AddErr('REF', 'R3 bos tabloda olmayan kolon (SUM)',
    ['CREATE TABLE e (id INTEGER)'],
    'SELECT SUM(yok_kolon) FROM e', 'ecColumnNotFound');

  AddErr('REF', 'R4 bos tabloda olmayan kolon (GROUP BY)',
    ['CREATE TABLE e (id INTEGER)'],
    'SELECT yok_kolon, SUM(id) FROM e GROUP BY yok_kolon', 'ecColumnNotFound');

  AddErr('REF', 'R5 bos tabloda olmayan kolon (ORDER BY)',
    ['CREATE TABLE e (id INTEGER)'],
    'SELECT id FROM e ORDER BY yok_kolon', 'ecColumnNotFound');

  AddErr('REF', 'R6 view uzerinden olmayan kolon',
    ['CREATE TABLE e (id INTEGER, v TEXT)',
     'CREATE VIEW vw AS SELECT id, v FROM e'],
    'SELECT yok_kolon FROM vw', 'ecColumnNotFound');

  { ORDER BY alias kabul edilir (S26). GROUP BY alias ise KABUL EDILMEZ:
    motor "GROUP BY kolonu bulunamadi" verir. PostgreSQL aliase'e izin
    verdigi icin bu bilincli bir farktir; SQL_COVERAGE.md'de yazilidir. }
  AddErr('REF', 'R7 GROUP BY alias kabul edilmez (bilinen fark)',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (1),(2),(2)'],
    'SELECT n AS k, COUNT(*) AS c FROM t GROUP BY k', 'ecColumnNotFound');

  Add('REF', 'R7b ORDER BY alias kabul edilir',
    ['CREATE TABLE t (n INTEGER)',
     'INSERT INTO t (n) VALUES (1),(2),(2)'],
    'SELECT n AS k, COUNT(*) AS c FROM t GROUP BY n ORDER BY k', '1,1|2,2');

  Add('REF', 'R8 nitelikli referans (tablo.adi)',
    ['CREATE TABLE t (id INTEGER)',
     'INSERT INTO t (id) VALUES (9)'],
    'SELECT t.id FROM t', '9');
end;

// ------------------------------------------------------------------

procedure RunCase(const AIdx: Integer);
var
  c: TCase;
  i: Integer;
  grid, code, msg, detail, tag: string;
  r: TSqlResult;
  ok: Boolean;
  setupErr: Boolean;
begin
  c := GCases[AIdx];
  tag := '[' + c.Group + '] ' + c.Name;
  OpenEnv(FreshDir('c' + IntToStr(AIdx)));
  try
    setupErr := False;
    detail := '';
    for i := 0 to High(c.Setup) do
    begin
      try
        r := GSql.Exec(c.Setup[i]);
        GCurPlan := r.PlanUsed;
      except
        on E: EVDbException do
        begin
          setupErr := True;
          detail := 'setup hata: ' + c.Setup[i] + ' -> ' +
            VDbErrorName(E.ErrorCode) + ' ' + E.Message;
        end;
      end;
      if setupErr then
        Break;
    end;

    if setupErr then
    begin
      Chk(tag, False, detail);
      Exit;
    end;

    if c.ErrSql <> '' then
    begin
      ok := ExecErr(c.ErrSql, code, msg);
      if not ok then
        detail := 'hata beklendi, gelmedi: ' + c.ErrSql
      else
      begin
        detail := 'err=' + code;
        if c.ErrName <> '' then
          ok := (code = c.ErrName);
        if not ok then
          detail := detail + ' beklenen=' + c.ErrName;
      end;
      Chk(tag, ok, detail);
      Exit;
    end;

    if c.Probe <> '' then
    begin
      try
        r := GSql.Exec(c.Probe);
      except
        on E: EVDbException do
        begin
          Chk(tag, False, 'probe hata: ' + VDbErrorName(E.ErrorCode) + ' ' + E.Message);
          Exit;
        end;
      end;
      GCurPlan := r.PlanUsed;
      grid := GridOf(r);
      Chk(tag, grid = c.Expected,
        'beklenen="' + c.Expected + '" gelen="' + grid + '" plan=' + r.PlanUsed);
    end
    else
      Chk(tag, True, 'calisti');
  finally
    CloseEnv;
  end;
end;

procedure PrintMatrix;
var
  i: Integer;
  lastGroup: string;
begin
  WriteLn;
  WriteLn('--- MATRIS ---');
  lastGroup := '';
  for i := 0 to High(GCases) do
  begin
    if GCases[i].Group <> lastGroup then
    begin
      lastGroup := GCases[i].Group;
      WriteLn('## ', lastGroup);
    end;
    WriteLn(GCases[i].Name, ' :: ', GCases[i].Plan);
  end;
end;

var
  i: Integer;
begin
  GPass := 0;
  GFail := 0;
  GBadPlan := 0;
  ForceDirectories(TestDir);
  DefineCases;
  for i := 0 to High(GCases) do
  begin
    RunCase(i);
    GCases[i].Plan := GCurPlan;
  end;
  PrintMatrix;
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then
    Halt(1);
end.
