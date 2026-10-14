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
  VDbPlatform, VDbCost, VDbExtension;

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

  { TVSqlExecutor }

  TVSqlExecutor = class
  private
    FT: TVTableDb;
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
    // 4.3: HAVING icinde dogrudan aggregate. EvalBool sirasinda aktif
    // grup baglami: FAggIdx <> nil iken EvalExpr'de aggregate cagrilari
    // grup satirlari uzerinden hesaplanir (alias zorunlu degil). yalnizca
    // HAVING degerlendirmesi sirasinda acilir, sonra eski degerine doner
    // (ic ice HAVING'li alt sorgu icin kayit/restor).
    FAggIdx: TList<Integer>;
    FAggSrcRows: TStrMatrix;
    FAggCNames: TStrArray;
    FAggCTypes: TByteArray;
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
      const ColNames: TStrArray; const ColTypes: TByteArray);
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
      out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
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
      out OutTypes: TByteArray);
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
    function Execute(Stmt: TSqlStmtNode): TSqlResult;
    property TableDb: TVTableDb read FT;
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
        bRes := (SameText(LeftVal, 'True') or (LeftVal = '1')) and
                (SameText(RightVal, 'True') or (RightVal = '1'));
        if bRes then Exit('True') else Exit('False');
      end;
    sboOr:
      begin
        bRes := (SameText(LeftVal, 'True') or (LeftVal = '1')) or
                (SameText(RightVal, 'True') or (RightVal = '1'));
        if bRes then Exit('True') else Exit('False');
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
    if lv = '' then Exit('False');
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
      // F1-13: NOT IN ... NULL => UNKNOWN (satir gelmez)
      // Liste icinde NULL varsa sonuc UNKNOWN -> eslesmez.
      if hasNull then matched := False
      else matched := not matched;
    end;
    if matched then Exit('True') else Exit('False');
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
    if lv = '' then Exit('False');
    ct := VCT_STR;
    if bt.Expr is TSqlColumnRefNode then
    begin
      colRef := TSqlColumnRefNode(bt.Expr);
      for i := 0 to High(ColNames) do
        if SameText(colRef.ColumnName, ColNames[i]) and (i < Length(ColTypes)) then
        begin ct := ColTypes[i]; Break; end;
    end;
    matched := VDbCmpVal(lv, EvalExpr(bt.LowBound, Row, ColNames, ColTypes), '>=', ct) and
               VDbCmpVal(lv, EvalExpr(bt.HighBound, Row, ColNames, ColTypes), '<=', ct);
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
    if (FAggIdx <> nil) and IsAggFuncName(fn.FuncName) then
      Exit(EvalAggregateValue(fn, FAggSrcRows, FAggIdx, FAggCNames, FAggCTypes));
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
  out Pks: TStrArray; out Rows: TStrMatrix): Boolean;
var
  conj: TList<TSqlExprNode>;
  i, ci, lo, hi, l2, h2, n: Integer;
  e: TIdxEntries;
  ct: Byte;
  pkVal: string;
  bestCol: Integer;
  bestLo, bestHi: Integer;
  foundRange: Boolean;
  op: TSqlBinaryOp;
  cr: TSqlColumnRefNode;
  opName: string;
  oneRow: TStrArray;
  nParts: Integer;
  covPos: Integer;      // F-19: index-only tarama icin indeks konumu
  covAll: Boolean;
  st: TVDbTableStats;   // R-15 Full CBO: ANALYZE istatistigi

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
          SetLength(Pks, 0);
          SetLength(Rows, 0);
          for n := 0 to TSqlInNode(conj[i]).List.Count - 1 do
          begin
            if not (TSqlInNode(conj[i]).List[n] is TSqlLiteralNode) then Continue;
            pkVal := TSqlLiteralNode(TSqlInNode(conj[i]).List[n]).AsString;
            if FT.ReadRow(Td.Name, pkVal, oneRow) then
            begin
              SetLength(Pks, Length(Pks) + 1);
              SetLength(Rows, Length(Rows) + 1);
              Pks[High(Pks)] := pkVal;
              Rows[High(Rows)] := oneRow;
            end;
          end;
          Exit(True);   // filtre RowMatches ile asagida uygulanir
        end;

    // --- 2) indeks dilimi ---
    bestCol := -1; bestLo := 0; bestHi := 0; foundRange := False;
    for i := 0 to conj.Count - 1 do
    begin
      lo := 0; hi := 0;
      // 2a) basit karsilastirma
      if AsSimple(conj[i], ci, pkVal, op) then
      begin
        opName := '';
        case op of
          sboEq:  opName := '=';
          sboGt:  opName := '>';
          sboGte: opName := '>=';
          sboLt:  opName := '<';
          sboLte: opName := '<=';
        end;
        if opName <> '' then
        begin
          if not FT.TryGetMemIndex(Td.TableId, ci, e) then Continue;
          if not VDbIdxRangeL(e, Td.Cols[ci].Ctype, opName, pkVal, FT.IdxNParts(Td.TableId, ci), lo, hi) then
            Continue;
        end
        else Continue;
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
        if not FT.TryGetMemIndex(Td.TableId, ci, e) then Continue;
        ct := Td.Cols[ci].Ctype;
        nParts := FT.IdxNParts(Td.TableId, ci);
        if not VDbIdxRangeL(e, ct, '>=',
             TSqlLiteralNode(TSqlBetweenNode(conj[i]).LowBound).AsString, nParts, l2, h2) then
          Continue;
        lo := l2; hi := Length(e);
        if VDbIdxRangeL(e, ct, '<=',
             TSqlLiteralNode(TSqlBetweenNode(conj[i]).HighBound).AsString, nParts, l2, h2) then
          if h2 < hi then hi := h2;
      end
      // 2c) IN (a, b, c, ...)
      else if (conj[i] is TSqlInNode) and (not TSqlInNode(conj[i]).IsNot) and
              (TSqlInNode(conj[i]).Expr is TSqlColumnRefNode) then
      begin
        cr := TSqlColumnRefNode(TSqlInNode(conj[i]).Expr);
        ci := -1;
        for n := 0 to High(Td.Cols) do
          if VDbNorm(Td.Cols[n].Name) = VDbNorm(cr.ColumnName) then
          begin ci := n; Break; end;
        if (ci < 0) or (TSqlInNode(conj[i]).List.Count = 0) then Continue;
        if not FT.TryGetMemIndex(Td.TableId, ci, e) then Continue;
        ct := Td.Cols[ci].Ctype;
        nParts := FT.IdxNParts(Td.TableId, ci);
        lo := MaxInt; hi := 0;
        for n := 0 to TSqlInNode(conj[i]).List.Count - 1 do
        begin
          if not (TSqlInNode(conj[i]).List[n] is TSqlLiteralNode) then Continue;
          pkVal := TSqlLiteralNode(TSqlInNode(conj[i]).List[n]).AsString;
          // alt sinir: EN KUCUK degerin '>=' baslangici
          if VDbIdxRangeL(e, ct, '>=', pkVal, nParts, l2, h2) then
            if l2 < lo then lo := l2;
          // ust sinir: EN BUYUK degerin '<=' bitisi
          if VDbIdxRangeL(e, ct, '<=', pkVal, nParts, l2, h2) then
            if h2 > hi then hi := h2;
        end;
        if (lo = MaxInt) or (hi = 0) then Continue;
      end
      else Continue;

      // ONEMLI: birden fazla indeks kosulu ancak AYNI KOLONDA ise
      // kesisilir. Farkli kolonlarda kesisim anlamsizdir (iki farkli
      // indeks dizisinin konumlari birbirine denk gelmez) ve hatta
      // dizi sonuna tasmaya yol acardi. Farkli kolonlu kosul yok sayilir;
      // sonuctaki satirlar yine RowMatches ile dogrulanir.
      if foundRange and (ci <> bestCol) then Continue;

      if not foundRange then
      begin
        foundRange := True; bestCol := ci; bestLo := lo; bestHi := hi;
      end
      else
      begin
        if lo > bestLo then bestLo := lo;
        if hi < bestHi then bestHi := hi;
      end;
    end;

    if not foundRange then Exit;   // -> tam tarama
    if bestHi <= bestLo then       // kesim bos
    begin
      Exit(True);                  // 0 satir, tam tarama gerekmez
    end;

    // ---- R-15 Full CBO: indeks dilimi secici degilse tam tarama ----
    // Dilim genisligi (bestHi-bestLo) indeksten TAM olculur; bu, kolon
    // istatistigindeki distinct tahmininden daha kesindir. Indeks, ancak
    // toplam maliyeti sirali taramadan kucukse kullanilir. Karar
    // VDbCost.VdbIndexIsSelective (TEK karar noktasi) tarafindan verilir.
    if GetTableStats(Td.Name, st) then
    begin
      covPos := FT.IdxPosOfCol(Td.TableId, bestCol);
      covAll := (covPos >= 0) and FT.IdxCoversAll(Td, covPos);
      if not VdbIndexIsSelective(st.RowCount, bestHi - bestLo, covAll) then
        Exit;  // False -> cagri FT.ScanRows ile tam tarama yapar
    end;

    // e dizisini KULLANILACAK kolona bagla (yukaridaki kosullar e'yi
    // degistirmis olabilir)
    if not FT.TryGetMemIndex(Td.TableId, bestCol, e) then Exit;

    SetLength(Pks, bestHi - bestLo);
    SetLength(Rows, bestHi - bestLo);
    n := 0;
    // F-19: indeks tablonun TUM kolonlarini kapsiyorsa satirlar tabloya
    // OKUNMAKDAN (index-only scan) uretilebilir; kapsamiyorsa normal yol.
    covPos := FT.IdxPosOfCol(Td.TableId, bestCol);
    covAll := (covPos >= 0) and FT.IdxCoversAll(Td, covPos);
    for i := bestLo to bestHi - 1 do
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
    Result := True;
  finally
    conj.Free;
  end;
end;

function TVSqlExecutor.TryIndexOrder(const Td: TTableDef; Stmt: TSqlSelectStmt;
  const ColNames: TStrArray; const ColTypes: TByteArray;
  out Rows: TStrMatrix): Boolean;
// ORDER BY <indeksli kolon(lar)> -> satirlari indeks sirasiyla oku.
// COK KOLONLU: ORDER BY a, b ile indeksin (a, b) on ek'i eslesiyorsa
// hicbir siralama yapilmaz; satirlar indeks sirasiyla okunur.
var
  e: TIdxEntries;
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
  if not FT.TryGetMemIndex(Td.TableId, ci, e) then Exit;
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
  lo := 0; hi := Length(e);
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
      if not VDbIdxRangeL(e, Td.Cols[ci].Ctype, opName, pkVal,
      FT.IdxNParts(Td.TableId, ci), l2, h2) then Continue;
      if l2 > lo then lo := l2;
      if h2 < hi then hi := h2;
    end;
  finally
    conj.Free;
  end;

  off := Stmt.OffsetVal;
  lim := Stmt.LimitVal;
  need := lim;
  if need < 0 then need := -1;
  SetLength(Rows, 0);
  n := 0;
  if desc then
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
          SetLength(Rows, Length(Rows) + 1);
          Rows[High(Rows)] := rv;
          if (need >= 0) and (Length(Rows) >= need) then Break;
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
          SetLength(Rows, Length(Rows) + 1);
          Rows[High(Rows)] := rv;
          if (need >= 0) and (Length(Rows) >= need) then Break;
        end;
      end;
      Inc(i);
    end;
  end;
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
  const Rows: TStrMatrix; const Cols: TVdbSortCols; UseInt, IntDesc: Boolean);
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
  const ColNames: TStrArray; const ColTypes: TByteArray);
var
  i, j, k, kidx, m, c, validCount: Integer;
  sortCols: TVdbSortCols;
  idx: TIntArray;
  newRows: TStrMatrix;
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

begin
  if (OrderBy = nil) or (OrderBy.Count = 0) or (Length(Rows) < 2) then Exit;

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

  // 2. Indeks dizisi olustur
  SetLength(idx, Length(Rows));
  for i := 0 to High(Rows) do idx[i] := i;

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
      intPath and sortCols[0].Desc)
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
          while (i < H) and (VdbSortCompareRows(sortCols, Rows, idx[i], pIdx) < 0) do Inc(i);
          while (j > L) and (VdbSortCompareRows(sortCols, Rows, idx[j], pIdx) > 0) do Dec(j);
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
    JoinEntries: TIdxEntries;
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
    begin
      if mrN >= 2000000 then
        raise EVDbException.Create(ecLimit, 'JOIN sonucu cok buyuk (2M sinir)');
      if mrN >= mrCap then
      begin
        if mrCap = 0 then mrCap := 64
        else mrCap := mrCap * 2;
        SetLength(mr, mrCap);
      end;
      mr[mrN] := Row;
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
    end;
    if JoinIdxCol2 >= 0 then
    begin
      if rIsCte then
        JoinIdxCol2 := -1   // CTE'de indeks/PK yok -> klasik yol
      else if (JC.JoinType = jtRight) or (JC.JoinType = jtFull) then
        JoinIdxCol2 := -1   // P5-RF: sag surucu klasik dongu kullanir
      else if rDef.PkIndex = JoinIdxCol2 - n1 then
        JoinUsePk := True
      else if not FT.TryGetMemIndex(rDef.TableId, JoinIdxCol2 - n1, JoinEntries) then
        JoinIdxCol2 := -1;   // indeks yok -> klasik yol
    end;

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
        else if VDbIdxRangeL(JoinEntries, rDef.Cols[JoinIdxCol2 - n1].Ctype, '=', jv,
                 FT.IdxNParts(rDef.TableId, JoinIdxCol2 - n1),
                 lo2, hi2) then
          for k := lo2 to hi2 - 1 do
            if FT.ReadRow(JC.Table, JoinEntries[k].Pk, rv2) then
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
      if (JC.JoinType = jtRight) or (JC.JoinType = jtFull) then
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
        for j := 0 to High(rRows) do
        begin
          matchFound := False;
          for i := 0 to High(LR) do
          begin
            SetLength(merged, n1 + n2);
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
            SetLength(merged, n1 + n2);
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
      for i := 0 to High(LR) do
      begin
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
  out Res: TSqlResult; out OutTypes: TByteArray);
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
      if not RowMatches(Stmt.WhereClause, AllRows[i], ColNames, ColTypes) then Continue;
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

    // 3. Her grup icin hesapla
    SetLength(outRows, 0);
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
        SetLength(outRows, Length(outRows) + 1);
        outRows[High(outRows)] := tmpRow;
      end;
    end;

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
  isDup, found, SkipOffsetLimit, HasSetOp, deferOrder: Boolean;
  baseIdx, tmpSlot, origCols: Integer;
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
    SetLength(filteredRows, 0);
    for i := 0 to High(allRows) do
      if RowMatches(Stmt.WhereClause, allRows[i], colNames, colTypes) then
      begin
        SetLength(filteredRows, Length(filteredRows) + 1);
        filteredRows[High(filteredRows)] := allRows[i];
      end;
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
        SkipOffsetLimit := TryIndexOrder(td, Stmt, colNames, colTypes, filteredRows);
      if not SkipOffsetLimit then
      begin
        { YOL 2: Satir adaylarini DARALT - PK nokta aramasi veya indeks dilimi.
          (Once her zaman FT.ScanRows cagriliyordu: 100.000 satirlik tabloda
           "WHERE id = 5" bile ~900 ms suruyordu.)
          Aggregate/GROUP BY de dogrudan sunu kullanir: ExecGroupBy satirlari
          KENDISI RowMatches ile filtreler, yani onceden daraltmak sonucu
          degistirmez. }
        if not NarrowRows(td, Stmt.WhereClause, colNames, colTypes, pks, allRows) then
          // R-13 Full: tam taramaya dustuk -> bolme hedef kumesiyle
          // tara (partition pruning). Sonuc ayni, okunan satir azalir.
          FT.ScanRowsPart(Stmt.FromTable, pks, allRows, PartTargetsOf(td, Stmt.WhereClause));
      end;
      // R-19: satirlar okundu; simdi RLS ile GORUNMEZ olanlari ele.
      // BURADA yapilir (WHERE filtresinden ONCE) ki aggregate/GROUP BY,
      // ORDER BY, LIMIT/LIST ve set-op birlestirmesi de dogru satir
      // kumesi uzerinde calissin. WHERE filtresi asagida ayrica uygulanir.
      if FT.RlsApplies(Stmt.FromTable) then
      begin
        SetLength(rlRows, 0);
        for i := 0 to High(allRows) do
          if RlsRowVisible(Stmt.FromTable, 1, allRows[i], colNames, colTypes) then
          begin
            SetLength(rlRows, Length(rlRows) + 1);
            rlRows[High(rlRows)] := allRows[i];
          end;
        allRows := rlRows;
        SetLength(pks, 0);
        SkipOffsetLimit := False;
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
      ExecGroupBy(Stmt, pks, allRows, colNames, colTypes, Res, outTypes);
      // 4.2: kuyruk ortak FinishGroup'a tasinildi (JOIN yolu da aynisini
      // cagirir; F1-20 ORDER BY tip haritasi + OFFSET/LIMIT + Affected).
      FinishGroup;
      Exit;
    end;

    // Indeks yolu (SkipOffsetLimit) filteredRows'u doldurduysa eleme;
    // CTE/normal yolda allRows buradan suzulur.
    if not SkipOffsetLimit then
    begin
      SetLength(filteredRows, 0);
      for i := 0 to High(allRows) do
        if RowMatches(Stmt.WhereClause, allRows[i], colNames, colTypes) then
        begin
          SetLength(filteredRows, Length(filteredRows) + 1);
          filteredRows[High(filteredRows)] := allRows[i];
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
      DoSort(filteredRows, orderKeys, Stmt.OrderBy, colNames, colTypes);
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
  SetLength(outTypes, Length(outCols));
  for j := 0 to High(outCols) do outTypes[j] := VCT_STR;
  for j := 0 to Stmt.Columns.Count - 1 do
  begin
    if not (Stmt.Columns[j].Expr is TSqlColumnRefNode) then Continue;
    for i := 0 to High(colNames) do
      if SameText(colNames[i], TSqlColumnRefNode(Stmt.Columns[j].Expr).ColumnName) then
      begin
        if i < Length(colTypes) then outTypes[j] := colTypes[i];
        Break;
      end;
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

  Res.Fields := outCols;
  Res.Rows := outRows;
  Res.Affected := Length(outRows);
  Res.Msg := 'OK';
  finally
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
    txCommit:          FT.CommitBatch;
    txRollback:        FT.AbortBatch;
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
  if Length(Td.Idx) = 0 then Exit;   // Td record; nil degil bos dizi olabilir
  conj := TList<TSqlExprNode>.Create;
  try
    Push(Where);
      for k := 0 to conj.Count - 1 do
        if conj[k] is TSqlBinaryOpNode then
        begin
          b := TSqlBinaryOpNode(conj[k]);
          opName := BinaryOpName(b.Op);
          if not ((opName = '=') or (opName = '<') or (opName = '>') or
                  (opName = '<=') or (opName = '>=')) then Continue;
          if not (b.Left is TSqlColumnRefNode) then Continue;
          if LeadsIdx(TSqlColumnRefNode(b.Left), ix) then
        begin
          IdxName := Td.Idx[ix].Name;
          Result := True;
          Break;
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
  eqDistinct, eqNulls, rangeRows: Int64;
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
  function EqColStats(T: TTableDef; out Distinct, Nulls: Int64): Boolean;
  var
    conj: TList<TSqlExprNode>;
    k, ci, cj: Integer;
    b: TSqlBinaryOpNode;
    colName: string;

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
          for cj := 0 to High(tblStats.ColStats) do
            if SameText(tblStats.ColStats[cj].ColName, T.Cols[ci].Name) then
            begin
              Distinct := tblStats.ColStats[cj].DistinctCount;
              Nulls := tblStats.ColStats[cj].NullCount;
              if Distinct > 0 then Exit(True);
            end;
        end;
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
          if EqColStats(td, eqDistinct, eqNulls) then
            est := VdbChooseScan(tblStats.RowCount, eqDistinct, eqNulls, True, covAll)
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
  colNames, colDistinct, colNulls, colMins, colMaxs: array of string;
  distinctCounts, nullCounts: array of Int64;
  minVals, maxVals: array of string;
  dicts: array of TDictionary<string, Integer>;   // R-15: gercek distinct
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
            if not dicts[j].ContainsKey(rows[i][j]) then
              dicts[j].Add(rows[i][j], 0);
            if (minVals[j] = '') or (rows[i][j] < minVals[j]) then
              minVals[j] := rows[i][j];
            if (maxVals[j] = '') or (rows[i][j] > maxVals[j]) then
              maxVals[j] := rows[i][j];
          end;
        end;
      end;
    end;
    for j := 0 to High(td.Cols) do
      distinctCounts[j] := dicts[j].Count;
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
    colNames, colDistinct, colNulls, colMins, colMaxs);

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
          Res.Rows[i][1] := VDbTypeName(td.Cols[i].Ctype);
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
          cn := cn + td.Cols[i].Name + ' ' + VDbTypeName(td.Cols[i].Ctype);
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
  SetLength(Res.Rows, 6);
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
begin

  Result.Affected := 0;
  SetLength(Result.Fields, 0);
  SetLength(Result.Rows, 0);
  if Stmt = nil then Exit;

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

