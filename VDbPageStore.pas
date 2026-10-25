unit VDbPageStore;

{ VDB v3 - Sayfa Deposu (Sprint 1 / Gun 2-3)

  Gorev: 4 KB sayfalari dosyadan okumak/yazmak, buffer pool ile onbelleklemek,
  sayfa ayirmak/serbest birakmak.

  Dosya yerlesimi:
    sayfa 0        : baslik (VDB3 sihirli sayi, surum, sayfa sayisi, freelist)
    sayfa 1..N     : veri sayfalari

  Baslik sayfasi 0 bir "veri sayfasi" DEGILDIR; kendi CRC'si ve alanlari
  vardir. Veri sayfalari VDbPage.pas formatindadir.

  Buffer pool: CLOCK (ikinci sans). Pin sayisi > 0 olan sayfa tahliye
  edilemez. CRC, sayfa DISKE yazilirken (Flush) hesaplanir; bellekteki
  her yazmada 4 KB CRC odenmez.

  Freelist: LIFO yigin. Trunk sayfalari 4 baytlik sayfa numaralari tutar,
  dolunca yeni trunk basa eklenir (tek bagli liste). Bosalan sayfa sayisi
  meta sayfada ayrica tutulur.

  Bilincli sinirlar:
  - Tek yazici, i$ parcacigi yok (kilit cagirana ait).
  - WAL yok; bu birim dogrudan dosyaya yazar. Sayfa-imajli WAL (Gun 5)
    Flush'in tek yazma noktasi olmasindan yararlanarak araya girecek.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, Generics.Collections, VDbCrc32, VDbPage, VDbSync,
  VDbCrypt, VDbPageCrypto;

const
  VDB_FILE_MAGIC   = $33424456;   // 'VDB3' (little endian)
  VDB_FILE_VER     = 3;
  VDB_V2_MAGIC     = $56444231;   // v2 'VDB1' — net goc hatasi icin
  VDB_HDR_PAGE     = 0;
  VDB_DEF_POOL     = 512;         // 512 x 4 KB = 2 MB
  VDB_MAX_POOL     = 65536;

  { v3.1: dosya buyutme parcasi. Her yeni sayfada ayri SetSize cagrisi
    ~45-50 us suruyordu (200k satirlik yazimda ~200 ms). Artik dosya
    64 sayfalik (256 KB) parcalarla uzatilir; kapanista mantiksal boya
    kirpilir. Kayipsiz: fazla baytlar sayfa sayacinin otesindedir. }
  VDB_GROW_BYTES   = 262144;

  { Sprint 3.4: meta sayfa alanlari (duz metin; sir tutmaz). }
  VDB_META_SALT     = 36;   // 16 bayt
  VDB_META_ITER     = 52;   // LongWord
  VDB_META_KEYCHECK = 56;   // 16 bayt
  VDB_META_FLAGS    = 72;   // LongWord
  VDB_META_FLAG_ENC = 1;

  { Freelist trunk sayfasi (ham 4096 bayt, VDbPage basligi KULLANILMAZ). }
  VDB_TRUNK_MAGIC  = $31544656;   // 'VFT1'
  VDB_TRUNK_HDR    = 16;
  VDB_TRUNK_MAX    = (VDB_PAGE_BODY_END - VDB_TRUNK_HDR) div SizeOf(LongWord);

type
  EVdbPageStore = class(Exception);

  { Kirli sayfa onbellege sigmadiginda, DISKE YAZILMADAN ONCE cagrilir.
    v3 motoru bunu WAL'e cerceve eklemek icin kullanir (write-ahead).
    Atanmamis ise sayfa dogrudan diske yazilir (WAL'siz kullanim). }
  TVdbPageSpillProc = procedure(PageNo: LongWord; P: PVdbPage) of object;

  { Onbellekte olmayan sayfa icin alternatif kaynak (WAL tamponu).
    True donerse sayfa imaji P'ye yazilmis olmalidir; diskten okunmaz. }
  TVdbPageMissProc = function(PageNo: LongWord; P: PVdbPage): Boolean of object;

  TVdbPageNoArray = array of LongWord;

  TVDbStoreStats = record
    PageCount: LongWord;   // dosyadaki toplam sayfa (0 dahil)
    FreeCount: LongWord;   // freelist'teki sayfa sayisi
    UsedCount: LongWord;   // PageCount - 1 - FreeCount
    PoolPages: Integer;
    PoolUsed: Integer;
    Reads: Int64;
    Writes: Int64;
    Evictions: Int64;
    FileBytes: Int64;
  end;

  TVDbPageStore = class
  private
    type
      TFrame = record
        PageNo: LongWord;      // 0 = bos cerceve
        Data: TVDbPageBuf;
        Pins: Integer;
        Dirty: Boolean;
        Ref: Boolean;
      end;
    var
      FPath: string;
      FStream: TFileStream;
      FPoolPages: Integer;
      FFrames: array of TFrame;
      FHashKey: array of LongWord;   // 0 = bos
      FHashVal: array of Integer;
      FHashMask: LongWord;
      FClock: Integer;
      FPageCount: LongWord;
      FFreeTrunk: LongWord;
      FFreeCount: LongWord;
      FLSN: LongWord;
      FCreated: Int64;
      FReads: Int64;
      FWrites: Int64;
      FEvictions: Int64;
      FMetaDirty: Boolean;
      FLocked: Boolean;
      FReadOnly: Boolean;
      FOnSpill: TVdbPageSpillProc;
      FOnMiss: TVdbPageMissProc;
      FSpillActive: Boolean;
      { Sprint 3.4: sayfa sifreleme. }
      FEncrypted: Boolean;
      FKey: TBytes;
      FSalt: TBytes;
      FKeyCheck: TBytes;
      FPassword: TBytes;
      FHasPassword: Boolean;
      FIterations: Integer;
      FFreshPage: LongWord;
      { v3.1: dosyanin FIZIKSEL boyu (onceden ayrilmis parca dahil).
        Mantiksal boy = RequiredFileSize(FPageCount); kapanista kirpilir. }
      FPhysSize: Int64;
    function HashOf(PageNo: LongWord): LongWord;
    function FindFrame(PageNo: LongWord): Integer;
    procedure HashPut(PageNo: LongWord; Idx: Integer);
    procedure HashDel(PageNo: LongWord);
    procedure HashReset;
    function LoadFrame(PageNo: LongWord): Integer;
    function PickVictim: Integer;
    function GetPageInternal(PageNo: LongWord; DoVerify: Boolean;
      out P: PVdbPage): Boolean;
    function OffsetOf(PageNo: LongWord): Int64;
    function RequiredFileSize(PageCount: LongWord): Int64;
    procedure SetupEncryptionForCreate;
    procedure CheckEncryptionOnOpen(const Meta: TVdbPageBuf);
    procedure ReadPageAt(PageNo: LongWord; P: PVdbPage);
    procedure WritePageAt(PageNo: LongWord; P: PVdbPage);
    procedure ExtendFile(out NewPageNo: LongWord);
    procedure GrowTo(Required: Int64);
    procedure TrimToLogical;
    procedure LoadMeta;
    procedure SaveMeta;
    function TrunkGet(var P: PVdbPage): LongWord;   // count
    procedure TrunkSetCount(P: PVdbPage; N: LongWord);
    function TrunkEntry(P: PVdbPage; I: Integer): LongWord;
    procedure TrunkSetEntry(P: PVdbPage; I: Integer; V: LongWord);
    function TrunkNext(P: PVdbPage): LongWord;
    procedure TrunkSetNext(P: PVdbPage; V: LongWord);
    procedure TrunkInit(P: PVdbPage; PageNo, NextTrunk: LongWord);
    procedure TrunkSeal(P: PVdbPage);
    function TrunkCheck(P: PVdbPage; out Err: string): Boolean;
  public
    constructor Create(const APath: string; APoolPages: Integer = VDB_DEF_POOL);
    destructor Destroy; override;

    { ACreate=False ise dosya yoksa hata verir. ACreate=True ise yoksa
      VDB3 dosyasi olusturur, varsa acar. }
    procedure Open(ACreate: Boolean = False);
    procedure Close;

    { Test/kurtarma: diske HICBIR SEY yazmadan kapat (surec olumu
      simulasyonu). Bellekteki kirli sayfalar ve WAL tamponu atilir. }
    procedure CloseNoFlush;

    { Sayfayi okur ve pinler. Basarisizsa False (sayfa yok / CRC bozuk). }
    function GetPage(PageNo: LongWord; out P: PVdbPage): Boolean;

    { Sayfayi CRC/yapi denetimi YAPMADAN okur ve pinler. Yalnizca sayfa
      tipini kesfetmek icin (freelist trunk sayfalari VDbPage formati
      kullanmaz) ve PageInit oncesi kullanilir. Cagiran, icerigi
      PageCheckStruct/PageVerify ile KENDISI dogrulamalidir. }
    function GetRawPage(PageNo: LongWord; out P: PVdbPage): Boolean;

    { Freelist'ten ya da dosya sonundan sayfa ayirir; pinli ve PageInit
      edilmis olarak doner. }
    function AllocPage(PageType: Byte; out PageNo: LongWord;
      out P: PVdbPage): Boolean;

    { Pini birakir. Dirty=True ise sayfa sonraki Flush'ta yazilir. }
    procedure Release(PageNo: LongWord; Dirty: Boolean = False);

    { Sayfayi freelist'e geri verir. Sayfa pinli OLMAMALIDIR. }
    procedure FreePage(PageNo: LongWord);

    { Kirli sayfalari yazar, meta sayfayi gunceller. DoSync=True ise
      fsync eder (P-DUR sozlesmesi: commit fsync eder). }
    procedure Flush(DoSync: Boolean = True);

    { Tum pinleri sifirlar ve onbellegi bosaltir (test/kurtarma icin). }
    procedure DropCache;

    { Su anda onbellekte KIRLI olan sayfa numaralari (tekil). Commit
      sirasinda WAL'e yazilacak cerceveleri belirlemek icin. }
    function DirtyPages: TVdbPageNoArray;

    { Checkpoint LSN'ini ayarlar; sonraki SaveMeta bu degeri yazar. }
    procedure SetLSN(Value: LongWord);

    { Meta sayfasinin guncel imajini uretir (WAL'e cerceve olarak
      yazmak icin; diske yazmaz). }
    procedure BuildMetaImage(out Buf: TVdbPageBuf);

    { Sprint 3.2: checkpoint sonrasi tutarli, bayt-bayt kopya. Meta sayfa
      imaji yeniden uretilir, tum sayfalar onbellek/diskten okunup hedefe
      yazilir. Hedef once .tmp olarak yazilir, fsync edilir, sonra yerine
      gecer; yarim kalmis yedek olusmaz. Kaynak dosya ACILMADAN kopyalanir
      (paylasim kilidi sorunu yok). }
    procedure CopyCommittedTo(const DestPath: string);

    { Sprint 3.4: sayfa sifreleme. Open cagrilmadan ONCE verilmelidir.
      Key 32 bayt AES-256 anahtaridir; Password verilirse PBKDF2-SHA256
      ile dosyaya ozgu tuzdan turetilir. Sifreli dosya anahtarsiz,
      sifresiz dosya anahtarla ACILMAZ (sessiz yanlis yapilandirma yok). }
    procedure SetEncryptionKey(const AKey: TBytes);
    procedure SetEncryptionPassword(const APassword: string);
    function KeyFingerprint: string;

    { WAL kurtarma: sayfa imajini yazar. Onbellekte varsa tazeler ve
      kirli isaretler; yoksa dogrudan dosyaya yazar. PageNo=0 ise meta
      alanlari da tazelenir. }
    procedure InstallPage(PageNo: LongWord; P: PVdbPage);

    { Sayfa onbellekte mi? (Yukleme/tahliye tetiklemez.) }
    function IsResident(PageNo: LongWord): Boolean;

    { Sayfa gecerli bir freelist trunk sayfasi mi (sihirli sayi + CRC)?
      Heap taramasi VDbPage formatinda OLMAYAN sayfalari bu sekilde ayirt
      eder; aksi halde bozuk sayfa sessizce atlanirdi. }
    function IsTrunkPage(P: PVdbPage): Boolean;

    { Sprint 3.1: freelist'i bastan sona dogrular ve serbest sayfa
      numaralarini dondurur. Denetimler: trunk zinciri dongusuz, her trunk
      kendi numarasini dogru tasir, sayac gecerli, her girdi aralikta,
      girdiler tekrarsiz ve toplam = meta FreeCount. }
    function VerifyFreeList(out FreePages: TVdbPageNoArray;
      out Err: string): Boolean;

    { Freelist'in bas sayfasi (0 = bos). }
    function GetFreeTrunk: LongWord;

    { Kirli sayfa tahliyesinden once cagrilacak kanca (write-ahead WAL). }
    property OnSpill: TVdbPageSpillProc read FOnSpill write FOnSpill;

    { Onbellekte bulunmayan sayfa icin alternatif kaynak (WAL tamponu). }
    property OnMiss: TVdbPageMissProc read FOnMiss write FOnMiss;

    function Stats: TVDbStoreStats;
    function PageSize: Integer;
    function FilePath: string;
    function NextLSN: LongWord;

    property PageCount: LongWord read FPageCount;
    property FreeCount: LongWord read FFreeCount;
    property LSN: LongWord read FLSN;

    { Sprint 3.4: dosya sifreli mi, anahtar ve tuz (WAL ayni anahtari ve
      tuzu kullanir). }
    property Encrypted: Boolean read FEncrypted;
    property Key: TBytes read FKey;
    property Salt: TBytes read FSalt;
    { RESTORE dogrulamasi: 16 baytlik anahtar dogrulayici. }
    property KeyCheck: TBytes read FKeyCheck;
  end;

implementation

{ ------------------------------------------------------------------ yardimci }

function TVDbPageStore.OffsetOf(PageNo: LongWord): Int64;
begin
  if FEncrypted then
  begin
    if PageNo = 0 then
      Result := 0
    else
      Result := VDB_PAGE_SIZE + Int64(PageNo - 1) * VDB_ENC_ENVELOPE;
  end
  else
    Result := Int64(PageNo) * VDB_PAGE_SIZE;
end;

function TVDbPageStore.RequiredFileSize(PageCount: LongWord): Int64;
begin
  if PageCount < 1 then PageCount := 1;
  if FEncrypted then
    Result := VDB_PAGE_SIZE + Int64(PageCount - 1) * VDB_ENC_ENVELOPE
  else
    Result := Int64(PageCount) * VDB_PAGE_SIZE;
end;

{ ================================================================ hash tablo }

function TVDbPageStore.HashOf(PageNo: LongWord): LongWord; inline;
begin
  Result := (PageNo * LongWord(2654435761)) and FHashMask;
end;

function TVDbPageStore.FindFrame(PageNo: LongWord): Integer;
var
  h: LongWord;
begin
  Result := -1;
  if PageNo = 0 then Exit;
  h := HashOf(PageNo);
  while FHashKey[h] <> 0 do
  begin
    if FHashKey[h] = PageNo then
    begin
      Result := FHashVal[h];
      Exit;
    end;
    h := (h + 1) and FHashMask;
  end;
end;

procedure TVDbPageStore.HashPut(PageNo: LongWord; Idx: Integer);
var
  h: LongWord;
begin
  h := HashOf(PageNo);
  while FHashKey[h] <> 0 do
    if FHashKey[h] = PageNo then
    begin
      FHashVal[h] := Idx;
      Exit;
    end
    else
      h := (h + 1) and FHashMask;
  FHashKey[h] := PageNo;
  FHashVal[h] := Idx;
end;

procedure TVDbPageStore.HashDel(PageNo: LongWord);
var
  h, j: LongWord;
  k, v: LongWord;
  vi: Integer;
begin
  h := HashOf(PageNo);
  while FHashKey[h] <> 0 do
  begin
    if FHashKey[h] = PageNo then
    begin
      FHashKey[h] := 0;
      { Dogrusal sondalama: kumeyi onarmak icin sonraki kayitlari tasi. }
      j := (h + 1) and FHashMask;
      while FHashKey[j] <> 0 do
      begin
        k := FHashKey[j];
        vi := FHashVal[j];
        FHashKey[j] := 0;
        v := k;
        HashPut(v, vi);
        j := (j + 1) and FHashMask;
      end;
      Exit;
    end;
    h := (h + 1) and FHashMask;
  end;
end;

procedure TVDbPageStore.HashReset;
var
  i: Integer;
begin
  for i := 0 to High(FHashKey) do
    FHashKey[i] := 0;
end;

{ ==================================================================== yasam }

constructor TVDbPageStore.Create(const APath: string;
  APoolPages: Integer);
var
  i, need: Integer;
begin
  inherited Create;
  FPath := APath;
  if APoolPages < 8 then APoolPages := 8;
  if APoolPages > VDB_MAX_POOL then APoolPages := VDB_MAX_POOL;
  FPoolPages := APoolPages;
  SetLength(FFrames, FPoolPages);
  for i := 0 to FPoolPages - 1 do
  begin
    FFrames[i].PageNo := 0;
    FFrames[i].Pins := 0;
    FFrames[i].Dirty := False;
    FFrames[i].Ref := False;
  end;
  need := 64;
  while need < (FPoolPages * 2) do need := need * 2;
  SetLength(FHashKey, need);
  SetLength(FHashVal, need);
  FHashMask := LongWord(need - 1);
  HashReset;
  FClock := 0;
  FLSN := 0;
  FIterations := VDB_ENC_ITER;
end;

destructor TVDbPageStore.Destroy;
begin
  try
    Close;
  except
    { yikici hata firlatmaz }
  end;
  inherited Destroy;
end;

procedure TVDbPageStore.SetEncryptionKey(const AKey: TBytes);
begin
  if Length(AKey) <> VDB_ENC_KEY_LEN then
    raise EVdbPageStore.Create(Format(
      'sifreleme anahtari %d bayt (beklenen %d)', [Length(AKey), VDB_ENC_KEY_LEN]));
  FKey := Copy(AKey, 0, Length(AKey));
  FHasPassword := False;
  FPassword := nil;
end;

procedure TVDbPageStore.SetEncryptionPassword(const APassword: string);
begin
  if APassword = '' then
    raise EVdbPageStore.Create('bos parola');
  FPassword := VDbCryptStrToBytes(APassword);
  FKey := nil;
  FHasPassword := True;
end;

function TVDbPageStore.KeyFingerprint: string;
begin
  if Length(FKey) > 0 then
    Result := VDbPageKeyFingerprint(FKey)
  else
    Result := '';
end;

procedure TVDbPageStore.SetupEncryptionForCreate;
begin
  if FHasPassword then
  begin
    FSalt := VDbPageNewSalt;
    FKey := VDbPageKeyFromPassword(FPassword, FSalt, FIterations);
  end
  else if Length(FKey) > 0 then
    FSalt := VDbPageNewSalt
  else
    FSalt := nil;
  FEncrypted := Length(FKey) > 0;
  if FEncrypted then
    FKeyCheck := VDbPageKeyCheck(FKey)
  else
    FKeyCheck := nil;
end;

procedure TVDbPageStore.CheckEncryptionOnOpen(const Meta: TVdbPageBuf);
var
  flags: LongWord;
  stored, computed: TBytes;
  i: Integer;
begin
  Move(Meta[VDB_META_FLAGS], flags, SizeOf(flags));
  if (flags and VDB_META_FLAG_ENC) <> 0 then
  begin
    SetLength(FSalt, VDB_ENC_SALT_LEN);
    Move(Meta[VDB_META_SALT], FSalt[0], VDB_ENC_SALT_LEN);
    Move(Meta[VDB_META_ITER], FIterations, SizeOf(FIterations));
    if FIterations < 1 then FIterations := VDB_ENC_ITER;
    if FHasPassword then
      FKey := VDbPageKeyFromPassword(FPassword, FSalt, FIterations);
    if Length(FKey) = 0 then
      raise EVdbPageStore.Create(
        'sifreli veritabani: anahtar gerekli (SetEncryptionKey/Password)');
    SetLength(stored, VDB_ENC_CHECK_LEN);
    Move(Meta[VDB_META_KEYCHECK], stored[0], VDB_ENC_CHECK_LEN);
    computed := VDbPageKeyCheck(FKey);
    for i := 0 to VDB_ENC_CHECK_LEN - 1 do
      if stored[i] <> computed[i] then
        raise EVdbPageStore.Create(
          'yanlis anahtar: sifre cozme reddedildi (anahtar dogrulayici tutmadi)');
    FKeyCheck := computed;
    FEncrypted := True;
  end
  else
  begin
    if (Length(FKey) > 0) or FHasPassword then
      raise EVdbPageStore.Create(
        'dosya sifresiz: anahtar verilmemeli (once ALTER/yeni dosya ile sifreleyin)');
    FEncrypted := False;
    FSalt := nil;
    FKeyCheck := nil;
  end;
end;

procedure TVDbPageStore.LoadMeta;
var
  buf: TVDbPageBuf;
  magic, ver: LongWord;
  ps: Word;
  crc: LongWord;
  q: PLongWord;
  fileLen: Int64;
begin
  if FStream.Size < VDB_PAGE_SIZE then
    raise EVdbPageStore.Create('dosya cok kucuk (baslik sayfasi yok)');
  FStream.Position := 0;
  FStream.ReadBuffer(buf, VDB_PAGE_SIZE);
  Move(buf[0], magic, SizeOf(magic));
  if magic = VDB_V2_MAGIC then
    raise EVdbPageStore.Create(
      'v2 formati: bu dosya VDB v3 degil. MIGRATE TO v3 calistirin.');
  if magic <> VDB_FILE_MAGIC then
    raise EVdbPageStore.Create(Format('gecersiz dosya sihirli sayisi: $%.8x', [magic]));
  Move(buf[4], ver, SizeOf(ver));
  if ver <> VDB_FILE_VER then
    raise EVdbPageStore.Create(Format('desteklenmeyen surum: %d (beklenen %d)',
      [ver, VDB_FILE_VER]));
  Move(buf[8], ps, SizeOf(ps));
  if ps <> VDB_PAGE_SIZE then
    raise EVdbPageStore.Create(Format('sayfa boyu %d (beklenen %d)',
      [ps, VDB_PAGE_SIZE]));
  q := PLongWord(@buf[VDB_PAGE_BODY_END]);
  crc := q^;
  if VDbCrc32Of(buf, VDB_PAGE_BODY_END) <> crc then
    raise EVdbPageStore.Create('baslik sayfasi CRC tutmadi (bozuk dosya)');
  Move(buf[12], FPageCount, SizeOf(FPageCount));
  Move(buf[16], FFreeTrunk, SizeOf(FFreeTrunk));
  Move(buf[20], FFreeCount, SizeOf(FFreeCount));
  Move(buf[24], FLSN, SizeOf(FLSN));
  Move(buf[28], FCreated, SizeOf(FCreated));
  CheckEncryptionOnOpen(buf);
  fileLen := FStream.Size;
  if fileLen < RequiredFileSize(FPageCount) then
    raise EVdbPageStore.Create(Format(
      'dosya kesik: %d bayt, baslikta %d sayfa yaziyor',
      [fileLen, FPageCount]));
  if FPageCount < 1 then
    raise EVdbPageStore.Create('baslikta sayfa sayisi 0');
end;

procedure TVDbPageStore.SaveMeta;
var
  buf: TVDbPageBuf;
  crc: LongWord;
  q: PLongWord;
  magic, ver: LongWord;
  ps: Word;
  flags: LongWord;
begin
  FillChar(buf, SizeOf(buf), 0);
  magic := VDB_FILE_MAGIC;
  ver := VDB_FILE_VER;
  ps := VDB_PAGE_SIZE;
  Move(magic, buf[0], SizeOf(magic));
  Move(ver, buf[4], SizeOf(ver));
  Move(ps, buf[8], SizeOf(ps));
  Move(FPageCount, buf[12], SizeOf(FPageCount));
  Move(FFreeTrunk, buf[16], SizeOf(FFreeTrunk));
  Move(FFreeCount, buf[20], SizeOf(FFreeCount));
  Move(FLSN, buf[24], SizeOf(FLSN));
  Move(FCreated, buf[28], SizeOf(FCreated));
  if FEncrypted then
  begin
    if Length(FSalt) = VDB_ENC_SALT_LEN then
      Move(FSalt[0], buf[VDB_META_SALT], VDB_ENC_SALT_LEN);
    Move(FIterations, buf[VDB_META_ITER], SizeOf(FIterations));
    if Length(FKeyCheck) = VDB_ENC_CHECK_LEN then
      Move(FKeyCheck[0], buf[VDB_META_KEYCHECK], VDB_ENC_CHECK_LEN);
    flags := VDB_META_FLAG_ENC;
    Move(flags, buf[VDB_META_FLAGS], SizeOf(flags));
  end;
  crc := VDbCrc32Of(buf, VDB_PAGE_BODY_END);
  q := PLongWord(@buf[VDB_PAGE_BODY_END]);
  q^ := crc;
  FStream.Position := 0;
  FStream.WriteBuffer(buf, VDB_PAGE_SIZE);
  FMetaDirty := False;
end;

procedure TVDbPageStore.Open(ACreate: Boolean);
var
  exists: Boolean;
begin
  if FStream <> nil then Exit;
  exists := FileExists(FPath);
  if not exists and not ACreate then
    raise EVdbPageStore.Create('veritabani dosyasi yok: ' + FPath);
  try
    if exists then
      FStream := TFileStream.Create(FPath, fmOpenReadWrite or fmShareDenyWrite)
    else
      FStream := TFileStream.Create(FPath, fmCreate or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      { 2026-10-25 (Sprint 3.10): baska bir islem/akis dosyayi tutuyorsa
        ham isletim sistemi hatasi yerine ACIK bir kilit hatasi ver.
        Windows'ta paylasim ihlali (32/33), Unix'te flock cakismasi
        EAGAIN ("Try again") olarak gelir. }
      if VDbIsSharingViolation(E) then
        raise EVdbPageStore.Create(
          'veritabani dosyasi kullanimda (baska islem acik): ' + FPath)
      else
        raise;
    end;
  end;
  try
    FLocked := VDbLockStream(FStream);
    FPhysSize := FStream.Size;
    if exists then
      LoadMeta
    else
    begin
      SetupEncryptionForCreate;
      FPageCount := 1;
      FFreeTrunk := 0;
      FFreeCount := 0;
      FLSN := 1;
      FCreated := DateTimeToUnix(Now, False);
      FStream.Size := RequiredFileSize(1);
      FPhysSize := FStream.Size;
      SaveMeta;
      VDbFlushStream(FStream);
    end;
    FReadOnly := False;
  except
    FreeAndNil(FStream);
    raise;
  end;
end;

procedure TVDbPageStore.Close;
begin
  if FStream = nil then Exit;
  try
    try
      if not FReadOnly then
      begin
        Flush(True);
        { v3.1: onceden ayrilmis parcayi kirp: dosya boyu = mantiksal boy. }
        TrimToLogical;
      end;
    finally
      if FLocked then VDbUnlockStream(FStream);
      FreeAndNil(FStream);
      FLocked := False;
    end;
  finally
    DropCache;
  end;
end;

procedure TVDbPageStore.CloseNoFlush;
begin
  if FStream = nil then Exit;
  if FLocked then VDbUnlockStream(FStream);
  FreeAndNil(FStream);
  FLocked := False;
  FMetaDirty := False;
  DropCache;
end;

{ ============================================================ okuma/yazma }

procedure TVDbPageStore.ReadPageAt(PageNo: LongWord; P: PVdbPage);
var
  env: TBytes;
  plain: TBytes;
begin
  if PageNo >= FPageCount then
    raise EVdbPageStore.Create(Format('sayfa %d yok (toplam %d)',
      [PageNo, FPageCount]));
  FStream.Position := OffsetOf(PageNo);
  if FEncrypted then
  begin
    { Yeni uzatilan sayfa: dosya sifirla doldurulmustur; sifreli zarf yok.
      PageInit hemen uzerine yazacagi icin okuma atlanir. }
    if PageNo = FFreshPage then
    begin
      FFreshPage := 0;
      FillChar(P^, VDB_PAGE_SIZE, 0);
      Inc(FReads);
      Exit;
    end;
    SetLength(env, VDB_ENC_ENVELOPE);
    FStream.ReadBuffer(env[0], VDB_ENC_ENVELOPE);
    if not VDbPageOpen(FKey, FSalt, PageNo, env, plain) then
      raise EVdbPageStore.Create(Format(
        'sayfa %d: sifre cozulemedi (yanlis anahtar ya da bozuk zarf)',
        [PageNo]));
    Move(plain[0], P^, VDB_PAGE_SIZE);
  end
  else
    FStream.ReadBuffer(P^, VDB_PAGE_SIZE);
  Inc(FReads);
end;

procedure TVDbPageStore.WritePageAt(PageNo: LongWord; P: PVdbPage);
var
  env: TBytes;
  plain: TBytes;
begin
  FStream.Position := OffsetOf(PageNo);
  if FEncrypted then
  begin
    SetLength(plain, VDB_PAGE_SIZE);
    Move(P^, plain[0], VDB_PAGE_SIZE);
    if not VDbPageSeal(FKey, FSalt, PageNo, plain, env) then
      raise EVdbPageStore.Create(Format('sayfa %d sifrelenemedi', [PageNo]));
    FStream.WriteBuffer(env[0], VDB_ENC_ENVELOPE);
  end
  else
    FStream.WriteBuffer(P^, VDB_PAGE_SIZE);
  Inc(FWrites);
end;

function TVDbPageStore.PickVictim: Integer;
var
  i, passes: Integer;
begin
  { CLOCK: pinli olmayan ilk cerceveyi sec; Ref set ise temizle ve gec. }
  for passes := 0 to 1 do
  begin
    for i := 0 to FPoolPages - 1 do
    begin
      FClock := (FClock + 1) mod FPoolPages;
      if FFrames[FClock].PageNo = 0 then Exit(FClock);
      if FFrames[FClock].Pins > 0 then Continue;
      if FFrames[FClock].Ref then
      begin
        FFrames[FClock].Ref := False;
        Continue;
      end;
      Exit(FClock);
    end;
  end;
  { Tum cerceveler pinli ya da hepsi Ref'li: ikinci turda Ref'lere de bak. }
  for i := 0 to FPoolPages - 1 do
  begin
    FClock := (FClock + 1) mod FPoolPages;
    if (FFrames[FClock].PageNo <> 0) and (FFrames[FClock].Pins = 0) then
      Exit(FClock);
  end;
  raise EVdbPageStore.Create('buffer pool dolu: tahliye edilecek sayfa yok');
end;

function TVDbPageStore.LoadFrame(PageNo: LongWord): Integer;
var
  idx: Integer;
  fromPending: Boolean;
begin
  idx := PickVictim;
  if FFrames[idx].PageNo <> 0 then
  begin
    if FFrames[idx].Dirty then
    begin
      if Assigned(FOnSpill) then
        { Write-ahead: sayfa WAL tamponuna alinir, DISKE YAZILMAZ.
          Commit edilmemis sayfa veritabani dosyasina hicbir zaman
          girmez; okuma OnMiss ile tampondan karsilanir. }
        FOnSpill(FFrames[idx].PageNo, @FFrames[idx].Data)
      else
      begin
        PageSeal(@FFrames[idx].Data);
        WritePageAt(FFrames[idx].PageNo, @FFrames[idx].Data);
      end;
      FFrames[idx].Dirty := False;
    end;
    HashDel(FFrames[idx].PageNo);
    Inc(FEvictions);
  end;
  fromPending := False;
  if Assigned(FOnMiss) and FOnMiss(PageNo, @FFrames[idx].Data) then
  begin
    { imaj WAL tamponundan geldi; diskten okumaya gerek yok. Bu imaj
      veri dosyasinda HENUZ yok: cerceve kirli isaretlenmezse checkpoint
      onu atlar ve WAL budanir -> sayfa kaybolur. }
    fromPending := True;
  end
  else
    ReadPageAt(PageNo, @FFrames[idx].Data);
  FFrames[idx].PageNo := PageNo;
  FFrames[idx].Pins := 0;
  FFrames[idx].Dirty := fromPending;
  FFrames[idx].Ref := True;
  HashPut(PageNo, idx);
  Result := idx;
end;

function TVDbPageStore.GetPageInternal(PageNo: LongWord; DoVerify: Boolean;
  out P: PVdbPage): Boolean;
var
  idx: Integer;
  e: string;
begin
  Result := False;
  P := nil;
  if FStream = nil then
    raise EVdbPageStore.Create('depo acik degil');
  if (PageNo = 0) or (PageNo >= FPageCount) then Exit;
  idx := FindFrame(PageNo);
  if idx < 0 then
  begin
    idx := LoadFrame(PageNo);
    if DoVerify and not PageVerify(@FFrames[idx].Data, e) then
    begin
      HashDel(PageNo);
      FFrames[idx].PageNo := 0;
      FFrames[idx].Pins := 0;
      raise EVdbPageStore.Create(Format('sayfa %d bozuk: %s', [PageNo, e]));
    end;
  end;
  Inc(FFrames[idx].Pins);
  FFrames[idx].Ref := True;
  P := @FFrames[idx].Data;
  Result := True;
end;

function TVDbPageStore.GetPage(PageNo: LongWord; out P: PVdbPage): Boolean;
begin
  Result := GetPageInternal(PageNo, True, P);
end;

function TVDbPageStore.GetRawPage(PageNo: LongWord; out P: PVdbPage): Boolean;
begin
  Result := GetPageInternal(PageNo, False, P);
end;

procedure TVDbPageStore.Release(PageNo: LongWord; Dirty: Boolean);
var
  idx: Integer;
begin
  idx := FindFrame(PageNo);
  if idx < 0 then
    raise EVdbPageStore.Create(Format('Release: sayfa %d onbellekte degil', [PageNo]));
  if FFrames[idx].Pins <= 0 then
    raise EVdbPageStore.Create(Format('Release: sayfa %d pinli degil', [PageNo]));
  if Dirty then FFrames[idx].Dirty := True;
  Dec(FFrames[idx].Pins);
end;

procedure TVDbPageStore.ExtendFile(out NewPageNo: LongWord);
begin
  NewPageNo := FPageCount;
  Inc(FPageCount);
  GrowTo(RequiredFileSize(FPageCount));
  FFreshPage := NewPageNo;
  FMetaDirty := True;
end;

procedure TVDbPageStore.GrowTo(Required: Int64);
var
  want: Int64;
begin
  if Required <= FPhysSize then Exit;
  { Parca halinde uzat: her sayfa icin ayri SetSize cagrisi yapilmaz. }
  want := Required + VDB_GROW_BYTES;
  FStream.Size := want;
  FPhysSize := want;
end;

procedure TVDbPageStore.TrimToLogical;
var
  want: Int64;
begin
  if FStream = nil then Exit;
  if FReadOnly then Exit;
  want := RequiredFileSize(FPageCount);
  if FPhysSize <= want then Exit;
  FStream.Size := want;
  FPhysSize := want;
end;

{ ================================================================= freelist }

procedure TVDbPageStore.TrunkInit(P: PVdbPage; PageNo, NextTrunk: LongWord);
var
  crc: LongWord;
  q: PLongWord;
  magic, zero: LongWord;
begin
  FillChar(P^, VDB_PAGE_SIZE, 0);
  magic := VDB_TRUNK_MAGIC;
  zero := 0;
  Move(magic, P^[0], SizeOf(magic));
  Move(NextTrunk, P^[4], SizeOf(NextTrunk));
  Move(zero, P^[8], SizeOf(zero));
  Move(PageNo, P^[12], SizeOf(PageNo));
  crc := VDbCrc32Of(P^, VDB_PAGE_BODY_END);
  q := PLongWord(@P^[VDB_PAGE_BODY_END]);
  q^ := crc;
end;

procedure TVDbPageStore.TrunkSeal(P: PVdbPage);
var
  crc: LongWord;
  q: PLongWord;
begin
  crc := VDbCrc32Of(P^, VDB_PAGE_BODY_END);
  q := PLongWord(@P^[VDB_PAGE_BODY_END]);
  q^ := crc;
end;

function TVDbPageStore.TrunkGet(var P: PVdbPage): LongWord;
var
  v: LongWord;
begin
  Move(P^[8], v, SizeOf(v));
  Result := v;
end;

procedure TVDbPageStore.TrunkSetCount(P: PVdbPage; N: LongWord);
begin
  Move(N, P^[8], SizeOf(N));
end;

function TVDbPageStore.TrunkNext(P: PVdbPage): LongWord;
var
  v: LongWord;
begin
  Move(P^[4], v, SizeOf(v));
  Result := v;
end;

procedure TVDbPageStore.TrunkSetNext(P: PVdbPage; V: LongWord);
begin
  Move(V, P^[4], SizeOf(V));
end;

function TVDbPageStore.TrunkEntry(P: PVdbPage; I: Integer): LongWord;
var
  v: LongWord;
begin
  Move(P^[VDB_TRUNK_HDR + I * SizeOf(LongWord)], v, SizeOf(v));
  Result := v;
end;

procedure TVDbPageStore.TrunkSetEntry(P: PVdbPage; I: Integer; V: LongWord);
begin
  Move(V, P^[VDB_TRUNK_HDR + I * SizeOf(LongWord)], SizeOf(V));
end;

function TVDbPageStore.TrunkCheck(P: PVdbPage; out Err: string): Boolean;
var
  magic, cnt, selfNo, crc: LongWord;
  q: PLongWord;
begin
  Result := False;
  Move(P^[0], magic, SizeOf(magic));
  if magic <> VDB_TRUNK_MAGIC then
  begin
    Err := 'freelist trunk sihirli sayisi bozuk';
    Exit;
  end;
  q := PLongWord(@P^[VDB_PAGE_BODY_END]);
  crc := q^;
  if VDbCrc32Of(P^, VDB_PAGE_BODY_END) <> crc then
  begin
    Err := 'freelist trunk CRC tutmadi';
    Exit;
  end;
  Move(P^[8], cnt, SizeOf(cnt));
  if cnt > LongWord(VDB_TRUNK_MAX) then
  begin
    Err := Format('freelist trunk sayaci gecersiz: %d', [cnt]);
    Exit;
  end;
  Move(P^[12], selfNo, SizeOf(selfNo));
  if (selfNo = 0) or (selfNo >= FPageCount) then
  begin
    Err := Format('freelist trunk kendi numarasi gecersiz: %d', [selfNo]);
    Exit;
  end;
  Result := True;
end;

function TVDbPageStore.GetFreeTrunk: LongWord;
begin
  Result := FFreeTrunk;
end;

function TVDbPageStore.VerifyFreeList(out FreePages: TVdbPageNoArray;
  out Err: string): Boolean;
var
  trunk, cnt, i, entry, nextTrunk: LongWord;
  P: PVdbPage;
  seen: TDictionary<LongWord, Boolean>;
  e: string;
begin
  Result := False;
  Err := '';
  FreePages := nil;
  if FStream = nil then
  begin
    Err := 'depo acik degil';
    Exit;
  end;
  seen := TDictionary<LongWord, Boolean>.Create;
  try
    trunk := FFreeTrunk;
    while trunk <> 0 do
    begin
      if trunk >= FPageCount then
      begin
        Err := Format('freelist trunk numarasi aralik disi: %d (sayfa=%d)',
          [trunk, FPageCount]);
        Exit;
      end;
      if seen.ContainsKey(trunk) then
      begin
        Err := Format('freelist trunk zinciri dongulu: %d', [trunk]);
        Exit;
      end;
      seen.Add(trunk, True);
      if not GetPageInternal(trunk, False, P) then
      begin
        Err := Format('freelist trunk okunamadi: %d', [trunk]);
        Exit;
      end;
      try
        if not TrunkCheck(P, e) then
        begin
          Err := Format('freelist trunk %d bozuk: %s', [trunk, e]);
          Exit;
        end;
        cnt := TrunkGet(P);
        for i := 0 to cnt - 1 do
        begin
          entry := TrunkEntry(P, i);
          if (entry = 0) or (entry >= FPageCount) then
          begin
            Err := Format('freelist girdisi aralik disi: %d (trunk %d)',
              [entry, trunk]);
            Exit;
          end;
          if seen.ContainsKey(entry) then
          begin
            Err := Format('freelist girdisi yineleniyor: %d', [entry]);
            Exit;
          end;
          seen.Add(entry, True);
          SetLength(FreePages, Length(FreePages) + 1);
          FreePages[High(FreePages)] := entry;
        end;
        nextTrunk := TrunkNext(P);
      finally
        Release(trunk, False);
      end;
      trunk := nextTrunk;
    end;
    if LongWord(Length(FreePages)) <> FFreeCount then
    begin
      Err := Format('freelist sayaci tutmuyor: zincirde %d, meta %d',
        [Length(FreePages), FFreeCount]);
      Exit;
    end;
    Result := True;
  finally
    seen.Free;
  end;
end;

procedure TVDbPageStore.FreePage(PageNo: LongWord);
var
  trunk, newTrunk, cnt: LongWord;
  P: PVdbPage;
  e: string;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('depo acik degil');
  if (PageNo = 0) or (PageNo >= FPageCount) then
    raise EVdbPageStore.Create(Format('FreePage: gecersiz sayfa %d', [PageNo]));
  if FindFrame(PageNo) >= 0 then
    if FFrames[FindFrame(PageNo)].Pins > 0 then
      raise EVdbPageStore.Create(Format('FreePage: sayfa %d hala pinli', [PageNo]));

  trunk := FFreeTrunk;
  if trunk = 0 then
  begin
    { Ilk trunk: dosya sonuna ekle. }
    ExtendFile(newTrunk);
    if not GetPageInternal(newTrunk, False, P) then
      raise EVdbPageStore.Create('FreePage: trunk sayfasi olusturulamadi');
    TrunkInit(P, newTrunk, 0);
    Release(newTrunk, True);
    FFreeTrunk := newTrunk;
    trunk := newTrunk;
  end;

  { Trunk sayfalari VDbPage formati kullanmaz; dogrulamayi TrunkCheck yapar. }
  if not GetPageInternal(trunk, False, P) then
    raise EVdbPageStore.Create('FreePage: trunk okunamadi');
  if not TrunkCheck(P, e) then
  begin
    Release(trunk, False);
    raise EVdbPageStore.Create('freelist bozuk: ' + e);
  end;

  cnt := TrunkGet(P);
  if cnt >= LongWord(VDB_TRUNK_MAX) then
  begin
    { Trunk dolu: yeni trunk basa ekle. }
    Release(trunk, False);
    ExtendFile(newTrunk);
    if not GetPageInternal(newTrunk, False, P) then
      raise EVdbPageStore.Create('FreePage: yeni trunk olusturulamadi');
    TrunkInit(P, newTrunk, trunk);
    Release(newTrunk, True);
    FFreeTrunk := newTrunk;
    trunk := newTrunk;
    if not GetPageInternal(trunk, False, P) then
      raise EVdbPageStore.Create('FreePage: yeni trunk okunamadi');
    cnt := 0;
  end;

  TrunkSetEntry(P, cnt, PageNo);
  TrunkSetCount(P, cnt + 1);
  TrunkSeal(P);
  Release(trunk, True);
  Inc(FFreeCount);
  FMetaDirty := True;
end;

function TVDbPageStore.AllocPage(PageType: Byte; out PageNo: LongWord;
  out P: PVdbPage): Boolean;
var
  trunk, cnt, nextTrunk: LongWord;
  tp: PVdbPage;
  e: string;
begin
  Result := False;
  P := nil;
  PageNo := 0;
  if FStream = nil then
    raise EVdbPageStore.Create('depo acik degil');

  while (FFreeTrunk <> 0) do
  begin
    trunk := FFreeTrunk;
    if not GetPageInternal(trunk, False, tp) then
      raise EVdbPageStore.Create('AllocPage: trunk okunamadi');
    if not TrunkCheck(tp, e) then
    begin
      Release(trunk, False);
      raise EVdbPageStore.Create('freelist bozuk: ' + e);
    end;
    cnt := TrunkGet(tp);
    if cnt = 0 then
    begin
      { Trunk'in kendisi bos sayfa sayilir; zinciri ilerlet. }
      nextTrunk := TrunkNext(tp);
      Release(trunk, False);
      PageNo := trunk;
      FFreeTrunk := nextTrunk;
      FMetaDirty := True;
      Break;
    end;
    Dec(cnt);
    PageNo := TrunkEntry(tp, cnt);
    TrunkSetCount(tp, cnt);
    TrunkSeal(tp);
    Release(trunk, True);
    Dec(FFreeCount);
    FMetaDirty := True;
    Break;
  end;

  if PageNo = 0 then
  begin
    ExtendFile(PageNo);
    FMetaDirty := True;
  end;

  { Yeni/geri kazanilmis sayfa: PageInit hemen uzerine yazacagi icin
    diskteki eski icerik denetlenmez. }
  if not GetPageInternal(PageNo, False, P) then
    raise EVdbPageStore.Create(Format('AllocPage: sayfa %d okunamadi', [PageNo]));
  PageInit(P, PageNo, PageType);
  Result := True;
end;

{ ==================================================================== flush }

procedure TVDbPageStore.Flush(DoSync: Boolean);
var
  i: Integer;
begin
  if FStream = nil then Exit;
  for i := 0 to FPoolPages - 1 do
    if (FFrames[i].PageNo <> 0) and FFrames[i].Dirty then
    begin
      PageSeal(@FFrames[i].Data);
      WritePageAt(FFrames[i].PageNo, @FFrames[i].Data);
      FFrames[i].Dirty := False;
    end;
  if FMetaDirty then
    SaveMeta;
  if DoSync then
    VDbFlushStream(FStream);
end;

procedure TVDbPageStore.DropCache;
var
  i: Integer;
begin
  for i := 0 to High(FFrames) do
  begin
    FFrames[i].PageNo := 0;
    FFrames[i].Pins := 0;
    FFrames[i].Dirty := False;
    FFrames[i].Ref := False;
  end;
  if FHashKey <> nil then
    HashReset;
  FClock := 0;
end;

function TVDbPageStore.DirtyPages: TVdbPageNoArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  n := 0;
  for i := 0 to FPoolPages - 1 do
    if (FFrames[i].PageNo <> 0) and FFrames[i].Dirty and
       (FFrames[i].PageNo <> VDB_HDR_PAGE) then
    begin
      SetLength(Result, n + 1);
      Result[n] := FFrames[i].PageNo;
      Inc(n);
    end;
end;

procedure TVDbPageStore.SetLSN(Value: LongWord);
begin
  FLSN := Value;
  FMetaDirty := True;
end;

procedure TVDbPageStore.BuildMetaImage(out Buf: TVdbPageBuf);
var
  crc: LongWord;
  q: PLongWord;
  magic, ver: LongWord;
  ps: Word;
  encFlags: LongWord;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  magic := VDB_FILE_MAGIC;
  ver := VDB_FILE_VER;
  ps := VDB_PAGE_SIZE;
  Move(magic, Buf[0], SizeOf(magic));
  Move(ver, Buf[4], SizeOf(ver));
  Move(ps, Buf[8], SizeOf(ps));
  Move(FPageCount, Buf[12], SizeOf(FPageCount));
  Move(FFreeTrunk, Buf[16], SizeOf(FFreeTrunk));
  Move(FFreeCount, Buf[20], SizeOf(FFreeCount));
  Move(FLSN, Buf[24], SizeOf(FLSN));
  Move(FCreated, Buf[28], SizeOf(FCreated));
  if FEncrypted then
  begin
    if Length(FSalt) = VDB_ENC_SALT_LEN then
      Move(FSalt[0], Buf[VDB_META_SALT], VDB_ENC_SALT_LEN);
    Move(FIterations, Buf[VDB_META_ITER], SizeOf(FIterations));
    if Length(FKeyCheck) = VDB_ENC_CHECK_LEN then
      Move(FKeyCheck[0], Buf[VDB_META_KEYCHECK], VDB_ENC_CHECK_LEN);
    encFlags := VDB_META_FLAG_ENC;
    Move(encFlags, Buf[VDB_META_FLAGS], SizeOf(encFlags));
  end;
  crc := VDbCrc32Of(Buf, VDB_PAGE_BODY_END);
  q := PLongWord(@Buf[VDB_PAGE_BODY_END]);
  q^ := crc;
end;

procedure TVDbPageStore.CopyCommittedTo(const DestPath: string);
var
  tmp, dir: string;
  fs: TFileStream;
  meta: TVdbPageBuf;
  pno: LongWord;
  P: PVdbPage;
  plain, env: TBytes;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('depolama acik degil (CopyCommittedTo)');
  if DestPath = '' then
    raise EVdbPageStore.Create('CopyCommittedTo: hedef yol bos');
  dir := ExtractFileDir(DestPath);
  if dir <> '' then ForceDirectories(dir);
  tmp := DestPath + '.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  BuildMetaImage(meta);
  fs := TFileStream.Create(tmp, fmCreate);
  try
    fs.WriteBuffer(meta, SizeOf(meta));
    for pno := 1 to FPageCount - 1 do
    begin
      if not GetRawPage(pno, P) then
        raise EVdbPageStore.Create(Format(
          'kopya: sayfa %d okunamadi', [pno]));
      try
        if FEncrypted then
        begin
          SetLength(plain, VDB_PAGE_SIZE);
          Move(P^, plain[0], VDB_PAGE_SIZE);
          if not VDbPageSeal(FKey, FSalt, pno, plain, env) then
            raise EVdbPageStore.Create(Format(
              'kopya: sayfa %d sifrelenemedi', [pno]));
          fs.WriteBuffer(env[0], VDB_ENC_ENVELOPE);
        end
        else
          fs.WriteBuffer(P^, VDB_PAGE_SIZE);
      finally
        Release(pno, False);
      end;
    end;
    VDbFlushStream(fs);
  finally
    fs.Free;
  end;
  try
    if FileExists(DestPath) then
      if not DeleteFile(DestPath) then
        raise EVdbPageStore.Create('kopya: eski hedef silinemedi: ' + DestPath);
    if not RenameFile(tmp, DestPath) then
      raise EVdbPageStore.Create('kopya: hedefe tasinamadi: ' + DestPath);
    if dir <> '' then
      VDbFlushDir(dir);
  except
    if FileExists(tmp) then DeleteFile(tmp);
    raise;
  end;
end;

procedure TVDbPageStore.InstallPage(PageNo: LongWord; P: PVdbPage);
var
  idx: Integer;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('depolama acik degil (InstallPage)');
  idx := FindFrame(PageNo);
  if idx >= 0 then
  begin
    { Sayfa onbellekte: imaji tazele ve kirli isaretle; Flush yazacak.
      Boylece tahliye tetiklenmez ve pending listesi commit sirasinda
      degismez. }
    if FFrames[idx].Pins > 0 then
      raise EVdbPageStore.Create(Format(
        'InstallPage: sayfa %d pinli (kurtarma sirasinda beklenmiyordu)', [PageNo]));
    Move(P^, FFrames[idx].Data, VDB_PAGE_SIZE);
    FFrames[idx].Dirty := True;
    Exit;
  end;
  if PageNo >= FPageCount then
  begin
    FPageCount := PageNo + 1;
    GrowTo(RequiredFileSize(FPageCount));
  end;
  if PageNo = VDB_HDR_PAGE then
  begin
    { Meta sayfa her zaman DUZ metindir (sir tutmaz, sifreleme zarfi yok). }
    FStream.Position := 0;
    FStream.WriteBuffer(P^, VDB_PAGE_SIZE);
    LoadMeta;
  end
  else
    WritePageAt(PageNo, P);
end;

function TVDbPageStore.IsResident(PageNo: LongWord): Boolean;
begin
  Result := FindFrame(PageNo) >= 0;
end;

function TVDbPageStore.IsTrunkPage(P: PVdbPage): Boolean;
var
  e: string;
begin
  Result := TrunkCheck(P, e);
end;

function TVDbPageStore.Stats: TVDbStoreStats;
var
  i, used: Integer;
begin
  used := 0;
  for i := 0 to FPoolPages - 1 do
    if FFrames[i].PageNo <> 0 then Inc(used);
  Result.PageCount := FPageCount;
  Result.FreeCount := FFreeCount;
  if FPageCount >= 1 + FFreeCount then
    Result.UsedCount := FPageCount - 1 - FFreeCount
  else
    Result.UsedCount := 0;
  Result.PoolPages := FPoolPages;
  Result.PoolUsed := used;
  Result.Reads := FReads;
  Result.Writes := FWrites;
  Result.Evictions := FEvictions;
  { v3.1: MANTIKSAL boy (FPageCount x 4096). Dosya onceden ayrilmis parca
    tasiyabilir; o fazlalik veriye dahil degildir ve kapanista kirpilir. }
  if FStream <> nil then Result.FileBytes := RequiredFileSize(FPageCount)
  else Result.FileBytes := 0;
end;

function TVDbPageStore.PageSize: Integer;
begin
  Result := VDB_PAGE_SIZE;
end;

function TVDbPageStore.FilePath: string;
begin
  Result := FPath;
end;

function TVDbPageStore.NextLSN: LongWord;
begin
  Inc(FLSN);
  if FLSN = 0 then FLSN := 1;
  FMetaDirty := True;
  Result := FLSN;
end;

end.
