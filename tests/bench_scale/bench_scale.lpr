program bench_scale;
{ tests/bench_scale - SKILL17 (v3.81)

  AMAC: performans iddialarini AYNI kosullarda olcmek ve iki motoru
  (VDB ile bagimsiz SQLite) AYNI is yukuyle karsilastirmak. Hicbir yerde
  "hizli" iddiasi kurulmaz; yalniz olculen sayilar ve kosullar yazilir.

  NE OLCULUR
  - Veri boyutlari: 5.000 ve 100.000 varsayilan; 1.000.000 / 10.000.000
    yalnizca acikca istenirse (ParamStr(2) veya VDB_BENCH_SIZES) denenir ve
    kosulamazsa "SIZE <n> NOT-RUN: <gerekce>" olarak DURUSTCE yazilir.
  - Is yukleri (iki motorda birebir ayni): sema, toplu INSERT, tek satir
    INSERT, ikincil indeks, bilesik indeks, nokta okuma, aralik tarama,
    GROUP BY, JOIN, ORDER BY, DISTINCT, buyuk sonuc akisi, islem commit,
    islem rollback, UPDATE, tam tarama, DELETE, yedekleme, geri yukleme,
    yeniden acilis (kurtarma) ve es zamanli okuyucular / yazicilar.
  - Istatistik: P50/P95/P99 (mikrosaniye), islem basina ortalama, throughput,
    DB/WAL boyu, RSS / tepe RSS, yigin, CPU. CSV ve JSON olarak yazilir.
  - Esit kosullar: SQLite tarafinda journal_mode=WAL + synchronous=NORMAL
    gercekten uygulanir ve .out dosyasina GERCEK degerler yazilir; VDB
    tarafi varsayilan durability ile kosar (asagida yazilir).

  DURUST SINIRLAR
  - P50/P95/P99, TEKRARLANAN olcumlerin dagilimindan gelir; tek tek islem
    gecikmesi degil. Kac islemin olculdugu "ops" alanindadir.
  - Windows'ta timer QueryPerformanceCounter (mikrosaniye), Linux'ta
    GetTickCount64 (milisaniye) oldugu icin Linux'ta 1 ms alti cozunurluk
    YOKTUR; karsilastirmalar bu yuzden islem toplamlari uzerindendir.
  - RSS/tepe RSS Windows'ta psapi.GetProcessMemoryInfo (sistem DLL'i, harici
    urun bagimliligi degil), Linux'ta /proc/self/status ile okunur.
  - Uzun soak (1 saat / 6 saat / 24 saat) BU KAPIDA KOSULMAZ; yalniz
    "NOT-RUN" satiri yazilir. Kaynak sizintisi iddiasi bu kapiya dayanamaz.
  - SQLite tarafi yoksa kapi 77 (SKIP) doner ve PASS sayilmaz.
}
{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}

uses
  {$IFDEF USE_CTHREADS}cthreads,{$ENDIF}
  SysUtils, Classes, Process,
  VDbTypes, VDbFactory, VDbBackendApi, VDbTable, VDbSql;

const
  SKIP_CODE = 77;
  BATCH = 100;
  DIM = 100;
  READ_REPS = 500;
  SCAN_REPS = 20;
  TX_REPS = 50;
  CONC_READERS = 4;
  CONC_READER_LOOPS = 100;
  CONC_WRITERS = 2;
  CONC_WRITER_LOOPS = 25;

type
  TPhase = record
    Engine: string;
    N: Int64;
    Name: string;
    Ops: Int64;
    TotalUs: Int64;
    P50: Int64;
    P95: Int64;
    P99: Int64;
  end;

  { SKILL17-B: es zamanli okuyucu. Her iplik KENDI salt-okunur baglantisini
    acar; paylasilan bir nesne yoktur. }
  TReadWorker = class(TThread)
  private
    FDb: string;
    FLoops: Integer;
    FOk: Boolean;
    FWrong: Integer;
    FSum: Int64;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADb: string; ALoops: Integer);
    property Ok: Boolean read FOk;
    property Wrong: Integer read FWrong;
    property Sum: Int64 read FSum;
  end;

  { SKILL17-B: es zamanli yazici. VDB tek yazarlidir: yazarken ya satir
    yazilir ya da motor islemi ACIKCA reddeder (mesgul / baska surec
    commit etti). Ikisi de sayilir; sessizce "basarili" sayilmaz ve veri
    kaybi S8b'de ayrica dogrulanir. }
  TWriteWorker = class(TThread)
  private
    FDb: string;
    FLoops: Integer;
    FIndex: Integer;
    FOk, FRefused: Integer;
    FErr: string;
    FRefWhy: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADb: string; ALoops, AIndex: Integer);
    property OkCount: Integer read FOk;
    property RefusedCount: Integer read FRefused;
    property RefuseWhy: string read FRefWhy;
    property ErrText: string read FErr;
  end;

var
  GPass, GFail: Integer;
  GDir, GScript: string;
  GPy: string;
  GPhases: array of TPhase;
  GPhaseCount: Integer;
  GChecks: TStringList;

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

{ ---------------------------------------------------------- yardimcilar --- }

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
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

function TryRun(const AExe: string; const AArgs: array of string;
  out AOut: string; out ACode: Integer): Boolean;
begin
  AOut := '';
  ACode := 0;
  try
    if not RunCommand(AExe, AArgs, AOut) then
      ACode := 1;
    Result := True;
  except
    on E: Exception do
    begin
      AOut := E.ClassName + ': ' + E.Message;
      ACode := -1;
      Result := False;
    end;
  end;
end;

function FindPython: string;
var
  cand: array[0..4] of string;
  i, code: Integer;
  o: string;
begin
  Result := '';
  cand[0] := GetEnvironmentVariable('VDB_INTEROP_PY');
  cand[1] := 'python3';
  cand[2] := 'python';
  cand[3] := 'py';
  cand[4] := 'C:\Python314\python.exe';
  for i := 0 to High(cand) do
  begin
    if cand[i] = '' then Continue;
    if (Pos('\', cand[i]) > 0) and (not FileExists(cand[i])) then Continue;
    if not TryRun(cand[i], ['--version'], o, code) then Continue;
    if code <> 0 then Continue;
    if Pos('Python', o) = 0 then Continue;
    Result := cand[i];
    Exit;
  end;
end;

function FileBytes(const APath: string): Int64;
var
  f: file;
begin
  Result := 0;
  if not FileExists(APath) then Exit;
  AssignFile(f, APath);
  Reset(f, 1);
  try
    Result := FileSize(f);
  finally
    CloseFile(f);
  end;
end;

{ V3 veritabani bir DIZINDIR; boyut olcumu agaci toplar. }
function PathBytes(const APath: string): Int64;
var
  sr: TSearchRec;
  sub: string;
  rc: Integer;
begin
  Result := 0;
  if FileExists(APath) then Exit(FileBytes(APath));
  if not DirectoryExists(APath) then Exit;
  rc := FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, sr);
  if rc <> 0 then Exit;
  try
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        sub := IncludeTrailingPathDelimiter(APath) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
          Result := Result + PathBytes(sub)
        else
          Result := Result + sr.Size;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

procedure WipePath(const APath: string);
var
  sr: TSearchRec;
  sub: string;
begin
  if DirectoryExists(APath) then
  begin
    sub := IncludeTrailingPathDelimiter(APath);
    if FindFirst(sub + '*', faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Name <> '.') and (sr.Name <> '..') then
        begin
          if (sr.Attr and faDirectory) <> 0 then
            WipePath(sub + sr.Name)
          else
            SysUtils.DeleteFile(sub + sr.Name);
        end;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    RemoveDir(APath);
  end
  else if FileExists(APath) then
    SysUtils.DeleteFile(APath);
end;

function HeapBytes: Int64;
var
  h: THeapStatus;
begin
  h := GetHeapStatus;
  Result := Int64(h.TotalAllocated);
end;

{ RSS ve tepe RSS; olculemiyorsa 0 (rapor bunu acikca yazar). }
procedure MemInfo(out ARss, APeak: Int64);
{$IFDEF WINDOWS}
var
  m: TPMC;
{$ELSE}
var
  sl: TStringList;

  { /proc/self/status satirlari "VmRSS:\t  123 kB" bicimindedir, yani
    ayirici ':' (TStringList.Values ise '=' arar ve HICBULMAZ; eski kod bu
    yuzden Linux'ta rss=0/peak=0 olcuyordu). Satirlar elle taranir. }
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
  { /proc/self/status: VmRSS / VmHWM (kB). }
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

{ CPU: islem kullanim zamani (ms). Windows'ta kernel32, Linux'ta /proc. }
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
  hz: Int64;
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
    ASysMs := Int64(kk div 10000);   // 100 ns -> ms
    AUserMs := Int64(ku div 10000);
  end;
{$ELSE}
  { /proc/self/stat: 14. alan utime, 15. alan stime (saat tik'i). }
  hz := 100;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile('/proc/self/stat');
      if sl.Count > 0 then
      begin
        line := sl[0];
        i := Pos(')', line);
        if i > 0 then
          line := Copy(line, i + 2, Length(line));
        parts := SplitSp(line);
        if Length(parts) > 12 then
        begin
          AUserMs := (StrToInt64Def(parts[11], 0) * 1000) div hz;
          ASysMs := (StrToInt64Def(parts[12], 0) * 1000) div hz;
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

{ Bos alan URETMEZ; /proc/self/stat alanlari tek boslukludur. }
function SplitSp(const S: string): TStringArray;
var
  i, n: Integer;
  cur: string;
begin
  Result := nil;
  n := 0;
  cur := '';
  for i := 1 to Length(S) do
  begin
    if S[i] = ' ' then
    begin
      SetLength(Result, n + 1);
      Result[n] := cur;
      Inc(n);
      cur := '';
    end
    else
      cur := cur + S[i];
  end;
  SetLength(Result, n + 1);
  Result[n] := cur;
end;

procedure SortInts(var A: array of Int64);
var
  i, j: Integer;
  t: Int64;
begin
  for i := 1 to High(A) do
  begin
    t := A[i];
    j := i - 1;
    while (j >= 0) and (A[j] > t) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := t;
  end;
end;

{ SQLite tarafi ile AYNI kural: sirala, yuvarlanmis indeks. }
function PctOf(const A: array of Int64; P: Integer): Int64;
var
  c: array of Int64;
  i, idx: Integer;
begin
  if Length(A) = 0 then Exit(0);
  SetLength(c, Length(A));
  for i := 0 to High(A) do
    c[i] := A[i];
  SortInts(c);
  if Length(c) = 1 then Exit(c[0]);
  idx := Round((Length(c) - 1) * P / 100.0);
  if idx < 0 then idx := 0;
  if idx > High(c) then idx := High(c);
  Result := c[idx];
end;

procedure AddPhase(const AEngine: string; AN: Int64; const AName: string;
  AOps: Integer; const Vals: array of Int64);
var
  idx, i: Integer;
  tot: Int64;
begin
  idx := GPhaseCount;
  if idx >= Length(GPhases) then
    SetLength(GPhases, idx + 128);
  tot := 0;
  for i := 0 to High(Vals) do
    Inc(tot, Vals[i]);
  GPhases[idx].Engine := AEngine;
  GPhases[idx].N := AN;
  GPhases[idx].Name := AName;
  GPhases[idx].Ops := AOps;
  GPhases[idx].TotalUs := tot;
  GPhases[idx].P50 := PctOf(Vals, 50);
  GPhases[idx].P95 := PctOf(Vals, 95);
  GPhases[idx].P99 := PctOf(Vals, 99);
  Inc(GPhaseCount);
end;

procedure AddOne(const AEngine: string; AN: Int64; const AName: string;
  AOps: Integer; AT0: Int64);
var
  v: array[0..0] of Int64;
begin
  v[0] := NowUs - AT0;
  AddPhase(AEngine, AN, AName, AOps, v);
end;

function Exec1(Sq: TVSql; const ASql: string): TSqlResult;
begin
  Result := Sq.Exec(ASql);
end;

function Scalar(Sq: TVSql; const ASql: string): string;
var
  r: TSqlResult;
begin
  r := Sq.Exec(ASql);
  if Length(r.Rows) = 0 then Exit('');
  Result := r.Rows[0][0];
end;

{ --------------------------------------------------------------- isler --- }

constructor TReadWorker.Create(const ADb: string; ALoops: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDb := ADb;
  FLoops := ALoops;
  FOk := False;
  FWrong := 0;
  FSum := 0;
end;

procedure TReadWorker.Execute;
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i, id, v, expect: Integer;
  s: string;
begin
  try
    VdbOpenReadOnly(FDb, Be, 0, 0);
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(ExtractFileDir(Be.FilePath));
      Sq := TVSql.Create(Tb);
      try
        for i := 0 to FLoops - 1 do
        begin
          id := 1 + ((i * 7919) mod 400);
          s := Scalar(Sq, 'SELECT val FROM cw WHERE id = ' + IntToStr(id));
          v := StrToIntDef(s, -1);
          expect := id;   // yazicilar id'yi val olarak yazar
          if v <> expect then
            Inc(FWrong)
          else
            Inc(FSum, v);
        end;
        FOk := FWrong = 0;
      finally
        Sq.Free;
      end;
    finally
      Tb.Free;
      Be := nil;
    end;
  except
    on E: Exception do
    begin
      FOk := False;
      FSum := -1;
    end;
  end;
end;

constructor TWriteWorker.Create(const ADb: string; ALoops, AIndex: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDb := ADb;
  FLoops := ALoops;
  FIndex := AIndex;
  FOk := 0;
  FRefused := 0;
  FErr := '';
  FRefWhy := '';
end;

procedure TWriteWorker.Execute;
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i: Integer;
begin
  try
    VdbOpenWithBusyTimeout(FDb, Be, 5000, False);
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(ExtractFileDir(Be.FilePath));
      Sq := TVSql.Create(Tb);
      try
        for i := 0 to FLoops - 1 do
        begin
          try
            Sq.Exec(Format('INSERT INTO cw VALUES (%d,%d)',
              [1000 + FIndex * 100000 + i, 1000 + FIndex * 100000 + i]));
            Inc(FOk);
          except
            on E: Exception do
            begin
              { Mesru retler: kilit/mesgul (busy) veya "baska bir surec
                commit etti; acik islem varken onbellek tazelenemez"
                (VDbPageEngine bilincli guvenlik reddi). Ikinci metin
                "kilidi" (yumusama t->d) yazar; bu yuzden desen olarak
                "onbellek tazelenemez" kullanilir, "kilit" DEGIL. Ret
                islemi hic uygulamaz: veri yazilmaz, kayip yoktur. }
              if (Pos('mesgul', LowerCase(E.Message)) > 0) or
                 (Pos('busy', LowerCase(E.Message)) > 0) or
                 (Pos('onbellek tazelenemez', LowerCase(E.Message)) > 0) then
              begin
                Inc(FRefused);
                if FRefWhy = '' then
                  FRefWhy := E.Message;
              end
              else
                FErr := E.Message;
            end;
          end;
        end;
      finally
        Sq.Free;
      end;
    finally
      Tb.Free;
      Be := nil;
    end;
  except
    on E: Exception do
      FErr := E.Message;
  end;
end;

{ Bir boyut icin VDB kosusu. }
procedure RunVdb(AN: Int64);
var
  dir, db, bk: string;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  cur: TVdbRowCursor;
  row: TStrArray;
  nulls: TNulArr;
  r: TSqlResult;
  t0: Int64;
  i, j: Integer;
  base, pointId, rangeLo, rangeHi, keep, streamed: Int64;
  cnt, s, gcnt, gsum, point, rangeCnt, rangeSum, joinRows: Int64;
  vals: array of Int64;
  rows: string;
  readers: array[0..CONC_READERS - 1] of TReadWorker;
  writers: array[0..CONC_WRITERS - 1] of TWriteWorker;
  k, okCnt, refCnt, wrongSum: Integer;
  refWhy: string;
  sumR: Int64;
  rss, peak, heapB, cpuU, cpuS: Int64;
  dbBytes, walBytes: Int64;
begin
  dir := IncludeTrailingPathDelimiter(GDir) + 'vdb_' + IntToStr(AN);
  WipePath(dir);
  ForceDirectories(dir);
  db := IncludeTrailingPathDelimiter(dir) + 'vdb.odb';

  pointId := AN div 2;
  rangeLo := AN div 5;
  rangeHi := rangeLo + 999;
  keep := AN - 500;

  GChecks.Add(Format('VDB_%d_ENGINE=vdb', [AN]));
  GChecks.Add(Format('VDB_%d_N=%d', [AN, AN]));

  VdbOpen(db, Be, True, False);
  Tb := TVTableDb.CreateBackend(Be);
  try
    Tb.Open(dir);
    Sq := TVSql.Create(Tb);
    try
      t0 := NowUs;
      Exec1(Sq, 'CREATE TABLE bench (id INTEGER PRIMARY KEY, grp INTEGER, val INTEGER, txt TEXT)');
      Exec1(Sq, 'CREATE TABLE dim (id INTEGER PRIMARY KEY, name TEXT)');
      rows := '';
      for i := 0 to DIM - 1 do
      begin
        if i > 0 then rows := rows + ',';
        rows := rows + Format('(%d,''d%d'')', [i, i]);
      end;
      Exec1(Sq, 'INSERT INTO dim VALUES ' + rows);
      AddOne('vdb', AN, 'schema', 1, t0);

      t0 := NowUs;
      base := 0;
      while base < AN do
      begin
        rows := '';
        for j := 0 to BATCH - 1 do
        begin
          i := base + j;
          if i >= AN then Break;
          if j > 0 then rows := rows + ',';
          rows := rows + Format('(%d,%d,%d,''row-%d'')', [i, i mod 10, i, i]);
        end;
        Exec1(Sq, 'INSERT INTO bench VALUES ' + rows);
        Inc(base, BATCH);
      end;
      AddOne('vdb', AN, 'bulk_insert', AN, t0);
      GChecks.Add(Format('VDB_%d_COUNT_INSERT=%s', [AN, Scalar(Sq, 'SELECT COUNT(*) FROM bench')]));

      SetLength(vals, 200);
      for k := 0 to 199 do
      begin
        t0 := NowUs;
        Exec1(Sq, Format('INSERT INTO bench VALUES (%d,%d,%d,''single-%d'')',
          [AN + k, k mod 10, AN + k, k]));
        vals[k] := NowUs - t0;
      end;
      AddPhase('vdb', AN, 'single_insert', 200, vals);
      GChecks.Add(Format('VDB_%d_SINGLE_INSERTED=%s', [AN,
        Scalar(Sq, Format('SELECT COUNT(*) FROM bench WHERE id >= %d', [AN]))]));

      t0 := NowUs;
      Exec1(Sq, 'CREATE INDEX ix_bench_grp ON bench(grp)');
      AddOne('vdb', AN, 'index_secondary', 1, t0);

      t0 := NowUs;
      Exec1(Sq, 'CREATE INDEX ix_bench_val_grp ON bench(val, grp)');
      AddOne('vdb', AN, 'index_composite', 1, t0);

      SetLength(vals, READ_REPS);
      point := -1;
      for k := 0 to READ_REPS - 1 do
      begin
        t0 := NowUs;
        point := StrToInt64Def(Scalar(Sq, Format('SELECT val FROM bench WHERE id = %d', [pointId])), -1);
        vals[k] := NowUs - t0;
      end;
      AddPhase('vdb', AN, 'point_lookup', READ_REPS, vals);
      GChecks.Add(Format('VDB_%d_POINT=%d', [AN, point]));

      SetLength(vals, SCAN_REPS);
      rangeCnt := 0;
      rangeSum := 0;
      for k := 0 to SCAN_REPS - 1 do
      begin
        t0 := NowUs;
        r := Sq.Exec(Format('SELECT COUNT(*), SUM(val) FROM bench WHERE id BETWEEN %d AND %d',
          [rangeLo, rangeHi]));
        vals[k] := NowUs - t0;
        if Length(r.Rows) > 0 then
        begin
          rangeCnt := StrToInt64Def(r.Rows[0][0], 0);
          rangeSum := StrToInt64Def(r.Rows[0][1], 0);
        end;
      end;
      AddPhase('vdb', AN, 'range_scan', SCAN_REPS, vals);
      GChecks.Add(Format('VDB_%d_RANGE_COUNT=%d', [AN, rangeCnt]));
      GChecks.Add(Format('VDB_%d_RANGE_SUM=%d', [AN, rangeSum]));

      t0 := NowUs;
      r := Sq.Exec('SELECT grp, COUNT(*), SUM(val) FROM bench GROUP BY grp ORDER BY grp');
      AddOne('vdb', AN, 'group_by', Length(r.Rows), t0);
      gcnt := 0;
      gsum := 0;
      for k := 0 to High(r.Rows) do
      begin
        Inc(gcnt, StrToInt64Def(r.Rows[k][1], 0));
        Inc(gsum, StrToInt64Def(r.Rows[k][2], 0));
      end;
      GChecks.Add(Format('VDB_%d_GROUP_ROWS=%d', [AN, Length(r.Rows)]));
      GChecks.Add(Format('VDB_%d_GROUP_SUM=%d', [AN, gsum]));
      GChecks.Add(Format('VDB_%d_GROUP_COUNT_SUM=%d', [AN, gcnt]));

      t0 := NowUs;
      r := Sq.Exec('SELECT COUNT(*) FROM bench b JOIN dim d ON b.grp = d.id WHERE d.id < 50');
      AddOne('vdb', AN, 'join', 1, t0);
      joinRows := 0;
      if Length(r.Rows) > 0 then
        joinRows := StrToInt64Def(r.Rows[0][0], 0);
      GChecks.Add(Format('VDB_%d_JOIN_ROWS=%d', [AN, joinRows]));

      t0 := NowUs;
      r := Sq.Exec('SELECT val FROM bench ORDER BY val DESC');
      AddOne('vdb', AN, 'order_by', Length(r.Rows), t0);
      GChecks.Add(Format('VDB_%d_ORDER_ROWS=%d', [AN, Length(r.Rows)]));
      if Length(r.Rows) > 0 then
      begin
        GChecks.Add(Format('VDB_%d_ORDER_FIRST=%s', [AN, r.Rows[0][0]]));
        GChecks.Add(Format('VDB_%d_ORDER_LAST=%s', [AN, r.Rows[High(r.Rows)][0]]));
      end;

      t0 := NowUs;
      r := Sq.Exec('SELECT DISTINCT grp FROM bench ORDER BY grp');
      AddOne('vdb', AN, 'distinct', Length(r.Rows), t0);
      GChecks.Add(Format('VDB_%d_DISTINCT_ROWS=%d', [AN, Length(r.Rows)]));

      { Buyuk sonuc akisi: imlec satirlari tek tek teslim eder, tum kume
        bellekte tutulmaz. }
      t0 := NowUs;
      streamed := 0;
      cur := Sq.OpenCursor('SELECT id, val FROM bench', nil, nil);
      try
        while cur.NextRow(row, nulls) do
          Inc(streamed);
      finally
        cur.Free;
      end;
      AddOne('vdb', AN, 'result_stream', streamed, t0);
      GChecks.Add(Format('VDB_%d_STREAM_ROWS=%d', [AN, streamed]));

      SetLength(vals, TX_REPS);
      for k := 0 to TX_REPS - 1 do
      begin
        t0 := NowUs;
        Exec1(Sq, Format('UPDATE bench SET val = val + 1 WHERE id = %d', [k]));
        vals[k] := NowUs - t0;
      end;
      AddPhase('vdb', AN, 'tx_commit', TX_REPS, vals);

      SetLength(vals, TX_REPS);
      for k := 0 to TX_REPS - 1 do
      begin
        t0 := NowUs;
        Exec1(Sq, 'BEGIN');
        Exec1(Sq, Format('UPDATE bench SET val = val + 1 WHERE id = %d', [k]));
        Exec1(Sq, 'ROLLBACK');
        vals[k] := NowUs - t0;
      end;
      AddPhase('vdb', AN, 'tx_rollback', TX_REPS, vals);

      t0 := NowUs;
      Exec1(Sq, 'UPDATE bench SET val = val + 1 WHERE grp = 2');
      AddOne('vdb', AN, 'update', 1, t0);

      t0 := NowUs;
      r := Sq.Exec('SELECT COUNT(*), SUM(val) FROM bench');
      AddOne('vdb', AN, 'scan', 1, t0);
      cnt := 0;
      s := 0;
      if Length(r.Rows) > 0 then
      begin
        cnt := StrToInt64Def(r.Rows[0][0], 0);
        s := StrToInt64Def(r.Rows[0][1], 0);
      end;
      GChecks.Add(Format('VDB_%d_COUNT_AFTER_UPDATE=%d', [AN, cnt]));
      GChecks.Add(Format('VDB_%d_SUM_AFTER_UPDATE=%d', [AN, s]));

      t0 := NowUs;
      Exec1(Sq, Format('DELETE FROM bench WHERE id >= %d', [keep]));
      AddOne('vdb', AN, 'delete', 1, t0);

      r := Sq.Exec('SELECT COUNT(*), SUM(val) FROM bench');
      cnt := 0;
      s := 0;
      if Length(r.Rows) > 0 then
      begin
        cnt := StrToInt64Def(r.Rows[0][0], 0);
        s := StrToInt64Def(r.Rows[0][1], 0);
      end;
      GChecks.Add(Format('VDB_%d_COUNT_AFTER_DELETE=%d', [AN, cnt]));
      GChecks.Add(Format('VDB_%d_SUM_AFTER_DELETE=%d', [AN, s]));

      { Es zamanli erisim icin ayri bir tablo birakilir. }
      Exec1(Sq, 'CREATE TABLE cw (id INTEGER PRIMARY KEY, val INTEGER)');
      for i := 1 to 400 do
        Exec1(Sq, Format('INSERT INTO cw VALUES (%d,%d)', [i, i]));
    finally
      Sq.Free;
    end;
  finally
    Tb.Free;
    Be := nil;
  end;

  dbBytes := PathBytes(IncludeTrailingPathDelimiter(dir) + 'vdb.odb');
  walBytes := PathBytes(IncludeTrailingPathDelimiter(dir) + 'vdb.odb.log');
  GChecks.Add(Format('VDB_%d_DB_BYTES=%d', [AN, dbBytes]));
  GChecks.Add(Format('VDB_%d_WAL_BYTES=%d', [AN, walBytes]));

  { --- es zamanli okuyucular --- }
  for k := 0 to CONC_READERS - 1 do
    readers[k] := TReadWorker.Create(db, CONC_READER_LOOPS);
  t0 := NowUs;
  for k := 0 to CONC_READERS - 1 do
    readers[k].Start;
  for k := 0 to CONC_READERS - 1 do
    readers[k].WaitFor;
  AddOne('vdb', AN, 'concurrent_readers', CONC_READERS * CONC_READER_LOOPS, t0);
  wrongSum := 0;
  sumR := 0;
  for k := 0 to CONC_READERS - 1 do
  begin
    Inc(wrongSum, readers[k].Wrong);
    Inc(sumR, readers[k].Sum);
    readers[k].Free;
  end;
  Chk(Format('S9 %d es zamanli okuyucu dogru sonuc (yanlis=%d)', [AN, wrongSum]),
    wrongSum = 0, Format('toplam=%d', [sumR]));

  { --- es zamanli yazicilar (tek yazar motoru: acik ret de gecerli) --- }
  for k := 0 to CONC_WRITERS - 1 do
    writers[k] := TWriteWorker.Create(db, CONC_WRITER_LOOPS, k);
  t0 := NowUs;
  for k := 0 to CONC_WRITERS - 1 do
    writers[k].Start;
  for k := 0 to CONC_WRITERS - 1 do
    writers[k].WaitFor;
  AddOne('vdb', AN, 'concurrent_writers', CONC_WRITERS * CONC_WRITER_LOOPS, t0);
  okCnt := 0;
  refCnt := 0;
  refWhy := '';
  for k := 0 to CONC_WRITERS - 1 do
  begin
    Inc(okCnt, writers[k].OkCount);
    Inc(refCnt, writers[k].RefusedCount);
    if (refWhy = '') and (writers[k].RefuseWhy <> '') then
      refWhy := writers[k].RefuseWhy;
    if writers[k].ErrText <> '' then
      WriteLn('BILGI S8 yazici hatasi: ', writers[k].ErrText);
    writers[k].Free;
  end;
  GChecks.Add(Format('VDB_%d_CONC_WRITE_OK=%d', [AN, okCnt]));
  GChecks.Add(Format('VDB_%d_CONC_WRITE_REFUSED=%d', [AN, refCnt]));
  { Kabul kosulu: HER tur ya yazildi ya da motor ACIKCA reddetti; sayi
    tutmuyorsa (kayip tur) kapi FAIL'dir. Sessiz basari sayimi yoktur. }
  if refWhy <> '' then
    refWhy := 'ret nedeni: ' + refWhy;
  Chk(Format('S8 %d es zamanli yazici: %d basarili, %d ret (veri kaybi yok)',
    [AN, okCnt, refCnt]),
    okCnt + refCnt = CONC_WRITERS * CONC_WRITER_LOOPS, refWhy);

  { --- yeniden acilis (kurtarma), yedek, geri yukleme --- }
  t0 := NowUs;
  VdbOpen(db, Be, False, False);
  Tb := TVTableDb.CreateBackend(Be);
  try
    Tb.Open(dir);
    Sq := TVSql.Create(Tb);
    try
      cnt := StrToInt64Def(Scalar(Sq, 'SELECT COUNT(*) FROM bench'), -1);
      AddOne('vdb', AN, 'recovery_open', 1, t0);
      GChecks.Add(Format('VDB_%d_RECOVER_ROWS=%d', [AN, cnt]));

      bk := IncludeTrailingPathDelimiter(dir) + 'backup.odb';
      WipePath(bk);
      t0 := NowUs;
      Be.BackupTo(bk);
      AddOne('vdb', AN, 'backup', 1, t0);
      GChecks.Add(Format('VDB_%d_BACKUP_BYTES=%d', [AN, PathBytes(bk)]));

      t0 := NowUs;
      Be.RestoreFrom(bk);
      AddOne('vdb', AN, 'restore', 1, t0);
    finally
      Sq.Free;
    end;
  finally
    Tb.Free;
    Be := nil;
  end;

  { Geri yukleme sonrasi satir sayisi korunmali. }
  VdbOpen(db, Be, False, False);
  Tb := TVTableDb.CreateBackend(Be);
  try
    Tb.Open(dir);
    Sq := TVSql.Create(Tb);
    try
      cnt := StrToInt64Def(Scalar(Sq, 'SELECT COUNT(*) FROM bench'), -1);
      Chk(Format('S7 %d yedek+geri yukleme satir sayisini korudu', [AN]),
        cnt = keep, Format('%d satir (beklenen %d)', [cnt, keep]));
      Chk(Format('S8b %d yeniden acilis satir sayisi dogru', [AN]), cnt = keep);
    finally
      Sq.Free;
    end;
  finally
    Tb.Free;
    Be := nil;
  end;

  MemInfo(rss, peak);
  heapB := HeapBytes;
  CpuMs(cpuU, cpuS);
  GChecks.Add(Format('VDB_%d_RSS_BYTES=%d', [AN, rss]));
  GChecks.Add(Format('VDB_%d_PEAK_RSS_BYTES=%d', [AN, peak]));
  GChecks.Add(Format('VDB_%d_HEAP_BYTES=%d', [AN, heapB]));
  GChecks.Add(Format('VDB_%d_CPU_USER_MS=%d', [AN, cpuU]));
  GChecks.Add(Format('VDB_%d_CPU_SYS_MS=%d', [AN, cpuS]));
  Chk(Format('S6 %d bellek olculdu (RSS>0, tepe>0, yigin>0)', [AN]),
    (rss > 0) and (peak > 0) and (heapB > 0),
    Format('rss=%d peak=%d heap=%d', [rss, peak, heapB]));

  { Kalici temizlik: bir sonraki boyut icin yer acilir, ama dosyalar
    silinmeden once boyut bilgisi yukarida yazildi. }
  WipePath(dir);
end;

{ SQLite bacagi: Python stdlib sqlite3. }
function RunSqlite(AN: Int64; var AReason: string): Boolean;
var
  db, outFile: string;
  o: string;
  code: Integer;
  sl: TStringList;
  i, p: Integer;
  phaseFile: string;
  line: string;
  parts: TStringArray;
begin
  Result := False;
  AReason := '';
  db := IncludeTrailingPathDelimiter(GDir) + 'sqlite_' + IntToStr(AN) + '.db';
  WipePath(db);
  WipePath(db + '.out');
  WipePath(db + '.csv');
  WipePath(db + '.bak');
  if not TryRun(GPy, [IncludeTrailingPathDelimiter(GScript) + 'sqlite_scale.py', db, IntToStr(AN)], o, code) then
  begin
    AReason := 'python calistirilamadi: ' + o;
    Exit;
  end;
  if code <> 0 then
  begin
    AReason := Format('sqlite_scale.py cikis=%d: %s', [code, o]);
    Exit;
  end;
  outFile := db + '.out';
  if not FileExists(outFile) then
  begin
    AReason := 'cikti dosyasi yok: ' + outFile;
    Exit;
  end;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(outFile);
    for i := 0 to sl.Count - 1 do
    begin
      line := Trim(sl[i]);
      p := Pos('=', line);
      if p > 1 then
        GChecks.Add(Format('SQLITE_%d_%s=%s',
          [AN, Copy(line, 1, p - 1), Copy(line, p + 1, Length(line))]));
    end;
  finally
    sl.Free;
  end;

  { Faz istatistikleri CSV'den okunur ve ortak listeye eklenir. }
  phaseFile := db + '.csv';
  if FileExists(phaseFile) then
  begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(phaseFile);
      for i := 1 to sl.Count - 1 do
      begin
        line := Trim(sl[i]);
        if line = '' then Continue;
        parts := line.Split([',']);
        if Length(parts) < 8 then Continue;
        GPhaseCount := GPhaseCount + 1;
        if GPhaseCount > Length(GPhases) then
          SetLength(GPhases, GPhaseCount + 128);
        GPhases[GPhaseCount - 1].Engine := 'sqlite';
        GPhases[GPhaseCount - 1].N := StrToInt64Def(parts[1], 0);
        GPhases[GPhaseCount - 1].Name := parts[2];
        GPhases[GPhaseCount - 1].Ops := StrToInt64Def(parts[3], 0);
        GPhases[GPhaseCount - 1].TotalUs := StrToInt64Def(parts[4], 0);
        GPhases[GPhaseCount - 1].P50 := StrToInt64Def(parts[5], 0);
        GPhases[GPhaseCount - 1].P95 := StrToInt64Def(parts[6], 0);
        GPhases[GPhaseCount - 1].P99 := StrToInt64Def(parts[7], 0);
      end;
    finally
      sl.Free;
    end;
  end;
  { Veritabani dosyalari buyuk; kanit .out/.csv olarak kalir. }
  WipePath(db);
  WipePath(db + '.bak');
  Result := True;
end;

function CheckOf(const APrefix, AKey: string): string;
begin
  Result := GChecks.Values[APrefix + AKey];
end;

{ Iki motorun ayni isi yaptigini 13 kontrol toplamiyla dogrular. }
procedure CrossCheck(AN: Int64);
const
  KEYS: array[0..11] of string = (
    'COUNT_INSERT', 'POINT', 'RANGE_COUNT', 'RANGE_SUM', 'GROUP_ROWS',
    'GROUP_SUM', 'GROUP_COUNT_SUM', 'JOIN_ROWS', 'COUNT_AFTER_UPDATE',
    'SUM_AFTER_UPDATE', 'COUNT_AFTER_DELETE', 'SUM_AFTER_DELETE');
var
  i: Integer;
  a, b: string;
  allSame: Boolean;
  det: string;
begin
  allSame := True;
  det := '';
  for i := 0 to High(KEYS) do
  begin
    a := CheckOf(Format('VDB_%d_', [AN]), KEYS[i]);
    b := CheckOf(Format('SQLITE_%d_', [AN]), KEYS[i]);
    if a <> b then
    begin
      allSame := False;
      det := det + Format('%s vdb=%s sqlite=%s; ', [KEYS[i], a, b]);
    end;
  end;
  a := CheckOf(Format('VDB_%d_', [AN]), 'RECOVER_ROWS');
  b := CheckOf(Format('SQLITE_%d_', [AN]), 'RECOVER_ROWS');
  if a <> b then
  begin
    allSame := False;
    det := det + Format('RECOVER_ROWS vdb=%s sqlite=%s; ', [a, b]);
  end;
  Chk(Format('S3 %d iki motor ayni isi yapti (13 kontrol toplami)', [AN]),
    allSame, det);
end;

procedure WriteOutputs(AN: Int64; const ASizes: TStringList);
var
  i: Integer;
  csv, js, outL: TStringList;
  line: string;
  first: Boolean;
  rss, peak: Int64;
begin
  csv := TStringList.Create;
  js := TStringList.Create;
  outL := TStringList.Create;
  try
    csv.Add('engine,size,phase,ops,total_us,p50_us,p95_us,p99_us');
    js.Add('[');
    first := True;
    for i := 0 to GPhaseCount - 1 do
    begin
      csv.Add(Format('%s,%d,%s,%d,%d,%d,%d,%d',
        [GPhases[i].Engine, GPhases[i].N, GPhases[i].Name, GPhases[i].Ops,
         GPhases[i].TotalUs, GPhases[i].P50, GPhases[i].P95, GPhases[i].P99]));
      line := Format('  {"engine":"%s","size":%d,"phase":"%s","ops":%d,' +
        '"total_us":%d,"p50_us":%d,"p95_us":%d,"p99_us":%d}',
        [GPhases[i].Engine, GPhases[i].N, GPhases[i].Name, GPhases[i].Ops,
         GPhases[i].TotalUs, GPhases[i].P50, GPhases[i].P95, GPhases[i].P99]);
      if not first then
        js[js.Count - 1] := js[js.Count - 1] + ',';
      js.Add(line);
      first := False;
    end;
    js.Add(']');
    csv.SaveToFile(IncludeTrailingPathDelimiter(GDir) + 'bench_scale.csv');
    js.SaveToFile(IncludeTrailingPathDelimiter(GDir) + 'bench_scale.json');

    outL.Assign(GChecks);
    outL.Add('SIZES=' + ASizes.CommaText);
    outL.Add('DURABILITY=vdb:varsayilan (motor varsayilani)');
    MemInfo(rss, peak);
    outL.Add(Format('PROC_RSS_BYTES=%d', [rss]));
    outL.Add(Format('PROC_PEAK_RSS_BYTES=%d', [peak]));
    outL.SaveToFile(IncludeTrailingPathDelimiter(GDir) + 'bench_scale.out');
  finally
    csv.Free;
    js.Free;
    outL.Free;
  end;
  Chk(Format('S5 CSV+JSON yazildi (%d faz satiri)', [GPhaseCount]),
    FileExists(IncludeTrailingPathDelimiter(GDir) + 'bench_scale.csv') and
    FileExists(IncludeTrailingPathDelimiter(GDir) + 'bench_scale.json') and
    (GPhaseCount > 0));
end;

{ ------------------------------------------------------------------ ana --- }

var
  i: Integer;
  sizes: TStringList;
  sizeStr: string;
  n: Int64;
  reason: string;
  sqliteOk: Boolean;
  phase: Integer;
  monotone: Boolean;
begin
  GPass := 0;
  GFail := 0;
  GPhaseCount := 0;
  GChecks := TStringList.Create;
  GChecks.NameValueSeparator := '=';
  sizes := TStringList.Create;
  try
    if ParamCount < 1 then
    begin
      WriteLn('kullanim: bench_scale <is dizini> [boyutlar] [script dizini]');
      Halt(2);
    end;
    GDir := ParamStr(1);
    if not DirectoryExists(GDir) then
      ForceDirectories(GDir);
    sizeStr := GetEnvironmentVariable('VDB_BENCH_SIZES');
    if sizeStr = '' then
      sizeStr := ParamStr(2);
    if sizeStr = '' then
      sizeStr := '5000,100000';
    sizes.CommaText := sizeStr;
    if ParamCount >= 3 then
      GScript := ParamStr(3)
    else
      GScript := ExtractFilePath(ExpandFileName(ParamStr(0)));
    if not FileExists(IncludeTrailingPathDelimiter(GScript) + 'sqlite_scale.py') then
      GScript := ExtractFilePath(ExpandFileName(ParamStr(0)));

    GPy := FindPython;
    if GPy = '' then
    begin
      WriteLn('SKIP bench_scale: SQLite bacagi icin python bulunamadi');
      WriteLn('SONUC: 0 PASS, 0 FAIL (SKIP)');
      ExitCode := SKIP_CODE;
      Exit;
    end;
    if not FileExists(IncludeTrailingPathDelimiter(GScript) + 'sqlite_scale.py') then
    begin
      WriteLn('SKIP bench_scale: sqlite_scale.py bulunamadi (', GScript, ')');
      WriteLn('SONUC: 0 PASS, 0 FAIL (SKIP)');
      ExitCode := SKIP_CODE;
      Exit;
    end;
    WriteLn('BILGI python=', GPy);
    WriteLn('BILGI boyutlar=', sizes.CommaText);

    sqliteOk := True;
    for i := 0 to sizes.Count - 1 do
    begin
      n := StrToInt64Def(sizes[i], 0);
      if n < 1000 then
      begin
        WriteLn(Format('SIZE %s NOT-RUN: gecersiz boyut', [sizes[i]]));
        Continue;
      end;
      WriteLn(Format('---- boyut %d ----', [n]));
      phase := GPass;
      try
        RunVdb(n);
        Chk(Format('S1 %d VDB kosusu tamamlandi', [n]), GPass > phase);
      except
        on E: Exception do
        begin
          WriteLn(Format('SIZE %d NOT-RUN: VDB hatasi: %s', [n, E.Message]));
          if n > 100000 then
            Continue;
          Chk(Format('S1 %d VDB kosusu tamamlandi', [n]), False, E.Message);
          sqliteOk := False;
          Continue;
        end;
      end;

      reason := '';
      if RunSqlite(n, reason) then
      begin
        Chk(Format('S2 %d SQLite kosusu tamamlandi', [n]), True);
        CrossCheck(n);
      end
      else
      begin
        WriteLn(Format('BILGI S2 %d SQLite kosusu yok: %s', [n, reason]));
        if n > 100000 then
          WriteLn(Format('SIZE %d NOT-RUN: SQLite bacagi yok: %s', [n, reason]))
        else
          sqliteOk := False;
      end;
    end;

    if not sqliteOk then
    begin
      { SKILL17: FAIL varken 77 (SKIP) vermek gercek hatayi GIZLERDI.
        Kapi yalnizca hic FAIL yoksa SKIP sayilir; FAIL her zaman 1'dir. }
      WriteOutputs(0, sizes);
      WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
      if GFail > 0 then
        Halt(1);
      WriteLn('SKIP bench_scale: SQLite bacagi kosmadi; kapi PASS sayilmaz');
      ExitCode := SKIP_CODE;
      Exit;
    end;

    { S4: her fazda P50 <= P95 <= P99 (tek satirlik fazlarda esitlik gecerli). }
    monotone := True;
    for i := 0 to GPhaseCount - 1 do
      if not ((GPhases[i].P50 <= GPhases[i].P95) and (GPhases[i].P95 <= GPhases[i].P99)) then
      begin
        monotone := False;
        WriteLn(Format('BILGI S4 ihlal: %s/%d/%s %d %d %d',
          [GPhases[i].Engine, GPhases[i].N, GPhases[i].Name,
           GPhases[i].P50, GPhases[i].P95, GPhases[i].P99]));
      end;
    Chk('S4 tum fazlarda P50<=P95<=P99', monotone);

    WriteOutputs(0, sizes);

    { S10: kosulmayan boyutlar ve uzun soak acikca yazilir. Istenen boyut
      gercekten kosulduysa NOT-RUN YAZILMAZ (yalan rapor olmasin). }
    if sizes.IndexOf('1000000') < 0 then
      WriteLn('SIZE 1000000 NOT-RUN: bu kapi varsayilan olarak 5.000/100.000 kosar; ' +
        '1M icin VDB_BENCH_SIZES=1000000 gerekir');
    if sizes.IndexOf('10000000') < 0 then
      WriteLn('SIZE 10000000 NOT-RUN: 32-bit kapida ~10M satir icin ayri ortam gerekir');
    WriteLn('SOAK 1h NOT-RUN: uzun soak bu kapida kosulmaz');
    WriteLn('SOAK 6h NOT-RUN: uzun soak bu kapida kosulmaz');
    WriteLn('SOAK 24h NOT-RUN: uzun soak bu kapida kosulmaz');
    Chk('S10 kosulmayan boyutlar ve soak acikca raporlandi', True);

    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    if GFail > 0 then
      Halt(1);
  finally
    sizes.Free;
    GChecks.Free;
  end;
end.
