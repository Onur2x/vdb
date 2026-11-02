program scanpushbench;
{ Tarama-seviyesi join pushdown olcumu (v3.35).
  Buyuk sag tablo + secici sag taraf filtresi.
  Kullanim: scanpushbench <dizin> [sag_satir] [sol_satir]
  Cikis: her sorgu icin sure (ms) + satir sayisi. }
{$mode delphi}{$H+}
uses
  SysUtils, Classes,
  VDbCore, VDbTypes, VDbTable, VDbSql;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  dir: string;
  nR, nL, i, k: Integer;
  t0, t1: QWord;
  R: TSqlResult;
  ad: string;

function NowMs: QWord;
begin
  Result := GetTickCount64;
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: scanpushbench <dizin> [sag_satir=100000] [sol_satir=100]');
    Halt(2);
  end;
  dir := ParamStr(1);
  nR := 100000;
  nL := 100;
  if ParamCount >= 2 then nR := StrToIntDef(ParamStr(2), 100000);
  if ParamCount >= 3 then nL := StrToIntDef(ParamStr(3), 100);

  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(dir);
  tb.Open(dir);

  WriteLn('scanpushbench: sag=', nR, ' sol=', nL);

  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, k INTEGER, y INTEGER, ad TEXT)');
  sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('CREATE INDEX idx_b_y ON b(y)');
  sq.Exec('CREATE INDEX idx_b_k ON b(k)');

  WriteLn('  veri yukleniyor...');
  t0 := NowMs;
  tb.BeginBatch;
  for i := 1 to nR do
  begin
    ad := 'satir-' + IntToStr(i);
    sq.Exec('INSERT INTO b VALUES(' + IntToStr(i) + ',' + IntToStr(i) + ',' +
      IntToStr(i) + ',''' + ad + ''')');
    if (i mod 20000) = 0 then
      WriteLn('    ', i, '/', nR, ' (', NowMs - t0, ' ms)');
  end;
  for i := 1 to nL do
    sq.Exec('INSERT INTO a VALUES(' + IntToStr(i) + ',' + IntToStr(i) + ')');
  tb.CommitBatch;
  WriteLn('  veri: ', NowMs - t0, ' ms');

  { Sorgu 1: secici sag filtre — NarrowRows daraltmasi beklenen }
  WriteLn;
  for k := 1 to 2 do
  begin
    WriteLn('S1.', k, ': SELECT COUNT(*) FROM a JOIN b ON a.k=b.k WHERE b.y > ', nR - 10);
    t0 := NowMs;
    R := sq.Exec('SELECT COUNT(*) FROM a JOIN b ON a.k=b.k WHERE b.y > ' + IntToStr(nR - 10));
    t1 := NowMs;
    WriteLn('  sonuc=', R.Rows[0][0], '  sure=', t1 - t0, ' ms');
  end;

  { Sorgu 2: genis sag filtre — daraltma az, taban olcum }
  for k := 1 to 2 do
  begin
    WriteLn('S2.', k, ': SELECT COUNT(*) FROM a JOIN b ON a.k=b.k WHERE b.y > 0');
    t0 := NowMs;
    R := sq.Exec('SELECT COUNT(*) FROM a JOIN b ON a.k=b.k WHERE b.y > 0');
    t1 := NowMs;
    WriteLn('  sonuc=', R.Rows[0][0], '  sure=', t1 - t0, ' ms');
  end;

  { Sorgu 3: sol taraf filtresi (sag daraltma etkisiz olmali) }
  for k := 1 to 2 do
  begin
    WriteLn('S3.', k, ': SELECT COUNT(*) FROM a JOIN b ON a.k=b.k WHERE a.k > ', nL - 5);
    t0 := NowMs;
    R := sq.Exec('SELECT COUNT(*) FROM a JOIN b ON a.k=b.k WHERE a.k > ' + IntToStr(nL - 5));
    t1 := NowMs;
    WriteLn('  sonuc=', R.Rows[0][0], '  sure=', t1 - t0, ' ms');
  end;

  { Sorgu 4: ON icinde sag filtre }
  for k := 1 to 2 do
  begin
    WriteLn('S4.', k, ': SELECT COUNT(*) FROM a JOIN b ON a.k=b.k AND b.y > ', nR - 10);
    t0 := NowMs;
    R := sq.Exec('SELECT COUNT(*) FROM a JOIN b ON a.k=b.k AND b.y > ' + IntToStr(nR - 10));
    t1 := NowMs;
    WriteLn('  sonuc=', R.Rows[0][0], '  sure=', t1 - t0, ' ms');
  end;

  sq.Free; tb.Free; kv.Free;
  WriteLn('TEMIZ');
end.