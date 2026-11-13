unit VDbCost;

{ R-15 Full: Cost-Based Optimizer (CBO) — MALIYET MODELI.

  Bu birim SAF bir maliyet/karar modelidir; hicbir veri yapisina veya
  dosyaya erismez. Hem EXPLAIN planlayicisi (`VDbExecutor.ExecExplain`)
  hem de gercek satir secimi (`VDbExecutor.NarrowRows`) AYNI karar
  fonksiyonlarini kullanir; boylece plan metni ile yurutulen plan
  tutarlidir.

  Neden ayri birim?
    * Maliyet sabitleri ve secicilik formulleri tek yerde toplanir.
    * Model, AST'den bagimsiz olarak birim duzeyinde test edilebilir.
    * Mutasyon testi icin TEK karar noktasi (VdbIndexIsSelective) vardir.

  Model (PostgreSQL'in basitlestirilmis "seq_page_cost/random_page_cost"
  benzeri):
    - Sirali tarama: satir basina VDB_C_SEQ_ROW.
    - Indeks tarama: sabit acilis + satir basina probe + (index-only degilse)
      tabloya rastgele erisim (VDB_C_IDX_FETCH).
    - Indeks yalnizca tabloyu kapsiyorsa (index-only) rastgele erisim
      yoktur; bu yuzden cok daha secici olmayan durumlarda bile kazanir.

  Karar: bir indeks dilimi ancak toplam maliyeti sirali taramadan KUCUKSE
  kullanilir. Kaba sonuc: normal indekste ~%20, index-only'de ~%80
  secicilik esigi.
}

{$mode delphi}{$H+}

interface

uses SysUtils;

const
  // Varsayilan maliyet sabitleri (birim: "satir okuma esdegeri").
  VDB_C_SEQ_ROW   = 1.0;   // sirali tarama, satir basina
  VDB_C_IDX_PROBE = 1.0;   // indekste aralik acma / probe
  VDB_C_IDX_FETCH = 4.0;   // indeks -> tablo rastgele erisim
  VDB_C_IDX_ONLY  = 0.2;   // index-only: tabloya hic gidilmez

type
  { Planlayicinin secebilecegi tarama turleri. }
  TVdbPlanKind = (pkSeqScan, pkIndexScan, pkIndexOnlyScan, pkPkLookup);

  { Tek bir tarama/dugum icin maliyet tahmini. }
  TVdbCostEstimate = record
    Kind: TVdbPlanKind;
    EstRows: Double;      // beklenen cikti satiri
    StartupCost: Double;  // ilk satirdan once odenen maliyet
    TotalCost: Double;    // tum satirlar icin toplam maliyet
  end;

{ Bir esitlik (col = deger) kosulunun beklenen satir sayisi.
  DistinctCount <= 0 ise istatistik yok sayilir (RowCount/4 sezgisi). }
function VdbEstimateEqRows(RowCount, DistinctCount, NullCount: Int64): Double;

{ Sirali taramanin toplam maliyeti. }
function VdbSeqScanCost(RowCount: Int64): Double;

{ Indeks taramasinin toplam maliyeti. IndexOnly ise tabloya gidilmez. }
function VdbIndexScanCost(RowCount, EstRows: Int64; IndexOnly: Boolean): Double;

{ ---- TEK KARAR NOKTASI (mutasyon hedefi) ----
  Verilen satir sayisi ve tahmini eslesen satir icin indeks, sirali
  taramadan daha ucuz mu? }
function VdbIndexIsSelective(RowCount, EstRows: Int64; IndexOnly: Boolean): Boolean;

{ Kolon istatistiklerinden + kullanilabilir indeks bilgisinden tarama sec. }
function VdbChooseScan(RowCount, DistinctCount, NullCount: Int64;
  HasUsableIndex, IndexOnly: Boolean): TVdbCostEstimate;

{ Bilinen (mevcut indeksten olculen) eslesen satir sayisiyla tarama sec. }
function VdbChooseScanForRows(RowCount, EstRows: Int64;
  HasUsableIndex, IndexOnly: Boolean): TVdbCostEstimate;

{ Nested-loop JOIN'de LEFT (dis/driving tablo) solda mi olmali?
  Kucuk tablo dis tarafta olursa probe sayisi azalir. }
function VdbJoinOuterFirst(LeftRows, RightRows: Int64): Boolean;

function VdbPlanKindName(K: TVdbPlanKind): string;
function VdbFormatCost(const E: TVdbCostEstimate): string;

implementation

function VdbEstimateEqRows(RowCount, DistinctCount, NullCount: Int64): Double;
var
  d: Int64;
  nn: Int64;
begin
  if RowCount <= 0 then Exit(1.0);
  d := DistinctCount;
  if d <= 0 then
    d := RowCount div 4;   // istatistik yok: rowcount/4 sezgisi
  if d < 1 then d := 1;
  nn := RowCount - NullCount;
  if nn < 0 then nn := 0;
  Result := nn / d;
  if Result < 1.0 then Result := 1.0;
end;

function VdbSeqScanCost(RowCount: Int64): Double;
begin
  if RowCount < 0 then RowCount := 0;
  Result := RowCount * VDB_C_SEQ_ROW;
end;

function VdbIndexScanCost(RowCount, EstRows: Int64; IndexOnly: Boolean): Double;
var
  fetch: Double;
begin
  if RowCount < 0 then RowCount := 0;
  if EstRows < 0 then EstRows := 0;
  if IndexOnly then fetch := VDB_C_IDX_ONLY else fetch := VDB_C_IDX_FETCH;
  Result := VDB_C_IDX_PROBE + EstRows * (VDB_C_IDX_PROBE + fetch);
end;

function VdbIndexIsSelective(RowCount, EstRows: Int64; IndexOnly: Boolean): Boolean;
begin
  if RowCount <= 0 then Exit(True);
  { MUTASYON NOKTASI: asil karar. `if False then` yapildiginda Result
    varsayilan False'ta kalir (indeks HIC secilmez) ve CBO testleri duser. }
  if VdbIndexScanCost(RowCount, EstRows, IndexOnly) < VdbSeqScanCost(RowCount) then
    Result := True
  else
    Result := False;
end;

function VdbChooseScan(RowCount, DistinctCount, NullCount: Int64;
  HasUsableIndex, IndexOnly: Boolean): TVdbCostEstimate;
var
  est: Int64;
begin
  if RowCount <= 0 then RowCount := 1;
  Result.Kind := pkSeqScan;
  Result.EstRows := RowCount;
  Result.StartupCost := 0;
  Result.TotalCost := VdbSeqScanCost(RowCount);
  if not HasUsableIndex then Exit;

  Result.EstRows := VdbEstimateEqRows(RowCount, DistinctCount, NullCount);
  est := Round(Result.EstRows);
  if est < 1 then est := 1;

  if VdbIndexIsSelective(RowCount, est, IndexOnly) then
  begin
    if IndexOnly then Result.Kind := pkIndexOnlyScan
    else Result.Kind := pkIndexScan;
    Result.StartupCost := VDB_C_IDX_PROBE;
    Result.TotalCost := VdbIndexScanCost(RowCount, est, IndexOnly);
  end
  else
  begin
    Result.Kind := pkSeqScan;
    Result.EstRows := RowCount;
    Result.StartupCost := 0;
    Result.TotalCost := VdbSeqScanCost(RowCount);
  end;
end;

function VdbChooseScanForRows(RowCount, EstRows: Int64;
  HasUsableIndex, IndexOnly: Boolean): TVdbCostEstimate;
begin
  Result.Kind := pkSeqScan;
  Result.EstRows := RowCount;
  Result.StartupCost := 0;
  Result.TotalCost := VdbSeqScanCost(RowCount);
  if not HasUsableIndex then Exit;
  if EstRows < 1 then EstRows := 1;

  if VdbIndexIsSelective(RowCount, EstRows, IndexOnly) then
  begin
    if IndexOnly then Result.Kind := pkIndexOnlyScan
    else Result.Kind := pkIndexScan;
    Result.EstRows := EstRows;
    Result.StartupCost := VDB_C_IDX_PROBE;
    Result.TotalCost := VdbIndexScanCost(RowCount, EstRows, IndexOnly);
  end
  else
  begin
    Result.Kind := pkSeqScan;
    Result.EstRows := RowCount;
    Result.StartupCost := 0;
    Result.TotalCost := VdbSeqScanCost(RowCount);
  end;
end;

function VdbJoinOuterFirst(LeftRows, RightRows: Int64): Boolean;
begin
  if LeftRows < 0 then LeftRows := 0;
  if RightRows < 0 then RightRows := 0;
  Result := LeftRows <= RightRows;
end;

function VdbPlanKindName(K: TVdbPlanKind): string;
begin
  case K of
    pkIndexScan:     Result := 'Index Scan';
    pkIndexOnlyScan: Result := 'Index Only Scan';
    pkPkLookup:      Result := 'Index Scan';
    else             Result := 'Seq Scan';
  end;
end;

function VdbFormatCost(const E: TVdbCostEstimate): string;
var
  fs: TFormatSettings;
begin
  // Yerel ayardan BAGIMSIZ bicim: plan metni her platformda ayni olmali
  // (ondalik ayirici '.'; aksi halde TR locale'de 'cost=0,00' gorunurdu).
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := Format('(cost=%.2f..%.2f rows=%.0f)',
    [E.StartupCost, E.TotalCost, E.EstRows], fs);
end;

end.
