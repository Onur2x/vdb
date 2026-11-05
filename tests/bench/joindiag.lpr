program joindiag;
{ Join taraflari materyalizasyon maliyeti ayrimi (P-87 aday arastirmasi).
  scanpushbench S6'daki ~500 ms'in kaynagini bolmek icin:
  tam tablo taramasi / filtreli tarama / hash join / indeks join.
  Kullanim: joindiag <dizin> [satir=100000]
  Cikis: her sorgu icin sure (us) + satir sayisi. }
{$mode delphi}{$H+}
uses
  Windows, SysUtils, Classes,
  VDbMM, // P-110: ozel bellek yoneticisi (initialization'da kurulur)
  VDbCore, VDbTypes, VDbTable, VDbSql;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  dir: string;
  nR, i: Integer;
  gQpf: Int64;
  R: TSqlResult;
  ad: string;

function NowUs: Int64;
var
  c: Int64;
begin
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then
    Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then
    Result := (c * 1000) div gQpf
  else
    Result := c * 1000;
end;

procedure Q(const Title, Sql: string; RepeatN: Integer);
var
  t0, t1, best: Int64;
  n, k: Integer;
begin
  best := High(Int64);
  for k := 1 to RepeatN do
  begin
    t0 := NowUs;
    R := sq.Exec(Sql);
    t1 := NowUs;
    if t1 - t0 < best then best := t1 - t0;
  end;
  n := Length(R.Rows);
  WriteLn(Title);
  WriteLn('  sonuc=', n, '  en_iyi=', best, ' us  ', Sql);
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: joindiag <dizin> [satir=100000]');
    Halt(2);
  end;
  dir := ParamStr(1);
  nR := 100000;
  if ParamCount >= 2 then nR := StrToIntDef(ParamStr(2), 100000);
  MMSingleThreaded := True; // P-110 v4: tek is parcacigi — spinlock atla
  ForceDirectories(dir);
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  kv.Open(dir);
  tb.Open(dir);

  WriteLn('joindiag: sag=', nR);
  sq.Exec('CREATE TABLE b(id INTEGER PRIMARY KEY, k INTEGER, y INTEGER, ad TEXT)');
  sq.Exec('CREATE TABLE a(id INTEGER PRIMARY KEY, k INTEGER)');
  sq.Exec('CREATE INDEX idx_b_y ON b(y)');
  sq.Exec('CREATE INDEX idx_b_k ON b(k)');

  WriteLn('  veri yukleniyor...');
  tb.BeginBatch;
  for i := 1 to nR do
  begin
    ad := 'satir-' + IntToStr(i);
    sq.Exec('INSERT INTO b VALUES(' + IntToStr(i) + ',' + IntToStr(i) + ',' +
      IntToStr(i) + ',''' + ad + ''')');
  end;
  for i := 1 to 100 do
    sq.Exec('INSERT INTO a VALUES(' + IntToStr(i) + ',' + IntToStr(i) + ')');
  tb.CommitBatch;

  WriteLn;
  Q('A) tek tablo COUNT(*) — KR-1B sayac yolu',
    'SELECT COUNT(*) FROM b', 3);
  Q('B) tek tablo tam tarama — SELECT * materyalizasyonu',
    'SELECT b.id, b.k, b.y, b.ad FROM b', 3);
  Q('C) tek tablo WHERE ile sayim (ham akis?)',
    'SELECT COUNT(*) FROM b WHERE b.y > 0', 3);
  Q('D) S6: b JOIN a hash join + WHERE',
    'SELECT COUNT(*) FROM b JOIN a ON a.k=b.k WHERE b.y > 0', 3);
  Q('E) S6 sonuc satirlariyla (100 satir)',
    'SELECT b.id, a.id FROM b JOIN a ON a.k=b.k WHERE b.y > 0', 3);
  Q('F) S2: a JOIN b indeks join (P-86)',
    'SELECT COUNT(*) FROM a JOIN b ON a.k=b.k WHERE b.y > 0', 3);
  Q('G) sol yalniz indeksli filtre (v3.37 NarrowRows)',
    'SELECT COUNT(*) FROM b JOIN a ON a.k=b.k WHERE b.y > ' + IntToStr(nR - 10), 3);

  sq.Free; tb.Free; kv.Free;
  WriteLn('TEMIZ');
end.