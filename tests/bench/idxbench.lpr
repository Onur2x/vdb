program idxbench;
{ v4 OLCUM: siralı indeks / aralik sorgulari. Yalniz OLCULEN degerler.
  Kullanim: idxbench <dizin> [satir]
  Olculen:
    - indekssiz tam tarama + siralama (ORDER BY n)
    - indeksli aralik (WHERE n BETWEEN a AND b)
    - indeksli nokta arama
    - indeks sirasinda ORDER BY n (LIMIT'li ve LIMIT'siz)
    - kapsayan indeks (INCLUDE) ile aralik
    - COUNT(*) aralik
  Her sorgu 3 kez kosulur, MEDYAN basilir. }
{$mode delphi}{$H+}
uses
  SysUtils, Classes, VDbBackendApi, VDbBackendV3, VDbTable, VDbSql,
  VDbTypes, VDbChangeLog;

function QueryPerformanceCounter(out C: Int64): LongBool; stdcall;
  external 'kernel32' name 'QueryPerformanceCounter';
function QueryPerformanceFrequency(out F: Int64): LongBool; stdcall;
  external 'kernel32' name 'QueryPerformanceFrequency';

var
  gQpf: Int64 = 0;
  gDir: string;

function NowUs: Int64;
var
  c: Int64;
begin
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then Result := (c * 1000) div gQpf
  else Result := c * 1000;
end;

function Cel(const R: TSqlResult; Row, Col: Integer): string;
begin
  if (Row > High(R.Rows)) or (Col > High(R.Rows[Row])) then Exit('?');
  Result := R.Rows[Row][Col];
end;

var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
  i, nRows: Integer;
  t: array[0..2] of Int64;
  k: Integer;
  us: Int64;

procedure Bench(const Label_, Sql: string; ExpectRows: Integer);
var
  n, j: Integer;
  med: Int64;
  ok: Boolean;
begin
  ok := True;
  n := 0;
  for j := 0 to 2 do
  begin
    t[j] := NowUs;
    R := Sq.Exec(Sql);
    t[j] := NowUs - t[j];
    if (ExpectRows >= 0) and (Length(R.Rows) <> ExpectRows) then ok := False;
    Inc(n);
  end;
  med := t[0];
  if t[1] < med then med := t[1];
  if t[2] < med then med := t[2];
  { medyan: 3 degerin ortancasi }
  if ((t[0] >= t[1]) and (t[0] <= t[2])) or ((t[0] <= t[1]) and (t[0] >= t[2])) then
    med := t[0]
  else if ((t[1] >= t[0]) and (t[1] <= t[2])) or ((t[1] <= t[0]) and (t[1] >= t[2])) then
    med := t[1]
  else
    med := t[2];
  WriteLn(Format('%-42s %8.1f ms  satir=%d  %s', [Label_, med / 1000,
    Length(R.Rows), BoolToStr(ok, 'DOGRU', 'BEKLENTI FARKLI')]));
end;

begin
  if ParamCount >= 1 then gDir := ParamStr(1) else gDir := GetCurrentDir;
  nRows := 50000;
  if ParamCount >= 2 then nRows := StrToIntDef(ParamStr(2), nRows);
  ForceDirectories(gDir);
  Be := TVdbBackendV3.Create(IncludeTrailingPathDelimiter(gDir) + 'ib.odb',
    True, 512);
  Tb := TVTableDb.CreateBackend(Be);
  Sq := TVSql.Create(Tb);
  Tb.Open(gDir);
  try
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, s TEXT)');
    Sq.Exec('CREATE TABLE t2 (id INTEGER PRIMARY KEY, n INTEGER, s TEXT)');
    Sq.Exec('BEGIN');
    for i := 1 to nRows do
    begin
      Sq.Exec(Format('INSERT INTO t VALUES (%d,%d,%s)',
        [i, i mod 997, QuotedStr('s' + IntToStr(i))]));
      Sq.Exec(Format('INSERT INTO t2 VALUES (%d,%d,%s)',
        [i, i mod 997, QuotedStr('s' + IntToStr(i))]));
    end;
    Sq.Exec('COMMIT');
    R := Sq.Exec('SELECT COUNT(*) FROM t');
    WriteLn('satir: ', Cel(R, 0, 0));

    WriteLn;
    WriteLn('--- indeks YOK (tam tarama) ---');
    Bench('ORDER BY n (indekssiz)', 'SELECT id FROM t ORDER BY n', nRows);
    Bench('WHERE n BETWEEN 100 AND 120', 'SELECT id FROM t WHERE n BETWEEN 100 AND 120', -1);
    Bench('WHERE n = 42', 'SELECT id FROM t WHERE n = 42', -1);

    Sq.Exec('CREATE INDEX ix_n ON t(n)');
    WriteLn;
    WriteLn('--- ix_n (tek kolon) ---');
    Bench('ORDER BY n', 'SELECT id FROM t ORDER BY n', nRows);
    Bench('ORDER BY n LIMIT 20', 'SELECT id FROM t ORDER BY n LIMIT 20', 20);
    Bench('ORDER BY n DESC LIMIT 20', 'SELECT id FROM t ORDER BY n DESC LIMIT 20', 20);
    Bench('ORDER BY n LIMIT 1000', 'SELECT id FROM t ORDER BY n LIMIT 1000', 1000);
    Bench('WHERE n BETWEEN 100 AND 120', 'SELECT id FROM t WHERE n BETWEEN 100 AND 120', -1);
    Bench('WHERE n BETWEEN 100 AND 120 ORDER BY n',
      'SELECT id FROM t WHERE n BETWEEN 100 AND 120 ORDER BY n', -1);
    Bench('WHERE n = 42', 'SELECT id FROM t WHERE n = 42', -1);
    Bench('COUNT(*) WHERE n BETWEEN 100 AND 120',
      'SELECT COUNT(*) FROM t WHERE n BETWEEN 100 AND 120', 1);
    Bench('WHERE n >= 500 ORDER BY n LIMIT 10',
      'SELECT id FROM t WHERE n >= 500 ORDER BY n LIMIT 10', 10);

    Sq.Exec('CREATE INDEX ix_t2n ON t2(n) INCLUDE(s)');
    WriteLn;
    WriteLn('--- ix_n kapaksiz (SELECT s -> ReadRow) ---');
    Bench('SELECT s WHERE n BETWEEN 100 AND 120',
      'SELECT s FROM t WHERE n BETWEEN 100 AND 120', -1);
    WriteLn;
    WriteLn('--- ix_t2n (kapsayan: n INCLUDE s) ---');
    Bench('SELECT s WHERE n BETWEEN 100 AND 120',
      'SELECT s FROM t2 WHERE n BETWEEN 100 AND 120', -1);
    Bench('SELECT n WHERE n BETWEEN 100 AND 120',
      'SELECT n FROM t2 WHERE n BETWEEN 100 AND 120', -1);
  finally
    Sq.Free;
    Tb.Close;
    Tb.Free;
    Be := nil;
  end;
end.
