unit VDbPageCrypto;

{ VDB v3 - sayfa zarfi (Sprint 3.4)

  Sayfa imaji ONCE PageSeal ile CRC'lenir (VDbPage), SONRA AES-256-GCM ile
  sarmalanir. Disk/WAL uzerinde duran zarf:

    nonce (12) | sifreli sayfa (4096) | GCM etiketi (16)   = 4124 bayt

  AAD = 'VDB3PG' (6) | sayfa numarasi (4, LE) | tuz (16)

  Boylece bir zarf baska bir sayfaya ya da baska bir dosyaya tasinamaz:
  etiket dogrulanmadan HICBIR duz metin aciga cikmaz. Yanlis anahtar,
  bozuk zarf ve sayfa karistirma ayni net hataya donusur.

  Anahtar 32 bayttir (AES-256). Parola verilirse PBKDF2-SHA256 ile tuz
  kullanilarak turetilir. Anahtar dogrulamasi icin HMAC tabanli 16 baytlik
  bir "keycheck" meta sayfada acik olarak durur (sir degil, dogrulayici).
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, VDbCrypt;

const
  VDB_ENC_NONCE_LEN = 12;
  VDB_ENC_TAG_LEN   = 16;
  VDB_ENC_SALT_LEN  = 16;
  VDB_ENC_KEY_LEN   = 32;
  VDB_ENC_ENVELOPE  = VDB_ENC_NONCE_LEN + 4096 + VDB_ENC_TAG_LEN;  // 4124
  VDB_ENC_CHECK_LEN = 16;
  VDB_ENC_ITER      = 200000;

type
  EVdbPageCrypto = class(Exception);

{ 16 baytlik anahtar dogrulayici (meta/WAL basliginda saklanir). }
function VDbPageKeyCheck(const Key: TBytes): TBytes;

{ 8 hex karakterlik parmak izi (kullaniciya gosterilir). }
function VDbPageKeyFingerprint(const Key: TBytes): string;

{ Paroladan anahtar turetir (PBKDF2-SHA256). }
function VDbPageKeyFromPassword(const Password: TBytes; const Salt: TBytes;
  Iterations: Integer): TBytes;

{ Yeni rastgele tuz. }
function VDbPageNewSalt: TBytes;

{ Yeni rastgele anahtar (32 bayt) - test/kurulum icin. }
function VDbPageNewKey: TBytes;

{ Sayfa imajini zarfa sarar. Plain 4096 bayt olmalidir. }
function VDbPageSeal(const Key, Salt: TBytes; PageNo: LongWord;
  const Plain: TBytes; out Envelope: TBytes): Boolean;

{ Zarfi cozer. Basarisizsa (yanlis anahtar / bozuk zarf / yanlis sayfa)
  False doner ve OutPlain'e DOKUNMAZ. }
function VDbPageOpen(const Key, Salt: TBytes; PageNo: LongWord;
  const Envelope: TBytes; out Plain: TBytes): Boolean;

implementation

function VDbPageKeyCheck(const Key: TBytes): TBytes;
var
  h: TBytes;
begin
  h := VDbCryptHmacSha256(Key, VDbCryptStrToBytes('VDB3-PAGE-KEY-v1'));
  SetLength(Result, VDB_ENC_CHECK_LEN);
  if Length(h) >= VDB_ENC_CHECK_LEN then
    Move(h[0], Result[0], VDB_ENC_CHECK_LEN)
  else
    FillChar(Result[0], VDB_ENC_CHECK_LEN, 0);
end;

function VDbPageKeyFingerprint(const Key: TBytes): string;
var
  h: TBytes;
  i: Integer;
begin
  Result := '';
  if Length(Key) = 0 then Exit;
  h := VDbCryptHmacSha256(Key, VDbCryptStrToBytes('VDB3-FP-v1'));
  for i := 0 to 3 do
    Result := Result + IntToHex(h[i], 2);
  Result := LowerCase(Result);
end;

function VDbPageKeyFromPassword(const Password: TBytes; const Salt: TBytes;
  Iterations: Integer): TBytes;
begin
  if Iterations < 1 then
    raise EVdbPageCrypto.Create('PBKDF2: gecersiz iterasyon');
  Result := VDbPbkdf2Sha256(Password, Salt, Iterations, VDB_ENC_KEY_LEN);
end;

function VDbPageNewSalt: TBytes;
begin
  if not VDbCryptRandom(Result, VDB_ENC_SALT_LEN) then
    raise EVdbPageCrypto.Create('rastgele tuz uretilemedi');
end;

function VDbPageNewKey: TBytes;
begin
  if not VDbCryptRandom(Result, VDB_ENC_KEY_LEN) then
    raise EVdbPageCrypto.Create('rastgele anahtar uretilemedi');
end;

function BuildAad(const Salt: TBytes; PageNo: LongWord): TBytes;
const
  AAD_MAGIC: array[0..5] of AnsiChar = 'VDB3PG';
var
  n: LongWord;
begin
  SetLength(Result, 6 + 4 + Length(Salt));
  Move(AAD_MAGIC[0], Result[0], 6);
  n := PageNo;
  Move(n, Result[6], 4);
  if Length(Salt) > 0 then
    Move(Salt[0], Result[10], Length(Salt));
end;

function VDbPageSeal(const Key, Salt: TBytes; PageNo: LongWord;
  const Plain: TBytes; out Envelope: TBytes): Boolean;
var
  nonce, cipher, tag, aad: TBytes;
begin
  Result := False;
  Envelope := nil;
  if Length(Key) <> VDB_ENC_KEY_LEN then
    raise EVdbPageCrypto.Create(Format('sifreleme anahtari %d bayt (beklenen %d)',
      [Length(Key), VDB_ENC_KEY_LEN]));
  if Length(Plain) <> 4096 then
    raise EVdbPageCrypto.Create(Format('sayfa imaji %d bayt (beklenen 4096)',
      [Length(Plain)]));
  if not VDbCryptRandom(nonce, VDB_ENC_NONCE_LEN) then
    raise EVdbPageCrypto.Create('nonce uretilemedi');
  aad := BuildAad(Salt, PageNo);
  if not VDbCryptGcmSeal(Key, nonce, Plain, aad, cipher, tag) then
    raise EVdbPageCrypto.Create('AES-GCM sifreleme basarisiz');
  SetLength(Envelope, VDB_ENC_ENVELOPE);
  Move(nonce[0], Envelope[0], VDB_ENC_NONCE_LEN);
  Move(cipher[0], Envelope[VDB_ENC_NONCE_LEN], 4096);
  Move(tag[0], Envelope[VDB_ENC_NONCE_LEN + 4096], VDB_ENC_TAG_LEN);
  Result := True;
end;

function VDbPageOpen(const Key, Salt: TBytes; PageNo: LongWord;
  const Envelope: TBytes; out Plain: TBytes): Boolean;
var
  nonce, cipher, tag, aad: TBytes;
begin
  Result := False;
  Plain := nil;
  if Length(Key) <> VDB_ENC_KEY_LEN then Exit;
  if Length(Envelope) <> VDB_ENC_ENVELOPE then Exit;
  SetLength(nonce, VDB_ENC_NONCE_LEN);
  SetLength(cipher, 4096);
  SetLength(tag, VDB_ENC_TAG_LEN);
  Move(Envelope[0], nonce[0], VDB_ENC_NONCE_LEN);
  Move(Envelope[VDB_ENC_NONCE_LEN], cipher[0], 4096);
  Move(Envelope[VDB_ENC_NONCE_LEN + 4096], tag[0], VDB_ENC_TAG_LEN);
  aad := BuildAad(Salt, PageNo);
  Result := VDbCryptGcmOpen(Key, nonce, cipher, tag, aad, Plain);
end;

end.
