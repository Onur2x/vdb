program ornek05_join;

{ TR: VDB JOIN İşlemleri Örneği
  EN: VDB JOIN Operations Example

  INNER, LEFT, RIGHT, CROSS JOIN.
  INNER, LEFT, RIGHT, CROSS JOIN. }

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
  WriteLn('=== VDB JOIN İşlemleri / JOIN Operations ===');
  WriteLn;

  KV := TVDb.Create;
  TB := TVTableDb.Create(KV);
  SQ := TVSql.Create(TB);
  try
    KV.Open('ornek05_db');
    TB.Open('ornek05_db');

    SQ.Exec('CREATE TABLE departman (id INTEGER PRIMARY KEY, ad TEXT)');
    SQ.Exec('CREATE TABLE calisan (id INTEGER PRIMARY KEY, ad TEXT, departman_id INTEGER)');
    SQ.Exec('INSERT INTO departman (id, ad) VALUES (1, ''Yazılım'')');
    SQ.Exec('INSERT INTO departman (id, ad) VALUES (2, ''Pazarlama'')');
    SQ.Exec('INSERT INTO calisan (ad, departman_id) VALUES (''Ali'', 1)');
    SQ.Exec('INSERT INTO calisan (ad, departman_id) VALUES (''Ayşe'', 1)');
    SQ.Exec('INSERT INTO calisan (ad, departman_id) VALUES (''Mehmet'', 2)');
    SQ.Exec('INSERT INTO calisan (ad, departman_id) VALUES (''Fatma'', NULL)');

    R := SQ.Exec('SELECT c.ad, d.ad FROM calisan c INNER JOIN departman d ON c.departman_id = d.id');
    ShowRows('1. INNER JOIN', R);

    R := SQ.Exec('SELECT c.ad, d.ad FROM calisan c LEFT JOIN departman d ON c.departman_id = d.id');
    ShowRows('2. LEFT JOIN', R);

    R := SQ.Exec('SELECT c.ad, d.ad FROM calisan c CROSS JOIN departman d');
    ShowRows('3. CROSS JOIN', R);

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