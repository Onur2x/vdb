program ornek02_sql;

{ TR: VDB SQL Sorguları Örneği
  EN: VDB SQL Queries Example

  Bu örnek, VDB'nin desteklediği SQL sorgularını gösterir.
  This example demonstrates VDB SQL queries. }

{$mode delphi}{$H+}

uses
  SysUtils, VDbBackendApi, VDbFactory, VDbTable, VDbSql;

var
  Be: IVdbBackend;
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
  WriteLn('=== VDB SQL Sorguları / SQL Queries ===');
  WriteLn;

  VdbOpenOrCreate('ornek02_db', Be);
  TB := TVTableDb.CreateBackend(Be);
  SQ := TVSql.Create(TB);
  try
    TB.Open('ornek02_db');

    // TR: Test verisi oluştur / Create test data
    SQ.Exec('CREATE TABLE kategori (id INTEGER PRIMARY KEY, ad TEXT)');
    SQ.Exec('CREATE TABLE urun (id INTEGER PRIMARY KEY, ad TEXT, fiyat FLOAT, kategori_id INTEGER)');
    SQ.Exec('INSERT INTO kategori (id, ad) VALUES (1, ''Elektronik'')');
    SQ.Exec('INSERT INTO kategori (id, ad) VALUES (2, ''Giyim'')');
    SQ.Exec('INSERT INTO urun (ad, fiyat, kategori_id) VALUES (''Laptop'', 15000, 1)');
    SQ.Exec('INSERT INTO urun (ad, fiyat, kategori_id) VALUES (''Telefon'', 8000, 1)');
    SQ.Exec('INSERT INTO urun (ad, fiyat, kategori_id) VALUES (''Tişört'', 250, 2)');

    // 1. SELECT
    R := SQ.Exec('SELECT * FROM urun');
    ShowRows('1. Tüm ürünler / All products', R);

    // 2. WHERE
    R := SQ.Exec('SELECT ad, fiyat FROM urun WHERE fiyat > 1000 ORDER BY fiyat DESC');
    ShowRows('2. Fiyatı 1000 üzeri / Price > 1000', R);

    // 3. JOIN + GROUP BY
    R := SQ.Exec('SELECT k.ad, AVG(u.fiyat) FROM urun u JOIN kategori k ON u.kategori_id = k.id GROUP BY k.ad');
    ShowRows('3. Kategori ortalaması / Category average', R);

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