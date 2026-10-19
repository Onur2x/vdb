program insplit;
{ H10/H13: INSERT maliyetinin nereye gittigini izole eder.
  A) sq.Exec ile satir-satir INSERT (SQL parse dahil)
  B) tb.Insert ile dogrudan (parse yok, yazma yolu)
  Fark ~= SQL parse + ifade degerlendirme maliyeti. }
{$mode delphi}
uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 200000;
  DIR = 'insplit_dir';
  CHUNKS: array[0..4] of Integer = (1, 10, 100, 1000, 5000);

var
  GFreq: Int64;

function Tick: Int64;
var c: Int64;
begin QueryPerformanceCounter(c); Result := c; end;

function Ms(t0, t1: Int64): Double;
begin Result := (t1 - t0) * 1000 / GFreq; end;

procedure Fresh(var kv: TVDb; var tb: TVTableDb; var sq: TVSql);
begin
  kv.Free; tb.Free; sq.Free;
  DeleteFile(DIR + '\veritabani.odb');
  DeleteFile(DIR + '\veritabani.schema');
  if DirectoryExists(DIR) then RemoveDir(DIR);
  ForceDirectories(DIR);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  kv.Open(DIR); tb.Open(DIR);
  sq.Exec('CREATE TABLE bench (id INTEGER PRIMARY KEY, name TEXT, val INTEGER)');
end;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  i, m: Integer; t0, t1: Int64; stmt: string;
  chunk, c2: Integer;
  sl: TStringList;
begin
  QueryPerformanceFrequency(GFreq);
  try
    Fresh(kv, tb, sq);
    t0 := Tick;
    sq.Exec('BEGIN');
    for i := 1 to N do
      sq.Exec('INSERT INTO bench VALUES (' + IntToStr(i) + ', ''row' + IntToStr(i) + ''', ' + IntToStr(i * 2) + ')');
    sq.Exec('COMMIT');
    t1 := Tick;
    Writeln(Format('A) sq.Exec satir-satir : %.0f ms  (%d satir)', [Ms(t0, t1), N]));

    Fresh(kv, tb, sq);
    t0 := Tick;
    sq.Exec('BEGIN');
    for i := 1 to N do
      tb.Insert('bench', ['id', 'name', 'val'],
        [IntToStr(i), 'row' + IntToStr(i), IntToStr(i * 2)]);
    sq.Exec('COMMIT');
    t1 := Tick;
    Writeln(Format('B) tb.Insert dogrudan  : %.0f ms  (%d satir)', [Ms(t0, t1), N]));

    // C) cok-satirli VALUES — parca boyutu taramasi (parse bir kez/parca)
    for m := 0 to 4 do
    begin
      chunk := CHUNKS[m];
      Fresh(kv, tb, sq);
      t0 := Tick;
      sq.Exec('BEGIN');
      i := 1;
      sl := TStringList.Create;
      while i <= N do
      begin
        sl.Clear;
        c2 := 0;
        while (c2 < chunk) and (i <= N) do
        begin
          sl.Add('(' + IntToStr(i) + ',''row' + IntToStr(i) + ''',' + IntToStr(i * 2) + '),');
          Inc(i); Inc(c2);
        end;
        stmt := StringReplace(sl.Text, sLineBreak, '', [rfReplaceAll]);
        sq.Exec('INSERT INTO bench VALUES ' + Copy(stmt, 1, Length(stmt) - 1));
      end;
      sl.Free;
      sq.Exec('COMMIT');
      t1 := Tick;
      Writeln(Format('C) VALUES parca=%-5d : %.0f ms  (%.2f us/satir)',
        [chunk, Ms(t0, t1), Ms(t0, t1) * 1000 / N]));
    end;
  except
    on E: Exception do Writeln('HATA: ', E.Message);
  end;
  kv.Free; tb.Free; sq.Free;
end.
