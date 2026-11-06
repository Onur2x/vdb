program colmapchk;
{ R2-D-YENI-1 dogrulamasi: INSERT sutun haritasi onbellegi.

  Onbelge yalniz uzunluk + tablo adi ile dogrulaniyordu; ayni islemde
  (ya da ardisik INSERT'lerde) ESIT SAYIDA farkli kolon listeli ikinci
  INSERT bayat haritayla sessiz yanlis kolona yazardi.

  Senaryo: t(id INTEGER PRIMARY KEY, a, b, c INTEGER)
    1) INSERT (id,a,b) = (1,10,20)   harita [0,1,2] kurulur
    2) INSERT (id,b,a) = (2,30,40)   ayni sayida farkli sira -> a=40 b=30
    3) INSERT (id,c,a) = (3,50,60)   farkli kume              -> a=60 c=50
    4) batch: (id,a,b)=(4,70,80) sonra (id,b,a)=(5,90,95)     -> a=95 b=90
  Bozuk yolda 2. satirda a=30 b=40, 3. satirda a=50 b=60 c bos,
  5. satirda a=90 b=95 yazilirdi. }
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

procedure Chk(const Title: string; Row, Col: Integer; const Expected: string);
var
  got: string;
begin
  if Row >= Length(R.Rows) then
  begin
    Inc(nBad);
    WriteLn('  *** YOK: satir ', Row, ' (', Title, ')');
    Exit;
  end;
  if Col >= Length(R.Rows[Row]) then
  begin
    Inc(nBad);
    WriteLn('  *** SUTUN YOK: ', Col, ' (', Title, ')');
    Exit;
  end;
  got := R.Rows[Row][Col];
  if got = Expected then
  begin
    Inc(nOk);
    WriteLn('  TAMAM: ', Title, ' = ', got);
  end
  else
  begin
    Inc(nBad);
    WriteLn('  *** UYUSMAZLIK: ', Title, ' beklenen=', Expected, ' gelen=', got);
  end;
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: colmapchk <dizin>');
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

  sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, c INTEGER)');

  { Ayni uzunlukta farkli kolon listeleri — hepsi 3 sutun. }
  sq.Exec('INSERT INTO t(id,a,b) VALUES(1,10,20)');
  sq.Exec('INSERT INTO t(id,b,a) VALUES(2,30,40)');
  sq.Exec('INSERT INTO t(id,c,a) VALUES(3,50,60)');

  { Batch yolu ayni onbellegi kullanir. }
  tb.BeginBatch;
  tb.Insert('t', ['id', 'a', 'b'], ['4', '70', '80'], nil);
  tb.Insert('t', ['id', 'b', 'a'], ['5', '90', '95'], nil);
  tb.CommitBatch;

  R := sq.Exec('SELECT id, a, b, c FROM t ORDER BY id');
  WriteLn('satir sayisi=', Length(R.Rows), ' beklenen=5');

  Chk('satir1.a', 0, 1, '10');
  Chk('satir1.b', 0, 2, '20');
  Chk('satir2.a', 1, 1, '40');
  Chk('satir2.b', 1, 2, '30');
  Chk('satir3.a', 2, 1, '60');
  Chk('satir3.c', 2, 3, '50');
  Chk('satir4.a', 3, 1, '70');
  Chk('satir4.b', 3, 2, '80');
  Chk('satir5.a', 4, 1, '95');
  Chk('satir5.b', 4, 2, '90');

  WriteLn;
  if nBad = 0 then
  begin
    WriteLn('KOLON HARITASI ONBELLEGI DOGRULANDI');
    WriteLn('SONUC: gecen=', nOk, ' kalan=0');
  end
  else
    WriteLn('SONUC: gecen=', nOk, ' kalan=', nBad);
  sq.Free; tb.Free; kv.Free;
  if nBad <> 0 then Halt(1);
  WriteLn('TEMIZ');
end.