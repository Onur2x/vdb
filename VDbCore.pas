unit VDbCore;

{ V1: append-only UInt64 -> Bytes motoru. DLL yok, saf FPC.
  Format (little-endian, packed):
    magic:u32=$56444231  crc:u32  seq:u64  key:u64  vallen:u32  flags:u8
    + value[vallen]
  crc = CRC32(seq + key + vallen + flags + value)
  flags: 0=put, 1=del
  Crash kurali: sadece dosya sonu yirtik olabilir, acilista truncate edilir.
}

{$mode delphi}

interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections, VDbErr,
  VDbTypes, DateUtils;

const
  VDB_MAGIC = $56444231;
  // 2026-10-05: WAL baslik imzasi artik interface'te (VDbCdc /
  // VDbTimeTravel ayni bicimde okusun diye). Once implementation'da idi.
  VDB_WAL_MAGIC = $57414C52;   // 'WALR'
  VDB_FLAG_PUT = 0;
  VDB_FLAG_DEL = 1;
  // Batch commit isareti: bu bayrakli kayit yazilmadan onceki batch
  // kayitlari UYGULANMAZ (recovery'de geri sarilir). Boylece COMMIT
  // gercekten atomik olur: ya hepsi gecerli, ya hicbiri.
  VDB_FLAG_BATCHEND = 2;
  VDB_FLAG_ENCRYPTED = 4;   // Faz D: Encryption (AES)
  VDB_FLAG_COMPRESSED = 8;  // Faz D: Compression (ZLIB)
  { H5 (2026-10-20): blok-grup CRC. Bir blok, pes pese kayitlarin
    baytlarini kapsar; blok sonunda Key=blok baslangic offseti, ValLen=0,
    Crc=CRC32(blok baytlari) olan bir footer kaydi yazilir. Footer
    kendisi CRC'ye DAHIL DEGILDIR. Kayit-bazi CRC geriye uyumluluk
    ve rastgele erisim icin korunur; Verify hizli yolda blok CRC'sini
    kullanir. }
  VDB_FLAG_BLOCKCRC = 16;
  VDB_BLOCK_TARGET = 1024 * 1024;   // ~1 MB'lik blok gruplari
  VDB_MAX_VALUE = 16 * 1024 * 1024;
  // P-19w: bu boyuta kadar header+deger TEK WriteBuffer ile yazilir
  // (3 syscall -> 2). Uzerinde ESKI yol birebir calisir (buyuk bloblar
  // icin gecici birlesik kopya ayirmamak icin).
  VDB_COMBINE_MAX = 64 * 1024;
  // P-21: COMMIT toplu yazim tamponu esigi. CommitBatch bekleyen kayitlari
  // bu boyuta kadar biriktirip TEK WriteBuffer ile bosaltir (kayit basina
  // syscall yerine ~blok basina). Diskteki bayt akisi birebir aynidir.
  VDB_WRBUF_MAX = 1024 * 1024;

  // Dosya kimligi: her .odb 'VODB'(LE) + surum + bayrak + baslik CRC ile baslar.
  // Kayitlar hep VDB_HDR_SIZE sonrasinda. Ham kayit akisiyla karismaz.
  VDB_FILE_MAGIC = $42444F56; // 'VODB' little-endian
  // SURUM 2: Flags=2 (BATCHEND) eklendi. Daha onceki surum (1) bu bayragi
  // bilmez; Recovery'de "bozuk kayit" sanip dosyayi kirpar -- yani commit
  // edilmis veri SILINIR. Bu yuzden surum yukseltildi: eski surumlu build
  // surumu okuyamayinca dosyayi ACAMAZ (temiz hata) ama KIRPMAZ.
  // V1 dosyalar acildiginda V2'ye yukseltilir (bkz. DetectFormat).
  // SURUM 3 (H5): blok-grup CRC footer'lari eklendi. Kayit duzeni ayni;
  // V1/V2 dosyalari acilirken V3'e yukseltilir. Eski build'ler V3'u
  // acamaz (temiz hata) ama dosyayi KIRPMAZ.
  VDB_FILE_VER = 3;
  VDB_FILE_VER_OLD = 1;
  VDB_FILE_VER_V2 = 2;
  VDB_HDR_SIZE = 16;
  VDB_HFLAG_HAS_ENCRYPTED = 1;
  { H3 (2026-10-18): zone map / atlanabilir offset bolumu geometrisi.
    ScanRawIter PAS B/C ile BIREBIR ayni olmali. }
  VDB_RAW_SCAN_SHIFT = 21;         // 2 MB
  VDB_RAW_SCAN_MAX_BUCKET = 8192;

type
  TQWordArray = array of QWord;
  TValArray = array of TBytes;
  { M11: depolama motoru DIKISI. Yalnizca temel KV islemleri bu arayuzde;
    transaction, WAL, indeks ve sifreleme TVDb'de kalir. Amac, ileride
    sayfa tabanli ikinci bir backend'in ust katmani degistirmeden
    denenebilmesi. Bugun TVDbKvStore bunu TVDb'ye delege eder. }
  IVDbKvStore = interface
    ['{6D8B2E71-4C1A-4F6E-9E3B-7A5C0D2F1A44}']
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer);
  end;
  { R-26 (2026-10-15): satirin icindeki TABLO ID'yi cozucu.
    KV katmani satir bicimini BILMEZ; cozucuyu VDbTable saglar ve TVDb
    icin atar. Boylece Recover, zaten CRC icin okudugu degerden tablo
    id'yi bedava cikarir.
      >= 0 : bu kayit o tabloya ait satir
      -1   : satir degil (semaya benzer ozel kayit) -> filtre uygulanmaz }
  TVDbRowTagFunc = function(const PlainValue: TBytes; ValueLen: Integer): Integer;
  { P-18a (2026-10-16): ScanRawIter geri cagrisi. Buf, motorun ic tamponuna
    (bucket chunk'i) isaret eder — YALNIZ cagri sirasinda gecerlidir,
    saklanmamali/kopyalamadan kullanilmalidir. Return False => tarama
    derhal durdurulur (ScanRawIter False doner). EN: zero-copy raw scan
    callback; buffer valid only during the call. }
  TVDbRawCb = function(Key: QWord; Buf: PByte; Len: Integer;
    User: Pointer): Boolean;

  { H6 (2026-10-18): PARALEL TARAMA icin ONCEDEN HAZIRLANMIS aday kumesi.
    PrepareRawScan adaylari BIR KEZ toplar ve offset bucket'larina gore
    gruplar; isci basina yalnizca kendi aday araligi [CandLo, CandHi)
    taranir. Boylece isci basina FIndex dolasimi (O(n)) YAPILMAZ — paralel
    hizin sarti budur. Kayitlar bucket-major dizilir; ayni bucket icinde
    sira onemsizdir (tarama bucket basina min/max span okur). }
  TVDbRawPrepared = record
    FSize: Int64;
    BucketShift: Integer;
    BCount: Integer;
    BucketStart: array of Integer;   // BCount+1 (kumulatif)
    CandOff: array of Int64;
    CandSize: array of LongWord;
    CandKey: array of QWord;
    { H6: istege bagli SALT-OKUNUR esleme. Dolu ise isciler kayitlari
      haritadan OKUR (paylasimli, syscall yok); bos ise konumsal okuma. }
    MapBase: PByte;
    MapLen: Int64;
    MapHandle: THandle;
    MapView: Pointer;
  end;

  TDbLoc = record
    Offset: Int64;
    Size: LongWord;
    Seq: QWord;
    { 2026-10-05: kaydin KENDI bayragi. Compact/BackupTo ham (sifreli)
      baytlari kopyaladigi icin bayragi da KORUMALIDIR; sabit
      VDB_FLAG_PUT yazmak sifreli kaydi duz metne cevirirdi. }
    Flags: Byte;
    { R-26: satirin tablo id'si. Recover zaten her kaydin TAM degerini
      CRC icin okudugundan bu alan bedava dolar. Bir tablo taramasi,
      DIGER tablolarin kayitlarini dosyadan OKUMADAN eleyebilir
      (eski hali: butun KV okunup decode edilirdi -> baska tablo
      boyutuyla orantili gereksiz masraf).
      -1 = bilinmiyor/satir degil -> tablo filtresi uygulanmaz. }
    TableId: Integer;
  end;

  TPendOp = record
    Key: QWord;
    Value: TBytes;
    IsDel: Boolean;
  end;

  TVDbRecHead = packed record
    Magic: LongWord;
    Crc: LongWord;
    Seq: QWord;
    Key: QWord;
    ValLen: LongWord;
    Flags: Byte;
  end;

  { H12 (2026-10-18): sinirli blok onbellegi icin slot. Blk = -1 -> bos.
    Data, dosyadaki FCacheBlock baytin BIREBIR kopyasidir (ham baytlar;
    sifre cozumu/CRC bu katmanda yapilmaz -> bayt-icerikten bagimsiz). }
  TVDbCacheSlot = record
    Blk: Int64;      // blok numarasi (offset div FCacheBlock)
    Ref: Boolean;    // CLOCK referans biti
    Data: TBytes;    // FCacheBlock bayt (dosyadan birebir)
  end;

  { 2026-10-05: WAL kayit basligi ARTIK INTERFACE'TE.
    ONCEDEN yalnizca implementation icinde tanimliyd; boylece dis
    birimler (VDbCdc / VDbTimeTravel) .wal dosyasini YANLIS bicimde
    okuyordu (TVDbRecHead saniliyordu). Her kayit kendi magic +
    CRC'sini tasiyor; bozuk/yirtik kuyruk okuyan tarafca GORULMEZ. }
  { R-16 (2026-10-12): LSN ve zaman damgasi EKLENDI.
    Onceki bicim (21 bayt): Magic/Key/Flags/ValLen/Crc.
    LSN, RecCrc'in `Seq` parametresi olarak kullanilir; boylece CRC
    hem LSN'i hem de zaman damgasini KAPSAR (LSN'i olan bir kaydin
    zaman damgasi degistirilirse CRC kirilir).
    NOT: eski .wal dosyalari bu boyutta okunamaz; gecersiz kayit
    gibi gorunur ve replay orada kesilir (veri bozulmaz, yalnizca
    eski WAL atilir). .wal gecici dosyadir. }
  TVDbWalHead = packed record
    Magic: LongWord;      // VDB_WAL_MAGIC
    Key: QWord;
    Flags: Byte;          // VDB_FLAG_PUT | VDB_FLAG_DEL (duz bayrak)
    ValLen: LongWord;
    Crc: LongWord;        // RecCrcWal(LSN, WalStamp, Key, ValLen, Flags, Value)
    LSN: QWord;           // R-16: artan gunluk dizin numarasi
    WalStamp: QWord;      // R-16: Unix milisaniye (PITR hedefi)
  end;

  TVDbFileHead = packed record
    Magic: LongWord; // VDB_FILE_MAGIC
    Ver: LongWord;   // VDB_FILE_VER
    Flags: LongWord; // 0
    Crc: LongWord;   // ilk 12 byte'in CRC32'si
  end;

  { R-11: COMMIT oncesi calisacak geri-cagirim tipi. Bir METOT adresi
    tutuldugu icin duz TProcedure degil, `procedure of object` olmali.
    TVTableDb kendi deferrable-kisit denetimini bu kanca ile VDb'ye
    baglar (bkz. TVTableDb.Open). }
  TDbCommitHook = procedure of object;

  TVDb = class
  private
    FDir: string;
FPath: string;
    FS: TFileStream;
    FLock: TCriticalSection;
    FIndex: TDictionary<QWord, TDbLoc>;
    { KR-1: tablo basina ANAHTAR DIZINI (turev onbellek). Yalnizca tarama
      hizlandirmasi icindir; TEK kaynagi FIndex'tir ve asla bagimsiz
      guncellenmez. FIndex her degistiginde FTableKeysDirty kurulur;
      filtreli bir tarama once bu dizini FIndex'ten yeniden kurar (O(N)),
      sonra YALNIZCA hedef tablonun anahtarlarini dolasir. Boylece karisik
      veritabanlarinda her tarama icin tum tablolarin anahtarlari
      dolasilmaz. Anahtar -1 = "etiketsiz" kayitlar (sema kaydi); R-26
      davranisi geregi her tablo taramasinda elenmez. }
    FTableKeys: TDictionary<Integer, TList<QWord>>;
    FTableKeysDirty: Boolean;
    { KR-1B: COUNT(*) O(1) sonucu ONEMLI: bu sozluk FIndex'ten DEGIL, dogrulanmis
      bir COUNT taramasinin (stream-agg) sonucundan beslenir -- boylece recover/
      reopen sonrasi FIndex kayitlarinin etiketsiz (-1) kalmasi sayimi etkilemez.
      Herhangi bir yazma (AppendRec/recover/restore) TUM cache'i gecerli kilmadiyi
      siler (Clear). Okuma-agirlikli ise tablo-bazinda O(1); yazma sonrasi ilk
      COUNT yeniden sayar. Yalniz autocommit'te kullanilir (acik batch gorunurlugu
      cache'e yansimaz). }
    FTableRowCount: TDictionary<Integer, Int64>;
    { R-26: satir bicimi cozucusu. VDbTable olustururken atar; nil ise
      (ham KV kullanimi) tablo id'leri -1 kalir ve filtre uygulanmaz. }
    FRowTagFunc: TVDbRowTagFunc;
    FSeq: QWord;
    { H3: FIndex TAM guncellendikten SONRA artan surum. Zone map anahtari
      bunu kullanir; yarim kalmis (FSeq artmis ama FIndex'e yazilmamis)
      bir yazma yuzunden bayat haritanin "gecerli" sanilmasi imkansizdir. }
    FIdxVer: QWord;
    { H3: dosya fiziksel olarak yeniden yazildiginda (Compact/Restore/Rekey)
      artar; zone map gecerliligi (FDataEpoch, FSeq) ciftiyle denetlenir. }
    FDataEpoch: QWord;
    FSyncWrite: Boolean;
    // GROUP COMMIT: SyncWrite=True iken bile, fsync'ler bu sure (ms)
    // icinde toplanir. 0 = her yazmada fsync (eski davranis). Varsayilan
    // 0; uygulama isterse 1..10 gibi degerler vererek 10-100x hizlanma
    // saglayabilir (PostgreSQL commit_delay benzeri).
    FSyncWriteInterval: Integer;
    FSyncWriteLast: QWord;   // son fsync zaman damgasi (GetTickCount64)
    FInBatch: Boolean;
    { F-42: acik batch'in sahibi oturum. 0 = ham TVDb API (eski global
      davranis). Baska bir oturum batch sahibi iken yazma reddedilir ve
      okuma yalnizca commit edilmis gorunumu gorur. }
    FBatchOwner: Cardinal;
    { F-42: oturumlararasi seri calisma kapisi. Bir SQL oturumu acik
      transaction tutarken diger SQL oturumlari cumle basinda burada
      bekler. Boylece henuz commit edilmemis indeks/sema degisiklikleri
      baska oturuma sizmaz; kapi FT.Lock'tan ONCE alinir. }
    FGateLock: TCriticalSection;
    FGateEvent: TEvent;
    FGateOpen: Boolean;
    FGateOwner: Cardinal;
    // MVCC / Snapshot Isolation (R-01):
    // FSnapshotSeq: transaction-level snapshot sequence (BeginBatch'ta FSeq+1).
    // Okuma gorunurlugu: Loc.Seq <= SnapshotSeq.
    FSnapshotSeq: QWord;
    FSnapshotDepth: Integer; // nested SELECT (correlated subquery) tarama derinligi
    // P-DUR: fsync'lenmemis yazma var mi? AppendRec/AppendBatchEnd kurar,
    // Flush ve CommitBatch temizler. TVSql.Exec basarili yazma sonrasi
    // kirliyse Flush cagirir -> SQL katmaninda SyncWrite ayarindan bagimsiz
    // commit garantisi (salt-okunur sorgularda syscall yok).
    FDirty: Boolean;
    { P-21 (2026-10-16): COMMIT TOPLU YAZIM TAMPONU. CommitBatch icinde
      AppendRec kayit baytlarini (baslik+deger) dogrudan dosyaya yazmak
      yerine bu tampona biriktirir; esik asilinca TEK WriteBuffer ile
      dosyaya bosaltilir. Diskteki bayt akisi BIREBIR aynidir: ayni
      baytlar, ayni sira, ayni offset (FWrBufBase + tampondaki konum).
      Yalniz syscall sayisi duser. Tampon YALNIZCA FLock altinda ve
      CommitBatch suresince aktiftir; baska her yerde FWrBufActive=False
      -> ESKI yol birebir. FlushWriteBuf dosya sonu ile FWrBufBase
      uyusmazsa yazar DEGIL, GORUNUR hata verir (sessiz bozulma yok). }
    FWrBuf: TBytes;
    FWrBufLen: Integer;
    FWrBufBase: Int64;
    FWrBufActive: Boolean;
    { H5: acik blok grubunun baslangici, bayt sayisi ve kumulatif CRC'si.
      Blok kapaninca footer yazilir; sayaclar sifirlanir. }
    FBlockStart: Int64;
    FBlockBytes: Int64;
    FBlockCrc: LongWord;
    // Bekleyen (batch ici) yazmalar.
    //
    // FPending   : yazma sirasiyla islenen op listesi
    // FPendingIdx: key -> op'in bulundugu slot (O(1) okuma icin)
    // FPutSeen   : bu batch icinde EN AZ BIR KEZ yazilmis anahtarlar.
    //              Put icindeki "eski op'i kaldir" taramasi yalnizca
    //              anahtar batch icinde daha once gorulduyse gerekir
    //              (yoksa silinecek op yoktur). Bu sayede toplu yukleme
    //              O(n^2) yerine O(n) olur ve DAVRANIS BIT BIT AYNIDIR.
    FPending: TList<TPendOp>;
    FPendingPuts: TDictionary<QWord, Byte>;
    FPendingDels: TDictionary<QWord, Byte>;
    FPendingIdx: TDictionary<QWord, Integer>; // key -> op indeksi (O(1))
    FPutSeen: TDictionary<QWord, Byte>;       // batch icinde yazilmis key'ler
    FClosed: Boolean;
    FDataStart: Int64;
    FLcked: Boolean;
    FRestored: Boolean;
  // F2-2: dizin (dosya adi) girdisi fsync edilemedi. Veri dosyasi
  // duruyor ama crash sonrasi dosya adi kaybolabilir.
  FDirSyncFailed: Boolean;
    FNewFile: Boolean;
    FDeadBytes: Int64;
    { H12 (2026-10-18): SUNUCU TARAFLI SINIRLI BLOK ONBELLEGI. GetSnapshot
      noktasal okumalari kayit basina bir ReadFile yapiyordu; ayni 8 KB
      bloga dusen TEKRARLI okumalar (indeks probe / JOIN) icin blok bazinda
      onbellek. Salt-okunur yol; diskt/formati DEGISTIRMEZ. Guvenlik: yalnizca
      dosyadan TAM bir blok (FCacheBlock bayt) okunabildiyse onbelleklenir;
      dosya append-only oldugundan bu blok bir daha DEGISMEZ (kismi son blok
      onbelleklenmez). Recover/Compact/yerinde baslik yazimi veya commit
      hata-sarma (truncate) onbellegi temizler. FCacheMaxBlocks = 0 -> kapali. }
    FCacheLock: TCriticalSection;
    FCacheSlots: array of TVDbCacheSlot;
    FCacheMap: TDictionary<Int64, Integer>;   // blok no -> slot indeksi (O(1))
    FCacheHand: Integer;          // CLOCK eli
    FCacheBlock: Integer;         // blok boyutu (bayt)
    FCacheHits: Int64;
    FCacheMisses: Int64;
    FCacheMaxBlocks: Integer;     // kapasite (blok sayisi); 0 = kapali
    { H4 (2026-10-18): mmap okuma yolu anahtari. OLCUM: sicak onbellekte
      tarama basina esleme kurma + yumusak sayfa hatasi (4 KB'da bir)
      maliyeti, ReadFile'in tek syscall + yeniden kullanilan tampon
      kopyasindan DAHA YAVAS (6,5 MB tarama: 11,3 -> 17,3 ms). Taramalar
      kayit-basi CPU'ya bagli oldugundan mmap varsayilan KAPALI; istege
      bagli deneysel yol olarak durur. }
    FReadMapEnabled: Boolean;
    { H4: basariyla acilan okuma-eslemesi sayisi (tanilama/olcum). }
    FMmapOpens: Int64;
    { 2026-10-04: OTOMATIK WAL. True iken her kalici yazma once .wal'a
      yazilir, sonra ana dosyaya. Eski davranis (yalniz elle
      WriteAheadWAL) varsayilandir; bu yuzden mevcut kullanicilarin
      davranisi DEGILMEZ. }
    FWALEnabled: Boolean;
    FWALAutoCount: Integer;
    { ReplayWAL cagrisinda kullaniciyi uyarmak icin: acik miydi? }
    FWALWasEnabled: Boolean;
    { R-16 (2026-10-12): bir sonraki WAL kaydinin LSN'i. Segment
      rotasyonu ve PITR bu sayacla calisir. }
    FWalLSN: QWord;
    { R-16: WAL arsiv dizini. Bos ise arsivleme KAPALI.
      Segmentler <dir>/<dbadi>_NNNNNNNN.wal olarak yazilir. }
    FArchiveDir: string;
    { R-16: mevcut segmentin karektan sonra ne zaman arsivlenecegi
      (bayt). 0 ise segment limiti yok, yalnizca BACKUP arsivler. }
    FWalSegmentMax: Int64;
    { 2026-10-05 KAYIT SEVIYESI SIFRELEME. FEncKey bos ise sifreleme
      KAPALI (geriye donuk uyum). Dolu ise her Put degeri
      VDB_FLAG_ENCRYPTED ile AES-256-CTR + HMAC-SHA256 ile saklanir.
      SILME kayitlari (tombstone) SIFRELENMEZ: icerik yok. }
    FEncKey: TBytes;
    { Basliktaki Flags alaninin bit 0'i: dosyada en az bir sifreli kayit var.
      Open without anahtar ile dosyanin 'sifreli' oldugu bilinsin diye. }
    FEncFlags: LongWord;
    { M6: kolon seviyesi sifrelemede kullanilan anahtar kimligi. 0 ise
      bu veritabaninda henuz kolon anahtari yok. Anahtarin kendisi
      <db>.colkey dosyasindan yuklenir; burada yalnizca kimlik tutulur. }
    FColKeyId: QWord;
    procedure TxnGateOpen(AOwner: Cardinal);
    procedure TxnGateClose;
    function BatchIsMine: Boolean;
    { F-42: acik batch baska oturuma aitse yazma reddedilir. Boylece
      ikinci oturumun yazmasi sessizce birinci oturumun transaction'ina
      katilmaz. }
    procedure RequireBatchWrite;
    function EncryptValue(const Value: TBytes; out Cipher: TBytes): Boolean;
    function DecryptValue(const Cipher: TBytes; out Plain: TBytes): Boolean;
    procedure CheckOpen;
    function RecCrc(Seq, Key: QWord; ValLen: LongWord; Flags: Byte; Value: PByte): LongWord;
    { R-16: WAL kaydi CRC'si. Ana dosya kayitlarinda kullanilan
      RecCrc'den AYRI: zaman damgasini da kapsar, boylece arsivlenen
      bir segmentin zaman bilgisi sonradan degistirilemez. }
    function RecCrcWal(LSN, Stamp, Key: QWord; ValLen: LongWord;
      Flags: Byte; Value: PByte): LongWord;
    function HeadCrc(const H: TVDbFileHead): LongWord;
    procedure WriteHeaderTo(S: TStream);
    procedure DetectFormat;
    procedure MigrateLegacy;
    procedure ReplaceWith(const TmpPath: string);
    { SkipWAL=True yalnizca Recover tarafindan kullanilir: kendi
      kayitlarini .wal'a yazmasin (yoksa dongu). }
    procedure AppendRec(Key: QWord; const Value: TBytes; IsDel: Boolean;
      DoFlush: Boolean; SkipWAL: Boolean = False);
    { H5: blok CRC'sine bir kaydin yazilan baytlarini ekler. }
    procedure BlockCrcAdd(const H: TVDbRecHead; Value: PByte);
    { H5: acik blogu footer ile kapatir. Blok bossa no-op. }
    procedure AppendBlockFooter;
    { P-21: aktif toplu yazim tamponunu (varsa) dosyaya bosaltir ve
      tamponu sifirlar. FWrBufActive=False veya tampon bos ise no-op. }
    procedure FlushWriteBuf;
    { WriteAheadWAL'in kilit ALMAYAN cekirdegi. AppendRec bunu cagirir;
      kilit zaten AppendRec'de tutuluyor, yeniden almak deadlock yapar. }
    function WriteAheadWALCore(Key: QWord; const Value: TBytes;
      Flags: Byte): Boolean;
    procedure SetWALEnabled(AValue: Boolean);
    procedure AppendBatchEnd(DoFlush: Boolean);
    procedure AppendBatchEndTo(S: TStream; ASeq: QWord);
    procedure Recover;
    { KR-1: tablo anahtar dizinini temizler / FIndex'ten yeniden kurar. }
    procedure ClearTableKeys;
    procedure RebuildTableKeys;
    procedure SetRowTagFunc(AValue: TVDbRowTagFunc);
    function FindPending(Key: QWord; out Op: TPendOp): Boolean;
    procedure PendingAdd(const Op: TPendOp);
    procedure PendingRemove(const Idx: Integer);
    procedure PendingClear;
    function PendingCount: Integer;
    { H12: blok onbellegi ic yardimcilari (bkz. FCache* alanlari). }
    function CacheGetBlock(Blk: Int64; out Data: TBytes): Boolean;
    function CacheFill(Offset: Int64; Need: Integer; Dest: PByte): Boolean;
    procedure CacheInvalidateAt(Offset: Int64; Len: Integer);
    { ---------------------------------------------------------------
      SAVEPOINT / Nested Transaction (R-02)
      Her savepoint: Seq, PendingCount, FIndex kopyasi (referans sayacli).
      RollbackTo savepoint: pending op'lari geri al, FIndex'i restore et.
      --------------------------------------------------------------- }
    type
      TSavepoint = record
        Name: string;
        Seq: QWord;
        PendingCount: Integer;
        IndexSnapshot: TDictionary<QWord, TDbLoc>; // FIndex kopyasi
        Dirty: Boolean;
      end;
    var
      FSavepoints: TList<TSavepoint>;
    { ---------------------------------------------------------------
      MVCC / Snapshot Isolation (R-01)
      Gorunurluk kurali: kayit gorunur ise Loc.Seq <= SnapshotSeq.
      Tombstone (DEL) de Seq tasirir; Seq <= SnapshotSeq ise silinmis
      sayilir (GetSnapshot False doner).
      --------------------------------------------------------------- }
    function IsVisible(const Loc: TDbLoc; SnapshotSeq: QWord): Boolean;
private
    { R-11: COMMIT oncesi calisacak geri-cagirim (deferrable kisit
      denetimi). TVTableDB kendi denetimini buraya baglar. }
    FBeforeCommit: TDbCommitHook;
    { R-16: WAL arsivleme yardimcilari. }
    function BaseName: string;
    function ArchivePathFor(ASegment: Int64): string;
    procedure EnsureArchiveDir;
    function NextSegmentNo: Int64;
    function CurrentWalSize: Int64;
    function ArchiveBytes(ASegment: Int64): Int64;
    function CopyFileRaw(const ASrc, ADst: string): Boolean;
    function SetArchiveDirCore(const ADir: string): string;
    procedure EnsureArchiveDirHelper(const ADir: string);
    { Bir arsiv segmentindeki gecerli kayitlari sayar. Bozuk kayitta
      DURUR. }
    function CountSegmentValid(APath: string): Integer;
    { Bir arsiv segmentini UYGULAR (ana dosyaya tek batch).
      AStopStamp > 0 ise yalnizca o damgadan kucuk kayitlar uygulanir
      ve ilk boyle bir kayitta dongu KIRILIR (zaman sirali oldugu icin
      sonrakiler de hedefi asar). Doner: uygulanan kayit sayisi. }
    function ApplySegment(APath: string; AStopStamp: QWord;
      AUseBatch: Boolean): Integer;

  public
    { R-02 SAVEPOINT: bunlar ONCEDEN private idi; TVTableDB kendi
      Savepoint/Release/Rollback delegasyonlarinda FKv.Savepoint(...)`
      cagiriyordu -> "no member Savepoint". Disaridan cagrilabilmeleri
      icin public'a tasindi. }
    procedure Savepoint(const AName: string);
    procedure ReleaseSavepoint(const AName: string);
    procedure RollbackToSavepoint(const AName: string);
    procedure ClearSavepoints;
    constructor Create;
    destructor Destroy; override;
    procedure Open(const Dir: string);
    procedure Close;
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Exists(Key: QWord): Boolean;
    function Delete(Key: QWord): Boolean;
    procedure BeginBatch;
    { F-40: READ COMMITTED icin her cumle basinda gorunurluk penceresini
      ilerletir. Yalnizca acik batch icinde etkilidir; bekleyen yazmalar
      (bu oturumun) gorunmeye devam eder. }
    procedure RefreshBatchSnapshot;
    procedure CommitBatch;
    procedure AbortBatch; // NOT: tablo indexleri onarilmaz, TVTableDb.AbortBatch kullan
    { F-42: baska bir SQL oturumunun acik transaction'i varsa, o bitene
      kadar bekler. TVSql.Exec/ExecAll tarafindan FT.Lock'tan ONCE
      cagrilir; boylece kilitlenme olmaz. ASessionId=0 (ham API/ic
      is parcaci) beklemez. }
    procedure WaitForeignTxn(ASessionId: Cardinal);
    procedure Flush;
    function Count: Integer;
    { KR-1B: COUNT(*) O(1). Tablonun daha once DOGRULANMIS canli satir sayisi
      cache'te duruyorsa True+deger dondurur; cache yoksa/gecersizse False
      (cagiran dogrulamali taramayi yapip SetTableRowCount ile doldurur).
      CAGIRAN SARTI: autocommit olmali (acik batch gorunurlugu cache'e
      yansimaz). Cache her yazmada Clear edilir; boylece tek bir gecersiz
      deger bile kalmaz. }
    function TryGetTableRowCount(TableId: Integer; out Value: Int64): Boolean;
    { KR-1B: dogrulanmis COUNT degerini cache'e yazar (autocommit'ten emin
      cagiran tarafi). Coksayili COUNT(*) ayni degeri yazar -- zararsiz. }
    procedure SetTableRowCount(TableId: Integer; Value: Int64);
    function GetAllKeys: TQWordArray;
    { R-26: TableFilter >= 0 ise yalnizca o tabloya ait satirlar okunur;
      diger tablolarin kayitlari DOSYADAN OKUNMAZ (gorev oncesi
      FIndex'teki TableId ile elenir). -1 = filtre yok (eski davranis). }
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer = -1);
    { P-18a (2026-10-16): ScanSnapshot'in SIFIR-KOPYA surumu. Faz A/B/C
      ScanSnapshot ile birebir (gorunurluk, tombstone, R-26 filtresi,
      bucket toplu okuma, bozuk-kayit sessiz atlama, sifre cozme); tek
      fark: kayit basina TBytes/Keys/Vals ayirilmaz, chunk icindeki
      tampon Cb'ye (PByte+Len) olarak verilir. Limit desteklenmez
      (agregalar kullanmaz); siralama bucket sirasidir — agregada
      siparis bagimsizdir. SnapshotSeq secimini cagiran yapar (bkz.
      ScanRawIterAll). Kilitsizdir; ScanSnapshot ile ayni kosullarda. }
    function ScanRawIter(SnapshotSeq: QWord; TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer;
      OffLo: Int64 = 0; OffHi: Int64 = High(Int64);
      SkipBuckets: PByte = nil; SkipLen: Integer = 0;
      CurBucket: PInteger = nil): Boolean;
    function ScanRawIterAll(TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer): Boolean;
    { H6 (2026-10-18): ScanRawIterAll'in [OffLo, OffHi) offset araligina
      kirpilmis hali. Aday KAYIT BASLANGICI bu aralikta olanlar islenir;
      boylece [0, DataFileSize) N parcaya bolunup N isciye dagitilabilir
      (her kayit TAM BIR kez). Sonuc offset parcalarina gore degismez. }
    function ScanRawIterAllRange(TableFilter: Integer; OffLo, OffHi: Int64;
      Cb: TVDbRawCb; User: Pointer): Boolean;
    { H6: veri dosyasinin o anki boyutu (paralel bolumleme siniri icin). }
    function DataFileSize: Int64;
    { H3 (2026-10-18): ZONE MAP icin tarama bolumleme sabiti. Bolum (bucket)
      indeksi = offset shr VDB_RAW_SCAN_SHIFT; ust sinir VDB_RAW_SCAN_MAX_BUCKET.
      Cagiran (VDbExecutor) ayni geometriyi kullanarak bayt-dizi atlama
      haritasi uretir; boylece motor zone map mantigini BILMEZ. }
    function DataSeqValue: QWord;
    { H3: zone map bolum sayisi (ScanRawIter PAS B ile birebir ayni). }
    class function RawScanBucketCount(FileSize: Int64): Integer; static;
    { H3: dosya YENIDEN yazildiginda (Compact/Restore/Rekey) artan damga.
      Offset'ler degistigi icin zone map gecersizdir; (Seq, Epoch) cifti
      birlikte karsilastirilir. }
    function DataEpochValue: QWord;
    { H3: SkipBuckets[b] <> 0 ise o offset bolumu HIC OKUNMAZ. SkipLen,
      SkipBuckets uzunlugudur (dosya buyurse tasma olmaz). CurBucket nil
      degilse her bolum basinda oraya bolum indeksi yazilir (zone map
      insa eden cagiran icin). }
    function ScanRawIterAllZoned(TableFilter: Integer;
      SkipBuckets: PByte; SkipLen: Integer; CurBucket: PInteger;
      Cb: TVDbRawCb; User: Pointer): Boolean;
    { H6: tablo anahtar dizini kirliyse TEK KEZ yeniden kurar. Paralel
      tarama oncesi cagrilir; boylece N isci RebuildTableKeys'i yaris
      halinde cagirmaz. }
    procedure EnsureTableKeys;
    { H6: tablonun anahtar sayisi (paralel esik karari icin). Dizini
      gerekirse kurar; tablo yoksa 0 doner. }
    function TableKeyCount(TableId: Integer): Integer;
    { H6: aday kumesini BIR KEZ toplar (bkz. TVDbRawPrepared). Acik
      batch'te (pending op) False doner; cagiran seri yola duser. }
    function PrepareRawScan(TableFilter: Integer;
      out P: TVDbRawPrepared): Boolean;
    { H6: hazir aday kumesinin [CandLo, CandHi) araligini tarar.
      ScanRawIterAll ile ayni gorunurluk/baslik/sifre kurallari. }
    function ScanRawPrepared(const P: TVDbRawPrepared;
      CandLo, CandHi: Integer; Cb: TVDbRawCb; User: Pointer): Boolean;
    { H6: PrepareRawScan'in actigi eslemeyi birakir (esleme yoksa no-op). }
    procedure ReleasePreparedScan(var P: TVDbRawPrepared);
    { ScanAll'in secim kuraliyla birebir ayni snapshot secimi. }
    { R-26: satir bicimi cozucusu (bkz. TVDbRowTagFunc). VDbTable
      TVDb olustururken atar. }
    property RowTagFunc: TVDbRowTagFunc read FRowTagFunc write SetRowTagFunc;
    { ---------------------------------------------------------------
      MVCC / Snapshot Isolation (R-01) - Kilitsiz Okuma API
      --------------------------------------------------------------- }
    function GetSnapshot(Key: QWord; out Value: TBytes; SnapshotSeq: QWord): Boolean;
    function ExistsSnapshot(Key: QWord; SnapshotSeq: QWord): Boolean;
    procedure ScanSnapshot(out Keys: TQWordArray; out Vals: TValArray;
      SnapshotSeq: QWord; Limit: Integer = -1; TableFilter: Integer = -1);
    procedure Compact(out OldBytes, NewBytes: Int64);
    function AutoCompact(out OldBytes, NewBytes: Int64;
      MaxDeadRatio: Double = 0.3; MinBytes: Int64 = 65536): Boolean;
    function Verify(out Report: string): Boolean;
    function GetIsOpen: Boolean;
    { H12 (2026-10-18): sinirli blok onbellegi denetimi. BlockCount=0 kapatir.
      Varsayilan: ReadCacheDefaultBlocks (bkz. implementation). }
    procedure SetReadCacheBlocks(BlockCount: Integer);
    function ReadCacheBlocks: Integer;
    { H4 (2026-10-18): mmap okuma yolu anahtari (varsayilan KAPALI;
      olcumle kazanc gorulmedi, deneysel). }
    procedure SetReadMapEnabled(AValue: Boolean);
    function ReadMapEnabled: Boolean;
    { H4: simdiye kadar basariyla acilan okuma-eslemesi sayisi. }
    function ReadMapOpens: Int64;
    procedure ClearReadCache;
    procedure GetReadCacheStats(out Hits, Misses: Int64;
      out UsedBlocks, MaxBlocks: Integer);
    procedure BackupTo(const DestPath: string);
    { R-16: yedekten geri yukler. Mevcut .odb once
      <db>.pre-restore.bak olarak saklanir, boylece hatali bir
      RESTORE geri alinabilir. }
    function RestoreFrom(const SrcPath: string): Boolean;
    // 2026-10-05 Adim 15: parola rotasyonu (TAMAMEN izole: tmp+rename)
    procedure RekeyWithPassword(const NewPassword: string);
    // WAL Motor Entegrasyonu
    function WriteAheadWAL(Key: QWord; const Value: TBytes; Flags: Byte = VDB_FLAG_PUT): Boolean;
    function ReplayWAL: Boolean;
    function CheckpointWAL: Boolean;
    function HasWAL: Boolean;
    function WalRecordCount: Integer;
  // 2026-10-04: .wal dosya yolu (tek noktadan).
  function WalPath: string;
    { ---------------------------------------------------------------
      2026-10-05 WAL GECMISI OKUMA (CDC / Time Travel)

      AIndex: 0 tabanli kayit indeksi (0 .. WalRecordCount-1).
      Her okuma dosyayi bastan dogrular (magic/CRC/yirtik kuyruk);
      bozuk kayit sonrasi False doner. WAL yalnizca son checkpoint'ten
      sonraki gecmisi tutar -> "tarihin tamami" DEGILDIR (belgele). }
function ReadWalEntry(AIndex: Integer; out AKey: QWord;
    out AFlags: Byte; out AValue: TBytes): Boolean;
  { ----------------------------------------------------------------
  R-16 (2026-10-12): WAL ARSIVLEME + PITR
  ---------------------------------------------------------------- }
  { Arsivleme acik mi? }
  function ArchiveEnabled: Boolean;
  { Arsiv dizinini ac/kapat. Kapatma arsivlenen dosyalari SILMEZ
    (arsiv korunur, yalnizca yeni segment arsivlenmez). }
  procedure SetArchiveDir(const ADir: string);
  function GetArchiveDir: string;
  { Segment limiti (bayt). Ustu asilinca .wal arsive tasinir ve
    yeni bos segment baslar. 0 = limit yok (yalniz BACKUP arsivler). }
  procedure SetWalSegmentMax(AMax: Int64);
  function GetWalSegmentMax: Int64;
  { Mevcut .wal'i arsive tasir. Doner: segment no veya 0. }
  function MaybeRotateWal(Force: Boolean): Int64;
  { Arsiv segmentlerini kronolojik sirada listeler. }
  function ListWalArchive: TStrArray;
  { Arsivdeki tum segmentleri BIRLIKTE bu veritabanina UYGULAR.
    Bu, "son ana kadar" kurtarma (PITR). ATargetStamp > 0 ise yalnizca
    o zaman damgasindan KUCUK/EQUAL kayitlar uygulanir; boylece
    verilen ana kadar geri alinir.
    Bozuk segmentte DURUR, sonrakiler uygulanmaz.
    Doner: uygulanan kayit sayisi. }
  function RecoverFromArchive(ATargetStamp: QWord): Integer;
  { R-17: Streaming Replication - HARICI bir WAL segment dosyasini
    (standby inbox / primary arsivi) bu veritabanina uygular. Log
    shipping'in cekirdegi: segment yolu verilir, icindeki gecerli
    kayitlar ana dosyaya batch halinde yazilir. Doner: uygulanan
    kayit sayisi. Bozuk segmentte DURUR. }
  function ApplyWalSegmentFile(const APath: string): Integer;
  { Sonraki WAL kaydi icin kullanilacak zaman damgasi (Unix ms). }
  function NowUnixMS: QWord;
    { ----------------------------------------------------------------
      OTOMATIK WAL (2026-10-04)

      Sorun: WAL opt-in idi. Uygulama `Put`/`Delete` dogrudan ana
      dosyaya yaziyor, `WriteAheadWAL` yalniz elle cagriliyordu.
      Buyuk yuklemede (toplu INSERT) kullanici "WAL kullanacagim"
      dediginde her yazma icin iki cagri gerekiyordu; cagirmayi
      unutunca kayit yalnizce bellekte kalirdi.

      Cozum: `WALEnabled = True` iken HER kalici yazma once `.wal`a
      yazilir, SONRA ana dosyaya. Boylece:
        * cagri sirasinda crash olursa kayit `.wal`da durur ve
          sonraki `ReplayWAL` ile kurtarilir,
        * `WriteAheadWAL` elle cagrilmaya devam eder (cift yazim
          olmaz: elle cagri yapanlar otomatik modu kapatmali).

      ETKI ALANI: yalnizca kalici yazma yollarini sarar. `Get`,
      `Exists`, `Count`, sorgular ETKILENMEZ.

      DIKKAT (yol haritasi): otomatik WAL acikken `ReplayWAL`
      calistirmak kayitlari IKI KEZ uygular. Bu yuzden `ReplayWAL`
      otomatik modda uyarir ve kullanici onay ister.
      ------------------------------------------------------------- }
    property WALEnabled: Boolean read FWALEnabled write SetWALEnabled;
    { AutoWAL modunda yazilan kayit sayisi (yalnizca bilgi amacli). }
    function WalAutoCount: Integer;
  // R-03/R-04: UPSERT / RETURNING
  function InsertReturning(const Table: string; const ColNames, Values: TStrArray;
    out OutPk: string; out OutVals: TStrArray): Boolean;
  function UpsertRowReturning(const Table: string; const ColNames, Values: TStrArray;
    OnConflictAction: Integer; const OnConflictTarget: TStrArray;
    const SetValues: array of TUpdateAssignment;
    out OutPk: string; out OutVals: TStrArray): Boolean;
{ R-01 MVCC: motorun guncel sequence degeri. Okuma amacli; snapshot
  baslangicinda gorunurluk sinirini belirler (VDBTable snapshot icin
  bunu kullanir; FSeq private oldugu icin disaridan erisilemiyordu). }
property CurrentSeq: QWord read FSeq;
    property FilePath: string read FPath;
    property IsOpen: Boolean read GetIsOpen;
    property RestoredFromBak: Boolean read FRestored;
  // F2-2: dizin fsync basarisiz (Unix). True ise veri dosyada duruyor
  // ama dosya adi kalici degil; isletme bir uyari vermelidir.
  property DirSyncFailed: Boolean read FDirSyncFailed;
property DeadBytes: Int64 read FDeadBytes;
    property SyncWrite: Boolean read FSyncWrite write FSyncWrite;
    // GROUP COMMIT: SyncWrite=True iken fsync'ler bu sure (ms) icinde
    // toplanir. 0 = her yazmada fsync (varsayilan, eski davranis).
    // 10 = en fazla 10ms gecikme, ama ~10-100x hizlanma.
    property SyncWriteInterval: Integer read FSyncWriteInterval write FSyncWriteInterval;
    property InBatch: Boolean read FInBatch;
    // R-11: COMMIT oncesi geri-cagirim (deferrable kisit denetimi).
    // Metot adresi tutuldugu icin `procedure of object` tipindedir.
    procedure SetBeforeCommit(Proc: TDbCommitHook);
    // P-DUR: fsync bekleyen yazma var mi (ham API ile toplu yukleyenler
    // bitince Flush cagirir; SQL katmani kendisi halleder).
    property Dirty: Boolean read FDirty;

    { -------------------------------------------------------------
      2026-10-05 KAYIT SEVIYESI SIFRELEME

      Kullanim:
        db.SetEncryptionKey(anahtar);        // yazmalari sifrele
        db.CreateKeyFile('x.key','parola');   // anahtari dosyaya yaz
        db.OpenKeyFile('x.key','parola');     // anahtari dosyadan al
        db.ClearEncryptionKey;                // sifrelemeyi kapat

      ONEMLI - DUYARLILIK (mixed mode):
        Sifreleme AÇIKken yazilan kayitlar sifreli, KAPALIken yazilanlar
        duz metindir. `Get`/`ScanAll` bayraga bakip ayirt eder; iki tur
        birlikte okunabilir. Bu yuzden `Compact`/`BackupTo` bayragi
        ASLA sabitlememeli, kaydin KENDI bayragini korumalidir.
      ------------------------------------------------------------- }
    function IsEncrypted: Boolean;
    function HasEncryptedRecordsProp: Boolean;
    property HasEncryptedRecords: Boolean read HasEncryptedRecordsProp;
    { Anahtari dogrudan ver (32 bayt). Bos verilirse sifreleme kapanir. }
    procedure SetEncryptionKey(const Key: TBytes);
    procedure ClearEncryptionKey;
    { .key dosyasi olusturur (dosyada sır yok) ve anahtari yukler. }
    function CreateKeyFile(const FileName, Password: string): Boolean;
    { .key dosyasindan anahtari yukler; yanlis parola hata verir. }
    function OpenKeyFile(const FileName, Password: string): Boolean;
    { Bu veritabaninin varsayilan .key yolu. }
    function KeyPath: string;
    { M6: kolon seviyesi sifreleme anahtari. Dosya yoksa olusturur;
      varsa yukler. Doner: anahtar kimligi. }
    function EnsureColumnKey: QWord;
    { Yuklu kolon anahtarinin kimligi; 0 = yok. }
    function ColumnKeyId: QWord;
    { <db>.colkey yolu. }
    function ColumnKeyPath: string;
    { Etkin anahtarin SHA256 parmak izi (hex) - tanilama/log icin.
      Anahtarin KENDISINI vermez. }
    function EncryptionKeyFingerprint: string;
  end;

  { M11: IVDbKvStore'un TVDb'ye delege eden varsayilan uygulamasi.
    TVDb'yi SAHIPLENMEZ; yasam dongusu cagirana aittir. }
  TVDbKvStore = class(TInterfacedObject, IVDbKvStore)
  private
    FDb: TVDb;
  public
    constructor Create(ADb: TVDb);
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer);
  end;

function VDbStrToBytes(const S: RawByteString): TBytes;
function VDbBytesToStr(const B: TBytes): RawByteString;

{ F-42: cumleyi calistiran oturumun kimligi (thread yerel). TVDb batch
  sahipligini ve gorunurlugunu bu kimlige gore ayirir. 0 = oturum yok. }
procedure VDbSetTxnSession(AId: Cardinal);
function VDbGetTxnSession: Cardinal;
implementation

uses
  VDbCrc32, VDbSync, VDbCrypt, VDbUndo;

threadvar
  GVdbTxnSession: Cardinal;

procedure VDbSetTxnSession(AId: Cardinal);
begin
  GVdbTxnSession := AId;
end;

function VDbGetTxnSession: Cardinal;
begin
  Result := GVdbTxnSession;
end;

function TVDb.BatchIsMine: Boolean;
begin
  { Oturum kimligi 0 = ham TVDb API'si ya da motorun kendi ic is parcacigi.
    Bunlar eski global batch davranisini korur; yalnizca kimligi olan
    farkli SQL oturumlari birbirinden yalitilir. }
  Result := FInBatch and ((FBatchOwner = 0) or
    (VDbGetTxnSession = 0) or (FBatchOwner = VDbGetTxnSession));
end;

procedure TVDb.RequireBatchWrite;
begin
  if FInBatch and (FBatchOwner <> 0) and
     (VDbGetTxnSession <> 0) and
     (FBatchOwner <> VDbGetTxnSession) then
    raise EVDbException.Create(ecLockConflict,
      'VDb: baska bir oturumun acik islemi var; once COMMIT veya ROLLBACK');
end;

procedure TVDb.TxnGateOpen(AOwner: Cardinal);
begin
  if FGateLock = nil then Exit;
  FGateLock.Enter;
  try
    FGateOwner := AOwner;
    FGateOpen := True;
    FGateEvent.ResetEvent;
  finally
    FGateLock.Leave;
  end;
end;

procedure TVDb.TxnGateClose;
begin
  if FGateLock = nil then Exit;
  FGateLock.Enter;
  try
    FGateOpen := False;
    FGateOwner := 0;
  finally
    FGateLock.Leave;
  end;
  FGateEvent.SetEvent;
end;

procedure TVDb.WaitForeignTxn(ASessionId: Cardinal);
begin
  if (ASessionId = 0) or (FGateLock = nil) or (FGateEvent = nil) then Exit;
  while True do
  begin
    FGateLock.Enter;
    try
      if (not FGateOpen) or (FGateOwner = 0) or
         (FGateOwner = ASessionId) then
        Exit;
    finally
      FGateLock.Leave;
    end;
    { Manual-reset olay: kapanista isaretlenir, yeni transaction acilisinda
      sifirlanir. 1 sn'lik uyku, kacirilan sinyalde sonsuz bekleme yerine
      durumu yeniden denetler. }
    FGateEvent.WaitFor(1000);
  end;
end;

{ 2026-10-05: kayit bayragi gecerliligi.
  VDB_FLAG_ENCRYPTED bir KARSILIK (bit) olarak PUT ile birlikte
  kullanilir; eski kod `h.Flags <> VDB_FLAG_PUT` diye TAM KARSILASTIRMA
  yaptigi icin sifreli kayitlari "bozuk" sayip dosyayi kirardi.
  SILME kaydinda ENCRYPTED biti GECERSIZDIR (tombstone iceriksizdir).
  BATCHEND tek basina gecerlidir. }
function RecFlagsValid(AFlags: Byte; AValLen: LongWord;
  AllowBatchEnd: Boolean): Boolean;
var
  base: Byte;
begin
  base := Byte(AFlags and not Byte(VDB_FLAG_ENCRYPTED));
  if base = VDB_FLAG_PUT then
  begin
    if (AFlags and VDB_FLAG_ENCRYPTED) <> 0 then
      { sifreli degerin bos olmasi mumkun degil (en az 68 bayt) }
      Result := AValLen > 0
    else
      Result := True;
    Exit;
  end;
  if base = VDB_FLAG_DEL then
  begin
    { tombstone sifrelenmez }
    Result := ((AFlags and VDB_FLAG_ENCRYPTED) = 0) and (AValLen = 0);
    Exit;
  end;
  if AFlags = VDB_FLAG_BLOCKCRC then
  begin
    { H5: blok footer'i yapisal olarak deger tasimaz; blok bayt sayisi
      Key alanindadir. }
    Result := AValLen = 0;
    Exit;
  end;
  Result := AllowBatchEnd and (AFlags = VDB_FLAG_BATCHEND);
end;

function VDbStrToBytes(const S: RawByteString): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function VDbBytesToStr(const B: TBytes): RawByteString;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then Move(B[0], Result[1], Length(B));
end;

{ TVDb }

constructor TVDb.Create;
var
  i: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  { H12: sinirli blok onbellegi. Varsayilan 1024 blok x 8 KB = 8 MB (sinirli,
    salt-okunur). Uygulama SetReadCacheBlocks ile degistirebilir/kapatabilir. }
  FCacheLock := TCriticalSection.Create;
  FCacheMap := TDictionary<Int64, Integer>.Create;
  FCacheBlock := 8 * 1024;
  FCacheHand := 0;
  FCacheHits := 0;
  FCacheMisses := 0;
  FCacheMaxBlocks := 1024;
  SetLength(FCacheSlots, FCacheMaxBlocks);
  for i := 0 to FCacheMaxBlocks - 1 do
    FCacheSlots[i].Blk := -1;
  FGateLock := TCriticalSection.Create;
  FGateEvent := TEvent.Create(nil, True, False, '');
  FGateOpen := False;
  FGateOwner := 0;
  FIndex := TDictionary<QWord, TDbLoc>.Create;
  FTableKeys := TDictionary<Integer, TList<QWord>>.Create;
  FTableKeysDirty := True;
  FTableRowCount := TDictionary<Integer, Int64>.Create;
  FPending := TList<TPendOp>.Create;
  FPendingPuts := TDictionary<QWord, Byte>.Create;
  FPendingDels := TDictionary<QWord, Byte>.Create;
  FPendingIdx := TDictionary<QWord, Integer>.Create;
  FPutSeen := TDictionary<QWord, Byte>.Create;
FSavepoints := TList<TSavepoint>.Create;
  FSyncWrite := True;
  FSyncWriteInterval := 0;   // varsayilan: her yazmada fsync (eski davranis)
  FSyncWriteLast := 0;
  FDirty := False;
  FClosed := True;
  FLcked := False;
  FRestored := False;
  FDirSyncFailed := False;
  FNewFile := False;
  FDeadBytes := 0;
  FDataStart := VDB_HDR_SIZE;
  FEncFlags := 0;
  FColKeyId := 0;
  FReadMapEnabled := False;  // H4: olcumle net kazanc yok -> varsayilan kapali
end;

destructor TVDb.Destroy;
begin
  try
    Close;
  except
  end;
  FPending.Free;
  FPendingPuts.Free;
  FPendingDels.Free;
  FPendingIdx.Free;
  FPutSeen.Free;
  ClearSavepoints;
  FSavepoints.Free;
  FIndex.Free;
  ClearTableKeys;
  FTableKeys.Free;
  FTableRowCount.Free;
  FGateEvent.Free;
  FGateLock.Free;
  FLock.Free;
  SetLength(FCacheSlots, 0);
  FCacheMap.Free;
  FCacheLock.Free;
  { 2026-10-05 Adim 12: anahtar kalintisi birakma }
  if FEncKey <> nil then
  begin
    FillChar(FEncKey[0], Length(FEncKey), 0);
    FEncKey := nil;
  end;
  inherited;
end;

procedure TVDb.CheckOpen;
begin
  if FClosed or (FS = nil) then
    raise EVDbException.Create(ecDatabaseNotOpen, 'VDb: once Open cagir');
end;

function TVDb.RecCrc(Seq, Key: QWord; ValLen: LongWord; Flags: Byte; Value: PByte): LongWord;
var
  c: LongWord;
begin
  c := VDbCrc32Init;
  c := VDbCrc32Update(c, Seq, SizeOf(Seq));
  c := VDbCrc32Update(c, Key, SizeOf(Key));
  c := VDbCrc32Update(c, ValLen, SizeOf(ValLen));
  c := VDbCrc32Update(c, Flags, SizeOf(Flags));
  if (ValLen > 0) and (Value <> nil) then
    c := VDbCrc32UpdatePtr(c, Value, ValLen);
  Result := VDbCrc32Final(c);
end;

function TVDb.RecCrcWal(LSN, Stamp, Key: QWord; ValLen: LongWord;
  Flags: Byte; Value: PByte): LongWord;
var
  c: LongWord;
begin
  c := VDbCrc32Init;
  c := VDbCrc32Update(c, LSN, SizeOf(LSN));
  c := VDbCrc32Update(c, Stamp, SizeOf(Stamp));
  c := VDbCrc32Update(c, Key, SizeOf(Key));
  c := VDbCrc32Update(c, ValLen, SizeOf(ValLen));
  c := VDbCrc32Update(c, Flags, SizeOf(Flags));
  if (ValLen > 0) and (Value <> nil) then
    c := VDbCrc32UpdatePtr(c, Value, ValLen);
  Result := VDbCrc32Final(c);
end;

function TVDb.HeadCrc(const H: TVDbFileHead): LongWord;
begin
  Result := VDbCrc32Of(H, SizeOf(H) - SizeOf(H.Crc));
end;

procedure TVDb.WriteHeaderTo(S: TStream);
var
  h: TVDbFileHead;
begin
  h.Magic := VDB_FILE_MAGIC;
  h.Ver := VDB_FILE_VER;
  h.Flags := FEncFlags;
  h.Crc := HeadCrc(h);
  S.WriteBuffer(h, SizeOf(h));
end;

procedure TVDb.DetectFormat;
var
  m: LongWord;
  h: TVDbFileHead;
  n: Integer;
begin
  // F2-3: Bu yordam BOSUK veya YARIM yazilmis dosyada ReadBuffer ile
  // EReadError firlatabiliyordu; cagiran taraf EVDbException beklerken
  // EReadError goruyordu (tutarsiz hata sinifi). Artik her yol
  // EVDbException(ecCorrupt) ile biter.
  // cagri oncesi FS acik, FLock tutuluyor
  try
    FS.Position := 0;
    n := FS.Read(m, SizeOf(m));
    if n <> SizeOf(m) then
      // 0 baytlik dosya Open'da zaten yakalaniyor; buraya 1..3 bayt
      // gelir (yarim yazma / bozuk dosya).
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: dosya cok kisa (baslik okunamadi, %d bayt)', [n]);
    if m = VDB_MAGIC then
    begin
      MigrateLegacy; // FDataStart'i de kurar
      Exit;
    end
    else if m = VDB_FILE_MAGIC then
    begin
      FS.Position := 0;
      FS.ReadBuffer(h, SizeOf(h));
      if h.Crc <> HeadCrc(h) then
        raise EVDbException.Create(ecCorrupt, 'VDb: dosya basligi CRC hatasi (bozuk)');
      FEncFlags := h.Flags and VDB_HFLAG_HAS_ENCRYPTED;
      if (h.Ver = VDB_FILE_VER_OLD) or (h.Ver = VDB_FILE_VER_V2) then
      begin
        // V1/V2 -> V3 yukseltme. Kayit duzeni ayni; V3'te blok CRC
        // footer'lari eklenir. Basligi yerinde yeniden yazip fsync ->
        // dosya artik eski buildler tarafindan guvenle reddedilir.
        h.Ver := VDB_FILE_VER;
        h.Crc := HeadCrc(h);
        FS.Position := 0;
        FS.WriteBuffer(h, SizeOf(h));
        VDbFlushStream(FS);
      end
      else if h.Ver <> VDB_FILE_VER then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: dosya surumu desteklenmiyor (dosya=%d, motor=%d). Dosya bu ' +
          'motorun daha yeni surumuyle yazilmis; icerigi degistirilmedi.',
          [h.Ver, VDB_FILE_VER]);
      FDataStart := VDB_HDR_SIZE;
    end
    else
      raise EVDbException.Create(ecCorrupt, 'VDb: dosya formati taninmiyor (VODB degil)');
  except
    on E: EVDbException do raise;              // zaten dogru sinif
    on E: EAccessViolation do
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: dosya okunurken bellek hatasi (%s)', [FPath]);
    on E: Exception do
      // EReadError (kisa dosya), EInOutError, EOutOfMemory ...
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: dosya basligi okunamadi/bozuk (%s: %s)', [FPath, E.Message]);
  end;
end;


procedure TVDb.MigrateLegacy;
// Eski ham kayit akisini (headersiz) yeni .odb duzenine cevirir:
// kayit byte'lari aynen korunur, basa baslik eklenir. .bak birakir.
// F1-3: Govdeyi RAM'e ALMAZ; sabit 64 KB tamponla akis kopyasi yapar.
var
  ts: TFileStream;
  tmpPath: string;
  sz, copied: Int64;
  buf: array[0..65535] of Byte;
  n: Integer;
begin
  FDataStart := 0;
  Recover; // index kur + yirtik kuyrugu kes
  sz := FS.Size;
  tmpPath := FPath + '.tmp';
  if FileExists(tmpPath) then DeleteFile(tmpPath);
  ts := TFileStream.Create(tmpPath, fmCreate);
  try
    WriteHeaderTo(ts);
    if sz > 0 then
    begin
      FS.Position := 0;
      copied := 0;
      while copied < sz do
      begin
        if sz - copied < Int64(SizeOf(buf)) then
          n := FS.Read(buf[0], sz - copied)
        else
          n := FS.Read(buf[0], SizeOf(buf));
        if n <= 0 then Break;
        ts.WriteBuffer(buf[0], n);
        Inc(copied, n);
      end;
    end;
    VDbFlushStream(ts);
  finally
    ts.Free;
  end;
  // NOT: tmp dosyasi baslikli duzende oldugu icin FDataStart,
  // ReplaceWith icindeki Recover'dan ONCE kurulmali.
  // Yanlis sira dosyayi sifirlar (harness yakaladi).
  FDataStart := VDB_HDR_SIZE;
  ReplaceWith(tmpPath);
end;

procedure TVDb.ReplaceWith(const TmpPath: string);
// TmpPath'teki dosyayi fsync'li ve dogrulanmis kabul eder, atomik
// rename ile FPath yapar, acip index'i kurar. Hata olursa .bak'tan doner.
// Giriste FLock tutuluyor olmali.
var
  bakPath: string;

  procedure Reopen;
  begin
    FS := TFileStream.Create(FPath, fmOpenReadWrite);
    FLcked := False;
    if not VDbLockStream(FS) then
    begin
      FreeAndNil(FS);
      raise EVDbException.Create(ecDatabaseLocked, 'dosya kilitlenemedi (yarisma)');
    end;
    FLcked := True;
    FClosed := False;
    PendingClear;
    FPendingPuts.Clear;
    FPendingDels.Clear;
    Recover;
    // H3: offsetler fiziksel olarak degisti -> zone map gecersiz.
    Inc(FDataEpoch);
  end;

begin
  if FLcked then
  begin
    try VDbUnlockStream(FS); except end;
    FLcked := False;
  end;
  FreeAndNil(FS);
  try
    bakPath := FPath + '.bak';
    if FileExists(bakPath) then DeleteFile(bakPath);
    if not RenameFile(FPath, bakPath) then
      raise EVDbException.Create(ecIOError, 'yedekleme basarisiz');
    try
      if not RenameFile(TmpPath, FPath) then
        raise EVDbException.Create(ecIOError, 'degisim basarisiz');
      // F2-1/F2-2: rename sonrasi dizin girdisi flush EDILMEZSE yeni ad
      // kalici olmaz; crash'ta dosya .bak adiyla kalir.
      if not VDbFlushDir(ExtractFileDir(FPath)) then
        FDirSyncFailed := True;
    except
      RenameFile(bakPath, FPath);
      raise;
    end;
    Reopen;
  except
    on E: Exception do
    begin
      try
        if FS = nil then
        begin
          if FileExists(bakPath) and not FileExists(FPath) then
            RenameFile(bakPath, FPath);
          if FileExists(FPath) then
          begin
            FS := TFileStream.Create(FPath, fmOpenReadWrite);
            FLcked := False;
            if VDbLockStream(FS) then
            begin
              FLcked := True;
              FClosed := False;
              PendingClear;
              FPendingPuts.Clear;
              FPendingDels.Clear;
              DetectFormat;
              Recover;
            end
            else
            begin
              FreeAndNil(FS);
              FClosed := True;
            end;
          end
          else
            FClosed := True;
        end;
      except
        FClosed := True;
      end;
      raise EVDbException.Create(ecIOError, 'VDb dosya degisimi hatasi: ' + E.Message);
    end;
  end;
end;

procedure TVDb.FlushWriteBuf;
{ P-21 (2026-10-16): aktif toplu yazim tamponunu dosyaya bosaltir.
  Diskteki bayt akisi birebir aynidir (tampon = sirayla yazilacak
  baytlar). GUVENLIK: dosya sonu FWrBufBase ile UYUSMAZSA yazmaz,
  GORUNUR hata verir — sessiz veri bozulmasi imkansiz. }
var
  off: Int64;
begin
  if not FWrBufActive then Exit;
  if FWrBufLen <= 0 then Exit;
  off := FS.Seek(0, soEnd);
  if off <> FWrBufBase then
    raise EVDbException.CreateFmt(ecIOError,
      'VDb: toplu yazim tamponu dosya sonuyla uyusmuyor (beklenen=%d gercek=%d)',
      [FWrBufBase, off]);
  FS.WriteBuffer(FWrBuf[0], FWrBufLen);
  Inc(FWrBufBase, Int64(FWrBufLen));
  FWrBufLen := 0;
  FDirty := True;
end;

procedure TVDb.BlockCrcAdd(const H: TVDbRecHead; Value: PByte);
begin
  FBlockCrc := VDbCrc32Update(FBlockCrc, H, SizeOf(H));
  if (H.ValLen > 0) and (Value <> nil) then
    FBlockCrc := VDbCrc32UpdatePtr(FBlockCrc, Value, Integer(H.ValLen));
  Inc(FBlockBytes, Int64(SizeOf(H)) + Int64(H.ValLen));
end;

procedure TVDb.AppendBlockFooter;
{ H5: o ana kadar yazilan blok baytlarinin CRC'sini footer kaydi olarak
  yazar. Footer'in ValLen'i 0'dir (yapisal olarak deger tasimaz); blok
  bayt sayisi Key alaninda tasinir. Footer kendi CRC'sine dahil edilmez. }
var
  h: TVDbRecHead;
  off: Int64;
  need, newCap: Integer;
begin
  if FBlockBytes <= 0 then Exit;
  if FBlockBytes > Int64(High(LongWord)) then
    raise EVDbException.Create(ecLimit, 'VDb: blok boyutu cok buyuk');
  h.Magic := VDB_MAGIC;
  h.Crc := VDbCrc32Final(FBlockCrc);
  h.Seq := 0;
  h.Key := QWord(FBlockStart);   // blok baslangic offseti (Verify yeniden hesaplayabilir)
  h.ValLen := 0;
  h.Flags := VDB_FLAG_BLOCKCRC;
  need := SizeOf(h);
  if FWrBufActive then
  begin
    off := FWrBufBase + Int64(FWrBufLen);
    if FWrBufLen + need > Length(FWrBuf) then
    begin
      newCap := Length(FWrBuf);
      while newCap < FWrBufLen + need do
        Inc(newCap, VDB_WRBUF_MAX);
      SetLength(FWrBuf, newCap);
    end;
    Move(h, FWrBuf[FWrBufLen], need);
    Inc(FWrBufLen, need);
    if FWrBufLen >= VDB_WRBUF_MAX then
      FlushWriteBuf;
  end
  else
  begin
    off := FS.Seek(0, soEnd);
    FS.WriteBuffer(h, need);
  end;
  FDirty := True;
  FBlockStart := off + Int64(need);
  FBlockBytes := 0;
  FBlockCrc := VDbCrc32Init;
end;

procedure TVDb.AppendRec(Key: QWord; const Value: TBytes; IsDel: Boolean;
  DoFlush: Boolean; SkipWAL: Boolean);
{ Tum KALICI yazma yollarinin tek kavsi. Put, Delete, CommitBatch ve
  ReplayWAL hepsi burayi cagirir.

  2026-10-04 OTOMATIK WAL: FWALEnabled True ise kayit ONCE .wal'a
  yazilir, SONRA ana dosyaya. Boylece bu fonksiyon cagrildigi anda
  sistem cokerse kayit .wal'da durur ve ReplayWAL ile kurtarilir.

  DIKKAT - RECOVER UYUMU: ozel bir bayrakla cagrilir. Recover, dosyayi
  bastan tarayip kendi AppendRec'ini cagirdigi icik, kendi kayitlarini
  .wal'a yeniden yazmamalidir (sonsuz dongu + dosya buyumesi).
  Bu yuzden `SkipWAL` parametresi eklendi.

  2026-10-05 SIFRELEME: FEncKey doluysa PUT degeri sifrelenerek
  yazilir ve VDB_FLAG_ENCRYPTED bayragi eklenir. TOMBSTONE
  (IsDel) sifrelenmez. CRC sifreli baytlari kapsar.
  WAL'a ise DUZ METIN + duz bayrak yazilir: replay AppendRec'i
  yeniden cagirip degeri yeniden sifreler, boylece WAL'da sifreli
  veri birikmez ve bayrak cakismasi olmaz.
}
var
  h: TVDbRecHead;
  loc: TDbLoc;
  off: Int64;
  pv: PByte;
  stored: TBytes;      // dosyaya yazilacak deger (sifreli olabilir)
  wbuf: TBytes;        // P-19w: header+deger birlesik yazim tamponu
  need, newCap: Integer;   // P-21: toplu yazim tamponu boyut yonetimi
  walFlags: Byte;
begin
  stored := nil;
  if IsDel then
  begin
    h.ValLen := 0;
    walFlags := VDB_FLAG_DEL;
  end
  else
  begin
    walFlags := VDB_FLAG_PUT;
    if Length(FEncKey) = VDB_KEY_LEN then
    begin
      if not EncryptValue(Value, stored) then
        raise EVDbException.Create(ecIOError, 'VDb: deger sifrelenemedi');
      h.ValLen := LongWord(Length(stored));
    end
    else
    begin
      stored := Value;
      h.ValLen := LongWord(Length(Value));
    end;
  end;
  if (not IsDel) and (Length(FEncKey) = VDB_KEY_LEN) and ((FEncFlags and VDB_HFLAG_HAS_ENCRYPTED) = 0) then
  begin
  { Once sifreli kayit yazilirken dosyanin basligindaki Flags alanina
    VDB_HFLAG_HAS_ENCRYPTED biri yazilir. Open'da sifreli dosyayi
    anahtarsız acarsan, ilk erisimde 'gereksiz dosya' mesaji yerine
    dogrudan net hata verilir. Basligi yerinde yazmak icin seek edip
    geri doner; ek fsync basliga da uygulanir. }
    FEncFlags := FEncFlags or VDB_HFLAG_HAS_ENCRYPTED;
    FS.Position := 0;
    WriteHeaderTo(FS);
    FS.Seek(0, soEnd);
    VDbFlushStream(FS);
    // H12: baslik YERINDE degisti -> 0. blogu gecersiz kil.
    CacheInvalidateAt(0, VDB_HDR_SIZE);
  end;
  if h.ValLen > VDB_MAX_VALUE then
    raise EVDbException.Create(ecLimit, 'VDb: value cok buyuk');
  Inc(FSeq);
  h.Magic := VDB_MAGIC;
  h.Seq := FSeq;
  h.Key := Key;
  h.Flags := walFlags;
  if (not IsDel) and (Length(FEncKey) = VDB_KEY_LEN) then
    h.Flags := Byte(h.Flags or VDB_FLAG_ENCRYPTED);
  if h.ValLen > 0 then
    pv := @stored[0]
  else
    pv := nil;
  h.Crc := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, pv);

  // ---- 2026-10-04: OTOMATIK WAL (once .wal, sonra ana dosya) ----
  // SkipWAL=False ise ve otomatik mod acikse once gunkluge yaz.
  // Yazma HATASI olursa ana dosyaya YAZILMAZ: yarim kalmis kayit
  // olusmaz. (Kayip veri yerine "islem basarisiz" tercih edildi.)
  // ONEMLI: gunkluge DUZ METIN + duz bayrak yazilir (sifreli degil).
  if not SkipWAL then
    if FWALEnabled then
      if not WriteAheadWALCore(Key, Value, walFlags) then
        raise EVDbException.CreateFmt(ecIOError,
          'VDb: WAL yazilamadi, islem durduruldu (ana dosyaya yazilmadi): %s',
          [FPath]);

  { H5: hedef blok buyuklugune ulastiysa once mevcut blogu kapat.
    Boylece yeni kayit yeni blokta baslar; footer'in kendisi bir sonraki
    bloga dahil edilmez. }
  if FBlockBytes >= VDB_BLOCK_TARGET then
    AppendBlockFooter;
  BlockCrcAdd(h, pv);

  { P-21 (2026-10-16): CommitBatch toplu yazim. Tampon AKTIFSE kayit
    baytlari (baslik+deger) dosyaya degil tampona eklenir; offset
    FWrBufBase + tampondaki konumdur (kayit CommitBatch sonunda TAM o
    offset'e gidecek). Esikte FlushWriteBuf tek WriteBuffer yapar.
    Diskteki bayt akisi BIREBIR aynidir: ayni baytlar, ayni sira.
    Tampon PASIFSE (CommitBatch disi HER yol) asagidaki ESKI yol
    birebir calisir. }
  if FWrBufActive then
  begin
    off := FWrBufBase + Int64(FWrBufLen);
    need := Integer(SizeOf(h)) + Integer(h.ValLen);
    if FWrBufLen + need > Length(FWrBuf) then
    begin
      newCap := Length(FWrBuf);
      while newCap < FWrBufLen + need do
        Inc(newCap, VDB_WRBUF_MAX);
      SetLength(FWrBuf, newCap);
    end;
    Move(h, FWrBuf[FWrBufLen], SizeOf(h));
    if h.ValLen > 0 then
      Move(stored[0], FWrBuf[FWrBufLen + SizeOf(h)], h.ValLen);
    Inc(FWrBufLen, need);
    if FWrBufLen >= VDB_WRBUF_MAX then
      FlushWriteBuf;
  end
  else
  begin
    off := FS.Seek(0, soEnd);
    { P-19w: header + deger TEK WriteBuffer ile yazilir (3 syscall -> 2).
      FS.Seek(0, soEnd) KORUNUR: dosya sonunun tek yetkili kaynagi budur.
      Offset'i bellekte tutmak (in-place guncelleme FS.Position, rollback
      FS.Size:=, Compact, truncate yollarinda) bir kez invalide
      edilmediginde sessiz veri bozulmasi riski tasirdi; guvenlik > mikro
      kazanc. Birlesik yazim veri sozlesmesini DEGISTIRMEZ: ayni baytlar
      ayni sirayla ayni offset'e yazilir.
      BUYUK DEGER (blob): birlesik tampon ayirmamak icin ESKI yol birebir
      (16 MB'a kadar gecici kopya olmasin). }
    if h.ValLen <= VDB_COMBINE_MAX then
    begin
      SetLength(wbuf, Integer(SizeOf(h)) + Integer(h.ValLen));
      Move(h, wbuf[0], SizeOf(h));
      if h.ValLen > 0 then
        Move(stored[0], wbuf[SizeOf(h)], h.ValLen);
      FS.WriteBuffer(wbuf[0], Integer(SizeOf(h)) + Integer(h.ValLen));
    end
    else
    begin
      FS.WriteBuffer(h, SizeOf(h));
      if h.ValLen > 0 then
        FS.WriteBuffer(stored[0], h.ValLen);
    end;
  end;
  FDirty := True;
  if DoFlush then
    VDbFlushStream(FS);
  if (not SkipWAL) and FWALEnabled then
    Inc(FWALAutoCount);

  if FIndex.TryGetValue(Key, loc) then
    Inc(FDeadBytes, Int64(SizeOf(h)) + Int64(loc.Size));
  if IsDel then
  begin
    Inc(FDeadBytes, Int64(SizeOf(h)) + Int64(h.ValLen));
    FIndex.Remove(Key);
  end
  else
  begin
    loc.Offset := off;
    loc.Size := h.ValLen;
    loc.Seq := h.Seq;
    loc.Flags := h.Flags;
    // R-26: tablo id'yi satirin icinden cikar (Value PLAINTEXT'tir;
    // sifreleme 'stored' uzerinde yapilir). WAL replay de AppendRec'i
    // cagirdigi icin gunkluk yeniden yazimlari da kapsar.
    if @FRowTagFunc <> nil then
      loc.TableId := FRowTagFunc(Value, Length(Value))
    else
      loc.TableId := -1;
    FIndex.AddOrSetValue(Key, loc);
  end;
  // KR-1: FIndex degisti -> tablo anahtar dizini bir sonraki filtreli
  // taramada FIndex'ten yeniden kurulacak (yazma yoluna ek maliyet yok).
  FTableKeysDirty := True;
  FTableRowCount.Clear;   // KR-1B: her yazma COUNT cache'ini gecersiz kilar
  // H3: FIndex artik TAM guncel -> zone map surumu.
  Inc(FIdxVer);
  { 2026-10-05 Adim 12: sifreli ara tampon ClearEnc; ham sifreli baytlar
    bellekte kalmasin. Try-finally ile dosyalara dokunmadan temizlenir. }
  if (stored <> nil) and (Length(stored) > 0) and (Length(FEncKey) = VDB_KEY_LEN) then
  begin
    FillChar(stored[0], Length(stored), 0);
    stored := nil;
  end;
end;

procedure TVDb.AppendBatchEnd(DoFlush: Boolean);
// Batch sonu isareti: Key = 0, ValLen = 0, Flags = VDB_FLAG_BATCHEND.
// CommitBatch bunu yazip tek fsync yapar. Recovery bu kaydi gormeden
// onceki batch kayitlarini geri sarar -> gercek atomiklik.
var
  h: TVDbRecHead;
  off: Int64;
begin
  Inc(FSeq);
  h.Magic := VDB_MAGIC;
  h.Seq := FSeq;
  h.Key := 0;
  h.ValLen := 0;
  h.Flags := VDB_FLAG_BATCHEND;
  h.Crc := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, nil);
  BlockCrcAdd(h, nil);
  off := FS.Seek(0, soEnd);
  FS.WriteBuffer(h, SizeOf(h));
  { H5: BATCHEND'den sonra blogu kapat. Boylece commit'in gorunur
    oldugu her noktada bir blok CRC'si de tamamlanmis olur. }
  AppendBlockFooter;
  FDirty := True;
  if DoFlush then
    VDbFlushStream(FS);
end;

procedure TVDb.AppendBatchEndTo(S: TStream; ASeq: QWord);
// Compact/BackupTo cikis dosyasi icin batch-end (belirtilen seq ile).
var
  h: TVDbRecHead;
begin
  h.Magic := VDB_MAGIC;
  h.Seq := ASeq;
  h.Key := 0;
  h.ValLen := 0;
  h.Flags := VDB_FLAG_BATCHEND;
  h.Crc := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, nil);
  S.WriteBuffer(h, SizeOf(h));
end;

procedure TVDb.Recover;
// Dosyayi bastan sona tarar. Batch kavrami: CommitBatch her batch sonunda
// bir BATCHEND kaydi yazar. Tarama, BATCHEND gorene kadar olan kayitlari
// GECICI listeye yazar; BATCHEND gorulurse listeyi FIndex'e isler, yoksa
// (yarim batch / crash) listeyi TAMAMEN BIRAKIR -> gercek atomiklik.
var
  fsize, pos, next: Int64;
  h: TVDbRecHead;
  buf: TBytes;
  c: LongWord;
  loc: TDbLoc;
  n: Integer;
  pendPos: array of Int64;
  pendSz: array of LongWord;
  pendKey: array of QWord;
  pendFlags: array of Byte;
  pendTag: array of Integer;   // R-26: satirin tablo id'si (-1 = satir degil)
  pendN: Integer;
  tag: Integer;
  tagPlain: TBytes;
  committed: Boolean;
  torn: Boolean;   // dongu bir kayitta kirildi (CRC/magic/yari yazim)
  sawBatchEnd: Boolean; // dosyada HIC BIR BATCHEND kaydi var miydi
  committedThrough: Int64; // son commit'li BATCHEND'den sonraki bayt offseti
  truncatePos: Int64;

  procedure ApplyPending;
  var
    q: Integer;
    l2: TDbLoc;
  begin
    for q := 0 to pendN - 1 do
    begin
      if FIndex.TryGetValue(pendKey[q], l2) then
        Inc(FDeadBytes, Int64(SizeOf(h)) + Int64(l2.Size));
      if pendFlags[q] = VDB_FLAG_DEL then
      begin
        Inc(FDeadBytes, Int64(SizeOf(h)) + Int64(pendSz[q]));
        FIndex.Remove(pendKey[q]);
      end
      else
      begin
        l2.Offset := pendPos[q];
        l2.Size := pendSz[q];
        l2.Seq := 0;
        l2.Flags := pendFlags[q];
        l2.TableId := pendTag[q];   // R-26
        FIndex.AddOrSetValue(pendKey[q], l2);
      end;
    end;
    FTableKeysDirty := True;   // KR-1: kurtarma sirasinda FIndex degisti
    FTableRowCount.Clear;
    pendN := 0;
  end;

begin
  // H12: kurtarma offset'leri yeniden kurar (ve gerekirse dosyayi kirpar)
  // -> blok onbellegi gecersiz.
  ClearReadCache;
  FIndex.Clear;
  FTableKeysDirty := True;   // KR-1: index tamamen sifirlandi
  FTableRowCount.Clear;
  FSeq := 0;
  FDeadBytes := 0;
  fsize := FS.Size;
  pos := FDataStart;
  SetLength(buf, 65536);
  pendN := 0;
  committed := True;
  torn := False;
  sawBatchEnd := False;   // ONEMLI: Boolean yereller otomatik sifirlanmaz
  committedThrough := FDataStart;
  while pos + Int64(SizeOf(h)) <= fsize do
  begin
    FS.Position := pos;
    n := FS.Read(h, SizeOf(h));
    if n <> SizeOf(h) then begin torn := True; Break; end;
    if h.Magic <> VDB_MAGIC then
    begin torn := True; Break; end; // yirtik kuyruk
    if h.ValLen > VDB_MAX_VALUE then
    begin torn := True; Break; end;
    next := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
    if next > fsize then
    begin torn := True; Break; end; // yari yazilmis
    { H5: blok footer'i bir kayit degildir; seq/pending/CRC akisina
      katilmaz. Kayit-bazi CRC'ler zaten dogrulandi; footer yalnizca
      Verify'in hizli blok kontrolu icindir. }
    if h.Flags = VDB_FLAG_BLOCKCRC then
    begin
      { Footer, BATCHEND'den sonra gelir. Arada commit edilmemis kayit
        yoksa bu footer da commit'in parcasi sayilir; aksi halde yarim
        batch kirpilirken commit'li blogun footer'i da silinir ve Verify
        "blok footer yok" der. }
      if committed then
        committedThrough := next;
      pos := next;
      Continue;
    end;
    if h.ValLen > 0 then
    begin
      if Length(buf) < Integer(h.ValLen) then
        SetLength(buf, h.ValLen);
      FS.ReadBuffer(buf[0], h.ValLen);
      c := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, @buf[0]);
    end
    else
      c := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, nil);
    if c <> h.Crc then
    begin torn := True; Break; end; // CRC tutmadi -> kuyrugu kes
    if not RecFlagsValid(h.Flags, h.ValLen, True) then
    begin torn := True; Break; end;
    if h.Seq > FSeq then
      FSeq := h.Seq;
    // R-26: CRC zaten tum degeri buf'a okudu -> tablo id'yi bedava cikar.
    // Boylece bir tablo taramasi, diger tablolarin kayitlarini AYRICA
    // okumak zorunda kalmaz. Sifreli kayitta once cozulur.
    if (h.ValLen >= 2) and (@FRowTagFunc <> nil) then
    begin
      if (h.Flags and VDB_FLAG_ENCRYPTED) <> 0 then
      begin
        if DecryptValue(buf, tagPlain) then
          tag := FRowTagFunc(tagPlain, Length(tagPlain))
        else
          tag := -1;   // cozulemedi -> filtre uygulanmaz (guvenli taraf)
      end
      else
        tag := FRowTagFunc(buf, Integer(h.ValLen));
    end
    else
      tag := -1;
    if h.Flags = VDB_FLAG_BATCHEND then
    begin
      // batch tamam: gecici kayitlar gecerli
      ApplyPending;
      committed := True;
      sawBatchEnd := True;
      committedThrough := next;  // BATCHEND'den sonraki bayt
    end
    else
    begin
      // henuz commit edilmemis batch kaydi
      if Length(pendPos) <= pendN then
      begin
        SetLength(pendPos, pendN + 64);
        SetLength(pendSz, pendN + 64);
        SetLength(pendKey, pendN + 64);
        SetLength(pendFlags, pendN + 64);
        SetLength(pendTag, pendN + 64);
      end;
      pendPos[pendN] := pos;
      pendSz[pendN] := h.ValLen;
      pendKey[pendN] := h.Key;
      pendFlags[pendN] := h.Flags;
      pendTag[pendN] := tag;      // R-26
      Inc(pendN);
      committed := False;
    end;
    pos := next;
  end;
  // truncate iki farkli duruma gore:
  //  - DONGUDEN CIKTIKSA (pos < fsize): yirtik/bozuk kuyruk, pos'a kes.
  //  - Dosya sonuna kadar okundu ama BATCHEND yoksa (not committed):
  //    commit edilmemis batch -> geri sarildi, dosya sonuna kes.
  // ONEMLI: torn (kayitta kirilma) varsa pos KORUNUR; aksi halde kesme
  // noktasi yanlis olur ve bozuk veri geri gelirdi.
  // Kesme noktasi (F1-1: torn=True+committed=False durumunda pending
  // prefix'i de sil; eskiden pos'a kesiliyor ama pending prefix diskte
  // kaliyordu -> seq cakismasi + Verify bozuluyordu):
  //  - sawBatchEnd=False: legacy dosya (BATCHEND yok), tum kayitlar gecerli
  //    -> ApplyPending + yalniz torn kuyruk kesilir.
  //  - committed=False: son batch commit edilmemis -> committedThrough'a
  //    kes (pending prefix silinir) + FSeq geri sar.
  //  - temiz/torn: yalniz torn kuyruğu kes (pos).
  if not sawBatchEnd then
  begin
    if pendN > 0 then ApplyPending;
    committed := True;
    truncatePos := pos;
  end
  else if not committed then
  begin
    truncatePos := committedThrough;
    if pendN > 0 then FSeq := FSeq - QWord(pendN);
  end
  else
    truncatePos := pos;
  {$IFDEF VDB_DEBUG_RECOVER}
  WriteLn('  [Recover] start=', FDataStart, ' fsize=', fsize, ' pos=', pos,
    ' torn=', torn, ' committed=', committed, ' sawBE=', sawBatchEnd,
    ' pendN=', pendN, ' index=', FIndex.Count,
    ' committedThrough=', committedThrough, ' truncatePos=', truncatePos);
  {$ENDIF}
  if truncatePos < fsize then
  begin
    FS.Size := truncatePos;
    VDbFlushStream(FS);
  end;
  FS.Position := FS.Size;
  { H5: kurtarma sonrasi yeni blok, temizlenmis dosya sonundan baslar.
    Boylece yarim kalmis bir blok footer'i asla yeni blokla karismaz. }
  FBlockStart := FS.Size;
  FBlockBytes := 0;
  FBlockCrc := VDbCrc32Init;
end;

function TVDb.FindPending(Key: QWord; out Op: TPendOp): Boolean;
// ONEMLI: eskiden FPending listesini bastan taraardi (O(n)). 5000'lik
// batch'te her Get/Exists cagrisi tum listeyi dolasiyordu (O(n^2)).
// Simdi key -> slot haritasi var: O(1).
//
// KRITIK DUZELTME: "haritada anahtar YOK" demek "bu anahtar icin pending
// op yoktur" demektir ve bu durumda ARAMA YAPILMAZ. Once her Get cagrisi
// (ORN. INSERT'in duplicate-PK kontrolunde Get) 20000 satirlik bir batch'te
// "bulunamadi" dondugu icin TUM listeyi tarardi -> her INSERT O(pending) ->
// toplam O(n^2). 20.000 satirlik toplu yazma 3,5 saniye suruyordu;
// ilk 5.000 satir 43 us, sonraki 15.000 satir 215 us idi (lineer artis).
// Tarama YALniz harita bir anahtari gosteriyor ama slot bozuk ciddur
// (nadir, savunma yolu).
var
  idx, i: Integer;
  found: Boolean;
begin
  Op.Key := Key;
  Op.IsDel := False;
  SetLength(Op.Value, 0);
  if not FPendingIdx.TryGetValue(Key, idx) then
  begin
    // haritada yok -> pending op da yoktur. HIZLI ISKALAMA (O(1)).
    Result := False;
    Exit;
  end;
  if (idx >= 0) and (idx < FPending.Count) and (FPending[idx].Key = Key) then
  begin
    Op := FPending[idx];
    Exit(True);
  end;
  // Harita tutarsiz (slot tasinmis): onar
  found := False;
  for i := FPending.Count - 1 downto 0 do
    if FPending[i].Key = Key then
    begin
      FPendingIdx[Key] := i;
      Op := FPending[i];
      found := True;
      Break;
    end;
  if not found then
    FPendingIdx.Remove(Key);
  Result := found;
end;

procedure TVDb.PendingAdd(const Op: TPendOp);
begin
  FPending.Add(Op);
  // FPC TDictionary: '[]' atamasi anahtar YOKSA hata verir.
  // AddOrSetValue ekleme + guncellemeyi tek adimda yapar.
  FPendingIdx.AddOrSetValue(Op.Key, FPending.Count - 1);
end;

procedure TVDb.PendingRemove(const Idx: Integer);
// Listeden bir op siler (TList.Delete son elemani bos slota tasir).
// Silinen anahtarin harita girdisi de silinir: aksi halde harita o
// slottaki FARKLI bir anahtari gosterirdi (bayat kayit).
var
  j: Integer;
  movedKey: QWord;
begin
  if (Idx < 0) or (Idx >= FPending.Count) then Exit;
  FPendingIdx.Remove(FPending[Idx].Key);
  if Idx = FPending.Count - 1 then
  begin
    FPending.Delete(Idx);
    Exit;
  end;
  movedKey := FPending[FPending.Count - 1].Key;
  FPending.Delete(Idx);
  if FPendingIdx.TryGetValue(movedKey, j) then
    FPendingIdx[movedKey] := Idx;
end;

procedure TVDb.PendingClear;
begin
  FPending.Clear;
  FPendingIdx.Clear;
  FPendingPuts.Clear;
  FPendingDels.Clear;
  FPutSeen.Clear;
end;

function TVDb.PendingCount: Integer;
begin
  Result := FPending.Count;
end;

procedure TVDb.Open(const Dir: string);
var
  Loc, Old: string;
  ColKeyFile: string;
  Restored: Integer;
begin
  FLock.Enter;
  try
    if not FClosed then Close;
    Loc := Trim(Dir);
    if (Loc <> '') and SameText(ExtractFileExt(Loc), '.odb') then
    begin
      FPath := Loc;
      FDir := IncludeTrailingPathDelimiter(ExtractFileDir(FPath));
      ForceDirectories(FDir);
    end
    else
    begin
      FDir := IncludeTrailingPathDelimiter(Loc);
      ForceDirectories(FDir);
      FPath := FDir + 'veritabani.odb';
      // eski surum tasiyici: vdb.log varsa odb'ye tasi
      Old := FDir + 'vdb.log';
      if not FileExists(FPath) and FileExists(Old) then
      begin
        RenameFile(Old, FPath);
        // F2-2: rename sonrasi dizin girdisi flush edilmezse crash'ta
        // ya eski ad ya hicbiri gorunur. Dosya yeni olmadigi icin
        // FNewFile False kalir ama dizin yine de flush edilir.
        if not VDbFlushDir(FDir) then
          FDirSyncFailed := True;
      end;
    end;
    // yarim kalmis compact/replace: ana dosya yok ama .bak varsa don
    FRestored := False;
    FDirSyncFailed := False;
    FNewFile := False;
    FEncFlags := 0;
    { M6: kolon anahtari varsa acilista yukle. Yoksa sifreli kolon
      okumalari anahtar isteyene kadar hata verir; sema yukleme ayrica
      sifreli kolon varken anahtarsiz acilmaya izin vermez. }
    FColKeyId := 0;
    ColKeyFile := ChangeFileExt(FPath, '.colkey');
    if FileExists(ColKeyFile) then
      if not VDbColumnKeyLoadFile(ColKeyFile, FColKeyId) then
        raise EVDbException.Create(ecIOError,
          'VDb: kolon anahtar dosyasi okunamadi: ' + ColKeyFile);
    if not FileExists(FPath) and FileExists(FPath + '.bak') then
    begin
      if not RenameFile(FPath + '.bak', FPath) then
        raise EVDbException.Create(ecIOError, 'VDb: .bak geri yuklenemedi: ' + FPath);
      FRestored := True;
      // F2-2: .bak -> ana dosya rename'i de dizin girdisi olusturur
      if not VDbFlushDir(FDir) then
        FDirSyncFailed := True;
    end;
    // 2026-10-04: Dosya paylasim ihlali (ERROR_SHARING_VIOLATION = 32)
    // icin TFileStream.Create ham bir EFOpenError firlatir ve bu hata
    // EVDbException DEGILDIR. Boylece "dosya baska islemde acik" durumu
    // cagirana anlamsiz bir dosya hatasi olarak gidiyordu; ayrica motorun
    // kendi kilit kontrolune (satir 850) hic ULAASILAMADIYOR.
    // Simdi paylasim ihlali yakalanip kendi hata kodumuza cevriliyor.
    try
      if FileExists(FPath) then
        FS := TFileStream.Create(FPath, fmOpenReadWrite)
      else
      begin
        FS := TFileStream.Create(FPath, fmCreate);
        // F2-2: YENI dosya olusturuldu. Dosya icerigi fsync edilse bile
        // dizin girdisi (dosya adi) kalici degilse, crash sonrasi dosya
        // KAYBOLUR. Bu yuzden dizin de flush edilir.
        FNewFile := True;
      end;
    except
      on E: Exception do
      if VDbIsSharingViolation(E) then
      begin
        raise EVDbException.Create(ecDatabaseLocked,
          'VDb: dosya kullanimda (baska islem acik olabilir): ' + FPath);
      end
      else
        raise;
    end;
    FLcked := False;
    if not VDbLockStream(FS) then
    begin
      FreeAndNil(FS);
      FClosed := True;
      raise EVDbException.Create(ecDatabaseLocked, 'VDb: dosya kullanimda (baska islem acik olabilir): ' + FPath);
    end;
    FLcked := True;
    FClosed := False;
    FInBatch := False;
    FBatchOwner := 0;
    PendingClear;
    FPendingPuts.Clear;
    FPendingDels.Clear;
    { H11.1: yerinde yazim gunlugu varsa once onu uygula/at. Commit
      isareti yoksa eski baytlar geri yuklenir; ardindan normal Recover
      calisir. }
    if FileExists(VDbUndoPath(FPath)) then
      if not VDbUndoRollback(FS, VDbUndoPath(FPath), Restored) then
        raise EVDbException.Create(ecCorrupt,
          'VDb: undo gunlugu geri yuklenemedi: ' + VDbUndoPath(FPath));
    if FS.Size = 0 then
    begin
      WriteHeaderTo(FS);
      VDbFlushStream(FS);
      FDataStart := VDB_HDR_SIZE;
      // F2-2: baslik + yeni dosya -> dizin girdisi de kalici olmali
      if not VDbFlushDir(FDir) then
        FDirSyncFailed := True;
    end
    else
      DetectFormat;
    Recover;
    FDirty := False;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.Close;
begin
  FLock.Enter;
  try
    if FClosed then Exit;
    if FInBatch then AbortBatch;
    try
      if FS <> nil then VDbFlushStream(FS);
    finally
      if FLcked then
      begin
        try VDbUnlockStream(FS); except end;
        FLcked := False;
      end;
      FreeAndNil(FS);
    end;
    { 2026-10-04: Otomatik WAL durumu dosya kapanisiyla sifirlanir.
      Aksi halde ayni nesne yeniden Open edildiginde WALEnabled True
      kaliyor ve kullanicinin kapattigini sandigi gunluk sessizce
      buyuyordu. T73 'reopen sonrasi WALEnabled sifirlandi' bunu
      dogrular. }
    FWALEnabled := False;
    FWALAutoCount := 0;
    FWALWasEnabled := False;
    FClosed := True;
    // H12: kapanista blok onbellegi bosaltilir (dosya tanitici degisir).
    ClearReadCache;
    { 2026-10-05 Adim 12: kapanista master anahtar bellekte kalmasin }
    if FEncKey <> nil then
    begin
      FillChar(FEncKey[0], Length(FEncKey), 0);
      FEncKey := nil;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.Put(Key: QWord; const Value: TBytes);
var
  op: TPendOp;
  i: Integer;
begin
  FLock.Enter;
  try
    CheckOpen;
    RequireBatchWrite;
    if FInBatch then
    begin
      // Ayni key batch icinde birden fazla yazilabilir (orn. INSERT sonra
      // UPDATE ayni transaction icinde). Son yazan kazanir: eski pending
      // op once kaldirilir.
      //
      // ONCEDEN bu temizlik HER Put icinde tum listeyi basdan taraardi
      // (O(n)). Tek bir batch'e 20000 satir yazilirken O(n^2) = ~200M
      // karsilastirma olusuyor ve COMMIT ~3 SANIYE suruyordu.
      //
      // SIMDI: FPutSeen bu batch icinde o anahtara ait bir pending op
      // olustugunu soyler. Anahtar ilk kez goruluyorsa silinecek op
      // YOKTUR (PendingAdd'i yalnizca Put ve Delete cagirir ve ikisi de
      // buraya kaydeder) -> tarama kanitlanabilir bicimde atlanir.
      // Davranis bit bit ayni kalir, maliyet O(n)'e iner.
      if FPutSeen.ContainsKey(Key) then
      begin
        for i := FPending.Count - 1 downto 0 do
          if FPending[i].Key = Key then
            PendingRemove(i);
      end
      else
        FPutSeen.AddOrSetValue(Key, 0);
      op.Key := Key;
      op.Value := Value;
      op.IsDel := False;
      PendingAdd(op);
      FPendingPuts.AddOrSetValue(Key, 0);
      FPendingDels.Remove(Key);
end
    else
    begin
      // Batch disi tek yazim: kayit + BATCHEND. Boylece recovery,
      // yarim kalan tek yazimi da "gorulmemis" sayip geri sarabilir.
      //
      // GROUP COMMIT: SyncWrite=True olsa bile, SyncWriteInterval > 0 ise
      // fsync bu sure icinde toplanir. Boylece tekil yazimlar ~10-100x
      // hizlanir; en fazla SyncWriteInterval ms gecikme olur.
      AppendRec(Key, Value, False, False);
      if FSyncWrite and ((FSyncWriteInterval <= 0) or
         (GetTickCount64 - FSyncWriteLast >= QWord(FSyncWriteInterval))) then
      begin
        AppendBatchEnd(True);
        FSyncWriteLast := GetTickCount64;
      end
      else
        AppendBatchEnd(False);   // fsync ertelendi (group commit)
    end;
  finally
    FLock.Leave;
  end;
end;

const
  { P-19: konumsal hizli okumanin ust siniri. Bu boyuttan buyuk degerler
    (bozuk loc.Size) ESKI yola birakilir: orada once dosya-siniri kontrolu
    yapilir, asiri ayirma olmaz. Yalnizca HIZI etkiler, davranisi degil. }
  VDB_POSREAD_MAX = 16 * 1024 * 1024;

  { H4 (2026-10-18): mmap read yolu esikleri. Bu araligin disindaki
    taramalar mevcut konumsal/parca okuma yolunu birebir kullanir. }
  VDB_MMAP_MIN = 1 * 1024 * 1024;              // kucuk taramalar icin degmez
  VDB_MMAP_MAX = Int64(2) * 1024 * 1024 * 1024; // adres alani tavani (i386)

{$IFDEF MSWINDOWS}
type
  { Windows birimini KULLANMIYORUZ (kendi TCriticalSection'i SyncObjs'inkini
    golgeliyor); ReadFile'i dogrudan kernel32'den baglariz. Yerlesim
    Win32 OVERLAPPED ile aynidir (yalniz offset alanlari kullanilir). }
  TVDbOverlapped = record
    Internal: LongWord;
    InternalHigh: LongWord;
    Offset: LongWord;
    OffsetHigh: LongWord;
    hEvent: THandle;
  end;

function VDbReadFileRaw(hFile: THandle; lpBuffer: Pointer;
  nNumberOfBytesToRead: LongWord; lpNumberOfBytesRead: PLongWord;
  lpOverlapped: Pointer): LongBool; stdcall;
  external 'kernel32.dll' name 'ReadFile';

function VDbPosRead(H: THandle; Offset: Int64; var Buf; Count: Integer): Integer;
// P-19 (2026-10-16): KONUMSAL TEK OKUMA. Eski okuma yolu kayit basina
//   FS.Size (1 syscall) + FS.Position (1) + FS.Read (1) + FS.Read (1)
// = 4 syscall yapiyordu; olcumde 6,65 us/kayit (Defender/filtre surucusu
// dahil). Burada OVERLAPPED offset ile TEK ReadFile: senkron handle'da
// offset OVERLAPPED'tan alinir, dosya konum belirteci kullanilmaz
// (yazim yollari zaten FS.Seek(0, soEnd) ile acik konumlanir).
// Basarisizsa -1 doner; cagiran ESKI yola duser (davranis degismez).
var
  ov: TVDbOverlapped;
  n: LongWord;
begin
  if Count <= 0 then Exit(0);
  FillChar(ov, SizeOf(ov), 0);
  ov.Offset := LongWord(Offset and $FFFFFFFF);
  ov.OffsetHigh := LongWord((Offset shr 32) and $FFFFFFFF);
  n := 0;
  if not VDbReadFileRaw(H, @Buf, LongWord(Count), @n, @ov) then
    Exit(-1);
  Result := Integer(n);
end;
{$ELSE}
function VDbPosRead(H: THandle; Offset: Int64; var Buf; Count: Integer): Integer;
// Tasinabilir yol (Linux/macOS/BSD): System.FileSeek + FileRead. Bunlar
// FPC'nin KENDI THandleStream'inin kullandigi ilkellerdir (Classes),
// yani ayni ilkel uzerinde calisir; TFileStream'in Position+Read+Read
// zincirinden (3 syscall) daha az is yapar. Windows'ta OVERLAPPED yolu
// (1 syscall) secilir. Basarisizsa -1 -> cagiran ESKI yola duser.
var
  n: Integer;
begin
  if Count <= 0 then Exit(0);
  if FileSeek(H, Offset, 0) < 0 then Exit(-1);
  n := FileRead(H, Buf, Count);
  if n < 0 then Exit(-1);
  Result := n;
end;
{$ENDIF}

{ ---------------------------------------------------------------
  H4 (2026-10-18): SALT-OKUNUR DOSYA ESLEMESI (mmap read yolu)
  ---------------------------------------------------------------
  ACIK veritabani handle'i (FS.Handle) uzerinden tum dosyayi salt-okunur
  esler; bucket araligi harita icindeyse kayitlar DOGRUDAN haritadan
  verilir (kopya/syscall yok). Ayri handle ACMAYIZ: TFileStream dosyayi
  paylasimsiz actigindan ikinci bir CreateFile basarisiz olur; mevcut
  handle uzerinden mapping yeterlidir ve esleme dosya yeniden adlansa
  (Compact) bile gecerli kalir.
  Herhangi bir hata / aralik-disi / kucuk-buyuk dosyada cagiran mevcut
  konumsal okuma yoluna BIREBIR duser. POSIX'te simdilik kapali
  (Valid=False -> fallback). }

type
  TVDbFileMap = record
    Base: PByte;
    Len: Int64;
    MapHandle: THandle;   // Win: mapping; 0 = yok
    View: Pointer;
    Valid: Boolean;
  end;

{$IFDEF MSWINDOWS}
const
  VDB_PAGE_READONLY  = $02;
  VDB_FILE_MAP_READ  = $0004;

function VDbGetFileSize(hFile: THandle; lpFileSizeHigh: PLongWord): LongWord;
  stdcall; external 'kernel32.dll' name 'GetFileSize';
function VDbCreateFileMappingA(hFile: THandle; lpFileMappingAttributes: Pointer;
  flProtect, dwMaximumSizeHigh, dwMaximumSizeLow: LongWord; lpName: PChar): THandle;
  stdcall; external 'kernel32.dll' name 'CreateFileMappingA';
function VDbMapViewOfFile(hFileMappingObject: THandle; dwDesiredAccess: LongWord;
  dwFileOffsetHigh, dwFileOffsetLow, dwNumberOfBytesToMap: LongWord): Pointer;
  stdcall; external 'kernel32.dll' name 'MapViewOfFile';
function VDbUnmapViewOfFile(lpBaseAddress: Pointer): LongBool;
  stdcall; external 'kernel32.dll' name 'UnmapViewOfFile';
function VDbCloseHandle(hObject: THandle): LongBool;
  stdcall; external 'kernel32.dll' name 'CloseHandle';
{$ENDIF}

function VDbMapFileHandle(hFile: THandle; MaxBytes: Int64): TVDbFileMap;
{$IFDEF MSWINDOWS}
var
  szLo, szHi: LongWord;
  ml: Int64;
{$ENDIF}
begin
  Result.Base := nil; Result.Len := 0; Result.MapHandle := 0;
  Result.View := nil; Result.Valid := False;
  {$IFDEF MSWINDOWS}
  if (hFile = 0) or (hFile = THandle(-1)) then Exit;
  szLo := VDbGetFileSize(hFile, @szHi);
  ml := (Int64(szHi) shl 32) or Int64(szLo);
  if (ml <= 0) or ((MaxBytes > 0) and (ml > MaxBytes)) then Exit;
  Result.MapHandle := VDbCreateFileMappingA(hFile, nil, VDB_PAGE_READONLY, 0, 0, nil);
  if Result.MapHandle = 0 then Exit;
  Result.View := VDbMapViewOfFile(Result.MapHandle, VDB_FILE_MAP_READ, 0, 0, 0);
  if Result.View = nil then
  begin
    VDbCloseHandle(Result.MapHandle);
    Result.MapHandle := 0;
    Exit;
  end;
  Result.Base := PByte(Result.View);
  Result.Len := ml;
  Result.Valid := True;
  {$ENDIF}
end;

procedure VDbCloseFileMap(var M: TVDbFileMap);
begin
  {$IFDEF MSWINDOWS}
  if M.View <> nil then VDbUnmapViewOfFile(M.View);
  if M.MapHandle <> 0 then VDbCloseHandle(M.MapHandle);
  {$ENDIF}
  M.View := nil; M.Base := nil; M.MapHandle := 0; M.Len := 0; M.Valid := False;
end;

{ ---------------------------------------------------------------
  H12 (2026-10-18): SINIRLI BLOK ONBELLEGI (CLOCK)
  --------------------------------------------------------------- }

procedure TVDb.SetReadCacheBlocks(BlockCount: Integer);
var
  i: Integer;
begin
  if BlockCount < 0 then BlockCount := 0;
  FCacheLock.Enter;
  try
    FCacheMaxBlocks := BlockCount;
    FCacheHand := 0;
    FCacheHits := 0;
    FCacheMisses := 0;
    FCacheMap.Clear;
    SetLength(FCacheSlots, BlockCount);
    for i := 0 to BlockCount - 1 do
      FCacheSlots[i].Blk := -1;
  finally
    FCacheLock.Leave;
  end;
end;

function TVDb.ReadCacheBlocks: Integer;
begin
  FCacheLock.Enter;
  try
    Result := FCacheMaxBlocks;
  finally
    FCacheLock.Leave;
  end;
end;

procedure TVDb.SetReadMapEnabled(AValue: Boolean);
begin
  FReadMapEnabled := AValue;
end;

function TVDb.ReadMapEnabled: Boolean;
begin
  Result := FReadMapEnabled;
end;

function TVDb.ReadMapOpens: Int64;
begin
  Result := FMmapOpens;
end;

procedure TVDb.ClearReadCache;
var
  i: Integer;
begin
  FCacheLock.Enter;
  try
    for i := 0 to Length(FCacheSlots) - 1 do
    begin
      FCacheSlots[i].Blk := -1;
      FCacheSlots[i].Ref := False;
      FCacheSlots[i].Data := nil;
    end;
    FCacheMap.Clear;
    FCacheHand := 0;
  finally
    FCacheLock.Leave;
  end;
end;

procedure TVDb.GetReadCacheStats(out Hits, Misses: Int64;
  out UsedBlocks, MaxBlocks: Integer);
begin
  FCacheLock.Enter;
  try
    Hits := FCacheHits;
    Misses := FCacheMisses;
    MaxBlocks := FCacheMaxBlocks;
    UsedBlocks := FCacheMap.Count;
  finally
    FCacheLock.Leave;
  end;
end;

procedure TVDb.CacheInvalidateAt(Offset: Int64; Len: Integer);
var
  b0, b1: Int64;
  i: Integer;
begin
  if (FCacheMaxBlocks <= 0) or (Len <= 0) then Exit;
  b0 := Offset div FCacheBlock;
  b1 := (Offset + Len - 1) div FCacheBlock;
  FCacheLock.Enter;
  try
    for i := 0 to Length(FCacheSlots) - 1 do
      if (FCacheSlots[i].Blk >= b0) and (FCacheSlots[i].Blk <= b1) then
      begin
        FCacheMap.Remove(FCacheSlots[i].Blk);
        FCacheSlots[i].Blk := -1;
        FCacheSlots[i].Ref := False;
        FCacheSlots[i].Data := nil;
      end;
  finally
    FCacheLock.Leave;
  end;
end;

function TVDb.CacheGetBlock(Blk: Int64; out Data: TBytes): Boolean;
// Bir TAM blogu (FCacheBlock bayt) dondurur; yoksa dosyadan okuyup
// onbellege alir. Kismi blok (dosya sonu) veya kapali onbellek -> False.
// Onbellek tutamaclari TBytes oldugundan, tahliye edilse bile donen
// referans cagiran boyunca GECERLI kalir (referans sayimi).
var
  i, n, victim, scanned: Integer;
  tmp: TBytes;
begin
  Data := nil;
  Result := False;
  if (FCacheMaxBlocks <= 0) or (Blk < 0) then Exit;

  // 1. Arama (kilit altinda; O(1) hash; hit'te syscall YOK)
  FCacheLock.Enter;
  try
    if FCacheMap.TryGetValue(Blk, i) then
    begin
      FCacheSlots[i].Ref := True;
      Inc(FCacheHits);
      Data := FCacheSlots[i].Data;
      Exit(True);
    end;
    Inc(FCacheMisses);
  finally
    FCacheLock.Leave;
  end;

  // 2. Miss: blogu KILIT DISINDA oku (paralel okuyuculari serilestirmemek icin)
  SetLength(tmp, FCacheBlock);
  if VDbPosRead(FS.Handle, Blk * FCacheBlock, tmp[0], FCacheBlock)
       <> FCacheBlock then
    Exit(False);   // kismi blok / okuma hatasi -> onbelleklenmez

  // 3. Yerlestir (tekrar kontrol + CLOCK tahliyesi)
  FCacheLock.Enter;
  try
    if FCacheMap.TryGetValue(Blk, i) then
    begin   // arada baska is parcacigi doldurdu -> onunki kullan
      FCacheSlots[i].Ref := True;
      Data := FCacheSlots[i].Data;
      Exit(True);
    end;
    n := Length(FCacheSlots);
    if n <= 0 then Exit(False);
    victim := -1;
    scanned := 0;
    while (victim < 0) and (scanned < 2 * n) do
    begin
      if FCacheHand >= n then FCacheHand := 0;
      if FCacheSlots[FCacheHand].Blk < 0 then
        victim := FCacheHand
      else if FCacheSlots[FCacheHand].Ref then
      begin
        FCacheSlots[FCacheHand].Ref := False;
        FCacheHand := (FCacheHand + 1) mod n;
        Inc(scanned);
      end
      else
        victim := FCacheHand;
    end;
    if victim < 0 then
      victim := FCacheHand mod n;
    if FCacheSlots[victim].Blk >= 0 then
      FCacheMap.Remove(FCacheSlots[victim].Blk);
    FCacheSlots[victim].Blk := Blk;
    FCacheSlots[victim].Data := tmp;
    FCacheSlots[victim].Ref := True;
    FCacheMap.AddOrSetValue(Blk, victim);
    FCacheHand := (victim + 1) mod n;
    Data := tmp;
    Result := True;
  finally
    FCacheLock.Leave;
  end;
end;

function TVDb.CacheFill(Offset: Int64; Need: Integer; Dest: PByte): Boolean;
// [Offset, Offset+Need) araligini onbellekten doldurur. Need <= FCacheBlock
// olmali (kayit en fazla bir bloga sigar; bu yuzden en fazla 2 blok gerekir).
// Herhangi bir blok onbellekte yoksa False doner ve cagiran ESKI yola duser.
var
  done, take: Integer;
  absOff, blk, off: Int64;
  pb: TBytes;
begin
  Result := False;
  if (FCacheMaxBlocks <= 0) or (Need <= 0) or (Need > FCacheBlock) then Exit;
  done := 0;
  while done < Need do
  begin
    absOff := Offset + done;
    blk := absOff div FCacheBlock;
    off := absOff - blk * FCacheBlock;
    take := FCacheBlock - Integer(off);
    if take > Need - done then take := Need - done;
    if not CacheGetBlock(blk, pb) then Exit;
    Move(pb[off], Dest[done], take);
    Inc(done, take);
  end;
  Result := True;
end;

function TVDb.Get(Key: QWord; out Value: TBytes): Boolean;
begin
  // R-01 MVCC: batch icinde transaction snapshot'indan oku; batch disi eski Get davranisi (High(QWord) = her sey gorunur)
  if BatchIsMine and (FSnapshotSeq > 0) then
    Result := GetSnapshot(Key, Value, FSnapshotSeq)
  else
    Result := GetSnapshot(Key, Value, High(QWord));
end;
function TVDb.Exists(Key: QWord): Boolean;
// Dosyaya dokunmadan net durum: pending + index birlikte.
begin
  // R-01 MVCC: batch icinde transaction snapshot'indan kontrol et; batch disi eski davranis (High(QWord))
  if BatchIsMine and (FSnapshotSeq > 0) then
    Result := ExistsSnapshot(Key, FSnapshotSeq)
  else
    Result := ExistsSnapshot(Key, High(QWord));
end;

{ ---------------------------------------------------------------
  MVCC / Snapshot Isolation (R-01) Implementation
  --------------------------------------------------------------- }

function TVDb.IsVisible(const Loc: TDbLoc; SnapshotSeq: QWord): Boolean;
// Gorunurluk kurali: kaydin Seq <= SnapshotSeq ise gorunur.
// Tombstone (DEL kaydi) da Seq tasirir; Seq <= SnapshotSeq ise
// o snapshot icin 'silinmis' sayilir (GetSnapshot False doner).
begin
  Result := (Loc.Seq <= SnapshotSeq);
end;

function TVDb.GetSnapshot(Key: QWord; out Value: TBytes; SnapshotSeq: QWord): Boolean;
// Kilitsiz (lock-free) snapshot okuma.
// SnapshotSeq = FSeq (mevcut Get/Exists icin) veya transaction baslangic Seq'i.
var
  loc: TDbLoc;
  h: TVDbRecHead;
  op: TPendOp;
  fsize: Int64;
  nRead: Integer;
  need: Integer;
  scratch: TBytes;
  plainBuf: TBytes;
  inBatchVisible: Boolean;
begin
  Result := False;
  SetLength(Value, 0);
  // Not: FLock ALINMAZ - bu kilitsiz okuma.
  // FClosed kontrolu yeterli (atomik okuma icin).
  if FClosed then
    raise EVDbException.Create(ecDatabaseNotOpen, 'VDb: once Open cagir');

  // 1. Batch icindeyse: pending ops snapshot Seq'sine gore gorunur mu?
  inBatchVisible := False;
  if BatchIsMine and FindPending(Key, op) then
  begin
    // Pending op gorunur ise: op'nin mantiksel Seq'si FSeq+1'dir (henuz commit edilmemis).
    // SnapshotSeq >= FSeq+1 ise gorunur, degilse gorunmez.
    // Pratikte: transaction icindeki okuma (SnapshotSeq = transaction baslangic Seq)
    // kendi yazdigi veriyi gormeli -> SnapshotSeq = FSeq (batch baslangic) degil,
    // SnapshotSeq = FSeq + 1 (veya buyuk) olmali.
    // TVTableDb.BeginBatch FSnapshotSeq := FKv.FSeq yapar; transaction icinde
    // kendi yazdiklarini gormesi icin GetSnapshot cagirildiginda
    // SnapshotSeq = FSnapshotSeq + 1 (veya High(QWord)) gonderilmeli.
    // Basit kural: pending op her zaman 'gelecekte' (Seq > FSeq), dolayisiyle
    // SnapshotSeq >= FSeq+1 ise gorunur.
    if (SnapshotSeq > FSeq) and (not op.IsDel) then
    begin
      Value := Copy(op.Value, 0, Length(op.Value));
      Exit(True);
    end;
    // Pending DEL veya SnapshotSeq <= FSeq -> gorunmez
    Exit(False);
  end;

  // 2. Commit edilmis veriler (FIndex) icin gorunurluk kontrolu
  if not FIndex.TryGetValue(Key, loc) then Exit;
  if not IsVisible(loc, SnapshotSeq) then Exit;

  // 3/4/5/6. Okuma — P-19 (2026-10-16): HIZLI YOL tek konumsal ReadFile,
  //   yedek ESKI yol birebir. Siniflandirma SIRASI ve mesajlari eski ile
  //   ayni: (dosya disinda) -> (baslik eksik) -> (index/data uyusmazligi)
  //   -> (DEL) -> (deger eksik). Hizli yol yalnizca okuma basariliysa
  //   kullanilir; platform/aralik sapmasinda ESKI yol aynen calisir.
  need := -1;
  if (loc.Offset >= 0) and (loc.Size >= 0) and (loc.Size <= VDB_POSREAD_MAX) then
  begin
    need := SizeOf(h) + loc.Size;
    SetLength(scratch, need);
    // H12: once sinirli blok onbellegi. Onbellek HIT'i syscall yapmaz.
    // Kayit en fazla FCacheBlock ise denenir (en fazla 2 blok). Onbellekte
    // yoksa/kismi bloksa CacheFill False doner -> ESKI konumsal yol birebir.
    if CacheFill(loc.Offset, need, PByte(@scratch[0])) then
      nRead := need
    else
    begin
      nRead := VDbPosRead(FS.Handle, loc.Offset, scratch[0], need);
      if nRead < 0 then
        need := -1;   // basarisiz -> ESKI yol
    end;
  end;

  if need >= 0 then
  begin
    // ---- HIZLI YOL ----
    if nRead < SizeOf(h) then
    begin
      fsize := FS.Size;
      if loc.Offset + Int64(SizeOf(h)) + Int64(loc.Size) > fsize then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: index kaydi dosya disinda (key=%d offset=%d size=%d dosya=%d)',
          [Key, loc.Offset, loc.Size, fsize]);
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit basligi eksik (key=%d, okunan=%d)', [Key, nRead]);
    end;
    Move(scratch[0], h, SizeOf(h));
    if (h.Magic <> VDB_MAGIC) or (h.Key <> Key) or (h.ValLen <> loc.Size) then
      raise EVDbException.Create(ecCorrupt, 'VDb: index/data uyusmazligi');
    if (h.Flags and VDB_FLAG_DEL) <> 0 then Exit(False);
    if nRead < need then
    begin
      fsize := FS.Size;
      if loc.Offset + Int64(SizeOf(h)) + Int64(loc.Size) > fsize then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: index kaydi dosya disinda (key=%d offset=%d size=%d dosya=%d)',
          [Key, loc.Offset, loc.Size, fsize]);
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit degeri eksik (key=%d, okunan=%d beklenen=%d)',
        [Key, nRead - SizeOf(h), loc.Size]);
    end;
    SetLength(Value, loc.Size);
    if loc.Size > 0 then
      Move(scratch[SizeOf(h)], Value[0], loc.Size);
  end
  else
  begin
    // ---- ESKI YOL (birebir; davranis referansi) ----
    // 3. Guvenlik kontrolu (Get ile ayni)
    fsize := FS.Size;
    if (loc.Offset < 0) or
       (loc.Offset + Int64(SizeOf(h)) + Int64(loc.Size) > fsize) then
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: index kaydi dosya disinda (key=%d offset=%d size=%d dosya=%d)',
        [Key, loc.Offset, loc.Size, fsize]);

    // 4. Kayit basligini oku ve dogrula
    FS.Position := loc.Offset;
    nRead := FS.Read(h, SizeOf(h));
    if nRead <> SizeOf(h) then
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit basligi eksik (key=%d, okunan=%d)', [Key, nRead]);
    if (h.Magic <> VDB_MAGIC) or (h.Key <> Key) or (h.ValLen <> loc.Size) then
      raise EVDbException.Create(ecCorrupt, 'VDb: index/data uyusmazligi');

    // 5. DELETED kayit kontrolu (tombstone)
    if (h.Flags and VDB_FLAG_DEL) <> 0 then Exit(False);

    // 6. Degeri oku
    SetLength(Value, loc.Size);
    if loc.Size > 0 then
    begin
      nRead := FS.Read(Value[0], loc.Size);
      if nRead <> loc.Size then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: kayit degeri eksik (key=%d, okunan=%d beklenen=%d)',
          [Key, nRead, loc.Size]);
    end;
  end;

  // 7. Sifreleme cozme (Get ile ayni mantik)
  if (h.Flags and VDB_FLAG_ENCRYPTED) <> 0 then
  begin
    plainBuf := nil;
    if not DecryptValue(Value, plainBuf) then
    begin
      if Length(Value) > 0 then FillChar(Value[0], Length(Value), 0);
      SetLength(Value, 0);
      if Length(FEncKey) <> VDB_KEY_LEN then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: kayit SIFRELI: anahtar yok. Once OpenKeyFile/SetEncryptionKey. key=%d',
          [Key]);
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit cozulemedi (anahtar yanlis veya veri bozulmus) key=%d',
        [Key]);
    end;
    Value := plainBuf;
  end;

  Result := True;
end;

function TVDb.ExistsSnapshot(Key: QWord; SnapshotSeq: QWord): Boolean;
// Kilitsiz snapshot varlik kontrolu.
var
  loc: TDbLoc;
  op: TPendOp;
begin
  Result := False;
  if FClosed then
    raise EVDbException.Create(ecDatabaseNotOpen, 'VDb: once Open cagir');

  // Batch icindeki pending ops (yalniz batch sahibi oturum gorur)
  if BatchIsMine and FindPending(Key, op) then
  begin
    if (SnapshotSeq > FSeq) and (not op.IsDel) then Exit(True);
    Exit(False);
  end;

  // Commit edilmis veriler
  if not FIndex.TryGetValue(Key, loc) then Exit;
  if not IsVisible(loc, SnapshotSeq) then Exit;

  // Tombstone kontrolu: index'te DEL bayragi varsa veya bayrak DEL ise
  if (loc.Flags and VDB_FLAG_DEL) <> 0 then Exit(False);

  Result := True;
end;

  procedure TVDb.ClearTableKeys;
  // KR-1: tablo anahtar dizinindeki tum listeleri serbest birakir.
  var
    lst: TList<QWord>;
  begin
    for lst in FTableKeys.Values do
      lst.Free;
    FTableKeys.Clear;
    FTableKeysDirty := False;
  end;

  procedure TVDb.RebuildTableKeys;
  // KR-1: FIndex'i BIR KEZ dolasarak tablo id -> anahtar listesi kurar.
  // Etiketsiz kayitlar (TableId < 0; sema kaydi) -1 anahtari altinda
  // toplanir ve her tablo taramasinda (R-26 gibi) elenmez.
  var
    pair: TPair<QWord, TDbLoc>;
    lst: TList<QWord>;
    tid: Integer;
  begin
    ClearTableKeys;
    FTableKeysDirty := False;
    if @FRowTagFunc = nil then Exit;   // ham KV: filtre yok, dizin gerekmez
    for pair in FIndex do
    begin
      tid := pair.Value.TableId;
      if tid < 0 then tid := -1;
      if not FTableKeys.TryGetValue(tid, lst) then
      begin
        lst := TList<QWord>.Create;
        FTableKeys.Add(tid, lst);
      end;
      lst.Add(pair.Key);
    end;
  end;

  function TVDb.TryGetTableRowCount(TableId: Integer; out Value: Int64): Boolean;
  // KR-1B: dogrulanmis COUNT cache'ini oku. Kilit altinda (yazicilarla tutarli).
  // Cache yoksa False -> cagiran dogrulamali taramayi yapar, sonra doldurur.
  begin
    FLock.Enter;
    try
      Result := FTableRowCount.TryGetValue(TableId, Value);
    finally
      FLock.Leave;
    end;
  end;

  procedure TVDb.SetTableRowCount(TableId: Integer; Value: Int64);
  // KR-1B: dogrulanmis COUNT degerini cache'e yazar. Cagiran yurutucu autocommit
  // oldugundan emindir; Value bir onceki DOGRULAMALI taramanin (stream-agg)
  // sonucudur -- bu yuzden etiket/reopen kaynakli -1 sorunu sayimi etkilemez.
  begin
    FLock.Enter;
    try
      FTableRowCount.AddOrSetValue(TableId, Value);
    finally
      FLock.Leave;
    end;
  end;

  procedure TVDb.SetRowTagFunc(AValue: TVDbRowTagFunc);
  begin
    FRowTagFunc := AValue;
    FTableKeysDirty := True;   // dizin yeni etiketleyiciyle yeniden kurulmali
    FTableRowCount.Clear;
  end;

  procedure TVDb.ScanSnapshot(out Keys: TQWordArray; out Vals: TValArray;
    SnapshotSeq: QWord; Limit: Integer; TableFilter: Integer);
  // Kilitsiz snapshot tum tarama. Limit > 0 ise en fazla Limit kayit dondurur.
  // R-26: TableFilter >= 0 ise FIndex'teki TableId ile ONCE elenir; ele
  // gecmeyen kayit icin dosya hic acilmaz (eski hali: tum KV okunuyordu).
  // KR-1: TableFilter >= 0 ise ayrica FIndex YERINE yalnizca hedef tablonun
  // anahtar dizini dolanilir (karisik DB'de O(toplam) -> O(tablo)).
  // P-13 (2026-10-16): kayit basina 3 syscall (Position+Read+Read) yerine
  // gorunur adaylar once toplanir, dosya 2 MB'lik bucket araliklarinda
  // TEK okumayla taranir. Cikti sirasi eski枚举 ile BIREBIR aynidir:
  // her aday eski sira numarasini (Slot) tasir; basarisiz slotlar sonda
  // sikistirilir (eski Continue semantigi). }
const
  VDB_SCAN_BUCKET = 21;                  // 2 MB'lik bucket araligi
  VDB_SCAN_CHUNK_CAP = 4 * 1024 * 1024;  // tek okuma ust siniri (asirsiz
                                         // bucket'ta kayit-bazina donulur)
type
  TScanCand = record
    Off: Int64;
    Size: LongWord;
    Slot: Integer;   // eski enumeration sirasindaki yeri
  end;
var
  fsize: Int64;
  pair: TPair<QWord, TDbLoc>;
  h: TVDbRecHead;
  n, np: Integer;
  op: TPendOp;
  pendKeys: TDictionary<QWord, Byte>;
  pendDels: TDictionary<QWord, Byte>; // pending DEL -> index'deki satir gorunmemeli
  count: Integer;
  // P-13 toplu okuma durumdizileri
  cands: array of TScanCand;
  kept: array of Byte;
  bBeg, bCur: array of Integer;
  bLo, bHi: array of Int64;
  order: array of Integer;
  chunk: TBytes;
  candCnt, keptCnt, bucket, m, n2, bCount: Integer;
  lo, hi, span, endOff, bucket64: Int64;
  got, p: Integer;
  // KR-1: hedef-tablo anahtar dizini dolasim durumu
  stop: Boolean;
  tloc: TDbLoc;
  tl: TList<QWord>;

  procedure DecryptIfNeeded(var V: TBytes; Flags: Byte; RecKey: QWord);
  var
    plain: TBytes;
  begin
    if (Flags and VDB_FLAG_ENCRYPTED) = 0 then Exit;
    plain := nil;
    if not DecryptValue(V, plain) then
    begin
      if Length(FEncKey) <> VDB_KEY_LEN then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: kayit SIFRELI: anahtar yok. Once OpenKeyFile/SetEncryptionKey. key=%d',
          [RecKey]);
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit cozulemedi (anahtar yanlis veya veri bozulmus) key=%d',
        [RecKey]);
    end;
    V := plain;
  end;

  // KR-1/R-26: aday eleme govdesi. Filtre karari cagiran tarafta verilir:
  // filtresiz yol tum FIndex'i gezer, filtreli yol YALNIZCA hedef tablonun
  // anahtar dizinini (ve etiketsiz kayitlari) gezer.
  procedure Consider(const K: QWord; const L: TDbLoc);
  begin
    if stop then Exit;
    if (Limit > 0) and (count >= Limit) then
    begin
      stop := True;
      Exit;
    end;
    // Gorunurlilik kontrolu
    if not IsVisible(L, SnapshotSeq) then Exit;
    // Tombstone kontrolu
    if (L.Flags and VDB_FLAG_DEL) <> 0 then Exit;
    // Guvenlik kontrolu
    if (L.Offset < 0) or
       (L.Offset + Int64(SizeOf(h)) + Int64(L.Size) > fsize) then
      Exit;
    // Pending ile cakisma kontrolu
    if pendKeys.ContainsKey(K) then Exit;
    if pendDels.ContainsKey(K) then Exit;

    Keys[count] := K;
    cands[candCnt].Off := L.Offset;
    cands[candCnt].Size := L.Size;
    cands[candCnt].Slot := count;
    Inc(count);
    Inc(candCnt);
  end;
begin
  if FClosed then
    raise EVDbException.Create(ecDatabaseNotOpen, 'VDb: once Open cagir');

  fsize := FS.Size;
  pendKeys := TDictionary<QWord, Byte>.Create;
  pendDels := TDictionary<QWord, Byte>.Create;
  try
    // Batch icindeki pending ops: SnapshotSeq > FSeq ise gorunur
    if BatchIsMine and (SnapshotSeq > FSeq) then
      for n := 0 to FPending.Count - 1 do
        if FPending[n].IsDel then
          pendDels.AddOrSetValue(FPending[n].Key, 0)
        else
          pendKeys.AddOrSetValue(FPending[n].Key, 0);

    // Tahmini boyut: index + pending puts
    SetLength(Keys, FIndex.Count + pendKeys.Count);
    SetLength(Vals, FIndex.Count + pendKeys.Count);
    count := 0;

    // ---- P-13 PAS A: gorunur adaylari topla (dosyaya hic dokunmaz) ----
    // Eleme kurallari ve SIRASI eski kodla birebir aynidir; tek fark:
    // okuma yerine (Offset, Size, Slot) kaydedilir. Slot = eski count
    // degeri oldugu icin cikti dizisinin anlami ve SIRASI degismez.
    // NOT: Limit>0 (su an hic cagiran yok) basari degil ADAY sayar;
    // bozuk kayitli dosyada Limit'in azasi donebilir - belgelenmis fark.
    SetLength(cands, FIndex.Count);
    SetLength(kept, FIndex.Count);   // 0 = basarisiz slot (sonra sikistirilir)
    candCnt := 0;
    stop := False;
    if TableFilter >= 0 then
    begin
      // KR-1: YALNIZCA hedef tablonun anahtarlari (O(tablo), O(toplam) degil).
      if FTableKeysDirty then RebuildTableKeys;
      if FTableKeys.TryGetValue(TableFilter, tl) then
        for n := 0 to tl.Count - 1 do
        begin
          if stop then Break;
          if FIndex.TryGetValue(tl[n], tloc) then Consider(tl[n], tloc);
        end;
      // R-26: TableId < 0 (sema kaydi) hicbir filtrede elenmez.
      if (not stop) and FTableKeys.TryGetValue(-1, tl) then
        for n := 0 to tl.Count - 1 do
        begin
          if stop then Break;
          if FIndex.TryGetValue(tl[n], tloc) then Consider(tl[n], tloc);
        end;
    end
    else
      for pair in FIndex do
        Consider(pair.Key, pair.Value);

    // ---- P-13 PAS B: bucket sayim-donusturmesi (counting sort, O(N)) ----
    // Kayitlar dosya offset'ine gore gruplanir; her bucket bir KEZ
    // okunur. (Eski kod: kayit basina Position + 2 ReadBuffer = 3 syscall;
    // 1M satirlik taramada ~7 sn'nin tamamı buydu.)
    keptCnt := 0;
    if candCnt > 0 then
    begin
      bCount := Integer((fsize shr VDB_SCAN_BUCKET) + 1);
      if bCount > 8192 then bCount := 8192;   // ~16 GB'a kadar 2 MB grid
      SetLength(bLo, bCount); SetLength(bHi, bCount);
      for n := 0 to bCount - 1 do begin bLo[n] := High(Int64); bHi[n] := 0; end;
      SetLength(bBeg, bCount + 1);
      for n := 0 to bCount do bBeg[n] := 0;
      for n := 0 to candCnt - 1 do
      begin
        bucket64 := cands[n].Off shr VDB_SCAN_BUCKET;
        if bucket64 >= bCount then bucket := bCount - 1
        else bucket := Integer(bucket64);
        Inc(bBeg[bucket + 1]);
        endOff := cands[n].Off + Int64(SizeOf(h)) + Int64(cands[n].Size);
        if cands[n].Off < bLo[bucket] then bLo[bucket] := cands[n].Off;
        if endOff > bHi[bucket] then bHi[bucket] := endOff;
      end;
      for n := 1 to bCount do Inc(bBeg[n], bBeg[n - 1]);  // prefix baslangic
      bCur := Copy(bBeg);                                 // dagitim imleci
      SetLength(order, candCnt);
      for n := 0 to candCnt - 1 do
      begin
        bucket64 := cands[n].Off shr VDB_SCAN_BUCKET;
        if bucket64 >= bCount then bucket := bCount - 1
        else bucket := Integer(bucket64);
        order[bCur[bucket]] := n;
        Inc(bCur[bucket]);                                // bCur[b] = bitis
      end;

      // ---- P-13 PAS C: bucket basina TEK dosya okuması ----
      for bucket := 0 to bCount - 1 do
      begin
        if bCur[bucket] <= bBeg[bucket] then Continue;    // bos bucket
        lo := bLo[bucket]; hi := bHi[bucket]; span := hi - lo;
        got := -1;
        if span <= VDB_SCAN_CHUNK_CAP then
        begin
          if Length(chunk) < Integer(span) then SetLength(chunk, Integer(span));
          // H14: konumsal (paylasimsiz) okuma; FS.Position paralel
          // taramalarda yaris durumudur.
          if VDbPosRead(FS.Handle, lo, chunk[0], Integer(span)) =
             Integer(span) then
            got := Integer(span);
        end;
        for m := bBeg[bucket] to bCur[bucket] - 1 do
        begin
          n2 := order[m];
          if got >= 0 then
            Move(chunk[Integer(cands[n2].Off - lo)], h, SizeOf(h))
          else
          begin
            // Asiri buyuk bucket / kismi okuma: kayit-bazi konumsal yol
            if VDbPosRead(FS.Handle, cands[n2].Off, h, SizeOf(h)) <>
               SizeOf(h) then
              Continue;
          end;
          // Eski davranisla birebir: magic/anahtar/uzunluk/DEL uyumsuzsa
          // kayit SESSIZ atlanir (slot bos kalir, sonda sikistirilir).
          if (h.Magic <> VDB_MAGIC) or (h.Key <> Keys[cands[n2].Slot]) or
             (h.ValLen <> cands[n2].Size) or
             ((h.Flags and VDB_FLAG_DEL) <> 0) then
            Continue;
          SetLength(Vals[cands[n2].Slot], cands[n2].Size);
          if cands[n2].Size > 0 then
          begin
            if got >= 0 then
            begin
              p := Integer(cands[n2].Off - lo) + SizeOf(h);
              Move(chunk[p], Vals[cands[n2].Slot][0], cands[n2].Size);
            end
            else if VDbPosRead(FS.Handle,
              cands[n2].Off + SizeOf(h), Vals[cands[n2].Slot][0],
              cands[n2].Size) <> cands[n2].Size then
              Continue;
          end;
          DecryptIfNeeded(Vals[cands[n2].Slot], h.Flags, Keys[cands[n2].Slot]);
          kept[cands[n2].Slot] := 1;
          Inc(keptCnt);
        end;
      end;

      // Basarisiz slotlar (bozuk/bayrakli) cikarilir — eski Continue
      // semantiginin dizideki karsiligi.
      if keptCnt < count then
      begin
        n2 := 0;
        for n := 0 to count - 1 do
          if kept[n] = 1 then
          begin
            if n2 <> n then begin Keys[n2] := Keys[n]; Vals[n2] := Vals[n]; end;
            Inc(n2);
          end;
        count := n2;
      end;
    end;

    // 2. Batch icindeki pending PUT'lar (SnapshotSeq > FSeq ise)
    if BatchIsMine and (SnapshotSeq > FSeq) then
    begin
      for n := 0 to FPending.Count - 1 do
      begin
        if (Limit > 0) and (count >= Limit) then Break;
        op := FPending[n];
        if op.IsDel then Continue;
        // Zaten index'te varsa ve pendKeys'te isaretlendiyse atlandi
        if pendKeys.ContainsKey(op.Key) then
        begin
          Keys[count] := op.Key;
          SetLength(Vals[count], Length(op.Value));
          if Length(op.Value) > 0 then
            Move(op.Value[0], Vals[count][0], Length(op.Value));
          Inc(count);
        end;
      end;
    end;

    SetLength(Keys, count);
    SetLength(Vals, count);
  finally
    pendKeys.Free;
    pendDels.Free;
  end;
end;

function TVDb.ScanRawIter(SnapshotSeq: QWord; TableFilter: Integer;
  Cb: TVDbRawCb; User: Pointer; OffLo: Int64; OffHi: Int64;
  SkipBuckets: PByte; SkipLen: Integer; CurBucket: PInteger): Boolean;
// P-18a (2026-10-16): bkz. interface. Fazlar ScanSnapshot'tan kopyadir ve
// ELEME/SINIFLANDIRMA kurallari birebirdir; yalniz CIKTI biyimi degisir:
// adayin deger tamponu Cb'ye gosterilir, kopyalanmaz. DecryptNeededIf
// ScanSnapshot icindeki ile aynidir (kucuk yordam; paylasim yerine
// kopya — ScanSnapshot gauntlet'ten gecmis haliyle kalmasi icin).
const
  VDB_SCAN_BUCKET = VDB_RAW_SCAN_SHIFT;
  VDB_SCAN_CHUNK_CAP = 4 * 1024 * 1024;
type
  TIterCand = record
    Off: Int64;
    Size: LongWord;
    Key: QWord;
  end;
var
  fsize: Int64;
  pair: TPair<QWord, TDbLoc>;
  h: TVDbRecHead;
  n: Integer;
  op: TPendOp;
  pendKeys, pendDels: TDictionary<QWord, Byte>;
  cands: array of TIterCand;
  bBeg, bCur: array of Integer;
  bLo, bHi: array of Int64;
  order: array of Integer;
  chunk, decB, recBuf: TBytes;
  fmap: TVDbFileMap;            // H4: salt-okunur esleme (opsiyonel)
  useMap: Boolean;
  spanBase: PByte;              // H4: bucket araliginin okuma tabani
  candCnt, bucket, m, n2, bCount: Integer;
  lo, hi, span, endOff, bucket64: Int64;
  got, p: Integer;
  // KR-1: hedef-tablo anahtar dizini dolasim durumu
  tloc: TDbLoc;
  tl: TList<QWord>;

  procedure DecryptIfNeeded(var V: TBytes; Flags: Byte; RecKey: QWord);
  var
    plain: TBytes;
  begin
    if (Flags and VDB_FLAG_ENCRYPTED) = 0 then Exit;
    plain := nil;
    if not DecryptValue(V, plain) then
    begin
      if Length(FEncKey) <> VDB_KEY_LEN then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: kayit SIFRELI: anahtar yok. Once OpenKeyFile/SetEncryptionKey. key=%d',
          [RecKey]);
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit cozulemedi (anahtar yanlis veya veri bozulmus) key=%d',
        [RecKey]);
    end;
    V := plain;
  end;

  // KR-1/R-26: aday eleme govdesi (ScanSnapshot.Consider ile ayni kurallar;
  // tek fark cikti bicimi — deger kopyalanmaz, aday listesine yazilir).
  procedure Consider(const K: QWord; const L: TDbLoc);
  begin
    // H6: offset aralik filtresi. [OffLo, OffHi) disindaki adaylar bu
    // isciye ait degildir; boylece [0, DataFileSize) N parcaya bolununce
    // her kayit TAM BIR kez islenir. Varsayilan (0, High(Int64)) hepsini
    // gecirir; seri yol degismez.
    if (L.Offset < OffLo) or (L.Offset >= OffHi) then Exit;
    if not IsVisible(L, SnapshotSeq) then Exit;
    if (L.Flags and VDB_FLAG_DEL) <> 0 then Exit;
    if (L.Offset < 0) or
       (L.Offset + Int64(SizeOf(h)) + Int64(L.Size) > fsize) then
      Exit;
    if pendKeys.ContainsKey(K) then Exit;
    if pendDels.ContainsKey(K) then Exit;
    cands[candCnt].Off := L.Offset;
    cands[candCnt].Size := L.Size;
    cands[candCnt].Key := K;
    Inc(candCnt);
  end;

begin
  Result := True;
  if FClosed then
    raise EVDbException.Create(ecDatabaseNotOpen, 'VDb: once Open cagir');

  fsize := FS.Size;
  // H4 (2026-10-18): taranan dosyayi salt-okunur esle. Esleme YALNIZCA bu
  // tarama icin (yerel) ve VDB_MMAP_MIN..VDB_MMAP_MAX arasinda denenir;
  // herhangi bir hata/kucuk-buyuk dosyada mevcut okuma yolu birebir kalir.
  FillChar(fmap, SizeOf(fmap), 0);
  useMap := FReadMapEnabled and (fsize >= VDB_MMAP_MIN) and (fsize <= VDB_MMAP_MAX);
  if useMap then
  begin
    fmap := VDbMapFileHandle(FS.Handle, VDB_MMAP_MAX);
    useMap := fmap.Valid;
    if useMap then Inc(FMmapOpens);
  end;
  pendKeys := TDictionary<QWord, Byte>.Create;
  pendDels := TDictionary<QWord, Byte>.Create;
  try
    // Batch icindeki pending ops: SnapshotSeq > FSeq ise gorunur
    if BatchIsMine and (SnapshotSeq > FSeq) then
      for n := 0 to FPending.Count - 1 do
        if FPending[n].IsDel then
          pendDels.AddOrSetValue(FPending[n].Key, 0)
        else
          pendKeys.AddOrSetValue(FPending[n].Key, 0);

    // ---- PAS A: gorunur adaylari topla (dosyaya hic dokunmaz) ----
    SetLength(cands, FIndex.Count);
    candCnt := 0;
    if TableFilter >= 0 then
    begin
      // KR-1: YALNIZCA hedef tablonun anahtarlari (O(tablo), O(toplam) degil).
      if FTableKeysDirty then RebuildTableKeys;
      if FTableKeys.TryGetValue(TableFilter, tl) then
        for n := 0 to tl.Count - 1 do
          if FIndex.TryGetValue(tl[n], tloc) then Consider(tl[n], tloc);
      // R-26: TableId < 0 (sema kaydi) hicbir filtrede elenmez.
      if FTableKeys.TryGetValue(-1, tl) then
        for n := 0 to tl.Count - 1 do
          if FIndex.TryGetValue(tl[n], tloc) then Consider(tl[n], tloc);
    end
    else
      for pair in FIndex do
        Consider(pair.Key, pair.Value);

    // ---- PAS B: bucket sayim-donusturmesi (ScanSnapshot ile birebir) ----
    if candCnt > 0 then
    begin
      bCount := RawScanBucketCount(fsize);
      SetLength(bLo, bCount); SetLength(bHi, bCount);
      for n := 0 to bCount - 1 do begin bLo[n] := High(Int64); bHi[n] := 0; end;
      SetLength(bBeg, bCount + 1);
      for n := 0 to bCount do bBeg[n] := 0;
      for n := 0 to candCnt - 1 do
      begin
        bucket64 := cands[n].Off shr VDB_SCAN_BUCKET;
        if bucket64 >= bCount then bucket := bCount - 1
        else bucket := Integer(bucket64);
        Inc(bBeg[bucket + 1]);
        endOff := cands[n].Off + Int64(SizeOf(h)) + Int64(cands[n].Size);
        if cands[n].Off < bLo[bucket] then bLo[bucket] := cands[n].Off;
        if endOff > bHi[bucket] then bHi[bucket] := endOff;
      end;
      for n := 1 to bCount do Inc(bBeg[n], bBeg[n - 1]);
      bCur := Copy(bBeg);
      SetLength(order, candCnt);
      for n := 0 to candCnt - 1 do
      begin
        bucket64 := cands[n].Off shr VDB_SCAN_BUCKET;
        if bucket64 >= bCount then bucket := bCount - 1
        else bucket := Integer(bucket64);
        order[bCur[bucket]] := n;
        Inc(bCur[bucket]);
      end;

      // ---- PAS C: bucket basina TEK okuma; deger KOPYALANMAZ ----
      // H4: dosya eslenebildiyse bucket araligi DOGRUDAN haritadan verilir
      // (syscall/kopya yok). Aralik harita disinda ya da esleme yoksa
      // birebir eski konumsal okuma kullanilir.
      for bucket := 0 to bCount - 1 do
      begin
        if bCur[bucket] <= bBeg[bucket] then Continue;
        // H3: zone map "bu bolumde eslesen satir olamaz" dediyse bolumu
        // HIC OKUMA (ne ReadFile ne Cb). SkipLen disi = guvenli taraf.
        if (SkipBuckets <> nil) and (bucket < SkipLen) and
           (SkipBuckets[bucket] <> 0) then Continue;
        if CurBucket <> nil then CurBucket^ := bucket;
        lo := bLo[bucket]; hi := bHi[bucket]; span := hi - lo;
        got := -1;
        spanBase := nil;
        if useMap and (hi <= fmap.Len) then
        begin
          spanBase := fmap.Base + lo;
          got := Integer(span);
        end
        else if span <= VDB_SCAN_CHUNK_CAP then
        begin
          if Length(chunk) < Integer(span) then SetLength(chunk, Integer(span));
          // H6: konumsal okuma (OVERLAPPED) — paralel taramalarda FS.Position
          // paylasimli durumdur; VDbPosRead dosya konum belirtecine dokunmaz.
          if VDbPosRead(FS.Handle, lo, chunk[0], Integer(span)) = Integer(span) then
          begin
            got := Integer(span);
            spanBase := @chunk[0];
          end;
        end;
        for m := bBeg[bucket] to bCur[bucket] - 1 do
        begin
          n2 := order[m];
          if got >= 0 then
            Move(spanBase[Integer(cands[n2].Off - lo)], h, SizeOf(h))
          else
          begin
            // H6: konumsal (paylasimsiz) okuma.
            if VDbPosRead(FS.Handle, cands[n2].Off, h, SizeOf(h)) <> SizeOf(h) then
              Continue;
          end;
          if (h.Magic <> VDB_MAGIC) or (h.Key <> cands[n2].Key) or
             (h.ValLen <> cands[n2].Size) or
             ((h.Flags and VDB_FLAG_DEL) <> 0) then
            Continue;
          if (h.Flags and VDB_FLAG_ENCRYPTED) <> 0 then
          begin
            // Sifreli kayit: cozum yeni tampon gerektirir (nadir yol).
            SetLength(decB, cands[n2].Size);
            if cands[n2].Size > 0 then
            begin
              if got >= 0 then
                Move(spanBase[Integer(cands[n2].Off - lo) + SizeOf(h)], decB[0], cands[n2].Size)
              else
              begin
                // H6: konumsal (paylasimsiz) okuma.
                VDbPosRead(FS.Handle, cands[n2].Off + SizeOf(h), decB[0], cands[n2].Size);
              end;
            end;
            DecryptIfNeeded(decB, h.Flags, cands[n2].Key);
            if Length(decB) > 0 then
            begin
              if not Cb(cands[n2].Key, @decB[0], Length(decB), User) then Exit(False);
            end
            else if not Cb(cands[n2].Key, nil, 0, User) then Exit(False);
          end
          else if got >= 0 then
          begin
            // HIZLI YOL: chunk icindeki baytlar oldugu gibi verilir.
            p := Integer(cands[n2].Off - lo) + SizeOf(h);
            if cands[n2].Size > 0 then
            begin
              if not Cb(cands[n2].Key, spanBase + p, Integer(cands[n2].Size), User) then
                Exit(False);
            end
            else if not Cb(cands[n2].Key, spanBase + p, 0, User) then Exit(False);
          end
          else
          begin
            // Asiri buyuk bucket / kismi okuma: kayit-bazi eski yol.
            SetLength(recBuf, cands[n2].Size);
            if cands[n2].Size > 0 then
            begin
              // H6: konumsal (paylasimsiz) okuma.
              if VDbPosRead(FS.Handle, cands[n2].Off + SizeOf(h),
                recBuf[0], cands[n2].Size) <> cands[n2].Size then
                Continue;
              if not Cb(cands[n2].Key, @recBuf[0], cands[n2].Size, User) then Exit(False);
            end
            else if not Cb(cands[n2].Key, nil, 0, User) then Exit(False);
          end;
        end;
      end;
    end;

    // 2. Batch icindeki pending PUT'lar (ScanSnapshot ile ayni kume:
    //    pendKeys her pending put'i icerdiginden eski ContainsKey denetimi
    //    daima dogruydu — burada dogal olarak dusuruldu.)
    //    H6: offset parcasi YOKTUR; yalnizca ilk parcada (OffLo = 0) verilir,
    //    aksi halde N isci ayni pending satiri N kez sayardi.
    if BatchIsMine and (SnapshotSeq > FSeq) and (OffLo = 0) then
      for n := 0 to FPending.Count - 1 do
      begin
        op := FPending[n];
        if op.IsDel then Continue;
        if Length(op.Value) > 0 then
        begin
          if not Cb(op.Key, @op.Value[0], Length(op.Value), User) then Exit(False);
        end
        else if not Cb(op.Key, nil, 0, User) then Exit(False);
      end;
  finally
    pendKeys.Free;
    pendDels.Free;
    VDbCloseFileMap(fmap);   // H4: eslemeyi birak (acilmadiysa no-op)
  end;
end;

function TVDb.ScanRawIterAll(TableFilter: Integer;
  Cb: TVDbRawCb; User: Pointer): Boolean;
// ScanAll'in snapshot secim kuraliyla birebir ayni.
begin
  if BatchIsMine and (FSnapshotSeq > 0) then
    Result := ScanRawIter(FSnapshotSeq, TableFilter, Cb, User)
  else
    Result := ScanRawIter(High(QWord), TableFilter, Cb, User);
end;

class function TVDb.RawScanBucketCount(FileSize: Int64): Integer;
var
  n: Int64;
begin
  n := (FileSize shr VDB_RAW_SCAN_SHIFT) + 1;
  if n < 1 then n := 1;
  if n > VDB_RAW_SCAN_MAX_BUCKET then n := VDB_RAW_SCAN_MAX_BUCKET;
  Result := Integer(n);
end;

function TVDb.DataSeqValue: QWord;
begin
  // H3: zone map surumu — yarim yazmalari degil, TAMAMLANMIS dizin
  // guncellemelerini yansitir.
  Result := FIdxVer;
end;

function TVDb.DataEpochValue: QWord;
begin
  Result := FDataEpoch;
end;

function TVDb.ScanRawIterAllZoned(TableFilter: Integer;
  SkipBuckets: PByte; SkipLen: Integer; CurBucket: PInteger;
  Cb: TVDbRawCb; User: Pointer): Boolean;
// H3: ScanRawIterAll ile ayni snapshot kurali; yalnizca zone map'in
// atlanabilir buldugu offset bolumleri okunmaz.
begin
  if BatchIsMine and (FSnapshotSeq > 0) then
    Result := ScanRawIter(FSnapshotSeq, TableFilter, Cb, User,
      0, High(Int64), SkipBuckets, SkipLen, CurBucket)
  else
    Result := ScanRawIter(High(QWord), TableFilter, Cb, User,
      0, High(Int64), SkipBuckets, SkipLen, CurBucket);
end;

function TVDb.ScanRawIterAllRange(TableFilter: Integer; OffLo, OffHi: Int64;
  Cb: TVDbRawCb; User: Pointer): Boolean;
// H6: ScanRawIterAll ile ayni snapshot kurali; yalnizca [OffLo, OffHi)
// offset araligindaki kayit baslangiclari islenir.
begin
  if BatchIsMine and (FSnapshotSeq > 0) then
    Result := ScanRawIter(FSnapshotSeq, TableFilter, Cb, User, OffLo, OffHi)
  else
    Result := ScanRawIter(High(QWord), TableFilter, Cb, User, OffLo, OffHi);
end;

function TVDb.DataFileSize: Int64;
begin
  if FClosed or (FS = nil) then Exit(0);
  Result := FS.Size;
end;

procedure TVDb.EnsureTableKeys;
begin
  if FClosed then Exit;
  if not FTableKeysDirty then Exit;
  FLock.Enter;
  try
    if FTableKeysDirty then RebuildTableKeys;
  finally
    FLock.Leave;
  end;
end;

function TVDb.TableKeyCount(TableId: Integer): Integer;
var
  tl: TList<QWord>;
begin
  Result := 0;
  if FClosed then Exit;
  EnsureTableKeys;
  if FTableKeys.TryGetValue(TableId, tl) then Result := tl.Count;
end;

function TVDb.PrepareRawScan(TableFilter: Integer;
  out P: TVDbRawPrepared): Boolean;
// H6: bkz. interface. Iki gecisli sayim-yerlestirme (counting sort):
//   1) bucket basina aday sayisi, 2) bucket-major yerlestirme.
// Gorunurluk/eleme kurallari ScanRawIter.Consider ile BIREBIR.
const
  VDB_PREP_SHIFT = 18;   // 256 KB: paralel bolumleme icin yeterince ince
  { H6: hazir taramada dosya eslemesi. Olcumle karar verilir; buyuk
    dosyada i386 adres alanini tuketmemek icin ust sinir vardir. }
  VDB_PREP_USE_MAP = False;
  VDB_PREP_MAP_MAX = Int64(256) * 1024 * 1024;
var
  fsize: Int64;
  bCount, n, b, total, candCnt, cap: Integer;
  cur: array of Integer;
  tmpOff: array of Int64;
  tmpSize: array of LongWord;
  tmpKey: array of QWord;
  tl: TList<QWord>;
  loc: TDbLoc;
  pair: TPair<QWord, TDbLoc>;
  fmap: TVDbFileMap;
  direct: Boolean;      // FIndex'i dogrudan dolas (tablo yogunsa hizli)

  procedure Visit(const K: QWord; const L: TDbLoc);
  var
    bucket64: Int64;
    bucket: Integer;
  begin
    if not IsVisible(L, High(QWord)) then Exit;
    if (L.Flags and VDB_FLAG_DEL) <> 0 then Exit;
    if (L.Offset < 0) or
       (L.Offset + Int64(SizeOf(TVDbRecHead)) + Int64(L.Size) > fsize) then
      Exit;
    bucket64 := L.Offset shr VDB_PREP_SHIFT;
    if bucket64 >= bCount then bucket := bCount - 1
    else bucket := Integer(bucket64);
    // TEK gecis: adayi gecici duz diziye yaz + bucket say.
    if candCnt < cap then
    begin
      tmpOff[candCnt] := L.Offset;
      tmpSize[candCnt] := L.Size;
      tmpKey[candCnt] := K;
    end;
    Inc(candCnt);
    Inc(P.BucketStart[bucket + 1]);
  end;

  procedure VisitSource;
  var
    i, tid: Integer;
  begin
    if direct then
    begin
      // Tek gecis, HASH YOK: FIndex kayitlarinda TableId/offset zaten
      // yan yana. Yogun tabloda FTableKeys+TryGetValue'den ~5-10x hizli.
      for pair in FIndex do
      begin
        if TableFilter >= 0 then
        begin
          tid := pair.Value.TableId;
          // R-26: TableId < 0 (sema) hicbir filtrede elenmez.
          if (tid >= 0) and (tid <> TableFilter) then Continue;
        end;
        Visit(pair.Key, pair.Value);
      end;
    end
    else if TableFilter >= 0 then
    begin
      if FTableKeys.TryGetValue(TableFilter, tl) then
        for i := 0 to tl.Count - 1 do
          if FIndex.TryGetValue(tl[i], loc) then Visit(tl[i], loc);
      if FTableKeys.TryGetValue(-1, tl) then
        for i := 0 to tl.Count - 1 do
          if FIndex.TryGetValue(tl[i], loc) then Visit(tl[i], loc);
    end
    else
      for pair in FIndex do Visit(pair.Key, pair.Value);
  end;

begin
  Result := False;
  FillChar(P, SizeOf(P), 0);
  if FClosed then Exit;
  // Pending op'larin offset'i yoktur; paralel/parcali toplama onlari
  // yanlis sayar. Acik batch'te seri yol kullanilir.
  if FInBatch then Exit;
  EnsureTableKeys;
  // Kaynak secimi: tablo FIndex'e KOMSU ise dogrudan dolas (hash lookup
  // yok); seyrekse tablo anahtar listesi (O(tablo), O(toplam) degil).
  if TableFilter < 0 then
    direct := True
  else if not FTableKeys.TryGetValue(TableFilter, tl) then
    direct := True
  else
    direct := (Int64(tl.Count) * 3 >= FIndex.Count);
  P.BucketShift := VDB_PREP_SHIFT;
  fsize := FS.Size;
  P.FSize := fsize;
  // H6: SALT-OKUNUR esleme (istege bagli; asagidaki sabitle acilir).
  // Kucuk/orta dosyada ReadFile yolu da yeterli; esleme buyuk dosyada
  // i386 adres alanini tuketmemek icin ust sinirlidir.
  if VDB_PREP_USE_MAP and (fsize > 0) and (fsize <= VDB_PREP_MAP_MAX) then
  begin
    fmap := VDbMapFileHandle(FS.Handle, VDB_PREP_MAP_MAX);
    if fmap.Valid then
    begin
      P.MapBase := fmap.Base;
      P.MapLen := fmap.Len;
      P.MapHandle := fmap.MapHandle;
      P.MapView := fmap.View;
    end;
  end;
  bCount := Integer((fsize shr VDB_PREP_SHIFT) + 1);
  if bCount < 1 then bCount := 1;
  if bCount > 4096 then bCount := 4096;
  P.BCount := bCount;
  SetLength(P.BucketStart, bCount + 1);
  for n := 0 to bCount do P.BucketStart[n] := 0;

  // Gecici dizi kapasitesi = kaynak ust siniri (gorunurluk/eleme azaltir).
  if direct then
    cap := FIndex.Count
  else
  begin
    cap := 0;
    if FTableKeys.TryGetValue(TableFilter, tl) then Inc(cap, tl.Count);
    if FTableKeys.TryGetValue(-1, tl) then Inc(cap, tl.Count);
  end;
  if cap < 0 then cap := 0;
  SetLength(tmpOff, cap);
  SetLength(tmpSize, cap);
  SetLength(tmpKey, cap);
  candCnt := 0;

  // ---- TEK gecis: adaylari gecici diziye topla + bucket say ----
  VisitSource;
  total := candCnt;
  if total <= 0 then Exit(True);   // bos: aday yok (gecerli sonuc)

  // bucket kumulatif baslangiclari
  for n := 1 to bCount do
    Inc(P.BucketStart[n], P.BucketStart[n - 1]);
  SetLength(P.CandOff, total);
  SetLength(P.CandSize, total);
  SetLength(P.CandKey, total);
  SetLength(cur, bCount);
  for n := 0 to bCount - 1 do cur[n] := P.BucketStart[n];

  // ---- counting sort: bucket-major yerlestir (hash/IO yok) ----
  for n := 0 to total - 1 do
  begin
    b := Integer(tmpOff[n] shr VDB_PREP_SHIFT);
    if b >= bCount then b := bCount - 1;
    candCnt := cur[b];
    P.CandOff[candCnt] := tmpOff[n];
    P.CandSize[candCnt] := tmpSize[n];
    P.CandKey[candCnt] := tmpKey[n];
    Inc(cur[b]);
  end;
  Result := True;
end;

function TVDb.ScanRawPrepared(const P: TVDbRawPrepared;
  CandLo, CandHi: Integer; Cb: TVDbRawCb; User: Pointer): Boolean;
// H6: bkz. interface. Pass C'nin onceden toplanmis adaylarla ayni isi;
// seri ScanRawIter'dan farki: aday toplama/bucket sayimi YOK, isci yalniz
// kendi araligini isler ve konumsal VDbPosRead kullanir (paylasimsiz).
const
  VDB_PREP_CHUNK_CAP = 4 * 1024 * 1024;
var
  h: TVDbRecHead;
  chunk, decB, recBuf: TBytes;
  k, e, m, bucket, got, pp: Integer;
  lo, hi, span, off, endOff: Int64;
  spanBase: PByte;

  procedure DecryptIfNeeded(var V: TBytes; Flags: Byte; RecKey: QWord);
  var
    plain: TBytes;
  begin
    if (Flags and VDB_FLAG_ENCRYPTED) = 0 then Exit;
    plain := nil;
    if not DecryptValue(V, plain) then
    begin
      if Length(FEncKey) <> VDB_KEY_LEN then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: kayit SIFRELI: anahtar yok. Once OpenKeyFile/SetEncryptionKey. key=%d',
          [RecKey]);
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit cozulemedi (anahtar yanlis veya veri bozulmus) key=%d',
        [RecKey]);
    end;
    V := plain;
  end;

begin
  Result := True;
  if (CandLo < 0) or (CandHi > Length(P.CandOff)) or (CandLo >= CandHi) then Exit;
  k := CandLo;
  while k < CandHi do
  begin
    bucket := Integer(P.CandOff[k] shr P.BucketShift);
    if bucket >= P.BCount then bucket := P.BCount - 1;
    e := k + 1;
    while e < CandHi do
    begin
      m := Integer(P.CandOff[e] shr P.BucketShift);
      if m >= P.BCount then m := P.BCount - 1;
      if m <> bucket then Break;
      Inc(e);
    end;
    // Bucket grubunun okuma araligi
    lo := P.CandOff[k];
    hi := 0;
    for m := k to e - 1 do
    begin
      off := P.CandOff[m];
      endOff := off + Int64(SizeOf(h)) + Int64(P.CandSize[m]);
      if off < lo then lo := off;
      if endOff > hi then hi := endOff;
    end;
    span := hi - lo;
    got := -1;
    spanBase := nil;
    if (P.MapBase <> nil) and (hi <= P.MapLen) then
    begin
      // H6: paylasimli salt-okunur esleme -> syscall yok.
      spanBase := P.MapBase + PtrInt(lo);
      got := Integer(span);
    end
    else if (span > 0) and (span <= VDB_PREP_CHUNK_CAP) then
    begin
      if Length(chunk) < Integer(span) then SetLength(chunk, Integer(span));
      if VDbPosRead(FS.Handle, lo, chunk[0], Integer(span)) = Integer(span) then
      begin
        got := Integer(span);
        spanBase := @chunk[0];
      end;
    end;
    for m := k to e - 1 do
    begin
      if got >= 0 then
        Move(spanBase[Integer(P.CandOff[m] - lo)], h, SizeOf(h))
      else if VDbPosRead(FS.Handle, P.CandOff[m], h, SizeOf(h)) <> SizeOf(h) then
        Continue;
      if (h.Magic <> VDB_MAGIC) or (h.Key <> P.CandKey[m]) or
         (h.ValLen <> P.CandSize[m]) or
         ((h.Flags and VDB_FLAG_DEL) <> 0) then
        Continue;
      if (h.Flags and VDB_FLAG_ENCRYPTED) <> 0 then
      begin
        SetLength(decB, P.CandSize[m]);
        if P.CandSize[m] > 0 then
        begin
          if got >= 0 then
            Move(spanBase[Integer(P.CandOff[m] - lo) + SizeOf(h)], decB[0], P.CandSize[m])
          else
            VDbPosRead(FS.Handle, P.CandOff[m] + SizeOf(h), decB[0], P.CandSize[m]);
        end;
        DecryptIfNeeded(decB, h.Flags, P.CandKey[m]);
        if Length(decB) > 0 then
        begin
          if not Cb(P.CandKey[m], @decB[0], Length(decB), User) then Exit(False);
        end
        else if not Cb(P.CandKey[m], nil, 0, User) then Exit(False);
      end
      else if got >= 0 then
      begin
        pp := Integer(P.CandOff[m] - lo) + SizeOf(h);
        if P.CandSize[m] > 0 then
        begin
          if not Cb(P.CandKey[m], spanBase + pp, Integer(P.CandSize[m]), User) then
            Exit(False);
        end
        else if not Cb(P.CandKey[m], spanBase + pp, 0, User) then Exit(False);
      end
      else
      begin
        SetLength(recBuf, P.CandSize[m]);
        if P.CandSize[m] > 0 then
        begin
          if VDbPosRead(FS.Handle, P.CandOff[m] + SizeOf(h),
            recBuf[0], P.CandSize[m]) <> P.CandSize[m] then
            Continue;
          if not Cb(P.CandKey[m], @recBuf[0], P.CandSize[m], User) then Exit(False);
        end
        else if not Cb(P.CandKey[m], nil, 0, User) then Exit(False);
      end;
    end;
    k := e;
  end;
end;

procedure TVDb.ReleasePreparedScan(var P: TVDbRawPrepared);
var
  m: TVDbFileMap;
begin
  if P.MapBase = nil then Exit;
  FillChar(m, SizeOf(m), 0);
  m.Base := P.MapBase;
  m.Len := P.MapLen;
  m.MapHandle := P.MapHandle;
  m.View := P.MapView;
  m.Valid := True;
  VDbCloseFileMap(m);
  P.MapBase := nil;
  P.MapLen := 0;
  P.MapHandle := 0;
  P.MapView := nil;
end;

function TVDb.Delete(Key: QWord): Boolean;
var
  op: TPendOp;
  i: Integer;
begin
  FLock.Enter;
  try
    CheckOpen;
    RequireBatchWrite;
    if FInBatch then
    begin
      // "put-then-del" kisayolu SADECE anahtar diskte OLMAYAN bir
      // anahtarda gecerlidir (bu batch icinde yeni satir yazilmis, sonra
      // silinmis -> net etki "yok").
      //
      // ONCEDEN bu kosul SORGULANMADAN uygulaniyordu ve bu bir veri
      // HATASI idi: batch icinde "UPDATE t SET n=0 WHERE id=1; DELETE FROM
      // t WHERE id=1" calistirilirsa pending put geri aliniyor, DELETE op'i
      // HIC YAZILMIYOR ve SATIR SILINMIYORDU (Affected=1 donuyordu ama
      // satir diskte kaliyordu; indeks girdisi silinip veri girdisi
      // kaliyordu -> indeksli sorgu satiri kaybediyordu).
      //
      // Dogru kural: FIndex'te anahtar VARSA (yani put bir UZERTE yazmaysa)
      // normal DEL op yazilir.
      if FPendingPuts.ContainsKey(Key) and (not FIndex.ContainsKey(Key)) then
      begin
        // bu batch icinde yeni yazilmis ve simdi siliniyor -> net etki "yok"
        for i := FPending.Count - 1 downto 0 do
          if FPending[i].Key = Key then
            PendingRemove(i);
        FPendingPuts.Remove(Key);
        FPendingDels.Remove(Key);
        FPutSeen.Remove(Key);
        Exit(True);
      end;
      if not FIndex.ContainsKey(Key) and not FPendingPuts.ContainsKey(Key) then
        Exit(False);
      // ayni key icin birden fazla DEL op olmasin.
      // FPutSeen anahtarin bu batch icinde bir pending opu oldugunu
      // soyler; gorulmemisse silinecek op yoktur (tarama atlanir).
      if FPutSeen.ContainsKey(Key) then
        for i := FPending.Count - 1 downto 0 do
          if FPending[i].Key = Key then
            PendingRemove(i);
      FPutSeen.AddOrSetValue(Key, 0);
      // BU ANAHTAR BU BATCH ICINDE PUT EDILMISSE: o put op'i de geri
      // alinir ve yerine DEL konur. Aksi halde commit'te put sonra del
      // olur (yine silinir) ama pending put FPendingPuts'ta kalir ve
      // "yok etkili put-then-del" sanilir.
      FPendingPuts.Remove(Key);
      FPendingDels.AddOrSetValue(Key, 0);
      op.Key := Key;
      SetLength(op.Value, 0);
      op.IsDel := True;
      PendingAdd(op);
      Exit(True);
    end;
if not FIndex.ContainsKey(Key) then
      Exit(False);
    // Batch disi tek silme: kayit + BATCHEND (bkz. Put).
    //
    // GROUP COMMIT: Put ile ayni mantik - fsync SyncWriteInterval
    // icinde toplanir.
    AppendRec(Key, nil, True, False);
    if FSyncWrite and ((FSyncWriteInterval <= 0) or
       (GetTickCount64 - FSyncWriteLast >= QWord(FSyncWriteInterval))) then
    begin
      AppendBatchEnd(True);
      FSyncWriteLast := GetTickCount64;
    end
    else
      AppendBatchEnd(False);   // fsync ertelendi (group commit)
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.BeginBatch;
begin
  FLock.Enter;
  try
    CheckOpen;
    if FInBatch then
      raise EVDbException.Create(ecTransactionState, 'VDb: batch zaten acik');
    FInBatch := True;
    FBatchOwner := VDbGetTxnSession;
    TxnGateOpen(FBatchOwner);
    FSnapshotSeq := FSeq + 1;  // R-01: transaction snapshot — gorunen: tamamlanmis (Seq<=FSeq) + bu batch'taki yazmalar (Seq=FSeq+1)
    PendingClear;
    FPendingPuts.Clear;
    FPendingDels.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.RefreshBatchSnapshot;
begin
  FLock.Enter;
  try
    CheckOpen;
    if FInBatch then
    begin
      RequireBatchWrite;
      FSnapshotSeq := FSeq + 1;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.SetBeforeCommit(Proc: TDbCommitHook);
begin
  FBeforeCommit := Proc;
end;

procedure TVDb.CommitBatch;
var
  i: Integer;
  op: TPendOp;
  savedSize: Int64;
begin
  FLock.Enter;
  try
    CheckOpen;
    if not FInBatch then
      raise EVDbException.Create(ecTransactionState, 'VDb: batch acik degil');
    RequireBatchWrite;
    { R-11: DEFERRABLE kisitlarin COMMIT oncesi denetimi.
      Buraya, HICBIR kayit dosyaya yazilmadan ONCE cagrilir: ihlal
      varsa hicbir sey yazilmamis olur, otomatik geri alma (rollback)
      gerekmez ve transaction acik kalir -- PostgreSQL ile ayni
      davranis ("gecikmis kisit ihlali COMMIT'i reddeder"). }
    if Assigned(FBeforeCommit) then
      FBeforeCommit();
    savedSize := FS.Size;
    try
      // F1-2: ON-DOGRULAMA
      for i := 0 to FPending.Count - 1 do
        if Length(FPending[i].Value) > VDB_MAX_VALUE then
          raise EVDbException.Create(ecLimit, 'VDb: value cok buyuk');
      try
        { 2026-10-04: SkipWAL=False. ONEMLI: batch ici kayitlar
          BeginBatch aninda BIRIKMIS durumdadir; Put/Delete .wal'a
          YAZILMAZ (AppendRec cagrilmaz). Bu yuzden kayitlar ancak
          CommitBatch sirasinda ana dosyaya aktarilir ve otomatik
          WAL aciksa ANCAK O ZAMAN gunluge yazilmalidir.
          SkipWAL=True birakilirsa batch kayitlari hicbir zaman
          .wal'a girmez; crash sonrasi ReplayWAL onlari kurtaramaz
          (T73 bu boslugu yakaladi). }
        { P-21: TOPLU YAZIM. Kayitlar bellekte biriktirilir, esikte tek
          WriteBuffer ile dosyaya bosaltilir; diskteki bayt akisi BIREBIR
          ayni (ayni baytlar, ayni sira, ayni offset). Tampon YALNIZCA
          burada, FLock altinda ve bu blok suresince aktiftir. }
        FWrBufLen := 0;
        FWrBufBase := FS.Seek(0, soEnd);
        FWrBufActive := True;
        try
          for i := 0 to FPending.Count - 1 do
            AppendRec(FPending[i].Key, FPending[i].Value, FPending[i].IsDel,
              False, False);
          FlushWriteBuf;
        finally
          FWrBufActive := False;
          FWrBufLen := 0;
        end;
        if PendingCount > 0 then
          AppendBatchEnd(False);
        // GROUP COMMIT: SyncWriteInterval > 0 ise ve yeterli sure gecmediyse
        // fsync ertelenir. Boylece SQL katmaninin her UPDATE/DELETE icin
        // kullandigi BeginBatch/CommitBatch de group commit ile calisir.
        // FDirty False birakilmaz (siradaki Flush/CommitBatch'te tekrar denenecek).
        if (FSyncWriteInterval <= 0) or
           (GetTickCount64 - FSyncWriteLast >= QWord(FSyncWriteInterval)) then
        begin
          VDbFlushStream(FS);
          FDirty := False;
          FSyncWriteLast := GetTickCount64;
        end;
      except
        on E: Exception do
        begin
          try
            FS.Size := savedSize;
            VDbFlushStream(FS);
            // H12: kuyruk kirpildi -> bu bolgedeki olasi onbellek bloklari
            // artik gecersiz (Recover zaten temizler; yine de burada da temizle).
            ClearReadCache;
          except
          end;
          try
            Recover;
          except
          end;
          raise;
        end;
      end;
    finally
      PendingClear;
      FPendingPuts.Clear;
      FPendingDels.Clear;
      FInBatch := False;
      FBatchOwner := 0;
      TxnGateClose;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.AbortBatch;
begin
  FLock.Enter;
  try
    { Kapanis/ROLLBACK her zaman guvenlidir: yalnizca commit edilmemis
      degisiklikleri atar. Sahip denetimi burada yapilmaz; aksi halde
      baska oturumun acik biraktigi batch yuzunden DB kapatilamaz. }
    PendingClear;
    FPendingPuts.Clear;
    FPendingDels.Clear;
    FInBatch := False;
    FBatchOwner := 0;
    TxnGateClose;
    ClearSavepoints;
  finally
    FLock.Leave;
  end;
end;

{ ---------------------------------------------------------------
  SAVEPOINT / Nested Transaction (R-02) Implementation
  --------------------------------------------------------------- }
procedure TVDb.Savepoint(const AName: string);
// Yeni bir savepoint olusturur. Mevcut durumun kopyasini alir.
var
  sp: TSavepoint;
  pair: TPair<QWord, TDbLoc>;
begin
  FLock.Enter;
  try
    CheckOpen;
    if FInBatch then RequireBatchWrite;
    // SQL standardi: SAVEPOINT, acik bir transaction olmasa da calisir —
    // o zaman ORTUK (implicit) transaction baslatilir. Bizde "batch" bu
    // anlama gelir. Once hata veriyordu; test grubu R-02 tamamen kirildi.
    if not FInBatch then
    begin
      FInBatch := True;
      FBatchOwner := VDbGetTxnSession;
      FSnapshotSeq := FSeq + 1;
      PendingClear;
      FPendingPuts.Clear;
      FPendingDels.Clear;
    end;
    // Ayni isimde savepoint varsa hata (SQL standardi)
    for sp in FSavepoints do
      if SameText(sp.Name, AName) then
        raise EVDbException.CreateFmt(ecDuplicateSavepoint,
          'VDb: savepoint zaten var: %s', [AName]);
    sp.Name := AName;
    sp.Seq := FSeq;
    sp.PendingCount := FPending.Count;
    sp.Dirty := FDirty;
    // FIndex kopyasi (shallow copy - TDbLoc record'lar kopyalanir)
    sp.IndexSnapshot := TDictionary<QWord, TDbLoc>.Create;
    for pair in FIndex do
      sp.IndexSnapshot.Add(pair.Key, pair.Value);
    FSavepoints.Add(sp);
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.ReleaseSavepoint(const AName: string);
// Savepoint'i serbest birakir (parent'a birlestirilir).
// Savepoint ve tum child savepoint'ler silinir.
var
  i, j, found: Integer;
begin
  FLock.Enter;
  try
    CheckOpen;
    // Savepoint'i bul (en sondan basla - en guncel olan)
    found := -1;
    for i := FSavepoints.Count - 1 downto 0 do
      if SameText(FSavepoints[i].Name, AName) then
      begin
        found := i;
        Break;
      end;
    if found = -1 then
      raise EVDbException.CreateFmt(ecSavepointNotFound,
        'VDb: savepoint bulunamadi: %s', [AName]);
    // Bu savepoint ve sonrasindakilere ait index kopyalarini birak.
    // DIKKAT: dis dongunun `i` degiskeni IC dongude yeniden
    // kullanilamaz; `for` dongu degiskenine atama yasaktir ve
    // dis dongunun sayaci da bozulurdu.
    for j := found to FSavepoints.Count - 1 do
      FSavepoints[j].IndexSnapshot.Free;
    // FSavepoints bir TList, SetLength YALNIZCA dinamik diziler icindir.
    FSavepoints.Count := found;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.RollbackToSavepoint(const AName: string);
// Savepoint'e don: pending op'lari geri al, FIndex'i restore et.
// Savepoint ve child'lari silinir.
var
  i, removeFrom: Integer;
  sp: TSavepoint;
  pair: TPair<QWord, TDbLoc>;
begin
  FLock.Enter;
  try
    CheckOpen;
    // Savepoint'i bul (en sondan basla)
    removeFrom := -1;
    for i := FSavepoints.Count - 1 downto 0 do
      if SameText(FSavepoints[i].Name, AName) then
      begin
        removeFrom := i;
        Break;
      end;
    if removeFrom = -1 then
      raise EVDbException.CreateFmt(ecSavepointNotFound,
        'VDb: savepoint bulunamadi: %s', [AName]);
    sp := FSavepoints[removeFrom];
    // 1. Pending op'lari savepoint oncesine geri getir
    while FPending.Count > sp.PendingCount do
    begin
      i := FPending.Count - 1;
      PendingRemove(i);
    end;
    FPendingPuts.Clear;
    FPendingDels.Clear;
    for i := 0 to FPending.Count - 1 do
    begin
      if not FPending[i].IsDel then
        FPendingPuts.AddOrSetValue(FPending[i].Key, 0)
      else
        FPendingDels.AddOrSetValue(FPending[i].Key, 0);
    end;
    // 2. FIndex'i savepoint anlik durumuna restore et
    FIndex.Clear;
    for pair in sp.IndexSnapshot do
      FIndex.Add(pair.Key, pair.Value);
    FTableKeysDirty := True;   // KR-1: index restore edildi
    FTableRowCount.Clear;
    // 3. State restore
    FSeq := sp.Seq;
    FDirty := sp.Dirty;
    // 4. YALNIZCA child savepoint'leri temizle; HEDEF savepoint KALIR.
    //    SQL standardi hedefi de yok eder ama SQLite ve geri kalan DB'ler
    //    (ve bizim R-02 test grubu) hedefi korur: Boylece ayni savepoint'e
    //    tekrar ROLLBACK TO yapilabilir ve RELEASE edilebilir.
    //    Not: FIndex zaten restore edildigi icin hedefin IndexSnapshot'i
    //    artik "eski" bir kopyadir ama tutmaya devam eder (tekrar kullanilir).
    if removeFrom + 1 <= FSavepoints.Count - 1 then
    begin
      for i := removeFrom + 1 to FSavepoints.Count - 1 do
        FSavepoints[i].IndexSnapshot.Free;
      FSavepoints.Count := removeFrom + 1;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.ClearSavepoints;
// Tum savepoint'leri temizler (CommitBatch/AbortBatch'te cagrilir).
var
  i: Integer;
begin
  for i := 0 to FSavepoints.Count - 1 do
    FSavepoints[i].IndexSnapshot.Free;
  FSavepoints.Clear;
end;

procedure TVDb.Flush;
begin
  FLock.Enter;
  try
    CheckOpen;
    // GROUP COMMIT: SyncWriteInterval > 0 ise ve yeterli sure gecmediyse
    // fsync ertelenir. Boylece SQL katmaninin her Exec sonrasi cagirdigi
    // Flush bile group commit ile calisir. FDirty False birakilmaz
    // (siradaki Flush'te tekrar denenecek).
    if (FSyncWriteInterval > 0) and
       (GetTickCount64 - FSyncWriteLast < QWord(FSyncWriteInterval)) then
      Exit;   // fsync ertelendi; FDirty hala True
    VDbFlushStream(FS);
    FDirty := False;
    FSyncWriteLast := GetTickCount64;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.Compact(out OldBytes, NewBytes: Int64);
// Sadece canli kayitlari yeni dosyaya yazar (olu PUT surumleri ve
// tombstone'lar duser), fsync + atomik rename ile degistirir.
// Canli veriyi tek parca RAM'e cekmez; sabit tamponla akis kopyalamasi yapar.
// Eski dosya .bak olarak kalir. Batch acikken cagrilamaz.
var
  tmpPath: string;
  ts: TFileStream;
  pair: TPair<QWord, TDbLoc>;
  loc: TDbLoc;
  h: TVDbRecHead;
  pv: PByte;
  buf: TBytes;
  i: Integer;
begin
  OldBytes := 0; NewBytes := 0;
  FLock.Enter;
  try
    CheckOpen;
    if FInBatch then
      raise EVDbException.Create(ecTransactionState, 'VDb: batch acikken compact yapilamaz');
    OldBytes := FS.Size;
    tmpPath := FPath + '.tmp';
    if FileExists(tmpPath) then DeleteFile(tmpPath);
    ts := TFileStream.Create(tmpPath, fmCreate);
    try
      WriteHeaderTo(ts);
      SetLength(buf, 65536);
      i := 0;
      for pair in FIndex do
      begin
        loc := pair.Value;
        if loc.Size > 0 then
        begin
          if Length(buf) < Integer(loc.Size) then
            SetLength(buf, loc.Size);
          FS.Position := loc.Offset + Int64(SizeOf(TVDbRecHead));
          FS.ReadBuffer(buf[0], loc.Size);
          pv := @buf[0];
        end
        else
          pv := nil;
        h.Magic := VDB_MAGIC;
        h.Seq := FSeq + QWord(i) + 1;
        h.Key := pair.Key;
        h.ValLen := loc.Size;
        { 2026-10-05 BAYRAK KORUMASI (ZORUNLU DUZELTME):
          Burada kopyalanan deger HAM baytlardir. Sifreli bir kayit
          kopyalanirsa bayragi `VDB_FLAG_PUT` yapmak onu "duz metin"
          ilan ederdi: sonraki acilista Get COZMEYI deneyip etiket
          dogrulanamayinca hataya duserdi. Bu yuzden kaydin kendi
          bayragi (PUT|DEL biti + ENCRYPTED) korunur. }
        h.Flags := Byte(loc.Flags and not Byte(VDB_FLAG_BATCHEND));
        if not RecFlagsValid(h.Flags, h.ValLen, False) then
          h.Flags := VDB_FLAG_PUT;
        h.Crc := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, pv);
        ts.WriteBuffer(h, SizeOf(h));
        if h.ValLen > 0 then
          ts.WriteBuffer(buf[0], h.ValLen);
        Inc(i);
      end;
      AppendBatchEndTo(ts, FSeq + QWord(i) + 1);
      VDbFlushStream(ts);
    finally
      ts.Free;
    end;
    ReplaceWith(tmpPath);
    FDataStart := VDB_HDR_SIZE;
    FDeadBytes := 0;
    NewBytes := FS.Size;
  finally
    FLock.Leave;
  end;
end;

function TVDb.AutoCompact(out OldBytes, NewBytes: Int64;
  MaxDeadRatio: Double; MinBytes: Int64): Boolean;
// Olu oran esigi asildiysa Compact yapar.
// DIKKAT: kilidi TEK PARCA icinde tut. Once kilidi birakip sonra Compact
// cagrilirsa araya baska islem girip yanlis karar verirdi (yarisma).
// Compact kendi kilidini alir; TCriticalSection rekursiftir.
var
  sz: Int64;
begin
  Result := False;
  OldBytes := 0; NewBytes := 0;
  FLock.Enter;
  try
    CheckOpen;
    if FInBatch then Exit; // batch icinde compact yapilamaz, atla
    sz := FS.Size;
    if sz <= 0 then Exit;
    if sz < MinBytes then Exit;
    if (Double(FDeadBytes) / Double(sz)) < MaxDeadRatio then Exit;
    Compact(OldBytes, NewBytes);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TVDb.RestoreFrom(const SrcPath: string): Boolean;
// R-16: yedek dosyasini bu veritabanina geri yukler (RESTORE FROM).
// Once gecici dosyaya kopyalanir, sonra ReplaceWith ile yerine gecer
// (yarim kalan geri yukleme olusmaz) ve ReplaceWith eski dosyayi
// <db>.bak olarak BIRAKIR -> hatali bir RESTORE geri alinabilir.
//
// ONEMLI: onceki surumde mevcut .odb'yi ayrica kopyaliyorduk
// (CopyFileRaw(FPath, ...)). Bu CALISMIYORDU: acik veritabani bir
// bayt-araligi kilidi (LockFileEx) tasiyor ve ayni dosyaya IKINCI bir
// handle ile acmak ERROR_LOCK_VIOLATION (paylasim ihlali) veriyordu.
// ReplaceWith zaten .bak biraktigi icin ayri kopya gerekmiyor.
var
  tmp, dir: string;
begin
  FLock.Enter;
  try
    CheckOpen;
    Result := False;
    if not FileExists(SrcPath) then
      raise EVDbException.Create(ecIOError,
        'VDb: yedek dosyasi bulunamadi: ' + SrcPath);
    dir := ExtractFileDir(FPath);
    if dir = '' then dir := '.';
    tmp := FPath + '.restore.tmp';
    if FileExists(tmp) then DeleteFile(tmp);
    if not CopyFileRaw(SrcPath, tmp) then
      raise EVDbException.Create(ecIOError,
        'VDb: yedek kopyalanamadi: ' + SrcPath);
    { NOT: .wal silinmez. Arsiv segmentleri PITR icin gereklidir ve
      .odb'a bagli degildir; RECOVER onlari .odb'ye UYGULAR. }
    ReplaceWith(tmp);
    VDbFlushDir(dir);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.BackupTo(const DestPath: string);
// Acik DB'nin tutarli kopyasini yeni .odb olarak yazar (schema dahil).
// Commitlenmis veriyi alir; sabit tamponla akis halinde yazar (RAM OOM onler).
var
  ts: TFileStream;
  tmp, dir: string;
  pair: TPair<QWord, TDbLoc>;
  loc: TDbLoc;
  h: TVDbRecHead;
  pv: PByte;
  buf: TBytes;
  i: Integer;
begin
  FLock.Enter;
  try
    CheckOpen;
    if FInBatch then
      raise EVDbException.Create(ecTransactionState, 'VDb: batch acikken yedek alinamaz (once Commit/Abort)');
    dir := ExtractFileDir(DestPath);
    if dir <> '' then ForceDirectories(dir);
    tmp := DestPath + '.tmp';
    if FileExists(tmp) then DeleteFile(tmp);
    ts := TFileStream.Create(tmp, fmCreate);
    try
      WriteHeaderTo(ts);
      SetLength(buf, 65536);
      i := 0;
      for pair in FIndex do
      begin
        loc := pair.Value;
        if loc.Size > 0 then
        begin
          if Length(buf) < Integer(loc.Size) then
            SetLength(buf, loc.Size);
          FS.Position := loc.Offset + Int64(SizeOf(TVDbRecHead));
          FS.ReadBuffer(buf[0], loc.Size);
          pv := @buf[0];
        end
        else
          pv := nil;
        h.Magic := VDB_MAGIC;
        h.Seq := QWord(i) + 1;
        h.Key := pair.Key;
        h.ValLen := loc.Size;
        { 2026-10-05: Compact ile ayni sebeple bayrak KORUNUR.
          Yedek, sifreli kaydi duz metne cevirip sessizce BOZMAZ. }
        h.Flags := Byte(loc.Flags and not Byte(VDB_FLAG_BATCHEND));
        if not RecFlagsValid(h.Flags, h.ValLen, False) then
          h.Flags := VDB_FLAG_PUT;
        h.Crc := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, pv);
        ts.WriteBuffer(h, SizeOf(h));
        if h.ValLen > 0 then
          ts.WriteBuffer(buf[0], h.ValLen);
        Inc(i);
      end;
      AppendBatchEndTo(ts, QWord(i) + 1);
      VDbFlushStream(ts);
    finally
      ts.Free;
    end;
    if FileExists(DestPath) then DeleteFile(DestPath);
    if not RenameFile(tmp, DestPath) then
      raise EVDbException.Create(ecIOError, 'VDb: yedek tasinamadi: ' + DestPath);
    // M6: sifreli kolonlar varsa anahtar dosyasi da yedegin yanina
    // kopyalanir; aksi halde yedek tek basina acilamaz.
    if FileExists(ColumnKeyPath) then
      if not CopyFileRaw(ColumnKeyPath, ChangeFileExt(DestPath, '.colkey')) then
        raise EVDbException.Create(ecIOError,
          'VDb: kolon anahtar dosyasi yedege kopyalanamadi: ' + DestPath);
    VDbFlushDir(dir);
    { R-16: yedek anina kadar bekleyen WAL'i arsive tasir. Yedekten
      SONRA olan degisiklikler arsivde kalir; RECOVER TO TIMESTAMP
      bunlari yedek + arsiv birlestirerek "o ana kadar" dondurur.
      (Yedek zaten commitlenmis veriyi icerir; arsivdeki kayitlar
      ONDAN SONRAKI degisikliklerdir, tekrarlanan kayit degildir.) }
    if FArchiveDir <> '' then MaybeRotateWal(True);
  finally
    FLock.Leave;
  end;
end;

// ============================================================================
// WAL Kayit Bicimi (TVDbWalHead / VDB_WAL_MAGIC): ARTIK INTERFACE'TE
// (2026-10-05) - VDbCdc ve VDbTimeTravel ayni bicimde okuyabilsin diye.
// Eski yorumdaki "STUB / ReplayWAL gercek yapmaz" ifadesi GECERSIZ:
// ReplayWAL gercektir (magic + CRC + yirtik kuyruk kesme).

function TVDb.WriteAheadWALCore(Key: QWord; const Value: TBytes;
  Flags: Byte): Boolean;
{ KILIT ALMAZ. AppendRec bunu cagirir ve kilidi zaten tutuyor;
  kilidi burada yeniden almak DEADLOCK olurdu (TCriticalSection
  recursive olsa da bekleme kuyrugu bozulur).
  CheckOpen da cagrilmaz: yine AppendRec icindeyiz.
  Tum dogrulama kurallari public WriteAheadWAL ile AYNI. }
var
  fs: TFileStream;
  wp: string;
  h: TVDbWalHead;
begin
  Result := False;
  if (Flags <> VDB_FLAG_PUT) and (Flags <> VDB_FLAG_DEL) then Exit(False);
  if (Flags = VDB_FLAG_DEL) and (Length(Value) > 0) then Exit(False);
  if Length(Value) > VDB_MAX_VALUE then Exit(False);
  wp := WalPath;
  h.Magic := VDB_WAL_MAGIC;
  h.Key := Key;
  h.Flags := Flags;
  h.ValLen := LongWord(Length(Value));
  { R-16: LSN ve zaman damgasi. CRC ikisini de kapsar. }
  Inc(FWalLSN);
  h.LSN := FWalLSN;
  h.WalStamp := NowUnixMS;
  if h.ValLen > 0 then
    h.Crc := RecCrcWal(h.LSN, h.WalStamp, Key, h.ValLen, Flags, @Value[0])
  else
    h.Crc := RecCrcWal(h.LSN, h.WalStamp, Key, 0, Flags, nil);
  { 2026-10-04: .wal dosyasi VARSA EKLENEREK acilir, yoksa YENIDEN
    olusturulur. ONCEDEN her zaman `fmCreate` kullaniliyordu; FPC'de
    fmCreate dosyayi KIRPAR, boylece her WriteAheadWAL cagrisi
    onceki kayitlari SILERDI (replay yalnizca son kaydi goruyordu). }
  if FileExists(wp) then
    fs := TFileStream.Create(wp, fmOpenReadWrite)
  else
    fs := TFileStream.Create(wp, fmCreate);
  try
    fs.Position := fs.Size;
    fs.WriteBuffer(h, SizeOf(h));
    if h.ValLen > 0 then fs.WriteBuffer(Value[0], h.ValLen);
    { write-ahead: kayit ana dosyaya GECMEDEN once kalici olmali }
    VDbFlushStream(fs);
    Result := True;
  finally
    fs.Free;
  end;
  { R-16: segment limiti asildiysa KAYIT YAZILDIKTAN SONRA arsivle.
    (Onceki arsivleme kaydi bozmazdi; ama yine de yazim oncesi
    yapmak, limit dolu dosyaya yeni kayit eklemeyi riske atardi.) }
  if FArchiveDir <> '' then
    MaybeRotateWal(False);
end;

procedure TVDb.SetWALEnabled(AValue: Boolean);
{ 2026-10-04. Acilikta uyari: otomatik WAL acikken ReplayWAL
  cagrisi kayitlari IKI KEZ uygular (cift yazim). Bu yuzden
  kullanicinin bilmesi gerekir; ayrica sayac sifirlanir. }
begin
  FLock.Enter;
  try
    FWALEnabled := AValue;
    FWALAutoCount := 0;
    FWALWasEnabled := AValue;
  finally
    FLock.Leave;
  end;
end;

// ============================================================================
// 2026-10-05 KAYIT SEVIYESI SIFRELEME
// ============================================================================

function TVDb.IsEncrypted: Boolean;
begin
  FLock.Enter;
  try
    Result := Length(FEncKey) = VDB_KEY_LEN;
  finally
    FLock.Leave;
  end;
end;

function TVDb.HasEncryptedRecordsProp: Boolean;
begin
  FLock.Enter;
  try
    Result := (FEncFlags and VDB_HFLAG_HAS_ENCRYPTED) <> 0;
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.SetEncryptionKey(const Key: TBytes);
// Bos anahtar = sifreleme kapali (geriye donuk uyum).
// Yazilmis KAYITLAR ETKILENMEZ: her kaydin bayragi kendi kendini
// tasir, bu yuzden karisik (mixed) dosyalar sorunsuz okunur.
begin
  FLock.Enter;
  try
    if Length(Key) = 0 then
    begin
      if FEncKey <> nil then
        FillChar(FEncKey[0], Length(FEncKey), 0);
      FEncKey := nil;
      Exit;
    end;
    if Length(Key) <> VDB_KEY_LEN then
      raise EVDbException.CreateFmt(ecUnsupported,
        'VDb: anahtar uzunlugu %d (beklenen %d)', [Length(Key), VDB_KEY_LEN]);
    if FEncKey <> nil then
      FillChar(FEncKey[0], Length(FEncKey), 0);
    SetLength(FEncKey, VDB_KEY_LEN);
    Move(Key[0], FEncKey[0], VDB_KEY_LEN);
  finally
    FLock.Leave;
  end;
end;

procedure TVDb.ClearEncryptionKey;
begin
  SetEncryptionKey(nil);
end;

procedure TVDb.RekeyWithPassword(const NewPassword: string);
// 2026-10-05 Adim 15. Yeni parola ile SIFRELI kayitlarin anahtari
// degistirilir. Agirlik: FEncKey aktif olmali (OpenKeyFile / SetEncryptionKey).
// Atomik: tmp.odb + ReplaceWith (Compact ile ayni desen), .key.tmp -> .key.
var
  tmpPath, keyTmp: string;
  ts: TFileStream;
  pair: TPair<QWord, TDbLoc>;
  loc: TDbLoc;
  h: TVDbRecHead;
  pv: PByte;
  raw, plain, enc: TBytes;
  OldKey, NewKey: TBytes;
  NewIter: Integer;
  i: Integer;
begin
  FLock.Enter;
  try
    CheckOpen;
    if FInBatch then
      raise EVDbException.Create(ecTransactionState,
        'VDb: batch acikken REKEY yapilamaz');
    if Length(FEncKey) <> VDB_KEY_LEN then
      raise EVDbException.Create(ecUnsupported,
        'VDb: once anahtar yukle (SetEncryptionKey / OpenKeyFile)');

    OldKey := Copy(FEncKey, 0, VDB_KEY_LEN);

    tmpPath := FPath + '.tmp';
    if FileExists(tmpPath) then DeleteFile(tmpPath);
    keyTmp := ChangeFileExt(FPath, '.rekey.key');
    if FileExists(keyTmp) then DeleteFile(keyTmp);

    NewKey := nil; NewIter := 0;
    if not VDbKeyFileWrite(keyTmp, NewPassword, NewKey, NewIter) then
      raise EVDbException.Create(ecIOError, 'VDb: .key yazilamadi');

    ts := TFileStream.Create(tmpPath, fmCreate);
    try
      WriteHeaderTo(ts);
      SetLength(raw, 65536);
      i := 0;
      for pair in FIndex do
      begin
        loc := pair.Value;
        if loc.Size > 0 then
        begin
          if Length(raw) < Integer(loc.Size) then
            SetLength(raw, loc.Size);
          FS.Position := loc.Offset + Int64(SizeOf(TVDbRecHead));
          FS.ReadBuffer(raw[0], loc.Size);
          pv := @raw[0];
        end
        else
          pv := nil;

        h.Magic := VDB_MAGIC;
        h.Seq := FSeq + QWord(i) + 1;
        h.Key := pair.Key;

        if (loc.Flags and VDB_FLAG_ENCRYPTED) <> 0 then
        begin
          SetLength(enc, loc.Size);
          Move(raw[0], enc[0], loc.Size);
          plain := nil;
          if not VDbCryptDecrypt(OldKey, enc, plain) then
            raise EVDbException.Create(ecCorrupt,
              'VDb: REKEY: kayit cozulemedi (eski anahtar uyumsuz)');
          enc := nil;
          if not VDbCryptEncrypt(NewKey, plain, enc) then
            raise EVDbException.Create(ecIOError,
              'VDb: REKEY: yeniden sifreleme basarisiz');
          if Length(enc) > 0 then
            pv := @enc[0];
          h.ValLen := LongWord(Length(enc));
          h.Flags := Byte(Byte(loc.Flags and not Byte(VDB_FLAG_BATCHEND)));
          if not RecFlagsValid(h.Flags, h.ValLen, False) then
            h.Flags := VDB_FLAG_PUT or VDB_FLAG_ENCRYPTED;
        end
        else
        begin
          h.ValLen := loc.Size;
          h.Flags := Byte(loc.Flags and not Byte(VDB_FLAG_BATCHEND));
          if not RecFlagsValid(h.Flags, h.ValLen, False) then
            h.Flags := VDB_FLAG_PUT;
        end;

        h.Crc := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, pv);
        ts.WriteBuffer(h, SizeOf(h));
        if h.ValLen > 0 then
          ts.WriteBuffer(pv^, h.ValLen);
        Inc(i);
      end;
      AppendBatchEndTo(ts, FSeq + QWord(i) + 1);
      VDbFlushStream(ts);
    finally
      ts.Free;
    end;

    // Once .key.tmp hedef .key'e; basarisizsa eski .key korunur
    if FileExists(KeyPath) then
      RenameFile(KeyPath, KeyPath + '.bak');
    if not RenameFile(keyTmp, KeyPath) then
    begin
      if FileExists(KeyPath + '.bak') then
        RenameFile(KeyPath + '.bak', KeyPath);
      raise EVDbException.Create(ecIOError, 'VDb: .key rename basarisiz');
    end;

    ReplaceWith(tmpPath);
    FDataStart := VDB_HDR_SIZE;
    FDeadBytes := 0;

    if FEncKey <> nil then
      FillChar(FEncKey[0], Length(FEncKey), 0);
    FEncKey := NewKey;
    NewKey := nil;
    FEncFlags := FEncFlags or VDB_HFLAG_HAS_ENCRYPTED;
  finally
    FLock.Leave;
    if OldKey <> nil then
      FillChar(OldKey[0], Length(OldKey), 0);
    if NewKey <> nil then
      FillChar(NewKey[0], Length(NewKey), 0);
  end;
end;

function TVDb.KeyPath: string;
begin
  Result := ChangeFileExt(FPath, '.key');
end;

function TVDb.ColumnKeyPath: string;
begin
  Result := ChangeFileExt(FPath, '.colkey');
end;

function TVDb.ColumnKeyId: QWord;
begin
  FLock.Enter;
  try
    Result := FColKeyId;
  finally
    FLock.Leave;
  end;
end;

function TVDb.EnsureColumnKey: QWord;
var
  p: string;
begin
  FLock.Enter;
  try
    if FColKeyId <> 0 then Exit(FColKeyId);
    if Trim(FPath) = '' then
      raise EVDbException.Create(ecIOError,
        'VDb: kolon anahtari icin veritabani yolu yok');
    p := ColumnKeyPath;
    if FileExists(p) then
    begin
      if not VDbColumnKeyLoadFile(p, FColKeyId) then
        raise EVDbException.Create(ecIOError,
          'VDb: kolon anahtar dosyasi okunamadi: ' + p);
    end
    else
    begin
      if not VDbColumnKeyCreateFile(p, FColKeyId) then
        raise EVDbException.Create(ecIOError,
          'VDb: kolon anahtar dosyasi olusturulamadi: ' + p);
    end;
    Result := FColKeyId;
  finally
    FLock.Leave;
  end;
end;

function TVDb.CreateKeyFile(const FileName, Password: string): Boolean;
var
  k: TBytes;
  it: Integer;
begin
  FLock.Enter;
  try
    k := nil;
    if not VDbKeyFileWrite(FileName, Password, k, it) then
    begin
      Result := False;
      Exit;
    end;
    try
      SetEncryptionKey(k);
    finally
      if k <> nil then
        FillChar(k[0], Length(k), 0);
    end;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TVDb.OpenKeyFile(const FileName, Password: string): Boolean;
var
  k: TBytes;
  it: Integer;
begin
  FLock.Enter;
  try
    k := nil;
    { VDbKeyFileRead yanlis parolada False doner (istisna atmaz);
      dogru parolada anahtari doldurur. Dosya bozuksa istisna atar. }
    if not VDbKeyFileRead(FileName, Password, k, it) then
    begin
      Result := False;
      Exit;
    end;
    try
      SetEncryptionKey(k);
    finally
      if k <> nil then
        FillChar(k[0], Length(k), 0);
    end;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TVDb.EncryptionKeyFingerprint: string;
// Anahtarin kendisini vermez; yalnizca tanilama icin HMAC tabanli
// kisa bir parmak izi. Log/ekrana yazilabilir.
var
  f: TBytes;
  i: Integer;
  s: string;
begin
  FLock.Enter;
  try
    if Length(FEncKey) <> VDB_KEY_LEN then Exit('');
    f := VDbCryptHmacSha256(FEncKey, VDbCryptStrToBytes('VDB-KEY-FINGERPRINT'));
    s := '';
    for i := 0 to 3 do
      s := s + IntToHex(f[i], 2);
    Result := s;
  finally
    FLock.Leave;
  end;
end;

function TVDb.EncryptValue(const Value: TBytes;
  out Cipher: TBytes): Boolean;
begin
  Cipher := nil;
  if Length(FEncKey) <> VDB_KEY_LEN then
  begin
    Cipher := Value;
    Exit(False);
  end;
  if not VDbCryptEncrypt(FEncKey, Value, Cipher) then
  begin
    Cipher := nil;
    Exit(False);
  end;
  Result := True;
end;

function TVDb.DecryptValue(const Cipher: TBytes;
  out Plain: TBytes): Boolean;
{ DIKKAT: bu bir YORDAM FONKSIYONUDUR, istisna FIRLATMAZ.
  VDbCryptDecrypt etiket dogrulanamazsa EVdbCryptError yutar; burada
  yutulup False donulur. Aksi halde istisna, cagiranin `out`
  parametresini temizleme kodunaulasmadan yukarı cikardi ve istisna
  yutan tarafta ham sifreli baytlar kaliyordu. }
begin
  Plain := nil;
  if Length(Cipher) = 0 then
    Exit(False);
  if Length(FEncKey) <> VDB_KEY_LEN then
    Exit(False);
  try
    if not VDbCryptDecrypt(FEncKey, Cipher, Plain) then
    begin
      Plain := nil;
      Exit(False);
    end;
  except
    on E: Exception do
    begin
      Plain := nil;
      Exit(False);
    end;
  end;
  Result := True;
end;

function TVDb.WalAutoCount: Integer;
begin
  FLock.Enter;
  try    Result := FWALAutoCount;
  finally
    FLock.Leave;
  end;
end;

function TVDb.WriteAheadWAL(Key: QWord; const Value: TBytes; Flags: Byte): Boolean;
// F2-4: ONCEDEN FLock almiyordu; iki thread ayni anda .wal'a yazip
// birbirinin kaydini bozabiliyordu. Simdi tum WAL metotlari ayni kilidi
// kullanir (Put/Delete ile ayni) ve CheckOpen ile dogrulanir.
//
// 2026-10-04: kayda magic + CRC eklendi (yirtik kuyruk tespiti) ve
// deger dosyaya FLUSH EDILIR. Aksi halde "write-ahead"in anlami
// kalmazdi: kayit elektrik kesintisinde kaybolabilirdi.
// Flags VDB_FLAG_PUT (0) veya VDB_FLAG_DEL (1) olmalidir.
begin
  FLock.Enter;
  try
    CheckOpen;
    Result := WriteAheadWALCore(Key, Value, Flags);
  finally
    FLock.Leave;
  end;
end;

function TVDb.ReplayWAL: Boolean;
// 2026-10-04: GERCEK REPLAY (onceki hâli STUB'du: .wal varsa False
// donup icerigi UYGULAMAYARDI ve cagirici dosyayi silebiliyordu).
//
// Akis:
//  1) .wal dosyasi yoksa True (yapilacak yok).
//  2) Kayitlar sirayla okunur; magic/CRC/uzunluk tutmuyorsa
//     yirtik kuyruk -> ORADA KESILIR, o ana kadar olanlar uygulanir.
//  3) Gecerli kayitlar ANA DOSYAYA TEK BATCH'te yazilir (BATCHEND +
//     tek fsync): ya hep uygulanir ya hicbiri.
//  4) Basarili olursa .wal silinir.
//
// Kilit, Put/Delete ile ayni FLock. Batch icindeyse cagrilamaz.
var
  fs: TFileStream;
  wp: string;
  h: TVDbWalHead;
  valBuf: TBytes;
  walSize: Int64;
  pos: Int64;
  applied: Integer;
  i: Integer;
  ownBatch: Boolean;
begin
  FLock.Enter;
  try
    CheckOpen;
    wp := WalPath;
    if not FileExists(wp) then Exit(True);
    if FInBatch then
      raise EVDbException.Create(ecUnsupported,
        'VDb: batch icinde WAL replay yapilamaz');
    applied := 0;
    ownBatch := False;
    fs := TFileStream.Create(wp, fmOpenRead);
    try
      walSize := fs.Size;
      pos := 0;
      // 1) GECERLI kayitlari say, gecersiz olanlarda KES
      while pos + Int64(SizeOf(h)) <= walSize do
      begin
        fs.Position := pos;
        if fs.Read(h, SizeOf(h)) <> SizeOf(h) then Break;
        // magic tutmazsa -> yirtik/bozuk kuyruk
        if h.Magic <> VDB_WAL_MAGIC then Break;
        // anlamsiz bayrak veya silme kaydinda deger -> gecersiz
        if (h.Flags <> VDB_FLAG_PUT) and (h.Flags <> VDB_FLAG_DEL) then Break;
        if (h.Flags = VDB_FLAG_DEL) and (h.ValLen <> 0) then Break;
        if h.ValLen > VDB_MAX_VALUE then Break;
        // degerin tamami dosyada mi? degilse kayit yarim yazilmis
        if pos + Int64(SizeOf(h)) + Int64(h.ValLen) > walSize then Break;
        SetLength(valBuf, h.ValLen);
        if h.ValLen > 0 then
          if fs.Read(valBuf[0], h.ValLen) <> Integer(h.ValLen) then Break;
        if h.ValLen > 0 then
        begin
          if RecCrcWal(h.LSN, h.WalStamp, h.Key, h.ValLen, h.Flags,
          @valBuf[0]) <> h.Crc then Break;
        end
        else if RecCrcWal(h.LSN, h.WalStamp, h.Key, 0, h.Flags, nil) <> h.Crc then
          Break;
        Inc(applied);
        pos := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
      end;
      // 2) Ana dosyaya TEK BATCH'te uygula
      if applied > 0 then
      begin
        BeginBatch;
        ownBatch := True;
        try
          // YALNIZCA sayimda dogrulanmis `applied` kayit uygulanir.
          // 2026-10-04: burada `while True ... if applied <= 0 then Break;
          // Dec(applied)` yaziliydi; kontrol EN SONDA oldugu icin
          // gecersiz/yirtik son kayit da bir tur DAHA uygulaniyordu
          // (off-by-one) -> cop veri ana dosyaya yaziliyordu.
          // Tarama zaten durdugu yeri `pos` ile bildiriyor; o yuzu
          // dogrudan kullanmak hem daha hizli hem de guvenli.
          //
          // ONEMLI: kayitlar AppendRec ile DOGRUDAN yazilir; CommitBatch
          // yalnizca FPending'i bosalttigi icin BATCHEND yazmaz. Oysa
          // Recover, dosyada daha once bir BATCHEND varsa sonraki
          // BATCHEND'siz kayitlari "commit edilmemis batch" sayip GERI
          // SARAR. Yani replay sonrasi kayitlar yeniden acilista KAYBOLURDU.
          // Bu yuzden BATCHEND'i elle yaziyoruz: CommitBatch'in yazmadigi
          // tek sey tam da budur.
          pos := 0;
          i := 0;
          while i < applied do
          begin
            fs.Position := pos;
            if fs.Read(h, SizeOf(h)) <> SizeOf(h) then Break;
            SetLength(valBuf, h.ValLen);
            if h.ValLen > 0 then
              if fs.Read(valBuf[0], h.ValLen) <> Integer(h.ValLen) then Break;
            { 2026-10-04: SkipWAL=True ZORUNLU. Bu kayitlar zaten
              .wal dosyasinda; AppendRec de yazarsa replay dongusu
              olusur (her replay gunlugu buyutur) ve ReplayWAL'in
              sonundaki DeleteFile anlamsizlasir. }
            if h.Flags = VDB_FLAG_DEL then
              AppendRec(h.Key, nil, True, False, True)
            else
              AppendRec(h.Key, valBuf, False, False, True);
            pos := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
            Inc(i);
          end;
          AppendBatchEnd(False);   // commit isareti (Recover icin ZORUNLU)
          CommitBatch;
          ownBatch := False;
        except
          if ownBatch then AbortBatch;
          raise;
        end;
      end;
    finally
      fs.Free;
    end;

    // 3) Uygulama tamam; .wal artik gereksiz.
    // badTail olsa da silinir: bozuk kuyruk zaten hicbir zaman
    // UYGULANAMAZ, dolayisiyla tutmanin veri kurtarma degeri yoktur
    // (silinmezse her Open'da ayni bozuk kuyruk tekrar tekrar okunur).
    DeleteFile(wp);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TVDb.CheckpointWAL: Boolean;
// 2026-10-04: ONCEDEN yalniz .wal dosyasini SILIYORDU - uygulanmamis
// kayitlar bu sayede KALICI OLARAK KAYBOLUYORDU. Simdi once replay
// edilir, sonra silinir; replay edilemiyorsa dosya SILINMEZ.
var
  wp: string;
begin
  FLock.Enter;
  try
    CheckOpen;
    wp := WalPath;
    if not FileExists(wp) then Exit(True);
    if not ReplayWAL then Exit(False);
    Result := not FileExists(wp);
  finally
    FLock.Leave;
  end;
end;

function TVDb.WalPath: string;
begin
  Result := ChangeFileExt(FPath, '.wal');
end;

// ============================================================================
// R-16 (2026-10-12): WAL ARSIVLEME + PITR (Point-In-Time Recovery)
// ============================================================================
//
// PostgreSQL'deki WAL arsivlemesinin sadeleştirilmiş hâli. Amacı:
// bir BACKUP alındıktan sonra oluşan degisikliklerin .wal dosyalarina
// BOLUNMEZ (segment rotasyonu), sonra da "belli bir ana kadar" geri
// alinabilmesi (PITR).
//
// Akis:
//   BACKUP TO 'x.odb'        -> tam kopya + o ana kadarki WAL arsivlenir
//   RECOVER TO TIMESTAMP 't' -> arsiv segmentleri t zamanina kadar,
//                                sirali olarak UYGULANIR
//
// Guvenlik: arsiv segmentleri .odb'den AYRI dosyalardir ve yalnizca
// oluşturulduklari veritabaninin adini tasiyorlar. Bir arsiv segmenti
// ANLAMINDA (magic/CRC) dogrulanir; bozuk segment PITR'i orada keser,
// sonraki segmentler UYGULANMAZ. Boylece veri bozulmaz, kismi
// kurtarma olur.

function TVDb.NowUnixMS: QWord;
var
  a: Int64;
begin
  a := DateTimeToUnix(Now) * 1000;
  if a < 0 then a := 0;
  Result := QWord(a);
end;

function TVDb.CopyFileRaw(const ASrc, ADst: string): Boolean;
// R-16: WAL segmenti kopyalama. FileCopy kullanmiyoruz cunku FPC'de
// FileCopy hedefte var olan dosyayi SILLER (ustune yazmaz); boylece
// bir onceki segmentin uzerine yazilma riski olurdu.
var
  fsIn, fsOut: TFileStream;
  buf: array of Byte;
  got: Integer;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  fsIn := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    fsOut := TFileStream.Create(ADst, fmCreate);
    try
      SetLength(buf, 65536);
      repeat
        got := fsIn.Read(buf[0], Length(buf));
        if got > 0 then fsOut.WriteBuffer(buf[0], got);
      until got <= 0;
      VDbFlushStream(fsOut);
      Result := True;
    finally
      fsOut.Free;
    end;
  finally
    fsIn.Free;
  end;
end;

function TVDb.BaseName: string;
begin
  Result := ChangeFileExt(ExtractFileName(FPath), '');
end;

function TVDb.SetArchiveDirCore(const ADir: string): string;
// R-16: goreli yollari .odb'nin yanina gore mutlaklastirir. Boylece
// veritabani tasindiginda arsiv yolu tasinmamis olmaz (yanlis yere
// arsiv yazip veri kaybetmektense hata vermek yeğdir).
begin
  if ADir = '' then Exit('');
  Result := ADir;
  if ExtractFilePath(Result) = '' then
    Result := IncludeTrailingPathDelimiter(ExtractFileDir(FPath)) + Result;
end;

function TVDb.ArchivePathFor(ASegment: Int64): string;
// R-16: segment numarasindan arsiv dosya adini uretir.
// Sekiz haneli sifir dolgu -> lexical siralama kronolojik siralamayla
// ayni olur (ReplaySegment'lar bunu varsayar).
begin
  Result := IncludeTrailingPathDelimiter(FArchiveDir) + BaseName +
    '_' + Format('%.8d', [ASegment]) + '.wal';
end;

procedure TVDb.EnsureArchiveDir;
begin
  if FArchiveDir = '' then Exit;
  EnsureArchiveDirHelper(FArchiveDir);
end;

function TVDb.NextSegmentNo: Int64;
// R-16: arsivdeki en buyuk segment numarasi + 1.
// Klasor bos/okunamazsa 1.
var
  sr: TSearchRec;
  n, best: Int64;
  p: string;
begin
  Result := 1;
  if FArchiveDir = '' then Exit;
  best := 0;
  try
    if FindFirst(IncludeTrailingPathDelimiter(FArchiveDir) + BaseName +
      '_????????.wal', faAnyFile or faHidden or faSysFile or faDirectory, sr) = 0 then
    try
      repeat
        if not DirectoryExists(ExcludeTrailingPathDelimiter(sr.Name) ) then
        begin
          p := Copy(sr.Name, Length(BaseName) + 2, 8);
          n := StrToIntDef(p, 0);
          if n > best then best := n;
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  except
    best := 0;   // dizin okunamazsa sifirdan basla
  end;
  Result := best + 1;
end;

function TVDb.CurrentWalSize: Int64;
var
  fs: TFileStream;
begin
  Result := 0;
  if not FileExists(WalPath) then Exit;
  fs := TFileStream.Create(WalPath, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

function TVDb.MaybeRotateWal(Force: Boolean): Int64;
// R-16: mevcut .wal'i arsive tasir ve yenisini bos baslatir.
// Doner: arsivlenen segmentin numarasi, arsivlenmediyse 0.
// Segment limiti 0 ise ve Force=False ise HICBIR sey yapilmaz
// (yalnizca BACKUP aninda zorla arsivlenir).
var
  seg: Int64;
  src, dst: string;
  fs: TFileStream;
begin
  Result := 0;
  if FArchiveDir = '' then Exit;
  if not Force and (FWalSegmentMax <= 0) then Exit;
  { Bos segmenti arsivlemeye deger degil. }
  if (not Force) and (CurrentWalSize = 0) then Exit;
  if (not Force) and (CurrentWalSize < FWalSegmentMax) then Exit;
  EnsureArchiveDirHelper(FArchiveDir);
  seg := NextSegmentNo;
  src := WalPath;
  if not FileExists(src) then Exit;
  dst := ArchivePathFor(seg);
  { R-17 Full: once .tmp'ye kopyala, ardindan atomik yeniden adlandir.
    Arsiv dizinini taramakta olan bir TCP gonderici (WalSenderLoop)
    ASLA yarim kopyalanmis bir segment okumamali; yeniden adlandirma
    ayni dizinde atomiktir. }
  if not CopyFileRaw(src, dst + '.tmp') then Exit;
  if FileExists(dst) then DeleteFile(dst);
  if not RenameFile(dst + '.tmp', dst) then Exit;
  fs := TFileStream.Create(src, fmCreate);  // yeni bos segment
  fs.Free;
  { Segmentin kalici olmasini sagla }
  VDbFlushDir(FArchiveDir);
  Result := seg;
end;

function TVDb.ListWalArchive: TStrArray;
// R-16: arsiv segmentlerini kronolojik sirada dondurur.
// Her eleman: <segment-no (8 hane)>|<bayt>
var
  sr: TSearchRec;
  lst: array of Int64;
  i, j, n: Integer;
  p: string;
begin
  Result := nil;
  SetLength(Result, 0);
  if FArchiveDir = '' then Exit;
  EnsureArchiveDir;
  SetLength(lst, 0);
  if FindFirst(IncludeTrailingPathDelimiter(FArchiveDir) + BaseName +
    '_????????.wal', faAnyFile or faHidden or faSysFile, sr) = 0 then
  try
    repeat
      p := Copy(sr.Name, Length(BaseName) + 2, 8);
      n := StrToIntDef(p, 0);
      if n > 0 then
      begin
        SetLength(lst, Length(lst) + 1);
        lst[High(lst)] := n;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  { kucukten buyuge sirala (insertion sort: segment sayisi kucuk) }
  for i := 1 to High(lst) do
  begin
    j := i;
    while (j > 0) and (lst[j - 1] > lst[j]) do
    begin
      n := lst[j];
      lst[j] := lst[j - 1];
      lst[j - 1] := n;
      Dec(j);
    end;
  end;
  SetLength(Result, Length(lst));
  for i := 0 to High(lst) do
    Result[i] := Format('%.8d', [lst[i]]) + '|' +
      IntToStr(ArchiveBytes(lst[i]));
end;

function TVDb.ArchiveBytes(ASegment: Int64): Int64;
var
  fs: TFileStream;
  p: string;
begin
  Result := 0;
  if FArchiveDir = '' then Exit;
  p := ArchivePathFor(ASegment);
  if not FileExists(p) then Exit;
  fs := TFileStream.Create(p, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

function TVDb.ArchiveEnabled: Boolean;
begin
  Result := FArchiveDir <> '';
end;

procedure TVDb.SetArchiveDir(const ADir: string);
{ R-16. Goreli yol .odb'nin yanina gore cozumlenir: arsiv, veritabani
  dosyasiyla birlikte tasinsa da yol BOZULMAZ. }
var
  d: string;
begin
  d := SetArchiveDirCore(ADir);
  if d = '' then
  begin
    FArchiveDir := '';
    Exit;
  end;
  EnsureArchiveDirHelper(d);
  FArchiveDir := d;
end;

procedure TVDb.EnsureArchiveDirHelper(const ADir: string);
begin
  if not ForceDirectories(ADir) then
    raise EVDbException.Create(ecIOError,
      'VDb: WAL arsiv dizini olusturulamadi: ' + ADir);
end;

function TVDb.GetArchiveDir: string;
begin
  Result := FArchiveDir;
end;

procedure TVDb.SetWalSegmentMax(AMax: Int64);
begin
  if AMax < 0 then FWalSegmentMax := 0
  else FWalSegmentMax := AMax;
end;

function TVDb.GetWalSegmentMax: Int64;
begin
  Result := FWalSegmentMax;
end;

function TVDb.CountSegmentValid(APath: string): Integer;
// R-16: bir arsiv segmentindeki gecERLI kayit sayisi.
// ReplayWAL/WalRecordCount ile AYNI dogrulama kurallari; bozuk
// kayitta durur.
var
  fs: TFileStream;
  h: TVDbWalHead;
  buf: TBytes;
  size, pos: Int64;
begin
  Result := 0;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    size := fs.Size;
    pos := 0;
    while pos + Int64(SizeOf(h)) <= size do
    begin
      fs.Position := pos;
      if fs.Read(h, SizeOf(h)) <> SizeOf(h) then Break;
      if h.Magic <> VDB_WAL_MAGIC then Break;
      if (h.Flags <> VDB_FLAG_PUT) and (h.Flags <> VDB_FLAG_DEL) then Break;
      if (h.Flags = VDB_FLAG_DEL) and (h.ValLen <> 0) then Break;
      if h.ValLen > VDB_MAX_VALUE then Break;
      if pos + Int64(SizeOf(h)) + Int64(h.ValLen) > size then Break;
      SetLength(buf, h.ValLen);
      if h.ValLen > 0 then
        if fs.Read(buf[0], h.ValLen) <> Integer(h.ValLen) then Break;
      if h.ValLen > 0 then
      begin
        if RecCrcWal(h.LSN, h.WalStamp, h.Key, h.ValLen, h.Flags,
          @buf[0]) <> h.Crc then Break;
      end
      else if RecCrcWal(h.LSN, h.WalStamp, h.Key, 0, h.Flags, nil) <> h.Crc then Break;
      Inc(Result);
      pos := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
    end;
  finally
    fs.Free;
  end;
end;

function TVDb.ApplySegment(APath: string; AStopStamp: QWord;
  AUseBatch: Boolean): Integer;
// R-16: arsiv segmentini bu veritabanina uygular.
// ATargetStamp semantigi: WAL zaman SIRALIDIR (LSN artar, damga
// artar). Bu yuzden ilk "hedefi asan" kayitta durulur; sonraki
// kayitlar da hedefi asar, uygulamak yanlis olur.
var
  fs: TFileStream;
  h: TVDbWalHead;
  buf: TBytes;
  size, pos: Int64;
  applied: Integer;
  ownBatch: Boolean;
  hb: TBytes;
begin
  Result := 0;
  if not FileExists(APath) then Exit;
  if FInBatch then
    raise EVDbException.Create(ecUnsupported,
      'VDb: batch icinde arsiv replay yapilamaz');
  applied := 0;
  ownBatch := False;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    size := fs.Size;
    pos := 0;
    while pos + Int64(SizeOf(h)) <= size do
    begin
      fs.Position := pos;
      if fs.Read(h, SizeOf(h)) <> SizeOf(h) then Break;
      if h.Magic <> VDB_WAL_MAGIC then Break;
      if (h.Flags <> VDB_FLAG_PUT) and (h.Flags <> VDB_FLAG_DEL) then Break;
      if (h.Flags = VDB_FLAG_DEL) and (h.ValLen <> 0) then Break;
      if h.ValLen > VDB_MAX_VALUE then Break;
      if pos + Int64(SizeOf(h)) + Int64(h.ValLen) > size then Break;
      SetLength(buf, h.ValLen);
      if h.ValLen > 0 then
        if fs.Read(buf[0], h.ValLen) <> Integer(h.ValLen) then Break;
      if h.ValLen > 0 then
      begin
        if RecCrcWal(h.LSN, h.WalStamp, h.Key, h.ValLen, h.Flags,
          @buf[0]) <> h.Crc then Break;
      end
      else if RecCrcWal(h.LSN, h.WalStamp, h.Key, 0, h.Flags, nil) <> h.Crc then Break;

      { zaman hedefi asildi mi? o ve sonrakiler uygulanmaz }
      if (AStopStamp > 0) and (h.WalStamp > AStopStamp) then Break;

{ BATCH BASINA: segment tek batch, ya hep ya hic uygulanir.
        SkipWAL=True: replay eden kaydi .wal'a YAZMAZ (yoksa dongu:
        segmenti okuyor, ana dosyaya yaziyor, .wal'i buyutuyor). }
      if AUseBatch and not ownBatch then
      begin
        BeginBatch;
        ownBatch := True;
      end;
      AppendRec(h.Key, buf, h.Flags = VDB_FLAG_DEL, True, True);
      Inc(applied);
      pos := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
    end;
  finally
    fs.Free;
  end;
  if ownBatch then CommitBatch;
  Result := applied;
end;

function TVDb.RecoverFromArchive(ATargetStamp: QWord): Integer;
// R-16: arsivdeki tum segmentleri sirayla uygular (PITR).
// Arsivlenmis veri zaten .odb'ye yazildigi icin bu "geri alma"
// degil, "ileri oynatma" yapar: BACKUP anindan sonraki degisiklikleri
// hedef zamana kadar .odb'ye uygular.
var
  lst: TStrArray;
  i, total, seg, n: Integer;
  sp: string;
  firstLsn: QWord;
begin
  FLock.Enter;
  try
    CheckOpen;
    Result := 0;
    if FArchiveDir = '' then Exit;
    lst := ListWalArchive;
    total := 0;
    for i := 0 to High(lst) do
    begin
      { lst[i] = 'NNNNNNNN|bayt' }
      sp := Copy(lst[i], 1, Pos('|', lst[i] + '|') - 1);
      seg := StrToIntDef(sp, 0);
      if seg = 0 then Continue;
      n := ApplySegment(ArchivePathFor(seg), ATargetStamp, True);
      { Segment hedef zamani gecmisse devam etmenin anlami yok. }
      if (ATargetStamp > 0) and (n = 0) and
         (CountSegmentValid(ArchivePathFor(seg)) > 0) then Break;
      Inc(total, n);
    end;
    Result := total;
  finally
    FLock.Leave;
  end;
end;

function TVDb.ApplyWalSegmentFile(const APath: string): Integer;
// R-17: Harici bir WAL segment dosyasini uygular (log shipping).
// ApplySegment ile ayni dogrulama/batch mantigi; hedef zaman siniri
// yoktur (tum gecerli kayitlar uygulanir).
begin
  FLock.Enter;
  try
    CheckOpen;
    Result := 0;
    if not FileExists(APath) then Exit;
    Result := ApplySegment(APath, 0, True);
  finally
    FLock.Leave;
  end;
end;

function TVDb.HasWAL: Boolean;
// F2-4: kilit + CheckOpen.
var
  wp: string;
begin
  FLock.Enter;
  try
    CheckOpen;
    wp := ChangeFileExt(FPath, '.wal');
    Result := FileExists(wp);
  finally
    FLock.Leave;
  end;
end;

function TVDb.WalRecordCount: Integer;
// 2026-10-04 (M9): Bekleyen GECERLI WAL kayit sayisi. Yonetim
// programi "kac kayit uygulanacak" sorusunu bu metotla yanitlar.
//
// YAN ETKISI YOK: dosya yalnizca OKUNUR; hicbir kayit uygulanmaz,
// hicbir sey silinmez. ReplayWAL ile ayni dogrulama kurallarini
// (magic / bayrak / uzunluk / CRC) kullanir ve gecersiz kayitta
// durur; boylece "uygulanacak kayit" sayisini gercekten bildirir.
//
// Replay icin ONEMLI: bu sayim ReplayWAL'daki taramanin KOPYASI
// olmali. Iki yeri ayirirsak (ornegin biri bayragi, digeri CRC'yi
// kontrol ederse) sayi yaniltici olur.
var
  fs: TFileStream;
  wp: string;
  h: TVDbWalHead;
  valBuf: TBytes;
  walSize, pos: Int64;
begin
  FLock.Enter;
  try
    CheckOpen;
    Result := 0;
    wp := WalPath;
    if not FileExists(wp) then Exit;
    fs := TFileStream.Create(wp, fmOpenRead);
    try
      walSize := fs.Size;
      pos := 0;
      while pos + Int64(SizeOf(h)) <= walSize do
      begin
        fs.Position := pos;
        if fs.Read(h, SizeOf(h)) <> SizeOf(h) then Break;
        if h.Magic <> VDB_WAL_MAGIC then Break;
        if (h.Flags <> VDB_FLAG_PUT) and (h.Flags <> VDB_FLAG_DEL) then Break;
        if (h.Flags = VDB_FLAG_DEL) and (h.ValLen <> 0) then Break;
        if h.ValLen > VDB_MAX_VALUE then Break;
        if pos + Int64(SizeOf(h)) + Int64(h.ValLen) > walSize then Break;
        SetLength(valBuf, h.ValLen);
        if h.ValLen > 0 then
          if fs.Read(valBuf[0], h.ValLen) <> Integer(h.ValLen) then Break;
        if h.ValLen > 0 then
        begin
          if RecCrcWal(h.LSN, h.WalStamp, h.Key, h.ValLen, h.Flags,
          @valBuf[0]) <> h.Crc then Break;
        end
        else if RecCrcWal(h.LSN, h.WalStamp, h.Key, 0, h.Flags, nil) <> h.Crc then
          Break;
        Inc(Result);
        pos := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
      end;
    finally
      fs.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TVDb.ReadWalEntry(AIndex: Integer; out AKey: QWord;
  out AFlags: Byte; out AValue: TBytes): Boolean;
// 2026-10-05 (CDC / Time Travel): siradaki GECERLI WAL kaydini dondurur.
// Dogrulama kurallari ReplayWAL/WalRecordCount ile AYNI (magic, bayrak,
// uzunluk, CRC, yirtik kuyruk). Bozuk kayitta dongu kesilir ve False
// donulur; dosya yalnizca OKUNUR.
var
  fs: TFileStream;
  h: TVDbWalHead;
  walSize, pos: Int64;
  idx: Integer;
begin
  Result := False;
  AKey := 0;
  AFlags := 0;
  AValue := nil;
  if AIndex < 0 then Exit;
  FLock.Enter;
  try
    CheckOpen;
    if not FileExists(WalPath) then Exit;
    fs := TFileStream.Create(WalPath, fmOpenRead);
    try
      walSize := fs.Size;
      pos := 0;
      idx := 0;
      while pos + Int64(SizeOf(h)) <= walSize do
      begin
        fs.Position := pos;
        if fs.Read(h, SizeOf(h)) <> SizeOf(h) then Break;
        if h.Magic <> VDB_WAL_MAGIC then Break;
        if (h.Flags <> VDB_FLAG_PUT) and (h.Flags <> VDB_FLAG_DEL) then Break;
        if (h.Flags = VDB_FLAG_DEL) and (h.ValLen <> 0) then Break;
        if h.ValLen > VDB_MAX_VALUE then Break;
        if pos + Int64(SizeOf(h)) + Int64(h.ValLen) > walSize then Break;
        SetLength(AValue, h.ValLen);
        if h.ValLen > 0 then
          if fs.Read(AValue[0], h.ValLen) <> Integer(h.ValLen) then Break;
        if h.ValLen > 0 then
        begin
          if RecCrcWal(h.LSN, h.WalStamp, h.Key, h.ValLen, h.Flags,
          @AValue[0]) <> h.Crc then Break;
        end
        else if RecCrcWal(h.LSN, h.WalStamp, h.Key, 0, h.Flags, nil) <> h.Crc then
          Break;
        if idx = AIndex then
        begin
          AKey := h.Key;
          AFlags := h.Flags;
          Result := True;
          Exit;
        end;
        Inc(idx);
        pos := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
      end;
      AValue := nil;
    finally
      fs.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TVDb.Verify(out Report: string): Boolean;
// Salt-okunur butunluk denetimi: baslik + tum kayitlarin CRC + seq
// surekliligi. Dosyayi degistirmez (truncate yok).
//
// BELLEK: dosya TAMAMINI bellege almaz; sabit 64 KB tamponla kayit kayit
// okunur. (ONCEDEN `SetLength(buf, fsize)` idi -> 500 MB dosyada OOM.)
var
  buf: TBytes;
  fsize, pos, next: Int64;
  fh: TVDbFileHead;
  h: TVDbRecHead;
  c: LongWord;
  pv: PByte;
  n, nPut, nDel, nEnd, nEnc: Int64;
  expSeq: QWord;
  first: Boolean;
  blockCrc: LongWord;
  blockStart: Int64;
  nBlock: Integer;
  sawBlock: Boolean;

  procedure Bad(const Fmt: string; const Args: array of const);
  begin
    Report := Format('BOZUK @%d: ', [pos]) + Format(Fmt, Args);
  end;

  function CrcRange(AStart: Int64; ALen: Int64; out ACrc: LongWord): Boolean;
  var
    b: TBytes;
    rem: Int64;
    got: Integer;
  begin
    Result := False;
    if (AStart < VDB_HDR_SIZE) or (ALen < 0) or (AStart + ALen > fsize) then Exit;
    SetLength(b, 65536);
    ACrc := VDbCrc32Init;
    FS.Position := AStart;
    rem := ALen;
    while rem > 0 do
    begin
      if rem > Int64(Length(b)) then got := Length(b) else got := Integer(rem);
      if FS.Read(b[0], got) <> got then Exit;
      ACrc := VDbCrc32Update(ACrc, b[0], got);
      Dec(rem, got);
    end;
    ACrc := VDbCrc32Final(ACrc);
    Result := True;
  end;

begin
  Result := False;
  Report := '';
  FLock.Enter;
  try
    CheckOpen;
    fsize := FS.Size;
    // ONCEDEN dosyanin TAMAMI bellege aliniyordu:
    //   SetLength(buf, fsize); FS.ReadBuffer(buf[0], fsize);
    // 500 MB dosyada OutOfMemoryError; Verify GUI'de HER ACILISTA
    // calistigi icin bu pratik bir crash sebebiydi.
    // SIMDI sabit boyutlu tamponla kayit kayit okunur (ScanAll ile ayni).
    if fsize < VDB_HDR_SIZE then begin Report := 'BOZUK: dosya basliktan kisa'; Exit; end;
    SetLength(buf, 65536);
    FS.Position := 0;
    FS.ReadBuffer(buf[0], VDB_HDR_SIZE);
    Move(buf[0], fh, SizeOf(fh));
    if fh.Magic <> VDB_FILE_MAGIC then begin Report := 'BOZUK: VODB imzasi yok'; Exit; end;
    if fh.Ver <> VDB_FILE_VER then begin Report := 'BOZUK: desteklenmeyen surum'; Exit; end;
    if fh.Crc <> HeadCrc(fh) then begin Report := 'BOZUK: baslik CRC'; Exit; end;
    pos := VDB_HDR_SIZE;
    n := 0; nPut := 0; nDel := 0; nEnd := 0; nEnc := 0; first := True; expSeq := 0;
    blockCrc := VDbCrc32Init;
    blockStart := pos;
    nBlock := 0;
    sawBlock := False;
    while pos + Int64(SizeOf(h)) <= fsize do
    begin
      FS.Position := pos;
      if FS.Read(h, SizeOf(h)) <> SizeOf(h) then
      begin Bad('okunamadi', []); Exit; end;
      if h.Magic <> VDB_MAGIC then begin Bad('kayit imzasi yok', []); Exit; end;
      if h.ValLen > VDB_MAX_VALUE then begin Bad('asiri vallen=%d', [h.ValLen]); Exit; end;
      next := pos + Int64(SizeOf(h)) + Int64(h.ValLen);
      if next > fsize then begin Bad('yirtik kuyruk', []); Exit; end;
      { H5: blok footer'i. Crc alani, footer'in Key alanindaki baslangictan
        bu footer'a kadar olan blok baytlarinin CRC32'sidir. Normal
        durumda kumulatif blockCrc yeterlidir; V1/V2'den yukseltilmis
        dosyada ilk footer'in baslangici FDataStart'tan ileridedir, o
        durumda aralik yeniden hesaplanir. }
      if h.Flags = VDB_FLAG_BLOCKCRC then
      begin
        if (h.ValLen <> 0) or (h.Seq <> 0) then
        begin Bad('blok footer bozuk', []); Exit; end;
        if h.Key <> QWord(blockStart) then
        begin
          if not CrcRange(Int64(h.Key), pos - Int64(h.Key), c) then
          begin Bad('blok araligi okunamadi', []); Exit; end;
        end
        else
          c := VDbCrc32Final(blockCrc);
        if c <> h.Crc then
        begin Bad('blok CRC tutmadi (baslangic=%d)', [Int64(h.Key)]); Exit; end;
        Inc(nBlock);
        sawBlock := True;
        blockCrc := VDbCrc32Init;
        blockStart := next;
        pos := next;
        Continue;
      end;
      blockCrc := VDbCrc32Update(blockCrc, h, SizeOf(h));
      if h.ValLen > 0 then
      begin
        if Length(buf) < Integer(h.ValLen) then
          SetLength(buf, h.ValLen);
        if FS.Read(buf[0], h.ValLen) <> Integer(h.ValLen) then
        begin Bad('deger okunamadi', []); Exit; end;
        pv := @buf[0];
        blockCrc := VDbCrc32Update(blockCrc, buf[0], Integer(h.ValLen));
      end
      else
        pv := nil;
      c := RecCrc(h.Seq, h.Key, h.ValLen, h.Flags, pv);
      if c <> h.Crc then begin Bad('CRC tutmadi key=%d', [h.Key]); Exit; end;
      if not RecFlagsValid(h.Flags, h.ValLen, True) then
      begin Bad('bayrak=%d', [h.Flags]); Exit; end;
      // F2-17: BATCHEND isareti Key=0/ValLen=0 olmali; aksi halde
      // Recover'da "commit isareti" yanlis yorumlanir.
      if (h.Flags = VDB_FLAG_BATCHEND) and ((h.Key <> 0) or (h.ValLen <> 0)) then
      begin Bad('BATCHEND bozuk (key=%d vallen=%d)', [h.Key, h.ValLen]); Exit; end;
      if first then begin expSeq := h.Seq; first := False; end;
      if h.Seq <> expSeq then begin Bad('seq kirik beklenen=%d gelen=%d', [expSeq, h.Seq]); Exit; end;
      Inc(expSeq);
      // F2-17: ONCEDEN "del degilse put" sayiliyordu; BATCHEND kayitlari
      // da put olarak sayildigi icin rapor yanilticiydi (399 put + 399
      // BATCHEND -> "put=798"). Artik ucuncu sayac ayri.
      // 2026-10-05 Adim 16: sifreli kayit sayaci.
      if h.Flags = VDB_FLAG_BATCHEND then
        Inc(nEnd)
      else
      begin
        case h.Flags and not VDB_FLAG_ENCRYPTED of
          VDB_FLAG_PUT: Inc(nPut);
          VDB_FLAG_DEL: Inc(nDel);
        end;
        if (h.Flags and VDB_FLAG_ENCRYPTED) <> 0 then
          Inc(nEnc);
      end;
      Inc(n);
      pos := next;
    end;
    if pos <> fsize then begin Bad('artik %d byte', [fsize - pos]); Exit; end;
    if sawBlock and (blockCrc <> VDbCrc32Init) then
    begin Bad('blok footer yok (baslangic=%d)', [blockStart]); Exit; end;
    Report := Format('OK kayit=%d put=%d del=%d batchend=%d sifreli=%d canli=%d olu=%d boyut=%d blok=%d',
      [n, nPut, nDel, nEnd, nEnc, FIndex.Count, FDeadBytes, fsize, nBlock]);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TVDb.GetIsOpen: Boolean;
begin
  Result := not FClosed;
end;

function TVDb.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FIndex.Count;
  finally
    FLock.Leave;
  end;
end;

function TVDb.GetAllKeys: TQWordArray;
var
  k: QWord;
  i: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, FIndex.Count);
    i := 0;
    for k in FIndex.Keys do
    begin
      Result[i] := k;
      Inc(i);
    end;
  finally
    FLock.Leave;
  end;
end;

  procedure TVDb.ScanAll(out Keys: TQWordArray; out Vals: TValArray;
    TableFilter: Integer);
  // R-01 MVCC: batch icinde transaction snapshot'indan taran; batch disi eski ScanAll (High(QWord) = her sey gorunur)
  // R-26: TableFilter >= 0 ise yalnizca o tablonun satirlari dosyadan okunur.
  begin
    if BatchIsMine and (FSnapshotSeq > 0) then
      ScanSnapshot(Keys, Vals, FSnapshotSeq, -1, TableFilter)
    else
      ScanSnapshot(Keys, Vals, High(QWord), -1, TableFilter);
  end;


{ R-03/R-04: UPSERT / RETURNING }

function TVDb.InsertReturning(const Table: string; const ColNames, Values: TStrArray;
  out OutPk: string; out OutVals: TStrArray): Boolean;
begin
  Result := False;
  OutPk := '';
  OutVals := nil;
  raise EVDbException.Create(ecUnsupported, 'InsertReturning not implemented');
end;

function TVDb.UpsertRowReturning(const Table: string; const ColNames, Values: TStrArray;
  OnConflictAction: Integer; const OnConflictTarget: TStrArray;
  const SetValues: array of TUpdateAssignment;
  out OutPk: string; out OutVals: TStrArray): Boolean;
begin
  Result := False;
  OutPk := '';
  OutVals := nil;
  raise EVDbException.Create(ecUnsupported, 'UpsertRowReturning not implemented');
end;

{ TVDbKvStore }

constructor TVDbKvStore.Create(ADb: TVDb);
begin
  inherited Create;
  FDb := ADb;
end;

procedure TVDbKvStore.Put(Key: QWord; const Value: TBytes);
begin
  FDb.Put(Key, Value);
end;

function TVDbKvStore.Get(Key: QWord; out Value: TBytes): Boolean;
begin
  Result := FDb.Get(Key, Value);
end;

function TVDbKvStore.Delete(Key: QWord): Boolean;
begin
  Result := FDb.Delete(Key);
end;

procedure TVDbKvStore.ScanAll(out Keys: TQWordArray; out Vals: TValArray;
  TableFilter: Integer);
begin
  FDb.ScanAll(Keys, Vals, TableFilter);
end;

initialization
  { R-23: Motorun metin formati UTF-8'dir. FPC'nin AnsiString donusum
    kod sayfasini UTF-8 yapar. ONCEDEN bu, engine'in FileUtil (LazUtils)
    kullanmasi sayesinde LazUtils baslatmasindan geliyordu; R-23'te
    FileUtil bagimliligi kaldirilinca bu baslatma kayboldu ve Windows'ta
    kod sayfasi sistem ACP'sine (cp1254) dustu. Sonuc: UTF-8 literal'ler
    ile motor degerleri farkli kod sayfalarinda karsilastiriliyor, Turkce
    ve Unicode veri (collation, UPPER/LOWER, XML, BLOB) bozuluyordu.
    Artik platformdan bagimsiz olarak motor kendisi UTF-8'e sabitler. }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
