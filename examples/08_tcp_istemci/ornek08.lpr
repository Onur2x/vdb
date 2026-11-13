program ornek08_tcp_istemci;

{ TR: VDB TCP SQL İstemcisi Örneği (R-12)
  EN: VDB TCP SQL Client Example (R-12)

  Bu örnek, VDB TCP sunucusuna (R-12) bağlanıp SQL çalıştırır.
  Önce ornek07 (sunucu) çalıştırılmalıdır.

  This example connects to a VDB TCP server (R-12) and runs SQL.
  Run ornek07 (server) first. }

{$mode delphi}{$H+}

uses
  SysUtils, VDbAst, VDbClientNet;

var
  Cl: TVdbNetClient;
  R: TSqlResult;
begin
  WriteLn('=== VDB TCP SQL İstemcisi / TCP SQL Client ===');
  WriteLn;

  Cl := TVdbNetClient.Create;
  try
    // TR: Sunucuya bağlan / Connect to server
    WriteLn('1. Sunucuya bağlanılıyor... / Connecting to server...');
    try
      Cl.Connect('127.0.0.1', 54720);
      WriteLn('   OK / Success');
    except
      on E: Exception do
      begin
        WriteLn('   HATA: Bağlantı kurulamadı / Connection failed: ', E.Message);
        WriteLn('   Önce ornek07 (sunucu) çalıştırın / Run ornek07 (server) first');
        Exit;
      end;
    end;

    // TR: Giriş yap / Login
    WriteLn('2. Giriş yapılıyor... / Logging in...');
    if not Cl.Login('admin', 'admin123') then
    begin
      WriteLn('   HATA: Giriş başarısız / Login failed');
      Exit;
    end;
    WriteLn('   OK / Success');

    // TR: SQL çalıştır / Execute SQL
    WriteLn('3. SQL sorgusu... / SQL query...');
    R := Cl.Exec('SELECT 1+1');
    if Length(R.Rows) > 0 then
      WriteLn('   Sonuç / Result: ', R.Rows[0][0])
    else
      WriteLn('   Sonuç yok / No result');

    // TR: Hazırlanmış sorgu / Prepared statement
    WriteLn('4. Hazırlanmış sorgu... / Prepared statement...');
    if Cl.Prepare('SELECT 2+2') then
    begin
      R := Cl.ExecutePrepared;
      if Length(R.Rows) > 0 then
        WriteLn('   Sonuç / Result: ', R.Rows[0][0]);
    end;

    // TR: Çıkış yap / Logout
    WriteLn('5. Çıkış yapılıyor... / Logging out...');
    Cl.Logout;
    WriteLn('   OK / Success');

    WriteLn;
    WriteLn('=== Tamamlandı / Completed ===');

  finally
    Cl.Free;
  end;

  WriteLn;
  WriteLn('Çıkmak için Enter / Press Enter to exit');
  ReadLn;
end.