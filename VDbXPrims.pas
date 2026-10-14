unit VDbXPrims;

{ Faz A - R-12 Connection Pool (Multi-Process)
  ===========================================
  Cross-process primitifler:
    - TCriticalSectionEx : isimli mutex (Windows: CreateMutex / Unix: fcntl)
    - TSharedMemory      : paylasilan bellek (Windows: FileMapping / Unix: shm_open)
    - SHM Header + Connection Slot yapi + orphan temizleme
  Derleyici kontrol: Windows veya UNIX ifdef'li.
}

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, VDbPlatform;

const
  // SHM Magic: 'VDBL' ("VdB Locker")
  VDB_SHM_MAGIC   = $4C424456;
  VDB_SHM_VERSION = 1;
  // Varsayilan heartbeat / orphan tespit sureleri (sn)
  VDB_SHM_HEARTBEAT_INTERVAL_S = 5;
  VDB_SHM_ORPHAN_TIMEOUT_S     = 30;

type
  EPrimsError = class(Exception);
  EPrimsOrphan = class(EPrimsError);

  // ------------------------------------------------------------------
  // Cross-process mutex: Windows isimli mutex  /  Unix fcntl kilidi
  // ------------------------------------------------------------------
  TCriticalSectionEx = class
  private
    // Windows
    {$IFDEF WINDOWS}
    FHandle: THandle;
    FLockNameW: WideString;
    {$ELSE}
    FLockFd: Integer;
    FLockDir: string;
    {$ENDIF}
    FLockName: string;
    FLocked: Boolean;
    {$IFDEF WINDOWS}
    procedure CreateHandle;
    procedure ReleaseHandle;
    function Lock: Boolean;
    procedure Unlock;
    {$ELSE}
    function LockUnix(var Errno: Integer): Boolean;
    procedure UnlockUnix;
    {$ENDIF}
  public
    constructor Create(ALockName: string; ALockDir: string = '');
    destructor Destroy;
    procedure Enter; overload;
    procedure TryEnter(out Success: Boolean);
    procedure Enter(AMSec: Integer); overload;
    procedure Leave;
    property Locked: Boolean read FLocked;
  end;

  // ------------------------------------------------------------------
  // SHM yapi: Header (ilk sayfada) + connection slot dizisi
  // ------------------------------------------------------------------
  PPoolHeader = ^TPoolHeader;
  TPoolHeader = packed record
    Magic: QWord;
    Version: Integer;
    Flags: Integer;
    // kim yaratti / guncelledi
    ProcessID: Cardinal;
    ThreadID: TThreadID;
    SessionID: Int64;
    CreationTime: Int64;
    LastHeartbeat: Int64;
    // pool durumu
    ConnectionCount: Integer;   // havuzun gecerli baglanti limit
    ActiveConnections: Integer; // aktif baglanti sayisi
    NextConnectionID: Integer;  // birakilan slotlar tekrardan kullanilabilir
    Reserved: array[0..63] of Byte;
  end;

  PConnectionSlot = ^TConnectionSlot;
  TConnectionSlot = packed record
    ConnectionID: Integer;
    ProcessID: Cardinal;
    ThreadID: TThreadID;
    LastAccessTime: Int64;
    Active: Boolean;
    Flags: Integer;
    Reserved: array[0..112] of Byte;
  end;

  // ------------------------------------------------------------------
  // Paylasilan bellek yonetici
  // ------------------------------------------------------------------
  TSharedMemory = class
  private
    FHandle: THandle;
    FMemory: Pointer;
    FSize: Integer;
    FIsOwner: Boolean;
    FHeader: PPoolHeader;
    FSlots: PConnectionSlot;
    FSlotsCount: Integer;
    FName: string;   // SHM ismi (Unlink icin)
    procedure MapMemory;
    procedure UnmapMemory;
    procedure EnsureHeader;
    function SlotAt(Offset: Integer): PConnectionSlot;
  public
    constructor Create(AName: string; ASize: Integer); overload;
    constructor Create(AName: string; ASize: Integer; ACreate: Boolean); overload;
    destructor Destroy; override;
    function AcquireHeader: PPoolHeader;
    function GetSlot(ID: Integer): PConnectionSlot;
    function SlotRec(ID: Integer): PConnectionSlot;
    function AllocateSlot: Integer;
    { Atomik "dene-ve-al": basarili olmazsa -1 doner, HATA VERMEZ.
      Zaman asimi dolana kadar yeniden denemek icin. }
    function TryAllocateSlot: Integer;
    { Su an KIRALI olan slot'lar "id:sahipPID" listesi olarak
      (virgulle ayrilmis TEK string; ornegin "1:31480,3:22104").
      Bos degilse kirali slot vardir.
      R-12 testi bunu kullanir: kiralamadan hemen sonra okunan
      listede KENDI slotumun sahibi benim PID'im olmalidir. listede
      benim slotum BAŞKA bir PID ile gorunuyorsa yaris sart
      calismiyor demektir. }
    function ClaimedSlots: string;
    procedure ReleaseSlot(ID: Integer);
    { Kiralanan slotun heartbeat'ini tazeler; CleanOrphans'in
      sagli baglantilari yanlislikla temizlemesini onler. }
    procedure TouchSlot(ID: Integer);
    procedure Heartbeat;
    procedure CleanOrphans(ATimeoutSec: Integer = VDB_SHM_ORPHAN_TIMEOUT_S);
    function ThreadToID: Int64;
    class function CurrentProcessID: Cardinal; overload; static;
    class function CurrentThreadID: TThreadID; overload; static;
    function ActiveCount: Integer;
    function LastActivity: Int64;
    procedure SetPoolSize(ACount: Integer);
    procedure Unlink;
    property Size: Integer read FSize;
    property Header: PPoolHeader read FHeader;
    property IsOwner: Boolean read FIsOwner;
    property SlotsCount: Integer read FSlotsCount;
  end;

function SHMHash(const S: string): string;

// R-12: shared memory uzerinde ATOMIK islemler. Once yalniz TActive
// baytigi okunup yaziliyordu; iki surec ayni anda ayni slotu
// kiralamis olabiliyordu. Bunlar tek islemde "kirala/birak" yapar.
// NOT: bu birim Windows'ta `Windows`u uses ALMAZ; FPC'nin Windows
// birimi TCriticalSection/TEvent'i gölgelliyordu. Gerekli Win32
// cagrilari acikca bildiriliyor.
{$IFDEF WINDOWS}
function InterlockedCompareExchange(var Destination: LongInt; Exchange,
  Comperand: LongInt): LongInt; stdcall; external 'kernel32.dll';
function InterlockedIncrement(var Target: LongInt): LongInt; stdcall; external 'kernel32.dll';
function InterlockedDecrement(var Target: LongInt): LongInt; stdcall; external 'kernel32.dll';
function InterlockedExchange(var Target: LongInt; Value: LongInt): LongInt; stdcall; external 'kernel32.dll';
{$ENDIF}

implementation

uses
  {$IFDEF WINDOWS}
  Windows;
  {$ENDIF}
  {$IFDEF UNIX}
  BaseUnix, Unix, fcntl, Types, SysUtils;
  {$ENDIF}

// ==================================================================
// TCriticalSectionEx
// ==================================================================

{$IFDEF WINDOWS}

constructor TCriticalSectionEx.Create(ALockName: string; ALockDir: string);
begin
  inherited Create;
  FLockName := ALockName;
  FLockNameW := 'VDBMutex_' + ALockName;
  FLocked := False;
  CreateHandle;
end;

procedure TCriticalSectionEx.CreateHandle;
begin
  FHandle := CreateMutex(nil, False, PChar(FLockNameW));
  Writeln('DBG CH name=', FLockNameW, ' len=', IntToStr(Length(FLockNameW)), ' handle=', IntToStr(FHandle));
  Flush(Output);
  if FHandle = 0 then
    raise EPrimsError.CreateFmt('TCriticalSectionEx: mutex yaratilamadi %s', [FLockName]);
end;

procedure TCriticalSectionEx.ReleaseHandle;
var
  h: THandle;
begin
  h := FHandle;
  FHandle := 0;
  if h <> 0 then
    CloseHandle(h);
end;

function HexStr(S: AnsiString): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    Result := Result + IntToHex(Ord(S[I]), 2);
end;

function TCriticalSectionEx.Lock;
var
  Res: DWORD;
  T0: Int64;
begin
  T0 := VdbTickMs;
  Res := WaitForSingleObject(FHandle, 10000);
  Writeln('DBG Lock FHandle=', IntToStr(FHandle), ' Res=', IntToStr(Res),
    ' ms=', IntToStr(VdbTickMs - T0), ' Tick=', IntToStr(VdbTickMs));
  Flush(Output);
  if Res = WAIT_TIMEOUT then
    Writeln('DBG Lock LOCK TIMEOUT - mutex baska proses tarafindan tutuluyor, FLocked:=False');
  case Res of
    WAIT_OBJECT_0:
      Result := True;
    WAIT_ABANDONED:
    begin
      // önceki sahipli proses koptu; mutex birakilmis sayilir
      // ve bekleyen ele gecmistir (Delphi TMutex davranisi)
      Result := True;
      FLocked := True;
    end;
  else
    Result := False;
  end;
  FLocked := Result;
  if Result and (Res = WAIT_OBJECT_0) then
  begin
    Writeln('DBG Lock ACQUIRED FHandle=', IntToStr(FHandle), ' Res=', IntToStr(Res),
      ' ms=', IntToStr(VdbTickMs - T0));
    Flush(Output);
  end;
end;

procedure TCriticalSectionEx.Unlock;
begin
  if FLocked then
  begin
    ReleaseMutex(FHandle);
    FLocked := False;
  end
  else
    raise EPrimsError.Create('TCriticalSectionEx: kilit yokken unlock çağrıldı (bug)');
end;

{$ENDIF}
// Unix tarafı aşağıda ayrı bloktadır

{$IFDEF UNIX}

const
  VDB_LOCK_PREFIX = 'vdblock_';

constructor TCriticalSectionEx.Create(ALockName: string; ALockDir: string);
var
  LPath: string;
begin
  inherited Create;
  FLockName := ALockName;
  if ALockDir = '' then
    FLockDir := GetTempDir
  else
    FLockDir := ALockDir;
  FLocked := False;
  LPath := IncludeTrailingPathDelimiter(FLockDir) + VDB_LOCK_PREFIX + ALockName + '.lock';
  FLockFd := FpOpen(PChar(LPath), O_RDWR or O_CREAT or O_TRUNC, 0o644);
  if FLockFd < 0 then
    raise EPrimsError.CreateFmt('TCriticalSectionEx: kilid dosyasi acilamadi %s', [LPath]);
end;

procedure TCriticalSectionEx.ReleaseHandle;
begin
  if FLockFd >= 0 then
  begin
    Close(FLockFd);
    FLockFd := -1;
  end;
end;

function TCriticalSectionEx.LockUnix(var Errno: Integer): Boolean;
var
  L: TFileLock;
  i: Integer;
begin
  Errno := 0;
  L.l_type := F_WRLCK;
  L.l_whence := SEEK_SET;
  L.l_start := 0;
  L.l_len := 0;
  for i := 0 to 20 do
  begin
    if fcntl(FLockFd, F_SETLKW, @L) = 0 then
    begin
      Result := True;
      FLocked := True;
      Exit;
    end;
    Errno := GetErrno;
    if Errno = EINTR then
      Continue
    else
      Break;
  end;
  Result := False;
end;

procedure TCriticalSectionEx.UnlockUnix;
var
  L: TFileLock;
begin
  if FLocked then
  begin
    L.l_type := F_UNLCK;
    L.l_whence := SEEK_SET;
    L.l_start := 0;
    L.l_len := 0;
    fcntl(FLockFd, F_SETLK, @L);
    FLocked := False;
  end;
end;

{$ENDIF}

destructor TCriticalSectionEx.Destroy;
begin
  if FLocked then
    Leave;
  ReleaseHandle;
  inherited;
end;

procedure TCriticalSectionEx.Enter;
begin
  {$IFDEF WINDOWS}
  Lock;
  {$ELSE}
  {$IFDEF UNIX}
  LockUnix(0);
  {$ENDIF}
  {$ENDIF}
end;

procedure TCriticalSectionEx.TryEnter(out Success: Boolean);
var
  {$IFDEF WINDOWS}
  Res: DWORD;
  {$ELSE}
  {$IFDEF UNIX}
  Errno: Integer;
  L: TFileLock;
  {$ENDIF}
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  Res := WaitForSingleObject(FHandle, 0);
  Success := (Res = WAIT_OBJECT_0);
  FLocked := Success;
  {$ELSE}
  {$IFDEF UNIX}
  Errno := 0;
  L.l_type := F_WRLCK;
  L.l_whence := SEEK_SET;
  L.l_start := 0;
  L.l_len := 0;
  Success := fcntl(FLockFd, F_SETLK, @L) = 0;
  FLocked := Success;
  if not Success then
    Errno := GetErrno;
  {$ENDIF}
  {$ENDIF}
end;

procedure TCriticalSectionEx.Enter(AMSec: Integer);
var
  {$IFDEF WINDOWS}
  Res: DWORD;
  {$ELSE}
  {$IFDEF UNIX}
  Errno: Integer;
  L: TFileLock;
  Start: Int64;
  {$ENDIF}
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  Writeln('DBG Enter AMSec=', AMSec, ' Tick=', IntToStr(VdbTickMs), ' FHandle=', IntToStr(FHandle));
  Flush(Output);
  Res := WaitForSingleObject(FHandle, AMSec);
  Writeln('DBG Enter Res=', IntToStr(Res), ' Tick=', IntToStr(VdbTickMs));
  Flush(Output);
  if Res = WAIT_OBJECT_0 then
    FLocked := True
  else
    raise EPrimsError.CreateFmt('TCriticalSectionEx: %d ms icinde kilit alinamadi', [AMSec]);
  {$ELSE}
  {$IFDEF UNIX}
  Errno := 0;
  L.l_type := F_WRLCK;
  L.l_whence := SEEK_SET;
  L.l_start := 0;
  L.l_len := 0;
  Start := VdbTickMs;
  while True do
  begin
    if fcntl(FLockFd, F_SETLKW, @L) = 0 then
    begin
      FLocked := True;
      Exit;
    end;
    Errno := GetErrno;
    if Errno = EINTR then
      Continue;
    if (VdbTickMs - Start) > (AMSec)
      raise EPrimsError.CreateFmt('TCriticalSectionEx: %d ms icinde kilit alinamadi', [AMSec]);
    Sleep(5);
  end;
  {$ENDIF}
  {$ENDIF}
end;

procedure TCriticalSectionEx.Leave;
begin
  {$IFDEF WINDOWS}
  Unlock;
  {$ELSE}
  {$IFDEF UNIX}
  UnlockUnix;
  {$ENDIF}
  {$ENDIF}
end;

// ==================================================================
// TSharedMemory
// ==================================================================

{$IFDEF WINDOWS}

constructor TSharedMemory.Create(AName: string; ASize: Integer);
begin
  Create(AName, ASize, False);
end;

constructor TSharedMemory.Create(AName: string; ASize: Integer; ACreate: Boolean);
var
  WName: string;
begin
  inherited Create;
  FHandle := 0;
  FMemory := nil;
  FIsOwner := False;
  FSize := ASize;
  FName := AName;
  // Windows isimli mapping: islem-disi gorunurlugu saglar.
  WName := 'VDBSHM_' + AName;
  FHandle := CreateFileMapping(THandle(-1), nil, PAGE_READWRITE,
    0, ASize, PChar(WName));
  if FHandle = 0 then
    raise EPrimsError.CreateFmt('TSharedMemory: map acilamadi %s', [AName]);
  // CreateFileMapping: yeni mapping yaratti (GetLastError=SUCCESS) ya da
  // var olanini acar (GetLastError=ERROR_ALREADY_EXISTS); her iki halde
  // handle alicidir.
  if ACreate then
    FIsOwner := (GetLastError <> ERROR_ALREADY_EXISTS)
  else
    FIsOwner := False;
  // Dosya boyutunu kontrol et (oldu gibi boyutla).
  MapMemory;
  if ACreate and (FHeader.Magic <> VDB_SHM_MAGIC) then
  begin
    // ilk baglanan = owner; header'i bas.
    EnsureHeader;
  end;
end;

procedure TSharedMemory.MapMemory;
begin
  if FSize > 0 then
  begin
    FMemory := MapViewOfFile(FHandle, FILE_MAP_ALL_ACCESS, 0, 0, FSize);
    if FMemory = nil then
      raise EPrimsError.CreateFmt('TSharedMemory: goruntu olusturulamadi %s', ['']);
    FHeader := PPoolHeader(FMemory);
    FSlots := PConnectionSlot(PChar(FMemory) + SizeOf(TPoolHeader));
    FSlotsCount := (FSize - SizeOf(TPoolHeader)) div SizeOf(TConnectionSlot);
  end;
end;

{$ELSE}

{$IFDEF UNIX}

constructor TSharedMemory.Create(AName: string; ASize: Integer);
begin
  Create(AName, ASize, False);
end;

constructor TSharedMemory.Create(AName: string; ASize: Integer; ACreate: Boolean);
var
  LFlags, LErr: Integer;
  st: TStatBuf;
  SName: string;
begin
  inherited Create;
  FHandle := -1;
  FMemory := nil;
  FIsOwner := False;
  FSize := ASize;
  FName := AName;
  SName := 'vdbshm_' + AName;
  LFlags := O_RDWR;
  if ACreate then
    LFlags := LFlags or O_CREAT or O_EXCL;
  FHandle := shm_open(PChar(SName), LFlags, 0o666);
  LErr := GetErrno;
  if FHandle < 0 then
  begin
    if ACreate and (LErr = EEXIST) then
    begin
      // Basikasi yaratti: var olanini bagla (owner degiliz).
      FHandle := shm_open(PChar(SName), O_RDWR, 0o666);
      if FHandle < 0 then
        raise EPrimsError.CreateFmt('TSharedMemory: shm var olanini baglanamadi %s', [AName]);
      FIsOwner := False;
    end
    else
      raise EPrimsError.CreateFmt('TSharedMemory: shm_acilamadi %s', [AName]);
  end
  else
    FIsOwner := True;  // O_EXCL ile biz yarattik.
  // Boyut kontrolu: header + slotlar yeterli mi?
  if fstat(FHandle, st) = 0 then
  begin
    if UInt64(st.st_size) < ASize then
    begin
      if ftruncate(FHandle, ASize) < 0 then
      begin
        Close(FHandle);
        FHandle := -1;
        raise EPrimsError.CreateFmt('TSharedMemory: shm_truncate basarisiz, hata=%d', [GetErrno]);
      end;
    end;
  end;
  MapMemory;
  if ACreate and (FHeader.Magic <> VDB_SHM_MAGIC) then
    EnsureHeader;
end;

procedure TSharedMemory.MapMemory;
begin
  if FHandle < 0 then Exit;
  FMemory := mmap(nil, FSize, PROT_READ or PROT_WRITE, MAP_SHARED, FHandle, 0);
  if FMemory = MAP_FAILED then
  begin
    FMemory := nil;
    raise EPrimsError.CreateFmt('TSharedMemory: mmap basarisiz, hata=%d', [GetErrno]);
  end;
  FHeader := PPoolHeader(FMemory);
  FSlots := PConnectionSlot(PChar(FMemory) + SizeOf(TPoolHeader));
  FSlotsCount := (FSize - SizeOf(TPoolHeader)) div SizeOf(TConnectionSlot);
end;

{$ENDIF}

{$ENDIF}

destructor TSharedMemory.Destroy;
begin
  UnmapMemory;
  if FHandle <> 0 then
  begin
    {$IFDEF WINDOWS}
    UnmapViewOfFile(FMemory);
    CloseHandle(FHandle);
    {$ELSE}
    {$IFDEF UNIX}
    if FMemory <> nil then munmap(FMemory, FSize);
    if FHandle >= 0 then
    begin
      // SHM ismini silme gorevi atamasina gore; burada sadece
      // descriptor'u kapatiyoruz. (Yapilmasi gereken: session sona eriginde
      // shm_unlink cagrisi.)
      Close(FHandle);
    end;
    {$ENDIF}
    {$ENDIF}
    FHandle := 0;
  end;
  FMemory := nil;
  FHeader := nil;
  inherited;
end;

procedure TSharedMemory.UnmapMemory;
begin
  if FMemory <> nil then
  begin
    {$IFDEF WINDOWS}
    UnmapViewOfFile(FMemory);
    {$ELSE}
    {$IFDEF UNIX}
    munmap(FMemory, FSize);
    {$ENDIF}
    {$ENDIF}
    FMemory := nil;
  end;
end;

procedure TSharedMemory.EnsureHeader;
begin
  FillChar(FHeader^, SizeOf(TPoolHeader), 0);
  FHeader.Magic := VDB_SHM_MAGIC;
  FHeader.Version := VDB_SHM_VERSION;
  FHeader.CreationTime := VdbTickMs;
  FHeader.LastHeartbeat := VdbTickMs;
  FHeader.ProcessID := CurrentProcessID;
  FHeader.ThreadID := CurrentThreadID;
  FHeader.SessionID := ThreadToID;
  FHeader.ConnectionCount := 0;
  FHeader.NextConnectionID := 1;
  FHeader.ActiveConnections := 0;
end;

function TSharedMemory.AcquireHeader: PPoolHeader;
begin
  // Header'a ulasim once kilitleme gerektirmez (degerler atomik degilse,
  // cagirici farkli bir kilitleme kullanir).
  FHeader.LastHeartbeat := VdbTickMs;
  FHeader.ProcessID := CurrentProcessID;
  FHeader.ThreadID := CurrentThreadID;
  Result := FHeader;
end;

function TSharedMemory.SlotAt(Offset: Integer): PConnectionSlot;
begin
  if (Offset >= 0) and (Offset < FSlotsCount) then
    Result := PConnectionSlot(PChar(FSlots) + Offset * SizeOf(TConnectionSlot))
  else
    Result := nil;
end;

function TSharedMemory.GetSlot(ID: Integer): PConnectionSlot;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FSlotsCount - 1 do
    if SlotRec(i).ConnectionID = ID then
    begin
      Result := SlotRec(i);
      Break;
    end;
end;

function TSharedMemory.SlotRec(ID: Integer): PConnectionSlot;
begin
  Result := PConnectionSlot(PChar(FSlots) + ID * SizeOf(TConnectionSlot));
end;

function TSharedMemory.AllocateSlot: Integer;
{ Slot kiralamasi ATOMIK yapilir.
  NOT: Onceki surumde "ilk uygun slotu bul, Active=True yap" seklinde
  idi; iki surec ayni anda tarama yaparsa AYNI slotu ikisi de
  alabiliyordu (shared memory uzerinde yari sart olmadigi icin).
  Testte uc surec de "slot=2" yaziyordu - bu hatayi dogrudan
  gosteriyordu. Artik TConnectionSlot.Flags bir KIRALAMA bayti olarak
  kullanilir ve InterlockedCompareExchange ile tek islemde alinir.
  Donus: baglanti ID'si (index+1). Tum slotlar doluysa hata verir. }
var
  i: Integer;
  s: PConnectionSlot;
begin
  Result := -1;
  for i := 0 to FSlotsCount - 1 do
  begin
    s := SlotRec(i);
    { KIRALAMA: 0 -> 1. Basarili olan ve SADECE o surec devam eder. }
    if InterlockedCompareExchange(s.Flags, 1, 0) <> 0 then
      Continue;   // baska surec kiralamis (veya kirali kalmis)
    s.ConnectionID := i + 1;
    s.ProcessID := CurrentProcessID;
    s.ThreadID := CurrentThreadID;
    s.LastAccessTime := VdbTickMs;
    s.Active := True;
    Result := i + 1;
    Exit;
  end;
  raise EPrimsOrphan.CreateFmt('TSharedMemory: bos slot yok (boyut=%d)',
    [FSlotsCount]);
end;

procedure TSharedMemory.ReleaseSlot(ID: Integer);
{ ID = index + 1 -> index = ID - 1.
  NOT: kiralama bayti (Flags) DA sifirlanir. Sadece Active=False
  yapmak, bayt kirali kalmasina ve slotunun kisa surede yeniden
  kiralanamamasina yol acar. }
var
  i: Integer;
  s: PConnectionSlot;
begin
  i := ID - 1;
  if (i < 0) or (i >= FSlotsCount) then Exit;
  s := SlotRec(i);
  s.Active := False;
  s.ConnectionID := 0;
  s.ProcessID := 0;
  s.ThreadID := 0;
  InterlockedExchange(s.Flags, 0);
end;

function TSharedMemory.TryAllocateSlot: Integer;
{ Kiralamayi DENE; basarili olmazsa -1 doner (hata vermez).
  Havuzun zaman asimi dolana kadar yeniden denemesi icin. }
var
  i: Integer;
  s: PConnectionSlot;
begin
  Result := -1;
  if FSlotsCount <= 0 then Exit;
  for i := 0 to FSlotsCount - 1 do
  begin
    s := SlotRec(i);
    if InterlockedCompareExchange(s.Flags, 1, 0) <> 0 then Continue;
    s.ConnectionID := i + 1;
    s.ProcessID := CurrentProcessID;
    s.ThreadID := CurrentThreadID;
    s.LastAccessTime := VdbTickMs;
    s.Active := True;
    Result := i + 1;
    Exit;
  end;
end;

function TSharedMemory.ClaimedSlots: string;
{ Kirali slot'lar "id:sahipPID" listesi. }
var
  i, n: Integer;
  s: PConnectionSlot;
begin
  Result := '';
  n := 0;
  for i := 0 to FSlotsCount - 1 do
  begin
    s := SlotRec(i);
    if s.Flags <> 0 then
    begin
      if n > 0 then Result := Result + ',';
      Result := Result + IntToStr(i + 1) + ':' + IntToStr(s.ProcessID);
      Inc(n);
    end;
  end;
end;

procedure TSharedMemory.Heartbeat;
begin
  FHeader.LastHeartbeat := VdbTickMs;
end;

procedure TSharedMemory.TouchSlot(ID: Integer);
var
  i: Integer;
  s: PConnectionSlot;
begin
  i := ID - 1;
  if (i < 0) or (i >= FSlotsCount) then Exit;
  s := SlotRec(i);
  s.LastAccessTime := VdbTickMs;
end;

procedure TSharedMemory.CleanOrphans(ATimeoutSec: Integer);
// Orphan: Active ama LastAccessTime 'TimeoutSec' saniyeden eski olan.
// NOT: geri alinan slotun KIRALAMA BAYTI (Flags) DA sifirlanir;
// aksi halde slot bayt kirali kaldigi icin bir daha kiralanamaz ve
// kapasite kalici olarak daralir.
var
  i: Integer;
  Now, Last: Int64;
  Sec: Integer;
  s: PConnectionSlot;
begin
  Now := VdbTickMs;
  Sec := ATimeoutSec * 1000;
  for i := 0 to FSlotsCount - 1 do
  begin
    s := SlotRec(i);
    if not s.Active then Continue;
    Last := s.LastAccessTime;
    if (Now - Last) > Sec then
    begin
      // islem cokin; slotu birakilan say.
      s.Active := False;
      s.ProcessID := 0;
      s.ThreadID := 0;
      s.ConnectionID := 0;
      InterlockedExchange(s.Flags, 0);
    end;
  end;
end;

procedure TSharedMemory.SetPoolSize(ACount: Integer);
begin
  if ACount < 0 then ACount := 0;
  FSlotsCount := ACount;
  FHeader.ConnectionCount := ACount;
end;

procedure TSharedMemory.Unlink;
begin
  // Owner tarafindan, tum baglantilar disaridaken cagirilir:
  // SHM ismini isletim sistemi seviyesinde siler.
  if FHandle <> 0 then
  begin
    UnmapMemory;
    {$IFDEF WINDOWS}
    CloseHandle(FHandle);
    // Windows SHM ismi 'VDBSHM_' oneli ile silinir; dosya sistemi
    // mapping'i isletim seviyesindedir, Unlink islemi burada
    // bitirilmelidir (isletim sistemi handle sayisina gore).
    {$ELSE}
    {$IFDEF UNIX}
    if FHandle >= 0 then
    begin
      Close(FHandle);
      shm_unlink('vdbshm_' + FName);
    end;
    {$ENDIF}
    {$ENDIF}
    FHandle := 0;
  end;
  FMemory := nil;
end;

// ------------------------------------------------------------------
// Yardimci fonksiyonlar
// ------------------------------------------------------------------

function TSharedMemory.ThreadToID: Int64;
begin
  // TThreadID (Integer) -> Int64 session ID.
  Result := TThreadID(CurrentThreadID);
end;

class function TSharedMemory.CurrentProcessID: Cardinal;
begin
  {$IFDEF WINDOWS}
  Result := GetCurrentProcessId;
  {$ELSE}
  {$IFDEF UNIX}
  Result := Cardinal(getpid);
  {$ENDIF}
  {$ENDIF}
end;

class function TSharedMemory.CurrentThreadID: TThreadID;
begin
  {$IFDEF WINDOWS}
  Result := GetCurrentThreadId;
  {$ELSE}
  {$IFDEF UNIX}
  Result := pthread_self;
  {$ENDIF}
  {$ENDIF}
end;

function TSharedMemory.ActiveCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FSlotsCount - 1 do
    if SlotRec(i).Active then Inc(Result);
end;

function TSharedMemory.LastActivity: Int64;
var
  i: Integer;
  L: Int64;
begin
  Result := 0;
  for i := 0 to FSlotsCount - 1 do
  begin
    L := SlotRec(i).LastAccessTime;
    if L > Result then Result := L;
  end;
end;

function SHMHash(const S: string): string;
var
  H: UInt64;
  i: Integer;
begin
  H := 14695981039346656037;
  for i := 1 to Length(S) do
    H := H xor Byte(S[i]);
  Result := IntToHex(H, 8);
end;

end.
