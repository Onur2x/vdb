program LayerProbe;

{$mode delphi}
{$APPTYPE CONSOLE}

{ Yazma yolu katman katman ayristirma (transaction icinde):
  1) Tam yol      : sq.Exec('INSERT ...')       parse + executor + tablo + KV
  2) Tablo katmani: FT.Insert(...)              parse/executor YOK
  Fark = SQL katmaninin (parse + nesne + AST) payidir. }

uses
  SysUtils, Classes,
  VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N = 20000;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  t0, t1: Int64;
  i: Integer;
  msSql, msTbl: Int64;

procedure Reset;
begin
  sq.Exec('DROP TABLE IF EXISTS b');
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');
end;

procedure Mark(const baslik: string; ms: Int64);
begin
  WriteLn(Format('%-40s %6d ms  %9.0f satir/sn  %6.1f us/satir',
    [baslik, ms, N / (ms / 1000.0), ms * 1000.0 / N]));
end;

begin
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open('C:\temp\layerprobe');
    tb.Open('C:\temp\layerprobe');
    WriteLn(Format('N = %d satir, transaction icinde (BEGIN/COMMIT)', [N]));
    WriteLn;

    // 1) Tam yol
    Reset;
    t0 := GetTickCount64;
    sq.Exec('BEGIN');
    for i := 1 to N do
      sq.Exec(Format('INSERT INTO b(id,val,txt) VALUES(%d,%d,''t%d'')', [i, i * 2, i]));
    sq.Exec('COMMIT');
    t1 := GetTickCount64;
    msSql := t1 - t0;
    Mark('1) Tam yol sq.Exec', msSql);

    // 2) Tablo katmani (parse/executor yok)
    Reset;
    t0 := GetTickCount64;
    kv.BeginBatch;
    for i := 1 to N do
      tb.Insert('b', ['id', 'val', 'txt'],
        [IntToStr(i), IntToStr(i * 2), 't' + IntToStr(i)]);
    kv.CommitBatch;
    t1 := GetTickCount64;
    msTbl := t1 - t0;
    Mark('2) Tablo katmani FT.Insert', msTbl);

    WriteLn;
    WriteLn(Format('SQL katmani payi = (%d - %d) / %d = %.0f%%',
      [msSql, msTbl, msSql, 100.0 * (msSql - msTbl) / msSql]));
    WriteLn(Format('Tablo+KV payi                         = %.0f%%',
      [100.0 * msTbl / msSql]));
    WriteLn;
    WriteLn('Dogrulama: ', sq.Exec('SELECT COUNT(*) FROM b').Rows[0][0], ' satir');
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.
