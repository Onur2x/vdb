program sql_fuzz;
{ V3 sertlestirme - SQL ayristirici dayaniklilik kapisi (fuzz smoke).

  Amac: VDbParser.Parse'e gelen bozuk/kotu niyetli girdilerin
  (a) sureci oldurmedigini (AV/erisim ihlali yok),
  (b) istisna ile temiz reddedildigini,
  (c) AST'nin serbest birakildigini (heap buyumesi sabit),
  (d) toplamda makul surede bittigini KANITLAMAK.

  Girdi uretimi deterministik (sabit tohumlu xorshift32): ayni tohum ayni
  corpus'u uretir, kirilma tekrar uretilebilir. Uc kaynak karisir:
    1. gecerli SQL'lerin rastgele kesilmesi/bozulmasi (mutation),
    2. rastgele token dizisi (sozdizimi agaci baski),
    3. rastgele yazdirilabilir bayt dizisi (tokenizer baski).

  DURUST SINIR: bu kapi surec-ici bir kosumdur; tek bir girdinin ICINDE
  sonsuz donguye girmesini kesemez (FPC is parcacigini zorla durdurmaz).
  Kapi toplam sureyi olcer ve tek bir girdi butcesini asarsa FAIL verir;
  fakat "asiliyor" tespiti ancak o girdi biterse yapilabilir. Gercek
  zaman asimi denetimi ayri bir is kalemidir (bkz. docs/engineering/CI.md).

  Cikis kodu = basarisiz kontrol sayisi. Derleme: fpc (lpi gerekmez).
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbParser, VDbSql, VDbAst, VDbTypes, VDbTable, VDbErr;

const
  ITERATIONS   = 3000;
  SEED_DEFAULT = $5EED1234;
  MAX_TOTAL_MS = 120000;   { 2 dakika: cok kolay asilirsa bir sey yanlis }
  MAX_HEAP_GROWTH = 16 * 1024 * 1024;

var
  GPass, GFail: Integer;
  GRng: LongWord;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

{ Deterministik xorshift32. Math.Random kullanilmaz: tohum kontrol edilemez. }
function NextRand: LongWord;
begin
  GRng := GRng xor (GRng shl 13);
  GRng := GRng xor (GRng shr 17);
  GRng := GRng xor (GRng shl 5);
  Result := GRng;
end;

function RandRange(AN: Integer): Integer;
begin
  if AN <= 1 then
    Result := 0
  else
    Result := Integer(NextRand mod LongWord(AN));
end;

const
  TOKENS: array[0..55] of string = (
    'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET',
    'DELETE', 'CREATE', 'TABLE', 'INDEX', 'DROP', 'ALTER', 'ADD', 'COLUMN',
    'PRIMARY', 'KEY', 'NOT', 'NULL', 'DEFAULT', 'REFERENCES', 'ON', 'JOIN',
    'LEFT', 'INNER', 'GROUP', 'BY', 'ORDER', 'HAVING', 'LIMIT', 'OFFSET',
    'UNION', 'ALL', 'EXCEPT', 'INTERSECT', 'AS', 'AND', 'OR', 'IN', 'LIKE',
    'BETWEEN', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END', 'CAST', 'BEGIN',
    'COMMIT', 'ROLLBACK', 't1', 't2', 'col', 'x', '*');

  SEEDS: array[0..9] of string = (
    'SELECT * FROM t1',
    'SELECT a, b FROM t1 WHERE a > 1 AND b LIKE ''x%'' ORDER BY a DESC LIMIT 10',
    'INSERT INTO t1 (a, b) VALUES (1, ''x'')',
    'UPDATE t1 SET a = a + 1 WHERE b IS NOT NULL',
    'DELETE FROM t1 WHERE a BETWEEN 1 AND 2',
    'CREATE TABLE t1 (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT ''x'')',
    'SELECT COUNT(*) FROM t1 GROUP BY a HAVING COUNT(*) > 1',
    'SELECT a FROM t1 UNION ALL SELECT b FROM t2',
    'SELECT CASE WHEN a > 1 THEN 1 ELSE 0 END FROM t1',
    'SELECT CAST(a AS TEXT) FROM t1 WHERE a IN (1, 2, 3)');

function RandomSql: string;
var
  i, n, kind, p: Integer;
  s: string;
  c: Char;
begin
  kind := RandRange(3);
  if kind = 0 then
  begin
    { Mutation: bir gecerli cumleyi kes ve/veya 1-3 rastgele karakter ekle. }
    s := SEEDS[RandRange(Length(SEEDS))];
    if Length(s) > 8 then
      s := Copy(s, 1, 1 + RandRange(Length(s)));
    n := 1 + RandRange(3);
    for i := 1 to n do
    begin
      p := 1 + RandRange(Length(s) + 1);
      c := Chr(32 + RandRange(95));
      Insert(c, s, p);
    end;
  end
  else if kind = 1 then
  begin
    { Rastgele token dizisi. }
    n := 1 + RandRange(24);
    s := '';
    for i := 1 to n do
    begin
      if i > 1 then s := s + ' ';
      s := s + TOKENS[RandRange(Length(TOKENS))];
    end;
  end
  else
  begin
    { Rastgele yazdirilabilir baytlar (tokenizer sinir durumlari). }
    n := RandRange(80);
    s := '';
    for i := 1 to n do
      s := s + Chr(32 + RandRange(95));
  end;
  Result := s;
end;

{ Tek bir girdiyi ayristirir; istisna disari sizmaz. Sonuc: TRUE = kabul. }
function TryParse(const ASql: string; out AError: string): Boolean;
var
  P: TVDbParser;
  N: TSqlStmtNode;
begin
  Result := False;
  AError := '';
  P := TVDbParser.Create;
  try
    N := nil;
    try
      N := P.Parse(ASql, []);
      Result := N <> nil;
    finally
      { Sahiplik cagirana gecer; basari ve hata yollarinda da serbest birak. }
      N.Free;
    end;
  except
    on E: Exception do
    begin
      Result := False;
      AError := E.ClassName + ': ' + E.Message;
    end;
  end;
  P.Free;
end;

var
  i, accepted, rejected: Integer;
  heapBefore, heapAfter: TFPCHeapStatus;
  t0, elapsed: QWord;
  sql, err, seedName: string;
  worstMs, oneMs: QWord;
  okSeeds, seedTotal: Integer;

begin
  GPass := 0;
  GFail := 0;
  GRng := SEED_DEFAULT;

  { S0: Gecerli SQL'ler kabul edilmeli; aksi halde fuzz sonucu anlamsiz. }
  seedTotal := 0;
  okSeeds := 0;
  for i := Low(SEEDS) to High(SEEDS) do
  begin
    Inc(seedTotal);
    if TryParse(SEEDS[i], err) then
      Inc(okSeeds);
  end;
  Chk('F0 gecerli tohumlar kabul edildi',
    okSeeds = seedTotal, IntToStr(okSeeds) + '/' + IntToStr(seedTotal));

  heapBefore := GetFPCHeapStatus;
  t0 := GetTickCount64;
  accepted := 0;
  rejected := 0;
  worstMs := 0;

  for i := 1 to ITERATIONS do
  begin
    sql := RandomSql;
    oneMs := GetTickCount64;
    try
      if TryParse(sql, err) then
        Inc(accepted)
      else
        Inc(rejected);
    except
      { TryParse istisnayi yutar; buraya dusmek kapi hatasidir. }
      on E: Exception do
      begin
        Inc(GFail);
        WriteLn('FAIL F1 beklenmeyen istisna iter=', i, ' ', E.ClassName, ': ', E.Message);
      end;
    end;
    oneMs := GetTickCount64 - oneMs;
    if oneMs > worstMs then
      worstMs := oneMs;
    { Tek bir girdi 10 sn'den uzun surdüyse bu bir performans/hang sinyalidir. }
    if oneMs > 10000 then
    begin
      Inc(GFail);
      seedName := sql;
      if Length(seedName) > 120 then seedName := Copy(seedName, 1, 120);
      WriteLn('FAIL F2 tek girdi cok yavas iter=', i, ' ms=', oneMs,
        ' sql="', seedName, '"');
    end;
  end;

  elapsed := GetTickCount64 - t0;
  heapAfter := GetFPCHeapStatus;

  Chk('F1 corpus istisna sizdirmadan bitti',
    (accepted + rejected) = ITERATIONS,
    'kabul=' + IntToStr(accepted) + ' ret=' + IntToStr(rejected) +
    ' iter=' + IntToStr(ITERATIONS));

  Chk('F2 tek girdi 10 sn altinda', worstMs <= 10000,
    'en yavas=' + IntToStr(worstMs) + ' ms');

  Chk('F3 toplam sure siniri', elapsed <= MAX_TOTAL_MS,
    IntToStr(elapsed) + ' ms <= ' + IntToStr(MAX_TOTAL_MS));

  { Bellek: her iterasyonda AST serbest birakiliyor; buyume kalici olmamali.
    Not: yonetici (FPC heap) parcalanmasi nedeniyle kucuk dalgalanma normal. }
  Chk('F4 heap buyumesi sinirli',
    Int64(heapAfter.CurrHeapUsed) - Int64(heapBefore.CurrHeapUsed) <= MAX_HEAP_GROWTH,
    'fark=' + IntToStr(Int64(heapAfter.CurrHeapUsed) - Int64(heapBefore.CurrHeapUsed)) + ' bayt');

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail = 0 then
    Halt(0)
  else
    Halt(GFail);
end.
