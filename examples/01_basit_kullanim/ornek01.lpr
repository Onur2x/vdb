program ornek01_basit;

{ TR: VDB Basit Kullanım Örneği
  EN: VDB Basic Usage Example

  Bu örnek, VDB veritabanı motorunun en temel kullanımını gösterir.
  This example shows the most basic usage of VDB database engine. }

{$mode delphi}{$H+}

uses
  SysUtils, VDbCore, VDbTable, VDbSql;

var
  KV: TVDb;
  TB: TVTableDb;
  SQ: TVSql;
  R: TSqlResult;
  I, J: Integer;
  DBPath: string;
begin
  WriteLn('=== VDB Basit Kullanım / Basic Usage ===');
  WriteLn;

  // TR: Veritabanı yolu / Database path
  DBPath := 'ornek01_db';

  // TR: Veritabanı katmanlarını oluştur / Create database layers
  KV := TVDb.Create;
  TB := TVTableDb.Create(KV);
  SQ := TVSql.Create(TB);
  try
    // TR: Veritabanını aç / Open database
    WriteLn('1. Veritabanı açılıyor... / Opening database...');
    KV.Open(DBPath);
    TB.Open(DBPath);
    WriteLn('   OK / Success');

    // TR: Tablo oluştur / Create table
    WriteLn('2. Tablo oluşturuluyor... / Creating table...');
    R := SQ.Exec('CREATE TABLE musteri (id INTEGER PRIMARY KEY, ad TEXT, email TEXT)');
    WriteLn('   OK / Success');

    // TR: Veri ekle / Insert data
    WriteLn('3. Veriler ekleniyor... / Inserting data...');
    SQ.Exec('INSERT INTO musteri (id, ad, email) VALUES (1, ''Ali Veli'', ''ali@example.com'')');
    SQ.Exec('INSERT INTO musteri (id, ad, email) VALUES (2, ''Ayşe'', ''ayse@example.com'')');
    SQ.Exec('INSERT INTO musteri (id, ad, email) VALUES (3, ''Mehmet'', ''mehmet@example.com'')');
    WriteLn('   OK / Success');

    // TR: Veri oku / Read data
    WriteLn('4. Veriler okunuyor... / Reading data...');
    R := SQ.Exec('SELECT id, ad, email FROM musteri ORDER BY id');

    WriteLn;
    WriteLn('   ID | Ad / Name    | Email');
    WriteLn('   ---+--------------+------------------');
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

    WriteLn;
    WriteLn('   Toplam / Total: ', Length(R.Rows), ' kayıt / records');
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