program selbench;
{ H7 dogrulama: (1) parse-baskin minik SELECT, (2) filtre+sort SELECT.
  Plan onbellegi etkisini olcer. }
{$mode delphi}
uses
  SysUtils, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 100000;
  REP_CHEAP = 50000;
  REP_HEAVY = 60;
  DIR = 'selbench_dir2';

var
  GFreq: Int64;

function Tick: Int64; var c: Int64; begin QueryPerformanceCounter(c); Result := c; end;
function Ms(t0, t1: Int64): Double; begin Result := (t1 - t0) * 1000 / GFreq; end;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  i: Integer; t0, t1: Int64; R: TSqlResult; cnt: Int64;
  QC, QH: string;
begin
  try
    QueryPerformanceFrequency(GFreq);
    if DirectoryExists(DIR) then begin
      DeleteFile(DIR + '\veritabani.odb'); DeleteFile(DIR + '\veritabani.schema');
      RemoveDir(DIR);
    end;
    ForceDirectories(DIR);
    kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
    try
      kv.Open(DIR); tb.Open(DIR);
      sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
      sq.Exec('BEGIN');
      for i := 1 to N do
        sq.Exec('INSERT INTO t VALUES (' + IntToStr(i) + ', ' + IntToStr(i mod 500) + ', ''v' + IntToStr(i mod 97) + ''')');
      sq.Exec('COMMIT');

      QC := 'SELECT 1 + 2 AS x';
      QH := 'SELECT id, a, b FROM t WHERE a >= 100 AND a < 200 ORDER BY a DESC LIMIT 50';

      R := sq.Exec(QC); R := sq.Exec(QH);   // isinma

      t0 := Tick;
      for i := 1 to REP_CHEAP do R := sq.Exec(QC);
      t1 := Tick;
      Writeln(Format('CHEAP x%d: toplam %.0f ms (%.4f ms/sorgu)', [REP_CHEAP, Ms(t0, t1), Ms(t0, t1)/REP_CHEAP]));

      t0 := Tick;
      for i := 1 to REP_HEAVY do R := sq.Exec(QH);
      t1 := Tick;
      Writeln(Format('HEAVY (indekssiz) x%d (satir=%d): toplam %.0f ms (%.3f ms/sorgu)',
        [REP_HEAVY, Length(R.Rows), Ms(t0, t1), Ms(t0, t1)/REP_HEAVY]));

      // H3 denetimi: 'a' kolonuna indeks ekleyince agir sorgu ne oluyor?
      sq.Exec('CREATE INDEX ia ON t(a)');
      R := sq.Exec(QH);   // indeks kurulumu + isinma
      t0 := Tick;
      for i := 1 to REP_HEAVY do R := sq.Exec(QH);
      t1 := Tick;
      Writeln(Format('HEAVY+IDX x%d (satir=%d): toplam %.0f ms (%.3f ms/sorgu)',
        [REP_HEAVY, Length(R.Rows), Ms(t0, t1), Ms(t0, t1)/REP_HEAVY]));
    finally
      sq.Free; tb.Free; kv.Free;
    end;
  except on E: Exception do Writeln('HATA: ', E.Message); end;
end.
