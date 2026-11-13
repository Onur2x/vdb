unit VDbCryptoProvider;
{ VDbCryptoProvider - kripto provider sozlesmesi ve secim API'si
  (CRYPTO_ADR K1/K6 - Adim 1; INVENTORY parca 6).

  SOZLESME TERCIH (kayitli karar): provider sozlesmesi SOYUT SINIF
  (vtable) olarak kuruldu; fonksiyon-pointer kaydi (el yazimi vtable)
  secilmedi. Gerekce: (a) proje genelinde sinif kalibi yaygin
  (VDbTlsContext, EVdbException...), (b) FPC sanal metot cagrisi
  zaten vtable'dir - ek bir katman degildir, (c) yeni yetenek
  eklemek sanal metot + cap bayragi ile temiz sekilde olur, fonk
  pointer kaydinda her yeni alan tum tasiyicilarda elle senkron
  ister.

  SECIM KURALI (SAHIB KARARI R-5 / ADR EK-B, 2026-11-13 - K1'in
  "OpenSSL birincil" onceligini DEGISTIRDI; skill 3.1 satir 81'in
  "otomatik/gizli fallback YOK" kurali hala yururlukte):
  VARSAYILAN provider = BUILTIN (saf Pascal, sifir harici DLL;
  readme.md:3-4 sozu). VDbCryptoOpenSSL yalniz ACIK OPT-IN'dir:
    (a) VDbCryptoSelectProvider(VDB_PROVIDER_OPENSSL) cagrisi, VEYA
    (b) VDB_CRYPTO_PROVIDER=openssl ortam degiskeni (esdeger opt-in;
        VDbCrypt facade'i ilk primitif cagrisinda bir kez cozumler).
  OpenSSL ACIKCA secildi de kullanilamiyorsa secim BASARISIZ OLUR ve
  denen DLL adlarini + VDB_CRYPTO_DLL ipucunu soyleyen temiz hata
  doner - sessiz builtin dususu YOK (K6). Acik secim olmadikca
  OpenSSL DLL'i hic aranmaz/yuklenmez (R-5/b).

  ADIM 1 KAPSAM NOTU (ADR 3 adim 1 = "dual path, henuz hicbir caller
  tasinmaz"): sozlesme Adim 1'in gerektirdigi kadardir - Hash/Hmac/
  Aead/Pbkdf2/Random/Argon2id/SelfTest/Capabilities. ADR K1'in tam
  listesindeki AesCbcLegacyDecrypt (salt-okunur legacy) ve facade'in
  provider'a baglanmasi Adim 2'de (VDbCrypt.pas implementasyon baglari)
  gelir; o adimda buraya sanal metot eklemek breaking change degildir
  cunku henuz dis cagiran yok.

  Argon2id burada bulunur cunku K3 yeni yazimlarin TEK KDF'ini
  Argon2id yapar ve OpenSSL 1.1/3.0-3.1'de Argon2 YOKTUR (K6 destek
  matrisi); builtin VDbKdf referansina devreder, OpenSSL desteklemez
  (capArgon2id yok). VDbCryptoKdf ayr birim olarak Adim 2/3'te gelir. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  VDbCryptoTypes;

type
  TVDbCryptoProvider = class;
  TVDbCryptoProviderClass = class of TVDbCryptoProvider;

  { Her yonten ham primitif seviyesindedir; zar sarma (VDBAEAD1 magic,
    sayfa AAD'si) FACADE isidir, provider isi degildir.
    Sozlesme:
      - Hata durumlarinda ya False doner (AEAD dogrulama reddi gibi
        "verinin kendisi" hatalari) ya EVdbCryptoError firlatir
        (ortam/destek hatalari). Hangisi oldugu her metotta yazili.
      - Cagiran taraf girdi uzunluklarini provider'a guvenerek degil,
        kendi sozlesmesine gore dogrular; provider yine de savunma
        amacli guard'lar (False, exception degil). }
  TVDbCryptoProvider = class abstract
  public
    { ASCII kisa ad - 'openssl' / 'builtin' (VDB_PROVIDER_* sabitleri) }
    function Name: string; virtual; abstract;
    function Capabilities: TVDbCryptoCaps; virtual; abstract;
    { Provider kullanim icin hazir mi? OpenSSL DLL baglama + surum
      kontrolu yapar; hazir degilse AErr denen adlari ve
      VDB_CRYPTO_DLL ipucunu icerir. Yan etkisi kaldirilamaz: init-once. }
    function IsAvailable(out AErr: string): Boolean; virtual; abstract;
    { Ham SHA-256; 32 bayt doner. Ortam hatasi yok (durum hatasi). }
    function HashSHA256(const Data: TBytes): TBytes; virtual; abstract;
    { HMAC-SHA256; 32 bayt. >64B anahtar: capHmacKeyOver64 yoksa
      EVdbCryptoError(UNSUPPORTED). }
    function HmacSHA256(const Key, Data: TBytes): TBytes; virtual; abstract;
    { AES-256-GCM ham seal: Cipher(=Plain boyu), Tag(16). Gecersiz
      uzunluk (key<>32, nonce<>12) -> False, exception DEGIL.
      Giris verisi hatasi olamaz; OpenSSL cagrisi basarisizsa
      EVdbCryptoError(INTERNAL). }
    function AeadSeal(const Key, Nonce, Plain, Aad: TBytes;
      out Cipher, Tag: TBytes): Boolean; virtual; abstract;
    { AES-256-GCM ham open. Tag/veri dogrulama reddi -> False +
      OutPlain bos (plain aciga cikmaz). Gecersiz uzunluk -> False. }
    function AeadOpen(const Key, Nonce, Cipher, Tag, Aad: TBytes;
      out Plain: TBytes): Boolean; virtual; abstract;
    { RFC 8018 PBKDF2-HMAC-SHA256. Iter/DkLen < 1 -> EVdbCryptoError(INPUT). }
    function Pbkdf2Sha256(const Pass, Salt: TBytes; Iter, DkLen: Integer): TBytes;
      virtual; abstract;
    { CSPRNG. Kaynak tuketilemez/bulunamamaz -> fail-closed
      EVdbCryptoError; asla zayif doldurma yapmaz. }
    function RandomBytes(out Buf: TBytes; ALen: Integer): Boolean; virtual; abstract;
    { Argon2id (K3 hedef KDF). capArgon2id yoksa EVdbCryptoError
      (UNSUPPORTED) - cagiran taraf cap'a bakarak onlemeli. }
    function Argon2id(const Password, Salt, Secret, Ad: TBytes;
      TimeCost, MemoryKiB, Lanes, HashLen: Integer;
      out Hash: TBytes): Boolean; virtual;
    { Tek blok AES-256-ECB - YALNIZ selftest/uyumluluk; cap
      capAes256Block yoksa EVdbCryptoError(UNSUPPORTED). }
    function Aes256Block(const Key, Block: TBytes): TBytes; virtual;
    { K5 acilis oz testi: saglayicinin yeteneklerine uyarlanan sabit
      KAT setini kosturur. ALog satir satir rapor (PASS/FAIL/SKIP).
      False => crypto ETKINLESMEMELI (fail-closed, cagiran sozlesmesi). }
    function SelfTest(out ALog: string): Boolean; virtual; abstract;
    destructor Destroy; override;
  end;

{ -------------------------- kayit + secim API'si --------------------------
  Kayit: uygulamasyon birimlerinin initialization'i self-record eder;
  boylece VDbCryptoProvider implementation birimlerini IMPORT ETMEZ
  (dongusel bagimlilik yok). Runner/uygulama kullandigi provider
  birimlerini uses'e yazar -> kayit kendiliginden olur. }

{ Ayni adla tekrar kayit sessizce gecerli bir degisiklik yapmaz (False). }
function VDbCryptoRegisterProviderClass(const AName: string;
  AClass: TVDbCryptoProviderClass): Boolean;

{ Kayitli provider adlarini virgul ile listeler (hata mesajlarinda). }
function VDbCryptoProviderNames: string;

{ Proje varsayilani provider Adi (SAHIB KARARI R-5): VDB_CRYPTO_PROVIDER
  ortam degiskeni varsa onun degeri (acik opt-in kanali), yoksa
  'builtin'. Hicbir kutuphane yuklemez/dogrulamaz; yalniz Adir. }
function VDbCryptoDefaultProviderName: string;

{ Adiyla provider ornegi yaratir/hazirlar. Basarisizsa AErr temiz hata:
  OpenSSL icin "kullanilamiyor, denen: ..., VDB_CRYPTO_DLL ayarla".
  ORNEK cagiran tarafin mulkiyetindedir; Free ile serbest birakilir. }
function VDbCryptoCreateProvider(const AName: string;
  out AProvider: TVDbCryptoProvider; out AErr: string): Boolean;

{ Etkin provider'i secer (singleton yonetimi burada). BASARISIZLIKTA
  etkin provider DEGISMEZ ve AErr dolar - builtin'e otomatik gecis YOK. }
function VDbCryptoSelectProvider(const AName: string; out AErr: string): Boolean;

{ Proje varsayilanini secer: builtin (SAHIB KARARI R-5).
  VDB_CRYPTO_PROVIDER=openssl ise bu ACIK opt-in olarak OpenSSL'i secer;
  OpenSSL kullanilamiyorsa False + temiz hata (sessiz builtin dususu YOK,
  K6 - hata yalniz OpenSSL ACIKCA secildiginde uretilir, R-5/c). }
function VDbCryptoSelectDefaultProvider(out AErr: string): Boolean;

{ Etkin provider veya nil. Cagiran nil ise crypto KAPALI demektir;
  plaintext'e dusmez (cagiran sozlesmesi). }
function VDbCryptoActiveProvider: TVDbCryptoProvider;

{ Secim basarisizliginin son hata metni (yoksa bos). }
function VDbCryptoLastError: string;

implementation

const
  MAX_PROVIDERS = 8;

type
  TProviderSlot = record
    Name: string;
    Cls: TVDbCryptoProviderClass;
    Inst: TVDbCryptoProvider;   { lazy singleton; finalization'da free }
  end;

var
  GLock: SyncObjs.TCriticalSection;
  GSlots: array[0..MAX_PROVIDERS - 1] of TProviderSlot;
  GSlotCount: Integer;
  GActive: TVDbCryptoProvider;
  GLastError: string;
  iFin: Integer;  { finalization dongusu degiskeni }

{ ------------------ varsayilan govde (desteklemeyen provider) ---------- }

function TVDbCryptoProvider.Argon2id(const Password, Salt, Secret, Ad: TBytes;
  TimeCost, MemoryKiB, Lanes, HashLen: Integer;
  out Hash: TBytes): Boolean;
begin
  Hash := nil;
  if not (capArgon2id in Capabilities) then
    raise EVdbCryptoError.Create(Name + ': Argon2id desteklenmiyor ' +
      '(K6 matrisi: OpenSSL 1.1/3.0-3.1 Argon2 icermiyor; K3 referansi ' +
      'VDbKdf tabanli builtin)', VDB_CRYPTO_E_UNSUPPORTED);
  Result := False;
end;

function TVDbCryptoProvider.Aes256Block(const Key, Block: TBytes): TBytes;
begin
  if not (capAes256Block in Capabilities) then
    raise EVdbCryptoError.Create(Name + ': tek blok AES-256-ECB saglanmiyor ' +
      '(yalniz builtin DCP cekirdek uyumluluk vektoru icin)',
      VDB_CRYPTO_E_UNSUPPORTED);
  Result := nil;
end;

destructor TVDbCryptoProvider.Destroy;
begin
  inherited Destroy;
end;

{ ------------------------------ kayit ----------------------------------- }

function VDbCryptoRegisterProviderClass(const AName: string;
  AClass: TVDbCryptoProviderClass): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (AName = '') or (AClass = nil) then Exit;
  GLock.Enter;
  try
    for i := 0 to GSlotCount - 1 do
      if SameText(GSlots[i].Name, AName) then
        Exit;  { ikinci kayit: sessizce reddet (uygulama hatasi) }
    if GSlotCount >= MAX_PROVIDERS then Exit;
    GSlots[GSlotCount].Name := AName;
    GSlots[GSlotCount].Cls := AClass;
    GSlots[GSlotCount].Inst := nil;
    Inc(GSlotCount);
    Result := True;
  finally
    GLock.Leave;
  end;
end;

{ Kilit altinda cagrilmak uzere: VDbCryptoProviderNames kilit alir,
  hata mesaji kurulumunda yeniden kilit almamak icin bu kullanim. }
function NamesLocked: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to GSlotCount - 1 do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + GSlots[i].Name;
  end;
end;

function VDbCryptoProviderNames: string;
begin
  GLock.Enter;
  try
    Result := NamesLocked;
  finally
    GLock.Leave;
  end;
end;

function FindSlot(const AName: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to GSlotCount - 1 do
    if SameText(GSlots[i].Name, AName) then Exit(i);
end;

function VDbCryptoCreateProvider(const AName: string;
  out AProvider: TVDbCryptoProvider; out AErr: string): Boolean;
var
  idx: Integer;
  p: TVDbCryptoProvider;
begin
  Result := False;
  AProvider := nil;
  AErr := '';
  GLock.Enter;
  try
    idx := FindSlot(AName);
    if idx < 0 then
    begin
      AErr := 'bilinmeyen crypto provider: "' + AName + '" (kayitli: ' +
        NamesLocked + ')';
      Exit;
    end;

    if GSlots[idx].Inst = nil then
      GSlots[idx].Inst := GSlots[idx].Cls.Create;
    p := GSlots[idx].Inst;
  finally
    GLock.Leave;
  end;
  if not p.IsAvailable(AErr) then
  begin
    if AErr = '' then
      AErr := p.Name + ': kullanilamiyor';
    Exit;
  end;
  AProvider := p;
  Result := True;
end;

function VDbCryptoSelectProvider(const AName: string; out AErr: string): Boolean;
var
  p: TVDbCryptoProvider;
begin
  if not VDbCryptoCreateProvider(AName, p, AErr) then
  begin
    GLock.Enter;
    try
      GLastError := AErr;
    finally
      GLock.Leave;
    end;
    Exit(False);
  end;
  GLock.Enter;
  try
    GActive := p;
    GLastError := '';
  finally
    GLock.Leave;
  end;
  Result := True;
end;

function VDbCryptoDefaultProviderName: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('VDB_CRYPTO_PROVIDER'));
  if Result = '' then
    Result := VDB_PROVIDER_BUILTIN;  { R-5: varsayilan builtin - sifir DLL }
end;

function VDbCryptoSelectDefaultProvider(out AErr: string): Boolean;
begin
  { SAHIB KARARI R-5 / ADR EK-B madde 1: varsayilan provider = builtin.
    Adim 1'deki OpenSSL varsayilanindan farklidir; K1 onceligi gecersiz.
    VDB_CRYPTO_PROVIDER ortam degiskeni varsa ACIK opt-in'dir ve
    basarisizlikta temiz hata doner - otomatik builtin fallback YOK. }
  Result := VDbCryptoSelectProvider(VDbCryptoDefaultProviderName, AErr);
end;

function VDbCryptoActiveProvider: TVDbCryptoProvider;
begin
  GLock.Enter;
  try
    Result := GActive;
  finally
    GLock.Leave;
  end;
end;

function VDbCryptoLastError: string;
begin
  GLock.Enter;
  try
    Result := GLastError;
  finally
    GLock.Leave;
  end;
end;

initialization
  GLock := SyncObjs.TCriticalSection.Create;

finalization
  { Singleton'lari birak; aktif isareti de temizlenir. }
  for iFin := 0 to GSlotCount - 1 do
    if GSlots[iFin].Inst <> nil then
      FreeAndNil(GSlots[iFin].Inst);
  GActive := nil;
  GLock.Free;

end.
