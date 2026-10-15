program ParseProbe;

{$mode delphi}
{$APPTYPE CONSOLE}

{ Exec icinde parse + nesne olusturma kaciyor?
  ExecRaw birebir taklit edilir: TVDbParser.Create + Parse + Free.
  Karsilastirma icin: saf parse (parser tek) ve tam Exec. }

uses
  SysUtils, VDbParser, VDbAst, VDbTable, VDbSql, VDbCore, VDbTypes;

const
  N = 10000;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  t0, t1, msParse, msExec: Int64;
  i, j: Integer;
  dummy: TSqlResult;
  pars: TVDbParser;
  stmt: TSqlStmtNode;

begin
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open('C:\temp\parseprobe');
    tb.Open('C:\temp\parseprobe');
    sq.Exec('DROP TABLE IF EXISTS b');
    sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, val INTEGER)');
    sq.Exec('BEGIN');
    for i := 1 to 1000 do
      sq.Exec(Format('INSERT INTO b(id,val) VALUES(%d,%d)', [i, i]));
    sq.Exec('COMMIT');

    WriteLn(Format('N = %d tekrar, ifade: SELECT val FROM b WHERE id = 12345', [N]));

    // 1) ExecRaw'in parse fazi birebir: her seferinde yeni parser nesnesi
    t0 := GetTickCount64;
    for j := 1 to N do
    begin
      pars := TVDbParser.Create;
      try
        stmt := pars.Parse('SELECT val FROM b WHERE id = 12345', []);
        stmt.Free;
      finally
        pars.Free;
      end;
    end;
    t1 := GetTickCount64;
    msParse := t1 - t0;
    WriteLn(Format('1) Parse fazi (yeni nesne/her is)      : %6d ms  %8.1f us/is',
      [msParse, msParse * 1000.0 / N]));

    // 2) Tek parser nesnesi, tekrar tekrar parse (cache ile ayni is)
    pars := TVDbParser.Create;
    try
      t0 := GetTickCount64;
      for j := 1 to N do
      begin
        stmt := pars.Parse('SELECT val FROM b WHERE id = 12345', []);
        stmt.Free;
      end;
      t1 := GetTickCount64;
      WriteLn(Format('2) Saf parse (nesne tek)               : %6d ms  %8.1f us/is',
        [t1 - t0, (t1 - t0) * 1000.0 / N]));
    finally
      pars.Free;
    end;

    // 3) Tam Exec (parse + executor + yurutme) - mevcut durum
    t0 := GetTickCount64;
    for j := 1 to N do
      dummy := sq.Exec('SELECT val FROM b WHERE id = 12345');
    t1 := GetTickCount64;
    msExec := t1 - t0;
    WriteLn(Format('3) Tam Exec (mevcut durum)             : %6d ms  %8.1f us/is',
      [msExec, msExec * 1000.0 / N]));

    WriteLn;
    if msExec > 0 then
      WriteLn(Format('Ayristirma payi = 1 / 3 = %.0f%%', [100.0 * msParse / msExec]))
    else
      WriteLn('Ayristirma payi olcum disi');
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
end.
