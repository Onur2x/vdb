program ornek04_transaction;

{ TR: VDB Transaction Yönetimi Örneği
  EN: VDB Transaction Management Example

  BEGIN/COMMIT ve ROLLBACK her iki motorda da vardir.
  SAVEPOINT v3.1 sayfa motorunda HENUZ YOKTUR (v3.2 kapsaminda); ornek bunu
  calisma aninda gosterir, cokme yerine bilgilendirir.
  BEGIN/COMMIT and ROLLBACK work on both engines. SAVEPOINT is NOT available
  on the v3.1 page engine yet (planned for v3.2); the example reports this at
  runtime instead of crashing. }

{$mode delphi}{$H+}

uses
  SysUtils, VDbBackendApi, VDbFactory, VDbTable, VDbSql;

var
  Be: IVdbBackend;
  TB: TVTableDb;
  SQ: TVSql;
  R: TSqlResult;

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

  VdbOpenOrCreate('ornek04_db', Be);
  TB := TVTableDb.CreateBackend(Be);
  SQ := TVSql.Create(TB);
  try
    TB.Open('ornek04_db');

    SQ.Exec('CREATE TABLE hesap (id INTEGER PRIMARY KEY, ad TEXT, bakiye FLOAT)');
    SQ.Exec('INSERT INTO hesap (id, ad, bakiye) VALUES (1, ''Ali'', 1000)');
    SQ.Exec('INSERT INTO hesap (id, ad, bakiye) VALUES (2, ''Ayşe'', 1500)');

    // 1. Transaction: iki UPDATE tek islemde
    WriteLn('1. Transaction - Para transferi / Money transfer');
    SQ.Exec('BEGIN');
    SQ.Exec('UPDATE hesap SET bakiye = bakiye - 300 WHERE id = 1');
    SQ.Exec('UPDATE hesap SET bakiye = bakiye + 300 WHERE id = 2');
    SQ.Exec('COMMIT');
    R := SQ.Exec('SELECT ad, bakiye FROM hesap');
    ShowRows('   Transfer sonrası / After transfer', R);

    // 2. SAVEPOINT: v3.1'de henuz yok -> temiz bir mesaj
    WriteLn('2. SAVEPOINT örneği / SAVEPOINT example');
    SQ.Exec('BEGIN');
    SQ.Exec('UPDATE hesap SET bakiye = bakiye + 500 WHERE id = 1');
    try
      SQ.Exec('SAVEPOINT sp1');
      SQ.Exec('ROLLBACK TO SAVEPOINT sp1');
      WriteLn('   OK / Success');
    except
      on E: Exception do
        WriteLn('   Bu sürümde yok / Not in this version: ', E.Message);
    end;
    SQ.Exec('ROLLBACK');
    R := SQ.Exec('SELECT ad, bakiye FROM hesap');
    ShowRows('   Değişiklik yok / No change', R);

    // 3. ROLLBACK: tum degisiklik geri alinir
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
    Be := nil;
  end;

  WriteLn;
  WriteLn('Çıkmak için Enter / Press Enter to exit');
  ReadLn;
end.
