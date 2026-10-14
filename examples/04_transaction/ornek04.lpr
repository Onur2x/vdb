program ornek04_transaction;

{ TR: VDB Transaction Yönetimi Örneği
  EN: VDB Transaction Management Example

  BEGIN/COMMIT, ROLLBACK, SAVEPOINT.
  BEGIN/COMMIT, ROLLBACK, SAVEPOINT. }

{$mode delphi}{$H+}

uses
  SysUtils, VDbCore, VDbTable, VDbSql;

var
  KV: TVDb;
  TB: TVTableDb;
  SQ: TVSql;
  R: TSqlResult;
  I, J: Integer;

procedure ShowRows(const Title: string; R: TSqlResult);
var
  I, J: Integer;
begin
  WriteLn;
  WriteLn(Title);
  for I := 0 to High(R.Rows) do
  begin
    Write('   ');
    for J := 0 to High(R.Rows[I]) do
    begin
      if J > 0 then Write(' | ');
      Write(R.Rows[I][J]);
    end;
    WriteLn;
  end;
end;

begin
  WriteLn('=== VDB Transaction / Transaction Management ===');
  WriteLn;

  KV := TVDb.Create;
  TB := TVTableDb.Create(KV);
  SQ := TVSql.Create(TB);
  try
    KV.Open('ornek04_db');
    TB.Open('ornek04_db');

    SQ.Exec('CREATE TABLE hesap (id INTEGER PRIMARY KEY, ad TEXT, bakiye FLOAT)');
    SQ.Exec('INSERT INTO hesap (id, ad, bakiye) VALUES (1, ''Ali'', 1000)');
    SQ.Exec('INSERT INTO hesap (id, ad, bakiye) VALUES (2, ''Ayşe'', 1500)');

    // Transaction
    WriteLn('1. Transaction - Para transferi / Money transfer');
    SQ.Exec('BEGIN');
    SQ.Exec('UPDATE hesap SET bakiye = bakiye - 300 WHERE id = 1');
    SQ.Exec('UPDATE hesap SET bakiye = bakiye + 300 WHERE id = 2');
    SQ.Exec('COMMIT');
    R := SQ.Exec('SELECT ad, bakiye FROM hesap');
    ShowRows('   Transfer sonrası / After transfer', R);

    // SAVEPOINT
    WriteLn('2. SAVEPOINT örneği / SAVEPOINT example');
    SQ.Exec('BEGIN');
    SQ.Exec('SAVEPOINT sp1');
    SQ.Exec('UPDATE hesap SET bakiye = bakiye + 500 WHERE id = 1');
    SQ.Exec('ROLLBACK TO SAVEPOINT sp1');
    SQ.Exec('COMMIT');
    R := SQ.Exec('SELECT ad, bakiye FROM hesap');
    ShowRows('   Rollback sonrası / After rollback', R);

    // ROLLBACK
    WriteLn('3. ROLLBACK örneği / ROLLBACK example');
    SQ.Exec('BEGIN');
    SQ.Exec('UPDATE hesap SET bakiye = 0');
    SQ.Exec('ROLLBACK');
    R := SQ.Exec('SELECT ad, bakiye FROM hesap');
    ShowRows('   Rollback sonrası / After rollback', R);

    WriteLn;
    WriteLn('=== Tamamlandı / Completed ===');

  finally
    SQ.Free;
    TB.Free;
    KV.Free;
  end;

  WriteLn;
  WriteLn('Çıkmak için Enter / Press Enter to exit');
  ReadLn;
end.