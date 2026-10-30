unit VDbSql;

{ Minimal SQL v1:
  CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT, c FLOAT, d BOOL)
  INSERT INTO t (a,b) VALUES (1,'x')
  SELECT * | a,b | COUNT(*) FROM t [WHERE c op v [AND ...]] [LIMIT n] [OFFSET m]
  SELECT SUM/AVG/MIN/MAX(..) [AS ad] [GROUP BY k] [ORDER BY cikti] [LIMIT ..]
  CREATE/DROP INDEX i ON t (c)
  UPDATE t SET b='y' WHERE a=1
  DELETE FROM t WHERE a=1
  DROP TABLE t
  EXPORT [TABLE t] JSON 'dosya' / IMPORT JSON 'dosya'
  BEGIN / COMMIT / ROLLBACK
  op: = <> != > < >= <= LIKE
  Exec(sql, params): '?' yer tutuculu guvenli cagri
  Sonuc: TSqlResult (Fields+Rows metin). Hata -> exception.
}

{$mode delphi}

interface

uses
  Classes, SysUtils, Generics.Collections, VDbTable, VDbAst, VDbParser, VDbExecutor, VDbErr, VDbTypes;

const
  // Veritabani dosya uzantisi. CREATE DATABASE satis -> satis.odb
  // (klasor + veritabani.odb yerine TEK dosya).
  VDB_EXT = '.odb';
  // H7: plan onbellegi ust siniri (asilirsa tamamen temizlenir)
  PLAN_CACHE_CAP = 256;

type
  TSqlResult = VDbAst.TSqlResult;

  { F-21: YAVAS SORGU KAYDI.
    Sql  = cumlenin tam metni (kisitli uzunlukta)
    Ms   = olcumlenen sure (ms)
    Rows = donen satir sayisi (yoksa -1)
    Seq  = kayit sirasi (ayni sure icinde siralamayi bozmamak icin) }
  TFSlowRec = class
    Sql: string;
    Ms: Int64;
    Rows: Integer;
    Seq: Integer;
  end;

  TVSql = class
  private
    FT: TVTableDb;
    FSessionId: Cardinal;   // F-41: satir kilidi sahipligi
    FParams: TStrArray;
    FParamIdx: Integer;
    FSetDepth: Boolean;  // ic ice UNION taramasini engeller
    FAutoTx: Boolean;    // coklu cumle = tek transaction (otomatik)
    // --- F-21: YAVAS SORGU TESPITI alanlari ---
    // DIKKAT: bu alanlar sinifin EN BASINDA olmali; FPC ozellik
    // bildirimlerinin kendinden sonra gelen alanlari cozumleyemiyor
    // ("Unknown class field" hatasi).
    // FPC 3.2'de Classes.TList GENERIC'tir; parametresiz yazim derlenmez.
    // TList<T> ogeleri sahiplendigi icin Free hepsini serbest birakir.
    FSlowMs: Int64;        // yavas sorgu esigi (ms), 0 = kapali
    FSlowMax: Integer;     // halka tampon boyutu
    FLastMs: Int64;        // son cumlenin suresi (ms)
    FSlow: TList<TFSlowRec>;
    FSlowNext: Integer;    // halka yazma imleci
    FSlowT0: TDateTime;    // olcum baslangic ani (MSWINDOWS disi)
    FSlowT0Tick: QWord;    // olcum baslangic tik (MSWINDOWS)
    FParser: TVDbParser;   // P-25 (2026-10-17): her sorguda Create/Free yapmamak icin yeniden kullanilan parser
    FExecutor: TVSqlExecutor; // P-25: yeniden kullanilan yurutucu
    // H7 (2026-10-18): PLAN ONBELLEGI. Ayni SELECT metni tekrar geldiginde
    // AST yeniden ayristirilmaz. Yalniz PARAMETRESIZ SELECT'ler saklanir
    // (view-DML AST'yi yerinde degistirir -> yalniz okuma guvenli; parametreli
    // cagride AST degere bagli). DDL calisinca onbellek temizlenir.
    FPlanCache: TDictionary<string, TSqlStmtNode>;
    FPlanHits, FPlanMiss: Int64;
    function Tok(const S: string; var P: Integer; out T: string): Boolean;
    function PeekWord(const S: string; P: Integer): string;
    function TokAt(const S: string; var P: Integer; out T: string;
      out StartPos: Integer): Boolean;
    procedure ExpectWord(const S: string; var P: Integer; const W: string);
    function ParseStrOrNum(const S: string; var P: Integer): string;
    function ParseWhereGroups(const S: string; var P: Integer; const Td: TTableDef;
      const Alias: string = ''): TWhereGroups; overload;
    function ParseWhereGroups(const S: string; var P: Integer; const Tables: array of TTableRef): TWhereGroups; overload;
    function ResolveJoinRef(const Tables: array of TTableRef; const Ref: string): Integer; overload;
    function ResolveJoinRefType(const Tables: array of TTableRef; const Ref: string): Byte;
    function ColTypeOf(const Tn: string): Byte;
    // Tek tablo icin nitelemeli adi (alias.kolon / tablo.kolon) sade
    // kolon adina indirger. Oneki alias veya tablo adiyle eslesmezse
    // oldugu gibi doner (cagiran "kolon yok" hatasi verir).
    function StripQual(const S, Alias, Tbl: string): string;
    // "adi tip" sonrasini bir TColDef'e cevirir; ardindaki PRIMARY/NOT/
    // UNIQUE/DEFAULT/REFERENCES anahtarlarini da yerinde gunceller.
    procedure ParseColDef(var C: TColDef; const TypeName: string);
    // "ON DELETE|UPDATE <aksiyon>" -> kanonik VDB_FK_* degeri
    function ReadFkAction(const S: string; var P: Integer): string;
    function IsAggWord(const W: string): Boolean;
    function ParseSetExpr(const Td: TTableDef; const Sql: string; var P: Integer;
      const ColName: string; out E: TSetExpr): Boolean;
    function AndGroups(const A, B: TWhereGroups): TWhereGroups;
    function CollectParenText(const S: string; var P: Integer): string;
    procedure ParseSelectItem(const S: string; var P: Integer; var Next: string;
      var AggF, AggA, AggO, SCols, SOut: TStrArray;
      var HasAgg: Boolean; var IsCount: Boolean);
    function CompareRowsTbl(const Ra, Rb: array of string; const Td: TTableDef;
      const OCols: array of Integer; const ODesc: array of Boolean): Integer;
    procedure QuickSortIdx(var Idx: array of Integer; const Rows: TStrMatrix;
      const Td: TTableDef; const OCols: array of Integer; const ODesc: array of Boolean);
    procedure QuickSortIntKeys(var Idx: array of Integer;
      var Keys: array of Int64; Desc: Boolean);
    // TEK sayisal ORDER BY kolonu icin onceden hesaplanmis anahtarla hizli yol
    procedure SortRowsBy(var Idx: array of Integer; const Rows: TStrMatrix;
      const Td: TTableDef; const OCols: array of Integer; const ODesc: array of Boolean);
    function TryIndexSelect(const Td: TTableDef; const SCols: array of string;
      const Groups: TWhereGroups;
      const OCols: array of Integer; const ODesc: array of Boolean;
      Lim, Off: Integer; IsCount: Boolean; out Res: TSqlResult): Boolean;
    procedure ExecAggregate(const Td: TTableDef; const SCols, AggF, AggA, AggO: array of string;
      const WGroups: TWhereGroups;
      const GrpCols: array of Integer; const ONames: array of string; const ODesc: array of Boolean;
      Lim, Off: Integer; HasHaving: Boolean; const HGroups: TWhereGroups;
      out Res: TSqlResult);
    // UNION/EXCEPT/INTERSECT icin satir esitligi
    function IndexOfRow(const Hay: TStrMatrix; const Row: TStrArray): Integer;
    // Token kolon adi mi deger mi? (FROM'suz SELECT icin)
    function IsLitTok(const S: string): Boolean;
    // FROM'suz SELECT yolu: tek satir doner
    procedure ExecConstSelect(const S: string; var P: Integer;
      const FirstTok: string; out Res: TSqlResult);
    // SQL metnini "govde" ve "kuyruk (ORDER BY/LIMIT/OFFSET)" olarak ayirir
    procedure SplitSetTail(const S: string; out Head, Tail: string);
    // Kuyrugu birlestirilmis cikti satirlarina uygular
    procedure ApplySetTail(var R: TSqlResult; const Tail: string);
    // SQL metninde (tirnak disinda) ilk kume operatorunu bulur:
    // 'UNION' | 'UNIONALL' | 'EXCEPT' | 'INTERSECT'; bulunamazsa ''.
    function FindSetOp(const S: string; out Pos: Integer): string;
    function DedupRows(const InR: TStrMatrix): TStrMatrix;
    procedure ExecJoin(const Sql: string; var P: Integer; const T1: string;
      const SCols: array of string; HasAgg, IsCount: Boolean; out Res: TSqlResult);
    // --- veritabani seviyesi yardimcilar (CREATE/DROP DATABASE, LIST) ---
    function DbDir: string;              // etkin .odb'nin bulundugu klasor
    function DbParent: string;           // = aktif db'nin bulundugu klasor
    function CleanDbName(const S: string): string;
    function DbFileOf(const Name: string): string;
    function DbLegacyFileOf(const Name: string): string;
    function DbNameOfFile(const Path: string): string;
    function ExecCreateDatabase(const Sql: string; var P: Integer): TSqlResult;
    function ExecDropDatabase(const Sql: string; var P: Integer): TSqlResult;
    function ExecOpenDatabase(const Sql: string; var P: Integer): TSqlResult;
    function ExecCloseDatabase(const Sql: string; var P: Integer): TSqlResult;
    function ExecBackupTo(const Sql: string; var P: Integer): TSqlResult;
    { Sprint 2.8: v2 -> v3 gocu. Kaynak acik veritabanidir. }
    function ExecMigrateTo(const Sql: string; var P: Integer): TSqlResult;
    function ExecMigrateVerify(const Sql: string; var P: Integer): TSqlResult;
    { Tek tirnakli dosya yolu argumanini okur (MIGRATE/BACKUP ortak). }
    function PathArg(const Sql: string; var P: Integer): string;
    procedure ExecVerify(out Res: TSqlResult);
    procedure ExecListDatabases(out Res: TSqlResult);
    // --- F-21: YAVAS SORGU TESPITI ---
    // Bir cumlenin suresi asagi eÅŸildiginde kaydedilir. Log HALKA tampon
    // (cift arabellek): eski kayit dusurulur, bellek sinirsiz buyumez.
    procedure NoteSlow(const Sql: string; Ms: Int64; Rows: Integer);
    procedure ExecShowSlowQueries(out Res: TSqlResult);
    function CountSlow: Integer;
    function GetPlanCacheSize: Integer;   // H7
    // Bu cumle otomatik transaction (batch) icinde calistirilabilir mi?
    function StmtBatchSafe(const S: string): Boolean;
    function ExecRaw(const Sql: string): TSqlResult;
    // goreli sure olcer (VdbTickMs yalniz Windows'ta var; platform
    // bagimsiz olmak icin TDateTime farkindan hesaplanir)
    procedure SlowMarkStart;
    function ElapsedMs: Int64;
    // KR-7: lock alinmis yazma yolu icin ic yardimci (recursive write lock yok)
    function ExecAllInner(const Stmts: TStrArray): TSqlResult;
    // F-35: check if statement is a read-only SELECT
    function IsSelectStatement(const S: string): Boolean;
    // P-CACHE: SQL metninin ilk kelimesi SELECT/WITH/INSERT/UPDATE/DELETE mi?
    // Yalniz plan onbellegi on-eleme icin; kesin karar IsCacheableAst'te.
    function IsCacheableText(const S: string): Boolean;
    // P-CACHE: AST plan onbellegine alinabilir mi? Yalniz DML/SELECT dugumleri
    // (WITH ... INSERT gibi metin sezgisini yalanlayan durumlar burada ayiklanir).
    function IsCacheableAst(Stmt: TSqlStmtNode): Boolean;
    // P-CACHE: onbellek anahtari. '?' JSONB operatoru / yer tutucu ayrimi
    // parametre sayisina bagli oldugundan anahtar onu da tasir.
    function PlanCacheKey(const Sql: string): string;
  public
    constructor Create(AT: TVTableDb);
    // F-21: yavas sorgu kayitlari burada serbest birakilir
    destructor Destroy; override;
    function Exec(const Sql: string): TSqlResult; overload;
    // Parametreli SQL: '?' sirayla, `$1`/`$2` ... konumsal olarak
    // Params[i] ile doldurulur. Tirnak/escape derdi yok
    // (or. soyad O'Brien guvenli gecer).
    function Exec(const Sql: string; const Params: array of string): TSqlResult; overload;
    // SQL betigini ';' ile ayrilmis cumlelere boler (tirnak disinda).
    // 'a;b' gibi bir deger icindeki ';' bolunmez, '' kacisli tirnak sayilir.
    function SplitStatements(const S: string): TStrArray;
    // Cumle listesini sirayla isler; Affected toplamdir.
    // AutoTransaction acikken (varsayilan) ve cumlelerin hepsi batch
    // uyumluysa hepsi TEK transaction icinde calisir: tek fsync (hizli)
    // ve hata halinde hicbiri uygulanmaz (guvenli).
    function ExecAll(const Stmts: TStrArray): TSqlResult; overload;
    function GetAutoTx: Boolean;
    procedure SetAutoTx(const V: Boolean);
    property AutoTransaction: Boolean read GetAutoTx write SetAutoTx;
    // P4b: sema gorunumu icin tablo katmani (VDbDataSet tipli alanlar ve
    // duzenlenebilirlik denetimi buradan okur). Sahiplik degismez.
    property TableDb: TVTableDb read FT;
    // --- F-21: YAVAS SORGU TESPITI ---
    // SlowThresholdMs = 0  -> kayit kapali (varsayilan)
    // SlowThresholdMs > 0  -> suresi bu esigi veya ustu olan cumleler kaydedilir
    // Programatik API: LastElapsedMs / SlowQueryCount / ClearSlow()
    property SlowThresholdMs: Int64 read FSlowMs write FSlowMs;
    property MaxSlowEntries: Integer read FSlowMax write FSlowMax;
    property LastElapsedMs: Int64 read FLastMs;
    property SlowQueryCount: Integer read CountSlow;
    procedure ClearSlow;   // F-21: kayitlari temizle
    // --- H7: PLAN ONBELLEGI ---
    property PlanCacheHits: Int64 read FPlanHits;      // onbellekten calisan SELECT
    property PlanCacheMisses: Int64 read FPlanMiss;    // yeniden ayristirilan SELECT
    property PlanCacheSize: Integer read GetPlanCacheSize;
    procedure ClearPlanCache;                          // sema degisince/zorla temizle
    // --- M9 (2026-10-19): Prometheus text exposition ---
    // Saf metin uretir; HTTP ucu/OpenTelemetry disarida (gomulu sunucu,
    // uygulama veya bir /metrics adaptoru) tarafindan sunulur. Ayni
    // metrikler SHOW STATS ile de okunabilir.
    function GetMetricsText: string;
  end;

implementation

uses
  VDbCore, VDbJson, VDbPlatform, VDbMonitor, VDbTrace, VDbMigrate;   // VDbCore: CREATE/DROP DATABASE icin TVDb

constructor TVSql.Create(AT: TVTableDb);
begin
  inherited Create;
  FT := AT;
  // F-41: oturum kimligi. Ayni anda yasayan TVSql nesneleri icin nesne
  // adresi yeterince benzersizdir; kilitler nesne yok edilirken birakilir.
  FSessionId := Cardinal(PtrUInt(Self));
  if FSessionId = 0 then FSessionId := 1;
  // Boolean alanlar Pascal'da OTOMATIK sifirlanmaz. FSetDepth yanlislikla
  // True kalirsa UNION ayristirmasi tamamen atlanir ve sorgu
  // "anlasilamayan ek: SELECT" ile bozulur. AYNI sebEPLE FAutoTx de
  // acikca atanir (aksi halde otomatik transaction hicbir zaman devreye
  // girmez ve coklu cumle yavas kalir).
  FSetDepth := False;
  FParamIdx := 0;
  FAutoTx := True;
  // F-21: yavas sorgu kaydi â€” varsayilan KAPALI (kirli yazma yok)
  FSlowMs := -1;   // F-21: varsayilan KAPALI (-1); 0 = "her cumle", >0 = esik ms
  FSlowMax := 50;
  FLastMs := 0;
  FSlow := TList<TFSlowRec>.Create;
  FSlowNext := 0;
  FParser := TVDbParser.Create;
  FExecutor := TVSqlExecutor.Create(FT);
  FExecutor.SessionId := FSessionId;
  FPlanCache := TDictionary<string, TSqlStmtNode>.Create;   // H7
  FPlanHits := 0;
  FPlanMiss := 0;
end;

destructor TVSql.Destroy;
var
  pn: TSqlStmtNode;
begin
  // F-41: kapanan oturum kendi satir kilitlerini birakir. Acik batch'e
  // DOKUNULMAZ: batch TVDb basina globaldir ve baska bir TVSql'e ait olabilir.
  FT.UnlockRows(FSessionId);
  // H7: onbellekteki AST'ler sahiplenilir
  for pn in FPlanCache.Values do pn.Free;
  FPlanCache.Free;
  FExecutor.Free;
  FParser.Free;
  FSlow.Free;   // F-21: TList<T> ogeleri sahiplendigi icin hepsi serbest
  inherited;
end;

{ ------------------------------------------------------------
  F-21: YAVAS SORGU TESPITI
  //---------------------------------------------------------- }

procedure TVSql.SlowMarkStart;
// F-21: olcum baslangicini isaretle (platform-nötr tik)
begin
  FSlowT0Tick := VdbTickMs;
end;

function TVSql.ElapsedMs: Int64;
// Platform BAGIMSIZ sure olcer. Monotonik tik: geriye gitmez; yine de
// QWord farkinin sarmamasi icin savunmali.
begin
  if VdbTickMs >= FSlowT0Tick then
    Result := Int64(VdbTickMs - FSlowT0Tick)
  else
    Result := 0;
end;

procedure TVSql.NoteSlow(const Sql: string; Ms: Int64; Rows: Integer);
// Esigi asan cumleyi halka tampona yazar. Tampon doldugunda en eski
// kayit SILINIR (bellek sinirsiz buyumez).
//
// ESIK ANLAMI (varsayilan -1 = KAPALI):
//   -1  -> kayit yok
//    0  -> HER cumle kaydedilir ("hepsini olc" modu; testler ve teşhis
//          icin deterministik — sure olcumu tum donanimlarda 0ms olabilir)
//   >0  -> suresi bu esigi veya ustu olan cumleler kaydedilir
var
  r: TFSlowRec;
  txt: string;
begin
  if FSlowMs < 0 then Exit;
  if (FSlowMs > 0) and (Ms < FSlowMs) then Exit;
  txt := Sql;
  // AÅŸÄ±rÄ± uzun cumleler kÄ±rpÄ±lÄ±r (gÃ¼nlÃ¼ÄŸÃ¼ ÅŸiÅŸirmemek iÃ§in)
  if Length(txt) > 500 then txt := Copy(txt, 1, 500) + ' ...';
  if FSlow.Count < FSlowMax then
  begin
    r := TFSlowRec.Create;
    FSlow.Add(r);
    // DIKKAT: imlec HEP [0, Count-1] araliginda tutulur. Daha once
    // "Next := Count" deniyordu; tampon DOLUNCA (Count = Max) sonraki
    // yazimda FSlow[Count] -> "Argument out of range" hatasidi.
    if FSlowNext >= FSlow.Count then FSlowNext := 0;
  end
  else
  begin
    r := TFSlowRec(FSlow[FSlowNext]);
    Inc(FSlowNext);
    if FSlowNext >= FSlow.Count then FSlowNext := 0;
  end;
  r.Sql := txt;
  r.Ms := Ms;
  r.Rows := Rows;
  r.Seq := 0;
end;

procedure TVSql.ClearSlow;
begin
  FSlow.Clear;   // TList<T> ogeleri de serbest birakir
  FSlowNext := 0;
end;

function TVSql.CountSlow: Integer;
begin
  Result := FSlow.Count;
end;

// --- H7: plan onbellegi API ---
function TVSql.GetPlanCacheSize: Integer;
begin
  Result := FPlanCache.Count;
end;

procedure TVSql.ClearPlanCache;
var
  pn: TSqlStmtNode;
begin
  for pn in FPlanCache.Values do pn.Free;
  FPlanCache.Clear;
end;

// --- M9: Prometheus text exposition (saf metin; ag katmani disarida) ---
function TVSql.GetMetricsText: string;
var
  ms: TVDbMonitorStats;
  hits, misses: Int64;
  usedB, maxB: Integer;
  avgUs: UInt64;
  ratio: Double;
  sl: TStringList;
  v2: Boolean;
  fs: TFileStream;
  dataB: Int64;

  function FileBytes(const P: string): Int64;
  begin
    Result := 0;
    if not FileExists(P) then Exit;
    try
      fs := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
      try
        Result := fs.Size;
      finally
        fs.Free;
      end;
    except
      Result := 0;
    end;
  end;

begin
  GetStats(ms);
  { 2026-10-25 (v3): v3 sayfa motorunda `Kv = nil`. Okuma onbellegi
    sayaclari yoktur; eskiden burada kosulsuz `FT.Kv.GetReadCacheStats`
    cagriliyordu ve v3'te AV olurdu. Artik motor-farkinda: v2 satirlari
    AYNEN korunur, v3'te yalniz gercekten olculen metrikler yazilir. }
  v2 := FT.Kv <> nil;
  hits := 0; misses := 0; usedB := 0; maxB := 0;
  if v2 then
    FT.Kv.GetReadCacheStats(hits, misses, usedB, maxB);
  if ms.CommandCount > 0 then
    avgUs := ms.TotalDurationUs div ms.CommandCount
  else
    avgUs := 0;
  if (hits + misses) > 0 then
    ratio := hits * 100.0 / (hits + misses)
  else
    ratio := 0;
  if v2 then
    dataB := FT.Kv.DataFileSize
  else
    dataB := FileBytes(FT.Backend.FilePath);
  sl := TStringList.Create;
  try
    sl.Add('# HELP vdb_up Database open (1) or closed (0).');
    sl.Add('# TYPE vdb_up gauge');
    sl.Add('vdb_up 1');
    sl.Add('# TYPE vdb_commands_total counter');
    sl.Add('vdb_commands_total ' + IntToStr(ms.CommandCount));
    sl.Add('# TYPE vdb_command_duration_us_total counter');
    sl.Add('vdb_command_duration_us_total ' + IntToStr(ms.TotalDurationUs));
    sl.Add('# TYPE vdb_command_duration_us_max gauge');
    sl.Add('vdb_command_duration_us_max ' + IntToStr(ms.MaxDurationUs));
    sl.Add('# TYPE vdb_command_duration_us_avg gauge');
    sl.Add('vdb_command_duration_us_avg ' + IntToStr(avgUs));
    sl.Add('# TYPE vdb_slow_queries gauge');
    sl.Add('vdb_slow_queries ' + IntToStr(FSlow.Count));
    sl.Add('# TYPE vdb_plan_cache_hits_total counter');
    sl.Add('vdb_plan_cache_hits_total ' + IntToStr(FPlanHits));
    sl.Add('# TYPE vdb_plan_cache_misses_total counter');
    sl.Add('vdb_plan_cache_misses_total ' + IntToStr(FPlanMiss));
    sl.Add('# TYPE vdb_plan_cache_size gauge');
    sl.Add('vdb_plan_cache_size ' + IntToStr(FPlanCache.Count));
    if v2 then
    begin
      sl.Add('# TYPE vdb_read_cache_hits_total counter');
      sl.Add('vdb_read_cache_hits_total ' + IntToStr(hits));
      sl.Add('# TYPE vdb_read_cache_misses_total counter');
      sl.Add('vdb_read_cache_misses_total ' + IntToStr(misses));
      sl.Add('# TYPE vdb_read_cache_blocks_used gauge');
      sl.Add('vdb_read_cache_blocks_used ' + IntToStr(usedB));
      sl.Add('# TYPE vdb_read_cache_blocks_max gauge');
      sl.Add('vdb_read_cache_blocks_max ' + IntToStr(maxB));
      sl.Add('# TYPE vdb_read_cache_hit_ratio gauge');
      sl.Add('vdb_read_cache_hit_ratio ' + FormatFloat('0.0000', ratio / 100.0));
    end
    else
    begin
      { v3: sayfa motorunda olculen gercek degerler. }
      sl.Add('# TYPE vdb_engine_info gauge');
      sl.Add('vdb_engine_info{engine="v3"} 1');
      sl.Add('# TYPE vdb_live_keys gauge');
      sl.Add('vdb_live_keys ' + IntToStr(FT.Backend.Count));
      sl.Add('# TYPE vdb_wal_file_bytes gauge');
      sl.Add('vdb_wal_file_bytes ' + IntToStr(FileBytes(FT.Backend.FilePath + '.wal')));
      sl.Add('# TYPE vdb_idx_file_bytes gauge');
      sl.Add('vdb_idx_file_bytes ' + IntToStr(FileBytes(FT.Backend.FilePath + '.idx')));
    end;
    sl.Add('# TYPE vdb_data_file_bytes gauge');
    sl.Add('vdb_data_file_bytes ' + IntToStr(dataB));
    sl.Add('# TYPE vdb_batch_active gauge');
    if FT.Backend.InBatch then
      sl.Add('vdb_batch_active 1')
    else
      sl.Add('vdb_batch_active 0');
    sl.Add('# TYPE vdb_tables gauge');
    sl.Add('vdb_tables ' + IntToStr(Length(FT.TableNames)));
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

procedure TVSql.ExecShowSlowQueries(out Res: TSqlResult);
var
  i, k, n: Integer;
  ord: TIntArray;
  rs: TFSlowRec;
  best: Integer;
  tmp: Integer;
begin
  SetLength(Res.Fields, 4);
  Res.Fields[0] := 'ms';
  Res.Fields[1] := 'rows';
  Res.Fields[2] := 'seq';
  Res.Fields[3] := 'sql';
  // En yeni once: liste sirasi = yazma sirasi, halka sarmasindan bagimsiz
  // olarak korunur (her kaydin Seq degeri artirilir).
  n := FSlow.Count;
  SetLength(ord, n);
  for i := 0 to n - 1 do ord[i] := i;
  // kucuk bubble (n kucuk, okunabilirlik oncelik)
  for i := 0 to n - 2 do
    for k := 0 to n - 2 - i do
      if TFSlowRec(FSlow[ord[k]]).Ms < TFSlowRec(FSlow[ord[k+1]]).Ms then
      begin
        tmp := ord[k]; ord[k] := ord[k+1]; ord[k+1] := tmp;
      end;
  SetLength(Res.Rows, n);
  for i := 0 to n - 1 do
  begin
    rs := TFSlowRec(FSlow[ord[i]]);
    SetLength(Res.Rows[i], 4);
    Res.Rows[i][0] := IntToStr(rs.Ms);
    Res.Rows[i][1] := IntToStr(rs.Rows);
    Res.Rows[i][2] := IntToStr(i + 1);
    Res.Rows[i][3] := rs.Sql;
  end;
  Res.Affected := n;
  Res.Msg := IntToStr(n) + ' yavas sorgu (esik: ' + IntToStr(FSlowMs) + ' ms)';
end;

function TVSql.GetAutoTx: Boolean;
begin
  Result := FAutoTx;
end;

procedure TVSql.SetAutoTx(const V: Boolean);
begin
  FAutoTx := V;
end;

function TVSql.PeekWord(const S: string; P: Integer): string;
var
  t: string;
  si: Integer;
begin
  si := FParamIdx; // onizleme parametre sayacini ilerletmesin
  if Tok(S, P, t) then Result := UpperCase(t) else Result := '';
  FParamIdx := si;
end;

function TVSql.TokAt(const S: string; var P: Integer; out T: string;
  out StartPos: Integer): Boolean;
// Tok gibi, ama tokenin BASLANGIC konumunu da dondurur. Geri sarma
// (Peek + gerekirse konumu geri almak) icin gerekli: p := StartPos ile konumu
// geri alabiliriz (boyut tahmini gibi kirli hileler yerine).
begin
  while (P <= Length(S)) and (S[P] in [' ', #9, #10, #13, ';']) do Inc(P);
  StartPos := P;
  Result := Tok(S, P, T);
end;

procedure TVSql.ExpectWord(const S: string; var P: Integer; const W: string);
var
  t: string;
begin
  if not Tok(S, P, t) then raise EVDbException.Create(ecSyntaxError, W + ' bekleniyor');
  if UpperCase(t) <> W then raise EVDbException.Create(ecSyntaxError, W + ' bekleniyor, gelen: ' + t);
end;

function TVSql.Tok(const S: string; var P: Integer; out T: string): Boolean;
var
  start: Integer;
  q: Char;
begin
  Result := False; T := '';
  while (P <= Length(S)) and (S[P] in [' ', #9, #10, #13, ';']) do Inc(P);
  if P > Length(S) then Exit;
  // parametre yer tutucu: string disi '?' sirayla Params'tan gelir
  if S[P] = '?' then
  begin
    Inc(P);
    if FParamIdx > High(FParams) then
      raise EVDbException.Create(ecSyntaxError, 'parametre eksik: ? sayisi fazla');
    T := FParams[FParamIdx];
    Inc(FParamIdx);
    Result := True;
    Exit;
  end;
  if S[P] = '''' then
  begin
    q := ''''; Inc(P); start := P;
    T := '';
    while P <= Length(S) do
    begin
      if S[P] = q then
      begin
        if (P < Length(S)) and (S[P + 1] = q) then begin T := T + Copy(S, start, P - start) + ''''; P := P + 2; start := P; Continue; end;
        T := T + Copy(S, start, P - start);
        Inc(P); Result := True; Exit;
      end;
      Inc(P);
    end;
    raise EVDbException.Create(ecSyntaxError, 'kapanmamis string');
  end;
  if S[P] in ['(', ')', ',', '*', '='] then begin T := S[P]; Inc(P); Exit(True); end;
  if S[P] in ['<', '>', '!'] then
  begin
    T := S[P]; Inc(P);
    if (P <= Length(S)) and (S[P] = '=') then begin T := T + '='; Inc(P); end
    else if (T = '<') and (P <= Length(S)) and (S[P] = '>') then begin T := '<>'; Inc(P); end;
    Exit(True);
  end;
  start := P;
  while (P <= Length(S)) and not (S[P] in [' ', #9, #10, #13, ';', '(', ')', ',', '*', '=', '<', '>', '!']) do Inc(P);
  T := Copy(S, start, P - start);
  Result := T <> '';
end;

function TVSql.ResolveJoinRef(const Tables: array of TTableRef; const Ref: string): Integer;
// Nitelikli (a.c / t.c) veya yalin kolon -> birlesik satir konumu.
// Yalin ad iki tabloda da varsa belirsizlik hatasi.
var
  dot, k, m, found: Integer;
  tn, cn: string;
begin
  dot := Pos('.', Ref);
  found := -1;
  for m := 0 to High(Tables) do
  begin
    if dot > 0 then
    begin
      tn := Copy(Ref, 1, dot - 1);
      cn := Copy(Ref, dot + 1, 9999);
      if (UpperCase(tn) <> UpperCase(Tables[m].Name)) and
         ((Tables[m].Alias = '') or (UpperCase(tn) <> UpperCase(Tables[m].Alias))) then
        Continue;
    end
    else
      cn := Ref;
    for k := 0 to High(Tables[m].Cols) do
      if UpperCase(Tables[m].Cols[k].Name) = UpperCase(cn) then
      begin
        if found >= 0 then
          raise EVDbException.Create(ecSyntaxError, 'belirsiz kolon: ' + Ref);
        found := Tables[m].Base + k;
      end;
  end;
  if found < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Ref);
  Result := found;
end;

function TVSql.ResolveJoinRefType(const Tables: array of TTableRef; const Ref: string): Byte;
// ResolveJoinRef ile ayni cozum, ama kolonun VCT_* tipini dondurur.
// WHERE kosuluna tasinir: karsilastirma tip-bilgili olsun.
var
  idx: Integer;
  dot, k, m: Integer;
  tn, cn: string;
begin
  idx := ResolveJoinRef(Tables, Ref);
  Result := VCT_STR;
  dot := Pos('.', Ref);
  cn := Ref;
  if dot > 0 then cn := Copy(Ref, dot + 1, 9999);
  for m := 0 to High(Tables) do
  begin
    if dot > 0 then
    begin
      tn := Copy(Ref, 1, dot - 1);
      if (UpperCase(tn) <> UpperCase(Tables[m].Name)) and
         ((Tables[m].Alias = '') or (UpperCase(tn) <> UpperCase(Tables[m].Alias))) then
        Continue;
    end;
    for k := 0 to High(Tables[m].Cols) do
      if UpperCase(Tables[m].Cols[k].Name) = UpperCase(cn) then
        if Tables[m].Base + k = idx then
          Exit(Tables[m].Cols[k].Ctype);
  end;
end;

function TVSql.ParseWhereGroups(const S: string; var P: Integer; const Td: TTableDef;
  const Alias: string = ''): TWhereGroups;
var
  one: TTableRef;
begin
  one.Name := Td.Name;
  one.Alias := Alias;
  one.Cols := Td.Cols;
  one.Base := 0;
  Result := ParseWhereGroups(S, P, [one]);
end;

function TVSql.ParseWhereGroups(const S: string; var P: Integer; const Tables: array of TTableRef): TWhereGroups;
// WHERE sonrasi kosul listesi: AND > OR oncelikli, parantez destekli.
// Sonuc DNF: OR'lanmis AND gruplari.
var
  col, op, val: string;
  ci: Integer;

  function ColIdx(const C: string): Integer;
  begin
    Result := ResolveJoinRef(Tables, C);
  end;

  function ColType(const C: string): Byte;
  begin
    Result := ResolveJoinRefType(Tables, C);
  end;

  function IsOp(const O: string): Boolean;
  var
    u: string;
  begin
    u := UpperCase(O);
    Result := (u = '=') or (u = '<>') or (u = '!=') or (u = '>') or (u = '<') or
      (u = '>=') or (u = '<=') or (u = 'LIKE') or (u = 'IS');
  end;

  function CondGroups(C: Integer; Ct: Byte; const O, V: string): TWhereGroups;
  begin
    SetLength(Result, 1);
    SetLength(Result[0], 1);
    Result[0][0].Col := C;
    Result[0][0].Ctype := Ct;
    Result[0][0].Op := O;
    Result[0][0].Val := V;
    SetLength(Result[0][0].Vals, 0);
  end;

  function CondList(C: Integer; Ct: Byte; const O, V: string;
    const L: array of string): TWhereGroups;
  // IN / NOT IN / BETWEEN icin: L listenin tamami (BETWEEN'de ust sinir).
  var
    k: Integer;
  begin
    SetLength(Result, 1);
    SetLength(Result[0], 1);
    Result[0][0].Col := C;
    Result[0][0].Ctype := Ct;
    Result[0][0].Op := O;
    Result[0][0].Val := V;
    SetLength(Result[0][0].Vals, Length(L));
    for k := 0 to High(L) do Result[0][0].Vals[k] := L[k];
  end;

  function AndGroups(const A, B: TWhereGroups): TWhereGroups;
  var
    x, y, q, z: Integer;
  begin
    SetLength(Result, Length(A) * Length(B));
    z := 0;
    for x := 0 to High(A) do
      for y := 0 to High(B) do
      begin
        SetLength(Result[z], Length(A[x]) + Length(B[y]));
        for q := 0 to High(A[x]) do
          Result[z][q] := A[x][q];
        for q := 0 to High(B[y]) do
          Result[z][Length(A[x]) + q] := B[y][q];
        Inc(z);
      end;
  end;

  function ParseUnary: TWhereGroups; forward;

  function ParseAnd: TWhereGroups;
  var
    b: TWhereGroups;
    dummy: string;
  begin
    Result := ParseUnary;
    while PeekWord(S, P) = 'AND' do
    begin
      Tok(S, P, dummy);
      b := ParseUnary;
      Result := AndGroups(Result, b);
    end;
  end;

  function ParseOr: TWhereGroups;
  var
    b: TWhereGroups;
    n0, k: Integer;
    dummy: string;
  begin
    Result := ParseAnd;
    while PeekWord(S, P) = 'OR' do
    begin
      Tok(S, P, dummy);
      b := ParseAnd;
      n0 := Length(Result);
      SetLength(Result, n0 + Length(b));
      for k := 0 to High(b) do
        Result[n0 + k] := b[k];
    end;
  end;

  function ParseUnary: TWhereGroups;
  var
    dummy: string;
    ct: Byte;
    neg, outerNeg: Boolean;
    lst: TStrArray;
    k: Integer;
    // NOT'un tum kombinasyonlari: a IN (...) AND NOT b LIKE ... gibi
    // ifadelerde dogru gruplama icin isaret zinciri kurulur.
    // Bir operatorun karsitini dondurur.
    function NegOp(const O: string): string;
    var
      u: string;
    begin
      u := UpperCase(O);
      if u = 'IN' then Result := 'NOTIN'
      else if u = 'NOTIN' then Result := 'IN'
      else if u = 'BETWEEN' then Result := 'NOTBETWEEN'
      else if u = 'NOTBETWEEN' then Result := 'BETWEEN'
      else if u = 'NOTLIKE' then Result := 'LIKE'
      else if u = 'ISNULL' then Result := 'ISNOTNULL'
      else if u = 'ISNOTNULL' then Result := 'ISNULL'
      else if u = '=' then Result := '<>'
      else if (u = '<>') or (u = '!=') then Result := '='
      else if u = '>' then Result := '<='
      else if u = '<' then Result := '>='
      else if u = '>=' then Result := '<'
      else if u = '<=' then Result := '>'
      else if u = 'LIKE' then Result := 'NOTLIKE'
      else
        raise EVDbException.Create(ecSyntaxError, 'bu operatorun NOT''u yok: ' + O);
    end;
    // Gruptaki tek kosulu DEGILTIRIR (NOT).
    //   NOT a=1        -> a<>1              (tek kosul, sorun yok)
    //   NOT (a=1)      -> a<>1              (parantez icinde tek kosul)
    //   NOT (a=1 AND b=2) -> NOT a OR NOT b (AND grubu dagitilabilir)
    //   NOT (a=1 OR b=2)  -> NOT a AND NOT b  ==> DNF ile IFADE EDILEMEZ
    // Kosul temsili "OR'lu AND'ler" (DNF) oldugu icin son durum ifade
    // edilemez. Yanlis sonuc uretmektense kullanicya acik bir hata verip
    // De Morgan ile yeniden yazmasini soyleyelim.
    procedure NegateGroup(var G: TWhereGroups);
    var kk, kk2: Integer;
    begin
      if Length(G) = 0 then Exit;
      if Length(G) = 1 then
      begin
        // 4.4: NOT (A AND B) = NOT A OR NOT B. Tek AND grubunda her
        // kosul icin bir OR dali uretilir; eskiden yalnizca ilk kosul
        // degistirilip digerleri sessizce korunuyordu.
        SetLength(Result, Length(G[0]));
        for kk := 0 to High(G[0]) do
        begin
          SetLength(Result[kk], 1);
          Result[kk][0] := G[0][kk];
          Result[kk][0].Op := NegOp(Result[kk][0].Op);
        end;
        Exit;
      end;
      // 4.4: NOT icinde OR: De Morgan ile acilir.
      // Her G[i] tek kosullu ise (NOT (a=1 OR b=2) -> a<>1 AND b<>2)
      // tek AND grubu olusturulur (DNF ile temsil edilebilir).
      // G[i] cok kosullu ise (NOT (a=1 AND b=2 OR c=3)) -> temsil edilemez.
      for kk := 0 to High(G) do
        if Length(G[kk]) > 1 then
          raise EVDbException.Create(ecUnsupported,
            'NOT (...) icinde cok kosullu OR grubu temsil edilemez (4.4 siniri): ' +
            '"NOT (A AND B OR C)" gibi ifadeler. Basit OR gruplari (tek kosul) ' +
            'icin De Morgan ile yeniden yazin: "NOT (a=1 OR b=2)" -> "a<>1 AND b<>2"');
      // Tum gruplar tek kosullu -> tek AND grubu (DNF).
      SetLength(Result, 1);
      SetLength(Result[0], Length(G));
      for kk2 := 0 to High(G) do
      begin
        Result[0][kk2] := G[kk2][0];
        Result[0][kk2].Op := NegOp(Result[0][kk2].Op);
      end;
    end;
  begin
    // ONCE NOT zinciri:  NOT NOT x = 1
    outerNeg := False;
    while PeekWord(S, P) = 'NOT' do
    begin
      Tok(S, P, dummy);
      outerNeg := not outerNeg;
    end;
    if PeekWord(S, P) = '(' then
    begin
      Tok(S, P, dummy); // (
      Result := ParseOr;
      ExpectWord(S, P, ')');
      if outerNeg then NegateGroup(Result);
      Exit;
    end;
    if not Tok(S, P, col) then raise EVDbException.Create(ecColumnNotFound, 'kosulda kolon bekleniyor');
    ci := ColIdx(col);
    ct := ColType(col);
    if not Tok(S, P, op) then raise EVDbException.Create(ecSyntaxError, 'operator bekleniyor');
    // NOT LIKE / NOT IN / NOT BETWEEN
    neg := False;
    if SameText(op, 'NOT') then
    begin
      neg := True;
      if not Tok(S, P, op) then raise EVDbException.Create(ecSyntaxError, 'NOT sonrasi operator bekleniyor');
    end;
    if SameText(op, 'IN') then
    begin
      // IN (v1, v2, ...)  /  IN (SELECT ...) -> alt sorgu desteklenmiyor
      ExpectWord(S, P, '(');
      SetLength(lst, 0);
      if PeekWord(S, P) = 'SELECT' then
        raise EVDbException.Create(ecUnsupported, 'IN (SELECT ...) desteklenmiyor; alt sorgu yok');
      while True do
      begin
        if not Tok(S, P, dummy) then raise EVDbException.Create(ecSyntaxError, ') bekleniyor');
        if dummy = ')' then Break;
        if dummy = ',' then Continue;
        // Tok zaten tirnakli string'i cozup diger token'i oldugu gibi
        // donduruyor -> dogrudan deger olarak kullanilir. Boylece '?'
        // parametreleri iki kez sayilmaz.
        if SameText(dummy, 'NULL') then dummy := '';
        SetLength(lst, Length(lst) + 1);
        lst[High(lst)] := dummy;
      end;
      if Length(lst) = 0 then raise EVDbException.Create(ecSyntaxError, 'IN listesi bos');
      if neg then Result := CondList(ci, ct, 'NOTIN', '', lst)
      else Result := CondList(ci, ct, 'IN', '', lst);
      if outerNeg then NegateGroup(Result);
      Exit;
    end;
    if SameText(op, 'BETWEEN') then
    begin
      // BETWEEN alt AND ust
      val := ParseStrOrNum(S, P);
      if SameText(val, 'NULL') then val := '';
      ExpectWord(S, P, 'AND');
      k := 0;
      SetLength(lst, 1);
      lst[0] := ParseStrOrNum(S, P);
      if SameText(lst[0], 'NULL') then lst[0] := '';
      if neg then Result := CondList(ci, ct, 'NOTBETWEEN', val, lst)
      else Result := CondList(ci, ct, 'BETWEEN', val, lst);
      if outerNeg then NegateGroup(Result);
      Exit;
    end;
    if not IsOp(op) then
      raise EVDbException.CreateFmt(ecSyntaxError, 'bilinmeyen operator: %s (desteklenen: = <> != < > <= >= LIKE NOT LIKE IN NOT IN BETWEEN NOT BETWEEN IS [NOT] NULL)', [op]);
    if SameText(op, 'IS') then
    begin
      // IS NULL / IS NOT NULL  ->  'ISNULL' / 'ISNOTNULL'
      neg := PeekWord(S, P) = 'NOT';
      if neg then
      begin
        Tok(S, P, dummy);
        ExpectWord(S, P, 'NULL');
        Result := CondGroups(ci, ct, 'ISNOTNULL', '');
      end
      else
      begin
        ExpectWord(S, P, 'NULL');
        Result := CondGroups(ci, ct, 'ISNULL', '');
      end;
      if outerNeg then NegateGroup(Result);
      Exit;
    end;
    val := ParseStrOrNum(S, P);
    // WHERE icinde TIRNAKSIZ NULL literal de NULL'dir. Normalize
    // edilmezse deger 'NULL' diye 4 harfli metin olarak kalir ve
    // "e <> NULL" gibi kosullarda yanlis eslesme uretir.
    if SameText(val, 'NULL') then val := '';
    if neg then
    begin
      // NOT <operator> ...  ->  karsiti operator
      Result := CondGroups(ci, ct, NegOp(op), val);
    end
    else
      Result := CondGroups(ci, ct, op, val);
    if outerNeg then NegateGroup(Result);
  end;

begin
  Result := ParseOr;
end;

function TVSql.ParseStrOrNum(const S: string; var P: Integer): string;
var
  save: Integer;
  t: string;
begin
  // tirnakli string Tok tarafindan cozuluyor ama sayi/identifier da gelebilir
  save := P;
  while (save <= Length(S)) and (S[save] in [' ', #9]) do Inc(save);
  if (save <= Length(S)) and (S[save] = '''') then
  begin
    Tok(S, P, t);
    Result := t; // tirnak ici ham deger
  end
  else if not Tok(S, P, t) then
    raise EVDbException.Create(ecSyntaxError, 'deger bekleniyor')
  else
    Result := t;
  // sayi mi kontrol yok, string olarak birak (tablo katmani parse eder)
end;

function TVSql.ColTypeOf(const Tn: string): Byte;
// Kural tek yerde: VDbTable.VDbTypeFromName (ALTER COLUMN da kullanir).
begin
  Result := VDbTypeFromName(Tn);
end;

function TVSql.StripQual(const S, Alias, Tbl: string): string;
var
  d: Integer;
  pre: string;
begin
  Result := S;
  d := Pos('.', S);
  if d <= 1 then Exit;
  pre := Copy(S, 1, d - 1);
  if (Alias <> '') and (UpperCase(pre) = UpperCase(Alias)) then
    Result := Copy(S, d + 1, MaxInt)
  else if (Tbl <> '') and (UpperCase(pre) = UpperCase(Tbl)) then
    Result := Copy(S, d + 1, MaxInt);
end;

function TVSql.IsLitTok(const S: string): Boolean;
// Token bir KOLON adi degil bir DEGER mi? (FROM'suz SELECT tespiti icin)
// Tirnakli string, sayi, NULL, TRUE/FALSE -> deger; duger her sey kolon adi.
var
  d: Double;
begin
  if S = '' then Exit(False);
  if S[1] = '''' then Exit(True);
  if SameText(S, 'NULL') then Exit(True);
  if SameText(S, 'TRUE') then Exit(True);
  if SameText(S, 'FALSE') then Exit(True);
  Result := TryStrToFloat(S, d);
end;

procedure TVSql.ExecConstSelect(const S: string; var P: Integer;
  const FirstTok: string; out Res: TSqlResult);
// FROM'suz SELECT: SELECT 1 / SELECT 'abc' AS x / SELECT NULL, 2.5
// Tek satir doner; alan adlari degerin kendisi (veya AS alias'i).
var
  vals, names: TStrArray;
  w2, nm, dummy: string;
  n: Integer;
  procedure AddVal(const V: string);
  begin
    SetLength(vals, Length(vals) + 1); vals[High(vals)] := V;
    SetLength(names, Length(names) + 1); names[High(names)] := V;
  end;
begin
  SetLength(vals, 0);
  SetLength(names, 0);
  AddVal(FirstTok);
  while True do
  begin
    w2 := PeekWord(S, P);
    if w2 = 'AS' then
    begin
      Tok(S, P, dummy);
      if not Tok(S, P, nm) then raise EVDbException.Create(ecInvalidName, 'AS sonrasi alias adi yok');
      names[High(names)] := nm;
      if PeekWord(S, P) = ',' then
      begin
        Tok(S, P, dummy);
        if not Tok(S, P, w2) then raise EVDbException.Create(ecSyntaxError, 'deger bekleniyor');
        AddVal(w2);
        Continue;
      end;
      Break;
    end;
    if w2 = ',' then
    begin
      Tok(S, P, dummy);
      if not Tok(S, P, w2) then raise EVDbException.Create(ecSyntaxError, 'deger bekleniyor');
      AddVal(w2);
      Continue;
    end;
    if w2 = 'FROM' then
      raise EVDbException.Create(ecSyntaxError, 'FROM''suz SELECT icinde kolon kullanilamaz: ' +
        FirstTok);
    Break;
  end;
  if PeekWord(S, P) <> '' then
    raise EVDbException.Create(ecSyntaxError, 'anlasilamayan ek: ' + PeekWord(S, P));
  SetLength(Res.Fields, Length(names));
  for n := 0 to High(names) do Res.Fields[n] := names[n];
  SetLength(Res.Rows, 1);
  SetLength(Res.Rows[0], Length(vals));
  for n := 0 to High(vals) do Res.Rows[0][n] := vals[n];
  Res.Affected := 1;
  Res.Msg := 'OK';
end;

function TVSql.IndexOfRow(const Hay: TStrMatrix; const Row: TStrArray): Integer;
// Satirlari tam esitlikle arar (UNION/EXCEPT/INTERSECT icin).
var
  i, j: Integer;
begin
  for i := 0 to High(Hay) do
  begin
    if Length(Hay[i]) <> Length(Row) then Continue;
    j := 0;
    while (j < Length(Row)) and (Hay[i][j] = Row[j]) do Inc(j);
    if j = Length(Row) then Exit(i);
  end;
  Result := -1;
end;

procedure TVSql.SplitSetTail(const S: string; out Head, Tail: string);
// Kume islemli bir sorgunun SONUNDAKI "ORDER BY ... [LIMIT n] [OFFSET m]"
// kismini ayirir. Tirnak disinda ve parantez disinda ilk ORDER aranir.
// SQL'de ORDER BY kume isleminden SONRA gelir ve birlesmis sonuca
// uygulanir; sadece sag tabloya uygulamak yanlis sonuc verir.
var
  i, k, n, depth, m2: Integer;
  inStr: Boolean;
  c: Char;
  w: string;
  isOrder: Boolean;
begin
  Head := S;
  Tail := '';
  n := Length(S);
  inStr := False;
  depth := 0;
  i := 1;
  while i <= n do
  begin
    c := S[i];
    if c = '''' then
    begin
      if inStr and (i < n) and (S[i + 1] = '''') then
      begin Inc(i, 2); Continue; end;
      inStr := not inStr;
      Inc(i);
      Continue;
    end;
    if inStr then begin Inc(i); Continue; end;
    if c = '(' then begin Inc(depth); Inc(i); Continue; end;
    if c = ')' then begin Dec(depth); Inc(i); Continue; end;
    if (depth = 0) and (c in ['A'..'Z', 'a'..'z']) or (c = '_') then
    begin
      // kelime basligini kontrol et (onceki karakter harf/rakam olmamali)
      if (i = 1) or not (S[i - 1] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      begin
        k := i;
        while (k <= n) and ((S[k] in ['A'..'Z', 'a'..'z']) or (S[k] in ['0'..'9']) or
          (S[k] = '_')) do Inc(k);
        w := UpperCase(Copy(S, i, k - i));
        // ORDER'dan sonra bosluklar gelip "BY" kelimesi olmali
        isOrder := False;
        if w = 'ORDER' then
        begin
          m2 := k;
          while (m2 <= n) and (S[m2] in [' ', #9]) do Inc(m2);
          if (Copy(S, m2, 2) = 'BY') and
             ((m2 + 2 > n) or not (S[m2 + 2] in ['A'..'Z', 'a'..'z', '0'..'9', '_'])) then
            isOrder := True;
        end;
        if isOrder then
        begin
          Head := Copy(S, 1, i - 1);
          Tail := Copy(S, i, MaxInt);
          Exit;
        end;
        i := k;
        Continue;
      end;
    end;
    Inc(i);
  end;
end;

procedure TVSql.ApplySetTail(var R: TSqlResult; const Tail: string);
// ORDER BY / LIMIT / OFFSET'i BIRLESMIS cikti satirlarina uygular.
// SQL'de bunlar kume isleminden SONRA gelir ve birlestirilmis sonuca
// uygulanir; yalnizca sag tabloya uygulanirsa sonuc yanlis (fazla) satir
// doner. Alanlar cikti adi (Result.Fields) ya da 1-based pozisyon olabilir.
// Karsilastirma: once sayisal denenir, degilse byte sirasi.
var
  p, i, j, k, t2, c, n: Integer;
  wrd, s: string;
  cols: TStrArray;    // cikti sirasindaki kolonlar (metin)
  desc: TStrArray;    // '1' = DESC
  lim2, off2: Integer;
  src, dst: TStrMatrix;
  af, bf: Double;
  num: Boolean;
  ci, key: Integer;
  tp: TStrArray;

  function JoinFields(const A: TStrArray): string;
  var i: Integer;
  begin
    Result := '';
    for i := 0 to High(A) do
    begin
      if i > 0 then Result := Result + ', ';
      Result := Result + A[i];
    end;
  end;

  function CmpCells(const A, B: TStrArray; const Cix: Integer): Integer;
  begin
    if (Cix < 0) or (Cix >= Length(A)) or (Cix >= Length(B)) then Exit(0);
    if A[Cix] = B[Cix] then Exit(0);
    num := (A[Cix] <> '') and (B[Cix] <> '') and
      TryStrToFloat(A[Cix], af) and TryStrToFloat(B[Cix], bf);
    if num then
    begin
      if af < bf then Exit(-1) else if af > bf then Exit(1) else Exit(0);
    end;
    if A[Cix] < B[Cix] then Exit(-1) else Exit(1);
  end;

begin
  p := 1;
  if PeekWord(Tail, p) <> 'ORDER' then Exit;
  Tok(Tail, p, wrd);   // ORDER
  Tok(Tail, p, wrd);   // BY
  SetLength(cols, 0);
  SetLength(desc, 0);
  lim2 := -1; off2 := 0;
  while True do
  begin
    if not Tok(Tail, p, wrd) then Break;
    if SameText(wrd, 'LIMIT') then
    begin
      if Tok(Tail, p, wrd) then lim2 := StrToIntDef(wrd, -1);
      Continue;
    end;
    if SameText(wrd, 'OFFSET') then
    begin
      if Tok(Tail, p, wrd) then off2 := StrToIntDef(wrd, 0);
      Continue;
    end;
    ci := -1;
    for j := 0 to High(R.Fields) do
      if SameText(R.Fields[j], wrd) then begin ci := j; Break; end;
    if ci < 0 then
    begin
      n := StrToIntDef(wrd, 0);
      if (n >= 1) and (n <= Length(R.Fields)) then ci := n - 1;
    end;
    if ci < 0 then
      raise EVDbException.CreateFmt(ecSyntaxError, 'ORDER BY: cikti alani yok: %s (alanlar: %s)',
        [wrd, JoinFields(R.Fields)]);
    SetLength(cols, Length(cols) + 1); cols[High(cols)] := IntToStr(ci);
    s := '0';
    if PeekWord(Tail, p) = 'DESC' then begin Tok(Tail, p, wrd); s := '1'; end
    else if PeekWord(Tail, p) = 'ASC' then Tok(Tail, p, wrd);
    SetLength(desc, Length(desc) + 1); desc[High(desc)] := s;
    if PeekWord(Tail, p) = ',' then
    begin Tok(Tail, p, wrd); Continue; end;
    if (PeekWord(Tail, p) = 'LIMIT') or (PeekWord(Tail, p) = 'OFFSET') then Continue;
    if PeekWord(Tail, p) <> '' then
      raise EVDbException.Create(ecSyntaxError, 'ORDER BY sonrasi anlasilamayan ek: ' + PeekWord(Tail, p));
    Break;
  end;
  // Coklu anahtar: anahtarlari TERSTEN uygulayan kararli (stable)
  // selection sort. Kume islemi sonrasi satir sayisi kucuk oldugu icin
  // yeterli ve esitlikte ORIJINAL SIRAYI korur.
  if Length(cols) > 0 then
  begin
    for k := Length(cols) - 1 downto 0 do
    begin
      src := R.Rows;
      SetLength(dst, Length(src));
      for i := 0 to High(src) do dst[i] := src[i];
      key := StrToIntDef(cols[k], 0);
      for i := 1 to High(dst) do
      begin
        tp := dst[i];
        j := i - 1;
        while j >= 0 do
        begin
          c := CmpCells(dst[j], tp, key);
          if (desc[k] = '0') and (c <= 0) then Break;
          if (desc[k] = '1') and (c >= 0) then Break;
          dst[j + 1] := dst[j];
          Dec(j);
        end;
        dst[j + 1] := tp;
      end;
      R.Rows := dst;
    end;
  end;
  // OFFSET / LIMIT
  if (off2 > 0) or (lim2 >= 0) then
  begin
    SetLength(dst, 0);
    for i := 0 to High(R.Rows) do
    begin
      if i < off2 then Continue;
      if (lim2 >= 0) and (Length(dst) >= lim2) then Break;
      SetLength(dst, Length(dst) + 1);
      dst[High(dst)] := R.Rows[i];
    end;
    R.Rows := dst;
  end;
end;

function RowEncodeKey(const R: TStrArray): string;
var
  j: Integer;
  sb: string;
begin
  sb := '';
  for j := 0 to High(R) do
    sb := sb + IntToStr(Length(R[j])) + ':' + R[j] + #30;
  Result := sb;
end;

function TVSql.DedupRows(const InR: TStrMatrix): TStrMatrix;
// Ayni satirlari teke indirger, SIRAYI KORUR (SELECT DISTINCT). O(N) hash seti ile hizli.
var
  i, n: Integer;
  outR: TStrMatrix;
  seen: TDictionary<string, Byte>;
  k: string;
begin
  SetLength(outR, Length(InR));
  seen := TDictionary<string, Byte>.Create;
  try
    n := 0;
    for i := 0 to High(InR) do
    begin
      k := RowEncodeKey(InR[i]);
      if not seen.ContainsKey(k) then
      begin
        seen.Add(k, 0);
        outR[n] := InR[i];
        Inc(n);
      end;
    end;
    SetLength(outR, n);
    Result := outR;
  finally
    seen.Free;
  end;
end;

function TVSql.FindSetOp(const S: string; out Pos: Integer): string;
// Tirnak disinda, tam kelime olarak ilk kume operatorunu bulur.
// 'UNION ALL' iki kelime oldugu icin 'UNIONALL' olarak doner.
// Doner: 'UNION' | 'UNIONALL' | 'EXCEPT' | 'INTERSECT' ya da '' (yok).
var
  i, k, n, j0: Integer;
  up, w, w2: string;
  inStr, prevAlnum: Boolean;
  c: Char;
  m2: Integer;
begin
  Pos := 0;
  Result := '';
  n := Length(S);
  inStr := False;
  prevAlnum := False;
  i := 1;
  while i <= n do
  begin
    c := S[i];
    if c = '''' then
    begin
      if inStr and (i < n) and (S[i + 1] = '''') then
      begin
        Inc(i, 2);
        prevAlnum := True;
        Continue;
      end;
      inStr := not inStr;
      prevAlnum := True;
      Inc(i);
      Continue;
    end;
    if inStr then begin Inc(i); Continue; end;
    if ((c in ['A'..'Z', 'a'..'z']) or (c = '_')) and not prevAlnum then
    begin
      k := i;
      while (k <= n) and (((S[k] in ['A'..'Z', 'a'..'z']) or (S[k] = '_') or
        (S[k] in ['0'..'9']))) do Inc(k);
      w := UpperCase(Copy(S, i, k - i));
      if (w = 'UNION') or (w = 'EXCEPT') or (w = 'INTERSECT') then
      begin
        if w = 'UNION' then
        begin
          m2 := k;
          while (m2 <= n) and (S[m2] in [' ', #9]) do Inc(m2);
          w2 := UpperCase(Copy(S, m2, 3));
          if w2 = 'ALL' then
          begin
            Pos := i;
            Result := 'UNIONALL';
            Exit;
          end;
        end;
        Pos := i;
        Result := w;
        Exit;
      end;
      i := k;
      prevAlnum := True;
      Continue;
    end;
    prevAlnum := (c in ['A'..'Z', 'a'..'z']) or (c in ['0'..'9']) or (c = '_');
    Inc(i);
  end;
end;

function TVSql.ReadFkAction(const S: string; var P: Integer): string;
// ON DELETE|UPDATE sonrasi gelen aksiyonu okur:
//   CASCADE | RESTRICT | SET NULL | SET DEFAULT | NO ACTION
var
  t: string;
begin
  if not Tok(S, P, t) then
    raise EVDbException.Create(ecSyntaxError, 'ON sonrasi aksiyon bekleniyor ' +
      '(CASCADE | SET NULL | SET DEFAULT | RESTRICT)');
  if SameText(t, 'SET') then
  begin
    if not Tok(S, P, t) then raise EVDbException.Create(ecSyntaxError, 'SET sonrasi NULL/DEFAULT bekleniyor');
    if SameText(t, 'NULL') then Result := VDB_FK_SETNULL
    else if SameText(t, 'DEFAULT') then Result := VDB_FK_SETDEFAULT
    else
      raise EVDbException.Create(ecSyntaxError, 'SET sonrasi NULL ya da DEFAULT bekleniyor: ' + t);
    Exit;
  end;
  if SameText(t, 'NO') then
  begin
    if not Tok(S, P, t) then raise EVDbException.Create(ecSyntaxError, 'NO sonrasi ACTION bekleniyor');
    if not SameText(t, 'ACTION') then
      raise EVDbException.Create(ecSyntaxError, 'NO sonrasi ACTION bekleniyor: ' + t);
    Result := VDB_FK_RESTRICT;
    Exit;
  end;
  // CASCADE / RESTRICT; gecersizse VDbFkAction hata verir
  Result := VDbFkAction(t);
end;

procedure TVSql.ParseColDef(var C: TColDef; const TypeName: string);
// Tip atanir, varsayilanlar sifirlanir. C.Name CREATE'in tarafinda
// normalize edilerek atanir (CREATE ve ALTER ayni yolu kullanir).
// NOT: PRIMARY KEY / NOT NULL / UNIQUE / DEFAULT / REFERENCES anahtarlari
// CREATE tarafta islenir (CREATE TABLE dongusu paylasir).
begin
  C.Name := VDbNorm(C.Name);
  C.Ctype := ColTypeOf(TypeName);
  C.NotNull := False;
  C.Unique := False;
  C.HasDef := False;
  C.Def := '';
  // M4: VECTOR(n) boyutu. Gecersiz boyut sessizce TEXT'e dusmesin.
  C.VecDim := VDbVectorDimFromName(TypeName);
  if (Copy(UpperCase(Trim(TypeName)), 1, 6) = 'VECTOR') and
     (C.VecDim = 0) and (not SameText(Trim(TypeName), 'VECTOR')) then
    raise EVDbException.Create(ecTypeMismatch,
      'gecersiz VECTOR tipi (VECTOR(n), 1..255): ' + TypeName);
end;

function TVSql.CompareRowsTbl(const Ra, Rb: array of string; const Td: TTableDef;
  const OCols: array of Integer; const ODesc: array of Boolean): Integer;
// Satir karsilastirmasi (ORDER BY).
//
// ONCEDEN her kosulda `VDbParseFloat` cagriliyordu. Bu hem YAVAS
// (karsilastirma basina 2x kayan nokta ayristirma) hem DE HATALIydi:
// Double 2^53'ten buyuk tam sayilari temsil edemedigi icin buyuk
// INTEGER degerleri yanlis siralanabiliyordu.
//
// SIMDI kolon TIPINE gore:
//   VCT_INT / VCT_BOOL -> Int64 ile TAM KARSILASTIRMA (birebir dogru)
//   VCT_FLOAT         -> Double
//   VCT_STR / DATE    -> CompareStr
var
  k, c: Integer;
  ia, ib: Int64;
  fa, fb: Double;
  na, nb: Boolean;
begin
  Result := 0;
  for k := 0 to High(OCols) do
  begin
    c := OCols[k];
    if (c < 0) or (c > High(Ra)) or (c > High(Rb)) then
      Continue;
    { Td her zaman gercek sema olmayabilir (JOIN'de sentetik tablo defi
      kullanilir). Kolon tipi BILINMIYORSA atlama; CompareStr'e dus.
      (Oncekipi kodda "Tanim yok -> Continue" vardi; bu, tip bilgisi
      olmayan JOIN sirasinda TUM karsilastirmalari 0 yapiyor ve siralama
      bozuluyordu.) }
    if (c > High(Td.Cols)) then
    begin
      Result := CompareStr(Ra[c], Rb[c]);
      if ODesc[k] then Result := -Result;
      if Result <> 0 then Exit;
      Continue;
    end;
    if (Td.Cols[c].Ctype = VCT_INT) or (Td.Cols[c].Ctype = VCT_BOOL) then
    begin
      // NULL en basta (bos string); iki NULL esit
      if (Ra[c] = '') and (Rb[c] = '') then
        Result := 0
      else if Ra[c] = '' then Result := -1
      else if Rb[c] = '' then Result := 1
      else if VDbParseInt(Ra[c], ia) and VDbParseInt(Rb[c], ib) then
      begin
        if ia < ib then Result := -1
        else if ia > ib then Result := 1
        else Result := 0;
      end
      else
        Result := CompareStr(Ra[c], Rb[c]);
    end
    else if Td.Cols[c].Ctype = VCT_FLOAT then
    begin
      na := VDbParseFloat(Ra[c], fa);
      nb := VDbParseFloat(Rb[c], fb);
      if na and nb then
      begin
        if fa < fb then Result := -1
        else if fa > fb then Result := 1
        else Result := 0;
      end
      else
        Result := CompareStr(Ra[c], Rb[c]);
    end
    else
      Result := CompareStr(Ra[c], Rb[c]);
    if ODesc[k] then Result := -Result;
    if Result <> 0 then Exit;
  end;
end;

procedure TVSql.QuickSortIntKeys(var Idx: array of Integer;
  var Keys: array of Int64; Desc: Boolean);
// TEK sayisal ORDER BY kolonu icin ONCEDEN HESAPLANMIS anahtarla siralama.
//
// Gerekce: genel yol her karsilastirmada metni sayiya ceviriyordu.
// 100.000 satirlik `ORDER BY id` 4,2 saniye suruyordu. Anahtarlar bir kez
// hesaplanip (O(n) ayristirma) ic dongude sadece tam sayi karsilastirmasi
// yapilir -> siralama ~6 kat hizlanir. NULL en basta (Low(Int64)).
//
// ONEMLI: Keys[i] daima Idx[i]'nin anahtari olacak sekilde IKISI BIRDEN
// takas edilir. Anahtar dizisi kopyalanip birakilirsa Idx siralanirken
// anahtarlar eski sirada kaldigi icin sonuc KARBASIK cikar.
var
  StackL, StackH: array of Integer;
  SP, L, H, i, j, tmp: Integer;
  piv, c, tmpk: Int64;
begin
  if Length(Idx) <= 1 then Exit;
  SetLength(StackL, Length(Idx));
  SetLength(StackH, Length(Idx));
  SP := 0;
  StackL[0] := 0; StackH[0] := High(Idx); Inc(SP);
  while SP > 0 do
  begin
    Dec(SP);
    L := StackL[SP]; H := StackH[SP];
    while L < H do
    begin
      piv := Keys[(L + H) div 2];
      i := L; j := H;
      repeat
        // AZALAN sirada buyuk degerler one gider; ARTAN sirada kucukler.
        while True do
        begin
          c := Keys[i];
          if Desc then begin if c > piv then Inc(i) else Break; end
          else begin if c < piv then Inc(i) else Break; end;
        end;
        while True do
        begin
          c := Keys[j];
          if Desc then begin if c < piv then Dec(j) else Break; end
          else begin if c > piv then Dec(j) else Break; end;
        end;
        if i <= j then
        begin
          tmp := Idx[i]; Idx[i] := Idx[j]; Idx[j] := tmp;
          tmpk := Keys[i]; Keys[i] := Keys[j]; Keys[j] := tmpk;
          Inc(i); Dec(j);
        end;
      until i > j;
      if L < j then
      begin
        StackL[SP] := L; StackH[SP] := j; Inc(SP);
      end;
      L := i;
    end;
  end;
end;

procedure TVSql.SortRowsBy(var Idx: array of Integer; const Rows: TStrMatrix;
  const Td: TTableDef; const OCols: array of Integer; const ODesc: array of Boolean);
// ORDER BY yonlendiricisi:
//   * TEK sayisal kolon -> onceden hesaplanmis Int64 anahtarlarla hizli yol
//   * aksi halem        -> tip-bilgili genel yol
var
  n, i, c: Integer;
  keys: array of Int64;
  v: Int64;
  numeric: Boolean;
begin
  if Length(Idx) = 0 then Exit;   // bos sonuc: hicbir sey siralanmaz
  if Length(OCols) = 0 then Exit;
  numeric := (Length(OCols) = 1) and (OCols[0] >= 0) and
             (OCols[0] < Length(Td.Cols)) and
             (OCols[0] < Length(Rows[Idx[0]])) and
             ((Td.Cols[OCols[0]].Ctype = VCT_INT) or
              (Td.Cols[OCols[0]].Ctype = VCT_BOOL));
  if not numeric then
  begin
    QuickSortIdx(Idx, Rows, Td, OCols, ODesc);
    Exit;
  end;
  c := OCols[0];
  SetLength(keys, Length(Idx));
  for i := 0 to High(Idx) do
  begin
    n := Idx[i];
    if (n < 0) or (n > High(Rows)) or (c > High(Rows[n])) or (Rows[n][c] = '') then
      keys[i] := Low(Int64)          // NULL en basta
    else if VDbParseInt(Rows[n][c], v) then
      keys[i] := v
    else
      keys[i] := Low(Int64);
  end;
  QuickSortIntKeys(Idx, keys, ODesc[0]);
end;

procedure TVSql.QuickSortIdx(var Idx: array of Integer; const Rows: TStrMatrix;
  const Td: TTableDef; const OCols: array of Integer; const ODesc: array of Boolean);
var
  StackL, StackH: array of Integer;
  SP, L, H, i, j, piv, tmp: Integer;
begin
  if Length(Idx) <= 1 then Exit;
  SetLength(StackL, Length(Idx));
  SetLength(StackH, Length(Idx));
  SP := 0;
  StackL[SP] := 0; StackH[SP] := High(Idx); Inc(SP);
  while SP > 0 do
  begin
    Dec(SP);
    L := StackL[SP]; H := StackH[SP];
    while L < H do
    begin
      piv := Idx[(L + H) div 2];
      i := L; j := H;
      repeat
        while CompareRowsTbl(Rows[Idx[i]], Rows[piv], Td, OCols, ODesc) < 0 do Inc(i);
        while CompareRowsTbl(Rows[Idx[j]], Rows[piv], Td, OCols, ODesc) > 0 do Dec(j);
        if i <= j then
        begin
          tmp := Idx[i]; Idx[i] := Idx[j]; Idx[j] := tmp;
          Inc(i); Dec(j);
        end;
      until i > j;
      if L < j then
      begin
        StackL[SP] := L; StackH[SP] := j; Inc(SP);
      end;
      L := i;
    end;
  end;
end;

function TVSql.TryIndexSelect(const Td: TTableDef; const SCols: array of string;
  const Groups: TWhereGroups;
  const OCols: array of Integer; const ODesc: array of Boolean;
  Lim, Off: Integer; IsCount: Boolean; out Res: TSqlResult): Boolean;
// Index varsa full-scan yapmadan cevaplar. True = cevaplandi.
// Hizli dilim tek sartli (tek grup/tek kosul) WHERE'de gecerli;
// cok sartli OR'lu filtreler dilim icinde VDbMatchGroups ile elenir.
var
  e: TIdxEntries;
  useOrder, desc: Boolean;
  lo, hi, k, q, m, n, z, need: Integer;
  takeAll: Boolean;
  seek: TWhereCond;
  hasSeek: Boolean;
  ct: Byte;
  l2, h2: Integer;
  rv: TStrArray;
  proj: array of Integer;
  outR: TStrMatrix;
  mPks: TStrArray;
  mRows: TStrMatrix;
  sPks: TStrArray;
  sRows: TStrMatrix;
  rowOf: TDictionary<string, Integer>;
  sidx: array of Integer;
  ord: array of Integer;
  mCap, mCount, outCap, outCount: Integer;
begin
  Result := False;
  Res.Affected := 0; Res.Msg := '';
  SetLength(Res.Fields, 0); SetLength(Res.Rows, 0);
  useOrder := False;
  lo := 0; hi := 0;
  // Batch acikken indeks KULLANILIR.
  // ONCEDEN burada tam tarama kullaniliyordu (gerekce: "index commit
  // edilmemis satirlari icermiyor"). Oysa bekleyen indeks eklemeleri
  // TryGetMemIndex icinde TEK seferde uygulanir (tembel siralama), yani
  // indeks batch icinde de COMMIT edilmemis satirlari gorur; sIkisi de
  // transaction ici okumanin dogru sonucunu verir. ROLLBACK'te
  // TVTableDb.AbortBatch indeksleri veriden yeniden kurar. Boylece
  // BEGIN...END icinde indeksli SELECT yavaslamaz.
  // 0) En sik sorgu: WHERE pk = <deger>. PK zaten hash anahtari oldugu
  // icin ReadRow O(1) -> index/tarama gerekmez. (PK disi ikinci index
  // kullanmiyorsa.)
  if (Length(OCols) = 0) and (Length(Groups) = 1) and (Length(Groups[0]) = 1) and
     (Td.PkIndex >= 0) and (Groups[0][0].Col = Td.PkIndex) and
     (Groups[0][0].Op = '=') then
  begin
    if not FT.ReadRow(Td.Name, Groups[0][0].Val, rv) then Exit(True); // eslesme yok
    if Length(SCols) = 0 then
    begin
      SetLength(Res.Fields, Length(Td.Cols));
      for m := 0 to High(Td.Cols) do Res.Fields[m] := Td.Cols[m].Name;
      SetLength(Res.Rows, 1);
      Res.Rows[0] := Copy(rv, 0, Length(rv));
    end
    else
    begin
      SetLength(Res.Fields, Length(SCols));
      SetLength(proj, Length(SCols));
      for m := 0 to High(SCols) do
      begin
        Res.Fields[m] := SCols[m];
        proj[m] := -1;
        for q := 0 to High(Td.Cols) do
          if UpperCase(Td.Cols[q].Name) = UpperCase(SCols[m]) then
          begin proj[m] := q; Break; end;
        if proj[m] < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + SCols[m]);
      end;
      SetLength(Res.Rows, 1);
      SetLength(Res.Rows[0], Length(proj));
      for m := 0 to High(proj) do Res.Rows[0][m] := rv[proj[m]];
    end;
    Result := True;
    Exit;
  end;
  // 1) ORDER BY tek kolon ve indexli mi?
  if (not IsCount) and (Length(OCols) = 1) and
     FT.TryGetMemIndex(Td.TableId, OCols[0], e) then
  begin
    useOrder := True;
    desc := ODesc[0];
    lo := 0; hi := Length(e);
    // ayni kolonda dilimlenebilir WHERE varsa dilimi daralt
    // (tek gruplu sartlar; cok gruplu OR'da tam dilim guvenli degil -> atla)
    if Length(Groups) = 1 then
      for k := 0 to High(Groups[0]) do
        if Groups[0][k].Col = OCols[0] then
        begin
          if (Groups[0][k].Op = '=') or (Groups[0][k].Op = '>') or (Groups[0][k].Op = '>=') or
             (Groups[0][k].Op = '<') or (Groups[0][k].Op = '<=') then
            if VDbIdxRange(e, Td.Cols[OCols[0]].Ctype, Groups[0][k].Op, Groups[0][k].Val, lo, hi) then
              Break;
        end;
  end
  else
  begin
    // 2) WHERE dilimi: TEK grup (AND'li kosullar) icinde indeksli ve
    //    dilimlenebilir kosul varsa onun dilimini kullan.
    //    ONCEDE yalniz "tek grup + TEK kosul" kabul ediliyordu; BETWEEN
    //    iki kosul uretir ("x>=a" ve "x<=b") ve bu yuzden her zaman
    //    TAM TARAMAYA dushuyordu. Artik ayni indeksli kolona dusen
    //    TUM kosullar KESISIM (intersection) ile birlestirilir.
    //    Dilim bir UST KUMEDIR: sonucta yine VDbMatchGroups ile elenir,
    //    bu yuzden eksik dilimlemek dogrulugu bozmaz.
    if Length(Groups) <> 1 then Exit(False);
    hasSeek := False;
    lo := 0; hi := MaxInt;
    for k := 0 to High(Groups[0]) do
    begin
      if (Groups[0][k].Col < 0) or (Groups[0][k].Col > High(Td.Cols)) then Continue;
      if not FT.TryGetMemIndex(Td.TableId, Groups[0][k].Col, e) then Continue;
      ct := Td.Cols[Groups[0][k].Col].Ctype;
      seek := Groups[0][k];
      if SameText(seek.Op, 'BETWEEN') then
      begin
        // alt + ust sinirini birlestir
        if VDbIdxRange(e, ct, '>=', seek.Val, l2, h2) then
        begin
          if l2 > lo then lo := l2;
          if h2 < hi then hi := h2;
        end;
        if (Length(seek.Vals) > 0) and
           VDbIdxRange(e, ct, '<=', seek.Vals[0], l2, h2) then
        begin
          if l2 > lo then lo := l2;
          if h2 < hi then hi := h2;
        end;
        hasSeek := True;
      end
      else if SameText(seek.Op, 'IN') then
      begin
        // IN: TUM degerleri kapsayan TEK aralik (UST KUME; sonra elenir).
        //
        // ONCEDEN her deger icin '>=' ve '<=' araligi ARTI ARDA uygulaniyordu;
        // lo/hi her adimda EZILDIgi icin dilim yalnizca TEK degerin
        // araligina kaliyordu ("IN (0,1,2)" sadece 0'lari getiriyordu).
        // Dogru kurgu:
        //   alt sinir = EN KUCUK degerin '>=' baslangici  (min)
        //   ust sinir = EN BUYUK degerin '<=' bitisi      (MAKS!)
        lo := MaxInt;
        hi := 0;
        for q := 0 to High(seek.Vals) do
        begin
          if VDbIdxRange(e, ct, '>=', seek.Vals[q], l2, h2) then
            if l2 < lo then lo := l2;
          if VDbIdxRange(e, ct, '<=', seek.Vals[q], l2, h2) then
            if h2 > hi then hi := h2;
        end;
        if (lo = MaxInt) or (hi = 0) then Continue;
        hasSeek := True;
      end
      else if (seek.Op = '=') or (seek.Op = '>') or (seek.Op = '>=') or
              (seek.Op = '<') or (seek.Op = '<=') then
      begin
        if not VDbIdxRange(e, ct, seek.Op, seek.Val, l2, h2) then Continue;
        if l2 > lo then lo := l2;
        if h2 < hi then hi := h2;
        hasSeek := True;
      end;
    end;
    if not hasSeek then Exit(False);
    if lo > hi then lo := hi;   // bos dilim
    // COUNT tek dilimlenebilir sartliysa satir okumadan say
    if IsCount then
    begin
      SetLength(Res.Fields, 1); Res.Fields[0] := 'COUNT';
      SetLength(Res.Rows, 1); SetLength(Res.Rows[0], 1);
      Res.Rows[0][0] := IntToStr(hi - lo);
      Result := True;
      Exit;
    end;
  end;
  // projeksiyon kolonlarini coz
  if IsCount then
  begin
    SetLength(Res.Fields, 1); Res.Fields[0] := 'COUNT';
  end
  else if Length(SCols) = 0 then
  begin
    SetLength(Res.Fields, Length(Td.Cols));
    for m := 0 to High(Td.Cols) do Res.Fields[m] := Td.Cols[m].Name;
  end
  else
  begin
    SetLength(Res.Fields, Length(SCols));
    for m := 0 to High(SCols) do Res.Fields[m] := SCols[m];
  end;
  SetLength(proj, Length(Res.Fields));
  if not IsCount then
    for m := 0 to High(Res.Fields) do
    begin
      proj[m] := -1;
      for q := 0 to High(Td.Cols) do
        if UpperCase(Td.Cols[q].Name) = UpperCase(Res.Fields[m]) then
        begin proj[m] := q; Break; end;
      if proj[m] < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + Res.Fields[m]);
    end;
  if IsCount then
  begin
    // cok sartli COUNT: dilim icini say
    q := 0;
    if useOrder then
    begin
      if desc then
        for k := hi - 1 downto lo do
        begin
          if not FT.ReadRow(Td.Name, e[k].Pk, rv) then Continue;
          if not VDbMatchGroups(rv, Groups) then Continue;
          Inc(q);
        end
      else
        for k := lo to hi - 1 do
        begin
          if not FT.ReadRow(Td.Name, e[k].Pk, rv) then Continue;
          if not VDbMatchGroups(rv, Groups) then Continue;
          Inc(q);
        end;
    end
    else
      for k := lo to hi - 1 do
      begin
        if not FT.ReadRow(Td.Name, e[k].Pk, rv) then Continue;
        if not VDbMatchGroups(rv, Groups) then Continue;
        Inc(q);
      end;
    SetLength(Res.Rows, 1); SetLength(Res.Rows[0], 1);
    Res.Rows[0][0] := IntToStr(q);
    Result := True;
    Exit;
  end;
  SetLength(outR, 0);
  // --- Satirlari topla -------------------------------------------------
  // Iki strateji var:
  //  a) KUCUK dilim  : her indeks girdisi icin TEK ReadRow (rastgele seek).
  //                   (dilim daraltma en degerli oldugu yerde hizli)
  //  b) BUYUK dilim : tabloyu BIR KEZ sirali oku (ScanRows), sonra indeks
  //                   sirasina gore yeniden diz. 100.000 satirlik tam
  //                   siralamada (a) 5,4 saniye, (b) 0,7 saniye -> 7 kat.
  SetLength(mPks, 0); SetLength(mRows, 0);
  // Kucuk LIMIT varsa ( orn. "ORDER BY n LIMIT 10") satirlari toplamaya
  // gerek yok: indeks sirasi bellidir, istenen kadar satir okunup durulur.
  // ONCEDEN limit uygulanana kadar tum dilim okunuyordu (100.000 satirlik
  // tabloda 10 satir isteyen sorgu 953 ms suruyordu; simdi ~1 ms).
  takeAll := True;
  need := Lim + Off;
  if useOrder and (Lim >= 0) and (need < 512) then takeAll := False;
  if useOrder and ((hi - lo) >= 2048) and takeAll then
  begin
    // (b) sirali okuma + indeks sirasi
    FT.ScanRows(Td.Name, sPks, sRows);
    rowOf := TDictionary<string, Integer>.Create;
    for q := 0 to High(sPks) do
      if not rowOf.ContainsKey(sPks[q]) then
        rowOf.AddOrSetValue(sPks[q], q);
    SetLength(sidx, hi - lo);
    n := 0;
    if desc then
    begin
      for z := hi - 1 downto lo do
        if rowOf.TryGetValue(e[z].Pk, m) then
        begin
          sidx[n] := m; Inc(n);
        end;
    end
    else
    begin
      for z := lo to hi - 1 do
        if rowOf.TryGetValue(e[z].Pk, m) then
        begin
          sidx[n] := m; Inc(n);
        end;
    end;
    SetLength(sidx, n);
    // filtre asagida ortak yolda; burada sadece sirali satirlari al
    SetLength(ord, 0);
    for z := 0 to High(sidx) do
    begin
      m := sidx[z];
      if not VDbMatchGroups(sRows[m], Groups) then Continue;
      SetLength(ord, Length(ord) + 1);
      ord[High(ord)] := m;
    end;
    for z := 0 to High(ord) do
    begin
      m := ord[z];
      SetLength(mPks, Length(mPks) + 1); SetLength(mRows, Length(mRows) + 1);
      mPks[High(mPks)] := sPks[m]; mRows[High(mRows)] := sRows[m];
    end;
    rowOf.Free;
  end
  else if useOrder and desc then
  begin
    mCap := hi - lo;
    if mCap < 16 then mCap := 16;
    SetLength(mPks, mCap);
    SetLength(mRows, mCap);
    mCount := 0;
    for k := hi - 1 downto lo do
    begin
      if not FT.ReadRow(Td.Name, e[k].Pk, rv) then Continue;
      if not VDbMatchGroups(rv, Groups) then Continue;
      if mCount >= Length(mPks) then
      begin
        SetLength(mPks, Length(mPks) * 2);
        SetLength(mRows, Length(mRows) * 2);
      end;
      mPks[mCount] := e[k].Pk; mRows[mCount] := rv;
      Inc(mCount);
      if (not takeAll) and (mCount >= need) then Break;
    end;
    SetLength(mPks, mCount);
    SetLength(mRows, mCount);
  end
  else
  begin
    mCap := hi - lo;
    if mCap < 16 then mCap := 16;
    SetLength(mPks, mCap);
    SetLength(mRows, mCap);
    mCount := 0;
    for k := lo to hi - 1 do
    begin
      if not FT.ReadRow(Td.Name, e[k].Pk, rv) then Continue;
      if not VDbMatchGroups(rv, Groups) then Continue;
      if mCount >= Length(mPks) then
      begin
        SetLength(mPks, Length(mPks) * 2);
        SetLength(mRows, Length(mRows) * 2);
      end;
      mPks[mCount] := e[k].Pk; mRows[mCount] := rv;
      Inc(mCount);
      if (not takeAll) and (mCount >= need) then Break;
    end;
    SetLength(mPks, mCount);
    SetLength(mRows, mCount);
  end;
  // --- Siralama --------------------------------------------------------
  if (not useOrder) and (Length(OCols) > 0) then
  begin
    // index dilimi bulundu ama sira baska kolonda: topla, sirala
    SetLength(sidx, Length(mPks));
    for k := 0 to High(sidx) do sidx[k] := k;
    SortRowsBy(sidx, mRows, Td, OCols, ODesc);
  end
  else
  begin
    // zaten indeks sirasinda (veya sira yok): kimlik sirasi
    SetLength(sidx, Length(mPks));
    for k := 0 to High(sidx) do sidx[k] := k;
  end;
  // --- OFFSET / LIMIT + projeksiyon -----------------------------------
  outCap := Length(sidx);
  if (Lim >= 0) and (Lim < outCap) then outCap := Lim;
  SetLength(outR, outCap);
  outCount := 0;
  for k := 0 to High(sidx) do
  begin
    if Off > 0 then begin Dec(Off); Continue; end;
    if (Lim >= 0) and (outCount >= Lim) then Break;
    m := sidx[k];
    if outCount >= Length(outR) then
      SetLength(outR, Length(outR) * 2 + 8);
    if Length(SCols) = 0 then
      outR[outCount] := Copy(mRows[m], 0, Length(mRows[m]))
    else
    begin
      SetLength(outR[outCount], Length(proj));
      for q := 0 to High(proj) do
        outR[outCount][q] := mRows[m][proj[q]];
    end;
    Inc(outCount);
  end;
  SetLength(outR, outCount);
  Res.Rows := outR;
  Result := True;
end;

function TVSql.CollectParenText(const S: string; var P: Integer): string;
// Giriste '(' tuketilmis; eslesen ')' dahil tuketilir, ici ham dondurulur.
// Tirnak ici parantezler atlanir.
var
  depth, start: Integer;
begin
  depth := 1; start := P;
  while P <= Length(S) do
  begin
    if S[P] = '''' then
    begin
      Inc(P);
      while P <= Length(S) do
      begin
        if S[P] = '''' then
        begin
          if (P < Length(S)) and (S[P + 1] = '''') then Inc(P, 2)
          else begin Inc(P); Break; end;
        end
        else Inc(P);
      end;
      Continue;
    end;
    if S[P] = '(' then Inc(depth)
    else if S[P] = ')' then
    begin
      Dec(depth);
      if depth = 0 then
      begin
        Result := Copy(S, start, P - start);
        Inc(P);
        Exit;
      end;
    end;
    Inc(P);
  end;
  raise EVDbException.Create(ecSyntaxError, 'kapanmamis parantez');
end;

function TVSql.AndGroups(const A, B: TWhereGroups): TWhereGroups;
var
  x, y, q, z: Integer;
begin
  SetLength(Result, Length(A) * Length(B));
  z := 0;
  for x := 0 to High(A) do
    for y := 0 to High(B) do
    begin
      SetLength(Result[z], Length(A[x]) + Length(B[y]));
      for q := 0 to High(A[x]) do
        Result[z][q] := A[x][q];
      for q := 0 to High(B[y]) do
        Result[z][Length(A[x]) + q] := B[y][q];
      Inc(z);
    end;
end;

// "UPDATE ... SET kolon = deger" degerini ayristirir.
//
//   kolon = 5                -> Duz deger        (Kind=0)
//   kolon = 'abc'            -> Duz deger
//   kolon = n + 1            -> Kolon islemi     (Kind=1)
//   kolon = n * 2.5
//   kolon = n + b            -> Kolon islemi     (Kind=2)
//   kolon = f + 1            -> Kolon islemi     (Kind=1, FLOAT)
//
// Desteklenen islemler: + - * / %
// Sol taraf KULLANILAN KOLON olmak zorundadir; boylece "5 - 3" gibi
// yazimlar kastedilen anlam degil, net bir hata verir.
// Basarisiz olursa False doner ve cagiran hata firlatir.
function TVSql.ParseSetExpr(const Td: TTableDef; const Sql: string; var P: Integer;
  const ColName: string; out E: TSetExpr): Boolean;
var
  ci, p0, sv: Integer;
  t1, t2, wt2: string;
  opc: Char;

  function ColIdxOf(const Nm: string): Integer;
  var q: Integer;
  begin
    Result := -1;
    for q := 0 to High(Td.Cols) do
      if VDbNorm(Td.Cols[q].Name) = VDbNorm(Nm) then Exit(q);
  end;

begin
  Result := False;
  E.Kind := 0;
  E.ColA := -1;
  E.ColB := -1;
  E.Op := #0;
  E.Lit := '';
  // sol taraf gercekten bir kolon olmali (kullanici hedef kolonu yazdi)
  ci := ColIdxOf(ColName);
  if ci < 0 then Exit;
  { E.ColA ifade icin kullanilacak SOL KOLON; duz degerde (Kind=0)
    atanmayabilir. Atama hedefi zaten SetCols icinde. }
  p0 := P;
  sv := FParamIdx;
  if not Tok(Sql, P, t1) then Exit;
  wt2 := PeekWord(Sql, P);
  if (Length(wt2) <> 1) or
     ((wt2[1] <> '+') and (wt2[1] <> '-') and (wt2[1] <> '*') and
      (wt2[1] <> '/') and (wt2[1] <> '%')) then
  begin
    // islem yok -> duz deger.
    // ONEMLI: t1'i geri alirken parametre sayacini da geri almak ZORUNDA
    // ('?' degeri sayilmis olabilir); ama ParseStrOrNum'dan sonra sayaci
    // ASLA geri almamak gerekir, yoksa sonraki '?' yanlis parametreyi okur.
    P := p0;
    FParamIdx := sv;
    E.Lit := ParseStrOrNum(Sql, P);
    E.Kind := 0;
    Exit(True);
  end;
  // Ifadenin SOL tarafi DAHA BIR KOLON olmak zorundadir.
  // SQL semantigi: "SET b = n * 2" -> b := n * 2  (b degil, n kullanilir!)
  ci := ColIdxOf(t1);
  if ci < 0 then Exit;   // "5 - 3" gibi yazim: anlamli degil -> hata
  E.ColA := ci;
  opc := wt2[1];
  Tok(Sql, P, t2);              // islemci
  if not Tok(Sql, P, t2) then Exit;
  // sag taraf sayisal bir KOLON mu, yoksa sabit mi?
  ci := -1;
  if (t2 <> '') and (t2[1] <> '''') then
    ci := ColIdxOf(t2);
  if (ci >= 0) and ((Td.Cols[ci].Ctype = VCT_INT) or
                    (Td.Cols[ci].Ctype = VCT_FLOAT) or
                    (Td.Cols[ci].Ctype = VCT_BOOL)) then
  begin
    E.ColB := ci;
    E.Kind := 2;
  end
  else
  begin
    E.ColB := -1;
    E.Lit := t2;
    if (Length(E.Lit) >= 2) and (E.Lit[1] = '''') and
       (E.Lit[Length(E.Lit)] = '''') then
      E.Lit := Copy(E.Lit, 2, Length(E.Lit) - 2);
    E.Kind := 1;
  end;
  E.Op := opc;
  Result := True;
end;

function TVSql.IsAggWord(const W: string): Boolean;
var
  u: string;
begin
  u := UpperCase(W);
  Result := (u = 'COUNT') or (u = 'SUM') or (u = 'AVG') or (u = 'MIN') or (u = 'MAX');
end;

procedure TVSql.ParseSelectItem(const S: string; var P: Integer; var Next: string;
  var AggF, AggA, AggO, SCols, SOut: TStrArray; var HasAgg: Boolean; var IsCount: Boolean);
// Giriste Next = aday (kolon ya da fonksiyon adi).
// Cikista Next = ayirac (',' ya da FROM...) ve listeler guncel.
// SOut: SCols ile ayni uzunlukta CIKTI ADLARI. Kolon alias'i
// (SELECT a AS x  /  SELECT a x) burada yakalanir; alias verilmediyse
// SOut[k] = SCols[k].
var
  name, arg, onm, t, al, u: string;
begin
  name := Next;
  if IsAggWord(name) and (PeekWord(S, P) = '(') then
  begin
    Tok(S, P, t); // (
    if not Tok(S, P, arg) then raise EVDbException.Create(ecSyntaxError, 'aggregate argumani yok');
    ExpectWord(S, P, ')');
    if (UpperCase(name) = 'COUNT') and (arg = '*') and (PeekWord(S, P) <> 'AS') then
      IsCount := True // yalin COUNT(*): hizli yol (tek basina + grupsuzsa)
    else
    begin
      HasAgg := True;
      SetLength(AggF, Length(AggF) + 1);
      SetLength(AggA, Length(AggA) + 1);
      SetLength(AggO, Length(AggO) + 1);
      AggF[High(AggF)] := UpperCase(name);
      AggA[High(AggA)] := arg;
      if PeekWord(S, P) = 'AS' then
      begin Tok(S, P, t); Tok(S, P, t); onm := t; end
      else
        onm := UpperCase(name) + '(' + arg + ')';
      AggO[High(AggO)] := onm;
    end;
    if not Tok(S, P, Next) then
      raise EVDbException.Create(ecSyntaxError, 'FROM bekleniyor');
    Exit;
  end;
  SetLength(SCols, Length(SCols) + 1);
  SCols[High(SCols)] := name;
  SetLength(SOut, Length(SOut) + 1);
  SOut[High(SOut)] := name;          // varsayilan cikti adi = kolon adi
  if not Tok(S, P, Next) then
    raise EVDbException.Create(ecSyntaxError, 'FROM bekleniyor');
  if UpperCase(Next) = 'AS' then
  begin
    // acik alias:  SELECT a AS x
    if not Tok(S, P, t) then raise EVDbException.Create(ecInvalidName, 'alias adi yok');
    SOut[High(SOut)] := t;
    if not Tok(S, P, Next) then
      raise EVDbException.Create(ecSyntaxError, 'FROM bekleniyor');
  end
  else
  begin
    // alesiz alias:  SELECT a x  -- yalniz Next ayirac/anahtar kelimesi
    // DEGILSE. Boylece "SELECT a FROM t" bozulmaz.
    u := UpperCase(Next);
    if (u <> '') and (u <> ',') and (u <> 'FROM') and (u <> 'JOIN') and
       (u <> 'INNER') and (u <> 'LEFT') and (u <> 'ON') and (u <> 'WHERE') and
       (u <> 'GROUP') and (u <> 'ORDER') and (u <> 'LIMIT') and
       (u <> 'OFFSET') and (u <> 'RIGHT') and (u <> 'FULL') and
       (u <> 'CROSS') and (u <> 'HAVING') and (u <> 'AS') then
    begin
      al := Next;
      SOut[High(SOut)] := al;
      if not Tok(S, P, Next) then
        raise EVDbException.Create(ecSyntaxError, 'FROM bekleniyor');
    end;
  end;
end;

procedure TVSql.ExecAggregate(const Td: TTableDef; const SCols, AggF, AggA, AggO: array of string;
  const WGroups: TWhereGroups;
  const GrpCols: array of Integer; const ONames: array of string; const ODesc: array of Boolean;
  Lim, Off: Integer; HasHaving: Boolean; const HGroups: TWhereGroups;
  out Res: TSqlResult);
// Res doldurulur (hata = exception).
var
  pks: TStrArray;
  rows, frows: TStrMatrix;
  argIdx: array of Integer;
  i, k, m, q, j: Integer;
  outR: TStrMatrix;
  oidx: array of Integer;
  odir: array of Boolean;
  members: array of Integer;
  gidx: array of Integer;
  sgrp: array of Integer;

  function HavOK(const Out1: TStrArray; const H: TWhereGroups): Boolean;
  // HAVING kosulunu cikti satirina uygular. 'RAW' isaretli kosullarda
  // Val metin karsilastirmasi yapar (gruplama kolonu = deger).
  var
    g, c: Integer;
    ok: Boolean;
    cc: TWhereCond;
    val1: string;
  begin
    for g := 0 to High(H) do
    begin
      ok := True;
      for c := 0 to High(H[g]) do
      begin
        if (H[g][c].Col < 0) or (H[g][c].Col >= Length(Out1)) then
        begin ok := False; Break; end;
        val1 := Out1[H[g][c].Col];
        if SameText(H[g][c].Op, 'RAW') then
        begin
          cc := H[g][c];
          cc.Op := '=';      // "= deger" anlamina gelir
          cc.Val := H[g][c].Val;
          if not VDbMatchCond(val1, cc) then begin ok := False; Break; end;
        end
        else
          if not VDbMatchCond(val1, H[g][c]) then begin ok := False; Break; end;
      end;
      if ok then Exit(True);
    end;
    Result := False;
  end;

  function AggOf(const Members: array of Integer; F, A: Integer): string;
  var
    r, s: Integer;
    fv, sum: Double;
    iv: Int64;
    cnt: Integer;
    intOnly: Boolean;
    best: string;
    has: Boolean;
  begin
    if AggF[F] = 'COUNT' then
    begin
      if AggA[F] = '*' then
        Exit(IntToStr(Length(Members)));
      cnt := 0;
      for r := 0 to High(Members) do
        if frows[Members[r]][A] <> '' then Inc(cnt);
      Exit(IntToStr(cnt));
    end;
    if AggF[F] = 'MIN' then
    begin
      has := False; best := '';
      for r := 0 to High(Members) do
      begin
        s := Members[r];
        if frows[s][A] = '' then Continue;
        if not has then begin best := frows[s][A]; has := True; end
        else if VDbIdxCmp(frows[s][A], best, Td.Cols[A].Ctype) < 0 then
          best := frows[s][A];
      end;
      Exit(best);
    end;
    if AggF[F] = 'MAX' then
    begin
      has := False; best := '';
      for r := 0 to High(Members) do
      begin
        s := Members[r];
        if frows[s][A] = '' then Continue;
        if not has then begin best := frows[s][A]; has := True; end
        else if VDbIdxCmp(frows[s][A], best, Td.Cols[A].Ctype) > 0 then
          best := frows[s][A];
      end;
      Exit(best);
    end;
    // SUM / AVG
    sum := 0; cnt := 0; intOnly := True;
    for r := 0 to High(Members) do
    begin
      s := Members[r];
      if frows[s][A] = '' then Continue;
      if VDbParseInt(frows[s][A], iv) then
        sum := sum + iv
      else if VDbParseFloat(frows[s][A], fv) then
      begin sum := sum + fv; intOnly := False; end
      else
        Continue;
      Inc(cnt);
    end;
    if cnt = 0 then Exit('');
    if AggF[F] = 'SUM' then
    begin
      if intOnly then Exit(IntToStr(Trunc(sum)));
      Exit(VDbFloatToStr(sum));
    end;
    // AVG
    if intOnly and (Trunc(sum) = sum) and (Round(sum) mod cnt = 0) then
      Exit(IntToStr(Round(sum) div cnt));
    Exit(VDbFloatToStr(sum / cnt));
  end;

  function GroupCmp(A, B: Integer): Integer; // frows indexleri
  var
    g: Integer;
  begin
    for g := 0 to High(GrpCols) do
    begin
      Result := VDbIdxCmp(frows[A][GrpCols[g]], frows[B][GrpCols[g]], Td.Cols[GrpCols[g]].Ctype);
      if Result <> 0 then Exit;
    end;
    Result := 0;
  end;

  procedure SortGroupIdx(var G: array of Integer);
    procedure Sort(L, H: Integer);
    var
      a, b, piv, tp: Integer;
    begin
      a := L; b := H; piv := G[(L + H) div 2];
      repeat
        while GroupCmp(G[a], piv) < 0 do Inc(a);
        while GroupCmp(G[b], piv) > 0 do Dec(b);
        if a <= b then
        begin tp := G[a]; G[a] := G[b]; G[b] := tp; Inc(a); Dec(b); end;
      until a > b;
      if L < b then Sort(L, b);
      if a < H then Sort(a, H);
    end;
  begin
    if Length(G) > 1 then Sort(0, High(G));
  end;

  procedure SortOutRows(var R: TStrMatrix);
  // insertion sort: grup/cikti kumesi kucuk oldugu icin yeterli
  var
    a, b, c: Integer;
    d: Integer;
    tp: TStrArray;
  begin
    if Length(R) < 2 then Exit;
    for a := 1 to High(R) do
    begin
      tp := R[a]; b := a - 1;
      while b >= 0 do
      begin
        d := 0;
        for c := 0 to High(oidx) do
        begin
          d := VDbIdxCmp(R[b][oidx[c]], tp[oidx[c]], VCT_FLOAT);
          if odir[c] then d := -d;
          if d <> 0 then Break;
        end;
        if d <= 0 then Break;
        R[b + 1] := R[b];
        Dec(b);
      end;
      R[b + 1] := tp;
    end;
  end;
begin
  Res.Affected := 0; Res.Msg := '';
  SetLength(Res.Fields, 0); SetLength(Res.Rows, 0);
  // arguman kolonlarini coz
  SetLength(argIdx, Length(AggF));
  for i := 0 to High(AggF) do
  begin
    if AggA[i] = '*' then
    begin
      if AggF[i] <> 'COUNT' then
        raise EVDbException.Create(ecUnsupported, 'yildiz sadece COUNT ile olur');
      argIdx[i] := -1;
    end
    else
    begin
      argIdx[i] := -1;
      for k := 0 to High(Td.Cols) do
        if UpperCase(Td.Cols[k].Name) = UpperCase(AggA[i]) then
        begin argIdx[i] := k; Break; end;
      if argIdx[i] < 0 then raise EVDbException.Create(ecColumnNotFound, 'kolon yok: ' + AggA[i]);
    end;
  end;
  // duz kolon kurali: her duz kolon grup kolonlarindan biri olmali
  SetLength(sgrp, Length(SCols));
  for i := 0 to High(SCols) do
  begin
    if Length(GrpCols) = 0 then
      raise EVDbException.Create(ecSyntaxError, 'aggregate yaninda duz kolon olmaz (GROUP BY yok)');
    sgrp[i] := -1;
    for k := 0 to High(GrpCols) do
      if UpperCase(SCols[i]) = UpperCase(Td.Cols[GrpCols[k]].Name) then
      begin sgrp[i] := k; Break; end;
    if sgrp[i] < 0 then
      raise EVDbException.Create(ecSyntaxError, 'duz kolon GROUP BY kolonu olmali: ' + SCols[i]);
  end;
  if (Length(AggF) = 0) and (Length(GrpCols) > 0) then
  begin
    // SELECT GROUP BY = distinct listesi: alanlar grupla birebir olmali
    if Length(SCols) <> Length(GrpCols) then
      raise EVDbException.Create(ecSyntaxError, 'GROUP BY alan sayisi uymadi (v1)');
  end;
  // WHERE filtresi
  FT.ScanRows(Td.Name, pks, rows);
  SetLength(frows, 0);
  for i := 0 to High(pks) do
  begin
    if not VDbMatchGroups(rows[i], WGroups) then Continue;
    SetLength(frows, Length(frows) + 1);
    frows[High(frows)] := Copy(rows[i], 0, Length(rows[i]));
  end;
  // cikti alanlari
  for i := 0 to High(SCols) do
  begin
    SetLength(Res.Fields, Length(Res.Fields) + 1);
    Res.Fields[High(Res.Fields)] := SCols[i];
  end;
  for i := 0 to High(AggO) do
  begin
    SetLength(Res.Fields, Length(Res.Fields) + 1);
    Res.Fields[High(Res.Fields)] := AggO[i];
  end;
  SetLength(outR, 0);
  if Length(GrpCols) = 0 then
  begin
    // tek grup
    SetLength(members, Length(frows));
    for i := 0 to High(members) do members[i] := i;
    SetLength(outR, 1);
    SetLength(outR[0], Length(AggF));
    for i := 0 to High(AggF) do
      outR[0][i] := AggOf(members, i, argIdx[i]);
  end
  else
  begin
    // cok kolonlu grup: sirala + super
    SetLength(gidx, Length(frows));
    for i := 0 to High(gidx) do gidx[i] := i;
    SortGroupIdx(gidx);
    i := 0;
    while i < Length(gidx) do
    begin
      SetLength(members, 0);
      j := i;
      while (j < Length(gidx)) and (GroupCmp(gidx[j], gidx[i]) = 0) do
      begin
        SetLength(members, Length(members) + 1);
        members[High(members)] := gidx[j];
        Inc(j);
      end;
      SetLength(outR, Length(outR) + 1);
      SetLength(outR[High(outR)], Length(SCols) + Length(AggF));
      for k := 0 to High(SCols) do
        outR[High(outR)][k] := frows[gidx[i]][GrpCols[sgrp[k]]];
      for k := 0 to High(AggF) do
        outR[High(outR)][Length(SCols) + k] := AggOf(members, k, argIdx[k]);
      i := j;
    end;
  end;
  // HAVING: aggregate CIKTISI uzerinde filtre. Kosullar ExecRaw tarafindan
  // cikti konumuna cevrildi; 'RAW' isaretli olanlarda Val metin karsilastirmasi
  // (gruplama kolonu esitligi) yapar.
  if HasHaving and (Length(HGroups) > 0) then
  begin
    k := 0;
    while k < Length(outR) do
    begin
      if not HavOK(outR[k], HGroups) then
      begin
        // k. satiri cikar
        for m := k to High(outR) - 1 do outR[m] := outR[m + 1];
        SetLength(outR, Length(outR) - 1);
        Continue;
      end;
      Inc(k);
    end;
  end;
  // ORDER BY cikti alanlari
  if Length(ONames) > 0 then
  begin
    SetLength(oidx, Length(ONames));
    SetLength(odir, Length(ONames));
    for i := 0 to High(ONames) do
    begin
      oidx[i] := -1;
      for k := 0 to High(Res.Fields) do
        if UpperCase(Res.Fields[k]) = UpperCase(ONames[i]) then
        begin oidx[i] := k; Break; end;
      if oidx[i] < 0 then
        raise EVDbException.Create(ecSyntaxError, 'ORDER BY cikti alani degil: ' + ONames[i]);
      odir[i] := ODesc[i];
    end;
    SortOutRows(outR);
  end;
  // LIMIT/OFFSET
  if (Off > 0) or (Lim >= 0) then
  begin
    k := 0;
    q := 0;
    while k < Length(outR) do
    begin
      if Off > 0 then begin Dec(Off); Inc(k); Continue; end;
      if (Lim >= 0) and (q >= Lim) then Break;
      if q <> k then outR[q] := outR[k];
      Inc(q); Inc(k);
    end;
    SetLength(outR, q);
  end;
  Res.Rows := outR;
end;

procedure TVSql.ExecJoin(const Sql: string; var P: Integer; const T1: string;
  const SCols: array of string; HasAgg, IsCount: Boolean; out Res: TSqlResult);
// FROM t1 [[AS] a1] [INNER|LEFT [OUTER]] JOIN t2 [[AS] a2] ON x=y
// WHERE/ORDER BY tekil + birlesik konumlarla; hash equi-join.
var
  fld, col, op, val, t2, a1, a2, key: string;
  td1, td2, fakeTd: TTableDef;
  refs: array of TTableRef;
  nL, nR, i, j, k, m, q: Integer;
  leftJoin: Boolean;
  p1, p2, l1, l2, lo, hi: Integer;
  groups: TWhereGroups;
  ocols: array of Integer;
  odesc: array of Boolean;
  lim, off, cnt: Integer;
  pks1, pks2: TStrArray;
  rows1, rows2: TStrMatrix;
  rKeys: TStrArray;
  rOrder: array of Integer;
  jrows, outR: TStrMatrix;
  jrow: TStrArray;
  idx: array of Integer;
  fpos: array of Integer;
  joinNumeric: Boolean;
  ct1, ct2: Byte;

  function NormKey(const V: string): string;
  // Yalniz SAYISAL kolonlarda normalize et. Aksi halde TEXT kolonda
  // '007' ile '7' ayni anahtara dusup HATALI eslesme olurdu.
  var
    f: Double;
  begin
    Result := V;
    if not joinNumeric then Exit;
    if VDbParseFloat(V, f) then
      Result := VDbFloatToStr(f);
  end;

  procedure SortRight;
    procedure Sort(L, H: Integer);
    var
      a, b, piv, tp: Integer;
    begin
      a := L; b := H; piv := rOrder[(L + H) div 2];
      repeat
        while CompareStr(rKeys[rOrder[a]], rKeys[piv]) < 0 do Inc(a);
        while CompareStr(rKeys[rOrder[b]], rKeys[piv]) > 0 do Dec(b);
        if a <= b then
        begin tp := rOrder[a]; rOrder[a] := rOrder[b]; rOrder[b] := tp; Inc(a); Dec(b); end;
      until a > b;
      if L < b then Sort(L, b);
      if a < H then Sort(a, H);
    end;
  begin
    if Length(rOrder) > 1 then Sort(0, High(rOrder));
  end;

  function RightRange(const K: string; out RLo, RHi: Integer): Boolean;
  var
    lo, hi, md: Integer;
  begin
    lo := 0; hi := Length(rOrder);
    while lo < hi do
    begin
      md := (lo + hi) div 2;
      if CompareStr(rKeys[rOrder[md]], K) < 0 then lo := md + 1 else hi := md;
    end;
    RLo := lo;
    hi := Length(rOrder);
    while lo < hi do
    begin
      md := (lo + hi) div 2;
      if CompareStr(rKeys[rOrder[md]], K) <= 0 then lo := md + 1 else hi := md;
    end;
    RHi := lo;
    Result := RHi > RLo;
  end;

  procedure EmitRow(iL, iR: Integer);
  var
    c: Integer;
  begin
    if Length(jrows) >= 2000000 then
      raise EVDbException.Create(ecLimit, 'JOIN sonucu cok buyuk (2M sinir)');
    SetLength(jrows, Length(jrows) + 1);
    SetLength(jrows[High(jrows)], nL + nR);
    for c := 0 to nL - 1 do
      jrows[High(jrows)][c] := rows1[iL][c];
    for c := 0 to nR - 1 do
      if iR >= 0 then
        jrows[High(jrows)][nL + c] := rows2[iR][c]
      else
        jrows[High(jrows)][nL + c] := '';
  end;

begin
  Res.Affected := 0; Res.Msg := '';
  SetLength(Res.Fields, 0); SetLength(Res.Rows, 0);
  if HasAgg then
    raise EVDbException.Create(ecUnsupported, 'JOIN ile aggregate yok (v1)');
  td1 := FT.GetTable(T1);
  // t1 takma adi (JOIN/INNER/LEFT gorunurse yok)
  a1 := '';
  if PeekWord(Sql, P) = 'AS' then
  begin
    Tok(Sql, P, fld);
    if not Tok(Sql, P, a1) then raise EVDbException.Create(ecSyntaxError, 'alias bekleniyor');
  end
  else if (PeekWord(Sql, P) <> 'JOIN') and (PeekWord(Sql, P) <> 'INNER') and
     (PeekWord(Sql, P) <> 'LEFT') then
  begin
    if not Tok(Sql, P, a1) then raise EVDbException.Create(ecSyntaxError, 'JOIN bekleniyor');
  end;
  Tok(Sql, P, fld);
  leftJoin := False;
  if UpperCase(fld) = 'LEFT' then
  begin
    leftJoin := True;
    if PeekWord(Sql, P) = 'OUTER' then Tok(Sql, P, fld);
    ExpectWord(Sql, P, 'JOIN');
  end
  else if UpperCase(fld) = 'INNER' then
    ExpectWord(Sql, P, 'JOIN')
  else if UpperCase(fld) <> 'JOIN' then
    raise EVDbException.Create(ecSyntaxError, 'JOIN bekleniyor');
  if not Tok(Sql, P, t2) then raise EVDbException.Create(ecTableNotFound, 'tablo yok');
  td2 := FT.GetTable(t2);
  a2 := '';
  if PeekWord(Sql, P) = 'AS' then
  begin
    Tok(Sql, P, fld);
    if not Tok(Sql, P, a2) then raise EVDbException.Create(ecSyntaxError, 'alias bekleniyor');
  end
  else if PeekWord(Sql, P) <> 'ON' then
  begin
    if not Tok(Sql, P, a2) then raise EVDbException.Create(ecSyntaxError, 'ON bekleniyor');
  end;
  ExpectWord(Sql, P, 'ON');
  SetLength(refs, 2);
  refs[0].Name := td1.Name; refs[0].Alias := VDbNorm(a1);
  refs[0].Cols := td1.Cols; refs[0].Base := 0;
  refs[1].Name := td2.Name; refs[1].Alias := VDbNorm(a2);
  refs[1].Cols := td2.Cols; refs[1].Base := Length(td1.Cols);
  nL := Length(td1.Cols); nR := Length(td2.Cols);
  if not Tok(Sql, P, col) then raise EVDbException.Create(ecSyntaxError, 'ON sol taraf yok');
  if not Tok(Sql, P, op) then raise EVDbException.Create(ecSyntaxError, 'ON operator yok');
  if not Tok(Sql, P, val) then raise EVDbException.Create(ecSyntaxError, 'ON sag taraf yok');
  if UpperCase(op) <> '=' then
    raise EVDbException.Create(ecUnsupported, 'ON sadece esitlik (v1)');
  p1 := ResolveJoinRef(refs, col);
  p2 := ResolveJoinRef(refs, val);
  if (p1 < nL) = (p2 < nL) then
    raise EVDbException.Create(ecUnsupported, 'ON farkli tablolarda olmali');
  if p1 < nL then begin l1 := p1; l2 := p2 - nL; end
  else begin l1 := p2; l2 := p1 - nL; end;
  // ON anahtari iki tarafta da SAYISAL ise normalize et; aksi halde
  // metin kolonlarinda '007' = '7' hatali eslesirdi.
  ct1 := VCT_STR; ct2 := VCT_STR;
  if l1 < nL then ct1 := td1.Cols[l1].Ctype else ct1 := td2.Cols[l1 - nL].Ctype;
  if l2 < nR then ct2 := td2.Cols[l2].Ctype else ct2 := td1.Cols[l2].Ctype;
  joinNumeric := VDbIsNumericCol(ct1) and VDbIsNumericCol(ct2);
  // WHERE
  SetLength(groups, 0);
  if PeekWord(Sql, P) = 'WHERE' then
  begin
    Tok(Sql, P, fld); // WHERE
    groups := ParseWhereGroups(Sql, P, refs);
  end;
  if PeekWord(Sql, P) = 'GROUP' then
    raise EVDbException.Create(ecUnsupported, 'JOIN ile GROUP BY yok (v1)');
  // ORDER BY (birlesik konumlar)
  SetLength(ocols, 0); SetLength(odesc, 0);
  if PeekWord(Sql, P) = 'ORDER' then
  begin
    Tok(Sql, P, fld);
    ExpectWord(Sql, P, 'BY');
    while True do
    begin
      if not Tok(Sql, P, col) then raise EVDbException.Create(ecSyntaxError, 'ORDER BY kolon bekleniyor');
      SetLength(ocols, Length(ocols) + 1); SetLength(odesc, Length(odesc) + 1);
      ocols[High(ocols)] := ResolveJoinRef(refs, col);
      odesc[High(odesc)] := False;
      if PeekWord(Sql, P) = 'DESC' then begin Tok(Sql, P, fld); odesc[High(odesc)] := True; end
      else if PeekWord(Sql, P) = 'ASC' then begin Tok(Sql, p, fld); end;
      if PeekWord(Sql, P) = ',' then begin Tok(Sql, P, fld); Continue; end;
      Break;
    end;
  end;
  lim := -1; off := 0;
  if PeekWord(Sql, P) = 'LIMIT' then
  begin
    Tok(Sql, P, fld);
    Tok(Sql, P, fld); lim := StrToIntDef(fld, -1);
    if PeekWord(Sql, P) = 'OFFSET' then begin Tok(Sql, P, fld); Tok(Sql, P, fld); off := StrToIntDef(fld, 0); end;
  end
  else if PeekWord(Sql, P) = 'OFFSET' then
  begin
    Tok(Sql, P, fld);
    Tok(Sql, P, fld); off := StrToIntDef(fld, 0);
  end;
  // JOIN zinciri bu islevde 2 tablo ile SINIRLI (refs = 2). Ucuncu
  // JOIN sessizce yutulursa kullanici yanlis satir sayisi gorur; acik
  // hata ver.
  if (PeekWord(Sql, P) = 'JOIN') or (PeekWord(Sql, P) = 'INNER') or
     (PeekWord(Sql, P) = 'LEFT') then
    raise EVDbException.Create(ecUnsupported, 'birden fazla JOIN desteklenmiyor (en fazla 2 tablo)');
  if PeekWord(Sql, P) <> '' then
    raise EVDbException.Create(ecSyntaxError, 'JOIN sonrasi anlasilamayan ek: ' + PeekWord(Sql, P));
  // projeksiyon konumlari
  if IsCount then
  begin
    SetLength(Res.Fields, 1); Res.Fields[0] := 'COUNT';
  end
  else if Length(SCols) = 0 then
  begin
    // *: nitelemeli adlar
    SetLength(Res.Fields, nL + nR);
    for i := 0 to nL - 1 do
    begin
      if a1 <> '' then Res.Fields[i] := a1 + '.' + td1.Cols[i].Name
      else Res.Fields[i] := td1.Name + '.' + td1.Cols[i].Name;
    end;
    for i := 0 to nR - 1 do
    begin
      if a2 <> '' then Res.Fields[nL + i] := a2 + '.' + td2.Cols[i].Name
      else Res.Fields[nL + i] := td2.Name + '.' + td2.Cols[i].Name;
    end;
    SetLength(fpos, nL + nR);
    for i := 0 to High(fpos) do fpos[i] := i;
  end
  else
  begin
    SetLength(Res.Fields, Length(SCols));
    SetLength(fpos, Length(SCols));
    for i := 0 to High(SCols) do
    begin
      Res.Fields[i] := SCols[i];
      fpos[i] := ResolveJoinRef(refs, SCols[i]);
    end;
  end;
  // hash join
  FT.ScanRows(td1.Name, pks1, rows1);
  FT.ScanRows(td2.Name, pks2, rows2);
  SetLength(rKeys, Length(pks2));
  for i := 0 to High(pks2) do
    rKeys[i] := NormKey(rows2[i][l2]);
  SetLength(rOrder, Length(pks2));
  for i := 0 to High(rOrder) do rOrder[i] := i;
  SortRight;
  SetLength(jrows, 0);
  cnt := 0;
  for i := 0 to High(pks1) do
  begin
    key := NormKey(rows1[i][l1]);
    if RightRange(key, lo, hi) then
    begin
      for j := lo to hi - 1 do
      begin
        SetLength(jrow, nL + nR);
        for k := 0 to nL - 1 do jrow[k] := rows1[i][k];
        for k := 0 to nR - 1 do jrow[nL + k] := rows2[rOrder[j]][k];
        if not VDbMatchGroups(jrow, groups) then Continue;
        if IsCount then
          Inc(cnt)
        else
          EmitRow(i, rOrder[j]);
      end;
    end
    else if leftJoin then
    begin
      SetLength(jrow, nL + nR);
      for k := 0 to nL - 1 do jrow[k] := rows1[i][k];
      for k := 0 to nR - 1 do jrow[nL + k] := '';
      if not VDbMatchGroups(jrow, groups) then Continue;
      if IsCount then
        Inc(cnt)
      else
        EmitRow(i, -1);
    end;
  end;
  if IsCount then
  begin
    SetLength(Res.Rows, 1); SetLength(Res.Rows[0], 1);
    Res.Rows[0][0] := IntToStr(cnt);
    Exit;
  end;
  // ORDER BY
  if Length(ocols) > 0 then
  begin
    fakeTd.Name := '';
    SetLength(fakeTd.Cols, 0);
    fakeTd.PkIndex := 0;
    SetLength(idx, Length(jrows));
    for i := 0 to High(idx) do idx[i] := i;
    SortRowsBy(idx, jrows, fakeTd, ocols, odesc);
    SetLength(outR, Length(jrows));
    for i := 0 to High(idx) do
      outR[i] := jrows[idx[i]];
    jrows := outR;
  end;
  // LIMIT/OFFSET + projeksiyon
  SetLength(outR, 0);
  for i := 0 to High(jrows) do
  begin
    if off > 0 then begin Dec(off); Continue; end;
    if (lim >= 0) and (Length(outR) >= lim) then Break;
    SetLength(outR, Length(outR) + 1);
    SetLength(outR[High(outR)], Length(fpos));
    for m := 0 to High(fpos) do
      outR[High(outR)][m] := jrows[i][fpos[m]];
  end;
  Res.Rows := outR;
end;

function TVSql.SplitStatements(const S: string): TStrArray;
// SQL betigini ';' ile AYRIK cumlelere boler. Tirnak disinda bolunur:
//   INSERT INTO t(a) VALUES('a;b');   -> tek komut, 'a;b' tek deger
// Kacisli tirnak ('it''si') dogru sayilir. Bos parcalar atilir.
// NEDEN: kullanici tek Edit'e birden fazla cumle yapistirip calistirir.
// Once Exec yalnizca ILK cumleyi isliyor, gerisi sessizce yok oluyordu --
// kullanici tabloyu bos/yarim sanirdi.
var
  i, n, start: Integer;
  inStr, inDq, inLine, inBlock: Boolean;
  c: Char;
  depth: Integer;   // F-35: acik BEGIN...END blok derinligi
  w, w2: string;
  j: Integer;
begin
  SetLength(Result, 0);
  n := Length(S);
  { P-20: HIZLI YOL. Hic ';' yoksa bolme de, BEGIN/END govde sayaci da
    is yapmaz; sonuc TAM OLARAK [Trim(S)] (ya da S tamamen bosluk ise []).
    Genel yolun son blogu da bunu uretir: dongu ';' dali HIC calismaz,
    bu yuzden start=1 kalir ve tek parca Trim(S) eklenir. Bu, tirnak/
    yorum icindeki ';' durumlarini da kapsar (Pos yalnizca VARLIGA bakar;
    varsa genel yol aynen calisir). Karakter-karakter string birleştiren
    genel yol her ifadede ~2.4 us yiyordu; tek-ifadeli cagrilar baskin. }
  if Pos(';', S) = 0 then
  begin
    { P-21: tek Trim — iki cagri yerine bir. }
    w := Trim(S);
    if w <> '' then
    begin
      SetLength(Result, 1);
      Result[0] := w;
    end;
    Exit;
  end;
  inStr := False;
  inDq := False;
  inLine := False;
  inBlock := False;
  depth := 0;
  start := 1;
  i := 1;
  while i <= n do
  begin
    c := S[i];
    // satir yorumu icinde: #10'a kadar devam
    if inLine then
    begin
      if c = #10 then inLine := False;
      Inc(i);
      Continue;
    end;
    // blok yorumu icinde: */ kadar devam
    if inBlock then
    begin
      if (c = '*') and (i < n) and (S[i + 1] = '/') then
      begin inBlock := False; Inc(i, 2); Continue; end;
      Inc(i);
      Continue;
    end;
    // tirnakli string/tanÄ±mlayÄ±cÄ± icinde: sadece kapanisa kadar devam
    if inStr then
    begin
      if c = '''' then
      begin
        if (i < n) and (S[i + 1] = '''') then Inc(i, 2) // kacis
        else begin inStr := False; Inc(i); end;
        Continue;
      end;
      Inc(i);
      Continue;
    end;
    if inDq then
    begin
      if c = '"' then inDq := False;
      Inc(i);
      Continue;
    end;
    // bu noktada tirnak icinda degiliz
    if c = '''' then
    begin
      inStr := True;
      Inc(i);
      Continue;
    end;
    if c = '"' then
    begin
      inDq := True;
      Inc(i);
      Continue;
    end;
    // yorumlari atla
    if (c = '-') and (i < n) and (S[i + 1] = '-') then
    begin inLine := True; Inc(i, 2); Continue; end;
    if (c = '/') and (i < n) and (S[i + 1] = '*') then
    begin inBlock := True; Inc(i, 2); Continue; end;
    // F-35: BEGIN / END sayaci. Govde blogu ICINDEKI noktali virguller
    // cumleyi BOLMEZ; aksi halde
    //   CREATE FUNCTION f() ... AS BEGIN RETURN 1; END
    // iki parcaya bolunur ve govde yarim kalsiyordu.
    // Karsilastirma: BEGIN TRANSACTION/WORK bir blok BASLATMAZ.
    if (c in ['A'..'Z', 'a'..'z', '_']) then
    begin
      w := '';
      while (i <= n) and (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      begin
        w := w + S[i];
        Inc(i);
      end;
      w2 := UpperCase(w);
      if w2 = 'BEGIN' then
      begin
        // BEGIN; / BEGIN TRANSACTION / BEGIN WORK / BEGIN DEFERRED ->
        // transaction baslangici, govde blogu DEGIL.
        w := '';
        j := i;
        while (j <= n) and (S[j] in [' ', #9, #10, #13]) do Inc(j);
        if (j <= n) and (S[j] = ';') then
          j := 0                       // bos cumle: blok acmaz
        else
        begin
          while (j <= n) and (S[j] in ['A'..'Z', 'a'..'z']) do
          begin
            w := w + S[j];
            Inc(j);
          end;
          w := UpperCase(w);
        end;
        if (w <> 'TRANSACTION') and (w <> 'WORK') and (w <> 'DEFERRED') and
           (j <> 0) then
          Inc(depth);
      end
      else if (w2 = 'END') and (depth > 0) then
        Dec(depth);
      Continue;
    end;
    if (c = ';') and (depth <= 0) then
    begin
      if Trim(Copy(S, start, i - start)) <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Trim(Copy(S, start, i - start));
      end;
      start := i + 1;
    end;
    Inc(i);
  end;
  if Trim(Copy(S, start, MaxInt)) <> '' then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Trim(Copy(S, start, MaxInt));
  end;
end;

function TVSql.StmtBatchSafe(const S: string): Boolean;
// Bir cumle otomatik transaction (batch) icinde calistirilabilir mi?
//
// HARIC TUTULANLAR:
//   BEGIN/COMMIT/ROLLBACK/END/SAVEPOINT -> ic ice batch olur, karisiyor
//   CREATE/DROP/DELETE DATABASE       -> ayri dosya; rollback onu geri almaz
//   VACUUM/REINDEX/EXPORT/IMPORT         -> dosya seviyesi yan etkiler
// Bunlardan biri varsa tum betik batch'siz (cumle basina ayri commit)
// calisir -> eski davranis korunur.
var
  p, sv: Integer;
  w, w2: string;
begin
  sv := FParamIdx;
  p := 1;
  Result := True;
  try
    if not Tok(S, p, w) then Exit;
    w := UpperCase(w);
    if (w = 'BEGIN') or (w = 'COMMIT') or (w = 'ROLLBACK') or (w = 'END') or
       (w = 'SAVEPOINT') or (w = 'RELEASE') or (w = 'VACUUM') or (w = 'REINDEX') or
       (w = 'EXPORT') or (w = 'IMPORT') or (w = 'ATTACH') or (w = 'DETACH') or
       (w = 'OPEN') or (w = 'USE') or (w = 'CLOSE') or (w = 'BACKUP') or
       (w = 'MIGRATE') or
       (w = 'VERIFY') or (w = 'REFRESH') or (w = 'TRIGGER') then
      Exit(False);
    if (w = 'CREATE') or (w = 'DROP') or (w = 'DELETE') then
      if Tok(S, p, w2) then
        if (UpperCase(w2) = 'DATABASE') or (UpperCase(w2) = 'VIEW') or
           (UpperCase(w2) = 'MATERIALIZED') or (UpperCase(w2) = 'FUNCTION') or
           (UpperCase(w2) = 'PROCEDURE') or (UpperCase(w2) = 'TRIGGER') then
          Exit(False);
  finally
    FParamIdx := sv;
  end;
end;

function TVSql.IsSelectStatement(const S: string): Boolean;
// Cumle SELECT (salt-okunur) mi?
// Basit heuristik: ilk kelime SELECT veya WITH (CTE) ise True.
// Bu, Exec/ExecAll'in kilit alip almayacagini belirler.
// MVCC icin SELECT sorgulari kilit ALMAZ, snapshot okuma kullanir.
var
  p, sv: Integer;
  w: string;
begin
  sv := FParamIdx;
  p := 1;
  Result := False;
  try
    if not Tok(S, p, w) then Exit;
    w := UpperCase(w);
    if (w = 'SELECT') or (w = 'WITH') then
      Result := True;
  finally
    FParamIdx := sv;
  end;
end;

function TVSql.IsCacheableText(const S: string): Boolean;
// P-CACHE: ilk kelime SELECT/WITH/INSERT/UPDATE/DELETE ise True.
// Yalniz plan onbellegi on-eleme acisindan; kesin karar IsCacheableAst'te.
// (Metin sezgisi yanilabilir: 'WITH ... INSERT' gercekte INSERT'tir.)
var
  p, sv: Integer;
  w: string;
begin
  sv := FParamIdx;
  p := 1;
  Result := False;
  try
    if not Tok(S, p, w) then Exit;
    w := UpperCase(w);
    Result := (w = 'SELECT') or (w = 'WITH') or (w = 'INSERT') or
              (w = 'UPDATE') or (w = 'DELETE');
  finally
    FParamIdx := sv;
  end;
end;

function TVSql.IsCacheableAst(Stmt: TSqlStmtNode): Boolean;
// P-CACHE: yalniz DML/SELECT dugumleri onbelleklenir. Metin sezgisinin
// kacirdigi durumlar (WITH ... INSERT -> TSqlInsertStmt) burada ayiklanir.
begin
  Result := (Stmt is TSqlSelectStmt) or (Stmt is TSqlInsertStmt) or
            (Stmt is TSqlUpdateStmt) or (Stmt is TSqlDeleteStmt);
end;

function TVSql.PlanCacheKey(const Sql: string): string;
// P-CACHE: onbellek anahtari. '?' karakteri parametre sayisina bagli olarak
// ya yer tutucu ya da JSONB operatorudur; bu yuzden parametre sayisi da
// anahtarin parcasi olmak zorunda. '#0' ayiraci SQL metninde gecemez.
begin
  Result := Sql + #0 + IntToStr(Length(FParams));
end;

function TVSql.ExecAll(const Stmts: TStrArray): TSqlResult;
// Cumle listesini sirayla isler. Affected TOPLAM, Fields/Rows ise SATIR
// DONDUREN SON cumlenin sonucu (yoksa son cumlenin sonucu).
//
// KR-7 (MREW): Tum cumleler SELECT ise LockRead (paralel calisir),
//   aksi halde Lock (yazma kilidi). Yazma yolu ExecAllInner'a delege
//   edilir -- bu sayede Exec -> ExecAll zincirinde recursive BeginWrite yok.
var
  i: Integer;
  one: TSqlResult;
  allSelect: Boolean;
  prevSess: Cardinal;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  prevSess := VDbGetWriteSession;
  VDbSetWriteSession(FSessionId);
  FT.Backend.WaitForeignTxn(FSessionId);
  try
  // Once tum cumleler SELECT mi kontrol et
  allSelect := True;
  for i := 0 to High(Stmts) do
    if not IsSelectStatement(Stmts[i]) then
    begin
      allSelect := False;
      Break;
    end;

  if allSelect then
  begin
    // Tum cumleler SELECT: okuma kilidi (paralel calisabilir)
    FT.LockRead;
    try
      Result.Affected := 0;
      Result.Msg := '';
      SetLength(Result.Fields, 0);
      SetLength(Result.FieldTypes, 0);
      SetLength(Result.Rows, 0);
      Result.LastTable := '';
      Result.Stmts := Length(Stmts);
      if Length(Stmts) = 0 then Exit;
      for i := 0 to High(Stmts) do
      begin
        one := ExecRaw(Stmts[i]);
        Result.Affected := Result.Affected + one.Affected;
        if one.LastTable <> '' then Result.LastTable := one.LastTable;
        Result.Fields := one.Fields;
        Result.FieldTypes := one.FieldTypes;
        Result.Rows := one.Rows;
        Result.Msg := one.Msg;
      end;
      Result.Msg := 'OK';
    finally
      FT.UnlockRead;
    end;
    Exit;
  end;

  // En az bir yazma cumlesi var: yazma kilidi + ExecAllInner
  FT.Lock;
  try
    Result := ExecAllInner(Stmts);
  finally
    FT.Unlock;
  end;
  finally
    VDbSetWriteSession(prevSess);
  end;
end;

function TVSql.ExecAllInner(const Stmts: TStrArray): TSqlResult;
// KR-7: Lock ALINMADAN calistirilir. Cagiranin FT.Lock (yazma kilidi)
// almis olmasi beklenir. Exec/ExecWithParams write path'i bu yardimciyi
// kullanarak recursive BeginWrite sorununu onler.
var
  i: Integer;
  one: TSqlResult;
  ownBatch, okAll: Boolean;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  Result.Affected := 0;
  Result.Msg := '';
  SetLength(Result.Fields, 0);
  SetLength(Result.FieldTypes, 0);
  SetLength(Result.Rows, 0);
  Result.LastTable := '';
  Result.Stmts := Length(Stmts);
  if Length(Stmts) = 0 then Exit;

  ownBatch := False;
  if FAutoTx and (Length(Stmts) > 1) and not FT.Backend.InBatch then
  begin
    okAll := True;
    for i := 0 to High(Stmts) do
      if not StmtBatchSafe(Stmts[i]) then
      begin
        okAll := False;
        Break;
      end;
    ownBatch := okAll;
  end;

  if ownBatch then FT.BeginBatch;
  try
    for i := 0 to High(Stmts) do
    begin
      one := ExecRaw(Stmts[i]);
      Result.Affected := Result.Affected + one.Affected;
      if one.LastTable <> '' then Result.LastTable := one.LastTable;
      Result.Fields := one.Fields;
      Result.FieldTypes := one.FieldTypes;
      Result.Rows := one.Rows;
      Result.Msg := one.Msg;
    end;
    if ownBatch then FT.CommitBatch;
  except
    if ownBatch then
      try FT.AbortBatch; except end;
    raise;
  end;
  Result.Msg := 'OK';
  // P-DUR: basarili yazma sonrasi kirliyse flush'la.
  if FT.Backend.Dirty then FT.Backend.Flush;
end;

function TVSql.Exec(const Sql: string): TSqlResult;
var
  st: TStrArray;
  prevSess: Cardinal;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);

  // KR-7 (MREW): SELECT sorgulari LockRead (paralel), yazma Lock (seri).
  st := SplitStatements(Sql);
  if Length(st) = 0 then
  begin
    Result.Affected := 0; Result.Msg := ''; Result.LastTable := '';
    Result.Stmts := 0;
    SetLength(Result.Fields, 0); SetLength(Result.Rows, 0);
    Exit;
  end;

  { F-42: oturum kimligini TUM Exec boyunca sabit tut. Executor kendi
    finally'sinda onceki degere dondurur; hizli yollar (literal INSERT,
    nokta SELECT) Execute'a ugradigi icin kimligi kendileri kurmaz.
    Bu sarmalayici olmadan hizli yol yazmalari 0 kimlikle kalir ve acik
    bir transaction'in sahibiyle uyusmaz. }
  prevSess := VDbGetWriteSession;
  VDbSetWriteSession(FSessionId);
  FT.Backend.WaitForeignTxn(FSessionId);
  try

  { P-21: SELECT/WITH disi cumlelerde IsSelectStatement cagrisini ATLA.
    Tok + UpperCase + try/finally her yazmada ~0.2 us yiyordu. }
  if (Length(st) = 1) and (Length(st[0]) > 0) and
     (st[0][1] in ['S', 's', 'W', 'w']) and IsSelectStatement(st[0]) then
  begin
    // Tek SELECT: okuma kilidi (paralel calisabilir)
    SetLength(FParams, 0);
    FParamIdx := 0;
    FT.LockRead;
    try
      Result := ExecRaw(st[0]);
      Result.Stmts := 1;
    finally
      FT.UnlockRead;
    end;
    Exit;
  end;

  // Coklu cumle veya yazma islemi: yazma kilidi
  FT.Lock;
  try
    SetLength(FParams, 0);
    FParamIdx := 0;
    if Length(st) = 1 then
    begin
      Result := ExecRaw(st[0]);
      Result.Stmts := 1;
      // P-DUR: tek cumlelik yazma burada saglama alinir (ExecAllInner kendi yapar).
      if FT.Backend.Dirty then FT.Backend.Flush;
    end
    else
      Result := ExecAllInner(st);  // KR-7: recursive Lock yok
  finally
    FT.Unlock;
  end;
  finally
    VDbSetWriteSession(prevSess);
  end;
end;

function TVSql.Exec(const Sql: string; const Params: array of string): TSqlResult;
var
  i: Integer;
  st: TStrArray;
  prevSess: Cardinal;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);

  // KR-7 (MREW): SELECT sorgulari LockRead (paralel), yazma Lock (seri).
  st := SplitStatements(Sql);
  if Length(st) = 0 then
  begin
    Result.Affected := 0; Result.Msg := ''; Result.LastTable := '';
    Result.Stmts := 0;
    SetLength(Result.Fields, 0); SetLength(Result.Rows, 0);
    Exit;
  end;

  prevSess := VDbGetWriteSession;
  VDbSetWriteSession(FSessionId);
  FT.Backend.WaitForeignTxn(FSessionId);
  try

  { P-21: SELECT/WITH disi cumlelerde IsSelectStatement cagrisini ATLA. }
  if (Length(st) = 1) and (Length(st[0]) > 0) and
     (st[0][1] in ['S', 's', 'W', 'w']) and IsSelectStatement(st[0]) then
  begin
    // Tek SELECT: okuma kilidi (paralel calisabilir)
    SetLength(FParams, Length(Params));
    for i := 0 to High(Params) do
      FParams[i] := Params[i];
    FParamIdx := 0;
    FT.LockRead;
    try
      Result := ExecRaw(st[0]);
      Result.Stmts := 1;
    finally
      FT.UnlockRead;
    end;
    Exit;
  end;

  // Coklu cumle veya yazma islemi: yazma kilidi
  FT.Lock;
  try
    SetLength(FParams, Length(Params));
    for i := 0 to High(Params) do
      FParams[i] := Params[i];
    FParamIdx := 0;
    if Length(st) = 1 then
    begin
      Result := ExecRaw(st[0]);
      Result.Stmts := 1;
      // P-DUR: tek cumlelik yazma burada saglama alinir (ExecAllInner kendi yapar).
      if FT.Backend.Dirty then FT.Backend.Flush;
    end
    else
      Result := ExecAllInner(st);  // KR-7: recursive Lock yok
  // fazla parametre sessizce yoksayilir; eksik Tok'ta patlar
  finally
    FT.Unlock;
  end;
  finally
    VDbSetWriteSession(prevSess);
  end;
end;

{ ---------------------------------------------------- veritabani seviyesi }

function TVSql.DbDir: string;
// Etkin veritabaninin klasoru. TVDb.Open(Dir) -> <Dir>\veritabani.odb
begin
  Result := ExtractFileDir(FT.Backend.FilePath);
end;

function TVSql.DbParent: string;
// Yeni veritabanlari ETKIN veritabaninin BULUNDUGU KLASORE olusur.
//
//   D:\veritabani\db\veritabani.odb   <- etkin
//   D:\veritabani\db\satis.odb        <- CREATE DATABASE 'satis'
//
// "Kardes" deyimi burada ayni klasoru ifade eder: veritabani dosyalari
// birbirinin icine g?m?lmez, tek dosya olarak yan yana durur.
// NOT: LIST DATABASES bu klasordeki hem *.odb dosyalarini hem de icinde
// veritabani.odb bulunan klasorleri (eski yerlesim) listeler.
begin
  Result := DbDir;
  if Result = '' then Result := '.';
end;

function TVSql.CleanDbName(const S: string): string;
// Veritabani adi = dosya adi (uzantisiz). Kullanici 'satis.odb' yazarsa
// uzantI atilir -> 'satis' (yoksa satis.odb.odb olurdu).
// Bu SQL ile diskte ISTENEN yere dosya yazilabilmemesi icin yol ayirici
// ve '..' reddedilir. Tirnakli gelirse ('satis') ayirilir.
var
  i: Integer;
  sn: string;   // S ile cakismasin (mode delphi: kucuk/buyuk harf duyarsiz)
begin
  sn := Trim(S);
  if (Length(sn) >= 2) and (sn[1] = '''') and (sn[Length(sn)] = '''') then
    sn := Copy(sn, 2, Length(sn) - 2);
  sn := Trim(sn);
  if sn = '' then
    raise EVDbException.Create(ecInvalidName, 'veritabani adi bos olamaz');
  if Length(sn) > 64 then
    raise EVDbException.Create(ecInvalidName, 'veritabani adi cok uzun (en fazla 64 karakter)');
  for i := 1 to Length(sn) do
    if (sn[i] in ['\', '/', ':', '*', '?', '"', '<', '>', '|']) or (sn[i] = #0) then
      raise EVDbException.Create(ecInvalidName, 'gecersiz veritabani adi (yol ayirici kullanilamaz): ' + sn);
  if (sn = '.') or (sn = '..') or (Pos('..', sn) > 0) then
    raise EVDbException.Create(ecInvalidName, 'gecersiz veritabani adi: ' + sn);
  // kullanici uzantiyi yazdiysa soy (satis.odb -> satis)
  if SameText(ExtractFileExt(sn), VDB_EXT) then
    sn := ChangeFileExt(sn, '');
  Result := sn;
end;

function TVSql.DbLegacyFileOf(const Name: string): string;
// ESKI yerlesim: <klasor>\<ad>\veritabani.odb  (okunur, yeni olusturulmaz)
begin
  Result := IncludeTrailingPathDelimiter(DbParent) + CleanDbName(Name) +
    PathDelim + 'veritabani.odb';
end;

function TVSql.DbFileOf(const Name: string): string;
// YENI yerlesim: <aktif db klasoru>\<ad>.odb  -> TEK DOSYA.
//
// "CREATE DATABASE satis" yazdiginda satis.odb, ETKIN veritabaninin
// bulundugu klasore olusur.
//
// Geriye uyum: ayni klasorde klasor icinde olusturulmus bir veritabani
// varsa (<ad>\veritabani.odb) ONUN yolu dondurulur; boylece eski veriler
// bulunmaya devam eder ve DROP/CREATE ayni nesneyi gosterir.
var
  nm, f: string;
begin
  nm := CleanDbName(Name);
  f := IncludeTrailingPathDelimiter(DbParent) + nm + VDB_EXT;
  if FileExists(f) then Exit(f);
  if FileExists(DbLegacyFileOf(nm)) then Exit(DbLegacyFileOf(nm));
  Result := f;
end;

function TVSql.DbNameOfFile(const Path: string): string;
// Bir .odb dosya yolundan veritabani adini cikarir.
// VERITABANI ADI = DOSYA ADI (uzantisiz). Bu, CREATE/DROP DATABASE ile
// tutarlidir: DbFileOf('veritabani') her zaman <klasor>\veritabani.odb
// doner, klasor adi degil.
//   ...\satis.odb            -> satis
//   ...\ana4\veritabani.odb  -> veritabani
begin
  Result := ChangeFileExt(ExtractFileName(Path), '');
end;

function TVSql.ExecCreateDatabase(const Sql: string; var P: Integer): TSqlResult;
// CREATE DATABASE [IF NOT EXISTS] ad
// "CREATE DATABASE satis" -> <aktif db klasoru>\satis.odb (TEK DOSYA, klasor yok)
// NOT: 'DATABASE' tokeni CAGIRAN (ExecRaw) tarafindan tuketilmistir.
var
  t: string;
  ifNotExists: Boolean;
  path, f: string;
  nkv: TVDb;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  ifNotExists := False;
  if PeekWord(Sql, P) = 'IF' then
  begin
    Tok(Sql, P, t);
    ExpectWord(Sql, P, 'NOT');
    ExpectWord(Sql, P, 'EXISTS');
    ifNotExists := True;
  end;
  if not Tok(Sql, P, t) then raise EVDbException.Create(ecInvalidName, 'veritabani adi yok');
  f := DbFileOf(t);
  path := ExtractFileDir(f);
  if FileExists(f) then
  begin
    if not ifNotExists then
      raise EVDbException.Create(ecDatabaseExists, 'veritabani zaten var: ' + t);
    Result.Msg := 'VAR';
    Result.Affected := 0;
    Exit;
  end;
  ForceDirectories(path);
  // TVDb.Open .odb yolunda dogrudan TEK DOSYA acar (klasor olusturmaz).
  // Bos dosyaya VODB basligi yazilir; sonra kapatiyoruz.
  // (Uzerine yazma riski yok: yukarida FileExists ile elendi.)
  nkv := TVDb.Create;
  try
    nkv.SyncWrite := True;
    nkv.Open(f);
    nkv.Flush;
  finally
    nkv.Close;
    nkv.Free;
  end;
  Result.Msg := 'OLUSTURULDU: ' + f;
  Result.Affected := 1;
end;

function TVSql.ExecDropDatabase(const Sql: string; var P: Integer): TSqlResult;
// DROP DATABASE [IF EXISTS] ad
// NOT: 'DATABASE' tokeni CAGIRAN (ExecRaw) tarafindan tuketilmistir.
var
  t, f: string;
  ifExists: Boolean;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  ifExists := False;
  if PeekWord(Sql, P) = 'IF' then
  begin
    Tok(Sql, P, t);
    ExpectWord(Sql, P, 'EXISTS');
    ifExists := True;
  end;
  if not Tok(Sql, P, t) then raise EVDbException.Create(ecInvalidName, 'veritabani adi yok');
  f := DbFileOf(t);
  if not FileExists(f) then
  begin
    if not ifExists then
      raise EVDbException.Create(ecDatabaseNotFound, 'veritabani yok: ' + t);
    Result.Msg := 'YOK';
    Exit;
  end;
  // Etkin veritabani kendini silemez
  if SameText(ExtractFileExt(f), VDB_EXT) and
     SameText(ExtractFileName(f), ExtractFileName(FT.Backend.FilePath)) and
     SameText(ExtractFileDir(f), ExtractFileDir(FT.Backend.FilePath)) then
    raise EVDbException.Create(ecInvalidState, 'etkin veritabani silinemez');
  if not DeleteFile(f) then
    raise EVDbException.Create(ecDatabaseLocked, 'silinemedi (dosya kilitli olabilir): ' + f);
  // .odb.tmp / .odb.bak artiklari
  DeleteFile(f + '.tmp');
  DeleteFile(f + '.bak');
  Result.Msg := 'SILINDI: ' + f;
  Result.Affected := 1;
end;

function TVSql.ExecOpenDatabase(const Sql: string; var P: Integer): TSqlResult;
// OPEN DATABASE ad  |  OPEN ad  |  USE ad
// Etkin veritabanini degistirir. Veritabani ETKIN dosyanin bulundugu
// klasorde aranir (DbFileOf). Acilis sonrasi otomatik olarak butunluk
// denetimi (Verify) yapilir ve sonuc Msg'de bildirilir.
//
// NOT: motor nesnesi AYNI kalir (TVDb.Open kendi kendini kapatip yeni
// dosyayi acar; TVTableDb semayi yeniden yukler). Bu yuzden cagiran
// tarafin TVSql / TVTableDb / TVDb referanslari gecerli kalir.
//
// Guvenlik: var OLMAYAN bir veritabani yanlis yazimda bos dosya
// OLUSTURULMAZ; hata verir ve mevcutler listelenmesi icin yol gosterilir.
var
  t, f, dir, rep: string;
  okv: Boolean;
  ms: QWord;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  if PeekWord(Sql, P) = 'DATABASE' then
    Tok(Sql, P, t);   // 'DATABASE' tokeni tuketildi
  if not Tok(Sql, P, t) then raise EVDbException.Create(ecInvalidName, 'veritabani adi yok');
  f := DbFileOf(t);
  if not FileExists(f) then
    raise EVDbException.Create(ecDatabaseNotFound, 'veritabani bulunamadi: ' + CleanDbName(t) +
      '  (LIST DATABASES ile listele)');
  dir := ExtractFileDir(f);
  ms := VdbTickMs;
  FT.Close;        // acik olanin bekleyen sema yazimi (varsa) tamamlansin
  FT.Kv.Open(f);   // TVDb.Open kendini kapatip yeni dosyayi acar
  FT.Open(dir);    // semayi yeni dosyadan yeniden yukler + indeksleri kurar
  rep := '';       // otomatik butunluk denetimi
  okv := FT.Kv.Verify(rep);
  Result.LastTable := '';
  Result.Affected := 1;
  Result.Stmts := 1;
  if okv then
    Result.Msg := 'ACILDI: ' + f + '  SAGLAM  (' +
      IntToStr(VdbTickMs - ms) + ' ms)'
  else
    Result.Msg := 'ACILDI: ' + f + '  !! BUTUNLUK SORUNU: ' + rep;
end;

function TVSql.ExecCloseDatabase(const Sql: string; var P: Integer): TSqlResult;
// CLOSE [DATABASE]
var
  t, f: string;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  if PeekWord(Sql, P) = 'DATABASE' then
    Tok(Sql, P, t);
  f := FT.Backend.FilePath;
  FT.Close;        // bekleyen sema yazimi
  FT.Kv.Close;     // dosya kilidini birakir
  Result.Affected := 1;
  Result.LastTable := '';
  Result.Stmts := 1;
  Result.Msg := 'KAPATILDI: ' + f;
end;

function TVSql.ExecBackupTo(const Sql: string; var P: Integer): TSqlResult;
// BACKUP TO 'dosya.odb'  -> acik veritabaninin tutarli yedegi
var
  dest: string;
  ms: QWord;
begin
  { Bkz. ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  ExpectWord(Sql, P, 'TO');   // "BACKUP TO '<dosya>'"
  if not Tok(Sql, P, dest) then raise EVDbException.Create(ecInvalidName, 'dosya adi yok');
  dest := Trim(dest);
  if (Length(dest) >= 2) and (dest[1] = '''') and (dest[Length(dest)] = '''') then
    dest := Copy(dest, 2, Length(dest) - 2);
  dest := Trim(dest);
  if dest = '' then raise EVDbException.Create(ecInvalidName, 'dosya adi bos');
  if not SameText(ExtractFileExt(dest), VDB_EXT) then
    dest := dest + VDB_EXT;
  ms := VdbTickMs;
  { Sprint 3.2: v3 sayfa motorunda `Kv = nil`; yedek backend uzerinden alinir.
    Bu yol SQL metnini parser'a vermeden calisan hizli yoldur. }
  if FT.Kv <> nil then
    FT.Kv.BackupTo(dest)
  else
    FT.Backend.BackupTo(dest);
  Result.Affected := 1;
  Result.LastTable := '';
  Result.Stmts := 1;
  Result.Msg := 'YEDEK: ' + dest + '  (' + IntToStr(VdbTickMs - ms) + ' ms)';
end;

function TVSql.PathArg(const Sql: string; var P: Integer): string;
begin
  if not Tok(Sql, P, Result) then
    raise EVDbException.Create(ecInvalidName, 'dosya adi yok');
  Result := Trim(Result);
  if (Length(Result) >= 2) and (Result[1] = '''') and
     (Result[Length(Result)] = '''') then
    Result := Copy(Result, 2, Length(Result) - 2);
  Result := Trim(Result);
  if Result = '' then
    raise EVDbException.Create(ecInvalidName, 'dosya adi bos');
end;

function TVSql.ExecMigrateTo(const Sql: string; var P: Integer): TSqlResult;
// MIGRATE TO v3 'yeni.odb'
//   Acik (v2) veritabaninin KV uzayini v3 sayfa dosyasina birebir kopyalar.
var
  dest, w: string;
  rep: TVdbMigrateReport;
  err: string;
begin
  FillChar(Result, SizeOf(Result), 0);
  if FT.Kv = nil then
    raise EVDbException.Create(ecUnsupported,
      'MIGRATE: kaynak zaten v3 sayfa motoru');
  { Cagiran 'MIGRATE TO' tuketti; sirada surum etiketi var. }
  if not Tok(Sql, P, w) then
    raise EVDbException.Create(ecSyntaxError,
      'MIGRATE TO v3 ''<dosya>'' bekleniyor');
  if not SameText(w, 'v3') then
    raise EVDbException.Create(ecSyntaxError,
      'MIGRATE TO v3 bekleniyor (bulunan: ' + w + ')');
  dest := PathArg(Sql, P);
  if not SameText(ExtractFileExt(dest), VDB_EXT) then
    dest := dest + VDB_EXT;
  if not VdbMigrateToV3(FT.Backend, dest, 256, rep, err) then
    raise EVDbException.Create(ecIOError, 'MIGRATE basarisiz: ' + err);
  Result.Affected := rep.Keys;
  Result.LastTable := '';
  Result.Stmts := 1;
  Result.Msg := Format('GOC v3: %s  kayit=%d  bayt=%d  %d ms',
    [dest, rep.Keys, rep.Bytes, rep.Ms]);
end;

function TVSql.ExecMigrateVerify(const Sql: string; var P: Integer): TSqlResult;
// MIGRATE VERIFY '<goc.odb>' - acik veritabani ile hedefi bayt bayt karsilastirir
var
  dest: string;
  rep: TVdbMigrateReport;
  err: string;
begin
  FillChar(Result, SizeOf(Result), 0);
  dest := PathArg(Sql, P);
  if not SameText(ExtractFileExt(dest), VDB_EXT) then
    dest := dest + VDB_EXT;
  if not VdbMigrateVerify(FT.Backend, dest, 256, rep, err) then
    raise EVDbException.Create(ecCorrupt, 'MIGRATE VERIFY basarisiz: ' + err);
  Result.Affected := rep.Keys;
  Result.LastTable := '';
  Result.Stmts := 1;
  Result.Msg := Format('GOC DOGRULANDI: %s  kayit=%d  bayt=%d  fark=0  %d ms',
    [dest, rep.Keys, rep.Bytes, rep.Ms]);
end;

procedure TVSql.ExecVerify(out Res: TSqlResult);
// VERIFY -> salt-okunur butunluk denetimi (sonuc Msg'de)
var
  rep: string;
  ms: QWord;
begin
  ms := VdbTickMs;
  rep := '';
  if FT.Kv.Verify(rep) then Res.Affected := 1 else Res.Affected := 0;
  Res.LastTable := '';
  Res.Stmts := 1;
  Res.Msg := 'VERIFY (' + IntToStr(VdbTickMs - ms) + ' ms): ' + rep;
end;

procedure TVSql.ExecListDatabases(out Res: TSqlResult);
// Etkin veritabaninin kardeslerini listeler. IKI yerlesimi de tanir:
//   YENI : <klasor>\satis.odb             (TEK dosya - CREATE DATABASE)
//   ESKI : <klasor>\satis\veritabani.odb  (klasor - geriye uyum)
// Liste satiri: veritabani adi + '*' isareti (etkin olan).
var
  sr: TSearchRec;
  root, full: string;
  n: Integer;
  curPath: string;
  curListed: Boolean;

  function Already(const Nm: string): Boolean;
  var i: Integer;
  begin
    Result := False;
    for i := 0 to n - 1 do
      if SameText(Res.Rows[i][0], Nm) then Exit(True);
  end;

  procedure AddRow(const Nm, FullPath: string);
  var isCur: Boolean;
  begin
    if Already(Nm) then Exit;
    isCur := SameText(FullPath, curPath);
    SetLength(Res.Rows, n + 1);
    SetLength(Res.Rows[n], 2);
    Res.Rows[n][0] := Nm;
    if isCur then Res.Rows[n][1] := '*' else Res.Rows[n][1] := '';
    Inc(n);
    if isCur then curListed := True;
  end;
begin
  SetLength(Res.Fields, 2);
  Res.Fields[0] := 'database';
  Res.Fields[1] := 'current';
  curPath := FT.Backend.FilePath;
  root := DbParent;
  n := 0;
  curListed := False;
  SetLength(Res.Rows, 0);

  // 1) YENI yerlesim: <klasor>\*.odb  -> adi dosya adindan gelir
  if FindFirst(IncludeTrailingPathDelimiter(root) + '*' + VDB_EXT,
    faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Attr and faDirectory = 0) and (sr.Name <> '.') and
         (sr.Name <> '..') and (sr.Name <> '') then
      begin
        full := IncludeTrailingPathDelimiter(root) + sr.Name;
        AddRow(ChangeFileExt(sr.Name, ''), full);
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;

  // 2) ESKI yerlesim: <klasor>\<klasor>\veritabani.odb
  if FindFirst(IncludeTrailingPathDelimiter(root) + '*', faDirectory, sr) = 0 then
  try
    repeat
      if (sr.Attr and faDirectory <> 0) and (sr.Name <> '.') and
         (sr.Name <> '..') then
      begin
        full := IncludeTrailingPathDelimiter(root) + sr.Name +
                PathDelim + 'veritabani.odb';
        if FileExists(full) then AddRow(sr.Name, full);
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;

  // Etkin veritabani kardesler arasinda degilse (baska surucu vb.)
  // listede gorunmez; sona ekle ki LIST DATABASES yaniltmasin.
  if not curListed then
  begin
    SetLength(Res.Rows, n + 1);
    SetLength(Res.Rows[n], 2);
    Res.Rows[n][0] := DbNameOfFile(curPath);
    Res.Rows[n][1] := '*';
    Inc(n);
  end;
  Res.Affected := n;
  Res.Msg := IntToStr(n) + ' veritabani';
end;

function TVSql.ExecRaw(const Sql: string): TSqlResult;
var
  astStmt: TSqlStmtNode;
  pTest: Integer;
  pSet: Integer;   // R-11: "SET" anahtar kelimesinden SONRAKI konum
                    // (SET CONSTRAINTS ayriminda geri sarmak icin)
  w1, w2, w3: string;
  fastOk: Boolean;
  spanRoot, spanChild: TVDbTraceSpan;
  // P-CACHE: plan onbellegi anahtari / karar degiskenleri
  cacheKey: string;
  cacheable: Boolean;
  i: Integer;
  lit: TSqlLiteralNode;
begin
  { FPC 3.2.2 / x86_64: bazi cagri baglamlarinda yonetilen alanli kayit
    donduren fonksiyonun gecici sonucu sifirlanmiyor; onceki cagridan
    kalan (artik serbest birakilmis) dizi isaretcileri SetLength tarafindan
    yeniden finalize edilip yigin bozulmasina yol aciyor. Sonuc deposunu
    finalize ETMEDEN sifirla; girisde sahiplenilmis veri yoktur.
    v4: FillChar zaten tum alanlari sifirlar (dizi/string isaretcileri = nil
    = bos); ardindan SetLength(..., 0) ve '' atamalari gereksiz. }
  FillChar(Result, SizeOf(Result), 0);
  Result.Stmts := 1;

  { F-42: dogrudan ExecRaw cagrilari da yabanci acik transaction'i beklesin. }
  FT.Backend.WaitForeignTxn(FSessionId);

  // F-40: READ COMMITTED / READ UNCOMMITTED -> her cumle yeni snapshot.
  if FT.Backend.InBatch and
     (FExecutor.Isolation in [ilReadUncommitted, ilReadCommitted]) then
    FT.Backend.RefreshBatchSnapshot;

  spanRoot := VDbTraceBegin('sql.query', nil);
  VDbTraceSetAttr(spanRoot, 'db.statement', Sql);
  try
  // P-18c (2026-10-16): literal INSERT hizli seridi.
  if (Length(Sql) > 13) and ((Sql[1] = 'I') or (Sql[1] = 'i')) then
  begin
    SlowMarkStart;
    try
      fastOk := FExecutor.ExecFastLiteralInsert(Sql, Result);
      if fastOk then
      begin
        FLastMs := ElapsedMs;
        NoteSlow(Sql, FLastMs, Length(Result.Rows));
        RecordCommand(Sql, FLastMs * 1000, 0);
        Exit;
      end;
      // P-DUR v3: literal ret edildiyse parametreli INSERT seridini dene.
      if Length(FParams) > 0 then
      begin
        fastOk := FExecutor.ExecFastParamInsert(Sql, FParams, Result);
        if fastOk then
        begin
          FLastMs := ElapsedMs;
          NoteSlow(Sql, FLastMs, Length(Result.Rows));
          RecordCommand(Sql, FLastMs * 1000, 0);
          Exit;
        end;
      end;
    except
      FLastMs := ElapsedMs;
      NoteSlow(Sql, FLastMs, Length(Result.Rows));
      RecordCommand(Sql, FLastMs * 1000, 0);
      raise;
    end;
  end;

  // H13 (2026-10-19): COPY FROM dosya akisi. COPY sozcugu ile baslamayan
  // cumlelerde ExecFastCopy False doner ve normal yol aynen calisir.
  if (Length(Sql) > 6) and ((Sql[1] = 'C') or (Sql[1] = 'c')) then
  begin
    SlowMarkStart;
    try
      fastOk := FExecutor.ExecFastCopy(Sql, Result);
      if fastOk then
      begin
        FLastMs := ElapsedMs;
        NoteSlow(Sql, FLastMs, Length(Result.Rows));
        RecordCommand(Sql, FLastMs * 1000, 0);
        Exit;
      end;
    except
      FLastMs := ElapsedMs;
      NoteSlow(Sql, FLastMs, Length(Result.Rows));
      RecordCommand(Sql, FLastMs * 1000, 0);
      raise;
    end;
  end;

  // P-23 (2026-10-17): tekil PK nokta SELECT hizli seridi
  // ('S'/'s' ile baslayan, WHERE pk = val iceren basit sorgular)
  if (Length(Sql) > 15) and ((Sql[1] = 'S') or (Sql[1] = 's')) then
  begin
    SlowMarkStart;
    try
      fastOk := FExecutor.ExecFastPointSelect(Sql, FParams, Result);
      if fastOk then
      begin
        FLastMs := ElapsedMs;
        NoteSlow(Sql, FLastMs, Length(Result.Rows));
        RecordCommand(Sql, FLastMs * 1000, 0);
        Exit;
      end;
    except
      FLastMs := ElapsedMs;
      NoteSlow(Sql, FLastMs, Length(Result.Rows));
      RecordCommand(Sql, FLastMs * 1000, 0);
      raise;
    end;
  end;

  // P-CACHE (2026-10-30): tekil PK nokta DELETE hizli seridi
  // ('D'/'d' ile baslayan, WHERE pk = val iceren basit silmeler)
  if (Length(Sql) > 15) and ((Sql[1] = 'D') or (Sql[1] = 'd')) then
  begin
    SlowMarkStart;
    try
      fastOk := FExecutor.ExecFastPointDelete(Sql, FParams, Result);
      if fastOk then
      begin
        FLastMs := ElapsedMs;
        NoteSlow(Sql, FLastMs, Length(Result.Rows));
        RecordCommand(Sql, FLastMs * 1000, 0);
        Exit;
      end;
    except
      FLastMs := ElapsedMs;
      NoteSlow(Sql, FLastMs, Length(Result.Rows));
      RecordCommand(Sql, FLastMs * 1000, 0);
      raise;
    end;
  end;

  // P-CACHE (2026-10-30): tekil PK nokta UPDATE hizli seridi
  // ('U'/'u' ile baslayan, WHERE pk = val + literal SET iceren basit
  // guncellemeler; tetikleyici/RLS/EXPRESSION SET/PK yazma -> genel yol)
  if (Length(Sql) > 15) and ((Sql[1] = 'U') or (Sql[1] = 'u')) then
  begin
    SlowMarkStart;
    try
      fastOk := FExecutor.ExecFastPointUpdate(Sql, FParams, Result);
      if fastOk then
      begin
        FLastMs := ElapsedMs;
        NoteSlow(Sql, FLastMs, Length(Result.Rows));
        RecordCommand(Sql, FLastMs * 1000, 0);
        Exit;
      end;
    except
      FLastMs := ElapsedMs;
      NoteSlow(Sql, FLastMs, Length(Result.Rows));
      RecordCommand(Sql, FLastMs * 1000, 0);
      raise;
    end;
  end;

  // DB yonetim komutlari TVSql uzerinde ozel dosya yonetimi gerektirir
  pTest := 1;
  if Tok(Sql, pTest, w1) then
  begin
    w1 := UpperCase(w1);
    if (w1 = 'LIST') or (w1 = 'SHOW') then
    begin
      // DIKKAT: ilk Tok SADECE bir kez cagrilir. Iki kez cagrilirsa ilk
      // kosul ("DATABASES") ikinci kelimeyi tukumus olur ve sonraki
      // kosullar da yanlis yere bakar (SHOW SLOW QUERIES -> "SLOW"
      // tuhnup, "QUERIES" gorunur).
      if Tok(Sql, pTest, w3) then
      begin
        if UpperCase(w3) = 'DATABASES' then
        begin
          ExecListDatabases(Result);
          Exit;
        end;
        // F-21: SHOW SLOW QUERIES — kayitli yavas sorgulari raporlar
        if UpperCase(w3) = 'SLOW' then
          if Tok(Sql, pTest, w2) and (UpperCase(w2) = 'QUERIES') then
          begin
            ExecShowSlowQueries(Result);
            Exit;
          end;
      end;
    end
    // F-21: SET SLOW = N  /  SET SLOW_QUERY_MS = N  /  SET MAX_SLOW_ENTRIES = N
    else if w1 = 'SET' then
    begin
      pSet := pTest;   // R-11
      { R-11: `SET CONSTRAINTS ALL DEFERRED | IMMEDIATE` ayar degil,
        SQL cumlesidir. Asagidakaki "SET x = y" yolu `=` bekledigi
        icin bu cumleyi yanlis yorumlardi ("= bekleniyor, gelen: ALL").
        Once AST'ye devredilir. }
      if Tok(Sql, pTest, w3) then
      begin
        { R-19: SET ROLE rol | NONE  -- ayar DEGIL, SQL cumlesi }
        if UpperCase(w3) = 'ROLE' then
        begin
          if not Tok(Sql, pTest, w2) then
            raise EVDbException.Create(ecSyntaxError,
              'SET ROLE sonrasi rol adi ya da NONE bekleniyor');
          FT.SetCurrentRole(w2);
          SetLength(Result.Fields, 1);
          Result.Fields[0] := 'role';
          SetLength(Result.Rows, 1);
          SetLength(Result.Rows[0], 1);
          Result.Rows[0][0] := w2;
          Result.Affected := 0;
          Result.Msg := 'OK';
          Exit;
        end;
        { F-40: SET [SESSION CHARACTERISTICS AS] TRANSACTION ISOLATION
          LEVEL ... bir ayar degil, SQL cumlesidir; AST'ye devredilir. }
        if (UpperCase(w3) = 'TRANSACTION') or
           (UpperCase(w3) = 'SESSION') then
        begin
          astStmt := FParser.Parse(Sql, FParams);
          try
            Result := FExecutor.Execute(astStmt);
          finally
            astStmt.Free;
          end;
          Exit;
        end;
        { R-11: SET CONSTRAINTS ... }
        if UpperCase(w3) <> 'CONSTRAINTS' then
        begin
          { Tok imleci ILETERDI. CONSTRAINTS degilse konumu geri al,
            yoksa asagidaki "SET x = y" yolu bir sonraki token'i
            w3 sanip ("SET SLOW = 5" -> w3='=') ve tum ayar komutlari
            bozulur. }
          pTest := pSet;
        end
        else
        begin
        if not Tok(Sql, pTest, w2) then
          raise EVDbException.Create(ecSyntaxError,
            'SET CONSTRAINTS sonrasi ALL / kisit adi bekleniyor');
        // istege bagli kisit-adi listesi atlanir
        while (UpperCase(w2) <> 'DEFERRED') and (UpperCase(w2) <> 'IMMEDIATE') do
          if not Tok(Sql, pTest, w2) then
            raise EVDbException.Create(ecSyntaxError,
              'SET CONSTRAINTS sonrasi DEFERRED ya da IMMEDIATE bekleniyor');
        FT.SetDeferred(UpperCase(w2) = 'DEFERRED');
        SetLength(Result.Fields, 1);
        Result.Fields[0] := 'constraints';
        SetLength(Result.Rows, 1);
        SetLength(Result.Rows[0], 1);
        Result.Rows[0][0] := UpperCase(w2);
        Result.Affected := 0;
        Result.Msg := 'OK';
        Exit;
        end;
      end;
      if not Tok(Sql, pTest, w3) then
        raise EVDbException.Create(ecSyntaxError, 'SET sonrasi ayar adi bekleniyor');
      ExpectWord(Sql, pTest, '=');
      if not Tok(Sql, pTest, w2) then
        raise EVDbException.Create(ecSyntaxError, 'SET ... = <sayi> bekleniyor');
      if (UpperCase(w3) = 'SLOW') or (UpperCase(w3) = 'SLOW_QUERY_MS') then
        FSlowMs := StrToInt64Def(Trim(w2), -1)
      else if UpperCase(w3) = 'MAX_SLOW_ENTRIES' then
      begin
        FSlowMax := StrToIntDef(Trim(w2), 50);
        if FSlowMax < 1 then FSlowMax := 1;
      end
      else
        raise EVDbException.CreateFmt(ecSyntaxError, 'bilinmeyen ayar: "%s"', [w3]);
      Result.Affected := 1;
      Result.Msg := 'OK';
      Exit;
    end
    else if (w1 = 'OPEN') or (w1 = 'USE') then
    begin
      Result := ExecOpenDatabase(Sql, pTest);
      Exit;
    end
    else if w1 = 'CLOSE' then
    begin
      Result := ExecCloseDatabase(Sql, pTest);
      Exit;
    end
    else if w1 = 'BACKUP' then
    begin
      Result := ExecBackupTo(Sql, pTest);
      Exit;
    end
    else if w1 = 'MIGRATE' then
    begin
      if not Tok(Sql, pTest, w2) then
        raise EVDbException.Create(ecSyntaxError,
          'MIGRATE TO v3 ''<dosya>'' veya MIGRATE VERIFY ''<dosya>'' bekleniyor');
      w2 := UpperCase(w2);
      if w2 = 'VERIFY' then
        Result := ExecMigrateVerify(Sql, pTest)
      else if w2 = 'TO' then
        Result := ExecMigrateTo(Sql, pTest)
      else
        raise EVDbException.Create(ecSyntaxError,
          'MIGRATE VERIFY veya MIGRATE TO v3 bekleniyor (bulunan: ' + w2 + ')');
      Exit;
    end
    else if (w1 = 'CREATE') and Tok(Sql, pTest, w2) and (UpperCase(w2) = 'DATABASE') then
    begin
      Result := ExecCreateDatabase(Sql, pTest);
      Exit;
    end
    else if (w1 = 'DROP') and Tok(Sql, pTest, w2) and (UpperCase(w2) = 'DATABASE') then
    begin
      Result := ExecDropDatabase(Sql, pTest);
      Exit;
    end
    else if (w1 = 'DELETE') and Tok(Sql, pTest, w2) and (UpperCase(w2) = 'DATABASE') then
    begin
      // F1-15: DELETE DATABASE gercekte canli; eskiden DB-oncesi blokta
      // yoktu, AST'ye dusup syntax hatasi veriyordu. DROP ile ayni.
      Result := ExecDropDatabase(Sql, pTest);
      Exit;
    end;
  end;

  // H7 + P-CACHE (2026-10-30): PLAN ONBELLEGI. SELECT/INSERT/UPDATE/DELETE
  // tekrar geldiginde AST yeniden ayristirilmaz (parse maliyeti atlanir).
  // P-CACHE ile '?' / '$N' yer tutucularinin degerleri her calistirmada
  // ParamLits uzerinden guncellenir; boylece ayni plan farkli parametrelerle
  // yeniden kullanilir. Onbellekteki AST sahiplenilir; kullanimda Free EDILMEZ.
  cacheable := IsCacheableText(Sql);
  cacheKey := '';
  if cacheable then
  begin
    cacheKey := PlanCacheKey(Sql);
    if FPlanCache.TryGetValue(cacheKey, astStmt) then
    begin
      Inc(FPlanHits);
      // P-CACHE: yer tutucu degerlerini bu calistirma icin guncelle.
      // ParamIdx = -1 olan sabit literal'a dokunulmaz.
      if Length(FParams) > 0 then
        for i := 0 to astStmt.ParamLits.Count - 1 do
        begin
          lit := astStmt.ParamLits[i];
          if (lit.ParamIdx >= 0) and (lit.ParamIdx <= High(FParams)) then
            lit.StrVal := FParams[lit.ParamIdx];
        end;
      SlowMarkStart;
      try
        spanChild := VDbTraceBegin('sql.execute', spanRoot);
        VDbTraceSetCurrent(spanChild);
        try
          Result := FExecutor.Execute(astStmt);
        finally
          VDbTraceSetCurrent(nil);
          VDbTraceEnd(spanChild);
        end;
      finally
        FLastMs := ElapsedMs;
        NoteSlow(Sql, FLastMs, Length(Result.Rows));
        RecordCommand(Sql, FLastMs * 1000, 0);
      end;
      // Guvenlik agi: yurutucu AST'yi yerinde degistirdiyse (sonraki
      // calistirmalarda farkli bir yol tutulduysa) plan artik guvenilir
      // degildir; onbellegten cikar ki sonraki calistirma yeniden ayristsin.
      if FExecutor.StmtMutated then
        FPlanCache.Remove(cacheKey);
      Exit;
    end;
    Inc(FPlanMiss);
  end;
  spanChild := VDbTraceBegin('sql.parse', spanRoot);
  try
    astStmt := FParser.Parse(Sql, FParams);
  finally
    VDbTraceEnd(spanChild);
  end;
  try
    if astStmt = nil then Exit;
    // F-21: yavas sorgu olcumu. Parse DAHIL edilir (kullanicinin
    // bekledigi sure = ayristirma + yurutme).
    SlowMarkStart;
    try
      spanChild := VDbTraceBegin('sql.execute', spanRoot);
      VDbTraceSetCurrent(spanChild);
      try
        Result := FExecutor.Execute(astStmt);
      finally
        VDbTraceSetCurrent(nil);
        VDbTraceEnd(spanChild);
      end;
    finally
      FLastMs := ElapsedMs;
      NoteSlow(Sql, FLastMs, Length(Result.Rows));
      // R-24 (2026-10-13): ast gecen her cumle sure ile birlikte
      // global sayaclara yazilir (SHOW STATS bunlari okur). Hata
      // yolunda da kaydedilir (pg_stat benzeri: basarisiz cumleler
      // de sayilir). Sure F-21 ile AYNI olcumden turetilir (ms -> us).
      RecordCommand(Sql, FLastMs * 1000, 0);
    end;

    // H7 + P-CACHE: basarili + guvenli plani onbellege al (sahiplik aktarilir).
    //  - Yalniz DML/SELECT dugumleri (IsCacheableAst): 'WITH ... INSERT' gibi
    //    metin sezgisini yalanlayan durumlar burada ayiklanir.
    //  - Parametresiz DML onbellegi kirletmesin diye cache'lenmez; yalniz
    //    parametreli DML veya SELECT cache'lenir.
    //  - ParamsBoundOk = False ise bazi degerler literal OLMAYAN alanlara
    //    gomulmustur (LIMIT ?, tanimlayici, -? vb.); boyle AST yeniden
    //    kullanilamaz, cunku placeholder bolumu ayristirma sirasinda kaybolur.
    //  - StmtMutated = True ise yurutucu AST'yi yerinde degistirmistir
    //    (view yazimi, ON CONFLICT varsayilan esleme, CHECK katlama, govde
    //    sahiplik devri); boyle AST onbellege ALINMAZ.
    if cacheable and IsCacheableAst(astStmt) and FParser.ParamsBoundOk and
       (not FExecutor.StmtMutated) and
       ((Length(FParams) > 0) or (astStmt is TSqlSelectStmt)) then
    begin
      if FPlanCache.Count >= PLAN_CACHE_CAP then FPlanCache.Clear;
      if not FPlanCache.ContainsKey(cacheKey) then
      begin
        FPlanCache.Add(cacheKey, astStmt);
        astStmt := nil;   // sahiplik onbellege gecti; finally Free ETMEZ
      end;
    end
    else
    begin
      // H7: DDL sonrasi sema degismis olabilir -> plan onbellegi gecersiz
      pTest := 1;
      if Tok(Sql, pTest, w1) then
      begin
        w1 := UpperCase(w1);
        if (w1 = 'CREATE') or (w1 = 'DROP') or (w1 = 'ALTER') or
           (w1 = 'TRUNCATE') or (w1 = 'RENAME') then
          FPlanCache.Clear;
      end;
    end;
    Exit;
  finally
    if astStmt <> nil then astStmt.Free;
  end;
  // ------------------------------------------------------------
  // NOT (2026-10-02): Eski monolitik yol dosya altina tasindi.
  // AST Pipeline (ustteki blok) tum komutlari karsiliyor; asagidaki
  // VDB_LEGACY_OLDESECRAW_ARSIV blogu F3-1 ile SILINDI (bkz. asagida).
  // ------------------------------------------------------------
  finally
    VDbTraceEnd(spanRoot);
  end;
end;

  // F3-1: VDB_LEGACY_OLDESECRAW_ARSIV (1267 satir, `{$IF 0}` blogu) SILINDI.
  // Icerik birebir "VDbSql.ExecRaw icindeki eski monolitik yol" kopyasiydi;
  // hic derlenmiyordu ve HICBIR yordam/fonksiyon TANIMLAMIYORDU (yalnizca
  // ifade iceriyordu), bu yuzden referans denetimi yapilmadan guvenle
  // kaldirildi. Gerekirse git surumunden alinabilir.

end.




