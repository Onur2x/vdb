program ornek10_ileri;

{ TR: VDB İleri Özellikler Örneği
  EN: VDB Advanced Features Example

  Trigger, View, Window Functions, CTE.
  Trigger, View, Window Functions, CTE. }

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
  WriteLn('=== VDB İleri Özellikler / Advanced Features ===');
  WriteLn;

  VdbOpenOrCreate('ornek10_db', Be);
  TB := TVTableDb.CreateBackend(Be);
  SQ := TVSql.Create(TB);
  try
    TB.Open('ornek10_db');

    SQ.Exec('CREATE TABLE satis (id INTEGER PRIMARY KEY, urun TEXT, tutar FLOAT)');
    SQ.Exec('INSERT INTO satis (id, urun, tutar) VALUES (1, ''Laptop'', 15000)');
    SQ.Exec('INSERT INTO satis (id, urun, tutar) VALUES (2, ''Telefon'', 8000)');
    SQ.Exec('INSERT INTO satis (id, urun, tutar) VALUES (3, ''Laptop'', 12000)');

    // View
    WriteLn('1. View / View');
    SQ.Exec('CREATE VIEW toplam AS SELECT urun, SUM(tutar) AS toplam FROM satis GROUP BY urun');
    R := SQ.Exec('SELECT urun, toplam FROM toplam');
    ShowRows('   View sonucu / View result', R);

    // Window Functions
    WriteLn('2. Window Functions');
    R := SQ.Exec('SELECT urun, tutar, ROW_NUMBER() OVER (ORDER BY tutar DESC) FROM satis');
    ShowRows('   ROW_NUMBER', R);

    // CTE
    WriteLn('3. CTE');
    R := SQ.Exec('WITH ozet AS (SELECT urun, SUM(tutar) AS t FROM satis GROUP BY urun) SELECT urun, t FROM ozet');
    ShowRows('   CTE sonucu / CTE result', R);

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