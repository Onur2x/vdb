program scanbench;
{ H1 profili: indekssiz tarama nerede yavas? Varyantlari olc. }
{$mode delphi}
uses
  SysUtils, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 100000;
  REP = 10;
  DIR = 'scanbench_dir';

var
  GFreq: Int64;
function Tick: Int64; var c: Int64; begin QueryPerformanceCounter(c); Result := c; end;
function Ms(t0, t1: Int64): Double; begin Result := (t1 - t0) * 1000 / GFreq; end;

procedure Bench(sq: TVSql; const name, q: string);
var i: Integer; t0, t1: Int64; R: TSqlResult;
begin
  R := sq.Exec(q);  // isinma
  t0 := Tick;
  for i := 1 to REP do R := sq.Exec(q);
  t1 := Tick;
  Writeln(Format('%-8s x%d: %.3f ms/sorgu (satir=%d) :: %s',
    [name, REP, Ms(t0, t1)/REP, Length(R.Rows), q]));
end;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql; i: Integer;
begin
  try
    QueryPerformanceFrequency(GFreq);
    DeleteFile(DIR + '\veritabani.odb'); DeleteFile(DIR + '\veritabani.schema');
    if DirectoryExists(DIR) then RemoveDir(DIR);
    ForceDirectories(DIR);
    kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
    try
      kv.Open(DIR); tb.Open(DIR);
      sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
      sq.Exec('BEGIN');
      for i := 1 to N do
        sq.Exec('INSERT INTO t VALUES (' + IntToStr(i) + ', ' + IntToStr(i mod 500) + ', ''v' + IntToStr(i mod 97) + ''')');
      sq.Exec('COMMIT');

      Bench(sq, 'A-full',  'SELECT COUNT(*) FROM t');
      Bench(sq, 'B-fcnt',  'SELECT COUNT(*) FROM t WHERE a >= 100 AND a < 200');
      Bench(sq, 'C-fsel',  'SELECT id, a FROM t WHERE a >= 100 AND a < 200');
      Bench(sq, 'D-flim',  'SELECT id, a FROM t WHERE a >= 100 AND a < 200 LIMIT 50');
      Bench(sq, 'E-heavy', 'SELECT id, a, b FROM t WHERE a >= 100 AND a < 200 ORDER BY a DESC LIMIT 50');
      Bench(sq, 'F-pkrng', 'SELECT id, a, b FROM t WHERE id >= 100 AND id < 200');
      Bench(sq, 'G-eq',    'SELECT id, a FROM t WHERE a = 123');
      Bench(sq, 'H-all',   'SELECT COUNT(*) FROM t WHERE a >= 0');
      Bench(sq, 'I-nc',    'SELECT COUNT(*) FROM t WHERE 1 = 1');
      Bench(sq, 'J-bsel',  'SELECT id, b FROM t WHERE b = ''v42''');
      Bench(sq, 'K-nwlim', 'SELECT id, a FROM t LIMIT 50');
      Bench(sq, 'L-off',   'SELECT id, a FROM t LIMIT 20 OFFSET 100000');
      Bench(sq, 'M-nwsel', 'SELECT id, a FROM t');
      Bench(sq, 'N-betw',  'SELECT id, a FROM t WHERE a BETWEEN 100 AND 199');
      Bench(sq, 'O-in',    'SELECT id, a FROM t WHERE a IN (100,150,200,250)');
      Bench(sq, 'P-genin', 'SELECT id, a FROM t WHERE (a+0) IN (100,150,200,250)');
      Bench(sq, 'Q-genbetw','SELECT id, a FROM t WHERE (a+0) BETWEEN 100 AND 199');
    finally
      sq.Free; tb.Free; kv.Free;
    end;
  except on E: Exception do Writeln('HATA: ', E.Message); end;
end.
