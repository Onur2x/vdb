program cachechk;
{ H12 dogrulama + olcum: sinirli blok onbellegi ACIK/KAPALI AYNI sonucu
  vermeli; sicak noktasal okumalarda syscall azalmasiyla hizlanmali.
  Ayrica: yazma (UPDATE/DELETE) ve Compact sonrasi onbellek dogru
  gecersizlesmeli. }
{$mode delphi}
uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 200000;
  M = 300000;
  DIR = 'cachechk_dir';

var
  GFreq: Int64;

function Tick: Int64; var c: Int64; begin QueryPerformanceCounter(c); Result := c; end;
function Ms(t0, t1: Int64): Double; begin Result := (t1 - t0) * 1000 / GFreq; end;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  i, k, id: Integer;
  seed: Integer;
  t0, t1: Int64;
  R: TSqlResult;
  Hits, Misses: Int64; Used, MaxB: Integer;
  chkOff, chkOn: Int64;
  msOff, msOn: Double;
  ob, nb: Int64;
  RndMax: Integer;

procedure WipeDir(const D: string);
begin
  SysUtils.DeleteFile(D + '\veritabani.odb');
  SysUtils.DeleteFile(D + '\veritabani.odb.bak');
  SysUtils.DeleteFile(D + '\veritabani.odb.tmp');
  SysUtils.DeleteFile(D + '\veritabani.schema');
  SysUtils.DeleteFile(D + '\veritabani.wal');
  SysUtils.DeleteFile(D + '\vdb.log');
  RemoveDir(D);
end;

function Rnd: Integer;
begin
  seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
  Result := (seed mod RndMax) + 1;
end;

function RunLookups(out chk: Int64; out elapsedMs: Double): Boolean;
var j: Integer; rr: TSqlResult;
begin
  chk := 0; seed := 987654321;
  t0 := Tick;
  for j := 1 to M do
  begin
    id := Rnd;
    rr := sq.Exec('SELECT a, b FROM t WHERE id = ' + IntToStr(id));
    if Length(rr.Rows) = 1 then
      chk := chk + StrToInt64Def(rr.Rows[0][0], -1) + Length(rr.Rows[0][1])
    else
      chk := chk + 1000000;   // beklenmeyen: satir yok
  end;
  t1 := Tick;
  elapsedMs := Ms(t0, t1);
  Result := True;
end;

procedure EncTest;
const
  EN = 50000;
  EM = 60000;
  EDIR = 'cachechk_enc_dir';
var
  kv2: TVDb; tb2: TVTableDb; sq2: TVSql;
  key: TBytes;
  j, seed2, id2: Integer;
  rr: TSqlResult;
  c1, c2: Int64;
  hits2, miss2: Int64; u2, m2: Integer;

  function R2: Integer;
  begin
    seed2 := (seed2 * 1103515245 + 12345) and $7FFFFFFF;
    Result := (seed2 mod EN) + 1;
  end;

  procedure Run2(out chk: Int64);
  var q: Integer;
  begin
    chk := 0; seed2 := 24680;
    for q := 1 to EM do
    begin
      id2 := R2;
      rr := sq2.Exec('SELECT a, b FROM t WHERE id = ' + IntToStr(id2));
      if Length(rr.Rows) = 1 then
        chk := chk + StrToInt64Def(rr.Rows[0][0], -1) + Length(rr.Rows[0][1])
      else
        chk := chk + 1000000;
    end;
  end;

begin
  WipeDir(EDIR);
  ForceDirectories(EDIR);
  SetLength(key, 32);
  for j := 0 to 31 do key[j] := Byte((j * 37 + 5) mod 251);
  kv2 := TVDb.Create; tb2 := TVTableDb.Create(kv2); sq2 := TVSql.Create(tb2);
  try
    kv2.Open(EDIR); tb2.Open(EDIR);
    tb2.Kv.SetEncryptionKey(key);
    sq2.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
    sq2.Exec('BEGIN');
    for j := 1 to EN do
      sq2.Exec(Format('INSERT INTO t VALUES (%d, %d, ''s%d'')',
        [j, j mod 1000, j mod 89]));
    sq2.Exec('COMMIT');

    tb2.Kv.SetReadCacheBlocks(0);
    Run2(c1);
    tb2.Kv.SetReadCacheBlocks(4096);
    Run2(c2);   // isinma
    Run2(c2);
    tb2.Kv.GetReadCacheStats(hits2, miss2, u2, m2);
    Writeln(Format('SIFRELI diferansiyel: kapali=%d acik=%d -> %s (hits=%d misses=%d)',
      [c1, c2, BoolToStr(c1 = c2, True), hits2, miss2]));
    rr := sq2.Exec('SELECT a,b FROM t WHERE id = 7');
    if Length(rr.Rows) = 1 then
      Writeln('SIFRELI id=7 cozuldu: a=', rr.Rows[0][0], ' b=', rr.Rows[0][1])
    else
      Writeln('SIFRELI id=7: HATA');
  finally
    sq2.Free; tb2.Free; kv2.Free;
  end;
end;

begin
  try
    QueryPerformanceFrequency(GFreq);
    if DirectoryExists(DIR) then WipeDir(DIR);
    ForceDirectories(DIR);
    kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
    try
      kv.Open(DIR); tb.Open(DIR);
      kv.SetReadCacheBlocks(0);   // yukleme sirasinda kapali
      sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
      sq.Exec('BEGIN');
      for i := 1 to N do
        sq.Exec(Format('INSERT INTO t VALUES (%d, %d, ''v%d'')',
          [i, i mod 1000, i mod 97]));
      sq.Exec('COMMIT');
      Writeln(Format('Yuklendi: %d satir', [N]));

      RndMax := N;
      // ---- ONBELLEK KAPALI ----
      kv.SetReadCacheBlocks(0);
      RunLookups(chkOff, msOff);
      Writeln(Format('ONBELLEK KAPALI : %.0f ms (%.3f us/okuma)',
        [msOff, msOff * 1000 / M]));

      // ---- ONBELLEK ACIK (dosya sigar: 4096 blok x 8 KB = 32 MB) ----
      kv.SetReadCacheBlocks(4096);
      RunLookups(chkOn, msOn);   // isinma
      RunLookups(chkOn, msOn);   // olcum
      kv.GetReadCacheStats(Hits, Misses, Used, MaxB);
      Writeln(Format('ONBELLEK ACIK   : %.0f ms (%.3f us/okuma) hits=%d misses=%d blok=%d/%d',
        [msOn, msOn * 1000 / M, Hits, Misses, Used, MaxB]));

      Writeln(Format('Diferansiyel: %d vs %d -> %s',
        [chkOff, chkOn, BoolToStr(chkOff = chkOn, True)]));

      // ---- Varsayilan boyut (1024 blok x 8 KB = 8 MB) ----
      kv.SetReadCacheBlocks(1024);
      RunLookups(chkOn, msOn);   // isinma
      RunLookups(chkOn, msOn);
      kv.GetReadCacheStats(Hits, Misses, Used, MaxB);
      Writeln(Format('ONBELLEK 1024(vars.): %.0f ms (%.3f us/okuma) hits=%d misses=%d blok=%d/%d',
        [msOn, msOn * 1000 / M, Hits, Misses, Used, MaxB]));

      // ---- SICAK CALISMA KUMESI (varsayilan 8 MB ile): ilk 10000 id ----
      kv.SetReadCacheBlocks(1024);
      RndMax := 10000;
      RunLookups(chkOn, msOn);   // isinma
      RunLookups(chkOn, msOn);
      kv.GetReadCacheStats(Hits, Misses, Used, MaxB);
      Writeln(Format('ONBELLEK 1024 + SICAK(10k): %.0f ms (%.3f us/okuma) hits=%d misses=%d blok=%d/%d',
        [msOn, msOn * 1000 / M, Hits, Misses, Used, MaxB]));
      RndMax := N;

      // ---- Kucuk onbellek (bellek tavani sinirli; tahliye yolu) ----
      kv.SetReadCacheBlocks(16);
      RunLookups(chkOn, msOn);   // isinma + tahliye
      RunLookups(chkOn, msOn);
      kv.GetReadCacheStats(Hits, Misses, Used, MaxB);
      Writeln(Format('ONBELLEK 16 BLOK: %.0f ms (%.3f us/okuma) hits=%d misses=%d blok=%d/%d',
        [msOn, msOn * 1000 / M, Hits, Misses, Used, MaxB]));
      Writeln(Format('Diferansiyel(kucuk): %d vs %d -> %s',
        [chkOff, chkOn, BoolToStr(chkOff = chkOn, True)]));

      // ---- Yazma sonrasi dogruluk (onbellek ACIK) ----
      kv.SetReadCacheBlocks(4096);
      sq.Exec('UPDATE t SET b = ''Z'' WHERE id = 42');
      sq.Exec('DELETE FROM t WHERE id = 77');
      R := sq.Exec('SELECT a,b FROM t WHERE id = 42');
      if Length(R.Rows) = 1 then
        Writeln('UPDATE sonrasi id=42: satir=1 b=', R.Rows[0][1])
      else
        Writeln('UPDATE sonrasi id=42: HATA satir=', Length(R.Rows));
      R := sq.Exec('SELECT id FROM t WHERE id = 77');
      Writeln('DELETE sonrasi id=77: satir=', Length(R.Rows));

      // ---- Compact sonrasi dogruluk ----
      ob := 0; nb := 0;
      kv.Compact(ob, nb);
      R := sq.Exec('SELECT a,b FROM t WHERE id = 42');
      if Length(R.Rows) = 1 then
        Writeln('Compact sonrasi id=42: satir=1 b=', R.Rows[0][1])
      else
        Writeln('Compact sonrasi id=42: HATA satir=', Length(R.Rows));
      R := sq.Exec('SELECT a,b FROM t WHERE id = 123');
      if Length(R.Rows) = 1 then
        Writeln('Compact sonrasi id=123: a=', R.Rows[0][0])
      else
        Writeln('Compact sonrasi id=123: HATA satir=', Length(R.Rows));

      EncTest;

    finally
      sq.Free; tb.Free; kv.Free;
    end;
  except on E: Exception do Writeln('HATA: ', E.Message); end;
end.
