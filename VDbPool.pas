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
    { R2-B-5: Acquire'in urettigi orneklerin sahibi thread. Yanlis
      sahiplikte Release, motoru/mutex'i baska thread'in altindan
      cekmeden once acik hata verir. }
    FOwners: TDictionary<Pointer, THandle>;
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
// Interlocked islemleri SYSTEM biriminin intrinsic surumlerinden gelir;
// kernel32 x86_64'te bu adlar artik disa aktarilmiyor (0xC0000139).
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
  FOut := 0;
  FClosed := False;
  // R-12: varsayilan TEK surec modu. CreateXProc ile cok surece
  // gecirilir.
  FShm := nil;
  FMySlot := -1;
  FSlotBusy := False;
  FMutex := nil;
  FOwnedKv := nil;
  FOwnedTb := nil;
  FXProcDir := '';
  // R2-A-6: kurulum yarida kalirsa destructor cagrilir; alanlar bu
  // yuzden nil baslatilir ve asagidaki her adim nil denetimine dayanir.
  FLock := nil;
  FAvail := nil;
  FIdle := nil;
  FAll := nil;
  FOwners := nil;
  FLock := TCriticalSection.Create;
  // Manuel-reset degil: tek bekleyeni uyandirir (otomatik sifirlanir).
  FAvail := TEvent.Create(nil, False, False, '');
  FIdle := TList<TVSql>.Create;
  FAll := TList<TVSql>.Create;
  FOwners := TDictionary<Pointer, THandle>.Create;
  for i := 1 to FSize do
  begin
    FIdle.Add(TVSql.Create(FTb));
    FAll.Add(FIdle[FIdle.Count - 1]);
  end;
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
{ Motoru kapatir. Cagiran, FMutex hala tutuyorken cagirir.
  R2-B-6: yalniz cok surec modunda havuzun actigi motor vardir. Tek
  surec modunda FTb cagirandan gelir ve burada ASLA nil yapilmaz /
  serbest birakilmaz. }
begin
  if FShm = nil then Exit;
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
      { R2-A-5: sayac kiralama ile BIRLIKTE artirilir. Boylece
        OpenEngine (veya mutex Enter) hata verse bile ReleaseSlot'un
        decrement'i hep eslesir; releaseler arasinda kayma olmaz. }
      InterlockedIncrement(PPoolHeader(FShm.Header)^.ActiveConnections);
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
    { R2-A-5: bu decrement yalnizca AcquireSlot'un artirdigi sayaci
      geri alir (artirma kiralama ile atomik eslesir). }
    InterlockedDecrement(PPoolHeader(FShm.Header)^.ActiveConnections);
    FShm.ReleaseSlot(FMySlot);
    FMySlot := -1;
  end;
end;

constructor TVDbPool.CreateXProc(const AXName, ADataDir: string; ASize: Integer;
  ATimeoutMs: Integer);
begin
  { R2-A-6: TObject kurulumu ATLANMAMALI. Constructor sonradan hata
    verse FPC destructor'i cagirir; nil alanlarla guvenli calisir. }
  inherited Create;
  if ASize < 1 then ASize := 1;
  FSize := ASize;
  FTimeoutMs := ATimeoutMs;
  FOut := 0;
  FClosed := False;
  FMySlot := -1;
  FSlotBusy := False;
  FXProcDir := ADataDir;
  FTb := nil;
  FShm := nil;
  FMutex := nil;
  FOwnedKv := nil;
  FOwnedTb := nil;
  FLock := nil;
  FAvail := nil;
  FIdle := nil;
  FAll := nil;
  FOwners := nil;
  FLock := TCriticalSection.Create;
  FAvail := TEvent.Create(nil, False, False, '');
  FIdle := TList<TVSql>.Create;
  FAll := TList<TVSql>.Create;
  FOwners := TDictionary<Pointer, THandle>.Create;
  { NOT: Motor BURADA ACILMAZ. .odb dosyasi ozel kilitlidir; iki
    surec ayni anda motoru acamaz. Motor Acquire'da isimli mutex
    alindiktan SONRA acilir, Release'de kapatilir. }
  InitXProc(AXName);
end;

destructor TVDbPool.Destroy;
var
  i: Integer;
begin
  { R2-A-6: yarim kurulumda FLock/FIdle/FAll nil olabilir. }
  if FLock <> nil then
  begin
    FLock.Enter;
    try
      FClosed := True;
      if FIdle <> nil then
        for i := 0 to FIdle.Count - 1 do
          FIdle[i].Free;
      // Disaridaki ornekler uygulamaya aittir (dokumante); burada
      // serbest birakilmaz (cift-free riski).
    finally
      FLock.Leave;
    end;
  end
  else if FIdle <> nil then
    for i := 0 to FIdle.Count - 1 do
      FIdle[i].Free;
  FreeAndNil(FIdle);
  FreeAndNil(FAll);
  FreeAndNil(FOwners);
  FreeAndNil(FAvail);
  FreeAndNil(FLock);
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
  Locked: Boolean;
  Deadline: Int64;
  WaitMs: Integer;
begin
  { R-12: 1) isimli mutex al -> motor dosyasi ozel kilitli, sirali
                erisim sart.
             2) paylasilan SHM'den slot kirala -> surec kapasitesi sinirli.
    R2-B-5: slot, mutex'ten SONRA kiralanir. FMySlot havuz (surec) bazli
    TEK alandir; mutex'i bekleyen ikinci thread onu ezerse sahip
    thread'in Release'inde yanlis slot birakilir, isimli mutex ve motor
    tutulu kalirdi. Mutex once alininca ayni anda tek thread kiralama
    yapar; FMySlot'un sahibi ile mutex'in sahibi ayni thread olur. }
  Locked := False;
  try
    { R2-A-5: mutex Enter da hata yoluna dahil. Kilit alinamazsa
      asagidaki except'ta temizlik yapilir. }
    if FMutex <> nil then
    begin
      FMutex.Enter;
      Locked := True;
    end;
    if not AcquireSlot then
      raise EVDbException.CreateFmt(ecPoolTimeout,
        'TVDbPool: paylasilan slot yok (%d ms, kapasite=%d)',
        [FTimeoutMs, FSize]);
    { R2-B-6: motor yalniz cok surec modunda burada acilir. Tek surec
      modunda motor cagirandan gelir (constructor ATableDb); burada
      yeniden acmak verilen motoru terk edip cwd'de bos bir veritabani
      acmak demekti. }
    if FShm <> nil then
      OpenEngine;
  except
    { R2-B-YENI-1: temizlik zinciri. Once slot, sonra mutex birakilir
      (alma sirasinin tersi). Boylece mutex birakildiktan sonra baska
      bir thread FMySlot'u ezmeden once bu thread kendi slotunu
      birakir; FMutex.Leave hata verse bile ReleaseSlot calisir. }
    try
      ReleaseSlot;
    finally
      if Locked then FMutex.Leave;
    end;
    raise;
  end;
  try
    if FShm = nil then
    begin
      { R2-B-6: tek surec modunda FSize siniri. Onceki surum her
        Acquire'da sinirsiz TVSql uretiyordu (FIdle yalniz isim olarak
        duruyordu). Burada FOut < FSize olana kadar FAvail beklenir;
        Release FOut'u dusurup FAvail'i uyandirir. TVSql.Create ve
        sahiplik kaydi, sayac rezervasyonu ile ayni FLock blogunda
        yapilir; boylece paralel Acquire'lar FSize'i asamaz. }
      Deadline := VdbTickMs + FTimeoutMs;
      while True do
      begin
        FLock.Enter;
        try
          if FClosed then
            raise EVDbException.Create(ecPoolClosed,
              'TVDbPool: havuz kapali');
          if FOut < FSize then
          begin
            Result := TVSql.Create(FTb);
            FOwners.AddOrSetValue(Pointer(Result),
              THandle(GetCurrentThreadId));
            Inc(FOut);
            Exit;
          end;
        finally
          FLock.Leave;
        end;
        WaitMs := Deadline - VdbTickMs;
        if WaitMs <= 0 then
          raise EVDbException.CreateFmt(ecPoolTimeout,
            'TVDbPool: havuz dolu (%d ms, kapasite=%d)',
            [FTimeoutMs, FSize]);
        { Otomatik-sifirlanan olayda SetEvent'ler ust uste binerse
          uyandirma kaybolabilir; en fazla 10 ms bekleyip FOut'u
          yeniden denetlemek kayipsizligi garanti eder. }
        if WaitMs > 10 then WaitMs := 10;
        FAvail.WaitFor(WaitMs);
      end;
    end;
    FLock.Enter;
    try
      if FClosed then
        raise EVDbException.Create(ecPoolClosed,
          'TVDbPool: havuz kapali');
      Result := TVSql.Create(FTb);
      FOwners.AddOrSetValue(Pointer(Result), THandle(GetCurrentThreadId));
      Inc(FOut);
    finally
      FLock.Leave;
    end;
  except
    { R2-B-YENI-1: CloseEngine veya FMutex.Leave hata verse bile
      sonraki adim ve slot birakma denenir. Birakma sirasi LIFO:
      once slot, sonra mutex. }
    try
      CloseEngine;
    finally
      try
        ReleaseSlot;
      finally
        if Locked then FMutex.Leave;
      end;
    end;
    raise;
  end;
end;

procedure TVDbPool.Release(Sql: TVSql);
{ NOT: Sql = nil OLABILIR ve BU BIR HATA DEGILDIR. Cagiran bazen
  yalnizca "is parcam bitti, kilidi birak" demek ister (orn. slot
  sayimi testi). Onceki surumde `if Sql = nil then Exit` vardi ve
  bu durumda slot ASLA birakilmiyordu -> kapasite siziyordu.

  R2-B-5: havuzun uretmedigi / baska thread'den Release edilen ornek
  icin motoru ve mutex'i baska thread'in altindan cekmek yerine acik
  hata (ecInvalidArgument) verilir. Boylece use-after-free onlenir.

  R2-B-YENI-1: her erken cikis/istisna yolu tek temizlik zincirine
  baglanir. Sahiplik dogrulamasi hata verse de, Sql.Free veya
  FMutex.Leave istisna firlatsa da kiralanan slot birakilir ve motor
  kapatilir. Boylece ornek+slot+mutex 1:1 kalir. }
var
  Owner: THandle;
  Owned: Boolean;
  OutCount: Integer;
  Err: EVDbException;
  DoCleanup: Boolean;
begin
  Owned := False;
  Err := nil;
  OutCount := 0;

  if Sql <> nil then
  begin
    FLock.Enter;
    try
      if not FOwners.TryGetValue(Pointer(Sql), Owner) then
        Err := EVDbException.Create(ecInvalidArgument,
          'TVDbPool: havuzun uretmedigi ornek Release edildi')
      else if Owner <> THandle(GetCurrentThreadId) then
        Err := EVDbException.Create(ecInvalidArgument,
          'TVDbPool: ornek farkli thread''den Release ediliyor')
      else
      begin
        { R2-B-YENI-1 / TID yeniden kullanimi: anahtar ornek
          isaretcisidir, TID degil. Ayni adreste AYNI ANDA iki canli
          ornek olamaz; bir thread olup TID'si yeni bir thread'e
          verilse bile yalnizca eski, hala yasayan ve o thread'e
          birakilmis ornege erisilebilir. Acquire her yeni ornekte
          AddOrSetValue ile kaydi tazeler. Bu yuzden TID karsilastirmasi
          yeterlidir (ek nesil/sayac gerekmez). }
        FOwners.Remove(Pointer(Sql));
        Owned := True;
      end;
    finally
      FLock.Leave;
    end;
  end;

  { Tek temizlik zinciri: Sql.Free istisnasi bile asagidaki finally'ye
    girer. }
  try
    if Owned then
      // Cok surec modunda TVSql ornegi is parcasi basina olusturulur;
      // burada serbest birakilir.
      Sql.Free;
  finally
    FLock.Enter;
    try
      if Owned and (FOut > 0) then Dec(FOut);
      OutCount := FOut;
      { R2-B-6: tek surec modunda FSize bekleyicilerini uyandir. }
      if Owned then FAvail.SetEvent;
    finally
      FLock.Leave;
    end;

    { Temizlik kosulu (R2-B-5):
      - Bu cagri gercekten bu havuzun, bu thread'e ait bir ornegini
        birakmis olmali (Owned). Sahipsiz Release(nil) veya baska
        thread'in cagrisi motor/mutex'i baskasinin altindan cekmez;
        isimli mutex thread-sahipli oldugundan Release(nil) ile
        FMutex.Leave cagirmak da yasaktir.
      - Disarida canli ornek kalmamis olmali (OutCount = 0). Boylece
        baska thread'in canli TVSql'i varken FTb serbest birakilmaz
        (use-after-free onlenir).
      - Cok surec modunda ayrica bu surec bir slot tutuyor olmali.
      Tek surec modunda CloseEngine/ReleaseSlot zaten no-op'tur
      (FOwnedKv/FShm nil); kosul yine de ayni UAF korumasini verir. }
    DoCleanup := Owned and (OutCount = 0) and
      ((FShm = nil) or (FMySlot > 0));
    if DoCleanup then
    begin
      { R-12 sirasi: motoru kapat -> SHM slotunu birak -> isimli
        mutex'i birak. Slot, mutex hala tutulurken birakilir; aksi
        halde mutex'i devralan thread FMySlot'u ezip bu thread'in
        ReleaseSlot'u yanlis slotu birakirdi. Her adim, oncekiler
        hata verse bile denenir. }
      try
        CloseEngine;
      finally
        try
          ReleaseSlot;
        finally
          if FMutex <> nil then FMutex.Leave;
        end;
      end;
    end;
  end;

  { Sahiplik hatasi temizlikten SONRA bildirilir; kaynaklar sizmaz. }
  if Err <> nil then
    raise Err;
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
  Result := Default(TSqlResult);
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
  Result := Default(TSqlResult);
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
