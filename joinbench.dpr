program joinbench;
{ H1 dogrulama: indekssiz esitlik JOIN (klasik ic ice dongu) oncesi/sonrasi.
  L ve R ayni anahtar dagilimi; join kolonu indekssiz. }
{$mode delphi}
uses
  SysUtils, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 3000;
  DIR = 'joinbench_dir';

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
  R: TSqlResult;
  cnt: Int64;
begin
  try
    QueryPerformanceFrequency(GFreq);
    DeleteFile(DIR + '\veritabani.odb');
    DeleteFile(DIR + '\veritabani.schema');
    if DirectoryExists(DIR) then RemoveDir(DIR);
    ForceDirectories(DIR);

    kv := TVDb.Create;
    tb := TVTableDb.Create(kv);
    sq := TVSql.Create(tb);
    try
      kv.Open(DIR);
      tb.Open(DIR);
      sq.Exec('CREATE TABLE l (id INTEGER PRIMARY KEY, k INTEGER)');
      sq.Exec('CREATE TABLE r (id INTEGER PRIMARY KEY, k INTEGER)');
      sq.Exec('BEGIN');
      for i := 1 to N do
      begin
        sq.Exec('INSERT INTO l VALUES (' + IntToStr(i) + ', ' + IntToStr(i mod 300) + ')');
        sq.Exec('INSERT INTO r VALUES (' + IntToStr(i) + ', ' + IntToStr(i mod 300) + ')');
      end;
      sq.Exec('COMMIT');

      t0 := Tick;
      R := sq.Exec('SELECT COUNT(*) FROM l JOIN r ON l.k = r.k');
      t1 := Tick;
      cnt := StrToInt64(R.Rows[0, 0]);
      Writeln(Format('JOIN %dx%d indekssiz esitlik: %.0f ms (eslesme=%d)', [N, N, Ms(t0, t1), cnt]));
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
