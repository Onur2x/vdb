program dbg1;
{$mode delphi}
uses SysUtils, Classes, VDbCore, VDbTable, VDbSql;
const DIR = 'dbg1_dir';
var kv: TVDb; tb: TVTableDb; sq: TVSql; R: TSqlResult; i, j: Integer;

procedure Show(const q: string);
begin
  R := sq.Exec(q);
  Write(q, '  -> ', Length(R.Rows), ' satir: ');
  for i := 0 to High(R.Rows) do
  begin
    Write('(');
    for j := 0 to High(R.Rows[i]) do
    begin if j > 0 then Write('|'); Write(R.Rows[i][j]); end;
    Write(') ');
  end;
  Writeln;
end;

begin
  DeleteFile(DIR + '\veritabani.odb'); DeleteFile(DIR + '\veritabani.schema');
  if DirectoryExists(DIR) then RemoveDir(DIR);
  ForceDirectories(DIR);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(DIR); tb.Open(DIR);
    sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b BOOLEAN)');
    sq.Exec('INSERT INTO t VALUES (1,10,TRUE)');
    sq.Exec('INSERT INTO t VALUES (2,20,FALSE)');
    sq.Exec('INSERT INTO t VALUES (3,30,TRUE)');
    sq.Exec('INSERT INTO t VALUES (4,40,FALSE)');
    sq.Exec('INSERT INTO t VALUES (5,50,TRUE)');
    sq.Exec('INSERT INTO t VALUES (6,5,FALSE)');
    sq.Exec('INSERT INTO t VALUES (7,35,TRUE)');
    sq.Exec('INSERT INTO t VALUES (8,45,FALSE)');
    sq.Exec('INSERT INTO t VALUES (9,NULL,TRUE)');
    sq.Exec('INSERT INTO t VALUES (10,15,FALSE)');

    Show('SELECT id,a,b FROM t WHERE a >= 30');
    Show('SELECT id,a,b FROM t WHERE a >= 30 ORDER BY id');
    Show('SELECT id,a,b FROM t WHERE a >= 30 AND b = FALSE');
    Show('SELECT id,a,b FROM t WHERE a >= 30 AND b = FALSE ORDER BY id');
    Show('SELECT id,a,b FROM t WHERE b = FALSE');
    Show('SELECT id,a FROM t WHERE a >= 30');
    Show('SELECT id,a FROM t WHERE a >= 30 ORDER BY id');
  finally
    sq.Free; tb.Free; kv.Free;
  end;
end.
