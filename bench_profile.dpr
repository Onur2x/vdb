program bench_profile;
{$mode delphi}
uses
  SysUtils, Classes, Math, Windows, VDbCore, VDbTable, VDbSql, VDbTypes;

const
  N = 1000000;
  DBDIR = 'bench_profile_dir';

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

procedure FillTable(DB: TVDb; Table: TVTableDb; Sql: TVSql);
var
  i: Integer;
begin
  Sql.Exec('CREATE TABLE bench (id INTEGER PRIMARY KEY, name TEXT, val INTEGER)');
  Sql.Exec('BEGIN');
  for i := 1 to N do
    Sql.Exec('INSERT INTO bench VALUES (' + IntToStr(i) + ', ''row' + IntToStr(i) + ''', ' + IntToStr(i * 2) + ')');
  Sql.Exec('COMMIT');
  Writeln('Tablo dolduruldu: ', N, ' satir');
end;

procedure TestIORaw(const FPath: string);
var
  f: TFileStream;
  buf: array[0..$200000-1] of Byte;
  t0, t1: Int64;
  totalSize, bytesRead: Int64;
  toRead: Integer;
begin
  if not FileExists(FPath) then
  begin
    Writeln('Dosya bulunamadi: ', FPath);
    Exit;
  end;
  f := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone);
  try
    totalSize := f.Size;
    t0 := NowTick;
    bytesRead := 0;
    while bytesRead < totalSize do
    begin
      toRead := Min(2*1024*1024, totalSize - bytesRead);
      f.ReadBuffer(buf[0], toRead);
      bytesRead := bytesRead + toRead;
    end;
    t1 := NowTick;
    Writeln(Format('[RAW I/O] %d MB, 2MB buffer x %d = %.0f ms', [totalSize div (1024*1024), (bytesRead + 2*1024*1024 - 1) div (2*1024*1024), Sec(t0,t1)*1000]));
  finally
    f.Free;
  end;
end;

procedure TestSUM(Sql: TVSql; iterations: Integer);
var
  i: Integer;
  R: TSqlResult;
  tA, tB: Int64;
  s1, s2: Int64;
  ti, tv: Double;
begin
  { ERKEN-DURMA teshisi (sicak + ic ice, cold-penalty esitlenmis):
    SUM(id) -> MaxCol=0 (erkenden durmali); SUM(val) -> MaxCol=2 (tam
    yuruyus). Erken-durma calisiyorsa SUM(id) tutarli bicimde HIZLI olmali. }
  Sql.Exec('SELECT SUM(id) FROM bench');    // warmup (elenir)
  Sql.Exec('SELECT SUM(val) FROM bench');
  ti := 0; tv := 0;
  for i := 1 to iterations do
  begin
    tA := NowTick; R := Sql.Exec('SELECT SUM(id) FROM bench');  tB := NowTick;
    if Length(R.Rows) > 0 then s1 := StrToInt64(R.Rows[0,0]) else s1 := 0;
    ti := ti + Sec(tA, tB) * 1000;
    tA := NowTick; R := Sql.Exec('SELECT SUM(val) FROM bench'); tB := NowTick;
    if Length(R.Rows) > 0 then s2 := StrToInt64(R.Rows[0,0]) else s2 := 0;
    tv := tv + Sec(tA, tB) * 1000;
  end;
  Writeln(Format('[SUM(id) col0 x%d] ort %.1f ms (deger=%d)', [iterations, ti/iterations, s1]));
  Writeln(Format('[SUM(val) col2 x%d] ort %.1f ms (deger=%d)', [iterations, tv/iterations, s2]));
end;

procedure TestCOUNT(Sql: TVSql; iterations: Integer);
var
  i: Integer;
  R: TSqlResult;
  t0, tA, t1, tB: Int64;
  cnt: Int64;
  first, mn, d: Double;
begin
  cnt := -1;
  first := 0; mn := 1e18;
  t0 := NowTick;
  for i := 1 to iterations do
  begin
    tA := NowTick;
    R := Sql.Exec('SELECT COUNT(*) FROM bench');
    tB := NowTick;
    if Length(R.Rows) > 0 then
      cnt := StrToInt64(R.Rows[0,0])
    else
      cnt := 0;
    d := Sec(tA, tB) * 1000;
    if i = 1 then first := d
    else if d < mn then mn := d;
  end;
  t1 := NowTick;
  Writeln(Format('[COUNT %dx] deger=%d | ilk(dogrulamali tarama)=%.1f ms | sonraki(COUNT O(1) cache) min=%.2f ms | toplam=%.0f ms',
    [iterations, cnt, first, mn, Sec(t0, t1) * 1000]));
end;

{ --- KR-8 alt-profil: tarama makinesi (bos-cb) vs peek maliyeti ayrimi --- }
var
  GType: array of Byte;
  GOff, GLen: array of Integer;
  GSeed: QWord;

function EmptyCb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
begin
  Result := True;   // PAS A+B+C makinesi; cb isleri YOK
end;

function PeekOnlyCb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
var
  tid: Word;
  kh: QWord;
begin
  if Key = VDB_SCHEMA_KEY then Exit(True);
  // Yalniz peek (baslik + kolon dizini + pk hash); agreg aritmetigi YOK.
  Result := VDbPeekRawRowKeyHash(Buf, Len, 3, tid, GSeed, kh, GType, GOff, GLen);
end;

{ GEVSETME-TAVANI olcumleri (motor koduna DOKUNMAZ; tavan tespiti): }
function PeekNoHashCb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
// Tam kolon yuruyusu ama FNV carpisma-hash'i YOK -> FNV maliyetini ayirir.
var p: Integer; pkL, cc, i: Word; vl: LongInt; tid: Word;
begin
  if Key = VDB_SCHEMA_KEY then Exit(True);
  Result := False;
  if Buf = nil then Exit;
  p := 0;
  if p + 2 > Len then Exit; tid := Buf[p] or (Word(Buf[p+1]) shl 8); Inc(p,2);
  if p + 2 > Len then Exit; pkL := Buf[p] or (Word(Buf[p+1]) shl 8); Inc(p,2);
  if p + pkL > Len then Exit; Inc(p, pkL);
  if p + 2 > Len then Exit; cc := Buf[p] or (Word(Buf[p+1]) shl 8); Inc(p,2);
  if Integer(cc) <> 3 then Exit;
  for i := 0 to cc - 1 do
  begin
    if p >= Len then Exit;
    GType[i] := Buf[p]; Inc(p);
    if p + 4 > Len then Exit; Move(Buf[p], vl, 4); Inc(p,4);
    if vl = -1 then Continue;
    if (vl < 0) or (p + vl > Len) then Exit;
    Inc(p, vl);
  end;
  Result := True;   // FNV YOK
end;

function PeekStop0Cb(Key: QWord; Buf: PByte; Len: Integer; User: Pointer): Boolean;
// FNV KALIR, ama yalniz col0 cozulur (SUM(id)); 1,2 dogrulanmaz -> kuyruk-kolon
// yuruyus maliyetini ayirir (bu, COUNT'takiyle ayni kategoride bozuk-satir
// gevsemesinin tavanidir).
var p: Integer; pkL, cc: Word; vl: LongInt; tid: Word; pkPtr: PByte; kh: QWord;
begin
  if Key = VDB_SCHEMA_KEY then Exit(True);
  Result := False;
  if Buf = nil then Exit;
  p := 0;
  if p + 2 > Len then Exit; tid := Buf[p] or (Word(Buf[p+1]) shl 8); Inc(p,2);
  if p + 2 > Len then Exit; pkL := Buf[p] or (Word(Buf[p+1]) shl 8); Inc(p,2);
  if p + pkL > Len then Exit; pkPtr := Buf + p; Inc(p, pkL);
  if p + 2 > Len then Exit; cc := Buf[p] or (Word(Buf[p+1]) shl 8); Inc(p,2);
  if Integer(cc) <> 3 then Exit;
  if p >= Len then Exit;
  GType[0] := Buf[p]; Inc(p);
  if p + 4 > Len then Exit; Move(Buf[p], vl, 4); Inc(p,4);
  if vl <> -1 then
  begin
    if (vl < 0) or (p + vl > Len) then Exit;
    Inc(p, vl);
  end;
  kh := VDbHashKeyBytes(GSeed, pkPtr, pkL);
  Result := True;
end;

procedure TestScanFloor(DB: TVDb);
var
  t0, t1: Int64;
begin
  SetLength(GType, 3); SetLength(GOff, 3); SetLength(GLen, 3);
  GSeed := VDbHashKeyPrefix('bench');
  // TableFilter<0: FIndex'in TAMAMI (FTableKeys yok); Ayni ~1M aday.
  t0 := NowTick;
  DB.ScanRawIterAll(-1, EmptyCb, nil);
  t1 := NowTick;
  Writeln(Format('[FLOOR bos-cb  (PAS A+B+C makinesi)] = %.1f ms', [Sec(t0,t1)*1000]));
  t0 := NowTick;
  DB.ScanRawIterAll(-1, PeekOnlyCb, nil);
  t1 := NowTick;
  Writeln(Format('[PEEK bos-cb+peek (KR-8 yolu)      ] = %.1f ms', [Sec(t0,t1)*1000]));
  t0 := NowTick;
  DB.ScanRawIterAll(-1, PeekNoHashCb, nil);
  t1 := NowTick;
  Writeln(Format('[PEEK tam-yuruyus FNV-YOK          ] = %.1f ms  (FNV maliyeti ~ PEEK - bu)', [Sec(t0,t1)*1000]));
  t0 := NowTick;
  DB.ScanRawIterAll(-1, PeekStop0Cb, nil);
  t1 := NowTick;
  Writeln(Format('[PEEK erken-dur col0 +FNV          ] = %.1f ms  (kuyruk-kolon ~ PEEK - bu)', [Sec(t0,t1)*1000]));
end;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  reuse: Boolean;
begin
  try
    Writeln('=== BENCH: IO vs SUM profiling ===');
    QueryPerformanceFrequency(GFreq);

    reuse := FileExists(DBDIR + '\veritabani.odb');
    if reuse then
      Writeln('(mevcut DB kullaniliyor - tablo yeniden doldurulmuyor)')
    else
    begin
      if DirectoryExists(DBDIR) then
        RemoveDir(DBDIR);
      ForceDirectories(DBDIR);
    end;

    kv := TVDb.Create;
    tb := TVTableDb.Create(kv);
    sq := TVSql.Create(tb);
    try
      kv.Open(DBDIR);
      tb.Open(DBDIR);
      if not reuse then
        FillTable(kv, tb, sq);
      TestCOUNT(sq, 10);
      TestSUM(sq, 7);
      TestScanFloor(kv);
    finally
      sq.Free;
      tb.Free;
      kv.Free;
    end;
    TestIORaw(DBDIR + '\veritabani.odb');
  except
    on E: Exception do
      Writeln('HATA: ', E.Message);
  end;
end.
