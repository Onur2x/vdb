program Bench;

{$mode delphi}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  i, n: Integer;
  t0, t1: Int64;
  secs: Double;
  path: string;

procedure RunBench(const AName: string; ACount: Integer; const ASql: string);
var
  j: Integer;
  ok: Boolean;
  sql: string;
begin
  t0 := GetTickCount64;
  ok := True;
  for j := 1 to ACount do
  begin
    try
      sql := Format(ASql, [j, j, j, j]);
      R := sq.Exec(sql);
    except
      on E: Exception do
      begin
        WriteLn('  HATA (j=', j, '): ', E.Message);
        ok := False;
        Break;
      end;
    end;
  end;
  if not ok then Exit;
  t1 := GetTickCount64;
  secs := (t1 - t0) / 1000.0;
  WriteLn(Format('  %s: %d islem, %.3f sn, %.0f islem/sn',
    [AName, ACount, secs, ACount / secs]));
end;

begin
  if ParamCount >= 1 then
    path := ParamStr(1)
  else
    path := 'C:\temp\bench_db';

  if not DirectoryExists(path) then
    ForceDirectories(path);

  WriteLn('=== VDb Hiz Testi ===');
  WriteLn('Dizin: ', path);
  WriteLn;

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(path);
    tb.Open(path);

    WriteLn('--- Sema ---');
    R := sq.Exec('CREATE TABLE bench(id INTEGER PRIMARY KEY, ad TEXT, val INTEGER, txt TEXT)');
    WriteLn('Tablo olustur: ', R.Msg);

    n := 5000;

    WriteLn(Format('--- Yazma (%d kayit) ---', [n]));

    RunBench('INSERT', n, 'INSERT INTO bench(id,ad,val,txt) VALUES(%d,''kayit_%d'',%d,''data_%.4d'')');

    WriteLn;
    WriteLn('--- Okuma ---');

    RunBench('SELECT tek (PK)', n, 'SELECT ad,val,txt FROM bench WHERE id = %d');

    RunBench('SELECT aralik (100)', n div 10, 'SELECT id,ad FROM bench WHERE id BETWEEN %d AND %d');

    RunBench('SELECT tum (LIMIT 100)', 100, 'SELECT id,ad,val FROM bench ORDER BY id LIMIT 100');

    WriteLn;
    WriteLn('--- Guncelleme ---');

    RunBench('UPDATE tek (PK)', n, 'UPDATE bench SET val = val + 1, txt = ''u_%.4d'' WHERE id = %d');

    WriteLn;
    WriteLn('--- Silme ---');

    RunBench('DELETE tek (PK)', n, 'DELETE FROM bench WHERE id = %d');

    WriteLn;
    WriteLn('=== Bitti ===');

  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.