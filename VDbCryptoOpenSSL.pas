unit VDbCryptoOpenSSL;
{ VDbCryptoOpenSSL - BIRINCIL kripto provider'i (CRYPTO_ADR K1/K6).

  Dinamik YUKLEME KALIBI VDbTls.pas'in birebir tekrarinidir (ADR K6):
  LoadLibrary + GetProcAddress ile sembol baglama, hepsi-bir-arada
  sembol dogrulamasi (biri eksik -> kutuphane geri birakilir, temiz
  hata), init-once + kilit, VDB_CRYPTO_DLL ortam degiskeni asgari.
  Fark: YALNIZ libcrypto yuklenir; libssl'e DOKUNULMAZ (crypto icin
  gerekli degil; TLS kanali ayrica VDbTls'de yasiyor).

  DENENEN DOSYA ADALARI (Windows):
    libcrypto-3.dll (OpenSSL 3.x) -> libcrypto-1_1.dll (1.1.x) ->
    libeay32.dll (1.0.2 miras adlandirmasi)
  Linux: libcrypto.so.3 / libcrypto.so.1.1 / libcrypto.so
  macOS: libcrypto.3.dylib / libcrypto.1.1.dylib / libcrypto.dylib
  VDB_CRYPTO_DLL setilmisse ONCE o denenir (VDbTls'teki VDB_SSL_DLL/
  VDB_CRYPTO_DLL kanalinin karsiligi).

  SURUM MATRISI (K6 - baglayici): crypto provider OpenSSL >= 1.1.0
  gerektirir. 1.0.2 hatti YALNIZ TLS'te mirastir (VDbTls.pas:6-8);
  crypto 1.0.2'yi REDDEDER: EVP_CIPHER_CTX_new (>=1.1) oncesi statik
  context API farki hata yuzeyini buyutur. Kontrol: OpenSSL_version_num
  sembolu varsa donen deger < 0x01010000 -> ret; sembol YOKSA eski
  adlandirma (libeay32) 1.0.x kabul edilip YINE reddedilir - dokumante
  edilmis davranistir (K6 matrisi + gorev kilavuzu).

  SEMBOL KUMESI (K6 listesi + kanitlanmis zorunlu ekler - SAPMA):
    EVP_aes_256_gcm, EVP_CIPHER_CTX_new/free/reset,
    EVP_EncryptInit_ex/EncryptUpdate/EncryptFinal_ex,
    EVP_DecryptInit_ex/DecryptUpdate/DecryptFinal_ex,
    EVP_CIPHER_CTX_ctrl (SET_IVLEN / SET_TAG / GET_TAG),
    HMAC, PKCS5_PBKDF2_HMAC, RAND_bytes
    EK 1: EVP_sha256 - HMAC() ve PKCS5_PBKDF2_HMAC() "md" parametresi
      olmadan CALISAMAZ; K6 listesi HMAC/PBKDF2'yi adlandiriyor ama
      md secici sembolu adli gecirmiyor. libcrypto ici, tum surumlerde
      sabit.
    EK 2: EVP_Digest - saglanacak HashSHA256 (duz SHA-256) primitif
      girisi K6 listesinde HIC yok; HMAC(), bos anahtarla bile,
      tanim geregi HMAC uretir, duz SHA-256 DEGILDIR. EVP_Digest
      OpenSSL 1.1/3.x'in modern tek-atimlik hash yoludur.
    EK 3: ERR_get_error + ERR_error_string_n - temiz hata metni
      (VDbTls de bu ikisini zorunlu sayiyor).
    EK 4: OpenSSL_version_num - K6 surum kapisi (sembol opsiyonel:
      yoksa 1.0.x sayilir ve ret edilir).

  GCM AKISI (klasik tuzak - EVP_CTRL_GCM_* siralamasi):
    sifreleme: Init_ex(cipher) -> ctrl(SET_IVLEN) -> Init_ex(key,iv)
      -> Update(AAD, out=NULL) -> Update(pt) -> Final_ex -> ctrl(GET_TAG)
    sifre-cozme: Init_ex(cipher) -> ctrl(SET_IVLEN) -> Init_ex(key,iv)
      -> Update(AAD, out=NULL) -> Update(ct) -> ctrl(SET_TAG,tag)
      -> Final_ex  <-- TAG FINAL_ONCESI GIRMELI; aksi halde dogrulama
      hic yapilmaz ve yanlis anahtar sessizce kabul edilir.
      Final_ex <= 0 => tag reddi => False (plain sirfirlanir).
  Bu dosya HICBIR kripto primitifi YAZMAZ (skill 0.4): salt OpenSSL
  EVP cagrilari.

  DLL YOK / sembol eksik / 1.0.2 -> IsAvailable False + hata mesaji
  DENENEN dosya adlarini ve VDB_CRYPTO_DLL ipucunu soyler. Sessiz
  fallback YOK: builtin kendiliginden devreye girmez (K6). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  VDbCryptoTypes, VDbCryptoProvider;

type
  TVDbCryptoOpenSSLProvider = class(TVDbCryptoProvider)
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
    function Pbkdf2Sha256(const Pass, Salt: TBytes; Iter, DkLen: Integer): TBytes;
      override;
    function RandomBytes(out Buf: TBytes; ALen: Integer): Boolean; override;
    function SelfTest(out ALog: string): Boolean; override;
  end;

{ libcrypto'yu baglar / bagli oldugunu bildirir (init-once + kilit,
  VDbTls InitLibs kalibi). Basarisizlikta AErr: "OpenSSL crypto
  kullanilamiyor... denen: ... ; VDB_CRYPTO_DLL ...". }
function VDbCryptoOpenSSLInit(out AErr: string): Boolean;

{ Bagli ise surum numarasinin hex karsiligi ('' = henuz bagli degil).
  Raporlama/log amacli; sifir secret icermez. }
function VDbCryptoOpenSSLVersion: string;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF} dynlibs,
  VDbCryptoSelfTest;

const
  { EVP_CTRL_AEAD_* (eski adi EVP_CTRL_GCM_*; ayni degerler, >=1.1) }
  EVP_CTRL_AEAD_SET_IVLEN = $9;
  EVP_CTRL_AEAD_GET_TAG   = $10;
  EVP_CTRL_AEAD_SET_TAG   = $11;

  { K6 surum kapisi: OpenSSL_VERSION_NUMBER = 0xMNNFFPPS; >= 1.1.0 }
  OPENSSL_MIN_CRYPTO_VER = $01010000;

type
  {$IFDEF CPU64BIT}
  TOpenSslVer = QWord;
  {$ELSE}
  TOpenSslVer = LongWord;   { win32'de unsigned long = 32 bit }
  {$ENDIF}

  TfnEvpCipher = function: Pointer; cdecl;
  TfnCtxNew = function: Pointer; cdecl;
  TfnCtxFree = procedure(ACtx: Pointer); cdecl;
  TfnCtxReset = function(ACtx: Pointer): Integer; cdecl;
  TfnCryptInit = function(ACtx, ACipher, AImpl: Pointer;
    AKey, AIv: PByte): Integer; cdecl;
  TfnCryptUpdate = function(ACtx, AOut: PByte; AOutLen: PInteger;
    AIn: PByte; AInLen: Integer): Integer; cdecl;
  TfnCryptFinal = function(ACtx, AOut: PByte; AOutLen: PInteger): Integer; cdecl;
  TfnCtxCtrl = function(ACtx: Pointer; ACommand, AParm: Integer;
    AArg: Pointer): Integer; cdecl;
  TfnDigest = function(AData: PByte; ACount: NativeUInt; AMd: PByte;
    AMdLen: PInteger; AEvpMd: Pointer; AImpl: Pointer): Integer; cdecl;
  TfnHmac = function(AEvpMd: Pointer; AKey: PByte; AKeyLen: Integer;
    AData: PByte; AN: NativeUInt; ADigest: PByte;
    ADigestLen: PInteger): Pointer; cdecl;
  TfnPbkdf2 = function(APass: PByte; APassLen: Integer; ASalt: PByte;
    ASaltLen, AIter: Integer; AEvpMd: Pointer; ADkLen: Integer;
    ADk: PByte): Integer; cdecl;
  TfnRandBytes = function(ABuf: PByte; ALen: Integer): Integer; cdecl;
  TfnVersionNum = function: TOpenSslVer; cdecl;
  { ERR_get_error/ERR_error_string_n: unsigned long ABI'si - Windows'ta
    (win32 ve win64) 32 bittir; kodlar 32 bite sigar. }
  TfnErrGetError = function: LongWord; cdecl;
  TfnErrString = procedure(AErr: LongWord; ABuf: PAnsiChar;
    ALen: NativeUInt); cdecl;

var
  GLock: SyncObjs.TCriticalSection;
  GInitDone: Boolean;
  GInitOk: Boolean;
  GInitErr: string;
  GLibHandle: TLibHandle = NilHandle;
  GVersion: string;

  GEvpAes256Gcm: TfnEvpCipher;
  GEvpSha256: TfnEvpCipher;
  GCtxNew: TfnCtxNew;
  GCtxFree: TfnCtxFree;
  GCtxReset: TfnCtxReset;
  GEncryptInit, GDecryptInit: TfnCryptInit;
  GEncryptUpdate, GDecryptUpdate: TfnCryptUpdate;
  GEncryptFinal, GDecryptFinal: TfnCryptFinal;
  GCtxCtrl: TfnCtxCtrl;
  GDigest: TfnDigest;
  GHmac: TfnHmac;
  GPbkdf2: TfnPbkdf2;
  GRandBytes: TfnRandBytes;
  GVersionNum: TfnVersionNum;
  GErrGetError: TfnErrGetError;
  GErrString: TfnErrString;

{ OpenSSL'un birikmis son hatasini metne cevirir (VDbTls kalibi). }
function LastOpenSslError: string;
var
  e: LongWord;
  buf: array[0..255] of AnsiChar;
begin
  Result := '';
  if not Assigned(GErrGetError) then Exit;
  e := GErrGetError();
  if (e = 0) or (not Assigned(GErrString)) then Exit;
  FillChar(buf, SizeOf(buf), 0);
  GErrString(e, @buf[0], SizeOf(buf) - 1);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
end;

function CandidateNames: TStringList;
begin
  Result := TStringList.Create;
  {$IFDEF WINDOWS}
  Result.Add('libcrypto-3.dll');
  Result.Add('libcrypto-1_1.dll');
  Result.Add('libeay32.dll');
  {$ENDIF}
  {$IFDEF LINUX}
  Result.Add('libcrypto.so.3');
  Result.Add('libcrypto.so.1.1');
  Result.Add('libcrypto.so');
  {$ENDIF}
  {$IFDEF DARWIN}
  Result.Add('libcrypto.3.dylib');
  Result.Add('libcrypto.1.1.dylib');
  Result.Add('libcrypto.dylib');
  {$ENDIF}
end;

function LoadCrypto(const AName: string; out AErr: string): Boolean;
var
  h: TLibHandle;
  ver: TOpenSslVer;
  verKnown: Boolean;

  function Sym(const AName: string): Pointer;
  begin
    Result := GetProcAddress(h, PAnsiChar(AnsiString(AName)));
  end;

  procedure Drop;
  begin
    if h <> NilHandle then
    begin
      UnloadLibrary(h);
      h := NilHandle;
    end;
  end;

begin
  Result := False;
  AErr := '';
  h := LoadLibrary(AName);
  if h = NilHandle then
  begin
    AErr := AName + ' yuklenemedi: ' + GetLoadErrorStr;
    Exit;
  end;

  GEvpAes256Gcm  := TfnEvpCipher(Sym('EVP_aes_256_gcm'));
  GEvpSha256     := TfnEvpCipher(Sym('EVP_sha256'));
  GCtxNew        := TfnCtxNew(Sym('EVP_CIPHER_CTX_new'));
  GCtxFree       := TfnCtxFree(Sym('EVP_CIPHER_CTX_free'));
  GCtxReset      := TfnCtxReset(Sym('EVP_CIPHER_CTX_reset'));
  GEncryptInit   := TfnCryptInit(Sym('EVP_EncryptInit_ex'));
  GEncryptUpdate := TfnCryptUpdate(Sym('EVP_EncryptUpdate'));
  GEncryptFinal  := TfnCryptFinal(Sym('EVP_EncryptFinal_ex'));
  GDecryptInit   := TfnCryptInit(Sym('EVP_DecryptInit_ex'));
  GDecryptUpdate := TfnCryptUpdate(Sym('EVP_DecryptUpdate'));
  GDecryptFinal  := TfnCryptFinal(Sym('EVP_DecryptFinal_ex'));
  GCtxCtrl       := TfnCtxCtrl(Sym('EVP_CIPHER_CTX_ctrl'));
  GDigest        := TfnDigest(Sym('EVP_Digest'));
  GHmac          := TfnHmac(Sym('HMAC'));
  GPbkdf2        := TfnPbkdf2(Sym('PKCS5_PBKDF2_HMAC'));
  GRandBytes     := TfnRandBytes(Sym('RAND_bytes'));
  GErrGetError   := TfnErrGetError(Sym('ERR_get_error'));
  GErrString     := TfnErrString(Sym('ERR_error_string_n'));
  GVersionNum    := TfnVersionNum(Sym('OpenSSL_version_num'));

  if (not Assigned(GEvpAes256Gcm)) or (not Assigned(GEvpSha256)) or
     (not Assigned(GCtxNew)) or (not Assigned(GCtxFree)) or
     (not Assigned(GCtxReset)) or (not Assigned(GEncryptInit)) or
     (not Assigned(GEncryptUpdate)) or (not Assigned(GEncryptFinal)) or
     (not Assigned(GDecryptInit)) or (not Assigned(GDecryptUpdate)) or
     (not Assigned(GDecryptFinal)) or (not Assigned(GCtxCtrl)) or
     (not Assigned(GDigest)) or (not Assigned(GHmac)) or
     (not Assigned(GPbkdf2)) or (not Assigned(GRandBytes)) or
     (not Assigned(GErrGetError)) or (not Assigned(GErrString)) then
  begin
    AErr := AName + ': gerekli libcrypto sembolleri eksik (crypto icin ' +
      'OpenSSL >= 1.1 gerekir - 1.0.2 desteklenmiyor, K6 matrisi)';
    Drop;
    Exit;
  end;

  { K6 surum kapisi. OpenSSL_version_num yoksa eski adlandirma 1.0.x
    sayilir ve reddedilir (dokumante edilmis davranis). }
  verKnown := Assigned(GVersionNum);
  if verKnown then ver := GVersionNum() else ver := 0;
  if (not verKnown) or (ver < OPENSSL_MIN_CRYPTO_VER) then
  begin
    if verKnown then
      AErr := AName + ': OpenSSL surumu 0x' + IntToHex(Int64(ver), 8) +
        ' - crypto provider >= 1.1.0 ister (K6); 1.0.2 yalniz TLS mirasi'
    else
      AErr := AName + ': OpenSSL_version_num yok - 1.0.x adlandirmasi ' +
        'crypto icin desteklenmiyor (K6; >= 1.1 gerekir)';
    Drop;
    Exit;
  end;

  GVersion := '0x' + IntToHex(Int64(ver), 8);
  GLibHandle := h;
  Result := True;
end;

function VDbCryptoOpenSSLInit(out AErr: string): Boolean;
var
  err, envCrypto, tried, names: string;
  i: Integer;
  lst: TStringList;
begin
  if GInitDone then
  begin
    Result := GInitOk;
    AErr := '';
    if not GInitOk then AErr := GInitErr;
    Exit;
  end;
  GLock.Enter;
  try
    if GInitDone then
    begin
      Result := GInitOk;
      AErr := '';
      if not GInitOk then AErr := GInitErr;
      Exit;
    end;
    GInitDone := True;
    GInitOk := False;
    tried := '';
    envCrypto := SysUtils.GetEnvironmentVariable('VDB_CRYPTO_DLL');
    if envCrypto <> '' then
      if LoadCrypto(envCrypto, err) then
      begin
        GInitOk := True;
        AErr := '';
        Exit(True);
      end
      else
        tried := envCrypto + ' (' + err + ')';
    lst := CandidateNames;
    try
      for i := 0 to lst.Count - 1 do
        if LoadCrypto(lst[i], err) then
        begin
          GInitOk := True;
          AErr := '';
          Exit(True);
        end
        else
        begin
          if tried <> '' then tried := tried + '; ';
          tried := tried + lst[i] + ' (' + err + ')';
        end;
    finally
      lst.Free;
    end;
    names := '';
    if envCrypto <> '' then names := envCrypto;
    lst := CandidateNames;
    try
      for i := 0 to lst.Count - 1 do
      begin
        if names <> '' then names := names + ', ';
        names := names + lst[i];
      end;
    finally
      lst.Free;
    end;
    GInitErr := 'OpenSSL crypto kullanilamiyor; crypto KAPALI. denen: ' +
      tried + '. VDB_CRYPTO_DLL ortam degiskenini libcrypto dosyasinin ' +
      'tam yoluna ayarlayin (beklenen adlar: ' + names + '; 32-bit build ' +
      'icin 32-bit DLL gerekir). Sessiz builtin fallback yoktur (K6).';
    GInitOk := False;
    AErr := GInitErr;
    Result := False;
  finally
    GLock.Leave;
  end;
end;

function VDbCryptoOpenSSLVersion: string;
begin
  Result := GVersion;
end;

{ ------------------------------ yardimcilar ----------------------------- }

procedure RequireCrypto;
var
  e: string;
begin
  if not VDbCryptoOpenSSLInit(e) then
    raise EVdbCryptoError.Create('OpenSSL provider hazir degil: ' + e,
      VDB_CRYPTO_E_PROVIDER);
end;

{ OpenSSL cagrisi hata dondu - ortam hatasi, veri hatasi DEGIL. }
procedure OsslFail(const AWhat: string);
begin
  raise EVdbCryptoError.Create('OpenSSL ' + AWhat + ' basarisiz: ' +
    LastOpenSslError, VDB_CRYPTO_E_INTERNAL);
end;

function PtrOf(const B: TBytes): PByte;
begin
  if Length(B) > 0 then Result := @B[0] else Result := nil;
end;

{ ------------------------------ provider -------------------------------- }

function TVDbCryptoOpenSSLProvider.Name: string;
begin
  Result := VDB_PROVIDER_OPENSSL;
end;

function TVDbCryptoOpenSSLProvider.Capabilities: TVDbCryptoCaps;
begin
  { capArgon2id YOK (K6: OpenSSL 1.1/3.0-3.1'de Argon2 yok; >=3.2
    EVP_KDF cross-check'i ancak opsiyonel - K3 referansi VDbKdf).
    capAes256Block YOK: K6 sembol setine ECB eklenmedi (sapma
    istememek icin); AES-256 cekirdegi OpenSSL tarafinda GCM
    vektorleriyle kaplidir. }
  Result := [capHash, capHmac, capHmacKeyOver64, capAead, capPbkdf2,
    capRandom];
end;

function TVDbCryptoOpenSSLProvider.IsAvailable(out AErr: string): Boolean;
begin
  Result := VDbCryptoOpenSSLInit(AErr);
end;

function TVDbCryptoOpenSSLProvider.HashSHA256(const Data: TBytes): TBytes;
var
  n: Integer;
begin
  RequireCrypto;
  SetLength(Result, VDB_HASH_SHA256_LEN);
  n := 0;
  if GDigest(Pointer(Data), NativeUInt(Length(Data)), @Result[0], @n,
    GEvpSha256(), nil) <> 1 then
    OsslFail('EVP_Digest(SHA-256)');
end;

function TVDbCryptoOpenSSLProvider.HmacSHA256(const Key, Data: TBytes): TBytes;
var
  n: Integer;
begin
  RequireCrypto;
  SetLength(Result, VDB_HASH_SHA256_LEN);
  n := 0;
  if GHmac(GEvpSha256(), PtrOf(Key), Length(Key), PtrOf(Data),
    NativeUInt(Length(Data)), @Result[0], @n) = nil then
    OsslFail('HMAC-SHA256');
end;

{ GCM islem govdesi - AeadSeal/AeadOpen ortak kurulumu. }
function GcmRun(AProvider: TVDbCryptoOpenSSLProvider; AEncrypt: Boolean;
  const Key, Nonce, InData, Aad, InTag: TBytes;
  out OutData, OutTag: TBytes): Boolean;
var
  ctx: Pointer;
  outl, total, n: Integer;
  scratch: array[0..31] of Byte;
  tag: array[0..15] of Byte;

  procedure Cleanup;
  begin
    if (ctx <> nil) and Assigned(GCtxFree) then
      GCtxFree(ctx);
    ctx := nil;
  end;

begin
  Result := False;
  OutData := nil;
  OutTag := nil;
  { Savunma guard'lari: VDbCryptGcmSeal/Open sozlesmesiyle birebir -
    gecersiz uzunluk False, exception DEGIL (kat_runner seal'i). }
  if (Length(Key) <> VDB_KEY_LEN) or (Length(Nonce) <> VDB_AEAD_NONCE_LEN) then
    Exit;
  if (not AEncrypt) and (Length(InTag) <> VDB_AEAD_TAG_LEN) then
    Exit;

  RequireCrypto;
  ctx := GCtxNew();
  if ctx = nil then
    OsslFail('EVP_CIPHER_CTX_new');
  try
    { 1) cipher atamasi }
    if AEncrypt then
    begin
      if GEncryptInit(ctx, GEvpAes256Gcm(), nil, nil, nil) <> 1 then
        OsslFail('EVP_EncryptInit_ex(cipher)');
      { 2) IV uzunlugu }
      if GCtxCtrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, Length(Nonce), nil) <> 1 then
        OsslFail('EVP_CTRL_GCM_SET_IVLEN');
      { 3) anahtar + iv }
      if GEncryptInit(ctx, nil, nil, PtrOf(Key), PtrOf(Nonce)) <> 1 then
        OsslFail('EVP_EncryptInit_ex(key,iv)');
      { 4) AAD - out=NULL triginin (outl doner, veri islenmez) }
      if Length(Aad) > 0 then
      begin
        if GEncryptUpdate(ctx, nil, @outl, PtrOf(Aad), Length(Aad)) <> 1 then
          OsslFail('EVP_EncryptUpdate(AAD)');
      end;
      { 5) veri }
      SetLength(OutData, Length(InData));
      total := 0;
      if Length(InData) > 0 then
      begin
        if GEncryptUpdate(ctx, @OutData[0], @outl, PtrOf(InData),
          Length(InData)) <> 1 then
          OsslFail('EVP_EncryptUpdate(pt)');
        total := outl;
      end;
      { 6) final (GCM: 0 bayt; blok boyu kadar tampon istenir) }
      FillChar(scratch, SizeOf(scratch), 0);
      if GEncryptFinal(ctx, @scratch[0], @outl) <> 1 then
        OsslFail('EVP_EncryptFinal_ex');
      Inc(total, outl);
      if total <> Length(InData) then
      begin
        SetLength(OutData, total);
      end;
      { 7) TAG SONRADAN ALINIR }
      SetLength(OutTag, VDB_AEAD_TAG_LEN);
      if GCtxCtrl(ctx, EVP_CTRL_AEAD_GET_TAG, VDB_AEAD_TAG_LEN,
        @OutTag[0]) <> 1 then
        OsslFail('EVP_CTRL_GCM_GET_TAG');
    end
    else
    begin
      if GDecryptInit(ctx, GEvpAes256Gcm(), nil, nil, nil) <> 1 then
        OsslFail('EVP_DecryptInit_ex(cipher)');
      if GCtxCtrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, Length(Nonce), nil) <> 1 then
        OsslFail('EVP_CTRL_GCM_SET_IVLEN');
      if GDecryptInit(ctx, nil, nil, PtrOf(Key), PtrOf(Nonce)) <> 1 then
        OsslFail('EVP_DecryptInit_ex(key,iv)');
      if Length(Aad) > 0 then
      begin
        if GDecryptUpdate(ctx, nil, @outl, PtrOf(Aad), Length(Aad)) <> 1 then
          OsslFail('EVP_DecryptUpdate(AAD)');
      end;
      SetLength(OutData, Length(InData));
      total := 0;
      if Length(InData) > 0 then
      begin
        if GDecryptUpdate(ctx, @OutData[0], @outl, PtrOf(InData),
          Length(InData)) <> 1 then
          OsslFail('EVP_DecryptUpdate(ct)');
        total := outl;
      end;
      { 6) TAG FINAL-DEKLENIR - GCM'in klasik tuzagi; siralama yanlis
         ise dogrulama hic yapilmaz. }
      FillChar(tag, SizeOf(tag), 0);
      Move(InTag[0], tag[0], VDB_AEAD_TAG_LEN);
      if GCtxCtrl(ctx, EVP_CTRL_AEAD_SET_TAG, VDB_AEAD_TAG_LEN,
        @tag[0]) <> 1 then
        OsslFail('EVP_CTRL_GCM_SET_TAG');
      { 7) final - tag mismatch burada <=0 doner }
      FillChar(scratch, SizeOf(scratch), 0);
      n := GDecryptFinal(ctx, @scratch[0], @outl);
      if n <> 1 then
      begin
        { tag reddi: plain ASLA aciga cikmaz (BASELINE 5 satir 76
          davranisiyla ayni: tek temiz red). }
        FillChar(OutData[0], Length(OutData), 0);
        SetLength(OutData, 0);
        Cleanup;
        Exit(False);
      end;
      Inc(total, outl);
      if total <> Length(InData) then
        SetLength(OutData, total);
    end;
    Cleanup;
    Result := True;
  except
    FillChar(scratch, SizeOf(scratch), 0);
    OutData := nil;
    OutTag := nil;
    Cleanup;
    raise;
  end;
end;

function TVDbCryptoOpenSSLProvider.AeadSeal(const Key, Nonce, Plain,
  Aad: TBytes; out Cipher, Tag: TBytes): Boolean;
begin
  Result := GcmRun(Self, True, Key, Nonce, Plain, Aad, nil, Cipher, Tag);
end;

function TVDbCryptoOpenSSLProvider.AeadOpen(const Key, Nonce, Cipher, Tag,
  Aad: TBytes; out Plain: TBytes): Boolean;
var
  dummy: TBytes;
begin
  Result := GcmRun(Self, False, Key, Nonce, Cipher, Aad, Tag, Plain, dummy);
end;

function TVDbCryptoOpenSSLProvider.Pbkdf2Sha256(const Pass, Salt: TBytes;
  Iter, DkLen: Integer): TBytes;
begin
  if (Iter < 1) or (DkLen < 1) then
    raise EVdbCryptoError.Create('PBKDF2: gecersiz parametre',
      VDB_CRYPTO_E_INPUT);
  RequireCrypto;
  SetLength(Result, DkLen);
  if GPbkdf2(PtrOf(Pass), Length(Pass), PtrOf(Salt), Length(Salt), Iter,
    GEvpSha256(), DkLen, @Result[0]) <> 1 then
    OsslFail('PKCS5_PBKDF2_HMAC');
end;

function TVDbCryptoOpenSSLProvider.RandomBytes(out Buf: TBytes;
  ALen: Integer): Boolean;
begin
  Buf := nil;
  if ALen < 0 then
    raise EVdbCryptoError.Create('rastgele: negatif uzunluk',
      VDB_CRYPTO_E_INPUT);
  SetLength(Buf, ALen);
  if ALen = 0 then Exit(True);
  RequireCrypto;
  { RAND_bytes 1 basari; <=0 hata - fail-closed, OS yoluna SESSIZ
    gecilmez (K6). Cagiran istersen VDbCryptoOsRandomBytes'i acikca
    kendisi secer. }
  if GRandBytes(@Buf[0], ALen) <> 1 then
  begin
    FillChar(Buf[0], ALen, 0);
    Buf := nil;
    OsslFail('RAND_bytes');
  end;
  Result := True;
end;

function TVDbCryptoOpenSSLProvider.SelfTest(out ALog: string): Boolean;
begin
  Result := VDbCryptoSelfTestRun(Self, ALog);
end;

initialization
  GLock := SyncObjs.TCriticalSection.Create;
  VDbCryptoRegisterProviderClass(VDB_PROVIDER_OPENSSL,
    TVDbCryptoOpenSSLProvider);

finalization
  if GLibHandle <> NilHandle then
  begin
    UnloadLibrary(GLibHandle);
    GLibHandle := NilHandle;
  end;
  GLock.Free;

end.
