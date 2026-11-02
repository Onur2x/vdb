program wherenull;
{ WHERE pushdown NULL-kabul eden predikat guvenlik testi.
  1) LEFT JOIN + WHERE sagda IS NULL  -> v3.35 tarama daraltma hatasi adayi
  2) Zincirde sonradan RIGHT/FULL + WHERE sol IS NULL -> v3.34 FilterSide hatasi adayi }
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
  nBad: Integer;

procedure Q(const Title, Sql: string; Expected: Integer);
var
  n: Integer;
begin
  R := sq.Exec(Sql);
  n := Length(R.Rows);
  WriteLn('--- ', Title);
  WriteLn('  sonuc=', n, '  beklenen=', Expected, '  ', Sql);
  if n <> Expected then
  begin
    Inc(nBad);
    WriteLn('  *** UYUSMAZLIK ***');
  end;
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: wherenull <dizin>');
    Halt(2);
  end;
  dir := ParamStr(1);
  ForceDirectories(dir);
  nBad := 0;
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(dir);
  tb.Open(dir);

  sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, k INTEGER, x INTEGER)');
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, k INTEGER, y INTEGER)');
  sq.Exec('CREATE TABLE c(id INTEGER PRIMARY KEY, k INTEGER)');
  { a: id1 k=1 x=10 ; id2 k=2 x=NULL }
  sq.Exec('INSERT INTO a VALUES(1,1,10)');
  sq.Exec('INSERT INTO a VALUES(2,2,NULL)');
  { b: id1 k=1 y=10 ; id2 k=2 y=NULL }
  sq.Exec('INSERT INTO b VALUES(1,1,10)');
  sq.Exec('INSERT INTO b VALUES(2,2,NULL)');
  { c: id1 k=1 ; id3 k=3 (eslesmez) }
  sq.Exec('INSERT INTO c VALUES(1,1)');
  sq.Exec('INSERT INTO c VALUES(3,3)');

  WriteLn('=== 1) LEFT JOIN + WHERE sag IS NULL (v3.35 tarama daraltma) ===');
  { a LEFT JOIN b ON a.k=b.k:
     a1 eslesir b1 (y=10) ; a2 eslesir b2 (y=NULL)
     WHERE b.y IS NULL -> yalniz a2 satiri (y=NULL)  => 1 satir }
  Q('LEFT + WHERE b.y IS NULL',
    'SELECT a.id, b.y FROM a LEFT JOIN b ON a.k=b.k WHERE b.y IS NULL', 1);

  { a LEFT JOIN b ON a.k=b.k, b'de yalniz y=10 olan satir olsaydi:
     eslesme (y=10) ; WHERE b.y IS NULL -> 0 satir.
     Daraltma b'yi bosaltirsa a NULL-sarmali 1 satir uretir -> HATA. }
  Q('LEFT + WHERE b.y IS NULL (b dolu)',
    'SELECT a.id, b.y FROM a LEFT JOIN b ON a.k=b.k WHERE b.y IS NULL', 1);

  WriteLn;
  WriteLn('=== 2) NULL-rejecting WHERE (guvenli olmali) ===');
  Q('LEFT + WHERE b.y > 5',
    'SELECT a.id, b.y FROM a LEFT JOIN b ON a.k=b.k WHERE b.y > 5', 1);
  Q('INNER + WHERE b.y IS NULL',
    'SELECT a.id, b.y FROM a INNER JOIN b ON a.k=b.k WHERE b.y IS NULL', 1);

  WriteLn;
  WriteLn('=== 3) zincirde sonradan RIGHT JOIN + WHERE sol IS NULL (v3.34) ===');
  { a INNER JOIN b ON a.k=b.k -> 2 satir (a1b1, a2b2)
     RIGHT JOIN c ON c.k=a.k -> a1b1 eslesir c1 ; a2b2 eslesmez (c'de k=2 yok)
       c3 eslesmez -> NULL sarmalama
       SONUC: (a1,b1,c1), (NULL,NULL,c3)   [a2b2 RIGHT'te duser]
     WHERE a.x IS NULL -> (a1 x=10) elenir ; (NULL,NULL,c3) kalir  => 1 satir }
  Q('zincir INNER...RIGHT + WHERE a.x IS NULL',
    'SELECT a.id, a.x, c.id FROM a INNER JOIN b ON a.k=b.k RIGHT JOIN c ON c.k=a.k WHERE a.x IS NULL', 1);

  Q('zincir INNER...RIGHT + WHERE a.x IS NULL (baska)',
    'SELECT a.id, a.x, c.id FROM a INNER JOIN b ON a.k=b.k RIGHT JOIN c ON c.k=a.k WHERE a.x IS NULL', 1);

  WriteLn;
  WriteLn('=== 4) zincirde sonradan FULL JOIN + WHERE sol IS NULL ===');
  { a INNER JOIN b ON a.k=b.k -> 2 satir
     FULL JOIN c ON c.k=a.k -> a1b1+c1 ; a2b2 (k=2 yok c'de) NULL c ; c3 NULL a
       SONUC: 3 satir
     WHERE a.x IS NULL -> (a1 x=10) elenir ; (a2 x=NULL) kalir ; (NULL a) kalir
       => 2 satir }
  Q('zincir INNER...FULL + WHERE a.x IS NULL',
    'SELECT a.id, a.x, c.id FROM a INNER JOIN b ON a.k=b.k FULL JOIN c ON c.k=a.k WHERE a.x IS NULL', 2);

  WriteLn;
  WriteLn('=== 5) tek RIGHT JOIN + WHERE sag IS NULL (koruma) ===');
  { a RIGHT JOIN b ON a.k=b.k -> a1b1 (y=10), a2b2 (y=NULL)  [ikisi de eslesir]
     WHERE b.y IS NULL -> yalniz a2b2  => 1 satir }
  Q('RIGHT + WHERE b.y IS NULL',
    'SELECT a.id, b.y FROM a RIGHT JOIN b ON a.k=b.k WHERE b.y IS NULL', 1);

  WriteLn;
  if nBad = 0 then
    WriteLn('SONUC: gecen=hepsi kalan=0')
  else
    WriteLn('SONUC: UYUSMAZLIK kalan=', nBad);
  sq.Free; tb.Free; kv.Free;
  if nBad <> 0 then Halt(1);
  WriteLn('TEMIZ');
end.