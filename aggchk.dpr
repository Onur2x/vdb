program aggchk;
{ H6 (2026-10-18) dogrulama/olcum:
  (1) Paralel agrega sonucu, genel yolun (WHERE 1=1 -> TryStreamAgg kapali)
      sonucuyla BIREBIR ayni mi?
  (2) Isci sayisi 1/2/4/8 icin COUNT/SUM/AVG/MIN/MAX olcumu.
  (3) SUM/AVG VCT_FLOAT: paralel yol kapali olmali (bit-ayni sonuc).

  Paralel yolun gercekten kostugunu VdbParallelStats.TasksSubmitted
  deltasindan dogrulariz (w=1 seri, w>=2 paralel). }
{$mode delphi}
uses
  SysUtils, VDbCore, VDbTable, VDbSql, VDbParallel, Windows;

const
  N = 150000;
  REPS = 5;
  DIR = 'aggchk_dir';

var
  GFreq: Int64;

function Tick: Int64; var c: Int64; begin QueryPerformanceCounter(c); Result := c; end;
function MsOf(t0, t1: Int64): Double; begin Result := (t1 - t0) * 1000 / GFreq; end;

function RowText(const R: TSqlResult): string;
var j: Integer;
begin
  Result := '';
  if (Length(R.Rows) <> 1) then Exit('<satir=' + IntToStr(Length(R.Rows)) + '>');
  for j := 0 to High(R.Rows[0]) do
  begin
    if j > 0 then Result := Result + ' | ';
    Result := Result + R.Rows[0][j];
  end;
end;

procedure NoopTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
begin
end;

function CountCb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
begin
  Inc(PInt64(User)^);
  Result := True;
end;

type
  TScanCtx = record
    Kv: TVDb;
    P: TVDbRawPrepared;
    CLo, CHi: array of Integer;
    Cnt: array of Int64;
  end;

procedure ScanTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
var
  c: ^TScanCtx;
  i: Integer;
  n: Int64;
begin
  c := ACtx;
  for i := ALo to AHi do
  begin
    n := 0;
    c.Kv.ScanRawPrepared(c.P, c.CLo[i], c.CHi[i], CountCb, @n);
    c.Cnt[i] := n;
  end;
end;

procedure CpuTask(ACtx: Pointer; AChunkIx, ALo, AHi: Integer);
var
  i, k: Integer;
  x: Int64;
begin
  x := 0;
  for i := ALo to AHi do
    for k := 1 to 400000 do Inc(x, k);
  if x = -1 then Writeln('imkansiz');
end;

var
  kv: TVDb; tb: TVTableDb; sq: TVSql;
  i, w, rep: Integer; t0, t1: Int64;
  Q, QRef, QF, QFRef: string;
  R, RRef, RF, RFRef: TSqlResult;
  st0, st1: TVdbParallelStats;
  ms: Double; tasks: Int64; okAll: Boolean;
  gp: TVDbRawPrepared;
  sc: TScanCtx;
  pmask, smask: DWORD;

  function RunOnce(const Qry: string; out Tasks: Int64): Double;
  var r0, r1: Int64; s0, s1: TVdbParallelStats; k: Integer;
  begin
    R := sq.Exec(Qry);              // isinma
    s0 := VdbParallelStats;
    r0 := Tick;
    for k := 1 to REPS do R := sq.Exec(Qry);
    r1 := Tick;
    s1 := VdbParallelStats;
    Tasks := s1.TasksSubmitted - s0.TasksSubmitted;
    Result := MsOf(r0, r1) / REPS;
  end;

begin
  okAll := True;
  try
    QueryPerformanceFrequency(GFreq);
    if DirectoryExists(DIR) then
    begin
      SysUtils.DeleteFile(DIR + '\veritabani.odb');
      SysUtils.DeleteFile(DIR + '\veritabani.schema');
      RemoveDir(DIR);
    end;
    ForceDirectories(DIR);
    kv := TVDb.Create; tb := TVTableDb.Create(kv); sq := TVSql.Create(tb);
    try
      kv.Open(DIR); tb.Open(DIR);
      sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, f FLOAT)');
      sq.Exec('BEGIN');
      for i := 1 to N do
        sq.Exec('INSERT INTO t VALUES (' + IntToStr(i) + ', ' +
          IntToStr((i * 37) mod 100000) + ', ' + IntToStr(i) + '.5)');
      sq.Exec('COMMIT');

      Q     := 'SELECT COUNT(*), COUNT(v), SUM(v), AVG(v), MIN(v), MAX(v) FROM t';
      QRef  := 'SELECT COUNT(*), COUNT(v), SUM(v), AVG(v), MIN(v), MAX(v) FROM t WHERE 1=1';
      QF    := 'SELECT SUM(f), AVG(f), MIN(f), MAX(f) FROM t';
      QFRef := 'SELECT SUM(f), AVG(f), MIN(f), MAX(f) FROM t WHERE 1=1';

      RRef := sq.Exec(QRef);
      RFRef := sq.Exec(QFRef);
      Writeln('REF (genel yol): ', RowText(RRef));
      Writeln('REF (float):     ', RowText(RFRef));
      Writeln;

      for w in [1, 2, 4, 8] do
      begin
        ShutdownThreadPool;
        if not InitThreadPool(w) then
        begin
          Writeln('w=', w, ': havuz acilamadi'); Continue;
        end;
        ms := RunOnce(Q, tasks);
        R := sq.Exec(Q);
        Writeln(Format('w=%d  %8.2f ms/sorgu  gorev+=%d  sonuc=%s', [w, ms, tasks, RowText(R)]));
        if tasks > 0 then Writeln('     (paralel yol KULLANILDI)')
        else Writeln('     (seri yol)');
        if RowText(R) <> RowText(RRef) then
        begin
          okAll := False;
          Writeln('     !! SONUC REFERANSTAN FARKLI');
        end;
      end;

      Writeln;
      // Float: isci 8 olsa da SUM/AVG paralel KAPALI olmali (gorev+=0)
      ms := RunOnce(QF, tasks);
      RF := sq.Exec(QF);
      Writeln(Format('float w=8  %8.2f ms/sorgu  gorev+=%d', [ms, tasks]));
      if tasks > 0 then
      begin
        okAll := False;
        Writeln('     !! float SUM/AVG paralel kosuldu (beklenmiyordu)');
      end;
      Writeln('     float sonuc: ', RowText(RF));
      if RowText(RF) <> RowText(RFRef) then
      begin
        okAll := False;
        Writeln('     !! float sonuc referanstan farkli');
      end;

      // Rastgele varyasyon: filtreli olmayan, karisik planli agrega
      st0 := VdbParallelStats;
      R := sq.Exec('SELECT COUNT(v), MIN(v), MAX(v), SUM(v) FROM t');
      st1 := VdbParallelStats;
      Writeln;
      Writeln('karisik (w=8): ', RowText(R),
        '  gorev+=', st1.TasksSubmitted - st0.TasksSubmitted);

      Writeln;
      // PrepareRawScan maliyeti (paralel yolun tek-iscili on hazirligi)
      t0 := Tick;
      for rep := 1 to 10 do kv.PrepareRawScan(-1, gp);
      t1 := Tick;
      Writeln(Format('PrepareRawScan(-1) x10: %.2f ms/tur (aday=%d)',
        [MsOf(t0, t1) / 10, Length(gp.CandOff)]));

      // havuz maliyeti (is yok)
      Writeln('Havuz isci=', VdbParallelStats.Workers,
        '  Default=', DefaultParallelWorkers,
        '  Ready=', ThreadPoolReady);
      if GetProcessAffinityMask(GetCurrentProcess, pmask, smask) then
        Writeln('Islem affinity mask=', IntToHex(pmask, 16),
          '  sistem=', IntToHex(smask, 16));
      t0 := Tick;
      for rep := 1 to 200 do VdbParallelForChunked(0, 7, 8, NoopTask, @gp);
      t1 := Tick;
      Writeln(Format('noop 8 gorev x200: %.3f ms/cagri', [MsOf(t0, t1) / 200]));

      // prepared tarama: seri vs paralel (yalniz tarama, agg yok)
      SetLength(sc.CLo, 8); SetLength(sc.CHi, 8); SetLength(sc.Cnt, 8);
      sc.Kv := kv;
      sc.P := gp;
      for rep := 0 to 7 do
      begin
        sc.CLo[rep] := Integer((Int64(Length(gp.CandOff)) * rep) div 8);
        sc.CHi[rep] := Integer((Int64(Length(gp.CandOff)) * (rep + 1)) div 8);
      end;
      t0 := Tick;
      for rep := 1 to 10 do
      begin
        tasks := 0;
        kv.ScanRawPrepared(gp, 0, Length(gp.CandOff), CountCb, @tasks);
      end;
      t1 := Tick;
      Writeln(Format('tarama SERI x10: %.2f ms/tur (n=%d)', [MsOf(t0, t1) / 10, tasks]));
      t0 := Tick;
      for rep := 1 to 10 do VdbParallelForChunked(0, 7, 8, ScanTask, @sc);
      t1 := Tick;
      Writeln(Format('tarama PARALEL(8) x10: %.2f ms/tur', [MsOf(t0, t1) / 10]));

      t0 := Tick;
      VdbParallelForChunked(0, 7, 1, CpuTask, nil);
      t1 := Tick;
      Writeln(Format('CPU seri (8x400k): %.2f ms', [MsOf(t0, t1)]));
      t0 := Tick;
      VdbParallelForChunked(0, 7, 8, CpuTask, nil);
      t1 := Tick;
      Writeln(Format('CPU paralel(8)   : %.2f ms', [MsOf(t0, t1)]));

      Writeln;
      if okAll then Writeln('SONUC: GECTI (paralel = referans)')
      else Writeln('SONUC: BASARISIZ');
    finally
      ShutdownThreadPool;
      sq.Free; tb.Free; kv.Free;
    end;
  except
    on E: Exception do Writeln('HATA: ', E.ClassName, ': ', E.Message);
  end;
end.
