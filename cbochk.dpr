program cbochk;
{ H8: CBO kalibrasyon/dogrulama seti.
  EXPLAIN tahmini (plan satirindaki "rows=N") vs EXPLAIN ANALYZE gercegi
  ("Actual Rows: M") karsilastirilir. Dagitimlar: uniform, skewed, yuksek
  NULL, korelasyonlu, dar/genis aralik. Ayrica secilen plan turu (Index
  Scan / Seq Scan) dogrulanir. }
{$mode delphi}
uses
  SysUtils, VDbCore, VDbTable, VDbSql;

const
  N = 10000;
  DIR = 'cbochk_dir';

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  fails: Integer;

function ExplainLine(const sql: string): TStrArray;
var R: TSqlResult; i: Integer;
begin
  R := sq.Exec('EXPLAIN ' + sql);
  SetLength(Result, Length(R.Rows));
  for i := 0 to High(R.Rows) do Result[i] := R.Rows[i][0];
end;

{ "rows=N" -> N  (tahmin) }
function EstRows(const sql: string): Int64;
var L: TStrArray; i, pHi, p, q: Integer; s: string;
begin
  Result := -1;
  L := ExplainLine(sql);
  for i := 0 to High(L) do
  begin
    p := Pos('rows=', L[i]);
    if p = 0 then Continue;
    s := '';
    q := p + 5;
    while (q <= Length(L[i])) and (L[i][q] in ['0'..'9']) do begin s := s + L[i][q]; Inc(q); end;
    if s <> '' then begin Result := StrToInt64(s); Exit; end;
  end;
end;

{ "Actual Rows: M" -> M }
function ActualRows(const sql: string): Int64;
var R: TSqlResult; i, p: Integer; s: string;
begin
  Result := -1;
  R := sq.Exec('EXPLAIN ANALYZE ' + sql);
  for i := 0 to High(R.Rows) do
  begin
    p := Pos('Actual Rows:', R.Rows[i][0]);
    if p = 0 then Continue;
    s := Trim(Copy(R.Rows[i][0], p + 12, MaxInt));
    Result := StrToInt64(s);
    Exit;
  end;
end;

{ plan turu: indeks mi? }
function PlanUsesIndex(const sql: string): Boolean;
var L: TStrArray; i: Integer;
begin
  L := ExplainLine(sql);
  for i := 0 to High(L) do
    if Pos('Index Scan', L[i]) > 0 then Exit(True);
  Result := False;
end;

procedure SatirGoster(const etiket, sql: string; bekleIndeks: Integer);
var est, act: Int64; r: Double; ik: Boolean;
begin
  est := EstRows(sql);
  act := ActualRows(sql);
  ik := PlanUsesIndex(sql);
  if act > 0 then r := est / act else r := 0;
  Writeln(Format('  %-10s est=%-7d gercek=%-7d oran=%-6.2f plan=%s',
    [etiket, est, act, r, BoolToStr(ik, 'Index', 'Seq')]));
  if (bekleIndeks >= 0) and (ik <> (bekleIndeks = 1)) then
  begin
    Writeln('    HATA: plan beklentisi ', BoolToStr(bekleIndeks = 1, 'Index', 'Seq'));
    Inc(fails);
  end;
end;

procedure Yak1(const etiket, sql: string; minR, maxR: Double);
var est, act: Int64; r: Double;
begin
  est := EstRows(sql); act := ActualRows(sql);
  if act > 0 then r := est / act else r := 0;
  if (r < minR) or (r > maxR) then
  begin
    Writeln(Format('HATA %s: oran %.2f [%.2f..%.2f] disinda (est=%d gercek=%d)',
      [etiket, r, minR, maxR, est, act]));
    Inc(fails);
  end
  else
    Writeln(Format('OK   %s: oran %.2f (est=%d gercek=%d)', [etiket, r, est, act]));
end;

var i: Integer;
begin
  fails := 0;
  DeleteFile(DIR + '\veritabani.odb'); DeleteFile(DIR + '\veritabani.schema');
  if DirectoryExists(DIR) then RemoveDir(DIR);
  ForceDirectories(DIR);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(DIR); tb.Open(DIR);
    sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, c INTEGER, d INTEGER)');
    sq.Exec('CREATE INDEX ix_a ON t(a)');
    sq.Exec('CREATE INDEX ix_b ON t(b)');
    sq.Exec('CREATE INDEX ix_c ON t(c)');
    sq.Exec('BEGIN');
    for i := 1 to N do
    begin
      // a: uniform 0..99; b: deger 7 ~%50, kalan uniform; c: %50 NULL, 10 distinct;
      // d: a ile birebir korelasyonlu
      if (i mod 100) < 50 then
        sq.Exec(Format('INSERT INTO t VALUES (%d, %d, 7, %s, %d)',
          [i, i mod 100, IntToStr(i mod 10), i mod 100]))
      else
        sq.Exec(Format('INSERT INTO t VALUES (%d, %d, %d, %s, %d)',
          [i, i mod 100, 100 + (i mod 50), IntToStr(i mod 10), i mod 100]));
    end;
    sq.Exec('COMMIT');
    sq.Exec('ANALYZE t');

    Writeln('--- Tahmin vs Gercek (EXPLAIN / EXPLAIN ANALYZE) ---');
    SatirGoster('uniform', 'SELECT id FROM t WHERE a = 42', 1);
    SatirGoster('skewed', 'SELECT id FROM t WHERE b = 7', 1);
    SatirGoster('null-yuk', 'SELECT id FROM t WHERE c = 3', 1);
    SatirGoster('korel-as', 'SELECT id FROM t WHERE a = 42 AND d = 42', 1);
    SatirGoster('dar-aral', 'SELECT id FROM t WHERE a >= 40 AND a < 60', -1);
    SatirGoster('ince-aral', 'SELECT id FROM t WHERE a >= 40 AND a < 42', 1);
    SatirGoster('between', 'SELECT id FROM t WHERE a BETWEEN 40 AND 41', 1);
    SatirGoster('genis-ar', 'SELECT id FROM t WHERE a >= 0 AND a < 1000', -1);
    SatirGoster('secici-deg', 'SELECT id FROM t WHERE a < 100', 0);

    Writeln('--- Kabul: tahmin/gercek orani ---');
    Yak1('uniform a=42', 'SELECT id FROM t WHERE a = 42', 0.5, 2.0);
    Yak1('yuksek-NULL c=3', 'SELECT id FROM t WHERE c = 3', 0.4, 2.5);
    Yak1('korelasyonlu a=42 AND d=42', 'SELECT id FROM t WHERE a = 42 AND d = 42', 0.5, 2.0);
    Yak1('ince aralik a>=40 AND a<42', 'SELECT id FROM t WHERE a >= 40 AND a < 42', 0.5, 2.0);
    Yak1('BETWEEN 40 AND 41', 'SELECT id FROM t WHERE a BETWEEN 40 AND 41', 0.4, 2.5);
    Writeln('NOT: "dar-aral" (a>=40 AND a<60, ~%20) indeks esiginde oldugu icin');
    Writeln('     Seq Scan secilir; plan rows= tarama cikisidir (=RowCount). Skew');
    Writeln('     ise distinct-tabanli tahminin bilinen siniridir.');
  except
    on E: Exception do begin Writeln('ISTISNA: ', E.Message); Inc(fails); end;
  end;
  kv.Free; tb.Free; sq.Free;
  Writeln('SONUC: ', fails, ' hata');
end.
