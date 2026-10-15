program TagDiag;

{$mode delphi}
{$APPTYPE CONSOLE}

{ R-26 etiket dogrulamasi:
  1) Tum FIndex kayitlarinin TableId dagilimi ne? (-1 kac tane?)
  2) TableFilter'li ScanAll kac anahtar donduruyor?
  3) Sorgu suresi ne?
  Tablo SIRASI scanprobe ile ayni: once b, sonra a. }

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

procedure CountTags(filter: Integer; var cnt: Integer);
begin
  kv.ScanAll(keys, vals, filter);
  cnt := Length(keys);
end;

begin
  dir := 'C:\temp\tagdiag_' + IntToStr(GetTickCount64);
  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);
    // scanprobe ile AYNI SIRA: once b, sonra a
    sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, v TEXT)');
    sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT)');
    for i := 1 to B_ROWS do
      sq.Exec(Format('INSERT INTO b(id,v) VALUES(%d,''bb%d'')', [i, i]));
    sq.Exec('BEGIN');
    for i := 1 to A_ROWS do
      sq.Exec(Format('INSERT INTO a(id,v) VALUES(%d,''aaaa%d'')', [i, i]));
    sq.Exec('COMMIT');

    // ---- AYNI OTURUM (Recover'siz): AppendRec etiketi koyabiliyor mu? ----
    tbDef := tb.GetTable('b');
    taDef := tb.GetTable('a');
    WriteLn('--- AYNI OTURUM (yazim sonrasi, Recover yok) ---');
    WriteLn(Format('b.TableId = %d , a.TableId = %d', [tbDef.TableId, taDef.TableId]));
    kv.ScanAll(keys, vals);           nAll := Length(keys);
    CountTags(tbDef.TableId, nB);
    CountTags(taDef.TableId, nA);
    CountTags(-1, nUn);
    WriteLn(Format('FIndex toplam (filtresiz) : %d', [nAll]));
    WriteLn(Format('b filtresi ile donen      : %d', [nB]));
    WriteLn(Format('a filtresi ile donen      : %d', [nA]));
    WriteLn(Format('filtresiz (-1) donen      : %d', [nUn]));
    sq.Exec('SELECT * FROM b LIMIT 10');
    t0 := GetTickCount64;
    for i := 1 to 5 do sq.Exec('SELECT * FROM b LIMIT 10');
    t1 := GetTickCount64;
    WriteLn(Format('  SELECT b LIMIT 10 : %d ms / 5 = %d ms', [t1 - t0, (t1 - t0) div 5]));
    WriteLn;
  finally
    FreeAndNil(sq); FreeAndNil(tb); FreeAndNil(kv);
  end;

  // 2. oturum: Recover FIndex'i dosyadan insa eder (R-26 tag burada dolar)
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);
    tbDef := tb.GetTable('b');
    taDef := tb.GetTable('a');
    WriteLn(Format('b.TableId = %d , a.TableId = %d', [tbDef.TableId, taDef.TableId]));

    kv.ScanAll(keys, vals);           nAll := Length(keys);
    CountTags(tbDef.TableId, nB);
    CountTags(taDef.TableId, nA);
    CountTags(-1, nUn);
    WriteLn(Format('FIndex toplam (filtresiz) : %d', [nAll]));
    WriteLn(Format('b filtresi ile donen      : %d', [nB]));
    WriteLn(Format('a filtresi ile donen      : %d', [nA]));
    WriteLn(Format('filtresiz (-1) donen      : %d', [nUn]));
    WriteLn;

    // etiket dagilimini dogrudan goruntule
    WriteLn('Sorgu suresi (5 tur, ilk isinma haric):');
    sq.Exec('SELECT * FROM b LIMIT 10');
    t0 := GetTickCount64;
    for i := 1 to 5 do begin sq.Exec('SELECT * FROM b LIMIT 10'); end;
    t1 := GetTickCount64;
    WriteLn(Format('  SELECT b LIMIT 10 : %d ms / 5 = %d ms', [t1 - t0, (t1 - t0) div 5]));

    t0 := GetTickCount64;
    for i := 1 to 5 do begin sq.Exec('SELECT * FROM a LIMIT 10'); end;
    t1 := GetTickCount64;
    WriteLn(Format('  SELECT a LIMIT 10 : %d ms / 5 = %d ms', [t1 - t0, (t1 - t0) div 5]));
  finally
    FreeAndNil(sq); FreeAndNil(tb); FreeAndNil(kv);
  end;
end.

