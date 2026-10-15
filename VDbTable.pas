unit VDbTable;

{ V2 tablo katmani: VDb (UInt64->Bytes) ustunde tablo.
  key = FNV1a64(lower(table)+#0+pk)  (ust $FFFFFF0000000000 araligi ayrilmis, sema icin)
  value = [u16 tableId][u16 pkLen][pk][u16 colCount] + colCount kez: [u8 ctype][i32 vlen][vbytes]  (vlen=-1 => NULL)
  katalog tek dosyada: ayrilmis VDB_SCHEMA_KEY altinda KV kaydi olarak, fsync'li
  ctype: 0=int64, 1=float64, 2=str utf8, 3=bool
}

{$mode delphi}

interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections, VDbCore, VDbErr, VDbText, VDbTypes;

type
  // Use Pointer for TSqlSelectStmt parameters to avoid circular dependency with VDbAst
  // VDbText: F-18 ifade indeksi (LOWER/UPPER/LENGTH) - bagimsiz birim,
  // dongu riski yok (VDbText hicbir motor birimini kullanmaz).
  PDummy = ^Integer; // dummy to satisfy type section

const
  VCT_INT = 0;
  VCT_FLOAT = 1;
  VCT_STR = 2;
  VCT_BOOL = 3;
  VCT_DATE = 4;     // ISO yyyy-mm-dd metin
  VCT_DATETIME = 5; // ISO yyyy-mm-dd hh:nn:ss metin
  VCT_TIME = 6;     // ISO hh:nn:ss metin
  // Ã‡ok kolonlu indeks anahtarlarÄ±nÄ±n ayÄ±rÄ±cÄ±sÄ± (yalnÄ±zca bellekte)
  VDB_IDX_SEP = #1;
  VCT_BLOB = 7;     // ham byte
  // F2-12: ON DELETE/UPDATE CASCADE zinciri ozguc doner (Delete ->
  // CheckRestrict -> Delete -> ...). CYCLE varsa (a -> b -> a) sonsuza
  // kadar doner (yigin tasmasi + sinirsiz silme). Azami derinlik.
  VDB_MAX_CASCADE_DEPTH = 32;

  // Sema tek dosyada: katalog ayrilmis key altinde KV icinde durur.
  // 0 kullanilir cunku VDbHashKey asla 0 uretmez (bak: asagida).
  VDB_SCHEMA_KEY: QWord = 0;
  VDB_SCHEMA_TAG = 'VSCH1';



type
  TIdxDef = record
    Name: string;   // lower-case
    Col: Integer;   // TTableDef.Cols indexi (ILK kolon = Cols[0], geri uyum)
    Cols: array of Integer; // indeks kolonlari (cok kolonlu indeks)
    // F2-23: CREATE UNIQUE INDEX. Sema satirinda indeks adi "!" onekiyle
    // yazilir; eski kayitlarda onek yoksa UNIQUE degildir (geri uyum).
    Uniq: Boolean;
    // F-17: PARTIAL INDEX â€” "CREATE INDEX ix ON t(c) WHERE <kosul>".
    // Bos = normal indeks (tum satirlar). Dolu ise yalnizca kosulu
    // SAGLAYAN satirlar indekslenir. Sema satirinda hex(kosul metni)
    // olarak saklanir (ayirici '|' ile birlestirilir).
    Predicate: string;
    // F-18: EXPRESSION INDEX — "CREATE INDEX ix ON t(LOWER(ad))".
    // Bos = normal (kolon) indeks. Dolu ise indeks anahtari bu ifadenin
    // satir basina hesaplanan degeridir ve TIdxDef.Col gecersizdir (-1).
    // Sema satirinda '|' onekiyle hex(ifade metni) saklanir.
    ExprText: string;
    // F-19: COVERING INDEX — "CREATE INDEX ix ON t(a) INCLUDE (b, c)".
    // INCLUDE edilen kolonlar ANAHTAR DEGILDIR: siralamaya, aralık
    // taramasina ve UNIQUE denetimine girmez; yalnizca indeks girdisinin
    // icinde tasinir (index-only scan icin). Bos = covering degil.
    Incl: array of Integer;
    // R-22 Full: CREATE INDEX CONCURRENTLY. True = indeks HENUZ GECERLI
    // DEGIL: ya arka plan insasi suruyor ya da yarida kaldi (basarisiz
    // CONCURRENTLY insasi, PostgreSQL'deki gibi INVALID birakilir).
    // Okuma yollari (planlayici/unique/bakim) bu indeksi ATALAR; yazmalar
    // bekleyen islem olarak indeksi beslemeye DEVAM EDER (finalize'daki
    // catch-up kaynagi). Semada indeks adina '?' oneki olarak yazilir.
    Invalid: Boolean;
  end;
  TIdxEntry = record
    Key: string;    // kolon degeri (string form)
    Pk: string;
    // F-19: INCLUDE kolonlarinin degerleri (uzunluk-oneki kodlama, VDbIdxJoin
    // ile ayni). Anahtardan BAGIMSIZ: sorgu satiri indeksten okunabilir.
    Cov: string;
  end;
  TIdxEntries = array of TIdxEntry;
  // Bekleyen indeks islemi.
  //   Kind = 0 (VDBIKS_SET) : bu satir icin indeks anahtari artik Key'dir
  //   Kind = 1 (VDBIKS_DEL) : bu satir indeksden TAMAMEN kalkiyor
  //
  // ONCEDEN "IdxDel(eski) + IdxAdd(yeni)" FARKLARI kaydediliyordu; bu
  // bicimde flush, eski degerin dogru bilinmesine bagimli oluyordu ve
  // batch icinde bir satir arka arkaya guncellendiginde eski deger
  // bayat kalinca indeks BIR KAYIPTAN fazla (mukerrer) girdi birakiyordu.
  // Simdi her satir icin SADECE GUNCEL DURUM yaziliyor; islem sirasi ve
  // eski deger onemsiz hale gelir -> her (Pk) icin tam bir girdi garanti.
  TIdxOp = record
    Key: string;
    Pk: string;
    IsDel: Boolean;
    Cov: string;      // F-19: INCLUDE kolon degerleri
  end;
  TIdxOps = array of TIdxOp;
  // BIR IKINCI INDEKSIN BELLEK ICI TAMPONU
  //
  // TEMEL FIKIR: sirali diziye ARA DEGER eklemek O(n) kaydirma ister.
  // FPC dinamik dizilerinde SetLength(+1) de her seferinde tum diziyi
  // yeniden ayirir (amortize buyume YOK), yani "sonda ekle" bile O(n)
  // olur. 20000 satirlik indeksli tablo ~6.5 SANIYE suruyordu (O(n^2)).
  //
  // COZUM (tembel siralama):
  //   FMemIdx      : SIRALI ve COMMITLENMIS girisler (okuma icin)
  //   FIdxOps      : henuz uygulanmamis EKLEME/SILME islemleri, ISLEM
  //                  SIRASI KORUNARAK (TList -> amortize O(1))
  // Sirlama + islem uygulamasi TEK seferde, indeksin okunacagi tek noktada
  // (TryGetMemIndex) yapilir. Toplu yukleme O(N log N) olur; sorgu
  // sonucu BIT BIT ayni kalir.
  //
  // ONCEDEN eklemeler ve silmeler AYRI listelerde tutuluyordu; boylece
  // "islem sirasi" kayboluyordu ve ayni (deger, id) cifti icin MUKERRER
  // indeks girisi kalabiliyordu (indeksli ORDER BY/listede satir FAZLA
  // cikiyordu, sessizce). Artik TEK sirali islem listesi var ve Flush
  // "her (Key,Pk) icin SON islem ekleme mi silme mi" diye hesaplayip
  // her cift icin TAM OLARAK BIR giris birakir -> mukerrer imkansiz.
  TStrArray = array of string;
  TStrMatrix = array of TStrArray;
  TColArray = array of TColDef;
  // WHERE: OR'lanmis AND gruplari (DNF). OR yoksa tek grup.
  // UPDATE ... SET degeri.
  //   Kind = 0 : Duz deger (E.Lit)
  //   Kind = 1 : <kolon> Op <deger>   (Ã¶rn. n = n + 1)
  //   Kind = 2 : <kolon> Op <kolon>   (Ã¶rn. n = n - b)
  // Op: '+', '-', '*', '/', '%'
  TSetExpr = record
    Kind: Byte;
    ColA: Integer;   // sol taraf tablo kolonu
    ColB: Integer;   // sag taraf kolonu (-1 = degil)
    Op: Char;
    Lit: string;     // sag taraf sabiti
  end;
  TSetExprs = array of TSetExpr;
  // JOIN/WHERE cozumlemede tablo gorunumu (Base = birlesik satir ofseti)
  TTableRef = record
    Name: string;
    Alias: string;
    Cols: TColArray;
    Base: Integer;
  end;

  TTableDef = record
    TableId: Word;
    Name: string;   // lower-case
    Cols: TColArray;
    PkIndex: Integer;
    AutoInc: Int64; // pk int ise son deger
    Idx: array of TIdxDef;
    Fks: array of TFkDef;
    Checks: TWhereGroups; // CHECK kosullari (yapilandirilmis)
    IsView: Boolean;          // F-33: VIEW
    IsMaterializedView: Boolean; // F-34: MATERIALIZED VIEW
    SelectStmt: Pointer;      // F-33/F-34: SELECT ifade agaci (TSqlSelectStmt)
    SelectText: string;       // F-33/F-34: orijinal SELECT metni
  // R-15: Cost-Based Optimizer - istatistikler (analiz sonucu)
  FRowEstimate: Integer;    // tahmini satir sayisi (ANALYZE)
  FLastAnalyze: Int64;      // son ANALYZE zaman damgasi
  // R-13 Full: tablo bolme (partitioning) tanimi.
  // PartType: '' (bolunmemis) | 'HASH' | 'LIST' | 'RANGE'
  // PartCol : bolme anahtari kolon adi (lower-case)
  // PartVals: HASH -> [bolum sayisi]; LIST -> deger listesi (listede
  //           olmayan degerler DEFAULT bolumune duser); RANGE -> [min, max]
  //           (bolumler: 0=min alti, 1=aralik ici, 2=max ustu)
  PartType: string;
  PartCol: string;
  PartVals: array of string;
  end;

  { R-13 Full: partition pruning hedef kumesi. HasFilter=False ise filtre
    yok (butun satirlar taranir); Parts bos ise HICBIR bolum taranmaz
    (kosul hicbir bolume dusmez -> sonuc bos kume; WHERE zaten bos
    dondururdugu icin guvenlidir). }
  TPartTargets = record
    HasFilter: Boolean;
    Parts: TIntArray;
  end;

  { R-18: RBAC. Bir rolun tanimi. Super roller her seyi yapabilir;
    digerleri yalnizca kendilerine GRANT edilmis izinleri kullanir. }
  TRoleDef = record
    Name: string;      // lower-case
    Super: Boolean;    // SUPERUSER
  end;

  { R-18: tek bir izin kaydi. Tablo '*' ise TUM tablolar icin gecerlidir. }
  TGrantDef = record
    Table: string;     // lower-case, '*' = hepsi
    Priv: Byte;        // TPrivKind ordinal
    Role: string;      // lower-case
  end;

  { R-19: ROW LEVEL SECURITY politikasi. Politika ifadesi METIN olarak
    saklanir (sema kaliciligi icin); denetim aninda yeniden ayristirilir.
    Cmd TPrivKind DEGIL: R-19'un kendi enum'u TPolicyCmd'dir (0=ALL,
    1=SELECT, 2=INSERT, 3=UPDATE, 4=DELETE). }
  TPolicyDef = record
    Table: string;
    Name: string;
    Cmd: Byte;             // TPolicyCmd ordinal
    UsingText: string;     // bos = kisit yok
    CheckText: string;
  end;

  TVTableDb = class;   // R-22: ileri bildirim (builder tanimi icin)

  { R-22 Full: CREATE INDEX CONCURRENTLY — arka plan insa is parcacigi.
    Ana thread anlik goruntuden SIRALANMAMIS girdileri hazirlar (ScanRows
    + anahtar hesabi; sema cumle icinde sabittir). Bu thread yalnizca
    KENDI girdi dizisini SIRALAR: SortIdxEntries* yordamlari paylasilan
    hicbir nesne durumuna dokunmaz (yalniz parametre dizisi + saf
    karsilama islevleri) — bu yuzden thread'den cagrilari guvenlidir.
    Motoru hic kilitlemez: tablo insa sirasinda yazmaya ACIK kalir
    (online DDL). Sonuc finalize (PollConcurrentIndexes) ana thread'de
    kurulur. }
  TVdbConcIdxBuilder = class(TThread)
  private
    FOwner: TVTableDb;
    FEntries: TIdxEntries;   // giris: siralanmamis / cikis: sirali
    FCtypes: TByteArray;     // cok parcali karsilastirma tipleri (kopya)
    FSingleCt: Byte;         // tek kolonlu karsilastirma tipi
    FMulti: Boolean;         // True = SortIdxEntriesCols, False = SortIdxEntries
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TVTableDb; const E: TIdxEntries;
      const ACtypes: TByteArray; ASingleCt: Byte; AMulti: Boolean);
    { Siralanmis girdiler — yalniz Finished=True sonrasi okunur. }
    property Entries: TIdxEntries read FEntries;
  end;

  { R-22: kayit defteri girdisi — (tablo kimligi, indeks adi, is parcacigi).
    Finalize aninda tanim KONUMU yeniden cozulur (aradaki DropTable /
    DropIndex konumlari kaydirabilir); cozulemezse sonuc SILINIR.
    TableId yeniden yaratilan ayni adli tabloyla karismaz (yeni kimlik). }
  TVdbConcRec = record
    TableId: Word;
    IndexName: string;      // normallestirilmis (VDbNorm)
    Builder: TVdbConcIdxBuilder;
  end;

  TVTableDb = class
  private
    FKv: TVDb;
    // P3: kaba taneli kilit. TVSql.Exec/ExecAll cagrinin TAMAMI bu kilit
    // altinda calisir; ayni TVTableDb'yi paylasan tum thread'ler siralanir.
    // TCriticalSection recursive'tir: Exec -> ExecAll -> ExecRaw zinciri
    // ayni thread'de ic ice kilit alabilir (VDbCore'daki modelle ayni).
    // Dogrudan TVTableDb kullanan cok-thread'li kod Lock/Unlock ile sarmalimali.
    FLock: TCriticalSection;
    FDir: string;
    FTables: TDictionary<string, TTableDef>; // name -> def
    FById: TDictionary<Word, string>;
    FMemIdx: TDictionary<Int64, TIdxEntries>; // IdxKey -> SIRALI girisler
    FIdxOps: TDictionary<Int64, TList<TIdxOp>>;         // sirali bekleyen islemler
    FIdxCtype: TDictionary<Int64, Byte>;                // indeks kolon tipi
    FPkIdx: TDictionary<Word, TIdxEntries>;  // PK lazy index (tableId -> sorted)
    FPkIdxDirty: TDictionary<Word, Boolean>; // PK index kirli mi?
    FIdxUniq: TDictionary<Int64, TDictionary<string, string>>;
    // UNIQUE kolonlar icin "deger -> sahip pk" haritasi.
    //
    // NEDEN: CheckConstraints UNIQUE denetiminde indeksin SIRALI dizisini
    // kullaniyordu; diziyi okumak once FlushIdxPending'i tetikliyor ve
    // 20.000 satirlik toplu yazmada HER INSERT tam bir yeniden siralama
    // yapiyordu (27 ms/satir, 9 dakika). Bu harita nedensel olarak
    // guncellenir (O(1)) ve denetimi siralamaya BAGLAMAZ.
    // Yalniz UNIQUE kolonlar icin tutulur (bellek sinirli).
    FIdxDirty: TList<Int64>;                         // bekleyen degisikligi olan indeksler
    // R-22 Full: surmekte olan CONCURRENTLY insalari (kayit defteri).
    // Yalniz ANA thread erisir; is parcaciklari kendi dizileriyle ugrasir.
    FConcBuilders: TList<TVdbConcRec>;
    FSchemaDirty: Boolean;
  // F2-12: aktif FK kaskad zinciri derinligi (koruma sayaci)
  FCascadeDepth: Integer;
    FNextId: Word;
    FSnapActive: Boolean;          // batch basinda sema yedegi alindi mi
    FSnapTables: TDictionary<string, TTableDef>; // batch basindaki sema
    FSnapById: TDictionary<Word, string>;
    FSnapNextId: Word;
    FSnapDirty: Boolean;
    // F-35: kullanici tanimli fonksiyon/prosedur kataloglari.
    // DIKKAT: sema ile birlikte diske yazilmaz; oturum ici kayit.
    FFunctions: TDictionary<string, TFunctionDef>;
    FProcedures: TDictionary<string, TFunctionDef>;
    // F-36: trigger katalogu. Anahtar = tetikleyici adi; deger = TTriggerDef.
    // Ayni tablo icin birden fazla tetikleyici olabilir.
    FTriggers: TDictionary<string, TTriggerDef>;
    // R-11: DEFERRABLE kisitlar. FDeferred -> FK denetimi COMMIT'e kadar
    // ertelenir; FDeferredRows ertelenen (tablo, satir) ciftlerini tutar.
    FDeferred: Boolean;
    FDeferredRows: TList<string>;
    // ---- R-18: RBAC katalogu ----
    FRoles: TDictionary<string, TRoleDef>;   // rol adi -> tanim
    FGrants: TList<TGrantDef>;               // izin kayitlari
    FCurrentRole: string;                    // etkin rol ('' = belirtilmedi)
    // ---- R-19: ROW LEVEL SECURITY katalogu ----
    FRlsOn: TDictionary<string, Boolean>;    // tablo -> RLS acik mi
    FPolicies: TList<TPolicyDef>;            // politikalar
    // rol degistiginde yeniden dogrulama gerekebilir; INSERT/UPDATE/DELETE
    // icin ek olarak "hedef tablo" bilgisi gerekir.
    // R-11: VDb'ye verilen geri-cagirim. Metot adresi `procedure of
    // object` tipindedir; duz TProcedure'a dogrudan atanamaz.
    FCommitHook: procedure of object;
    // --- sema korumasi (schema clobber guard) ---
    // Sema TEK kayit olarak (key=0) durur: "son yazan kazanir". Sema
    // bir sekilde bos/eksik yuklenen bir oturum, kendi 1 tablosunu
    // yazarken diger tablolari kalici olarak siler. Bu gercekten oldu
    // (kisi + t tablolari "siparisler" ile ezildi). Yazma ONCESI diskteki
    // sema ile bellekteki tablo listesi karsilastirilir.
    FIntentDrop: TStrArray;    // DROP TABLE / RENAME ile kaldirilanlar
    procedure IntentDrop(const Name: string);
    function IntentHas(const Name: string): Boolean;
    procedure GuardSchemaLoss;
    function SchemaPath: string;
    procedure LoadSchema;
    procedure SaveSchema;
    procedure MarkSchema; // batchte isaretle, disiinda hemen yaz
    procedure SnapshotSchema;
    procedure RestoreSchemaSnapshot;
    procedure ClearSchemaSnapshot;
    function FindCol(const T: TTableDef; const Col: string): Integer;
    function MaxPkInt(const T: TTableDef): Int64;
    procedure CheckConstraints(const T: TTableDef; var Vals: TStrArray; const ExcludePk: string);
    function RefValueExists(const Rt: TTableDef; ColIdx: Integer; const V: string): Boolean;
    procedure CheckFk(const T: TTableDef; const Vals: TStrArray);
    // ---------- R-11: DEFERRABLE CONSTRAINTS ----------
    // `SET CONSTRAINTS ALL DEFERRED` sonrasi FK denetimi COMMIT'e kadar
    // ertelenir; boylece cocuk satiri ebeveyninden ONCE eklenebilir.
    // DIKKAT: yalniz REFERANS DOGRULAMASI (FK) ertelenir. PK/UNIQUE/NOT
    // NULL indeks ve satir butunlugu dogrudur; ertelenirlerse indeks
    // tutarsiz birakilir ve geri alinamaz, bu yuzden ANINDA denetlenir.
    procedure CheckDeferredNow;
  public
    // ---- R-18: RBAC ----
    // Roller ve izinler SEMA ile birlikte saklanir (katalog), boylece
    // veritabani dosyasi baska bir baglamda acildiginda yetkiler de
    // tasinir. Super olmayan motor kullanici (FCurrentRole = '') her
    // cumleyi calistirabilir: yetki sistemi ACIKCA devreye girer,
    // varsayilan olarak her sey serbest kalir.
    procedure CreateRole(const AName: string; ASuper: Boolean);
    procedure DropRole(const AName: string);
    function RoleExists(const AName: string): Boolean;
    procedure GrantPriv(const ATable: string; APriv: Byte; const ARole: string);
    procedure RevokePriv(const ATable: string; APriv: Byte; const ARole: string);
    procedure SetCurrentRole(const AName: string);
    property CurrentRole: string read FCurrentRole write FCurrentRole;
    function RoleCount: Integer;
    function GrantCount: Integer;
    // Ic denetim: rol verilen tablo uzerinde izne sahip mi?
    // Super rol veya rol belirtilmemesi durumunda TRUE doner.
    function RoleCan(const ATable: string; APriv: Byte): Boolean;
    // Dis denetim (executor): yetki yoksa hata firlatir.
    function PrivName(APriv: Byte): string;
    procedure RequirePriv(const ATable: string; APriv: Byte);
    // ---- R-19: ROW LEVEL SECURITY ----
    procedure SetRls(const ATable: string; AOn: Boolean);
    function RlsEnabled(const ATable: string): Boolean;
    procedure CreatePolicy(const ATable, AName: string; ACmd: Byte;
      const AUsing, ACheck: string);
    procedure DropPolicy(const ATable, AName: string);
    function PolicyCount: Integer;
    { Verilen tablo+komut icin gecerli USING kosullarini dondurur.
      Super rol / rol yoksa sonuc bos (RLS uygulanmaz). }
    function RlsUsing(const ATable: string; ACmd: Byte): TStrArray;
    { INSERT/UPDATE icin WITH CHECK kosullari. }
    function RlsCheck(const ATable: string; ACmd: Byte): TStrArray;
    function RlsApplies(const ATable: string): Boolean;
    procedure SetDeferred(AOn: Boolean);
    property Deferred: Boolean read FDeferred;
    function DeferrableFk(const T: TTableDef): Boolean;
  private
    procedure DoCheckDeferred;
    procedure CheckRestrict(const T: TTableDef; const ParentVals: TStrArray;
      const Mode, NewVal: string; const RefColFilter: Integer = -1);
    // FK CASCADE/SET NULL icin: satiri dogrudan yazar (kisit denetimi
    // uygulanmaz -- zaten gecerli bir deger).
    procedure PutRow(const T: TTableDef; const Pk: string; const Vals: TStrArray);
    // ON DELETE/ON UPDATE degistirilebilir mi? (ALTER ile degismez)
    procedure SetFkAction(const Table, Column, RefTable: string;
      const OnEvent, Action: string);
    function IdxKey(TableId: Word; ColIdx: Integer): Int64;
    function IdxKeyPos(const T: TTableDef; IdxPos: Integer): Int64;   // F-17
    function IdxKeyOfRow(const T: TTableDef; IdxPos: Integer;
      const Vals: TStrArray): string;                            // F-18
    function IdxCtypeOfPos(const T: TTableDef; IdxPos: Integer): Byte;  // F-18
    function IdxPosOfKey(const k: Int64): Integer;                    // F-17
    function IdxOpTag(const Pk: string): string;
    procedure DropIdxPend(const k: Int64);
    procedure FreeIdxUniqMaps;
    procedure FreeIdxPend;
    procedure FlushIdxPending(const k: Int64);
    function IdxTDefByKey(const k: Int64; out ColIdx: Integer): TTableDef;
    function IdxNPartsByKey(const k: Int64): Integer;
    function IdxCtypesByKey(const k: Int64): TByteArray;
    procedure SortIdxEntries(var E: TIdxEntries; Ctype: Byte);
    function IdxLowerBound(const E: TIdxEntries; Ctype: Byte; const Key, Pk: string): Integer;
    procedure IdxAdd(TableId: Word; ColIdx: Integer; const Key, Pk: string; Ctype: Byte);
    procedure IdxDel(TableId: Word; ColIdx: Integer; const Key, Pk: string; Ctype: Byte);
    // R-22 Full: CONCURRENTLY insa zinciri — anlik goruntu girdileri,
    // tanim cozumu, insa baslatma ve iptal etme.
    procedure BuildIdxEntries(const T: TTableDef; IdxPos: Integer;
      out E: TIdxEntries; out Ctypes: TByteArray; out KeyCt: Byte);
    function FindIdxDefById(ATableId: Word; const AIndexName: string;
      out t: TTableDef; out IdxPos: Integer): Boolean;
    procedure StartConcBuild(const t: TTableDef; IdxPos: Integer);
    procedure StopConcBuilders(const AIndexName: string = '');
    procedure BuildOneIndex(const T: TTableDef; IdxPos: Integer);
    function IdxColsOf(const T: TTableDef; IdxPos: Integer): TIntArray;
    // F2-11: IdxPos konumundaki indeks ColIdx kolonunu iceriyor mu?
    // (cok kolonlu indeksler icin Col listesine de bakar)
    function IdxHasCol(const T: TTableDef; IdxPos, ColIdx: Integer): Boolean;
    function IdxCtypesOf(const T: TTableDef; IdxPos: Integer): TByteArray;
    procedure SortIdxEntriesCols(var E: TIdxEntries; const Ctypes: TByteArray);
    procedure IdxAddRow(const T: TTableDef; const Vals: TStrArray;
      const Pk: string; const OnlyPos: Integer);
    procedure IdxDelRow(const T: TTableDef; const Vals: TStrArray;
      const Pk: string; const OnlyPos: Integer);
    procedure BuildPkIdx(const T: TTableDef; out E: TIdxEntries);
    // Satirin TUM indekslerine ait anahtarlarini hesaplar (cok kolonlu destek)
    procedure IdxKeysOfRow(const T: TTableDef; const Vals: TStrArray;
      out Keys: TStrArray);
  public
    constructor Create(AKv: TVDb);
    destructor Destroy; override;
    procedure Open(const Dir: string);
    procedure Close;
    // ddl/dml
    procedure CreateTable(const Name: string; const Cols: TColArray; PkIndex: Integer;
      const Checks: TWhereGroups; const Fks: array of TFkDef;
      const PartitionType: string = ''; const PartitionCol: string = '';
      const PartitionValues: TStringList = nil);
    procedure DropTable(const Name: string);
    // ALTER TABLE: sema degisikligi, satirlar yeniden kodlanir.
    // Satirlar tek tek okunup yeni semayla yeniden yazilir (append-only
    // motor oldugu icin eski surumler olu olur; AutoCompact temizler).
    // DDL geri alinabilsin diye batch varsa ic ice batch ACILMAZ.
    procedure AlterAddColumn(const Table: string; const Col: TColDef;
      const After: string; const HasDef: Boolean; const DefVal: string);
    procedure AlterDropColumn(const Table, Column: string);
    procedure AlterRenameColumn(const Table, OldName, NewName: string);
    procedure AlterColumnType(const Table, Column, NewType: string);
    procedure AlterSetDefault(const Table, Column: string;
      const HasDef: Boolean; const DefVal: string);
    procedure AlterDropDefault(const Table, Column: string);
    procedure AlterSetNotNull(const Table, Column: string; const On: Boolean);
    procedure AlterRenameTable(const OldName, NewName: string);
    // NOT: index ekleme/kaldirma icin CreateIndex/DropIndex kullanilir
    // (SQL'de zaten CREATE/DROP INDEX olarak var).
    // Semayi degistirip tum satirlari yeniden kodlar. asmap: yeni sema
    // her sutunu icin kaynak kolon indeksi (-1 = yeni). Sonra index/CHK/FK
    // yeniden kurulur.
    procedure RewriteTable(const T: TTableDef; const asmap: TIntArray);
    procedure RewriteTableRows(const T: TTableDef; const asmap: TIntArray;
      const Pks: TStrArray; const Rows: TStrMatrix);
    procedure FixCheckCols(var T: TTableDef; const asmap: TIntArray);
    procedure CloneDef(const Src: TTableDef; out Dst: TTableDef);
    function SqlTypeToCtype(const S: string): Byte;
    procedure BeginBatch;
    procedure CommitBatch;
    procedure AbortBatch; // FKv abort + index onarimi
    // P3: paylasilan ornegi dogrudan kullanan thread'ler icin genel kilit.
    // TVSql uzerinden calisanlar icin Exec/ExecAll zaten kilit alir.
    procedure Lock;
    procedure Unlock;
    function TableExists(const Name: string): Boolean;
    function GetTable(const Name: string): TTableDef;
    function TableNames: TStrArray;
    // 2026-10-05 CDC: dis dunyadan satir cozumu + id->tablo adi
    // (VDbCdc bu ikisini ister; DecodeRow implementation icindedir)
    function DecodeRowDataPublic(const B: TBytes; out TableId: Word;
      out Pk: string; out Vals: TStrArray): Boolean;
    function GetTableNameById(AId: Word): string;
    // satir: values[] string formda, tip donusumu burada
    procedure Insert(const Table: string; const ColNames, StrVals: array of string);
    // COKMULU ekleme (tek atomik batch): Values satirlari = VALUES gruplari.
    procedure BatchInsert(const Table: string; const ColNames: array of string;
      const Rows: array of TStrArray);
    function Delete(const Table: string; const Pk: string): Boolean; overload;
    function DeleteWhere(const Table: string; const Groups: TWhereGroups): Integer;
    function ReadRow(const Table: string; const Pk: string; out Vals: TStrArray): Boolean;
    // DELETE/UPDATE icin WHERE'i tam tarama yapmadan daraltmayi dener:
    // PK nokta aramasi (O(1)) veya indeks dilimi. False -> tam tarama.
    function CandidatePks(const T: TTableDef; const Groups: TWhereGroups;
      out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
    function ScanRows(const Table: string; out Pks: TStrArray; out Rows: TStrMatrix): Integer;
    // R-13 Full: bolme filtreli tarama (partition pruning). Hedef kumesi
    // DISINDAKI satirlar hic materialize edilmez; sonuc kumesi degismez
    // (WHERE tum aday satirlarda yeniden dogrulanir - ust kume garantisi).
    function ScanRowsPart(const Table: string; out Pks: TStrArray;
      out Rows: TStrMatrix; const Targets: TPartTargets): Integer;
    // R-13 Full: bolme anahtari DEGERININ dusecegi bolum (-1 = hesaplanamadi)
    function PartValueOf(const T: TTableDef; const Val: string): Integer;
    // R-13 Full: satirin bolum numarasi (-1 = bolunmemis/cozulemedi)
    function PartRowOf(const T: TTableDef; const Row: TStrArray): Integer;
    // R-13 Full: toplam bolum sayisi (0 = bolunmemis)
    function PartCountOf(const T: TTableDef): Integer;
    // R-13 Full: bolum etiketi (SHOW PARTITIONS ciktisi icin)
    function PartLabelOf(const T: TTableDef; PartNo: Integer): string;
    function UpdateWhere(const Table: string; const SetCols: array of string;
      const SetExprs: TSetExprs; const Groups: TWhereGroups): Integer;
    // Tek satiri YERINDE gunceller (sil+insert YAPMAZ).
    // UpdateWhere ve SQL katmani (ExecUpdate) bunu paylasir; boylece
    // ON DELETE CASCADE / RESTRICT mantigi tek yerde ve dogru yerde calisir.
    // (F1-4: SQL UPDATE once Delete+Insert yapiyordu; ilgisiz kolon
    //  degisikligi bile cocuk satirlari ON DELETE CASCADE ile siliyordu.)
    // False donerse satir bulunamadi (hicbir sey yazilmadi).
    function UpdateRowInPlace(const Table: string; const Pk: string;
      const SrcVals: TStrArray): Boolean;
    // UPDATE SET ifadesini SATIR BASINA hesaplar.
    function EvalSetExpr(const T: TTableDef; const E: TSetExpr;
      const Old: TStrArray; const ColName: string): string;
    function DataKeyCount: Integer; // sema kaydi haric veri sayisi
    // secondary index (bellek-ici, veriden turetilir; crash-safe)
    procedure CreateIndex(const Table, IndexName, Col: string);
    procedure CreateIndexCols(const Table, IndexName: string; const Cols: TStrArray;
  Unique: Boolean = False; const Predicate: string = '';
  const ExprText: string = ''; const Incl: TStrArray = nil;
  Concurrent: Boolean = False);   // F2-23, F-17, F-18, F-19, R-22 Full
    procedure DropIndex(const IndexName: string);
    // R-22 Full: bitmis CONCURRENTLY insalarini finalize eder (sonraki
    // cumleler cagririr; AForce=True bekleyen insalari da bitirir —
    // ALTER COLUMN TYPE gibi "onceden temiz baslangic" gereken yerlerde).
    procedure PollConcurrentIndexes(AForce: Boolean = False);
    // R-22: surmekte olan CONCURRENTLY insa sayisi (test/gozlem).
    function ConcIdxBuildersActive: Integer;
    function IndexNames(const Table: string): TStrArray;
    function TryGetMemIndex(TableId: Word; ColIdx: Integer; out Entries: TIdxEntries): Boolean;
    function IdxNParts(TableId: Word; ColIdx: Integer): Integer;
    function IdxPosOfName(const Table, IdxName: string): Integer;      // F-19
function IdxEntryCount(TableId: Word; IdxPos: Integer): Integer;      // F-17
    function IdxPosOfCol(TableId: Word; ColIdx: Integer): Integer;   // F-19
    function IdxCoversAll(const Td: TTableDef; IdxPos: Integer): Boolean;  // F-19
    function ReadRowCovered(const Td: TTableDef; IdxPos: Integer;
      const Entry: TIdxEntry; out Vals: TStrArray): Boolean;         // F-19
function IdxColsOfPosTable(TableId: Word; IdxPos: Integer): TIntArray;  // F-17
function IdxColsOfTable(TableId: Word; ColIdx: Integer): TIntArray;
    // Tum bellek indekslerini veriden yeniden kurar (SQL: REINDEX)
    procedure RebuildIndexes;
    // F-33: VIEW
    procedure CreateView(const ViewName: string; const SelectStmt: Pointer;
      const SelectText: string; const IfNotExists: Boolean);
    function ViewExists(const Name: string): Boolean;
    procedure DropView(const ViewName: string; const IfExists: Boolean);
    // F-34: MATERIALIZED VIEW
    procedure CreateMaterializedView(const ViewName: string; const SelectStmt: Pointer;
      const SelectText: string; const IfNotExists: Boolean);
    function MaterializedViewExists(const Name: string): Boolean;
    procedure DropMaterializedView(const ViewName: string; const IfExists: Boolean);
    // F-34: SELECT sonucunu MV tablosuna yazan yardimcilar (executor cagirir)
    procedure AddMaterializedViewColumn(const ViewName, ColName: string);
    procedure InsertMaterializedViewRow(const ViewName: string; const StrVals: TStrArray);
    procedure ClearMaterializedView(const ViewName: string);
    procedure ResetMaterializedView(const ViewName: string);
    function MaterializedViewColCount(const ViewName: string): Integer;
    function GetMaterializedViewSelect(const ViewName: string): Pointer;
    // DIKKAT: SelectStmt POINTER olarak saklanir ve AST Free edilince
    // dangling pointer olur. REFRESH bu yuzden SelectText METNINI kullanir.
    function GetMaterializedViewSelectText(const ViewName: string): string;
    function ScanMaterializedView(const ViewName: string;
      out Pks: TStrArray; out Rows: TStrMatrix): Integer;
    // F-33: view/tablo tanimini hata vermeden al
    function TryGetTableDef(const Name: string; out Td: TTableDef): Boolean;
    procedure RefreshMaterializedView(const ViewName: string; const Concurrently: Boolean);
    // F-35: STORED PROCEDURE
    // DIKKAT: imza asagida F-35 bolumunde TEKRAR bildirilir; eski
    // "const Args: TObject" bildirimi kaldirildi (forward declaration
    // not solved hatasi veriyordu).
    // RETURNING support (stubs)
    function InsertReturning(const Table: string; const ColNames, Values: TStrArray;
      out OutPk: string; out OutVals: TStrArray): Boolean;
    function UpsertRowReturning(const Table: string; const ColNames, Values: TStrArray;
      const OnConflictAction: TOnConflictAction;
      const OnConflictTarget: TStrArray;
      const SetValues: TSetValuePairs;
      out OutPk: string; out OutVals: TStrArray): Boolean;
    // F-35: User-defined function / procedure support
    function FunctionExists(const FuncName: string): Boolean;
    function ExecuteFunction(const FuncName: string; const Args: TStrArray): string;
    procedure CreateFunction(const FuncName: string;
      const Params: array of TFunctionParameter; const ReturnType: string;
      const Language, Body: string; const IfNotExists: Boolean);
    procedure DropFunction(const FuncName: string; const IfExists: Boolean);
    function ProcedureExists(const ProcName: string): Boolean;
    // F-35: govde AST'si katalogda SAKLANIR (CREATE cumlesi bitince AST
    // Free edilir; govde pointer'i olsaydi dangling pointer olurdu).
    // Sahiplik katalogdadir: Drop* ve Close serbest birakir.
    function GetFunctionDef(const Name: string; out Def: TFunctionDef): Boolean;
    function GetProcedureDef(const Name: string; out Def: TFunctionDef): Boolean;
    procedure SetFunctionBody(const Name: string; ABody: TObject);
    procedure SetProcedureBody(const Name: string; ABody: TObject);
    procedure CreateProcedure(const ProcName: string;
      const Params: array of TFunctionParameter; const Language,
      Body: string; const IfNotExists: Boolean);
    procedure DropProcedure(const ProcName: string; const IfExists: Boolean);
    { ---------- F-36 TRIGGER KATALOGU ----------
      Govde ve WHEN ifadesi AST (TSqlStmtNode/TSqlExprNode) olarak
      saklanir ve katalog TARAFINDAN SAHPLENILIR. Bu yuzden
      CreateTrigger'a verilen govdeyi cagiran AST'den TSqlStmtNode
      pointer'ini nil'lemesi gerekir. }
    procedure CreateTrigger(const TrgName, TableName: string;
      const Events: array of Byte; Timing, ForEach: Byte;
      const IfNotExists: Boolean);
    procedure SetTriggerDef(const TrgName: string; const WhenCond,
      Body: TObject);
    procedure DropTrigger(const TrgName: string; const IfExists: Boolean);
    function TriggerExists(const TrgName: string): Boolean;
    function GetTriggerDef(const TrgName: string; out Def: TTriggerDef): Boolean;
    // Tablo + zamanlama + olay verilen TUM tetikleyiciler (adi sirali).
    // Tetikleyici yoksa bos dizi doner (cagiran Free ETMEZ).
    function TriggersFor(const TableName: string; Timing, Ev: Byte): TStrArray;
    // Tabloyu silmeden ONCE bagli tetikleyicileri de kaldirir; aksi
    // halde yalniz tabloya sahip, tetikleyicisiz (orphan) kayit kalir.
    procedure FreeAllTriggers;
    procedure DropTriggersOfTable(const TableName: string);
    procedure ClearTriggers;
    procedure CallProcedure(const ProcName: string; const Args: TStrArray;
      out Results: TStrArray);
    // F-33: view taniminin SELECT METNI (AST katalogda saklanmaz;
    // CREATE bitince Free edilir -> dangling pointer olur).
    function ViewSelectText(const ViewName: string): string;
    function IsView(const Name: string): Boolean;
    property Kv: TVDb read FKv;
  end;

const
  // FK referans aksiyonlari
  VDB_FK_RESTRICT = 'RESTRICT';
  VDB_FK_CASCADE = 'CASCADE';
  VDB_FK_SETNULL = 'SETNULL';
  VDB_FK_SETDEFAULT = 'SETDEFAULT';


  // --- Yardimci fonksiyonlar (AST ve diger birimler icin) ---
{function VDbNorm(const S: string): string;
function VDbFloatToStr(V: Double): string;
function VDbParseInt(const S: string; out V: Int64): Boolean;
function VDbParseFloat(const S: string; out V: Double): Boolean;
function VDbNormValue(Ctype: Byte; const S: string): string; }

function VDbHashKey(const Table, Pk: string): QWord;
function VDbNorm(const S: string): string;
// FK aksiyonu adi -> kanonik bicim. Gecersizse exception.
function VDbFkAction(const S: string): string;
function VDbParseInt(const S: string; out V: Int64): Boolean;
function VDbParseFloat(const S: string; out V: Double): Boolean;
function VDbFloatToStr(V: Double): string;
// Tip dogrula; tarih/saatleri ISO'ya normallestirir (bos = NULL gecer).
function VDbNormValue(Ctype: Byte; const S: string): string;
function VDbHex(const S: RawByteString): string;
function VDbUnhex(const S: string): RawByteString;
function VDbLikeMatch(const Txt, Pat: string): Boolean;
function VDbIsNumericCol(Ctype: Byte): Boolean;
function VDbCmpVal(const A, B, Op: string; Ctype: Byte): Boolean;
// Tek bir TWhereCond'u degerlendirir: = <> != < > <= >= LIKE NOTLIKE
// ISNULL ISNOTNULL IN NOTIN BETWEEN NOTBETWEEN
function VDbMatchCond(const V: string; const C: TWhereCond): Boolean;
function VDbMatchGroups(const Vals: TStrArray; const Groups: TWhereGroups): Boolean;
// ---- COK KOLONLU INDEKS YARDIMCILARI ----
// Anahtarlar VDB_IDX_SEP (#1) ile birlestirilir. Anahtar yalnizca bellekte
// tutulur (diskte degil); parcalara ayirmak karsilastirma sirasinda olur.
function VDbIdxPartOf(const A: string; Part: Integer): string;
function VDbIdxPartCmp(const A, B: string; Part: Integer; Ctype: Byte): Integer;
function VDbIdxMultiCmp(const A, B: string; const Ctypes: TByteArray): Integer;
function VDbIdxJoin(const Vals: TStrArray; const Cols: TIntArray): string;
function VDbPredOK(const Predicate: string; const Vals: TStrArray;
  const Cols: array of TColDef): Boolean;   // F-17: partial index kosulu
function VDbExprVal(const Expr: string; const Vals: TStrArray;
  const Cols: array of TColDef; out Val: string; out ACtype: Byte): Boolean; // F-18
function VDbIdxCmpMulti(const A, B: string; Ctype: Byte;
  NParts: Integer): Integer;
// CHECK icin UC DEGERLI mantik: kosul FALSE ise ihlal, TRUE veya
// BILINMEZ(NULL) ise gecer. WHERE ile ayni degildir -- WHERE'da
// bilinmez "eslesmez" sayilir, CHECK'te "ihlal" sayilmaz.
function VDbCheckOK(const Vals: TStrArray; const Groups: TWhereGroups): Boolean;
procedure VDbSortStrs(var A: TStrArray);   // karsilastirmali (byte) siralama
// SQL tip adi -> VCT_* (ALTER COLUMN icin; VDbSql.ColTypeOf ile ayni kural)
function VDbTypeFromName(const S: string): Byte;
// Index siralama: NULL('') en kucuk; sayisal kolonda sayisal karsilastirma.
function VDbIdxCmp(const A, B: string; Ctype: Byte): Integer;
// Op (=,>,>=,<,<=) icin [Lo,Hi) dilimi; dilimlenemezse False (ÃƒÂ¶rn. <>, LIKE).
function VDbIdxRange(const E: TIdxEntries; Ctype: Byte; const Op, Val: string;
  out Lo, Hi: Integer): Boolean;
// COK KOLONLU indekslerde ayni sey, ama yalniz ILK KOLONA gore.
// NParts = 1 ise VDbIdxRange ile birebir ayni sonucu verir.
function VDbIdxRangeL(const E: TIdxEntries; Ctype: Byte; const Op, Val: string;
  NParts: Integer; out Lo, Hi: Integer): Boolean;
function VDbIdxRangeLK(const E: TIdxEntries; Ctype: Byte; const Op, EncodedKey: string;
  NParts: Integer; out Lo, Hi: Integer): Boolean;
function VDbIdxProbe1(const Val: string): string;
// 2026-10-04: Ctype -> SQL tip adi (sema sorgulari icin).
// VDbTypeFromName'in tersidir; semayi SQL'e cevirirken kullanilir.
function VDbTypeName(Ctype: Byte): string;
// 2026-10-04: VDB_FK_* kanonik degeri -> SQL metni (sema sorgulari).
function VDbFkActionToStr(const A: string): string;

{ R-22 Full: TEST KANCASI — CONCURRENTLY insa kapisi. Kapatilinca yeni
  baslayan insalar siralamadan once kapida bekler; test bu pencerede
  yazma yaparak "online" davranisi DETERMINISTIK dogrular. Kapinin
  unutulmasi kilitlenme yaratmaz: StopConcBuilders ve AForce'lu poll
  kapıyı acar. Uretim kodu hic kapatmaz. }
procedure VdbSetConcIdxGate(AClosed: Boolean);
function VdbConcIdxGateClosed: Boolean;

implementation

uses
  VDbSync;

{ ==================== R-22 Full: CONCURRENTLY insa altyapisi ==================== }

var
  // R-22: insa kapisi (test kancasi; varsayilan ACIK).
  GVdbConcGateClosed: Boolean = False;

procedure VdbSetConcIdxGate(AClosed: Boolean);
begin
  GVdbConcGateClosed := AClosed;
end;

function VdbConcIdxGateClosed: Boolean;
begin
  Result := GVdbConcGateClosed;
end;

constructor TVdbConcIdxBuilder.Create(AOwner: TVTableDb;
  const E: TIdxEntries; const ACtypes: TByteArray; ASingleCt: Byte;
  AMulti: Boolean);
begin
  { DIKKAT: FPC'de Create(False) thread'i ANINDA baslatir; tum alanlar
  inherited'ten ONCE atanmalidir (R-17 deseninin aynisi). }
  FOwner := AOwner;
  FEntries := E;                    // dizi referansi devralinir (cagiran kullanmaz)
  FCtypes := ACtypes;
  FSingleCt := ASingleCt;
  FMulti := AMulti;
  FreeOnTerminate := False;         // kayit defteri yonetir
  inherited Create(False);
end;

procedure TVdbConcIdxBuilder.Execute;
begin
  // TEST KANCASI: kapali kapida bekle — insa penceresi. Terminate buradan
  // cikar (StopConcBuilders / DropIndex kilitlenmez).
  while GVdbConcGateClosed and (not Terminated) do
    Sleep(5);
  if Terminated then Exit;
  // SIRALA: yalnizca KENDI dizisine dokunulur. SortIdxEntries*
  // yordamlari TVTableDb'nin paylasilan hicbir ALANINA dokunmaz (saf
  // parametre siralamasi) — bu yuzden baska bir thread'den cagri
  // guvenlidir. Motor bu sirada yazmaya acik kalir.
  if FMulti then
    FOwner.SortIdxEntriesCols(FEntries, FCtypes)
  else
    FOwner.SortIdxEntries(FEntries, FSingleCt);
end;

function VDbS2B(const S: RawByteString): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function VDbB2S(const B: TBytes; Pos, Len: Integer): RawByteString;
begin
  SetLength(Result, Len);
  if Len > 0 then Move(B[Pos], Result[1], Len);
end;

function VDbNorm(const S: string): string;
begin
  Result := LowerCase(Trim(S));
end;

function VDbHashKey(const Table, Pk: string): QWord;
var
  h: QWord;
  s: RawByteString;
  i: Integer;
begin
  s := UTF8Encode(VDbNorm(Table) + #0 + Pk);
  h := QWord($CBF29CE484222325);
  for i := 1 to Length(s) do
  begin
    h := h xor Byte(s[i]);
    h := h * QWord($100000001B3);
  end;
  if h = 0 then h := 1;
  Result := h;
end;

function VDbParseInt(const S: string; out V: Int64): Boolean;
begin
  Result := TryStrToInt64(Trim(S), V);
end;

function VDbParseFloat(const S: string; out V: Double): Boolean;
var
  pfs: TFormatSettings;
begin
  pfs := DefaultFormatSettings;
  pfs.DecimalSeparator := '.';
  Result := TryStrToFloat(Trim(S), V, pfs);
  if not Result then Result := TryStrToFloat(Trim(S), V);
end;

function VDbLikeMatch(const Txt, Pat: string): Boolean;
var
  ti, pi: Integer;
  star, mark: Integer;
begin
  ti := 1; pi := 1; star := 0; mark := 0;
  while ti <= Length(Txt) do
  begin
    if (pi <= Length(Pat)) and ((Pat[pi] = '_') or (Pat[pi] = Txt[ti])) then begin Inc(ti); Inc(pi); end
    else if (pi <= Length(Pat)) and (Pat[pi] = '%') then begin star := pi; mark := ti; Inc(pi); end
    else if star <> 0 then begin pi := star + 1; Inc(mark); ti := mark; end
    else Exit(False);
  end;
  while (pi <= Length(Pat)) and (Pat[pi] = '%') do Inc(pi);
  Result := pi > Length(Pat);
end;

function VDbIsNumericCol(Ctype: Byte): Boolean;
begin
  Result := (Ctype = VCT_INT) or (Ctype = VCT_FLOAT);
end;


function VDbCmpVal(const A, B, Op: string; Ctype: Byte): Boolean;
// Tip-bilgili karsilastirma. ONEMLI: sayisalla lastirme sadece sayisal
// kolonlarda yapilir. Aksi halde TEXT kolonda '007' = '7' olurdu.
// NULL (bos) degerler: IS NULL disinda hicbir karsilastirmada eslesmez.
var
  af, bf: Double;
  an, bn: Boolean;
  o: string;
  numeric: Boolean;
begin
  o := UpperCase(Op);
  numeric := VDbIsNumericCol(Ctype);
  // IS NULL / IS NOT NULL -> parser bunu ozel operatora cevirir;
  // NULL'a izin veren tek operatorler bunlar.
  if o = 'ISNULL' then Exit(A = '');
  if o = 'ISNOTNULL' then Exit(A <> '');
  // NULL degeri SQL'de BILINMEZDIR (unknown): hicbir operatorde eslesmez.
  // Bu kontrol LIKE'dan ONCE gelmeli; aksi halde "NULL LIKE '%'" true
  // doner ve NULL satirlar filtreye girer.
  if (A = '') or (B = '') then Exit(False);
  if o = 'LIKE' then Exit(VDbLikeMatch(A, B));
  if numeric then
  begin
    an := VDbParseFloat(A, af);
    bn := VDbParseFloat(B, bf);
    if an and bn then
    begin
      if o = '=' then Exit(af = bf);
      if (o = '<>') or (o = '!=') then Exit(af <> bf);
      if o = '>' then Exit(af > bf);
      if o = '<' then Exit(af < bf);
      if o = '>=' then Exit(af >= bf);
      if o = '<=' then Exit(af <= bf);
    end;
  end;
  // metin (veya sayisalla lastirilamayan) karsilastirma: bayt duzeni
  if o = '=' then Exit(A = B);
  if (o = '<>') or (o = '!=') then Exit(A <> B);
  if o = '>' then Exit(A > B);
  if o = '<' then Exit(A < B);
  if o = '>=' then Exit(A >= B);
  if o = '<=' then Exit(A <= B);
  Result := False;
end;

function VDbFkAction(const S: string): string;
// "CASCADE" / "SET NULL" / "SET DEFAULT" / "NO ACTION" / "RESTRICT"
// yazimlarini kanonik VDB_FK_* degerine indirger.
var
  u: string;
begin
  u := UpperCase(Trim(S));
  u := StringReplace(u, ' ', '', [rfReplaceAll]);
  if u = 'CASCADE' then Exit(VDB_FK_CASCADE);
  if (u = 'SETNULL') or (u = 'NULL') then Exit(VDB_FK_SETNULL);
  if (u = 'SETDEFAULT') or (u = 'DEFAULT') then Exit(VDB_FK_SETDEFAULT);
  if (u = 'RESTRICT') or (u = 'NOACTION') or (u = '') then Exit(VDB_FK_RESTRICT);
  raise EVDbException.Create(ecSyntaxError, 'bilinmeyen FK aksiyonu: ' + S +
    ' (CASCADE | SET NULL | SET DEFAULT | RESTRICT | NO ACTION)');
end;

procedure VDbSortStrs(var A: TStrArray);
// Basit insertion sort: katalog tablo sayisi kucuk (<1000).
var
  i, j: Integer;
  tp: string;
begin
  for i := 1 to High(A) do
  begin
    tp := A[i];
    j := i - 1;
    while (j >= 0) and (CompareStr(A[j], tp) > 0) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := tp;
  end;
end;

function VDbTypeFromName(const S: string): Byte;
var
  u: string;
begin
  u := UpperCase(Trim(S));
  if (u = 'INTEGER') or (u = 'INT') or (u = 'BIGINT') or (u = 'SMALLINT') then Exit(VCT_INT);
  if (u = 'FLOAT') or (u = 'DOUBLE') or (u = 'REAL') or (u = 'DECIMAL') or
     (u = 'NUMERIC') then Exit(VCT_FLOAT);
  if (u = 'BOOL') or (u = 'BOOLEAN') then Exit(VCT_BOOL);
  if u = 'DATE' then Exit(VCT_DATE);
  if (u = 'DATETIME') or (u = 'TIMESTAMP') then Exit(VCT_DATETIME);
  if u = 'TIME' then Exit(VCT_TIME);
  if (u = 'BLOB') or (u = 'BINARY') then Exit(VCT_BLOB);
  Result := VCT_STR; // TEXT / VARCHAR / STRING
end;

function VDbMatchCond(const V: string; const C: TWhereCond): Boolean;
// Tek kosul degerlendirici. IN / NOT IN / BETWEEN / NOT BETWEEN /
// NOT LIKE destekler. NULL tarafi bilesik deger: WHERE'de ESLESMEZ.
var
  o: string;
  i: Integer;
  found, anyNull: Boolean;
  hi: string;
begin
  o := UpperCase(C.Op);
  if o = 'ISNULL' then Exit(V = '');
  if o = 'ISNOTNULL' then Exit(V <> '');
  if o = 'NOTLIKE' then
  begin
    if (V = '') or (C.Val = '') then Exit(False);
    Exit(not VDbLikeMatch(V, C.Val));
  end;
  if o = 'IN' then
  begin
    if V = '' then Exit(False);
    anyNull := False;
    for i := 0 to High(C.Vals) do
    begin
      if C.Vals[i] = '' then begin anyNull := True; Continue; end;
      if VDbCmpVal(V, C.Vals[i], '=', C.Ctype) then Exit(True);
    end;
    // NULL tarafi bilesik deger -> WHERE'de eslesmez
    Result := False;
    Exit;
  end;
  if o = 'NOTIN' then
  begin
    if V = '' then Exit(False);
    found := False;
    anyNull := False;
    for i := 0 to High(C.Vals) do
    begin
      if C.Vals[i] = '' then begin anyNull := True; Continue; end;
      if VDbCmpVal(V, C.Vals[i], '=', C.Ctype) then
      begin found := True; Break; end;
    end;
    // eslesme varsa false; NULL tarafi varsa da bilinmez -> false
    Result := (not found) and (not anyNull);
    Exit;
  end;
  if (o = 'BETWEEN') or (o = 'NOTBETWEEN') then
  begin
    // C.Val = alt sinir, C.Vals[0] = ust sinir
    if Length(C.Vals) = 0 then Exit(False);
    hi := C.Vals[0];
    if (V = '') or (C.Val = '') or (hi = '') then Exit(False);
    Result := VDbCmpVal(V, C.Val, '>=', C.Ctype) and
              VDbCmpVal(V, hi, '<=', C.Ctype);
    if o = 'NOTBETWEEN' then Result := not Result;
    Exit;
  end;
  Result := VDbCmpVal(V, C.Val, C.Op, C.Ctype);
end;

function VDbMatchGroups(const Vals: TStrArray; const Groups: TWhereGroups): Boolean;
var
  g, c: Integer;
  ok: Boolean;
begin
  // WHERE yoksa (bos) eslesir
  if Length(Groups) = 0 then Exit(True);
  for g := 0 to High(Groups) do
  begin
    ok := True;
    for c := 0 to High(Groups[g]) do
    begin
      if (Groups[g][c].Col < 0) or (Groups[g][c].Col >= Length(Vals)) then
      begin ok := False; Break; end;
      if not VDbMatchCond(Vals[Groups[g][c].Col], Groups[g][c]) then
      begin ok := False; Break; end;
    end;
    if ok then Exit(True);
  end;
  Result := False;
end;

function VDbCondTri(const V: string; const C: TWhereCond): Integer;
// Tek kosulu uc-degerli degerlendirir: -1 FALSE, 0 BILINMEZ, +1 TRUE.
// IN/NOTIN/BETWEEN/NOTBETWEEN/NOTLIKE dahil.
var
  o: string;
  i: Integer;
  t: Integer;
  anyNull: Boolean;
begin
  o := UpperCase(C.Op);
  if o = 'ISNULL' then Exit(Ord(V = '') * 2 - 1);
  if o = 'ISNOTNULL' then Exit(Ord(V <> '') * 2 - 1);
  if o = 'IN' then
  begin
    if V = '' then Exit(0);
    anyNull := False;
    for i := 0 to High(C.Vals) do
    begin
      if C.Vals[i] = '' then begin anyNull := True; Continue; end;
      if VDbCmpVal(V, C.Vals[i], '=', C.Ctype) then Exit(1);
    end;
    if anyNull then Exit(0);
    Exit(-1);
  end;
  if o = 'NOTIN' then
  begin
    if V = '' then Exit(0);
    anyNull := False;
    for i := 0 to High(C.Vals) do
    begin
      if C.Vals[i] = '' then begin anyNull := True; Continue; end;
      if VDbCmpVal(V, C.Vals[i], '=', C.Ctype) then Exit(-1);
    end;
    if anyNull then Exit(0);
    Exit(1);
  end;
  if (o = 'BETWEEN') or (o = 'NOTBETWEEN') then
  begin
    if Length(C.Vals) = 0 then Exit(0);
    if (V = '') or (C.Val = '') or (C.Vals[0] = '') then Exit(0);
    t := 1;
    if not VDbCmpVal(V, C.Val, '>=', C.Ctype) then Exit(-1)
    else if not VDbCmpVal(V, C.Vals[0], '<=', C.Ctype) then Exit(-1);
    if o = 'NOTBETWEEN' then Exit(-1);
    Exit(1);
  end;
  if o = 'NOTLIKE' then
  begin
    if (V = '') or (C.Val = '') then Exit(0);
    if VDbLikeMatch(V, C.Val) then Exit(-1);
    Exit(1);
  end;
  // skaler operatorler
  if (V = '') or (C.Val = '') then Exit(0);
  if o = 'LIKE' then
  begin
    if VDbLikeMatch(V, C.Val) then Exit(1);
    Exit(-1);
  end;
  if VDbCmpVal(V, C.Val, C.Op, C.Ctype) then Exit(1);
  Exit(-1);
end;

function VDbCmpTri(const A, B, Op: string; Ctype: Byte): Integer;
// Uc degerli karsilastirma: -1 = FALSE, 0 = BILINMEZ (NULL), +1 = TRUE
var
  af, bf: Double;
  o: string;
  numeric: Boolean;
begin
  o := UpperCase(Op);
  numeric := VDbIsNumericCol(Ctype);
  if o = 'ISNULL' then Exit(Ord(A = '') * 2 - 1);
  if o = 'ISNOTNULL' then Exit(Ord(A <> '') * 2 - 1);
  // NULL tarafi: deger BILINMEZ olur. (WHERE farkli davranir: eslesmez.)
  if (A = '') or (B = '') then Exit(0);
  if o = 'LIKE' then Exit(Ord(VDbLikeMatch(A, B)) * 2 - 1);
  if numeric and VDbParseFloat(A, af) and VDbParseFloat(B, bf) then
  begin
    if o = '=' then Exit(Ord(af = bf) * 2 - 1);
    if (o = '<>') or (o = '!=') then Exit(Ord(af <> bf) * 2 - 1);
    if o = '>' then Exit(Ord(af > bf) * 2 - 1);
    if o = '<' then Exit(Ord(af < bf) * 2 - 1);
    if o = '>=' then Exit(Ord(af >= bf) * 2 - 1);
    if o = '<=' then Exit(Ord(af <= bf) * 2 - 1);
  end;
  if o = '=' then Exit(Ord(A = B) * 2 - 1);
  if (o = '<>') or (o = '!=') then Exit(Ord(A <> B) * 2 - 1);
  if o = '>' then Exit(Ord(A > B) * 2 - 1);
  if o = '<' then Exit(Ord(A < B) * 2 - 1);
  if o = '>=' then Exit(Ord(A >= B) * 2 - 1);
  if o = '<=' then Exit(Ord(A <= B) * 2 - 1);
  Result := -1;
end;

function VDbCheckOK(const Vals: TStrArray; const Groups: TWhereGroups): Boolean;
// SQL CHECK semantigi: ihlal yalnizca kosul KESIN OLARAK FALSE ise
// olur. NULL iceren kosul BILINMEZ'dir ve ihlal SAYILMAZ. Aksi halde
// "CHECK (p >= 0)" olan opsiyonel kolon, NULL degerle INSERT'i reddederdi.
// Gruplar arasi OR, grup ici AND.
var
  g, c, gt: Integer;
  anyTrue, anyUnknown: Boolean;
begin
  if Length(Groups) = 0 then Exit(True);
  anyTrue := False;
  anyUnknown := False;
  for g := 0 to High(Groups) do
  begin
    gt := 1;                        // AND grubu: basta TRUE
    for c := 0 to High(Groups[g]) do
    begin
      if (Groups[g][c].Col < 0) or (Groups[g][c].Col >= Length(Vals)) then
      begin gt := 0; Continue; end;  // indis hatasi: bilinmez sayilir
      case VDbCondTri(Vals[Groups[g][c].Col], Groups[g][c]) of
        -1: begin gt := -1; Break; end;   // kesin FALSE -> grup dustu
         0: if gt > 0 then gt := 0;        // bilinmez
      end;
    end;
    if gt = 1 then anyTrue := True
    else if gt = 0 then anyUnknown := True;
  end;
  // hicbir grup kesin FALSE degilse gecer
  Result := anyTrue or anyUnknown;
end;

function VDbHex(const S: RawByteString): string;
var
  i: Integer;
const
  HH: array[0..15] of Char = ('0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F');
begin
  SetLength(Result, Length(S) * 2);
  for i := 1 to Length(S) do
  begin
    Result[(i - 1) * 2 + 1] := HH[(Byte(S[i]) shr 4) and 15];
    Result[(i - 1) * 2 + 2] := HH[Byte(S[i]) and 15];
  end;
end;

function VDbUnhex(const S: string): RawByteString;
var
  i, n: Integer;

  function Hx(c: Char): Integer;
  begin
    if (c >= '0') and (c <= '9') then Exit(Ord(c) - Ord('0'));
    if (c >= 'A') and (c <= 'F') then Exit(Ord(c) - Ord('A') + 10);
    if (c >= 'a') and (c <= 'f') then Exit(Ord(c) - Ord('a') + 10);
    raise EVDbException.Create(ecTypeMismatch, 'hex bozuk');
  end;

begin
  if Odd(Length(S)) then raise EVDbException.Create(ecTypeMismatch, 'hex uzunlugu tek');
  SetLength(Result, Length(S) div 2);
  n := 0;
  i := 1;
  while i < Length(S) do
  begin
    Inc(n);
    Result[n] := AnsiChar((Hx(S[i]) shl 4) or Hx(S[i + 1]));
    Inc(i, 2);
  end;
end;

{ R-19: sema satirindaki metin alanlari '|' ayiracini icerebilir (politika
  ifadesi). Bu yuzden hex'e cevrilir. Bos alan icin tek basina '-' kullanilir
  (bos alan TStringList.DelimitedText ile kaybolur). }
function HexEncFld(const S: string): string;
begin
  if S = '' then Exit('-');
  Result := VDbHex(RawByteString(S));
end;

function HexFld(const S: string): string;
var r: RawByteString;
begin
  if (S = '') or (S = '-') then Exit('');
  r := VDbUnhex(S);
  SetLength(Result, Length(r));
  if Length(r) > 0 then Move(r[1], Result[1], Length(r));
end;

function VDbNormValue(Ctype: Byte; const S: string): string;
var
  v: string;
  iv: Int64;
  fv: Double;
  d: TDateTime;
  fs: TFormatSettings;
begin
  if Ctype = VCT_BLOB then
  begin
    // BLOB = ham bayt: Trim ve 'NULL' literal denetimi YAPILMAZ.
    // Aksi halde JPEG/PNG gibi ikili verinin bas ve son baytlari
    // (<= $20) sessizce silinir.
    Result := S;
    Exit;
  end;
  v := Trim(S);
  Result := v;
  if v = '' then Exit; // NULL serbest (NOT NULL ayri denetlenir)
  // SQL NULL literal: her tipe NULL yazar (NOT NULL ayri denetlenir)
  if SameText(v, 'NULL') then
  begin
    Result := '';
    Exit;
  end;
  case Ctype of
    VCT_INT:
      if not VDbParseInt(v, iv) then
        raise EVDbException.Create(ecTypeMismatch, 'INTEGER degil: ' + v);
    VCT_FLOAT:
      if not VDbParseFloat(v, fv) then
        raise EVDbException.Create(ecTypeMismatch, 'sayi degil: ' + v);
    VCT_BOOL:
      if not (SameText(v, 'true') or SameText(v, 'false') or (v = '1') or (v = '0')) then
        raise EVDbException.Create(ecTypeMismatch, 'BOOLEAN degil: ' + v);
    VCT_DATE, VCT_DATETIME, VCT_TIME:
      begin
        fs := DefaultFormatSettings;
        fs.DateSeparator := '-';
        fs.TimeSeparator := ':';
        fs.ShortDateFormat := 'yyyy-mm-dd';
        fs.LongTimeFormat := 'hh:nn:ss';
        if Ctype = VCT_DATE then
        begin
          if not TryStrToDate(v, d, fs) then
            if not TryStrToDate(v, d) then
              raise EVDbException.Create(ecTypeMismatch, 'tarih degil: ' + v);
          Result := FormatDateTime('yyyy-mm-dd', d);
        end
        else if Ctype = VCT_TIME then
        begin
          if not TryStrToTime(v, d, fs) then
            if not TryStrToTime(v, d) then
              raise EVDbException.Create(ecTypeMismatch, 'saat degil: ' + v);
          Result := FormatDateTime('hh:nn:ss', d);
        end
        else
        begin
          if not TryStrToDateTime(v, d, fs) then
            if not TryStrToDateTime(v, d) then
              raise EVDbException.Create(ecTypeMismatch, 'tarih-saat degil: ' + v);
          Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', d);
        end;
      end;
  end;
end;

function VDbFloatToStr(V: Double): string;
var
  fs: TFormatSettings;
begin
  // cikti her locale'de ayni: ondalik nokta
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  Result := FloatToStr(V, fs);
end;

function VDbIdxCmp(const A, B: string; Ctype: Byte): Integer;
// Indeks anahtarlarini karsilastirir.
//
// ONCEDEN INTEGER kolonlarda Double'a ceviriliyordu. Bu hem YAVAS
// (her karsilastirmada 2x kayan nokta ayristirma; 96.000 girdilik bir
// indeksin siralanmasi saniyeler suruyordu) hem DE HATALIYDI: Double
// 2^53'ten buyuk tam sayilari temsil edemedigi icin buyuk id'ler yanlis
// siralanirdi.
//
// SIMDI: INTEGER/BOOLEAN -> Int64 (birebir dogru ve hizli),
//       FLOAT            -> Double,
//       digerleri        -> CompareStr.
// NULL (bos string) her zaman en basta.
var
  ia, ib: Int64;
  fa, fb: Double;
begin
  if A = '' then
  begin
    if B = '' then Exit(0);
    Exit(-1);
  end;
  if B = '' then Exit(1);
  if (Ctype = VCT_INT) or (Ctype = VCT_BOOL) then
  begin
    if VDbParseInt(A, ia) and VDbParseInt(B, ib) then
    begin
      if ia < ib then Exit(-1);
      if ia > ib then Exit(1);
      Exit(0);
    end;
  end
  else if Ctype = VCT_FLOAT then
  begin
    if VDbParseFloat(A, fa) and VDbParseFloat(B, fb) then
    begin
      if fa < fb then Exit(-1);
      if fa > fb then Exit(1);
      Exit(0);
    end;
  end;
  Result := CompareStr(A, B);
end;

{ ================= COK KOLONLU INDEKS YARDIMCILARI ================= }

function VDbIdxPartOf(const A: string; Part: Integer): string;
// F2-15: Birlestirilmis anahtar artik "<uzunluk>:<deger><uzunluk>:<deger>..."
// bicimindedir. Once #1 ayirici kullaniliyordu; degerin ICINDE #1 varsa
// (BLOB'ta her olabilir, TEXT'te de olabilir) iki farkli satir ayni
// anahtari uretip birbirinin yerine gecirdi.
//
// Iki bicim de taninir: ilk karakter rakam degilse ESKI #1 bicimi
// varsayilir (indices yalnizca bellekte tutuldugu icin bu yalniz
// savunma ama yine de guvenli).
var
  i, p, st, ln: Integer;
begin
  Result := '';
  if A = '' then Exit;
  if (A[1] >= '0') and (A[1] <= '9') then
  begin
    i := 1; p := 0;
    while i <= Length(A) do
    begin
      st := i;
      while (i <= Length(A)) and (A[i] >= '0') and (A[i] <= '9') do Inc(i);
      if i = st then Exit('');                 // rakam yok -> bozuk
      ln := StrToIntDef(Copy(A, st, i - st), -1);
      if ln < 0 then Exit('');
      if (i > Length(A)) or (A[i] <> ':') then Exit('');
      Inc(i);
      if ln > Length(A) - i + 1 then Exit('');  // tasma
      if p = Part then Exit(Copy(A, i, ln));
      Inc(p);
      Inc(i, ln);
    end;
    Exit;
  end;
  // eski #1 bicimi
  p := 0; i := 1; st := 1;
  while i <= Length(A) do
  begin
    if A[i] = VDB_IDX_SEP then
    begin
      if p = Part then Exit(Copy(A, st, i - st));
      Inc(p); st := i + 1;
    end;
    Inc(i);
  end;
  if p = Part then Result := Copy(A, st, Length(A) + 1 - st);
end;

{ F-17: PARTIAL INDEX kosul denetleyici.
  Predicate metni VDbParser.ExprToText tarafindan uretilmistir; desteklenen
  dil sinirli ve NOTsaldir:
      (((kolon|tipli-sabit) <op> (kolon|tipli-sabit)) | IS [NOT] NULL | IN (...))
      birlestiriciler: AND / OR
  Baska bir bicim gelirse (parantez, NOT, fonksiyon) **guvenli tarafta**
  FALSE doner: indeks satiri EKLENMEZ. Boylece indeksin icerigi her zaman
  gercek kosulun alt kumesi kalir; bir satir yanlis Sekilde indekslenmis
  olsa bile sorgu sonucu degismez (indeks yalnizca on daraltir, dogrulamayi
  WHERE yine yapar).
  Bos Predicate = normal indeks (tum satirlar). }
function VDbPredOK(const Predicate: string; const Vals: TStrArray;
  const Cols: array of TColDef): Boolean;
var
  S: string;
  P: Integer;
  neg, found, sub: Boolean;      // Atom/Expr paylasilan bayraklar
  opS, lhsS, rhsS: string;
  lhsNull, rhsNull: Boolean;
  ci, k, cmp: Integer;
  ctype: Byte;

  function Expr: Boolean; forward;
  function AndExpr: Boolean; forward;
  function Atom: Boolean; forward;

  function LastDot(const A: string): Integer;
  var
    j: Integer;
  begin
    Result := 0;
    for j := 1 to Length(A) do
      if A[j] = '.' then Result := j;
  end;

  function IsNameCh(c: Char): Boolean;
  begin
    Result := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
              ((c >= '0') and (c <= '9')) or (c = '_') or (c = '.');
  end;

  procedure SkipWs;
  begin
    while (P <= Length(S)) and (S[P] = ' ') do Inc(P);
  end;

  function WordIs(const W: string): Boolean;
  // P konumunda W kelimesi var mi (sonrasi boslak / ')' / son)?
  begin
    Result := (P + Length(W) - 1 <= Length(S)) and
              (Copy(S, P, Length(W)) = W) and
              ((P + Length(W) > Length(S)) or
               (S[P + Length(W)] = ' ') or (S[P + Length(W)] = ')'));
  end;

  { Tek bir deger okur: 'metin' | sayi | NULL | kolon.
    Basarisiz olursa False doner (cagiran guvenli FALSE yoluna gider). }
  function Operand(out SVal: string; out IsNull: Boolean): Boolean;
  var
    v: string;
    cmp2: Integer;   // FPC 4058: FOR sayaci dis degisken olamaz
  begin
    SkipWs;
    IsNull := False;
    SVal := '';
    if P > Length(S) then Exit(False);
    if S[P] = '''' then                    // 'metin' sabiti
    begin
      Inc(P);
      while P <= Length(S) do
      begin
        if S[P] <> '''' then
        begin
          SVal := SVal + S[P];
          Inc(P);
          Continue;
        end;
        // '' kacisi mi, yoksa kapanis mi?
        if (P + 1 <= Length(S)) and (S[P + 1] = '''') then
        begin
          SVal := SVal + '''';
          Inc(P, 2);
          Continue;
        end;
        Inc(P);                           // kapanis tirnagi
        Exit(True);
      end;
      Exit(False);                        // tirnak kapanmadi
    end;
    if (S[P] >= '0') and (S[P] <= '9') then     // sayi
    begin
      while (P <= Length(S)) and (((S[P] >= '0') and (S[P] <= '9')) or
            (S[P] = '.')) do
      begin
        SVal := SVal + S[P];
        Inc(P);
      end;
      Exit(True);
    end;
    if WordIs('NULL') then
    begin
      IsNull := True;
      Inc(P, 4);
      Exit(True);
    end;
    // kolon adi  [t.]ad
    v := '';
    while (P <= Length(S)) and IsNameCh(S[P]) do
    begin
      v := v + S[P];
      Inc(P);
    end;
    if v = '' then Exit(False);
    k := LastDot(v);
    if k > 0 then v := Copy(v, k + 1, MaxInt);
    ci := -1;
    for cmp2 := 0 to High(Cols) do
      if VDbNorm(Cols[cmp2].Name) = VDbNorm(v) then
      begin
        ci := cmp2;
        Break;
      end;
    if ci < 0 then Exit(False);            // bilinmeyen kolon -> guvenli FALSE
    ctype := Cols[ci].Ctype;
    if ci >= Length(Vals) then
    begin
      IsNull := True;                     // eksik deger = NULL
      Exit(True);
    end;
    SVal := Vals[ci];
    IsNull := (SVal = '');
    Exit(True);
  end;

  function Atom: Boolean;
  begin
    SkipWs;
    if P > Length(S) then Exit(False);
    // IS [NOT] NULL
    if WordIs('IS') then
    begin
      Inc(P, 2);
      SkipWs;
      neg := False;
      if WordIs('NOT') then
      begin
        neg := True;
        Inc(P, 3);
        SkipWs;
      end;
      if not WordIs('NULL') then Exit(False);
      Inc(P, 4);
      if not Operand(rhsS, rhsNull) then Exit(False);
      if neg then Exit(not rhsNull) else Exit(rhsNull);
    end;
    // NOT IN (...) desteklenmiyor -> guvenli FALSE
    if WordIs('NOT') then Exit(False);
    // IN (a, b, ...)
    if WordIs('IN') then
    begin
      Inc(P, 2);
      SkipWs;
      if (P > Length(S)) or (S[P] <> '(') then Exit(False);
      Inc(P);
      if not Operand(lhsS, lhsNull) then Exit(False);
      if lhsNull then Exit(False);        // NULL IN (...) -> UNKNOWN -> FALSE
      found := False;
      while True do
      begin
        SkipWs;
        if P > Length(S) then Exit(False);
        if S[P] = ')' then
        begin
          Inc(P);
          Break;
        end;
        if not Operand(rhsS, rhsNull) then Exit(False);
        if (not rhsNull) and (rhsS = lhsS) then found := True;
        SkipWs;
        if (P <= Length(S)) and (S[P] = ',') then
        begin
          Inc(P);
          Continue;
        end;
        if (P <= Length(S)) and (S[P] = ')') then
        begin
          Inc(P);
          Break;
        end;
        Exit(False);
      end;
      Exit(found);
    end;
    // ( ... )
    if S[P] = '(' then
    begin
      Inc(P);
      sub := Expr;
      SkipWs;
      if (P > Length(S)) or (S[P] <> ')') then Exit(False);
      Inc(P);
      Exit(sub);
    end;
    // operand [op operand]
    if not Operand(lhsS, lhsNull) then Exit(False);
    SkipWs;
    if P > Length(S) then Exit(False);
    opS := '';
    if S[P] = '<' then
    begin
      if (P + 1 <= Length(S)) and (S[P+1] = '>') then
      begin opS := '<>'; Inc(P, 2); end
      else if (P + 1 <= Length(S)) and (S[P+1] = '=') then
      begin opS := '<='; Inc(P, 2); end
      else begin opS := '<'; Inc(P); end;
    end
    else if S[P] = '>' then
    begin
      if (P + 1 <= Length(S)) and (S[P+1] = '=') then
      begin opS := '>='; Inc(P, 2); end
      else begin opS := '>'; Inc(P); end;
    end
    else if S[P] = '=' then begin opS := '='; Inc(P); end
    else Exit(False);                     // LIKE / fonksiyon / vs -> desteklenmiyor
    SkipWs;
    if not Operand(rhsS, rhsNull) then Exit(False);
    if lhsNull or rhsNull then Exit(False);   // SQL NULL: sonuc UNKNOWN
    Exit(VDbCmpVal(lhsS, rhsS, opS, ctype));
  end;

  function AndExpr: Boolean;
  begin
    Result := Atom;
    while True do
    begin
      SkipWs;
      if WordIs('AND') then
      begin
        Inc(P, 3);
        if not Atom then Exit(False);     // kisa devre: hep guvenli FALSE
        Continue;
      end;
      Break;
    end;
  end;

  function Expr: Boolean;
  begin
    Result := AndExpr;
    while True do
    begin
      SkipWs;
      if WordIs('OR') then
      begin
        Inc(P, 2);
        if not AndExpr then Exit(False);
        Continue;
      end;
      Break;
    end;
  end;

begin
  // Bos predicate = normal indeks (tum satirlar indekslenir)
  Result := True;
  if Predicate = '' then Exit;
  S := Predicate;
  P := 1;
  Result := False;
  if not Expr then Exit;
  SkipWs;
  // Tum metin tuketilmis olmali; artik varsa guvenli FALSE
  if P > Length(S) then Result := True;
end;

{ F-18: ifade indeks anahtari hesabi.
  Expr metni VDbParser.ExprToText tarafindan uretilir. Desteklenen dil:
    fonksiyon: LOWER/UPPER/TRIM/LENGTH/ABS
    operator : + - * /
    atom     : kolon | sayi | 'metin'
  Donus: basariliysa True ve Val/ACtype doldurulur. BASARISIZSA False
  doner ve cagiran guvenli tarafta gider (indeks o satiri icermez) — boylece
  yanlis tipte siralama yapilip SATIR KACIRILAMAZ.
  Tip kurali: sayisal kolon/islem -> VCT_INT/VCT_FLOAT, aksi halde VCT_STR. }
function VDbExprVal(const Expr: string; const Vals: TStrArray;
  const Cols: array of TColDef; out Val: string; out ACtype: Byte): Boolean;
var
  S: string;
  P: Integer;

  procedure SkipWs;
  begin
    while (P <= Length(S)) and (S[P] = ' ') do Inc(P);
  end;

  function WordIs(const W: string): Boolean;
  begin
    Result := (P + Length(W) - 1 <= Length(S)) and
              (Copy(S, P, Length(W)) = W) and
              ((P + Length(W) > Length(S)) or
               (S[P + Length(W)] = ' ') or (S[P + Length(W)] = ')') or
               (S[P + Length(W)] = '(') or (S[P + Length(W)] = ','));
  end;

  function IsNameCh(c: Char): Boolean;
  begin
    Result := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
              ((c >= '0') and (c <= '9')) or (c = '_') or (c = '.');
  end;

  function LastDot(const A: string): Integer;
  var
    j: Integer;
  begin
    Result := 0;
    for j := 1 to Length(A) do
      if A[j] = '.' then Result := j;
  end;

  { Deger uretip + tip bildirir; basarisizsa False.
    Desteklenen fonksiyonlar: LOWER / UPPER / TRIM / LENGTH / ABS }
  function Term(out V: string; out Tp: Byte): Boolean;
  var
    fname, arg, r: string;
    aTp, rTp: Byte;
    d: Double;
    k, ci, cmp2: Integer;
    opc: Char;
    f1, f2: Double;

    function Primary(out V2: string; out Tp2: Byte): Boolean;
    var
      cmp3: Integer;   // FPC 4058: FOR sayaci dis degisken olamaz
    begin
      SkipWs;
      if P > Length(S) then Exit(False);
      if S[P] = '(' then
      begin
        Inc(P);
        if not Term(V2, Tp2) then Exit(False);
        SkipWs;
        if (P > Length(S)) or (S[P] <> ')') then Exit(False);
        Inc(P);
        Exit(True);
      end;
      if S[P] = '''' then                      // 'metin'
      begin
        Inc(P);
        while P <= Length(S) do
        begin
          if S[P] <> '''' then
          begin
            V2 := V2 + S[P];
            Inc(P);
            Continue;
          end;
          if (P + 1 <= Length(S)) and (S[P + 1] = '''') then
          begin
            V2 := V2 + '''';
            Inc(P, 2);
            Continue;
          end;
          Inc(P);
          Tp2 := VCT_STR;
          Exit(True);
        end;
        Exit(False);
      end;
      if (S[P] >= '0') and (S[P] <= '9') then
      begin
        while (P <= Length(S)) and (((S[P] >= '0') and (S[P] <= '9')) or
              (S[P] = '.')) do
        begin
          V2 := V2 + S[P];
          Inc(P);
        end;
        if Pos('.', V2) > 0 then Tp2 := VCT_FLOAT else Tp2 := VCT_INT;
        Exit(True);
      end;
      // fonksiyon: AD( arg )
      if WordIs('LOWER') or WordIs('UPPER') or WordIs('TRIM') or
         WordIs('LENGTH') or WordIs('ABS') then
      begin
        fname := '';
        while (P <= Length(S)) and IsNameCh(S[P]) do
        begin
          fname := fname + S[P];
          Inc(P);
        end;
        fname := UpperCase(fname);
        SkipWs;
        if (P > Length(S)) or (S[P] <> '(') then Exit(False);
        Inc(P);
        if not Term(arg, aTp) then Exit(False);
        SkipWs;
        if (P > Length(S)) or (S[P] <> ')') then Exit(False);
        Inc(P);
        // SQL NULL propagasyonu: arg NULL ise sonuc da NULL (bos) olur.
        // aksi halde LENGTH(NULL) = 0 gibi yanlis bir anahtar uretilirdi.
        if (arg = '') and (aTp <> VCT_INT) and (aTp <> VCT_FLOAT) then
        begin
          V2 := '';
          Tp2 := VCT_STR;
          Exit(True);
        end;
        if fname = 'LOWER' then begin V2 := VDbTrLower(arg); Tp2 := VCT_STR; Exit(True); end;
        if fname = 'UPPER' then begin V2 := VDbTrUpper(arg); Tp2 := VCT_STR; Exit(True); end;
        if fname = 'TRIM'  then begin V2 := Trim(arg);     Tp2 := VCT_STR; Exit(True); end;
        if fname = 'LENGTH' then
        begin
          if aTp = VCT_STR then V2 := IntToStr(VDbUtf8Length(arg))
          else if VDbParseFloat(arg, d) then V2 := IntToStr(Round(d))
          else Exit(False);
          Tp2 := VCT_INT;
          Exit(True);
        end;
        if fname = 'ABS' then
        begin
          if aTp = VCT_STR then Exit(False);
          VDbParseFloat(arg, d);
          if d < 0 then d := -d;
          if aTp = VCT_INT then V2 := IntToStr(Round(d)) else V2 := VDbFloatToStr(d);
          Tp2 := aTp;
          Exit(True);
        end;
        Exit(False);   // yukarida tanimli disi fonksiyon
      end;
      // kolon  [t.]ad
      V2 := '';
      while (P <= Length(S)) and IsNameCh(S[P]) do
      begin
        V2 := V2 + S[P];
        Inc(P);
      end;
      if V2 = '' then Exit(False);
      k := LastDot(V2);
      if k > 0 then V2 := Copy(V2, k + 1, MaxInt);
      ci := -1;
      for cmp3 := 0 to High(Cols) do
        if VDbNorm(Cols[cmp3].Name) = VDbNorm(V2) then
        begin
          ci := cmp3;
          Break;
        end;
      if ci < 0 then Exit(False);
      Tp2 := Cols[ci].Ctype;
      if ci >= Length(Vals) then V2 := '' else V2 := Vals[ci];
      Exit(True);
    end;

    function Arith(out V2: string; out Tp2: Byte): Boolean;
    begin
      Result := Primary(V2, Tp2);
      while True do
      begin
        SkipWs;
        if P > Length(S) then Break;
        if (S[P] <> '+') and (S[P] <> '-') and (S[P] <> '*') and
           (S[P] <> '/') then Break;
        opc := S[P];
        Inc(P);
        if not Primary(r, rTp) then Exit(False);
        // metin aritmetigi anlamsiz -> tip belirsiz, guvenli False
        if (Tp2 = VCT_STR) or (rTp = VCT_STR) then Exit(False);
        if (Tp2 = VCT_FLOAT) or (rTp = VCT_FLOAT) then Tp2 := VCT_FLOAT
        else Tp2 := VCT_INT;
        VDbParseFloat(V2, f1);
        VDbParseFloat(r, f2);
        case opc of
          '+': f1 := f1 + f2;
          '-': f1 := f1 - f2;
          '*': f1 := f1 * f2;
          '/': if f2 = 0 then Exit(False) else f1 := f1 / f2;
        end;
        if Tp2 = VCT_INT then V2 := IntToStr(Round(f1))
        else V2 := VDbFloatToStr(f1);
      end;
    end;

  begin
    Result := Arith(V, Tp);
  end;

begin
  Result := False;
  Val := '';
  ACtype := VCT_STR;
  if Expr = '' then Exit;
  S := Expr;
  P := 1;
  if not Term(Val, ACtype) then Exit;
  SkipWs;
  // artik erken varsa ifade bizim dilimizde degildir -> guvenli False
  if P <= Length(S) then Exit;
  Result := True;
end;

function VDbIdxJoin(const Vals: TStrArray; const Cols: TIntArray): string;
// Satir degerlerinden indeks anahtari olusturur.
// F2-15: Birden fazla kolon varsa UZUNLUK-ONEKI kodlama kullanilir
// ("3:abc2:xy"). Boylece deger icindeki #1 (BLOB) belirsizlik yaratmaz.
// TEK kolonlu indeksler ham deger olarak kalir: hem hizli yol hem de
// NParts<=1 karsilastirmasi (VDbIdxCmp) degismemek icin.
var
  i, cnt: Integer;
begin
  cnt := 0;
  for i := 0 to High(Cols) do
    if (Cols[i] >= 0) and (Cols[i] < Length(Vals)) then Inc(cnt);
  Result := '';
  if cnt <= 1 then
  begin
    for i := 0 to High(Cols) do
      if (Cols[i] >= 0) and (Cols[i] < Length(Vals)) then
      begin
        Result := Vals[Cols[i]];
        Break;
      end;
    Exit;
  end;
  for i := 0 to High(Cols) do
  begin
    if (Cols[i] < 0) or (Cols[i] >= Length(Vals)) then Continue;
    Result := Result + IntToStr(Length(Vals[Cols[i]])) + ':' + Vals[Cols[i]];
  end;
end;

function VDbIdxPartCmp(const A, B: string; Part: Integer; Ctype: Byte): Integer;
begin
  Result := VDbIdxCmp(VDbIdxPartOf(A, Part), VDbIdxPartOf(B, Part), Ctype);
end;

function VDbIdxMultiCmp(const A, B: string; const Ctypes: TByteArray): Integer;
// Iki birlestirilmis anahtari parca parca karsilastirir (sozluk sirasi)
var
  p: Integer;
begin
  for p := 0 to High(Ctypes) do
  begin
    Result := VDbIdxPartCmp(A, B, p, Ctypes[p]);
    if Result <> 0 then Exit;
  end;
  Result := 0;
end;

function VDbIdxCmpMulti(const A, B: string; Ctype: Byte; NParts: Integer): Integer;
// NParts = 1 ise dogrudan VDbIdxCmp (hizli yol).
// NParts > 1 ise parca parca karsilastirma (ilk farkli parca belirler).
var
  p: Integer;
  pa, pb: string;
begin
  if NParts <= 1 then Exit(VDbIdxCmp(A, B, Ctype));
  for p := 0 to NParts - 1 do
  begin
    pa := VDbIdxPartOf(A, p);
    pb := VDbIdxPartOf(B, p);
    Result := VDbIdxCmp(pa, pb, Ctype);   // ilk kolonun tipi
    if Result <> 0 then Exit;
  end;
  Result := 0;
end;

function IdxKeyLo(const E: TIdxEntries; Ctype: Byte; const Key: string): Integer;
// Key'e gore alt sinir (pk goz ardi)
var
  lo, hi, m: Integer;
begin
  lo := 0; hi := Length(E);
  while lo < hi do
  begin
    m := (lo + hi) div 2;
    if VDbIdxCmp(E[m].Key, Key, Ctype) < 0 then
      lo := m + 1
    else
      hi := m;
  end;
  Result := lo;
end;

function IdxKeyHi(const E: TIdxEntries; Ctype: Byte; const Key: string): Integer;
// Key'e gore ust sinir (Key>X olan ilk konum)
var
  lo, hi, m: Integer;
begin
  lo := 0; hi := Length(E);
  while lo < hi do
  begin
    m := (lo + hi) div 2;
    if VDbIdxCmp(E[m].Key, Key, Ctype) <= 0 then
      lo := m + 1
    else
      hi := m;
  end;
  Result := lo;
end;

function VDbIdxRange(const E: TIdxEntries; Ctype: Byte; const Op, Val: string;
  out Lo, Hi: Integer): Boolean;
var
  o: string;
begin
  Result := True;
  o := UpperCase(Op);
  if o = '=' then begin Lo := IdxKeyLo(E, Ctype, Val); Hi := IdxKeyHi(E, Ctype, Val); end
  else if o = '>' then begin Lo := IdxKeyHi(E, Ctype, Val); Hi := Length(E); end
  else if o = '>=' then begin Lo := IdxKeyLo(E, Ctype, Val); Hi := Length(E); end
  else if o = '<' then begin Lo := 0; Hi := IdxKeyLo(E, Ctype, Val); end
  else if o = '<=' then begin Lo := 0; Hi := IdxKeyHi(E, Ctype, Val); end
  else begin Lo := 0; Hi := 0; Result := False; end;
end;

function VDbIdxProbe1(const Val: string): string;
// TEK bir degeri, cok kolonlu indeks anahtarinin KODLANMIS bicimine cevirir
// ("3:abc"). VDbIdxRangeL bunu yapmazsa VDbIdxPartOf ham degeri de kodlu
// sanip ayirir: '10' -> "10" rakam sayilir, "10:" aranir, yoktur -> BOS
// doner. Bos ile karsilastirma '=' dilimini BOS BIRAKIR ve satirlar
// sessizce kaybolur.
begin
  Result := IntToStr(Length(Val)) + ':' + Val;
end;

function VDbTypeName(Ctype: Byte): string;
// 2026-10-04: sema sorgulari (DESCRIBE / SHOW CREATE TABLE).
begin
  case Ctype of
    VCT_INT:    Result := 'INTEGER';
    VCT_FLOAT:  Result := 'FLOAT';
    VCT_STR:    Result := 'TEXT';
    VCT_BOOL:   Result := 'BOOLEAN';
    VCT_BLOB:   Result := 'BLOB';
  else
    Result := 'TEXT';
  end;
end;

function VDbFkActionToStr(const A: string): string;
begin
  if A = VDB_FK_CASCADE then Result := 'CASCADE'
  else if A = VDB_FK_SETNULL then Result := 'SET NULL'
  else if A = VDB_FK_SETDEFAULT then Result := 'SET DEFAULT'
  else Result := 'RESTRICT';
end;

function VDbIdxRangeLK(const E: TIdxEntries; Ctype: Byte; const Op, EncodedKey: string;
  NParts: Integer; out Lo, Hi: Integer): Boolean;
// VDbIdxRangeL'nin KODLANMIS anahtar alan varyanti (cagiran zaten
// "len:v1len:v2..." biciminde bir anahtar verir; yeniden kodlanmaz).
// F2-23 UNIQUE denetimi bunu kullanir.
var
  lo2, hi2: Integer;
begin
  Result := True;
  if NParts <= 1 then Exit(VDbIdxRange(E, Ctype, Op, EncodedKey, Lo, Hi));
  if Op = '=' then
  begin
    lo2 := 0; hi2 := Length(E);
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, EncodedKey, 0, Ctype) < 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := lo2;
    hi2 := Length(E);
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, EncodedKey, 0, Ctype) <= 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Hi := lo2;
  end
  else if Op = '>' then
  begin
    hi2 := Length(E); lo2 := 0;
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, EncodedKey, 0, Ctype) <= 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := lo2; Hi := Length(E);
  end
  else if Op = '>=' then
  begin
    hi2 := Length(E); lo2 := 0;
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, EncodedKey, 0, Ctype) < 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := lo2; Hi := Length(E);
  end
  else
    // '<', '<=', BETWEEN vb. icin ham degerli VDbIdxRangeL kullanilir.
    raise EVDbException.Create(ecUnsupported,
      'VDbIdxRangeLK: desteklenmeyen operator ' + Op);
end;

function VDbIdxRangeL(const E: TIdxEntries; Ctype: Byte; const Op, Val: string;
  NParts: Integer; out Lo, Hi: Integer): Boolean;
// COK KOLONLU indekslerde aralik YALNIZ ILK KOLONA gore hesaplanir
// (gercek RDBMS'lerin "leading column" kurali).
// NParts = 1 ise VDbIdxRange ile birebir aynidir.
//
// Val HAM bir degerdir (orn. '10'); VDbIdxPartOf kodlu anahtar bekledigi
// icin once VDbIdxProbe1 ile kodlanir. KODLU anahtar vermek icin
// VDbIdxRangeLK kullanilir.
var
  o: string;
  lo2, hi2: Integer;
  probe: string;
begin
  Result := True;
  if NParts <= 1 then Exit(VDbIdxRange(E, Ctype, Op, Val, Lo, Hi));
  o := UpperCase(Op);
  probe := VDbIdxProbe1(Val);   // ham deger -> kodlu 1-parca anahtar

  if o = '=' then
  begin
    // tum bilesik anahtarin basinda "Val" ilk parcasi olan bolum
    lo2 := 0; hi2 := Length(E);
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, probe, 0, Ctype) < 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := lo2;
    hi2 := Length(E);
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, probe, 0, Ctype) <= 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Hi := lo2;
  end
  else if o = '>' then
  begin
    hi2 := Length(E); lo2 := 0;
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, probe, 0, Ctype) <= 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := lo2; Hi := Length(E);
  end
  else if o = '>=' then
  begin
    hi2 := Length(E); lo2 := 0;
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, probe, 0, Ctype) < 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := lo2; Hi := Length(E);
  end
  else if o = '<' then
  begin
    hi2 := Length(E); lo2 := 0;
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, probe, 0, Ctype) < 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := 0; Hi := lo2;
  end
  else if o = '<=' then
  begin
    hi2 := Length(E); lo2 := 0;
    while lo2 < hi2 do
    begin
      if VDbIdxPartCmp(E[(lo2 + hi2) div 2].Key, probe, 0, Ctype) <= 0 then
        lo2 := (lo2 + hi2) div 2 + 1
      else
        hi2 := (lo2 + hi2) div 2;
    end;
    Lo := 0; Hi := lo2;
  end
  else begin Lo := 0; Hi := 0; Result := False; end;
end;

// ---- row encode/decode ----

procedure WriteU16(var B: TBytes; var P: Integer; V: Word);
begin
  if Length(B) < P + 2 then SetLength(B, P + 64);
  B[P] := Byte(V); B[P + 1] := Byte(V shr 8); Inc(P, 2);
end;

procedure WriteI32(var B: TBytes; var P: Integer; V: LongInt);
begin
  if Length(B) < P + 4 then SetLength(B, P + 64);
  Move(V, B[P], 4); Inc(P, 4);
end;

procedure WriteBytes(var B: TBytes; var P: Integer; const D: TBytes);
begin
  if Length(D) = 0 then Exit;
  if Length(B) < P + Length(D) then SetLength(B, P + Length(D) + 64);
  Move(D[0], B[P], Length(D)); Inc(P, Length(D));
end;

function EncodeRow(TableId: Word; const Pk: string; const T: TTableDef; const Vals: TStrArray): TBytes;
var
  b: TBytes;
  p: Integer;
  pkB: TBytes;
  i: Integer;
  sv: TBytes;
  iv: Int64;
  fv: Double;
  bv: Byte;
begin
  SetLength(b, 128); p := 0;
  WriteU16(b, p, TableId);
  pkB := VDbS2B(UTF8Encode(Pk));
  WriteU16(b, p, Word(Length(pkB)));
  WriteBytes(b, p, pkB);
  WriteU16(b, p, Word(Length(T.Cols)));
  for i := 0 to High(T.Cols) do
  begin
    if p + 2 > Length(b) then SetLength(b, p + 64);
    b[p] := T.Cols[i].Ctype; Inc(p);
    case T.Cols[i].Ctype of
      VCT_INT:
        if (i < Length(Vals)) and (Vals[i] <> '') and VDbParseInt(Vals[i], iv) then
        begin SetLength(sv, 8); Move(iv, sv[0], 8); WriteI32(b, p, 8); WriteBytes(b, p, sv); end
        else begin WriteI32(b, p, -1); end;
      VCT_FLOAT:
        if (i < Length(Vals)) and (Vals[i] <> '') and VDbParseFloat(Vals[i], fv) then
        begin SetLength(sv, 8); Move(fv, sv[0], 8); WriteI32(b, p, 8); WriteBytes(b, p, sv); end
        else WriteI32(b, p, -1);
      VCT_BOOL:
        begin
          // BOS DEGER = NULL (vlen = -1). Once kontrol etmek gerekiyor:
          // aksi halde NULL satiri 'False' olarak kalici yazilirdi.
          if (i >= Length(Vals)) or (Vals[i] = '') then
            WriteI32(b, p, -1)
          else
          begin
            if SameText(Trim(Vals[i]), 'true') or (Trim(Vals[i]) = '1') then bv := 1
            else bv := 0;
            WriteI32(b, p, 1);
            WriteBytes(b, p, TBytes.Create(bv));
          end;
        end;
    else
      if (i < Length(Vals)) and (Vals[i] <> '') then
      begin
        // VCT_BLOB = ham bayt: kodlama/temizleme YAPILMAZ.
        // Metin kolonlari UTF-8'e normalize edilir; BLOB kolonunda bu
        // gecersiz UTF-8 baytlarini U+FFFD'ye cevirerek JPEG/PNG/exe
        // gibi ikili veriyi bozardi.
        if T.Cols[i].Ctype = VCT_BLOB then
          sv := VDbS2B(Vals[i])
        else
          sv := VDbS2B(UTF8Encode(Vals[i]));
        WriteI32(b, p, Length(sv)); WriteBytes(b, p, sv);
      end
      else WriteI32(b, p, -1);
    end;
  end;
  SetLength(b, p);
  Result := b;
end;

function ReadU16(const B: TBytes; var P: Integer; out V: Word): Boolean;
begin
  Result := P + 2 <= Length(B);
  if Result then begin V := B[P] or (Word(B[P+1]) shl 8); Inc(P, 2); end;
end;

function ReadI32(const B: TBytes; var P: Integer; out V: LongInt): Boolean;
begin
  Result := P + 4 <= Length(B);
  if Result then begin Move(B[P], V, 4); Inc(P, 4); end;
end;

function DecodeRow(const B: TBytes; out TableId: Word; out Pk: string; out Vals: TStrArray): Boolean;
// Satiri kayitli sira ile cozer. Alanlar eski semaya gore yazilmis
// olabilir; ALTER TABLE sirasinda cagricilar SrcCts ile kesisim
// dondurum yapar.
var
  p: Integer;
  pkL, cc, i: Word;
  ct: Byte;
  vl: LongInt;
  iv: Int64;
  fv: Double;
begin
  Result := False;
  p := 0;
  if not ReadU16(B, p, TableId) then Exit;
  if not ReadU16(B, p, pkL) then Exit;
  if p + pkL > Length(B) then Exit;
  Pk := UTF8Decode(VDbB2S(B, p, pkL)); Inc(p, pkL);
  if not ReadU16(B, p, cc) then Exit;
  SetLength(Vals, cc);
  for i := 0 to cc - 1 do
  begin
    if p >= Length(B) then Exit;
    ct := B[p]; Inc(p);
    if not ReadI32(B, p, vl) then Exit;
    if vl = -1 then begin Vals[i] := ''; Continue; end;
    if (vl < 0) or (p + vl > Length(B)) then Exit;
    case ct of
      VCT_INT: begin if vl <> 8 then Exit; Move(B[p], iv, 8); Vals[i] := IntToStr(iv); end;
      VCT_FLOAT: begin if vl <> 8 then Exit; Move(B[p], fv, 8); Vals[i] := VDbFloatToStr(fv); end;
      VCT_BOOL: begin Vals[i] := BoolToStr(B[p] <> 0, True); end;
    else
      if ct = VCT_BLOB then
        Vals[i] := VDbB2S(B, p, vl)          // ham bayt, kodlama yok
      else
        Vals[i] := UTF8Decode(VDbB2S(B, p, vl));
    end;
    Inc(p, vl);
  end;
  Result := True;
end;

function VDbRowTagOf(const PlainValue: TBytes; ValueLen: Integer): Integer;
// R-26 (2026-10-15): KV katmanina verdigimiz TABLO ID cozucusu.
begin
  Result := -1;
  if (ValueLen < 2) or (Length(PlainValue) < 2) then Exit;
  // sema kaydi ('VSCH1') satir degildir; ilk iki bayti rastgele bir
  // tablo id'sine denk gelebilir -> mutlaka -1 yap.
  if (ValueLen >= Length(VDB_SCHEMA_TAG)) and
     (Length(PlainValue) >= Length(VDB_SCHEMA_TAG)) and
     CompareMem(@PlainValue[0], @VDB_SCHEMA_TAG[1], Length(VDB_SCHEMA_TAG)) then
    Exit;
  // ReadU16 ile birebir ayni hesap
  Result := Integer(PlainValue[0]) or (Integer(PlainValue[1]) shl 8);
end;

{ TVTableDb }

constructor TVTableDb.Create(AKv: TVDb);
begin
  inherited Create;
  FKv := AKv;
  // R-26: KV katmanina tablo-id cozucusunu ver. Boylece Recover, zaten
  // CRC icin okudugu her kayittan tablo id'yi bedava cikarir ve tablo
  // taramalari diger tablolarin kayitlarini OKUMAZ.
  AKv.RowTagFunc := @VDbRowTagOf;
  FLock := TCriticalSection.Create;
  FTables := TDictionary<string, TTableDef>.Create;
  FById := TDictionary<Word, string>.Create;
  FMemIdx := TDictionary<Int64, TIdxEntries>.Create;
  FFunctions := TDictionary<string, TFunctionDef>.Create;
  FProcedures := TDictionary<string, TFunctionDef>.Create;
  FTriggers := TDictionary<string, TTriggerDef>.Create;
  FDeferredRows := TList<string>.Create;
  FDeferred := False;
  // R-18: rol/izin kataloglari semada tasinir
  FRoles := TDictionary<string, TRoleDef>.Create;
  FGrants := TList<TGrantDef>.Create;
  FCurrentRole := '';
  FRlsOn := TDictionary<string, Boolean>.Create;   // R-19
  FPolicies := TList<TPolicyDef>.Create;
  FIdxOps := TDictionary<Int64, TList<TIdxOp>>.Create;
  FIdxCtype := TDictionary<Int64, Byte>.Create;
  FIdxUniq := TDictionary<Int64, TDictionary<string, string>>.Create;
  FIdxDirty := TList<Int64>.Create;
  FPkIdx := TDictionary<Word, TIdxEntries>.Create;
  FPkIdxDirty := TDictionary<Word, Boolean>.Create;
  FConcBuilders := TList<TVdbConcRec>.Create;   // R-22 Full
  FSchemaDirty := False;
  FNextId := 1;
  FSnapActive := False;
  FSnapTables := nil;
  FSnapById := nil;
  FSnapNextId := 1;
  FSnapDirty := False;
end;

destructor TVTableDb.Destroy;
begin
  StopConcBuilders;   // R-22: surmekte olan insalar durdurulur (INVALID kalir)
  ClearSchemaSnapshot;
  FreeAllTriggers;   // F-36: govde AST'leri serbest birakilir
  FDeferredRows.Free;   // R-11
  FRoles.Free;          // R-18
  FGrants.Free;
  FRlsOn.Free;          // R-19
  FPolicies.Free;
  FTables.Free;
  FById.Free;
  FFunctions.Free;
  FProcedures.Free;
  FTriggers.Free;
  FMemIdx.Free;
  FreeIdxPend;      // TList'leri serbest birakir
  FIdxOps.Free;
  FIdxCtype.Free;
  FreeIdxUniqMaps;
  FIdxDirty.Free;
  FPkIdx.Free;
  FPkIdxDirty.Free;
  FConcBuilders.Free;   // R-22 Full
  FLock.Free;
  inherited;
end;

procedure TVTableDb.Lock;
begin
  FLock.Enter;
end;

procedure TVTableDb.Unlock;
begin
  FLock.Leave;
end;

function TVTableDb.SchemaPath: string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + 'schema.dat';
end;

procedure TVTableDb.LoadSchema;
var
  sl, parts, cp: TStringList;
  i, j: Integer;
  t: TTableDef;
  s: string;
  b: TBytes;
  raw: RawByteString;

procedure ParseLines(Lines: TStrings);
     var
       li, lj, ci2, k2, k3, kp, kq: Integer;   // F-17: kp = '#' konumu, F-19: kq
       s2, rest: string;
       q1, q2, fl: Integer;
       ixName: string;          // F2-23: UNIQUE oneki ayiklanir
       ixLine: string;          // F-17: #bolunesi ayiklanmis indeks satiri
       ixPred: string;          // F-17: PARTIAL indeks kosulu
       inclTxt: string;         // F-19: INCLUDE listesi metni
       incs: TStrArray;         // F-19: parcalanmis INCLUDE kolonlari
       gs, cs, fs: TStrArray;
       rd: TRoleDef;          // R-18
       kn: string;              // R-19
    gd: TGrantDef;         // R-18
    pd: TPolicyDef;        // R-19
    tq: TTableDef;         // R-13 Full: #Q bolme tanimi
    gi, ci3, fi: Integer;
    c3: TStrArray;
    f3: TStrArray;

  function Split(const X: string; D: Char): TStrArray;
  var
    r, p: string;
    qq: Integer;
  begin
    SetLength(Result, 0);
    r := X;
    while r <> '' do
    begin
      qq := Pos(D, r);
      if qq > 0 then begin p := Copy(r, 1, qq - 1); r := Copy(r, qq + 1, 99999); end
      else begin p := r; r := ''; end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := p;
    end;
  end;

  begin
    for li := 0 to Lines.Count - 1 do
    begin
      s := Trim(Lines[li]);
      if s = '' then Continue;
      // F2-13: BOZUK SATIR sessizce ATLANIYORDU. Sema kaydi tek kayit
      // halinde tutuldugu icin atlanan satir tabloyu/KOLONU/FK'yi
      // kaybolma anlamina geliyor; sonraki INSERT'ler "kolon yok" ile
      // kacar ya daha kotusu sessizce yanlis sonuc uretir. Artik hata.
      // R-18: RBAC satirlari '#R' (rol) ve '#G' (izin) onekiyle gelir.
      // Diger '#' satirlari yorumdur ve atlanir.
      if s[1] = '#' then
      begin
        if (Length(s) > 2) and (s[2] = 'R') and (s[1] = '#') then
        begin
          parts.DelimitedText := s;
          if (parts.Count >= 3) and (CompareText(parts[0], '#R') = 0) then
          begin
            rd.Name := VDbNorm(parts[1]);
            rd.Super := (parts[2] = '1');
            FRoles.AddOrSetValue(rd.Name, rd);
          end;
        end
        else if (Length(s) > 2) and (CompareText(Copy(s, 1, 2), '#G') = 0) then
        begin
          parts.DelimitedText := s;
          if parts.Count >= 4 then
          begin
            gd.Table := VDbNorm(parts[1]);
            gd.Priv := Byte(StrToIntDef(parts[2], 0));
            gd.Role := VDbNorm(parts[3]);
            FGrants.Add(gd);
          end;
        end
        // R-19: #L = tablo adi | RLS acik mi (0/1)
        else if (Length(s) > 2) and (CompareText(Copy(s, 1, 2), '#L') = 0) then
        begin
          parts.DelimitedText := s;
          if parts.Count >= 3 then
          begin
            kn := VDbNorm(parts[1]);
            FRlsOn.Add(kn, parts[2] = '1');  // FPC 3.2.2 ICE workaround: AddOrSetValue -> Add (may raise if exists)
          end;
        end
        // R-19: #P = tablo | politika adi | cmd | using(hex) | check(hex)
        else if (Length(s) > 2) and (CompareText(Copy(s, 1, 2), '#P') = 0) then
        begin
          parts.DelimitedText := s;
          if parts.Count >= 5 then
          begin
            pd.Table := VDbNorm(parts[1]);
            pd.Name := VDbNorm(parts[2]);
            pd.Cmd := Byte(StrToIntDef(parts[3], 0));
            pd.UsingText := HexFld(parts[4]);
            pd.CheckText := HexFld(parts[5]);
            FPolicies.Add(pd);
          end;
        end
        // R-13 Full: #Q = tablo | bolme tipi | kolon | hex degerler (virgulle).
        // Tablo satiri (#Q'den once yazilir) zaten islendigi icin burada
        // tanim GUNCELLENIR. Eski semalarda #Q yoktur -> bolunmemis kalir.
        else if (Length(s) > 2) and (CompareText(Copy(s, 1, 2), '#Q') = 0) then
        begin
          parts.DelimitedText := s;
          if parts.Count >= 4 then
          begin
            tq := Default(TTableDef);
            if FTables.TryGetValue(VDbNorm(parts[1]), tq) then
            begin
              tq.PartType := UpperCase(parts[2]);
              tq.PartCol := VDbNorm(parts[3]);
              SetLength(tq.PartVals, 0);
              if parts.Count >= 5 then
              begin
                cp.DelimitedText := parts[4];
                for lj := 0 to cp.Count - 1 do
                  if cp[lj] <> '' then
                  begin
                    SetLength(tq.PartVals, Length(tq.PartVals) + 1);
                    tq.PartVals[High(tq.PartVals)] := HexFld(cp[lj]);
                  end;
              end;
              FTables.AddOrSetValue(VDbNorm(parts[1]), tq);
            end;
          end;
        end;
        Continue;
      end;
      parts.DelimitedText := s;
      if parts.Count < 5 then
        raise EVDbException.CreateFmt(ecSchemaCorrupt,
          'VDb: sema kaydi bozuk (satir %d, beklenen >=5 alan, bulunan %d): %s',
          [li + 1, parts.Count, Copy(s, 1, 60)]);
      if not TryStrToInt(parts[0], k2) then
        raise EVDbException.CreateFmt(ecSchemaCorrupt,
          'VDb: sema kaydi tablo kimligi sayi degil (satir %d): %s',
          [li + 1, Copy(parts[0], 1, 30)]);
      // R-17/load fix: yerel kayit TAM sifirlanmali. Aksi halde IsView /
      // IsMaterializedView / SelectStmt / FRowEstimate gibi yonetilmeyen
      // alanlar YIGIN COPU tasir; reopen sonrasi normal tablo yanlislikla
      // "view" sayilir ("view tanimi ayristirilamadi veya bos: <tablo>").
      t := Default(TTableDef);
      t.TableId := Word(StrToIntDef(parts[0], 0));
      t.Name := VDbNorm(parts[1]);
      t.PkIndex := StrToIntDef(parts[2], -1);
      t.AutoInc := StrToInt64Def(parts[3], 0);
      cp.DelimitedText := parts[4];
      SetLength(t.Cols, cp.Count);
      for lj := 0 to cp.Count - 1 do
      begin
        // ad:tip[:bayrak[:hexdef]] (bayrak bit0=NOT NULL, bit1=UNIQUE)
        t.Cols[lj].NotNull := False;
        t.Cols[lj].Unique := False;
        t.Cols[lj].HasDef := False;
        t.Cols[lj].Def := '';
        t.Cols[lj].Collate := '';   // R-20
        if Pos(':', cp[lj]) > 0 then
        begin
          s2 := cp[lj];
          q1 := Pos(':', s2);
          t.Cols[lj].Name := VDbNorm(Copy(s2, 1, q1 - 1));
          rest := Copy(s2, q1 + 1, 999);
          q2 := Pos(':', rest);
          if q2 > 0 then
          begin
            t.Cols[lj].Ctype := Byte(StrToIntDef(Copy(rest, 1, q2 - 1), 2));
            rest := Copy(rest, q2 + 1, 999);
            q2 := Pos(':', rest);
            if q2 > 0 then
            begin
              fl := StrToIntDef(Copy(rest, 1, q2 - 1), 0);
              rest := Copy(rest, q2 + 1, 9999);
              q1 := Pos(':', rest);
              if q1 > 0 then
              begin
                // R-20: ad:tip:bayrak:hexdef:collation
                // hexdef BOS olabilir (varsayilan deger yok, collation var)
                if q1 > 1 then
                begin
                  t.Cols[lj].HasDef := True;
                  t.Cols[lj].Def := string(VDbUnhex(Copy(rest, 1, q1 - 1)));
                end;
                t.Cols[lj].Collate := Copy(rest, q1 + 1, 999);
              end
              else
              begin
                // eski bicim: ad:tip:bayrak:hexdef
                t.Cols[lj].HasDef := True;
                t.Cols[lj].Def := string(VDbUnhex(rest));
              end;
            end
            else
              fl := StrToIntDef(rest, 0);
            t.Cols[lj].NotNull := (fl and 1) <> 0;
            t.Cols[lj].Unique := (fl and 2) <> 0;
          end
          else
            t.Cols[lj].Ctype := Byte(StrToIntDef(rest, 2));
        end
        else begin t.Cols[lj].Name := VDbNorm(cp[lj]); t.Cols[lj].Ctype := VCT_STR; end;
      end;
      // 6. bolum: indexler (yoksa bos, eski kataloglarla uyumlu)
      SetLength(t.Idx, 0);
      if parts.Count >= 6 then
      begin
        cp.DelimitedText := parts[5];
        for lj := 0 to cp.Count - 1 do
          if Pos(':', cp[lj]) > 0 then
          begin
            // "ad:kolon1[:kolon2...][#hex(predicate)][|hex(expr)]" -> indeks
            // F2-23: "!" oneki UNIQUE bayragini tasir (yoksa UNIQUE degil).
            // F-17: sondaki "#hex(...)" PARTIAL indeks kosulunu tasir.
            // F-18: onundaki "|hex(...)" EXPRESSION indeksini tasir.
            SetLength(t.Idx, Length(t.Idx) + 1);
            ixLine := cp[lj];
            ixPred := '';
            // F-17: sondaki "#hex(...)" PARTIAL indeks kosulunu tasir.
            // (F-18 ifade indeksi ':' sonrasinda '@' onekiyle DUZ metin
            //  olarak saklanir; desteklenen ifade dilinde ':', '#' ve '|'
            //  karakterleri geciemedigi icin hex'e gerek yoktur.)
            kp := Pos('#', ixLine);
            if kp > 0 then
            begin
              ixPred := VDbUnhex(Copy(ixLine, kp + 1, MaxInt));
              ixLine := Copy(ixLine, 1, kp - 1);
            end;
            ixName := Copy(ixLine, 1, Pos(':', ixLine) - 1);
            t.Idx[High(t.Idx)].Uniq := (Copy(ixName, 1, 1) = '!');
            if t.Idx[High(t.Idx)].Uniq then
              ixName := Copy(ixName, 2, MaxInt);
            // R-22 Full: '!' sonrasi '?' oneki INVALID bayragini tasir
            // (concurrent insa yarida kalmis / suruyor).
            t.Idx[High(t.Idx)].Invalid := (Copy(ixName, 1, 1) = '?');
            if t.Idx[High(t.Idx)].Invalid then
              ixName := Copy(ixName, 2, MaxInt);
            t.Idx[High(t.Idx)].Name := VDbNorm(ixName);
            t.Idx[High(t.Idx)].Predicate := ixPred;   // F-17
            SetLength(t.Idx[High(t.Idx)].Cols, 0);
            t.Idx[High(t.Idx)].ExprText := '';        // F-18
            t.Idx[High(t.Idx)].Incl := nil;          // F-19
            // F-19: '$' ile INCLUDE listesi. Once '#'(predicate) ayrildi;
            // ifade indeksi ise ':@' ile baslar ve INCLUDE tasimaz.
            kp := Pos('$', ixLine);
            if kp > 0 then
            begin
              inclTxt := Copy(ixLine, kp + 1, MaxInt);
              ixLine := Copy(ixLine, 1, kp - 1);
              if inclTxt <> '' then
              begin
                incs := Split(inclTxt, ';');
                for kq := 0 to High(incs) do
                  if incs[kq] <> '' then
                  begin
                    ci2 := FindCol(t, incs[kq]);
                    if ci2 >= 0 then
                    begin
                      SetLength(t.Idx[High(t.Idx)].Incl,
                        Length(t.Idx[High(t.Idx)].Incl) + 1);
                      t.Idx[High(t.Idx)].Incl[
                        High(t.Idx[High(t.Idx)].Incl)] := ci2;
                    end;
                  end;
              end;
            end;
            k2 := Pos(':', ixLine);
            if (k2 > 0) and (Copy(ixLine, k2 + 1, 1) = '@') then
            begin
              // F-18: ifade indeksi — kolon listesini cozmeye calisma
              t.Idx[High(t.Idx)].ExprText :=
                Copy(ixLine, k2 + 2, MaxInt);
              t.Idx[High(t.Idx)].Col := -1;
            end
            else
            begin
              while k2 > 0 do
              begin
                k3 := Pos(':', ixLine, k2 + 1);
                if k3 > 0 then
                  ci2 := FindCol(t, Copy(ixLine, k2 + 1, k3 - k2 - 1))
                else
                  ci2 := FindCol(t, Copy(ixLine, k2 + 1, 999));
                if ci2 >= 0 then
                begin
                  SetLength(t.Idx[High(t.Idx)].Cols,
                    Length(t.Idx[High(t.Idx)].Cols) + 1);
                  t.Idx[High(t.Idx)].Cols[High(t.Idx[High(t.Idx)].Cols)] := ci2;
                end;
                k2 := k3;
              end;
              if Length(t.Idx[High(t.Idx)].Cols) > 0 then
                t.Idx[High(t.Idx)].Col := t.Idx[High(t.Idx)].Cols[0]
              else
                // taninmayan kolon: bu indeksi at
                SetLength(t.Idx, Length(t.Idx) - 1);
            end;
          end;
      end;
      // 7. bolum: checks (grup;grup / kosul&kosul / col,op,hexval)
      SetLength(t.Checks, 0);
      if parts.Count >= 7 then
      begin
        gs := Split(parts[6], ';');
        for gi := 0 to High(gs) do
        begin
          if gs[gi] = '' then Continue;
          cs := Split(gs[gi], '&');
          SetLength(t.Checks, Length(t.Checks) + 1);
          SetLength(t.Checks[High(t.Checks)], Length(cs));
          for ci3 := 0 to High(cs) do
          begin
            c3 := Split(cs[ci3], ',');
            if Length(c3) <> 3 then
              raise EVDbException.Create(ecSchemaCorrupt, 'katalog checks bozuk');
            t.Checks[High(t.Checks)][ci3].Col := StrToIntDef(c3[0], -1);
            t.Checks[High(t.Checks)][ci3].Op := c3[1];
            t.Checks[High(t.Checks)][ci3].Val := string(VDbUnhex(c3[2]));
            if (t.Checks[High(t.Checks)][ci3].Col < 0) or
               (t.Checks[High(t.Checks)][ci3].Col >= Length(t.Cols)) then
              raise EVDbException.Create(ecSchemaCorrupt, 'katalog checks kolon disi');
            // tip semada saklanmaz; kolon tanimindan turetilir
            t.Checks[High(t.Checks)][ci3].Ctype := t.Cols[t.Checks[High(t.Checks)][ci3].Col].Ctype;
          end;
        end;
      end;
      // 8. bolum: fk (col:reftable:refcol,...)
      SetLength(t.Fks, 0);
      if parts.Count >= 8 then
      begin
        fs := Split(parts[7], ',');
        for fi := 0 to High(fs) do
        begin
          if fs[fi] = '' then Continue;
          f3 := Split(fs[fi], ':');
          // 3 alan (eski), 5 alan (ondelete:onupdate) veya
          // 6 alan (+deferrable, R-11) kabul edilir
          if (Length(f3) <> 3) and (Length(f3) <> 5) and (Length(f3) <> 6) then
            raise EVDbException.Create(ecSchemaCorrupt, 'katalog fk bozuk');
          SetLength(t.Fks, Length(t.Fks) + 1);
          t.Fks[High(t.Fks)].Col := StrToIntDef(f3[0], -1);
          t.Fks[High(t.Fks)].RefTable := VDbNorm(f3[1]);
          t.Fks[High(t.Fks)].RefCol := VDbNorm(f3[2]);
          if Length(f3) >= 5 then
          begin
            t.Fks[High(t.Fks)].OnDelete := VDbFkAction(f3[3]);
            t.Fks[High(t.Fks)].OnUpdate := VDbFkAction(f3[4]);
          end
          else
          begin
            t.Fks[High(t.Fks)].OnDelete := VDB_FK_RESTRICT;
            t.Fks[High(t.Fks)].OnUpdate := VDB_FK_RESTRICT;
          end;
          // R-11: 6. alan yoksa 0 (= NOT DEFERRABLE), eski sema korunur.
          t.Fks[High(t.Fks)].Deferrable := 0;
          if Length(f3) >= 6 then
            t.Fks[High(t.Fks)].Deferrable := Byte(StrToIntDef(f3[5], 0));
          if (t.Fks[High(t.Fks)].Col < 0) or
             (t.Fks[High(t.Fks)].Col >= Length(t.Cols)) then
            raise EVDbException.Create(ecSchemaCorrupt, 'katalog fk kolon disi');
        end;
      end;
      FTables.AddOrSetValue(t.Name, t);
      FById.AddOrSetValue(t.TableId, t.Name);
      if t.TableId >= FNextId then FNextId := t.TableId + 1;
    end;
  end;

begin
  FTables.Clear; FById.Clear; FNextId := 1;
  SetLength(FIntentDrop, 0);
  sl := TStringList.Create; parts := TStringList.Create; cp := TStringList.Create;
  try
    parts.Delimiter := '|'; parts.StrictDelimiter := True;
    cp.Delimiter := ','; cp.StrictDelimiter := True;
    // 1) katalog .odb icinde mi?
    if FKv.Get(VDB_SCHEMA_KEY, b) and (Length(b) > Length(VDB_SCHEMA_TAG)) then
    begin
      SetLength(raw, Length(b));
      Move(b[0], raw[1], Length(b));
      if Copy(raw, 1, Length(VDB_SCHEMA_TAG)) = VDB_SCHEMA_TAG then
      begin
        sl.Text := Copy(raw, Length(VDB_SCHEMA_TAG) + 2, MaxInt);
        ParseLines(sl);
        Exit;
      end;
    end;
    // 2) eski surum tasiyici: schema.dat varsa ice aktar
    if not FileExists(SchemaPath) then Exit;
    sl.LoadFromFile(SchemaPath);
    ParseLines(sl);
    SaveSchema; // .odb icine yaz
    DeleteFile(SchemaPath); // tek dosya kalsin
  finally
    sl.Free; parts.Free; cp.Free;
  end;
end;

procedure TVTableDb.SaveSchema;
var
  sl: TStringList;
  kv: TPair<string, TTableDef>;
  rv: TPair<string, TRoleDef>;   // R-18
  lv: TPair<string, Boolean>;     // R-19
  s, si, sc, sf: string;
  fl: Integer;
  i, j: Integer;
  raw: RawByteString;
  b: TBytes;
  order: TStrArray;      // TableId'e gore sirali tablo adlari
  n: TStrArray;
  nm: string;
  t: TTableDef;
  k, m: Integer;

  function FkAct(const S: string): string;
  // Bos/bozuk degerler RESTRICT olur (geriye uyum).
  begin
    if S = '' then Result := VDB_FK_RESTRICT else Result := S;
  end;

  function Bool01(B: Boolean): string;
  begin
    if B then Result := '1' else Result := '0';
  end;
begin
  // Guvenlik on kontrolu: bildigimiz tablolardan biri kaybolmus olabilir.
  GuardSchemaLoss;
  // SEMA SIRASI SABIT OLMALI. TDictionary uzerinde dogrudan dolasma
  // kararsiz sirada yaziyordu: ayni sema iki farkli .odb uretebiliyordu
  // (diff/otomatik test kararliligi bozulur). TableId sirasi kanonik.
  SetLength(n, FTables.Count);
  k := 0;
  for nm in FTables.Keys do begin n[k] := nm; Inc(k); end;
  SetLength(order, Length(n));
  for k := 0 to High(n) do
    if FTables.TryGetValue(n[k], t) then order[k] := IntToStr(t.TableId) + #1 + n[k]
    else order[k] := '999999' + #1 + n[k];
  VDbSortStrs(order);
  sl := TStringList.Create;
  try
    for k := 0 to High(order) do
    begin
      nm := Copy(order[k], Pos(#1, order[k]) + 1, 999);
      if not FTables.TryGetValue(nm, t) then Continue;
      kv.Key := nm; kv.Value := t;
      s := '';
      for i := 0 to High(kv.Value.Cols) do
      begin
        if i > 0 then s := s + ',';
        fl := 0;
        if kv.Value.Cols[i].NotNull then fl := fl or 1;
        if kv.Value.Cols[i].Unique then fl := fl or 2;
        s := s + kv.Value.Cols[i].Name + ':' + IntToStr(kv.Value.Cols[i].Ctype) +
          ':' + IntToStr(fl);
        { R-20: collation 5. alan (ad:tip:bayrak:hexdef:collation).
          DIKKAT: 4. alan (hexdef) dolu olmasa bile BOS AYIRAC yazilir;
          aksi halde okuma tarafi 5. alani hexdef sanar ve "hex bozuk"
          hatasi verir. Eski 3 alanli bicim geriye uyumlu kalir. }
        if kv.Value.Cols[i].Collate <> '' then
        begin
          if kv.Value.Cols[i].HasDef then
            s := s + ':' + VDbHex(kv.Value.Cols[i].Def)
          else
            s := s + '::';
          s := s + kv.Value.Cols[i].Collate;
        end
        else if kv.Value.Cols[i].HasDef then
          s := s + ':' + VDbHex(kv.Value.Cols[i].Def);
      end;
      si := '';
      for i := 0 to High(kv.Value.Idx) do
      begin
        if i > 0 then si := si + ',';
        // "ad:kolon1:kolon2:..."  (tek kolonlu = eski bicimle ayni,
        // geriye uyumlu)
        // F2-23: UNIQUE indeksler "!" onekiyle yazilir.
        // F-17: PARTIAL indeksler "#" onekiyle yazilir; ardindan adi
        // gelmeden ONCE degil, sonra hex(predicate) eklenir:
        //   ix:col#<hex(kosul)>   (yoksa = normal indeks)
        if kv.Value.Idx[i].Uniq then si := si + '!';
        // R-22 Full: INVALID indeksler '?' onekiyle yazilir (concurrent
        // insa yarida kalmis / suruyor). Okuma tarafinda '!' sonrasi
        // ayristirilir.
        if kv.Value.Idx[i].Invalid then si := si + '?';
        si := si + kv.Value.Idx[i].Name;
        if kv.Value.Idx[i].ExprText <> '' then
          // F-18: ifade indeksi — kolon listesi yok, dogrudan ifade yazilir
          si := si + ':@' + kv.Value.Idx[i].ExprText
        else if Length(kv.Value.Idx[i].Cols) = 0 then
          si := si + ':' + kv.Value.Cols[kv.Value.Idx[i].Col].Name
        else
          for j := 0 to High(kv.Value.Idx[i].Cols) do
            si := si + ':' + kv.Value.Cols[kv.Value.Idx[i].Cols[j]].Name;
        // F-19: INCLUDE kolonlari '$' ile, ';' ayiracli liste olarak. '$' secildi
        // cunku ifade indeksi metni '+' ICEREBILIR ((n + 1)); ',' ise sema satirinin
        // KOLON LISTESI ayiracidir, hex predicate ise yalniz 0-9A-F kullanir.
        if Length(kv.Value.Idx[i].Incl) > 0 then
        begin
          si := si + '$';
          for j := 0 to High(kv.Value.Idx[i].Incl) do
          begin
            if j > 0 then si := si + ';';
            if (kv.Value.Idx[i].Incl[j] >= 0) and
               (kv.Value.Idx[i].Incl[j] < Length(kv.Value.Cols)) then
              si := si + kv.Value.Cols[kv.Value.Idx[i].Incl[j]].Name;
          end;
        end;
        // DIKKAT: yazma sirasi OKUMA sirasiyla ayni olmak ZORUNDA —
        // once '#' predicate, sonra '$' INCLUDE ayrilir. Ters sirada
        // '$' listesi hex'in icinde kalir ve "hex uzunlugu tek" olur.
        if kv.Value.Idx[i].Predicate <> '' then
          si := si + '#' + VDbHex(kv.Value.Idx[i].Predicate);
      end;
      sc := '';
      for i := 0 to High(kv.Value.Checks) do
      begin
        if i > 0 then sc := sc + ';';
        for j := 0 to High(kv.Value.Checks[i]) do
        begin
          if j > 0 then sc := sc + '&';
          sc := sc + IntToStr(kv.Value.Checks[i][j].Col) + ',' +
            kv.Value.Checks[i][j].Op + ',' + VDbHex(kv.Value.Checks[i][j].Val);
        end;
      end;
      sf := '';
      for i := 0 to High(kv.Value.Fks) do
      begin
        if i > 0 then sf := sf + ',';
        // col:reftable:refcol:ondelete:onupdate[:deferrable]
        // 3 veya 5 alanli eski yazim geriye uyumlu kalir: LoadSchema
        // eksik alanlari sirayla RESTRICT / 0 doldurur.
        sf := sf + IntToStr(kv.Value.Fks[i].Col) + ':' +
          kv.Value.Fks[i].RefTable + ':' + kv.Value.Fks[i].RefCol + ':' +
          FkAct(kv.Value.Fks[i].OnDelete) + ':' + FkAct(kv.Value.Fks[i].OnUpdate) +
          ':' + IntToStr(kv.Value.Fks[i].Deferrable);
      end;
      sl.Add(Format('%d|%s|%d|%d|%s|%s|%s|%s', [kv.Value.TableId, kv.Value.Name, kv.Value.PkIndex, kv.Value.AutoInc, s, si, sc, sf]));
      // R-13 Full: bolme tanimi ayri '#Q' satirinda (R-18/R-19 deseni;
      // eski semalar bu satiri icermedigi icin geriye uyumludur).
      // Degerler hex kodlanir (bosluk/ayrac guvenligi).
      if kv.Value.PartType <> '' then
      begin
        s := '';
        for i := 0 to High(kv.Value.PartVals) do
        begin
          if i > 0 then s := s + ',';
          s := s + HexEncFld(kv.Value.PartVals[i]);
        end;
        sl.Add('#Q|' + kv.Value.Name + '|' + kv.Value.PartType + '|' +
          kv.Value.PartCol + '|' + s);
      end;
    end;
    // ---- R-18: ROLES / GRANTS (ayri satirlar, '#R' ve '#G' oneki) ----
    // Tablo satirlari 8 alanli '|' ile ayrilir; RBAC satirlari farkli
    // sayida alan icerir. LoadSchema oneke bakarak ayirt eder; boylece
    // eski sema dosyalari (RBAC satiri icermeyen) aynen okunur.
    if FRoles.Count > 0 then
      for rv in FRoles do
        sl.Add('#R|' + rv.Key + '|' + Bool01(rv.Value.Super));
    for i := 0 to FGrants.Count - 1 do
      sl.Add('#G|' + FGrants[i].Table + '|' + IntToStr(FGrants[i].Priv) +
            '|' + FGrants[i].Role);
    // ---- R-19: RLS ('#L') ve politikalar ('#P') ----
    if FRlsOn.Count > 0 then
      for lv in FRlsOn do
        if lv.Value then
          sl.Add('#L|' + lv.Key + '|1');
    for i := 0 to FPolicies.Count - 1 do
      sl.Add('#P|' + FPolicies[i].Table + '|' + FPolicies[i].Name + '|' +
            IntToStr(FPolicies[i].Cmd) + '|' +
            HexEncFld(FPolicies[i].UsingText) + '|' +
            HexEncFld(FPolicies[i].CheckText));
    raw := VDB_SCHEMA_TAG + sLineBreak + sl.Text;
    SetLength(b, Length(raw));
    if Length(raw) > 0 then Move(raw[1], b[0], Length(raw));
    FKv.Put(VDB_SCHEMA_KEY, b);
    // batch icindeyse tek fsync CommitBatch'te olur, burada Flush yok
    if not FKv.InBatch then
      FKv.Flush;
  finally
    sl.Free;
  end;
  FSchemaDirty := False;
  // F2-7: "bu tablo kasitli silindi" isaretleri (FIntentDrop) basariyla
  // yazilmis semadan SONRA temizlenir. Once temizlenmiyordu: liste
  // sonsuza dek birikiyor ve ayni adli tablo YENIDEN olusturulduktan
  // sonra yanlislikla kaybolursa GuardSchemaLoss onu "kasitli silinmis"
  // sayip KORUMAYI DEVRE DISI BIRAKIYORDU (sema clobber korumasi sessizce
  // etkisizlesiyordu).
  // Batch icindeyse yazma henuz kalici degil; temizlik CommitBatch'te
  // yapilir. AbortBatch'te ise isaretler KALIR (durus gerceklesmedi).
  if not FKv.InBatch then
    SetLength(FIntentDrop, 0);
end;

procedure TVTableDb.IntentDrop(const Name: string);
begin
  SetLength(FIntentDrop, Length(FIntentDrop) + 1);
  FIntentDrop[High(FIntentDrop)] := VDbNorm(Name);
end;

function TVTableDb.IntentHas(const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(FIntentDrop) do
    if VDbNorm(FIntentDrop[i]) = VDbNorm(Name) then Exit(True);
end;

procedure TVTableDb.GuardSchemaLoss;
// Sema tek kayit oldugu icin "son yazan kazanir". Sema yanlis yuklenmis
// bir oturum yazma ile diger tum tablolari kalici olarak siler.
//
// Referans BELLEKTEKI liste degil, DISKTEKI semadir: boylece sema hic
// yuklenmemis ya da eksik yuklenmis bir oturum da yakalanir.
var
  b: TBytes;
  raw: RawByteString;
  sl, parts: TStringList;
  i, nDisk, nLost: Integer;
  diskNames, lost: TStrArray;
  s: string;
begin
  SetLength(diskNames, 0);
  nDisk := 0;
  if FKv.Get(VDB_SCHEMA_KEY, b) and (Length(b) > Length(VDB_SCHEMA_TAG)) then
  begin
    SetLength(raw, Length(b));
    Move(b[0], raw[1], Length(b));
    if Copy(raw, 1, Length(VDB_SCHEMA_TAG)) = VDB_SCHEMA_TAG then
    begin
      sl := TStringList.Create;
      parts := TStringList.Create;
      try
        parts.Delimiter := '|'; parts.StrictDelimiter := True;
        sl.Text := Copy(raw, Length(VDB_SCHEMA_TAG) + 2, MaxInt);
        for i := 0 to sl.Count - 1 do
        begin
          s := Trim(sl[i]);
          if s = '' then Continue;
          // R-18: '#' ile baslayan satirlar yorum/rol/izin satirlari,
          // tablo tanimi DEGILDIR. GuardSchemaLoss bunlari saymamali.
          if (Length(s) > 0) and (s[1] = '#') then Continue;
          parts.DelimitedText := sl[i];
          if parts.Count < 2 then Continue;
          SetLength(diskNames, nDisk + 1);
          diskNames[nDisk] := VDbNorm(parts[1]);
          Inc(nDisk);
        end;
      finally
        sl.Free;
        parts.Free;
      end;
    end;
  end;
  if nDisk = 0 then Exit;          // diskte sema yok: koruma gerekmez
  nLost := 0;
  SetLength(lost, 0);
  for i := 0 to nDisk - 1 do
    if (not FTables.ContainsKey(diskNames[i])) and
       (not IntentHas(diskNames[i])) then
    begin
      SetLength(lost, nLost + 1);
      lost[nLost] := diskNames[i];
      Inc(nLost);
    end;
  if nLost = 0 then Exit;
  s := '';
  for i := 0 to nLost - 1 do
  begin
    if i > 0 then s := s + ', ';
    s := s + lost[i];
  end;
  raise EVDbException.CreateFmt(ecSchemaCorrupt, 
    'sema yazimi reddedildi: diskteki %d tablodan %d tanesi listeden ' +
    'kayboldu (%s). Bunlar DROP TABLE / RENAME TABLE ile kaldirilmamisti. ' +
    'Sema TEK kayit oldugu icin yazmak diger tablolari da kalici olarak ' +
    'silerdi. Sema hasarini geri almak icin .odb.bak dosyasini geri alin.',
    [nDisk, nLost, s]);
end;

procedure TVTableDb.MarkSchema;
begin
  if FKv.InBatch then
    FSchemaDirty := True
  else
    SaveSchema;
end;

procedure TVTableDb.SnapshotSchema;
// Batch basinda sema yedegi al. AbortBatch bunu geri yukleyecek,
// boylece ROLLBACK DDL'yi de geri alir.
var
  kvT: TPair<string, TTableDef>;
  kvI: TPair<Word, string>;
begin
  ClearSchemaSnapshot;
  FSnapActive := True;
  FSnapDirty := FSchemaDirty;
  FSnapNextId := FNextId;
  FSnapTables := TDictionary<string, TTableDef>.Create;
  FSnapById := TDictionary<Word, string>.Create;
  for kvT in FTables do
    FSnapTables.AddOrSetValue(kvT.Key, kvT.Value);
  for kvI in FById do
    FSnapById.AddOrSetValue(kvI.Key, kvI.Value);
end;

procedure TVTableDb.RestoreSchemaSnapshot;
// Yalnizca FSnapActive ise etkili; AbortBatch cagrisinda kullanilir.
var
  kvT: TPair<string, TTableDef>;
  kvI: TPair<Word, string>;
begin
  if not FSnapActive then Exit;
  FTables.Clear;
  FById.Clear;
  for kvT in FSnapTables do
    FTables.AddOrSetValue(kvT.Key, kvT.Value);
  for kvI in FSnapById do
    FById.AddOrSetValue(kvI.Key, kvI.Value);
  FNextId := FSnapNextId;
  FSchemaDirty := FSnapDirty;
  // ROLLBACK: tablo geri geliyor, o yuzden intent listesini temizle
  // (yoksa "kaybolmus tablo" sanilip yazma reddedilirdi).
  SetLength(FIntentDrop, 0);
  ClearSchemaSnapshot;
end;

procedure TVTableDb.ClearSchemaSnapshot;
begin
  FSnapActive := False;
  FreeAndNil(FSnapTables);
  FreeAndNil(FSnapById);
end;

procedure TVTableDb.Open(const Dir: string);
begin
  FDir := IncludeTrailingPathDelimiter(Dir);
  LoadSchema;
  { R-11: COMMIT oncesi ertelenmis kisit denetimini VDb'ye bagla.
    Buraya baglanmazsa `SET CONSTRAINTS ALL DEFERRED` sonrasi FK
    ihlaleri hicbir zaman denetlenmez ve bozuk veri kalici olur. }
  FCommitHook := DoCheckDeferred;
  FKv.SetBeforeCommit(FCommitHook);
  // Indeksler BURADA kurulmaz (tembel): ilk okumada TryGetMemIndex
  // veriden kurar. 95.000 satirlik tabloda dosya acilisi 4,5 sn -> ~0 ms.
end;

procedure TVTableDb.BeginBatch;
begin
  // DDL (CREATE/DROP TABLE, INDEX) batch icinde yapilabilsin diye sema
  // yedegi alinir; AbortBatch bunu geri yukler. Aksi halde ROLLBACK
  // sonrasi tablo hem diskte hem bellekte kalirdi.
  SnapshotSchema;
  FKv.BeginBatch;
end;

procedure TVTableDb.CommitBatch;
begin
  if FSchemaDirty then
    SaveSchema; // batch icine yazilir, tek fsync commit'te
  FKv.CommitBatch;
  ClearSchemaSnapshot;
  // F2-7: Sema kalici olarak yazildi; "kasitli silindi" isaretleri artik
  // gerekli degil. Temizlenmezse GuardSchemaLoss sonraki gercek kayiplari
  // (koruma) sessizce atlar.
  SetLength(FIntentDrop, 0);
end;

procedure TVTableDb.AbortBatch;
// KV tamponu atilir; o sirada bellege islenmis index degisiklikleri
// veriden yeniden kurulur (abort nadir, maliyet onemsiz).
// DDL varsa sema yedegi de geri yuklenir.
var
  kv: TPair<string, TTableDef>;
  j: Integer;
begin
  // R-22 Full: geri alma tum indeksleri VERIDEN yeniden kurar; surmekte
  // olan CONCURRENTLY insalari da bu noktada iptal edilir (sonuctan
  // vazgec: indeks INVALID kalir). Bekleyen islemler islem isaretli
  // olmadigindan ayirt edilemez; iptal tek GUVENLI secenektir.
  StopConcBuilders;
  FKv.AbortBatch;
  // R-11: geri alinan islemde ertelenen satirlar da gecerlidir artik;
  // COMMIT'e kadar bekleyen liste TEMIZLENMEZSE sonraki gercek
  // COMMIT'te "satir kayboldu" hatasi verir (rollback edilmis bir
  // satiri denetlemeye calisir).
  FDeferredRows.Clear;
  RestoreSchemaSnapshot;
  for kv in FTables do
    for j := 0 to High(kv.Value.Idx) do
      if not kv.Value.Idx[j].Invalid then   // R-22: INVALID indeks kurulmaz
        BuildOneIndex(kv.Value, j);
end;

procedure TVTableDb.Close;
begin
  // sayaclari kalici yap; Close asla patlamaz
  try
    if FSchemaDirty then
      SaveSchema;
  except
  end;
  // R-22 Full: surmekte olan CONCURRENTLY insalari IPTAL edilir (sonuctan
  // vazgecilir; indeks INVALID kalir — PostgreSQL'deki yarida kalan insa
  // gibi). Insa bellek-icidir: yeniden acilista devam ETMEZ; indeks ya
  // DROP edilir ya da yeniden CREATE edilir.
  StopConcBuilders;
  // F-36: tetikleyici govdeleri AST nesnesidir; Close ile serbest
  // birakilmazsa yeniden acilan oturumda ayni AST'ye erisilir.
  ClearTriggers;
end;

function TVTableDb.FindCol(const T: TTableDef; const Col: string): Integer;
var
  i: Integer;
  n: string;
begin
  n := VDbNorm(Col);
  for i := 0 to High(T.Cols) do
    if T.Cols[i].Name = n then Exit(i);
  Result := -1;
end;

procedure TVTableDb.CheckConstraints(const T: TTableDef; var Vals: TStrArray; const ExcludePk: string);
// Tip dogrula (+tarih normallestir), NOT NULL ve UNIQUE denetle.
// UNIQUE'te ayni satir (ExcludePk) sayilmaz; bos (=NULL) degerler sayilmaz.
//
// ONCE YAVAS YOL: UNIQUE denetimi SIRALI indeks dizisini okuyordu; dizi
// kirliyse once FlushIdxPending calisiyor ve 20.000 satirlik toplu yazmada
// HER INSERT tum diziyi yeniden siraliyordu (27 ms/satir = 9 dakika).
//
// SIMDI: UNIQUE kolonlar icin nedensel tutulan "deger -> sahip pk" haritasi
// (FIdxUniq) kullanilir -> O(1), siralamayi TETIKLEMEZ. Harita yoksa
// eski yola dusulur.
var
  i, k: Integer;
  e: TIdxEntries;
  hasIdx: Boolean;
  lo, hi: Integer;
  ikey: string;              // F2-23: UNIQUE bilesik indeks anahtari
  rkey: string;             // F-18: ifade UNIQUE karsilastirma anahtari
  eCtype: Byte;             // F-18
  icols: TIntArray;          // F2-23: indeks kolonlari
  pks: TStrArray;
  rows: TStrMatrix;
  ik: Int64;
  um: TDictionary<string, string>;
  sahip: string;
begin
  for i := 0 to High(T.Cols) do
  begin
    if Vals[i] <> '' then
      Vals[i] := VDbNormValue(T.Cols[i].Ctype, Vals[i]);
    if T.Cols[i].NotNull and (Vals[i] = '') then
      raise EVDbException.Create(ecNotNullViolation, 'NOT NULL ihlali: ' + T.Cols[i].Name);
    // R-13 Full: bolme anahtari NULL olamaz (hangi bolume dusecegi
    // hesaplanamazdi). INSERT ve UPDATE yollari CheckConstraints'ten
    // gectigi icin tek noktada denetlenir.
    if (T.PartType <> '') and (T.Cols[i].Name = T.PartCol) and (Vals[i] = '') then
      raise EVDbException.Create(ecNotNullViolation,
        'partition anahtari NULL olamaz: ' + T.PartCol);
    if T.Cols[i].Unique and (Vals[i] <> '') then
    begin
      // hizli yol: deger -> sahip pk haritasi
      ik := IdxKey(T.TableId, i);
      if FIdxUniq.TryGetValue(ik, um) then
      begin
        if um.TryGetValue(Vals[i], sahip) and (sahip <> ExcludePk) then
          raise EVDbException.Create(ecUniqueViolation, 'UNIQUE ihlali: ' + T.Cols[i].Name);
        Continue;
      end;
      // harita henuz kurulmadiysa kur ve tekrar dene
      // R-22: INVALID indeks (concurrent insa) kurulMAZ -> asagiya tam
      // taramaya dusulur; unique denetimi insa sirasinda da DOGRU surer.
      for k := 0 to High(T.Idx) do
        if (T.Idx[k].Col = i) and not T.Idx[k].Invalid then   // R-22
        begin
          BuildOneIndex(T, k);
          Break;
        end;
      if FIdxUniq.TryGetValue(ik, um) then
      begin
        if um.TryGetValue(Vals[i], sahip) and (sahip <> ExcludePk) then
          raise EVDbException.Create(ecUniqueViolation, 'UNIQUE ihlali: ' + T.Cols[i].Name);
        Continue;
      end;
      // indeks tanimli degilse tam tara
      hasIdx := TryGetMemIndex(T.TableId, i, e);
      if hasIdx and VDbIdxRange(e, T.Cols[i].Ctype, '=', Vals[i], lo, hi) then
      begin
        for k := lo to hi - 1 do
          if e[k].Pk <> ExcludePk then
            raise EVDbException.Create(ecUniqueViolation, 'UNIQUE ihlali: ' + T.Cols[i].Name);
      end
      else if not hasIdx then
      begin
        ScanRows(T.Name, pks, rows);
        for k := 0 to High(pks) do
          if (pks[k] <> ExcludePk) and (rows[k][i] = Vals[i]) then
            raise EVDbException.Create(ecUniqueViolation, 'UNIQUE ihlali: ' + T.Cols[i].Name);
      end;
    end;
  end;
  // F2-23: CREATE UNIQUE INDEX kisiti. ONCEDEN bu tanim hicbir yerde
  // zorlanmiyordu: parser UNIQUE kelimesini yutup bayragi motora
  // tasimiyordu, TIdxDef'te de alan yoktu. Sonuc `CREATE UNIQUE INDEX`
  // sessizce HIC BIR SEY yapmiyordu (tek ve cok kolonlu).
  // Burada bilesik indeks anahtarinin TAMAMI ayni olan BASKA bir satir
  // varsa reddedilir. Bos (=NULL) deger sayilmaz.
  for i := 0 to High(T.Idx) do
  begin
    if not T.Idx[i].Uniq then Continue;
    // F-18: EXPRESSION UNIQUE — anahtar ifadeden gelir
    if T.Idx[i].ExprText <> '' then
    begin
      if not VDbExprVal(T.Idx[i].ExprText, Vals, T.Cols, ikey, eCtype) then
        Continue;              // ifade hesaplanamadiysa bu kisit denetlenmez
      if ikey = '' then Continue;   // NULL sayilmaz
      ik := IdxKeyPos(T, i);
      if FIdxUniq.TryGetValue(ik, um) then
      begin
        if um.TryGetValue(ikey, sahip) and (sahip <> ExcludePk) then
          raise EVDbException.Create(ecUniqueViolation,
            'UNIQUE ihlali: ' + T.Idx[i].Name);
        Continue;
      end;
      // harita henuz kurulmadiysa kur
      if not T.Idx[i].Invalid then   // R-22: concurrent insa kurulmaz
        BuildOneIndex(T, i);
      if FIdxUniq.TryGetValue(ik, um) then
      begin
        if um.TryGetValue(ikey, sahip) and (sahip <> ExcludePk) then
          raise EVDbException.Create(ecUniqueViolation,
            'UNIQUE ihlali: ' + T.Idx[i].Name);
        Continue;
      end;
      ScanRows(T.Name, pks, rows);
      for k := 0 to High(pks) do
        if pks[k] <> ExcludePk then
        begin
          VDbExprVal(T.Idx[i].ExprText, rows[k], T.Cols, rkey, eCtype);
          if (rkey <> '') and (rkey = ikey) then
            raise EVDbException.Create(ecUniqueViolation,
              'UNIQUE ihlali: ' + T.Idx[i].Name);
        end;
      Continue;
    end;
    icols := IdxColsOf(T, i);
    ikey := VDbIdxJoin(Vals, icols);
    if ikey = '' then Continue;
    // hizli yol: indeks dizisinden ilk kolonun TUM karsiliklarini al
    // (cok kolonlu indeks girdileri PARCA PARCA sirali oldugu icin ham
    // dize uzerinde ikili arama GECERSIZDIR; once ilk parca blogu
    // alinir, sonra tam anahtar esitligi denetlenir).
    if TryGetMemIndex(T.TableId, T.Idx[i].Col, e) then
    begin
      if Length(icols) <= 1 then
      begin
        lo := 0; hi := 0;
        if VDbIdxRange(e, T.Cols[icols[0]].Ctype, '=', ikey, lo, hi) then
          for k := lo to hi - 1 do
            if e[k].Pk <> ExcludePk then
              raise EVDbException.Create(ecUniqueViolation,
                'UNIQUE ihlali: ' + T.Idx[i].Name);
      end
      else
      begin
        // ONEMLI: VDbIdxRangeL'e parca degil TAM kodlanmis anahtar verilir;
        // icerideki VDbIdxPartOf(ikey,0) dogru sekilde ilk parcayi ayirir.
        // Once ilk parca ELDE EDILIP verilseydi, degerin kendi icindeki #1
        // yeniden ayirici sayilir ve karsilastirma bozulurdu.
        lo := 0; hi := 0;
        if VDbIdxRangeLK(e, T.Cols[icols[0]].Ctype, '=', ikey, Length(icols), lo, hi) then
          for k := lo to hi - 1 do
            if (e[k].Pk <> ExcludePk) and (e[k].Key = ikey) then
              raise EVDbException.Create(ecUniqueViolation,
                'UNIQUE ihlali: ' + T.Idx[i].Name);
      end;
    end
    else
    begin
      // indeks bellekte yok: tam tara
      ScanRows(T.Name, pks, rows);
      for k := 0 to High(pks) do
      begin
        if pks[k] = ExcludePk then Continue;
        if VDbIdxJoin(rows[k], icols) = ikey then
          raise EVDbException.Create(ecUniqueViolation,
            'UNIQUE ihlali: ' + T.Idx[i].Name);
      end;
    end;
  end;
end;

function TVTableDb.RefValueExists(const Rt: TTableDef; ColIdx: Integer; const V: string): Boolean;
// Referans deger baska tabloda var mi? (PK ise O(1), indexli ise dilim, degilse tara)
var
  e: TIdxEntries;
  lo, hi, k: Integer;
  pks: TStrArray;
  rows: TStrMatrix;
begin
  Result := False;
  // F2-22: PkIndex<0 ise PK tanimlanmamis; bu yol kullanilmaz.
  if (Rt.PkIndex >= 0) and (ColIdx = Rt.PkIndex) then
    Exit(ReadRow(Rt.Name, V, pks));
  if TryGetMemIndex(Rt.TableId, ColIdx, e) then
    Exit(VDbIdxRange(e, Rt.Cols[ColIdx].Ctype, '=', V, lo, hi) and (hi > lo));
  ScanRows(Rt.Name, pks, rows);
  for k := 0 to High(pks) do
    if rows[k][ColIdx] = V then Exit(True);
end;

// ---- R-18: RBAC ----
function TVTableDb.PrivName(APriv: Byte): string;
var
  K: TPrivKind;
begin
  K := TPrivKind(APriv);
  case K of
    pkSelect: Result := 'SELECT';
    pkInsert: Result := 'INSERT';
    pkUpdate: Result := 'UPDATE';
    pkDelete: Result := 'DELETE';
    pkAll:    Result := 'ALL';
  else
    Result := 'BILINMIYOR(' + IntToStr(APriv) + ')';
  end;
end;

procedure TVTableDb.CreateRole(const AName: string; ASuper: Boolean);
var
  r: TRoleDef;
begin
  if Trim(AName) = '' then
    raise EVDbException.Create(ecInvalidName, 'rol adi bos olamaz');
  r.Name := VDbNorm(AName);
  if FRoles.ContainsKey(r.Name) then
    raise EVDbException.Create(ecObjectExists, 'rol var: ' + r.Name);
  r.Super := ASuper;
  FRoles.AddOrSetValue(r.Name, r);
  MarkSchema;
end;

procedure TVTableDb.DropRole(const AName: string);
var
  i: Integer;
  nm: string;
begin
  nm := VDbNorm(AName);
  if not FRoles.ContainsKey(nm) then
    raise EVDbException.Create(ecNotFound, 'rol yok: ' + nm);
  FRoles.Remove(nm);
  // Role verilmis izinler de düşer (orphan izin bir ise yaramaz).
  i := 0;
  while i < FGrants.Count do
    if FGrants[i].Role = nm then
    begin
      FGrants.Delete(i);   // dizi silinince INDISKAYDIRILIR
    end
    else
      Inc(i);
  if FCurrentRole = nm then FCurrentRole := '';
  MarkSchema;
end;

function TVTableDb.RoleCount: Integer;
begin
  Result := FRoles.Count;
end;

function TVTableDb.GrantCount: Integer;
begin
  Result := FGrants.Count;
end;

function TVTableDb.RoleExists(const AName: string): Boolean;
begin
  Result := FRoles.ContainsKey(VDbNorm(AName));
end;

procedure TVTableDb.GrantPriv(const ATable: string; APriv: Byte;
  const ARole: string);
var
  g: TGrantDef;
  i: Integer;
begin
  if not RoleExists(ARole) then
    raise EVDbException.Create(ecNotFound, 'rol yok: ' + VDbNorm(ARole));
  g.Table := VDbNorm(ATable);
  g.Priv := APriv;
  g.Role := VDbNorm(ARole);
  for i := 0 to FGrants.Count - 1 do
    if (FGrants[i].Table = g.Table) and (FGrants[i].Priv = g.Priv) and
       (FGrants[i].Role = g.Role) then
      Exit;   // ayni izin iki kez verilmez
  FGrants.Add(g);
  MarkSchema;
end;

procedure TVTableDb.RevokePriv(const ATable: string; APriv: Byte;
  const ARole: string);
var
  i: Integer;
  t, r: string;
begin
  t := VDbNorm(ATable);
  r := VDbNorm(ARole);
  i := 0;
  while i < FGrants.Count do
    if (FGrants[i].Table = t) and (FGrants[i].Priv = APriv) and
       (FGrants[i].Role = r) then
      FGrants.Delete(i)
    else
      Inc(i);
  MarkSchema;
end;

procedure TVTableDb.SetCurrentRole(const AName: string);
begin
  if (AName = '') or (SameText(AName, 'NONE')) then
  begin
    FCurrentRole := '';
    Exit;
  end;
  if not RoleExists(AName) then
    raise EVDbException.Create(ecNotFound, 'rol yok: ' + VDbNorm(AName));
  FCurrentRole := VDbNorm(AName);
end;

function TVTableDb.RoleCan(const ATable: string; APriv: Byte): Boolean;
var
  g: TRoleDef;
  i: Integer;
  t: string;
begin
  // Rol belirtilmemisse motor kullanici modundayiz: her sey serbest.
  if FCurrentRole = '' then Exit(True);
  if not FRoles.TryGetValue(FCurrentRole, g) then Exit(True);
  if g.Super then Exit(True);
  t := VDbNorm(ATable);
  for i := 0 to FGrants.Count - 1 do
    if (FGrants[i].Role = FCurrentRole) and
       ((FGrants[i].Table = t) or (FGrants[i].Table = '*')) and
       ((FGrants[i].Priv = APriv) or (FGrants[i].Priv = Byte(pkAll))) then
      Exit(True);
  Result := False;
end;

procedure TVTableDb.RequirePriv(const ATable: string; APriv: Byte);
begin
  if not RoleCan(ATable, APriv) then
    raise EVDbException.CreateFmt(ecPermissionDenied,
      'yetkisiz: rol "%s" tablo "%s" uzerinde %s iznine sahip degil',
      [FCurrentRole, VDbNorm(ATable), PrivName(APriv)]);
end;

{ ---- R-19: ROW LEVEL SECURITY ---- }

procedure TVTableDb.SetRls(const ATable: string; AOn: Boolean);
var t: string;
begin
  t := VDbNorm(ATable);
  if AOn then FRlsOn.AddOrSetValue(t, True)
  else FRlsOn.Remove(t);
  MarkSchema;
end;

function TVTableDb.RlsEnabled(const ATable: string): Boolean;
var v: Boolean;
begin
  Result := FRlsOn.TryGetValue(VDbNorm(ATable), v) and v;
end;

procedure TVTableDb.CreatePolicy(const ATable, AName: string; ACmd: Byte;
  const AUsing, ACheck: string);
var
  t, n: string;
  i: Integer;
  p: TPolicyDef;
begin
  t := VDbNorm(ATable);
  n := VDbNorm(AName);
  if (ACmd > 4) then
    raise EVDbException.Create(ecSyntaxError, 'policy komutu gecersiz');
  for i := 0 to FPolicies.Count - 1 do
    if (FPolicies[i].Table = t) and (FPolicies[i].Name = n) then
      raise EVDbException.Create(ecObjectExists,
        'politika zaten var: ' + t + '.' + n);
  p.Table := t;
  p.Name := n;
  p.Cmd := ACmd;
  p.UsingText := AUsing;
  p.CheckText := ACheck;
  FPolicies.Add(p);
  MarkSchema;
end;

procedure TVTableDb.DropPolicy(const ATable, AName: string);
var
  t, n: string;
  i: Integer;
begin
  t := VDbNorm(ATable);
  n := VDbNorm(AName);
  i := 0;
  while i < FPolicies.Count do
    if (FPolicies[i].Table = t) and (FPolicies[i].Name = n) then
      FPolicies.Delete(i)
    else
      Inc(i);
  MarkSchema;
end;

function TVTableDb.PolicyCount: Integer;
begin
  Result := FPolicies.Count;
end;

{ Super rol veya rol belirtilmemisse R-18 mantigiyla ayni sekilde RLS de
  uygulanmaz: yetki sistemi opt-in'dir. }
function TVTableDb.RlsApplies(const ATable: string): Boolean;
var
  r: TRoleDef;
begin
  Result := RlsEnabled(ATable);
  if not Result then Exit;
  if FCurrentRole = '' then Exit(False);
  if not FRoles.TryGetValue(FCurrentRole, r) then Exit(False);
  if r.Super then Exit(False);
end;

function TVTableDb.RlsUsing(const ATable: string; ACmd: Byte): TStrArray;
var
  i, k: Integer;
  t: string;
begin
  SetLength(Result, 0);
  if not RlsApplies(ATable) then Exit;
  t := VDbNorm(ATable);
  for i := 0 to FPolicies.Count - 1 do
    if (FPolicies[i].Table = t) and (FPolicies[i].UsingText <> '') and
       (FPolicies[i].Cmd in [0, ACmd]) then
    begin
      k := Length(Result);
      SetLength(Result, k + 1);
      Result[k] := FPolicies[i].UsingText;
    end;
end;

function TVTableDb.RlsCheck(const ATable: string; ACmd: Byte): TStrArray;
var
  i, k: Integer;
  t: string;
  p: TPolicyDef;
begin
  SetLength(Result, 0);
  if not RlsApplies(ATable) then Exit;
  t := VDbNorm(ATable);
  for i := 0 to FPolicies.Count - 1 do
    if (FPolicies[i].Table = t) and
       (FPolicies[i].Cmd in [0, ACmd]) then
    begin
      // WITH CHECK varsa o kullanilir; yoksa USING de gecerlidir
      // (PostgreSQL: INSERT icin USING, UPDATE icin USING varsayilandir).
      p := FPolicies[i];
      if p.CheckText <> '' then
      begin
        k := Length(Result);
        SetLength(Result, k + 1);
        Result[k] := p.CheckText;
      end
      else if (p.UsingText <> '') and (p.Cmd <> 1) then
      begin
        k := Length(Result);
        SetLength(Result, k + 1);
        Result[k] := p.UsingText;
      end;
    end;
end;

procedure TVTableDb.SetDeferred(AOn: Boolean);
{ R-11: DEFERRED -> IMMEDIATE gecisi. IMMEDIATE'a donuldugu anda
  birikmis ertelenen satirlar ANINDA denetlenir (SQL standardi:
  "SET CONSTRAINTS ... IMMEDIATE" bekleyen denetimleri hemce yurutur).
  Ihlal varsa exception firlatilir; cagiran (executor) hatayi kullaniciya
  iletir ve transaction hala acik kalir. }
begin
  FDeferred := AOn;
  if not AOn then
    // IMMEDIATE'a donuldu: ertelenen satirlar ANINDA denetlenir.
    CheckDeferredNow;
end;

function TVTableDb.DeferrableFk(const T: TTableDef): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(T.Fks) do
    if T.Fks[i].Deferrable <> 0 then Exit(True);
  Result := False;
end;

procedure TVTableDb.DoCheckDeferred;
begin
  CheckDeferredNow;
end;

procedure TVTableDb.CheckDeferredNow;
// COMMIT oncesi cagrilir: ertelenen satirlar NİHAİ haliyle yeniden
// denetlenir. Ihlal varsa exception firlatilir; CommitBatch bunu
// yakalayip dosyayi geri sarar (rollback).
var
  i: Integer;
  t: TTableDef;
  vals: TStrArray;
  entry: string;
  sep: Integer;
  tbl, pk: string;
  saved: Boolean;
  dup: TStringList;
begin
  if FDeferredRows.Count = 0 then Exit;
  saved := FDeferred;
  FDeferred := False;     // yeniden denetimde tekrar erteleme
  dup := TStringList.Create;
  dup.Sorted := True;
  dup.Duplicates := dupIgnore;
  try
    // Ayni (tablo, pk) birkerez denetlensin: bir satir bir islemde
    // birkac kez yazilabilir, her seferinde denetmek gereksiz.
    for i := 0 to FDeferredRows.Count - 1 do
    begin
      entry := FDeferredRows[i];
      sep := Pos(#1, entry);
      if sep <= 0 then Continue;
      dup.Add(VDbNorm(Copy(entry, 1, sep - 1)) + #1 +
              Copy(entry, sep + 1, MaxInt));
    end;
    for i := 0 to dup.Count - 1 do
    begin
      entry := dup[i];
      sep := Pos(#1, entry);
      tbl := Copy(entry, 1, sep - 1);
      pk  := Copy(entry, sep + 1, MaxInt);
      if not FTables.TryGetValue(tbl, t) then Continue;
      // Satir COMMIT'e kadar silinmis olabilir. Cocuk satiri silinmisse
      // dogrulanacak BIR SEY kalmaz -> gecersiz sayilir ve atlanir.
      if not ReadRow(t.Name, pk, vals) then Continue;
      CheckFk(t, vals);
    end;
  finally
    FDeferred := saved;
    // Denetim bitti (basari da hata da). Ihlal halinde liste
    // temizlenmezse, COMMIT reddedildikten sonra kullanici ayni
    // hatayi tekrar alir.
    FDeferredRows.Clear;
    dup.Free;
  end;
end;

procedure TVTableDb.CheckFk(const T: TTableDef; const Vals: TStrArray);
var
  i: Integer;
  rt: TTableDef;
  rc: Integer;
  pk: string;
begin
  // ---- R-11: DEFERRABLE FK ertelemesi ----
  // Yalniz (a) acik bir batch icinde, (b) SET CONSTRAINTS ... DEFERRED
  // etkin ve (c) tabloda DEFERRABLE bir FK varken ertelenir. Batch disinda
  // erteleme anlamsizdir: COMMIT yok, denetim ne zaman yapilacagi bilinmez.
  if FDeferred and FKv.InBatch and DeferrableFk(T) and (T.PkIndex >= 0) then
  begin
    pk := Vals[T.PkIndex];
    FDeferredRows.Add(T.Name + #1 + pk);
    Exit;
  end;
  for i := 0 to High(T.Fks) do
  begin
    if Vals[T.Fks[i].Col] = '' then Continue; // NULL serbest
    // F2-12: kendine referansta hedef tablo T'nin kendisi (zaten var).
    if VDbNorm(T.Fks[i].RefTable) = T.Name then
      rt := T
    else if not FTables.TryGetValue(T.Fks[i].RefTable, rt) then
      raise EVDbException.Create(ecForeignKeyViolation, 'FK hedef tablo yok: ' + T.Fks[i].RefTable);
    rc := FindCol(rt, T.Fks[i].RefCol);
    if rc < 0 then
      raise EVDbException.Create(ecForeignKeyViolation, 'FK hedef kolon yok: ' + T.Fks[i].RefCol);
    if not RefValueExists(rt, rc, Vals[T.Fks[i].Col]) then
      raise EVDbException.CreateFmt(ecForeignKeyViolation, 'FOREIGN KEY ihlali: %s.%s=%s kayitli degil',
        [T.Name, T.Cols[T.Fks[i].Col].Name, Vals[T.Fks[i].Col]]);
  end;
end;

procedure TVTableDb.PutRow(const T: TTableDef; const Pk: string;
  const Vals: TStrArray);
var
  j: Integer;
  b, oldB: TBytes;
  key: QWord;
  exTid: Word;
  exPk: string;
  exVals: TStrArray;
begin
  // R-13 Full: bolme anahtari NULL olamaz (hangi bolume dusecegi
  // hesaplanamazdi). PostgreSQL uyumlu kural; INSERT ve UPDATE yollarinin
  // ikisi de PutRow'dan gectigi icin tek noktada denetlenir.
  if T.PartType <> '' then
  begin
    j := 0;
    while (j < Length(T.Cols)) and (T.Cols[j].Name <> T.PartCol) do Inc(j);
    if (j < Length(T.Cols)) and (j <= High(Vals)) and (Vals[j] = '') then
      raise EVDbException.Create(ecNotNullViolation,
        'partition anahtari NULL olamaz: ' + T.PartCol);
  end;
  key := VDbHashKey(T.Name, Pk);
  if FKv.Get(key, oldB) then
  begin
    // DIKKAT: kararÄ±n esas belirleyicisi exPk'dir; TID karÅŸÄ±laÅŸtÄ±rmasÄ±
    // F-34 MV'lerinde anlamsÄ±zdÄ±r. Normal tabloda exPk esitse aynÄ± satÄ±r
    // gÃ¼ncellemesidir (upsert) -> hata yok.
    if DecodeRow(oldB, exTid, exPk, exVals) and (exPk <> Pk) then
      raise EVDbException.CreateFmt(ecHashCollision,
        'VDb: hash carpismasi (%s, %s)', [T.Name, Pk]);
  end;
  b := EncodeRow(T.TableId, Pk, T, Vals);
  // NOT: WriteAheadWAL cagrisi KALDIRILDI. Gerekce: mevcut WAL duzeni
  // replay yapmiyor (ReplayWAL stub) ve her cagri .wal'i bastan aciyor
  // (fmCreate) â€” yani hem ise yaramiyor hem her satirda dosya aciyordu.
  // Gercek dayaniklilik: batch basina tek fsync + BATCHEND + recovery.
  FKv.Put(key, b);
  // Indeksleri guncelle (cok kolonlu destekli)
  IdxAddRow(T, Vals, Pk, -1);
end;

procedure TVTableDb.SetFkAction(const Table, Column, RefTable: string;
  const OnEvent, Action: string);
// ON DELETE/ON UPDATE aksiyonunu degistirir (ALTER TABLE yerine).
var
  t: TTableDef;
  ci: Integer;
  i: Integer;
  nt: TTableDef;
begin
  t := GetTable(Table);
  ci := FindCol(t, Column);
  if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Column);
  nt := t;
  for i := 0 to High(nt.Fks) do
    if (nt.Fks[i].Col = ci) and
       ((RefTable = '') or (nt.Fks[i].RefTable = VDbNorm(RefTable))) then
    begin
      if SameText(OnEvent, 'DELETE') then
        nt.Fks[i].OnDelete := VDbFkAction(Action)
      else if SameText(OnEvent, 'UPDATE') then
        nt.Fks[i].OnUpdate := VDbFkAction(Action)
      else
        raise EVDbException.Create(ecSyntaxError, 'ON DELETE veya ON UPDATE bekleniyor: ' + OnEvent);
    end;
  FTables.AddOrSetValue(nt.Name, nt);
  MarkSchema;
end;

type
  // FK referans aksiyonu: hangi cocuk tablosunda, hangi FK'da, ne yapilacak
  // ve etkilenen cocuk satirlarinin PK'lari.
  TFkCascade = record
    Child: string;          // cocuk tablo adi
    ChildId: Word;          // cocuk tablo kimligi
    Col: Integer;           // cocuktaki FK kolonu
    Ctype: Byte;            // FK kolonunun tipi
    Action: string;         // VDB_FK_CASCADE / SETNULL / SETDEFAULT
    DefVal: string;         // SET DEFAULT icin kolonun DEFAULT'i
    Pks: TStrArray;         // etkilenen cocuk satirlari
  end;
  TFkCascadeSet = array of TFkCascade;

procedure TVTableDb.CheckRestrict(const T: TTableDef; const ParentVals: TStrArray;
  const Mode, NewVal: string; const RefColFilter: Integer);
// Ebeveyn satiri silinecek/guncellenince cocuklara ne olacak?
//  - RESTRICT (varsayilan): kullaniliyorsa hata
//  - CASCADE              : cocuk satirlari da silinir / yeni degere guncellenir
//  - SET NULL             : cocuk FK kolonu NULL yapilir
//  - SET DEFAULT          : kolonun DEFAULT'i yazilir
// Mode: 'DELETE' (ebeveyn siliniyor) | 'UPDATE' (ebeveyn degeri degisiyor)
//
// IKI ASAMALI. Asama 1: tum cocuk FK'lar denetlenir ve RESTRICT ihlali
// HENUZ HICBIR YAZMA YAPILMADEN bildirilir. Asama 2: kaskadlar uygulanir.
// Tek asamali olsaydi, FTables siralamasina bagli olarak bir cocuk tablosu
// CASCADE ile silinirken sonraki tablo RESTRICT hatasi verip batch geri
// alsa bile o kosudaki yan etkiler birikiyordu.
var
  kv: TPair<string, TTableDef>;
  i, rc, n: Integer;
  e: TIdxEntries;
  lo, hi: Integer;
  pks: TStrArray;
  rows: TStrMatrix;
  act: string;
  newVals: TStrArray;
  cdef: string;
  hits: TStrArray;
  plan: TFkCascadeSet;
  child: TTableDef;
  c2: TFkCascade;
  ownBatch: Boolean;

  function FindHits(const Child2: TTableDef; const FkIx: Integer): TStrArray;
  // Bu FK icin ParentVals[rc]'e isaret eden cocuk satirlarinin PK'lari.
  var
    ii: Integer;
    ee: TIdxEntries;
    l2, h2: Integer;
    pp: TStrArray;
    rr: TStrMatrix;
    res: TStrArray;
  begin
    SetLength(res, 0);
    if TryGetMemIndex(Child2.TableId, Child2.Fks[FkIx].Col, ee) then
    begin
      if VDbIdxRange(ee, Child2.Cols[Child2.Fks[FkIx].Col].Ctype, '=',
        ParentVals[rc], l2, h2) then
        for ii := l2 to h2 - 1 do
        begin
          SetLength(res, Length(res) + 1);
          res[High(res)] := ee[ii].Pk;
        end;
    end
    else
    begin
      ScanRows(Child2.Name, pp, rr);
      for ii := 0 to High(pp) do
        if rr[ii][Child2.Fks[FkIx].Col] = ParentVals[rc] then
        begin
          SetLength(res, Length(res) + 1);
          res[High(res)] := pp[ii];
        end;
    end;
    Result := res;
  end;
begin
  // F2-12: Kaskad zinciri Delete -> CheckRestrict -> Delete -> ...
  // seklinde ozguc doner. CASCADE'li bir CYCLE (a -> b -> a) sonsuza
  // kadar doner (yigin tasmasi / sonsuz silme). Derinlik siniri koyulur.
  Inc(FCascadeDepth);
  try
    if FCascadeDepth > VDB_MAX_CASCADE_DEPTH then
      raise EVDbException.CreateFmt(ecLimit,
        'FK kaskad derinligi asildi (>%d). Muhtemelen CASCADE dongusu var; ' +
        'once veriyi elle duzeltin.', [VDB_MAX_CASCADE_DEPTH]);
    // ------------------------- Asama 1: denetim -------------------------
    SetLength(plan, 0);
    for kv in FTables do
    begin
      // F2-12: ONCEDEN `if kv.Key = T.Name then Continue` ile kendine
      // referans veren tablo (node -> node) TUMDEN denetlenmiyordu:
      // RESTRICT calismiyor, CASCADE calismiyor -> silinen ebeveynin
      // cocugu orphan kaliyordu. Artik kendi tablo da denetlenir.
      for n := 0 to High(kv.Value.Fks) do
      begin
      if kv.Value.Fks[n].RefTable <> T.Name then Continue;
      rc := FindCol(T, kv.Value.Fks[n].RefCol);
      if (rc < 0) or (rc >= Length(ParentVals)) or (ParentVals[rc] = '') then Continue;
      // F1-4: UPDATE'te yalniz degisen referans kolonuna ait FK'lari isle.
      // (Eskiden tum FK'lar NewVal ile eziliyordu; ilgisiz kolondaki
      //  degisiklikte bile RESTRICT atiliyordu.)
      if (RefColFilter >= 0) and (rc <> RefColFilter) then Continue;
      if SameText(Mode, 'UPDATE') then act := kv.Value.Fks[n].OnUpdate
      else act := kv.Value.Fks[n].OnDelete;
      if act = '' then act := VDB_FK_RESTRICT;
      if (act <> VDB_FK_CASCADE) and (act <> VDB_FK_SETNULL) and
         (act <> VDB_FK_SETDEFAULT) then act := VDB_FK_RESTRICT;
      hits := FindHits(kv.Value, n);
      if Length(hits) = 0 then Continue;
      if act = VDB_FK_RESTRICT then
        raise EVDbException.CreateFmt(ecForeignKeyViolation, 'FOREIGN KEY ihlali: %s kullaniliyor (%s)',
          [T.Name, kv.Key]);
      c2.Child := kv.Key;
      c2.ChildId := kv.Value.TableId;
      c2.Col := kv.Value.Fks[n].Col;
      c2.Ctype := kv.Value.Cols[c2.Col].Ctype;
      c2.Action := act;
      c2.DefVal := '';
      if act = VDB_FK_SETDEFAULT then
        if kv.Value.Cols[c2.Col].HasDef then
          c2.DefVal := kv.Value.Cols[c2.Col].Def;
      c2.Pks := hits;
      SetLength(plan, Length(plan) + 1);
      plan[High(plan)] := c2;
    end;
  end;
  if Length(plan) = 0 then Exit;   // hicbir sey etkilenmiyor

  // ---------------------- Asama 2: kaskadlari uygula ----------------------
  // Kaskad yazan bir islem varsa kendi batch'ini ac (yoksa ust batch'e
  // yazilir; DeleteWhere's toplu isi zaten kendi batch'inde).
  ownBatch := not FKv.InBatch;
  if ownBatch then FKv.BeginBatch;
  try
    for i := 0 to High(plan) do
    begin
      child := GetTable(plan[i].Child);
      if plan[i].Action = VDB_FK_CASCADE then
      begin
        if SameText(Mode, 'UPDATE') then
          // cocugun FK kolonu yeni ebeveyn degerine cekilir
          for n := 0 to High(plan[i].Pks) do
          begin
            if not ReadRow(child.Name, plan[i].Pks[n], newVals) then Continue;
            newVals[plan[i].Col] := NewVal;
            PutRow(child, plan[i].Pks[n], newVals);
          end
        else
          for n := 0 to High(plan[i].Pks) do
            Delete(child.Name, plan[i].Pks[n]);
      end
      else
        // SET NULL / SET DEFAULT
        for n := 0 to High(plan[i].Pks) do
        begin
          if not ReadRow(child.Name, plan[i].Pks[n], newVals) then Continue;
          newVals[plan[i].Col] := plan[i].DefVal;   // SET NULL -> DefVal = ''
          PutRow(child, plan[i].Pks[n], newVals);
        end;
    end;
    if ownBatch then FKv.CommitBatch;
  except
    if ownBatch then AbortBatch;
    raise;
  end;
  finally
    // F2-12: her cikista (basari/hata) sayaci geri al
    Dec(FCascadeDepth);
  end;
end;

function TVTableDb.MaxPkInt(const T: TTableDef): Int64;
var
  pks: TStrArray;
  rows: TStrMatrix;
  i: Integer;
  v: Int64;
begin
  Result := 0;
  ScanRows(T.Name, pks, rows);
  for i := 0 to High(pks) do
    if VDbParseInt(pks[i], v) and (v > Result) then
      Result := v;
end;

function TVTableDb.IdxKey(TableId: Word; ColIdx: Integer): Int64;
begin
  Result := (Int64(TableId) shl 32) or Int64(LongWord(ColIdx));
end;

function TVTableDb.IdxKeyPos(const T: TTableDef; IdxPos: Integer): Int64;
// Indeksi ADRESLEME anahtari. Normal indekslerde bu = IdxKey(col), yani
// geri uyumlu. Diger turler sentetik bir numara alir ki ayni kolondaki
// normal indeksle (veya baska bir ifade indeksiyle) CARISMASIN:
//   partial : 16384 + IdxPos
//   ifade   : 32768 + IdxPos
var
  syn: Integer;
begin
  syn := 0;
  if T.Idx[IdxPos].Predicate <> '' then syn := 16384 + IdxPos
  else if T.Idx[IdxPos].ExprText <> '' then syn := 32768 + IdxPos;
  if syn <> 0 then
    Result := (Int64(T.TableId) shl 32) or Int64(LongWord(syn))
  else
    Result := IdxKey(T.TableId, T.Idx[IdxPos].Col);
end;

function TVTableDb.IdxKeyOfRow(const T: TTableDef; IdxPos: Integer;
  const Vals: TStrArray): string;
// Indeks anahtari: kolon indeksi mi ifade indeksi mi?
// F-18: ifade indeksi -> ifade satir basina hesaplanir; HESAPLANAMAZSA
// bos string doner ve satir indekslenmez (guvenli taraf).
var
  ev, ct: Byte;
  v: string;
begin
  if T.Idx[IdxPos].ExprText <> '' then
  begin
    if not VDbExprVal(T.Idx[IdxPos].ExprText, Vals, T.Cols, v, ct) then
      Exit('');
    Exit(v);
  end;
  Result := VDbIdxJoin(Vals, IdxColsOf(T, IdxPos));
end;

function TVTableDb.IdxCtypeOfPos(const T: TTableDef; IdxPos: Integer): Byte;
// Indeks anahtarinin siralama tipi. F-18: ifade indeksi icin tip
// ifadeden cikarilir; cikarilamazsa metin (guvenli: byte sirasi).
var
  probe: string;
  ct: Byte;
  i, ci2: Integer;
begin
  if T.Idx[IdxPos].ExprText = '' then
  begin
    if Length(T.Idx[IdxPos].Cols) > 0 then
      Result := T.Cols[T.Idx[IdxPos].Cols[0]].Ctype
    else
      Result := T.Cols[T.Idx[IdxPos].Col].Ctype;
    Exit;
  end;
  // ifade metnindeki ILK kolonun tipini kullan (basit ve yeterli).
  // Taban yoksa VCT_STR: yalnizca daraltma yapar, sonuc WHERE dogrular.
  ct := VCT_STR;
  i := 1;
  while i <= Length(T.Idx[IdxPos].ExprText) do
  begin
    if ((T.Idx[IdxPos].ExprText[i] >= 'a') and (T.Idx[IdxPos].ExprText[i] <= 'z')) or
        ((T.Idx[IdxPos].ExprText[i] >= 'A') and (T.Idx[IdxPos].ExprText[i] <= 'Z')) or
        (T.Idx[IdxPos].ExprText[i] = '_') then
    begin
      probe := '';
      while (i <= Length(T.Idx[IdxPos].ExprText)) and
            (((T.Idx[IdxPos].ExprText[i] >= 'a') and (T.Idx[IdxPos].ExprText[i] <= 'z')) or
             ((T.Idx[IdxPos].ExprText[i] >= 'A') and (T.Idx[IdxPos].ExprText[i] <= 'Z')) or
             ((T.Idx[IdxPos].ExprText[i] >= '0') and (T.Idx[IdxPos].ExprText[i] <= '9')) or
             (T.Idx[IdxPos].ExprText[i] = '_')) do
      begin
        probe := probe + T.Idx[IdxPos].ExprText[i];
        Inc(i);
      end;
      if SameText(probe, 'LOWER') or SameText(probe, 'UPPER') or
         SameText(probe, 'TRIM') or SameText(probe, 'LENGTH') or
         SameText(probe, 'ABS') then
      begin
        i := Length(T.Idx[IdxPos].ExprText);   // fonksiyon: metin kabul et
        Break;
      end;
      for ci2 := 0 to High(T.Cols) do
        if VDbNorm(T.Cols[ci2].Name) = VDbNorm(probe) then
        begin
          ct := T.Cols[ci2].Ctype;
          Exit(ct);
        end;
    end
    else
      Inc(i);
  end;
  Result := ct;
end;

procedure TVTableDb.SortIdxEntries(var E: TIdxEntries; Ctype: Byte);
  procedure Sort(L, H: Integer);
  var
    i, j: Integer;
    piv, tmp: TIdxEntry;
    c: Integer;
  begin
    i := L; j := H; piv := E[(L + H) div 2];
    repeat
      while True do
      begin
        c := VDbIdxCmp(E[i].Key, piv.Key, Ctype);
        if c = 0 then c := CompareStr(E[i].Pk, piv.Pk);
        if c < 0 then Inc(i) else Break;
      end;
      while True do
      begin
        c := VDbIdxCmp(E[j].Key, piv.Key, Ctype);
        if c = 0 then c := CompareStr(E[j].Pk, piv.Pk);
        if c > 0 then Dec(j) else Break;
      end;
      if i <= j then
      begin
        tmp := E[i]; E[i] := E[j]; E[j] := tmp;
        Inc(i); Dec(j);
      end;
    until i > j;
    if L < j then Sort(L, j);
    if i < H then Sort(i, H);
  end;
begin
  if Length(E) > 1 then Sort(0, High(E));
end;

procedure TVTableDb.SortIdxEntriesCols(var E: TIdxEntries;
  const Ctypes: TByteArray);
// COK KOLONLU indeks siralamasi: anahtarlar #1 ile birlestirilmis,
// her parca kendi tipine gore karsilastirilir.
  procedure Sort(L, H: Integer);
  var
    i, j: Integer;
    piv, tmp: TIdxEntry;
    c: Integer;
  begin
    i := L; j := H; piv := E[(L + H) div 2];
    repeat
      while True do
      begin
        c := VDbIdxMultiCmp(E[i].Key, piv.Key, Ctypes);
        if c = 0 then c := CompareStr(E[i].Pk, piv.Pk);
        if c < 0 then Inc(i) else Break;
      end;
      while True do
      begin
        c := VDbIdxMultiCmp(E[j].Key, piv.Key, Ctypes);
        if c = 0 then c := CompareStr(E[j].Pk, piv.Pk);
        if c > 0 then Dec(j) else Break;
      end;
      if i <= j then
      begin
        tmp := E[i]; E[i] := E[j]; E[j] := tmp;
        Inc(i); Dec(j);
      end;
    until i > j;
    if L < j then Sort(L, j);
    if i < H then Sort(i, H);
  end;
begin
  if Length(E) > 1 then Sort(0, High(E));
end;

function TVTableDb.IdxLowerBound(const E: TIdxEntries; Ctype: Byte; const Key, Pk: string): Integer;
var
  lo, hi, m, c: Integer;
begin
  lo := 0; hi := Length(E);
  while lo < hi do
  begin
    m := (lo + hi) div 2;
    c := VDbIdxCmp(E[m].Key, Key, Ctype);
    if c = 0 then c := CompareStr(E[m].Pk, Pk);
    if c < 0 then
      lo := m + 1
    else
      hi := m;
  end;
  Result := lo;
end;

procedure TVTableDb.IdxAddRow(const T: TTableDef; const Vals: TStrArray;
  const Pk: string; const OnlyPos: Integer);
// Satirin indeks anahtarlarini gunceller (cok kolonlu destekli).
// OnlyPos >= 0 ise yalniz o indeks guncellenir (UPDATE'te sadece degisen).
var
  j: Integer;
  k: Int64;
  l: TList<TIdxOp>;
  op: TIdxOp;
  m: TDictionary<string, string>;
  key: string;
begin
  // PK lazy index kirli isaretle (T.Idx'te PK yok, burada yakalanir)
  if FPkIdx.ContainsKey(T.TableId) then
    FPkIdxDirty.AddOrSetValue(T.TableId, True);
  for j := 0 to High(T.Idx) do
  begin
    if (OnlyPos >= 0) and (j <> OnlyPos) then Continue;
    // F-17: PARTIAL indeks — kosulu SAGLAMAYAN satir indekslenmez
    if not VDbPredOK(T.Idx[j].Predicate, Vals, T.Cols) then Continue;
    key := IdxKeyOfRow(T, j, Vals);   // F-18: ifade indeksi anahtari
    // F-18: ifade hesaplanamadi (desteklenmeyen bicim) -> indekslenmez
    if (T.Idx[j].ExprText <> '') and (key = '') then Continue;
    k := IdxKeyPos(T, j);   // F-17: partial indeks ayri anahtar kullanir
    if not FIdxOps.TryGetValue(k, l) then
    begin
      l := TList<TIdxOp>.Create;
      FIdxOps.AddOrSetValue(k, l);
    end;
    op.Key := key;
    op.Pk := Pk;
    op.Cov := VDbIdxJoin(Vals, T.Idx[j].Incl);   // F-19: INCLUDE degerleri
    op.IsDel := False;
    l.Add(op);
    if T.Idx[j].ExprText <> '' then
      FIdxCtype.AddOrSetValue(k, IdxCtypeOfPos(T, j))   // F-18
    else
      FIdxCtype.AddOrSetValue(k, T.Cols[T.Idx[j].Col].Ctype);
    // UNIQUE kolon haritasi (bkz. CheckConstraints)
    // F3-5: bos (=NULL) anahtar HARITAYA YAZILMAZ. NULL degerler UNIQUE
    // denetiminde muaftir ("deger <> ''" kosulu), dolayisiyla haritadaki
    // bir bos kaydi hicbir sorguda kullanilmaz; yalnizca haritayi
    // buyutur ve sonraki gercek bir degerle ayni anahtara (AddOrSetValue)
    // yazilirsa eski NULL sahibi ezilir. BuildOneIndex zaten bos
    // anahtari atiyordu; bu yolun da ayni davranisi olmali.
    if (key <> '') and FIdxUniq.TryGetValue(k, m) then m.AddOrSetValue(key, Pk);
    if FIdxDirty.IndexOf(k) < 0 then FIdxDirty.Add(k);
  end;
end;

procedure TVTableDb.IdxDelRow(const T: TTableDef; const Vals: TStrArray;
  const Pk: string; const OnlyPos: Integer);
// Satir indeksden TAMAMEN kalkiyor.
var
  j: Integer;
  k: Int64;
  l: TList<TIdxOp>;
  op: TIdxOp;
  m: TDictionary<string, string>;
  key, s: string;
begin
  // PK lazy index kirli isaretle
  if FPkIdx.ContainsKey(T.TableId) then
    FPkIdxDirty.AddOrSetValue(T.TableId, True);
  for j := 0 to High(T.Idx) do
  begin
    if (OnlyPos >= 0) and (j <> OnlyPos) then Continue;
    // F-17: PARTIAL indeks — satir indeksde yoksa silme islemi de gerekmez
    if not VDbPredOK(T.Idx[j].Predicate, Vals, T.Cols) then Continue;
    key := IdxKeyOfRow(T, j, Vals);   // F-18
    if (T.Idx[j].ExprText <> '') and (key = '') then Continue;
    k := IdxKeyPos(T, j);   // F-17
    if not FIdxOps.TryGetValue(k, l) then
    begin
      l := TList<TIdxOp>.Create;
      FIdxOps.AddOrSetValue(k, l);
    end;
    op.Key := key;
    op.Pk := Pk;
    op.Cov := '';   // F-19: silmede deger tasinmaya gerek yok
    op.IsDel := True;
    l.Add(op);
    if T.Idx[j].ExprText <> '' then
      FIdxCtype.AddOrSetValue(k, IdxCtypeOfPos(T, j))   // F-18
    else
      FIdxCtype.AddOrSetValue(k, T.Cols[T.Idx[j].Col].Ctype);
    // UNIQUE kolon haritasi: deger -> sahip pk
    if FIdxUniq.TryGetValue(k, m) then
      if m.TryGetValue(key, s) and (s = Pk) then m.Remove(key);
    if FIdxDirty.IndexOf(k) < 0 then FIdxDirty.Add(k);
  end;
end;

procedure TVTableDb.IdxAdd(TableId: Word; ColIdx: Integer; const Key, Pk: string; Ctype: Byte);
// TEK kolonlu indeks icin kisa yol (cok kolonlu indekslerde kullanilmaz)
var
  k: Int64;
  l: TList<TIdxOp>;
  op: TIdxOp;
  m: TDictionary<string, string>;
begin
  k := IdxKey(TableId, ColIdx);
  if not FIdxOps.TryGetValue(k, l) then
  begin
    l := TList<TIdxOp>.Create;
    FIdxOps.AddOrSetValue(k, l);
  end;
  op.Key := Key;
  op.Pk := Pk;
  op.IsDel := False;
  l.Add(op);
  FIdxCtype.AddOrSetValue(k, Ctype);
  // F3-5: bos anahtar haritaya yazilmaz (IdxAddRow ile ayni gerekce)
  if (Key <> '') and FIdxUniq.TryGetValue(k, m) then m.AddOrSetValue(Key, Pk);
  if FIdxDirty.IndexOf(k) < 0 then FIdxDirty.Add(k);
end;

procedure TVTableDb.IdxDel(TableId: Word; ColIdx: Integer; const Key, Pk: string; Ctype: Byte);
// TEK kolonlu indeks icin kisa yol
var
  k: Int64;
  l: TList<TIdxOp>;
  op: TIdxOp;
  m: TDictionary<string, string>;
  s: string;
begin
  k := IdxKey(TableId, ColIdx);
  if not FIdxOps.TryGetValue(k, l) then
  begin
    l := TList<TIdxOp>.Create;
    FIdxOps.AddOrSetValue(k, l);
  end;
  op.Key := Key;
  op.Pk := Pk;
  op.IsDel := True;
  l.Add(op);
  FIdxCtype.AddOrSetValue(k, Ctype);
  if FIdxUniq.TryGetValue(k, m) then
    if m.TryGetValue(Key, s) and (s = Pk) then m.Remove(Key);
  if FIdxDirty.IndexOf(k) < 0 then FIdxDirty.Add(k);
end;

procedure TVTableDb.FreeIdxUniqMaps;
// UNIQUE "deger -> pk" haritalarini serbest birakir.
var
  kv: TPair<Int64, TDictionary<string, string>>;
begin
  if FIdxUniq = nil then Exit;
  for kv in FIdxUniq do kv.Value.Free;
  FIdxUniq.Clear;
end;

procedure TVTableDb.DropIdxPend(const k: Int64);
// Bir indeks anahtarinin bekleyen islemlerini TAMAMEN at.
//
// ONEMLI: indeks yeniden kuruldugunda (BuildOneIndex / DropIndex) bekleyen
// islemler ONA EKLENMEZ. Once ekleniyordu; boylece "DROP INDEX; CREATE
// INDEX" sonrasi turetilmis (dogru) indeksin UZERINE bayat islemler tekrar
// oynaniyor ve indekste olmayan degerler ortaya cikiyordu (indeksli
// ORDER BY tam taramadan fazla satir donuyordu).
var
  l: TList<TIdxOp>;
  m: Integer;
  um: TDictionary<string, string>;
begin
  if FIdxOps.TryGetValue(k, l) then
  begin
    l.Free;
    FIdxOps.Remove(k);
  end;
  FIdxCtype.Remove(k);
  if FIdxUniq.TryGetValue(k, um) then
  begin
    um.Free;
    FIdxUniq.Remove(k);
  end;
  m := FIdxDirty.IndexOf(k);
  if m >= 0 then FIdxDirty.Delete(m);
end;

procedure TVTableDb.BuildIdxEntries(const T: TTableDef; IdxPos: Integer;
  out E: TIdxEntries; out Ctypes: TByteArray; out KeyCt: Byte);
// R-22 Full: tabloyu tarayip SIRALANMAMIS indeks girdilerini uretir.
// BuildOneIndex'in tarama yarisi buraya cikarildi: ayni kod hem eszamanli
// (senkron) kurulumda hem CONCURRENTLY anlik goruntusunda kullanilir.
// ANA THREAD'de cagrilmalidir (ScanRows motora erisir).
var
  pks: TStrArray;
  rows: TStrMatrix;
  i, ci, n: Integer;
  cols: TIntArray;
  pred, expr, key: string;
begin
  ci := T.Idx[IdxPos].Col;
  pred := T.Idx[IdxPos].Predicate;    // F-17 ('' = normal indeks)
  expr := T.Idx[IdxPos].ExprText;     // F-18 ('' = kolon indeksi)
  // indeks kolonlari (cok kolonlu ise Cols, degilse tek Col)
  // F-18: ifade indeksinde Col = -1'dir; anahtar ifadeden gelir.
  if expr <> '' then
    SetLength(cols, 0)
  else if Length(T.Idx[IdxPos].Cols) > 0 then
    cols := Copy(T.Idx[IdxPos].Cols, 0, Length(T.Idx[IdxPos].Cols))
  else
  begin
    SetLength(cols, 1);
    cols[0] := ci;
  end;
  SetLength(Ctypes, Length(cols));
  for i := 0 to High(cols) do Ctypes[i] := T.Cols[cols[i]].Ctype;
  KeyCt := 0;
  if expr <> '' then KeyCt := IdxCtypeOfPos(T, IdxPos);   // F-18
  ScanRows(T.Name, pks, rows);
  // F-17: PARTIAL indeks — yalniz kosulu saglayan satirlar alinir
  // F-18: ifade indeksi — anahtar ifadeden hesaplanir
  if (pred = '') and (expr = '') then
  begin
    SetLength(E, Length(pks));
    for i := 0 to High(pks) do
    begin
      E[i].Key := VDbIdxJoin(rows[i], cols);
      E[i].Pk := pks[i];
      E[i].Cov := VDbIdxJoin(rows[i], T.Idx[IdxPos].Incl);   // F-19
    end;
  end
  else
  begin
    n := 0;
    SetLength(E, Length(pks));
    for i := 0 to High(pks) do
      if VDbPredOK(pred, rows[i], T.Cols) then
      begin
        key := IdxKeyOfRow(T, IdxPos, rows[i]);
        // F-18: ifade hesaplanamadiysa satir indekslenmez
        if (expr <> '') and (key = '') then Continue;
        Inc(n);
        E[n - 1].Key := key;
        E[n - 1].Pk := pks[i];
        E[n - 1].Cov := VDbIdxJoin(rows[i], T.Idx[IdxPos].Incl);   // F-19
      end;
    if n < Length(E) then SetLength(E, n);
  end;
end;

procedure TVTableDb.BuildPkIdx(const T: TTableDef; out E: TIdxEntries);
// PK kolonu icin tembel (lazy) sirali index kurar. T.Idx'e KAYIT YAPMAZ;
// yalnizca FPkIdx'de saklanir. Boylece IndexNames/CheckConstraints/schema
// kayitlari etkilenmez (test kirilmaz), ancak BETWEEN/ORDER BY range
// query'leri bu sirali diziyi kullanarak indeks taramasi yapabilir.
// PK hash key oldugu icin point lookup O(1) kalir; bu index yalnizca
// aralik/ siralama sorgulari icin lazimdir.
var
  pks: TStrArray;
  dummy: TStrMatrix;
  i: Integer;
begin
  ScanRows(T.Name, pks, dummy);
  SetLength(E, Length(pks));
  for i := 0 to High(pks) do
  begin
    E[i].Key := pks[i];
    E[i].Pk := pks[i];
    E[i].Cov := '';
  end;
  SortIdxEntries(E, T.Cols[T.PkIndex].Ctype);
end;

procedure TVTableDb.BuildOneIndex(const T: TTableDef; IdxPos: Integer);
var
  e: TIdxEntries;
  i, ci: Integer;
  k: Int64;
  um: TDictionary<string, string>;
  ctypes: TByteArray;
  pred, expr: string;
  keyCt: Byte;   // F-18
begin
  ci := T.Idx[IdxPos].Col;
  pred := T.Idx[IdxPos].Predicate;    // F-17 ('' = normal indeks)
  expr := T.Idx[IdxPos].ExprText;     // F-18 ('' = kolon indeksi)

  k := IdxKeyPos(T, IdxPos);
  // indeks sifirdan kuruluyor -> bekleyen islemler gecersizdir
  DropIdxPend(k);
  // R-22: tarama + girdi uretimi ortak yardimcida (anlik goruntu aynisi
  // CONCURRENTLY insasinda da kullanilir).
  BuildIdxEntries(T, IdxPos, e, ctypes, keyCt);
  if expr <> '' then
  begin
    SetLength(ctypes, 1);
    ctypes[0] := keyCt;
    SortIdxEntriesCols(e, ctypes);
  end
  else if Length(T.Idx[IdxPos].Cols) > 1 then
    SortIdxEntriesCols(e, ctypes)
  else
    SortIdxEntries(e, T.Cols[ci].Ctype);
  FMemIdx.AddOrSetValue(k, e);
  if expr <> '' then
    FIdxCtype.AddOrSetValue(k, keyCt)     // F-18
  else
    FIdxCtype.AddOrSetValue(k, T.Cols[ci].Ctype);
  // UNIQUE kolonlarda "deger -> sahip pk" haritasini kur
  // F-17: bos (=NULL) anahtar haritaya yazilmaz.
  if (pred = '') and
     ((expr <> '') and T.Idx[IdxPos].Uniq or
      (expr = '') and (ci >= 0) and T.Cols[ci].Unique) then
  begin
    um := TDictionary<string, string>.Create;
    for i := 0 to High(e) do
      if e[i].Key <> '' then
        um.AddOrSetValue(e[i].Key, e[i].Pk);
    FIdxUniq.AddOrSetValue(k, um);
  end;
end;

function TVTableDb.FindIdxDefById(ATableId: Word; const AIndexName: string;
  out t: TTableDef; out IdxPos: Integer): Boolean;
// R-22 Full: kayit defterindeki (tablo kimligi, indeks adi) ciftini
// GUNCEL semada yeniden cozer. Arada DropTable/DropIndex/REINDEX olmus
// olabilir; cozulemezse False doner ve finalize sonucu ATILIR.
var
  nm: string;
  j: Integer;
begin
  Result := False;
  IdxPos := -1;
  if not FById.TryGetValue(ATableId, nm) then Exit;
  t := GetTable(nm);
  for j := 0 to High(t.Idx) do
    if t.Idx[j].Name = AIndexName then
    begin
      IdxPos := j;
      Result := True;
      Exit;
    end;
end;

procedure TVTableDb.StartConcBuild(const t: TTableDef; IdxPos: Integer);
// R-22 Full: CONCURRENTLY tanimi semaya yazildiktan sonra arka plan
// insasini baslatir. ANA THREAD'de cagrilir: ScanRows motora erisir ve
// sema cumle icinde sabittir. Is parcacigi yalnizca elindeki
// SIRALANMAMIS girdileri siralar; hicbir paylasilan duruma dokunmaz.
var
  e: TIdxEntries;
  ctypes: TByteArray;
  keyCt: Byte;
  multi: Boolean;
  singleCt: Byte;
  rec: TVdbConcRec;
begin
  BuildIdxEntries(t, IdxPos, e, ctypes, keyCt);
  // siralama bicimi (BuildOneIndex ile ayni kural)
  if t.Idx[IdxPos].ExprText <> '' then
  begin
    multi := True;
    SetLength(ctypes, 1);
    ctypes[0] := keyCt;
  end
  else
    multi := Length(t.Idx[IdxPos].Cols) > 1;
  singleCt := 0;
  if t.Idx[IdxPos].Col >= 0 then
    singleCt := t.Cols[t.Idx[IdxPos].Col].Ctype
  else if keyCt <> 0 then
    singleCt := keyCt;   // ifade indeksi (multi=True; kullanilmaz)
  rec.TableId := t.TableId;
  rec.IndexName := t.Idx[IdxPos].Name;
  rec.Builder := TVdbConcIdxBuilder.Create(Self, e, ctypes, singleCt, multi);
  FConcBuilders.Add(rec);
end;

procedure TVTableDb.StopConcBuilders(const AIndexName: string);
// R-22 Full: surmekte olan insalari durdurur ve SONUCTAN VAZGECER:
// indeks INVALID kalir (PostgreSQL'deki yarida kalan CONCURRENTLY insasi
// gibi; DROP INDEX ile temizlenir ya da yeniden kurulur). AIndexName
// bossa tumu durdurulur. Test kapisinin unutulmus olmasi sorun
// degildir: kapi burada acilir.
var
  i: Integer;
  rec: TVdbConcRec;
begin
  if FConcBuilders = nil then Exit;
  GVdbConcGateClosed := False;   // test kancasi kapatilir (kilitlenme yok)
  for i := FConcBuilders.Count - 1 downto 0 do
  begin
    rec := FConcBuilders[i];
    if (AIndexName <> '') and (rec.IndexName <> AIndexName) then Continue;
    rec.Builder.Terminate;
    rec.Builder.WaitFor;
    rec.Builder.Free;
    FConcBuilders.Delete(i);
  end;
end;

procedure TVTableDb.PollConcurrentIndexes(AForce: Boolean);
// R-22 Full: FINALIZE noktasi — ana thread'de her cumlenin basinda
// cagrilir. Bitmis (Finished) insalar bulunur ve sonuc kurulur:
//   1) siralanmis girdiler FMemIdx'e konur (anlik goruntu hali),
//   2) CATCH-UP: insa penceresinde biriken yazmalar FlushIdxPending
//      ile ustune uygulanir (bekleyen islemler satirin GUNCEL durumunu
//      tasir; eksiksiz ve mukerrersiz birlesim garanti),
//   3) UNIQUE haritasi NIHAI girdilerden kurulur,
//   4) Invalid=False yapilip semaya yazilir -> indeks artik okunur.
// Tanim (TableId, ad) cozulemezse sonuc ATILIR (arada DROP edilmis).
// AForce=True: bekleyen insalari da bitirir (AlterColumnType oncesi
// "temiz baslangic"); test kapisini de acar.
var
  i, pos, ci, m: Integer;
  rec: TVdbConcRec;
  t: TTableDef;
  k: Int64;
  e: TIdxEntries;
  um: TDictionary<string, string>;
begin
  if (FConcBuilders = nil) or (FConcBuilders.Count = 0) then Exit;
  if AForce then GVdbConcGateClosed := False;   // kilitlenme yok
  i := 0;
  while i < FConcBuilders.Count do
  begin
    rec := FConcBuilders[i];
    if AForce and (not rec.Builder.Finished) then
      rec.Builder.WaitFor;    // guvenli: saf CPU + kapi acik
    if not rec.Builder.Finished then begin Inc(i); Continue; end;
    if FindIdxDefById(rec.TableId, rec.IndexName, t, pos) and
       t.Idx[pos].Invalid then
    begin
      k := IdxKeyPos(t, pos);
      ci := t.Idx[pos].Col;
      // 1) siralanmis anlik goruntu girdileri
      FMemIdx.AddOrSetValue(k, rec.Builder.Entries);
      if t.Idx[pos].ExprText <> '' then
        FIdxCtype.AddOrSetValue(k, IdxCtypeOfPos(t, pos))
      else
        FIdxCtype.AddOrSetValue(k, t.Cols[ci].Ctype);
      // 2) CATCH-UP: insa penceresindeki yazmalar
      if FIdxDirty.IndexOf(k) >= 0 then
        FlushIdxPending(k);
      // 3) UNIQUE haritasi (BuildOneIndex ile ayni kural)
      if (t.Idx[pos].Predicate = '') and
         ((t.Idx[pos].ExprText <> '') and t.Idx[pos].Uniq or
          (t.Idx[pos].ExprText = '') and (ci >= 0) and t.Cols[ci].Unique) then
      begin
        um := TDictionary<string, string>.Create;
        if FMemIdx.TryGetValue(k, e) then
          for m := 0 to High(e) do
            if e[m].Key <> '' then
              um.AddOrSetValue(e[m].Key, e[m].Pk);
        FIdxUniq.AddOrSetValue(k, um);
      end;
      // 4) gecerlilik + kalicilik
      t.Idx[pos].Invalid := False;
      FTables.AddOrSetValue(t.Name, t);
      MarkSchema;
    end;
    rec.Builder.Free;
    FConcBuilders.Delete(i);
  end;
end;

function TVTableDb.ConcIdxBuildersActive: Integer;
begin
  if FConcBuilders = nil then Result := 0
  else Result := FConcBuilders.Count;
end;

function TVTableDb.IdxNParts(TableId: Word; ColIdx: Integer): Integer;
// Verilen kolona ait indeksin kac kolonu var (1 = tek kolonlu).
var
  nm: string;
  t: TTableDef;
  j: Integer;
begin
  Result := 1;
  if not FById.TryGetValue(TableId, nm) then Exit;
  t := GetTable(nm);
  for j := 0 to High(t.Idx) do
    if t.Idx[j].Col = ColIdx then
    begin
      if Length(t.Idx[j].Cols) > 0 then Result := Length(t.Idx[j].Cols)
      else Result := 1;
      Exit;
    end;
end;

function TVTableDb.IdxHasCol(const T: TTableDef; IdxPos, ColIdx: Integer): Boolean;
// F2-11: indeks tek kolonluysa Col, cok kolonluysa Cols listesiBakilir.
var
  k: Integer;
begin
  if (IdxPos < 0) or (IdxPos > High(T.Idx)) then Exit(False);
  if Length(T.Idx[IdxPos].Cols) > 0 then
  begin
    for k := 0 to High(T.Idx[IdxPos].Cols) do
      if T.Idx[IdxPos].Cols[k] = ColIdx then Exit(True);
    Result := False;
  end
  else
    Result := T.Idx[IdxPos].Col = ColIdx;
end;

function TVTableDb.IdxPosOfCol(TableId: Word; ColIdx: Integer): Integer;
// Kolona ait indeksin KONUMU (kisisel indeksler haric).
var
  nm: string;
  t: TTableDef;
  j: Integer;
begin
  Result := -1;
  if not FById.TryGetValue(TableId, nm) then Exit;
  t := GetTable(nm);
  for j := 0 to High(t.Idx) do
    if (t.Idx[j].Col = ColIdx) and (t.Idx[j].ExprText = '') then
    begin
      Result := j;
      Exit;
    end;
end;

function TVTableDb.ReadRowCovered(const Td: TTableDef; IdxPos: Integer;
  const Entry: TIdxEntry; out Vals: TStrArray): Boolean;
// F-19: INDEX-ONLY SCAN — satir tabloya OKUNMAKDAN indeks girdisinden
// olusturulur. Yalnizca indeks TUM kolonlari kapsiyorsa True doner
// (anahtar kolonlar + INCLUDE kolonlari). Kapsamiyorsa False doner ve
// cagiran normal ReadRow yoluna gecer.
//
// Guvenlik: kapsama denetimi KESIN olmalidir. Eksik bir kolon sessizce
// bos birakilirsa sorgu YANLIS SONUC verir; bu yuzden once tam kapsama
// dogrulanir, sonra degerler yerlestirilir.
var
  j, q, seen: Integer;
  kc: TIntArray;
  ok: Boolean;
begin
  Result := False;
  SetLength(Vals, 0);
  if (IdxPos < 0) or (IdxPos > High(Td.Idx)) then Exit;
  if Length(Td.Cols) = 0 then Exit;
  if Length(Td.Idx[IdxPos].Cols) > 0 then
    kc := Td.Idx[IdxPos].Cols
  else
    kc := [Td.Idx[IdxPos].Col];
  // 1) kapsama denetimi — eksik herhangi bir kolon varsa bu yol kullanilmaz
  // PK kolonu OZELDIR: satir adresi (Entry.Pk) zaten PK degerini icerir,
  // bu yuzden PK kolonu kapsama sayilir (PostgreSQL'deki "index stores the
  // TID + PK" davranisi).
  for q := 0 to High(Td.Cols) do
  begin
    if q = Td.PkIndex then Continue;
    ok := False;
    for j := 0 to High(kc) do
      if (kc[j] >= 0) and (kc[j] = q) then
      begin
        ok := True;
        Break;
      end;
    if not ok then
      for j := 0 to High(Td.Idx[IdxPos].Incl) do
        if Td.Idx[IdxPos].Incl[j] = q then
        begin
          ok := True;
          Break;
        end;
    if not ok then Exit(False);
  end;
  // 2) degerleri yerlestir
  SetLength(Vals, Length(Td.Cols));
  for q := 0 to High(Td.Cols) do Vals[q] := '';
  // PK kolonu satir adresinden gelir
  if (Td.PkIndex >= 0) and (Td.PkIndex < Length(Vals)) then
    Vals[Td.PkIndex] := Entry.Pk;
  if Length(kc) = 1 then
    Vals[kc[0]] := Entry.Key                        // tek parca: ham deger
  else
    for j := 0 to High(kc) do
      if (kc[j] >= 0) and (kc[j] < Length(Vals)) then
        Vals[kc[j]] := VDbIdxPartOf(Entry.Key, j);
  for j := 0 to High(Td.Idx[IdxPos].Incl) do
    if (Td.Idx[IdxPos].Incl[j] >= 0) and
       (Td.Idx[IdxPos].Incl[j] < Length(Vals)) then
      Vals[Td.Idx[IdxPos].Incl[j]] :=
        VDbIdxPartOf(Entry.Cov, j);
  Result := True;
end;

function TVTableDb.IdxCoversAll(const Td: TTableDef; IdxPos: Integer): Boolean;
// Indeks tablonun TUM kolonlarini kapsiyor mu? (index-only tarama icin)
var
  q, j: Integer;
  kc: TIntArray;
  ok: Boolean;
begin
  Result := False;
  if (IdxPos < 0) or (IdxPos > High(Td.Idx)) then Exit;
  if Length(Td.Cols) = 0 then Exit;
  if Length(Td.Idx[IdxPos].Cols) > 0 then
    kc := Td.Idx[IdxPos].Cols
  else
    kc := [Td.Idx[IdxPos].Col];
  for q := 0 to High(Td.Cols) do
  begin
    if q = Td.PkIndex then Continue;   // PK satir adresinde zaten var
    ok := False;
    for j := 0 to High(kc) do
      if (kc[j] >= 0) and (kc[j] = q) then
      begin
        ok := True;
        Break;
      end;
    if not ok then
      for j := 0 to High(Td.Idx[IdxPos].Incl) do
        if Td.Idx[IdxPos].Incl[j] = q then
        begin
          ok := True;
          Break;
        end;
    if not ok then Exit(False);
  end;
  Result := True;
end;

function TVTableDb.IdxPosOfName(const Table, IdxName: string): Integer;
// F-19: indeks ADI -> konum. EXPLAIN plan ciktisinda kullanilir.
var
  t: TTableDef;
  j: Integer;
  nm: string;
begin
  Result := -1;
  nm := VDbNorm(IdxName);
  // UNIQUE indeksler semada '!' onekiyle yazilir; burada o onek atilir.
  if (Length(nm) > 0) and (nm[1] = '!') then
    nm := Copy(nm, 2, MaxInt);
  nm := VDbNorm(nm);
  try
    t := GetTable(Table);
  except
    Exit(-1);
  end;
  for j := 0 to High(t.Idx) do
    if t.Idx[j].Name = nm then
    begin
      Result := j;
      Exit;
    end;
end;

function TVTableDb.IdxEntryCount(TableId: Word; IdxPos: Integer): Integer;
// F-17: indekteki KAYIT SAYISI (SHOW INDEXES "nentries"). Partial indekslerde
// bu sayi tablo satir sayisindan KUCUK olabilir — indeksin icerigini
// dogrulamak icin tek gozlenebilir olcutur.
// DIKKAT: bekleyen yazma islemleri ONCE uygulanir; aksi halde "simdi kaç
// kayit var" sorusu bayat bir durumu raporlar (TryGetMemIndex ile ayni kural).
var
  k: Int64;
  e: TIdxEntries;
  nm: string;
  t: TTableDef;
begin
  Result := -1;   // -1 = indeks bellekte degil / yok
  if not FById.TryGetValue(TableId, nm) then Exit;
  t := GetTable(nm);
  if (IdxPos < 0) or (IdxPos > High(t.Idx)) then Exit;
  // R-22: INVALID indeks (concurrent insa suruyor / yarida kaldi)
  // okunmaz, kurulmaz, bekleyen islemleri FLUSH EDILMEZ: -1 doner.
  if t.Idx[IdxPos].Invalid then Exit;
  k := IdxKeyPos(t, IdxPos);
  if FIdxDirty.IndexOf(k) >= 0 then
    FlushIdxPending(k);
  // Indeksler TENBEL kurulur; "kac kayit var" sorusu bunu yine de
  // yanitlayabilmelidir, yoksa SHOW INDEXES ilk acikta -1 gosterirdi.
  if not FMemIdx.ContainsKey(k) then
    BuildOneIndex(t, IdxPos);
  if not FMemIdx.TryGetValue(k, e) then Exit;
  Result := Length(e);
end;

function TVTableDb.IdxColsOfPosTable(TableId: Word; IdxPos: Integer): TIntArray;
// F-17: indeks KONUMU ile kolon listesi (partial/normal ayirt edilir)
var
  nm: string;
  t: TTableDef;
begin
  SetLength(Result, 0);
  if not FById.TryGetValue(TableId, nm) then Exit;
  t := GetTable(nm);
  if (IdxPos < 0) or (IdxPos > High(t.Idx)) then Exit;
  Result := IdxColsOf(t, IdxPos);
end;

function TVTableDb.IdxColsOfTable(TableId: Word; ColIdx: Integer): TIntArray;
// Verilen kolona ait indeksin kolon listesi
var
  nm: string;
  t: TTableDef;
  j: Integer;
begin
  SetLength(Result, 0);
  if not FById.TryGetValue(TableId, nm) then Exit;
  t := GetTable(nm);
  for j := 0 to High(t.Idx) do
    if t.Idx[j].Col = ColIdx then
    begin
      Result := IdxColsOf(t, j);
      Exit;
    end;
end;

function TVTableDb.IdxColsOf(const T: TTableDef; IdxPos: Integer): TIntArray;
// indeksin kolon listesi (tek kolonlu ise {Col})
begin
  if Length(T.Idx[IdxPos].Cols) > 0 then
    Result := Copy(T.Idx[IdxPos].Cols, 0, Length(T.Idx[IdxPos].Cols))
  else
  begin
    SetLength(Result, 1);
    Result[0] := T.Idx[IdxPos].Col;
  end;
end;

function TVTableDb.IdxCtypesOf(const T: TTableDef; IdxPos: Integer): TByteArray;
// indeks kolonlarinin tipleri (cok kolonlu ise sirayla)
var
  cols: TIntArray;
  i: Integer;
begin
  cols := IdxColsOf(T, IdxPos);
  SetLength(Result, Length(cols));
  for i := 0 to High(cols) do
    Result[i] := T.Cols[cols[i]].Ctype;
end;

procedure TVTableDb.IdxKeysOfRow(const T: TTableDef; const Vals: TStrArray;
  out Keys: TStrArray);
// Satirin her indeks icin anahtarini hesaplar (cok kolonlu destekli).
// Keys[j] = t.Idx[j] icin anahtar.
var
  j: Integer;
begin
  SetLength(Keys, Length(T.Idx));
  for j := 0 to High(T.Idx) do
    Keys[j] := VDbIdxJoin(Vals, IdxColsOf(T, j));
end;

procedure TVTableDb.RebuildIndexes;
var
  kv: TPair<string, TTableDef>;
  j: Integer;
begin
  // R-22: tum indeksler veriden yeniden kurulacagi icin surmekte olan
  // CONCURRENTLY insalari iptal edilir (INVALID kalirlar).
  StopConcBuilders;
  FMemIdx.Clear;
  FreeIdxPend;
  for kv in FTables do
    for j := 0 to High(kv.Value.Idx) do
      if not kv.Value.Idx[j].Invalid then   // R-22: INVALID kurulmaz
        BuildOneIndex(kv.Value, j);
end;

procedure TVTableDb.RewriteTable(const T: TTableDef; const asmap: TIntArray);
// Tablonun tum satirlarini yeni semaya (T) gore yeniden kodlar.
// asmap[i] = yeni sema sutunu i icin kaynak (eski) kolon indeksi,
//             -1 ise o sutun yeni eklenmis -> NULL.
// Motor append-only: eski key'ler tombstone ile dusurulur, yeniler yazilir.
// DDL oldugu icin FKv.BeginBatch yalnizca disaridan batch gelmediyse
// cagrilir (ic ice batch hatasi olmaz).
var
  keys: TQWordArray;
  raw: TValArray;
  oldKeys: TQWordArray;
  pks: TStrArray;
  oldRows: TStrMatrix;
  newRows: TStrMatrix;
  nv: TStrArray;
  nb: TBytes;
  tid: Word;
  pk: string;
  i, j, sj: Integer;
  ownBatch: Boolean;
  b: TBytes;
  exTid: Word;
  exPk: string;
  exVals: TStrArray;
begin
  // 1) Eski satirlari topla (dosyadan, eski semaya gore)
  // ONEMLI: once hepsini cozup KOPYALIYORUZ. Ara adimda (orn. index
  // erisimi) ScanAll tekrar cagrilirsa paylasilan dizi uzerine
    // yazilir ve asagidaki satirlar bozulur -> access violation.
    FKv.ScanAll(keys, raw, T.TableId);   // R-26: yalnizca bu tablonun satirlari
  SetLength(oldKeys, 0);
  SetLength(pks, 0);
  SetLength(oldRows, 0);
  for i := 0 to High(keys) do
  begin
    if keys[i] = VDB_SCHEMA_KEY then Continue;
    if not DecodeRow(raw[i], tid, pk, nv) then Continue;
    if tid <> T.TableId then Continue;
    SetLength(oldKeys, Length(oldKeys) + 1);
    SetLength(pks, Length(pks) + 1);
    SetLength(oldRows, Length(oldRows) + 1);
    oldKeys[High(oldKeys)] := keys[i];
    pks[High(pks)] := pk;
    // kopyala: nv yeniden kullanilacak
    oldRows[High(oldRows)] := Copy(nv, 0, Length(nv));
  end;
  // cozum bittikten sonra paylasilan arabellek artik gerekmez
  SetLength(raw, 0);
  SetLength(keys, 0);

  // 2) Yeni satirlari uret: her satir icin yeni sema dizisini olustur
  SetLength(newRows, Length(pks));
  for i := 0 to High(pks) do
  begin
    SetLength(newRows[i], Length(T.Cols));
    for j := 0 to High(T.Cols) do
    begin
      newRows[i][j] := '';
      sj := asmap[j];
      if (sj >= 0) and (sj < Length(oldRows[i])) then
        newRows[i][j] := oldRows[i][sj];
    end;
  end;

  ownBatch := not FKv.InBatch;
  if ownBatch then FKv.BeginBatch;
  try
    for i := 0 to High(oldKeys) do
    begin
      // F1-8: silmeden once hash'in gercekten bu satiri gosterdigini dogrula.
      if FKv.Get(oldKeys[i], b) then
      begin
        if not DecodeRow(b, exTid, exPk, exVals) then
          raise EVDbException.CreateFmt(ecCorrupt,
            'VDb: hash ile isaretlenen satir bozuk (tablo=%s, pk=%s)', [T.Name, pks[i]]);
        if (exTid <> T.TableId) or (exPk <> pks[i]) then
          raise EVDbException.CreateFmt(ecHashCollision, 'VDb: hash carpismasi (tablo=%s, pk=%s)', [T.Name, pks[i]]);
      end;
      FKv.Delete(oldKeys[i]);
    end;
    for i := 0 to High(pks) do
    begin
      nb := EncodeRow(T.TableId, pks[i], T, newRows[i]);
      FKv.Put(VDbHashKey(T.Name, pks[i]), nb);
    end;
    if ownBatch then FKv.CommitBatch;
  except
    if ownBatch then AbortBatch;
    raise;
  end;
end;

{ ------------------------------------------------------------ ALTER TABLE }

function TVTableDb.SqlTypeToCtype(const S: string): Byte;
begin
  Result := VDbTypeFromName(S);
end;

procedure TVTableDb.RewriteTableRows(const T: TTableDef; const asmap: TIntArray;
  const Pks: TStrArray; const Rows: TStrMatrix);
// RewriteTable'in satirlar ONCEDEN hazirlandigi varyant (ALTER COLUMN
// TYPE: satirlar yeni tipe gore normallenmis gelir).
var
  newRows: TStrMatrix;
  nb: TBytes;
  i, j, sj: Integer;
  ownBatch: Boolean;
  b: TBytes;
  exTid: Word;
  exPk: string;
  exVals: TStrArray;
begin
  SetLength(newRows, Length(Pks));
  for i := 0 to High(Pks) do
  begin
    SetLength(newRows[i], Length(T.Cols));
    for j := 0 to High(T.Cols) do
    begin
      newRows[i][j] := '';
      sj := asmap[j];
      if (sj >= 0) and (sj < Length(Rows[i])) then
        newRows[i][j] := Rows[i][sj];
    end;
  end;
  ownBatch := not FKv.InBatch;
  if ownBatch then FKv.BeginBatch;
  try
    for i := 0 to High(Pks) do
    begin
      // F1-8: silmeden once hash'in gercekten bu satiri gosterdigini dogrula.
      if FKv.Get(VDbHashKey(T.Name, Pks[i]), b) then
      begin
        if not DecodeRow(b, exTid, exPk, exVals) then
          raise EVDbException.CreateFmt(ecCorrupt,
            'VDb: hash ile isaretlenen satir bozuk (%s, %s)', [T.Name, Pks[i]]);
        if (exTid <> T.TableId) or (exPk <> Pks[i]) then
          raise EVDbException.CreateFmt(ecHashCollision, 'VDb: hash carpismasi (%s, %s)', [T.Name, Pks[i]]);
      end;
      FKv.Delete(VDbHashKey(T.Name, Pks[i]));
    end;
    for i := 0 to High(Pks) do
    begin
      nb := EncodeRow(T.TableId, Pks[i], T, newRows[i]);
      FKv.Put(VDbHashKey(T.Name, Pks[i]), nb);
    end;
    if ownBatch then FKv.CommitBatch;
  except
    if ownBatch then AbortBatch;
    raise;
  end;
end;

procedure TVTableDb.CloneDef(const Src: TTableDef; out Dst: TTableDef);
// DERIN KOPYA. TTableDef icinde yonlendirilmis diziler (Cols/Idx/Fks/
// Checks) var; sadece 'nt := t' yazmak onlari PAYLASIR. Sonra
// nt.Idx[i].Col := ... yazimi t'yi de bozuyor (sema + bellek uyumsuz,
// access violation). Bu yuzden her alan ayri ayri kopyalanir.
var
  i, j: Integer;
begin
  Dst.TableId := Src.TableId;
  Dst.Name := Src.Name;
  Dst.PkIndex := Src.PkIndex;
  Dst.AutoInc := Src.AutoInc;
  // DIKKAT (F-33/F-34): bu dort alan ONCEDEN kopyalanmiyordu. ALTER TABLE
  // her zaman CloneDef uzerinden yeni sema urettigi icin bir tabloya
  // "ALTER TABLE ... DROP COLUMN" uygulaninca IsView bayragi COZULMEMIS
  // bir deger aliyordu; normal tablo "view" saniliyor ve
  // "view uzerine INSERT yapilamaz (guncellenemez view): di" hatasi
  // veriyordu. Eksik alan = sessiz veri bozulmasi.
  Dst.IsView := Src.IsView;
  Dst.IsMaterializedView := Src.IsMaterializedView;
  Dst.SelectStmt := Src.SelectStmt;
  Dst.SelectText := Src.SelectText;
  SetLength(Dst.Cols, Length(Src.Cols));
  for i := 0 to High(Src.Cols) do Dst.Cols[i] := Src.Cols[i];
  SetLength(Dst.Idx, Length(Src.Idx));
  for i := 0 to High(Src.Idx) do Dst.Idx[i] := Src.Idx[i];
  SetLength(Dst.Fks, Length(Src.Fks));
  for i := 0 to High(Src.Fks) do Dst.Fks[i] := Src.Fks[i];
  SetLength(Dst.Checks, Length(Src.Checks));
  for i := 0 to High(Src.Checks) do
  begin
    SetLength(Dst.Checks[i], Length(Src.Checks[i]));
    for j := 0 to High(Src.Checks[i]) do
      Dst.Checks[i][j] := Src.Checks[i][j];
  end;
end;

procedure TVTableDb.FixCheckCols(var T: TTableDef; const asmap: TIntArray);
// CHECK kosullarindaki KOLON INDEKSLERI eski semaya gore yazilmis.
// Sema degisince (ekleme/drop/rename) yeniden eslenir. Silinen kolona
// bagli CHECK kosulu kaldirilir.
var
  i, j, n: Integer;
  keep: array of Boolean;
  g: TWhereGroup;
begin
  SetLength(keep, Length(T.Checks));
  for i := 0 to High(T.Checks) do
  begin
    keep[i] := True;
    for j := 0 to High(T.Checks[i]) do
    begin
      n := asmap[T.Checks[i][j].Col];
      if n < 0 then keep[i] := False
      else T.Checks[i][j].Col := n;
    end;
  end;
  n := 0;
  for i := 0 to High(T.Checks) do
    if keep[i] then Inc(n);
  SetLength(g, 0);
  if n > 0 then
  begin
    SetLength(T.Checks, n);
    n := 0;
    for i := 0 to High(keep) do
      if keep[i] then
      begin
        T.Checks[n] := T.Checks[i];
        Inc(n);
      end;
  end
  else
    SetLength(T.Checks, 0);
end;

procedure TVTableDb.AlterAddColumn(const Table: string; const Col: TColDef;
  const After: string; const HasDef: Boolean; const DefVal: string);
var
  t, nt: TTableDef;
  amap: TIntArray;
  i, j, pos, nOld: Integer;
  ownDdl: Boolean;
  c2: TColDef;
  v: string;
  pks: TStrArray;
  rows: TStrMatrix;
begin
  t := GetTable(Table);
  nOld := Length(t.Cols);
  if FindCol(t, Col.Name) >= 0 then
    raise EVDbException.Create(ecColumnExists, 'kolon var: ' + Col.Name);
  if Trim(Col.Name) = '' then raise EVDbException.Create(ecInvalidName, 'kolon adi bos olamaz');
  c2 := Col;
  c2.Name := VDbNorm(Col.Name);
  // DEFAULT tip dogrulugu
  v := '';
  if HasDef and (DefVal <> '') then
    v := VDbNormValue(c2.Ctype, DefVal);
  c2.HasDef := HasDef;
  c2.Def := v;

  // F1-7: NOT NULL kontrolu REWRITETABLE'DAN ONCE yapilir.
  // Yeni kolon mevcut satirlarda NULL kalir; NOT NULL + (DEFAULT yok/bos)
  // ile dolu tabloda tum satirlar NULL icin constraint'i ihlal eder.
  if c2.NotNull and (not HasDef or (DefVal = '')) then
  begin
    SetLength(pks, 0); SetLength(rows, 0);
    ScanRows(t.Name, pks, rows);
    if Length(rows) > 0 then
      raise EVDbException.Create(ecNotNullViolation,
        'NOT NULL eklenemez: mevcut satirlar NULL kalir (' +
        t.Name + ', ' + IntToStr(Length(rows)) + ' satir)');
  end;

  CloneDef(t, nt);
  // konum: AFTER kolon varsa hemen sonrasi, yoksa sona ekle
  pos := nOld;
  if After <> '' then
  begin
    pos := FindCol(t, After);
    if pos < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + After);
    Inc(pos);
  end;
  SetLength(nt.Cols, nOld + 1);
  for i := 0 to pos - 1 do nt.Cols[i] := t.Cols[i];
  nt.Cols[pos] := c2;
  for i := pos to nOld - 1 do nt.Cols[i + 1] := t.Cols[i];
  if nt.PkIndex >= pos then Inc(nt.PkIndex);

  // eski sutunlar ayni sirada kalir
  SetLength(amap, Length(nt.Cols));
  for i := 0 to High(amap) do
    if i < pos then amap[i] := i
    else if i = pos then amap[i] := -1   // yeni sutun: NULL
    else amap[i] := i - 1;

  // index konumlarini kaydir (yeni sutundan sonraki)
  for i := 0 to High(nt.Idx) do
    if nt.Idx[i].Col >= pos then Inc(nt.Idx[i].Col);
  FixCheckCols(nt, amap);

  // F2-9: DDL ATOMIKLIGI. Veri yeniden kodlamasi ile sema yazimi ARTIK
  // AYRI AYRI fsync EDILIYORDU: veri commit -> sema commit arasinda
  // crash olursa tablo yeni duzenli veri + eski sema ile kalir ve
  // okunamaz hale gelir. Artik ikisi TEK batch'te: veri + sema tek
  // fsync ile birlikte kalici olur. Basarisizlikta AbortBatch hem
  // veriyi hem semayi geri alir.
  ownDdl := not FKv.InBatch;
  if ownDdl then BeginBatch;
  try
    RewriteTable(nt, amap);
    FTables.AddOrSetValue(nt.Name, nt);
    MarkSchema;
    if ownDdl then CommitBatch;
  except
    if ownDdl then AbortBatch;
    raise;
  end;
end;

procedure TVTableDb.AlterDropColumn(const Table, Column: string);
var
  t, nt: TTableDef;
  amap: TIntArray;
  i, j, ci, nOld: Integer;
  ownDdl: Boolean;
  kv: TPair<string, TTableDef>;
  nm: string;
begin
  t := GetTable(Table);
  nOld := Length(t.Cols);
  ci := FindCol(t, Column);
  if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Column);
  // F2-22: PkIndex<0 ise PK tanimlanmamis; koruma uygulanmaz.
  if (t.PkIndex >= 0) and (ci = t.PkIndex) then
    raise EVDbException.Create(ecUnsupported, 'PK kolonu dusurulemez');
  if nOld <= 1 then
    raise EVDbException.Create(ecUnsupported, 'son kolon dusurulemez');
  // bu kolona FK referansi var mi?
  nm := VDbNorm(Table);
  for kv in FTables do
  begin
    if kv.Key = nm then Continue;
    for j := 0 to High(kv.Value.Fks) do
      if (kv.Value.Fks[j].RefTable = nm) and
         (FindCol(t, kv.Value.Fks[j].RefCol) = ci) then
        raise EVDbException.CreateFmt(ecForeignKeyViolation, 'kolon FK hedefi: %s.%s kullaniliyor',
          [kv.Key, kv.Value.Fks[j].RefCol]);
  end;

  CloneDef(t, nt);
  SetLength(nt.Cols, nOld - 1);
  for i := 0 to ci - 1 do nt.Cols[i] := t.Cols[i];
  for i := ci + 1 to nOld - 1 do nt.Cols[i - 1] := t.Cols[i];
  if nt.PkIndex > ci then Dec(nt.PkIndex);

  SetLength(amap, nOld - 1);
  for i := 0 to High(amap) do
    if i < ci then amap[i] := i else amap[i] := i + 1;

  // Bu kolonu iceren indeks(ler)i kaldir.
  // F2-11: ONCEDEN yalniz `Idx[i].Col = ci` (tek kolonlu indeks) bakiliyordu;
  //  - cok kolonlu indeks bu kolonu iceriyorsa GORULMUYORDU ve o indeks
  //    yanlis Col konumuyla birakiyordu,
  //  - kaldirilan indeksin BEKLEYEN islemleri (FIdxOps), tip bilgisi
  //    (FIdxCtype) ve UNIQUE haritasi (FIdxUniq) TEMIZLENMIYORDU; sonraki
  //    bir ayni konumlu indeks eski bekleyenleri miras aliyordu.
  j := -1;
  for i := 0 to High(nt.Idx) do
    if IdxHasCol(nt, i, ci) then begin j := i; Break; end;
  if j >= 0 then
  begin
    // F2-11: bekleyen indeks islemlerini de at
    for i := 0 to High(nt.Idx) do
      if IdxHasCol(nt, i, ci) then
      begin
        DropIdxPend(IdxKey(t.TableId, nt.Idx[i].Col));
        FMemIdx.Remove(IdxKey(t.TableId, nt.Idx[i].Col));
      end;
    for i := j to High(nt.Idx) - 1 do nt.Idx[i] := nt.Idx[i + 1];
    SetLength(nt.Idx, Length(nt.Idx) - 1);
    for i := 0 to High(nt.Idx) do
      if nt.Idx[i].Col > ci then Dec(nt.Idx[i].Col);
  end
  else
    for i := 0 to High(nt.Idx) do
    begin
      if nt.Idx[i].Col > ci then Dec(nt.Idx[i].Col);
      if Length(nt.Idx[i].Cols) > 0 then
        for j := 0 to High(nt.Idx[i].Cols) do
          if nt.Idx[i].Cols[j] > ci then Dec(nt.Idx[i].Cols[j]);
    end;
  // FK'larin KAYNAK kolonu ise: o FK gecersiz olurdu -> hata.
  // (NOT: mesajda nt.Fks kullanilir; t.Fks yazilirsa yanlis tablo adi
  //  bildirilir.)
  for i := 0 to High(nt.Fks) do
    if nt.Fks[i].Col = ci then
      raise EVDbException.CreateFmt(ecForeignKeyViolation,
        'FK kaynak kolonu dusurulemez: %s.%s', [nt.Name, nt.Fks[i].RefTable]);
  FixCheckCols(nt, amap);

  // F2-9: veri + sema tek batch'te (bkz. AlterAddColumn). Bu yol
  // sarmalamadan kalmisti: veri commit -> sema commit arasinda crash
  // olursa tablo yeni duzenli veri + eski sema ile kalirdi.
  ownDdl := not FKv.InBatch;
  if ownDdl then BeginBatch;
  try
    RewriteTable(nt, amap);
    FTables.AddOrSetValue(nt.Name, nt);
    MarkSchema;
    if ownDdl then CommitBatch;
  except
    if ownDdl then AbortBatch;
    raise;
  end;
end;

procedure TVTableDb.AlterRenameColumn(const Table, OldName, NewName: string);
var
  t, nt: TTableDef;
  amap: TIntArray;
  i, ci: Integer;
  ownDdl: Boolean;
  nn: string;
begin
  t := GetTable(Table);
  ci := FindCol(t, OldName);
  if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + OldName);
  if Trim(NewName) = '' then raise EVDbException.Create(ecInvalidName, 'yeni ad bos olamaz');
  nn := VDbNorm(NewName);
  if nn = VDbNorm(OldName) then Exit; // degisiklik yok
  if FindCol(t, nn) >= 0 then raise EVDbException.Create(ecColumnExists, 'kolon var: ' + NewName);
  CloneDef(t, nt);
  nt.Cols[ci].Name := nn;
  // CHECK/Idx/FK referanslari KOLON ADIYLA bagli, indeks degismiyor
  SetLength(amap, Length(t.Cols));
  for i := 0 to High(amap) do amap[i] := i;
  // isim degisince satirlar da degisir -> yeniden kodla
  // F2-9: veri + sema tek batch'te (bkz. AlterAddColumn).
  ownDdl := not FKv.InBatch;
  if ownDdl then BeginBatch;
  try
    RewriteTable(nt, amap);
    FTables.AddOrSetValue(nt.Name, nt);
    MarkSchema;
    if ownDdl then CommitBatch;
  except
    if ownDdl then AbortBatch;
    raise;
  end;
end;
procedure TVTableDb.AlterColumnType(const Table, Column, NewType: string);
var
  t, nt: TTableDef;
  amap: TIntArray;
  i, ci, nc: Integer;
  ownDdl: Boolean;
  pks: TStrArray;
  rows: TStrMatrix;
  v: string;
  p2: TStrArray;
begin
  t := GetTable(Table);
  ci := FindCol(t, Column);
  if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Column);
  // F2-10: PK kolonunun tipi DEGISTIRILEMEZ. Satir anahtari dosyada
  // metin olarak saklanir; tip cevirisi PK'yi donusturebilir (veya
  // ceviremez). Normalde zaten 'UPDATE PK guncellenemez' kurali var,
  // ama ALTER bu kalkani atlayarak PK'i baska bir tipe cevirebiliyordu.
  // F2-22: PkIndex<0 ise PK tanimlanmamis; koruma uygulanmaz.
  if (t.PkIndex >= 0) and (ci = t.PkIndex) then
    raise EVDbException.Create(ecUnsupported,
      'PK kolonunun tipi degistirilemez: ' + t.Name + '.' + t.Cols[ci].Name);
  nc := SqlTypeToCtype(NewType);
  if nc = t.Cols[ci].Ctype then Exit;
  // R-22 Full: kolon tipi degisirken anahtar bicimi de degisebilir.
  // Surmekte olan CONCURRENTLY insalari ONCEDEN finalize et (AForce):
  // boylece tip degisikligi sonrasi kurulan indeksler guncel bicimle
  // insa edilir; yarida kalan (reopened-invalid) indeks ise kurulmaz.
  PollConcurrentIndexes(True);
  // NOT: tip degisince tum satirlar yeni tipe gore yeniden normallenir.
  // Donusturulemeyen deger hata verir (veri kaybi sessiz olmaz).
  SetLength(pks, 0); SetLength(rows, 0);
  ScanRows(t.Name, pks, rows);
  for i := 0 to High(rows) do
  begin
    v := rows[i][ci];
    if v <> '' then
    begin
      try
        rows[i][ci] := VDbNormValue(nc, v);
      except
        on E: Exception do
          raise EVDbException.CreateFmt(ecTypeMismatch, 'tip degistirilemedi (satir %s, deger "%s"): %s',
            [pks[i], v, E.Message]);
      end;
    end;
  end;
  CloneDef(t, nt);
  nt.Cols[ci].Ctype := nc;
  if nt.Cols[ci].HasDef then
    nt.Cols[ci].Def := VDbNormValue(nc, nt.Cols[ci].Def);
  // F2-10: YENI tip altinda SATIRLAR yeniden dogrulanir. Once yalnizca
  // deger normallestiriliyordu; boylece mesela INTEGER -> TEXT sonrasi
  // CHECK (n > 5) veya FK hedefi degisikligi mevcut satirlari ihlal
  // ediyor olabiliyor ve sema yine de yaziliyordu (bozuk tablo).
  for i := 0 to High(rows) do
  begin
    if not VDbCheckOK(rows[i], nt.Checks) then
      raise EVDbException.CreateFmt(ecCheckViolation,
        'tip degistirilemedi: %s.%s CHECK ihlali (satir %s, sutun "%s")',
        [t.Name, t.Cols[ci].Name, pks[i], v]);
  end;
  // FK hedefi olarak kullaniliyorsa yeni tipte de ayni degerler aranir;
  // tip cevirisi degeri degistirdiyse cocuklarin isaretleri bozulur.
  if FindCol(t, Column) = ci then
  begin
    for i := 0 to High(t.Fks) do
      if (t.Fks[i].Col = ci) and (t.Fks[i].RefTable <> '') then
        raise EVDbException.CreateFmt(ecUnsupported,
          'FK kaynak kolonunun tipi degistirilemez: %s.%s (FK tanimi var)',
          [t.Name, t.Cols[ci].Name]);
  end;
  SetLength(amap, Length(t.Cols));
  for i := 0 to High(amap) do amap[i] := i;
  // F2-9: veri + sema tek batch'te (bkz. AlterAddColumn). Indeks
  // yeniden kurulumu da ayni batch icinde (veriden turetilir).
  ownDdl := not FKv.InBatch;
  if ownDdl then BeginBatch;
  try
    // rows zaten normallestigine gore dogrudan yeniden kodla
    RewriteTableRows(nt, amap, pks, rows);
    FTables.AddOrSetValue(nt.Name, nt);
    MarkSchema;
    // index siralamasi degisebilir -> yeniden kur
    for i := 0 to High(nt.Idx) do
      if (nt.Idx[i].Col = ci) and not nt.Idx[i].Invalid then   // R-22
        BuildOneIndex(nt, i);
    if ownDdl then CommitBatch;
  except
    if ownDdl then AbortBatch;
    raise;
  end;
end;

procedure TVTableDb.AlterSetDefault(const Table, Column: string;
  const HasDef: Boolean; const DefVal: string);
var
  t: TTableDef;
  ci: Integer;
begin
  t := GetTable(Table);
  ci := FindCol(t, Column);
  if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Column);
  t.Cols[ci].HasDef := HasDef;
  t.Cols[ci].Def := '';
  if HasDef then
    t.Cols[ci].Def := VDbNormValue(t.Cols[ci].Ctype, DefVal);
  FTables.AddOrSetValue(t.Name, t);
  MarkSchema;
end;

procedure TVTableDb.AlterDropDefault(const Table, Column: string);
begin
  AlterSetDefault(Table, Column, False, '');
end;

procedure TVTableDb.AlterSetNotNull(const Table, Column: string; const On: Boolean);
var
  t: TTableDef;
  ci, i: Integer;
  pks: TStrArray;
  rows: TStrMatrix;
begin
  t := GetTable(Table);
  ci := FindCol(t, Column);
  if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Column);
  // PK her zaman NOT NULL'dur: NULL PK satiri olusturulamaz cunku
  // anahtar bos kalir. Kaldirmaya calisirsa reddet.
  // F2-22: PkIndex<0 ise PK yok; koruma uygulanmaz.
  if (not On) and (t.PkIndex >= 0) and (ci = t.PkIndex) then
    raise EVDbException.Create(ecNotNullViolation, 'PK kolonu NOT NULL olamaz');
  if On then
  begin
    // mevcut NULL satirlar varsa kurulamaz
    SetLength(pks, 0); SetLength(rows, 0);
    ScanRows(t.Name, pks, rows);
    for i := 0 to High(rows) do
      if rows[i][ci] = '' then
        raise EVDbException.Create(ecNotNullViolation, 'NOT NULL yapilamaz, NULL satirlar var (satir ' + pks[i] + ')');
  end;
  t.Cols[ci].NotNull := On;
  FTables.AddOrSetValue(t.Name, t);
  MarkSchema;
end;

procedure TVTableDb.AlterRenameTable(const OldName, NewName: string);
var
  t, nt: TTableDef;
  keys: TQWordArray;
  raw: TValArray;
  nv: TStrArray;
  nb: TBytes;
  ob: TBytes;
  tid: Word;
  otid: Word;
  opk: string;
  ovals: TStrArray;
  pk: string;
  i, j: Integer;
  ownBatch: Boolean;
  nn, old: string;
  kv: TPair<string, TTableDef>;
  t2: TTableDef;
  newPk: string;
begin
  old := VDbNorm(OldName);
  nn := VDbNorm(NewName);
  t := GetTable(old);
  if nn = old then Exit;
  if TableExists(nn) then raise EVDbException.Create(ecTableExists, 'tablo var: ' + NewName);
  if Trim(NewName) = '' then raise EVDbException.Create(ecInvalidName, 'yeni ad bos olamaz');

    // KEY tablo adi ile hashlendigi icin tum anahtarlar degismeli
    FKv.ScanAll(keys, raw, t.TableId);   // R-26
  ownBatch := not FKv.InBatch;
  if ownBatch then FKv.BeginBatch;
  try
    for i := 0 to High(keys) do
    begin
      if keys[i] = VDB_SCHEMA_KEY then Continue;
      // F1-8: cozulemeyen satiri sessizce ATLAMAK eski adda orphan
      // birakir; bozuk veri olarak bildir.
      if not DecodeRow(raw[i], tid, pk, nv) then
        raise EVDbException.CreateFmt(ecCorrupt,
          'VDb: rename sirasinda bozuk satir (tablo=%s, key=%d)', [old, i]);
      if tid <> t.TableId then Continue;
      FKv.Delete(keys[i]);
      nb := EncodeRow(tid, pk, t, nv);
      // F1-8: yeni hash baska bir satira aitse Put sessizce onu ezer.
      if FKv.Get(VDbHashKey(nn, pk), ob) then
        if DecodeRow(ob, otid, opk, ovals) and
           ((otid <> t.TableId) or (opk <> pk)) then
          raise EVDbException.CreateFmt(ecHashCollision,
            'VDb: hash carpismasi (tablo=%s, pk=%s)', [nn, pk]);
      FKv.Put(VDbHashKey(nn, pk), nb);
    end;
    if ownBatch then FKv.CommitBatch;
  except
    if ownBatch then AbortBatch;
    raise;
  end;

  // sema: cocuk FK referanslarini guncelle
  CloneDef(t, nt);
  nt.Name := nn;
  for kv in FTables do
  begin
    if kv.Key = old then Continue;
    t2 := kv.Value;
    for j := 0 to High(t2.Fks) do
      if t2.Fks[j].RefTable = old then
      begin
        t2.Fks[j].RefTable := nn;
        FTables.AddOrSetValue(kv.Key, t2);
      end;
  end;
  IntentDrop(old);    // sema korumasi: eski ad kayboldu, kasitli
  FTables.Remove(old);
  FTables.AddOrSetValue(nn, nt);
  FById.Remove(t.TableId);
  FById.Add(t.TableId, nn);
  MarkSchema;
end;

procedure TVTableDb.FreeIdxPend;
// Bekleyen indeks tamponlarini serbest birakir.
var
  i: Integer;
  k: Int64;
  l: TList<TIdxOp>;
begin
  if FIdxDirty = nil then Exit;
  for i := 0 to FIdxDirty.Count - 1 do
  begin
    k := FIdxDirty[i];
    if FIdxOps.TryGetValue(k, l) then
    begin
      l.Free;
      FIdxOps.Remove(k);
    end;
  end;
  FIdxOps.Clear;
  FIdxCtype.Clear;
  FreeIdxUniqMaps;
  FIdxDirty.Clear;
end;

// Satir Pk'sini tek dize anahtarina cevirir (tampon ici; diskte tutulmaz).
function TVTableDb.IdxOpTag(const Pk: string): string;
begin
  Result := Pk;
end;

function TVTableDb.IdxTDefByKey(const k: Int64; out ColIdx: Integer): TTableDef;
// Indeks anahtarindan (tablo, ilk kolon) cozdurur
var
  nm: string;
  j: Integer;
begin
  ColIdx := -1;
  Result.TableId := 0;
  Result.Name := '';
  Result.Cols := nil;
  Result.Idx := nil;
  Result.Fks := nil;
  Result.Checks := nil;
  // F2-22: PK yok varsayilani
  Result.PkIndex := -1;
  Result.AutoInc := 0;
  if not FById.TryGetValue(Word(k shr 32), nm) then Exit;
  Result := GetTable(nm);
  ColIdx := Integer(LongWord(k and $FFFFFFFF));
  // F-17: PARTIAL indeksler sentetik no ile adreslenir (0x4000 + IdxPos).
  // ColIdx cikisi "ilk kolon" bekledigi icin indeks konumundan cozulur.
  if ColIdx >= 16384 then
  begin
    j := ColIdx - 16384;
    if (j >= 0) and (j <= High(Result.Idx)) then
      ColIdx := Result.Idx[j].Col
    else
      ColIdx := -1;
  end;
end;

function TVTableDb.IdxPosOfKey(const k: Int64): Integer;
// F-17: anahtardan indeks KONUMUNU cozdurur (partial sentetik adres de).
// -1 = bulunamadi.
var
  nm: string;
  t: TTableDef;
  raw, j: Integer;
begin
  Result := -1;
  if not FById.TryGetValue(Word(k shr 32), nm) then Exit;
  t := GetTable(nm);
  raw := Integer(LongWord(k and $FFFFFFFF));
  // F-17/F-18: sentetik adresler
  //   16384 + pos -> partial indeks
  //   32768 + pos -> ifade indeksi
  if raw >= 32768 then
  begin
    j := raw - 32768;
    if (j >= 0) and (j <= High(t.Idx)) then Result := j;
    Exit;
  end;
  if raw >= 16384 then
  begin
    j := raw - 16384;
    if (j >= 0) and (j <= High(t.Idx)) then Result := j;
    Exit;
  end;
  for j := 0 to High(t.Idx) do
    if t.Idx[j].Col = raw then
    begin
      Result := j;
      Exit;
    end;
end;

function TVTableDb.IdxNPartsByKey(const k: Int64): Integer;
var
  t: TTableDef;
  ci, j: Integer;
begin
  Result := 1;
  j := IdxPosOfKey(k);
  if j < 0 then Exit;
  t := IdxTDefByKey(k, ci);
  if t.Idx[j].ExprText <> '' then Exit(1);   // F-18: ifade indeksi tek parca
  if Length(t.Idx[j].Cols) > 0 then Result := Length(t.Idx[j].Cols);
end;

function TVTableDb.IdxCtypesByKey(const k: Int64): TByteArray;
var
  t: TTableDef;
  ci, j, i: Integer;
  cols: TIntArray;
begin
  j := IdxPosOfKey(k);
  if j < 0 then Exit;
  t := IdxTDefByKey(k, ci);
  if t.Idx[j].ExprText <> '' then
  begin
    // F-18: ifade indeksi TEK parcalidir
    SetLength(Result, 1);
    Result[0] := IdxCtypeOfPos(t, j);
    Exit;
  end;
  cols := IdxColsOf(t, j);
  SetLength(Result, Length(cols));
  for i := 0 to High(cols) do
    Result[i] := t.Cols[cols[i]].Ctype;
end;

procedure TVTableDb.FlushIdxPending(const k: Int64);
// Bekleyen islemleri TEK seferde uygular: filtrele, ekle, sirala.
//
// KURGU: tampon bir "fark listesi" DEGIL, satir basina GUNCEL DURUM
// listesidir:
//   op.IsDel = False -> satirin indeks anahtari artik op.Key
//   op.IsDel = True  -> satir indeksden tamamen kalkiyor
// Ayni Pk icin birden fazla op olabilir; SON op gecerlidir. Boylece
// (a) islem sirasi ve (b) eski degerin dogru bilinmesi onemsizdir ve her
// satir icin TAM OLARAK BIR girdi garanti edilir -> indeks veriden
// bagimsiz olarak kendini tutarli tutar (mukerrer/eksik girdi imkansiz).
var
  ops: TList<TIdxOp>;
  e, keep: TIdxEntries;
  lastOp: TDictionary<string, TIdxOp>;    // pk -> son durum
  added: TDictionary<string, Boolean>;     // eklenen pk'ler
  ct: Byte;
  i: Integer;
begin
  if not FIdxOps.TryGetValue(k, ops) then Exit;
  if ops.Count = 0 then
  begin
    ops.Free;
    FIdxOps.Remove(k);
    Exit;
  end;
  if not FIdxCtype.TryGetValue(k, ct) then ct := VCT_STR;
  if not FMemIdx.TryGetValue(k, e) then SetLength(e, 0);

  // 1) her satir icin son durumu belirle
  lastOp := TDictionary<string, TIdxOp>.Create;
  for i := 0 to ops.Count - 1 do
    lastOp.AddOrSetValue(ops[i].Pk, ops[i]);

  // 2) commitlenmis girdilerden bu toplantida dokunulan satirlari cikar
  SetLength(keep, 0);
  for i := 0 to High(e) do
  begin
    if lastOp.ContainsKey(e[i].Pk) then Continue;
    SetLength(keep, Length(keep) + 1);
    keep[High(keep)] := e[i];
  end;
  // 3) hala var olan satirlar icin TAM OLARAK birer girdi koy
  added := TDictionary<string, Boolean>.Create;
  for i := 0 to ops.Count - 1 do
    if not ops[i].IsDel then
    begin
      if added.ContainsKey(ops[i].Pk) then Continue;
      // bu satirin SON durumu silme mi? (daha sonraki bir op geci kalmis olabilir)
      if lastOp[ops[i].Pk].IsDel then Continue;
      added.AddOrSetValue(ops[i].Pk, True);
      SetLength(keep, Length(keep) + 1);
      keep[High(keep)].Key := ops[i].Key;
      keep[High(keep)].Pk := ops[i].Pk;
      keep[High(keep)].Cov := ops[i].Cov;   // F-19
    end;
  added.Free;
  lastOp.Free;

  // 4) sirala ve yayinla
  // COK KOLONLU indekslerde her parca kendi tipine gore karsilastirilir
  if IdxNPartsByKey(k) > 1 then
    SortIdxEntriesCols(keep, IdxCtypesByKey(k))
  else
    SortIdxEntries(keep, ct);
  FMemIdx.AddOrSetValue(k, keep);
  ops.Free;
  FIdxOps.Remove(k);
  FIdxDirty.Delete(FIdxDirty.IndexOf(k));
end;

function TVTableDb.TryGetMemIndex(TableId: Word; ColIdx: Integer; out Entries: TIdxEntries): Boolean;
// Indeksin OKUNABILIR tek noktasi. Burada bekleyen islemler uygulanir;
// hicbir sorgu yarim veya bozuk indeks gormez.
//
// Indeksler TENBEL yuklenir: ilk okumada veriden kurulur. ONCEDEN Open'da
// TUM indeksler EAGER kuruluyordu; 95.000 satirlik bir tabloda yalnizca
// dosya acilisi 4,5 saniye suruyordu. Artik yalnizca GERCEKTEN sorgulanan
// indeks kurulur (index kullanmayan tabloda ek yuk yok).
var
  k: Int64;
  nm: string;
  t: TTableDef;
  j: Integer;
  dirty: Boolean;
begin
  // R-22 Full: bu kolon uzerindeki NORMAL indekslerden biri INVALID ise
  // (concurrent insa suruyor / yarida kaldi) indeks OKUNMAZ ve bekleyen
  // islemler FLUSH EDILMEZ: ops finalize'a dek birikir (catch-up kaynagi).
  // Erken cikis planlayiciyi otomatik seq scan'a dusurur; sorgu sonucu
  // dogru kalir (indekssiz yol zaten her zaman dogrudur).
  if FById.TryGetValue(TableId, nm) then
  begin
    t := GetTable(nm);
    for j := 0 to High(t.Idx) do
      if (t.Idx[j].Col = ColIdx) and (t.Idx[j].Predicate = '') and
         (t.Idx[j].ExprText = '') and t.Idx[j].Invalid then
        Exit(False);
  end;
  k := IdxKey(TableId, ColIdx);
  if FIdxDirty.IndexOf(k) >= 0 then
    FlushIdxPending(k);
  if not FMemIdx.ContainsKey(k) then
  begin
    if FById.TryGetValue(TableId, nm) then
    begin
      t := GetTable(nm);
      for j := 0 to High(t.Idx) do
        if (t.Idx[j].Col = ColIdx) and not t.Idx[j].Invalid then   // R-22
        begin
          BuildOneIndex(t, j);
          Break;
        end;
    end;
  end;
  Result := FMemIdx.TryGetValue(k, Entries);
  // PK lazy index: T.Idx'te PK icin normal indeks YOKSA ve bu kolon
  // PK kolonuysa, ayri bir sirali diziden cevapla. Boylece BETWEEN/
  // ORDER BY range query'leri Seq Scan yerine Index Scan yapar.
  // T.Idx'e kayit YAPILMAZ (IndexNames/CheckConstraints etkilenmez).
  if (not Result) and FById.TryGetValue(TableId, nm) then
  begin
    t := GetTable(nm);
    if (t.PkIndex >= 0) and (ColIdx = t.PkIndex) then
    begin
      dirty := True;
      FPkIdxDirty.TryGetValue(TableId, dirty);
      if (not FPkIdx.TryGetValue(TableId, Entries)) or dirty then
      begin
        BuildPkIdx(t, Entries);
        FPkIdx.AddOrSetValue(TableId, Entries);
        FPkIdxDirty.AddOrSetValue(TableId, False);
      end;
      Result := True;
    end;
  end;
end;

function TVTableDb.IndexNames(const Table: string): TStrArray;
var
  t: TTableDef;
  i: Integer;
begin
  t := GetTable(Table);
  SetLength(Result, Length(t.Idx));
  for i := 0 to High(t.Idx) do
    Result[i] := t.Idx[i].Name;
end;

procedure TVTableDb.CreateIndex(const Table, IndexName, Col: string);
begin
  CreateIndexCols(Table, IndexName, [Col]);
end;

procedure TVTableDb.CreateIndexCols(const Table, IndexName: string;
  const Cols: TStrArray; Unique: Boolean; const Predicate: string = '';
  const ExprText: string = ''; const Incl: TStrArray = nil;
  Concurrent: Boolean = False);   // F-18, F-19, R-22 Full
var
  t: TTableDef;
  ci, j, i: Integer;
  kv: TPair<string, TTableDef>;
  nm: string;
  cis: TIntArray;
  inis: TIntArray;   // F-19
begin
  // R-22 Full: PostgreSQL ile ayni kural — CONCURRENTLY islem (batch)
  // icinde kullanilamaz. Insa, geri alinamayan yan etkiler birakir
  // (arka plan insasaci + INVALID sema kaydi); batch abort'u bu
  // durumlarin ayrilmasini imkansiz kilardi.
  if Concurrent and FKv.InBatch then
    raise EVDbException.Create(ecInvalidState,
      'CREATE INDEX CONCURRENTLY islem icinde kullanilamaz');
  t := GetTable(Table);
  nm := VDbNorm(IndexName);
  if nm = '' then raise EVDbException.Create(ecInvalidName, 'index adi bos olamaz');
  // F-19: INCLUDE kolonlari cozumlenir (yineleme ve anahtarla cakisma yasak)
  if Length(Incl) > 0 then
  begin
    SetLength(inis, Length(Incl));
    for i := 0 to High(Incl) do
    begin
      inis[i] := FindCol(t, Incl[i]);
      if inis[i] < 0 then
        raise EVDbException.Create(ecColumnNotFound, 'INCLUDE kolonu yok: ' + Incl[i]);
      for j := 0 to i - 1 do
        if inis[j] = inis[i] then
          raise EVDbException.Create(ecColumnExists,
            'INCLUDE kolonu iki kez: ' + Incl[i]);
      for j := 0 to High(Cols) do
        if VDbNorm(t.Cols[inis[i]].Name) = VDbNorm(Cols[j]) then
          raise EVDbException.Create(ecColumnExists,
            'INCLUDE kolonu anahtar kolonla ayni: ' + Incl[i]);
    end;
  end;
  // F-18: ifade indeksi — TColCol yok, ifade metni anahtari belirler
  if ExprText <> '' then
  begin
    for kv in FTables do
      for j := 0 to High(kv.Value.Idx) do
        if kv.Value.Idx[j].Name = nm then
          raise EVDbException.Create(ecIndexExists, 'index var: ' + IndexName);
    SetLength(t.Idx, Length(t.Idx) + 1);
    t.Idx[High(t.Idx)].Name := nm;
    t.Idx[High(t.Idx)].Col := -1;              // F-18: kolon adresi gecersiz
    t.Idx[High(t.Idx)].Cols := nil;
    t.Idx[High(t.Idx)].Uniq := Unique;
    t.Idx[High(t.Idx)].Predicate := Predicate;
    t.Idx[High(t.Idx)].ExprText := ExprText;
    t.Idx[High(t.Idx)].Incl := Copy(inis, 0, Length(inis));   // F-19
    t.Idx[High(t.Idx)].Invalid := Concurrent;  // R-22: insa INVALID baslar
    FTables.AddOrSetValue(t.Name, t);
    MarkSchema;
    // R-22 Full: CONCURRENTLY -> insa ARKA PLANDA baslar (anlik goruntu
    // alinir, is parcacigi siralar); cumle HEMEN doner. Finalize bir
    // sonraki cumlede (PollConcurrentIndexes) yapilir.
    if Concurrent then
      StartConcBuild(t, High(t.Idx))
    else
      BuildOneIndex(t, High(t.Idx));
    Exit;
  end;
  if Length(Cols) = 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok');
  // kolonlar cozumlenir ve TEKRARSIZ olmalidir
  SetLength(cis, Length(Cols));
  for i := 0 to High(Cols) do
  begin
    cis[i] := FindCol(t, Cols[i]);
    if cis[i] < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Cols[i]);
    for j := 0 to i - 1 do
      if cis[j] = cis[i] then
        raise EVDbException.Create(ecColumnExists, 'ayni kolon iki kez: ' + Cols[i]);
  end;
  for kv in FTables do
    for j := 0 to High(kv.Value.Idx) do
      if kv.Value.Idx[j].Name = nm then
        raise EVDbException.Create(ecIndexExists, 'index var: ' + IndexName);
  // Ayni ILK kolona ikinci indeks kurulamaz (indeks anahtari ilk kolona
  // gore uretilir; ayrica sorgu planlayici da ilk kolonu kullanir).
  // F-17: PARTIAL indeks istisnadir â€” ayni kolonda bir normal indeks varsa
  // birlikte yasayabilirler (farkli satir kumesi).
  for j := 0 to High(t.Idx) do
    if (t.Idx[j].Col = cis[0]) and not (Predicate <> '') then
    begin
      if Copy(t.Idx[j].Name, 1, 17) = 'sqlite_autoindex_' then
      begin
        t.Idx[j].Name := nm;
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
        Exit;
      end;
      raise EVDbException.Create(ecIndexExists, 'kolonda index var: ' + Cols[0]);
    end;
  SetLength(t.Idx, Length(t.Idx) + 1);
  t.Idx[High(t.Idx)].Name := nm;
  t.Idx[High(t.Idx)].Col := cis[0];
  t.Idx[High(t.Idx)].Uniq := Unique;   // F2-23
  t.Idx[High(t.Idx)].Predicate := Predicate;   // F-17 (bos = normal indeks)
  t.Idx[High(t.Idx)].ExprText := '';            // F-18 (bu yol kolon indeksidir)
  t.Idx[High(t.Idx)].Incl := Copy(inis, 0, Length(inis));   // F-19
  t.Idx[High(t.Idx)].Invalid := Concurrent;     // R-22: insa INVALID baslar
  if Length(cis) > 1 then
  begin
    SetLength(t.Idx[High(t.Idx)].Cols, Length(cis));
    for i := 0 to High(cis) do
      t.Idx[High(t.Idx)].Cols[i] := cis[i];
  end;
  // F2-23: TEK KOLONLU `CREATE UNIQUE INDEX` icin kolon bayragi da
  // isaretlenir; aksi halde CheckConstraints'in O(1) hizli yolu bu
  // indeksi hic dikkate almaz ve kisit zorlanmaz. (Cok kolonlu indeksler
  // icin yalniz TIdxDef.Uniq yeterlidir.)
  // DIKKAT: BuildOneIndex "deger -> sahip pk" haritasini kurarken bu bayraÄŸÄ±
  // okur; bu yuzden BuildOneIndex ONCESINCE isaretlenmelidir.
  if Unique and (Length(t.Idx[High(t.Idx)].Cols) = 0) then
    t.Cols[cis[0]].Unique := True;
  FTables.AddOrSetValue(t.Name, t);
  MarkSchema;
  // R-22 Full: CONCURRENTLY -> arka plan insasi (bkz. yukaridaki ifade
  // yolu). Cume HEMEN doner; finalize bir sonraki cumlede yapilir.
  if Concurrent then
    StartConcBuild(t, High(t.Idx))
  else
    // BuildOneIndex, ilk kolon UNIQUE ise "deger -> sahip pk" haritasini da kurar
    BuildOneIndex(t, High(t.Idx));
end;

procedure TVTableDb.DropIndex(const IndexName: string);
var
  kv: TPair<string, TTableDef>;
  t: TTableDef;
  j, m: Integer;
  nm: string;
begin
  nm := VDbNorm(IndexName);
  // R-22 Full: bu indeks icin surmekte olan CONCURRENTLY insasi varsa
  // durdurulur (sonuctan vazgecilir; indeks zaten siliniyor).
  StopConcBuilders(nm);
  for kv in FTables do
    for j := 0 to High(kv.Value.Idx) do
      if kv.Value.Idx[j].Name = nm then
      begin
        t := kv.Value;
        // indeks hem bellekten hem de tampondan KALDIRILIR
        DropIdxPend(IdxKeyPos(t, j));   // F-17: partial indeks anahtari
        FMemIdx.Remove(IdxKeyPos(t, j));
        FIdxCtype.Remove(IdxKeyPos(t, j));
        for m := j to High(t.Idx) - 1 do
          t.Idx[m] := t.Idx[m + 1];
        SetLength(t.Idx, Length(t.Idx) - 1);
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
        Exit;
      end;
  raise EVDbException.Create(ecIndexNotFound, 'index yok: ' + IndexName);
end;

procedure TVTableDb.CreateTable(const Name: string; const Cols: TColArray; PkIndex: Integer;
  const Checks: TWhereGroups; const Fks: array of TFkDef;
  const PartitionType: string = ''; const PartitionCol: string = '';
  const PartitionValues: TStringList = nil);
var
  t: TTableDef;
  i, j: Integer;
  rt: TTableDef;
  rc: Integer;
  n: Integer;        // R-13 Full: HASH bolum sayisi
begin
  // F2-14: Bos tablo adi KABUL EDIYORDU. `VDbNorm('')` bos string
  // dondugu icin tablo anahtari olarak '' kaydediliyordu; sonraki
  // `VDbHashKey('', pk)` da bozuk/ortak anahtar uretiyor ve tablo
  // listede gorunmez hale geliyordu.
  if Trim(Name) = '' then raise EVDbException.Create(ecInvalidName, 'tablo adi bos olamaz');
  if TableExists(Name) then raise EVDbException.Create(ecTableExists, 'tablo var: ' + Name);
  if Length(Cols) = 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok');
  // F2-22: PRIMARY KEY tanimlanmadiysa -1 kalir (PK yok). Once 0'a
  // zorlaniyordu; boylece PK'siz tabloda ilk kolon PK saniliyor ve
  // satir anahtari olarak kullaniliyordu (ortuk UNIQUE).
  if (PkIndex < 0) or (PkIndex >= Length(Cols)) then PkIndex := -1;
  if FNextId >= $FFFF then raise EVDbException.Create(ecLimit, 'tablo limit (65534)');
  t.TableId := FNextId; Inc(FNextId);
  t.Name := VDbNorm(Name);
  // DIKKAT (F-33/F-34): TTableDef bir RECORD ve yerel degisken; FPC
  // managed alanlari (string/dinamik dizi) sifirlamadan birakir. Bu
  // alanlar ATANMADIGI icin yeni olusturulan bir tablo "view"
  // sanilabiliyordu: `INSERT INTO fl ...` -> "view uzerine INSERT
  // yapilamaz (guncellenemez view): fl". Ayni sekil IsMaterializedView
  // ve SelectStmt/SelectText de kirli kaliyordu.
  // NOT: FillChar kullanilmiyor - record'da managed alan var, sifirlama
  // finalizasyonu bozabilir; tek tek atama guvenli.
  t.IsView := False;
  t.IsMaterializedView := False;
  t.SelectStmt := nil;
  t.SelectText := '';
  t.FRowEstimate := 1000;      // R-15: varsayılan tahmin
  t.FLastAnalyze := 0;         // R-15: henüz analiz edilmedi
  SetLength(t.Cols, Length(Cols));
  for i := 0 to High(Cols) do
  begin
    if Trim(Cols[i].Name) = '' then raise EVDbException.Create(ecInvalidName, 'kolon adi bos olamaz');
    t.Cols[i].Name := VDbNorm(Cols[i].Name);
    t.Cols[i].Ctype := Cols[i].Ctype;
    t.Cols[i].NotNull := Cols[i].NotNull;
    t.Cols[i].Unique := Cols[i].Unique;
    t.Cols[i].HasDef := Cols[i].HasDef;
    t.Cols[i].Def := Cols[i].Def;
    t.Cols[i].Collate := Cols[i].Collate;   // R-20
  end;
  t.PkIndex := PkIndex;
  t.AutoInc := 0;
SetLength(t.Idx, 0);
   for i := 0 to High(t.Cols) do
     if t.Cols[i].Unique and (i <> t.PkIndex) then
     begin
       SetLength(t.Idx, Length(t.Idx) + 1);
       t.Idx[High(t.Idx)].Name := 'sqlite_autoindex_' + t.Name + '_' + IntToStr(i + 1);
       t.Idx[High(t.Idx)].Col := i;
     end;
  // CHECK: kolon indexleri gecerli mi? Ctype kolon taniminden turetilir.
  for i := 0 to High(Checks) do
    for j := 0 to High(Checks[i]) do
      if (Checks[i][j].Col < 0) or (Checks[i][j].Col >= Length(t.Cols)) then
        raise EVDbException.Create(ecCheckViolation, 'CHECK kolonu gecersiz');
  t.Checks := Copy(Checks, 0, Length(Checks));
  for i := 0 to High(t.Checks) do
    for j := 0 to High(t.Checks[i]) do
      t.Checks[i][j].Ctype := t.Cols[t.Checks[i][j].Col].Ctype;
  // FOREIGN KEY: hedef tablo/kolon var mi?
  // F2-12: KENDINE referans ( dugum(id, parent REFERENCES dugum(id)) )
  // CreateTable aninda tablo henuz FTables'a YAZILMAMIS olurdu; hedef
  // tablo "yok" sanilip reddediliyordu -> self-referans FK hic kurulamazdi.
  // Artik kendi tablo da hedef sayilir.
  SetLength(t.Fks, Length(Fks));
  for i := 0 to High(Fks) do
  begin
    if (Fks[i].Col < 0) or (Fks[i].Col >= Length(t.Cols)) then
      raise EVDbException.Create(ecForeignKeyViolation, 'FK kolonu gecersiz');
    if VDbNorm(Fks[i].RefTable) <> t.Name then
      if not FTables.TryGetValue(VDbNorm(Fks[i].RefTable), rt) then
        raise EVDbException.Create(ecForeignKeyViolation, 'FK hedef tablo yok: ' + Fks[i].RefTable);
    if VDbNorm(Fks[i].RefTable) = t.Name then
      rt := t
    else
      FTables.TryGetValue(VDbNorm(Fks[i].RefTable), rt);
    rc := FindCol(rt, Fks[i].RefCol);
    if rc < 0 then
      raise EVDbException.Create(ecForeignKeyViolation, 'FK hedef kolon yok: ' + Fks[i].RefCol);
    // F2-12: ONCEDEN oz-yinelemeli (kendine referans veren) FK burada
    // reddediliyordu: "oz-yinelemeli FK yok (v1)". Bu, agac/yol gibi
    // kendini referans alan YAPILARI kurmayi tamamen engelliyordu.
    // Artik izin veriliyor; DELETE/DELETE zincirinde derinlik korumasi
    // (FCascadeDepth) donguleri yakalar.
    t.Fks[i].Col := Fks[i].Col;
    t.Fks[i].RefTable := VDbNorm(Fks[i].RefTable);
    t.Fks[i].RefCol := VDbNorm(Fks[i].RefCol);
    t.Fks[i].OnDelete := VDbFkAction(Fks[i].OnDelete);
    t.Fks[i].OnUpdate := VDbFkAction(Fks[i].OnUpdate);
    t.Fks[i].Deferrable := Fks[i].Deferrable;   // R-11
  end;
  // R-13 Full: bolme (partitioning) tanimini kaydet ve dogrula.
  // Onceden parser'in cikardigi degerler CreateTable'a geliyor ama
  // HICBIR YERDE saklanmiyordu (parametreler yok sayiliyordu).
  t.PartType := UpperCase(Trim(PartitionType));
  t.PartCol := '';
  SetLength(t.PartVals, 0);
  if t.PartType <> '' then
  begin
    t.PartCol := VDbNorm(PartitionCol);
    j := 0;
    while (j < Length(t.Cols)) and (T.Cols[j].Name <> t.PartCol) do Inc(j);
    if j >= Length(t.Cols) then
      raise EVDbException.Create(ecColumnNotFound,
        'bolme kolonu tabloda yok: ' + t.PartCol);
    if t.PartType = 'HASH' then
    begin
      // PartVals[0] = bolum sayisi (parser 'PARTITIONS n' okur)
      if (PartitionValues = nil) or (PartitionValues.Count < 1) then
        raise EVDbException.Create(ecSyntaxError,
          'HASH bolme icin PARTITIONS n gerekir');
      n := StrToIntDef(Trim(PartitionValues[0]), 0);
      if (n < 1) or (n > 1024) then
        raise EVDbException.Create(ecSyntaxError,
          'HASH bolum sayisi 1..1024 arasinda olmali');
      SetLength(t.PartVals, 1);
      t.PartVals[0] := IntToStr(n);
    end
    else if t.PartType = 'LIST' then
    begin
      if (PartitionValues = nil) or (PartitionValues.Count < 1) then
        raise EVDbException.Create(ecSyntaxError,
          'LIST bolme icin VALUES IN (...) gerekir');
      SetLength(t.PartVals, PartitionValues.Count);
      for i := 0 to PartitionValues.Count - 1 do
        t.PartVals[i] := PartitionValues[i];
    end
    else if t.PartType = 'RANGE' then
    begin
      if (PartitionValues = nil) or (PartitionValues.Count < 2) then
        raise EVDbException.Create(ecSyntaxError,
          'RANGE bolme icin VALUES BETWEEN a AND b gerekir');
      SetLength(t.PartVals, 2);
      t.PartVals[0] := PartitionValues[0];
      t.PartVals[1] := PartitionValues[1];
    end
    else
      raise EVDbException.Create(ecSyntaxError,
        'bilinmeyen bolme tipi: ' + t.PartType + ' (HASH/LIST/RANGE)');
  end;
  FTables.Add(t.Name, t);
  FById.Add(t.TableId, t.Name);
  MarkSchema;
end;

procedure TVTableDb.DropTable(const Name: string);
var
  t: TTableDef;
  kv2: TPair<string, TTableDef>;
  keys: TQWordArray;
  k: QWord;
  tid: Word;
  pk: string;
  vals: TStrArray;
  raw: TValArray;
  ck: TStrArray;
  cr: TStrMatrix;
  i: Integer;
  j: Integer;
  ownBatch: Boolean;
  parentVals: TStrArray;
  nRef, ci, nReferencing: Integer;
  cdef: string;
  chT: TTableDef;
  nFksRemoved: Integer;
  newFks: array of TFkDef;
  m: Integer;
  dropped: Boolean;
begin
  if not FTables.TryGetValue(VDbNorm(Name), t) then Exit;
  // F-36: tabloyla birlikte bagli TETIKLEYICILER de kaldirilir. Aksi
  // halde katalogda tetikleyicisiz tabloya sahip (orphan) kayit kalir ve
  // ayni adli tablo yeniden olusturuldugunda eski tetikleyici ona baglanir.
  DropTriggersOfTable(VDbNorm(Name));
  // F2-6: ONCEDEN "cocuk tablonun HIC BIR satiri varsa" engel konuyordu.
  // Bu cok katÄ±ydi: cocukta FK kolonu NULL olan satirlar varsa tablo
  // dusurulemiyordu, hatta hicbir FK tanimi olmayan cocuk tablo bile
  // engel oluyordu. Dogru kural: COCUK SATIRININ BU EBEVEYNI GERCEKTEN
  // GOSTERMESI. Gostermiyorsa veri engeli yoktur.
  // Ancak sarkan FK TANIMI birakilirsa sonraki cocuk INSERT'leri FK
  // denetiminde "tablo yok" ile kacar (F1-6 ile ayni sinif sorun).
  // Bu yuzden engel yoksa ilgili FK tanimlari cocuktan SILINIR.
  parentVals := nil;
  // Ebeveynin RefCol degerleri (cocuk satirlariyla kesisim icin)
  for kv2 in FTables do
  begin
    if kv2.Key = t.Name then Continue;
    for j := 0 to High(kv2.Value.Fks) do
      if kv2.Value.Fks[j].RefTable = t.Name then
      begin
        if parentVals = nil then
        begin
          SetLength(parentVals, 0);
          ScanRows(t.Name, ck, cr);
          for i := 0 to High(cr) do
          begin
            ci := FindCol(t, kv2.Value.Fks[j].RefCol);
            if (ci >= 0) and (ci < Length(cr[i])) and (cr[i][ci] <> '') then
            begin
              SetLength(parentVals, Length(parentVals) + 1);
              parentVals[High(parentVals)] := cr[i][ci];
            end;
          end;
        end;
        nReferencing := 0;
        ScanRows(kv2.Value.Name, ck, cr);
        for i := 0 to High(cr) do
        begin
          // TFkDef.Col bir KOLON INDEKSIdir (ad degil)
          ci := kv2.Value.Fks[j].Col;
          if (ci < 0) or (ci >= Length(cr[i])) then Continue;
          if cr[i][ci] = '' then Continue;      // NULL referans degildir
          for m := 0 to High(parentVals) do
            if SameText(cr[i][ci], parentVals[m]) then
            begin
              Inc(nReferencing);
              Break;
            end;
        end;
        if nReferencing > 0 then
          raise EVDbException.CreateFmt(ecForeignKeyViolation,
            'tablo dusurulemez: %s.%s icinde %d satir bu tabloyu gosteriyor ' +
            '(once cocuk satirlari silin veya FK kaldirin)',
            [kv2.Key, kv2.Value.Fks[j].Col, nReferencing]);
      end;
  end;
    FKv.ScanAll(keys, raw, t.TableId);   // R-26: yalnizca bu tablonun satirlari
    ownBatch := not FKv.InBatch;
  if ownBatch then FKv.BeginBatch;
  try
    for i := 0 to High(keys) do
    begin
      k := keys[i];
      if k = VDB_SCHEMA_KEY then Continue;
      if not DecodeRow(raw[i], tid, pk, vals) then Continue;
      if tid = t.TableId then FKv.Delete(k);
    end;
    if ownBatch then FKv.CommitBatch;
  except
    if ownBatch then FKv.AbortBatch;
    raise;
  end;
  IntentDrop(Name);   // sema korumasi: bu kaybolma kasitli
  FTables.Remove(VDbNorm(Name));
  FById.Remove(t.TableId);
  for j := 0 to High(t.Idx) do
    FMemIdx.Remove(IdxKey(t.TableId, t.Idx[j].Col));
  // F2-6: Artik var olmayan tabloya isaret eden FK TANIMLARINI cocuk
  // tablolardan kaldir. Aksi halde cocukta sonraki INSERT'ler FK
  // denetiminde "tablo yok" ile kacar ve tablo kalici kullanilamaz
  // hale gelir. Veri engeli zaten yukarida kontrol edildi.
  dropped := False;
  for kv2 in FTables do
  begin
    cdef := kv2.Key;
    if cdef = t.Name then Continue;
    chT := kv2.Value;
    nFksRemoved := 0;
    SetLength(newFks, 0);
    for j := 0 to High(chT.Fks) do
      if chT.Fks[j].RefTable = t.Name then
        Inc(nFksRemoved)
      else
      begin
        SetLength(newFks, Length(newFks) + 1);
        newFks[High(newFks)] := chT.Fks[j];
      end;
    if nFksRemoved > 0 then
    begin
      chT.Fks := newFks;
      FTables.AddOrSetValue(cdef, chT);
      dropped := True;
    end;
  end;
  MarkSchema;
end;

function TVTableDb.TableExists(const Name: string): Boolean;
begin
  Result := FTables.ContainsKey(VDbNorm(Name));
end;

function TVTableDb.GetTable(const Name: string): TTableDef;
begin
  if not FTables.TryGetValue(VDbNorm(Name), Result) then
    raise EVDbException.Create(ecTableNotFound, 'tablo yok: ' + Name);
end;

function TVTableDb.TableNames: TStrArray;
var
  k: string;
  i: Integer;
begin
  SetLength(Result, FTables.Count);
  i := 0;
  for k in FTables.Keys do begin Result[i] := k; Inc(i); end;
end;

function TVTableDb.DecodeRowDataPublic(const B: TBytes; out TableId: Word;
  out Pk: string; out Vals: TStrArray): Boolean;
// CDC icin sarmalayici: DecodeRow implementation icinde oldugu icin
// disari (VDbCdc) dogrudan gorunmez.
begin
  Result := DecodeRow(B, TableId, Pk, Vals);
end;

function TVTableDb.GetTableNameById(AId: Word): string;
// CDC icin id -> tablo adi. Bulunamazsa bos doner (kayit 'unknown' olur).
begin
  Result := '';
  FById.TryGetValue(AId, Result);
end;

procedure TVTableDb.BatchInsert(const Table: string; const ColNames: array of string;
  const Rows: array of TStrArray);
// COKMULU ekleme: "INSERT INTO t(a,b) VALUES (1,'x'),(2,'y'),(3,'z')".
// TUM satirlar TEK ATOMIK batch icinde yazilir: 3. grup CHECK/FK ihlali
// verirse hicbiri yazilmaz (kismi yazim = veri tutarsizligi).
// Icinde zaten batch acikse (BEGIN) o batch'e yazar, bitirmez.
var
  i: Integer;
  ownBatch: Boolean;
begin
  if Length(Rows) = 0 then Exit;
  ownBatch := not FKv.InBatch;
  // F1-9: own batch acarken TVTableDb.BeginBatch/CommitBatch kullan (sema
  // kirli bayragi flush'lansin; AutoInc kaybolmasin).
  if ownBatch then BeginBatch;
  try
    for i := 0 to High(Rows) do
      Insert(Table, ColNames, Rows[i]);
    if ownBatch then CommitBatch;
  except
    if ownBatch then AbortBatch;
    raise;
  end;
end;

procedure TVTableDb.Insert(const Table: string; const ColNames, StrVals: array of string);
var
  t: TTableDef;
  vals, exVals, dummyVals: TStrArray;
  provided: array of Boolean;
  i, ci: Integer;
  pk, exPk: string;
  iv: Int64;
  key: QWord;
  b: TBytes;
  exTid: Word;
begin
  t := GetTable(Table);
  // Sutun sayisi ile deger sayisi ESIT olmali. Esit degilse sessizce
  // yutmak veri kaybina yol acar: eksik deger NULL olur, fazla deger
  // atilir. Kullanim hatasi erken bildirilir.
  if Length(ColNames) <> Length(StrVals) then
    raise EVDbException.CreateFmt(ecInvalidArgument, '%s: sutun sayisi (%d) deger sayisiyla (%d) esit degil',
      [Table, Length(ColNames), Length(StrVals)]);
  SetLength(vals, Length(t.Cols));
  SetLength(provided, Length(t.Cols));
  for i := 0 to High(vals) do begin vals[i] := ''; provided[i] := False; end;
  for i := 0 to High(ColNames) do
  begin
    ci := FindCol(t, ColNames[i]);
    if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + ColNames[i]);
    if provided[ci] then
      raise EVDbException.Create(ecColumnExists, 'kolon iki kez verildi: ' + ColNames[i]);
    vals[ci] := StrVals[i];
    provided[ci] := True;
  end;
  // verilmemis kolonlara DEFAULT
  for i := 0 to High(vals) do
    if not provided[i] and t.Cols[i].HasDef then
      vals[i] := t.Cols[i].Def;
  // F2-22: PK TANIMLANMAMISSA sentetik satir anahtari uretilir.
  // ONCEDEN PkIndex 0'a zorlandigi icin ilk kolon hem anahtar hem de
  // ortuk UNIQUE idi: `CREATE TABLE t(a,b)` + ayni a ile ikinci satir
  // "duplicate PK" hatasi veriyordu. Artik ilk kolon serbesttir.
  // Sayac olarak AutoInc kullanilir: PK'li tabloda oldugu gibi semada
  // kalici olarak saklanir, yeniden acilista carpisma olusmaz.
  if t.PkIndex < 0 then
  begin
    Inc(t.AutoInc);
    pk := '@' + IntToStr(t.AutoInc);
    FTables.AddOrSetValue(t.Name, t);
    MarkSchema;
  end
  else
  begin
    pk := vals[t.PkIndex];
    if t.Cols[t.PkIndex].Ctype = VCT_INT then
    begin
      if pk = '' then
      begin
        // oto-sayac; eski DB'de sayac geride kalmissa veriyle uzlastir
        iv := t.AutoInc + 1;
        if ReadRow(t.Name, IntToStr(iv), dummyVals) then
          iv := MaxPkInt(t) + 1;
        t.AutoInc := iv;
        vals[t.PkIndex] := IntToStr(iv);
        pk := vals[t.PkIndex];
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
      end
      else if VDbParseInt(pk, iv) and (iv > t.AutoInc) then
      begin
        // acik PK verildiyse sayaci ilerlet ki sonraki oto deger cakismasin
        t.AutoInc := iv;
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
      end;
    end;
    if pk = '' then raise EVDbException.Create(ecInvalidName, 'PK bos olamaz');
  end;
  CheckConstraints(t, vals, '');
  // tarih-PK normallesmis olabilir (sentetik anahtarda dokunulmaz)
  if t.PkIndex >= 0 then pk := vals[t.PkIndex];
  if not VDbCheckOK(vals, t.Checks) then
    raise EVDbException.Create(ecCheckViolation, 'CHECK ihlali: ' + t.Name);
  CheckFk(t, vals);
  key := VDbHashKey(t.Name, pk);
  if FKv.Get(key, b) then
  begin
    if DecodeRow(b, exTid, exPk, exVals) and (exTid = t.TableId) and (exPk = pk) then
      raise EVDbException.Create(ecDuplicatePrimaryKey, 'duplicate PK: ' + pk)
    else
      raise EVDbException.CreateFmt(ecHashCollision, 'VDb: hash carpismasi (%s, %s)', [t.Name, pk]);
  end;
  b := EncodeRow(t.TableId, pk, t, vals);
  FKv.Put(key, b);
  IdxAddRow(t, vals, pk, -1);
end;

function TVTableDb.Delete(const Table: string; const Pk: string): Boolean;
var
  t: TTableDef;
  vals: TStrArray;
  j: Integer;
begin
  t := GetTable(Table);
  if not ReadRow(t.Name, Pk, vals) then Exit(False);
  CheckRestrict(t, vals, 'DELETE', '');
  IdxDelRow(t, vals, Pk, -1);
  Result := FKv.Delete(VDbHashKey(t.Name, Pk));
end;

function TVTableDb.CandidatePks(const T: TTableDef; const Groups: TWhereGroups;
  out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
// DELETE/UPDATE icin "hangi satirlara dokunulacak" sorusunu TAM TARAMA
// yapmadan cevaplar.
//
// ONCEDEN her DELETE/UPDATE ScanRows ile tum tabloyu bellege cekiyordu.
// 100.000 satirlik tabloda `WHERE id = 5` bile 641 ms tutuyordu; 5000
// nokta UPDATE = ~53 DAKIKA suruyordu. Simdi:
//   1) WHERE tek grup + tek kosul + PK kolonu + '='  -> TEK satir (O(1))
//   2) WHERE tek grup + indeksli kolon + dilimlenebilir
//      kosul (=,>,>=,<,<=,BETWEEN,IN)             -> yalniz o dilim
// Diger her durumda False doner ve cagirici tam tarama yapar.
//
// ONEMLI: donen satirlar UST KUMEDIR; WHERE'in geri kalani her zaman
// VDbMatchGroups ile yeniden elenir -> sonuc degismez.
var
  i, lo, hi, n, m: Integer;
  l2, h2: Integer;
  e: TIdxEntries;
  rv: TStrArray;
  w: string;
  ct: Byte;
begin
  SetLength(Pks, 0);
  SetLength(Rows, 0);
  Result := False;
  if Length(Groups) <> 1 then Exit;

  // --- 1) PK nokta arama (en sik durum) ---
  if Length(Groups[0]) = 1 then
    if (T.PkIndex >= 0) and (Groups[0][0].Col = T.PkIndex) and
       (Groups[0][0].Op = '=') then
    begin
      if not ReadRow(T.Name, Groups[0][0].Val, rv) then Exit; // eslesme yok
      if not VDbMatchGroups(rv, Groups) then Exit;
      SetLength(Pks, 1);
      SetLength(Rows, 1);
      Pks[0] := Groups[0][0].Val;
      Rows[0] := rv;
      Exit(True);
    end;

  // --- 2) indeks dilimi ---
  for i := 0 to High(Groups[0]) do
  begin
    if (Groups[0][i].Col < 0) or (Groups[0][i].Col >= Length(T.Cols)) then Continue;
    if not TryGetMemIndex(T.TableId, Groups[0][i].Col, e) then Continue;
    ct := T.Cols[Groups[0][i].Col].Ctype;
    w := Groups[0][i].Op;
    lo := 0;
    hi := Length(e);
    if (w = '=') or (w = '>') or (w = '>=') or (w = '<') or (w = '<=') then
    begin
      if not VDbIdxRange(e, ct, w, Groups[0][i].Val, lo, hi) then Continue;
    end
    else if w = 'BETWEEN' then
    begin
      if not VDbIdxRange(e, ct, '>=', Groups[0][i].Val, lo, hi) then Continue;
      if Length(Groups[0][i].Vals) > 0 then
        VDbIdxRange(e, ct, '<=', Groups[0][i].Vals[0], lo, hi);
    end
    else if w = 'IN' then
    begin
      // TUM degerleri kapsayan TEK aralik (UST KUME; sonra elenir).
      // alt sinir = en kucuk degerin '>=' baslangici (min)
      // ust sinir = en buyuk degerin '<=' bitisi     (max)
      lo := MaxInt;
      hi := 0;
      for m := 0 to High(Groups[0][i].Vals) do
      begin
        if VDbIdxRange(e, ct, '>=', Groups[0][i].Vals[m], l2, h2) then
          if l2 < lo then lo := l2;
        if VDbIdxRange(e, ct, '<=', Groups[0][i].Vals[m], l2, h2) then
          if h2 > hi then hi := h2;
      end;
      if (lo = MaxInt) or (hi = 0) then Continue;
    end
    else
      Continue;
    if lo > hi then lo := hi;
    // dilimdeki PKlari topla; satirlari SADECE onlar icin oku
    SetLength(Pks, 0);
    SetLength(Rows, 0);
    for n := lo to hi - 1 do
    begin
      if not ReadRow(T.Name, e[n].Pk, rv) then Continue;
      if not VDbMatchGroups(rv, Groups) then Continue;
      SetLength(Pks, Length(Pks) + 1);
      SetLength(Rows, Length(Rows) + 1);
      Pks[High(Pks)] := e[n].Pk;
      Rows[High(Rows)] := rv;
    end;
    Exit(True);
  end;
  Result := False;
end;

function TVTableDb.DeleteWhere(const Table: string; const Groups: TWhereGroups): Integer;
var
  t: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  i, j: Integer;
  ownBatch: Boolean;
begin
  Result := 0;
  t := GetTable(Table);
  // SQL katmanindan BEGIN ile gelen bir transaction varsa ic ice batch ACMA.
  // Kendi batch'imizi biz baslatti ise commit de biz yapariz.
  ownBatch := not FKv.InBatch;
  // ONCEDEN: ScanRows -> HER ZAMAN tam tarama (WHERE id=5 bile 641 ms).
  // Simdi: WHERE daraltabiliyorsa yalniz o satirlar okunur.
  if not CandidatePks(t, Groups, pks, rows) then
    ScanRows(t.Name, pks, rows);
  if ownBatch then FKv.BeginBatch;
  try
    for i := 0 to High(pks) do
    begin
      if not VDbMatchGroups(rows[i], Groups) then Continue;
      CheckRestrict(t, rows[i], 'DELETE', '');
      IdxDelRow(t, rows[i], pks[i], -1);
      FKv.Delete(VDbHashKey(t.Name, pks[i]));
      Inc(Result);
    end;
    if ownBatch then FKv.CommitBatch;
  except
    if ownBatch then AbortBatch;
    raise;
  end;
end;

function TVTableDb.ReadRow(const Table: string; const Pk: string; out Vals: TStrArray): Boolean;
var
  t: TTableDef;
  b: TBytes;
  tid: Word;
  apk: string;
begin
  Result := False;
  t := GetTable(Table);
  if not FKv.Get(VDbHashKey(t.Name, Pk), b) then Exit;
  if not DecodeRow(b, tid, apk, Vals) then Exit;
  if (tid = t.TableId) and (apk = Pk) then
  begin
    Result := True;
    Exit;
  end;
  // Anahtara bir kayit var ama icindeki (tablo, pk) beklenen degil.
  // ONCEDEN burada sadece False donuluyordu; sonuc SATIR GORUNMEZ OLURDU
  // (sessiz veri kaybi). Artik net hata verilir.
  raise EVDbException.CreateFmt(ecHashCollision, 
    'HASH CARPISMASI: tablo %s, istenen pk=%s ama kayit %s satiri iceriyor. ' +
    'Veritabani bozulmus; yedekten geri yukleyin.', [t.Name, Pk, apk]);
end;

function TVTableDb.ScanRows(const Table: string; out Pks: TStrArray; out Rows: TStrMatrix): Integer;
begin
  // R-13 Full: filtresiz tarama = bos hedef kumeli tarama.
  Result := ScanRowsPart(Table, Pks, Rows, Default(TPartTargets));
end;

function VDbPartHash(const S: string): QWord;
{ R-13 Full: HASH bolme icin deterministik 64-bit FNV-1a. Ayni deger
  (ayni string bicimiyle) her zaman ayni bolume duser. }
var
  i: Integer;
begin
  Result := QWord($CBF29CE484222325);
  for i := 1 to Length(S) do
  begin
    Result := Result xor QWord(Ord(S[i]));
    Result := Result * QWord($100000001B3);
  end;
end;

function TVTableDb.PartValueOf(const T: TTableDef; const Val: string): Integer;
{ R-13 Full: bolme anahtari degerinin bolumu.
  HASH : FNV-1a mod N. LIST: listedeki indeks; listede yoksa DEFAULT
  (son) bolumu. RANGE: min alti=0, aralik ici=1, max ustu=2.
  Sayisal RANGE degerleri Int64 ile; cevrilemezse METIN karsilastirmasi
  (hedef hesabi ayni yolu izledigi icin tutarlidir). -1 = hesaplanamadi.

  GUVENLIK (INT kanoniklestirme): depolama INT degeri dogrular ama
  yeniden yazmaz ('05' boylece '05' olarak yazar). Sayisal WHERE
  esitligi '05' = 5 dogruyken bolum hash'i farkli olurdu -> satir
  YANLIS elenirdi. Bu yuzden INT bolme kolonunda deger once IntToStr
  ile kanoniklestirilir: satir da hedef literal de ayni bicime iner. }
var
  i: Integer;
  ia, ib, iv: Int64;
  n: Integer;
  v: string;
begin
  Result := -1;
  if T.PartType = '' then Exit;
  v := Val;
  for i := 0 to High(T.Cols) do
    if T.Cols[i].Name = T.PartCol then
    begin
      if (T.Cols[i].Ctype = VCT_INT) and VDbParseInt(v, iv) then
        v := IntToStr(iv);
      Break;
    end;
  if T.PartType = 'HASH' then
  begin
    if Length(T.PartVals) = 0 then Exit;
    n := StrToIntDef(T.PartVals[0], 0);
    if n < 1 then Exit;
    Result := Integer(VDbPartHash(v) mod QWord(n));
  end
  else if T.PartType = 'LIST' then
  begin
    for i := 0 to High(T.PartVals) do
      if T.PartVals[i] = v then Exit(i);
    Result := Length(T.PartVals);   // DEFAULT bolumu
  end
  else if T.PartType = 'RANGE' then
  begin
    if Length(T.PartVals) < 2 then Exit;
    if VDbParseInt(T.PartVals[0], ia) and VDbParseInt(T.PartVals[1], ib) and
       VDbParseInt(v, iv) then
    begin
      if iv < ia then Result := 0
      else if iv > ib then Result := 2
      else Result := 1;
    end
    else
    begin
      if v < T.PartVals[0] then Result := 0
      else if v > T.PartVals[1] then Result := 2
      else Result := 1;
    end;
  end;
end;

function TVTableDb.PartRowOf(const T: TTableDef; const Row: TStrArray): Integer;
var
  i: Integer;
begin
  Result := -1;
  if T.PartType = '' then Exit;
  for i := 0 to High(T.Cols) do
    if T.Cols[i].Name = T.PartCol then
    begin
      if i <= High(Row) then Result := PartValueOf(T, Row[i]);
      Exit;
    end;
end;

function TVTableDb.PartCountOf(const T: TTableDef): Integer;
begin
  Result := 0;
  if T.PartType = '' then Exit;
  if T.PartType = 'HASH' then
  begin
    if Length(T.PartVals) > 0 then Result := StrToIntDef(T.PartVals[0], 0);
  end
  else if T.PartType = 'LIST' then
    Result := Length(T.PartVals) + 1   // + DEFAULT bolumu
  else if T.PartType = 'RANGE' then
    Result := 3;
end;

function TVTableDb.PartLabelOf(const T: TTableDef; PartNo: Integer): string;
begin
  Result := '';
  if T.PartType = 'HASH' then
    Result := 'p' + IntToStr(PartNo)
  else if T.PartType = 'LIST' then
  begin
    if PartNo < Length(T.PartVals) then
      Result := 'values: ' + T.PartVals[PartNo]
    else
      Result := 'DEFAULT';
  end
  else if T.PartType = 'RANGE' then
  begin
    if Length(T.PartVals) < 2 then Exit;
    case PartNo of
      0: Result := 'below ' + T.PartVals[0];
      1: Result := 'range ' + T.PartVals[0] + '..' + T.PartVals[1];
    else
      Result := 'above ' + T.PartVals[1];
    end;
  end;
end;

function TVTableDb.ScanRowsPart(const Table: string; out Pks: TStrArray;
  out Rows: TStrMatrix; const Targets: TPartTargets): Integer;
var
  t: TTableDef;
  keys: TQWordArray;
  k: QWord;
  tid: Word;
  pk: string;
  vals: TStrArray;
  raw: TValArray;
  i, n: Integer;
  pci: Integer;       // R-13 Full: bolme kolonu indeksi (-1 = filtre yok)
  pno, pj: Integer;
  hit: Boolean;
begin
  t := GetTable(Table);
  // R-13 Full: bolme kolonunu BIR KEZ coz. Filtre istenmis ama kolon
  // cozulemiyorsa filtre YOK sayilir (guvenli taraf: yanlis eleme olmaz).
  pci := -1;
  if Targets.HasFilter and (t.PartType <> '') then
    for i := 0 to High(t.Cols) do
      if t.Cols[i].Name = t.PartCol then begin pci := i; Break; end;
    FKv.ScanAll(keys, raw, t.TableId);   // R-26: diger tablolar okunmaz
    SetLength(Pks, 0); SetLength(Rows, 0); n := 0;
  for i := 0 to High(keys) do
  begin
    k := keys[i];
    if k = VDB_SCHEMA_KEY then Continue;
    // F2-16: COZULEMEYEN SATIR sessizce ATLANIYORDU. Bu tabloya ait
    // olabilecek tek bir bozuk kayit, SELECT/UPDATE/DELETE sonuclarini
    // sessizce eksik donduruyordu ("satir kayip" ama hata yok).
    // Artik net hata: veri bozulmus, yedekten geri yuklenmeli.
    if not DecodeRow(raw[i], tid, pk, vals) then
      raise EVDbException.CreateFmt(ecCorrupt,
        'VDb: kayit cozulemedi (tablo=%s, anahtar=%d). Veritabani bozulmus; ' +
        'yedekten geri yukleyin.', [t.Name, k]);
    if tid <> t.TableId then Continue;
    // CARPISMA DENETIMI: anahtar, kaydin icindeki (tablo, pk) ciftinden
    // hesaplanmis olmali. Degilse iki farkli satir ayni 64-bit anahtari
    // paylasmis demektir; bu durumda SATIR SESSIZCE BIR DIGERININ
    // YERINE GEZER (veri kaybi, hicbir hata verilmez). Artik net hata verir.
    if VDbHashKey(t.Name, pk) <> k then
      raise EVDbException.CreateFmt(ecHashCollision, 
        'HASH CARPISMASI: tablo %s, pk=%s -> iki satir ayni anahtari paylasiyor. ' +
        'Veritabani bozulmus; yedekten geri yukleyin.', [t.Name, pk]);
    // R-13 Full: PARTITION PRUNING — hedef bolum kumesi DISINDEKI satir
    // hic materialize edilmez (WHERE degerlendirmesine hic ulasmaz).
    // pno = -1 (hesaplanamadi) ise satir ELENMEZ: guvenli taraf.
    if pci >= 0 then
    begin
      pno := -1;
      if pci <= High(vals) then pno := PartValueOf(t, vals[pci]);
      if pno >= 0 then
      begin
        hit := False;
        for pj := 0 to High(Targets.Parts) do
          if Targets.Parts[pj] = pno then begin hit := True; Break; end;
        if not hit then Continue;
      end;
    end;
    SetLength(Pks, n + 1); SetLength(Rows, n + 1);
    Pks[n] := pk; Rows[n] := vals; Inc(n);
  end;
  Result := n;
end;

function TVTableDb.EvalSetExpr(const T: TTableDef; const E: TSetExpr;
  const Old: TStrArray; const ColName: string): string;
// UPDATE ... SET degerini HESAPLAR.
//
//   Sag (E.ColA) kolonu NULL ise sonuc da NULL'dir (bos string).
//   Metin kolonlarda aritmetik reddedilir (sessizce sayiya cevrilmez) --
//   bu, veri bozulmasini onler.
var
  ct: Byte;
  ia, ib, ir: Int64;
  fa, fb, fr: Double;
  rightS: string;
  isInt: Boolean;
begin
  if E.Kind = 0 then Exit(E.Lit);
  isInt := (T.Cols[E.ColA].Ctype = VCT_INT) or (T.Cols[E.ColA].Ctype = VCT_BOOL);
  ct := T.Cols[E.ColA].Ctype;
  if Old[E.ColA] = '' then Exit('');      // NULL + x = NULL
  if not isInt then
    if ct <> VCT_FLOAT then
      raise EVDbException.Create(ecTypeMismatch, 'SET ifadesi sayisal olmayan kolonda: ' + ColName);
  // sag taraf
  if E.ColB >= 0 then
  begin
    rightS := Old[E.ColB];
    if rightS = '' then Exit('');
  end
  else
    rightS := E.Lit;

  if isInt then
  begin
    if not VDbParseInt(Old[E.ColA], ia) then
      raise EVDbException.Create(ecTypeMismatch, 'SET: INTEGER degil: ' + Old[E.ColA]);
    if not VDbParseInt(rightS, ib) then
      raise EVDbException.Create(ecTypeMismatch, 'SET: INTEGER degil: ' + rightS);
    case E.Op of
      '+': ir := ia + ib;
      '-': ir := ia - ib;
      '*': ir := ia * ib;
      '/': begin
              if ib = 0 then raise EVDbException.Create(ecMathError, 'SET: sifira bolme');
              ir := ia div ib;
            end;
      '%': begin
              if ib = 0 then raise EVDbException.Create(ecMathError, 'SET: mod sifir');
              ir := ia mod ib;
            end;
      else raise EVDbException.Create(ecUnsupported, 'SET: bilinmeyen islem: ' + E.Op);
    end;
    Result := IntToStr(ir);
  end
  else
  begin
    if not VDbParseFloat(Old[E.ColA], fa) then
      raise EVDbException.Create(ecTypeMismatch, 'SET: sayi degil: ' + Old[E.ColA]);
    if not VDbParseFloat(rightS, fb) then
      raise EVDbException.Create(ecTypeMismatch, 'SET: sayi degil: ' + rightS);
    case E.Op of
      '+': fr := fa + fb;
      '-': fr := fa - fb;
      '*': fr := fa * fb;
      '/': begin
              if fb = 0 then raise EVDbException.Create(ecMathError, 'SET: sifira bolme');
              fr := fa / fb;
            end;
      '%': raise EVDbException.Create(ecMathError, 'SET: FLOAT kolonda % kullanilamaz');
      else raise EVDbException.Create(ecUnsupported, 'SET: bilinmeyen islem: ' + E.Op);
    end;
    Result := VDbFloatToStr(fr);
  end;
end;

function TVTableDb.UpdateRowInPlace(const Table: string; const Pk: string;
  const SrcVals: TStrArray): Boolean;
var
  t: TTableDef;
  i, j, k2, k3: Integer;
  setIdx, idxCols: TIntArray;
  needUpd, isRefCol: Boolean;
  oldVals, newVals: TStrArray;
  b, oldB: TBytes;
  key: QWord;
  exTid: Word;
  exPk: string;
  exVals: TStrArray;
  kv: TPair<string, TTableDef>;
  n: Integer;
begin
  t := GetTable(Table);
  if not ReadRow(t.Name, Pk, oldVals) then Exit(False);
  if Length(SrcVals) <> Length(t.Cols) then
    raise EVDbException.Create(ecColumnNotFound,
      'UPDATE: sutun sayisi uymuyor (' + t.Name + ')');

  // Yalnizca GERCEKTEN degisen kolonlar. (Once SET edilen tum kolonlar
  // listeleniyordu; degismeyenleri indeks bakiminda gezmek gereksizdi.)
  SetLength(setIdx, 0);
  for i := 0 to High(t.Cols) do
    if oldVals[i] <> SrcVals[i] then
    begin
      SetLength(setIdx, Length(setIdx) + 1);
      setIdx[High(setIdx)] := i;
    end;
  if Length(setIdx) = 0 then Exit(True);   // hicbir sey degismemis

  // CheckConstraints Vals'i YERINDE normalize eder (var parametre), bu
  // yuzden const NewVals'i dogrudan veremeyiz; calisma kopyasi kullanilir.
  newVals := Copy(SrcVals, 0, Length(SrcVals));
  CheckConstraints(t, newVals, Pk);
  if not VDbCheckOK(newVals, t.Checks) then
    raise EVDbException.Create(ecCheckViolation, 'CHECK ihlali: ' + t.Name);
  // FK kontrolu: YENI deger gecerli olmali (INSERT ile ayni kural)
  CheckFk(t, newVals);

  // Referans degeri degistiriliyorsa cocuklarin hala bu satiri
  // gostermesi lazim. Tetikleyici, kolonun UNIQUE/PK olmasi degil
  // BIR COCUK FK'NIN RefCol'u OLMASI dir: UNIQUE olmayan bir kolonu
  // da referans alabiliriz. UNIQUE sarti eklenirse ON UPDATE CASCADE
  // hic tetiklenmez.
  // F1-4: yalniz DEGISEN kolon bir cocuk FK'nin RefCol'u ise cagir;
  // RefColFilter ile o kolona ait FK'lar isaretlenir, digerleri atlanir.
  for j := 0 to High(setIdx) do
  begin
    isRefCol := False;
    for kv in FTables do
    begin
      if kv.Key = t.Name then Continue;
      for n := 0 to High(kv.Value.Fks) do
        if SameText(kv.Value.Fks[n].RefTable, t.Name) and
           (FindCol(t, kv.Value.Fks[n].RefCol) = setIdx[j]) then
        begin
          isRefCol := True;
          Break;
        end;
      if isRefCol then Break;
    end;
    if isRefCol then
      CheckRestrict(t, oldVals, 'UPDATE', newVals[setIdx[j]], setIdx[j]);
  end;

  b := EncodeRow(t.TableId, Pk, t, newVals);
  key := VDbHashKey(t.Name, Pk);
  if FKv.Get(key, oldB) then
    if DecodeRow(oldB, exTid, exPk, exVals) and
       ((exTid <> t.TableId) or (exPk <> Pk)) then
      raise EVDbException.CreateFmt(ecHashCollision,
        'VDb: hash carpismasi (%s, %s)', [t.Name, Pk]);
  FKv.Put(key, b);

  // Indeks bakimi: yalniz degisen kolonlardan birini iceren indeksler.
  // Once IdxDel(eski)+IdxAdd(yeni) idi; batch icinde eski deger bayat
  // okununca indeks mUKERRER girdi birakiyordu.
  for j := 0 to High(t.Idx) do
  begin
    idxCols := IdxColsOf(t, j);
    needUpd := False;
    for k2 := 0 to High(setIdx) do
      for k3 := 0 to High(idxCols) do
        if setIdx[k2] = idxCols[k3] then
        begin
          needUpd := True;
          Break;
        end;
    // F-19: INCLUDE kolonlari indeks girdisinin ICINDE tasindigi icin
    // degismeleri de indeks girdisini yenilemeyi gerektirir — anahtar
    // kolonlarla kesismese bile.
    if not needUpd then
      for k3 := 0 to High(t.Idx[j].Incl) do
        for k2 := 0 to High(setIdx) do
          if setIdx[k2] = t.Idx[j].Incl[k3] then
          begin
            needUpd := True;
            Break;
          end;
    // F-17: PARTIAL indeksin KOSULU, indeks kolonlarindan bagimsiz
    // olarak degisen bir kolona bagli olabilir
    // ("CREATE INDEX ix ON t(v) WHERE aktif = 1"; UPDATE ... SET aktif = 0).
    // Boyle bir durumda indeks satiri girer/cikar, ama setIdx indeks
    // kolonlariyla kesismez — yalniz "degisen kolon" bakisi onu kaçirir.
    // Bu yuzden partial indeksler her UPDATE'te yeniden degerlendirilir.
    if t.Idx[j].Predicate <> '' then needUpd := True;
    if needUpd then
    begin
      // F1-5: UNIQUE haritada bayat girdi kalmasin.
      IdxDelRow(t, oldVals, Pk, j);
      IdxAddRow(t, newVals, Pk, j);
    end;
  end;
  Result := True;
end;

function TVTableDb.UpdateWhere(const Table: string; const SetCols: array of string; const SetExprs: TSetExprs;
  const Groups: TWhereGroups): Integer;
var
  t: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  i, j: Integer;
  setIdx: TIntArray;
  oldVals, newVals: TStrArray;
  ownBatch: Boolean;
begin
  Result := 0;
  t := GetTable(Table);
  // SQL katmanindan BEGIN ile gelen bir transaction varsa ic ice batch ACMA.
  // Kendi batch'imizi biz baslatti ise commit de biz yapariz.
  ownBatch := not FKv.InBatch;
  // ONCEDEN: ScanRows -> HER ZAMAN tam tarama. `WHERE id = 5` yazsan bile
  // tum tablo bellege cekiliyordu (100.000 satirda 641 ms; 5000 UPDATE
  // = ~53 DAKIKA). Simdi: WHERE daraltabiliyorsa yalniz o satirlar okunur
  // (PK nokta arama O(1), indeks dilimi O(dilim)).
  if not CandidatePks(t, Groups, pks, rows) then
    ScanRows(t.Name, pks, rows);
  if ownBatch then FKv.BeginBatch;
  try
    for i := 0 to High(pks) do
    begin
      if not VDbMatchGroups(rows[i], Groups) then Continue;
      SetLength(setIdx, Length(SetCols));
      for j := 0 to High(SetCols) do
      begin
        setIdx[j] := FindCol(t, SetCols[j]);
        if setIdx[j] < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + SetCols[j]);
        if (t.PkIndex >= 0) and (setIdx[j] = t.PkIndex) then
        raise EVDbException.Create(ecUnsupported, 'PK guncellenemez');
      end;
      oldVals := Copy(rows[i], 0, Length(rows[i]));
      newVals := Copy(rows[i], 0, Length(rows[i]));
      for j := 0 to High(SetCols) do
        // SET degeri satira gore HESAPLANIR (orn. n = n + 1)
        newVals[setIdx[j]] := EvalSetExpr(t, SetExprs[j], oldVals, SetCols[j]);
      // Satir mantigi TEK yerde: UpdateRowInPlace (kisitler + FK +
      // ON UPDATE CASCADE/RESTRICT + indeks/UNIQUE bakimi).
      if UpdateRowInPlace(t.Name, pks[i], newVals) then Inc(Result);
    end;
    if ownBatch then FKv.CommitBatch;
  except
    if ownBatch then AbortBatch;
    raise;
  end;
end;

function TVTableDb.DataKeyCount: Integer;
var
  dummy: TBytes;
begin
  Result := FKv.Count;
  if FKv.Get(VDB_SCHEMA_KEY, dummy) then Dec(Result);
end;





{ F-33: VIEW DML }
procedure TVTableDb.CreateView(const ViewName: string; const SelectStmt: Pointer;
  const SelectText: string; const IfNotExists: Boolean);
var
  v: TTableDef;
begin
  if FTables.ContainsKey(VDbNorm(ViewName)) then
  begin
    if IfNotExists then Exit
    else raise EVDbException.Create(ecTableExists, 'view zaten var: ' + ViewName);
  end;
  v.Name := VDbNorm(ViewName);
  v.TableId := 0;
  v.Cols := [];
  v.PkIndex := -1;
  v.AutoInc := 0;
  v.Idx := [];
  v.Fks := [];
  v.Checks := [];
  v.IsView := True;
  v.SelectStmt := SelectStmt;
  v.SelectText := SelectText;
  FTables.Add(VDbNorm(ViewName), v);
  MarkSchema;
end;

procedure TVTableDb.DropView(const ViewName: string; const IfExists: Boolean);
var
  v: TTableDef;
begin
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then
  begin
    if IfExists then Exit
    else raise EVDbException.Create(ecTableNotFound, 'view yok: ' + ViewName);
  end;
  if not v.IsView then
    raise EVDbException.Create(ecTableNotFound, 'view yok: ' + ViewName);
  // DIKKAT (F-33): IntentDrop OLMAZSA GuardSchemaLoss bu view'u "diskte var
  // ama listede yok" sayar ve TUM sema yazimini reddeder
  // ("diskteki 8 tablodan 2 tanesi listeden kayboldu"). DROP TABLE ve
  // DROP MATERIALIZED VIEW icin de ayni koruma yolu kullaniliyor.
  IntentDrop(VDbNorm(ViewName));
  FTables.Remove(VDbNorm(ViewName));
  MarkSchema;
end;

function TVTableDb.ViewExists(const Name: string): Boolean;
begin
  Result := FTables.ContainsKey(VDbNorm(Name)) and FTables[VDbNorm(Name)].IsView;
end;

{ F-34: MATERIALIZED VIEW }
procedure TVTableDb.CreateMaterializedView(const ViewName: string; const SelectStmt: Pointer;
  const SelectText: string; const IfNotExists: Boolean);
var
  v: TTableDef;
begin
  if FTables.ContainsKey(VDbNorm(ViewName)) then
  begin
    if IfNotExists then Exit
    else raise EVDbException.Create(ecTableExists, 'materialized view zaten var: ' + ViewName);
  end;
  v.Name := VDbNorm(ViewName);
  // DIKKAT (F-34): TableId 0 OLAMAZ. ScanRows kayitlari tid ile ayirir;
  // 0 verilirse MV'ler birbirinin satirlarini gorur ve hash denetimi
  // "HASH CARPISMASI" ile patlar (iki MV ayni @mv0 anahtarini paylasir).
  Inc(FNextId);
  v.TableId := Word(FNextId);
  v.Cols := [];
  // F-34: MV satirlari dizin (0..N-1) ile adreslenir; PK YOK.
  v.PkIndex := -1;
  v.AutoInc := 0;
  v.Idx := [];
  v.Fks := [];
  v.Checks := [];
  v.IsMaterializedView := True;
  v.SelectStmt := SelectStmt;
  v.SelectText := SelectText;
  FTables.Add(VDbNorm(ViewName), v);
  MarkSchema;
end;

procedure TVTableDb.DropMaterializedView(const ViewName: string; const IfExists: Boolean);
var
  v: TTableDef;
  i: Integer;
  vals: TStrArray;
  pk: string;
begin
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then
  begin
    if IfExists then Exit
    else raise EVDbException.Create(ecTableNotFound, 'materialized view yok: ' + ViewName);
  end;
  if not v.IsMaterializedView then
    raise EVDbException.Create(ecTableNotFound, 'materialized view yok: ' + ViewName);
  // DIKKAT: IntentDrop OLMAZSA GuardSchemaLoss bu view'u diskte var ama
  // listede yok sayip "sema bozuldu" hatasÄ± verir ve TUM sema yazÄ±mÄ±
  // reddeder (DROP TABLE ile aynÄ± koruma yolu).
  IntentDrop(VDbNorm(ViewName));
  i := 0;
  while i < v.AutoInc do
  begin
    pk := '@mv' + IntToStr(i);
    if ReadRow(VDbNorm(ViewName), pk, vals) then
      IdxDelRow(v, vals, pk, -1);
    FKv.Delete(VDbHashKey(v.Name, pk));
    Inc(i);
  end;
  FTables.Remove(VDbNorm(ViewName));
  MarkSchema;
end;

function TVTableDb.MaterializedViewExists(const Name: string): Boolean;
begin
  Result := FTables.ContainsKey(VDbNorm(Name)) and FTables[VDbNorm(Name)].IsMaterializedView;
end;

// F-34 yardimcilari: SELECT sonucunu MV tablosuna yazar.
procedure TVTableDb.AddMaterializedViewColumn(const ViewName, ColName: string);
// Sonuc kolonlarini semaya ekler. Ayni ad iki kez eklenmez.
var
  v: TTableDef;
  nm: string;
  k, d: Integer;
begin
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then Exit;
  nm := VDbNorm(ColName);
  for k := 0 to High(v.Cols) do
    if VDbNorm(v.Cols[k].Name) = nm then Exit;
  SetLength(v.Cols, Length(v.Cols) + 1);
  d := High(v.Cols);
  v.Cols[d].Name := nm;
  v.Cols[d].Ctype := VCT_STR;
  v.Cols[d].NotNull := False;
  v.Cols[d].HasDef := False;
  v.Cols[d].Def := '';
  v.Cols[d].Unique := False;
  FTables.AddOrSetValue(VDbNorm(ViewName), v);
  MarkSchema;
end;

function TVTableDb.MaterializedViewColCount(const ViewName: string): Integer;
var
  v: TTableDef;
begin
  if FTables.TryGetValue(VDbNorm(ViewName), v) then
    Result := Length(v.Cols)
  else
    Result := 0;
end;

procedure TVTableDb.InsertMaterializedViewRow(const ViewName: string;
  const StrVals: TStrArray);
// Bir sonuc satirini yazar. Satir indeksi = mevcut satir sayisi; PK yok
// oldugu icin benzersizlik zorunlulugu uygulanmaz.
var
  v: TTableDef;
  pk: string;
  n, d: Integer;
begin
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then Exit;
  // DIKKAT: EncodeRow T.Cols sayisina gore serer. Sema henuz kurulmadiysa
  // (Cols bos) degerler sessizce KAYBOLUR ve sonraki satirlarla hash
  // carpismasi olur. Sema yoksa once kur.
  n := Length(StrVals);
  while Length(v.Cols) < n do
  begin
    SetLength(v.Cols, Length(v.Cols) + 1);
    d := High(v.Cols);
    v.Cols[d].Name := 'c' + IntToStr(d + 1);
    v.Cols[d].Ctype := VCT_STR;
    v.Cols[d].NotNull := False;
    v.Cols[d].HasDef := False;
    v.Cols[d].Def := '';
    v.Cols[d].Unique := False;
  end;
  pk := '@mv' + IntToStr(v.AutoInc);
  Inc(v.AutoInc);
  // AutoInc ONCE yazilir: PutRow asagida yeni kopyayi alip EncodeRow eder.
  FTables.AddOrSetValue(VDbNorm(ViewName), v);
  PutRow(FTables[VDbNorm(ViewName)], pk, StrVals);
end;

procedure TVTableDb.ClearMaterializedView(const ViewName: string);
// REFRESH/CREATE oncesi: eski satirlari KV'den GERCEKTEN sil.
// DIKKAT: sadece IdxDelRow cagirmak yeterli DEGIL - KV kaydi kalir ve
// "kayit cozulemedi (tablo=..., anahtar=...)" hatasi verir.
var
  v: TTableDef;
  i: Integer;
  vals: TStrArray;
  pk: string;
begin
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then Exit;
  i := 0;
  while i < v.AutoInc do
  begin
    pk := '@mv' + IntToStr(i);
    if ReadRow(VDbNorm(ViewName), pk, vals) then
      IdxDelRow(v, vals, pk, -1);
    FKv.Delete(VDbHashKey(v.Name, pk));
    Inc(i);
  end;
  v.AutoInc := 0;
  FTables.AddOrSetValue(VDbNorm(ViewName), v);
  MarkSchema;
end;

procedure TVTableDb.ResetMaterializedView(const ViewName: string);
// REFRESH: satirlari + kolon semasini TEK AddOrSetValue ile sifirla.
// DIKKAT: ClearMaterializedView + ayri SetLength iki ayri yazma demektir;
// araya GetTable/LoadSchema girerse eski sema geri gelir.
var
  v: TTableDef;
  i: Integer;
begin
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then Exit;
  i := 0;
  while i < v.AutoInc do
  begin
    FKv.Delete(VDbHashKey(v.Name, '@mv' + IntToStr(i)));
    Inc(i);
  end;
  v.AutoInc := 0;
  SetLength(v.Cols, 0);
  FTables.AddOrSetValue(VDbNorm(ViewName), v);
  MarkSchema;
end;

function TVTableDb.GetMaterializedViewSelect(const ViewName: string): Pointer;
var
  v: TTableDef;
begin
  if FTables.TryGetValue(VDbNorm(ViewName), v) then
    Result := v.SelectStmt
  else
    Result := nil;
end;

function TVTableDb.GetMaterializedViewSelectText(const ViewName: string): string;
var
  v: TTableDef;
begin
  if FTables.TryGetValue(VDbNorm(ViewName), v) then
    Result := v.SelectText
  else
    Result := '';
end;

function TVTableDb.ScanMaterializedView(const ViewName: string;
  out Pks: TStrArray; out Rows: TStrMatrix): Integer;
// MV satirlarini DOGRudan okur (ScanRows yerine). ScanRows tum tabloyu
// tarayip tid ile ayirir; MV'de tarama gereksiz ve yavas.
var
  v: TTableDef;
  i, n: Integer;
  vals: TStrArray;
  pk: string;
begin
  SetLength(Pks, 0); SetLength(Rows, 0); n := 0;
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then Exit(0);
  for i := 0 to v.AutoInc - 1 do
  begin
    pk := '@mv' + IntToStr(i);
    if not ReadRow(VDbNorm(ViewName), pk, vals) then Continue;
    SetLength(Pks, n + 1); SetLength(Rows, n + 1);
    Pks[n] := pk; Rows[n] := vals; Inc(n);
  end;
  Result := n;
end;

function TVTableDb.TryGetTableDef(const Name: string; out Td: TTableDef): Boolean;
begin
  Result := FTables.TryGetValue(VDbNorm(Name), Td);
end;

procedure TVTableDb.RefreshMaterializedView(const ViewName: string; const Concurrently: Boolean);
var
  v: TTableDef;
begin
  if not FTables.TryGetValue(VDbNorm(ViewName), v) then
    raise EVDbException.Create(ecTableNotFound, 'materialized view yok: ' + ViewName);
  if not v.IsMaterializedView then
    raise EVDbException.Create(ecTableNotFound, 'materialized view yok: ' + ViewName);
  MarkSchema;
end;

// F-35: STORED PROCEDURE (stub)
procedure TVTableDb.CallProcedure(const ProcName: string; const Args: TStrArray;
  out Results: TStrArray);
begin
  SetLength(Results, 0);
  // NOT: ProcedureExists kontrolu executor'da yapilir; bilinmeyen
  // prosedur sessizce BOS sonuc donmesin diye burada da dogrulanir.
  if not ProcedureExists(ProcName) then
    raise EVDbException.Create(ecTableNotFound, 'prosedur yok: ' + ProcName);
end;

// RETURNING support
function TVTableDb.InsertReturning(const Table: string; const ColNames, Values: TStrArray;
  out OutPk: string; out OutVals: TStrArray): Boolean;
var
  t: TTableDef;
  vals, dummyVals: TStrArray;
  provided: array of Boolean;
  i, ci: Integer;
  pk: string;
  iv: Int64;
  key: QWord;
  b: TBytes;
  exTid: Word;
  exPk: string;
  exVals: TStrArray;
begin
  Result := False;
  OutPk := '';
  OutVals := nil;
  
  t := GetTable(Table);
  if Length(ColNames) <> Length(Values) then
    raise EVDbException.CreateFmt(ecInvalidArgument, '%s: sutun sayisi (%d) deger sayisiyla (%d) esit degil',
      [Table, Length(ColNames), Length(Values)]);
  
  SetLength(vals, Length(t.Cols));
  SetLength(provided, Length(t.Cols));
  for i := 0 to High(vals) do begin vals[i] := ''; provided[i] := False; end;
  
  for i := 0 to High(ColNames) do
  begin
    ci := FindCol(t, ColNames[i]);
    if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + ColNames[i]);
    if provided[ci] then
      raise EVDbException.Create(ecColumnExists, 'kolon iki kez verildi: ' + ColNames[i]);
    vals[ci] := Values[i];
    provided[ci] := True;
  end;
  
  // verilmemis kolonlara DEFAULT
  for i := 0 to High(vals) do
    if not provided[i] and t.Cols[i].HasDef then
      vals[i] := t.Cols[i].Def;
  
  // PK belirleme
  if t.PkIndex < 0 then
  begin
    Inc(t.AutoInc);
    pk := '@' + IntToStr(t.AutoInc);
    FTables.AddOrSetValue(t.Name, t);
    MarkSchema;
  end
  else
  begin
    pk := vals[t.PkIndex];
    if t.Cols[t.PkIndex].Ctype = VCT_INT then
    begin
      if pk = '' then
      begin
        iv := t.AutoInc + 1;
        if ReadRow(t.Name, IntToStr(iv), dummyVals) then
          iv := MaxPkInt(t) + 1;
        t.AutoInc := iv;
        vals[t.PkIndex] := IntToStr(iv);
        pk := vals[t.PkIndex];
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
      end
      else if VDbParseInt(pk, iv) and (iv > t.AutoInc) then
      begin
        t.AutoInc := iv;
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
      end;
    end;
    if pk = '' then raise EVDbException.Create(ecInvalidName, 'PK bos olamaz');
  end;
  
  CheckConstraints(t, vals, '');
  if t.PkIndex >= 0 then pk := vals[t.PkIndex];
  if not VDbCheckOK(vals, t.Checks) then
    raise EVDbException.Create(ecCheckViolation, 'CHECK ihlali: ' + t.Name);
  CheckFk(t, vals);
  
  key := VDbHashKey(t.Name, pk);
  if FKv.Get(key, b) then
  begin
    if DecodeRow(b, exTid, exPk, exVals) and (exTid = t.TableId) and (exPk = pk) then
      raise EVDbException.Create(ecDuplicatePrimaryKey, 'duplicate PK: ' + pk)
    else
      raise EVDbException.CreateFmt(ecHashCollision, 'VDb: hash carpismasi (%s, %s)', [t.Name, pk]);
  end;
  
  b := EncodeRow(t.TableId, pk, t, vals);
  FKv.Put(key, b);
  IdxAddRow(t, vals, pk, -1);
  
  // RETURNING icin donus degerleri
  OutPk := pk;
  OutVals := vals;
  Result := True;
end;

function TVTableDb.UpsertRowReturning(const Table: string; const ColNames, Values: TStrArray;
  const OnConflictAction: TOnConflictAction;
  const OnConflictTarget: TStrArray;
  const SetValues: TSetValuePairs;
  out OutPk: string; out OutVals: TStrArray): Boolean;
var
  t: TTableDef;
  vals, existingVals, dummyVals: TStrArray;
  provided: array of Boolean;
  i, ci, ciTarget: Integer;
  pk: string;
  iv: Int64;
  key: QWord;
  b: TBytes;
  exTid: Word;
  exPk: string;
  exVals: TStrArray;
  conflict: Boolean;
  doUpdate: Boolean;
begin
  Result := False;
  OutPk := '';
  OutVals := nil;
  
  t := GetTable(Table);
  if Length(ColNames) <> Length(Values) then
    raise EVDbException.CreateFmt(ecInvalidArgument, '%s: sutun sayisi (%d) deger sayisiyla (%d) esit degil',
      [Table, Length(ColNames), Length(Values)]);
  
  SetLength(vals, Length(t.Cols));
  SetLength(provided, Length(t.Cols));
  for i := 0 to High(vals) do begin vals[i] := ''; provided[i] := False; end;
  
  for i := 0 to High(ColNames) do
  begin
    ci := FindCol(t, ColNames[i]);
    if ci < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + ColNames[i]);
    if provided[ci] then
      raise EVDbException.Create(ecColumnExists, 'kolon iki kez verildi: ' + ColNames[i]);
    vals[ci] := Values[i];
    provided[ci] := True;
  end;
  
  // verilmemis kolonlara DEFAULT
  for i := 0 to High(vals) do
    if not provided[i] and t.Cols[i].HasDef then
      vals[i] := t.Cols[i].Def;
  
  // PK belirleme
  if t.PkIndex < 0 then
  begin
    Inc(t.AutoInc);
    pk := '@' + IntToStr(t.AutoInc);
    FTables.AddOrSetValue(t.Name, t);
    MarkSchema;
  end
  else
  begin
    pk := vals[t.PkIndex];
    if t.Cols[t.PkIndex].Ctype = VCT_INT then
    begin
      if pk = '' then
      begin
        iv := t.AutoInc + 1;
        if ReadRow(t.Name, IntToStr(iv), dummyVals) then
          iv := MaxPkInt(t) + 1;
        t.AutoInc := iv;
        vals[t.PkIndex] := IntToStr(iv);
        pk := vals[t.PkIndex];
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
      end
      else if VDbParseInt(pk, iv) and (iv > t.AutoInc) then
      begin
        t.AutoInc := iv;
        FTables.AddOrSetValue(t.Name, t);
        MarkSchema;
      end;
    end;
    if pk = '' then raise EVDbException.Create(ecInvalidName, 'PK bos olamaz');
  end;
  
  CheckConstraints(t, vals, '');
  if t.PkIndex >= 0 then pk := vals[t.PkIndex];
  if not VDbCheckOK(vals, t.Checks) then
    raise EVDbException.Create(ecCheckViolation, 'CHECK ihlali: ' + t.Name);
  CheckFk(t, vals);
  
  key := VDbHashKey(t.Name, pk);
  conflict := FKv.Get(key, b);
  
  if conflict then
  begin
    if DecodeRow(b, exTid, exPk, existingVals) and (exTid = t.TableId) and (exPk = pk) then
    begin
      // PK conflict bulundu
      case OnConflictAction of
        ocaDoNothing:
        begin
          // DO NOTHING - islem basarili sayilir ama hicbir sey degistirmez
          OutPk := pk;
          OutVals := existingVals;
          Result := True;
          Exit;
        end;
        ocaDoUpdate:
        begin
          doUpdate := True;
        end;
        else
        begin
          // ocaNone - hata firlat
          raise EVDbException.Create(ecDuplicatePrimaryKey, 'duplicate PK: ' + pk);
        end;
      end;
      
      if doUpdate then
      begin
        // R-03: ON CONFLICT DO UPDATE SET
        // DIKKAT: yeni degerler INSERT satiri (vals) uzerinden DEGIL,
        // MEVCUT satir (existingVals) uzerinden kurulur. Aksi halde
        // SET'te belirtilmeyen kolonlar gelen degerlerle ezilirdi.
        SetLength(dummyVals, Length(t.Cols));
        for i := 0 to High(t.Cols) do
          if i <= High(existingVals) then dummyVals[i] := existingVals[i]
          else dummyVals[i] := '';
        for ci := 0 to High(SetValues) do
        begin
          i := SetValues[ci].ColIdx;
          if (i < 0) or (i > High(dummyVals)) then
            raise EVDbException.Create(ecColumnNotFound,
              'ON CONFLICT DO UPDATE: kolon yok');
          dummyVals[i] := SetValues[ci].Value;
        end;
        // PK degistirilemez
        if t.PkIndex >= 0 then dummyVals[t.PkIndex] := pk;
        vals := dummyVals;

        // Eski satir indekslerinden sil
        IdxDelRow(t, existingVals, pk, -1);

        CheckConstraints(t, vals, pk);
        if not VDbCheckOK(vals, t.Checks) then
          raise EVDbException.Create(ecCheckViolation, 'CHECK ihlali: ' + t.Name);
        CheckFk(t, vals);

        // Yeni satir yaz
        b := EncodeRow(t.TableId, pk, t, vals);
        FKv.Put(key, b);
        IdxAddRow(t, vals, pk, -1);

        OutPk := pk;
        OutVals := vals;
        Result := True;
        Exit;
      end;
    end
    else
    begin
      raise EVDbException.CreateFmt(ecHashCollision, 'VDb: hash carpismasi (%s, %s)', [t.Name, pk]);
    end;
  end
  else
  begin
    // Conflict yok - normal insert
    b := EncodeRow(t.TableId, pk, t, vals);
    FKv.Put(key, b);
    IdxAddRow(t, vals, pk, -1);
    
    OutPk := pk;
    OutVals := vals;
    Result := True;
  end;
end;

// F-35: User-defined function / procedure support (stub)
//
// NOT: Tanimlar OLMAZDA calistirilir; katalog yazimi ve govde
// yorumlayicisi F-35'in asil isidir. Buradaki katman yalnizca
// executor'in cagirdigi API yuzeyini tanimlar ve "var/yok" bilgisini
// tutar. Bilinmeyen ad sessizce bos sonuc DONMEZ: hata verir.
function TVTableDb.FunctionExists(const FuncName: string): Boolean;
begin
  Result := FFunctions.ContainsKey(VDbNorm(FuncName));
end;

function TVTableDb.ProcedureExists(const ProcName: string): Boolean;
begin
  Result := FProcedures.ContainsKey(VDbNorm(ProcName));
end;

procedure TVTableDb.CreateFunction(const FuncName: string;
  const Params: array of TFunctionParameter; const ReturnType: string;
  const Language, Body: string; const IfNotExists: Boolean);
var
  fd: TFunctionDef;
  i: Integer;
begin
  if FunctionExists(FuncName) then
  begin
    if IfNotExists then Exit
    else raise EVDbException.Create(ecTableExists, 'fonksiyon zaten var: ' + FuncName);
  end;
  fd.Name := VDbNorm(FuncName);
  SetLength(fd.Parameters, Length(Params));
  for i := 0 to High(Params) do fd.Parameters[i] := Params[i];
  fd.ReturnType := ReturnType;
  fd.Language := Language;
  fd.Body := nil;
  fd.IsFunction := True;
  FFunctions.AddOrSetValue(fd.Name, fd);
end;

procedure TVTableDb.DropFunction(const FuncName: string; const IfExists: Boolean);
var
  fd: TFunctionDef;
begin
  if not FunctionExists(FuncName) then
  begin
    if IfExists then Exit
    else raise EVDbException.Create(ecTableNotFound, 'fonksiyon yok: ' + FuncName);
  end;
  // Govde AST'si katalogun SAHIPLENIMINDEDIR; burada serbest birakilir.
  // Eksik Free = bellek sizintisi.
  if FFunctions.TryGetValue(VDbNorm(FuncName), fd) then fd.Body.Free;
  FFunctions.Remove(VDbNorm(FuncName));
end;

function TVTableDb.GetFunctionDef(const Name: string; out Def: TFunctionDef): Boolean;
begin
  Result := FFunctions.TryGetValue(VDbNorm(Name), Def);
end;

function TVTableDb.GetProcedureDef(const Name: string; out Def: TFunctionDef): Boolean;
begin
  Result := FProcedures.TryGetValue(VDbNorm(Name), Def);
end;

procedure TVTableDb.SetFunctionBody(const Name: string; ABody: TObject);
var fd: TFunctionDef;
begin
  if not FFunctions.TryGetValue(VDbNorm(Name), fd) then Exit;
  fd.Body.Free;          // eski govdeyi serbest birak
  fd.Body := ABody;      // yeni govdeyi SAHPLEN (sahiplik devri)
  FFunctions.AddOrSetValue(VDbNorm(Name), fd);
end;

procedure TVTableDb.SetProcedureBody(const Name: string; ABody: TObject);
var fd: TFunctionDef;
begin
  if not FProcedures.TryGetValue(VDbNorm(Name), fd) then Exit;
  fd.Body.Free;
  fd.Body := ABody;
  FProcedures.AddOrSetValue(VDbNorm(Name), fd);
end;

procedure TVTableDb.CreateProcedure(const ProcName: string;
  const Params: array of TFunctionParameter; const Language,
  Body: string; const IfNotExists: Boolean);
var
  fd: TFunctionDef;
  i: Integer;
begin
  if ProcedureExists(ProcName) then
  begin
    if IfNotExists then Exit
    else raise EVDbException.Create(ecTableExists, 'prosedur zaten var: ' + ProcName);
  end;
  fd.Name := VDbNorm(ProcName);
  SetLength(fd.Parameters, Length(Params));
  for i := 0 to High(Params) do fd.Parameters[i] := Params[i];
  fd.ReturnType := '';
  fd.Language := Language;
  fd.Body := nil;
  fd.IsFunction := False;
  FProcedures.AddOrSetValue(fd.Name, fd);
end;

procedure TVTableDb.DropProcedure(const ProcName: string; const IfExists: Boolean);
var
  fd: TFunctionDef;
begin
  if not ProcedureExists(ProcName) then
  begin
    if IfExists then Exit
    else raise EVDbException.Create(ecTableNotFound, 'prosedur yok: ' + ProcName);
  end;
  if FProcedures.TryGetValue(VDbNorm(ProcName), fd) then fd.Body.Free;
  FProcedures.Remove(VDbNorm(ProcName));
end;

{ ================= F-36 TRIGGER KATALOGU ================= }

procedure TVTableDb.FreeAllTriggers;
// Katalogdaki TUM tetikleyicilerin govde/WHEN AST'lerini serbest birakir.
begin
  ClearTriggers;
end;

procedure TVTableDb.DropTriggersOfTable(const TableName: string);
// Verilen tabloya bagli tum tetikleyicileri kaldirir. Bos ad verilirse
// TUM katalog temizlenir.
var
  k: string;
  td: TTriggerDef;
  drop: TStrArray;
  i: Integer;
begin
  if FTriggers = nil then Exit;
  SetLength(drop, 0);
  for k in FTriggers.Keys do
  begin
    if not FTriggers.TryGetValue(k, td) then Continue;
    if (TableName = '') or (td.TableName = VDbNorm(TableName)) then
    begin
      SetLength(drop, Length(drop) + 1);
      drop[High(drop)] := k;
    end;
  end;
  // Katalog YAZILIRKEN anahtarlari silmek guvenli degildir; once adlar
  // toplanir, sonra silinir.
  for i := 0 to High(drop) do
  begin
    if FTriggers.TryGetValue(drop[i], td) then
    begin
      td.Body.Free;
      td.WhenCondition.Free;
    end;
    FTriggers.Remove(drop[i]);
  end;
end;

procedure TVTableDb.ClearTriggers;
var td: TTriggerDef;
begin
  if FTriggers = nil then Exit;
  for td in FTriggers.Values do
  begin
    td.Body.Free;
    td.WhenCondition.Free;
  end;
  FTriggers.Clear;
end;

procedure TVTableDb.CreateTrigger(const TrgName, TableName: string;
  const Events: array of Byte; Timing, ForEach: Byte;
  const IfNotExists: Boolean);
var
  td: TTriggerDef;
  i: Integer;
begin
  if TriggerExists(TrgName) then
  begin
    if IfNotExists then Exit
    else raise EVDbException.Create(ecTableExists,
      'tetikleyici zaten var: ' + TrgName);
  end;
  td.Name := VDbNorm(TrgName);
  td.TableName := VDbNorm(TableName);
  td.Timing := Timing;
  td.ForEach := ForEach;
  SetLength(td.Events, Length(Events));
  for i := 0 to High(Events) do td.Events[i] := Events[i];
  td.WhenCondition := nil;
  td.Body := nil;
  FTriggers.AddOrSetValue(td.Name, td);
end;

procedure TVTableDb.SetTriggerDef(const TrgName: string; const WhenCond,
  Body: TObject);
var td: TTriggerDef;
begin
  if not FTriggers.TryGetValue(VDbNorm(TrgName), td) then Exit;
  // Yeni govde gelmeden_once eskileri serbest birak: ayni adla iki kez
  // CREATE TRIGGER ... OR REPLACE calistirilirsa sizinti olmaz.
  td.Body.Free;
  td.WhenCondition.Free;
  td.WhenCondition := WhenCond;
  td.Body := Body;   // sahiplik kataloga devredildi
  FTriggers.AddOrSetValue(VDbNorm(TrgName), td);
end;

procedure TVTableDb.DropTrigger(const TrgName: string; const IfExists: Boolean);
var td: TTriggerDef;
begin
  if not TriggerExists(TrgName) then
  begin
    if IfExists then Exit
    else raise EVDbException.Create(ecTableNotFound,
      'tetikleyici yok: ' + TrgName);
  end;
  if FTriggers.TryGetValue(VDbNorm(TrgName), td) then
  begin
    td.Body.Free;
    td.WhenCondition.Free;
  end;
  FTriggers.Remove(VDbNorm(TrgName));
end;

function TVTableDb.TriggerExists(const TrgName: string): Boolean;
begin
  Result := (FTriggers <> nil) and FTriggers.ContainsKey(VDbNorm(TrgName));
end;

function TVTableDb.GetTriggerDef(const TrgName: string;
  out Def: TTriggerDef): Boolean;
begin
  Result := (FTriggers <> nil) and FTriggers.TryGetValue(VDbNorm(TrgName), Def);
end;

function TVTableDb.TriggersFor(const TableName: string; Timing,
  Ev: Byte): TStrArray;
{ Ayni tablo + zamanlama + olay icin birden fazla tetikleyici olabilir.
  Sonuc ADI SIRALI dondurulur: tetikleyici calisma sirasi kodun icinde
  yanlislikla dictionary sirasina baglanmasin diye. }
var
  td: TTriggerDef;
  k: string;
  i: Integer;
  found: Boolean;
  evlist: string;
  evstr: string;
begin

  if FTriggers = nil then Exit;
  for k in FTriggers.Keys do
  begin
    if not FTriggers.TryGetValue(k, td) then Continue;
    evstr := '';
    for i := 0 to High(td.Events) do evstr := evstr + IntToStr(td.Events[i]) + ',';
    if td.TableName <> VDbNorm(TableName) then
    begin
      WriteLn('  check ' + k + ': TableName mismatch ' + td.TableName + ' vs ' + VDbNorm(TableName));
      Continue;
    end;
    if td.Timing <> Timing then
    begin
      WriteLn('  check ' + k + ': Timing mismatch ' + IntToStr(td.Timing) + ' vs ' + IntToStr(Timing));
      Continue;
    end;
    found := False;
    for i := 0 to High(td.Events) do
      if td.Events[i] = Ev then found := True;
    WriteLn('  detail ' + k + ': TblOK=' + BoolToStr(td.TableName = VDbNorm(TableName), True) +
      ' TimOK=' + BoolToStr(td.Timing = Timing, True) + ' Events=[' + evstr + '] EvOK=' + BoolToStr(found, True));
    if not found then Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := td.Name;
    WriteLn('  ADD ' + k + ' -> Result now len=' + IntToStr(Length(Result)));
  end;
end;

function TVTableDb.ExecuteFunction(const FuncName: string;
  const Args: TStrArray): string;
begin
  if not FunctionExists(FuncName) then
    raise EVDbException.Create(ecTableNotFound, 'fonksiyon yok: ' + FuncName);
  // NOT: govde yorumlayicisi F-35'in asil isidir; su an anlamsiz bir
  // deger donmek "sessizce yanlis sonuc" uretirdi, bu yuzden hata verir.
  raise EVDbException.Create(ecUnsupported,
    'fonksiyon govdesi henuz calistirilamiyor: ' + FuncName);
end;

function TVTableDb.IsView(const Name: string): Boolean;
begin
  Result := FTables.ContainsKey(VDbNorm(Name)) and FTables[VDbNorm(Name)].IsView;
end;

function TVTableDb.ViewSelectText(const ViewName: string): string;
var
  v: TTableDef;
begin
  if FTables.TryGetValue(VDbNorm(ViewName), v) then
    Result := v.SelectText
  else
    Result := '';
end;

end.
