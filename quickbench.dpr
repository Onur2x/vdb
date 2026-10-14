program QuickBench;

{$mode delphi}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  i: Integer;
  t0, t1: Int64;
  path: string;

begin
  if ParamCount >= 1 then
    path := ParamStr(1)
  else
    path := 'C:\temp\qb';
  if not DirectoryExists(path) then ForceDirectories(path);

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(path);
    tb.Open(path);

    sq.Exec('DROP TABLE IF EXISTS b');
    R := sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');
    WriteLn('Tablo: ', R.Msg);
    WriteLn('Tablo olusturuldu, devam ediyor...');

    // --- Batch INSERT ---
    t0 := GetTickCount64;
    sq.Exec('BEGIN');
    for i := 1 to 10000 do
      sq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [i, i*2, i]));
    sq.Exec('COMMIT');
    t1 := GetTickCount64;
    WriteLn(Format('Batch INSERT 10k: %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 10000.0/((t1-t0)/1000.0)]));

    // --- Single INSERT ---
    t0 := GetTickCount64;
    for i := 10001 to 20000 do
      sq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [i, i*2, i]));
    t1 := GetTickCount64;
    WriteLn(Format('Single INSERT 10k: %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 10000.0/((t1-t0)/1000.0)]));

    // --- SELECT PK ---
    t0 := GetTickCount64;
    for i := 1 to 10000 do
      sq.Exec('SELECT val,txt FROM b WHERE id = ' + IntToStr(i));
    t1 := GetTickCount64;
    WriteLn(Format('SELECT PK 10k: %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 10000.0/((t1-t0)/1000.0)]));

    // --- EXPLAIN range ---
    R := sq.Exec('EXPLAIN SELECT val FROM b WHERE id BETWEEN 100 AND 200');
    WriteLn('EXPLAIN range:');
    for i := 0 to High(R.Rows) do
      WriteLn('  ', R.Rows[i][0]);

    // --- Range query ---
    t0 := GetTickCount64;
    for i := 1 to 100 do
      sq.Exec('SELECT val FROM b WHERE id BETWEEN 100 AND 200');
    t1 := GetTickCount64;
    WriteLn(Format('Range (100x) 100: %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 100.0/((t1-t0)/1000.0)]));

    // --- UPDATE ---
    t0 := GetTickCount64;
    for i := 1 to 5000 do
      sq.Exec('UPDATE b SET val = val + 1 WHERE id = ' + IntToStr(i));
    t1 := GetTickCount64;
    WriteLn(Format('UPDATE 5k single: %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 5000.0/((t1-t0)/1000.0)]));

    // --- UPDATE group commit ---
    kv.SyncWriteInterval := 10;
    t0 := GetTickCount64;
    for i := 5001 to 10000 do
      sq.Exec('UPDATE b SET val = val + 1 WHERE id = ' + IntToStr(i));
    t1 := GetTickCount64;
    WriteLn(Format('UPDATE 5k group-commit(10ms): %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 5000.0/((t1-t0)/1000.0)]));
    kv.SyncWriteInterval := 0;

    // --- DELETE ---
    t0 := GetTickCount64;
    for i := 1 to 5000 do
      sq.Exec('DELETE FROM b WHERE id = ' + IntToStr(i));
    t1 := GetTickCount64;
    WriteLn(Format('DELETE 5k single: %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 5000.0/((t1-t0)/1000.0)]));

    // --- DELETE group commit ---
    kv.SyncWriteInterval := 10;
    t0 := GetTickCount64;
    for i := 5001 to 10000 do
      sq.Exec('DELETE FROM b WHERE id = ' + IntToStr(i));
    t1 := GetTickCount64;
    WriteLn(Format('DELETE 5k group-commit(10ms): %.3f sn, %.0f/sn', [(t1-t0)/1000.0, 5000.0/((t1-t0)/1000.0)]));
    kv.SyncWriteInterval := 0;

  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.