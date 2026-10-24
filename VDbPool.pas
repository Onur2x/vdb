unit VDbPool;

{ Baglanti havuzu: tek motor (TVDb/TVTableDb) uzerinde N adet TVSql ornegi.
  Kullanim (REST sunucusu is parcasi basina):

    Sq := Pool.Acquire;           // bosalana kadar bekler (zaman asimli)
    try
      R := Sq.Exec('SELECT ...', [...]);
      ...
    finally
      Pool.Release(Sq);
    end;

  Ya da tek satirlik: R := Pool.Exec('SELECT ...');

  NEDEN TEK MOTOR: .odb dosyasi exclusive kilitlidir (VDbSync); ayni
  dosyaya ikinci baglanti acilamaz. Havuz, motoru paylasan TVSql
  orneklerini yonetir (her ornek bir thread'e aittir; guvenlik P3
  kilitleriyle saglanir). Havuz paralellik CARPMaz, kaynak kullanimini
  SINIRLAR (asiri yukte kuyruk + zaman asimi).

  Kurallar:
  - Acquire bos havuzda TimeoutMs kadar bekler, sonra ecPoolTimeout.
  - Kapanmis havuzdan Acquire ecPoolClosed verir.
  - Havuza ait olmayan ornek Release edilirse ecInvalidArgument.
  - Free oncesi tum baglantilar Release edilmelidir (edilmeyenler
    serbest birakilir; kayip sayisi kapanista yoksayilir).
}

{$mode delphi}

interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections, VDbTable, VDbSql,
  VDbAst, VDbErr, VDbXPrims, VDbCore, VDbPlatform;
  { R-12: VDbCore -> TVDb (motor). VDbXPrims -> SHM + isimli mutex.
    Windows (implementation uses) -> GetCurrentProcessId/ThreadId,
    Interlocked* atomikleri. }

{ R-12: SHM'de slot basina yer kaplayan byte miktari. TConnectionSlot
  packed record ve TPoolHeader'in arkasinda dizi halinde durur; her
  slot "kendi mutex'unu tutuyor mu" bilgisini TConnectionSlot.Active
  alaninda barindirir, ayrica bir slot kilidini gosteren bayt da
  tutariz (AcquireSlot/ReleaseSlot yari sartini SHM uzerinde kurar). }
const
  VDB_POOL_SHM_SIZE = 4096;

type
  TVDbPool = class
  private
    FTb: TVTableDb;
    FSize: Integer;
    FLock: TCriticalSection;
    FAvail: TEvent;               // bosta baglanti sinyali
    FIdle: TList<TVSql>;          // bosta ornekler
    FAll: TList<TVSql>;           // havuzun urettigi tum ornekler (sahiplik)
    FOut: Integer;                // disaridaki ornek sayisi
    FClosed: Boolean;
    FTimeoutMs: Integer;
    { ---- R-12 cok surec katmani ---- }
    FShm: TSharedMemory;        // paylasilan slot havuzu
    FMySlot: Integer;           // bu surecin slotu (-1 = yalniz yerel)
    FSlotBusy: Boolean;         // slotun kestigi bayt (0/1)
    FMutex: TCriticalSectionEx; // DB dosya kilidi (prosesler arasi)
    { CreateXProc motoru KENDISI acar; o motoru havuzun serbest
      birakmasi gerekir. Aksi halde .odb dosyasi havuz Free edildikten
      SONRA da kilitli kalir ve "dosya kullanimda" hatasi verilir. }
    FOwnedKv: TVDb;
    FOwnedTb: TVTableDb;
    { R-12: motor .odb dosyasini OZEL (exclusive) kilit ile acar.
      Bu yuzden iki surec ayni anda motoru AÇAMAZ. Dogru model
      "serilestirilmis cok surec"dir: Acquire'da isimli mutex alinir,
      motor acilir; Release'de motor kapatilir ve mutex birakilir.
      Boylece N surec guvenle calisir (kaynak paylasimi SHM slotlari
      ile, erisim siralamasi isimli mutex ile). }
    FXProcDir: string;
    procedure OpenEngine;
    procedure CloseEngine;
    procedure InitXProc(const AXName: string);
    procedure DoneXProc;
    function AcquireSlot: Boolean;
    procedure ReleaseSlot;
  public
    constructor Create(ATableDb: TVTableDb; ASize: Integer = 8;
      ATimeoutMs: Integer = 5000); overload;
    { R-12: cok surec havuz. AName SHM/mutex adini belirler (ornegin
      veritabani klasoru adi). ADataDir verilirse motor oradan acilir;
      verilmezse ATableDb'nin dizini kullanilir. }
    constructor CreateXProc(const AXName, ADataDir: string; ASize: Integer = 8;
      ATimeoutMs: Integer = 5000);
    destructor Destroy; override;
    // Kullanimlik ornek al (yoksa TimeoutMs bekler).
    function Acquire: TVSql;
    // Geri ver (baska thread uyandirilir).
    procedure Release(Sql: TVSql);
    // Kapat: yeni Acquire reddedilir, bekleyenler hata ile uyanir.
    // Geri gelen baglantilar serbest kalir.
    procedure Close;
    // Tek seferlik: al + calistir + geri ver.
    function Exec(const Sql: string): TSqlResult; overload;
    function Exec(const Sql: string; const Params: array of string): TSqlResult; overload;
    property Size: Integer read FSize;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    // Su an disaridaki ornek sayisi (gozlem).
    function ActiveCount: Integer;
    { ---- R-12 gozlem API ---- }
    // Bu surecin SHM slotu (-1 = yok).
    property SlotId: Integer read FMySlot;
    // Paylasilan SHM uzerindeki aktif slot sayisi (butun surecler).
    function SharedActiveCount: Integer;
    // Cok surec modunda mi?
    function IsXProc: Boolean;
  end;

implementation

{ NOT: Burada ASLA `uses Windows` yazilmaz. FPC'nin Windows birimi
  `TCriticalSection` ve `TEvent` tiplerini KENDISI de disa aktarir;
  uses listesinde SONRA gelen birim kazanir, SyncObjs'teki
  TCriticalSection.Create gölgelenir ve "no member Create" hatasi
  verir. Gerekli Win32 cagrilari asagda ACIKCA bildiriliyor. }
{$IFDEF WINDOWS}
function GetCurrentProcessId: THandle; stdcall; external 'kernel32.dll' name 'GetCurrentProcessId';
function GetCurrentThreadId: THandle; stdcall; external 'kernel32.dll' name 'GetCurrentThreadId';
function InterlockedCompareExchange(var Destination: LongInt; Exchange,
  Comperand: LongInt): LongInt; stdcall; external 'kernel32.dll';
function InterlockedIncrement(var Target: LongInt): LongInt; stdcall; external 'kernel32.dll';
function InterlockedDecrement(var Target: LongInt): LongInt; stdcall; external 'kernel32.dll';
{$ENDIF}

constructor TVDbPool.Create(ATableDb: TVTableDb; ASize: Integer;
  ATimeoutMs: Integer);
var
  i: Integer;
begin
  inherited Create;
  if ATableDb = nil then
    raise EVDbException.Create(ecInvalidArgument,
      'TVDbPool: tablo katmani verilmedi');
  if ASize < 1 then ASize := 1;
  FTb := ATableDb;
  FSize := ASize;
  FTimeoutMs := ATimeoutMs;
  // NOT: TCriticalSection/TEvent SyncObjs'ten gelir; interface uses'te
  // zaten var. Implementation uses'e SADECE Windows eklenir (asagida).
  FLock := TCriticalSection.Create;
  // Manuel-reset degil: tek bekleyeni uyandirir (otomatik sifirlanir).
  FAvail := TEvent.Create(nil, False, False, '');
  FIdle := TList<TVSql>.Create;
  FAll := TList<TVSql>.Create;
  for i := 1 to FSize do
  begin
    FIdle.Add(TVSql.Create(FTb));
    FAll.Add(FIdle[FIdle.Count - 1]);
  end;
  FOut := 0;
  FClosed := False;
  // R-12: varsayilan TEK surec modu. CreateXProc ile cok surece
  // gecirilir.
  FShm := nil;
  FMySlot := -1;
  FSlotBusy := False;
  FMutex := nil;
end;

{ ------------------------------------------------------------------
  R-12: cok surec katmani
  ------------------------------------------------------------------ }

function TVDbPool.IsXProc: Boolean;
begin
  Result := (FShm <> nil);
end;

function TVDbPool.SharedActiveCount: Integer;
begin
  if FShm = nil then Exit(FOut);
  Result := FShm.ActiveCount;
end;

procedure TVDbPool.InitXProc(const AXName: string);
{ SHM acilir (yoksa yaratilir), havuz boyutu yazilir, bu surec slot
  alir. Dosya kilidi icin prosesler arasi isimli mutex kurulur.
  NOT: TSharedMemory.Create(ACreate=True) ilk cagiran yaratir, digerleri
  var OLANI acar; boylece "kim sahibi" ayrimi otomatik olur.
  Motor BURADA acilmaz - Acquire'da FMutex ile acilir. }
begin
  { NOT: BURADA FXProcDir ATANMAZ. AXName SHM/mutex adi olup veri
    DIZINI degildir; atanirsa motor yanlis dizinde bos bir veritabani
    acar ve "tablo yok" hatasi dogar. Dizin CreateXProc'ta kurulur. }
  FShm := TSharedMemory.Create(SHMHash(AXName), VDB_POOL_SHM_SIZE, True);
  try
    FShm.SetPoolSize(FSize);
    { Eski (orphan) slotlari temizle. Kiralamalar ATOMIK oldugu
      icin, bir onceki surecin olmus baytlari da burada duzelir. }
    FShm.CleanOrphans(VDB_SHM_ORPHAN_TIMEOUT_S);
    { NOT: burada slot kiralanmaz. Slot = bir ACIK BAGLANTI'yi
      temsil eder ve Acquire/Release arasinda tutulur. Surec
      basina ayrica slot kiralamak kapasiteyi yaridan dusuruyordu
      ve iki yer tutuyordu. }
    FMySlot := -1;
  except
    FreeAndNil(FShm);
    raise;
  end;
  FMutex := TCriticalSectionEx.Create('DB_' + AXName, '');
end;

procedure TVDbPool.OpenEngine;
{ Moturu acar. Cagiran once FMutex'u almis OLMALI. }
begin
  if FOwnedKv <> nil then Exit;
  FOwnedKv := TVDb.Create;
  FOwnedTb := TVTableDb.Create(FOwnedKv);
  try
    FOwnedKv.Open(FXProcDir);
    FOwnedTb.Open(FXProcDir);
  except
    on E: Exception do
    begin
      FreeAndNil(FOwnedTb);
      FreeAndNil(FOwnedKv);
      FTb := nil;
      raise E;
    end;
  end;
  { NOT: FTb ATANMALI. Acquire icinde TVSql.Create(FTb) cagriliyor;
    FTb nil kalirsa TVSql nil tablo katmaniyla kurulur ve
    Access violation olur. }
  FTb := FOwnedTb;
end;

procedure TVDbPool.CloseEngine;
{ Motoru kapatir. Cagiran, FMutex hala tutuyorken cagirir. }
begin
  FTb := nil;
  if FOwnedTb <> nil then
  begin
    FOwnedTb.Close;
    FreeAndNil(FOwnedTb);
  end;
  if FOwnedKv <> nil then
  begin
    FOwnedKv.Close;
    FreeAndNil(FOwnedKv);
  end;
end;

procedure TVDbPool.DoneXProc;
begin
  if FMySlot > 0 then ReleaseSlot;
  if FMutex <> nil then
  begin
    FreeAndNil(FMutex);
  end;
  if FShm <> nil then
  begin
    { SHM'i UNLINK ETME: baska surecler bagli olabilir. Sahibi
      (ilk yaratan) kapanirken bile yer birakilir; boylece isim
      cekirgesi olusmaz ve yeni surecler ayni adi kullanabilir. }
    FreeAndNil(FShm);
    FMySlot := -1;
  end;
end;

function TVDbPool.AcquireSlot: Boolean;
{ SHM'de bos slotu ATOMIK olarak kiralamayi dener (TryAllocateSlot).
  Slot sayisi tukendiyse TimeoutMs dolana kadar bekler.
  NOT: onceki surumde slot kiralamasi VDbPool'un KENDI Interlocked
  koduyla yapiliyordu ve InitXProc ayrica bir slot daha kiraliyordu
  (surec basina 2 slot). Artik tek ve atomik yol var:
  VDbXPrims.TryAllocateSlot. }
var
  Deadline: Int64;
  id: Integer;
begin
  Result := False;
  if FShm = nil then Exit(True);        // tek surec modu
  Deadline := VdbTickMs + FTimeoutMs;
  repeat
    id := FShm.TryAllocateSlot;
    if id > 0 then
    begin
      FMySlot := id;
      Result := True;
      Exit;
    end;
    Sleep(10);
  until VdbTickMs >= Deadline;
end;

procedure TVDbPool.ReleaseSlot;
begin
  if FShm = nil then Exit;
  if FMySlot > 0 then
  begin
    InterlockedDecrement(PPoolHeader(FShm.Header)^.ActiveConnections);
    FShm.ReleaseSlot(FMySlot);
    FMySlot := -1;
  end;
end;

constructor TVDbPool.CreateXProc(const AXName, ADataDir: string; ASize: Integer;
  ATimeoutMs: Integer);
begin
  if ASize < 1 then ASize := 1;
  FSize := ASize;
  FTimeoutMs := ATimeoutMs;
  FLock := TCriticalSection.Create;
  FAvail := TEvent.Create(nil, False, False, '');
  FIdle := TList<TVSql>.Create;
  FAll := TList<TVSql>.Create;
  FOut := 0;
  FClosed := False;
  FMySlot := -1;
  FSlotBusy := False;
  FXProcDir := ADataDir;
  { NOT: Motor BURADA ACILMAZ. .odb dosyasi ozel kilitlidir; iki
    surec ayni anda motoru acamaz. Motor Acquire'da isimli mutex
    alindiktan SONRA acilir, Release'de kapatilir. }
  InitXProc(AXName);
end;

destructor TVDbPool.Destroy;
var
  i: Integer;
begin
  FLock.Enter;
  try
    FClosed := True;
    for i := 0 to FIdle.Count - 1 do
      FIdle[i].Free;
    FIdle.Free;
    FAll.Free;
    // Disaridaki ornekler uygulamaya aittir (dokumante); burada
    // serbest birakilmaz (cift-free riski).
  finally
    FLock.Leave;
  end;
  FAvail.Free;
  FLock.Free;
  { R-12: slotu birak ve SHM'i kapat. DB kilidi (FMutex) once
    serbest birakilmali ki baska surecler kilitli kalmasin. }
  DoneXProc;
  { CreateXProc ile ACILAN motoru havuz kapatir. Yapilmazsa .odb
    dosyasi havuz Free olduktan sonra da kilitli kalir ve yeniden
    acma "dosya kullanimda" hatasi verir. }
  if FOwnedTb <> nil then begin FOwnedTb.Close; FreeAndNil(FOwnedTb); end;
  if FOwnedKv <> nil then begin FOwnedKv.Close; FreeAndNil(FOwnedKv); end;
  FTb := nil;
  inherited;
end;

function TVDbPool.Acquire: TVSql;
var
  W: TWaitResult;
  HaveSlot: Boolean;
  Locked: Boolean;
begin
  { R-12: 1) paylasilan SHM'den slot kirala -> surec kapasitesi sinirli.
             2) isimli mutex al -> motor dosyasi ozel kilitli, sirali
                erisim sart. }
  HaveSlot := AcquireSlot;
  if not HaveSlot then
    raise EVDbException.CreateFmt(ecPoolTimeout,
      'TVDbPool: paylasilan slot yok (%d ms, kapasite=%d)',
      [FTimeoutMs, FSize]);
  Locked := False;
  if FMutex <> nil then
  begin
    FMutex.Enter;
    Locked := True;
  end;
  try
    OpenEngine;   // cok surec modunda motoru simdi ac
    if FShm <> nil then
      InterlockedIncrement(PPoolHeader(FShm.Header)^.ActiveConnections);
  except
    if Locked then FMutex.Leave;
    ReleaseSlot;
    raise;
  end;
  try
    FLock.Enter;
    try
      if FClosed then
        raise EVDbException.Create(ecPoolClosed,
          'TVDbPool: havuz kapali');
      Result := TVSql.Create(FTb);
      Inc(FOut);
    finally
      FLock.Leave;
    end;
  except
    CloseEngine;
    if Locked then FMutex.Leave;
    ReleaseSlot;
    raise;
  end;
end;

procedure TVDbPool.Release(Sql: TVSql);
{ NOT: Sql = nil OLABILIR ve BU BIR HATA DEGILDIR. Cagiran bazen
  yalnizca "is parcam bitti, kilidi birak" demek ister (orn. slot
  sayimi testi). Onceki surumde `if Sql = nil then Exit` vardi ve
  bu durumda slot ASLA birakilmiyordu -> kapasite siziyordu. }
begin
  if Sql <> nil then
  begin
    // Cok surec modunda TVSql ornegi is parcasi basina olusturulur;
    // burada serbest birakilir.
    Sql.Free;
    FLock.Enter;
    try
      if FOut > 0 then Dec(FOut);
    finally
      FLock.Leave;
    end;
  end;
  { R-12: sirasi: motoru kapat -> isimli mutex'i birak -> SHM slotunu
    birak. Motori kapatmadan mutex birakilirsa baska surec dosyayi
    acamaz. }
  CloseEngine;
  if FMutex <> nil then FMutex.Leave;
  ReleaseSlot;
end;

procedure TVDbPool.Close;
begin
  FLock.Enter;
  try
    FClosed := True;
    // Bekleyen Acquire'lar hata ile uyanir.
    FAvail.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TVDbPool.Exec(const Sql: string): TSqlResult;
var
  Q: TVSql;
begin
  { Bkz. VDbSql.ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  Q := Acquire;
  try
    Result := Q.Exec(Sql);
  finally
    Release(Q);
  end;
end;

function TVDbPool.Exec(const Sql: string;
  const Params: array of string): TSqlResult;
var
  Q: TVSql;
begin
  { Bkz. VDbSql.ExecRaw: gecici kayit sonucu sifirlanmamis olabilir. }
  FillChar(Result, SizeOf(Result), 0);
  Q := Acquire;
  try
    Result := Q.Exec(Sql, Params);
  finally
    Release(Q);
  end;
end;

function TVDbPool.ActiveCount: Integer;
begin
  FLock.Enter;
  try
    Result := FOut;
  finally
    FLock.Leave;
  end;
end;

end.
