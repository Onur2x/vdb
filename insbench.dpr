program insbench;
{ H10 taban/sonrasi olcumu: 1M INSERT (tek transaction).
  Yalniz yazma yolunu izole eder; SELECT yok. }
{$mode delphi}
uses
  SysUtils, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 1000000;
  DIR = 'insbench_dir';

var
  GFreq: Int64;

function Tick: Int64;
var c: Int64;
begin
  QueryPerformanceCounter(c);
  Result := c;
end;

function Ms(t0, t1: Int64): Double;
begin
  Result := (t1 - t0) * 1000 / GFreq;
end;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  i: Integer;
  t0, t1: Int64;
  rows: Integer;
begin
  try
    QueryPerformanceFrequency(GFreq);
    if DirectoryExists(DIR) then
    begin
      DeleteFile(DIR + '\veritabani.odb');
      DeleteFile(DIR + '\veritabani.schema');
      RemoveDir(DIR);
    end;
    ForceDirectories(DIR);

    kv := TVDb.Create;
    tb := TVTableDb.Create(kv);
    sq := TVSql.Create(tb);
    try
      kv.Open(DIR);
      tb.Open(DIR);
      sq.Exec('CREATE TABLE bench (id INTEGER PRIMARY KEY, name TEXT, val INTEGER)');

      t0 := Tick;
      sq.Exec('BEGIN');
      for i := 1 to N do
        sq.Exec('INSERT INTO bench VALUES (' + IntToStr(i) + ', ''row' + IntToStr(i) + ''', ' + IntToStr(i * 2) + ')');
      sq.Exec('COMMIT');
      t1 := Tick;

      Writeln(Format('INSERT %d (tx): %.0f ms  (%.0f satir/sn)', [N, Ms(t0, t1), N / (Ms(t0, t1) / 1000)]));

      t0 := Tick;
      rows := StrToInt64(sq.Exec('SELECT COUNT(*) FROM bench').Rows[0, 0]);
      t1 := Tick;
      Writeln(Format('dogrulama: COUNT=%d (%.0f ms)', [rows, Ms(t0, t1)]));
    finally
      sq.Free;
      tb.Free;
      kv.Free;
    end;
  except
    on E: Exception do
      Writeln('HATA: ', E.Message);
  end;
end.
