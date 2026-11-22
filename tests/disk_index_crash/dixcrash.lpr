program dixcrash;
{ tests/disk_index_crash - SKILL12: DISK INDEKSI COKME MATRISI (v5)

  Amac: heap ile indeksin AYNI islem sinirinda kaldigini ve cokme sonrasi
  indeksin ASLA yanlis satir dondurmedigini olcmek. Her iddia ayri bir
  kontrol olarak yazilir; olculemeyen sey PASS sayilmaz.

  Yontem: cocuk surec GERCEK olarak oldurulur (TerminateProcess / SIGKILL;
  Close, Destroy ve finalization CALISMAZ). Enjeksiyon noktalari:

    precommit  heap commit'inden ONCE (fsync yok)
    heap       heap commit'i TAMAM, indeks dosyasina HIC dokunulmadi
    prepage    indeks sayfa yazimindan once
    midpages   coklu sayfa yaziminin ortasinda (ilk sayfa indi, gerisi inmedi)
    postpage   tum sayfalar indi, META yazilmadi
    premeta    meta yazimindan hemen once (postpage ile ayni durum)
    postmeta   meta yazildi, fsync YOK

  Bolunme / birlestirme / kok degisimi BELLEKTE olur; diske etkisi ancak
  Commit icindeki sayfa ve meta yazimiyla gorunur. Bu yuzden gozlenebilir
  cokme pencereleri yukaridaki noktalardir. Is yuku (300 anahtar degisimi +
  201 silme + 200 ekleme, tek islem) agacta cok sayida bolunme/birlestirme
  ve muhtemelen kok degisimi uretir.

  Her asamada olculen:
    * surec gercekten oldu mu
    * yeniden acilista vmFull dogrulama temiz mi
    * heap satir sayisi beklenen durumda mi (eski / yeni / ikisi de)
    * INDEKSLI sonuc ile heap'ten bagimsiz hesaplanan kume AYNI mi
    * indeks diskten mi servis edildi (DiskIdxHits) yoksa yeniden mi
      kuruldu (DiskIdxBuilds) - asama basina beklenti ayri yazilir
    * .dix dosyasi duruyor ve kapanistan sonra yazilabilir mi (tanitici
      sizmadi) }
{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}
uses
  {$IFDEF USE_CTHREADS}cthreads,{$ENDIF}
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Process, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore, VDbExecutor, VDbErr, VDbDiskIdx;

const
  DBNAME = 'dixcrash.odb';
  NBASE = 2000;          { taban satir: id 1..2000 }
  NEWLO = 2001;          { islemde eklenen satirlar: id 2001..2200 }
  NEWHI = 2200;
  BATCH = 500;
  GCrashCode = 9;
  { Ebeveynin gordugu cikis degeri platforma baglidir: Windows'ta
    TerminateProcess(9) -> 9; Unix'te fpKill(SIGKILL) -> FPC TProcess
    sinyal olumunu NEGATIF sinyal numarasi olarak verir (-9). Iki deger
    de "surec temizlik yapmadan gercekten oldu" demektir. Halt(GCrashCode)
    yalnizca fpKill basarisiz olursa calisir; Unix'te kabul EDILMEZ ki
    hard-kill gercekten olculsun. }
  {$IFDEF WINDOWS}
  GCrashExpect = GCrashCode;
  {$ELSE}
  GCrashExpect = -GCrashCode;
  {$ENDIF}
  { VDbPageEngine'deki commit asamalari (crash_points ile ayni numaralar). }
  ENG_PRE_SYNC = 6;      { fsync YOK: commit kaybi serbest }
  ENG_POST_SYNC = 7;     { fsync VAR: commit DURABIL }

type
  TInt64Arr = array of Int64;

var
  GDir, GDb, GExe: string;
  GPass, GFail: Integer;
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, '  ', ADetail);
  end;
  Flush(Output);
end;

{ --------------------------------------------------------------- cocuk ---- }

procedure HardExitNow(ACode: Integer);
begin
  {$IFDEF WINDOWS}
  TerminateProcess(GetCurrentProcess, LongWord(ACode));
  {$ELSE}
  fpKill(fpGetPid, SIGKILL);
  {$ENDIF}
  Halt(ACode);   { ulasilmamali }
end;

procedure KillHook;
begin
  HardExitNow(GCrashCode);
end;

function DixStageOf(const AMode: string): Integer;
begin
  if AMode = 'prepage' then Result := DIX_CRASH_PRE_PAGE
  else if AMode = 'midpages' then Result := DIX_CRASH_MID_PAGES
  else if AMode = 'postpage' then Result := DIX_CRASH_POST_PAGE
  else if AMode = 'premeta' then Result := DIX_CRASH_PRE_META
  else if AMode = 'postmeta' then Result := DIX_CRASH_POST_META
  else Result := DIX_CRASH_NONE;
end;

procedure RunChild(const ADir, AMode: string);
var
  b: TVdbBackendV3;
  t: TVTableDb;
  q: TVSql;
  k: Integer;
begin
  b := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(ADir) + DBNAME);
  try
    t := TVTableDb.CreateBackend(b);
    try
      t.Open(IncludeTrailingPathDelimiter(ADir));
      q := TVSql.Create(t);
      try
        if AMode = 'heap' then
        begin
          b.Engine.CrashAtStage := ENG_POST_SYNC;
          b.Engine.OnCrashPoint := @KillHook;
        end
        else if AMode = 'precommit' then
        begin
          b.Engine.CrashAtStage := ENG_PRE_SYNC;
          b.Engine.OnCrashPoint := @KillHook;
        end
        else
        begin
          VDbDixCrashStage := DixStageOf(AMode);
          VDbDixCrashHook := @KillHook;
        end;
        { TEK islem: tum degisiklikler ayni commit'e girer. Boylece
          "heap onaylandi, indeks yazilmadi" penceresi gercekten acilir. }
        q.Exec('BEGIN');
        q.Exec('UPDATE t SET a = ''z'' WHERE id <= 300');
        q.Exec('DELETE FROM t WHERE id >= 500 AND id <= 700');
        for k := NEWLO to NEWHI do
          q.Exec('INSERT INTO t (id, a, n, b) VALUES (' + IntToStr(k) +
            ', ''k7'', ' + IntToStr(k mod 100) + ', ''b1'')');
        q.Exec('COMMIT');
        WriteLn('CHILD SURVIVED mode=', AMode);
        Flush(Output);
        Halt(3);
      finally
        q.Free;
      end;
    finally
      t.Free;
    end;
  finally
    b := nil;
  end;
end;

{ ------------------------------------------------------------- yardimci -- }

procedure Wipe(const ADir: string);
var
  sr: TSearchRec;
begin
  ForceDirectories(ADir);
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(ADir) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function FileSizeOf(const APath: string): Int64;
var
  fs: TFileStream;
begin
  Result := -1;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

function CanWrite(const APath: string): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareExclusive);
    try
      Result := True;
    finally
      fs.Free;
    end;
  except
  end;
end;

function FirstDix(const ADir: string): string;
var
  sr: TSearchRec;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + 'vdbidx_*.dix',
    faAnyFile, sr) = 0 then
  begin
    Result := IncludeTrailingPathDelimiter(ADir) + sr.Name;
    FindClose(sr);
  end;
end;

procedure OpenDb;
begin
  Be := TVdbBackendV3.Create(GDb);
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

function VerifyDb(const APath: string; out ARep: string): Boolean;
var
  bc: TVdbBackendV3;
begin
  ARep := '';
  bc := TVdbBackendV3.CreateReadOnly(APath);
  try
    Result := bc.Engine.VerifyEx(vmFull, True, ARep);
  finally
    bc.Free;
  end;
end;

procedure AddId(var A: TInt64Arr; AVal: Int64);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := AVal;
end;

function SortedStr(var A: TInt64Arr): string;
var
  i, j: Integer;
  v: Int64;
begin
  { Kucuk liste: basit ekleme sirasi yeterli (en fazla birkac bin oge). }
  for i := 1 to High(A) do
  begin
    v := A[i];
    j := i - 1;
    while (j >= 0) and (A[j] > v) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := v;
  end;
  Result := '';
  for i := 0 to High(A) do
    Result := Result + IntToStr(A[i]) + ',';
end;

{ HEAP'TEN BAGIMSIZ GERCEK: anahtar birincil anahtar araligidir (id), ix_a
  DEGILDIR. Boylece indeks bayat/eksik olsa bile bu kume etkilenmez. }
procedure HeapTruth(out ATotal: Int64; out AIds: string);
var
  r: TSqlResult;
  i: Integer;
  a: TInt64Arr;
begin
  a := nil;
  r := Sq.Exec('SELECT id, a FROM t WHERE id >= 1 AND id <= ' + IntToStr(NEWHI));
  for i := 0 to High(r.Rows) do
    if (Length(r.Rows[i]) >= 2) and (Trim(r.Rows[i][1]) = 'k7') then
      AddId(a, StrToInt64Def(Trim(r.Rows[i][0]), -1));
  ATotal := Length(r.Rows);
  AIds := SortedStr(a);
end;

{ Cok satirli listelerde oge sayisi: her oge sonunda bir virgul var. }
function Entries(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do
    if S[i] = ',' then Inc(Result);
end;

{ IS YUKUNUN BEKLENTISI (SQL'den bagimsiz, id kuralindan turetilir):
  k7 kumesi eski durumda id mod 50 = 7; yeni durumda ek olarak id <= 300
  ve 500..700 dislanir, 2001..2200 eklenir. }
function ExpectK7(ATotal: Int64): Integer;
var
  id: Integer;
begin
  Result := 0;
  for id := 1 to NBASE do
    if (id mod 50 = 7) and (ATotal <> NBASE) then
    begin
      if (id > 300) and not ((id >= 500) and (id <= 700)) then Inc(Result);
    end
    else if (id mod 50 = 7) and (ATotal = NBASE) then
      Inc(Result);
  if ATotal <> NBASE then
    Inc(Result, NEWHI - NEWLO + 1);
end;

function IndexIds: string;var
  r: TSqlResult;
  i: Integer;
  a: TInt64Arr;
begin
  a := nil;
  r := Sq.Exec('SELECT id FROM t WHERE a = ''k7''');
  for i := 0 to High(r.Rows) do
    if Length(r.Rows[i]) >= 1 then
      AddId(a, StrToInt64Def(Trim(r.Rows[i][0]), -1));
  Result := SortedStr(a);
end;

procedure InsertRange(ALo, AHi: Int64);
var
  id, stop: Int64;
begin
  id := ALo;
  while id <= AHi do
  begin
    Sq.Exec('BEGIN');
    stop := id + BATCH - 1;
    if stop > AHi then stop := AHi;
    while id <= stop do
    begin
      Sq.Exec('INSERT INTO t (id, a, n, b) VALUES (' + IntToStr(id) +
        ', ''k' + IntToStr(id mod 50) + ''', ' + IntToStr(id mod 100) +
        ', ''b' + IntToStr(id mod 7) + ''')');
      Inc(id);
    end;
    Sq.Exec('COMMIT');
  end;
end;

procedure CreateBase;
begin
  CloseDb;
  Wipe(GDir);
  OpenDb;
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, n INTEGER, b TEXT)');
  InsertRange(1, NBASE);
  Sq.Exec('CREATE INDEX ix_a ON t (a)');
  CloseDb;
end;

{ ------------------------------------------------------------ ebeveyn ---- }

function RunChildSync(const ADir, AMode: string; out AOut: string): Integer;
var
  P: TProcess;
  buf: array[0..4095] of AnsiChar;
  n: LongInt;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := GExe;
    P.Parameters.Add('child');
    P.Parameters.Add(ADir);
    P.Parameters.Add(AMode);
    P.Options := [poUsePipes, poStderrToOutput];
    P.Execute;
    AOut := '';
    repeat
      n := P.Output.Read(buf, SizeOf(buf));
      if n > 0 then
        AOut := AOut + Copy(buf, 1, n);
    until n <= 0;
    P.WaitOnExit;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

procedure RunStage(const AMode: string; AHeap: Integer; ABuilds: Integer);
{ AHeap:   0 = ESKI (2000 satir), 1 = YENI (1999), 2 = ikisi de olabilir
  ABuilds: 1 = yeniden insa SART, 0 = diskten servis SART, 2 = heap durumuna bagli }
var
  rc: Integer;
  out1, rep, idsHeap, idsIdx, dix: string;
  total: Int64;
  verified, okTotal, okBuild: Boolean;
  sz: Int64;
begin
  CreateBase;
  rc := RunChildSync(GDir, AMode, out1);
  Chk('C ' + AMode + '/olduruldu', rc = GCrashExpect,
    'rc=' + IntToStr(rc) + ' cikti=' + out1);
  OpenDb;
  HeapTruth(total, idsHeap);
  IndexIds;                    { ilk sorgu soguk acilis yapabilir }
  idsIdx := IndexIds;          { ikinci sorgu onbellekten servis eder }
  okTotal := ((AHeap = 2) and ((total = NBASE) or (total = NBASE - 201 + 200))) or
             ((AHeap = 1) and (total = NBASE - 201 + 200)) or
             ((AHeap = 0) and (total = NBASE));
  Chk('C ' + AMode + '/heap durumu', okTotal,
    'satir=' + IntToStr(total) + ' beklenen=' + IntToStr(AHeap));
  Chk('C ' + AMode + '/heap kumesi is yukune uyuyor',
    Entries(idsHeap) = ExpectK7(total),
    'k7=' + IntToStr(Entries(idsHeap)) + ' beklenen=' + IntToStr(ExpectK7(total)));
  Chk('C ' + AMode + '/indeks = heap', idsIdx = idsHeap,
    'indeks=' + IntToStr(Length(idsIdx)) + ' bayt heap=' +
    IntToStr(Length(idsHeap)) + ' bayt');
  if ABuilds = 1 then
    okBuild := Tb.DiskIdxBuilds >= 1
  else if ABuilds = 0 then
    okBuild := (Tb.DiskIdxBuilds = 0) and (Tb.DiskIdxHits > 0)
  else
    okBuild := ((total = NBASE) and (Tb.DiskIdxBuilds = 0) and
                (Tb.DiskIdxHits > 0)) or
               ((total <> NBASE) and (Tb.DiskIdxBuilds >= 1));
  Chk('C ' + AMode + '/indeks kaynagi', okBuild,
    'builds=' + IntToStr(Tb.DiskIdxBuilds) + ' hits=' + IntToStr(Tb.DiskIdxHits) +
    ' beklenen=' + IntToStr(ABuilds));
  CloseDb;
  verified := VerifyDb(GDb, rep);
  Chk('C ' + AMode + '/vmFull temiz', verified, rep);
  dix := FirstDix(GDir);
  sz := FileSizeOf(dix);
  Chk('C ' + AMode + '/.dix gecerli', (dix <> '') and (sz >= 3 * 4096),
    'boy=' + IntToStr(sz));
  Chk('C ' + AMode + '/tanitici birakildi', (dix <> '') and CanWrite(dix));
end;

begin
  GExe := ParamStr(0);
  if (ParamCount >= 2) and (ParamStr(1) = 'child') then
  begin
    RunChild(ParamStr(2), ParamStr(3));
    Exit;
  end;

  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'dixcrash_work');
  GDb := GDir + DBNAME;

  { Heap commit'inden once: commit kaybi serbest, TUTARSIZLIK yasak. }
  RunStage('precommit', 2, 2);
  { Heap onaylandi, indeks dosyasina hic dokunulmadi -> yeniden insa SART. }
  RunStage('heap', 1, 1);
  { Indeks yaziminin her penceresi -> yine yeniden insa (meta eski). }
  RunStage('prepage', 1, 1);
  RunStage('midpages', 1, 1);
  RunStage('postpage', 1, 1);
  RunStage('premeta', 1, 1);
  { Meta indi ve damga heap ile AYNI -> dosyadan servis, insa YOK. }
  RunStage('postmeta', 1, 0);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
