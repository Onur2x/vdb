program SplitProbe;

{$mode delphi}
{$APPTYPE CONSOLE}

{ 1782 ms nereye gidiyor? Ayristirma:
  (a) FKv.ScanAll  -> dosya okuma + per-record tahsis + Move
  (b) kalan       -> DecodeRow + TableId filtresi + string insasi
  Eger (a) baskinsa: tablo id INDEKSTE olmali (okumadan elemeli).
  Eger (b) baskinsa: decode once tablo id okunup diger tablolar atlansin. }

uses
  SysUtils, Classes,
  VDbCore, VDbTable, VDbSql, VDbTypes;

const
  A_ROWS = 150000;
  B_ROWS = 500;
  N = 5;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  keys: TQWordArray;
  vals: TValArray;
  dir: string;
  t0, t1: Int64;
  j, i: Integer;
  scanMs, qryMs: Int64;
  r: TSqlResult;
begin
  dir := 'C:\temp\splitprobe_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);
    sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT)');
    sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, v TEXT)');
    for i := 1 to B_ROWS do
      sq.Exec(Format('INSERT INTO b(id,v) VALUES(%d,''bb%d'')', [i, i]));
    WriteLn('A tablosuna ', A_ROWS, ' satir yaz??l??yor...');
    sq.Exec('BEGIN');
    for i := 1 to A_ROWS do
      sq.Exec(Format('INSERT INTO a(id,v) VALUES(%d,''aaaa%d'')', [i, i]));
    sq.Exec('COMMIT');
    WriteLn('bitti. ikinci oturum: FIndex dosyadan yeniden kuruluyor');
  finally
    FreeAndNil(sq); FreeAndNil(tb); FreeAndNil(kv);
  end;

  // yeniden ac: Recover FIndex'i dosyadan insa eder
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);

    // (a) yalnizca ScanAll
    scanMs := 0;
    for j := 1 to N do
    begin
      t0 := GetTickCount64;
      kv.ScanAll(keys, vals);
      t1 := GetTickCount64;
      scanMs := scanMs + (t1 - t0);
    end;
    scanMs := scanMs div N;
    WriteLn(Format('kv.ScanAll            : %5d ms  (%d anahtar)', [scanMs, Length(keys)]));

    // (b) tam sorgu (ScanRowsPart dahil)
    qryMs := 0;
    for j := 1 to N do
    begin
      t0 := GetTickCount64;
      r := sq.Exec('SELECT * FROM b LIMIT 10');
      t1 := GetTickCount64;
      qryMs := qryMs + (t1 - t0);
    end;
    qryMs := qryMs div N;
    WriteLn(Format('SELECT b LIMIT 10     : %5d ms', [qryMs]));
    WriteLn;
    WriteLn(Format('-> ScanAll payi       : %5.1f%%', [scanMs * 100.0 / qryMs]));
    WriteLn(Format('-> decode+filtre payi : %5.1f%%  (%d ms)', [(qryMs - scanMs) * 100.0 / qryMs, qryMs - scanMs]));
    WriteLn(Format('-> satir basina toplam: %6.1f us (A=%d)', [qryMs * 1000.0 / A_ROWS, A_ROWS]));
  finally
    FreeAndNil(sq); FreeAndNil(tb); FreeAndNil(kv);
  end;
end.

