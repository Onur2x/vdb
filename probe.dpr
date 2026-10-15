program Probe;

{$mode delphi}
{$APPTYPE CONSOLE}

{ TR: COUNT(*) ham yolu + VDbFloatToStr sabit ayar ölçümü (1M satır).
  EN: COUNT(*) raw path + VDbFloatToStr static settings measurement. }
uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, VDbTypes;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  t0, t1: QWord;
  R: TSqlResult;

  procedure RunQ(const Q: string; Runs: Integer);
  var
    r2: Integer;
    tt0, tt1: QWord;
  begin
    tt0 := GetTickCount64;
    for r2 := 1 to Runs do
      R := sq.Exec(Q);
    tt1 := GetTickCount64;
    WriteLn(Format('  %-46s %6d ms/run  [%s=%s]',
      [Q, (tt1 - tt0) div Runs, R.Fields[0], R.Rows[0][0]]));
  end;

begin
  kv := TVDb.Create; tb := TVTableDb.Create(kv);
  try
    kv.Open('C:\temp\vdb1m'); tb.Open('C:\temp\vdb1m');
    sq := TVSql.Create(tb);
    try
      WriteLn('-- sorgu (1M satir) --');
      RunQ('SELECT COUNT(*) FROM musteri', 3);
      RunQ('SELECT COUNT(*) FROM musteri', 1);
      RunQ('SELECT * FROM musteri', 1);
      RunQ('SELECT SUM(id) FROM musteri', 1);
      RunQ('SELECT COUNT(*) FROM musteri WHERE yas = 25', 1);
      RunQ('SELECT COUNT(*) FROM musteri WHERE id > 100', 1);
    finally
      sq.Free;
    end;
  finally
    tb.Free; kv.Free;
  end;
end.
