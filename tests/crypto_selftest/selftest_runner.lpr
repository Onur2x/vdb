program selftest_runner;
{ VDB crypto provider Selftest runner - ADR K5 (Adim 1).

   Kullanim:
     selftest_runner [builtin|openssl|default]
     varsayilan: default = proje secimi (VDbCryptoSelectDefaultProvider,
     yani OpenSSL; builtin'e OTOMATIK GECIS YOKTUR - K6).

   K5 madde 5: bu program iki somut provider birimini (VDbCryptoOpenSSL,
   VDbCryptoBuiltin) uses'e yazar; boylece (a) kendilerini initialization
   ile kaydederler, (b) derlemeye dahildirler. Selftest'in kendisi
   (VDbCryptoSelfTest) saglayici-bagimsizdir.

   Build (FPC 3.2.4, from repo root; -Fu/-FU bayraklari yola bitisik):
     fpc -FuD:\veritabani -FuD:\veritabani\dcpcrypt -FuD:\veritabani\dcpcrypt\Ciphers -FuD:\veritabani\dcpcrypt\Hashes -FUD:\veritabani\tests\crypto_selftest\lib D:\veritabani\tests\crypto_selftest\selftest_runner.lpr

   Exit kodu: FAIL sayisi (0 = yesil). PROVIDER SECILEMEZSE 97 -
   "ortamda kullanilabilir libcrypto yok" ile "vektor basarisiz"
   ayri sinyallenir (G4 kaniti). }

{$mode delphi}{$H+}

uses
  {$ifdef UNIX}
  ccthreads,
  {$endif}
  SysUtils, Classes,
  VDbCryptoTypes,
  VDbCryptoProvider,
  VDbCryptoSelfTest,
  VDbCryptoOpenSSL,
  VDbCryptoBuiltin;

var
  Mode, Err, Log: string;
  Prov: TVDbCryptoProvider;
  Sel, Ok: Boolean;
  Fails: Integer;

function CountFails(const ALog: string): Integer;
var
  L: TStringList;
  J: Integer;
begin
  Result := 0;
  L := TStringList.Create;
  try
    L.Text := ALog;
    for J := 0 to L.Count - 1 do
      if Copy(L[J], 1, 5) = 'FAIL ' then Inc(Result);
  finally
    L.Free;
  end;
end;

begin
  Mode := LowerCase(ParamStr(1));
  if Mode = 'builtin' then
    Sel := VDbCryptoSelectProvider(VDB_PROVIDER_BUILTIN, Err)
  else if Mode = 'openssl' then
    Sel := VDbCryptoSelectProvider(VDB_PROVIDER_OPENSSL, Err)
  else if (Mode = '') or (Mode = 'default') then
    Sel := VDbCryptoSelectDefaultProvider(Err)
  else
  begin
    Writeln('kullanim: selftest_runner [builtin|openssl|default]');
    Writeln('  builtin -> DCP tabanli saglayici (gecis; VDbCrypt/VDbKdf delegasyon)');
    Writeln('  openssl -> OpenSSL EVP saglayici (birincil; dinamik libcrypto)');
    Writeln('  kayitli providerlar: ', VDbCryptoProviderNames);
    Halt(2);
    Sel := False;
    Err := '';
  end;

  if not Sel then
  begin
    Writeln('SONUC: PROVIDER KULLANILAMAZ (exit 97)');
    Writeln(Err);
    Halt(97);
  end;

  Prov := VDbCryptoActiveProvider;
  Writeln('VDB crypto provider selftest - ',
    FormatDateTime('yyyy-mm-dd', Now), ' - provider: ', Prov.Name);
  try
    Ok := VDbCryptoSelfTestRun(Prov, Log);
  except
    on E: Exception do
    begin
      Writeln('SONUC: SELFTEST ISTISNA FIRLATTI: ', E.ClassName,
        ' (', E.Message, ')');
      Halt(1);
      Exit;
    end;
  end;
  Write(Log);
  Fails := CountFails(Log);
  Writeln;
  if Ok and (Fails = 0) then
  begin
    Writeln('RESULT: PASS');
    Halt(0);
  end
  else
  begin
    Writeln('RESULT: FAIL (', Fails, ' vektor basarisiz)');
    if Fails > 255 then Fails := 255;
    Halt(Fails);
  end;
end.
