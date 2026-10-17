program bench_mixed;

{$mode delphi}
{$APPTYPE CONSOLE}

{ KR-1 dogrulama mikro-testi: KARISIK (cok tablolu) veritabaninda TEK bir
  tablonun taranmasi. R-26 yalnizca diger tablolarin KAYITLARINI okumayi
  onler; KR-1 ise tarama icin FIndex'in TAMAMINI degil yalnizca hedef
  tablonun anahtar dizinini dolasir. Bu test NT tablo x NR satir kurar ve
  t0 uzerinde tekrarli SUM taramasi olcer.

  Kullanim: bench_mixed.exe [dizin] [NT] [NR] [NSCAN] }

uses
  SysUtils, Windows, VDbCore, VDbTable, VDbSql, VDbTypes;

var
  GFreq: Int64;

function NowTick: Int64;
var c: Int64;
begin
  QueryPerformanceCounter(c);
  Result := c;
end;

function Sec(t0, t1: Int64): Double;
begin
  Result := (t1 - t0) / GFreq;
end;

var
  dir: string;
  NT, NR, NSCAN: Integer;
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  R: TSqlResult;
  i, j, s, k, col: Integer;
  chunk: string;
  t0, t1: Int64;
  chk: Int64;
begin
  QueryPerformanceFrequency(GFreq);
  dir := 'C:\temp\bench_mixed';
  NT := 20; NR := 20000; NSCAN := 40;
  if ParamCount >= 1 then dir := ParamStr(1);
  if ParamCount >= 2 then NT := StrToIntDef(ParamStr(2), NT);
  if ParamCount >= 3 then NR := StrToIntDef(ParamStr(3), NR);
  if ParamCount >= 4 then NSCAN := StrToIntDef(ParamStr(4), NSCAN);

  if DirectoryExists(dir) then RemoveDir(dir);
  ForceDirectories(dir);

  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    kv.Open(dir);
    tb.Open(dir);

    // NT tablo kur + her birine NR satir bas
    for i := 0 to NT - 1 do
    begin
      sq.Exec(Format('CREATE TABLE t%d(id INTEGER PRIMARY KEY, val INTEGER, txt TEXT)', [i]));
      sq.Exec('BEGIN');
      j := 1;
      while j <= NR do
      begin
        chunk := '';
        for k := 1 to 200 do
        begin
          if j > NR then Break;
          if chunk <> '' then chunk := chunk + ',';
          chunk := chunk + Format('(%d,%d,''x%d'')', [j, j * 2, j]);
          Inc(j);
        end;
        sq.Exec(Format('INSERT INTO t%d(id,val,txt) VALUES', [i]) + chunk);
      end;
      sq.Exec('COMMIT');
    end;

    WriteLn(Format('DB: %d tablo x %d satir = %d satir toplam; hedef t0', [NT, NR, NT * NR]));

    // Isinma (index/onbellek)
    R := sq.Exec('SELECT SUM(val) FROM t0');

    // Tek tablo taramasi (R-26 + KR-1 yolunun tamami)
    chk := 0;
    t0 := NowTick;
    for s := 1 to NSCAN do
    begin
      R := sq.Exec('SELECT SUM(val) FROM t0');
      if Length(R.Rows) > 0 then Inc(chk, StrToInt64Def(R.Rows[0][0], 0));
    end;
    t1 := NowTick;
    WriteLn(Format('t0 SUM x%d : %.3f sn  (%.2f ms/tarama)  chk=%d',
      [NSCAN, Sec(t0, t1), Sec(t0, t1) * 1000 / NSCAN, chk]));

    // Kontrol: sqlite-benzeri tam sonuc
    R := sq.Exec('SELECT COUNT(*) FROM t0');
    WriteLn('t0 satir sayisi = ', R.Rows[0][0]);
  finally
    sq.Free;
    tb.Free;
    kv.Free;
  end;
  WriteLn('Bitti.');
end.
