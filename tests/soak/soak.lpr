program soak;
{ v3.50 KALICI REGRESYON KAPISI - SKILL4 §7 ag/kaynak soak'i (gömülü motor).
  Amac: UZUN SURE calisan bir yuk altinda RAM, dosya tutamacasi (FD/handle),
  is parcacigi (thread), WAL boyu, veritabani boyu, sorgu gecikmesi ve hata
  oraninin SUREKLI BUYUMEDIGINI olcmek. "Soak gecti" iddiasi olcumsuz
  birakilmaz: her kontrol SOMUT bir sayi raporlar.

  IS YUKU (sabit calisma kumesi):
    - isinma: 2000 satir eklenir
    - her turda: BATCH yeni satir eklenir (BEGIN/COMMIT), ayni turda en
      eski BATCH satir silinir -> canli satir sayisi HEP 2000 kalir.
      Sabit calisma kumesi, "dosya buyudu" sinyalini satir sayisi artisindan
      ayirir: boyu sabit tutan bir yukte dosya buyumeye devam ediyorsa bu
      gercek bir sizintidir.
    - her turda rastgele mevcut bir satir guncellenir
    - her 15 turda veritabani KAPATILIP YENIDEN ACILIR (tutamac sizintisi
      arama/yeniden acilis maliyeti burada gorunur)
    - her 20 turda zorunlu checkpoint

  SURE: VDB_SOAK_SECONDS ortam degiskeni (varsayilan 25 sn). Uzun kosu
  (1 saat / 6 saat / 24 saat) icin ayni ikili `VDB_SOAK_SECONDS=3600`
  ile kosulur; burada varsayilan kisa tutulur ki normal kapi takiminda
  kalsin. NE KOSULDUGU rapora yazilir; kosulmayan sure "kosuldu" denmez.

  OLCUM ALETLERI (durust sinirlar):
    - yigin_delta_kb = GetHeapStatus.TotalAllocated deltasi; RSS DEGILDIR.
      Ayirici bos bloklari yeniden kullandigi icin dalgalanir; bu yuzden
      "ilk pencere ortalamasi" ile "son pencere ortalamasi" karsilastirilir.
    - Windows'ta FD yerine SUREC TUTAMAC (handle) sayisi olculur
      (GetProcessHandleCount); dosya tutamaclari bunun bir alt kumesidir,
      yani sayi FD'den buyuk olabilir ama buyume sinyali aynidir.
      Linux'ta /proc/self/fd girdileri sayilir.
    - Is parcacigi: Linux /proc/self/status "Threads:", Windows
      CreateToolhelp32Snapshot + Thread32First/Next.
    - Gecikme: tur basina duvar saati (GetTickCount64) milisaniye; p50/p95
      ayri raporlanir. Bu bir verimlilik iddiasi degil, soak boyunca
      BOZULMA olup olmadiginin olcumudur.
    - Bu kapi GOMULU motordur; ag sunucusu (TVdbPgServer) soak'i ayri bir
      is kalemidir ve burada kosulmaz. Cokme/kurtarma yollari `wal_crash`,
      `crash_points` ve `page_corrupt` kapilarinda olculur; burada cokme
      simule EDILMEZ.

  F-22 REGRESYONU (SO16/SO17): soak, F-22'nin ortaya ciktigi yerdir. Hata
  serbest listedeki bir sayfanin yeniden acilis sonrasi bos bir heap sayfasi
  sanilip icine satir yazilmasi, sonra da AllocPage'in o sayfayi PageInit ile
  sifirlamasiydi. Bu yuzden her checkpoint ve her yeniden acilis sonrasi UC
  sayim yolu karsilastirilir: hizli COUNT(*), sayfa taramasi (WHERE id > 0)
  ve COUNT(DISTINCT id). Ucu de 2000 degilse SO16/SO17 basarisiz olur.

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Generics.Collections,
  VDbBackendV3, VDbPageEngine, VDbTable, VDbSql, VDbPageStore;

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
  BATCH = 100;
  LIVE_ROWS = 2000;
  DEF_SECONDS = 25;
  REOPEN_EVERY = 15;
  CHECKPOINT_EVERY = 20;

var
  GDir, GDb: string;
  GPass, GFail: Integer;
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
  Flush(Output);
end;

procedure Wipe(const D: string);
var
  sr: TSearchRec;
  d2: string;
begin
  d2 := IncludeTrailingPathDelimiter(D);
  ForceDirectories(d2);
  if FindFirst(d2 + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(d2 + sr.Name);
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

{ Dizindeki butun dosyalarin toplam boyu (db + wal + idx + gen). }
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
      if (sr.Name <> '.') and (sr.Name <> '..') and
         ((sr.Attr and faDirectory) = 0) then
        Inc(Result, Int64(sr.Size));
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function HeapKB: Int64;
var
  h: THeapStatus;
begin
  h := GetHeapStatus;
  Result := Int64(h.TotalAllocated) div 1024;
end;

function Ticks: Int64;
begin
  Result := GetTickCount64;
end;

{ --- isletim sistemi olcumleri ------------------------------------------ }

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

procedure OpenDb(const APath, ADir: string);
begin
  Be := TVdbBackendV3.Create(APath);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(ADir);
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

function StrQ(const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '<yok>';
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := Trim(r.Rows[0][0]);
end;

{ F-22 REGRESYONU: ayni veri kumesi UC yoldan ayni sayiyi vermeli.
  F-22'de hizli COUNT(*) (backend sayaci) 2000 derken sayfa taramasi 1896
  goruyordu; serbest listedeki bir sayfa yeniden tahsis edilip PageInit ile
  sifirlaniyor, satirlar sessizce kayboluyordu. Bu kontrol uc yolun
  ayristigi ani yakalar. }
function CountsAgree(out Fast, Scan, Dist: Int64): Boolean;
begin
  Fast := IntQ('SELECT COUNT(*) FROM t');
  Scan := IntQ('SELECT COUNT(*) FROM t WHERE id > 0');
  Dist := IntQ('SELECT COUNT(DISTINCT id) FROM t');
  Result := (Fast = LIVE_ROWS) and (Scan = LIVE_ROWS) and (Dist = LIVE_ROWS);
end;

function CountsText(Fast, Scan, Dist: Int64): string;
begin
  Result := 'hizli=' + IntToStr(Fast) + ' tarama=' + IntToStr(Scan) +
            ' distinct=' + IntToStr(Dist);
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

{ --- istatistik yardimcilari -------------------------------------------- }

type
  TInts = array of Int64;

function MeanOf(const A: TInts; AFrom, ATo: Integer): Double;
var
  i: Integer;
begin
  Result := 0;
  if ATo < AFrom then Exit;
  for i := AFrom to ATo do Result := Result + A[i];
  Result := Result / (ATo - AFrom + 1);
end;

procedure Percentiles(const A: TInts; out AP50, AP95, AMax: Int64);
var
  L: TList<Int64>;
  i: Integer;
begin
  AP50 := 0; AP95 := 0; AMax := 0;
  if Length(A) = 0 then Exit;
  L := TList<Int64>.Create;
  try
    for i := 0 to High(A) do L.Add(A[i]);
    L.Sort;
    AP50 := L[L.Count div 2];
    AP95 := L[(L.Count * 95) div 100];
    AMax := L[L.Count - 1];
  finally
    L.Free;
  end;
end;

var
  GSeconds: Integer;
  GCpEvery, GReopenEvery: Integer;

function EnvInt(const AName: string; ADef: Integer): Integer;
var
  s: string;
begin
  s := Trim(GetEnvironmentVariable(AName));
  Result := StrToIntDef(s, ADef);
end;

function DesiredSeconds: Integer;
var
  s: string;
begin
  s := Trim(GetEnvironmentVariable('VDB_SOAK_SECONDS'));
  Result := StrToIntDef(s, DEF_SECONDS);
  if Result < 5 then Result := 5;
  if Result > 86400 then Result := 86400;
end;

{ --- ana senaryo -------------------------------------------------------- }

procedure RunDirSaturation;
const
  { F-21 regresyonu: kucuk canli kume + kucuk parti secilir ki dizin
    (hash tablosu) kisa surede mezar taslariyla doysun. Eski kodda bu faz
    ~15. turda 'toplu yazim basarisiz' ile dusuyordu (Insert sessizce False
    donuyordu). Canli 200 + 20'lik parti ile 256/512 yuvalik tablo hizlica
    doyar; 40 tur fazlasiyla yeterli. }
  SAT_LIVE  = 200;
  SAT_BATCH = 20;
  SAT_TURNS = 40;
var
  seed, nextId, delBase, tid, cnt: Int64;
  it, firstErr, errs: Integer;
  path: string;
begin
  path := GDir + 'sat.odb';
  WriteLn('--- F-21 dizin doygunlugu fazi: canli=', SAT_LIVE,
          ' parti=', SAT_BATCH, ' tur=', SAT_TURNS, ' (yeniden acilis YOK) ---');
  Flush(Output);
  OpenDb(path, GDir);
  try
    Sq.Exec('CREATE TABLE s (id INTEGER PRIMARY KEY, v TEXT)');
    nextId := 1;
    while nextId <= SAT_LIVE do
    begin
      Sq.Exec('BEGIN');
      tid := nextId;
      while tid <= nextId + SAT_BATCH - 1 do
      begin
        Sq.Exec('INSERT INTO s (id, v) VALUES (' + IntToStr(tid) +
                ', ''s' + IntToStr(tid) + ''')');
        Inc(tid);
      end;
      Sq.Exec('COMMIT');
      Inc(nextId, SAT_BATCH);
    end;
    Chk('SO15a dizin doygunlugu isinma satiri',
        IntQ('SELECT COUNT(*) FROM s') = SAT_LIVE,
        'sayi=' + IntToStr(IntQ('SELECT COUNT(*) FROM s')));
    delBase := 1;
    errs := 0;
    firstErr := 0;
    for it := 1 to SAT_TURNS do
    begin
      try
        Sq.Exec('BEGIN');
        tid := nextId;
        while tid <= nextId + SAT_BATCH - 1 do
        begin
          Sq.Exec('INSERT INTO s (id, v) VALUES (' + IntToStr(tid) +
                  ', ''s' + IntToStr(tid) + ''')');
          Inc(tid);
        end;
        Inc(nextId, SAT_BATCH);
        tid := delBase;
        while tid <= delBase + SAT_BATCH - 1 do
        begin
          Sq.Exec('DELETE FROM s WHERE id = ' + IntToStr(tid));
          Inc(tid);
        end;
        Inc(delBase, SAT_BATCH);
        Sq.Exec('COMMIT');
        cnt := IntQ('SELECT COUNT(*) FROM s');
        if cnt <> SAT_LIVE then
        begin
          Inc(errs);
          if firstErr = 0 then firstErr := it;
          WriteLn('HATA doygunluk tur ', it, ': canli satir ', cnt,
                  ' (beklenen ', SAT_LIVE, ')');
        end;
      except
        on E: Exception do
        begin
          Inc(errs);
          if firstErr = 0 then firstErr := it;
          WriteLn('HATA doygunluk tur ', it, ': ', E.ClassName, ': ', E.Message);
          { F-21 sonrasi: kirli islem kalirsa sonraki turlar zincirleme
            duser; burada islemi geri al. }
          try
            Sq.Exec('ROLLBACK');
          except
          end;
        end;
      end;
    end;
    Chk('SO15b dizin doygunlugunda hata yok', errs = 0,
        'hata=' + IntToStr(errs) + ' ilk_tur=' + IntToStr(firstErr));
    Chk('SO15c dizin doygunlugu sonrasi canli satir',
        IntQ('SELECT COUNT(*) FROM s') = SAT_LIVE,
        'sayi=' + IntToStr(IntQ('SELECT COUNT(*) FROM s')));
    { Doygunluk fazinin verisi de kalici olmali: kapat, dogrula, tekrar ac. }
    CloseDb;
    OpenDb(path, GDir);
    Chk('SO15d doygunluk fazi yeniden acilista okunuyor',
        IntQ('SELECT COUNT(*) FROM s') = SAT_LIVE,
        'sayi=' + IntToStr(IntQ('SELECT COUNT(*) FROM s')));
  finally
    if Sq <> nil then CloseDb;
  end;
  WriteLn('OLCUM SO15 doygunluk: canli=', SAT_LIVE, ' parti=', SAT_BATCH,
          ' tur=', SAT_TURNS, ' hata=', IntToStr(errs));
  Flush(Output);
end;

procedure RunSoak;
var
  heapS, fdS, thrS, walS, dbS: TInts;
  latS: TInts;
  seed, nextId, delBase, it, i, rnd, tid, nSamples: Int64;
  t0, tEnd, turT0: Int64;
  cnt, liveCnt: Int64;
  errs: Integer;
  walMax, heapFirst, heapLast, fdFirst, fdLast: Double;
  walMaxLimit: Int64;
  thrFirst, thrLast, dbFirst, dbLast, totalBytes: Double;
  p50, p95, latMax: Int64;
  rep, detail: string;
  ok: Boolean;
  iterCount, reopenCount, cpCount: Integer;
  cpMismatch, reopenMismatch: Integer;
  cFast, cScan, cDist: Int64;
  lastWal, maxWalSeen, maxTotalSeen: Int64;
begin
  WriteLn('SOAK baslangic: sure=', GSeconds, ' sn, BATCH=', BATCH,
          ', canli satir hedefi=', LIVE_ROWS,
          ', yeniden acilis her ', GReopenEvery,
          ' tur, checkpoint her ', GCpEvery, ' tur');
  Flush(Output);

  OpenDb(GDb, GDir);
  try
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, n INTEGER)');
    { isinma: 2000 satir }
    seed := 2463534242;
    nextId := 1;
    i := 0;
    while i < LIVE_ROWS do
    begin
      Sq.Exec('BEGIN');
      tid := nextId;
      while tid <= nextId + BATCH - 1 do
      begin
        Sq.Exec('INSERT INTO t (id, v, n) VALUES (' + IntToStr(tid) +
                ', ''v' + IntToStr(tid) + ''', 0)');
        Inc(tid);
      end;
      Sq.Exec('COMMIT');
      Inc(nextId, BATCH);
      Inc(i, BATCH);
    end;
    delBase := 1;
    liveCnt := IntQ('SELECT COUNT(*) FROM t');
    Chk('SO1 isinma sonrasi canli satir', liveCnt = LIVE_ROWS,
        'sayi=' + IntToStr(liveCnt));
    Be.Engine.Checkpoint(True);

    SetLength(heapS, 0); SetLength(fdS, 0); SetLength(thrS, 0);
    SetLength(walS, 0); SetLength(dbS, 0); SetLength(latS, 0);
    maxWalSeen := 0; maxTotalSeen := 0;
    errs := 0; it := 0; reopenCount := 0; cpCount := 0;
    cpMismatch := 0; reopenMismatch := 0;
    walMaxLimit := Be.Engine.WalMaxBytes;

    t0 := Ticks;
    tEnd := t0 + Int64(GSeconds) * 1000;

    while Ticks < tEnd do
    begin
      turT0 := Ticks;
      Inc(it);
      try
        { 1) BATCH yeni satir }
        Sq.Exec('BEGIN');
        tid := nextId;
        while tid <= nextId + BATCH - 1 do
        begin
          Sq.Exec('INSERT INTO t (id, v, n) VALUES (' + IntToStr(tid) +
                  ', ''v' + IntToStr(tid) + ''', 0)');
          Inc(tid);
        end;
        Inc(nextId, BATCH);

        { 2) en eski BATCH satiri sil (canli sayi sabit kalir) }
        tid := delBase;
        while tid <= delBase + BATCH - 1 do
        begin
          Sq.Exec('DELETE FROM t WHERE id = ' + IntToStr(tid));
          Inc(tid);
        end;
        Inc(delBase, BATCH);

        { 3) rastgele bir guncelleme }
        seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
        rnd := (seed shr 8) mod (nextId - 1) + 1;
        Sq.Exec('UPDATE t SET n = n + 1 WHERE id = ' + IntToStr(rnd));
        Sq.Exec('COMMIT');

        { 4) her turda bir dogrulama okumasi (indekssiz tarama) }
        cnt := IntQ('SELECT COUNT(*) FROM t');
        if cnt <> LIVE_ROWS then
        begin
          Inc(errs);
          WriteLn('HATA tur ', it, ': canli satir ', cnt, ' (beklenen ', LIVE_ROWS, ')');
        end;
      except
        on E: Exception do
        begin
          Inc(errs);
          WriteLn('HATA tur ', it, ': ', E.ClassName, ': ', E.Message);
          { F-21: basarisiz turdan sonra acik islem kalirsa sonraki turlar
            zincirleme duser; islemi geri al. }
          try
            Sq.Exec('ROLLBACK');
          except
          end;
        end;
      end;

      { 5) ornekleme }
      SetLength(heapS, Length(heapS) + 1); heapS[High(heapS)] := HeapKB;
      SetLength(fdS, Length(fdS) + 1);     fdS[High(fdS)] := FDCount;
      SetLength(thrS, Length(thrS) + 1);   thrS[High(thrS)] := ThreadCount;
      lastWal := FileSizeOf(GDb + '.wal');
      if lastWal < 0 then lastWal := 0;
      if lastWal > maxWalSeen then maxWalSeen := lastWal;
      SetLength(walS, Length(walS) + 1);   walS[High(walS)] := lastWal;
      totalBytes := DirBytes(GDir);
      if totalBytes > maxTotalSeen then maxTotalSeen := Trunc(totalBytes);
      SetLength(dbS, Length(dbS) + 1);     dbS[High(dbS)] := Trunc(totalBytes);
      SetLength(latS, Length(latS) + 1);   latS[High(latS)] := Ticks - turT0;

      { 6) periyodik checkpoint }
      if (GCpEvery > 0) and ((it mod GCpEvery) = 0) then
      begin
        Inc(cpCount);
        try
          Be.Engine.Checkpoint(True);
        except
          on E: Exception do
          begin
            Inc(errs);
            WriteLn('HATA checkpoint: ', E.Message);
          end;
        end;
        { F-22: checkpoint sonrasi uc sayim yolu ayni olmali. }
        if not CountsAgree(cFast, cScan, cDist) then
        begin
          Inc(errs);
          Inc(cpMismatch);
          WriteLn('HATA checkpoint sayim tur ', it, ': ',
                  CountsText(cFast, cScan, cDist));
        end;
      end;

      { 7) periyodik kapat/ac: tutamac sizintisini gorunur kilar }
      if (GReopenEvery > 0) and ((it mod GReopenEvery) = 0) then
      begin
        Inc(reopenCount);
        try
          CloseDb;
          OpenDb(GDb, GDir);
          cnt := IntQ('SELECT COUNT(*) FROM t');
          if cnt <> LIVE_ROWS then
          begin
            Inc(errs);
            WriteLn('HATA yeniden acilis ', reopenCount, ': satir ', cnt);
          end;
          { F-22: yeniden acilis sonrasi da uc sayim yolu ayni olmali.
            F-22'nin kaybi tam bu noktada gorunur hale geliyordu. }
          if not CountsAgree(cFast, cScan, cDist) then
          begin
            Inc(errs);
            Inc(reopenMismatch);
            WriteLn('HATA yeniden acilis sayim ', reopenCount, ': ',
                    CountsText(cFast, cScan, cDist));
          end;
        except
          on E: Exception do
          begin
            Inc(errs);
            WriteLn('HATA yeniden acilis: ', E.Message);
          end;
        end;
      end;

      if (it mod 50) = 0 then
      begin
        WriteLn('... tur=', it, ' gecen=', (Ticks - t0) div 1000, ' sn',
                ' yigin_kb=', HeapKB, ' tutamac=', FDCount,
                ' thread=', ThreadCount, ' wal_bayt=', lastWal,
                ' toplam_bayt=', Int64(totalBytes));
        Flush(Output);
      end;
    end;

    { son durum }
    cnt := IntQ('SELECT COUNT(*) FROM t');
    Chk('SO2 soak sonrasi canli satir sabit', cnt = LIVE_ROWS,
        'sayi=' + IntToStr(cnt) + ' tur=' + IntToStr(it));
    Chk('SO3 is yuku hatasiz', errs = 0, 'hata=' + IntToStr(errs));
    { F-22 regresyonu: ayri adli kontroller, boylece regresyon sessizce
      SO3'un icinde kaybolmaz. }
    Chk('SO16 checkpoint sonrasi uc sayim tutarli', cpMismatch = 0,
        'uyusmazlik=' + IntToStr(cpMismatch) + ' checkpoint=' + IntToStr(cpCount));
    Chk('SO17 yeniden acilis sonrasi uc sayim tutarli', reopenMismatch = 0,
        'uyusmazlik=' + IntToStr(reopenMismatch) + ' acilis=' + IntToStr(reopenCount));

    { son checkpoint + kapat }
    Be.Engine.Checkpoint(True);
    CloseDb;

    nSamples := Length(heapS);
    Chk('SO4 yeterli ornek toplandi', nSamples >= 5,
        'ornek=' + IntToStr(nSamples) + ' tur=' + IntToStr(it));

    if nSamples >= 5 then
    begin
      heapFirst := MeanOf(heapS, 0, nSamples div 5);
      heapLast := MeanOf(heapS, nSamples - 1 - nSamples div 5, nSamples - 1);
      fdFirst := MeanOf(fdS, 0, nSamples div 5);
      fdLast := MeanOf(fdS, nSamples - 1 - nSamples div 5, nSamples - 1);
      thrFirst := MeanOf(thrS, 0, nSamples div 5);
      thrLast := MeanOf(thrS, nSamples - 1 - nSamples div 5, nSamples - 1);
      dbFirst := MeanOf(dbS, 0, nSamples div 5);
      dbLast := MeanOf(dbS, nSamples - 1 - nSamples div 5, nSamples - 1);

      { SO5: yigin surekli buyumemeli. Esik 8 MB: dalgalanma serbest,
        tek yonlu buyume degil. }
      Chk('SO5 yigin surekli buyumuyor',
          heapLast - heapFirst <= 8192,
          'ilk_ort_kb=' + FloatToStrF(heapFirst, ffFixed, 12, 0) +
          ' son_ort_kb=' + FloatToStrF(heapLast, ffFixed, 12, 0) +
          ' fark_kb=' + FloatToStrF(heapLast - heapFirst, ffFixed, 12, 0));

      { SO6: tutamac sayisi buyumemeli (yeniden acilis dongusu dahil). }
      Chk('SO6 tutamac/FD sayisi buyumuyor',
          fdLast - fdFirst <= 4,
          'ilk_ort=' + FloatToStrF(fdFirst, ffFixed, 12, 0) +
          ' son_ort=' + FloatToStrF(fdLast, ffFixed, 12, 0) +
          ' fark=' + FloatToStrF(fdLast - fdFirst, ffFixed, 12, 0));

      { SO7: is parcacigi sayisi buyumemeli. }
      Chk('SO7 is parcacigi sayisi buyumuyor',
          thrLast - thrFirst <= 2,
          'ilk_ort=' + FloatToStrF(thrFirst, ffFixed, 12, 0) +
          ' son_ort=' + FloatToStrF(thrLast, ffFixed, 12, 0) +
          ' fark=' + FloatToStrF(thrLast - thrFirst, ffFixed, 12, 0));

      { SO8: sabit calisma kumesinde dosya boyu buyumemeli. Esik 8 MB. }
      Chk('SO8 sabit yukte dosya boyu buyumuyor',
          dbLast - dbFirst <= 8 * 1024 * 1024,
          'ilk_ort_bayt=' + FloatToStrF(dbFirst, ffFixed, 15, 0) +
          ' son_ort_bayt=' + FloatToStrF(dbLast, ffFixed, 15, 0) +
          ' fark_bayt=' + FloatToStrF(dbLast - dbFirst, ffFixed, 15, 0));

      Percentiles(latS, p50, p95, latMax);
      WriteLn('OLCUM sure_sn=', GSeconds, ' tur=', it, ' ornek=', nSamples,
              ' islem~=', it * (BATCH * 2 + 2),
              ' yeniden_acilis=', reopenCount, ' checkpoint=', cpCount);
      WriteLn('OLCUM yigin_kb ilk_ort=', FloatToStrF(heapFirst, ffFixed, 12, 0),
              ' son_ort=', FloatToStrF(heapLast, ffFixed, 12, 0),
              ' son_ornek=', heapS[nSamples - 1]);
      WriteLn('OLCUM tutamac ilk_ort=', FloatToStrF(fdFirst, ffFixed, 12, 0),
              ' son_ort=', FloatToStrF(fdLast, ffFixed, 12, 0),
              ' max=', IntToStr(Int64(Trunc(MeanOf(fdS, 0, nSamples - 1)))));
      WriteLn('OLCUM thread ilk_ort=', FloatToStrF(thrFirst, ffFixed, 12, 0),
              ' son_ort=', FloatToStrF(thrLast, ffFixed, 12, 0));
      WriteLn('OLCUM wal_bayt max_gorulen=', maxWalSeen,
              ' tavan=', walMaxLimit);
      WriteLn('OLCUM dosya_bayt ilk_ort=', FloatToStrF(dbFirst, ffFixed, 15, 0),
              ' son_ort=', FloatToStrF(dbLast, ffFixed, 15, 0),
              ' max_gorulen=', maxTotalSeen,
              ' son=', Int64(DirBytes(GDir)),
              ' canli_satir_basina_bayt~',
              Int64(DirBytes(GDir)) div LIVE_ROWS);
      WriteLn('OLCUM gecikme_ms p50=', p50, ' p95=', p95, ' max=', latMax);
      WriteLn('OLCUM hata=', errs);
      Flush(Output);

      { SO9: gecikme p95 makul kalmali (kayit amacli; soak bozulmasi). }
      Chk('SO9 tur gecikmesi p95 siniri', p95 <= 20000,
          'p50=' + IntToStr(p50) + 'ms p95=' + IntToStr(p95) + 'ms');

      { SO10: WAL sert tavani asilmamis olmali. }
      Chk('SO10 WAL sert tavani asilmadi', maxWalSeen <= walMaxLimit,
          'max=' + IntToStr(maxWalSeen) + ' tavan=' + IntToStr(walMaxLimit));
    end
    else
    begin
      Chk('SO5 yigin surekli buyumuyor', False, 'ornek yetersiz');
      Chk('SO6 tutamac/FD sayisi buyumuyor', False, 'ornek yetersiz');
      Chk('SO7 is parcacigi sayisi buyumuyor', False, 'ornek yetersiz');
      Chk('SO8 sabit yukte dosya boyu buyumuyor', False, 'ornek yetersiz');
      Chk('SO9 tur gecikmesi p95 siniri', False, 'ornek yetersiz');
      Chk('SO10 WAL sert tavani asilmadi', False, 'ornek yetersiz');
    end;

    { SO11: kapanis sonrasi tam VERIFY temiz olmali. }
    ok := VerifyDb(GDb, rep);
    Chk('SO11 soak sonrasi tam VERIFY', ok, rep);

    { SO12: yeniden acilista veri durmali ve dogru okunmali. }
    try
      OpenDb(GDb, GDir);
      liveCnt := IntQ('SELECT COUNT(*) FROM t');
      detail := 'sayi=' + IntToStr(liveCnt);
      Chk('SO12 yeniden acilis sonrasi satir sayisi', liveCnt = LIVE_ROWS, detail);
      detail := StrQ('SELECT v FROM t WHERE id = ' + IntToStr(nextId - 1));
      Chk('SO13 son eklenen satir okunabiliyor',
          detail = 'v' + IntToStr(nextId - 1), 'v=' + detail);
      CloseDb;
    except
      on E: Exception do
      begin
        Chk('SO12 yeniden acilis sonrasi satir sayisi', False, E.Message);
        Chk('SO13 son eklenen satir okunabiliyor', False, E.Message);
        CloseDb;
      end;
    end;

    { SO14: kayitli sayilari tek satirda ozetle (rapora dogrudan gecer). }
    WriteLn('OLCUM ozet: tur=', it, ' ornek=', nSamples,
            ' canli_satir=', LIVE_ROWS,
            ' dosya_son_bayt=', Int64(DirBytes(GDir)),
            ' wal_max_bayt=', maxWalSeen,
            ' hata=', errs);
    Chk('SO14 soak bir butun olarak tamamlandi', it > 0);
    Flush(Output);
  finally
    if Sq <> nil then CloseDb;
  end;
end;

begin
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/soak');
  GDb := GDir + 'soak.odb';
  GSeconds := DesiredSeconds;
  GCpEvery := EnvInt('VDB_SOAK_CP', CHECKPOINT_EVERY);
  GReopenEvery := EnvInt('VDB_SOAK_REOPEN', REOPEN_EVERY);
  GPass := 0;
  GFail := 0;

  WriteLn('--- soak (gomulu motor, ayri ag sunucusu soak''i degil) ---');
  Wipe(GDir);
  try
    RunDirSaturation;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL BEKLENMEYEN ISTISNA (doygunluk): ', E.ClassName, ': ', E.Message);
    end;
  end;
  try
    RunSoak;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL BEKLENMEYEN ISTISNA: ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  ExitCode := GFail;
end.
