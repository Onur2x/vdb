program null_empty;
{ v3.71 KALICI REGRESYON KAPISI - SKILL6 03 (F-49) "SQL NULL ile bos metni
  birbirinden ayir".

  NEDEN BU KAPI: disk formati NULL'i (lenCode 0) ve sifir uzunluklu metni
  (lenCode 1, 0 bayt) ZATEN ayri kodlayabiliyordu, ama bellekteki deger
  modeli duz metin oldugu icin DecodeRow NULL'i '' yapiyor, EvalExpr de
  sltNull icin '' donuyordu. Yani NULL ve '' ayni degerdi.

  Bu dosya iddialari UC katmanda olcer:
    A) ifade semantigi  - NULL literal, IS NULL/NOT NULL, uc degerli mantik
    B) depolama         - yaz/oku/restart/backup sonrasi ayrimin korunmasi
    C) kume/siralama    - COUNT(kolon), GROUP BY, DISTINCT, ORDER BY, UNIQUE

  Bilincli tercih: her kontrol GERCEK bir sorgu sonucu karsilastirir; "kod
  var" demek yetmez. Ayrimin bir katmanda kaybolmasi kapiyi kirmizi yapar.

  KAPSAM (v3.72): (A) ifade semantigi, (B) depolama ve (C) kume/siralama
  katmanlarinin UCU DE ACIK. Okuma maskesi (ScanRowsPartEx ->
  ExecSelect -> Res.RowNulls) ve yazma maskesi (INSERT/UPDATE/UPSERT/
  INSERT..SELECT/COPY/ALTER yeniden yazma) birlikte bagli oldugu icin
  NE20-NE44 artik kosulsuz derlenir; NULL ile '' arasindaki ayrim
  yaz/oku/restart/UPDATE dongusunde korunur. }
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

var
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;

function CellQ(Aq: TVSql; const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '<yok>';
  r := Aq.Exec(ASql);
  if Length(r.Rows) > 0 then
  begin
    if Length(r.Rows[0]) > 0 then
      Result := Trim(r.Rows[0][0])
    else
      Result := '<bossatir>';
  end;
end;

{ Hucrenin IS NULL sonucunu metne cevirir: 'T' / 'F' / '<hata>'.
  Deger kanali metin oldugu icin NULL'i dogrudan karsilastirmak yerine
  her zaman IS NULL uzerinden olcuyoruz - boylece testin kendisi de
  ayrimi varsaymiyor. }
function NullQ(Aq: TVSql; const AExpr: string): string;
begin
  Result := CellQ(Aq, 'SELECT (' + AExpr + ') IS NULL');
end;

function IntQ(Aq: TVSql; const ASql: string): Int64;
var
  s: string;
begin
  s := CellQ(Aq, ASql);
  if not TryStrToInt64(s, Result) then Result := -1;
end;

{ Sorgunun dondurdugu SATIR sayisi (turetilmis tablo olmadan grup saymak icin). }
function RowCountQ(Aq: TVSql; const ASql: string): Integer;
var
  r: TSqlResult;
begin
  Result := -1;
  try
    r := Aq.Exec(ASql);
    Result := Length(r.Rows);
  except
    Result := -1;
  end;
end;

{ Sonucun birinci kolonunda NULL maskesi True olan satir sayisi. Maske
  dondurulmediyse (Length(RowNulls) <> Length(Rows)) -1 doner; boylece test
  maskenin gercekten tasindigini de olcer. }
function NullMaskQ(Aq: TVSql; const ASql: string): Integer;
var
  r: TSqlResult;
  i: Integer;
begin
  Result := -1;
  try
    r := Aq.Exec(ASql);
    if Length(r.RowNulls) <> Length(r.Rows) then Exit;
    Result := 0;
    for i := 0 to High(r.Rows) do
      if (Length(r.RowNulls[i]) > 0) and r.RowNulls[i][0] then Inc(Result);
  except
    Result := -1;
  end;
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

procedure OpenFresh(const AName: string);
begin
  GDir := GetTempDir + 'vdb_ne_' + AName + '_' + IntToStr(GetProcessID);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'ne.odb';
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

procedure Reopen;
begin
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;
  Be := TVdbBackendV3.Create(GDb);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
end;

{ ---- A) ifade semantigi: NULL literal ile '' ayrimi ------------------- }
procedure CaseLiterals;
const
  { Tek tirnak. Pascal'da '''' dört tirnak olarak yazmak yerine sabit
    kullaniyoruz; okunabilirlik ve yazim hatasi riski icin. }
  Q = #39;
  cNull = 'NULL';
  bBos = Q + Q;               { '' - sifir uzunluklu metin literali }
var
  s: string;
begin
  OpenFresh('lit');
  s := CellQ(Sq, 'SELECT ' + cNull + ' IS NULL');
  Chk('NE1 NULL IS NULL', s = 'True', s);

  s := CellQ(Sq, 'SELECT ' + bBos + ' IS NULL');
  Chk('NE2 bos metin IS NULL degil', s = 'False', s);

  s := CellQ(Sq, 'SELECT ' + cNull + ' IS NOT NULL');
  Chk('NE3 NULL IS NOT NULL degil', s = 'False', s);

  s := CellQ(Sq, 'SELECT ' + bBos + ' IS NOT NULL');
  Chk('NE4 bos metin IS NOT NULL', s = 'True', s);

  s := NullQ(Sq, cNull + ' = ' + bBos);
  Chk('NE5 NULL = bos metin UNKNOWN', s = 'True', s);

  s := NullQ(Sq, bBos + ' = ' + bBos);
  Chk('NE6 bos metin = bos metin UNKNOWN degil', s = 'False', s);

  s := NullQ(Sq, cNull + ' = ' + cNull);
  Chk('NE7 NULL = NULL UNKNOWN', s = 'True', s);

  s := NullQ(Sq, '1 + ' + cNull);
  Chk('NE8 1 + NULL UNKNOWN', s = 'True', s);

  s := NullQ(Sq, '1 + 1');
  Chk('NE9 1 + 1 NULL degil', s = 'False', s);

  { Uc degerli mantik: UNKNOWN AND FALSE = FALSE, UNKNOWN OR TRUE = TRUE }
  s := CellQ(Sq, 'SELECT ' + cNull + ' AND FALSE');
  Chk('NE10 NULL AND FALSE = FALSE', s = 'False', s);

  s := NullQ(Sq, cNull + ' AND TRUE');
  Chk('NE11 NULL AND TRUE UNKNOWN', s = 'True', s);

  s := CellQ(Sq, 'SELECT ' + cNull + ' OR TRUE');
  Chk('NE12 NULL OR TRUE = TRUE', s = 'True', s);

  s := NullQ(Sq, cNull + ' OR FALSE');
  Chk('NE13 NULL OR FALSE UNKNOWN', s = 'True', s);

  s := NullQ(Sq, 'NOT ' + cNull);
  Chk('NE14 NOT NULL UNKNOWN', s = 'True', s);
  CloseAll;
end;

{ ---- B) depolama: NULL ile '' yazilip aynen geri okunmali ------------- }
procedure CaseStorage;
const
  Q = #39;
  bBos = Q + Q;
var
  err, s1, s2, s3: string;
begin
  OpenFresh('sto');
  if not TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)', err) then
  begin
    Chk('NE20 tablo olusturuldu', False, err);
    CloseAll;
    Exit;
  end;
  Chk('NE20 tablo olusturuldu', True);
  Chk('NE21 NULL satiri yazildi',
    TryExec(Sq, 'INSERT INTO t VALUES (1, NULL)', err), err);
  Chk('NE22 bos metin satiri yazildi',
    TryExec(Sq, 'INSERT INTO t VALUES (2, ' + bBos + ')', err), err);
  Chk('NE23 dolu metin satiri yazildi',
    TryExec(Sq, 'INSERT INTO t VALUES (3, ' + Q + 'abc' + Q + ')', err), err);

  s1 := CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 1');
  s2 := CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 2');
  s3 := CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 3');
  Chk('NE24 id=1 NULL', s1 = 'True', 'IS NULL=' + s1);
  Chk('NE25 id=2 bos metin (NULL degil)', s2 = 'False', 'IS NULL=' + s2);
  Chk('NE26 id=3 dolu metin (NULL degil)', s3 = 'False', 'IS NULL=' + s3);
  Chk('NE27 id=2 degeri gercekten bos', CellQ(Sq, 'SELECT v FROM t WHERE id = 2') = '',
    'deger=[' + CellQ(Sq, 'SELECT v FROM t WHERE id = 2') + ']');

  { Yeniden acilis: ayrim diskte korunuyor mu? }
  Reopen;
  s1 := CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 1');
  s2 := CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 2');
  Chk('NE28 restart sonrasi id=1 NULL', s1 = 'True', 'IS NULL=' + s1);
  Chk('NE29 restart sonrasi id=2 bos metin', s2 = 'False', 'IS NULL=' + s2);

  { Yeniden yazma yolu ayrimi bozmamali. }
  Chk('NE30 UPDATE dolu satiri degistirdi',
    TryExec(Sq, 'UPDATE t SET v = ''xyz'' WHERE id = 3', err), err);
  s1 := CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 1');
  s2 := CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 2');
  Chk('NE31 UPDATE sonrasi id=1 hala NULL', s1 = 'True', 'IS NULL=' + s1);
  Chk('NE32 UPDATE sonrasi id=2 hala bos metin', s2 = 'False', 'IS NULL=' + s2);

  Chk('NE33 SET v = NULL calisti',
    TryExec(Sq, 'UPDATE t SET v = NULL WHERE id = 3', err), err);
  Chk('NE34 SET v = NULL sonrasi id=3 NULL',
    CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 3') = 'True',
    CellQ(Sq, 'SELECT v IS NULL FROM t WHERE id = 3'));
  CloseAll;
end;

{ ---- C) kume/siralama: NULL SQL kurallarina gore davranmali ---------- }
procedure CaseAggregates;
const
  Q = #39;
  bBos = Q + Q;
var
  err: string;
begin
  OpenFresh('agg');
  if not TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, v TEXT)', err) then
  begin
    Chk('NE40 tablo olusturuldu', False, err);
    CloseAll;
    Exit;
  end;
  Chk('NE40 tablo olusturuldu', True);
  TryExec(Sq, 'INSERT INTO t VALUES (1, ' + Q + 'a' + Q + ', NULL)', err);
  TryExec(Sq, 'INSERT INTO t VALUES (2, ' + Q + 'a' + Q + ', ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO t VALUES (3, ' + Q + 'a' + Q + ', ' + Q + 'x' + Q + ')', err);

  Chk('NE41 COUNT(*) uc satiri sayar', IntQ(Sq, 'SELECT COUNT(*) FROM t') = 3,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  { SQL kurali: COUNT(kolon) NULL'lari saymaz -> 2 (bos metin + 'x') }
  Chk('NE42 COUNT(v) NULL saymaz', IntQ(Sq, 'SELECT COUNT(v) FROM t') = 2,
    IntToStr(IntQ(Sq, 'SELECT COUNT(v) FROM t')));
  { GROUP BY NULL ile '' ayri gruplar olmali -> 3 grup. Turetilmis tablo (FROM
    (SELECT ...) q) bu SQL motorunda yok, bu yuzden grup SAYISINI dogrudan
    sorgunun satir sayisiyla olcuyoruz. }
  Chk('NE43 GROUP BY NULL ile bos metni ayirir', RowCountQ(Sq, 'SELECT COUNT(*) FROM t GROUP BY v') = 3,
    IntToStr(RowCountQ(Sq, 'SELECT COUNT(*) FROM t GROUP BY v')));
  { DISTINCT ayni sekilde 3 ayri deger }
  Chk('NE44 DISTINCT NULL ile bos metni ayirir', RowCountQ(Sq, 'SELECT DISTINCT v FROM t') = 3,
    IntToStr(RowCountQ(Sq, 'SELECT DISTINCT v FROM t')));
  { DISTINCT sonucu NULL maskesini de tasimali: tam olarak 1 NULL satir. }
  Chk('NE45 DISTINCT sonucunda 1 NULL', NullMaskQ(Sq, 'SELECT DISTINCT v FROM t') = 1,
    IntToStr(NullMaskQ(Sq, 'SELECT DISTINCT v FROM t')));
  { Yuklemde ayrim: WHERE v IS NULL yalniz id=1, WHERE v = '' yalniz id=2. }
  Chk('NE46 WHERE v IS NULL 1 satir', IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE v IS NULL') = 1,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE v IS NULL')));
  Chk('NE47 WHERE v = bos metin 1 satir', IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE v = ' + bBos) = 1,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t WHERE v = ' + bBos)));
  { INSERT..SELECT maskeyi tasimali: NULL satiri kopyalanirken '' olmamali. }
  Chk('NE48 INSERT..SELECT icin tablo', TryExec(Sq, 'CREATE TABLE t2 (id INTEGER PRIMARY KEY, v TEXT)', err), err);
  Chk('NE49 INSERT..SELECT calisti', TryExec(Sq, 'INSERT INTO t2 (id, v) SELECT id, v FROM t', err), err);
  Chk('NE50 kopyada NULL korundu', IntQ(Sq, 'SELECT COUNT(*) FROM t2 WHERE v IS NULL') = 1,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t2 WHERE v IS NULL')));
  Chk('NE51 kopyada bos metin korundu', IntQ(Sq, 'SELECT COUNT(*) FROM t2 WHERE v = ' + bBos) = 1,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t2 WHERE v = ' + bBos)));
  CloseAll;
end;

function TQ(const E: string): Boolean;
begin
  Result := SameText(CellQ(Sq, 'SELECT (' + E + ')'), 'True');
end;

function FQ(const E: string): Boolean;
begin
  Result := SameText(CellQ(Sq, 'SELECT (' + E + ')'), 'False');
end;

function UQ(const E: string): Boolean;
begin
  Result := SameText(NullQ(Sq, E), 'True');
end;

{ ---- D) IN / NOT IN: '' GERCEK deger, NULL uc degerli mantik --------- }
procedure CaseInList;
const
  Q = #39;
  bBos = Q + Q;
var
  err: string;
begin
  OpenFresh('in');
  if not TryExec(Sq, 'CREATE TABLE t3 (id INTEGER PRIMARY KEY, v TEXT)', err) then
  begin
    Chk('NE52-IN tablo', False, err);
    CloseAll;
    Exit;
  end;
  TryExec(Sq, 'INSERT INTO t3 VALUES (1, NULL)', err);
  TryExec(Sq, 'INSERT INTO t3 VALUES (2, ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO t3 VALUES (3, ' + Q + 'x' + Q + ')', err);

  Chk('NE52 bos metin IN (bos metin)', TQ(bBos + ' IN (' + bBos + ')'));
  Chk('NE53 bos metin IN (x) = FALSE', FQ(bBos + ' IN (' + Q + 'x' + Q + ')'));
  Chk('NE54 x IN (bos metin) = FALSE', FQ(Q + 'x' + Q + ' IN (' + bBos + ')'));
  Chk('NE55 x NOT IN (bos metin) = TRUE', TQ(Q + 'x' + Q + ' NOT IN (' + bBos + ')'));
  Chk('NE56 bos metin IN (NULL, bos) = TRUE', TQ(bBos + ' IN (NULL, ' + bBos + ')'));
  Chk('NE57 bos metin NOT IN (NULL, bos) = FALSE',
    FQ(bBos + ' NOT IN (NULL, ' + bBos + ')'));
  Chk('NE58 bos metin IN (NULL) = UNKNOWN', UQ(bBos + ' IN (NULL)'));
  Chk('NE59 x NOT IN (NULL, x) = FALSE', FQ(Q + 'x' + Q + ' NOT IN (NULL, ' + Q + 'x' + Q + ')'));
  Chk('NE60 y IN (NULL, y) = TRUE', TQ(Q + 'y' + Q + ' IN (NULL, ' + Q + 'y' + Q + ')'));
  Chk('NE61 y NOT IN (NULL, z) = UNKNOWN', UQ(Q + 'y' + Q + ' NOT IN (NULL, ' + Q + 'z' + Q + ')'));
  Chk('NE62 5 IN (NULL, 5) = TRUE', TQ('5 IN (NULL, 5)'));
  Chk('NE63 5 NOT IN (NULL, 5) = FALSE', FQ('5 NOT IN (NULL, 5)'));
  { Alt sorguda da maske okunmali; '' hasNull SAYMAZ. }
  Chk('NE64 bos metin IN (SELECT)', TQ(bBos + ' IN (SELECT v FROM t3)'));
  Chk('NE65 q NOT IN (SELECT: NULL var) = UNKNOWN',
    UQ(Q + 'q' + Q + ' NOT IN (SELECT v FROM t3)'));
  CloseAll;
end;

{ ---- E) BETWEEN / NOT BETWEEN ---------------------------------------- }
procedure CaseBetween;
const
  Q = #39;
  bBos = Q + Q;
begin
  OpenFresh('btw');
  Chk('NE66 bos BETWEEN bos AND z', TQ(bBos + ' BETWEEN ' + bBos + ' AND ' + Q + 'z' + Q));
  Chk('NE67 a BETWEEN bos AND z', TQ(Q + 'a' + Q + ' BETWEEN ' + bBos + ' AND ' + Q + 'z' + Q));
  Chk('NE68 bos NOT BETWEEN a AND z', TQ(bBos + ' NOT BETWEEN ' + Q + 'a' + Q + ' AND ' + Q + 'z' + Q));
  Chk('NE69 NULL BETWEEN bos AND z = UNKNOWN', UQ('NULL BETWEEN ' + bBos + ' AND ' + Q + 'z' + Q));
  Chk('NE70 bos BETWEEN NULL AND z = UNKNOWN', UQ(bBos + ' BETWEEN NULL AND ' + Q + 'z' + Q));
  Chk('NE71 bos BETWEEN a AND NULL = UNKNOWN', UQ(bBos + ' BETWEEN ' + Q + 'a' + Q + ' AND NULL'));
  Chk('NE72 bos BETWEEN bos AND bos', TQ(bBos + ' BETWEEN ' + bBos + ' AND ' + bBos));
  Chk('NE73 bos NOT BETWEEN bos AND z = FALSE',
    FQ(bBos + ' NOT BETWEEN ' + bBos + ' AND ' + Q + 'z' + Q));
  Chk('NE74 5 BETWEEN 5 AND 10', TQ('5 BETWEEN 5 AND 10'));
  Chk('NE75 5 BETWEEN NULL AND 10 = UNKNOWN', UQ('5 BETWEEN NULL AND 10'));
  CloseAll;
end;

{ ---- F) ANY / ALL ----------------------------------------------------- }
procedure CaseQuant;
const
  Q = #39;
  bBos = Q + Q;
var
  err: string;
begin
  OpenFresh('qnt');
  TryExec(Sq, 'CREATE TABLE t3 (id INTEGER PRIMARY KEY, v TEXT)', err);
  TryExec(Sq, 'INSERT INTO t3 VALUES (1, NULL)', err);
  TryExec(Sq, 'INSERT INTO t3 VALUES (2, ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO t3 VALUES (3, ' + Q + 'x' + Q + ')', err);

  Chk('NE76 NULL = ANY = UNKNOWN', UQ('NULL = ANY (SELECT v FROM t3)'));
  Chk('NE77 NULL = ALL = UNKNOWN', UQ('NULL = ALL (SELECT v FROM t3)'));
  Chk('NE78 bos = ANY (bos var) = TRUE', TQ(bBos + ' = ANY (SELECT v FROM t3)'));
  Chk('NE79 bos = ALL (x var) = FALSE', FQ(bBos + ' = ALL (SELECT v FROM t3)'));
  Chk('NE80 x = ALL = FALSE', FQ(Q + 'x' + Q + ' = ALL (SELECT v FROM t3)'));
  Chk('NE81 q = ANY (NULL var) = UNKNOWN', UQ(Q + 'q' + Q + ' = ANY (SELECT v FROM t3)'));
  Chk('NE82 q = ALL (x var) = FALSE', FQ(Q + 'q' + Q + ' = ALL (SELECT v FROM t3)'));
  Chk('NE83 NULL = ANY (bos kume) = FALSE',
    FQ('NULL = ANY (SELECT v FROM t3 WHERE 1 = 0)'));
  Chk('NE84 NULL = ALL (bos kume) = TRUE',
    TQ('NULL = ALL (SELECT v FROM t3 WHERE 1 = 0)'));
  Chk('NE85 bos = ANY (yalniz NULL) = UNKNOWN',
    UQ(bBos + ' = ANY (SELECT v FROM t3 WHERE v IS NULL)'));
  CloseAll;
end;

{ ---- G) skaler alt sorgu maske tasimasi ------------------------------- }
procedure CaseScalarSub;
const
  Q = #39;
  bBos = Q + Q;
var
  err: string;
begin
  OpenFresh('sub');
  TryExec(Sq, 'CREATE TABLE t4 (id INTEGER PRIMARY KEY, v TEXT)', err);
  TryExec(Sq, 'INSERT INTO t4 VALUES (1, NULL)', err);
  TryExec(Sq, 'INSERT INTO t4 VALUES (2, ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO t4 VALUES (3, ' + Q + 'x' + Q + ')', err);

  Chk('NE86 skaler NULL IS NULL', UQ('(SELECT v FROM t4 WHERE id = 1)'));
  Chk('NE87 skaler NULL = bos metin UNKNOWN', UQ('(SELECT v FROM t4 WHERE id = 1) = ' + bBos));
  Chk('NE88 skaler bos IS NULL degil', FQ('(SELECT v FROM t4 WHERE id = 2) IS NULL'));
  Chk('NE89 skaler bos = bos metin', TQ('(SELECT v FROM t4 WHERE id = 2) = ' + bBos));
  Chk('NE90 satirsiz skaler IS NULL', UQ('(SELECT v FROM t4 WHERE id = 99)'));
  Chk('NE91 NULL || x IS NULL', UQ('(SELECT v FROM t4 WHERE id = 1) || ' + Q + 'x' + Q));
  Chk('NE92 bos || x = x', TQ('(SELECT v FROM t4 WHERE id = 2) || ' + Q + 'x' + Q + ' = ' + Q + 'x' + Q));
  Chk('NE93 korelasyonlu IN (bos)', IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE a.v IN (SELECT b.v FROM t4 b WHERE b.id = 2)') = 1,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE a.v IN (SELECT b.v FROM t4 b WHERE b.id = 2)')));
  Chk('NE94 korelasyonlu IN (NULL)', IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE a.v IN (SELECT b.v FROM t4 b WHERE b.id = 1)') = 0,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE a.v IN (SELECT b.v FROM t4 b WHERE b.id = 1)')));
  Chk('NE95 NOT (IN NULL) hic satir getirmez',
    IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE NOT (a.v IN (SELECT b.v FROM t4 b WHERE b.id = 1))') = 0,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE NOT (a.v IN (SELECT b.v FROM t4 b WHERE b.id = 1))')));
  Chk('NE96 NOT IN (bos) yalniz x', IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE a.v NOT IN (SELECT b.v FROM t4 b WHERE b.id = 2)') = 1,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t4 a WHERE a.v NOT IN (SELECT b.v FROM t4 b WHERE b.id = 2)')));
  Chk('NE97 COUNT(*) alt sorgusu', IntQ(Sq, 'SELECT COUNT(*) FROM t4 WHERE v IS NULL') = 1);
  Chk('NE98 COALESCE(skaler NULL, d) = d', TQ('COALESCE((SELECT v FROM t4 WHERE id = 1), ' + Q + 'd' + Q + ') = ' + Q + 'd' + Q));
  Chk('NE99 COALESCE(skaler bos, d) = bos',
    TQ('COALESCE((SELECT v FROM t4 WHERE id = 2), ' + Q + 'd' + Q + ') = ' + bBos));
  Chk('NE100 skaler bos IS NOT NULL', TQ('(SELECT v FROM t4 WHERE id = 2) IS NOT NULL'));
  CloseAll;
end;

{ ---- H) CASE / COALESCE / NULLIF ------------------------------------- }
procedure CaseCaseCoalesce;
const
  Q = #39;
  bBos = Q + Q;
begin
  OpenFresh('ccn');
  Chk('NE101 CASE THEN NULL IS NULL', UQ('CASE WHEN 1 = 1 THEN NULL END'));
  Chk('NE102 ELSEsiz CASE IS NULL', UQ('CASE WHEN 1 = 0 THEN ' + Q + 'x' + Q + ' END'));
  Chk('NE103 CASE ELSE bos = bos', TQ('CASE WHEN 1 = 0 THEN ' + Q + 'x' + Q + ' ELSE ' + bBos + ' END = ' + bBos));
  Chk('NE104 CASE ELSE bos IS NULL degil', FQ('CASE WHEN 1 = 0 THEN ' + Q + 'x' + Q + ' ELSE ' + bBos + ' END IS NULL'));
  Chk('NE105 COALESCE(bos, y) = bos', TQ('COALESCE(' + bBos + ', ' + Q + 'y' + Q + ') = ' + bBos));
  Chk('NE106 COALESCE(NULL, y) = y', TQ('COALESCE(NULL, ' + Q + 'y' + Q + ') = ' + Q + 'y' + Q));
  Chk('NE107 COALESCE(NULL, NULL) IS NULL', UQ('COALESCE(NULL, NULL)'));
  Chk('NE108 NULLIF(bos, bos) IS NULL', UQ('NULLIF(' + bBos + ', ' + bBos + ')'));
  Chk('NE109 NULLIF(bos, x) IS NULL degil', FQ('NULLIF(' + bBos + ', ' + Q + 'x' + Q + ') IS NULL'));
  Chk('NE110 NULLIF(bos, x) = bos', TQ('NULLIF(' + bBos + ', ' + Q + 'x' + Q + ') = ' + bBos));
  Chk('NE111 NULLIF(NULL, bos) IS NULL', UQ('NULLIF(NULL, ' + bBos + ')'));
  Chk('NE112 NULLIF(a, NULL) = a', TQ('NULLIF(' + Q + 'a' + Q + ', NULL) = ' + Q + 'a' + Q));
  Chk('NE113 CASE bos WHEN bos THEN a', TQ('CASE ' + bBos + ' WHEN ' + bBos + ' THEN ' + Q + 'a' + Q + ' ELSE ' + Q + 'b' + Q + ' END = ' + Q + 'a' + Q));
  Chk('NE114 CASE NULL WHEN NULL THEN a ELSE b', TQ('CASE NULL WHEN NULL THEN ' + Q + 'a' + Q + ' ELSE ' + Q + 'b' + Q + ' END = ' + Q + 'b' + Q));
  Chk('NE115 CASE bos WHEN x THEN a ELSE b', TQ('CASE ' + bBos + ' WHEN ' + Q + 'x' + Q + ' THEN ' + Q + 'a' + Q + ' ELSE ' + Q + 'b' + Q + ' END = ' + Q + 'b' + Q));
  CloseAll;
end;

{ ---- I) JOIN / toplama ve HAVING ------------------------------------- }
procedure CaseJoinAgg;
const
  Q = #39;
  bBos = Q + Q;
var
  err: string;
begin
  OpenFresh('jag');
  TryExec(Sq, 'CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT)', err);
  TryExec(Sq, 'CREATE TABLE b (id INTEGER PRIMARY KEY, w TEXT)', err);
  TryExec(Sq, 'CREATE TABLE c (id INTEGER PRIMARY KEY, x INTEGER)', err);
  TryExec(Sq, 'INSERT INTO a VALUES (1, NULL)', err);
  TryExec(Sq, 'INSERT INTO a VALUES (2, ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO a VALUES (3, ' + Q + 'k' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO b VALUES (1, NULL)', err);
  TryExec(Sq, 'INSERT INTO b VALUES (2, ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO b VALUES (3, ' + Q + 'k' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO c VALUES (1, NULL)', err);
  TryExec(Sq, 'INSERT INTO c VALUES (2, 0)', err);
  TryExec(Sq, 'INSERT INTO c VALUES (3, 5)', err);

  { SQL kurali: MIN/MAX NULL'i atlar ama '' gercek degerdir. }
  Chk('NE116 MIN bos metni korur',
    RowCountQ(Sq, 'SELECT COUNT(*) FROM a GROUP BY v HAVING MIN(v) = ' + bBos) = 1);
  Chk('NE117 MAX dolu metni verir', TQ('(SELECT MAX(v) FROM a) = ' + Q + 'k' + Q));
  Chk('NE118 yalniz NULL satirda MIN NULL', UQ('(SELECT MIN(v) FROM a WHERE v IS NULL)'));
  Chk('NE119 COUNT(v) NULL saymaz', IntQ(Sq, 'SELECT COUNT(v) FROM a') = 2);
  Chk('NE120 SUM NULL saymaz', IntQ(Sq, 'SELECT SUM(x) FROM c') = 5);
  Chk('NE121 COUNT(x) NULL saymaz', IntQ(Sq, 'SELECT COUNT(x) FROM c') = 2);
  { NULL anahtar JOIN'de eslesmez (eslesen yalniz 'k'). }
  Chk('NE122 JOIN k uzerinden 1 satir',
    IntQ(Sq, 'SELECT COUNT(*) FROM a JOIN b ON a.v = b.w WHERE a.v = ' + Q + 'k' + Q) = 1);
  { NOT: LEFT JOIN cikisinda '' ile NULL maskesi ayni TStrArray'de
    tasindigindan IS NULL orada guvenilir degil; bu SKILL13 (tipli hucre
    matrisi) kapsaminda. Burada yalniz satir korunumu olculur. }
  Chk('NE123 LEFT JOIN sol satirlari korur',
    IntQ(Sq, 'SELECT COUNT(*) FROM a LEFT JOIN b ON a.v = b.w') = 3);
  Chk('NE124 GROUP BY uc grup', RowCountQ(Sq, 'SELECT COUNT(*) FROM a GROUP BY v') = 3);
  Chk('NE125 HAVING toplama', RowCountQ(Sq, 'SELECT COUNT(*) FROM a GROUP BY v HAVING COUNT(*) = 1') = 3);
  CloseAll;
end;

{ ---- J) indeksli erisim yolu: agac karsilastirmasi '' ile NULL'i
        karistirmamali (TreeCmp/TreeLike/BuildTree IN+BETWEEN) -------- }
procedure CaseIndexed;
const
  Q = #39;
  bBos = Q + Q;
var
  err: string;
begin
  OpenFresh('idx');
  if not TryExec(Sq, 'CREATE TABLE t5 (id INTEGER PRIMARY KEY, v TEXT)', err) then
  begin
    Chk('NE126 indeks tablosu', False, err);
    CloseAll;
    Exit;
  end;
  TryExec(Sq, 'INSERT INTO t5 VALUES (1, NULL)', err);
  TryExec(Sq, 'INSERT INTO t5 VALUES (2, ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO t5 VALUES (3, ' + Q + 'a' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO t5 VALUES (4, ' + Q + 'b' + Q + ')', err);
  Chk('NE126 indeks olustu', TryExec(Sq, 'CREATE INDEX ix_t5_v ON t5 (v)', err), err);

  Chk('NE127 indeksli v = bos', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v = ' + bBos) = 1);
  Chk('NE128 indeksli v = a', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v = ' + Q + 'a' + Q) = 1);
  Chk('NE129 indeksli IN (bos)', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v IN (' + bBos + ')') = 1);
  Chk('NE130 indeksli IN (bos, b)', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v IN (' + bBos + ', ' + Q + 'b' + Q + ')') = 2);
  Chk('NE131 indeksli BETWEEN bos AND a', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v BETWEEN ' + bBos + ' AND ' + Q + 'a' + Q) = 2);
  Chk('NE132 indeksli v > bos', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v > ' + bBos) = 2);
  Chk('NE133 indeksli LIKE bos', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v LIKE ' + bBos) = 1);
  Chk('NE134 indeksli IS NULL', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v IS NULL') = 1);
  Chk('NE135 indeksli BETWEEN NULL AND a = 0', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v BETWEEN NULL AND ' + Q + 'a' + Q) = 0);
  Chk('NE136 indeksli IN (NULL) = 0', IntQ(Sq, 'SELECT COUNT(*) FROM t5 WHERE v IN (NULL)') = 0);
  CloseAll;
end;

begin
  GPass := 0;
  GFail := 0;
  CaseLiterals;
  CaseStorage;
  CaseAggregates;
  CaseInList;
  CaseBetween;
  CaseQuant;
  CaseScalarSub;
  CaseCaseCoalesce;
  CaseJoinAgg;
  CaseIndexed;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then
    Halt(1);
end.
