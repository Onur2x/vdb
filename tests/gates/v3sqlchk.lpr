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
  { FPC/Unix: TEvent/TThread icin cthreads programin EN BASINDA olmali. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbBackendApi, VDbCore, VDbBackendV3, VDbTable, VDbSql,
  VDbTypes, VDbErr, VDbPageEngine, VDbChangeLog;

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

  { Sprint 3.10: ayni dosyayi ikinci kez ACMAK reddedilir ve hata ACIK
    bir kilit mesajidir (ham "Try again"/paylasim ihlali degil). Unix'te
    FPC'nin TFileStream'i flock uygular; Windows'ta paylasim ihlali olur. }
procedure TestDoubleOpen;
var
  S, S2: TV3Sql;
  r: TSqlResult;
  msg: string;
  caught: Boolean;
begin
  WriteLn;
  WriteLn('Sprint 3.10/v3.16 - ayni dosyaya ikinci yazar oturumu: ACIK olmali');
  CleanDir;
  OpenV3(S, 'lock.odb', True);
  try
    r := Exec(S, 'CREATE TABLE k (id INTEGER PRIMARY KEY, ad TEXT)');
    if not gErr then Ok('lock: tablo olustu') else Fail('lock: CREATE: ' + r.Msg);
    r := Exec(S, 'INSERT INTO k VALUES (1, ''Ali'')');
    if not gErr then Ok('lock: satir yazildi') else Fail('lock: INSERT: ' + r.Msg);

    caught := False;
    msg := '';
    try
      S2.Be := TVdbBackendV3.Create(DirOf('lock.odb'), False, 64);
      caught := True;
    except
      on E: Exception do
      begin
        caught := False;
        msg := E.ClassName + ': ' + E.Message;
      end;
    end;
    { v3.16: SURECLER ARASI COK YAZARLILIK. Kilit artik islem boyu tutulur;
      bu yuzden ayni dosyaya ikinci bir YAZAR oturum ACILABILIR. Beklenen
      davranis: hata DEGIL, acilis + bagimsiz yazma. }
    if caught then
    begin
      Ok('lock: ikinci yazar oturumu acildi (v3.16 cok yazarlilik)');
      S2.Be := nil;
    end
    else
      Fail('lock: ikinci yazar acilamadi -> ' + msg);

    { Ilk motor etkilenmemis olmali. }
    r := Exec(S, 'SELECT COUNT(*) FROM k');
    if (not gErr) and (Cel(r, 0, 0) = '1') then
      Ok('lock: ilk motor calismaya devam ediyor')
    else
      Fail('lock: ilk motor bozuldu: ' + r.Msg);
    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) then
      Ok('lock: VERIFY gecti: ' + r.Msg)
    else
      Fail('lock: VERIFY: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  { Kapanistan sonra acilis serbest. }
  OpenV3(S, 'lock.odb', False);
  try
    r := Exec(S, 'SELECT COUNT(*) FROM k');
    if (not gErr) and (Cel(r, 0, 0) = '1') then
      Ok('lock: kapanistan sonra acilis serbest')
    else
      Fail('lock: yeniden acilis: ' + r.Msg);
  finally
    CloseV3(S);
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

{ ==================================== 8) VERIFY (Sprint 3.1) }

procedure TestVerifySql;
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
begin
  CleanDir;
  OpenV3(S, 'verify.odb', True);
  try
    Exec(S, 'CREATE TABLE v (id INTEGER PRIMARY KEY, ad TEXT)');
    for i := 1 to 50 do
      Exec(S, Format('INSERT INTO v VALUES (%d, ''kayit%d'')', [i, i]));
    for i := 1 to 50 do
      if (i mod 5) = 0 then
        Exec(S, Format('DELETE FROM v WHERE id = %d', [i]));

    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) and (Pos('VERIFY:', r.Msg) = 1) and
       (Pos('anahtar=', r.Msg) > 0) then
      Ok('SQL VERIFY gecti: ' + r.Msg)
    else
      Fail('SQL VERIFY: ' + r.Msg);

    { Islem icinde VERIFY reddedilir; hata firlatmak yerine Affected=0
      ve net mesaj doner. }
    Exec(S, 'BEGIN');
    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 0) and (Pos('VERIFY HATASI:', r.Msg) = 1)
       and (Pos('acik parti', r.Msg) > 0) then
      Ok('SQL VERIFY acik islemde reddedildi')
    else
      Fail('SQL VERIFY acik islemde: ' + r.Msg);
    Exec(S, 'ROLLBACK');
  finally
    CloseV3(S);
  end;
end;

{ ================================ 8) BACKUP / RESTORE (Sprint 3.2) }

procedure TestBackupRestoreSql;
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
  bak: string;
begin
  CleanDir;
  bak := DirOf('sql_backup.odb');
  OpenV3(S, 'sql_br.odb', True);
  try
    Exec(S, 'CREATE TABLE b (id INTEGER PRIMARY KEY, ad TEXT)');
    for i := 1 to 100 do
      Exec(S, Format('INSERT INTO b VALUES (%d, ''s%d'')', [i, i]));

    r := Exec(S, Format('BACKUP TO ''%s''', [bak]));
    if (not gErr) and (r.Affected = 1) and FileExists(bak) then
      Ok('SQL BACKUP dosya olusturdu')
    else
      Fail('SQL BACKUP: ' + r.Msg);

    Exec(S, 'DELETE FROM b WHERE id <= 50');
    r := Exec(S, 'SELECT COUNT(*) FROM b');
    if (not gErr) and (Cel(r, 0, 0) = '50') then
      Ok('BACKUP sonrasi 50 satir silindi')
    else
      Fail('BACKUP sonrasi silme: ' + Cel(r, 0, 0));

    r := Exec(S, Format('RESTORE FROM ''%s''', [bak]));
    if (not gErr) and (r.Affected = 1) then
      Ok('SQL RESTORE calisti')
    else
      Fail('SQL RESTORE: ' + r.Msg);

    { RESTORE sonrasi sema BELLEKTEN degil, yeni dosyadan yuklenmeli. }
    r := Exec(S, 'SELECT COUNT(*) FROM b');
    if (not gErr) and (Cel(r, 0, 0) = '100') then
      Ok('RESTORE 100 satiri geri getirdi')
    else
      Fail('RESTORE sonrasi COUNT: ' + Cel(r, 0, 0));
    r := Exec(S, 'SELECT ad FROM b WHERE id = 75');
    if (not gErr) and (Cel(r, 0, 0) = 's75') then
      Ok('RESTORE sema + veri tutarli')
    else
      Fail('RESTORE PK okumasi: ' + Cel(r, 0, 0));

    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) and (Pos('VERIFY:', r.Msg) = 1) then
      Ok('RESTORE sonrasi SQL VERIFY gecti')
    else
      Fail('RESTORE sonrasi VERIFY: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

{ ==================================== 10) VACUUM (Sprint 3.3) }

procedure TestVacuumSql;
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
  big: string;
begin
  CleanDir;
  OpenV3(S, 'vac.odb', True);
  try
    Exec(S, 'CREATE TABLE v (id INTEGER PRIMARY KEY, t TEXT)');
    big := StringOfChar('x', 300);
    for i := 1 to 200 do
      Exec(S, Format('INSERT INTO v VALUES (%d, ''%s'')', [i, big]));
    { 180 satiri sil: dosyada buyuk miktarda olu bayt kalsin. }
    for i := 1 to 200 do
      if (i mod 10) <> 0 then
        Exec(S, Format('DELETE FROM v WHERE id = %d', [i]));

    r := Exec(S, 'VACUUM');
    if (not gErr) and (r.Affected = 1) and (Pos('VACUUM ', r.Msg) = 1) then
      Ok('SQL VACUUM: ' + r.Msg)
    else
      Fail('SQL VACUUM: ' + r.Msg);

    r := Exec(S, 'SELECT COUNT(*) FROM v');
    if (not gErr) and (Cel(r, 0, 0) = '20') then
      Ok('VACUUM sonrasi 20 canli satir')
    else
      Fail('VACUUM sonrasi COUNT: ' + Cel(r, 0, 0));
    r := Exec(S, 'SELECT t FROM v WHERE id = 100');
    if (not gErr) and (Length(Cel(r, 0, 0)) = 300) then
      Ok('VACUUM sonrasi deger birebir')
    else
      Fail('VACUUM sonrasi deger: ' + Cel(r, 0, 0));

    { Sema yeni dosyadan yuklendi: yazim da calismali. }
    Exec(S, 'INSERT INTO v VALUES (999, ''yeni'')');
    r := Exec(S, 'SELECT COUNT(*) FROM v');
    if (not gErr) and (Cel(r, 0, 0) = '21') then
      Ok('VACUUM sonrasi yazim calisiyor')
    else
      Fail('VACUUM sonrasi yazim: ' + Cel(r, 0, 0));

    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) then
      Ok('VACUUM sonrasi VERIFY gecti')
    else
      Fail('VACUUM sonrasi VERIFY: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

function ExecErr(const S: TV3Sql; const Sql: string; out Code, Msg: string): Boolean;
begin
  Result := False;
  Code := '';
  Msg := '';
  try
    S.Sq.Exec(Sql);
  except
    on E: EVDbException do
    begin
      Result := True;
      Code := VDbErrorName(E.ErrorCode);
      Msg := E.Message;
    end;
    on E: Exception do
    begin
      Result := True;
      Code := E.ClassName;
      Msg := E.Message;
    end;
  end;
end;

{ Sprint 3.10: v3'te SHOW STATS. v2'ye ozgu okuma-onbellegi sayaclari
  yoktur; bunlari 0 gostermek yerine v3'te GERCEK olan metrikler doner
  (engine, live_keys, dosya boyutlari). SHOW STATS TABLE <t> ANALYZE
  istatistiklerini dondurmeye devam eder. }
procedure TestShowStats;
var
  S: TV3Sql;
  r: TSqlResult;
  i: Integer;
  val: string;
  sawEngine, sawLive, sawData, sawWal: Boolean;
begin
  WriteLn;
  WriteLn('SHOW STATS - v3 sayfa motoru metrikleri');
  CleanDir;
  OpenV3(S, 'stats.odb', True);
  try
    Exec(S, 'CREATE TABLE st (id INTEGER PRIMARY KEY, ad TEXT)');
    for i := 1 to 20 do
      Exec(S, Format('INSERT INTO st VALUES (%d, ''a%d'')', [i, i]));

    r := Exec(S, 'SHOW STATS');
    if gErr then
    begin
      Fail('SHOW STATS: ' + r.Msg);
      Exit;
    end;
    Ok('SHOW STATS calisti (' + IntToStr(Length(r.Rows)) + ' satir)');

    sawEngine := False; sawLive := False; sawData := False; sawWal := False;
    val := '';
    for i := 0 to High(r.Rows) do
    begin
      if Cel(r, i, 0) = 'engine' then
      begin
        sawEngine := True;
        if Cel(r, i, 1) <> 'v3' then Fail('SHOW STATS: engine=' + Cel(r, i, 1));
      end
      else if Cel(r, i, 0) = 'live_keys' then
      begin
        sawLive := True;
        val := Cel(r, i, 1);
      end
      else if Cel(r, i, 0) = 'data_file_bytes' then
      begin
        sawData := True;
        if StrToInt64Def(Cel(r, i, 1), 0) <= 0 then
          Fail('SHOW STATS: data_file_bytes=' + Cel(r, i, 1));
      end
      else if Cel(r, i, 0) = 'wal_file_bytes' then
        sawWal := True;
    end;
    if sawEngine and sawLive and sawData and sawWal then
      Ok('SHOW STATS: engine/live_keys/dosya boyutlari var (canli anahtar=' + val + ')')
    else
      Fail(Format('SHOW STATS eksik alan (engine=%s live=%s data=%s wal=%s)',
        [BoolToStr(sawEngine, True), BoolToStr(sawLive, True),
         BoolToStr(sawData, True), BoolToStr(sawWal, True)]));

    { Tablo bicimi ANALYZE sonrasi calisir, oncesinde yol gosteren hata. }
    r := Exec(S, 'ANALYZE st');
    if gErr then Fail('ANALYZE st: ' + r.Msg);
    r := Exec(S, 'SHOW STATS TABLE st');
    if (not gErr) and (Length(r.Rows) >= 1) and (Cel(r, 0, 0) = 'st') then
      Ok('SHOW STATS TABLE st: ANALYZE ozeti dondu')
    else
      Fail('SHOW STATS TABLE st: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

  { v4: v3 sayfa motorunda replikasyon = MANTIKSAL GUNLUK TASIMA.
    Burada SQL yuzeyi denenir: slot olusturma, birincil tasima, ikincil
    uygulama, artimli devam, bos PUMP ve TCP reddi. Derin protokol
    (bozuk dosya, bosluk, yeniden baslatma) ayri kapi: replchk. }
procedure TestReplicationV3;
var
  S: TV3Sql;
  S2: TV3Sql;
  r: TSqlResult;
  ship: string;
  n1: Integer;
  minSeq2, maxSeq2, minTs2, maxTs2: Int64;
  baseCount2: Integer;
begin
  WriteLn;
  WriteLn('v4 - v3 replikasyon: slot + mantiksal gunluk tasima (birincil/ikincil)');
  CleanDir;
  ship := IncludeTrailingPathDelimiter(gDir) + 'ship';
  OpenV3(S, 'repl.odb', True);
  try
    r := Exec(S, 'CREATE TABLE t (id INTEGER PRIMARY KEY, ad TEXT)');
    if not gErr then Ok('repl: tablo olustu')
    else Fail('repl: CREATE TABLE: ' + r.Msg);
    r := Exec(S, 'INSERT INTO t VALUES (1, ''Ali'')');
    if not gErr then Ok('repl: baslangic satiri yazildi')
    else Fail('repl: INSERT: ' + r.Msg);

    r := Exec(S, 'CREATE REPLICATION SLOT ''S1''');
    if (not gErr) and (Pos('s1', r.Msg) > 0) then
      Ok('repl: slot olustu')
    else
      Fail('repl: CREATE SLOT: ' + r.Msg);

    r := Exec(S, 'SHOW REPLICATION SLOTS');
    if (not gErr) and (Length(r.Rows) = 1) and (Cel(r, 0, 0) = 's1') and
      (Cel(r, 0, 1) = 'none') then
      Ok('repl: SHOW SLOTS 1 satir, rol none')
    else
      Fail('repl: SHOW SLOTS: ' + r.Msg);

    r := Exec(S, 'START REPLICATION PRIMARY DEST ''' + ship + ''' SLOT ''S1''');
    if (not gErr) and (Pos('PRIMARY', r.Msg) > 0) then
      Ok('repl: birincil basladi')
    else
      Fail('repl: START PRIMARY: ' + r.Msg);

    { TCP akisi v3'te yok: sessiz no-op degil, ACIK cevap (hata degil). }
    r := Exec(S, 'START REPLICATION PRIMARY TCP PORT 5599 SLOT ''S1''');
    if (not gErr) and (r.Affected = 0) and (Pos('TCP', r.Msg) > 0) then
      Ok('repl: TCP acik sekilde reddedildi')
    else
      Fail('repl: TCP: ' + r.Msg);

    r := Exec(S, 'PUMP REPLICATION');
    n1 := r.Affected;
    if (not gErr) and (n1 >= 2) then
      Ok('repl: PUMP taban + veri grubunu tasidi (' + IntToStr(n1) + ' grup)')
    else
      Fail('repl: PUMP: ' + r.Msg);

    r := Exec(S, 'SHOW REPLICATION STATUS');
    if (not gErr) and (Length(r.Rows) = 1) and (Cel(r, 0, 0) = 'primary') and
      (Cel(r, 0, 4) = 'True') then
      Ok('repl: SHOW STATUS birincil')
    else
      Fail('repl: SHOW STATUS: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  { Ikincil: bos veritabani; taban imaji RESTORE edilir, gruplar uygulanir. }
  OpenV3(S2, 'repl_std.odb', True);
  try
    r := Exec(S2, 'START REPLICATION STANDBY ''' + ship + ''' SLOT ''S1''');
    if not gErr then Ok('repl: ikincil basladi')
    else Fail('repl: START STANDBY: ' + r.Msg);

    r := Exec(S2, 'PUMP REPLICATION');
    if (not gErr) and (r.Affected >= 2) then
      Ok('repl: ikincil taban + grubu uyguladi (' + IntToStr(r.Affected) + ' grup)')
    else
      Fail('repl: STANDBY PUMP: ' + r.Msg);

    r := Exec(S2, 'SELECT COUNT(*) FROM t');
    if (not gErr) and (Cel(r, 0, 0) = '1') then
      Ok('repl: ikincilde 1 satir (bayt bayt kopya)')
    else
      Fail('repl: ikincil veri: ' + r.Msg);
    r := Exec(S2, 'SELECT ad FROM t WHERE id = 1');
    if (not gErr) and (Cel(r, 0, 0) = 'Ali') then
      Ok('repl: ikincil deger dogru')
    else
      Fail('repl: ikincil deger: ' + r.Msg);

    { Yeni grup yoksa PUMP etkisiz ve hatasiz. }
    r := Exec(S2, 'PUMP REPLICATION');
    if (not gErr) and (r.Affected = 0) then
      Ok('repl: bos PUMP etkisiz')
    else
      Fail('repl: bos PUMP: ' + r.Msg);
  finally
    CloseV3(S2);
  end;

  { Artimli devam: birincilde yeni commit, iki PUMP. }
  OpenV3(S, 'repl.odb', False);
  try
    r := Exec(S, 'START REPLICATION PRIMARY DEST ''' + ship + ''' SLOT ''S1''');
    if gErr then Fail('repl: birincil yeniden: ' + r.Msg);
    r := Exec(S, 'INSERT INTO t VALUES (2, ''Veli'')');
    if not gErr then Ok('repl: birincilde yeni satir')
    else Fail('repl: INSERT 2: ' + r.Msg);
    r := Exec(S, 'UPDATE t SET ad = ''Ali2'' WHERE id = 1');
    if not gErr then Ok('repl: birincilde guncelleme')
    else Fail('repl: UPDATE: ' + r.Msg);
    r := Exec(S, 'PUMP REPLICATION');
    if (not gErr) and (r.Affected >= 2) then
      Ok('repl: artimli tasima')
    else
      Fail('repl: artimli PUMP: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  OpenV3(S2, 'repl_std.odb', False);
  try
    r := Exec(S2, 'START REPLICATION STANDBY ''' + ship + ''' SLOT ''S1''');
    if gErr then Fail('repl: ikincil yeniden: ' + r.Msg);
    r := Exec(S2, 'PUMP REPLICATION');
    if (not gErr) and (r.Affected >= 2) then
      Ok('repl: artimli uygulama')
    else
      Fail('repl: artimli uygulama: ' + r.Msg);
    r := Exec(S2, 'SELECT COUNT(*) FROM t');
    if (not gErr) and (Cel(r, 0, 0) = '2') then
      Ok('repl: ikincil 2 satir')
    else
      Fail('repl: ikincil count: ' + r.Msg);
    r := Exec(S2, 'SELECT ad FROM t WHERE id = 1');
    if (not gErr) and (Cel(r, 0, 0) = 'Ali2') then
      Ok('repl: ikincil guncel deger')
    else
      Fail('repl: ikincil guncel deger: ' + r.Msg);

    { Ikincil kendi gunlugune yeniden numaralandirir: PITR yetenegi korunur. }
    if S2.Be.LogSupported then
      Ok('repl: ikincil degisim gunlugu acik')
    else
      Fail('repl: ikincil gunluk: ' + S2.Be.LogStatus);

    { Ikincil kendi gunlugune YENIDEN NUMARALANDIRIR: kendi seq uzayi
      olusur (birincilin 5'i ikincilde 3 olabilir). Gunluk kapsami artar ve
      son surum noktasi okunabilir. Taban kurulumu nesil kopmasi yazar;
      ondan SONRASI tam calisir (onceki gecmis birincile aittir). }
    if S2.Be.LogRangeInfo(minSeq2, maxSeq2, minTs2, maxTs2, baseCount2) and
      (maxSeq2 > 1) then
      Ok(Format('repl: ikincil gunluk seq %d..%d (%d taban)',
        [minSeq2, maxSeq2, baseCount2]))
    else
      Fail('repl: ikincil gunluk araligi: ' + S2.Be.LogStatus);
    r := Exec(S2, 'SELECT COUNT(*) FROM t AS OF VERSION ' + IntToStr(maxSeq2));
    if (not gErr) and (Cel(r, 0, 0) = '2') then
      Ok('repl: ikincil AS OF VERSION (son) 2 satir')
    else
      Fail('repl: ikincil AS OF: ' + Cel(r, 0, 0) + ' ' + r.Msg);

    r := Exec(S2, 'STOP REPLICATION');
    if (not gErr) and (r.Affected = 1) then
      Ok('repl: ikincil durduruldu')
    else
      Fail('repl: STOP: ' + r.Msg);
    r := Exec(S2, 'SHOW REPLICATION STATUS');
    if (not gErr) and (Cel(r, 0, 0) = 'none') then
      Ok('repl: durdurulunca rol none')
    else
      Fail('repl: durdurulunca rol: ' + r.Msg);
  finally
    CloseV3(S2);
  end;

  { Kalicilik: ikincil yeniden acilir, veri yerinde ve rol none. }
  OpenV3(S2, 'repl_std.odb', False);
  try
    r := Exec(S2, 'SELECT COUNT(*) FROM t');
    if (not gErr) and (Cel(r, 0, 0) = '2') then
      Ok('repl: ikincil veri kalici')
    else
      Fail('repl: ikincil kalicilik: ' + r.Msg);
    r := Exec(S2, 'DROP REPLICATION SLOT ''S1''');
    if (not gErr) and (r.Affected = 1) then
      Ok('repl: slot silindi')
    else
      Fail('repl: DROP SLOT: ' + r.Msg);
  finally
    CloseV3(S2);
  end;
end;

  { Sprint 3.6 + v3.2: PITR / zaman yolculugu.
    v3.1'de sayfa WAL'i yalniz sayfa imaji tuttugu icin AS OF/RECOVER TO/WAL
    arsivi ACIKCA reddediliyordu. v3.2'de AS OF SEQUENCE artik CALISIR:
    sayfa imajlari N'inci commit'in tam goruntusunu vermeye yeter, goruntu
    gecici bir kopyada kurulur. Mantiksal gunluk gerektiren yollar
    (AS OF TIMESTAMP/VERSION, RECOVER TO, ARCHIVE WAL) hala reddedilir. }
procedure TestPitrSql;
var
  S: TV3Sql;
  S2: TV3Sql;
  r: TSqlResult;
  code, msg, base, tstext: string;
  seq1, ts1: Int64;
  minSeq, maxSeq, minTs, maxTs: Int64;
  baseCount: Integer;
begin
  WriteLn;
  WriteLn('Sprint 3.6/v4 - v3 PITR: AS OF SEQUENCE/VERSION/TIMESTAMP, ' +
    'ARSIV + RECOVER');
  CleanDir;
  base := IncludeTrailingPathDelimiter(gDir);
  OpenV3(S, 'pitr.odb', True);
  try
    r := Exec(S, 'CREATE TABLE t (id INTEGER PRIMARY KEY, ad TEXT)');
    if not gErr then Ok('pitr: tablo olustu') else Fail('pitr: CREATE: ' + r.Msg);
    r := Exec(S, 'INSERT INTO t VALUES (1, ''Ali''), (2, ''Veli'')');
    if not gErr then Ok('pitr: 2 satir yazildi') else Fail('pitr: INSERT: ' + r.Msg);

    { v3.2: AS OF SEQUENCE artik gecmis okur (gecici kopya uzerinde).
      N = WAL penceresindeki COMMIT sayisi: 0 = WAL tabani (bu dosyada
      CREATE TABLE oncesi -> bos), en buyuk deger = guncel durum. }
    r := Exec(S, 'SELECT COUNT(*) FROM t AS OF SEQUENCE ' +
      IntToStr(S.Be.AsOfMaxSequence));
    if (not gErr) and (Cel(r, 0, 0) = '2') then
      Ok('pitr: AS OF SEQUENCE <son> guncel goruntuyu okur')
    else
      Fail('pitr: AS OF SEQUENCE <son>: ' + r.Msg);
    r := Exec(S, 'SELECT COUNT(*) FROM t AS OF SEQUENCE 0');
    if (not gErr) and (Cel(r, 0, 0) = '0') then
      Ok('pitr: AS OF SEQUENCE 0 WAL tabanini okur (tablo henuz yok)')
    else
      Fail('pitr: AS OF SEQUENCE 0: ' + r.Msg);
    r := Exec(S, 'SELECT id FROM t AS OF SEQUENCE 1');
    if (not gErr) and (Length(r.Rows) = 0) then
      Ok('pitr: AS OF SEQUENCE 1 tablo bos goruntusu')
    else
      Fail('pitr: AS OF SEQUENCE 1: ' + r.Msg);

    { v4: mantiksal gunluk geldi — VERSION / TIMESTAMP / arsiv / kurtarma
      artik CALISIR. Once birinci fazin sinirini (seq + ts) yakala. }
    if not S.Be.LogRangeInfo(minSeq, maxSeq, minTs, maxTs, baseCount) then
    begin
      Fail('pitr: gunluk araligi okunamadi: ' + S.Be.LogStatus);
      minSeq := 0; maxSeq := 0; minTs := 0; maxTs := 0;
    end
    else
      Ok(Format('pitr: gunluk seq %d..%d', [minSeq, maxSeq]));
    seq1 := maxSeq;
    ts1 := maxTs;
    tstext := VdbLogFormatTimestamp(ts1);

    { Ikinci faz: ayri commit'ler -> ayri gruplar. }
    Sleep(40);
    r := Exec(S, 'UPDATE t SET ad = ''Ali2'' WHERE id = 1');
    if not gErr then Ok('pitr: faz 2 guncelleme') else Fail('pitr: UPDATE: ' + r.Msg);
    r := Exec(S, 'INSERT INTO t VALUES (3, ''Can'')');
    if not gErr then Ok('pitr: faz 2 ekleme') else Fail('pitr: INSERT 3: ' + r.Msg);

    { Guncel durum 3 satir, id=1 -> Ali2 }
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if (not gErr) and (Cel(r, 0, 0) = '3') then Ok('pitr: guncel COUNT 3')
    else Fail('pitr: guncel COUNT: ' + Cel(r, 0, 0) + ' ' + r.Msg);

    { AS OF VERSION: birinci fazin sonu -> 2 satir, id=1 -> Ali }
    r := Exec(S, 'SELECT COUNT(*) FROM t AS OF VERSION ' + IntToStr(seq1));
    if (not gErr) and (Cel(r, 0, 0) = '2') then
      Ok('pitr: AS OF VERSION <faz1> COUNT 2')
    else
      Fail('pitr: AS OF VERSION COUNT: ' + Cel(r, 0, 0) + ' ' + r.Msg);
    r := Exec(S, 'SELECT ad FROM t AS OF VERSION ' + IntToStr(seq1) +
      ' WHERE id = 1');
    if (not gErr) and (Cel(r, 0, 0) = 'Ali') then
      Ok('pitr: AS OF VERSION eski degeri okur')
    else
      Fail('pitr: AS OF VERSION deger: ' + Cel(r, 0, 0) + ' ' + r.Msg);

    { AS OF TIMESTAMP: ayni nokta, zamanla }
    r := Exec(S, 'SELECT COUNT(*) FROM t AS OF TIMESTAMP ''' + tstext + '''');
    if (not gErr) and (Cel(r, 0, 0) = '2') then
      Ok('pitr: AS OF TIMESTAMP "' + tstext + '" COUNT 2')
    else
      Fail('pitr: AS OF TIMESTAMP COUNT: ' + Cel(r, 0, 0) + ' ' + r.Msg);
    r := Exec(S, 'SELECT ad FROM t AS OF TIMESTAMP ''' + tstext +
      ''' WHERE id = 1');
    if (not gErr) and (Cel(r, 0, 0) = 'Ali') then
      Ok('pitr: AS OF TIMESTAMP eski degeri okur')
    else
      Fail('pitr: AS OF TIMESTAMP deger: ' + Cel(r, 0, 0) + ' ' + r.Msg);

    { Bozuk hedefler: sessiz 0 degil, ACIK sozdizimi hatasi. }
    if ExecErr(S, 'SELECT id FROM t AS OF VERSION abc', code, msg) and
      (code = 'ecSyntaxError') then
      Ok('pitr: AS OF VERSION abc -> ecSyntaxError')
    else
      Fail('pitr: AS OF VERSION abc: ' + code + ' ' + msg);
    if ExecErr(S, 'SELECT id FROM t AS OF TIMESTAMP ''gecersiz''',
      code, msg) and (code = 'ecSyntaxError') then
      Ok('pitr: AS OF TIMESTAMP gecersiz -> ecSyntaxError')
    else
      Fail('pitr: AS OF TIMESTAMP gecersiz: ' + code + ' ' + msg);

    { Gecmis, tabandan ONCE: acik hata (sessiz bos kume yok). }
    if ExecErr(S, 'SELECT id FROM t AS OF VERSION 0', code, msg) then
      Ok('pitr: AS OF VERSION 0 reddedildi')
    else
      Fail('pitr: AS OF VERSION 0 kabul edildi');

    { ARCHIVE WAL SET: gunlugun tam kopyasi }
    r := Exec(S, 'ARCHIVE WAL SET DIR=''' + base + 'arsiv''');
    if (not gErr) and DirectoryExists(base + 'arsiv') then
      Ok('pitr: ARCHIVE WAL SET kopyaladi: ' + r.Msg)
    else
      Fail('pitr: ARCHIVE WAL SET: ' + r.Msg);

    { ARCHIVE WAL LIST: gunluk kapsami }
    r := Exec(S, 'ARCHIVE WAL LIST');
    if (not gErr) and (r.Affected = 1) and (Cel(r, 0, 1) <> '<yok>') then
      Ok('pitr: ARCHIVE WAL LIST kapsami: ' + r.Msg)
    else
      Fail('pitr: ARCHIVE WAL LIST: ' + r.Msg);

    { RECOVER TO TIMESTAMP: canli dosyaya DOKUNMADAN kurtarma dosyasi }
    r := Exec(S, 'RECOVER TO TIMESTAMP ''' + tstext + '''');
    if (not gErr) and FileExists(base + 'pitr.odb.recovered') then
      Ok('pitr: RECOVER TO TIMESTAMP dosyasi olustu: ' + r.Msg)
    else
      Fail('pitr: RECOVER TO TIMESTAMP: ' + r.Msg);

    { Kurtarma dosyasi gercek bir veritabani: icerigi faz 1 ile ayni. }
    OpenV3(S2, 'pitr.odb.recovered', False);
    try
      r := Exec(S2, 'SELECT COUNT(*) FROM t');
      if (not gErr) and (Cel(r, 0, 0) = '2') then
        Ok('pitr: kurtarma dosyasi COUNT 2 (faz 1)')
      else
        Fail('pitr: kurtarma dosyasi COUNT: ' + Cel(r, 0, 0) + ' ' + r.Msg);
      r := Exec(S2, 'SELECT ad FROM t WHERE id = 1');
      if (not gErr) and (Cel(r, 0, 0) = 'Ali') then
        Ok('pitr: kurtarma dosyasinda eski deger')
      else
        Fail('pitr: kurtarma dosyasi deger: ' + Cel(r, 0, 0) + ' ' + r.Msg);
      r := Exec(S2, 'VERIFY');
      if (not gErr) and (r.Affected = 1) then
        Ok('pitr: kurtarma dosyasi VERIFY TEMIZ')
      else
        Fail('pitr: kurtarma dosyasi VERIFY: ' + r.Msg);
    finally
      CloseV3(S2);
    end;

    { RECOVER TO NOW: son durum }
    r := Exec(S, 'RECOVER TO NOW');
    if not gErr then Ok('pitr: RECOVER TO NOW calisti: ' + r.Msg)
    else Fail('pitr: RECOVER TO NOW: ' + r.Msg);

    { Canli dosya DEGISMEDI: kurtarma ayri dosyaya yazildi. }
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if (not gErr) and (Cel(r, 0, 0) = '3') then
      Ok('pitr: kurtarma sonrasi canli veri bozulmadi')
    else
      Fail('pitr: kurtarma sonrasi canli COUNT: ' + Cel(r, 0, 0) + ' ' + r.Msg);

    { Guncel okuma bozulmadi. }
    r := Exec(S, 'SELECT ad FROM t WHERE id = 2');
    if (not gErr) and (Cel(r, 0, 0) = 'Veli') then
      Ok('pitr: anahtar erisimi etkilenmedi')
    else
      Fail('pitr: anahtar erisimi: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  { Yeniden acilis: dosya saglam. }
  OpenV3(S, 'pitr.odb', False);
  try
    r := Exec(S, 'SELECT COUNT(*) FROM t');
    if (not gErr) and (Cel(r, 0, 0) = '3') then
      Ok('pitr: yeniden acilista veri yerinde (3 satir)')
    else
      Fail('pitr: yeniden acilis: ' + r.Msg);
    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) and (Pos('VERIFY:', r.Msg) = 1) then
      Ok('pitr: VERIFY gecti: ' + r.Msg)
    else
      Fail('pitr: VERIFY: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

  { v4 DUZELTME (regresyon kapisi): negatif literalli IN listesi indeks
    daraltmasinda sessizce kayboluyordu. AST'de `-3` bir
    TSqlUnaryOpNode(suoNeg) dugumudur; daraltma kodu "literal degil"
    diye ATLIYOR, dilim yalniz pozitiflerden hesaplaniyor ve negatif
    grubun satirlari HIC OKUNMADAN sonuctan dusuyordu (hata yok, yanlis
    sonuc). Hem indeksli satir yolu, hem PK IN yolu, hem de COUNT yolu
    burada birebir denetlenir. }
procedure TestIndexInNegative;
const
  N = 400;
var
  S: TV3Sql;
  r: TSqlResult;
  i, v, got: Integer;
  gotIds: string;  j: Integer;

  { Beklenen satir sayisi: n = (i*7) mod 53 - 3, i mod 17 = 0 -> NULL }
  function Expect(const Vals: array of Integer): Integer;
  var
    a, b: Integer;
    hit: Boolean;
  begin
    Result := 0;
    for a := 1 to N do
    begin
      if a mod 17 = 0 then Continue;
      v := (a * 7) mod 53 - 3;
      hit := False;
      for b := 0 to High(Vals) do
        if v = Vals[b] then
        begin
          hit := True;
          Break;
        end;
      if hit then Inc(Result);
    end;
  end;

  procedure CheckIn(const Sql: string; Exp: Integer);
  begin
    r := Exec(S, Sql);
    got := Length(r.Rows);
    if gErr then
      Fail('idxneg: ' + Sql + ' -> HATA: ' + r.Msg)
    else if got = Exp then
      Ok(Format('idxneg: %d satir -> %s', [got, Sql]))
    else
      Fail(Format('idxneg: %d satir (beklenen %d) -> %s', [got, Exp, Sql]));
  end;

begin
  WriteLn;
  WriteLn('v4 duzeltme - indeksli IN listesinde negatif degerler');
  CleanDir;
  OpenV3(S, 'idxneg.odb', True);
  try
    r := Exec(S, 'CREATE TABLE fz (id INTEGER PRIMARY KEY, n INTEGER, k TEXT)');
    r := Exec(S, 'BEGIN');
    for i := 1 to N do
    begin
      if i mod 17 = 0 then
        r := Exec(S, Format('INSERT INTO fz VALUES (%d,NULL,%s)',
          [i, QuotedStr('k' + IntToStr(i mod 10))]))
      else
        r := Exec(S, Format('INSERT INTO fz VALUES (%d,%d,%s)',
          [i, (i * 7) mod 53 - 3, QuotedStr('k' + IntToStr(i mod 10))]));
    end;
    r := Exec(S, 'COMMIT');
    if not gErr then Ok('idxneg: 400 satir yazildi')
    else Fail('idxneg: INSERT: ' + r.Msg);
    r := Exec(S, 'CREATE INDEX ix_fz_n ON fz(n)');
    if not gErr then Ok('idxneg: indeks olustu')
    else Fail('idxneg: CREATE INDEX: ' + r.Msg);

    { Indeksli satir yolu (NarrowRows) - sikayet edilen yol. }
    CheckIn('SELECT id FROM fz WHERE n IN (19,17,-3)', Expect([19, 17, -3]));
    CheckIn('SELECT id FROM fz WHERE n IN (19,17,-3) ORDER BY id',
      Expect([19, 17, -3]));
    CheckIn('SELECT id FROM fz WHERE n IN (-3,5)', Expect([-3, 5]));
    CheckIn('SELECT id FROM fz WHERE n IN (5,-3)', Expect([5, -3]));
    CheckIn('SELECT id FROM fz WHERE n IN (-3)', Expect([-3]));
    CheckIn('SELECT id FROM fz WHERE n IN (-1,44,34)', Expect([-1, 44, 34]));
    CheckIn('SELECT id FROM fz WHERE n IN (-3,-1,-2)', Expect([-3, -1, -2]));
    CheckIn('SELECT id FROM fz WHERE n IN (3,5,7)', Expect([3, 5, 7]));
    CheckIn('SELECT id FROM fz WHERE n IN (-3,3)', Expect([-3, 3]));

    { Ayni sorgularin COUNT(*) yolu da birebir olmali (tam tarama yolu). }
    r := Exec(S, 'SELECT COUNT(*) FROM fz WHERE n IN (19,17,-3)');
    if (not gErr) and (Cel(r, 0, 0) = IntToStr(Expect([19, 17, -3]))) then
      Ok('idxneg: COUNT(*) IN (19,17,-3) birebir')
    else
      Fail('idxneg: COUNT(*) IN: ' + Cel(r, 0, 0) + ' ' + r.Msg);

    { PK uzerinde IN: negatif pk degerleri de bulunmali. }
    r := Exec(S, 'CREATE TABLE nk (id INTEGER PRIMARY KEY, v TEXT)');
    r := Exec(S, 'INSERT INTO nk VALUES (-5,''a''),(-1,''b''),(1,''c''),(7,''d'')');
    CheckIn('SELECT v FROM nk WHERE id IN (-5,1)', 2);
    CheckIn('SELECT v FROM nk WHERE id IN (-5,-1)', 2);
    CheckIn('SELECT v FROM nk WHERE id IN (-5,-1,1,7)', 4);
    r := Exec(S, 'SELECT v FROM nk WHERE id IN (-5,1) ORDER BY id');
    gotIds := '';
    for j := 0 to High(r.Rows) do gotIds := gotIds + Cel(r, j, 0);
    if (not gErr) and (gotIds = 'ac') then
      Ok('idxneg: PK IN sirali degerler birebir (ac)')
    else
      Fail('idxneg: PK IN degerleri: ' + gotIds);

    { NULL iceren liste: daraltma YAPILMAMALI (UNKNOWN semantigi). }
    CheckIn('SELECT id FROM fz WHERE n IN (19, NULL, -3)',
      Expect([19, -3]));

    { Negatif sabitli esitlik/aralik: daraltma artik KABUL ediyor
      (eskiden negatifler indekslenemiyor, tam taramaya dusuyordu).
      Sonuclar yine birebir olmali. }
    CheckIn('SELECT id FROM fz WHERE n = -3', Expect([-3]));
    CheckIn('SELECT id FROM fz WHERE -3 = n', Expect([-3]));
    CheckIn('SELECT id FROM fz WHERE n >= -3 AND n <= 3',
      Expect([-3, -2, -1, 0, 1, 2, 3]));
    CheckIn('SELECT id FROM fz WHERE n BETWEEN -3 AND 3',
      Expect([-3, -2, -1, 0, 1, 2, 3]));
    CheckIn('SELECT id FROM fz WHERE n BETWEEN -3 AND -1',
      Expect([-3, -2, -1]));
    CheckIn('SELECT id FROM fz WHERE n > -3 AND n < -1',
      Expect([-2]));
    CheckIn('SELECT id FROM fz WHERE n IN (19,17,-3) ORDER BY id DESC', 
      Expect([19, 17, -3]));
  finally
    CloseV3(S);
  end;
end;

  { Sprint 3.7: zone map v3'te DEVRE DISI (duz tam tarama). Budama olmadigi
  icin sonuclar degismemeli: 3000 satirlik tabloda aralik/esitlik/IN
  sorgularinin sonuclari Pascal'da hesaplanan beklentiyle birebir
  karsilastirilir. }
procedure TestZoneMapFallback;
const
  N = 3000;
  MODU = 997;
var
  S: TV3Sql;
  r: TSqlResult;
  vals: array[0..N - 1] of Integer;
  i, a, b, k, exp: Integer;
  bat: string;

  function CountRange(Lo, Hi: Integer): Integer;
  var
    j: Integer;
  begin
    Result := 0;
    for j := 0 to N - 1 do
      if (vals[j] >= Lo) and (vals[j] < Hi) then Inc(Result);
  end;

  function CountEq(V: Integer): Integer;
  var
    j: Integer;
  begin
    Result := 0;
    for j := 0 to N - 1 do
      if vals[j] = V then Inc(Result);
  end;

  procedure CheckCount(const Sql: string; AExpected: Integer);
  var
    rr: TSqlResult;
    got: Integer;
  begin
    rr := Exec(S, Sql);
    if gErr then
    begin
      Fail('zonemap: ' + Sql + ': ' + rr.Msg);
      Exit;
    end;
    got := StrToIntDef(Cel(rr, 0, 0), -1);
    if got = AExpected then
      Ok(Format('zonemap: %s -> %d', [Sql, got]))
    else
      Fail(Format('zonemap: %s -> %d (beklenen %d)', [Sql, got, AExpected]));
  end;

begin
  WriteLn;
  WriteLn('Sprint 3.7 - v3''te zone map devre disi: tam tarama dogru sonuc');
  CleanDir;
  OpenV3(S, 'zone.odb', True);
  try
    r := Exec(S, 'CREATE TABLE z (id INTEGER PRIMARY KEY, val INTEGER, ad TEXT)');
    if not gErr then Ok('zonemap: tablo olustu') else Fail('zonemap: CREATE: ' + r.Msg);

    { Toplu INSERT (tek cumlede 3000 satir cok uzun olur; parti halinde). }
    bat := '';
    for i := 0 to N - 1 do
    begin
      vals[i] := (i * 37) mod MODU;
      if bat <> '' then bat := bat + ',';
      bat := bat + Format('(%d,%d,''n%d'')', [i + 1, vals[i], i + 1]);
      if ((i + 1) mod 100 = 0) or (i = N - 1) then
      begin
        r := Exec(S, 'INSERT INTO z VALUES ' + bat);
        if gErr then
        begin
          Fail('zonemap: INSERT: ' + r.Msg);
          Break;
        end;
        bat := '';
      end;
    end;
    if not gErr then Ok('zonemap: 3000 satir yazildi');

    CheckCount('SELECT COUNT(*) FROM z', N);

    { Aralik sorgulari (zone map budamasinin asil hedefi). }
    for i := 0 to 7 do
    begin
      a := i * 125;
      b := a + 125;
      CheckCount(Format('SELECT COUNT(*) FROM z WHERE val >= %d AND val < %d', [a, b]),
        CountRange(a, b));
    end;
    CheckCount('SELECT COUNT(*) FROM z WHERE val >= 900', CountRange(900, MODU));
    CheckCount('SELECT COUNT(*) FROM z WHERE val < 10', CountRange(0, 10));
    CheckCount('SELECT COUNT(*) FROM z WHERE val >= 997 AND val < 2000', 0);
    CheckCount('SELECT COUNT(*) FROM z WHERE val > 996', 0);

    { Esitlik + IN + esitsizlik. }
    CheckCount('SELECT COUNT(*) FROM z WHERE val = 5', CountEq(5));
    CheckCount('SELECT COUNT(*) FROM z WHERE val = 0', CountEq(0));
    CheckCount('SELECT COUNT(*) FROM z WHERE val = 996', CountEq(996));
    CheckCount('SELECT COUNT(*) FROM z WHERE val <> 500', N - CountEq(500));
    CheckCount('SELECT COUNT(*) FROM z WHERE val IN (1, 2, 3, 997)',
      CountEq(1) + CountEq(2) + CountEq(3) + CountEq(997));

    { Karma kosul: aralik + PK kosulu. }
    exp := 0;
    for k := 0 to N - 1 do
      if (vals[k] >= 400) and (vals[k] < 600) and (k + 1 > 1000) then Inc(exp);
    CheckCount('SELECT COUNT(*) FROM z WHERE val >= 400 AND val < 600 AND id > 1000', exp);

    { Budama yoklugunda da dogru satirlar gelir: en kucuk degerin PK'si. }
    r := Exec(S, 'SELECT id FROM z WHERE val = 0 ORDER BY id LIMIT 1');
    if (not gErr) and (Cel(r, 0, 0) = '1') then
      Ok('zonemap: val = 0 -> ilk PK 1')
    else
      Fail('zonemap: val = 0 sorgusu: ' + r.Msg);

    { ORDER BY + LIMIT (akış/top-N yolu v3'te genel yola duser). }
    r := Exec(S, 'SELECT val FROM z ORDER BY val DESC, id LIMIT 3');
    if (not gErr) and (Length(r.Rows) = 3) and (Cel(r, 0, 0) = IntToStr(MODU - 1)) then
      Ok('zonemap: ORDER BY val DESC LIMIT 3 ilk deger ' + IntToStr(MODU - 1))
    else
      Fail('zonemap: ORDER BY: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  { Yeniden acilis: ayni sonuclar. }
  OpenV3(S, 'zone.odb', False);
  try
    CheckCount('SELECT COUNT(*) FROM z', N);
    CheckCount('SELECT COUNT(*) FROM z WHERE val >= 125 AND val < 250',
      CountRange(125, 250));
    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) then
      Ok('zonemap: yeniden acilis sonrasi VERIFY: ' + r.Msg)
    else
      Fail('zonemap: VERIFY: ' + r.Msg);
  finally
    CloseV3(S);
  end;
end;

  { Sprint 3.11: SQLancer tarzi RASGELE diferansiyel. v3'te ham/akisli yol
  (Kv) olmadigi icin sqltest'in T111/T147 oracle'lari zayiflar: ayni yol
  iki kez kosar. Burada BAGIMSIZ oracle Pascal'da UC-DEGERLI MANTIK
  (TRUE/FALSE/UNKNOWN) ile hesaplanir ve SQL sonucu satir satir
  karsilastirilir. Tohum sabittir: kosu tekrarlanabilir. }
{ v3.3: SAYFA duzeyi zone map. v3 heap'i satirlari ekleme sirasina gore
  sayfalara yerlestirdigi icin monoton artan bir kolonda her sayfa DAR bir
  aralik tasir; harita sayfalarin buyuk cogunlugunu budayabilir. Sinanan:
  (a) budama sonrasi sonuc AYNI, (b) budama gercekten oluyor
  (zone_pruned_pages), (c) NULL'lu satir budamayi bozmuyor,
  (d) commit edilmemis (kirli) islemde harita KULLANILMIYOR. }
procedure TestPageZoneMap;
const
  N = 20000;
  THRESH = 59000;      { a = 3*id; a > 59000 -> id >= 19667 -> 334 satir }
  EXPECT = 334;
var
  S: TV3Sql;
  r: TSqlResult;
  i, pruned1, pruned2, pruned3: Integer;
  okAll: Boolean;
  function Stat(const Name: string): Integer;
  var
    k: Integer;
  begin
    Result := -1;
    for k := 0 to High(r.Rows) do
      if Cel(r, k, 0) = Name then
      begin
        Result := StrToIntDef(Cel(r, k, 1), -1);
        Exit;
      end;
  end;
begin
  WriteLn;
  WriteLn('v3.3 - sayfa duzeyi zone map (budama + dogruluk)');
  CleanDir;
  OpenV3(S, 'zm.odb', True);
  try
    r := Exec(S, 'CREATE TABLE zm (id INTEGER PRIMARY KEY, a INTEGER)');
    if gErr then
    begin
      Fail('zm: CREATE: ' + r.Msg);
      Exit;
    end;
    okAll := True;
    for i := 1 to N do
    begin
      r := Exec(S, Format('INSERT INTO zm VALUES (%d, %d)', [i, i * 3]));
      if gErr then
      begin
        okAll := False;
        Fail('zm: INSERT: ' + r.Msg);
        Break;
      end;
    end;
    if not okAll then Exit;

    { 1) Ilk sorgu haritayi INSA eder: budama yok. NOT: COUNT(*) yolu
      indeks/sayac hizli yolunu kullanabilir; zone map yalnizca AKISLI
      (streaming) satir seciminde devreye girer. }
    r := Exec(S, Format('SELECT a FROM zm WHERE a > %d', [THRESH]));
    if (not gErr) and (Length(r.Rows) = EXPECT) then
      Ok(Format('zm: harita insasi sirasinda sonuc dogru (%d)', [EXPECT]))
    else
      Fail(Format('zm: ilk SELECT: %d satir %s', [Length(r.Rows), r.Msg]));
    r := Exec(S, 'SHOW STATS');
    pruned1 := Stat('zone_pruned_pages');
    if pruned1 = 0 then
      Ok('zm: harita insasinda budama yok (0 sayfa)')
    else
      Fail(Format('zm: ilk taramada beklenmedik budama: %d', [pruned1]));

    { 2) Ayni sorgu: harita hazir -> sayfalarin cogu atlanir. }
    r := Exec(S, Format('SELECT a FROM zm WHERE a > %d', [THRESH]));
    if (not gErr) and (Length(r.Rows) = EXPECT) then
      Ok('zm: budanmis taramada sonuc AYNI')
    else
      Fail(Format('zm: budanmis SELECT: %d satir %s',
        [Length(r.Rows), r.Msg]));
    r := Exec(S, 'SHOW STATS');
    pruned2 := Stat('zone_pruned_pages');
    if pruned2 >= 50 then
      Ok(Format('zm: zone map %d sayfayi diskten okumadan atladi', [pruned2]))
    else
      Fail(Format('zm: budama beklenenin altinda (%d sayfa)', [pruned2]));

    { 3) Tum aralik: budanacak sayfa YOK, sonuc tam. }
    r := Exec(S, 'SELECT a FROM zm WHERE a >= 0');
    if (not gErr) and (Length(r.Rows) = N) then
      Ok(Format('zm: tum aralik sorgusu %d satir', [N]))
    else
      Fail(Format('zm: tum aralik SELECT: %d satir %s',
        [Length(r.Rows), r.Msg]));
    r := Exec(S, 'SHOW STATS');
    pruned3 := Stat('zone_pruned_pages');
    { Tum aralikta hicbir DOLU sayfa budanamaz; yalnizca tabloya ait satir
      tasimayan (bos/preallocated) sayfalar atlanir. }
    if pruned3 < pruned2 then
      Ok(Format('zm: tum aralikta yalnizca bos sayfalar atlandi (%d < %d)',
        [pruned3, pruned2]))
    else
      Fail(Format('zm: tum aralikta beklenmedik budama: %d', [pruned3]));

    { 4) NULL'lu satir: harita NULL'u atlar (kiyas FALSE), budama surer. }
    r := Exec(S, Format('INSERT INTO zm VALUES (%d, NULL)', [N + 1]));
    if gErr then
    begin
      Fail('zm: NULL INSERT: ' + r.Msg);
      Exit;
    end;
    { Damga degisti: bu sorgu haritayi YENIDEN insa eder. }
    r := Exec(S, Format('SELECT a FROM zm WHERE a > %d', [THRESH]));
    if (not gErr) and (Length(r.Rows) = EXPECT) then
      Ok('zm: NULL satirdan sonra sonuc dogru')
    else
      Fail(Format('zm: NULL sonrasi SELECT: %d satir %s',
        [Length(r.Rows), r.Msg]));
    { Ikinci kosu: budama yine calisir (NULL kolonu kilitlemedi). }
    r := Exec(S, Format('SELECT a FROM zm WHERE a > %d', [THRESH]));
    r := Exec(S, 'SHOW STATS');
    pruned3 := Stat('zone_pruned_pages');
    if pruned3 >= 50 then
      Ok(Format('zm: NULL satirdan sonra budama suruyor (%d sayfa)', [pruned3]))
    else
      Fail(Format('zm: NULL sonrasi budama yok (%d)', [pruned3]));

    { 5) KRITIK: commit edilmemis islemde harita KULLANILMAMALI. }
    Exec(S, 'BEGIN');
    r := Exec(S, Format('INSERT INTO zm VALUES (%d, %d)', [N + 2, 999999]));
    { Bu satir henuz sayfaya yazilmadi; eski harita onu goremez. Budama
      kapali olmali, yoksa satir kaybolur. }
    r := Exec(S, Format('SELECT a FROM zm WHERE a > %d', [THRESH]));
    if (not gErr) and (Length(r.Rows) = EXPECT + 1) then
      Ok('zm: kirli islemde yeni satir goruldu (harita kullanilmadi)')
    else
      Fail(Format('zm: kirli islem SELECT: %d satir %s',
        [Length(r.Rows), r.Msg]));
    r := Exec(S, 'ROLLBACK');
    if gErr then Fail('zm: ROLLBACK: ' + r.Msg);

    { 6) COMMIT'li 500 satir sonrasi budama yine dogru. }
    Exec(S, 'BEGIN');
    for i := N + 10 to N + 509 do
      Exec(S, Format('INSERT INTO zm VALUES (%d, %d)', [i, i * 3]));
    r := Exec(S, 'COMMIT');
    if gErr then Fail('zm: COMMIT: ' + r.Msg);
    r := Exec(S, Format('SELECT a FROM zm WHERE a > %d', [THRESH]));
    { 334 eski + 500 yeni (hepsi esik ustunde) + 1 NULL (a NULL, sayilmaz) }
    if (not gErr) and (Length(r.Rows) = EXPECT + 500) then
      Ok('zm: COMMIT sonrasi 500 yeni satir dogru sayildi')
    else
      Fail(Format('zm: COMMIT sonrasi SELECT: %d satir %s',
        [Length(r.Rows), r.Msg]));
  finally
    CloseV3(S);
  end;
end;

procedure TestRowIntVarint;
const
  NV = 12;
  { 1..6 baytlik varintler + 8 baytlik HAM'a geri donen degerler (>= 2^55
    zigzag 8 bayttan fazla tutar) + Int64 sinirlari. }
  IVALS: array[0..NV - 1] of Int64 = (
    0, 1, -1, 127, -128, 1000000,
    1099511627776, -1099511627776,
    1152921504606846976, -1152921504606846976,
    9223372036854775807, -9223372036854775807);
  SORTED = '-9223372036854775807,-1152921504606846976,-1099511627776,' +
    '-128,-1,0,1,127,1000000,1099511627776,1152921504606846976,' +
    '9223372036854775807';
var
  S: TV3Sql;
  r: TSqlResult;
  i, p: Integer;
  l32: LongInt;
  okAll: Boolean;
  got: string;
  raw, ob: TBytes;
  eng: TVdbPageEngine;
  tid: Word;
  pkS: string;
  vals: TStrArray;
  v: Int64;
  ftype: array[0..1] of Byte;
  foff, flen: array[0..1] of Integer;
begin
  WriteLn;
  WriteLn('v3.2 - satir INT kodlamasi (zigzag varint + eski ham bicim uyumu)');
  CleanDir;
  OpenV3(S, 'rowint.odb', True);
  try
    r := Exec(S, 'CREATE TABLE r (id INTEGER PRIMARY KEY, v INTEGER)');
    if gErr then
    begin
      Fail('rowint: CREATE: ' + r.Msg);
      Exit;
    end;
    for i := 0 to NV - 1 do
    begin
      r := Exec(S, Format('INSERT INTO r VALUES (%d, %d)', [i + 1, IVALS[i]]));
      if gErr then
      begin
        Fail('rowint: INSERT: ' + r.Msg);
        Exit;
      end;
    end;

    okAll := True;
    for i := 0 to NV - 1 do
    begin
      r := Exec(S, Format('SELECT v FROM r WHERE id = %d', [i + 1]));
      if gErr or (Cel(r, 0, 0) <> IntToStr(IVALS[i])) then
      begin
        okAll := False;
        Fail(Format('rowint: %s -> %s (%s)',
          [IntToStr(IVALS[i]), Cel(r, 0, 0), r.Msg]));
      end;
    end;
    { Ayni degerler LITERAL olarak da dogru mu? (satir kodlamasindan bagimsiz
      kontrol: hata buradaysa kaynak SQL sabiti, kodlama degil.) }
    for i := 0 to NV - 1 do
    begin
      r := Exec(S, Format('SELECT %d', [IVALS[i]]));
      if gErr or (Cel(r, 0, 0) <> IntToStr(IVALS[i])) then
        Fail(Format('rowint: LITERAL %s -> %s (%s)',
          [IntToStr(IVALS[i]), Cel(r, 0, 0), r.Msg]));
    end;
    if okAll then
      Ok(Format('rowint: %d Int64 degeri birebir (varint + ham 8 bayt donusu)',
        [NV]));

    { ORDER BY: kucuk degerler artik 1-6 bayt; 8 bayt okuyan yol KOMSU
      baytlari okuyup siralamayi bozardi. }
    r := Exec(S, 'SELECT v FROM r ORDER BY v');
    got := '';
    if not gErr then
      for i := 0 to High(r.Rows) do
      begin
        if i > 0 then got := got + ',';
        got := got + Cel(r, i, 0);
      end;
    if (not gErr) and (got = SORTED) then
      Ok('rowint: ORDER BY INT sirasi dogru')
    else
      Fail('rowint: ORDER BY: ' + got + ' ' + r.Msg);

    r := Exec(S, 'SELECT COUNT(*) FROM r WHERE v >= 0');
    if (not gErr) and (Cel(r, 0, 0) = '7') then
      Ok('rowint: WHERE v >= 0 on-elemesi dogru (7 satir)')
    else
      Fail('rowint: WHERE v >= 0: ' + Cel(r, 0, 0) + ' ' + r.Msg);

    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) then
      Ok('rowint: VERIFY gecti')
    else
      Fail('rowint: VERIFY: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  { Kucuk deger GERCEKTEN varint mi? Satiri motordan ham okuyup bakilir. }
  eng := TVdbPageEngine.Create(DirOf('rowint.odb'), 64);
  try
    eng.Open(False);
    if eng.TryGet(VDbHashKey('r', '1'), raw) then
    begin
      if VDbPeekRawRow(raw, 2, tid, pkS, ftype, foff, flen) and
         (flen[1] >= 1) and (flen[1] <= 7) then
        Ok(Format('rowint: id=1 satiri v alani %d bayt (eski bicim 8 bayt)',
          [flen[1]]))
      else
        Fail(Format('rowint: v alani beklenen varint degil (flen=%d)', [flen[1]]));
    end
    else
      Fail('rowint: satir motordan okunamadi');
  finally
    eng.Free;
  end;

  { ESKI bicim (vlen=8 + ham little-endian Int64) HALA cozulmeli: sahadaki
    dosyalar bu bicimle yazildi. Satir elle kurulur. }
  l32 := 8;
  SetLength(ob, 7 + 1 + 4 + 8 + 1 + 4 + 2);
  ob[0] := 7; ob[1] := 0;                 { TableId }
  ob[2] := 1; ob[3] := 0;                 { pk uzunlugu }
  ob[4] := Ord('1');
  ob[5] := 2; ob[6] := 0;                 { kolon sayisi }
  p := 7;
  ob[p] := VCT_INT; Inc(p);
  Move(l32, ob[p], 4); Inc(p, 4);
  v := -123456789;
  Move(v, ob[p], 8); Inc(p, 8);
  ob[p] := VCT_STR; Inc(p);
  l32 := 2;
  Move(l32, ob[p], 4); Inc(p, 4);
  ob[p] := Ord('a'); ob[p + 1] := Ord('b');
  if VDbDecodeRawRowP(@ob[0], Length(ob), tid, pkS, vals) and (tid = 7) and
     (pkS = '1') and (Length(vals) = 2) and (vals[0] = '-123456789') and
     (vals[1] = 'ab') then
    Ok('rowint: ESKI bicim satir (vlen=8 ham Int64) birebir cozuldu')
  else
    Fail('rowint: ESKI bicim satir cozulemedi');

  { Bozuk/kisa yuk reddedilir (sessiz yanlis sayi uretilmez). }
  SetLength(ob, 9);
  ob[0] := $85; ob[1] := $00;             { kanonik olmayan 2 baytlik 5 }
  okAll := not VDbIntFromPayload(@ob[0], 2, v);
  SetLength(ob, 9);
  ob[0] := $85;                            { kesik varint }
  okAll := okAll and (not VDbIntFromPayload(@ob[0], 1, v));
  okAll := okAll and (not VDbIntFromPayload(@ob[0], 9, v));
  if okAll then
    Ok('rowint: bozuk varint (kanonik degil/kesik/uzun) reddedildi')
  else
    Fail('rowint: bozuk varint kabul edildi');
end;

procedure TestFuzzOracle;
const
  NROW = 400;
  NQ = 240;
  NODE_MAX = 24;
type
  TTri = (trFalse, trTrue, trUnknown);
  TNodeKind = (nkTrue, nkIntCmp, nkIsNull, nkIsNotNull, nkIntIn, nkIntNotIn,
    nkBetween, nkNotBetween, nkTextEq, nkTextCmp, nkTextIsNull, nkTextIsNotNull,
    nkAnd, nkOr, nkNot);
  TNode = record
    Kind: TNodeKind;
    Op: Integer;        // int: 0 =, 1 <>, 2 <, 3 <=, 4 >, 5 >=
    Val, Val2: Integer;
    Run: array[0..3] of Integer;   // IN listesi
    RunN: Integer;
    HasNull: Boolean;              // IN listesinde NULL var mi
    Txt: string;
    TxtOp: Integer;                // metin: 0 =, 1 <>
    A, B: Integer;                 // alt dugum indeksleri
  end;
var
  S: TV3Sql;
  r: TSqlResult;
  nodes: array[0..NODE_MAX - 1] of TNode;
  nNode: Integer;
  hasA: array[0..NROW - 1] of Boolean;
  valA: array[0..NROW - 1] of Integer;
  hasS: array[0..NROW - 1] of Boolean;
  valS: array[0..NROW - 1] of string;
  i, q, root, bad, expN: Integer;
  sql, got, pred: string;
  okAll: Boolean;

  function RandRange(Lo, Hi: Integer): Integer;
  begin
    Result := Lo + Random(Hi - Lo + 1);
  end;

  { ---- uc-degerli mantik ---- }
  function TriNot(T: TTri): TTri;
  begin
    case T of
      trTrue: Result := trFalse;
      trFalse: Result := trTrue;
    else
      Result := trUnknown;
    end;
  end;

  function TriAnd(X, Y: TTri): TTri;
  begin
    if (X = trFalse) or (Y = trFalse) then Result := trFalse
    else if (X = trUnknown) or (Y = trUnknown) then Result := trUnknown
    else Result := trTrue;
  end;

  function TriOr(X, Y: TTri): TTri;
  begin
    if (X = trTrue) or (Y = trTrue) then Result := trTrue
    else if (X = trUnknown) or (Y = trUnknown) then Result := trUnknown
    else Result := trFalse;
  end;

  function CmpTri(C: Boolean): TTri;
  begin
    if C then Result := trTrue else Result := trFalse;
  end;

  function IntCmp(Op, X, Y: Integer): TTri;
  begin
    case Op of
      0: Result := CmpTri(X = Y);
      1: Result := CmpTri(X <> Y);
      2: Result := CmpTri(X < Y);
      3: Result := CmpTri(X <= Y);
      4: Result := CmpTri(X > Y);
    else
      Result := CmpTri(X >= Y);
    end;
  end;

  function EvalNode(N: Integer; Row: Integer): TTri;
  var
    C: TNode;
    Eq, HasEq, HasUnk: Boolean;
    j: Integer;
  begin
    C := nodes[N];
    case C.Kind of
      nkTrue: Result := trTrue;
      nkAnd: Result := TriAnd(EvalNode(C.A, Row), EvalNode(C.B, Row));
      nkOr:  Result := TriOr(EvalNode(C.A, Row), EvalNode(C.B, Row));
      nkNot: Result := TriNot(EvalNode(C.A, Row));
      nkIsNull:    if hasA[Row] then Result := trFalse else Result := trTrue;
      nkIsNotNull: if hasA[Row] then Result := trTrue else Result := trFalse;
      nkTextIsNull:    if hasS[Row] then Result := trFalse else Result := trTrue;
      nkTextIsNotNull: if hasS[Row] then Result := trTrue else Result := trFalse;
      nkIntCmp:
        if not hasA[Row] then Result := trUnknown
        else Result := IntCmp(C.Op, valA[Row], C.Val);
      nkBetween:
        if not hasA[Row] then Result := trUnknown
        else Result := TriAnd(IntCmp(5, valA[Row], C.Val), IntCmp(3, valA[Row], C.Val2));
      nkNotBetween:
        if not hasA[Row] then Result := trUnknown
        else Result := TriNot(TriAnd(IntCmp(5, valA[Row], C.Val), IntCmp(3, valA[Row], C.Val2)));
      nkIntIn, nkIntNotIn:
        begin
          if not hasA[Row] then
          begin
            Result := trUnknown;
            Exit;
          end;
          Eq := False;
          for j := 0 to C.RunN - 1 do
            if valA[Row] = C.Run[j] then Eq := True;
          if Eq then Result := trTrue
          else if C.HasNull then Result := trUnknown
          else Result := trFalse;
          if C.Kind = nkIntNotIn then Result := TriNot(Result);
        end;
      nkTextEq, nkTextCmp:
        begin
          if not hasS[Row] then
          begin
            Result := trUnknown;
            Exit;
          end;
          HasEq := (valS[Row] = C.Txt);
          if (C.Kind = nkTextEq) or (C.TxtOp = 0) then
            Result := CmpTri(HasEq)
          else
            Result := CmpTri(not HasEq);
        end;
    else
      Result := trUnknown;
    end;
  end;

  { ---- rasgele ifade uretimi ---- }
  function NewNode(K: TNodeKind): Integer;
  begin
    Result := nNode;
    nodes[Result].Kind := K;
    nodes[Result].RunN := 0;
    nodes[Result].HasNull := False;
    Inc(nNode);
  end;

  function GenLeaf: Integer;
  var
    k, j, a, b: Integer;
  begin
    case RandRange(0, 8) of
      0, 1:
        begin
          Result := NewNode(nkIntCmp);
          nodes[Result].Op := RandRange(0, 5);
          nodes[Result].Val := RandRange(-10, 70);
        end;
      2:
        begin
          Result := NewNode(nkBetween);
          a := RandRange(-10, 40);
          b := a + RandRange(0, 30);
          nodes[Result].Val := a;
          nodes[Result].Val2 := b;
        end;
      3:
        begin
          Result := NewNode(nkNotBetween);
          a := RandRange(-10, 40);
          b := a + RandRange(0, 30);
          nodes[Result].Val := a;
          nodes[Result].Val2 := b;
        end;
      4:
        begin
          { IN listesi; bazen NULL icerir (3VL sinamasi). }
          if Random(2) = 0 then
            Result := NewNode(nkIntIn)
          else
            Result := NewNode(nkIntNotIn);
          nodes[Result].RunN := RandRange(1, 4);
          for j := 0 to nodes[Result].RunN - 1 do
            nodes[Result].Run[j] := RandRange(-10, 70);
          nodes[Result].HasNull := Random(3) = 0;
        end;
      5:
        begin
          if Random(2) = 0 then Result := NewNode(nkIsNull)
          else Result := NewNode(nkIsNotNull);
        end;
      6:
        begin
          Result := NewNode(nkTextEq);
          nodes[Result].Txt := Chr(Ord('a') + Random(4));
          nodes[Result].TxtOp := 0;
        end;
      7:
        begin
          Result := NewNode(nkTextCmp);
          nodes[Result].Txt := Chr(Ord('a') + Random(4));
          nodes[Result].TxtOp := Random(2);
        end;
    else
      begin
        if Random(2) = 0 then Result := NewNode(nkTextIsNull)
        else Result := NewNode(nkTextIsNotNull);
      end;
    end;
    k := 0;   { sessiz kalsin }
    if k <> 0 then Exit;
  end;

  function GenExpr(Depth: Integer): Integer;
  var
    L, R: Integer;
  begin
    if (Depth <= 0) or (Random(100) < 40) then
      Result := GenLeaf
    else
      case RandRange(0, 2) of
        0:
          begin
            L := GenExpr(Depth - 1);
            R := GenExpr(Depth - 1);
            Result := NewNode(nkAnd);
            nodes[Result].A := L;
            nodes[Result].B := R;
          end;
        1:
          begin
            L := GenExpr(Depth - 1);
            R := GenExpr(Depth - 1);
            Result := NewNode(nkOr);
            nodes[Result].A := L;
            nodes[Result].B := R;
          end;
      else
        begin
          L := GenExpr(Depth - 1);
          Result := NewNode(nkNot);
          nodes[Result].A := L;
        end;
      end;
  end;

  function Render(N: Integer): string;
  var
    C: TNode;
    j: Integer;
    opS: string;
  begin
    C := nodes[N];
    case C.Kind of
      nkTrue: Result := '1 = 1';
      nkAnd:  Result := '(' + Render(C.A) + ' AND ' + Render(C.B) + ')';
      nkOr:   Result := '(' + Render(C.A) + ' OR ' + Render(C.B) + ')';
      nkNot:  Result := '(NOT ' + Render(C.A) + ')';
      nkIsNull:    Result := '(a IS NULL)';
      nkIsNotNull: Result := '(a IS NOT NULL)';
      nkTextIsNull:    Result := '(s IS NULL)';
      nkTextIsNotNull: Result := '(s IS NOT NULL)';
      nkIntCmp:
        begin
          case C.Op of
            0: opS := '=';
            1: opS := '<>';
            2: opS := '<';
            3: opS := '<=';
            4: opS := '>';
          else
            opS := '>=';
          end;
          Result := Format('(a %s %d)', [opS, C.Val]);
        end;
      nkBetween:    Result := Format('(a BETWEEN %d AND %d)', [C.Val, C.Val2]);
      nkNotBetween: Result := Format('(a NOT BETWEEN %d AND %d)', [C.Val, C.Val2]);
      nkIntIn, nkIntNotIn:
        begin
          Result := '(a ';
          if C.Kind = nkIntNotIn then Result := Result + 'NOT ';
          Result := Result + 'IN (';
          for j := 0 to C.RunN - 1 do
          begin
            if j > 0 then Result := Result + ', ';
            Result := Result + IntToStr(C.Run[j]);
          end;
          if C.HasNull then
          begin
            if C.RunN > 0 then Result := Result + ', ';
            Result := Result + 'NULL';
          end;
          Result := Result + '))';
        end;
      nkTextEq, nkTextCmp:
        begin
          if (C.Kind = nkTextCmp) and (C.TxtOp = 1) then
            Result := Format('(s <> ''%s'')', [C.Txt])
          else
            Result := Format('(s = ''%s'')', [C.Txt]);
        end;
    else
      Result := '1 = 1';
    end;
  end;

  { ---- kosu ---- }
  procedure RunOne;
  var
    j, expected: Integer;
    ids: TStringList;
    rr: TSqlResult;
  begin
    nNode := 0;
    root := GenExpr(3);
    pred := Render(root);

    expected := 0;
    for j := 0 to NROW - 1 do
      if EvalNode(root, j) = trTrue then Inc(expected);

    rr := Exec(S, 'SELECT COUNT(*) FROM f WHERE ' + pred);
    if gErr then
    begin
      Fail('fuzz: SQL hatasi: ' + pred + ' -> ' + rr.Msg);
      Exit;
    end;
    got := Cel(rr, 0, 0);
    if StrToIntDef(got, -1) <> expected then
    begin
      Inc(bad);
      Fail(Format('fuzz: COUNT uyusmadi (SQL %s, oracle %d): %s',
        [got, expected, pred]));
      Exit;
    end;

    { Yalniz sayi degil, SATIR KUMESI de karsilastirilir. }
    ids := TStringList.Create;
    try
      for j := 0 to NROW - 1 do
        if EvalNode(root, j) = trTrue then ids.Add(IntToStr(j + 1));
      rr := Exec(S, 'SELECT id FROM f WHERE ' + pred + ' ORDER BY id');
      if gErr then
      begin
        Fail('fuzz: SQL hatasi (satir): ' + pred + ' -> ' + rr.Msg);
        Exit;
      end;
      if Length(rr.Rows) <> ids.Count then
      begin
        Inc(bad);
        Fail(Format('fuzz: satir sayisi uyusmadi (SQL %d, oracle %d): %s',
          [Length(rr.Rows), ids.Count, pred]));
        Exit;
      end;
      for j := 0 to High(rr.Rows) do
        if Cel(rr, j, 0) <> ids[j] then
        begin
          Inc(bad);
          Fail(Format('fuzz: satir %d uyusmadi (SQL %s, oracle %s): %s',
            [j, Cel(rr, j, 0), ids[j], pred]));
          Exit;
        end;
    finally
      ids.Free;
    end;
  end;

begin
  WriteLn;
  WriteLn('Sprint 3.11 - SQLancer tarzi rasgele diferansiyel (bagimsiz 3VL oracle)');
  CleanDir;
  Randomize;
  RandSeed := 20261025;
  bad := 0;
  OpenV3(S, 'fuzz.odb', True);
  try
    r := Exec(S, 'CREATE TABLE f (id INTEGER PRIMARY KEY, a INTEGER, s TEXT)');
    if not gErr then Ok('fuzz: tablo olustu') else Fail('fuzz: CREATE: ' + r.Msg);

    { Veri: a = NULL ya da -10..69, s = NULL ya da 'a'..'d'. }
    okAll := True;
    for i := 0 to NROW - 1 do
    begin
      hasA[i] := Random(100) >= 20;      // ~%20 NULL
      valA[i] := RandRange(-10, 69);
      hasS[i] := Random(100) >= 25;
      valS[i] := Chr(Ord('a') + Random(4));
      if hasA[i] and hasS[i] then
        sql := Format('INSERT INTO f VALUES (%d, %d, ''%s'')', [i + 1, valA[i], valS[i]])
      else if (not hasA[i]) and hasS[i] then
        sql := Format('INSERT INTO f VALUES (%d, NULL, ''%s'')', [i + 1, valS[i]])
      else if hasA[i] and (not hasS[i]) then
        sql := Format('INSERT INTO f VALUES (%d, %d, NULL)', [i + 1, valA[i]])
      else
        sql := Format('INSERT INTO f VALUES (%d, NULL, NULL)', [i + 1]);
      r := Exec(S, sql);
      if gErr then
      begin
        Fail('fuzz: INSERT: ' + r.Msg);
        okAll := False;
        Break;
      end;
    end;
    if okAll then
      Ok(Format('fuzz: %d satir yazildi (a/s NULL dahil)', [NROW]));

    r := Exec(S, 'SELECT COUNT(*) FROM f');
    if (not gErr) and (Cel(r, 0, 0) = IntToStr(NROW)) then
      Ok('fuzz: taban COUNT tam')
    else
      Fail('fuzz: taban COUNT: ' + r.Msg);

    for q := 1 to NQ do
      RunOne;

    if bad = 0 then
      Ok(Format('fuzz: %d rasgele sorgu oracle ile BIREBIR', [NQ]))
    else
      Fail(Format('fuzz: %d/%d sorgu uyusmadi', [bad, NQ]));

    r := Exec(S, 'VERIFY');
    if (not gErr) and (r.Affected = 1) then
      Ok('fuzz: VERIFY gecti: ' + r.Msg)
    else
      Fail('fuzz: VERIFY: ' + r.Msg);
  finally
    CloseV3(S);
  end;

  { Yeniden acilis: ayni veri, ayni oracle sonuclari. }
  OpenV3(S, 'fuzz.odb', False);
  try
    r := Exec(S, 'SELECT COUNT(*) FROM f');
    if (not gErr) and (Cel(r, 0, 0) = IntToStr(NROW)) then
      Ok('fuzz: yeniden acilista COUNT tam')
    else
      Fail('fuzz: yeniden acilis: ' + r.Msg);
    bad := 0;
    for q := 1 to 40 do
      RunOne;
    if bad = 0 then
      Ok('fuzz: yeniden acilis sonrasi 40 sorgu BIREBIR')
    else
      Fail(Format('fuzz: yeniden acilis sonrasi %d/40 uyusmadi', [bad]));
  finally
    CloseV3(S);
  end;
end;

procedure TestMultiSession;
var
  S: TV3Sql;
  Sq2: TVSql;
  r: TSqlResult;
  function Exec2(const Sql: string): TSqlResult;
  begin
    gErr := False;
    try
      Result := Sq2.Exec(Sql);
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
  function One(const R: TSqlResult): string;
  begin
    Result := Cel(R, 0, 0);
  end;
  procedure Chk(const Cond: Boolean; const S1, S2: string);
  begin
    if Cond then Ok(S1) else Fail(S1 + ' | ' + S2);
  end;
var
  k: QWord;
  caught: Boolean;
  msg: string;
  cntA, cntB: string;
begin
  WriteLn;
  WriteLn('v3.4 - cok oturumlu yazma: ozel yazma kumesi + cakisma denetimi');
  CleanDir;
  OpenV3(S, 'ms.odb', True);
  Sq2 := TVSql.Create(S.Tb);
  try
    r := Exec(S, 'CREATE TABLE m (id INTEGER PRIMARY KEY, v INTEGER)');
    if gErr then
    begin
      Fail('ms: CREATE: ' + r.Msg);
      Exit;
    end;
    r := Exec(S, 'INSERT INTO m VALUES (1, 10), (2, 20)');
    if gErr then
    begin
      Fail('ms: INSERT taban: ' + r.Msg);
      Exit;
    end;

    { 1) IKI oturum AYNI ANDA yazma islemi acabilir (eski surumde ikincisi
         "baska bir oturumun acik islemi var" hatasi aliyordu). }
    r := Exec(S, 'BEGIN');
    Chk(not gErr, 'ms: A BEGIN', r.Msg);
    r := Exec(S, 'INSERT INTO m VALUES (3, 30)');
    Chk(not gErr, 'ms: A INSERT (3,30)', r.Msg);

    r := Exec2('BEGIN');
    Chk(not gErr, 'ms: B BEGIN (A acikken)', r.Msg);
    r := Exec2('INSERT INTO m VALUES (4, 40)');
    Chk(not gErr, 'ms: B INSERT (4,40)', r.Msg);

    { 2) Her oturum YALNIZ kendi yazisini + onaylanmis veriyi gorur. }
    r := Exec(S, 'SELECT COUNT(*) FROM m');
    cntA := One(r);
    Chk((not gErr) and (cntA = '3'), 'ms: A 3 satir gorur (2 taban + kendi)',
      cntA + ' ' + r.Msg);
    r := Exec2('SELECT COUNT(*) FROM m');
    cntB := One(r);
    Chk((not gErr) and (cntB = '3'), 'ms: B 3 satir gorur (2 taban + kendi)',
      cntB + ' ' + r.Msg);

    r := Exec(S, 'SELECT COUNT(*) FROM m WHERE id = 3');
    Chk((not gErr) and (One(r) = '1'), 'ms: A kendi satirini gorur', One(r));
    r := Exec2('SELECT COUNT(*) FROM m WHERE id = 3');
    Chk((not gErr) and (One(r) = '0'), 'ms: B A''nin commit edilmemis satirini GORMEZ',
      One(r) + ' ' + r.Msg);
    r := Exec2('SELECT COUNT(*) FROM m WHERE id = 4');
    Chk((not gErr) and (One(r) = '1'), 'ms: B kendi satirini gorur', One(r));
    r := Exec(S, 'SELECT COUNT(*) FROM m WHERE id = 4');
    Chk((not gErr) and (One(r) = '0'), 'ms: A B''nin commit edilmemis satirini GORMEZ',
      One(r) + ' ' + r.Msg);

    { 3) A commit eder: B hala KENDI anlik goruntusunu gorur (v3.15 snapshot
         isolation, v2 semantigi); commit'ten sonra BASLAYAN okuma A'nin
         satirini gorur. }
    r := Exec(S, 'COMMIT');
    Chk(not gErr, 'ms: A COMMIT', r.Msg);
    r := Exec2('SELECT COUNT(*) FROM m');
    Chk((not gErr) and (One(r) = '3'),
      'ms: B A commit''inden sonra KENDI anlik goruntusunu gorur (3 satir)',
      One(r) + ' ' + r.Msg);
    r := Exec2('SELECT COUNT(*) FROM m WHERE id = 3');
    Chk((not gErr) and (One(r) = '0'),
      'ms: B A''nin commit edilmis satirini GORMEZ (snapshot)',
      One(r) + ' ' + r.Msg);
    r := Exec2('COMMIT');
    Chk(not gErr, 'ms: B COMMIT', r.Msg);
    r := Exec(S, 'SELECT COUNT(*) FROM m');
    Chk((not gErr) and (One(r) = '4'), 'ms: iki commit sonrasi 4 satir', One(r));
    r := Exec2('SELECT COUNT(*) FROM m');
    Chk((not gErr) and (One(r) = '4'),
      'ms: commit sonrasi YENI okuma 4 satir', One(r) + ' ' + r.Msg);

    { 4) Ayni satiri iki oturum guncellerse KAYIP GUNCELLEME olmaz: ilk
         commit gecer, ikincisi commit ANINDA "yazma cakismasi" ile durur. }
    r := Exec(S, 'BEGIN');
    Chk(not gErr, 'ms: A BEGIN (cakisma)', r.Msg);
    r := Exec(S, 'UPDATE m SET v = 11 WHERE id = 1');
    Chk(not gErr, 'ms: A id=1 -> 11', r.Msg);
    r := Exec2('BEGIN');
    Chk(not gErr, 'ms: B BEGIN (cakisma)', r.Msg);
    r := Exec2('UPDATE m SET v = 99 WHERE id = 1');
    Chk(not gErr, 'ms: B kendi kumesinde id=1 -> 99', r.Msg);
    r := Exec(S, 'COMMIT');
    Chk(not gErr, 'ms: A COMMIT gecti (ilk commit kazanir)', r.Msg);
    r := Exec2('COMMIT');
    Chk(gErr, 'ms: B COMMIT kayip guncelleme nedeniyle DURDU',
      'beklenen hata, gelen: ' + r.Msg);
    r := Exec2('ROLLBACK');
    Chk(not gErr, 'ms: B cakisma sonrasi ROLLBACK temiz', r.Msg);
    r := Exec(S, 'SELECT v FROM m WHERE id = 1');
    Chk((not gErr) and (One(r) = '11'), 'ms: id=1 degeri 11 (B''nin 99''u yazilmadi)',
      One(r) + ' ' + r.Msg);

    { 4b) v3.6 HIZLI YOL SEMANTIGI: B commit ettikten SONRA A ayni satiri
         yazarsa cakisma YOKTUR (A yeni degeri gordu ve ona gore yazdi).
         Before-image seyrek tutulunca bu yolun bozulmadigi burada kilitlenir. }
    r := Exec(S, 'BEGIN');
    Chk(not gErr, 'ms: A BEGIN (4b)', r.Msg);
    r := Exec2('BEGIN');
    Chk(not gErr, 'ms: B BEGIN (4b)', r.Msg);
    r := Exec2('UPDATE m SET v = 200 WHERE id = 1');
    Chk(not gErr, 'ms: B id=1 -> 200 (4b)', r.Msg);
    r := Exec2('COMMIT');
    Chk(not gErr, 'ms: B COMMIT gecti (4b)', r.Msg);
    r := Exec2('SELECT v FROM m WHERE id = 1');
    Chk((not gErr) and (One(r) = '200'), 'ms: A 200 gorur (4b)', One(r) + ' ' + r.Msg);
    r := Exec(S, 'UPDATE m SET v = 300 WHERE id = 1');
    Chk(not gErr, 'ms: A id=1 -> 300 (4b, yeni deger uzerine)', r.Msg);
    r := Exec(S, 'COMMIT');
    Chk(not gErr, 'ms: A COMMIT cakismasiz gecti (4b)', 'beklenmedik hata: ' + r.Msg);
    r := Exec2('SELECT v FROM m WHERE id = 1');
    Chk((not gErr) and (One(r) = '300'), 'ms: son deger 300 (4b)', One(r) + ' ' + r.Msg);
    { 7. senaryo id=1 icin 11 bekledigi icin taban duruma geri donulur. }
    r := Exec(S, 'UPDATE m SET v = 11 WHERE id = 1');
    Chk(not gErr, 'ms: id=1 -> 11 (4b temizlik)', r.Msg);

    { 5) DDL coklu yazmada ACIKCA reddedilir (global sema durumu korunur). }
    r := Exec(S, 'BEGIN');
    Chk(not gErr, 'ms: A BEGIN (DDL)', r.Msg);
    r := Exec2('BEGIN');
    Chk(not gErr, 'ms: B BEGIN (DDL)', r.Msg);
    r := Exec2('CREATE TABLE ikinci (id INTEGER PRIMARY KEY)');
    Chk(gErr, 'ms: B coklu yazmada DDL reddedildi', 'beklenen hata, gelen: ' + r.Msg);
    r := Exec2('ROLLBACK');
    r := Exec(S, 'ROLLBACK');
    Chk(not gErr, 'ms: DDL denemesinden sonra iki ROLLBACK temiz', r.Msg);

    { 6) MOTOR duzeyi kayip-guncelleme denetimi: satir kilidi devrede
         olmasa bile (dogrudan KV yazimi) ikinci commit DURUR. }
    r := Exec(S, 'INSERT INTO m VALUES (9, 90)');
    Chk(not gErr, 'ms: kilit testi icin id=9 eklendi', r.Msg);
    k := VDbHashKey('m', '9');
    VDbSetTxnSession(1001);
    S.Be.BeginBatch;
    S.Be.Delete(k);
    VDbSetTxnSession(1002);
    S.Be.BeginBatch;
    S.Be.Delete(k);
    VDbSetTxnSession(1002);
    caught := False;
    msg := '';
    S.Be.CommitBatch;               // ilk commit gecer
    try
      VDbSetTxnSession(1001);
      S.Be.CommitBatch;             // ikinci commit cakisma gormeli
    except
      on E: Exception do
      begin
        caught := True;
        msg := E.Message;
      end;
    end;
    Chk(caught, 'ms: ikinci commit yazma cakismasi ile DURDU', msg);
    VDbSetTxnSession(1001);
    S.Be.AbortBatch;
    VDbSetTxnSession(0);

    { 7) Son durum tutarli: id=9 silindi, digerleri yerinde. }
    r := Exec(S, 'SELECT COUNT(*) FROM m');
    Chk((not gErr) and (One(r) = '4'), 'ms: son satir sayisi 4 (id=9 silindi)', One(r));
    r := Exec(S, 'SELECT v FROM m WHERE id = 1');
    Chk((not gErr) and (One(r) = '11'), 'ms: son deger tutarli', One(r));
    r := Exec(S, 'VERIFY');
    Chk((not gErr) and (r.Affected = 1), 'ms: VERIFY temiz', r.Msg);
  finally
    VDbSetTxnSession(0);
    Sq2.Free;
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
  TestDoubleOpen;
  TestBulkInsert(N);
  TestTxn;
  TestConstraints;
  TestIndex;
  TestJoin;
  TestVerifySql;
  TestBackupRestoreSql;
  TestVacuumSql;
  TestShowStats;
  TestReplicationV3;
  TestPitrSql;
  TestIndexInNegative;
  TestZoneMapFallback;
  TestRowIntVarint;
  TestPageZoneMap;
  TestMultiSession;
  TestFuzzOracle;
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
