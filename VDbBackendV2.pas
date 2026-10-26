unit VDbBackendV2;

{ VDB v3 - v2 motorunu IVDbBackend'e saran adaptor (Sprint 2 / 2.2)

  Hicbir davranis eklemez: her cagriyi dogrudan TVDb'ye iletir. Amac,
  ust katmanin (VDbTable/VDbSql/VDbExecutor) artik SOMUT TVDb tipini
  tanimadan calisabilmesi ve v2 kapisinin (3112/3112) bozulmamasi.

  SAHIPLIK: adaptor TVDb'yi SERBEST BIRAKMAZ. TVDb'nin yasam dongusu
  bugunku gibi cagiranda kalir (Create/Free). Arayuz referans saymaz.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, VDbBackendApi, VDbCore;

type
  EVdbBackendV2 = class(Exception);

  TVDbBackendV2 = class(TInterfacedObject, IVDbBackend)
  private
    FDb: TVDb;
    FOwnsDb: Boolean;
  public
    constructor Create(ADb: TVDb);
    { VDbFactory icin: adaptor kapanirken TVDb'yi de kapatir/serbest
      birakir. Boylece uygulama kodu TVDb tipini hic tanimaz. }
    constructor CreateOwned(ADb: TVDb);
    destructor Destroy; override;
    property Db: TVDb read FDb;

    procedure Put(Key: QWord; const Value: TBytes);
    function Get(Key: QWord; out Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function Exists(Key: QWord): Boolean;
    function Count: Integer;

    procedure ScanAll(out Keys: TQWordArray; out Vals: TValArray;
      TableFilter: Integer = -1);
    function ScanRawIterAll(TableFilter: Integer;
      Cb: TVDbRawCb; User: Pointer): Boolean;
    { v3.3: v2'de sayfa numarali tarama yoktur; False = tam tarama. }
    function ScanRawIterAllPaged(TableFilter: Integer;
      Skip: PByte; SkipCount: Integer;
      Cb: TVDbRawPageCb; User: Pointer): Boolean;
    { v3.3: v2 zone map'i DataSeqValue/DataEpochValue ile calisir. }
    function DataStamp: QWord;
    function CountTable(TableFilter: Integer): Int64;
    { v3.2: v2'de AS OF mantiksal WAL kayitlari uzerinden VDbExecutor'da
      kurulur; burada anlik kopya yolu YOKTUR (False). }
    function ScanAllAt(TableFilter, Sequence: Integer;
      out Keys: TQWordArray; out Vals: TValArray;
      out ActualSequence: Integer): Boolean;
    function AsOfMaxSequence: Integer;

    procedure BeginBatch;
    procedure CommitBatch;
    procedure AbortBatch;
    procedure Flush;
    function GetInBatch: Boolean;
    function SoleWriter: Boolean;

    { v3.2: v2'de R-02 savepoint'leri TVDb'de WAL tabanlidir; aynen
      devredilir. Istisna mesajlari (ecDuplicateSavepoint /
      ecSavepointNotFound) yukari gecer. }
    procedure Savepoint(const Name: string);
    function RollbackToSavepoint(const Name: string): Boolean;
    function ReleaseSavepoint(const Name: string): Boolean;

    { v3.2: v2 kayit duzeyi anahtar rotasyonu (TVDb.RekeyWithPassword). }
    procedure Rekey(const NewPassword: string);

    function EnsureColumnKey: QWord;
    function ColumnKeyId: QWord;
    function ColumnKeyPath: string;
    function FileEncrypted: Boolean;
    procedure SetBeforeCommit(Proc: TDbCommitHook);
    function GetDirty: Boolean;
    procedure WaitForeignTxn(ASessionId: Cardinal);
    procedure RefreshBatchSnapshot;
    function GetFilePath: string;
    function GetIsReadOnly: Boolean;
    function GetBusyTimeoutMs: Integer;
    procedure SetRowTagFunc(AValue: TVDbRowTagFunc);

    { Sprint 3.1: v2 dosya butunlugu denetimi (TVDb.Verify'e devreder). }
    function Verify(out Report: string): Boolean;

    { Sprint 3.2: v2 TVDb.BackupTo / RestoreFrom'a devreder. }
    procedure BackupTo(const DestPath: string);
    procedure RestoreFrom(const SrcPath: string);

    { Sprint 3.3: v2 TVDb.Compact'a devreder. }
    procedure Compact(out OldBytes, NewBytes: Int64);

    { v3.2: v2 yonetim API'leri (H25 / olcum). }
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

    { v4: v2 motorunda mantiksal degisim gunlugu YOK. Deger yalan
      soylememek icin LogSupported=False; kapsam metotlari bos doner. }
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
    { v4 replikasyon: v2'de mantiksal gunluk yok. }
    function ReplSupported: Boolean;
    procedure ReplSuspendLog(ASuspend: Boolean);
    function ReplAppendGroup(const ARaw: TBytes; out AErr: string): Boolean;
  end;

implementation

constructor TVDbBackendV2.Create(ADb: TVDb);
begin
  inherited Create;
  if ADb = nil then
    raise EVdbBackendV2.Create('TVDbBackendV2: db nil');
  FDb := ADb;
  FOwnsDb := False;
end;

constructor TVDbBackendV2.CreateOwned(ADb: TVDb);
begin
  Create(ADb);
  FOwnsDb := True;
end;

destructor TVDbBackendV2.Destroy;
begin
  if FOwnsDb and (FDb <> nil) then
  begin
    try
      FDb.Close;
    except
      { Kapanis hatasi yikiciyi durdurmaz; asil veri zaten dosyada. }
    end;
    FreeAndNil(FDb);
  end;
  inherited Destroy;
end;

procedure TVDbBackendV2.Put(Key: QWord; const Value: TBytes);
begin
  FDb.Put(Key, Value);
end;

function TVDbBackendV2.Get(Key: QWord; out Value: TBytes): Boolean;
begin
  Result := FDb.Get(Key, Value);
end;

function TVDbBackendV2.Delete(Key: QWord): Boolean;
begin
  Result := FDb.Delete(Key);
end;

function TVDbBackendV2.Exists(Key: QWord): Boolean;
begin
  Result := FDb.Exists(Key);
end;

function TVDbBackendV2.Count: Integer;
begin
  Result := FDb.Count;
end;

procedure TVDbBackendV2.ScanAll(out Keys: TQWordArray; out Vals: TValArray;
  TableFilter: Integer);
begin
  FDb.ScanAll(Keys, Vals, TableFilter);
end;

function TVDbBackendV2.ScanRawIterAll(TableFilter: Integer;
  Cb: TVDbRawCb; User: Pointer): Boolean;
begin
  Result := FDb.ScanRawIterAll(TableFilter, Cb, User);
end;

function TVDbBackendV2.ScanRawIterAllPaged(TableFilter: Integer;
  Skip: PByte; SkipCount: Integer;
  Cb: TVDbRawPageCb; User: Pointer): Boolean;
begin
  { v2 veri dosyasi sayfa numarasi sunmaz; cagiran tam taramaya duser. }
  Result := False;
end;

function TVDbBackendV2.DataStamp: QWord;
begin
  { v2 zone map damgasi: veri seq + epoch. }
  Result := (QWord(FDb.DataEpochValue) shl 32) or
    QWord(FDb.DataSeqValue);
end;

function TVDbBackendV2.CountTable(TableFilter: Integer): Int64;
begin
  { v2'de dogrulanmis COUNT onbellegi TVDb tarafindadir (KR-1B);
    burada O(1) bir kaynak yok. Cagiran tam tarama yapar. }
  Result := -1;
end;

function TVDbBackendV2.ScanAllAt(TableFilter, Sequence: Integer;
  out Keys: TQWordArray; out Vals: TValArray;
  out ActualSequence: Integer): Boolean;
begin
  { v2: mantiksal WAL gunlugu VDbExecutor.BuildAsOfRows'ta okunur; sayfa
    imaji kopyasi gerekmez. Cagiran eski yolu kullanir. }
  Keys := nil;
  Vals := nil;
  ActualSequence := 0;
  Result := False;
end;

function TVDbBackendV2.AsOfMaxSequence: Integer;
begin
  { v2 AS OF SEQUENCE: 0 tabanli WAL kayit indeksi (WalRecordCount-1'e kirpilir). }
  Result := FDb.WalRecordCount;
end;

procedure TVDbBackendV2.BeginBatch;
begin
  FDb.BeginBatch;
end;

procedure TVDbBackendV2.CommitBatch;
begin
  FDb.CommitBatch;
end;

procedure TVDbBackendV2.AbortBatch;
begin
  FDb.AbortBatch;
end;

procedure TVDbBackendV2.Flush;
begin
  FDb.Flush;
end;

function TVDbBackendV2.GetInBatch: Boolean;
begin
  Result := FDb.InBatch;
end;

function TVDbBackendV2.SoleWriter: Boolean;
begin
  { v2 tek yazicidir (dosya kilidi); coklu yazma islemi yoktur. }
  Result := True;
end;

procedure TVDbBackendV2.Savepoint(const Name: string);
begin
  FDb.Savepoint(Name);
end;

function TVDbBackendV2.RollbackToSavepoint(const Name: string): Boolean;
begin
  { v2 TVDb bulunamayan savepoint icin istisna firlatir; burada da
    istisna YUKARI GECER (sozlesme: ayni davranis). }
  FDb.RollbackToSavepoint(Name);
  Result := True;
end;

function TVDbBackendV2.ReleaseSavepoint(const Name: string): Boolean;
begin
  FDb.ReleaseSavepoint(Name);
  Result := True;
end;

procedure TVDbBackendV2.Rekey(const NewPassword: string);
begin
  FDb.RekeyWithPassword(NewPassword);
end;

function TVDbBackendV2.EnsureColumnKey: QWord;
begin
  Result := FDb.EnsureColumnKey;
end;

function TVDbBackendV2.ColumnKeyId: QWord;
begin
  Result := FDb.ColumnKeyId;
end;

function TVDbBackendV2.ColumnKeyPath: string;
begin
  Result := FDb.ColumnKeyPath;
end;

function TVDbBackendV2.FileEncrypted: Boolean;
begin
  { v2: kayit seviyesi anahtar yuklu ise degerler sifreli yazilir. }
  Result := FDb.IsEncrypted;
end;

procedure TVDbBackendV2.SetBeforeCommit(Proc: TDbCommitHook);
begin
  FDb.SetBeforeCommit(Proc);
end;

procedure TVDbBackendV2.SetRowTagFunc(AValue: TVDbRowTagFunc);
begin
  FDb.RowTagFunc := AValue;
end;

function TVDbBackendV2.GetDirty: Boolean;
begin
  Result := FDb.Dirty;
end;

procedure TVDbBackendV2.WaitForeignTxn(ASessionId: Cardinal);
begin
  FDb.WaitForeignTxn(ASessionId);
end;

procedure TVDbBackendV2.RefreshBatchSnapshot;
begin
  FDb.RefreshBatchSnapshot;
end;

function TVDbBackendV2.GetFilePath: string;
begin
  Result := FDb.FilePath;
end;

{ v3.2: v2 motorunda salt-okunur / busy timeout kavrami bu sozlesmede yok.
  v2 zaten yalniz goc ve eski dosya okumasi icin kullanilir. }
function TVDbBackendV2.GetIsReadOnly: Boolean;
begin
  Result := False;
end;

function TVDbBackendV2.GetBusyTimeoutMs: Integer;
begin
  Result := 0;
end;

function TVDbBackendV2.Verify(out Report: string): Boolean;
begin
  Result := FDb.Verify(Report);
end;

procedure TVDbBackendV2.BackupTo(const DestPath: string);
begin
  FDb.BackupTo(DestPath);
end;

procedure TVDbBackendV2.RestoreFrom(const SrcPath: string);
begin
  FDb.RestoreFrom(SrcPath);
end;

procedure TVDbBackendV2.Compact(out OldBytes, NewBytes: Int64);
begin
  FDb.Compact(OldBytes, NewBytes);
end;

{ --- v3.2: v2 yonetim API'leri --- }

function TVDbBackendV2.GetDeadBytes: Int64;
begin
  Result := FDb.DeadBytes;
end;

function TVDbBackendV2.GetDataFileSize: Int64;
begin
  Result := FDb.DataFileSize;
end;

function TVDbBackendV2.GetAutoCompactEnabled: Boolean;
begin
  Result := FDb.AutoCompactEnabled;
end;

procedure TVDbBackendV2.SetAutoCompactEnabled(AValue: Boolean);
begin
  FDb.AutoCompactEnabled := AValue;
end;

function TVDbBackendV2.GetAutoCompactRatio: Double;
begin
  Result := FDb.AutoCompactRatio;
end;

procedure TVDbBackendV2.SetAutoCompactRatio(AValue: Double);
begin
  FDb.AutoCompactRatio := AValue;
end;

function TVDbBackendV2.GetAutoCompactMinBytes: Int64;
begin
  Result := FDb.AutoCompactMinBytes;
end;

procedure TVDbBackendV2.SetAutoCompactMinBytes(AValue: Int64);
begin
  FDb.AutoCompactMinBytes := AValue;
end;

function TVDbBackendV2.GetAutoCompactCount: Int64;
begin
  Result := FDb.AutoCompactCount;
end;

function TVDbBackendV2.GetLastAutoCompactError: string;
begin
  Result := FDb.LastAutoCompactError;
end;
function TVDbBackendV2.AutoCompact(out OldBytes, NewBytes: Int64;
  MaxDeadRatio: Double; MinBytes: Int64): Boolean;
begin
  Result := FDb.AutoCompact(OldBytes, NewBytes, MaxDeadRatio, MinBytes);
end;

{ ---------------------------------------- v4: gunluk / PITR (v2: YOK) }

function TVDbBackendV2.LogSupported: Boolean;
begin
  Result := False;
end;

function TVDbBackendV2.LogStatus: string;
begin
  Result := 'v2 motorunda mantiksal degisim gunlugu yok';
end;

function TVDbBackendV2.LogRangeInfo(out MinSeq, MaxSeq: Int64;
  out MinTsMs, MaxTsMs: Int64; out BaseCount: Integer): Boolean;
begin
  MinSeq := 0;
  MaxSeq := 0;
  MinTsMs := 0;
  MaxTsMs := 0;
  BaseCount := 0;
  Result := False;
end;

function TVDbBackendV2.BuildLogSnapshot(TimestampMs, Version: Int64;
  const DestPath: string;
  out ActualTsMs, ActualSeq: Int64): Boolean;
begin
  ActualTsMs := 0;
  ActualSeq := 0;
  Result := False;
  raise EVdbBackendV2.Create(
    'PITR: v2 motorunda mantiksal degisim gunlugu yok; ' +
    'yalniz AS OF SEQUENCE desteklenir');
end;

function TVDbBackendV2.ScanAllAtLogTime(TableFilter: Integer;
  TimestampMs, Version: Int64;
  out Keys: TQWordArray; out Vals: TValArray;
  out ActualTsMs, ActualSeq: Int64): Boolean;
begin
  Keys := nil;
  Vals := nil;
  ActualTsMs := 0;
  ActualSeq := 0;
  Result := False;
end;

function TVDbBackendV2.ArchiveLogSet(const DestDir: string): Int64;
begin
  Result := 0;
  raise EVdbBackendV2.Create(
    'ARCHIVE WAL: v2 motorunda mantiksal degisim gunlugu yok');
end;

{ v4 replikasyon: v2'de mantiksal gunluk yok; v2 kendi WAL-tasima
  replikasyonunu (VDbReplication) kullanmaya devam eder. }
function TVDbBackendV2.ReplSupported: Boolean;
begin
  Result := False;
end;

procedure TVDbBackendV2.ReplSuspendLog(ASuspend: Boolean);
begin
  { Etkisiz: v2'nin gunlugu yok. }
end;

function TVDbBackendV2.ReplAppendGroup(const ARaw: TBytes;
  out AErr: string): Boolean;
begin
  AErr := 'REPLICATION: v2 motorunda mantiksal gunluk yok';
  Result := False;
end;

end.
