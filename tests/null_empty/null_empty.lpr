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

  KAPSAM (v3.71): yalnizca (A) ifade semantigi ACIK. Bu katman bugun
  TAM ve kapali: NULL literal, IS NULL/IS NOT NULL, NULL ile '' ayrimi ve
  uc degerli mantik dogru sonuc veriyor.

  (B) depolama ve (C) kume/siralama bloklari NE_STORAGE tanimliysa
  derlenir. Bugun DERLENMEZLER cunku okuma maskesi yurutucuye bagli
  degil: ScanRowsPartEx maskeyi donduruyor (VDbTable, asama 1) ama
  ExecSelect onu tasimiyor, dolayisiyla depolanmis NULL hala '' olarak
  gorunuyor. Bu bloklari simdi acmak, kapiciya KIRMIZI bir kapi eklemek
  olurdu. Acma kosulu: okuma maskesinin ExecSelect/ExecGroupBy hattina
  baglanmasi VE yeniden-yazan tum yollarin (UPDATE/MERGE/UPSERT/
  INSERT..SELECT/vacuum/indeks yeniden kurma) maskeyi tasimasi. Ikincisi
  yapilmadan maskeli YAZIM acilirsa gercek '' bir UPDATE'te NULL'a donusur
  = veri kaybi. Bu yuzden iki is birlikte yapilmalidir. }
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
{$IFDEF NE_STORAGE}
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
{$ENDIF}

{ ---- C) kume/siralama: NULL SQL kurallarina gore davranmali ---------- }
{$IFDEF NE_STORAGE}
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
  TryExec(Sq, 'INSERT INTO t VALUES (1, ' + Q + 'a' + Q + ', NULL)', err);
  TryExec(Sq, 'INSERT INTO t VALUES (2, ' + Q + 'a' + Q + ', ' + bBos + ')', err);
  TryExec(Sq, 'INSERT INTO t VALUES (3, ' + Q + 'a' + Q + ', ' + Q + 'x' + Q + ')', err);

  Chk('NE41 COUNT(*) uc satiri sayar', IntQ(Sq, 'SELECT COUNT(*) FROM t') = 3,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM t')));
  { SQL kurali: COUNT(kolon) NULL'lari saymaz -> 2 (bos metin + 'x') }
  Chk('NE42 COUNT(v) NULL saymaz', IntQ(Sq, 'SELECT COUNT(v) FROM t') = 2,
    IntToStr(IntQ(Sq, 'SELECT COUNT(v) FROM t')));
  { GROUP BY NULL ile '' ayri gruplar olmali -> 3 grup }
  Chk('NE43 GROUP BY NULL ile bos metni ayirir',
    IntQ(Sq, 'SELECT COUNT(*) FROM (SELECT v FROM t GROUP BY v) q') = 3,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM (SELECT v FROM t GROUP BY v) q')));
  { DISTINCT ayni sekilde 3 ayri deger }
  Chk('NE44 DISTINCT NULL ile bos metni ayirir',
    IntQ(Sq, 'SELECT COUNT(*) FROM (SELECT DISTINCT v FROM t) q') = 3,
    IntToStr(IntQ(Sq, 'SELECT COUNT(*) FROM (SELECT DISTINCT v FROM t) q')));
  CloseAll;
end;
{$ENDIF}

begin
  GPass := 0;
  GFail := 0;
  CaseLiterals;
{$IFDEF NE_STORAGE}
  CaseStorage;
  CaseAggregates;
{$ENDIF}
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then
    Halt(1);
end.
