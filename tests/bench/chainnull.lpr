program chainnull;
{ Zincir join + NULL sarmalama guvenlik testi (v3.36 duzeltmesi dogrulamasi).
  Senaryo: FROM a INNER JOIN b ... RIGHT JOIN c ... WHERE a.x IS NULL
  WHERE sol tek tarafli IS NULL, zincirde RIGHT JOIN varsa erken eleme
  yanlis sonuc uretir mi?

  Veri:  a(id,k,x): (1,1,10), (2,2,NULL)
         b(id,k):   (1,1), (2,2)
         c(id,k):   (1,1), (3,3)

  El ile cozmum:
    a INNER JOIN b ON a.k=b.k       -> (a1,b1), (a2,b2)            2 satir
    ... RIGHT JOIN c ON c.k=a.k     -> (a1,b1,c1)   [c1 eslesir]
                                        (NULL,NULL,c3) [c3 sarmalama]
                                       a2b2 DUSER (c'de k=2 yok)   2 satir
    WHERE a.x IS NULL               -> (a1 x=10) elenir
                                       (NULL,NULL,c3) kalir        1 satir }
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
  if n > 0 then
    WriteLn('  ilk=', R.Rows[0][0], ' | ', R.Rows[0][1], ' | ', R.Rows[0][2]);
  if n <> Expected then
  begin
    Inc(nBad);
    WriteLn('  *** UYUSMAZLIK ***');
  end;
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: chainnull <dizin>');
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
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('CREATE TABLE c(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('INSERT INTO a VALUES(1,1,10)');   // x NOT NULL
  sq.Exec('INSERT INTO a VALUES(2,2,NULL)'); // x NULL
  sq.Exec('INSERT INTO b VALUES(1,1)');
  sq.Exec('INSERT INTO b VALUES(2,2)');
  sq.Exec('INSERT INTO c VALUES(1,1)');
  sq.Exec('INSERT INTO c VALUES(3,3)');      // k=3 eslesmez -> NULL sarmalama

  WriteLn('=== 1) tam zincir + WHERE a.x IS NULL (v3.34 erken eleme adayi) ===');
  Q('zincir INNER...RIGHT + WHERE a.x IS NULL',
    'SELECT a.id, a.x, c.id FROM a INNER JOIN b ON a.k=b.k RIGHT JOIN c ON c.k=a.k WHERE a.x IS NULL', 1);

  WriteLn;
  WriteLn('=== 2) kontrol: WHERE yok ===');
  Q('zincir INNER...RIGHT (WHERE yok)',
    'SELECT a.id, a.x, c.id FROM a INNER JOIN b ON a.k=b.k RIGHT JOIN c ON c.k=a.k', 2);

  WriteLn;
  WriteLn('=== 3) yalniz RIGHT JOIN + WHERE a.x IS NULL ===');
  Q('yalniz RIGHT + WHERE a.x IS NULL',
    'SELECT a.id, a.x, c.id FROM a RIGHT JOIN c ON c.k=a.k WHERE a.x IS NULL', 1);

  WriteLn;
  WriteLn('=== 4) yalniz INNER + WHERE a.x IS NULL ===');
  Q('yalniz INNER + WHERE a.x IS NULL',
    'SELECT a.id, a.x, b.id FROM a INNER JOIN b ON a.k=b.k WHERE a.x IS NULL', 1);

  WriteLn;
  WriteLn('=== 5) NULL-rejecting WHERE (a.x > 5) zincirde ===');
  Q('zincir INNER...RIGHT + WHERE a.x > 5',
    'SELECT a.id, a.x, c.id FROM a INNER JOIN b ON a.k=b.k RIGHT JOIN c ON c.k=a.k WHERE a.x > 5', 1);

  WriteLn;
  WriteLn('=== 6) zincirde FULL JOIN + WHERE a.x IS NULL ===');
  Q('zincir INNER...FULL + WHERE a.x IS NULL',
    'SELECT a.id, a.x, c.id FROM a INNER JOIN b ON a.k=b.k FULL JOIN c ON c.k=a.k WHERE a.x IS NULL', 2);

  WriteLn;
  if nBad = 0 then
    WriteLn('SONUC: gecen=hepsi kalan=0')
  else
    WriteLn('SONUC: UYUSMAZLIK kalan=', nBad);
  sq.Free; tb.Free; kv.Free;
  if nBad <> 0 then Halt(1);
  WriteLn('TEMIZ');
end.