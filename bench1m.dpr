program Bench1M;

{$mode delphi}
{$APPTYPE CONSOLE}

{ TR: 1 milyon satir gercek olcek testi
  EN: Real 1M-row scale test

  BEGIN/COMMIT sarmali yukleme ile olcer; motor kodunu degistirmeden
  kullanilabilen en hizli yol budur. }

uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N = 1000000;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  i: Integer;
  t0, t1: Int64;
  oldB, newB: Int64;
  path: string;

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

function Mb(AB: Int64): Double;
begin
  Result := AB / (1024.0 * 1024.0);
end;

function Rps(AN: Int64; AMS: Int64): Double;
begin
  if AMS <= 0 then Result := 0 else Result := AN / (AMS / 1000.0);
end;

begin
  path := 'C:\temp\vdb1m';
  if DirectoryExists(path) then
  begin
    // onceki kaliintilari temizle
    for i := 0 to 5 do
      DeleteFile(IncludeTrailingPathDelimiter(path) + 'veritabani' + IntToStr(i) + '.odb');
    DeleteFile(IncludeTrailingPathDelimiter(path) + 'veritabani.odb');
  end
  else
    ForceDirectories(path);

  WriteLn('=== VDB 1M OLCEK TESTI / 1M SCALE TEST ===');
  WriteLn('Dizin: ', path);
  WriteLn;

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(path);
    tb.Open(path);

    sq.Exec('CREATE TABLE musteri(id INTEGER PRIMARY KEY, ad TEXT, yas INTEGER, bakiye DOUBLE, notu TEXT)');

    // ---------- 1) 1M INSERT (BEGIN/COMMIT sarmali) ----------
    WriteLn('-- 1) ', N, ' INSERT (BEGIN/COMMIT) --');
    t0 := GetTickCount64;
    sq.Exec('BEGIN');
    for i := 1 to N do
      sq.Exec(Format('INSERT INTO musteri(id,ad,yas,bakiye,notu) VALUES(%d,''musteri-%d'',%d,%d.5,''aciklama metni %d'')',
        [i, i, i mod 80, i mod 10000, i]));
    sq.Exec('COMMIT');
    t1 := GetTickCount64;
    WriteLn(Format('  sure      : %.2f sn', [(t1 - t0) / 1000.0]));
    WriteLn(Format('  hiz       : %.0f INSERT/sn', [Rps(N, t1 - t0)]));
    WriteLn(Format('  dosya     : %.2f MB', [Mb(DirSize(path))]));
    WriteLn(Format('  bayt/satir: %.1f', [DirSize(path) / N]));

    // ---------- 2) SELECT PK ----------
    WriteLn;
    WriteLn('-- 2) SELECT PK (50.000 nokta arama, ', N, ' satirlik tabloda) --');
    t0 := GetTickCount64;
    for i := 1 to 50000 do
      // Int64: i*N 50000*1M = 5e10 degeri 32-bit Integer'da tasiyordu
      sq.Exec('SELECT ad,yas,bakiye FROM musteri WHERE id = ' + IntToStr((Int64(i) * Int64(N)) div 50000));
    t1 := GetTickCount64;
    WriteLn(Format('  sure      : %.2f sn', [(t1 - t0) / 1000.0]));
    WriteLn(Format('  hiz       : %.0f SELECT/sn', [Rps(50000, t1 - t0)]));

    // ---------- 3) UPDATE 100k ----------
    WriteLn;
    WriteLn('-- 3) UPDATE 100.000 (BEGIN/COMMIT) --');
    t0 := GetTickCount64;
    sq.Exec('BEGIN');
    for i := 1 to 100000 do
      sq.Exec(Format('UPDATE musteri SET yas = yas + 1 WHERE id = %d', [i]));
    sq.Exec('COMMIT');
    t1 := GetTickCount64;
    WriteLn(Format('  sure      : %.2f sn', [(t1 - t0) / 1000.0]));
    WriteLn(Format('  hiz       : %.0f UPDATE/sn', [Rps(100000, t1 - t0)]));

    // ---------- 4) DELETE 100k ----------
    WriteLn;
    WriteLn('-- 4) DELETE 100.000 (BEGIN/COMMIT) --');
    t0 := GetTickCount64;
    sq.Exec('BEGIN');
    for i := 1 to 100000 do
      sq.Exec(Format('DELETE FROM musteri WHERE id = %d', [i]));
    sq.Exec('COMMIT');
    t1 := GetTickCount64;
    WriteLn(Format('  sure      : %.2f sn', [(t1 - t0) / 1000.0]));
    WriteLn(Format('  hiz       : %.0f DELETE/sn', [Rps(100000, t1 - t0)]));
    WriteLn(Format('  dosya     : %.2f MB  (silme SONRASI - tombstone)', [Mb(DirSize(path))]));
    WriteLn(Format('  olu bayt  : %.2f MB', [Mb(kv.DeadBytes)]));

    // ---------- 5) COMPACT ----------
    WriteLn;
    WriteLn('-- 5) COMPACT (olu kayitlari temizle) --');
    t0 := GetTickCount64;
    kv.Compact(oldB, newB);
    t1 := GetTickCount64;
    WriteLn(Format('  sure      : %.2f sn', [(t1 - t0) / 1000.0]));
    WriteLn(Format('  oncesi    : %.2f MB -> sonrasi %.2f MB', [Mb(oldB), Mb(newB)]));
    WriteLn(Format('  dosya     : %.2f MB  (COMPACT sonrasi)', [Mb(DirSize(path))]));

    // ---------- 6) Kapanis + yeniden acilis ----------
    WriteLn;
    WriteLn('-- 6) Yeniden acilis (kurtarma taramasi dahil) --');
    sq.Free; tb.Free; kv.Free;
    t0 := GetTickCount64;
    kv := TVDb.Create;
    tb := TVTableDb.Create(kv);
    sq := TVSql.Create(tb);
    kv.Open(path);
    tb.Open(path);
    t1 := GetTickCount64;
    WriteLn(Format('  acilis    : %.2f sn', [(t1 - t0) / 1000.0]));
    WriteLn(Format('  dosya     : %.2f MB', [Mb(DirSize(path))]));

    i := 0;
    with sq.Exec('SELECT COUNT(*) FROM musteri') do
      if Length(Rows) > 0 then
        WriteLn(Format('  satir     : %s (900.000 beklenir)', [Rows[0][0]]));

    WriteLn;
    WriteLn('=== BITTI / DONE ===');
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.
