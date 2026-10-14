unit VDbCrypt;
{ VDbCrypt - kayit seviyesinde sifreleme.

  NEDEN SAF PASCAL: Windows kripto API'leri denendi ve bu makinede
  calismadiklari FPC ve .NET P/Invoke ile ayri ayri dogrulandi:
    * BCrypt + AES-256-GCM    -> STATUS_INVALID_PARAMETER (0xC000000D)
    * CryptoAPI CryptCreateHash -> Win32 87 (MD5 dahil TUM algoritmalar)
  Uzerine guvenilemedigi icin primitifler DCPcrypt'ten (MIT, saf
  Pascal) alinmistir; bkz. `dcpcrypt` klasoru.

  KURULUM (encrypt-then-MAC):
    kayit = IV(16) || duzUzunluk(4,LE) || AES-256-CTR(duz) || Tag(32)
    Tag   = HMAC-SHA256(K_mac, IV || len || sifreli)
  Cozmede ONCE Tag dogrulanir; bozuk kayit ASLA cozulmez.
  K_enc ve K_mac master anahtardan ayri ayri turetilir:
    K_enc = HMAC-SHA256(master,"VDB-ENC-v1"), K_mac = ...("VDB-MAC-v1")

  ANAHTAR DOSYASI: master anahtar `.key` icinde DPAPI
  (CryptProtectData, kullanici kapsamli) ile korunur; baska makineye
  kopyalanan dosya acilmaz, kullanici hicbir sey girmeye calismaz. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

const
  VDB_KEY_LEN   = 32;
  VDB_IV_LEN    = 16;
  VDB_TAG_LEN   = 32;
  VDB_CRYPTO_ERR = -1000;

type
  EVdbCryptError = class(Exception)
  public
    Code: Integer;
    constructor Create(const Msg: string; ACode: Integer);
  end;

function VDbCryptRandom(out Buf: TBytes; Len: Integer): Boolean; overload;
function VDbCryptRandom(out Buf: TBytes): Boolean; overload;
function VDbCryptNewKey(out Key: TBytes): Boolean;

{ ---------------- parola-turetmeli anahtar (PBKDF2) ---------------- }

const
  VDB_SALT_LEN  = 16;
  VDB_PBKDF2_ITER = 200000;
  VDB_MIN_PASSWORD_LEN = 8;

{ .key dosyasi basligi }
const
  VDB_KEYFILE_MAGIC = 'VDBK'#0;
  VDB_KEYFILE_VER   = 1;
  VDB_KEYFILE_HEAD  = 10;   { 4 magic + 1 surum + 1 tuzUz + 4 iterasyon }

function VDbPbkdf2Sha256(const Pass, Salt: TBytes; Iter, DkLen: Integer): TBytes;
function VDbCryptNewSalt(out Salt: TBytes): Boolean;
function VDbCryptDeriveKey(const Password: string; const Salt: TBytes;
  Iter: Integer): TBytes;
function VDbCryptVerifier(const Key: TBytes): TBytes;
function VDbCryptKeyFromPassword(const Password: string; const Salt: TBytes;
  Iter: Integer; const Verifier: TBytes; out Key: TBytes): Boolean;
function VDbCryptPasswordLongEnough(const Password: string): Boolean;

function VDbCryptEncrypt(const Key, Plain: TBytes;
  out OutCipher: TBytes): Boolean;
function VDbCryptDecrypt(const Key, Cipher: TBytes;
  out OutPlain: TBytes): Boolean;

function VDbDapiProtect(const Data: TBytes; out OutBlob: TBytes): Boolean;
function VDbDapiUnprotect(const Blob: TBytes; out OutData: TBytes): Boolean;

{ ------------------------------------------------------------------
  .key dosyasi. Dosyada SIR YOKTUR; yalnizca tuz, KDF parametresi
  ve dogrulayici bulunur:

    'VDBK' (4) | surum (1) | tuzUz (1) | iterasyon (4, LE)
    | tuz (tuzUz) | dogrulayici (32)

  Dosya kopyalansa bile anahtar elde edilemez; yalnizca parola
  dogrulanabilir.
  ------------------------------------------------------------------ }
function VDbKeyFileWrite(const FileName: string; const Password: string;
  out OutKey: TBytes; out OutIter: Integer): Boolean;
function VDbKeyFileRead(const FileName: string; const Password: string;
  out OutKey: TBytes; out OutIter: Integer): Boolean;

function VDbCryptStrToBytes(const S: string): TBytes;
function VDbCryptBytesToStr(const B: TBytes): string;
{ Sadece OKUR; `var` degil `const` olmali ki bir fonksiyon sonucu ya da
  ifade dogrudan geçirilebilsin. }
function VDbCryptEqual(const A, B: TBytes): Boolean;

{ Testler icin: HMAC-SHA256 dogrudan dogrudan. }
function VDbCryptHmacSha256(const Key: TBytes; const Data: TBytes): TBytes;

{ Testler icin: AES-256 tek blok ECB (FIPS-197 Appendix C.3 vektoru).
  DCPcrypt'in Init ve EncryptECB parametreleri open array oldugu icin
  tum tamponlar STATIK dizi olarak veriliyor (bkz. tuzak 8). }
function VDbCryptAes256Block(const Key, Block: TBytes): TBytes;

implementation

uses
  {$IFDEF MSWINDOWS} Windows, {$ENDIF}
  dcpcrypt2, dcpblockciphers, dcprijndael, dcpsha256;

{$IFDEF MSWINDOWS}
const
  CRYPTPROTECT_UI_FORBIDDEN = $00000001;
  PROV_RSA_AES = 24;
  CRYPT_VERIFYCONTEXT = $F0000000;
{$ENDIF}

type
  TTDCP_sha256Class = class of TDCP_sha256;
  TTDCP_rijndaelClass = class of TDCP_rijndael;

{$IFDEF MSWINDOWS}
type
  DATA_BLOB = record
    cbData: DWORD;
    pbData: PByte;
  end;
  PDATA_BLOB = ^DATA_BLOB;

function CryptAcquireContextA(out phProv: THandle; pszContainer: PChar;
  pszProvider: PChar; dwProvType: DWORD; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptAcquireContextA';
function CryptReleaseContext(hProv: THandle; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptReleaseContext';
function CryptGenRandom(hProv: THandle; dwLen: DWORD; pbBuffer: PByte): BOOL;
  stdcall; external 'advapi32.dll' name 'CryptGenRandom';
function CryptProtectData(pDataIn: PDATA_BLOB; szDescription: PChar;
  pOptionalEntropy: PDATA_BLOB; pvReserved: Pointer;
  pPromptStruct: Pointer; dwFlags: DWORD; pDataOut: PDATA_BLOB): BOOL;
  stdcall; external 'crypt32.dll' name 'CryptProtectData';
function CryptUnprotectData(pDataOut: PDATA_BLOB; ppszDataDescr: PPChar;
  pOptionalEntropy: PDATA_BLOB; pvReserved: Pointer;
  pPromptStruct: Pointer; dwFlags: DWORD; pDataIn: PDATA_BLOB): BOOL;
  stdcall; external 'crypt32.dll' name 'CryptUnprotectData';
{$ENDIF}

constructor EVdbCryptError.Create(const Msg: string; ACode: Integer);
begin
  Code := ACode;
  inherited CreateFmt('VDbCrypt: %s (hata %d)', [Msg, ACode]);
end;

function VDbCryptStrToBytes(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function VDbCryptBytesToStr(const B: TBytes): string;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Result[1], Length(B));
end;

function VDbCryptEqual(const A, B: TBytes): Boolean;
{ Sabit zamanli icerik karsilastirmasi.
  DIKKAT: dizi parametrelerine A[i] / B[i] seklinde DOGRUKAN
  erisilmez; isaretci aritmetigi (PByte) kullanilir. Acik dizi
  parametreleri uzerinden indeksleme bu ortamda bir bayt kayabiliyor
  ve etiket dogrulamasini yanlis yonde etkiliyordu. }
var
  pa, pb: PByte;
  i, n: Integer;
  d: Byte;
begin
  n := Length(A);
  if n <> Length(B) then Exit(False);
  if n = 0 then Exit(True);
  pa := @A[0];
  pb := @B[0];
  d := 0;
  for i := 0 to n - 1 do
    d := d or Byte(pa[i] xor pb[i]);
  Result := (d = 0);
end;

function VDbCryptHmacSha256(const Key, Data: TBytes): TBytes;
var
  kPad: array[0..63] of Byte;
  inner, outer: array[0..31] of Byte;
  h: TDCP_sha256;
  cls: TTDCP_sha256Class;
  i: Integer;
begin
  if Length(Key) > 64 then
    raise EVdbCryptError.Create('HMAC anahtari cok uzun', VDB_CRYPTO_ERR);
  FillChar(kPad, SizeOf(kPad), 0);
  for i := 1 to Length(Key) do
    kPad[i - 1] := Key[i - 1];
  for i := 1 to 64 do
    kPad[i - 1] := kPad[i - 1] xor $36;
  { DCPcrypt siniflari kendi Create metotlarini bildirmiyor; TComponent'inkini
    miras aliyorlar. Dogrudan `TDCP_sha256.Create` bir **sinif metodi
    referansi** olarak ele alindiginda FPC onu TComponent olarak tipler.
    Bu yuzden sinif-referansi degiskeni uzerinden cagrilir. }
  cls := TDCP_sha256;
  h := cls.Create(nil);
  try
    h.Init;
    h.Update(kPad, 64);
    if Length(Data) > 0 then
      h.Update(Data[0], LongWord(Length(Data)));
    h.Final(inner);
    FillChar(kPad, SizeOf(kPad), 0);
    for i := 1 to Length(Key) do
      kPad[i - 1] := Key[i - 1];
    for i := 1 to 64 do
      kPad[i - 1] := kPad[i - 1] xor $5C;
    h.Init;
    h.Update(kPad, 64);
    h.Update(inner, SizeOf(inner));
    h.Final(outer);
  finally
    h.Free;
  end;
  FillChar(kPad, SizeOf(kPad), 0);
  SetLength(Result, VDB_TAG_LEN);
  Move(outer, Result[0], VDB_TAG_LEN);
end;

function VDbCryptAes256Block(const Key, Block: TBytes): TBytes;
var
  aes: TDCP_rijndael;
  ccls: TTDCP_rijndaelClass;
  kSt: array[0..VDB_KEY_LEN - 1] of Byte;
  iv: array[0..15] of Byte;
  blkIn, blkOut: array[0..15] of Byte;
  i, n: Integer;
begin
  if Length(Key) <> VDB_KEY_LEN then
    raise EVdbCryptError.Create('AES-256 anahtar uzunlugu ' +
      IntToStr(Length(Key)) + ' (beklenen ' + IntToStr(VDB_KEY_LEN) + ')',
      VDB_CRYPTO_ERR);
  n := Length(Block);
  if n > 16 then n := 16;
  dcpFillChar(kSt, SizeOf(kSt), 0);
  dcpFillChar(iv, SizeOf(iv), 0);
  dcpFillChar(blkIn, SizeOf(blkIn), 0);
  dcpFillChar(blkOut, SizeOf(blkOut), 0);
  Move(Key[0], kSt[0], VDB_KEY_LEN);
  if n > 0 then
    Move(Block[0], blkIn[0], n);
  ccls := TDCP_rijndael;
  aes := ccls.Create(nil);
  try
    aes.Init(kSt, 256, @iv[0]);
    aes.EncryptECB(blkIn[0], blkOut[0]);
  finally
    aes.Free;
  end;
  dcpFillChar(kSt, SizeOf(kSt), 0);
  SetLength(Result, 16);
  for i := 0 to 15 do
    Result[i] := blkOut[i];
end;

function Hmac2(const Key, D1, D2: TBytes): TBytes;
var
  tmp: TBytes;
begin
  SetLength(tmp, Length(D1) + Length(D2));
  if Length(D1) > 0 then Move(D1[0], tmp[0], Length(D1));
  if Length(D2) > 0 then Move(D2[0], tmp[Length(D1)], Length(D2));
  Result := VDbCryptHmacSha256(Key, tmp);end;

function ConcatB(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

procedure DeriveKeys(const Master: TBytes; out KEnc, KMac: TBytes);
begin
  if Length(Master) <> VDB_KEY_LEN then
    raise EVdbCryptError.Create('anahtar uzunlugu ' +
      IntToStr(Length(Master)) + ' (beklenen ' + IntToStr(VDB_KEY_LEN) + ')',
      VDB_CRYPTO_ERR);
  KEnc := VDbCryptHmacSha256(Master, VDbCryptStrToBytes('VDB-ENC-v1'));
  KMac := VDbCryptHmacSha256(Master, VDbCryptStrToBytes('VDB-MAC-v1'));
end;

function VDbCryptRandom(out Buf: TBytes; Len: Integer): Boolean;
var
  hProv: THandle;
  {$IFNDEF MSWINDOWS}
  fs: TFileStream;
  got, n: Integer;
  seed: Int64;
  {$ENDIF}
begin
  Result := False;
  Buf := nil;
  if Len < 0 then Exit;
  SetLength(Buf, Len);
  if Len = 0 then Exit(True);
{$IFDEF MSWINDOWS}
  { DIKKAT: CryptGenRandom'a hProv=0 VERILMEZ; Win32 87 doner.
    Gercek bir saglayici handle'i acmak gerekir. }
  hProv := 0;
  if not CryptAcquireContextA(hProv, nil, nil, PROV_RSA_AES,
    CRYPT_VERIFYCONTEXT) then
    raise EVdbCryptError.Create('rastgele uretim icin saglayici acilamadi ' +
      '(Win32 ' + IntToStr(GetLastError) + ')', GetLastError);
  try
    if not CryptGenRandom(hProv, DWORD(Len), @Buf[0]) then
      raise EVdbCryptError.Create('rastgele bayt uretilemedi (Win32 ' +
        IntToStr(GetLastError) + ')', GetLastError);
  finally
    CryptReleaseContext(hProv, 0);
  end;
  Result := True;
{$ELSE}
  { R-23: Unix (Linux/macOS/BSD) — /dev/urandom. Yeterince entropi
    yoksa (nadir) zaman tabanli PRNG'ye dusulur. }
  if FileExists('/dev/urandom') then
  begin
    fs := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
    try
      got := 0;
      while got < Len do
      begin
        n := fs.Read(Buf[got], Len - got);
        if n <= 0 then Break;
        Inc(got, n);
      end;
    finally
      fs.Free;
    end;
    if got = Len then Exit(True);
  end;
  seed := Int64(Round(Now * 86400000.0)) xor Int64(PtrUInt(Buf));
  for got := 0 to Len - 1 do
  begin
    seed := seed * 6364136223846793005 + 1442695040888963407;
    Buf[got] := Byte(seed shr 33);
  end;
  Result := True;
{$ENDIF}
end;

function VDbCryptRandom(out Buf: TBytes): Boolean;
begin
  Result := VDbCryptRandom(Buf, VDB_KEY_LEN);
end;

function VDbCryptNewKey(out Key: TBytes): Boolean;
begin
  Result := VDbCryptRandom(Key, VDB_KEY_LEN);
end;

{ --------------------------- PBKDF2 --------------------------- }

function VDbPbkdf2Sha256(const Pass, Salt: TBytes; Iter, DkLen: Integer): TBytes;
var
  msg: TBytes;      // S || INT_32_BE(i)
  u: TBytes;        // U_i (HMAC sonucu, tam 32 bayt)
  acc: TBytes;      // biriktilen XOR
  blk: array[0..3] of Byte;
  blkno, it, k: Integer;
  ofs: Integer;
begin
  { RFC 8018 PBKDF2:
      U_1 = PRF(P, S || INT(i))
      U_j = PRF(P, U_(j-1))
      T_i = U_1 xor U_2 xor ... xor U_c
    PRF = HMAC-SHA256 (ciktisi tam 32 bayt). }
  if (Iter < 1) or (DkLen < 1) then
    raise EVdbCryptError.Create('PBKDF2: gecersiz parametre', VDB_CRYPTO_ERR);

  SetLength(Result, DkLen);
  blkno := 1;
  while blkno <= ((DkLen + VDB_TAG_LEN - 1) div VDB_TAG_LEN) do
  begin
    blk[0] := Byte((blkno shr 24) and $FF);
    blk[1] := Byte((blkno shr 16) and $FF);
    blk[2] := Byte((blkno shr 8) and $FF);
    blk[3] := Byte(blkno and $FF);

    SetLength(msg, Length(Salt) + 4);
    if Length(Salt) > 0 then
      Move(Salt[0], msg[0], Length(Salt));
    Move(blk[0], msg[Length(Salt)], 4);

    u := VDbCryptHmacSha256(Pass, msg);
    SetLength(acc, VDB_TAG_LEN);
    Move(u[0], acc[0], VDB_TAG_LEN);

    for it := 2 to Iter do
    begin
      u := VDbCryptHmacSha256(Pass, u);
      for k := 0 to VDB_TAG_LEN - 1 do
        acc[k] := acc[k] xor u[k];
    end;

    ofs := (blkno - 1) * VDB_TAG_LEN;
    { DIZI 0 TABANLIDIR. once Result[ofs + 1] yaziliyordu ve cikti
      bir bayt kayiyordu (ilk bayt cop, son bayt dusuyordu):
      RFC 7914 vektoru '73' + dogru deger olarak cikiyordu. }
    if ofs + VDB_TAG_LEN <= DkLen then
      Move(acc[0], Result[ofs], VDB_TAG_LEN)
    else
      Move(acc[0], Result[ofs], DkLen - ofs);

    Inc(blkno);
  end;
  if Length(u) > 0 then FillChar(u[0], Length(u), 0);
  if Length(acc) > 0 then FillChar(acc[0], Length(acc), 0);
  if Length(msg) > 0 then FillChar(msg[0], Length(msg), 0);
end;

function VDbCryptNewSalt(out Salt: TBytes): Boolean;
begin
  Result := VDbCryptRandom(Salt, VDB_SALT_LEN);
end;

function VDbCryptDeriveKey(const Password: string; const Salt: TBytes;
  Iter: Integer): TBytes;
var
  p: TBytes;
begin
  p := VDbCryptStrToBytes(Password);
  Result := VDbPbkdf2Sha256(p, Salt, Iter, VDB_KEY_LEN);
  FillChar(p[0], Length(p), 0);
end;

function VDbCryptVerifier(const Key: TBytes): TBytes;
begin
  Result := VDbCryptHmacSha256(Key,
    VDbCryptStrToBytes('VDB-KEY-VERIFY'));
end;

function VDbCryptKeyFromPassword(const Password: string; const Salt: TBytes;
  Iter: Integer; const Verifier: TBytes; out Key: TBytes): Boolean;
var
  v: TBytes;
  vc: TBytes;
begin
  Key := VDbCryptDeriveKey(Password, Salt, Iter);
  v := VDbCryptVerifier(Key);
  { Sabit zamanli karsilastirma: yanlis parola "hemen fark edilir".
    VDbCryptEqual `var` parametre istiyor; `const` Verifier'i once
    yereel kopyaya aliyoruz. }
  vc := Verifier;
  Result := VDbCryptEqual(v, vc);
  FillChar(Key[0], Length(Key), 0);
end;

function VDbCryptPasswordLongEnough(const Password: string): Boolean;
begin
  Result := Length(Password) >= VDB_MIN_PASSWORD_LEN;
end;

{ ------------------------- .key dosyasi ------------------------- }

function VDbKeyFileWrite(const FileName: string; const Password: string;
  out OutKey: TBytes; out OutIter: Integer): Boolean;
var
  salt, verifier, buf: TBytes;
  f: TFileStream;
  i: Integer;
begin
  OutKey := nil;
  OutIter := 0;
  if not VDbCryptPasswordLongEnough(Password) then
    raise EVdbCryptError.Create('parola cok kisa (en az ' +
      IntToStr(VDB_MIN_PASSWORD_LEN) + ' karakter)', VDB_CRYPTO_ERR);

  salt := nil;
  VDbCryptNewSalt(salt);
  OutIter := VDB_PBKDF2_ITER;
  OutKey := VDbCryptDeriveKey(Password, salt, OutIter);
  verifier := VDbCryptVerifier(OutKey);

  { 'VDBK' | surum | tuzUz | iterasyon(LE) | tuz | dogrulayici }
  SetLength(buf, VDB_KEYFILE_HEAD + Length(salt) + Length(verifier));
  Move(VDB_KEYFILE_MAGIC[1], buf[0], 4);
  buf[4] := VDB_KEYFILE_VER;
  buf[5] := Byte(Length(salt));
  for i := 0 to 3 do
    buf[6 + i] := Byte((LongWord(OutIter) shr (i * 8)) and $FF);
  Move(salt[0], buf[VDB_KEYFILE_HEAD], Length(salt));
  Move(verifier[0], buf[VDB_KEYFILE_HEAD + Length(salt)], Length(verifier));

  f := TFileStream.Create(FileName, fmCreate);
  try
    if Length(buf) > 0 then
      f.WriteBuffer(buf[0], Length(buf));
  finally
    f.Free;
  end;
  FillChar(salt[0], Length(salt), 0);
  FillChar(buf[0], Length(buf), 0);
  Result := True;
end;

function VDbKeyFileRead(const FileName: string; const Password: string;
  out OutKey: TBytes; out OutIter: Integer): Boolean;
var
  salt, verifier, buf, blob, tmp: TBytes;
  f: TFileStream;
  saltLen, i: Integer;
  n: Int64;
  p: PByte;
  tam: Boolean;
begin
  OutKey := nil;
  OutIter := 0;
  f := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    n := f.Size;
    if n < VDB_KEYFILE_HEAD + VDB_TAG_LEN then
      raise EVdbCryptError.Create('.key dosyasi cok kisa / bozuk (' +
        IntToStr(n) + ' bayt)', VDB_CRYPTO_ERR);
    SetLength(buf, n);
    if n > 0 then
      f.ReadBuffer(buf[0], n);
  finally
    f.Free;
  end;

  p := @buf[0];
  for i := 0 to 3 do
    if p[i] <> Byte(VDB_KEYFILE_MAGIC[i + 1]) then
      raise EVdbCryptError.Create('bu bir VDB .key dosyasi degil (imza hatali)',
        VDB_CRYPTO_ERR);
  if p[4] <> VDB_KEYFILE_VER then
    raise EVdbCryptError.Create('.key surumu desteklenmiyor (dosya ' +
      IntToStr(p[4]) + ', beklenen ' + IntToStr(VDB_KEYFILE_VER) + ')',
      VDB_CRYPTO_ERR);
  saltLen := p[5];
  if (saltLen < 8) or (saltLen > 64) then
    raise EVdbCryptError.Create('.key tuz uzunlugu gecersiz (' +
      IntToStr(saltLen) + ')', VDB_CRYPTO_ERR);
  { DIKKAT: f serbest birakildi; burada DOSYAYA DEGIL, kaydedilmis
    boyuta bakiliyor. }
  if n <> VDB_KEYFILE_HEAD + saltLen + VDB_TAG_LEN then
    raise EVdbCryptError.Create('.key dosya boyutu tutarsiz', VDB_CRYPTO_ERR);

  OutIter := 0;
  for i := 0 to 3 do
    OutIter := OutIter or (Integer(p[6 + i]) shl (i * 8));
  if (OutIter < 1000) or (OutIter > 10000000) then
    raise EVdbCryptError.Create('.key iterasyon sayisi gecersiz (' +
      IntToStr(OutIter) + ')', VDB_CRYPTO_ERR);

  SetLength(salt, saltLen);
  Move(p[VDB_KEYFILE_HEAD], salt[0], saltLen);
  SetLength(verifier, VDB_TAG_LEN);
  Move(p[VDB_KEYFILE_HEAD + saltLen], verifier[0], VDB_TAG_LEN);

  { ONEMLI: VDbCryptKeyFromPassword YOK; anahtari dogrulama sonrasi
    BILEREK SILER ("sifreleme icin kullanilamaz" olmasi icin). Burada
    ise anahtari ELDE ETMEMIZ gerekiyor. Dogrulamayi kendimiz
    sabit zamanli karsilastirma ile yapiyoruz. }
  OutKey := VDbCryptDeriveKey(Password, salt, OutIter);
  blob := VDbCryptVerifier(OutKey);
  tmp := Copy(verifier, 0, Length(verifier));
  tam := VDbCryptEqual(blob, tmp);
  FillChar(salt[0], Length(salt), 0);
  FillChar(buf[0], Length(buf), 0);
  if not tam then
  begin
    FillChar(OutKey[0], Length(OutKey), 0);
    OutKey := nil;
    Result := False;
    Exit;
  end;
  Result := True;
end;

function VDbCryptEncrypt(const Key, Plain: TBytes;
  out OutCipher: TBytes): Boolean;
var
  iv, kEnc, kMac, body, tag, lenB, outTmp: TBytes;
  aes: TDCP_rijndael;
  ccls: TTDCP_rijndaelClass;
  plainLen, padded: LongWord;
  p, n: Integer;
  blkIn, blkOut: array[0..15] of Byte;
  ivComp: array[0..15] of Byte;
  kEncStat: array[0..VDB_KEY_LEN - 1] of Byte;
begin
  OutCipher := nil;
  DeriveKeys(Key, kEnc, kMac);
  plainLen := LongWord(Length(Plain));
  iv := nil;
  VDbCryptRandom(iv, VDB_IV_LEN);

  padded := ((plainLen + 15) div 16) * 16;
  if padded = 0 then padded := 16;
  SetLength(body, padded);
  FillChar(body[0], padded, 0);
  if plainLen > 0 then
    Move(Plain[0], body[0], plainLen);

  Move(iv[0], ivComp[0], VDB_IV_LEN);
  SetLength(outTmp, padded);
  ccls := TDCP_rijndael;
  aes := ccls.Create(nil);
  try
    { ONEMLI: Init'in Key parametresi open array. Bu ortamda (FPC 3.2.2,
      i386) dinamik dizi (TBytes) verildiginde anahtar YANLIS okunuyor -
      ayni anahtar/IV/düz metin statik dizi ile verildiginde tamamen
      farkli sifreli metin uretiyor (48/48 bayt farkli, bagimsiz
      ctr.lpr olcumuyle kanitlandi). Bu yuzden once statik tampona
      kopyaliyoruz. }
    Move(kEnc[0], kEncStat[0], VDB_KEY_LEN);
    aes.Init(kEncStat, 256, @ivComp[0]);
    { 2026-10-05: DCPcrypt'in blok tamponu STATIK dizi ile besleniyor.
      Dinamik dizi tamponu dogrudan verildiginde cozme sonucu
      tutarsiz cikiyordu (uzunluk dogru, baytlar yanlis; etiket
      dogrulamasi gectigi icin IV/anahtar ayniydi). Blok blok, statik
      tamponla islemmek bu belirsizligi tamamen ortadan kaldirir ve
      ayni zamanda bellege tek seferde dokunmaz. }
    p := 0;
    while p < Integer(padded) do
    begin
      n := Integer(padded) - p;
      if n > 16 then n := 16;
      dcpFillChar(blkIn, SizeOf(blkIn), 0);
      dcpFillChar(blkOut, SizeOf(blkOut), 0);
      Move(body[p], blkIn[0], n);
      aes.EncryptCTR(blkIn[0], blkOut[0], 16);
      Move(blkOut[0], outTmp[p], n);
      Inc(p, 16);
    end;
  finally
    aes.Free;
  end;

  SetLength(lenB, 4);
  lenB[0] := Byte(plainLen and $FF);
  lenB[1] := Byte((plainLen shr 8) and $FF);
  lenB[2] := Byte((plainLen shr 16) and $FF);
  lenB[3] := Byte((plainLen shr 24) and $FF);

  tag := Hmac2(kMac, iv, ConcatB(lenB, outTmp));

  SetLength(OutCipher, VDB_IV_LEN + 4 + padded + VDB_TAG_LEN);
  Move(iv[0], OutCipher[0], VDB_IV_LEN);
  Move(lenB[0], OutCipher[VDB_IV_LEN], 4);
  Move(outTmp[0], OutCipher[VDB_IV_LEN + 4], padded);
  Move(tag[0], OutCipher[VDB_IV_LEN + 4 + padded], VDB_TAG_LEN);


  FillChar(kEnc[0], Length(kEnc), 0);
  FillChar(kMac[0], Length(kMac), 0);
  Result := True;
end;

function VDbCryptDecrypt(const Key, Cipher: TBytes;
  out OutPlain: TBytes): Boolean;
var
  kEnc, kMac, body, tag, beklenen, lenB, outTmp: TBytes;
  aes: TDCP_rijndael;
  ccls: TTDCP_rijndaelClass;
  plainLen, padded: LongWord;
  p, n: Integer;
  blkIn, blkOut: array[0..15] of Byte;
  ivComp: array[0..15] of Byte;
  kEncStat: array[0..VDB_KEY_LEN - 1] of Byte;
  bodyOff: Integer;
begin
  OutPlain := nil;
  if Length(Cipher) < VDB_IV_LEN + 4 + 16 + VDB_TAG_LEN then
    raise EVdbCryptError.Create('sifreli kayit cok kisa (' +
      IntToStr(Length(Cipher)) + ' bayt)', VDB_CRYPTO_ERR);
  DeriveKeys(Key, kEnc, kMac);

  SetLength(lenB, 4);
  Move(Cipher[VDB_IV_LEN], lenB[0], 4);
  bodyOff := VDB_IV_LEN + 4;
  padded := LongWord(Length(Cipher) - bodyOff - VDB_TAG_LEN);

  SetLength(body, padded);
  Move(Cipher[bodyOff], body[0], padded);
  SetLength(tag, VDB_TAG_LEN);
  Move(Cipher[Length(Cipher) - VDB_TAG_LEN], tag[0], VDB_TAG_LEN);

  { ONCE ETIKETI DOGRULA - cozme bu kontrolun ALTINDA kalir.
    Duz metin uzunlugu da dahil HICBIR kayit alani etiket
    dogrulanmadan once kullanilmaz veya guvenilir sayilmaz. Aksi
    halde bir saldirgan etiketi hiccettirmeden "kayit uzunlugu
    tutarsiz" gibi ayirt edilebilir bir hata tetikleyebilir. }
  beklenen := Hmac2(kMac, Copy(Cipher, 0, VDB_IV_LEN),
    ConcatB(lenB, body));
  if not VDbCryptEqual(beklenen, tag) then
  begin
    FillChar(kEnc[0], Length(kEnc), 0);
    FillChar(kMac[0], Length(kMac), 0);
    raise EVdbCryptError.Create('kimlik dogrulama BASARISIZ - anahtar ' +
      'yanlis veya veri bozulmus', VDB_CRYPTO_ERR);
  end;

  { etiket gecti: duz metin uzunlugu artik guvenle cozulebilir }
  plainLen := LongWord(lenB[0]) or (LongWord(lenB[1]) shl 8) or
              (LongWord(lenB[2]) shl 16) or (LongWord(lenB[3]) shl 24);
  if plainLen > padded then
    raise EVdbCryptError.Create('kayit uzunlugu tutarsiz', VDB_CRYPTO_ERR);

  Move(Cipher[0], ivComp[0], VDB_IV_LEN);
  SetLength(outTmp, padded);
  ccls := TDCP_rijndael;
  aes := ccls.Create(nil);
  try
    { Sifrelemedeki ile ayni neden: open-array Key parametresine
      dinamik dizi verilemez, statik tampon kullanilir. }
    Move(kEnc[0], kEncStat[0], VDB_KEY_LEN);
    aes.Init(kEncStat, 256, @ivComp[0]);
    p := 0;
    while p < Integer(padded) do
    begin
      n := Integer(padded) - p;
      if n > 16 then n := 16;
      dcpFillChar(blkIn, SizeOf(blkIn), 0);
      dcpFillChar(blkOut, SizeOf(blkOut), 0);
      Move(body[p], blkIn[0], n);
      aes.DecryptCTR(blkIn[0], blkOut[0], 16);
      Move(blkOut[0], outTmp[p], n);
      Inc(p, 16);
    end;
  finally
    aes.Free;
  end;
  SetLength(OutPlain, plainLen);
  if plainLen > 0 then
    Move(outTmp[0], OutPlain[0], plainLen);


  FillChar(kEnc[0], Length(kEnc), 0);
  FillChar(kMac[0], Length(kMac), 0);
  Result := True;
end;

function VDbDapiProtect(const Data: TBytes; out OutBlob: TBytes): Boolean;
{$IFDEF MSWINDOWS}
var
  inBl, outBl: DATA_BLOB;
{$ENDIF}
begin
  OutBlob := nil;
  if Length(Data) = 0 then
    raise EVdbCryptError.Create('DPAPI: bos veri korunamaz', VDB_CRYPTO_ERR);
{$IFDEF MSWINDOWS}
  inBl.cbData := DWORD(Length(Data));
  inBl.pbData := @Data[0];
  FillChar(outBl, SizeOf(outBl), 0);
  if not CryptProtectData(@inBl, 'VDB anahtar', nil, nil, nil,
    CRYPTPROTECT_UI_FORBIDDEN, @outBl) then
    raise EVdbCryptError.Create('DPAPI koruma basarisiz (Win32 ' +
      IntToStr(GetLastError) + ')', GetLastError);
  try
    SetLength(OutBlob, outBl.cbData);
    if outBl.cbData > 0 then
      Move(outBl.pbData^, OutBlob[0], outBl.cbData);
  finally
    if outBl.pbData <> nil then LocalFree(HLOCAL(outBl.pbData));
  end;
  Result := True;
{$ELSE}
  { R-23: Unix'te DPAPI YOK. Kimlik kopyasi doner; sirri asil parola +
    PBKDF2 ve `.key` dosya izinleri (0600) korur. }
  OutBlob := Copy(Data, 0, Length(Data));
  Result := True;
{$ENDIF}
end;

function VDbDapiUnprotect(const Blob: TBytes; out OutData: TBytes): Boolean;
{$IFDEF MSWINDOWS}
var
  inBl, outBl: DATA_BLOB;
  descr: PChar;
{$ENDIF}
begin
  OutData := nil;
  if Length(Blob) = 0 then
    raise EVdbCryptError.Create('DPAPI: bos korumali veri acilamaz',
      VDB_CRYPTO_ERR);
{$IFDEF MSWINDOWS}
  inBl.cbData := DWORD(Length(Blob));
  inBl.pbData := @Blob[0];
  FillChar(outBl, SizeOf(outBl), 0);
  descr := nil;
  if not CryptUnprotectData(@outBl, @descr, nil, nil, nil,
    CRYPTPROTECT_UI_FORBIDDEN, @inBl) then
    raise EVdbCryptError.Create('DPAPI acma basarisiz (Win32 ' +
      IntToStr(GetLastError) + ') - anahtar dosyasi baska kullaniciya ' +
      'veya makineye ait olabilir', GetLastError);
  try
    SetLength(OutData, outBl.cbData);
    if outBl.cbData > 0 then
      Move(outBl.pbData^, OutData[0], outBl.cbData);
  finally
    if descr <> nil then LocalFree(HLOCAL(descr));
    if outBl.pbData <> nil then LocalFree(HLOCAL(outBl.pbData));
  end;
  Result := True;
{$ELSE}
  { R-23: Unix kimlik kopyasi (bkz. VDbDapiProtect). }
  OutData := Copy(Blob, 0, Length(Blob));
  Result := True;
{$ENDIF}
end;

end.
