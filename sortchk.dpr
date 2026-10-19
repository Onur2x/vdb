{ H6-sort dogrulama + olcum: paralel indeks siralamasi (parca sirala +
  k-yonlu birlestirme) ACIK/KAPALI AYNI indeks icerigini uretmeli;
  buyuk CREATE INDEX'te hizlanmali. }
{$mode delphi}
program sortchk;

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 300000;
  DIR = 'sortchk_dir';

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

function OneInt(const Q: string): Int64;
var R: TSqlResult;
begin
  Result := -1;
  R := sq.Exec(Q);
  if (Length(R.Rows) = 1) and (Length(R.Rows[0]) >= 1) then
    Result := StrToInt64Def(R.Rows[0][0], -1);
end;

{ Indeksin urettigi sonucun ozeti: aralik taramasi + esitlik. }
function Checksum: string;
var c1, c2, s1: Int64;
begin
  c1 := OneInt('SELECT COUNT(*) FROM t WHERE a >= 40000 AND a < 40100');
  c2 := OneInt('SELECT COUNT(*) FROM t WHERE a = 12345');
  s1 := OneInt('SELECT SUM(id) FROM t WHERE a >= 40000 AND a < 40100');
  Result := Format('c1=%d c2=%d s=%d', [c1, c2, s1]);
end;

function BuildOnce(AParallel: Boolean; const Label_: string; out Elapsed: Double): string;
var t0, t1: Int64;
begin
  VdbSetSortParallel(AParallel);
  try sq.Exec('DROP INDEX ix_a'); except end;   // ilk turda yok
  t0 := Tick;
  sq.Exec('CREATE INDEX ix_a ON t(a)');
  t1 := Tick;
  Elapsed := MS(t0, t1);
  Result := Checksum;
  Writeln(Format('%-10s CREATE INDEX: %8.1f ms  %s', [Label_, Elapsed, Result]));
end;

var
  i: Integer;
  msOff, msOn: Double;
  chkOff, chkOn: string;
  R: TSqlResult;

begin
  fails := 0;
  QueryPerformanceFrequency(GFreq);
  if DirectoryExists(DIR) then WipeDir(DIR);
  ForceDirectories(DIR);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(DIR); tb.Open(DIR);
    sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, s TEXT)');
    sq.Exec('BEGIN');
    for i := 1 to N do
      sq.Exec(Format('INSERT INTO t VALUES (%d, %d, ''v%d'')',
        [i, (i * 7919) mod 100003, i mod 97]));
    sq.Exec('COMMIT');
    Writeln(Format('Yuklendi: %d satir, ~%d MB', [N, tb.Kv.DataFileSize div (1024*1024)]));

    chkOff := BuildOnce(False, 'SERI', msOff);
    chkOn := BuildOnce(True, 'PARALEL', msOn);
    // ikinci tur (isinma etkisini gormek icin)
    BuildOnce(False, 'SERI-2', msOff);
    BuildOnce(True, 'PARALEL-2', msOn);

    Writeln(Format('Diferansiyel: %s', [BoolToStr(chkOff = chkOn, True)]));
    if chkOff <> chkOn then Inc(fails);

    // indeks gercekten kullaniliyor mu? (plan metni)
    R := sq.Exec('EXPLAIN SELECT id FROM t WHERE a BETWEEN 40000 AND 40050');
    Writeln('EXPLAIN: ', R.Rows[0][0]);
    // siralama dogrulugu: indeks sirali tarama
    R := sq.Exec('SELECT a FROM t WHERE a >= 50000 AND a < 50010 ORDER BY a');
    if Length(R.Rows) > 0 then
      Writeln('Ornek: ', R.Rows[0][0], ' .. ', R.Rows[High(R.Rows)][0]);

    Writeln(Format('SONUC: %s (fails=%d)', [BoolToStr(fails = 0, True), fails]));
  finally
    sq.Free; tb.Free; kv.Free;
  end;
end.
