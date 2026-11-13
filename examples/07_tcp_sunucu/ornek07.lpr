program ornek07_tcp_sunucu;

{ TR: VDB TCP SQL Sunucusu Örneği (R-12)
  EN: VDB TCP SQL Server Example (R-12)

  Bu örnek, TCP SQL sunucusunu gösterir:
  - Sunucu başlatma
  - İstemci bağlantılarını kabul etme
  - SQL sorgularını çalıştırma

  This example demonstrates TCP SQL server:
  - Starting server
  - Accepting client connections
  - Executing SQL queries }

{$mode delphi}{$H+}

uses
  SysUtils, VDbSqlServer;

var
  Srv: TVdbSqlServer;
  Err: string;
  Port: Integer;
begin
  WriteLn('=== VDB TCP SQL Sunucusu / TCP SQL Server ===');
  WriteLn;

  Port := 54720;

  // TR: Sunucu oluştur / Create server
  WriteLn('1. Sunucu oluşturuluyor... / Creating server...');
  Srv := TVdbSqlServer.Create('ornek07_db', Port);
  try
    // TR: Sunucuyu başlat / Start server
    WriteLn('2. Sunucu başlatılıyor... / Starting server...');
    if not Srv.Start(Err) then
    begin
      WriteLn('   HATA / ERROR: ', Err);
      Exit;
    end;

    WriteLn('   OK / Success');
    WriteLn;
    WriteLn('   Sunucu çalışıyor / Server is running');
    WriteLn('   Port: ', Port);
    WriteLn('   Adres / Address: 127.0.0.1:', Port);
    WriteLn('   Maksimum bağlantı / Max connections: 4');
    WriteLn;
    WriteLn('   İstemci bağlanabilir / Clients can connect');
    WriteLn('   VDbClientNet kullanın / Use VDbClientNet');
    WriteLn;
    WriteLn('   Durdurmak için Enter / Press Enter to stop');

    ReadLn;

    // TR: Sunucuyu durdur / Stop server
    WriteLn('3. Sunucu durduruluyor... / Stopping server...');
    Srv.Stop;
    WriteLn('   OK / Success');

    WriteLn;
    WriteLn('=== Tamamlandı / Completed ===');

  finally
    Srv.Free;
  end;

  WriteLn;
  WriteLn('Çıkmak için Enter / Press Enter to exit');
  ReadLn;
end.