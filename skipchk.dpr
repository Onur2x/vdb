{ H3 skiplist prototipi dogrulama + olcum.

  - Rastgele 200.000 girdi (mukerrer anahtarlar dahil) sirali bir
    TStringList oracle'ina karsi eklenir.
  - All / LowerBound / Find / Range / Delete sonuclari oracle ile
    karsilastirilir.
  - 1.000.000 girdilik yeni listede ekleme, arama, aralik ve silme
    sureleri olculur (kabul testi olcegi). }
{$mode delphi}{$H+}
program skipchk;

uses
  SysUtils, Classes, Windows, VDbSkipList;

const
  N = 200000;
  N_FIND = 20000;
  N_LB = 20000;
  N_RANGE = 5000;
  N_DEL = 50000;
  BENCH_N = 1000000;

var
  fails: Integer;
  GFreq: Int64;

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

procedure Check(const Cond: Boolean; const Label_: string);
begin
  if not Cond then
  begin
    Inc(fails);
    Writeln('  HATA: ', Label_);
  end;
end;

function K(I: Integer): string;
begin
  Result := Format('K%.8d', [I]);
end;

function V(I: Integer): string;
begin
  Result := Format('V%.8d', [I]);
end;

function LineOf(const Key, Value: string): string;
begin
  Result := Key + #1 + Value;
end;

function OracleLBIndex(SL: TStringList; const Key: string): Integer;
var
  lo, hi, mid: Integer;
  s: string;
begin
  lo := 0;
  hi := SL.Count;
  while lo < hi do
  begin
    mid := (lo + hi) div 2;
    s := SL[mid];
    if Copy(s, 1, Length(Key)) < Key then
      lo := mid + 1
    else
      hi := mid;
  end;
  Result := lo;
end;

function OracleLB(SL: TStringList; const Key: string; out Line: string): Boolean;
var
  i: Integer;
begin
  i := OracleLBIndex(SL, Key);
  Result := i < SL.Count;
  if Result then Line := SL[i];
end;

function OracleFind(SL: TStringList; const Key: string; out Value: string): Boolean;
var
  s, v: string;
  p: Integer;
begin
  Result := OracleLB(SL, Key, s);
  if Result then
  begin
    Result := Copy(s, 1, Length(Key)) = Key;
    if Result then
    begin
      p := Pos(#1, s);
      v := Copy(s, p + 1, MaxInt);
      Value := v;
    end;
  end;
end;

function OracleRangeCount(SL: TStringList; const Lo, Hi: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  i := OracleLBIndex(SL, Lo);
  while (i < SL.Count) and (Copy(SL[i], 1, Length(Hi)) <= Hi) do
  begin
    Inc(Result);
    Inc(i);
  end;
end;

procedure TestCorrectness;
var
  L: TVDbSkipList;
  SL: TStringList;
  arr: TVDbSkipEntryArray;
  Keys, Vals: array of string;
  i, j, p, lo, hi, cnt: Integer;
  rnd: Cardinal;
  key, val, s, oval: string;
  lb: TVDbSkipEntry;
  ok: Boolean;
  line: string;
begin
  L := TVDbSkipList.Create(32, 20261019);
  SL := TStringList.Create;
  try
    SL.Sorted := True;
    SL.Duplicates := dupAccept;
    SL.CaseSensitive := True;
    SetLength(Keys, N);
    SetLength(Vals, N);
    rnd := 12345;
    for i := 0 to N - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      key := K(rnd mod 150000);
      val := V(i);
      Keys[i] := key;
      Vals[i] := val;
      Check(L.Insert(key, val), 'Insert ' + key + '/' + val);
      SL.Add(LineOf(key, val));
    end;
    Check(L.Count = SL.Count, 'Count ekleme sonrasi');
    Writeln(Format('  Ekleme: %d girdi, Count=%d', [N, L.Count]));

    // Ayni Key+Value ikinci kez eklenmemeli.
    key := K(123); val := V(7);
    if SL.IndexOf(LineOf(key, val)) >= 0 then
    begin
      Check(not L.Insert(key, val), 'mukerrer girdi reddedilmeli');
    end;

    // Tam sirali dokum oracle ile birebir ayni olmali.
    cnt := L.All(arr);
    Check(cnt = SL.Count, 'All Count');
    ok := True;
    for i := 0 to cnt - 1 do
    begin
      s := LineOf(arr[i].Key, arr[i].Value);
      if s <> SL[i] then
      begin
        ok := False;
        Writeln('  Sirali fark i=', i, ' got=', s, ' exp=', SL[i]);
        Break;
      end;
    end;
    Check(ok, 'All sirasi');

    rnd := 777;
    for i := 0 to N_FIND - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      key := K(rnd mod 150000);
      ok := OracleFind(SL, key, oval);
      Check(L.Find(key, val) = ok, 'Find varlik ' + key);
      if ok then Check(val = oval, 'Find deger ' + key);
    end;

    rnd := 991;
    for i := 0 to N_LB - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      key := K(rnd mod 200000);
      ok := OracleLB(SL, key, line);
      Check(L.LowerBound(key, lb) = ok, 'LowerBound varlik ' + key);
      if ok then
        Check(LineOf(lb.Key, lb.Value) = line, 'LowerBound deger ' + key);
    end;

    rnd := 31337;
    for i := 0 to N_RANGE - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      lo := rnd mod 190000;
      rnd := rnd * 1664525 + 1013904223;
      hi := lo + (rnd mod 50);
      cnt := L.Range(K(lo), K(hi), arr);
      Check(cnt = OracleRangeCount(SL, K(lo), K(hi)), 'Range sayisi');
      ok := True;
      for j := 0 to cnt - 1 do
        if (arr[j].Key < K(lo)) or (arr[j].Key > K(hi)) then
        begin
          ok := False;
          Break;
        end;
      Check(ok, 'Range sinirlari');
      if cnt > 0 then
      begin
        ok := OracleLB(SL, K(lo), line);
        Check(ok and (LineOf(arr[0].Key, arr[0].Value) = line),
          'Range ilk anahtar');
        Check(arr[cnt - 1].Key <= K(hi), 'Range son anahtar');
      end;
    end;

    // Silme: rastgele yarisi sil, oracle ile karsilastir.
    rnd := 4242;
    for i := 0 to N_DEL - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      j := rnd mod N;
      key := Keys[j];
      val := Vals[j];
      line := LineOf(key, val);
      p := OracleLBIndex(SL, line);
      if (p >= SL.Count) or (SL[p] <> line) then p := -1;
      if p >= 0 then
      begin
        Check(L.Delete(key, val), 'Delete ' + key + '/' + val);
        SL.Delete(p);
      end
      else
        Check(not L.Delete(key, val), 'Delete olmayan');
    end;
    Check(L.Count = SL.Count, 'Count silme sonrasi');
    cnt := L.All(arr);
    ok := True;
    for i := 0 to cnt - 1 do
      if LineOf(arr[i].Key, arr[i].Value) <> SL[i] then
      begin
        ok := False;
        Break;
      end;
    Check(ok, 'Silme sonrasi sira');
    Writeln(Format('  Silme: %d deneme, Count=%d', [N_DEL, L.Count]));
  finally
    SL.Free;
    L.Free;
  end;
end;

procedure Bench;
var
  L: TVDbSkipList;
  i: Integer;
  t0, t1: Int64;
  rnd: Cardinal;
  e: TVDbSkipEntry;
  arr: TVDbSkipEntryArray;
  cnt: Integer;
  msIns, msLB, msRange, msDel: Double;
begin
  L := TVDbSkipList.Create(32, 998877);
  try
    t0 := Tick;
    for i := 0 to BENCH_N - 1 do
      L.Insert(K(i), V(i));
    t1 := Tick;
    msIns := MS(t0, t1);
    Check(L.Count = BENCH_N, 'bench Count');

    rnd := 555;
    t0 := Tick;
    for i := 0 to 200000 - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      L.LowerBound(K(rnd mod BENCH_N), e);
    end;
    t1 := Tick;
    msLB := MS(t0, t1);

    rnd := 666;
    t0 := Tick;
    for i := 0 to 10000 - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      cnt := L.Range(K(rnd mod BENCH_N), K((rnd mod 1000) + (rnd mod BENCH_N)),
        arr);
      if cnt < 0 then Check(False, 'range');
    end;
    t1 := Tick;
    msRange := MS(t0, t1);

    rnd := 777;
    t0 := Tick;
    for i := 0 to 100000 - 1 do
    begin
      rnd := rnd * 1664525 + 1013904223;
      L.Delete(K(rnd mod BENCH_N), V(rnd mod BENCH_N));
    end;
    t1 := Tick;
    msDel := MS(t0, t1);

    Writeln(Format('  BENCH %d: ekleme=%.1f ms  LB(200k)=%.1f ms  range(10k)=%.1f ms  silme(100k)=%.1f ms  son Count=%d',
      [BENCH_N, msIns, msLB, msRange, msDel, L.Count]));
  finally
    L.Free;
  end;
end;

begin
  fails := 0;
  QueryPerformanceFrequency(GFreq);
  Writeln('H3 skiplist prototipi');
  TestCorrectness;
  Bench;
  if fails = 0 then
    Writeln('SONUC: TAMAM (0 hata)')
  else
    Writeln(Format('SONUC: %d HATA', [fails]));
  if fails <> 0 then Halt(1);
end.
