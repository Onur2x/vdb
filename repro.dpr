program Repro;

{$mode delphi}
{$APPTYPE CONSOLE}

{ TR: SAVEPOINT + otomatik batch carpmasini izole eden minimal yeniden uretim
  EN: Minimal repro isolating the SAVEPOINT vs auto-batch collision }

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  path: string;

procedure Dump(const Baslik: string);
begin
  R := sq.Exec('SELECT id,v FROM t ORDER BY id');
  WriteLn('  ', Baslik, ' -> satir=', Length(R.Rows), '  InBatch=', Ord(kv.InBatch),
    '  HasSp=', Ord(kv.HasSavepoints), '  Dirty=', Ord(kv.Dirty));
  if Length(R.Rows) > 0 then
    WriteLn('        idler: ', R.Rows[0][0]);
end;

begin
  path := 'C:\temp\vdbrepro';
  if ParamCount >= 1 then path := path + '_eski' else path := path + '_yeni';
  if not DirectoryExists(path) then ForceDirectories(path);

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    // Parametre verilirse otomatik batch KAPALI -> eski (sarmalamasiz) davranis
    if ParamCount >= 1 then
    begin
      sq.AutoTransaction := False;
      WriteLn('** otomatik batch KAPALI (eski davranis) **');
    end
    else
      WriteLn('** otomatik batch ACIK (yeni davranis) **');
    kv.Open(path);
    tb.Open(path);
    sq.Exec('DROP TABLE IF EXISTS t');
    sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
    WriteLn('== SAVEPOINT testi (sqltest T79 ile ayni siralama) ==');
    sq.Exec('INSERT INTO t(id,v) VALUES(1,10)');   // <-- bu mu sarmalanıyor?
    Dump('INSERT id=1 sonrasi');
    sq.Exec('SAVEPOINT sp1');
    Dump('SAVEPOINT sp1 sonrasi');
    sq.Exec('INSERT INTO t(id,v) VALUES(2,20)');
    Dump('INSERT id=2 sonrasi');
    sq.Exec('SAVEPOINT sp2');
    Dump('SAVEPOINT sp2 sonrasi');
    sq.Exec('INSERT INTO t(id,v) VALUES(3,30)');
    Dump('INSERT id=3 sonrasi');
    sq.Exec('ROLLBACK TO SAVEPOINT sp2');
    Dump('ROLLBACK TO sp2 sonrasi  <-- beklenen: 2 satir (id=1,2)');
    sq.Exec('COMMIT');
    Dump('COMMIT sonrasi');
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.
