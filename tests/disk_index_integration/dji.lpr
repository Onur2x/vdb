program dji;
{ tests/disk_index_integration — SKILL12: KALICI DISK INDEKSI (v5)

  Amac: ikincil indekslerin GERCEKTEN diskte yasadigini ve heap ile
  atomik kaldigini olcmek. Her iddia ayri bir kontrol (D1..) olarak
  yazilir; olculemeyen sey PASS sayilmaz.

  Kapsam:
    A  kalicilik: CREATE INDEX dosya birakir; kapanip acilinca indeks
       RAM'e TAMAMEN yuklenmeden diskten servis edilir (DiskIdxBuilds=0).
    B  aralik, bilesik, mukerrer anahtar, NULL.
    C  UPDATE / DELETE sonrasi artimli guncelleme (dosya tazelenir).
    D  islem geri alma: diske yazilmamis degisiklik sizmaz.
    E  damga uyusmazligi (eski .dix geri konursa) -> yeniden insa.
    F  sayfa bozulmasi -> red + yeniden insa; ASLA yanlis satir yok.
    G  REINDEX / VACUUM / DROP INDEX / islem icinde CREATE INDEX.
    H  cok surecli okur (ayni exe, alt surec) ve ikinci yazar.

  Not: indeks TURETILMIS veridir; dogru olan heap'tir. Bozuk/bayat indeks
  daima reddedilir ve veriden yeniden kurulur. }
{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}
uses
  {$IFDEF USE_CTHREADS}cthreads,{$ENDIF}
  SysUtils, Classes, Process, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore, VDbExecutor, VDbErr;

const
  NROWS = 3000;
  BATCH = 500;

var
  GDir, GDb: string;
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

procedure CopyFileTo(const ASrc, ADst: string);
var
  a, b: TFileStream;
begin
  a := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    b := TFileStream.Create(ADst, fmCreate);
    try
      b.CopyFrom(a, 0);
    finally
      b.Free;
    end;
  finally
    a.Free;
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

function DixFiles: Integer;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(GDir + 'vdbidx_*.dix', faAnyFile, sr) = 0 then
  begin
    repeat
      Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function FirstDix: string;
var
  sr: TSearchRec;
begin
  Result := '';
  if FindFirst(GDir + 'vdbidx_*.dix', faAnyFile, sr) = 0 then
  begin
    Result := GDir + sr.Name;
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

function RowCountOf(const ASql: string): Integer;
var
  r: TSqlResult;
begin
  r := Sq.Exec(ASql);
  Result := Length(r.Rows);
end;

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

{ id mod ModA = A ve id mod ModB = B olan satir sayisi (SQL'den bagimsiz). }
function CountMod(AModA, A, AModB, B: Integer): Integer;
var
  id: Integer;
begin
  Result := 0;
  for id := 1 to NROWS do
    if (id mod AModA = A) and (id mod AModB = B) then Inc(Result);
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
      Sq.Exec('INSERT INTO t (id, a, n, b) VALUES (' + IntToStr(id) +
        ', ''k' + IntToStr(id mod 50) + ''', ' + IntToStr(id mod 100) +
        ', ''b' + IntToStr(id mod 7) + ''')');
      Inc(id);
    end;
    Sq.Exec('COMMIT');
  end;
end;

procedure NewDb(ARows: Int64);
begin
  CloseDb;   { onceki senaryo acik kalmis olabilir }
  Wipe(GDir);
  OpenDb;
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, n INTEGER, b TEXT)');
  BulkT(1, ARows);
end;

{ A + B: kalicilik, diskten okuma, aralik/bilesik/mukerrer/NULL. }
procedure ScenarioAB;
var
  hits: Int64;
  sz: Int64;
  rep: string;
begin
  NewDb(NROWS);
  Sq.Exec('CREATE INDEX ix_a ON t (a)');
  Sq.Exec('CREATE INDEX ix_nb ON t (n, b)');
  Chk('D1 CREATE INDEX iki .dix dosyasi birakti', DixFiles = 2,
    'dosya=' + IntToStr(DixFiles));
  sz := FileSizeOf(FirstDix);
  Chk('D2 .dix dosyasi gecerli boyutta', sz >= 3 * 4096, 'boy=' + IntToStr(sz));
  { D3..D5 YENIDEN ACILMIS oturumda olculur: ayni oturumda sicak skiplist
    vardir ve disk yolu (tasarim geregi) kullanilmaz. Disk iddiasi ancak
    taze acilista anlamlidir. }
  CloseDb;
  { Kapanista tanitici birakilmali: sizinti Windows'ta dosyayi kilitler ve
    sonraki yeniden insa/rename basarisiz olur (olculmus hata). }
  Chk('D2b kapanista .dix taniticisi birakildi', CanWrite(FirstDix));
  OpenDb;
  hits := Tb.DiskIdxHits;
  Chk('D3 indeksli esitlik dogru (mukerrer anahtar)',
    RowCountOf('SELECT id FROM t WHERE a = ''k7''') = 60,
    IntToStr(RowCountOf('SELECT id FROM t WHERE a = ''k7''')));
  Chk('D4 esitlik sorgusu indeks kullaniyor', Pos('Index Scan',
    PlanOf('SELECT id FROM t WHERE a = ''k7''')) > 0,
    PlanOf('SELECT id FROM t WHERE a = ''k7'''));
  Chk('D5 disk indeksi servis etti (DiskIdxHits>0)', Tb.DiskIdxHits > hits,
    'once=' + IntToStr(hits) + ' sonra=' + IntToStr(Tb.DiskIdxHits));

  { --- kapan / ac: indeks RAM'e yuklenmeden diskten gelmeli --- }
  CloseDb;
  OpenDb;
  Chk('D6 yeniden acilista ayni sonuc',
    RowCountOf('SELECT id FROM t WHERE a = ''k7''') = 60);
  hits := Tb.DiskIdxHits;
  Chk('D7 yeniden acilista diskten servis edildi',
    RowCountOf('SELECT id FROM t WHERE a = ''k7''') = 60, 'satir');
  Chk('D7b yeniden acilista DiskIdxHits>0', Tb.DiskIdxHits > hits,
    'once=' + IntToStr(hits) + ' sonra=' + IntToStr(Tb.DiskIdxHits));
  Chk('D8 yeniden acilista YENIDEN INSA YOK', Tb.DiskIdxBuilds = 0,
    'builds=' + IntToStr(Tb.DiskIdxBuilds));

  { aralik taramasi: sayisal (karsilastirma belirsizligi yok) }
  Chk('D9 aralik taramasi dogru', IntQ(
    'SELECT COUNT(*) FROM t WHERE n >= 10 AND n < 20') = 300,
    IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE n >= 10 AND n < 20')));
  { bilesik indeks }
  Chk('D10 bilesik indeks dogru', IntQ(
    'SELECT COUNT(*) FROM t WHERE n = 7 AND b = ''b3''') = CountMod(100, 7, 7, 3),
    'beklenen=' + IntToStr(CountMod(100, 7, 7, 3)) + ' gelen=' +
    IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE n = 7 AND b = ''b3''')));
  { NULL: indekse GIRMEZ, IS NULL bulur }
  Sq.Exec('INSERT INTO t (id, a, n, b) VALUES (9001, NULL, 1, ''bx'')');
  Sq.Exec('INSERT INTO t (id, a, n, b) VALUES (9002, NULL, 1, ''bx'')');
  Chk('D11 NULL anahtar IS NULL ile bulunur', IntQ(
    'SELECT COUNT(*) FROM t WHERE a IS NULL') = 2,
    IntToStr(IntQ('SELECT COUNT(*) FROM t WHERE a IS NULL')));
  Chk('D12 NULL anahtar esitlik taramasina girmez', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''k7''') = 60);
  Chk('D13 tam dogrulama (vmFull)', VerifyDb(GDb, rep), rep);
end;

{ C: UPDATE / DELETE artimli olarak diske isleniyor mu? }
procedure ScenarioC;
var
  base: Int64;
begin
  Chk('D14 guncelleme oncesi k1 sayisi', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''k1''') = 60);
  Sq.Exec('UPDATE t SET a = ''zz'' WHERE id = 1');
  Sq.Exec('DELETE FROM t WHERE id = 2');
  Chk('D15 UPDATE sonrasi yeni anahtar', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''zz''') = 1);
  Chk('D16 UPDATE sonrasi eski anahtar azaldi', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''k1''') = 59);
  Chk('D17 DELETE sonrasi anahtar azaldi', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''k2''') = 59);
  base := IntQ('SELECT COUNT(*) FROM t');
  Chk('D18 toplam satir 3001', base = 3001, IntToStr(base));
  CloseDb;
  OpenDb;
  Chk('D19 yeniden acilista UPDATE kalici', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''zz''') = 1);
  Chk('D20 yeniden acilista DELETE kalici', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''k2''') = 59);
  Chk('D21 artimli yazim yeniden insa gerektirmedi', Tb.DiskIdxBuilds = 0,
    'builds=' + IntToStr(Tb.DiskIdxBuilds));
end;

{ D: geri alma diskte iz birakmaz. }
procedure ScenarioD;
var
  before, after: Int64;
begin
  before := IntQ('SELECT COUNT(*) FROM t');
  Sq.Exec('BEGIN');
  Sq.Exec('INSERT INTO t (id, a, n, b) VALUES (9500, ''rb'', 5, ''by'')');
  Sq.Exec('UPDATE t SET a = ''rb2'' WHERE id = 3');
  Sq.Exec('ROLLBACK');
  after := IntQ('SELECT COUNT(*) FROM t');
  Chk('D22 ROLLBACK sonrasi satir sayisi degismedi', before = after,
    IntToStr(before) + ' -> ' + IntToStr(after));
  Chk('D23 ROLLBACK edilen INSERT indekste yok', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''rb''') = 0);
  Chk('D24 ROLLBACK edilen UPDATE indekste yok', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''rb2''') = 0);
  Chk('D25 ROLLBACK sonrasi eski anahtar yerinde', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''k3''') = 60);
  CloseDb;
  OpenDb;
  Chk('D26 yeniden acilista ROLLBACK kalici', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''rb''') = 0);
  Chk('D27 yeniden acilista eski anahtar yerinde', IntQ(
    'SELECT COUNT(*) FROM t WHERE a = ''k3''') = 60);
end;

{ E: eski .dix geri konursa damga uyusmaz -> yeniden insa, yanlis satir YOK. }
procedure ScenarioE;
var
  f, bak: string;
  i: Integer;
begin
  CloseDb;   { onceki senaryo acik kalmis olabilir }
  Wipe(GDir);
  OpenDb;
  Sq.Exec('CREATE TABLE e (id INTEGER PRIMARY KEY, a TEXT)');
  Sq.Exec('BEGIN');
  for i := 1 to 100 do
    Sq.Exec('INSERT INTO e (id, a) VALUES (' + IntToStr(i) +
      ', ''k' + IntToStr(i mod 10) + ''')');
  Sq.Exec('COMMIT');
  Sq.Exec('CREATE INDEX ix_e ON e (a)');
  f := FirstDix;
  bak := GDir + 'eski.dix';
  CopyFileTo(f, bak);
  CloseDb;
  OpenDb;
  Sq.Exec('UPDATE e SET a = ''yeni'' WHERE id = 10');
  CloseDb;
  { eski (damgasi bayat) dosyayi geri koy }
  CopyFileTo(bak, f);
  OpenDb;
  Chk('D28 bayat .dix reddedildi, dogru satir', IntQ(
    'SELECT COUNT(*) FROM e WHERE a = ''yeni''') = 1,
    IntToStr(IntQ('SELECT COUNT(*) FROM e WHERE a = ''yeni''')));
  Chk('D29 bayat .dix sonrasi eski anahtar dogru', IntQ(
    'SELECT COUNT(*) FROM e WHERE a = ''k0''') = 9,
    IntToStr(IntQ('SELECT COUNT(*) FROM e WHERE a = ''k0''')));
  Chk('D30 bayat indeks yeniden insa edildi', Tb.DiskIdxBuilds > 0,
    'builds=' + IntToStr(Tb.DiskIdxBuilds));
end;

{ F: sayfa bozulmasi -> red + yeniden insa; asla yanlis satir. }
procedure CorruptAt(const APath: string; AOffset: Int64);
var
  fs: TFileStream;
  b: Byte;
begin
  fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := AOffset;
    fs.ReadBuffer(b, 1);
    b := b xor $5A;
    fs.Position := AOffset;
    fs.WriteBuffer(b, 1);
  finally
    fs.Free;
  end;
end;

procedure ScenarioF;
var
  f: string;
  rep: string;
  i: Integer;
begin
  CloseDb;   { onceki senaryo acik kalmis olabilir }
  Wipe(GDir);
  OpenDb;
  Sq.Exec('CREATE TABLE f (id INTEGER PRIMARY KEY, a TEXT)');
  Sq.Exec('BEGIN');
  for i := 1 to 400 do
    Sq.Exec('INSERT INTO f (id, a) VALUES (' + IntToStr(i) +
      ', ''v' + IntToStr(i mod 20) + ''')');
  Sq.Exec('COMMIT');
  Sq.Exec('CREATE INDEX ix_f ON f (a)');
  CloseDb;
  f := FirstDix;
  { veri sayfasi (meta 2 sayfa = 8192; ilk veri sayfasi) icinde bir bayt }
  CorruptAt(f, 8192 + 64);
  OpenDb;
  Chk('D31 bozuk veri sayfasi yanlis satir dondurmedi', IntQ(
    'SELECT COUNT(*) FROM f WHERE a = ''v7''') = 20,
    IntToStr(IntQ('SELECT COUNT(*) FROM f WHERE a = ''v7''')));
  Chk('D32 bozuk indeks yeniden insa edildi', Tb.DiskIdxBuilds > 0,
    'builds=' + IntToStr(Tb.DiskIdxBuilds));
  Chk('D33 bozulma sonrasi tam dogrulama', VerifyDb(GDb, rep), rep);
  CloseDb;
  f := FirstDix;
  { meta sayfayi tamamen boz }
  CorruptAt(f, 16);
  CorruptAt(f, 4096 + 16);
  OpenDb;
  Chk('D34 bozuk meta reddedildi, satirlar dogru', IntQ(
    'SELECT COUNT(*) FROM f WHERE a = ''v7''') = 20);
  Chk('D35 bozuk meta sonrasi yeniden insa', Tb.DiskIdxBuilds > 0,
    'builds=' + IntToStr(Tb.DiskIdxBuilds));
end;

{ G: REINDEX / VACUUM / DROP / islem icinde CREATE INDEX. }
procedure ScenarioG;
var
  n0: Int64;
  i: Integer;
begin
  CloseDb;   { onceki senaryo acik kalmis olabilir }
  Wipe(GDir);
  OpenDb;
  Sq.Exec('CREATE TABLE g (id INTEGER PRIMARY KEY, a TEXT)');
  Sq.Exec('BEGIN');
  for i := 1 to 200 do
    Sq.Exec('INSERT INTO g (id, a) VALUES (' + IntToStr(i) +
      ', ''g' + IntToStr(i mod 10) + ''')');
  { DDL islem ICINDE: dosya commit'ten sonra yazilmali (ertelenmis yol) }
  Sq.Exec('CREATE INDEX ix_g ON g (a)');
  Sq.Exec('COMMIT');
  Chk('D36 islem icinde CREATE INDEX dosya birakti', DixFiles = 1,
    'dosya=' + IntToStr(DixFiles));
  Chk('D37 islem icinde kurulan indeks dogru', IntQ(
    'SELECT COUNT(*) FROM g WHERE a = ''g3''') = 20);
  n0 := IntQ('SELECT COUNT(*) FROM g');
  Sq.Exec('REINDEX');
  Chk('D38 REINDEX satir kaybetmedi', IntQ('SELECT COUNT(*) FROM g') = n0);
  Chk('D39 REINDEX sonrasi indeks dogru', IntQ(
    'SELECT COUNT(*) FROM g WHERE a = ''g3''') = 20);
  Sq.Exec('VACUUM');
  Chk('D40 VACUUM sonrasi indeks dogru', IntQ(
    'SELECT COUNT(*) FROM g WHERE a = ''g3''') = 20);
  CloseDb;
  OpenDb;
  Chk('D41 VACUUM + yeniden acilis indeks dogru', IntQ(
    'SELECT COUNT(*) FROM g WHERE a = ''g3''') = 20);
  Chk('D42 VACUUM sonrasi dosya hala diskte', DixFiles >= 1);
  CloseDb;
  OpenDb;
  Sq.Exec('DROP INDEX ix_g');
  Chk('D43 DROP INDEX dosyayi sildi', DixFiles = 0,
    'dosya=' + IntToStr(DixFiles));
  Chk('D44 DROP INDEX sonrasi tam tarama dogru', IntQ(
    'SELECT COUNT(*) FROM g WHERE a = ''g3''') = 20);
end;

{ H: alt surec salt-okunur acip ayni sonucu ve DISKTEN servisi goruyor mu? }
procedure ScenarioH;
var
  exe: string;
  p: TProcess;
  outS: TStringList;
  ok: Boolean;
begin
  CloseDb;   { onceki senaryo acik kalmis olabilir }
  Wipe(GDir);
  OpenDb;
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, n INTEGER, b TEXT)');
  BulkT(1, NROWS);
  Sq.Exec('CREATE INDEX ix_a ON t (a)');
  CloseDb;

  exe := ParamStr(0);
  p := TProcess.Create(nil);
  outS := TStringList.Create;
  try
    p.Executable := exe;
    p.Parameters.Add('--readonly-check');
    p.Parameters.Add(GDir);
    p.Options := [poUsePipes, poWaitOnExit];
    p.Execute;
    outS.LoadFromStream(p.Output);
    ok := (p.ExitStatus = 0) and (Pos('CHILD-OK', outS.Text) > 0);
    Chk('D45 ayri surec disk indeksini yeniden insa etmeden okudu', ok,
      'exit=' + IntToStr(p.ExitStatus) + ' cikti=' + Trim(outS.Text));
  finally
    outS.Free;
    p.Free;
  end;
end;

{ Alt surec: yalniz okur; indeks diskten gelmeli (builds = 0). }
function ChildCheck(const ADir: string): Integer;
var
  b: TVdbBackendV3;
  t: TVTableDb;
  q: TVSql;
  r: TSqlResult;
  n: Int64;
begin
  Result := 3;
  b := TVdbBackendV3.CreateReadOnly(IncludeTrailingPathDelimiter(ADir) + 'dji.odb');
  try
    t := TVTableDb.CreateBackend(b);
    try
      t.Open(IncludeTrailingPathDelimiter(ADir));
      q := TVSql.Create(t);
      try
        r := q.Exec('SELECT COUNT(*) FROM t WHERE a = ''k7''');
        n := -1;
        if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
          n := StrToInt64Def(Trim(r.Rows[0][0]), -1);
        { builds=0 YETMEZ: hic indeks okunmamis da olabilir. hits>0 sart. }
        if (n = 60) and (t.DiskIdxBuilds = 0) and (t.DiskIdxHits > 0) then
        begin
          WriteLn('CHILD-OK ', n, ' builds=', t.DiskIdxBuilds,
            ' hits=', t.DiskIdxHits);
          Result := 0;
        end
        else
          WriteLn('CHILD-BAD n=', n, ' builds=', t.DiskIdxBuilds,
            ' hits=', t.DiskIdxHits);
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

{ I: iki yazar ayni dosyaya yazar; sonuc indekste EKSIK olmamali. }
procedure ScenarioI;
var
  b2: TVdbBackendV3;
  t2: TVTableDb;
  q2: TVSql;
  total: Int64;
begin
  CloseDb;   { onceki senaryo acik kalmis olabilir }
  Wipe(GDir);
  OpenDb;
  Sq.Exec('CREATE TABLE w (id INTEGER PRIMARY KEY, a TEXT)');
  Sq.Exec('INSERT INTO w (id, a) VALUES (1, ''x'')');
  Sq.Exec('CREATE INDEX ix_w ON w (a)');
  b2 := TVdbBackendV3.Create(GDb);
  try
    t2 := TVTableDb.CreateBackend(b2);
    try
      t2.Open(GDir);
      q2 := TVSql.Create(t2);
      try
        Sq.Exec('INSERT INTO w (id, a) VALUES (2, ''x'')');
        q2.Exec('INSERT INTO w (id, a) VALUES (3, ''x'')');
      finally
        q2.Free;
      end;
    finally
      t2.Free;
    end;
  finally
    b2 := nil;
  end;
  CloseDb;
  OpenDb;
  total := IntQ('SELECT COUNT(*) FROM w');
  Chk('D46 iki yazar sonrasi indeks tam taramayla ayni',
    IntQ('SELECT COUNT(*) FROM w WHERE a = ''x''') = total,
    'indeks=' + IntToStr(IntQ('SELECT COUNT(*) FROM w WHERE a = ''x''')) +
    ' toplam=' + IntToStr(total));
  Chk('D47 iki yazar sonrasi uc satir korundu', total = 3, IntToStr(total));
end;

var
  rep: string;
begin
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'dji_work');
  if (ParamCount >= 2) and (ParamStr(1) = '--readonly-check') then
  begin
    ExitCode := ChildCheck(ParamStr(2));
    Exit;
  end;

  GDb := GDir + 'dji.odb';
  WriteLn('=== tests/disk_index_integration (SKILL12) ===');
  ForceDirectories(GDir);
  try
    ScenarioAB;
    ScenarioC;
    ScenarioD;
    ScenarioE;
    ScenarioF;
    ScenarioG;
    ScenarioH;
    ScenarioI;
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
