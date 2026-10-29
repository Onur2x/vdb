unit VDbPageWal;

{ VDB v3 - Sayfa imajli WAL (Sprint 1 / Gun 5)

  Amac: commit edilmis her sayfa degisikligi, veritabani dosyasina
  yazilmadan ONCE WAL'e yazilip fsync edilir. Boylece sayfa yaziminin
  yarida kalmesi (torn page) ya da surecin kill -9 ile olmesi veri
  kaybina yol acmaz.

  Dosya yerlesimi:
    kayit 0        : 4096 baytlik baslik (sihirli sayi, surum, sayfa boyu,
                     checkpoint LSN, CRC)
    sonraki kayitlar: cerceve ve commit kayitlari, ardisik

  Kayit basligi (20 bayt):
    Magic(4) | LSN(4) | PayloadLen(4) | PageNo(4) | Crc(4)

  - Cerceve (VFW1): PayloadLen = 4096, PageNo = sayfa numarasi, yuk = sayfa imaji.
  - Commit  (FWC1): PayloadLen = 0, PageNo = 0. Bu kayittan onceki tum
    cerceveler "commit edilmis" sayilir.

  Kurtarma: kayitlar bastan sona okunur. Bozuk/kesik kayit gorulunce
  DURULUR (kuyruk yarim kalmis demektir). Yalnizca bir commit kaydiyla
  kapanmis cerceveler uygulanir; commit'siz kuyruk atilir.

  Bilincli sinirlar:
  - Tek yazici.
  - WAL dosyasi checkpoint'te tamamen silinmez, basligi kalir (truncate).
  - Sayfa 0 (meta) WAL'e girmez; meta WAL commit'inden SONRA yazilir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbPage, VDbCrc32, VDbSync, VDbPageCrypto;

const
  VDB_WAL_MAGIC       = $334C5756;   // 'VWL3'
  VDB_WAL_VER         = 1;
  { Meta sayfa numarasi (VDbPageStore.VDB_HDR_PAGE ile ayni; bu birim
    depo birimine bagimli olmamak icin yerel sabit tutar). }
  VDB_WAL_META_PAGE   = 0;
  VDB_WAL_REC_FRAME   = $31574656;   // 'VFW1'
  VDB_WAL_REC_COMMIT  = $31435746;   // 'FWC1'
  VDB_WAL_REC_HDR     = 20;          // bayt

  { Sprint 3.4: sifreli WAL basligi alanlari (meta sayfa yerlesimiyle ayni). }
  VDB_WAL_FLAGS       = 16;   // LongWord
  VDB_WAL_KEYCHECK    = 20;   // 16 bayt
  VDB_WAL_SALT        = 36;   // 16 bayt
  VDB_WAL_FLAG_ENC    = 1;

type
  EVdbWal = class(Exception);

  { Kurtarma sirasinda her onaylanmis cerceve icin cagrilir. }
  TVdbWalApplyProc = procedure(PageNo: LongWord; P: PVdbPage) of object;

  { v3.31: son Recover'in uyguladigi sayfa numaralari (tekillik).
    Delta tazeleme: yalnizca bu sayfalari yeniden indesklemek gerekir. }
  TVdbWalPageArray = array of LongWord;

  TVdbWalStats = record
    Frames: Integer;          // WAL'de commit edilmis cerceve sayisi
    Commits: Integer;
    TornTail: Boolean;        // kuyrukta bozuk/kesik kayit vardi
    Bytes: Int64;
  end;

  TVdbPageWal = class
  private
    type
      TPending = record
        PageNo: LongWord;
        Data: TVDbPageBuf;
      end;
    var
      FPath: string;
      FStream: TFileStream;
      FBuffer: array of TPending;    // commit bekleyen cerceveler
      FBufferCount: Integer;
      { v3.24: commit sirasinda tum kayitlar (cerceveler + commit kaydi) TEK
        WriteFile ile yazilir; tampon commit'ler arasinda yeniden kullanilir
        (boyu yalniz buyur). }
      FOutBuf: TBytes;
      FLSN: LongWord;
      FHasContent: Boolean;
      { Sprint 3.4: sifreli WAL. }
      FEncryptedMode: Boolean;   // cagiran (motor) sifreleme istiyor mu
      FWalEncrypted: Boolean;    // diskteki baslik ne diyor
      FKey: TBytes;
      FSalt: TBytes;
      FKeyCheck: TBytes;
      { v3.2: salt-okunur WAL (okuyucu oturum). }
      FReadOnlyMode: Boolean;
    { v3.19 GRUP COMMIT: WAL'e FIILEN yazilmis en son LSN. FLSN'den farki:
      FLSN Commit icinde kayitlar yazilmadan ONCE set edilir; fsync'in
      kapsadigi araligi bilmek icin yazimdan SONRA isaretlenen bir deger
      gerekir. Commit/Truncate/Recover/CommitCount tarafindan guncellenir. }
    FWrittenLsn: LongWord;
    { v3.29 ARTIMSAL GERI UYGULAMA (delta tazeleme).
      Tazelemede WAL'in TAMAMI bastan uygulaniyordu; WAL buyudukce maliyet
      dogrusal artiyordu. FScanPos: basariyla okunan son kayittan SONRAKI
      bayt konumu. FScanHdrLsn: o tarama sirasindaki WAL BASLIK LSN'i.
      Truncate basligi yeniden yazip LSN'i ilerlettigi icin baslik LSN'i
      degistiyse dosya kesilmis demektir -> bastan taranir.
      GUVENLIK: bu alanlara yalnizca kilit altinda (paylasimli kilit)
      erisilir; o sirada baska surec WAL'e yazamaz. Yanlis konumdan devam
      etmek eksik uygulama riski tasir; bu yuzden baslik LSN'i esit
      degilse HER ZAMAN tam tarama yapilir. }
    FScanPos: Int64;
    FScanHdrLsn: LongWord;
    { v3.31 DELTA TAZELEME.
      FHeaderLsn: WAL basligindaki checkpoint LSN'i. Veri dosyasi bu LSN'e
      kadar TAMAMEN gunceldir (Truncate oncesinde dosya fsync edilmistir);
      onbellek bu LSN'den gerideyse yalniz WAL'e bakmak YETMEZ — o degisiklikler
      zaten veri dosyasindadir ve WAL'den silinmis olabilir (drop cache gerekir).
      FAppliedPages: son Recover'in uyguladigi (tekillik sonrasi) sayfa
      numaralari. Bayat heap dizinini yalnizca bu sayfalar icin yeniden
      indesklemek yeterlidir. }
    FHeaderLsn: LongWord;
    FAppliedPages: TVdbWalPageArray;
    { v3.19 GRUP COMMIT: fsync icin AYRI handle. Neden: TFileStream'in
      konumu paylasilan durumdur; lider fsync yaparken baska bir thread
      ayni stream'e yazarsa konum/ tampon bozulur. FlushFileBuffers
      konum kullanmaz ve DOSYA duzeyinde calisir, yani ikinci handle ile
      yapilan fsync birinci handle'in yazdiklarini da diske indirir. }
    FSyncStream: TFileStream;
    procedure WriteHeader;
    procedure ReadHeader;
    procedure AppendBuffer(PageNo: LongWord; P: PVdbPage);
    function BufferedPageIndex(PageNo: LongWord): Integer;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;

    { WAL dosyasini kesif/olustur (yoksa baslik yazar).
      v3.2: AReadOnly=True ise dosya OLUSTURULMAZ ve yalnizca okunur
      (fmOpenRead); yoksa "icerik yok" kabul edilir. }
    procedure Open(AReadOnly: Boolean = False);
    procedure Close;

    { v3.28: BASKA SUREC COMMIT ETTI -> WAL gorunumunu tazele.
      NEDEN AYRI METOT: ONCEDEN Close+Open yapiliyordu; yani her
      tazelemede dosya kapatilip yeniden aciliyordu. Windows'ta YENI
      YAZILMIS bir dosyanin ILK yeniden acilisi olculdu: 4-10 ms
      (ayni dosyanin ikinci acilisi 40 us). Maliyet acilis katmaninda
      (savunma/onbellek), handle'i koruyup yalniz basligi yeniden
      okumak onu tamamen kaldirir: 6,5 ms -> ~0,05 ms.
      GUVENLIK: WAL dosyasi hicbir yerde SILINMIYOR; Truncate yalniz
      SetEndOfFile kullanir, dolayisiyla handle gecerliligini korur ve
      diger surecin yazdiklari ayni handle'dan okunur. }
    procedure Refresh(AReadOnly: Boolean);

    { Sprint 3.4: Open'dan ONCE cagrilir. Anahtar 32 bayt; tuz depodan
      gelir (AAD ayni olsun). }
    procedure SetEncryptionKey(const AKey, ASalt: TBytes);
    property Encrypted: Boolean read FEncryptedMode;

    { WAL'de uygulanacak (commit edilmis) cerceve var mi? Acilista
      kurtarma gerekip gerekmedigine karar vermek icin. }
    function HasContent: Boolean;

    { Commit bekleyen cerceveyi ekler (bellekte). Ayni sayfa icin son
      ekleme kazanir. }
    procedure AppendFrame(PageNo: LongWord; P: PVdbPage);

    { Bekleyen cerceveleri diske yazar, commit kaydini ekler. DoSync=True
      ise fsync eder (P-DUR: commit fsync eder). }
    function Commit(DoSync: Boolean; LSN: LongWord): Boolean;
    { v3.19 GRUP COMMIT: tamponu diske yazip fsync eder; Commit(True) ile
      ayni isi yapar ama cagiran zaten Commit(False) yaptiysa yeniden
      yazmaz. Yalniz FSyncBusy lideri cagirir. }
    procedure SyncDurable;
    { FIILEN yazilmis son LSN (0 = WAL'de yazilmis kayit yok). }
    property WrittenLsn: LongWord read FWrittenLsn;
    { v3.31: WAL basligindaki checkpoint LSN'i. Veri dosyasi bu LSN'e kadar
      guncel; onbellek bunun gerisindeyse tam tazeleme (DropCache) gerekir. }
    property HeaderLsn: LongWord read FHeaderLsn;
    { v3.31: son Recover'in uyguladigi sayfa numaralari (tekillik). }
    property AppliedPages: TVdbWalPageArray read FAppliedPages;

    { Commit edilmemis cerceveleri atar. }
    procedure Rollback;

    { WAL'i okuyup onaylanmis cerceveleri uygular.
      MaxCommits > 0 ise yalnizca ILK MaxCommits commit uygulanir (v3.2:
      AS OF anlik goruntusu). Okuma orada kesilir; kuyruk "yirtik" sayilmaz. }
    { v3.29: MinLSN > 0 ise LSN'i bu degerden KUCUK/ESIT kayitlar
      cozulmeden, CRC hesaplanmadan atlanir (zaten veritabani dosyasinda).
      AIncremental=True ise son taramanin biraktigi konumdan devam edilir
      (baslik LSN'i degismediyse); aksi halde bastan taranir. }
    function Recover(Apply: TVdbWalApplyProc; out Stats: TVdbWalStats;
      MaxCommits: Integer = 0; MinLSN: LongWord = 0;
      AIncremental: Boolean = False): Boolean;

    { WAL penceresindeki onaylanmis commit sayisi (uygulamaz, yalniz sayar).
      AS OF SEQUENCE icin ust sinirdir. }
    function CommitCount: Integer;

    { Checkpoint sonrasi WAL'i bosalt (yalniz baslik kalir). }
    procedure Truncate(CheckpointLSN: LongWord);

    property Path: string read FPath;
    property BufferedCount: Integer read FBufferCount;
    { WAL dosyasinin su anki boyu (checkpoint esigi icin). }
    function Bytes: Int64;
  end;

implementation



type
  TPendingArray = array of TVdbPageWal.TPending;

{ Iki parca uzerinden tek CRC (baslik + yuk). }
function WalCrc(const Hdr; HdrLen: Integer; const Payload; PayLen: Integer): LongWord;
var
  c: LongWord;
begin
  c := VDbCrc32Init;
  c := VDbCrc32Update(c, Hdr, HdrLen);
  if PayLen > 0 then
    c := VDbCrc32Update(c, Payload, PayLen);
  Result := VDbCrc32Final(c);
end;

function BytesEqual(const A, B: TBytes): Boolean;
var
  i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 0 to High(A) do
    if A[i] <> B[i] then Exit(False);
  Result := True;
end;

{ ------------------------------------------------------------------ baslik }

procedure TVDbPageWal.WriteHeader;
var
  buf: TVDbPageBuf;
  q: PLongWord;
  magic, ver: LongWord;
  ps: Word;
  lsn: LongWord;
  flags: LongWord;
begin
  FillChar(buf, SizeOf(buf), 0);
  magic := VDB_WAL_MAGIC;
  ver := VDB_WAL_VER;
  ps := VDB_PAGE_SIZE;
  lsn := FLSN;
  Move(magic, buf[0], 4);
  Move(ver, buf[4], 4);
  Move(ps, buf[8], 2);
  Move(lsn, buf[12], 4);
  if FEncryptedMode then
  begin
    flags := VDB_WAL_FLAG_ENC;
    Move(flags, buf[VDB_WAL_FLAGS], 4);
    if Length(FKeyCheck) = VDB_ENC_CHECK_LEN then
      Move(FKeyCheck[0], buf[VDB_WAL_KEYCHECK], VDB_ENC_CHECK_LEN);
    if Length(FSalt) = VDB_ENC_SALT_LEN then
      Move(FSalt[0], buf[VDB_WAL_SALT], VDB_ENC_SALT_LEN);
  end;
  q := PLongWord(@buf[VDB_PAGE_BODY_END]);
  q^ := VDbCrc32Of(buf, VDB_PAGE_BODY_END);
  FStream.Position := 0;
  FStream.WriteBuffer(buf, VDB_PAGE_SIZE);
end;

procedure TVDbPageWal.ReadHeader;
var
  buf: TVDbPageBuf;
  magic, ver, lsn, crc: LongWord;
  flags: LongWord;
  storedCheck, storedSalt: TBytes;
  i: Integer;
  ps: Word;
  q: PLongWord;
begin
  if FStream.Size < VDB_PAGE_SIZE then
    raise EVdbWal.Create(Format('WAL dosyasi cok kucuk (%d bayt)', [FStream.Size]));
  FStream.Position := 0;
  FStream.ReadBuffer(buf, VDB_PAGE_SIZE);
  Move(buf[0], magic, 4);
  if magic <> VDB_WAL_MAGIC then
    raise EVdbWal.Create(Format('gecersiz WAL sihirli sayisi: $%.8x', [magic]));
  Move(buf[4], ver, 4);
  if ver <> VDB_WAL_VER then
    raise EVdbWal.Create(Format('desteklenmeyen WAL surumu: %d', [ver]));
  Move(buf[8], ps, 2);
  if ps <> VDB_PAGE_SIZE then
    raise EVdbWal.Create(Format('WAL sayfa boyu %d (beklenen %d)',
      [ps, VDB_PAGE_SIZE]));
  q := PLongWord(@buf[VDB_PAGE_BODY_END]);
  crc := q^;
  if VDbCrc32Of(buf, VDB_PAGE_BODY_END) <> crc then
    raise EVdbWal.Create('WAL basligi bozuk (CRC tutmadi)');
  Move(buf[12], lsn, 4);
  FLSN := lsn;
  FHeaderLsn := lsn;

  Move(buf[VDB_WAL_FLAGS], flags, 4);
  if (flags and VDB_WAL_FLAG_ENC) <> 0 then
  begin
    if Length(FKey) <> VDB_ENC_KEY_LEN then
      raise EVdbWal.Create(
        'sifreli WAL: anahtar gerekli (SetEncryptionKey)');
    SetLength(storedSalt, VDB_ENC_SALT_LEN);
    Move(buf[VDB_WAL_SALT], storedSalt[0], VDB_ENC_SALT_LEN);
    if not BytesEqual(storedSalt, FSalt) then
      raise EVdbWal.Create(
        'WAL baska bir veritabanina ait (tuz farkli)');
    SetLength(storedCheck, VDB_ENC_CHECK_LEN);
    Move(buf[VDB_WAL_KEYCHECK], storedCheck[0], VDB_ENC_CHECK_LEN);
    if not BytesEqual(storedCheck, FKeyCheck) then
      raise EVdbWal.Create(
        'yanlis anahtar: WAL dogrulayici tutmadi');
    FWalEncrypted := True;
  end
  else
  begin
    if FEncryptedMode then
      raise EVdbWal.Create(
        'WAL sifresiz ama veritabani sifreli (eski WAL dosyasini silin)');
    FWalEncrypted := False;
  end;
end;

{ ------------------------------------------------------------------ yasam }

constructor TVdbPageWal.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  FBufferCount := 0;
  FHasContent := False;
  FLSN := 0;
  FHeaderLsn := 0;
  SetLength(FAppliedPages, 0);
  FEncryptedMode := False;
  FWalEncrypted := False;
  FKey := nil;
  FSalt := nil;
  FKeyCheck := nil;
end;

procedure TVdbPageWal.SetEncryptionKey(const AKey, ASalt: TBytes);
begin
  if Length(AKey) <> VDB_ENC_KEY_LEN then
    raise EVdbWal.Create(Format('WAL anahtari %d bayt (beklenen %d)',
      [Length(AKey), VDB_ENC_KEY_LEN]));
  FKey := Copy(AKey, 0, Length(AKey));
  FSalt := Copy(ASalt, 0, Length(ASalt));
  FKeyCheck := VDbPageKeyCheck(FKey);
  FEncryptedMode := True;
end;

destructor TVdbPageWal.Destroy;
begin
  try
    Close;
  except
    { yikici hata firlatmaz }
  end;
  inherited Destroy;
end;

procedure TVdbPageWal.Open(AReadOnly: Boolean);
var
  hasFile: Boolean;
begin
  if FStream <> nil then Exit;
  FReadOnlyMode := AReadOnly;
  hasFile := False;
  if FileExists(FPath) then
  begin
    { Sadece boyut kesfi; dosya ACILMAZ (Unix'te flock cakismasin). }
    hasFile := VDbFileBytes(FPath) >= VDB_PAGE_SIZE;
  end;
  if hasFile then
  begin
    if AReadOnly then
      FStream := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone)
    else
      FStream := TFileStream.Create(FPath, fmOpenReadWrite or fmShareDenyNone);
    try
      ReadHeader;
      FHasContent := FStream.Size > VDB_PAGE_SIZE;
    except
      FreeAndNil(FStream);
      raise;
    end;
  end
  else if AReadOnly then
  begin
    { Salt-okunur: WAL yok -> icerik yok. Dosya OLUSTURULMAZ. }
    FLSN := 0;
    FHasContent := False;
  end
  else
  begin
    { v3.16: WAL dosyasi da PAYLASIMA ACIK olmali; ayni veritabanina ikinci
      bir surec/oturum acabilmeli. Yazma yine veritabani kilidiyle siralanir. }
    FStream := TFileStream.Create(FPath, fmCreate or fmShareDenyNone);
    FLSN := 0;
    WriteHeader;
    VDbFlushStream(FStream);
    FWalEncrypted := FEncryptedMode;
    FHasContent := False;
  end;
  { v3.19: fsync icin ikinci handle (yalniz yazilabilir modda). }
  if (not AReadOnly) and (FStream <> nil) and (FSyncStream = nil) then
    FSyncStream := TFileStream.Create(FPath, fmOpenReadWrite or fmShareDenyNone);
end;

procedure TVdbPageWal.Close;
begin
  if FStream = nil then Exit;
  if FBufferCount > 0 then
    Rollback;
  FreeAndNil(FSyncStream);
  FreeAndNil(FStream);
end;

procedure TVdbPageWal.Refresh(AReadOnly: Boolean);
begin
  { Mod degistiyse (ya da hic acilmamissa) eski yol tek secenek. }
  if (FStream = nil) or (FReadOnlyMode <> AReadOnly) then
  begin
    Close;
    Open(AReadOnly);
    Exit;
  end;
  { Yazilmamis tampon varsa at (kapanista da ayni sey yapiliyordu). }
  if FBufferCount > 0 then
    Rollback;
  FStream.Position := 0;
  ReadHeader;
  FWrittenLsn := FLSN;
  { FStream.Size her cagrida isletim sistemine sorulur; baska surecin
    uzattigi dosya buradan gorulur. }
  FHasContent := FStream.Size > VDB_PAGE_SIZE;
end;

function TVdbPageWal.HasContent: Boolean;
begin
  Result := FHasContent;
end;

{ ----------------------------------------------------------------- cerceve }

function TVdbPageWal.BufferedPageIndex(PageNo: LongWord): Integer;
var
  i: Integer;
begin
  for i := 0 to FBufferCount - 1 do
    if FBuffer[i].PageNo = PageNo then Exit(i);
  Result := -1;
end;

procedure TVdbPageWal.AppendBuffer(PageNo: LongWord; P: PVdbPage);
var
  i: Integer;
begin
  i := BufferedPageIndex(PageNo);
  if i >= 0 then
  begin
    Move(P^, FBuffer[i].Data, VDB_PAGE_SIZE);
    Exit;
  end;
  if FBufferCount >= Length(FBuffer) then
    SetLength(FBuffer, FBufferCount + 64);
  FBuffer[FBufferCount].PageNo := PageNo;
  Move(P^, FBuffer[FBufferCount].Data, VDB_PAGE_SIZE);
  Inc(FBufferCount);
end;

procedure TVdbPageWal.AppendFrame(PageNo: LongWord; P: PVdbPage);
begin
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  if FReadOnlyMode then
    raise EVdbWal.Create('salt-okunur WAL: cerceve eklenemez');
  { Cerceve DISKE YAZILACAK bir imajdir: CRC'si simdi hesaplanir. Boylece
    kurtarma sirasinda yazilan sayfa PageVerify'dan gecer. }
  PageSeal(P);
  AppendBuffer(PageNo, P);
end;

procedure TVdbPageWal.Rollback;
begin
  FBufferCount := 0;
end;

procedure TVdbPageWal.SyncDurable;
var
  S: TFileStream;
begin
  { v3.19 GRUP COMMIT: kayitlar zaten yazildi (Commit(False)); burada yalniz
    isletim sisteminin tamponlari diske indirilir. Tek lider cagirir.
    AYRI handle kullanilir: fsync baska bir thread'in yazmasiyla ayni anda
    calisabilir; TFileStream'in konumu ortak oldugu icin FStream uzerinde
    fsync yapmak yaris durumu uretirdi. }
  if FReadOnlyMode then Exit;
  S := FSyncStream;
  if S = nil then Exit;
  VDbFlushStream(S);
end;

function TVdbPageWal.Commit(DoSync: Boolean; LSN: LongWord): Boolean;
var
  i, total, off, payLen: Integer;
  env, plain: TBytes;
  src: PByte;
  magic, zero, crc: LongWord;
begin
  Result := False;
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  if FBufferCount = 0 then Exit(True);   // yazacak bir sey yok
  FLSN := LSN;
  if FWalEncrypted then
    payLen := VDB_ENC_ENVELOPE
  else
    payLen := VDB_PAGE_SIZE;
  { v3.24: cerceveler + commit kaydi TEK tamponda toplanip TEK WriteFile ile
    yazilir. Onceden commit basina 3 cagri vardi (2 cerceve + commit kaydi);
    olculen fark ~1,85 us/cagri. Tampon uye alanda tutulur, commit'ler
    arasinda yeniden kullanilir. }
  total := FBufferCount * (VDB_WAL_REC_HDR + payLen) + VDB_WAL_REC_HDR;
  if Length(FOutBuf) < total then
    SetLength(FOutBuf, total + 8192);
  { v3.21: tek arama. Onceden FStream.Size + Position atamasi iki arama
    yapiyordu; Seek(0, soEnd) hem konumu hem sonu tek cagrida verir. }
  FStream.Seek(0, soEnd);
  off := 0;
  magic := VDB_WAL_REC_FRAME;
  zero := 0;
  for i := 0 to FBufferCount - 1 do
  begin
    if FWalEncrypted then
    begin
      SetLength(plain, VDB_PAGE_SIZE);
      Move(FBuffer[i].Data, plain[0], VDB_PAGE_SIZE);
      if not VDbPageSeal(FKey, FSalt, FBuffer[i].PageNo, plain, env) then
        raise EVdbWal.Create(Format('WAL cercevesi %d sifrelenemedi',
          [FBuffer[i].PageNo]));
      src := @env[0];
    end
    else
      src := @FBuffer[i].Data[0];
    Move(magic, FOutBuf[off], 4);
    Move(FLSN, FOutBuf[off + 4], 4);
    Move(payLen, FOutBuf[off + 8], 4);
    Move(FBuffer[i].PageNo, FOutBuf[off + 12], 4);
    Move(src^, FOutBuf[off + VDB_WAL_REC_HDR], payLen);
    crc := WalCrc(FOutBuf[off], 16, FOutBuf[off + VDB_WAL_REC_HDR], payLen);
    Move(crc, FOutBuf[off + 16], 4);
    Inc(off, VDB_WAL_REC_HDR + payLen);
  end;
  { commit kaydi: yuk yok, CRC yalniz baslik uzerinden. }
  magic := VDB_WAL_REC_COMMIT;
  Move(magic, FOutBuf[off], 4);
  Move(FLSN, FOutBuf[off + 4], 4);
  Move(zero, FOutBuf[off + 8], 4);
  Move(zero, FOutBuf[off + 12], 4);
  crc := WalCrc(FOutBuf[off], 16, FOutBuf[off], 0);
  Move(crc, FOutBuf[off + 16], 4);
  Inc(off, VDB_WAL_REC_HDR);
  FStream.WriteBuffer(FOutBuf[0], off);
  { Cok buyuk islemlerden sonra tamponu birak: aksi halde WAL nesnesi omru
    boyunca onlarca MB tutulur. Normal commit'lerde tampon yeniden kullanilir. }
  if Length(FOutBuf) > 4 * 1024 * 1024 then
    SetLength(FOutBuf, 0);
  if DoSync then
    VDbFlushStream(FStream);
  FBufferCount := 0;
  FHasContent := True;
  FWrittenLsn := LSN;
  Result := True;
end;

{ ---------------------------------------------------------------- kurtarma }

function TVdbPageWal.Recover(Apply: TVdbWalApplyProc;
  out Stats: TVdbWalStats; MaxCommits: Integer; MinLSN: LongWord;
  AIncremental: Boolean): Boolean;
var
  startPos, goodPos: Int64;
  hdrLsn: LongWord;
  hdr: array[0..VDB_WAL_REC_HDR - 1] of Byte;
  magic, lsn, payLen, pageNo, crc: LongWord;
  calc: LongWord;
  payload: TVDbPageBuf;
  raw: TBytes;
  plain: TBytes;
  expectedLen: LongWord;
  pending: TPendingArray;
  pendingCount: Integer;
  applied: TPendingArray;
  appliedCount: Integer;
  i, j: Integer;
  got: Integer;

  procedure AddTo(var arr: TPendingArray; var n: Integer;
    ANo: LongWord; const AData: TVDbPageBuf);
  var
    k: Integer;
  begin
    for k := 0 to n - 1 do
      if arr[k].PageNo = ANo then
      begin
        Move(AData, arr[k].Data, VDB_PAGE_SIZE);
        Exit;
      end;
    if n >= Length(arr) then
      SetLength(arr, n + 64);
    arr[n].PageNo := ANo;
    Move(AData, arr[n].Data, VDB_PAGE_SIZE);
    Inc(n);
  end;

begin
  Result := False;
  Stats.Frames := 0;
  Stats.Commits := 0;
  Stats.TornTail := False;
  Stats.Bytes := 0;
  pendingCount := 0;
  appliedCount := 0;
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  hdrLsn := FLSN;
  { v3.29: artimsal tarama. Konum YALNIZ (a) cagiran istediyse, (b) onceki
    tarama gecerli bir konum biraktiysa, (c) WAL basligi DEGISMEDIYSE
    (dosya kesilmedi) ve (d) konum dosya sinirinda ise kullanilir. }
  startPos := VDB_PAGE_SIZE;
  if AIncremental and (FScanPos >= VDB_PAGE_SIZE) and
     (FScanHdrLsn = hdrLsn) and (FScanPos <= FStream.Size) then
    startPos := FScanPos;
  goodPos := startPos;
  Stats.Bytes := FStream.Size - startPos;
  FStream.Position := startPos;
  while FStream.Position < FStream.Size do
  begin
    got := FStream.Read(hdr[0], VDB_WAL_REC_HDR);
    if got <> VDB_WAL_REC_HDR then
    begin
      Stats.TornTail := True;
      Break;
    end;
    Move(hdr[0], magic, 4);
    Move(hdr[4], lsn, 4);
    Move(hdr[8], payLen, 4);
    Move(hdr[12], pageNo, 4);
    Move(hdr[16], crc, 4);
    if (magic <> VDB_WAL_REC_FRAME) and (magic <> VDB_WAL_REC_COMMIT) then
    begin
      Stats.TornTail := True;
      Break;
    end;
    if magic = VDB_WAL_REC_FRAME then
    begin
      if FWalEncrypted then expectedLen := VDB_ENC_ENVELOPE
      else expectedLen := VDB_PAGE_SIZE;
      if payLen <> expectedLen then
      begin
        Stats.TornTail := True;
        Break;
      end;
    end;
    if (magic = VDB_WAL_REC_COMMIT) and (payLen <> 0) then
    begin
      Stats.TornTail := True;
      Break;
    end;
    { v3.29: MinLSN'den eski kayitlar ZATEN veritabani dosyasinda (onbellek
      oradan yuklendi). Cozme/CRC/kopyalama yapmadan yalniz konum ilerlet. }
    if lsn <= MinLSN then
    begin
      if payLen > 0 then
        FStream.Position := FStream.Position + payLen;
      goodPos := FStream.Position;
      Continue;
    end;
    calc := WalCrc(hdr[0], 16, hdr[0], 0);
    if payLen > 0 then
    begin
      if payLen > 65536 then
      begin
        Stats.TornTail := True;
        Break;
      end;
      SetLength(raw, payLen);
      got := FStream.Read(raw[0], payLen);
      if got <> Integer(payLen) then
      begin
        Stats.TornTail := True;
        Break;
      end;
      calc := WalCrc(hdr[0], 16, raw[0], payLen);
    end;
    if calc <> crc then
    begin
      Stats.TornTail := True;
      Break;
    end;

    if magic = VDB_WAL_REC_FRAME then
    begin
      if FWalEncrypted then
      begin
        if not VDbPageOpen(FKey, FSalt, pageNo, raw, plain) then
          raise EVdbWal.Create(Format(
            'WAL cercevesi %d cozulemedi (yanlis anahtar ya da bozuk kayit)',
            [pageNo]));
        Move(plain[0], payload[0], VDB_PAGE_SIZE);
      end
      else
        Move(raw[0], payload[0], VDB_PAGE_SIZE);
      AddTo(pending, pendingCount, pageNo, payload);
    end
    else
    begin
      { Commit: bekleyenleri onaylanmis kumeye tasi. }
      for j := 0 to pendingCount - 1 do
        AddTo(applied, appliedCount, pending[j].PageNo, pending[j].Data);
      pendingCount := 0;
      Inc(Stats.Commits);
      FLSN := lsn;
      { v3.2: AS OF icin sinirli kurtarma — pencere basi burada biter.
        Okumayi kes; kalan kayitlar "yirtik kuyruk" DEGILDIR. }
      if (MaxCommits > 0) and (Stats.Commits >= MaxCommits) then
        Break;
    end;
    { v3.29: son TAM dogrulanmis kaydin sonu. Yirtik kuyrukta buradan
      ileri gidilmez; bir sonraki tarama ayni yerden devam eder. }
    goodPos := FStream.Position;
  end;

  { Commit'siz kuyruk atilir. Meta sayfa (0) EN SON uygulanir: once veri
    sayfalari yazilip dosya uzatilmali, yoksa meta'daki sayfa sayisi
    dosya boyutundan buyuk gorunur. }
  for i := 0 to appliedCount - 1 do
    if (applied[i].PageNo <> VDB_WAL_META_PAGE) and Assigned(Apply) then
      Apply(applied[i].PageNo, @applied[i].Data);
  for i := 0 to appliedCount - 1 do
    if (applied[i].PageNo = VDB_WAL_META_PAGE) and Assigned(Apply) then
      Apply(applied[i].PageNo, @applied[i].Data);
  Stats.Frames := appliedCount;
  { v3.31: uygulanan sayfa numaralari — delta tazeleme icin. Tekillik zaten
    AddTo'da yapildi; yalnizca numaralari kopyala. Meta sayfa (0) de listede
    kalir; indesk yenileme onu yok sayar. }
  SetLength(FAppliedPages, appliedCount);
  for i := 0 to appliedCount - 1 do
    FAppliedPages[i] := applied[i].PageNo;
  { v3.19: kurtarma sonrasi WAL'de yazilmis sayilan en son LSN, kurtarilan
    son commit'in LSN'idir. }
  FWrittenLsn := FLSN;
  FScanPos := goodPos;
  FScanHdrLsn := hdrLsn;
  Result := True;
end;

function TVdbPageWal.CommitCount: Integer;
var
  st: TVdbWalStats;
  oldLSN: LongWord;
  oldWritten: LongWord;
begin
  if (FStream = nil) or (not FHasContent) then
    Exit(0);
  { Apply = nil: yalnizca dogrulanmis commit'ler sayilir. Recover FLSN'i
    son commit'e ceker; canli WAL'de bu yan etki istenmez. }
  oldLSN := FLSN;
  oldWritten := FWrittenLsn;
  try
    Recover(nil, st);
    Result := st.Commits;
  finally
    FLSN := oldLSN;
    FWrittenLsn := oldWritten;
  end;
end;

procedure TVdbPageWal.Truncate(CheckpointLSN: LongWord);
begin
  if FReadOnlyMode then Exit;
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  FLSN := CheckpointLSN;
  FHeaderLsn := CheckpointLSN;
  { v3.29: dosya kesildi -> artimsal tarama konumu gecersiz. Baslik LSN'i
    CheckpointLSN olarak yazilacagi icin onunla esitlenir. }
  FScanPos := VDB_PAGE_SIZE;
  FScanHdrLsn := FLSN;
  { v3.19: checkpoint sonrasi WAL bos; yazilmis LSN de checkpoint LSN'idir.
    Sifira cekmek YANLIS olur: LSN monoton artar, bekleyen AwaitDurable
    cagrilari eski LSN ile karsilastirir. }
  FWrittenLsn := CheckpointLSN;
  FBufferCount := 0;
  FStream.Size := VDB_PAGE_SIZE;
  WriteHeader;
  VDbFlushStream(FStream);
  FHasContent := False;
end;

function TVdbPageWal.Bytes: Int64;
begin
  if FStream = nil then
    Exit(0);
  Result := FStream.Size +
    Int64(FBufferCount) * (VDB_PAGE_SIZE + VDB_WAL_REC_HDR);
end;

end.
