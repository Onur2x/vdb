program ornek03_crud;

{ TR: VDB CRUD İşlemleri Örneği
  EN: VDB CRUD Operations Example

  CREATE, READ, UPDATE, DELETE işlemleri.
  CREATE, READ, UPDATE, DELETE operations. }

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
  WriteLn('=== VDB CRUD İşlemleri / CRUD Operations ===');
  WriteLn;

  KV := TVDb.Create;
  TB := TVTableDb.Create(KV);
  SQ := TVSql.Create(TB);
  try
    KV.Open('ornek03_db');
    TB.Open('ornek03_db');

    // CREATE
    WriteLn('1. CREATE - Veri ekleme / Inserting data');
    SQ.Exec('CREATE TABLE calisan (id INTEGER PRIMARY KEY, ad TEXT, maas FLOAT)');
    SQ.Exec('INSERT INTO calisan (id, ad, maas) VALUES (1, ''Ali'', 50000)');
    SQ.Exec('INSERT INTO calisan (id, ad, maas) VALUES (2, ''Ayşe'', 45000)');
    SQ.Exec('INSERT INTO calisan (id, ad, maas) VALUES (3, ''Mehmet'', 55000)');
    WriteLn('   OK');

    // READ
    R := SQ.Exec('SELECT id, ad, maas FROM calisan ORDER BY id');
    ShowRows('2. READ - Veri okuma / Reading data', R);

    // UPDATE
    WriteLn('3. UPDATE - Maaş güncelleme / Updating salary');
    SQ.Exec('UPDATE calisan SET maas = maas * 1.1 WHERE ad = ''Ali''');
    R := SQ.Exec('SELECT ad, maas FROM calisan WHERE ad = ''Ali''');
    ShowRows('   Zam sonrası / After raise', R);

    // DELETE
    WriteLn('4. DELETE - Kayıt silme / Deleting record');
    SQ.Exec('DELETE FROM calisan WHERE id = 2');
    R := SQ.Exec('SELECT id, ad FROM calisan ORDER BY id');
    ShowRows('   Kalan kayıtlar / Remaining records', R);

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