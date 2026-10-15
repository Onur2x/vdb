program SchemaProbe;

{$mode delphi}
{$APPTYPE CONSOLE}

{ Hipotez: tek satir autocommit INSERT, artan integer PK'da HER SEFER
  MarkSchema -> SaveSchema (tum semayi yeniden serialize + yaz) cagiriyor.
  Kanit: dar tablo (2 kolon) vs genis tablo (40 kolon) ayni INSERT hizi.
  SaveSchema baskinsa genis tablo belirgin sekilde yavas olmali.
  Ayrica: ayni INSERT'i transaction icinde (MarkSchema -> sadece bayrak)
  karsilastirilir. }

uses
  SysUtils, Classes,
  VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N = 3000;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  t0, t1: Int64;
  i, c: Integer;
  colDef: string;

procedure RunMode(const baslik: string; nCols: Integer; inTx: Boolean);
var
  ddl, ins: string;
  j: Integer;
  ms: Int64;
begin
  sq.Exec('DROP TABLE IF EXISTS t');
  colDef := 'id INTEGER PRIMARY KEY, v0 INTEGER';
  for j := 1 to nCols - 2 do
    colDef := colDef + Format(', c%d TEXT DEFAULT ''x''', [j]);
  sq.Exec('CREATE TABLE t(' + colDef + ')');

  t0 := GetTickCount64;
  if inTx then sq.Exec('BEGIN');
  for j := 1 to N do
  begin
    if inTx then
      sq.Exec(Format('INSERT INTO t(id,v0) VALUES(%d,%d)', [j, j]))
    else
      sq.Exec(Format('INSERT INTO t(id,v0) VALUES(%d,%d)', [j, j]));
  end;
  if inTx then sq.Exec('COMMIT');
  t1 := GetTickCount64;
  ms := t1 - t0;
  WriteLn(Format('%-46s %6d ms  %8.0f satir/sn  %6.1f us/satir',
    [baslik, ms, N / (ms / 1000.0), ms * 1000.0 / N]));
end;

begin
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open('C:\temp\schemaprobe');
    tb.Open('C:\temp\schemaprobe');
    WriteLn(Format('N = %d tek satir INSERT (autocommit = BEGIN/COMMIT yok)', [N]));
    WriteLn;

    RunMode('DAR tablo (2 kolon), autocommit', 2, False);
    RunMode('GENIS tablo (40 kolon), autocommit', 40, False);
    RunMode('COK GENIS tablo (80 kolon), autocommit', 80, False);
    WriteLn;
    RunMode('DAR tablo (2 kolon), transaction icinde', 2, True);
    RunMode('GENIS tablo (40 kolon), transaction icinde', 40, True);

    WriteLn;
    WriteLn('Kontrol (satir sayisi): ', sq.Exec('SELECT COUNT(*) FROM t').Rows[0][0]);
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.
