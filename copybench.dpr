{ H13 olcum: COPY FROM vs satir-basina INSERT (tek transaction).
  Ayni 100.000 satir iki yoldan yuklenir; sure ve satir/sn karsilastirilir. }
{$mode delphi}
program copybench;

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 100000;
  DIR = 'copybench_dir';
  CSV = 'copybench_data.csv';

var
  GFreq: Int64;
  kv: TVDb; tb: TVTableDb; sq: TVSql;

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

procedure WipeDir(const D: string);
begin
  SysUtils.DeleteFile(D + '\veritabani.odb');
  SysUtils.DeleteFile(D + '\veritabani.odb.bak');
  SysUtils.DeleteFile(D + '\veritabani.odb.tmp');
  SysUtils.DeleteFile(D + '\veritabani.schema');
  SysUtils.DeleteFile(D + '\veritabani.wal');
  RemoveDir(D);
end;

function CountOf(const T: string): Integer;
var R: TSqlResult;
begin
  R := sq.Exec('SELECT COUNT(*) FROM ' + T);
  if Length(R.Rows) = 1 then Result := StrToIntDef(R.Rows[0][0], -1) else Result := -1;
end;

var
  sl: TStringList;
  i, nRows: Integer;
  t0, t1: Int64;
  msCopy, msIns: Double;
  r1, r2: TSqlResult;
  fsz: Int64;

begin
  QueryPerformanceFrequency(GFreq);
  nRows := N;
  if ParamCount >= 1 then nRows := StrToIntDef(ParamStr(1), N);
  if DirectoryExists(DIR) then WipeDir(DIR);
  ForceDirectories(DIR);

  Writeln(Format('Veri uretiliyor: %d satir...', [nRows]));
  sl := TStringList.Create;
  try
    sl.Add('id,name,qty');
    for i := 1 to nRows do
      sl.Add(Format('%d,"kayit %d, açıklama",%d', [i, i, i mod 1000]));
    sl.SaveToFile(CSV);
  finally
    sl.Free;
  end;
  fsz := 0;
  with TFileStream.Create(CSV, fmOpenRead) do
    try fsz := Size; finally Free; end;
  Writeln(Format('CSV: %d satir, %.1f MB', [nRows, fsz / (1024*1024)]));

  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(DIR); tb.Open(DIR);

    sq.Exec('CREATE TABLE c (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)');
    t0 := Tick;
    r1 := sq.Exec('COPY c FROM ''copybench_data.csv'' WITH (FORMAT CSV, HEADER)');
    t1 := Tick;
    msCopy := MS(t0, t1);
    Writeln(Format('COPY FROM      : %8.1f ms  (%d satir, %.0f satir/sn, Affected=%d, %s)',
      [msCopy, CountOf('c'), nRows * 1000 / msCopy, r1.Affected, r1.Msg]));

    sq.Exec('CREATE TABLE i (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)');
    t0 := Tick;
    sq.Exec('BEGIN');
    for i := 1 to nRows do
      sq.Exec(Format('INSERT INTO i VALUES (%d,''kayit %d, açıklama'',%d)', [i, i, i mod 1000]));
    sq.Exec('COMMIT');
    t1 := Tick;
    msIns := MS(t0, t1);
    r2 := sq.Exec('SELECT COUNT(*) FROM i');
    Writeln(Format('INSERT satir   : %8.1f ms  (%s satir, %.0f satir/sn)',
      [msIns, r2.Rows[0][0], nRows * 1000 / msIns]));

    if (r1.Affected = nRows) and (StrToIntDef(r2.Rows[0][0], -1) = nRows) then
      Writeln(Format('HIZ: %.2fx  (COPY daha hizli)', [msIns / msCopy]))
    else
      Writeln('HATA: satir sayilari uyusmuyor');
  finally
    tb.Free; kv.Free; sq.Free;
  end;
end.
