unit VDbBackendApi;

{ VDB v3 - Backend arayuzu (Sprint 2 / 2.1)

  Amac: SQL katmani (VDbTable / VDbSql / VDbExecutor) motorun SOMUT tipini
  (TVDb) degil bu arayuzu tanisin. Boylece ayni SQL kodu hem v2 motoru
  (satir-kayit dosyasi) hem v3 sayfa motoru uzerinde calisir.

  Bu birim BILEREK cok az seye bagimlidir (yalniz SysUtils): v3 backend'i
  v2 motorunu link etmeden derlenebilsin.

  ONEMLI - SAHIPLIK: arayuz referans saymaz. Uygulayan nesne cagiran
  tarafindan yaratilir ve yine cagiran tarafindan serbest birakilir.
  TVDb gibi dogrudan Create/Free ile yonetilen nesnelerin yasam dongusunu
  degistirmemek icin bilincli tercih: `_AddRef` -1 doner, `_Release` 0
  doner (hicbir sey yapmaz). Arayuzu bir degiskende tutarken nesneyi
  serbest birakmak cagiranin sorumlulugudur.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TQWordArray = array of QWord;
  TValArray = array of TBytes;

  { R-26: satirin icindeki TABLO ID'yi cozucu. KV katmani satir bicimini
    BILMEZ; cozucuyu VDbTable saglar.
      >= 0 : bu kayit o tabloya ait satir
      -1   : satir degil (semaya benzer ozel kayit) -> filtre uygulanmaz }
  TVDbRowTagFunc = function(const PlainValue: TBytes; ValueLen: Integer): Integer;

  { P-18a: sifir-kopya tarama geri cagrisi. Buf, motorun ic tamponuna
    isaret eder — YALNIZ cagri sirasinda gecerlidir, saklanmamali.
    False => tarama durur. }
  TVDbRawCb = function(Key: QWord; Buf: PByte; Len: Integer;
    User: Pointer): Boolean;

  { R-11: COMMIT oncesi geri-cagirim (deferrable kisit denetimi). }
  TDbCommitHook = procedure of object;

  { M11: yalnizca temel KV islemleri (transaction/WAL/indeks disarida). }
  IVDbKvStore = interface
    ['{6D8B2E71-4C1A-4F6E-9E3B-7A5C0D2F1A44}']
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer);
  end;

  { Motorun SQL katmanina sundugu tam yuzey. VDbTable'in bugun TVDb
    uzerinden yaptigi cagrilarin tamami burada; boylece motor degisir,
    ust katman degismez. }
  IVDbBackend = interface
    ['{B4E1C7A2-9F31-4D68-8E5A-2C7B1D904E56}']
    { --- temel kayit islemleri --- }
    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function Exists(Key: QWord): Boolean;
    function Count: Integer;

    { --- tarama --- }
    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer = -1);
    function ScanRawIterAll(TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer): Boolean;
    { v3.1: tablo basina canli satir sayisi (O(1) olabilir). Tam tarama ile
      AYNI yuklem. Acik kaplama veya desteklenmeyen yol -> -1 (cagiran
      tarama yapar). v2: -1 (dogrulanmis onbellek TVDb tarafindadir). }
    function CountTable(TableFilter: Integer): Int64;

    { --- islem / toplu yazim --- }
    procedure BeginBatch;
    procedure CommitBatch;
    procedure AbortBatch;
    procedure Flush;
    function GetInBatch: Boolean;
    property InBatch: Boolean read GetInBatch;

    { --- v3.2: SAVEPOINT / ROLLBACK TO / RELEASE SAVEPOINT ---
      Sozlesme (v2 TVDb ile AYNI, R-02):
        * Acik parti yoksa UYGULAMA baslatilir (SQL standardi: SAVEPOINT
          ortuk islem acar); sonraki COMMIT/ROLLBACK onu kapatir.
        * Ayni isimde ikinci SAVEPOINT hata verir (EVDbException
          ecDuplicateSavepoint); backend bunu Boolean ile degil istisna
          ile bildirir, cunku cagiran SQL katmani mesaji aynen gecirir.
        * ROLLBACK TO hedef savepoint'i KORUR (SQLite davranisi; ayni
          noktaya tekrar donulebilir), ondan SONRAKI savepoint'leri atar.
        * RELEASE hedefi ve sonrakileri atar; veriyi COMMIT ETMEZ.
        * Islem Commit/Abort edilince tum savepoint'ler dusurulur. }
    procedure Savepoint(const Name: string);
    function RollbackToSavepoint(const Name: string): Boolean;  // False: yok
    function ReleaseSavepoint(const Name: string): Boolean;     // False: yok

    { --- v3.2: ALTER DATABASE KEY (anahtar/parola rotasyonu) ---
      v3: dosya butunu yeni parola ile yeniden sifrelenir (eski kayitlar
      cozulur, yeni anahtarla yazilir; gecici dosya + atomik degistirme).
      v2: kayit duzeyi anahtar (.key) yeniden uretilir.
      Dosya sifresizse / parti acikken hata verir. }
    procedure Rekey(const NewPassword: string);

    { --- sema / sifreleme kancalari --- }
    function EnsureColumnKey: QWord;
    function ColumnKeyId: QWord;
    function ColumnKeyPath: string;
    { v3.2: dosyanin BUTUNU sifreli mi?
      v2: kayit seviyesi anahtar yuklu mu (TVDb.IsEncrypted).
      v3: sayfa dosyasi parola/anahtar ile sifreli mi (Store.Encrypted).
      Kolon sifrelemesi v3'te dosya sifrelemesine dayanir; bu yuzden
      TVTableDb ENCRYPTED kolon isteginde v3'te bunu arar. }
    function FileEncrypted: Boolean;
    procedure SetBeforeCommit(Proc: TDbCommitHook);

    { --- motor durumu (Sprint 2.7) --- }
    { Commit edilmemis yazma var mi (Flush karari icin). }
    function GetDirty: Boolean;
    property Dirty: Boolean read GetDirty;
    { v3 tek yazar: karsilik yok (no-op). v2'de baska oturumun acik
      islemi bitene kadar bekler. }
    procedure WaitForeignTxn(ASessionId: Cardinal);
    { READ COMMITTED icin gorunurluk penceresini ilerletir. v3'te
      snapshot/MVCC yok: no-op. }
    procedure RefreshBatchSnapshot;
    { Veri dosyasinin tam yolu (goreli yollarin cozumu icin). }
    function GetFilePath: string;
    property FilePath: string read GetFilePath;

    { Satir icindeki tablo kimligini cozen fonksiyon (R-26 filtresi). }
    procedure SetRowTagFunc(AValue: TVDbRowTagFunc);

    { Sprint 3.1: dosya butunlugu denetimi. v2'de TVDb.Verify, v3'te
      sayfa motorunun tam taramasidir (CRC + freelist + heap + tasma).
      Report: tek satir ozet veya hata nedeni. }
    function Verify(out Report: string): Boolean;

    { Sprint 3.2: tutarli yedek (tek .odb) ve geri yukleme. Yedek, checkpoint
      sonrasi sayfa imajlarinin bayt-bayt kopyasidir; geri yukleme kaynak
      dosyayi atomik olarak yerine koyar ve eski dosyayi .bak birakir. }
    procedure BackupTo(const DestPath: string);
    procedure RestoreFrom(const SrcPath: string);

    { Sprint 3.3: VACUUM - canli kayitlari yeni, sikisik bir dosyaya yazar
      ve atomik olarak yerine koyar. Bos sayfalar/olu baytlar dosyadan
      gercekten dusulur. Eski dosya .bak kalir. }
    procedure Compact(out OldBytes, NewBytes: Int64);
  end;

implementation

end.
