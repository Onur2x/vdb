program ScaleBench;

{$mode delphi}
{$APPTYPE CONSOLE}

{ TR: Olcek testi - yavaslik satir sayisiyla artiyor mu? (O(n^2) tespiti)
  EN: Scaling test - does slowness grow with row count? (O(n^2) detection) }

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  i: Integer;
  t0, t1: Int64;
  path: string;
  N: Integer;
  rates: array of Double;

{ TR: Dizindeki tum dosyalarin toplam boyutu (bayt) / EN: total bytes of all files in dir }
function DirSize(const ADir: string): Int64;
var
  rec: TSearchRec;
  res: Integer;
begin
  Result := 0;
  res := FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.*', faAnyFile, rec);
  while res = 0 do
  begin
    if (rec.Attr and faDirectory) = 0 then
      Inc(Result, rec.Size);
    res := FindNext(rec);
  end;
  FindClose(rec);
end;

procedure RunSize(APath: string; ASize: Integer);
var
  k: TVDb;
  t: TVTableDb;
  s: TVSql;
  j: Integer;
  tt0, tt1: Int64;
  insRate, selRate: Double;
begin
  if not DirectoryExists(APath) then ForceDirectories(APath);
  k := TVDb.Create;
  t := TVTableDb.Create(k);
  s := TVSql.Create(t);
  try
    k.Open(APath);
    t.Open(APath);

    s.Exec('DROP TABLE IF EXISTS sc');
    s.Exec('CREATE TABLE sc(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');

    // --- Batch INSERT (BEGIN/COMMIT icinde) ---
    tt0 := GetTickCount64;
    s.Exec('BEGIN');
    for j := 1 to ASize do
      s.Exec(Format('INSERT INTO sc(id,val,txt) VALUES(%d,%d,''t%d'')', [j, j * 2, j]));
    s.Exec('COMMIT');
    tt1 := GetTickCount64;
    if tt1 - tt0 > 0 then
      insRate := ASize / ((tt1 - tt0) / 1000.0)
    else
      insRate := 0;
    WriteLn(Format('  Batch INSERT %7d: %8.3f sn  %10.0f/sn', [ASize, (tt1 - tt0) / 1000.0, insRate]));

    // --- SELECT PK ---
    tt0 := GetTickCount64;
    for j := 1 to 5000 do
      s.Exec('SELECT val,txt FROM sc WHERE id = ' + IntToStr((j * ASize) div 5000));
    tt1 := GetTickCount64;
    if tt1 - tt0 > 0 then
      selRate := 5000.0 / ((tt1 - tt0) / 1000.0)
    else
      selRate := 0;
    WriteLn(Format('  SELECT PK  5000x: %8.3f sn  %10.0f/sn   (tablo %d satir)', [(tt1 - tt0) / 1000.0, selRate, ASize]));

    // --- UPDATE 5k tekil (transactionsiz) ---
    tt0 := GetTickCount64;
    for j := 1 to 5000 do
      s.Exec(Format('UPDATE sc SET val = val + 1 WHERE id = %d', [j]));
    tt1 := GetTickCount64;
    WriteLn(Format('  UPDATE 5k tekil:  %8.3f sn  %10.0f/sn', [(tt1 - tt0) / 1000.0, 5000.0 / ((tt1 - tt0) / 1000.0)]));

    // --- Dosya boyutu ---
    WriteLn(Format('  .odb dizin boyutu: %.2f MB', [DirSize(APath) / (1024.0 * 1024.0)]));
  finally
    s.Free;
    t.Free;
    k.Free;
  end;
end;

begin
  WriteLn('=== VDB Olcek Testi / Scaling Test ===');
  WriteLn;

  RunSize('C:\temp\sb10k', 10000);
  WriteLn;
  RunSize('C:\temp\sb50k', 50000);
  WriteLn;
  RunSize('C:\temp\sb100k', 100000);
  WriteLn;
  RunSize('C:\temp\sb200k', 200000);

  WriteLn;
  WriteLn('Yorum / Interpretation:');
  WriteLn('  Eger "Batch INSERT" hizi satir sayisiyla dusuyorsa -> O(n^2) var.');
  WriteLn('  EN: If insert rate FALLS as row count rises -> there is O(n^2).');
  WriteLn('  Eger hiz sabit kaliyorsa depolama katmani saglikli, sorun fsync.');
  WriteLn('  EN: If rate stays flat, storage is healthy and fsync is the culprit.');
end.
