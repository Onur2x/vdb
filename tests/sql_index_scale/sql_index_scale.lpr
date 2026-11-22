program sql_index_scale;
{ tests/sql_index_scale — IX1..IX20 (v3.49)

  SQL indekslerinin OLCEK davranisini olcer ve yalan soylemez:
  - Birincil anahtar (yigin aramasi) 100k/1M satirda,
  - ikincil indeks (CREATE INDEX) plani ve dogrulugu,
  - UNIQUE ihlali veri kaybi yaratmadan reddedilir mi,
  - REINDEX / VACUUM / yeniden acilis sonrasi dogruluk,
  - .odb.idx yan dosyasi bozulunca tam tarama ile kurtarma (veri kaybi yok),
  - indeksin RAM maliyeti (yigin deltasi) ve disk boyu.

  DURUST SINIR (SKILL12 ile GUNCELLENDI): ikincil indeksler artik KALICI
  disk B+Tree'sinde (VDbDiskIdx) yasar ve v5 motoruna ENTEGREDIR; ayni
  oturumda sicak FSkipIdx, yeniden acilista disk agaci kullanilir. Bu kapi
  yine de yalnizca SQL davranisini ve bellek/disk maliyetini olcer; disk
  indeksinin KALICILIGI, cokme matrisi ve olcek iddialari
  tests/disk_index_integration, tests/disk_index_crash ve
  tests/disk_index_scale kapilarinda olculur.
}
{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}
uses
  {$IFDEF USE_CTHREADS}cthreads,{$ENDIF}
  SysUtils, Classes, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore, VDbExecutor, VDbErr;

const
  ROWS100K = 100000;
  ROWS1M   = 1000000;
  BATCH    = 500;

var
  GDir, GDb, GBigDb: string;
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

procedure OpenDb(const APath, ADir: string);
begin
  Be := TVdbBackendV3.Create(APath);
  { v3.32 varsayilani: `.idx` kapanista SILINIR (tek dosya sozu). Bu kapi
    yan dosyanin davranisini olctugu icin acikca istiyoruz; varsayilan
    davranis `tests/single_file` kapsaminda ve DEGISMIYOR. }
  Be.Engine.KeepIdxOnClose := True;
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(ADir);
  Sq := TVSql.Create(Tb);
end;

procedure CloseDb;
begin
  FreeAndNil(Sq);
  FreeAndNil(Tb);
  Be := nil;   { arayuz referansli; be.Free cift serbest birakir }
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
  Result := '';
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := r.Rows[0][0];
end;

{ Plan metni: EXPLAIN'in butun satir/hucreleri birlestirilir. }
function PlanOf(const ASql: string): string;
var
  r: TSqlResult;
  i, j: Integer;
begin
  Result := '';
  r := Sq.Exec('EXPLAIN ' + ASql);
  for i := 0 to High(r.Rows) do
    for j := 0 to High(r.Rows[i]) do
      Result := Result + ' ' + r.Rows[i][j];
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

{ Bir ifadenin EVDbException ile reddedildigini ve kodunu dogrular. }
function RejectedWith(const ASql: string; ACode: TVDbErrorCode;
  out AMsg: string): Boolean;
var
  r: TSqlResult;
begin
  Result := False;
  AMsg := '';
  try
    r := Sq.Exec(ASql);
    AMsg := 'istisna yok; satir=' + IntToStr(Length(r.Rows));
  except
    on E: EVDbException do
    begin
      AMsg := VDbErrorName(E.ErrorCode) + ': ' + E.Message;
      Result := E.ErrorCode = ACode;
    end;
    on E: Exception do
      AMsg := E.ClassName + ': ' + E.Message;
  end;
end;

procedure BulkT(ALo, AHi: Int64);
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
      Sq.Exec('INSERT INTO t (id, v, b, w) VALUES (' + IntToStr(id) +
        ', ''v' + IntToStr(id) + ''', ' + IntToStr(id mod 100) +
        ', ''w' + IntToStr(id mod 1000) + ''')');
      Inc(id);
    end;
    Sq.Exec('COMMIT');
  end;
end;

procedure BulkM(ALo, AHi: Int64);
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
      Sq.Exec('INSERT INTO m (id, v) VALUES (' + IntToStr(id) +
        ', ''m' + IntToStr(id) + ''')');
      Inc(id);
    end;
    Sq.Exec('COMMIT');
  end;
end;

{ ---------- senaryolar ---------- }

procedure Scenario100k;
var
  i, k, seed, n, bad, insX, delX: Integer;
  r: TSqlResult;
  plan, rep, msg: string;
  ok: Boolean;
  t0, dtIns, dtPk, dtIdx, dtScan: Int64;
  h0, h1: Int64;
  fsDb, fsIdx: Int64;
begin
  WriteLn('--- 100k kademesi');
  OpenDb(GDb, GDir);
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, b INTEGER, w TEXT)');

  h0 := HeapKB;
  t0 := Ticks;
  BulkT(1, ROWS100K);
  dtIns := Ticks - t0;
  h1 := HeapKB;
  fsDb := FileSizeOf(GDb);
  n := IntQ('SELECT COUNT(*) FROM t');
  Chk('IX1 100k ekleme + COUNT dogru', n = ROWS100K,
    'satir=' + IntToStr(n) + ' sure_ms=' + IntToStr(dtIns) +
    ' dosya_bayt=' + IntToStr(fsDb) + ' yigin_delta_kb=' + IntToStr(h1 - h0));
  WriteLn('OLCUM IX1 100k_ekleme_ms=', dtIns, ' dosya_bayt=', fsDb,
    ' yigin_delta_kb=', h1 - h0);

  { IX2: birincil anahtar aramasi }
  t0 := Ticks;
  bad := 0;
  for i := 1 to 12 do
  begin
    k := ((i * 7919) mod ROWS100K) + 1;
    if StrQ('SELECT v FROM t WHERE id = ' + IntToStr(k)) <> 'v' + IntToStr(k) then
      Inc(bad);
  end;
  dtPk := Ticks - t0;
  plan := PlanOf('SELECT v FROM t WHERE id = 7');
  Chk('IX2a PK aramasi plani _pkey kullaniyor', Pos('t_pkey', plan) > 0, plan);
  Chk('IX2b 12 PK nokta okumasi dogru', bad = 0,
    'bozuk=' + IntToStr(bad) + ' sure_ms=' + IntToStr(dtPk));
  WriteLn('OLCUM IX2 12_pk_okuma_ms=', dtPk);

  { IX3: indekssiz kolon -> Seq Scan }
  plan := PlanOf('SELECT id FROM t WHERE w = ''w7''');
  Chk('IX3a indekssiz kolon Seq Scan', Pos('Seq Scan', plan) > 0, plan);
  n := IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''');
  Chk('IX3b indekssiz tarama dogru', n = 100, 'satir=' + IntToStr(n));

  { IX4/IX5: ikincil indeks kurulumu ve plan degisimi }
  h0 := HeapKB;
  t0 := Ticks;
  ok := True;
  msg := '';
  try
    Sq.Exec('CREATE INDEX ix_t_w ON t (w)');
  except
    on E: Exception do
    begin
      ok := False;
      msg := E.ClassName + ': ' + E.Message;
    end;
  end;
  dtIdx := Ticks - t0;
  h1 := HeapKB;
  Be.Engine.Checkpoint(True);
  Chk('IX4 CREATE INDEX calisti', ok,
    'sure_ms=' + IntToStr(dtIdx) + ' yigin_delta_kb=' + IntToStr(h1 - h0) +
    ' ' + msg);
  WriteLn('OLCUM IX4 100k_1000_grup_indeks_kurulum_ms=', dtIdx,
    ' yigin_delta_kb=', h1 - h0, ' odb_bayt=', FileSizeOf(GDb),
    ' (yan dosya boyu IX16 satirinda)');

  plan := PlanOf('SELECT id FROM t WHERE w = ''w7''');
  Chk('IX5a indeksli plan ix_t_w kullaniyor', Pos('ix_t_w', plan) > 0, plan);
  plan := PlanOf('SELECT id FROM t WHERE w > ''w990''');
  Chk('IX5b aralik plani ix_t_w kullaniyor', Pos('ix_t_w', plan) > 0, plan);

  { IX6: indeksli sorgu dogrulugu }
  t0 := Ticks;
  r := Sq.Exec('SELECT id FROM t WHERE w = ''w7'' ORDER BY id');
  dtScan := Ticks - t0;
  Chk('IX6a indeksli nokta sorgusu 100 satir', Length(r.Rows) = 100,
    'satir=' + IntToStr(Length(r.Rows)));
  Chk('IX6b indeksli sorgu degerleri dogru',
    (Length(r.Rows) > 0) and (r.Rows[0][0] = '7') and (r.Rows[99][0] = '99007'),
    'ilk=' + r.Rows[0][0] + ' son=' + r.Rows[99][0]);
  SetLength(r.Rows, 0);
  WriteLn('OLCUM IX6 indeksli_100_satir_ms=', dtScan);

  { IX7: cok tekrarlı ikincil indeks (100 grup x 1000) }
  Sq.Exec('CREATE INDEX ix_t_b ON t (b)');
  r := Sq.Exec('SELECT id FROM t WHERE b = 42');
  Chk('IX7 cok tekrarli indeks 1000 satir', Length(r.Rows) = 1000,
    'satir=' + IntToStr(Length(r.Rows)));
  SetLength(r.Rows, 0);

  { IX8/IX9: UNIQUE indeks }
  Sq.Exec('CREATE UNIQUE INDEX ux_t_v ON t (v)');
  ok := RejectedWith('INSERT INTO t (id, v, b, w) VALUES (900001, ''v5'', 0, ''wx'')',
    ecUniqueViolation, msg);
  n := IntQ('SELECT COUNT(*) FROM t');
  Chk('IX8a UNIQUE ihlali ecUniqueViolation ile reddedildi', ok, msg);
  Chk('IX8b reddedilen ekleme hayalet satir birakmadi', n = ROWS100K,
    'satir=' + IntToStr(n));
  ok := RejectedWith('UPDATE t SET v = ''v6'' WHERE id = 900', ecUniqueViolation, msg);
  Chk('IX9a UNIQUE ihlali UPDATE''te de reddedildi', ok, msg);
  Chk('IX9b reddedilen UPDATE satiri degistirmedi',
    StrQ('SELECT v FROM t WHERE id = 900') = 'v900',
    'v=' + StrQ('SELECT v FROM t WHERE id = 900'));

  { IX10: UPDATE + indeks gorunurlugu }
  Sq.Exec('UPDATE t SET w = ''degisti'' WHERE id <= 1000');
  n := IntQ('SELECT COUNT(*) FROM t WHERE w = ''degisti''');
  Chk('IX10 guncelleme indekse yansidi', n = 1000, 'satir=' + IntToStr(n));

  { IX11: DELETE + indeks gorunurlugu }
  Sq.Exec('DELETE FROM t WHERE id > 99500');
  n := IntQ('SELECT COUNT(*) FROM t');
  Chk('IX11a silme sonrasi satir sayisi', n = 99500, 'satir=' + IntToStr(n));
  n := IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''');
  Chk('IX11b silinen satirlar indeksten dusuldu', n = 99, 'satir=' + IntToStr(n));

  { IX12: karisik yazma/okuma }
  seed := 4242;
  n := IntQ('SELECT COUNT(*) FROM t');
  insX := 0;
  delX := 0;
  for i := 1 to 300 do
  begin
    seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
    k := seed mod 3;
    case k of
      0: begin
           Sq.Exec('INSERT INTO t (id, v, b, w) VALUES (' + IntToStr(200000 + i) +
             ', ''vx' + IntToStr(i) + ''', ' + IntToStr(i mod 100) + ', ''wz'')');
           Inc(n);
           Inc(insX);
         end;
      1: Sq.Exec('UPDATE t SET b = ' + IntToStr(i mod 100) + ' WHERE id = ' + IntToStr(1 + (seed mod 90000)));
      2: begin
           if IntQ('SELECT COUNT(*) FROM t WHERE id = ' + IntToStr(200001 + (seed mod 300))) > 0 then
           begin
             Sq.Exec('DELETE FROM t WHERE id = ' + IntToStr(200001 + (seed mod 300)));
             Dec(n);
             Inc(delX);
           end;
         end;
    end;
  end;
  Chk('IX12a karisik yazma sonrasi COUNT tutarli', IntQ('SELECT COUNT(*) FROM t') = n,
    'beklenen=' + IntToStr(n) + ' olculen=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')));
  Chk('IX12b karisik yazma sonrasi indeks tutarli',
    IntQ('SELECT COUNT(*) FROM t WHERE w = ''wz''') = insX - delX,
    'beklenen=' + IntToStr(insX - delX) + ' olculen=' +
    IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE w = ''wz''')));
  { karisik yazmadan sonra UNIQUE indeks hala gecerli mi: yinelenen deger yok.
    'v1' ilk toplu yuklemeden gelir (id=1) ve IX12 yalniz b/w alanlarini degistirir. }
  ok := RejectedWith('INSERT INTO t (id, v, b, w) VALUES (900002, ''v1'', 0, ''wq'')',
    ecUniqueViolation, msg);
  Chk('IX12c karisik yazmadan sonra UNIQUE korunuyor', ok, msg);

  { IX13: REINDEX }
  n := IntQ('SELECT COUNT(*) FROM t');
  ok := True;
  try
    Sq.Exec('REINDEX');
  except
    on E: Exception do
    begin
      ok := False;
      msg := E.ClassName + ': ' + E.Message;
    end;
  end;
  Chk('IX13a REINDEX calisti', ok, msg);
  Chk('IX13b REINDEX sonrasi COUNT degismedi', IntQ('SELECT COUNT(*) FROM t') = n,
    'beklenen=' + IntToStr(n) + ' olculen=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')));
  Chk('IX13c REINDEX sonrasi indeks sorgusu dogru',
    IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''') = 99,
    'satir=' + IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''')));

  { IX14: VACUUM }
  ok := True;
  try
    Sq.Exec('VACUUM');
  except
    on E: Exception do
    begin
      ok := False;
      msg := E.ClassName + ': ' + E.Message;
    end;
  end;
  Chk('IX14a VACUUM calisti', ok, msg);
  Chk('IX14b VACUUM sonrasi COUNT degismedi', IntQ('SELECT COUNT(*) FROM t') = n,
    'beklenen=' + IntToStr(n) + ' olculen=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')));
  Chk('IX14c VACUUM sonrasi indeks sorgusu dogru',
    IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''') = 99,
    'satir=' + IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''')));

  { IX15: yeniden acilis + tam VERIFY }
  CloseDb;
  Ok := VerifyDb(GDb, rep);
  Chk('IX15a yeniden acilis VERIFY temiz', ok, rep);
  OpenDb(GDb, GDir);
  Chk('IX15b yeniden acilis COUNT korunuyor', IntQ('SELECT COUNT(*) FROM t') = n,
    'beklenen=' + IntToStr(n) + ' olculen=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')));
  Chk('IX15c yeniden acilis indeks sorgusu dogru',
    IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''') = 99,
    'satir=' + IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''')));

  { IX17: SHOW INDEXES FROM t }
  r := Sq.Exec('SHOW INDEXES FROM t');
  Chk('IX17a SHOW INDEXES FROM t satir dondurdu', Length(r.Rows) >= 3,
    'satir=' + IntToStr(Length(r.Rows)));
  bad := 0;
  for i := 0 to High(r.Rows) do
    if Pos('ix_t_w', r.Rows[i][0]) > 0 then Inc(bad);
  Chk('IX17b SHOW INDEXES ix_t_w listeliyor', bad = 1, 'bulunan=' + IntToStr(bad));
  SetLength(r.Rows, 0);

  { IX18: tablo adi olmadan SHOW INDEXES -> net sozdizimi hatasi (F-20) }
  ok := RejectedWith('SHOW INDEXES', ecSyntaxError, msg);
  Chk('IX18a SHOW INDEXES (tablo adi yok) ecSyntaxError', ok, msg);
  Chk('IX18b hata mesaji eyleme donuk', Pos('tablo adi gerekir', msg) > 0, msg);

  { Yan dosya yalniz checkpoint sonrasi yazilir; IX16'nin olcmek istedigi
    sey bozuk bir .odb.idx oldugu icin once checkpoint'i zorla. }
  Be.Engine.Checkpoint(True);
  CloseDb;

  { IX16: .odb.idx yan dosyasi bozulunca tam tarama ile kurtarma }
  if FileExists(GDb + '.idx') then
  begin
    fsIdx := FileSizeOf(GDb + '.idx');
    WriteLn('OLCUM IX16 100k_idx_dosya_bayt=', fsIdx);
    { Kayit blogunun son baytini boz: dosya butun olarak CRC ile reddedilir
      ve motor tam taramaya duser. Yan dosya asla veri kaynagi degildir. }
    with TFileStream.Create(GDb + '.idx', fmOpenReadWrite or fmShareDenyNone) do
    try
      if Size > 80 then
      begin
        Seek(Size - 5, soFromBeginning);
        WriteByte(Ord('Z'));
      end;
    finally
      Free;
    end;
    OpenDb(GDb, GDir);
    Chk('IX16a bozuk .odb.idx sonrasi COUNT dogru', IntQ('SELECT COUNT(*) FROM t') = n,
      'beklenen=' + IntToStr(n) + ' olculen=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')));
    Chk('IX16b bozuk .odb.idx sonrasi indeks sorgusu dogru',
      IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''') = 99,
      'satir=' + IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE w = ''w7''')));
    CloseDb;
    Chk('IX16c bozuk yan dosya sonrasi VERIFY temiz', VerifyDb(GDb, rep), rep);
    Chk('IX16d yan dosya bozulmadan once vardi', fsIdx > 0, 'idx_bayt=' + IntToStr(fsIdx));
  end
  else
    Chk('IX16 .odb.idx yan dosyasi olustu', False, 'yan dosya yok');
end;

procedure Scenario1M;
var
  n, t0, dt, dtIdx, dtFirst: Int64;
  h0, h1: Int64;
  ok: Boolean;
  rep, plan: string;
  fsDb, fsIdx: Int64;
begin
  WriteLn('--- 1M kademesi');
  OpenDb(GBigDb, GDir);
  Sq.Exec('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
  h0 := HeapKB;
  t0 := Ticks;
  BulkM(1, ROWS1M);
  dt := Ticks - t0;
  h1 := HeapKB;
  fsDb := FileSizeOf(GBigDb);
  n := IntQ('SELECT COUNT(*) FROM m');
  Chk('IX19a 1M ekleme + COUNT dogru', n = ROWS1M,
    'satir=' + IntToStr(n) + ' sure_ms=' + IntToStr(dt) +
    ' dosya_bayt=' + IntToStr(fsDb) + ' yigin_delta_kb=' + IntToStr(h1 - h0));
  WriteLn('OLCUM IX19 1M_ekleme_ms=', dt, ' dosya_bayt=', fsDb,
    ' yigin_delta_kb=', h1 - h0);

  h0 := HeapKB;
  t0 := Ticks;
  Sq.Exec('CREATE INDEX ix_m_v ON m (v)');
  dtIdx := Ticks - t0;
  h1 := HeapKB;
  { .odb.idx yalniz checkpoint'te yazilir; gercek yan dosya boyunu olcmek
    icin once checkpoint, sonra dosya boyu. Yigin deltasi indeks kurulumunun
    kendisini olcer, checkpoint dahil degildir. }
  Be.Engine.Checkpoint(True);
  fsIdx := FileSizeOf(GBigDb + '.idx');
  Chk('IX19b 1M indeks kurulumu calisti', True,
    'sure_ms=' + IntToStr(dtIdx) + ' yigin_delta_kb=' + IntToStr(h1 - h0));
  WriteLn('OLCUM IX19b 1M_indeks_kurulum_ms=', dtIdx,
    ' yigin_delta_kb=', h1 - h0,
    ' odb_bayt=', FileSizeOf(GBigDb), ' indeks_basina_satir_bayt=',
    ((h1 - h0) * 1024) div ROWS1M);

  plan := PlanOf('SELECT id FROM m WHERE v = ''m500000''');
  Chk('IX19c 1M indeksli plan ix_m_v kullaniyor', Pos('ix_m_v', plan) > 0, plan);
  t0 := Ticks;
  Chk('IX19d 1M indeksli nokta okumasi dogru',
    StrQ('SELECT id FROM m WHERE v = ''m500000''') = '500000',
    'deger=' + StrQ('SELECT id FROM m WHERE v = ''m500000'''));
  WriteLn('OLCUM IX19d 1M_indeksli_nokta_ms=', Ticks - t0);

  CloseDb;
  fsIdx := FileSizeOf(GBigDb + '.idx');
  WriteLn('OLCUM IX19 kapanis_sonrasi_idx_dosya_bayt=', fsIdx);
  ok := VerifyDb(GBigDb, rep);
  Chk('IX19e 1M dosya VERIFY temiz', ok, rep);

  { IX20: yeniden acilis sonrasi ilk indeksli sorgu = indeks yeniden kurulumu }
  OpenDb(GBigDb, GDir);
  t0 := Ticks;
  n := IntQ('SELECT COUNT(*) FROM m');
  dtFirst := Ticks - t0;
  Chk('IX20a yeniden acilis COUNT dogru', n = ROWS1M, 'satir=' + IntToStr(n));
  t0 := Ticks;
  Chk('IX20b yeniden acilis sonrasi indeks sorgusu dogru',
    StrQ('SELECT id FROM m WHERE v = ''m999999''') = '999999',
    'deger=' + StrQ('SELECT id FROM m WHERE v = ''m999999'''));
  WriteLn('OLCUM IX20 yeniden_acilis_count_ms=', dtFirst,
    ' yeniden_acilis_indeks_sorgu_ms=', Ticks - t0,
    ' (indeks bellekte oldugu icin ilk sorgu yeniden kurulum bedelini oder)');
  CloseDb;
end;

begin
  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/sql_index_scale');
  Wipe(GDir);
  GDb := IncludeTrailingPathDelimiter(GDir) + 'ix.odb';
  GBigDb := IncludeTrailingPathDelimiter(GDir) + 'big.odb';

  WriteLn('=== tests/sql_index_scale (v3.49) ===');
  WriteLn('Ikincil indeksler artik KALICI disk B+Tree (VDbDiskIdx); disk');
  WriteLn('entegrasyonu/cokme matrisi/olcek tests/disk_index_* kapilarindadir.');
  try
    Scenario100k;
    Scenario1M;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn('FAIL BEKLENMEYEN ISTISNA ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  Flush(Output);
  ExitCode := GFail;
end.
