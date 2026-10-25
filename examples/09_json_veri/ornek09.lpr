program ornek09_json;

{ TR: VDB JSON İşlemleri Örneği
  EN: VDB JSON Operations Example

  JSONB veri tipi ve sorgulama.
  JSONB data type and querying. }

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
  WriteLn('=== VDB JSON İşlemleri / JSON Operations ===');
  WriteLn;

  VdbOpenOrCreate('ornek09_db', Be);
  TB := TVTableDb.CreateBackend(Be);
  SQ := TVSql.Create(TB);
  try
    TB.Open('ornek09_db');

    SQ.Exec('CREATE TABLE urun (id INTEGER PRIMARY KEY, ad TEXT, ozellikler TEXT)');
    SQ.Exec('INSERT INTO urun (id, ad, ozellikler) VALUES (1, ''Laptop'', ''{"marka":"Dell","fiyat":15000}'')');
    SQ.Exec('INSERT INTO urun (id, ad, ozellikler) VALUES (2, ''Telefon'', ''{"marka":"Samsung","fiyat":8000}'')');

    R := SQ.Exec('SELECT ad, ozellikler FROM urun');
    ShowRows('1. JSON verileri / JSON data', R);

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