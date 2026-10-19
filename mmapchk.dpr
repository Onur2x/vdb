program mmapchk;
{ H4 (mmap okuma yolu) dogrulama: ScanRawIter ACIK/KAPALI AYNI sonucu vermeli
  (kayit sayisi + deger uzunlugu + icerik saglamasi). Ayrica yazma/Compact
  sonrasi ve sifreli dosyada birebir olmali. Esleme gercekten aciliyor mu
  (ReadMapOpens) diye de sayilir. }
{$mode delphi}
uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql, Windows;

const
  N = 120000;                 // satir (dosya > 1 MB -> esleme devreye girer)
  DIR = 'mmapchk_dir';
  EN = 120000;
  EDIR = 'mmapchk_enc_dir';

var
  GFreq: Int64;
  GKv: TVDb;
  GChk, GRows, GLen: Int64;

function Tick: Int64; var c: Int64; begin QueryPerformanceCounter(c); Result := c; end;
function ElapsedMs(t0, t1: Int64): Double; begin Result := (t1 - t0) * 1000 / GFreq; end;

function Cb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
var i: Integer;
begin
  Inc(GRows);
  GChk := GChk + Int64(Key);
  GLen := GLen + Len;
  if Len > 0 then
    for i := 0 to Len - 1 do
      GChk := GChk + Int64(Buf[i]) * (i + 1);
  Result := True;
end;

// Salt zamanlama icin hafif geri cagri (bayt-bayt toplama yok).
function CbCheap(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
begin
  Inc(GRows);
  GChk := GChk + Int64(Key) + Int64(Len);
  if Len > 0 then GChk := GChk + Int64(Buf[0]) + Int64(Buf[Len - 1]);
  Result := True;
end;

procedure Scan(AKv: TVDb; AFn: TVDbRawCb; out chk, rows, len: Int64; out ms: Double);
var t0, t1: Int64;
begin
  GKv := AKv;
  GChk := 0; GRows := 0; GLen := 0;
  t0 := Tick;
  GKv.ScanRawIter(High(QWord), -1, AFn, nil);
  t1 := Tick;
  chk := GChk; rows := GRows; len := GLen; ms := ElapsedMs(t0, t1);
end;

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

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  i: Integer;
  c1, c2, c3, r1, r2, r3, l1, l2, l3, ob, nb: Int64;
  m1, m2, m3: Double;
  o1, o2: Int64;
  R: TSqlResult;

procedure EncTest;
var
  kv2: TVDb; tb2: TVTableDb; sq2: TVSql;
  key: TBytes; j: Integer;
  e1, e2, er1, er2, el1, el2, eo1, eo2: Int64; em: Double;
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
      sq2.Exec(Format('INSERT INTO t VALUES (%d, %d, ''s%d'')', [j, j mod 1000, j mod 89]));
    sq2.Exec('COMMIT');

    kv2.SetReadMapEnabled(False); Scan(kv2, Cb, e1, er1, el1, em);
    eo1 := kv2.ReadMapOpens;
    kv2.SetReadMapEnabled(True);  Scan(kv2, Cb, e2, er2, el2, em);   // isinma
    Scan(kv2, Cb, e2, er2, el2, em);
    eo2 := kv2.ReadMapOpens;
    Writeln(Format('SIFRELI diferansiyel: kapali=%d acik=%d -> %s (satir %d/%d len %d/%d esleme=%d)',
      [e1, e2, BoolToStr((e1 = e2) and (er1 = er2) and (el1 = el2), True),
       er1, er2, el1, el2, eo2 - eo1]));

    // id ile cozme dogru mu (noktasal)
    R := sq2.Exec('SELECT a,b FROM t WHERE id = 7');
    if Length(R.Rows) = 1 then
      Writeln('SIFRELI id=7 cozuldu: a=', R.Rows[0][0], ' b=', R.Rows[0][1])
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
      sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
      sq.Exec('BEGIN');
      for i := 1 to N do
        sq.Exec(Format('INSERT INTO t VALUES (%d, %d, ''v%d'')', [i, i mod 1000, i mod 97]));
      sq.Exec('COMMIT');
      Writeln(Format('Yuklendi: %d satir', [N]));

      // ---- esleme KAPALI ----
      kv.SetReadMapEnabled(False);
      Scan(kv, Cb, c1, r1, l1, m1);            // dogruluk
      Scan(kv, CbCheap, c2, r2, l2, m2);       // zaman (isinma)
      Scan(kv, CbCheap, c2, r2, l2, m2);       // zaman
      Writeln(Format('MAP KAPALI : satir=%d len=%d chk=%d (zaman %.1f ms)', [r1, l1, c1, m2]));

      // ---- esleme ACIK ----
      o1 := kv.ReadMapOpens;
      kv.SetReadMapEnabled(True);
      Scan(kv, Cb, c3, r3, l3, m3);            // dogruluk
      Scan(kv, CbCheap, c2, r2, l2, m2);       // zaman (isinma)
      Scan(kv, CbCheap, c2, r2, l2, m2);       // zaman
      o2 := kv.ReadMapOpens;
      Writeln(Format('MAP ACIK   : satir=%d len=%d chk=%d (zaman %.1f ms) esleme=%d',
        [r3, l3, c3, m2, o2 - o1]));
      Writeln(Format('Diferansiyel: %s',
        [BoolToStr((c1 = c3) and (l1 = l3) and (r1 = r3), True)]));

      // ---- yazma sonrasi ----
      sq.Exec('UPDATE t SET b = ''ZZ'' WHERE id = 100');
      sq.Exec('DELETE FROM t WHERE id = 200');
      kv.SetReadMapEnabled(False); Scan(kv, Cb, c1, r1, l1, m1);
      kv.SetReadMapEnabled(True);  Scan(kv, Cb, c3, r3, l3, m3);
      Writeln(Format('Yazma sonrasi diferansiyel: %s',
        [BoolToStr((c1 = c3) and (l1 = l3) and (r1 = r3), True)]));

      // ---- Compact sonrasi ----
      ob := 0; nb := 0;
      kv.Compact(ob, nb);
      kv.SetReadMapEnabled(False); Scan(kv, Cb, c1, r1, l1, m1);
      kv.SetReadMapEnabled(True);  Scan(kv, Cb, c3, r3, l3, m3);
      Writeln(Format('Compact sonrasi diferansiyel: %s',
        [BoolToStr((c1 = c3) and (l1 = l3) and (r1 = r3), True)]));
      R := sq.Exec('SELECT a,b FROM t WHERE id = 100');
      if Length(R.Rows) = 1 then
        Writeln('Compact id=100 b=', R.Rows[0][1])
      else Writeln('Compact id=100 HATA');

      // ---- sifreli ----
      EncTest;

    finally
      sq.Free; tb.Free; kv.Free;
    end;
  except on E: Exception do Writeln('HATA: ', E.Message); end;
end.
