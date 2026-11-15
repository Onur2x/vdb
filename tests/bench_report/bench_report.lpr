program bench_report;
{ VDB V3 sertlestirme - SKILL2 §22 kapisi: BENCHMARK + YUZDELIKLER + REGRESYON.

Amac: §22.1'de sayilan 18 kategoriyi TEKRARLANABILIR bicimde olcup
§22.2'deki metrikleri raporlamak, §22.3'teki tekrarlanabilirlik bilgilerini
yazmak ve §22.4 icin regresyon esiklerini tanimlamak.

Neden ayri kapi: `perf_baseline` yalnizca B+Tree ekleme/arama/silme + SQL
ekleme/nokta okuma olcuyordu; acilis, kapanis, rastgele ekleme/okuma,
guncelleme, silme, indeks olusturma, indeksli arama, aralik sorgusu, islem,
eszamanli islem, WAL kurtarma, checkpoint, yedek ve geri yukleme olculmuyordu.
Yuzdelikler (P50/P95/P99), bellek, DB/WAL boyu ve onbellek isabet orani da
raporlanmiyordu.

Durust sinirlar (kapiyi kandirmamak icin acikca yazilir):
  - Sureler MAKINEYE BAGLIDIR. Bu kapi sureleri KARSILASTIRMAZ; yalnizca
    olcup raporlar ve ucuz/patolojik bozunmayi yakalayan GENIS tavanlara
    bakar. Mutlak sayilar PERF_BASELINE.md / bench_report.csv'de saklanir.
  - "Eszamanli islem" kategorisi AYNI SURECTE iki ayri oturum kullanir;
    motorun islem basina yazma kilidiyle SIRAYA girer. Gercek isletim
    sistemi paralelligi `multiproc` kapisinin konusudur.
  - "WAL kurtarma" kategorisi, checkpoint edilmemis WAL'i olan bir dosyayi
    IKINCI oturumun acmasini olcer (acilista WAL yeniden oynatilir). Kurtarma
    VERININ gorunur oldugu ile dogrulanir; ayni surec icinde olcumdur.
  - CPU kullanimi olculmez: platforma ozgu API (Windows GetProcessTimes /
    Linux /proc) gerekir; tasinabilir bir yol olmadigi icin "olculmedi"
    olarak raporlanir. Uydurulmus bir sayi yazilmaz.
  - Bellek olcumu FPC yigin durumudur (GetFPCHeapStatus.CurrHeapUsed);
    isletim sisteminin RSS degeri degildir.

Cikti: OLCUM satirlari (parser dostu), META satirlari, bench_report.csv,
bench_meta.txt. Cikis kodu = basarisiz kontrol sayisi.

Derleme: fpc (lpi gerekmez).
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbPage, VDbErr;

const
  N_ROWS   = 1000;   // ana veri kumesi (sirali ekleme)
  N_RND    = 1000;   // rastgele ekleme
  N_READ   = 500;    // nokta okuma turu
  N_UPD    = 300;    // guncelleme
  N_DEL    = 200;    // silme
  N_TX     = 15;     // islem sayisi
  N_TXROWS = 20;     // islem basina satir
  N_CONC   = 12;     // eszamanli islem turu
  N_OPEN   = 6;      // acilis/kapanis ornegi
  N_CKPT   = 3;      // checkpoint / yedek / geri yukleme ornegi
  N_RANGE  = 200;    // aralik sorgusu
  N_IDXQ   = 300;    // indeksli arama
  REC_ROWS = 60;     // WAL kurtarma verisi
  RND_BASE = 100000; // rastgele id tabani (sirali id'lerle cakismaz)
  CEIL_MS  = 300000; // 5 dk: yalnizca "asiri yavas/hang" tavani

{$IFDEF UNIX}
const
  CLOCK_MONOTONIC = 1;
function clock_gettime(clk_id: LongInt; tp: Pointer): LongInt; cdecl; external 'c';
{$ENDIF}

type
  TUsArray = array of QWord;

  TSample = class
  public
    Name: string;
    Lats: array of QWord;   // islem basina mikrosaniye
    procedure Add(AUs: QWord);
    function Count: Integer;
    function TotalUs: QWord;
    function MaxUs: QWord;
    function AvgUs: Double;
    function Pct(AP: Double): QWord;
    function OpsPerSec: Double;
    function Sorted: TUsArray;
  end;

var
  GPass, GFail: Integer;
  GSeed: LongWord;
  GRoot, GDir, GDbFile: string;
  GBe: IVdbBackend;
  GBeC: TVdbBackendV3;
  GTb: TVTableDb;
  GSq: TVSql;
  GAll: TList;
  GMeta: TStringList;
  GCsv: TStringList;

function MkVal(AKey: Integer): string; forward;

{ ------------------------------------------------------------------ arac }

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
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

procedure Info(const S: string);
begin
  WriteLn('BILGI ', S);
  Flush(Output);
end;

procedure Meta(const S: string);
begin
  WriteLn('META ', S);
  GMeta.Add(S);
end;

function NextRand(AMax: Integer): Integer;
begin
  GSeed := (GSeed * 1103515245 + 12345) and $7FFFFFFF;
  Result := Integer(GSeed mod LongWord(AMax));
end;

function NowUs: QWord;
{$IFDEF UNIX}
var
  ts: record
    sec: Int64;
    nsec: Int64;
  end;
begin
  { clock_gettime(CLOCK_MONOTONIC): glibc'te libc icinde; ayri bir bagimlilik
    yok. BaseUnix'in fpgettimeofday'i bu FPC surumunde yok. }
  if clock_gettime(CLOCK_MONOTONIC, @ts) <> 0 then
    Exit(0);
  Result := QWord(ts.sec) * 1000000 + QWord(ts.nsec) div 1000;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  c, f: Int64;
begin
  if not QueryPerformanceFrequency(f) then
    Exit(0);
  QueryPerformanceCounter(c);
  if f <= 0 then
    Exit(0);
  Result := QWord(c) * 1000000 div QWord(f);
end;
{$ENDIF}

function FileLenOf(const APath: string): Int64;
var
  fs: TFileStream;
begin
  Result := 0;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

{ `.gen` dosyasinin 0 ofsetindeki sayaci (yoksa -1) okur. }
function GenFileOf(const ADbPath: string): Int64;
var
  fs: TFileStream;
  v: QWord;
begin
  Result := -1;
  if not FileExists(ADbPath + '.gen') then Exit;
  fs := TFileStream.Create(ADbPath + '.gen', fmOpenRead or fmShareDenyNone);
  try
    if fs.Size < 8 then Exit;
    fs.Position := 0;
    fs.ReadBuffer(v, 8);
    Result := Int64(v);
  finally
    fs.Free;
  end;
end;

procedure WipeDir(const ADir: string);
var
  d: string;
  sr: TSearchRec;
begin
  d := IncludeTrailingPathDelimiter(ADir);
  ForceDirectories(d);
  if FindFirst(d + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(d + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function FreshDir(const AName: string): string;
var
  base: string;
begin
  { Gecici dizin: DrvFs/9p uzerinde dosya boyu degistirme (SetSize) hata
    verebiliyor; olcum yerel gecici dosya sisteminde yapilir. }
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'vdb_bench_' +
    IntToStr(GetProcessID);
  ForceDirectories(base);
  Result := IncludeTrailingPathDelimiter(base) + AName;
  WipeDir(Result);
end;

{ --------------------------------------------------------------- TSample }

procedure TSample.Add(AUs: QWord);
var
  n: Integer;
begin
  n := Length(Lats);
  SetLength(Lats, n + 1);
  Lats[n] := AUs;
end;

function TSample.Count: Integer;
begin
  Result := Length(Lats);
end;

function TSample.TotalUs: QWord;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Lats) do
    Inc(Result, Lats[i]);
end;

function TSample.MaxUs: QWord;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Lats) do
    if Lats[i] > Result then Result := Lats[i];
end;

function TSample.AvgUs: Double;
begin
  if Length(Lats) = 0 then Exit(0);
  Result := TotalUs / Length(Lats);
end;

function TSample.Sorted: TUsArray;
var
  i, j: Integer;
  t: QWord;
begin
  Result := Copy(Lats, 0, Length(Lats));
  { Kucuk diziler icin basit ekleme siralamasi yeterli ve deterministik. }
  for i := 1 to High(Result) do
  begin
    t := Result[i];
    j := i - 1;
    while (j >= 0) and (Result[j] > t) do
    begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := t;
  end;
end;

function TSample.Pct(AP: Double): QWord;
var
  a: array of QWord;
  k: Integer;
begin
  Result := 0;
  a := Sorted;
  if Length(a) = 0 then Exit;
  k := Round(AP * (Length(a) - 1));
  if k < 0 then k := 0;
  if k > High(a) then k := High(a);
  Result := a[k];
end;

function TSample.OpsPerSec: Double;
var
  tot: QWord;
begin
  tot := TotalUs;
  if tot = 0 then Exit(0);
  Result := Length(Lats) * 1000000 / tot;
end;

function NewSample(const AName: string): TSample;
begin
  Result := TSample.Create;
  Result.Name := AName;
  GAll.Add(Result);
end;

procedure Emit(S: TSample);
begin
  WriteLn('OLCUM ', S.Name, ' ops=', S.Count, ' us=', S.TotalUs,
    Format(' ops_s=%.1f avg_us=%.1f', [S.OpsPerSec, S.AvgUs]),
    ' p50=', S.Pct(0.50), ' p95=', S.Pct(0.95), ' p99=', S.Pct(0.99),
    ' max_us=', S.MaxUs);
  Flush(Output);
end;

{ Bir kategorinin yuzdelik tutarliligi: p50 <= p95 <= p99 <= max ve
  ortalama max'i asmaz. Bozuk toplama/siralama burada yakalanir. }
function PctOk(S: TSample): Boolean;
var
  p50, p95, p99, mx: QWord;
  av: Double;
begin
  p50 := S.Pct(0.50);
  p95 := S.Pct(0.95);
  p99 := S.Pct(0.99);
  mx := S.MaxUs;
  av := S.AvgUs;
  Result := (S.Count > 0) and (p50 <= p95) and (p95 <= p99) and
    (p99 <= mx) and (av <= mx + 0.5);
end;

{ ------------------------------------------------------------ oturum(lar) }

{ Bir dizindeki veritabani dosyasi: motor dosya yolu bekler, tablo katalogu
  dizin bekler. Ikisini tek yerden turet. }
function DbInDir(const ADir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + 'veritabani.odb';
end;

function OpenRW(const APath: string; out ABe: IVdbBackend;
  out ATb: TVTableDb): Boolean;
begin
  Result := False;
  ABe := nil;
  ATb := nil;
  try
    VdbOpen(DbInDir(APath), ABe, True, False);
    ATb := TVTableDb.CreateBackend(ABe);
    ATb.Open(APath);
    Result := True;
  except
    on E: Exception do
    begin
      Info('acilis hatasi: ' + E.ClassName + ': ' + E.Message);
      ATb := nil;
      ABe := nil;
    end;
  end;
end;

{ -------------------------------------------------------------- 1..3 acilis }

procedure BenchLifecycle;
var
  SNew, SOpen, SClose: TSample;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i, okN: Integer;
  d: string;
  t: QWord;
  r: TSqlResult;
begin
  SNew := NewSample('creation');
  SOpen := NewSample('opening');
  SClose := NewSample('closing');

  { (1) Veritabani olusturma: yeni dosya + katalog. }
  for i := 1 to 3 do
  begin
    d := FreshDir('life' + IntToStr(i));
    t := NowUs;
    if OpenRW(d, Be, Tb) then
    begin
      Sq := TVSql.Create(Tb);
      try
        Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        SNew.Add(NowUs - t);
      finally
        FreeAndNil(Sq);
      end;
      FreeAndNil(Tb);
      Be := nil;
    end;
  end;
  Emit(SNew);

  { (2) Acilis, (3) kapanis: ayni veritabani N_OPEN kez acilip kapatilir. }
  if OpenRW(GDir, Be, Tb) then
  begin
    GDbFile := Be.FilePath;
    Sq := TVSql.Create(Tb);
    Sq.Exec('CREATE TABLE lc (id INTEGER PRIMARY KEY, v TEXT)');
    Sq.Exec('INSERT INTO lc (id, v) VALUES (1, ''acilis'')');
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
  end;

  okN := 0;
  for i := 1 to N_OPEN do
  begin
    t := NowUs;
    if OpenRW(GDir, Be, Tb) then
    begin
      Inc(okN);
      SOpen.Add(NowUs - t);
      t := NowUs;
      FreeAndNil(Tb);
      Be := nil;
      SClose.Add(NowUs - t);
    end;
  end;
  Emit(SOpen);
  Emit(SClose);
  Chk('BR1 acilis ornekleri toplandi', SOpen.Count = N_OPEN,
    IntToStr(SOpen.Count) + '/' + IntToStr(N_OPEN));
  Chk('BR1 kapanis ornekleri toplandi', SClose.Count = N_OPEN,
    IntToStr(SClose.Count) + '/' + IntToStr(N_OPEN));
  Chk('BR1 olusturma ornekleri toplandi', SNew.Count = 3,
    IntToStr(SNew.Count) + '/3');
  Chk('BR1 acilis/kapanis zaman asimi yok',
    (SOpen.MaxUs <= QWord(CEIL_MS) * 1000) and
    (SClose.MaxUs <= QWord(CEIL_MS) * 1000),
    'acilis_max_us=' + IntToStr(SOpen.MaxUs) +
    ' kapanis_max_us=' + IntToStr(SClose.MaxUs));

  { Acilis gercekten veriyi goruyor mu (bos dosya acmak hile olurdu). }
  r := Default(TSqlResult);
  okN := -1;
  if OpenRW(GDir, Be, Tb) then
  begin
    Sq := TVSql.Create(Tb);
    try
      r := Sq.Exec('SELECT COUNT(*) FROM lc');
      if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
        okN := StrToIntDef(r.Rows[0][0], -1);
    finally
      FreeAndNil(Sq);
      FreeAndNil(Tb);
      Be := nil;
    end;
  end;
  Chk('BR1 acilan veritabani veriyi goruyor', okN = 1, 'lc=' + IntToStr(okN));
end;

{ --------------------------------------------------- 4..7 ekleme ve okuma }

function SeqInsert(S: TSample; ACount: Integer): Boolean;
var
  i: Integer;
  t: QWord;
begin
  Result := False;
  for i := 1 to ACount do
  begin
    t := NowUs;
    try
      GSq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
        MkVal(i) + ''')');
      S.Add(NowUs - t);
    except
      on E: Exception do
      begin
        Info('sirali ekleme hatasi i=' + IntToStr(i) + ' ' + E.Message);
        Exit;
      end;
    end;
  end;
  Result := True;
end;

function MkVal(AKey: Integer): string;
var
  i: Integer;
begin
  SetLength(Result, 24);
  for i := 1 to Length(Result) do
    Result[i] := Chr(Ord('a') + ((AKey + i) mod 26));
end;

function RandInsert(S: TSample; ACount: Integer): Boolean;
var
  i, id: Integer;
  t: QWord;
begin
  Result := False;
  for i := 1 to ACount do
  begin
    id := RND_BASE + NextRand(1000000);
    t := NowUs;
    try
      GSq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(id) + ', ''' +
        MkVal(id) + ''')');
      S.Add(NowUs - t);
    except
      on E: Exception do
      begin
        { Cakisma olasiligi var: benzersiz bir id ile tekrar dene. }
        try
          GSq.Exec('INSERT INTO t (id, v) VALUES (' +
            IntToStr(RND_BASE + 900000 + i) + ', ''' + MkVal(i) + ''')');
          S.Add(NowUs - t);
        except
          on E2: Exception do
          begin
            Info('rastgele ekleme hatasi i=' + IntToStr(i) + ' ' + E2.Message);
            Exit;
          end;
        end;
      end;
    end;
  end;
  Result := True;
end;

function SeqRead(S: TSample; ACount: Integer): Integer;
var
  i, ok: Integer;
  t: QWord;
  r: TSqlResult;
begin
  ok := 0;
  for i := 1 to ACount do
  begin
    t := NowUs;
    r := GSq.Exec('SELECT v FROM t WHERE id = ' + IntToStr(i));
    S.Add(NowUs - t);
    if (Length(r.Rows) = 1) and (r.Rows[0][0] = MkVal(i)) then Inc(ok);
  end;
  Result := ok;
end;

function RandRead(S: TSample; ACount: Integer): Integer;
var
  i, id, ok: Integer;
  t: QWord;
  r: TSqlResult;
begin
  ok := 0;
  for i := 1 to ACount do
  begin
    id := 1 + NextRand(N_ROWS);
    t := NowUs;
    r := GSq.Exec('SELECT v FROM t WHERE id = ' + IntToStr(id));
    S.Add(NowUs - t);
    if Length(r.Rows) = 1 then Inc(ok);
  end;
  Result := ok;
end;

{ ------------------------------------- 8..10 guncelleme / silme / indeks }

function UpdateRows(S: TSample; ACount: Integer): Integer;
var
  i, id, ok: Integer;
  t: QWord;
  r: TSqlResult;
begin
  ok := 0;
  for i := 1 to ACount do
  begin
    id := 1 + NextRand(N_ROWS);
    t := NowUs;
    r := GSq.Exec('UPDATE t SET v = ''u' + IntToStr(i) + ''' WHERE id = ' +
      IntToStr(id));
    S.Add(NowUs - t);
    if r.Affected = 1 then Inc(ok);
  end;
  Result := ok;
end;

function DeleteRows(S: TSample; ACount: Integer): Integer;
var
  i, id, ok: Integer;
  t: QWord;
  r: TSqlResult;
begin
  ok := 0;
  for i := 1 to ACount do
  begin
    id := 1 + NextRand(N_ROWS);
    t := NowUs;
    r := GSq.Exec('DELETE FROM t WHERE id = ' + IntToStr(id));
    S.Add(NowUs - t);
    if r.Affected <= 1 then Inc(ok);
  end;
  Result := ok;
end;

{ --------------------------------------- 11..12 indeksli arama ve aralik }

function IndexLookup(S: TSample; ACount: Integer): Integer;
var
  i, ok: Integer;
  t: QWord;
  r: TSqlResult;
begin
  { Kendi satirlarini kur: guncelleme/silme asamalarinin hangi id'leri
    biraktigina bagimli olmadan indeksli arama olculur. Eklenemeyen satir
    varsa sessizce yutulmaz; sayilir ve asagidaki kontrolu dusurur.
    v3.36 DUZELTME: id tabani 2000000. Eski taban 300000 BR5 rastgele
    ekleme araligiyla (RND_BASE..RND_BASE+1e6) CAKISIYORDU: ayni id daha
    once eklenmis olabiliyor, "duplicate PK" olcumu yanlis yere yaziyordu
    (olculen: i=296, id 300296 zaten BR5'te vardi). }
  for i := 1 to ACount do
  begin
    try
      GSq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(2000000 + i) +
        ', ''ix' + IntToStr(i) + ''')');
    except
      on E: Exception do
        Info('indeks satiri eklenemedi i=' + IntToStr(i) + ' ' +
          E.ClassName + ': ' + E.Message);
    end;
  end;
  r := GSq.Exec('SELECT COUNT(*) FROM t WHERE v LIKE ''ix%''');
  Info('indeks satiri sayisi=' + Trim(r.Rows[0][0]) + '/' + IntToStr(ACount));
  ok := 0;
  for i := 1 to ACount do
  begin
    t := NowUs;
    r := GSq.Exec('SELECT id FROM t WHERE v = ''ix' + IntToStr(i) + '''');
    S.Add(NowUs - t);
    if Length(r.Rows) >= 1 then Inc(ok);
  end;
  Result := ok;
end;

function RangeQuery(S: TSample; ACount: Integer): Integer;
var
  i, lo, ok: Integer;
  t: QWord;
  r: TSqlResult;
  cnt: Int64;
begin
  ok := 0;
  for i := 1 to ACount do
  begin
    lo := 1 + NextRand(1500);
    t := NowUs;
    r := GSq.Exec('SELECT id FROM t WHERE id BETWEEN ' + IntToStr(lo) +
      ' AND ' + IntToStr(lo + 40) + ' ORDER BY id');
    S.Add(NowUs - t);
    cnt := Length(r.Rows);
    if (cnt >= 0) and (cnt <= 41) then Inc(ok);
  end;
  Result := ok;
end;

{ ------------------------------------------------ 13..14 islemler (tx) }

function TxBench(S: TSample; ACount, ARows, ABase: Integer): Integer;
var
  i, j, ok: Integer;
  t: QWord;
begin
  ok := 0;
  for i := 1 to ACount do
  begin
    t := NowUs;
    try
      GSq.Exec('BEGIN');
      for j := 1 to ARows do
        GSq.Exec('INSERT INTO tx (id, v) VALUES (' +
          IntToStr(ABase + (i - 1) * ARows + j) + ', ''' + MkVal(j) + ''')');
      GSq.Exec('COMMIT');
      S.Add(NowUs - t);
      Inc(ok);
    except
      on E: Exception do
      begin
        Info('islem hatasi i=' + IntToStr(i) + ' ' + E.Message);
        try
          GSq.Exec('ROLLBACK');
        except
          { yutulur: kapi zaten basarisiz }
        end;
        Exit;
      end;
    end;
  end;
  Result := ok;
end;

{ -------------------------------------------------- 15 WAL kurtarma }

function WalRecovery(S: TSample): Boolean;
var
  d, p, wal: string;
  BeA, BeB: IVdbBackend;
  TbA, TbB: TVTableDb;
  SqA, SqB: TVSql;
  i, okN: Integer;
  t: QWord;
  sz: Int64;
  r: TSqlResult;
begin
  Result := False;
  d := FreshDir('walrec');
  BeA := nil;
  TbA := nil;
  SqA := nil;
  BeB := nil;
  TbB := nil;
  SqB := nil;
  try
    if not OpenRW(d, BeA, TbA) then Exit;
    p := BeA.FilePath;
    wal := p + '.wal';
    SqA := TVSql.Create(TbA);
    SqA.Exec('CREATE TABLE r (id INTEGER PRIMARY KEY, v TEXT)');
    for i := 1 to REC_ROWS do
      SqA.Exec('INSERT INTO r (id, v) VALUES (' + IntToStr(i) + ', ''' +
        MkVal(i) + ''')');
    { Birinci oturum HALA ACIK: checkpoint yapilmadi, WAL dolu olmali. }
    sz := FileLenOf(wal);
    Chk('BR15 kurtarilacak WAL dolu', sz > 0, 'wal_bayt=' + IntToStr(sz));

    { Ikinci oturum ayni dosyayi acar: acilista WAL yeniden oynatilir. }
    t := NowUs;
    VdbOpen(p, BeB, False, False);
    TbB := TVTableDb.CreateBackend(BeB);
    TbB.Open(ExtractFileDir(p));
    S.Add(NowUs - t);

    SqB := TVSql.Create(TbB);
    r := SqB.Exec('SELECT COUNT(*) FROM r');
    okN := -1;
    if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
      okN := StrToIntDef(r.Rows[0][0], -1);
    Chk('BR15 WAL yeniden oynatildi (ikinci oturum veriyi gordu)',
      okN = REC_ROWS, 'satir=' + IntToStr(okN) + '/' + IntToStr(REC_ROWS));
    Result := True;
  except
    on E: Exception do
      Info('WAL kurtarma hatasi: ' + E.ClassName + ': ' + E.Message);
  end;
  FreeAndNil(SqB);
  FreeAndNil(TbB);
  BeB := nil;
  FreeAndNil(SqA);
  FreeAndNil(TbA);
  BeA := nil;
end;

{ ------------------------------------- 16..18 checkpoint / yedek / geri }

function CheckpointBench(S: TSample): Integer;
var
  i, ok: Integer;
  t: QWord;
begin
  ok := 0;
  for i := 1 to N_CKPT do
  begin
    GSq.Exec('INSERT INTO ck (id, v) VALUES (' + IntToStr(i) + ', ''x'')');
    t := NowUs;
    if GBeC.Engine.Checkpoint(True) then Inc(ok);
    S.Add(NowUs - t);
  end;
  Result := ok;
end;

function BackupBench(S: TSample; out ABkPath: string): Integer;
var
  i, ok: Integer;
  t: QWord;
  rep: string;
begin
  ok := 0;
  ABkPath := IncludeTrailingPathDelimiter(GDir) + 'yedek.odb';
  for i := 1 to N_CKPT do
  begin
    SysUtils.DeleteFile(ABkPath);
    t := NowUs;
    try
      GBe.BackupTo(ABkPath);
      S.Add(NowUs - t);
      if FileExists(ABkPath) and GBe.VerifyBackup(ABkPath, rep) then Inc(ok);
    except
      on E: Exception do
        Info('yedek hatasi: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
  Result := ok;
end;

function RestoreBench(S: TSample; const ABkPath: string): Integer;
var
  i, ok: Integer;
  t: QWord;
begin
  ok := 0;
  for i := 1 to N_CKPT do
  begin
    t := NowUs;
    try
      GBe.RestoreFrom(ABkPath);
      S.Add(NowUs - t);
      Inc(ok);
    except
      on E: Exception do
        Info('geri yukleme hatasi: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
  Result := ok;
end;

{ Yeniden acma: taze anlik goruntu. Baska bir oturumun commit'lerini gormek
  icin oturum kapatilip yeniden acilir (motorun belgelenmis davranisi). }
procedure ReopenMain;
begin
  FreeAndNil(GSq);
  FreeAndNil(GTb);
  GBe := nil;
  GBeC := nil;
  GBeC := TVdbBackendV3.Create(DbInDir(GDir));
  GBe := GBeC;
  GTb := TVTableDb.CreateBackend(GBe);
  GTb.Open(GDir);
  GSq := TVSql.Create(GTb);
end;

{ ------------------------------------------------------------------ ana }

var
  SSeqIns, SRndIns, SSeqRead, SRndRead, SUpd, SDel, SIdx, SIdxQ, SRange,
  STx, SConc, SWal, SCkpt, SBk, SRest: TSample;
  bkPath, csv, metaf: string;
  i, ok, pk: Integer;
  okB: Boolean;
  cs: TVdbCacheStats;
  hs: TFPCHeapStatus;
  okN: Integer;
  tot, hits, miss: Int64;
  ratio: Double;
  dbsz, walsz: Int64;
  r: TSqlResult;
  r2: TSqlResult;
  rt: TSqlResult;
  kid: Integer;
  sid: string;
  Be2: IVdbBackend;
  Tb2: TVTableDb;
  Sq2: TVSql;
  t: QWord;
  why: string;
begin
  GPass := 0;
  GFail := 0;
  GSeed := 20251115;
  GAll := TList.Create;
  GMeta := TStringList.Create;

  GDir := FreshDir('main');
  GBeC := nil;
  GBe := nil;
  GTb := nil;
  try
    GBeC := TVdbBackendV3.Create(DbInDir(GDir));
    GBe := GBeC;
    GTb := TVTableDb.CreateBackend(GBe);
    GTb.Open(GDir);
  except
    on E: Exception do
    begin
      WriteLn('FAIL BR0 ana veritabani acilamadi ', GDir, ' ', E.Message);
      WriteLn;
      WriteLn('SONUC: 0 PASS, 1 FAIL');
      Halt(1);
    end;
  end;
  GDbFile := GBe.FilePath;
  Info('BR0 gen@acilis=' + IntToStr(GenFileOf(GDbFile)) +
    ' bayt=' + IntToStr(FileLenOf(GDbFile + '.gen')));
  GSq := TVSql.Create(GTb);
  GSq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  GSq.Exec('CREATE TABLE tx (id INTEGER PRIMARY KEY, v TEXT)');
  GSq.Exec('CREATE TABLE ck (id INTEGER PRIMARY KEY, v TEXT)');

  Meta('dataset_rows=' + IntToStr(N_ROWS + N_RND) +
    ' read_ops=' + IntToStr(N_READ) + ' update_ops=' + IntToStr(N_UPD) +
    ' delete_ops=' + IntToStr(N_DEL) + ' tx=' + IntToStr(N_TX) + 'x' +
    IntToStr(N_TXROWS));
  Meta('os=' + {$I %FPCTARGETOS%} + ' cpu=' + {$I %FPCTARGETCPU%});
  Meta('compiler=FPC ' + {$I %FPCVERSION%});
  Meta('build=-MObjFPC -Scghi -O1 -g (tests/run_gates.sh)');
  Meta('db=page_size=4096 pool_pages=' + IntToStr(GBe.GetCacheStats.PoolPages) +
    ' durable_on_flush=' + BoolToStr(GBe.DurableOnFlush, True) +
    ' exclusive=' + BoolToStr(GBe.ExclusiveAccess, True));
  Meta('tx_settings=autocommit per statement; explicit BEGIN/COMMIT for islem');
  Meta('procedure=ayni surec, tek dosya; her kategori icin islem basina us');
  Meta('cpu_usage=olculmedi (tasinabilir API yok)');
  Meta('wal_path=' + GDbFile + '.wal');

  { 1-3: olusturma / acilis / kapanis }
  BenchLifecycle;
  Info('BR0 gen@lifecycle=' + IntToStr(GenFileOf(GDbFile)) +
    ' bayt=' + IntToStr(FileLenOf(GDbFile + '.gen')));

  { 4-7 }
  SSeqIns := NewSample('seq_insert');
  okB := SeqInsert(SSeqIns, N_ROWS);
  Emit(SSeqIns);
  Chk('BR4 sirali ekleme tamamlandi', okB and (SSeqIns.Count = N_ROWS),
    'adet=' + IntToStr(SSeqIns.Count) + '/' + IntToStr(N_ROWS));

  SRndIns := NewSample('rnd_insert');
  okB := RandInsert(SRndIns, N_RND);
  Emit(SRndIns);
  Chk('BR5 rastgele ekleme tamamlandi', okB and (SRndIns.Count = N_RND),
    'adet=' + IntToStr(SRndIns.Count) + '/' + IntToStr(N_RND));

  SSeqRead := NewSample('seq_read');
  ok := SeqRead(SSeqRead, N_READ);
  Emit(SSeqRead);
  Chk('BR6 sirali nokta okuma dogru', ok = N_READ,
    IntToStr(ok) + '/' + IntToStr(N_READ));

  SRndRead := NewSample('rnd_read');
  ok := RandRead(SRndRead, N_READ);
  Emit(SRndRead);
  Chk('BR7 rastgele nokta okuma bulundu', ok = N_READ,
    IntToStr(ok) + '/' + IntToStr(N_READ));

  { 8-9 }
  SUpd := NewSample('update');
  ok := UpdateRows(SUpd, N_UPD);
  Emit(SUpd);
  Chk('BR8 guncelleme bir satiri etkiledi', ok = N_UPD,
    IntToStr(ok) + '/' + IntToStr(N_UPD));

  SDel := NewSample('delete');
  ok := DeleteRows(SDel, N_DEL);
  Emit(SDel);
  Chk('BR9 silme calisti', ok = N_DEL, IntToStr(ok) + '/' + IntToStr(N_DEL));
  Info('BR0 gen@silme=' + IntToStr(GenFileOf(GDbFile)) +
    ' bayt=' + IntToStr(FileLenOf(GDbFile + '.gen')));

  { 10 indeks olusturma: tek ornek, olcum degeri bilgi amaclidir. }
  SIdx := NewSample('index_create');
  t := NowUs;
  GSq.Exec('CREATE INDEX ix_v ON t (v)');
  SIdx.Add(NowUs - t);
  Emit(SIdx);
  Chk('BR10 indeks olusturuldu', SIdx.Count = 1,    'us=' + IntToStr(SIdx.TotalUs));

  { 11 indeksli arama }
  SIdxQ := NewSample('indexed_lookup');
  ok := IndexLookup(SIdxQ, N_IDXQ);
  Emit(SIdxQ);
  Chk('BR11 indeksli arama sonuc dondurdu', ok = N_IDXQ,
    IntToStr(ok) + '/' + IntToStr(N_IDXQ));

  { 12 aralik sorgusu }
  SRange := NewSample('range_query');
  ok := RangeQuery(SRange, N_RANGE);
  Emit(SRange);
  Chk('BR12 aralik sorgusu beklenen satir araliginda', ok = N_RANGE,
    IntToStr(ok) + '/' + IntToStr(N_RANGE));

  { 13 islem }
  STx := NewSample('transaction');
  ok := TxBench(STx, N_TX, N_TXROWS, 1);
  Emit(STx);
  Chk('BR13 islemler commit edildi', ok = N_TX,
    IntToStr(ok) + '/' + IntToStr(N_TX));
  r := GSq.Exec('SELECT COUNT(*) FROM tx');
  okN := -1;
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    okN := StrToIntDef(r.Rows[0][0], -1);
  Chk('BR13 commit edilen satirlar kalici', okN = N_TX * N_TXROWS,
    'satir=' + IntToStr(okN) + '/' + IntToStr(N_TX * N_TXROWS));

  { 14 eszamanli islem: ayni dosyada IKINCI oturum, islem basina yazma
    kilidiyle siraya girer (gercek OS paralelligi `multiproc` kapsami). }
  SConc := NewSample('concurrent_tx');
  Be2 := nil;
  Tb2 := nil;
  Sq2 := nil;
  pk := 0;
  GBeC.Engine.Checkpoint(True);
  Info('BR14 B acilmadan: genMmapA=' + IntToStr(GBe.StoreGenStamp) +
    ' genDosya=' + IntToStr(GenFileOf(GDbFile)) +
    ' genbayt=' + IntToStr(FileLenOf(GDbFile + '.gen')) +
    ' wal=' + IntToStr(FileLenOf(GDbFile + '.wal')));
  try
    VdbOpen(GDbFile, Be2, False, False);
    Info('BR14 B acildi: genMmapB=' + IntToStr(Be2.StoreGenStamp) +
      ' genDosya=' + IntToStr(GenFileOf(GDbFile)));
    Tb2 := TVTableDb.CreateBackend(Be2);
    Tb2.Open(ExtractFileDir(GDbFile));
    Sq2 := TVSql.Create(Tb2);
    for i := 1 to N_CONC do
    begin
      t := NowUs;
      if Odd(i) then
      begin
        GSq.Exec('BEGIN');
        GSq.Exec('INSERT INTO tx (id, v) VALUES (' +
          IntToStr(20000 + i) + ', ''p'')');
        Info('BR14 A insert sonrasi wal=' + IntToStr(FileLenOf(GDbFile + '.wal')));
        GSq.Exec('COMMIT');
        Info('BR14 A commit sonrasi wal=' + IntToStr(FileLenOf(GDbFile + '.wal')));
        rt := GSq.Exec('SELECT COUNT(*) FROM tx WHERE v = ''p''');
        Info('BR14 A gorunen p=' + rt.Rows[0][0] + ' inbatch=' +
          BoolToStr(GBe.InBatch, True) + ' dirty=' + BoolToStr(GBe.Dirty, True));
      end
      else
      begin
        Sq2.Exec('BEGIN');
        Sq2.Exec('INSERT INTO tx (id, v) VALUES (' +
          IntToStr(20000 + i) + ', ''q'')');
        Info('BR14 B insert sonrasi wal=' + IntToStr(FileLenOf(GDbFile + '.wal')));
        Sq2.Exec('COMMIT');
        Info('BR14 B commit sonrasi wal=' + IntToStr(FileLenOf(GDbFile + '.wal')));
      end;
      SConc.Add(NowUs - t);
      Inc(pk);
      Info('BR14 i=' + IntToStr(i) + ' genA=' + IntToStr(GBe.StoreGenStamp) +
        ' genB=' + IntToStr(Be2.StoreGenStamp) +
        ' stampA=' + IntToStr(GBe.DataStamp) +
        ' stampB=' + IntToStr(Be2.DataStamp) +
        ' wal=' + IntToStr(FileLenOf(GDbFile + '.wal')));
    end;
  except
    on E: Exception do
      Info('eszamanli islem hatasi: ' + E.ClassName + ': ' + E.Message);
  end;
  FreeAndNil(Sq2);
  FreeAndNil(Tb2);
  Be2 := nil;
  Emit(SConc);
  Chk('BR14 iki oturum sirayla commit etti', pk = N_CONC,
    IntToStr(pk) + '/' + IntToStr(N_CONC));
  { Ikinci oturumun commit'leri bu oturumun anlik goruntusunde degildi;
    kalicilik kontrolu TAZE oturumla yapilir. }
  ReopenMain;
  r := GSq.Exec('SELECT COUNT(*) FROM tx WHERE id >= 20000');
  okN := -1;
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    okN := StrToIntDef(r.Rows[0][0], -1);
  begin
    r2 := GSq.Exec('SELECT id, v FROM tx WHERE v IN (''p'', ''q'') ORDER BY id');
    sid := '';
    for kid := 0 to Length(r2.Rows) - 1 do
      sid := sid + r2.Rows[kid][0] + r2.Rows[kid][1] + ' ';
    Info('eszamanli kayitli satirlar: ' + sid);
  end;
  Chk('BR14 eszamanli satirlar kalici', okN = N_CONC,
    'satir=' + IntToStr(okN) + '/' + IntToStr(N_CONC));

  { 15 WAL kurtarma }
  SWal := NewSample('wal_recovery');
  WalRecovery(SWal);
  Emit(SWal);
  Chk('BR15 kurtarma suresi olculdu', SWal.Count = 1,
    'us=' + IntToStr(SWal.TotalUs));

  { 16 checkpoint }
  SCkpt := NewSample('checkpoint');
  ok := CheckpointBench(SCkpt);
  Emit(SCkpt);
  Chk('BR16 checkpoint tamamlandi', ok = N_CKPT,
    IntToStr(ok) + '/' + IntToStr(N_CKPT));
  walsz := FileLenOf(GDbFile + '.wal');
  { Checkpoint sonrasi WAL yalnizca basligi (4096 bayt) tutabilir; sifir
    beklemek yanlisti (olculdu: 4096). Onemli olan govde/cerceve kalmamasi. }
  Chk('BR16 checkpoint sonrasi WAL govdesi bosaldi', walsz <= VDB_PAGE_SIZE,
    'wal_bayt=' + IntToStr(walsz));

  { 17 yedek }
  SBk := NewSample('backup');
  ok := BackupBench(SBk, bkPath);
  Emit(SBk);
  Chk('BR17 yedek alindi ve dogrulandi', ok = N_CKPT,
    IntToStr(ok) + '/' + IntToStr(N_CKPT));

  { Yedekteki veri ana veritabaniyla ayni mi (olcum degil, dogruluk). }
  okN := -1;
  if FileExists(bkPath) then
  begin
    VdbOpen(bkPath, Be2, False, False);
    Tb2 := TVTableDb.CreateBackend(Be2);
    Tb2.Open(ExtractFileDir(bkPath));
    Sq2 := TVSql.Create(Tb2);
    r := Sq2.Exec('SELECT COUNT(*) FROM tx');
    if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
      okN := StrToIntDef(r.Rows[0][0], -1);
    FreeAndNil(Sq2);
    FreeAndNil(Tb2);
    Be2 := nil;
  end;
  Chk('BR17 yedekteki islem satirlari tam', okN = N_TX * N_TXROWS + N_CONC,
    'satir=' + IntToStr(okN) + '/' + IntToStr(N_TX * N_TXROWS + N_CONC));

  { 18 geri yukleme }
  SRest := NewSample('restore');
  ok := RestoreBench(SRest, bkPath);
  Emit(SRest);
  Chk('BR18 geri yukleme calisti', ok = N_CKPT,
    IntToStr(ok) + '/' + IntToStr(N_CKPT));
  r := GSq.Exec('SELECT COUNT(*) FROM tx');
  okN := -1;
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    okN := StrToIntDef(r.Rows[0][0], -1);
  Chk('BR18 geri yukleme sonrasi veri korundu', okN = N_TX * N_TXROWS + N_CONC,
    'satir=' + IntToStr(okN) + '/' + IntToStr(N_TX * N_TXROWS + N_CONC));

  { Yuzdelik tutarliligi (18 kategorinin tamami). }
  why := '';
  for i := 0 to GAll.Count - 1 do
    if not PctOk(TSample(GAll[i])) then
      why := why + TSample(GAll[i]).Name + ' ';
  Chk('BR19 tum kategorilerde P50<=P95<=P99<=max', why = '',
    'bozuk=' + Trim(why));
  Chk('BR19 kategori sayisi 18', GAll.Count = 18,
    'kategori=' + IntToStr(GAll.Count));

  { Genis tavan: hang/asiri yavas (regresyon sinyali). }
  why := '';
  for i := 0 to GAll.Count - 1 do
    if TSample(GAll[i]).TotalUs > QWord(CEIL_MS) * 1000 then
      why := why + TSample(GAll[i]).Name + ' ';
  Chk('BR19 kategori sureleri tavan altinda', why = '',
    'tavan_ms=' + IntToStr(CEIL_MS) + ' asan=' + Trim(why));

  { ------------------------------------------------------- metrikler }
  dbsz := FileLenOf(GDbFile);
  walsz := FileLenOf(GDbFile + '.wal');
  cs := GBe.GetCacheStats;
  hits := cs.Hits;
  miss := cs.Misses;
  tot := hits + miss;
  if tot > 0 then ratio := hits / tot else ratio := 0;
  hs := GetFPCHeapStatus;
  Info(Format('ONBELLEK hits=%d misses=%d oran=%.4f pool=%d dolu=%d kirli=%d',
    [hits, miss, ratio, cs.PoolPages, cs.PoolUsed, cs.DirtyPages]));
  Info(Format('YAZMA flush=%d sayfa=%d son_ms=%d toplam_ms=%d',
    [cs.FlushCount, cs.FlushPages, cs.FlushLastMs, cs.FlushTotalMs]));
  Info('BOYUT db_bayt=' + IntToStr(dbsz) + ' wal_bayt=' + IntToStr(walsz));
  Info('BELLEK fpc_heap_used=' + IntToStr(Int64(hs.CurrHeapUsed)) +
    ' fpc_heap_free=' + IntToStr(Int64(hs.CurrHeapFree)) +
    ' fpc_heap_size=' + IntToStr(Int64(hs.CurrHeapSize)));
  Meta('db_bytes=' + IntToStr(dbsz) + ' wal_bytes=' + IntToStr(walsz));
  Meta(Format('cache_pool=%d cache_used=%d hits=%d misses=%d ratio=%.4f',
    [cs.PoolPages, cs.PoolUsed, hits, miss, ratio]));
  Meta('flush_count=' + IntToStr(cs.FlushCount) +
    ' flush_pages=' + IntToStr(cs.FlushPages) +
    ' flush_total_ms=' + IntToStr(cs.FlushTotalMs));
  Meta('heap_used_bytes=' + IntToStr(Int64(hs.CurrHeapUsed)));

  Chk('BR20 onbellek isabet orani gecerli',
    cs.Supported and (ratio >= 0) and (ratio <= 1) and (tot > 0),
    Format('oran=%.4f toplam=%d', [ratio, tot]));
  Chk('BR20 onbellek havuzu makul', (cs.PoolPages >= 8) and
    (cs.PoolUsed >= 0) and (cs.PoolUsed <= cs.PoolPages),
    'pool=' + IntToStr(cs.PoolPages) + ' dolu=' + IntToStr(cs.PoolUsed));
  Chk('BR20 DB dosyasi buyudu', dbsz > 32768, 'db_bayt=' + IntToStr(dbsz));
  Chk('BR20 bellek olcumu alindi', Int64(hs.CurrHeapUsed) > 0,
    'bayt=' + IntToStr(Int64(hs.CurrHeapUsed)));

  { ------------------------------------------------------------ cikti }
  { CSV ve meta AYRI dosyalar: meta satirlari CSV'ye, CSV satirlari meta
    dosyasina sizmamali. Bu yuzden iki ayri liste kullanilir. }
  csv := IncludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0))) +
    'bench_report.csv';
  GCsv := TStringList.Create;
  try
    GCsv.Add('kategori;islem;toplam_us;islem_sn;ort_us;p50_us;p95_us;p99_us;max_us');
    for i := 0 to GAll.Count - 1 do
      GCsv.Add(Format('%s;%d;%d;%.1f;%.1f;%d;%d;%d;%d',
        [TSample(GAll[i]).Name, TSample(GAll[i]).Count,
         TSample(GAll[i]).TotalUs, TSample(GAll[i]).OpsPerSec,
         TSample(GAll[i]).AvgUs, TSample(GAll[i]).Pct(0.50),
         TSample(GAll[i]).Pct(0.95), TSample(GAll[i]).Pct(0.99),
         TSample(GAll[i]).MaxUs]));
    GCsv.SaveToFile(csv);
  finally
    GCsv.Free;
  end;
  metaf := IncludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0))) +
    'bench_meta.txt';
  GMeta.SaveToFile(metaf);
  Info('rapor: ' + csv + ' ve ' + metaf);

  { Dogrulama: rapor dosyalari gercekten yazildi mi. }
  Chk('BR20 rapor dosyalari yazildi',
    FileExists(csv) and FileExists(metaf),
    'csv=' + IntToStr(FileLenOf(csv)) + ' meta=' + IntToStr(FileLenOf(metaf)));

  FreeAndNil(GSq);
  FreeAndNil(GTb);
  GBe := nil;
  GBeC := nil;

  for i := 0 to GAll.Count - 1 do
    TSample(GAll[i]).Free;
  FreeAndNil(GAll);
  FreeAndNil(GMeta);

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
