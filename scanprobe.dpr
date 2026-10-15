program ScanProbe;

{$mode delphi}
{$APPTYPE CONSOLE}

{ R-26 tam kaniti: ayni oturumda ve yeniden acma sonrasi
  etiket sayilari + sorgu suresini karsilastirir. }

uses
  SysUtils, Classes,
  VDbCore, VDbTable, VDbSql, VDbTypes;

const
  B_ROWS = 500;
  N_SORU = 40;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;

procedure Setup(const dir: string; aRows: Integer);
var
  i: Integer;
begin
  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(dir);
  tb.Open(dir);
  sq.Exec('CREATE TABLE IF NOT EXISTS b(id INTEGER PRIMARY KEY, v TEXT)');
  sq.Exec('CREATE TABLE IF NOT EXISTS a(id INTEGER PRIMARY KEY, v TEXT)');
  for i := 1 to B_ROWS do
    sq.Exec(Format('INSERT INTO b(id,v) VALUES(%d,''bb%d'')', [i, i]));
  if aRows > 0 then
    for i := 1 to aRows do
      sq.Exec(Format('INSERT INTO a(id,v) VALUES(%d,''aaaa%d'')', [i, i]));
end;

procedure PrintTagsAndQuery(const ctx: string; aRows: Integer);
var
  tbDef, taDef: TTableDef;
  nAll, nB, nA, nUn: Integer;
  keys: TQWordArray;
  vals: TValArray;
  t0, t1, ms: Int64;
  j: Integer;
  r: TSqlResult;
begin
  tbDef := tb.GetTable('b');
  taDef := tb.GetTable('a');
  kv.ScanAll(keys, vals);           nAll := Length(keys);
  kv.ScanAll(keys, vals, tbDef.TableId); nB := Length(keys);
  kv.ScanAll(keys, vals, taDef.TableId); nA := Length(keys);
  kv.ScanAll(keys, vals, -1);       nUn := Length(keys);
  WriteLn(Format('%s  |  A=%7d  |  FIndex=%7d  |  b-filter=%6d  |  a-filter=%7d  |  -1=%7d',
    [ctx, aRows, nAll, nB, nA, nUn]));

  // sorgu olcum (icinma haric)
  r := sq.Exec('SELECT * FROM b LIMIT 10');
  t0 := GetTickCount64;
  for j := 1 to N_SORU do r := sq.Exec('SELECT * FROM b LIMIT 10');
  t1 := GetTickCount64;
  ms := t1 - t0;
  WriteLn(Format('%s  |  SELECT b LIMIT 10  ->  %5.1f ms/sorgu  (%d soru)',
    [ctx, ms / N_SORU, N_SORU]));
end;

procedure Measure(const aLabel: string; aRows: Integer);
var
  dir: string;
begin
  dir := 'C:\temp\scanprobe\' + aLabel + '_' + IntToStr(GetTickCount64);
  Setup(dir, aRows);

  // --- 1) AYNI OTURUM (Recover'siz) ---
  PrintTagsAndQuery('ayn?? oturum', aRows);

  // --- 2) YENIDEN AC (Recover FIndex'i dosyadan insa eder) ---
  FreeAndNil(sq); FreeAndNil(tb); FreeAndNil(kv);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(dir);
  tb.Open(dir);

  PrintTagsAndQuery('yeniden a?? (Recover)', aRows);

  // temizlik
  FreeAndNil(sq); FreeAndNil(tb); FreeAndNil(kv);
end;

begin
  WriteLn('R-26 kaniti: kucuk tablo sorgusu baska tablo boyutuna bagli mi?');
  WriteLn('Tablo sirasi: once b (500 satir), sonra a (degisken).');
  WriteLn(Format('Ayni oturumda %d sorgu, yeniden acip %d sorgu.', [N_SORU, N_SORU]));
  WriteLn;
  Measure('a0', 0);
  WriteLn;
  Measure('a50k', 50000);
  WriteLn;
  Measure('a150k', 150000);
  WriteLn;
WriteLn('Beklenti: ayni oturumda ve yeniden acta b sorgusu a tablosunun boyutundan');
  WriteLn('bagsiz ~5-15 ms civarinda olmali (etiket filtresi calisiyorsa).');
end.
