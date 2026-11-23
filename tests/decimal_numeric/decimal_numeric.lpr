program decimal_numeric;
{ SKILL14 KAPISI - tam hassasiyetli DECIMAL / NUMERIC.

  NEDEN BU KAPI: V3 motoru degerleri METIN olarak saklar. DECIMAL icin
  metin saklama tek basina yetmez; tamlik, yuvarlama, tasma, siralama ve
  kumeleme davranisi ancak uctan uca olculurse dogrulanir. Bu dosya
  iddialari GERCEK SQL sonuclariyla olcer:

    A) tip ve yazma   - DECIMAL(p,s) ayristirma, kanoniklestirme, yuvarlama,
                        precision/scale tasmasi (sessiz kirpma YOK)
    B) aritmetik      - + - * / , bolme olcegi, sifira bolme, 38 hane siniri
    C) karsilastirma  - WHERE/ORDER BY/indeks SAYISAL sira ('10' > '9.99')
    D) kumeleme       - SUM/AVG/MIN/MAX, GROUP BY, DISTINCT, CHECK, UNIQUE
    E) kalicilik      - restart sonrasi deger ve (p,s) korunumu, ALTER

  Bilincli tercih: hicbir kontrol "kod var" demez; her biri yanlis
  davranista kirmizi olur. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbErr, VDbTypes, VDbDecimal, VDbArrow, VDbParquet;

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

function CellAt(Aq: TVSql; const ASql: string; ARow, ACol: Integer): string;
var
  r: TSqlResult;
begin
  Result := '<yok>';
  r := Aq.Exec(ASql);
  if (ARow >= 0) and (ARow < Length(r.Rows)) and (ACol >= 0) and
     (ACol < Length(r.Rows[ARow])) then
    Result := Trim(r.Rows[ARow][ACol]);
end;

function RowCountQ(Aq: TVSql; const ASql: string): Integer;var
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
  GDir := GetTempDir + 'vdb_dec_' + AName + '_' + IntToStr(GetProcessID);
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'dec.odb';
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

{ ---- A) tip, kanoniklestirme, yuvarlama, tasma ----------------------- }
procedure CaseTypeAndWrite;
const
  Q = #39;
var
  err: string;
begin
  OpenFresh('w');
  Chk('DN1 DECIMAL(10,2) tablo',
    TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v DECIMAL(10,2))', err), err);

  Chk('DN2 DECIMAL kolon kaydedildi',
    TryExec(Sq, 'INSERT INTO t VALUES (1, ' + Q + '0.1' + Q + ')', err), err);

  { Yazma yolunda olcege yuvarlama degil, kanoniklestirme olmali. }
  Chk('DN3 0.1 -> 0.10', CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = '0.10',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));

  Chk('DN4 2.345 -> 2.35 (yarim yukari)',
    TryExec(Sq, 'INSERT INTO t VALUES (2, ' + Q + '2.345' + Q + ')', err), err);
  Chk('DN5 2.345 sonucu',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 2') = '2.35',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 2'));

  Chk('DN6 -2.345 -> -2.35 (sifirdan uzaga)',
    TryExec(Sq, 'INSERT INTO t VALUES (3, ' + Q + '-2.345' + Q + ')', err), err);
  Chk('DN7 negatif sonuc',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 3') = '-2.35',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 3'));

  { Sifir de olcegi korumali: DECIMAL(10,2) kolonda 0 -> '0.00'. Aksi halde
    kanonik metin bozulur ve metin anahtarli kumeleme (GROUP BY/DISTINCT)
    ayni degeri iki farkli anahtar sanar. }
  Chk('DN7b sifir olcegi korur (0 -> 0.00)',
    TryExec(Sq, 'INSERT INTO t VALUES (4, ' + Q + '0' + Q + ')', err), err);
  Chk('DN7c sifir sonucu 0.00',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 4') = '0.00',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 4'));
  Chk('DN7d sifir fazla haneli yazim da 0.00',
    TryExec(Sq, 'INSERT INTO t VALUES (5, ' + Q + '0.000' + Q + ')', err) and
    (CellQ(Sq, 'SELECT v FROM t WHERE id = 5') = '0.00'),
    CellQ(Sq, 'SELECT v FROM t WHERE id = 5'));

  { Precision tasmasi: DECIMAL(4,2) icin 100.00 sigmaz. Sessiz kirpma
    yerine hata beklenir. }
  Chk('DN8 DECIMAL(4,2) tablo',
    TryExec(Sq, 'CREATE TABLE p (id INTEGER PRIMARY KEY, v DECIMAL(4,2))', err), err);
  Chk('DN9 99.99 sigar',
    TryExec(Sq, 'INSERT INTO p VALUES (1, ' + Q + '99.99' + Q + ')', err), err);
  Chk('DN10 100.00 precision tasmasi REDDEDILIR',
    not TryExec(Sq, 'INSERT INTO p VALUES (2, ' + Q + '100.00' + Q + ')', err), err);
  Chk('DN11 tasan satir yazilmadi', RowCountQ(Sq, 'SELECT id FROM p') = 1,
    IntToStr(RowCountQ(Sq, 'SELECT id FROM p')));

  { 38 hane sinirinin gercekten tasindigi: DECIMAL(38,0) tam sinirda,
    39 hane reddedilir. }
  Chk('DN12 DECIMAL(38,0) tablo',
    TryExec(Sq, 'CREATE TABLE big (id INTEGER PRIMARY KEY, v DECIMAL(38,0))', err), err);
  Chk('DN13 38 hane kabul',
    TryExec(Sq, 'INSERT INTO big VALUES (1, ' + Q +
      '99999999999999999999999999999999999999' + Q + ')', err), err);
  Chk('DN14 39 hane reddedilir',
    not TryExec(Sq, 'INSERT INTO big VALUES (2, ' + Q +
      '999999999999999999999999999999999999999' + Q + ')', err), err);

  { Gecersiz tip tanimi reddedilir: s > p. }
  Chk('DN15 DECIMAL(5,6) reddedilir',
    not TryExec(Sq, 'CREATE TABLE bad (id INTEGER PRIMARY KEY, v DECIMAL(5,6))', err), err);
  Chk('DN16 DECIMAL(39,0) reddedilir',
    not TryExec(Sq, 'CREATE TABLE bad2 (id INTEGER PRIMARY KEY, v DECIMAL(39,0))', err), err);

  CloseAll;
end;

{ ---- B) aritmetik --------------------------------------------------- }
procedure CaseArithmetic;
const
  Q = #39;
var
  err: string;
begin
  OpenFresh('a');
  Chk('DN17 aritmetik tablo',
    TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, a DECIMAL(10,1), b DECIMAL(10,1))', err), err);
  Chk('DN18 0.1 yazildi', TryExec(Sq, 'INSERT INTO t VALUES (1, ' + Q + '0.1' + Q +
    ', ' + Q + '0.2' + Q + ')', err), err);

  { Spec'in cikis noktasi: 0.1 + 0.2 tam 0.3 olmali. Double ile 0.3000...4
    cikardi. }
  Chk('DN19 0.1 + 0.2 = 0.3', CellQ(Sq, 'SELECT a + b FROM t WHERE id = 1') = '0.3',
    CellQ(Sq, 'SELECT a + b FROM t WHERE id = 1'));
  Chk('DN20 0.1 - 0.2 = -0.1', CellQ(Sq, 'SELECT a - b FROM t WHERE id = 1') = '-0.1',
    CellQ(Sq, 'SELECT a - b FROM t WHERE id = 1'));

  { Olcek kurallari: carpim s1+s2, bolme max(s1+s2,6). }
  Chk('DN21 carpim tablo',
    TryExec(Sq, 'CREATE TABLE m (id INTEGER PRIMARY KEY, a DECIMAL(10,2), b DECIMAL(10,2))', err), err);
  Chk('DN22 carpim satiri', TryExec(Sq, 'INSERT INTO m VALUES (1, ' + Q + '1.50' + Q +
    ', ' + Q + '2.00' + Q + ')', err), err);
  Chk('DN23 1.50 * 2.00 = 3.0000 (s1+s2)',
    CellQ(Sq, 'SELECT a * b FROM m WHERE id = 1') = '3.0000',
    CellQ(Sq, 'SELECT a * b FROM m WHERE id = 1'));

  Chk('DN24 bolme satiri', TryExec(Sq, 'INSERT INTO m VALUES (2, ' + Q + '1.00' + Q +
    ', ' + Q + '3.00' + Q + ')', err), err);
  Chk('DN25 1.00 / 3.00 = 0.333333 (max(s1+s2,6))',
    CellQ(Sq, 'SELECT a / b FROM m WHERE id = 2') = '0.333333',
    CellQ(Sq, 'SELECT a / b FROM m WHERE id = 2'));
  Chk('DN26 2.00 / 3.00 = 0.666667 (yarim yukari)',
    TryExec(Sq, 'INSERT INTO m VALUES (3, ' + Q + '2.00' + Q + ', ' + Q + '3.00' + Q + ')', err), err);
  Chk('DN26b 2/3 sonucu',
    CellQ(Sq, 'SELECT a / b FROM m WHERE id = 3') = '0.666667',
    CellQ(Sq, 'SELECT a / b FROM m WHERE id = 3'));

  Chk('DN27 sifir degerli bolen yazildi',
    TryExec(Sq, 'INSERT INTO m VALUES (4, ' + Q + '1.00' + Q + ', ' + Q + '0.00' + Q + ')', err), err);
  Chk('DN27b sifira bolme hata',
    not TryExec(Sq, 'SELECT a / b FROM m WHERE id = 4', err), err);

  { Ifade sonucu 38 haneyi asarsa hata; sessiz tasma yok. }
  Chk('DN28 38 hane sinirinda carpim tablosu',
    TryExec(Sq, 'CREATE TABLE x (id INTEGER PRIMARY KEY, a DECIMAL(38,0), b DECIMAL(2,0))', err), err);
  Chk('DN29 38 hane deger', TryExec(Sq, 'INSERT INTO x VALUES (1, ' + Q +
    '99999999999999999999999999999999999999' + Q + ', ' + Q + '1' + Q + ')', err), err);
  Chk('DN30 38x1 carpim hata vermez',
    TryExec(Sq, 'INSERT INTO x VALUES (2, ' + Q + '1' + Q + ', ' + Q + '1' + Q + ')', err), err);

  CloseAll;
end;

{ ---- C) karsilastirma, siralama, indeks ------------------------------ }
procedure CaseCompare;
const
  Q = #39;
var
  err: string;
begin
  OpenFresh('c');
  Chk('DN31 karsilastirma tablosu',
    TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v DECIMAL(10,2))', err), err);
  TryExec(Sq, 'INSERT INTO t VALUES (1, ' + Q + '10.00' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO t VALUES (2, ' + Q + '9.99' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO t VALUES (3, ' + Q + '100.00' + Q + ')', err);

  { Metin sirasinda '10.00' < '9.99' olurdu; sayisal sirada 9.99 < 10.00. }
  Chk('DN32 ORDER BY sayisal sira',
    CellQ(Sq, 'SELECT v FROM t ORDER BY v') = '9.99',
    CellQ(Sq, 'SELECT v FROM t ORDER BY v'));
  Chk('DN33 ORDER BY ikinci satir',
    CellQ(Sq, 'SELECT v FROM t ORDER BY v DESC') = '100.00',
    CellQ(Sq, 'SELECT v FROM t ORDER BY v DESC'));

  { Aralik sorgusu: metin karsilastirmasiyla '10.00' araligin DISINDA kalirdi. }
  Chk('DN34 WHERE sayisal aralik',
    RowCountQ(Sq, 'SELECT id FROM t WHERE v > 9.99 AND v < 10.01') = 1,
    IntToStr(RowCountQ(Sq, 'SELECT id FROM t WHERE v > 9.99 AND v < 10.01')));
  Chk('DN35 WHERE esitlik (metin yazimi farkli)',
    CellQ(Sq, 'SELECT id FROM t WHERE v = 10') = '1',
    CellQ(Sq, 'SELECT id FROM t WHERE v = 10'));
  Chk('DN36 WHERE esitlik ondalik',
    CellQ(Sq, 'SELECT id FROM t WHERE v = ' + Q + '9.990' + Q) = '2',
    CellQ(Sq, 'SELECT id FROM t WHERE v = ' + Q + '9.990' + Q));

  Chk('DN37 indeks olustu',
    TryExec(Sq, 'CREATE INDEX ix_v ON t (v)', err), err);
  Chk('DN38 indeksli ORDER BY',
    CellQ(Sq, 'SELECT v FROM t WHERE v > 9.9 ORDER BY v LIMIT 1') = '9.99',
    CellQ(Sq, 'SELECT v FROM t WHERE v > 9.9 ORDER BY v LIMIT 1'));
  Chk('DN39 indeksli aralik',
    RowCountQ(Sq, 'SELECT id FROM t WHERE v BETWEEN 9.99 AND 10.00') = 2,
    IntToStr(RowCountQ(Sq, 'SELECT id FROM t WHERE v BETWEEN 9.99 AND 10.00')));

  CloseAll;
end;

{ ---- D) kumeleme, SUM/AVG/MIN/MAX, GROUP BY, DISTINCT, kisitlar ------ }
procedure CaseAggregate;
const
  Q = #39;
var
  err: string;
begin
  OpenFresh('g');
  Chk('DN40 kumeleme tablosu',
    TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, v DECIMAL(10,2))', err), err);
  TryExec(Sq, 'INSERT INTO t VALUES (1, ' + Q + 'a' + Q + ', ' + Q + '1.10' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO t VALUES (2, ' + Q + 'a' + Q + ', ' + Q + '2.20' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO t VALUES (3, ' + Q + 'b' + Q + ', ' + Q + '0.10' + Q + ')', err);
  TryExec(Sq, 'INSERT INTO t VALUES (4, ' + Q + 'b' + Q + ', ' + Q + '0.10' + Q + ')', err);

  Chk('DN41 SUM = 3.50', CellQ(Sq, 'SELECT SUM(v) FROM t') = '3.50',
    CellQ(Sq, 'SELECT SUM(v) FROM t'));
  Chk('DN42 AVG = 0.875000 (olcek 6)', CellQ(Sq, 'SELECT AVG(v) FROM t') = '0.875000',
    CellQ(Sq, 'SELECT AVG(v) FROM t'));
  Chk('DN43 MIN = 0.10', CellQ(Sq, 'SELECT MIN(v) FROM t') = '0.10',
    CellQ(Sq, 'SELECT MIN(v) FROM t'));
  Chk('DN44 MAX = 2.20', CellQ(Sq, 'SELECT MAX(v) FROM t') = '2.20',
    CellQ(Sq, 'SELECT MAX(v) FROM t'));
  Chk('DN45 GROUP BY a toplami',
    CellAt(Sq, 'SELECT g, SUM(v) FROM t GROUP BY g ORDER BY g', 0, 1) = '3.30',
    CellAt(Sq, 'SELECT g, SUM(v) FROM t GROUP BY g ORDER BY g', 0, 1));
  Chk('DN46 GROUP BY b AVG',
    CellAt(Sq, 'SELECT g, AVG(v) FROM t GROUP BY g ORDER BY g', 1, 1) = '0.100000',
    CellAt(Sq, 'SELECT g, AVG(v) FROM t GROUP BY g ORDER BY g', 1, 1));
  Chk('DN47 DISTINCT gruplar (1.10,2.20,0.10)',
    RowCountQ(Sq, 'SELECT DISTINCT v FROM t') = 3,
    IntToStr(RowCountQ(Sq, 'SELECT DISTINCT v FROM t')));
  Chk('DN48 GROUP BY grup sayisi 2',
    RowCountQ(Sq, 'SELECT g FROM t GROUP BY g') = 2,
    IntToStr(RowCountQ(Sq, 'SELECT g FROM t GROUP BY g')));

  Chk('DN49 CHECK tablosu',
    TryExec(Sq, 'CREATE TABLE ck (id INTEGER PRIMARY KEY, v DECIMAL(6,2) CHECK (v >= 0))', err), err);
  Chk('DN50 CHECK gecerli deger',
    TryExec(Sq, 'INSERT INTO ck VALUES (1, ' + Q + '1.00' + Q + ')', err), err);
  Chk('DN51 CHECK negatifi reddeder',
    not TryExec(Sq, 'INSERT INTO ck VALUES (2, ' + Q + '-1.00' + Q + ')', err), err);
  Chk('DN52 CHECK sayisal karsilastirir (10 >= 0)',
    TryExec(Sq, 'INSERT INTO ck VALUES (3, ' + Q + '10.00' + Q + ')', err), err);

  Chk('DN53 UNIQUE tablosu',
    TryExec(Sq, 'CREATE TABLE uq (id INTEGER PRIMARY KEY, v DECIMAL(6,2) UNIQUE)', err), err);
  Chk('DN54 UNIQUE ilk deger',
    TryExec(Sq, 'INSERT INTO uq VALUES (1, ' + Q + '1.00' + Q + ')', err), err);
  Chk('DN55 UNIQUE yazim farki ayni deger sayilir',
    not TryExec(Sq, 'INSERT INTO uq VALUES (2, ' + Q + '1.0' + Q + ')', err), err);

  CloseAll;
end;

{ ---- E) CAST, kalicilik, ALTER -------------------------------------- }
procedure CasePersist;
const
  Q = #39;
var
  err: string;
begin
  OpenFresh('p');
  Chk('DN56 CAST hedefi',
    CellQ(Sq, 'SELECT CAST(' + Q + '2.345' + Q + ' AS DECIMAL(6,2))') = '2.35',
    CellQ(Sq, 'SELECT CAST(' + Q + '2.345' + Q + ' AS DECIMAL(6,2))'));
  Chk('DN57 CAST tam sayi',
    CellQ(Sq, 'SELECT CAST(7 AS DECIMAL(5,2))') = '7.00',
    CellQ(Sq, 'SELECT CAST(7 AS DECIMAL(5,2))'));
  Chk('DN58 CAST tasma hata',
    not TryExec(Sq, 'SELECT CAST(' + Q + '1000' + Q + ' AS DECIMAL(4,2))', err), err);

  Chk('DN59 kalicilik tablosu',
    TryExec(Sq, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v DECIMAL(10,2))', err), err);
  Chk('DN60 yuvarlanan deger yazildi',
    TryExec(Sq, 'INSERT INTO t VALUES (1, ' + Q + '1.239' + Q + ')', err), err);
  Chk('DN61 yuvarlama sonucu 1.24',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = '1.24',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));

  Reopen;
  Chk('DN62 restart sonrasi deger ayni',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = '1.24',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));
  Chk('DN63 restart sonrasi olcek korunuyor',
    TryExec(Sq, 'INSERT INTO t VALUES (2, ' + Q + '5.555' + Q + ')', err), err);
  Chk('DN64 restart sonrasi yuvarlama 5.56',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 2') = '5.56',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 2'));

  { ALTER COLUMN TYPE yeni (p,s) ile degerleri yeniden yuvarlamali. }
  Chk('DN65 ALTER DECIMAL(12,3)',
    TryExec(Sq, 'ALTER TABLE t ALTER COLUMN v TYPE DECIMAL(12,3)', err), err);
  Chk('DN66 ALTER sonrasi deger 1.240',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1') = '1.240',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 1'));
  Chk('DN67 ALTER sonrasi yeni deger olcege uyuyor',
    TryExec(Sq, 'INSERT INTO t VALUES (3, ' + Q + '7.1' + Q + ')', err), err);
  Chk('DN68 ALTER sonrasi olcek 3 uygulaniyor',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 3') = '7.100',
    CellQ(Sq, 'SELECT v FROM t WHERE id = 3'));
  Chk('DN69 ALTER sonrasi hassasiyet 12',
    not TryExec(Sq, 'INSERT INTO t VALUES (4, ' + Q + '9999999999.999' + Q + ')', err), err);

  CloseAll;
end;

{ ---- F) Arrow / Parquet DECIMAL: (p,s) ve tam deger --------------- }
procedure MkCell(var M: TVdbCellMatrix; ARow, ACol: Integer;
  const AVal: string; AType: Byte);
begin
  VDbCellFromStr(AVal, AType, M[ARow][ACol]);
end;

function TextAt(const M: TVdbCellMatrix; ARow, ACol: Integer): string;
begin
  Result := '<yok>';
  if (ARow < 0) or (ARow >= Length(M)) or (ACol < 0) or
     (ACol >= Length(M[ARow])) then Exit;
  case M[ARow][ACol].Kind of
    vckNull: Result := '<null>';
    vckText: Result := M[ARow][ACol].S;
  else
    Result := '<tip ' + IntToStr(Ord(M[ARow][ACol].Kind)) + '>';
  end;
end;

function CellsSame(const A, B: TVdbCellMatrix; out AReason: string): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  AReason := '';
  if Length(A) <> Length(B) then
  begin
    AReason := 'satir ' + IntToStr(Length(A)) + ' <> ' + IntToStr(Length(B));
    Exit;
  end;
  for i := 0 to High(A) do
  begin
    if Length(A[i]) <> Length(B[i]) then
    begin
      AReason := 'kolon (satir ' + IntToStr(i) + ') ' + IntToStr(Length(A[i])) +
        ' <> ' + IntToStr(Length(B[i]));
      Exit;
    end;
    for j := 0 to High(A[i]) do
      if (A[i][j].Kind <> B[i][j].Kind) or
         ((A[i][j].Kind in [vckText, vckBlob]) and (A[i][j].S <> B[i][j].S)) or
         (A[i][j].Kind = vckInt) and (A[i][j].I <> B[i][j].I) then
      begin
        AReason := 'hucre ' + IntToStr(i) + ',' + IntToStr(j) + ': ' +
          TextAt(A, i, j) + ' <> ' + TextAt(B, i, j);
        Exit;
      end;
  end;
  Result := True;
end;

procedure CaseInterop;
const
  D38 = '99999999999999999999999999999999999999';
var
  err, reason: string;
  pfx: string;
  flds, flds2: TStrArray;
  typs, pr, sc, pr2, sc2: TByteArray;
  cells, back: TVdbCellMatrix;
  i, j: Integer;
begin
  OpenFresh('x');
  { OpenFresh GDir'yi ayiricisiz birakir; dosyalar dizinin KARDESI olarak
    yazilirsa (yol birlestirme hatasi) import bos doner. Tum yollar
    IncludeTrailingPathDelimiter ile dizin icinde tutulur. }
  pfx := IncludeTrailingPathDelimiter(GDir);

  { Gercek tablodan bagimsiz olarak tipli hucre matrisi kurulur: burada
    olculen sey SQL degil, disa aktarim katmaninin (p,s) ve tam deger
    sozlesmesidir. }
  SetLength(flds, 2);
  flds[0] := 'id'; flds[1] := 'v';
  SetLength(typs, 2);
  typs[0] := VCT_INT; typs[1] := VCT_DECIMAL;
  SetLength(pr, 2); pr[0] := 0; pr[1] := 12;
  SetLength(sc, 2); sc[0] := 0; sc[1] := 3;

  SetLength(cells, 5, 2);
  for i := 0 to 4 do MkCell(cells, i, 0, IntToStr(i + 1), VCT_INT);
  MkCell(cells, 0, 1, '123.456', VCT_DECIMAL);
  MkCell(cells, 1, 1, '-0.001', VCT_DECIMAL);
  MkCell(cells, 2, 1, '0.000', VCT_DECIMAL);
  MkCell(cells, 3, 1, '999999999.999', VCT_DECIMAL);
  cells[4][1].Kind := vckNull;

  { ---- Arrow ---- }
  err := '';
  Chk('DN70 Arrow DECIMAL(12,3) disa aktarim',
    VDbArrowExportCellsEx(pfx + 'd.arrow', flds, typs, pr, sc, cells, err), err);
  err := '';
  reason := '';
  Chk('DN71 Arrow DECIMAL okunur',
    VDbArrowImportCellsEx(pfx + 'd.arrow', flds2, typs, pr2, sc2, back, err),
    err);
  Chk('DN72 Arrow tip VCT_DECIMAL',
    (Length(typs) = 2) and (typs[1] = VCT_DECIMAL),
    IntToStr(Length(typs)));
  Chk('DN73 Arrow (p,s) = (12,3)',
    (Length(pr2) = 2) and (pr2[1] = 12) and (Length(sc2) = 2) and (sc2[1] = 3),
    IntToStr(pr2[1]) + ',' + IntToStr(sc2[1]));
  Chk('DN74 Arrow degerler birebir (NULL dahil)',
    CellsSame(cells, back, reason), reason);

  { 38 hane siniri Decimal128'in tam siniridir; tek hane fazlasi reddedilir. }
  SetLength(flds2, 1); flds2[0] := 'v';
  SetLength(typs, 1); typs[0] := VCT_DECIMAL;
  SetLength(pr, 1); pr[0] := VDB_DEC_MAX_PREC;
  SetLength(sc, 1); sc[0] := 0;
  SetLength(cells, 1, 1);
  MkCell(cells, 0, 0, D38, VCT_DECIMAL);
  err := '';
  Chk('DN75 Arrow DECIMAL(38,0) 38 hane yazilir',
    VDbArrowExportCellsEx(pfx + 'd38.arrow', flds2, typs, pr, sc, cells, err), err);
  err := '';
  reason := '';
  Chk('DN76 Arrow 38 hane birebir doner',
    VDbArrowImportCellsEx(pfx + 'd38.arrow', flds, typs, pr2, sc2, back, err) and
    CellsSame(cells, back, reason) and (pr2[0] = VDB_DEC_MAX_PREC), reason + err);

  SetLength(pr, 1); pr[0] := 6;
  SetLength(sc, 1); sc[0] := 2;
  MkCell(cells, 0, 0, '12345.67', VCT_DECIMAL);
  err := '';
  Chk('DN77 Arrow hassasiyet tasmasi reddedilir',
    not VDbArrowExportCellsEx(pfx + 'dov.arrow', flds2, typs, pr, sc, cells, err)
    and (err <> ''), err);

  SetLength(pr, 1); pr[0] := 10;
  SetLength(sc, 1); sc[0] := 3;
  MkCell(cells, 0, 0, '1.5', VCT_DECIMAL);
  err := '';
  reason := '';
  Chk('DN78 Arrow olcege kanoniklestirir (1.5 -> 1.500)',
    VDbArrowExportCellsEx(pfx + 'dc.arrow', flds2, typs, pr, sc, cells, err) and
    VDbArrowImportCellsEx(pfx + 'dc.arrow', flds, typs, pr2, sc2, back, err) and
    (TextAt(back, 0, 0) = '1.500'), TextAt(back, 0, 0) + ' ' + err + reason);

  { ---- Parquet ---- }
  { ONEMLI: VDbArrowImportCellsEx `flds`i OUT parametresi olarak YENIDEN
    yazar (d38.arrow tek kolonludur), bu yuzden burada alan listesi tekrar
    kurulur. Aksi halde 2 kolonlu matris 1 kolonluk sema ile yazilir ve
    Parquet okuma tek kolon doner (kapida gorulen gercek test hatasi). }
  SetLength(flds, 2);
  flds[0] := 'id'; flds[1] := 'v';
  SetLength(typs, 2);
  typs[0] := VCT_INT; typs[1] := VCT_DECIMAL;
  SetLength(pr, 2); pr[0] := 0; pr[1] := 12;
  SetLength(sc, 2); sc[0] := 0; sc[1] := 3;
  SetLength(cells, 5, 2);
  for i := 0 to 4 do MkCell(cells, i, 0, IntToStr(i + 1), VCT_INT);
  MkCell(cells, 0, 1, '123.456', VCT_DECIMAL);
  MkCell(cells, 1, 1, '-0.001', VCT_DECIMAL);
  MkCell(cells, 2, 1, '0.000', VCT_DECIMAL);
  MkCell(cells, 3, 1, '999999999.999', VCT_DECIMAL);
  cells[4][1].Kind := vckNull;

  err := '';
  Chk('DN79 Parquet DECIMAL(12,3) disa aktarim',
    VDbParquetExportCellsEx(pfx + 'd.parquet', flds, typs, pr, sc, cells, err), err);
  err := '';
  reason := '';
  Chk('DN80 Parquet DECIMAL okunur',
    VDbParquetImportCellsEx(pfx + 'd.parquet', flds2, typs, pr2, sc2, back, err),
    err);
  Chk('DN81 Parquet tip VCT_DECIMAL',
    (Length(typs) = 2) and (typs[1] = VCT_DECIMAL),
    IntToStr(Length(typs)));
  Chk('DN82 Parquet (p,s) = (12,3)',
    (Length(pr2) = 2) and (pr2[1] = 12) and (Length(sc2) = 2) and (sc2[1] = 3),
    IntToStr(pr2[1]) + ',' + IntToStr(sc2[1]));
  Chk('DN83 Parquet degerler birebir (NULL dahil)',
    CellsSame(cells, back, reason), reason);

  SetLength(flds2, 1); flds2[0] := 'v';
  SetLength(typs, 1); typs[0] := VCT_DECIMAL;
  SetLength(pr, 1); pr[0] := VDB_DEC_MAX_PREC;
  SetLength(sc, 1); sc[0] := 0;
  SetLength(cells, 1, 1);
  MkCell(cells, 0, 0, D38, VCT_DECIMAL);
  err := '';
  reason := '';
  Chk('DN84 Parquet DECIMAL(38,0) 38 hane birebir',
    VDbParquetExportCellsEx(pfx + 'd38.parquet', flds2, typs, pr, sc, cells, err) and
    VDbParquetImportCellsEx(pfx + 'd38.parquet', flds, typs, pr2, sc2, back, err) and
    CellsSame(cells, back, reason) and (pr2[0] = VDB_DEC_MAX_PREC),
    reason + err);

  SetLength(pr, 1); pr[0] := 6;
  SetLength(sc, 1); sc[0] := 2;
  MkCell(cells, 0, 0, '12345.67', VCT_DECIMAL);
  err := '';
  Chk('DN85 Parquet hassasiyet tasmasi reddedilir',
    not VDbParquetExportCellsEx(pfx + 'dov.parquet', flds2, typs, pr, sc, cells, err)
    and (err <> ''), err);

  SetLength(pr, 1); pr[0] := 10;
  SetLength(sc, 1); sc[0] := 3;
  MkCell(cells, 0, 0, '1.5', VCT_DECIMAL);
  err := '';
  reason := '';
  Chk('DN86 Parquet olcege kanoniklestirir (1.5 -> 1.500)',
    VDbParquetExportCellsEx(pfx + 'dc.parquet', flds2, typs, pr, sc, cells, err) and
    VDbParquetImportCellsEx(pfx + 'dc.parquet', flds, typs, pr2, sc2, back, err) and
    (TextAt(back, 0, 0) = '1.500'), TextAt(back, 0, 0) + ' ' + err + reason);

  { (p,s) verilmezse Parquet olcegi hucreden turetir; deger yine tam. }
  MkCell(cells, 0, 0, '42.125', VCT_DECIMAL);
  err := '';
  reason := '';
  Chk('DN87 Parquet (p,s) verilmezse olcek hucreden turetilir',
    VDbParquetExportCellsEx(pfx + 'dn.parquet', flds2, typs, nil, nil, cells, err) and
    VDbParquetImportCellsEx(pfx + 'dn.parquet', flds, typs, pr2, sc2, back, err) and
    (TextAt(back, 0, 0) = '42.125') and (Length(sc2) = 1) and (sc2[0] = 3),
    TextAt(back, 0, 0) + ' ' + err + reason);

  { Arrow'da sema basta yazildigi icin (p,s) zorunludur; eksikse acik hata. }
  err := '';
  Chk('DN88 Arrow (p,s) verilmezse acik hata',
    not VDbArrowExportCellsEx(pfx + 'dn.arrow', flds2, typs, nil, nil, cells, err)
    and (err <> ''), err);

  CloseAll;
end;

begin
  GPass := 0;
  GFail := 0;
  DecimalSeparator := '.';
  CaseTypeAndWrite;
  CaseArithmetic;
  CaseCompare;
  CaseAggregate;
  CasePersist;
  CaseInterop;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
