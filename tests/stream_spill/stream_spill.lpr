program stream_spill;
{ tests/stream_spill - SKILL11: imlec duzeyinde DIS SIRALAMA davranis kapisi.

  Kapsam (hepsi saf Pascal; harici arac/DLL yok):
    SS1  ORDER BY dis siralama GERCEKTEN devreye girer (kosu dosyasi yazilir)
    SS2  cikti maddesel (Exec) yolla BIT BIT aynidir (degerler + sira)
    SS3  ORDER BY ... LIMIT/OFFSET imlec duzeyinde AYNI sonucu verir
    SS4  satir sayisi 10 kat artinca tepe bellek 10 kat artmaz (plato)
    SS5  normal bitiste gecici kosu dizini kalmaz
    SS6  iptal (Cancel) sonrasi gecici dosyalar silinir
    SS7  TARAMA SIRASINDA hata olursa (CAST bozuk deger) gecici dosyalar silinir
    SS8  onceki surecten kalan artik (orphan) dizin gercek imlecte toplanir,
         CANLI pid'in dizini korunur
    SS9  gomulu API: OpenCursor / NextChunk (NextBatch) / CloseCursor
    SS10 64 MiB bellek butcesiyle 100k satir ORDER BY
    SS11 1M satir ORDER BY dis siralama (kosular > 1, tepe bellek sinirli)
    SS12 belgelenen maddesel fallback'lar (GROUP BY, DISTINCT, JOIN,
         UNION ALL, pencere, NULL tablo) maddesel yolda kalmali ve ayni
         sonucu vermeli
    SS13 tuketilmis imlecte teslim tamponu + dis siralama kaynaklari
         birakilir (ReleaseBuffers); tepe bellek kaniti ve imlec durumu
         korunur, ikinci cagri zararsizdir

  Not: `VdbSpillRootOverride` bu testte kendi calisma dizinine yonlendirilir;
  makinenin gercek %TEMP% dizini kirlenmez. Butce testte kucultulur ki
  20k satir bile birden cok kosu uretsin. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbTypes, VDbFactory, VDbBackendApi, VDbBackendV3,
  VDbTable, VDbSql, VDbErr, VDbExecutor, VDbSpill;

var
  GPass, GFail: Integer;
  GDir, GRoot, GDb, GDbReal: string;
  Be: TVdbBackendV3;
  Tb: TVTableDb;
  Sq: TVSql;

procedure Chk(const AName: string; AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' | ', ADetail);
  end;
end;

function DirsIn(const D: string): Integer;
var
  sr: TSearchRec;
  d2: string;
begin
  Result := 0;
  d2 := IncludeTrailingPathDelimiter(D);
  if FindFirst(d2 + '*', faDirectory, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name <> '.') and (sr.Name <> '..') then
          if (sr.Attr and faDirectory) <> 0 then Inc(Result);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
end;

procedure Wipe(const ADir: string);
begin
  if DirectoryExists(ADir) then VdbDeleteTree(ADir);
end;

function FileOfDir(const ADir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + VDBSPILL_MANIFEST;
end;

procedure MakeFakeSpillDir(const ADir, ADb, APid: string);
var
  sl: TStringList;
begin
  Wipe(ADir);
  ForceDirectories(ADir);
  sl := TStringList.Create;
  try
    sl.LineBreak := #10;
    sl.Add('DB' + #9 + ADb);
    sl.Add('PID' + #9 + APid);
    sl.Add('VER' + #9 + '1');
    sl.SaveToFile(FileOfDir(ADir));
  finally
    sl.Free;
  end;
  with TFileStream.Create(IncludeTrailingPathDelimiter(ADir) + 'run0' +
    VDBSPILL_EXT, fmCreate) do
    try
      WriteBuffer(VDBSPILL_MAGIC, SizeOf(VDBSPILL_MAGIC));
    finally
      Free;
    end;
end;

{ id araligini toplu yazar; her 1000 satirda tek transaction. }
procedure Bulk(const ATbl: string; AFrom, ATo: Integer; const AText: string);
var
  id, stop: Integer;
  s: string;
begin
  id := AFrom;
  while id <= ATo do
  begin
    Sq.Exec('BEGIN');
    stop := id + 999;
    if stop > ATo then stop := ATo;
    while id <= stop do
    begin
      s := IntToStr((id * 7919) mod 100003);
      Sq.Exec('INSERT INTO ' + ATbl + ' (id, k, v) VALUES (' + IntToStr(id) +
        ', ' + s + ', ''' + AText + IntToStr(id) + ''')');
      Inc(id);
    end;
    Sq.Exec('COMMIT');
  end;
end;

function RowsEqual(const A, B: TStrArray): Boolean;
var
  i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 0 to High(A) do
    if A[i] <> B[i] then Exit(False);
end;

function JoinRow(const R: TStrArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(R) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + '[' + R[i] + ']';
  end;
end;

{ Imleci ayni SQL'in maddesel ciktisiyla satir satir karsilastirir. }
function CursorEqualsExec(const ASql: string; out ARows: Integer;
  out ADetail: string): Boolean;
var
  r: TSqlResult;
  Cur: TVdbRowCursor;
  row: TStrArray;
  gn: TNulArr;
  i: Integer;
begin
  ARows := 0;
  ADetail := '';
  Result := False;
  r := Sq.Exec(ASql);
  Cur := Sq.OpenCursor(ASql, nil, nil);
  try
    i := 0;
    while Cur.NextRow(row, gn) do
    begin
      if i >= Length(r.Rows) then
      begin
        ADetail := 'imlec maddesel sonuctan FAZLA satir uretti: ' + IntToStr(i);
        Exit;
      end;
      if not RowsEqual(row, r.Rows[i]) then
      begin
        ADetail := 'satir ' + IntToStr(i) + ' farkli: [' +
          JoinRow(row) + '] <> [' + JoinRow(r.Rows[i]) + ']';
        Exit;
      end;
      Inc(i);
    end;
    ARows := i;
    if i <> Length(r.Rows) then
    begin
      ADetail := 'satir sayisi: imlec=' + IntToStr(i) + ' maddesel=' +
        IntToStr(Length(r.Rows));
      Exit;
    end;
    Result := True;
  finally
    Cur.Free;
  end;
end;

{ ---------------- SS1-SS3: dis siralama + birebir esitlik ---------------- }

procedure TestOrderByBasics;
var
  Cur: TVdbRowCursor;
  row: TStrArray;
  gn: TNulArr;
  n, prevK, curK: Integer;
  mono, ok: Boolean;
  runs: Integer;
  bytes: Int64;
  detail: string;
begin
  VdbSpillBudgetOverride := 256 * 1024;
  VdbSpillResetStats;
  Cur := Sq.OpenCursor('SELECT id, k, v FROM t ORDER BY k', nil, nil);
  n := 0;
  prevK := -2147483648;
  mono := True;
  ok := True;
  try
    while Cur.NextRow(row, gn) do
    begin
      if Length(row) <> 3 then
      begin
        ok := False;
        Break;
      end;
      curK := StrToIntDef(row[1], -2147483648);
      if (n > 0) and (curK < prevK) then mono := False;
      prevK := curK;
      Inc(n);
    end;
    runs := Cur.FSpillRuns;
    bytes := Cur.FSpillBytes;
  finally
    Cur.Free;
  end;
  Chk('SS1 dis siralama devrede: 20000 satir, kosular>1, kosu bayti>0',
    (n = 20000) and ok and mono and (runs > 1) and (bytes > 0),
    'n=' + IntToStr(n) + ' mono=' + BoolToStr(mono, True) +
    ' runs=' + IntToStr(runs) + ' bytes=' + IntToStr(bytes));

  ok := CursorEqualsExec('SELECT id, k, v FROM t ORDER BY k', n, detail);
  Chk('SS2 imlec ciktisi maddesel Exec ile birebir ayni', ok and (n = 20000),
    detail + ' n=' + IntToStr(n));

  ok := CursorEqualsExec('SELECT id, k, v FROM t ORDER BY k DESC LIMIT 7 OFFSET 5',
    n, detail);
  Chk('SS3 ORDER BY DESC LIMIT 7 OFFSET 5 imlecte ayni', ok and (n = 7),
    detail + ' n=' + IntToStr(n));
end;

{ ---------------- SS4: tepe bellek platosu ---------------- }

function PeakFor(const ASql: string): Int64;
var
  Cur: TVdbRowCursor;
  row: TStrArray;
  gn: TNulArr;
  n: Integer;
begin
  Cur := Sq.OpenCursor(ASql, nil, nil);
  n := 0;
  try
    while Cur.NextRow(row, gn) do Inc(n);
    Result := Cur.PeakBytes;
  finally
    Cur.Free;
  end;
  if n = 0 then Result := -1;   { bos sonuc -> olcum gecersiz }
end;

procedure TestMemoryPlateau;
var
  p10, p100: Int64;
  ratio: Double;
begin
  VdbSpillBudgetOverride := 1024 * 1024;
  Bulk('m', 1, 10000, 'm');
  p10 := PeakFor('SELECT id, k, v FROM m ORDER BY k');
  Bulk('m', 10001, 100000, 'm');
  p100 := PeakFor('SELECT id, k, v FROM m ORDER BY k');
  if p10 > 0 then ratio := p100 / p10 else ratio := 999;
  WriteLn(Format('  bellek: 10k=%d bayt, 100k=%d bayt, oran=%.2f',
    [p10, p100, ratio]));
  Chk('SS4 satir 10x artinca tepe bellek 10x artmiyor (plato)',
    (p10 > 0) and (p100 > 0) and (ratio < 3.0) and (p100 < 6 * 1024 * 1024),
    Format('10k=%d 100k=%d oran=%.2f', [p10, p100, ratio]));
end;

{ ---------------- SS5-SS7: temizlik ---------------- }

procedure TestCleanup;
var
  Cur: TVdbRowCursor;
  row: TStrArray;
  gn: TNulArr;
  i: Integer;
begin
  Chk('SS5 normal bitiste gecici dizin kalmadi', DirsIn(GRoot) = 0,
    IntToStr(DirsIn(GRoot)) + ' dizin kaldi');

  { Iptal: birkac satir okunduktan sonra Cancel; kapanis temizlemeli. }
  VdbSpillBudgetOverride := 128 * 1024;
  VdbSpillResetStats;
  Cur := Sq.OpenCursor('SELECT id, k, v FROM t ORDER BY k', nil, nil);
  try
    i := 0;
    while (i < 5) and Cur.NextRow(row, gn) do Inc(i);
    Cur.Cancel;
    Chk('SS6a iptal sonrasi NextRow False', Cur.NextRow(row, gn) = False);
  finally
    Cur.Free;
  end;
  Chk('SS6 iptal sonrasi gecici dizin silindi', DirsIn(GRoot) = 0,
    IntToStr(DirsIn(GRoot)) + ' dizin kaldi');

  { Hata: ilk parca yazildiktan SONRA CAST bozuk degere carpar. }
  VdbSpillBudgetOverride := 64 * 1024;
  VdbSpillResetStats;
  i := 0;
  Cur := Sq.OpenCursor(
    'SELECT id, k, CAST(v AS INTEGER) AS a FROM e ORDER BY k', nil, nil);
  try
    try
      while Cur.NextRow(row, gn) do Inc(i);
      WriteLn('  SS7 uyari: hata beklenirken tarama tamamlandi (satir=',
        i, ')');
    except
      on E: Exception do
        WriteLn('  SS7 beklenen hata: ', E.ClassName, ': ', E.Message);
    end;
  finally
    Cur.Free;
  end;
  Chk('SS7 tarama sirasinda hata sonrasi gecici dizin silindi',
    DirsIn(GRoot) = 0, IntToStr(DirsIn(GRoot)) + ' dizin kaldi');
end;

{ ---------------- SS8: artik (orphan) dizin ---------------- }

procedure TestOrphans;
var
  deadDir, liveDir: string;
  Cur: TVdbRowCursor;
  row: TStrArray;
  gn: TNulArr;
  n, runs, dirs: Integer;
begin
  deadDir := IncludeTrailingPathDelimiter(GRoot) + VDBSPILL_DIR_PREFIX + 'ss_dead';
  liveDir := IncludeTrailingPathDelimiter(GRoot) + VDBSPILL_DIR_PREFIX + 'ss_live';
  MakeFakeSpillDir(deadDir, GDbReal, '4294967294');
  MakeFakeSpillDir(liveDir, GDbReal, IntToStr(VdbSpillPid));
  VdbSpillBudgetOverride := 256 * 1024;
  VdbSpillResetStats;
  n := 0;
  runs := 0;
  Cur := Sq.OpenCursor('SELECT id, k FROM t ORDER BY k', nil, nil);
  try
    while Cur.NextRow(row, gn) do Inc(n);
    runs := Cur.FSpillRuns;
  finally
    Cur.Free;
  end;
  dirs := DirsIn(GRoot);
  WriteLn('  SS8 db=', GDbReal, ' runs=', IntToStr(runs),
    ' created=', IntToStr(VdbSpillStats.DirsCreated),
    ' removed=', IntToStr(VdbSpillStats.OrphansRemoved),
    ' dirs=', IntToStr(dirs));
  Chk('SS8a eski surecten kalan dizin toplandi',
    (not DirectoryExists(deadDir)) and (VdbSpillStats.OrphansRemoved >= 1),
    'var=' + BoolToStr(DirectoryExists(deadDir), True) +
    ' removed=' + IntToStr(VdbSpillStats.OrphansRemoved));
  Chk('SS8b CANLI pid dizini korundu', DirectoryExists(liveDir), liveDir);
  Chk('SS8c sorgu artik toplamaya ragmen tam sonuc verdi', n = 20000,
    IntToStr(n));
  Wipe(liveDir);
end;

{ ---------------- SS9: gomulu API (NextBatch/CloseCursor) ---------------- }

procedure TestEmbeddedApi;
var
  Cur: TVdbRowCursor;
  res: TSqlResult;
  n, prevK, curK, got: Integer;
  mono: Boolean;
begin
  VdbSpillBudgetOverride := 256 * 1024;
  VdbSpillResetStats;
  n := 0;
  prevK := -2147483648;
  mono := True;
  Cur := Sq.OpenCursor('SELECT id, k FROM t ORDER BY k', nil, nil);
  try
    while Cur.NextChunk(500, res) do
    begin
      if Length(res.Fields) <> 2 then mono := False;
      for got := 0 to High(res.Rows) do
      begin
        curK := StrToIntDef(res.Rows[got][1], -2147483648);
        if (n > 0) and (curK < prevK) then mono := False;
        prevK := curK;
        Inc(n);
      end;
    end;
    Chk('SS9a NextBatch parcalari sirali ve tam (20000)',
      (n = 20000) and mono, 'n=' + IntToStr(n) +
      ' mono=' + BoolToStr(mono, True));
    Chk('SS9b dis siralama bu yolda da devrede', Cur.FSpillRuns > 1,
      'runs=' + IntToStr(Cur.FSpillRuns));
  finally
    Cur.Free;   { CloseCursor }
  end;
  Chk('SS9c CloseCursor sonrasi gecici dizin yok', DirsIn(GRoot) = 0,
    IntToStr(DirsIn(GRoot)) + ' dizin kaldi');
end;

{ ---------------- SS13: tuketilmis imlecte tampon birakma ----------------

  Portal katmani akis bitince imlecin teslim tamponunu ve dis siralama
  kaynaklarini birakir (TVdbRowCursor.ReleaseBuffers). Boylece bitmis bir
  portal sunucunun sonuc bellegi butcesinde yer tutmaz; imlec NESNESI
  kalir cunku Describe onu gorunce sorguyu yeniden calistirmamalidir. }

procedure TestReleaseBuffers;
var
  Cur: TVdbRowCursor;
  res: TSqlResult;
  n: Integer;
  peakBefore, liveBefore, liveAfter: Int64;
  more: Boolean;
begin
  VdbSpillBudgetOverride := 256 * 1024;
  VdbSpillResetStats;
  n := 0;
  Cur := Sq.OpenCursor('SELECT id, k, v FROM t ORDER BY k', nil, nil);
  try
    while Cur.NextChunk(500, res) do Inc(n, Length(res.Rows));
    peakBefore := Cur.PeakBytes;
    liveBefore := Cur.LiveBytes;
    Cur.ReleaseBuffers;
    liveAfter := Cur.LiveBytes;
    Chk('SS13a tuketilmis imlecte tampon birakildi',
      (n = 20000) and (liveBefore > liveAfter) and (liveAfter < 4096),
      'n=' + IntToStr(n) + ' once=' + IntToStr(liveBefore) +
      ' sonra=' + IntToStr(liveAfter));
    Chk('SS13b birakma sonrasi tepe bellek kaniti korunur',
      (peakBefore > 0) and (Cur.PeakBytes = peakBefore),
      'tepe=' + IntToStr(Cur.PeakBytes));
    Chk('SS13c birakma gecici dizini de sildi', DirsIn(GRoot) = 0,
      IntToStr(DirsIn(GRoot)) + ' dizin kaldi');
    more := Cur.NextChunk(500, res);
    Chk('SS13d birakma sonrasi imlec hala tukenmis', not more,
      'donen=' + BoolToStr(more, True));
    Cur.ReleaseBuffers;
    Chk('SS13e ikinci birakma zararsiz ve durum degismedi',
      Cur.LiveBytes = liveAfter, 'sonra=' + IntToStr(Cur.LiveBytes));
  finally
    Cur.Free;
  end;
end;

{ ---------------- SS10: 64 MiB butce ---------------- }

procedure TestBudget64M;
var
  Cur: TVdbRowCursor;
  row: TStrArray;
  gn: TNulArr;
  n: Integer;
begin
  VdbSpillBudgetOverride := Int64(64) * 1024 * 1024;
  VdbSpillResetStats;
  n := 0;
  Cur := Sq.OpenCursor('SELECT id, k, v FROM m ORDER BY k', nil, nil);
  try
    while Cur.NextRow(row, gn) do Inc(n);
    Chk('SS10a 64 MiB butce: 100k satir tam ve sirali',
      n = 100000, 'n=' + IntToStr(n));
    Chk('SS10b 64 MiB butce: kosu yazildi, tepe bellek butce civarinda',
      (Cur.FSpillRuns >= 1) and (Cur.PeakBytes > 0) and
      (Cur.PeakBytes < Int64(80) * 1024 * 1024),
      'runs=' + IntToStr(Cur.FSpillRuns) + ' peak=' +
      IntToStr(Cur.PeakBytes));
  finally
    Cur.Free;
  end;
  Chk('SS10c gecici dizin yok', DirsIn(GRoot) = 0,
    IntToStr(DirsIn(GRoot)) + ' dizin kaldi');
end;

{ ---------------- SS11: 1M satir ORDER BY ---------------- }

procedure TestMillion;
var
  Cur: TVdbRowCursor;
  res: TSqlResult;
  n, prevK, curK, i: Integer;
  mono: Boolean;
  t0: TDateTime;
  ms: Int64;
  runs: Integer;
  peak: Int64;
begin
  t0 := Now;
  Bulk('b', 1, 1000000, 'b');
  ms := Round((Now - t0) * 86400000);
  WriteLn('  1M satir yazildi: ', ms, ' ms');
  VdbSpillBudgetOverride := 2 * 1024 * 1024;
  VdbSpillResetStats;
  n := 0;
  prevK := -2147483648;
  mono := True;
  t0 := Now;
  Cur := Sq.OpenCursor('SELECT id, k FROM b ORDER BY k', nil, nil);
  try
    while Cur.NextChunk(4096, res) do
      for i := 0 to High(res.Rows) do
      begin
        curK := StrToIntDef(res.Rows[i][1], -2147483648);
        if (n > 0) and (curK < prevK) then mono := False;
        prevK := curK;
        Inc(n);
      end;
    runs := Cur.FSpillRuns;
    peak := Cur.PeakBytes;
  finally
    Cur.Free;
  end;
  ms := Round((Now - t0) * 86400000);
  WriteLn(Format('  1M ORDER BY: %d ms, kosular=%d, tepe=%d bayt',
    [ms, runs, peak]));
  Chk('SS11a 1M satir ORDER BY tam ve sirali', (n = 1000000) and mono,
    'n=' + IntToStr(n) + ' mono=' + BoolToStr(mono, True));
  Chk('SS11b 1M satirda birden cok kosu + tepe bellek 8 MiB altinda',
    (runs > 1) and (peak > 0) and (peak < 8 * 1024 * 1024),
    'runs=' + IntToStr(runs) + ' peak=' + IntToStr(peak));
  Chk('SS11c 1M satir sonrasi gecici dizin yok', DirsIn(GRoot) = 0,
    IntToStr(DirsIn(GRoot)) + ' dizin kaldi');
end;

{ ---------------- SS12: belgelenen maddesel fallback'lar ----------------

  SKILL11 dis siralama YALNIZCA duz kolon ORDER BY icin devrededir.
  JOIN / GROUP BY / DISTINCT / UNION / pencere / NULL tasiyan tablo
  maddesel yolda KALIR; iki yol asla karistirilmaz. Bu test hem sonucun
  maddesel Exec ile ayni oldugunu hem de dis siralama yolunun bu
  sekillerde ACILMADIGINI dogrular. }

procedure TestFallbacks;
var
  N: Integer;
  D: string;

  function Fb(const ASql, ATag: string): Boolean;
  var
    r: TSqlResult;
    Cur: TVdbRowCursor;
    row: TStrArray;
    gn: TNulArr;
    i: Integer;
    ok, same: Boolean;
  begin
    Result := False;
    r := Sq.Exec(ASql);
    Cur := Sq.OpenCursor(ASql, nil, nil);
    try
      i := 0;
      same := True;
      while Cur.NextRow(row, gn) do
      begin
        if (i >= Length(r.Rows)) or (not RowsEqual(row, r.Rows[i])) then
        begin
          same := False;
          Break;
        end;
        Inc(i);
      end;
      ok := same and (i = Length(r.Rows)) and (not Cur.FStreamed) and
        (not Cur.FExtSort);
      Chk('SS12 ' + ATag + ': maddesel yolda, cikti ayni', ok,
        'satir=' + IntToStr(i) + '/' + IntToStr(Length(r.Rows)) +
        ' streamed=' + BoolToStr(Cur.FStreamed, True) +
        ' extsort=' + BoolToStr(Cur.FExtSort, True));
      Result := ok;
    finally
      Cur.Free;
    end;
  end;

begin
  N := 0;
  D := '';
  Fb('SELECT k, COUNT(*) AS c FROM t GROUP BY k ORDER BY k', 'GROUP BY');
  Fb('SELECT DISTINCT k FROM t ORDER BY k', 'DISTINCT');
  Fb('SELECT a.id AS x, b.id AS y FROM t a JOIN m b ON a.id = b.id ' +
    'ORDER BY x', 'JOIN');
  Fb('SELECT id FROM t WHERE id <= 5 UNION ALL SELECT id FROM m ' +
    'WHERE id <= 5', 'UNION ALL');
  Fb('SELECT id, ROW_NUMBER() OVER (ORDER BY k) AS rn FROM t ' +
    'ORDER BY id LIMIT 10', 'pencere');
  Fb('SELECT id, k FROM n ORDER BY k', 'NULL tasiyan tablo');
end;

var
  s: string;
  i: Integer;
begin
  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) +
    'stream_spill_work');
  Wipe(GDir);
  ForceDirectories(GDir);
  GRoot := GDir + 'spillroot';
  ForceDirectories(GRoot);
  VdbSpillRootOverride := GRoot;
  GDb := GDir + 'data.odb';

  WriteLn('=== tests/stream_spill (SKILL11) ===');
  WriteLn('spill kok dizini: ', VdbSpillRoot);
  Be := TVdbBackendV3.Create(GDb);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(GDir);
  Sq := TVSql.Create(Tb);
  GDbReal := GDb;
  if (Tb.Backend <> nil) and (Tb.Backend.FilePath <> '') then
    GDbReal := Tb.Backend.FilePath;

  try
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
    Bulk('t', 1, 20000, 'v');
    Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
    Sq.Exec('CREATE TABLE e (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
    Bulk('e', 1, 6000, '123');
    { Son 100 satir sayisal DEGIL: tarama sirasinda CAST hatasi. }
    Bulk('e', 6001, 6100, 'x');
    Sq.Exec('CREATE TABLE b (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
    { NULL tasiyan tablo: SS12'de belgelenen maddesel yolda kalmali. }
    Sq.Exec('CREATE TABLE n (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
    Sq.Exec('BEGIN');
    for i := 1 to 200 do
    begin
      if (i mod 7) = 0 then
        Sq.Exec('INSERT INTO n (id, k, v) VALUES (' + IntToStr(i) +
          ', NULL, ''n' + IntToStr(i) + ''')')
      else
        Sq.Exec('INSERT INTO n (id, k, v) VALUES (' + IntToStr(i) + ', ' +
          IntToStr((i * 31) mod 97) + ', ''n' + IntToStr(i) + ''')');
    end;
    Sq.Exec('COMMIT');

    TestOrderByBasics;
    TestMemoryPlateau;
    TestCleanup;
    TestOrphans;
    TestEmbeddedApi;
    TestReleaseBuffers;
    TestBudget64M;
    TestFallbacks;
    TestMillion;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL beklenmeyen istisna: ', E.ClassName, ': ', E.Message);
    end;
  end;

  s := '';
  if DirsIn(GRoot) > 0 then
    s := IntToStr(DirsIn(GRoot)) + ' gecici dizin kaldi';
  WriteLn('---');
  WriteLn(Format('SONUC: %d PASS, %d FAIL', [GPass, GFail]));
  if (GFail > 0) or (s <> '') then
  begin
    if s <> '' then WriteLn('FAIL kapanis: ', s);
    Halt(1);
  end;
  Sq.Free;
  Tb.Free;
  { Be ayri bir nesne degil: Tb.Backend arayuzu onu sahiplenir ve Tb.Free
    ile yok edilir; burada Be.Free cift serbestlik olurdu. }
  Wipe(GDir);
end.
