{ H3 COUNT(*) indeks sayimi + aralik kesinligi kapi testi.

  Iki ozdes tablo kurar:
    c  : indeksli (ia, isidx, iab, ipart)
    c2 : indekssiz (tam tarama + RowMatches oracle)

  Her WHERE icin hem COUNT(*) hem SUM(id) karsilastirir. Boylece
  - satir okumadan sayan hizli yolun (TryIndexCount) ve
  - ayni kolondaki bitisik araliklarin "tam" sayilmesinin
  hicbir satiri atlamadigi / fazla saymadigi dogrulanir.

  Kullanim: countchk.exe }
{$mode delphi}
program countchk;

uses
  SysUtils, Windows, VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N = 5000;
  DIR = 'countchk_dir';

var
  GFreq: Int64;
  errs, checks: Integer;

function Tick: Int64;
var c: Int64;
begin
  QueryPerformanceCounter(c);
  Result := c;
end;

function MS(t0, t1: Int64): Double;
begin
  Result := (t1 - t0) * 1000 / GFreq;
end;

procedure WipeDir;
begin
  SysUtils.DeleteFile(DIR + '\veritabani.odb');
  SysUtils.DeleteFile(DIR + '\veritabani.schema');
  RemoveDir(DIR);
end;

procedure Fail(const Msg: string);
begin
  Inc(errs);
  Writeln('KALDI: ', Msg);
end;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  i, j: Integer;
  chunk, vs, aStr, sStr: string;
  w: string;
  co, cn, so, sn: string;
  R: TSqlResult;
  t0, t1: Int64;

  function Scalar(const SQL: string): string;
  begin
    R := sq.Exec(SQL);
    if Length(R.Rows) = 1 then
      Result := R.Rows[0][0]
    else
      Result := '<satir=' + IntToStr(Length(R.Rows)) + '>';
  end;

  procedure CheckOne(const W: string);
  var
    sqlO, sqlN: string;
  begin
    Inc(checks);
    sqlO := 'SELECT COUNT(*) FROM c WHERE ' + W;
    sqlN := 'SELECT COUNT(*) FROM c2 WHERE ' + W;
    co := Scalar(sqlO);
    cn := Scalar(sqlN);
    if co <> cn then
      Fail('COUNT uyusmadi [' + W + '] indeksli=' + co + ' oracle=' + cn);
    sqlO := 'SELECT SUM(id) FROM c WHERE ' + W;
    sqlN := 'SELECT SUM(id) FROM c2 WHERE ' + W;
    so := Scalar(sqlO);
    sn := Scalar(sqlN);
    if so <> sn then
      Fail('SUM(id) uyusmadi [' + W + '] indeksli=' + so + ' oracle=' + sn);
  end;

  procedure CheckAll(const Tag: string);
  begin
    CheckOne('a >= 10 AND a < 20');
    CheckOne('a = 42');
    CheckOne('a BETWEEN 10 AND 20');
    CheckOne('a IN (1,3,5,7)');
    CheckOne('a IN (1,3) AND a >= 2');
    CheckOne('a >= 10 AND a <= 20 AND a <> 15');
    CheckOne('a >= 10');
    CheckOne('a < 10');
    CheckOne('5 < a');
    CheckOne('5 >= a');
    CheckOne('a >= 10 AND b = 3');
    CheckOne('a = 42 AND b = 2');
    CheckOne('a = 42 AND a > 10');
    CheckOne('a = 42 AND a = 43');
    CheckOne('a >= 1000');
    CheckOne('a <= -1');
    CheckOne('a = NULL');
    CheckOne('a IS NULL');
    CheckOne('a IS NOT NULL');
    CheckOne('b > 3');
    CheckOne('b > -1');
    CheckOne('b >= 0');
    CheckOne('b < 5');
    CheckOne('b <= 5');
    CheckOne('b = 3');
    CheckOne('b = 0');
    CheckOne('b IS NULL');
    CheckOne('s = ' + QuotedStr('k3'));
    CheckOne('s >= ' + QuotedStr('k3') + ' AND s < ' + QuotedStr('k6'));
    CheckOne('LOWER(s) = ' + QuotedStr('k3'));
    CheckOne('a + 1 >= 10');
    CheckOne('a >= 10 OR a < 5');
    CheckOne('NOT (a < 10)');
    CheckOne('id = 100');
    CheckOne('id IN (1,2,3)');
    CheckOne('id IN (1,1,2)');
    CheckOne('id >= 100 AND id < 200');
    CheckOne('id < 200');
    CheckOne('id <= 200');
    CheckOne('id = 100 AND a >= 0');
    Writeln(Tag + ': ', checks, ' kontrol, ', errs, ' hata');
  end;

begin
  QueryPerformanceFrequency(GFreq);
  errs := 0; checks := 0;
  WipeDir;
  ForceDirectories(DIR);
  kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
  try
    kv.Open(DIR); tb.Open(DIR);
    sq.Exec('CREATE TABLE c(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, s TEXT)');
    sq.Exec('CREATE TABLE c2(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, s TEXT)');

    sq.Exec('BEGIN');
    i := 1;
    while i <= N do
    begin
      chunk := '';
      for j := 1 to 200 do
      begin
        if i > N then Break;
        if (i mod 13) = 0 then aStr := 'NULL'
        else aStr := IntToStr(i mod 100);
        if (i mod 17) = 0 then sStr := 'NULL'
        else sStr := QuotedStr('k' + IntToStr(i mod 10));
        vs := Format('(%d,%s,%d,%s)', [i, aStr, i mod 7, sStr]);
        if chunk <> '' then chunk := chunk + ',';
        chunk := chunk + vs;
        Inc(i);
      end;
      sq.Exec('INSERT INTO c(id,a,b,s) VALUES' + chunk);
      sq.Exec('INSERT INTO c2(id,a,b,s) VALUES' + chunk);
    end;
    sq.Exec('COMMIT');

    sq.Exec('CREATE INDEX iab ON c(a,b)');
    sq.Exec('CREATE INDEX isidx ON c(s)');
    sq.Exec('CREATE INDEX ipart ON c(b) WHERE b > 0');

    t0 := Tick;
    CheckAll('baslangic');

    // Pending update + tekrar sorgu (flush hizli yolu)
    sq.Exec('UPDATE c SET a = 200 WHERE id = 7');
    sq.Exec('UPDATE c2 SET a = 200 WHERE id = 7');
    sq.Exec('UPDATE c SET a = a + 1 WHERE id >= 1 AND id <= 100');
    sq.Exec('UPDATE c2 SET a = a + 1 WHERE id >= 1 AND id <= 100');
    sq.Exec('DELETE FROM c WHERE id IN (2,4,6)');
    sq.Exec('DELETE FROM c2 WHERE id IN (2,4,6)');
    CheckAll('update+delete sonrasi');

    // Rollback: yalnizca c degisir, geri alinmali
    sq.Exec('BEGIN');
    sq.Exec('UPDATE c SET a = 999 WHERE id >= 1 AND id <= 50');
    sq.Exec('ROLLBACK');
    CheckAll('rollback sonrasi');

    t1 := Tick;
    Writeln(Format('sure: %.1f ms', [MS(t0, t1)]));
  finally
    sq.Free; tb.Free; kv.Free;
  end;
  WipeDir;

  Writeln;
  if errs = 0 then
    Writeln('SONUC: TUM TESTLER GECTI')
  else
  begin
    Writeln('SONUC: KALDI (', errs, ' hata)');
    Halt(1);
  end;
end.
