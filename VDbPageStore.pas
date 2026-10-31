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
  {$IFDEF WINDOWS}Windows,{$ENDIF} VDbCrypt, VDbPageCrypto;

const
  VDB_FILE_MAGIC   = $33424456;   // 'VDB3' (little endian)
  VDB_FILE_VER     = 5;
  { v3.11: satir govdesi v1 yazmis olabilecek onceki surum; okunur ve ilk
    yazmada guncel surume yukseltilir. }
  VDB_FILE_VER_V3  = 3;
  { v3.13: pk'nin satir govdesinde ikinci kez yazilmadigi bicim. Bu
    surumden ONCEKI dosyalar pk'yi satir ici tasir; okunur ve ilk yazmada
    5'e yukseltilir. }
  VDB_FILE_VER_V4  = 4;
  VDB_V2_MAGIC     = $56444231;   // v2 'VDB1' — net goc hatasi icin
  VDB_HDR_PAGE     = 0;
  VDB_DEF_POOL     = 512;         // 512 x 4 KB = 2 MB
  VDB_MAX_POOL     = 65536;

  { v3.1: dosya buyutme parcasi. Her yeni sayfada ayri SetSize cagrisi
    ~45-50 us suruyordu (200k satirlik yazimda ~200 ms). Artik dosya
    64 sayfalik (256 KB) parcalarla uzatilir; kapanista mantiksal boya
    kirpilir. Kayipsiz: fazla baytlar sayfa sayacinin otesindedir. }
  VDB_GROW_BYTES   = 262144;

  { v3.2: yazar kilidi icin VARSAYILAN bekleme (ms). 0 = bekleme yok:
    kilit alinamazsa hemen "veritabani mesgul" hatasi verilir (v2 ve onceki
    v3 davranisi ile ayni; SQLite'in varsayilan busy handler'i gibi).
    Beklemek isteyen uygulama VdbOpenWithBusyTimeout / Create(..., ABusyMs)
    ile acikca sure verir. }
  VDB_DEF_BUSY_MS  = 0;

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
        { v3.1: cercevenin en son hangi islemde kirletildigi. Commit yalnizca
          BU islemde degisen sayfalari WAL'e yazar (eskiden tum kirli sayfalar
          yaziliyordu => autocommit'te O(kirli sayfa) maliyet). }
        TxnMark: LongWord;
      end;
    var
      FPath: string;
      FStream: TFileStream;
      FPoolPages: Integer;
      FFrames: array of TFrame;
      { P-54: islem bazli kirli cerceve listesi. TxnPages yalniz bu listeyi
        gezer (O(kirli)) — tum havuzu taramak (O(havuz=512)) yerine.
        Liste eski/tekrarli girdiler icerebilir; TxnPages dogrulamayla
        suzulur (TxnMark = FTxnId ve Dirty). }
      FTxnDirty: array of Integer;
      FTxnDirtyCount: Integer;
      FHashKey: array of LongWord;   // 0 = bos
      FHashVal: array of Integer;
      FHashMask: LongWord;
      FClock: Integer;
      FPageCount: LongWord;
      FFreeTrunk: LongWord;
      FFreeCount: LongWord;
      FLSN: LongWord;
      { v3.31 DELTA TAZELEME. FLSN meta sayfadaki (yapısal) LSN'dir ve veri-
        yalnız commit'lerde geride kalabilir. FViewLsn ise onbellek + heap
        dizininin tutarlı olduğu GERCEK commit LSN'idir. Tazeleme kararı buna
        bakar: FViewLsn < WAL.HeaderLsn ise degisiklikler yalniz veri
        dosyasindadir (WAL budanmistir) -> tam yeniden yukleme gerekir. }
      FViewLsn: LongWord;
      FCreated: Int64;
      FReads: Int64;
      FWrites: Int64;
      FEvictions: Int64;
      FMetaDirty: Boolean;
      { v3.1: meta sayfanin YAPISAL icerigi (sayfa sayisi / freelist) diskte
        bayat mi? Commit yalnizca bu True iken meta cercevesi yazar; yalniz
        LSN degismisse cerceve gereksiz (4 KB). }
      FStructDirty: Boolean;
      { v3.1: islem (commit) kimligi; FFrame.TxnMark ile karsilastirilir. }
      FTxnId: LongWord;
      FLocked: Boolean;
      { v3.16: surecler arasi cok yazarlilik. Acilista HER oturum paylasimli
        kilit alir (cok okuyucu + cok yazar adayi ayni anda acabilir).
        Yazma girisinde paylasimli birakilir, tam kilit alinir; yazma
        cikisinda tersi. FLocked = (FLockedShared or FLockedExcl). }
      FLockedShared: Boolean;
      FLockedExcl: Boolean;
      { Ayni surecte ic ice yazma girisleri (oturum basina yazma kumesi +
        otomatik commit). 0 -> 1 gecisinde kilit yukseltilir. }
      FWriteDepth: Integer;
      { v3.18: acik yazma islemi (BeginBatch..CommitBatch) boyunca tutulan
        REZERVASYON derinligi. Rezervasyon `.gen` handle'i uzerinden alinir;
        VERI kilidi (FStream tam kilit) yalniz commit penceresinde alinir.
        Boylece uzun bir islem okuyuculari BLOKLAMAZ, yazarlari bloklar. }
      FHoldDepth: Integer;
      { Rezervasyon su an `.gen` handle'i uzerinde tutuluyor mu? }
      FReserved: Boolean;
      { v3.18: iyimser yazma islemi acikken okuma yolu tazeleme yapmaz
        (islemin goruntusu sabit kalir). Bkz. RefreshIfStale. Sayac:
        ic ice islemler icin. }
      FDeferCount: Integer;
      { v3.18 dilim 6: ACILIS tam kilidi rezervasyonsuz alir (AcquireWriteOpen).
        Rezervasyon islemleri siralar; acilis yalniz kisa kritik bolum icin
        tam kilide ihtiyac duyar. }
      FSkipReserve: Boolean;
      FWriteCs: TRTLCriticalSection;
      { v3.16: islem kapsamli paylasimli kilit derinligi (yazan oturum). }
      FReadDepth: Integer;
      { v3.16: meta sayfanin (sayfa 0) son gorulen HAM 4 KB imaji. Tam
        kilit alindiktan sonra diskteki imajla karsilastirilir; farkliysa
        baska bir surec commit etmistir -> onbellek dusurulur + meta
        yeniden yuklenir. Meta sayfa duz metindir (sifreleme yalniz
        kullanici sayfalarinda), bu yuzden ham karsilastirma gecerlidir. }
      FMetaSig: TBytes;
      { v3.16: meta imzasinin temsil ettigi LSN. Commit (LSN artisi) her
        zaman meta sayfaya yazilir; aksi halde yalniz sayfa degistiren bir
        commit'i diger surecler FARK ETMEZ. }
      FSigLSN: LongWord;
      FOnRefreshed: TNotifyEvent;
      { v3.16: SURECLER ARASI DEGISIKLIK DAMGASI. Meta sayfaya commit LSN'i
        yazmak taban dosyanin kendi kendine tutarliligini BOZAR (sayfalar
        hala WAL'de olabilir; AS OF/PITR testi bunu yakaladi). Bu yuzden
        degisiklik, ayri ve kucuk bir `<db>.gen` sayac dosyasinda tutulur:
        her yazma islemi sonunda 8 bayt artirilir. Baska bir surec bunu
        gordugunde onbellegini tazeler. }
      FSigGen: QWord;
      FGenStream: TFileStream;
      { v3.25: `.gen` sayaci icin BELLEK ESLEMESI. Okuma yolu eskiden her
        ifade basina `SetFilePointer` + `ReadFile` (olculen ~2,5 us) yapiyordu;
        eslenmis 8 baytlik goruntu bunu tek bellek okumasina indirir.
        Guvenlik gerekcesi: dosya hicbir zaman silinmiyor/kucultulmuyor,
        yalniz yerinde 8 bayt yaziliyor; Windows'ta eslenmis goruntu ile
        `WriteFile` AYNI onbellek bolumunu kullanir, yani tutarlidir.
        Ayrica sayac TUM yazmalarda (BumpGen) ve okumalarda (ReadGen) tam
        ya da paylasimli kilit ALTINDA erisilir; dolayisiyla 32 bitlik iki
        parcali okuma ile yirtik deger okunamaz. Esleme kurulamazsa eski
        (Position + Read) yolu kullanilir; davranis degismez. }
      FGenMap: PByte;
      FGenMapH: THandle;
      { v3.16 GUVENLIK AGI: paylasimli kilit altindayken bir yazma ilkeli
        cagrilirsa (Windows'ta paylasimli kilit = yalniz okuma, ayni handle
        bile yazamaz) kilit KENDILIGINDEN tam kilide yukseltilir ve
        ReleaseRead'de geri birakilir. Boylece unutulan bir yazma yolu veri
        kaybina ya da EWriteError'a yol acmaz. }
      FAutoWrite: Boolean;
      FReadOnly: Boolean;
      { v3.2: salt-okunur oturumda WAL'den gelen sayfa imajlari. Dosyaya
        YAZILMAZ; okuma bu katmandan karsilanir (crash sonrasi okuma ve
        yazarsiz ikinci surec icin). }
      FRoPages: TDictionary<LongWord, PVdbPage>;
      FRoCount: Integer;
      FBusyMs: Integer;
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
    function LoadFrame(PageNo: LongWord; AImage: PVdbPage = nil): Integer;
    function PickVictim: Integer;
    function GetPageInternal(PageNo: LongWord; DoVerify: Boolean;
      out P: PVdbPage): Boolean;
    function OffsetOf(PageNo: LongWord): Int64;
    function RequiredFileSize(PageCount: LongWord): Int64;
    procedure SetupEncryptionForCreate;
    procedure CheckEncryptionOnOpen(const Meta: TVdbPageBuf);
    procedure ReadPageAt(PageNo: LongWord; P: PVdbPage);
    procedure ReadBytesAt(Pos: Int64; var Buf; Len: Integer; PageNo: LongWord);
    procedure WritePageAt(PageNo: LongWord; P: PVdbPage);
    procedure ExtendFile(out NewPageNo: LongWord);
    procedure GrowTo(Required: Int64);
    procedure TrimToLogical;
    procedure LoadMeta;
    procedure SaveMeta;
    { v3.16: kilit gecisleri. }
    function TakeSharedLock: Boolean;
    procedure LockExclusive;
    { v3.18: `.gen` uzerindeki YAZAR REZERVASYONU (bekleme politikasi
      LockExclusive ile ayni: FBusyMs boyunca 1 ms'de bir yokla). }
    procedure LockReserve;
    { v3.26: rezervasyon birakma tek yerde (bes cagri noktasi). }
    procedure UnlockGen;
    procedure RefreshIfStale;
    { v3.18: FDeferRefresh bayragini YOK SAYAN tazeleme. Yazma yollari
      bunu kullanir: bayat onbellekle yazmak veri kaybi uretir. }
    procedure RefreshIfStaleForce;
    { v3.18 DUZELTME — VERI BUTUNLUGU: tazelemeyi VERI dosyasinin tam kilidi
      altinda yapar, sonra kilidi birakir (islemin goruntusu yine sabit
      degildir; yalniz bu okuma penceresi korunur). Rezervasyon (.gen) kilidi
      BUNUN YERINE GECMEZ: baska bir surec tam kilidi tutup WAL'i kisaltirken
      tazeleme yapmak yirtik goruntu ve kisa okuma hatasi uretiyordu. }
    procedure RefreshUnderExclusive;
    { v3.16: yazma ilkelleri icin guvenlik agi (bkz. FAutoWrite). }
    procedure EnsureIoWrite;
    { v3.16: `<db>.gen` degisiklik sayaci. }
    function ReadGen: QWord;
    procedure BumpGen;
    { v3.25: sayaci bellek eslemesinden okumak icin. }
    procedure MapGen;
    procedure UnmapGen;
    { v3.31: surecler arasi GRUP FSYNC. `.gen` eslemesinde offset 8'de
      tutulan durabil LSN (fsync'in KAPSADIGI en buyuk LSN). }
    function ReadDurableLsn: LongWord;
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

    { v3.2: cok okuyucu / tek yazici.
      AReadOnly=True: dosya salt-okunur acilir ve PAYLASIMLI kilit alinir
      (birden cok okuyucu ayni anda). Yazma denenirse acik hata verir.
      AReadOnly=False: tam kilit; alinamazsa ABusyMs boyunca denenir. }
    procedure OpenEx(ACreate: Boolean; AReadOnly: Boolean;
      ABusyMs: Integer = VDB_DEF_BUSY_MS);
    property ReadOnly: Boolean read FReadOnly;
    property BusyTimeoutMs: Integer read FBusyMs;

    { v3.16: surecler arasi cok yazarlilik.
      Giris: paylasimli kilit birakilir, tam kilit ABusyMs boyunca denenir,
      alininca meta imgasi karsilastirilir ve gerekirse onbellek tazelenir.
      Cikis: tam kilit birakilir, paylasimli kilide donulur.
      Ic ice cagri desteklidir: derinlik 0 -> 1 gecisinde kilit yukseltilir. }
    procedure AcquireWrite;
    { v3.18 dilim 6: acilis icin tam kilit — rezervasyon ALMAZ. }
    procedure AcquireWriteOpen;
    procedure ReleaseWrite;
    { v3.18: acik islem icin YAZAR REZERVASYONU (veri kilidi DEGIL).
      Uzun islem boyunca tutulur; okuyucular etkilenmez. }
    procedure AcquireWriteHold;
    { v3.18: rezervasyonu BEKLETMEDEN dener. True: rezervasyon artik
      BIZDE (FHoldDepth=1). False: baska bir surec tutuyor, hicbir sey
      alinmadi; ISTISNA FIRLATMAZ. Iyimser yazma islemi bu yolla baslar. }
    function TryAcquireWriteHold: Boolean;
    procedure ReleaseWriteHold;
    { v3.18: iyimser islem boyunca okuma yolunun tazelemesini erteler. }
    procedure BeginDeferRefresh;
    procedure EndDeferRefresh;
    { v3.18: gercek veri kilidi penceresi (commit/uygulama aninda). }
    procedure AcquireDataWrite;
    procedure ReleaseDataWrite;
    procedure AcquireRead;
    procedure ReleaseRead;
    { v3.18 DUZELTME — KILITLENME: iyimser yazar commit aninda rezervasyonu
      beklerken PAYLASIMLI kilidi tutarsa iki yazar birbirini kilitler
      (A rezervasyonu tutar + tam kilidi ister; B paylasimliyi tutar +
      rezervasyonu ister). Bu metot, beklemeden ONCE paylasimli kilidi ve
      okuma derinligini birakir. Dogruluk kaybolmaz: cakisma denetimi tam
      kilit altinda TAZE veriyle yapilir (VerifyNoConflict). }
    procedure ReleaseReadForUpgrade;
    function WriteHeld: Boolean;
    { v3.16: guvenlik agi ile ALINAN tam kilidi birakir. Yalnizca
      `EnsureIoWrite` kilit yukseltmesi yaptiysa etkilidir (aksi halde
      no-op). `TVdbPageEngine`'i dogrudan kullanan oturumlar bunu islem
      sonunda CAGRMAK ZORUNDADIR; aksi halde tam kilit oturum boyu
      tutulur ve diger surecler okuyamaz. }
    procedure EndIoWrite;
    { v3.16: meta imzasi degistiginde (baska surec commit etti) cagrilir.
      Motor WAL gorunumunu tazelemek icin baglar. }
    property OnRefreshed: TNotifyEvent read FOnRefreshed write FOnRefreshed;

    { v3.18: bu oturumun EN SON gordugu `<db>.gen` degeri. Yalnizca bellek
      okumasidir (diskte yoklama yapmaz). Baska bir surec commit ettiginde
      deger degisir; sema katmani bunu tazelik damgasi olarak kullanir. }
    function GenStamp: QWord;

    { v3.31 SURECLER ARASI GRUP FSYNC. `.gen` eslemesinde offset 8'de
      paylasilan durabil LSN: bir process'in fsync'i bu LSN'e kadar olan
      TUM WAL kayitlarini kapsar. Baska bir process `AwaitDurable`'da
      kendi LSN'i bu degerden kucuk/eşitse fsync'i ATLAYABILIR.

      Monoton artar (yalnizca daha buyuk deger yazilir). Yalnizca fsync
      BASARILI OLDUKTAN SONRA yazilmalidir; aksi halde fsync atlanir ve
      veri kaybi olur. Yazim atomiktir (InterlockedCompareExchange). }
    function DurableLsn: LongWord;
    procedure SetDurableLsn(Value: LongWord);

    { Salt-okunur oturumda WAL'den gelen imaji bellek katmanina alir.
      Diske YAZMAZ; meta sayfa (0) ise mantiksal alanlari tazeler. }
    procedure InstallReadOnlyPage(PageNo: LongWord; P: PVdbPage);
    { v3.18: RO WAL imajlarini bosaltir (baska surec commit etti). }
    procedure ResetReadOnlyImages;
    function ReadOnlyPageCount: Integer;

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

    { v3.1: YALNIZCA bu islemde kirletilmis (yerlesik) sayfalar. Commit bunlari
      WAL'e yazar; onceki islemlerde yazilmis sayfalari tekrar yazmaz. }
    function TxnPages: TVdbPageNoArray;
    { v3.1: sayfanin cercevesindeki islem isareti (yerlesik degilse 0). }
    function TxnMarkOf(PageNo: LongWord): LongWord;
    { v3.1: islemi kapat: sonraki kirletmeler yeni islem kimligi alir. }
    procedure EndTxn;
    property TxnId: LongWord read FTxnId;

    { Checkpoint LSN'ini ayarlar; sonraki SaveMeta bu degeri yazar. }
    procedure SetLSN(Value: LongWord);
    { v3.31: onbellek + heap dizininin tutarli oldugu LSN'i isaretler.
      Yalnizca motor cagirir (commit sonu, kurtarma sonu, acilis sonu).
      LoadMeta BUNA DOKUNMAZ — tazeleme oncesi gorunum LSN'i korunur ki
      "WAL budandi, tam tazeleme gerek" karari verilebilsin. }
    procedure SetViewLsn(Value: LongWord);

    { Meta sayfasinin guncel imajini uretir (WAL'e cerceve olarak
      yazmak icin; diske yazmaz). }
    procedure BuildMetaImage(out Buf: TVdbPageBuf);

    { Sprint 3.2: checkpoint sonrasi tutarli, bayt-bayt kopya. Meta sayfa
      imaji yeniden uretilir, tum sayfalar onbellek/diskten okunup hedefe
      yazilir. Hedef once .tmp olarak yazilir, fsync edilir, sonra yerine
      gecer; yarim kalmis yedek olusmaz. Kaynak dosya ACILMADAN kopyalanir
      (paylasim kilidi sorunu yok). }
    procedure CopyCommittedTo(const DestPath: string);
    { v3.2: son checkpoint tabaninin HAM kopyasi (AS OF anlik goruntusu icin).
      CopyCommittedTo'dan farki: bellek onbellegini/gecerli durumu YAZMAZ,
      WAL'i budamaz; diskteki taban imajini bayt bayt kopyalar. Kopya deponun
      KENDI handle'i uzerinden yapilir (dosya tam aralik kilidiyle kilitli;
      baska handle'dan okuma Windows'ta 0 bayt doner). }
    procedure CopyBaseImageTo(const DestPath: string);

    { Sprint 3.4: sayfa sifreleme. Open cagrilmadan ONCE verilmelidir.
      Key 32 bayt AES-256 anahtaridir; Password verilirse PBKDF2-SHA256
      ile dosyaya ozgu tuzdan turetilir. Sifreli dosya anahtarsiz,
      sifresiz dosya anahtarla ACILMAZ (sessiz yanlis yapilandirma yok). }
    procedure SetEncryptionKey(const AKey: TBytes);
    procedure SetEncryptionPassword(const APassword: string);
    function KeyFingerprint: string;

    { WAL kurtarma: sayfa imajini yazar. Onbellekte varsa tazeler ve
      kirli isaretler; yoksa dogrudan dosyaya yazar. PageNo=0 ise meta
      alanlari da tazelenir.

      AViewOnly=True (v3.31 TAZELEME): DISKE YAZMAZ. Yalnizca onbellege
      kurar ve sayfayi TEMIZ isaretler (Dirty=False). Gerekce: tazeleme
      paylasimli kilit altinda calisir; Windows'ta yazma kilit ihlali
      (EWriteError) uretir. Ayrica imaj zaten WAL'de fsync'li - durabil
      kaynak WAL'dir, dosya degil; diskteki surum yazarin commit'inde
      guncellenir. Checkpoint (Truncate) yalniz yazarin Flush'indan
      sonra budandigi icin veri kaybi olmaz. }
    procedure InstallPage(PageNo: LongWord; P: PVdbPage;
      AViewOnly: Boolean = False);

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
    property ViewLsn: LongWord read FViewLsn;
    { v3.1: meta sayfa diskte bayat mi (sayfa sayisi/freelist degisti)?
      Commit yalnizca True iken meta cercevesi yazar; commit LSN'i WAL commit
      kaydinda tasindigi icin degismemis meta imaji gereksizdi. }
    property MetaDirty: Boolean read FMetaDirty;
    { v3.1: meta sayfanin YAPISAL alanlari (sayfa sayisi, freelist) degisti
      mi? Commit karari bunu kullanir. }
    property MetaStructDirty: Boolean read FStructDirty;

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
  FTxnId := 1;
  FTxnDirtyCount := 0;
  FIterations := VDB_ENC_ITER;
  { v3.16: yazma kilidi yuvasi + kilit durumu. }
  InitCriticalSection(FWriteCs);
  FWriteDepth := 0;
  FLockedShared := False;
  FLockedExcl := False;
  FAutoWrite := False;
end;

destructor TVDbPageStore.Destroy;
var
  p: PVdbPage;
begin
  try
    Close;
  except
    { yikici hata firlatmaz }
  end;
  if FRoPages <> nil then
  begin
    for p in FRoPages.Values do
      FreeMem(p);
    FreeAndNil(FRoPages);
  end;
  FRoCount := 0;
  DoneCriticalSection(FWriteCs);
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
  if (ver <> VDB_FILE_VER) and (ver <> VDB_FILE_VER_V3) and
     (ver <> VDB_FILE_VER_V4) then
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
  { v3.11/v3.13: eski (surum 3 veya 4) baslik, YAZILABILIR oturumda HEMEN
    guncel surume yukseltilir. Aksi halde bu dosyaya yeni govdeli satir
    yazildiktan sonra eski bir ikili dosyayi acip satirlari sessizce yanlis
    cozebilirdi. Salt-okunur oturum yazmadigi icin yukseltme gerekmez. }
  if ((ver = VDB_FILE_VER_V3) or (ver = VDB_FILE_VER_V4)) and not FReadOnly then
    SaveMeta;
  { v3.16: tazeleme imkasi icin son gorulen HAM meta imaji. SaveMeta
    yukarida cagrildiysa imza orada guncellenir; cagrilmadiysa burada. }
  if Length(FMetaSig) <> VDB_PAGE_SIZE then
  begin
    SetLength(FMetaSig, VDB_PAGE_SIZE);
    Move(buf[0], FMetaSig[0], VDB_PAGE_SIZE);
  end
  else
    Move(buf[0], FMetaSig[0], VDB_PAGE_SIZE);
  FSigLSN := FLSN;
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
  { v3.2: salt-okunur oturum meta sayfayi YAZMAZ. }
  if FReadOnly then Exit;
  { v3.16 guvenlik agi: paylasimli kilit altinda yazilamaz -> tam kilide
    yukselt (acilis gibi zaten tam kilitli durumlarda dokunmaz). }
  EnsureIoWrite;
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
  { v3.16: yazdigimiz imaj artik "son gorulen" imajdir. }
  if Length(FMetaSig) <> VDB_PAGE_SIZE then
    SetLength(FMetaSig, VDB_PAGE_SIZE);
  Move(buf[0], FMetaSig[0], VDB_PAGE_SIZE);
  FSigLSN := FLSN;
  FMetaDirty := False;
  FStructDirty := False;
end;

procedure TVDbPageStore.Open(ACreate: Boolean);
begin
  OpenEx(ACreate, False, VDB_DEF_BUSY_MS);
end;

{ ---------------------------------------------------------------- v3.16 }
{ v3.18 — AC KALMAYI ONLEME (adil kuyruk yerine yazar oncelikli yoklama).
  Kesin FIFO surecler arasi bir kuyruk dosyasi gerektirir; onun yerine
  yoklama araliklari ASIMETRIK yapilir: YAZAR 1 ms'de bir dener, OKUYUCU
  ustel artan araliklarla (1,2,4,...50 ms) dener. Paylasimli kilit zaten
  islem basina tutuldugu icin okuyucu kisa araliklarla birakir; yazar bu
  boslukta en gec birkac ms icinde girer. Boylece surekli okuyucu yuku
  altinda yazar acliga dusmez (olculdu: lockchk "yazar acligi" bolumu). }

function TVDbPageStore.TakeSharedLock: Boolean;
var
  t0: QWord;
  bekle: Integer;
begin
  Result := VDbLockStream(FStream, True);
  if Result then Exit;
  t0 := GetTickCount64;
  bekle := 1;
  repeat
    Sleep(bekle);
    Result := VDbLockStream(FStream, True);
    if Result then Exit;
    if bekle < 50 then bekle := bekle * 2;
  until GetTickCount64 - t0 >= QWord(FBusyMs);
end;

{ Tam (yazma) kilidini alir; alinamazsa FBusyMs sonunda ACIK hata verir.
  Yoklama 1 ms: yazar okuyucudan DAHA SIK dener (bkz. TakeSharedLock). }
procedure TVDbPageStore.LockExclusive;
var
  t0: QWord;
begin
  t0 := GetTickCount64;
  repeat
    if VDbLockStream(FStream, False) then Exit;
    if GetTickCount64 - t0 >= QWord(FBusyMs) then Break;
    Sleep(1);
  until False;
  if FBusyMs > 0 then
    raise EVdbPageStore.Create(Format(
      'veritabani mesgul: yazar kilidi %d ms icinde alinamadi ' +
      '(baska bir yazma oturumu acik): %s',
      [FBusyMs, FPath]))
  else
    raise EVdbPageStore.Create(
      'veritabani mesgul: yazar kilidi alinamadi ' +
      '(baska bir yazma oturumu acik): ' + FPath);
end;


procedure TVDbPageStore.LockReserve;
var
  t0: QWord;
begin
  if FGenStream = nil then
    raise EVdbPageStore.Create('kapali veritabani: yazar rezervasyonu alinamaz');
  { Kilitten once birak: yoksa yukaridaki karsilikli kilitlenme olusur. }
  ReleaseReadForUpgrade;
  t0 := GetTickCount64;
  repeat
    if VDbLockGenReserve(FGenStream) then Exit;
    if GetTickCount64 - t0 >= QWord(FBusyMs) then Break;
    Sleep(1);
  until False;
  if FBusyMs > 0 then
    raise EVdbPageStore.Create(Format(
      'veritabani mesgul: yazar rezervasyonu %d ms icinde alinamadi ' +
      '(baska bir surec yaziyor): %s', [FBusyMs, FPath]))
  else
    raise EVdbPageStore.Create(
      'veritabani mesgul: yazar rezervasyonu alinamadi ' +
      '(baska bir surec yaziyor): ' + FPath);
end;


{ Tam kilit ALTINDA cagrilir: diskteki meta sayfa son gorulen imajdan
  farkliysa baska bir surec commit etmistir -> onbellek dusurulur ve meta
  yeniden yuklenir. Meta sayfa duz metin oldugu icin ham karsilastirma
  yeterlidir (sifreleme yalniz kullanici sayfalarinda). }
procedure TVDbPageStore.RefreshIfStaleForce;
var
  buf: TVdbPageBuf;
  len: Int64;
  g: QWord;
begin
  { v3.16: ONCE 8 baytlik degisiklik sayaci okunur. Degismediyse 4 KB meta
    sayfayi okumaya GEREK YOK.
    v3.22: hizli yol YALNIZ sayaci okur. ONCEDEN burada da `FStream.Size`
    (GetFileSizeEx) cagriliyordu ve `ReadGen` icinde bir `FGenStream.Size`
    daha vardi: hizli yol 4 sistem cagrisi oduyordu (olculen 7,37 us/cagri,
    toplu yazmada satir basina 3 cagri = 22 us). Simdi 2 cagri (Seek+Read);
    dosya boyutu yalniz gercekten bayat olan yolda sorulur. }
  g := ReadGen;
  if (FGenStream <> nil) and (g = FSigGen) then Exit;
  len := FStream.Size;
  if len < VDB_PAGE_SIZE then Exit;
  FStream.Position := 0;
  FStream.ReadBuffer(buf, VDB_PAGE_SIZE);
  if (FGenStream = nil) and (Length(FMetaSig) = VDB_PAGE_SIZE) and
     CompareMem(@buf[0], @FMetaSig[0], VDB_PAGE_SIZE) then Exit;
  { v3.31 DELTA TAZELEME: DropCache ARTIK BURADA DEGIL.
    Onbellek bosaltilmaz; tazelenecek sayfalar kurtarma (WAL) tarafindan
    InstallPage ile yerinde guncellenir. Karar motorda: ViewLsn < WAL
    HeaderLsn ise (WAL budandi, degisiklik yalniz dosyada) motorda tam
    DropCache yapilir. Burada onbellekten vazgectigimiz tek guvenlik:
    kurtarma kanca'si YOKSA (OnRefreshed atanmamissa) tazeleme yapabilecek
    kimse yoktur -> eski davranisa donup onbellek dusurulur. }
  FPhysSize := len;
  LoadMeta;
  { v3.16: baska bir surec commit etti — WAL gorunumunu de tazele. }
  FSigGen := ReadGen;
  if Assigned(FOnRefreshed) then
    FOnRefreshed(Self)
  else
    DropCache;
end;

procedure TVDbPageStore.RefreshUnderExclusive;
var
  hadShared: Boolean;
begin
  if FStream = nil then Exit;
  hadShared := FLockedShared;
  if hadShared then
  begin
    VDbUnlockStream(FStream);
    FLockedShared := False;
    FLocked := False;
  end;
  LockExclusive;
  try
    RefreshIfStaleForce;
  finally
    VDbUnlockStream(FStream);
    if hadShared then
    begin
      FLockedShared := TakeSharedLock;
      FLocked := FLockedShared;
    end;
  end;
end;

procedure TVDbPageStore.ReleaseReadForUpgrade;
begin
  if FStream = nil then Exit;
  EnterCriticalSection(FWriteCs);
  try
    { Tam kilit zaten bizde ya da rezervasyon bizde: birakilacak sey yok. }
    if FLockedExcl then Exit;
    if FHoldDepth > 0 then Exit;
    if FWriteDepth > 0 then Exit;
    FReadDepth := 0;
    if FLockedShared then
    begin
      VDbUnlockStream(FStream);
      FLockedShared := False;
      FLocked := False;
    end;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.RefreshIfStale;
begin
  { v3.18: iyimser yazma islemi acikken (bkz. BeginDeferRefresh) okuma
    yolu tazeleme YAPMAZ. Boylece islemin goruntusu islem boyunca sabit
    kalir; anahtar basina before-image "islem basindaki deger" olur ve
    commit'te karsilastirma dogru sonuc verir. Yazma yollari bu bayragi
    YOK SAYAR (RefreshIfStaleForce): bayat onbellekle yazmak v3.17'de
    veri kaybina yol acmisti. }
  if FDeferCount > 0 then Exit;
  { v3.22: yazar rezervasyonu BIZDEYKEN (FHoldDepth > 0) baska bir surec
    commit EDEMEZ ve rezervasyon alinirken nesil karsilastirmasi
    yapilmisti (bkz. AcquireWriteHold/TryAcquireWriteHold): onbellek islem
    boyunca taze. Bu yuzden `.gen` dosyasini anahtar basina 3 kez yoklamak
    (olculen 7,37 us x 3) gereksizdi — seri toplu yazmada tazelik bedava. }
  if FHoldDepth > 0 then Exit;
  RefreshIfStaleForce;
end;

procedure TVDbPageStore.EnsureIoWrite;
begin
  if FStream = nil then Exit;
  if FReadOnly then Exit;              // salt-okunur zaten yazmaz
  if FWriteDepth > 0 then Exit;        // tam kilit bizde
  if FLockedExcl then Exit;            // acilis gibi ozel durumlar
  { Paylasimli kilidi birak, tam kilidi al. Onbellek TAZE: paylasimli kilit
    tutarken baska bir surec commit edemezdi, tazeleme gerekmez. }
  if FLockedShared then
  begin
    VDbUnlockStream(FStream);
    FLockedShared := False;
    FLocked := False;
  end;
  LockExclusive;
  FLockedExcl := True;
  FLocked := True;
  FAutoWrite := True;
end;

{ v3.16: guvenlik agi kilidini birak (bkz. FAutoWrite). }
procedure TVDbPageStore.EndIoWrite;
begin
  if FStream = nil then Exit;
  if not FAutoWrite then Exit;
  FAutoWrite := False;
  if FLockedExcl then
  begin
    VDbUnlockStream(FStream);
    FLockedExcl := False;
    FLocked := False;
  end;
  { Islem kapsamli paylasimli kilide geri don. }
  if (FReadDepth > 0) and (FStream <> nil) then
  begin
    FLockedShared := TakeSharedLock;
    FLocked := FLockedShared;
  end;
end;

{ v3.16: `<db>.gen` — surecler arasi degisiklik sayaci. }
function TVDbPageStore.GenStamp: QWord;
begin
  { v3.18: BELLEK degeri. Diskteki sayaci okumak islem basina ~2 us
    ek yuk getirirdi; tazelik zaten `RefreshIfStale` (yazma girisi) ile
    senkronlanir. }
  Result := FSigGen;
end;

procedure TVDbPageStore.UnmapGen;
begin
  if FGenMap <> nil then
  begin
    UnmapViewOfFile(FGenMap);
    FGenMap := nil;
  end;
  if FGenMapH <> 0 then
  begin
    CloseHandle(FGenMapH);
    FGenMapH := 0;
  end;
end;

procedure TVDbPageStore.UnlockGen;
begin
  if FGenStream = nil then Exit;
  VDbUnlockGenReserve(FGenStream);
end;

procedure TVDbPageStore.MapGen;
{$IFDEF WINDOWS}
var
  h: THandle;
  p: Pointer;
{$ENDIF}
begin
  UnmapGen;
  if FGenStream = nil then Exit;
  {$IFDEF WINDOWS}
  FGenMap := nil;
  FGenMapH := 0;
  { v3.31: 8 -> 16 bayt. Offset 0 = gen sayaci, offset 8 = durabil LSN. }
  if FGenStream.Size < 16 then Exit;
  h := CreateFileMapping(FGenStream.Handle, nil, PAGE_READWRITE, 0, 16, nil);
  if h = 0 then Exit;
  p := MapViewOfFile(h, FILE_MAP_READ or FILE_MAP_WRITE, 0, 0, 16);
  if p = nil then
  begin
    CloseHandle(h);
    Exit;
  end;
  FGenMapH := h;
  FGenMap := PByte(p);
  {$ENDIF}
end;

function TVDbPageStore.ReadGen: QWord;
var
  got: Integer;
begin
  Result := 0;
  if FGenStream = nil then Exit;
  { v3.25: eslenmis goruntu varsa okuma TEK bellek erisimidir; sistem
    cagrisi yok. Yirtik okuma riski yok: sayac her zaman kilit altinda
    yazilir/okunur (bkz. alan bildirimi). }
  if FGenMap <> nil then
  begin
    Result := PQWord(FGenMap)^;
    Exit;
  end;
  { v3.22: `FGenStream.Size` denetimi KALDIRILDI (hizli yolda fazladan
    GetFileSizeEx). Kisa okuma zaten 0 dondurup tazelemeyi zorluyor. }
  FGenStream.Position := 0;
  { v3.18: `.gen` yalniz bir IPUCUDUR (asil veri baska yerde). Kisa okuma
    gercek bir yarisin isareti olabilir; istisna atmak yerine 0 don ve
    tazelemeyi ZORLA — 0 hicbir zaman gecerli bir nesil degildir. }
  got := FGenStream.Read(Result, 8);
  if got <> 8 then Result := 0;
end;

procedure TVDbPageStore.BumpGen;
var
  v: QWord;
begin
  if FGenStream = nil then Exit;
  v := ReadGen + 1;
  { v4: eslenmis goruntu varsa dogrudan bellek bolumune yaz — Seek + WriteFile
    (2 syscall, ~2,5 us) yerine tek bellek erisimi. Eski v3.25 yorumu WriteFile
    'niyet acik' diye birakmisti; esleme zaten ayni onbellek bolumunu gosterir
    ve yazan tarafin kendi goruntusu de aninda guncellenir. Dayaniklilik ayni:
    her iki yolda da OS onbellegi uzerinden gider, FlushFileBuffers yok. }
  if FGenMap <> nil then
  begin
    PQWord(FGenMap)^ := v;
    FSigGen := v;
    Exit;
  end;
  FGenStream.Position := 0;
  FGenStream.WriteBuffer(v, 8);
  FSigGen := v;
end;

{ v3.31: `.gen` eslemesinde offset 8'de durabil LSN. }
function TVDbPageStore.ReadDurableLsn: LongWord;
begin
  Result := 0;
  if FGenMap = nil then Exit;
  Result := PLongWord(FGenMap + 8)^;
end;

function TVDbPageStore.DurableLsn: LongWord;
begin
  Result := ReadDurableLsn;
end;

procedure TVDbPageStore.SetDurableLsn(Value: LongWord);
var
  p: PLongWord;
  cur: LongWord;
begin
  if (FGenMap = nil) or (Value = 0) then Exit;
  p := PLongWord(FGenMap + 8);
  repeat
    cur := p^;
    if Value <= cur then Exit;
    { Atomik: yalnizca daha buyuk deger yazilir (monoton artis). }
    if LongWord(InterlockedCompareExchange(PLongint(p)^, Value, cur)) = cur then
      Exit;
  until False;
end;

procedure TVDbPageStore.AcquireWrite;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('kapali veritabani: yazma kilidi alinamaz');
  if FReadOnly then
    raise EVdbPageStore.Create('salt-okunur oturumda yazma yapilamaz');
  EnterCriticalSection(FWriteCs);
  try
    { Ayni surecte ic ice giris: kilit zaten bizde. }
    if FWriteDepth > 0 then
    begin
      Inc(FWriteDepth);
      Exit;
    end;
    { Guvenlik agi tam kilidi zaten almissa (yazma ilkeli icinden cagri)
      sahipligi acik yazmaya devret. }
    if FAutoWrite and FLockedExcl then
    begin
      FAutoWrite := False;
      FWriteDepth := 1;
      Exit;
    end;
    { KILITLENMEYI ONLE: paylasimliyi BIRAK, sonra tam kilidi iste.
      Iki surec de ayni anda yukseltmek isterse ikisi de beklemez. }
    if FLockedShared then
    begin
      VDbUnlockStream(FStream);
      FLockedShared := False;
      FLocked := False;
    end;
    { v3.18: YAZAR REZERVASYONU. Uzun acik islem yalniz rezervasyonu tutar
      (bkz. AcquireWriteHold); kisa yazma yolu da AYNI rezervasyonu almak
      ZORUNDA, yoksa acik bir islem varken ikinci yazar paralel girer ve
      sira garantisi kaybolur. Rezervasyon `.gen` handle'inda tutulur.
      FHoldDepth > 0 ise rezervasyon zaten BIZDE. }
    if FHoldDepth = 0 then
    begin
      { v3.18 dilim 6: ACILIS rezervasyon ALMAZ (AcquireWriteOpen). Rezervasyon
        ISLEMLERI siralar; acilis ise yalniz kisa bir kritik bolum icin tam
        kilide ihtiyac duyar. Once acilis da rezervasyon istiyordu ve acik bir
        islem tutan surec varken ikinci yazar HIC ACILAMIYORDU (olculdu:
        lockchk 3c "yazar rezervasyonu 500 ms icinde alinamadi"). }
      if not FSkipReserve then
      begin
        LockReserve;
        FReserved := True;
      end;
    end;
    LockExclusive;
    FLockedExcl := True;
    FLocked := True;
    try
      RefreshIfStaleForce;
    except
      VDbUnlockStream(FStream);
      FLockedExcl := False;
      FLocked := False;
      if (FHoldDepth = 0) and FReserved then
      begin
        UnlockGen;
        FReserved := False;
      end;
      if FReadDepth > 0 then
      begin
        FLockedShared := TakeSharedLock;
        FLocked := FLockedShared;
      end;
      raise;
    end;
    FWriteDepth := 1;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.AcquireWriteOpen;
begin
  { v3.18 dilim 6: ACILIS icin tam kilit — REZERVASYONSIZ. Rezervasyon
    ISLEMLERI siralar; iki yazar surec ayni anda acilabilsin diye acilis
    rezervasyon istemez. Acilisin kritik bolumu (WAL kurtarma, meta yazimi,
    `.gen` artisi) tam kilit altindadir ve commit de ayni tam kilidi alir;
    yani acilis ile commit CAKISMAZ. }
  FSkipReserve := True;
  try
    AcquireWrite;
  finally
    FSkipReserve := False;
  end;
end;

{ v3.16: islem kapsamli PAYLASIMLI kilit. Yazan oturumda kilit artik oturum
  boyu tutulmadigi icin her islem girisi kilit alir ve meta imgasini
  dogrular; boylece baska bir surec commit ettiyse onbellek tazelenir.
  v3.18: AYNI SEY SALT-OKUNUR oturum icin de gecerli. Onceki surumde RO
  oturum paylasimli kilidi OTURUM BOYU tutuyordu; acik bir RO oturum
  yazarlari SINIRSIZ blokluyordu. Artik RO de kilit alir/birakir.
  BEDEL: RO oturumda tekrarlanabilir okuma (sabit goruntu) YOKTUR; her
  ifade guncel durumu gorur. Diske yine hicbir sey yazilmaz. }
procedure TVDbPageStore.AcquireRead;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('kapali veritabani: okuma kilidi alinamaz');
  EnterCriticalSection(FWriteCs);
  try
    if FWriteDepth > 0 then
    begin
      Inc(FReadDepth);
      Exit;
    end;
    if FReadDepth > 0 then
    begin
      Inc(FReadDepth);
      Exit;
    end;
    { v3.22: yazar rezervasyonu BIZDEYKEN (FHoldDepth > 0) baska bir surec
      commit EDEMEZ: rezervasyon, yazarlarin tam kilit/checkpoint/truncate
      yolunun onunde durur. Onbellek de rezervasyon aninda tazelenmisti
      (bkz. AcquireWriteHold). Bu yuzden anahtar basina paylasimli kilit
      (olculen 0,96 us) ve tazelik yoklamasi gereksizdir.
      KILIT ALINMADIGI icin FLockedShared False kalir; ReleaseRead yalniz
      sayaci dusurur. }
    if FHoldDepth > 0 then
    begin
      Inc(FReadDepth);
      Exit;
    end;
    if not FLockedShared then
    begin
      FLockedShared := TakeSharedLock;
      if not FLockedShared then
        raise EVdbPageStore.Create(
          'veritabani mesgul: paylasimli kilit alinamadi (baska bir surec ' +
          'tam kilitli): ' + FPath);
      FLocked := True;
      RefreshIfStale;
    end;
    FReadDepth := 1;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.ReleaseRead;
begin
  if FStream = nil then Exit;
  EnterCriticalSection(FWriteCs);
  try
    if FReadDepth <= 0 then Exit;
    Dec(FReadDepth);
    if FReadDepth > 0 then Exit;
    { v3.16 guvenlik agi: yazma sirasinda otomatik yukseltilen tam kilidi
      islem sonunda birak (once tam, sonra paylasimli karari). }
    if FAutoWrite then
    begin
      FAutoWrite := False;
      if FLockedExcl then
      begin
        VDbUnlockStream(FStream);
        FLockedExcl := False;
        FLocked := False;
      end;
    end;
    { Yazma kilidi acikken paylasimli kilit zaten birakilmistir. }
    if FWriteDepth > 0 then Exit;
    if FLockedShared then
    begin
      VDbUnlockStream(FStream);
      FLockedShared := False;
      FLocked := False;
    end;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

function TVDbPageStore.WriteHeld: Boolean;
begin
  Result := FWriteDepth > 0;
end;

procedure TVDbPageStore.ReleaseWrite;
var
  t0: QWord;
begin
  if FStream = nil then Exit;
  EnterCriticalSection(FWriteCs);
  try
    if FWriteDepth <= 0 then Exit;
    Dec(FWriteDepth);
    if FWriteDepth > 0 then Exit;
    { v3.16: ISLEM SONU — degisiklik sayacini artir. Baska bir surec bunu
      gorunce onbellegini tazeler. Meta sayfaya DOKUNULMAZ: taban dosyanin
      kendi kendine tutarliligi korunur (sayfalar hala WAL'de olabilir). }
    if (FGenStream <> nil) and FLockedExcl and not FReadOnly then
      BumpGen;
    if FLockedExcl then
    begin
      VDbUnlockStream(FStream);
      FLockedExcl := False;
      FLocked := False;
    end;
    { v3.18: rezervasyonu birak (acik islem tutmuyorsa). }
    if (FHoldDepth = 0) and FReserved then
    begin
      UnlockGen;
      FReserved := False;
    end;
    { Paylasimliya don YALNIZCA okuyucu kilidi hala acikken. Oturum kapsami
      kilit modelinde (FReadDepth = 0) tam kilit tamamen birakilir. }
    if FReadDepth > 0 then
    begin
      FLockedShared := VDbLockStream(FStream, True);
      t0 := GetTickCount64;
      while (not FLockedShared) and (GetTickCount64 - t0 < 5000) do
      begin
        Sleep(1);
        FLockedShared := VDbLockStream(FStream, True);
      end;
      FLocked := FLockedShared;
    end;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

{ v3.18: ACIK ISLEM REZERVASYONU.
  Uzun bir yazma islemi (BeginBatch..CommitBatch) VERI kilidini tutmaz:
  yalniz `.gen` handle'i uzerinde yazar rezervasyonu tutar. Sonuc:
  - Okuyucular BLOKLANMAZ (paylasimli kilit yalniz FStream'de, rezervasyon
    orada degil). Onceki surumde BeginBatch tam kilidi aliyordu ve 2 sn'lik
    bir islem bile okuyucuya "veritabani mesgul" veriyordu (olculdu).
  - Diger YAZARLAR yine sirayla girer: hem rezervasyon hem veri kilidi
    ayni `.gen`/`FStream` ikilisi uzerinden alinir.
  Rezervasyon sirasinda baska surec commit EDEMEZ, bu yuzden islem
  basindaki tazeleme islem sonuna kadar gecerlidir (kayip guncelleme
  riski BU dilimde ARTMAZ). }
procedure TVDbPageStore.AcquireWriteHold;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('kapali veritabani: yazma kilidi alinamaz');
  if FReadOnly then
    raise EVdbPageStore.Create('salt-okunur oturumda yazma yapilamaz');
  EnterCriticalSection(FWriteCs);
  try
    if FHoldDepth > 0 then
    begin
      Inc(FHoldDepth);
      Exit;
    end;
    if FGenStream = nil then
      raise EVdbPageStore.Create(
        'yazar rezervasyonu kurulamadi: degisiklik sayaci yok: ' + FPath);
    LockReserve;
    FReserved := True;
    try
      { v3.21: rezervasyon bizdeyken baska bir yazar commit edemez; nesil
        degismediyse tam kilit turu gereksiz (bkz. TryAcquireWriteHold). }
      if ReadGen <> FSigGen then
        RefreshUnderExclusive;
    except
      UnlockGen;
      FReserved := False;
      raise;
    end;
    FHoldDepth := 1;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.ReleaseWriteHold;
begin
  if FStream = nil then Exit;
  EnterCriticalSection(FWriteCs);
  try
    if FHoldDepth <= 0 then Exit;
    Dec(FHoldDepth);
    if FHoldDepth > 0 then Exit;
    if FReserved then
    begin
      UnlockGen;
      FReserved := False;
    end;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

{ v3.18: PARALEL COK YAZAR — beklemeden rezervasyon denemesi.
  Basarili olursa bugunku (seri) davranis aynen surer: islem boyunca
  rezervasyon BIZDE, anahtar basina before-image GEREKMEZ (sifir ek
  maliyet). Basarisizsa baska bir surec ACIK islem tutuyor demektir:
  cagiran iyimser moda gecer (NeedBefore + BeginDeferRefresh) ve commit
  aninda rezervasyonu bekler. }
function TVDbPageStore.TryAcquireWriteHold: Boolean;
begin
  Result := False;
  if FStream = nil then Exit;
  if FReadOnly then Exit;
  EnterCriticalSection(FWriteCs);
  try
    if FHoldDepth > 0 then
    begin
      Inc(FHoldDepth);
      Exit(True);
    end;
    if FGenStream = nil then Exit;
    if not VDbLockGenReserve(FGenStream) then Exit;
    FReserved := True;
    try
      { v3.21: rezervasyon bizdeyken baska bir yazar COMMIT EDEMEZ (.gen
        neslini yalniz yazar artirir). Nesil degismediyse tam kilit turu
        (LockExclusive + ReadGen + unlock + paylasimliyi geri alma = 4 sistem
        cagrisi) gereksizdir; olculen kazanc ~10 us/commit. }
      if ReadGen <> FSigGen then
        RefreshUnderExclusive;
    except
      UnlockGen;
      FReserved := False;
      raise;
    end;
    FHoldDepth := 1;
    Result := True;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.BeginDeferRefresh;
begin
  EnterCriticalSection(FWriteCs);
  try
    inc(FDeferCount);
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.EndDeferRefresh;
begin
  EnterCriticalSection(FWriteCs);
  try
    if FDeferCount > 0 then dec(FDeferCount);
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.AcquireDataWrite;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('kapali veritabani: yazma kilidi alinamaz');
  if FReadOnly then
    raise EVdbPageStore.Create('salt-okunur oturumda yazma yapilamaz');
  EnterCriticalSection(FWriteCs);
  try
    { Kisa yazma yolu zaten tam kilidi tutuyor olabilir. }
    if FLockedExcl then Exit;
    if FLockedShared then
    begin
      VDbUnlockStream(FStream);
      FLockedShared := False;
      FLocked := False;
    end;
    LockExclusive;
    FLockedExcl := True;
    FLocked := True;
    try
      RefreshIfStaleForce;
    except
      VDbUnlockStream(FStream);
      FLockedExcl := False;
      FLocked := False;
      if FReadDepth > 0 then
      begin
        FLockedShared := TakeSharedLock;
        FLocked := FLockedShared;
      end;
      raise;
    end;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.ReleaseDataWrite;
var
  t0: QWord;
begin
  if FStream = nil then Exit;
  EnterCriticalSection(FWriteCs);
  try
    if not FLockedExcl then Exit;
    { Veri penceresi kapandi: degisiklik sayacini SIMDI artir. Acik islem
      rezervasyonu hala bizde olsa da diger sureclerin okuyuculari taze
      veriyi gormeli. }
    if (FGenStream <> nil) and not FReadOnly then
      BumpGen;
    VDbUnlockStream(FStream);
    FLockedExcl := False;
    FLocked := False;
    if FReadDepth > 0 then
    begin
      FLockedShared := VDbLockStream(FStream, True);
      t0 := GetTickCount64;
      while (not FLockedShared) and (GetTickCount64 - t0 < 5000) do
      begin
        Sleep(1);
        FLockedShared := VDbLockStream(FStream, True);
      end;
      FLocked := FLockedShared;
    end;
  finally
    LeaveCriticalSection(FWriteCs);
  end;
end;

procedure TVDbPageStore.OpenEx(ACreate: Boolean; AReadOnly: Boolean;
  ABusyMs: Integer);
var
  exists: Boolean;
  t0: QWord;
  needUpgrade: Boolean;
  ver32: LongWord;
  z: QWord;
begin
  if FStream <> nil then Exit;
  exists := FileExists(FPath);
  if not exists and not ACreate then
    raise EVdbPageStore.Create('veritabani dosyasi yok: ' + FPath);
  if AReadOnly and not exists then
    raise EVdbPageStore.Create('salt-okunur acilis: dosya yok: ' + FPath);
  FBusyMs := ABusyMs;
  try
    if AReadOnly then
      { Paylasim: yazar da acabilmeli (fmShareDenyNone). Kilit PAYLASIMLI. }
      FStream := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone)
    else if exists then
      FStream := TFileStream.Create(FPath, fmOpenReadWrite or fmShareDenyNone)
    else
      FStream := TFileStream.Create(FPath, fmCreate or fmShareDenyNone);
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
    { v3.16: SURECLER ARASI COK YAZARLILIK.
      ONCEDEN acilista yazar oturum TAM kilit aliyordu: ayni dosyaya ikinci
      surec hic acamiyordu. Artik HER oturum PAYLASIMLI kilit alir; yazma
      girisinde (AcquireWrite) paylasimli birakilip tam kilit alinir, cikista
      tersi yapilir. Iki surec ayni anda acabilir ve sirayla yazar.
      Yeni dosyayi olusturan oturum, basligi yazarken TAM kilit tutar. }
    FLockedShared := False;
    FLockedExcl := False;
    FLocked := False;
    { v3.16: SURECLER ARASI COK YAZARLILIK — kilit semantigi OLCULEREK
      belirlendi (lckprobe):
        * PAYLASIMLI kilit = YALNIZ OKUMA. Ayni handle uzerinden bile yazma
          EWriteError verir.
        * TAM kilit = yalniz bu handle; BASKA handle'dan okuma da EReadError
          verir.
      Sonuc: kilit ALINMADAN dosyadan okumak guvenli degildir (baska surec
      tam kilitliyken okuma patlar). Bu yuzden YAZAN oturum acilisi HER ZAMAN
      tam kilit altinda yapar (WAL kurtarma, yukseltme, meta yazimi hep
      yazma), isi bitince PAYLASIMLI kilit'e iner. Boylece iki surec ayni
      anda ACIK olabilir; yazma aninda sirayla tam kilide yukselir. }
    if not AReadOnly then
    begin
      LockExclusive;
      FLockedExcl := True;
      FLocked := True;
    end
    else
    begin
      if not TakeSharedLock then
        raise EVdbPageStore.Create(
          'veritabani mesgul: paylasimli kilit alinamadi (baska bir surec ' +
          'tam kilitli): ' + FPath);
      FLockedShared := True;
      FLocked := True;
    end;
    try
      FPhysSize := FStream.Size;
      FReadOnly := AReadOnly;
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
      { v3.16: YAZAN oturumda kilit SAKLANMAZ. Oturum boyu paylasimli kilit
        tutmak ikinci yazar surecin onunu tikiyordu (olculdu: prochk B 20 s
        bekleyip acilamadi). Artik kilit ISLEM BASINA alinir: AcquireRead /
        AcquireWrite. v3.18: ayni kural SALT-OKUNUR oturum icin de gecerli;
        acik RO oturum artik yazarlari bloklamaz. }
      { v3.16: degisiklik sayaci (<db>.gen). Paylasima acik; her surec kendi
        handle'i ile okur/yazar; yoksa olusturulur. Kilit BIRAKILMADAN once
        acilir ki acilis artisi ile yaris olmasin. }
      try
        FGenStream := TFileStream.Create(FPath + '.gen',
          fmOpenReadWrite or fmShareDenyNone);
      except
        try
          FGenStream := TFileStream.Create(FPath + '.gen',
            fmCreate or fmShareDenyNone);
        except
          FGenStream := nil;
        end;
      end;
      if FGenStream <> nil then
      begin
        { v3.31: 8 -> 16 bayt (offset 8 = durabil LSN). Eski 8 baytlik
          dosya buyutulur; gen sayaci korunur, durabil LSN 0'dan baslar
          (fazladan fsync, guvenli). }
        if FGenStream.Size < 16 then
        begin
          if FGenStream.Size < 8 then
          begin
            FSigGen := 0;
            FGenStream.Position := 0;
            FGenStream.WriteBuffer(FSigGen, 8);
          end
          else
            FSigGen := ReadGen;
          FGenStream.Position := 8;
          z := 0;
          FGenStream.WriteBuffer(z, 8);  { durabil LSN = 0 }
        end
        else
          FSigGen := ReadGen;
        { v3.25: sayac eslemesi (yalniz okuma hizlandirmasi). }
        MapGen;
        { v3.16: her YAZAR oturum acilisi sayaci bir kez ilerletir: acilis
          sirasinda yazilan meta (surum yukseltmesi) boylece diger sureclere
          de bildirilmis olur. Maliyet: oturum basina 8 bayt. }
        if not AReadOnly then
          BumpGen;
      end;
      { v3.31: onbellek bos, diskteki meta kadar taze. Kurtarma bunu
        SetViewLsn ile ilerletecek (bkz. TVdbPageEngine.Open). }
      FViewLsn := FLSN;
      { v3.18: acilis bitince kilit BIRAKILIR (hem yazan hem RO). Boylece
        iki surec ayni anda acik olabilir; kilit yalniz islem basina alinir. }
      if FLockedExcl or FLockedShared then
      begin
        VDbUnlockStream(FStream);
        FLockedExcl := False;
        FLockedShared := False;
        FLocked := False;
      end;
    except
      if FLockedShared or FLockedExcl then VDbUnlockStream(FStream);
      FLocked := False;
      FLockedShared := False;
      FLockedExcl := False;
      UnmapGen;
      FreeAndNil(FGenStream);
      FreeAndNil(FStream);
      raise;
    end;
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
        { v3.16: yazma basligi/sayfalari icin tam kilit gerekir. }
        AcquireWrite;
        try
          Flush(True);
          { v3.1: onceden ayrilmis parcayi kirp: dosya boyu = mantiksal boy. }
          TrimToLogical;
        finally
          FWriteDepth := 0;
          if FLockedExcl then VDbUnlockStream(FStream);
          FLockedExcl := False;
          FLocked := False;
        end;
      end;
    finally
      if FLockedShared then VDbUnlockStream(FStream);
      if FLockedExcl then VDbUnlockStream(FStream);
      UnmapGen;
      FreeAndNil(FGenStream);
      FreeAndNil(FStream);
      FLocked := False;
      FLockedShared := False;
      FLockedExcl := False;
      FWriteDepth := 0;
    end;
  finally
    DropCache;
  end;
end;

procedure TVDbPageStore.CloseNoFlush;
begin
  if FStream = nil then Exit;
  if FLockedShared then VDbUnlockStream(FStream);
  if FLockedExcl then VDbUnlockStream(FStream);
  UnmapGen;
  FreeAndNil(FGenStream);
  FreeAndNil(FStream);
  FLocked := False;
  FLockedShared := False;
  FLockedExcl := False;
  FWriteDepth := 0;
  FMetaDirty := False;
  DropCache;
end;

{ ==================================================== v3.2 salt-okunur katman }

{ v3.18: RO oturumunun WAL imajlarini (FRoPages) bosaltir. Baska bir
  surec commit ettiginde motor bunu cagirir ve WAL'i yeniden uygular.
  Diske HICBIR sey yazilmaz; yalnizca bellek imajlari birakilir. }
procedure TVDbPageStore.ResetReadOnlyImages;
var
  q: PVdbPage;
begin
  if FRoPages = nil then Exit;
  for q in FRoPages.Values do
    FreeMem(q);
  FRoPages.Clear;
  FRoCount := 0;
end;

procedure TVDbPageStore.InstallReadOnlyPage(PageNo: LongWord; P: PVdbPage);
var
  q: PVdbPage;
  buf: TVDbPageBuf;
  dl: LongWord;
begin
  if not FReadOnly then Exit;
  if FRoPages = nil then
    FRoPages := TDictionary<LongWord, PVdbPage>.Create;
  if FRoPages.TryGetValue(PageNo, q) then
    Move(P^, q^, VDB_PAGE_SIZE)
  else
  begin
    GetMem(q, VDB_PAGE_SIZE);
    Move(P^, q^, VDB_PAGE_SIZE);
    FRoPages.Add(PageNo, q);
    Inc(FRoCount);
  end;
  if PageNo = VDB_HDR_PAGE then
  begin
    { Meta imaji WAL'den geldi: mantiksal alanlari tazele, DISKE YAZMA.
      Boylece WAL'de buyuyen dosya bu oturumda tam gorunur. }
    Move(q^, buf, VDB_PAGE_SIZE);
    Move(buf[12], dl, 4);
    if dl >= 1 then FPageCount := dl;
    Move(buf[16], FFreeTrunk, 4);
    Move(buf[20], FFreeCount, 4);
    Move(buf[24], FLSN, 4);
  end
  else if PageNo >= FPageCount then
    FPageCount := PageNo + 1;
end;

function TVDbPageStore.ReadOnlyPageCount: Integer;
begin
  Result := FRoCount;
end;

{ ============================================================ okuma/yazma }

{ v3.19 — KILIT CAKISMASI (olculdu: pcbench 4 surec, 8 kosuda 2 kez
  "EReadError: Stream read error"; teshis eklendiginde ayrinti netlesti:
  "sayfa 1 okunamadi (konum 4096, dosya boyu 282624, mantiksal sayfa 5)" —
  yani dosya SAGLAM, EOF yok).

  NEDEN: Windows'ta byte-araligi kilidi (LockFileEx) TUM dosyayi kapsiyor.
  Bir surec TAM kilit tutarken baska surecin ReadFile'i ERROR_LOCK_VIOLATION
  (33) ile duser; TFileStream bunu "Stream read error" yapar. Iyimser modda
  islem ARASINDA kilit tutulmuyor (bilincli: okuyucular bloklanmasin), bu
  yuzden bir islemin okuma sayfalari baska surecin TAM kilidi altinda
  kalabiliyor.

  COZUM: okuma kilit ihlaliyle duserse PAYLASIMLI kilidi ALAYIM yeniden
  dene. Kilit tutmuyorken aldigimiz icin karsilikli kilitlenme yok; TAM
  kilit tutan surec commit'ini bitirince okuma surer. Kilit zaten bizdeyse
  yeniden denemek anlamsiz (gercek bozulma) -> hemen acik hata. }
procedure TVDbPageStore.ReadBytesAt(Pos: Int64; var Buf; Len: Integer;
  PageNo: LongWord);
var
  tries: Integer;
  selfShared: Boolean;
  ok: Boolean;
  err: string;
begin
  tries := 0;
  selfShared := False;
  repeat
    ok := True;
    err := '';
    try
      FStream.Position := Pos;
      FStream.ReadBuffer(Buf, Len);
    except
      on E: Exception do
      begin
        ok := False;
        err := E.Message;
      end;
    end;
    if ok then Break;
    Inc(tries);
    if (tries <= 8) and ((not FLockedExcl) and (not FLockedShared)) then
    begin
      { Kilidi al (yazar bitene kadar bekler), sonra tekrar dene. }
      if TakeSharedLock then
      begin
        selfShared := True;
        Continue;
      end;
    end;
    raise EVdbPageStore.Create(Format(
      'sayfa %d okunamadi (konum %d, dosya boyu %d, mantiksal sayfa %d,' +
      ' kilit paylasimli=%d tam=%d, deneme %d): %s',
      [PageNo, Pos, FStream.Size, FPageCount, Ord(FLockedShared),
       Ord(FLockedExcl), tries, err]));
  until False;
  if selfShared then
  begin
    VDbUnlockStream(FStream);
    selfShared := False;
  end;
end;

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
    ReadBytesAt(OffsetOf(PageNo), env[0], VDB_ENC_ENVELOPE, PageNo);
    if not VDbPageOpen(FKey, FSalt, PageNo, env, plain) then
      raise EVdbPageStore.Create(Format(
        'sayfa %d: sifre cozulemedi (yanlis anahtar ya da bozuk zarf)',
        [PageNo]));
    Move(plain[0], P^, VDB_PAGE_SIZE);
  end
  else
    ReadBytesAt(OffsetOf(PageNo), P^, VDB_PAGE_SIZE, PageNo);
  Inc(FReads);
end;

procedure TVDbPageStore.WritePageAt(PageNo: LongWord; P: PVdbPage);
var
  env: TBytes;
  plain: TBytes;
begin
  if FReadOnly then
    raise EVdbPageStore.Create(Format(
      'salt-okunur veritabani: sayfa %d yazilamaz', [PageNo]));
  { v3.16 guvenlik agi: paylasimli kilit altinda yazma olmaz. }
  EnsureIoWrite;
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

function TVDbPageStore.LoadFrame(PageNo: LongWord; AImage: PVdbPage): Integer;
var
  idx: Integer;
  fromPending: Boolean;
  roP: PVdbPage;
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
  if AImage <> nil then
  begin
    { v3.31 TAZELEME: imaj hazir, diskten okunmaz. Imaj WAL'de fsync'li
      oldugu icin TEMIZ isaretlenir; diskteki surum yazarin commit'inde
      guncellenir. }
    Move(AImage^, FFrames[idx].Data, VDB_PAGE_SIZE);
    FFrames[idx].PageNo := PageNo;
    FFrames[idx].Pins := 0;
    FFrames[idx].Dirty := False;
    FFrames[idx].TxnMark := 0;
    FFrames[idx].Ref := True;
    HashPut(PageNo, idx);
    Exit(idx);
  end;
  fromPending := False;
  if (FRoPages <> nil) and FRoPages.TryGetValue(PageNo, roP) then
  begin
    { v3.2 salt-okunur: imaj WAL'den geldi, diskte olmayabilir. }
    Move(roP^, FFrames[idx].Data, VDB_PAGE_SIZE);
    fromPending := True;
  end
  else if Assigned(FOnMiss) and FOnMiss(PageNo, @FFrames[idx].Data) then
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
  { Salt-okunurda HICBIR sey kirli degildir; aksi halde Flush yazmaya
    calisirdi. Yazma modunda pending imaji kirli isaretlenir. }
  if FReadOnly then
    FFrames[idx].Dirty := False
  else
    FFrames[idx].Dirty := fromPending;
  { v3.1: pending'den gelen imaj WAL'de olmayabilir (tahliye commit'ten
    ONCE olduysa). Mark'i guncel islem yap ki bir sonraki Commit onu yazsin;
    gereksiz yazim zararsiz, atlanan yazim VERI KAYBI olurdu. }
  if FReadOnly then FFrames[idx].TxnMark := 0
  else if fromPending then
  begin
    FFrames[idx].TxnMark := FTxnId;
    { P-54: pending'den gelen imaj da kirli listeye girer. }
    if FTxnDirtyCount >= Length(FTxnDirty) then
      SetLength(FTxnDirty, FTxnDirtyCount * 2 + 8);
    FTxnDirty[FTxnDirtyCount] := idx;
    Inc(FTxnDirtyCount);
  end
  else FFrames[idx].TxnMark := 0;
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
  if Dirty then
  begin
    FFrames[idx].Dirty := True;
    { v3.1: bu islemde degisti -> bir sonraki Commit bu cerceveyi WAL'e yazar.
      P-54: cerceve listeye yalnizca geciste eklenir (tekrar kirletmede
      zaten listededir). }
    if FFrames[idx].TxnMark <> FTxnId then
    begin
      FFrames[idx].TxnMark := FTxnId;
      if FTxnDirtyCount >= Length(FTxnDirty) then
        SetLength(FTxnDirty, FTxnDirtyCount * 2 + 8);
      FTxnDirty[FTxnDirtyCount] := idx;
      Inc(FTxnDirtyCount);
    end;
  end;
  Dec(FFrames[idx].Pins);
end;

procedure TVDbPageStore.ExtendFile(out NewPageNo: LongWord);
begin
  NewPageNo := FPageCount;
  Inc(FPageCount);
  GrowTo(RequiredFileSize(FPageCount));
  FFreshPage := NewPageNo;
  FMetaDirty := True;
  FStructDirty := True;
end;

procedure TVDbPageStore.GrowTo(Required: Int64);
var
  want: Int64;
begin
  if Required <= FPhysSize then Exit;
  { v3.2: salt-okunur oturumda dosya BUYUTULMEZ. WAL ile buyuyen sayfalar
    yalnizca bellek katmaninda yasar. }
  if FReadOnly then
  begin
    FPhysSize := Required;
    Exit;
  end;
  EnsureIoWrite;
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
  EnsureIoWrite;
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
  trunk, cnt: LongWord;
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
    { Ilk trunk: serbest birakilan sayfanin KENDISINI trunk yap.
      Eski yol ExtendFile ile dosyayi 1 sayfa buyutuyordu (bloatbench:
      tam silmede bosuna +8 KB). Trunk sayfalari FreeCount'a girmez. }
    if not GetPageInternal(PageNo, False, P) then
      raise EVdbPageStore.Create('FreePage: trunk sayfasi olusturulamadi');
    TrunkInit(P, PageNo, 0);
    Release(PageNo, True);
    FFreeTrunk := PageNo;
    FMetaDirty := True;
    FStructDirty := True;
    Exit;
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
    { Trunk dolu: serbest birakilan sayfayi YENI trunk yap (dosya buyumesin).
      ExtendFile yerine PageNo kullanilir; trunk FreeCount'a girmez. }
    Release(trunk, False);
    if not GetPageInternal(PageNo, False, P) then
      raise EVdbPageStore.Create('FreePage: yeni trunk olusturulamadi');
    TrunkInit(P, PageNo, trunk);
    Release(PageNo, True);
    FFreeTrunk := PageNo;
    FMetaDirty := True;
    FStructDirty := True;
    Exit;
  end;

  TrunkSetEntry(P, cnt, PageNo);
  TrunkSetCount(P, cnt + 1);
  TrunkSeal(P);
  Release(trunk, True);
  Inc(FFreeCount);
  FMetaDirty := True;
  FStructDirty := True;
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
      FStructDirty := True;
      Break;
    end;
    Dec(cnt);
    PageNo := TrunkEntry(tp, cnt);
    TrunkSetCount(tp, cnt);
    TrunkSeal(tp);
    Release(trunk, True);
    Dec(FFreeCount);
    FMetaDirty := True;
    FStructDirty := True;
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
  { v3.31: tazeleme sirasinda yeni sayfa no'su FPageCount'i artirmis olabilir
    ama disk buyutulmemisti (paylasimli kilit). Burada yazma kilidi altinda
    dosya mantiksal boyuna buyutulur; aksi halde WritePageAt EOF'a yazar ve
    TrimToLogical yanlis kirpar. }
  if (not FReadOnly) and (FPageCount > 0) then
    GrowTo(RequiredFileSize(FPageCount));
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
    FFrames[i].TxnMark := 0;
  end;
  if FHashKey <> nil then
    HashReset;
  FClock := 0;
  FTxnDirtyCount := 0;   // P-54
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

function TVDbPageStore.TxnPages: TVdbPageNoArray;
var
  i, idx, n, cap: Integer;
begin
  SetLength(Result, 0);
  n := 0;
  cap := 0;
  { P-54: tam havuz taramasi (O(512)) yerine kirli cerceve listesi (O(kirli)).
    Liste eski/tekrarli girdiler icerebilir; asagidaki dogrulama suzer. }
  for i := 0 to FTxnDirtyCount - 1 do
  begin
    idx := FTxnDirty[i];
    if (idx >= 0) and (idx < FPoolPages) and
       (FFrames[idx].PageNo <> 0) and FFrames[idx].Dirty and
       (FFrames[idx].TxnMark = FTxnId) and
       (FFrames[idx].PageNo <> VDB_HDR_PAGE) then
    begin
      if n >= cap then
      begin
        if cap = 0 then cap := 8 else cap := cap * 2;
        SetLength(Result, cap);
      end;
      Result[n] := FFrames[idx].PageNo;
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

function TVDbPageStore.TxnMarkOf(PageNo: LongWord): LongWord;
var
  idx: Integer;
begin
  idx := FindFrame(PageNo);
  if idx < 0 then Exit(0);
  Result := FFrames[idx].TxnMark;
end;

procedure TVDbPageStore.EndTxn;
begin
  Inc(FTxnId);
  if FTxnId = 0 then FTxnId := 1;
  { P-54: kirli cerceve listesi bu islem icin bitti. }
  FTxnDirtyCount := 0;
end;

procedure TVDbPageStore.SetLSN(Value: LongWord);
begin
  FLSN := Value;
  FMetaDirty := True;
end;

procedure TVDbPageStore.SetViewLsn(Value: LongWord);
begin
  FViewLsn := Value;
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
  { v3.18: gecici ad SÜREÇ benzersiz olmali. Iki surec ayni hedefe kopyalarsa
    (olculdu: degisim gunlugu taban imaji) ayni .tmp dosyasina yazip
    "dosya kullanimda" hatasi veriyorlardi. }
  tmp := DestPath + '.' + VDbProcessToken + '.tmp';
  if FileExists(tmp) then SysUtils.DeleteFile(tmp);
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
      if not SysUtils.DeleteFile(DestPath) then
        raise EVdbPageStore.Create('kopya: eski hedef silinemedi: ' + DestPath);
    if not RenameFile(tmp, DestPath) then
      raise EVdbPageStore.Create('kopya: hedefe tasinamadi: ' + DestPath);
    if dir <> '' then
      VDbFlushDir(dir);
  except
    if FileExists(tmp) then SysUtils.DeleteFile(tmp);
    raise;
  end;
end;

procedure TVdbPageStore.CopyBaseImageTo(const DestPath: string);
var
  tmp, dir: string;
  fs: TFileStream;
  buf: array[0..65535] of Byte;
  left: Int64;
  n: Integer;
begin
  if FStream = nil then
    raise EVdbPageStore.Create('depolama acik degil (CopyBaseImageTo)');
  if DestPath = '' then
    raise EVdbPageStore.Create('CopyBaseImageTo: hedef yol bos');
  dir := ExtractFileDir(DestPath);
  if dir <> '' then ForceDirectories(dir);
  { v3.18: gecici ad SÜREÇ benzersiz olmali (bkz. CopyCommittedTo). }
  tmp := DestPath + '.' + VDbProcessToken + '.tmp';
  if FileExists(tmp) then SysUtils.DeleteFile(tmp);
  fs := TFileStream.Create(tmp, fmCreate);
  try
    FStream.Position := 0;
    left := FPhysSize;
    while left > 0 do
    begin
      n := SizeOf(buf);
      if left < n then n := left;
      FStream.ReadBuffer(buf, n);
      fs.WriteBuffer(buf, n);
      Dec(left, n);
    end;
    VDbFlushStream(fs);
  finally
    fs.Free;
  end;
  try
    if FileExists(DestPath) then
      if not SysUtils.DeleteFile(DestPath) then
        raise EVdbPageStore.Create('taban kopyasi: eski hedef silinemedi: ' + DestPath);
    if not RenameFile(tmp, DestPath) then
      raise EVdbPageStore.Create('taban kopyasi: hedefe tasinamadi: ' + DestPath);
    if dir <> '' then
      VDbFlushDir(dir);
  except
    if FileExists(tmp) then SysUtils.DeleteFile(tmp);
    raise;
  end;
end;

procedure TVDbPageStore.InstallPage(PageNo: LongWord; P: PVdbPage;
  AViewOnly: Boolean);
var
  idx: Integer;
  buf: TVDbPageBuf;
  isNew: Boolean;
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
    if AViewOnly then
    begin
      { v3.31: kirli bayrak KORUNUR. Yeni sayfa (dosyada olmayan) isaretliyse
        ikinci bir imaj kurulumu onu silerse Checkpoint sayfayi atlar ve
        WAL budaninca sayfa kaybolur. Temiz cerceve temiz kalir. }
      FFrames[idx].TxnMark := 0;
    end
    else
    begin
      FFrames[idx].Dirty := True;
      { P-54: kirli cerceve listesine ekle (yalniz geciste). }
      if FFrames[idx].TxnMark <> FTxnId then
      begin
        FFrames[idx].TxnMark := FTxnId;
        if FTxnDirtyCount >= Length(FTxnDirty) then
          SetLength(FTxnDirty, FTxnDirtyCount * 2 + 8);
        FTxnDirty[FTxnDirtyCount] := idx;
        Inc(FTxnDirtyCount);
      end;
    end;
    Exit;
  end;
  isNew := PageNo >= FPageCount;
  if isNew then
  begin
    FPageCount := PageNo + 1;
    { Tazelemede disk buyutmesi yapilmaz (paylasimli kilit altinda yazma
      EWriteError uretir). Mantiksal sayfa sayisi artar; fiziksel buyume
      bir sonraki Flush'te GrowTo ile olur. }
    if not AViewOnly then
      GrowTo(RequiredFileSize(FPageCount));
    FMetaDirty := True;
    FStructDirty := True;
  end;
  if PageNo = VDB_HDR_PAGE then
  begin
    if AViewOnly then
    begin
      { Meta imaji yalnizca onbellege kurulur ve mantiksal alanlar
        tazelenir; diske yazilmaz. }
      Move(P^, buf, VDB_PAGE_SIZE);
      Move(buf[12], FPageCount, 4);
      Move(buf[16], FFreeTrunk, 4);
      Move(buf[20], FFreeCount, 4);
      Move(buf[24], FLSN, 4);
      Exit;
    end;
    { Meta sayfa her zaman DUZ metindir (sir tutmaz, sifreleme zarfi yok). }
    FStream.Position := 0;
    FStream.WriteBuffer(P^, VDB_PAGE_SIZE);
    LoadMeta;
    Exit;
  end;
  if AViewOnly then
  begin
    { Tazeleme: yalnizca onbellege kur. Imaj WAL'de fsync'li; diskteki surum
      yazarin commit'inde guncellenir.
      v3.31 DIZELTME (pcbench P=4 acilis taramasi catlamasi): YENI sayfa
      (sayfa no >= sayfa sayisi) dosyada YOKTUR — icerik yalniz WAL'dedir.
      TEMIZ isaretlenirse sonraki Checkpoint onu yazmadan WAL'i budar ve
      sayfa sifir kalir (meta sayfa sayisi arttigi icin acilista "taninmiyor"
      ya da "okunamadi" hatasi). Bu yuzden yalnizca YENI sayfalar KIRLI
      isaretlenir; guncelleme durumunda dosyada zaten bir surum vardir ve
      yazan surec kendi imajini yazar. }
    LoadFrame(PageNo, P);
    if isNew then
    begin
      idx := FindFrame(PageNo);
      if idx >= 0 then
      begin
        FFrames[idx].Dirty := True;
        FFrames[idx].TxnMark := 0;
      end;
    end;
    Exit;
  end;
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
