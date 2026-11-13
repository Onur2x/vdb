unit VDbCryptoRandom;
{ VDbCryptoRandom - CSPRNG erisimi (CRYPTO_ADR K1 - Adim 1).

  TASINMA NOTU (ADR K1 "VDbCryptoRandom oldugu gibi tasinir"):
  VDbCrypt.pas:666-719'daki KANITLANMIS OS CSPRNG mantigi buraya
  birebir kopyalandi (Windows: CryptAcquireContextA/CryptGenRandom -
  hProv=0 VERILMEZ, Win32 87 doner; Unix: /dev/urandom). P-185 kurali
  surer: zaman tabanli LCG fallback YOK - kaynak yoksa fail-closed
  hata, cagiran taraf duymali.

  Bu adimda (Adim 1: dual path) VDbCrypt.pas DOKUNULMADAN durur;
  iki kopya gecici olarak kasitlidir ve Adim 2'de VDbCrypt.Pascal
  implementasyonu bu birime baglanarak tek kaynaga indirilir.

  Provider tercih kurali (K6 ile uyumlu - bu "fallback" DEGILDIR):
  ETKIN provider capRandom'a sahipse (OpenSSL: RAND_bytes) onun
  rastgele kaynagi kullanilir; provider hic secilmediyse veya
  secilen provider'in kendi CSPRNG'si yoksa builtin YOL (OS CSPRNG)
  kullanilir. Kaynak basarisiz olursa HICBIR yol sessiz gecilmez -
  EVdbCryptoError firlatilir (fail-closed). Zayif/deterministik
  doldurma IMKANSIZ. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes,
  VDbCryptoTypes, VDbCryptoProvider;

{ Rastgele bayt uretir. Etkin provider'in CSPRNG'si tercih edilir
  (capRandom), degilse OS CSPRNG. Kaynak hatasi -> EVdbCryptoError. }
function VDbCryptoRandomBytes(out Buf: TBytes; ALen: Integer): Boolean;
function VDbCryptoRandomKey(out Key: TBytes): Boolean;

{ Yalniz OS CSPRNG (Windows CryptoAPI / /dev/urandom) - provider'dan
  bagimsiz. Fail-closed: kaynak yoksa EVdbCryptoError. }
function VDbCryptoOsRandomBytes(out Buf: TBytes; ALen: Integer): Boolean;

implementation

{$IFDEF MSWINDOWS}
const
  PROV_RSA_AES = 24;
  CRYPT_VERIFYCONTEXT = $F0000000;

function CryptAcquireContextA(out phProv: THandle; pszContainer: PChar;
  pszProvider: PChar; dwProvType: DWORD; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptAcquireContextA';
function CryptReleaseContext(hProv: THandle; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptReleaseContext';
function CryptGenRandom(hProv: THandle; dwLen: DWORD; pbBuffer: PByte): BOOL;
  stdcall; external 'advapi32.dll' name 'CryptGenRandom';
{$ENDIF}

function VDbCryptoOsRandomBytes(out Buf: TBytes; ALen: Integer): Boolean;
var
  hProv: THandle;
  {$IFNDEF MSWINDOWS}
  fs: TFileStream;
  got, n: Integer;
  {$ENDIF}
begin
  Result := False;
  Buf := nil;
  if ALen < 0 then
    raise EVdbCryptoError.Create('rastgele: negatif uzunluk', VDB_CRYPTO_E_INPUT);
  SetLength(Buf, ALen);
  if ALen = 0 then Exit(True);
{$IFDEF MSWINDOWS}
  { DIKKAT (VDbCrypt.pas:680-681'den tasinan kanit): CryptGenRandom'a
    hProv=0 VERILMEZ; Win32 87 doner. Gercek saglayici handle'i gerekir. }
  hProv := 0;
  if not CryptAcquireContextA(hProv, nil, nil, PROV_RSA_AES,
    CRYPT_VERIFYCONTEXT) then
    raise EVdbCryptoError.Create('rastgele uretim icin saglayici acilamadi ' +
      '(Win32 ' + IntToStr(GetLastError) + ')', GetLastError);
  try
    if not CryptGenRandom(hProv, DWORD(ALen), @Buf[0]) then
      raise EVdbCryptoError.Create('rastgele bayt uretilemedi (Win32 ' +
        IntToStr(GetLastError) + ')', GetLastError);
  finally
    CryptReleaseContext(hProv, 0);
  end;
  Result := True;
{$ELSE}
  { R-23: Unix (Linux/macOS/BSD) - /dev/urandom.
    P-185: LCG fallback KALDIRILDI - zayif/kestirilebilir RNG kripto
    baglaminda sessizce kabul edilmez; kaynak yoksa hata. }
  if FileExists('/dev/urandom') then
  begin
    fs := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
    try
      got := 0;
      while got < ALen do
      begin
        n := fs.Read(Buf[got], ALen - got);
        if n <= 0 then Break;
        Inc(got, n);
      end;
    finally
      fs.Free;
    end;
    if got = ALen then Exit(True);
  end;
  raise EVdbCryptoError.Create('rastgele bayt kaynagi (/dev/urandom) ' +
    'okunamadi', VDB_CRYPTO_E_INTERNAL);
{$ENDIF}
end;

function VDbCryptoRandomBytes(out Buf: TBytes; ALen: Integer): Boolean;
var
  p: TVDbCryptoProvider;
begin
  p := VDbCryptoActiveProvider;
  if (p <> nil) and (capRandom in p.Capabilities) then
    Exit(p.RandomBytes(Buf, ALen));
  { Etkin provider yoksa ya da provider'in kendi CSPRNG'si yoksa:
    builtin OS yolu. Bu bir saglayici dususu DEGILDIR - builtin yol
    zaten OS CSPRNG'dir ve fail-closed kalir. }
  Result := VDbCryptoOsRandomBytes(Buf, ALen);
end;

function VDbCryptoRandomKey(out Key: TBytes): Boolean;
begin
  Result := VDbCryptoRandomBytes(Key, VDB_KEY_LEN);
end;

end.
