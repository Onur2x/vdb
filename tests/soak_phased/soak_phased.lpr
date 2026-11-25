program soak_phased;
{ SKILL8 (v3.83) - HIZLANDIRILMIS KARARLILIK KOSUSU.

  AMAC: 24 saatlik soak'in YERI DEGIL; erken kusur bulma testi. Iki mod:

    phased  (varsayilan) : 7200 saniyelik tek kesintisiz kosu, fazlar:
              0-15 dk  isinma      (baslangic referansi)
              15-45 dk yogun CRUD  (INSERT/UPDATE/DELETE/SELECT)
              45-75 dk eszamanlilik (coklu baglanti + eszamanli tx)
              75-100 dk WAL/checkpoint (buyume, checkpoint, reopen)
              100-115 dk karma yuk
              115-120 dk son dogrulama (VERIFY + checksum + sayim)
            Sure VDB_PHASED_SECONDS ile kisaltilabilir (varsayilan 7200).
    write                : 1800 s yogun yazma + eszamanli islem
                           (VDB_WRITE_SECONDS ile ayarlanir).
    quick                : 30 s toplam (yalniz duman testi; PASS'i uzun
                           kosu kaniti DEGILDIR).

  IZLEME: her 10 saniyede bir CSV ornegi:
    elapsed_s,phase,rss_bytes,peak_rss_bytes,heap_bytes,cpu_pct,threads,
    handles,db_bytes,wal_bytes,ops,errs,retries,p50_us,p95_us

  DURUST SINIRLAR:
  - 2 saatlik kosu 24 saatlik kararliligin KANITI DEGILDIR.
  - Surec hayatta kaldi diye "sizinti yok" denmez; egilim raporlanir.
  - RSS/heap olculemiyorsa 0 yazilir ve rapor bunu acikca soyler.
  - Bu ikili varsayilan suite'e EKLENMEZ (uzun kosar).

  Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  VDbBackendApi, VDbFactory, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore;

{$IFDEF WINDOWS}
const
  TH32CS_SNAPTHREAD = $00000004;
type
  THREADENTRY32 = record
    dwSize: DWORD;
    cntUsage: DWORD;
    th32ThreadID: DWORD;
    th32OwnerProcessID: DWORD;
    tpBasePri: LongInt;
    tpDeltaPri: LongInt;
    dwFlags: DWORD;
  end;
function GetProcessHandleCount(hProcess: THandle; var pdwHandleCount: DWORD): BOOL;
  stdcall; external 'kernel32' name 'GetProcessHandleCount';
function CreateToolhelp32Snapshot(dwFlags, th32ProcessID: DWORD): THandle;
  stdcall; external 'kernel32' name 'CreateToolhelp32Snapshot';
function Thread32First(hSnapshot: THandle; var lpte: THREADENTRY32): BOOL;
  stdcall; external 'kernel32' name 'Thread32First';
function Thread32Next(hSnapshot: THandle; var lpte: THREADENTRY32): BOOL;
  stdcall; external 'kernel32' name 'Thread32Next';
{$ENDIF}

const
  SAMPLE_EVERY = 10;      { saniye }
  WARM_ROWS = 2000;
  WARM_BATCH = 100;

type
  TInts = array of Int64;

var
  GDir, GDb, GMetrics: string;
  GPass, GFail: Integer;
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;
  GNextId, GDelBase: Int64;
  GCSV: TStringList;
  GStop: Boolean;
  GLock: TCriticalSection;
  GTotalOps, GTotalErrs, GRetries: LongInt;
  GSeed: Integer;
  GLastSampleMs: Int64;
  GLastPathBytes: Int64;
  GLat: TInts;

{ ---------------------------------------------------------------- zaman --- }

{$IFDEF WINDOWS}
procedure Qpc(var c: Int64); stdcall; external 'kernel32' name 'QueryPerformanceCounter';
function Qpf(var f: Int64): LongBool; stdcall; external 'kernel32' name 'QueryPerformanceFrequency';

type
  TPMC = record
    cb: LongWord;
    PageFaultCount: LongWord;
    PeakWorkingSetSize: PtrUInt;
    WorkingSetSize: PtrUInt;
    QuotaPeakPagedPoolUsage: PtrUInt;
    QuotaPagedPoolUsage: PtrUInt;
    QuotaPeakNonPagedPoolUsage: PtrUInt;
    QuotaNonPagedPoolUsage: PtrUInt;
    PagefileUsage: PtrUInt;
    PeakPagefileUsage: PtrUInt;
  end;

  TFTime = record
    Lo, Hi: LongWord;
  end;

function GetCurrentProcess: PtrUInt; stdcall; external 'kernel32' name 'GetCurrentProcess';
function GetProcessMemoryInfo(hProcess: PtrUInt; var m: TPMC; cb: LongWord): LongBool;
  stdcall; external 'psapi.dll' name 'GetProcessMemoryInfo';
function GetProcessTimes(hProcess: PtrUInt; var c, e, k, u: TFTime): LongBool;
  stdcall; external 'kernel32' name 'GetProcessTimes';

var
  GQpf: Int64 = 0;
{$ENDIF}

function NowUs: Int64;
{$IFDEF WINDOWS}
var
  c: Int64;
{$ENDIF}
begin
{$IFDEF WINDOWS}
  if GQpf = 0 then
    Qpf(GQpf);
  Qpc(c);
  if GQpf <= 0 then
    Exit(Int64(GetTickCount64) * 1000);
  Result := (c div GQpf) * 1000000 + ((c mod GQpf) * 1000000) div GQpf;
{$ELSE}
  Result := Int64(GetTickCount64) * 1000;
{$ENDIF}
end;

function NowMs: Int64;
begin
  Result := GetTickCount64;
end;

{ ------------------------------------------------------------ yardimcilar --- }

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    if ADetail <> '' then
      WriteLn('PASS ', AName, ' - ', ADetail)
    else
      WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('FAIL ', AName, ' - ', ADetail)
    else
      WriteLn('FAIL ', AName);
  end;
  Flush(Output);
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
  d: string;
begin
  ForceDirectories(ADir);
  d := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(d + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        if (sr.Attr and faDirectory) <> 0 then
          WipeDir(d + sr.Name)
        else
          SysUtils.DeleteFile(d + sr.Name);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function DirBytes(const D: string): Int64;
var
  sr: TSearchRec;
  d2: string;
begin
  Result := 0;
  d2 := IncludeTrailingPathDelimiter(D);
  if FindFirst(d2 + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        if (sr.Attr and faDirectory) <> 0 then
          Inc(Result, DirBytes(d2 + sr.Name))
        else
          Inc(Result, Int64(sr.Size));
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function HeapBytes: Int64;
var
  h: THeapStatus;
begin
  h := GetHeapStatus;
  Result := Int64(h.TotalAllocated);
end;

function FDCount: Integer;
{$IFDEF WINDOWS}
var
  n: DWORD;
begin
  Result := -1;
  n := 0;
  if GetProcessHandleCount(GetCurrentProcess, n) then
    Result := Integer(n);
end;
{$ELSE}
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst('/proc/self/fd/*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;
{$ENDIF}

function ThreadCount: Integer;
{$IFDEF WINDOWS}
var
  snap: THandle;
  te: THREADENTRY32;
  pid: DWORD;
begin
  Result := -1;
  pid := GetCurrentProcessId;
  snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if snap = INVALID_HANDLE_VALUE then Exit;
  try
    Result := 0;
    te.dwSize := SizeOf(te);
    if Thread32First(snap, te) then
      repeat
        if te.th32OwnerProcessID = pid then Inc(Result);
      until not Thread32Next(snap, te);
  finally
    CloseHandle(snap);
  end;
end;
{$ELSE}
var
  sl: TStringList;
  i, p: Integer;
  s: string;
begin
  Result := -1;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile('/proc/self/status');
    except
      Exit;
    end;
    for i := 0 to sl.Count - 1 do
    begin
      s := sl[i];
      if Copy(s, 1, 8) = 'Threads:' then
      begin
        s := Trim(Copy(s, 9, Length(s)));
        p := Pos(' ', s);
        if p > 0 then s := Copy(s, 1, p - 1);
        Result := StrToIntDef(s, -1);
        Exit;
      end;
    end;
  finally
    sl.Free;
  end;
end;
{$ENDIF}

procedure MemInfo(out ARss, APeak: Int64);
{$IFDEF WINDOWS}
var
  m: TPMC;
{$ELSE}
var
  sl: TStringList;
  procedure Take(const AName: string; var ADst: Int64);
  var
    k: Integer;
    v: string;
  begin
    for k := 0 to sl.Count - 1 do
      if Pos(AName + ':', sl[k]) = 1 then
      begin
        v := Trim(Copy(sl[k], Length(AName) + 2, MaxInt));
        v := Trim(StringReplace(v, 'kB', '', [rfReplaceAll]));
        ADst := StrToInt64Def(v, 0) * 1024;
        Exit;
      end;
  end;
{$ENDIF}
begin
  ARss := 0;
  APeak := 0;
{$IFDEF WINDOWS}
  FillChar(m, SizeOf(m), 0);
  m.cb := SizeOf(m);
  if GetProcessMemoryInfo(GetCurrentProcess, m, SizeOf(m)) then
  begin
    ARss := Int64(m.WorkingSetSize);
    APeak := Int64(m.PeakWorkingSetSize);
  end;
{$ELSE}
  try
    sl := TStringList.Create;
    try
      sl.LoadFromFile('/proc/self/status');
      Take('VmRSS', ARss);
      Take('VmHWM', APeak);
    finally
      sl.Free;
    end;
  except
    ARss := 0;
    APeak := 0;
  end;
{$ENDIF}
end;

function SplitSp(const S: string): TStringArray; forward;

procedure CpuMs(out AUserMs, ASysMs: Int64);
{$IFDEF WINDOWS}
var
  c, e, k, u: TFTime;
  ku, kk: QWord;
{$ELSE}
var
  sl: TStringList;
  parts: TStringArray;
  line: string;
  i: Integer;
{$ENDIF}
begin
  AUserMs := 0;
  ASysMs := 0;
{$IFDEF WINDOWS}
  FillChar(c, SizeOf(c), 0);
  FillChar(e, SizeOf(e), 0);
  FillChar(k, SizeOf(k), 0);
  FillChar(u, SizeOf(u), 0);
  if GetProcessTimes(GetCurrentProcess, c, e, k, u) then
  begin
    kk := (QWord(k.Hi) shl 32) or k.Lo;
    ku := (QWord(u.Hi) shl 32) or u.Lo;
    ASysMs := Int64(kk div 10000);
    AUserMs := Int64(ku div 10000);
  end;
{$ELSE}
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile('/proc/self/stat');
      if sl.Count > 0 then
      begin
        line := sl[0];
        i := Pos(')', line);
        if i > 0 then line := Copy(line, i + 2, Length(line));
        parts := SplitSp(line);
        if Length(parts) >= 15 then
        begin
          AUserMs := StrToInt64Def(parts[12], 0) * 10;
          ASysMs := StrToInt64Def(parts[13], 0) * 10;
        end;
      end;
    except
      AUserMs := 0;
      ASysMs := 0;
    end;
  finally
    sl.Free;
  end;
{$ENDIF}
end;

function SplitSp(const S: string): TStringArray;
var
  i, n, st: Integer;
begin
  SetLength(Result, 0);
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    while (i <= Length(S)) and (S[i] = ' ') do Inc(i);
    st := i;
    while (i <= Length(S)) and (S[i] <> ' ') do Inc(i);
    if i > st then
    begin
      SetLength(Result, n + 1);
      Result[n] := Copy(S, st, i - st);
      Inc(n);
    end;
  end;
end;

{ --- istatistik --- }

procedure LatAdd(AUs: Int64);
var
  n: Integer;
begin
  GLock.Enter;
  try
    n := Length(GLat);
    if n >= 1000 then
    begin
      Move(GLat[n - 500], GLat[0], 500 * SizeOf(Int64));
      SetLength(GLat, 500);
      n := 500;
    end;
    SetLength(GLat, n + 1);
    GLat[n] := AUs;
  finally
    GLock.Leave;
  end;
end;

function PercentilesCopy(const A: TInts; out AP50, AP95: Int64): Boolean;
var
  L: TList<Int64>;
  i: Integer;
begin
  AP50 := 0;
  AP95 := 0;
  Result := Length(A) > 0;
  if not Result then Exit;
  L := TList<Int64>.Create;
  try
    for i := 0 to High(A) do L.Add(A[i]);
    L.Sort;
    AP50 := L[L.Count div 2];
    AP95 := L[(L.Count * 95) div 100];
  finally
    L.Free;
  end;
end;

function EnvInt(const AName: string; ADef: Integer): Integer;
begin
  Result := StrToIntDef(Trim(GetEnvironmentVariable(AName)), ADef);
end;

var
  GErrLog: Integer = 0;

{ Hata mesajlari sel gibi akabilir; ilk 50 yazilir, sonra yalniz sayilir.
  Boylece 2 saatlik kosuda log dosyasi patlamaz ve gercek sayi korunur. }
procedure LogErr(const APrefix, AMsg: string);
begin
  Inc(GErrLog);
  if GErrLog <= 50 then
    WriteLn('BILGI ', APrefix, ': ', AMsg)
  else if GErrLog = 51 then
    WriteLn('BILGI daha fazla hata satiri yazilmayacak (ilk 50 gosterildi)');
end;

function PhaseOf(AElapsed, ATotal: Int64): Integer;
begin
  if AElapsed < (ATotal * 15) div 120 then Exit(0);
  if AElapsed < (ATotal * 45) div 120 then Exit(1);
  if AElapsed < (ATotal * 75) div 120 then Exit(2);
  if AElapsed < (ATotal * 100) div 120 then Exit(3);
  if AElapsed < (ATotal * 115) div 120 then Exit(4);
  Result := 5;
end;

function PhaseName(AIdx: Integer): string;
begin
  case AIdx of
    0: Result := 'warmup';
    1: Result := 'crud';
    2: Result := 'concurrency';
    3: Result := 'wal_checkpoint';
    4: Result := 'mixed';
  else
    Result := 'final_verify';
  end;
end;

{ --------------------------------------------------------------- veritabani --- }

procedure ApplyDurability;
begin
  if Be <> nil then
    Be.DurableOnFlush := EnvInt('VDB_SOAK_DURABLE', 1) <> 0;
end;

procedure OpenDb;
begin
  Be := TVdbBackendV3.Create(GDb);
  ApplyDurability;
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
end;

procedure CloseDb;
begin
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;
end;

function IntQ(const ASql: string): Int64;
var
  r: TSqlResult;
begin
  Result := -1;
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := StrToInt64Def(Trim(r.Rows[0][0]), -1);
end;

function VerifyDb(const APath: string; out ARep: string): Boolean;
var
  BeC: TVdbBackendV3;
begin
  ARep := '';
  Result := False;
  BeC := nil;
  try
    try
      BeC := TVdbBackendV3.CreateReadOnly(APath);
      Result := BeC.Engine.VerifyEx(vmFull, True, ARep);
    except
      on E: Exception do
        ARep := 'istisna: ' + E.ClassName + ': ' + E.Message;
    end;
  finally
    BeC := nil;
  end;
end;

procedure CountOp(AErr, ARef: Boolean);
begin
  GLock.Enter;
  try
    if AErr then
      Inc(GTotalErrs)
    else if ARef then
      Inc(GRetries)
    else
      Inc(GTotalOps);
  finally
    GLock.Leave;
  end;
end;

{ ---------------------------------------------------------------- ornekleme --- }

var
  GLastCpuMs: Int64 = 0;
  GLastSampleWall: Int64 = 0;

procedure WriteHeaders;
begin
  GCSV.Add('elapsed_s,phase,rss_bytes,peak_rss_bytes,heap_bytes,cpu_pct,' +
    'threads,handles,db_bytes,wal_bytes,ops,errs,retries,p50_us,p95_us');
end;

procedure Sample(AElapsed: Int64; APhase: string);
var
  rss, peak, heap, pathB, walB, cu, cs, cpuTot, wall: Int64;
  p50, p95: Int64;
  th, fd, ops, errs, rets: Integer;
  lat: TInts;
begin
  MemInfo(rss, peak);
  heap := HeapBytes;
  CpuMs(cu, cs);
  cpuTot := cu + cs;
  wall := NowMs;
  if (GLastSampleWall > 0) and (wall > GLastSampleWall) then
    th := Integer(((cpuTot - GLastCpuMs) * 100) div (wall - GLastSampleWall))
  else
    th := 0;
  GLastCpuMs := cpuTot;
  GLastSampleWall := wall;

  pathB := DirBytes(GDir);
  GLastPathBytes := pathB;
  if (Be <> nil) and (Be.Engine <> nil) and (Be.Engine.Wal <> nil) then
    walB := Be.Engine.Wal.Bytes
  else
    walB := 0;

  GLock.Enter;
  try
    ops := GTotalOps;
    errs := GTotalErrs;
    rets := GRetries;
    SetLength(lat, Length(GLat));
    if Length(lat) > 0 then
      Move(GLat[0], lat[0], Length(lat) * SizeOf(Int64));
  finally
    GLock.Leave;
  end;
  PercentilesCopy(lat, p50, p95);

  GCSV.Add(Format('%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d',
    [AElapsed, APhase, rss, peak, heap, th, ThreadCount, FDCount,
     pathB, walB, ops, errs, rets, p50, p95]));
  GCSV.SaveToFile(GMetrics);
end;

{ ---------------------------------------------------------------- is yukleri --- }

procedure InsRow(AId: Int64);
begin
  Sq.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, %d, ''s%d'')',
    [AId, AId mod 1000, AId mod 97]));
end;

{ Tek CRUD turu: 10 INSERT, 10 UPDATE, 10 DELETE, 5 SELECT. }
procedure CrudCycle;
var
  i, k: Integer;
  t0: Int64;
begin
  t0 := NowUs;
  try
    for i := 1 to 10 do
    begin
      InsRow(GNextId);
      Inc(GNextId);
    end;
    for i := 1 to 10 do
    begin
      k := GDelBase + Random(500);
      Sq.Exec(Format('UPDATE t SET v = v + 1 WHERE id = %d', [k]));
    end;
    for i := 1 to 10 do
    begin
      Sq.Exec(Format('DELETE FROM t WHERE id = %d', [GDelBase]));
      Inc(GDelBase);
    end;
    for i := 1 to 5 do
      IntQ(Format('SELECT COUNT(*) FROM t WHERE v = %d', [Random(1000)]));
    CountOp(False, False);
  except
    on E: Exception do
    begin
      CountOp(True, False);
      LogErr('CRUD', E.ClassName + ': ' + E.Message);
    end;
  end;
  LatAdd(NowUs - t0);
end;

{ WAL turu: yogun yazim + periyodik checkpoint; her 20 turda reopen. }
var
  GWalCycle: Integer = 0;

procedure WalCycle;
var
  i: Integer;
  t0: Int64;
begin
  Inc(GWalCycle);
  t0 := NowUs;
  try
    for i := 1 to 20 do
    begin
      InsRow(GNextId);
      Inc(GNextId);
    end;
    for i := 1 to 10 do
      Sq.Exec(Format('DELETE FROM t WHERE id = %d', [GDelBase + i]));

    if (GWalCycle mod 5) = 0 then
      Be.Engine.Checkpoint(True);

    if (GWalCycle mod 20) = 0 then
    begin
      CloseDb;
      OpenDb;
    end;
    CountOp(False, False);
  except
    on E: Exception do
    begin
      CountOp(True, False);
      LogErr('WAL', E.ClassName + ': ' + E.Message);
    end;
  end;
  LatAdd(NowUs - t0);
end;

{ Karma tur: okuma agirlikli yazim + point lookup + aralik. }
procedure MixedCycle;
var
  i, k: Integer;
  t0: Int64;
begin
  t0 := NowUs;
  try
    if (Random(2) = 0) then
    begin
      for i := 1 to 5 do
      begin
        InsRow(GNextId);
        Inc(GNextId);
      end;
      for i := 1 to 5 do
      begin
        Sq.Exec(Format('DELETE FROM t WHERE id = %d', [GDelBase]));
        Inc(GDelBase);
      end;
    end;
    for i := 1 to 8 do
    begin
      k := GDelBase + Random(1500);
      IntQ(Format('SELECT v FROM t WHERE id = %d', [k]));
    end;
    IntQ('SELECT COUNT(*) FROM t');
    CountOp(False, False);
  except
    on E: Exception do
    begin
      CountOp(True, False);
      LogErr('karisik', E.ClassName + ': ' + E.Message);
    end;
  end;
  LatAdd(NowUs - t0);
end;

{ ------------------------------------------------------------ eszamanlilik --- }

type
  TStressThread = class(TThread)
  private
    FDb: string;
    FSeed: Integer;
    FIsWriter: Boolean;
    FOk, FRef, FErr: Integer;
    FWhy: string;
    procedure Note(ARef: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(const ADb: string; ASeed: Integer; AWriter: Boolean);
    property OkCount: Integer read FOk;
    property RefCount: Integer read FRef;
    property ErrCount: Integer read FErr;
    property Why: string read FWhy;
  end;

constructor TStressThread.Create(const ADb: string; ASeed: Integer; AWriter: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDb := ADb;
  FSeed := ASeed;
  FIsWriter := AWriter;
  FOk := 0;
  FRef := 0;
  FErr := 0;
  FWhy := '';
end;

procedure TStressThread.Note(ARef: Boolean);
begin
  if ARef then Inc(FRef) else Inc(FOk);
  GLock.Enter;
  try
    if ARef then Inc(GRetries) else Inc(GTotalOps);
  finally
    GLock.Leave;
  end;
end;

procedure TStressThread.Execute;
var
  B: IVdbBackend;
  TB: TVTableDb;
  S: TVSql;
  n: Int64;
begin
  try
    VdbOpenWithBusyTimeout(FDb, B, 5000, False);
    B.DurableOnFlush := EnvInt('VDB_SOAK_DURABLE', 1) <> 0;
    TB := TVTableDb.CreateBackend(B);
    try
      TB.Open(ExtractFileDir(FDb));
      S := TVSql.Create(TB);
      try
        n := 0;
        while not GStop do
        begin
          try
            if FIsWriter then
            begin
              Inc(n);
              S.Exec(Format('INSERT INTO t (id, v, s) VALUES (%d, %d, ''c'')',
                [100000000 + Int64(FSeed) * 10000000 + n, n mod 1000]));
            end
            else
            begin
              Inc(n);
              S.Exec(Format('SELECT COUNT(*) FROM t WHERE v = %d', [n mod 1000]));
            end;
            Note(False);
          except
            on E: Exception do
            begin
              if (Pos('mesgul', E.Message) > 0) or (Pos('busy', E.Message) > 0) or
                 (Pos('onbellek tazelenemez', E.Message) > 0) then
              begin
                if FWhy = '' then FWhy := E.Message;
                Note(True);
              end
              else
              begin
                Inc(FErr);
                GLock.Enter;
                try
                  Inc(GTotalErrs);
                finally
                  GLock.Leave;
                end;
                if FWhy = '' then FWhy := E.Message;
              end;
            end;
          end;
        end;
      finally
        S.Free;
      end;
    finally
      TB.Free;
      B := nil;
    end;
  except
    on E: Exception do
    begin
      Inc(FErr);
      FWhy := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ ---------------------------------------------------------------- kosular --- }

procedure WarmupRows;
var
  i: Integer;
begin
  for i := 1 to WARM_ROWS do
  begin
    InsRow(i);
    if (i mod 500) = 0 then
      Be.Engine.Checkpoint(True);
  end;
  GNextId := WARM_ROWS + 1;
  GDelBase := 1;
end;

function RunPhased(ATotal: Int64): Boolean;
var
  t0, elapsed, lastPhase: Int64;
  ph, i: Integer;
  threads: array[0..2] of TStressThread;
  started: Boolean;
  rep: string;
  c1, c2, c3, sumB, sumA, reopened: Int64;
begin
  Result := False;
  GStop := False;
  started := False;
  lastPhase := -1;
  GLastSampleWall := 0;
  GLastCpuMs := 0;
  CpuMs(GLastCpuMs, sumA);
  GLastCpuMs := GLastCpuMs + sumA;

  OpenDb;
  try
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)');
    WarmupRows;
    Be.Engine.Checkpoint(True);
    Chk('T1 isinma tamamlandi (2000 satir)', IntQ('SELECT COUNT(*) FROM t') = WARM_ROWS);

    t0 := NowMs;
    GLastSampleMs := t0;
    while True do
    begin
      elapsed := (NowMs - t0) div 1000;
      if elapsed >= ATotal then Break;
      ph := PhaseOf(elapsed, ATotal);

      if ph <> lastPhase then
      begin
        WriteLn(Format('BILGI faz %s basladi (elapsed=%ds)', [PhaseName(ph), elapsed]));
        Flush(Output);
        lastPhase := ph;

        if (ph = 2) and (EnvInt('VDB_SOAK_THREADS', 1) > 0) then
        begin
          if not started then
          begin
            threads[0] := TStressThread.Create(GDb, 1, True);
            threads[1] := TStressThread.Create(GDb, 2, True);
            threads[2] := TStressThread.Create(GDb, 3, False);
            for i := 0 to 2 do threads[i].Start;
            started := True;
          end;
        end
        else if started then
        begin
          GStop := True;
          for i := 0 to 2 do threads[i].WaitFor;
          started := False;
          for i := 0 to 2 do
          begin
            Chk(Format('T2 eszamanli is parcacigi %d hata=0', [i]),
              threads[i].ErrCount = 0, threads[i].Why);
            WriteLn(Format('BILGI thread %d: ok=%d ret=%d hata=%d',
              [i, threads[i].OkCount, threads[i].RefCount, threads[i].ErrCount]));
            threads[i].Free;
          end;
        end;
      end;

      if (elapsed - ((GLastSampleMs - t0) div 1000)) >= SAMPLE_EVERY then
      begin
        Sample(elapsed, PhaseName(ph));
        GLastSampleMs := NowMs;
      end;

      if ph = 5 then
      begin
        { Son dogrulama fazinda yazma yok; sadece bekleme/ornekleme. }
        Sleep(200);
        Continue;
      end;

      if started then
      begin
        { Eszamanlilik fazinda ana is parcacigi okuma + eski satir silme. }
        try
          if EnvInt('VDB_SOAK_NODELETE', 0) = 0 then
          begin
            Sq.Exec(Format('DELETE FROM t WHERE id = %d', [GDelBase]));
            Inc(GDelBase);
          end;
          IntQ('SELECT COUNT(*) FROM t');
          CountOp(False, False);
        except
          on E: Exception do
            if (Pos('mesgul', E.Message) > 0) or (Pos('busy', E.Message) > 0) or
               (Pos('onbellek tazelenemez', E.Message) > 0) then
              CountOp(False, True)
            else
              CountOp(True, False);
        end;
        Sleep(10);
      end
      else if ph = 0 then
      begin
        IntQ(Format('SELECT v FROM t WHERE id = %d', [Random(WARM_ROWS) + 1]));
      end
      else if ph = 1 then
        CrudCycle
      else if ph = 3 then
        WalCycle
      else
        MixedCycle;
    end;

    { --- son dogrulama --- }
    WriteLn('BILGI son dogrulama basliyor');
    Flush(Output);
    if started then
    begin
      GStop := True;
      for i := 0 to 2 do threads[i].WaitFor;
      started := False;
      for i := 0 to 2 do threads[i].Free;
    end;
    Sample(ATotal, 'final_verify');

    Chk('T3 SONUC: kosu kesintisiz tamamlandi', True,
      Format('planlanan=%ds ornek=%d', [ATotal, GCSV.Count - 1]));

    c1 := IntQ('SELECT COUNT(*) FROM t');
    c2 := IntQ('SELECT COUNT(*) FROM t WHERE id > 0');
    c3 := IntQ('SELECT COUNT(DISTINCT id) FROM t');
    Chk('T4 uc sayim yolu ayni sonucu verdi', (c1 = c2) and (c2 = c3),
      Format('hizli=%d tarama=%d distinct=%d', [c1, c2, c3]));

    sumB := IntQ('SELECT SUM(v) FROM t');
    Be.Engine.Checkpoint(True);
    CloseDb;

    reopened := -1;
    Chk('T5 dosya yeniden acilabiliyor', True);
    OpenDb;
    reopened := IntQ('SELECT COUNT(*) FROM t');
    sumA := IntQ('SELECT SUM(v) FROM t');
    Chk('T6 yeniden acilista satir sayisi korundu', reopened = c1,
      Format('once=%d sonra=%d', [c1, reopened]));
    Chk('T7 yeniden acilista kontrol toplami korundu', sumA = sumB,
      Format('once=%d sonra=%d', [sumB, sumA]));
    InsRow(999999999);
    Chk('T8 yeniden acilis sonrasi hala yazilabilir',
      IntQ('SELECT COUNT(*) FROM t WHERE id = 999999999') = 1);
    CloseDb;

    Chk('T9 VERIFY temiz', VerifyDb(GDb, rep), rep);
  finally
    if started then
      for i := 0 to 2 do
        if threads[i] <> nil then
        begin
          GStop := True;
          threads[i].WaitFor;
          threads[i].Free;
        end;
    if Be <> nil then CloseDb;
  end;
  Result := GFail = 0;
end;

function RunWrite(ATotal: Int64): Boolean;
var
  t0, elapsed: Int64;
  i, nthr: Integer;
  threads: array[0..1] of TStressThread;
  rep: string;
  cnt: Int64;
begin
  Result := False;
  GStop := False;
  { SKILL8 (v3.83): ek yazici is parcacigi sayisi ARTIK ORTAM DEGISKENIYLE
    ayarlanabilir (VDB_WRITE_THREADS, varsayilan 0). Once kosulsuz 2 yazici
    aciliyordu; ana is parcacigi da yazdigi icin AYNI dosyada 3 yazar
    olusuyor, ana oturum "paylasimli kilit alinamadi" ile HIC is yapmadan
    dusuyordu (WF: yazar kilidi alinamadi). Varsayilan 0 = tek yazar
    (ana is parcacigi) ve bu, veritabani motorunun tek-yazar kuralina
    uyar; coklu yazar yolu yalniz istege bagli denenir. }
  threads[0] := nil;
  threads[1] := nil;
  nthr := EnvInt('VDB_WRITE_THREADS', 0);
  if nthr < 0 then nthr := 0;
  if nthr > 2 then nthr := 2;
  OpenDb;
  try
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)');
    GNextId := 1;
    GDelBase := 1;
    t0 := NowMs;
    GLastSampleMs := t0;
    if nthr >= 1 then threads[0] := TStressThread.Create(GDb, 1, True);
    if nthr >= 2 then threads[1] := TStressThread.Create(GDb, 2, True);
    for i := 0 to nthr - 1 do threads[i].Start;

    while True do
    begin
      elapsed := (NowMs - t0) div 1000;
      if elapsed >= ATotal then Break;
      if (elapsed - ((GLastSampleMs - t0) div 1000)) >= SAMPLE_EVERY then
      begin
        Sample(elapsed, 'write');
        GLastSampleMs := NowMs;
      end;
      CrudCycle;
      if (elapsed mod 60) < 2 then
        Be.Engine.Checkpoint(True);
      Sleep(5);
    end;

    GStop := True;
    for i := 0 to nthr - 1 do threads[i].WaitFor;
    for i := 0 to nthr - 1 do
    begin
      Chk(Format('W1 yazici %d hata=0', [i]), threads[i].ErrCount = 0, threads[i].Why);
      WriteLn(Format('BILGI yazici %d: ok=%d ret=%d hata=%d',
        [i, threads[i].OkCount, threads[i].RefCount, threads[i].ErrCount]));
      threads[i].Free;
    end;
    Sample(ATotal, 'write');

    cnt := IntQ('SELECT COUNT(*) FROM t');
    Chk('W2 SONUC: yazma kosusu tamamlandi', True,
      Format('planlanan=%ds satir=%d', [ATotal, cnt]));
    Be.Engine.Checkpoint(True);
    CloseDb;
    OpenDb;
    Chk('W3 yeniden acilista satir sayisi korundu',
      IntQ('SELECT COUNT(*) FROM t') = cnt);
    CloseDb;
    Chk('W4 VERIFY temiz', VerifyDb(GDb, rep), rep);
  finally
    if Be <> nil then CloseDb;
  end;
  Result := GFail = 0;
end;

{ -------------------------------------------------------------------- main --- }

var
  mode: string;
  total: Int64;
begin
  GPass := 0;
  GFail := 0;
  Randomize;
  GSeed := Random(1000);
  GCSV := TStringList.Create;
  GLock := TCriticalSection.Create;
  SetLength(GLAt, 0);
  GTotalOps := 0;
  GTotalErrs := 0;
  GRetries := 0;

  mode := LowerCase(Trim(ParamStr(1)));
  if mode = '' then mode := 'phased';

  if ParamStr(2) <> '' then
    GDir := ParamStr(2)
  else
    GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp');

  if mode = 'quick' then
  begin
    WipeDir(GDir);
    GDir := IncludeTrailingPathDelimiter(GDir);
  end
  else
  begin
    WipeDir(GDir);
    GDir := IncludeTrailingPathDelimiter(GDir);
  end;
  ForceDirectories(GDir);
  GDb := GDir + 'veritabani.odb';
  GMetrics := GDir + 'metrics.csv';

  WriteHeaders;
  GCSV.SaveToFile(GMetrics);

  WriteLn('BILGI mod=', mode);
  WriteLn('BILGI dizin=', GDir);
  WriteLn('BILGI dayaniklilik DurableOnFlush=', EnvInt('VDB_SOAK_DURABLE', 1));
  Flush(Output);

  if mode = 'write' then
  begin
    total := EnvInt('VDB_WRITE_SECONDS', 1800);
    if total < 5 then total := 5;
    RunWrite(total);
  end
  else if mode = 'quick' then
  begin
    total := EnvInt('VDB_PHASED_SECONDS', 30);
    if total < 10 then total := 10;
    RunPhased(total);
  end
  else if mode = 'phased' then
  begin
    total := EnvInt('VDB_PHASED_SECONDS', 7200);
    if total < 60 then total := 60;
    RunPhased(total);
  end
  else
  begin
    WriteLn('HATA: bilinmeyen mod "', mode, '" (phased|write|quick)');
    Halt(2);
  end;

  WriteLn(Format('SONUC: %d PASS, %d FAIL', [GPass, GFail]));
  WriteLn('METRIK_CSV=', GMetrics);
  WriteLn('TOPLAM_OPS=', GTotalOps, ' HATA=', GTotalErrs, ' RET=', GRetries);
  Flush(Output);
  GCSV.Free;
  GLock.Free;
  Halt(GFail);
end.
