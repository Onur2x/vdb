program aggchk;
{ D-Y1/Y2: SUM/AVG hassasiyet kapisi.

  Dogrulananlar:
    * 2^53 (9007199254740992) ustunde INTEGER SUM tam Int64 olmali.
    * Cok satirli AVG: Int64 toplam / sayim (1e15 olcekli degerler).
    * Karisik isaretli toplam (buyuk pozitif + buyuk negatif) tam olmali.
    * FLOAT SUM/AVG: Double + Kahan; cikti bicimi VDbFloatToStr ile ayni.
    * Hizli akis (WHERE'siz), genel yol (WHERE'li), GROUP BY ve pencere
      yollari AYNI degeri uretmeli.

  Beklenen degerler elle hesaplandi; B = 2^53 + 1 = 9007199254740993.
  Buyuk orneklemlerde (flt, avgbig) eski Double birikim belirgin bicimde
  farkli sonuc verirdi. }
{$mode delphi}{$H+}
uses
  SysUtils, Classes,
  VDbCore, VDbTypes, VDbTable, VDbSql;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  dir: string;
  R: TSqlResult;
  nBad, nOk: Integer;
  i: Integer;
  dA, dB: Double;   // test tarafi: Double bolme (sabit katlama Single'a dusmesin)

procedure Fail(const Title, Msg: string);
begin
  Inc(nBad);
  WriteLn('  *** UYUSMAZLIK: ', Title, ' ', Msg);
end;

procedure Chk(const Title: string; Row, Col: Integer; const Expected: string);
var
  got: string;
begin
  if Row >= Length(R.Rows) then
  begin
    Fail(Title, 'satir yok');
    Exit;
  end;
  if Col >= Length(R.Rows[Row]) then
  begin
    Fail(Title, 'sutun yok');
    Exit;
  end;
  got := R.Rows[Row][Col];
  if got = Expected then
  begin
    Inc(nOk);
    WriteLn('  TAMAM: ', Title, ' = ', got);
  end
  else
    Fail(Title, 'beklenen=' + Expected + ' gelen=' + got);
end;

procedure ChkVal(const Title, Sql: string; Row, Col: Integer;
  const Expected: string);
begin
  R := sq.Exec(Sql);
  Chk(Title, Row, Col, Expected);
end;

{ Iki sorgunun ayni hucreyi ayni metinle vermesi. }
procedure ChkSame(const Title, SqlA, SqlB: string; Row, Col: Integer);
var
  A, B: TSqlResult;
  va, vb: string;
begin
  A := sq.Exec(SqlA);
  B := sq.Exec(SqlB);
  va := '';
  vb := '';
  if Row < Length(A.Rows) then va := A.Rows[Row][Col];
  if Row < Length(B.Rows) then vb := B.Rows[Row][Col];
  if va = vb then
  begin
    Inc(nOk);
    WriteLn('  TAMAM: ', Title, ' = ', va);
  end
  else
    Fail(Title, 'A=' + va + ' B=' + vb);
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: aggchk <dizin>');
    Halt(2);
  end;
  dir := ParamStr(1);
  ForceDirectories(dir);
  nBad := 0;
  nOk := 0;
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(dir);
  tb.Open(dir);

  { --- 1) 2^53 ustunde INTEGER SUM --- }
  sq.Exec('CREATE TABLE big(id INTEGER PRIMARY KEY, v INTEGER, g INTEGER)');
  sq.Exec('BEGIN');
  sq.Exec('INSERT INTO big VALUES (1, 9007199254740993, 1)');
  sq.Exec('INSERT INTO big VALUES (2, 9007199254740993, 1)');
  sq.Exec('INSERT INTO big VALUES (3, 9007199254740993, 2)');
  sq.Exec('INSERT INTO big VALUES (4, 1, 2)');
  sq.Exec('INSERT INTO big VALUES (5, 9007199254740993, 3)');
  sq.Exec('INSERT INTO big VALUES (6, -9007199254740992, 3)');
  sq.Exec('INSERT INTO big VALUES (7, 1, 3)');
  sq.Exec('COMMIT');

  R := sq.Exec('SELECT SUM(v) FROM big');
  Chk('SUM tam Int64 (hizli akis)', 0, 0, '27021597764222982');

  ChkSame('SUM hizli/genel yol ayni',
    'SELECT SUM(v) FROM big',
    'SELECT SUM(v) FROM big WHERE id > 0', 0, 0);

  R := sq.Exec('SELECT g, SUM(v) FROM big GROUP BY g ORDER BY g');
  Chk('GROUP BY g=1 SUM', 0, 1, '18014398509481986');
  Chk('GROUP BY g=2 SUM', 1, 1, '9007199254740994');
  Chk('GROUP BY g=3 karisik isaret SUM', 2, 1, '2');

  { Pencere yolu: cerceve yok -> tum partition ayni toplami alir. }
  R := sq.Exec('SELECT id, SUM(v) OVER (PARTITION BY g) FROM big ORDER BY id');
  Chk('Pencere SUM g=1', 0, 1, '18014398509481986');
  Chk('Pencere SUM g=2', 2, 1, '9007199254740994');

  { --- 2) Cok satirli AVG (1e15 olcekli degerler) --- }
  sq.Exec('CREATE TABLE avgbig(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('BEGIN');
  for i := 1 to 1000 do
    sq.Exec('INSERT INTO avgbig VALUES (' + IntToStr(i) + ', 9007199254740993)');
  for i := 1001 to 2000 do
    sq.Exec('INSERT INTO avgbig VALUES (' + IntToStr(i) + ', -9007199254740992)');
  sq.Exec('COMMIT');
  { Tam toplam 1000, sayim 2000 -> AVG 0.5. Eski Double yolu 0 verirdi. }
  ChkVal('AVG cok satir tam', 'SELECT AVG(v) FROM avgbig', 0, 0, '0.5');

  { Kucuk veri: normal AVG sozlesmesi degismedi. }
  sq.Exec('CREATE TABLE sm(id INTEGER PRIMARY KEY, v INTEGER)');
  sq.Exec('INSERT INTO sm VALUES (1, 10)');
  sq.Exec('INSERT INTO sm VALUES (2, 20)');
  sq.Exec('INSERT INTO sm VALUES (3, 30)');
  ChkVal('AVG kucuk', 'SELECT AVG(v) FROM sm', 0, 0, '20');
  ChkVal('SUM kucuk', 'SELECT SUM(v) FROM sm', 0, 0, '60');

  { --- 3) FLOAT SUM/AVG (Kahan) --- }
  sq.Exec('CREATE TABLE flt(id INTEGER PRIMARY KEY, x FLOAT)');
  sq.Exec('BEGIN');
  for i := 1 to 1000 do
    sq.Exec('INSERT INTO flt VALUES (' + IntToStr(i) + ', 0.1)');
  sq.Exec('COMMIT');
  { Naif Double: 99.9999999999986; Kahan: 100. }
  ChkVal('FLOAT SUM Kahan', 'SELECT SUM(x) FROM flt', 0, 0,
    VDbFloatToStr(100.0));
  ChkVal('FLOAT AVG Kahan', 'SELECT AVG(x) FROM flt', 0, 0,
    VDbFloatToStr(0.1));
  ChkSame('FLOAT SUM hizli/genel yol ayni',
    'SELECT SUM(x) FROM flt',
    'SELECT SUM(x) FROM flt WHERE id > 0', 0, 0);

  sq.Exec('CREATE TABLE fst(id INTEGER PRIMARY KEY, x FLOAT)');
  sq.Exec('INSERT INTO fst VALUES (1, 1.25)');
  sq.Exec('INSERT INTO fst VALUES (2, 2.25)');
  sq.Exec('INSERT INTO fst VALUES (3, 3.5)');
  ChkVal('FLOAT SUM basit', 'SELECT SUM(x) FROM fst', 0, 0,
    VDbFloatToStr(7.0));
  dA := 7; dB := 3;
  ChkVal('FLOAT AVG basit', 'SELECT AVG(x) FROM fst', 0, 0,
    VDbFloatToStr(dA / dB));

  { --- 4) JOIN aggregate yolu (Int64) --- }
  sq.Exec('CREATE TABLE j1(id INTEGER PRIMARY KEY, g INTEGER)');
  sq.Exec('INSERT INTO j1 VALUES (1, 1)');
  R := sq.Exec('SELECT SUM(b.v) FROM j1 a JOIN big b ON a.g = b.g');
  Chk('JOIN SUM tam Int64', 0, 0, '18014398509481986');

  WriteLn;
  if nBad = 0 then
  begin
    WriteLn('AGGREGATE HASSASIYETI DOGRULANDI');
    WriteLn('SONUC: gecen=', nOk, ' kalan=0');
  end
  else
    WriteLn('SONUC: gecen=', nOk, ' kalan=', nBad);
  sq.Free; tb.Free; kv.Free;
  if nBad <> 0 then Halt(1);
  WriteLn('TEMIZ');
end.
