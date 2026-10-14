unit VDbCdc;

{ VDb Change Data Capture (CDC) - Motor Katmani
  ---------------------------------------------------------------------------
  WAL (.wal) dosyasini okuyup satir degisikliklerini olaya (callback)
  donusturur.

  2026-10-05 KOK DUSTURMELI ONARIM:
    ONCEDEN bu birim .wal dosyasini TVDbRecHead (ana dosya kayit basligi)
    olarak OKUYORDU. Gercek WAL bicimi TVDbWalHead'dir (magic 'WALR',
    Key, duz Flags, ValLen, Crc) ve icinde NE Seq NE BATCHEND vardir.
    Yani CDC hicbir zaman dogru olay uretemezdi (test de assertion
    icermiyordu, "gecti" gorunuyordu).

  DOGRU KAYNAK:
    * WAL yalnizca otomatik modda (`WALEnabled = True`) dolar; bu yuzden
      `Start` motorun otomatik WAL'ini ACAR (kapatmak isteyen `Stop`
      sonrasi kapatabilir).
    * Deger = satir kodlamasi (EncodeRow); WAL bilerek DUZ METINDIR
      (sifreli bile olsa) -> CDC anahtarsiz calisir.
    * Silme (DEL) kaydinin degeri bosdur; PK/onceki deger WAL'den
      cozulemez. Bu yuzden gorulen PUT'lar icin `FSeen` haritasi tutulur
      ve silme olayi buradan beslenir. Harita WAL basindan kurulur
      (Start sirasinda tum gecmis okunur).
    * WAL, checkpoint'te temizlenir; CDC "tarihin tamamini" degil,
      "son checkpoint'ten beriyi" kapsar (belgeli sinir).

  OLAY SEMANTIGI:
    * PUT + ilk gorulus            -> cdcInsert
    * PUT + daha once goruldu      -> cdcUpdate  (OldValues = onceki)
    * DEL + haritada kayit var     -> cdcDelete  (OldValues = son bilinen)
    * satir disi deger (sema vb.)  -> atlaniyor (SkippedCount)
  }

{$mode delphi}
interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections, VDbPlatform, VDbCore, VDbTable;

type
  TCDCEventType = (cdcInsert, cdcUpdate, cdcDelete);
  TCDCEvent = record
    EventType: TCDCEventType;
    TableName: string;
    PK: string;
    OldValues: TStrArray;
    NewValues: TStrArray;
    Timestamp: TDateTime;
    Seq: QWord;         // CDC olay sira numarasi (WAL'de Seq yoktur)
  end;

  TCDCChangeProc = procedure(const Event: TCDCEvent);

  { WAL'de gorulen satirin son bilgisi (silme olayini besler) }
  TRowInfo = record
    TableId: Word;
    TableName: string;
    PK: string;
    Vals: TStrArray;
  end;

  TVDbCdcThread = class(TThread)
  private
    FCdc: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(ACdc: Pointer);
  end;

  TVDbCdc = class
  private
    FTb: TVTableDb;
    FWalPath: string;
    FThread: TVDbCdcThread;
    FRunning: Boolean;
    FLock: TCriticalSection;
    FOnChange: TCDCChangeProc;
    FNextIndex: Integer;             // siradaki WAL kayit indeksi
    FBuffer: TList<TCDCEvent>;
    FFlushInterval: Integer;
    FSeen: TDictionary<QWord, TRowInfo>; // yalnizca CDC parcasi erisir
    FSeq: QWord;
    FEvents: Integer;
    FSkipped: Integer;
    { POLL modu (2026-10-06): tampon siniri ve dusen olay sayisi }
    FMaxPending: Integer;
    FDropped: Integer;
    procedure ProcessWal;
    procedure HandleEntry(AKey: QWord; AFlags: Byte; const AValue: TBytes);
    function GetPendingCount: Integer;
  public
    constructor Create(const ATb: TVTableDb);
    destructor Destroy; override;
    { WAL'i acar ve mevcut gecmisi okumaya baslar. }
    procedure Start;
    procedure Stop;
    { birikmis olaylari hemen OnChange'e tasir (thread'siz de cagrilabilir). }
    procedure Flush;
    { POLL modu (2026-10-06): OnChange ATANMADIGINDA olaylar tamponda
      KALIR (Flush onlari bosaltmaz) ve istemci sirayla ceker:
        TryPeek  -> onunde duran olayi gorur (tuketmez; boyut icin),
        TryDequeue -> onundeki olayi verip tampondan cikarir.
      Tek istemci (tek parcacik) varsayilir. Tampon MaxPending'i asarsa
      EN ESKI olay dusurulur ve DroppedCount artar (bellek siniri). }
    function TryPeek(out E: TCDCEvent): Boolean;
    function TryDequeue(out E: TCDCEvent): Boolean;
    property OnChange: TCDCChangeProc read FOnChange write FOnChange;
    property FlushIntervalMs: Integer read FFlushInterval write FFlushInterval;
    { gorunurluk (test/tanilama) }
    property EventCount: Integer read FEvents;
    property SkippedCount: Integer read FSkipped;
    property PendingCount: Integer read GetPendingCount;
    property Running: Boolean read FRunning;
    property MaxPending: Integer read FMaxPending write FMaxPending;
    property DroppedCount: Integer read FDropped;
  end;

implementation

constructor TVDbCdcThread.Create(ACdc: Pointer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCdc := ACdc;
end;

procedure TVDbCdcThread.Execute;
var
  cdc: TVDbCdc;
  lastFlush: QWord;
begin
  cdc := TVDbCdc(FCdc);
  lastFlush := VdbTickMs;
  while not Terminated do
  begin
    try
      cdc.ProcessWal;
    except
      { parcacik olmemeli: hata yutlanir, sonraki turda tekrar denenir }
    end;
    if VdbTickMs - lastFlush >= QWord(cdc.FlushIntervalMs) then
    begin
      try
        cdc.Flush;
      except
      end;
      lastFlush := VdbTickMs;
    end;
    Sleep(50);
  end;
end;

{ TVDbCdc }

constructor TVDbCdc.Create(const ATb: TVTableDb);
begin
  inherited Create;
  FTb := ATb;
  FWalPath := ChangeFileExt(FTb.Kv.FilePath, '.wal');
  FLock := TCriticalSection.Create;
  FBuffer := TList<TCDCEvent>.Create;
  FSeen := TDictionary<QWord, TRowInfo>.Create;
  FFlushInterval := 1000;
  FRunning := False;
  FNextIndex := 0;
  FSeq := 0;
  FEvents := 0;
  FSkipped := 0;
  FMaxPending := 100000;   // POLL modu tampon siniri (bellek korumasi)
  FDropped := 0;
end;

destructor TVDbCdc.Destroy;
begin
  Stop;
  FSeen.Free;
  FBuffer.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TVDbCdc.Start;
begin
  if FRunning then Exit;
  { CDC'nin kaynak kosulu: otomatik WAL. Yoksa dosya hic dolmaz. }
  FTb.Kv.WALEnabled := True;
  FRunning := True;
  FThread := TVDbCdcThread.Create(Self);
  FThread.Start;
end;

procedure TVDbCdc.Stop;
begin
  if not FRunning then Exit;
  FRunning := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
  { durmadan once kalan her seyi isle }
  try
    ProcessWal;
  except
  end;
  Flush;
end;

function TVDbCdc.GetPendingCount: Integer;
begin
  FLock.Enter;
  try
    Result := FBuffer.Count;
  finally
    FLock.Leave;
  end;
end;

procedure TVDbCdc.Flush;
var
  ev: TCDCEvent;
  local: array of TCDCEvent;
  i: Integer;
begin
  { POLL modu (OnChange yok): tampon istemcinin TryDequeue'sini bekler;
    bosaltmak olay KAYBIDIR - Flush burada hicbir sey yapmaz. }
  if not Assigned(FOnChange) then Exit;
  { OnChange callback'i KILIT disinda cagrilir: callback SQL/cagri yaparsa
    ProcessWal kilit rekabetine girmez. Kopyalayip bosalt, sonra yay. }
  FLock.Enter;
  try
    SetLength(local, FBuffer.Count);
    for i := 0 to FBuffer.Count - 1 do
      local[i] := FBuffer[i];
    FBuffer.Clear;
  finally
    FLock.Leave;
  end;
  if Assigned(FOnChange) then
    for ev in local do
      FOnChange(ev);
end;

procedure TVDbCdc.ProcessWal;
{ WAL'i sirayla okur (TVDbWalHead bicimi, dogrulama TVDb.ReadWalEntry
  icinde: magic/CRC/yirtik kuyruk). Checkpoint dosyayi temizlerse
  indeks sayidan buyuk kalir -> basa donulur. }
var
  cnt, i: Integer;
  k: QWord;
  fl: Byte;
  val: TBytes;
begin
  cnt := FTb.Kv.WalRecordCount;
  if FNextIndex > cnt then
    FNextIndex := 0;   // checkpoint gecmisi silmis; yeni baslangic
  i := FNextIndex;
  while i < cnt do
  begin
    if not FTb.Kv.ReadWalEntry(i, k, fl, val) then
      Break;           // bozuk/yirtik kuyruk: orada dur
    HandleEntry(k, fl, val);
    Inc(i);
  end;
  FNextIndex := i;
end;

procedure TVDbCdc.HandleEntry(AKey: QWord; AFlags: Byte; const AValue: TBytes);
var
  ev: TCDCEvent;
  info: TRowInfo;
  tid: Word;
  pk: string;
  vals: TStrArray;
begin
  ev.OldValues := nil;
  ev.NewValues := nil;
  ev.Timestamp := Now;

  if AFlags = VDB_FLAG_PUT then
  begin
    { satir disi degerler (sema kaydi vb.) -> decode edilemez/atanir }
    if not FTb.DecodeRowDataPublic(AValue, tid, pk, vals) then
    begin
      FLock.Enter;
      try
        Inc(FSkipped);
      finally
        FLock.Leave;
      end;
      Exit;
    end;
    ev.TableName := FTb.GetTableNameById(tid);
    if ev.TableName = '' then
    begin
      FLock.Enter;
      try
        Inc(FSkipped);
      finally
        FLock.Leave;
      end;
      Exit;
    end;

    if FSeen.TryGetValue(AKey, info) then
    begin
      ev.EventType := cdcUpdate;
      ev.OldValues := Copy(info.Vals, 0, Length(info.Vals));
    end
    else
      ev.EventType := cdcInsert;

    ev.PK := pk;
    ev.NewValues := Copy(vals, 0, Length(vals));

    info.TableId := tid;
    info.TableName := ev.TableName;
    info.PK := pk;
    info.Vals := Copy(vals, 0, Length(vals));
    FSeen.AddOrSetValue(AKey, info);
  end
  else { VDB_FLAG_DEL }
  begin
    { WAL silme kaydinda deger YOKTUR; PK'yi yalnizca daha once
      gorulen PUT'tan bilebiliriz. Bilinmiyorsa (sema silmesi /
      CDC baslamadan onceki silme) olay URETILMEZ. }
    if not FSeen.TryGetValue(AKey, info) then
    begin
      FLock.Enter;
      try
        Inc(FSkipped);
      finally
        FLock.Leave;
      end;
      Exit;
    end;
    ev.EventType := cdcDelete;
    ev.TableName := info.TableName;
    ev.PK := info.PK;
    ev.OldValues := Copy(info.Vals, 0, Length(info.Vals));
    FSeen.Remove(AKey);
  end;

  FLock.Enter;
  try
    Inc(FSeq);
    ev.Seq := FSeq;
    FBuffer.Add(ev);
    Inc(FEvents);
    { POLL modu bellek siniri: tampon tasiarsa EN ESKI olay dusurulur
      (istemci geride kalmis demektir; kayip DroppedCount ile SAYILIR,
      sessizce gizlenmez). }
    if FMaxPending > 0 then
      while FBuffer.Count > FMaxPending do
      begin
        FBuffer.Delete(0);
        Inc(FDropped);
      end;
  finally
    FLock.Leave;
  end;
end;

function TVDbCdc.TryPeek(out E: TCDCEvent): Boolean;
// Onunde duran olayi gorur, tampondan CIKARMAZ (boyut sorgusu icin).
begin
  FLock.Enter;
  try
    Result := FBuffer.Count > 0;
    if Result then
      E := FBuffer[0];
  finally
    FLock.Leave;
  end;
end;

function TVDbCdc.TryDequeue(out E: TCDCEvent): Boolean;
// Onundeki olayi verip tampondan cikarir (poll modunun tuketimi).
begin
  FLock.Enter;
  try
    Result := FBuffer.Count > 0;
    if Result then
    begin
      E := FBuffer[0];
      FBuffer.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
end;

end.
