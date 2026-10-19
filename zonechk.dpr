{ H3 dogrulama + olcum: bucket zone map (min/max).
  - Ayni sorgu 1. kez haritayi INSAA eder, 2. kez bolum atlar.
  - Sonuclar COUNT(*) ile birebir karsilastirilir.
  - Yazma (INSERT/UPDATE/DELETE) sonrasi harita GECERSIZ olmali; eski
    sonuc donmemeli (sessiz satir kaybi testi).
  - Blok onbellegi KAPALI: tek degisken zone map olsun. }
{$mode delphi}
program zonechk;

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 200000;
  DIR = 'zonechk_dir';
  REP = 2;

var
  GFreq: Int64;
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  fails: Integer;

function Tick: Int64; var c: Int64; begin QueryPerformanceCounter(c); Result := c; end;
function MS(t0, t1: Int64): Double; begin Result := (t1 - t0) * 1000 / GFreq; end;

procedure WipeDir(const D: string);
begin
  SysUtils.DeleteFile(D + '\veritabani.odb');
  SysUtils.DeleteFile(D + '\veritabani.odb.bak');
  SysUtils.DeleteFile(D + '\veritabani.odb.tmp');
  SysUtils.DeleteFile(D + '\veritabani.schema');
  SysUtils.DeleteFile(D + '\veritabani.wal');
  RemoveDir(D);
end;

function Check(const Label_: string; const Q: string; expRows: Integer): Boolean;
var
  R: TSqlResult;
  cnt: Integer;
begin
  R := sq.Exec(Q);
  cnt := Length(R.Rows);
  Result := cnt = expRows;
  Writeln(Format('  %-28s satir=%-7d beklenen=%-7d %s',
    [Label_, cnt, expRows, BoolToStr(Result, True)]));
  if not Result then Inc(fails);
end;

{ Ayni sorguyu REP kez calistir; ilk sure harita insasi, sonraki atlama. }
function TimeQ(const Q: string; out firstMs, bestMs: Double;
  out rows: Integer): Boolean;
var
  k: Integer; t0, t1: Int64; R: TSqlResult; d: Double;
begin
  firstMs := 0; bestMs := 1e18; rows := -1;
  for k := 0 to REP - 1 do
  begin
    t0 := Tick;
    R := sq.Exec(Q);
    t1 := Tick;
    d := MS(t0, t1);
    rows := Length(R.Rows);
    if k = 0 then firstMs := d;
    if d < bestMs then bestMs := d;
  end;
end;

function CountOf(const Pred: string): Integer;
var R: TSqlResult;
begin
  R := sq.Exec('SELECT COUNT(*) FROM t WHERE ' + Pred);
  if Length(R.Rows) = 1 then Result := StrToIntDef(R.Rows[0][0], -1)
  else Result := -1;
end;

procedure RunShape(const Label_, Pred: string);
var
  q: string;
  fm, bm: Double;
  rows: Integer;
  exp: Integer;
begin
  exp := CountOf(Pred);
  q := 'SELECT a, b, f FROM t WHERE ' + Pred;
  TimeQ(q, fm, bm, rows);
  Writeln(Format('%-22s ilk=%.1f ms  sonraki=%.1f ms  satir=%d  count=%d  %s',
    [Label_, fm, bm, rows, exp, BoolToStr(rows = exp, True)]));
  if rows <> exp then Inc(fails);
end;

var
  i: Integer;
  q: string;
  R: TSqlResult;
  before, after: Integer;
  ob, nb: Int64;

begin
  fails := 0;
  QueryPerformanceFrequency(GFreq);
  if DirectoryExists(DIR) then WipeDir(DIR);
  ForceDirectories(DIR);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(DIR); tb.Open(DIR);
    kv.SetReadCacheBlocks(0);   // yalniz zone map etkisi olculsun
    sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, f FLOAT, s TEXT)');
    sq.Exec('BEGIN');
    for i := 1 to N do
    begin
      // a: sirali (iyi budanir), b: dagilmis (budanmaz), f: float aralik
      if i mod 5000 = 0 then
        sq.Exec(Format('INSERT INTO t VALUES (%d, NULL, %d, %d.25, ''n%d'')',
          [i, (i * 7919) mod 100003, i, i mod 97]))
      else
        sq.Exec(Format('INSERT INTO t VALUES (%d, %d, %d, %d.25, ''v%d'')',
          [i, i, (i * 7919) mod 100003, i, i mod 97]));
    end;
    sq.Exec('COMMIT');
    Writeln(Format('Yuklendi: %d satir, dosya ~%d MB',
      [N, (tb.Kv.DataFileSize div (1024*1024))]));

    Writeln('--- dogruluk + olcum (ilk=harita insasi, sonraki=atlama) ---');
    RunShape('EQ', 'a = 77777');
    RunShape('RANGE kucuk', 'a BETWEEN 100000 AND 100500');
    RunShape('RANGE buyuk', 'a >= 199000');
    RunShape('IN', 'a IN (1, 50000, 150000, 199999)');
    RunShape('LT', 'a < 300');
    RunShape('NE (budanmaz)', 'a <> 77777');
    RunShape('FLOAT range', 'f BETWEEN 1000.0 AND 1001.0');
    RunShape('DAGILMIS (kontrol)', 'b BETWEEN 100 AND 200');

    Writeln('--- invalidation guvenligi ---');
    // 1) INSERT: daha once "bos" bilinen bolume yeni satir
    before := CountOf('a BETWEEN 1500 AND 1600');
    sq.Exec('INSERT INTO t VALUES (900001, 1550, 5, 221.4, ''yeni'')');
    after := CountOf('a BETWEEN 1500 AND 1600');
    q := 'SELECT a FROM t WHERE a BETWEEN 1500 AND 1600';
    R := sq.Exec(q);
    Writeln(Format('  INSERT sonrasi: count %d->%d, akis=%d  %s',
      [before, after, Length(R.Rows), BoolToStr(Length(R.Rows) = after, True)]));
    if Length(R.Rows) <> after then Inc(fails);

    // 2) UPDATE: deger aralik disina cikar
    sq.Exec('UPDATE t SET a = 1 WHERE id = 77777');
    q := 'SELECT a FROM t WHERE a = 77777';
    before := CountOf('a = 77777');
    R := sq.Exec(q);
    Writeln(Format('  UPDATE sonrasi: count=%d akis=%d sifir=TRUE %s',
      [before, Length(R.Rows), BoolToStr((Length(R.Rows) = before) and (before = 0), True)]));
    if Length(R.Rows) <> before then Inc(fails);

    // 3) DELETE ayni sekilde
    sq.Exec('DELETE FROM t WHERE a BETWEEN 100000 AND 100500');
    q := 'SELECT a FROM t WHERE a BETWEEN 100000 AND 100500';
    before := CountOf('a BETWEEN 100000 AND 100500');
    R := sq.Exec(q);
    Writeln(Format('  DELETE sonrasi: count=%d akis=%d  %s',
      [before, Length(R.Rows), BoolToStr(Length(R.Rows) = before, True)]));
    if Length(R.Rows) <> before then Inc(fails);

    // 4) Batch icinde pending satir gorunurlugu (zone map devre disi olmali)
    sq.Exec('BEGIN');
    sq.Exec('INSERT INTO t VALUES (900002, 1555, 7, 222.4, ''pend'')');
    before := CountOf('a BETWEEN 1500 AND 1600');
    q := 'SELECT a FROM t WHERE a BETWEEN 1500 AND 1600';
    R := sq.Exec(q);
    Writeln(Format('  BATCH icinde: count=%d akis=%d  %s',
      [before, Length(R.Rows), BoolToStr(Length(R.Rows) = before, True)]));
    if Length(R.Rows) <> before then Inc(fails);
    sq.Exec('ROLLBACK');
    before := CountOf('a BETWEEN 1500 AND 1600');
    R := sq.Exec(q);
    Writeln(Format('  ROLLBACK sonrasi: count=%d akis=%d  %s',
      [before, Length(R.Rows), BoolToStr(Length(R.Rows) = before, True)]));
    if Length(R.Rows) <> before then Inc(fails);

    // 5) Compact sonrasi (fiziksel offsetler degisir) dogruluk
    tb.Kv.Compact(ob, nb);
    q := 'SELECT a FROM t WHERE a >= 199000';
    before := CountOf('a >= 199000');
    R := sq.Exec(q);
    Writeln(Format('  Compact sonrasi: count=%d akis=%d  %s',
      [before, Length(R.Rows), BoolToStr(Length(R.Rows) = before, True)]));
    if Length(R.Rows) <> before then Inc(fails);

    Writeln(Format('SONUC: %s  (fails=%d)',
      [BoolToStr(fails = 0, True), fails]));
  finally
    sq.Free; tb.Free; kv.Free;
  end;
end.
