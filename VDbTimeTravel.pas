unit VDbTimeTravel;

{ VDb Time Travel / Snapshot - Motor Katmani
  ---------------------------------------------------------------------------
  WAL (.wal) gecmisindekiOnceki degerlere erisim saglar.

  2026-10-05 ONARIM:
    Bu birim HIC DERLENEMIYORDU: `FTb.Kv.ScanWal`, `FTb.Kv.FWalEntries`,
    `TWalEntryArray` diye bir API yoktu (uydurulmus/kopuk kod). Simdi
    gercek API baglandi: `TVDb.ReadWalEntry` + `TVDb.WalRecordCount`.

  DOSRUSTLUK (sinirlar - gizlenmez):
    * WAL yalnizca SON CHECKPOINT'TEN SONRAKI yazilari tutar. Yani
      gecmis SINIRLIDIR; "tarihin tamami" DEGILDIR. Checkpoint/WAL
      temizligi sonrasi eski degerlere erisilemez.
    * WAL girdilerinin sirasi icin `Seq` = WAL kayit INDEKSIdir
      (0 tabanli, 0 .. WalRecordCount-1). KAYITLARIN Seq'si YOKTUR.
    * `SELECT ... AS OF SEQUENCE <n>` 06.10.2026'da SQL parser'a
      baglandi (VDbExecutor.BuildAsOfRows; ayrinti SQL.md -> §0b).
      TIMESTAMP/VERSION hala bilerek `ecUnsupported` verir (WAL'de ne
      zaman damgasi ne surum vardir); `ParseSnapshotSpec` yalnizca
      metni dogrular. `ExecSnapshot` aktif snapshot'ta acik hata verir
      (sessizce yanlis cevap donmez).
  }

{$mode delphi}
interface

uses
  Classes, SysUtils, VDbCore, VDbTable, VDbSql;

type
  TSnapshotMode = (smNone, smTimestamp, smVersion, smSequence);

  TSnapshotSpec = record
    Mode: TSnapshotMode;
    Timestamp: TDateTime;  // smTimestamp icin
    Version: QWord;        // smVersion icin
    Sequence: QWord;       // smSequence icin
  end;

  TVTimeTravel = class
  private
    FTb: TVTableDb;
    FSnapshot: TSnapshotSpec;
    FActive: Boolean;
  public
    constructor Create(const ATb: TVTableDb);
    destructor Destroy; override;

    procedure BeginSnapshot(const ASpec: TSnapshotSpec);
    procedure EndSnapshot;

    { AS OF sorgusu: aktif snapshot varsa DESTEKLENMEDIIGINI acikca
      soyler (ecUnsupported). Snapshot'siz calistirilirsa normal SQL'dir. }
    function ExecSnapshot(const Sql: string): TSqlResult;

    { WAL gecmisinde `Seq` indeksine kadar olan en SON yazimi dondurur
      (satir kodlamasi ham baytlar halinde; cozmek icin GetRowAt).
      Bulunamazsa / o noktada silinmisse BOS doner. }
    function GetValueAt(const Table: string; const PK: string;
      const Seq: QWord): TBytes;

    { Ayni sorgu, satir olarak cozulmus hali. }
    function GetRowAt(const Table: string; const PK: string;
      const Seq: QWord; out Vals: TStrArray): Boolean;

    { WAL'de okunabilir gecmis kayit sayisi (0 = gecmis yok). }
    function HistoryCount: Integer;

    property Active: Boolean read FActive;
    property Snapshot: TSnapshotSpec read FSnapshot;
  end;

  { SQL metnindeki AS OF ... ifadesini cozer (parser entegrasyonu YOK). }
  function ParseSnapshotSpec(const Sql: string; out Spec: TSnapshotSpec): Boolean;

implementation

uses
  VDbErr, DateUtils;

constructor TVTimeTravel.Create(const ATb: TVTableDb);
begin
  inherited Create;
  FTb := ATb;
  FActive := False;
  FillChar(FSnapshot, SizeOf(TSnapshotSpec), 0);
  FSnapshot.Mode := smNone;
end;

destructor TVTimeTravel.Destroy;
begin
  EndSnapshot;
  inherited Destroy;
end;

procedure TVTimeTravel.BeginSnapshot(const ASpec: TSnapshotSpec);
begin
  if FActive then EndSnapshot;
  FSnapshot := ASpec;
  FActive := True;
end;

procedure TVTimeTravel.EndSnapshot;
begin
  FActive := False;
  FillChar(FSnapshot, SizeOf(TSnapshotSpec), 0);
  FSnapshot.Mode := smNone;
end;

function TVTimeTravel.ExecSnapshot(const Sql: string): TSqlResult;
var
  sq: TVSql;
begin
  if FActive then
    raise EVDbException.Create(ecUnsupported,
      'TimeTravel: aktif snapshot modunda SQL calistirilamaz - ' +
      'SELECT ... AS OF SEQUENCE veya GetValueAt/GetRowAt ile oku');
  sq := TVSql.Create(FTb);
  try
    Result := sq.Exec(Sql);
  finally
    sq.Free;
  end;
end;

function TVTimeTravel.HistoryCount: Integer;
begin
  try
    Result := FTb.Kv.WalRecordCount;
  except
    Result := 0;
  end;
end;

function TVTimeTravel.GetValueAt(const Table: string; const PK: string;
  const Seq: QWord): TBytes;
var
  key: QWord;
  i, cnt: Integer;
  k: QWord;
  f: Byte;
  v: TBytes;
begin
  SetLength(Result, 0);
  key := VDbHashKey(Table, PK);
  cnt := HistoryCount;
  for i := 0 to cnt - 1 do
  begin
    if QWord(i) > Seq then Break;
    if not FTb.Kv.ReadWalEntry(i, k, f, v) then Break;
    if k <> key then Continue;
    if f = VDB_FLAG_DEL then
    begin
      { o indekse kadar silinmis }
      SetLength(Result, 0);
      Exit;
    end;
    Result := Copy(v, 0, Length(v));
  end;
end;

function TVTimeTravel.GetRowAt(const Table: string; const PK: string;
  const Seq: QWord; out Vals: TStrArray): Boolean;
var
  b: TBytes;
  tid: Word;
  pk2: string;
begin
  SetLength(Vals, 0);
  b := GetValueAt(Table, PK, Seq);
  if Length(b) = 0 then
  begin
    Result := False;
    Exit;
  end;
  Result := FTb.DecodeRowDataPublic(b, tid, pk2, Vals);
  if Result and (pk2 <> PK) then
    Result := False;   // hash carpismasi / tablo adi yanlis
end;

function ParseSnapshotSpec(const Sql: string; out Spec: TSnapshotSpec): Boolean;
var
  upperSql: string;
  p, p2: Integer;
  s: string;
  n: Int64;
  fs: TFormatSettings;
  dt: TDateTime;
begin
  Result := False;
  FillChar(Spec, SizeOf(TSnapshotSpec), 0);
  Spec.Mode := smNone;
  upperSql := UpperCase(Sql);

  { AS OF TIMESTAMP '2026-01-15 10:30:00' }
  p := Pos('AS OF TIMESTAMP', upperSql);
  if p > 0 then
  begin
    s := Trim(Copy(Sql, p + Length('AS OF TIMESTAMP'), Length(Sql)));
    if (Length(s) >= 2) and (s[1] = '''') then
    begin
      p2 := Pos('''', Copy(s, 2, Length(s)));
      if p2 > 0 then
        s := Copy(s, 2, p2 - 1)
      else
        s := '';
    end;
    if s <> '' then
    begin
      { ISO bicim once denenir ('2026-01-15 10:30:00'); sistem ayari
        (tr: gg.aa.yyyy) bunu kabul etmez. Sonra yerel ayar denenir. }
      fs := DefaultFormatSettings;   // kopya; ustune ISO yaziyoruz
      fs.DateSeparator := '-';
      fs.ShortDateFormat := 'yyyy-mm-dd';
      fs.LongDateFormat := 'yyyy-mm-dd';
      fs.TimeSeparator := ':';
      fs.ShortTimeFormat := 'hh:nn:ss';
      fs.LongTimeFormat := 'hh:nn:ss';
      if TryStrToDateTime(s, dt, fs) or TryStrToDateTime(s, dt) then
      begin
        Spec.Timestamp := dt;
        Spec.Mode := smTimestamp;
        Exit(True);
      end;
    end;
    Exit(False);
  end;

  { AS OF VERSION N }
  p := Pos('AS OF VERSION', upperSql);
  if p > 0 then
  begin
    s := Trim(Copy(Sql, p + Length('AS OF VERSION'), Length(Sql)));
    if TryStrToInt64(s, n) and (n >= 0) then
    begin
      Spec.Version := QWord(n);
      Spec.Mode := smVersion;
      Exit(True);
    end;
    Exit(False);
  end;

  { AS OF SEQUENCE N }
  p := Pos('AS OF SEQUENCE', upperSql);
  if p > 0 then
  begin
    s := Trim(Copy(Sql, p + Length('AS OF SEQUENCE'), Length(Sql)));
    if TryStrToInt64(s, n) and (n >= 0) then
    begin
      Spec.Sequence := QWord(n);
      Spec.Mode := smSequence;
      Exit(True);
    end;
    Exit(False);
  end;
end;

end.
