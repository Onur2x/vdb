unit VDbCryptoTypes;
{ VDbCryptoTypes - kriptografi provider katmaninin tip sozlesmesi
  (CRYPTO_ADR K1 / INVENTORY parca 6 - Adim 1).

  Bu birim HICBIR kripto primitifi icermez; yalnizca enum/kimlik/
  yetenek bayraklari ve tipli hata sinifi tanimlar. VDbErr.pas kalibi
  izlenir: Exception alt sinifi + Integer kod, cagiran taraf metin
  ayristirmadan kod uzerinden karar verir.

  KDF kimlikleri CRYPTO_ADR K3/3'teki metadata sozlesmesidir:
    kdf_id bayti: 1 = PBKDF2-SHA256, 2 = Argon2id
  (SCRAM bu alani KULLANMAZ - K3/4 istisnasi; wire protokolunde kendi
  iterasyon alani vardir.) }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  { VDbCrypt.pas'daki VDB_CRYPTO_ERR = -1000 ile celismesin diye ayri
    bant: provider katmani -1100..-1199 kullanir. }
  VDB_CRYPTO_E_PROVIDER  = -1100;  { secilen provider kullanilamaz }
  VDB_CRYPTO_E_NOSELECT  = -1101;  { henuz provider secilmedi }
  VDB_CRYPTO_E_UNSUPPORTED = -1102; { provider bu isi desteklemiyor }
  VDB_CRYPTO_E_INTERNAL  = -1103;  { OpenSSL cagrisi hata dondu }
  VDB_CRYPTO_E_INPUT     = -1104;  { gecersiz uzunluk/parametre }
  VDB_CRYPTO_E_SELFTEST  = -1105;  { selftest basarisiz - crypto kapali }

  { K3 kdf_id metadata degerleri }
  VDB_KDF_ID_PBKDF2_SHA256 = 1;
  VDB_KDF_ID_ARGON2ID      = 2;

  { Provider adlari (secim API'si ve loglar icin ASCII sabitler) }
  VDB_PROVIDER_OPENSSL = 'openssl';
  VDB_PROVIDER_BUILTIN = 'builtin';

  VDB_HASH_SHA256_LEN = 32;
  VDB_AEAD_TAG_LEN    = 16;
  VDB_AEAD_NONCE_LEN  = 12;
  VDB_KEY_LEN         = 32;

type
  { Desteklenen hash algoritmalarinin kimlikleri. Genisletme kurali:
    yeni uyeler SONA eklenir (log/metadata uyumu). }
  TVDbHashAlg = (
    haSHA256
  );

  { KDF kimligi (K3). Tel/sabit eslesimi VDbKdfIdToByte/FromByte ile. }
  TVDbKdfId = (
    kdfPbkdf2Sha256,   { kdf_id = 1 - salt-okunur legacy yol (K3/2) }
    kdfArgon2id        { kdf_id = 2 - yeni yazimlarin tek KDF'i (K3/1) }
  );

  { Provider yetenek bayraklari. Cagiran taraf "var mi" sorusunu
    capability ile sorar; deneme-yanilma ile ogrenmez (K6: sessiz
    dusus yok, eksik yetenek temiz hata/SKIP ile raporlanir). }
  TVDbCryptoCap = (
    capHash,            { HashSHA256 }
    capHmac,            { HmacSHA256 (anahtar <= 64B) }
    capHmacKeyOver64,   { HmacSHA256 >64B anahtari RFC 2104'e gore
                            hash'ler (builtin HENUZ desteklemiyor -
                            bilinen borc; selftest SKIP nedeni) }
    capAead,            { AeadSeal/AeadOpen (AES-256-GCM) }
    capPbkdf2,          { Pbkdf2Sha256 }
    capArgon2id,        { Argon2id (VDbKdf referans implementasyonu) }
    capRandom,          { provider CSPRNG'si (RAND_bytes vb.) }
    capAes256Block      { tek blok AES-256-ECB (yalniz selftest/ic
                            uyumluluk; veri formati bunu kullanmaz) }
  );
  TVDbCryptoCaps = set of TVDbCryptoCap;

  EVdbCryptoError = class(Exception)
  public
    Code: Integer;
    constructor Create(const Msg: string; ACode: Integer);
  end;

{ kdf_id bayt eslemesi - tanimsiz deger False doner (cagiran taraf
  eski dosyada alan yoksa PBKDF2 varsayar; K3/3). }
function VDbKdfIdToByte(Id: TVDbKdfId): Byte;
function VDbKdfIdFromByte(B: Byte; out Id: TVDbKdfId): Boolean;

function VDbHashAlgName(A: TVDbHashAlg): string;

implementation

constructor EVdbCryptoError.Create(const Msg: string; ACode: Integer);
begin
  inherited Create(Msg);
  Code := ACode;
end;

function VDbKdfIdToByte(Id: TVDbKdfId): Byte;
begin
  case Id of
    kdfPbkdf2Sha256: Result := VDB_KDF_ID_PBKDF2_SHA256;
    kdfArgon2id:     Result := VDB_KDF_ID_ARGON2ID;
  else
    Result := 0;
  end;
end;

function VDbKdfIdFromByte(B: Byte; out Id: TVDbKdfId): Boolean;
begin
  case B of
    VDB_KDF_ID_PBKDF2_SHA256: begin Id := kdfPbkdf2Sha256; Result := True; end;
    VDB_KDF_ID_ARGON2ID:      begin Id := kdfArgon2id;     Result := True; end;
  else
    Id := kdfPbkdf2Sha256;
    Result := False;
  end;
end;

function VDbHashAlgName(A: TVDbHashAlg): string;
begin
  case A of
    haSHA256: Result := 'SHA-256';
  else
    Result := '?';
  end;
end;

end.
