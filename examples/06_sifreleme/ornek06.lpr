program ornek06_sifreleme;

{ TR: VDB Şifreleme Örneği
  EN: VDB Encryption Example

  AES-256 şifreleme.
  AES-256 encryption. }

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
  WriteLn('=== VDB Şifreleme / Encryption ===');
  WriteLn;

  KV := TVDb.Create;
  TB := TVTableDb.Create(KV);
  SQ := TVSql.Create(TB);
  try
    KV.Open('ornek06_db');
    TB.Open('ornek06_db');

    WriteLn('1. Şifreli tablo oluşturuluyor... / Creating encrypted table...');
    SQ.Exec('CREATE TABLE gizli (id INTEGER PRIMARY KEY, ad TEXT, sifre TEXT)');
    SQ.Exec('INSERT INTO gizli (id, ad, sifre) VALUES (1, ''Kullanıcı 1'', ''secret123'')');
    SQ.Exec('INSERT INTO gizli (id, ad, sifre) VALUES (2, ''Kullanıcı 2'', ''password456'')');
    WriteLn('   OK');

    R := SQ.Exec('SELECT id, ad, sifre FROM gizli');
    ShowRows('2. Şifreli veriler / Encrypted data', R);

    WriteLn;
    WriteLn('3. Parola değiştirme / Password change');
    R := SQ.Exec('ALTER DATABASE KEY ''YeniParola123!''');
    WriteLn('   OK');

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