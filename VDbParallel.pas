unit VDbParallel;

{ R-14 Full (2026-10-13) PARALLEL QUERY — gercek isci havuzu (thread pool).

  Eskiden stub idi: FPC 3.2.4'te TConditionVariable ve `reference to
  procedure` (kapanis) yok diye ertelenmisti. Cozum:

    * Wuyandirma sinyali  -> System biriminin RTLEvent*'i
      (RTLEventCreate/SetEvent/ResetEvent/WaitFor; tum platformlarda var,
      TConditionVariable GEREKMEZ).
    * Gorev tanimi        -> duz prosedur isaretcisi + cagirani baglam
      kaydi (`TVdbRangeFn`). Kapanis (closure) gerekmez.
    * Kuyruk kilidi       -> syncobjs.TCriticalSection.

  KULLANIM MODELİ (onemli kisitlar):
    1) VdbParallelFor / VdbParallelForChunked yalnizca havuzu ACAN
       (ana) is parcacigindan cagrilir. Isçi icinden yapilan ic ice
       cagrilar otomatik olarak SERI yurutulur (GBusy kilidi sayesinde
       kilitlenme olmaz).
    2) Gorev fonksiyonu paylasilan veri uzerinde YALNIZCA OKUMA yapmali
       ya da kendisine ayrilmis araliklara yazmali. Motor tarafinda
       tek entegrasyon noktasi ORDER BY siralamasidir (VDbExecutor.DoSort):
       satir deposu salt-okunur, indeks dizisi parcali yazilir.
    3) Havuz, ilk buyuk siralamada kendiliginden acilir (lazy init);
       ShutdownThreadPool ile ya da finalization'da kapatilir.

  Thread-guvenligi notlari:
    * FPCRTL, IsMultiThread=True iken ansistring referans sayacini atomik
      artirir/azaltir (TThread.Create bunu otomatik yapar).
    * Sayaclarda ve bayraklarda kilitsiz okuma yalnizca ana is
      parcacigi icin gecerlidir; GBusy kilidin ALTINDA okunur (zayif
      hafiza duzendeki makinelerde isçi tarafindan bayat okuma +
      kuyruga girip kendi kendine beklemek = kilitlenme riski). }

{ R-23: Diger motor birimleri gibi delphi modu (varsayilan parametre
  degerleri, out parametreleri vs. icin). Bu satir olmadan `fpc` vakfa
  modda InitThreadPool(MaxThreads: Integer = 0) derlenmiyor. }
{$mode delphi}{$H+}

interface

uses SysUtils, Classes;

const
  { Isci sayisi ust siniri. 8 uzeri isci, siralamanin bellek ayak izisini
    buyutup getirisini dusurur (GIL olmayan dilde bile cache bant genisligi
    sinirlidir). }
  VDB_PAR_MAX_WORKERS = 8;

  { Bu satir sayisinin ALTINDAKI kumeler hic paralelleştirilmez; seri
    quicksort daha hizli ve daha az yuk getiri. Eşik, EXPLAIN anotasyonu
    ile AYNI sabittir (plan ile yurutme ayni karari verir). }
  VDB_PAR_SORT_MIN_ROWS = 2048;

  { Isçi uykusunda en fazla bu kadar ms bekle; Shutdown buraya kadar
    gecikebilir (uyandirma sinyali normalde anliktir). }
  VDB_PAR_POLL_MS = 100;

type
  { Gorev fonksiyonu: ACtx = cagiranin baglami, AChunkIx = gorev sirasi
    (cagri icinde benzersiz), [ALo..AHi] = islenecek aralik (dahil). }
  TVdbRangeFn = procedure(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);

  TVdbParallelStats = record
    Workers: Integer;        // acik isci sayisi (0 = havuz kapali)
    ActiveWorkers: Integer;  // su an gorev yuruten isci
    TasksSubmitted: Int64;   // kuyruga verilen toplam gorev
    TasksExecuted: Int64;    // hatasiz biten toplam gorev
  end;

{ Otomatik acilista kullanilacak isci sayisi: Windows'ta islemci sayisi,
  diger platformlarda 4; [1..VDB_PAR_MAX_WORKERS] araligina kirpilir.
  Is parcacigi YARATMAZ. }
function DefaultParallelWorkers: Integer;

{ Havuzu acar. MaxThreads <= 0 ise DefaultParallelWorkers. Zaten aciksa
  dokunmadan True doner (idempotent). }
function InitThreadPool(MaxThreads: Integer = 0): Boolean;

{ Havuzu kapatir: isçilere cikis sinyali verir, hepsinin bitmesini
  bekler, kaynaklari bosaltir. Kapali havuzda cagrilmasi hatasizdir. }
procedure ShutdownThreadPool;

function ThreadPoolReady: Boolean;
function ParallelWorkerCount: Integer;

{ [ABeg..AEnd] araligini iscilere esit parcalarla dagitir ve hepsi
  bitene kadar bekler. Gorev hata firlatirsa ilk hata, cagirana
  'VDB paralel gorev hatasi: ...' olarak yukseltilir. Havuz kapali /
  tek isçi / isçi icinden cagrilmissa aralik TEK PARCA seri yurutulur. }
procedure VdbParallelFor(ABeg, AEnd: Integer; const AFn: TVdbRangeFn;
  ACtx: Pointer);

{ VdbParallelFor'un parca sayisini acik belirten hali. AChunkCount < 1
  olursa 1 kabul edilir; araliktan buyukse araliga kirpilir. }
procedure VdbParallelForChunked(ABeg, AEnd, AChunkCount: Integer;
  const AFn: TVdbRangeFn; ACtx: Pointer);

function VdbParallelStats: TVdbParallelStats;

{ R-14 EXPLAIN anotasyonu: plan satirini, sorgu gercekten isci
  kullanacaksa 'Parallel ... (workers=N)' bicimine cevirir.
  AEstRows = dugumden beklenen satir sayisi; esik altinda ya da isçi
  yoksa metin degismez. Havuz kapaliysa otomatik acilistaki isci
  sayisi esas alinir (is parcacigi yaratilmaz). }
function GetParallelPlanText(const BasePlan: string; AEstRows: Int64): string;

implementation

uses
  {$IFDEF MSWINDOWS}
  { ONCE Windows: bu birim TCRITICALSECTION = TRTLCriticalSection (kayit
    tipi) bildirir ve Pascal buyuk/kucuk harf duyarsiz oldugundan
    syncobjs'in ayni adli SINIFINI golgeler. Siralama bunu onler; tip
    asagida yine birim-nitelikli yazildi (cift guvenlik). }
  Windows,
  {$ENDIF}
  syncobjs;

type
  TVdbWorkItem = record
    Fn: TVdbRangeFn;
    Ctx: Pointer;
    ChunkIx: Integer;
    Lo, Hi: Integer;
  end;

  TVdbWorkerThread = class(TThread)
  protected
    procedure RunItem(const item: TVdbWorkItem);
    procedure Execute; override;
  end;

var
  // Not: sinif/isaretçi tipleri Pascal'da zaten varsayilan olarak nil'dir;
  // FPC'de sinif tipi icin `= nil` baslatci SYNTAX hatasidir.
  GLock: syncobjs.TCriticalSection;  // kuyruk + sayaclari korur
  GQueue: array of TVdbWorkItem;   // halka tampon (ring buffer)
  GQHead: Integer = 0;             // bir sonraki cekilecek yuva
  GQCount: Integer = 0;            // kuyruktaki gorev sayisi
  GWake: PRTLEvent;                // isçileri uyandiran sinyal
  GIdle: PRTLEvent;                // 'kuyruk bos + aktif isçi yok' sinyali
  {$IFDEF MSWINDOWS}
  GWorkSem: THandle = 0;           // H6: is dagitimi icin sayma semaforu
  {$ENDIF}
  GThreads: array of TVdbWorkerThread;
  GWorkerCount: Integer = 0;
  GQuit: Boolean = False;          // isçilere cikis emri
  GActive: Integer = 0;            // su an gorev yuruten isci sayisi
  GBusy: Boolean = False;          // bir VdbParallelFor su an suruyor
  GSubmitted: Int64 = 0;
  GExecuted: Int64 = 0;
  GFailed: Boolean = False;        // son cagrıda gorev hatasi oldu mu
  GErrMsg: string = '';

{ ------------------------------------------------------------ isçi }

procedure TVdbWorkerThread.RunItem(const item: TVdbWorkItem);
begin
  try
    item.Fn(item.Ctx, item.ChunkIx, item.Lo, item.Hi);
    GLock.Enter;
    try
      Inc(GExecuted);
      Dec(GActive);
      if (GQCount = 0) and (GActive = 0) then
        RTLEventSetEvent(GIdle);
    finally
      GLock.Leave;
    end;
  except
    // Istisna isçi parcacigindan disari sizmaz: ilk hata kaydedilir,
    // kalan gorevler yine de bitirilir, sonunda cagirana yukseltilir.
    on E: Exception do
    begin
      GLock.Enter;
      try
        if not GFailed then
        begin
          GFailed := True;
          GErrMsg := E.ClassName + ': ' + E.Message;
        end;
        Dec(GActive);
        if (GQCount = 0) and (GActive = 0) then
          RTLEventSetEvent(GIdle);
      finally
        GLock.Leave;
      end;
    end;
  end;
end;

procedure TVdbWorkerThread.Execute;
var
  item: TVdbWorkItem;
  has: Boolean;
begin
  while True do
  begin
    {$IFDEF MSWINDOWS}
    // H6 (2026-10-18): FPC'nin Windows RTLEvent'i AUTO-RESET'tir; tek
    // SetEvent yalnizca BIR isçiyi uyandirir. Bu yuzden is dagitimi
    // sayma semaforu ile yapilir: her gorev icin bir token. (Onceden tum
    // "paralel" isler fiilen TEK isçide kosuyordu; olcum: 8 isçi ≈ 1 isçi.)
    if GWorkSem = 0 then Sleep(VDB_PAR_POLL_MS)
    else WaitForSingleObject(GWorkSem, VDB_PAR_POLL_MS);
    if GQuit then Break;
    has := False;
    GLock.Enter;
    try
      if GQCount > 0 then
      begin
        item := GQueue[GQHead];
        GQHead := (GQHead + 1) mod Length(GQueue);
        Dec(GQCount);
        Inc(GActive);
        has := True;
      end;
    finally
      GLock.Leave;
    end;
    if not has then Continue;   // fazla token (onceki parti)
    RunItem(item);
    {$ELSE}
    RTLEventWaitFor(GWake, VDB_PAR_POLL_MS);
    RTLEventResetEvent(GWake);
    if GQuit then Break;

    // Kuyrugu kendi kendine tuket (POSIX RTLEvent davranisina birakilir).
    while True do
    begin
      has := False;
      GLock.Enter;
      try
        if GQCount > 0 then
        begin
          item := GQueue[GQHead];
          GQHead := (GQHead + 1) mod Length(GQueue);
          Dec(GQCount);
          Inc(GActive);
          has := True;
        end
        else if GActive = 0 then
          RTLEventSetEvent(GIdle);
      finally
        GLock.Leave;
      end;
      if not has then Break;
      RunItem(item);
    end;
    {$ENDIF}
  end;
end;

{ ------------------------------------------------------------ yardimcilar }

function DefaultParallelWorkers: Integer;
var
  {$IFDEF MSWINDOWS}
  si: TSystemInfo;
  {$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  FillChar(si, SizeOf(si), 0);
  GetSystemInfo(si);
  Result := si.dwNumberOfProcessors;
  {$ELSE}
  // Unix'te islemci sayisini okumak icin ek bagimlilik istemiyoruz;
  // 4 makul bir varsayilan (ust sinir 8).
  Result := 4;
  {$ENDIF}
  if Result < 1 then Result := 1;
  if Result > VDB_PAR_MAX_WORKERS then Result := VDB_PAR_MAX_WORKERS;
end;

{ GLock TUTULUYORKEN cagirilmalidir: kuyrugu gerekiyorsa buyutur ve
  ogeyi sona ekler. }
procedure EnqueueLocked(const AItem: TVdbWorkItem);
var
  cap, i: Integer;
  packed_: array of TVdbWorkItem;
begin
  if Length(GQueue) = 0 then
  begin
    SetLength(GQueue, 64);
    GQHead := 0;
    GQCount := 0;
  end;
  if GQCount = Length(GQueue) then
  begin
    // Halka tampon doldu: bastan sikistirip iki katina cikar.
    cap := Length(GQueue) * 2;
    SetLength(packed_, cap);
    for i := 0 to GQCount - 1 do
      packed_[i] := GQueue[(GQHead + i) mod Length(GQueue)];
    GQueue := packed_;
    GQHead := 0;
  end;
  GQueue[(GQHead + GQCount) mod Length(GQueue)] := AItem;
  Inc(GQCount);
  Inc(GSubmitted);
end;

function ThreadPoolReady: Boolean;
begin
  Result := GWorkerCount > 0;
end;

function ParallelWorkerCount: Integer;
begin
  Result := GWorkerCount;
end;

{ ------------------------------------------------------------ yasam dongusu }

function InitThreadPool(MaxThreads: Integer = 0): Boolean;
var
  n, i: Integer;
begin
  Result := False;
  if GLock = nil then
    GLock := TCriticalSection.Create;
  GLock.Enter;
  try
    if GWorkerCount > 0 then Exit(True);   // zaten acik: dokunma
    if MaxThreads <= 0 then n := DefaultParallelWorkers
    else n := MaxThreads;
    if n < 1 then n := 1;
    if n > VDB_PAR_MAX_WORKERS then n := VDB_PAR_MAX_WORKERS;

    GQuit := False;
    GFailed := False;
    GErrMsg := '';
    GActive := 0;
    GBusy := False;
    GSubmitted := 0;
    GExecuted := 0;
    GQHead := 0;
    GQCount := 0;
    SetLength(GQueue, 64);
    GWake := RTLEventCreate;
    GIdle := RTLEventCreate;
    RTLEventSetEvent(GIdle);   // baslangicta havuz bosta
    {$IFDEF MSWINDOWS}
    GWorkSem := CreateSemaphore(nil, 0, $7FFFFFFF, nil);
    {$ENDIF}

    // Isçiler hemen kosmaya baslar; ilk GLock.Enter'lari init bitene
    // kadar kilit disinda bekler (deadlock yok).
    SetLength(GThreads, n);
    for i := 0 to n - 1 do
    begin
      GThreads[i] := TVdbWorkerThread.Create(False);
      GThreads[i].FreeOnTerminate := False;
    end;
    GWorkerCount := n;
    Result := True;
  finally
    GLock.Leave;
  end;
end;

procedure ShutdownThreadPool;
var
  i: Integer;
begin
  if GLock = nil then Exit;
  GLock.Enter;
  try
    if GWorkerCount = 0 then Exit;
    GQuit := True;
  finally
    GLock.Leave;
  end;
  {$IFDEF MSWINDOWS}
  if GWorkSem <> 0 then
    ReleaseSemaphore(GWorkSem, GWorkerCount, nil);
  {$ELSE}
  if GWake <> nil then RTLEventSetEvent(GWake);
  {$ENDIF}
  // Isçiler elindeki gorevi bitirir, kuyruga döner, GQuit'i gorur ve
  // cikar. WaitFor kapanisin tamamlanmasini garanti eder.
  for i := 0 to High(GThreads) do
  begin
    GThreads[i].WaitFor;
    GThreads[i].Free;
  end;
  SetLength(GThreads, 0);
  {$IFDEF MSWINDOWS}
  if GWorkSem <> 0 then
  begin
    CloseHandle(GWorkSem);
    GWorkSem := 0;
  end;
  {$ENDIF}
  if GWake <> nil then RTLEventDestroy(GWake);
  if GIdle <> nil then RTLEventDestroy(GIdle);
  GWake := nil;
  GIdle := nil;
  GWorkerCount := 0;
  GActive := 0;
  GQCount := 0;
  GQHead := 0;
  SetLength(GQueue, 0);
  GBusy := False;
end;

{ ------------------------------------------------------------ paralel for }

procedure VdbParallelForChunked(ABeg, AEnd, AChunkCount: Integer;
  const AFn: TVdbRangeFn; ACtx: Pointer);
var
  n, chunks, sz, extra, c, lo, hi, i: Integer;
  item: TVdbWorkItem;
  done, failed, serial: Boolean;
  msg: string;
begin
  if not Assigned(AFn) then
    raise Exception.Create('VDB paralel gorev fonksiyonu nil');
  n := AEnd - ABeg + 1;
  if n <= 0 then Exit;

  chunks := AChunkCount;
  if chunks < 1 then chunks := 1;

  // Seri durum: havuz yok / tek isçi / isçi icinden cagrildi (GBusy).
  // GBusy KILIT ALTINDA okunur: is parcacigi icinden bayat deger okuyup
  // kuyruga girerse kendi tamamlanmasini bekler -> kilitlenme.
  GLock.Enter;
  try
    serial := (GWorkerCount < 2) or GBusy;
  finally
    GLock.Leave;
  end;
  if serial then
  begin
    AFn(ACtx, 0, ABeg, AEnd);
    Exit;
  end;

  if chunks > n then chunks := n;

  GLock.Enter;
  try
    GBusy := True;
    GFailed := False;
    GErrMsg := '';
    RTLEventResetEvent(GIdle);
    RTLEventResetEvent(GWake);   // yeni parti: sinyali temiz baslat

    sz := n div chunks;
    extra := n mod chunks;
    lo := ABeg;
    for i := 0 to chunks - 1 do
    begin
      c := sz + Ord(i < extra);      // ilk 'extra' parca 1 fazla alir
      hi := lo + c - 1;
      item.Fn := AFn;
      item.Ctx := ACtx;
      item.ChunkIx := i;
      item.Lo := lo;
      item.Hi := hi;
      EnqueueLocked(item);
      lo := hi + 1;
    end;
  finally
    GLock.Leave;
  end;
  {$IFDEF MSWINDOWS}
  // Her gorev icin BIR token: auto-reset RTLEvent'in aksine adil dagitim.
  if GWorkSem <> 0 then ReleaseSemaphore(GWorkSem, chunks, nil);
  {$ELSE}
  RTLEventSetEvent(GWake);
  {$ENDIF}

  // Tum gorevler bitene kadar bekle. Her turda kilitle kontrol; kayip
  // sinyale karsi 10 ms'lik yoklama gecisi de var.
  try
    while True do
    begin
      GLock.Enter;
      try
        done := (GQCount = 0) and (GActive = 0);
        // H6: partinin bittigini gorunce uyandirma sinyalini TEMIZLE.
        // Boylece sonraki parti SetEvent'i kaybolmaz (isçiler resetlemez;
        // yoksa ilk uyanan digerlerinin sinyalini yutar).
        if done then RTLEventResetEvent(GWake);
      finally
        GLock.Leave;
      end;
      if done then Break;
      RTLEventWaitFor(GIdle, 10);
      RTLEventResetEvent(GIdle);
    end;
  finally
    GLock.Enter;
    try
      GBusy := False;
    finally
      GLock.Leave;
    end;
  end;

  GLock.Enter;
  try
    failed := GFailed;
    msg := GErrMsg;
  finally
    GLock.Leave;
  end;
  if failed then
    raise Exception.Create('VDB paralel gorev hatasi: ' + msg);
end;

procedure VdbParallelFor(ABeg, AEnd: Integer; const AFn: TVdbRangeFn;
  ACtx: Pointer);
begin
  VdbParallelForChunked(ABeg, AEnd, ParallelWorkerCount * 2, AFn, ACtx);
end;

function VdbParallelStats: TVdbParallelStats;
begin
  Result.Workers := 0;
  Result.ActiveWorkers := 0;
  Result.TasksSubmitted := 0;
  Result.TasksExecuted := 0;
  if GLock = nil then Exit;
  GLock.Enter;
  try
    Result.Workers := GWorkerCount;
    Result.ActiveWorkers := GActive;
    Result.TasksSubmitted := GSubmitted;
    Result.TasksExecuted := GExecuted;
  finally
    GLock.Leave;
  end;
end;

{ ------------------------------------------------------------ EXPLAIN }

function GetParallelPlanText(const BasePlan: string; AEstRows: Int64): string;
var
  w: Integer;
begin
  Result := BasePlan;
  if AEstRows < VDB_PAR_SORT_MIN_ROWS then Exit;
  if ThreadPoolReady then w := ParallelWorkerCount
  else w := DefaultParallelWorkers;
  if w < 2 then Exit;
  Result := 'Parallel ' + BasePlan + '  (workers=' + IntToStr(w) + ')';
end;

initialization

finalization
  { DLL bosaltilirken / program kapanirken isçiler temizce durdurulur.
    (C ABI kullanicilari VdbParallelShutdown ile daha once de
    kapatabilir; burasi guvenlik agidir.) }
  ShutdownThreadPool;

end.
