program v3sqlchk;

{ VDB v3 - SQL katmaninin SAYFA MOTORU uzerinde dogrulanmasi (Sprint 2.7)

  Amac: v3'u yalniz KV katmaninda degil, TVSql/TVTableDb uzerinden de
  sinamak. TVTableDb.CreateBackend(IVDbBackend) ile alt katman tamamen
  TVdbBackendV3'tur; v2 moturu (TVDb) yalniz arayuz tipleri icin link
  edilir, veri yolu olarak KULLANILMAZ.

  Kapsanan davranislar (SQL sozlesmesi):
    CREATE TABLE / INSERT / bilincli toplu INSERT (VALUES coklu)
    SELECT / WHERE / ORDER BY / COUNT(*) / SUM / GROUP BY / JOIN
    UPDATE / DELETE / LIMIT / OFFSET / DISTINCT
    PRIMARY KEY (tekil ihlali) / UNIQUE / NOT NULL / CHECK
    INDEX olusturma ve indeksli arama
    BEGIN / COMMIT / ROLLBACK (gercek geri alma)
    Sema kaliciligi: yeniden acilista tablo+satir+indeks ayni
    Bozuk/eksik veri yok: her satir birebir dogrulanir
}

{$mode delphi}{$H+}

uses
  Classes, SysUtils, VDbBackendApi, VDbCore, VDbBackendV3, VDbTable, VDbSql,
  VDbTypes, VDbErr, VDbPageEngine;

var
  gPass, gFail: Int64;
  gDir: string;
  b: TBytes;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function DirOf(const N: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + N;
end;

procedure CleanDir;
var
  sr: TSearchRec;
  base: string;
begin
  base := IncludeTrailingPathDelimiter(gDir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        if (sr.Attr and faDirectory) = 0 then
          DeleteFile(base + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

type
  TV3Sql = record
    Be: IVdbBackend;
    Tb: TVTableDb;
    Sq: TVSql;
  end;

var
  { Son Exec cagrisi hata firlatti mi? TSqlResult'ta Ok alani yok; motor
    hatalari EVDbException olarak firlatir. Kapi kolayligi icin yakalanir. }
  gErr: Boolean;

function OpenV3(out S: TV3Sql; const FileName: string; Create_: Boolean;
  Pool: Integer = 64): Boolean;
begin
  Result := False;
  S.Be := TVdbBackendV3.Create(DirOf(FileName), Create_, Pool);
  S.Tb := TVTableDb.CreateBackend(S.Be);
  S.Sq := TVSql.Create(S.Tb);
  S.Tb.Open(gDir);
  Result := True;
end;

procedure CloseV3(var S: TV3Sql);
begin
  if S.Sq <> nil then FreeAndNil(S.Sq);
  if S.Tb <> nil then
  begin
    S.Tb.Close;
    FreeAndNil(S.Tb);
  end;
  S.Be := nil;
end;

{ Guvenli hucre erisimi: hata durumunda Rows nil olabilir. }
function Cel(const R: TSqlResult; Row, Col: Integer): string;
begin
  if (Row < 0) or (Row > High(R.Rows)) or (Col < 0) or (Col > High(R.Rows[Row])) then
    Result := '<yok>'
  else
    Result := R.Rows[Row][Col];
end;
function Exec(const S: TV3Sql; const Sql: string): TSqlResult;
begin
  gErr := False;
  try
    Result := S.Sq.Exec(Sql);
  except
    on E: Exception do
    begin
      gErr := True;
      Result.Fields := nil;
      Result.Rows := nil;
      Result.Affected := 0;
      Result.Stmts := 0;
      Result.Msg := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ ============================================================ 1) temel DML }

procedure TestBasic;
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
begin
  CleanDir;
  OpenV3(S, 'basic.odb', True);
  try
    r := Exec(S, 'CREATE TABLE t (id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER, ' +
      'maas REAL)');
    if not gErr then Ok('CREATE TABLE') else Fail('CREATE TABLE: ' + r.Msg);

    r := Exec(S, 'INSERT INTO t VALUES (1, ''Ali'', 30, 1000.5)');
    if not gErr and (r.Affected = 1) then Ok('INSERT tek satir')
    else Fail('INSERT: ' + r.Msg);

    r := Exec(S, 'INSERT INTO t VALUES (2, ''Veli'', 40, 2000), ' +
      '(3, ''Ayse'', 25, 1500), (4, ''Fatma'', 35, 1750)');
    if not gErr and (r.Affected = 3) then Ok('INSERT coklu VALUES (3 satir)')
    else Fail('INSERT coklu: ' + IntToStr(r.Affected) + ' ' + r.Msg);

    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '4') then Ok('COUNT(*) = 4')
    else Fail('COUNT(*): ' + r.Msg + ' / ' + Cel(r,0,0));

    r := Exec(S, 'SELECT ad FROM t WHERE id = 3');
    if not gErr and (Cel(r,0,0) = 'Ayse') then Ok('PK WHERE')
    else Fail('PK WHERE');

    r := Exec(S, 'SELECT ad FROM t ORDER BY yas DESC');
    if not gErr and (Cel(r,0,0) = 'Veli') and (Cel(r,3,0) = 'Ayse') then
      Ok('ORDER BY yas DESC')
    else Fail('ORDER BY');

    r := Exec(S, 'SELECT COUNT(*), SUM(yas) FROM t');
    if not gErr and (Cel(r,0,0) = '4') and (Cel(r,0,1) = '130') then
      Ok('COUNT + SUM (130)')
    else Fail('agrega: ' + r.Msg);

    r := Exec(S, 'SELECT yas, COUNT(*) FROM t GROUP BY yas ORDER BY yas');
    if not gErr and (Length(r.Rows) = 4) then Ok('GROUP BY (4 grup)')
    else Fail('GROUP BY');

    { guncelleme ve silme }
    r := Exec(S, 'UPDATE t SET maas = maas * 2 WHERE yas >= 35');
    if not gErr and (r.Affected = 2) then Ok('UPDATE 2 satir')
    else Fail('UPDATE: ' + IntToStr(r.Affected) + ' ' + r.Msg);

    r := Exec(S, 'SELECT maas FROM t WHERE id = 4');
    if not gErr and (Cel(r,0,0) = '3500') then Ok('UPDATE degeri motorda gorunur')
    else Fail('UPDATE degeri: ' + r.Msg);

    r := Exec(S, 'DELETE FROM t WHERE id = 2');
    if not gErr and (r.Affected = 1) then Ok('DELETE 1 satir') else Fail('DELETE');

    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '3') then Ok('silme sonrasi COUNT = 3')
    else Fail('silme sonrasi COUNT');
  finally
    CloseV3(S);
  end;

  { yeniden acilis: kalicilik }
  OpenV3(S, 'basic.odb', False);
  try
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '3') then Ok('yeniden acilista 3 satir')
    else Fail('yeniden acilis COUNT: ' + r.Msg);
    r := Exec(S, 'SELECT ad, maas FROM t WHERE id = 4');
    if not gErr and (Cel(r,0,0) = 'Fatma') and (Cel(r,0,1) = '3500') then
      Ok('yeniden acilista guncel deger birebir')
    else Fail('yeniden acilis deger: ' + r.Msg);
    r := Exec(S, 'SELECT COUNT(*) FROM t WHERE id = 2');
    if not gErr and (Cel(r,0,0) = '0') then Ok('silinen satir kalici')
    else Fail('silinen satir geri geldi');
  finally
    CloseV3(S);
  end;
end;

{ ===================================================== 2) toplu INSERT yolu }

procedure TestBulkInsert(N: Integer);
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
  sql: string;
begin
  CleanDir;
  OpenV3(S, 'bulk.odb', True, 8);   { 8 sayfalik havuz: tahliye yolu }
  try
    r := Exec(S, 'CREATE TABLE b (id INTEGER PRIMARY KEY, v INTEGER)');
    if not not gErr then Fail('CREATE b: ' + r.Msg);

    { F2: tek ifadede coklu VALUES -> ic batch }
    sql := 'INSERT INTO b VALUES ';
    for i := 1 to 500 do
    begin
      if i > 1 then sql := sql + ',';
      sql := sql + Format('(%d,%d)', [i, i * 7]);
    end;
    r := Exec(S, sql);
    if not gErr and (r.Affected = 500) then Ok('coklu VALUES 500 satir')
    else Fail('coklu VALUES: ' + IntToStr(r.Affected) + ' ' + r.Msg);

    { tek tek INSERT: autocommit yolu }
    for i := 501 to N do
      r := Exec(S, Format('INSERT INTO b VALUES (%d,%d)', [i, i * 7]));
    r := Exec(S, 'SELECT COUNT(*) FROM b');
    if not gErr and (Cel(r,0,0) = IntToStr(N)) then
      Ok(Format('autocommit INSERT -> %d satir', [N]))
    else Fail('autocommit INSERT: ' + r.Msg);

    r := Exec(S, Format('SELECT v FROM b WHERE id = %d', [N]));
    if not gErr and (Cel(r,0,0) = IntToStr(N * 7)) then Ok('son satir dogru')
    else Fail('son satir: ' + r.Msg);

    r := Exec(S, 'SELECT SUM(v) FROM b');
    if not gErr and (Cel(r,0,0) = IntToStr(N * (N + 1) div 2 * 7)) then
      Ok('SUM tum satirlarda dogru')
    else Fail('SUM: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  OpenV3(S, 'bulk.odb', False, 8);
  try
    r := Exec(S, 'SELECT COUNT(*) FROM b');
    if not gErr and (Cel(r,0,0) = IntToStr(N)) then
      Ok(Format('yeniden acilista %d satir', [N]))
    else Fail('yeniden acilis: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

{ ========================================================= 3) islem / rollback }

procedure TestTxn;
var
  S: TV3Sql;
  r: TSqlResult;
begin
  CleanDir;
  OpenV3(S, 'txn.odb', True);
  try
    Exec(S, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    Exec(S, 'INSERT INTO t VALUES (1, 10)');

    r := Exec(S, 'BEGIN');
    if not gErr then Ok('BEGIN') else Fail('BEGIN: ' + r.Msg);
    Exec(S, 'INSERT INTO t VALUES (2, 20)');
    Exec(S, 'UPDATE t SET v = 99 WHERE id = 1');
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '2') then Ok('islem icinde 2 satir gorunur')
    else Fail('islem ici COUNT');

    r := Exec(S, 'ROLLBACK');
    if not gErr then Ok('ROLLBACK') else Fail('ROLLBACK: ' + r.Msg);

    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '1') then Ok('ROLLBACK eklenen satiri geri aldi')
    else Fail('ROLLBACK sonrasi COUNT: ' + r.Msg);
    r := Exec(S, 'SELECT v FROM t WHERE id = 1');
    if not gErr and (Cel(r,0,0) = '10') then Ok('ROLLBACK guncellemeyi geri aldi')
    else Fail('ROLLBACK sonrasi deger: ' + r.Msg);

    Exec(S, 'BEGIN');
    Exec(S, 'INSERT INTO t VALUES (3, 30)');
    r := Exec(S, 'COMMIT');
    if not gErr then Ok('COMMIT') else Fail('COMMIT: ' + r.Msg);
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '2') then Ok('COMMIT kalici (2 satir)')
    else Fail('COMMIT sonrasi COUNT');
  finally
    CloseV3(S);
  end;

  OpenV3(S, 'txn.odb', False);
  try
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '2') then Ok('islem sonucu diskte kalici')
    else Fail('islem kaliciligi: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

{ ============================================================= 4) kisitlar }

procedure TestConstraints;
var
  S: TV3Sql;
  r: TSqlResult;
begin
  CleanDir;
  OpenV3(S, 'cons.odb', True);
  try
    Exec(S, 'CREATE TABLE t (id INTEGER PRIMARY KEY, kod TEXT UNIQUE, ' +
      'ad TEXT NOT NULL, yas INTEGER CHECK (yas >= 0))');
    r := Exec(S, 'INSERT INTO t VALUES (1, ''a'', ''Ali'', 10)');
    if not gErr then Ok('kisitli tabloya gecerli INSERT')
    else Fail('gecerli INSERT: ' + r.Msg);

    r := Exec(S, 'INSERT INTO t VALUES (1, ''b'', ''Veli'', 20)');
    if not not gErr then Ok('PRIMARY KEY tekillik ihlali reddedildi')
    else Fail('PK ihlali kabul edildi');

    r := Exec(S, 'INSERT INTO t VALUES (2, ''a'', ''Veli'', 20)');
    if not not gErr then Ok('UNIQUE ihlali reddedildi')
    else Fail('UNIQUE ihlali kabul edildi');

    r := Exec(S, 'INSERT INTO t VALUES (3, ''c'', NULL, 20)');
    if not not gErr then Ok('NOT NULL ihlali reddedildi')
    else Fail('NOT NULL ihlali kabul edildi');

    r := Exec(S, 'INSERT INTO t VALUES (4, ''d'', ''Ayse'', -5)');
    if not not gErr then Ok('CHECK ihlali reddedildi')
    else Fail('CHECK ihlali kabul edildi');

    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = '1') then Ok('ihlallerden sonra yalniz 1 satir')
    else Fail('ihlal sonrasi COUNT: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

{ ============================================================== 5) indeks }

procedure TestIndex;
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
begin
  CleanDir;
  OpenV3(S, 'idx.odb', True);
  try
    Exec(S, 'CREATE TABLE t (id INTEGER PRIMARY KEY, ad TEXT, sehir TEXT)');
    Exec(S, 'BEGIN');
    for i := 1 to 300 do
      Exec(S, Format('INSERT INTO t VALUES (%d, ''ad%d'', ''sehir%d'')',
        [i, i, i mod 10]));
    Exec(S, 'COMMIT');

    r := Exec(S, 'CREATE INDEX ix_ad ON t (ad)');
    if not gErr then Ok('CREATE INDEX') else Fail('CREATE INDEX: ' + r.Msg);

    r := Exec(S, 'SELECT id FROM t WHERE ad = ''ad250''');
    if not gErr and (Length(r.Rows) = 1) and (Cel(r,0,0) = '250') then
      Ok('indeksli arama dogru satiri buldu')
    else Fail('indeksli arama: ' + r.Msg);

    r := Exec(S, 'SELECT COUNT(*) FROM t WHERE sehir = ''sehir3''');
    if not gErr and (Cel(r,0,0) = '30') then Ok('indekssiz filtre 30 satir')
    else Fail('indekssiz filtre: ' + r.Msg);

    r := Exec(S, 'INSERT INTO t VALUES (301, ''ad999'', ''yeni'')');
    if not gErr then Ok('indeksli tabloya INSERT')
    else Fail('indeksli INSERT: ' + r.Msg);
    r := Exec(S, 'SELECT id FROM t WHERE ad = ''ad999''');
    if not gErr and (Length(r.Rows) = 1) and (Cel(r,0,0) = '301') then
      Ok('yeni satir indekste gorunur')
    else Fail('yeni satir indekste yok');
  finally
    CloseV3(S);
  end;

  OpenV3(S, 'idx.odb', False);
  try
    r := Exec(S, 'SELECT id FROM t WHERE ad = ''ad250''');
    if not gErr and (Length(r.Rows) = 1) and (Cel(r,0,0) = '250') then
      Ok('yeniden acilista indeks calisiyor')
    else Fail('yeniden acilis indeks: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

{ ========================================================= 6) JOIN / DISTINCT }

procedure TestJoin;
var
  S: TV3Sql;
  r: TSqlResult;
begin
  CleanDir;
  OpenV3(S, 'join.odb', True);
  try
    Exec(S, 'CREATE TABLE d (id INTEGER PRIMARY KEY, ad TEXT)');
    Exec(S, 'CREATE TABLE p (id INTEGER PRIMARY KEY, dept INTEGER, ad TEXT)');
    Exec(S, 'INSERT INTO d VALUES (1, ''Ar-Ge'')');
    Exec(S, 'INSERT INTO d VALUES (2, ''Satis'')');
    Exec(S, 'INSERT INTO p VALUES (1, 1, ''Ali'')');
    Exec(S, 'INSERT INTO p VALUES (2, 1, ''Veli'')');
    Exec(S, 'INSERT INTO p VALUES (3, 2, ''Ayse'')');

    r := Exec(S, 'SELECT d.ad, COUNT(*) FROM d JOIN p ON p.dept = d.id ' +
      'GROUP BY d.ad ORDER BY d.ad');
    if not gErr and (Length(r.Rows) = 2) and (Cel(r,0,0) = 'Ar-Ge') and
       (Cel(r,0,1) = '2') then Ok('JOIN + GROUP BY (Ar-Ge=2)')
    else Fail('JOIN: ' + r.Msg);

    r := Exec(S, 'SELECT DISTINCT dept FROM p ORDER BY dept');
    if not gErr and (Length(r.Rows) = 2) then Ok('DISTINCT 2 deger')
    else Fail('DISTINCT: ' + r.Msg);

    r := Exec(S, 'SELECT ad FROM p ORDER BY ad LIMIT 2 OFFSET 1');
    if not gErr and (Length(r.Rows) = 2) and (Cel(r,0,0) = 'Ayse') then
      Ok('LIMIT/OFFSET sirali')
    else Fail('LIMIT/OFFSET: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

{ ======================================= 7) satir butunlugu (buyuk tablo) }

procedure TestIntegrity(N: Integer);
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
  bad: Integer;
begin
  CleanDir;
  OpenV3(S, 'intg.odb', True, 16);
  try
    Exec(S, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)');
    Exec(S, 'BEGIN');
    for i := 1 to N do
      if (i mod 100) = 0 then
        Exec(S, Format('INSERT INTO t VALUES (%d,%d,''%s'')',
          [i, i * 3, StringOfChar('x', 200)]))
      else
        Exec(S, Format('INSERT INTO t VALUES (%d,%d,''satir%d'')', [i, i * 3, i]));
    Exec(S, 'COMMIT');

    bad := 0;
    for i := 1 to N do
    begin
      r := Exec(S, Format('SELECT v FROM t WHERE id = %d', [i]));
      if (not not gErr) or (Length(r.Rows) <> 1) or (Cel(r,0,0) <> IntToStr(i * 3)) then
      begin
        Inc(bad);
        if bad <= 3 then
          Fail(Format('satir %d bozuk/eksik', [i]));
      end;
    end;
    if bad = 0 then Ok(Format('%d satirin tamami birebir (200 baytlik satirlar dahil)', [N]));

    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = IntToStr(N)) then Ok('COUNT tam')
    else Fail('COUNT: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  OpenV3(S, 'intg.odb', False, 16);
  try
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if not gErr and (Cel(r,0,0) = IntToStr(N)) then
      Ok('yeniden acilista COUNT tam')
    else
      Fail('yeniden acilista COUNT: ' + Cel(r,0,0) + ' (beklenen ' +
        IntToStr(N) + ') ' + r.Msg);
    bad := 0;
    for i := 1 to N do
    begin
      r := Exec(S, Format('SELECT v FROM t WHERE id = %d', [i]));
      if gErr or (Length(r.Rows) <> 1) or (Cel(r,0,0) <> IntToStr(i * 3)) then
      begin
        Inc(bad);
        if bad <= 3 then
          Fail(Format('yeniden acilista satir %d bozuk (gelen=%s satir=%d)',
            [i, Cel(r,0,0), Length(r.Rows)]));
      end;
    end;
    if bad > 3 then WriteLn(Format('        (toplam %d bozuk satir)', [bad]));
    if bad = 0 then Ok(Format('yeniden acilista %d satir birebir', [N]));
  finally
    CloseV3(S);
  end;
end;

{ ================================================================== ana }

var
  N: Integer;
begin
  gPass := 0;
  gFail := 0;
  N := 2000;
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  if ParamCount >= 2 then N := StrToIntDef(ParamStr(2), N);
  if not DirectoryExists(gDir) then ForceDirectories(gDir);

  WriteLn('VDB v3 v3sqlchk - SQL katmani sayfa motoru uzerinde');
  WriteLn('dizin=', gDir, '  N=', N);
  WriteLn;

  TestBasic;
  TestBulkInsert(N);
  TestTxn;
  TestConstraints;
  TestIndex;
  TestJoin;
  TestIntegrity(N);

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('V3 SQL KATMANI DOGRULANDI');
    Halt(0);
  end;
  WriteLn('V3 SQL KATMANI HATALI');
  Halt(1);
end.
