{ H3 indeks guncelleme olcumu.

  Senaryo A (toplu): N satir yukle, K satiri guncelle, TEK indeksli
  aralik sorgusu (tek flush).
  Senaryo B (update+query dongusu): her guncellemeden sonra ayni indeksli
  aralik sorgusu. Kucuk delta hizli yolu tek kaydirma yapar; delta buyukse
  O(N+M) merge yedek yoldur.
  Senaryo C (indekssiz kontrol): ayni is ama ikincil indeks yok.

  B0 : pending yokken indeksli sorgu
  B  : UPDATE + indeksli sorgu dongusu
  B1 : yalniz UPDATE (pending birikir)
  B2 : ayni pending uzerinde sorgular (ilk sorgu flush eder)

  Kullanim: idxbench.exe [N] [K] [DONGU] }
{$mode delphi}
program idxbench;

uses
  SysUtils, Windows, VDbCore, VDbTable, VDbSql, VDbTypes;

var
  GFreq: Int64;

function Tick: Int64;
var c: Int64;
begin
  QueryPerformanceCounter(c);
  Result := c;
end;

function MS(t0, t1: Int64): Double;
begin
  Result := (t1 - t0) * 1000 / GFreq;
end;

function Q(const sq: TVSql; const S: string): TSqlResult;
begin
  Result := sq.Exec(S);
end;

procedure WipeDir(const D: string);
begin
  SysUtils.DeleteFile(D + '\veritabani.odb');
  SysUtils.DeleteFile(D + '\veritabani.odb.bak');
  SysUtils.DeleteFile(D + '\veritabani.odb.tmp');
  SysUtils.DeleteFile(D + '\veritabani.schema');
  SysUtils.DeleteFile(D + '\veritabani.wal');
  RemoveDir(D);
end;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  N, K, LOOP, i, j: Integer;
  t0, t1: Int64;
  R: TSqlResult;
  dir: string;
  chunk: string;
  sum: Int64;

  procedure Load;
  var x: Integer;
  begin
    sq.Exec('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
    sq.Exec('CREATE INDEX ia ON t(a)');
    sq.Exec('BEGIN');
    x := 1;
    while x <= N do
    begin
      chunk := '';
      for j := 1 to 200 do
      begin
        if x > N then Break;
        if chunk <> '' then chunk := chunk + ',';
        chunk := chunk + Format('(%d,%d,''v%d'')', [x, x mod 10000, x]);
        Inc(x);
      end;
      sq.Exec('INSERT INTO t(id,a,b) VALUES' + chunk);
    end;
    sq.Exec('COMMIT');
    // indexi kur ve isit
    R := Q(sq, 'SELECT COUNT(*) FROM t WHERE a >= 100 AND a < 200');
    sum := StrToInt64Def(R.Rows[0][0], 0);
  end;

  function RangeCount: Int64;
  begin
    R := Q(sq, 'SELECT COUNT(*) FROM t WHERE a >= 100 AND a < 200');
    Result := StrToInt64Def(R.Rows[0][0], 0);
  end;

begin
  QueryPerformanceFrequency(GFreq);
  N := 100000; K := 200; LOOP := 100;
  if ParamCount >= 1 then N := StrToIntDef(ParamStr(1), N);
  if ParamCount >= 2 then K := StrToIntDef(ParamStr(2), K);
  if ParamCount >= 3 then LOOP := StrToIntDef(ParamStr(3), LOOP);

  dir := 'idxbench_dir';
  WipeDir(dir);
  ForceDirectories(dir);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(dir); tb.Open(dir);
    Load;
    Writeln(Format('N=%d K=%d LOOP=%d  taban COUNT=%d', [N, K, LOOP, sum]));

    // A) K guncelleme, tek sorgu
    t0 := Tick;
    for i := 1 to K do
      sq.Exec(Format('UPDATE t SET a = a + 1 WHERE id = %d', [i]));
    t1 := Tick;
    Writeln(Format('A) %d UPDATE (pending): %.1f ms', [K, MS(t0, t1)]));
    t0 := Tick;
    sum := RangeCount;
    t1 := Tick;
    Writeln(Format('A) ilk indeksli sorgu (flush): %.1f ms  COUNT=%d', [MS(t0, t1), sum]));

    // B0) yalniz indeksli sorgu (pending yok)
    t0 := Tick;
    for i := 1 to LOOP do
      sum := RangeCount;
    t1 := Tick;
    Writeln(Format('B0) %d indeksli sorgu (pending yok): %.1f ms (%.2f ms/dongu)',
      [LOOP, MS(t0, t1), MS(t0, t1) / LOOP]));

    // B) her update'ten sonra indeksli sorgu
    t0 := Tick;
    for i := 1 to LOOP do
    begin
      sq.Exec(Format('UPDATE t SET a = a + 1 WHERE id = %d', [(i mod N) + 1]));
      sum := RangeCount;
    end;
    t1 := Tick;
    Writeln(Format('B) %d x (UPDATE + indeksli sorgu): %.1f ms (%.2f ms/dongu)',
      [LOOP, MS(t0, t1), MS(t0, t1) / LOOP]));
    t0 := Tick;
    for i := 1 to LOOP do
      sq.Exec(Format('UPDATE t SET a = a + 1 WHERE id = %d', [(i mod N) + 1]));
    t1 := Tick;
    Writeln(Format('B1) %d UPDATE (sorgusuz, pending): %.1f ms (%.2f ms/dongu)',
      [LOOP, MS(t0, t1), MS(t0, t1) / LOOP]));
    t0 := Tick;
    for i := 1 to LOOP do
      sum := RangeCount;
    t1 := Tick;
    Writeln(Format('B2) %d indeksli sorgu (ayni pending): %.1f ms (%.2f ms/dongu)',
      [LOOP, MS(t0, t1), MS(t0, t1) / LOOP]));

    // C) ayni is, fakat sorgu indekssiz (a+0 ile indeks bastirilir)
    t0 := Tick;
    for i := 1 to LOOP do
    begin
      sq.Exec(Format('UPDATE t SET a = a + 1 WHERE id = %d', [(i mod N) + 1]));
      R := Q(sq, 'SELECT COUNT(*) FROM t WHERE a + 0 >= 100 AND a + 0 < 200');
      sum := StrToInt64Def(R.Rows[0][0], 0);
    end;
    t1 := Tick;
    Writeln(Format('C) %d x (UPDATE + indekssiz sorgu): %.1f ms (%.2f ms/dongu)',
      [LOOP, MS(t0, t1), MS(t0, t1) / LOOP]));

    R := Q(sq, 'SELECT COUNT(*) FROM t');
    Writeln('son satir=', R.Rows[0][0], ' checksum=', sum);
  finally
    sq.Free; tb.Free; kv.Free;
  end;
  WipeDir(dir);
end.
