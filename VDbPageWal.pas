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
  SysUtils, Classes, SyncObjs, VDbPage, VDbCrc32, VDbSync, VDbPageCrypto;

const
  VDB_WAL_MAGIC       = $334C5756;   // 'VWL3'
  VDB_WAL_VER         = 2;
  { P-53: surum 1 — WalCrc baslik + yuk uzerinden. Surum 2 — WalCrc yalniz
    baslik; yuk butunlugu PageSeal CRC ile saglanir (daha az CRC maliyeti). }
  VDB_WAL_VER_COMPAT  = 1;   // desteklenen en eski surum
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

  { R2-C-YENI-2: WAL'in ait oldugu VERITABANI KIMLIGI. Ayni yolda
    DROP+CREATE ile yeniden yaratilan DB'ye eski .wal uygulanmasin.
    Kimlik, veri dosyasinin meta sayfasindaki yaratilis damgasindan ve
    bicim alanlarindan turetilir (VDbPageStore bagimliligi olmasin diye
    ofsetler yerel sabit). Cagiran daha guclu bir kimlik (or. UUID)
    saglarsa SetDatabaseId ile Open'dan ONCE verir. }
  VDB_WAL_DBID        = 64;   // 16 bayt (52..63 serbest)
  VDB_WAL_DBID_LEN    = 16;
  { VDbPageStore.VDB_FILE_MAGIC ile ayni ('VDB3'). }
  VDB_WAL_DB_MAGIC    = $33424456;
  VDB_WAL_DB_CREATED  = 28;   // meta: Int64 yaratilis damgasi
  VDB_WAL_DB_IDBYTES  = 36;   // magic(4)+ver(4)+...+created(8 @28)

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
      { v4: ara TPending kopyasi kaldirildi — yuk dogrudan FOutBuf'a yazilir.
        Yalniz sayfa numaralari tutulur (dedup + baslik icin). }
      FFramePages: array of LongWord;
      FBufferCount: Integer;
      { P-71: cerceve dedup haritasi. BufferedPageIndex onceden tamponu
        DOGRUSAL taramaktaydi (12K cercevelik committe ~72M karsilastirma,
        olculen ~0,05-0,1 us/satir). Acik-sondalama; anahtar sayfaNo+1
        (VDB_HDR_PAGE=0 gecerli bir sayfa oldugundan 0 = bos yuva). }
      FBufHash: array of LongWord;
      FBufHashIdx: array of Integer;
      FBufHashCap: Integer;   // 2'nin kuvveti; 0 = tablo yok
      { v3.24: commit sirasinda tum kayitlar (cerceveler + commit kaydi) TEK
        WriteFile ile yazilir; tampon commit'ler arasinda yeniden kullanilir
        (boyu yalniz buyur). }
      FOutBuf: TBytes;
      FLSN: LongWord;
      FHasContent: Boolean;
      { P-61: WAL dosyasi boyutu sayaçi — FStream.Size (syscall) yerine
        bellekten okunur. Commit'te artar, Truncate'de sifirlanir,
        Open/Refresh'te diskten bir kez okunur. }
      FWrittenBytes: Int64;
      { P-57: FStream konumu dosya sonunda mi? Commit'te Seek(0, soEnd)
        atlaniyor. Tek surecli modda Commit sonrasi konum zaten sondadir;
        Refresh/Recover/ReadHeader konumu bastan baslattigi icin bayrak
        duser. Cok surecli modda StoreRefreshed -> FWal.Refresh bayragi
        sifirlar. }
      FAtEnd: Boolean;
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
    { P-53: acik WAL dosyasinin kayit CRC bicimi. 1 = baslik+yuk, 2 = yalniz
      baslik (PageSeal yuk butunlugunu tasir). ReadHeader'da belirlenir;
      WriteHeader yeni dosyalara 2 yazar. Truncate sonrasi surum 2'ye yukselir. }
    FWalVer: LongWord;
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
    { R2-C-3 (kalan): GRUP COMMIT'te fsync Commit icinde yapilmaz; kayitlar
      Commit(False) ile yazilir, fsync sonradan SyncDurable'da cekilir.
      fsync basarisiz olursa istemci commit'i BASARISIZ gorur ama kayitlar
      dosyada kalirsa kurtarma onlari "hayalet commit" olarak uygular.
      Bu yuzden son BASARILI durabilite noktasindan sonra yazilmis ilk
      commit'in dosya konumu isaretlenir; SyncDurable hatasinda oraya geri
      kirpilir. FUnsyncedBaseValid=False iken isaret yoktur.
      FWrittenLsn'e DOKUNULMAZ: R2-C-YENI-1 geregi yalniz ileri gider; geri
      cekmek eszamanli bekleyenlerin AwaitDurable erken cikisina (yanlis
      basarili commit) yol acardi. }
    FUnsyncedStartPos: Int64;
    FUnsyncedBaseValid: Boolean;
    FSyncFault: Boolean;   // R2-C-3 test kancasi
    { R2-C-3: WAL yazimi ile geri kirpma ayni anda calismamali. fsync'in
      kendisi (FSyncStream) kilit DISINDA yapilir; grup commit'in amaci
      fsync sirasinda baska thread'lerin yazabilmesidir. Bu kilit yalniz
      FStream uzerindeki yazim/kesme islemlerini siralar. }
    FWriteCs: TCriticalSection;
    { R2-C-YENI-2: dogrulanmis/verilmis veritabani kimligi. Ilk Open'da
      turetilir ve oturum boyunca onbellekte kalir (Refresh sicak yoldur;
      her tazelemede veri dosyasini yeniden acmak istemeyiz). }
    FDbId: TBytes;
    FDbIdKnown: Boolean;
    function DbFilePath: string;
    function DeriveDbId(out AId: TBytes): Boolean;
    procedure EnsureDbId;
    { C-1: WAL govdesindeki TUM gecerli kayitlar CheckpointLSN'den kucuk/
      esit mi? Yalnizca oyle ise govde budanabilir. AMaxLsn: gorulen en
      buyuk kayit LSN'i (FWrittenLsn'i geri dusurmemek icin). }
    function WalBodySafeToPrune(CheckpointLSN: LongWord;
      out AMaxLsn: LongWord): Boolean;
    procedure WriteHeader;
    procedure ReadHeader;
    procedure AppendBuffer(PageNo: LongWord; P: PVdbPage);
    function BufferedPageIndex(PageNo: LongWord): Integer;
    { P-71: dedup haritasi islemleri. }
    procedure BufHashClear;
    procedure BufHashRawPut(PageNo: LongWord; Idx: Integer);
    procedure BufHashGrow;
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

    { R2-C-YENI-2: veritabani kimligini acikca ver (Open'dan ONCE).
      16 bayt beklenir; bos TBytes kimligi temizler ve yeniden turetmeye
      doner. Verilmezse kimlik veri dosyasinin meta sayfasindan turetilir;
      boylece eski .wal yeni DB'ye sessizce uygulanmaz. }
    procedure SetDatabaseId(const AId: TBytes);
    property DatabaseId: TBytes read FDbId;

    { WAL'de uygulanacak (commit edilmis) cerceve var mi? Acilista
      kurtarma gerekip gerekmedigine karar vermek icin. }
    function HasContent: Boolean;

    { Commit bekleyen cerceveyi ekler (bellekte). Ayni sayfa icin son
      ekleme kazanir. }
    procedure AppendFrame(PageNo: LongWord; P: PVdbPage; ALsn: LongWord);

    { Bekleyen cerceveleri diske yazar, commit kaydini ekler. DoSync=True
      ise fsync eder (P-DUR: commit fsync eder). }
    function Commit(DoSync: Boolean; LSN: LongWord): Boolean;
    { v3.19 GRUP COMMIT: tamponu diske yazip fsync eder; Commit(True) ile
      ayni isi yapar ama cagiran zaten Commit(False) yaptiysa yeniden
      yazmaz. Yalniz FSyncBusy lideri cagirir. }
    procedure SyncDurable;
    { FIILEN yazilmis son LSN (0 = WAL'de yazilmis kayit yok). }
    property WrittenLsn: LongWord read FWrittenLsn;
    { R2-C-3 test kancasi: True iken fsync yerine hata verilir. Yalniz
      kapi/test kodu kullanir; normal akista daima False. }
    procedure DebugSetSyncFault(AValue: Boolean);
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

function BytesAllZero(const A: TBytes): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(A) do
    if A[i] <> 0 then Exit(False);
  Result := True;
end;

{ ------------------------------------------------------ veritabani kimligi }

function TVdbPageWal.DbFilePath: string;
begin
  { WAL sozlesmesi: <db yolu> + '.wal'. Farkli bir adlandirma kullanilirsa
    kimlik turetilemez; bu durumda dogrulama yapilmaz (eski davranis). }
  Result := FPath;
  if (Length(Result) > 4) and
     SameText(Copy(Result, Length(Result) - 3, 4), '.wal') then
    SetLength(Result, Length(Result) - 4)
  else
    Result := '';
end;

function TVdbPageWal.DeriveDbId(out AId: TBytes): Boolean;
var
  p: string;
  S: THandleStream;
  buf: array[0..VDB_WAL_DB_IDBYTES - 1] of Byte;
  magic, ver: LongWord;
begin
  Result := False;
  AId := nil;
  p := DbFilePath;
  if p = '' then Exit;
  if not FileExists(p) then Exit;
  S := nil;
  try
    try
      { Kilit istemeyen acilis: motor veri dosyasinda tam/paylasimli kilit
        tutuyor olabilir (bkz VDbSync.VDbOpenStreamNoFlock). }
      S := VDbOpenStreamNoFlock(p, True, False);
      if S.Size < VDB_WAL_DB_IDBYTES then Exit;
      S.Position := 0;
      S.ReadBuffer(buf[0], VDB_WAL_DB_IDBYTES);
    except
      { Okunamayan dosya -> kimlik yok; cagiran guvenli tarafa karar verir. }
      Exit;
    end;
  finally
    S.Free;
  end;
  Move(buf[0], magic, 4);
  if magic <> VDB_WAL_DB_MAGIC then Exit;
  Move(buf[4], ver, 4);
  SetLength(AId, VDB_WAL_DBID_LEN);
  Move(buf[VDB_WAL_DB_CREATED], AId[0], 8);
  Move(magic, AId[8], 4);
  Move(ver, AId[12], 4);
  Result := True;
end;

procedure TVdbPageWal.EnsureDbId;
begin
  if FDbIdKnown then Exit;
  if DeriveDbId(FDbId) then
    FDbIdKnown := True;
end;

procedure TVdbPageWal.SetDatabaseId(const AId: TBytes);
begin
  if Length(AId) = 0 then
  begin
    FDbId := nil;
    FDbIdKnown := False;
    Exit;
  end;
  if Length(AId) <> VDB_WAL_DBID_LEN then
    raise EVdbWal.Create(Format('WAL DB kimligi %d bayt (beklenen %d)',
      [Length(AId), VDB_WAL_DBID_LEN]));
  FDbId := Copy(AId, 0, Length(AId));
  FDbIdKnown := True;
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
  FWalVer := VDB_WAL_VER;   // P-53: yeni/yeniden yazilan baslik daima son surum
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
  { R2-C-YENI-2: veritabani kimligi. Kimlik turetilenemezse alan sifir
    kalir (eski bicim) ve ReadHeader dogrulama yapmaz. }
  EnsureDbId;
  if FDbIdKnown and (Length(FDbId) = VDB_WAL_DBID_LEN) then
    Move(FDbId[0], buf[VDB_WAL_DBID], VDB_WAL_DBID_LEN);
  q := PLongWord(@buf[VDB_PAGE_BODY_END]);
  q^ := VDbCrc32Of(buf, VDB_PAGE_BODY_END);
  FStream.Position := 0;
  FStream.WriteBuffer(buf, VDB_PAGE_SIZE);
  { P-57: WriteHeader yalniz yeni dosya (Open) ve Truncate'ta cagrilir;
    her ikisinde de dosya boyutu = VDB_PAGE_SIZE, dolayisiyla konum sondadir. }
  FAtEnd := True;
end;

procedure TVDbPageWal.ReadHeader;
var
  buf: TVDbPageBuf;
  magic, ver, lsn, crc: LongWord;
  flags: LongWord;
  storedCheck, storedSalt, storedId: TBytes;
  i: Integer;
  ps: Word;
  q: PLongWord;
begin
  if FStream.Size < VDB_PAGE_SIZE then
    raise EVdbWal.Create(Format('WAL dosyasi cok kucuk (%d bayt)', [FStream.Size]));
  FStream.Position := 0;
  FStream.ReadBuffer(buf, VDB_PAGE_SIZE);
  FAtEnd := False;   // P-57: konum VDB_PAGE_SIZE'ta; dosya sonunda olmayabilir
  Move(buf[0], magic, 4);
  if magic <> VDB_WAL_MAGIC then
    raise EVdbWal.Create(Format('gecersiz WAL sihirli sayisi: $%.8x', [magic]));
  Move(buf[4], ver, 4);
  if (ver < VDB_WAL_VER_COMPAT) or (ver > VDB_WAL_VER) then
    raise EVdbWal.Create(Format('desteklenmeyen WAL surumu: %d', [ver]));
  FWalVer := ver;
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

  { R2-C-YENI-2: kimlik dogrulamasi. Alan sifirsa dosya bu korumadan ONCE
    yazilmistir (uyumluluk: dogrulama yapilmaz). Sifir degilse guncel
    veritabani kimligiyle karsilastirilir.
      * Govde VARSA ve kimlik farkli -> eski WAL baska DB'ye aittir;
        uygulanmasi veri bozulmasi demektir -> ACIK HATA.
      * Govde BOSSA (yalniz baslik) -> uygulanacak cerceve yok; yazilabilir
        oturumda baslik yeni kimlik + LSN 0 ile tazelenir. Boylece ayni
        yolda silinip yeniden yaratilan DB eski bos .wal yuzunden acilmaz
        hale gelmez. }
  SetLength(storedId, VDB_WAL_DBID_LEN);
  Move(buf[VDB_WAL_DBID], storedId[0], VDB_WAL_DBID_LEN);
  if not BytesAllZero(storedId) then
  begin
    EnsureDbId;
    if FDbIdKnown then
    begin
      if not BytesEqual(storedId, FDbId) then
      begin
        if FStream.Size > VDB_PAGE_SIZE then
          raise EVdbWal.Create(
            'WAL baska bir veritabanina ait (kimlik farkli); ' +
            'eski WAL dosyasini silin');
        if not FReadOnlyMode then
        begin
          FLSN := 0;
          FHeaderLsn := 0;
          WriteHeader;
        end;
      end;
    end
    else if FStream.Size > VDB_PAGE_SIZE then
      raise EVdbWal.Create(
        'WAL veritabani kimligi dogrulanamadi (veri dosyasi okunamadi)');
  end;
end;

{ ------------------------------------------------------------------ yasam }

constructor TVdbPageWal.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  FBufferCount := 0;
  FHasContent := False;
  FAtEnd := False;
  FLSN := 0;
  FHeaderLsn := 0;
  FWalVer := VDB_WAL_VER;   // P-53: Open/ReadHeader gunceller
  SetLength(FAppliedPages, 0);
  FEncryptedMode := False;
  FWalEncrypted := False;
  FKey := nil;
  FSalt := nil;
  FKeyCheck := nil;
  FDbId := nil;
  FDbIdKnown := False;
  { R2-C-YENI-1: acik dosya yokken "yazilmis" LSN iddiasi yoktur. }
  FWrittenLsn := 0;
  FWrittenBytes := 0;
  FScanPos := 0;
  FScanHdrLsn := 0;
  FUnsyncedStartPos := 0;
  FUnsyncedBaseValid := False;
  FSyncFault := False;
  FWriteCs := TCriticalSection.Create;
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
  FWriteCs.Free;
  inherited Destroy;
end;

procedure TVdbPageWal.Open(AReadOnly: Boolean);
var
  hasFile: Boolean;
begin
  if FStream <> nil then Exit;
  FReadOnlyMode := AReadOnly;
  { R2-C-3: yeni gorunumde onceki nesnenin isaretli bolgesi devralinmaz. }
  FUnsyncedBaseValid := False;
  FUnsyncedStartPos := 0;
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
      FWrittenBytes := FStream.Size;
      { R2-C-YENI-1: yeni bir gorunum. Baslik LSN'i alt sinirdir; Recover
        govdedeki son commit'e yukseltir. Onceki oturumdan kalan deger
        TASINMAZ (dosya/DB degismis olabilir). }
      FWrittenLsn := FLSN;
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
    FWrittenBytes := 0;
    FWrittenLsn := 0;
  end
  else
  begin
    { v3.16: WAL dosyasi da PAYLASIMA ACIK olmali; ayni veritabanina ikinci
      bir surec/oturum acabilmeli. Yazma yine veritabani kilidiyle siralanir. }
    FStream := TFileStream.Create(FPath, fmCreate or fmShareDenyNone);
    FLSN := 0;
    FWrittenLsn := 0;
    WriteHeader;
    VDbFlushStream(FStream);
    FWalEncrypted := FEncryptedMode;
    FHasContent := False;
    FWrittenBytes := FStream.Size;
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
  { R2-C-YENI-1: FWrittenLsn ASLA DUSURULMEZ. Baslik LSN'i yalnizca
    checkpoint isaretidir; govdede daha yeni yazilmis kayitlar olabilir.
    Eski `FWrittenLsn := FLSN` degeri geri cekiyordu; AwaitDurable'daki
    `ALsn > WrittenLsn -> Exit` erken cikisi fsync'i SESSIZCE atliyor ve
    fsync edilmemis commit "durabil" sayiliyordu. Yukari yonlu guncelleme
    guvenlidir: en kotu durumda fazladan bir fsync yapilir. }
  if FLSN > FWrittenLsn then
    FWrittenLsn := FLSN;
  { FStream.Size her cagrida isletim sistemine sorulur; baska surecin
    uzattigi dosya buradan gorulur. }
  FHasContent := FStream.Size > VDB_PAGE_SIZE;
  FWrittenBytes := FStream.Size;
end;

function TVdbPageWal.HasContent: Boolean;
begin
  Result := FHasContent;
end;

{ ----------------------------------------------------------------- cerceve }

function TVdbPageWal.BufferedPageIndex(PageNo: LongWord): Integer;
var
  h: LongWord;
begin
  { P-71: dogrusal tarama yerine acik-sondalama (yukarida alan yorumu). }
  Result := -1;
  if FBufHashCap = 0 then Exit;
  h := (PageNo * LongWord(2654435761)) and LongWord(FBufHashCap - 1);
  while FBufHash[h] <> 0 do
  begin
    if FBufHash[h] = PageNo + 1 then
      Exit(FBufHashIdx[h]);
    h := (h + 1) and LongWord(FBufHashCap - 1);
  end;
end;

procedure TVdbPageWal.BufHashRawPut(PageNo: LongWord; Idx: Integer);
var
  h: LongWord;
begin
  h := (PageNo * LongWord(2654435761)) and LongWord(FBufHashCap - 1);
  while FBufHash[h] <> 0 do
    h := (h + 1) and LongWord(FBufHashCap - 1);
  FBufHash[h] := PageNo + 1;
  FBufHashIdx[h] := Idx;
end;

procedure TVdbPageWal.BufHashGrow;
var
  ncap, i: Integer;
begin
  ncap := FBufHashCap * 2;
  if ncap = 0 then ncap := 1024;
  { DIKKAT: SetLength var olan girisleri KORUR (yalnizca kuyrugu sifirlar).
    Eski girisler eski maskeyle yerlestirilmisti; tablo once TAMAMEN
    bosaltilip yeni maskeyle yeniden kurulmazsa her buyumede bayat
    girisler ikiye katlanir, tablo dolar ve sondalama sonsuz donguye girer. }
  SetLength(FBufHash, ncap);
  SetLength(FBufHashIdx, ncap);
  FillChar(FBufHash[0], ncap * 4, 0);
  FBufHashCap := ncap;
  { Yeniden yerlestirme: en yeni cerceve (FFramePages[FBufferCount-1])
    AppendBuffer'da RawPut ile eklenecegi icin burada atlanir — yoksa
    iki kez girilir. }
  for i := 0 to FBufferCount - 2 do
    BufHashRawPut(FFramePages[i], i);
end;

procedure TVdbPageWal.BufHashClear;
begin
  { Cagiran FBufferCount'i sifirlarken cagirir; sira bagimliligi olmasin
    diye kosulsuz temizlenir (32K yuvali tabloda ~128 KB FillChar). }
  if FBufHashCap > 0 then
    FillChar(FBufHash[0], FBufHashCap * 4, 0);
end;

procedure TVdbPageWal.AppendBuffer(PageNo: LongWord; P: PVdbPage);
var
  i, off, payLen, ncap: Integer;
  plain, env: TBytes;
begin
  { v4: yuk dogrudan FOutBuf'a yazilir; ara TPending kopyasi yok.
    Eski akis: P → FBuffer (4KB Move) → Commit'te FOutBuf (4KB Move).
    Yeni akis: P → FOutBuf (tek Move). Dedup son yazim kazanir (ayni). }
  if FWalEncrypted then
    payLen := VDB_ENC_ENVELOPE
  else
    payLen := VDB_PAGE_SIZE;
  i := BufferedPageIndex(PageNo);
  if i < 0 then
  begin
    i := FBufferCount;
    Inc(FBufferCount);
    { P-70: geometrik buyume — onceden her cercevede +64 giris; 12K
      cercevelik committe 12K SetLength, her biri diziyi bastan kopyalar. }
    if FBufferCount > Length(FFramePages) then
      SetLength(FFramePages, FBufferCount * 2 + 64);
    FFramePages[i] := PageNo;
    { P-71: dedup haritasina ekle (%75 dolulukta buyur). }
    if (FBufHashCap = 0) or (FBufferCount * 4 >= FBufHashCap * 3) then
      BufHashGrow;
    BufHashRawPut(PageNo, i);
  end;
  off := i * (VDB_WAL_REC_HDR + payLen) + VDB_WAL_REC_HDR;
  { P-70: GEOMETRIK buyume — onceden her cercevede tampon yalnizca BIR
    cerceve kadar buyutuluyordu; yerinde genisleme basarisiz olursa her
    SetLength tum tamponu bastan kopyalar (12K cerceve = kuadratik; 1M
    satirlik committe olculen 1,6 s). Kapasite artik ikiye katlanir. }
  if Length(FOutBuf) < off + payLen + VDB_WAL_REC_HDR then
  begin
    ncap := Length(FOutBuf) * 2;
    if ncap < off + payLen + VDB_WAL_REC_HDR then
      ncap := off + payLen + VDB_WAL_REC_HDR;
    Inc(ncap, 8192);
    SetLength(FOutBuf, ncap);
  end;
  if FWalEncrypted then
  begin
    SetLength(plain, VDB_PAGE_SIZE);
    Move(P^, plain[0], VDB_PAGE_SIZE);
    if not VDbPageSeal(FKey, FSalt, PageNo, plain, env) then
      raise EVdbWal.Create(Format('WAL cercevesi %d sifrelenemedi',
        [PageNo]));
    Move(env[0], FOutBuf[off], payLen);
  end
  else
    Move(P^, FOutBuf[off], payLen);
end;

procedure TVdbPageWal.AppendFrame(PageNo: LongWord; P: PVdbPage; ALsn: LongWord);
begin
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  if FReadOnlyMode then
    raise EVdbWal.Create('salt-okunur WAL: cerceve eklenemez');
  { Cerceve DISKE YAZILACAK bir imajdir: CRC'si simdi hesaplanir. Boylece
    kurtarma sirasinda yazilan sayfa PageVerify'dan gecer. }
  { C-16: SIRA ONEMLI - damga (1) once, CRC (2) sonra, tampona kopya (3)
    en son. CRC tum sayfayi kapsadigi icin damga CRC'den SONRA yazilirsa
    hem WAL imaji hem disk imaji dogrulamadan gecmezdi.
    Meta sayfa (VDB_WAL_META_PAGE) ISTISNADIR: bu sayfa normal sayfa
    basligi tasimaz; offset 20 FFreeCount'tur (VDbPageStore.BuildMetaImage).
    Damga yazmak freelist sayacini bozardi, bu yuzden atlanir. Meta'nin
    kendi LSN'i zaten offset 24'tedir ve motor imaji kurarken yazar.
    Meta page 0 oldugu icin "PageNo <> 0" ile ayni; sabit okunurluk icin.
    Freelist trunk sayfasinda (VFT1) offset 20 IKINCI GIRDIDIR: damga oraya
    yazilirsa PageSeal CRC'yi bozulmus icerik uzerinden tazeler ve trunk
    sessizce bozulur (freelist yanlis sayfa verir -> veri kaybi). Damga
    yalnizca gercek VDbPage imajlarina (VP sihirli sozcugu) yazilir. }
  if (PageNo <> VDB_WAL_META_PAGE) and
     (PageHdr(P)^.Magic = VDB_PAGE_MAGIC) then
    PageHdr(P)^.LSN := ALsn;
  PageSeal(P);
  AppendBuffer(PageNo, P);
end;

procedure TVdbPageWal.Rollback;
begin
  FBufferCount := 0;
  BufHashClear;   // P-71
end;

procedure TVdbPageWal.DebugSetSyncFault(AValue: Boolean);
begin
  FSyncFault := AValue;
end;

procedure TVdbPageWal.SyncDurable;
var
  S: TFileStream;
  capPos: Int64;
begin
  { v3.19 GRUP COMMIT: kayitlar zaten yazildi (Commit(False)); burada yalniz
    isletim sisteminin tamponlari diske indirilir. Tek lider cagirir.
    AYRI handle kullanilir: fsync baska bir thread'in yazmasiyla ayni anda
    calisabilir; TFileStream'in konumu ortak oldugu icin FStream uzerinde
    fsync yapmak yaris durumu uretirdi. }
  if FReadOnlyMode then Exit;
  S := FSyncStream;
  if S = nil then
    { R2-C-YENI-1: fsync kanali yoksa "basarili" donmek yanlis durabil
      onayi olurdu. Yazilabilir WAL'de bu kanal Open'da kurulur; yoklugu
      gercek bir hatadir. }
    raise EVdbWal.Create('WAL fsync kanali yok (durabilite dogrulanamaz)');
  { R2-C-3: fsync'in KAPSADIGI son konum. Bu ana kadar tamamlanmis
    yazimlar fsync baslamadan once disk onbellegine girmistir; sirasinda
    yazilanlar garanti degildir. }
  FWriteCs.Enter;
  try
    capPos := FWrittenBytes;
  finally
    FWriteCs.Leave;
  end;
  try
    if FSyncFault then
      raise EVdbWal.Create('WAL fsync hatasi (test kancasi)')
    else
      VDbFlushStream(S);
  except
    { R2-C-3 (kalan): fsync basarisiz -> istemci commit'i BASARISIZ goruyor,
      ama kayitlar dosyada. Kurtarma bunlari "hayalet commit" olarak
      uygulardi. Son basarili durabilite noktasindan sonra yazilan TUM
      bolumu geri kirp. Eszamanli yazimlar da bu bolgeye dahildir; motor
      FSyncErr'i kalici oldugundan onlarin cagiranlari da hata alir.
      FWrittenLsn GERI CEKILMEZ (R2-C-YENI-1): eszamanli bekleyen bir
      AwaitDurable erken cikip basarisiz commit'i basarili sanmamali. }
    FWriteCs.Enter;
    try
      if FUnsyncedBaseValid then
      begin
        try
          FStream.Size := FUnsyncedStartPos;
          FStream.Seek(0, soEnd);
          FWrittenBytes := FUnsyncedStartPos;
          FAtEnd := True;
          { Geriye yalniz baslik kaldiysa govde de bos demektir. }
          if FUnsyncedStartPos <= VDB_PAGE_SIZE then
            FHasContent := False;
          FUnsyncedBaseValid := False;
        except
          { En iyi caba; asil fsync hatasini maskeleme. Isaret korunur ki
            sonraki deneme kirpmayi yeniden denesin. }
        end;
      end;
    finally
      FWriteCs.Leave;
    end;
    raise;
  end;
  { Basarili fsync: capPos'a kadar durabil. Daha SONRA yazilan kayitlar
    varsa isaret oradan (ya da daha yeni bir isaret varsa o noktadan)
    devam eder. ONEMLI: var olan isaret capPos'tan YENIYSE geri cekilmez;
    aksi halde sonraki bir fsync hatasi, bu kez BASARILI raporlanmis bir
    commit'i de geri kirparak sessiz veri kaybina yol acardi. }
  FWriteCs.Enter;
  try
    if FWrittenBytes > capPos then
    begin
      if (not FUnsyncedBaseValid) or (FUnsyncedStartPos < capPos) then
        FUnsyncedStartPos := capPos;
      FUnsyncedBaseValid := True;
    end
    else
      FUnsyncedBaseValid := False;
  finally
    FWriteCs.Leave;
  end;
end;

function TVdbPageWal.Commit(DoSync: Boolean; LSN: LongWord): Boolean;
var
  i, total, off, payLen: Integer;
  magic, zero, crc: LongWord;
  startPos, writeEnd: Int64;
  baseSet: Boolean;
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
  { v4: yuk zaten AppendBuffer'da FOutBuf'a yazildi; yalniz baslik + CRC. }
  total := FBufferCount * (VDB_WAL_REC_HDR + payLen) + VDB_WAL_REC_HDR;
  if Length(FOutBuf) < total then
    SetLength(FOutBuf, total + 8192);
  off := 0;
  magic := VDB_WAL_REC_FRAME;
  zero := 0;
  for i := 0 to FBufferCount - 1 do
  begin
    Move(magic, FOutBuf[off], 4);
    Move(FLSN, FOutBuf[off + 4], 4);
    Move(payLen, FOutBuf[off + 8], 4);
    Move(FFramePages[i], FOutBuf[off + 12], 4);
    { P-53: surum 2'de CRC yalniz baslik uzerinden — yuk butunlugu
      PageSeal'de. Surum 1'de eski bicim (baslik + yuk) korunur. }
    if FWalVer >= 2 then
      crc := WalCrc(FOutBuf[off], 16, FOutBuf[off], 0)
    else
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
  baseSet := False;
  FWriteCs.Enter;
  try
    { P-57: konum zaten sondaysa Seek atlaniyor. Tek surecli modda Commit
      sonrasi konum sondadir; Refresh/Recover/ReadHeader disaridan gelir. }
    if not FAtEnd then
      FStream.Seek(0, soEnd);
    startPos := FStream.Position;   // R2-C-3: geri kirpma noktasi
    { R2-C-3 (kalan): grup commit (DoSync=False) yolunda fsync sonradan
      SyncDurable'da yapilir. Son basarili durabilite noktasindan sonraki
      ILK yazimin basini isaretle; fsync hatasinda oraya geri kirpilir. }
    if (not DoSync) and (not FUnsyncedBaseValid) then
    begin
      FUnsyncedStartPos := startPos;
      FUnsyncedBaseValid := True;
      baseSet := True;
    end;
    try
      FStream.WriteBuffer(FOutBuf[0], off);
    except
      { R2-C-3 artigi: yazim yarida kaldiysa dosyada kesik/bayat bir kuyruk
        kalir. Sonraki commit onun ARDINA eklenir; kurtarma kesik kayitta
        durdugu icin SONRAKI commit'ler de gorunmez olurdu (sessiz kayip).
        Bu commit'e ait bolumu geri kirp; tampon korunur (cagiran tekrar
        deneyebilir). }
      try
        FStream.Size := startPos;
        FStream.Seek(0, soEnd);
        FWrittenBytes := startPos;
        FAtEnd := True;
      except
        { En iyi caba; asil hatayi maskeleme. }
      end;
      { Yalniz BU commit icin konulan isaret geri alinir; daha onceki
        durabil olmayan bolgenin isareti korunur. }
      if baseSet then FUnsyncedBaseValid := False;
      raise;
    end;
    FAtEnd := True;   // P-57: konum artik dosya sonunda
    Inc(FWrittenBytes, off);   // P-61: boyut sayaci
    writeEnd := FWrittenBytes;
  finally
    FWriteCs.Leave;
  end;
  { Cok buyuk islemlerden sonra tamponu birak: aksi halde WAL nesnesi omru
    boyunca onlarca MB tutulur. Normal commit'lerde tampon yeniden kullanilir. }
  if Length(FOutBuf) > 4 * 1024 * 1024 then
    SetLength(FOutBuf, 0);
  if DoSync then
  begin
    try
      if FSyncFault then
        raise EVdbWal.Create('WAL fsync hatasi (test kancasi)')
      else
        VDbFlushStream(FStream);
    except
      { C-14: kayitlar WriteBuffer ile dosyaya zaten yazildi. Tampon
        durumunu temizle ki yeniden deneme ayni kayitlari ikinci kez
        yazmasin (4 MB ustu tampon sifirlanmissa sifir yuk yazilirdi). }
      FBufferCount := 0;
      BufHashClear;
      SetLength(FOutBuf, 0);
      { R2-C-3: fsync basarisiz -> istemci commit'i BASARISIZ goruyor. Dosyada
        kalan tam commit kaydi kurtarmada "hayalet commit" olarak uygulanirdi.
        Bu commit'e ait yazilan bolumu geri kirp (tek yazar varsayimi: WAL'e
        yazim dis kilit/mutex ile serilestirilir). }
      FWriteCs.Enter;
      try
        try
          FStream.Size := startPos;
          FStream.Seek(0, soEnd);
          FWrittenBytes := startPos;
          FAtEnd := True;
          { Eszamanli bir yazarin isareti bu kesme noktasinin OTESINDEYSE
            o bolge de silindi; isaret gecersizdir (aksi halde sonraki
            geri kirpma dosyayi sifirla uzatirdi). }
          if FUnsyncedBaseValid and (FUnsyncedStartPos > startPos) then
            FUnsyncedBaseValid := False;
        except
          { Kirpma da basarisizsa ASIL hatayi maskeleme; FSyncErr kalici
            oldugu icin sonraki commit'ler de hata verir. }
        end;
      finally
        FWriteCs.Leave;
      end;
      raise;
    end;
    { R2-C-3: fsync BASARILI. writeEnd'e kadar olan her sey durabil; bu
      noktaya kadarki isaret temizlenir. fsync SIRASINDA baska thread'in
      yazdigi kayitlar (FWrittenBytes > writeEnd) garanti kapsaminda
      degildir: onlar icin isaret writeEnd'den baslatilir. Var olan isaret
      writeEnd'den YENIYSE korunur (bkz. SyncDurable ayni kural). }
    FWriteCs.Enter;
    try
      if FWrittenBytes > writeEnd then
      begin
        if (not FUnsyncedBaseValid) or (FUnsyncedStartPos < writeEnd) then
          FUnsyncedStartPos := writeEnd;
        FUnsyncedBaseValid := True;
      end
      else
        FUnsyncedBaseValid := False;
    finally
      FWriteCs.Leave;
    end;
  end;
  FBufferCount := 0;
  BufHashClear;   // P-71
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
  maxLsn: LongWord;
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
  FAtEnd := False;   // P-57: Recover dosyayi tarar; konum son degildir
  hdrLsn := FLSN;
  { R2-C-YENI-1: tarama boyunca gorulen en buyuk LSN. Yalnizca CRC'den
    GECEN kayitlar sayilir (bozuk basliktaki LSN durabilite filigranini
    sisirmesin). MinLSN ile atlanan kayitlar zaten bu surecin yazmadigi,
    daha onceki yazarlara ait kayitlardir. FWrittenLsn yalnizca yukari
    guncellenir (asla geri cekilmez). }
  maxLsn := FLSN;
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
      { P-53: surum 2'de CRC yalniz baslik uzerinden hesaplandi (yukarida);
        yuk butunlugu asagida PageSeal ile dogrulanir. Surum 1'de eski
        bicim: CRC baslik + yuk uzerinden. }
      if FWalVer < 2 then
        calc := WalCrc(hdr[0], 16, raw[0], payLen);
    end;
    if calc <> crc then
    begin
      Stats.TornTail := True;
      Break;
    end;
    { R2-C-YENI-1: yalniz CRC'den GECEN kayit "yazilmis" sayilir. Bozuk
      basliktaki LSN'in durabilite filigranini (.gen) sisirmesine izin
      verme. }
    if lsn > maxLsn then
      maxLsn := lsn;

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
      { P-52: sayfa ici CRC dogrulamasi. AppendFrame'de PageSeal ile yazilan
        deger karsilastirilir. WalCrc tasiyici bozulmayi yakalar; bu denetim
        sayfa govdesinin ic butunlugunu ayrica dogrular — ileride WalCrc
        yalniz basliga indirilirse tek guvenlik katmani bu olur. }
      if PageCrcCalc(PVdbPage(@payload[0])) <>
         PageCrcStored(PVdbPage(@payload[0])) then
      begin
        Stats.TornTail := True;
        Break;
      end;
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
      begin
        { C-15: kesilmeden once konumu kaydet; aksi halde sonraki artimsal
          tarama ayni commit kaydini yeniden okur. }
        goodPos := FStream.Position;
        Break;
      end;
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
    son commit'in LSN'idir. R2-C-YENI-1: yalniz YUKARI guncelle - MinLSN
    ile atlanan kayitlar yuzunden degeri geri cekmek, fsync'i atlayan
    yanlis "durabil" onayina yol acabilir. }
  if FLSN > maxLsn then
    maxLsn := FLSN;
  if maxLsn > FWrittenLsn then
    FWrittenLsn := maxLsn;
  FScanPos := goodPos;
  FScanHdrLsn := hdrLsn;
  Result := True;
end;

function TVdbPageWal.CommitCount: Integer;
var
  st: TVdbWalStats;
  oldLSN: LongWord;
  oldWritten: LongWord;
  oldScanPos: Int64;
  oldScanHdrLsn: LongWord;
  oldAtEnd: Boolean;
begin
  if (FStream = nil) or (not FHasContent) then
    Exit(0);
  { Apply = nil: yalnizca dogrulanmis commit'ler sayilir. Recover FLSN'i
    son commit'e ceker; canli WAL'de bu yan etki istenmez. }
  oldLSN := FLSN;
  oldWritten := FWrittenLsn;
  { R2-C-4: Recover artimsal tarama imlecini (FScanPos/FScanHdrLsn) de
    degistirir. Sayim yalniz okuma amaclidir; imlec geri konmazsa eszamanli
    artimsal tazeleme (StoreRefreshed) yanlis konumdan surer ve kayit
    atlayabilir. Bu yuzden TUM tarama durumu geri yuklenir. }
  oldScanPos := FScanPos;
  oldScanHdrLsn := FScanHdrLsn;
  oldAtEnd := FAtEnd;
  try
    Recover(nil, st);
    Result := st.Commits;
  finally
    FLSN := oldLSN;
    FWrittenLsn := oldWritten;
    FScanPos := oldScanPos;
    FScanHdrLsn := oldScanHdrLsn;
    FAtEnd := oldAtEnd;
  end;
end;

function TVdbPageWal.WalBodySafeToPrune(CheckpointLSN: LongWord;
  out AMaxLsn: LongWord): Boolean;
var
  fileSize, oldPos: Int64;
  hdr: array[0..VDB_WAL_REC_HDR - 1] of Byte;
  magic, lsn, payLen, crc, calc: LongWord;
  expectedLen: LongWord;
  got: Integer;
  raw: TBytes;
begin
  { C-1: FILTRELIDIR. Govde yalnizca TUM gecerli kayitlarin LSN'i
    CheckpointLSN'den kucuk/esitse budanabilir. Checkpoint'in otesinde
    (henuz veri dosyasina inmeyen, or. baska surecin) bir commit varsa
    govdeye DOKUNULMAZ. Kesik/bozuk kuyruk "gecerli kayit" degildir;
    kurtarma da orada durur, dolayisiyla budama guvenlidir.
    AMaxLsn: CRC'den gecen kayitlarin en buyuk LSN'i. }
  Result := True;
  AMaxLsn := 0;
  fileSize := FStream.Size;
  oldPos := FStream.Position;
  try
    FStream.Position := VDB_PAGE_SIZE;
    while FStream.Position + VDB_WAL_REC_HDR <= fileSize do
    begin
      got := FStream.Read(hdr[0], VDB_WAL_REC_HDR);
      if got <> VDB_WAL_REC_HDR then Break;
      Move(hdr[0], magic, 4);
      Move(hdr[4], lsn, 4);
      Move(hdr[8], payLen, 4);
      Move(hdr[16], crc, 4);
      if (magic <> VDB_WAL_REC_FRAME) and (magic <> VDB_WAL_REC_COMMIT) then
        Break;
      if magic = VDB_WAL_REC_FRAME then
      begin
        if FWalEncrypted then expectedLen := VDB_ENC_ENVELOPE
        else expectedLen := VDB_PAGE_SIZE;
        if payLen <> expectedLen then Break;
      end
      else if payLen <> 0 then
        Break;
      calc := WalCrc(hdr[0], 16, hdr[0], 0);
      if payLen > 0 then
      begin
        if payLen > 65536 then Break;
        SetLength(raw, payLen);
        got := FStream.Read(raw[0], payLen);
        if got <> Integer(payLen) then Break;
        if FWalVer < 2 then
          calc := WalCrc(hdr[0], 16, raw[0], payLen);
      end;
      if calc <> crc then Break;
      if lsn > AMaxLsn then
        AMaxLsn := lsn;
      if lsn > CheckpointLSN then
      begin
        Result := False;
        Break;
      end;
    end;
  finally
    FStream.Position := oldPos;
  end;
end;

procedure TVdbPageWal.Truncate(CheckpointLSN: LongWord);
var
  safe: Boolean;
  maxLsn: LongWord;
begin
  if FReadOnlyMode then Exit;
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  safe := WalBodySafeToPrune(CheckpointLSN, maxLsn);
  if not safe then
  begin
    { C-1: checkpoint'in otesinde cerceveler var -> HICBIR SEY budanmaz.
      Baslik da YAZILMAZ: yarim kalmis bir geciste (crash) dosyanin ESKI
      hali oldugu gibi gecerlidir. Bekleyen bellek tamponu da ATILMAZ:
      diske yazilmamis bir commit'i sessizce silmek veri kaybi olurdu.
      FWrittenLsn geri cekilmez; tarama sirasinda gorulen en buyuk LSN'e
      kadar yukseltilir. }
    if CheckpointLSN > FWrittenLsn then
      FWrittenLsn := CheckpointLSN;
    if maxLsn > FWrittenLsn then
      FWrittenLsn := maxLsn;
    Exit;
  end;
  { Yalniz GUVENLI budama yolunda bekleyen tampon atilir (zaten diske
    yazildi; asagida govde silinip baslik yeniden yazilacak). }
  FBufferCount := 0;
  { R2-C-3: govde silinip fsync edilecegi icin bekleyen durabilite
    isareti anlamsizlasir. }
  FUnsyncedBaseValid := False;
  BufHashClear;   // P-71
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
  FStream.Size := VDB_PAGE_SIZE;
  FWrittenBytes := VDB_PAGE_SIZE;   // P-61
  WriteHeader;
  FStream.Seek(0, soEnd);
  FAtEnd := True;
  VDbFlushStream(FStream);
  FHasContent := False;
end;

function TVdbPageWal.Bytes: Int64;
var
  payLen: Integer;
begin
  if FStream = nil then
    Exit(0);
  { C-13: sifreli modda cerceve yuku VDB_ENC_ENVELOPE kadardir. }
  if FWalEncrypted then
    payLen := VDB_ENC_ENVELOPE
  else
    payLen := VDB_PAGE_SIZE;
  Result := FWrittenBytes +
    Int64(FBufferCount) * (payLen + VDB_WAL_REC_HDR);
end;

end.
