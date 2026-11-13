unit VDbCryptoBuiltin;
{ VDbCryptoBuiltin - proje-ici, TAMAMEN saf Pascal kripto provider'i (Adim 1).

   Durum: VARSAYILAN provider (SAHIB KARARI R-5). Bu sinif yeni primitif
   URETmez; primitifler saf Pascal cekirdekten gelir:
     AES-256 / SHA-256 / HMAC-SHA256 -> VDbCryptoCore (FIPS-197,
       FIPS 180-4, RFC 2104) - ADIM 4'te DCPcrypt tamamen kaldirildi.
     Argon2id / BLAKE2b               -> VDbKdf.
   Bu birim yalnizca provider sozlesmesini (VDbCryptoProvider) bu
   cekirdege baglar. Harici DLL YOK; DCPcrypt bagimliligi YOK.

   Neden VDbCrypt'e delege: VDbCrypt'in yerel (builtin) yol govdeleri
   zaten bu cekirdegi kullanir ve tek dogruluk kaynagi orada tutulur.
   Dongu riski yoktur cunku VDbCrypt, VDbCryptoBuiltin'i `uses` ETMEZ
   (bkz. VDbCrypt implementation uses notu).

   Opt-in: varsayilan provider builtin'dir (R-5). OpenSSL yalnizca acik
   VDbCryptoSelectProvider(VDB_PROVIDER_OPENSSL) veya
   VDB_CRYPTO_PROVIDER=openssl ile secilir (K6).

   K6 madde 3: bu birim HICbir OpenSSL sembolu cagirmaz; salt mevcut
   Pascal fonksiyonlarini sarar.

   Bilinen yetenek farklari (sozlesme VDbCryptoProvider.pas):
   - capHmacKeyOver64 YOK: VDbCryptHmacSha256 64 bayt uzeri anahtari
     BASELINE 4 geregi reddeder; OpenSSL kabul eder. Selftest bu
     vektoru builtin'de SKIP isaretler (borc listesi: ADR 6).
   - capAes256Block VAR: FIPS 197 blok testi yalnizca builtin'de
     kosar (K6 sembol setine bilerek ECB sembolu eklenmedi).
   - capArgon2id VAR: OpenSSL 1.1.1/3.x EVP sozlesmesinde Argon2id
     yoktur; vektor yalnizca builtin'de kosar.
   - RandomBytes: VDbCryptRandom (CryptoAPI/BCrypt) devredilir;
     capRandom bu yuzden set edilir (K5 madde 2 duman vektoru). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, VDbCryptoTypes, VDbCryptoProvider, VDbCrypt, VDbKdf;

type
  TVDbCryptoBuiltinProvider = class(TVDbCryptoProvider)
  public
    function Name: string; override;
    function Capabilities: TVDbCryptoCaps; override;
    function IsAvailable(out AErr: string): Boolean; override;
    function HashSHA256(const Data: TBytes): TBytes; override;
    function HmacSHA256(const Key, Data: TBytes): TBytes; override;
    function AeadSeal(const Key, Nonce, Plain, Aad: TBytes;
      out Cipher, Tag: TBytes): Boolean; override;
    function AeadOpen(const Key, Nonce, Cipher, Tag, Aad: TBytes;
      out Plain: TBytes): Boolean; override;
    function Pbkdf2Sha256(const Pass, Salt: TBytes;
      Iter, DkLen: Integer): TBytes; override;
    function RandomBytes(out Buf: TBytes; ALen: Integer): Boolean; override;
    function Argon2id(const Password, Salt, Secret, Ad: TBytes;
      TimeCost, MemoryKiB, Lanes, HashLen: Integer;
      out Hash: TBytes): Boolean; override;
    function Aes256Block(const Key, Block: TBytes): TBytes; override;
    function SelfTest(out ALog: string): Boolean; override;
  end;

implementation

uses
  VDbCryptoSelfTest;

{ TVDbCryptoBuiltinProvider }

function TVDbCryptoBuiltinProvider.Name: string;
begin
  Result := VDB_PROVIDER_BUILTIN;
end;

function TVDbCryptoBuiltinProvider.Capabilities: TVDbCryptoCaps;
begin
  { capHmacKeyOver64 BILEREK yok - VDbCryptHmacSha256 >64B anahtari
    reddeder (bilinen borc, ADR 6). capAeadVarNonce zaten sozlesmede
    yok: VDbCryptGcmSeal nonce uzunlugunu 12'ye sabitlemistir. }
  Result := [capHash, capHmac, capPbkdf2, capArgon2id, capAead,
    capRandom, capAes256Block];
end;

{ Statik DCP/Pascal kodu: her zaman hazir. }
function TVDbCryptoBuiltinProvider.IsAvailable(out AErr: string): Boolean;
begin
  AErr := '';
  Result := True;
end;

function TVDbCryptoBuiltinProvider.HashSHA256(const Data: TBytes): TBytes;
begin
  Result := VDbCryptSha256(Data);
end;

function TVDbCryptoBuiltinProvider.HmacSHA256(const Key, Data: TBytes): TBytes;
begin
  Result := VDbCryptHmacSha256(Key, Data);
end;

function TVDbCryptoBuiltinProvider.Pbkdf2Sha256(const Pass, Salt: TBytes;
  Iter, DkLen: Integer): TBytes;
begin
  if (Iter < 1) or (DkLen < 1) then
    raise EVdbCryptoError.Create('PBKDF2: gecersiz parametre',
      VDB_CRYPTO_E_INPUT);
  Result := VDbPbkdf2Sha256(Pass, Salt, Iter, DkLen);
end;

function TVDbCryptoBuiltinProvider.Argon2id(const Password, Salt, Secret,
  Ad: TBytes; TimeCost, MemoryKiB, Lanes, HashLen: Integer;
  out Hash: TBytes): Boolean;
begin
  Hash := nil;
  { VDbArgon2id parametre dogrulamasi ve 256 MB sinirini kendi icinde
    yapiyor; False donerse hata budur. }
  if not VDbArgon2id(Password, Salt, Secret, Ad, TimeCost, MemoryKiB, Lanes,
    HashLen, Hash) then
  begin
    Hash := nil;
    raise EVdbCryptoError.Create('Argon2id: VDbKdf basarisiz (parametre ' +
      'sinirlari mi asildi?)', VDB_CRYPTO_E_INTERNAL);
  end;
  Result := True;
end;

function TVDbCryptoBuiltinProvider.Aes256Block(const Key,
  Block: TBytes): TBytes;
begin
  if (Length(Key) <> VDB_KEY_LEN) or (Length(Block) <> 16) then
    raise EVdbCryptoError.Create('AES blok: anahtar 32 / blok 16 bayt olmali',
      VDB_CRYPTO_E_INPUT);
  Result := VDbCryptAes256Block(Key, Block);
end;

function TVDbCryptoBuiltinProvider.AeadSeal(const Key, Nonce, Plain,
  Aad: TBytes; out Cipher, Tag: TBytes): Boolean;
begin
  { Sozlesme: gecersiz uzunluk -> False, exception DEGIL
    (VDbCryptGcmSeal ile ayni yol). }
  Cipher := nil;
  Tag := nil;
  Result := VDbCryptGcmSeal(Key, Nonce, Plain, Aad, Cipher, Tag);
  if not Result then
  begin
    Cipher := nil;
    Tag := nil;
  end;
end;

function TVDbCryptoBuiltinProvider.AeadOpen(const Key, Nonce, Cipher, Tag,
  Aad: TBytes; out Plain: TBytes): Boolean;
begin
  { Sozlesme: False = red/parametre hatasi, Plain bos birakilir
    (BASELINE 5 satir 76 anlamsal kopyasi). }
  Result := VDbCryptGcmOpen(Key, Nonce, Cipher, Tag, Aad, Plain);
  if not Result then
    Plain := nil;
end;

function TVDbCryptoBuiltinProvider.RandomBytes(out Buf: TBytes;
  ALen: Integer): Boolean;
begin
  Buf := nil;
  if ALen < 0 then
    raise EVdbCryptoError.Create('rastgele: negatif uzunluk',
      VDB_CRYPTO_E_INPUT);
  Result := VDbCryptRandom(Buf, ALen);
  if not Result then
    Buf := nil;
end;

function TVDbCryptoBuiltinProvider.SelfTest(out ALog: string): Boolean;
begin
  Result := VDbCryptoSelfTestRun(Self, ALog);
end;

initialization
  VDbCryptoRegisterProviderClass(VDB_PROVIDER_BUILTIN,
    TVDbCryptoBuiltinProvider);

end.
