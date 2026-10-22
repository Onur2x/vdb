unit VDbExecutor;

{ VDb SQL AST Yurutucusu (Executor)  - Faz 2 Adim 2.2
  AST cumle dugumlerini (TSqlStmtNode) TVTableDb uzerinde calistirir ve
  TSqlResult sonuc nesnesini uretir.

  Ozellikler:
  * EvalExpr: tam tip-bilgili ifade degerlendirici (literal, kolon, ikili/tekli
    op, IN, BETWEEN, COUNT/SUM/AVG/MIN/MAX fonksiyon cagrilari)
  * ExecSelect: WHERE filtreleme, ORDER BY (cok sutun, ASC/DESC),
    LIMIT/OFFSET, DISTINCT, GROUP BY + HAVING, toplama fonksiyonlari,
    INNER/LEFT JOIN, UNION/UNION ALL/EXCEPT/INTERSECT
  * ExecInsert: cok satirli VALUES + INSERT ... SELECT
  * ExecUpdate: AST WHERE ile filtreli guncelleme (Delete+ReInsert)
  * ExecDelete: AST WHERE ile filtreli silme
  * DDL (CREATE/ALTER/DROP TABLE, CREATE/DROP INDEX)
  * TX (BEGIN/COMMIT/ROLLBACK), Admin (VERIFY/VACUUM/REINDEX), JSON
}

{$mode delphi}

interface

uses
  Classes, SysUtils, Math, Generics.Collections,
  VDbCore, VDbTable, VDbAst, VDbJson, VDbErr, VDbText, VDbXml, VDbSpatial,
  VDbRange, VDbParser, VDbTypes, VDbReplication, VDbParallel, VDbMonitor,
  VDbPlatform, VDbCost, VDbExtension, VDbVector, VDbArrow, VDbParquet;

const
  // F2-18: DISTINCT / UNION tekilleÅŸtirme sonucu ve set-op birlestirme
  // satiri ust siniri. Once sinirsizdi; tekilleÅŸtirme kovasi bir tabloda
  // bellek kucak doldurabiliyordu (OOM).
  VDB_MAX_RESULT_ROWS = 2000000;
  // F2-18: satir icin tekillestirme anahtari. Her deger "len:deger"
  // biciminde yazilir; boylece degerin icindeki ayirici (#1) belirsizlik
  // yaratmaz.
  VDB_ROWKEY_SEP = #1;
  // F3-2: quicksort yigin derinligi. Iki durakli (push larger half)
  // quicksortta derinlik log2(N); 64 cerverek. Yine de asilirsa dizi
  // disina yazilmamasi icin sinir denetimi vardir.
  VDB_SORT_STACK_MAX = 64;

type
  { NOT: TByteArray burada YENIDEN tanimlaniyordu. VDbTypes zaten
    tanimliyor ve VDbTable'in implementation uses'i VDbExecutor
    oldugu icin "VDbIdxMultiCmp ... header doesn't match" hatasi
    veriyordu (iki ayri TByteArray tipi). Tek kaynak: VDbTypes. }

  // P5-CTE: materyallestirilmis gecici sonuc (ad -> satirlar + tipler).
  TCteTable = record
    Names: TStrArray;
    Types: TByteArray;
    Rows: TStrMatrix;
  end;

  { H3 (2026-10-18): ZONE MAP — offset bolumu basina min/max.
    Yalnizca INT(8)/FLOAT(8) kolonlar icin kurulur. Amac: aralik/esitlik
    yukleminde "bu bolumde eslesen satir OLAMAZ" kanitlanirsa bolum HIC
    okunmaz. Guvenlik: min/max ASLA daraltilmaz; bir satirin tipi
    beklenenden farkliysa ilgili kolon "kullanilamaz" isaretlenir ve o
    kolon icin budama YAPILMAZ (sessiz satir kaybi imkansiz). }
  TVDbZoneOp = (zopEq, zopNe, zopLt, zopLe, zopGt, zopGe, zopIn);

  TVDbZoneCond = record
    Col: Integer;
    Op: TVDbZoneOp;
    IsFloat: Boolean;
    I: Int64;
    F: Double;
    InIsFloat: Boolean;
    InInts: array of Int64;
    InFloats: array of Double;
  end;

  TVDbZoneMap = class
  public
    GenSeq: QWord;
    GenEpoch: QWord;
    BucketCount: Integer;
    ColIds: array of Integer;
    ColFloat: array of Boolean;
    ColUsable: array of Boolean;
    MinI, MaxI: array of Int64;     // BucketCount * NCol
    MinF, MaxF: array of Double;    // BucketCount * NCol
    HasVal: array of Byte;          // BucketCount * NCol
    Complete: array of Byte;        // BucketCount
    constructor Create(ASeq, AEpoch: QWord; ABucketCount: Integer;
      const ACols: array of Integer; const AIsFloat: array of Boolean);
    function FindCol(ACol: Integer): Integer;
  end;

  { H15: akisli GROUP BY yolunda HAVING icin aggregate dugumu -> deger
    eslemesi. Akisli yol kaynak satirlari tutmadigindan HAVING'deki
    aggregate'lar sayaclardan hesaplanip burada dondurulur. }
  TVdbHavingOv = record
    N: TSqlExprNode;
    V: string;
  end;

  { TVSqlExecutor }

  TVSqlExecutor = class
  private
    FT: TVTableDb;
    // F-40: oturum yalitim seviyesi (varsayilan REPEATABLE READ).
    FIsolation: TIsolationLevel;
    // F-41: bu yurutucunun bagli oldugu SQL oturumu (0 = kimliksiz).
    FSessionId: Cardinal;
    // R-20: aktif tablo adi. Kolon varsayilan collation'i (ad:tip:bayrak:
    // hexdef:collate) metin karsilastirmasinda kullanilir; eski sema
    // dosyalarinda bu alan yoktur, o durumda bos string = motor varsayilani.
    FCurTable: string;
    // R-20: aktif METIN kolonunun varsayilan collation'i (bos = motor
    // varsayilani). WHERE karsilastirmalarinda kullanilir.
    FCurCollation: string;
    // R-20: acik `... COLLATE <ad>` yazildiysa True. Bu durumda kolonun
    // varsayilan collation'i ONUN USTUNE YAZILMAZ (acik COLLATE kazanir).
    FExplicitColl: Boolean;
    // P5-2: iliskisiz alt sorgu sonuclari (cumle basi onbellek; ayni ic
    // sorgu disaridaki her satir icin bir kez calisir). Anahtar = AST dugumu.
    FSubCache: TDictionary<Pointer, TSqlResult>;
    // F2-20: IN (SELECT ...) deger kumesi (alt sorgu basina TEK KEZ kurulur).
    // Once her dis satir icin alt sonucu yeniden taraniyordu (O(N*M)).
    FInSetCache: TDictionary<Pointer, TDictionary<string, Byte>>;
    // P5-CTE: WITH adlari (cumle basi kapsam; sirayla doldurulur,
    // sonrakiler oncekileri gorur).
    FCteTables: TDictionary<string, TCteTable>;
    { H3: tablo id -> zone map (VERI DEGISINCE (Seq/Epoch) gecersiz). }
    FZoneMaps: TDictionary<Integer, TVDbZoneMap>;
    { M5: tablo id + kolon -> inverted FTS index; Seq degisince yeniden kurulur. }
    FFtsIndexes: TDictionary<string, TVdbFtsIndex>;
    FFtsSeqs: TDictionary<string, QWord>;
    { M4: tablo id + kolon + metrik -> HNSW yakinlik indeksi. Ayni sekilde
      Seq degisince tembel olarak yeniden kurulur. }
    FVecIndexes: TDictionary<string, TVdbVectorIndex>;
    FVecSeqs: TDictionary<string, QWord>;
    // H3: COUNT(*) + indekslenebilir WHERE icin yalnizca indeks girdilerini
    // sayan yol. FCountOnly yalnizca TryIndexCount cagrisi boyunca aciktir;
    // NarrowRows bu modda satir OKUMAZ, FCountResult'a sayiyi yazar.
    FCountOnly: Boolean;
    FCountResult: Int64;
    // 4.3: HAVING icinde dogrudan aggregate. EvalBool sirasinda aktif
    // grup baglami: FAggIdx <> nil iken EvalExpr'de aggregate cagrilari
    // grup satirlari uzerinden hesaplanir (alias zorunlu degil). yalnizca
    // HAVING degerlendirmesi sirasinda acilir, sonra eski degerine doner
    // (ic ice HAVING'li alt sorgu icin kayit/restor).
    FAggIdx: TList<Integer>;
    FAggSrcRows: TStrMatrix;
    FAggCNames: TStrArray;
    FAggCTypes: TByteArray;
    { H15: akisli GROUP BY yolunda HAVING icin aggregate degerleri.
      Akisli yol grup satirlarini TUTMAZ; aggregate'lar sayac olarak
      hesaplanir. HAVING ifadesindeki aggregate cagrilari bu eslemeden
      cozulur (genel yolla ayni sonuc). }
    FHavingOv: array of TVdbHavingOv;
    FHavingOvOn: Boolean;
    // F-27/F-28: NATURAL JOIN / USING eslesmesi. FJoinUsing True iken JOIN
    // karsilastirmasi OnCondition yerine bu kolon ciftleriyle yapilir.
    FJoinUsing: Boolean;
    FJoinUsingCols: TStrArray;     // F-28: USING listesi (nil = NATURAL veya yok)
    FJoinPairL: array of Integer;   // sol kume indeksi (1 tabanli)
    FJoinPairR: array of Integer;   // sag kume indeksi (n1+1 tabanli)
    // F-03: Correlated subquery â€” dÄ±ÅŸ satÄ±r baÄŸlamÄ± (SubResult iÃ§inde ayarlanÄ±r)
    FOuterRow: TStrArray;
    FOuterColNames: TStrArray;
    // F-36: trigger context - ESKI satir (UPDATE/DELETE)
    FOuterOldRow: TStrArray;
    FOuterOldColNames: TStrArray;
    // R-03: UPSERT - excluded pseudo-table values
    FExcludedRow: TStrArray;
    FExcludedColNames: TStrArray;
    // F-03: ic calisan SELECT'in kendi tablosu/alias'i. Tek-tablo yolunda
    // ColNames niteliksiz oldugu icin nitelikli referans (b.id) kapsam
    // denetiminden gecer; bu alan olmadan dis satira yanlis duser.
    FCurQualifier: string;
    // F-09: SELECT listesindeki ifade dizisi (QUALIFY pencere eslesmesi)
    FStmtColumns: TArray<TSqlExprNode>;
    // P5-CTE: gÃ¶rÃ¼len CTE adlarÄ± (sonsuz dÃ¶ngÃ¼ korumasi)
    FSeenCteNames: string;
    // F-35: aktif fonksiyon/prosedur parametre kapsami. Govde icindeki
    // ifadelerde parametre adlari cozulur; ic ice cagirimda yigilir.
    FProcRow: TStrArray;
    FProcColNames: TStrArray;
    // F-36: aktif tetikleyici kapisinda ic ice gecme derinligi.
    FTriggerNesting: Integer;
    // R-10: CTE ANCHOR'unu degerlendirirken SET OP birlestirmesi
    // YAPILMAZ. Aksi halde `anchor UNION ALL terim` yaziminda ozyinelemeli
    // terim, CTE tablosu (orn. `r`) henuz materialize EDILMEDEN
    // calisir ve "tablo yok: r" ile patlar.
    FNoSetOpMerge: Boolean;
    // R-10: ozyinelemeli CTE dongusunde alt sorgu ONBELLEGI devre disi
    // birakilir. SubResult sonucu Sel POINTER'ina gore onbellekler; ozyineleme
    // ise AYNI terimi her turda TEKRAR calistirmak zorundadir. Onbellek
    // kullanilirsa ilk turun sonucu dondurulur ve dongu hic bitmez.
    FNoSubCache: Boolean;

    // RETURN cumlesi sonucu (ic ice cagirimda yigilir)
    FProcReturn: string;
    FProcReturned: Boolean;

    { ---------- Expression Evaluator ---------- }
    function EvalExpr(Expr: TSqlExprNode; const Row: TStrArray;
      const ColNames: TStrArray; const ColTypes: TByteArray): string;
    function EvalBool(Expr: TSqlExprNode; const Row: TStrArray;
      const ColNames: TStrArray; const ColTypes: TByteArray): Boolean;
    function EvalBinary(AOp: TSqlBinaryOp; const LeftVal, RightVal: string;
      Ctype: Byte): string;
    function EvalUnary(AOp: TSqlUnaryOp; const Val: string): string;
    // 4.3: aggregate'i verilen grup satir kumesi uzerinden hesaplar
    // (SELECT listesi ve HAVING icin TEK uygulama â€” kod tekrari yok).
    function EvalAggregateValue(fn: TSqlFuncCallNode;
      const SrcRows: TStrMatrix; Idx: TList<Integer>;
      const ACNames: TStrArray; const ACTypes: TByteArray): string;
    // F-14/F-15: STRING_AGG / PERCENTILE
    function EvalAggNode(AN: TSqlAggNode;
      const SrcRows: TStrMatrix; Idx: TList<Integer>;
      const ACNames: TStrArray; const ACTypes: TByteArray): string;
    // 4.3: aggregate fonksiyonun karsilastirma tipi (COUNT->INT,
    // SUM/AVG->FLOAT, MIN/MAX->kolon tipi). Yoksa metin sirasi kiyasi
    // ('10' > '9' => false) yanlis HAVING sonucu dogurur.
    function AggFuncCtype(fn: TSqlFuncCallNode): Byte;
    // H-ek: ifade sonuc tipi (aritmetik -> INT/FLOAT). Aksi halde WHERE/ON'da
    // `(a+0) > 198` gibi ifadeler yanlislikla METIN sirasiyla kiyaslanir
    // ('1990' < '198' yanlis sonuc). Yalnizca sayisal sonuc kanitlanabiliyorsa
    // VCT_INT/VCT_FLOAT doner; aksi halde VCT_STR (mevcut davranis korunur).
    function ExprResultCtype(E: TSqlExprNode;
      const ColNames: TStrArray; const ColTypes: TByteArray): Byte;
    procedure ExecCall(Stmt: TSqlCallStmt; out Res: TSqlResult);
    { F-35: CREATE/DROP FUNCTION + PROCEDURE. Bu metotlar vardi ama
      SINIF TANIMINDA yoktu -> "method identifier expected" hatasi. }
    procedure ExecCreateFunction(Stmt: TSqlCreateFunctionStmt; out Res: TSqlResult);
    // F-35: fonksiyon/prosedur CALISTIRMA
    //
    // Parametre kapsami: FProcRow/FProcColNames. EvalExpr'in kolon cozumleme
    // zincirinde SADECE bulunamazsa denetlenir; boylece govde icindeki bir
    // SELECT'in kendi kolonlari parametre adini golgelemez.
    function CallUserFunction(const FuncName: string;
      const Args: TStrArray): string;
    function CallUserProcedure(const ProcName: string; const Args: TStrArray;
      out Res2: TSqlResult): Boolean;
    // Govdeyi calistirir; RETURN cumlesi bulunursa RetVal'e yazar.
    procedure RunProcBody(const Body: TObject; const ArgTexts: TStrArray;
      const Params: TFunctionParamArray; out RetVal: string; out Returned: Boolean);
    procedure ExecProcStatement(Stmt: TSqlStmtNode; out Res2: TSqlResult);
    procedure ExecDropFunction(Stmt: TSqlDropFunctionStmt; out Res: TSqlResult);
    procedure ExecCreateProcedure(Stmt: TSqlCreateProcedureStmt; out Res: TSqlResult);
    procedure ExecDropProcedure(Stmt: TSqlDropProcedureStmt; out Res: TSqlResult);
    procedure ExecCreateTrigger(Stmt: TSqlCreateTriggerStmt; out Res: TSqlResult);
    procedure ExecDropTrigger(Stmt: TSqlDropTriggerStmt; out Res: TSqlResult);
    // F-36: helper metodlar (helper metotlar).
    procedure FireTriggers(const TableName: string; Timing: Byte; Event: Byte;
      const OldRow, NewRow: TStrArray; const NewColNames: TStrArray;
      out Res: TSqlResult; IsRowOp: Boolean);
    // F-36: helper (class ici).
    procedure FireTriggerDef(const TDef: TTriggerDef;
      Timing: Byte; Event: Byte; const OldRow, NewRow: TStrArray;
      const NewColNames: TStrArray; out Res: TSqlResult);
    procedure F36_InsertRowHooks(var NewRow: TStrArray;
      const TableName: string; const cnames: TStrArray; out Res: TSqlResult);
    // F-34: kayitli SELECT metnini yeniden ayristirir (REFRESH)
    function ParseSelectText(const Txt: string): TSqlSelectStmt;
    // R-19: politika kosulu metnini AST'ye cevirir
    function RlsExprNode(const Txt: string): TSqlExprNode;
    function RlsRowVisible(const ATable: string; ACmd: Byte;
      const Row: TStrArray; const Names: TStrArray;
      const Types: TByteArray): Boolean;
    function RlsCheckRow(const ATable: string; ACmd: Byte;
      const Row: TStrArray; const Names: TStrArray;
      const Types: TByteArray): Boolean;
    procedure RlsRequireInsert(const ATable: string;
      const AColNames: array of string; const ARow: TStrArray);
    // R-03: ON CONFLICT DO UPDATE SET degerlerini hesaplar.
    //
    // DIKKAT: ifadeler MEVCUT SATIR kapsaminda degerlendirilir
    // ("cnt = cnt + 1" -> satirdaki cnt). "EXCLUDED.x" referanslari ise
    // eklenmek isteyen satirdan gelir ve EvalExpr icindeki
    // FExcludedRow/FExcludedColNames uzerinden cozulur.
    // Onceki yalniz FExcludedRow'a bakan kod "Kolon bulunamadi: cnt
    // (kapsam: [id, val])" hatasi veriyordu.
    procedure BuildUpsertSetValues(Stmt: TSqlInsertStmt;
      const ExcludedVals: TStrArray; const ExcludedCols, AllColNames: TStrArray;
      const Td: TTableDef; out SetValues: TSetValuePairs);
    // F-33: view sonucunun kolon tipleri. Kolon adi taban tablonun
    // kolonuyla eslesiyorsa o kolonun tipi, aksi halde VCT_STR.
    function ViewResultTypes(const ViewName: string;
      const Fields: TStrArray): TByteArray;
    procedure ExecCreateMaterializedView(Stmt: TSqlCreateMaterializedViewStmt;
      out Res: TSqlResult);
    procedure ExecCreateView(Stmt: TSqlCreateViewStmt; out Res: TSqlResult);
    procedure ExecDropMaterializedView(Stmt: TSqlDropMaterializedViewStmt; out
      Res: TSqlResult);
    procedure ExecDropView(Stmt: TSqlDropViewStmt; out Res: TSqlResult);
    procedure ExecRefreshMaterializedView(
      Stmt: TSqlRefreshMaterializedViewStmt; out Res: TSqlResult);
    function ScalarFuncCtype(fn: TSqlFuncCallNode): Byte;
    // P5-2/F-03: ic sorguyu calistirip sonucu dondurur. OuterRow verilirse
    // iliskili (correlated) alt sorgu: onbellek KULLANILMAZ.
    function SubResult(Sel: TSqlSelectStmt; const OuterRow: TStrArray = nil;
      const OuterColNames: TStrArray = nil): TSqlResult;
    // F-03: alt sorgu dis satira bagli mi? (kendi tablolari disinda nitelikli
    // referans varsa iliskilidir; o durumda sonuc onbelleklenmez.)
    function IsCorrelatedSel(Sel: TSqlSelectStmt): Boolean;
    // P5-CTE: WITH listesini sirayla materyallestirir.
    procedure MaterializeCtes(Stmt: TSqlSelectStmt);
    // P5-CTE: ad CTE ise satirlarini dondurur (yoksa False).
    function TryCte(const TableName: string; out Names: TStrArray;
      out Types: TByteArray; out Rows: TStrMatrix): Boolean;
    // P5-CTE: ic sorgu ciktisinin kolon tipleri (Taraf/kiyas icin).
    procedure CteColTypes(Sel: TSqlSelectStmt; const Fields: TStrArray;
      out Types: TByteArray);
    // ---------- R-10: GERCEK OZYINELEME + CYCLE ----------
    // Govde `anchor UNION ALL ozyinelemeli-terim` bicimindeyse iteratif
    // calistirilir. Eski yol (gövdeyi maxIter kez tekrarlama) sahte
    // sonuc uretiyordu ve ozyinelemeli terim hic calismiyordu.
    function CteIsRecursive(const W: TWithQuery): Boolean;
    procedure RunRecursiveCte(Stmt: TSqlSelectStmt; Idx: Integer);
    // P5-2: ic sorgunun dis tablolara basvurmadigini dogrular
    // (iliskili alt sorgu desteklenmez; sessiz yanlis sonuc yerine hata).
    procedure ValidateSubquery(Sel: TSqlSelectStmt);

    { ---------- Yardimcilar ---------- }
    function CurColCollation(ColIx: Integer): string;
    function ColCollation(Expr: TSqlExprNode; const ColNames: TStrArray): string;
    procedure BuildColInfo(const td: TTableDef; out ColNames: TStrArray;
      out ColTypes: TByteArray);
    { F1-17: kolon referansini konum listesinde cozer.
      JOIN'de kolonlar nitelemeli (alias.col) gelir; yalniz tam ad
      eslestirmesi typi VCT_STR'a dusurur ve '10' < '2' sonucu dogar.
      Nitelemesiz referanslar sonek eslestirmesiyle bulunur. }
    function FindColIdx(const ColumnName, TableQualifier: string;
      const ColNames: TStrArray): Integer;
    // function FindColIdx(const ColumnName: string;
    //   const Td: TTableDef): Integer; overload;
    // F-03: nitelikli referans ic kapsamda mi?
    function QualifierInScope(const Qualifier: string;
      const ColNames: TStrArray): Boolean;
    function FindColIdxInViewSelect(const ColumnName, TableQualifier: string;
      const SelectStmt: TSqlSelectStmt): Integer;
    function RowMatches(WhereClause: TSqlExprNode; const Row: TStrArray;
      const ColNames: TStrArray; const ColTypes: TByteArray): Boolean;
    procedure DoSort(var Rows: TStrMatrix; const Keys: TStrArray;
      OrderBy: TList<TOrderItem>;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      const MaxRows: Integer = -1);
    function HasAggregate(Stmt: TSqlSelectStmt): Boolean;
    // F-09: QUALIFY ifadesini degerlendirir; pencere fonksiyonu
    // cagrilari WinVals[RowIx][WinSlot[j]] uzerinden cozulur.
    function EvalQualify(Expr: TSqlExprNode; const Row: TStrArray;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      const WinVals: TStrMatrix; const WinSlot: TIntArray;
      RowIx: Integer): Boolean;
    // F-09: iki AST ifadesi yapisal ayni mi? (QUALIFY pencere eslesmesi)
    function IsSameExpr(A, B: TSqlExprNode): Boolean;
    // F-09: QUALIFY filtresini uygular (pencere degerleriyle birlikte)
    procedure ApplyQualify(Stmt: TSqlSelectStmt; var Rows: TStrMatrix;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      var WinVals: TStrMatrix; const WinSlot: TIntArray);
    // F-33: View kolon adlarini base kolon adlarina cevirir (AST'yi kopyalayarak)
    function TransformViewColsToBase(Expr: TSqlExprNode;
      const ColMap: TStrArray): TSqlExprNode;
    // P5-WIN: SELECT listesinde pencere fonksiyonu var mi (ic ice dahil).
    function HasWindow(Stmt: TSqlSelectStmt): Boolean;
    // P5-WIN: pencere yerlesim kurali (yalniz ust-duzey SELECT ogesi;
    // WHERE/HAVING/ORDER BY/JOIN-ON ve ic ice kullanim yasaktir).
    procedure CheckWindowPlacement(Stmt: TSqlSelectStmt);

    // F-33: VIEW INSERT/UPDATE/DELETE — gorunumu analiz eder ve
    // guncellenebilir mi, temel tablo ve kolon eslemesi dondurur.
    // Updatable view kriterleri (SQL standardi yakinligi):
    // - Tek temel tablo (FROM, JOIN yok, SET OP yok)
    // - DISTINCT, GROUP BY, HAVING, aggregate yok
    // - Sadece basit kolon referanslari (ifadeler/alias yok)
    // - WHERE/OrderBy/Limit/Offset DML icin goz ardi edilebilir
    function AnalyzeViewUpdatable(const ViewName: string;
      out BaseTable: string; out ColMap: TStrArray): Boolean;
    // F-33: view SELECT'ten view kolon adlari -> base kolon adlari haritasi
    procedure BuildViewColMap(const ViewSelect: TSqlSelectStmt;
      out ColMap: TStrArray);
    { ---------- Satir adaylarini DARALTMA (tam tarama oncesi) ----------
      WHERE AST'sinden PK nokta aramasi veya indeks dilimi cikarir.
      False donerse cagri tam tarama yapar.
      DONUMLERIN TAMAMI RowMatches ile yeniden dogrulanir; dilim yalnizca
      UST KUMEDIR, bu yuzden sonuc hicbir kosulda degismez. }
    function NarrowRows(const Td: TTableDef; WhereClause: TSqlExprNode;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Pks: TStrArray; out Rows: TStrMatrix;
      out IsExact: Boolean): Boolean; overload;
    function NarrowRows(const Td: TTableDef; WhereClause: TSqlExprNode;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Pks: TStrArray; out Rows: TStrMatrix): Boolean; overload;
    { H3: Saf COUNT(*) + indekslenebilir WHERE. Satirlari okumadan, indeks
      dilimindeki girdi sayisini dondurur. WHERE'in tamami dilimle
      temsil edilemiyorsa False -> genel yol. }
    function TryIndexCount(const Td: TTableDef; Stmt: TSqlSelectStmt;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Cnt: Int64): Boolean;
    { H17: Saf COUNT(*) + WHERE -> ham akistan tek pass. WHERE'in
      referans verdigi kolonlar satir basina yalniz bir kez cozulur; tum
      satir matrisi kurulmaz. Alt sorgu/pencere/aggregate iceren WHERE
      genel yola birakilir. Sekil uymazsa False. }
    function TryStreamFilteredCount(Stmt: TSqlSelectStmt;
      const td: TTableDef; const ColNames: TStrArray;
      const ColTypes: TByteArray; out Res: TSqlResult): Boolean;
    { R-13 Full: WHERE'den bolme hedef kumesini cikarir (partition
      pruning). Guvenlik: yalniz AND'lenen ve anlasilabilen kosullar
      (bolme kolonunda '=' ya da IN, literal degerlerle) katki verir;
      OR / belirsiz kosul -> filtre yok (tum satirlar taranir). Donen
      kume UST KUME degildir AMA her hedef disi satir WHERE tarafindan
      da elenmis olur: k = literal kosulu satirin bolme kolon degerini
      sabitler, o deger baska bolume dusemez. }
    function PartTargetsOf(const Td: TTableDef;
      WhereClause: TSqlExprNode): TPartTargets;
    { R-13 Full: SHOW PARTITIONS t yurutmesi. }
    procedure ExecShowPartitions(Stmt: TSqlAdminStmt; out Res: TSqlResult);
    { R-24 (2026-10-13): SHOW STATS / SHOW STATS TABLE t yurutmesi. }
    procedure ExecShowStats(Stmt: TSqlAdminStmt; out Res: TSqlResult);
    { ORDER BY tek kolon ve bu kolon indeksliyse, satirlar INDeks sirasiyla
      okunur; OFFSET/LIMIT erken uygulanir. "ORDER BY n LIMIT 10" 100.000
      satirlik tabloda ~900 ms yerine ~0 ms surer.
      False donerse normal (tam tarama + siralama) yol kullanilir. }
    function TryIndexOrder(const Td: TTableDef; Stmt: TSqlSelectStmt;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Rows: TStrMatrix): Boolean;
    procedure ExecGroupBy(Stmt: TSqlSelectStmt; const AllPks: TStrArray;
      const AllRows: TStrMatrix; const ColNames: TStrArray;
      const ColTypes: TByteArray; out Res: TSqlResult;
      out OutTypes: TByteArray; AlreadyFiltered: Boolean = False);
    { P-12 (2026-10-16): WHERE/GROUP BY/HAVING/JOIN/ORDER/LIMIT OLMAYAN
      tek tablo agregalarini (COUNT(*), COUNT(k), SUM/AVG/MIN/MAX(k))
      HAM kayit uzerinde tek passede hesaplar; satirlar string matrisine
      cevrilmez (COUNT/SUM ~100x hizlanir). Semantiği EvalAggregateValue
      ile birebir ayni. Sorgu sekli veya kayit bicimi (eski sema, NaN...)
      tam uymazsa False -> genel yol AYNEN calisir (bozuk kayit hatasi
      dahil davranis degismez). }
    function TryStreamAgg(Stmt: TSqlSelectStmt; const td: TTableDef;
      out Res: TSqlResult): Boolean;
    { H13 (2026-10-21): GROUP BY + basit aggregate'leri ham akistan tek
      passede hesaplar. Tum satirlar string matrisine cevrilmez; her grup
      icin yalniz anahtar + sayaclar tutulur. Sekil uymazsa False -> genel
      ExecGroupBy yolu AYNEN calisir. }
    function TryStreamGroupBy(Stmt: TSqlSelectStmt; const td: TTableDef;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Res: TSqlResult; out OutTypes: TByteArray): Boolean;
    { H1 (2026-10-18): Indekssiz tek-tablo LIMIT'li SELECT'te satirlari HAM
      akistan okuyup LIMIT kadar eslesen bulunca DURUR (tum tabloyu cozmez).
      Sekil/guvenlik uymazsa False -> genel yol AYNEN calisir. }
    function TryStreamSelect(Stmt: TSqlSelectStmt; const td: TTableDef;
      out Res: TSqlResult): Boolean;
    { H16: tek kolonlu SELECT DISTINCT ... [ORDER BY ayni kolon] sorgusunu
      ham akistan tek pass'te tekillestirir. Tum satir matrisi kurulmaz;
      yalniz secilen kolon cozulur. Sekil uymazsa False -> genel yol. }
    function TryStreamDistinct(Stmt: TSqlSelectStmt; const td: TTableDef;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Res: TSqlResult): Boolean;
    { H12: ORDER BY ... LIMIT icin tek tabloyu ham akistan okur; yalniz
      en iyi K = LIMIT + OFFSET satiri tutar. WHERE varsa satir yine
      RowMatches ile dogrulanir. Sekil uymazsa False -> genel yol. }
    function TryStreamOrderLimit(Stmt: TSqlSelectStmt; const td: TTableDef;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
    { H12c (2026-10-21): cok kolonlu ORDER BY ... LIMIT icin ayni ham akisli
      top-N yolu. Karma yon (ASC/DESC), farkli tipler ve NULLS konumlari
      desteklenir; ifade anahtarlari genel yola birakilir. }
    function TryStreamOrderMultiLimit(Stmt: TSqlSelectStmt; const td: TTableDef;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
    { M5: WHERE icindeki TS_MATCH(col, 'sorgu') conjunct'larini inverted
      index ile daraltir. Semantik degismez: WHERE sonradan aynen uygulanir. }
    function TryFtsNarrow(Stmt: TSqlSelectStmt; const td: TTableDef;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
    { M4: ORDER BY VECTOR_DISTANCE(kolon, sabit) LIMIT k olan tek tablo
      sorgusunda HNSW indeksinden k aday getirir. Sonuc kumesi normal
      WHERE/ORDER BY/LIMIT hattindan gecer; indeks yalnizca aday daraltir.
      Semantik yaklasiktir (ANN); WHERE/JOIN/CTE/agregasyon varsa kullanilmaz. }
    function TryVectorNarrow(Stmt: TSqlSelectStmt; const td: TTableDef;
      const ColNames: TStrArray; const ColTypes: TByteArray;
      out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
    procedure ExecJoinScan(Stmt: TSqlSelectStmt; out MergedRows: TStrMatrix;
      out MergedColNames: TStrArray; out MergedColTypes: TByteArray);
    { P5-WIN: pencere kolonlarini satirlarla ayni sirada hesaplar.
      WinVals[i][s] = i'nci satirin s'nci pencere degeri;
      WinSlot[j] = j'nci cikti kolonunun penceresi (degilse -1).
      Sorgu ORDER BY'sinden SONRA, projeksiyondan ONCE cagrilir. }
    procedure ComputeWindows(Stmt: TSqlSelectStmt;
      const Rows: TStrMatrix; const ColNames: TStrArray;
      const ColTypes: TByteArray; out WinVals: TStrMatrix;
      out WinSlot: TIntArray);

    { AS OF (2026-10-06): FROM tablosunun WAL gecmisindeki satir kumesini
      kurar (N = min(AsOfValue, WalRecordCount-1)). Pencere icinde hic
      gormeyen anahtar "degismedi" sayilir; pencere sonrasi eklenenler
      N'de gorunmez; pencere icinde silinenler N'deki son PUT degeriyle
      geri gelir. Pencere bossa ecUnsupported (gecmis yok). }
    procedure BuildAsOfRows(Stmt: TSqlSelectStmt; Td: TTableDef;
      const ColNames: TStrArray; out Pks: TStrArray; out Rows: TStrMatrix);

    { ---------- Statement Handlers ---------- }
    procedure ExecSelect(Stmt: TSqlSelectStmt; out Res: TSqlResult);
    procedure ExecInsert(Stmt: TSqlInsertStmt; out Res: TSqlResult);
    procedure ExecUpdate(Stmt: TSqlUpdateStmt; out Res: TSqlResult);
    procedure ExecDelete(Stmt: TSqlDeleteStmt; out Res: TSqlResult);
    procedure ExecCreateTable(Stmt: TSqlCreateTableStmt; out Res: TSqlResult);
    procedure ExecAlterTable(Stmt: TSqlAlterTableStmt; out Res: TSqlResult);
    procedure ExecDropTable(Stmt: TSqlDropTableStmt; out Res: TSqlResult);
    procedure ExecCreateIndex(Stmt: TSqlCreateIndexStmt; out Res: TSqlResult);
    procedure ExecDropIndex(Stmt: TSqlDropIndexStmt; out Res: TSqlResult);
    procedure ExecTx(Stmt: TSqlTxStmt; out Res: TSqlResult);
    procedure ExecAdmin(Stmt: TSqlAdminStmt; out Res: TSqlResult);
    // F-20: EXPLAIN â€” plan satirlarini uretir
    procedure ExecExplain(Stmt: TSqlExplainStmt; out Res: TSqlResult);
    // R-15: Cost-Based Optimizer â€” ANALYZE
    procedure ExecAnalyze(const Stmt: TSqlAdminStmt; out Res: TSqlResult);
    // F-20 yardimcilari
    function BinaryOpName(Op: TSqlBinaryOp): string;
    function DescribeExpr(E: TSqlExprNode): string;
    function TryCteOk(const TableName: string): Boolean;
    function IndexUsedByWhere(const Td: TTableDef; const Where: TSqlExprNode;
      out IdxName: string): Boolean;
    procedure ExecJson(Stmt: TSqlJsonStmt; out Res: TSqlResult);
    // R-10: SET OP (UNION [ALL] / EXCEPT / INTERSECT) birlestirmesi.
    procedure MergeSetOpRows(Stmt: TSqlSelectStmt; var Rows: TStrMatrix;
      const Cols: TStrArray);
    // R-11: SET CONSTRAINTS [ALL] DEFERRED | IMMEDIATE
    procedure ExecSetConstraints(Stmt: TSqlSetConstraintsStmt; out Res: TSqlResult);
    // F-40: SET TRANSACTION ISOLATION LEVEL ...
    procedure ExecSetIsolation(Stmt: TSqlSetIsolationStmt; out Res: TSqlResult);
    // F-41: SELECT ... FOR UPDATE satirlarini kilitler.
    procedure LockSelectRows(Stmt: TSqlSelectStmt);
    // R-18: RBAC
    procedure ExecRole(Stmt: TRoleStmt; out Res: TSqlResult);
    procedure ExecGrant(Stmt: TGrantStmt; out Res: TSqlResult);
    procedure ExecSetRole(Stmt: TSetRoleStmt; out Res: TSqlResult);
    procedure ExecPolicy(Stmt: TPolicyStmt; out Res: TSqlResult);   // R-19
    // R-04: RETURNING - ifadeleri degerlendir ve sonuc dondur
    function EvaluateReturning(const Stmt: TSqlStmtNode;
      const Row: TStrArray; const ColNames: TStrArray;
      const ColTypes: TByteArray): TStrArray;
    // R-04: RETURNING listesinde DUZ KOLON disinda gercek ifade var mi?
    // Parser duz kolonlari hem Cols'a hem Exprs'e yazar; bu yuzden
    // Exprs.Count > 0 tek basina "ifade var" demek DEGILDIR. Sadece
    // kolon referansi olmayan ogeler sayilir:
    //   UPDATE t SET cnt=1 RETURNING cnt + 1
    // Parser su an bu cumlede Exprs'e 2 ogE koyar ve ifade HICBIR
    // degerlendirilmeden ilk kolonun degeri dondurulurdu.
    function ReturningHasExpr(Stmt: TSqlStmtNode): Boolean;
    // RETURNING basligini (alan adlari) ifadelere gore kurar.
    procedure BuildReturningNames(Stmt: TSqlStmtNode; out Names: TStrArray);
    // R-04: RETURNING satirini kurar. Ifade yoksa FALSE doner (cagiran
    // kendi kolon-indeks yolunu kullanir); varsa TRUE doner ve Row
    // EvaluateReturning ile doldurulur.
    function MakeReturningRow(Stmt: TSqlStmtNode; Row: TStrArray;
      const AllColNames: TStrArray; const AllColTypes: TByteArray;
      out Ret: TStrArray): Boolean;
  public
    constructor Create(ATableDb: TVTableDb);
    destructor Destroy; override;
    function Execute(Stmt: TSqlStmtNode): TSqlResult;
    property TableDb: TVTableDb read FT;
    // F-40/F-41: TVSql tarafindan atanan oturum kimligi ve yalitim.
    property SessionId: Cardinal read FSessionId write FSessionId;
    property Isolation: TIsolationLevel read FIsolation write FIsolation;
    { F-35: FUNCTION/PROCEDURE govdesi bu executor ile calistirilir.
      Parametre degerleri FOuterRow/FOuterColNames uzerinden gecer.
      VDbTable'daki ExecuteFunctionFor/CallProcedureFor bunlari
      PRIVATE alanlara erisemedigi icin ("no member FOuterRow")
      disaridan yazilabilir property'ye cevrildi. }
    property OuterRow: TStrArray read FOuterRow write FOuterRow;
    property OuterColNames: TStrArray read FOuterColNames write FOuterColNames;
    property CurQualifier: string read FCurQualifier write FCurQualifier;
    { F-36: trigger WHEN kosulu bu metotla degerlendirilir
      (EvalExpr private; VDbTable'dan cagrilamaz). }
    function EvalExprFor(Expr: TSqlExprNode; const Row: TStrArray): string;
    { P-18c (2026-10-16): LITERAL INSERT hizli seridi. Yalniz birebir
      `INSERT INTO t (a,b,...) VALUES (<literal>,...)` bicimini tanir
      (literaller: kanonik tamsayi, tek tirnakli string, NULL, TRUE,
      FALSE; kolon listesi opsiyonel). En ufak sapmada (yorum, param,
      fonksiyon, float, ON CONFLICT, RETURNING, cok satir, tirnakli
      tanimlayici, tablo yok, VIEW, INSERT tetikleyicisi, kolon/deger
      sayi farki) False doner ve GENEL YOL AYNEN calisir — davranis
      garantisi buradan gelir. Kabul yolunda genel yolun sarmalama
      dizisi birebir uygulanir: RequirePriv -> RlsRequireInsert ->
      FT.Insert (PK/UNIQUE/NOT NULL/CHECK/AutoInc tablo katmaninda);
      hata istisnalari ayni sirada ayni noktalardan firlar. }
    function ExecFastLiteralInsert(const Sql: string;
      out Res: TSqlResult): Boolean;
    { H13 (2026-10-19): COPY dosya akisi.
        COPY <tablo> [(kolon,...)] FROM '<yol>' [WITH] [(] [FORMAT CSV|TEXT|ARROW]
                    [, HEADER] [, DELIMITER 'x'] [, NULL 'x'] [, QUOTE 'x'] [)]
        COPY <tablo> [(kolon,...)] TO '<yol>' [WITH] [(] FORMAT ARROW [)]
      Tum satirlar TEK batch icinde yazilir (atomik); batch zaten aciksa
      (BEGIN / cok cumleli otomatik batch) ona eklenir, kapatilmaz.
      CSV: RFC4180 tirnaklari ("") ve tirnak icinde satir sonu desteklenir.
      TEXT: PostgreSQL benzeri; varsayilan ayirici TAB, NULL '\\N'.
      ARROW (M2): Arrow IPC stream; dis bagimlilik yok, tip eslemesi
      INT/DATE/DATETIME/TIME dahil skaler alanlarla sinirlidir.
      Kok neden: her satir icin INSERT cumlesi ayristirmak/calistirmak
      yerine tek gecisli dosya okuma + FT.Insert batch yolu. }
    function ExecFastCopy(const Sql: string;
      out Res: TSqlResult): Boolean;
    { P-23 (2026-10-17): Tekil PK nokta sorgusu icin hizli serit (SELECT <cols> FROM <table> WHERE <pk> = <val>).
      AST Parser/Executor olusturma yukunu atlayarak dogrudan TVTableDb.ReadRow uzerinden calisir. }
    function ExecFastPointSelect(const Sql: string;
      out Res: TSqlResult): Boolean;
  end;

implementation

type
  { FPC'de TList<TList<T>> desteklenmedigi icin yardimci alt sinif }
  TIntList = class(TList<Integer>)
  end;
  TIntListList = TList<TIntList>;

{ ============================================================
  Hata yardimcisi: "Kolon bulunamadi" — mevcut kapsamla birlikte.
  Hatayi ayiklamak icin: referans verilen ad kapsamda GORUNMUYORSA
  liste, LATERAL/alt sorgu birlesimlerinde "hangi kolonlar var" sorusunu
  tek bakista yanitlar.
  ============================================================ }
procedure RaiseEVDbColumnNotFound(const RefName: string;
  const ColNames: TStrArray);
var
  i: Integer;
  s: string;
begin
  s := '';
  for i := 0 to High(ColNames) do
  begin
    if s <> '' then s := s + ', ';
    s := s + ColNames[i];
    if Length(s) > 400 then
    begin
      s := s + ', ...';
      Break;
    end;
  end;
  raise EVDbException.Create(ecColumnNotFound,
    'Kolon bulunamadi: ' + RefName + ' (kapsam: [' + s + '])');
end;

{ ============================================================
  Yardimci: string dizisi esit mi?
  ============================================================ }
function RowEncodeKey(const Row: TStrArray): string;
// F2-18: Satiri tekilleÅŸtirme icin UZUNLUK-ONEKI kodlanmis anahtara
// cevirir. Her deger "len:deger" seklinde yazilir; boylece degerin
// icindeki ayirici (#1) belirsizlik yaratmaz.
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Row) do
    Result := Result + IntToStr(Length(Row[i])) + ':' + Row[i] + VDB_ROWKEY_SEP;
end;

function SameStrArr(const A, B: TStrArray): Boolean;
var i: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for i := 0 to High(A) do
    if A[i] <> B[i] then Exit(False);
  Result := True;
end;

{ ============================================================
  TVSqlExecutor
  ============================================================ }

constructor TVSqlExecutor.Create(ATableDb: TVTableDb);
begin
  inherited Create;
  FT := ATableDb;
  FIsolation := ilRepeatableRead;   // F-40: mevcut snapshot davranisi
  FSessionId := 0;
  FZoneMaps := TDictionary<Integer, TVDbZoneMap>.Create;
  FFtsIndexes := TDictionary<string, TVdbFtsIndex>.Create;
  FFtsSeqs := TDictionary<string, QWord>.Create;
  FVecIndexes := TDictionary<string, TVdbVectorIndex>.Create;
  FVecSeqs := TDictionary<string, QWord>.Create;
end;

destructor TVSqlExecutor.Destroy;
var
  m: TVDbZoneMap;
  f: TVdbFtsIndex;
  v: TVdbVectorIndex;
begin
  if FZoneMaps <> nil then
  begin
    for m in FZoneMaps.Values do m.Free;
    FreeAndNil(FZoneMaps);
  end;
  if FFtsIndexes <> nil then
  begin
    for f in FFtsIndexes.Values do f.Free;
    FreeAndNil(FFtsIndexes);
  end;
  FreeAndNil(FFtsSeqs);
  if FVecIndexes <> nil then
  begin
    for v in FVecIndexes.Values do v.Free;
    FreeAndNil(FVecIndexes);
  end;
  FreeAndNil(FVecSeqs);
  inherited Destroy;
end;

{ ---------------- H3: zone map ---------------- }

constructor TVDbZoneMap.Create(ASeq, AEpoch: QWord; ABucketCount: Integer;
  const ACols: array of Integer; const AIsFloat: array of Boolean);
var
  i, n: Integer;
begin
  inherited Create;
  GenSeq := ASeq;
  GenEpoch := AEpoch;
  BucketCount := ABucketCount;
  if BucketCount < 1 then BucketCount := 1;
  SetLength(ColIds, Length(ACols));
  SetLength(ColFloat, Length(ACols));
  SetLength(ColUsable, Length(ACols));
  for i := 0 to High(ACols) do
  begin
    ColIds[i] := ACols[i];
    ColFloat[i] := AIsFloat[i];
    ColUsable[i] := True;
  end;
  n := BucketCount * Length(ColIds);
  SetLength(MinI, n); SetLength(MaxI, n);
  SetLength(MinF, n); SetLength(MaxF, n);
  SetLength(HasVal, n);
  for i := 0 to n - 1 do
  begin
    MinI[i] := High(Int64); MaxI[i] := Low(Int64);
    MinF[i] := 0; MaxF[i] := 0;
    HasVal[i] := 0;
  end;
  SetLength(Complete, BucketCount);
  for i := 0 to BucketCount - 1 do Complete[i] := 0;
end;

function TVDbZoneMap.FindCol(ACol: Integer): Integer;
var i: Integer;
begin
  for i := 0 to High(ColIds) do
    if ColIds[i] = ACol then Exit(i);
  Result := -1;
end;

function TVSqlExecutor.CurColCollation(ColIx: Integer): string;
{ R-20: aktif tabloda ColIx'inci kolonun varsayilan collation'i.
  `ad TEXT COLLATE tr` ile tanimlanmis kolonlarda ORDER BY acik COLLATE
  yazmadan da o collation ile siralanir. }
var
  td: TTableDef;
begin
  Result := '';
  if (FCurTable = '') or (ColIx < 0) then Exit;
  if not FT.TableExists(FCurTable) then Exit;
  td := FT.GetTable(FCurTable);
  if ColIx > High(td.Cols) then Exit;
  Result := td.Cols[ColIx].Collate;
end;

{ ------------------------------------------------------------
  BuildColInfo
  //---------------------------------------------------------- }
function TVSqlExecutor.ColCollation(Expr: TSqlExprNode;
  const ColNames: TStrArray): string;
{ R-20: ifade bir kolon referansi ise ve o kolonun varsayilan collation'i
  varsa dondurur; degilse bos string (motor varsayilani). }
var
  cr: TSqlColumnRefNode;
  td: TTableDef;
  nm: string;
  j, ci: Integer;
begin
  Result := '';
  if (Expr = nil) or (FCurTable = '') then Exit;
  if not (Expr is TSqlColumnRefNode) then Exit;
  cr := TSqlColumnRefNode(Expr);
  if not FT.TableExists(FCurTable) then Exit;
  td := FT.GetTable(FCurTable);
  nm := VDbNorm(cr.ColumnName);
  for j := 0 to High(td.Cols) do
    if VDbNorm(td.Cols[j].Name) = nm then
    begin
      Result := td.Cols[j].Collate;
      Exit;
    end;
  // Kolon bulunamadiysa ColNames uzerinden tekrar dene (niteliikli yazim)
  ci := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
  if ci < 0 then Exit;
end;

procedure TVSqlExecutor.BuildColInfo(const td: TTableDef;
  out ColNames: TStrArray; out ColTypes: TByteArray);
var i: Integer;
begin
  SetLength(ColNames, Length(td.Cols));
  SetLength(ColTypes, Length(td.Cols));
  for i := 0 to High(td.Cols) do
  begin
    ColNames[i] := td.Cols[i].Name;
    ColTypes[i] := td.Cols[i].Ctype;
  end;
end;

function TVSqlExecutor.FindColIdx(const ColumnName, TableQualifier: string;
  const ColNames: TStrArray): Integer;
var
  i, dp: Integer;
begin
  // 1. Tam eslesme (nitelemeli veya nitelememisiz)
  for i := 0 to High(ColNames) do
    if SameText(ColNames[i], ColumnName) or
       ((TableQualifier <> '') and SameText(ColNames[i], TableQualifier + '.' + ColumnName)) then
      Exit(i);
  // 2. Nitelemesiz referans -> sonek eslestirmesi (ad -> alias.ad)
  if TableQualifier = '' then
    for i := 0 to High(ColNames) do
    begin
      dp := Pos('.', ColNames[i]);
      if (dp > 0) and
         SameText(Copy(ColNames[i], dp + 1, MaxInt), ColumnName) then
        Exit(i);
    end;
  Result := -1;
end;

function TVSqlExecutor.FindColIdxInViewSelect(const ColumnName, TableQualifier: string;
  const SelectStmt: TSqlSelectStmt): Integer;
// View SELECT'inde kolon indeksini bulur (alias veya kolon adi)
var
  i: Integer;
  item: TSelectColumnItem;
  cr: TSqlColumnRefNode;
begin
  Result := -1;
  for i := 0 to SelectStmt.Columns.Count - 1 do
  begin
    item := SelectStmt.Columns[i];
    // Alias kontrolu
    if (item.Alias <> '') and SameText(item.Alias, ColumnName) then
    begin
      if (TableQualifier = '') or SameText(TableQualifier, item.Alias) then
        Exit(i);
    end;
    // Kolon adi kontrolu
    if item.Expr is TSqlColumnRefNode then
    begin
      cr := TSqlColumnRefNode(item.Expr);
      if SameText(cr.ColumnName, ColumnName) then
      begin
        if (TableQualifier = '') or SameText(TableQualifier, cr.TableQualifier) then
          Exit(i);
      end;
    end;
  end;
  Result := -1;
end;

{ ------------------------------------------------------------
  QualifierInScope (F-03)
  Nitelikli referans (a.x) ic kapsamda mi? ColNames'ler
  'alias.kolon' seklinde oldugunda kontrol edilir. Tek-tablo
  yolunda ColNames niteliksiz oldugu icin nitelikli referans
  ic kapsamda sayilmaz -> dis kapsama bakilir.
  //---------------------------------------------------------- }
function TVSqlExecutor.QualifierInScope(const Qualifier: string;
  const ColNames: TStrArray): Boolean;
var
  i: Integer;
begin
  // Nitelikli kolon adlarinda alias eslesmesi (JOIN yolu).
  for i := 0 to High(ColNames) do
    if SameText(Qualifier, Copy(ColNames[i], 1, Pos('.', ColNames[i]) - 1)) then
      Exit(True);
  // Tek-tablo yolunda ColNames niteliksizdir; ic sorgunun kendi
  // tablosu/alias'i FCurQualifier ile bilinir.
  if (FCurQualifier <> '') and SameText(Qualifier, FCurQualifier) then
    Exit(True);
  Result := False;
end;

{ ------------------------------------------------------------
  EvalBinary
  //---------------------------------------------------------- }
{ ------------------------------------------------------------
  ParseBothRanges
  Iki tarafi da aralik olarak ayristirir. Birkisi de aralik DEGILSE veya
  yazim bozuksa FALSE doner; cagiran UNKNOWN ('') uretir.
  DIKKAT: ayristirma basarisiz olsa da cikti atanir — FPC'de 'out'
  parametresi yazmazsa geriye donuk deger kalir ve sonraki operator
  tanimlanmamis bir TRangeBound kullanabilirdi.
  //---------------------------------------------------------- }
function ParseBothRanges(const L, R: string; out A, B: TRangeBound): Boolean;
begin
  A.Lo := ''; A.Hi := ''; A.LoIncl := False; A.HiIncl := False; A.Valid := False;
  B.Lo := ''; B.Hi := ''; B.LoIncl := False; B.HiIncl := False; B.Valid := False;
  if not VDbParseRange(L, A) then Exit(False);
  if not VDbParseRange(R, B) then Exit(False);
  Result := True;
end;

{ ------------------------------------------------------------
  EvalRangeCtor
  RANGE(alt, ust [, '[]'|'[)'|'(]'|'()']) kurucusu. Parser argumanlari
  '~' ile birlestirip tek metin olarak verir.
  '*' her iki yonu da sonsuz yapar ve kanonik bicimde '*' olarak gosterilir.
  //---------------------------------------------------------- }
function EvalRangeCtor(const Raw: string): string;
var
  parts: TStrArray;
  lo, hi, br: string;
  i, n: Integer;
  cur: string;
begin
  // '~' ile bol
  SetLength(parts, 0);
  n := 0;
  cur := '';
  for i := 1 to Length(Raw) do
  begin
    if Raw[i] = '~' then
    begin
      SetLength(parts, n + 1);
      parts[n] := cur;
      Inc(n);
      cur := '';
    end
    else
      cur := cur + Raw[i];
  end;
  SetLength(parts, n + 1);
  parts[n] := cur;
  if Length(parts) < 2 then Exit('');
  lo := parts[0];
  hi := parts[1];
  br := '[]';
  if Length(parts) >= 3 then br := parts[2];
  // FPC 3.2.4'te 'not in [...]' yok.
  if (Length(br) <> 2) or (not (br[1] in ['[', '('])) or
     (not (br[2] in [']', ')'])) then Exit('');
  if lo = '*' then lo := '';
  if hi = '*' then hi := '';
  // Sonsuz uclar '*' olarak yazilir.
  if lo = '' then lo := '*';
  if hi = '' then hi := '*';
  Result := br[1] + lo + '..' + hi + br[2];
end;

function TVSqlExecutor.EvalBinary(AOp: TSqlBinaryOp; const LeftVal, RightVal: string;
  Ctype: Byte): string;
var
  ia, ib: Int64;
  fa, fb, fc, fd, fe, fg: Double;
  bRes: Boolean;
  RA, RB: TRangeBound;
  cl: TVDbLang;
  cc: Integer;
  la, lb: Integer;

  { SQL uc-degerli mantik: -1 = FALSE, 0 = UNKNOWN (NULL), +1 = TRUE. }
  function BoolTri(const V: string): Integer;
  begin
    if V = '' then Exit(0);
    if SameText(V, 'True') or (V = '1') then Exit(1);
    Result := -1;
  end;

  { R-20: metin karsilastirmasinda kolonun varsayilan collation'i
    uygulanir. Acik COLLATE yoksa VDbCmpVal'in varsayilan (bayt/duyarli)
    davranisi korunur. }
  function ColCmp(const A, B: string; CT: Byte; const Op: string): Boolean;
  begin
    if (CT <> VCT_STR) or (FCurCollation = '') then
      Exit(VDbCmpVal(A, B, Op, CT));
    if not VDbLangProfile(FCurCollation, cl) then
      Exit(VDbCmpVal(A, B, Op, CT));
    cc := VDbCompareCol(A, B, cl);
    if Op = '=' then Result := cc = 0
    else if Op = '<>' then Result := cc <> 0
    else if Op = '<' then Result := cc < 0
    else if Op = '<=' then Result := cc <= 0
    else if Op = '>' then Result := cc > 0
    else Result := cc >= 0;
  end;

begin
  // F1-14: SQL'de NULL ile hicbir KARSILASTIRMA operatoru eslesmez; sonuc
  // UNKNOWN ('') olur. Once 'False' donuyordu, bu yuzden NOT (NULL = 1)
  // -> True oluyor ve NULL satirlari WHERE filtresine giriyordu.
  // (sboEq..sboLike araligi = =, <>, <, <=, >, >=, LIKE; sboILike ayrica)
  // Aritmetik operatorler zaten kendi NULL kontrolunu yapiyor.
  if (((AOp >= sboEq) and (AOp <= sboLike)) or (AOp = sboILike) or
     (AOp = sboJsonContains) or (AOp = sboJsonContained) or
     (AOp = sboJsonHasKey) or (AOp >= sboRangeOverlap)) and
     ((LeftVal = '') or (RightVal = '')) then Exit('');
  case AOp of
    sboAdd, sboSub, sboMul, sboDiv, sboMod:
      begin
        if (LeftVal = '') or (RightVal = '') then Exit('');
        if (Ctype = VCT_FLOAT) or (Pos('.', LeftVal) > 0) or (Pos('.', RightVal) > 0) then
        begin
          if not VDbParseFloat(LeftVal, fa) or not VDbParseFloat(RightVal, fb) then Exit('');
          case AOp of
            sboAdd: Exit(VDbFloatToStr(fa + fb));
            sboSub: Exit(VDbFloatToStr(fa - fb));
            sboMul: Exit(VDbFloatToStr(fa * fb));
            sboDiv:
              begin
                if fb = 0.0 then raise EVDbException.Create(ecMathError, 'Sifira bolme hatasi');
                Exit(VDbFloatToStr(fa / fb));
              end;
            sboMod: raise EVDbException.Create(ecMathError, 'FLOAT tipte modulo kullanilamaz');
          end;
        end
        else
        begin
          if not VDbParseInt(LeftVal, ia) or not VDbParseInt(RightVal, ib) then Exit('');
          case AOp of
            sboAdd: Exit(IntToStr(ia + ib));
            sboSub: Exit(IntToStr(ia - ib));
            sboMul: Exit(IntToStr(ia * ib));
            sboDiv:
              begin
                if ib = 0 then raise EVDbException.Create(ecMathError, 'Sifira bolme hatasi');
                Exit(IntToStr(ia div ib));
              end;
            sboMod:
              begin
                if ib = 0 then raise EVDbException.Create(ecMathError, 'Sifira bolme hatasi');
                Exit(IntToStr(ia mod ib));
              end;
          end;
        end;
      end;
    sboAnd:
      begin
        // SQL 3VL: FALSE AND UNKNOWN = FALSE, TRUE AND UNKNOWN = UNKNOWN.
        // UNKNOWN'i burada 'False'e indirgersek NOT (unknown AND ...) yanlis
        // True olur ve NULL satirlari filtreye girer.
        la := BoolTri(LeftVal);
        lb := BoolTri(RightVal);
        if (la = -1) or (lb = -1) then Exit('False');
        if (la = 0) or (lb = 0) then Exit('');
        Exit('True');
      end;
    sboOr:
      begin
        // SQL 3VL: TRUE OR UNKNOWN = TRUE, FALSE OR UNKNOWN = UNKNOWN.
        la := BoolTri(LeftVal);
        lb := BoolTri(RightVal);
        if (la = 1) or (lb = 1) then Exit('True');
        if (la = 0) or (lb = 0) then Exit('');
        Exit('False');
      end;
    sboConcat:
      // || string birlestirme (SQL standardi)
      Exit(LeftVal + RightVal);
    sboEq:   bRes := ColCmp(LeftVal, RightVal, Ctype, '=');
    sboNeq:  bRes := ColCmp(LeftVal, RightVal, Ctype, '<>');
    sboLt:   bRes := ColCmp(LeftVal, RightVal, Ctype, '<');
    sboLte:  bRes := ColCmp(LeftVal, RightVal, Ctype, '<=');
    sboGt:   bRes := ColCmp(LeftVal, RightVal, Ctype, '>');
    sboGte:  bRes := ColCmp(LeftVal, RightVal, Ctype, '>=');
    sboLike: bRes := VDbLikeMatch(LeftVal, RightVal);
    // F-05: ILIKE â€” iki taraf da Turkce duyarli kucuk harfe indirilir.
    // VDbLikeMatch zaten '%' ve '_' jokerlerini destekler.
    sboILike: bRes := VDbLikeMatch(VDbTrLower(LeftVal), VDbTrLower(RightVal));
    // ---- F-22: JSONB operatorleri ----
    // Metin karsilastirmasi degil, JSON YAPISAL karsilastirmasi.
    // '@>' / '<@' iki kime de ait: JSONB kapsama ve RANGE kapsama. Ayrim
    // TIK (tanim) tarafindan yapilir: her iki taraf da aralik metni
    // ('[', '(' ile baslayan) ise RANGE, aksi halde JSONB sayilir.
    sboJsonContains, sboJsonContained:
      begin
        if VDbIsRangeLit(LeftVal) or VDbIsRangeLit(RightVal) then
        begin
          if not ParseBothRanges(LeftVal, RightVal, RA, RB) then Exit('');
          if AOp = sboJsonContains then bRes := VDbRangeContains(RA, RB)
          else bRes := VDbRangeContained(RA, RB);
        end
        else if AOp = sboJsonContains then
          bRes := VDbJsonContainsStr(LeftVal, RightVal)
        else
          bRes := VDbJsonContainsStr(RightVal, LeftVal);
      end;
    sboJsonHasKey:    bRes := VDbJsonHasKeyStr(LeftVal, RightVal);     // ?
    // ---- F-25: RANGE operatorleri ----
    // Parse edilemeyen aralik metni hata vermez; UNKNOWN ('') doner.
    sboRangeOverlap, sboRangeBefore, sboRangeAfter, sboRangeContains,
    sboRangeContained, sboRangeOvLeft, sboRangeOvRight, sboRangeAdjacent:
      begin
        if not ParseBothRanges(LeftVal, RightVal, RA, RB) then Exit('');
        case AOp of
          sboRangeOverlap:   bRes := VDbRangeOverlap(RA, RB);
          sboRangeBefore:    bRes := VDbRangeBefore(RA, RB);
          sboRangeAfter:     bRes := VDbRangeAfter(RA, RB);
          sboRangeContains:  bRes := VDbRangeContains(RA, RB);
          sboRangeContained: bRes := VDbRangeContained(RA, RB);
          sboRangeOvLeft:    bRes := VDbRangeOverlapsLeft(RA, RB);
          sboRangeOvRight:   bRes := VDbRangeOverlapsRight(RA, RB);
          sboRangeAdjacent:  bRes := VDbRangeAdjacent(RA, RB);
        end;
      end;
  else
    bRes := False;
  end;
  if bRes then Result := 'True' else Result := 'False';
end;

{ ------------------------------------------------------------
  EvalUnary
  //---------------------------------------------------------- }
function TVSqlExecutor.EvalUnary(AOp: TSqlUnaryOp; const Val: string): string;
var
  iVal: Int64;
  fVal: Double;
  b: Boolean;
begin
  case AOp of
    suoNot:
      begin
        // F1-14: NOT NULL => UNKNOWN (''), not TRUE.
        if Val = '' then Exit('');
        b := SameText(Val, 'True') or (Val = '1');
        if not b then Result := 'True' else Result := 'False';
      end;
    suoNeg:
      begin
        if Val = '' then Exit('');
        if VDbParseInt(Val, iVal) then Result := IntToStr(-iVal)
        else if VDbParseFloat(Val, fVal) then Result := VDbFloatToStr(-fVal)
        else Result := Val;
      end;
    suoIsNull:    if Val = '' then Result := 'True' else Result := 'False';
    suoIsNotNull: if Val <> '' then Result := 'True' else Result := 'False';
  else
    Result := Val;
  end;
end;

{ H-ek: Bir ifadenin sonuc tipini (kaba) cikarir. EvalBinary'nin aritmetik
  dallari (sboAdd..sboMod) HER ZAMAN sayisal sonuc uretir ( || ayri op).
  Bu yuzden aritmetik bir ifade karsilastirmada VCT_STR ile metin sirasi
  yerine sayisal kiyaslanmalidir. Yalnizca kanitlanabilir durumda sayisal
  doner; belirsizlikte VCT_STR. }
function TVSqlExecutor.ExprResultCtype(E: TSqlExprNode;
  const ColNames: TStrArray; const ColTypes: TByteArray): Byte;
var
  ci: Integer;
  bin: TSqlBinaryOpNode;
  un: TSqlUnaryOpNode;
  lit: TSqlLiteralNode;
  lt, rt: Byte;
begin
  Result := VCT_STR;
  if E = nil then Exit;
  if E is TSqlColumnRefNode then
  begin
    ci := FindColIdx(TSqlColumnRefNode(E).ColumnName,
                     TSqlColumnRefNode(E).TableQualifier, ColNames);
    if (ci >= 0) and (ci < Length(ColTypes)) then Result := ColTypes[ci];
    Exit;
  end;
  if E is TSqlLiteralNode then
  begin
    lit := TSqlLiteralNode(E);
    case lit.LitType of
      sltInt:   Result := VCT_INT;
      sltFloat: Result := VCT_FLOAT;
    else
      Result := VCT_STR;
    end;
    Exit;
  end;
  if E is TSqlUnaryOpNode then
  begin
    un := TSqlUnaryOpNode(E);
    if un.Op = suoNeg then Exit(ExprResultCtype(un.Operand, ColNames, ColTypes));
    Exit(VCT_STR);
  end;
  if E is TSqlBinaryOpNode then
  begin
    bin := TSqlBinaryOpNode(E);
    case bin.Op of
      sboAdd, sboSub, sboMul, sboDiv, sboMod:
        begin
          lt := ExprResultCtype(bin.Left, ColNames, ColTypes);
          rt := ExprResultCtype(bin.Right, ColNames, ColTypes);
          if (lt = VCT_FLOAT) or (rt = VCT_FLOAT) then Result := VCT_FLOAT
          else if (lt = VCT_INT) and (rt = VCT_INT) then Result := VCT_INT
          else Result := VCT_STR;
        end;
    else
      Result := VCT_STR;   // karsilastirma/mantik/concat -> metin/bool
    end;
    Exit;
  end;
  if E is TSqlFuncCallNode then
    Exit(ScalarFuncCtype(TSqlFuncCallNode(E)));
end;

{ ------------------------------------------------------------
  4.3: Aggregate yardimcilari
  IsAggFuncName: fonksiyon adi aggregate mi?
  EvalAggregateValue: aggregate'i verilen grup satir kumesi uzerinden
    hesaplar â€” SELECT listesi ile HAVING TEK uygulamayi paylasir.
  AggFuncCtype: aggregate'in karsilastirma tipi (HAVING'de kolon
    referansi olmadigi icin tip burada cozulur).
//---------------------------------------------------------- }
function IsAggFuncName(const S: string): Boolean;
begin
  Result := (S = 'COUNT') or (S = 'SUM') or (S = 'AVG') or
            (S = 'MIN') or (S = 'MAX') or
            (S = 'STRING_AGG') or (S = 'PERCENTILE_CONT') or
            (S = 'PERCENTILE_DISC') or (S = 'PERCENTILE');
end;

function TVSqlExecutor.EvalAggregateValue(fn: TSqlFuncCallNode;
  const SrcRows: TStrMatrix; Idx: TList<Integer>;
  const ACNames: TStrArray; const ACTypes: TByteArray): string;
var
  k, ci, avgCnt: Integer;
  cntI: Int64;
  sumF, fv: Double;
  minV, maxV, colVal: string;
  aggCt: Byte;
  // F-11: DISTINCT â€” tekrarli degerler bir kez sayilir. Hash kova ile
  // O(N); NULL degerler DISTINCT kumesine GIRMEZ (SQL standardi).
  seen: TDictionary<string, Byte>;
begin
  cntI := 0; sumF := 0; avgCnt := 0; minV := ''; maxV := '';
  if fn.IsDistinct then
    seen := TDictionary<string, Byte>.Create
  else
    seen := nil;
  try
  // MIN/MAX karsilastirmasi kolon tipiyle yapilir. VCT_STR ile
  // kiyaslanirsa '10' < '2' olur (string sira) â€” yanlis sonuc.
  // 4.3: FindColIdx ile â€” nitelikli arguman ('o.tutar') ve JOIN'de
  // sonek kurali da gorulur (eski birebir SameText yalnizca tek
  // tabloda eslesiyordu).
  aggCt := VCT_STR;
  if fn.Arg is TSqlColumnRefNode then
  begin
    ci := FindColIdx(TSqlColumnRefNode(fn.Arg).ColumnName,
      TSqlColumnRefNode(fn.Arg).TableQualifier, ACNames);
    if (ci >= 0) and (ci < Length(ACTypes)) then aggCt := ACTypes[ci];
  end;
  for k := 0 to Idx.Count - 1 do
  begin
    // F-16: FILTER (WHERE ...) â€” kosul saglamayan satir atlanir.
    if fn.Filter <> nil then
      if not EvalBool(fn.Filter, SrcRows[Idx[k]], ACNames, ACTypes) then
        Continue;
    if fn.IsStar then
    begin
      // COUNT(DISTINCT *) her zaman 1 (tek yildiz)
      if fn.IsDistinct then
      begin
        if not seen.ContainsKey('*') then
        begin
          seen.Add('*', 0);
          Inc(cntI);
        end;
      end
      else
        Inc(cntI);
    end
    else
    begin
      colVal := EvalExpr(fn.Arg, SrcRows[Idx[k]], ACNames, ACTypes);
      if colVal = '' then Continue;   // NULL: DISTINCT kumesine girmez
      // F-11: tekrarli degerler bir kez sayilir
      if seen <> nil then
        if seen.ContainsKey(colVal) then Continue
        else seen.Add(colVal, 0);
      Inc(cntI);
      if VDbParseFloat(colVal, fv) then
      begin
        sumF := sumF + fv;
        Inc(avgCnt);
      end;
      if (minV = '') or VDbCmpVal(colVal, minV, '<', aggCt) then minV := colVal;
      if (maxV = '') or VDbCmpVal(colVal, maxV, '>', aggCt) then maxV := colVal;
    end;
  end;
  if fn.FuncName = 'COUNT' then Result := IntToStr(cntI)
  else if fn.FuncName = 'SUM' then
    if cntI > 0 then Result := VDbFloatToStr(sumF) else Result := ''
  else if fn.FuncName = 'AVG' then
  begin
    if avgCnt > 0 then Result := VDbFloatToStr(sumF / avgCnt)
    else Result := '';
  end
  else if fn.FuncName = 'MIN' then Result := minV
  else if fn.FuncName = 'MAX' then Result := maxV
  else Result := '';
  finally
    seen.Free;
  end;
end;

{ ------------------------------------------------------------
  EvalAggNode (F-14/F-15)
  TSqlAggNode: STRING_AGG(deger, ayirac[, DISTINCT]) ve
  PERCENTILE_CONT/DISC(p) WITHIN GROUP (ORDER BY kolon).
  Gruplu aggregate â€” FAggIdx baglaminda hesaplanir.
  //---------------------------------------------------------- }
function TVSqlExecutor.EvalAggNode(AN: TSqlAggNode;
  const SrcRows: TStrMatrix; Idx: TList<Integer>;
  const ACNames: TStrArray; const ACTypes: TByteArray): string;
var
  k, n, pctIdx, j: Integer;
  sepStr, val, loV, hiV: string;
  vals: TStrArray;
  // F-14: DISTINCT â€” TStringList ile tekrarli degerler elenir
  // (TDictionary generics'i bu fonksiyonda namespace sorunu veriyor;
  //  TStringList ayni isi yapar ve FPC'te sorunsuz).
  seen: TStringList;
  loF, hiF, frac: Double;
begin
  Result := '';
  if AN = nil then Exit;
  if AN.Kind = akStringAgg then
  begin
    sepStr := ',';
    if AN.Sep <> nil then
      sepStr := EvalExpr(AN.Sep, nil, ACNames, ACTypes);
    seen := nil;
    if AN.IsDistinct then
    begin
      // DIKKAT: TStringList.Sorted := True degerleri SIRALAR; cikti
      // sirasini bozardi. Bu yuzden IndexOf ile eleme YAPILIR ama
      // degerler dogru SIRADA eklenir (Sorted := False).
      seen := TStringList.Create;
      seen.Sorted := False;
      seen.Duplicates := dupAccept;
    end;
    try
      SetLength(vals, Idx.Count);
      n := 0;
      for k := 0 to Idx.Count - 1 do
      begin
        if AN.Arg = nil then Continue;
        val := EvalExpr(AN.Arg, SrcRows[Idx[k]], ACNames, ACTypes);
        if val = '' then Continue;   // NULL atlanir
        if seen <> nil then
        begin
          if seen.IndexOf(val) >= 0 then Continue;
          seen.Add(val);
        end;
        vals[n] := val;
        Inc(n);
      end;
      for j := 0 to n - 1 do
      begin
        if j > 0 then Result := Result + sepStr;
        Result := Result + vals[j];
      end;
    finally
      seen.Free;
    end;
    Exit;
  end;

  // PERCENTILE_CONT / PERCENTILE_DISC
  SetLength(vals, Idx.Count);
  n := 0;
  for k := 0 to Idx.Count - 1 do
  begin
    if AN.Arg = nil then Continue;
    val := EvalExpr(AN.Arg, SrcRows[Idx[k]], ACNames, ACTypes);
    if val = '' then Continue;   // NULL atlanir
    vals[n] := val;
    Inc(n);
  end;
  if n = 0 then Exit('');
  // sayisal siralama: VCT_FLOAT verilir, boylece '10' < '2' (metin
  // sirasi) yanligi olusmaz.
  for j := 0 to n - 2 do
    for k := 0 to n - 2 - j do
      if VDbCmpVal(vals[k], vals[k + 1], '>', VCT_FLOAT) then
      begin
        val := vals[k]; vals[k] := vals[k + 1]; vals[k + 1] := val;
      end;
  if AN.Kind = akPercentileDisc then
  begin
    // kesilmis: p*(n-1) indeksindeki GERCEK deger
    pctIdx := Trunc(AN.Pct * (n - 1));
    if pctIdx < 0 then pctIdx := 0;
    if pctIdx > n - 1 then pctIdx := n - 1;
    Result := vals[pctIdx];
    Exit;
  end;
  // CONT: iki komsu nokta arasinda lineer enterpolasyon
  frac := AN.Pct * (n - 1);
  pctIdx := Trunc(frac);
  if pctIdx >= n - 1 then
  begin
    // son eleman: enterpolasyon yok
    Result := vals[n - 1];
    Exit;
  end;
  loV := vals[pctIdx];
  hiV := vals[pctIdx + 1];
  if VDbParseFloat(loV, loF) and VDbParseFloat(hiV, hiF) then
    Result := VDbFloatToStr(loF + (hiF - loF) * (frac - pctIdx))
  else
    Result := loV;   // metin degerler: ilk nokta
end;

function TVSqlExecutor.ScalarFuncCtype(fn: TSqlFuncCallNode): Byte;
// Satir-ici skaler (aggregate olmayan) fonksiyonlarin donus tipi.
// WHERE/HAVING'te karsilastirma tipi buradan cozulur.
begin
  Result := VCT_STR;
  if (fn.FuncName = 'DISTANCE') or (fn.FuncName = 'HAVERSINE') or
     (fn.FuncName = 'AREA_POLYGON') or (fn.FuncName = 'ROUND') then
    Result := VCT_FLOAT
  else if (fn.FuncName = 'IN_CIRCLE') or (fn.FuncName = 'IN_BOX') or
          (fn.FuncName = 'IN_POLYGON') or
          (fn.FuncName = 'POINT_IN_POLYGON') then
    Result := VCT_BOOL;
end;

function TVSqlExecutor.AggFuncCtype(fn: TSqlFuncCallNode): Byte;
var
  ci: Integer;
begin
  Result := ScalarFuncCtype(fn);
  if Result <> VCT_STR then Exit;
  if fn.FuncName = 'COUNT' then Exit(VCT_INT);
  if (fn.FuncName = 'SUM') or (fn.FuncName = 'AVG') then Exit(VCT_FLOAT);
  if (fn.FuncName = 'MIN') or (fn.FuncName = 'MAX') then
    if fn.Arg is TSqlColumnRefNode then
    begin
      // HAVING sirasinda KAYNAK kolon adlari kullanilir (cikti
      // alias'lari degil; SUM(tutar) SELECT'te yoksa bile cozulur).
      ci := FindColIdx(TSqlColumnRefNode(fn.Arg).ColumnName,
        TSqlColumnRefNode(fn.Arg).TableQualifier, FAggCNames);
      if (ci >= 0) and (ci < Length(FAggCTypes)) then Exit(FAggCTypes[ci]);
    end;
end;

{ ------------------------------------------------------------
  EvalExpr
  //---------------------------------------------------------- }
function TVSqlExecutor.EvalExpr(Expr: TSqlExprNode; const Row: TStrArray;
  const ColNames: TStrArray; const ColTypes: TByteArray): string;
var
  lit: TSqlLiteralNode;
  colRef: TSqlColumnRefNode;
  bin: TSqlBinaryOpNode;
  un: TSqlUnaryOpNode;
  inN: TSqlInNode;
  collN: TSqlCollateNode;   // R-20
  subN: TSqlSubqueryNode;
  quantN: TSqlQuantNode;   // F-06: ANY/SOME/ALL
  aggN: TSqlAggNode;       // F-14/F-15: STRING_AGG / PERCENTILE
  csN: TSqlCaseNode;
  cn: TSqlCastNode;       // CAST ( expr AS type )
  ov, wv, lv, lv2: string;
  subR: TSqlResult;
  varRow, varCols: TStrArray;   // F-36: trigger NEW/OLD baglam degiskenleri
  v: string;              // gecici ifade degeri
  bt: TSqlBetweenNode;
  fn: TSqlFuncCallNode;
  rv, itemVal: string;
  ct: Byte;
  idx, i, ci, nd: Integer;
  matched: Boolean;
  fa, fb, fc, fd, fe, fg: Double;
  ia: Int64;
  hasNull: Boolean;
  // F2-20
  inSet: TDictionary<string, Byte>;
  // F-22: JSONB anahtar listesi
  jk: TSqlJsonKeyNode;
  jv, jw: string;
  jkeys: TStrArray;
  nk: Integer;
  // F-23: XML
  xargs: TStrArray;
  xpart: string;
  xroot: TXmlNode;
  xn: TXmlNode;
  // M10: JSONPath fonksiyon argumanlari
  jargs: TStrArray;
  jout: string;
  // M4: vektor fonksiyonlari
  va, vb: TDoubleArray;
  vna, vnb, vdot, vsum: Double;
  vmetric: string;
  // F-25: RANGE
  rargs: TStrArray;
  br: string;
  rr: TRangeBound;
  args: TList<TSqlExprNode>;
  argTexts: TStrArray;
begin
  if Expr = nil then Exit('');

  if Expr is TSqlLiteralNode then
  begin
    lit := TSqlLiteralNode(Expr);
    Exit(lit.AsString);
  end;

  if Expr is TSqlCastNode then
  begin
    // CAST ( expr AS type )
    cn := TSqlCastNode(Expr);
    v := EvalExpr(cn.Expr, Row, ColNames, ColTypes);
    // TEXT -> metin (zaten string donuyor), INTEGER -> metin
    if SameText(cn.TargetType, 'TEXT') then Exit(v);
    if SameText(cn.TargetType, 'INTEGER') then
    begin
      if not VDbParseInt(v, ia) then
        raise EVDbException.Create(ecTypeMismatch, 'CAST: "' + v + '" INTEGER olamiyor');
      Exit(IntToStr(ia));
    end;
    // Tip bilinmiyorsa (VARCHAR, NUMERIC vb.) metin olarak dondur.
    Exit(v);
  end;

  if Expr is TSqlColumnRefNode then
  begin
    colRef := TSqlColumnRefNode(Expr);
    if (Row = nil) or (Length(ColNames) = 0) then
    begin
      // F-35: nitelikSIZ kolon ismi fonksiyon/prosedur parametresine bakilir.
      // Nitelikli (p_t.id gibi) referanslar TABLO'dan gelmelidir, parametreye DEGIL.
      if colRef.TableQualifier = '' then
      begin
        // F-35: fonksiyon/prosedur parametre kapsami hâlâ aktifse ona bak
        if (FProcRow <> nil) and (Length(FProcColNames) > 0) then
        begin
          idx := FindColIdx(colRef.ColumnName, colRef.TableQualifier, FProcColNames);
          if (idx >= 0) and (idx < Length(FProcRow)) then Exit(FProcRow[idx]);
        end;
      end;
      // F-36: TRIGGER NEW/OLD satir karsiliklari
      if colRef.TableQualifier <> '' then
      begin
        varRow := FOuterRow;
        varCols := FOuterColNames;
        if SameText(colRef.TableQualifier, 'OLD') then
        begin
          varRow := FOuterOldRow;
          varCols := FOuterOldColNames;
        end;
        if (varRow <> nil) and (varCols <> nil) and (Length(varCols) > 0) then
        begin

          idx := FindColIdx(colRef.ColumnName, '', varCols);
          if (idx >= 0) and (idx < Length(varRow)) then
          begin
  
            Exit(varRow[idx]);
          end
          else
          begin
            // NEW/OLD kolonu satir dizisinde YOK -> NULL ('')

            Exit('');
          end;
        end;
      end;

      Exit(colRef.ColumnName);
    end;
    // R-03: UPSERT - excluded pseudo-table
    if (colRef.TableQualifier <> '') and SameText(colRef.TableQualifier, 'excluded') then
    begin
      if (FExcludedRow <> nil) and (Length(FExcludedColNames) > 0) then
      begin
        idx := FindColIdx(colRef.ColumnName, '', FExcludedColNames);
        if (idx >= 0) and (idx < Length(FExcludedRow)) then Exit(FExcludedRow[idx]);
      end;
      raise EVDbException.Create(ecColumnNotFound, 'excluded kolonu bulunamadi: ' + colRef.ColumnName);
    end;
    // F-03: iliskili alt sorgu. Nitelikli referans (a.x) ic kapsamda YOKSA
    // once DIS kapsam denenir. DIKKAT: tek-tablo yolunda ColNames
    // NITELIKSIZdir ('id'), FindColIdx niteligi yok sayip ic satiri
    // dondururdu -> a.id yanlis cozulurdu. Dis kapsamda bulunamazsa
    // normal cozumlemeye DUSULUR (ust duzey sorgu `a.ad` yazabilir).
    if (colRef.TableQualifier <> '') and (not QualifierInScope(colRef.TableQualifier, ColNames)) then
      if (FOuterRow <> nil) and (FOuterColNames <> nil) then
      begin
        idx := FindColIdx(colRef.ColumnName, colRef.TableQualifier, FOuterColNames);
        if (idx >= 0) and (idx < Length(FOuterRow)) then
        begin
          Exit(FOuterRow[idx]);
        end;
      end;
      // F-35: fonksiyon/prosedur PARAMETRE KAPSAMI (niteliksiz adlar icin ONCELikli).
      // Parametre kapsami, govde icindeki tablo/alias kolonlarindan once denenir:
      // böylece bir SELECT'in kendi kolonu parametre adini golgeleyemez
      // (PL/pgSQL semantigi: fonksiyon/prosedur parametreleri, govde icindeki
      // ifadelerde kolon isimlerini golgelemektedir). Nitelikli referanslar
      // (p_t.id) ise her zaman TABLO'dan gelmelidir (aşağıdaki Normal yol).
      if (FProcRow <> nil) and (Length(FProcColNames) > 0) and (colRef.TableQualifier = '') then
      begin
        idx := FindColIdx(colRef.ColumnName, colRef.TableQualifier, FProcColNames);
        if (idx >= 0) and (idx < Length(FProcRow)) then Exit(FProcRow[idx]);
      end;
    idx := FindColIdx(colRef.ColumnName, colRef.TableQualifier, ColNames);
    if (idx >= 0) and (idx < Length(Row)) then Exit(Row[idx]);
    if (colRef.TableQualifier <> '') and (FOuterRow <> nil) and (FOuterColNames <> nil) then
    begin
      idx := FindColIdx(colRef.ColumnName, colRef.TableQualifier, FOuterColNames);
      if (idx >= 0) and (idx < Length(FOuterRow)) then Exit(FOuterRow[idx]);
    end;
    // Hata mesajina mevcut kolon adlarini da ekle: hatayi ayiklamak
    // ("x.butce" hangi tabloya ait degil?) icin gereklidir.
    RaiseEVDbColumnNotFound(colRef.QualifiedName, ColNames);
  end;

  if Expr is TSqlBinaryOpNode then
  begin
    bin := TSqlBinaryOpNode(Expr);
    lv := EvalExpr(bin.Left, Row, ColNames, ColTypes);
    rv := EvalExpr(bin.Right, Row, ColNames, ColTypes);
    ct := VCT_STR;
    // F1-17: tip cozumlesmesi nitelemeli adi da gorur, aksi halde
    // JOIN sonrasi WHERE'te karsilastirma metin sirasiyla yapilir.
    if bin.Left is TSqlColumnRefNode then
    begin
      colRef := TSqlColumnRefNode(bin.Left);
      ci := FindColIdx(colRef.ColumnName, colRef.TableQualifier, ColNames);
      if (ci >= 0) and (ci < Length(ColTypes)) then ct := ColTypes[ci];
    end;
    if (ct = VCT_STR) and (bin.Right is TSqlColumnRefNode) then
    begin
      colRef := TSqlColumnRefNode(bin.Right);
      ci := FindColIdx(colRef.ColumnName, colRef.TableQualifier, ColNames);
      if (ci >= 0) and (ci < Length(ColTypes)) then ct := ColTypes[ci];
    end;
    // 4.3: HAVING'de aggregate ifade kolon referansi olmadigi icin tipi
    // burada cozulur. Yapilmazsa VCT_STR ile metin sirasi kiyasla
    // yapilir ve '10' > '9' (false) gibi yanlis HAVING sonuclari dogar.
    if (ct = VCT_STR) and (FAggIdx <> nil) then
    begin
      if bin.Left is TSqlFuncCallNode then
        ct := AggFuncCtype(TSqlFuncCallNode(bin.Left));
      if (ct = VCT_STR) and (bin.Right is TSqlFuncCallNode) then
        ct := AggFuncCtype(TSqlFuncCallNode(bin.Right));
    end;
    // F-24: WHERE'de fonksiyon donusu de tip-bilgili karsilastirilmalidir.
    // DISTANCE(x,y,0,0) <= 5 ifadesi aksi halde metin sirasiyla kiyaslanir:
    // '14.141356' <= '5' -> TRUE olur ve (10,10) noktasi yanlis girer.
    if ct = VCT_STR then
    begin
      if bin.Left is TSqlFuncCallNode then
        ct := ScalarFuncCtype(TSqlFuncCallNode(bin.Left));
      if (ct = VCT_STR) and (bin.Right is TSqlFuncCallNode) then
        ct := ScalarFuncCtype(TSqlFuncCallNode(bin.Right));
    end;
    // H-ek: IKI taraf da kolon referansi DEGILSE (yani tip hicbir kolondan
    // gelmiyorsa) ifade sonuc tipini cikar. `(a+0) > 198` aksi halde metin
    // sirasiyla kiyaslanip '1990' < '198' gibi yanlis sonuc veriyordu.
    // Bir taraf kolon ise kolon tipi (ustteki mantik) korunur — metin
    // kolonunun sayisal literalle kiyasi DEGISMEZ.
    if (ct = VCT_STR) and (not (bin.Left is TSqlColumnRefNode)) and
       (not (bin.Right is TSqlColumnRefNode)) then
    begin
      ct := ExprResultCtype(bin.Left, ColNames, ColTypes);
      if ct = VCT_STR then
        ct := ExprResultCtype(bin.Right, ColNames, ColTypes);
    end;
    // R-20: metin kolonu ve karsilastirma tarafi bir kolon referansi ise
    // o kolonun varsayilan collation'i uygulanir. ACIK COLLATE yazilmissa
    // ustune yazilmaz (FExplicitColl).
    if (ct = VCT_STR) and (FCurTable <> '') and (not FExplicitColl) then
    begin
      FCurCollation := ColCollation(bin.Left, ColNames);
      if FCurCollation = '' then
        FCurCollation := ColCollation(bin.Right, ColNames);
    end
    else if not FExplicitColl then
      FCurCollation := '';
    Result := EvalBinary(bin.Op, lv, rv, ct);
    if not FExplicitColl then
    begin
      FCurCollation := '';
      FExplicitColl := False;
    end;
    Exit(Result);
  end;

  // ---- R-20: `karsilastirma COLLATE <ad>` ----
  // TSqlCollateNode karsilastirma ifadesini sarar: once acik collation
  // ayarlanir, sonra ic ifade degerlendirilir (orada FExplicitColl
  // kolon varsayilaninin USTUNE YAZMASINI engeller).
  if Expr is TSqlCollateNode then
  begin
    collN := TSqlCollateNode(Expr);
    FCurCollation := collN.Name;
    FExplicitColl := True;
    Exit(EvalExpr(collN.Inner, Row, ColNames, ColTypes));
  end;

  if Expr is TSqlUnaryOpNode then
  begin
    un := TSqlUnaryOpNode(Expr);
    lv := EvalExpr(un.Operand, Row, ColNames, ColTypes);
    Exit(EvalUnary(un.Op, lv));
  end;

  if Expr is TSqlInNode then
  begin
    inN := TSqlInNode(Expr);
    lv := EvalExpr(inN.Expr, Row, ColNames, ColTypes);
    // NULL IN (...) / NULL NOT IN (...) -> UNKNOWN. Once 'False' donuyordu;
    // dis NOT bunu True'ya cevirip NULL satirlarini yanlislikla seciyordu.
    if lv = '' then Exit('');
    matched := False;
    // F1-13: NOT IN ... NULL handling (three-valued logic)
    hasNull := False;
    if inN.SubSelect <> nil then
    begin
      // P5-2: IN (SELECT ...) - ic sorgu tek kolon dondurmelidir.
      // NULL kurali liste davranisiyla aynidir: '' degerler eslesmez.
      subR := SubResult(inN.SubSelect, Row, ColNames);
      if Length(subR.Fields) <> 1 then
        raise EVDbException.Create(ecInvalidArgument,
          'IN alt sorgusu tek kolon dondurmeli');
      // F2-20: iliskisiz alt sorguda degerler TEK KEZ hash kovaya yazilir
      // (O(N+M)). F-03: iliskili alt sorguda sonuc dis satira baglidir;
      // onbellek KULLANILMAZ.
      if IsCorrelatedSel(inN.SubSelect) then
      begin
        matched := False; hasNull := False;
        for i := 0 to High(subR.Rows) do
        begin
          if Length(subR.Rows[i]) = 0 then Continue;
          if subR.Rows[i][0] = '' then hasNull := True;
          if (not matched) and (subR.Rows[i][0] = lv) then matched := True;
        end;
      end
      else if FInSetCache.TryGetValue(Pointer(inN.SubSelect), inSet) then
      begin
        matched := inSet.ContainsKey(lv);
        hasNull := inSet.ContainsKey('');
      end
      else
      begin
        inSet := TDictionary<string, Byte>.Create;
        for i := 0 to High(subR.Rows) do
          if Length(subR.Rows[i]) > 0 then
            inSet.AddOrSetValue(subR.Rows[i][0], 0);
        FInSetCache.Add(Pointer(inN.SubSelect), inSet);
        matched := inSet.ContainsKey(lv);
        hasNull := inSet.ContainsKey('');
      end;
    end
    else
      for i := 0 to inN.List.Count - 1 do
      begin
        itemVal := EvalExpr(inN.List[i], Row, ColNames, ColTypes);
        if itemVal = lv then begin matched := True; Break; end;
        if itemVal = '' then hasNull := True;
      end;
    if inN.IsNot then
    begin
      // SQL: x NOT IN (liste) = NOT (x IN (liste)).
      // Eslesme varsa FALSE; eslesme yok ama listede NULL varsa UNKNOWN.
      if matched then Exit('False');
      if hasNull then Exit('');
      Exit('True');
    end;
    if matched then Exit('True');
    if hasNull then Exit('');
    Exit('False');
  end;

  if Expr is TSqlQuantNode then
  begin
    // F-06: ANY/SOME/ALL. ANY = en az bir satir, ALL = tum satirlar.
    quantN := TSqlQuantNode(Expr);
    subR := SubResult(quantN.SubSelect, Row, ColNames);
    if Length(subR.Fields) <> 1 then
      raise EVDbException.Create(ecInvalidArgument,
        'ANY/SOME/ALL alt sorgusu tek kolon dondurmeli');
    lv := EvalExpr(quantN.Left, Row, ColNames, ColTypes);
    ct := VCT_STR;
    if quantN.Left is TSqlColumnRefNode then
    begin
      colRef := TSqlColumnRefNode(quantN.Left);
      ci := FindColIdx(colRef.ColumnName, colRef.TableQualifier, ColNames);
      if (ci >= 0) and (ci < Length(ColTypes)) then ct := ColTypes[ci];
    end;
    matched := False;
    hasNull := False;
    if quantN.Kind = qkAny then
    begin
      // en az bir satir TRUE -> TRUE
      for i := 0 to High(subR.Rows) do
      begin
        if Length(subR.Rows[i]) = 0 then Continue;
        rv := subR.Rows[i][0];
        if rv = '' then begin hasNull := True; Continue; end;
        if SameText(EvalBinary(quantN.CmpOp, lv, rv, ct), 'True') then
        begin matched := True; Break; end;
      end;
      if (not matched) and hasNull then Exit('');   // UNKNOWN
    end
    else
    begin
      // tum satirlar TRUE -> TRUE; bos kume -> TRUE (SQL standart)
      matched := True;
      for i := 0 to High(subR.Rows) do
      begin
        if Length(subR.Rows[i]) = 0 then Continue;
        rv := subR.Rows[i][0];
        if rv = '' then begin matched := False; hasNull := True; Break; end;
        if not SameText(EvalBinary(quantN.CmpOp, lv, rv, ct), 'True') then
        begin matched := False; Break; end;
      end;
      // NULL varsa ve baska bir satir FALSE degilse UNKNOWN
      if hasNull and matched then Exit('');
      if hasNull and not matched then
      begin
        // NULL goruldu ve en az bir FALSE goruldu -> FALSE
        Exit('False');
      end;
    end;
    if matched then Exit('True') else Exit('False');
  end;

  if Expr is TSqlSubqueryNode then
  begin
    // P5-2: skaler deger veya EXISTS denetimi.
    subN := TSqlSubqueryNode(Expr);
    subR := SubResult(subN.Select, Row, ColNames);
    if subN.Kind = sqExists then
    begin
      matched := Length(subR.Rows) > 0;
      if subN.IsNot then matched := not matched;
      if matched then Exit('True') else Exit('False');
    end;
    if Length(subR.Fields) <> 1 then
      raise EVDbException.Create(ecInvalidArgument,
        'skaler alt sorgu tek kolon dondurmeli');

    if Length(subR.Rows) = 0 then Exit(''); // satir yok = NULL
    if Length(subR.Rows) > 1 then
      raise EVDbException.Create(ecInvalidArgument,
        'skaler alt sorgu birden fazla satir dondurdu');
    if Length(subR.Rows[0]) = 0 then Exit('');
    Exit(subR.Rows[0][0]);
  end;

  if Expr is TSqlBetweenNode then
  begin
    bt := TSqlBetweenNode(Expr);
    lv := EvalExpr(bt.Expr, Row, ColNames, ColTypes);
    // NULL BETWEEN ... / NULL NOT BETWEEN ... -> UNKNOWN. Once 'False'
    // donuyordu; dis NOT bunu True'ya cevirip NULL satirlarini seciyordu.
    if lv = '' then Exit('');
    ct := VCT_STR;
    if bt.Expr is TSqlColumnRefNode then
    begin
      colRef := TSqlColumnRefNode(bt.Expr);
      for i := 0 to High(ColNames) do
        if SameText(colRef.ColumnName, ColNames[i]) and (i < Length(ColTypes)) then
        begin ct := ColTypes[i]; Break; end;
    end
    // H-ek: ifade tarafi (kolon degil) sayisal ise metin sirasi yerine sayisal.
    else
      ct := ExprResultCtype(bt.Expr, ColNames, ColTypes);
    lv2 := EvalExpr(bt.LowBound, Row, ColNames, ColTypes);
    if lv2 = '' then Exit('');
    rv := EvalExpr(bt.HighBound, Row, ColNames, ColTypes);
    if rv = '' then Exit('');
    matched := VDbCmpVal(lv, lv2, '>=', ct) and
               VDbCmpVal(lv, rv, '<=', ct);
    if bt.IsNot then matched := not matched;
    if matched then Exit('True') else Exit('False');
  end;

  if Expr is TSqlAggNode then
  begin
    // F-14/F-15: STRING_AGG / PERCENTILE. Satir-basi degerlendirmede
    // (FAggIdx yok) anlamsizdir: aggregate bir grup uzerinden hesaplanir.
    // ExecGroupId bu dogrudan rowIdx ile cagirir; buraya yalniz HAVING
    // icinden (FAggIdx acikken) girilir.
    if FAggIdx = nil then
      raise EVDbException.Create(ecUnsupported,
        'STRING_AGG/PERCENTILE yanlis baglamda (satir-basi) kullanilamaz');
    Exit(EvalAggNode(TSqlAggNode(Expr), FAggSrcRows, FAggIdx,
                     FAggCNames, FAggCTypes));
  end;

  if Expr is TSqlFuncCallNode then
  begin
    fn := TSqlFuncCallNode(Expr);
    // 4.3: HAVING'de aggregate dogrudan yazilabilir. Grup baglami acikken
    // deger grup satirlari uzerinden hesaplanir; baglam yoksa eski
    // davranis (COUNT(*) -> '1', SUM(x) -> tek satir degeri) surer.
    if IsAggFuncName(fn.FuncName) and ((FAggIdx <> nil) or FHavingOvOn) then
    begin
      // H15: akisli GROUP BY yolunda kaynak satir yok; aggregate degeri
      // grup sayaclarindan onceden hesaplanip dugum kimligiyle eslenir.
      if FHavingOvOn then
      begin
        for i := 0 to High(FHavingOv) do
          if FHavingOv[i].N = Expr then Exit(FHavingOv[i].V);
        raise EVDbException.Create(ecUnsupported,
          'HAVING aggregate degeri hesaplanmadi: ' + fn.FuncName);
      end;
      Exit(EvalAggregateValue(fn, FAggSrcRows, FAggIdx, FAggCNames, FAggCTypes));
    end;
    // F-35: User-defined function execution
    { NOT: Argumanlar AST olarak degil, DEGERLENMIS METIN olarak
      gecirilir. TVTableDb.ExecuteFunction parametreleri TStrArray alir
      (VDBTable parser'a baglanamaz; ayrica parametre sayisi denetimi
      yapilabilsin diye). }
    if FT.FunctionExists(fn.FuncName) then
    begin
      if fn.Args <> nil then
      begin
        // Coklu arguman: fn.Args listesi
        SetLength(argTexts, fn.Args.Count);
        for i := 0 to fn.Args.Count - 1 do
          argTexts[i] := EvalExpr(fn.Args[i], Row, ColNames, ColTypes);
      end
      else
      begin
        // Tek arguman (parser fn.Arg'a koyar) ya da argsiz cagir
        if fn.Arg <> nil then
          argTexts := [EvalExpr(fn.Arg, Row, ColNames, ColTypes)]
        else
          argTexts := [];
      end;
      // F-35: govde executor'da calistirilir (katalog yalniz tanimi tutar).
      Exit(CallUserFunction(fn.FuncName, argTexts));
    end;
    if fn.IsStar then Exit('1');
    lv := EvalExpr(fn.Arg, Row, ColNames, ColTypes);
    if fn.FuncName = 'UPPER' then Exit(VDbTrUpper(lv))
    else if fn.FuncName = 'LENGTH' then
    begin
      // BLOB'da bayt sayisi (ikili veri UTF-8 karakteri degildir).
      if fn.Arg is TSqlColumnRefNode then
      begin
        colRef := TSqlColumnRefNode(fn.Arg);
        for i := 0 to High(ColNames) do
          if SameText(colRef.ColumnName, ColNames[i]) and
             (i < Length(ColTypes)) and (ColTypes[i] = VCT_BLOB) then
            Exit(IntToStr(Length(lv)));
      end;
      Exit(IntToStr(VDbUtf8Length(lv)));
    end
    else if fn.FuncName = 'ABS' then
    begin
      if VDbParseFloat(lv, fa) then Exit(VDbFloatToStr(Abs(fa)))
      else if VDbParseInt(lv, ia) then Exit(IntToStr(Abs(ia)))
      else Exit(lv);
    end
    // F-25: RANGE fonksiyonlari (degisken argumanli)
    else if (fn.FuncName = 'RANGE') or (fn.FuncName = 'CONTAINS') then
    begin
      SetLength(rargs, fn.Args.Count);
      for i := 0 to fn.Args.Count - 1 do
        rargs[i] := EvalExpr(fn.Args[i], Row, ColNames, ColTypes);
      if fn.FuncName = 'CONTAINS' then
      begin
        if Length(rargs) < 2 then Exit('');
        if not VDbParseRange(rargs[0], rr) then Exit('');
        Exit(BoolToStr(VDbRangeContainsVal(rr, rargs[1]), True));
      end;
      // RANGE: parser TUM argumanlari tek literal metninde topladi ve
      // '~' ile birlestirdi ("1~5" / "1~5~[)").
      Exit(EvalRangeCtor(rargs[0]));
    end
    else if fn.FuncName = 'LOWER' then Exit(VDbTrLower(lv))
    // F-24: ROUND(sayi [, ondalik]) â€” yuvarlama
    else if fn.FuncName = 'ROUND' then
    begin
      if fn.Args.Count < 1 then Exit('');
      lv := EvalExpr(fn.Args[0], Row, ColNames, ColTypes);
      if not VDbParseFloat(lv, fa) then Exit('');
      nd := 0;
      if fn.Args.Count >= 2 then
      begin
        lv := EvalExpr(fn.Args[1], Row, ColNames, ColTypes);
        if not TryStrToInt(lv, nd) then Exit('');
      end;
      if nd < 0 then nd := 0;
      if nd > 15 then nd := 15;
      Exit(VDbFloatToStr(RoundTo(fa, -nd)));
    end
    else if fn.FuncName = 'COALESCE' then
    begin
      if lv <> '' then Exit(lv) else Exit('');
    end
    // ---- M10: JSONPath (JSON_EXTRACT / JSON_VALUE / JSON_EXISTS) ----
    else if (fn.FuncName = 'JSON_EXTRACT') or (fn.FuncName = 'JSON_VALUE') or
            (fn.FuncName = 'JSON_EXISTS') then
    begin
      SetLength(jargs, 0);
      if fn.Args <> nil then
      begin
        SetLength(jargs, fn.Args.Count);
        for i := 0 to fn.Args.Count - 1 do
          jargs[i] := EvalExpr(fn.Args[i], Row, ColNames, ColTypes);
      end
      else if fn.Arg <> nil then
        jargs := [EvalExpr(fn.Arg, Row, ColNames, ColTypes)];
      if Length(jargs) < 2 then Exit('');
      if fn.FuncName = 'JSON_EXISTS' then
        Exit(BoolToStr(VDbJsonPathExists(jargs[0], jargs[1]), True));
      if fn.FuncName = 'JSON_VALUE' then
      begin
        if not VDbJsonPathScalar(jargs[0], jargs[1], jout) then Exit('');
        Exit(jout);
      end;
      if not VDbJsonPathGet(jargs[0], jargs[1], jout) then Exit('');
      Exit(jout);
    end
    // ---- M4: vektor fonksiyonlari (JSON sayi dizisi uzerinde) ----
    else if (fn.FuncName = 'VECTOR_DIM') or (fn.FuncName = 'VECTOR_NORM') or
            (fn.FuncName = 'VECTOR_DISTANCE') then
    begin
      SetLength(jargs, 0);
      if fn.Args <> nil then
      begin
        SetLength(jargs, fn.Args.Count);
        for i := 0 to fn.Args.Count - 1 do
          jargs[i] := EvalExpr(fn.Args[i], Row, ColNames, ColTypes);
      end
      else if fn.Arg <> nil then
        jargs := [EvalExpr(fn.Arg, Row, ColNames, ColTypes)];
      if Length(jargs) < 1 then Exit('');
      if not VDbJsonNumArray(jargs[0], va) then Exit('');
      if fn.FuncName = 'VECTOR_DIM' then Exit(IntToStr(Length(va)));
      if fn.FuncName = 'VECTOR_NORM' then
      begin
        vsum := 0;
        for i := 0 to High(va) do vsum := vsum + va[i] * va[i];
        Exit(VDbFloatToStr(Sqrt(vsum)));
      end;
      if Length(jargs) < 2 then Exit('');
      if not VDbJsonNumArray(jargs[1], vb) then Exit('');
      if Length(va) <> Length(vb) then Exit('');
      vmetric := 'l2';
      if Length(jargs) >= 3 then vmetric := LowerCase(jargs[2]);
      vdot := 0;
      vna := 0;
      vnb := 0;
      vsum := 0;
      for i := 0 to High(va) do
      begin
        vdot := vdot + va[i] * vb[i];
        vna := vna + va[i] * va[i];
        vnb := vnb + vb[i] * vb[i];
        vsum := vsum + Sqr(va[i] - vb[i]);
      end;
      if (vmetric = 'cosine') or (vmetric = 'cos') then
      begin
        if (vna = 0) or (vnb = 0) then Exit('');
        Exit(VDbFloatToStr(1 - vdot / (Sqrt(vna) * Sqrt(vnb))));
      end;
      if (vmetric = 'dot') or (vmetric = 'ip') then
        Exit(VDbFloatToStr(vdot));
      if (vmetric = 'l1') or (vmetric = 'manhattan') then
      begin
        vsum := 0;
        for i := 0 to High(va) do
          vsum := vsum + Abs(va[i] - vb[i]);
        Exit(VDbFloatToStr(vsum));
      end;
      if (vmetric = 'l2') or (vmetric = 'euclidean') then
        Exit(VDbFloatToStr(Sqrt(vsum)));
      Exit('');
    end
    // ---- M5: temel tam metin arama (index yok; satir uzerinde) ----
    else if (fn.FuncName = 'TO_TSVECTOR') or (fn.FuncName = 'TS_MATCH') or
            (fn.FuncName = 'TS_RANK') then
    begin
      SetLength(jargs, 0);
      if fn.Args <> nil then
      begin
        SetLength(jargs, fn.Args.Count);
        for i := 0 to fn.Args.Count - 1 do
          jargs[i] := EvalExpr(fn.Args[i], Row, ColNames, ColTypes);
      end
      else if fn.Arg <> nil then
        jargs := [EvalExpr(fn.Arg, Row, ColNames, ColTypes)];
      if Length(jargs) < 1 then Exit('');
      if fn.FuncName = 'TO_TSVECTOR' then Exit(VDbFtsNormalize(jargs[0]));
      if Length(jargs) < 2 then Exit('');
      if fn.FuncName = 'TS_MATCH' then
        Exit(BoolToStr(VDbFtsMatch(jargs[0], jargs[1]), True));
      Exit(IntToStr(VDbFtsRank(jargs[0], jargs[1])));
    end
    // ---- F-23: XML fonksiyonlari ----
    else if (fn.FuncName = 'DISTANCE') or (fn.FuncName = 'HAVERSINE') or
          (fn.FuncName = 'IN_CIRCLE') or (fn.FuncName = 'IN_BOX') or
          (fn.FuncName = 'IN_POLYGON') or (fn.FuncName = 'AREA_POLYGON') then
    begin
      SetLength(xargs, fn.Args.Count);
      for i := 0 to fn.Args.Count - 1 do
        xargs[i] := EvalExpr(fn.Args[i], Row, ColNames, ColTypes);
      if fn.FuncName = 'DISTANCE' then
      begin
        if Length(xargs) < 4 then Exit('');
        if not (VDbParseFloat(xargs[0], fa) and VDbParseFloat(xargs[1], fb) and
                VDbParseFloat(xargs[2], fc) and VDbParseFloat(xargs[3], fd)) then Exit('');
        Exit(VDbFloatToStr(VDbDistance(fa, fb, fc, fd)));
      end
      else if fn.FuncName = 'HAVERSINE' then
      begin
        if Length(xargs) < 4 then Exit('');
        if not (VDbParseFloat(xargs[0], fa) and VDbParseFloat(xargs[1], fb) and
                VDbParseFloat(xargs[2], fc) and VDbParseFloat(xargs[3], fd)) then Exit('');
        Exit(VDbFloatToStr(VDbHaversine(fa, fb, fc, fd)));
      end
      else if fn.FuncName = 'IN_CIRCLE' then
      begin
        if Length(xargs) < 5 then Exit('');
        if not (VDbParseFloat(xargs[0], fa) and VDbParseFloat(xargs[1], fb) and
                VDbParseFloat(xargs[2], fc) and VDbParseFloat(xargs[3], fd) and
                VDbParseFloat(xargs[4], fe)) then Exit('');
        Exit(BoolToStr(VDbInCircle(fa, fb, fc, fd, fe), True));
      end
      else if fn.FuncName = 'IN_BOX' then
      begin
        if Length(xargs) < 6 then Exit('');
        if not (VDbParseFloat(xargs[0], fa) and VDbParseFloat(xargs[1], fb) and
                VDbParseFloat(xargs[2], fc) and VDbParseFloat(xargs[3], fd) and
                VDbParseFloat(xargs[4], fe) and VDbParseFloat(xargs[5], fg)) then Exit('');
        Exit(BoolToStr(VDbInBox(fa, fb, fc, fd, fe, fg), True));
      end
      else if fn.FuncName = 'IN_POLYGON' then
      begin
        if Length(xargs) < 3 then Exit('');
        if not (TryStrToFloat(xargs[0], fa) and TryStrToFloat(xargs[1], fb)) then Exit('');
        Exit(BoolToStr(VDbInPolygon(fa, fb, xargs[2]), True));
      end
      else if fn.FuncName = 'AREA_POLYGON' then
      begin
        if Length(xargs) < 1 then Exit('');
        Exit(VDbFloatToStr(VDbAreaPolygon(xargs[0])));
      end
      else
        Exit('');
    end
    else if Copy(fn.FuncName, 1, 3) = 'XML' then
    begin
      // degisken argumanli yol: Args
      SetLength(xargs, fn.Args.Count);
      for i := 0 to fn.Args.Count - 1 do
        xargs[i] := EvalExpr(fn.Args[i], Row, ColNames, ColTypes);
      if fn.FuncName = 'XMLELEMENT' then
      begin
        if Length(xargs) < 1 then Exit('');
        // icerikler birlestirilir (ara metin bosluk eklenmez)
        xpart := '';
        for i := 1 to High(xargs) do xpart := xpart + xargs[i];
        Exit(VDbXmlElement(xargs[0], xpart));
      end
      else if fn.FuncName = 'XMLCONCAT' then
        Exit(VDbXmlConcat(xargs))
      else if fn.FuncName = 'XMLESCAPE' then
      begin
        if Length(xargs) = 0 then Exit('');
        Exit(VDbXmlEscape(xargs[0]));
      end
      else if fn.FuncName = 'XMLPARSE' then
      begin
        // gecerli XML mi? gecersizse NULL (PostgreSQL XMLPARSE davranisi
        // yaklasimi: hata yerine NULL, sorgu kirilmaz)
        if Length(xargs) = 0 then Exit('');
        if VDbXmlParse(xargs[0], xroot) then
        begin
          VDbXmlFree(xroot);
          Exit(xargs[0]);
        end;
        Exit('');
      end
      else if (Length(xargs) >= 2) and (fn.FuncName <> 'XMLATTR') then
      begin
        // Sorgu fonksiyonlari: once XML ayristirilir
        if not VDbXmlParse(xargs[0], xroot) then Exit('');
        try
          if fn.FuncName = 'XMLEXTRACT' then
          begin
            xn := VDbXmlFind(xroot, xargs[1], True);
            if xn = nil then Exit('');
            Exit(xn.Text);
          end
          else if fn.FuncName = 'XMLEXISTS' then
          begin
            xn := VDbXmlFind(xroot, xargs[1], True);
            Exit(BoolToStr(xn <> nil, True));
          end
          else if fn.FuncName = 'XMLCOUNT' then
            Exit(IntToStr(VDbXmlCount(xroot, xargs[1])))
          else
            Exit('');
        finally
          VDbXmlFree(xroot);
        end;
      end
      else if (Length(xargs) >= 3) and (fn.FuncName = 'XMLATTR') then
      begin
        if not VDbXmlParse(xargs[0], xroot) then Exit('');
        try
          xn := VDbXmlFind(xroot, xargs[1], True);
          if xn = nil then Exit('');
          // nitelik YOKSA NULL doner (PostgreSQL davranisi)
          if not xn.HasAttr(xargs[2]) then Exit('');
          Exit(xn.Attr(xargs[2]));
        finally
          VDbXmlFree(xroot);
        end;
      end
      else
        Exit('');
    end
    else Exit(lv); // COUNT/SUM/AVG/MIN/MAX: ExecGroupBy'da degerlendirilir
  end;

  if Expr is TSqlCaseNode then
  begin
    // P5-3: aranan (WHEN kosul) ve sade (CASE x WHEN deger) bicimler.
    // ELSE yoksa sonuc NULL'dur. Sade bicimde NULL eslesmez.
    csN := TSqlCaseNode(Expr);
    if csN.Operand <> nil then
    begin
      ov := EvalExpr(csN.Operand, Row, ColNames, ColTypes);
      ct := VCT_STR;
      if csN.Operand is TSqlColumnRefNode then
      begin
        colRef := TSqlColumnRefNode(csN.Operand);
        for i := 0 to High(ColNames) do
          if SameText(colRef.ColumnName, ColNames[i]) and (i < Length(ColTypes)) then
          begin ct := ColTypes[i]; Break; end;
      end;
    end;
    for i := 0 to csN.Whens.Count - 1 do
    begin
      if csN.Operand <> nil then
      begin
        wv := EvalExpr(csN.Whens[i].Cond, Row, ColNames, ColTypes);
        if (ov <> '') and (wv <> '') and VDbCmpVal(ov, wv, '=', ct) then
          Exit(EvalExpr(csN.Whens[i].Value, Row, ColNames, ColTypes));
      end
      else if EvalBool(csN.Whens[i].Cond, Row, ColNames, ColTypes) then
        Exit(EvalExpr(csN.Whens[i].Value, Row, ColNames, ColTypes));
    end;
    if csN.ElseExpr <> nil then
      Exit(EvalExpr(csN.ElseExpr, Row, ColNames, ColTypes));
    Exit('');
  end;

  // F-02: NULLIF(a,b) â€” a=b ise NULL, degilse a
  if Expr is TSqlNullIfNode then
  begin
    ov := EvalExpr(TSqlNullIfNode(Expr).Arg1, Row, ColNames, ColTypes);
    wv := EvalExpr(TSqlNullIfNode(Expr).Arg2, Row, ColNames, ColTypes);
    if (ov <> '') and (wv <> '') and VDbCmpVal(ov, wv, '=', VCT_STR) then
      Exit('');
    Exit(ov);
  end;

  // F-02: COALESCE(a,b,c,...) â€” ilk non-NULL
  if Expr is TSqlCoalesceNode then
  begin
    for i := 0 to TSqlCoalesceNode(Expr).Args.Count - 1 do
    begin
      ov := EvalExpr(TSqlCoalesceNode(Expr).Args[i], Row, ColNames, ColTypes);
      if ov <> '' then Exit(ov);
    end;
    Exit('');
  end;

  // F-22: JSONB ANAHTAR LISTESI â€” `col ?| ('a','b')` / `col ?& ('a','b')`
  if Expr is TSqlJsonKeyNode then
  begin
    jk := TSqlJsonKeyNode(Expr);
    jv := EvalExpr(jk.Left, Row, ColNames, ColTypes);
    // SQL NULL: JSON metni NULL ise sonuc UNKNOWN
    if jv = '' then Exit('');
    // NULL anahtar bir listede UNKNOWN uretir; PostgreSQL bunu yok sayar
    SetLength(jkeys, jk.Keys.Count);
    nk := 0;
    for i := 0 to jk.Keys.Count - 1 do
    begin
      jw := EvalExpr(jk.Keys[i], Row, ColNames, ColTypes);
      if jw <> '' then
      begin
        jkeys[nk] := jw;
        Inc(nk);
      end;
    end;
    SetLength(jkeys, nk);
    if jk.RequireAll then
      Exit(BoolToStr(VDbJsonAllKeysStr(jv, jkeys), True))
    else
      Exit(BoolToStr(VDbJsonAnyKeyStr(jv, jkeys), True));
  end;

  if Expr is TSqlWindowNode then
    // P5-WIN: pencere yalniz projeksiyonda tuketilir; satir-basi
    // degerlendirme anlamsizdir (CheckWindowPlacement bunu onceden eler).
    raise EVDbException.Create(ecUnsupported,
      'pencere fonksiyonu yalnizca SELECT listesinde kullanilabilir');

  Result := '';
end;

{ ------------------------------------------------------------
  SubResult (P5-2)
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ValidateSubquery(Sel: TSqlSelectStmt);

  procedure CheckSelect(S: TSqlSelectStmt); forward;

  function InScope(const Qual: string; const Tabs: TStrArray): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    for k := 0 to High(Tabs) do
      if (Tabs[k] <> '') and SameText(Tabs[k], Qual) then
        Exit(True);
  end;

  procedure CheckExpr(E: TSqlExprNode; const Tabs: TStrArray);
  var
    k: Integer;
    C: TSqlColumnRefNode;
  begin
    if E = nil then Exit;
    if E is TSqlColumnRefNode then
    begin
      C := TSqlColumnRefNode(E);
      // F-03: Ä°liÅŸkili alt sorgu desteÄŸi â€” dÄ±ÅŸ tablo referansÄ±na izin ver.
      // InScope kontrolÃ¼ kaldÄ±rÄ±ldÄ±; dÄ±ÅŸ tablo referansÄ± SubResult'ta Ã§Ã¶zÃ¼lÃ¼r.
      // if (C.TableQualifier <> '') and not InScope(C.TableQualifier, Tabs) then
      //   raise EVDbException.Create(ecUnsupported,
      //     'iliskili alt sorgu desteklenmiyor (dis tablo: ' +
      //     C.TableQualifier + ')');
    end
    else if E is TSqlBinaryOpNode then
    begin
      CheckExpr(TSqlBinaryOpNode(E).Left, Tabs);
      CheckExpr(TSqlBinaryOpNode(E).Right, Tabs);
    end
    else if E is TSqlUnaryOpNode then
      CheckExpr(TSqlUnaryOpNode(E).Operand, Tabs)
    else if E is TSqlInNode then
    begin
      CheckExpr(TSqlInNode(E).Expr, Tabs);
      for k := 0 to TSqlInNode(E).List.Count - 1 do
        CheckExpr(TSqlInNode(E).List[k], Tabs);
      if TSqlInNode(E).SubSelect <> nil then
        CheckSelect(TSqlInNode(E).SubSelect);
    end
    else if E is TSqlBetweenNode then
    begin
      CheckExpr(TSqlBetweenNode(E).Expr, Tabs);
      CheckExpr(TSqlBetweenNode(E).LowBound, Tabs);
      CheckExpr(TSqlBetweenNode(E).HighBound, Tabs);
    end
    else if E is TSqlFuncCallNode then
      CheckExpr(TSqlFuncCallNode(E).Arg, Tabs)
    else if E is TSqlWindowNode then
    begin
      CheckExpr(TSqlWindowNode(E).Arg, Tabs);
      CheckExpr(TSqlWindowNode(E).Default, Tabs);
      for k := 0 to TSqlWindowNode(E).Partitions.Count - 1 do
        CheckExpr(TSqlWindowNode(E).Partitions[k], Tabs);
      for k := 0 to TSqlWindowNode(E).OrderBys.Count - 1 do
        CheckExpr(TSqlWindowNode(E).OrderBys[k].Expr, Tabs);
    end
    else if E is TSqlCaseNode then
    begin
      CheckExpr(TSqlCaseNode(E).Operand, Tabs);
      for k := 0 to TSqlCaseNode(E).Whens.Count - 1 do
      begin
        CheckExpr(TSqlCaseNode(E).Whens[k].Cond, Tabs);
        CheckExpr(TSqlCaseNode(E).Whens[k].Value, Tabs);
      end;
      CheckExpr(TSqlCaseNode(E).ElseExpr, Tabs);
    end
    else if E is TSqlSubqueryNode then
      CheckSelect(TSqlSubqueryNode(E).Select);
  end;

  procedure CheckSelect(S: TSqlSelectStmt);
  var
    Tabs: TStrArray;
    k: Integer;
    CteNm: string;

    procedure AddTab(const T, A: string);
    begin
      if T <> '' then
      begin
        SetLength(Tabs, Length(Tabs) + 1);
        Tabs[High(Tabs)] := T;
      end;
      if A <> '' then
      begin
        SetLength(Tabs, Length(Tabs) + 1);
        Tabs[High(Tabs)] := A;
      end;
    end;

  begin
    if S = nil then Exit;
    SetLength(Tabs, 0);
    AddTab(S.FromTable, S.FromAlias);
    if S.HasJoin then
    begin
      AddTab(S.Join.Table, S.Join.Alias);
      for k := 0 to S.MoreJoins.Count - 1 do
        AddTab(S.MoreJoins[k].Table, S.MoreJoins[k].Alias);
      CheckExpr(S.Join.OnCondition, Tabs);
      for k := 0 to S.MoreJoins.Count - 1 do
        CheckExpr(S.MoreJoins[k].OnCondition, Tabs);
    end;
    // Kapsamdaki CTE adlari da gecerli niteleyicidir (materyal sirada
    // biriktigi icin FCteTables o an gorunur olanlari icerir).
    if FCteTables <> nil then
      for CteNm in FCteTables.Keys do
      begin
        SetLength(Tabs, Length(Tabs) + 1);
        Tabs[High(Tabs)] := CteNm;
      end;
    for k := 0 to S.Columns.Count - 1 do
      CheckExpr(S.Columns[k].Expr, Tabs);
    CheckExpr(S.WhereClause, Tabs);
    CheckExpr(S.HavingClause, Tabs);
    if S.OrderBy <> nil then
      for k := 0 to S.OrderBy.Count - 1 do
        CheckExpr(S.OrderBy[k].Expr, Tabs);
    if S.RightSelect <> nil then
      CheckSelect(S.RightSelect);
  end;

begin
  CheckSelect(Sel);
end;

{ ------------------------------------------------------------
  IsCorrelatedSel (F-03)
  Alt sorgu dis satira bagli mi? Kendi tablolari disinda nitelikli
  bir kolon referansi varsa iliskilidir -> sonuc onbelleklenmez.
  //---------------------------------------------------------- }
function TVSqlExecutor.IsCorrelatedSel(Sel: TSqlSelectStmt): Boolean;
var
  Own: TStrArray;
  k, i: Integer;

  procedure AddTab(const T, A: string);
  begin
    if T <> '' then
    begin
      SetLength(Own, Length(Own) + 1);
      Own[High(Own)] := VDbNorm(T);
    end;
    if A <> '' then
    begin
      SetLength(Own, Length(Own) + 1);
      Own[High(Own)] := VDbNorm(A);
    end;
  end;

  function InOwn(const Q: string): Boolean;
  var t: Integer;
  begin
    Result := False;
    for t := 0 to High(Own) do
      if Own[t] = Q then Exit(True);
  end;

  // Recursive walker: qualified colref outside own scope => correlated.
  function Walk(E: TSqlExprNode): Boolean;
  var
    iw: Integer;
  begin
    Result := False;
    if E = nil then Exit;
    if E is TSqlColumnRefNode then
    begin
      // sade (niteliksiz) referans dis satira ait olamaz -> iliskili degil
      if TSqlColumnRefNode(E).TableQualifier <> '' then
        if not InOwn(VDbNorm(TSqlColumnRefNode(E).TableQualifier)) then
          Exit(True);
      Exit;
    end;
    if E is TSqlBinaryOpNode then
    begin
      if Walk(TSqlBinaryOpNode(E).Left) or Walk(TSqlBinaryOpNode(E).Right) then Exit(True);
    end
    else if E is TSqlUnaryOpNode then
    begin
      if Walk(TSqlUnaryOpNode(E).Operand) then Exit(True);
    end
    else if E is TSqlInNode then
    begin
      if Walk(TSqlInNode(E).Expr) then Exit(True);
      for iw := 0 to TSqlInNode(E).List.Count - 1 do
        if Walk(TSqlInNode(E).List[iw]) then Exit(True);
      if (TSqlInNode(E).SubSelect <> nil) and IsCorrelatedSel(TSqlInNode(E).SubSelect) then
        Exit(True);
    end
    else if E is TSqlBetweenNode then
    begin
      if Walk(TSqlBetweenNode(E).Expr) or Walk(TSqlBetweenNode(E).LowBound) or
         Walk(TSqlBetweenNode(E).HighBound) then Exit(True);
    end
    else if E is TSqlFuncCallNode then
    begin
      if Walk(TSqlFuncCallNode(E).Arg) then Exit(True);
    end
    else if E is TSqlCaseNode then
    begin
      if Walk(TSqlCaseNode(E).Operand) then Exit(True);
      for iw := 0 to TSqlCaseNode(E).Whens.Count - 1 do
        if Walk(TSqlCaseNode(E).Whens[iw].Cond) or Walk(TSqlCaseNode(E).Whens[iw].Value) then
          Exit(True);
      if Walk(TSqlCaseNode(E).ElseExpr) then Exit(True);
    end
    else if E is TSqlWindowNode then
    begin
      if Walk(TSqlWindowNode(E).Arg) or Walk(TSqlWindowNode(E).Default) then Exit(True);
      for iw := 0 to TSqlWindowNode(E).Partitions.Count - 1 do
        if Walk(TSqlWindowNode(E).Partitions[iw]) then Exit(True);
      for iw := 0 to TSqlWindowNode(E).OrderBys.Count - 1 do
        if Walk(TSqlWindowNode(E).OrderBys[iw].Expr) then Exit(True);
    end
    else if E is TSqlSubqueryNode then
    begin
      if IsCorrelatedSel(TSqlSubqueryNode(E).Select) then Exit(True);
    end;
  end;

begin
  Result := False;
  if Sel = nil then Exit;
  SetLength(Own, 0);
  AddTab(Sel.FromTable, Sel.FromAlias);
  if Sel.HasJoin then
  begin
    AddTab(Sel.Join.Table, Sel.Join.Alias);
    for k := 0 to Sel.MoreJoins.Count - 1 do
      AddTab(Sel.MoreJoins[k].Table, Sel.MoreJoins[k].Alias);
  end;
  // CTE isimleri de kendi kapsaminda sayilir.
  for k := 0 to Sel.WithQueries.Count - 1 do
    AddTab(Sel.WithQueries[k].Name, '');
  // Ana ifadeler + ON/WHERE/HAVING/ORDER BY kontrol edilir.
  if Sel = nil then Exit;
  for i := 0 to Sel.Columns.Count - 1 do
    if Walk(Sel.Columns[i].Expr) then Exit(True);
  if Sel.HasJoin then
  begin
    if Walk(Sel.Join.OnCondition) then Exit(True);
    for k := 0 to Sel.MoreJoins.Count - 1 do
      if Walk(Sel.MoreJoins[k].OnCondition) then Exit(True);
  end;
  if Walk(Sel.WhereClause) then Exit(True);
  if Walk(Sel.HavingClause) then Exit(True);
  for k := 0 to Sel.OrderBy.Count - 1 do
    if Walk(Sel.OrderBy[k].Expr) then Exit(True);
  if (Sel.RightSelect <> nil) and IsCorrelatedSel(Sel.RightSelect) then Exit(True);
end;

function TVSqlExecutor.SubResult(Sel: TSqlSelectStmt; const OuterRow: TStrArray = nil; const OuterColNames: TStrArray = nil): TSqlResult;
var
  SavedOuterRow: TStrArray;
  SavedOuterColNames: TStrArray;
  SavedQualifier: string;
begin
  // Correlated subqueries (OuterRow <> nil) cannot be cached - must re-execute per outer row
  if (OuterRow = nil) and (not FNoSubCache) and (FSubCache <> nil) and
     FSubCache.TryGetValue(Pointer(Sel), Result) then
    Exit;
  ValidateSubquery(Sel);
  // Save current outer context
  SavedOuterRow := FOuterRow;
  SavedOuterColNames := FOuterColNames;
  SavedQualifier := FCurQualifier;
  try
    FOuterRow := OuterRow;
    FOuterColNames := OuterColNames;
    // F-03: ic SELECT'in kendi tablosu/alias'i (kapsam denetimi icin).
    if Sel.FromAlias <> '' then FCurQualifier := Sel.FromAlias
    else FCurQualifier := Sel.FromTable;
    ExecSelect(Sel, Result);
  finally
    FOuterRow := SavedOuterRow;
    FOuterColNames := SavedOuterColNames;
    FCurQualifier := SavedQualifier;
  end;
  // F2-20: alt sorgu sonucu sinirli.
  if Length(Result.Rows) > VDB_MAX_RESULT_ROWS then
    raise EVDbException.CreateFmt(ecLimit,
      'alt sorgu sonucu cok buyuk (%d > %d satir)',
      [Length(Result.Rows), VDB_MAX_RESULT_ROWS]);
  if (OuterRow = nil) and (not FNoSubCache) and (FSubCache <> nil) then
  begin
    if FSubCache.ContainsKey(Pointer(Sel)) then
      FSubCache[Pointer(Sel)] := Result
    else
      FSubCache.Add(Pointer(Sel), Result);
  end;
end;

{ ------------------------------------------------------------
  CTE yardimcilari (P5-CTE)
  //---------------------------------------------------------- }
function TVSqlExecutor.TryCte(const TableName: string; out Names: TStrArray;
  out Types: TByteArray; out Rows: TStrMatrix): Boolean;
var
  T: TCteTable;
begin
  Result := False;
  if (FCteTables <> nil) and
     FCteTables.TryGetValue(VDbNorm(TableName), T) then
  begin
    Names := T.Names;
    Types := T.Types;
    Rows := T.Rows;
    Result := True;
  end;
end;

procedure TVSqlExecutor.CteColTypes(Sel: TSqlSelectStmt;
  const Fields: TStrArray; out Types: TByteArray);
// Ic sorgu ciktisinin mumkun olan en iyi tipleri: sade kolonlar kaynaktan,
// COUNT(*) tamsayi, SUM/AVG gercek sayi; gerisi metin. Amac: dis sorguda
// sayisal kiyas/siralama dogru calissin ('10' > '2' sayisal).
var
  i: Integer;
  Td: TTableDef;
  Ref: TSqlColumnRefNode;
  Fn: TSqlFuncCallNode;
  L: TSqlLiteralNode;

  function SrcCol(const Nm: string; out Ct: Byte): Boolean;
  var
    q: Integer;
  begin
    Result := False;
    for q := 0 to High(Td.Cols) do
      if SameText(Td.Cols[q].Name, Nm) then
      begin Ct := Td.Cols[q].Ctype; Exit(True); end;
  end;

begin
  SetLength(Types, Length(Fields));
  for i := 0 to High(Types) do
    Types[i] := VCT_STR;
  // R-10: Once SAF LITERAL sutunlarin tipini cikar. Anchor cogu kez
  // FROM'suzdur (`SELECT 1 UNION ALL ...`); asagidaki tablo tabanli
  // cikarimdan ONCE yapilmazsa sayisal anchor metin sanilir ve
  // `n < 10` kiyaslamasi metin kiyaslamasina duser.
  if Sel.Columns.Count = Length(Fields) then
    for i := 0 to Sel.Columns.Count - 1 do
      if Sel.Columns[i].Expr is TSqlLiteralNode then
      begin
        L := TSqlLiteralNode(Sel.Columns[i].Expr);
        if L.LitType = sltInt then
          Types[i] := VCT_INT
        else if L.LitType = sltFloat then
          Types[i] := VCT_FLOAT;
      end;
  if (Sel.FromTable = '') or Sel.HasJoin then Exit;
  try
    Td := FT.GetTable(Sel.FromTable);
  except
    Exit;
  end;
  if Sel.Columns.Count = 0 then
  begin
    // SELECT *: cikti = sema sirasi
    if Length(Fields) <> Length(Td.Cols) then Exit;
    for i := 0 to High(Td.Cols) do
      Types[i] := Td.Cols[i].Ctype;
    Exit;
  end;
  if Sel.Columns.Count <> Length(Fields) then Exit;
  for i := 0 to Sel.Columns.Count - 1 do
  begin
    if Sel.Columns[i].Expr is TSqlColumnRefNode then
    begin
      Ref := TSqlColumnRefNode(Sel.Columns[i].Expr);
      SrcCol(Ref.ColumnName, Types[i]);
    end
    else if Sel.Columns[i].Expr is TSqlFuncCallNode then
    begin
      Fn := TSqlFuncCallNode(Sel.Columns[i].Expr);
      if SameText(Fn.FuncName, 'COUNT') then
        Types[i] := VCT_INT
      else if SameText(Fn.FuncName, 'SUM') or SameText(Fn.FuncName, 'AVG') then
        Types[i] := VCT_FLOAT;
    end;
  end;
end;

function TVSqlExecutor.CteIsRecursive(const W: TWithQuery): Boolean;
begin
  Result := (W.Select <> nil) and (W.Select.SetOp = sokUnionAll) and
            (W.Select.RightSelect <> nil);
end;

procedure TVSqlExecutor.RunRecursiveCte(Stmt: TSqlSelectStmt; Idx: Integer);
{ R-10: gercek ozyineleme + CYCLE tespiti.

  anchor   = W.Select            (kendini gormeyen ilk SELECT)
  recTerm  = W.Select.RightSelect (kendine bakan ikinci SELECT)
  Calisma: anchor satirlari calisma tablosuna yazilir; ozyinelemeli
  terim calisma tablosunu okuyup YENI satirlari uretir ve bunlar
  calisma tablosuna eklenir. Yeni satir uretilmezse dongu biter.

  CYCLE: `CYCLE c SET ic USING path` verildiginde c degeri daha once
  gorulduyse o satir is_cycle=True isaretlenir ve calisma tablosuna
  TEKRAR YAZILMAZ -> dongu orada kesilir. Boylece `WHERE n < 1` gibi
  bir kosulun YAZILMADIGI `SELECT n+1 FROM r` ifadesi sonsuz donguye
  girmez ve motor kendi kendine durur.

  BILINEN SADELESTIRME: UNION ALL zincirinde bir satirin "basi" tek
  degildir (bag semantigi). Bu yuzden `path`, degerin ilk goruldugu
  andaki zincir olarak kurulur; PostgreSQL'in yol basina ayri sayma
  semantigi degil. Dongu tespiti ve sonuc KUMESI ayni sonucu verir.
}
const
  VDB_RECUR_MAX = 100000;
var
  W: TWithQuery;
  anchorR, stepR: TSqlResult;
  T: TCteTable;
  i, j, k, cycIx, it, guard, nAll: Integer;
  Nm: string;
  savedNoMerge: Boolean;
  savedNoCache: Boolean;
  names: TStrArray;
  allRows, deltaRows: TStrMatrix;
  step: TStrArray;
  cv: string;
  hasCycle, isCyc: Boolean;
  seenVals: TDictionary<string, Boolean>;
  added: Boolean;
begin
  W := Stmt.WithQueries[Idx];
  Nm := VDbNorm(W.Name);

  // --- 1) anchor (SET OP birlestirmesi YAPILMAZ) ---
  savedNoMerge := FNoSetOpMerge;
  FNoSetOpMerge := True;
  try
    anchorR := SubResult(W.Select);
  finally
    FNoSetOpMerge := savedNoMerge;
  end;
  names := anchorR.Fields;
  if (Length(W.ColAliases) > 0) and (Length(W.ColAliases) = Length(names)) then
    for i := 0 to High(names) do names[i] := W.ColAliases[i];

  hasCycle := (W.CycleCol <> '') and (W.IsCycleCol <> '');
  cycIx := -1;
  if hasCycle then
  begin
    cycIx := FindColIdx(W.CycleCol, '', names);
    if cycIx < 0 then
      raise EVDbException.Create(ecColumnNotFound,
        'CYCLE kolonu "' + W.CycleCol + '" CTE sonucunda yok');
  end;

  // anchor satirlari da CYLE sutunlariyla ayni GENISLIKTE olmali;
// aksi halde sonucta sutun sayisi ile satir uzunlugu uyusmaz.
  SetLength(allRows, Length(anchorR.Rows));
  for i := 0 to High(anchorR.Rows) do
  begin
    SetLength(step, Length(anchorR.Rows[i]));
    for j := 0 to High(anchorR.Rows[i]) do step[j] := anchorR.Rows[i][j];
    if hasCycle then
    begin
      SetLength(step, Length(step) + 2);
      cv := step[High(anchorR.Rows[i])];
      step[Length(names)] := 'False';
      step[Length(names) + 1] := '';
    end;
    allRows[i] := step;
  end;

  T.Names := names;
  CteColTypes(W.Select, names, T.Types);
  // ozyineleme sirasinda CTE tablosu DELTA (yalnizca yeni satirlar)
  // olarak gorunur. Tum calisma tablosunu her turda tekrar okutmak
  // (naif semantik) hem cok yavas hem pratikte bitmez:
  //   WITH r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<5)
  // naif yontemde satir sayisi 1,2,4,8,... diye buyuyor ve WHERE
  // filtrelenedigi degerler calisma tablosunda birikiyor.
  // DELTA (semi-naive) degerlendirme ayni sonucu Ucuz verir.
  SetLength(deltaRows, 0);
  for i := 0 to High(anchorR.Rows) do
  begin
    SetLength(deltaRows, Length(deltaRows) + 1);
    deltaRows[High(deltaRows)] := allRows[i];
  end;

  seenVals := TDictionary<string, Boolean>.Create;
  try
    if hasCycle then
      for i := 0 to High(allRows) do
        seenVals.AddOrSetValue(allRows[i][cycIx], True);

    savedNoCache := FNoSubCache;
    FNoSubCache := True;
    guard := 0;
    try
      while (guard < VDB_RECUR_MAX) and (Length(deltaRows) > 0) do
      begin
        Inc(guard);
        // calisma tablosunu DELTA olarak yaz
        T.Rows := deltaRows;
        if FCteTables.ContainsKey(Nm) then FCteTables[Nm] := T
        else FCteTables.Add(Nm, T);

        stepR := SubResult(W.Select.RightSelect);
        if Length(stepR.Rows) = 0 then Break;

        SetLength(deltaRows, Length(stepR.Rows));
        for i := 0 to High(stepR.Rows) do
        begin
          step := Copy(stepR.Rows[i], 0, Length(stepR.Rows[i]));
          isCyc := False;
          if hasCycle then
          begin
            SetLength(step, Length(step) + 2);
            cv := stepR.Rows[i][cycIx];
            if seenVals.ContainsKey(cv) then
            begin
              isCyc := True;
              step[Length(names)] := 'True';
              step[Length(names) + 1] := cv;
            end
            else
            begin
              seenVals.AddOrSetValue(cv, True);
              step[Length(names)] := 'False';
              step[Length(names) + 1] := '';
            end;
          end;
          deltaRows[i] := step;
          SetLength(allRows, Length(allRows) + 1);
          allRows[High(allRows)] := step;
        end;
      end;
    finally
      FNoSubCache := savedNoCache;
    end;

    // --- sonuc: tum satirlar + CYCLE sutunlari ---
    T.Rows := allRows;
    if hasCycle then
    begin
      j := Length(T.Names);
      SetLength(T.Names, j + 2);
      T.Names[j] := W.IsCycleCol;
      T.Names[j + 1] := W.PathCol;
      j := Length(T.Types);
      SetLength(T.Types, j + 2);
      T.Types[j] := VCT_STR;
      T.Types[j + 1] := VCT_STR;
    end;
    if FCteTables.ContainsKey(Nm) then FCteTables[Nm] := T
    else FCteTables.Add(Nm, T);
  finally
    seenVals.Free;
  end;
end;

procedure TVSqlExecutor.MaterializeCtes(Stmt: TSqlSelectStmt);
var
  i, iter, maxIter, it: Integer;
  R: TSqlResult;
  T: TCteTable;
  Nm, SeenCteNames: string;
  CteSeen: Boolean;
begin
  if (Stmt.WithQueries.Count = 0) or (FCteTables = nil) then Exit;
  for i := 0 to Stmt.WithQueries.Count - 1 do
  begin
    Nm := VDbNorm(Stmt.WithQueries[i].Name);
    // R-10: gercek ozyineleme (anchor UNION ALL terim) varsa onu calistir
    // ve bu CTE icin ESKI sahte dongeden gec.
    if CteIsRecursive(Stmt.WithQueries[i]) then
    begin
      RunRecursiveCte(Stmt, i);
      Continue;
    end;
    // F-32: CYCLE detection - recursive CTE'de aynı isim tekrar ederse sonsuz döngü
    CteSeen := False;
    if Stmt.WithQueries[i].IsRecursive then
    begin
      // Bu CTE'nin daha oncegorulup görülmediğini takip et
      // SeenNames her iterasyonda sıfırlanmaz, recursive CTE'ler arası cycle tespiti için
      if Pos(Nm, FSeenCteNames) > 0 then
        CteSeen := True;
      FSeenCteNames := FSeenCteNames + Nm + ';';
    end;
    maxIter := 10; // 4.5: recursive CTE limit artırıldı (F-30)
    iter := 0;
    repeat
      // F-32: CYCLE detection - cycle tespitildiyse döngüyü kır
      if CteSeen then Break;
      R := SubResult(Stmt.WithQueries[i].Select);
      // 4.5: kolon alias'lari
      if (Length(Stmt.WithQueries[i].ColAliases) > 0) and
         (Length(Stmt.WithQueries[i].ColAliases) = Length(R.Fields)) then
        for it := 0 to High(R.Fields) do
          R.Fields[it] := Stmt.WithQueries[i].ColAliases[it];
    T.Names := R.Fields;
    T.Rows := R.Rows;
    CteColTypes(Stmt.WithQueries[i].Select, R.Fields, T.Types);
    if FCteTables.ContainsKey(Nm) then
      FCteTables[Nm] := T
    else
      FCteTables.Add(Nm, T);
    Inc(iter);
    // 4.5 recursive: previous result feeds back; maxIter stops loop.
    if (Stmt.WithQueries[i].IsRecursive) and (iter < maxIter) then
    begin
      // F-31: MATERIALIZE / NOT MATERIALIZE kontrolu
      if Stmt.WithQueries[i].Materialize then
      begin
        // Materialize: once materialize edip sonraya koy
        if not FCteTables.ContainsKey(Nm) then
        begin
          R := SubResult(Stmt.WithQueries[i].Select);
          // ... existing materialization code ...
          FCteTables.Add(Nm, T);
        end;
        // Her iterasyonda aynı tabloyu kullan
        Break; // Materialize CTE sadece bir kez calisir
      end
      else
      begin
        // NOT MATERIALIZE: her iterasyondan yeniden materialize
        R := SubResult(Stmt.WithQueries[i].Select);
        // ... mevcut kod ...
        Continue; // Devam et, tekrar materialize et
      end;
    end
    else
      Break;
    until False;
  end;
end;

function TVSqlExecutor.EvalBool(Expr: TSqlExprNode; const Row: TStrArray;
  const ColNames: TStrArray; const ColTypes: TByteArray): Boolean;
var s: string;
begin
  if Expr = nil then Exit(True);
  s := EvalExpr(Expr, Row, ColNames, ColTypes);
  Result := SameText(s, 'True') or (s = '1');
end;

{ ------------------------------------------------------------
  RowMatches
  //---------------------------------------------------------- }
function TVSqlExecutor.RowMatches(WhereClause: TSqlExprNode;
  const Row: TStrArray; const ColNames: TStrArray; const ColTypes: TByteArray): Boolean;
begin
  Result := EvalBool(WhereClause, Row, ColNames, ColTypes);
end;

{ ------------------------------------------------------------
  ApplyQualify (F-09)
  QUALIFY filtresini filteredRows uzerinde uygular ve pencere
  degerlerini (WinVals) ayni indekslere tasir.
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ApplyQualify(Stmt: TSqlSelectStmt;
  var Rows: TStrMatrix; const ColNames: TStrArray;
  const ColTypes: TByteArray; var WinVals: TStrMatrix;
  const WinSlot: TIntArray);
var
  i, j, qn: Integer;
  keep: TIntArray;
  newRows: TStrMatrix;
  newWin: TStrMatrix;
begin
  if Stmt.QualifyClause = nil then Exit;
  if not HasWindow(Stmt) then
    raise EVDbException.Create(ecUnsupported,
      'QUALIFY yalnizca pencere fonksiyonu iceren sorgularda kullanilabilir');
  SetLength(FStmtColumns, Stmt.Columns.Count);
  for j := 0 to Stmt.Columns.Count - 1 do
    FStmtColumns[j] := Stmt.Columns[j].Expr;
  SetLength(keep, Length(Rows));
  SetLength(newRows, Length(Rows));
  SetLength(newWin, Length(Rows));
  qn := 0;
  for i := 0 to High(Rows) do
    if EvalQualify(Stmt.QualifyClause, Rows[i], ColNames, ColTypes,
                   WinVals, WinSlot, i) then
    begin
      keep[qn] := i;
      newRows[qn] := Rows[i];
      if i < Length(WinVals) then newWin[qn] := WinVals[i];
      Inc(qn);
    end;
  if qn = 0 then Exit;   // hicbir satir elenmedi
  SetLength(Rows, qn);
  for i := 0 to qn - 1 do Rows[i] := newRows[i];
  if Length(WinVals) > 0 then
  begin
    SetLength(WinVals, qn);
    for i := 0 to qn - 1 do WinVals[i] := newWin[i];
  end;
end;

{ ------------------------------------------------------------
  IsSameExpr (F-09)
  Iki AST ifadesi yapisal ayni mi? QUALIFY'daki pencere ile SELECT
  listesindeki pencere AYRI dugumlerdir; Pointer esitligi calismaz.
  Karsilastirma yalniz pencere tanimini (isim + partition + order)
  kapsar: arguman NULL oldugu icin atlanir.
  //---------------------------------------------------------- }
function TVSqlExecutor.IsSameExpr(A, B: TSqlExprNode): Boolean;
var
  wa, wb: TSqlWindowNode;
  i: Integer;
begin
  Result := False;
  if (A = nil) or (B = nil) then Exit(A = B);
  if not ((A is TSqlWindowNode) and (B is TSqlWindowNode)) then
  begin
    // diger turler: metin karsilastirmasi yeterli (column ref / literal)
    Result := SameText(A.ClassName + IntToStr(PtrInt(A)), B.ClassName + IntToStr(PtrInt(B)));
    Exit;
  end;
  wa := TSqlWindowNode(A); wb := TSqlWindowNode(B);
  if wa.FuncName <> wb.FuncName then Exit;
  if wa.Partitions.Count <> wb.Partitions.Count then Exit;
  if wa.OrderBys.Count <> wb.OrderBys.Count then Exit;
  for i := 0 to wa.Partitions.Count - 1 do
    if not IsSameExpr(wa.Partitions[i], wb.Partitions[i]) then Exit;
  for i := 0 to wa.OrderBys.Count - 1 do
  begin
    if wa.OrderBys[i].Desc <> wb.OrderBys[i].Desc then Exit;
    if not IsSameExpr(wa.OrderBys[i].Expr, wb.OrderBys[i].Expr) then Exit;
  end;
  Result := True;
end;

{ ------------------------------------------------------------
  EvalQualify (F-09)
  QUALIFY ifadesi: pencere fonksiyonu cagrilari WinVals uzerinden
  cozulur (normal EvalExpr pencere dugumunde hata verir).
  //---------------------------------------------------------- }
function TVSqlExecutor.EvalQualify(Expr: TSqlExprNode; const Row: TStrArray;
  const ColNames: TStrArray; const ColTypes: TByteArray;
  const WinVals: TStrMatrix; const WinSlot: TIntArray;
  RowIx: Integer): Boolean;
var
  s: string;
  w: TSqlWindowNode;
  slot: Integer;

  // QUALIFY'daki pencere ile SELECT listesindeki pencere AYRI AST
  // dugumleridir (Pointer esitligi calismaz). Bu yuzden yapisal
  // eslestirme yapilir: isim + partition sayisi + order sayisi +
  // partition/order ifadeleri (metin karsilastirmasi).
  function SameExprText(A, B: TSqlExprNode): Boolean;
  begin
    if (A = nil) or (B = nil) then Exit(A = B);
    if A.ClassName <> B.ClassName then Exit(False);
    if A is TSqlColumnRefNode then
      Exit(SameText(TSqlColumnRefNode(A).QualifiedName,
                    TSqlColumnRefNode(B).QualifiedName));
    if A is TSqlLiteralNode then
    begin
      if not (B is TSqlLiteralNode) then Exit(False);
      Exit(TSqlLiteralNode(A).AsString = TSqlLiteralNode(B).AsString);
    end;
    Result := False;
  end;

  function FindWinSlot(WN: TSqlWindowNode): Integer;
  var
    t, t2: Integer;
    ws: TSqlWindowNode;
    same: Boolean;
  begin
    Result := -1;
    if WN = nil then Exit;
    for t := 0 to High(WinSlot) do
    begin
      if (WinSlot[t] < 0) then Continue;
      if (t >= Length(FStmtColumns)) or (FStmtColumns[t] = nil) then Continue;
      if not (FStmtColumns[t] is TSqlWindowNode) then Continue;
      ws := TSqlWindowNode(FStmtColumns[t]);
      if (ws.FuncName <> WN.FuncName) then Continue;
      if (ws.Partitions.Count <> WN.Partitions.Count) then Continue;
      if (ws.OrderBys.Count <> WN.OrderBys.Count) then Continue;
      same := True;
      for t2 := 0 to ws.Partitions.Count - 1 do
        if not SameExprText(ws.Partitions[t2], WN.Partitions[t2]) then
        begin same := False; Break; end;
      if same then
        for t2 := 0 to ws.OrderBys.Count - 1 do
        begin
          if (ws.OrderBys[t2].Desc <> WN.OrderBys[t2].Desc) or
             not SameExprText(ws.OrderBys[t2].Expr, WN.OrderBys[t2].Expr) then
          begin same := False; Break; end;
        end;
      if same then
      begin
        Result := WinSlot[t];
        Exit;
      end;
    end;
  end;

  // F-09: karsilastirma tipi. Sol/sag taraftan biri pencere degeri
  // (ROW_NUMBER/RANK -> hep sayisal) ise VCT_INT; diger durumlar normal
  // kolon tip cozumlemesine birakilir.
  function QualifyCtype(L, R: TSqlExprNode): Byte;
  var
    crL: TSqlColumnRefNode;
    qt: Integer;
  begin
    Result := VCT_STR;
    if L is TSqlWindowNode then Exit(VCT_INT);
    if R is TSqlWindowNode then Exit(VCT_INT);
    if L is TSqlColumnRefNode then
    begin
      crL := TSqlColumnRefNode(L);
      for qt := 0 to High(ColNames) do
        if SameText(crL.QualifiedName, ColNames[qt]) and (qt < Length(ColTypes)) then
        begin Result := ColTypes[qt]; Exit; end;
    end;
  end;

  function Ev(E: TSqlExprNode): string;
  var
    b: TSqlBinaryOpNode;
    u: TSqlUnaryOpNode;
    csN: TSqlCaseNode;
    btr: TSqlBetweenNode;
    n: TSqlNullIfNode;
    co: TSqlCoalesceNode;
    t: Integer;
  begin
    if E = nil then Exit('');
    if E is TSqlWindowNode then
    begin
      w := TSqlWindowNode(E);
      slot := FindWinSlot(w);
      if (slot >= 0) and (RowIx < Length(WinVals)) and
         (slot < Length(WinVals[RowIx])) then
        Exit(WinVals[RowIx][slot]);
      Exit('');
    end;
    if E is TSqlLiteralNode then Exit(TSqlLiteralNode(E).AsString);
    if E is TSqlColumnRefNode then
      Exit(EvalExpr(E, Row, ColNames, ColTypes));
    if E is TSqlBinaryOpNode then
    begin
      b := TSqlBinaryOpNode(E);
      // F-09: karsilastirma tipi cozumlenir; aksi halde ROW_NUMBER() (metin)
      // ile 2 (sayi) karsilastirilir ve '10' <= '2' YANLIS sonuc verir.
      Exit(EvalBinary(b.Op, Ev(b.Left), Ev(b.Right), QualifyCtype(b.Left, b.Right)));
    end;
    if E is TSqlUnaryOpNode then
    begin
      u := TSqlUnaryOpNode(E);
      Exit(EvalUnary(u.Op, Ev(u.Operand)));
    end;
    if E is TSqlFuncCallNode then
      Exit(EvalExpr(E, Row, ColNames, ColTypes));
    if E is TSqlBetweenNode then
    begin
      btr := TSqlBetweenNode(E);
      s := Ev(btr.Expr);
      if (s = '') or (Ev(btr.LowBound) = '') or (Ev(btr.HighBound) = '') then Exit('');
      if SameText(EvalBinary(sboGte, s, Ev(btr.LowBound), VCT_STR), 'True') and
         SameText(EvalBinary(sboLte, s, Ev(btr.HighBound), VCT_STR), 'True') then
        s := 'True' else s := 'False';
      if btr.IsNot then
      begin if s = 'True' then Exit('False') else Exit('True'); end;
      Exit(s);
    end;
    if E is TSqlCaseNode then
    begin
      csN := TSqlCaseNode(E);
      for t := 0 to csN.Whens.Count - 1 do
        if SameText(Ev(csN.Whens[t].Cond), 'True') then
          Exit(Ev(csN.Whens[t].Value));
      if csN.ElseExpr <> nil then Exit(Ev(csN.ElseExpr));
      Exit('');
    end;
    if E is TSqlNullIfNode then
    begin
      n := TSqlNullIfNode(E);
      s := Ev(n.Arg1);
      if (s <> '') and (s = Ev(n.Arg2)) then Exit('');
      Exit(s);
    end;
    if E is TSqlCoalesceNode then
    begin
      co := TSqlCoalesceNode(E);
      for t := 0 to co.Args.Count - 1 do
      begin
        s := Ev(co.Args[t]);
        if s <> '' then Exit(s);
      end;
      Exit('');
    end;
    // IN, EXISTS, alt sorgu vb. normal yolla
    Exit(EvalExpr(E, Row, ColNames, ColTypes));
  end;

begin
  s := Ev(Expr);
  Result := SameText(s, 'True') or (s = '1');
end;

function TVSqlExecutor.HasAggregate(Stmt: TSqlSelectStmt): Boolean;
var
  i: Integer;
  fn: TSqlFuncCallNode;

  // F-14/F-15: ifade icinde (ic ice) aggregate var mi?
  // LENGTH(STRING_AGG(...)) gibi bir sarmalayici TSqlAggNode barindirir;
  // yalniz tepe dugune bakmak onu kacirir.
  function HasAggIn(E: TSqlExprNode): Boolean;
  var
    t: Integer;
    b: TSqlBinaryOpNode;
    u: TSqlUnaryOpNode;
    f: TSqlFuncCallNode;
  begin
    Result := False;
    if E = nil then Exit;
    if E is TSqlAggNode then Exit(True);
    if E is TSqlFuncCallNode then
    begin
      f := TSqlFuncCallNode(E);
      if IsAggFuncName(f.FuncName) then Exit(True);
      if HasAggIn(f.Arg) then Exit(True);
      Exit;
    end;
    if E is TSqlBinaryOpNode then
    begin
      b := TSqlBinaryOpNode(E);
      if HasAggIn(b.Left) or HasAggIn(b.Right) then Exit(True);
    end
    else if E is TSqlUnaryOpNode then
    begin
      u := TSqlUnaryOpNode(E);
      if HasAggIn(u.Operand) then Exit(True);
    end;
  end;

begin
  for i := 0 to Stmt.Columns.Count - 1 do
    if HasAggIn(Stmt.Columns[i].Expr) then Exit(True);
  if Stmt.HavingClause <> nil then Exit(True);
  Result := False;
end;

{ ------------------------------------------------------------
  Pencere yerlesim denetimi (P5-WIN)
  //---------------------------------------------------------- }
function TVSqlExecutor.HasWindow(Stmt: TSqlSelectStmt): Boolean;

  function Walk(E: TSqlExprNode): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    if E = nil then Exit;
    if E is TSqlWindowNode then Exit(True);
    if E is TSqlBinaryOpNode then
      Exit(Walk(TSqlBinaryOpNode(E).Left) or Walk(TSqlBinaryOpNode(E).Right));
    if E is TSqlUnaryOpNode then
      Exit(Walk(TSqlUnaryOpNode(E).Operand));
    if E is TSqlInNode then
    begin
      if Walk(TSqlInNode(E).Expr) then Exit(True);
      for k := 0 to TSqlInNode(E).List.Count - 1 do
        if Walk(TSqlInNode(E).List[k]) then Exit(True);
      Exit(False); // alt sorgular kendi ExecSelect'inde denetlenir
    end;
    if E is TSqlBetweenNode then
      Exit(Walk(TSqlBetweenNode(E).Expr) or
           Walk(TSqlBetweenNode(E).LowBound) or
           Walk(TSqlBetweenNode(E).HighBound));
    if E is TSqlFuncCallNode then
      Exit(Walk(TSqlFuncCallNode(E).Arg));
    if E is TSqlCaseNode then
    begin
      if Walk(TSqlCaseNode(E).Operand) then Exit(True);
      for k := 0 to TSqlCaseNode(E).Whens.Count - 1 do
        if Walk(TSqlCaseNode(E).Whens[k].Cond) or
           Walk(TSqlCaseNode(E).Whens[k].Value) then Exit(True);
      Exit(Walk(TSqlCaseNode(E).ElseExpr));
    end;
  end;

var
  i: Integer;
begin
  Result := False;
  for i := 0 to Stmt.Columns.Count - 1 do
    if Walk(Stmt.Columns[i].Expr) then Exit(True);
end;

procedure TVSqlExecutor.CheckWindowPlacement(Stmt: TSqlSelectStmt);

  procedure AssertNoWindow(E: TSqlExprNode; const Where: string);
  var
    k: Integer;
  begin
    if E = nil then Exit;
    if E is TSqlWindowNode then
      raise EVDbException.Create(ecUnsupported,
        'pencere fonksiyonu yalnizca SELECT listesinde kullanilabilir (' +
        Where + ')');
    if E is TSqlBinaryOpNode then
    begin
      AssertNoWindow(TSqlBinaryOpNode(E).Left, Where);
      AssertNoWindow(TSqlBinaryOpNode(E).Right, Where);
    end
    else if E is TSqlUnaryOpNode then
      AssertNoWindow(TSqlUnaryOpNode(E).Operand, Where)
    else if E is TSqlInNode then
    begin
      AssertNoWindow(TSqlInNode(E).Expr, Where);
      for k := 0 to TSqlInNode(E).List.Count - 1 do
        AssertNoWindow(TSqlInNode(E).List[k], Where);
    end
    else if E is TSqlBetweenNode then
    begin
      AssertNoWindow(TSqlBetweenNode(E).Expr, Where);
      AssertNoWindow(TSqlBetweenNode(E).LowBound, Where);
      AssertNoWindow(TSqlBetweenNode(E).HighBound, Where);
    end
    else if E is TSqlFuncCallNode then
      AssertNoWindow(TSqlFuncCallNode(E).Arg, Where)
    else if E is TSqlCaseNode then
    begin
      AssertNoWindow(TSqlCaseNode(E).Operand, Where);
      for k := 0 to TSqlCaseNode(E).Whens.Count - 1 do
      begin
        AssertNoWindow(TSqlCaseNode(E).Whens[k].Cond, Where);
        AssertNoWindow(TSqlCaseNode(E).Whens[k].Value, Where);
      end;
      AssertNoWindow(TSqlCaseNode(E).ElseExpr, Where);
    end
    else if E is TSqlWindowNode then
      raise EVDbException.Create(ecUnsupported,
        'pencere fonksiyonu yalnizca SELECT listesinde kullanilabilir (' +
        Where + ')');
    // Alt sorgular (SubSelect/Select) kendi cumlelerinde denetlenir.
  end;

var
  i, k: Integer;
begin
  // SELECT listesi: ust-duzey pencere serbest, ic ice yasak.
  for i := 0 to Stmt.Columns.Count - 1 do
    if not (Stmt.Columns[i].Expr is TSqlWindowNode) then
      AssertNoWindow(Stmt.Columns[i].Expr, 'SELECT');
  AssertNoWindow(Stmt.WhereClause, 'WHERE');
  AssertNoWindow(Stmt.HavingClause, 'HAVING');
  if Stmt.OrderBy <> nil then
    for k := 0 to Stmt.OrderBy.Count - 1 do
      AssertNoWindow(Stmt.OrderBy[k].Expr, 'ORDER BY');
  if Stmt.HasJoin then
  begin
    AssertNoWindow(Stmt.Join.OnCondition, 'JOIN ON');
    for k := 0 to Stmt.MoreJoins.Count - 1 do
      AssertNoWindow(Stmt.MoreJoins[k].OnCondition, 'JOIN ON');
  end;
end;

{ ============================================================
   F-33: VIEW INSERT/UPDATE/DELETE — View guncellenebilirlik analizi
   ============================================================ }

function TVSqlExecutor.AnalyzeViewUpdatable(const ViewName: string;
  out BaseTable: string; out ColMap: TStrArray): Boolean;
var
  v: TTableDef;
  Sel: TSqlSelectStmt;
begin
  Result := False;
  BaseTable := '';
  ColMap := nil;
  if not FT.TryGetTableDef(ViewName, v) then Exit;
  if not v.IsView then Exit;
  { NOT: AST katalogda saklanmaz (CREATE bitince Free edilir);
    METINDEN yeniden uretilir. }
  Sel := ParseSelectText(FT.ViewSelectText(ViewName));
  if Sel = nil then Exit;
  try
    // Updatable view kriterleri:
    // 1) Tek FROM tablo, JOIN yok
    if Sel.HasJoin then Exit;
    if Sel.MoreJoins <> nil then
      if Sel.MoreJoins.Count > 0 then Exit;
    // 2) SET OP yok (UNION/EXCEPT/INTERSECT)
    if Sel.SetOp <> sokNone then Exit;
    // 3) DISTINCT yok
    if Sel.IsDistinct then Exit;
    // 4) GROUP BY / HAVING / aggregate yok
    if Sel.GroupByCols <> nil then
      if Sel.GroupByCols.Count > 0 then Exit;
    if Sel.HavingClause <> nil then Exit;
    if HasAggregate(Sel) then Exit;
    // 5) FROM tablo var mi
    if Sel.FromTable = '' then Exit;
    // 6) Kolonlar sadece basit referans olmali (ifade/alias yok)
    BuildViewColMap(Sel, ColMap);
    if Length(ColMap) = 0 then Exit;
    BaseTable := Sel.FromTable;
    Result := True;
  finally
    Sel.Free;
  end;
end;

procedure TVSqlExecutor.BuildViewColMap(const ViewSelect: TSqlSelectStmt;
  out ColMap: TStrArray);
var
  i, ci: Integer;
  item: TSelectColumnItem;
  Ref: TSqlColumnRefNode;
  viewColName, baseColName: string;
begin
  SetLength(ColMap, 0);
  for i := 0 to ViewSelect.Columns.Count - 1 do
  begin
    item := ViewSelect.Columns[i];
    if item.Expr is TSqlColumnRefNode then
    begin
      Ref := TSqlColumnRefNode(item.Expr);
      // View kolon adi: alias varsa alias, yoksa kolon adi (nitesiz)
      if item.Alias <> '' then
        viewColName := item.Alias
      else
        viewColName := Ref.ColumnName;
      // Base kolon adi: nitelemeli ise son parca, degilse tum ad
      baseColName := Ref.ColumnName;
      if Pos('.', baseColName) > 0 then
        baseColName := Copy(baseColName, Pos('.', baseColName) + 1, MaxInt);
      SetLength(ColMap, Length(ColMap) + 1);
      ColMap[High(ColMap)] := viewColName + '=' + baseColName; // "viewCol=baseCol"
    end
    else
    begin
      // Ifade/alias -> guncellenemez
      SetLength(ColMap, 0);
      Exit;
    end;
  end;
end;

{ ============================================================
   F-33: VIEW DML yardimcilari
   ============================================================ }

// View kolon adlarini base kolon adlarina cevirir (AST'yi kopyalayarak)
function TVSqlExecutor.TransformViewColsToBase(Expr: TSqlExprNode;
  const ColMap: TStrArray): TSqlExprNode;
var
  i: Integer;
  viewCol, baseCol: string;
  WhenRec: TSqlCaseWhen;
begin
  Result := Expr;
  if Expr = nil then Exit;
  if Expr is TSqlColumnRefNode then
  begin
    for i := 0 to High(ColMap) do
    begin
      // ColMap format: "viewCol=baseCol"
      viewCol := Copy(ColMap[i], 1, Pos('=', ColMap[i]) - 1);
      baseCol := Copy(ColMap[i], Pos('=', ColMap[i]) + 1, MaxInt);
      if SameText(TSqlColumnRefNode(Expr).ColumnName, viewCol) then
      begin
        Result := TSqlColumnRefNode.Create(baseCol);
        Exit;
      end;
    end;
  end
  else if Expr is TSqlBinaryOpNode then
  begin
    TSqlBinaryOpNode(Expr).Left := TransformViewColsToBase(TSqlBinaryOpNode(Expr).Left, ColMap);
    TSqlBinaryOpNode(Expr).Right := TransformViewColsToBase(TSqlBinaryOpNode(Expr).Right, ColMap);
    Result := Expr;
  end
  else if Expr is TSqlUnaryOpNode then
  begin
    TSqlUnaryOpNode(Expr).Operand := TransformViewColsToBase(TSqlUnaryOpNode(Expr).Operand, ColMap);
    Result := Expr;
  end
  else if Expr is TSqlInNode then
  begin
    TSqlInNode(Expr).Expr := TransformViewColsToBase(TSqlInNode(Expr).Expr, ColMap);
    for i := 0 to TSqlInNode(Expr).List.Count - 1 do
      TSqlInNode(Expr).List[i] := TransformViewColsToBase(TSqlInNode(Expr).List[i], ColMap);
    Result := Expr;
  end
  else if Expr is TSqlBetweenNode then
  begin
    TSqlBetweenNode(Expr).Expr := TransformViewColsToBase(TSqlBetweenNode(Expr).Expr, ColMap);
    TSqlBetweenNode(Expr).LowBound := TransformViewColsToBase(TSqlBetweenNode(Expr).LowBound, ColMap);
    TSqlBetweenNode(Expr).HighBound := TransformViewColsToBase(TSqlBetweenNode(Expr).HighBound, ColMap);
    Result := Expr;
  end
  else if Expr is TSqlFuncCallNode then
  begin
    if TSqlFuncCallNode(Expr).Arg <> nil then
      TSqlFuncCallNode(Expr).Arg := TransformViewColsToBase(TSqlFuncCallNode(Expr).Arg, ColMap);
    Result := Expr;
  end
  else if Expr is TSqlCaseNode then
  begin
    if TSqlCaseNode(Expr).Operand <> nil then
      TSqlCaseNode(Expr).Operand := TransformViewColsToBase(TSqlCaseNode(Expr).Operand, ColMap);
    for i := 0 to TSqlCaseNode(Expr).Whens.Count - 1 do
    begin
      WhenRec := TSqlCaseNode(Expr).Whens[i];
      WhenRec.Cond := TransformViewColsToBase(WhenRec.Cond, ColMap);
      WhenRec.Value := TransformViewColsToBase(WhenRec.Value, ColMap);
      TSqlCaseNode(Expr).Whens[i] := WhenRec;
    end;
    if TSqlCaseNode(Expr).ElseExpr <> nil then
      TSqlCaseNode(Expr).ElseExpr := TransformViewColsToBase(TSqlCaseNode(Expr).ElseExpr, ColMap);
    Result := Expr;
  end;
end;

{ ============================================================
   NarrowRows - WHERE'den satir adayi daraltma

   SORUN: ExecSelect/ExecUpdate/ExecDelete kosiulsuz olarak
   FT.ScanRows cagirip TUM tabloyu bellege cekiyordu. 100.000 satirlik
   tabloda "WHERE id = 5" bile ~900 ms suruyordu (PK hash ile O(1)
   olmaliydi).

   COZUM: WHERE AST'sinden su iki kaliptan biri cikarilir:
     1) PK kolonunda '='  -> ReadRow ile TEK satir (O(1))
     2) indeksli kolonda '=', '>', '>=', '<', '<=', BETWEEN, IN
        -> indeks dilimi, yalniz o aralik okunur
   Bulunamazsa False doner ve cagri tam tarama yapar.

   GUVENLILIK: dilim yalnizca bir UST KUMEDIR; donen satirlarin tamami
   RowMatches ile yeniden dogrulanir. Bu yuzden "hangi satirlar eslesir"
   sorusunun cevabi degismez - sadece okunacak satir sayisi azalir.
   ============================================================ }

function TVSqlExecutor.PartTargetsOf(const Td: TTableDef;
  WhereClause: TSqlExprNode): TPartTargets;
{ R-13 Full: partition pruning hedef kumesi.
  Yalniz su kosullar katki verir (hepsi UST KUME GUVENLI):
    - bolme kolonu = literal  (veya literal = bolme kolonu)
    - bolme kolonu IN (literal, ...)  [NOT IN katki vermez]
    - bunlarin AND ile zinciri (kesisim)
  OR iceren kosul tek parca olarak degerlendirilir ve anlasilmazsa
  filtre YOK olur (guvenli taraf). INT kolonlarda literal IntToStr ile
  canonicallestirilir ('05' -> '5'); STRING kolonlarda aynen; diger
  tipler (FLOAT/BOOL/DATE) pruning'e katki vermez (canonical bicim
  garanti edilemedigi icin). }
var
  conj: TList<TSqlExprNode>;
  i, j, q, ci, ct: Integer;
  pno: Integer;
  nn: TSqlBinaryOpNode;
  lit: string;
  iv: Int64;
  started: Boolean;
  tgt, one, ins, keep: TIntArray;
  f: Boolean;
  pt: TPartTargets;
  bad: Boolean;

  procedure Push(C: TSqlExprNode);
  begin
    if (C is TSqlBinaryOpNode) and (TSqlBinaryOpNode(C).Op = sboAnd) then
    begin
      Push(TSqlBinaryOpNode(C).Left);
      Push(TSqlBinaryOpNode(C).Right);
    end
    else
      conj.Add(C);
  end;

  { Yeni hedef grubunu mevcut kumeyle KESISIMLER: onceki anlasilan
    kosullar with-AND bagli oldugu icin ayni anda saglanmalari gerekir.
    Ilk grupta kume kurulur. BOS kesisim = hicbir satir (WHERE de bos
    dondurecegi icin dogru sonuctur: orn. k = 5 AND k = 7). }
  procedure Intersect(const P: TIntArray);
  var
    a, b: Integer;
  begin
    if not started then
    begin
      tgt := Copy(P, 0, Length(P));
      started := True;
    end
    else
    begin
      SetLength(keep, 0);
      for a := 0 to High(tgt) do
      begin
        f := False;
        for b := 0 to High(P) do
          if tgt[a] = P[b] then begin f := True; Break; end;
        if f then
        begin
          SetLength(keep, Length(keep) + 1);
          keep[High(keep)] := tgt[a];
        end;
      end;
      tgt := keep;
    end;
  end;

  { Literal degeri SATIRDAKI saklama bicimine cevirir. Cevrilemiyorsa
    '' doner -> o kosul pruning'e katki vermez (guvenli taraf).
    R-20 guvenligi: STRING kolonun COLLATE varsayilani varsa esitlik
    harf/vurgu duyarsiz olabilir ('A' = 'a') ama bolum hesabi bayt
    esaslidir -> yanlis eleme riskine karsi katki yok. (Acik
    `COLLATE`li karsilastirma zaten TSqlCollateNode sarar; EqPart
    kolon referansi gormez, otomatik guvenli kalir.) }
  function CanonLit(const V: string): string;
  begin
    Result := '';
    if (ci < 0) or (ci >= Length(Td.Cols)) then Exit;
    ct := Td.Cols[ci].Ctype;
    if ct = VCT_INT then
    begin
      if VDbParseInt(V, iv) then Result := IntToStr(iv);
    end
    else if ct = VCT_STR then
    begin
      if Td.Cols[ci].Collate = '' then Result := V;
    end;
  end;

begin
  pt.HasFilter := False;
  SetLength(pt.Parts, 0);
  Result := pt;
  if (Td.PartType = '') or (WhereClause = nil) then Exit;
  ci := -1;
  for i := 0 to High(Td.Cols) do
    if Td.Cols[i].Name = Td.PartCol then begin ci := i; Break; end;
  if ci < 0 then Exit;

  conj := TList<TSqlExprNode>.Create;
  try
    Push(WhereClause);
    started := False;
    SetLength(tgt, 0);
    for i := 0 to conj.Count - 1 do
    begin
      if conj[i] is TSqlBinaryOpNode then
      begin
        nn := TSqlBinaryOpNode(conj[i]);
        if nn.Op <> sboEq then Continue;
        // kolon = literal
        if (nn.Left is TSqlColumnRefNode) and
           (nn.Right is TSqlLiteralNode) and
           (VDbNorm(TSqlColumnRefNode(nn.Left).ColumnName) = Td.PartCol) then
        begin
          lit := CanonLit(TSqlLiteralNode(nn.Right).AsString);
          if lit <> '' then
          begin
            SetLength(one, 1);
            one[0] := FT.PartValueOf(Td, lit);
            Intersect(one);
          end;
        end
        // literal = kolon (yansitilmis)
        else if (nn.Right is TSqlColumnRefNode) and
                (nn.Left is TSqlLiteralNode) and
                (VDbNorm(TSqlColumnRefNode(nn.Right).ColumnName) = Td.PartCol) then
        begin
          lit := CanonLit(TSqlLiteralNode(nn.Left).AsString);
          if lit <> '' then
          begin
            SetLength(one, 1);
            one[0] := FT.PartValueOf(Td, lit);
            Intersect(one);
          end;
        end;
      end
      else if conj[i] is TSqlInNode then
      begin
        // k IN (l1, l2, ...): hedef = degerlerin bolumlerinin birlesimi.
        // NOT IN / alt sorgulu IN katki vermez. Listede TEK belirsiz
        // eleman varsa (literal degil / canonical edilemedi) tum kosul
        // katki disi birakilir (yanlis eleme riski sifirlanir).
        with TSqlInNode(conj[i]) do
        begin
          if (not IsNot) and (SubSelect = nil) and
             (Expr is TSqlColumnRefNode) and
             (VDbNorm(TSqlColumnRefNode(Expr).ColumnName) = Td.PartCol) then
          begin
            SetLength(ins, 0);
            bad := False;
            for j := 0 to List.Count - 1 do
            begin
              if not (List[j] is TSqlLiteralNode) then begin bad := True; Break; end;
              lit := CanonLit(TSqlLiteralNode(List[j]).AsString);
              if lit = '' then begin bad := True; Break; end;
              pno := FT.PartValueOf(Td, lit);
              f := False;
              for q := 0 to High(ins) do
                if ins[q] = pno then begin f := True; Break; end;
              if not f then
              begin
                SetLength(ins, Length(ins) + 1);
                ins[High(ins)] := pno;
              end;
            end;
            if (not bad) and (Length(ins) > 0) then
              Intersect(ins);
          end;
        end;
      end;
    end;
    if started then
    begin
      pt.HasFilter := True;
      pt.Parts := tgt;   // bos kume = hicbolum (0 satir) - dogru sonuc
    end;
    Result := pt;
  finally
    conj.Free;
  end;
end;

function TVSqlExecutor.NarrowRows(const Td: TTableDef; WhereClause: TSqlExprNode;
  const ColNames: TStrArray; const ColTypes: TByteArray;
  out Pks: TStrArray; out Rows: TStrMatrix; out IsExact: Boolean): Boolean;
var
  conj: TList<TSqlExprNode>;
  i, ci, lo, hi, l2, h2, n: Integer;
  e: TIdxEntries;
  ct: Byte;
  pkVal: string;
  bestCol: Integer;
  bestLo, bestHi: Integer;
  foundRange: Boolean;
  exactRange: Boolean;
  nUsed: Integer;          // dilime katkida bulunan conjunct sayisi
  hasIn: Boolean;          // katkida bulunan IN var mi (aralik tam degil)
  hasLower: Boolean;       // alt sinir var mi (NULL'lari disarida tutar)
  isIn: Boolean;
  op: TSqlBinaryOp;
  cr: TSqlColumnRefNode;
  opName: string;
  oneRow: TStrArray;
  nParts: Integer;
  covPos: Integer;      // F-19: index-only tarama icin indeks konumu
  covAll: Boolean;
  st: TVDbTableStats;   // R-15 Full CBO: ANALYZE istatistigi
  mcvCnt: Int64;        // H8: esitlik degeri icin MCV sayimi
  // H3: skiplist/dizi ortak aralik kaynagi
  src, bestSrc: TIdxSource;
  hasLo, hasHi: Boolean;
  bestLoInc, bestHiInc: Boolean;
  condHasLo, condHasHi: Boolean;
  condLoInc, condHiInc: Boolean;
  bestLoVal, bestHiVal: string;
  condLoVal, condHiVal, minVal, maxVal: string;
  cmpV: Integer;

  procedure Push(C: TSqlExprNode);
  begin
    if (C is TSqlBinaryOpNode) and (TSqlBinaryOpNode(C).Op = sboAnd) then
    begin
      Push(TSqlBinaryOpNode(C).Left);
      Push(TSqlBinaryOpNode(C).Right);
    end
    else
      conj.Add(C);
  end;

  // Sutun + tek sabit iceren karsilastirmayi "op" adina cevirir.
  function AsSimple(const C: TSqlExprNode; out ColI: Integer;
    out Val: string; out Op: TSqlBinaryOp): Boolean;
  var
    nn: TSqlBinaryOpNode;
    a, b: TSqlColumnRefNode;
    q: Integer;
  begin
    Result := False;
    Op := sboEq; ColI := -1; Val := '';
    if not (C is TSqlBinaryOpNode) then Exit;
    nn := TSqlBinaryOpNode(C);
    if (nn.Op = sboAnd) or (nn.Op = sboOr) or (nn.Op = sboAdd) or
       (nn.Op = sboSub) or (nn.Op = sboMul) or (nn.Op = sboDiv) or
       (nn.Op = sboMod) or (nn.Op = sboLike) then Exit;
    a := nil; b := nil;
    if nn.Left  is TSqlColumnRefNode then a := TSqlColumnRefNode(nn.Left);
    if nn.Right is TSqlColumnRefNode then b := TSqlColumnRefNode(nn.Right);
    if (a <> nil) and (nn.Right is TSqlLiteralNode) then
    begin
      // `a = NULL` SQL'de UNKNOWN'dir; indeks araligi uretme, RowMatches
      // (veya tam tarama) dogru sonucu versin.
      if TSqlLiteralNode(nn.Right).LitType = sltNull then Exit;
      ColI := -1;
      for q := 0 to High(Td.Cols) do
        if VDbNorm(Td.Cols[q].Name) = VDbNorm(a.ColumnName) then
        begin ColI := q; Break; end;
      if ColI < 0 then Exit;
      Val := TSqlLiteralNode(nn.Right).AsString;
      Op := nn.Op;
      Exit(True);
    end;
    if (b <> nil) and (nn.Left is TSqlLiteralNode) then
    begin
      // "5 = a" -> "a = 5" (yansitilmis operator)
      if TSqlLiteralNode(nn.Left).LitType = sltNull then Exit;
      ColI := -1;
      for q := 0 to High(Td.Cols) do
        if VDbNorm(Td.Cols[q].Name) = VDbNorm(b.ColumnName) then
        begin ColI := q; Break; end;
      if ColI < 0 then Exit;
      Val := TSqlLiteralNode(nn.Left).AsString;
      case nn.Op of
        sboEq:  Op := sboEq;
        sboNeq: Op := sboNeq;
        sboLt:  Op := sboGt;
        sboLte: Op := sboGte;
        sboGt:  Op := sboLt;
        sboGte: Op := sboLte;
        else    Exit;
      end;
      Exit(True);
    end;
  end;

begin
  SetLength(Pks, 0);
  SetLength(Rows, 0);
  Result := False;
  IsExact := False;
  if WhereClause = nil then Exit;

  conj := TList<TSqlExprNode>.Create;
  try
    Push(WhereClause);
    if conj.Count = 0 then Exit;

    // --- 1) PK nokta aramasi (en degerli yol) ---
    for i := 0 to conj.Count - 1 do
      if AsSimple(conj[i], ci, pkVal, op) and (Td.PkIndex >= 0) and
         (ci = Td.PkIndex) and
         (op = sboEq) then
      begin
        if FT.ReadRow(Td.Name, pkVal, oneRow) and
           RowMatches(WhereClause, oneRow, ColNames, ColTypes) then
        begin
          SetLength(Pks, 1);
          SetLength(Rows, 1);
          Pks[0] := pkVal;
          Rows[0] := oneRow;
        end;
        // eslesme yoksa da bos sonuc DONDURULUR: tam tarama gerekmez
        IsExact := True;
        if FCountOnly then FCountResult := Length(Pks);
        Exit(True);
      end;

    // --- 1b) PK uzerinde IN (...) : her deger icin tek O(1) arama ---
    // (PK'nin bellek indeksi yoktur; kucuk listelerde tek tek okumak
    //  tam taramadan kat kat hizlidir.)
    // NOT: alt sorgulu IN burada ele alinmaz (liste bossa bos donerdi).
    if Td.PkIndex >= 0 then
      for i := 0 to conj.Count - 1 do
        if (conj[i] is TSqlInNode) and (not TSqlInNode(conj[i]).IsNot) and
           (TSqlInNode(conj[i]).SubSelect = nil) and
           (TSqlInNode(conj[i]).Expr is TSqlColumnRefNode) and
           (TSqlInNode(conj[i]).List.Count <= 512) then
        begin
          ci := -1;
          for n := 0 to High(Td.Cols) do
            if VDbNorm(Td.Cols[n].Name) =
                VDbNorm(TSqlColumnRefNode(TSqlInNode(conj[i]).Expr).ColumnName) then
            begin ci := n; Break; end;
          if ci <> Td.PkIndex then Continue;
          // KR-2: on-tahsis (List.Count ust sinir), sonunda budama.
          SetLength(Pks, TSqlInNode(conj[i]).List.Count);
          SetLength(Rows, TSqlInNode(conj[i]).List.Count);
          ci := 0;  // ci'yi sayac olarak yeniden kullan (PkIndex artik gerekmez)
          for n := 0 to TSqlInNode(conj[i]).List.Count - 1 do
          begin
            if not (TSqlInNode(conj[i]).List[n] is TSqlLiteralNode) then Continue;
            pkVal := TSqlLiteralNode(TSqlInNode(conj[i]).List[n]).AsString;
            if FT.ReadRow(Td.Name, pkVal, oneRow) then
            begin
              Pks[ci] := pkVal;
              Rows[ci] := oneRow;
              Inc(ci);
            end;
          end;
          SetLength(Pks, ci);
          SetLength(Rows, ci);
          IsExact := (conj.Count = 1);
          if FCountOnly then FCountResult := Length(Pks);
          Exit(True);   // filtre RowMatches ile asagida uygulanir (IsExact degilse)
        end;

    // --- 2) indeks dilimi ---
    bestCol := -1; foundRange := False; exactRange := False;
    nUsed := 0; hasIn := False; hasLower := False;
    hasLo := False; hasHi := False;
    bestLoVal := ''; bestHiVal := ''; bestLoInc := True; bestHiInc := True;
    for i := 0 to conj.Count - 1 do
    begin
      condHasLo := False; condHasHi := False;
      condLoInc := True; condHiInc := True;
      condLoVal := ''; condHiVal := '';
      isIn := False;
      // 2a) basit karsilastirma
      if AsSimple(conj[i], ci, pkVal, op) then
      begin
        case op of
          sboEq:
            begin
              condHasLo := True; condHasHi := True;
              condLoInc := True; condHiInc := True;
              condLoVal := pkVal; condHiVal := pkVal;
              hasLower := True;
            end;
          sboGt:
            begin
              condHasLo := True; condLoInc := False; condLoVal := pkVal;
              hasLower := True;
            end;
          sboGte:
            begin
              condHasLo := True; condLoInc := True; condLoVal := pkVal;
              hasLower := True;
            end;
          sboLt:
            begin
              condHasHi := True; condHiInc := False; condHiVal := pkVal;
            end;
          sboLte:
            begin
              condHasHi := True; condHiInc := True; condHiVal := pkVal;
            end;
        end;
        if (not condHasLo) and (not condHasHi) then Continue;
      end
      // 2b) BETWEEN a AND b
      else if (conj[i] is TSqlBetweenNode) and
              (not TSqlBetweenNode(conj[i]).IsNot) and
              (TSqlBetweenNode(conj[i]).Expr is TSqlColumnRefNode) and
              (TSqlBetweenNode(conj[i]).LowBound  is TSqlLiteralNode) and
              (TSqlBetweenNode(conj[i]).HighBound is TSqlLiteralNode) then
      begin
        cr := TSqlColumnRefNode(TSqlBetweenNode(conj[i]).Expr);
        ci := -1;
        for n := 0 to High(Td.Cols) do
          if VDbNorm(Td.Cols[n].Name) = VDbNorm(cr.ColumnName) then
          begin ci := n; Break; end;
        if ci < 0 then Continue;
        condHasLo := True; condLoInc := True;
        condLoVal := TSqlLiteralNode(TSqlBetweenNode(conj[i]).LowBound).AsString;
        condHasHi := True; condHiInc := True;
        condHiVal := TSqlLiteralNode(TSqlBetweenNode(conj[i]).HighBound).AsString;
        hasLower := True;
      end
      // 2c) IN (a, b, c, ...)
      else if (conj[i] is TSqlInNode) and (not TSqlInNode(conj[i]).IsNot) and
              (TSqlInNode(conj[i]).Expr is TSqlColumnRefNode) then
      begin
        isIn := True;
        cr := TSqlColumnRefNode(TSqlInNode(conj[i]).Expr);
        ci := -1;
        for n := 0 to High(Td.Cols) do
          if VDbNorm(Td.Cols[n].Name) = VDbNorm(cr.ColumnName) then
          begin ci := n; Break; end;
        if (ci < 0) or (TSqlInNode(conj[i]).List.Count = 0) then Continue;
        if (not FT.TryGetIdxSource(Td.TableId, ci, src)) then Continue;
        minVal := ''; maxVal := ''; n := 0;
        for lo := 0 to TSqlInNode(conj[i]).List.Count - 1 do
        begin
          if not (TSqlInNode(conj[i]).List[lo] is TSqlLiteralNode) then Continue;
          pkVal := TSqlLiteralNode(TSqlInNode(conj[i]).List[lo]).AsString;
          if n = 0 then
          begin minVal := pkVal; maxVal := pkVal; end
          else
          begin
            if IdxSourceCompareVal(src, pkVal, minVal) < 0 then minVal := pkVal;
            if IdxSourceCompareVal(src, pkVal, maxVal) > 0 then maxVal := pkVal;
          end;
          Inc(n);
        end;
        if n = 0 then Continue;
        condHasLo := True; condLoInc := True; condLoVal := minVal;
        condHasHi := True; condHiInc := True; condHiVal := maxVal;
      end
      else Continue;

      // ONEMLI: birden fazla indeks kosulu ancak AYNI KOLONDA ise
      // kesisilir. Farkli kolonlarda kesisim anlamsizdir.
      if foundRange and (ci <> bestCol) then Continue;
      if (not isIn) and (not FT.TryGetIdxSource(Td.TableId, ci, src)) then
        Continue;

      if not foundRange then
      begin
        foundRange := True;
        bestCol := ci;
        bestSrc := src;
      end;
      Inc(nUsed);
      if isIn then hasIn := True;
      if condHasLo then
      begin
        if (not hasLo) or
           (IdxSourceCompareVal(bestSrc, condLoVal, bestLoVal) > 0) or
           ((IdxSourceCompareVal(bestSrc, condLoVal, bestLoVal) = 0) and
            (not condLoInc) and bestLoInc) then
        begin
          hasLo := True; bestLoVal := condLoVal; bestLoInc := condLoInc;
        end;
      end;
      if condHasHi then
      begin
        if (not hasHi) or
           (IdxSourceCompareVal(bestSrc, condHiVal, bestHiVal) < 0) or
           ((IdxSourceCompareVal(bestSrc, condHiVal, bestHiVal) = 0) and
            (not condHiInc) and bestHiInc) then
        begin
          hasHi := True; bestHiVal := condHiVal; bestHiInc := condHiInc;
        end;
      end;
    end;

    if not foundRange then Exit;   // -> tam tarama
    if hasLo and hasHi then
    begin
      cmpV := IdxSourceCompareVal(bestSrc, bestLoVal, bestHiVal);
      if (cmpV > 0) or ((cmpV = 0) and ((not bestLoInc) or (not bestHiInc))) then
      begin
        IsExact := True;
        if FCountOnly then FCountResult := 0;
        Exit(True);                  // 0 satir, tam tarama gerekmez
      end;
    end;
    // Ayni kolondaki BITISIK araliklarin (>, >=, <, <=, =, BETWEEN) kesisimi
    // WHERE'in tamamini temsil eder. IN AYRIK bir kumedir: [min,max]
    // dilimi aradaki degerleri de kapsar, bu yuzden RowMatches her zaman
    // gerekir. Baska kolondaki/cozulmeyen kosullar da dilime girmez.
    // NULL/BOS anahtar indeksin EN BASINDA durur; yalniz ust sinirli
    // (<, <=) bir dilim onu da kapsar. SQL'de NULL < x bilinmez oldugundan
    // nullable kolonda alt sinir yoksa tam sayim yapilamaz.
    exactRange := (nUsed = conj.Count) and (not hasIn) and
      (hasLower or Td.Cols[bestCol].NotNull);

    // H3 COUNT(*): yalnizca dilimdeki girdileri say. exactRange degilse
    // RowMatches gerektigi icin genel yola don (satir okumadan sayamayiz).
    if FCountOnly then
    begin
      if not exactRange then
      begin
        SetLength(Pks, 0);
        SetLength(Rows, 0);
        Exit;
      end;
      FCountResult := IdxSourceCountBounds(bestSrc, bestLoVal, bestHiVal,
        hasLo, hasHi, bestLoInc, bestHiInc);
      SetLength(Pks, 0);
      SetLength(Rows, 0);
      IsExact := True;
      Exit(True);
    end;

    // ---- R-15 Full CBO: indeks dilimi secici degilse tam tarama ----
    if GetTableStats(Td.Name, st) then
    begin
      covPos := FT.IdxPosOfCol(Td.TableId, bestCol);
      covAll := (covPos >= 0) and FT.IdxCoversAll(Td, covPos);
      // H8: tek esitlikte MCV varsa dilimi saymadan karar ver. Boylece
      // 500k ayni degerli skew'te indeks girdilerini bosuna saymayiz.
      if (not hasIn) and hasLo and hasHi and bestLoInc and bestHiInc and
         (bestLoVal = bestHiVal) and
         VdbStatsMCVLookup(st, Td.Cols[bestCol].Name, bestLoVal, mcvCnt) and
         (not VdbIndexIsSelective(st.RowCount, mcvCnt, covAll)) then
        Exit;
      if not VdbIndexIsSelective(st.RowCount,
        IdxSourceCountBounds(bestSrc, bestLoVal, bestHiVal,
          hasLo, hasHi, bestLoInc, bestHiInc), covAll) then
        Exit;  // False -> cagri FT.ScanRows ile tam tarama yapar
    end;

    // Kullanilacak kolonun dilimini skiplist'ten/diziden al.
    if IdxSourceRangeBounds(bestSrc, bestLoVal, bestHiVal,
      hasLo, hasHi, bestLoInc, bestHiInc, e) <= 0 then
    begin
      SetLength(Pks, 0);
      SetLength(Rows, 0);
      IsExact := exactRange;
      Result := True;
      Exit;
    end;

    SetLength(Pks, Length(e));
    SetLength(Rows, Length(e));
    n := 0;
    covPos := FT.IdxPosOfCol(Td.TableId, bestCol);
    covAll := (covPos >= 0) and FT.IdxCoversAll(Td, covPos);
    for i := 0 to High(e) do
      if covAll and FT.ReadRowCovered(Td, covPos, e[i], oneRow) then
      begin
        Pks[n] := e[i].Pk;
        Rows[n] := oneRow;
        Inc(n);
      end
      else if FT.ReadRow(Td.Name, e[i].Pk, oneRow) then
      begin
        Pks[n] := e[i].Pk;
        Rows[n] := oneRow;
        Inc(n);
      end;
    SetLength(Pks, n);
    SetLength(Rows, n);
    IsExact := exactRange;
    Result := True;
  finally
    conj.Free;
  end;
end;

function TVSqlExecutor.NarrowRows(const Td: TTableDef; WhereClause: TSqlExprNode;
  const ColNames: TStrArray; const ColTypes: TByteArray;
  out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
var
  dummyExact: Boolean;
begin
  Result := NarrowRows(Td, WhereClause, ColNames, ColTypes, Pks, Rows, dummyExact);
end;

function TVSqlExecutor.TryIndexCount(const Td: TTableDef; Stmt: TSqlSelectStmt;
  const ColNames: TStrArray; const ColTypes: TByteArray; out Cnt: Int64): Boolean;
var
  fn: TSqlFuncCallNode;
  pks: TStrArray;
  rows: TStrMatrix;
  exact: Boolean;
  oneCol: Integer;

  { H17: H3'un yalnizca TEK kolonlu WHERE'de kesin sayabildigini onceden
    anlar. Farkli kolon/OR/IN/LIKE varsa indeks kurmaya (pahali) girmeden
    False doner; cagri H17 ham akis yoluna duser. }
  function SameColCond(E: TSqlExprNode; var ACol: Integer): Boolean;
  var
    b: TSqlBinaryOpNode;
    cr: TSqlColumnRefNode;
    ci2: Integer;
  begin
    Result := False;
    if E = nil then Exit(False);
    if E is TSqlBinaryOpNode then
    begin
      b := TSqlBinaryOpNode(E);
      if b.Op = sboAnd then
        Exit(SameColCond(b.Left, ACol) and SameColCond(b.Right, ACol));
      if not (b.Op in [sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte]) then Exit;
      if (b.Left is TSqlColumnRefNode) and (b.Right is TSqlLiteralNode) then
        cr := TSqlColumnRefNode(b.Left)
      else if (b.Right is TSqlColumnRefNode) and (b.Left is TSqlLiteralNode) then
        cr := TSqlColumnRefNode(b.Right)
      else Exit;
    end
    else if (E is TSqlBetweenNode) and (not TSqlBetweenNode(E).IsNot) and
            (TSqlBetweenNode(E).Expr is TSqlColumnRefNode) and
            (TSqlBetweenNode(E).LowBound is TSqlLiteralNode) and
            (TSqlBetweenNode(E).HighBound is TSqlLiteralNode) then
      cr := TSqlColumnRefNode(TSqlBetweenNode(E).Expr)
    else Exit;
    ci2 := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
    if (ci2 < 0) or (ci2 > High(Td.Cols)) then Exit;
    if ACol < 0 then ACol := ci2
    else if ci2 <> ACol then Exit;
    Result := True;
  end;

begin
  Result := False;
  Cnt := 0;
  if Stmt.WhereClause = nil then Exit;
  if Stmt.Columns.Count <> 1 then Exit;
  if not (Stmt.Columns[0].Expr is TSqlFuncCallNode) then Exit;
  fn := TSqlFuncCallNode(Stmt.Columns[0].Expr);
  if (fn.FuncName <> 'COUNT') or (not fn.IsStar) or
     fn.IsDistinct or (fn.Filter <> nil) then Exit;
  if Stmt.FromTable = '' then Exit;
  if Stmt.HasJoin or (Stmt.SetOp <> sokNone) or (Stmt.RightSelect <> nil) then Exit;
  if Stmt.AsOf <> saoNone then Exit;
  if Stmt.WithQueries.Count > 0 then Exit;
  if Stmt.IsDistinct then Exit;
  if Stmt.GroupByCols.Count > 0 then Exit;
  if Stmt.HavingClause <> nil then Exit;
  if Stmt.QualifyClause <> nil then Exit;
  if HasWindow(Stmt) then Exit;
  if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then Exit;
  if (Stmt.LimitVal >= 0) or (Stmt.OffsetVal <> 0) then Exit;
  if Td.IsView then Exit;
  if FT.RlsApplies(Stmt.FromTable) then Exit;
  oneCol := -1;
  if not SameColCond(Stmt.WhereClause, oneCol) then Exit;
  // H18: PK disi indeks hazir degilse BuildOneIndex (tum tabloyu tarar)
  // baslatma; H17 ham akis yolu daha hizli ve ongorulebilir.
  if (oneCol <> Td.PkIndex) and (not FT.IdxSourceReady(Td.TableId, oneCol)) then Exit;
  FCountOnly := True;
  try
    if not NarrowRows(Td, Stmt.WhereClause, ColNames, ColTypes,
      pks, rows, exact) then Exit;
    if not exact then Exit;
    Cnt := FCountResult;
    Result := True;
  finally
    FCountOnly := False;
  end;
end;

type
  { Ham WHERE on-elemesi (H13/H1/H12b ile ayni kayit; yalniz "kesinlikle
    uymuyor" satiri eler, aday yine tam WHERE ile dogrulanir). }
  TRawCond = record
    Col: Integer;
    Op: TSqlBinaryOp;
    IsFloat: Boolean;
    IsText: Boolean;
    IsLike: Boolean;          // H19: LIKE, S = desen
    IsILike: Boolean;         // H19: ILIKE, S = Turkce-duyarli kucuk desen
    IsIn: Boolean;
    InIsFloat: Boolean;
    InInts: array of Int64;
    InFloats: array of Double;
    I: Int64;
    F: Double;
    S: string;
  end;

  TRawCondArray = array of TRawCond;

  { H20: ham boolean agaci. AND/OR/NOT/resim (3VL) tam olarak
    degerlendirilir; yalniz guvenli yapraklar agaca alinir. }
  TRawTreeKind = (rttAnd, rttOr, rttNot, rttCmp, rttLike, rttILike,
    rttIsNull, rttIsNotNull, rttInInt, rttInFloat, rttInStr, rttUnknown);

  TRawTreeInts = array of Int64;
  TRawTreeFloats = array of Double;

  TRawTreeNode = record
    Kind: TRawTreeKind;
    Left, Right: Integer;     // -1 = yok
    Col: Integer;
    Op: TSqlBinaryOp;
    I: Int64;
    F: Double;
    S: string;                // LIKE/ILIKE deseni
    LitNull: Boolean;         // literal NULL veya '' (VDb'de NULL sayilir)
    // H23: uzun IN listeleri icin sirali kume (ikili arama).
    Ints: TRawTreeInts;
    Floats: TRawTreeFloats;
    Strs: TStrArray;
    HasNull: Boolean;
  end;

  TRawTree = array of TRawTreeNode;

  { Ham agac sonucu. rvUnknown SQL UNKNOWN (NULL) demektir; WHERE'te
    secilmez. rvUndecided yalniz guvenli olmayan satir (tip/ASCII/2^53)
    icin doner ve satirin cozulup EvalBool ile denenmesini ister. }
  TRawValue = (rvFalse, rvTrue, rvUnknown, rvUndecided);

  { H17: WHERE'li saf COUNT(*) icin ham akis baglami. }
  TStreamCountCtx = record
    Exec: TVSqlExecutor;
    TableId: Word;
    HashPrefix: QWord;
    ColCnt: Integer;
    FType: TByteArray;
    FOff, FLen: TIntArray;
    ColNames: TStrArray;
    ColTypes: TByteArray;
    Where: TSqlExprNode;
    RawConds: TRawCondArray;
    RawAll: Boolean;          // H18: WHERE tamamen ham kosullarla kesin cozulebilir
    RawTree: TRawTree;        // H20
    RawTreeRoot: Integer;
    NeedIdx: TIntArray;
    MaxCol: Integer;
    Vals: TStrArray;
    Count: Int64;
    Failed: Boolean;
  end;
  PStreamCountCtx = ^TStreamCountCtx;

function VdbStreamSelRawPass(const Conds: array of TRawCond;
  Buf: PByte; const FType: TByteArray; const FOff, FLen: TIntArray): Boolean; forward;
function VdbStreamSelRawPassEx(const Conds: array of TRawCond;
  Buf: PByte; const FType: TByteArray; const FOff, FLen: TIntArray;
  out AllDecided: Boolean): Boolean; forward;
procedure VdbStreamOrderAddRawCond(var Conds: TRawCondArray;
  Exec: TVSqlExecutor; E: TSqlExprNode; const td: TTableDef;
  const ColNames: TStrArray; const ColTypes: TByteArray); forward;
function VdbEvalRawTree(const Tree: TRawTree; Node: Integer;
  Buf: PByte; const FType: TByteArray; const FOff, FLen: TIntArray): TRawValue; forward;

function VdbBuildRawTree(Exec: TVSqlExecutor; E: TSqlExprNode;
  const td: TTableDef; const ColNames: TStrArray;
  const ColTypes: TByteArray; out Root: Integer): TRawTree;
var
  Tree: TRawTree;

  { H20: ham boolean agaci kurucusu. Guvenli olmayan tek bir dugumde
    -1 doner; bu durumda H17/H18 on-elemesi ve genel yol aynen calisir. }
  function TreeAdd(AKind: TRawTreeKind): Integer;
  begin
    Result := Length(Tree);
    SetLength(Tree, Result + 1);
    with Tree[Result] do
    begin
      Kind := AKind;
      Left := -1;
      Right := -1;
      Col := -1;
      Op := sboEq;
      I := 0;
      F := 0;
      S := '';
      LitNull := False;
    end;
  end;

  function SwapCmp(AOp: TSqlBinaryOp): TSqlBinaryOp;
  begin
    case AOp of
      sboLt: Result := sboGt;
      sboLte: Result := sboGte;
      sboGt: Result := sboLt;
      sboGte: Result := sboLte;
    else Result := AOp;
    end;
  end;

  function TreeCmp(ci2: Integer; AOp: TSqlBinaryOp;
    lit: TSqlLiteralNode): Integer;
  const
    SAFE_INT: Int64 = 9007199254740992;
  var
    q, n: Integer;
    isNull: Boolean;
    iv: Int64;
    fv: Double;
    sv: string;
  begin
    Result := -1;
    if (ci2 < 0) or (ci2 > High(td.Cols)) or (ci2 > High(ColTypes)) then Exit;
    if td.Cols[ci2].Encrypted or (td.Cols[ci2].Collate <> '') then Exit;
    if lit = nil then Exit;
    isNull := False; iv := 0; fv := 0; sv := '';
    if ColTypes[ci2] = VCT_INT then
    begin
      if lit.LitType = sltNull then isNull := True
      else if lit.LitType = sltInt then
      begin
        if (lit.IntVal > SAFE_INT) or (lit.IntVal < -SAFE_INT) then Exit;
        iv := lit.IntVal;
      end
      else Exit;
    end
    else if ColTypes[ci2] = VCT_FLOAT then
    begin
      if lit.LitType = sltNull then isNull := True
      else if lit.LitType = sltInt then fv := lit.IntVal
      else if lit.LitType = sltFloat then fv := lit.FloatVal
      else Exit;
    end
    else if ColTypes[ci2] = VCT_STR then
    begin
      if not (AOp in [sboEq, sboNeq]) then Exit;
      if lit.LitType = sltNull then isNull := True
      else if lit.LitType = sltString then
      begin
        for q := 1 to Length(lit.StrVal) do
          if lit.StrVal[q] >= #128 then Exit;
        if lit.StrVal = '' then isNull := True
        else sv := lit.StrVal;
      end
      else Exit;
    end
    else Exit;
    n := TreeAdd(rttCmp);
    with Tree[n] do
    begin
      Col := ci2;
      Op := AOp;
      LitNull := isNull;
      I := iv;
      F := fv;
      S := sv;
    end;
    Result := n;
  end;

  function TreeLike(ci2: Integer; AKind: TRawTreeKind;
    lit: TSqlLiteralNode): Integer;
  var
    q, n: Integer;
    isNull: Boolean;
    pat: string;
  begin
    Result := -1;
    if (ci2 < 0) or (ci2 > High(td.Cols)) or (ci2 > High(ColTypes)) then Exit;
    if td.Cols[ci2].Encrypted or (td.Cols[ci2].Collate <> '') then Exit;
    if ColTypes[ci2] <> VCT_STR then Exit;
    if lit = nil then Exit;
    isNull := False; pat := '';
    if lit.LitType = sltNull then isNull := True
    else if lit.LitType = sltString then
    begin
      for q := 1 to Length(lit.StrVal) do
        if lit.StrVal[q] >= #128 then Exit;
      if lit.StrVal = '' then isNull := True
      else if AKind = rttILike then pat := VDbTrLower(lit.StrVal)
      else pat := lit.StrVal;
    end
    else Exit;
    n := TreeAdd(AKind);
    with Tree[n] do
    begin
      Col := ci2;
      LitNull := isNull;
      S := pat;
    end;
    Result := n;
  end;

  function TreeNode1(AKind: TRawTreeKind; AChild: Integer): Integer;
  begin
    Result := -1;
    if AChild < 0 then Exit;
    Result := TreeAdd(AKind);
    Tree[Result].Left := AChild;
  end;

  function BuildTree(E: TSqlExprNode): Integer;
  var
    b: TSqlBinaryOpNode;
    u: TSqlUnaryOpNode;
    inN: TSqlInNode;
    bt: TSqlBetweenNode;
    cr: TSqlColumnRefNode;
    lit: TSqlLiteralNode;
    ci2, saved, q, l, r, n: Integer;
    opsw: TSqlBinaryOp;
    // H23: IN listesi icin sirali kume (tek dugum, O(log n) arama).
    inInts: TRawTreeInts;
    inFloats: TRawTreeFloats;
    inStrs: TStrArray;
    inNull: Boolean;
    inCnt: Integer;

    procedure SortInts(var A: TRawTreeInts);
    var
      x, y: Integer;
      t: Int64;
    begin
      for x := 1 to High(A) do
      begin
        t := A[x]; y := x - 1;
        while (y >= 0) and (A[y] > t) do
        begin A[y + 1] := A[y]; Dec(y); end;
        A[y + 1] := t;
      end;
    end;

    procedure SortFloats(var A: TRawTreeFloats);
    var
      x, y: Integer;
      t: Double;
    begin
      for x := 1 to High(A) do
      begin
        t := A[x]; y := x - 1;
        while (y >= 0) and (A[y] > t) do
        begin A[y + 1] := A[y]; Dec(y); end;
        A[y + 1] := t;
      end;
    end;

    procedure SortStrs(var A: TStrArray);
    var
      x, y: Integer;
      t: string;
    begin
      for x := 1 to High(A) do
      begin
        t := A[x]; y := x - 1;
        while (y >= 0) and (A[y] > t) do
        begin A[y + 1] := A[y]; Dec(y); end;
        A[y + 1] := t;
      end;
    end;
  begin
    Result := -1;
    if E = nil then Exit;
    saved := Length(Tree);

    if E is TSqlBinaryOpNode then
    begin
      b := TSqlBinaryOpNode(E);
      if (b.Op = sboAnd) or (b.Op = sboOr) then
      begin
        l := BuildTree(b.Left);
        r := BuildTree(b.Right);
        if (l < 0) or (r < 0) then
        begin
          SetLength(Tree, saved);
          Exit;
        end;
        if b.Op = sboAnd then n := TreeAdd(rttAnd)
        else n := TreeAdd(rttOr);
        Tree[n].Left := l;
        Tree[n].Right := r;
        Exit(n);
      end;
      if b.Op in [sboLike, sboILike] then
      begin
        if not ((b.Left is TSqlColumnRefNode) and
                (b.Right is TSqlLiteralNode)) then Exit;
        cr := TSqlColumnRefNode(b.Left);
        lit := TSqlLiteralNode(b.Right);
        ci2 := Exec.FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
        if b.Op = sboLike then Result := TreeLike(ci2, rttLike, lit)
        else Result := TreeLike(ci2, rttILike, lit);
        Exit;
      end;
      if b.Op in [sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte] then
      begin
        if (b.Left is TSqlColumnRefNode) and (b.Right is TSqlLiteralNode) then
        begin
          cr := TSqlColumnRefNode(b.Left);
          lit := TSqlLiteralNode(b.Right);
          opsw := b.Op;
        end
        else if (b.Right is TSqlColumnRefNode) and
                (b.Left is TSqlLiteralNode) then
        begin
          cr := TSqlColumnRefNode(b.Right);
          lit := TSqlLiteralNode(b.Left);
          opsw := SwapCmp(b.Op);
        end
        else Exit;
        ci2 := Exec.FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
        Result := TreeCmp(ci2, opsw, lit);
        Exit;
      end;
      Exit;
    end;

    if E is TSqlUnaryOpNode then
    begin
      u := TSqlUnaryOpNode(E);
      if u.Op = suoNot then
      begin
        l := BuildTree(u.Operand);
        if l < 0 then Exit;
        Result := TreeNode1(rttNot, l);
        Exit;
      end;
      if u.Op in [suoIsNull, suoIsNotNull] then
      begin
        if not (u.Operand is TSqlColumnRefNode) then Exit;
        cr := TSqlColumnRefNode(u.Operand);
        ci2 := Exec.FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
        if (ci2 < 0) or (ci2 > High(td.Cols)) or
           (ci2 > High(ColTypes)) then Exit;
        if td.Cols[ci2].Encrypted then Exit;
        if u.Op = suoIsNull then n := TreeAdd(rttIsNull)
        else n := TreeAdd(rttIsNotNull);
        Tree[n].Col := ci2;
        Exit(n);
      end;
      Exit;
    end;

    if E is TSqlInNode then
    begin
      inN := TSqlInNode(E);
      if inN.SubSelect <> nil then Exit;
      if not (inN.Expr is TSqlColumnRefNode) then Exit;
      if inN.List.Count = 0 then Exit;
      cr := TSqlColumnRefNode(inN.Expr);
      ci2 := Exec.FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
      if (ci2 < 0) or (ci2 > High(td.Cols)) or
         (ci2 > High(ColTypes)) then Exit;
      // Sifreli kolon veya collation'li metinde ham bayt esitligi genel
      // yolla ayni olmayabilir; bu durumda genel yolda kal.
      if td.Cols[ci2].Encrypted or (td.Cols[ci2].Collate <> '') then Exit;
      // H23: IN listesini tek dugumde sirali kume olarak tut. Uzun listelerde
      // satir basina O(n) karsilastirma yerine O(log n) ikili arama yapilir.
      if not (ColTypes[ci2] in [VCT_INT, VCT_FLOAT, VCT_STR]) then Exit;
      inNull := False;
      inCnt := 0;
      SetLength(inInts, 0); SetLength(inFloats, 0); SetLength(inStrs, 0);
      for q := 0 to inN.List.Count - 1 do
      begin
        if not (inN.List[q] is TSqlLiteralNode) then
        begin
          SetLength(Tree, saved);
          Exit;
        end;
        lit := TSqlLiteralNode(inN.List[q]);
        if lit.LitType = sltNull then
        begin
          inNull := True;
          Continue;
        end;
        if ColTypes[ci2] = VCT_INT then
        begin
          if lit.LitType <> sltInt then
          begin SetLength(Tree, saved); Exit; end;
          if (lit.IntVal > 9007199254740992) or
             (lit.IntVal < -9007199254740992) then
          begin SetLength(Tree, saved); Exit; end;
          SetLength(inInts, inCnt + 1);
          inInts[inCnt] := lit.IntVal; Inc(inCnt);
        end
        else if ColTypes[ci2] = VCT_FLOAT then
        begin
          if lit.LitType = sltInt then
          begin
            SetLength(inFloats, inCnt + 1);
            inFloats[inCnt] := lit.IntVal;
          end
          else if lit.LitType = sltFloat then
          begin
            if lit.FloatVal <> lit.FloatVal then
            begin SetLength(Tree, saved); Exit; end;   // NaN siralamayi bozar
            SetLength(inFloats, inCnt + 1);
            inFloats[inCnt] := lit.FloatVal;
          end
          else
          begin SetLength(Tree, saved); Exit; end;
          Inc(inCnt);
        end
        else
        begin
          if lit.LitType <> sltString then
          begin SetLength(Tree, saved); Exit; end;
          for n := 1 to Length(lit.StrVal) do
            if lit.StrVal[n] >= #128 then
            begin SetLength(Tree, saved); Exit; end;
          if lit.StrVal = '' then
            inNull := True
          else
          begin
            SetLength(inStrs, inCnt + 1);
            inStrs[inCnt] := lit.StrVal; Inc(inCnt);
          end;
        end;
      end;
      if inCnt = 0 then
      begin
        // Yalniz NULL: her satir icin UNKNOWN.
        if inNull then
        begin
          l := TreeAdd(rttUnknown);
          if inN.IsNot then l := TreeNode1(rttNot, l);
          Result := l;
          Exit;
        end;
        SetLength(Tree, saved);
        Exit;
      end;
      if ColTypes[ci2] = VCT_INT then
      begin
        SortInts(inInts);
        l := TreeAdd(rttInInt);
        Tree[l].Ints := inInts;
      end
      else if ColTypes[ci2] = VCT_FLOAT then
      begin
        SortFloats(inFloats);
        l := TreeAdd(rttInFloat);
        Tree[l].Floats := inFloats;
      end
      else
      begin
        SortStrs(inStrs);
        l := TreeAdd(rttInStr);
        Tree[l].Strs := inStrs;
      end;
      Tree[l].Col := ci2;
      Tree[l].HasNull := inNull;
      if inN.IsNot then l := TreeNode1(rttNot, l);
      Result := l;
      Exit;
    end;

    if E is TSqlBetweenNode then
    begin
      bt := TSqlBetweenNode(E);
      if not (bt.Expr is TSqlColumnRefNode) then Exit;
      if not (bt.LowBound is TSqlLiteralNode) or
         not (bt.HighBound is TSqlLiteralNode) then Exit;
      // Genel yol, iki sinirdan biri NULL ise BETWEEN'in TAMAMINI UNKNOWN
      // dondurur (kisa devre). Ayni davranisi koru; desenlemek yanlis olur.
      if (TSqlLiteralNode(bt.LowBound).LitType = sltNull) or
         (TSqlLiteralNode(bt.HighBound).LitType = sltNull) or
         ((TSqlLiteralNode(bt.LowBound).LitType = sltString) and
          (TSqlLiteralNode(bt.LowBound).StrVal = '')) or
         ((TSqlLiteralNode(bt.HighBound).LitType = sltString) and
          (TSqlLiteralNode(bt.HighBound).StrVal = '')) then
      begin
        Result := TreeAdd(rttUnknown);
        Exit;
      end;
      cr := TSqlColumnRefNode(bt.Expr);
      ci2 := Exec.FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
      l := TreeCmp(ci2, sboGte, TSqlLiteralNode(bt.LowBound));
      r := TreeCmp(ci2, sboLte, TSqlLiteralNode(bt.HighBound));
      if (l < 0) or (r < 0) then
      begin
        SetLength(Tree, saved);
        Exit;
      end;
      n := TreeAdd(rttAnd);
      Tree[n].Left := l;
      Tree[n].Right := r;
      if bt.IsNot then n := TreeNode1(rttNot, n);
      Result := n;
      Exit;
    end;
  end;


begin
  Tree := nil;
  Root := BuildTree(E);
  Result := Tree;
end;

function VdbStreamCountCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
var
  C: PStreamCountCtx;
  tid: Word;
  kh: QWord;
  i: Integer;
  decided: Boolean;
begin
  C := User;
  Result := True;
  if Key = VDB_SCHEMA_KEY then Exit;
  if not VDbPeekRawRowKeyHashTo(Buf, Len, C^.ColCnt, tid, C^.HashPrefix,
       kh, C^.MaxCol, C^.FType, C^.FOff, C^.FLen) then
  begin
    C^.Failed := True; Exit(False);
  end;
  if tid <> C^.TableId then Exit;
  if kh <> Key then
  begin
    C^.Failed := True; Exit(False);
  end;
  // H20: WHERE'in tam boolean agaci ham baytlardan kesin cozulebiliyorsa
  // AND/OR/NOT/NULL uc-degerli mantigiyla say; yalniz guvenli olmayan
  // satirlarda cozme yoluna dus.
  if C^.RawTreeRoot >= 0 then
  begin
    case VdbEvalRawTree(C^.RawTree, C^.RawTreeRoot, Buf, C^.FType,
      C^.FOff, C^.FLen) of
      rvFalse, rvUnknown: Exit;
      rvTrue:
        begin
          Inc(C^.Count);
          Exit;
        end;
      // rvUndecided: asagidaki ham on-eleme ve cozme yolu devam eder.
    end;
  end;
  // H17: basit AND kosullarinda satiri cozmeden kesin eleme.
  // H18: WHERE tamamen ham kosullardan olusuyorsa ve satir tip/ASCII
  // guvenliyse hic string cozmeden say.
  if Length(C^.RawConds) > 0 then
  begin
    if not VdbStreamSelRawPassEx(C^.RawConds, Buf, C^.FType,
         C^.FOff, C^.FLen, decided) then Exit;
    if C^.RawAll and decided then
    begin
      Inc(C^.Count);
      Exit;
    end;
  end;
  for i := 0 to High(C^.NeedIdx) do
    C^.Vals[C^.NeedIdx[i]] := VDbColFromOffsetsP(Buf, C^.ColCnt,
      C^.NeedIdx[i], C^.FType, C^.FOff, C^.FLen);
  if C^.Exec.EvalBool(C^.Where, C^.Vals, C^.ColNames, C^.ColTypes) then
    Inc(C^.Count);
end;

function TVSqlExecutor.TryStreamFilteredCount(Stmt: TSqlSelectStmt;
  const td: TTableDef; const ColNames: TStrArray;
  const ColTypes: TByteArray; out Res: TSqlResult): Boolean;
var
  fn: TSqlFuncCallNode;
  need: array of Boolean;
  ctx: TStreamCountCtx;
  i, maxCol, root: Integer;

  { WHERE'in referans verdigi kolonlari toplar. Alt sorgu, pencere ve
    aggregate dugumlerinde False doner: bunlar genel yolda kalir. }
  function Walk(E: TSqlExprNode): Boolean;
  var
    q: Integer;
  begin
    Result := False;
    if E = nil then Exit(True);
    if E is TSqlLiteralNode then Exit(True);
    if E is TSqlColumnRefNode then
    begin
      q := FindColIdx(TSqlColumnRefNode(E).ColumnName,
                      TSqlColumnRefNode(E).TableQualifier, ColNames);
      if (q < 0) or (q > High(need)) then Exit(False);
      need[q] := True;
      Exit(True);
    end;
    if E is TSqlBinaryOpNode then
      Exit(Walk(TSqlBinaryOpNode(E).Left) and
           Walk(TSqlBinaryOpNode(E).Right));
    if E is TSqlUnaryOpNode then
      Exit(Walk(TSqlUnaryOpNode(E).Operand));
    if E is TSqlCastNode then
      Exit(Walk(TSqlCastNode(E).Expr));
    if E is TSqlCollateNode then
      Exit(Walk(TSqlCollateNode(E).Inner));
    if E is TSqlNullIfNode then
      Exit(Walk(TSqlNullIfNode(E).Arg1) and Walk(TSqlNullIfNode(E).Arg2));
    if E is TSqlCoalesceNode then
    begin
      for q := 0 to TSqlCoalesceNode(E).Args.Count - 1 do
        if not Walk(TSqlCoalesceNode(E).Args[q]) then Exit(False);
      Exit(True);
    end;
    if E is TSqlFuncCallNode then
    begin
      // FTS eslesmesi tablo baglamina baglidir; genel yolda kalsin.
      if SameText(TSqlFuncCallNode(E).FuncName, 'TS_MATCH') then Exit(False);
      // WHERE icinde aggregate gecersizdir; hata genel yolda uretilsin.
      if IsAggFuncName(TSqlFuncCallNode(E).FuncName) then Exit(False);
      if not Walk(TSqlFuncCallNode(E).Arg) then Exit(False);
      if not Walk(TSqlFuncCallNode(E).Filter) then Exit(False);
      if TSqlFuncCallNode(E).Args <> nil then
        for q := 0 to TSqlFuncCallNode(E).Args.Count - 1 do
          if not Walk(TSqlFuncCallNode(E).Args[q]) then Exit(False);
      Exit(True);
    end;
    if E is TSqlInNode then
    begin
      if TSqlInNode(E).SubSelect <> nil then Exit(False);
      if not Walk(TSqlInNode(E).Expr) then Exit(False);
      for q := 0 to TSqlInNode(E).List.Count - 1 do
        if not Walk(TSqlInNode(E).List[q]) then Exit(False);
      Exit(True);
    end;
    if E is TSqlBetweenNode then
      Exit(Walk(TSqlBetweenNode(E).Expr) and
           Walk(TSqlBetweenNode(E).LowBound) and
           Walk(TSqlBetweenNode(E).HighBound));
    if E is TSqlCaseNode then
    begin
      if not Walk(TSqlCaseNode(E).Operand) then Exit(False);
      for q := 0 to TSqlCaseNode(E).Whens.Count - 1 do
        if (not Walk(TSqlCaseNode(E).Whens[q].Cond)) or
           (not Walk(TSqlCaseNode(E).Whens[q].Value)) then Exit(False);
      Exit(Walk(TSqlCaseNode(E).ElseExpr));
    end;
    if E is TSqlJsonKeyNode then
    begin
      if not Walk(TSqlJsonKeyNode(E).Left) then Exit(False);
      for q := 0 to TSqlJsonKeyNode(E).Keys.Count - 1 do
        if not Walk(TSqlJsonKeyNode(E).Keys[q]) then Exit(False);
      Exit(True);
    end;
    // TSqlSubqueryNode / TSqlQuantNode / TSqlAggNode / TSqlWindowNode /
    // bilinmeyen dugum: genel yol.
  end;

  { H18: WHERE'in TAMAMI ham kosullarla kesin cozulebilir mi? Yalniz
    AND'lenen, tek kolon/literal karsilastirmalari; INT icin 2^53 siniri
    (genel yol Double ile kiyaslar), TEXT icin yalniz ASCII esitlik/
    esitsizlik. Guvenli degilse False -> eski cozme+EvalBool yolu. }
  function RawCover(E: TSqlExprNode): Boolean;
  const
    SAFE_INT: Int64 = 9007199254740992;
  var
    b: TSqlBinaryOpNode;
    cr: TSqlColumnRefNode;
    lit: TSqlLiteralNode;
    ci2, q: Integer;
  begin
    Result := False;
    if E = nil then Exit(False);
    if E is TSqlBinaryOpNode then
    begin
      b := TSqlBinaryOpNode(E);
      if b.Op = sboAnd then
        Exit(RawCover(b.Left) and RawCover(b.Right));
      if b.Op in [sboLike, sboILike] then
      begin
        if not ((b.Left is TSqlColumnRefNode) and
                (b.Right is TSqlLiteralNode)) then Exit;
        cr := TSqlColumnRefNode(b.Left);
        lit := TSqlLiteralNode(b.Right);
        ci2 := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
        if (ci2 < 0) or (ci2 > High(td.Cols)) or (ci2 > High(ColTypes)) then Exit;
        if td.Cols[ci2].Encrypted or (td.Cols[ci2].Collate <> '') then Exit;
        if ColTypes[ci2] <> VCT_STR then Exit;
        if lit.LitType <> sltString then Exit;
        for q := 1 to Length(lit.StrVal) do
          if lit.StrVal[q] >= #128 then Exit(False);
        Exit(True);
      end;
      if not (b.Op in [sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte]) then Exit;
      if (b.Left is TSqlColumnRefNode) and (b.Right is TSqlLiteralNode) then
      begin
        cr := TSqlColumnRefNode(b.Left);
        lit := TSqlLiteralNode(b.Right);
      end
      else if (b.Right is TSqlColumnRefNode) and (b.Left is TSqlLiteralNode) then
      begin
        cr := TSqlColumnRefNode(b.Right);
        lit := TSqlLiteralNode(b.Left);
      end
      else Exit;
      ci2 := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
      if (ci2 < 0) or (ci2 > High(td.Cols)) or (ci2 > High(ColTypes)) then Exit;
      if td.Cols[ci2].Encrypted or (td.Cols[ci2].Collate <> '') then Exit;
      if ColTypes[ci2] = VCT_INT then
      begin
        if lit.LitType <> sltInt then Exit;
        if (lit.IntVal > SAFE_INT) or (lit.IntVal < -SAFE_INT) then Exit;
        Exit(True);
      end;
      if ColTypes[ci2] = VCT_FLOAT then
        Exit((lit.LitType = sltInt) or (lit.LitType = sltFloat));
      if ColTypes[ci2] = VCT_STR then
      begin
        if not (b.Op in [sboEq, sboNeq]) then Exit;
        if lit.LitType <> sltString then Exit;
        for q := 1 to Length(lit.StrVal) do
          if lit.StrVal[q] >= #128 then Exit(False);
        Exit(True);
      end;
    end;
  end;

begin
  Result := False;
  if Stmt.WhereClause = nil then Exit;
  if Stmt.Columns.Count <> 1 then Exit;
  if not (Stmt.Columns[0].Expr is TSqlFuncCallNode) then Exit;
  fn := TSqlFuncCallNode(Stmt.Columns[0].Expr);
  if (fn.FuncName <> 'COUNT') or (not fn.IsStar) or
     fn.IsDistinct or (fn.Filter <> nil) then Exit;
  if Stmt.FromTable = '' then Exit;
  if Stmt.HasJoin or (Stmt.SetOp <> sokNone) or (Stmt.RightSelect <> nil) then Exit;
  if Stmt.AsOf <> saoNone then Exit;
  if Stmt.WithQueries.Count > 0 then Exit;
  if Stmt.IsDistinct then Exit;
  if Stmt.GroupByCols.Count > 0 then Exit;
  if Stmt.HavingClause <> nil then Exit;
  if Stmt.QualifyClause <> nil then Exit;
  if HasWindow(Stmt) then Exit;
  if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then Exit;
  if (Stmt.LimitVal >= 0) or (Stmt.OffsetVal <> 0) then Exit;
  if td.IsView then Exit;
  if FT.RlsApplies(Stmt.FromTable) then Exit;
  SetLength(need, Length(td.Cols));
  if not Walk(Stmt.WhereClause) then Exit;
  ctx := Default(TStreamCountCtx);
  maxCol := -1;
  for i := 0 to High(need) do
    if need[i] then
    begin
      SetLength(ctx.NeedIdx, Length(ctx.NeedIdx) + 1);
      ctx.NeedIdx[High(ctx.NeedIdx)] := i;
      if i > maxCol then maxCol := i;
    end;
  ctx.Exec := Self;
  ctx.TableId := td.TableId;
  ctx.HashPrefix := VDbHashKeyPrefix(td.Name);
  ctx.ColCnt := Length(td.Cols);
  SetLength(ctx.FType, ctx.ColCnt);
  SetLength(ctx.FOff, ctx.ColCnt);
  SetLength(ctx.FLen, ctx.ColCnt);
  SetLength(ctx.Vals, ctx.ColCnt);
  ctx.ColNames := ColNames;
  ctx.ColTypes := ColTypes;
  ctx.Where := Stmt.WhereClause;
  ctx.RawConds := nil;
  VdbStreamOrderAddRawCond(ctx.RawConds, Self, Stmt.WhereClause, td,
    ColNames, ColTypes);
  ctx.RawAll := RawCover(Stmt.WhereClause);
  ctx.RawTree := VdbBuildRawTree(Self, Stmt.WhereClause, td, ColNames,
    ColTypes, root);
  ctx.RawTreeRoot := root;
  ctx.MaxCol := maxCol;
  ctx.Count := 0;
  ctx.Failed := False;
  if not FT.Kv.ScanRawIterAll(td.TableId, VdbStreamCountCb, @ctx) then Exit;
  if ctx.Failed then Exit;
  SetLength(Res.Fields, 1);
  if Stmt.Columns[0].Alias <> '' then Res.Fields[0] := Stmt.Columns[0].Alias
  else Res.Fields[0] := fn.FuncName;
  SetLength(Res.FieldTypes, 1);
  Res.FieldTypes[0] := VCT_INT;
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], 1);
  Res.Rows[0][0] := IntToStr(ctx.Count);
  Res.Affected := 1;
  Res.Msg := 'OK';
  Result := True;
end;

function TVSqlExecutor.TryIndexOrder(const Td: TTableDef; Stmt: TSqlSelectStmt;
  const ColNames: TStrArray; const ColTypes: TByteArray;
  out Rows: TStrMatrix): Boolean;
// ORDER BY <indeksli kolon(lar)> -> satirlari indeks sirasiyla oku.
// COK KOLONLU: ORDER BY a, b ile indeksin (a, b) on ek'i eslesiyorsa
// hicbir siralama yapilmaz; satirlar indeks sirasiyla okunur.
var
  e: TIdxEntries;
  src: TIdxSource;
  hasLo, hasHi, loInc, hiInc: Boolean;
  loVal, hiVal: string;
  cmpV: Integer;
  ci, lo, hi, l2, h2, i, j, n, off, lim, need: Integer;
  desc: Boolean;
  descAny: Boolean;
  rv: TStrArray;
  cr: TSqlColumnRefNode;
  conj: TList<TSqlExprNode>;
  node: TSqlBinaryOpNode;
  opName: string;
  pkVal: string;
  oCols: TIntArray;      // ORDER BY kolonlari (tablo indeksleri)
  icols: TIntArray;      // indeksin kolonlari
  nIdxCols: Integer;     // indeksin kac kolonu
  leadingMatch: Integer; // ORDER BY'nin indeks on ekiyle eslesen kolon sayisi
  cap: Integer;          // KR-2: geometrik kapasite
  // H22: ikincil indekste derin OFFSET icin hafif canlilik denetimi.
  pkFType: TByteArray;
  pkFOff, pkFLen: TIntArray;
  liveVals: TStrArray;

  function EntryLive(const Pk: string): Boolean;
  var
    b: TBytes;
    tid: Word;
    apk: string;
  begin
    Result := False;
    if Pk = '' then Exit;
    if not FT.Kv.Get(VDbHashKey(Td.Name, Pk), b) then Exit;
    if Length(b) = 0 then Exit;
    if VDbPeekRawRowP(@b[0], Length(b), Length(Td.Cols), tid, apk,
         pkFType, pkFOff, pkFLen) then
      Result := (tid = Td.TableId) and (apk = Pk)
    else
      // Eski sema/bozuk satir: tam okuma ile AYNI gorunurluk karari.
      Result := FT.ReadRow(Td.Name, Pk, liveVals);
  end;

  procedure Push(C: TSqlExprNode);
  begin
    if (C is TSqlBinaryOpNode) and (TSqlBinaryOpNode(C).Op = sboAnd) then
    begin
      Push(TSqlBinaryOpNode(C).Left);
      Push(TSqlBinaryOpNode(C).Right);
    end
    else
      conj.Add(C);
  end;

begin
  SetLength(Rows, 0);
  Result := False;
  // Yalniz: JOIN yok, aggregate yok, GROUP BY yok, DISTINCT yok,
  // pencere yok, ORDER BY kolonlari ve hepsi kolon referansi olmali.
  if Stmt.HasJoin or Stmt.IsDistinct then Exit;
  if HasAggregate(Stmt) or (Stmt.GroupByCols.Count > 0) then Exit;
  if HasWindow(Stmt) then Exit; // pencere tum kumeyi gorur (LIMIT oncesi)
  // P5-TR/R-20: indeks sirasi bayt duzenidir; acik COLLATE DoSort'a birakilir.
  if (Stmt.OrderBy <> nil) then
    for i := 0 to Stmt.OrderBy.Count - 1 do
      if Stmt.OrderBy[i].Collate <> '' then Exit;
  if (Stmt.OrderBy = nil) or (Stmt.OrderBy.Count = 0) then Exit;
  for i := 0 to Stmt.OrderBy.Count - 1 do
    if not (Stmt.OrderBy[i].Expr is TSqlColumnRefNode) then Exit;
  { LIMIT/OFFSET YOKSA indeksten tek tek ReadRow yapmak TAM TARAMA + siralamadan
    YAVAS kalir (her satir rastgele seek). Bu durumda eski yol tercih edilir;
    WHERE ile daraltma zaten NarrowRows'ta devreye giriyor. }
  if (Stmt.LimitVal < 0) and (Stmt.OffsetVal <= 0) then Exit;

  // ORDER BY kolonlarini coz
  SetLength(oCols, Stmt.OrderBy.Count);
  for i := 0 to Stmt.OrderBy.Count - 1 do
  begin
    cr := TSqlColumnRefNode(Stmt.OrderBy[i].Expr);
    oCols[i] := -1;
    for j := 0 to High(Td.Cols) do
      if VDbNorm(Td.Cols[j].Name) = VDbNorm(cr.ColumnName) then
      begin oCols[i] := j; Break; end;
    if oCols[i] < 0 then Exit;
  end;

  // Bilesik (farkli yonler) siralama indeksten saglanamaz.
  descAny := False;
  for i := 1 to Stmt.OrderBy.Count - 1 do
    if Stmt.OrderBy[i].Desc <> Stmt.OrderBy[0].Desc then descAny := True;
  if descAny then Exit;

  ci := oCols[0];
  if not FT.TryGetIdxSource(Td.TableId, ci, src) then Exit;
  nIdxCols := FT.IdxNParts(Td.TableId, ci);
  if Stmt.OrderBy.Count > nIdxCols then Exit;

  // ORDER BY kolonlari indeksin on ekiyle SIRAYLA eslesmeli
  icols := FT.IdxColsOfTable(Td.TableId, ci);
  if Length(icols) = 0 then Exit;
  leadingMatch := 0;
  for i := 0 to Stmt.OrderBy.Count - 1 do
    if icols[i] = oCols[i] then Inc(leadingMatch) else Break;
  if leadingMatch < Stmt.OrderBy.Count then Exit;

  desc := Stmt.OrderBy[0].Desc;

  // WHERE ile dilim daralt (yalnizca ILK ORDER BY kolonu uzerinden; boylece
  // dilim icinde indeks sirasi ORDER BY sirasiyla ayni kalir)
  hasLo := False; hasHi := False; loInc := True; hiInc := True;
  loVal := ''; hiVal := '';
  conj := TList<TSqlExprNode>.Create;
  try
    if Stmt.WhereClause <> nil then Push(Stmt.WhereClause);
    for i := 0 to conj.Count - 1 do
    begin
      opName := '';
      if (conj[i] is TSqlBinaryOpNode) then
      begin
        node := TSqlBinaryOpNode(conj[i]);
        if node.Right is TSqlLiteralNode then
          case node.Op of
            sboEq:  opName := '=';
            sboGt:  opName := '>';
            sboGte: opName := '>=';
            sboLt:  opName := '<';
            sboLte: opName := '<=';
          end;
      end;
      if opName = '' then Continue;   // bu kosulu indeksleyemeyiz -> daraltma
      if not (TSqlBinaryOpNode(conj[i]).Left is TSqlColumnRefNode) then Continue;
      if VDbNorm(TSqlColumnRefNode(TSqlBinaryOpNode(conj[i]).Left).ColumnName) <>
         VDbNorm(Td.Cols[ci].Name) then Continue;
      pkVal := TSqlLiteralNode(node.Right).AsString;
      case node.Op of
        sboEq:
          begin
            if (not hasLo) or (IdxSourceCompareVal(src, pkVal, loVal) > 0) then
            begin hasLo := True; loVal := pkVal; loInc := True; end
            else if (IdxSourceCompareVal(src, pkVal, loVal) = 0) then
              loInc := loInc and True;
            if (not hasHi) or (IdxSourceCompareVal(src, pkVal, hiVal) < 0) then
            begin hasHi := True; hiVal := pkVal; hiInc := True; end
            else if (IdxSourceCompareVal(src, pkVal, hiVal) = 0) then
              hiInc := hiInc and True;
          end;
        sboGt, sboGte:
          begin
            if (not hasLo) or (IdxSourceCompareVal(src, pkVal, loVal) > 0) or
               ((IdxSourceCompareVal(src, pkVal, loVal) = 0) and
                (node.Op = sboGt)) then
            begin hasLo := True; loVal := pkVal; loInc := node.Op = sboGte; end;
          end;
        sboLt, sboLte:
          begin
            if (not hasHi) or (IdxSourceCompareVal(src, pkVal, hiVal) < 0) or
               ((IdxSourceCompareVal(src, pkVal, hiVal) = 0) and
                (node.Op = sboLt)) then
            begin hasHi := True; hiVal := pkVal; hiInc := node.Op = sboLte; end;
          end;
      end;
    end;
  finally
    conj.Free;
  end;
  IdxSourceRangeBounds(src, loVal, hiVal, hasLo, hasHi, loInc, hiInc, e);
  lo := 0; hi := Length(e);
  if hi <= lo then
  begin
    // bos dilim: siralama yolu da dogru bos sonuc verir.
    Result := True;
    Exit;
  end;

  off := Stmt.OffsetVal;
  lim := Stmt.LimitVal;
  if lim = 0 then
  begin
    SetLength(Rows, 0);
    Result := True;
    Exit;
  end;
  need := lim;
  if need < 0 then need := -1;
  // KR-2: geometrik kapasite buyumesi — SetLength(+1) kopyalamasi engellenir.
  // LIMIT varsa cap'i ilk tahsis olarak LIMIT degerine esitle (cok buyuk
  // LIMIT icin (hi-lo) ile sinirla); yoksa 64'ten basla ve 2x buyut.
  if (need > 0) and (need <= hi - lo) then cap := need
  else if hi - lo < 64 then cap := hi - lo
  else cap := 64;
  if cap < 1 then cap := 1;
  SetLength(Rows, cap);
  n := 0;
  { WHERE yoksa PK indeksindeki her giris canli bir satirdir. OFFSET'i
    okuma sirasinda tek tek atlamak yerine dogrudan indeks konumuna atla;
    derin OFFSET'te yuz binlerce satir okumak gerekmez. Ikincil
    indekslerde eski/olu giris olabilecegi icin bu yol yalniz PK'de. }
  if (Stmt.WhereClause = nil) and (ci = Td.PkIndex) then
  begin
    if off >= hi - lo then
    begin
      SetLength(Rows, 0);
      Result := True;
      Exit;
    end;
    if desc then i := hi - 1 - off else i := lo + off;
    while (i >= lo) and (i < hi) do
    begin
      if FT.ReadRow(Td.Name, e[i].Pk, rv) then
      begin
        if n >= cap then begin cap := cap * 2; SetLength(Rows, cap); end;
        Rows[n] := rv; Inc(n);
        if (need >= 0) and (n >= need) then Break;
      end;
      if desc then Dec(i) else Inc(i);
    end;
  end
  else if Stmt.WhereClause = nil then
  begin
    // H22: WHERE yok, ikincil indeks. OFFSET'i satirlari tam cozmeden
    // atla; yalnizca indeks girdisinin canli bir satira isaret ettigini
    // dogrula. Boylece olu/silinmis girdiler OFFSET sayimini bozmaz.
    SetLength(pkFType, Length(Td.Cols));
    SetLength(pkFOff, Length(Td.Cols));
    SetLength(pkFLen, Length(Td.Cols));
    if desc then i := hi - 1 else i := lo;
    while (i >= lo) and (i < hi) and (off > 0) do
    begin
      if EntryLive(e[i].Pk) then Dec(off);
      if desc then Dec(i) else Inc(i);
    end;
    while (i >= lo) and (i < hi) do
    begin
      if EntryLive(e[i].Pk) and FT.ReadRow(Td.Name, e[i].Pk, rv) then
      begin
        if n >= cap then begin cap := cap * 2; SetLength(Rows, cap); end;
        Rows[n] := rv; Inc(n);
        if (need >= 0) and (n >= need) then Break;
      end;
      if desc then Dec(i) else Inc(i);
    end;
  end
  else if desc then
  begin
    i := hi - 1;
    while i >= lo do
    begin
      if FT.ReadRow(Td.Name, e[i].Pk, rv) and
         RowMatches(Stmt.WhereClause, rv, ColNames, ColTypes) then
      begin
        if off > 0 then Dec(off)
        else
        begin
          if n >= cap then begin cap := cap * 2; SetLength(Rows, cap); end;
          Rows[n] := rv; Inc(n);
          if (need >= 0) and (n >= need) then Break;
        end;
      end;
      Dec(i);
    end;
  end
  else
  begin
    i := lo;
    while i < hi do
    begin
      if FT.ReadRow(Td.Name, e[i].Pk, rv) and
         RowMatches(Stmt.WhereClause, rv, ColNames, ColTypes) then
      begin
        if off > 0 then Dec(off)
        else
        begin
          if n >= cap then begin cap := cap * 2; SetLength(Rows, cap); end;
          Rows[n] := rv; Inc(n);
          if (need >= 0) and (n >= need) then Break;
        end;
      end;
      Inc(i);
    end;
  end;
  SetLength(Rows, n);
  Result := True;
end;

type
  TSortColInfo = record
    ColIdx: Integer;
    CType: Byte;
    Desc: Boolean;
    // R-20: ORDER BY ... COLLATE <ad>. Bos = motor varsayilani (bayt
    // sirasi). TR eski davranisi verir; digerleri VDbCompareCol'a gider.
    Collate: string;
    UseTr: Boolean;  // acik COLLATE (yalniz metin kolonlarda)
    // F-10: NULLS FIRST (0) / LAST (1); -1 = motor varsayilani
    NullsPos: Integer;
  end;

type
  { R-14 Full: siralama kolonlari dizisi (birim duzeyinde; paralel
    gorevlerin baglam kaydinda tasinir). }
  TVdbSortCols = array of TSortColInfo;

  { H14: tekil FLOAT kolonunda onceden cozulmus anahtar plani. Anahtarlar
    SATIR-INDEKSLI (Idx dizisi satir numarasi tutar). Genel yolda her
    kiyasta VDbParseFloat cagriliyordu; 1M satirda ~60 s suruyordu. }
  TSortFloatPlan = record
    Keys: array of Double;   // satir-indeksli sayisal anahtarlar
    Null: TByteArray;        // satir-indeksli NULL bayragi (1 = NULL)
    Desc: Boolean;
    Valid: Boolean;          // tum degerler sayisala donustu mu?
  end;

  { R-14 Full: paralel siralama gorev baglami. Parca quicksort'u ve
    birlestirme turlari bu kaydin alanlarini okur; yalnizca Idx
    dizisinin goreve ayrilmis araligina yazilir (thread-guvenli). }
  PVdbSortTask = ^TVdbSortTask;
  TVdbSortTask = record
    Idx: TIntArray;            // siralanan satir indeksleri (parcali yazim)
    Rows: TStrMatrix;          // salt-okunur satir deposu
    Cols: TVdbSortCols;        // salt-okunur siralama kolonlari
    IntKeys: array of Int64;   // UseInt: satir-indeksli anahtarlar
    UseInt: Boolean;           // tekil tamsayi kolonu hizli yolu
    IntDesc: Boolean;
    { H14: tekil FLOAT kolonu hizli yolu. Anahtarlar satir basina ONCEDEN
      cozulur; karsilastirmada VDbParseFloat cagrilmaz. }
    Plan: TSortFloatPlan;      // Valid = True ise float anahtarlari hazir
  end;

  { R-14 Full: bir birlestirme turunun baglami. Src'den Dst'ye; her
    gorev kendi bitisik parca ciftini yazar (araliklar ayrik). }
  PVdbMergeTask = ^TVdbMergeTask;
  TVdbMergeTask = record
    Sort: PVdbSortTask;
    Src: TIntArray;
    Dst: TIntArray;
    Bounds: TIntArray;         // parca sinirlari (chunks+1 eleman)
    Run: Integer;              // bu turda birlestirilen parca genisligi
  end;

{ Eski icice CompareRowIdx'nin birim-duzeyi hali (govde birebir ayni):
  hem seri quicksort hem paralel isçiler burayi cagirir. Rows/Cols
  siralama sirasinda salt-okunurdur; VDbLangProfile/VDbCompareCol gibi
  yardimcilar durumu olmayan (pure) okumalardir. }
function VdbSortCompareRows(const Cols: TVdbSortCols; const Rows: TStrMatrix;
  ra, rb: Integer): Integer;
var
  sk, sc: Integer;
  sct: Byte;
  sav, sbv: string;
  tc: Integer;
  aNull, bNull: Boolean;
  np: Integer;
  LangP: TVDbLang;   // R-20
begin
  Result := 0;
  for sk := 0 to High(Cols) do
  begin
    sc := Cols[sk].ColIdx;
    sct := Cols[sk].CType;
    if (sc >= 0) and (sc < Length(Rows[ra])) then sav := Rows[ra][sc] else sav := '';
    if (sc >= 0) and (sc < Length(Rows[rb])) then sbv := Rows[rb][sc] else sbv := '';
    // F-10: NULLS FIRST / LAST. VDbCmpVal NULL'i zaten "en kucuk"
    // sayar; burada konumu acikca yonlendiriyoruz.
    aNull := (sav = '');
    bNull := (sbv = '');
    if aNull or bNull then
    begin
      if aNull and bNull then Continue;   // ikisi de NULL -> sonraki anahtar
      np := Cols[sk].NullsPos;
      if np < 0 then
      begin
        // SQL:2003 varsayilani: NULL "en kucuk" sayilir. Bu yon
        // DESC ile TERSLENIR (ASC -> once, DESC -> sonra).
        if aNull then Result := -1 else Result := 1;
        if Cols[sk].Desc then Result := -Result;
      end
      else
      begin
        // NULLS FIRST(0) -> NULL daima once; NULLS LAST(1) -> daima sonra.
        // Bu konum yone bagli DEGILDIR: DESC terslemez.
        if aNull then
        begin
          if np = 0 then Result := -1 else Result := 1;
        end
        else
        begin
          if np = 0 then Result := 1 else Result := -1;
        end;
      end;
      Exit;
    end;
    if Cols[sk].Collate <> '' then
    begin
      { R-20: acik COLLATE -> o dil profili ile karsilastir.
        Profil her karsilastirmada yeniden cozulur. }
      if VDbLangProfile(Cols[sk].Collate, LangP) then
        tc := VDbCompareCol(sav, sbv, LangP)
      else
        tc := VDbCompareTr(sav, sbv);
      if tc < 0 then Result := -1
      else if tc > 0 then Result := 1
      else Result := 0;
    end
    else if VDbCmpVal(sav, sbv, '<', sct) then Result := -1
    else if VDbCmpVal(sav, sbv, '>', sct) then Result := 1
    else Result := 0;
    if Result <> 0 then
    begin
      if Cols[sk].Desc then Result := -Result;
      Exit;
    end;
  end;
end;

{ R-14 Full: gorev baglamina gore iki SATIRI karsilastirir. Esit
  anahtarlarda orijinal satir indeksiyle baginti kurar (tie-break):
  paralel cikti boylece KARARLI (stable) olur ve esit satirlar ekleme
  sirasinda kalir. Toplam siralama olur (merge icin zorunlu). }
{ H14: tek kolonlu FLOAT siralamasi icin anahtar plani olusturur.
  Anahtarlar SATIR-INDEKSLI (Rows dizisinin sirasiyla). Genel yolda her
  karsilastirmada VDbParseFloat cagriliyordu; 1M satirlik FLOAT siralamasi
  ~64 s suruyordu, simdi ~5 s.
  Dondus: False = plan kullanilamaz (bir deger sayisala donusmedi) ->
  genel yol AYNEN calisir (sonuc degismez). }
function VdbBuildFloatPlan(const Rows: TStrMatrix; Col: Integer;
  Desc: Boolean; out Plan: TSortFloatPlan): Boolean;
var
  i: Integer;
  v: Double;
begin
  Result := False;
  Plan.Keys := nil;
  Plan.Null := nil;
  Plan.Desc := Desc;
  Plan.Valid := False;
  if Col < 0 then Exit;
  SetLength(Plan.Keys, Length(Rows));
  SetLength(Plan.Null, Length(Rows));
  for i := 0 to High(Rows) do
  begin
    if (Col > High(Rows[i])) or (Rows[i][Col] = '') then
    begin
      Plan.Null[i] := 1;      // bos metin = NULL
      Plan.Keys[i] := 0;
      Continue;
    end;
    if not VDbParseFloat(Rows[i][Col], v) then
    begin
      // Sayisala donusmeyen deger: genel yola don (metin kiyasi).
      SetLength(Plan.Keys, 0);
      SetLength(Plan.Null, 0);
      Exit(False);
    end;
    Plan.Null[i] := 0;
    Plan.Keys[i] := v;
  end;
  Plan.Valid := True;
  Result := True;
end;

{ H14: iki satiri onceden cozulmus FLOAT anahtarlariyla karsilastirir.
  NULL kurali genel yolla ayni: NULL "en kucuk" sayilir, DESC ile terslenir.
  Esitlikte 0 doner (baginti kuran kisi ek karar verir). }
function VdbSortCmpFloatPlan(const Plan: TSortFloatPlan;
  ra, rb: Integer): Integer;
begin
  if (Plan.Null[ra] <> 0) or (Plan.Null[rb] <> 0) then
  begin
    if (Plan.Null[ra] <> 0) and (Plan.Null[rb] <> 0) then Exit(0);
    if Plan.Null[ra] <> 0 then Result := -1 else Result := 1;
    if Plan.Desc then Result := -Result;
    Exit;
  end;
  if Plan.Keys[ra] < Plan.Keys[rb] then Result := -1
  else if Plan.Keys[ra] > Plan.Keys[rb] then Result := 1
  else Result := 0;
  if (Result <> 0) and Plan.Desc then Result := -Result;
end;

function VdbSortCmpRow(const T: TVdbSortTask; ra, rb: Integer): Integer;
begin
  if T.UseInt then
  begin
    if T.IntDesc then
    begin
      if T.IntKeys[ra] > T.IntKeys[rb] then Result := -1
      else if T.IntKeys[ra] < T.IntKeys[rb] then Result := 1
      else Result := 0;
    end
    else
    begin
      if T.IntKeys[ra] < T.IntKeys[rb] then Result := -1
      else if T.IntKeys[ra] > T.IntKeys[rb] then Result := 1
      else Result := 0;
    end;
  end
  else if T.Plan.Valid then
    Result := VdbSortCmpFloatPlan(T.Plan, ra, rb)
  else
    Result := VdbSortCompareRows(T.Cols, T.Rows, ra, rb);
  if Result = 0 then Result := ra - rb;
end;

{ R-14 Full: T^.Idx[L..H] araligini iterative quicksort ile siralar.
  Pivot DEGER olarak kopyalanir (satir indeksi); idx[] permutasyon
  sirasinda degistigi icin pivotu indeks olarak tutmak hatadir (R-20
  dersi, seri yolla ayni duzen). }
procedure VdbQSortIdxRange(T: PVdbSortTask; L, H: Integer);
var
  StackL, StackH: array[0..VDB_SORT_STACK_MAX - 1] of Integer;
  SP, i, j, pRow, tIdx: Integer;
begin
  if L >= H then Exit;
  SP := 0;
  StackL[0] := L; StackH[0] := H; Inc(SP);
  while SP > 0 do
  begin
    Dec(SP);
    L := StackL[SP]; H := StackH[SP];
    while L < H do
    begin
      pRow := T^.Idx[(L + H) div 2];
      i := L; j := H;
      repeat
        while (i < H) and (VdbSortCmpRow(T^, T^.Idx[i], pRow) < 0) do Inc(i);
        while (j > L) and (VdbSortCmpRow(T^, T^.Idx[j], pRow) > 0) do Dec(j);
        if i <= j then
        begin
          tIdx := T^.Idx[i]; T^.Idx[i] := T^.Idx[j]; T^.Idx[j] := tIdx;
          Inc(i); Dec(j);
        end;
      until i > j;
      if (j - L) < (H - i) then
      begin
        if i < H then
        begin
          if SP > High(StackL) then
            raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
          StackL[SP] := i; StackH[SP] := H; Inc(SP);
        end;
        H := j;
      end
      else
      begin
        if L < j then
        begin
          if SP > High(StackL) then
            raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
          StackL[SP] := L; StackH[SP] := j; Inc(SP);
        end;
        L := i;
      end;
    end;
  end;
end;

{ R-14 Full: parca siralama gorevi (VdbParallelForChunked cagirir).
  [ALo..AHi] = T^.Idx uzerinde bu goreve ayrilmis aralik. }
procedure VdbSortChunkTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
begin
  VdbQSortIdxRange(PVdbSortTask(ACtx), ALo, AHi);
end;

{ R-14 Full: Src'nin sirali [a..m-1] ve [m..b-1] kosularini Dst[a..b-1]'e
  birlestirir. Esitlikte SOL taraf once alinir (kararlilik).
  DIKKAT: parametre adlari buyuk/kucuk harf duyarsizdir; AM (gorev) ile
  aMid (sinir) ayni ad olamaz. }
procedure VdbMergeTwo(AM: PVdbMergeTask; aLo, aMid, aHi: Integer);
var
  i, j, d: Integer;
begin
  i := aLo;
  j := aMid;
  d := aLo;
  while (i < aMid) and (j < aHi) do
  begin
    if VdbSortCmpRow(AM^.Sort^, AM^.Src[i], AM^.Src[j]) <= 0 then
    begin
      AM^.Dst[d] := AM^.Src[i]; Inc(i);
    end
    else
    begin
      AM^.Dst[d] := AM^.Src[j]; Inc(j);
    end;
    Inc(d);
  end;
  while i < aMid do begin AM^.Dst[d] := AM^.Src[i]; Inc(i); Inc(d); end;
  while j < aHi do begin AM^.Dst[d] := AM^.Src[j]; Inc(j); Inc(d); end;
end;

{ R-14 Full: bir birlestirme turu; gorev [ALo..AHi] numarali parca
  ciftlerini Src'den Dst'ye yazar. Ciftler ayrik araliklara dokundugu
  icin paralel gorevler cakismaz. }
procedure VdbMergePairsTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
var
  AM: PVdbMergeTask;
  pp, bndLo, bndMid, bndHi: Integer;
begin
  AM := PVdbMergeTask(ACtx);
  for pp := ALo to AHi do
  begin
    bndLo := AM^.Bounds[pp * 2 * AM^.Run];
    bndMid := AM^.Bounds[pp * 2 * AM^.Run + AM^.Run];
    bndHi := AM^.Bounds[pp * 2 * AM^.Run + 2 * AM^.Run];
    VdbMergeTwo(AM, bndLo, bndMid, bndHi);
  end;
end;

{ R-14 Full: Idx'i isci havuzuyla siralar.
    1) Idx 2'nin kuvveti kadar parcaya bolunur; her parcayi bir isci
       quicksort ile siralar (ayrik araliklar -> cakisma yok).
    2) Kademeli ikili birlestirme (ping-pong tampon): her turda bitisik
       parca ciftleri paralel birlestirilir, run ikiye katlanir.
    3) Sonuc hangi tampondaysa Idx ona baglanir (referans atamasi).
  Cagiran on kosullari saglar: N >= VDB_PAR_SORT_MIN_ROWS, havuz acik
  ve >= 2 isci. Satir deposu (Rows) ve kolon bilgileri salt-okunur. }
procedure VdbParallelSortIdx(var Idx: TIntArray; N: Integer;
  const Rows: TStrMatrix; const Cols: TVdbSortCols; UseInt, IntDesc: Boolean;
  const Plan: TSortFloatPlan);
var
  T: TVdbSortTask;
  MT: TVdbMergeTask;
  bounds: TIntArray;
  chunks, run, pairs, i, c: Integer;
  sz, extra, lo: Integer;
  vInt: Int64;
  tmp, src, dst, sw: TIntArray;
begin
  if N < 2 then Exit;

  T.Idx := Idx;
  T.Rows := Rows;
  T.Cols := Cols;
  T.UseInt := UseInt;
  T.IntDesc := IntDesc;
  T.Plan := Plan;
  if UseInt then
  begin
    // Hizli yol: tamsayi anahtarlar ana is parcaciginda BIR kez
    // cozulur; isçiler yalnizca diziden okur (parse yok).
    c := Cols[0].ColIdx;
    SetLength(T.IntKeys, N);
    for i := 0 to N - 1 do
    begin
      if (c <= High(Rows[i])) and VDbParseInt(Rows[i][c], vInt) then
        T.IntKeys[i] := vInt
      else
        T.IntKeys[i] := Low(Int64);   // NULL en kucuk (seri yol ile ayni)
    end;
  end
  else
    SetLength(T.IntKeys, 0);

  // Parca sayisi: 2'nin kuvveti (birlestirme turlari icin), isci
  // sayisinin ~2 kati, en fazla 64, satir sayisindan buyuk degil.
  chunks := 2;
  while (chunks < ParallelWorkerCount * 2) and (chunks < 64) and
        (chunks * 2 <= N) do
    chunks := chunks * 2;

  // Parca sinirlari VdbParallelForChunked'in dilimlemesiyle BIREBIR ayni
  // formulle uretilmelidir (sz/extra: ilk 'extra' parca 1 fazla alir).
  // i*N/chunks aritmetigi N, chunks'in kati degilse FARKLI sinirlar verir
  // (or. N=5000, chunks=16 -> 312.5): parca quicksort'un siraladigi
  // araliklar birlestirme turlarinin kosu sinirlariyla kayar ve cikti
  // cop olur. VdbParallelForChunked(0, N-1, ...) cagrisini degistirmeden
  // buradaki formulu aynilastirmak tek dogru yoldur.
  SetLength(bounds, chunks + 1);
  bounds[0] := 0;
  sz := N div chunks;
  extra := N mod chunks;
  lo := 0;
  for i := 0 to chunks - 1 do
  begin
    Inc(lo, sz + Ord(i < extra));
    bounds[i + 1] := lo;
  end;
  bounds[chunks] := N;

  // 1) paralel parca quicksort
  VdbParallelForChunked(0, N - 1, chunks, VdbSortChunkTask, @T);

  // 2) kademeli ikili birlestirme
  SetLength(tmp, N);
  src := Idx;
  dst := tmp;
  run := 1;
  while run < chunks do
  begin
    MT.Sort := @T;
    MT.Src := src;
    MT.Dst := dst;
    MT.Bounds := bounds;
    MT.Run := run;
    pairs := chunks div (2 * run);
    VdbParallelForChunked(0, pairs - 1, Min(pairs, ParallelWorkerCount * 4),
      VdbMergePairsTask, @MT);
    sw := src; src := dst; dst := sw;
    run := run * 2;
  end;
  Idx := src;
end;

{ ------------------------------------------------------------
  DoSort - Bellek-ici ORDER BY (Iterative QuickSort, O(N log N))
  //---------------------------------------------------------- }
procedure TVSqlExecutor.DoSort(var Rows: TStrMatrix; const Keys: TStrArray;
  OrderBy: TList<TOrderItem>;
  const ColNames: TStrArray; const ColTypes: TByteArray;
  const MaxRows: Integer);
var
  i, j, k, kidx, m, c, validCount: Integer;
  sortCols: TVdbSortCols;
  idx: TIntArray;
  newRows: TStrMatrix;
  // ORDER BY ifadeleri (or. VECTOR_DISTANCE): onceden hesaplanan anahtarlar.
  exprKeys: TStrMatrix;
  exprTypes: TByteArray;
  keyCols: TIntArray;
  hasExpr: Boolean;
  // F3-3/F3-2: quicksort yigini. Derinlik log2(N) oldugu icin 64 cerverek
  // fazladir; yine de tasma OLSA bile dizi disina yazmamak icin asagidaki
  // VDB_SORT_STACK_MAX sinirinda hata verilir (ulasilamaz, savunma).
  StackL, StackH: array[0..VDB_SORT_STACK_MAX - 1] of Integer;
  SP, L, H, pIdx, tIdx: Integer;
  intKeys: array of Int64;
  vInt, pivInt, tInt: Int64;
  desc: Boolean;
  // R-14 Full: yola karar (tamsayi hizli yolu / paralel dagitim).
  intPath, usePar: Boolean;
  // H14: tek kolonlu FLOAT siralamasi icin onceden cozulmus anahtarlar.
  fPlan: TSortFloatPlan;
  useFPlan: Boolean;

  function ExprCt(E: TSqlExprNode): Byte;
  var
    ci: Integer;
  begin
    Result := VCT_STR;
    if E = nil then Exit;
    if E is TSqlColumnRefNode then
    begin
      ci := FindColIdx(TSqlColumnRefNode(E).ColumnName, '', ColNames);
      if (ci >= 0) and (ci <= High(ColTypes)) then Exit(ColTypes[ci]);
      Exit;
    end;
    if E is TSqlLiteralNode then
    begin
      case TSqlLiteralNode(E).LitType of
        sltInt, sltFloat: Exit(VCT_FLOAT);
        sltBool: Exit(VCT_BOOL);
      end;
      Exit;
    end;
    if E is TSqlBinaryOpNode then
    begin
      case TSqlBinaryOpNode(E).Op of
        sboAdd, sboSub, sboMul, sboDiv, sboMod: Exit(VCT_FLOAT);
        sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte, sboAnd, sboOr, sboLike,
          sboILike: Exit(VCT_BOOL);
      end;
      Exit;
    end;
    if E is TSqlFuncCallNode then
    begin
      if SameText(TSqlFuncCallNode(E).FuncName, 'VECTOR_DISTANCE') or
         SameText(TSqlFuncCallNode(E).FuncName, 'VECTOR_NORM') or
         SameText(TSqlFuncCallNode(E).FuncName, 'LENGTH') or
         SameText(TSqlFuncCallNode(E).FuncName, 'ABS') or
         SameText(TSqlFuncCallNode(E).FuncName, 'ROUND') or
         SameText(TSqlFuncCallNode(E).FuncName, 'FLOOR') or
         SameText(TSqlFuncCallNode(E).FuncName, 'CEIL') or
         SameText(TSqlFuncCallNode(E).FuncName, 'CEILING') then
        Exit(VCT_FLOAT);
      Exit;
    end;
    if E is TSqlWindowNode then
      Exit(VCT_INT);
  end;

  function CmpExpr(ia, ib: Integer): Integer;
  var
    kk: Integer;
  begin
    for kk := 0 to OrderBy.Count - 1 do
    begin
      Result := VDbIdxCmp(exprKeys[ia][kk], exprKeys[ib][kk], exprTypes[kk]);
      if Result <> 0 then
      begin
        if OrderBy[kk].Desc then Result := -Result;
        Exit;
      end;
    end;
    Result := 0;
  end;

  function CmpSortIdx(a, b: Integer): Integer;
  begin
    if hasExpr then
      Result := CmpExpr(a, b)
    else if useFPlan then
      Result := VdbSortCmpFloatPlan(fPlan, a, b)
    else
      Result := VdbSortCompareRows(sortCols, Rows, a, b);
  end;

  { H14: seri yolda iki satiri karsilastirir. }
  function CmpRows2(a, b: Integer): Integer;
  begin
    if useFPlan then
      Result := VdbSortCmpFloatPlan(fPlan, a, b)
    else
      Result := VdbSortCompareRows(sortCols, Rows, a, b);
  end;

  { H12: ORDER BY ... LIMIT icin yalniz en iyi K satiri tut.
    QuickSort tum N satiri siralar; burada N satir taranir ama yalniz
    K elemanli max-heap tutulur (O(N log K)). K = LIMIT + OFFSET. }
  procedure TopK(const K: Integer);
  var
    heap: TIntArray;
    nHeap, i, child, parent, tmp: Integer;
    stackL, stackH: array[0..VDB_SORT_STACK_MAX - 1] of Integer;
    sp, l, h, p, j, t: Integer;
  begin
    if K <= 0 then
    begin
      SetLength(Rows, 0);
      Exit;
    end;
    SetLength(heap, K);
    nHeap := 0;
    for i := 0 to High(Rows) do
    begin
      if nHeap < K then
      begin
        heap[nHeap] := i;
        Inc(nHeap);
        child := nHeap - 1;
        while child > 0 do
        begin
          parent := (child - 1) div 2;
          if CmpSortIdx(heap[parent], heap[child]) >= 0 then Break;
          tmp := heap[parent]; heap[parent] := heap[child]; heap[child] := tmp;
          child := parent;
        end;
      end
      else if CmpSortIdx(i, heap[0]) < 0 then
      begin
        heap[0] := i;
        parent := 0;
        while True do
        begin
          child := parent * 2 + 1;
          if child >= nHeap then Break;
          if (child + 1 < nHeap) and
             (CmpSortIdx(heap[child + 1], heap[child]) > 0) then
            Inc(child);
          if CmpSortIdx(heap[parent], heap[child]) >= 0 then Break;
          tmp := heap[parent]; heap[parent] := heap[child]; heap[child] := tmp;
          parent := child;
        end;
      end;
    end;

    // Heap'te kalan K satiri kendi arasinda sirala (K kucuk).
    sp := 0;
    if nHeap > 1 then
    begin
      stackL[0] := 0; stackH[0] := nHeap - 1; sp := 1;
    end;
    while sp > 0 do
    begin
      Dec(sp);
      l := stackL[sp]; h := stackH[sp];
      while l < h do
      begin
        p := heap[(l + h) div 2];
        i := l; j := h;
        repeat
          while (i < h) and (CmpSortIdx(heap[i], p) < 0) do Inc(i);
          while (j > l) and (CmpSortIdx(heap[j], p) > 0) do Dec(j);
          if i <= j then
          begin
            t := heap[i]; heap[i] := heap[j]; heap[j] := t;
            Inc(i); Dec(j);
          end;
        until i > j;
        if (j - l) < (h - i) then
        begin
          if i < h then
          begin
            if sp > High(stackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            stackL[sp] := i; stackH[sp] := h; Inc(sp);
          end;
          h := j;
        end
        else
        begin
          if l < j then
          begin
            if sp > High(stackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            stackL[sp] := l; stackH[sp] := j; Inc(sp);
          end;
          l := i;
        end;
      end;
    end;

    SetLength(newRows, nHeap);
    for i := 0 to nHeap - 1 do newRows[i] := Rows[heap[i]];
    Rows := newRows;
  end;

begin
  if (OrderBy = nil) or (OrderBy.Count = 0) or (Length(Rows) < 2) then Exit;

  // ORDER BY ifadesi (kolon olmayan anahtar) varsa, anahtarlari satir basina
  // BIR KEZ hesapla. Eskiden yalnizca kolon anahtarlari destekleniyordu;
  // `ORDER BY VECTOR_DISTANCE(...)` sessizce yok sayiliyordu.
  hasExpr := False;
  for k := 0 to OrderBy.Count - 1 do
    if Keys[k] = '' then hasExpr := True;
  if hasExpr then
  begin
    SetLength(exprKeys, Length(Rows));
    SetLength(exprTypes, OrderBy.Count);
    SetLength(keyCols, OrderBy.Count);
    for k := 0 to OrderBy.Count - 1 do
    begin
      keyCols[k] := -1;
      if Keys[k] <> '' then
      begin
        keyCols[k] := FindColIdx(Keys[k], '', ColNames);
        if keyCols[k] >= 0 then
        begin
          if keyCols[k] <= High(ColTypes) then exprTypes[k] := ColTypes[keyCols[k]]
          else exprTypes[k] := VCT_STR;
        end
        else
          raise EVDbException.Create(ecColumnNotFound,
            'ORDER BY bilinmeyen kolon: ' + Keys[k]);
      end
      else
        exprTypes[k] := ExprCt(OrderBy[k].Expr);
      for i := 0 to High(Rows) do
      begin
        SetLength(exprKeys[i], OrderBy.Count);
        if keyCols[k] >= 0 then
        begin
          if keyCols[k] <= High(Rows[i]) then
            exprKeys[i][k] := Rows[i][keyCols[k]]
          else
            exprKeys[i][k] := '';
        end
        else
          exprKeys[i][k] := EvalExpr(OrderBy[k].Expr, Rows[i], ColNames, ColTypes);
      end;
    end;
    SetLength(idx, Length(Rows));
    for i := 0 to High(Rows) do idx[i] := i;
    // NOT: ifade anahtarlarinda (VECTOR_DISTANCE vb.) tam siralama korunur.
    // TopK burada K siralamayi degil, "en iyi K satiri" secimini yapar; esit
    // anahtarlarda secim sirasi degisebilir. HNSW (M4) aday kumesi ile
    // karsilastirilan testlerde kume farki olusur -> bu yol kullanilmaz.
    // Yinelemeli quicksort (kucuk yigin).
    SP := 0;
    StackL[0] := 0; StackH[0] := High(idx); Inc(SP);
    while SP > 0 do
    begin
      Dec(SP);
      L := StackL[SP]; H := StackH[SP];
      while L < H do
      begin
        pIdx := idx[(L + H) div 2];
        i := L; j := H;
        repeat
          while (i < H) and (CmpExpr(idx[i], pIdx) < 0) do Inc(i);
          while (j > L) and (CmpExpr(idx[j], pIdx) > 0) do Dec(j);
          if i <= j then
          begin
            tIdx := idx[i]; idx[i] := idx[j]; idx[j] := tIdx;
            Inc(i); Dec(j);
          end;
        until i > j;
        if (j - L) < (H - i) then
        begin
          if i < H then
          begin
            if SP > High(StackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            StackL[SP] := i; StackH[SP] := H; Inc(SP);
          end;
          H := j;
        end
        else
        begin
          if L < j then
          begin
            if SP > High(StackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            StackL[SP] := L; StackH[SP] := j; Inc(SP);
          end;
          L := i;
        end;
      end;
    end;
    SetLength(newRows, Length(Rows));
    for i := 0 to High(idx) do newRows[i] := Rows[idx[i]];
    Rows := newRows;
    Exit;
  end;

  // 1. Siralama kolonlarini onceden coz (her karsilastirmada Name arama!)
  SetLength(sortCols, OrderBy.Count);
  validCount := 0;
  for k := 0 to OrderBy.Count - 1 do
  begin
    kidx := -1;
    for m := 0 to High(ColNames) do
    begin
      if SameText(ColNames[m], Keys[k]) then
      begin kidx := m; Break; end;
      if (Pos('.', ColNames[m]) > 0) and
         SameText(Copy(ColNames[m], Pos('.', ColNames[m]) + 1, MaxInt), Keys[k]) then
      begin kidx := m; Break; end;
      if (Pos('.', Keys[k]) > 0) and
         SameText(Copy(Keys[k], Pos('.', Keys[k]) + 1, MaxInt), ColNames[m]) then
      begin kidx := m; Break; end;
    end;
    if kidx >= 0 then
    begin
      sortCols[validCount].ColIdx := kidx;
      if kidx < Length(ColTypes) then
        sortCols[validCount].CType := ColTypes[kidx]
      else
        sortCols[validCount].CType := VCT_STR;
      sortCols[validCount].Desc := OrderBy[k].Desc;
      // P5-TR: yalniz metin kolonlarda gecerli (sayisal siralama korunur).
      sortCols[validCount].Collate := OrderBy[k].Collate;
      // R-20: acik COLLATE yoksa kolonun varsayilan collation'i
      // devreye girer (`ad TEXT COLLATE tr`).
      if sortCols[validCount].Collate = '' then
        sortCols[validCount].Collate := CurColCollation(kidx);
      sortCols[validCount].UseTr :=
        (sortCols[validCount].Collate <> '') and
        (sortCols[validCount].CType = VCT_STR);
      // F-10: NULLS FIRST/LAST bayragi.
      sortCols[validCount].NullsPos := OrderBy[k].NullsPos;
      Inc(validCount);
    end
    // F1-21: bilinmeyen kolon sessizce yok sayilmaz, hata verir.
    else if Keys[k] <> '' then
      raise EVDbException.Create(ecColumnNotFound,
        'ORDER BY bilinmeyen kolon: ' + Keys[k]);
  end;
  SetLength(sortCols, validCount);
  if validCount = 0 then Exit;

  { H14: tek kolonlu FLOAT siralamasi icin anahtarlar ONCEDEN cozulur.
    Genel yolda her kiyasta VDbParseFloat cagriliyordu; 1M satirlik
    FLOAT siralamasi ~64 s suruyordu. Plan gecerli degilse genel yol
    AYNEN calisir (sonuc degismez). }
  useFPlan := False;
  fPlan.Valid := False;
  if (validCount = 1) and (sortCols[0].CType = VCT_FLOAT) and
     (sortCols[0].NullsPos < 0) and (sortCols[0].Collate = '') then
    useFPlan := VdbBuildFloatPlan(Rows, sortCols[0].ColIdx,
      sortCols[0].Desc, fPlan);

  // 2. Indeks dizisi olustur
  SetLength(idx, Length(Rows));
  for i := 0 to High(Rows) do idx[i] := i;

  // H12: LIMIT/OFFSET varsa tum kumeyi siralama yerine en iyi K satiri sec.
  if (MaxRows >= 0) and (MaxRows < Length(idx)) then
  begin
    TopK(MaxRows);
    Exit;
  end;

  // 3. R-14 Full: yola karar ver.
  //    - Tamsayi hizli yolu: tekil INT/BOOL kolon + acik NULLS konumu yok.
  //    - Paralel yol: satir sayisi esik uzerindeyse isci havuzuyla parca
  //      quicksort + kademeli birlestirme. Havuz kapaliysa ilk buyuk
  //      siralamada otomatik acilir; tek isci artik kaldirmayan sistemde
  //      seri yol korunur (eski davranis, kucuk tablolar hep seri).
  intPath := (validCount = 1) and
    ((sortCols[0].CType = VCT_INT) or (sortCols[0].CType = VCT_BOOL)) and
    (sortCols[0].NullsPos < 0);
  usePar := Length(Rows) >= VDB_PAR_SORT_MIN_ROWS;
  if usePar and (not ThreadPoolReady) then
    usePar := InitThreadPool(0);
  if usePar and (ParallelWorkerCount < 2) then
    usePar := False;

  if usePar then
    VdbParallelSortIdx(idx, Length(Rows), Rows, sortCols, intPath,
      intPath and sortCols[0].Desc, fPlan)
  else if intPath then
  begin
    // Tekil sayisal kolon icin ultra-hizli tamsayi QuickSort.
    // DIKKAT (F-10): NULLS FIRST/LAST acikca yazildiginda bu yol NULL'i
    // "Low(Int64) = en kucuk" sayar; konum yonunun tersidir. Bu yolun
    // varsayilan (-1) disinda NULLS konumu ihtimalinde ATLANIR.
    c := sortCols[0].ColIdx;
    desc := sortCols[0].Desc;
    SetLength(intKeys, Length(Rows));
    for i := 0 to High(Rows) do
    begin
      if (c <= High(Rows[i])) and VDbParseInt(Rows[i][c], vInt) then
        intKeys[i] := vInt
      else
        intKeys[i] := Low(Int64);
    end;

    SP := 0;
    StackL[0] := 0; StackH[0] := High(idx); Inc(SP);
    while SP > 0 do
    begin
      Dec(SP);
      L := StackL[SP]; H := StackH[SP];
      while L < H do
      begin
        pivInt := intKeys[(L + H) div 2];
        i := L; j := H;
        repeat
          if desc then
          begin
            while intKeys[i] > pivInt do Inc(i);
            while intKeys[j] < pivInt do Dec(j);
          end
          else
          begin
            while intKeys[i] < pivInt do Inc(i);
            while intKeys[j] > pivInt do Dec(j);
          end;
          if i <= j then
          begin
            tIdx := idx[i]; idx[i] := idx[j]; idx[j] := tIdx;
            tInt := intKeys[i]; intKeys[i] := intKeys[j]; intKeys[j] := tInt;
            Inc(i); Dec(j);
          end;
        until i > j;
        if (j - L) < (H - i) then
        begin
          if i < H then
          begin
            if SP > High(StackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            StackL[SP] := i; StackH[SP] := H; Inc(SP);
          end;
          H := j;
        end
        else
        begin
          if L < j then
          begin
            if SP > High(StackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            StackL[SP] := L; StackH[SP] := j; Inc(SP);
          end;
          L := i;
        end;
      end;
    end;
  end
  else
  begin
    // 4. Genel tip-bilgili Quicksort
    SP := 0;
    StackL[0] := 0; StackH[0] := High(idx); Inc(SP);
    while SP > 0 do
    begin
      Dec(SP);
      L := StackL[SP]; H := StackH[SP];
      while L < H do
      begin
        { DIKKAT (R-20): pivot DEGER olarak kopyalanir. idx[] permutasyon
          sirasinda DEGISTIGI icin, pivotu bir satir INDESI olarak
          tutmak hatadir: takas sonrasi pIdx baska bir satiri gosterir
          ve bölümleme bozulur ("ORDER BY ... COLLATE" ile belirgin
          sekilde yanlis sonuc veriyordu). }
        pIdx := idx[(L + H) div 2];
        i := L; j := H;
        repeat
          while (i < H) and (CmpRows2(idx[i], pIdx) < 0) do Inc(i);
          while (j > L) and (CmpRows2(idx[j], pIdx) > 0) do Dec(j);
          if i <= j then
          begin
            tIdx := idx[i]; idx[i] := idx[j]; idx[j] := tIdx;
            Inc(i); Dec(j);
          end;
        until i > j;
        if (j - L) < (H - i) then
        begin
          if i < H then
          begin
            if SP > High(StackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            StackL[SP] := i; StackH[SP] := H; Inc(SP);
          end;
          H := j;
        end
        else
        begin
          if L < j then
          begin
            if SP > High(StackL) then
              raise EVDbException.Create(ecLimit, 'siralama yigini asildi');
            StackL[SP] := L; StackH[SP] := j; Inc(SP);
          end;
          L := i;
        end;
      end;
    end;
  end;

  // 5. Siralanmis indekslere gore satirlari tek seferde O(N) kopyala
  SetLength(newRows, Length(Rows));
  for i := 0 to High(Rows) do
    newRows[i] := Rows[idx[i]];
  Rows := newRows;
end;

{ ------------------------------------------------------------
  ExecJoinScan
  //---------------------------------------------------------- }
// P5-CTE: materyal kumeden sahte tablo tanimi (Taraf cozumu icin).
// TableId=0, PkIndex=-1: indeks/PK yollari bu tanimla denenmez.
procedure PseudoDef(const TableName: string; const Names: TStrArray;
  const Types: TByteArray; out Td: TTableDef);
var
  k: Integer;
begin
  Td.TableId := 0;
  Td.Name := TableName;
  SetLength(Td.Cols, Length(Names));
  for k := 0 to High(Names) do
  begin
    Td.Cols[k].Name := Names[k];
    Td.Cols[k].Ctype := VCT_STR;
    if k < Length(Types) then
      Td.Cols[k].Ctype := Types[k];
    Td.Cols[k].NotNull := False;
    Td.Cols[k].Unique := False;
    Td.Cols[k].HasDef := False;
    Td.Cols[k].Def := '';
  end;
  Td.PkIndex := -1;
  Td.AutoInc := 0;
  SetLength(Td.Idx, 0);
  SetLength(Td.Fks, 0);
  SetLength(Td.Checks, 0);
end;

procedure TVSqlExecutor.ExecJoinScan(Stmt: TSqlSelectStmt;
  out MergedRows: TStrMatrix;
  out MergedColNames: TStrArray; out MergedColTypes: TByteArray);
{ P5-1: N-tablo JOIN (soldan derin). Ilk tablo taranir, her JOIN adimi
  birikmis sol kumeyle sag tabloyu birlestirir. 2-tablo davranisi
  (nitelikli/niteliksiz kolon cozumu, indeksli hizli yol, LEFT
  NULL-genisletme) her adimda aynen korunur. }
type
  TJoinTab = record
    Def: TTableDef;
    AliasEff: string;    // Alias <> '' ? Alias : Table
    ColStart: Integer;   // birlesik satirdaki ofset
    ColCount: Integer;
  end;
  TJoinTabs = array of TJoinTab;
var
  LRows: TStrMatrix;
  LNames: TStrArray;
  LTypes: TByteArray;
  LTabs: TJoinTabs;
  td0: TTableDef;
  cn0: TStrArray;
  ct0: TByteArray;
  pks0: TStrArray;
  // F-33: view satirlari view'in kendi SELECT'i calistirilarak gelir
  ViewSel: TSqlSelectStmt;
  ViewRes: TSqlResult;
  ViewTypes: TByteArray;
  i, t: Integer;

  // Tek birlestirme adimi: birikmis sol (LR/LN/LT/Tabs) + sag tablo (JC).
  procedure MergeStep(var LR: TStrMatrix; var LN: TStrArray;
    var LT: TByteArray; var Tabs: TJoinTabs; JC: TJoinClause;
    AUsing: TStrArray);   // F-28: nil = USING yok.
                          // DIKKAT: JC ve AUsing asla 'const' OLABILMEZ.
                          // TJoinClause record'u yonlendirilmis alanlar
                          // iceriyor (OnCondition) ve FPC
                          // 'const' yonlendirmede bunlari bos sayabiliyor
                          // -> AV.
  // UsingAt, JoinUsing listesinden belirtilen sira icin USING kolonlarini
  // dondurur (yoksa nil). Liste MoreJoins ile ayni sıradadır.
  var
    rDef: TTableDef;
    rAlias: string;
    rRows: TStrMatrix;
    rPks: TStrArray;
    rCn: TStrArray;
    rCt: TByteArray;
    n1, n2: Integer;
    i, j, k, q: Integer;
    merged: TStrArray;
    onOk, matchFound: Boolean;
    rIsCte: Boolean;
    lMatched: array of Boolean;
    JoinIdxCol1, JoinIdxCol2: Integer;   // sol/sag JOIN kolonlari
    JoinUsePk: Boolean;
    JoinSrc: TIdxSource;
    JoinRange: TIdxEntries;
    lo2, hi2: Integer;
    rv2: TStrArray;
    jv: string;
    eqn: TSqlBinaryOpNode;
    latR: TSqlResult;   // F-29: LATERAL alt sorgu sonucu
    latSel: TSqlSelectStmt;   // F-29: LATERAL alt sorgu dugumu
    mr: TStrMatrix;        // kademeli buyume (O(n^2) SetLength onlemi)
    mrN, mrCap: Integer;
    nt: TJoinTab;
    // F-27/F-28: NATURAL/USING ortak kolon hesabi
    np, li, ri: Integer;
    bare: string;
    // H2 (2026-10-18): indekssiz tek-esitlik join icin hash join.
    // HashL: sol kolonun birlesik satirdaki 0-tabanli indeksi;
    // HashRrel: sag kolonun rRows icindeki 0-tabanli indeksi.
    HashL, HashRrel, x: Integer;
    HashOK: Boolean;
    bk: TDictionary<string, TList<Integer>>;
    lst: TList<Integer>;
    kj: string;

    // LN ogesindeki nitelemeyi ('alias.kolon' -> 'kolon') atar.
    function AfterDot(const S: string): string;
    var
      d: Integer;
    begin
      d := Pos('.', S);
      if d > 0 then Result := Copy(S, d + 1, MaxInt) else Result := S;
    end;

    // Bir kolon referansinin hangi tarafta oldugunu bulur.
    // Doner: 1 = sol birlesim, 2 = sag tablo, 0 = belirsiz/yok.
    // Nitelikli ad birden cok tabloyla eslesirse 0 doner; hicbiriyle
    // eslesmezse sade ada dusulur (2-tablo motoruyla ayni kural).
    function Taraf(const C: TSqlColumnRefNode; out Pos: Integer): Integer;
    var
      hitTab, hitCount, w, lc: Integer;
      nm: string;
    begin
      Pos := -1;
      Result := 0;
      hitTab := -1; hitCount := 0;
      if C.TableQualifier <> '' then
      begin
        for w := 0 to High(Tabs) do
          if SameText(C.TableQualifier, Tabs[w].AliasEff) then
          begin Inc(hitCount); hitTab := w; end;
        if SameText(C.TableQualifier, rAlias) then
        begin Inc(hitCount); hitTab := -2; end;
        if hitCount > 1 then Exit; // belirsiz
        if hitCount = 1 then
        begin
          nm := VDbNorm(C.ColumnName);
          if hitTab = -2 then
          begin
            Result := 2;
            for w := 0 to High(rDef.Cols) do
              if VDbNorm(rDef.Cols[w].Name) = nm then
              begin Pos := n1 + w; Break; end;
          end
          else
          begin
            Result := 1;
            for w := 0 to High(Tabs[hitTab].Def.Cols) do
              if VDbNorm(Tabs[hitTab].Def.Cols[w].Name) = nm then
              begin Pos := Tabs[hitTab].ColStart + w; Break; end;
          end;
          Exit;
        end;
        // hitCount = 0: asagidaki sade-ad aramasina dus (eski davranis)
      end;
      nm := VDbNorm(C.ColumnName);
      for w := 0 to High(Tabs) do
        for lc := 0 to High(Tabs[w].Def.Cols) do
          if VDbNorm(Tabs[w].Def.Cols[lc].Name) = nm then
          begin Inc(hitCount); hitTab := w; Pos := Tabs[w].ColStart + lc; end;
      for w := 0 to High(rDef.Cols) do
        if VDbNorm(rDef.Cols[w].Name) = nm then
        begin Inc(hitCount); hitTab := -2; Pos := n1 + w; end;
      if hitCount = 1 then
      begin
        if hitTab = -2 then Result := 2 else Result := 1;
      end
      else Pos := -1;
    end;

    procedure MrPush(const Row: TStrArray);
    { H1 (2026-10-18): satiri KOPYALAYARAK saklar. Onceden `mr[mrN] := Row`
      diziyi PAYLASIYORDU; bu yuzden cagiran her (i,j) icin yeni bir
      `merged` ayirmak zorundaydi (eslesmeyen ciftlerde bosa tahsis).
      Kopya ile artik cagiran TEK bir `merged` tamponunu yeniden
      kullanabilir; eslesmeyen ciftlerde hic tahsis yapilmaz. Cikti ve
      sirasi BIREBIR aynidir. }
    var
      z: Integer;
    begin
      if mrN >= 2000000 then
        raise EVDbException.Create(ecLimit, 'JOIN sonucu cok buyuk (2M sinir)');
      if mrN >= mrCap then
      begin
        if mrCap = 0 then mrCap := 64
        else mrCap := mrCap * 2;
        SetLength(mr, mrCap);
      end;
      SetLength(mr[mrN], Length(Row));
      for z := 0 to High(Row) do
        mr[mrN][z] := Row[z];
      Inc(mrN);
    end;

    { ------------------------------------------------------------
      JoinOnOk — ortak ON kosulu.
      F-27/F-28: NATURAL JOIN ve USING (...) icin OnCondition YOKTUR;
      esitlik dogrudan kolon degerleri uzerinden kurulur.
      pairL/pairR: sol ve sag kume indeksleri (1 tabanli).
      Bu eslesme UC-Degerli mantiga uyar: bir tarafta NULL varsa
      eslesme YOKTUR (unknown), esleşmiş sayilmaz.
      //---------------------------------------------------------- }
    function JoinOnOk(const Row: TStrArray; CNames: TStrArray;
      CTypes: TByteArray): Boolean;
    var
      p: Integer;
      a, b: string;
      ct: Byte;
    begin
      if not FJoinUsing then
        Exit(EvalBool(JC.OnCondition, Row, CNames, CTypes));
      for p := 0 to High(FJoinPairL) do
      begin
        // FJoinPairL/R 1 TABANLI saklanir (JoinIdxCol ile ayni olcek
        // duzeni); Row ise 0 tabanlidir. Bir azalt.
        a := Row[FJoinPairL[p] - 1];
        b := Row[FJoinPairR[p] - 1];
        // NULL: hicbir operatorle eslesmez -> satır eşleşmez
        if (a = '') or (b = '') then Exit(False);   // NULL: eslesme sayilmaz
        if (FJoinPairL[p] - 1) < Length(CTypes) then
          ct := CTypes[FJoinPairL[p] - 1]
        else
          ct := VCT_STR;   // (indeks zaten 0 tabanli)
        if not VDbCmpVal(a, b, '=', ct) then Exit(False);
      end;
      Result := True;
    end;

  begin
    { ------------------------------------------------------------
      F-29: LATERAL — sol kume HER SATIR icin sag taraf yeniden
      hesaplanir. Alt sorgu (LateralIdx >= 0) varsa tablo okunmaz;
      aksi hâlde tablo/CTE normal yoldan okunur.
      Sag taraf her zaman INNER/LEFT JOIN olarak calisir: RIGHT ve
      FULL, LATERAL ile birlikte anlamli DEGILDIR (dis kume sabit
      degildir) ve reddedilir.
      //---------------------------------------------------------- }
    if JC.LateralIdx <> -1 then
    begin
      if (JC.JoinType = jtRight) or (JC.JoinType = jtFull) then
        raise EVDbException.Create(ecUnsupported,
          'LATERAL ile RIGHT/FULL JOIN birlestirilemez');
      n1 := Length(LN);
      latSel := nil;
      if JC.Alias <> '' then rAlias := JC.Alias
      else if (JC.LateralIdx >= 0) then rAlias := 'lateral'
      else rAlias := JC.Table;
      // Sag kolon adlari: alt sorgudan ya da tablodan
      if (JC.LateralIdx >= 0) and
         (JC.LateralIdx < Stmt.LateralSubs.Count) then
      begin
        latSel := Stmt.LateralSubs[JC.LateralIdx];
        // Sol kume BOSSA hicbir satir uretilmez; sag taraf hic
        // calistirilmaz (LR[0] erisimi de yapilmaz).
        if Length(LR) = 0 then
        begin
          nt.AliasEff := '';
          nt.ColStart := n1; nt.ColCount := 0;
          Exit;
        end;
        latR := SubResult(latSel, LR[0], LN);
        SetLength(rCn, Length(latR.Fields));
        SetLength(rCt, Length(latR.Fields));
        // DIKKAT: SubResult cikisindaki alan adlarini rCn'e KOPYALA.
        // Once sadece SetLength yapiliyordu; dizi bos string ile kaliyordu
        // ve "x.butce" yerine "x." uretiliyordu.
        for i := 0 to High(rCn) do
        begin
          rCn[i] := latR.Fields[i];
          rCt[i] := VCT_STR;
        end;
        CteColTypes(latSel, latR.Fields, rCt);
      end
      else
      begin
        rIsCte := TryCte(JC.Table, rCn, rCt, rRows);
        if rIsCte then PseudoDef(JC.Table, rCn, rCt, rDef)
        else
        begin
          rDef := FT.GetTable(JC.Table);
          BuildColInfo(rDef, rCn, rCt);
          FT.ScanRows(JC.Table, rPks, rRows);
        end;
      end;
      if JC.Alias <> '' then rAlias := JC.Alias
      else if (JC.LateralIdx >= 0) and (JC.LateralIdx < Stmt.LateralSubs.Count) then
        rAlias := 'lateral'
      else rAlias := JC.Table;
      n2 := Length(rCn);
      SetLength(LN, n1 + n2);
      SetLength(LT, n1 + n2);
      for i := 0 to n2 - 1 do
      begin
        // LATERAL alt sorgusunun alan adlari ExecSelect tarafindan
        // TSqlColumnRefNode.ColumnName ile uretilir -> NITELEMESIZ ("butce").
        // Burada yalniz LATERAL alias'i onekliyoruz: "x.butce".
        LN[n1 + i] := rAlias + '.' + rCn[i];
        LT[n1 + i] := rCt[i];
      end;
      // ON kosulu her satirda JoinOnOk ile degerlendirilecek; o cosumleyici
      // Tabs + rAlias kullanir. Bu yuzden LATERAL tablo kaydi (rDef) ve
      // rAlias, BIRLESIM DONGUSUNDEN ONCE kurulmalidir. Aksi halde
      // "x.butce > 80" gibi ON kosullarinda niteleme cozulemez.
      if latSel = nil then
        rDef := FT.GetTable(JC.Table)
      else
        PseudoDef(rAlias, rCn, rCt, rDef);
      // NATURAL/USING LATERAL ile birlikte kullanilamaz (SQL standardi)
      if JC.Natural then
        raise EVDbException.Create(ecSyntaxError,
          'NATURAL JOIN ile LATERAL birlestirilemez');
      if (AUsing <> nil) and (Length(AUsing) > 0) then
        raise EVDbException.Create(ecSyntaxError,
          'USING ile LATERAL birlestirilemez');
      FJoinUsing := False;
      mrN := 0;
      mrCap := 0;
      SetLength(mr, 0);
      for i := 0 to High(LR) do
      begin
        if latSel <> nil then
        begin
          latR := SubResult(latSel, LR[i], LN);
          SetLength(rRows, Length(latR.Rows));
          SetLength(rPks, 0);
          for k := 0 to High(latR.Rows) do rRows[k] := latR.Rows[k];
        end;
        matchFound := False;
        for j := 0 to High(rRows) do
        begin
          SetLength(merged, n1 + n2);
          for k := 0 to n1 - 1 do merged[k] := LR[i][k];
          for k := 0 to n2 - 1 do merged[n1 + k] := rRows[j][k];
          onOk := JoinOnOk(merged, LN, LT);
          if onOk then
          begin
            MrPush(merged);
            matchFound := True;
          end;
        end;
        if (not matchFound) and (JC.JoinType = jtLeft) then
        begin
          SetLength(merged, n1 + n2);
          for k := 0 to n1 - 1 do merged[k] := LR[i][k];
          for k := 0 to n2 - 1 do merged[n1 + k] := '';
          MrPush(merged);
        end;
      end;
      SetLength(mr, mrN);
      LR := mr;
      nt.Def := rDef; nt.AliasEff := rAlias;
      nt.ColStart := n1; nt.ColCount := n2;
      SetLength(Tabs, Length(Tabs) + 1);
      Tabs[High(Tabs)] := nt;
      Exit;
    end;

    // P5-CTE: sag taraf CTE ise materyal kume kullanilir; indeks/PK
    // hizli yolu atlanir (klasik ic ice dongu her zaman dogrudur).
    rIsCte := TryCte(JC.Table, rCn, rCt, rRows);
    if rIsCte then
      PseudoDef(JC.Table, rCn, rCt, rDef)
    else
    begin
      rDef := FT.GetTable(JC.Table);
      BuildColInfo(rDef, rCn, rCt);
      FT.ScanRows(JC.Table, rPks, rRows);
    end;
    if JC.Alias <> '' then rAlias := JC.Alias else rAlias := JC.Table;
    n1 := Length(LN); n2 := Length(rCn);

    { ------------------------------------------------------------
      F-27/F-28: NATURAL JOIN ve USING (...) hazirligi.
      Ortak kolon ciftleri hesaplanir; OnCondition yerine bunlar
      kullanilir. Sol kume adlari LN (nitelemis), LN'in her ogesinden
      niteleme atilip karsilastirilir.
      //---------------------------------------------------------- }
    FJoinUsing := False;
    FJoinUsingCols := AUsing;
    SetLength(FJoinPairL, 0);
    SetLength(FJoinPairR, 0);
    if JC.Natural or (AUsing <> nil) and (Length(AUsing) > 0) then
    begin
      FJoinUsing := True;
      if JC.Natural then
      begin
        // Ortak adlar: sol kume ve sag kume arasinda ayni ada sahip
        // kolonlar. Kume sirasi ONEMLI DEGILDIR (kesisim).
        np := 0;
        for i := 0 to n1 - 1 do
        begin
          bare := AfterDot(LN[i]);
          for q := 0 to n2 - 1 do
            if SameText(bare, rCn[q]) then
            begin
              Inc(np);
              break;
            end;
        end;
        if np = 0 then
          raise EVDbException.Create(ecSyntaxError,
            'NATURAL JOIN: taraflarin ortak kolonu yok');
        SetLength(FJoinPairL, np);
        SetLength(FJoinPairR, np);
        np := 0;
        for i := 0 to n1 - 1 do
        begin
          bare := AfterDot(LN[i]);
          for q := 0 to n2 - 1 do
            if SameText(bare, rCn[q]) then
            begin
              FJoinPairL[np] := i + 1;
              FJoinPairR[np] := n1 + q + 1;
              Inc(np);
              break;
            end;
        end;
      end
      else
      begin
        // USING (a, b): verilen kolonlar HER IKI tarafta da olmali.
        SetLength(FJoinPairL, Length(FJoinUsingCols));
        SetLength(FJoinPairR, Length(FJoinUsingCols));
        for i := 0 to High(FJoinUsingCols) do
        begin
          bare := FJoinUsingCols[i];
          // LN nitelemeli ('alias.kolon') oldugu icin niteleme atilip
          // aranir; FindColIdx nitelemesiz veriyi nitelemeli listede
          // bulamaz.
          li := -1;
          for q := 0 to n1 - 1 do
            if SameText(AfterDot(LN[q]), bare) then begin li := q; break; end;
          ri := FindColIdx(bare, '', rCn);
          if (li < 0) or (ri < 0) then
            raise EVDbException.CreateFmt(ecColumnNotFound,
              'USING kolonu iki tarafta da bulunamadi: %s', [bare]);
          FJoinPairL[i] := li + 1;
          FJoinPairR[i] := n1 + ri + 1;
        end;
      end;
    end;

    JoinIdxCol1 := -1; JoinIdxCol2 := -1; JoinUsePk := False;
    HashL := -1; HashRrel := -1;
    if (JC.OnCondition is TSqlBinaryOpNode) and
       (TSqlBinaryOpNode(JC.OnCondition).Op = sboEq) and
       (TSqlBinaryOpNode(JC.OnCondition).Left  is TSqlColumnRefNode) and
       (TSqlBinaryOpNode(JC.OnCondition).Right is TSqlColumnRefNode) then
    begin
      eqn := TSqlBinaryOpNode(JC.OnCondition);
      j := Taraf(TSqlColumnRefNode(eqn.Left), i);
      k := Taraf(TSqlColumnRefNode(eqn.Right), q);
      if (j = 1) and (k = 2) and (i >= 0) and (q >= 0) then
      begin
        JoinIdxCol1 := i; JoinIdxCol2 := q;
      end
      else if (j = 2) and (k = 1) and (i >= 0) and (q >= 0) then
      begin
        JoinIdxCol1 := q; JoinIdxCol2 := i;
      end;
      if (JoinIdxCol1 >= 0) and (JoinIdxCol2 >= 0) then
      begin
        HashL := JoinIdxCol1;
        HashRrel := JoinIdxCol2 - n1;
      end;
    end;
    if JoinIdxCol2 >= 0 then
    begin
      if rIsCte then
        JoinIdxCol2 := -1   // CTE'de indeks/PK yok -> klasik yol
      else if (JC.JoinType = jtRight) or (JC.JoinType = jtFull) then
        JoinIdxCol2 := -1   // P5-RF: sag surucu klasik dongu kullanir
      else if rDef.PkIndex = JoinIdxCol2 - n1 then
        JoinUsePk := True
      else if not FT.TryGetIdxSource(rDef.TableId, JoinIdxCol2 - n1, JoinSrc) then
        JoinIdxCol2 := -1;   // indeks yok -> klasik yol
    end;
    // H2 (2026-10-18): indeks hizli yolu UYGULANMIYORSA ve ON tek esitlikse
    // sag tarafi hash tablosuna koyup O(N+M) yap. Kurallar:
    //   - yalniz INNER/LEFT (RIGHT/FULL sag surucu semantigini bozmamak icin),
    //   - NULL anahtar eslesmez (SQL uc-degerli mantik),
    //   - iki kolon ayni ctype olmali (norm anahtari tutarli olsun),
    //   - USING/NATURAL (OnCondition yok) klasik yolda kalir.
    HashOK := (HashL >= 0) and (HashRrel >= 0) and (JoinIdxCol2 < 0) and
              ((JC.JoinType = jtInner) or (JC.JoinType = jtLeft)) and
              (not FJoinUsing) and
              (HashRrel <= High(rDef.Cols)) and (HashL <= High(LT)) and
              (rDef.Cols[HashRrel].Ctype = LT[HashL]);

    // Sag isimler (nitelikli, alias oncelikli)
    SetLength(LN, n1 + n2);
    SetLength(LT, n1 + n2);
    for i := 0 to n2 - 1 do
    begin
      LN[n1 + i] := rAlias + '.' + rCn[i];
      LT[n1 + i] := rCt[i];
    end;

    { ----------------------------------------------------------------
      HIZLI YOL: ON <sol kolon> = <sag kolon>
      Sag tarafin JOIN kolonunda indeks (veya PK) varsa sol satir basina
      yalniz O(log n + eslesme) kadar bakilir.
      //-------------------------------------------------------------- }

    mrN := 0; mrCap := 0; SetLength(mr, 0);

    if JoinIdxCol2 >= 0 then
    begin
      for i := 0 to High(LR) do
      begin
        jv := VDbNormValue(rDef.Cols[JoinIdxCol2 - n1].Ctype, LR[i][JoinIdxCol1]);
        matchFound := False;
        if JoinUsePk then
        begin
          if FT.ReadRow(JC.Table, jv, rv2) and
             (rv2[JoinIdxCol2 - n1] = LR[i][JoinIdxCol1]) then
          begin
            SetLength(merged, n1 + n2);
            for k := 0 to n1 - 1 do merged[k] := LR[i][k];
            for k := 0 to n2 - 1 do merged[n1 + k] := rv2[k];
            MrPush(merged);
            matchFound := True;
          end;
        end
        else if IdxSourceRange(JoinSrc, '=', jv, JoinRange) > 0 then
          for k := 0 to High(JoinRange) do
            if FT.ReadRow(JC.Table, JoinRange[k].Pk, rv2) then
            begin
              SetLength(merged, n1 + n2);
              for q := 0 to n1 - 1 do merged[q] := LR[i][q];
              for q := 0 to n2 - 1 do merged[n1 + q] := rv2[q];
              onOk := JoinOnOk(merged, LN, LT);
              if onOk then
              begin
                MrPush(merged);
                matchFound := True;
              end;
            end;
        if (not matchFound) and (JC.JoinType = jtLeft) then
        begin
          SetLength(merged, n1 + n2);
          for k := 0 to n1 - 1 do merged[k] := LR[i][k];
          for k := 0 to n2 - 1 do merged[n1 + k] := '';
          MrPush(merged);
        end;
      end;
      SetLength(mr, mrN);
      LR := mr;
    end
    else
    begin
      // klasik ic ice dongu (sag tarafta indeks/PK yok veya CTE)
      if not rIsCte then
        FT.ScanRows(JC.Table, rPks, rRows);
      mrN := 0;
      if HashOK then
      begin
        // H2 (2026-10-18): sag tarafi hash tablosuna koy, sol satir basina
        // O(1) bak. Sonuc ve SATIR SIRASI klasik ic ice donguyle BIREBIR
        // (kuyruk listeleri artan j ile kurulur; JoinOnOk nihai eleyicidir).
        bk := TDictionary<string, TList<Integer>>.Create;
        try
          for j := 0 to High(rRows) do
          begin
            if rRows[j][HashRrel] = '' then Continue;   // NULL eslesmez
            kj := VDbNormValue(rDef.Cols[HashRrel].Ctype, rRows[j][HashRrel]);
            if not bk.TryGetValue(kj, lst) then
            begin
              lst := TList<Integer>.Create;
              bk.Add(kj, lst);
            end;
            lst.Add(j);
          end;
          SetLength(merged, n1 + n2);
          for i := 0 to High(LR) do
          begin
            matchFound := False;
            if LR[i][HashL] <> '' then
            begin
              kj := VDbNormValue(LT[HashL], LR[i][HashL]);
              if bk.TryGetValue(kj, lst) then
                for x := 0 to lst.Count - 1 do
                begin
                  j := lst[x];
                  for k := 0 to n1 - 1 do merged[k] := LR[i][k];
                  for k := 0 to n2 - 1 do merged[n1 + k] := rRows[j][k];
                  if JoinOnOk(merged, LN, LT) then
                  begin
                    MrPush(merged);
                    matchFound := True;
                  end;
                end;
            end;
            if (not matchFound) and (JC.JoinType = jtLeft) then
            begin
              for k := 0 to n1 - 1 do merged[k] := LR[i][k];
              for k := 0 to n2 - 1 do merged[n1 + k] := '';
              MrPush(merged);
            end;
          end;
        finally
          if bk <> nil then
          begin
            for lst in bk.Values do lst.Free;
            bk.Free;
          end;
        end;
      end
      else if (JC.JoinType = jtRight) or (JC.JoinType = jtFull) then
      begin
        // P5-RF: sag surucu. Eslesmeyen sag satirlar NULL-solla korunur;
        // FULL'da ayrica eslesmeyen sol satirlar da korunur. Cikti sirasi
        // (sol kolonlar, sag kolonlar) degismez. Hizli yol yok (sol kume
        // materyaldir, indeksi yoktur) â€” O(n*m) klasik dongu.
        if JC.JoinType = jtFull then
        begin
          SetLength(lMatched, Length(LR));
          for i := 0 to High(lMatched) do
            lMatched[i] := False;
        end;
        SetLength(merged, n1 + n2);   // H1: tek tampon
        for j := 0 to High(rRows) do
        begin
          matchFound := False;
          for i := 0 to High(LR) do
          begin
            for k := 0 to n1 - 1 do merged[k] := LR[i][k];
            for k := 0 to n2 - 1 do merged[n1 + k] := rRows[j][k];
            onOk := JoinOnOk(merged, LN, LT);
            if onOk then
            begin
              MrPush(merged);
              matchFound := True;
              if JC.JoinType = jtFull then
                lMatched[i] := True;
            end;
          end;
          if not matchFound then
          begin
            for k := 0 to n1 - 1 do merged[k] := '';
            for k := 0 to n2 - 1 do merged[n1 + k] := rRows[j][k];
            MrPush(merged);
          end;
        end;
        if JC.JoinType = jtFull then
          for i := 0 to High(LR) do
            if not lMatched[i] then
            begin
              SetLength(merged, n1 + n2);
              for k := 0 to n1 - 1 do merged[k] := LR[i][k];
              for k := 0 to n2 - 1 do merged[n1 + k] := '';
              MrPush(merged);
            end;
      end
      else
      begin
        // H1: tek `merged` tamponu dongu boyunca yeniden kullanilir;
        // MrPush kopyaladigi icin guvenli ve eslesmeyen ciftte tahsis YOK.
        SetLength(merged, n1 + n2);
        for i := 0 to High(LR) do
        begin
          matchFound := False;
          for j := 0 to High(rRows) do
          begin
            for k := 0 to n1 - 1 do merged[k] := LR[i][k];
            for k := 0 to n2 - 1 do merged[n1 + k] := rRows[j][k];
            onOk := JoinOnOk(merged, LN, LT);
            if onOk then
            begin
              MrPush(merged);
              matchFound := True;
            end;
          end;
          if (not matchFound) and (JC.JoinType = jtLeft) then
          begin
            for k := 0 to n1 - 1 do merged[k] := LR[i][k];
            for k := 0 to n2 - 1 do merged[n1 + k] := '';
            MrPush(merged);
          end;
        end;
      end;
      SetLength(mr, mrN);
      LR := mr;
    end;

    // Sag tablo koken bilgisi (sonraki adimlarin Taraf cozumu icin)
    nt.Def := rDef; nt.AliasEff := rAlias; nt.ColStart := n1; nt.ColCount := n2;
    SetLength(Tabs, Length(Tabs) + 1);
    Tabs[High(Tabs)] := nt;
  end;

  // F-28: JoinUsing listesinden verilen sira icin USING kolonlarini getir.
  // Liste MoreJoins ile AYNI SIRADADIR ve bazi JOIN'lerde USING yoktur
  // (o sirada liste bos kalir -> nil doner).
  function UsingAt(AStmt: TSqlSelectStmt; Idx: Integer): TStrArray;
  begin
    Result := nil;
    if (AStmt.JoinUsing = nil) or (Idx < 0) or
       (Idx >= AStmt.JoinUsing.Count) then Exit;
    
    Result := AStmt.JoinUsing[Idx].UsingCols;
  end;

begin
  // Adim 0: sol taraf (FROM tablo veya CTE) yuklenir, isimler nitelenir

  if TryCte(Stmt.FromTable, cn0, ct0, LRows) then
    PseudoDef(Stmt.FromTable, cn0, ct0, td0)
  else
  begin

    td0 := FT.GetTable(Stmt.FromTable);
    BuildColInfo(td0, cn0, ct0);

    // F-33: VIEW destegi - view ise SELECT'ini calistir
    { NOT: TSqlResult icinde OutTypes/Pks alanlari YOK; sonuc
      yalniz Fields + Rows dondurur. Kolon tipleri view taniminda
      saklanan ColTypes'tan (yoksa metin) alinir, satirlarin PK'si
      yoktur (view satiri fiziksel kayit degildir). }
    if td0.IsView then
    begin
      { NOT: AST katalogda saklanmaz; view tanim METNINDEN yeniden
        uretilir ve is bitince serbest birakilir. }
      ViewSel := ParseSelectText(FT.ViewSelectText(Stmt.FromTable));
      if ViewSel = nil then
        raise EVDbException.Create(ecSyntaxError,
          'view tanimi ayristirilamadi veya bos: ' + Stmt.FromTable);
      try

        ExecSelect(ViewSel, ViewRes);


      finally
        ViewSel.Free;
      end;
      ViewTypes := ViewResultTypes(Stmt.FromTable, ViewRes.Fields);
      cn0 := ViewRes.Fields;
      SetLength(ct0, Length(cn0));
      for i := 0 to High(cn0) do
        if i <= High(ViewTypes) then ct0[i] := ViewTypes[i]
        else ct0[i] := VCT_STR;
      LRows := ViewRes.Rows;
      SetLength(pks0, 0);
    end
    else
      FT.ScanRows(Stmt.FromTable, pks0, LRows);
  end;
  SetLength(LNames, Length(cn0));
  SetLength(LTypes, Length(cn0));
  for i := 0 to High(cn0) do
  begin
    if Stmt.FromAlias <> '' then
      LNames[i] := Stmt.FromAlias + '.' + cn0[i]
    else
      LNames[i] := Stmt.FromTable + '.' + cn0[i];
    LTypes[i] := ct0[i];
  end;
  SetLength(LTabs, 1);
  LTabs[0].Def := td0;
  if Stmt.FromAlias <> '' then
    LTabs[0].AliasEff := Stmt.FromAlias
  else
    LTabs[0].AliasEff := Stmt.FromTable;
  LTabs[0].ColStart := 0;
  LTabs[0].ColCount := Length(cn0);
  // Adim 1..n: her JOIN soldan derine uygulanir.
  // F-28: JoinUsing listesi MoreJoins ile ayni sira; ilk JOIN icin
  // indis 0, MoreJoins[i] icin i+1. Eksikse nil (USING yok).
  MergeStep(LRows, LNames, LTypes, LTabs, Stmt.Join,
    UsingAt(Stmt, 0));
  for t := 0 to Stmt.MoreJoins.Count - 1 do
    MergeStep(LRows, LNames, LTypes, LTabs, Stmt.MoreJoins[t],
      UsingAt(Stmt, t + 1));
  MergedRows := LRows;
  MergedColNames := LNames;
  MergedColTypes := LTypes;
end;

{ ------------------------------------------------------------
  ComputeWindows (P5-WIN)
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ComputeWindows(Stmt: TSqlSelectStmt;
  const Rows: TStrMatrix; const ColNames: TStrArray;
  const ColTypes: TByteArray; out WinVals: TStrMatrix;
  out WinSlot: TIntArray);
var
  WList: TList<TSqlWindowNode>;
  j, r, s, q, k, kk, kkEnd: Integer;
  WN: TSqlWindowNode;
  PDict: TDictionary<string, TList<Integer>>;
  PKeys: TList<string>;
  idxList: TList<Integer>;
  key: AnsiString;
  ord: array of Integer;
  tmpM: TStrMatrix;
  keyNames: TStrArray;
  keyTypes: TByteArray;
  ci2: Integer;
  tmpRow: TStrArray;
  orderKeys: TStrArray;
  v, wv, dv, frameVal: string;
  ct: Byte;
  cnt: Int64;
  sum: Double;
  navg: Integer;
  mn, mx: string;
  fv: Double;
  rk,uv: Integer;
  colRef: TSqlColumnRefNode;

  function PartKey(RowIdx: Integer): AnsiString;
  var
    t, L: Integer;
    e: string;
  begin
    // Carpismasiz birlesim: uzunluk-onekli parcalar.
    Result := '';
    for t := 0 to WN.Partitions.Count - 1 do
    begin
      e := EvalExpr(WN.Partitions[t], Rows[RowIdx], ColNames, ColTypes);
      L := Length(e);
      Result := Result + AnsiString(Chr(L and $FF) + Chr((L shr 8) and $FF) +
        Chr((L shr 16) and $FF) + Chr((L shr 24) and $FF)) + AnsiString(e);
    end;
  end;

  function KeyCtype(E: TSqlExprNode): Byte;
  var
    t: Integer;
  begin
    Result := VCT_STR;
    if E is TSqlColumnRefNode then
      for t := 0 to High(ColNames) do
        if SameText(TSqlColumnRefNode(E).ColumnName, ColNames[t]) and
           (t < Length(ColTypes)) then
        begin Result := ColTypes[t]; Break; end;
  end;

  // Baglarin esitligi (RANK bag paylasimi icin, tip-bilgili).
  function KeysEqual(Ra, Rb: Integer): Boolean;
  var
    t: Integer;
    va, vb: string;
  begin
    Result := True;
    for t := 0 to WN.OrderBys.Count - 1 do
    begin
      va := EvalExpr(WN.OrderBys[t].Expr, Rows[Ra], ColNames, ColTypes);
      vb := EvalExpr(WN.OrderBys[t].Expr, Rows[Rb], ColNames, ColTypes);
      if (va = '') or (vb = '') then
      begin
        if va <> vb then Exit(False);
        Continue; // iki NULL = bag
      end;
      if not VDbCmpVal(va, vb, '=', KeyCtype(WN.OrderBys[t].Expr)) then
        Exit(False);
    end;
  end;

  function AggCtype: Byte;
  begin
    Result := VCT_STR;
    if (WN.Arg <> nil) and (WN.Arg is TSqlColumnRefNode) then
      Result := KeyCtype(WN.Arg);
  end;

begin
  SetLength(WinSlot, Stmt.Columns.Count);
  WList := TList<TSqlWindowNode>.Create;
  try
    for j := 0 to Stmt.Columns.Count - 1 do
      if Stmt.Columns[j].Expr is TSqlWindowNode then
      begin
        WinSlot[j] := WList.Count;
        WList.Add(TSqlWindowNode(Stmt.Columns[j].Expr));
      end
      else
        WinSlot[j] := -1;
    SetLength(WinVals, Length(Rows));
    for r := 0 to High(WinVals) do
      SetLength(WinVals[r], WList.Count);
    for s := 0 to WList.Count - 1 do
    begin
      WN := WList[s];
      // 1. Partition'lara ayir (giris sirasi korunur).
      PDict := TDictionary<string, TList<Integer>>.Create;
      PKeys := TList<string>.Create;
      try
        for r := 0 to High(Rows) do
        begin
          key := PartKey(r);
          if not PDict.TryGetValue(key, idxList) then
          begin
            idxList := TList<Integer>.Create;
            PDict.Add(key, idxList);
            PKeys.Add(key);
          end;
          idxList.Add(r);
        end;
        // 2. Her partition'da sirala + degerleri yaz.
        for q := 0 to PKeys.Count - 1 do
        begin
          idxList := PDict[PKeys[q]];
          SetLength(ord, idxList.Count);
          for k := 0 to idxList.Count - 1 do
            ord[k] := idxList[k];
          if WN.OrderBys.Count > 0 then
          begin
            // F2-19: ONCEDEN gecici matris (tmpM) satirin TUM
            // kolonlarini kopyaliyordu (Cols+1 dizi/satir) -> pencere
            // isleminde bellek 2-3 katina cikiyordu. Artik yalnizca
            // SIRALAMA ANAHTARI kolonlari + satir indeksi kopyalanir.
            // (Tablo 100 kolonluysa fark 100 katindir.)
            SetLength(keyNames, WN.OrderBys.Count + 1);
            SetLength(keyTypes, WN.OrderBys.Count + 1);
            SetLength(orderKeys, WN.OrderBys.Count);
            for k := 0 to WN.OrderBys.Count - 1 do
            begin
              if WN.OrderBys[k].Expr is TSqlColumnRefNode then
              begin
                // deger zaten satirdaki kolonun kendisi
                orderKeys[k] := TSqlColumnRefNode(WN.OrderBys[k].Expr).QualifiedName;
                keyNames[k] := orderKeys[k];
                keyTypes[k] := VCT_STR;
                ci2 := FindColIdx(TSqlColumnRefNode(WN.OrderBys[k].Expr).ColumnName,
                  TSqlColumnRefNode(WN.OrderBys[k].Expr).TableQualifier, ColNames);
                if (ci2 >= 0) and (ci2 < Length(ColTypes)) then keyTypes[k] := ColTypes[ci2];
              end
              else
              begin
                // ifade siralama: degeri hesapla, sentetik ad ver
                orderKeys[k] := '#w' + IntToStr(k);
                keyNames[k] := orderKeys[k];
                keyTypes[k] := VCT_STR;
              end;
            end;
            // son sutun: orijinal satir indeksi (siralama SONUCUNU okumak icin)
            keyNames[WN.OrderBys.Count] := '#wrow';
            keyTypes[WN.OrderBys.Count] := VCT_INT;
            SetLength(tmpM, idxList.Count);
            for k := 0 to idxList.Count - 1 do
            begin
              SetLength(tmpM[k], WN.OrderBys.Count + 1);
              for j := 0 to WN.OrderBys.Count - 1 do
                if WN.OrderBys[j].Expr is TSqlColumnRefNode then
                begin
                  ci2 := FindColIdx(TSqlColumnRefNode(WN.OrderBys[j].Expr).ColumnName,
                    TSqlColumnRefNode(WN.OrderBys[j].Expr).TableQualifier, ColNames);
                  if (ci2 >= 0) and (ci2 < Length(Rows[idxList[k]])) then
                    tmpM[k][j] := Rows[idxList[k]][ci2]
                  else tmpM[k][j] := '';
                end
                else
                  tmpM[k][j] := EvalExpr(WN.OrderBys[j].Expr,
                    Rows[idxList[k]], ColNames, ColTypes);
              tmpM[k][WN.OrderBys.Count] := IntToStr(idxList[k]);
            end;
            DoSort(tmpM, orderKeys, WN.OrderBys, keyNames, keyTypes);
            for k := 0 to High(tmpM) do
              ord[k] := StrToIntDef(tmpM[k][WN.OrderBys.Count], -1);
            SetLength(tmpM, 0);   // F2-19: kopyayi hemen birak
          end;
          // 3. Fonksiyona gore yaz.
          if (WN.FuncName = 'ROW_NUMBER') then
          begin
            for k := 0 to High(ord) do
              WinVals[ord[k]][s] := IntToStr(k + 1);
          end
          else if (WN.FuncName = 'RANK') or (WN.FuncName = 'DENSE_RANK') then
          begin
            rk := 1; uv := 1;
            for k := 0 to High(ord) do
            begin
              if (k > 0) and not KeysEqual(ord[k], ord[k - 1]) then
              begin
                if WN.FuncName = 'RANK' then rk := k + 1
                else Inc(uv);
              end;
              if WN.FuncName = 'RANK' then
                WinVals[ord[k]][s] := IntToStr(rk)
              else
                WinVals[ord[k]][s] := IntToStr(uv);
            end;
          end
          else if (WN.FuncName = 'LAG') or (WN.FuncName = 'LEAD') then
          begin
            for k := 0 to High(ord) do
            begin
              if WN.FuncName = 'LAG' then uv := k - WN.Offset
              else uv := k + WN.Offset;
              if (uv >= 0) and (uv <= High(ord)) then
                WinVals[ord[k]][s] := EvalExpr(WN.Arg, Rows[ord[uv]], ColNames, ColTypes)
              else if WN.Default <> nil then
                WinVals[ord[k]][s] := EvalExpr(WN.Default, Rows[ord[k]], ColNames, ColTypes)
              else
                WinVals[ord[k]][s] := '';
            end;
          end
          else
          begin
            // 4.6: cerceve (frame) varsa UNBOUNDED PRECEDING -> CURRENT ROW
            // birikimi uygulanir (kk = 0..k). Cerceve YOKSA (FrameType = '')
            // tum bolum (partition) kullanilir â€” SQL varsayilani ve 4.6
            // oncesi davranis bu yoldadir.
            ct := AggCtype;
            for k := 0 to High(ord) do
            begin
              cnt := 0; sum := 0; navg := 0; mn := ''; mx := '';
              if WN.FrameType = '' then
                kkEnd := High(ord)
              else
                kkEnd := k;
              for kk := 0 to kkEnd do
              begin
                if WN.IsStar then
                begin
                  Inc(cnt);
                  Continue;
                end;
                v := EvalExpr(WN.Arg, Rows[ord[kk]], ColNames, ColTypes);
                if v = '' then Continue;
                Inc(cnt);
                if VDbParseFloat(v, fv) then
                begin
                  sum := sum + fv;
                  Inc(navg);
                end;
                if (mn = '') or VDbCmpVal(v, mn, '<', ct) then mn := v;
                if (mx = '') or VDbCmpVal(v, mx, '>', ct) then mx := v;
              end;
              if WN.FuncName = 'COUNT' then wv := IntToStr(cnt)
              else if WN.FuncName = 'SUM' then wv := VDbFloatToStr(sum)
              else if WN.FuncName = 'AVG' then
              begin
                if navg > 0 then wv := VDbFloatToStr(sum / navg) else wv := '';
              end
              else if WN.FuncName = 'MIN' then wv := mn
              else if WN.FuncName = 'MAX' then wv := mx
              else wv := '';
              if WN.FrameType = '' then
              begin
                // cercevesiz: tum partition ayni degeri alir
                if k = 0 then frameVal := wv;
                WinVals[ord[k]][s] := frameVal;
              end
              else
                WinVals[ord[k]][s] := wv;
            end;
          end;
        end;
      finally
        for q := 0 to PKeys.Count - 1 do
          PDict[PKeys[q]].Free;
        PDict.Free;
        PKeys.Free;
      end;
    end;
  finally
    WList.Free;
  end;
end;

{ ------------------------------------------------------------
  ExecGroupBy
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecGroupBy(Stmt: TSqlSelectStmt;
  const AllPks: TStrArray; const AllRows: TStrMatrix;
  const ColNames: TStrArray; const ColTypes: TByteArray;
  out Res: TSqlResult; out OutTypes: TByteArray; AlreadyFiltered: Boolean);
var
  GroupKeys: TList<TStrArray>;
  GroupRowSets: TIntListList;
  i, j, gi: Integer;
  key: TStrArray;
  rowIdx: TIntList;
  outCols: TStrArray;
  outRows: TStrMatrix;
  fn: TSqlFuncCallNode;
  ci: Integer;
  n: Integer;            // KR-2: outRows satir sayaci
  tmpRow: TStrArray;
  havingOk: Boolean;
  gb: string;             // 4.2: GROUP BY cozumleme (EvalExpr ile ayni kural)
  dp: Integer;
  // 4.3: HAVING aggregate baglami â€” kayit/restor (ic ice HAVING'li alt
  // sorgu kendi baglamini kurup disarinkini geri birakir).
  savedIdx: TList<Integer>;
  savedSrc: TStrMatrix;
  savedCN: TStrArray;
  savedCT: TByteArray;
begin
  GroupKeys := TList<TStrArray>.Create;
  GroupRowSets := TIntListList.Create;
  try
    // 1. Grupla
    for i := 0 to High(AllRows) do
    begin
      // Indeks dilimi WHERE'in tamamini temsil ediyorsa satirlar zaten
      // filtrelenmistir; ayni AST'yi ikinci kez degerlendirmeyiz.
      if (not AlreadyFiltered) and
         (not RowMatches(Stmt.WhereClause, AllRows[i], ColNames, ColTypes)) then
        Continue;
      SetLength(key, Stmt.GroupByCols.Count);
      for j := 0 to Stmt.GroupByCols.Count - 1 do
      begin
        // 4.2: cozumleme EvalExpr ile AYNI kural (FindColIdx):
        // nitelikli ('b.id') ve sade ('id') yazim. Onceki birebir metin
        // aramasinda JOIN'de sade yazim hic eslesmiyor ve TUM satirlar
        // tek gruba dusuyordu (SESSIZ YANLIS); tek tabloda ise
        // 'x.ad' yazimi eslesmiyordu. Eslesmezse hata verilir.
        gb := Stmt.GroupByCols[j];
        dp := Pos('.', gb);
        if dp > 0 then
          ci := FindColIdx(Copy(gb, dp + 1, MaxInt), Copy(gb, 1, dp - 1), ColNames)
        else
          ci := FindColIdx(gb, '', ColNames);
        if ci < 0 then
          raise EVDbException.Create(ecColumnNotFound,
            'GROUP BY kolonu bulunamadi: ' + gb);
        if ci < Length(AllRows[i]) then key[j] := AllRows[i][ci]
        else key[j] := '';
      end;
      gi := -1;
      for j := 0 to GroupKeys.Count - 1 do
        if SameStrArr(GroupKeys[j], key) then begin gi := j; Break; end;
      if gi < 0 then
      begin
        GroupKeys.Add(key);
        GroupRowSets.Add(TIntList.Create);
        gi := GroupKeys.Count - 1;
      end;
      GroupRowSets[gi].Add(i);
    end;
    // Bos tablo + GROUP BY'siz aggregate: tek bos grup olustur (COUNT(*)=0)
    if (GroupKeys.Count = 0) and (Stmt.GroupByCols.Count = 0) then
    begin
      SetLength(key, 0);
      GroupKeys.Add(key);
      GroupRowSets.Add(TIntList.Create);
    end;

    // 2. Cikti kolonlari + tipleri
    SetLength(outCols, Stmt.Columns.Count);
    SetLength(OutTypes, Stmt.Columns.Count);
    for j := 0 to Stmt.Columns.Count - 1 do
    begin
      // Kolon adi
      if Stmt.Columns[j].Alias <> '' then outCols[j] := Stmt.Columns[j].Alias
      else if Stmt.Columns[j].Expr is TSqlFuncCallNode then
        outCols[j] := TSqlFuncCallNode(Stmt.Columns[j].Expr).FuncName
      else if Stmt.Columns[j].Expr is TSqlColumnRefNode then
        outCols[j] := TSqlColumnRefNode(Stmt.Columns[j].Expr).ColumnName
      else outCols[j] := 'col' + IntToStr(j + 1);

      // P5-WIN: cikti tipi belirleme
      OutTypes[j] := VCT_STR;
      if Stmt.Columns[j].Expr is TSqlColumnRefNode then
      begin
        for ci := 0 to High(ColNames) do
          if SameText(ColNames[ci], TSqlColumnRefNode(Stmt.Columns[j].Expr).ColumnName) then
          begin
            if ci < Length(ColTypes) then OutTypes[j] := ColTypes[ci];
            Break;
          end;
      end
      else if Stmt.Columns[j].Expr is TSqlAggNode then
        OutTypes[j] := VCT_STR   // F-14/F-15: STRING_AGG metin, PERCENTILE sayisal
      else if Stmt.Columns[j].Expr is TSqlFuncCallNode then
      begin
        fn := TSqlFuncCallNode(Stmt.Columns[j].Expr);
        if (fn.FuncName = 'COUNT') then
          OutTypes[j] := VCT_INT
        else if (fn.FuncName = 'SUM') or (fn.FuncName = 'AVG') then
          OutTypes[j] := VCT_FLOAT
        else if ((fn.FuncName = 'MIN') or (fn.FuncName = 'MAX')) and (fn.Arg is TSqlColumnRefNode) then
        begin
          for ci := 0 to High(ColNames) do
            if SameText(ColNames[ci], TSqlColumnRefNode(fn.Arg).ColumnName) then
            begin
              if ci < Length(ColTypes) then OutTypes[j] := ColTypes[ci];
              Break;
            end;
        end;
      end;
    end;

    // KR-2: on-tahsis (her grup 1 cikti satiri uretir).
    SetLength(outRows, GroupKeys.Count);
    n := 0;
    for gi := 0 to GroupKeys.Count - 1 do
    begin
      rowIdx := GroupRowSets[gi];
      SetLength(tmpRow, Stmt.Columns.Count);
      // F-14/F-15: ic ice ifadelerde (ORN. LENGTH(STRING_AGG(...))) aggregate
      // alt dugumu FAggIdx baglami olmadan satir-basi yola duserdi. Burada
      // grup baglami kurulur; HAVING ve projeksiyon bitince geri alinir.
      savedIdx := FAggIdx;   savedSrc := FAggSrcRows;
      savedCN  := FAggCNames; savedCT := FAggCTypes;
      FAggIdx := rowIdx;
      FAggSrcRows := AllRows;
      FAggCNames := ColNames;
      FAggCTypes := ColTypes;
      try
      for j := 0 to Stmt.Columns.Count - 1 do
      begin
        if (Stmt.Columns[j].Expr is TSqlFuncCallNode) and
           IsAggFuncName(TSqlFuncCallNode(Stmt.Columns[j].Expr).FuncName) then
          // 4.3: aggregate â€” tek uygulama, HAVING de ayni yardimciyi cagirir.
          tmpRow[j] := EvalAggregateValue(
            TSqlFuncCallNode(Stmt.Columns[j].Expr), AllRows, rowIdx,
            ColNames, ColTypes)
        else
        begin
          // F-14/F-15: tepe dugum TSqlAggNode ise dogrudan hesaplanir;
          // degilse (ORN. LENGTH(STRING_AGG(...))) EvalExpr ic ice degerlendirir
          // (FAggIdx baglami kurulu oldugu icin).
          if Stmt.Columns[j].Expr is TSqlAggNode then
            tmpRow[j] := EvalAggNode(TSqlAggNode(Stmt.Columns[j].Expr),
              AllRows, rowIdx, ColNames, ColTypes)
          else if rowIdx.Count > 0 then
            tmpRow[j] := EvalExpr(Stmt.Columns[j].Expr, AllRows[rowIdx[0]], ColNames, ColTypes)
          else
            tmpRow[j] := '';
        end;
      end;
      finally
        // F-14/F-15: projeksiyon baglami geri alinir (HAVING kendi
        // baglamini kurar, bu yuzden onu da kapatmamiz gerekir).
        FAggIdx := savedIdx;   FAggSrcRows := savedSrc;
        FAggCNames := savedCN; FAggCTypes := savedCT;
      end;
      // 4.3: HAVING â€” aggregate'ler grup satirlari uzerinden degerlenir
      // (alias ZORUNLU DEGIL). Baglam yalnizca bu degerlendirme sirasinda
      // aciktir; hata durumunda bile eski degerine doner.
      if Stmt.HavingClause <> nil then
      begin
        savedIdx := FAggIdx;   savedSrc := FAggSrcRows;
        savedCN  := FAggCNames; savedCT := FAggCTypes;
        FAggIdx := rowIdx;
        FAggSrcRows := AllRows;
        FAggCNames := ColNames;
        FAggCTypes := ColTypes;
        try
          havingOk := EvalBool(Stmt.HavingClause, tmpRow, outCols, OutTypes);
        finally
          FAggIdx := savedIdx;   FAggSrcRows := savedSrc;
          FAggCNames := savedCN; FAggCTypes := savedCT;
        end;
      end
      else
        havingOk := True;
      if havingOk then
      begin
        outRows[n] := tmpRow;
        Inc(n);
      end;
    end;

  SetLength(outRows, n);  // KR-2: on-tahsis sonrasi budama
  Res.Fields := outCols;
    Res.Rows := outRows;
    Res.Affected := Length(outRows);
    Res.Msg := 'OK';
  finally
    for i := 0 to GroupRowSets.Count - 1 do GroupRowSets[i].Free;
    GroupRowSets.Free;
    GroupKeys.Free;
  end;
end;

{ ------------------------------------------------------------
  P-12 (2026-10-16) - TryStreamAgg (bkz. sinif bildirimi)
  P-18a (2026-10-16): ham akis artik ScanRawIter GERI CAGRISIYLA akar;
  satir basina TBytes malzellestirmesi kaldirildi (COUNT/SUM boslugu).
  TAggPlan birim duzeyine cikarildi — VdbAggRawCb unit duzeyinde bir
  prosedurdur ve TVDbRawCb imzasina uyar; dolasim durumu TAggIterCtx
  uzerinden (stack, cagri boyunca gecerli) gecer.
  //---------------------------------------------------------- }
type
  TAggPlan = record
    Fn: TSqlFuncCallNode;
    Col: Integer;            // -1 = COUNT(*)
    Cnt, AvgCnt: Int64;
    SumF: Double;
    MinI, MaxI: Int64;       // VCT_INT icin
    MinF, MaxF: Double;      // VCT_FLOAT icin
    HasMin, HasMax: Boolean;
  end;

  TAggIterCtx = record
    Plans: array of TAggPlan;   // cagiranin plans dizisiyle ayni gonderme
    Ct, FType: TByteArray;
    FOff, FLen: TIntArray;
    ColCnt: Integer;
    TableId: Word;
    TableName: string;
    PrefixSeed: QWord;   // KR-8: VDbHashKeyPrefix(td.Name) -- sorgu basi bir kez
    MaxCol: Integer;     // KR-8c: planlarin referans verdigi en buyuk kolon (-1 = hic)
  end;

function VdbAggRawCb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
// P-18a: TryStreamAgg'in satir-dongusu govdesi BIREBIR (P-12 semantigi);
// tek fark veri kaynagi (Buf, Len) — kopyalanmis TBytes degil, motorun
// chunk tamponu. False => taramayi kes (genel yola dus; hata orada).
var
  ctx: ^TAggIterCtx;
  tid: Word;
  kh: QWord;               // KR-8: pk stringi KURULMAZ; yalniz hash hesaplanir
  j, c: Integer;
  iv: Int64;
  fv: Double;
  fn: TSqlFuncCallNode;
begin
  ctx := User;
  if Key = VDB_SCHEMA_KEY then Exit(True);
  if not VDbPeekRawRowKeyHashTo(Buf, Len, ctx.ColCnt, tid, ctx.PrefixSeed, kh,
                                ctx.MaxCol, ctx.FType, ctx.FOff, ctx.FLen) then
    Exit(False);   // eski sema / bozuk kayit -> genel yol (hata onda uretilir)
  if tid <> ctx.TableId then Exit(True);          // ScanRowsPart ile ayni kural
  if kh <> Key then
    Exit(False);   // hash carpismasi: genel yol ayni kayitta NET HATA verir
  for j := 0 to High(ctx.Plans) do
  begin
    if ctx.Plans[j].Col < 0 then                  // COUNT(*)
    begin
      Inc(ctx.Plans[j].Cnt);
      Continue;
    end;
    c := ctx.Plans[j].Col;
    // EvalAggregateValue bos metni NULL sayar: vl=-1 VE vl=0 ayni kapar
    if (ctx.FOff[c] < 0) or (ctx.FLen[c] = 0) then Continue;
    fn := ctx.Plans[j].Fn;
    if fn.FuncName = 'COUNT' then                 // her tur kolonda sayilir
    begin
      Inc(ctx.Plans[j].Cnt);
      Continue;
    end;
    // SUM/AVG/MIN/MAX: kolon tipi planda sinirlandi (INT/FLOAT/BOOL).
    case ctx.Ct[c] of
      VCT_INT:
        begin
          if ctx.FLen[c] <> 8 then Exit(False);   // DecodeRow gibi: 8 bayt sart
          Move(Buf[ctx.FOff[c]], iv, 8);
          // DIKKAT: Double(iv) mode-delphi'de BIT CAST'tir (denormal
          // cantan); deger donusumu atama/carpmayla olur (P-12 sqltest).
          fv := iv * 1.0;   // StrToFloat(IntToStr(iv)) ile birebir ayni
        end;
      VCT_FLOAT:
        begin
          if ctx.FLen[c] <> 8 then Exit(False);
          Move(Buf[ctx.FOff[c]], fv, 8);
          // NaN/Inf: VDbFloatToStr/Parse turu belirsiz -> genel yol
          if not ((fv = fv) and (fv < 1e308) and (fv > -1e308)) then Exit(False);
        end;
    else  // VCT_BOOL: BoolToStr(x, True) = '-1' / '0'
      begin
        if ctx.FLen[c] <> 1 then Exit(False);
        if Buf[ctx.FOff[c]] <> 0 then fv := -1 else fv := 0;
      end;
    end;
    // Kanonik bicimler VDbParseFloat'ta her zaman cozulur (NaN/Inf elendi)
    Inc(ctx.Plans[j].Cnt);
    Inc(ctx.Plans[j].AvgCnt);
    ctx.Plans[j].SumF := ctx.Plans[j].SumF + fv;
    if fn.FuncName = 'MIN' then
    begin
      if not ctx.Plans[j].HasMin then
      begin
        ctx.Plans[j].HasMin := True;
        if ctx.Ct[c] = VCT_INT then ctx.Plans[j].MinI := iv else ctx.Plans[j].MinF := fv;
      end
      else if ctx.Ct[c] = VCT_INT then
      begin if iv < ctx.Plans[j].MinI then ctx.Plans[j].MinI := iv end
      else if fv < ctx.Plans[j].MinF then ctx.Plans[j].MinF := fv;
    end
    else if fn.FuncName = 'MAX' then
    begin
      if not ctx.Plans[j].HasMax then
      begin
        ctx.Plans[j].HasMax := True;
        if ctx.Ct[c] = VCT_INT then ctx.Plans[j].MaxI := iv else ctx.Plans[j].MaxF := fv;
      end
      else if ctx.Ct[c] = VCT_INT then
      begin if iv > ctx.Plans[j].MaxI then ctx.Plans[j].MaxI := iv end
      else if fv > ctx.Plans[j].MaxF then ctx.Plans[j].MaxF := fv;
    end;
  end;
  Result := True;
end;

{ ------------------------------------------------------------
  H6 (2026-10-18) — Tek sorgu paralel agrega.
  TryStreamAgg'in seri taramasini [0, DataFileSize) offset araliklarina
  bolup isci havuzuna dagitir. Her isci KENDI TAggIterCtx kopyasina
  biriktirir; sonra planlar birlestirilir. COUNT/SUM/AVG/MIN/MAX
  birlesmeli (associative) oldugundan sonuc offset bolunmesinden
  bagimsizdir.

  Determinizm siniri: SUM/AVG bir VCT_FLOAT kolonundaysa kayan nokta
  toplama sirasi sonucun son bitini degistirebilir; bu durumda paralel
  yol KAPATILIR (seri sonuc bit-ayni kalir). VCT_INT toplamlari
  |toplam| < 2^53 icin tamdir, bu yuzden birlestirme bit-ayni sonuc verir.
  ------------------------------------------------------------ }
const
  { H6: altinda seri yol (kucuk tabloda regresyon yok). Ust sinir: aday
    kumesi isci sayisindan bagimsiz TEK kez ~24 B/satir tutar; i386 adres
    alanini korumak icin cok buyuk tabloda seri kalinir. }
  VDB_PAR_AGG_MIN_ROWS = 20000;
  VDB_PAR_AGG_MAX_ROWS = 2000000;

type
  TAggParCtx = record
    Kv: TVDb;
    TableId: Word;
    Base: TAggIterCtx;              // salt-okunur sablon (paylasilan diziler)
    Ctxs: array of TAggIterCtx;     // isci basina ayri biriktirici
    Prep: TVDbRawPrepared;          // ADAY KUMESI bir kez toplandi
    CLo, CHi: array of Integer;     // isci basina aday araligi
    Fails: array of Byte;           // isci basina basarisizlik bayragi
  end;

procedure VdbAggParTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
var
  pc: ^TAggParCtx;
  i, j: Integer;
begin
  pc := ACtx;
  for i := ALo to AHi do
  begin
    pc.Ctxs[i].Ct := pc.Base.Ct;
    // DIKKAT (H6): FType/FOff/FLen VdbAggRawCb tarafindan HER SATIRDA
    // YENIDEN YAZILIR (VDbPeekRawRowKeyHashTo). Paylasilirsa isciler
    // birbirinin kolon ofsetini ezer -> yanlis deger (8 iscide goruldu).
    // Bu yuzden her isciye AYRI dizi verilir; Ct salt-okunur oldugundan
    // paylasilabilir.
    SetLength(pc.Ctxs[i].FType, Length(pc.Base.FType));
    SetLength(pc.Ctxs[i].FOff, Length(pc.Base.FOff));
    SetLength(pc.Ctxs[i].FLen, Length(pc.Base.FLen));
    pc.Ctxs[i].ColCnt := pc.Base.ColCnt;
    pc.Ctxs[i].TableId := pc.Base.TableId;
    pc.Ctxs[i].TableName := pc.Base.TableName;
    pc.Ctxs[i].PrefixSeed := pc.Base.PrefixSeed;
    pc.Ctxs[i].MaxCol := pc.Base.MaxCol;
    SetLength(pc.Ctxs[i].Plans, Length(pc.Base.Plans));
    for j := 0 to High(pc.Ctxs[i].Plans) do
    begin
      // Sablon planlar (Fn/Col) kopyalanir; SAYACLAR sifirdan baslar.
      pc.Ctxs[i].Plans[j] := pc.Base.Plans[j];
      pc.Ctxs[i].Plans[j].Cnt := 0;
      pc.Ctxs[i].Plans[j].AvgCnt := 0;
      pc.Ctxs[i].Plans[j].SumF := 0;
      pc.Ctxs[i].Plans[j].MinI := 0;
      pc.Ctxs[i].Plans[j].MaxI := 0;
      pc.Ctxs[i].Plans[j].MinF := 0;
      pc.Ctxs[i].Plans[j].MaxF := 0;
      pc.Ctxs[i].Plans[j].HasMin := False;
      pc.Ctxs[i].Plans[j].HasMax := False;
    end;
    if not pc.Kv.ScanRawPrepared(pc.Prep, pc.CLo[i], pc.CHi[i],
      VdbAggRawCb, @pc.Ctxs[i]) then
      pc.Fails[i] := 1;
  end;
end;

function TVSqlExecutor.TryStreamAgg(Stmt: TSqlSelectStmt; const td: TTableDef;
  out Res: TSqlResult): Boolean;
var
  j, c, colCnt: Integer;
  mc: Integer;                     // KR-8c: planlarin max referans kolonu
  cn: TStrArray;
  ct, ftype: TByteArray;
  foff, flen: TIntArray;
  plans: array of TAggPlan;
  ctx: TAggIterCtx;
  fn: TSqlFuncCallNode;
  cr: TSqlColumnRefNode;
  useCounter, allStar: Boolean;   // KR-1B
  ncnt: Int64;                     // KR-1B
  // H6: paralel yol
  usePar: Boolean;
  parN, i, w, total, kc: Integer;
  prep: TVDbRawPrepared;
  prepared: Boolean;
  pc: TAggParCtx;
begin
  Result := False;
  { --- 1) Sorgu sekli korumasi: yalnizca saf, tek tablo, tek grup --- }
  if (Stmt.FromTable = '') or Stmt.HasJoin then Exit;
  if (Stmt.SetOp <> sokNone) or (Stmt.RightSelect <> nil) then Exit;
  if Stmt.AsOf <> saoNone then Exit;
  if Stmt.WithQueries.Count > 0 then Exit;
  if Stmt.IsDistinct then Exit;
  if (Stmt.WhereClause <> nil) or (Stmt.HavingClause <> nil) or
     (Stmt.QualifyClause <> nil) then Exit;
  if Stmt.GroupByCols.Count > 0 then Exit;
  if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then Exit;
  if (Stmt.LimitVal >= 0) or (Stmt.OffsetVal <> 0) then Exit;
  if td.IsView then Exit;
  if FT.RlsApplies(Stmt.FromTable) then Exit;   // R-19: RLS -> genel yol
  if Stmt.Columns.Count = 0 then Exit;

  BuildColInfo(td, cn, ct);   // kolon adlari nitelemesiz, sira = td.Cols

  SetLength(plans, Stmt.Columns.Count);
  for j := 0 to Stmt.Columns.Count - 1 do
  begin
    if not (Stmt.Columns[j].Expr is TSqlFuncCallNode) then Exit;
    fn := TSqlFuncCallNode(Stmt.Columns[j].Expr);
    if not ((fn.FuncName = 'COUNT') or (fn.FuncName = 'SUM') or
            (fn.FuncName = 'AVG') or (fn.FuncName = 'MIN') or
            (fn.FuncName = 'MAX')) then Exit;
    if fn.IsDistinct or (fn.Filter <> nil) then Exit;
    FillChar(plans[j], SizeOf(TAggPlan), 0);
    plans[j].Fn := fn;
    if fn.IsStar then
    begin
      // EvalAggregateValue'daki gibi: yildiz yalniz COUNT'u sayar
      if fn.FuncName <> 'COUNT' then Exit;
      plans[j].Col := -1;
      Continue;
    end;
    if not (fn.Arg is TSqlColumnRefNode) then Exit;
    cr := TSqlColumnRefNode(fn.Arg);
    c := FindColIdx(cr.ColumnName, cr.TableQualifier, cn);
    if c < 0 then Exit;                       // cozumsuz -> genel yol hatasi
    plans[j].Col := c;
    if ((fn.FuncName = 'SUM') or (fn.FuncName = 'AVG')) and
       not ((ct[c] = VCT_INT) or (ct[c] = VCT_FLOAT) or (ct[c] = VCT_BOOL)) then
      Exit;      // metin/tarih: VDbParseFloat esik davranisi birebir degil
    if ((fn.FuncName = 'MIN') or (fn.FuncName = 'MAX')) and
       not ((ct[c] = VCT_INT) or (ct[c] = VCT_FLOAT)) then
      Exit;      // BOOL/metin karsilastirma semantigi genel yolda farkli
  end;

  { --- KR-1B: Saf COUNT(*) (TUM secim kolonlari yildiz) + autocommit ise
        taramayi HIC yapmadan motorun bellek-ici canli satir sayacindan O(1)
        yanit ver. Acik batch'te bekleyen INSERT/DELETE gorunurlugu sayaca
        yansimadigi icin akiskan taramaya dus; karisik agregada (COUNT(k),
        SUM...) da akiskan tarama gerekir. Sonuc kurulumu asagida BIREBIR
        ayni kod oldugu icin alan adi/deger bicimi degismez. --- }
  useCounter := False;
  allStar := False;
  if not FT.Kv.InBatch then
  begin
    allStar := True;
    for j := 0 to High(plans) do
      if plans[j].Col <> -1 then
      begin
        allStar := False;
        Break;
      end;
    if allStar and FT.Kv.TryGetTableRowCount(td.TableId, ncnt) then
    begin
      for j := 0 to High(plans) do
        plans[j].Cnt := ncnt;
      useCounter := True;
    end;
  end;

  if not useCounter then
  begin
  { --- 2) Ham akis: ScanRows'un okudugu AYNI kayit kumesi; alanlar
        cozulmez, ofset/uzunluk uzerinden okunur (string alloc YOK). --- }
  colCnt := Length(td.Cols);
  SetLength(ftype, colCnt); SetLength(foff, colCnt); SetLength(flen, colCnt);
  // P-18a: sifir-kopya akis (ScanRawIter). plans/ftype/foff/flen/ct
  // dizileri ctx uzerinden ayni gondermeyi paylasir; sayac guncellemeleri
  // geri cagrisinda YERINDE yapilir (bkz. VdbAggRawCb — govde P-12 ile
  // birebir, veri kaynagi (Buf, Len)). False => genel yola dus.
  ctx.ColCnt := colCnt;
  ctx.TableId := td.TableId;
  ctx.TableName := td.Name;
  ctx.PrefixSeed := VDbHashKeyPrefix(td.Name);   // KR-8: satir basi pk stringi yerine tek tohum
  ctx.Ct := ct;
  ctx.FType := ftype; ctx.FOff := foff; ctx.FLen := flen;
  ctx.Plans := plans;
  // KR-8c: planlarin referans verdigi en buyuk kolon indeksi. Erken kolon-
  // durmasi bu noktada durur; sonrasindaki kolonlar (aggregate'in OKUMADIGI)
  // cozulmez. COUNT(*) Col=-1 oldugundan hic kolon cozulmez (mc=-1).
  mc := -1;
  for j := 0 to High(plans) do
    if plans[j].Col > mc then mc := plans[j].Col;
  ctx.MaxCol := mc;

  { H6: paralel uygunluk. Kucuk tabloda ve SUM/AVG VCT_FLOAT'ta seri yol
    korunur (bit-ayni sonuc). Aday kumesi BIR KEZ hazirlanir; isciler
    yalnizca kendi dilimini tarar (isci basina O(n) FIndex dolasimi YOK). }
  kc := FT.Kv.TableKeyCount(td.TableId);
  usePar := (kc >= VDB_PAR_AGG_MIN_ROWS) and (kc <= VDB_PAR_AGG_MAX_ROWS);
  if usePar then
    for j := 0 to High(plans) do
      if (plans[j].Col >= 0) and
         ((plans[j].Fn.FuncName = 'SUM') or (plans[j].Fn.FuncName = 'AVG')) and
         (ct[plans[j].Col] = VCT_FLOAT) then
      begin
        usePar := False;
        Break;
      end;
  total := 0;
  prepared := False;
  if usePar then
  begin
    if not FT.Kv.PrepareRawScan(td.TableId, prep) then
      usePar := False
    else
    begin
      prepared := True;
      total := Length(prep.CandOff);
      if total < VDB_PAR_AGG_MIN_ROWS then usePar := False;
    end;
  end;
  if usePar and (not ThreadPoolReady) then
    usePar := InitThreadPool(0);
  if usePar and (ParallelWorkerCount < 2) then
    usePar := False;

  if usePar then
  begin
    parN := ParallelWorkerCount;
    if parN > VDB_PAR_MAX_WORKERS then parN := VDB_PAR_MAX_WORKERS;
    if parN < 2 then parN := 2;
    SetLength(pc.Ctxs, parN);
    SetLength(pc.Fails, parN);
    SetLength(pc.CLo, parN);
    SetLength(pc.CHi, parN);
    pc.Kv := FT.Kv;
    pc.TableId := td.TableId;
    pc.Base := ctx;
    pc.Prep := prep;
    for i := 0 to parN - 1 do
    begin
      // ADAY SAYISINA gore denge (bucket sinirlari degil): her isci
      // hemen hemen ayni sayida satir isler.
      pc.CLo[i] := Integer((Int64(total) * i) div parN);
      pc.CHi[i] := Integer((Int64(total) * (i + 1)) div parN);
      pc.Fails[i] := 0;
    end;
    VdbParallelForChunked(0, parN - 1, parN, VdbAggParTask, @pc);
    // Isci taramalari bitti: eslemeyi birak (pc.Ctxs sonuclari kalir).
    if prepared then
    begin
      FT.Kv.ReleasePreparedScan(prep);
      prepared := False;
    end;
    for i := 0 to parN - 1 do
      if pc.Fails[i] <> 0 then Exit;   // -> genel yol (hata orada uretilir)
    // Birlesim: isci sirasi sabit -> deterministik.
    for j := 0 to High(plans) do
    begin
      c := plans[j].Col;
      for w := 0 to parN - 1 do
      begin
        Inc(plans[j].Cnt, pc.Ctxs[w].Plans[j].Cnt);
        Inc(plans[j].AvgCnt, pc.Ctxs[w].Plans[j].AvgCnt);
        plans[j].SumF := plans[j].SumF + pc.Ctxs[w].Plans[j].SumF;
        if pc.Ctxs[w].Plans[j].HasMin then
        begin
          if not plans[j].HasMin then
          begin
            plans[j].HasMin := True;
            plans[j].MinI := pc.Ctxs[w].Plans[j].MinI;
            plans[j].MinF := pc.Ctxs[w].Plans[j].MinF;
          end
          else if (c >= 0) and (ct[c] = VCT_INT) then
          begin
            if pc.Ctxs[w].Plans[j].MinI < plans[j].MinI then
              plans[j].MinI := pc.Ctxs[w].Plans[j].MinI;
          end
          else if pc.Ctxs[w].Plans[j].MinF < plans[j].MinF then
            plans[j].MinF := pc.Ctxs[w].Plans[j].MinF;
        end;
        if pc.Ctxs[w].Plans[j].HasMax then
        begin
          if not plans[j].HasMax then
          begin
            plans[j].HasMax := True;
            plans[j].MaxI := pc.Ctxs[w].Plans[j].MaxI;
            plans[j].MaxF := pc.Ctxs[w].Plans[j].MaxF;
          end
          else if (c >= 0) and (ct[c] = VCT_INT) then
          begin
            if pc.Ctxs[w].Plans[j].MaxI > plans[j].MaxI then
              plans[j].MaxI := pc.Ctxs[w].Plans[j].MaxI;
          end
          else if pc.Ctxs[w].Plans[j].MaxF > plans[j].MaxF then
            plans[j].MaxF := pc.Ctxs[w].Plans[j].MaxF;
        end;
      end;
    end;
  end
  else
  begin
    // Hazirlik yapildi ama paralel yol secilmedi (kucuk kume / havuz yok).
    if prepared then
    begin
      FT.Kv.ReleasePreparedScan(prep);
      prepared := False;
    end;
    if not FT.Kv.ScanRawIterAll(td.TableId, VdbAggRawCb, @ctx) then
      Exit;
  end;
  { KR-1B: saf COUNT(*) (allStar => autocommit) dogrulamali tarayarak sayildi;
    sonucu cache'e yaz -> sonraki ayni COUNT taramasiz O(1) doner. }
  if allStar then
    FT.Kv.SetTableRowCount(td.TableId, plans[0].Cnt);
  end;

  { --- 3) Sonuc: ExecGroupBy'nin alan adi / deger bicimi kurallari BIREBIR --- }
  SetLength(Res.Fields, Stmt.Columns.Count);
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], Stmt.Columns.Count);
  for j := 0 to Stmt.Columns.Count - 1 do
  begin
    fn := plans[j].Fn;
    if Stmt.Columns[j].Alias <> '' then
      Res.Fields[j] := Stmt.Columns[j].Alias
    else
      Res.Fields[j] := fn.FuncName;
    if fn.FuncName = 'COUNT' then
      Res.Rows[0][j] := IntToStr(plans[j].Cnt)
    else if fn.FuncName = 'SUM' then
    begin
      if plans[j].Cnt > 0 then
        Res.Rows[0][j] := VDbFloatToStr(plans[j].SumF)
      else Res.Rows[0][j] := '';
    end
    else if fn.FuncName = 'AVG' then
    begin
      if plans[j].AvgCnt > 0 then
        Res.Rows[0][j] := VDbFloatToStr(plans[j].SumF / plans[j].AvgCnt)
      else Res.Rows[0][j] := '';
    end
    else if fn.FuncName = 'MIN' then
    begin
      if not plans[j].HasMin then Res.Rows[0][j] := ''
      else if ct[plans[j].Col] = VCT_INT then
        Res.Rows[0][j] := IntToStr(plans[j].MinI)
      else Res.Rows[0][j] := VDbFloatToStr(plans[j].MinF);
    end
    else  // MAX
    begin
      if not plans[j].HasMax then Res.Rows[0][j] := ''
      else if ct[plans[j].Col] = VCT_INT then
        Res.Rows[0][j] := IntToStr(plans[j].MaxI)
      else Res.Rows[0][j] := VDbFloatToStr(plans[j].MaxF);
    end;
  end;
  Res.Affected := 1;
  Res.Msg := 'OK';
  Result := True;
end;

{ ------------------------------------------------------------
  H13 (2026-10-21) - TryStreamGroupBy
  ------------------------------------------------------------
  ExecGroupBy tum satirlari once TStrMatrix'e cevirip her satir icin
  grup anahtarini TList uzerinde LINEER ariyor, sonra her grubun satir
  indekslerini ayri ayri dolasip aggregate'i yeniden hesapliyordu.
  1M satir / ~12 grup icin bu ~4 s suruyordu.

  Bu yol ayni sonucu ham kayit tamponu uzerinden uretir:
    * satirlar matrise cevrilmez,
    * grup arama TDictionary ile O(1) (ilk-gorulme sirasi korunur),
    * COUNT/SUM/AVG/MIN/MAX her satirda grup sayacina EKLENIR.
  Yalniz guvenli sekil desteklenir; WHERE varsa satir yine RowMatches
  ile dogrulanir. ORDER BY/OFFSET/LIMIT cagiran tarafta FinishGroup'ta
  uygulanir. Sekil uymazsa False -> ExecGroupBy AYNEN calisir. }
type
  TStreamGroupState = record
    Key: TStrArray;
    Plans: array of TAggPlan;
  end;

  TStreamGroupCtx = record
    Exec: TVSqlExecutor;
    TableId: Word;
    HashPrefix: QWord;
    ColCnt: Integer;
    FType: TByteArray;
    FOff, FLen: TIntArray;
    Ct: TByteArray;
    ColNames: TStrArray;
    ColTypes: TByteArray;
    GroupCols: TIntArray;
    Plans: array of TAggPlan;      // SELECT sira indeksli sablon
    Where: TSqlExprNode;
    RawConds: TRawCondArray;
    RawTree: TRawTree;
    RawTreeRoot: Integer;
    MaxCol: Integer;
    Groups: array of TStreamGroupState;
    Map: TDictionary<string, Integer>;
    Failed: Boolean;
  end;
  PStreamGroupCtx = ^TStreamGroupCtx;

function VdbStrPureAscii(const S: string): Boolean; forward;

function VdbStreamGroupCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
var
  C: PStreamGroupCtx;
  tid: Word;
  kh: QWord;
  j, ci, gi: Integer;
  gkey, gv: string;
  vals: TStrArray;
  st: ^TStreamGroupState;
  iv: Int64;
  fv: Double;
  whereOK: Boolean;

  procedure NewGroup;
  var
    k: Integer;
  begin
    SetLength(C^.Groups, Length(C^.Groups) + 1);
    gi := High(C^.Groups);
    st := @C^.Groups[gi];
    SetLength(st^.Key, Length(C^.GroupCols));
    for k := 0 to High(C^.GroupCols) do
      st^.Key[k] := VDbColFromOffsetsP(Buf, C^.ColCnt, C^.GroupCols[k],
        C^.FType, C^.FOff, C^.FLen);
    SetLength(st^.Plans, Length(C^.Plans));
    for k := 0 to High(C^.Plans) do
    begin
      st^.Plans[k] := C^.Plans[k];
      st^.Plans[k].Cnt := 0;
      st^.Plans[k].AvgCnt := 0;
      st^.Plans[k].SumF := 0;
      st^.Plans[k].MinI := 0;
      st^.Plans[k].MaxI := 0;
      st^.Plans[k].MinF := 0;
      st^.Plans[k].MaxF := 0;
      st^.Plans[k].HasMin := False;
      st^.Plans[k].HasMax := False;
    end;
    C^.Map.Add(gkey, gi);
  end;

begin
  C := User;
  Result := True;
  if Key = VDB_SCHEMA_KEY then Exit;
  if not VDbPeekRawRowKeyHashTo(Buf, Len, C^.ColCnt, tid, C^.HashPrefix,
       kh, C^.MaxCol, C^.FType, C^.FOff, C^.FLen) then
  begin
    C^.Failed := True; Exit(False);
  end;
  if tid <> C^.TableId then Exit;
  if kh <> Key then
  begin
    C^.Failed := True; Exit(False);
  end;

  // H21: tam boolean agaci FALSE/UNKNOWN satiri cozmeden eler; TRUE ise
  // RowMatches'a hic gerek kalmaz.
  whereOK := False;
  if C^.RawTreeRoot >= 0 then
  begin
    case VdbEvalRawTree(C^.RawTree, C^.RawTreeRoot, Buf, C^.FType,
      C^.FOff, C^.FLen) of
      rvFalse, rvUnknown: Exit;
      rvTrue: whereOK := True;
    end;
  end;
  if not whereOK then
  begin
    // H13: basit WHERE kosullarinda satiri cozmeden kesin eleme.
    if (C^.Where <> nil) and (Length(C^.RawConds) > 0) then
      if not VdbStreamSelRawPass(C^.RawConds, Buf, C^.FType,
        C^.FOff, C^.FLen) then Exit;

    // WHERE: nihai dogrulama her zaman RowMatches (ham yol yalniz hizlandirir).
    if C^.Where <> nil then
    begin
      VDbRowFromOffsetsP(Buf, C^.ColCnt, C^.FType, C^.FOff, C^.FLen, vals);
      if not C^.Exec.RowMatches(C^.Where, vals, C^.ColNames, C^.ColTypes) then
        Exit;
    end;
  end;

  // Uzunluk-onekli anahtar: ayirici/veri cakismasi imkansiz.
  gkey := '';
  for j := 0 to High(C^.GroupCols) do
  begin
    gv := VDbColFromOffsetsP(Buf, C^.ColCnt, C^.GroupCols[j],
      C^.FType, C^.FOff, C^.FLen);
    gkey := gkey + IntToStr(Length(gv)) + ':' + gv;
  end;
  if not C^.Map.TryGetValue(gkey, gi) then NewGroup;

  st := @C^.Groups[gi];
  for j := 0 to High(st^.Plans) do
  begin
    if st^.Plans[j].Fn = nil then Continue;
    if st^.Plans[j].Col < 0 then                 // COUNT(*)
    begin
      Inc(st^.Plans[j].Cnt);
      Continue;
    end;
    ci := st^.Plans[j].Col;
    // EvalAggregateValue bos metni NULL sayar.
    if (C^.FOff[ci] < 0) or (C^.FLen[ci] = 0) then Continue;
    if st^.Plans[j].Fn.FuncName = 'COUNT' then
    begin
      Inc(st^.Plans[j].Cnt);
      Continue;
    end;
    // SUM/AVG/MIN/MAX: guvenli sekil kontrolu INT/FLOAT ile sinirli.
    case C^.Ct[ci] of
      VCT_INT:
        begin
          if C^.FLen[ci] <> 8 then begin C^.Failed := True; Exit(False); end;
          Move(Buf[C^.FOff[ci]], iv, 8);
          fv := iv * 1.0;
        end;
      VCT_FLOAT:
        begin
          if C^.FLen[ci] <> 8 then begin C^.Failed := True; Exit(False); end;
          Move(Buf[C^.FOff[ci]], fv, 8);
          if not ((fv = fv) and (fv < 1e308) and (fv > -1e308)) then
          begin
            C^.Failed := True; Exit(False);
          end;
        end;
    else
      begin
        { BOOL: genel yolda deger 'True'/'False' metnidir ve
          VDbParseFloat'a GIRMEZ -> toplama katkisi 0, avg sayaci artmaz.
          Ayni sonucu vermek icin yalnizca bos olmayan sayac artirilir. }
        if C^.FLen[ci] <> 1 then begin C^.Failed := True; Exit(False); end;
        Inc(st^.Plans[j].Cnt);
        Continue;
      end;
    end;
    Inc(st^.Plans[j].Cnt);
    Inc(st^.Plans[j].AvgCnt);
    st^.Plans[j].SumF := st^.Plans[j].SumF + fv;
    if st^.Plans[j].Fn.FuncName = 'MIN' then
    begin
      if not st^.Plans[j].HasMin then
      begin
        st^.Plans[j].HasMin := True;
        if C^.Ct[ci] = VCT_INT then st^.Plans[j].MinI := iv
        else st^.Plans[j].MinF := fv;
      end
      else if C^.Ct[ci] = VCT_INT then
      begin
        if iv < st^.Plans[j].MinI then st^.Plans[j].MinI := iv;
      end
      else if fv < st^.Plans[j].MinF then st^.Plans[j].MinF := fv;
    end
    else if st^.Plans[j].Fn.FuncName = 'MAX' then
    begin
      if not st^.Plans[j].HasMax then
      begin
        st^.Plans[j].HasMax := True;
        if C^.Ct[ci] = VCT_INT then st^.Plans[j].MaxI := iv
        else st^.Plans[j].MaxF := fv;
      end
      else if C^.Ct[ci] = VCT_INT then
      begin
        if iv > st^.Plans[j].MaxI then st^.Plans[j].MaxI := iv;
      end
      else if fv > st^.Plans[j].MaxF then st^.Plans[j].MaxF := fv;
    end;
  end;
end;

function TVSqlExecutor.TryStreamGroupBy(Stmt: TSqlSelectStmt;
  const td: TTableDef; const ColNames: TStrArray;
  const ColTypes: TByteArray; out Res: TSqlResult;
  out OutTypes: TByteArray): Boolean;
var
  j, c, gi: Integer;
  E: TSqlExprNode;
  fn: TSqlFuncCallNode;
  cr: TSqlColumnRefNode;
  ctx: TStreamGroupCtx;
  plans: array of TAggPlan;
  selGroup: TIntArray;
  gb: string;
  dp: Integer;
  st: ^TStreamGroupState;
  plan: TAggPlan;
  conj: TList<TSqlExprNode>;
  cnd: TRawCond;
  // H15: HAVING destegi
  havNodes: array of TSqlExprNode;   // HAVING'deki aggregate cagri dugumleri
  nRow: Integer;
  havingOk: Boolean;
  root: Integer;

  procedure CollectAnd(E: TSqlExprNode);
  begin
    if E = nil then Exit;
    if (E is TSqlBinaryOpNode) and (TSqlBinaryOpNode(E).Op = sboAnd) then
    begin
      CollectAnd(TSqlBinaryOpNode(E).Left);
      CollectAnd(TSqlBinaryOpNode(E).Right);
    end
    else conj.Add(E);
  end;

  { H13: AND zincirindeki basit kiyaslari ham on-elemeye cevirir. Destek
    disi kosul atlanir; hicbir zaman yanlis eleme yapilmaz (RowMatches son
    sozdur). }
  function TryRawCond(E: TSqlExprNode; out C: TRawCond): Boolean;
  var
    b: TSqlBinaryOpNode;
    op: TSqlBinaryOp;
    swap: Boolean;
    crl: TSqlColumnRefNode;
    lit: TSqlLiteralNode;
    ci2: Integer;
  begin
    Result := False;
    if not (E is TSqlBinaryOpNode) then Exit;
    b := TSqlBinaryOpNode(E);
    op := b.Op;
    if not (op in [sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte]) then Exit;
    swap := False;
    if b.Left is TSqlColumnRefNode then
    begin
      crl := TSqlColumnRefNode(b.Left);
      if not (b.Right is TSqlLiteralNode) then Exit;
      lit := TSqlLiteralNode(b.Right);
    end
    else if b.Right is TSqlColumnRefNode then
    begin
      crl := TSqlColumnRefNode(b.Right);
      if not (b.Left is TSqlLiteralNode) then Exit;
      lit := TSqlLiteralNode(b.Left);
      swap := True;
    end
    else Exit;
    ci2 := FindColIdx(crl.ColumnName, crl.TableQualifier, ColNames);
    if (ci2 < 0) or (ci2 > High(td.Cols)) or (ci2 > High(ColTypes)) then Exit;
    if td.Cols[ci2].Encrypted then Exit;
    if swap then
      case op of
        sboLt: op := sboGt;
        sboLte: op := sboGte;
        sboGt: op := sboLt;
        sboGte: op := sboLte;
      end;
    C.Col := ci2; C.Op := op; C.IsFloat := False; C.IsText := False;
    C.IsIn := False; C.InIsFloat := False;
    C.I := 0; C.F := 0; C.S := '';
    C.InInts := nil; C.InFloats := nil;
    if ColTypes[ci2] = VCT_INT then
    begin
      if lit.LitType <> sltInt then Exit;
      C.I := lit.IntVal;
      Exit(True);
    end;
    if ColTypes[ci2] = VCT_FLOAT then
    begin
      if lit.LitType = sltInt then C.F := lit.IntVal
      else if lit.LitType = sltFloat then C.F := lit.FloatVal
      else Exit;
      C.IsFloat := True;
      Exit(True);
    end;
    if ColTypes[ci2] = VCT_STR then
    begin
      if not (op in [sboEq, sboNeq]) then Exit;
      if lit.LitType <> sltString then Exit;
      if not VdbStrPureAscii(lit.StrVal) then Exit;
      C.IsText := True;
      C.S := lit.StrVal;
      Exit(True);
    end;
  end;

  { H15: HAVING AST'sini tarar. Desteklenen her aggregate cagrisi icin
    plans dizisinin SONUNA bir plan ekler ve dugum kimligini havNodes'a
    yazar. Desteklenmeyen bir bicim (DISTINCT/FILTER, ifade argumani,
    metin MIN/MAX, STRING_AGG/PERCENTILE, alt sorgu, pencere) varsa
    False doner: cagiran genel yola duser (sonuc birebir ayni kalir). }
  function CollectHavingAgg(E: TSqlExprNode): Boolean;
  var
    f2: TSqlFuncCallNode;
    cr2: TSqlColumnRefNode;
    c2, k2: Integer;
    p2: TAggPlan;
  begin
    Result := False;
    if E = nil then Exit(True);
    if E is TSqlAggNode then Exit;          // STRING_AGG/PERCENTILE
    if E is TSqlSubqueryNode then Exit;     // skaler/EXISTS alt sorgu
    if E is TSqlQuantNode then Exit;        // ANY/SOME/ALL
    if E is TSqlWindowNode then Exit;       // pencere fonksiyonu
    if E is TSqlFuncCallNode then
    begin
      f2 := TSqlFuncCallNode(E);
      if IsAggFuncName(f2.FuncName) then
      begin
        if not ((f2.FuncName = 'COUNT') or (f2.FuncName = 'SUM') or
                (f2.FuncName = 'AVG') or (f2.FuncName = 'MIN') or
                (f2.FuncName = 'MAX')) then Exit;
        if f2.IsDistinct or (f2.Filter <> nil) then Exit;
        FillChar(p2, SizeOf(TAggPlan), 0);
        p2.Fn := f2;
        if f2.IsStar then
        begin
          if f2.FuncName <> 'COUNT' then Exit;
          p2.Col := -1;
        end
        else
        begin
          if not (f2.Arg is TSqlColumnRefNode) then Exit;
          cr2 := TSqlColumnRefNode(f2.Arg);
          c2 := FindColIdx(cr2.ColumnName, cr2.TableQualifier, ColNames);
          if (c2 < 0) or (c2 > High(td.Cols)) or (c2 > High(ColTypes)) then
            Exit;
          if td.Cols[c2].Encrypted then Exit;   // sifreli uzunluk != acik metin
          if ((f2.FuncName = 'SUM') or (f2.FuncName = 'AVG')) and
             not ((ColTypes[c2] = VCT_INT) or (ColTypes[c2] = VCT_FLOAT) or
                  (ColTypes[c2] = VCT_BOOL)) then Exit;
          if ((f2.FuncName = 'MIN') or (f2.FuncName = 'MAX')) and
             not ((ColTypes[c2] = VCT_INT) or (ColTypes[c2] = VCT_FLOAT)) then
            Exit;
          p2.Col := c2;
        end;
        SetLength(plans, Length(plans) + 1);
        plans[High(plans)] := p2;
        SetLength(havNodes, Length(havNodes) + 1);
        havNodes[High(havNodes)] := E;
        Exit(True);
      end;
      // Aggregate olmayan fonksiyon: argumanlarini tara.
      if (f2.Arg <> nil) and (not CollectHavingAgg(f2.Arg)) then Exit;
      if f2.Args <> nil then
        for k2 := 0 to f2.Args.Count - 1 do
          if not CollectHavingAgg(f2.Args[k2]) then Exit;
      Exit(True);
    end;
    if E is TSqlBinaryOpNode then
    begin
      if not CollectHavingAgg(TSqlBinaryOpNode(E).Left) then Exit;
      Exit(CollectHavingAgg(TSqlBinaryOpNode(E).Right));
    end;
    if E is TSqlUnaryOpNode then
      Exit(CollectHavingAgg(TSqlUnaryOpNode(E).Operand));
    if E is TSqlCastNode then
      Exit(CollectHavingAgg(TSqlCastNode(E).Expr));
    if E is TSqlCollateNode then
      Exit(CollectHavingAgg(TSqlCollateNode(E).Inner));
    if E is TSqlBetweenNode then
    begin
      if not CollectHavingAgg(TSqlBetweenNode(E).Expr) then Exit;
      if not CollectHavingAgg(TSqlBetweenNode(E).LowBound) then Exit;
      Exit(CollectHavingAgg(TSqlBetweenNode(E).HighBound));
    end;
    if E is TSqlInNode then
    begin
      if TSqlInNode(E).SubSelect <> nil then Exit;   // IN (SELECT ...)
      if not CollectHavingAgg(TSqlInNode(E).Expr) then Exit;
      for k2 := 0 to TSqlInNode(E).List.Count - 1 do
        if not CollectHavingAgg(TSqlInNode(E).List[k2]) then Exit;
      Exit(True);
    end;
    if E is TSqlCaseNode then
    begin
      if not CollectHavingAgg(TSqlCaseNode(E).Operand) then Exit;
      for k2 := 0 to TSqlCaseNode(E).Whens.Count - 1 do
      begin
        if not CollectHavingAgg(TSqlCaseNode(E).Whens[k2].Cond) then Exit;
        if not CollectHavingAgg(TSqlCaseNode(E).Whens[k2].Value) then Exit;
      end;
      Exit(CollectHavingAgg(TSqlCaseNode(E).ElseExpr));
    end;
    if E is TSqlNullIfNode then
    begin
      if not CollectHavingAgg(TSqlNullIfNode(E).Arg1) then Exit;
      Exit(CollectHavingAgg(TSqlNullIfNode(E).Arg2));
    end;
    if E is TSqlCoalesceNode then
    begin
      for k2 := 0 to TSqlCoalesceNode(E).Args.Count - 1 do
        if not CollectHavingAgg(TSqlCoalesceNode(E).Args[k2]) then Exit;
      Exit(True);
    end;
    if E is TSqlJsonKeyNode then
    begin
      if not CollectHavingAgg(TSqlJsonKeyNode(E).Left) then Exit;
      for k2 := 0 to TSqlJsonKeyNode(E).Keys.Count - 1 do
        if not CollectHavingAgg(TSqlJsonKeyNode(E).Keys[k2]) then Exit;
      Exit(True);
    end;
    // Literal / kolon referansi: yaprak.
    Exit(True);
  end;

  { Bir TAggPlan'in (grup sayaclarindan) metin degerini uretir.
    SELECT cikti kolonlari ve HAVING aggregate'leri AYNI donusumu kullanir
    (genel yol EvalAggregateValue ile birebir ayni bicim). }
  function AggPlanValue(const P: TAggPlan; const Ct: TByteArray): string;
  begin
    if P.Fn = nil then Exit('');
    if P.Fn.FuncName = 'COUNT' then Exit(IntToStr(P.Cnt));
    if P.Fn.FuncName = 'SUM' then
    begin
      if P.Cnt > 0 then Exit(VDbFloatToStr(P.SumF)) else Exit('');
    end;
    if P.Fn.FuncName = 'AVG' then
    begin
      if P.AvgCnt > 0 then Exit(VDbFloatToStr(P.SumF / P.AvgCnt)) else Exit('');
    end;
    if P.Fn.FuncName = 'MIN' then
    begin
      if not P.HasMin then Exit('')
      else if Ct[P.Col] = VCT_INT then Exit(IntToStr(P.MinI))
      else Exit(VDbFloatToStr(P.MinF));
    end;
    // MAX
    if not P.HasMax then Exit('')
    else if Ct[P.Col] = VCT_INT then Exit(IntToStr(P.MaxI))
    else Exit(VDbFloatToStr(P.MaxF));
  end;

begin
  Result := False;
  if (Stmt.FromTable = '') or Stmt.HasJoin then Exit;
  if (Stmt.SetOp <> sokNone) or (Stmt.RightSelect <> nil) then Exit;
  if Stmt.AsOf <> saoNone then Exit;
  if Stmt.WithQueries.Count > 0 then Exit;
  if Stmt.IsDistinct then Exit;
  if HasWindow(Stmt) or (Stmt.QualifyClause <> nil) then Exit;
  if Stmt.GroupByCols.Count = 0 then Exit;
  if Stmt.Columns.Count = 0 then Exit;
  if td.IsView then Exit;
  if FT.RlsApplies(Stmt.FromTable) then Exit;

  SetLength(ctx.GroupCols, Stmt.GroupByCols.Count);
  for j := 0 to Stmt.GroupByCols.Count - 1 do
  begin
    gb := Stmt.GroupByCols[j];
    dp := Pos('.', gb);
    if dp > 0 then
      c := FindColIdx(Copy(gb, dp + 1, MaxInt), Copy(gb, 1, dp - 1), ColNames)
    else
      c := FindColIdx(gb, '', ColNames);
    if (c < 0) or (c > High(td.Cols)) or (c > High(ColTypes)) then Exit;
    // M6/H13: sifreli kolonun ham baytlari acik metin degil; genel yol
    // (cozulmus satirlar) kullanilmalidir.
    if td.Cols[c].Encrypted then Exit;
    ctx.GroupCols[j] := c;
  end;

  SetLength(plans, Stmt.Columns.Count);
  SetLength(selGroup, Stmt.Columns.Count);
  for j := 0 to Stmt.Columns.Count - 1 do
  begin
    selGroup[j] := -1;
    FillChar(plans[j], SizeOf(TAggPlan), 0);
    E := Stmt.Columns[j].Expr;
    if E is TSqlColumnRefNode then
    begin
      cr := TSqlColumnRefNode(E);
      c := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
      if c < 0 then Exit;
      gi := -1;
      for dp := 0 to High(ctx.GroupCols) do
        if ctx.GroupCols[dp] = c then begin gi := dp; Break; end;
      if gi < 0 then Exit;   // GROUP BY disi duz kolon: genel yol
      selGroup[j] := gi;
      Continue;
    end;
    if not (E is TSqlFuncCallNode) then Exit;
    fn := TSqlFuncCallNode(E);
    if not ((fn.FuncName = 'COUNT') or (fn.FuncName = 'SUM') or
            (fn.FuncName = 'AVG') or (fn.FuncName = 'MIN') or
            (fn.FuncName = 'MAX')) then Exit;
    if fn.IsDistinct or (fn.Filter <> nil) then Exit;
    plan := plans[j];
    plan.Fn := fn;
    if fn.IsStar then
    begin
      if fn.FuncName <> 'COUNT' then Exit;
      plan.Col := -1;
    end
    else
    begin
      if not (fn.Arg is TSqlColumnRefNode) then Exit;
      cr := TSqlColumnRefNode(fn.Arg);
      c := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
      if (c < 0) or (c > High(td.Cols)) or (c > High(ColTypes)) then Exit;
      // M6: sifreli kolonun ham uzunlugu acik metinden farkli -> genel yol.
      if td.Cols[c].Encrypted then Exit;
      if ((fn.FuncName = 'SUM') or (fn.FuncName = 'AVG')) and
         not ((ColTypes[c] = VCT_INT) or (ColTypes[c] = VCT_FLOAT) or
              (ColTypes[c] = VCT_BOOL)) then Exit;
      if ((fn.FuncName = 'MIN') or (fn.FuncName = 'MAX')) and
         not ((ColTypes[c] = VCT_INT) or (ColTypes[c] = VCT_FLOAT)) then Exit;
      plan.Col := c;
    end;
    plans[j] := plan;
  end;

  // H15: HAVING'deki aggregate'ler icin ek planlar (dizinin sonuna).
  // selGroup[j]/st^.Plans[j] eslemesi yalniz ilk Stmt.Columns.Count ogeyi
  // kullanir; ek planlar yalniz HAVING degerleri icindir.
  if Stmt.HavingClause <> nil then
  begin
    SetLength(havNodes, 0);
    if not CollectHavingAgg(Stmt.HavingClause) then Exit;
  end;

  ctx.Exec := Self;
  ctx.TableId := td.TableId;
  ctx.HashPrefix := VDbHashKeyPrefix(td.Name);
  ctx.ColCnt := Length(td.Cols);
  SetLength(ctx.FType, ctx.ColCnt);
  SetLength(ctx.FOff, ctx.ColCnt);
  SetLength(ctx.FLen, ctx.ColCnt);
  SetLength(ctx.Ct, ctx.ColCnt);
  for j := 0 to High(ColTypes) do
    if j < ctx.ColCnt then ctx.Ct[j] := ColTypes[j];
  ctx.ColNames := ColNames;
  ctx.ColTypes := ColTypes;
  ctx.Plans := plans;
  ctx.Where := Stmt.WhereClause;
  ctx.RawTree := VdbBuildRawTree(Self, Stmt.WhereClause, td, ColNames,
    ColTypes, root);
  ctx.RawTreeRoot := root;
  SetLength(ctx.RawConds, 0);
  if Stmt.WhereClause <> nil then
  begin
    conj := TList<TSqlExprNode>.Create;
    try
      CollectAnd(Stmt.WhereClause);
      for j := 0 to conj.Count - 1 do
        if TryRawCond(conj[j], cnd) then
        begin
          SetLength(ctx.RawConds, Length(ctx.RawConds) + 1);
          ctx.RawConds[High(ctx.RawConds)] := cnd;
        end;
    finally
      conj.Free;
    end;
  end;
  ctx.Groups := nil;
  ctx.Failed := False;

  ctx.MaxCol := -1;
  for j := 0 to High(ctx.GroupCols) do
    if ctx.GroupCols[j] > ctx.MaxCol then ctx.MaxCol := ctx.GroupCols[j];
  for j := 0 to High(plans) do
    if (plans[j].Fn <> nil) and (plans[j].Col > ctx.MaxCol) then
      ctx.MaxCol := plans[j].Col;
  for j := 0 to High(ctx.RawConds) do
    if ctx.RawConds[j].Col > ctx.MaxCol then
      ctx.MaxCol := ctx.RawConds[j].Col;
  // RowMatches tam satiri ister: WHERE varsa TUM kolonlarin ofseti gecerli
  // olmali (aksi halde onceki satirdan kalan FOff/FLen kullanilirdi).
  if Stmt.WhereClause <> nil then
    ctx.MaxCol := ctx.ColCnt - 1;

  ctx.Map := TDictionary<string, Integer>.Create;
  try
    if not FT.Kv.ScanRawIterAll(td.TableId, VdbStreamGroupCb, @ctx) then Exit;
    if ctx.Failed then Exit;

    SetLength(Res.Fields, Stmt.Columns.Count);
    SetLength(OutTypes, Stmt.Columns.Count);
    for j := 0 to Stmt.Columns.Count - 1 do
    begin
      if Stmt.Columns[j].Alias <> '' then
        Res.Fields[j] := Stmt.Columns[j].Alias
      else if Stmt.Columns[j].Expr is TSqlFuncCallNode then
        Res.Fields[j] := TSqlFuncCallNode(Stmt.Columns[j].Expr).FuncName
      else if Stmt.Columns[j].Expr is TSqlColumnRefNode then
        Res.Fields[j] := TSqlColumnRefNode(Stmt.Columns[j].Expr).ColumnName
      else
        Res.Fields[j] := 'col' + IntToStr(j + 1);

      OutTypes[j] := VCT_STR;
      if Stmt.Columns[j].Expr is TSqlColumnRefNode then
      begin
        cr := TSqlColumnRefNode(Stmt.Columns[j].Expr);
        c := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
        if (c >= 0) and (c <= High(ColTypes)) then OutTypes[j] := ColTypes[c];
      end
      else if Stmt.Columns[j].Expr is TSqlFuncCallNode then
      begin
        fn := TSqlFuncCallNode(Stmt.Columns[j].Expr);
        if fn.FuncName = 'COUNT' then OutTypes[j] := VCT_INT
        else if (fn.FuncName = 'SUM') or (fn.FuncName = 'AVG') then
          OutTypes[j] := VCT_FLOAT
        else if ((fn.FuncName = 'MIN') or (fn.FuncName = 'MAX')) and
                (fn.Arg is TSqlColumnRefNode) then
        begin
          cr := TSqlColumnRefNode(fn.Arg);
          c := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
          if (c >= 0) and (c <= High(ColTypes)) then OutTypes[j] := ColTypes[c];
        end;
      end;
    end;

    // H15: HAVING eslesmeyen gruplari duserir -> satirlar sikistirilir.
    SetLength(Res.Rows, Length(ctx.Groups));
    nRow := 0;
    for gi := 0 to High(ctx.Groups) do
    begin
      st := @ctx.Groups[gi];
      SetLength(Res.Rows[nRow], Stmt.Columns.Count);
      for j := 0 to Stmt.Columns.Count - 1 do
      begin
        if selGroup[j] >= 0 then
        begin
          if selGroup[j] <= High(st^.Key) then
            Res.Rows[nRow][j] := st^.Key[selGroup[j]]
          else
            Res.Rows[nRow][j] := '';
          Continue;
        end;
        Res.Rows[nRow][j] := AggPlanValue(st^.Plans[j], ctx.Ct);
      end;
      // H15: HAVING — kolon referanslari CIKTI kolonlarina cozulur (genel
      // yolla ayni); aggregate cagrilari FHavingOv uzerinden cozulur.
      if Stmt.HavingClause <> nil then
      begin
        SetLength(FHavingOv, Length(havNodes));
        for j := 0 to High(havNodes) do
        begin
          FHavingOv[j].N := havNodes[j];
          FHavingOv[j].V := AggPlanValue(
            st^.Plans[Stmt.Columns.Count + j], ctx.Ct);
        end;
        FHavingOvOn := True;
        try
          havingOk := EvalBool(Stmt.HavingClause, Res.Rows[nRow],
            Res.Fields, OutTypes);
        finally
          FHavingOvOn := False;
          SetLength(FHavingOv, 0);
        end;
        if not havingOk then Continue;
      end;
      Inc(nRow);
    end;
    SetLength(Res.Rows, nRow);
    Res.Affected := nRow;
    Res.Msg := 'OK';
    Result := True;
  finally
    ctx.Map.Free;
  end;
end;

{ ------------------------------------------------------------
  ExecSelect
  //---------------------------------------------------------- }
{ ------------------------------------------------------------
  AS OF (2026-10-06) - WAL gecmisinden tablo goruntusu.

  N = min(AsOfValue, WalRecordCount-1). Kurallar (hepsi WAL penceresine,
  yani son checkpoint'ten berine goredir):

    * pencerede (0..N) hic gormeyen + pencere sonrasi (N+1..) hic
      degismeyen anahtar -> mevcut hali aynen alinir (degismedi).
    * N'ye kadar son op PUT  -> o anki deger WAL'dedir, satir o an VAR.
    * N'ye kadar son op DEL  -> satir o an YOKTUR.
    * N sonrasi degisen, N'ye kadar PUT'u olmayan anahtar -> N'de yok
      sayilir (pencere sonrasi eklenmis kabul edilir; bkz. sinir notu).
    * pencere sonrasi silinmis, N'ye kadar PUT'u olan satir -> geri gelir.

  SINIRLAR (SQL.md "AS OF" bolumunde de yazilidir):
    - WAL, son checkpoint'ten beriyi tutar; checkpoint gecmise dokunur.
    - Pencere onceden gelip pencerede DEGISMIS bir satirin eski degeri
      WAL'de yoksa N'de yok sayilir (gorevli kod bunu ayirt edemez:
      "pencere sonrasi eklenmis" ile ayni gorunumdur).
    - Gecmis satir farkli kolon sayisina sahipse (ALTER TABLE) ecUnsupported.
  ------------------------------------------------------------ }
type
  TAsOfSt = record
    HasPut: Boolean;      // 0..N araliginda en az bir PUT goruldu
    LastWasDel: Boolean;  // 0..N araligindaki son op DEL
    Tid: Word;            // PUT satirinin tablo id'si
    Pk: string;
    Vals: TStrArray;      // son PUT'in cozulmus satiri
  end;

procedure TVSqlExecutor.BuildAsOfRows(Stmt: TSqlSelectStmt; Td: TTableDef;
  const ColNames: TStrArray; out Pks: TStrArray; out Rows: TStrMatrix);
var
  state: TDictionary<QWord, TAsOfSt>;  // anahtar -> N'ye kadarki son durum
  after: TDictionary<QWord, Byte>;     // N sonrasi degisen anahtarlar
  afterPk: TDictionary<string, QWord>; // (bizim tablo) PK -> anahtar
  present: TDictionary<string, Byte>;  // simdi var olan PK'lar
  curPks: TStrArray;
  curRows: TStrMatrix;
  cnt, n, i, outn: Integer;
  key, k: QWord;
  fl: Byte;
  val: TBytes;
  tid: Word;
  pk: string;
  vals: TStrArray;
  st: TAsOfSt;
  touched: Boolean;

  procedure ResetSt(var S: TAsOfSt);
  begin
    S.HasPut := False; S.LastWasDel := False;
    S.Tid := 0; S.Pk := ''; S.Vals := nil;
  end;

  procedure AppendRow(const APk: string; const AVals: TStrArray; AFromWal: Boolean);
  begin
    if AFromWal and (Length(AVals) <> Length(ColNames)) then
      raise EVDbException.CreateFmt(ecUnsupported,
        'AS OF: gecmis satir semasi (%d kolon) guncel semadan (%d kolon) farkli; ' +
        'ALTER TABLE sonrasi gecmis okunamaz (pk=%s)',
        [Length(AVals), Length(ColNames), APk]);
    SetLength(Pks, outn + 1);
    SetLength(Rows, outn + 1);
    Pks[outn] := APk;
    Rows[outn] := AVals;
    Inc(outn);
  end;

begin
  SetLength(Pks, 0);
  SetLength(Rows, 0);
  outn := 0;

  cnt := FT.Kv.WalRecordCount;
  if cnt <= 0 then
    raise EVDbException.Create(ecUnsupported,
      'AS OF: WAL gecmisi yok (WAL acik degil ya da son checkpoint gecmisi ' +
      'sildi); sorgulanacak an kayitli degil');
  if Stmt.AsOfValue >= QWord(cnt) then n := cnt - 1
  else n := Integer(Stmt.AsOfValue);

  state := TDictionary<QWord, TAsOfSt>.Create;
  after := TDictionary<QWord, Byte>.Create;
  afterPk := TDictionary<string, QWord>.Create;
  present := TDictionary<string, Byte>.Create;
  try
    // 1. pas: 0..N - her anahtarin N'ye kadarki son durumu.
    for i := 0 to n do
    begin
      if not FT.Kv.ReadWalEntry(i, key, fl, val) then Break;  // yirtik/kapali kuyruk
      if (fl and VDB_FLAG_DEL) <> 0 then
      begin
        if not state.TryGetValue(key, st) then ResetSt(st);
        st.LastWasDel := True;
        state.AddOrSetValue(key, st);
      end
      else if FT.DecodeRowDataPublic(val, tid, pk, vals) then
      begin
        // sema kaydi (VSCH1...) burada cozulemez -> atlanir; obur tablo
        // kayitlari durumda tutulur ama Tid kontroluyle elenir.
        if not state.TryGetValue(key, st) then ResetSt(st);
        st.HasPut := True;
        st.LastWasDel := False;
        st.Tid := tid;
        if tid = Td.TableId then begin st.Pk := pk; st.Vals := vals; end
        else begin st.Pk := ''; st.Vals := nil; end;
        state.AddOrSetValue(key, st);
      end;
    end;

    // 2. pas: N+1..son - pencere disinda degisen anahtarlar.
    for i := n + 1 to cnt - 1 do
    begin
      if not FT.Kv.ReadWalEntry(i, key, fl, val) then Break;
      after.AddOrSetValue(key, 0);
      if ((fl and VDB_FLAG_DEL) = 0) and
         FT.DecodeRowDataPublic(val, tid, pk, vals) and (tid = Td.TableId) then
        afterPk.AddOrSetValue(pk, key);
    end;

    // 3) Simdi var olan satirlar.
    FT.ScanRows(Stmt.FromTable, curPks, curRows);
    for i := 0 to High(curPks) do
      present.AddOrSetValue(curPks[i], 0);

    for i := 0 to High(curPks) do
    begin
      touched := afterPk.TryGetValue(curPks[i], key);
      if touched then
      begin
        // Pencere icinde degisti: N'deki deger yalnizca WAL'de olabilir.
        if state.TryGetValue(key, st) and st.HasPut and (not st.LastWasDel) and
           (st.Tid = Td.TableId) then
          AppendRow(st.Pk, st.Vals, True);
        // degilse N'de yok (pencere sonrasi eklenmis) -> gosterilmez.
      end
      else
        AppendRow(curPks[i], curRows[i], False);  // degismedi
    end;

    // 4) Pencere icinde silinmis, N'de var olan satirlar (simdi yoklar).
    for k in after.Keys do
    begin
      if not state.TryGetValue(k, st) then Continue;
      if (st.Tid <> Td.TableId) or (not st.HasPut) or st.LastWasDel then Continue;
      if present.ContainsKey(st.Pk) then Continue;  // (3) zaten islendi
      AppendRow(st.Pk, st.Vals, True);
    end;
  finally
    state.Free;
    after.Free;
    afterPk.Free;
    present.Free;
  end;
end;

procedure TVSqlExecutor.ExecRole(Stmt: TRoleStmt; out Res: TSqlResult);
{ R-18: CREATE ROLE ad [SUPERUSER] | DROP ROLE [IF EXISTS] ad }
var
  r: TRoleDef;
begin
  if Stmt.Make then
  begin
    FT.CreateRole(Stmt.RoleName, Stmt.Super);
  end
  else
  begin
    FT.DropRole(Stmt.RoleName);
  end;
  SetLength(Res.Fields, 1);
  Res.Fields[0] := 'role';
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], 1);
  if Stmt.Make then
    Res.Rows[0][0] := 'CREATE ROLE ' + Stmt.RoleName
  else
    Res.Rows[0][0] := 'DROP ROLE ' + Stmt.RoleName;
  Res.Affected := 0;
  Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecGrant(Stmt: TGrantStmt; out Res: TSqlResult);
{ R-18: GRANT/REVOKE privilege ON table TO/FROM role }
var
  msg: string;
begin
  if Stmt.Revoke then
    FT.RevokePriv(Stmt.TableName, Byte(Stmt.Priv), Stmt.RoleName)
  else
    FT.GrantPriv(Stmt.TableName, Byte(Stmt.Priv), Stmt.RoleName);
  SetLength(Res.Fields, 1);
  if Stmt.Revoke then
    Res.Fields[0] := 'revoke'
  else
    Res.Fields[0] := 'grant';
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], 1);
  if Stmt.Revoke then
    msg := 'REVOKE ' + FT.PrivName(Byte(Stmt.Priv)) + ' ON ' + Stmt.TableName + ' FROM ' + Stmt.RoleName
  else
    msg := 'GRANT ' + FT.PrivName(Byte(Stmt.Priv)) + ' ON ' + Stmt.TableName + ' TO ' + Stmt.RoleName;
  Res.Rows[0][0] := msg;
  Res.Affected := 0;
  Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecPolicy(Stmt: TPolicyStmt; out Res: TSqlResult);
{ R-19: CREATE/DROP POLICY }
begin
  if Stmt.Make then
    FT.CreatePolicy(Stmt.TableName, Stmt.PolicyName, Byte(Stmt.Cmd),
      Stmt.UsingText, Stmt.CheckText)
  else
    FT.DropPolicy(Stmt.TableName, Stmt.PolicyName);
  SetLength(Res.Fields, 1);
  Res.Fields[0] := 'policy';
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], 1);
  if Stmt.Make then
    Res.Rows[0][0] := 'CREATE POLICY ' + Stmt.PolicyName + ' ON ' + Stmt.TableName
  else
    Res.Rows[0][0] := 'DROP POLICY ' + Stmt.PolicyName + ' ON ' + Stmt.TableName;
  Res.Affected := 0;
  Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecSetRole(Stmt: TSetRoleStmt; out Res: TSqlResult);
{ R-18: SET ROLE rol | NONE }
begin
  FT.SetCurrentRole(Stmt.RoleName);
  SetLength(Res.Fields, 1);
  Res.Fields[0] := 'role';
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], 1);
  Res.Rows[0][0] := Stmt.RoleName;
  Res.Affected := 0;
  Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecSetConstraints(Stmt: TSqlSetConstraintsStmt;
  out Res: TSqlResult);
{ R-11: `SET CONSTRAINTS ALL DEFERRED | IMMEDIATE`

  DEFERRED   -> FK denetimleri COMMIT'e kadar ertelenir. Yalniz tabloda
                DEFERRABLE tanimli FK varsa erteleme gerceklesir; aksi
                halde cumle sessizce gecersizdir (bir uyari yerine),
                PostgreSQL ile ayni davranis.
  IMMEDIATE  -> birikmis ertelenen denetimler ANINDA yurutulur;
                ihlal varsa hata firlatilir ve transaction ACIK kalir
                (kullanici ROLLBACK yazabilir). }
begin
  FT.SetDeferred(Stmt.Deferred);
  SetLength(Res.Fields, 1);
  Res.Fields[0] := 'constraints';
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], 1);
  if Stmt.Deferred then
    Res.Rows[0][0] := 'DEFERRED'
  else
    Res.Rows[0][0] := 'IMMEDIATE';
  Res.Affected := 0;
  Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecSetIsolation(Stmt: TSqlSetIsolationStmt;
  out Res: TSqlResult);
// F-40: oturum yalitim seviyesi. READ COMMITTED her cumle basinda
// gorunurluk penceresini ilerletir; digerleri batch-basi snapshot kullanir.
begin
  FIsolation := Stmt.Level;
  SetLength(Res.Fields, 1);
  Res.Fields[0] := 'isolation';
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], 1);
  case Stmt.Level of
    ilReadUncommitted: Res.Rows[0][0] := 'READ UNCOMMITTED';
    ilReadCommitted:   Res.Rows[0][0] := 'READ COMMITTED';
    ilRepeatableRead:  Res.Rows[0][0] := 'REPEATABLE READ';
    ilSerializable:    Res.Rows[0][0] := 'SERIALIZABLE';
  end;
  Res.Affected := 0;
  Res.Msg := 'OK';
end;

procedure TVSqlExecutor.LockSelectRows(Stmt: TSqlSelectStmt);
// F-41: basit tek-tablo SELECT'te WHERE'e uyan satirlari FOR UPDATE ile
// kilitler. JOIN/VIEW/SET OP/CTE kapsam disidir. Kilitler tx sonunda
// (COMMIT/ROLLBACK) birakilir. LIMIT'ten ONCE kilitlenir: ust kume
// kilitlenmesi guvenlidir, eksik kilitlenmeden daha iyidir.
var
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  cn: TStrArray;
  ct: TByteArray;
  i: Integer;
begin
  if not FT.Kv.InBatch then
    raise EVDbException.Create(ecTransactionState,
      'SELECT ... FOR UPDATE yalniz acik islem (BEGIN) icinde kullanilabilir');
  if (Stmt.FromTable = '') or Stmt.HasJoin or
     ((Stmt.SetOp <> sokNone) and (Stmt.RightSelect <> nil)) or
     (Stmt.WithQueries.Count > 0) then
    raise EVDbException.Create(ecUnsupported,
      'SELECT ... FOR UPDATE yalniz tek tablo, JOIN/CTE/SET OP olmadan desteklenir');
  if not FT.TableExists(Stmt.FromTable) then
    raise EVDbException.Create(ecUnsupported,
      'SELECT ... FOR UPDATE yalniz temel tablo uzerinde desteklenir: ' + Stmt.FromTable);
  td := FT.GetTable(Stmt.FromTable);
  BuildColInfo(td, cn, ct);
  FT.ScanRows(td.Name, pks, rows);
  for i := 0 to High(rows) do
    if RowMatches(Stmt.WhereClause, rows[i], cn, ct) then
      FT.LockRow(FSessionId, td.Name, pks[i]);
end;

procedure TVSqlExecutor.MergeSetOpRows(Stmt: TSqlSelectStmt; var Rows: TStrMatrix;
  const Cols: TStrArray);
{ UNION [ALL] / EXCEPT / INTERSECT birlestirmesi.
  AYRI metoda cikarildi (R-10): ExecSelect'in FROM'suz yolu da
  birlestirme kurabilir (`SELECT 1 UNION ALL SELECT 2`) ve o yol
  onceki kodda SetOp bolumune hic ulasmadan Exit cikiyordu. }
var
  rightRes: TSqlResult;
  merged: TStrMatrix;
  seenSet, rightSet: TDictionary<string, Integer>;
  i, j, n: Integer;
  rowKey: string;
begin
  ExecSelect(Stmt.RightSelect, rightRes);
  // F1-11: UNION/EXCEPT/INTERSECT sutun sayisi esit olmali
  if Length(Cols) <> Length(rightRes.Fields) then
    raise EVDbException.Create(ecSyntaxError,
      'UNION/EXCEPT/INTERSECT: sutun sayilari esit olmali (sol=' +
      IntToStr(Length(Cols)) + ', sag=' + IntToStr(Length(rightRes.Fields)) + ')');
  case Stmt.SetOp of
    sokUnion, sokUnionAll:
      begin
        SetLength(merged, Length(Rows) + Length(rightRes.Rows));
        if Length(merged) > VDB_MAX_RESULT_ROWS then
          raise EVDbException.CreateFmt(ecLimit,
            'UNION/UNION ALL sonucu cok buyuk (%d > %d satir)',
            [Length(merged), VDB_MAX_RESULT_ROWS]);
        for i := 0 to High(Rows) do merged[i] := Rows[i];
        for i := 0 to High(rightRes.Rows) do merged[Length(Rows) + i] := rightRes.Rows[i];
        if Stmt.SetOp = sokUnion then
        begin
          // F2-18: O(N^2) icice tarama -> O(1) hash kova
          seenSet := TDictionary<string, Integer>.Create;
          try
            n := 0;
            for i := 0 to High(merged) do
            begin
              rowKey := RowEncodeKey(merged[i]);
              if seenSet.ContainsKey(rowKey) then Continue;
              seenSet.Add(rowKey, 0);
              merged[n] := merged[i];
              Inc(n);
            end;
            SetLength(merged, n);
          finally seenSet.Free; end;
        end;
        Rows := merged;
      end;
    sokExcept:
      begin
        // F2-18: sag taraf hash kovaya -> O(1) sorgu
        rightSet := TDictionary<string, Integer>.Create;
        try
          for j := 0 to High(rightRes.Rows) do
            rightSet.AddOrSetValue(RowEncodeKey(rightRes.Rows[j]), 0);
          n := 0; SetLength(merged, Length(Rows));
          for i := 0 to High(Rows) do
            if not rightSet.ContainsKey(RowEncodeKey(Rows[i])) then
            begin merged[n] := Rows[i]; Inc(n); end;
        finally rightSet.Free; end;
        SetLength(merged, n); Rows := merged;
      end;
    sokIntersect:
      begin
        // F2-18: ayni sekilde hash
        rightSet := TDictionary<string, Integer>.Create;
        try
          for j := 0 to High(rightRes.Rows) do
            rightSet.AddOrSetValue(RowEncodeKey(rightRes.Rows[j]), 0);
          n := 0; SetLength(merged, Length(Rows));
          for i := 0 to High(Rows) do
            if rightSet.ContainsKey(RowEncodeKey(Rows[i])) then
            begin merged[n] := Rows[i]; Inc(n); end;
        finally rightSet.Free; end;
        SetLength(merged, n); Rows := merged;
      end;
  end;
end;

{ ------------------------------------------------------------
  H1 (2026-10-18): TryStreamSelect — akisli filtered SELECT
  ------------------------------------------------------------
  Indekssiz tek-tablo, ORDER BY'siz, LIMIT'li SELECT'te kayitlar ham
  akistan okunur; LIMIT kadar eslesen satir bulununca tarama DURUR.
  Genel yol TUM satirlari cozup (string matrisi) sonra LIMIT uyguluyordu;
  "SELECT ... LIMIT 50" 100.000 satirlik tabloda ~580 ms yerine ~1 ms.
  Sekil/guvenlik uymazsa False doner ve genel yol AYNEN calisir. }

type
  TStreamSelCtx = record
    Exec: TVSqlExecutor;
    TableId: Word;
    TableName: string;
    ColCnt: Integer;
    FType: TByteArray;
    FOff, FLen: TIntArray;
    ColNames: TStrArray;
    ColTypes: TByteArray;
    Where: TSqlExprNode;
    Columns: TList<TSelectColumnItem>;
    Offset, Limit: Integer;   // Limit = -1 ise sinir yok
    Seen, Emitted: Integer;
    HasRaw: Boolean;
    RawConds: array of TRawCond;
    RawTree: TRawTree;
    RawTreeRoot: Integer;
    // H3: zone map insasi (yalnizca gecersiz harita varken acilir)
    ZoneOn: Boolean;
    ZoneMap: TVDbZoneMap;
    ZoneCols: array of Integer;
    ZoneIsFloat: array of Boolean;
    CurBucket: Integer;
    ZoneLastBucket: Integer;
    OutRows: TStrMatrix;
    Failed: Boolean;
  end;
  PStreamSelCtx = ^TStreamSelCtx;

  { H16: tek kolonlu akisli DISTINCT baglami. Satir matrisi yerine yalniz
    secilen kolonun degeri ve tekillestirme sozlugu tutulur. }
  TStreamDistinctCtx = record
    Exec: TVSqlExecutor;
    TableId: Word;
    HashPrefix: QWord;
    ColCnt: Integer;
    FType: TByteArray;
    FOff, FLen: TIntArray;
    ColNames: TStrArray;
    ColTypes: TByteArray;
    Where: TSqlExprNode;
    RawTree: TRawTree;
    RawTreeRoot: Integer;
    ColIdx: Integer;
    NeedFull: Boolean;
    Seen: Int64;
    Failed: Boolean;
    Overflow: Boolean;
    Keys: TDictionary<string, Integer>;
    Vals: TStrArray;
    N, Cap: Integer;
  end;
  PStreamDistinctCtx = ^TStreamDistinctCtx;

  { H12: ORDER BY ... LIMIT icin akisli top-N. Tum satirlar string
    matrisine cevrilmez; yalniz siralama anahtari + PK tutulur. }
  TStreamOrderRec = record
    Pk: string;
    Seq: Int64;
    IsNull: Boolean;
    I: Int64;
    F: Double;
    S: string;
  end;

  TStreamOrderCtx = record
    Exec: TVSqlExecutor;
    TableId: Word;
    TableName: string;
    HashPrefix: QWord;
    ColCnt: Integer;
    FType: TByteArray;
    FOff, FLen: TIntArray;
    ColNames: TStrArray;
    ColTypes: TByteArray;
    Where: TSqlExprNode;
    NeedFull: Boolean;
    RawConds: TRawCondArray;
    RawTree: TRawTree;
    RawTreeRoot: Integer;
    SortCol: Integer;
    SortType: Byte;
    Desc: Boolean;
    NullsPos: Integer;
    K: Integer;
    N: Integer;
    Heap: array of TStreamOrderRec;
    Seen: Int64;
    Failed: Boolean;
  end;
  PStreamOrderCtx = ^TStreamOrderCtx;

  { H12c: cok kolonlu akisli top-N. Her satir icin SortCnt kadar anahtar
    saklanir; karsilastirma kolon kolon, kendi yonu ve NULLS konumuyla
    yapilir. Arrays only for accepted heap candidates. }
  TStreamOrderKey = record
    IsNull: Boolean;
    I: Int64;
    F: Double;
    S: string;
  end;

  TStreamOrderMultiRec = record
    Pk: string;
    Seq: Int64;
    Keys: array of TStreamOrderKey;
  end;

  TStreamOrderMultiCtx = record
    Exec: TVSqlExecutor;
    TableId: Word;
    TableName: string;
    HashPrefix: QWord;
    ColCnt: Integer;
    FType: TByteArray;
    FOff, FLen: TIntArray;
    ColNames: TStrArray;
    ColTypes: TByteArray;
    Where: TSqlExprNode;
    NeedFull: Boolean;
    RawConds: TRawCondArray;
    RawTree: TRawTree;
    RawTreeRoot: Integer;
    SortCols: TIntArray;
    SortTypes: TByteArray;
    Descs: array of Boolean;
    NullsPos: TIntArray;
    SortCnt: Integer;
    Scratch: TStreamOrderMultiRec;
    K: Integer;
    N: Integer;
    Heap: array of TStreamOrderMultiRec;
    Seen: Int64;
    Failed: Boolean;
  end;
  PStreamOrderMultiCtx = ^TStreamOrderMultiCtx;

function VdbStreamOrderCmp(const A, B: TStreamOrderRec;
  C: PStreamOrderCtx): Integer;
var
  n: Integer;
begin
  if A.IsNull or B.IsNull then
  begin
    if A.IsNull and B.IsNull then
    begin
      if A.Seq < B.Seq then Exit(-1);
      if A.Seq > B.Seq then Exit(1);
      Exit(0);
    end;
    n := C^.NullsPos;
    if n < 0 then
    begin
      if A.IsNull then Result := -1 else Result := 1;
      if C^.Desc then Result := -Result;
    end
    else if A.IsNull then
    begin
      if n = 0 then Result := -1 else Result := 1;
    end
    else
    begin
      if n = 0 then Result := 1 else Result := -1;
    end;
    Exit;
  end;
  case C^.SortType of
    VCT_INT, VCT_BOOL:
      begin
        if A.I < B.I then Result := -1
        else if A.I > B.I then Result := 1
        else Result := 0;
      end;
    VCT_FLOAT:
      begin
        if A.F < B.F then Result := -1
        else if A.F > B.F then Result := 1
        else Result := 0;
      end;
  else
    Result := CompareStr(A.S, B.S);
  end;
  if (Result <> 0) and C^.Desc then Result := -Result;
  if Result = 0 then
  begin
    if A.Seq < B.Seq then Result := -1
    else if A.Seq > B.Seq then Result := 1;
  end;
end;

procedure VdbStreamOrderHeapAdd(C: PStreamOrderCtx; const R: TStreamOrderRec);
var
  child, parent: Integer;
  tmp: TStreamOrderRec;
begin
  if C^.N < C^.K then
  begin
    C^.Heap[C^.N] := R;
    Inc(C^.N);
    child := C^.N - 1;
    while child > 0 do
    begin
      parent := (child - 1) div 2;
      if VdbStreamOrderCmp(C^.Heap[parent], C^.Heap[child], C) >= 0 then Break;
      tmp := C^.Heap[parent]; C^.Heap[parent] := C^.Heap[child];
      C^.Heap[child] := tmp;
      child := parent;
    end;
  end
  else if VdbStreamOrderCmp(R, C^.Heap[0], C) < 0 then
  begin
    C^.Heap[0] := R;
    parent := 0;
    while True do
    begin
      child := parent * 2 + 1;
      if child >= C^.N then Break;
      if (child + 1 < C^.N) and
         (VdbStreamOrderCmp(C^.Heap[child + 1], C^.Heap[child], C) > 0) then
        Inc(child);
      if VdbStreamOrderCmp(C^.Heap[parent], C^.Heap[child], C) >= 0 then Break;
      tmp := C^.Heap[parent]; C^.Heap[parent] := C^.Heap[child];
      C^.Heap[child] := tmp;
      parent := child;
    end;
  end;
end;

function VdbStreamOrderWouldAccept(C: PStreamOrderCtx;
  const R: TStreamOrderRec): Boolean;
begin
  if C^.N < C^.K then Exit(True);
  Result := VdbStreamOrderCmp(R, C^.Heap[0], C) < 0;
end;

function VdbRawPkFromBuf(B: PByte; Len: Integer): string;
var
  n: Integer;
  s: RawByteString;
begin
  Result := '';
  if (B = nil) or (Len < 4) then Exit;
  n := B[2] or (Integer(B[3]) shl 8);
  if (n < 0) or (4 + n > Len) then Exit;
  SetString(s, PAnsiChar(NativeUInt(B) + 4), n);
  Result := UTF8Decode(s);
end;

procedure VdbStreamOrderSort(C: PStreamOrderCtx);
var
  stackL, stackH: array[0..63] of Integer;
  sp, l, h, i, j: Integer;
  p, t: TStreamOrderRec;
begin
  sp := 0;
  if C^.N > 1 then
  begin
    stackL[0] := 0; stackH[0] := C^.N - 1; sp := 1;
  end;
  while sp > 0 do
  begin
    Dec(sp);
    l := stackL[sp]; h := stackH[sp];
    while l < h do
    begin
      p := C^.Heap[(l + h) div 2];
      i := l; j := h;
      repeat
        while (i < h) and (VdbStreamOrderCmp(C^.Heap[i], p, C) < 0) do Inc(i);
        while (j > l) and (VdbStreamOrderCmp(C^.Heap[j], p, C) > 0) do Dec(j);
        if i <= j then
        begin
          t := C^.Heap[i]; C^.Heap[i] := C^.Heap[j]; C^.Heap[j] := t;
          Inc(i); Dec(j);
        end;
      until i > j;
      if (j - l) < (h - i) then
      begin
        if i < h then
        begin
          if sp > High(stackL) then Exit;
          stackL[sp] := i; stackH[sp] := h; Inc(sp);
        end;
        h := j;
      end
      else
      begin
        if l < j then
        begin
          if sp > High(stackL) then Exit;
          stackL[sp] := l; stackH[sp] := j; Inc(sp);
        end;
        l := i;
      end;
    end;
  end;
end;

function VdbStreamOrderCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
var
  C: PStreamOrderCtx;
  tid: Word;
  keyHash: QWord;
  vals: TStrArray;
  R: TStreamOrderRec;
  iv: Int64;
  fv: Double;
  whereOK: Boolean;
begin
  C := User;
  Result := True;
  if Key = VDB_SCHEMA_KEY then Exit;
  if not VDbPeekRawRowKeyHashTo(Buf, Len, C^.ColCnt, tid, C^.HashPrefix,
       keyHash, C^.ColCnt - 1, C^.FType, C^.FOff, C^.FLen) then
  begin
    C^.Failed := True; Exit(False);
  end;
  if tid <> C^.TableId then Exit;
  if keyHash <> Key then
  begin
    C^.Failed := True; Exit(False);
  end;
  // Dinamik/uyumsuz alan tipi varsa ham anahtar yolu guvenli degil.
  if C^.FType[C^.SortCol] <> C^.SortType then
  begin
    C^.Failed := True; Exit(False);
  end;
  Inc(C^.Seen);
  // H21: tam boolean agaci TRUE ise RowMatches'a hic gerek yok.
  whereOK := False;
  if C^.RawTreeRoot >= 0 then
  begin
    case VdbEvalRawTree(C^.RawTree, C^.RawTreeRoot, Buf, C^.FType,
      C^.FOff, C^.FLen) of
      rvFalse, rvUnknown: Exit;
      rvTrue: whereOK := True;
    end;
  end;
  if not whereOK then
  begin
    if (Length(C^.RawConds) > 0) and
       (not VdbStreamSelRawPass(C^.RawConds, Buf, C^.FType, C^.FOff, C^.FLen)) then
      Exit;
    if C^.NeedFull then
    begin
      VDbRowFromOffsetsP(Buf, C^.ColCnt, C^.FType, C^.FOff, C^.FLen, vals);
      if (C^.Where <> nil) and
         (not C^.Exec.RowMatches(C^.Where, vals, C^.ColNames, C^.ColTypes)) then
        Exit;
    end;
  end;
  R.Pk := '';
  R.Seq := C^.Seen;
  R.IsNull := (C^.FOff[C^.SortCol] < 0) or (C^.FLen[C^.SortCol] = 0);
  R.I := 0; R.F := 0; R.S := '';
  if not R.IsNull then
  begin
    case C^.SortType of
      VCT_INT:
        begin Move(Buf[C^.FOff[C^.SortCol]], iv, 8); R.I := iv; end;
      VCT_BOOL:
        R.I := Ord(Buf[C^.FOff[C^.SortCol]] <> 0);
      VCT_FLOAT:
        begin Move(Buf[C^.FOff[C^.SortCol]], fv, 8); R.F := fv; end;
    else
      begin
        R.S := VDbColFromOffsetsP(Buf, C^.ColCnt, C^.SortCol,
                                  C^.FType, C^.FOff, C^.FLen);
        if R.S = '' then R.IsNull := True;
      end;
    end;
  end;
  // PK string'ini yalnizca heap'e girecek adaylar icin coz.
  if VdbStreamOrderWouldAccept(C, R) then
  begin
    R.Pk := VdbRawPkFromBuf(Buf, Len);
    VdbStreamOrderHeapAdd(C, R);
  end;
end;

{ H12c: cok kolonlu top-N karsilastirmasi. Tek kolonlu yolla ayni NULLS
  kurallarini uygular; esitlikte fiziksel okuma sirasi (Seq) bagintiyi
  belirler. }
function VdbStreamOrderMultiCmp(const A, B: TStreamOrderMultiRec;
  C: PStreamOrderMultiCtx): Integer;
var
  k, np: Integer;
  aNull, bNull: Boolean;
begin
  for k := 0 to C^.SortCnt - 1 do
  begin
    aNull := A.Keys[k].IsNull;
    bNull := B.Keys[k].IsNull;
    if aNull or bNull then
    begin
      if aNull and bNull then Continue;   // ikisi de NULL -> sonraki anahtar
      np := C^.NullsPos[k];
      if np < 0 then
      begin
        if aNull then Result := -1 else Result := 1;
        if C^.Descs[k] then Result := -Result;
      end
      else if aNull then
      begin
        if np = 0 then Result := -1 else Result := 1;
      end
      else
      begin
        if np = 0 then Result := 1 else Result := -1;
      end;
      Exit;
    end;
    case C^.SortTypes[k] of
      VCT_INT, VCT_BOOL:
        begin
          if A.Keys[k].I < B.Keys[k].I then Result := -1
          else if A.Keys[k].I > B.Keys[k].I then Result := 1
          else Result := 0;
        end;
      VCT_FLOAT:
        begin
          if A.Keys[k].F < B.Keys[k].F then Result := -1
          else if A.Keys[k].F > B.Keys[k].F then Result := 1
          else Result := 0;
        end;
    else
      Result := CompareStr(A.Keys[k].S, B.Keys[k].S);
    end;
    if Result <> 0 then
    begin
      if C^.Descs[k] then Result := -Result;
      Exit;
    end;
  end;
  if A.Seq < B.Seq then Result := -1
  else if A.Seq > B.Seq then Result := 1
  else Result := 0;
end;

procedure VdbStreamOrderMultiHeapAdd(C: PStreamOrderMultiCtx;
  const R: TStreamOrderMultiRec);
var
  child, parent: Integer;
  tmp: TStreamOrderMultiRec;
begin
  if C^.N < C^.K then
  begin
    C^.Heap[C^.N] := R;
    Inc(C^.N);
    child := C^.N - 1;
    while child > 0 do
    begin
      parent := (child - 1) div 2;
      if VdbStreamOrderMultiCmp(C^.Heap[parent], C^.Heap[child], C) >= 0 then Break;
      tmp := C^.Heap[parent]; C^.Heap[parent] := C^.Heap[child];
      C^.Heap[child] := tmp;
      child := parent;
    end;
  end
  else if VdbStreamOrderMultiCmp(R, C^.Heap[0], C) < 0 then
  begin
    C^.Heap[0] := R;
    parent := 0;
    while True do
    begin
      child := parent * 2 + 1;
      if child >= C^.N then Break;
      if (child + 1 < C^.N) and
         (VdbStreamOrderMultiCmp(C^.Heap[child + 1], C^.Heap[child], C) > 0) then
        Inc(child);
      if VdbStreamOrderMultiCmp(C^.Heap[parent], C^.Heap[child], C) >= 0 then Break;
      tmp := C^.Heap[parent]; C^.Heap[parent] := C^.Heap[child];
      C^.Heap[child] := tmp;
      parent := child;
    end;
  end;
end;

function VdbStreamOrderMultiWouldAccept(C: PStreamOrderMultiCtx;
  const R: TStreamOrderMultiRec): Boolean;
begin
  if C^.N < C^.K then Exit(True);
  Result := VdbStreamOrderMultiCmp(R, C^.Heap[0], C) < 0;
end;

procedure VdbStreamOrderMultiSort(C: PStreamOrderMultiCtx);
var
  stackL, stackH: array[0..63] of Integer;
  sp, l, h, i, j: Integer;
  p, t: TStreamOrderMultiRec;
begin
  sp := 0;
  if C^.N > 1 then
  begin
    stackL[0] := 0; stackH[0] := C^.N - 1; sp := 1;
  end;
  while sp > 0 do
  begin
    Dec(sp);
    l := stackL[sp]; h := stackH[sp];
    while l < h do
    begin
      p := C^.Heap[(l + h) div 2];
      i := l; j := h;
      repeat
        while (i < h) and (VdbStreamOrderMultiCmp(C^.Heap[i], p, C) < 0) do Inc(i);
        while (j > l) and (VdbStreamOrderMultiCmp(C^.Heap[j], p, C) > 0) do Dec(j);
        if i <= j then
        begin
          t := C^.Heap[i]; C^.Heap[i] := C^.Heap[j]; C^.Heap[j] := t;
          Inc(i); Dec(j);
        end;
      until i > j;
      if (j - l) < (h - i) then
      begin
        if i < h then
        begin
          if sp > High(stackL) then Exit;
          stackL[sp] := i; stackH[sp] := h; Inc(sp);
        end;
        h := j;
      end
      else
      begin
        if l < j then
        begin
          if sp > High(stackL) then Exit;
          stackL[sp] := l; stackH[sp] := j; Inc(sp);
        end;
        l := i;
      end;
    end;
  end;
end;

function VdbStreamOrderMultiCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
var
  C: PStreamOrderMultiCtx;
  tid: Word;
  keyHash: QWord;
  vals: TStrArray;
  R: TStreamOrderMultiRec;
  j, ci: Integer;
  iv: Int64;
  fv: Double;
  whereOK: Boolean;
begin
  C := User;
  Result := True;
  if Key = VDB_SCHEMA_KEY then Exit;
  if not VDbPeekRawRowKeyHashTo(Buf, Len, C^.ColCnt, tid, C^.HashPrefix,
       keyHash, C^.ColCnt - 1, C^.FType, C^.FOff, C^.FLen) then
  begin
    C^.Failed := True; Exit(False);
  end;
  if tid <> C^.TableId then Exit;
  if keyHash <> Key then
  begin
    C^.Failed := True; Exit(False);
  end;
  // Tum siralama kolonlarinin ham tipi semayla uyusmali.
  for j := 0 to C^.SortCnt - 1 do
    if C^.FType[C^.SortCols[j]] <> C^.SortTypes[j] then
    begin
      C^.Failed := True; Exit(False);
    end;
  Inc(C^.Seen);
  // H21: tam boolean agaci TRUE ise RowMatches'a hic gerek yok.
  whereOK := False;
  if C^.RawTreeRoot >= 0 then
  begin
    case VdbEvalRawTree(C^.RawTree, C^.RawTreeRoot, Buf, C^.FType,
      C^.FOff, C^.FLen) of
      rvFalse, rvUnknown: Exit;
      rvTrue: whereOK := True;
    end;
  end;
  if not whereOK then
  begin
    if (Length(C^.RawConds) > 0) and
       (not VdbStreamSelRawPass(C^.RawConds, Buf, C^.FType, C^.FOff, C^.FLen)) then
      Exit;
    if C^.NeedFull then
    begin
      VDbRowFromOffsetsP(Buf, C^.ColCnt, C^.FType, C^.FOff, C^.FLen, vals);
      if (C^.Where <> nil) and
         (not C^.Exec.RowMatches(C^.Where, vals, C^.ColNames, C^.ColTypes)) then
        Exit;
    end;
  end;

  R.Seq := C^.Seen;
  for j := 0 to C^.SortCnt - 1 do
  begin
    ci := C^.SortCols[j];
    C^.Scratch.Keys[j].IsNull := (C^.FOff[ci] < 0) or (C^.FLen[ci] = 0);
    C^.Scratch.Keys[j].I := 0;
    C^.Scratch.Keys[j].F := 0;
    C^.Scratch.Keys[j].S := '';
    if not C^.Scratch.Keys[j].IsNull then
    begin
      case C^.SortTypes[j] of
        VCT_INT:
          begin Move(Buf[C^.FOff[ci]], iv, 8); C^.Scratch.Keys[j].I := iv; end;
        VCT_BOOL:
          C^.Scratch.Keys[j].I := Ord(Buf[C^.FOff[ci]] <> 0);
        VCT_FLOAT:
          begin Move(Buf[C^.FOff[ci]], fv, 8); C^.Scratch.Keys[j].F := fv; end;
      else
        begin
          C^.Scratch.Keys[j].S := VDbColFromOffsetsP(Buf, C^.ColCnt, ci,
            C^.FType, C^.FOff, C^.FLen);
          if C^.Scratch.Keys[j].S = '' then C^.Scratch.Keys[j].IsNull := True;
        end;
      end;
    end;
  end;
  // Anahtar dizisini yalniz heap'e girecek adaylar icin ayir.
  if VdbStreamOrderMultiWouldAccept(C, C^.Scratch) then
  begin
    SetLength(R.Keys, C^.SortCnt);
    for j := 0 to C^.SortCnt - 1 do
      R.Keys[j] := C^.Scratch.Keys[j];
    R.Pk := VdbRawPkFromBuf(Buf, Len);
    VdbStreamOrderMultiHeapAdd(C, R);
  end;
end;

{ H12/H13: WHERE'in AND zincirinden guvenli, gerekli ama yeterli olmayan
  ham kosular cikarir. Nihai dogrulama her zaman RowMatches'tir. }
procedure VdbStreamOrderAddRawCond(var Conds: TRawCondArray;
  Exec: TVSqlExecutor; E: TSqlExprNode; const td: TTableDef;
  const ColNames: TStrArray; const ColTypes: TByteArray);
var
  b: TSqlBinaryOpNode;
  c: TRawCond;
  cc: TSqlColumnRefNode;
  lit: TSqlLiteralNode;
  op: TSqlBinaryOp;
  ci: Integer;
  swap: Boolean;
begin
  if E = nil then Exit;
  if (E is TSqlBinaryOpNode) and (TSqlBinaryOpNode(E).Op = sboAnd) then
  begin
    VdbStreamOrderAddRawCond(Conds, Exec, TSqlBinaryOpNode(E).Left, td, ColNames, ColTypes);
    VdbStreamOrderAddRawCond(Conds, Exec, TSqlBinaryOpNode(E).Right, td, ColNames, ColTypes);
    Exit;
  end;
  if not (E is TSqlBinaryOpNode) then Exit;
  b := TSqlBinaryOpNode(E);
  op := b.Op;
  if op in [sboLike, sboILike] then
  begin
    // H19: LIKE/ILIKE yalniz "kolon OP literal" biciminde ve ASCII
    // desenle ham baytlara uygulanir. ILIKE deseni Turkce-duyarli
    // kucuk harfe cevrilir (VDbTrLower ile ayni).
    if not ((b.Left is TSqlColumnRefNode) and
            (b.Right is TSqlLiteralNode)) then Exit;
    cc := TSqlColumnRefNode(b.Left);
    lit := TSqlLiteralNode(b.Right);
    ci := Exec.FindColIdx(cc.ColumnName, cc.TableQualifier, ColNames);
    if (ci < 0) or (ci > High(td.Cols)) then Exit;
    if td.Cols[ci].Encrypted or (td.Cols[ci].Collate <> '') then Exit;
    if ColTypes[ci] <> VCT_STR then Exit;
    if lit.LitType <> sltString then Exit;
    if not VdbStrPureAscii(lit.StrVal) then Exit;
    FillChar(c, SizeOf(c), 0);
    c.Col := ci;
    c.Op := op;
    c.IsIn := False;
    c.InIsFloat := False;
    c.IsLike := op = sboLike;
    c.IsILike := op = sboILike;
    if c.IsILike then c.S := VDbTrLower(lit.StrVal)
    else c.S := lit.StrVal;
    SetLength(Conds, Length(Conds) + 1);
    Conds[High(Conds)] := c;
    Exit;
  end;
  if not (op in [sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte]) then Exit;
  swap := False;
  if b.Left is TSqlColumnRefNode then
  begin
    cc := TSqlColumnRefNode(b.Left);
    if not (b.Right is TSqlLiteralNode) then Exit;
    lit := TSqlLiteralNode(b.Right);
  end
  else if b.Right is TSqlColumnRefNode then
  begin
    cc := TSqlColumnRefNode(b.Right);
    if not (b.Left is TSqlLiteralNode) then Exit;
    lit := TSqlLiteralNode(b.Left);
    swap := True;
  end
  else Exit;
  ci := Exec.FindColIdx(cc.ColumnName, cc.TableQualifier, ColNames);
  if (ci < 0) or (ci > High(td.Cols)) then Exit;
  if td.Cols[ci].Encrypted or (td.Cols[ci].Collate <> '') then Exit;
  if swap then
    case op of
      sboLt: op := sboGt;
      sboLte: op := sboGte;
      sboGt: op := sboLt;
      sboGte: op := sboLte;
    end;
  FillChar(c, SizeOf(c), 0);
  c.Col := ci;
  c.Op := op;
  c.IsIn := False;
  c.InIsFloat := False;
  if ColTypes[ci] = VCT_INT then
  begin
    if lit.LitType <> sltInt then Exit;
    c.IsFloat := False; c.IsText := False;
    c.I := lit.IntVal;
  end
  else if ColTypes[ci] = VCT_FLOAT then
  begin
    if lit.LitType = sltInt then c.F := lit.IntVal
    else if lit.LitType = sltFloat then c.F := lit.FloatVal
    else Exit;
    c.IsFloat := True; c.IsText := False;
  end
  else if ColTypes[ci] = VCT_STR then
  begin
    if not (op in [sboEq, sboNeq]) then Exit;
    if lit.LitType <> sltString then Exit;
    if not VdbStrPureAscii(lit.StrVal) then Exit;
    c.IsFloat := False; c.IsText := True;
    c.S := lit.StrVal;
  end
  else Exit;
  SetLength(Conds, Length(Conds) + 1);
  Conds[High(Conds)] := c;
end;

{ H1b: kayittaki ham baytlar saf-ASCII mi? (>=128 varsa ham bayt kiyasi
  ile cozulmus-string kiyasi farkli olabilir; o durumda filtreleme yapmayiz.) }
function VdbBytesAscii(P: PByte; L: Integer): Boolean;
var i: Integer;
begin
  for i := 0 to L - 1 do
    if P[i] >= 128 then Exit(False);
  Result := True;
end;

{ H1b: literal saf-ASCII mi? (yalniz bu durumda ham bayt kiyasi guvenli) }
function VdbStrPureAscii(const S: string): Boolean;
var i: Integer;
begin
  for i := 1 to Length(S) do
    if S[i] >= #128 then Exit(False);
  Result := True;
end;

{ Ham baytlar ile saf-ASCII literal birebir mi? }
function VdbBytesEqP(P: PByte; L: Integer; const S: string): Boolean;
var i: Integer;
begin
  if L <> Length(S) then Exit(False);
  for i := 1 to L do
    if P[i - 1] <> Byte(S[i]) then Exit(False);
  Result := True;
end;

{ H19: VDbLikeMatch'in ham-bayt esdegeri. '%' ve '_' bayt bazinda
  calisir; VDbLikeMatch ile birebir ayni geri-izleme kurali. }
function VdbBytesLikeMatch(P: PByte; L: Integer; const Pat: string): Boolean;
var
  ti, pi, star, mark: Integer;
begin
  ti := 0; pi := 1; star := 0; mark := 0;
  while ti < L do
  begin
    if (pi <= Length(Pat)) and
       ((Pat[pi] = '_') or (Pat[pi] = Char(P[ti]))) then
    begin
      Inc(ti); Inc(pi);
    end
    else if (pi <= Length(Pat)) and (Pat[pi] = '%') then
    begin
      star := pi; mark := ti; Inc(pi);
    end
    else if star <> 0 then
    begin
      pi := star + 1; Inc(mark); ti := mark;
    end
    else Exit(False);
  end;
  while (pi <= Length(Pat)) and (Pat[pi] = '%') do Inc(pi);
  Result := pi > Length(Pat);
end;

{ H19: ASCII satiri VDbTrLower ile ayni sekilde kucultur. Turkce
  modda 'I' -> 'i' DEGIL, UTF-8 'ı' (C4 B1) olur. Cikti en fazla
  2*L bayttir; cagiran tampon boyutunu garanti eder. }
function VdbTrLowerAsciiTo(P: PByte; L: Integer; OutP: PByte;
  out OutLen: Integer): Boolean;
var
  i, o: Integer;
  b: Byte;
begin
  o := 0;
  for i := 0 to L - 1 do
  begin
    b := P[i];
    if b >= 128 then Exit(False);
    if b = Ord('I') then
    begin
      OutP[o] := $C4; OutP[o + 1] := $B1; Inc(o, 2);
    end
    else
    begin
      if (b >= Ord('A')) and (b <= Ord('Z')) then Inc(b, 32);
      OutP[o] := b; Inc(o);
    end;
  end;
  OutLen := o;
  Result := True;
end;

{ Ham kosullari degerlendirir: True = "uyabilir" (elem yok),
  False = "kesinlikle uymaz" (satiri cozmeden ele). Yalniz AND zincirinden
  cikan kosullar cagrilir; bu yuzden tek bir kosunun False'u yeterlidir. }
function VdbStreamSelRawPassEx(const Conds: array of TRawCond;
  Buf: PByte; const FType: TByteArray; const FOff, FLen: TIntArray;
  out AllDecided: Boolean): Boolean;
const
  SAFE_INT: Int64 = 9007199254740992;
var
  k: Integer;
  c: TRawCond;
  iv: Int64;
  fv: Double;
  ok: Boolean;
  iv2, outlen: Integer;
  lbuf: array[0..8191] of Byte;
begin
  Result := True;
  AllDecided := True;
  for k := 0 to High(Conds) do
  begin
    c := Conds[k];
    if FOff[c.Col] < 0 then Exit(False);        // NULL: kiyas FALSE (3-degerli)
    if c.IsLike or c.IsILike then
    begin
      // H19: yalniz saf-ASCII kayit + ASCII desen. ILIKE'da satir Turkce
      // duyarli kucultulur ('I' -> UTF-8 'ı'); desen kurulurken cevrilmistir.
      if FType[c.Col] <> VCT_STR then
      begin
        AllDecided := False;
        Continue;
      end;
      if FLen[c.Col] = 0 then Exit(False);      // '' hicbir kiyasta eslesmez
      if not VdbBytesAscii(Buf + FOff[c.Col], FLen[c.Col]) then
      begin
        AllDecided := False;
        Continue;
      end;
      if c.IsILike then
      begin
        if FLen[c.Col] * 2 > SizeOf(lbuf) then
        begin
          AllDecided := False;
          Continue;
        end;
        if not VdbTrLowerAsciiTo(Buf + FOff[c.Col], FLen[c.Col],
             @lbuf[0], outlen) then
        begin
          AllDecided := False;
          Continue;
        end;
        ok := VdbBytesLikeMatch(@lbuf[0], outlen, c.S);
      end
      else
        ok := VdbBytesLikeMatch(Buf + FOff[c.Col], FLen[c.Col], c.S);
      if not ok then Exit(False);
      Continue;
    end;
    if c.IsIn then
    begin
      // H1c: sayisal IN. NULL yukarida elendi. Kolon tipi beklenenden farkli
      // ise HIC filtreleme (Continue -> genel RowMatches dogru sonucu verir).
      if c.InIsFloat then
      begin
        if (FType[c.Col] <> VCT_FLOAT) or (FLen[c.Col] <> 8) then
        begin
          AllDecided := False;
          Continue;
        end;
        Move((Buf + FOff[c.Col])^, fv, 8);
        ok := False;
        for iv2 := 0 to High(c.InFloats) do
          if fv = c.InFloats[iv2] then begin ok := True; Break; end;
      end
      else
      begin
        if (FType[c.Col] <> VCT_INT) or (FLen[c.Col] <> 8) then
        begin
          AllDecided := False;
          Continue;
        end;
        Move((Buf + FOff[c.Col])^, iv, 8);
        ok := False;
        for iv2 := 0 to High(c.InInts) do
          if iv = c.InInts[iv2] then begin ok := True; Break; end;
      end;
      if not ok then Exit(False);
      Continue;
    end;
    if c.IsText then
    begin
      // H1b: TEXT esitlik/esitsizlik. VDbCmpVal metin yolunda NULL ('')
      // hicbir operatorle eslesmez; kiyas BAYT duzenidir. Yalniz saf-ASCII
      // kayit+literal icin filtrelenir (codepage farki riskini onler);
      // aksi halde Continue -> genel yol dogru sonucu verir.
      if FType[c.Col] <> VCT_STR then
      begin
        AllDecided := False;
        Continue;
      end;
      if FLen[c.Col] = 0 then Exit(False);      // '' hicbir kiyasta eslesmez
      if not VdbBytesAscii(Buf + FOff[c.Col], FLen[c.Col]) then
      begin
        AllDecided := False;
        Continue;
      end;
      if c.Op = sboEq then
      begin
        if not VdbBytesEqP(Buf + FOff[c.Col], FLen[c.Col], c.S) then Exit(False);
      end
      else
      begin
        if VdbBytesEqP(Buf + FOff[c.Col], FLen[c.Col], c.S) then Exit(False);
      end;
      Continue;
    end;
    if c.IsFloat then
    begin
      // Kayittaki GERCEK alan tipi beklenen tip degilse HIC filtreleme
      // (dinamik tip olabilir; genel yol dogru sonucu verir).
      if (FType[c.Col] <> VCT_FLOAT) or (FLen[c.Col] <> 8) then
      begin
        AllDecided := False;
        Continue;
      end;
      Move(Buf[FOff[c.Col]], fv, 8);
      case c.Op of
        sboEq: ok := fv = c.F;
        sboNeq: ok := fv <> c.F;
        sboLt: ok := fv < c.F;
        sboLte: ok := fv <= c.F;
        sboGt: ok := fv > c.F;
        sboGte: ok := fv >= c.F;
      else ok := True;
      end;
      if not ok then Exit(False);
    end
    else
    begin
      if (FType[c.Col] <> VCT_INT) or (FLen[c.Col] <> 8) then
      begin
        AllDecided := False;
        Continue;
      end;
      Move(Buf[FOff[c.Col]], iv, 8);
      // Genel yol INT'i Double ile kiyaslar. 2^53 disinda Int64 kiyasi
      // Double kiyasindan farkli olabilir; o satiri karara baglama.
      if (iv > SAFE_INT) or (iv < -SAFE_INT) or
         (c.I > SAFE_INT) or (c.I < -SAFE_INT) then
      begin
        AllDecided := False;
        Continue;
      end;
      case c.Op of
        sboEq: ok := iv = c.I;
        sboNeq: ok := iv <> c.I;
        sboLt: ok := iv < c.I;
        sboLte: ok := iv <= c.I;
        sboGt: ok := iv > c.I;
        sboGte: ok := iv >= c.I;
      else ok := True;
      end;
      if not ok then Exit(False);
    end;
  end;
end;

function VdbStreamSelRawPass(const Conds: array of TRawCond;
  Buf: PByte; const FType: TByteArray; const FOff, FLen: TIntArray): Boolean;
var
  dummy: Boolean;
begin
  Result := VdbStreamSelRawPassEx(Conds, Buf, FType, FOff, FLen, dummy);
end;

{ H20: ham boolean agacini SQL uc-degerli mantigiyla degerlendirir.
  NULL kiyasi UNKNOWN doner; WHERE'te secilmez. rvUndecided yalniz
  guvenli olmayan satir icin doner (cagiran cozme yoluna duser). }
function VdbEvalRawTree(const Tree: TRawTree; Node: Integer;
  Buf: PByte; const FType: TByteArray; const FOff, FLen: TIntArray): TRawValue;
const
  SAFE_INT: Int64 = 9007199254740992;
var
  n: TRawTreeNode;
  l, r: TRawValue;
  iv: Int64;
  fv: Double;
  ok: Boolean;
  outlen: Integer;
  lbuf: array[0..8191] of Byte;
  lo, hi, mid: Integer;
  cmp: Integer;

  { ASCII metin ile ham baytlari karsilastirir (IN ikili aramasi). }
  function CmpAscii(P: PByte; Len: Integer; const S: string): Integer;
  var
    i, m: Integer;
  begin
    m := Len;
    if Length(S) < m then m := Length(S);
    for i := 0 to m - 1 do
    begin
      if P[i] < Ord(S[i + 1]) then Exit(-1);
      if P[i] > Ord(S[i + 1]) then Exit(1);
    end;
    Result := Len - Length(S);
  end;

begin
  Result := rvUndecided;
  if (Node < 0) or (Node > High(Tree)) then Exit;
  n := Tree[Node];
  case n.Kind of
    rttAnd:
      begin
        l := VdbEvalRawTree(Tree, n.Left, Buf, FType, FOff, FLen);
        if l = rvFalse then Exit(rvFalse);
        r := VdbEvalRawTree(Tree, n.Right, Buf, FType, FOff, FLen);
        if r = rvFalse then Exit(rvFalse);
        if (l = rvUndecided) or (r = rvUndecided) then Exit(rvUndecided);
        if (l = rvTrue) and (r = rvTrue) then Exit(rvTrue);
        Result := rvUnknown;
      end;
    rttOr:
      begin
        l := VdbEvalRawTree(Tree, n.Left, Buf, FType, FOff, FLen);
        if l = rvTrue then Exit(rvTrue);
        r := VdbEvalRawTree(Tree, n.Right, Buf, FType, FOff, FLen);
        if r = rvTrue then Exit(rvTrue);
        if (l = rvUndecided) or (r = rvUndecided) then Exit(rvUndecided);
        if (l = rvFalse) and (r = rvFalse) then Exit(rvFalse);
        Result := rvUnknown;
      end;
    rttNot:
      begin
        l := VdbEvalRawTree(Tree, n.Left, Buf, FType, FOff, FLen);
        case l of
          rvTrue: Result := rvFalse;
          rvFalse: Result := rvTrue;
          rvUnknown: Result := rvUnknown;
        else
          Result := rvUndecided;
        end;
      end;
    rttIsNull, rttIsNotNull:
      begin
        if (n.Col < 0) or (n.Col > High(FOff)) then Exit(rvUndecided);
        ok := (FOff[n.Col] < 0) or (FLen[n.Col] = 0);
        if n.Kind = rttIsNotNull then ok := not ok;
        if ok then Result := rvTrue else Result := rvFalse;
      end;
    rttInInt:
      begin
        if (n.Col < 0) or (n.Col > High(FOff)) then Exit(rvUndecided);
        if (FOff[n.Col] < 0) or (FLen[n.Col] = 0) then Exit(rvUnknown);
        if (FType[n.Col] <> VCT_INT) or (FLen[n.Col] <> 8) then
          Exit(rvUndecided);
        Move((Buf + FOff[n.Col])^, iv, 8);
        if (iv > SAFE_INT) or (iv < -SAFE_INT) then Exit(rvUndecided);
        ok := False;
        lo := 0; hi := High(n.Ints);
        while lo <= hi do
        begin
          mid := (lo + hi) shr 1;
          if n.Ints[mid] < iv then lo := mid + 1
          else if n.Ints[mid] > iv then hi := mid - 1
          else begin ok := True; Break; end;
        end;
        if ok then Result := rvTrue
        else if n.HasNull then Result := rvUnknown
        else Result := rvFalse;
      end;
    rttInFloat:
      begin
        if (n.Col < 0) or (n.Col > High(FOff)) then Exit(rvUndecided);
        if (FOff[n.Col] < 0) or (FLen[n.Col] = 0) then Exit(rvUnknown);
        if (FType[n.Col] <> VCT_FLOAT) or (FLen[n.Col] <> 8) then
          Exit(rvUndecided);
        Move((Buf + FOff[n.Col])^, fv, 8);
        if fv <> fv then Exit(rvUndecided);   // NaN: genel yola birak
        ok := False;
        lo := 0; hi := High(n.Floats);
        while lo <= hi do
        begin
          mid := (lo + hi) shr 1;
          if n.Floats[mid] < fv then lo := mid + 1
          else if n.Floats[mid] > fv then hi := mid - 1
          else begin ok := True; Break; end;
        end;
        if ok then Result := rvTrue
        else if n.HasNull then Result := rvUnknown
        else Result := rvFalse;
      end;
    rttInStr:
      begin
        if (n.Col < 0) or (n.Col > High(FOff)) then Exit(rvUndecided);
        if (FOff[n.Col] < 0) or (FLen[n.Col] = 0) then Exit(rvUnknown);
        if FType[n.Col] <> VCT_STR then Exit(rvUndecided);
        if not VdbBytesAscii(Buf + FOff[n.Col], FLen[n.Col]) then
          Exit(rvUndecided);
        ok := False;
        lo := 0; hi := High(n.Strs);
        while lo <= hi do
        begin
          mid := (lo + hi) shr 1;
          cmp := CmpAscii(Buf + FOff[n.Col], FLen[n.Col], n.Strs[mid]);
          if cmp < 0 then hi := mid - 1
          else if cmp > 0 then lo := mid + 1
          else begin ok := True; Break; end;
        end;
        if ok then Result := rvTrue
        else if n.HasNull then Result := rvUnknown
        else Result := rvFalse;
      end;
    rttUnknown:
      Result := rvUnknown;
    rttCmp:
      begin
        if (n.Col < 0) or (n.Col > High(FOff)) then Exit(rvUndecided);
        if (FOff[n.Col] < 0) or (FLen[n.Col] = 0) then Exit(rvUnknown);
        if n.LitNull then Exit(rvUnknown);
        if FType[n.Col] = VCT_INT then
        begin
          if FLen[n.Col] <> 8 then Exit(rvUndecided);
          Move((Buf + FOff[n.Col])^, iv, 8);
          if (iv > SAFE_INT) or (iv < -SAFE_INT) then Exit(rvUndecided);
          case n.Op of
            sboEq: ok := iv = n.I;
            sboNeq: ok := iv <> n.I;
            sboLt: ok := iv < n.I;
            sboLte: ok := iv <= n.I;
            sboGt: ok := iv > n.I;
            sboGte: ok := iv >= n.I;
          else Exit(rvUndecided);
          end;
          if ok then Result := rvTrue else Result := rvFalse;
        end
        else if FType[n.Col] = VCT_FLOAT then
        begin
          if FLen[n.Col] <> 8 then Exit(rvUndecided);
          Move((Buf + FOff[n.Col])^, fv, 8);
          case n.Op of
            sboEq: ok := fv = n.F;
            sboNeq: ok := fv <> n.F;
            sboLt: ok := fv < n.F;
            sboLte: ok := fv <= n.F;
            sboGt: ok := fv > n.F;
            sboGte: ok := fv >= n.F;
          else Exit(rvUndecided);
          end;
          if ok then Result := rvTrue else Result := rvFalse;
        end
        else if FType[n.Col] = VCT_STR then
        begin
          if not (n.Op in [sboEq, sboNeq]) then Exit(rvUndecided);
          if not VdbBytesAscii(Buf + FOff[n.Col], FLen[n.Col]) then
            Exit(rvUndecided);
          ok := VdbBytesEqP(Buf + FOff[n.Col], FLen[n.Col], n.S);
          if n.Op = sboNeq then ok := not ok;
          if ok then Result := rvTrue else Result := rvFalse;
        end
        else Exit(rvUndecided);
      end;
    rttLike, rttILike:
      begin
        if (n.Col < 0) or (n.Col > High(FOff)) then Exit(rvUndecided);
        if (FOff[n.Col] < 0) or (FLen[n.Col] = 0) then Exit(rvUnknown);
        if n.LitNull then Exit(rvUnknown);
        if FType[n.Col] <> VCT_STR then Exit(rvUndecided);
        if not VdbBytesAscii(Buf + FOff[n.Col], FLen[n.Col]) then
          Exit(rvUndecided);
        if n.Kind = rttILike then
        begin
          if FLen[n.Col] * 2 > SizeOf(lbuf) then Exit(rvUndecided);
          if not VdbTrLowerAsciiTo(Buf + FOff[n.Col], FLen[n.Col],
               @lbuf[0], outlen) then Exit(rvUndecided);
          ok := VdbBytesLikeMatch(@lbuf[0], outlen, n.S);
        end
        else
          ok := VdbBytesLikeMatch(Buf + FOff[n.Col], FLen[n.Col], n.S);
        if ok then Result := rvTrue else Result := rvFalse;
      end;
  end;
end;

{ H3: zone kosulu bu bolumde ASLA eslesemez mi? (yalnizca kanit varsa
  True; suphede False -> bolum okunur, satir kaybi olmaz.) }
function VdbZoneCondFalse(const C: TVDbZoneCond; Has: Boolean;
  MnI, MxI: Int64; MnF, MxF: Double): Boolean;
var
  q: Integer;
begin
  if not Has then Exit(True);   // bolumde non-NULL deger yok: kiyas FALSE
  if C.IsFloat then
  begin
    case C.Op of
      zopEq: Result := (C.F < MnF) or (C.F > MxF);
      zopNe: Result := (MnF = MxF) and (MnF = C.F);
      zopLt: Result := MnF >= C.F;
      zopLe: Result := MnF > C.F;
      zopGt: Result := MxF <= C.F;
      zopGe: Result := MxF < C.F;
      zopIn:
        begin
          Result := True;
          for q := 0 to High(C.InFloats) do
            if (C.InFloats[q] >= MnF) and (C.InFloats[q] <= MxF) then Exit(False);
        end;
    else
      Result := False;
    end;
  end
  else
  begin
    case C.Op of
      zopEq: Result := (C.I < MnI) or (C.I > MxI);
      zopNe: Result := (MnI = MxI) and (MnI = C.I);
      zopLt: Result := MnI >= C.I;
      zopLe: Result := MnI > C.I;
      zopGt: Result := MxI <= C.I;
      zopGe: Result := MxI < C.I;
      zopIn:
        begin
          Result := True;
          for q := 0 to High(C.InInts) do
            if (C.InInts[q] >= MnI) and (C.InInts[q] <= MxI) then Exit(False);
        end;
    else
      Result := False;
    end;
  end;
end;

{ H3: bir satiri (o an cozulmus FType/FOff/FLen ile) zone map'e isler.
  Tip beklenenden farkliysa veya NaN gorulurse kolon KULLANILAMAZ olur;
  o kolon icin budama yapilmaz. }
procedure VdbStreamSelZoneAdd(ctx: PStreamSelCtx; Buf: PByte; Len: Integer);
var
  b, k, c, idx: Integer;
  iv: Int64;
  fv: Double;
begin
  b := ctx^.CurBucket;
  if (ctx^.ZoneMap = nil) or (b < 0) or (b >= ctx^.ZoneMap.BucketCount) then Exit;
  if b > ctx^.ZoneLastBucket then
  begin
    for idx := ctx^.ZoneLastBucket to b - 1 do
      ctx^.ZoneMap.Complete[idx] := 1;
    ctx^.ZoneLastBucket := b;
  end;
  for k := 0 to High(ctx^.ZoneCols) do
  begin
    if not ctx^.ZoneMap.ColUsable[k] then Continue;
    c := ctx^.ZoneCols[k];
    if (c < 0) or (c > High(ctx^.FType)) then Continue;
    if ctx^.FOff[c] < 0 then Continue;                    // NULL: kiyas FALSE
    if ctx^.FOff[c] + 8 > Len then
    begin
      ctx^.ZoneMap.ColUsable[k] := False; Continue;       // bozuk satir: budama yok
    end;
    idx := b * Length(ctx^.ZoneMap.ColIds) + k;
    if ctx^.ZoneIsFloat[k] then
    begin
      if (ctx^.FType[c] <> VCT_FLOAT) or (ctx^.FLen[c] <> 8) then
      begin ctx^.ZoneMap.ColUsable[k] := False; Continue; end;
      Move(Buf[ctx^.FOff[c]], fv, 8);
      if fv <> fv then                                  // NaN: karsilastirma belirsiz
      begin ctx^.ZoneMap.ColUsable[k] := False; Continue; end;
      if ctx^.ZoneMap.HasVal[idx] = 0 then
      begin
        ctx^.ZoneMap.MinF[idx] := fv;
        ctx^.ZoneMap.MaxF[idx] := fv;
        ctx^.ZoneMap.HasVal[idx] := 1;
      end
      else
      begin
        if fv < ctx^.ZoneMap.MinF[idx] then ctx^.ZoneMap.MinF[idx] := fv;
        if fv > ctx^.ZoneMap.MaxF[idx] then ctx^.ZoneMap.MaxF[idx] := fv;
      end;
    end
    else
    begin
      if (ctx^.FType[c] <> VCT_INT) or (ctx^.FLen[c] <> 8) then
      begin ctx^.ZoneMap.ColUsable[k] := False; Continue; end;
      Move(Buf[ctx^.FOff[c]], iv, 8);
      if ctx^.ZoneMap.HasVal[idx] = 0 then
      begin
        ctx^.ZoneMap.MinI[idx] := iv;
        ctx^.ZoneMap.MaxI[idx] := iv;
        ctx^.ZoneMap.HasVal[idx] := 1;
      end
      else
      begin
        if iv < ctx^.ZoneMap.MinI[idx] then ctx^.ZoneMap.MinI[idx] := iv;
        if iv > ctx^.ZoneMap.MaxI[idx] then ctx^.ZoneMap.MaxI[idx] := iv;
      end;
    end;
  end;
end;


function VdbStreamSelRefersCol(E: TSqlExprNode; const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if E = nil then Exit;
  if E is TSqlLiteralNode then Exit(False);
  if E is TSqlColumnRefNode then
    Exit(VDbNorm(TSqlColumnRefNode(E).ColumnName) = VDbNorm(Name));
  if E is TSqlBinaryOpNode then
    Exit(VdbStreamSelRefersCol(TSqlBinaryOpNode(E).Left, Name) or
         VdbStreamSelRefersCol(TSqlBinaryOpNode(E).Right, Name));
  if E is TSqlUnaryOpNode then
    Exit(VdbStreamSelRefersCol(TSqlUnaryOpNode(E).Operand, Name));
  if E is TSqlCastNode then
    Exit(VdbStreamSelRefersCol(TSqlCastNode(E).Expr, Name));
  if E is TSqlCollateNode then
    Exit(VdbStreamSelRefersCol(TSqlCollateNode(E).Inner, Name));
  if E is TSqlNullIfNode then
    Exit(VdbStreamSelRefersCol(TSqlNullIfNode(E).Arg1, Name) or
         VdbStreamSelRefersCol(TSqlNullIfNode(E).Arg2, Name));
  if E is TSqlCoalesceNode then
  begin
    for i := 0 to TSqlCoalesceNode(E).Args.Count - 1 do
      if VdbStreamSelRefersCol(TSqlCoalesceNode(E).Args[i], Name) then Exit(True);
    Exit(False);
  end;
  if E is TSqlFuncCallNode then
  begin
    if VdbStreamSelRefersCol(TSqlFuncCallNode(E).Arg, Name) then Exit(True);
    if VdbStreamSelRefersCol(TSqlFuncCallNode(E).Filter, Name) then Exit(True);
    if TSqlFuncCallNode(E).Args <> nil then
      for i := 0 to TSqlFuncCallNode(E).Args.Count - 1 do
        if VdbStreamSelRefersCol(TSqlFuncCallNode(E).Args[i], Name) then Exit(True);
    Exit(False);
  end;
  if E is TSqlInNode then
  begin
    if VdbStreamSelRefersCol(TSqlInNode(E).Expr, Name) then Exit(True);
    for i := 0 to TSqlInNode(E).List.Count - 1 do
      if VdbStreamSelRefersCol(TSqlInNode(E).List[i], Name) then Exit(True);
    if TSqlInNode(E).SubSelect <> nil then Exit(True);
    Exit(False);
  end;
  if E is TSqlBetweenNode then
    Exit(VdbStreamSelRefersCol(TSqlBetweenNode(E).Expr, Name) or
         VdbStreamSelRefersCol(TSqlBetweenNode(E).LowBound, Name) or
         VdbStreamSelRefersCol(TSqlBetweenNode(E).HighBound, Name));
  if E is TSqlCaseNode then
  begin
    if VdbStreamSelRefersCol(TSqlCaseNode(E).Operand, Name) then Exit(True);
    for i := 0 to TSqlCaseNode(E).Whens.Count - 1 do
      if VdbStreamSelRefersCol(TSqlCaseNode(E).Whens[i].Cond, Name) or
         VdbStreamSelRefersCol(TSqlCaseNode(E).Whens[i].Value, Name) then Exit(True);
    if VdbStreamSelRefersCol(TSqlCaseNode(E).ElseExpr, Name) then Exit(True);
    Exit(False);
  end;
  if E is TSqlJsonKeyNode then
  begin
    if VdbStreamSelRefersCol(TSqlJsonKeyNode(E).Left, Name) then Exit(True);
    for i := 0 to TSqlJsonKeyNode(E).Keys.Count - 1 do
      if VdbStreamSelRefersCol(TSqlJsonKeyNode(E).Keys[i], Name) then Exit(True);
    Exit(False);
  end;
  Result := True;   // bilinmeyen / alt sorgu / pencere: guvenli taraf
end;

function VdbStreamSelCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
var
  ctx: ^TStreamSelCtx;
  tid: Word;
  pk: string;
  vals, prow: TStrArray;
  j: Integer;
  whereOK: Boolean;
begin
  ctx := User;
  if Key = VDB_SCHEMA_KEY then Exit(True);
  if not VDbPeekRawRowP(Buf, Len, ctx^.ColCnt, tid, pk,
                        ctx^.FType, ctx^.FOff, ctx^.FLen) then
  begin
    ctx^.Failed := True;   // bozuk/eski sema: genel yol ayni hatayi uretir
    Exit(False);
  end;
  if tid <> ctx^.TableId then Exit(True);   // baska tablo: ScanRowsPart gibi atla
  if VDbHashKey(ctx^.TableName, pk) <> Key then
  begin
    ctx^.Failed := True;   // hash carpismasi: genel yol NET HATA verir
    Exit(False);
  end;
  // H3: zone map insasi (yalnizca harita gecersizken; validasyondan gecen
  // her canli satir katilir — ham yuklem elemesinden ONCE).
  if ctx^.ZoneOn then VdbStreamSelZoneAdd(ctx, Buf, Len);
  // H20: tam boolean agaci varsa UNKNOWN/FALSE satiri cozmeden ele.
  whereOK := False;
  if ctx^.RawTreeRoot >= 0 then
  begin
    case VdbEvalRawTree(ctx^.RawTree, ctx^.RawTreeRoot, Buf, ctx^.FType,
      ctx^.FOff, ctx^.FLen) of
      rvFalse, rvUnknown: Exit(True);
      rvTrue: whereOK := True;
      // rvUndecided: asagidaki on-eleme + RowMatches yolu.
    end;
  end;
  if not whereOK then
  begin
    // H1 ham-yuklem: kesinlikle UYMAYAN satiri HIC string'e cozmeden ele.
    if ctx^.HasRaw and
       (not VdbStreamSelRawPass(ctx^.RawConds, Buf, ctx^.FType,
                                ctx^.FOff, ctx^.FLen)) then
      Exit(True);
    VDbRowFromOffsetsP(Buf, ctx^.ColCnt, ctx^.FType, ctx^.FOff, ctx^.FLen, vals);
    if (ctx^.Where <> nil) and
       (not ctx^.Exec.RowMatches(ctx^.Where, vals, ctx^.ColNames, ctx^.ColTypes)) then
      Exit(True);
  end
  else
    VDbRowFromOffsetsP(Buf, ctx^.ColCnt, ctx^.FType, ctx^.FOff, ctx^.FLen, vals);
  Inc(ctx^.Seen);
  if ctx^.Seen <= ctx^.Offset then Exit(True);
  SetLength(prow, ctx^.Columns.Count);
  for j := 0 to ctx^.Columns.Count - 1 do
    prow[j] := ctx^.Exec.EvalExpr(ctx^.Columns[j].Expr, vals,
                                  ctx^.ColNames, ctx^.ColTypes);
  SetLength(ctx^.OutRows, Length(ctx^.OutRows) + 1);
  ctx^.OutRows[High(ctx^.OutRows)] := prow;
  Inc(ctx^.Emitted);
  if (ctx^.Limit >= 0) and (ctx^.Emitted >= ctx^.Limit) then Exit(False);
  Result := True;
end;

function VdbStreamDistinctCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
var
  C: PStreamDistinctCtx;
  tid: Word;
  keyHash: QWord;
  v: string;
  vals: TStrArray;
  maxCol: Integer;
  whereOK: Boolean;
begin
  C := User;
  Result := True;
  if Key = VDB_SCHEMA_KEY then Exit;
  if C^.NeedFull then maxCol := C^.ColCnt - 1 else maxCol := C^.ColIdx;
  if not VDbPeekRawRowKeyHashTo(Buf, Len, C^.ColCnt, tid, C^.HashPrefix,
       keyHash, maxCol, C^.FType, C^.FOff, C^.FLen) then
  begin
    C^.Failed := True; Exit(False);
  end;
  if tid <> C^.TableId then Exit;
  if keyHash <> Key then
  begin
    C^.Failed := True; Exit(False);
  end;
  Inc(C^.Seen);
  // H21: tam boolean agaci FALSE/UNKNOWN satiri cozmeden eler; TRUE ise
  // RowMatches'a hic gerek kalmaz.
  whereOK := False;
  if C^.RawTreeRoot >= 0 then
  begin
    case VdbEvalRawTree(C^.RawTree, C^.RawTreeRoot, Buf, C^.FType,
      C^.FOff, C^.FLen) of
      rvFalse, rvUnknown: Exit;
      rvTrue: whereOK := True;
    end;
  end;
  if C^.NeedFull and (not whereOK) then
  begin
    VDbRowFromOffsetsP(Buf, C^.ColCnt, C^.FType, C^.FOff, C^.FLen, vals);
    if (C^.Where <> nil) and
       (not C^.Exec.RowMatches(C^.Where, vals, C^.ColNames, C^.ColTypes)) then
      Exit;
    if (C^.ColIdx >= 0) and (C^.ColIdx <= High(vals)) then
      v := vals[C^.ColIdx]
    else
      v := '';
  end
  else
    v := VDbColFromOffsetsP(Buf, C^.ColCnt, C^.ColIdx,
                            C^.FType, C^.FOff, C^.FLen);
  if C^.Keys.ContainsKey(v) then Exit;
  if C^.N >= VDB_MAX_RESULT_ROWS then
  begin
    C^.Overflow := True; Exit(False);
  end;
  C^.Keys.Add(v, 0);
  if C^.N >= C^.Cap then
  begin
    if C^.Cap < 16 then C^.Cap := 16 else C^.Cap := C^.Cap * 2;
    SetLength(C^.Vals, C^.Cap);
  end;
  C^.Vals[C^.N] := v;
  Inc(C^.N);
end;

function TVSqlExecutor.TryStreamDistinct(Stmt: TSqlSelectStmt;
  const td: TTableDef; const ColNames: TStrArray; const ColTypes: TByteArray;
  out Res: TSqlResult): Boolean;
var
  ctx: TStreamDistinctCtx;
  ci, i, n, start, cnt, root: Integer;
  cr: TSqlColumnRefNode;
  fieldName: string;
  ctype: Byte;
  rows: TStrMatrix;
  orderKeys, sortNames: TStrArray;
  sortTypes: TByteArray;
  ok: Boolean;

  function SameName(const A, B: string): Boolean;
  var
    pa, pb: Integer;
    na, nb: string;
  begin
    na := A;
    nb := B;
    pa := Pos('.', na);
    pb := Pos('.', nb);
    if pa > 0 then na := Copy(na, pa + 1, MaxInt);
    if pb > 0 then nb := Copy(nb, pb + 1, MaxInt);
    Result := VDbNorm(na) = VDbNorm(nb);
  end;

begin
  Result := False;
  if Stmt.LimitVal = 0 then Exit;
  if Stmt.OffsetVal < 0 then Exit;
  if (Stmt.FromTable = '') or Stmt.HasJoin then Exit;
  if (Stmt.SetOp <> sokNone) or (Stmt.RightSelect <> nil) then Exit;
  if Stmt.AsOf <> saoNone then Exit;
  if Stmt.WithQueries.Count > 0 then Exit;
  if not Stmt.IsDistinct then Exit;
  if (Stmt.GroupByCols.Count > 0) or HasAggregate(Stmt) then Exit;
  if HasWindow(Stmt) then Exit;
  if (Stmt.QualifyClause <> nil) or (Stmt.HavingClause <> nil) then Exit;
  if Stmt.Columns.Count <> 1 then Exit;
  if not (Stmt.Columns[0].Expr is TSqlColumnRefNode) then Exit;
  if FT.RlsApplies(Stmt.FromTable) then Exit;
  cr := TSqlColumnRefNode(Stmt.Columns[0].Expr);
  ci := FindColIdx(cr.ColumnName, cr.TableQualifier, ColNames);
  if (ci < 0) or (ci > High(td.Cols)) then Exit;
  if (ci > High(ColTypes)) then Exit;
  // ORDER BY yalnizca ayni kolon (veya alias'i) ve tek anahtar olabilir.
  if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then
  begin
    if Stmt.OrderBy.Count <> 1 then Exit;
    // BOOL siralama genel yolda tamsayi hizli yolunda anahtar uretemedigi
    // icin fiilen siralamiyor (mevcut davranis). Ayni cikti sirasini korumak
    // uzere akisli yolu BOOL'de ORDER BY ile acmiyoruz.
    if not (ColTypes[ci] in [VCT_INT, VCT_FLOAT, VCT_STR]) then Exit;
    if not (Stmt.OrderBy[0].Expr is TSqlColumnRefNode) then Exit;
    if Stmt.OrderBy[0].Collate <> '' then Exit;
    // Kolon tanimli bir collation tasiyorsa genel yol onu uygular.
    if td.Cols[ci].Collate <> '' then Exit;
    ok := SameName(TSqlColumnRefNode(Stmt.OrderBy[0].Expr).ColumnName,
                   td.Cols[ci].Name);
    if (not ok) and (Stmt.Columns[0].Alias <> '') then
      ok := SameName(TSqlColumnRefNode(Stmt.OrderBy[0].Expr).ColumnName,
                     Stmt.Columns[0].Alias);
    if not ok then Exit;
  end;
  if Stmt.Columns[0].Alias <> '' then fieldName := Stmt.Columns[0].Alias
  else fieldName := cr.ColumnName;
  ctype := ColTypes[ci];

  ctx := Default(TStreamDistinctCtx);
  SetLength(ctx.FType, Length(td.Cols));
  SetLength(ctx.FOff, Length(td.Cols));
  SetLength(ctx.FLen, Length(td.Cols));
  ctx.Exec := Self;
  ctx.TableId := td.TableId;
  ctx.HashPrefix := VDbHashKeyPrefix(td.Name);
  ctx.ColCnt := Length(td.Cols);
  ctx.ColNames := ColNames;
  ctx.ColTypes := ColTypes;
  ctx.Where := Stmt.WhereClause;
  ctx.RawTree := VdbBuildRawTree(Self, Stmt.WhereClause, td, ColNames,
    ColTypes, root);
  ctx.RawTreeRoot := root;
  ctx.ColIdx := ci;
  ctx.NeedFull := Stmt.WhereClause <> nil;
  ctx.N := 0;
  ctx.Cap := 0;
  ctx.Keys := TDictionary<string, Integer>.Create;
  try
    if not FT.Kv.ScanRawIterAll(td.TableId, VdbStreamDistinctCb, @ctx) then
    begin
      if ctx.Overflow then
        raise EVDbException.CreateFmt(ecLimit,
          'DISTINCT sonucu cok buyuk (>%d satir)', [VDB_MAX_RESULT_ROWS]);
      Exit(False);
    end;
    if ctx.Failed then Exit(False);
    n := ctx.N;
    if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then
    begin
      SetLength(rows, n);
      for i := 0 to n - 1 do
      begin
        SetLength(rows[i], 1);
        rows[i][0] := ctx.Vals[i];
      end;
      SetLength(orderKeys, 1);
      orderKeys[0] := '__vdb_distinct_key__';
      SetLength(sortNames, 1);
      sortNames[0] := '__vdb_distinct_key__';
      SetLength(sortTypes, 1);
      sortTypes[0] := ctype;
      DoSort(rows, orderKeys, Stmt.OrderBy, sortNames, sortTypes);
      for i := 0 to n - 1 do ctx.Vals[i] := rows[i][0];
    end;
    start := Stmt.OffsetVal;
    if start > n then start := n;
    cnt := n - start;
    if (Stmt.LimitVal >= 0) and (Stmt.LimitVal < cnt) then
      cnt := Stmt.LimitVal;
    SetLength(Res.Fields, 1);
    Res.Fields[0] := fieldName;
    SetLength(Res.FieldTypes, 1);
    Res.FieldTypes[0] := ctype;
    SetLength(Res.Rows, cnt);
    for i := 0 to cnt - 1 do
    begin
      SetLength(Res.Rows[i], 1);
      Res.Rows[i][0] := ctx.Vals[start + i];
    end;
    Res.Affected := cnt;
    Res.Msg := 'OK';
    Result := True;
  finally
    ctx.Keys.Free;
  end;
end;

function TVSqlExecutor.TryStreamSelect(Stmt: TSqlSelectStmt; const td: TTableDef;
  out Res: TSqlResult): Boolean;
var
  ctx: TStreamSelCtx;
  cn, outCols: TStrArray;
  ct, outTypes: TByteArray;
  j, ci, nConds, root: Integer;
  pkName: string;
  conj: TList<TSqlExprNode>;
  b: TSqlBinaryOpNode;
  cr: TSqlColumnRefNode;
  lit: TSqlLiteralNode;
  op: TSqlBinaryOp;
  swap: Boolean;
  cnd: TRawCond;
  cnd2: TRawCond;
  // H3: zone map
  zConds: array of TVDbZoneCond;
  zCols: array of Integer;
  zFloat: array of Boolean;
  zSkip: TBytes;
  zSkipPtr: PByte;
  zMap, zOld: TVDbZoneMap;
  zN, zB, zIdx, zK, zBCount: Integer;
  zGenSeq, zGenEpoch: QWord;
  zUsable, zScanOk: Boolean;

  procedure CollectAnd(E: TSqlExprNode);
  begin
    if E = nil then Exit;
    if (E is TSqlBinaryOpNode) and (TSqlBinaryOpNode(E).Op = sboAnd) then
    begin
      CollectAnd(TSqlBinaryOpNode(E).Left);
      CollectAnd(TSqlBinaryOpNode(E).Right);
    end
    else conj.Add(E);
  end;

  { AND'in tek kosunu ham kosuya cevrilebilir mi? Yalnizca INT/FLOAT kolon
    ile SAYISAL literal; digerleri atlanir (guvenli: filtre uygulanmaz). }
  function TryCond(E: TSqlExprNode; out C: TRawCond): Boolean;
  begin
    Result := False;
    if not (E is TSqlBinaryOpNode) then Exit;
    b := TSqlBinaryOpNode(E);
    op := b.Op;
    if not (op in [sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte]) then Exit;
    swap := False;
    if b.Left is TSqlColumnRefNode then
    begin
      cr := TSqlColumnRefNode(b.Left);
      if not (b.Right is TSqlLiteralNode) then Exit;
      lit := TSqlLiteralNode(b.Right);
    end
    else if b.Right is TSqlColumnRefNode then
    begin
      cr := TSqlColumnRefNode(b.Right);
      if not (b.Left is TSqlLiteralNode) then Exit;
      lit := TSqlLiteralNode(b.Left);
      swap := True;     // literal op kolon  ->  kolon ters-op literal
    end
    else Exit;
    ci := FindColIdx(cr.ColumnName, cr.TableQualifier, cn);
    if ci < 0 then Exit;
    if td.Cols[ci].Encrypted then Exit;   // M6: ham karsilastirma sifreli
    if swap then
      case op of
        sboLt: op := sboGt;
        sboLte: op := sboGte;
        sboGt: op := sboLt;
        sboGte: op := sboLte;
      end;
    if ct[ci] = VCT_INT then
    begin
      if lit.LitType <> sltInt then Exit;
      C.Col := ci; C.Op := op; C.IsFloat := False; C.IsText := False;
      C.IsIn := False; C.InIsFloat := False;
      C.I := lit.IntVal; C.F := 0;
      Exit(True);
    end;
    if ct[ci] = VCT_FLOAT then
    begin
      if lit.LitType = sltInt then C.F := lit.IntVal
      else if lit.LitType = sltFloat then C.F := lit.FloatVal
      else Exit;
      C.Col := ci; C.Op := op; C.IsFloat := True; C.IsText := False; C.I := 0;
      C.IsIn := False; C.InIsFloat := False;
      Exit(True);
    end;
    if ct[ci] = VCT_STR then
    begin
      // H1b: TEXT yalniz '=' / '<>' ve saf-ASCII string literal icin ham
      // filtrelenir (VDbCmpVal metin yolu BAYT duzenidir). Diger operatorler
      // ya da ASCII disi literal -> ham filtre yok (genel RowMatches).
      if not (op in [sboEq, sboNeq]) then Exit;
      if lit.LitType <> sltString then Exit;
      if not VdbStrPureAscii(lit.StrVal) then Exit;
      C.Col := ci; C.Op := op; C.IsFloat := False; C.IsText := True;
      C.IsIn := False; C.InIsFloat := False;
      C.I := 0; C.F := 0; C.S := lit.StrVal;
      Exit(True);
    end;
  end;

  { H1c: sayisal BETWEEN (NOT degil) -> iki ham kosu (>= lo ve <= hi).
    Boylece mevcut degerlendirici yeniden kullanilir; RowMatches dogrulamasi
    zaten son sozdur. }
  function TryBetween(E: TSqlExprNode; out C1, C2: TRawCond): Boolean;
  var
    bt: TSqlBetweenNode;
    cl: TSqlColumnRefNode;
    loN, hiN: TSqlLiteralNode;
    ci2: Integer;
    loF, hiF: Double;
  begin
    Result := False;
    if not (E is TSqlBetweenNode) then Exit;
    bt := TSqlBetweenNode(E);
    if bt.IsNot then Exit;
    if not (bt.Expr is TSqlColumnRefNode) then Exit;
    if not ((bt.LowBound is TSqlLiteralNode) and (bt.HighBound is TSqlLiteralNode)) then Exit;
    cl := TSqlColumnRefNode(bt.Expr);
    ci2 := FindColIdx(cl.ColumnName, cl.TableQualifier, cn);
    if ci2 < 0 then Exit;
    if td.Cols[ci2].Encrypted then Exit;   // M6
    loN := TSqlLiteralNode(bt.LowBound);
    hiN := TSqlLiteralNode(bt.HighBound);

    C1.Col := ci2; C1.Op := sboGte; C1.IsText := False; C1.IsIn := False;
    C2.Col := ci2; C2.Op := sboLte; C2.IsText := False; C2.IsIn := False;
    C1.I := 0; C1.F := 0; C1.S := ''; C2.I := 0; C2.F := 0; C2.S := '';
    if ct[ci2] = VCT_INT then
    begin
      if (loN.LitType <> sltInt) or (hiN.LitType <> sltInt) then Exit;
      C1.IsFloat := False; C1.I := loN.IntVal;
      C2.IsFloat := False; C2.I := hiN.IntVal;
      Exit(True);
    end;
    if ct[ci2] = VCT_FLOAT then
    begin
      if loN.LitType = sltInt then loF := loN.IntVal
      else if loN.LitType = sltFloat then loF := loN.FloatVal
      else Exit;
      if hiN.LitType = sltInt then hiF := hiN.IntVal
      else if hiN.LitType = sltFloat then hiF := hiN.FloatVal
      else Exit;
      C1.IsFloat := True; C1.F := loF;
      C2.IsFloat := True; C2.F := hiF;
      Exit(True);
    end;
  end;

  { H1c: sayisal IN (NOT IN degil, alt sorgu yok, tum literal sayisal). }
  function TryIn(E: TSqlExprNode; out C: TRawCond): Boolean;
  var
    inN: TSqlInNode;
    cl: TSqlColumnRefNode;
    q, ci2: Integer;
    ln: TSqlLiteralNode;
  begin
    Result := False;
    if not (E is TSqlInNode) then Exit;
    inN := TSqlInNode(E);
    if inN.IsNot or (inN.SubSelect <> nil) then Exit;
    if not (inN.Expr is TSqlColumnRefNode) then Exit;
    if inN.List.Count = 0 then Exit;
    cl := TSqlColumnRefNode(inN.Expr);
    ci2 := FindColIdx(cl.ColumnName, cl.TableQualifier, cn);
    if ci2 < 0 then Exit;
    if td.Cols[ci2].Encrypted then Exit;   // M6
    C.Col := ci2; C.Op := sboEq; C.IsText := False; C.IsIn := True;
    C.I := 0; C.F := 0; C.S := '';
    if ct[ci2] = VCT_INT then
    begin
      C.IsFloat := False; C.InIsFloat := False;
      SetLength(C.InInts, inN.List.Count);
      for q := 0 to inN.List.Count - 1 do
      begin
        if not (inN.List[q] is TSqlLiteralNode) then Exit;
        ln := TSqlLiteralNode(inN.List[q]);
        if ln.LitType <> sltInt then Exit;
        C.InInts[q] := ln.IntVal;
      end;
      Exit(True);
    end;
    if ct[ci2] = VCT_FLOAT then
    begin
      C.IsFloat := False; C.InIsFloat := True;
      SetLength(C.InFloats, inN.List.Count);
      for q := 0 to inN.List.Count - 1 do
      begin
        if not (inN.List[q] is TSqlLiteralNode) then Exit;
        ln := TSqlLiteralNode(inN.List[q]);
        if ln.LitType = sltInt then C.InFloats[q] := ln.IntVal
        else if ln.LitType = sltFloat then C.InFloats[q] := ln.FloatVal
        else Exit;
      end;
      Exit(True);
    end;
  end;

begin
  Result := False;
  { --- Sekil korumasi: genel yol ile AYNI sonucu garantileyen dar kume --- }
  if Stmt.LimitVal = 0 then Exit;                 // LIMIT 0 -> genel (bos)
  if Stmt.OffsetVal < 0 then Exit;
  if (Stmt.FromTable = '') or Stmt.HasJoin then Exit;
  if (Stmt.SetOp <> sokNone) or (Stmt.RightSelect <> nil) then Exit;
  if Stmt.AsOf <> saoNone then Exit;
  if Stmt.WithQueries.Count > 0 then Exit;
  if Stmt.IsDistinct then Exit;
  if (Stmt.GroupByCols.Count > 0) or HasAggregate(Stmt) then Exit;
  if HasWindow(Stmt) then Exit;
  if (Stmt.QualifyClause <> nil) or (Stmt.HavingClause <> nil) then Exit;
  if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then Exit;
  if td.IsView then Exit;
  if FT.RlsApplies(Stmt.FromTable) then Exit;
  if Stmt.Columns.Count = 0 then Exit;
  // Ikincil indeks varsa ya da WHERE PK'ya basvuruyorsa genel yol
  // (indeks/PK daraltmasi) daha iyi olabilir; streaming KULLANMA.
  if Length(td.Idx) > 0 then Exit;
  if td.PkIndex >= 0 then
  begin
    pkName := td.Cols[td.PkIndex].Name;
    if VdbStreamSelRefersCol(Stmt.WhereClause, pkName) then Exit;
  end;

  BuildColInfo(td, cn, ct);
  // Cikti kolon adlari: genel yol ile ayni kural.
  SetLength(outCols, Stmt.Columns.Count);
  for j := 0 to Stmt.Columns.Count - 1 do
  begin
    if Stmt.Columns[j].Alias <> '' then outCols[j] := Stmt.Columns[j].Alias
    else if Stmt.Columns[j].Expr is TSqlColumnRefNode then
      outCols[j] := TSqlColumnRefNode(Stmt.Columns[j].Expr).ColumnName
    else outCols[j] := 'col' + IntToStr(j + 1);
  end;

  // Ham-yuklem kosulari: AND zincirindeki uygun kiyaslar.
  conj := TList<TSqlExprNode>.Create;
  try
    CollectAnd(Stmt.WhereClause);
    SetLength(ctx.RawConds, conj.Count * 2);   // BETWEEN iki kosu uretir
    nConds := 0;
    for j := 0 to conj.Count - 1 do
    begin
      if TryCond(conj[j], cnd) then
      begin
        ctx.RawConds[nConds] := cnd; Inc(nConds);
        Continue;
      end;
      // H1c: sayisal BETWEEN -> iki kosu; RowMatches yine son soz.
      if TryBetween(conj[j], cnd, cnd2) then
      begin
        ctx.RawConds[nConds] := cnd; Inc(nConds);
        ctx.RawConds[nConds] := cnd2; Inc(nConds);
        Continue;
      end;
      // H1c: sayisal IN listesi.
      if TryIn(conj[j], cnd) then
      begin
        ctx.RawConds[nConds] := cnd; Inc(nConds);
      end;
    end;
    SetLength(ctx.RawConds, nConds);
  finally
    conj.Free;
  end;
  ctx.HasRaw := nConds > 0;
  ctx.RawTree := VdbBuildRawTree(Self, Stmt.WhereClause, td, cn, ct, root);
  ctx.RawTreeRoot := root;

  // LIMIT yok, ham yuklem yok ve agac da yoksa: erken durma/eleme yok -> genel.
  if (Stmt.LimitVal < 0) and (not ctx.HasRaw) and
     (ctx.RawTreeRoot < 0) then Exit;

  // ---- H3 (2026-10-18): aralik/esitlik icin zone map ----
  // Kosullar yalnizca sayisal kolonlara uygulanir. Harita gecersizse
  // (veri degismis / yok) BU tarama sirasinda insa edilip yayinlanir;
  // gecerliyse bucket atlama bayraklari hesaplanir.
  SetLength(zConds, 0);
  SetLength(zCols, 0);
  SetLength(zFloat, 0);
  zN := 0;
  SetLength(zConds, Length(ctx.RawConds));
  for j := 0 to High(ctx.RawConds) do
  begin
    if ctx.RawConds[j].IsText then Continue;
    if (ctx.RawConds[j].Col < 0) or (ctx.RawConds[j].Col > High(ct)) then Continue;
    if (ct[ctx.RawConds[j].Col] <> VCT_INT) and
       (ct[ctx.RawConds[j].Col] <> VCT_FLOAT) then Continue;
    if ctx.RawConds[j].IsIn then
    begin
      if ctx.RawConds[j].InIsFloat and (ct[ctx.RawConds[j].Col] <> VCT_FLOAT) then Continue;
      if (not ctx.RawConds[j].InIsFloat) and (ct[ctx.RawConds[j].Col] <> VCT_INT) then Continue;
    end
    else
    begin
      if ctx.RawConds[j].IsFloat and (ct[ctx.RawConds[j].Col] <> VCT_FLOAT) then Continue;
      if (not ctx.RawConds[j].IsFloat) and (ct[ctx.RawConds[j].Col] <> VCT_INT) then Continue;
    end;
    zConds[zN].Col := ctx.RawConds[j].Col;
    if ctx.RawConds[j].IsIn then
    begin
      zConds[zN].Op := zopIn;
      zConds[zN].IsFloat := ctx.RawConds[j].InIsFloat;
      zConds[zN].InIsFloat := ctx.RawConds[j].InIsFloat;
      zConds[zN].InInts := ctx.RawConds[j].InInts;
      zConds[zN].InFloats := ctx.RawConds[j].InFloats;
    end
    else
    begin
      case ctx.RawConds[j].Op of
        sboEq: zConds[zN].Op := zopEq;
        sboNeq: zConds[zN].Op := zopNe;
        sboLt: zConds[zN].Op := zopLt;
        sboLte: zConds[zN].Op := zopLe;
        sboGt: zConds[zN].Op := zopGt;
        sboGte: zConds[zN].Op := zopGe;
      else
        zConds[zN].Op := zopEq;
      end;
      zConds[zN].IsFloat := ctx.RawConds[j].IsFloat;
      zConds[zN].I := ctx.RawConds[j].I;
      zConds[zN].F := ctx.RawConds[j].F;
    end;
    Inc(zN);
  end;
  SetLength(zConds, zN);
  // benzersiz (kolon, tip) listesi
  for j := 0 to zN - 1 do
  begin
    zIdx := -1;
    for zB := 0 to High(zCols) do
      if zCols[zB] = zConds[j].Col then begin zIdx := zB; Break; end;
    if zIdx < 0 then
    begin
      SetLength(zCols, Length(zCols) + 1);
      SetLength(zFloat, Length(zFloat) + 1);
      zCols[High(zCols)] := zConds[j].Col;
      zFloat[High(zFloat)] := zConds[j].IsFloat;
    end;
  end;

  zSkip := nil;
  zSkipPtr := nil;
  zMap := nil;
  zOld := nil;
  zScanOk := True;
  // Batch icinde bekleyen PUT/DELETE'ler FIdxVer'i ARTIRMAZ (dosyaya da
  // yazilmazlar). Harita pending degisimlerini kacirabilecegi icin batch
  // sirasinda zone map NE kullanilir NE de insa edilir.
  if FT.Kv.InBatch then
  begin
    SetLength(zCols, 0);
    SetLength(zFloat, 0);
    zN := 0;
  end;
  ctx.ZoneOn := False;
  ctx.ZoneMap := nil;
  ctx.CurBucket := -1;
  ctx.ZoneLastBucket := 0;
  SetLength(ctx.ZoneCols, 0);
  SetLength(ctx.ZoneIsFloat, 0);
  zBCount := 0;
  if Length(zCols) > 0 then
  begin
    zGenSeq := FT.Kv.DataSeqValue;
    zGenEpoch := FT.Kv.DataEpochValue;
    zBCount := TVDb.RawScanBucketCount(FT.Kv.DataFileSize);
    zUsable := FZoneMaps.TryGetValue(td.TableId, zMap) and
      (zMap.GenSeq = zGenSeq) and (zMap.GenEpoch = zGenEpoch) and
      (zMap.BucketCount = zBCount);
    if zUsable then
      for j := 0 to High(zCols) do
      begin
        zK := zMap.FindCol(zCols[j]);
        if zK < 0 then begin zUsable := False; Break; end;
        // Sema tipi degistiyse (INT<->FLOAT) eski min/max gecersizdir.
        if zMap.ColFloat[zK] <> zFloat[j] then begin zUsable := False; Break; end;
      end;
    if zUsable then
    begin
      SetLength(zSkip, zBCount);
      for zB := 0 to zBCount - 1 do
      begin
        if zMap.Complete[zB] = 0 then Continue;
        for j := 0 to zN - 1 do
        begin
          zK := zMap.FindCol(zConds[j].Col);
          if zK < 0 then Continue;
          if not zMap.ColUsable[zK] then Continue;
          zIdx := zB * Length(zMap.ColIds) + zK;
          if VdbZoneCondFalse(zConds[j], zMap.HasVal[zIdx] <> 0,
               zMap.MinI[zIdx], zMap.MaxI[zIdx],
               zMap.MinF[zIdx], zMap.MaxF[zIdx]) then
          begin
            zSkip[zB] := 1;
            Break;
          end;
        end;
      end;
      if Length(zSkip) > 0 then zSkipPtr := @zSkip[0];
    end
    else
    begin
      zMap := TVDbZoneMap.Create(zGenSeq, zGenEpoch, zBCount, zCols, zFloat);
      ctx.ZoneOn := True;
      ctx.ZoneMap := zMap;
      ctx.ZoneCols := zCols;
      ctx.ZoneIsFloat := zFloat;
      ctx.ZoneLastBucket := 0;
    end;
  end;

  FCurTable := Stmt.FromTable;
  FCurCollation := '';
  FExplicitColl := False;

  ctx.Exec := Self;
  ctx.TableId := td.TableId;
  ctx.TableName := td.Name;
  ctx.ColCnt := Length(td.Cols);
  SetLength(ctx.FType, ctx.ColCnt);
  SetLength(ctx.FOff, ctx.ColCnt);
  SetLength(ctx.FLen, ctx.ColCnt);
  ctx.ColNames := cn;
  ctx.ColTypes := ct;
  ctx.Where := Stmt.WhereClause;
  ctx.Columns := Stmt.Columns;
  ctx.Offset := Stmt.OffsetVal;
  ctx.Limit := Stmt.LimitVal;
  ctx.Seen := 0;
  ctx.Emitted := 0;
  SetLength(ctx.OutRows, 0);
  ctx.Failed := False;

  zScanOk := FT.Kv.ScanRawIterAllZoned(td.TableId, zSkipPtr, Length(zSkip),
    @ctx.CurBucket, VdbStreamSelCb, @ctx);

  // H3: insa edilen haritayi yayinla (yalnizca veri hala ayni surumdeyse).
  // LIMIT ile erken durulduysa yalnizca TAM islenen on-ek bucket'lar
  // "tamam" isaretlidir; kalanlar sonraki taramada okunur.
  if ctx.ZoneOn and (ctx.ZoneMap <> nil) then
  begin
    if (not ctx.Failed) and zScanOk then
      for zB := ctx.ZoneLastBucket to zBCount - 1 do
        ctx.ZoneMap.Complete[zB] := 1;
    if (not ctx.Failed) and
       (FT.Kv.DataSeqValue = zGenSeq) and
       (FT.Kv.DataEpochValue = zGenEpoch) then
    begin
      if FZoneMaps.TryGetValue(td.TableId, zOld) then
      begin
        FZoneMaps.AddOrSetValue(td.TableId, ctx.ZoneMap);
        zOld.Free;
      end
      else
        FZoneMaps.Add(td.TableId, ctx.ZoneMap);
    end
    else
      ctx.ZoneMap.Free;
    ctx.ZoneMap := nil;
  end;
  if ctx.Failed then Exit(False);

  // M1: cikti tipleri (pgwire OID'leri icin)
  SetLength(outTypes, Length(outCols));
  for j := 0 to High(outTypes) do
  begin
    if j < Stmt.Columns.Count then
      outTypes[j] := ExprResultCtype(Stmt.Columns[j].Expr, cn, ct)
    else
      outTypes[j] := VCT_STR;
  end;
  Res.Fields := outCols;
  Res.FieldTypes := outTypes;
  Res.Rows := ctx.OutRows;
  Res.Affected := Length(Res.Rows);
  Res.Msg := 'OK';
  Result := True;
end;

function TVSqlExecutor.TryStreamOrderLimit(Stmt: TSqlSelectStmt;
  const td: TTableDef; const ColNames: TStrArray; const ColTypes: TByteArray;
  out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
var
  ctx: TStreamOrderCtx;
  cr: TSqlColumnRefNode;
  i, j, start, cnt, root: Integer;
  k64: Int64;
  rv: TStrArray;

begin
  Result := False;
  SetLength(Pks, 0);
  SetLength(Rows, 0);
  if Stmt.OrderBy = nil then Exit;
  if Stmt.OrderBy.Count > 1 then
    Exit(TryStreamOrderMultiLimit(Stmt, td, ColNames, ColTypes, Pks, Rows));
  if Stmt.OrderBy.Count <> 1 then Exit;
  if Stmt.HasJoin or Stmt.IsDistinct or (Stmt.SetOp <> sokNone) then Exit;
  if HasAggregate(Stmt) or (Stmt.GroupByCols.Count > 0) then Exit;
  if HasWindow(Stmt) or (Stmt.QualifyClause <> nil) then Exit;
  if (Stmt.LimitVal < 0) or (Stmt.OffsetVal < 0) then Exit;
  if not (Stmt.OrderBy[0].Expr is TSqlColumnRefNode) then Exit;
  if Stmt.OrderBy[0].Collate <> '' then Exit;
  cr := TSqlColumnRefNode(Stmt.OrderBy[0].Expr);
  ctx.SortCol := -1;
  for j := 0 to High(td.Cols) do
    if VDbNorm(td.Cols[j].Name) = VDbNorm(cr.ColumnName) then
    begin ctx.SortCol := j; Break; end;
  if ctx.SortCol < 0 then Exit;
  if td.Cols[ctx.SortCol].Encrypted or (td.Cols[ctx.SortCol].Collate <> '') then Exit;
  ctx.SortType := td.Cols[ctx.SortCol].Ctype;
  if not (ctx.SortType in [VCT_INT, VCT_BOOL, VCT_FLOAT, VCT_STR]) then Exit;
  k64 := Int64(Stmt.LimitVal) + Int64(Stmt.OffsetVal);
  if k64 <= 0 then
  begin
    // LIMIT 0: tarama gerekmez.
    if Stmt.LimitVal = 0 then
    begin
      Result := True;
      Exit;
    end;
    Exit;
  end;
  // Cok derin OFFSET'te K buyur; bu durumda genel/top-N yol daha uygun.
  if k64 > 200000 then Exit;

  ctx.Exec := Self;
  ctx.TableId := td.TableId;
  ctx.TableName := td.Name;
  ctx.HashPrefix := VDbHashKeyPrefix(td.Name);
  ctx.ColCnt := Length(td.Cols);
  SetLength(ctx.FType, ctx.ColCnt);
  SetLength(ctx.FOff, ctx.ColCnt);
  SetLength(ctx.FLen, ctx.ColCnt);
  ctx.ColNames := ColNames;
  ctx.ColTypes := ColTypes;
  ctx.Where := Stmt.WhereClause;
  ctx.NeedFull := Stmt.WhereClause <> nil;
  SetLength(ctx.RawConds, 0);
  if ctx.NeedFull then
    VdbStreamOrderAddRawCond(ctx.RawConds, Self, Stmt.WhereClause, td, ColNames, ColTypes);
  ctx.RawTree := VdbBuildRawTree(Self, Stmt.WhereClause, td, ColNames,
    ColTypes, root);
  ctx.RawTreeRoot := root;
  ctx.Desc := Stmt.OrderBy[0].Desc;
  ctx.NullsPos := Stmt.OrderBy[0].NullsPos;
  ctx.K := k64;
  ctx.N := 0;
  ctx.Seen := 0;
  ctx.Failed := False;
  SetLength(ctx.Heap, ctx.K);

  if not FT.Kv.ScanRawIterAll(td.TableId, VdbStreamOrderCb, @ctx) then Exit;
  if ctx.Failed then Exit;

  VdbStreamOrderSort(@ctx);
  start := Stmt.OffsetVal;
  if start >= ctx.N then
  begin
    Result := True;
    Exit;
  end;
  cnt := ctx.N - start;
  if Stmt.LimitVal < cnt then cnt := Stmt.LimitVal;
  SetLength(Pks, cnt);
  SetLength(Rows, cnt);
  for i := 0 to cnt - 1 do
  begin
    if not FT.ReadRow(td.Name, ctx.Heap[start + i].Pk, rv) then
    begin
      SetLength(Pks, 0);
      SetLength(Rows, 0);
      Exit(False);
    end;
    Pks[i] := ctx.Heap[start + i].Pk;
    Rows[i] := rv;
  end;
  Result := True;
end;

function TVSqlExecutor.TryStreamOrderMultiLimit(Stmt: TSqlSelectStmt;
  const td: TTableDef; const ColNames: TStrArray; const ColTypes: TByteArray;
  out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
var
  ctx: TStreamOrderMultiCtx;
  cr: TSqlColumnRefNode;
  i, j, start, cnt, root: Integer;
  k64: Int64;
  rv: TStrArray;
begin
  Result := False;
  SetLength(Pks, 0);
  SetLength(Rows, 0);
  if (Stmt.OrderBy = nil) or (Stmt.OrderBy.Count < 2) then Exit;
  if Stmt.HasJoin or Stmt.IsDistinct or (Stmt.SetOp <> sokNone) then Exit;
  if HasAggregate(Stmt) or (Stmt.GroupByCols.Count > 0) then Exit;
  if HasWindow(Stmt) or (Stmt.QualifyClause <> nil) then Exit;
  if (Stmt.LimitVal < 0) or (Stmt.OffsetVal < 0) then Exit;

  ctx.SortCnt := Stmt.OrderBy.Count;
  SetLength(ctx.SortCols, ctx.SortCnt);
  SetLength(ctx.SortTypes, ctx.SortCnt);
  SetLength(ctx.Descs, ctx.SortCnt);
  SetLength(ctx.NullsPos, ctx.SortCnt);
  for i := 0 to ctx.SortCnt - 1 do
  begin
    if not (Stmt.OrderBy[i].Expr is TSqlColumnRefNode) then Exit;
    if Stmt.OrderBy[i].Collate <> '' then Exit;
    cr := TSqlColumnRefNode(Stmt.OrderBy[i].Expr);
    ctx.SortCols[i] := -1;
    for j := 0 to High(td.Cols) do
      if VDbNorm(td.Cols[j].Name) = VDbNorm(cr.ColumnName) then
      begin ctx.SortCols[i] := j; Break; end;
    if ctx.SortCols[i] < 0 then Exit;
    if td.Cols[ctx.SortCols[i]].Encrypted or
       (td.Cols[ctx.SortCols[i]].Collate <> '') then Exit;
    ctx.SortTypes[i] := td.Cols[ctx.SortCols[i]].Ctype;
    if not (ctx.SortTypes[i] in [VCT_INT, VCT_BOOL, VCT_FLOAT, VCT_STR]) then Exit;
    ctx.Descs[i] := Stmt.OrderBy[i].Desc;
    ctx.NullsPos[i] := Stmt.OrderBy[i].NullsPos;
  end;

  k64 := Int64(Stmt.LimitVal) + Int64(Stmt.OffsetVal);
  if k64 <= 0 then
  begin
    if Stmt.LimitVal = 0 then Result := True;
    Exit;
  end;
  if k64 > 200000 then Exit;

  ctx.Exec := Self;
  ctx.TableId := td.TableId;
  ctx.TableName := td.Name;
  ctx.HashPrefix := VDbHashKeyPrefix(td.Name);
  ctx.ColCnt := Length(td.Cols);
  SetLength(ctx.FType, ctx.ColCnt);
  SetLength(ctx.FOff, ctx.ColCnt);
  SetLength(ctx.FLen, ctx.ColCnt);
  ctx.ColNames := ColNames;
  ctx.ColTypes := ColTypes;
  ctx.Where := Stmt.WhereClause;
  ctx.NeedFull := Stmt.WhereClause <> nil;
  SetLength(ctx.RawConds, 0);
  if ctx.NeedFull then
    VdbStreamOrderAddRawCond(ctx.RawConds, Self, Stmt.WhereClause, td, ColNames, ColTypes);
  ctx.RawTree := VdbBuildRawTree(Self, Stmt.WhereClause, td, ColNames,
    ColTypes, root);
  ctx.RawTreeRoot := root;
  ctx.K := k64;
  ctx.N := 0;
  ctx.Seen := 0;
  ctx.Failed := False;
  SetLength(ctx.Heap, ctx.K);
  SetLength(ctx.Scratch.Keys, ctx.SortCnt);

  if not FT.Kv.ScanRawIterAll(td.TableId, VdbStreamOrderMultiCb, @ctx) then Exit;
  if ctx.Failed then Exit;

  VdbStreamOrderMultiSort(@ctx);
  start := Stmt.OffsetVal;
  if start >= ctx.N then
  begin
    Result := True;
    Exit;
  end;
  cnt := ctx.N - start;
  if Stmt.LimitVal < cnt then cnt := Stmt.LimitVal;
  SetLength(Pks, cnt);
  SetLength(Rows, cnt);
  for i := 0 to cnt - 1 do
  begin
    if not FT.ReadRow(td.Name, ctx.Heap[start + i].Pk, rv) then
    begin
      SetLength(Pks, 0);
      SetLength(Rows, 0);
      Exit(False);
    end;
    Pks[i] := ctx.Heap[start + i].Pk;
    Rows[i] := rv;
  end;
  Result := True;
end;

function TVSqlExecutor.TryFtsNarrow(Stmt: TSqlSelectStmt;
  const td: TTableDef; const ColNames: TStrArray;
  const ColTypes: TByteArray; out Pks: TStrArray;
  out Rows: TStrMatrix): Boolean;
var
  QList, Cand: TStringList;
  fts: TVdbFtsIndex;
  Counts: TDictionary<string, Integer>;
  allPks, loadedPks: TStrArray;
  allRows, loadedRows: TStrMatrix;
  i, j, ci, p, n: Integer;
  seq: QWord;
  col, q, key, pk, item: string;
  Pair: TPair<string, Integer>;
  storedSeq, curSeq: QWord;
  ftsRow: TStrArray;

  function Collect(E: TSqlExprNode): Boolean;
  var
    b: TSqlBinaryOpNode;
    fn: TSqlFuncCallNode;
    lit: TSqlLiteralNode;
    cref: TSqlColumnRefNode;
    l, r: Boolean;
  begin
    Result := False;
    if E = nil then Exit;
    if (E is TSqlBinaryOpNode) and
       (TSqlBinaryOpNode(E).Op = sboAnd) then
    begin
      b := TSqlBinaryOpNode(E);
      l := Collect(b.Left);
      r := Collect(b.Right);
      Exit(l or r);
    end;
    if not (E is TSqlFuncCallNode) then Exit;
    fn := TSqlFuncCallNode(E);
    if (not SameText(fn.FuncName, 'TS_MATCH')) or
       (fn.Args = nil) or (fn.Args.Count < 2) then Exit;
    if not (fn.Args[0] is TSqlColumnRefNode) then Exit;
    if not (fn.Args[1] is TSqlLiteralNode) then Exit;
    cref := TSqlColumnRefNode(fn.Args[0]);
    lit := TSqlLiteralNode(fn.Args[1]);
    if lit.LitType <> sltString then Exit;
    QList.Add(cref.ColumnName + #9 + lit.StrVal);
    Result := True;
  end;

begin
  Result := False;
  Pks := nil;
  Rows := nil;
  if (Stmt = nil) or (Stmt.WhereClause = nil) then Exit;
  QList := TStringList.Create;
  Cand := TStringList.Create;
  Counts := TDictionary<string, Integer>.Create;
  try
    if not Collect(Stmt.WhereClause) then Exit;
    if QList.Count = 0 then Exit;

    for i := 0 to QList.Count - 1 do
    begin
      item := QList[i];
      p := Pos(#9, item);
      if p <= 0 then Exit;
      col := Copy(item, 1, p - 1);
      q := Copy(item, p + 1, MaxInt);
      ci := FindColIdx(col, '', ColNames);
      if (ci < 0) or (ci > High(ColTypes)) or (ColTypes[ci] <> VCT_STR) then Exit;

      key := IntToStr(td.TableId) + ':' + LowerCase(col);
      if not FFtsIndexes.TryGetValue(key, fts) then
      begin
        fts := TVdbFtsIndex.Create;
        FFtsIndexes.Add(key, fts);
        FFtsSeqs.Add(key, High(QWord));
      end;
      curSeq := QWord(FT.Kv.DataSeqValue);
      if (not FFtsSeqs.TryGetValue(key, storedSeq)) or (storedSeq <> curSeq) then
      begin
        fts.Clear;
        FT.ScanRows(Stmt.FromTable, allPks, allRows);
        for j := 0 to High(allPks) do
          if (j <= High(allRows)) and (ci <= High(allRows[j])) then
            fts.AddDoc(allPks[j], allRows[j][ci]);
        allPks := nil;
        allRows := nil;
        FFtsSeqs[key] := curSeq;
      end;

      Cand.Clear;
      if not fts.Candidates(q, Cand) then Exit;   // yalniz negatif terim
      for j := 0 to Cand.Count - 1 do
      begin
        pk := Cand[j];
        if Counts.TryGetValue(pk, n) then Counts[pk] := n + 1
        else Counts.Add(pk, 1);
      end;
    end;

    // Tum TS_MATCH conjunct'lari ayni PK'yi isaret etmeli.
    loadedPks := nil;
    for Pair in Counts do
      if Pair.Value = QList.Count then
      begin
        SetLength(loadedPks, Length(loadedPks) + 1);
        loadedPks[High(loadedPks)] := Pair.Key;
      end;

    if Length(loadedPks) = 0 then
    begin
      SetLength(Pks, 0);
      SetLength(Rows, 0);
      Exit(True);
    end;

    SetLength(loadedRows, Length(loadedPks));
    n := 0;
    for i := 0 to High(loadedPks) do
      if FT.ReadRow(Stmt.FromTable, loadedPks[i], ftsRow) then
      begin
        loadedPks[n] := loadedPks[i];
        loadedRows[n] := ftsRow;
        Inc(n);
      end;
    SetLength(loadedPks, n);
    SetLength(loadedRows, n);
    Pks := loadedPks;
    Rows := loadedRows;
    Result := True;
  finally
    Counts.Free;
    Cand.Free;
    QList.Free;
  end;
end;

function TVSqlExecutor.TryVectorNarrow(Stmt: TSqlSelectStmt;
  const td: TTableDef; const ColNames: TStrArray;
  const ColTypes: TByteArray; out Pks: TStrArray;
  out Rows: TStrMatrix): Boolean;
const
  // Kucuk tabloda ANN'e gerek yok: tam tarama zaten hizli ve kesin.
  ANN_MIN_ROWS = 512;
var
  fn: TSqlFuncCallNode;
  lit: TSqlLiteralNode;
  cref: TSqlColumnRefNode;
  ci, i, n, k: Integer;
  metric, key, col: string;
  q: TDoubleArray;
  idx: TVdbVectorIndex;
  allPks, ids, loadedPks: TStrArray;
  allRows, loadedRows: TStrMatrix;
  vec, dists: TDoubleArray;
  seq, storedSeq: QWord;
  row: TStrArray;
begin
  Result := False;
  Pks := nil;
  Rows := nil;
  if Stmt = nil then Exit;
  if Stmt.HasJoin then Exit;
  if (Stmt.MoreJoins <> nil) and (Stmt.MoreJoins.Count > 0) then Exit;
  if (Stmt.WithQueries <> nil) and (Stmt.WithQueries.Count > 0) then Exit;
  if Stmt.SetOp <> sokNone then Exit;
  if Stmt.WhereClause <> nil then Exit;
  if Stmt.HavingClause <> nil then Exit;
  if Stmt.QualifyClause <> nil then Exit;
  if Stmt.IsDistinct then Exit;
  if (Stmt.GroupByCols <> nil) and (Stmt.GroupByCols.Count > 0) then Exit;
  if HasAggregate(Stmt) or HasWindow(Stmt) then Exit;
  if Stmt.ForUpdate or (Stmt.AsOf <> saoNone) then Exit;
  if (Stmt.OrderBy = nil) or (Stmt.OrderBy.Count <> 1) then Exit;
  if Stmt.OrderBy[0].Desc then Exit;
  if (Stmt.LimitVal <= 0) or (Stmt.LimitVal > 100000) then Exit;
  if not (Stmt.OrderBy[0].Expr is TSqlFuncCallNode) then Exit;
  fn := TSqlFuncCallNode(Stmt.OrderBy[0].Expr);
  if not SameText(fn.FuncName, 'VECTOR_DISTANCE') then Exit;
  if (fn.Args = nil) or (fn.Args.Count < 2) then Exit;
  if not (fn.Args[0] is TSqlColumnRefNode) then Exit;
  cref := TSqlColumnRefNode(fn.Args[0]);
  ci := FindColIdx(cref.ColumnName, '', ColNames);
  if (ci < 0) or (ci > High(ColTypes)) then Exit;
  if not (fn.Args[1] is TSqlLiteralNode) then Exit;
  lit := TSqlLiteralNode(fn.Args[1]);
  if lit.LitType <> sltString then Exit;
  if not VDbVectorParse(lit.StrVal, q) then Exit;
  if Length(q) = 0 then Exit;
  metric := 'l2';
  if fn.Args.Count >= 3 then
  begin
    if not (fn.Args[2] is TSqlLiteralNode) then Exit;
    metric := LowerCase(TSqlLiteralNode(fn.Args[2]).StrVal);
  end;
  metric := VDbVectorMetric(metric);
  if metric = '' then Exit;
  if FT.RlsApplies(Stmt.FromTable) then Exit;

  col := LowerCase(cref.ColumnName);
  key := IntToStr(td.TableId) + ':' + col + ':' + metric;
  if not FVecIndexes.TryGetValue(key, idx) then
  begin
    idx := TVdbVectorIndex.Create(Length(q), metric);
    FVecIndexes.Add(key, idx);
    FVecSeqs.Add(key, High(QWord));
  end;
  seq := QWord(FT.Kv.DataSeqValue);
  if (not FVecSeqs.TryGetValue(key, storedSeq)) or (storedSeq <> seq) then
  begin
    idx.Clear;
    FT.ScanRows(Stmt.FromTable, allPks, allRows);
    for i := 0 to High(allPks) do
      if (i <= High(allRows)) and (ci <= High(allRows[i])) and
         VDbVectorParse(allRows[i][ci], vec) and
         (Length(vec) = idx.Dim) then
        idx.Add(allPks[i], vec);
    allPks := nil;
    allRows := nil;
    FVecSeqs[key] := seq;
  end;

  // Kucuk tablo: indeks kuruldu ama kesin yol daha dogru ve yeterince hizli.
  if idx.Count <= ANN_MIN_ROWS then Exit;

  k := Stmt.LimitVal + Max(0, Stmt.OffsetVal);
  if not idx.Search(q, k, ids, dists) then
  begin
    SetLength(Pks, 0);
    SetLength(Rows, 0);
    Exit(True);
  end;

  SetLength(loadedPks, 0);
  SetLength(loadedRows, 0);
  n := 0;
  for i := 0 to High(ids) do
    if FT.ReadRow(Stmt.FromTable, ids[i], row) then
    begin
      SetLength(loadedPks, n + 1);
      SetLength(loadedRows, n + 1);
      loadedPks[n] := ids[i];
      loadedRows[n] := row;
      Inc(n);
    end;
  Pks := loadedPks;
  Rows := loadedRows;
  Result := True;
end;

procedure TVSqlExecutor.ExecSelect(Stmt: TSqlSelectStmt; out Res: TSqlResult);
var
  td: TTableDef;
  pks: TStrArray;
  allRows, filteredRows, outRows, merged: TStrMatrix;
  rlRows: TStrMatrix;   // R-19
  colNames: TStrArray;
  colTypes: TByteArray;
  outTypes: TByteArray;
  i, j, n: Integer;
  outCols: TStrArray;
  orderKeys: TStrArray;
  rightRes: TSqlResult;
  seenKeys: TList<TStrArray>;
  // F2-18: O(1) tekilleÅŸtirme kovalari
  seenSet, rightSet: TDictionary<string, Integer>;
  distinctOut: TStrMatrix;
  rowKey: string;
  isDup, found, SkipOffsetLimit, HasSetOp, deferOrder, isExactNarrow: Boolean;
  preferStream: Boolean;
  orderName: string;
  baseIdx, tmpSlot, origCols: Integer;
  // H1 (2026-10-18): LIMIT erken-cikis
  capSel: Integer;
  canEarly: Boolean;
  // P5-WIN: pencere onbellek (projeksiyonda tuketilir).
  WinVals: TStrMatrix;
  WinSlot: TIntArray;
  // F-09: QUALIFY satirlari
  qualifyKeep: TIntArray;
  qualifyNew: TStrMatrix;
  qualifyWin: TStrMatrix;
  qn: Integer;
  // F-33: View handling (non-JOIN path)
  ViewSel: TSqlSelectStmt;
  ViewRes: TSqlResult;
  ViewTypes: TByteArray;
  cnt64: Int64;

  // 4.2 (2026-10-06): aggregate/GROUP BY sonrasi kuyruk â€” JOIN ve
  // tek-tablo yolu ORTAK kullanir (kod tekrari yok). ORDER BY cikti
  // tip haritasiyla uygulanir (F1-20: COUNT '10' < '2' metin sirasi
  // olmasin), sonra OFFSET + LIMIT. Calisirken Res zaten doludur.
  procedure FinishGroup;
  var
    ix: Integer; // DIKKAT: nested prosedurde dis prosedur degiskeni FOR
                 // sayaci OLAMAZ (FPC 4058); sayac yerel olmali.
  begin
    if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then
    begin
      SetLength(orderKeys, Stmt.OrderBy.Count);
      for ix := 0 to Stmt.OrderBy.Count - 1 do
        if Stmt.OrderBy[ix].Expr is TSqlColumnRefNode then
          orderKeys[ix] := TSqlColumnRefNode(Stmt.OrderBy[ix].Expr).QualifiedName
        else orderKeys[ix] := '';
      DoSort(Res.Rows, orderKeys, Stmt.OrderBy, Res.Fields, outTypes);
    end;
    if Stmt.OffsetVal > 0 then
    begin
      if Stmt.OffsetVal < Length(Res.Rows) then
      begin
        n := Length(Res.Rows) - Stmt.OffsetVal;
        for ix := 0 to n - 1 do Res.Rows[ix] := Res.Rows[ix + Stmt.OffsetVal];
        SetLength(Res.Rows, n);
      end
      else SetLength(Res.Rows, 0);
    end;
    if (Stmt.LimitVal >= 0) and (Length(Res.Rows) > Stmt.LimitVal) then
      SetLength(Res.Rows, Stmt.LimitVal);
    Res.Affected := Length(Res.Rows);
  end;

begin


  // MVCC / Snapshot Isolation (R-01): Kilitsiz snapshot okuma.
  // SELECT sorgulari snapshot isolation ile calisir: okuyucular yazicilari
  // bloke etmez, yazicilar okuyuculari bloke etmez.
  // FT.BeginSnapshotRead;
  try
    SkipOffsetLimit := False;
    isExactNarrow := False;
    // R-20: aktif tablo — kolon varsayilan collation'i (WHERE / GROUP BY / ORDER BY icin)
    FCurTable := Stmt.FromTable;
    FCurCollation := '';
    FExplicitColl := False;
    // F1-12: set-op'ta kuyruk (ORDER BY / OFFSET / LIMIT) birlestirme
    // SONRASINA uygulanir; ONCESI uygulanirsa sol taraf kirpilir.
    HasSetOp := (Stmt.SetOp <> sokNone) and (Stmt.RightSelect <> nil);

  // AS OF (2026-10-06): kapsam disindaki kullanimlari ACIKCA reddet.
  // (JOIN dalindan once, cunku JOIN yolu ExecJoinScan ile CALISIYOR;
  //  gecmis goruntusu yalnizca tek tablo taramasinda kurulabilir.)
  if Stmt.AsOf <> saoNone then
  begin
    if Stmt.HasJoin then
      raise EVDbException.Create(ecUnsupported,
        'AS OF ile JOIN desteklenmiyor (yalnizca tek tablo taranir)');
    if Stmt.WithQueries.Count > 0 then
      raise EVDbException.Create(ecUnsupported,
        'AS OF ile WITH/CTE desteklenmiyor');
    if Stmt.AsOf = saoTimestamp then
      raise EVDbException.Create(ecUnsupported,
        'AS OF TIMESTAMP desteklenmiyor: WAL kayitlarinda zaman damgasi yoktur; ' +
        'AS OF SEQUENCE <n> kullanin (n = WAL kayit indeksi)');
    if Stmt.AsOf = saoVersion then
      raise EVDbException.Create(ecUnsupported,
        'AS OF VERSION desteklenmiyor: WAL kayitlarinda surum numarasi yoktur; ' +
        'AS OF SEQUENCE <n> kullanin (n = WAL kayit indeksi)');
  end;

  // FROM'suz SELECT: SELECT 1, 'abc' AS x, NULL
  if (Stmt.FromTable = '') and not Stmt.HasJoin then
  begin
    SetLength(outCols, Stmt.Columns.Count);
    SetLength(outRows, 1);
    SetLength(outRows[0], Stmt.Columns.Count);
    for i := 0 to Stmt.Columns.Count - 1 do
    begin
      if Stmt.Columns[i].Alias <> '' then
        outCols[i] := Stmt.Columns[i].Alias
      else if Stmt.Columns[i].Expr is TSqlLiteralNode then
        outCols[i] := TSqlLiteralNode(Stmt.Columns[i].Expr).AsString
      else
        outCols[i] := 'col' + IntToStr(i + 1);

      if Stmt.Columns[i].Expr is TSqlColumnRefNode then
        raise EVDbException.Create(ecSyntaxError, 'FROM''suz SELECT icinde kolon kullanilamaz: ' +
          TSqlColumnRefNode(Stmt.Columns[i].Expr).ColumnName);

      outRows[0][i] := EvalExpr(Stmt.Columns[i].Expr, nil, nil, nil);
    end;
    Res.Fields := outCols;
    Res.Rows := outRows;
    Res.Affected := 1;
    Res.Msg := 'OK';
    // R-10: SET OP yolundaki FROM'suz SELECT'ler de birlestirilir.
    // DIKKAT: asagidaki genel SetOp blogu bu yoldan SONRA gelir ve
    // burada Exit yapildigi icin hic calismazdi.
    if (not FNoSetOpMerge) and (Stmt.SetOp <> sokNone) and (Stmt.RightSelect <> nil) then
      MergeSetOpRows(Stmt, outRows, outCols);
    Res.Fields := outCols;
    Res.Rows := outRows;
    Exit;
  end;

  // P5-CTE: WITH listesi once materyallestirilir (sira onemli:
  // sonraki CTE oncekileri gorebilir).
  if (Stmt.WithQueries.Count > 0) then
    MaterializeCtes(Stmt);


  // Karma kontrol: FROM'lu SELECT'te ham literal + kolon ref birlikte kullanilamaz
  if (Stmt.FromTable <> '') and (Stmt.Columns.Count > 0) then
  begin
    found := False; isDup := False;
    for i := 0 to Stmt.Columns.Count - 1 do
    begin
      if Stmt.Columns[i].Expr is TSqlLiteralNode then found := True;
      if Stmt.Columns[i].Expr is TSqlColumnRefNode then isDup := True;
    end;
    if found and isDup then
      for i := 0 to Stmt.Columns.Count - 1 do
        if Stmt.Columns[i].Expr is TSqlColumnRefNode then
          raise EVDbException.CreateFmt(ecSyntaxError, 'FROM''suz SELECT icinde kolon kullanilamaz: %s',
            [TSqlColumnRefNode(Stmt.Columns[i].Expr).ColumnName]);
  end;


  if (Stmt.HavingClause <> nil) and (not HasAggregate(Stmt)) and (Stmt.GroupByCols.Count = 0) then
    raise EVDbException.Create(ecSyntaxError, 'HAVING yalnizca GROUP BY veya aggregate ile kullanilabilir');


  // P5-WIN: pencere yerlesim + GROUP BY/aggregate catismasi.
  if HasWindow(Stmt) then
  begin
    if (Stmt.GroupByCols.Count > 0) or HasAggregate(Stmt) then
      raise EVDbException.Create(ecUnsupported,
        'GROUP BY/aggregate ile pencere fonksiyonu desteklenmiyor');
    CheckWindowPlacement(Stmt);
  end;


  if Stmt.HasJoin then
  begin
    // P5-1 / 4.2 (2026-10-06): JOIN ile GROUP BY/aggregate ARTIK
    // calisir â€” birlesim ciktisi ayni ExecGroupBy hattindan gecer.
    // WHERE'i ExecGroupBy zaten kendisi uygular; onceden filtrelemek
    // yalnizca is yukunu azaltir, sonucu degistirmez. Set-op hala
    // reddedilir (F1-12 ayni kural, ayni mesaj).
    ExecJoinScan(Stmt, allRows, colNames, colTypes);
    if (Stmt.GroupByCols.Count > 0) or HasAggregate(Stmt) then
    begin
      if HasSetOp then
        raise EVDbException.Create(ecUnsupported,
          'UNION/EXCEPT/INTERSECT ile aggregate/GROUP BY birlestirilemiyor');
      ExecGroupBy(Stmt, pks, allRows, colNames, colTypes, Res, outTypes);
      FinishGroup;
      Exit;
    end;
    // Sonuc en fazla allRows kadar olabilir: bir kez ayir, eslesenleri
    // sirayla doldur ve sonunda kisalt. Satir basina SetLength O(N^2)
    // kopyalama maliyeti olusturuyordu.
    SetLength(filteredRows, Length(allRows));
    n := 0;
    for i := 0 to High(allRows) do
      if RowMatches(Stmt.WhereClause, allRows[i], colNames, colTypes) then
      begin
        filteredRows[n] := allRows[i];
        Inc(n);
      end;
    SetLength(filteredRows, n);
  end
  else
  begin
    // AS OF (2026-10-06): CTE ve indeks yollari GUNCEL veriye gore calisir;
    // gecmis goruntu once WAL'den kurulur, satirlar sonradan ayni
    // WHERE/ORDER/GROUP/LIMIT hattindan gecer.
    if Stmt.AsOf <> saoNone then
    begin
      td := FT.GetTable(Stmt.FromTable);
      BuildColInfo(td, colNames, colTypes);
      SkipOffsetLimit := False;
      BuildAsOfRows(Stmt, td, colNames, pks, allRows);
    end
    // P5-CTE: FROM bir CTE adiysa materyal kumesi kullanilir (PK/indeks
    // optimizasyonlari atlanir; filtreleme RowMatches ile aynen calisir).
    else if TryCte(Stmt.FromTable, colNames, colTypes, allRows) then
    begin

      SetLength(pks, 0);
      SkipOffsetLimit := False;
    end
    else
    begin

      td := FT.GetTable(Stmt.FromTable);
      // R-20: aktif tablo — kolon varsayilan collation'i icin
      FCurTable := Stmt.FromTable;
      FCurCollation := '';
      // R-18: SELECT icin SELECT izni
      FT.RequirePriv(Stmt.FromTable, Ord(pkSelect));
      BuildColInfo(td, colNames, colTypes);


      // F-33: VIEW destegi - view ise SELECT'ini calistir
      if td.IsView then
      begin
        { NOT: AST katalogda saklanmaz; view tanim METNINDEN yeniden
          uretilir ve is bitince serbest birakilir. }
        ViewSel := ParseSelectText(FT.ViewSelectText(Stmt.FromTable));
        if ViewSel = nil then
          raise EVDbException.Create(ecSyntaxError,
            'view tanimi ayristirilamadi veya bos: ' + Stmt.FromTable);
        try
          ExecSelect(ViewSel, ViewRes);
        finally
          ViewSel.Free;
        end;
        ViewTypes := ViewResultTypes(Stmt.FromTable, ViewRes.Fields);
        colNames := ViewRes.Fields;
        SetLength(colTypes, Length(colNames));
        for i := 0 to High(colNames) do
          if i <= High(ViewTypes) then colTypes[i] := ViewTypes[i]
          else colTypes[i] := VCT_STR;
        allRows := ViewRes.Rows;
        SetLength(pks, 0);
      end
      else
      begin
        { M5: TS_MATCH conjunct'lari varsa once inverted index ile daralt.
          WHERE yine asagida aynen uygulanir; sonuc kumesi degismez. }
        if TryFtsNarrow(Stmt, td, colNames, colTypes, pks, allRows) then
        begin
          SkipOffsetLimit := False;
          isExactNarrow := False;
        end
        { M4: ORDER BY VECTOR_DISTANCE(...) LIMIT k -> HNSW adaylari.
          WHERE/ORDER/LIMIT asagida aynen uygulanir. }
        else if TryVectorNarrow(Stmt, td, colNames, colTypes, pks, allRows) then
        begin
          SkipOffsetLimit := False;
          isExactNarrow := False;
        end
        else
        begin
        // H16: tek kolonlu SELECT DISTINCT -> ham akistan tek pass.
        if TryStreamDistinct(Stmt, td, colNames, colTypes, Res) then
          Exit;
        // H1 (2026-10-18): indekssiz, LIMIT'li, ORDER BY'siz tek tablo
        // SELECT'i ham akistan okuyup LIMIT dolunca durur. Uymazsa False.
        if TryStreamSelect(Stmt, td, Res) then
          Exit;
        // P-12: WHERE/GROUP'suz tek tablo agregasi -> ham akistan say.
        // Sekli uymazsa False; asagidaki genel yol AYNEN calisir.
        if TryStreamAgg(Stmt, td, Res) then
          Exit;
        // H13: GROUP BY + basit aggregate -> ham akistan tek pass.
        if TryStreamGroupBy(Stmt, td, colNames, colTypes, Res, outTypes) then
        begin
          FinishGroup;
          Exit;
        end;
        // H3: WHERE'li saf COUNT(*) -> indeks dilimini satir okumadan say.
        if TryIndexCount(td, Stmt, colNames, colTypes, cnt64) then
        begin
          SetLength(Res.Fields, 1);
          if Stmt.Columns[0].Alias <> '' then
            Res.Fields[0] := Stmt.Columns[0].Alias
          else
            Res.Fields[0] := 'COUNT';
          SetLength(Res.Rows, 1);
          SetLength(Res.Rows[0], 1);
          Res.Rows[0][0] := IntToStr(cnt64);
          Res.Affected := 1;
          Res.Msg := 'OK';
          Exit;
        end;
        // H17: WHERE'li saf COUNT(*) -> ham akistan, yalniz WHERE'in
        // referans verdigi kolonlari cozerek tek pass.
        if TryStreamFilteredCount(Stmt, td, colNames, colTypes, Res) then
          Exit;
        // YOL 1 (en hizli): ORDER BY tek kolon ve o kolon indeksliyse satirlar
      // INDEKS sirasiyla okunur; OFFSET/LIMIT satir okunurken uygulanir.
      // F1-12: Eger SetOp varsa (UNION/EXCEPT/INTERSECT), ORDER BY/LIMIT/OFFSET
      // birlesimden SONRA uygulanmali, indeks yolunu atla.
      // DIKKAT: SkipOffsetLimit yalnizca "indeks yolu eleme/siralamayi
      // kendi yapti" demektir; set-op'ta deger False kalir, cunku sol
      // taraf WHERE filtresi hala uygulanmali. Eski kodda True yapildigi
      // icin filteredRows hic doldurulmuyor ve birlestirme bos oluyordu.
      if Stmt.SetOp <> sokNone then
        SkipOffsetLimit := False
      else if FT.RlsApplies(Stmt.FromTable) then
        SkipOffsetLimit := False   // R-19: asagida satir satir filtrelenir
      else
      begin
        // H12b: Kucuk LIMIT'te siralama kolonu PK degilse ve WHERE PK'ya
        // basvurmuyorsa ham akisli top-N genellikle ikincil indeksin ilk
        // (bellek ici) insasindan cok daha hizlidir. PK sirasi korunur.
        preferStream := False;
        if (Length(allRows) = 0) and
           (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count = 1) and
           (Stmt.LimitVal >= 0) and
           (Int64(Stmt.LimitVal) + Int64(Stmt.OffsetVal) <= 10000) and
           (Stmt.OrderBy[0].Expr is TSqlColumnRefNode) then
        begin
          orderName := TSqlColumnRefNode(Stmt.OrderBy[0].Expr).ColumnName;
          if (td.PkIndex < 0) or
             (VDbNorm(orderName) <> VDbNorm(td.Cols[td.PkIndex].Name)) then
            if (Stmt.WhereClause = nil) or (td.PkIndex < 0) or
               (not VdbStreamSelRefersCol(Stmt.WhereClause,
                 td.Cols[td.PkIndex].Name)) then
              preferStream := True;
        end;
        if preferStream then
        begin
          SkipOffsetLimit := TryStreamOrderLimit(Stmt, td, colNames,
            colTypes, pks, filteredRows);
          if not SkipOffsetLimit then
            SkipOffsetLimit := TryIndexOrder(td, Stmt, colNames, colTypes,
              filteredRows);
        end
        else
        begin
          SkipOffsetLimit := TryIndexOrder(td, Stmt, colNames, colTypes,
            filteredRows);
          // H12: indeks yoksa ORDER BY ... LIMIT icin ham akisli top-N.
          // WHERE PK'ya basvuruyorsa NarrowRows'un PK daraltmasi daha iyidir.
          if (not SkipOffsetLimit) and (Length(allRows) = 0) and
             ((Stmt.WhereClause = nil) or (td.PkIndex < 0) or
              (not VdbStreamSelRefersCol(Stmt.WhereClause,
                td.Cols[td.PkIndex].Name))) then
            SkipOffsetLimit := TryStreamOrderLimit(Stmt, td, colNames,
              colTypes, pks, filteredRows);
        end;
      end;
      if not SkipOffsetLimit then
      begin
        { YOL 2: Satir adaylarini DARALT - PK nokta aramasi veya indeks dilimi.
          (Once her zaman FT.ScanRows cagriliyordu: 100.000 satirlik tabloda
           "WHERE id = 5" bile ~900 ms suruyordu.)
          Aggregate/GROUP BY de dogrudan sunu kullanir: ExecGroupBy satirlari
          KENDISI RowMatches ile filtreler, yani onceden daraltmak sonucu
          degistirmez. }
        if not NarrowRows(td, Stmt.WhereClause, colNames, colTypes, pks, allRows, isExactNarrow) then
          // R-13 Full: tam taramaya dustuk -> bolme hedef kumesiyle
          // tara (partition pruning). Sonuc ayni, okunan satir azalir.
          FT.ScanRowsPart(Stmt.FromTable, pks, allRows, PartTargetsOf(td, Stmt.WhereClause));
      end;
        end;
      // R-19: satirlar okundu; simdi RLS ile GORUNMEZ olanlari ele.
      // BURADA yapilir (WHERE filtresinden ONCE) ki aggregate/GROUP BY,
      // ORDER BY, LIMIT/LIST ve set-op birlestirmesi de dogru satir
      // kumesi uzerinde calissin. WHERE filtresi asagida ayrica uygulanir.
      if FT.RlsApplies(Stmt.FromTable) then
      begin
        // RLS sonucunun ust siniri allRows uzunlugudur; her gorunen
        // satirda diziyi yeniden buyutme.
        SetLength(rlRows, Length(allRows));
        n := 0;
        for i := 0 to High(allRows) do
          if RlsRowVisible(Stmt.FromTable, 1, allRows[i], colNames, colTypes) then
          begin
            rlRows[n] := allRows[i];
            Inc(n);
          end;
        SetLength(rlRows, n);
        allRows := rlRows;
        SetLength(pks, 0);
        SkipOffsetLimit := False;
        isExactNarrow := False;
      end;
    end;
  end;  // end of else (not view)

    if HasAggregate(Stmt) or (Stmt.GroupByCols.Count > 0) then
    begin
      // F1-12: aggregate/GROUP BY yolu taban tablodan dogrudan satirlari
      // dondurup Exit yapar; set-op birlestirmesi hic calismazdi ve
      // sonuc sessizce yanlis cikardi. Desteklenmiyorsa hata ver.
      if HasSetOp then
        raise EVDbException.Create(ecUnsupported,
          'UNION/EXCEPT/INTERSECT ile aggregate/GROUP BY birlestirilemiyor');
      ExecGroupBy(Stmt, pks, allRows, colNames, colTypes, Res, outTypes,
        isExactNarrow and (not SkipOffsetLimit));
      // 4.2: kuyruk ortak FinishGroup'a tasinildi (JOIN yolu da aynisini
      // cagirir; F1-20 ORDER BY tip haritasi + OFFSET/LIMIT + Affected).
      FinishGroup;
      Exit;
    end;

    // Indeks yolu (SkipOffsetLimit) filteredRows'u doldurduysa eleme;
    // CTE/normal yolda allRows buradan suzulur.
    if not SkipOffsetLimit then
    begin
      // P-22: Eger NarrowRows araligi zaten WHERE kosulunu TAM olarak
      // karsiliyorsa (tek BETWEEN / = / IN), satirlari tekrar tekrar
      // RowMatches ile AST evaluate etmekten kurtul (84x farkin cozumu).
      if isExactNarrow then
        filteredRows := allRows
      else
      begin
        // H1 (2026-10-18): LIMIT ERKEN-CIKIS. ORDER BY / DISTINCT / pencere /
        // QUALIFY / set-op YOKken ilk (OFFSET+LIMIT) eslesen satir nihai
        // sonuctur; sonrasi degerlendirilmez. Sonuc BIREBIR ayni kalir.
        canEarly := (Stmt.LimitVal >= 0) and (Stmt.OffsetVal >= 0) and
                    (Stmt.OrderBy.Count = 0) and (not Stmt.IsDistinct) and
                    (Stmt.SetOp = sokNone) and (Stmt.QualifyClause = nil) and
                    (not HasWindow(Stmt));
        if canEarly then capSel := Stmt.OffsetVal + Stmt.LimitVal
        else capSel := -1;
        // Sonuc en fazla allRows kadar olabilir; satir basina SetLength
        // dinamik diziyi tekrar tekrar kopyalayip O(N^2) maliyet yaratir.
        SetLength(filteredRows, Length(allRows));
        n := 0;
        for i := 0 to High(allRows) do
        begin
          if RowMatches(Stmt.WhereClause, allRows[i], colNames, colTypes) then
          begin
            filteredRows[n] := allRows[i];
            Inc(n);
            if (capSel >= 0) and (n >= capSel) then Break;   // H1
          end;
        end;
        SetLength(filteredRows, n);
      end;
    end;
  end;

  // ORDER BY (Projection oncesi - tum kolonlar mevcutken dogru sirala)
  // F1-12: set-op varsa birlestirme sonrasina birakilir.
  //
  // F2-19 ALIAS DESTEGI: `SELECT id, ROW_NUMBER() OVER (...) AS rn
  // FROM w ORDER BY g, rn` gecerlidir. Projeksiyon ONCESI 'rn' taban
  // kolonlarinda yoktur ve DoSort F1-21 geregi hata verir. Bu yuzden
  // once taban kolonlarinda cozulur; cozulemeyen anahtar varsa siralama
  // projeksiyon SONRASINA ertelenir (bkz. asagida deferOrder blogu) ve
  // orada CIKTI kolonlari uzerinden, alias dahil, cozulur.
  deferOrder := False;
  if (not SkipOffsetLimit) and (not HasSetOp) and (Stmt.OrderBy <> nil) and
     (Stmt.OrderBy.Count > 0) then
  begin
    SetLength(orderKeys, Stmt.OrderBy.Count);
    for i := 0 to Stmt.OrderBy.Count - 1 do
      if Stmt.OrderBy[i].Expr is TSqlColumnRefNode then
        orderKeys[i] := TSqlColumnRefNode(Stmt.OrderBy[i].Expr).QualifiedName
      else orderKeys[i] := '';
    // Taban kolonlarinda cozulebilir mi?
    for i := 0 to Stmt.OrderBy.Count - 1 do
    begin
      if orderKeys[i] = '' then Continue;
      found := False;
      for j := 0 to High(colNames) do
      begin
        if SameText(colNames[j], orderKeys[i]) then
        begin found := True; Break; end;
        if (Pos('.', colNames[j]) > 0) and
           SameText(Copy(colNames[j], Pos('.', colNames[j]) + 1, MaxInt),
                    orderKeys[i]) then
        begin found := True; Break; end;
        if (Pos('.', orderKeys[i]) > 0) and
           SameText(Copy(orderKeys[i], Pos('.', orderKeys[i]) + 1, MaxInt),
                    colNames[j]) then
        begin found := True; Break; end;
      end;
      if not found then deferOrder := True;
    end;
    // F-09: QUALIFY projeksiyon sonrasi (asagida) uygulanir; burada
    // WinVals henuz hesaplanmadi (ComputeWindows projeksiyondan once
    // calisir), dolayisiyla cagrilmaz.
    // Ertelenen siralamada cozulecek anahtarlar SELECT alias'i olabilir.
    // Gercekten tanimsiz kolon F1-21 hatasi vermeye devam eder.
    if deferOrder then
      for i := 0 to Stmt.OrderBy.Count - 1 do
      begin
        if orderKeys[i] = '' then Continue;
        found := False;
        for j := 0 to High(colNames) do
        begin
          if SameText(colNames[j], orderKeys[i]) then
          begin found := True; Break; end;
          if (Pos('.', colNames[j]) > 0) and
             SameText(Copy(colNames[j], Pos('.', colNames[j]) + 1, MaxInt),
                      orderKeys[i]) then
          begin found := True; Break; end;
          if (Pos('.', orderKeys[i]) > 0) and
             SameText(Copy(orderKeys[i], Pos('.', orderKeys[i]) + 1, MaxInt),
                      colNames[j]) then
          begin found := True; Break; end;
        end;
        if found then Continue;
        for j := 0 to Stmt.Columns.Count - 1 do
          if (Stmt.Columns[j].Alias <> '') and
             SameText(Stmt.Columns[j].Alias, orderKeys[i]) then
          begin found := True; Break; end;
        if not found then
          raise EVDbException.Create(ecColumnNotFound,
            'ORDER BY bilinmeyen kolon: ' + orderKeys[i]);
      end;
    if not deferOrder then
    begin
      { H12: DISTINCT/pencere/QUALIFY/set-op yoksa ve LIMIT varsa
        yalniz LIMIT+OFFSET kadar satiri sec; tum kumeyi siralama. }
      if (Stmt.LimitVal >= 0) and (not Stmt.IsDistinct) and
         (not HasWindow(Stmt)) and (Stmt.QualifyClause = nil) and
         (Stmt.SetOp = sokNone) then
        DoSort(filteredRows, orderKeys, Stmt.OrderBy, colNames, colTypes,
          Stmt.LimitVal + Stmt.OffsetVal)
      else
        DoSort(filteredRows, orderKeys, Stmt.OrderBy, colNames, colTypes);
    end;
  end;
  // Projection
  if Stmt.Columns.Count = 0 then
  begin
    SetLength(outCols, Length(colNames));
    for i := 0 to High(colNames) do outCols[i] := colNames[i];
    outRows := filteredRows;
  end
  else
  begin
    SetLength(outCols, Stmt.Columns.Count);
    for i := 0 to Stmt.Columns.Count - 1 do
    begin
      if Stmt.Columns[i].Alias <> '' then outCols[i] := Stmt.Columns[i].Alias
      else if Stmt.Columns[i].Expr is TSqlColumnRefNode then
        outCols[i] := TSqlColumnRefNode(Stmt.Columns[i].Expr).ColumnName
      else if Stmt.Columns[i].Expr is TSqlWindowNode then
        outCols[i] := TSqlWindowNode(Stmt.Columns[i].Expr).FuncName
      else outCols[i] := 'col' + IntToStr(i + 1);
    end;
    SetLength(outRows, Length(filteredRows));
    // P5-WIN: pencere degerleri sorgu ORDER BY'sinden SONRA hesaplanir
    // (kendi ORDER BY'si bagimsizdir), asagida tuketilir.
    if HasWindow(Stmt) then
      ComputeWindows(Stmt, filteredRows, colNames, colTypes, WinVals, WinSlot);
    // F-09: QUALIFY â€” pencere hesaplandiktan SONRA, projeksiyondan ONCE
    if Stmt.QualifyClause <> nil then
      ApplyQualify(Stmt, filteredRows, colNames, colTypes, WinVals, WinSlot);
    // outRows uzunlugu kirpilan filteredRows ile eslesmeli
    SetLength(outRows, Length(filteredRows));
    for i := 0 to High(filteredRows) do
    begin
      SetLength(outRows[i], Stmt.Columns.Count);
      for j := 0 to Stmt.Columns.Count - 1 do
        if (j < Length(WinSlot)) and (WinSlot[j] >= 0) and
           (i < Length(WinVals)) and (WinSlot[j] < Length(WinVals[i])) then
          outRows[i][j] := WinVals[i][WinSlot[j]]
        else if Stmt.Columns[j].Expr is TSqlAggNode then
        begin
          // F-14/F-15: aggregate'siz SELECT'te tum tablo tek gruptur
          outRows[i][j] := '';
        end
        else
          outRows[i][j] := EvalExpr(Stmt.Columns[j].Expr, filteredRows[i], colNames, colTypes);
    end;
  end;

  // ORDER BY: alias (veya projeksiyonda olmayan) kolona gore ertelenmis
  // siralama. SQL standardi ORDER BY icin SELECT listesinde OLMAYAN
  // taban kolonlara da izin verir; bu yuzden gerekli kolonlar outRows'a
  // gecici olarak EKLENIR, siralama yapilir, sonra kirpilir.
  // `SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY v) AS rn
  // FROM w ORDER BY g, rn` icin once g, sonra rn uygulanir.
  if deferOrder then
  begin
    SetLength(orderKeys, Stmt.OrderBy.Count);
    for i := 0 to Stmt.OrderBy.Count - 1 do
    begin
      if Stmt.OrderBy[i].Expr is TSqlColumnRefNode then
        orderKeys[i] := TSqlColumnRefNode(Stmt.OrderBy[i].Expr).QualifiedName
      else orderKeys[i] := '';
    end;
    // eksik anahtarlari gecici kolon olarak ekle
    origCols := Length(outCols);
    for i := 0 to Stmt.OrderBy.Count - 1 do
    begin
      if orderKeys[i] = '' then Continue;
      found := False;
      for j := 0 to High(outCols) do
      begin
        if SameText(outCols[j], orderKeys[i]) then
        begin found := True; Break; end;
        if (Pos('.', outCols[j]) > 0) and
           SameText(Copy(outCols[j], Pos('.', outCols[j]) + 1, MaxInt),
                    orderKeys[i]) then
        begin found := True; Break; end;
        if (Pos('.', orderKeys[i]) > 0) and
           SameText(Copy(orderKeys[i], Pos('.', orderKeys[i]) + 1, MaxInt),
                    outCols[j]) then
        begin found := True; Break; end;
      end;
      if found then Continue;
      // SELECT listesinde olmayan TABAN kolonu: siralama icin gecici
      // eklenir (outRows[i] ile filteredRows[i] ayni siradir).
      baseIdx := -1;
      for j := 0 to High(colNames) do
      begin
        if SameText(colNames[j], orderKeys[i]) then
        begin baseIdx := j; Break; end;
        if (Pos('.', colNames[j]) > 0) and
           SameText(Copy(colNames[j], Pos('.', colNames[j]) + 1, MaxInt),
                    orderKeys[i]) then
        begin baseIdx := j; Break; end;
        if (Pos('.', orderKeys[i]) > 0) and
           SameText(Copy(orderKeys[i], Pos('.', orderKeys[i]) + 1, MaxInt),
                    colNames[j]) then
        begin baseIdx := j; Break; end;
      end;
      if baseIdx < 0 then
        raise EVDbException.Create(ecColumnNotFound,
          'ORDER BY bilinmeyen kolon: ' + orderKeys[i]);
      tmpSlot := Length(outCols);
      SetLength(outCols, tmpSlot + 1);
      SetLength(outTypes, tmpSlot + 1);
      outCols[tmpSlot] := orderKeys[i];
      if baseIdx < Length(colTypes) then outTypes[tmpSlot] := colTypes[baseIdx]
      else       outTypes[tmpSlot] := VCT_STR;
      for j := 0 to High(outRows) do
      begin
        SetLength(outRows[j], tmpSlot + 1);
        if (j <= High(filteredRows)) and (baseIdx <= High(filteredRows[j])) then
          outRows[j][tmpSlot] := filteredRows[j][baseIdx]
        else outRows[j][tmpSlot] := '';
      end;
    end;
    if (Stmt.LimitVal >= 0) and (not Stmt.IsDistinct) and
       (Stmt.SetOp = sokNone) then
      DoSort(outRows, orderKeys, Stmt.OrderBy, outCols, outTypes,
        Stmt.LimitVal + Stmt.OffsetVal)
    else
      DoSort(outRows, orderKeys, Stmt.OrderBy, outCols, outTypes);
    // gecici kolonlari kirp
    if origCols < Length(outCols) then
    begin
      SetLength(outCols, origCols);
      SetLength(outTypes, origCols);
      for i := 0 to High(outRows) do SetLength(outRows[i], origCols);
    end;
  end;

  // DISTINCT
  // F2-18: ONCEDEN TList + ic ice SameStrArr taramasi -> O(N^2). 100.000
  // tekil satirda ~5 milyar karsilastirma (saniyelerce). Artik O(1)
  // hash kova ile N. Ayrica sonuc satiri SINIRLANIR: tekilleÅŸtirme
  // biriken sayi sinirsiz oldugu icin bellek kucak doluyordu.
  if Stmt.IsDistinct then
  begin
    seenSet := TDictionary<string, Integer>.Create;
    try
      SetLength(distinctOut, 0);
      for i := 0 to High(outRows) do
      begin
        rowKey := RowEncodeKey(outRows[i]);
        if seenSet.ContainsKey(rowKey) then Continue;
        seenSet.Add(rowKey, 0);
        if Length(distinctOut) >= VDB_MAX_RESULT_ROWS then
          raise EVDbException.CreateFmt(ecLimit,
            'DISTINCT sonucu cok buyuk (>%d satir)', [VDB_MAX_RESULT_ROWS]);
        SetLength(distinctOut, Length(distinctOut) + 1);
        distinctOut[High(distinctOut)] := outRows[i];
      end;
      outRows := distinctOut;
    finally
      seenSet.Free;
    end;
  end;

  // OFFSET  (TryIndexOrder yolu OFFSET/LIMIT'i SATIR OKURKEN uyguladi)
  // F1-12: set-op'ta birlestirme sonrasina birakilir.
  if (not SkipOffsetLimit) and (not HasSetOp) and (Stmt.OffsetVal > 0) then
  begin
    if Stmt.OffsetVal < Length(outRows) then
    begin
      n := Length(outRows) - Stmt.OffsetVal;
      for i := 0 to n - 1 do outRows[i] := outRows[i + Stmt.OffsetVal];
      SetLength(outRows, n);
    end
    else SetLength(outRows, 0);
  end;

  // F1-20: projeksiyon cikti tipleri (UNION sonrasi ORDER BY icin gerekir)
  // M1: yalniz kolon referansi degil, tum ifadeler icin tip cikarilir.
  SetLength(outTypes, Length(outCols));
  for j := 0 to High(outCols) do outTypes[j] := VCT_STR;
  for j := 0 to Stmt.Columns.Count - 1 do
  begin
    if j > High(outTypes) then Break;
    outTypes[j] := ExprResultCtype(Stmt.Columns[j].Expr, colNames, colTypes);
  end;

  // LIMIT  (TryIndexOrder yolu LIMIT'i SATIR OKURKEN uyguladi)
  // F1-12: set-op'ta birlestirme sonrasina birakilir.
  if (not SkipOffsetLimit) and (not HasSetOp) and (Stmt.LimitVal >= 0) and
     (Length(outRows) > Stmt.LimitVal) then
    SetLength(outRows, Stmt.LimitVal);

  // SET OP
  if HasSetOp then
  begin
    MergeSetOpRows(Stmt, outRows, outCols);

    // F1-12: ORDER BY / OFFSET / LIMIT birlestirme SONRASINA uygulanir.
    // Once uygulansaydi sol taraf kirpilir, birlestirilen sonuc fazladan
    // satir donerdi.
    if (Stmt.OrderBy <> nil) and (Stmt.OrderBy.Count > 0) then
    begin
      SetLength(orderKeys, Stmt.OrderBy.Count);
      for i := 0 to Stmt.OrderBy.Count - 1 do
        if Stmt.OrderBy[i].Expr is TSqlColumnRefNode then
          orderKeys[i] := TSqlColumnRefNode(Stmt.OrderBy[i].Expr).QualifiedName
        else orderKeys[i] := '';
      DoSort(outRows, orderKeys, Stmt.OrderBy, outCols, outTypes);
    end;
    if Stmt.OffsetVal > 0 then
    begin
      if Stmt.OffsetVal < Length(outRows) then
      begin
        n := Length(outRows) - Stmt.OffsetVal;
        for i := 0 to n - 1 do outRows[i] := outRows[i + Stmt.OffsetVal];
        SetLength(outRows, n);
      end
      else SetLength(outRows, 0);
    end;
    if (Stmt.LimitVal >= 0) and (Length(outRows) > Stmt.LimitVal) then
      SetLength(outRows, Stmt.LimitVal);
  end;

  if Stmt.ForUpdate then LockSelectRows(Stmt);

  Res.Fields := outCols;
  Res.FieldTypes := outTypes;   // M1: gercek sonuc tipleri
  Res.Rows := outRows;
  Res.Affected := Length(outRows);
  Res.Msg := 'OK';
  finally
    FCurTable := '';
    FCurCollation := '';
    FExplicitColl := False;
    // FT.EndSnapshotRead;
  end;
end;

{ ------------------------------------------------------------
  ExecInsert
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecInsert(Stmt: TSqlInsertStmt; out Res: TSqlResult);
var
  i, j, rCount, ci, k: Integer;
  ov: string;
  strVals: array of string;
  cnames: array of string;
  allColNames: TStrArray;
  subRes: TSqlResult;
  td: TTableDef;
  setExprs: array of TSetExpr;
  onConflictAction: TOnConflictAction;
  outPk: string;
  outVals: TStrArray;
  returningColNames: TStrArray;
  returningRows: TStrMatrix;
  retRow: TStrArray;
  hasReturning: Boolean;
  setIdx: Integer;
  upsertSetExprs: array of TUpdateAssignment;
  upsertSetValues: TSetValuePairs;
  emptyArr1, emptyArr2: TStrArray;
  // R-04: RETURNING ifadelerinin dogru yorumlanmasi icin kolon tipleri
  colTypes: TByteArray;
  // F-33: VIEW desteği
  baseTable: string;
  viewColMap: TStrArray;
  mappedCols: array of string;
  // F-36: BEFORE trigger'dan donen duzenlenmis yeni satir
  NewRow: TStrArray;
  o1, o2: string;
  def: TTriggerDef;
  trNames: TStrArray;
  viewColNames: TStrArray;
begin

  SetLength(emptyArr1, 0);
  SetLength(emptyArr2, 0);
  rCount := 0;
  // F-33: View guncellenebilirlik kontrolü
  baseTable := '';
  viewColMap := nil;
  // F-36: INSTEAD OF INSERT -> orijinal DML iptal, tetikleyici govdesi calistirilir
  if FT.IsView(Stmt.Table) then
  begin
    trNames := FT.TriggersFor(Stmt.Table, Byte(Byte(ttInsteadOf)), Byte(Byte(teInsert)));
    if Length(trNames) > 0 then
    begin
      // view kolonlarinin adi (NEW.kolon cozumu icin)
      if Length(Stmt.Columns) > 0 then
      begin
        SetLength(viewColNames, Length(Stmt.Columns));
        for i := 0 to High(Stmt.Columns) do viewColNames[i] := Stmt.Columns[i];
      end
      else
      begin
        td := FT.GetTable(Stmt.Table);
        SetLength(viewColNames, Length(td.Cols));
        for i := 0 to High(td.Cols) do viewColNames[i] := td.Cols[i].Name;
      end;

      if Stmt.SelectSrc <> nil then
      begin
        // INSERT INTO view SELECT ... : SELECT sonuc satirlari NEW olur
        ExecSelect(Stmt.SelectSrc, subRes);
        for j := 0 to High(subRes.Rows) do
        begin
          NewRow := subRes.Rows[j];
          for i := 0 to High(trNames) do
          begin
            FT.GetTriggerDef(trNames[i], def);
            FireTriggerDef(def, Byte(Byte(ttInsteadOf)), Byte(Byte(teInsert)), nil, NewRow, viewColNames, Res);
          end;
          Inc(rCount);
        end;
      end
      else if Stmt.ValuesRows <> nil then
      begin
        // INSERT INTO view (cols) VALUES (...): VALUES degerleri NEW olur
        for j := 0 to Stmt.ValuesRows.Count - 1 do
        begin

          SetLength(strVals, 0);
          SetLength(strVals, Stmt.ValuesRows[j].Count);

          for k := 0 to Stmt.ValuesRows[j].Count - 1 do
            strVals[k] := EvalExpr(Stmt.ValuesRows[j][k], nil, nil, nil);

          NewRow := strVals;

          for i := 0 to High(trNames) do
          begin
            FT.GetTriggerDef(trNames[i], def);
            FireTriggerDef(def, Byte(Byte(ttInsteadOf)), Byte(Byte(teInsert)), nil, NewRow, viewColNames, Res);
          end;
          Inc(rCount);
        end;
      end;
      Exit;  // INSTEAD OF orijinal INSERT'i iptal etti, govde yeterlidir
    end;
  end;
  // F-33: guncellenemez view uzerine yazma reddedilir
  if (FT.IsView(Stmt.Table)) and
     (not AnalyzeViewUpdatable(Stmt.Table, baseTable, viewColMap)) then
    raise EVDbException.Create(ecUnsupported,
      'view uzerine INSERT yapilamaz (guncellenemez view): ' + Stmt.Table);
  if AnalyzeViewUpdatable(Stmt.Table, baseTable, viewColMap) then
  begin
    // View -> base table'a yeniden yaz
    Stmt.Table := baseTable;
    // Kolon eslemesi: view kolonlari -> base kolonlari
    if Length(Stmt.Columns) > 0 then
    begin
      SetLength(mappedCols, Length(Stmt.Columns));
      for i := 0 to High(Stmt.Columns) do
      begin
        ci := -1;
        for j := 0 to High(viewColMap) do
        begin
          // viewColMap format: "viewCol=baseCol"
          if SameText(Copy(viewColMap[j], 1, Pos('=', viewColMap[j]) - 1), Stmt.Columns[i]) then
          begin ci := j; Break; end;
        end;
        if ci >= 0 then
          mappedCols[i] := Copy(viewColMap[ci], Pos('=', viewColMap[ci]) + 1, MaxInt)
        else
          mappedCols[i] := Stmt.Columns[i]; // fallback
      end;
      Stmt.Columns := mappedCols;
    end;
    // SELECT FROM view için de base table'a yönlendir (INSERT ... SELECT)
    if Stmt.SelectSrc <> nil then
      Stmt.SelectSrc.FromTable := baseTable;
  end;

  td := FT.GetTable(Stmt.Table);
  // R-18: INSERT icin INSERT izni kontrol et
  FT.RequirePriv(Stmt.Table, Ord(pkInsert));
  // Build allColNames for RETURNING column lookups
  SetLength(allColNames, Length(td.Cols));
  for i := 0 to High(td.Cols) do allColNames[i] := td.Cols[i].Name;
  // R-04: RETURNING ifadeleri kolon TIPLERINI gerekir (sayisal toplama
  // metin birleştirme olarak yorumlanmasin). ExecInsert'te colTypes
  // daha once hic doldurulmadigi icin tip bilgisi hic gelmiyordu.
  BuildColInfo(td, allColNames, colTypes);
  if Length(Stmt.Columns) = 0 then
  begin
    { F-33: view hedefliyorsa view'in kolonlarini kullan, base table'in
      tum kolonlarini DEGIL. viewColMap'teki view kolon sayisi kadar. }
    if (baseTable <> '') and (Length(viewColMap) > 0) then
    begin
      SetLength(cnames, Length(viewColMap));
      for i := 0 to High(viewColMap) do
        cnames[i] := Copy(viewColMap[i], 1, Pos('=', viewColMap[i]) - 1);
    end
    else
    begin
      SetLength(cnames, Length(td.Cols));
      for i := 0 to High(td.Cols) do cnames[i] := td.Cols[i].Name;
    end;
  end
  else
  begin
    SetLength(cnames, Length(Stmt.Columns));
    for i := 0 to High(Stmt.Columns) do cnames[i] := Stmt.Columns[i];
  end;

  // F-33: INSERT view icin cnames base kolon adlari olmali
  if (baseTable <> '') and (Length(viewColMap) > 0) then
  begin
    SetLength(cnames, Length(viewColMap));
    for i := 0 to High(viewColMap) do
      cnames[i] := Copy(viewColMap[i], Pos('=', viewColMap[i]) + 1, MaxInt); // baseCol
  end;

  // R-04: RETURNING setup
  hasReturning := (Length(Stmt.ReturningCols) > 0) or (Stmt.ReturningExprs.Count > 0);
  if hasReturning then
  begin
    if Length(Stmt.ReturningCols) > 0 then
      returningColNames := Stmt.ReturningCols
    else
    begin
      SetLength(returningColNames, Length(td.Cols));
      for i := 0 to High(td.Cols) do returningColNames[i] := td.Cols[i].Name;
    end;
    SetLength(returningRows, 0);
  end;

  // R-03: ON CONFLICT action mapping
  onConflictAction := ocaNone;
  case Stmt.OnConflictAction of
    ocaDoNothing: onConflictAction := ocaDoNothing;
    ocaDoUpdate: onConflictAction := ocaDoUpdate;
  end;

  // F-36: BEFORE STATEMENT tetikleyiciler (tum satirlardan once, bir kez)
  FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, nil, [], Res, False);
  if Stmt.SelectSrc <> nil then
  begin
    // INSERT ... SELECT with optional ON CONFLICT
    ExecSelect(Stmt.SelectSrc, subRes);
    if onConflictAction = ocaNone then
    begin
      for i := 0 to High(subRes.Rows) do
      begin
        NewRow := subRes.Rows[i];
        FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, NewRow, cnames, Res, True);
        RlsRequireInsert(Stmt.Table, cnames, NewRow);   // R-19
        FT.Insert(Stmt.Table, cnames, NewRow);
        Inc(rCount);
        FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, NewRow, cnames, Res, True);
        if hasReturning then
        begin
          SetLength(retRow, Length(returningColNames));
          for j := 0 to High(returningColNames) do
          begin
            ci := -1;
            for setIdx := 0 to High(cnames) do
              if SameText(cnames[setIdx], returningColNames[j]) then
              begin ci := setIdx; Break; end;
            if ci >= 0 then
              retRow[j] := subRes.Rows[i][ci]
            else
              retRow[j] := '';
          end;
          SetLength(returningRows, Length(returningRows) + 1);
          returningRows[High(returningRows)] := retRow;
        end;
      end;
    end
    else
    begin
      // ON CONFLICT with INSERT ... SELECT
      // Convert TList<TUpdateAssignment> to array of TUpdateAssignment
      SetLength(upsertSetExprs, Stmt.OnConflictSetExprs.Count);
      for i := 0 to Stmt.OnConflictSetExprs.Count - 1 do
        upsertSetExprs[i] := Stmt.OnConflictSetExprs[i];

      // Build SET values for DO UPDATE (evaluate expressions once per row)
      // We'll build this inside the loop per row since expressions may reference EXCLUDED

      for i := 0 to High(subRes.Rows) do
      begin
        FExcludedRow := subRes.Rows[i];
        FExcludedColNames := cnames;
        // Build SET values for this row (expressions may reference EXCLUDED)
        SetLength(upsertSetValues, Stmt.OnConflictSetExprs.Count);
        BuildUpsertSetValues(Stmt, FExcludedRow, FExcludedColNames, allColNames, td, upsertSetValues);
        if FT.UpsertRowReturning(Stmt.Table, cnames, subRes.Rows[i],
          onConflictAction, Stmt.OnConflictTarget, upsertSetValues,
          outPk, outVals) then
        begin
          Inc(rCount);
          if hasReturning then
          begin
            // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
            // duz kolonlarda eski (hizli) yol korunur.
            if not MakeReturningRow(Stmt, outVals, allColNames, colTypes, retRow) then
            begin
              SetLength(retRow, Length(returningColNames));
              for j := 0 to High(returningColNames) do
              begin
                ci := FindColIdx(returningColNames[j], '', allColNames);
                if ci >= 0 then retRow[j] := outVals[ci];
              end;
            end;
            SetLength(returningRows, Length(returningRows) + 1);
            returningRows[High(returningRows)] := retRow;
          end;
        end;
      end;
    end;
  end
  else if Stmt.ValuesRows <> nil then
  begin
    // Prepare SET expressions for DO UPDATE (convert to TUpdateAssignment array)
    SetLength(upsertSetExprs, Stmt.OnConflictSetExprs.Count);
    for i := 0 to Stmt.OnConflictSetExprs.Count - 1 do
      upsertSetExprs[i] := Stmt.OnConflictSetExprs[i];

    if (Stmt.ValuesRows.Count > 1) and not FT.Kv.InBatch then
    begin
      FT.Kv.BeginBatch;
      try
        for i := 0 to Stmt.ValuesRows.Count - 1 do
        begin
          if Stmt.ValuesRows[i].Count = 0 then
          begin
            if onConflictAction = ocaNone then
            begin
              NewRow := [];
              FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, NewRow, cnames, Res, True);
              RlsRequireInsert(Stmt.Table, cnames, NewRow);   // R-19
              FT.Insert(Stmt.Table, [], NewRow);
              Inc(rCount);
              FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, NewRow, cnames, Res, True);
              if hasReturning then
              begin
                // INSERT () VALUES () - tum kolonlar DEFAULT/NULL
                SetLength(retRow, Length(returningColNames));
                for j := 0 to High(returningColNames) do
                  retRow[j] := '';
                SetLength(returningRows, Length(returningRows) + 1);
                returningRows[High(returningRows)] := retRow;
                FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, NewRow, cnames, Res, True);
              end;
            end
            else
            begin
              FExcludedRow := [];
              FExcludedColNames := [];
              SetLength(upsertSetValues, 0);
              if FT.UpsertRowReturning(Stmt.Table, emptyArr1, emptyArr2, onConflictAction,
                Stmt.OnConflictTarget, upsertSetValues,
                outPk, outVals) then
              begin
                Inc(rCount);
                if hasReturning then
                begin
                  // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
                  // duz kolonlarda eski (hizli) yol korunur.
                  if not MakeReturningRow(Stmt, outVals, allColNames, colTypes, retRow) then
                  begin
                    SetLength(retRow, Length(returningColNames));
                    for j := 0 to High(returningColNames) do
                    begin
                      ci := FindColIdx(returningColNames[j], '', allColNames);
                      if ci >= 0 then retRow[j] := outVals[ci];
                    end;
                  end;
                  SetLength(returningRows, Length(returningRows) + 1);
                  returningRows[High(returningRows)] := retRow;
                end;
              end;
            end;
          end
          else
          begin
            SetLength(strVals, Stmt.ValuesRows[i].Count);
            for j := 0 to Stmt.ValuesRows[i].Count - 1 do
              strVals[j] := EvalExpr(Stmt.ValuesRows[i][j], nil, nil, nil);
            if onConflictAction = ocaNone then
            begin
              // DIKKAT: RETURNING varsa ONCE eklenmemeli. Once
              // FT.Insert + sonra FT.InsertReturning cagriliyordu; ikinci
              // cagri ayni PK'yi tekrar ekledigi icin "duplicate PK: 7"
              // hatasi veriyordu (satir iki kez yaziliyordu).
              if hasReturning then
              begin
                // F-36: BEFORE ROW tetikleyiciler
                NewRow := strVals;
                FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, NewRow, cnames, Res, True);
                RlsRequireInsert(Stmt.Table, cnames, NewRow);   // R-19
                if FT.InsertReturning(Stmt.Table, cnames, NewRow, outPk, outVals) then
                begin
                  Inc(rCount);
                  // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
                  // duz kolonlarda eski (hizli) yol korunur.
                  if not MakeReturningRow(Stmt, outVals, allColNames, colTypes, retRow) then
                  begin
                    SetLength(retRow, Length(returningColNames));
                    for j := 0 to High(returningColNames) do
                    begin
                      ci := FindColIdx(returningColNames[j], '', allColNames);
                      if ci >= 0 then retRow[j] := outVals[ci];
                    end;
                  end;
                  SetLength(returningRows, Length(returningRows) + 1);
                  returningRows[High(returningRows)] := retRow;
                  FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, NewRow, cnames, Res, True);
                end;
              end
              else
              begin
                // F-36: BEFORE ROW tetikleyiciler
                NewRow := strVals;
                FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, NewRow, cnames, Res, True);
                RlsRequireInsert(Stmt.Table, cnames, NewRow);   // R-19
                FT.Insert(Stmt.Table, cnames, NewRow);
                Inc(rCount);
                FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, NewRow, cnames, Res, True);
              end;
            end
            else
            begin
              FExcludedRow := strVals;
              FExcludedColNames := cnames;
              RlsRequireInsert(Stmt.Table, cnames, strVals);   // R-19 (upsert)
              // Build SET values for this row
              SetLength(upsertSetValues, Stmt.OnConflictSetExprs.Count);
              BuildUpsertSetValues(Stmt, FExcludedRow, FExcludedColNames, allColNames, td, upsertSetValues);
              if FT.UpsertRowReturning(Stmt.Table, cnames, strVals,
                onConflictAction, Stmt.OnConflictTarget, upsertSetValues,
                outPk, outVals) then
              begin
                Inc(rCount);
                if hasReturning then
                begin
                  // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
                  // duz kolonlarda eski (hizli) yol korunur.
                  if not MakeReturningRow(Stmt, outVals, allColNames, colTypes, retRow) then
                  begin
                    SetLength(retRow, Length(returningColNames));
                    for j := 0 to High(returningColNames) do
                    begin
                      ci := FindColIdx(returningColNames[j], '', allColNames);
                      if ci >= 0 then retRow[j] := outVals[ci];
                    end;
                  end;
                  SetLength(returningRows, Length(returningRows) + 1);
                  returningRows[High(returningRows)] := retRow;
                end;
              end;
            end;
          end;
        end;
        FT.Kv.CommitBatch;
      except
        FT.AbortBatch;
        raise;
      end;
    end
    else
    begin
      for i := 0 to Stmt.ValuesRows.Count - 1 do
      begin
        if Stmt.ValuesRows[i].Count = 0 then
        begin
          if onConflictAction = ocaNone then
          begin
            NewRow := [];
            FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, NewRow, cnames, Res, True);
            FT.Insert(Stmt.Table, [], NewRow);
            Inc(rCount);
            FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, NewRow, cnames, Res, True);
            if hasReturning then
            begin
              SetLength(retRow, Length(returningColNames));
              for j := 0 to High(returningColNames) do retRow[j] := '';
              SetLength(returningRows, Length(returningRows) + 1);
              returningRows[High(returningRows)] := retRow;
            end;
          end
          else
          begin
            FExcludedRow := [];
            FExcludedColNames := [];
            SetLength(upsertSetValues, 0);
            if FT.UpsertRowReturning(Stmt.Table, emptyArr1, emptyArr2, onConflictAction,
              Stmt.OnConflictTarget, upsertSetValues,
              outPk, outVals) then
            begin
              Inc(rCount);
              if hasReturning then
              begin
                // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
                // duz kolonlarda eski (hizli) yol korunur.
                if not MakeReturningRow(Stmt, outVals, allColNames, colTypes, retRow) then
                begin
                  SetLength(retRow, Length(returningColNames));
                  for j := 0 to High(returningColNames) do
                  begin
                    ci := FindColIdx(returningColNames[j], '', allColNames);
                    if ci >= 0 then retRow[j] := outVals[ci];
                  end;
                end;
                SetLength(returningRows, Length(returningRows) + 1);
                returningRows[High(returningRows)] := retRow;
              end;
            end;
          end;
        end
        else
        begin
          SetLength(strVals, Stmt.ValuesRows[i].Count);
          for j := 0 to Stmt.ValuesRows[i].Count - 1 do
            strVals[j] := EvalExpr(Stmt.ValuesRows[i][j], nil, nil, nil);
          if onConflictAction = ocaNone then
          begin
            // DIKKAT: RETURNING varsa ONCE eklenmemeli (bkz. bir ustteki
            // ayni hatanin ikinci kopyasi). Once FT.Insert, sonra
            // FT.InsertReturning -> ayni PK iki kez yaziliyordu.
            if hasReturning then
            begin
              // F-36: BEFORE ROW tetikleyiciler
              NewRow := strVals;
              FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, NewRow, cnames, Res, True);
              RlsRequireInsert(Stmt.Table, cnames, NewRow);   // R-19
              if FT.InsertReturning(Stmt.Table, cnames, NewRow, outPk, outVals) then
              begin
                Inc(rCount);
                // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
                // duz kolonlarda eski (hizli) yol korunur.
                if not MakeReturningRow(Stmt, outVals, allColNames, colTypes, retRow) then
                begin
                  SetLength(retRow, Length(returningColNames));
                  for j := 0 to High(returningColNames) do
                  begin
                    ci := FindColIdx(returningColNames[j], '', allColNames);
                    if ci >= 0 then retRow[j] := outVals[ci];
                  end;
                end;
                SetLength(returningRows, Length(returningRows) + 1);
                returningRows[High(returningRows)] := retRow;
              end;
            end
            else
            begin
              // F-36: BEFORE ROW tetikleyiciler
              NewRow := strVals;
              FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teInsert), nil, NewRow, cnames, Res, True);
              RlsRequireInsert(Stmt.Table, cnames, NewRow);   // R-19
              FT.Insert(Stmt.Table, cnames, NewRow);
              Inc(rCount);
              FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, NewRow, cnames, Res, True);
            end;
          end
          else
          begin
            FExcludedRow := strVals;
            FExcludedColNames := cnames;
            RlsRequireInsert(Stmt.Table, cnames, strVals);   // R-19 (upsert)
            SetLength(upsertSetValues, Stmt.OnConflictSetExprs.Count);
            BuildUpsertSetValues(Stmt, FExcludedRow, FExcludedColNames, allColNames, td, upsertSetValues);
            if FT.UpsertRowReturning(Stmt.Table, cnames, strVals,
              onConflictAction, Stmt.OnConflictTarget, upsertSetValues,
              outPk, outVals) then
            begin
              Inc(rCount);
              if hasReturning then
              begin
                // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
                // duz kolonlarda eski (hizli) yol korunur.
                if not MakeReturningRow(Stmt, outVals, allColNames, colTypes, retRow) then
                begin
                  SetLength(retRow, Length(returningColNames));
                  for j := 0 to High(returningColNames) do
                  begin
                    ci := FindColIdx(returningColNames[j], '', allColNames);
                    if ci >= 0 then retRow[j] := outVals[ci];
                  end;
                end;
                SetLength(returningRows, Length(returningRows) + 1);
                returningRows[High(returningRows)] := retRow;
              end;
            end;
          end;
        end;
      end;
    end;
  end;

  // F-36: AFTER STATEMENT tetikleyiciler (tum satirlardan sonra, bir kez)
  FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teInsert), nil, nil, [], Res, False);

  // R-04: RETURNING - sonuclari Res'e aktar
  if hasReturning then
  begin
    SetLength(Res.Fields, Length(returningColNames));
    for i := 0 to High(returningColNames) do Res.Fields[i] := returningColNames[i];
    Res.Rows := returningRows;
  end;

  Res.Affected := rCount;
  Res.LastTable := Stmt.Table;
  Res.Msg := 'OK';
end;

{ ------------------------------------------------------------
  P-18c (2026-10-16) - ExecFastLiteralInsert (bkz. sinif bildirimi)
  Lexer/AST/parse-maliyeti (~12 µs) + AST dugüm tahsislerini atlar.
  Literallerin STRING sonucu genel yolla birebir olmak ZORUNDADIR
  (VDbAst TSqlLiteralNode karsiligi):
    kanonik tamsayi  -> metin ayni (IntToStr tur-donum kimligi)
    'abc' / 'a''b'   -> tirnaksiz/kaçışsız ham metin (NextToken kuralı)
    NULL             -> ''  (EvalExpr de sltNull icin '' doner)
    TRUE / FALSE     -> 'True' / 'False' (CreateBool StrVal'i)
  Sayi bictimindeki HER turlu sapma (0 basamak, float, karsilikli,
  +isaret, tasma) False => genel yol ayni metni ayni sekilde
  uretir. Tarayici YANLIZ kabul/ret karar verir; motor hatasi
  uretmez — tek istisna kaynagi RequirePriv/RLS/FT.Insert.
  //---------------------------------------------------------- }
function TVSqlExecutor.ExecFastLiteralInsert(const Sql: string;
  out Res: TSqlResult): Boolean;
var
  n, p, nc, nv, cap: Integer;
  s, tbl: string;
  cnames, vals: TStrArray;
  td: TTableDef;
  fv: Double;   // P-18c: float literal kanoniklestirme (VDbParseFloat)
  // H13 (2026-10-18): cok-satirli VALUES icin satirlar
  rows: array of TStrArray;
  nrows, expNv, bi, bi2: Integer;

  procedure SkipWs;
  begin
    while (p <= n) and (Sql[p] in [' ', #9, #10, #13]) do Inc(p);
  end;

  function WordChar(c: Char): Boolean;
  begin
    Result := (c in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$']);
  end;

  { Kw BÜYÜK harf olmali; eslesme sonrasi kelime-karakteri gelmemeli
    ('INSERTION' INSERT ile baslamaz sayilir). }
  function MatchKw(const Kw: string): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    SkipWs;
    if p + Length(Kw) - 1 > n then Exit;
    for k := 1 to Length(Kw) do
      if UpCase(Sql[p + k - 1]) <> Kw[k] then Exit;
    if (p + Length(Kw) <= n) and WordChar(Sql[p + Length(Kw)]) then Exit;
    Inc(p, Length(Kw));
    Result := True;
  end;

  { Ham tanimlayici (buyuk/kucuk harf KORUNUR — genel yol da ham token
    saklar, normalizasyonu tablo katmani yapar). Tirnakh/tivitli/dot'lu
    tanimlayici TANI MAZ: ret -> genel yol. }
  function ReadIdent(out S: string): Boolean;
  var
    st: Integer;
  begin
    Result := False;
    SkipWs;
    if p > n then Exit;
    if not (Sql[p] in ['A'..'Z', 'a'..'z', '_']) then Exit;
    st := p;
    while (p <= n) and WordChar(Sql[p]) do Inc(p);
    S := Copy(Sql, st, p - st);
    Result := True;
  end;

  function ReadLiteral(out S: string): Boolean;
  var
    st: Integer;
    w: string;
  begin
    Result := False;
    S := '';
    SkipWs;
    if p > n then Exit;

    if Sql[p] = '''' then
    begin
      // String literali: NextToken ile BIREBIR ('' -> tek tirnak).
      Inc(p);
      st := p;
      while p <= n do
      begin
        if Sql[p] = '''' then
        begin
          if (p < n) and (Sql[p + 1] = '''') then
          begin
            S := S + Copy(Sql, st, p - st) + '''';
            Inc(p, 2);
            st := p;
            Continue;
          end;
          S := S + Copy(Sql, st, p - st);
          Inc(p);
          Result := True;
          Exit;
        end;
        Inc(p);
      end;
      Exit;   // kapanmamis string -> genel yol AYNI hatayi uretir
    end;

    // Sayi: kanonik tamsayi VEYA '.'-lic FLOAT. Float'ta genel yolun
    // YAPTIGI BIREBIR yapilir: token metni VDbParseFloat -> StrVal =
    // VDbFloatToStr(fv) (TSqlLiteralNode.CreateFloat). '-' genel yolda
    // ayri token + CreateFloat(-fv) idi; burada işaret metne dahil —
    // VDbParseFloat('-5.5') == -VDbParseFloat('5.5) oldugundan StrVal
    // ayni. Karsilikli (e/E) kabul; +isaret, 0-basamak ('05'),
    // '5.'-virgulSOnu, tasma: RET -> genel yol ayni sonucu uretir.
    st := p;
    if (Sql[p] = '-') and (p < n) and (Sql[p + 1] in ['1'..'9']) then Inc(p)
    else if not (Sql[p] in ['0'..'9']) then Exit;
    if Sql[p] = '0' then
    begin
      Inc(p);
      if (p <= n) and (Sql[p] in ['0'..'9']) then Exit;  // 05 -> genel yol
    end
    else
      while (p <= n) and (Sql[p] in ['0'..'9']) do Inc(p);
    if (p < n) and (Sql[p] = '.') and (Sql[p + 1] in ['0'..'9']) then
    begin
      Inc(p);
      while (p <= n) and (Sql[p] in ['0'..'9']) do Inc(p);
      if (p <= n) and ((Sql[p] = 'E') or (Sql[p] = 'e')) then
      begin
        Inc(p);
        if (p <= n) and ((Sql[p] = '+') or (Sql[p] = '-')) then Inc(p);
        if (p > n) or not (Sql[p] in ['0'..'9']) then Exit;
        while (p <= n) and (Sql[p] in ['0'..'9']) do Inc(p);
      end;
      if (p <= n) and WordChar(Sql[p]) then Exit;
      if not VDbParseFloat(Copy(Sql, st, p - st), fv) then Exit;
      S := VDbFloatToStr(fv);
      Result := True;
      Exit;
    end;
    if (p <= n) and ((Sql[p] = '.') or WordChar(Sql[p]) or
       (Sql[p] = 'E') or (Sql[p] = 'e')) then Exit;      // float/us/tasma...
    S := Copy(Sql, st, p - st);
    Result := True;
    Exit;
  end;

  { Kelime literalleri: NULL/TRUE/FALSE; baska her kelime ret.
    Karsilastirma genel yolla ayni UstCase (UpperCase) uzerinden. }
  function ReadWordLit(out S: string): Boolean;
  var
    st: Integer;
    w: string;
  begin
    Result := False;
    S := '';
    SkipWs;
    if p > n then Exit;
    if not (Sql[p] in ['A'..'Z', 'a'..'z']) then Exit;
    st := p;
    while (p <= n) and WordChar(Sql[p]) do Inc(p);
    w := UpperCase(Copy(Sql, st, p - st));
    if w = 'NULL'  then begin S := '';      Result := True end
    else if w = 'TRUE'  then begin S := 'True';  Result := True end
    else if w = 'FALSE' then begin S := 'False'; Result := True end;
  end;

  function ReadValue(out S: string): Boolean;
  var
    save: Integer;
  begin
    // ReadLiteral sayi kuyrugunda ret ile ayrilirken p'yi ilerletmis
    // olabilir ('12TRUE' tek lexer token'idir ve genel yol onu STRING
    // sayar): basarisizlikta konum GERI alinir, seri ret edilir.
    save := p;
    if ReadLiteral(S) then Exit(True);
    p := save;
    Result := ReadWordLit(S);
    if not Result then p := save;
  end;

begin
  Result := False;
  n := Length(Sql);
  p := 1;

  // ---- Bicim tanima (hiçbir motor durumuna dokunmaz) ----
  if not MatchKw('INSERT') then Exit;
  if not MatchKw('INTO') then Exit;
  if not ReadIdent(tbl) then Exit;
  SetLength(cnames, 0);
  nc := 0;
  SkipWs;
  if (p <= n) and (Sql[p] = '(') then
  begin
    Inc(p);
    repeat
      if not ReadIdent(s) then Exit;
      SetLength(cnames, nc + 1);
      cnames[nc] := s;
      Inc(nc);
      SkipWs;
      if (p <= n) and (Sql[p] = ',') then begin Inc(p); Continue; end;
      Break;
    until False;
    if (p > n) or (Sql[p] <> ')') then Exit;
    Inc(p);
  end;
  if not MatchKw('VALUES') then Exit;
  // H13: cok-satirli VALUES '(v,..),(v,..),..' — parse BIR KEZ, AST yok.
  // Bos tuple '()' genel yola birakilir (ReadValue basarisiz -> Exit).
  nrows := 0;
  expNv := -1;
  repeat
    SkipWs;
    if (p > n) or (Sql[p] <> '(') then Exit;
    Inc(p);
    SetLength(vals, 8);
    cap := 8;
    nv := 0;
    repeat
      if not ReadValue(s) then Exit;
      if nv >= cap then begin cap := cap * 2; SetLength(vals, cap); end;
      vals[nv] := s;
      Inc(nv);
      SkipWs;
      if (p <= n) and (Sql[p] = ',') then begin Inc(p); Continue; end;
      Break;
    until False;
    if (p > n) or (Sql[p] <> ')') then Exit;
    Inc(p);
    if nv = 0 then Exit;                  // '()' -> genel yol
    SetLength(vals, nv);
    if expNv < 0 then expNv := nv
    else if nv <> expNv then Exit;        // satirlar arasi deger sayisi farkli -> genel
    SetLength(rows, nrows + 1);
    rows[nrows] := vals;
    Inc(nrows);
    SkipWs;
    if (p <= n) and (Sql[p] = ',') then begin Inc(p); Continue; end;
    Break;
  until False;
  if p <= n then Exit;      // RETURNING / ON CONFLICT / ';' / kuyruk
  nv := expNv;

  // ---- Semantik kapilar: gecilirse genel yolun ayni sirasi ayni hata ----
  if not FT.TableExists(tbl) then Exit;   // genel: 'tablo bulunamadi'
  if FT.IsView(tbl) then Exit;            // view kurallari genel yolda
  // INSERT tetikleyicileri (STATEMENT + ROW, BEFORE + AFTER) genel yolun
  // FireTriggers cagri noktalaridir; biri bile varsa serit kapanir.
  if Length(FT.TriggersFor(tbl, Byte(ttBefore), Byte(teInsert))) > 0 then Exit;
  if Length(FT.TriggersFor(tbl, Byte(ttAfter),  Byte(teInsert))) > 0 then Exit;
  if nc = 0 then
  begin
    // Kolon listesi yok: genel yoldaki gibi tum tablo kolonlari.
    td := FT.GetTable(tbl);
    if nv <> Length(td.Cols) then Exit;   // sayi farki: genel hata
    SetLength(cnames, Length(td.Cols));
    for nc := 0 to High(td.Cols) do cnames[nc] := td.Cols[nc].Name;
  end
  else if nc <> nv then Exit;             // (kolon listesi + deger sayisi)
  // R-18 izin: genel yolun cagirdigi AYNI metot, AYNI sira (cumle basina bir kez).
  FT.RequirePriv(tbl, Ord(pkInsert));

  if nrows = 1 then
  begin
    // Tek satir: eski hizli serit davranisi (batch YOK).
    // R-19 RLS: genel yolun cagirdigi AYNI metot.
    RlsRequireInsert(tbl, cnames, rows[0]);
    // PK/UNIQUE/NOT NULL/CHECK/AutoInc/FK denetimleri FT.Insert icerisinde.
    FT.Insert(tbl, cnames, rows[0]);
  end
  else
  begin
    // Cok satir: genel yol ile ayni ATOMIKLIK (batch yoksa tumu icin ac).
    bi := 0;
    if not FT.Kv.InBatch then
    begin
      FT.Kv.BeginBatch;
      bi := 1;
    end;
    try
      for bi2 := 0 to nrows - 1 do
      begin
        RlsRequireInsert(tbl, cnames, rows[bi2]);   // R-19
        FT.Insert(tbl, cnames, rows[bi2]);
      end;
      if bi = 1 then FT.Kv.CommitBatch;
    except
      if bi = 1 then FT.AbortBatch;
      raise;
    end;
  end;

  Res.Affected := nrows;
  Res.LastTable := tbl;
  Res.Msg := 'OK';
  SetLength(Res.Fields, 0);
  SetLength(Res.Rows, 0);
  Result := True;
end;

function TVSqlExecutor.ExecFastCopy(const Sql: string;
  out Res: TSqlResult): Boolean;
type
  TCopyBoolArr = array of Boolean;
var
  n, p: Integer;
  tbl, path, alt: string;
  cnames: TStrArray;
  td: TTableDef;
  fmt, nullStr: string;
  delim, quoteCh: Char;
  delimSet, nullSet, header, inParen: Boolean;
  quoteSet: Boolean;
  fsh: TFileStream;
  buf: array[0..131071] of Byte;
  bPos, bLen: Integer;
  atEof: Boolean;
  pbBuf: array[0..7] of Char;
  pbN: Integer;
  row: TStrArray;
  rowQ: TCopyBoolArr;
  fbuf: string;
  flen: Integer;
  lineNo: Int64;
  total: Int64;
  i: Integer;
  ownBatch: Boolean;
  hasInsTrig: Boolean;
  cn, opt, val: string;
  isTo: Boolean;
  useMem: Boolean;
  memRows: TStrMatrix;
  memIdx, memTotal, k, ci, d, src: Integer;
  aFields: TStrArray;
  aTypes: TByteArray;
  aErr: string;
  mapIdx: TIntArray;
  usedSrc: array of Boolean;
  pks: TStrArray;
  allRows: TStrMatrix;
  outRows: TStrMatrix;
  byName: Boolean;
  stype, ttype: Byte;
  wrote, readOk: Boolean;

  procedure SkipWs;
  begin
    while (p <= n) and (Sql[p] in [' ', #9, #10, #13]) do Inc(p);
  end;

  function WordChar(c: Char): Boolean;
  begin
    Result := (c in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$']);
  end;

  function MatchKw(const Kw: string): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    SkipWs;
    if p + Length(Kw) - 1 > n then Exit;
    for k := 1 to Length(Kw) do
      if UpCase(Sql[p + k - 1]) <> Kw[k] then Exit;
    if (p + Length(Kw) <= n) and WordChar(Sql[p + Length(Kw)]) then Exit;
    Inc(p, Length(Kw));
    Result := True;
  end;

  { Tanimlayici: duz kelime veya "cift tirnakli" ("" kacisi). }
  function ReadIdent(out S: string): Boolean;
  var
    st: Integer;
  begin
    Result := False;
    S := '';
    SkipWs;
    if p > n then Exit;
    if Sql[p] = '"' then
    begin
      Inc(p);
      st := p;
      while p <= n do
      begin
        if Sql[p] = '"' then
        begin
          if (p < n) and (Sql[p + 1] = '"') then
          begin
            S := S + Copy(Sql, st, p - st) + '"';
            Inc(p, 2);
            st := p;
          end
          else
          begin
            S := S + Copy(Sql, st, p - st);
            Inc(p);
            Exit(True);
          end;
        end
        else Inc(p);
      end;
      Exit;
    end;
    if not (Sql[p] in ['A'..'Z', 'a'..'z', '_']) then Exit;
    st := p;
    while (p <= n) and WordChar(Sql[p]) do Inc(p);
    S := Copy(Sql, st, p - st);
    Result := True;
  end;

  { Tek tirnakli string; '' -> ' kacisi. }
  function ReadStr(out S: string): Boolean;
  var
    st: Integer;
  begin
    Result := False;
    S := '';
    SkipWs;
    if (p > n) or (Sql[p] <> '''') then Exit;
    Inc(p);
    st := p;
    while p <= n do
    begin
      if Sql[p] = '''' then
      begin
        if (p < n) and (Sql[p + 1] = '''') then
        begin
          S := S + Copy(Sql, st, p - st) + '''';
          Inc(p, 2);
          st := p;
        end
        else
        begin
          S := S + Copy(Sql, st, p - st);
          Inc(p);
          Exit(True);
        end;
      end
      else Inc(p);
    end;
  end;

  function ReadOptVal(out S: string): Boolean;
  var
    st: Integer;
  begin
    Result := False;
    S := '';
    SkipWs;
    if p > n then Exit;
    if Sql[p] = '''' then Exit(ReadStr(S));
    if Sql[p] = '"' then Exit(ReadIdent(S));
    if not (Sql[p] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '\', '/', '.']) then Exit;
    st := p;
    while (p <= n) and
          (Sql[p] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '\', '/', '.']) do
      Inc(p);
    S := Copy(Sql, st, p - st);
    Result := True;
  end;

  function ParseBoolVal(const S: string): Boolean;
  begin
    Result := SameText(S, 'TRUE') or SameText(S, 'YES') or
              SameText(S, 'ON') or (S = '1');
  end;

  { --- dosya okuyucu (256 KB tampon, tek gecis) --- }
  function NextCh(out c: Char): Boolean;
  begin
    if pbN > 0 then
    begin
      Dec(pbN);
      c := pbBuf[pbN];
      Exit(True);
    end;
    if bPos >= bLen then
    begin
      if atEof then Exit(False);
      bLen := fsh.Read(buf, SizeOf(buf));
      bPos := 0;
      if bLen <= 0 then
      begin
        atEof := True;
        Exit(False);
      end;
    end;
    c := Char(buf[bPos]);
    Inc(bPos);
    Result := True;
  end;

  procedure PushCh(c: Char);
  begin
    if pbN <= High(pbBuf) then
    begin
      pbBuf[pbN] := c;
      Inc(pbN);
    end;
  end;

  procedure FieldAdd(c: Char);
  begin
    if flen >= Length(fbuf) then
      SetLength(fbuf, flen * 2 + 256);
    Inc(flen);
    fbuf[flen] := c;
  end;

  { Tirnakli alan: kapanis tirnagini ve ardindan gelen sonlandiriciyi
    okur. Bozuk girdide (kapanis sonrasi bitisik metin) kalan karakterler
    alana eklenir; satir kaybi olmaz. }
  function ReadQuotedTerm(var Term: Char): Boolean;
  var
    cc, nn: Char;
  begin
    while NextCh(cc) do
    begin
      if cc = quoteCh then
      begin
        if NextCh(nn) then
        begin
          if nn = quoteCh then
          begin
            FieldAdd(quoteCh);
            Continue;
          end;
          if (nn = delim) or (nn = #10) or (nn = #13) then
          begin
            Term := nn;
            Exit(True);
          end;
          FieldAdd(nn);
          Continue;
        end
        else Exit(False);
      end;
      FieldAdd(cc);
    end;
    Result := False;
  end;

  function ReadRecord: Boolean;
  var
    c: Char;
    q, hasC: Boolean;
  begin
    SetLength(row, 0);
    SetLength(rowQ, 0);
    // Tamamen bos satirlari atla (tek kolonlu tabloda bos satir = NULL
    // satiri degil; belirsizligi onlemek icin atlanir).
    repeat
      if not NextCh(c) then Exit(False);
    until (c <> #10) and (c <> #13);
    hasC := True;
    while True do
    begin
      flen := 0;
      q := False;
      if (fmt <> 'text') and hasC and (c = quoteCh) then
      begin
        q := True;
        hasC := ReadQuotedTerm(c);
      end
      else
      begin
        while hasC and (c <> delim) and (c <> #10) and (c <> #13) do
        begin
          if (fmt = 'text') and (c = '\') then
          begin
            if NextCh(c) then
            begin
              case c of
                't': FieldAdd(#9);
                'n': FieldAdd(#10);
                'r': FieldAdd(#13);
                'b': FieldAdd(#8);
                'f': FieldAdd(#12);
                'v': FieldAdd(#11);
                '\': FieldAdd('\');
              else
                FieldAdd('\');
                FieldAdd(c);
              end;
              hasC := NextCh(c);
            end
            else hasC := False;
          end
          else
          begin
            FieldAdd(c);
            hasC := NextCh(c);
          end;
        end;
      end;
      SetLength(row, Length(row) + 1);
      row[High(row)] := Copy(fbuf, 1, flen);
      SetLength(rowQ, Length(rowQ) + 1);
      rowQ[High(rowQ)] := q;
      if not hasC then Break;
      if c = delim then
      begin
        hasC := NextCh(c);
        if not hasC then
        begin
          SetLength(row, Length(row) + 1);
          row[High(row)] := '';
          SetLength(rowQ, Length(rowQ) + 1);
          rowQ[High(rowQ)] := False;
          Break;
        end;
        Continue;
      end;
      // Satir sonu (CRLF / LF / CR)
      if c = #13 then
        if NextCh(c) and (c <> #10) then PushCh(c);
      Break;
    end;
    Inc(lineNo);
    Result := True;
  end;

begin
  Result := False;
  p := 1;
  n := Length(Sql);
  if not MatchKw('COPY') then Exit;

  // Buradan itibaren cumle bize ait: hatalar ecSyntaxError ile bildirilir.
  Result := True;
  Res.Affected := 0;
  Res.Msg := '';
  Res.LastTable := '';
  Res.Stmts := 1;
  SetLength(Res.Fields, 0);
  SetLength(Res.Rows, 0);

  fmt := 'csv';
  delim := ',';
  quoteCh := '"';
  nullStr := '';
  delimSet := False;
  nullSet := False;
  header := False;
  quoteSet := False;
  SetLength(cnames, 0);

  if not ReadIdent(tbl) then
    raise EVDbException.Create(ecSyntaxError, 'COPY: tablo adi bekleniyordu');

  SkipWs;
  if (p <= n) and (Sql[p] = '(') then
  begin
    Inc(p);
    while True do
    begin
      if not ReadIdent(cn) then
        raise EVDbException.Create(ecSyntaxError, 'COPY: kolon adi bekleniyordu');
      SetLength(cnames, Length(cnames) + 1);
      cnames[High(cnames)] := cn;
      SkipWs;
      if (p <= n) and (Sql[p] = ',') then Inc(p)
      else if (p <= n) and (Sql[p] = ')') then
      begin
        Inc(p);
        Break;
      end
      else
        raise EVDbException.Create(ecSyntaxError, 'COPY: kolon listesi kapatilmadi');
    end;
  end;

  if MatchKw('FROM') then
    isTo := False
  else if MatchKw('TO') then
    isTo := True
  else
    raise EVDbException.Create(ecSyntaxError, 'COPY: FROM veya TO bekleniyordu');
  if not ReadStr(path) then
    raise EVDbException.Create(ecSyntaxError, 'COPY: dosya yolu (string) bekleniyordu');

  // --- Secenekler: [WITH] [(] ... [)] ---
  SkipWs;
  MatchKw('WITH');
  SkipWs;
  inParen := False;
  if (p <= n) and (Sql[p] = '(') then
  begin
    Inc(p);
    inParen := True;
  end;
  while True do
  begin
    SkipWs;
    if p > n then Break;
    if inParen and (Sql[p] = ')') then
    begin
      Inc(p);
      Break;
    end;
    if not ReadIdent(opt) then
      raise EVDbException.Create(ecSyntaxError, 'COPY: secenek adi bekleniyordu');
    opt := UpperCase(opt);
    SkipWs;
    if (p <= n) and (Sql[p] = '=') then
    begin
      Inc(p);
      SkipWs;
    end;
    if opt = 'HEADER' then
    begin
      if (p > n) or (Sql[p] in [',', ')']) then
        header := True
      else
      begin
        if not ReadOptVal(val) then
          raise EVDbException.Create(ecSyntaxError, 'COPY: HEADER degeri bekleniyordu');
        header := ParseBoolVal(val);
      end;
    end
    else
    begin
      if not ReadOptVal(val) then
        raise EVDbException.CreateFmt(ecSyntaxError,
          'COPY: %s degeri bekleniyordu', [opt]);
      if opt = 'FORMAT' then
      begin
        fmt := LowerCase(val);
        if (fmt <> 'csv') and (fmt <> 'text') and (fmt <> 'arrow') and
           (fmt <> 'parquet') then
          raise EVDbException.Create(ecUnsupported,
            'COPY: yalniz FORMAT CSV, TEXT, ARROW veya PARQUET destekleniyor: ' + val);
      end
      else if opt = 'DELIMITER' then
      begin
        if Length(val) <> 1 then
          raise EVDbException.Create(ecInvalidArgument,
            'COPY: DELIMITER tek karakter olmali');
        delim := val[1];
        delimSet := True;
      end
      else if opt = 'NULL' then
      begin
        nullStr := val;
        nullSet := True;
      end
      else if opt = 'QUOTE' then
      begin
        if Length(val) <> 1 then
          raise EVDbException.Create(ecInvalidArgument,
            'COPY: QUOTE tek karakter olmali');
        quoteCh := val[1];
        quoteSet := True;
      end
      else if opt = 'ESCAPE' then
      begin
        // CSV kacis karakteri desteklenmiyor; kabul edilip yok sayilir.
      end
      else
        raise EVDbException.Create(ecUnsupported,
          'COPY: bilinmeyen secenek: ' + opt);
    end;
    SkipWs;
    if (p <= n) and (Sql[p] = ',') then Inc(p)
    else if inParen then
    begin
      if (p <= n) and (Sql[p] = ')') then
      begin
        Inc(p);
        Break;
      end;
      raise EVDbException.Create(ecSyntaxError, 'COPY: secenek listesi kapatilmadi');
    end;
  end;
  SkipWs;
  if p <= n then
    raise EVDbException.Create(ecSyntaxError,
      'COPY: beklenmeyen ifade: ' + Copy(Sql, p, 40));

  if not delimSet then
  begin
    if fmt = 'text' then delim := #9 else delim := ',';
  end;
  if not nullSet then
  begin
    if fmt = 'text' then nullStr := '\N' else nullStr := '';
  end;

  if (fmt = 'arrow') or (fmt = 'parquet') then
  begin
    if header or delimSet or nullSet or quoteSet then
      raise EVDbException.Create(ecUnsupported,
        'COPY ' + UpperCase(fmt) + ': HEADER/DELIMITER/NULL/QUOTE kullanilamaz');
  end
  else if isTo then
    raise EVDbException.Create(ecUnsupported,
      'COPY TO yalniz FORMAT ARROW veya PARQUET ile destekleniyor');

  // --- Dosya / tablo ---
  if not isTo then
  begin
    if not FileExists(path) then
    begin
      alt := '';
      if FT.Kv.FilePath <> '' then
        alt := IncludeTrailingPathDelimiter(ExtractFileDir(FT.Kv.FilePath)) + path;
      if (alt <> '') and FileExists(alt) then
        path := alt
      else
        raise EVDbException.Create(ecNotFound, 'COPY: dosya bulunamadi: ' + path);
    end;
  end
  else
  begin
    if (ExtractFileDir(path) = '') and (FT.Kv.FilePath <> '') then
      path := IncludeTrailingPathDelimiter(ExtractFileDir(FT.Kv.FilePath)) + path;
    if not DirectoryExists(ExtractFileDir(path)) then
      raise EVDbException.Create(ecNotFound,
        'COPY: hedef dizin bulunamadi: ' + ExtractFileDir(path));
  end;

  if not FT.TableExists(tbl) then
    raise EVDbException.Create(ecNotFound, 'COPY: tablo bulunamadi: ' + tbl);
  if FT.IsView(tbl) then
    raise EVDbException.Create(ecUnsupported,
      'COPY: view uzerine toplu yukleme desteklenmiyor: ' + tbl);
  td := FT.GetTable(tbl);
  if Length(cnames) = 0 then
  begin
    SetLength(cnames, Length(td.Cols));
    for i := 0 to High(td.Cols) do
      cnames[i] := td.Cols[i].Name;
  end;
  if isTo then
    FT.RequirePriv(tbl, Ord(pkSelect))
  else
    FT.RequirePriv(tbl, Ord(pkInsert));

  if (fmt = 'arrow') or (fmt = 'parquet') then
  begin
    if isTo then
    begin
      // Tabloyu Arrow/Parquet kolonlarina esle ve dosyaya yaz.
      SetLength(aFields, Length(cnames));
      SetLength(aTypes, Length(cnames));
      SetLength(mapIdx, Length(cnames));
      for i := 0 to High(cnames) do
      begin
        ci := -1;
        for k := 0 to High(td.Cols) do
          if SameText(td.Cols[k].Name, cnames[i]) then
          begin
            ci := k;
            Break;
          end;
        if ci < 0 then
          raise EVDbException.Create(ecNotFound,
            'COPY ' + UpperCase(fmt) + ': kolon bulunamadi: ' + cnames[i]);
        aFields[i] := td.Cols[ci].Name;
        aTypes[i] := td.Cols[ci].Ctype;
        mapIdx[i] := ci;
      end;
      FT.ScanRows(td.Name, pks, allRows);
      SetLength(outRows, Length(allRows));
      for k := 0 to High(allRows) do
      begin
        SetLength(outRows[k], Length(cnames));
        for i := 0 to High(cnames) do
          outRows[k][i] := allRows[k][mapIdx[i]];
      end;
      if fmt = 'arrow' then
        wrote := VDbArrowExport(path, aFields, aTypes, outRows, aErr)
      else
        wrote := VDbParquetExport(path, aFields, aTypes, outRows, aErr);
      if not wrote then
        raise EVDbException.Create(ecInvalidArgument,
          'COPY ' + UpperCase(fmt) + ' yazma hatasi: ' + aErr);
      Res.Affected := Length(outRows);
      Res.LastTable := tbl;
      Res.Msg := IntToStr(Length(outRows)) + ' satir';
      Result := True;
      Exit;
    end;

    if fmt = 'arrow' then
      readOk := VDbArrowImport(path, aFields, aTypes, memRows, aErr)
    else
      readOk := VDbParquetImport(path, aFields, aTypes, memRows, aErr);
    if not readOk then
      raise EVDbException.Create(ecInvalidArgument,
        'COPY ' + UpperCase(fmt) + ' okuma hatasi: ' + aErr);
    if Length(aFields) <> Length(cnames) then
      raise EVDbException.Create(ecInvalidArgument,
        Format('COPY %s: dosyada %d alan var, %d kolon bekleniyordu',
          [UpperCase(fmt), Length(aFields), Length(cnames)]));

    // Once ada gore esle; olmazsa siraya gore.
    SetLength(mapIdx, Length(cnames));
    SetLength(usedSrc, Length(aFields));
    byName := True;
    for d := 0 to High(cnames) do
    begin
      src := -1;
      for k := 0 to High(aFields) do
        if (not usedSrc[k]) and SameText(aFields[k], cnames[d]) then
        begin
          src := k;
          Break;
        end;
      if src < 0 then
      begin
        byName := False;
        Break;
      end;
      mapIdx[d] := src;
      usedSrc[src] := True;
    end;
    if not byName then
      for d := 0 to High(cnames) do
        mapIdx[d] := d;

    for d := 0 to High(cnames) do
    begin
      ci := -1;
      for k := 0 to High(td.Cols) do
        if SameText(td.Cols[k].Name, cnames[d]) then
        begin
          ci := k;
          Break;
        end;
      if ci < 0 then
        raise EVDbException.Create(ecNotFound,
          'COPY ' + UpperCase(fmt) + ': kolon bulunamadi: ' + cnames[d]);
      stype := aTypes[mapIdx[d]];
      ttype := td.Cols[ci].Ctype;
      if not ((stype = ttype) or (ttype = VCT_STR) or
              ((stype = VCT_INT) and (ttype = VCT_FLOAT))) then
        raise EVDbException.Create(ecInvalidArgument,
          Format('COPY %s: %s kolonunda tip uyusmuyor (dosya=%d, tablo=%d)',
            [UpperCase(fmt), cnames[d], stype, ttype]));
    end;

    SetLength(outRows, Length(memRows));
    for k := 0 to High(memRows) do
    begin
      SetLength(outRows[k], Length(cnames));
      for d := 0 to High(cnames) do
        outRows[k][d] := memRows[k][mapIdx[d]];
    end;
    memRows := outRows;
    useMem := True;
    memIdx := 0;
    memTotal := Length(memRows);
  end;

  fsh := nil;
  if not useMem then
    fsh := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    // UTF-8 BOM varsa atla (yoksa basa don).
    if (not useMem) and (fsh.Size >= 3) then
    begin
      fsh.Read(buf, 3);
      if not ((buf[0] = $EF) and (buf[1] = $BB) and (buf[2] = $BF)) then
        fsh.Position := 0;
    end;
    bPos := 0;
    bLen := 0;
    atEof := False;
    pbN := 0;
    flen := 0;
    SetLength(fbuf, 256);
    lineNo := 0;
    total := 0;

    if (not useMem) and header then
    begin
      if ReadRecord and (Length(row) <> Length(cnames)) then
        raise EVDbException.CreateFmt(ecInvalidArgument,
          'COPY %s:%d: baslikta %d alan var, %d bekleniyordu',
          [path, lineNo, Length(row), Length(cnames)]);
    end;

    // Tetikleyici meta verisi COPY boyunca degismez: bir kez bak, yoksa
    // satir basina iki FireTriggers cagrisini tamamen atla (sicak yol).
    hasInsTrig :=
      (Length(FT.TriggersFor(tbl, Byte(ttBefore), Byte(teInsert))) > 0) or
      (Length(FT.TriggersFor(tbl, Byte(ttAfter), Byte(teInsert))) > 0);
    if hasInsTrig then
      FireTriggers(tbl, Byte(ttBefore), Byte(teInsert), nil, nil, [], Res, False);
    ownBatch := not FT.Kv.InBatch;
    if ownBatch then FT.BeginBatch;
    try
      while True do
      begin
        if useMem then
        begin
          if memIdx >= memTotal then Break;
          row := Copy(memRows[memIdx], 0, Length(memRows[memIdx]));
          Inc(memIdx);
          lineNo := memIdx;
          SetLength(rowQ, Length(row));
          for k := 0 to High(rowQ) do
            rowQ[k] := False;
        end
        else if not ReadRecord then Break;
        if Length(row) <> Length(cnames) then
          raise EVDbException.CreateFmt(ecInvalidArgument,
            'COPY %s:%d: %d alan bekleniyordu, %d bulundu',
            [path, lineNo, Length(cnames), Length(row)]);
        for i := 0 to High(row) do
          if (not rowQ[i]) and (row[i] = nullStr) then
            row[i] := '';
        try
          if hasInsTrig then
            FireTriggers(tbl, Byte(ttBefore), Byte(teInsert),
              nil, row, cnames, Res, True);
          RlsRequireInsert(tbl, cnames, row);
          FT.Insert(tbl, cnames, row);
          Inc(total);
          if hasInsTrig then
            FireTriggers(tbl, Byte(ttAfter), Byte(teInsert),
              nil, row, cnames, Res, True);
        except
          on e: EVDbException do
            raise EVDbException.Create(e.ErrorCode,
              Format('COPY %s satir %d: %s', [path, lineNo, e.Message]));
        end;
      end;
      if ownBatch then FT.CommitBatch;
    except
      if ownBatch then
        try FT.AbortBatch; except end;
      raise;
    end;
    if hasInsTrig then
      FireTriggers(tbl, Byte(ttAfter), Byte(teInsert), nil, nil, [], Res, False);
  finally
    if fsh <> nil then fsh.Free;
  end;

  Res.Affected := total;
  Res.LastTable := tbl;
  Res.Msg := IntToStr(total) + ' satir';
  SetLength(Res.Fields, 0);
  SetLength(Res.Rows, 0);
end;

function TVSqlExecutor.ExecFastPointSelect(const Sql: string;
  out Res: TSqlResult): Boolean;
var
  n, p, nc, i, ci: Integer;
  s, tbl, pkCol, pkVal: string;
  cnames: TStrArray;
  colMap: TIntArray;
  td: TTableDef;
  rowVals: TStrArray;

  procedure SkipWs;
  begin
    while (p <= n) and (Sql[p] in [' ', #9, #10, #13]) do Inc(p);
  end;

  function WordChar(c: Char): Boolean;
  begin
    Result := (c in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$']);
  end;

  function MatchKw(const Kw: string): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    SkipWs;
    if p + Length(Kw) - 1 > n then Exit;
    for k := 1 to Length(Kw) do
      if UpCase(Sql[p + k - 1]) <> Kw[k] then Exit;
    if (p + Length(Kw) <= n) and WordChar(Sql[p + Length(Kw)]) then Exit;
    Inc(p, Length(Kw));
    Result := True;
  end;

  function ReadIdent(out S: string): Boolean;
  var
    st: Integer;
  begin
    Result := False;
    SkipWs;
    if p > n then Exit;
    if not (Sql[p] in ['A'..'Z', 'a'..'z', '_']) then Exit;
    st := p;
    while (p <= n) and WordChar(Sql[p]) do Inc(p);
    S := Copy(Sql, st, p - st);
    Result := True;
  end;

  function ReadLit(out S: string): Boolean;
  var
    st: Integer;
  begin
    Result := False;
    S := '';
    SkipWs;
    if p > n then Exit;
    if Sql[p] = '''' then
    begin
      Inc(p);
      st := p;
      while p <= n do
      begin
        if Sql[p] = '''' then
        begin
          if (p < n) and (Sql[p + 1] = '''') then
          begin
            S := S + Copy(Sql, st, p - st) + '''';
            Inc(p, 2);
            st := p;
          end
          else
          begin
            S := S + Copy(Sql, st, p - st);
            Inc(p);
            Result := True;
            Exit;
          end;
        end
        else
          Inc(p);
      end;
      Exit;
    end;
    if Sql[p] in ['0'..'9', '-', '+'] then
    begin
      st := p;
      if Sql[p] in ['-', '+'] then Inc(p);
      while (p <= n) and (Sql[p] in ['0'..'9']) do Inc(p);
      if (p <= n) and WordChar(Sql[p]) then Exit;
      S := Copy(Sql, st, p - st);
      Result := True;
    end;
  end;

begin
  Result := False;
  n := Length(Sql);
  p := 1;

  // 1. SELECT ile baslamali
  if not MatchKw('SELECT') then Exit;

  // 2. Kolon listesi
  SetLength(cnames, 0);
  nc := 0;
  SkipWs;
  if (p <= n) and (Sql[p] = '*') then
  begin
    Inc(p);
    // '*' tum kolonlar demek; cnames bos kalacak
  end
  else
  begin
    repeat
      if not ReadIdent(s) then Exit;
      SetLength(cnames, nc + 1);
      cnames[nc] := s;
      Inc(nc);
      SkipWs;
      if (p <= n) and (Sql[p] = ',') then begin Inc(p); Continue; end;
      Break;
    until False;
  end;

  // 3. FROM <table>
  if not MatchKw('FROM') then Exit;
  if not ReadIdent(tbl) then Exit;

  // 4. WHERE <pk_col> = <pk_val>
  if not MatchKw('WHERE') then Exit;
  if not ReadIdent(pkCol) then Exit;
  SkipWs;
  if (p > n) or (Sql[p] <> '=') then Exit;
  Inc(p);
  if not ReadLit(pkVal) then Exit;

  SkipWs;
  // Fazladan sozcuk (ORDER, LIMIT, GROUP, AND vb.) varsa serit ret eder
  if p <= n then Exit;

  // Semantik kontroller
  if not FT.TableExists(tbl) then Exit;
  if FT.IsView(tbl) then Exit;
  if FT.RlsApplies(tbl) then Exit; // RLS varsa genel yol filtrelesin

  td := FT.GetTable(tbl);
  if td.PkIndex < 0 then Exit; // PK'si olmayan tablo
  if VDbNorm(td.Cols[td.PkIndex].Name) <> VDbNorm(pkCol) then Exit; // kosul PK kolonu uzerinde degil

  // Kolon haritasi
  if Length(cnames) = 0 then
  begin
    // '*' durumu
    SetLength(colMap, Length(td.Cols));
    SetLength(Res.Fields, Length(td.Cols));
    for i := 0 to High(td.Cols) do
    begin
      colMap[i] := i;
      Res.Fields[i] := td.Cols[i].Name;
    end;
  end
  else
  begin
    SetLength(colMap, Length(cnames));
    SetLength(Res.Fields, Length(cnames));
    for i := 0 to High(cnames) do
    begin
      ci := -1;
      for n := 0 to High(td.Cols) do
        if VDbNorm(td.Cols[n].Name) = VDbNorm(cnames[i]) then
        begin ci := n; Break; end;
      if ci < 0 then Exit; // kolon bulunamadiysa genel yol hata uretsin
      colMap[i] := ci;
      Res.Fields[i] := td.Cols[ci].Name;
    end;
  end;

  // Dogrudan tekil okuma (AST yok, Parser yok, Executor yok)
  if FT.ReadRow(td.Name, pkVal, rowVals) then
  begin
    SetLength(Res.Rows, 1);
    SetLength(Res.Rows[0], Length(colMap));
    for i := 0 to High(colMap) do
      Res.Rows[0][i] := rowVals[colMap[i]];
    Res.Affected := 1;
  end
  else
  begin
    SetLength(Res.Rows, 0);
    Res.Affected := 0;
  end;

  Res.LastTable := td.Name;
  Res.Msg := 'OK';
  Res.Stmts := 1;
  Result := True;
end;

{ ------------------------------------------------------------
  ExecUpdate - AST WHERE filtreli, expression-based SET
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecUpdate(Stmt: TSqlUpdateStmt; out Res: TSqlResult);
var
  td: TTableDef;
  pks: TStrArray;
  allRows: TStrMatrix;
  colNames: TStrArray;
  colTypes: TByteArray;
  i, j, ci, setIdx, rCount: Integer;
  k: Integer;
  o1, o2: string;
  newVals: TStrArray;
  allColNames: TStrArray;
  returningColNames: TStrArray;
  returningRows: TStrMatrix;
  retRow: TStrArray;
  hasReturning: Boolean;
  // F-33: VIEW desteği
  baseTable: string;
  viewColMap: TStrArray;
  mappedAssignments: TList<TUpdateAssignment>;
  Asgn: TUpdateAssignment;
  originalAssignments: TList<TUpdateAssignment>;
begin
  // F-33: View guncellenebilirlik kontrolü
  baseTable := '';
  viewColMap := nil;
  if (FT.IsView(Stmt.Table)) and
     (not AnalyzeViewUpdatable(Stmt.Table, baseTable, viewColMap)) then
    raise EVDbException.Create(ecUnsupported,
      'view uzerine UPDATE yapilamaz (guncellenemez view): ' + Stmt.Table);
  if AnalyzeViewUpdatable(Stmt.Table, baseTable, viewColMap) then
  begin
    Stmt.Table := baseTable;
    // SET atamalarını base kolonlarına çevir (viewColMap: "viewCol=baseCol")
    originalAssignments := Stmt.Assignments;
    mappedAssignments := TList<TUpdateAssignment>.Create;
      for i := 0 to Stmt.Assignments.Count - 1 do
      begin
        ci := -1;
        for j := 0 to High(viewColMap) do
        begin
          if SameText(Copy(viewColMap[j], 1, Pos('=', viewColMap[j]) - 1), Stmt.Assignments[i].ColName) then
          begin ci := j; Break; end;
        end;
        if ci >= 0 then
          begin
            Asgn.ColName := Copy(viewColMap[ci], Pos('=', viewColMap[ci]) + 1, MaxInt);
            Asgn.Expr := Stmt.Assignments[i].Expr;
            mappedAssignments.Add(Asgn);
          end
        else
          mappedAssignments.Add(Stmt.Assignments[i]);
      end;
      Stmt.Assignments := mappedAssignments;
    originalAssignments.Free;
    // WHERE clause'daki kolon adlarini da duzelt (basit durum: nitelikli degil)
  end;

  // F-33: WHERE clause view -> base kolonlarini cevir
  if viewColMap <> nil then
    Stmt.WhereClause := TransformViewColsToBase(Stmt.WhereClause, viewColMap);

  td := FT.GetTable(Stmt.Table);
  // R-18: UPDATE icin UPDATE izni
  FT.RequirePriv(Stmt.Table, Ord(pkUpdate));
  BuildColInfo(td, colNames, colTypes);
  // F1-16: bilinmeyen SET kolonu sessizce atlanmaz. Atlanirsa satir
  // silinip aynen yazilir, rCount yanlis cikar.
  for j := 0 to Stmt.Assignments.Count - 1 do
  begin
    ci := -1;
    for setIdx := 0 to High(colNames) do
      if SameText(colNames[setIdx], Stmt.Assignments[j].ColName) then
      begin ci := setIdx; Break; end;
    if ci < 0 then
      raise EVDbException.Create(ecColumnNotFound,
        'UPDATE: bilinmeyen kolon: ' + Stmt.Assignments[j].ColName);
  end;

  // R-04: RETURNING setup
  hasReturning := (Length(Stmt.ReturningCols) > 0) or (Stmt.ReturningExprs.Count > 0);
  if hasReturning then
  begin
    // R-04: listede gercek IFADE varsa sema ifade sayisina gore kurulur
    // ve satirlar EvaluateReturning ile degerlendirilir.
    if ReturningHasExpr(Stmt) then
      BuildReturningNames(Stmt, returningColNames)
    else if Length(Stmt.ReturningCols) > 0 then
      returningColNames := Stmt.ReturningCols
    else
    begin
      SetLength(returningColNames, Length(td.Cols));
      for i := 0 to High(td.Cols) do returningColNames[i] := td.Cols[i].Name;
    end;
    SetLength(returningRows, 0);
  end;

  { Once her zaman FT.ScanRows -> 100.000 satirlik tabloda tek bir
    "UPDATE ... WHERE id = 5" ~1 saniye suruyordu. Simdi once adaylar
    daraltilir (PK nokta / indeks dilimi); bulunamazsa tam tarama. }
  if not NarrowRows(td, Stmt.WhereClause, colNames, colTypes, pks, allRows) then
    // R-13 Full: partition pruning (UPDATE/DELETE taramalari da kullanir)
    FT.ScanRowsPart(Stmt.Table, pks, allRows, PartTargetsOf(td, Stmt.WhereClause));

  SetLength(allColNames, Length(td.Cols));
  for i := 0 to High(td.Cols) do allColNames[i] := td.Cols[i].Name;

  rCount := 0;
  // F1-4 (tamamlayici): SQL UPDATE artik Delete+Insert YAPMIYOR.
  // Onceki yol "ON DELETE CASCADE"i yanlis tetikliyordu: ilgisiz bir
  // kolonu guncellerken bile cocuk satirlari SILINIYORDU. Satir mantigi
  // TVTableDb.UpdateRowInPlace'e tasindi (UpdateWhere ile ortak).
  // Ayrica PK kolonu SET edilemez (satir anahtari degismez).
  for j := 0 to Stmt.Assignments.Count - 1 do
    for setIdx := 0 to High(colNames) do
      if SameText(colNames[setIdx], Stmt.Assignments[j].ColName) then
        // F2-22: PkIndex<0 ise PK tanimlanmamis; koruma yok.
        if (td.PkIndex >= 0) and (setIdx = td.PkIndex) then
          raise EVDbException.Create(ecUnsupported,
            'UPDATE: PK kolonu guncellenemez: ' + colNames[setIdx]);


  if not FT.Kv.InBatch then
  begin
    FT.Kv.BeginBatch;
    try
      for i := 0 to High(allRows) do
      begin

        if not RowMatches(Stmt.WhereClause, allRows[i], colNames, colTypes) then Continue;
        // R-19: gorunmeyen satir guncellenemez (USING)
        if not RlsRowVisible(Stmt.Table, 3, allRows[i], colNames, colTypes) then Continue;
        SetLength(newVals, Length(td.Cols));
        for j := 0 to High(td.Cols) do newVals[j] := allRows[i][j];
        for j := 0 to Stmt.Assignments.Count - 1 do
        begin
          ci := -1;
          for setIdx := 0 to High(colNames) do
            if SameText(colNames[setIdx], Stmt.Assignments[j].ColName) then
            begin ci := setIdx; Break; end;
          if ci >= 0 then
            newVals[ci] := EvalExpr(TSqlExprNode(Stmt.Assignments[j].Expr), allRows[i], colNames, colTypes);
        end;
        // R-19: yeni satir WITH CHECK'ten gecmeli
        if not RlsCheckRow(Stmt.Table, 3, newVals, colNames, colTypes) then
          raise EVDbException.CreateFmt(ecPermissionDenied,
            'RLS politika ihlali: rol "%s" tablo "%s" icin bu satiri yazamaz',
            [FT.CurrentRole, Stmt.Table]);
        // F-36: BEFORE UPDATE ROW tetikleyiciler (NEW degisikliklerini FireTriggerDef isler)
        FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teUpdate),
          allRows[i], newVals, colNames, Res, True);
        if FT.UpdateRowInPlace(Stmt.Table, pks[i], newVals) then
        begin
          Inc(rCount);
          if hasReturning then
          begin
            // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
            // duz kolonlarda eski (hizli) yol korunur.
            if not MakeReturningRow(Stmt, newVals, allColNames, colTypes, retRow) then
            begin
              SetLength(retRow, Length(returningColNames));
              for j := 0 to High(returningColNames) do
              begin
                ci := FindColIdx(returningColNames[j], '', allColNames);
                if ci >= 0 then retRow[j] := newVals[ci];
              end;
            end;
            SetLength(returningRows, Length(returningRows) + 1);
            returningRows[High(returningRows)] := retRow;
          end;
        end;
        // F-36: AFTER UPDATE ROW tetikleyiciler
        FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teUpdate),
          allRows[i], newVals, colNames, Res, True);
      end;
      FT.Kv.CommitBatch;
      // F-36: AFTER UPDATE STATEMENT tetikleyiciler (tum satirlardan sonra)
      FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teUpdate), nil, nil, [], Res, False);
    except
      FT.AbortBatch;
      raise;
    end;
  end
  else
  begin
    for i := 0 to High(allRows) do
    begin
      if not RowMatches(Stmt.WhereClause, allRows[i], colNames, colTypes) then Continue;
      // R-19: gorunmeyen satir guncellenemez (USING)
      if not RlsRowVisible(Stmt.Table, 3, allRows[i], colNames, colTypes) then Continue;
      SetLength(newVals, Length(td.Cols));
      for j := 0 to High(td.Cols) do newVals[j] := allRows[i][j];
      for j := 0 to Stmt.Assignments.Count - 1 do
      begin
        ci := -1;
        for setIdx := 0 to High(colNames) do
          if SameText(colNames[setIdx], Stmt.Assignments[j].ColName) then
          begin ci := setIdx; Break; end;
        if ci >= 0 then
          newVals[ci] := EvalExpr(TSqlExprNode(Stmt.Assignments[j].Expr), allRows[i], colNames, colTypes);
      end;
      // R-19: yeni satir WITH CHECK'ten gecmeli
      if not RlsCheckRow(Stmt.Table, 3, newVals, colNames, colTypes) then
        raise EVDbException.CreateFmt(ecPermissionDenied,
          'RLS politika ihlali: rol "%s" tablo "%s" icin bu satiri yazamaz',
          [FT.CurrentRole, Stmt.Table]);
      // F-36: BEFORE UPDATE ROW tetikleyiciler (NEW degisikliklerini FireTriggerDef isler)
      FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teUpdate),
        allRows[i], newVals, colNames, Res, True);
      if FT.UpdateRowInPlace(Stmt.Table, pks[i], newVals) then
      begin
        Inc(rCount);
        if hasReturning then
        begin
          // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
          // duz kolonlarda eski (hizli) yol korunur.
          if not MakeReturningRow(Stmt, newVals, allColNames, colTypes, retRow) then
          begin
            SetLength(retRow, Length(returningColNames));
            for j := 0 to High(returningColNames) do
            begin
              ci := FindColIdx(returningColNames[j], '', allColNames);
              if ci >= 0 then retRow[j] := newVals[ci];
            end;
          end;
          SetLength(returningRows, Length(returningRows) + 1);
          returningRows[High(returningRows)] := retRow;
        end;
      end;
      // F-36: AFTER UPDATE ROW tetikleyiciler
      FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teUpdate),
        allRows[i], newVals, colNames, Res, True);
    end;
      // F-36: AFTER UPDATE STATEMENT tetikleyiciler (tum satirlardan sonra)
      FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teUpdate), nil, nil, [], Res, False);
  end;

  // R-04: RETURNING - sonuclari Res'e aktar
  if hasReturning then
  begin
    SetLength(Res.Fields, Length(returningColNames));
    for i := 0 to High(returningColNames) do Res.Fields[i] := returningColNames[i];
    Res.Rows := returningRows;
  end;

  Res.Affected := rCount;
  Res.LastTable := Stmt.Table;
  Res.Msg := 'OK';
end;

{ ------------------------------------------------------------
  ExecDelete - AST WHERE filtreli
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecDelete(Stmt: TSqlDeleteStmt; out Res: TSqlResult);
var
  td: TTableDef;
  pks: TStrArray;
  allRows: TStrMatrix;
  allColNames: TStrArray;
  colNames: TStrArray;
  colTypes: TByteArray;
  i, j, rCount, ci: Integer;
  k: Integer;
  o1, o2: string;
  toDelete: TList<Integer>;
  toDeleteRows: TStrMatrix;
  returningColNames: TStrArray;
  returningRows: TStrMatrix;
  retRow: TStrArray;
  hasReturning: Boolean;
  // F-33: VIEW desteği
  baseTable: string;
  viewColMap: TStrArray;
begin
  // F-33: View guncellenebilirlik kontrolü
  baseTable := '';
  viewColMap := nil;
  if (FT.IsView(Stmt.Table)) and
     (not AnalyzeViewUpdatable(Stmt.Table, baseTable, viewColMap)) then
    raise EVDbException.Create(ecUnsupported,
      'view uzerine DELETE yapilamaz (guncellenemez view): ' + Stmt.Table);
  if AnalyzeViewUpdatable(Stmt.Table, baseTable, viewColMap) then
  begin
    Stmt.Table := baseTable;
    // WHERE clause kolonları view kolonlarından base kolonlarına çevrilmeli
    // (Basit: exec içinde RowMatches zaten base tablo kolonları kullanıyor)
  end;

  // F-33: WHERE clause view -> base kolonlarini cevir
  if viewColMap <> nil then
    Stmt.WhereClause := TransformViewColsToBase(Stmt.WhereClause, viewColMap);

  td := FT.GetTable(Stmt.Table);
  // R-18: DELETE icin DELETE izni.
  { NOT: Burada pkUpdate kontrol ediliyordu -> bir role yalnizca
    UPDATE izni verilse DELETE de gecermis oluyordu (yetki atlama).
    pkDELETE zorunlu. }
  FT.RequirePriv(Stmt.Table, Ord(pkDelete));
  BuildColInfo(td, colNames, colTypes);
  // Build allColNames for RETURNING column lookups
  SetLength(allColNames, Length(td.Cols));
  for i := 0 to High(td.Cols) do allColNames[i] := td.Cols[i].Name;

  // R-04: RETURNING setup
  hasReturning := (Length(Stmt.ReturningCols) > 0) or (Stmt.ReturningExprs.Count > 0);
  if hasReturning then
  begin
    if Length(Stmt.ReturningCols) > 0 then
      returningColNames := Stmt.ReturningCols
    else
    begin
      SetLength(returningColNames, Length(td.Cols));
      for i := 0 to High(td.Cols) do returningColNames[i] := td.Cols[i].Name;
    end;
    SetLength(returningRows, 0);
  end;

  { Once her zaman tam tarama: "DELETE ... WHERE id = 5" 100.000 satirlik
    tabloda ~1 saniye suruyordu. Simdi PK nokta / indeks dilimi denenir. }
  if not NarrowRows(td, Stmt.WhereClause, colNames, colTypes, pks, allRows) then
    // R-13 Full: partition pruning (UPDATE/DELETE taramalari da kullanir)
    FT.ScanRowsPart(Stmt.Table, pks, allRows, PartTargetsOf(td, Stmt.WhereClause));

  toDelete := TList<Integer>.Create;
  if hasReturning then
    SetLength(toDeleteRows, 0);
  try
    for i := 0 to High(allRows) do
      if RowMatches(Stmt.WhereClause, allRows[i], colNames, colTypes) and
         RlsRowVisible(Stmt.Table, 4, allRows[i], colNames, colTypes) then   // R-19
      begin
        toDelete.Add(i);
        if hasReturning then
        begin
          SetLength(toDeleteRows, Length(toDeleteRows) + 1);
          toDeleteRows[High(toDeleteRows)] := Copy(allRows[i], 0, Length(allRows[i]));
        end;
      end;

    rCount := toDelete.Count;
    if rCount > 0 then
    begin
      if not FT.Kv.InBatch then
      begin
        FT.Kv.BeginBatch;
        try
          for i := 0 to toDelete.Count - 1 do
          begin

            // F-36: BEFORE DELETE ROW tetikleyiciler (satir silinmeden once)
            FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teDelete),
              allRows[toDelete[i]], nil, allColNames, Res, True);
            FT.Delete(Stmt.Table, pks[toDelete[i]]);
            // F-36: AFTER DELETE ROW tetikleyiciler (satir silindikten sonra)
            FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teDelete),
              allRows[toDelete[i]], nil, allColNames, Res, True);
          end;
          FT.Kv.CommitBatch;
          // F-36: AFTER DELETE STATEMENT tetikleyiciler (tum satirlardan sonra)
          FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teDelete), nil, nil, [], Res, False);
        except
          FT.AbortBatch;
          raise;
        end;
      end
      else
      begin
        for i := 0 to toDelete.Count - 1 do
        begin
          // F-36: BEFORE DELETE ROW tetikleyiciler (satir silinmeden once)
          FireTriggers(Stmt.Table, Byte(ttBefore), Byte(teDelete),
            allRows[toDelete[i]], nil, allColNames, Res, True);
          FT.Delete(Stmt.Table, pks[toDelete[i]]);
          // F-36: AFTER DELETE ROW tetikleyiciler (satir silindikten sonra)
          FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teDelete),
            allRows[toDelete[i]], nil, allColNames, Res, True);
        end;
        // F-36: AFTER DELETE STATEMENT tetikleyiciler (tum satirlardan sonra)
        FireTriggers(Stmt.Table, Byte(ttAfter), Byte(teDelete), nil, nil, [], Res, False);
      end;
    end;
  finally
    toDelete.Free;
  end;

  // R-04: RETURNING - silinen satir degerlerini dondur
  if hasReturning then
  begin
    for i := 0 to High(toDeleteRows) do
    begin
      // R-04: listede gercek IFADE varsa EvaluateReturning devreye girer;
      // duz kolonlarda eski (hizli) yol korunur.
      if not MakeReturningRow(Stmt, toDeleteRows[i], allColNames, colTypes, retRow) then
      begin
        SetLength(retRow, Length(returningColNames));
        for j := 0 to High(returningColNames) do
        begin
          ci := FindColIdx(returningColNames[j], '', allColNames);
          if ci >= 0 then retRow[j] := toDeleteRows[i][ci];
        end;
      end;
      SetLength(returningRows, Length(returningRows) + 1);
      returningRows[High(returningRows)] := retRow;
    end;
    SetLength(Res.Fields, Length(returningColNames));
    for i := 0 to High(returningColNames) do Res.Fields[i] := returningColNames[i];
    Res.Rows := returningRows;
  end;

  Res.Affected := rCount;
  Res.LastTable := Stmt.Table;
  Res.Msg := 'OK';
end;

function FindColInArr(const Cols: array of TColDef; const ColName: string): Integer;
var i: Integer;
begin
  for i := 0 to High(Cols) do
    if SameText(Cols[i].Name, ColName) then Exit(i);
  Result := -1;
end;

function AndWhereGroups(const A, B: TWhereGroups): TWhereGroups;
var x, y, q, z: Integer;
begin
  if Length(A) = 0 then Exit(B);
  if Length(B) = 0 then Exit(A);
  SetLength(Result, Length(A) * Length(B));
  z := 0;
  for x := 0 to High(A) do
    for y := 0 to High(B) do
    begin
      SetLength(Result[z], Length(A[x]) + Length(B[y]));
      for q := 0 to High(A[x]) do Result[z][q] := A[x][q];
      for q := 0 to High(B[y]) do Result[z][Length(A[x]) + q] := B[y][q];
      Inc(z);
    end;
end;

function OrWhereGroups(const A, B: TWhereGroups): TWhereGroups;
var i, nA, nB: Integer;
begin
  nA := Length(A); nB := Length(B);
  SetLength(Result, nA + nB);
  for i := 0 to nA - 1 do Result[i] := A[i];
  for i := 0 to nB - 1 do Result[nA + i] := B[i];
end;

function ExprToWhereGroups(Expr: TSqlExprNode; const Cols: TColArray): TWhereGroups;
var
  bin: TSqlBinaryOpNode;
  colRef: TSqlColumnRefNode;
  lit: TSqlLiteralNode;
  ci: Integer;
  c: TWhereCond;
  colName, valStr, opStr: string;
begin
  SetLength(Result, 0);
  if Expr = nil then Exit;

  if Expr is TSqlBinaryOpNode then
  begin
    bin := TSqlBinaryOpNode(Expr);
    if bin.Op = sboAnd then
      Exit(AndWhereGroups(ExprToWhereGroups(bin.Left, Cols), ExprToWhereGroups(bin.Right, Cols)));
    if bin.Op = sboOr then
      Exit(OrWhereGroups(ExprToWhereGroups(bin.Left, Cols), ExprToWhereGroups(bin.Right, Cols)));

    colName := ''; valStr := ''; opStr := SqlBinaryOpToStr(bin.Op);
    if bin.Left is TSqlColumnRefNode then
    begin
      colName := TSqlColumnRefNode(bin.Left).ColumnName;
      if bin.Right is TSqlLiteralNode then
        valStr := TSqlLiteralNode(bin.Right).AsString
      else if bin.Right is TSqlColumnRefNode then
        valStr := TSqlColumnRefNode(bin.Right).ColumnName;
    end
    else if bin.Right is TSqlColumnRefNode then
    begin
      colName := TSqlColumnRefNode(bin.Right).ColumnName;
      if bin.Left is TSqlLiteralNode then
        valStr := TSqlLiteralNode(bin.Left).AsString;
      if opStr = '<' then opStr := '>'
      else if opStr = '>' then opStr := '<'
      else if opStr = '<=' then opStr := '>='
      else if opStr = '>=' then opStr := '<=';
    end;

    if colName <> '' then
    begin
      ci := FindColInArr(Cols, colName);
      if ci >= 0 then
      begin
        c.Col := ci;
        c.Ctype := Cols[ci].Ctype;
        c.Op := opStr;
        c.Val := valStr;
        SetLength(c.Vals, 0);
        SetLength(Result, 1);
        SetLength(Result[0], 1);
        Result[0][0] := c;
      end;
    end;
  end;
end;

procedure TVSqlExecutor.ExecCreateTable(Stmt: TSqlCreateTableStmt; out Res: TSqlResult);
var i: Integer;
begin
  if Stmt.IfNotExists and FT.TableExists(Stmt.Table) then
  begin Res.Affected := 0; Res.Msg := 'OK'; Exit; end;
  if Stmt.CheckExprs <> nil then
  begin
    for i := 0 to Stmt.CheckExprs.Count - 1 do
      Stmt.Checks := AndWhereGroups(Stmt.Checks, ExprToWhereGroups(Stmt.CheckExprs[i], Stmt.Cols));
  end;
  // R-13: Table Partitioning - tablo tanimina ekleme
  FT.CreateTable(Stmt.Table, Stmt.Cols, Stmt.PkIndex, Stmt.Checks, Stmt.Fks, Stmt.PartitionType, Stmt.PartitionCol, Stmt.PartitionValues);
  Res.Affected := 1; Res.LastTable := Stmt.Table; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecDropTable(Stmt: TSqlDropTableStmt; out Res: TSqlResult);
begin
  if Stmt.IfExists and not FT.TableExists(Stmt.Table) then
  begin Res.Affected := 0; Res.Msg := 'OK'; Exit; end;
  FT.DropTable(Stmt.Table);
  Res.Affected := 1; Res.LastTable := Stmt.Table; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecCreateView(Stmt: TSqlCreateViewStmt; out Res: TSqlResult);
var
  v: TTableDef;
  Sel: TSqlSelectStmt;
  i: Integer;
  item: TSelectColumnItem;
  colName: string;
  Ref: TSqlColumnRefNode;
begin
  FT.CreateView(Stmt.ViewName, Stmt.SelectStmt, Stmt.SelectText, Stmt.IfNotExists);
  // F-33: View kolonlarini SELECT'ten turet ve kaydet
  if FT.TryGetTableDef(Stmt.ViewName, v) and v.IsView then
  begin
    Sel := TSqlSelectStmt(v.SelectStmt);
    if Sel <> nil then
    begin
      SetLength(v.Cols, 0);
      for i := 0 to Sel.Columns.Count - 1 do
      begin
        item := Sel.Columns[i];
        if item.Alias <> '' then
          colName := item.Alias
        else if item.Expr is TSqlColumnRefNode then
        begin
          Ref := TSqlColumnRefNode(item.Expr);
          colName := Ref.ColumnName;
          if Pos('.', colName) > 0 then
            colName := Copy(colName, Pos('.', colName) + 1, MaxInt);
        end
        else
          colName := 'col' + IntToStr(i + 1);
        SetLength(v.Cols, Length(v.Cols) + 1);
        v.Cols[High(v.Cols)].Name := VDbNorm(colName);
        v.Cols[High(v.Cols)].Ctype := VCT_STR;
        v.Cols[High(v.Cols)].NotNull := False;
        v.Cols[High(v.Cols)].HasDef := False;
        v.Cols[High(v.Cols)].Def := '';
        v.Cols[High(v.Cols)].Unique := False;
      end;
      // FT.MarkViewSchema(Stmt.ViewName, v.Cols); // view columns already stored in CreateView
    end;
  end;
  Res.Affected := 1; Res.LastTable := Stmt.ViewName; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecDropView(Stmt: TSqlDropViewStmt; out Res: TSqlResult);
begin
  if Stmt.IfExists and not FT.ViewExists(Stmt.ViewName) then
  begin Res.Affected := 0; Res.Msg := 'OK'; Exit; end;
  FT.DropView(Stmt.ViewName, Stmt.IfExists);
  Res.Affected := 1; Res.LastTable := Stmt.ViewName; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.BuildUpsertSetValues(Stmt: TSqlInsertStmt;
  const ExcludedVals: TStrArray; const ExcludedCols, AllColNames: TStrArray;
  const Td: TTableDef; out SetValues: TSetValuePairs);
var
  i, pkIx: Integer;
  pk: string;
  existing: TStrArray;
begin
  // EXCLUDED.* referanslari bu satirlardan cozulecek
  FExcludedRow := ExcludedVals;
  FExcludedColNames := ExcludedCols;

  // MEVCUT satir: SET ifadeleri ("cnt = cnt + 1") bunu kullanir.
  SetLength(existing, Length(Td.Cols));
  for i := 0 to High(existing) do existing[i] := '';
  pk := '';
  pkIx := Td.PkIndex;
  if pkIx >= 0 then
  begin
    for i := 0 to High(ExcludedCols) do
      if SameText(ExcludedCols[i], Td.Cols[pkIx].Name) then
        pk := ExcludedVals[i];
    if pk <> '' then FT.ReadRow(Td.Name, pk, existing);
  end;

  SetLength(SetValues, Stmt.OnConflictSetExprs.Count);
  for i := 0 to Stmt.OnConflictSetExprs.Count - 1 do
  begin
    SetValues[i].ColIdx := FindColIdx(Stmt.OnConflictSetExprs[i].ColName, '', AllColNames);
    SetValues[i].Value := EvalExpr(TSqlExprNode(Stmt.OnConflictSetExprs[i].Expr),
      existing, AllColNames, nil);
  end;
end;

function TVSqlExecutor.ViewResultTypes(const ViewName: string;
  const Fields: TStrArray): TByteArray;
// F-33: view kolonlarinin tipleri. Taban tablo tek tablo ise oradaki
// kolon tipi kullanilir; ifade/alias kolonlarda VCT_STR.
var
  base, nm: string;
  v: TTableDef;
  Sel: TSqlSelectStmt;
  i, k: Integer;
  baseCols: TStrArray;
  baseTypes: TByteArray;
begin
  SetLength(Result, Length(Fields));
  for i := 0 to High(Fields) do Result[i] := VCT_STR;
  if not FT.TryGetTableDef(ViewName, v) then Exit;
  if not v.IsView then Exit;
  Sel := ParseSelectText(FT.ViewSelectText(ViewName));
  if Sel = nil then Exit;
  try
    // Updatable degilse (aggregate/JOIN/DISTINCT) sunucu tarafi tipler
    // gecerli: hepsi metin.
    if Sel.HasJoin or Sel.IsDistinct or HasAggregate(Sel) or
       ((Sel.GroupByCols <> nil) and (Sel.GroupByCols.Count > 0)) then Exit;
    base := Sel.FromTable;
    if base = '' then Exit;
    if not FT.TryGetTableDef(base, v) then Exit;
    BuildColInfo(v, baseCols, baseTypes);
    for i := 0 to High(Fields) do
    begin
      nm := Fields[i];
      if Pos('.', nm) > 0 then
        nm := Copy(nm, Pos('.', nm) + 1, MaxInt);
      for k := 0 to High(baseCols) do
        if SameText(baseCols[k], nm) then
        begin
          Result[i] := baseTypes[k];
          Break;
        end;
    end;
  finally
    Sel.Free;
  end;
end;

function TVSqlExecutor.RlsRowVisible(const ATable: string; ACmd: Byte;
  const Row: TStrArray; const Names: TStrArray;
  const Types: TByteArray): Boolean;
{ R-19: satir gorunur mu? Ilgili tum USING kosullari OR'lanir.
  Politika yoksa -> HIC SATIR gorunmez (deny-by-default, PostgreSQL ile
  ayni). }
var
  conds: TStrArray;
  i: Integer;
  e: TSqlExprNode;
begin
  if not FT.RlsApplies(ATable) then Exit(True);
  conds := FT.RlsUsing(ATable, ACmd);
  if Length(conds) = 0 then Exit(False);
  for i := 0 to High(conds) do
  begin
    e := RlsExprNode(conds[i]);
    try
      if RowMatches(e, Row, Names, Types) then Exit(True);
    finally
      e.Free;
    end;
  end;
  Result := False;
end;

function TVSqlExecutor.RlsCheckRow(const ATable: string; ACmd: Byte;
  const Row: TStrArray; const Names: TStrArray;
  const Types: TByteArray): Boolean;
{ R-19: yeni satir yazilabilir mi? Tum WITH CHECK kosullari AND'lanir. }
var
  conds: TStrArray;
  i: Integer;
  e: TSqlExprNode;
begin
  if not FT.RlsApplies(ATable) then Exit(True);
  conds := FT.RlsCheck(ATable, ACmd);
  if Length(conds) = 0 then Exit(False);
  for i := 0 to High(conds) do
  begin
    e := RlsExprNode(conds[i]);
    try
      if not RowMatches(e, Row, Names, Types) then Exit(False);
    finally
      e.Free;
    end;
  end;
  Result := True;
end;

procedure TVSqlExecutor.RlsRequireInsert(const ATable: string;
  const AColNames: array of string; const ARow: TStrArray);
{ R-19: INSERT icin WITH CHECK. Politika metni TABLO kolon adlarini
  kullanir; ARow ise AColNames sirasindadir (INSERT'te kolon listesi
  verilmisse kisaltilmis olabilir). Once tam tablo sirasina eslenir. }
var
  td: TTableDef;
  full, names: TStrArray;
  types: TByteArray;
  i, k: Integer;
begin
  if not FT.RlsApplies(ATable) then Exit;
  td := FT.GetTable(ATable);
  SetLength(names, Length(td.Cols));
  SetLength(types, Length(td.Cols));
  SetLength(full, Length(td.Cols));
  for i := 0 to High(td.Cols) do
  begin
    names[i] := td.Cols[i].Name;
    types[i] := td.Cols[i].CType;
    full[i] := '';
  end;
  for k := 0 to High(AColNames) do
    for i := 0 to High(td.Cols) do
      if SameText(td.Cols[i].Name, AColNames[k]) and (k < Length(ARow)) then
      begin
        full[i] := ARow[k];
        Break;
      end;
  if not RlsCheckRow(ATable, 2, full, names, types) then
    raise EVDbException.CreateFmt(ecPermissionDenied,
      'RLS politika ihlali: rol "%s" tablo "%s" icin bu satiri yazamaz',
      [FT.CurrentRole, ATable]);
end;

function TVSqlExecutor.RlsExprNode(const Txt: string): TSqlExprNode;
{ R-19: politika kosulu METNI yeniden ayristirilir.
  Politika metni semada duz string olarak saklanir; bu yuzden ayristirma
  burada yapilir. Sarmalayici SELECT kullanilir (parser'da WHERE'i
  ayristiren tek yol SELECT icinde). }
var
  p: TVDbParser;
  n: TSqlStmtNode;
  sel: TSqlSelectStmt;
begin
  Result := nil;
  if Trim(Txt) = '' then Exit;
  p := TVDbParser.Create;
  try
    n := nil;
    try
      n := p.Parse('SELECT 1 FROM t WHERE ' + Txt, []);
    finally
      p.Free;
    end;
    if n is TSqlSelectStmt then
    begin
      sel := TSqlSelectStmt(n);
      Result := sel.WhereClause;
      sel.WhereClause := nil;   // sahiplik devralindi
    end
    else
      n.Free;
  except
    Result := nil;
    raise;
  end;
end;

function TVSqlExecutor.ParseSelectText(const Txt: string): TSqlSelectStmt;
// Kayitli SQL metnini yeniden ayristirir (MATERIALIZED VIEW REFRESH).
// DIKKAT: AST dugumu yalnizca bu cumle icin gecerlidir; cagiran Free
// sorumlulugundadir.
var
  p: TVDbParser;
  n: TSqlStmtNode;
begin
  Result := nil;
  if Trim(Txt) = '' then Exit;
  p := TVDbParser.Create;
  try
    n := nil;
    try
      n := p.Parse(Txt, []);
    finally
      p.Free;
    end;
    if n is TSqlSelectStmt then
      Result := TSqlSelectStmt(n)
    else
      n.Free;
  except
    Result := nil;
    raise;
  end;
end;

procedure TVSqlExecutor.ExecCreateMaterializedView(Stmt: TSqlCreateMaterializedViewStmt; out Res: TSqlResult);
// F-34: MATERIALIZED VIEW — SELECT'i calistirip sonucu gizli bir tabloya
// YAZAR. Materialize edilmis view normal tablo gibi okunur (indeks, WHERE,
// ORDER BY hepsi calisir); REFRESH ile yeniden hesaplanir.
var
  src: TSqlResult;
  i: Integer;
  existed: Boolean;
begin
  existed := FT.MaterializedViewExists(Stmt.ViewName);
  FT.CreateMaterializedView(Stmt.ViewName, Stmt.SelectStmt, Stmt.SelectText, Stmt.IfNotExists);
  // IF NOT EXISTS + zaten varsa -> sessizce cik (yeniden materyalize etme).
  if existed then
  begin Res.Affected := 0; Res.Msg := 'OK'; Exit; end;
  // 1) Sorguyu calistir
  ExecSelect(TSqlSelectStmt(Stmt.SelectStmt), src);
  // 2) Semayi TAMAMEN kur (Reset: eski satirlar + kolonlar gider), sonra
  //    satirlari yaz. Kolonlar tek tek eklenirken ara durumda gorunmesin.
  FT.ResetMaterializedView(Stmt.ViewName);
  for i := 0 to High(src.Fields) do
    FT.AddMaterializedViewColumn(Stmt.ViewName, src.Fields[i]);
  for i := 0 to High(src.Rows) do
    FT.InsertMaterializedViewRow(Stmt.ViewName, src.Rows[i]);
  Res.Affected := 1; Res.LastTable := Stmt.ViewName;
  Res.Msg := 'OK (' + IntToStr(Length(src.Rows)) + ' satir)';
end;

procedure TVSqlExecutor.ExecDropMaterializedView(Stmt: TSqlDropMaterializedViewStmt; out Res: TSqlResult);
begin
  if Stmt.IfExists and not FT.MaterializedViewExists(Stmt.ViewName) then
  begin Res.Affected := 0; Res.Msg := 'OK'; Exit; end;
  FT.DropMaterializedView(Stmt.ViewName, Stmt.IfExists);
  Res.Affected := 1; Res.LastTable := Stmt.ViewName; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecRefreshMaterializedView(Stmt: TSqlRefreshMaterializedViewStmt; out Res: TSqlResult);
// F-34: REFRESH MATERIALIZED VIEW — view'i tanimindaki SELECT ile
// YENIDEN hesaplar. Eski satirlar once atilir (REPLACE semantiği).
//
// DIKKAT: AST dugumu (SelectStmt) bir POINTER olarak saklanir ve CREATE
// cumlesi bitince AST Free edilir -> REFRESH'te kullanilamaz hale gelir
// (dangling pointer / bozuk kayit hatasi). Bu yuzden burada KAYITLI
// SELECT METNINI yeniden ayristiriyoruz.
var
  src: TSqlResult;
  i: Integer;
  Sel: TSqlSelectStmt;
  txt: string;
begin
  if not FT.MaterializedViewExists(Stmt.ViewName) then
    raise EVDbException.Create(ecTableNotFound, 'materialized view yok: ' + Stmt.ViewName);
  txt := FT.GetMaterializedViewSelectText(Stmt.ViewName);
  if txt = '' then
    raise EVDbException.Create(ecTableNotFound,
      'materialized view tanimi kayip: ' + Stmt.ViewName);
  Sel := ParseSelectText(txt);
  if Sel = nil then
    raise EVDbException.Create(ecSyntaxError,
      'materialized view tanimi ayristirilamadi: ' + Stmt.ViewName);
  try
    ExecSelect(Sel, src);
  finally
    Sel.Free;
  end;
  // REFRESH: satirlari + kolon semasini sifirla, sonra yeniden kur.
  // DIKKAT: ResetMaterializedView kendi icinde ClearMaterializedView
  // cagirir; ayrica Clear cagrilirsa ikinci tur AutoInc=0 oldugu icin
  // HICBIR sey silmez (olon kod) ve MV'de silme mantigi testlerle
  // dogrulanamaz hale gelir.
  FT.ResetMaterializedView(Stmt.ViewName);
  for i := 0 to High(src.Fields) do
    FT.AddMaterializedViewColumn(Stmt.ViewName, src.Fields[i]);
  for i := 0 to High(src.Rows) do
    FT.InsertMaterializedViewRow(Stmt.ViewName, src.Rows[i]);
  Res.Affected := 1; Res.LastTable := Stmt.ViewName;
  Res.Msg := 'OK (' + IntToStr(Length(src.Rows)) + ' satir)';
end;

{ ------------------------------------------------------------
  F-36: TRIGGER (stubbed - not fully implemented)
  ------------------------------------------------------------ }
{ ------------------------------------------------------------
  F-35: STORED PROCEDURE / FUNCTION — IMPLEMENTED (aktif).
  Dispatch: Exec() satir 7335-7339; handler'lar ExecCreateFunction,
  ExecDropFunction, ExecCreateProcedure, ExecDropProcedure, ExecCall.
  Test: sqltest — F-35 grubu tumu gecti (384/415).
  ------------------------------------------------------------ }

function TVSqlExecutor.EvalExprFor(Expr: TSqlExprNode; const Row: TStrArray): string;
begin
  Result := EvalExpr(Expr, Row, nil, nil);
end;

procedure TVSqlExecutor.ExecProcStatement(Stmt: TSqlStmtNode; out Res2: TSqlResult);
{ Govde icindeki TEK cumleyi calistirir. RETURN ve BEGIN...END ozel
  islenir; digerleri normal yoldan (Execute) gecer. }
var
  i: Integer;
  Inner: TSqlResult;
begin
  // TSqlResult bir RECORD (sinif degil): Create/Dispose yoktur.
  FillChar(Res2, SizeOf(Res2), 0);
  if Stmt = nil then Exit;
  if Stmt is TSqlReturnStmt then
  begin
    // DIKKAT: RETURN ifadesi parametre kapsaminda degerlendirilir.
    FProcReturn := EvalExpr(TSqlReturnStmt(Stmt).Expr, FProcRow, FProcColNames, nil);
    FProcReturned := True;
    Res2.Msg := 'RETURN';
    Exit;
  end;
  if Stmt is TSqlBlockStmt then
  begin
    for i := 0 to TSqlBlockStmt(Stmt).Stmts.Count - 1 do
    begin
      ExecProcStatement(TSqlBlockStmt(Stmt).Stmts[i], Inner);
      // RETURN islenmisse kalan cumleler CALISMAZ (prosedur erken cikar)
      if FProcReturned then Break;
    end;
    Exit;
  end;
  Res2 := Execute(Stmt);
end;


procedure TVSqlExecutor.RunProcBody(const Body: TObject;
  const ArgTexts: TStrArray; const Params: TFunctionParamArray;
  out RetVal: string; out Returned: Boolean);
{ Govdeyi calistirir. Parametre eslemesi KONUMA (pozisyon) gore;
  verilmemeyen parametreler varsayilan ifadesiyle (yoksa bos) dolar.
  Ic ice cagirimda kapsam YIGILIR (eski kapsam geri konur). }
var
  savedRow, savedNames: TStrArray;
  savedRet: string;
  savedRetd: Boolean;
  i, n: Integer;
  R: TSqlResult;
  names: TStrArray;
  vals: TStrArray;
begin
  RetVal := '';
  Returned := False;
  if Body = nil then
    raise EVDbException.Create(ecUnsupported, 'prosedur/fonksiyon govdesi yok');

  savedRow := FProcRow;
  savedNames := FProcColNames;
  savedRet := FProcReturn;
  savedRetd := FProcReturned;
  try
    n := Length(Params);
    SetLength(names, n);
    SetLength(vals, n);
    for i := 0 to n - 1 do
    begin
      names[i] := Params[i].Name;
      if i <= High(ArgTexts) then
        vals[i] := ArgTexts[i]
      else if Params[i].DefaultExpr <> nil then
        // Varsayilan ifadesi kapsam DISINDA degerlendirilir: onceki
        // kapsam saglanir, sonra temizlenir.
        vals[i] := EvalExpr(TSqlExprNode(Params[i].DefaultExpr),
          savedRow, savedNames, nil)
      else
        vals[i] := '';
    end;
    FProcRow := vals;
    FProcColNames := names;
    FProcReturned := False;
    FProcReturn := '';

    ExecProcStatement(TSqlStmtNode(Body), R);

    RetVal := FProcReturn;
    Returned := FProcReturned;
  finally
    FProcRow := savedRow;
    FProcColNames := savedNames;
    FProcReturn := savedRet;
    FProcReturned := savedRetd;
  end;
end;

function TVSqlExecutor.CallUserFunction(const FuncName: string;
  const Args: TStrArray): string;
var
  fd: TFunctionDef;
  rv: string;
  ret: Boolean;
begin
  if not FT.GetFunctionDef(FuncName, fd) then
    raise EVDbException.Create(ecTableNotFound, 'fonksiyon yok: ' + FuncName);
  if fd.Body = nil then
    raise EVDbException.Create(ecUnsupported,
      'fonksiyon govdesi yok: ' + FuncName);
  RunProcBody(fd.Body, Args, fd.Parameters, rv, ret);
  Result := rv;
end;

function TVSqlExecutor.CallUserProcedure(const ProcName: string;
  const Args: TStrArray; out Res2: TSqlResult): Boolean;
var
  fd: TFunctionDef;
  rv: string;
  ret: Boolean;
begin
  if not FT.GetProcedureDef(ProcName, fd) then
    raise EVDbException.Create(ecTableNotFound, 'prosedur yok: ' + ProcName);
  if fd.Body = nil then
    raise EVDbException.Create(ecUnsupported,
      'prosedur govdesi yok: ' + ProcName);
  RunProcBody(fd.Body, Args, fd.Parameters, rv, ret);
  Result := ret;
  // TSqlResult record; sifirdan kurulur.
  FillChar(Res2, SizeOf(Res2), 0);
  if ret then
  begin
    SetLength(Res2.Fields, 1);
    Res2.Fields[0] := 'result';
    SetLength(Res2.Rows, 1);
    SetLength(Res2.Rows[0], 1);
    Res2.Rows[0][0] := rv;
    Res2.Affected := 1;
  end
  else
    Res2.Affected := 0;
  Res2.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecCall(Stmt: TSqlCallStmt; out Res: TSqlResult);
var
  argTexts: TStrArray;
  i: Integer;
  r2: TSqlResult;
begin
  { NOT: Argumanlar AST olarak degil DEGERLENMIS METIN olarak gecirilir
    (TVTableDb.CallProcedure parametreleri TStrArray alir). }
  if Stmt.Arguments <> nil then
  begin
    SetLength(argTexts, Stmt.Arguments.Count);
    for i := 0 to Stmt.Arguments.Count - 1 do
      argTexts[i] := EvalExpr(Stmt.Arguments[i], nil, nil, nil);
  end;
  CallUserProcedure(Stmt.ProcName, argTexts, r2);
  Res := r2;
  if Res.Msg = 'OK' then Res.Msg := 'OK';
  Res.LastTable := Stmt.ProcName;
end;

procedure TVSqlExecutor.ExecCreateIndex(Stmt: TSqlCreateIndexStmt; out Res: TSqlResult);
var msg: string;
begin
  msg := 'OK';
  if Stmt.Concurrently then msg := 'OK (CONCURRENTLY)';
  // F2-23: UNIQUE bayragi TEK KOLONLU yolda da tasinir. Once bu dal
  // CreateIndex'i cagirip Uniq'i yutuyordu.
  // F-18: ifade indeksi (Cols bos, ExprText dolu)
  // R-22 Full: Concurrent bayragi motora tasinir — arka plan insasi
  // baslar, cumle HEMEN doner; finalize sonraki cumlelerde yapilir.
  if Stmt.ExprText <> '' then
    FT.CreateIndexCols(Stmt.Table, Stmt.IndexName, nil, Stmt.Uniq,
      Stmt.Predicate, Stmt.ExprText, Stmt.Incl, Stmt.Concurrently)   // R-22
  else if Length(Stmt.Cols) > 1 then
    FT.CreateIndexCols(Stmt.Table, Stmt.IndexName, Stmt.Cols, Stmt.Uniq,
      Stmt.Predicate, '', Stmt.Incl, Stmt.Concurrently)             // R-22
  else
    FT.CreateIndexCols(Stmt.Table, Stmt.IndexName, [Stmt.Col], Stmt.Uniq,
      Stmt.Predicate, '', Stmt.Incl, Stmt.Concurrently);            // R-22
  Res.Affected := 1; Res.LastTable := Stmt.Table; Res.Msg := msg;
end;

procedure TVSqlExecutor.ExecDropIndex(Stmt: TSqlDropIndexStmt; out Res: TSqlResult);
begin
  FT.DropIndex(Stmt.IndexName);
  Res.Affected := 1; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecAlterTable(Stmt: TSqlAlterTableStmt; out Res: TSqlResult);
var msg: string;
begin
  msg := 'OK';
  if Stmt.Concurrently then msg := 'OK (CONCURRENTLY)';
  case Stmt.Action of
    ataAddColumn:
      FT.AlterAddColumn(Stmt.Table, Stmt.ColDef, Stmt.PositionCol,
        Stmt.DefaultVal <> '', Stmt.DefaultVal);
    ataDropColumn:
      FT.AlterDropColumn(Stmt.Table, Stmt.ColName);
    ataRenameColumn:
      FT.AlterRenameColumn(Stmt.Table, Stmt.ColName, Stmt.NewName);
    ataAlterColType:
      FT.AlterColumnType(Stmt.Table, Stmt.ColName, Stmt.NewTypeName);
    ataSetDefault:
      FT.AlterSetDefault(Stmt.Table, Stmt.ColName, True, Stmt.DefaultVal);
    ataDropDefault:
      FT.AlterDropDefault(Stmt.Table, Stmt.ColName);
    ataSetNotNull:
      FT.AlterSetNotNull(Stmt.Table, Stmt.ColName, True);
    ataDropNotNull:
      FT.AlterSetNotNull(Stmt.Table, Stmt.ColName, False);
    ataRenameTable:
      FT.AlterRenameTable(Stmt.Table, Stmt.NewName);
    ataEnableRls:       // R-19
      FT.SetRls(Stmt.Table, True);
    ataDisableRls:
      FT.SetRls(Stmt.Table, False);
  end;
  Res.Affected := 1; Res.LastTable := Stmt.Table; Res.Msg := msg;
end;

{ ------------------------------------------------------------
  TX Handler
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecTx(Stmt: TSqlTxStmt; out Res: TSqlResult);
begin
  case Stmt.Kind of
    // DIKKAT: FT.BeginBatch (TVTableDb) kullanilir, FT.Kv.BeginBatch DEGIL.
    // TVTableDb.BeginBatch icinde SnapshotSchema cagrilir; boylece batch
    // icinde yapilan DDL (CREATE/DROP TABLE, INDEX, ALTER) ROLLBACK ile
    // geri alinir. Dogrudan Kv.BeginBatch cagrilirsa sema yedegi alinmadigi
    // icin "ROLLBACK sonrasi tablo yok" testi basarisiz olur.
    txBegin:           FT.BeginBatch;
    txCommit:          begin FT.CommitBatch; FT.UnlockRows(FSessionId); end;
    txRollback:        begin FT.AbortBatch; FT.UnlockRows(FSessionId); end;
    txSavepoint:       FT.Kv.Savepoint(Stmt.SavepointName);
    txRollbackTo:      FT.Kv.RollbackToSavepoint(Stmt.SavepointName);
    txReleaseSavepoint: FT.Kv.ReleaseSavepoint(Stmt.SavepointName);
  end;
  Res.Affected := 0; Res.Msg := 'OK';
end;

{ ------------------------------------------------------------
  F-35: STORED PROCEDURE / FUNCTION
  ------------------------------------------------------------ }
procedure TVSqlExecutor.ExecCreateFunction(Stmt: TSqlCreateFunctionStmt; out Res: TSqlResult);
var
  params: array of TFunctionParameter;
  i: Integer;
begin
  SetLength(params, Length(Stmt.Parameters));
  for i := 0 to Length(Stmt.Parameters) - 1 do
  begin
    params[i].Name := Stmt.Parameters[i].Name;
    params[i].TypeName := Stmt.Parameters[i].TypeName;
    params[i].Mode := Stmt.Parameters[i].Mode;
    if Stmt.Parameters[i].DefaultExpr <> nil then
      params[i].DefaultExpr := Stmt.Parameters[i].DefaultExpr
    else
      params[i].DefaultExpr := nil;
  end;
  FT.CreateFunction(Stmt.Name, params, Stmt.ReturnType,
    Stmt.Language, '', Stmt.IfNotExists);
  // Govde AST'sini kataloga DEVRET (sahiplik). Stmt.Body := nil yapilmazsa
  // AST Free olurken govde de serbest kalir ve katalogda dangling pointer
  // olurdu (cagirimda AV).
  if FT.FunctionExists(Stmt.Name) then
  begin
    FT.SetFunctionBody(Stmt.Name, Stmt.Body);
    Stmt.Body := nil;
  end;
  Res.Affected := 1; Res.LastTable := Stmt.Name; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecDropFunction(Stmt: TSqlDropFunctionStmt; out Res: TSqlResult);
begin
  if Stmt.IfExists and not FT.FunctionExists(Stmt.Name) then
  begin Res.Affected := 0; Res.Msg := 'OK'; Exit; end;
  FT.DropFunction(Stmt.Name, Stmt.IfExists);
  Res.Affected := 1; Res.LastTable := Stmt.Name; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecCreateProcedure(Stmt: TSqlCreateProcedureStmt; out Res: TSqlResult);
var
  params: array of TFunctionParameter;
  i: Integer;
begin
  SetLength(params, Length(Stmt.Parameters));
  for i := 0 to Length(Stmt.Parameters) - 1 do
  begin
    params[i].Name := Stmt.Parameters[i].Name;
    params[i].TypeName := Stmt.Parameters[i].TypeName;
    params[i].Mode := Stmt.Parameters[i].Mode;
    if Stmt.Parameters[i].DefaultExpr <> nil then
      params[i].DefaultExpr := Stmt.Parameters[i].DefaultExpr
    else
      params[i].DefaultExpr := nil;
  end;
  FT.CreateProcedure(Stmt.Name, params, Stmt.Language,
    '', Stmt.IfNotExists);
  // Govde sahipligi kataloga devredilir (bkz. ExecCreateFunction).
  if FT.ProcedureExists(Stmt.Name) then
  begin
    FT.SetProcedureBody(Stmt.Name, Stmt.Body);
    Stmt.Body := nil;
  end;
  Res.Affected := 1; Res.LastTable := Stmt.Name; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecDropProcedure(Stmt: TSqlDropProcedureStmt; out Res: TSqlResult);
begin
  if Stmt.IfExists and not FT.ProcedureExists(Stmt.Name) then
  begin Res.Affected := 0; Res.Msg := 'OK'; Exit; end;
  FT.DropProcedure(Stmt.Name, Stmt.IfExists);
  Res.Affected := 1; Res.LastTable := Stmt.Name; Res.Msg := 'OK';
end;

{ ------------------------------------------------------------
  F-36: TRIGGER
  //---------------------------------------------------------- }

procedure TVSqlExecutor.ExecCreateTrigger(Stmt: TSqlCreateTriggerStmt; out Res: TSqlResult);
var
  ev: array of Byte;
  i: Integer;
begin
  // F-36: tetikleyici kataloga kayit (gövde + WHEN ayri adimda).
  SetLength(ev, Length(Stmt.Events));
  for i := 0 to High(Stmt.Events) do
    ev[i] := Stmt.Events[i];
  FT.CreateTrigger(Stmt.TriggerName, Stmt.TableName, ev,
    Stmt.Timing, Stmt.ForEach, Stmt.IfNotExists);
  if FT.TriggerExists(Stmt.TriggerName) then
  begin
    // AS govdesi + WHEN kosulu: sahiplik FTriggers'e devredilir.
    FT.SetTriggerDef(Stmt.TriggerName, Stmt.WhenCondition, Stmt.Body);
    // Burada serbest birakma - catalog sahiplendi.
    Stmt.WhenCondition := nil;
    Stmt.Body := nil;
  end;
  Res.Affected := 1; Res.LastTable := Stmt.TableName; Res.Msg := 'OK';
end;

procedure TVSqlExecutor.ExecDropTrigger(Stmt: TSqlDropTriggerStmt; out Res: TSqlResult);
begin
  // F-36: tetikleyici katalogdan kaldirilir ve kaynaklar serbest kalir.
  FT.DropTrigger(Stmt.TriggerName, Stmt.IfExists);
  Res.Affected := 1; Res.Msg := 'OK';
end;

{ ------------------------------------------------------------
  F-36: TRIGGER ateşleme yardimcilarî
  //---------------------------------------------------------- }

procedure TVSqlExecutor.FireTriggerDef(const TDef: TTriggerDef;
  Timing: Byte; Event: Byte;
  const OldRow, NewRow: TStrArray;
  const NewColNames: TStrArray; out Res: TSqlResult);
var
  savedOuterRow, savedOuterCols: TStrArray;
  savedOldRow, savedOldCols: TStrArray;
  lenStr: string;
  o1, o2: string;
  i, idx: Integer;
  val: string;
  st: TSqlStmtNode;
  whenVal: string;
  whenTrue: Boolean;
  newrowstr, colstr, outerstr: string;
begin
  if (TDef.Body = nil) or (not (Timing in [Byte(Byte(ttBefore)), Byte(Byte(ttAfter)), Byte(Byte(ttInsteadOf))])) then Exit;

  // Sonsuz gecme / ic ice tetikleyici korumasî
  Inc(FTriggerNesting);
  try
    if FTriggerNesting > 100 then
      raise EVDbException.Create(ecUnsupported,
        'çok derin ic ice tetikleyici (100 seviye asildi): ' + TDef.Name);
    // --- WHEN kosulu (varsa) degerlendir ---
    whenTrue := True;
    if TDef.WhenCondition <> nil then
    begin
      savedOuterRow := FOuterRow;
      savedOuterCols := FOuterColNames;
      try
        FOuterRow := NewRow;
        FOuterColNames := NewColNames;
        whenVal := EvalExprFor(TSqlExprNode(TDef.WhenCondition), NewRow);
        whenTrue := SameText(whenVal, 'True');
      finally
        FOuterRow := savedOuterRow;
        FOuterColNames := savedOuterCols;
      end;
      if not whenTrue then Exit;  // WHEN yalan -> atlanir
    end;
    // --- Byte(ttBefore): NEW.kolon = ifade degisikliklerini NewRow'a uygula ---
    if Timing = Byte(Byte(ttBefore)) then
    begin
      savedOuterRow := FOuterRow;
      savedOuterCols := FOuterColNames;
      savedOldRow := FOuterOldRow;
      savedOldCols := FOuterOldColNames;
      try
        FOuterRow := NewRow;
        FOuterColNames := NewColNames;
        // BEFORE UPDATE/DELETE: OLD satir baglami
        if (Event = Byte(teUpdate)) or (Event = Byte(teDelete)) then
        begin
          FOuterOldRow := OldRow;
          FOuterOldColNames := NewColNames;
        end;
        // F-36: NewRow/FOuterRow debug

        if TDef.Body is TSqlBlockStmt then
        begin
          for i := 0 to TSqlBlockStmt(TDef.Body).Stmts.Count - 1 do
          begin
            st := TSqlBlockStmt(TDef.Body).Stmts[i];
            if st is TSqlSetNewStmt then
            begin
              val := EvalExpr(TSqlSetNewStmt(st).Expr, nil, nil, nil);
              idx := FindColIdx(TSqlSetNewStmt(st).ColName, '', NewColNames);
              if idx >= 0 then
              begin
                NewRow[idx] := val;
              end
              else
              begin
                // kolon YeniSatir'da YOK -> SET NEW yoksayilir
              end;
            end;
          end;
        end
        else if TDef.Body is TSqlSetNewStmt then
        begin
          st := TSqlStmtNode(TDef.Body);
          val := EvalExpr(TSqlSetNewStmt(st).Expr, nil, nil, nil);
          idx := FindColIdx(TSqlSetNewStmt(st).ColName, '', NewColNames);
          if idx >= 0 then
          begin
            NewRow[idx] := val;
          end
          else
          begin
            // kolon YeniSatir'da YOK -> SET NEW yoksayilir
          end;
        end;
      finally
        FOuterRow := savedOuterRow;
        FOuterColNames := savedOuterCols;
        FOuterOldRow := savedOldRow;
        FOuterOldColNames := savedOldCols;
      end;
    end;
    // --- Gövdeyi calistir ---
    savedOuterRow := FOuterRow;
    savedOuterCols := FOuterColNames;
    savedOldRow := FOuterOldRow;
    savedOldCols := FOuterOldColNames;
    try
      // --- NEW baglami ---
      if (Timing = Byte(Byte(ttBefore))) then
      begin
        FOuterRow := NewRow;
        FOuterColNames := NewColNames;

      end
      else if (Timing = Byte(Byte(ttAfter))) and
              (Event in [Byte(teInsert), Byte(teUpdate)]) then
      begin
        // AFTER INSERT/UPDATE: guncellenmis/yeni satir
        FOuterRow := NewRow;
        FOuterColNames := NewColNames;

      end
      else if (Timing = Byte(Byte(ttInsteadOf))) then
      begin
        // INSTEAD OF INSERT/UPDATE/DELETE: degisiklik oncesi degerler
        FOuterRow := NewRow;
        FOuterColNames := NewColNames;
      end;
      // --- OLD baglami ---
      if (Timing = Byte(Byte(ttBefore))) and
         (Event in [Byte(teUpdate), Byte(teDelete)]) or
         (Timing = Byte(Byte(ttAfter))) and (Event = Byte(teDelete)) then
      begin
        FOuterOldRow := OldRow;
        FOuterOldColNames := NewColNames;
      end
      else if (Timing = Byte(Byte(ttInsteadOf))) and (OldRow <> nil) then
      begin
        // INSTEAD OF UPDATE/DELETE: silinme/guncellenme oncesi degerler
        FOuterOldRow := OldRow;
        FOuterOldColNames := NewColNames;
      end;


      Res := Execute(TSqlStmtNode(TDef.Body));

    finally
      FOuterRow := savedOuterRow;
      FOuterColNames := savedOuterCols;
      FOuterOldRow := savedOldRow;
      FOuterOldColNames := savedOldCols;
    end;
  finally
    Dec(FTriggerNesting);
  end;
end;

procedure TVSqlExecutor.FireTriggers(
  const TableName: string; Timing: Byte; Event: Byte;
  const OldRow: TStrArray; const NewRow: TStrArray;
  const NewColNames: TStrArray; out Res: TSqlResult; IsRowOp: Boolean);
var
  tds: TTableDef;
  names: TStrArray;
  i, e: Integer;
  def: TTriggerDef;
  tdef: TTriggerDef;
  ok: Boolean;
begin
  Res.Affected := 0; Res.Msg := 'OK';
  SetLength(Res.Fields, 0); SetLength(Res.Rows, 0);
  // IsRowOp = False (STATEMENT) ise STATEMENT tetikleyicileri,
  // True ise bu satir icin ROW tetikleyicileri ateslenir.
  if not FT.TableExists(TableName) then Exit;
  tds := FT.GetTable(TableName);
  names := FT.TriggersFor(TableName, Timing, Event);
  if Length(names) = 0 then Exit;
  for i := 0 to High(names) do
  begin
    ok := FT.GetTriggerDef(names[i], tdef);
    if not ok then Continue;
    def := tdef;
    if def.Timing <> Timing then Continue;
    e := 0;
    while e < Length(def.Events) do
    begin
      if def.Events[e] = Event then Break;
      Inc(e);
    end;
    if e >= Length(def.Events) then Continue;
    if def.ForEach <> Byte(Byte(tfRow)) then
    begin
      // STATEMENT tetikleyicisi
      if not IsRowOp then
        FireTriggerDef(def, Timing, Event, OldRow, NewRow, NewColNames, Res);
      Continue;
    end;
    if IsRowOp then
      FireTriggerDef(def, Timing, Event, OldRow, NewRow, NewColNames, Res);
  end;

end;
procedure TVSqlExecutor.F36_InsertRowHooks(var NewRow: TStrArray;
  const TableName: string; const cnames: TStrArray; out Res: TSqlResult);
var
  NewColNames: TStrArray;
begin
  // F-36: BEFORE ROW tetikleyiciler (NEW degisiklikleri bu adimda NewRow'a uygulanir)
  NewColNames := cnames;
  FireTriggers(TableName, Byte(ttBefore), Byte(teInsert), nil, NewRow, NewColNames, Res, True);
  // F-36: AFTER ROW tetikleyiciler (yazim sonra)
  FireTriggers(TableName, Byte(ttAfter), Byte(teInsert), nil, NewRow, NewColNames, Res, True);
end;

{ ------------------------------------------------------------
  Admin Handler
  //---------------------------------------------------------- }
{ ------------------------------------------------------------
  F-20 yardimcilari: EXPLAIN plan metni
  //---------------------------------------------------------- }
function TVSqlExecutor.BinaryOpName(Op: TSqlBinaryOp): string;
begin
  case Op of
    sboEq: Result := '=';
    sboNeq: Result := '<>';
    sboLt: Result := '<';
    sboLte: Result := '<=';
    sboGt: Result := '>';
    sboGte: Result := '>=';
    sboLike: Result := 'LIKE';
    sboAnd: Result := 'AND';
    sboOr: Result := 'OR';
    sboAdd: Result := '+';
    sboSub: Result := '-';
    sboMul: Result := '*';
    sboDiv: Result := '/';
    sboMod: Result := 'MOD';
    sboILike: Result := 'ILIKE';
  else
    Result := '?';
  end;
end;

function TVSqlExecutor.DescribeExpr(E: TSqlExprNode): string;
var
  b: TSqlBinaryOpNode;
begin
  Result := '';
  if E = nil then Exit;
  if E is TSqlColumnRefNode then
  begin
    Result := TSqlColumnRefNode(E).QualifiedName;
    Exit;
  end;
  if E is TSqlLiteralNode then
  begin
    Result := TSqlLiteralNode(E).AsString;
    Exit;
  end;
  if E is TSqlBinaryOpNode then
  begin
    b := TSqlBinaryOpNode(E);
    Result := '(' + DescribeExpr(b.Left) + ' ' + BinaryOpName(b.Op) + ' ' +
              DescribeExpr(b.Right) + ')';
    Exit;
  end;
  Result := '(expr)';
end;

function TVSqlExecutor.TryCteOk(const TableName: string): Boolean;
begin
  Result := (FCteTables <> nil) and FCteTables.ContainsKey(VDbNorm(TableName));
end;

{ F-20: sema satirinda UNIQUE indeksler "!" onekiyle yazilir; plan
  metninde onek gosterilmez. }
function StripIdxMark(const Nm: string): string;
begin
  if (Length(Nm) > 0) and (Nm[1] = '!') then
    Result := Copy(Nm, 2, MaxInt)
  else
    Result := Nm;
end;

{ F-20: indeksin ILK kolonu (Cols dizisi yoksa geri uyum: Col alani). }
function firstColOf(const Td: TTableDef; Ix: Integer): Integer;
begin
  if Length(Td.Idx[Ix].Cols) > 0 then
    Result := Td.Idx[Ix].Cols[0]
  else
    Result := Td.Idx[Ix].Col;
end;

function TVSqlExecutor.IndexUsedByWhere(const Td: TTableDef;
  const Where: TSqlExprNode; out IdxName: string): Boolean;
var
  conj: TList<TSqlExprNode>;
  k, ci, ix: Integer;
  b: TSqlBinaryOpNode;
  bt: TSqlBetweenNode;
  opName: string;
  found: Boolean;

  procedure Push(C: TSqlExprNode);
  begin
    if (C is TSqlBinaryOpNode) and (TSqlBinaryOpNode(C).Op = sboAnd) then
    begin
      Push(TSqlBinaryOpNode(C).Left);
      Push(TSqlBinaryOpNode(C).Right);
    end
    else conj.Add(C);
  end;

  // sol taraf bu indeksin ILK kolonu mu?
  function LeadsIdx(ColRef: TSqlColumnRefNode; out Ix: Integer): Boolean;
  var
    q, firstCol, ci2: Integer;
  begin
    LeadsIdx := False;
    Ix := -1;
    // PK lazy index: PK kolonu T.Idx'te YOK ama TryGetMemIndex
    // tembel kurar; BETWEEN/ORDER BY range query'leri kullanabilir.
    if (Td.PkIndex >= 0) and (Td.PkIndex < Length(Td.Cols)) and
       (VDbNorm(Td.Cols[Td.PkIndex].Name) = VDbNorm(ColRef.ColumnName)) then
    begin
      Ix := -2;   // -2 = PK lazy index sinyali
      LeadsIdx := True;
      Exit;
    end;
    for q := 0 to High(Td.Idx) do
    begin
      // gercekten indeks var mi? (IdxNParts = 0 ise bos tanim)
      if FT.IdxNParts(Td.TableId, firstColOf(Td, q)) <= 0 then Continue;
      firstCol := firstColOf(Td, q);
      if (firstCol >= 0) and (firstCol < Length(Td.Cols)) and
         (VDbNorm(Td.Cols[firstCol].Name) = VDbNorm(ColRef.ColumnName)) then
      begin
        Ix := q; LeadsIdx := True; Exit;
      end;
    end;
  end;

begin
  Result := False;
  IdxName := '';
  if Where = nil then Exit;
  // PK lazy index: Td.Idx bos olsa bile PK kolonu uzerinde aralik
  // (BETWEEN, <, >, <=, >=) veya esitlik (^=) indeks kullanilabilir.
  // Dolayisiyla Length(Td.Idx)=0 erken cikisi KALDIRILDI.
  conj := TList<TSqlExprNode>.Create;
  try
    Push(Where);
      for k := 0 to conj.Count - 1 do
      begin
        { R-16: TSqlBetweenNode destegi - BETWEEN indeks kullanir }
        if conj[k] is TSqlBetweenNode then
        begin
          bt := TSqlBetweenNode(conj[k]);
          if (bt.Expr is TSqlColumnRefNode) and LeadsIdx(TSqlColumnRefNode(bt.Expr), ix) then
          begin
            if ix = -2 then
              IdxName := td.Name + '_pkey'   // PK lazy index
            else
              IdxName := Td.Idx[ix].Name;
            Result := True;
            Break;
          end;
          Continue;
        end;
        if conj[k] is TSqlBinaryOpNode then
        begin
          b := TSqlBinaryOpNode(conj[k]);
          opName := BinaryOpName(b.Op);
          if not ((opName = '=') or (opName = '<') or (opName = '>') or
                  (opName = '<=') or (opName = '>=')) then Continue;
          if not (b.Left is TSqlColumnRefNode) then Continue;
          if LeadsIdx(TSqlColumnRefNode(b.Left), ix) then
        begin
          if ix = -2 then
            IdxName := td.Name + '_pkey'   // PK lazy index
          else
            IdxName := Td.Idx[ix].Name;
          Result := True;
          Break;
        end;
      end;
    end;
  finally
    conj.Free;
  end;
end;

{ ------------------------------------------------------------
  ExecExplain (F-20)
  Sorgu planini dondurur. Cumle CALISTIRILMAZ (Analyze haric), yalniz
  secilecek yol raporlanir (PostgreSQL "QUERY PLAN" bicimi).
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecExplain(Stmt: TSqlExplainStmt; out Res: TSqlResult);
var
  plan: TStrArray;
  sel: TSqlSelectStmt;
  td: TTableDef;
  i: Integer;
  t0: Int64;
  usedWhere, usedGroup, usedOrder, usedLimit, usedJoin,
    usedAgg, usedWindow, usedQualify: Boolean;
  idxUsed, pkUsed: Boolean;
  idxName: string;
  innerR: TSqlResult;
  // R-15 Full CBO
  hasStats: Boolean;
  tblStats: TVDbTableStats;
  est: TVdbCostEstimate;
  eqDistinct, eqNulls, eqMCV, rangeRows: Int64;
  covAll: Boolean;
  base: string;
  stA, stB: TVDbTableStats;
  hasA, hasB: Boolean;
  // R-14 Full: Seq Scan dugumu "Parallel" isaretlenecek mi? (-1 = hayir;
  // degilse isaretlemeye esas satir sayisi)
  parRows: Int64;
  // R-13 Full: pruning hedef kumesi (EXPLAIN raporu icin)
  pt2: TPartTargets;
  // R-13 Full: bu plan PK/indeks yolu mu? (pruning yalniz Seq Scan'da uygulanir)
  nonSeqPath: Boolean;

  function SeqEst(RowCount: Int64): TVdbCostEstimate;
  begin
    Result.Kind := pkSeqScan;
    Result.EstRows := RowCount;
    Result.StartupCost := 0;
    Result.TotalCost := VdbSeqScanCost(RowCount);
  end;

  procedure Add(const L: string);
  begin
    SetLength(plan, Length(plan) + 1);
    plan[High(plan)] := L;
  end;

  // WHERE icinde PK kolonuna karsilastirma var mi? (Nokta aramasi yolu)
  function HasPkLookup(T: TTableDef): Boolean;
  var
    conj: TList<TSqlExprNode>;
    k, ci: Integer;
    b: TSqlBinaryOpNode;
    opName: string;

    procedure Push(C: TSqlExprNode);
    begin
      if (C is TSqlBinaryOpNode) and (TSqlBinaryOpNode(C).Op = sboAnd) then
      begin
        Push(TSqlBinaryOpNode(C).Left);
        Push(TSqlBinaryOpNode(C).Right);
      end
      else conj.Add(C);
    end;

  begin
    Result := False;
    // NOT: Bu fonksiyon SAF bir yuklemdir; plan metnine satir EKLEMEZ.
    // (R-25 actual-rows satirlari ExecExplain'in Stmt.Analyze blogunda
    //  eklenir; burada eklemek EXPLAIN ANALYZE'i 4 satira cikariyordu.)
    if (T.PkIndex < 0) or (sel = nil) then Exit;
    if sel.WhereClause = nil then Exit;
    conj := TList<TSqlExprNode>.Create;
    try
      Push(sel.WhereClause);
      for k := 0 to conj.Count - 1 do
        if conj[k] is TSqlBinaryOpNode then
        begin
          b := TSqlBinaryOpNode(conj[k]);
          opName := BinaryOpName(b.Op);
          if not ((opName = '=') or (opName = '<') or (opName = '>') or
                  (opName = '<=') or (opName = '>=')) then Continue;
          // sol taraf PK kolonu mu?
          if b.Left is TSqlColumnRefNode then
            for ci := 0 to High(T.Cols) do
              if SameText(T.Cols[ci].Name,
                 TSqlColumnRefNode(b.Left).ColumnName) then
                if ci = T.PkIndex then
                begin Result := True; Break; end;
          if Result then Break;
        end;
    finally
      conj.Free;
    end;
  end;

  { R-15 Full CBO: WHERE'de indeksli bir kolon uzerinde "col = literal"
    esitligi varsa o kolonun ANALYZE istatistigini (distinct/null) dondurur.
    Secicilik = RowCount / distinct ile tahmin edilir. Yalnizca TEK bir
    esitlik kullanilir; bulanamazsa False doner ve cagri sezgisel
    (range) tahmine duser. }
  function EqColStats(T: TTableDef; out Distinct, Nulls, MCVCount: Int64): Boolean;
  var
    conj: TList<TSqlExprNode>;
    k, ci, cj, m: Integer;
    b: TSqlBinaryOpNode;
    colName, litVal: string;

    procedure Push(C: TSqlExprNode);
    begin
      if (C is TSqlBinaryOpNode) and (TSqlBinaryOpNode(C).Op = sboAnd) then
      begin
        Push(TSqlBinaryOpNode(C).Left);
        Push(TSqlBinaryOpNode(C).Right);
      end
      else conj.Add(C);
    end;

  begin
    Result := False;
    Distinct := 0;
    Nulls := 0;
    MCVCount := -1;
    if (sel = nil) or (sel.WhereClause = nil) then Exit;
    conj := TList<TSqlExprNode>.Create;
    try
      Push(sel.WhereClause);
      for k := 0 to conj.Count - 1 do
        if conj[k] is TSqlBinaryOpNode then
        begin
          b := TSqlBinaryOpNode(conj[k]);
          if (b.Op <> sboEq) or (not (b.Left is TSqlColumnRefNode)) or
             (not (b.Right is TSqlLiteralNode)) then Continue;
          colName := TSqlColumnRefNode(b.Left).ColumnName;
          ci := -1;
          for cj := 0 to High(T.Cols) do
            if VDbNorm(T.Cols[cj].Name) = VDbNorm(colName) then
            begin ci := cj; Break; end;
          if ci < 0 then Continue;
          litVal := TSqlLiteralNode(b.Right).AsString;
          for cj := 0 to High(tblStats.ColStats) do
            if SameText(tblStats.ColStats[cj].ColName, T.Cols[ci].Name) then
            begin
              Distinct := tblStats.ColStats[cj].DistinctCount;
              Nulls := tblStats.ColStats[cj].NullCount;
              MCVCount := -1;
              for m := 0 to High(tblStats.ColStats[cj].MCV) do
                if tblStats.ColStats[cj].MCV[m].Value = litVal then
                begin
                  MCVCount := tblStats.ColStats[cj].MCV[m].Count;
                  Break;
                end;
              if Distinct > 0 then Exit(True);
            end;
        end;
    finally
      conj.Free;
    end;
  end;

  { H8: aralik (range) kosulu icin ANALYZE min/max istatistiginden secicilik
    tahmini. Gercek yurutme (NarrowRows) dilim boyutunu (bestHi-bestLo) TAM
    bilir; EXPLAIN ise sabit "RowCount div 3"e duserdi -> plan metni ile
    gercek plan celisebiliyordu. Burada [min,max] uzerinde uniform varsayimla
    kesir hesaplanir. Yalnizca sayisal kolon + sayisal sinir; aksi halde False
    (eski "div 3" sezgisine duser). }
  function RangeColEst(T: TTableDef; out EstRows: Int64): Boolean;
  var
    conj: TList<TSqlExprNode>;
    k, ci: Integer;
    b: TSqlBinaryOpNode;
    btw: TSqlBetweenNode;
    colName: string;
    lo, hi, v, mn, mx, frac: Double;
    tgt: Integer;

    procedure Push(C: TSqlExprNode);
    begin
      if (C is TSqlBinaryOpNode) and (TSqlBinaryOpNode(C).Op = sboAnd) then
      begin
        Push(TSqlBinaryOpNode(C).Left);
        Push(TSqlBinaryOpNode(C).Right);
      end
      else conj.Add(C);
    end;

    function ColIdxOf(const N: string): Integer;
    var q: Integer;
    begin
      Result := -1;
      for q := 0 to High(T.Cols) do
        if VDbNorm(T.Cols[q].Name) = VDbNorm(N) then Exit(q);
    end;

    function StatsOf(ci2: Integer; out m1, m2: Double): Boolean;
    var q: Integer;
    begin
      Result := False;
      for q := 0 to High(tblStats.ColStats) do
        if SameText(tblStats.ColStats[q].ColName, T.Cols[ci2].Name) then
        begin
          if VDbParseFloat(tblStats.ColStats[q].MinVal, m1) and
             VDbParseFloat(tblStats.ColStats[q].MaxVal, m2) then Exit(True);
          Exit(False);
        end;
    end;

  begin
    Result := False;
    EstRows := 0;
    if (sel = nil) or (sel.WhereClause = nil) then Exit;
    conj := TList<TSqlExprNode>.Create;
    try
      Push(sel.WhereClause);
      // 1) Hedef kolon: indeksli (PK ya da onek) + sayisal + istatistikli
      //    ilk aralik kolonu.
      tgt := -1;
      for k := 0 to conj.Count - 1 do
      begin
        colName := '';
        if conj[k] is TSqlBinaryOpNode then
        begin
          b := TSqlBinaryOpNode(conj[k]);
          if not ((b.Op in [sboLt, sboLte, sboGt, sboGte]) and
                  (b.Left is TSqlColumnRefNode) and
                  (b.Right is TSqlLiteralNode)) then Continue;
          colName := TSqlColumnRefNode(b.Left).ColumnName;
        end
        else if conj[k] is TSqlBetweenNode then
        begin
          btw := TSqlBetweenNode(conj[k]);
          if not (btw.Expr is TSqlColumnRefNode) then Continue;
          colName := TSqlColumnRefNode(btw.Expr).ColumnName;
        end
        else Continue;
        ci := ColIdxOf(colName);
        if ci < 0 then Continue;
        if not VDbIsNumericCol(T.Cols[ci].Ctype) then Continue;
        if not ((ci = T.PkIndex) or (FT.IdxPosOfCol(T.TableId, ci) >= 0)) then Continue;
        if not StatsOf(ci, mn, mx) then Continue;
        tgt := ci;
        Break;
      end;
      if tgt < 0 then Exit;
      if (not StatsOf(tgt, mn, mx)) or (mx <= mn) then Exit;

      // 2) Ayni kolon icin alt/ust sinirlari topla
      lo := mn; hi := mx;
      for k := 0 to conj.Count - 1 do
      begin
        if conj[k] is TSqlBinaryOpNode then
        begin
          b := TSqlBinaryOpNode(conj[k]);
          if not ((b.Left is TSqlColumnRefNode) and
                  (b.Right is TSqlLiteralNode)) then Continue;
          if ColIdxOf(TSqlColumnRefNode(b.Left).ColumnName) <> tgt then Continue;
          if not VDbParseFloat(TSqlLiteralNode(b.Right).AsString, v) then Continue;
          case b.Op of
            sboGt, sboGte: lo := v;
            sboLt, sboLte: hi := v;
          end;
        end
        else if conj[k] is TSqlBetweenNode then
        begin
          btw := TSqlBetweenNode(conj[k]);
          if not (btw.Expr is TSqlColumnRefNode) then Continue;
          if ColIdxOf(TSqlColumnRefNode(btw.Expr).ColumnName) <> tgt then Continue;
          if (btw.LowBound is TSqlLiteralNode) and
             VDbParseFloat(TSqlLiteralNode(btw.LowBound).AsString, v) then lo := v;
          if (btw.HighBound is TSqlLiteralNode) and
             VDbParseFloat(TSqlLiteralNode(btw.HighBound).AsString, v) then hi := v;
        end;
      end;

      // 3) [lo,hi] ∩ [mn,mx] kesiri (uniform)
      if lo < mn then lo := mn;
      if hi > mx then hi := mx;
      if hi <= lo then begin EstRows := 1; Exit(True); end;
      frac := (hi - lo) / (mx - mn);
      EstRows := Round(tblStats.RowCount * frac);
      if EstRows < 1 then EstRows := 1;
      if EstRows > tblStats.RowCount then EstRows := tblStats.RowCount;
      Result := True;
    finally
      conj.Free;
    end;
  end;

begin
  SetLength(plan, 0);
  sel := nil;
  if Stmt.Inner is TSqlSelectStmt then sel := TSqlSelectStmt(Stmt.Inner);

  if sel = nil then
  begin
    if Stmt.Inner is TSqlInsertStmt then
      Add('Insert on ' + TSqlInsertStmt(Stmt.Inner).Table)
    else if Stmt.Inner is TSqlUpdateStmt then
      Add('Update on ' + TSqlUpdateStmt(Stmt.Inner).Table)
    else if Stmt.Inner is TSqlDeleteStmt then
      Add('Delete on ' + TSqlDeleteStmt(Stmt.Inner).Table)
    else
      Add('(desteklenmeyen cumle tipi)');
  end
  else
  begin
    usedWhere   := sel.WhereClause <> nil;
    usedGroup   := (sel.GroupByCols.Count > 0) or HasAggregate(sel);
    usedOrder   := (sel.OrderBy <> nil) and (sel.OrderBy.Count > 0);
    usedLimit   := (sel.LimitVal >= 0) or (sel.OffsetVal > 0);
    usedJoin    := sel.HasJoin;
    usedAgg     := HasAggregate(sel);
    usedWindow  := HasWindow(sel);
    usedQualify := sel.QualifyClause <> nil;

    if usedJoin then
    begin
      Add('Nested Loop Join');
      // R-15 Full CBO: iki tablo da ANALYZE edildiyse nested-loop'un
      // dis (driving) tarafini tahmini DAHA KUCUK olan tablo yapar.
      hasA := GetTableStats(sel.FromTable, stA);
      hasB := GetTableStats(sel.Join.Table, stB);
      if hasA and hasB and (not VdbJoinOuterFirst(stA.RowCount, stB.RowCount)) then
      begin
        Add('  -> Seq Scan on ' + sel.Join.Table + '  ' + VdbFormatCost(SeqEst(stB.RowCount)));
        Add('  -> Seq Scan on ' + sel.FromTable + '  ' + VdbFormatCost(SeqEst(stA.RowCount)));
      end
      else
      begin
        if hasA then
          Add('  -> Seq Scan on ' + sel.FromTable + '  ' + VdbFormatCost(SeqEst(stA.RowCount)))
        else
          Add('  -> Seq Scan on ' + sel.FromTable);
        if hasB then
          Add('  -> Seq Scan on ' + sel.Join.Table + '  ' + VdbFormatCost(SeqEst(stB.RowCount)))
        else
          Add('  -> Seq Scan on ' + sel.Join.Table);
      end;
    end
    else if TryCteOk(sel.FromTable) then
      Add('CTE Scan on ' + sel.FromTable)
    else
    begin
      td := FT.GetTable(sel.FromTable);
      pkUsed := HasPkLookup(td);
      hasStats := GetTableStats(td.Name, tblStats);
      // R-14 Full: ORDER BY + ANALYZE istatistigi + esik ustu satir sayisi
      // varsa Seq Scan ciktisi "Parallel ... (workers=N)" olarak isaretlenir
      // (siralama gercekten iscilere dagitilacak). Plan ile yurutme ayni
      // esigi (VDB_PAR_SORT_MIN_ROWS) kullanir.
      parRows := -1;
      if usedOrder and hasStats then
        parRows := tblStats.RowCount;
      if pkUsed then
      begin
        nonSeqPath := True;   // R-13 Full: PK nokta aramasi -> pruning yok
        base := 'Index Scan using ' + td.Name + '_pkey on ' + sel.FromTable;
        if hasStats then
        begin
          est.Kind := pkPkLookup;
          est.EstRows := 1;
          est.StartupCost := VDB_C_IDX_PROBE;
          est.TotalCost := VDB_C_IDX_PROBE + VDB_C_IDX_FETCH;
          base := base + '  ' + VdbFormatCost(est);
        end;
        // PK nokta aramasi 1 satir dondurur: paralellik soz konusu olmaz.
        Add(GetParallelPlanText(base, 1));
      end
      else if IndexUsedByWhere(td, sel.WhereClause, idxName) then
      begin
        nonSeqPath := True;   // R-13 Full: indeks dilimi -> pruning yok
        // F-19: indeks tablonun tum kolonlarini kapsiyorsa tabloya
        // hic okunmaz (index-only scan).
        covAll := FT.IdxCoversAll(td, FT.IdxPosOfName(sel.FromTable, idxName));
        if hasStats then
        begin
          // R-15 Full CBO: seciciligi ANALYZE istatistiginden tahmin et
          // ve indeksin gercekten kazanip kazanmadigina karar ver.
          if EqColStats(td, eqDistinct, eqNulls, eqMCV) then
          begin
            if eqMCV >= 0 then
              est := VdbChooseScanForRows(tblStats.RowCount, eqMCV, True, covAll)
            else
              est := VdbChooseScan(tblStats.RowCount, eqDistinct, eqNulls, True, covAll);
          end
          else if RangeColEst(td, rangeRows) then
            // H8: aralik seçiciliği ANALYZE min/max'tan (uniform) -> gerçek
            // yürütmenin dilim-temelli kararıyla tutarlı.
            est := VdbChooseScanForRows(tblStats.RowCount, rangeRows, True, covAll)
          else
          begin
            rangeRows := tblStats.RowCount div 3;
            if rangeRows < 1 then rangeRows := 1;
            est := VdbChooseScanForRows(tblStats.RowCount, rangeRows, True, covAll);
          end;
          if est.Kind = pkSeqScan then
            base := 'Seq Scan on ' + sel.FromTable + '  (Filter: ' +
              DescribeExpr(sel.WhereClause) + ')  ' + VdbFormatCost(est)
          else if est.Kind = pkIndexOnlyScan then
            base := 'Index Only Scan using ' + StripIdxMark(idxName) +
              ' on ' + sel.FromTable + '  ' + VdbFormatCost(est)
          else
            base := 'Index Scan using ' + StripIdxMark(idxName) +
              ' on ' + sel.FromTable + '  ' + VdbFormatCost(est);
        end
        else if covAll then
          base := 'Index Only Scan using ' + StripIdxMark(idxName) + ' on ' + sel.FromTable
        else
          base := 'Index Scan using ' + StripIdxMark(idxName) + ' on ' + sel.FromTable;
        // R-14 Full: CBO indeksi reddedip Seq Scan sectiyse ve ORDER BY
        // buyuk kumeyi siraliyorsa dugum paralel isaretlenir; indeks
        // taramalari paralel degildir.
        if hasStats and (est.Kind = pkSeqScan) then
          Add(GetParallelPlanText(base, parRows))
        else
          Add(base);
      end
      else if usedWhere then
      begin
        nonSeqPath := False;  // R-13 Full: Seq Scan + Filter -> pruning gecerli
        base := 'Seq Scan on ' + sel.FromTable + '  (Filter: ' +
          DescribeExpr(sel.WhereClause) + ')';
        if hasStats then base := base + '  ' + VdbFormatCost(SeqEst(tblStats.RowCount));
        Add(GetParallelPlanText(base, parRows));
      end
      else
      begin
        nonSeqPath := False;  // R-13 Full: kosulsuz Seq Scan -> 4/4 raporu
        base := 'Seq Scan on ' + sel.FromTable;
        if hasStats then base := base + '  ' + VdbFormatCost(SeqEst(tblStats.RowCount));
        Add(GetParallelPlanText(base, parRows));
      end;
      // R-13 Full: bolme bilgisi (yalniz bolunmus tablolarda yazilir;
      // eski plan ciktisi bozulmaz). Pruning yalniz tam tarama yolunda
      // uygulanir (NarrowRows basarili olursa satirlar zaten indeksten
      // okunur) — bu yuzden PK/indeks planlarinda hic yazilmaz.
      if (td.PartType <> '') and (not nonSeqPath) then
      begin
        pt2 := PartTargetsOf(td, sel.WhereClause);
        if pt2.HasFilter then
          Add('  partitions scanned: ' + IntToStr(Length(pt2.Parts)) + '/' +
            IntToStr(FT.PartCountOf(td)) + ' (' + td.PartType + ' pruning)')
        else
          Add('  partitions scanned: ' + IntToStr(FT.PartCountOf(td)) + '/' +
            IntToStr(FT.PartCountOf(td)) + ' (no pruning)');
      end;
    end;

    if usedAgg then Add('Aggregate');
    if usedGroup then Add('Group');
    if usedWindow then Add('WindowAgg');
    if usedQualify then Add('Qualify');
    if usedOrder then Add('Sort');
    if usedLimit then Add('Limit');
  end;

  if Stmt.Analyze then
  begin
    t0 := VdbTickMs;
    innerR := Execute(Stmt.Inner);
    i := Integer(VdbTickMs - t0);
    Add('Actual Rows: ' + IntToStr(Length(innerR.Rows)));
    Add('Execution Time: ' + IntToStr(i) + ' ms');
  end;

  SetLength(Res.Fields, 1);
  Res.Fields[0] := 'QUERY PLAN';
  SetLength(Res.Rows, Length(plan));
  for i := 0 to High(plan) do
  begin
    SetLength(Res.Rows[i], 1);
    Res.Rows[i][0] := plan[i];
  end;
  Res.Affected := Length(Res.Rows);
  Res.Msg := IntToStr(Length(Res.Rows)) + ' plan satiri';
end;
// R-15: Cost-Based Optimizer - ANALYZE komutu (istatistik toplama)
procedure TVSqlExecutor.ExecAnalyze(const Stmt: TSqlAdminStmt; out Res: TSqlResult);
var
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  rowCount: Integer;
  idxCount: Integer;
  avgRowLen: Integer;
  i, j: Integer;
  totalLen: Int64;
  colNames, colDistinct, colNulls, colMins, colMaxs, colMCVs: array of string;
  distinctCounts, nullCounts: array of Int64;
  minVals, maxVals: array of string;
  dicts: array of TDictionary<string, Integer>;   // R-15: gercek distinct

  { H8: en sik 32 degeri MCV olarak paketle. Cok yuksek distinct'li
    kolonlarda tarama maliyetini sinirlamak icin 200k ustunu atla. }
  function BuildMCV(d: TDictionary<string, Integer>): string;
  const
    MCV_MAX = 32;
  var
    bestV: array[0..MCV_MAX - 1] of string;
    bestC: array[0..MCV_MAX - 1] of Int64;
    n, pos, k, c: Integer;
    pair: TPair<string, Integer>;
    vals: array of string;
    cnts: array of Int64;
  begin
    Result := '';
    if (d.Count = 0) or (d.Count > 200000) then Exit;
    n := 0;
    for pair in d do
    begin
      c := pair.Value;
      pos := n;
      for k := 0 to n - 1 do
        if c > bestC[k] then
        begin
          pos := k;
          Break;
        end;
      if pos >= MCV_MAX then Continue;
      if n < MCV_MAX then Inc(n);
      for k := n - 1 downto pos + 1 do
      begin
        bestV[k] := bestV[k - 1];
        bestC[k] := bestC[k - 1];
      end;
      bestV[pos] := pair.Key;
      bestC[pos] := c;
    end;
    SetLength(vals, n);
    SetLength(cnts, n);
    for k := 0 to n - 1 do
    begin
      vals[k] := bestV[k];
      cnts[k] := bestC[k];
    end;
    Result := VdbStatsPackMCV(vals, cnts);
  end;
begin
  // Stmt.TableName ile tablo hedeflenir (ANALYZE [TABLE] <tablo>)
  if Stmt.TableName = '' then
  begin
    // R-15 Full: tablo belirtilmeden ANALYZE desteklenmez ("tum tablolar"
    // modu yoktur). Sessiz no-op yerine ACIK hata: aksi halde kullanici
    // istatistigin guncellendigini sanirdi.
    raise EVDbException.Create(ecSyntaxError,
      'ANALYZE: tablo belirtilmedi (kullanim: ANALYZE [TABLE] <tablo>)');
  end;

  td := FT.GetTable(Stmt.TableName);

  // Satır sayısı ve veri oku
  rowCount := FT.ScanRows(td.Name, pks, rows);
  totalLen := 0;
  for i := 0 to rowCount - 1 do
  begin
    totalLen := totalLen + Length(rows[i][0]);
  end;
  if rowCount > 0 then
    avgRowLen := totalLen div rowCount
  else
    avgRowLen := 0;

  // İndeks sayısı
  idxCount := Length(td.Idx);

  // Kolon istatistikleri topla
  SetLength(colNames, Length(td.Cols));
  SetLength(colDistinct, Length(td.Cols));
  SetLength(colNulls, Length(td.Cols));
  SetLength(colMins, Length(td.Cols));
  SetLength(colMaxs, Length(td.Cols));
  SetLength(colMCVs, Length(td.Cols));
  SetLength(distinctCounts, Length(td.Cols));
  SetLength(nullCounts, Length(td.Cols));
  SetLength(minVals, Length(td.Cols));
  SetLength(maxVals, Length(td.Cols));

  for j := 0 to High(td.Cols) do
  begin
    colNames[j] := td.Cols[j].Name;
    distinctCounts[j] := 0;
    nullCounts[j] := 0;
    minVals[j] := '';
    maxVals[j] := '';
  end;

  // Basit distinct/null/min/max hesapla (tüm satırları tara)
  // R-15 Full: DISTINCT sayimi gercek kova (hash) ile yapilir; eski kod
  // bos olmayan HER degeri sayiyordu (distinct = rowcount olurdu ve
  // secicilik tahmini anlamsizlasirdi).
  SetLength(dicts, Length(td.Cols));
  for j := 0 to High(td.Cols) do
    dicts[j] := TDictionary<string, Integer>.Create;
  try
    for i := 0 to rowCount - 1 do
    begin
      for j := 0 to High(td.Cols) do
      begin
        if (i < Length(rows)) and (j < Length(rows[i])) then
        begin
          if rows[i][j] = '' then
            Inc(nullCounts[j])
          else
          begin
            if dicts[j].ContainsKey(rows[i][j]) then
              dicts[j][rows[i][j]] := dicts[j][rows[i][j]] + 1
            else
              dicts[j].Add(rows[i][j], 1);
            if (minVals[j] = '') or (rows[i][j] < minVals[j]) then
              minVals[j] := rows[i][j];
            if (maxVals[j] = '') or (rows[i][j] > maxVals[j]) then
              maxVals[j] := rows[i][j];
          end;
        end;
      end;
    end;
    for j := 0 to High(td.Cols) do
    begin
      distinctCounts[j] := dicts[j].Count;
      colMCVs[j] := BuildMCV(dicts[j]);
    end;
  finally
    for j := 0 to High(dicts) do dicts[j].Free;
  end;

  for j := 0 to High(td.Cols) do
  begin
    colDistinct[j] := IntToStr(distinctCounts[j]);
    colNulls[j] := IntToStr(nullCounts[j]);
    colMins[j] := minVals[j];
    colMaxs[j] := maxVals[j];
  end;

  // İndeks sayısı
  idxCount := Length(td.Idx);

  // VDbMonitor'a kaydet (genişletilmiş)
  RecordTableStats(td.Name, rowCount, avgRowLen, idxCount,
    colNames, colDistinct, colNulls, colMins, colMaxs, colMCVs);

  Res.Affected := 1;
  Res.Msg := Format('ANALYZE %s: rows=%d, avg_len=%d, indexes=%d',
    [td.Name, rowCount, avgRowLen, idxCount]);
end;

procedure TVSqlExecutor.ExecAdmin(Stmt: TSqlAdminStmt; out Res: TSqlResult);
var
  rep: string;
  vOld, vNew: Int64;
  tbls, tmpi: TStrArray;
  tmprow: TStrMatrix;
  i, j: Integer;
  td: TTableDef;
  cn, chk, fkCol: string;
  icols: TIntArray;
  lst: TStrArray;      // R-16: arsiv segment listesi
  bar, n16: Integer;   // R-16
  st: TReplicationState; // R-17
  slots: TReplSlotArray; // R-17
  nRep, kRep: Integer;   // R-17
  pmsg: string;          // R-17
  // R-17 Full: TCP akisi
  tcpErr: string;          // StartTcpSender/Receiver hata mesaji
  tcpIsPrimary: Boolean;   // SHOW STATUS: TCP rolu
  tcpSlot, tcpInfo: string; // SHOW STATUS: TCP slot + bilgi
  tcpArch: string;         // PRIMARY TCP: arsiv dizini
  // R-21: Extension/Plugin
  errExt: string;
  nExt, kExt: Integer;
  ei: TVdbExtensionInfo;
begin
  case Stmt.Kind of
    admVerify:
      begin
        if FT.Kv.Verify(rep) then
        begin Res.Affected := 1; Res.Msg := 'VERIFY: ' + rep; end
        else
        begin Res.Affected := 0; Res.Msg := 'VERIFY HATASI: ' + rep; end;
      end;
    admAnalyze:
      begin
        ExecAnalyze(Stmt, Res);
      end;
    admVacuum:
      begin
        FT.Kv.Compact(vOld, vNew);
        Res.Affected := 1;
        Res.Msg := Format('VACUUM %d -> %d bayt (%d kazanc)', [vOld, vNew, vOld - vNew]);
      end;
    admReindex:
      begin FT.RebuildIndexes; Res.Affected := 1; Res.Msg := 'OK'; end;
    admShowTables:
      begin
        tbls := FT.TableNames;
        SetLength(Res.Fields, 2);
        Res.Fields[0] := 'table'; Res.Fields[1] := 'rows';
        SetLength(Res.Rows, Length(tbls));
        for i := 0 to High(tbls) do
        begin
          SetLength(Res.Rows[i], 2);
          Res.Rows[i][0] := tbls[i];
          FT.ScanRows(tbls[i], tmpi, tmprow);
          Res.Rows[i][1] := IntToStr(Length(tmprow));
        end;
        Res.Affected := Length(tbls);
        Res.Msg := IntToStr(Length(tbls)) + ' tablo';
      end;
    admBackupDb:
      begin
        FT.Kv.BackupTo(Stmt.BackupPath);
        Res.Affected := 1;
        Res.Msg := 'OK';
        if FT.Kv.ArchiveEnabled then
          Res.Msg := Res.Msg + ' (WAL arsivlendi)';
      end;
    // ---- R-16: WAL ARSIVLEME + PITR ----
    admArchiveSet:
      begin
        if Stmt.ArchiveDir = '' then
          FT.Kv.SetArchiveDir('')
        else
        begin
          FT.Kv.SetArchiveDir(Stmt.ArchiveDir);
          FT.Kv.SetWalSegmentMax(Stmt.ArchiveSize);
        end;
        Res.Affected := 1;
        if FT.Kv.ArchiveEnabled then
          Res.Msg := 'arsiv: ' + FT.Kv.GetArchiveDir +
            ' segment=' + IntToStr(FT.Kv.GetWalSegmentMax)
        else
          Res.Msg := 'arsivleme kapali';
      end;
    admArchiveList:
      begin
        lst := FT.Kv.ListWalArchive;
        SetLength(Res.Fields, 3);
        Res.Fields[0] := 'segment';
        Res.Fields[1] := 'bytes';
        SetLength(Res.Rows, Length(lst));
        for i := 0 to High(lst) do
        begin
          bar := Pos('|', lst[i] + '|');
          SetLength(Res.Rows[i], 2);
          Res.Rows[i][0] := Copy(lst[i], 1, bar - 1);
          Res.Rows[i][1] := Copy(lst[i], bar + 1, MaxInt);
        end;
        Res.Affected := Length(lst);
        Res.Msg := IntToStr(Length(lst)) + ' arsiv segmenti';
      end;
    admRestoreFrom:
      begin
        FT.Kv.RestoreFrom(Stmt.BackupPath);
        Res.Affected := 1; Res.Msg := 'geri yuklendi';
      end;
    admRecoverTo:
      begin
        if not FT.Kv.ArchiveEnabled then
          raise EVDbException.Create(ecInvalidState,
            'RECOVER: WAL arsivleme kapali. Once "ARCHIVE WAL SET DIR=..." calistir.');
        n16 := FT.Kv.RecoverFromArchive(Stmt.RecoverStamp);
        Res.Affected := n16;
        if Stmt.RecoverStamp = 0 then
          Res.Msg := IntToStr(n16) + ' kayit uygulandi (arsivin tamami)'
        else
          Res.Msg := IntToStr(n16) + ' kayit uygulandi (hedef zamana kadar)';
      end;
    admAlterDbKey:
      begin
        FT.Kv.RekeyWithPassword(Stmt.NewKeyPassword);
        Res.Affected := 1; Res.Msg := 'OK';
      end;
    // ---- 2026-10-04: SEMA SORGULARI ----
    admDescribe:
      begin
        td := FT.GetTable(Stmt.TableName);
        SetLength(Res.Fields, 8);
        Res.Fields[0] := 'name';    Res.Fields[1] := 'type';
        Res.Fields[2] := 'notnull'; Res.Fields[3] := 'unique';
        Res.Fields[4] := 'default'; Res.Fields[5] := 'pk';
        Res.Fields[6] := 'autoinc'; Res.Fields[7] := 'position';
        SetLength(Res.Rows, Length(td.Cols));
        for i := 0 to High(td.Cols) do
        begin
          SetLength(Res.Rows[i], 8);
          Res.Rows[i][0] := td.Cols[i].Name;
          Res.Rows[i][1] := VDbColTypeName(td.Cols[i]);
          Res.Rows[i][2] := BoolToStr(td.Cols[i].NotNull, True);
          Res.Rows[i][3] := BoolToStr(td.Cols[i].Unique, True);
          if td.Cols[i].HasDef then Res.Rows[i][4] := td.Cols[i].Def
          else Res.Rows[i][4] := '';
          Res.Rows[i][5] := BoolToStr(td.PkIndex = i, True);
          Res.Rows[i][6] := BoolToStr(td.AutoInc > 0, True);
          Res.Rows[i][7] := IntToStr(i);
        end;
        Res.Affected := Length(td.Cols);
        Res.Msg := Stmt.TableName + ': ' + IntToStr(Length(td.Cols)) + ' sutun';
      end;
    admShowIndexes:
      begin
        td := FT.GetTable(Stmt.TableName);
        // F-17: 'predicate' kolonu PARTIAL indeks kosulunu gosterir,
        // 'nentries' indeks icindeki kayit sayisini (partial'ta tablo satir
        // sayisindan kucuk olabilir).
        // F-18: 'expr' kolonu EXPRESSION indeksinin ifadesini gosterir.
        SetLength(Res.Fields, 10);
        Res.Fields[0] := 'index';    Res.Fields[1] := 'unique';
        Res.Fields[2] := 'columns';  Res.Fields[3] := 'ncols';
        Res.Fields[4] := 'kind';     Res.Fields[5] := 'predicate';
        Res.Fields[6] := 'nentries'; Res.Fields[7] := 'expr';
        Res.Fields[8] := 'include';  // F-19
        Res.Fields[9] := 'valid';    // R-22 Full: CONCURRENTLY durumu
        SetLength(Res.Rows, Length(td.Idx));
        for i := 0 to High(td.Idx) do
        begin
          SetLength(Res.Rows[i], 10);
          Res.Rows[i][0] := td.Idx[i].Name;
          Res.Rows[i][1] := BoolToStr(td.Idx[i].Uniq, True);
          // F-18: ifade indeksinin "columns" alani ifadenin kendisidir
          if td.Idx[i].ExprText <> '' then
            icols := FT.IdxColsOfPosTable(td.TableId, i)
          else if td.Idx[i].Predicate <> '' then
            icols := FT.IdxColsOfPosTable(td.TableId, i)
          else
            icols := FT.IdxColsOfTable(td.TableId, td.Idx[i].Col);
          cn := '';
          for j := 0 to High(icols) do
          begin
            if cn <> '' then cn := cn + ',';
            if (icols[j] >= 0) and (icols[j] < Length(td.Cols)) then
              cn := cn + td.Cols[icols[j]].Name
            else
              cn := cn + '?';
          end;
          Res.Rows[i][2] := cn;
          Res.Rows[i][3] := IntToStr(Length(icols));
          // F-18: ifade indeksi "tek kolonlu" degil, kendi ifadesidir
          if td.Idx[i].ExprText <> '' then
          begin
            Res.Rows[i][2] := td.Idx[i].ExprText;
            Res.Rows[i][3] := '1';
            Res.Rows[i][4] := 'ifade';
          end
          else
          begin
            if Length(td.Idx[i].Cols) > 1 then Res.Rows[i][4] := 'cok kolunlu'
            else Res.Rows[i][4] := 'tek kolunlu';
          end;
          // F-17: partial kosulu ('' = normal indeks)
          Res.Rows[i][5] := td.Idx[i].Predicate;
          Res.Rows[i][6] := IntToStr(FT.IdxEntryCount(td.TableId, i));
          Res.Rows[i][7] := td.Idx[i].ExprText;   // F-18
          // F-19: INCLUDE kolonlari
          cn := '';
          for j := 0 to High(td.Idx[i].Incl) do
          begin
            if cn <> '' then cn := cn + ',';
            if (td.Idx[i].Incl[j] >= 0) and (td.Idx[i].Incl[j] < Length(td.Cols)) then
              cn := cn + td.Cols[td.Idx[i].Incl[j]].Name;
          end;
          Res.Rows[i][8] := cn;
          // R-22 Full: False = CONCURRENTLY insasi suruyor / yarida kaldi
          Res.Rows[i][9] := BoolToStr(not td.Idx[i].Invalid, True);
        end;
        Res.Affected := Length(td.Idx);
        Res.Msg := Stmt.TableName + ': ' + IntToStr(Length(td.Idx)) + ' indeks';
      end;
    admShowCreateTable:
      begin
        td := FT.GetTable(Stmt.TableName);
        cn := 'CREATE TABLE ' + td.Name + ' (';
        for i := 0 to High(td.Cols) do
        begin
          if i > 0 then cn := cn + ', ';
          cn := cn + td.Cols[i].Name + ' ' + VDbColTypeName(td.Cols[i]);
          if td.PkIndex = i then cn := cn + ' PRIMARY KEY';
          if td.Cols[i].NotNull then cn := cn + ' NOT NULL';
          if td.Cols[i].Unique then cn := cn + ' UNIQUE';
          if td.Cols[i].HasDef then
            cn := cn + ' DEFAULT ' + VDbNormValue(td.Cols[i].Ctype, td.Cols[i].Def);
        end;
        cn := cn + ')';
        if td.AutoInc > 0 then cn := cn + ' AUTOINCREMENT';
        SetLength(Res.Fields, 1);
        Res.Fields[0] := 'sql';
        SetLength(Res.Rows, 1);
        SetLength(Res.Rows[0], 1);
        Res.Rows[0][0] := cn;
        // CHECK / FK tanimlari ayrica satirlarda
        for i := 0 to High(td.Checks) do
        begin
          chk := '';
          for j := 0 to High(td.Checks[i]) do
          begin
            if chk <> '' then chk := chk + ' AND ';
            if td.Checks[i][j].Col >= 0 then
              chk := chk + VDbNorm(td.Cols[td.Checks[i][j].Col].Name) + ' ' +
                td.Checks[i][j].Op + ' ' +
                VDbNormValue(td.Cols[td.Checks[i][j].Col].Ctype, td.Checks[i][j].Val)
            else
              chk := chk + '?';
          end;
          if chk <> '' then
          begin
            SetLength(Res.Rows, Length(Res.Rows) + 1);
            SetLength(Res.Rows[High(Res.Rows)], 1);
            Res.Rows[High(Res.Rows)][0] := 'CHECK (' + chk + ')';
          end;
        end;
        for i := 0 to High(td.Fks) do
        begin
          if (td.Fks[i].Col >= 0) and (td.Fks[i].Col < Length(td.Cols)) then
            fkCol := td.Cols[td.Fks[i].Col].Name
          else
            fkCol := '?';
          SetLength(Res.Rows, Length(Res.Rows) + 1);
          SetLength(Res.Rows[High(Res.Rows)], 1);
          Res.Rows[High(Res.Rows)][0] := 'FOREIGN KEY (' + fkCol + ') REFERENCES ' +
            td.Fks[i].RefTable + '(' + td.Fks[i].RefCol + ')' +
            ' ON DELETE ' + VDbFkActionToStr(td.Fks[i].OnDelete) +
            ' ON UPDATE ' + VDbFkActionToStr(td.Fks[i].OnUpdate);
        end;
        Res.Affected := 1;
        Res.Msg := 'OK';
      end;
    admPragma:
      begin
        Res.Affected := 1;
        Res.Msg := 'PRAGMA ' + Stmt.PragmaName + ': OK';
      end;
    // R-02: SAVEPOINT / Nested Transaction
    admSavepoint:
      begin
        FT.Kv.Savepoint(Stmt.SavepointName);
        Res.Affected := 1; Res.Msg := 'SAVEPOINT ' + Stmt.SavepointName + ' OK';
      end;
    admReleaseSavepoint:
      begin
        FT.Kv.ReleaseSavepoint(Stmt.SavepointName);
        Res.Affected := 1; Res.Msg := 'RELEASE SAVEPOINT ' + Stmt.SavepointName + ' OK';
      end;
    admRollbackToSavepoint:
      begin
        FT.Kv.RollbackToSavepoint(Stmt.SavepointName);
        Res.Affected := 1; Res.Msg := 'ROLLBACK TO SAVEPOINT ' + Stmt.SavepointName + ' OK';
      end;
    // R-17: Streaming Replication
    admReplicationStart:
      begin
        // Slot dosyasi veritabaninin yaninda tutulur.
        SetReplicationDataDir(ExtractFileDir(FT.Kv.FilePath));
        // ---- R-17 Full: GERCEK TCP AKIS MODU ----
        if Stmt.ReplTcp then
        begin
          if Stmt.ReplIsPrimary then
          begin
            tcpArch := FT.Kv.GetArchiveDir;
            if tcpArch = '' then
            begin
              Res.Affected := 0;
              Res.Msg := 'PRIMARY TCP replication FAILED: arsiv dizini ayarli' +
                ' degil (once ARCHIVE WAL SET gerekir)';
            end
            else if StartTcpSender(FT.Kv, Stmt.ReplPort, Stmt.ReplSlot, tcpErr) then
            begin
              Res.Affected := 1;
              Res.Msg := 'PRIMARY TCP replication started (slot: ' + Stmt.ReplSlot +
                ', port: ' + IntToStr(Stmt.ReplPort) + ', archive: ' + tcpArch + ')';
            end
            else
              Res.Msg := 'PRIMARY TCP replication FAILED: ' + tcpErr;
          end
          else
          begin
            if StartTcpReceiver(FT.Kv, Stmt.ReplHost, Stmt.ReplPort,
              Stmt.ReplSlot, tcpErr) then
            begin
              Res.Affected := 1;
              Res.Msg := 'STANDBY TCP replication started (slot: ' + Stmt.ReplSlot +
                ', src: ' + Stmt.ReplHost + ':' + IntToStr(Stmt.ReplPort) + ')';
            end
            else
              Res.Msg := 'STANDBY TCP replication FAILED: ' + tcpErr;
          end;
        end
        else
        // ---- R-17 mini: dosya (log-shipping) modu ----
        if Stmt.ReplIsPrimary then
        begin
          // PRIMARY mode: DEST (Stmt.ReplConnInfo) ship dizinidir.
          if StartReplicationPrimary(Stmt.ReplSlot, Stmt.ReplConnInfo) then
            Res.Msg := 'PRIMARY replication started (slot: ' + Stmt.ReplSlot +
              ', dest: ' + Stmt.ReplConnInfo + ')'
          else
            Res.Msg := 'PRIMARY replication FAILED';
          Res.Affected := 1;
        end
        else
        begin
          // STANDBY mode: conn_info = primary ship dizini
          if StartReplicationStandby(Stmt.ReplConnInfo, Stmt.ReplSlot) then
            Res.Msg := 'STANDBY replication started (slot: ' + Stmt.ReplSlot +
              ', src: ' + Stmt.ReplConnInfo + ')'
          else
            Res.Msg := 'STANDBY replication FAILED';
          Res.Affected := 1;
        end;
      end;
    admReplicationPump:
      begin
        // R-17 Full: TCP akisinda tek adim PUMP anlamsizdir; akis zaten
        // canlidir. PUMP yalnizca dosya (log-shipping) modunda gecerlidir.
        if TcpActiveForDb(FT.Kv) then
        begin
          Res.Affected := 0;
          Res.Msg := 'PUMP: TCP akisi aktif (tek adim PUMP yalniz dosya modunda)';
        end
        else
        begin
          SetReplicationDataDir(ExtractFileDir(FT.Kv.FilePath));
          if GetReplicationStatus(st) then
          begin
            if PumpReplication(FT.Kv, st.PrimaryConnInfo, nRep, pmsg) then
            begin
              Res.Affected := nRep;
              Res.Msg := pmsg;
            end
            else
            begin
              Res.Affected := 0;
              Res.Msg := pmsg;
            end;
          end
          else
          begin
            Res.Affected := 0; Res.Msg := 'PUMP: status unavailable';
          end;
        end;
      end;
    admReplicationStop:
      begin
        // R-17 Full: once bu DB'nin TCP akisini (varsa) durdur.
        if StopTcpForDb(FT.Kv) then
        begin
          Res.Affected := 1;
          Res.Msg := 'TCP replication stopped';
        end
        else
        begin
          StopReplication;
          Res.Affected := 1; Res.Msg := 'replication stopped';
        end;
      end;
    admCreateReplSlot:
      begin
        SetReplicationDataDir(ExtractFileDir(FT.Kv.FilePath));
        if CreateReplicationSlot(Stmt.ReplSlot) then
          Res.Msg := 'replication slot created: ' + Stmt.ReplSlot
        else
          Res.Msg := 'replication slot FAILED: ' + Stmt.ReplSlot;
        Res.Affected := 1;
      end;
    admDropReplSlot:
      begin
        SetReplicationDataDir(ExtractFileDir(FT.Kv.FilePath));
        DropReplicationSlot(Stmt.ReplSlot);
        Res.Affected := 1; Res.Msg := 'replication slot dropped: ' + Stmt.ReplSlot;
      end;
    admShowReplSlots:
      begin
        SetReplicationDataDir(ExtractFileDir(FT.Kv.FilePath));
        slots := GetReplicationSlots;
        SetLength(Res.Fields, 4);
        Res.Fields[0] := 'slot'; Res.Fields[1] := 'restart_lsn';
        Res.Fields[2] := 'confirmed_lsn'; Res.Fields[3] := 'active';
        SetLength(Res.Rows, Length(slots));
        for kRep := 0 to High(slots) do
        begin
          SetLength(Res.Rows[kRep], 4);
          Res.Rows[kRep][0] := slots[kRep].SlotName;
          Res.Rows[kRep][1] := IntToStr(slots[kRep].RestartLSN);
          Res.Rows[kRep][2] := IntToStr(slots[kRep].ConfirmedLSN);
          Res.Rows[kRep][3] := BoolToStr(slots[kRep].Active, True);
        end;
        Res.Affected := Length(slots);
        Res.Msg := IntToStr(Length(slots)) + ' slot';
      end;
    admShowReplicationStatus:
      begin
        SetLength(Res.Fields, 5);
        Res.Fields[0] := 'role'; Res.Fields[1] := 'slot';
        Res.Fields[2] := 'conn_info'; Res.Fields[3] := 'last_lsn';
        Res.Fields[4] := 'running';
        SetLength(Res.Rows, 1);
        SetLength(Res.Rows[0], 5);
        // R-17 Full: TCP akisi once — global dosya-modu durumundan once.
        if TcpReplStatus(FT.Kv, tcpIsPrimary, tcpSlot, tcpInfo) then
        begin
          if tcpIsPrimary then
            Res.Rows[0][0] := 'primary/tcp'
          else
            Res.Rows[0][0] := 'standby/tcp';
          Res.Rows[0][1] := tcpSlot;
          Res.Rows[0][2] := tcpInfo;
          Res.Rows[0][3] := '';
          Res.Rows[0][4] := 'True';
          Res.Affected := 1; Res.Msg := 'OK';
        end
        else if GetReplicationStatus(st) then
        begin
          case st.Role of
            rrNone: Res.Rows[0][0] := 'none';
            rrPrimary: Res.Rows[0][0] := 'primary';
            rrStandby: Res.Rows[0][0] := 'standby';
          end;
          Res.Rows[0][1] := st.SlotName;
          Res.Rows[0][2] := st.PrimaryConnInfo;
          Res.Rows[0][3] := IntToStr(st.LastLSN);
          Res.Rows[0][4] := BoolToStr(st.IsRunning, True);
          Res.Affected := 1; Res.Msg := 'OK';
        end
        else
        begin
          SetLength(Res.Rows, 0);
          Res.Affected := 0; Res.Msg := 'status unavailable';
        end;
      end;
    // ---- R-21: EXTENSION / PLUGIN ----
    admCreateExtension:
      begin
        if ExtensionLoaded(Stmt.ExtName) then
        begin
          if Stmt.IfNotExists then
          begin Res.Affected := 1; Res.Msg := 'extension zaten var: ' + Stmt.ExtName; end
          else
          begin Res.Affected := 0; Res.Msg := 'CREATE EXTENSION HATASI: zaten yuklu: ' + Stmt.ExtName; end;
        end
        else if LoadExtension(Stmt.ExtName, Stmt.ExtPath, errExt) then
        begin Res.Affected := 1; Res.Msg := 'extension olusturuldu: ' + Stmt.ExtName; end
        else
        begin Res.Affected := 0; Res.Msg := 'CREATE EXTENSION HATASI: ' + errExt; end;
      end;
    admDropExtension:
      begin
        if DropExtension(Stmt.ExtName) then
        begin Res.Affected := 1; Res.Msg := 'extension kaldirildi: ' + Stmt.ExtName; end
        else if Stmt.IfExists then
        begin Res.Affected := 1; Res.Msg := 'extension yok (yoksayildi): ' + Stmt.ExtName; end
        else
        begin Res.Affected := 0; Res.Msg := 'DROP EXTENSION HATASI: bulunamadi: ' + Stmt.ExtName; end;
      end;
    admShowExtensions:
      begin
        nExt := ExtensionCount;
        SetLength(Res.Fields, 4);
        Res.Fields[0] := 'name';
        Res.Fields[1] := 'api_version';
        Res.Fields[2] := 'file';
        Res.Fields[3] := 'description';
        SetLength(Res.Rows, nExt);
        for kExt := 0 to nExt - 1 do
          if GetExtensionInfo(kExt, ei) then
          begin
            SetLength(Res.Rows[kExt], 4);
            Res.Rows[kExt][0] := ei.Name;
            Res.Rows[kExt][1] := Format('0x%.8x', [ei.ApiVersion]);
            Res.Rows[kExt][2] := ExtractFileName(ei.FileName);
            Res.Rows[kExt][3] := ei.Description;
          end;
        Res.Affected := nExt;
        Res.Msg := IntToStr(nExt) + ' extension';
      end;
    // R-13 Full: SHOW PARTITIONS t
    admShowPartitions: ExecShowPartitions(Stmt, Res);
    // R-24 (2026-10-13): SHOW STATS / SHOW STATS TABLE t
    admShowStats: ExecShowStats(Stmt, Res);
  else
    Res.Affected := 0; Res.Msg := 'OK';
  end;
end;

{ ------------------------------------------------------------
  ExecShowPartitions (R-13 Full)
  SHOW PARTITIONS t — bolum listesi ve bolum basina satir sayilari.
  HASH: p0..pN-1; LIST: deger bolumleri + DEFAULT; RANGE: BELOW /
  RANGE / ABOVE.
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecShowPartitions(Stmt: TSqlAdminStmt; out Res: TSqlResult);
var
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  cnt: TIntArray;
  i, np, pno: Integer;
begin
  td := FT.GetTable(Stmt.TableName);
  if td.PartType = '' then
    raise EVDbException.Create(ecUnsupported,
      'tablo bolunmemis: ' + Stmt.TableName);
  np := FT.PartCountOf(td);
  if np < 1 then
    raise EVDbException.Create(ecUnsupported,
      'bolum sayisi gecersiz: ' + Stmt.TableName);
  SetLength(cnt, np);
  for i := 0 to np - 1 do cnt[i] := 0;
  FT.ScanRows(Stmt.TableName, pks, rows);
  for i := 0 to High(rows) do
  begin
    pno := FT.PartRowOf(td, rows[i]);
    if (pno >= 0) and (pno < np) then Inc(cnt[pno]);
  end;
  SetLength(Res.Fields, 4);
  Res.Fields[0] := 'part';
  Res.Fields[1] := 'type';
  Res.Fields[2] := 'label';
  Res.Fields[3] := 'rows';
  SetLength(Res.Rows, np);
  for i := 0 to np - 1 do
  begin
    SetLength(Res.Rows[i], 4);
    Res.Rows[i][0] := IntToStr(i);
    Res.Rows[i][1] := td.PartType;
    Res.Rows[i][2] := FT.PartLabelOf(td, i);
    Res.Rows[i][3] := IntToStr(cnt[i]);
  end;
  Res.Affected := np;
  Res.Msg := Stmt.TableName + ': ' + IntToStr(np) + ' bolum, ' +
    IntToStr(Length(rows)) + ' satir';
end;

{ ------------------------------------------------------------
  ExecShowStats (R-24, 2026-10-13)
    SHOW STATS              -> global olcumler (name|value)
    SHOW STATS TABLE <t>    -> ANALYZE istatistikleri (ozet + kolon satirlari)
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecShowStats(Stmt: TSqlAdminStmt; out Res: TSqlResult);
var
  ms: TVDbMonitorStats;
  ts: TVDbTableStats;
  avg: UInt64;
  i: Integer;
  hits, misses: Int64;
  usedB, maxB: Integer;
  ratio: Double;
begin
  if Stmt.TableName <> '' then
  begin
    // ---- Tablo bazli: ANALYZE istatistikleri ----
    FT.GetTable(Stmt.TableName);   // yoksa ecTableNotFound yukselir
    if not GetTableStats(Stmt.TableName, ts) then
      raise EVDbException.Create(ecUnsupported,
        'istatistik yok (once ANALYZE calistirin): ' + Stmt.TableName);
    SetLength(Res.Fields, 8);
    Res.Fields[0] := 'column';
    Res.Fields[1] := 'rows';
    Res.Fields[2] := 'avg_row_len';
    Res.Fields[3] := 'index_count';
    Res.Fields[4] := 'distinct';
    Res.Fields[5] := 'nulls';
    Res.Fields[6] := 'min';
    Res.Fields[7] := 'max';
    SetLength(Res.Rows, Length(ts.ColStats) + 1);
    // ozet satiri: column = tablo adi; rows/avg/indexes doldurulur
    SetLength(Res.Rows[0], 8);
    Res.Rows[0][0] := ts.TableName;
    Res.Rows[0][1] := IntToStr(ts.RowCount);
    Res.Rows[0][2] := IntToStr(ts.AvgRowLen);
    Res.Rows[0][3] := IntToStr(ts.IndexCount);
    Res.Rows[0][4] := '';
    Res.Rows[0][5] := '';
    Res.Rows[0][6] := '';
    Res.Rows[0][7] := '';
    for i := 0 to High(ts.ColStats) do
    begin
      SetLength(Res.Rows[i + 1], 8);
      Res.Rows[i + 1][0] := ts.ColStats[i].ColName;
      Res.Rows[i + 1][1] := '';
      Res.Rows[i + 1][2] := '';
      Res.Rows[i + 1][3] := '';
      Res.Rows[i + 1][4] := IntToStr(ts.ColStats[i].DistinctCount);
      Res.Rows[i + 1][5] := IntToStr(ts.ColStats[i].NullCount);
      Res.Rows[i + 1][6] := ts.ColStats[i].MinVal;
      Res.Rows[i + 1][7] := ts.ColStats[i].MaxVal;
    end;
    Res.Affected := Length(Res.Rows);
    Res.Msg := ts.TableName + ': ' + IntToStr(ts.RowCount) +
      ' satir (ANALYZE)';
    Exit;
  end;

  // ---- Genel: pg_stat benzeri global sayaclar ----
  GetStats(ms);
  avg := 0;
  if ms.CommandCount > 0 then
    avg := ms.TotalDurationUs div ms.CommandCount;
  SetLength(Res.Fields, 2);
  Res.Fields[0] := 'name';
  Res.Fields[1] := 'value';
  FT.Kv.GetReadCacheStats(hits, misses, usedB, maxB);
  ratio := 0;
  if (hits + misses) > 0 then
    ratio := hits * 100.0 / (hits + misses);
  SetLength(Res.Rows, 13);
  SetLength(Res.Rows[0], 2);
  Res.Rows[0][0] := 'commands';
  Res.Rows[0][1] := IntToStr(ms.CommandCount);
  SetLength(Res.Rows[1], 2);
  Res.Rows[1][0] := 'total_us';
  Res.Rows[1][1] := IntToStr(ms.TotalDurationUs);
  SetLength(Res.Rows[2], 2);
  Res.Rows[2][0] := 'max_us';
  Res.Rows[2][1] := IntToStr(ms.MaxDurationUs);
  SetLength(Res.Rows[3], 2);
  Res.Rows[3][0] := 'avg_us';
  Res.Rows[3][1] := IntToStr(avg);
  SetLength(Res.Rows[4], 2);
  Res.Rows[4][0] := 'wal_records';
  Res.Rows[4][1] := IntToStr(FT.Kv.WalAutoCount);
  SetLength(Res.Rows[5], 2);
  Res.Rows[5][0] := 'tables_analyzed';
  Res.Rows[5][1] := IntToStr(AnalyzedTableCount);
  SetLength(Res.Rows[6], 2);
  Res.Rows[6][0] := 'data_file_bytes';
  Res.Rows[6][1] := IntToStr(FT.Kv.DataFileSize);
  SetLength(Res.Rows[7], 2);
  Res.Rows[7][0] := 'tables';
  Res.Rows[7][1] := IntToStr(Length(FT.TableNames));
  SetLength(Res.Rows[8], 2);
  Res.Rows[8][0] := 'batch_active';
  Res.Rows[8][1] := BoolToStr(FT.Kv.InBatch, True);
  SetLength(Res.Rows[9], 2);
  Res.Rows[9][0] := 'read_cache_blocks';
  Res.Rows[9][1] := IntToStr(usedB) + '/' + IntToStr(maxB);
  SetLength(Res.Rows[10], 2);
  Res.Rows[10][0] := 'cache_hits';
  Res.Rows[10][1] := IntToStr(hits);
  SetLength(Res.Rows[11], 2);
  Res.Rows[11][0] := 'cache_misses';
  Res.Rows[11][1] := IntToStr(misses);
  SetLength(Res.Rows[12], 2);
  Res.Rows[12][0] := 'cache_hit_ratio_pct';
  Res.Rows[12][1] := FormatFloat('0.0', ratio);
  Res.Affected := Length(Res.Rows);
  Res.Msg := IntToStr(ms.CommandCount) + ' komut';
end;

{ ------------------------------------------------------------
  JSON Handler
  //---------------------------------------------------------- }
procedure TVSqlExecutor.ExecJson(Stmt: TSqlJsonStmt; out Res: TSqlResult);
begin
  case Stmt.Kind of
    jsoExport:
      begin
        // VDbExportJson: Table='' ise tum veritabani, dolu ise tek tablo
        VDbExportJson(FT, Stmt.FilePath, Stmt.Table);
        Res.Affected := 1; Res.Msg := 'OK';
      end;
    jsoImport:
      begin
        VDbImportJson(FT, Stmt.FilePath);
        Res.Affected := 1; Res.Msg := 'OK';
      end;
  end;
end;


{ ------------------------------------------------------------
  Execute - Ana giris noktasi
  //---------------------------------------------------------- }
function TVSqlExecutor.Execute(Stmt: TSqlStmtNode): TSqlResult;
var
  vSet: TDictionary<string, Byte>;  // F2-20: IN kume serbest birakimi
  st: TSqlStmtNode;
  i: Integer;
  o1, o2: string;
  prevSess: Cardinal;
begin

  Result.Affected := 0;
  SetLength(Result.Fields, 0);
  SetLength(Result.FieldTypes, 0);
  SetLength(Result.Rows, 0);
  if Stmt = nil then Exit;

  // F-41: bu cumleyi calistiran oturumu yazma yoluna bildir.
  prevSess := VDbGetWriteSession;
  VDbSetWriteSession(FSessionId);

  // R-17 Full: TCP akisindaki standby motoru alici THREAD'E aittir.
  // STOP REPLICATION ve SHOW REPLICATION STATUS disindaki her cumle
  // reddedilir (motor aliciya birakmadan SQL calistirmak yaris kosulu
  // yaratir; once STOP REPLICATION ile serbest birakilir).
  if IsStreamingDb(FT.Kv) and not ((Stmt is TSqlAdminStmt) and
    (TSqlAdminStmt(Stmt).Kind in [admReplicationStop,
    admShowReplicationStatus])) then
    raise EVDbException.Create(ecDatabaseLocked,
      'STANDBY TCP akisi aktif: once STOP REPLICATION (motor aliciya aittir)');

  // R-22 Full: CREATE INDEX CONCURRENTLY aninda doner; sonraki cumlelerin
  // basinda bitmis arka plan insalari FINALIZE edilir (girdiler kurulur,
  // catch-up uygulanir, indeks gecerli isaretlenir). "Online" tamamlanma
  // noktasi budur: kullanici akisi hic beklemez.
  FT.PollConcurrentIndexes;

  // P5-2: alt sorgu onbellegi + P5-CTE kapsami cumle boyu yasar.
  FSubCache := TDictionary<Pointer, TSqlResult>.Create;
  FInSetCache := TDictionary<Pointer, TDictionary<string, Byte>>.Create;
  FCteTables := TDictionary<string, TCteTable>.Create;
  // F-36: FOuterRow/FOuterColNames (trigger NEW/OLD baglami) temizligi
  // FireTriggerDef tarafindan yonetilir (kayit/geri yuikleme);
  // burada resetlenmez - trigger govdesindeki nested ifadeler baglami gorur.
  FCurQualifier := '';
  try
    if Stmt is TSqlSelectStmt then
    begin
      // F-03: ust duzey SELECT'in kendi tablosu/alias'i.
      if TSqlSelectStmt(Stmt).FromAlias <> '' then
        FCurQualifier := TSqlSelectStmt(Stmt).FromAlias
      else
        FCurQualifier := TSqlSelectStmt(Stmt).FromTable;
      ExecSelect(TSqlSelectStmt(Stmt), Result);
    end
  else if Stmt is TSqlInsertStmt then ExecInsert(TSqlInsertStmt(Stmt), Result)
  else if Stmt is TSqlUpdateStmt then ExecUpdate(TSqlUpdateStmt(Stmt), Result)
  else if Stmt is TSqlDeleteStmt then ExecDelete(TSqlDeleteStmt(Stmt), Result)
  else if Stmt is TSqlCreateTableStmt then ExecCreateTable(TSqlCreateTableStmt(Stmt), Result)
  else if Stmt is TSqlAlterTableStmt then ExecAlterTable(TSqlAlterTableStmt(Stmt), Result)
  else if Stmt is TSqlDropTableStmt then ExecDropTable(TSqlDropTableStmt(Stmt), Result)
  // F-36: TRIGGER desteği
  else if Stmt is TSqlCreateTriggerStmt then ExecCreateTrigger(TSqlCreateTriggerStmt(Stmt), Result)
  else if Stmt is TSqlDropTriggerStmt then ExecDropTrigger(TSqlDropTriggerStmt(Stmt), Result)
  else if Stmt is TSqlCreateViewStmt then ExecCreateView(TSqlCreateViewStmt(Stmt), Result)
  else if Stmt is TSqlDropViewStmt then ExecDropView(TSqlDropViewStmt(Stmt), Result)
  else if Stmt is TSqlCreateMaterializedViewStmt then ExecCreateMaterializedView(TSqlCreateMaterializedViewStmt(Stmt), Result)
  else if Stmt is TSqlDropMaterializedViewStmt then ExecDropMaterializedView(TSqlDropMaterializedViewStmt(Stmt), Result)
  else if Stmt is TSqlRefreshMaterializedViewStmt then ExecRefreshMaterializedView(TSqlRefreshMaterializedViewStmt(Stmt), Result)
  { F-36: TRIGGER - tetikleyici executor'u henüz yazilmedi, buraya sonradan eklenir.
    { else if Stmt is TSqlCreateTriggerStmt then ExecCreateTrigger(TSqlCreateTriggerStmt(Stmt), Result)
    else if Stmt is TSqlDropTriggerStmt then ExecDropTrigger(TSqlDropTriggerStmt(Stmt), Result)
    }
  else if Stmt is TSqlCreateFunctionStmt then ExecCreateFunction(TSqlCreateFunctionStmt(Stmt), Result)
  else if Stmt is TSqlDropFunctionStmt then ExecDropFunction(TSqlDropFunctionStmt(Stmt), Result)
  else if Stmt is TSqlCreateProcedureStmt then ExecCreateProcedure(TSqlCreateProcedureStmt(Stmt), Result)
  else if Stmt is TSqlDropProcedureStmt then ExecDropProcedure(TSqlDropProcedureStmt(Stmt), Result)
  else if Stmt is TSqlCallStmt then ExecCall(TSqlCallStmt(Stmt), Result)
  else if Stmt is TSqlReturnStmt then
  begin
    // RETURN disarida calistirilirsa: degeri sonuc olarak dondur.
    Result.Fields := TStrArray(['result']);
    Result.Rows := TStrMatrix([TStrArray([
      EvalExpr(TSqlReturnStmt(Stmt).Expr, FProcRow, FProcColNames, nil)])]);
    Result.Affected := 1;
    Result.Msg := 'OK';
  end
  else if Stmt is TSqlBlockStmt then
  begin
    // TRIGGER / PROCEDURE govdesi gibi BEGIN..END bloklarini calistir
    FillChar(Result, SizeOf(Result), 0);
    Result.Msg := 'OK';
    for st in TSqlBlockStmt(Stmt).Stmts do
    begin
      if st is TSqlSetNewStmt then
      begin
        // NEW.kolon atamasi FireTriggerDef tarafindan (BEFORE hook) islenir;
        // aksi takdirde degisim iki kez uygulanir.
        Continue;
      end;
      Result := Execute(st);
    end;

  end
  else if Stmt is TSqlCreateIndexStmt then ExecCreateIndex(TSqlCreateIndexStmt(Stmt), Result)
  else if Stmt is TSqlDropIndexStmt then ExecDropIndex(TSqlDropIndexStmt(Stmt), Result)
  else if Stmt is TSqlTxStmt then ExecTx(TSqlTxStmt(Stmt), Result)
  else if Stmt is TSqlAdminStmt then ExecAdmin(TSqlAdminStmt(Stmt), Result)
  // F-20: EXPLAIN â€” plan uretir (son cumleye kadar zincirde)
  else if Stmt is TSqlExplainStmt then
    ExecExplain(TSqlExplainStmt(Stmt), Result)
  else if Stmt is TSqlJsonStmt then ExecJson(TSqlJsonStmt(Stmt), Result)
  // R-11: SET CONSTRAINTS ALL DEFERRED | IMMEDIATE
  else if Stmt is TSqlSetConstraintsStmt then
    ExecSetConstraints(TSqlSetConstraintsStmt(Stmt), Result)
  else if Stmt is TSqlSetIsolationStmt then
    ExecSetIsolation(TSqlSetIsolationStmt(Stmt), Result)
  else if Stmt is TRoleStmt then
    ExecRole(TRoleStmt(Stmt), Result)
  else if Stmt is TGrantStmt then
    ExecGrant(TGrantStmt(Stmt), Result)
  else if Stmt is TSetRoleStmt then
    ExecSetRole(TSetRoleStmt(Stmt), Result)
  else if Stmt is TPolicyStmt then   // R-19
    ExecPolicy(TPolicyStmt(Stmt), Result)
  // else if Stmt is TSqlCompoundStmt then
  //   ExecCompoundStmt(TSqlCompoundStmt(Stmt), Result)
  else raise EVDbException.Create(ecUnsupported, 'Desteklenmeyen AST cumlesi: ' + Stmt.ClassName);
  finally
    VDbSetWriteSession(prevSess);
    FSubCache.Free;
    FSubCache := nil;
    if FInSetCache <> nil then
    begin
      for vSet in FInSetCache.Values do vSet.Free;
      FInSetCache.Free;
      FInSetCache := nil;
    end;
    FCteTables.Free;
    FCteTables := nil;
  end;
end;

{ R-04: RETURNING - ifadeleri degerlendir }
function TVSqlExecutor.EvaluateReturning(const Stmt: TSqlStmtNode;
  const Row: TStrArray; const ColNames: TStrArray;
  const ColTypes: TByteArray): TStrArray;
var
  i: Integer;
  retCols: TStrArray;
  retExprs: TList<TSqlExprNode>;
  val: string;
begin
  SetLength(Result, 0);
  
  // Stmt tipine gore RETURNING alanlarini al
  if Stmt is TSqlInsertStmt then
  begin
    retCols := TSqlInsertStmt(Stmt).ReturningCols;
    retExprs := TSqlInsertStmt(Stmt).ReturningExprs;
  end
  else if Stmt is TSqlUpdateStmt then
  begin
    retCols := TSqlUpdateStmt(Stmt).ReturningCols;
    retExprs := TSqlUpdateStmt(Stmt).ReturningExprs;
  end
  else if Stmt is TSqlDeleteStmt then
  begin
    retCols := TSqlDeleteStmt(Stmt).ReturningCols;
    retExprs := TSqlDeleteStmt(Stmt).ReturningExprs;
  end
  else Exit;

  // RETURNING * (tum kolonlar)
  if (Length(retCols) = 0) and (retExprs.Count = 0) then
  begin
    SetLength(Result, Length(Row));
    for i := 0 to High(Row) do Result[i] := Row[i];
    Exit;
  end;

  // RETURNING ifadeleri degerlendir
  SetLength(Result, retExprs.Count);
  for i := 0 to retExprs.Count - 1 do
  begin
    val := EvalExpr(retExprs[i], Row, ColNames, ColTypes);
    Result[i] := val;
  end;
end;

function TVSqlExecutor.ReturningHasExpr(Stmt: TSqlStmtNode): Boolean;
{ Parser duz kolon referanslarini da ReturningExprs'e yaziyor
  (bkz. VDbParser.ParseReturning). Bu yuzden "ifade var" demek icin
  kolon referansi OLMAYAN ogeleri aramak gerekir. aksi halde
  `RETURNING val` de "ifadeli" sayilir ve butun RETURNING yolu
  ifade degerlendiricisine kayar. }
var
  exprs: TList<TSqlExprNode>;
  i: Integer;
begin
  Result := False;
  if Stmt is TSqlInsertStmt then exprs := TSqlInsertStmt(Stmt).ReturningExprs
  else if Stmt is TSqlUpdateStmt then exprs := TSqlUpdateStmt(Stmt).ReturningExprs
  else if Stmt is TSqlDeleteStmt then exprs := TSqlDeleteStmt(Stmt).ReturningExprs
  else Exit;
  if exprs = nil then Exit;
  for i := 0 to exprs.Count - 1 do
    if (exprs[i] <> nil) and (not (exprs[i] is TSqlColumnRefNode)) then
      Exit(True);
end;

procedure TVSqlExecutor.BuildReturningNames(Stmt: TSqlStmtNode;
  out Names: TStrArray);
{ RETURNING basligini semaya gore kurar. Kolon referansi olan ogeler
  kendi adini alir; gercek ifadeler "exprN" olarak adlandirilir
  (PostgreSQL de ifadeye isim vermezse "?column?" doner). }
var
  exprs: TList<TSqlExprNode>;
  i: Integer;
begin
  SetLength(Names, 0);
  if Stmt is TSqlInsertStmt then exprs := TSqlInsertStmt(Stmt).ReturningExprs
  else if Stmt is TSqlUpdateStmt then exprs := TSqlUpdateStmt(Stmt).ReturningExprs
  else if Stmt is TSqlDeleteStmt then exprs := TSqlDeleteStmt(Stmt).ReturningExprs
  else Exit;
  if exprs = nil then Exit;
  SetLength(Names, exprs.Count);
  for i := 0 to exprs.Count - 1 do
  begin
    if exprs[i] = nil then
      Names[i] := 'expr' + IntToStr(i)
    else if exprs[i] is TSqlColumnRefNode then
      Names[i] := TSqlColumnRefNode(exprs[i]).ColumnName
    else
      Names[i] := 'expr' + IntToStr(i);
  end;
end;

function TVSqlExecutor.MakeReturningRow(Stmt: TSqlStmtNode; Row: TStrArray;
  const AllColNames: TStrArray; const AllColTypes: TByteArray;
  out Ret: TStrArray): Boolean;
{ RETURNING satiri kurar.
    - Liste duz kolonlardan olusuyorsa FALSE doner; cagiran kendi
      mevcut kolon-indeks yolunu kullanir (hizli yol).
    - Gercek ifade varsa TRUE doner ve Ret, EvaluateReturning ciktisiyla
      doldurulur.
  Boylece 13 farkli RETURNING noktasi tek bir kurala uyar. }
begin
  if not ReturningHasExpr(Stmt) then Exit(False);
  Ret := EvaluateReturning(Stmt, Row, AllColNames, AllColTypes);
  Result := True;
end;

// -----------------------------------------------------------

end.

