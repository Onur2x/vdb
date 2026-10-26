unit VDbBackendV3;

{ VDB v3 - Sayfa motorunu IVDbBackend'e baglayan backend (Sprint 2 / 2.4)

  Ust katman (VDbTable/VDbSql/VDbExecutor) bu arayuzu tanir; altinda
  4 KB sayfa motoru + sayfa imajli WAL vardir.

  ISLEM (BATCH) MODELI - tek yazar, bellek ustu kaplama:
    BeginBatch  : kaplama acilir (yazma yok)
    Put/Delete  : once KAPLAMAYA yazilir (okuma da kaplamayi gorur)
    CommitBatch : kaplama sirayla motora uygulanir, Commit(True) + esik
                  asilmissa Checkpoint
    AbortBatch  : kaplama atilir; motora HICBIR SEY yazilmadi -> gercek
                  geri alma (v2'deki "tablo indeksleri onarilmaz" sorunu yok)

  Kaplamanin bedeli bellek: 200k satirlik toplu yuklemede ~10 MB. WAL
  tamponu da ayni sinirda; v3.1'de cerceveler WAL dosyasina indeksli
  yazilacak ve kaplama kalkacak.

  SILME/GUNCELLEME: heap Delete/Update O(1) (slot kararli, baytlar yerinde).
  SAYIM: Count = heap.Count + kaplama farki (O(1)).

  DESTEKLENMEYEN (v3.0): kayit sifreleme (Sprint 3.4), range tarama
  (v3.1 B+tree), replication (ecNotSupported).
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections,
  VDbBackendApi, VDbPage, VDbPageStore, VDbPageHeap, VDbPageWal, VDbPageEngine,
  VDbIdxFile, VDbSync, VDbCrypt, VDbChangeLog;

const
  { Bu boyuttan buyuk WAL'de commit sonrasi checkpoint yapilir. Cok kucuk
    deger her commit'te tam sayfa yazimi demek; cok buyuk deger cokme
    sonrasi replay suresini buyutur. }
  VDB_V3_CHECKPOINT_BYTES = 8 * 1024 * 1024;

type
  EVdbBackendV3 = class(Exception);

  { v3.9: motor kilidi. ONCEDEN duz `TCriticalSection` idi ve ic ice
    cagrilar (ScanAll -> ScanCb -> OwnSet gibi) yalnizca kritik bolumun
    YENIDEN GIRISLI olmasi VARSAYIMINA dayaniyordu. Artik her is parcacigi
    TUTTUGU kilitlerin yiginini (threadvar) tasir:
      - Ayni is parcacigindan giris: derinlik artar, kritik bolume HIC
        girilmez -> "kritik bolum yeniden girisli" varsayimi KALMADI.
      - Baska is parcacigindan giris: normal karsilikli dislama (bekler).
      - Paylasilan alanlar (FDepth/FMaxDepth) yeniden giris KARARINDA
        okunmaz (yalnizca sahibi ve test erisimcileri okur); boylece zayif
        bellek sirali platformlarda eski sahip degerini gorup yanlislikla
        "yeniden giris" sayma riski de yoktur.
      - Derinlik sifira donmezse Leave eksiktir; `Depth` testte yakalar. }
  TVdbGate = class
  private
    FCs: TCriticalSection;
    FDepth: Integer;
    FMaxDepth: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enter;
    procedure Leave;
    function Depth: Integer;
    function MaxDepth: Integer;
  end;

  TVdbBackendV3 = class(TInterfacedObject, IVDbBackend)
  private
    type
      TBatchRec = record
        Present: Boolean;
        Value: TBytes;
      end;
      { v3.2 savepoint gunlugu: bir anahtarin savepoint'ten ONCEKI hali.
        HadBefore=False ise anahtar FBatch'te hic yoktu; geri almada
        FBatch'ten SILINIR (bos bir "Present=False" kaydi birakmak
        Delete'in "once var miydi" yanitini bozardi). }
      TSavepointKeyRec = record
        HadBefore: Boolean;
        Rec: TBatchRec;
      end;
      { v3.2: tek bir savepoint. Journal yalnizca O savepoint'ten sonra
        DEGISEN anahtarlari tutar (tum partiyi kopyalamak 200k satirlik
        partide her SAVEPOINT'te O(n) bellek demekti). }
      TSavepointRec = record
        Name: string;
        OrderLen: Integer;                 // FOrder'in savepoint anindaki uzunlugu
        Journal: TDictionary<QWord, TSavepointKeyRec>;
        TagDelta: TDictionary<Integer, Int64>;  // FBatchTagDelta kopyasi
      end;
      { v3.4: OTURUM BASINA YAZMA KUMESI (cok oturumlu yazma).
        Once tek bir global parti tamponu vardi ve ikinci oturum yazmaya
        kalkinca "baska bir oturumun acik islemi var" hatasi aliyordu. Artik
        her oturum KENDI kumesinde biriktirir; motor ancak COMMIT'te
        degisir. Boylece iki oturum birbirinin commit edilmemis yazisini
        gormez ve birbirini islem suresi boyunca BLOKLAMAZ.

        Before: anahtarin ILK yazimdan onceki MOTOR degeri. Commit'te motor
        degeri hala ayni mi diye karsilastirilir; degistiyse kayip guncelleme
        riski vardir ve commit ACIK hatayla durur (veri kaybi yok). }
      TWriteSet = class
        Session: Cardinal;
        Map: TDictionary<QWord, TBatchRec>;
        Order: TList<QWord>;
        Before: TDictionary<QWord, TBatchRec>;
        TagDelta: TDictionary<Integer, Int64>;
        Savepoints: TList<TSavepointRec>;
        { v3.6: BeginBatch anindaki global commit sayaci. Before-image
          SEYREK tutulur (bkz. NoteBefore): yalnizca cakismanin MUMKUN
          oldugu durumda kaydedilir. Bu alan, "ben basladiktan sonra baska
          oturum commit etti mi" sorusunu yanitlar. }
        StartGen: Int64;
        { v3.6: "artik before-image GEREKLI" bayragi. Yalnizca biz acikken
          BASKA bir oturum commit ederse True olur (o commit'ten sonra motor
          degerleri degismis olabilir). Bayrak True olana kadar satir basina
          ne kilit ne motor okumasi yapilir; boylece tek yazarli toplu
          INSERT'te MVCC maliyeti SIFIRA iner. }
        NeedBefore: Boolean;
        constructor Create(ASession: Cardinal);
        destructor Destroy; override;
      end;
    var
      FEng: TVdbPageEngine;
      FPath: string;
      { v3.2: cok okuyucu / tek yazici. }
      FReadOnly: Boolean;
      FBusyMs: Integer;
      { v3.4: oturum kimligi -> o oturumun acik yazma kumesi. }
      FSets: TDictionary<Cardinal, TWriteSet>;
      { v3.6: commit sayaci + "baskasi dokundu" defteri.
        FCommitGen her basarili commit'te artar. FAlien, baska bir yazma
        kumesi ACIKKEN commit edilen anahtarlari (anahtar -> o commit'in
        gen degeri) tutar. Before-image seyrek tutuldugu icin, hizli yolda
        yazilmis bir anahtarin cakismasi bu defterden anlasilir. Defter
        yalnizca ortada acik kume varken dolar ve hic kume kalmayinca
        temizlenir. }
      FCommitGen: Int64;
      FAlien: TDictionary<QWord, Int64>;
      { Motor erisimini (ve FSets'i) serilestiren ic kilit. TEK backend
        birden fazla is parcacigi tarafindan paylasilabilsin diye; islemler
        ARASINDA tutulmaz (uzun islem baska oturumu kilitlemez). }
      FEngCs: TVdbGate;
      { v4: MANTIKSAL DEGISIM GUNLUGU. Her commit'in satir duzeyi
        kayitlarini <db>.log\ altina yazar; PITR (RECOVER TO TIMESTAMP,
        AS OF TIMESTAMP/VERSION) ve replikasyon bunun uzerine kurulur.
        Gunluk kapaliysa (dizin olusturulamadi) yazma yolu DEGISMEZ. }
      FLog: TVdbChangeLog;
      FLogInGroup: Boolean;
      FLogProblem: string;
      FLogBaseSeq: Int64;
      { v4 replikasyon: uygulama penceresinde yerel gunluge yazim kapali. }
      FLogSuspended: Boolean;
      { v4: PITR replay'i sirasinda hedef motor (gecici dosya) ve son
        hata nedeni. Replay geri cagirimi bu alanlari kullanir. }
      FReplayEng: TVdbPageEngine;
      FReplayErr: string;
      FReplayLastSeq: Int64;
      FReplayLastTs: Int64;
      { Sprint 3.12: parti anahtarlarinin GELIS SIRASI. TDictionary
        dolasimi rastgele oldugu icin ApplyBatch sayfalara sicramali
        yaziyordu (olculen: 200k toplu yazim 8,0 us/satir; sirali
        yazimda motor 1,7 us/satir). Ayni veri, ayni atomiklik;
        yalniz uygulama sirasi giris sirasi olur.
        v3.4: bu alanlar artik OTURUM BASINA yazma kumesindedir; asagidaki
        ozellikler cagiran oturumun kumesine cozulur (yoksa nil/False). }
      FRowTag: TVDbRowTagFunc;
      FBeforeCommit: TDbCommitHook;
      FCheckpointBytes: Int64;
      FDirty: Boolean;
      FPoolPages: Integer;
      FScanKeys: TQWordArray;
      FScanVals: TValArray;
      FScanN: Integer;
      FScanCap: Integer;
      FScanFilter: Integer;
      { v3.9: tarama boyunca cagiran oturumun yazma kumesi BIR kez cozulur.
        ONCEDEN ScanCb her satirda BatchIsMine + BatchMap cagirip 3 kez
        OwnSet (kilit + oturum sozlugu aramasi) yapiyordu. }
      FScanSet: TWriteSet;
      { v3.1: ScanRawIterAll dogrudan akitilir (satir basina dizi buyutmesi
        ve toplu kopyalama YOK). }
      FStreamCb: TVDbRawCb;
      FStreamUser: Pointer;
      { v3.3: sayfa numarali akitma (sayfa duzeyi zone map). }
      FStreamPageCb: TVDbRawPageCb;
      FStreamPageUser: Pointer;
      FStreamAbort: Boolean;
      FStreamFilter: Integer;
      { v3.1: satir etiketi icin tarama basina BIR kez ayrilan kucuk tampon
        (satir basina tahsis YOK). }
      FStreamTagBuf: TBytes;
      FCompactEng: TVdbPageEngine;
      FCompactN: Int64;
      { Sprint 3.4: acilis anahtari (parola Open'da turetilir, sonra
        yalniz ham anahtar tutulur; VACUUM/RESTORE yeniden acarken kullanilir). }
      FKey: TBytes;
      FPassword: string;
      FHasPassword: Boolean;
      { v3.1: tablo basina canli satir sayaci. TAM TARAMAYLA AYNI YUKLEMI
        kullanir (FRowTag), kalici DEGILDIR: acilista bir kez tam taramayla
        kurulur, yazma yolunda artimli guncellenir. Bayatlama/cokme riski
        yoktur (dogru kaynak her zaman motorun kendisidir). }
      FTagCounts: TDictionary<Integer, Int64>;
      FTagBuf: TBytes;
      { Sayac kuruldu mu? False ise tutulan harita guvenilmez; ilk COUNT
        isteginde tam taramayla kurulur. }
      FTagCountsValid: Boolean;
      { v3.2: otomatik sikistirma (H25). Varsayilan KAPALI; commit'ten SONRA
        yalniz esik asilinca calisir. Hata commit'i bozmaz. }
      FAutoCompactOn: Boolean;
      FAutoCompactRatio: Double;
      FAutoCompactMinBytes: Int64;
      FAutoCompactCount: Int64;
      FAutoCompactBusy: Boolean;
      FLastAutoCompactError: string;
      { v3.7: gunluk budama (retention). Varsayilan KAPALI; AutoCompact gibi. }
      FLogPruneOn: Boolean;
      FLogPruneDays: Integer;
      FLogPruneBases: Integer;
      FLogPruneErr: string;
      procedure MaybeLogPrune;
      function ValBytes: Int64;
      procedure MaybeAutoCompact;
      function AutoCompactBody(out OldBytes, NewBytes: Int64;
        MaxDeadRatio: Double; MinBytes: Int64): Boolean;
      { v3.4: cagiran oturumun yazma kumesi var mi? (eski BatchIsMine) }
      function BatchIsMine: Boolean;
      { v3.4: artik baska oturumun acik islemi HATA degildir; her oturum
        kendi kumesinde calisir. Yalniz salt-okunur denetimi kalir. }
      procedure RequireBatchWrite;
      { v3.4: oturum basina yazma kumesine cozulen erisimciler. }
      function OwnSet: TWriteSet;
      function GetBatchMap: TDictionary<QWord, TBatchRec>;
      function GetBatchOrder: TList<QWord>;
      function GetBatchTagDelta: TDictionary<Integer, Int64>;
      function GetSavepoints: TList<TSavepointRec>;
      function GetBatchOpen: Boolean;
      property BatchMap: TDictionary<QWord, TBatchRec> read GetBatchMap;
      property BatchOrder: TList<QWord> read GetBatchOrder;
      property BatchTagDelta: TDictionary<Integer, Int64> read GetBatchTagDelta;
      property Savepoints: TList<TSavepointRec> read GetSavepoints;
      property BatchOpen: Boolean read GetBatchOpen;

    procedure InitBackend(const ADbPath: string; ACreate: Boolean;
      APoolPages: Integer; AReadOnly: Boolean = False;
      ABusyMs: Integer = VDB_DEF_BUSY_MS);
    { v3.2: salt-okunur oturumda yazma denemelerini acik hataya cevirir. }
    procedure RequireWritable;
    function NewEngine(const APath: string): TVdbPageEngine;
    function GetEncrypted: Boolean;
    function GetIsReadOnly: Boolean;
    function GetBusyTimeoutMs: Integer;
    { --- v4: mantiksal degisim gunlugu --- }
    function LogTag(const V: TBytes): Integer;
    procedure OpenChangeLog;
    procedure EnsureLogBase(AFlags: LongWord; const AReason: string);
    procedure LogPut(AKey: QWord; const AOld, ANew: TBytes);
    procedure LogDel(AKey: QWord; const AOld: TBytes);
    procedure LogFinish;
    procedure LogAbort;
    procedure LogReplayCb(const E: TVdbLogEntry);
    function BuildLogSnapshotBody(TimestampMs, Version: Int64;
      const DestPath: string;
      out ActualTsMs, ActualSeq: Int64): Boolean;
    procedure ApplyBatch;
    { v3.4: anahtarin ILK yazimdan onceki motor degerini saklar (cakisma
      denetimi icin). }
    procedure NoteBefore(S: TWriteSet; Key: QWord);
    { v3.4: commit ONCESI cakisma denetimi. Hicbir sey uygulanmadan once
      tum anahtarlar karsilastirilir; boylece yarim uygulama olmaz. }
    procedure VerifyNoConflict(S: TWriteSet);
    function EffectiveCount: Integer;
    procedure MaybeCheckpoint;
    function PassFilter(Key: QWord; const Value: TBytes;
      TableFilter: Integer): Boolean;
    procedure ScanCb(Key: QWord; const Value: TBytes);
    { v3.2: AS OF tarama geri cagirimi. Canli partinin kaplamasi BILEREK
      karistirilmaz: anlik goruntu yalniz commit edilmis sayfalardan gelir. }
    procedure AsOfCb(Key: QWord; const Value: TBytes);
    { v3.1: streaming tarama geri cagirimi (sifir-kopya: Data sayfa icindedir). }
    procedure StreamCbRaw(Key: QWord; Data: PByte; Len: Integer);
    { v3.3: sayfa numarali akitma (sayfa duzeyi zone map budamasi). }
    procedure StreamCbRawPaged(Key: QWord; Data: PByte; Len: Integer;
      PageNo: LongWord);
    { v3.1: etiket sayaci yardimcilari. }
    function TagOf(Data: PByte; Len: Integer): Integer;
    procedure TagAdd(Tag: Integer; Delta: Int64);
    procedure TagBuildCb(Key: QWord; Data: PByte; Len: Integer);
    procedure RebuildTagCounts;
    function LoadTagCountsFromIdx: Boolean;
    procedure GetTagSummary(out Tags: TVdbIdxTagArray);
    procedure MergeTagDeltas;
    { Sprint 3.3: VACUUM/Compact yardimcilari. }
    procedure CompactCb(Key: QWord; const Value: TBytes);
    procedure SwapDbFile(const NewFilePath: string);
    { v3.2: ALTER DATABASE KEY. Yeni dosya yeni anahtar/parola ile yazilir;
      basarisizlikta ESKI kimlik bilgileri geri kurulur (dosya .bak'tan
      donerken yeni parolayla acmaya calismak backend'i kilitsiz birakirdi). }
    procedure SwapDbFileWith(const NewFilePath: string;
      const AKey: TBytes; const APassword: string; AHasPassword: Boolean);
    { v3.2: savepoint yardimcilari. }
    procedure JournalKey(Key: QWord);
    procedure ClearSavepoints;
    function FindSavepoint(const Name: string): Integer;
  public
    { ADbPath: .odb dosya yolu. ACreate=True ise yoksa olusturur.
      ABusyMs: yazar kilidi icin bekleme (ms); 0 = bekleme yok.
      v3.2: cok okuyucu / tek yazici. }
    constructor Create(const ADbPath: string; ACreate: Boolean = True;
      APoolPages: Integer = VDB_DEF_POOL;
      ABusyMs: Integer = VDB_DEF_BUSY_MS);

    { Sprint 3.4: sifreli v3 dosyasi. Anahtar 32 baytlık AES-256'dir;
      parola verilirse PBKDF2-SHA256 ile turetilir. Sifresiz dosyaya
      anahtar vermek net hatadir. }
    constructor CreateWithKey(const ADbPath: string; const AKey: TBytes;
      ACreate: Boolean = True; APoolPages: Integer = VDB_DEF_POOL);
    constructor CreateWithPassword(const ADbPath, APassword: string;
      ACreate: Boolean = True; APoolPages: Integer = VDB_DEF_POOL);

    { v3.2: SALT-OKUNUR acilis. Dosya paylasimli kilit ile acilir: birden cok
      okuyucu ayni anda calisabilir, yazar (tam kilit) bekler. Hicbir yazma
      yapilmaz; WAL imajlari bellek katmanindan okunur, degisim gunlugu
      ACILMAZ (okuyucu <db>.log'a yazmaz).
      ABusyMs yalnizca kayit amaclidir (okuyucu kilidi beklemez). }
    constructor CreateReadOnly(const ADbPath: string;
      APoolPages: Integer = VDB_DEF_POOL; ABusyMs: Integer = VDB_DEF_BUSY_MS);
    destructor Destroy; override;

    property Engine: TVdbPageEngine read FEng;
    property IsReadOnly: Boolean read FReadOnly;
    property BusyMs: Integer read FBusyMs;
    { Sprint 3.4: sayfa sifreleme durumu ve anahtar parmak izi (8 hex). }
    property Encrypted: Boolean read GetEncrypted;
    function KeyFingerprint: string;
    { Checkpoint esigi (bayt). 0 = yalnizca kapanis/Flush'ta. }
    property CheckpointBytes: Int64 read FCheckpointBytes write FCheckpointBytes;

    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function Exists(Key: QWord): Boolean;
    function Count: Integer;

    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer = -1);
    { v3.1: tablo basina canli satir sayisi (O(1)). Tam taramayla AYNI
      yuklem: TableFilter<0 ise tum anahtarlar. Etiket cozucusu yoksa -1. }
    function CountTable(TableFilter: Integer): Int64;
    function ScanRawIterAll(TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer): Boolean;
    { v3.3: sayfa numarali ham tarama; `Skip[i] <> 0` sayfalar hic acilmaz. }
    function ScanRawIterAllPaged(TableFilter: Integer;
      Skip: PByte; SkipCount: Integer;
      Cb: TVDbRawPageCb; User: Pointer): Boolean;
    { v3.3: veri surum damgasi (zone map onbellegi icin). }
    function DataStamp: QWord;

    { v3.2: AS OF — WAL penceresindeki ilk Sequence commit'in sonundaki
      tutarli goruntuden (TableFilter'a uyan) satirlari okur. Anlik goruntu
      gecici bir kopya uzerinde kurulur (canli dosyaya dokunulmaz). }
    function ScanAllAt(TableFilter, Sequence: Integer;
      out Keys: TQWordArray; out Vals: TValArray;
      out ActualSequence: Integer): Boolean;
    function AsOfMaxSequence: Integer;

    procedure BeginBatch;
    procedure CommitBatch;
    procedure AbortBatch;
    procedure Flush;
    function GetInBatch: Boolean;
    { v3.4: acik yazma islemi 0 veya 1 tane mi? (DDL/SAVEPOINT kosulu) }
    function SoleWriter: Boolean;

    { v3.2: ALTER DATABASE KEY — dosya yeni parola ile yeniden sifrelenir.
      Acik parti varken reddedilir; islem atomiktir (tmp + .bak). }
    procedure Rekey(const NewPassword: string);

    { --- v3.2: yonetim / olcum (v2 TVDb API esdegeri) --- }
    function GetDeadBytes: Int64;
    function GetDataFileSize: Int64;
    function GetAutoCompactEnabled: Boolean;
    procedure SetAutoCompactEnabled(AValue: Boolean);
    function GetAutoCompactRatio: Double;
    procedure SetAutoCompactRatio(AValue: Double);
    function GetAutoCompactMinBytes: Int64;
    procedure SetAutoCompactMinBytes(AValue: Int64);
    function GetAutoCompactCount: Int64;
    function GetLastAutoCompactError: string;
    function AutoCompact(out OldBytes, NewBytes: Int64;
      MaxDeadRatio: Double; MinBytes: Int64): Boolean;
    { v4: gunluk / PITR }
    function LogSupported: Boolean;
    function LogStatus: string;
    function LogRangeInfo(out MinSeq, MaxSeq: Int64;
      out MinTsMs, MaxTsMs: Int64; out BaseCount: Integer): Boolean;
    function BuildLogSnapshot(TimestampMs, Version: Int64;
      const DestPath: string;
      out ActualTsMs, ActualSeq: Int64): Boolean;
    function ScanAllAtLogTime(TableFilter: Integer;
      TimestampMs, Version: Int64;
      out Keys: TQWordArray; out Vals: TValArray;
      out ActualTsMs, ActualSeq: Int64): Boolean;
    function ArchiveLogSet(const DestDir: string): Int64;
    { v3.7: gunluk budama }
    function GetLogPruneEnabled: Boolean;
    procedure SetLogPruneEnabled(AValue: Boolean);
    function GetLogPruneKeepDays: Integer;
    procedure SetLogPruneKeepDays(AValue: Integer);
    function GetLogPruneKeepBases: Integer;
    procedure SetLogPruneKeepBases(AValue: Integer);
    function LogPrune(out ADroppedSegments, ADroppedBaseFiles: Integer;
      out ABytesFreed: Int64; out AErr: string): Boolean;
    function GetLastLogPruneError: string;
    { v4: replikasyon }
    function ReplSupported: Boolean;
    procedure ReplSuspendLog(ASuspend: Boolean);
    function ReplAppendGroup(const ARaw: TBytes; out AErr: string): Boolean;


    { v3.2: SAVEPOINT. Parti kaplamasi UZERINDE calisir; motora hicbir sey
      yazilmadigi icin geri alma yalnizca kaplama gunlugu ile yapilir. }
    procedure Savepoint(const Name: string);
    function RollbackToSavepoint(const Name: string): Boolean;
    function ReleaseSavepoint(const Name: string): Boolean;

    function EnsureColumnKey: QWord;
    function ColumnKeyId: QWord;
    function ColumnKeyPath: string;
    function FileEncrypted: Boolean;
    procedure SetBeforeCommit(Proc: TDbCommitHook);
    function GetDirty: Boolean;
    procedure WaitForeignTxn(ASessionId: Cardinal);
    procedure RefreshBatchSnapshot;
    function GetFilePath: string;
    procedure SetRowTagFunc(AValue: TVDbRowTagFunc);

    { Sprint 3.1: sayfa motorunun tam butunluk denetimi (CRC + freelist
      + heap + tasma zincirleri). Acik parti varsa denetim yapilmaz. }
    function Verify(out Report: string): Boolean;
    { v3.9: kilit gozlemi (test/teshis). Normalde 0; her genel islemden
      sonra 0 olmali. MaxDepth, ic ice girislerin ulastigi en yuksek
      derinligi gosterir (orn. ScanAll -> ScanCb -> OwnSet = 2). }
    function DebugLockDepth: Integer;
    function DebugLockMaxDepth: Integer;

    { Sprint 3.2: checkpoint sonrasi bayt-bayt yedek; geri yukleme dosyayi
      atomik degistirir (eski dosya .bak kalir), WAL/idx temizlenir, motor
      yeniden acilir. Ust katman semayi yeniden yuklemelidir. }
    procedure BackupTo(const DestPath: string);
    procedure RestoreFrom(const SrcPath: string);

    { Sprint 3.3: VACUUM - canli kayitlar yeni ve sikisik dosyaya yazilir,
      atomik olarak yerine konur; bos sayfalar/olu baytlar dosyadan duser.
      Eski dosya .bak kalir. Ust katman semayi yeniden yuklemelidir. }
    procedure Compact(out OldBytes, NewBytes: Int64);
  end;

implementation

var
  { v3.2: AS OF gecici dosya adlari icin surec ici sayac (okuyucular PARALEL
    calisir; sabit ad cakismaya ve yarisa yol acardi). }
  GAsOfCounter: LongInt = 0;

function TVdbBackendV3.GetEncrypted: Boolean;
begin
  Result := (FEng <> nil) and FEng.Encrypted;
end;

function TVdbBackendV3.KeyFingerprint: string;
begin
  if FEng <> nil then Result := FEng.KeyFingerprint
  else Result := '';
end;

procedure TVdbBackendV3.InitBackend(const ADbPath: string; ACreate: Boolean;
  APoolPages: Integer; AReadOnly: Boolean; ABusyMs: Integer);
begin
  FPath := ADbPath;
  FReadOnly := AReadOnly;
  FBusyMs := ABusyMs;
  FSets := TDictionary<Cardinal, TWriteSet>.Create;
  FAlien := TDictionary<QWord, Int64>.Create;
  FCommitGen := 0;
  FEngCs := TVdbGate.Create;
  FTagCounts := TDictionary<Integer, Int64>.Create;
  { v3.2: otomatik sikistirma v2 ile AYNI varsayilanlar (KAPALI). }
  FAutoCompactOn := False;
  FAutoCompactRatio := 0.35;
  FAutoCompactMinBytes := 4 * 1024 * 1024;
  FAutoCompactCount := 0;
  FAutoCompactBusy := False;
  FLastAutoCompactError := '';
  FLogPruneOn := False;
  FLogPruneDays := 30;
  FLogPruneBases := 2;
  FLogPruneErr := '';
  FDirty := False;
  FCheckpointBytes := VDB_V3_CHECKPOINT_BYTES;
  FPoolPages := APoolPages;
  FEng := NewEngine(ADbPath);
  try
    FEng.Open(ACreate, AReadOnly, ABusyMs);
  except
    FreeAndNil(FEng);
    raise;
  end;
  { Parola modunda turetilmis ham anahtar; VACUUM/RESTORE yeniden acarken
    ayni anahtar kullanilir. }
  FKey := Copy(FEng.Store.Key, 0, Length(FEng.Store.Key));
  FPassword := '';
  FHasPassword := False;
  { v3.1: satir sayaci. FRowTag bu noktada henuz atanmamis olabilir;
    TVTableDb.CreateBackend hemen ardindan atar ve SetRowTagFunc sayaci
    .idx ozetinden (tarama YAPMADAN) yukler. Ozet yoksa ilk COUNT isteginde
    bir kez tam taramayla kurulur. }
  FTagCountsValid := False;
  FEng.OnTagSummary := GetTagSummary;
  { v4: degisim gunlugu. FRowTag bu noktada atanmamis olabilir; etiket
    cozucusu yoksa TableId -1 yazilir (replay KV duzeyinde oldugu icin
    dogruluk ETKILENMEZ). }
  FLog := nil;
  FLogInGroup := False;
  FLogSuspended := False;
  FLogProblem := '';
  FLogBaseSeq := 0;
  { v3.2: salt-okunur okuyucu degisim gunlugune YAZMAZ ve taban imaji
    uretmez; <db>.log dizini okuyucu tarafindan olusturulmaz. }
  if FReadOnly then
  begin
    FLogProblem := 'salt-okunur oturum: degisim gunlugu kapali';
    Exit;
  end;
  OpenChangeLog;
end;

function TVdbBackendV3.NewEngine(const APath: string): TVdbPageEngine;
begin
  if FHasPassword then
    Result := TVdbPageEngine.CreateWithPassword(APath, FPassword, FPoolPages)
  else if Length(FKey) > 0 then
    Result := TVdbPageEngine.CreateWithKey(APath, FKey, FPoolPages)
  else
    Result := TVdbPageEngine.Create(APath, FPoolPages);
end;

{ --------------------------------------------------- v4: degisim gunlugu }

function TVdbBackendV3.LogTag(const V: TBytes): Integer;
begin
  if not Assigned(FRowTag) then Exit(-1);
  if Length(V) = 0 then Exit(-1);
  Result := FRowTag(@V[0], Length(V));
end;

procedure TVdbBackendV3.EnsureLogBase(AFlags: LongWord;
  const AReason: string);
var
  name, dest, baseDir: string;
  seq: Int64;
begin
  if (FLog = nil) or (not FLog.Enabled) then Exit;
  { Taban imaj DURABIL olmali: once checkpoint (WAL veri dosyasina iner),
    sonra depo handle'i uzerinden kopya. }
  FEng.Checkpoint(True);
  baseDir := IncludeTrailingPathDelimiter(FLog.Dir) + 'base';
  ForceDirectories(baseDir);
  seq := FLog.LastSeq + 1;
  name := 'b-' + IntToStr(seq) + '-' + IntToStr(FEng.Store.LSN) + '.odb';
  dest := IncludeTrailingPathDelimiter(baseDir) + name;
  if FileExists(dest) then
    if not DeleteFile(dest) then
    begin
      FLogProblem := 'gunluk taban dosyasi silinemedi: ' + dest;
      Exit;
    end;
  FEng.Store.CopyCommittedTo(dest);
  FLogBaseSeq := FLog.WriteBase(FEng.Store.LSN, VDbFileBytes(dest),
    VdbLogNowMs, AFlags, name);
  if FLogBaseSeq <= 0 then
    FLogProblem := 'taban isareti yazilamadi (' + AReason + ')';
end;

procedure TVdbBackendV3.OpenChangeLog;
var
  rd: TVdbLogReader;
  bases: TVdbLogBaseArray;
  lastSeq: Int64;
  lastLsn: LongWord;
  hasGroup: Boolean;
begin
  FLog := TVdbChangeLog.Create;
  try
    FLog.Open(FPath, True);
  except
    on E: Exception do
    begin
      { Gunluk ACIKCA kapali: yazma yolu degismez, ama PITR/replikasyon
        istekleri net hata verir (sessiz yalan yok). }
      FLogProblem := 'degisim gunlugu acilamadi: ' + E.Message;
      Exit;
    end;
  end;
  if not FLog.Enabled then
  begin
    FLogProblem := FLog.LastError;
    if FLogProblem = '' then FLogProblem := 'degisim gunlugu kapali';
    Exit;
  end;
  FLogProblem := '';
  rd := TVdbLogReader.Create(FPath);
  try
    bases := rd.ListBases;
    if Length(bases) = 0 then
    begin
      { Bu dosya icin gunlugun baslangici: taban imajini SIMDI al. }
      EnsureLogBase(0, 'ilk taban');
      Exit;
    end;
    { Gunluk ile motor ayni noktada mi? Son grubun END kaydindaki motor
      LSN'i ile canli LSN karsilastirilir. Farkli ise: ya commit ile gunluk
      yazimi arasinda cokme oldu (BOSLUK) ya da dosya degistirildi
      (VACUUM/RESTORE) ve isaret yazilamadi. Iki durumda da yeni bir NESIL
      KOPMASI tabani yazilir: bu andan ONCESI icin PITR REDDEDILIR, sonrasi
      icin tam calisir. }
    hasGroup := rd.LastState(lastSeq, lastLsn);
    if hasGroup and (lastLsn <> FEng.Store.LSN) then
      EnsureLogBase(1, 'gunluk/motor LSN uyusmazligi: gunluk ' +
        IntToStr(lastLsn) + ' motor ' + IntToStr(FEng.Store.LSN));
  finally
    rd.Free;
  end;
end;

procedure TVdbBackendV3.LogPut(AKey: QWord; const AOld, ANew: TBytes);
begin
  if FLogSuspended then Exit;
  if (FLog = nil) or (not FLog.Enabled) then Exit;
  if not FLogInGroup then
  begin
    FLog.BeginGroup;
    FLogInGroup := True;
  end;
  FLog.AddPut(LogTag(ANew), AKey, AOld, ANew);
end;

procedure TVdbBackendV3.LogDel(AKey: QWord; const AOld: TBytes);
begin
  if FLogSuspended then Exit;
  if (FLog = nil) or (not FLog.Enabled) then Exit;
  if not FLogInGroup then
  begin
    FLog.BeginGroup;
    FLogInGroup := True;
  end;
  FLog.AddDel(LogTag(AOld), AKey, AOld);
end;

procedure TVdbBackendV3.LogFinish;
var
  seq, ts: Int64;
begin
  if FLogSuspended then Exit;
  if (FLog = nil) or (not FLog.Enabled) or (not FLogInGroup) then Exit;
  if not FLog.EndGroup(FEng.Store.LSN, seq, ts) then
  begin
    { Gunluk yazilamadi: VERI kaybi YOK (commit zaten durabil), yalniz
      PITR/replikasyon bu noktadan sonra guvenilmez. Acikca isaretle. }
    FLogProblem := FLog.LastError;
    if FLogProblem = '' then FLogProblem := 'gunluk yazilamadi';
  end;
  FLogInGroup := False;
end;

procedure TVdbBackendV3.LogAbort;
begin
  if FLogInGroup and (FLog <> nil) then
    FLog.AbortGroup;
  FLogInGroup := False;
end;


{ ==================================================== v3.9: motor kilidi }

{ Bu is parcaciginin O AN tuttugu kilitler (ic ice girisler icin yigin).
  Yalnizca SAHIP is parcacigi okur/yazar: paylasilan alanlar kritik bolum
  DISINDA hic okunmaz. Boylece "kritik bolum yeniden girisli" varsayimi da,
  zayif bellek sirali platformlarda eski sahip degerini gorup yanlislikla
  yeniden giris sayma riski de ortadan kalkar. }
threadvar
  VdbGateHeld: array[0..7] of TVdbGate;
  VdbGateHeldN: Integer;

constructor TVdbGate.Create;
begin
  inherited Create;
  FCs := TCriticalSection.Create;
  FDepth := 0;
  FMaxDepth := 0;
end;

destructor TVdbGate.Destroy;
begin
  FCs.Free;
  inherited Destroy;
end;

function TVdbGate.Depth: Integer;
begin
  Result := FDepth;
end;

function TVdbGate.MaxDepth: Integer;
begin
  Result := FMaxDepth;
end;

procedure TVdbGate.Enter;
var
  i: Integer;
begin
  { Yeniden giris: AYNI is parcacigi bu kilidi zaten tutuyor. Yalnizca
    KENDI threadvar yiginimiza bakariz; kritik bolume girilmez. }
  for i := 0 to VdbGateHeldN - 1 do
    if VdbGateHeld[i] = Self then
    begin
      Inc(FDepth);
      if FDepth > FMaxDepth then FMaxDepth := FDepth;
      Exit;
    end;
  FCs.Enter;
  FDepth := 1;
  if FDepth > FMaxDepth then FMaxDepth := FDepth;
  if VdbGateHeldN > High(VdbGateHeld) then
  begin
    { Beklenmeyen derinlik: kilitlenmektense acik hata. }
    FDepth := 0;
    FCs.Leave;
    raise EVdbBackendV3.Create(
      'kilit hatasi: ic ice kilit yigini doldu (>' +
      IntToStr(High(VdbGateHeld) + 1) + ')');
  end;
  VdbGateHeld[VdbGateHeldN] := Self;
  Inc(VdbGateHeldN);
end;

procedure TVdbGate.Leave;
begin
  if FDepth <= 0 then
    raise EVdbBackendV3.Create('kilit hatasi: sahip olunmayan kilitten cikis');
  Dec(FDepth);
  if FDepth = 0 then
  begin
    if (VdbGateHeldN > 0) and (VdbGateHeld[VdbGateHeldN - 1] = Self) then
    begin
      Dec(VdbGateHeldN);
      VdbGateHeld[VdbGateHeldN] := nil;
    end;
    FCs.Leave;
  end;
end;

function TVdbBackendV3.DebugLockDepth: Integer;
begin
  Result := FEngCs.Depth;
end;

function TVdbBackendV3.DebugLockMaxDepth: Integer;
begin
  Result := FEngCs.MaxDepth;
end;

constructor TVdbBackendV3.Create(const ADbPath: string; ACreate: Boolean;
  APoolPages: Integer; ABusyMs: Integer);
begin
  inherited Create;
  FKey := nil;
  FPassword := '';
  FHasPassword := False;
  InitBackend(ADbPath, ACreate, APoolPages, False, ABusyMs);
end;

constructor TVdbBackendV3.CreateWithKey(const ADbPath: string;
  const AKey: TBytes; ACreate: Boolean; APoolPages: Integer);
begin
  inherited Create;
  FKey := Copy(AKey, 0, Length(AKey));
  FPassword := '';
  FHasPassword := False;
  InitBackend(ADbPath, ACreate, APoolPages);
end;

constructor TVdbBackendV3.CreateWithPassword(const ADbPath, APassword: string;
  ACreate: Boolean; APoolPages: Integer);
begin
  inherited Create;
  FKey := nil;
  FPassword := APassword;
  FHasPassword := True;
  InitBackend(ADbPath, ACreate, APoolPages);
end;

constructor TVdbBackendV3.CreateReadOnly(const ADbPath: string;
  APoolPages: Integer; ABusyMs: Integer);
begin
  inherited Create;
  FKey := nil;
  FPassword := '';
  FHasPassword := False;
  InitBackend(ADbPath, False, APoolPages, True, ABusyMs);
end;

function TVdbBackendV3.GetIsReadOnly: Boolean;
begin
  Result := FReadOnly;
end;

function TVdbBackendV3.GetBusyTimeoutMs: Integer;
begin
  Result := FBusyMs;
end;

procedure TVdbBackendV3.RequireWritable;
begin
  if FReadOnly then
    raise EVdbBackendV3.Create(
      'salt-okunur veritabani: yazma yapilamaz (READONLY acilis)');
end;

destructor TVdbBackendV3.Destroy;
var
  pair: TPair<Cardinal, TWriteSet>;
begin
  { v3.4: kapanista yarim islemler YAZILMAZ; acik yazma kumeleri atilir. }
  if FSets <> nil then
    for pair in FSets do
      pair.Value.Free;
  FreeAndNil(FSets);
  FreeAndNil(FAlien);
  FEngCs.Free;
  LogAbort;               // yarim grup yazilmaz
  FreeAndNil(FLog);       // gunluk fsync + kapat
  FreeAndNil(FEng);       // Close: commit + checkpoint + idx
  FreeAndNil(FTagCounts);
  inherited Destroy;
end;

{ ------------------------------------------------ v3.4: oturum yazma kumesi }

constructor TVdbBackendV3.TWriteSet.Create(ASession: Cardinal);
begin
  inherited Create;
  Session := ASession;
  Map := TDictionary<QWord, TBatchRec>.Create;
  Order := TList<QWord>.Create;
  Before := TDictionary<QWord, TBatchRec>.Create;
  TagDelta := TDictionary<Integer, Int64>.Create;
  Savepoints := TList<TSavepointRec>.Create;
  StartGen := 0;
end;

destructor TVdbBackendV3.TWriteSet.Destroy;
var
  i: Integer;
begin
  for i := 0 to Savepoints.Count - 1 do
  begin
    Savepoints[i].Journal.Free;
    Savepoints[i].TagDelta.Free;
  end;
  Savepoints.Free;
  TagDelta.Free;
  Before.Free;
  Order.Free;
  Map.Free;
  inherited Destroy;
end;

function TVdbBackendV3.OwnSet: TWriteSet;
var
  sid: Cardinal;
begin
  Result := nil;
  if FSets = nil then Exit;
  sid := VdbBackendSessionId;
  FEngCs.Enter;
  try
    FSets.TryGetValue(sid, Result);
  finally
    FEngCs.Leave;
  end;
end;

function TVdbBackendV3.GetBatchMap: TDictionary<QWord, TBatchRec>;
var
  s: TWriteSet;
begin
  s := OwnSet;
  if s = nil then Result := nil else Result := s.Map;
end;

function TVdbBackendV3.GetBatchOrder: TList<QWord>;
var
  s: TWriteSet;
begin
  s := OwnSet;
  if s = nil then Result := nil else Result := s.Order;
end;

function TVdbBackendV3.GetBatchTagDelta: TDictionary<Integer, Int64>;
var
  s: TWriteSet;
begin
  s := OwnSet;
  if s = nil then Result := nil else Result := s.TagDelta;
end;

function TVdbBackendV3.GetSavepoints: TList<TSavepointRec>;
var
  s: TWriteSet;
begin
  s := OwnSet;
  if s = nil then Result := nil else Result := s.Savepoints;
end;

function TVdbBackendV3.GetBatchOpen: Boolean;
begin
  Result := OwnSet <> nil;
end;

{ --------------------------------------------------------------- yardimci }

function TVdbBackendV3.PassFilter(Key: QWord; const Value: TBytes;
  TableFilter: Integer): Boolean;
var
  tag: Integer;
begin
  if TableFilter < 0 then Exit(True);
  if not Assigned(FRowTag) then Exit(True);
  tag := FRowTag(Value, Length(Value));
  Result := (tag < 0) or (tag = TableFilter);
end;

function TVdbBackendV3.EffectiveCount: Integer;
var
  pair: TPair<QWord, TBatchRec>;
  n: Integer;
begin
  FEngCs.Enter;
  try
    n := FEng.Count;
    if BatchIsMine then
      for pair in BatchMap do
      begin
        { Kaplamadaki her kayit: eskiden var miydi? }
        if pair.Value.Present then
        begin
          if not FEng.Contains(pair.Key) then Inc(n);
        end
        else if FEng.Contains(pair.Key) then
          Dec(n);
      end;
    Result := n;
  finally
    FEngCs.Leave;
  end;
end;

procedure TVdbBackendV3.MaybeCheckpoint;
begin
  if FCheckpointBytes <= 0 then Exit;
  if FEng.Wal.Bytes >= FCheckpointBytes then
  begin
    FEng.Checkpoint(True);
    { v3.7: "checkpoint sonrasi otomatik budama". Hata commit'i BOZMAZ;
      LastLogPruneError'da gorunur. }
    MaybeLogPrune;
  end;
end;

procedure TVdbBackendV3.MaybeLogPrune;
var
  rd: TVdbLogReader;
  oldest, cut: Int64;
  pr: TVdbLogPruneResult;
  err: string;
  hadOld: Boolean;
begin
  if not FLogPruneOn then Exit;
  if FReadOnly then Exit;
  if (FLog = nil) or (not FLog.Enabled) then Exit;
  if FLogPruneDays <= 0 then Exit;         { zaman kurali yoksa onek sinirsiz }
  cut := VdbLogNowMs - Int64(FLogPruneDays) * Int64(86400000);
  hadOld := False;
  oldest := 0;
  rd := TVdbLogReader.Create(FPath);
  try
    hadOld := rd.OldestGroupTsMs(oldest);
  finally
    rd.Free;
  end;
  if (not hadOld) or (oldest >= cut) then Exit;
  { Suresi dolmus bir ONEK var: once onu KAPSAYAN yeni taban imaji alinir,
    sonra onek silinir. Taban olmadan silmek PITR'i kirardi. }
  EnsureLogBase(0, 'budama tabani');
  if VdbLogPruneAt(FPath, cut, FLogPruneBases, pr, err) then
    FLogPruneErr := ''
  else
    FLogPruneErr := err;
end;

procedure TVdbBackendV3.ApplyBatch;
var
  i: Integer;
  key: QWord;
  rec: TBatchRec;
  ok: Boolean;
  oldTag, newTag: Integer;
  oldVal: TBytes;
begin
  if BatchMap.Count = 0 then Exit;
  { Giris sirasi: sayfalara ARDISIK yazilir (rastgele dolasim = sayfa
    sicramasi = yavas toplu yazim). }
  for i := 0 to BatchOrder.Count - 1 do
  begin
    key := BatchOrder[i];
    if not BatchMap.TryGetValue(key, rec) then Continue;
    if rec.Present then
    begin
      { ONCEDEN her anahtar icin ayrica `Contains` cagriliyordu; `Insert`
        zaten "anahtar var mi" diye bakiyor. Once eklemeyi dene, yalniz
        cakismada guncelle: toplu eklemede bir hash aramasi eksilir. }
      ok := FEng.Insert(key, rec.Value);
      if ok then
      begin
        { v3.1: yeni satir -> etiket sayaci +1 }
        if Length(rec.Value) > 0 then
          TagAdd(TagOf(@rec.Value[0], Length(rec.Value)), 1);
        LogPut(key, nil, rec.Value);
      end
      else
      begin
        { Var olan anahtar: etiket degismis olabilir; eski deger YALNIZCA
          bu yolda okunur (toplu eklemede hic okunmaz). }
        oldVal := nil;
        FEng.TryGet(key, oldVal);
        oldTag := -2;
        if Length(rec.Value) > 0 then
          if Length(oldVal) > 0 then
            oldTag := TagOf(@oldVal[0], Length(oldVal));
        ok := FEng.Update(key, rec.Value);
        if not ok then
          raise EVdbBackendV3.Create(Format(
            'toplu yazim basarisiz: anahtar $%.16x', [key]));
        if Length(rec.Value) > 0 then
        begin
          newTag := TagOf(@rec.Value[0], Length(rec.Value));
          if oldTag = -2 then TagAdd(newTag, 1)
          else if oldTag <> newTag then
          begin
            TagAdd(oldTag, -1);
            TagAdd(newTag, 1);
          end;
        end;
        LogPut(key, oldVal, rec.Value);
      end;
    end
    else
    begin
      { Silmeden ONCE eski deger: etiket sayaci ve degisim gunlugu icin. }
      if FEng.TryGet(key, oldVal) then
      begin
        FEng.Delete(key);
        if Length(oldVal) > 0 then
          TagAdd(TagOf(@oldVal[0], Length(oldVal)), -1);
        LogDel(key, oldVal);
      end
      else
        FEng.Delete(key);    // yoksa da zararsiz (gunluge YAZILMAZ)
    end;
  end;
  BatchMap.Clear;
  BatchOrder.Clear;
  FDirty := True;
end;

{ ------------------------------------------------------------------ kayit }

{ --- v3.2: oturum yalitimi ---------------------------------------- }

function TVdbBackendV3.BatchIsMine: Boolean;
begin
  { v3.4: artik "benim acik yazma kumem var mi" demektir. Baska oturumun
    acik islemi beni ilgilendirmez: onun yazma kumesi motora YANSIMADI. }
  Result := OwnSet <> nil;
end;

procedure TVdbBackendV3.RequireBatchWrite;
begin
  { v3.4: baska oturumun acik islemi HATA DEGIL (her oturum kendi kumesinde
    calisir). Burada yalnizca salt-okunur denetimi kalir. }
  RequireWritable;
end;

procedure TVdbBackendV3.NoteBefore(S: TWriteSet; Key: QWord);
var
  rec: TBatchRec;
  v: TBytes;
begin
  if S = nil then Exit;
  { v3.6 HIZLI YOL: biz acikken BASKA bir oturum commit etmediyse, motor
    degeri BeginBatch anindaki degerle AYNIDIR; before-image gereksiz.
    Bu bir kilit/sozluk islemi bile yapmaz (bayrak yalnizca yabanci commit
    tarafindan, FEngCs altinda True yapilir). 200k satirlik partide 200k
    gereksiz motor okumasi + 200k sozluk kaydi kalkar. }
  if not S.NeedBefore then Exit;
  FEngCs.Enter;
  try
    if S.Before.ContainsKey(Key) then Exit;
    rec.Present := FEng.TryGet(Key, v);
    rec.Value := v;
    S.Before.AddOrSetValue(Key, rec);
  finally
    FEngCs.Leave;
  end;
end;

procedure TVdbBackendV3.VerifyNoConflict(S: TWriteSet);
var
  i: Integer;
  key: QWord;
  b, cur: TBatchRec;
  curVal: TBytes;
  gen: Int64;
  same: Boolean;
begin
  if S = nil then Exit;
  { v3.6: ne before-image ne yabanci commit varsa yapacak is yok. }
  if (S.Before.Count = 0) and (FAlien.Count = 0) then Exit;
  for i := 0 to S.Order.Count - 1 do
  begin
    key := S.Order[i];
    if not S.Before.TryGetValue(key, b) then
    begin
      { v3.6: HIZLI YOLDA yazilan anahtar (before-image yok). Biz
        basladiktan sonra baska bir oturum bu anahtari commit ettiyse
        cakisma vardir; etmediyse yoktur. Bu, "ilk commit kazanir"
        kuralinin birebir aynisidir: o commit bizim yazimizdan sonra
        geldigi icin before-image karsilastirmasi da farkli cikardi. }
      if FAlien.TryGetValue(key, gen) and (gen > S.StartGen) then
        raise EVdbBackendV3.CreateFmt(
          'yazma cakismasi: $%.16x baska bir oturum tarafindan degistirildi ' +
          '(islem geri alindi)', [key]);
      Continue;
    end;
    curVal := nil;
    FEngCs.Enter;
    try
      cur.Present := FEng.TryGet(key, curVal);
    finally
      FEngCs.Leave;
    end;
    cur.Value := curVal;
    if cur.Present <> b.Present then
      raise EVdbBackendV3.CreateFmt(
        'yazma cakismasi: $%.16x baska bir oturum tarafindan degistirildi ' +
        '(islem geri alindi)', [key]);
    if not b.Present then Continue;
    if Length(cur.Value) <> Length(b.Value) then
      raise EVdbBackendV3.CreateFmt(
        'yazma cakismasi: $%.16x baska bir oturum tarafindan degistirildi ' +
        '(islem geri alindi)', [key]);
    same := True;
    if Length(b.Value) > 0 then
      same := CompareMem(@cur.Value[0], @b.Value[0], Length(b.Value));
    if not same then
      raise EVdbBackendV3.CreateFmt(
        'yazma cakismasi: $%.16x baska bir oturum tarafindan degistirildi ' +
        '(islem geri alindi)', [key]);
  end;
end;

procedure TVdbBackendV3.Put(Key: QWord; const Value: TBytes);
var
  rec: TBatchRec;
  oldTag, newTag: Integer;
  oldVal: TBytes;
  s: TWriteSet;
begin
  RequireWritable;
  RequireBatchWrite;
  { v3.6: OwnSet tek kez alinir (ONCEDEN BatchOpen + NoteBefore(OwnSet,..)
    satir basina IKI kilit + IKI sozluk aramasi yapiyordu). }
  s := OwnSet;
  if s <> nil then
  begin
    { v3.4: cakisma denetimi icin ILK yazimdan onceki motor degeri (v3.6:
      yalnizca gerektiginde, bkz. NoteBefore). }
    NoteBefore(s, Key);
    JournalKey(Key);
    rec.Present := True;
    rec.Value := Copy(Value, 0, Length(Value));
    if not s.Map.ContainsKey(Key) then
      s.Order.Add(Key);
    s.Map.AddOrSetValue(Key, rec);
    Exit;
  end;
  FEngCs.Enter;
  try
    { Tek anahtar yolu: once eklemeyi dene (Insert zaten varlik denetimi
      yapar), yalniz cakismada guncelle. Boylece anahtar basina bir hash
      aramasi eksilir. }
    if FEng.Insert(Key, Value) then
    begin
      if Length(Value) > 0 then
        TagAdd(TagOf(@Value[0], Length(Value)), 1);
      FDirty := True;
      LogPut(Key, nil, Value);
      Exit;
    end;
    { Anahtar zaten var: etiket DEGISEBILIR (DROP TABLE + ayni PK ile yeniden
      CREATE -> ayni anahtar, farkli TableId). Eski deger hem etiket hem de
      degisim gunlugu icin okunur. }
    oldVal := nil;
    FEng.TryGet(Key, oldVal);
    oldTag := -2;
    if (Length(Value) > 0) and (Length(oldVal) > 0) then
      oldTag := TagOf(@oldVal[0], Length(oldVal));
    if not FEng.Update(Key, Value) then
      raise EVdbBackendV3.Create('ekleme/guncelleme basarisiz');
    if Length(Value) > 0 then
    begin
      newTag := TagOf(@Value[0], Length(Value));
      if oldTag = -2 then TagAdd(newTag, 1)
      else if oldTag <> newTag then
      begin
        TagAdd(oldTag, -1);
        TagAdd(newTag, 1);
      end;
    end;
    FDirty := True;
    LogPut(Key, oldVal, Value);
  finally
    FEngCs.Leave;
  end;
end;

function TVdbBackendV3.Get(Key: QWord; out Value: TBytes): Boolean;
var
  rec: TBatchRec;
  s: TWriteSet;
begin
  s := OwnSet;
  if (s <> nil) and s.Map.TryGetValue(Key, rec) then
  begin
    if rec.Present then
    begin
      Value := Copy(rec.Value, 0, Length(rec.Value));
      Exit(True);
    end;
    Value := nil;
    Exit(False);
  end;
  FEngCs.Enter;
  try
    Result := FEng.TryGet(Key, Value);
  finally
    FEngCs.Leave;
  end;
end;

function TVdbBackendV3.Delete(Key: QWord): Boolean;
var
  rec: TBatchRec;
  had: Boolean;
  oldVal: TBytes;
  s: TWriteSet;
begin
  RequireBatchWrite;
  s := OwnSet;
  if s <> nil then
  begin
    { ONCEDEN: `BatchMap.AddOrSetValue(...)`'dan SONRA `BatchMap.ContainsKey`
      soruluyordu; bu her zaman True oldugu icin parti icinde Delete
      HIC OLMAYAN anahtar icin de True donuyordu. Dogru yanit: silmeden
      ONCE var miydi? }
    NoteBefore(s, Key);
    JournalKey(Key);
    had := FEng.Contains(Key);
    if s.Map.ContainsKey(Key) then
      had := s.Map[Key].Present;
    rec.Present := False;
    rec.Value := nil;
    if not s.Map.ContainsKey(Key) then
      s.Order.Add(Key);
    s.Map.AddOrSetValue(Key, rec);
    Exit(had);
  end;
  FEngCs.Enter;
  try
    { v3.1: etiket sayaci icin once eski deger (yalnizca silinen anahtar). }
    if FEng.TryGet(Key, oldVal) then
    begin
      Result := FEng.Delete(Key);
      if Length(oldVal) > 0 then
        TagAdd(TagOf(@oldVal[0], Length(oldVal)), -1);
      if Result then
        LogDel(Key, oldVal);
    end
    else
      Result := FEng.Delete(Key);
    if Result then
      FDirty := True;
  finally
    FEngCs.Leave;
  end;
end;

function TVdbBackendV3.Exists(Key: QWord): Boolean;
var
  s: TWriteSet;
  rec: TBatchRec;
begin
  { v3.6: ONCEDEN satir basina BatchIsMine + BatchMap.ContainsKey + BatchMap[]
    uc ayri OwnSet (kilit + oturum sozlugu aramasi) yapiyordu; INSERT yolu her
    satirda Exists cagirir. Tek OwnSet + tek sozluk aramasi yeterli. }
  s := OwnSet;
  if (s <> nil) and s.Map.TryGetValue(Key, rec) then
    Exit(rec.Present);
  FEngCs.Enter;
  try
    Result := FEng.Contains(Key);
  finally
    FEngCs.Leave;
  end;
end;

function TVdbBackendV3.Count: Integer;
begin
  Result := EffectiveCount;
end;

{ ----------------------------------------------------------------- tarama }

procedure TVdbBackendV3.ScanCb(Key: QWord; const Value: TBytes);
begin
  { v3.9: yazma kumesi tarama basinda BIR kez cozuldu (FScanSet). ONCEDEN
    her satirda BatchIsMine + BatchMap cagriliyordu; ikisi de OwnSet
    uzerinden kilit + oturum sozlugu aramasi yapiyordu (satir basina 3). }
  if (FScanSet <> nil) and FScanSet.Map.ContainsKey(Key) then Exit;
  if not PassFilter(Key, Value, FScanFilter) then Exit;
  { v3.1: her satirda SetLength(+1) YAPILMAZ (200k satirda O(n^2) kopya
    ve yeniden tahsis). Kapasite ikiye katlanir. }
  if FScanN >= FScanCap then
  begin
    if FScanCap < 256 then FScanCap := 256 else FScanCap := FScanCap * 2;
    SetLength(FScanKeys, FScanCap);
    SetLength(FScanVals, FScanCap);
  end;
  FScanKeys[FScanN] := Key;
  FScanVals[FScanN] := Value;
  Inc(FScanN);
end;

procedure TVdbBackendV3.ScanAll(out Keys: TQWordArray; out Vals: TValArray;
  TableFilter: Integer);
var
  pair: TPair<QWord, TBatchRec>;
begin
  { v3.4: tarama tamponlari (FScanKeys/FScanN) BACKEND alanidir; ayni
    backend'i paylasan oturumlar ayni anda tararsa birbirini bozardi.
    Kilit tarama boyunca tutulur. v3.9: geri cagirim ayni is parcaciginda
    oldugu icin TVdbGate bunu ACIKCA yeniden giris sayar (derinlik 2);
    kritik bolumun kendisi yeniden girisli olmak zorunda degildir. }
  FEngCs.Enter;
  try
    FScanKeys := nil;
    FScanVals := nil;
    FScanN := 0;
    FScanCap := 0;
    FScanFilter := TableFilter;
    { v3.9: oturumun yazma kumesi tarama boyunca sabit (kilit zaten bizde). }
    FScanSet := OwnSet;

    { Motor tarafi: kaplamada islem gormus anahtarlar atlanir. }
    FEng.ScanAll(ScanCb);

    { Kaplama tarafi: en guncel deger. }
    if FScanSet <> nil then
      for pair in FScanSet.Map do
      begin
        if not pair.Value.Present then Continue;
        if not PassFilter(pair.Key, pair.Value.Value, TableFilter) then Continue;
        if FScanN >= FScanCap then
        begin
          if FScanCap < 256 then FScanCap := 256 else FScanCap := FScanCap * 2;
          SetLength(FScanKeys, FScanCap);
          SetLength(FScanVals, FScanCap);
        end;
        FScanKeys[FScanN] := pair.Key;
        FScanVals[FScanN] := Copy(pair.Value.Value, 0, Length(pair.Value.Value));
        Inc(FScanN);
      end;

    SetLength(FScanKeys, FScanN);
    SetLength(FScanVals, FScanN);
    Keys := FScanKeys;
    Vals := FScanVals;
    FScanKeys := nil;
    FScanVals := nil;
    FScanN := 0;
    FScanCap := 0;
    FScanSet := nil;
  finally
    FEngCs.Leave;
  end;
end;

procedure TVdbBackendV3.AsOfCb(Key: QWord; const Value: TBytes);
begin
  if not PassFilter(Key, Value, FScanFilter) then Exit;
  if FScanN >= FScanCap then
  begin
    if FScanCap < 256 then FScanCap := 256 else FScanCap := FScanCap * 2;
    SetLength(FScanKeys, FScanCap);
    SetLength(FScanVals, FScanCap);
  end;
  FScanKeys[FScanN] := Key;
  FScanVals[FScanN] := Value;
  Inc(FScanN);
end;

{ Dosyayi bayt bayt kopyalar (hedef varsa silinir). }
procedure AsOfCopyFile(const Src, Dest: string);
var
  a, b: TFileStream;
begin
  if FileExists(Dest) then
    if not DeleteFile(Dest) then
      raise EVdbBackendV3.Create('AS OF: gecici dosya silinemedi: ' + Dest);
  a := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
  try
    b := TFileStream.Create(Dest, fmCreate);
    try
      b.CopyFrom(a, 0);
      VDbFlushStream(b);
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

function TVdbBackendV3.AsOfMaxSequence: Integer;
begin
  { WAL penceresindeki onaylanmis commit sayisi (son checkpoint'ten beri). }
  Result := FEng.Wal.CommitCount;
end;

function TVdbBackendV3.ScanAllAt(TableFilter, Sequence: Integer;
  out Keys: TQWordArray; out Vals: TValArray;
  out ActualSequence: Integer): Boolean;
var
  tmp, tmpWal, tmpIdx: string;
  total, n: Integer;
  eng: TVdbPageEngine;
begin
  Keys := nil;
  Vals := nil;
  ActualSequence := 0;
  Result := False;
  if FEng = nil then Exit;

  { Taban = son checkpoint'teki dosya; WAL = tabandan beri commit edilmis
    sayfa imajlari. Ikisinin kopyasi uzerinde sinirli kurtarma, N anindaki
    TUTARLI goruntuyu verir. Canli dosyalar yalniz OKUNUR. }
  total := FEng.Wal.CommitCount;
  if total <= 0 then
  begin
    { Gecmis yok: cagiran (VDbExecutor) v2 ile ayni mesaji verir. }
    ActualSequence := -1;
    Exit(True);
  end;
  n := Sequence;
  if n < 0 then n := 0;
  if n > total then n := total;
  ActualSequence := n;

  tmp := FPath + '.asof' + IntToStr(GetProcessID) + '_' +
    IntToStr(InterlockedIncrement(GAsOfCounter));
  tmpWal := tmp + '.wal';
  tmpIdx := tmp + '.idx';
  if FileExists(tmpIdx) then DeleteFile(tmpIdx);
  eng := nil;
  try
    { Taban kopyasi deponun KENDI handle'i uzerinden yapilir: dosya tam
      aralik kilidiyle kilitlidir (VDbLockStream), baska bir handle'dan
      okuma Windows'ta sessizce 0 bayt dondurur. }
    FEng.Store.CopyBaseImageTo(tmp);
    if n > 0 then
      AsOfCopyFile(FPath + '.wal', tmpWal)
    else if FileExists(tmpWal) then
      DeleteFile(tmpWal);

    eng := NewEngine(tmp);
    eng.RecoverLimit := n;
    try
      eng.Open(False);
    except
      { Yarim acilmis gecici motor: dosya kilitlerini birak, dosyalar silinsin. }
      try
        eng.SimulateCrash;
      except
      end;
      eng.Free;
      eng := nil;
      raise;
    end;
    try
      { v3.9: FScan* alanlari BACKEND genelindedir ve ScanAll de ayni
        alanlari kullanir. ONCEDEN bu bolge kilitsizdi: ayni backend'de
        es zamanli ScanAllAt + ScanAll (ya da iki ScanAllAt) birbirinin
        tamponunu bozabiliyordu. Kilit yalniz tamponun kullanildigi
        bolgede tutulur; gecici motorun kurulumu/kapanisi disaridadir. }
      FEngCs.Enter;
      try
        FScanKeys := nil;
        FScanVals := nil;
        FScanN := 0;
        FScanCap := 0;
        FScanFilter := TableFilter;
        eng.ScanAll(AsOfCb);
        SetLength(FScanKeys, FScanN);
        SetLength(FScanVals, FScanN);
        Keys := FScanKeys;
        Vals := FScanVals;
        FScanKeys := nil;
        FScanVals := nil;
        FScanN := 0;
        FScanCap := 0;
        Result := True;
      finally
        FEngCs.Leave;
      end;
    finally
      try
        eng.Close;
      except
        { gecici dosya: kapanis hatasi sonucu bozmaz }
      end;
      eng.Free;
      eng := nil;
    end;
  finally
    if eng <> nil then
    begin
      try
        eng.SimulateCrash;
      except
      end;
      eng.Free;
    end;
    if FileExists(tmpWal) then DeleteFile(tmpWal);
    if FileExists(tmpIdx) then DeleteFile(tmpIdx);
    if FileExists(tmp) then DeleteFile(tmp);
  end;
end;

procedure TVdbBackendV3.StreamCbRaw(Key: QWord; Data: PByte; Len: Integer);
var
  tag, n: Integer;
begin
  if FStreamAbort then Exit;
  if BatchIsMine and BatchMap.ContainsKey(Key) then Exit;
  { PassFilter'in sifir-kopya esdegeri: satir etiketi degerin ILK baytlarindan
    cikar; 8 baytlik sabit tampona kopyalanir (satir basina tahsis YOK). }
  if (FStreamFilter >= 0) and Assigned(FRowTag) then
  begin
    n := Len;
    if n > Length(FStreamTagBuf) then n := Length(FStreamTagBuf);
    if n > 0 then Move(Data^, FStreamTagBuf[0], n);
    tag := FRowTag(FStreamTagBuf, Len);
    if (tag >= 0) and (tag <> FStreamFilter) then Exit;
  end;
  if not FStreamCb(Key, Data, Len, FStreamUser) then
    FStreamAbort := True;
end;

function TVdbBackendV3.ScanRawIterAll(TableFilter: Integer;
  Cb: TVDbRawCb; User: Pointer): Boolean;
var
  pair: TPair<QWord, TBatchRec>;
  n: Integer;
begin
  { v3.1: sonuc kumesi ARTIK BIRIKTIRILMEZ; satirlar dogrudan geri cagirima
    akitilir ve sayfa ici hucre KOPYALANMAZ. Eski yol her satirda iki dinamik
    diziyi SetLength(+1) ile buyutuyor (200k satirda O(n^2) kopya + 200k
    yeniden tahsis), ayrica satir basina deger icin bir TBytes ayiriyordu.
    Gorunurluk/eleme kurallari AYNI: once motor (kaplamada islem gormus
    anahtarlar atlanir), sonra kaplama. }
  FStreamCb := Cb;
  FStreamUser := User;
  FStreamAbort := False;
  FStreamFilter := TableFilter;
  { v3.4: akitma durumu BACKEND alanidir; ayni backend'i paylasan oturumlar
    ayni anda tararsa birbirini bozardi -> tarama boyunca kilit. }
  FEngCs.Enter;
  try
    if Length(FStreamTagBuf) < 8 then SetLength(FStreamTagBuf, 8);
    FEng.ScanAllRaw(StreamCbRaw);
    if FStreamAbort then Exit(False);

    if BatchOpen then
      for pair in BatchMap do
      begin
        if not pair.Value.Present then Continue;
        if not PassFilter(pair.Key, pair.Value.Value, TableFilter) then Continue;
        n := Length(pair.Value.Value);
        if n > 0 then
        begin
          if not Cb(pair.Key, @pair.Value.Value[0], n, User) then Exit(False);
        end
        else if not Cb(pair.Key, nil, 0, User) then Exit(False);
      end;
    Result := True;
  finally
    FEngCs.Leave;
  end;
end;

{ ------------------------------------------------- v3.3: sayfa zone map }

procedure TVdbBackendV3.StreamCbRawPaged(Key: QWord; Data: PByte;
  Len: Integer; PageNo: LongWord);
var
  tag, n: Integer;
begin
  if FStreamAbort then Exit;
  if BatchIsMine and BatchMap.ContainsKey(Key) then Exit;
  if (FStreamFilter >= 0) and Assigned(FRowTag) then
  begin
    n := Len;
    if n > Length(FStreamTagBuf) then n := Length(FStreamTagBuf);
    if n > 0 then Move(Data^, FStreamTagBuf[0], n);
    tag := FRowTag(FStreamTagBuf, Len);
    if (tag >= 0) and (tag <> FStreamFilter) then Exit;
  end;
  if not FStreamPageCb(Key, Data, Len, PageNo, FStreamPageUser) then
    FStreamAbort := True;
end;

function TVdbBackendV3.ScanRawIterAllPaged(TableFilter: Integer;
  Skip: PByte; SkipCount: Integer;
  Cb: TVDbRawPageCb; User: Pointer): Boolean;
begin
  { Toplu yazim acikken bekleyen kayitlarin sayfasi YOKTUR ve harita da
    guvenilmez; cagiran tam taramaya duser. }
  if BatchOpen then Exit(False);
  FStreamPageCb := Cb;
  FStreamPageUser := User;
  FStreamAbort := False;
  FStreamFilter := TableFilter;
  FEngCs.Enter;
  try
    if Length(FStreamTagBuf) < 8 then SetLength(FStreamTagBuf, 8);
    FEng.ScanAllRawPaged(StreamCbRawPaged, Skip, SkipCount);
    Result := not FStreamAbort;
  finally
    FEngCs.Leave;
  end;
end;

function TVdbBackendV3.DataStamp: QWord;
begin
  if FEng = nil then Exit(0);
  { v3.3: motorun ICERIK damgasi. Her motor ornegi essiz taban alir; damga
    yalnizca veri degistiren commit'te ilerler (salt-okunur islem commit'i
    haritayi bosa cikarmaz). }
  Result := FEng.DataStamp;
end;

{ ------------------------------------------------- v3.1: etiket sayaci }

function TVdbBackendV3.TagOf(Data: PByte; Len: Integer): Integer;
{ Satir etiketi = degerin ilk baytlari (FRowTag). Sema kaydi -1 doner.
  Sabit tampona en fazla 16 bayt kopyalanir; satir basina tahsis YOK. }
var
  n: Integer;
begin
  if not Assigned(FRowTag) then Exit(-1);
  if (Data = nil) or (Len <= 0) then Exit(-1);
  if Length(FTagBuf) < 16 then SetLength(FTagBuf, 16);
  n := Len;
  if n > 16 then n := 16;
  Move(Data^, FTagBuf[0], n);
  Result := FRowTag(FTagBuf, Len);
end;

procedure TVdbBackendV3.TagAdd(Tag: Integer; Delta: Int64);
var
  cur: Int64;
begin
  if Delta = 0 then Exit;
  { Sayac henuz kurulmadiysa yazma yolu haritayi KIRLETMEZ. }
  if not FTagCountsValid then Exit;
  if BatchOpen then
  begin
    if not BatchTagDelta.TryGetValue(Tag, cur) then cur := 0;
    BatchTagDelta.AddOrSetValue(Tag, cur + Delta);
    Exit;
  end;
  if not FTagCounts.TryGetValue(Tag, cur) then cur := 0;
  cur := cur + Delta;
  if cur <= 0 then FTagCounts.Remove(Tag)
  else FTagCounts.AddOrSetValue(Tag, cur);
end;

procedure TVdbBackendV3.TagBuildCb(Key: QWord; Data: PByte; Len: Integer);
var
  tag: Integer;
  cur: Int64;
begin
  tag := TagOf(Data, Len);
  if not FTagCounts.TryGetValue(tag, cur) then cur := 0;
  FTagCounts.AddOrSetValue(tag, cur + 1);
end;

procedure TVdbBackendV3.RebuildTagCounts;
{ Sayaci motorun GERCEK iceriginden yeniden kurar. Kalici bir kayit yoktur;
  bu yuzden cokme/bayatlik kaynakli yanlis sayim mumkun degildir. Pahali
  (tam tarama); yalnizca .idx ozeti yoksa/guvenilmezse cagrilir. }
begin
  FTagCounts.Clear;
  FTagCountsValid := False;
  if FEng = nil then Exit;
  if not Assigned(FRowTag) then Exit;
  FEng.ScanAllRaw(TagBuildCb);
  FTagCountsValid := True;
end;

function TVdbBackendV3.LoadTagCountsFromIdx: Boolean;
{ `.idx` ozeti dizinle AYNI LSN'de yazildi; idx taze ise ozet de tutarlidir.
  Bos ozet yalnizca bos veritabaninda guvenilirdir (bkz. IdxTagsValid). }
var
  tags: TVdbIdxTagArray;
  i: Integer;
begin
  Result := False;
  FTagCounts.Clear;
  FTagCountsValid := False;
  if (FEng = nil) or (not Assigned(FRowTag)) then Exit;
  if not FEng.IdxTagsValid then Exit;
  tags := FEng.IdxTags;
  for i := 0 to High(tags) do
    if tags[i].Count > 0 then
      FTagCounts.AddOrSetValue(tags[i].Tag, tags[i].Count);
  FTagCountsValid := True;
  Result := True;
end;

procedure TVdbBackendV3.GetTagSummary(out Tags: TVdbIdxTagArray);
var
  pair: TPair<Integer, Int64>;
  n: Integer;
begin
  SetLength(Tags, 0);
  if not FTagCountsValid then Exit;   // guvenilmez ozet YAZILMAZ
  SetLength(Tags, FTagCounts.Count);
  n := 0;
  for pair in FTagCounts do
  begin
    if pair.Value <= 0 then Continue;
    Tags[n].Tag := pair.Key;
    Tags[n].Count := pair.Value;
    Inc(n);
  end;
  SetLength(Tags, n);
end;

procedure TVdbBackendV3.MergeTagDeltas;
var
  pair: TPair<Integer, Int64>;
  cur: Int64;
begin
  if (BatchTagDelta = nil) or (BatchTagDelta.Count = 0) then Exit;
  if not FTagCountsValid then
  begin
    BatchTagDelta.Clear;
    Exit;
  end;
  for pair in BatchTagDelta do
  begin
    if not FTagCounts.TryGetValue(pair.Key, cur) then cur := 0;
    cur := cur + pair.Value;
    if cur <= 0 then FTagCounts.Remove(pair.Key)
    else FTagCounts.AddOrSetValue(pair.Key, cur);
  end;
  BatchTagDelta.Clear;
end;

function TVdbBackendV3.CountTable(TableFilter: Integer): Int64;
var
  cur: Int64;
begin
  Result := -1;
  { Acik kaplama varsa bekleyen degisiklikler sayaca YANSIMAZ; cagiran
    (yurutucu) bu durumda tam tarama yapar. }
  if BatchIsMine then Exit;
  FEngCs.Enter;
  try
    if TableFilter < 0 then Exit(FEng.Count);
    if not Assigned(FRowTag) then Exit;
    { Sayac .idx ozetinden geldiyse burada tarama YOK; yoksa bir kez kurulur. }
    if not FTagCountsValid then
      RebuildTagCounts;
    if not FTagCountsValid then Exit;
    if FTagCounts.TryGetValue(TableFilter, cur) then Result := cur
    else Result := 0;
  finally
    FEngCs.Leave;
  end;
end;

{ ------------------------------------------------------------------ islem }

procedure TVdbBackendV3.BeginBatch;
var
  s: TWriteSet;
  sid: Cardinal;
begin
  RequireWritable;
  sid := VdbBackendSessionId;
  FEngCs.Enter;
  try
    if FSets.TryGetValue(sid, s) then Exit;   // zaten acik
    s := TWriteSet.Create(sid);
    s.StartGen := FCommitGen;
    FSets.AddOrSetValue(sid, s);
  finally
    FEngCs.Leave;
  end;
end;

procedure TVdbBackendV3.CommitBatch;
var
  s: TWriteSet;
  i: Integer;
  fpair: TPair<Cardinal, TWriteSet>;
begin
  RequireWritable;
  s := OwnSet;
  if s = nil then Exit;
  FEngCs.Enter;
  try
    if Assigned(FBeforeCommit) then
      FBeforeCommit;        // kisit denetimi: hata firlatirsa kaplama durur
    { v3.4: cakisma denetimi UYGULAMADAN ONCE yapilir: yarim uygulama yok. }
    VerifyNoConflict(s);
    { v3.6: yabanci anahtar defteri. ONEMLI: ApplyBatch yazma kumesini
      TEMIZLER (Map/Order), bu yuzden kayit ONDAN ONCE alinir. Biz commit
      ederken BASKA bir kume hala aciksa, o kume hizli yolda yazmis olabilir
      (before-image yok); dokundugumuz anahtarlar gen degeriyle deftere
      birakilir. Gen bir sonraki degere yazilir; sayac ancak uygulama
      basarili olursa artar (basarisizlikta yalnizca FAZLA cakisma gorunur,
      veri kaybi degil). }
    if FSets.Count > 1 then
    begin
      { v3.6: acik kumeler artik before-image kaydetmek ZORUNDA (motor
        degerleri bu commit ile degisti). Bayrak kilit altinda yazilir;
        kume sahibi kilitsiz okudugu icin en kotu ihtimalle tek satir gec
        fark edilir, o satiri da FAlien defteri yakalar. }
      for fpair in FSets do
        if fpair.Value <> s then
          fpair.Value.NeedBefore := True;
      for i := 0 to s.Order.Count - 1 do
        FAlien.AddOrSetValue(s.Order[i], FCommitGen + 1);
    end;
    ApplyBatch;
    { v3.1: parti ici etiket degisimleri simdi sayaca islenir. }
    MergeTagDeltas;
    Inc(FCommitGen);
    { v3.4: yazma kumesi commit ile KAPANIR (eski kodda BatchOpen:=False
      bu noktadaydi; otomatik sikistirma acik parti gormemeli). }
    FSets.Remove(s.Session);
    if FSets.Count = 0 then FAlien.Clear;
    if FDirty then
    begin
      FEng.Commit(True);
      FDirty := False;
      LogFinish;
      MaybeCheckpoint;
      MaybeAutoCompact;     // v3.2 (H25)
    end;
  finally
    FEngCs.Leave;
  end;
  s.Free;
end;

procedure TVdbBackendV3.AbortBatch;
var
  s: TWriteSet;
begin
  RequireWritable;
  s := OwnSet;
  if s = nil then Exit;
  FEngCs.Enter;
  try
    LogAbort;               // yarim islem gunluge SIZMAZ
    FSets.Remove(s.Session);
  finally
    FEngCs.Leave;
  end;
  s.Free;
end;

procedure TVdbBackendV3.Flush;
begin
  if BatchOpen then Exit;
  { P-DUR sozlesmesi yalniz DAYANIKLILIK ister: commit WAL'e yazilip fsync
    edilir. 2026-10-25 (Sprint 3.12): ONCEDEN burada tam `Checkpoint` de
    yapiliyordu; SQL katmani her autocommit yazimdan sonra Flush cagirdigi
    icin tek satirlik INSERT tum sayfalari veri dosyasina geri yaziyordu.
    Olculen bedel: autocommit INSERT 0,42 ms (v2) -> 1,17 ms (v3) — kabul
    hedefi 0,55 ms asiliyordu. Artik checkpoint YALNIZ esik asilinca
    (`MaybeCheckpoint`), acik cagrida, kapanista, yedekte ve VACUUM'da
    yapilir; veri dosyasi motor acikken bayat olabilir, dogru kaynak WAL'dir. }
  if FDirty then
  begin
    FEngCs.Enter;
    try
      if FDirty then
      begin
        FEng.Commit(True);
        FDirty := False;
        LogFinish;
        MaybeCheckpoint;
        MaybeAutoCompact;     // v3.2 (H25): autocommit yolu
      end;
    finally
      FEngCs.Leave;
    end;
  end;
end;

function TVdbBackendV3.GetInBatch: Boolean;
begin
  Result := BatchOpen;
end;

function TVdbBackendV3.SoleWriter: Boolean;
begin
  { v3.4: sema (FTables/FSchemaDirty) ve savepoint yiginlari TVTableDb'de
    GLOBALDIR. Bu yuzden DDL / SAVEPOINT yalnizca tek yazma islemi varken
    yapilir; coklu yazmada bunlar ACIK hatayla reddedilir (sessiz karisiklik
    yerine). }
  if FSets = nil then Exit(True);
  FEngCs.Enter;
  try
    Result := FSets.Count <= 1;
  finally
    FEngCs.Leave;
  end;
end;

{ --------------------------------------------------- v3.2: SAVEPOINT }

function TVdbBackendV3.FindSavepoint(const Name: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  if Savepoints = nil then Exit;
  for i := Savepoints.Count - 1 downto 0 do
    if SameText(Savepoints[i].Name, Name) then
      Exit(i);
end;

procedure TVdbBackendV3.ClearSavepoints;
var
  i: Integer;
  sp: TSavepointRec;
begin
  if Savepoints = nil then Exit;
  for i := 0 to Savepoints.Count - 1 do
  begin
    sp := Savepoints[i];
    sp.Journal.Free;
    sp.TagDelta.Free;
  end;
  Savepoints.Clear;
end;

{ Key ilk kez (bu savepoint'ten sonra) degistirilmeden ONCE cagrilir:
  her aktif savepoint icin anahtarin o andaki halini bir kez saklar.
  Maliyet yalnizca savepoint VARKEN ve anahtar basina BIR kez olur. }
procedure TVdbBackendV3.JournalKey(Key: QWord);
var
  i: Integer;
  sp: TSavepointRec;
  je: TSavepointKeyRec;
begin
  if (Savepoints = nil) or (Savepoints.Count = 0) then Exit;
  for i := 0 to Savepoints.Count - 1 do
  begin
    sp := Savepoints[i];
    if sp.Journal.ContainsKey(Key) then Continue;
    je.HadBefore := BatchMap.TryGetValue(Key, je.Rec);
    if not je.HadBefore then
    begin
      je.Rec.Present := False;
      je.Rec.Value := nil;
    end;
    sp.Journal.AddOrSetValue(Key, je);
  end;
end;

procedure TVdbBackendV3.Savepoint(const Name: string);
var
  sp: TSavepointRec;
  pair: TPair<Integer, Int64>;
begin
  RequireBatchWrite;
  if FindSavepoint(Name) >= 0 then
    raise EVdbBackendV3.CreateFmt('savepoint zaten var: %s', [Name]);
  { SQL standardi: SAVEPOINT acik islem yoksa ORTUK islem baslatir. }
  if not BatchOpen then BeginBatch;
  sp.Name := Name;
  sp.OrderLen := BatchOrder.Count;
  sp.Journal := TDictionary<QWord, TSavepointKeyRec>.Create;
  sp.TagDelta := TDictionary<Integer, Int64>.Create;
  for pair in BatchTagDelta do
    sp.TagDelta.AddOrSetValue(pair.Key, pair.Value);
  Savepoints.Add(sp);
end;

function TVdbBackendV3.RollbackToSavepoint(const Name: string): Boolean;
var
  ix, i: Integer;
  sp: TSavepointRec;
  st: TWriteSet;
  pair: TPair<QWord, TSavepointKeyRec>;
  tp: TPair<Integer, Int64>;
begin
  RequireBatchWrite;
  ix := FindSavepoint(Name);
  if ix < 0 then Exit(False);
  sp := Savepoints[ix];
  st := OwnSet;
  { 1) Savepoint'ten sonra degisen anahtarlari o andaki haline dondur.
    HadBefore=False olanlar BatchMap'te hic yoktu -> kaydi da silinir ve
    cakisma denetimindeki "onceki deger" kaydi da unutulur (aksi halde
    artik yazmadigim bir anahtar icin bosuna cakisma gorunurdu). }
  for pair in sp.Journal do
  begin
    if pair.Value.HadBefore then
      BatchMap.AddOrSetValue(pair.Key, pair.Value.Rec)
    else
    begin
      BatchMap.Remove(pair.Key);
      if st <> nil then st.Before.Remove(pair.Key);
    end;
  end;
  { 2) BatchOrder'i savepoint uzunluguna kirp. Girisler yalnizca "BatchMap'te
    yokken" eklendigi ve savepoint disinda silinmedigi icin kirpma tam
    olarak sonradan eklenen girisleri atar. }
  while BatchOrder.Count > sp.OrderLen do
    BatchOrder.Delete(BatchOrder.Count - 1);
  { 3) Etiket deltalari da savepoint haline doner. }
  BatchTagDelta.Clear;
  for tp in sp.TagDelta do
    BatchTagDelta.AddOrSetValue(tp.Key, tp.Value);
  { 4) SONRAKI savepoint'ler atilir; HEDEF kalir (SQLite davranisi:
    ayni noktaya tekrar donulebilir ve RELEASE edilebilir). }
  for i := Savepoints.Count - 1 downto ix + 1 do
  begin
    sp := Savepoints[i];
    sp.Journal.Free;
    sp.TagDelta.Free;
    Savepoints.Delete(i);
  end;
  Result := True;
end;

function TVdbBackendV3.ReleaseSavepoint(const Name: string): Boolean;
var
  ix, i: Integer;
  sp: TSavepointRec;
begin
  RequireBatchWrite;
  ix := FindSavepoint(Name);
  if ix < 0 then Exit(False);
  { RELEASE veriyi COMMIT ETMEZ; yalnizca geri donme noktasini (ve
    sonrakileri) dusurur. }
  for i := Savepoints.Count - 1 downto ix do
  begin
    sp := Savepoints[i];
    sp.Journal.Free;
    sp.TagDelta.Free;
    Savepoints.Delete(i);
  end;
  Result := True;
end;

{ ------------------------------------------------------ sema / sifreleme }

function TVdbBackendV3.ColumnKeyPath: string;
begin
  Result := ChangeFileExt(FPath, '.colkey');
end;

function TVdbBackendV3.EnsureColumnKey: QWord;
var
  id: QWord;
begin
  { v3.2: .colkey bicimi v2 ile AYNI olmali (VDbCrypt): ilk 8 bayt sihir,
    sonra anahtar kimligi, sonra DPAPI ile korunmus 32 baytlik anahtar.
    Dosya varsa yuklenir (anahtar SUREC KAYIT DEFTERINE yazilir; satir
    kodlayicisi degeri onunla muhurler), yoksa uretilir. }
  if FileExists(ColumnKeyPath) then
  begin
    id := 0;
    if not VDbColumnKeyLoadFile(ColumnKeyPath, id) then
      raise EVdbBackendV3.Create('kolon anahtari yuklenemedi: ' +
        ColumnKeyPath);
    Exit(id);
  end;
  id := 0;
  if not VDbColumnKeyCreateFile(ColumnKeyPath, id) then
    raise EVdbBackendV3.Create('kolon anahtari olusturulamadi: ' +
      ColumnKeyPath);
  Result := id;
end;

function TVdbBackendV3.FileEncrypted: Boolean;
begin
  { v3.2: kolon sifrelemesi dosya sifrelemesine dayanir; sayfa deposu
    parola/anahtar ile acildiysa True. }
  Result := (FEng <> nil) and FEng.Store.Encrypted;
end;

function TVdbBackendV3.ColumnKeyId: QWord;
var
  id: QWord;
begin
  Result := 0;
  if not FileExists(ColumnKeyPath) then Exit;
  { Yukleme AYNI ZAMANDA anahtari surce kayit defterine yazar; sifreli
    kolon degerlerinin cozulmesi icin bu sart. }
  id := 0;
  if not VDbColumnKeyLoadFile(ColumnKeyPath, id) then
    raise EVdbBackendV3.Create('kolon anahtari yuklenemedi: ' +
      ColumnKeyPath);
  Result := id;
end;

procedure TVdbBackendV3.SetBeforeCommit(Proc: TDbCommitHook);
begin
  FBeforeCommit := Proc;
end;

procedure TVdbBackendV3.SetRowTagFunc(AValue: TVDbRowTagFunc);
begin
  FRowTag := AValue;
  if FEng = nil then Exit;
  { v3.1: sayac kaynagi, en iyiden en pahaliya:
      1) `.idx` ozeti (dizinle ayni LSN) -> tarama YOK
      2) bos veritabani (0 anahtar)     -> dogru taban 0, tarama YOK
      3) aksi halde                     -> ilk COUNT isteginde bir kez tarama }
  if FEng.IdxTagsValid then
    LoadTagCountsFromIdx
  else if FEng.Count = 0 then
  begin
    FTagCounts.Clear;
    FTagCountsValid := True;
  end
  else
    FTagCountsValid := False;
end;

function TVdbBackendV3.GetDirty: Boolean;
begin
  Result := FDirty or (BatchOpen and (BatchMap.Count > 0));
end;

procedure TVdbBackendV3.WaitForeignTxn(ASessionId: Cardinal);
begin
  { v3.0 tek yazar: beklenecek yabanci islem yok. }
end;

procedure TVdbBackendV3.RefreshBatchSnapshot;
begin
  { v3.0'da snapshot/MVCC yok: parti icinde her okuma en guncel kaplamayi
    ve motoru gorur; ilerletilecek gorunurluk penceresi yok. }
end;

function TVdbBackendV3.GetFilePath: string;
begin
  Result := FPath;
end;

function TVdbBackendV3.Verify(out Report: string): Boolean;
begin
  { Acik partideki degisiklikler henuz durabil degil; denetim yalnizca
    onaylanmis durumu kapsar. Sessizce commit etmek yerine acikca reddet. }
  if BatchOpen then
  begin
    Report := 'acik parti varken VERIFY yapilamaz (once COMMIT/ROLLBACK)';
    Exit(False);
  end;
  FEngCs.Enter;
  try
    Result := FEng.Verify(Report);
  finally
    FEngCs.Leave;
  end;
end;

procedure TVdbBackendV3.BackupTo(const DestPath: string);
begin
  if BatchOpen then
    raise EVdbBackendV3.Create('acik parti varken yedek alinamaz (once COMMIT/ROLLBACK)');
  { Bellekte commit edilmemis degisiklik varsa once durabil hale getir. }
  FEngCs.Enter;
  try
    if FDirty then
    begin
      FEng.Commit(True);
      FDirty := False;
      LogFinish;
    end;
    { Checkpoint dosyayi tamamlar ve WAL'i budar: kopya kendi kendine yeter. }
    FEng.Checkpoint(True);
    FEng.Store.CopyCommittedTo(DestPath);
  finally
    FEngCs.Leave;
  end;
end;

procedure TVdbBackendV3.RestoreFrom(const SrcPath: string);
var
  tmp: string;
  src, dst: TFileStream;
  hdr: array[0..75] of Byte;
  magic, ver, flags: LongWord;
  i: Integer;
begin
  RequireWritable;
  if BatchOpen then
    raise EVdbBackendV3.Create('acik parti varken geri yukleme yapilamaz');
  if not FileExists(SrcPath) then
    raise EVdbBackendV3.Create('RESTORE: yedek dosyasi bulunamadi: ' + SrcPath);
  if SameFileName(ExpandFileName(SrcPath), ExpandFileName(FPath)) then
    raise EVdbBackendV3.Create('RESTORE: kaynak ile hedef ayni dosya');
  src := TFileStream.Create(SrcPath, fmOpenRead or fmShareDenyNone);
  try
    if src.Size < SizeOf(hdr) then
      raise EVdbBackendV3.Create('RESTORE: kaynak dosya cok kisa');
    src.ReadBuffer(hdr, SizeOf(hdr));
  finally
    src.Free;
  end;
  Move(hdr[0], magic, SizeOf(magic));
  Move(hdr[4], ver, SizeOf(ver));
  if (magic <> VDB_FILE_MAGIC) or (ver <> VDB_FILE_VER) then
    raise EVdbBackendV3.Create('RESTORE: kaynak v3 sayfa motoru dosyasi degil');

  { Sifreleme bicimi ve anahtar kaynakla AYNI olmali; aksi halde geri
    yuklenen dosya acilamaz ya da yanlis anahtarla sessizce kalirdi. }
  Move(hdr[VDB_META_FLAGS], flags, SizeOf(flags));
  if (flags and VDB_META_FLAG_ENC) <> 0 then
  begin
    if not FEng.Store.Encrypted then
      raise EVdbBackendV3.Create(
        'RESTORE: kaynak sifreli, hedef sifresiz (once sifreli olarak acin)');
    for i := 0 to 15 do
      if hdr[VDB_META_KEYCHECK + i] <> FEng.Store.KeyCheck[i] then
        raise EVdbBackendV3.Create(
          'RESTORE: yedek farkli anahtarla sifrelenmis (anahtar dogrulayici tutmadi)');
  end
  else if FEng.Store.Encrypted then
    raise EVdbBackendV3.Create(
      'RESTORE: kaynak sifresiz, hedef sifreli');

  { Calisan durumu diske indir; sonra motoru kapat. }
  FEngCs.Enter;
  try
    if FDirty then
    begin
      FEng.Commit(True);
      FDirty := False;
      LogFinish;
    end;
    FEng.Checkpoint(True);

    tmp := FPath + '.restore.tmp';
    if FileExists(tmp) then DeleteFile(tmp);
    src := TFileStream.Create(SrcPath, fmOpenRead or fmShareDenyNone);
    try
      dst := TFileStream.Create(tmp, fmCreate);
      try
        dst.CopyFrom(src, 0);
        VDbFlushStream(dst);
      finally
        dst.Free;
      end;
    finally
      src.Free;
    end;

    SwapDbFile(tmp);
  finally
    FEngCs.Leave;
  end;
  { v4: RESTORE dosya icerigini BASTAN yazar: nesil kopmasi. Bu andan
    onceki zamanlar icin PITR reddedilir; sonrasi tam calisir. }
  EnsureLogBase(1, 'RESTORE');
end;

procedure TVdbBackendV3.CompactCb(Key: QWord; const Value: TBytes);
begin
  if not FCompactEng.Insert(Key, Value) then
    raise EVdbBackendV3.Create(Format(
      'VACUUM: anahtar $%.16x yeni dosyaya yazilamadi', [Key]));
  Inc(FCompactN);
end;

procedure TVdbBackendV3.Compact(out OldBytes, NewBytes: Int64);
var
  tmp: string;
  newEng: TVdbPageEngine;
  tagsWere: Boolean;
begin
  RequireWritable;
  if BatchOpen then
    raise EVdbBackendV3.Create('acik parti varken VACUUM yapilamaz');
  FEngCs.Enter;
  try
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
    LogFinish;
  end;
  FEng.Checkpoint(True);
  { Sprint 3.10: CANLI dosyayi ikinci kez ACMA — Unix'te flock cakisir. }
  OldBytes := VDbFileBytes(FPath);

  tmp := FPath + '.compact.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  newEng := NewEngine(tmp);
  try
    try
      newEng.Open(True);
      FCompactEng := newEng;
      FCompactN := 0;
      try
        FEng.ScanAll(CompactCb);
      finally
        FCompactEng := nil;
      end;
      newEng.Close;   // checkpoint + idx; dosya tam ve kendi kendine yeter
    finally
      FreeAndNil(newEng);
    end;
  except
    { Yarim kalan gecici dosya bir sonraki VACUUM'u etkilemesin. }
    if FileExists(tmp) then DeleteFile(tmp);
    raise;
  end;

  { Kaynak dosya ve yeni dosya ayni canli anahtar kumesini tasimali. }
  tagsWere := FTagCountsValid;
  if FCompactN <> FEng.Count then
  begin
    if FileExists(tmp) then DeleteFile(tmp);
    raise EVdbBackendV3.Create(Format(
      'VACUUM: anahtar sayisi tutmuyor (yazilan %d, kaynak %d)',
      [FCompactN, FEng.Count]));
  end;

  SwapDbFile(tmp);
  { v3.1: VACUUM anahtar kumesini KORUR (yukarida dogrulandi); sayac da
    gecerli kalir -> VACUUM sonrasi COUNT(*) yine O(1). }
  FTagCountsValid := tagsWere;
  NewBytes := VDbFileBytes(FPath);
  { v4: VACUUM mantiksal icerigi KORUR (yukarida sayi dogrulandi); ayni
    nesil icinde yeni bir checkpoint tabani yazilir, PITR zinciri kopmaz. }
  EnsureLogBase(0, 'VACUUM');
  finally
    FEngCs.Leave;
  end;
end;

procedure TVdbBackendV3.Rekey(const NewPassword: string);
var
  tmp: string;
  newEng: TVdbPageEngine;
  n: Int64;
  tagsWere: Boolean;
begin
  RequireWritable;
  if BatchOpen then
    raise EVdbBackendV3.Create('acik parti varken ALTER DATABASE KEY yapilamaz');
  FEngCs.Enter;
  try
  if not FEng.Store.Encrypted then
    raise EVdbBackendV3.Create(
      'dosya sifresiz: ALTER DATABASE KEY icin once sifreli dosya gerekir');
  if Trim(NewPassword) = '' then
    raise EVdbBackendV3.Create('ALTER DATABASE KEY: yeni parola bos olamaz');
  if FDirty then
  begin
    FEng.Commit(True);
    FDirty := False;
    LogFinish;
  end;
  FEng.Checkpoint(True);

  tmp := FPath + '.rekey.tmp';
  if FileExists(tmp) then DeleteFile(tmp);
  { Yeni dosya YENI parola ile olusturulur: kayitlar cozulmus halde
    taramadan gelir, yazarken yeni anahtarla sifrelenir. }
  newEng := TVdbPageEngine.CreateWithPassword(tmp, NewPassword, FPoolPages);
  try
    try
      newEng.Open(True);
      FCompactEng := newEng;
      FCompactN := 0;
      n := 0;
      try
        FEng.ScanAll(CompactCb);
      finally
        FCompactEng := nil;
      end;
      n := FCompactN;
      newEng.Close;   // checkpoint + idx
    finally
      FreeAndNil(newEng);
    end;
  except
    if FileExists(tmp) then DeleteFile(tmp);
    raise;
  end;

  if n <> FEng.Count then
  begin
    if FileExists(tmp) then DeleteFile(tmp);
    raise EVdbBackendV3.Create(Format(
      'ALTER DATABASE KEY: anahtar sayisi tutmuyor (yazilan %d, kaynak %d)',
      [n, FEng.Count]));
  end;

  tagsWere := FTagCountsValid;
  SwapDbFileWith(tmp, nil, NewPassword, True);
  { Anahtar kumesi KORUNDU (yukarida dogrulandi) -> sayac gecerli. }
  FTagCountsValid := tagsWere;
  { v4: ALTER KEY yalniz sifreleme bicimini degistirir; mantiksal icerik
    ayni -> ayni nesilde yeni taban. }
  EnsureLogBase(0, 'ALTER DATABASE KEY');
  finally
    FEngCs.Leave;
  end;
end;

{ --- v3.2: yonetim / otomatik sikistirma (H25 esdegeri) --- }

function TVdbBackendV3.ValBytes: Int64;
begin
  if FEng = nil then Exit(0);
  Result := Int64(FEng.Store.PageCount) * Int64(FEng.Store.PageSize);
end;

function TVdbBackendV3.GetDeadBytes: Int64;
begin
  if FEng = nil then Exit(0);
  { v3'te "olu" alan = freelist'teki sayfalar: silinen/guncellenen satirin
    bosalttigi sayfa yeniden kullanilabilir, ama VACUUM'a kadar dosyada
    durur. (Heap ici bosluk freelist'e donustugu anda burada sayilir.) }
  Result := Int64(FEng.Store.FreeCount) * Int64(FEng.Store.PageSize);
end;

function TVdbBackendV3.GetDataFileSize: Int64;
begin
  Result := ValBytes;
end;

function TVdbBackendV3.GetAutoCompactEnabled: Boolean;
begin
  Result := FAutoCompactOn;
end;

procedure TVdbBackendV3.SetAutoCompactEnabled(AValue: Boolean);
begin
  FAutoCompactOn := AValue;
end;

function TVdbBackendV3.GetAutoCompactRatio: Double;
begin
  Result := FAutoCompactRatio;
end;

procedure TVdbBackendV3.SetAutoCompactRatio(AValue: Double);
begin
  if AValue <= 0 then AValue := 0.35;
  if AValue > 1 then AValue := 1;
  FAutoCompactRatio := AValue;
end;

function TVdbBackendV3.GetAutoCompactMinBytes: Int64;
begin
  Result := FAutoCompactMinBytes;
end;

procedure TVdbBackendV3.SetAutoCompactMinBytes(AValue: Int64);
begin
  if AValue < 0 then AValue := 0;
  FAutoCompactMinBytes := AValue;
end;

function TVdbBackendV3.GetAutoCompactCount: Int64;
begin
  Result := FAutoCompactCount;
end;

function TVdbBackendV3.GetLastAutoCompactError: string;
begin
  Result := FLastAutoCompactError;
end;

function TVdbBackendV3.AutoCompactBody(out OldBytes, NewBytes: Int64;
  MaxDeadRatio: Double; MinBytes: Int64): Boolean;
var
  sz, dead: Int64;
begin
  Result := False;
  OldBytes := 0;
  NewBytes := 0;
  if FEng = nil then Exit;
  if BatchOpen then Exit;      // parti icinde VACUUM olmaz (veri kaplamada)
  sz := ValBytes;
  if sz <= 0 then Exit;
  if sz < MinBytes then Exit;
  dead := GetDeadBytes;
  if dead <= 0 then Exit;
  if (Double(dead) / Double(sz)) < MaxDeadRatio then Exit;
  Compact(OldBytes, NewBytes);
  Result := True;
end;

function TVdbBackendV3.AutoCompact(out OldBytes, NewBytes: Int64;
  MaxDeadRatio: Double; MinBytes: Int64): Boolean;
begin
  Result := AutoCompactBody(OldBytes, NewBytes, MaxDeadRatio, MinBytes);
end;

procedure TVdbBackendV3.MaybeAutoCompact;
// H25: commit tamamlandiktan SONRA. Karar O(1); yalniz esik asilirsa dosya
// bir kez bastan yazilir. Hata commit'i BOZMAZ (veri zaten fsync'li);
// yalnizca LastAutoCompactError'a yazilir.
var
  o, n: Int64;
begin
  if (not FAutoCompactOn) or FAutoCompactBusy then Exit;
  if BatchOpen or (FEng = nil) then Exit;
  if GetDeadBytes <= 0 then Exit;
  if ValBytes < FAutoCompactMinBytes then Exit;
  if (Double(GetDeadBytes) / Double(ValBytes)) < FAutoCompactRatio then Exit;
  FAutoCompactBusy := True;
  try
    try
      AutoCompactBody(o, n, FAutoCompactRatio, FAutoCompactMinBytes);
      Inc(FAutoCompactCount);
      FLastAutoCompactError := '';
    except
      on E: Exception do
        FLastAutoCompactError := E.Message;
    end;
  finally
    FAutoCompactBusy := False;
  end;
end;

procedure TVdbBackendV3.SwapDbFile(const NewFilePath: string);
begin
  SwapDbFileWith(NewFilePath, FKey, FPassword, FHasPassword);
end;

{ v3.2: yeni kimlik bilgileriyle dosya degistirme. Basarisizlikta ESKI
  kimlik geri kurulur; aksi halde .bak'tan donen ESKI dosya yeni parolayla
  acilmaya calisilir ve backend FEng=nil ile kilitsiz kalirdi. }
procedure TVdbBackendV3.SwapDbFileWith(const NewFilePath: string;
  const AKey: TBytes; const APassword: string; AHasPassword: Boolean);
var
  bak, wal, idx: string;
  oldKey: TBytes;
  oldPass: string;
  oldHas: Boolean;
begin
  oldKey := FKey;
  oldPass := FPassword;
  oldHas := FHasPassword;
  bak := FPath + '.bak';
  wal := FPath + '.wal';
  idx := FPath + '.idx';
  FreeAndNil(FEng);
  FEng := nil;
  FKey := Copy(AKey, 0, Length(AKey));
  FPassword := APassword;
  FHasPassword := AHasPassword;
  try
    if FileExists(bak) then DeleteFile(bak);
    if not RenameFile(FPath, bak) then
      raise EVdbBackendV3.Create('dosya degistirme: mevcut dosya .bak yapilamadi');
    try
      if not RenameFile(NewFilePath, FPath) then
        raise EVdbBackendV3.Create('dosya degistirme: yeni dosya yerine konamadi');
    except
      RenameFile(bak, FPath);
      raise;
    end;
    { Yeni dosyanin WAL'i ve dizini ESKI dosyaya aittir; asla kullanilmaz. }
    if FileExists(wal) then DeleteFile(wal);
    if FileExists(idx) then DeleteFile(idx);
    { Uretim sirasinda yeni dosyanin yaninda olusan gecici WAL/.idx de
      kalici olmamali: yoksa sonraki acilis onlari bu dosyaya ait sanar. }
    if FileExists(NewFilePath + '.wal') then DeleteFile(NewFilePath + '.wal');
    if FileExists(NewFilePath + '.idx') then DeleteFile(NewFilePath + '.idx');
    FEng := NewEngine(FPath);
    try
      FEng.Open(False);
    except
      FreeAndNil(FEng);
      raise;
    end;
    { Turetilmis ham anahtar (parola modunda da) yeni dosyaya aittir. }
    FKey := Copy(FEng.Store.Key, 0, Length(FEng.Store.Key));
    { v3.1: icerik degismis olabilir (RESTORE/REKEY) -> sayac guvenilmez.
      VACUUM cagirani (Compact) anahtar kumesinin AYNI oldugunu dogrular ve
      bayragi geri kurar. Harita SILINMEZ: bayrak False iken yazma yolu onu
      kirletmez, ilk COUNT isteginde tam taramayla yeniden kurulur. }
    FEng.OnTagSummary := GetTagSummary;
    FTagCountsValid := False;
  except
    { Yarim kalan degistirmede .bak'tan ve ESKI kimlikle don. }
    if FEng = nil then
    begin
      FKey := oldKey;
      FPassword := oldPass;
      FHasPassword := oldHas;
      try
        if FileExists(bak) then
        begin
          if FileExists(FPath) then DeleteFile(FPath);
          RenameFile(bak, FPath);
        end;
        if FileExists(FPath) then
        begin
          FEng := NewEngine(FPath);
          FEng.Open(False);
          FEng.OnTagSummary := GetTagSummary;
          FTagCountsValid := False;
        end;
      except
        FreeAndNil(FEng);
      end;
    end;
  end;
end;

{ ==================================================== v4: gunluk / PITR }

type
  { Bir gunluk araligini ozetleyen ziyaretci. }
  TLogRangeVisit = class
  public
    Seen: Boolean;
    FirstSeq: Int64;
    FirstTs: Int64;
    LastSeq: Int64;
    LastTs: Int64;
    Applied: Int64;
    Reason: string;
    procedure Visit(const E: TVdbLogEntry);
  end;

procedure TLogRangeVisit.Visit(const E: TVdbLogEntry);
begin
  if E.Kind = VDBLOG_KIND_BASE then Exit;
  if not Seen then
  begin
    Seen := True;
    FirstSeq := E.Seq;
    FirstTs := E.TsMs;
  end;
  LastSeq := E.Seq;
  LastTs := E.TsMs;
end;

procedure TVdbBackendV3.LogReplayCb(const E: TVdbLogEntry);
begin
  if FReplayEng = nil then Exit;
  if E.Kind = VDBLOG_KIND_BASE then Exit;
  try
    if E.Kind = VDBLOG_KIND_DEL then
    begin
      FReplayEng.Delete(E.Key);
      FReplayLastSeq := E.Seq;
      FReplayLastTs := E.TsMs;
      Exit;
    end;
    { PUT: anahtar varsa guncelle, yoksa ekle. Ayni anahtarin birden fazla
      kaydi sirayla gelir (son kazanir). }
    if FReplayEng.Contains(E.Key) then
      FReplayEng.Update(E.Key, E.NewVal)
    else
      FReplayEng.Insert(E.Key, E.NewVal);
    FReplayLastSeq := E.Seq;
    FReplayLastTs := E.TsMs;
  except
    on Ex: Exception do
      FReplayErr := Format('anahtar $%.16x: %s', [E.Key, Ex.Message]);
  end;
end;

function TVdbBackendV3.LogSupported: Boolean;
begin
  Result := (FLog <> nil) and FLog.Enabled;
end;

function TVdbBackendV3.LogStatus: string;
begin
  if (FLog = nil) or (not FLog.Enabled) then
  begin
    Result := FLogProblem;
    if Result = '' then Result := 'degisim gunlugu kapali';
  end
  else
    Result := FLogProblem;   { bos = sorun yok }
end;

function TVdbBackendV3.LogRangeInfo(out MinSeq, MaxSeq: Int64;
  out MinTsMs, MaxTsMs: Int64; out BaseCount: Integer): Boolean;
var
  rd: TVdbLogReader;
  bases: TVdbLogBaseArray;
  v: TLogRangeVisit;
begin
  MinSeq := 0;
  MaxSeq := 0;
  MinTsMs := 0;
  MaxTsMs := 0;
  BaseCount := 0;
  Result := False;
  if not LogSupported then Exit;
  rd := TVdbLogReader.Create(FPath);
  try
    bases := rd.ListBases;
    BaseCount := Length(bases);
    if BaseCount > 0 then
    begin
      MinSeq := bases[0].Seq;
      MinTsMs := bases[0].TsMs;
      MaxSeq := bases[BaseCount - 1].Seq;
      MaxTsMs := bases[BaseCount - 1].TsMs;
    end;
    if BaseCount > 0 then
    begin
      { En son surumu bulmak icin SON tabandan ileri replay edilir. Ilk
        tabandan baslamak, arada olusan bir nesil kopmasinda (RESTORE /
        replika taban kurulumu) DURUR ve MaxSeq'i oldugundan kucuk
        bildirirdi; oysa kopmadan SONRAKI gruplar tam okunabilir. }
      v := TLogRangeVisit.Create;
      try
        rd.Replay(bases[BaseCount - 1].Seq, 0, 0, v.Visit, v.Applied, v.Reason);
        if v.Seen then
        begin
          MaxSeq := v.LastSeq;
          MaxTsMs := v.LastTs;
        end;
      finally
        v.Free;
      end;
    end;
    Result := (BaseCount > 0) or (MaxSeq > 0);
  finally
    rd.Free;
  end;
end;

function TVdbBackendV3.BuildLogSnapshotBody(TimestampMs, Version: Int64;
  const DestPath: string;
  out ActualTsMs, ActualSeq: Int64): Boolean;
var
  rd: TVdbLogReader;
  bases: TVdbLogBaseArray;
  i, pick: Integer;
  baseDir, srcBase: string;
  eng: TVdbPageEngine;
  early: Boolean;
  reason: string;
  applied: Int64;
begin
  ActualTsMs := 0;
  ActualSeq := 0;
  Result := False;
  if not LogSupported then
    raise EVdbBackendV3.Create('PITR: ' + LogStatus);
  if DestPath = '' then
    raise EVdbBackendV3.Create('PITR: hedef yol bos');
  rd := TVdbLogReader.Create(FPath);
  try
    bases := rd.ListBases;
    if Length(bases) = 0 then
      raise EVdbBackendV3.Create(
        'PITR: bu veritabani icin degisim gunlugu tabani yok ' +
        '(ilk taban acilista olusur)');
    { Hedefe uyan EN SON taban: zamani ve/veya surumu asmayan. }
    pick := -1;
    for i := 0 to Length(bases) - 1 do
    begin
      if (TimestampMs > 0) and (bases[i].TsMs > TimestampMs) then Continue;
      if (Version > 0) and (bases[i].Seq > Version) then Continue;
      pick := i;
    end;
    if pick < 0 then
      raise EVdbBackendV3.CreateFmt(
        'PITR: hedef (ts=%d, surum=%d) en eski tabandan once; ' +
        'en erken taban ts=%d surum=%d',
        [TimestampMs, Version, bases[0].TsMs, bases[0].Seq]);

    baseDir := IncludeTrailingPathDelimiter(rd.Dir) + 'base';
    srcBase := IncludeTrailingPathDelimiter(baseDir) + bases[pick].Name;
    if not FileExists(srcBase) then
      raise EVdbBackendV3.Create('PITR: taban imaji bulunamadi: ' + srcBase);
    AsOfCopyFile(srcBase, DestPath);
    { Hedef dosyanin ESKI yan dosyalari (wal/idx) yeni icerikle uyusmaz;
      temizlenmezlerse motor bayat indeksle acabilir. }
    if FileExists(DestPath + '.wal') then DeleteFile(DestPath + '.wal');
    if FileExists(DestPath + '.idx') then DeleteFile(DestPath + '.idx');

    eng := NewEngine(DestPath);
    try
      eng.Open(False);
    except
      eng.Free;
      raise;
    end;
    FReplayEng := eng;
    FReplayErr := '';
    FReplayLastSeq := bases[pick].Seq;
    FReplayLastTs := bases[pick].TsMs;
    try
      early := rd.Replay(bases[pick].Seq, Version, TimestampMs, LogReplayCb,
        applied, reason);
      if FReplayErr <> '' then
        raise EVdbBackendV3.Create('PITR: ' + FReplayErr);
      if early and (Pos('nesil', reason) > 0) then
        raise EVdbBackendV3.CreateFmt(
          'PITR: gunlukte nesil kopmasi var, bu noktadan sonrasi ' +
          'kurtarilamaz (%s)', [reason]);
      eng.Commit(True);
      ActualTsMs := FReplayLastTs;
      ActualSeq := FReplayLastSeq;
      Result := True;
    finally
      FReplayEng := nil;
      try
        eng.Close;
      except
        { gecici hedef: kapanis hatasi sonucu bozmaz, dosya zaten yazildi }
      end;
      eng.Free;
    end;
  finally
    rd.Free;
  end;
end;

function TVdbBackendV3.BuildLogSnapshot(TimestampMs, Version: Int64;
  const DestPath: string;
  out ActualTsMs, ActualSeq: Int64): Boolean;
begin
  Result := BuildLogSnapshotBody(TimestampMs, Version, DestPath,
    ActualTsMs, ActualSeq);
end;

function TVdbBackendV3.ScanAllAtLogTime(TableFilter: Integer;
  TimestampMs, Version: Int64;
  out Keys: TQWordArray; out Vals: TValArray;
  out ActualTsMs, ActualSeq: Int64): Boolean;
var
  tmp, tmpWal, tmpIdx: string;
  eng: TVdbPageEngine;
begin
  Keys := nil;
  Vals := nil;
  ActualTsMs := 0;
  ActualSeq := 0;
  Result := False;
  tmp := FPath + '.pitr' + IntToStr(GetProcessID) + '_' +
    IntToStr(InterlockedIncrement(GAsOfCounter));
  tmpWal := tmp + '.wal';
  tmpIdx := tmp + '.idx';
  eng := nil;
  try
    BuildLogSnapshotBody(TimestampMs, Version, tmp, ActualTsMs, ActualSeq);
    eng := NewEngine(tmp);
    try
      eng.Open(False);
    except
      try
        eng.SimulateCrash;
      except
      end;
      eng.Free;
      eng := nil;
      raise;
    end;
    { v3.9: FScan* backend genelinde; ScanAll/ScanAllAt ile ayni alanlar.
      Paylasilan tampon kilit altinda doldurulur (onceden kilitsizdi). }
    FEngCs.Enter;
    try
      FScanKeys := nil;
      FScanVals := nil;
      FScanN := 0;
      FScanCap := 0;
      FScanFilter := TableFilter;
      eng.ScanAll(AsOfCb);
      SetLength(FScanKeys, FScanN);
      SetLength(FScanVals, FScanN);
      Keys := FScanKeys;
      Vals := FScanVals;
      FScanKeys := nil;
      FScanVals := nil;
      FScanN := 0;
      FScanCap := 0;
    finally
      FEngCs.Leave;
    end;
    Result := True;
  finally
    if eng <> nil then
    begin
      try
        eng.Close;
      except
      end;
      eng.Free;
    end;
    if FileExists(tmpWal) then DeleteFile(tmpWal);
    if FileExists(tmpIdx) then DeleteFile(tmpIdx);
    if FileExists(tmp) then DeleteFile(tmp);
  end;
end;

function TVdbBackendV3.ArchiveLogSet(const DestDir: string): Int64;
var
  rd: TVdbLogReader;
  srcDir, dstDir, src, dst: string;
  sr: TSearchRec;
  n: Int64;
  a, b: TFileStream;

  procedure CopyOne(const ASrc, ADst: string);
  var
    x, y: TFileStream;
  begin
    if FileExists(ADst) then
      if not DeleteFile(ADst) then
        raise EVdbBackendV3.Create('ARCHIVE WAL: hedef silinemedi: ' + ADst);
    x := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
    try
      y := TFileStream.Create(ADst, fmCreate);
      try
        y.CopyFrom(x, 0);
        VDbFlushStream(y);
        Inc(n, y.Size);
      finally
        y.Free;
      end;
    finally
      x.Free;
    end;
  end;

begin
  Result := 0;
  if not LogSupported then
    raise EVdbBackendV3.Create('ARCHIVE WAL: ' + LogStatus);
  rd := TVdbLogReader.Create(FPath);
  try
    srcDir := rd.Dir;
    if not DirectoryExists(srcDir) then
      raise EVdbBackendV3.Create('ARCHIVE WAL: gunluk dizini yok: ' + srcDir);
    dstDir := IncludeTrailingPathDelimiter(DestDir);
    ForceDirectories(dstDir);
    n := 0;
    if DirectoryExists(IncludeTrailingPathDelimiter(srcDir) + 'base') then
    begin
      ForceDirectories(dstDir + 'base');
      if FindFirst(IncludeTrailingPathDelimiter(srcDir) + 'base' + PathDelim +
        '*.odb', faAnyFile, sr) = 0 then
      begin
        repeat
          if (sr.Attr and faDirectory) = 0 then
          begin
            src := IncludeTrailingPathDelimiter(srcDir) + 'base' + PathDelim +
              sr.Name;
            dst := dstDir + 'base' + PathDelim + sr.Name;
            CopyOne(src, dst);
          end;
        until FindNext(sr) <> 0;
        FindClose(sr);
      end;
    end;
    if FindFirst(IncludeTrailingPathDelimiter(srcDir) + '*.vlog',
      faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) = 0 then
        begin
          src := IncludeTrailingPathDelimiter(srcDir) + sr.Name;
          dst := dstDir + sr.Name;
          CopyOne(src, dst);
        end;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    Result := n;
  finally
    rd.Free;
  end;
end;

{ ===================================================== v3.7: GUNLUK BUDAMA }

function TVdbBackendV3.GetLogPruneEnabled: Boolean;
begin
  Result := FLogPruneOn;
end;

procedure TVdbBackendV3.SetLogPruneEnabled(AValue: Boolean);
begin
  FLogPruneOn := AValue;
end;

function TVdbBackendV3.GetLogPruneKeepDays: Integer;
begin
  Result := FLogPruneDays;
end;

procedure TVdbBackendV3.SetLogPruneKeepDays(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  FLogPruneDays := AValue;
end;

function TVdbBackendV3.GetLogPruneKeepBases: Integer;
begin
  Result := FLogPruneBases;
end;

procedure TVdbBackendV3.SetLogPruneKeepBases(AValue: Integer);
begin
  if AValue < 1 then AValue := 1;
  FLogPruneBases := AValue;
end;

function TVdbBackendV3.GetLastLogPruneError: string;
begin
  Result := FLogPruneErr;
end;

function TVdbBackendV3.LogPrune(out ADroppedSegments,
  ADroppedBaseFiles: Integer; out ABytesFreed: Int64;
  out AErr: string): Boolean;
var
  rd: TVdbLogReader;
  oldest, cut: Int64;
  pr: TVdbLogPruneResult;
  needBase: Boolean;
begin
  ADroppedSegments := 0;
  ADroppedBaseFiles := 0;
  ABytesFreed := 0;
  AErr := '';
  if not LogSupported then
  begin
    AErr := 'budama: ' + LogStatus;
    Result := False;
    Exit;
  end;
  if FReadOnly then
  begin
    AErr := 'budama: salt-okunur oturum';
    Result := False;
    Exit;
  end;
  FEngCs.Enter;
  try
    { Acik yazma islemi varken checkpoint/taban alinmaz: once bitirilmeli. }
    if BatchIsMine then
    begin
      AErr := 'budama: acik islem varken calistirilamaz';
      Result := False;
      Exit;
    end;
    if FLogPruneDays > 0 then
      cut := VdbLogNowMs - Int64(FLogPruneDays) * Int64(86400000)
    else
      cut := 0;
    needBase := False;
    if cut > 0 then
    begin
      oldest := 0;
      rd := TVdbLogReader.Create(FPath);
      try
        if rd.OldestGroupTsMs(oldest) and (oldest < cut) then
          needBase := True;
      finally
        rd.Free;
      end;
    end;
    if needBase then EnsureLogBase(0, 'budama tabani');
    Result := VdbLogPruneAt(FPath, cut, FLogPruneBases, pr, AErr);
    ADroppedSegments := pr.DroppedSegments;
    ADroppedBaseFiles := pr.DroppedBaseFiles;
    ABytesFreed := pr.BytesFreed;
    FLogPruneErr := AErr;
  finally
    FEngCs.Leave;
  end;
end;

{ ===================================================== v4: REPLIKASYON }

function TVdbBackendV3.ReplSupported: Boolean;
begin
  Result := (FLog <> nil) and FLog.Enabled;
end;

procedure TVdbBackendV3.ReplSuspendLog(ASuspend: Boolean);
begin
  if ASuspend then
  begin
    { Yarim kalmis bir yerel grup varsa kapatilmaz: iptal edilir. }
    if FLogInGroup then
    begin
      if FLog <> nil then FLog.AbortGroup;
      FLogInGroup := False;
    end;
  end;
  FLogSuspended := ASuspend;
end;

function TVdbBackendV3.ReplAppendGroup(const ARaw: TBytes;
  out AErr: string): Boolean;
var
  seq: Int64;
begin
  AErr := '';
  Result := False;
  if not ReplSupported then
  begin
    AErr := LogStatus;
    if AErr = '' then AErr := 'degisim gunlugu kapali';
    Exit;
  end;
  if BatchOpen then
  begin
    AErr := 'acik parti varken replika grubu eklenemez';
    Exit;
  end;
  seq := FLog.AppendForeignGroup(ARaw, FEng.Store.LSN);
  if seq <= 0 then
  begin
    AErr := FLog.LastError;
    if AErr = '' then AErr := 'gunluge eklenemedi';
    Exit;
  end;
  Result := True;
end;

end.
