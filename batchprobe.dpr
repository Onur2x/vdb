program BatchProbe;

{$mode delphi}
{$APPTYPE CONSOLE}

{ Yazma yolu genisletme deneyi:
  A) tek satirlik INSERT x N       (mevcut benchmark yolu)
  B) N/100 satirlik INSERT x 100  (coklu VALUES, parse 1 kez)
  C) N/1000 satirlik INSERT x 10  (daha da az statement)
  Hepsi AYNI transaction icinde (BEGIN/COMMIT), ayni satir sayisi. }

uses
  SysUtils, Classes,
  VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N = 10000;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  t0, t1: Int64;
  i, k, chunk: Integer;
  sql: string;

procedure Reset;
begin
  sq.Exec('DROP TABLE IF EXISTS b');
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)');
end;

procedure Meas(const baslik: string; perStmt: Integer);
var
  id: Integer;
  parts: string;
  nStmt: Integer;
begin
  Reset;
  id := 1;
  nStmt := 0;
  t0 := GetTickCount64;
  sq.Exec('BEGIN');
  while id <= N do
  begin
    parts := '';
    for k := 1 to perStmt do
    begin
      if id > N then Break;
      if parts <> '' then parts := parts + ',';
      parts := parts + Format('(%d,%d,''t%d'')', [id, id * 2, id]);
      Inc(id);
    end;
    sq.Exec('INSERT INTO b(id,val,txt) VALUES' + parts);
    Inc(nStmt);
  end;
  sq.Exec('COMMIT');
  t1 := GetTickCount64;
  WriteLn(Format('%-40s %6d ms  %9.0f satir/sn  (%d statement)',
    [baslik, t1 - t0, N / ((t1 - t0) / 1000.0), nStmt]));
end;

begin
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open('C:\temp\batchprobe');
    tb.Open('C:\temp\batchprobe');

    WriteLn(Format('N = %d satir, transaction icinde (BEGIN/COMMIT)', [N]));
    WriteLn;
    Meas('A) 1 satir/statement (mevcut yol)', 1);
    Meas('B) 100 satir/statement', 100);
    Meas('C) 500 satir/statement', 500);
    Meas('D) 1000 satir/statement', 1000);

    // dogrulama
    WriteLn;
    WriteLn('Dogrulama: ', sq.Exec('SELECT COUNT(*) FROM b').Rows[0][0], ' satir');
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.

