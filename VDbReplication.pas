unit VDbReplication;

{ R-17 Streaming Replication — WAL log-shipping + GERCEK TCP akisi (tam)

  Tasarim notu
  -----------
  Proje kurali "harici DLL yok, saf FPC" oldugu icin log-shipping
  modu agsiz ve deterministiktir (ag asagida). Tasima adimi:

    Primary: WALEnabled + Archive dizin acik. Her segment dolunca
             <base>_NNNNNNNN.wal arsive tasinir.
             `WalShipOnce` arsivdeki YENI segmentleri "ship" (hedef)
             dizinine kopyalar. Bu, streaming'in tasima adimidir.

    Standby: `WalApplyOnce` ship dizinindeki, daha once uygulanmamis
             segmentleri `TVDb.ApplyWalSegmentFile` ile kendi .odb'sine
             uygular. Bu, streaming'in uygulama adimidir.

  Gercek thread'li/ag'li dongu icin ayni iki adim bir arka plan
  thread'inde periyodik cagrilir (WalSenderLoop / WalReceiverLoop).
  Bu birim thread BASLATMAZ; `PUMP REPLICATION` ile adim SQL'den
  deterministik olarak tetiklenir (test edilebilirlik).

  Replikasyon slotlari kalicidir: `<DataDir>/.replslots` dosyasinda
  slot adi | restartLSN | confirmedLSN | active olarak saklanir.

  ---- R-17 FULL (2026-10-13): GERCEK TCP AKISI (VDbNet) ----
  Primary: `TVdbWalSenderThread` (START REPLICATION PRIMARY TCP
  PORT n SLOT 's') dinleme soketi acar, baglanan alicilarla el
  sikisir ve arsivdeki RestartLSN'den buyuk segmentleri protokolle
  AKITIR; her segmentten sonra ACK bekler. Motor DIKKATE ALINMAZ:
  yalnizca arsiv DOSYALARI okunur, primary SQL'e acik kalir.
  Standby: `TVdbWalReceiverThread` (START REPLICATION STANDBY TCP
  HOST 'h' PORT n SLOT 's') primary'ye baglanir, segmentleri alir,
  CRC32 dogrular ve `ApplyWalSegmentFile` ile aninda uygular. Akis
  sirasinda standby MOTORU BU THREAD'E AITTIR: baska cumle reddedilir
  (once STOP REPLICATION).
  Protokol: 'VDBR' magic + u32 surum el sikismasi; SEGMENT mesaji
  (ad, no, crc32, uzunluk, veri) + ACK (dogrulanmis LSN); boslukta
  HEARTBEAT; kapanista END.
  TCP thread'leri GLOBAL slot durumunu degil KENDI slot dosyasini
  (parametre) kullanir: ayni surecte bir primary ve bir standby
  AYNI ANDA akabilir (test tam boyle yapiyor). }

{$mode delphi}{$H+}

interface

uses SysUtils, Classes, VDbCore, VDbTypes, VDbNet, VDbCrc32;

type
  { Replikasyon rolleri }
  TReplicationRole = (rrNone, rrPrimary, rrStandby);

  { Replikasyon slotu. RestartLSN primary tarafinda en son GONDERILEN
    segment numarasi; ConfirmedLSN standby tarafinda en son UYGULANAN
    segment numarasidir. }
  TReplSlot = record
    SlotName: string;
    RestartLSN: Int64;
    ConfirmedLSN: Int64;
    Active: Boolean;
  end;

  TReplSlotArray = array of TReplSlot;

  { WAL gonderici/alıcı durumu }
  TReplicationState = record
    Role: TReplicationRole;
    PrimaryConnInfo: string;   // standby: ship dizini (primary arsivi)
    SlotName: string;          // replication slot adi
    LastLSN: Int64;            // son islenen segment (LSN)
    IsRunning: Boolean;
    ShippedCount: Integer;     // primary: gonderilen segment sayisi
    AppliedCount: Integer;     // standby: uygulanan segment sayisi
  end;

var
  GReplicationState: TReplicationState;

{ ---- Rol / durum ---- }
function StartReplicationPrimary(const SlotName, DestDir: string): Boolean;
function StartReplicationStandby(const ConnInfo, SlotName: string): Boolean;
function StopReplication: Boolean;
function GetReplicationStatus(out State: TReplicationState): Boolean;

{ ---- Slot yonetimi (kalici) ---- }
procedure SetReplicationDataDir(const ADir: string);
function GetReplicationDataDir: string;
function CreateReplicationSlot(const SlotName: string): Boolean;
function DropReplicationSlot(const SlotName: string): Boolean;
function GetReplicationSlots: TReplSlotArray;
function FindReplicationSlot(const SlotName: string; out Slot: TReplSlot): Boolean;
function UpdateReplicationSlot(const Slot: TReplSlot): Boolean;
procedure SaveReplicationSlots;
procedure LoadReplicationSlots;

{ ---- Segment yardimcilari ---- }
{ 'foo_00000007.wal' -> 7 ; segment no yoksa 0. }
function SegmentNoOfFile(const AFileName: string): Int64;
{ Dizindeki tum *.wal dosyalarini (tam yol) segment numarasina gore
  ARTAN sirada dondurur. }
function ArchiveSegmentFiles(const ADir: string): TStrArray;

{ ---- Asil log-shipping adimlari ---- }
{ Primary: ArchiveDir'deki, DestDir'de HENUZ olmayan segmentleri
  kopyalar. Slot.RestartLSN'i gunceller. Doner: basarili mi. }
function WalShipOnce(const ArchiveDir, DestDir, SlotName: string;
  out Shipped: Integer): Boolean;

{ Standby: SrcDir'deki, slot.ConfirmedLSN'den BUYUK numarali
  segmentleri ADb'ye uygular. Slot.ConfirmedLSN'i gunceller. }
function WalApplyOnce(ADb: TVDb; const SrcDir, SlotName: string;
  out Applied: Integer): Boolean;

{ Rol'e gore tek adim calistirir (SQL `PUMP REPLICATION`).
  Primary: shipDir'e gonderir; Standby: connInfo'dan uygular. }
function PumpReplication(ADb: TVDb; const ShipDir: string;
  out Count: Integer; out Msg: string): Boolean;

{ ==================== R-17 FULL: GERCEK TCP AKISI ==================== }

type
  { TCP WAL gonderici (primary tarafi). Arsiv dizinini dinler; baglanan
    alicilarla el sikisir ve RestartLSN'den buyuk arsiv segmentlerini
    protokolle akitar. Gonderici motoru HIC kullanmaz: yalnizca arsiv
    DOSYALARINI okur; primary, akis sirasinda SQL'e acik kalir. }
  TVdbWalSenderThread = class(TThread)
  private
    FPort: Word;
    FArchiveDir: string;
    FSlotName: string;
    FSlotFile: string;
    FListen: TVdbSocket;
    FClient: TVdbSocket;
    FAccepted: Integer;
    FSent: Integer;
    FLastErr: string;
    function ServeClient(ASock: TVdbSocket): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Word; const AArchiveDir, ASlotName,
      ASlotFile: string);
    { Terminate + dinleme/istemci soketlerini uyandir (kapanislari
      thread kendisi yapar). }
    procedure Stop;
    { Dinleme soketi kurulmus mu? (Execute'in ilk isi budur; kurulum
      basarisizsa thread hatayla biter.) }
    function ListenReady: Boolean;
    property Accepted: Integer read FAccepted;
    property Sent: Integer read FSent;
    property LastError: string read FLastErr;
    property Port: Word read FPort;
    property SlotName: string read FSlotName;
  end;

  { TCP WAL alicisi (standby tarafi). Primary'ye baglanir, segmentleri
    alir, CRC32 dogrular ve motor uzerinde aninda uygular. AKIS
    SIRASINDA MOTOR BU THREAD'E AITTIR: ayni motor uzerinde baska
    yurutucu cumlesi calistirilamaz (STOP REPLICATION ile birakilir). }
  TVdbWalReceiverThread = class(TThread)
  private
    FHost: string;
    FPort: Word;
    FSlotName: string;
    FSlotFile: string;
    FInboxDir: string;
    FDb: TVDb;
    FSock: TVdbSocket;
    FApplied: Integer;
    FLastErr: string;
    FConnected: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ADb: TVDb; const AHost: string; APort: Word;
      const ASlotName, ASlotFile: string);
    procedure Stop;
    property Applied: Integer read FApplied;
    property Connected: Boolean read FConnected;
    property LastError: string read FLastErr;
    property Host: string read FHost;
    property Port: Word read FPort;
    property SlotName: string read FSlotName;
  end;

{ Bu DB icin TCP GONDERICI baslatir. Arsiv dizini bossa False doner
  (once ARCHIVE WAL SET gerekir). }
function StartTcpSender(ADb: TVDb; APort: Word; const ASlotName: string;
  out AErr: string): Boolean;

{ Bu DB'yi (standby) TCP ALICIYA devreder. Zaten aktifse False. }
function StartTcpReceiver(ADb: TVDb; const AHost: string; APort: Word;
  const ASlotName: string; out AErr: string): Boolean;

{ Bu DB'ye bagli TCP gonderici/aliciyi durdurur ve kaydi siler.
  Aktif kayit yoksa False. }
function StopTcpForDb(ADb: TVDb): Boolean;

{ DB bir TCP alicisinin elinde mi (akista mi)? }
function IsStreamingDb(ADb: TVDb): Boolean;

{ SHOW REPLICATION STATUS icin bu DB'nin TCP durumu. Kayit yoksa
  False; varsa rol, slot ve bilgi dizgisi dolar. }
function TcpReplStatus(ADb: TVDb; out AIsPrimary: Boolean;
  out ASlot, AInfo: string): Boolean;

{ Bu DB'ye bagli herhangi bir TCP gonderici/alici aktif mi? }
function TcpActiveForDb(ADb: TVDb): Boolean;

{ Test/izleme yardimcisi: bu DB'nin TCP alicisi su ana dek kac segment
  uyguladi? Alici kayitli degilse -1. }
function TcpRecvApplied(ADb: TVDb): Integer;

{ Tanimlama yardimcisi: bu DB'nin gonderici/alicisi bir hata ile
  durum bildirdiyse mesaji (yoksa ''). }
function TcpLastError(ADb: TVDb): string;

implementation

var
  GDataDir: string;      // slot dosyasi icin
  GSlots: TReplSlotArray;
  GSlotsLoaded: Boolean;

function SlotFilePath: string;
begin
  if GDataDir = '' then
    Result := '.replslots'
  else
    Result := IncludeTrailingPathDelimiter(GDataDir) + '.replslots';
end;

procedure InternLoadSlots;
var
  f: TextFile;
  line: string;
  parts: TStringList;
  n: Integer;
begin
  SetLength(GSlots, 0);
  if not FileExists(SlotFilePath) then Exit;
  AssignFile(f, SlotFilePath);
  Reset(f);
  try
    while not Eof(f) do
    begin
      Readln(f, line);
      if Trim(line) = '' then Continue;
      parts := TStringList.Create;
      try
        parts.Delimiter := '|';
        parts.DelimitedText := line;
        if parts.Count >= 4 then
        begin
          n := Length(GSlots);
          SetLength(GSlots, n + 1);
          GSlots[n].SlotName := parts[0];
          GSlots[n].RestartLSN := StrToInt64Def(parts[1], 0);
          GSlots[n].ConfirmedLSN := StrToInt64Def(parts[2], 0);
          GSlots[n].Active := StrToIntDef(parts[3], 0) <> 0;
        end;
      finally
        parts.Free;
      end;
    end;
  finally
    CloseFile(f);
  end;
end;

procedure EnsureSlotsLoaded;
begin
  if not GSlotsLoaded then
  begin
    InternLoadSlots;
    GSlotsLoaded := True;
  end;
end;

procedure LoadReplicationSlots;
begin
  InternLoadSlots;
  GSlotsLoaded := True;
end;

procedure SaveReplicationSlots;
var
  f: TextFile;
  i: Integer;
begin
  AssignFile(f, SlotFilePath);
  Rewrite(f);
  try
    for i := 0 to High(GSlots) do
      Writeln(f, Format('%s|%d|%d|%d',
        [GSlots[i].SlotName, GSlots[i].RestartLSN, GSlots[i].ConfirmedLSN,
         Ord(GSlots[i].Active)]));
  finally
    CloseFile(f);
  end;
end;

function GetReplicationSlots: TReplSlotArray;
begin
  EnsureSlotsLoaded;
  Result := GSlots;
end;

function FindReplicationSlot(const SlotName: string; out Slot: TReplSlot): Boolean;
var
  i: Integer;
begin
  EnsureSlotsLoaded;
  Result := False;
  Slot.SlotName := '';
  Slot.RestartLSN := 0;
  Slot.ConfirmedLSN := 0;
  Slot.Active := False;
  for i := 0 to High(GSlots) do
    if SameText(GSlots[i].SlotName, SlotName) then
    begin
      Slot := GSlots[i];
      Exit(True);
    end;
end;

function UpdateReplicationSlot(const Slot: TReplSlot): Boolean;
var
  i, n: Integer;
  found: Boolean;
begin
  EnsureSlotsLoaded;
  found := False;
  for i := 0 to High(GSlots) do
    if SameText(GSlots[i].SlotName, Slot.SlotName) then
    begin
      GSlots[i] := Slot;
      found := True;
      Break;
    end;
  if not found then
  begin
    n := Length(GSlots);
    SetLength(GSlots, n + 1);
    GSlots[n] := Slot;
  end;
  SaveReplicationSlots;
  Result := True;
end;

function CreateReplicationSlot(const SlotName: string): Boolean;
var
  sl: TReplSlot;
begin
  Result := False;
  if SlotName = '' then Exit;
  if FindReplicationSlot(SlotName, sl) then
  begin
    Result := True; // zaten var
    Exit;
  end;
  sl.SlotName := SlotName;
  sl.RestartLSN := 0;
  sl.ConfirmedLSN := 0;
  sl.Active := False;
  Result := UpdateReplicationSlot(sl);
end;

function DropReplicationSlot(const SlotName: string): Boolean;
var
  i, n: Integer;
begin
  EnsureSlotsLoaded;
  n := 0;
  for i := 0 to High(GSlots) do
    if not SameText(GSlots[i].SlotName, SlotName) then
    begin
      GSlots[n] := GSlots[i];
      Inc(n);
    end;
  SetLength(GSlots, n);
  SaveReplicationSlots;
  Result := True;
end;

function StartReplicationPrimary(const SlotName, DestDir: string): Boolean;
var
  sl: TReplSlot;
begin
  Result := False;
  if GReplicationState.Role <> rrNone then Exit;
  GReplicationState.Role := rrPrimary;
  GReplicationState.SlotName := SlotName;
  GReplicationState.PrimaryConnInfo := DestDir;
  GReplicationState.LastLSN := 0;
  GReplicationState.ShippedCount := 0;
  GReplicationState.AppliedCount := 0;
  GReplicationState.IsRunning := True;

  if FindReplicationSlot(SlotName, sl) then
    sl.Active := True
  else
  begin
    sl.SlotName := SlotName;
    sl.RestartLSN := 0;
    sl.ConfirmedLSN := 0;
    sl.Active := True;
  end;
  UpdateReplicationSlot(sl);
  Result := True;
end;

function StartReplicationStandby(const ConnInfo, SlotName: string): Boolean;
var
  sl: TReplSlot;
begin
  Result := False;
  if GReplicationState.Role <> rrNone then Exit;
  GReplicationState.Role := rrStandby;
  GReplicationState.PrimaryConnInfo := ConnInfo;
  GReplicationState.SlotName := SlotName;
  GReplicationState.LastLSN := 0;
  GReplicationState.ShippedCount := 0;
  GReplicationState.AppliedCount := 0;
  GReplicationState.IsRunning := True;

  if FindReplicationSlot(SlotName, sl) then
    sl.Active := True
  else
  begin
    sl.SlotName := SlotName;
    sl.RestartLSN := 0;
    sl.ConfirmedLSN := 0;
    sl.Active := True;
  end;
  UpdateReplicationSlot(sl);
  Result := True;
end;

function StopReplication: Boolean;
var
  sl: TReplSlot;
begin
  if (GReplicationState.SlotName <> '') and
     FindReplicationSlot(GReplicationState.SlotName, sl) then
  begin
    sl.Active := False;
    UpdateReplicationSlot(sl);
  end;
  GReplicationState.IsRunning := False;
  GReplicationState.Role := rrNone;
  GReplicationState.PrimaryConnInfo := '';
  GReplicationState.SlotName := '';
  Result := True;
end;

function GetReplicationStatus(out State: TReplicationState): Boolean;
begin
  State := GReplicationState;
  Result := True;
end;

procedure SetReplicationDataDir(const ADir: string);
begin
  if ADir <> GDataDir then
  begin
    GDataDir := ADir;
    GSlotsLoaded := False;
  end;
end;

function GetReplicationDataDir: string;
begin
  Result := GDataDir;
end;

function SegmentNoOfFile(const AFileName: string): Int64;
var
  b: string;
  p, q: Integer;
begin
  Result := 0;
  b := ChangeFileExt(ExtractFileName(AFileName), '');
  p := LastDelimiter('_', b);
  if p <= 0 then Exit;
  q := Length(b) - p;
  if q <= 0 then Exit;
  Result := StrToInt64Def(Copy(b, p + 1, q), 0);
end;

function ArchiveSegmentFiles(const ADir: string): TStrArray;
var
  sr: TSearchRec;
  lst: array of string;
  nos: array of Int64;
  i, j, n: Integer;
  tmp: string;
begin
  Result := nil;
  SetLength(Result, 0);
  if (ADir = '') or (not DirectoryExists(ADir)) then Exit;
  SetLength(lst, 0);
  SetLength(nos, 0);
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.wal',
    faAnyFile or faHidden or faSysFile, sr) = 0 then
  try
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      n := SegmentNoOfFile(sr.Name);
      if n <= 0 then Continue;
      SetLength(lst, Length(lst) + 1);
      SetLength(nos, Length(nos) + 1);
      lst[High(lst)] := sr.Name;
      nos[High(nos)] := n;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  // Basit insertion sort (segment sayisi kucuk)
  for i := 1 to High(nos) do
  begin
    for j := i downto 1 do
    begin
      if nos[j] < nos[j - 1] then
      begin
        n := nos[j]; nos[j] := nos[j - 1]; nos[j - 1] := n;
        tmp := lst[j]; lst[j] := lst[j - 1]; lst[j - 1] := tmp;
      end
      else Break;
    end;
  end;
  SetLength(Result, Length(lst));
  for i := 0 to High(lst) do
    Result[i] := IncludeTrailingPathDelimiter(ADir) + lst[i];
end;

function CopyFileNoAhk(const ASrc, ADst: string): Boolean;
var
  fs, fd: TFileStream;
  buf: array[0..65535] of Byte;
  r: Integer;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  fs := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    fd := TFileStream.Create(ADst, fmCreate);
    try
      repeat
        r := fs.Read(buf, SizeOf(buf));
        if r > 0 then fd.WriteBuffer(buf, r);
      until r <= 0;
      Result := True;
    finally
      fd.Free;
    end;
  finally
    fs.Free;
  end;
end;

function WalShipOnce(const ArchiveDir, DestDir, SlotName: string;
  out Shipped: Integer): Boolean;
var
  files: TStrArray;
  i: Integer;
  sl: TReplSlot;
  base, dst: string;
  n: Int64;
begin
  Result := False;
  Shipped := 0;
  if (ArchiveDir = '') or (DestDir = '') then Exit;
  if not DirectoryExists(DestDir) then
    if not ForceDirectories(DestDir) then Exit;

  if not FindReplicationSlot(SlotName, sl) then
  begin
    sl.SlotName := SlotName;
    sl.RestartLSN := 0;
    sl.ConfirmedLSN := 0;
    sl.Active := True;
  end;

  files := ArchiveSegmentFiles(ArchiveDir);
  for i := 0 to High(files) do
  begin
    n := SegmentNoOfFile(files[i]);
    if n <= sl.RestartLSN then Continue; // zaten gonderildi
    base := ExtractFileName(files[i]);
    dst := IncludeTrailingPathDelimiter(DestDir) + base;
    if CopyFileNoAhk(files[i], dst) then
    begin
      Inc(Shipped);
      if n > sl.RestartLSN then sl.RestartLSN := n;
    end;
  end;
  UpdateReplicationSlot(sl);
  GReplicationState.LastLSN := sl.RestartLSN;
  GReplicationState.ShippedCount := GReplicationState.ShippedCount + Shipped;
  Result := True;
end;

function WalApplyOnce(ADb: TVDb; const SrcDir, SlotName: string;
  out Applied: Integer): Boolean;
var
  files: TStrArray;
  i: Integer;
  sl: TReplSlot;
  n: Int64;
begin
  Result := False;
  Applied := 0;
  if ADb = nil then Exit;
  if (SrcDir = '') or (not DirectoryExists(SrcDir)) then Exit;

  if not FindReplicationSlot(SlotName, sl) then
  begin
    sl.SlotName := SlotName;
    sl.RestartLSN := 0;
    sl.ConfirmedLSN := 0;
    sl.Active := True;
  end;

  files := ArchiveSegmentFiles(SrcDir);
  for i := 0 to High(files) do
  begin
    n := SegmentNoOfFile(files[i]);
    if n <= sl.ConfirmedLSN then Continue; // zaten uygulandi
    ADb.ApplyWalSegmentFile(files[i]);
    Inc(Applied);
    if n > sl.ConfirmedLSN then sl.ConfirmedLSN := n;
  end;
  UpdateReplicationSlot(sl);
  GReplicationState.LastLSN := sl.ConfirmedLSN;
  GReplicationState.AppliedCount := GReplicationState.AppliedCount + Applied;
  Result := True;
end;

function PumpReplication(ADb: TVDb; const ShipDir: string;
  out Count: Integer; out Msg: string): Boolean;
var
  n: Integer;
  arch: string;
begin
  Result := False;
  Count := 0;
  Msg := '';
  case GReplicationState.Role of
    rrPrimary:
      begin
        if ADb = nil then Exit;
        arch := ADb.GetArchiveDir;
        if arch = '' then
        begin
          Msg := 'PUMP: primary arsiv dizini ayarli degil (ARCHIVE WAL SET gerekli)';
          Exit;
        end;
        Result := WalShipOnce(arch, ShipDir, GReplicationState.SlotName, n);
        Count := n;
        Msg := Format('PRIMARY shipped=%d slot=%s -> %s',
          [n, GReplicationState.SlotName, ShipDir]);
      end;
    rrStandby:
      begin
        if ADb = nil then Exit;
        Result := WalApplyOnce(ADb, GReplicationState.PrimaryConnInfo,
          GReplicationState.SlotName, n);
        Count := n;
        Msg := Format('STANDBY applied=%d slot=%s <- %s',
          [n, GReplicationState.SlotName, GReplicationState.PrimaryConnInfo]);
      end;
  else
    Msg := 'PUMP: replikasyon aktif degil (START REPLICATION gerekli)';
  end;
end;

{ ============== R-17 FULL: TCP AKIS IMPLEMENTASYONU ============== }

const
  NETR_MAGIC: array[0..3] of Byte = ($56, $44, $42, $52); // "VDBR"
  NETR_PROTO = 1;
  NETR_MSG_SEGMENT = 1;   // gonderici -> alici: segment verisi
  NETR_MSG_HEARTBEAT = 2; // gonderici -> alici: bosluk sinyali
  NETR_MSG_END = 3;       // gonderici -> alici: nazik kapanis
  NETR_ACK = 1;           // alici -> gonderici: segment uygulandi
  NETR_STATUS_OK = 0;
  NETR_STATUS_BADSLOT = 1;

{ Thread'lerin GLOBAL slot durumunu kullanmamasi icin: belirli bir slot
  DOSYASINDA arama/guncelleme (dosya tabanli, onbelleksiz). }
function SlotFileFind(const AFile, AName: string; out Slot: TReplSlot): Boolean;
var
  f: TextFile;
  line, nm: string;
  parts: TStringList;
  p: Integer;
begin
  Result := False;
  Slot.SlotName := '';
  Slot.RestartLSN := 0;
  Slot.ConfirmedLSN := 0;
  Slot.Active := False;
  if not FileExists(AFile) then Exit;
  AssignFile(f, AFile);
  try
    Reset(f);
  except
    Exit;
  end;
  try
    while not Eof(f) do
    begin
      Readln(f, line);
      p := Pos('|', line);
      if p <= 1 then Continue;
      nm := Copy(line, 1, p - 1);
      if not SameText(nm, AName) then Continue;
      parts := TStringList.Create;
      try
        parts.Delimiter := '|';
        parts.DelimitedText := line;
        if parts.Count >= 4 then
        begin
          Slot.SlotName := parts[0];
          Slot.RestartLSN := StrToInt64Def(parts[1], 0);
          Slot.ConfirmedLSN := StrToInt64Def(parts[2], 0);
          Slot.Active := StrToIntDef(parts[3], 0) <> 0;
          Result := True;
          Exit;
        end;
      finally
        parts.Free;
      end;
    end;
  finally
    CloseFile(f);
  end;
end;

procedure SlotFileUpdate(const AFile: string; const Slot: TReplSlot);
var
  lines: TStringList;
  i: Integer;
  found: Boolean;
  s: string;
begin
  lines := TStringList.Create;
  try
    if FileExists(AFile) then lines.LoadFromFile(AFile);
    found := False;
    for i := 0 to lines.Count - 1 do
    begin
      s := lines[i];
      if SameText(Copy(s, 1, Pos('|', s) - 1), Slot.SlotName) then
      begin
        lines[i] := Format('%s|%d|%d|%d', [Slot.SlotName, Slot.RestartLSN,
          Slot.ConfirmedLSN, Ord(Slot.Active)]);
        found := True;
        Break;
      end;
    end;
    if not found then
      lines.Add(Format('%s|%d|%d|%d', [Slot.SlotName, Slot.RestartLSN,
        Slot.ConfirmedLSN, Ord(Slot.Active)]));
    lines.SaveToFile(AFile);
  finally
    lines.Free;
  end;
end;

{ ---- TVdbWalSenderThread ---- }

constructor TVdbWalSenderThread.Create(APort: Word; const AArchiveDir,
  ASlotName, ASlotFile: string);
begin
  FPort := APort;
  FArchiveDir := AArchiveDir;
  FSlotName := ASlotName;
  FSlotFile := ASlotFile;
  FListen := VDB_SOCK_INVALID;
  FClient := VDB_SOCK_INVALID;
  FAccepted := 0;
  FSent := 0;
  FLastErr := '';
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TVdbWalSenderThread.Stop;
var
  l, c: TVdbSocket;
begin
  Terminate;
  l := FListen;
  FListen := VDB_SOCK_INVALID;
  { Unix: close() tek basina engellenmis accept()'i UYANDIRMAZ; soket
    kapanana kadar accept blokta kalir (sqltest'te STOP REPLICATION'in
    sonsuz beklemesinin nedeni). Once shutdown ile uyandir, sonra kapat.
    Windows'ta dinleme soketinde shutdown tanimli degildir (hata doner),
    accept'i kapatma uyandirir; iki cagri da zararsizdir. }
  VdbSockShutdown(l);
  VdbSockClose(l);
  { Aktif baglanti (ACK bekleme) shutdown ile uyandirilir; kapanisini
    Execute yapar. }
  c := FClient;
  VdbSockShutdown(c);
end;

function TVdbWalSenderThread.ListenReady: Boolean;
begin
  Result := FListen <> VDB_SOCK_INVALID;
end;

function TVdbWalSenderThread.ServeClient(ASock: TVdbSocket): Boolean;
var
  magic: array[0..3] of Byte;
  proto, crc, dataLen: Cardinal;
  slotName, nm: string;
  slot: TReplSlot;
  files: TStrArray;
  i: Integer;
  n: Int64;
  ackLsn: UInt64;
  ack: Byte;
  fs: TFileStream;
  data: array of Byte;
  sentAny: Boolean;
begin
  Result := False;
  { ---- el sikisma: alici -> gonderici ---- }
  if not VdbRecvAll(ASock, magic, 4) then Exit;
  if (magic[0] <> NETR_MAGIC[0]) or (magic[1] <> NETR_MAGIC[1]) or
     (magic[2] <> NETR_MAGIC[2]) or (magic[3] <> NETR_MAGIC[3]) then
  begin
    FLastErr := 'TCP el sikisma: bozuk magic';
    Exit;
  end;
  if not VdbRecvU32(ASock, proto) then Exit;
  if proto <> NETR_PROTO then
  begin
    FLastErr := 'TCP el sikisma: desteklenmeyen protokol surumu';
    Exit;
  end;
  if not VdbRecvStr(ASock, slotName) then Exit;
  if not SameText(slotName, FSlotName) then
  begin
    { Bilinmeyen slot: reddet ve kapat. }
    VdbSendAll(ASock, NETR_MAGIC, 4);
    VdbSendU32(ASock, NETR_PROTO);
    VdbSendU32(ASock, NETR_STATUS_BADSLOT);
    FLastErr := 'TCP: bilinmeyen slot "' + slotName + '"';
    Exit;
  end;
  if not SlotFileFind(FSlotFile, FSlotName, slot) then
  begin
    slot.SlotName := FSlotName;
    slot.RestartLSN := 0;
    slot.ConfirmedLSN := 0;
    slot.Active := False;
  end;
  slot.Active := True;
  SlotFileUpdate(FSlotFile, slot);
  { ---- el sikisma yanidi: gonderici -> alici ---- }
  if not VdbSendAll(ASock, NETR_MAGIC, 4) then Exit;
  if not VdbSendU32(ASock, NETR_PROTO) then Exit;
  if not VdbSendU32(ASock, NETR_STATUS_OK) then Exit;

  { ---- akis dongusu ---- }
  while not Terminated do
  begin
    files := ArchiveSegmentFiles(FArchiveDir);
    sentAny := False;
    for i := 0 to High(files) do
    begin
      if Terminated then Break;
      n := SegmentNoOfFile(files[i]);
      if n <= slot.RestartLSN then Continue;  // zaten gonderildi
      try
        fs := TFileStream.Create(files[i], fmOpenRead or fmShareDenyNone);
        try
          SetLength(data, fs.Size);
          if fs.Size > 0 then fs.ReadBuffer(Pointer(data)^, Integer(fs.Size));
        finally
          fs.Free;
        end;
      except
        on E: Exception do
        begin
          FLastErr := 'segment okunamadi (' + files[i] + '): ' + E.Message;
          Exit;
        end;
      end;
      if Length(data) > 0 then
        crc := VDbCrc32Of(Pointer(data)^, Length(data))
      else
        crc := 0;
      nm := ExtractFileName(files[i]);
      if not VdbSendU8(ASock, NETR_MSG_SEGMENT) then Exit;
      if not VdbSendStr(ASock, nm) then Exit;
      if not VdbSendU64(ASock, UInt64(n)) then Exit;
      if not VdbSendU32(ASock, crc) then Exit;
      dataLen := Cardinal(Length(data));
      if not VdbSendU32(ASock, dataLen) then Exit;
      if dataLen > 0 then
        if not VdbSendAll(ASock, Pointer(data)^, Integer(dataLen)) then Exit;
      { ---- ACK bekle ---- }
      if not VdbRecvU8(ASock, ack) then Exit;
      if ack <> NETR_ACK then
      begin
        FLastErr := 'TCP: beklenmeyen mesaj (ACK degil)';
        Exit;
      end;
      if not VdbRecvU64(ASock, ackLsn) then Exit;
      Inc(FSent);
      sentAny := True;
      if Int64(ackLsn) > slot.RestartLSN then
        slot.RestartLSN := Int64(ackLsn);
      SlotFileUpdate(FSlotFile, slot);
    end;
    if not sentAny then
    begin
      if not VdbSendU8(ASock, NETR_MSG_HEARTBEAT) then Exit;
      Sleep(100);
    end;
  end;
  { Kibarca kapan. }
  VdbSendU8(ASock, NETR_MSG_END);
  Result := True;
end;

{ Bu, yol haritasindaki WalSenderLoop'un KENDISIDIR: dinle + kabul et +
  akit. TVdbWalSenderThread.Execute dogrudan burayi calistirir. }
procedure TVdbWalSenderThread.Execute;
var
  client: TVdbSocket;
begin
  FListen := VdbTcpListen(FPort);
  if FListen = VDB_SOCK_INVALID then
  begin
    FLastErr := 'TCP dinleme kurulamadi (port ' + IntToStr(FPort) + ')';
    Exit;
  end;
  while not Terminated do
  begin
    client := VdbTcpAccept(FListen);
    if client = VDB_SOCK_INVALID then
    begin
      if Terminated then Break;
      Sleep(50);
      Continue;
    end;
    Inc(FAccepted);
    FClient := client;
    ServeClient(client);
    FClient := VDB_SOCK_INVALID;
    VdbSockClose(client);
  end;
  { FListen'i burada da kapat: Stop zaten kapattiysa FListen gecersizdir
    ve bu cagri etkisizdir; Stop hic cagrilmadiysa (yaris yol) sizinti
    kalmaz. }
  VdbSockClose(FListen);
end;

{ ---- TVdbWalReceiverThread ---- }

constructor TVdbWalReceiverThread.Create(ADb: TVDb; const AHost: string;
  APort: Word; const ASlotName, ASlotFile: string);
var
  dir: string;
begin
  FDb := ADb;
  FHost := AHost;
  FPort := APort;
  FSlotName := ASlotName;
  FSlotFile := ASlotFile;
  dir := ExtractFileDir(ASlotFile);
  if dir = '' then
    FInboxDir := '.replrecv'
  else
    FInboxDir := IncludeTrailingPathDelimiter(dir) + '.replrecv';
  ForceDirectories(FInboxDir);
  FSock := VDB_SOCK_INVALID;
  FApplied := 0;
  FLastErr := '';
  FConnected := False;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TVdbWalReceiverThread.Stop;
begin
  Terminate;
  { Engellenmis recv'i uyandir; kapanisi Execute'in finally blogu yapar. }
  VdbSockShutdown(FSock);
end;

{ Bu, yol haritasindaki WalReceiverLoop'un KENDISIDIR: baglan + el
  sikis + al/uygula. }
procedure TVdbWalReceiverThread.Execute;
var
  magic: array[0..3] of Byte;
  proto, st, crcGot, crcCalc, dataLen: Cardinal;
  msg: Byte;
  nm, tmpPath: string;
  segNo: UInt64;
  slot: TReplSlot;
  data: array of Byte;
  fs: TFileStream;
  tryN: Integer;
  ok: Boolean;
begin
  { ---- baglan (gonderici henuz hazir olmayabilir: bir sure deneme) ---- }
  FSock := VDB_SOCK_INVALID;
  for tryN := 1 to 100 do
  begin
    if Terminated then Exit;
    FSock := VdbTcpConnect(FHost, FPort);
    if FSock <> VDB_SOCK_INVALID then Break;
    Sleep(50);
  end;
  if FSock = VDB_SOCK_INVALID then
  begin
    FLastErr := 'TCP baglanilamadi: ' + FHost + ':' + IntToStr(FPort);
    Exit;
  end;
  try
    FConnected := True;
    { ---- el sikisma: alici -> gonderici ---- }
    if not VdbSendAll(FSock, NETR_MAGIC, 4) then
    begin FLastErr := 'el sikisma gonderilemedi'; Exit; end;
    if not VdbSendU32(FSock, NETR_PROTO) then
    begin FLastErr := 'el sikisma gonderilemedi'; Exit; end;
    if not VdbSendStr(FSock, FSlotName) then
    begin FLastErr := 'el sikisma gonderilemedi'; Exit; end;
    { ---- el sikisma yanidi ---- }
    if not VdbRecvAll(FSock, magic, 4) then
    begin FLastErr := 'el sikisma yanidi alinamadi'; Exit; end;
    if (magic[0] <> NETR_MAGIC[0]) or (magic[1] <> NETR_MAGIC[1]) or
       (magic[2] <> NETR_MAGIC[2]) or (magic[3] <> NETR_MAGIC[3]) then
    begin FLastErr := 'TCP el sikisma: bozuk magic'; Exit; end;
    if not VdbRecvU32(FSock, proto) then
    begin FLastErr := 'protokol surumu alinamadi'; Exit; end;
    if proto <> NETR_PROTO then
    begin FLastErr := 'desteklenmeyen protokol surumu'; Exit; end;
    if not VdbRecvU32(FSock, st) then
    begin FLastErr := 'durum alinamadi'; Exit; end;
    if st <> NETR_STATUS_OK then
    begin FLastErr := 'slot reddedildi (bilinmeyen slot)'; Exit; end;
    if not SlotFileFind(FSlotFile, FSlotName, slot) then
    begin
      slot.SlotName := FSlotName;
      slot.RestartLSN := 0;
      slot.ConfirmedLSN := 0;
      slot.Active := False;
    end;
    slot.Active := True;
    SlotFileUpdate(FSlotFile, slot);

    { ---- akis ---- }
    while not Terminated do
    begin
      if not VdbRecvU8(FSock, msg) then
      begin
        FLastErr := 'baglanti koptu';
        Break;
      end;
      case msg of
        NETR_MSG_SEGMENT:
          begin
            if not VdbRecvStr(FSock, nm) then Break;
            if not VdbRecvU64(FSock, segNo) then Break;
            if not VdbRecvU32(FSock, crcGot) then Break;
            if not VdbRecvU32(FSock, dataLen) then Break;
            if dataLen > $40000000 then
            begin
              FLastErr := 'segment boyut siniri asildi';
              Break;
            end;
            SetLength(data, Integer(dataLen));
            if dataLen > 0 then
              if not VdbRecvAll(FSock, Pointer(data)^, Integer(dataLen)) then
                Break;
            if dataLen > 0 then
              crcCalc := VDbCrc32Of(Pointer(data)^, Integer(dataLen))
            else
              crcCalc := 0;
            if crcCalc <> crcGot then
            begin
              FLastErr := 'CRC hatasi: ' + nm;
              Break;
            end;
            { Idempotans: yalnizca ConfirmedLSN'den buyuk segmentler
              uygulanir. }
            if Int64(segNo) > slot.ConfirmedLSN then
            begin
              tmpPath := IncludeTrailingPathDelimiter(FInboxDir) + nm;
              ok := False;
              try
                fs := TFileStream.Create(tmpPath, fmCreate);
                try
                  if dataLen > 0 then
                    fs.WriteBuffer(Pointer(data)^, Integer(dataLen));
                finally
                  fs.Free;
                end;
                FDb.ApplyWalSegmentFile(tmpPath);
                ok := True;
              except
                on E: Exception do
                  FLastErr := 'segment uygulama hatasi: ' + E.Message;
              end;
              if not ok then Break;
              DeleteFile(tmpPath);
              Inc(FApplied);
              slot.ConfirmedLSN := Int64(segNo);
              SlotFileUpdate(FSlotFile, slot);
            end;
            { ACK (atlanan idempotent segmentler icin de olumlu yanit). }
            if not VdbSendU8(FSock, NETR_ACK) then Break;
            if not VdbSendU64(FSock, segNo) then Break;
          end;
        NETR_MSG_HEARTBEAT:
          ;  { bosluk sinyali: sessizce gec }
        NETR_MSG_END:
          Break;
      else
        begin
          FLastErr := 'bilinmeyen mesaj turu: ' + IntToStr(msg);
          Break;
        end;
      end;
    end;
  finally
    FConnected := False;
    VdbSockClose(FSock);
    FSock := VDB_SOCK_INVALID;
  end;
end;

{ ---- TCP kayit defteri (yalnizca ANA thread erisir) ---- }

type
  TVdbNetRepl = record
    Db: TVDb;
    Sender: TVdbWalSenderThread;
    Receiver: TVdbWalReceiverThread;
  end;

var
  GNetRepl: array of TVdbNetRepl;

function NetReplIndexOf(ADb: TVDb): Integer;
var
  i: Integer;
begin
  Result := -1;
  if ADb = nil then Exit;
  for i := 0 to High(GNetRepl) do
    if GNetRepl[i].Db = ADb then
      Exit(i);
end;

function DbSlotFile(ADb: TVDb): string;
var
  dir: string;
begin
  dir := ExtractFileDir(ADb.FilePath);
  if dir = '' then
    Result := '.replslots'
  else
    Result := IncludeTrailingPathDelimiter(dir) + '.replslots';
end;

function StartTcpSender(ADb: TVDb; APort: Word; const ASlotName: string;
  out AErr: string): Boolean;
var
  ix: Integer;
  arch: string;
  snd: TVdbWalSenderThread;
  w: Integer;
begin
  Result := False;
  AErr := '';
  if ADb = nil then
  begin
    AErr := 'motor yok';
    Exit;
  end;
  ix := NetReplIndexOf(ADb);
  if (ix >= 0) and ((GNetRepl[ix].Sender <> nil) or
    (GNetRepl[ix].Receiver <> nil)) then
  begin
    AErr := 'bu veritabaninda TCP replikasyon zaten aktif';
    Exit;
  end;
  arch := ADb.GetArchiveDir;
  if arch = '' then
  begin
    AErr := 'arsiv dizini ayarli degil (once ARCHIVE WAL SET gerekir)';
    Exit;
  end;
  if ix < 0 then
  begin
    SetLength(GNetRepl, Length(GNetRepl) + 1);
    ix := High(GNetRepl);
    GNetRepl[ix].Db := ADb;
    GNetRepl[ix].Sender := nil;
    GNetRepl[ix].Receiver := nil;
  end;
  snd := TVdbWalSenderThread.Create(APort, arch, ASlotName, DbSlotFile(ADb));
  GNetRepl[ix].Sender := snd;
  { Dinlemenin kurulmasini bekle (Execute'in ilk isi): kurulum aninda
    belli olur. Port bos degilse thread hatayla biter ve biz False
    doneriz — cagiran, akisin basladigini GUVENLE varsayabilir. }
  for w := 1 to 40 do
  begin
    if snd.ListenReady or snd.Finished then Break;
    Sleep(50);
  end;
  if (not snd.ListenReady) or snd.Finished then
  begin
    AErr := 'dinleme kurulamadi: ' + snd.LastError;
    snd.Stop;
    snd.WaitFor;
    snd.Free;
    GNetRepl[ix].Sender := nil;
    if (GNetRepl[ix].Sender = nil) and (GNetRepl[ix].Receiver = nil) then
    begin
      GNetRepl[ix] := GNetRepl[High(GNetRepl)];
      SetLength(GNetRepl, Length(GNetRepl) - 1);
    end;
    Exit;
  end;
  Result := True;
end;

function StartTcpReceiver(ADb: TVDb; const AHost: string; APort: Word;
  const ASlotName: string; out AErr: string): Boolean;
var
  ix: Integer;
begin
  Result := False;
  AErr := '';
  if ADb = nil then
  begin
    AErr := 'motor yok';
    Exit;
  end;
  ix := NetReplIndexOf(ADb);
  if (ix >= 0) and ((GNetRepl[ix].Sender <> nil) or
    (GNetRepl[ix].Receiver <> nil)) then
  begin
    AErr := 'bu veritabaninda TCP replikasyon zaten aktif';
    Exit;
  end;
  if ix < 0 then
  begin
    SetLength(GNetRepl, Length(GNetRepl) + 1);
    ix := High(GNetRepl);
    GNetRepl[ix].Db := ADb;
    GNetRepl[ix].Sender := nil;
    GNetRepl[ix].Receiver := nil;
  end;
  GNetRepl[ix].Receiver := TVdbWalReceiverThread.Create(ADb, AHost, APort,
    ASlotName, DbSlotFile(ADb));
  Result := True;
end;

{ Slot dosyasinda slotu pasiflestir (STOP sonrasi kalicilik). }
procedure DeactivateSlotInFile(const AFile, AName: string);
var
  sl: TReplSlot;
begin
  if SlotFileFind(AFile, AName, sl) then
  begin
    sl.Active := False;
    SlotFileUpdate(AFile, sl);
  end;
end;

function StopTcpForDb(ADb: TVDb): Boolean;
var
  ix: Integer;
  snd: TVdbWalSenderThread;
  rcv: TVdbWalReceiverThread;
  sFile, sName: string;
begin
  Result := False;
  ix := NetReplIndexOf(ADb);
  if ix < 0 then Exit;
  snd := GNetRepl[ix].Sender;
  rcv := GNetRepl[ix].Receiver;
  if snd <> nil then
  begin
    sFile := snd.FSlotFile;
    sName := snd.FSlotName;
    snd.Stop;
    snd.WaitFor;
    snd.Free;
    GNetRepl[ix].Sender := nil;
    { Slotu kalici olarak pasiflestir (dosya moduyla ayni semantik).
      Thread DURDUKTAN sonra: slot dosyasina eszamanli yazis yok. }
    DeactivateSlotInFile(sFile, sName);
  end;
  if rcv <> nil then
  begin
    sFile := rcv.FSlotFile;
    sName := rcv.FSlotName;
    rcv.Stop;
    rcv.WaitFor;
    rcv.Free;
    GNetRepl[ix].Receiver := nil;
    DeactivateSlotInFile(sFile, sName);
  end;
  GNetRepl[ix] := GNetRepl[High(GNetRepl)];
  SetLength(GNetRepl, Length(GNetRepl) - 1);
  Result := True;
end;

function IsStreamingDb(ADb: TVDb): Boolean;
var
  ix: Integer;
begin
  ix := NetReplIndexOf(ADb);
  Result := (ix >= 0) and (GNetRepl[ix].Receiver <> nil);
end;

function TcpReplStatus(ADb: TVDb; out AIsPrimary: Boolean;
  out ASlot, AInfo: string): Boolean;
var
  ix: Integer;
begin
  Result := False;
  AIsPrimary := False;
  ASlot := '';
  AInfo := '';
  ix := NetReplIndexOf(ADb);
  if ix < 0 then Exit;
  if GNetRepl[ix].Sender <> nil then
  begin
    AIsPrimary := True;
    ASlot := GNetRepl[ix].Sender.SlotName;
    AInfo := Format('tcp://*:%d (sent=%d, accepted=%d)',
      [GNetRepl[ix].Sender.Port, GNetRepl[ix].Sender.Sent,
       GNetRepl[ix].Sender.Accepted]);
    Result := True;
  end
  else if GNetRepl[ix].Receiver <> nil then
  begin
    AIsPrimary := False;
    ASlot := GNetRepl[ix].Receiver.SlotName;
    AInfo := Format('tcp://%s:%d (applied=%d, connected=%s)',
      [GNetRepl[ix].Receiver.Host, GNetRepl[ix].Receiver.Port,
       GNetRepl[ix].Receiver.Applied,
       BoolToStr(GNetRepl[ix].Receiver.Connected, True)]);
    Result := True;
  end;
end;

function TcpActiveForDb(ADb: TVDb): Boolean;
var
  ix: Integer;
begin
  ix := NetReplIndexOf(ADb);
  Result := (ix >= 0) and ((GNetRepl[ix].Sender <> nil) or
    (GNetRepl[ix].Receiver <> nil));
end;

function TcpRecvApplied(ADb: TVDb): Integer;
var
  ix: Integer;
begin
  Result := -1;
  ix := NetReplIndexOf(ADb);
  if (ix >= 0) and (GNetRepl[ix].Receiver <> nil) then
    Result := GNetRepl[ix].Receiver.Applied;
end;

function TcpLastError(ADb: TVDb): string;
var
  ix: Integer;
begin
  Result := '';
  ix := NetReplIndexOf(ADb);
  if ix < 0 then Exit;
  if GNetRepl[ix].Sender <> nil then
    Result := GNetRepl[ix].Sender.LastError
  else if GNetRepl[ix].Receiver <> nil then
    Result := GNetRepl[ix].Receiver.LastError;
end;

procedure StopAllNetRepl;
var
  i: Integer;
begin
  for i := 0 to High(GNetRepl) do
  begin
    if GNetRepl[i].Sender <> nil then
    begin
      GNetRepl[i].Sender.Stop;
      GNetRepl[i].Sender.WaitFor;
      GNetRepl[i].Sender.Free;
      GNetRepl[i].Sender := nil;
    end;
    if GNetRepl[i].Receiver <> nil then
    begin
      GNetRepl[i].Receiver.Stop;
      GNetRepl[i].Receiver.WaitFor;
      GNetRepl[i].Receiver.Free;
      GNetRepl[i].Receiver := nil;
    end;
  end;
  SetLength(GNetRepl, 0);
end;

initialization
  GReplicationState.Role := rrNone;
  GReplicationState.IsRunning := False;
  GReplicationState.PrimaryConnInfo := '';
  GReplicationState.SlotName := '';
  GReplicationState.LastLSN := 0;
  GReplicationState.ShippedCount := 0;
  GReplicationState.AppliedCount := 0;
  GDataDir := '';
  SetLength(GSlots, 0);
  GSlotsLoaded := False;

finalization
  { Guvenlik agi: test/uygulama STOP REPLICATION demeyi unuttuysa
    kalan TCP thread'lerini durdurup temizle. }
  StopAllNetRepl;
end.
