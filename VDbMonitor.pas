unit VDbMonitor;

{ R-23: Diger motor birimleri gibi delphi modu (out parametreleri,
  varsayilan parametre degerleri ve record icinde anonim record dizisi
  icin). Bu satir olmadan `fpc` vakfa modda MonitorConfig(out C: ...)
  derlenmiyor. }
{$mode delphi}{$H+}

{ R-24 Monitoring — VDB motoru icin temel istatistik ve izleme.
  Bu birim kalici diske DOSYA.EDB (uydur).apnd
  kayitlari yazir ve baslangic, total komut sayisi, ortalama sutunlarla
  izleme servisine raporlar.

  Hedefler:
    - SQL komutu cagrisi (`VDbSql.Exec`), sureyi ve sonucu
      izlemek.
    - Rustumsuz dizin (`INSERT`lerle) ve parametreizi almak
      (tam veri, yalnizca sema kontrol etmez).

  Temizlik:
    - Okuma gunluge veziye gerek yok; yazma oncesi gunluge
      sadece client-side izi veri.

  Veri katmani (`VDbCore`, `VDbDataSet` vs.) bu birimi gunluge yazmak
  yerine bilgileri sanal bir arayuz’a toplayabilir.
}

interface

type
  TVDbMonitorConfig = record
    FileName: string;
    FlushIntervalMs: Integer;
    MaxBufferSize: Integer;
  end;

  TVDbMonitorStats = record
    CommandCount: UInt64;
    TotalDurationUs: UInt64;
    MaxDurationUs: UInt64;
  end;

  { R-15: Cost-Based Optimizer — tablo istatistikleri }
  TVDbTableStats = record
    TableName: string;
    RowCount: Int64;
    AvgRowLen: Integer;
    IndexCount: Integer;
    LastAnalyze: Int64;
    // Column stats (basit: kolon adı -> distinct count)
    ColStats: array of record
      ColName: string;
      DistinctCount: Int64;
      NullCount: Int64;
      MinVal: string;
      MaxVal: string;
    end;
  end;

type
  PTVDbMonitorConfig = ^TVDbMonitorConfig;
  PTVDbMonitorStats = ^TVDbMonitorStats;

// Dış API
function MonitorConfig(out C: TVDbMonitorConfig): Boolean;
function UpdateConfig(C: TVDbMonitorConfig): Boolean;
function RecordCommand(Sql: string; DurationUs: Integer; DBId: Integer): Boolean;
function GetStats(out S: TVDbMonitorStats): Boolean;
function FlushStats: Boolean;
function FlushBufferToFile: Boolean;
// R-15: Cost-Based Optimizer — tablo istatistikleri (genişletilmiş)
function RecordTableStats(const TableName: string; RowCount: Int64; AvgRowLen: Integer; IndexCount: Integer;
  const ColNames, ColDistinct, ColNulls, ColMins, ColMaxs: array of string): Boolean;
function GetTableStats(const TableName: string; out S: TVDbTableStats): Boolean;
// R-24: ANALYZE edilmis tekil tablo sayisi (SHOW STATS icin)
function AnalyzedTableCount: Integer;

implementation

uses SysUtils, Classes, VDbPlatform;

const
  VDB_MONITOR_FILE_EXT = '.edb';
  VDB_MONITOR_FILE_PREFIX = '.mon';

var
  GConfig: TVDbMonitorConfig;
  GStats: TVDbMonitorStats;
  GBuffer: TStringList;
  { R-15 Full: tablo istatistikleri komut gunlugu tamponundan AYRI tutulur.
    Aksi halde GBuffer MaxBufferSize'a ulasip FlushBufferToFile ile
    temizlendiginde ANALYZE istatistikleri kaybolur ve CBO deterministik
    olmaz. }
  GTableStats: TStringList;

function MonitorConfig(out C: TVDbMonitorConfig): Boolean;
begin
  Result := True;
  C := GConfig;
end;

function UpdateConfig(C: TVDbMonitorConfig): Boolean;
begin
  Result := True;
  GConfig := C;
end;

function RecordCommand(Sql: string; DurationUs: Integer; DBId: Integer): Boolean;
var
  ts: string;
begin
  Result := True;
  // R-24 (2026-10-13): global sayaclara kayit ARTIK GERCEK.
  // Not: burada bir onceki turda `if False` ile devre disi birakilmis
  // bir MUTASYON KALINTISI vardi (sayaclar hic artmiyordu, hicbir test
  // GStats'i gozlemlemedigi icin yagmurlu gun hatasi kalmisti). T105
  // (SHOW STATS) artik sayaclari dogrudan gozlemliyor.
  Inc(GStats.CommandCount);
  Inc(GStats.TotalDurationUs, DurationUs);
  if DurationUs > GStats.MaxDurationUs then GStats.MaxDurationUs := DurationUs;
  // Gunluk dosyasina YAZMA yalnizca acikca etkinlestirilmisken yapilir
  // (GConfig.FileName = '' iken tampanda '.mon.edb' adli bir dosya
  // olusurdu — test klasorlerine gereksiz dosya birakmamak icin).
  if GConfig.FileName <> '' then
  begin
    ts := IntToStr(VdbTickMs);
    GBuffer.Add(ts + '|' + IntToStr(DurationUs) + '|' + IntToStr(DBId) + '|' + Sql);
    if GBuffer.Count >= GConfig.MaxBufferSize then FlushBufferToFile;
  end;
end;

function GetStats(out S: TVDbMonitorStats): Boolean;
begin
  Result := True;
  S := GStats;
end;

function FlushStats: Boolean;
begin
  Result := True;
end;

function FlushBufferToFile: Boolean;
var
  fn: string;
  f: TextFile;
  i: Integer;
begin
  fn := GConfig.FileName + VDB_MONITOR_FILE_EXT;
  AssignFile(f, fn);
  if FileExists(fn) then
    Append(f)
  else
    Rewrite(f);
  for i := 0 to GBuffer.Count - 1 do
    Writeln(f, GBuffer[i]);
  CloseFile(f);
  GBuffer.Clear;
  Result := True;
end;

// R-15: Cost-Based Optimizer — tablo istatistikleri (genişletilmiş)
function RecordTableStats(const TableName: string; RowCount: Int64; AvgRowLen: Integer; IndexCount: Integer;
  const ColNames, ColDistinct, ColNulls, ColMins, ColMaxs: array of string): Boolean;
var
  ts: string;
  i: Integer;
  colStats: string;
begin
  Result := True;
  // Kolon istatistiklerini tek string'e paketle: col1:distinct,null,min,max;col2:...
  colStats := '';
  for i := 0 to High(ColNames) do
  begin
    if colStats <> '' then colStats := colStats + ';';
    colStats := colStats + Format('%s:%s,%s,%s,%s',
      [ColNames[i], ColDistinct[i], ColNulls[i], ColMins[i], ColMaxs[i]]);
  end;
  // Format: TableName|RowCount|AvgRowLen|IndexCount|LastAnalyze|ColStats
  GTableStats.Add(Format('TBLSTATS:%s|%d|%d|%d|%d|%s',
    [TableName, RowCount, AvgRowLen, IndexCount, VdbTickMs, colStats]));
end;

function GetTableStats(const TableName: string; out S: TVDbTableStats): Boolean;
var
  i, j: Integer;
  ts: string;
  parts, colParts, statParts: TStringList;
begin
  Result := False;
  S.TableName := '';
  S.RowCount := 0;
  S.AvgRowLen := 0;
  S.IndexCount := 0;
  S.LastAnalyze := 0;
  SetLength(S.ColStats, 0);

  for i := GTableStats.Count - 1 downto 0 do
  begin
    ts := GTableStats[i];
    if ts.StartsWith('TBLSTATS:') then
    begin
      ts := Copy(ts, 10, Length(ts) - 9);
      parts := TStringList.Create;
      try
        parts.Delimiter := '|';
        parts.DelimitedText := ts;
        if parts.Count >= 6 then
        begin
          if SameText(parts[0], TableName) then
          begin
            S.TableName := parts[0];
            S.RowCount := StrToIntDef(parts[1], 0);
            S.AvgRowLen := StrToIntDef(parts[2], 0);
            S.IndexCount := StrToIntDef(parts[3], 0);
            S.LastAnalyze := StrToInt64Def(parts[4], 0);

            // Parse column stats: col1:distinct,null,min,max;col2:...
            SetLength(S.ColStats, 0);
            colParts := TStringList.Create;
            try
              colParts.Delimiter := ';';
              colParts.DelimitedText := parts[5];
              SetLength(S.ColStats, colParts.Count);
              for j := 0 to colParts.Count - 1 do
              begin
                statParts := TStringList.Create;
                try
                  statParts.Delimiter := ':';
                  statParts.DelimitedText := colParts[j];
                  if statParts.Count >= 2 then
                  begin
                    S.ColStats[j].ColName := statParts[0];
                    statParts.Delimiter := ',';
                    statParts.DelimitedText := statParts[1];
                    // R-15: paket bicimi "distinct,null,min,max" = 4 alan.
                    // Eski kod >= 5 ariyordu; bu yuzden DistinctCount/NullCount
                    // HICBIR ZAMAN dolmuyordu (CBO secicilik = 0).
                    if statParts.Count >= 4 then
                    begin
                      S.ColStats[j].DistinctCount := StrToIntDef(statParts[0], 0);
                      S.ColStats[j].NullCount := StrToIntDef(statParts[1], 0);
                      S.ColStats[j].MinVal := statParts[2];
                      S.ColStats[j].MaxVal := statParts[3];
                    end;
                  end;
                finally
                  statParts.Free;
                end;
              end;
            finally
              colParts.Free;
            end;

            Result := True;
            Break;
          end;
        end;
      finally
        parts.Free;
      end;
    end;
  end;
end;

// R-24: ANALYZE edilmis tekil tablo sayisi (SHOW STATS: tables_analyzed)
function AnalyzedTableCount: Integer;
var
  i, p: Integer;
  ts, nm: string;
  seen: TStringList;
begin
  Result := 0;
  seen := TStringList.Create;
  try
    seen.Sorted := True;
    seen.Duplicates := dupIgnore;
    for i := 0 to GTableStats.Count - 1 do
    begin
      ts := GTableStats[i];
      if not ts.StartsWith('TBLSTATS:') then Continue;
      ts := Copy(ts, 10, Length(ts) - 9);
      p := Pos('|', ts);
      if p < 1 then Continue;
      nm := Copy(ts, 1, p - 1);
      if nm <> '' then seen.Add(nm);
    end;
    Result := seen.Count;
  finally
    seen.Free;
  end;
end;

initialization
  GBuffer := TStringList.Create;
  GTableStats := TStringList.Create;
  GConfig.FileName := '';
  GConfig.FlushIntervalMs := 5000;
  GConfig.MaxBufferSize := 1000;
  GStats.CommandCount := 0;
  GStats.TotalDurationUs := 0;
  GStats.MaxDurationUs := 0;

finalization
  GBuffer.Free;
  GTableStats.Free;

end.