program AcDiag;

{$mode delphi}
{$APPTYPE CONSOLE}

{ HIPOTEZ: autocommit ile yazilan satirlarda R-26 etiketi eksik mi,
  yoksa sorgu baska bir yerde mi A'nin boyutuyla orantili calisiyor?
  Ayni oturumda (Recover'siz): etiket sayilari + sorgu suresi. }

uses
  SysUtils, Classes,
  VDbCore, VDbTable, VDbSql, VDbTypes;

const
  A_ROWS = 150000;
  B_ROWS = 500;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  dir: string;
  i, nAll, nB, nA, nUn: Integer;
  keys: TQWordArray;
  vals: TValArray;
  tbDef, taDef: TTableDef;
  t0, t1: Int64;
begin
  dir := 'C:\temp\acdiag_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);
    // scanprobe ile AYNI SIRA + AYNI MOD (autocommit, tek tek INSERT)
    sq.Exec('CREATE TABLE IF NOT EXISTS b(id INTEGER PRIMARY KEY, v TEXT)');
    sq.Exec('CREATE TABLE IF NOT EXISTS a(id INTEGER PRIMARY KEY, v TEXT)');
    for i := 1 to B_ROWS do
      sq.Exec(Format('INSERT INTO b(id,v) VALUES(%d,''bb%d'')', [i, i]));
    t0 := GetTickCount64;
    for i := 1 to A_ROWS do
      sq.Exec(Format('INSERT INTO a(id,v) VALUES(%d,''aaaa%d'')', [i, i]));
    t1 := GetTickCount64;
    WriteLn(Format('yazim (autocommit, %d satir): %d ms', [A_ROWS, t1 - t0]));
    WriteLn;

    tbDef := tb.GetTable('b');
    taDef := tb.GetTable('a');
    WriteLn(Format('b.TableId = %d , a.TableId = %d', [tbDef.TableId, taDef.TableId]));
    kv.ScanAll(keys, vals);           nAll := Length(keys);
    kv.ScanAll(keys, vals, tbDef.TableId); nB := Length(keys);
    kv.ScanAll(keys, vals, taDef.TableId); nA := Length(keys);
    kv.ScanAll(keys, vals, -1);       nUn := Length(keys);
    WriteLn(Format('FIndex toplam (filtresiz) : %d', [nAll]));
    WriteLn(Format('b filtresi ile donen      : %d', [nB]));
    WriteLn(Format('a filtresi ile donen      : %d', [nA]));
    WriteLn(Format('filtresiz (-1) donen      : %d', [nUn]));
    WriteLn;

    sq.Exec('SELECT * FROM b LIMIT 10');
    t0 := GetTickCount64;
    for i := 1 to 5 do sq.Exec('SELECT * FROM b LIMIT 10');
    t1 := GetTickCount64;
    WriteLn(Format('SELECT b LIMIT 10 : %d ms / 5 = %d ms', [t1 - t0, (t1 - t0) div 5]));
  finally
    FreeAndNil(sq); FreeAndNil(tb); FreeAndNil(kv);
  end;
end.

