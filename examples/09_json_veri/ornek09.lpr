program ornek09_json;

{ TR: VDB JSON İşlemleri Örneği
  EN: VDB JSON Operations Example

  JSONB veri tipi ve sorgulama.
  JSONB data type and querying. }

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
  WriteLn('=== VDB JSON İşlemleri / JSON Operations ===');
  WriteLn;

  KV := TVDb.Create;
  TB := TVTableDb.Create(KV);
  SQ := TVSql.Create(TB);
  try
    KV.Open('ornek09_db');
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
    KV.Free;
  end;

  WriteLn;
  WriteLn('Çıkmak için Enter / Press Enter to exit');
  ReadLn;
end.