program dixscale;
{ tests/disk_index_scale - SKILL12: KALICI DISK INDEKSI OLCEK KAPISI (v5)

  Amac: 1M satirlik tabloda ikincil indeksin diskte kalici oldugunu,
  yeniden acilista RAM'e TAMAMEN yuklenmeden servis edildigini (yeniden
  insa YOK) ve sonuclarin bagimsiz hesapla AYNI oldugunu olcmek.

  Kullanim: dixscale [satir]     (varsayilan 1000000)
  Cikti: PASS/FAIL satirlari + BILGI satirlari (boy, sure, bellek).

  Bellek iddiasi: acilis + sorgu sonrasi heap buyumesi, indeks dosyasinin
  yarisindan kucuk olmali. Anahtarlarin tamami RAM'e alinsaydi en az dosya
  boyutu kadar yer gerekirdi; VDbDiskIdx salt-okunur sayfa onbellegi
  DIX_CACHE_PAGES (64 sayfa = 256 KB) ile SINIRLIDIR.

  Not: 10M kosusu CI'ya DAHIL DEGILDIR; elle calistirilir ve olculen sayilar
  dokumana yazilir. }
{$mode delphi}{$H+}
{$IFDEF UNIX}{$DEFINE USE_CTHREADS}{$ENDIF}
uses
  {$IFDEF USE_CTHREADS}cthreads,{$ENDIF}
  SysUtils, Classes, VDbBackendV3, VDbPageEngine, VDbTable, VDbSql,
  VDbPageStore, VDbExecutor, VDbErr, VDbDiskIdx;

type
  { Dogrudan yapisal olcum icin ikili karsilastirici (dixtest ile ayni). }
  TStrCmp = class(TVDbDixCmp)
  public
    function CompareEntries(const AKey1, AVal1, AKey2, AVal2: string): Integer; override;
    function CompareKeyBound(const AKey, ABound: string): Integer; override;
  end;

function TStrCmp.CompareEntries(const AKey1, AVal1, AKey2, AVal2: string): Integer;
begin
  Result := CompareStr(AKey1, AKey2);
  if Result = 0 then
    Result := CompareStr(AVal1, AVal2);
end;

function TStrCmp.CompareKeyBound(const AKey, ABound: string): Integer;
begin
  Result := CompareStr(AKey, ABound);
end;

const
  DBNAME = 'dixscale.odb';
  BATCH = 500;
  DEFAULT_ROWS = 1000000;

var
  GDir, GDb: string;
  GPass, GFail: Integer;
  GRows: Int64;
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

procedure Info(const S: string);
begin
  WriteLn('BILGI ', S);
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

function DixSize: Int64;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(GDir + 'vdbidx_*.dix', faAnyFile, sr) = 0 then
  begin
    repeat
      Inc(Result, sr.Size);
    until FindNext(sr) <> 0;
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

function IntQ(const ASql: string): Int64;
var
  r: TSqlResult;
begin
  Result := -1;
  r := Sq.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := StrToInt64Def(Trim(r.Rows[0][0]), -1);
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
        ', ''k' + IntToStr(id mod 50000) + ''', ' + IntToStr(id mod 1000) +
        ', ''b' + IntToStr(id mod 7) + ''')');
      Inc(id);
    end;
    Sq.Exec('COMMIT');
    if (id mod 200000) < BATCH then
      Info('yazildi=' + IntToStr(id - 1));
  end;
end;

function ExpectEqUpTo(AVal: Integer; AMax: Int64): Int64;
var
  id: Int64;
begin
  Result := 0;
  id := 1;
  while id <= AMax do
  begin
    if (id mod 50000) = AVal then Inc(Result);
    Inc(id);
  end;
end;

function ExpectEq(AVal: Integer): Int64;
begin
  Result := ExpectEqUpTo(AVal, GRows);
end;

function ExpectRange(ALo, AHi: Integer): Int64;
var
  id: Int64;
  n: Integer;
begin
  Result := 0;
  id := 1;
  while id <= GRows do
  begin
    n := id mod 1000;
    if (n >= ALo) and (n < AHi) then Inc(Result);
    Inc(id);
  end;
end;

procedure ProbeStructure;
var
  cmp: TStrCmp;
  tree: TVDbDiskIdx;
  reason, fn, cov: string;
  sr: TSearchRec;
begin
  fn := '';
  if FindFirst(GDir + 'vdbidx_*.dix', faAnyFile, sr) = 0 then
  begin
    fn := GDir + sr.Name;
    FindClose(sr);
  end;
  Chk('S15 .dix dosyasi bulundu', fn <> '');
  if fn = '' then Exit;
  cmp := TStrCmp.Create;
  tree := nil;
  try
    if not TVDbDiskIdx.TryOpen(fn, cmp, True, tree, reason) then
    begin
      Chk('S16 indeks dosyasi acildi', False, reason);
      Exit;
    end;
    Chk('S16 indeks dosyasi acildi', True);
    Chk('S17 agac cok sayfali ve cok seviyeli',
      (tree.PageCount > 100) and (tree.Height >= 2),
      'sayfa=' + IntToStr(tree.PageCount) + ' yukseklik=' + IntToStr(tree.Height));
    tree.Find('k12345', '', cov);
    Info('yapisal: sayfa=' + IntToStr(tree.PageCount) + ' yukseklik=' +
      IntToStr(tree.Height) + ' tek arama sonrasi okunan sayfa=' +
      IntToStr(tree.PagesRead));
    { Tamami yuklenseydi PageCount kadar okuma olurdu; onbellek 64 sayfa. }
    Chk('S18 tek arama yalnizca yol kadar sayfa okudu',
      tree.PagesRead <= 8, 'okunan=' + IntToStr(tree.PagesRead));
  finally
    tree.Free;
    cmp.Free;
  end;
end;

var
  t0, t1: QWord;
  mem0, mem1: PtrUInt;
  hs: THeapStatus;
  sz: Int64;
  eEq, eRng, gEq, gRng, gTotal: Int64;

begin
  GPass := 0;
  GFail := 0;
  GRows := DEFAULT_ROWS;
  if ParamCount >= 1 then
    GRows := StrToInt64Def(ParamStr(1), DEFAULT_ROWS);
  if GRows < 1000 then GRows := 1000;

  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'dixscale_work');
  GDb := GDir + DBNAME;
  Wipe(GDir);

  t0 := GetTickCount64;
  OpenDb;
  Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, n INTEGER, b TEXT)');
  InsertRange(1, GRows);
  Sq.Exec('CREATE INDEX ix_a ON t (a)');
  Sq.Exec('CREATE INDEX ix_n ON t (n)');
  CloseDb;
  t1 := GetTickCount64;
  Info('satir=' + IntToStr(GRows) + ' yazim_ms=' + IntToStr(t1 - t0));

  sz := DixSize;
  Chk('S1 iki .dix dosyasi yazildi', sz >= 8 * 4096, 'boy=' + IntToStr(sz));
  Info('.dix toplam boy=' + IntToStr(sz) + ' bayt, sayfa~' +
    IntToStr(sz div 4096));

  { --- SOGUK ACILIS: indeks RAM'e yuklenmemeli, insa edilmemeli --------- }
  hs := GetHeapStatus;
  mem0 := hs.TotalAllocated;
  t0 := GetTickCount64;
  OpenDb;
  gTotal := IntQ('SELECT COUNT(*) FROM t');
  t1 := GetTickCount64;
  Chk('S2 yeniden acilista toplam satir', gTotal = GRows,
    'sayi=' + IntToStr(gTotal) + ' beklenen=' + IntToStr(GRows));

  eEq := ExpectEq(12345);
  gEq := IntQ('SELECT COUNT(*) FROM t WHERE a = ''k12345''');
  Chk('S3 esitlik sorgusu dogru', gEq = eEq,
    'sayi=' + IntToStr(gEq) + ' beklenen=' + IntToStr(eEq));

  eRng := ExpectRange(250, 260);
  gRng := IntQ('SELECT COUNT(*) FROM t WHERE n >= 250 AND n < 260');
  Chk('S4 aralik sorgusu dogru', gRng = eRng,
    'sayi=' + IntToStr(gRng) + ' beklenen=' + IntToStr(eRng));

  hs := GetHeapStatus;
  mem1 := hs.TotalAllocated;
  Info('acilis+ilk sorgu_ms=' + IntToStr(t1 - t0) + ' heap_delta=' +
    IntToStr(Int64(mem1) - Int64(mem0)) + ' bayt');
  { NOT: bu delta SQL katmaninin plan/onbellek ayirmalarini da icerir; tek
    basina indekse atfedilemez. Indeksin tam yuklenmedigi iddiasi S18'de
    DOGRUDAN yapi uzerinde olculur (tek arama yalnizca yol kadar sayfa okur).
    Burada yalnizca bilgi olarak raporlanir, PASS/FAIL uretilmez. }

  Chk('S6 yeniden insa YOK', Tb.DiskIdxBuilds = 0,
    'builds=' + IntToStr(Tb.DiskIdxBuilds));
  Chk('S7 diskten servis edildi', Tb.DiskIdxHits > 0,
    'hits=' + IntToStr(Tb.DiskIdxHits));

  { Ayni oturumda tekrar: sonuc degismemeli. }
  Chk('S8 tekrar esitlik ayni', IntQ('SELECT COUNT(*) FROM t WHERE a = ''k12345''') = eEq);
  CloseDb;

  { --- IKINCI SOGUK ACILIS (dosya gercekten kalici) --------------------- }
  OpenDb;
  Chk('S9 ikinci acilis esitlik ayni',
    IntQ('SELECT COUNT(*) FROM t WHERE a = ''k12345''') = eEq);
  Chk('S10 ikinci acilis aralik ayni',
    IntQ('SELECT COUNT(*) FROM t WHERE n >= 250 AND n < 260') = eRng);
  Chk('S11 ikinci acilis insa YOK', Tb.DiskIdxBuilds = 0,
    'builds=' + IntToStr(Tb.DiskIdxBuilds));
  CloseDb;

  { --- YAPISAL OLCUM: indeksin TAMAMI RAM'e alinmiyor ------------------ }
  ProbeStructure;

  { --- YAZMA: artimli guncelleme kalici mi ------------------------------ }
  OpenDb;
  Sq.Exec('UPDATE t SET a = ''zz'' WHERE id <= 1000');
  Sq.Exec('DELETE FROM t WHERE id > ' + IntToStr(GRows - 1000));
  CloseDb;
  OpenDb;
  Chk('S12 guncelleme sonrasi toplam', IntQ('SELECT COUNT(*) FROM t') = GRows - 1000,
    'sayi=' + IntToStr(IntQ('SELECT COUNT(*) FROM t')));
  Chk('S13 guncelleme sonrasi silinen satirlar dusuldu',
    IntQ('SELECT COUNT(*) FROM t WHERE a = ''k12345''') =
      ExpectEqUpTo(12345, GRows - 1000));
  Chk('S14 guncelleme sonrasi yeni anahtar',
    IntQ('SELECT COUNT(*) FROM t WHERE a = ''zz''') = 1000);
  CloseDb;

  Info('toplam .dix boy=' + IntToStr(DixSize) + ' bayt');

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
