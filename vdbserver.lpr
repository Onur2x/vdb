program vdbserver;

{ P-180: PostgreSQL wire (pgwire) sunucusu — calistirilabilir ikili.

  Kullanim:
    vdbserver <veritabani-klasoru> <port> [secenekler]

  Secenekler:
    --user KULLANICI:PAROLA   SCRAM-SHA-256 kullanicisi (tekrarlanabilir).
                              En az bir kullanici varsa kimlik dogrulama
                              zorunludur; yoksa trust.
    --tls SERTIFIKA ANAHTAR   PEM sunucu sertifikasi + ozel anahtar.
    --require-tls             TLS'siz baglantilari reddet (--tls ister).
    --trust                   Hic --user yoksa acik (trust) kabulune izin
                              ver. Kullanici tanimliysa SCRAM zaten zorunlu.
    --metrics PORT            (P-182) Prometheus /metrics ucu; ayri port.

  Calisirken stdin'den satir okur; "stop" satiri veya EOF ile temiz kapanir.
  READY port=<n> auth=<scram|trust> tls=<on|off> satiri basariyla
  dinlemeye baslandigini bildirir.

  Cikis kodlari: 0 = normal, 1 = calisma hatasi, 2 = kullanim hatasi.
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbPgWire, VDbMetricsHttp;

procedure Kullanim;
begin
  WriteLn('kullanim: vdbserver <dizin> <port> [--user K:P] [--tls CERT KEY]');
  WriteLn('                    [--require-tls] [--trust] [--metrics PORT]');
end;

var
  dir, err, line, u, p: string;
  port, v, mport: Integer;
  srv: TVdbPgServer;
  msrv: TVdbMetricsHttpServer;
  mprov: TVdbMetricsProvider;
  i, cpos: Integer;
  kullaniciVar: Boolean;
  guven: Boolean; { P-186 }

begin
  if ParamCount < 2 then
  begin
    Kullanim;
    Halt(2);
  end;
  dir := ParamStr(1);
  port := StrToIntDef(ParamStr(2), -1);
  if (port < 1) or (port > 65535) then
  begin
    WriteLn('gecersiz port: ', ParamStr(2));
    Halt(2);
  end;
  srv := TVdbPgServer.Create(dir, Word(port));
  msrv := nil;
  mport := 0;
  try
    kullaniciVar := False;
    guven := False; { P-186 }
    i := 3;
    while i <= ParamCount do
    begin
      line := LowerCase(ParamStr(i));
      if line = '--user' then
      begin
        if i = ParamCount then
        begin
          Kullanim;
          Halt(2);
        end;
        Inc(i);
        p := ParamStr(i);
        cpos := Pos(':', p);
        if cpos <= 1 then
        begin
          WriteLn('--user bicimi KULLANICI:PAROLA olmali');
          Halt(2);
        end;
        u := Copy(p, 1, cpos - 1);
        p := Copy(p, cpos + 1, MaxInt);
        { P-185: bos parola reddedilir — 'alice:' kaydi trust ile neredeyse
          ayni kapiyi acar; SCRAM'in hic bir kazanimi kalmaz. }
        if p = '' then
        begin
          WriteLn('--user: parola bos olamaz: ', u);
          Halt(2);
        end;
        srv.AddUser(u, p);
        kullaniciVar := True;
      end
      else if line = '--tls' then
      begin
        if i + 2 > ParamCount then
        begin
          Kullanim;
          Halt(2);
        end;
        srv.SetTlsFiles(ParamStr(i + 1), ParamStr(i + 2));
        Inc(i, 2);
      end
      else if line = '--require-tls' then
        srv.RequireTls := True
      else if line = '--trust' then guven := True { P-186 }
      else if line = '--metrics' then
      begin
        if i = ParamCount then
        begin
          Kullanim;
          Halt(2);
        end;
        Inc(i);
        v := StrToIntDef(ParamStr(i), -1);
        if (v < 1) or (v > 65535) then
        begin
          WriteLn('gecersiz metrics portu: ', ParamStr(i));
          Halt(2);
        end;
        // P-182: /metrics ucu Start sonrasi bu numarada yayinlanir.
        mport := v;
      end
      else
      begin
        WriteLn('bilinmeyen secenek: ', ParamStr(i));
        Kullanim;
        Halt(2);
      end;
      Inc(i);
    end;

    { P-186 (dagitim karari): trust yalniz acik bayrakla — kullanicisiz ve
      --trust'suz baslangic reddedilir; sunucu hic dinlemeye gecmez. }
    if not kullaniciVar and not guven then
    begin
      WriteLn(StdErr,
        'HATA: hic --user tanimi yok — sunucu acik moda girmeyi reddediyor. ',
        'En az bir --user KULLANICI:PAROLA verin ya da --trust ile acik ',
        'erisime bilincli izin verin.');
      Halt(2);
    end;
    if not srv.Start(err) then
    begin
      WriteLn('HATA: ', err);
      Halt(1);
    end;
    Write('READY port=', srv.Port);
    if kullaniciVar then Write(' auth=scram') else Write(' auth=trust');
    if srv.TlsActive then WriteLn(' tls=on') else WriteLn(' tls=off');
    { P-185: trust modu sesli uyari — READY satinin stdout akisi
    bozulmadan stderr'e yazilir. }
    if not kullaniciVar then
      WriteLn(StdErr,
        'UYARI: --trust ile acik erisim — her ag kullanicisi kimlik ',
        'dogrulamadan erisir. Uretimde en az bir --user K:P vermeyi dusunun.');
    if mport <> 0 then
    begin
      mprov := srv.MetricsSnapshot;
      msrv := TVdbMetricsHttpServer.Create(Word(mport), mprov);
      if msrv.Start then
        WriteLn('METRICS port=', mport)
      else
      begin
        WriteLn('uyari: metrics portu acilamadi: ', mport);
        FreeAndNil(msrv);
      end;
    end;
    try
      while not EOF do
      begin
        ReadLn(line);
        if LowerCase(Trim(line)) = 'stop' then Break;
      end;
    except
      on E: Exception do WriteLn('uyari: stdin: ', E.Message);
    end;
    if msrv <> nil then msrv.Stop;
    srv.Stop;
  finally
    FreeAndNil(msrv);
    srv.Free;
  end;
end.
