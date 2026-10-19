unit VDbAst;

{ VDb SQL AST (Soyut Sozdizim Agaci) Modeli
  SQL cumleleri ve ifadeleri icin tip-guvenli, agac yapisinda dugum siniflari.
  Her dugum kendi alt agacini Destroy icinde guvenle serbest birakir (RAII). }

{$mode delphi}

interface

uses
  Classes, SysUtils, Generics.Collections, VDbTypes, VDbTable, VDbErr;

type
  { Temel AST Dugumu }
  TSqlNode = class
  public
    constructor Create; virtual;
    destructor Destroy; override;
  end;

  // Ilgili ifade dugumu, asagida tanimlanir (ileri atililip burada kullanilir).
  TSqlExprNode = class;
  { Temel Ifade Dugumu }
  TSqlExprNode = class(TSqlNode)
  end;

  { CAST ( expr AS type ) }
  TSqlCastNode = class(TSqlExprNode)
  public
    Expr: TSqlExprNode;          // cevrilecek ifade
    TargetType: string;          // target tip (TEXT, INTEGER, ...) - buyuk harf
    constructor Create(AExpr: TSqlExprNode; const AType: string);
    destructor Destroy; override;
  end;

  { Sabit Degerler (Literal: Sayi, Metin, Boolean, NULL) }
  TSqlLiteralType = (sltNull, sltInt, sltFloat, sltString, sltBool);

  TSqlLiteralNode = class(TSqlExprNode)
  public
    LitType: TSqlLiteralType;
    IntVal: Int64;
    FloatVal: Double;
    StrVal: string;
    BoolVal: Boolean;
    constructor CreateNull;
    constructor CreateInt(const V: Int64);
    constructor CreateFloat(const V: Double);
    constructor CreateStr(const V: string);
    constructor CreateBool(const V: Boolean);
    function AsString: string;
  end;

  { Kolon Basvurusu (orn. "id" veya "t.ad") }
  TSqlColumnRefNode = class(TSqlExprNode)
  public
    TableQualifier: string;
    ColumnName: string;
    constructor Create(const ACol: string; const ATable: string = '');
    function QualifiedName: string;
  end;

  { Ikili Islemler (+, -, *, /, =, <>, <, <=, >, >=, LIKE, AND, OR) }
  TSqlBinaryOp = (
    sboAdd, sboSub, sboMul, sboDiv, sboMod,
    sboEq, sboNeq, sboLt, sboLte, sboGt, sboGte,
    // DIKKAT: sboLike ve sboILike ARALIK KIYASLAMASI (AOp >= sboEq and
    // AOp <= sboLike) kullanir. Yeni ekleme yapilirsa sboLike SONDA
    // kalmalidir, aksi halde NULL (uc-degerli) mantigi bozulur.
    sboLike, sboAnd, sboOr, sboILike,
    sboConcat,      // || string birlestirme
    // F-22: JSONB operatorleri. EN SONA eklenir; aralik kiyaslamasi
    // sboEq..sboLike arasinda yapildigi icin konumlari onemsiz.
    sboJsonContains,   // @>  : sol, sag'i iceriyor mu
    sboJsonContained,  // <@  : sol, sag'in icinde mi
    sboJsonHasKey,     // ?   : anahtar var mi
    sboJsonAnyKey,     // ?|  : anahtarlardan en az biri
    sboJsonAllKey,     // ?&  : anahtarlarin hepsi
    // F-25: RANGE operatorleri. Yine EN SONA eklenir.
    sboRangeOverlap,   // &&  : kesisiyor mu
    sboRangeBefore,    // <<  : tamamen once mi
    sboRangeAfter,     // >>  : tamamen sonra mi
    sboRangeAdjacent,  // -|- : bitisik mi (kesisim olmadan)
    sboRangeContains,  // @>  : iceriyor mu
    sboRangeContained, // <@  : icinde mi
    sboRangeOvLeft,    // &<  : kesisir ve sol taraftan
    sboRangeOvRight    // &>  : kesisir ve sag taraftan
  );

  TSqlBinaryOpNode = class(TSqlExprNode)
  public
    Op: TSqlBinaryOp;
    Left: TSqlExprNode;
    Right: TSqlExprNode;
    constructor Create(AOp: TSqlBinaryOp; ALeft, ARight: TSqlExprNode);
    destructor Destroy; override;
  end;

  { Tekli Islemler (NOT, Eksi, IS NULL, IS NOT NULL) }
  TSqlUnaryOp = (suoNot, suoNeg, suoIsNull, suoIsNotNull);

  TSqlUnaryOpNode = class(TSqlExprNode)
  public
    Op: TSqlUnaryOp;
    Operand: TSqlExprNode;
    constructor Create(AOp: TSqlUnaryOp; AOperand: TSqlExprNode);
    destructor Destroy; override;
  end;

  { IN / NOT IN Listesi }
  // Ileri bildirim: cumle dugumleri asagida tanimlidir.
  TSqlSelectStmt = class;

  { F-14 / F-15: cok argumanli aggregate'ler.
    STRING_AGG(deger, ayirac [, DISTINCT])
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kolon)
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY kolon) }
  TAggKind = (akStringAgg, akPercentileCont, akPercentileDisc);

  TSqlAggNode = class(TSqlExprNode)
  public
    Kind: TAggKind;
    Arg: TSqlExprNode;           // STRING_AGG degeri / PERCENTILE order kolonu
    Sep: TSqlExprNode;           // STRING_AGG ayiraci (nil = ',')
    Pct: Double;                 // PERCENTILE yuzdesi (0..1)
    IsDistinct: Boolean;
    constructor Create(AKind: TAggKind);
    destructor Destroy; override;
  end;

  { F-06: ANY / SOME / ALL karsilastirma grubu.    ANY  = en az bir satir saglanirsa TRUE  (IN ile ayni)
    ALL  = tum satirlar saglanirsa TRUE
    SOME = ANY ile ayni (SQL standardi es adi) }
  TQuantKind = (qkAny, qkAll);

  TSqlQuantNode = class(TSqlExprNode)
  public
    Kind: TQuantKind;
    Left: TSqlExprNode;          // sol ifade (x > ANY (...) gibi)
    CmpOp: TSqlBinaryOp;         // x'in ALT sorgu degeriyle karsilastirma op
    SubSelect: TSqlSelectStmt;   // alt sorgu (tek kolon)
    constructor Create(AKind: TQuantKind; AL: TSqlExprNode;
      ACmpOp: TSqlBinaryOp; ASel: TSqlSelectStmt);
    destructor Destroy; override;
  end;

  TSqlInNode = class(TSqlExprNode)
  public
    Expr: TSqlExprNode;
    List: TList<TSqlExprNode>;
    IsNot: Boolean;
    // P5-2: IN (SELECT ...) icin alt sorgu (nil ise duz liste).
    // Doluysa List bos kalir; ic sorgu tek kolon dondurmelidir.
    SubSelect: TSqlSelectStmt;
    constructor Create(AExpr: TSqlExprNode; AIsNot: Boolean = False);
    destructor Destroy; override;
  end;

  { Alt Sorgu (P5-2): skaler deger veya EXISTS denetimi.
    Iliskisiz (uncorrelated) sorgular desteklenir; ic sorgu dis
    tablolara basvuramaz. }
  TSubqueryKind = (sqScalar, sqExists);

  TSqlSubqueryNode = class(TSqlExprNode)
  public
    Select: TSqlSelectStmt;
    Kind: TSubqueryKind;
    IsNot: Boolean;   // NOT EXISTS icin
    constructor CreateScalar(ASelect: TSqlSelectStmt);
    constructor CreateExists(ASelect: TSqlSelectStmt; AIsNot: Boolean = False);
    destructor Destroy; override;
  end;

  { BETWEEN / NOT BETWEEN Araligi }
  TSqlBetweenNode = class(TSqlExprNode)
  public
    Expr: TSqlExprNode;
    LowBound: TSqlExprNode;
    HighBound: TSqlExprNode;
    IsNot: Boolean;
    constructor Create(AExpr, ALow, AHigh: TSqlExprNode; AIsNot: Boolean = False);
    destructor Destroy; override;
  end;
  { R-20: `<karsilastirma> COLLATE <ad>`.
    Karsilastirma operatorunden SONRA gelen acik collation'i tasir.
    Name bos ise kolonun varsayilan collation'i (TColDef.Collate)
    kullanilir. }
  TSqlCollateNode = class(TSqlExprNode)
  public
    Inner: TSqlExprNode;
    Name: string;          // upper-case
    constructor Create(AInner: TSqlExprNode; const AName: string);
    destructor Destroy; override;
  end;

  { Fonksiyon / Toplama Cagirisi (COUNT, SUM, AVG, MIN, MAX) }
  TSqlFuncCallNode = class(TSqlExprNode)
  public
    FuncName: string;     // COUNT, SUM, AVG, MIN, MAX
    Arg: TSqlExprNode;     // nil ise COUNT(*)
    IsStar: Boolean;       // COUNT(*) icin True
    IsDistinct: Boolean;   // COUNT(DISTINCT ...)
    // F-16: FILTER (WHERE ...) — aggregate'e satir filtresi.
    // COUNT(*) FILTER (WHERE x > 5) -> yalniz x > 5 olanlar sayilir.
    Filter: TSqlExprNode;  // nil = filtre yok
    // F-23: XML fonksiyonlari ve genel olarak DEGISKEN ARGUMAN.
    // Doluysa Arg/IsStar kullanilmaz; Args uzerinden calisir.
    Args: TList<TSqlExprNode>;
    constructor Create(const AFunc: string; AArg: TSqlExprNode; AIsStar: Boolean = False; AIsDistinct: Boolean = False);
    constructor CreateList(const AFunc: string; AArgs: TList<TSqlExprNode>; AIsStar: Boolean = False; AIsDistinct: Boolean = False);
    destructor Destroy; override;
  end;

  { CASE Ifadesi (P5-3): aranan (WHEN kosul) ve sade (CASE x WHEN deger)
    bicimler. ELSE yoksa sonuc NULL'dur. }
  TSqlCaseWhen = record
    Cond: TSqlExprNode;    // aranan: boolean kosul; sade: kiyas degeri
    Value: TSqlExprNode;
  end;

  TSqlCaseNode = class(TSqlExprNode)
  public
    Operand: TSqlExprNode; // nil = aranan CASE
    Whens: TList<TSqlCaseWhen>;
    ElseExpr: TSqlExprNode; // nil = ELSE yok
    constructor Create(AOperand: TSqlExprNode);
    destructor Destroy; override;
  end;

  { NULLIF(a,b) — a=b ise NULL, degilse a dondurur }
  TSqlNullIfNode = class(TSqlExprNode)
  public
    Arg1, Arg2: TSqlExprNode;
    constructor Create(A1, A2: TSqlExprNode);
    destructor Destroy; override;
  end;

  { COALESCE(a,b,c,...) — ilk non-NULL degeri dondurur }
  TSqlCoalesceNode = class(TSqlExprNode)
  public
    Args: TList<TSqlExprNode>;
    constructor Create(AArgs: TList<TSqlExprNode>);
    destructor Destroy; override;
  end;

  { Stored Procedure/Function Parameter (F-35)
    DIKKAT: kayit VDbTypes'te tanimlidir (DefaultExpr: TObject). Boylece
    VDbTable da ayni kaydi kullanabilir; burada ikinci bir kopya
    tanimlamak "Got VDBTYPES.TFunctionParameter expected
    VDBAST.TFunctionParameter" turunden tip cakismasi uretiyordu. }
  TFunctionParameter = VDbTypes.TFunctionParameter;

  { F-22: JSONB ANAHTAR LISTESI — `col ?| ('a','b')` / `col ?& ('a','b')`.
    Left  = JSON metni (kolon veya ifade)
    Keys  = aranan anahtarlar
    RequireAll = True ise ?& (hepsi), False ise ?| (en az biri) }
  TSqlJsonKeyNode = class(TSqlExprNode)
  public
    Left: TSqlExprNode;
    Keys: TList<TSqlExprNode>;
    RequireAll: Boolean;
    constructor Create(ALeft: TSqlExprNode; AKeys: TList<TSqlExprNode>;
      AAll: Boolean);
    destructor Destroy; override;
  end;

  { ---------------- CUMLE DUGUMLERI (STATEMENTS) ---------------- }

  { TSqlStmtNode }

  TSqlStmtNode = class(TSqlNode)
  public
     constructor Create; override;
  end;

  { SELECT Cikti Kolonu Tanimi }
  TSelectColumnItem = record
    Expr: TSqlExprNode;
    Alias: string;
  end;

  { ORDER BY Elemani }
  TOrderItem = record
    Expr: TSqlExprNode;
    Desc: Boolean;
    Collate: string;  // '' = bayt sirasi; 'TR' = Turk alfabesi
    // F-10 (SQL:2003): NULLS FIRST / NULLS LAST.
    // Nil = motor varsayilani (NULL en kucuk -> FIRST yonunde Once,
    // DESC yonunde SONra gelir). 0 = FIRST, 1 = LAST.
    NullsPos: Integer;
  end;

  { Pencere Fonksiyonu (P5-WIN): ROW_NUMBER/RANK/DENSE_RANK/COUNT/SUM/AVG/
    MIN/MAX/LAG/LEAD ... OVER ([PARTITION BY ...] [ORDER BY ...]).
    Yalniz SELECT listesinde ust-duzey oge olarak kullanilabilir;
    cerceve (ROWS/RANGE) desteklenmez. }
  TSqlWindowNode = class(TSqlExprNode)
  public
    FuncName: string;
    Arg: TSqlExprNode;          // nil: ROW_NUMBER/RANK/DENSE_RANK/COUNT(*)
    IsStar: Boolean;            // COUNT(*) icin
    Offset: Integer;            // LAG/LEAD kaydirma (varsayilan 1)
    Default: TSqlExprNode;      // LAG/LEAD varsayilan deger (nil = NULL)
    Partitions: TList<TSqlExprNode>;
    OrderBys: TList<TOrderItem>;
    FrameType: string;
    FrameStart: string;
    FrameEnd: string;
    constructor Create(const AFunc: string);
    destructor Destroy; override;
  end;

  { JOIN Tanimi }
  TJoinType = (jtInner, jtLeft, jtRight, jtFull);

  TJoinClause = record
    JoinType: TJoinType;
    Table: string;
    Alias: string;
    OnCondition: TSqlExprNode;
    // F-27: NATURAL JOIN — ortak kolon adlarinda kendiliginden esitlik.
    // OnCondition UYGULANMAZ; executor ortak kolonlari kendisi hesaplar.
    Natural: Boolean;
    // F-29: LATERAL — sag taraf alt sorgu/tabloda OLUR ve dis satirin
    // kolonlarina referans verebilir.
    // DIKKAT: LateralSelect BURAYA YAZILMAZ. TJoinClause bir RECORD'dur
    // ve JOIN dongusunda deger (struct) olarak kopyalaniyor; record
    // icindeki sinif pointer'i FPC'de yonlendirmelerde sayac
    // yonetimi sorunu yaratip Access violation veriyor. Bunun yerine
    // LateralSelect'i TSqlSelectStmt.LateralSubs listesinde tutup
    // burada YALNIZCA indeks (LateralIdx) saklariz.
    //  -1  : LATERAL degil
    //  >=0 : TSqlSelectStmt.LateralSubs[Idx] kullanilacak
    LateralIdx: Integer;
  end;

  { F-28: USING kolonlari TJoinClause icinde TUTULMAZ.
    Sebep: TStrArray (dinamik dizi) iceren bir RECORD'u 'var' parametre
    ile geçirmek FPC'de kopya/alias sorunlari yaratir; JOIN dongusu
    TJoinClause'i iki kez yazdiği için alanlar karisip tum JOIN
    zincirleri bozulur. Bunun yerine ayri bir dizi ve eşleme tablosu
    tutulur. }
  TJoinUsingRec = record
    UsingCols: TStrArray;
  end;

  { Kume Islemleri (UNION, UNION ALL, EXCEPT, INTERSECT) }
  TSetOpKind = (sokNone, sokUnion, sokUnionAll, sokExcept, sokIntersect);

  { WITH-CTE Tanim (P5-CTE): ad + ic sorgu. Kolon alias'lari (x(a,b))
    ve RECURSIVE desteklenmez. }
  TWithQuery = record
    Name: string;
    Select: TSqlSelectStmt;
    IsRecursive: Boolean;
    ColAliases: TStrArray;
	Materialize: Boolean;
    // R-10: CYCLE <kolon> SET <is_cycle_sutunu> USING <path_sutunu>
    // Bos ise CYCLE maddesi yoktur. Executor bu sutunlari ozyinelemeli
    // CTE'nin sonucuna EK sütun olarak ekler.
    CycleCol: string;
    IsCycleCol: string;
    PathCol: string;
  end;

  { AS OF (2026-10-06): WAL gecmisinden "o anki" okuma.
    yalnizca sol SELECT'te gecerli; TIMESTAM/VERSION cozumleme executor'da
    ecUnsupported ile reddedilir (WAL'de zaman damgasi/surum yoktur). }
  TSqlAsOfKind = (saoNone, saoSequence, saoVersion, saoTimestamp);

  { SELECT Cumlesi }
  TSqlSelectStmt = class(TSqlStmtNode)
  public
    IsDistinct: Boolean;
    Columns: TList<TSelectColumnItem>;
    FromTable: string;
    FromAlias: string;
    HasJoin: Boolean;
    Join: TJoinClause;
    // P5-1: zincir JOIN'ler (3+ tablo). Ilk JOIN Join alaninda,
    // sonrakiler burada (soldan derine left-deep sirada uygulanir).
    MoreJoins: TList<TJoinClause>;
    // F-28: USING kolonlari, MoreJoins ile AYNI SIRAYLA. Ilk JOIN icin
    // JoinUsing[0], MoreJoins[i] icin JoinUsing[i+1] kullanilir. Bos ise
    // USING yoktur (nil = hicbir JOIN'de USING yok).
    JoinUsing: TList<TJoinUsingRec>;
    // F-29: LATERAL alt sorgulari. TJoinClause.LateralIdx bunlarin
    // indisidir. Liste join sirasina gore olmak ZORUNDA DEGILDIR.
    LateralSubs: TList<TSqlSelectStmt>;
    // P5-CTE: WITH x AS (...), y AS (...) listesi (sira onemli:
    // sonrakiler oncekileri gorebilir). Bos olabilir, nil olmaz.
    WithQueries: TList<TWithQuery>;
    WhereClause: TSqlExprNode;
    GroupByCols: TList<string>;
    HavingClause: TSqlExprNode;
    // F-09 (SQL:2003 / modern): QUALIFY — pencere fonksiyonu hesaplandiktan
    // SONRA uygulanan filtre. HAVING gibi ama gruplamadan sonra, pencere
    // sonuclarini da gorebilir.
    QualifyClause: TSqlExprNode;
    OrderBy: TList<TOrderItem>;
    LimitVal: Integer;   // sinir yoksa -1
    OffsetVal: Integer;  // yoksa 0
    SetOp: TSetOpKind;
    RightSelect: TSqlSelectStmt;
    // AS OF: FROM tablosunun WAL gecmisindeki goruntusu (saoNone = yok).
    AsOf: TSqlAsOfKind;
    AsOfValue: QWord;   // SEQUENCE n
    AsOfText: string;   // TIMESTAMP/VERSION ham metni (executor rededer)
    // F-41: SELECT ... FOR UPDATE
    ForUpdate: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  { INSERT Cumlesi }
  TInsertValuesRow = TList<TSqlExprNode>;

  TSqlInsertStmt = class(TSqlStmtNode)
  public
    Table: string;
    Columns: TStrArray;
    ValuesRows: TList<TInsertValuesRow>;
    SelectSrc: TSqlSelectStmt;  // INSERT INTO ... SELECT icin
    WithQueries: TList<TWithQuery>; // 4.5 mimari: WITH + INSERT
    // R-03: UPSERT / ON CONFLICT
    OnConflictAction: TOnConflictAction;
    OnConflictTarget: TStrArray;
    OnConflictSetExprs: TList<TUpdateAssignment>;
    // R-04: RETURNING
    ReturningCols: TStrArray;
    ReturningExprs: TList<TSqlExprNode>;
    constructor Create;
    destructor Destroy; override;
  end;

  { UPDATE Cumlesi }
  TUpdateAssignment = VDbTypes.TUpdateAssignment;

  TSqlUpdateStmt = class(TSqlStmtNode)
  public
    Table: string;
    Assignments: TList<TUpdateAssignment>;
    WhereClause: TSqlExprNode;
    WithQueries: TList<TWithQuery>; // 4.5 mimari: WITH + UPDATE
    // R-04: RETURNING
    ReturningCols: TStrArray;
    ReturningExprs: TList<TSqlExprNode>;
    constructor Create;
    destructor Destroy; override;
  end;

  { DELETE Cumlesi }
  TSqlDeleteStmt = class(TSqlStmtNode)
  public
    Table: string;
    WhereClause: TSqlExprNode;
    WithQueries: TList<TWithQuery>; // 4.5 mimari: WITH + DELETE
    // R-04: RETURNING
    ReturningCols: TStrArray;
    ReturningExprs: TList<TSqlExprNode>;
    constructor Create;
    destructor Destroy; override;
  end;

  { CREATE TABLE Cumlesi }
  TSqlCreateTableStmt = class(TSqlStmtNode)
  public
    Table: string;
    IfNotExists: Boolean;
    Cols: TColArray;
    PkIndex: Integer;
    Checks: TWhereGroups;
    Fks: array of TFkDef;
    CheckExprs: TList<TSqlExprNode>;
    // R-13: Table Partitioning
    PartitionType: string; // 'RANGE', 'LIST', 'HASH'
    PartitionCol: string;  // kolon adı
    PartitionValues: TStringList; // RANGE: min/max, LIST: değer listesi
    constructor Create;
    destructor Destroy; override;
  end;

  { ALTER TABLE Eylemleri }
  TAlterTableAction = (
    ataAddColumn, ataDropColumn, ataRenameColumn,
    ataAlterColType, ataSetDefault, ataDropDefault,
    ataSetNotNull, ataDropNotNull, ataRenameTable, ataAddConstraint,
    // R-19: ROW LEVEL SECURITY acmak/kapatmak
    ataEnableRls, ataDisableRls
  );

  { R-19: politika hangi cumleyi etkiler.
    polAll = FOR verilmediginde (tumu SELECT/UPDATE/DELETE). }
  TPolicyCmd = (polAll, polSelect, polInsert, polUpdate, polDelete);

  { R-19: CREATE/DROP POLICY.
    USING  -> SELECT/UPDATE/DELETE icin gorunurluk kosulu (satir okunabilir mi)
    WITHCHECK -> INSERT/UPDATE icin yeni satir kosulu.
    Metin olarak saklanir (sema kaliciligi); ifade AST'si kayit aninda
    uretilip bellekte tutulur. }
  TPolicyStmt = class(TSqlStmtNode)
  public
    Make: Boolean;        // True = CREATE, False = DROP
    TableName: string;
    PolicyName: string;
    Cmd: TPolicyCmd;
    UsingText: string;
    CheckText: string;
    UsingExpr: TSqlExprNode;
    CheckExpr: TSqlExprNode;
    constructor Create; override;
    destructor Destroy; override;
  end;

  TSqlAlterTableStmt = class(TSqlStmtNode)
  public
    Table: string;
    Action: TAlterTableAction;
    ColName: string;
    NewName: string;
    ColDef: TColDef;
    PositionCol: string;  // AFTER col
    IsFirst: Boolean;     // FIRST
    DefaultVal: string;
    NewTypeName: string;
    // R-22: Online DDL — CONCURRENTLY (kilitsiz sema degisikligi)
    Concurrently: Boolean;
    constructor Create;
  end;

  { DROP TABLE Cumlesi }
  TSqlDropTableStmt = class(TSqlStmtNode)
  public
    Table: string;
    IfExists: Boolean;
    constructor Create;
  end;

  { CREATE INDEX Cumlesi }
  TSqlCreateIndexStmt = class(TSqlStmtNode)
  public
    IndexName: string;
    Table: string;
    Col: string;
    Cols: array of string;   // cok kolonlu indeks (Col = Cols[0], geri uyum)
    // F2-23: CREATE UNIQUE INDEX. ONCEDEN bu bayrak Parse'da yutuluyor,
    // motora hic tasinmiyordu; sonuc UNIQUE tanimi HIC zorlanmiyordu.
    Uniq: Boolean;
    // F-17: PARTIAL INDEX kosulu ("CREATE INDEX ix ON t(c) WHERE x > 0").
    // Bos = normal indeks (tum satirlar indekslenir).
    Predicate: string;
    // F-17: kosul AST'si (yazma yolunda satir bazinda uygulanir).
    PredExpr: TSqlExprNode;
    // F-18: EXPRESSION INDEX — "CREATE INDEX ix ON t(LOWER(ad))".
    // Bos = normal (kolon) indeks. Dolu ise indeks anahtari bu ifadenin
    // satir basina degeridir. Yalniz TEK ifade kabul edilir (Cols bos birakilir).
    ExprText: string;
    ExprNode: TSqlExprNode;
    // F-19: COVERING INDEX — INCLUDE kolonlari (anahtar degil, indekste tasinir)
    Incl: array of string;
    // R-22: Online DDL — CREATE INDEX CONCURRENTLY
    Concurrently: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  { F-20: EXPLAIN — sorgu planini dondurur (calistirmadan).
    Altinda yalniz SELECT/INSERT/UPDATE/DELETE olabilir. }
  TSqlExplainStmt = class(TSqlStmtNode)
  public
    Inner: TSqlStmtNode;   // aciklanacak cumle (sahiplik devralir)
    Analyze: Boolean;      // EXPLAIN ANALYZE: yurut + sureyi olc
    constructor Create;
    destructor Destroy; override;
  end;

  { DROP INDEX Cumlesi }
  TSqlDropIndexStmt = class(TSqlStmtNode)
  public
    IndexName: string;
    IfExists: Boolean;
    constructor Create;
  end;

  { UPSERT / ON CONFLICT (R-03) }
  TOnConflictAction = VDbTypes.TOnConflictAction;

  { VIEW DML (F-33) }
  TSqlCreateViewStmt = class(TSqlStmtNode)
  public

    ViewName: string;
    SelectStmt: TSqlSelectStmt;
    SelectText: string;
    IfNotExists: Boolean;
    constructor Create; override;
    destructor Destroy; override;
  end;

  TSqlDropViewStmt = class(TSqlStmtNode)
  public
    ViewName: string;
    IfExists: Boolean;
    constructor Create; override;
  end;

  { MATERIALIZED VIEW (F-34) }
  TSqlCreateMaterializedViewStmt = class(TSqlStmtNode)
  public
    ViewName: string;
    SelectStmt: TSqlSelectStmt;
    SelectText: string;
    IfNotExists: Boolean;
    constructor Create; override;
    destructor Destroy; override;
  end;

  TSqlDropMaterializedViewStmt = class(TSqlStmtNode)
  public
    ViewName: string;
    IfExists: Boolean;
    constructor Create; override;
  end;

  TSqlRefreshMaterializedViewStmt = class(TSqlStmtNode)
  public
    ViewName: string;
    Concurrently: Boolean;
    constructor Create; override;
  end;

  { TRIGGER (F-36) }
  TSqlCreateTriggerStmt = class(TSqlStmtNode)
  public
    TriggerName: string;
    TableName: string;
    Events: array of Byte;
    Timing: Byte;
    ForEach: Byte;
    WhenCondition: TSqlExprNode;
    Body: TSqlStmtNode;          // F-36: AS govdesi (BEFORE/AFTER blok)
    FunctionName: string;
    IfNotExists: Boolean;
    constructor Create; override;
    destructor Destroy; override;
  end;

  TSqlDropTriggerStmt = class(TSqlStmtNode)
  public
    TriggerName: string;
    TableName: string;
    IfExists: Boolean;
    constructor Create; override;
  end;

  { F-36: BEFORE tetikleyicide satiri degistirme:
      NEW.kolon = <ifade>
    Satirin YENI degeri bu cumle ile guncellenir; deger tabloya
    YAZILMADAN ONCE uygulanir. }
  TSqlSetNewStmt = class(TSqlStmtNode)
  public
    ColName: string;
    Expr: TSqlExprNode;
    constructor Create; override;
    destructor Destroy; override;
  end;

  { STORED PROCEDURE / FUNCTION (F-35) }
  TSqlCreateFunctionStmt = class(TSqlStmtNode)
  public
    Name: string;
    Parameters: array of TFunctionParameter;
    ReturnType: string;
    Language: string;
    Body: TSqlStmtNode;
    IfNotExists: Boolean;
    constructor Create; override;
    destructor Destroy; override;
  end;

  TSqlDropFunctionStmt = class(TSqlStmtNode)
  public
    Name: string;
    IfExists: Boolean;
    constructor Create; override;
  end;

  TSqlCreateProcedureStmt = class(TSqlStmtNode)
  public
    Name: string;
    Parameters: array of TFunctionParameter;
    Language: string;
    Body: TSqlStmtNode;
    IfNotExists: Boolean;
    constructor Create; override;
    destructor Destroy; override;
  end;

  TSqlDropProcedureStmt = class(TSqlStmtNode)
  public
    Name: string;
    IfExists: Boolean;
    constructor Create; override;
  end;

  TSqlCallStmt = class(TSqlStmtNode)
  public
    ProcName: string;
    Arguments: TList<TSqlExprNode>;
    constructor Create; override;
    destructor Destroy; override;
  end;

  { F-35: RETURN <ifade> — fonksiyon/prosedur govdesinden deger dondurur }
  TSqlReturnStmt = class(TSqlStmtNode)
  public
    Expr: TSqlExprNode;
    constructor Create; override;
    destructor Destroy; override;
  end;

  { F-35: BEGIN ... END govde blogu.
    Govde AST olarak saklanir; CREATE cumlesi bitince AST Free EDILIR,
    bu yuzden katalog govdeyi SAHPLENIR (bkz. TVTableDb.FFunctions). }
  TSqlBlockStmt = class(TSqlStmtNode)
  public
    Stmts: TList<TSqlStmtNode>;
    constructor Create; override;
    destructor Destroy; override;
  end;

  { F-40: islem yalitim seviyeleri. Motorda varsayilan REPEATABLE READ
    (batch basi snapshot). READ COMMITTED her cumle basinda gorunurluk
    penceresini ilerletir. SERIALIZABLE su an REPEATABLE READ ile ayni
    snapshot davranisini kullanir (tek global yazma kilidi ek koruma). }
  TIsolationLevel = (ilReadUncommitted, ilReadCommitted,
    ilRepeatableRead, ilSerializable);

  { Transaction Cumlesi (BEGIN / COMMIT / ROLLBACK / SAVEPOINT) }
  TTxKind = (txBegin, txCommit, txRollback, txSavepoint, txRollbackTo, txReleaseSavepoint);

  TSqlTxStmt = class(TSqlStmtNode)
  public
    Kind: TTxKind;
    SavepointName: string;
    constructor Create(AKind: TTxKind);
  end;

  { F-40: SET TRANSACTION ISOLATION LEVEL ... }
  TSqlSetIsolationStmt = class(TSqlStmtNode)
  public
    Level: TIsolationLevel;
    constructor Create(ALevel: TIsolationLevel);
  end;

  { Yonetim ve Bakim Cumlesi }
  TAdminKind = (
    admCreateDb, admDropDb, admOpenDb, admCloseDb,
    admBackupDb, admVerify, admVacuum, admReindex,
    admListDbs, admShowTables,
    // R-16 (2026-10-12): WAL arsivleme + PITR
    //   BACKUP TO 'yol'            -> tam kopya (+ arsiv segmenti)
    //   RECOVER TO TIMESTAMP 't'  -> arsivden t anina kadar uygula
    //   RESTORE FROM 'yol'         -> yedekten geri yukle
    //   ARCHIVE WAL SET DIR='yol' SIZE=<bayt>
    //   ARCHIVE WAL LIST
    admRecoverTo, admRestoreFrom,
    admArchiveSet, admArchiveList,
    // 2026-10-04: SEMA SORGULARI. Once motorun sema bilgisi yalnizca
    // programatik API'den (GetTable) okunabiliyordu; SQL tarafinda
    // hicbir yol yoktu. Yonetim/otomasyon icin eklendi.
    admDescribe, admShowIndexes, admShowCreateTable,
    // 2026-10-05: ALTER DATABASE KEY 'parola' - anahtar rotasyonu
    admAlterDbKey,
    admPragma,
    // R-02: SAVEPOINT
    admSavepoint, admReleaseSavepoint, admRollbackToSavepoint,
    // R-15: Cost-Based Optimizer — ANALYZE
    admAnalyze,
    // R-17: Streaming Replication
    admReplicationStart, admReplicationStop,
    admCreateReplSlot, admDropReplSlot,
    admShowReplicationStatus,
    admReplicationPump,     // PUMP REPLICATION (tek log-shipping adimi)
    admShowReplSlots        // SHOW REPLICATION SLOTS
    // R-21: Extension/Plugin
    , admCreateExtension, admDropExtension, admShowExtensions,
    // R-13 Full: SHOW PARTITIONS t
    admShowPartitions,
    // R-24 (2026-10-13): SHOW STATS / SHOW STATS TABLE t
    admShowStats
  );

  TSqlAdminStmt = class(TSqlStmtNode)
  public
    Kind: TAdminKind;
    DbName: string;
    BackupPath: string;
    { R-16: PITR hedef zaman damgasi (Unix ms). RECOVER TO TIMESTAMP
      icin kullanilir; 0 ise "su ana kadar" demektir. }
    RecoverStamp: QWord;
    { R-16: ARCHIVE WAL SET icin dizin ve segment boyutu. }
    ArchiveDir: string;
    ArchiveSize: Int64;
    IfExists: Boolean;
    IfNotExists: Boolean;
    TableName: string;   // DESCRIBE / SHOW INDEXES / SHOW CREATE TABLE
    PragmaName: string; // 4.6: PRAGMA
    NewKeyPassword: string; // ALTER DATABASE KEY
    // R-02: SAVEPOINT
    SavepointName: string;
    // R-17: Streaming Replication
    ReplSlot: string;       // slot adı
    ReplConnInfo: string;   // standby için connection info / primary için DEST
    ReplIsPrimary: Boolean; // True=PRIMARY, False=STANDBY
    // R-17 Full: TCP akış modu
    ReplTcp: Boolean;       // True = TCP taşma (PORT/HOST sözdizimi kullanıldı)
    ReplHost: string;       // STANDBY TCP: primary'nin host'u
    ReplPort: Integer;      // TCP port (primary: dinleme, standby: bağlanma)
    // R-21: Extension/Plugin
    ExtName: string;        // extension adi
    ExtPath: string;        // CREATE EXTENSION ... FROM 'yol' (opsiyonel)
    constructor Create(AKind: TAdminKind);
  end;

  { R-18: RBAC / ROLES
    Izinler tablo bazlidir: SELECT, INSERT, UPDATE, DELETE, ALL.
    Roller sema ile birlikte saklanir (katalog) ve bir GRANTS
    eslemesi ile tablo -> izin -> rol seti tutulur. }

  // NOT: TPrivKind VDbTypes'ta tanimlidir (bkz. VDbTypes); VDbAst
  // yalnizca onu kullanir.

  TRoleStmt = class(TSqlStmtNode)
  public
    Make: Boolean;        // True = CREATE ROLE, False = DROP ROLE
    RoleName: string;
    Super: Boolean;       // CREATE ROLE ... SUPERUSER
    constructor Create; override;
  end;

  TGrantStmt = class(TSqlStmtNode)
  public
    Revoke: Boolean;      // True = REVOKE
    Priv: TPrivKind;
    TableName: string;    // '*' =tum tablolar
    RoleName: string;
    constructor Create; override;
  end;

  TSetRoleStmt = class(TSqlStmtNode)
  public
    RoleName: string;     // 'NONE' = rolden cik
    constructor Create; override;
  end;

  { R-11: SET CONSTRAINTS [ALL] DEFERRED | IMMEDIATE
    Deferred=True -> kisitlar COMMIT'e kadar denetlenmez.
    NOT: enum'a eklenmedi; enum degerleri kayitlarda kullanildigi icin
    kaydirilmamalidir. }
  TSqlSetConstraintsStmt = class(TSqlStmtNode)
  public
    Deferred: Boolean;
    All: Boolean;
    constructor Create; override;
  end;

  { JSON Export / Import Cumlesi }
  TJsonOpKind = (jsoExport, jsoImport);

  TSqlJsonStmt = class(TSqlStmtNode)
  public
    Kind: TJsonOpKind;
    Table: string;  // bos ise tum veritabani
    FilePath: string;
    constructor Create(AKind: TJsonOpKind);
  end;

  { SQL sorgu sonucu (VDbSql.pas ile paylasilan ortak tip) }
  TSqlResult = record
    Fields: TStrArray;
    Rows: TStrMatrix;
    Affected: Integer;
    Msg: string;
    // Son komutun dokundugu tablo (INSERT/UPDATE/DELETE/DDL).
    LastTable: string;
    // Islenen komut sayisi (betik icin)
    Stmts: Integer;
  end;

function SqlBinaryOpToStr(Op: TSqlBinaryOp): string;
function SqlBinaryOpFromStr(const S: string): TSqlBinaryOp;

implementation

{ ------------------------------------------------------------
  TJoinUsingRec (F-28) - now a record, no constructor/destructor needed
  //---------------------------------------------------------- }

function SqlBinaryOpToStr(Op: TSqlBinaryOp): string;
begin
  case Op of
    sboAdd: Result := '+';
    sboSub: Result := '-';
    sboMul: Result := '*';
    sboDiv: Result := '/';
    sboMod: Result := '%';
    sboEq:  Result := '=';
    sboNeq: Result := '<>';
    sboLt:  Result := '<';
    sboLte: Result := '<=';
    sboGt:  Result := '>';
    sboGte: Result := '>=';
    sboLike: Result := 'LIKE';
    sboAnd: Result := 'AND';
    sboOr:  Result := 'OR';
    sboConcat: Result := '||';
  else
    Result := '?';
  end;
end;

function SqlBinaryOpFromStr(const S: string): TSqlBinaryOp;
var
  u: string;
begin
  u := UpperCase(Trim(S));
  if u = '+' then Result := sboAdd
  else if u = '-' then Result := sboSub
  else if u = '*' then Result := sboMul
  else if u = '/' then Result := sboDiv
  else if u = '%' then Result := sboMod
  else if u = '=' then Result := sboEq
  else if (u = '<>') or (u = '!=') then Result := sboNeq
  else if u = '<' then Result := sboLt
  else if u = '<=' then Result := sboLte
  else if u = '>' then Result := sboGt
  else if u = '>=' then Result := sboGte
  else if u = 'LIKE' then Result := sboLike
  else if u = 'AND' then Result := sboAnd
  else if u = 'OR' then Result := sboOr
  else if u = '||' then Result := sboConcat
  else raise EVDbException.Create(ecSyntaxError, 'Gecersiz ikili operator: ' + S);
end;

{ TSqlNode }

constructor TSqlNode.Create;
begin
  inherited Create;
end;

destructor TSqlNode.Destroy;
begin
  inherited Destroy;
end;

{ TSqlLiteralNode }

constructor TSqlLiteralNode.CreateNull;
begin
  inherited Create;
  LitType := sltNull;
  StrVal := '';
  IntVal := 0;
  FloatVal := 0.0;
  BoolVal := False;
end;

constructor TSqlLiteralNode.CreateInt(const V: Int64);
begin
  inherited Create;
  LitType := sltInt;
  IntVal := V;
  StrVal := IntToStr(V);
  FloatVal := V;
  BoolVal := V <> 0;
end;

constructor TSqlLiteralNode.CreateFloat(const V: Double);
begin
  inherited Create;
  LitType := sltFloat;
  FloatVal := V;
  StrVal := VdbTable.VDbFloatToStr(V);
  IntVal := Trunc(V);
  BoolVal := V <> 0.0;
end;

constructor TSqlLiteralNode.CreateStr(const V: string);
begin
  inherited Create;
  LitType := sltString;
  StrVal := V;
  IntVal := 0;
  FloatVal := 0.0;
  BoolVal := V <> '';
end;

constructor TSqlLiteralNode.CreateBool(const V: Boolean);
begin
  inherited Create;
  LitType := sltBool;
  BoolVal := V;
  if V then StrVal := 'True' else StrVal := 'False';
  IntVal := Ord(V);
  FloatVal := Ord(V);
end;

function TSqlLiteralNode.AsString: string;
begin
  Result := StrVal;
end;

{ TSqlColumnRefNode }

constructor TSqlColumnRefNode.Create(const ACol: string; const ATable: string);
begin
  inherited Create;
  ColumnName := VDbTable.VDbNorm(ACol);
  TableQualifier := VDbTable.VDbNorm(ATable);
end;

function TSqlColumnRefNode.QualifiedName: string;
begin
  if TableQualifier <> '' then
    Result := TableQualifier + '.' + ColumnName
  else
    Result := ColumnName;
end;

{ TSqlCastNode }

constructor TSqlCastNode.Create(AExpr: TSqlExprNode; const AType: string);
begin
  inherited Create;
  Expr := AExpr;
  TargetType := UpperCase(AType);
end;

destructor TSqlCastNode.Destroy;
begin
  Expr.Free;
  inherited Destroy;
end;

{ TSqlBinaryOpNode }

constructor TSqlBinaryOpNode.Create(AOp: TSqlBinaryOp; ALeft, ARight: TSqlExprNode);
begin
  inherited Create;
  Op := AOp;
  Left := ALeft;
  Right := ARight;
end;

destructor TSqlBinaryOpNode.Destroy;
begin
  Left.Free;
  Right.Free;
  inherited Destroy;
end;

{ TSqlUnaryOpNode }

constructor TSqlUnaryOpNode.Create(AOp: TSqlUnaryOp; AOperand: TSqlExprNode);
begin
  inherited Create;
  Op := AOp;
  Operand := AOperand;
end;

destructor TSqlUnaryOpNode.Destroy;
begin
  Operand.Free;
  inherited Destroy;
end;

{ TSqlInNode }

constructor TSqlInNode.Create(AExpr: TSqlExprNode; AIsNot: Boolean);
begin
  inherited Create;
  Expr := AExpr;
  IsNot := AIsNot;
  List := TList<TSqlExprNode>.Create;
  SubSelect := nil;
end;

destructor TSqlInNode.Destroy;
var
  i: Integer;
begin
  Expr.Free;
  if List <> nil then
  begin
    for i := 0 to List.Count - 1 do
      List[i].Free;
    List.Free;
  end;
  SubSelect.Free;
  inherited Destroy;
end;

{ TSqlAggNode (F-14/F-15) }

constructor TSqlAggNode.Create(AKind: TAggKind);
begin
  inherited Create;
  Kind := AKind;
  Arg := nil;
  Sep := nil;
  Pct := 0.5;
  IsDistinct := False;
end;

destructor TSqlAggNode.Destroy;
begin
  Arg.Free;
  Sep.Free;
  inherited Destroy;
end;

{ TSqlQuantNode (F-06: ANY/SOME/ALL) }

constructor TSqlQuantNode.Create(AKind: TQuantKind; AL: TSqlExprNode;
  ACmpOp: TSqlBinaryOp; ASel: TSqlSelectStmt);
begin
  inherited Create;
  Kind := AKind;
  Left := AL;
  CmpOp := ACmpOp;
  SubSelect := ASel;
end;

destructor TSqlQuantNode.Destroy;
begin
  Left.Free;
  SubSelect.Free;
  inherited Destroy;
end;

{ TSqlSubqueryNode }

constructor TSqlSubqueryNode.CreateScalar(ASelect: TSqlSelectStmt);
begin
  inherited Create;
  Select := ASelect;
  Kind := sqScalar;
  IsNot := False;
end;

constructor TSqlSubqueryNode.CreateExists(ASelect: TSqlSelectStmt;
  AIsNot: Boolean);
begin
  inherited Create;
  Select := ASelect;
  Kind := sqExists;
  IsNot := AIsNot;
end;

destructor TSqlSubqueryNode.Destroy;
begin
  Select.Free;
  inherited Destroy;
end;

{ TSqlBetweenNode }

constructor TSqlBetweenNode.Create(AExpr, ALow, AHigh: TSqlExprNode; AIsNot: Boolean);
begin
  inherited Create;
  Expr := AExpr;
  LowBound := ALow;
  HighBound := AHigh;
  IsNot := AIsNot;
end;

destructor TSqlBetweenNode.Destroy;
begin
  Expr.Free;
  LowBound.Free;
  HighBound.Free;
  inherited Destroy;
end;

{ R-20: TSqlCollateNode }

constructor TSqlCollateNode.Create(AInner: TSqlExprNode; const AName: string);
begin
  inherited Create;
  Inner := AInner;
  Name := AName;
end;

destructor TSqlCollateNode.Destroy;
begin
  Inner.Free;
  inherited Destroy;
end;

{ TSqlFuncCallNode }

constructor TSqlFuncCallNode.Create(const AFunc: string; AArg: TSqlExprNode;
  AIsStar: Boolean; AIsDistinct: Boolean);
begin
  inherited Create;
  FuncName := UpperCase(AFunc);
  Arg := AArg;
  IsStar := AIsStar;
  IsDistinct := AIsDistinct;
  Filter := nil;   // F-16
  Args := nil;     // F-23 (degisken argumanli fonksiyonlar)
end;

{ F-35: kullanicinin tanimladigi degisken-argumanli fonksiyonlar.
  Arg BOSTUR; tum argumanlar Args icinde sirayla durur. Sahiplik
  listeye devredilir (cagiran listeyi Free ETMEZ). }
constructor TSqlFuncCallNode.CreateList(const AFunc: string; AArgs: TList<TSqlExprNode>;
  AIsStar: Boolean; AIsDistinct: Boolean);
begin
  inherited Create;
  FuncName := UpperCase(AFunc);
  Arg := nil;
  IsStar := AIsStar;
  IsDistinct := AIsDistinct;
  Filter := nil;
  Args := AArgs;
end;

destructor TSqlFuncCallNode.Destroy;
var
  i: Integer;
begin
  Arg.Free;
  Filter.Free;   // F-16
  // DIKKAT: Args normal fonksiyonlarda nil'dir; TList.Count nil nesne
  // uzerinde ACCESS VIOLATION verir. Kontrol sart olmali.
  if Args <> nil then
  begin
    for i := 0 to Args.Count - 1 do Args[i].Free;
    Args.Free;
  end;
  inherited Destroy;
end;

{ TSqlWindowNode }

constructor TSqlWindowNode.Create(const AFunc: string);
begin
  inherited Create;
  FuncName := UpperCase(AFunc);
  Arg := nil;
  IsStar := False;
  Offset := 1;
  Default := nil;
  Partitions := TList<TSqlExprNode>.Create;
  OrderBys := TList<TOrderItem>.Create;
end;

destructor TSqlWindowNode.Destroy;
var
  i: Integer;
begin
  Arg.Free;
  Default.Free;
  if Partitions <> nil then
  begin
    for i := 0 to Partitions.Count - 1 do
      Partitions[i].Free;
    Partitions.Free;
  end;
  if OrderBys <> nil then
  begin
    for i := 0 to OrderBys.Count - 1 do
      OrderBys[i].Expr.Free;
    OrderBys.Free;
  end;
  inherited Destroy;
end;

{ TSqlCaseNode }

constructor TSqlCaseNode.Create(AOperand: TSqlExprNode);
begin
  inherited Create;
  Operand := AOperand;
  Whens := TList<TSqlCaseWhen>.Create;
  ElseExpr := nil;
end;

destructor TSqlCaseNode.Destroy;
var
  i: Integer;
begin
  Operand.Free;
  if Whens <> nil then
  begin
    for i := 0 to Whens.Count - 1 do
    begin
      Whens[i].Cond.Free;
      Whens[i].Value.Free;
    end;
    Whens.Free;
  end;
  ElseExpr.Free;
  inherited Destroy;
end;

{ TSqlNullIfNode }

constructor TSqlNullIfNode.Create(A1, A2: TSqlExprNode);
begin
  inherited Create;
  Arg1 := A1;
  Arg2 := A2;
end;

destructor TSqlNullIfNode.Destroy;
begin
  Arg1.Free;
  Arg2.Free;
  inherited Destroy;
end;

{ TSqlCoalesceNode }

constructor TSqlCoalesceNode.Create(AArgs: TList<TSqlExprNode>);
begin
  inherited Create;
  Args := AArgs;
end;

destructor TSqlCoalesceNode.Destroy;
var
  i: Integer;
begin
  for i := 0 to Args.Count - 1 do
    Args[i].Free;
  Args.Free;
  inherited Destroy;
end;

{ TSqlJsonKeyNode (F-22) }

constructor TSqlJsonKeyNode.Create(ALeft: TSqlExprNode;
  AKeys: TList<TSqlExprNode>; AAll: Boolean);
begin
  inherited Create;
  Left := ALeft;
  Keys := AKeys;
  RequireAll := AAll;
end;

destructor TSqlJsonKeyNode.Destroy;
var
  i: Integer;
begin
  Left.Free;
  for i := 0 to Keys.Count - 1 do Keys[i].Free;
  Keys.Free;
  inherited Destroy;
end;

{ TSqlStmtNode }

constructor TSqlStmtNode.Create;
begin
  inherited Create;
end;

{ TSqlSelectStmt }

constructor TSqlSelectStmt.Create;
begin
  inherited Create;
  IsDistinct := False;
  Columns := TList<TSelectColumnItem>.Create;
  FromTable := '';
  FromAlias := '';
  HasJoin := False;
  Join.OnCondition := nil;
  Join.Natural := False;
  Join.LateralIdx := -1;
  JoinUsing := TList<TJoinUsingRec>.Create;
  LateralSubs := TList<TSqlSelectStmt>.Create;
  MoreJoins := TList<TJoinClause>.Create;
  WithQueries := TList<TWithQuery>.Create;
  WhereClause := nil;
  GroupByCols := TList<string>.Create;
  HavingClause := nil;
  QualifyClause := nil;   // F-09
  OrderBy := TList<TOrderItem>.Create;
  LimitVal := -1;
  OffsetVal := 0;
  SetOp := sokNone;
  RightSelect := nil;
  AsOf := saoNone;
  AsOfValue := 0;
  AsOfText := '';
  ForUpdate := False;
end;

destructor TSqlSelectStmt.Destroy;
var
  i: Integer;
begin
  if Columns <> nil then
  begin
    for i := 0 to Columns.Count - 1 do
      Columns[i].Expr.Free;
    Columns.Free;
  end;
  if HasJoin then
    Join.OnCondition.Free;
  if LateralSubs <> nil then
  begin
    for i := 0 to LateralSubs.Count - 1 do
      LateralSubs[i].Free;
    LateralSubs.Free;
  end;
  if MoreJoins <> nil then
  begin
    for i := 0 to MoreJoins.Count - 1 do
      MoreJoins[i].OnCondition.Free;
    MoreJoins.Free;
  end;
  // JoinUsing is a record with dynamic array (auto-managed), no Free needed
  // if JoinUsing <> nil then
  // begin
  //   for i := 0 to JoinUsing.Count - 1 do
  //     JoinUsing[i].Free;
  //   JoinUsing.Free;
  // end;
  if WithQueries <> nil then
  begin
    for i := 0 to WithQueries.Count - 1 do
      WithQueries[i].Select.Free;
    WithQueries.Free;
  end;
  WhereClause.Free;
  GroupByCols.Free;
  HavingClause.Free;
  QualifyClause.Free;   // F-09
  if OrderBy <> nil then
  begin
    for i := 0 to OrderBy.Count - 1 do
      OrderBy[i].Expr.Free;
    OrderBy.Free;
  end;
  RightSelect.Free;
  inherited Destroy;
end;

{ TSqlInsertStmt }

constructor TSqlInsertStmt.Create;
begin
  inherited Create;
  Table := '';
  SetLength(Columns, 0);
  ValuesRows := TList<TInsertValuesRow>.Create;
  SelectSrc := nil;
  WithQueries := TList<TWithQuery>.Create; // 4.5
  OnConflictAction := ocaNone;
  SetLength(OnConflictTarget, 0);
  OnConflictSetExprs := TList<TUpdateAssignment>.Create;
  SetLength(ReturningCols, 0);
  ReturningExprs := TList<TSqlExprNode>.Create;
end;

destructor TSqlInsertStmt.Destroy;
var
  i, j: Integer;
begin
  if WithQueries <> nil then
    WithQueries.Free; // 4.5
  if ValuesRows <> nil then
  begin
    for i := 0 to ValuesRows.Count - 1 do
    begin
      for j := 0 to ValuesRows[i].Count - 1 do
        ValuesRows[i][j].Free;
      ValuesRows[i].Free;
    end;
    ValuesRows.Free;
  end;
  SelectSrc.Free;
  OnConflictSetExprs.Free;
  ReturningExprs.Free;
  inherited Destroy;
end;

{ TSqlUpdateStmt }

constructor TSqlUpdateStmt.Create;
begin
  inherited Create;
  Table := '';
  Assignments := TList<TUpdateAssignment>.Create;
  WhereClause := nil;
  WithQueries := TList<TWithQuery>.Create; // 4.5
  SetLength(ReturningCols, 0);
  ReturningExprs := TList<TSqlExprNode>.Create;
end;

destructor TSqlUpdateStmt.Destroy;
var
  i: Integer;
begin
  if WithQueries <> nil then
    WithQueries.Free; // 4.5
  if Assignments <> nil then
  begin
    for i := 0 to Assignments.Count - 1 do
      Assignments[i].Expr.Free;
    Assignments.Free;
  end;
  WhereClause.Free;
  ReturningExprs.Free;
  inherited Destroy;
end;

{ TSqlDeleteStmt }

constructor TSqlDeleteStmt.Create;
begin
  inherited Create;
  Table := '';
  WhereClause := nil;
  WithQueries := TList<TWithQuery>.Create; // 4.5
  SetLength(ReturningCols, 0);
  ReturningExprs := TList<TSqlExprNode>.Create;
end;

destructor TSqlDeleteStmt.Destroy;
begin
  WhereClause.Free;
  if WithQueries <> nil then
    WithQueries.Free; // 4.5
  ReturningExprs.Free;
  inherited Destroy;
end;

{ TSqlCreateTableStmt }

constructor TSqlCreateTableStmt.Create;
begin
  inherited Create;
  Table := '';
  IfNotExists := False;
  SetLength(Cols, 0);
  // F2-22: -1 = "PK tanimlanmadi". 0 idi; boylece PRIMARY KEY yazilmamis
  // CREATE TABLE'lerde ilk kolon PK saniliyordu.
  PkIndex := -1;
  SetLength(Checks, 0);
  SetLength(Fks, 0);
  CheckExprs := TList<TSqlExprNode>.Create;
  PartitionType := '';
  PartitionCol := '';
  PartitionValues := TStringList.Create;
end;

destructor TSqlCreateTableStmt.Destroy;
var i: Integer;
begin
  if CheckExprs <> nil then
  begin
    for i := 0 to CheckExprs.Count - 1 do CheckExprs[i].Free;
    CheckExprs.Free;
  end;
  if PartitionValues <> nil then PartitionValues.Free;
  inherited Destroy;
end;

{ TSqlAlterTableStmt }

constructor TSqlAlterTableStmt.Create;
begin
  inherited Create;
  Table := '';
  Action := ataAddColumn;
  ColName := '';
  NewName := '';
  PositionCol := '';
  IsFirst := False;
  DefaultVal := '';
  NewTypeName := '';
end;

{ TSqlDropTableStmt }

constructor TSqlDropTableStmt.Create;
begin
  inherited Create;
  Table := '';
  IfExists := False;
end;

{ TSqlCreateIndexStmt }

constructor TSqlCreateIndexStmt.Create;
begin
  inherited Create;
  IndexName := '';
  Table := '';
  Col := '';
  Uniq := False;
  Predicate := '';   // F-17
  PredExpr := nil;   // F-17
  ExprText := '';    // F-18
  ExprNode := nil;   // F-18
  Incl := nil;       // F-19
end;

destructor TSqlCreateIndexStmt.Destroy;
begin
  PredExpr.Free;   // F-17
  ExprNode.Free;   // F-18
  inherited Destroy;
end;

{ TSqlDropIndexStmt }

constructor TSqlDropIndexStmt.Create;
begin
  inherited Create;
  IndexName := '';
  IfExists := False;
end;

{ TSqlCreateViewStmt }

constructor TSqlCreateViewStmt.Create;
begin
  inherited Create;
  ViewName := '';
  SelectStmt := nil;
  SelectText := '';
  IfNotExists := False;
end;

destructor TSqlCreateViewStmt.Destroy;
begin
  SelectStmt.Free;
  inherited Destroy;
end;

{ TSqlDropViewStmt }

constructor TSqlDropViewStmt.Create;
begin
  inherited Create;
  ViewName := '';
  IfExists := False;
end;

{ TSqlCreateMaterializedViewStmt }

constructor TSqlCreateMaterializedViewStmt.Create;
begin
  inherited Create;
  ViewName := '';
  SelectStmt := nil;
  SelectText := '';
  IfNotExists := False;
end;

destructor TSqlCreateMaterializedViewStmt.Destroy;
begin
  SelectStmt.Free;
  inherited Destroy;
end;

{ TSqlDropMaterializedViewStmt }

constructor TSqlDropMaterializedViewStmt.Create;
begin
  inherited Create;
  ViewName := '';
  IfExists := False;
end;

{ TSqlRefreshMaterializedViewStmt }

constructor TSqlRefreshMaterializedViewStmt.Create;
begin
  inherited Create;
  ViewName := '';
  Concurrently := False;
end;

{ TSqlCreateTriggerStmt }

constructor TSqlCreateTriggerStmt.Create;
begin
  inherited Create;
  TriggerName := '';
  TableName := '';
  Events := nil;
  Timing := 0;
  ForEach := 0;
  WhenCondition := nil;
  Body := nil;
  FunctionName := '';
  IfNotExists := False;
end;

destructor TSqlCreateTriggerStmt.Destroy;
begin
  WhenCondition.Free;
  // Govde sahipligi katalogu DEVRETTIGI icin burada nil olmalidir;
  // dolu birakilirsa katalogda dangling pointer kalir (cagirimda AV).
  Body.Free;
  inherited Destroy;
end;

{ TSqlDropTriggerStmt }

constructor TSqlDropTriggerStmt.Create;
begin
  inherited Create;
  TriggerName := '';
  TableName := '';
  IfExists := False;
end;

{ TSqlSetNewStmt }

constructor TSqlSetNewStmt.Create;
begin
  inherited Create;
  ColName := '';
  Expr := nil;
end;

destructor TSqlSetNewStmt.Destroy;
begin
  Expr.Free;
  inherited Destroy;
end;

{ TSqlCreateFunctionStmt }

constructor TSqlCreateFunctionStmt.Create;
begin
  inherited Create;
  Name := '';
  Parameters := nil;
  ReturnType := '';
  Language := '';
  Body := nil;
  IfNotExists := False;
end;

destructor TSqlCreateFunctionStmt.Destroy;
begin
  // Parameters is array of record, no Free needed
  Body.Free;
  inherited Destroy;
end;

{ TSqlDropFunctionStmt }

constructor TSqlDropFunctionStmt.Create;
begin
  inherited Create;
  Name := '';
  IfExists := False;
end;

{ TSqlCreateProcedureStmt }

constructor TSqlCreateProcedureStmt.Create;
begin
  inherited Create;
  Name := '';
  Parameters := nil;
  Language := '';
  Body := nil;
  IfNotExists := False;
end;

destructor TSqlCreateProcedureStmt.Destroy;
begin
  // Parameters is array of record, no Free needed
  Body.Free;
  inherited Destroy;
end;

{ TSqlDropProcedureStmt }

constructor TSqlDropProcedureStmt.Create;
begin
  inherited Create;
  Name := '';
  IfExists := False;
end;

{ TSqlCallStmt }

constructor TSqlCallStmt.Create;
begin
  inherited Create;
  ProcName := '';
  Arguments := TList<TSqlExprNode>.Create;
end;

destructor TSqlCallStmt.Destroy;
begin
  Arguments.Free;
  inherited Destroy;
end;

{ TSqlReturnStmt }

constructor TSqlReturnStmt.Create;
begin
  inherited Create;
  Expr := nil;
end;

destructor TSqlReturnStmt.Destroy;
begin
  Expr.Free;
  inherited Destroy;
end;

{ TSqlBlockStmt }

constructor TSqlBlockStmt.Create;
begin
  inherited Create;
  Stmts := TList<TSqlStmtNode>.Create;
end;

destructor TSqlBlockStmt.Destroy;
var
  i: Integer;
begin
  // Alt cumlelerin HESAPLANMIS sonuclari bu bloga ait; hepsi serbest
  // birakilir. Eksik Free = bellek sizintisi.
  if Stmts <> nil then
    for i := 0 to Stmts.Count - 1 do
      Stmts[i].Free;
  Stmts.Free;
  inherited Destroy;
end;

{ TSqlExplainStmt }

constructor TSqlExplainStmt.Create;
begin
  inherited Create;
  Inner := nil;
  Analyze := False;
end;

destructor TSqlExplainStmt.Destroy;
begin
  Inner.Free;   // F-20
  inherited Destroy;
end;

{ TSqlTxStmt }

constructor TSqlTxStmt.Create(AKind: TTxKind);
begin
  inherited Create;
  Kind := AKind;
  SavepointName := '';
end;

constructor TSqlSetIsolationStmt.Create(ALevel: TIsolationLevel);
begin
  inherited Create;
  Level := ALevel;
end;

{ TSqlAdminStmt }

constructor TRoleStmt.Create;
begin
  inherited Create;
  Make := False;   // varsayilan DROP ROLE
  Super := False;
end;

constructor TGrantStmt.Create;
begin
  inherited Create;
  Revoke := False;
  Priv := pkNone;
end;

constructor TSetRoleStmt.Create;
begin
  inherited Create;
  RoleName := '';
end;

constructor TSqlSetConstraintsStmt.Create;
begin
  inherited Create;
  Deferred := False;
  All := True;
end;

constructor TPolicyStmt.Create;
begin
  inherited Create;
  Make := True;
  Cmd := polAll;
  UsingExpr := nil;
  CheckExpr := nil;
end;

destructor TPolicyStmt.Destroy;
begin
  UsingExpr.Free;
  CheckExpr.Free;
  inherited Destroy;
end;

constructor TSqlAdminStmt.Create(AKind: TAdminKind);
begin
  inherited Create;
  Kind := AKind;
  DbName := '';
  BackupPath := '';
  IfExists := False;
  IfNotExists := False;
end;

{ TSqlJsonStmt }

constructor TSqlJsonStmt.Create(AKind: TJsonOpKind);
begin
  inherited Create;
  Kind := AKind;
  Table := '';
  FilePath := '';
end;

end.
