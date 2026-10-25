program btreechk;

{ VDB v4 - B+tree sirali indeks kapisi (kapı 12)

  Denetlenenler (bagimsiz ORACLE'a karsi, skiplist ile PARITE):
    1) LoadSorted: sirali yukleme -> All birebir, Count dogru
    2) Rastgele Insert + mukerrer reddi
    3) All() tam sirasi oracle ile birebir
    4) Find / LowerBound
    5) CollectRange: 16 sinir kombinasyonu (HasLo/HasHi/LoInc/HiInc)
    6) CountRange: oracle aralik uzunlugu ile birebir
    7) RankBefore: oracle sayimi ile birebir
    8) Delete (yarisi + tamami) sonrasi All / aralik / sayi
    9) Ayni anahtar + farkli PK (es anlamli) siralama ve aralik sinirlari
   10) Sayisal karsilastirici: anahtar BAYTLARI sirali degilken de dogru
       (B+tree yalniz karsilastiriciya guvenir; "9" < "10" sozlesmesi)
   11) PARITE: ayni islem dizisi TVDbSkipList uzerinde de kosar; her adimda
       All/aralik/sayi ayni olmali
   12) Olcum: 200k girdi yukleme + 100k aralik sorgusu (B+tree vs skiplist)

  Cikis kodu: 0 = hepsi gecti, 1 = hata.
  Kullanim: btreechk [girdi_sayisi]
}

{$mode delphi}{$H+}

uses
  SysUtils, DateUtils, VDbSkipList, VDbBTree;

function QueryPerformanceCounter(out C: Int64): LongBool; stdcall;
  external 'kernel32' name 'QueryPerformanceCounter';
function QueryPerformanceFrequency(out F: Int64): LongBool; stdcall;
  external 'kernel32' name 'QueryPerformanceFrequency';

var
  gPass, gFail: Int64;
  gQpf: Int64 = 0;

function NowUs: Int64;
var
  c: Int64;
begin
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then Result := (c * 1000) div gQpf
  else Result := c * 1000;
end;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

type
  TCmp = class
  public
    Numeric: Boolean;
    KeyOrder: Boolean;   // True: yalniz anahtar (Value esit sayilir)
    function Key(const A, B: string): Integer;
    function Full(const A, B: TVDbSkipEntry): Integer;
  end;

function TCmp.Key(const A, B: string): Integer;
var
  x, y: Int64;
begin
  if Numeric then
  begin
    x := StrToInt64Def(A, 0);
    y := StrToInt64Def(B, 0);
    if x < y then Exit(-1);
    if x > y then Exit(1);
    Exit(0);
  end;
  Result := CompareStr(A, B);
end;

function TCmp.Full(const A, B: TVDbSkipEntry): Integer;
begin
  Result := Key(A.Key, B.Key);
  if Result <> 0 then Exit;
  Result := CompareStr(A.Value, B.Value);
  if Result <> 0 then Exit;
  Result := CompareStr(A.Cov, B.Cov);
end;

{ ------------------------------------------------------------ ORACLE
  Bilerek en saf uygulama: sirali dizi + ikili arama + DOGRUSAL aralik
  taramasi. Hicbir B+tree/skiplist kodu paylasilmaz. }

type
  TOracle = class
  public
    Items: TVDbSkipEntryArray;
    Cmp: TCmp;
    constructor Create(C: TCmp);
    function Pos(const E: TVDbSkipEntry): Integer;   // ilk >= E
    function Add(const E: TVDbSkipEntry): Boolean;
    function Remove(const E: TVDbSkipEntry): Boolean;
    function Count: Integer;
    function RangeOf(const LoKey, HiKey: string; HasLo, HasHi, LoInc,
      HiInc: Boolean): TVDbSkipEntryArray;
    function RankOf(const Key: string; IncludeEqual: Boolean): Int64;
  end;

constructor TOracle.Create(C: TCmp);
begin
  inherited Create;
  Cmp := C;
  SetLength(Items, 0);
end;

function TOracle.Pos(const E: TVDbSkipEntry): Integer;
var
  lo, hi, mid: Integer;
begin
  lo := 0;
  hi := Length(Items);
  while lo < hi do
  begin
    mid := (lo + hi) div 2;
    if Cmp.Full(Items[mid], E) < 0 then lo := mid + 1
    else hi := mid;
  end;
  Result := lo;
end;

function TOracle.Add(const E: TVDbSkipEntry): Boolean;
var
  p, n, i: Integer;
begin
  p := Pos(E);
  if (p < Length(Items)) and (Cmp.Full(Items[p], E) = 0) then Exit(False);
  n := Length(Items);
  SetLength(Items, n + 1);
  for i := n downto p + 1 do
    Items[i] := Items[i - 1];
  Items[p] := E;
  Result := True;
end;

function TOracle.Remove(const E: TVDbSkipEntry): Boolean;
var
  p, i: Integer;
begin
  p := Pos(E);
  if (p >= Length(Items)) or (Cmp.Full(Items[p], E) <> 0) then Exit(False);
  for i := p to High(Items) - 1 do
    Items[i] := Items[i + 1];
  SetLength(Items, Length(Items) - 1);
  Result := True;
end;

function TOracle.Count: Integer;
begin
  Result := Length(Items);
end;

function TOracle.RangeOf(const LoKey, HiKey: string; HasLo, HasHi, LoInc,
  HiInc: Boolean): TVDbSkipEntryArray;
var
  i, c, n: Integer;
  ok: Boolean;
begin
  SetLength(Result, Length(Items));
  n := 0;
  for i := 0 to High(Items) do
  begin
    ok := True;
    if HasLo then
    begin
      c := Cmp.Key(Items[i].Key, LoKey);
      if (c < 0) or ((c = 0) and (not LoInc)) then ok := False;
    end;
    if ok and HasHi then
    begin
      c := Cmp.Key(Items[i].Key, HiKey);
      if (c > 0) or ((c = 0) and (not HiInc)) then ok := False;
    end;
    if ok then
    begin
      Result[n] := Items[i];
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

function TOracle.RankOf(const Key: string; IncludeEqual: Boolean): Int64;
var
  i, c: Integer;
begin
  Result := 0;
  for i := 0 to High(Items) do
  begin
    c := Cmp.Key(Items[i].Key, Key);
    if (c < 0) or (IncludeEqual and (c = 0)) then Inc(Result)
    else if c > 0 then Break;
  end;
end;

{ ------------------------------------------------------------ yardimcilar }

function EqEntries(const A, B: TVDbSkipEntryArray; out Err: string): Boolean;
var
  i: Integer;
begin
  Err := '';
  if Length(A) <> Length(B) then
  begin
    Err := Format('uzunluk %d <> %d', [Length(A), Length(B)]);
    Exit(False);
  end;
  for i := 0 to High(A) do
    if (A[i].Key <> B[i].Key) or (A[i].Value <> B[i].Value) or
       (A[i].Cov <> B[i].Cov) then
    begin
      Err := Format('eleman %d: (%s,%s) <> (%s,%s)',
        [i, A[i].Key, A[i].Value, B[i].Key, B[i].Value]);
      Exit(False);
    end;
  Result := True;
end;

var
  gRnd: Cardinal = 12345;

function Rnd(ARange: Cardinal): Cardinal;
begin
  { xorshift32 }
  gRnd := gRnd xor (gRnd shl 13);
  gRnd := gRnd xor (gRnd shr 17);
  gRnd := gRnd xor (gRnd shl 5);
  if ARange = 0 then Result := 0
  else Result := gRnd mod ARange;
end;

function Entry(const K, V: string): TVDbSkipEntry;
begin
  Result.Key := K;
  Result.Value := V;
  Result.Cov := '';
end;

function PadKey(I: Integer): string;
begin
  Result := Format('%.10d', [I]);
end;

{ ------------------------------------------------------------ testler }

procedure TestLoadSorted(N: Integer);
var
  c: TCmp;
  bt: TVDbBTree;
  arr, got: TVDbSkipEntryArray;
  i: Integer;
  err: string;
begin
  c := TCmp.Create;
  bt := TVDbBTree.Create(c.Full, 96);
  try
    SetLength(arr, N);
    for i := 0 to N - 1 do
      arr[i] := Entry(PadKey(i * 3), 'pk' + IntToStr(i));
    bt.LoadSorted(arr);
    if bt.Count = N then Ok(Format('LoadSorted: %d girdi yuklendi', [N]))
    else Fail(Format('LoadSorted: sayi %d (beklenen %d)', [bt.Count, N]));
    if bt.All(got) = N then
    begin
      if EqEntries(arr, got, err) then
        Ok('LoadSorted: All() sirasi birebir')
      else
        Fail('LoadSorted: sira farkli - ' + err);
    end
    else
      Fail('LoadSorted: All() sayisi yanlis');
    if bt.Range(arr[0].Key, arr[0].Key, got) = 1 then
      Ok('LoadSorted: tek anahtar araligi 1 girdi')
    else
      Fail('LoadSorted: tek anahtar araligi yanlis');
  finally
    bt.Free;
    c.Free;
  end;
end;

procedure TestInsertAndAll(N: Integer);
var
  c: TCmp;
  bt, bt2: TVDbBTree;
  o: TOracle;
  i, dup: Integer;
  e: TVDbSkipEntry;
  got, want: TVDbSkipEntryArray;
  err: string;
  sv: string;
  nBad, k: Integer;
begin
  c := TCmp.Create;
  bt := TVDbBTree.Create(c.Full, 96);
  bt2 := TVDbBTree.Create(c.Full, 7);   // kucuk dugum: cok seviye + bolunme
  o := TOracle.Create(c);
  try
    for i := 1 to N do
    begin
      e := Entry(PadKey(Rnd(N * 4)), 'p' + IntToStr(i));
      if bt.Insert(e) <> bt2.Insert(e) then
        Fail('Insert donusu dugum boyutuna gore farkli');
      o.Add(e);
    end;
    if bt.Count = o.Count then
      Ok(Format('rastgele Insert: sayi %d dogru', [bt.Count]))
    else
      Fail(Format('rastgele Insert: sayi %d <> %d', [bt.Count, o.Count]));
    if (bt2.Count = o.Count) then
      Ok('kucuk dugum (7 anahtar): sayi dogru')
    else
      Fail(Format('kucuk dugum: sayi %d <> %d', [bt2.Count, o.Count]));

    // mukerrer
    dup := 0;
    for i := 0 to High(o.Items) do
      if not bt.Insert(o.Items[i]) then Inc(dup);
    if dup = o.Count then
      Ok(Format('mukerrer Insert reddedildi (%d adet)', [dup]))
    else
      Fail(Format('mukerrer reddi: %d / %d', [dup, o.Count]));
    if bt.Count = o.Count then
      Ok('mukerrer sonrasi sayi degismedi')
    else
      Fail('mukerrer sonrasi sayi degisti');

    bt.All(got);
    want := o.Items;
    if EqEntries(want, got, err) then
      Ok('All() tam sirasi oracle ile birebir')
    else
      Fail('All() sira farkli - ' + err);

    // es anlamli anahtarlarla RankBefore (B+tree dugum sinirlarini asar)
    nBad := 0;
    for i := 0 to 199 do
    begin
      sv := PadKey(Rnd(N * 4));
      for k := 0 to 1 do
        if bt.RankBefore(sv, c.Key, k = 1) <> o.RankOf(sv, k = 1) then
        begin
          Inc(nBad);
          if nBad = 1 then
            Fail(Format('RankBefore %s inc=%d: %d <> %d',
              [sv, k, bt.RankBefore(sv, c.Key, k = 1), o.RankOf(sv, k = 1)]));
        end;
    end;
    if nBad = 0 then
      Ok('RankBefore 400 sorgu (es anlamli anahtarlar) birebir');
    if bt.CheckInvariants = '' then
      Ok('B+tree degismezleri (SubCount, ayirici, yaprak zinciri) saglam')
    else
      Fail('degismez ihlali: ' + bt.CheckInvariants);

    // Find / LowerBound
    if bt.Find(o.Items[0].Key, sv) and (sv = o.Items[0].Value) then
      Ok('Find ilk anahtar')
    else
      Fail('Find ilk anahtar basarisiz');
    if not bt.Find('ZZZZZZ', sv) then
      Ok('Find olmayan anahtar False')
    else
      Fail('Find olmayan anahtar True');
  finally
    bt.Free;
    bt2.Free;
    o.Free;
    c.Free;
  end;
end;

procedure TestRanges(N: Integer);
var
  c: TCmp;
  bt: TVDbBTree;
  o: TOracle;
  i, k, cursor, nGood, nBad: Integer;
  loKey, hiKey: string;
  hasLo, hasHi, loInc, hiInc: Boolean;
  got, want: TVDbSkipEntryArray;
  err: string;
begin
  c := TCmp.Create;
  bt := TVDbBTree.Create(c.Full, 32);
  o := TOracle.Create(c);
  try
    for i := 0 to N - 1 do
      o.Add(Entry(PadKey(i * 2), 'v' + IntToStr(i)));   // cift anahtarlar
    bt.LoadSorted(o.Items);
    nGood := 0;
    nBad := 0;
    for k := 0 to 63 do
    begin
      hasLo := (k and 1) <> 0;
      hasHi := (k and 2) <> 0;
      loInc := (k and 4) <> 0;
      hiInc := (k and 8) <> 0;
      case (k shr 4) and 3 of
        0: begin cursor := Rnd(N) * 2; loKey := PadKey(cursor); hiKey := PadKey(cursor + 20); end;
        1: begin cursor := Rnd(N) * 2; loKey := PadKey(cursor + 41); hiKey := PadKey(cursor); end; // ters: bos
        2: begin loKey := PadKey(0); hiKey := PadKey(N * 2); end;
      else
        loKey := PadKey(Rnd(N * 2));
        hiKey := loKey;
      end;
      bt.CollectRange(loKey, hiKey, hasLo, hasHi, loInc, hiInc, c.Key, got);
      want := o.RangeOf(loKey, hiKey, hasLo, hasHi, loInc, hiInc);
      if EqEntries(want, got, err) then Inc(nGood)
      else
      begin
        Inc(nBad);
        if nBad = 1 then
          Fail(Format('CollectRange k=%d (%s..%s hl=%s hh=%s li=%s hi=%s): %s',
            [k, loKey, hiKey, BoolToStr(hasLo, True), BoolToStr(hasHi, True),
             BoolToStr(loInc, True), BoolToStr(hiInc, True), err]));
      end;
      if bt.CountRange(loKey, hiKey, hasLo, hasHi, loInc, hiInc, c.Key) <>
         Length(want) then
        Fail(Format('CountRange k=%d: %d <> %d',
          [k, bt.CountRange(loKey, hiKey, hasLo, hasHi, loInc, hiInc, c.Key),
           Length(want)]));
      if bt.CountRange(loKey, hiKey, hasLo, hasHi, loInc, hiInc, c.Key) <>
         Length(got) then
        Fail(Format('CountRange k=%d CollectRange ile uyusmuyor: %d <> %d',
          [k, bt.CountRange(loKey, hiKey, hasLo, hasHi, loInc, hiInc, c.Key),
           Length(got)]));
    end;
    if nBad = 0 then
      Ok(Format('CollectRange 64 sinir kombinasyonu birebir (%d pencere)', [nGood]));

    // RankBefore
    nBad := 0;
    for k := 0 to 199 do
    begin
      loKey := PadKey(Rnd(N * 3));
      for i := 0 to 1 do
        if bt.RankBefore(loKey, c.Key, i = 1) <> o.RankOf(loKey, i = 1) then
        begin
          Inc(nBad);
          if nBad = 1 then
            Fail(Format('RankBefore %s inc=%d: %d <> %d',
              [loKey, i, bt.RankBefore(loKey, c.Key, i = 1), o.RankOf(loKey, i = 1)]));
        end;
    end;
    if nBad = 0 then
      Ok('RankBefore 400 sorgu birebir');
  finally
    bt.Free;
    o.Free;
    c.Free;
  end;
end;

procedure TestDelete(N: Integer);
var
  c: TCmp;
  bt: TVDbBTree;
  o: TOracle;
  i: Integer;
  got, want: TVDbSkipEntryArray;
  err: string;
begin
  c := TCmp.Create;
  bt := TVDbBTree.Create(c.Full, 24);
  o := TOracle.Create(c);
  try
    for i := 0 to N - 1 do
    begin
      bt.Insert(Entry(PadKey(i), 'v' + IntToStr(i)));
      o.Add(Entry(PadKey(i), 'v' + IntToStr(i)));
    end;
    // her ikinciyi sil
    for i := 0 to N - 1 do
      if (i mod 2) = 0 then
      begin
        if not bt.Delete(PadKey(i), 'v' + IntToStr(i)) then
          Fail(Format('Delete %d False', [i]));
        o.Remove(Entry(PadKey(i), 'v' + IntToStr(i)));
      end;
    if bt.Count = o.Count then
      Ok(Format('yarisi silindi: sayi %d dogru', [bt.Count]))
    else
      Fail(Format('silme sonrasi sayi %d <> %d', [bt.Count, o.Count]));
    if not bt.Delete(PadKey(0), 'v0') then
      Ok('silinmis girdiyi tekrar silmek False')
    else
      Fail('silinmis girdiyi silmek True');
    bt.All(got);
    want := o.Items;
    if EqEntries(want, got, err) then
      Ok('silme sonrasi All() birebir')
    else
      Fail('silme sonrasi sira farkli - ' + err);
    got := nil;
    bt.CollectRange(PadKey(10), PadKey(200), True, True, True, True, c.Key, got);
    want := o.RangeOf(PadKey(10), PadKey(200), True, True, True, True);
    if EqEntries(want, got, err) then
      Ok('silme sonrasi aralik birebir')
    else
      Fail('silme sonrasi aralik farkli - ' + err);
    // hepsini sil
    for i := 0 to High(o.Items) do
      bt.Delete(o.Items[i].Key, o.Items[i].Value);
    if (bt.Count = 0) and (bt.All(got) = 0) then
      Ok('tamami silindi: sayi 0, All bos')
    else
      Fail(Format('tamami silme: sayi %d, All %d', [bt.Count, Length(got)]));
    bt.CollectRange('', '', False, False, True, True, c.Key, got);
    if Length(got) = 0 then
      Ok('bos agacta aralik bos')
    else
      Fail(Format('bos agacta aralik %d girdi', [Length(got)]));
    // yeniden ekleme
    for i := 0 to 99 do
      bt.Insert(Entry(PadKey(i), 'n' + IntToStr(i)));
    if bt.Count = 100 then
      Ok('bos agaca yeniden ekleme: 100 girdi')
    else
      Fail(Format('yeniden ekleme: %d', [bt.Count]));
  finally
    bt.Free;
    o.Free;
    c.Free;
  end;
end;

procedure TestDuplicateKeys;
var
  c: TCmp;
  bt: TVDbBTree;
  i: Integer;
  got: TVDbSkipEntryArray;
begin
  c := TCmp.Create;
  bt := TVDbBTree.Create(c.Full, 8);
  try
    for i := 0 to 39 do
      bt.Insert(Entry('k', 'p' + PadKey(i)));
    if bt.Count = 40 then
      Ok('es anlamli 40 girdi (ayni Key, farkli PK) eklendi')
    else
      Fail(Format('es anlamli sayi %d', [bt.Count]));
    bt.CollectRange('k', 'k', True, True, True, True, c.Key, got);
    if Length(got) = 40 then
      Ok('es anlamli aralik 40 girdi')
    else
      Fail(Format('es anlamli aralik %d', [Length(got)]));
    if (got[0].Value = 'p' + PadKey(0)) and (got[39].Value = 'p' + PadKey(39)) then
      Ok('es anlamli siralama PK ile deterministik')
    else
      Fail(Format('es anlamli sira: %s .. %s', [got[0].Value, got[39].Value]));
    if not bt.Insert(Entry('k', 'p' + PadKey(0))) then
      Ok('es anlamli mukerrer (Key+PK) reddedildi')
    else
      Fail('es anlamli mukerrer kabul edildi');
  finally
    bt.Free;
    c.Free;
  end;
end;

procedure TestNumericCompare(N: Integer);
var
  c: TCmp;
  bt: TVDbBTree;
  o: TOracle;
  i: Integer;
  got, want: TVDbSkipEntryArray;
  err: string;
begin
  c := TCmp.Create;
  c.Numeric := True;
  bt := TVDbBTree.Create(c.Full, 16);
  o := TOracle.Create(c);
  try
    // anahtar baytlari sirali DEGIL: "10" < "9" (byte), sayisal 9 < 10
    for i := 0 to N - 1 do
    begin
      bt.Insert(Entry(IntToStr((i * 7919) mod (N * 3)), 'v' + IntToStr(i)));
      o.Add(Entry(IntToStr((i * 7919) mod (N * 3)), 'v' + IntToStr(i)));
    end;
    bt.All(got);
    want := o.Items;
    if EqEntries(want, got, err) then
      Ok('sayisal karsilastirici: All() oracle ile birebir')
    else
      Fail('sayisal karsilastirici sira farkli - ' + err);
    bt.CollectRange('9', '11', True, True, True, True, c.Key, got);
    want := o.RangeOf('9', '11', True, True, True, True);
    if EqEntries(want, got, err) then
      Ok('sayisal karsilastirici: 9..11 araligi birebir')
    else
      Fail('sayisal aralik farkli - ' + err);
  finally
    bt.Free;
    o.Free;
    c.Free;
  end;
end;

procedure TestParity(N: Integer);
var
  c: TCmp;
  bt: TVDbBTree;
  sk: TVDbSkipList;
  i: Integer;
  e: TVDbSkipEntry;
  a, b: TVDbSkipEntryArray;
  err: string;
  nBad: Integer;
  k: Integer;
begin
  c := TCmp.Create;
  bt := TVDbBTree.Create(c.Full, 32);
  sk := TVDbSkipList.Create(c.Full, 32, 1);
  nBad := 0;
  try
    for i := 1 to N do
    begin
      e := Entry(PadKey(Rnd(N * 2)), 'p' + IntToStr(i));
      if bt.Insert(e) <> sk.Insert(e) then
      begin
        Inc(nBad);
        if nBad = 1 then Fail('Insert donusu farkli');
      end;
      if (i mod 5) = 0 then
      begin
        // rastgele bir anahtari sil
        k := Rnd(N * 2);
        e := Entry(PadKey(k), 'p' + IntToStr(Rnd(i) + 1));
        bt.Delete(e.Key, e.Value);
        sk.Delete(e.Key, e.Value);
      end;
      if (i mod 97) = 0 then
      begin
        bt.All(a);
        sk.All(b);
        if not EqEntries(a, b, err) then
        begin
          Inc(nBad);
          if nBad = 1 then Fail('All farkli: ' + err);
        end;
      end;
    end;
    // ayni sinirlarla karsilastir
    for k := 0 to 99 do
    begin
      i := Rnd(N * 2);
      bt.CollectRange(PadKey(i), PadKey(i + 50), True, True, True, True, c.Key, a);
      sk.CollectRange(PadKey(i), PadKey(i + 50), True, True, True, True, c.Key, b);
      if not EqEntries(a, b, err) then
      begin
        Inc(nBad);
        if nBad = 1 then Fail('aralik farkli: ' + err);
      end;
      if bt.CountRange(PadKey(i), PadKey(i + 50), True, True, True, True, c.Key) <>
         Length(a) then
      begin
        Inc(nBad);
        if nBad = 1 then
          Fail(Format('B+tree CountRange <> CollectRange (%s..%s): %d <> %d',
            [PadKey(i), PadKey(i + 50),
             bt.CountRange(PadKey(i), PadKey(i + 50), True, True, True, True, c.Key),
             Length(a)]));
      end;
      if sk.CountRange(PadKey(i), PadKey(i + 50), True, True, True, True, c.Key) <>
         Length(b) then
      begin
        Inc(nBad);
        if nBad = 1 then
          Fail(Format('skiplist CountRange <> CollectRange (%s..%s): %d <> %d',
            [PadKey(i), PadKey(i + 50),
             sk.CountRange(PadKey(i), PadKey(i + 50), True, True, True, True, c.Key),
             Length(b)]));
      end;
    end;
    if bt.Count = sk.Count then
      Ok(Format('PARITE skiplist: sayi %d ayni', [bt.Count]))
    else
      Fail(Format('PARITE sayi %d <> %d', [bt.Count, sk.Count]));
    if nBad = 0 then
      Ok('PARITE skiplist: 100 aralik + 100 sayim birebir');
  finally
    bt.Free;
    sk.Free;
    c.Free;
  end;
end;

procedure TestPerf(N: Integer);
var
  c: TCmp;
  bt: TVDbBTree;
  sk: TVDbSkipList;
  arr: TVDbSkipEntryArray;
  i, q: Integer;
  usBt, usSk: Int64;
  got: TVDbSkipEntryArray;
begin
  c := TCmp.Create;
  bt := TVDbBTree.Create(c.Full, 96);
  sk := TVDbSkipList.Create(c.Full, 32, 1);
  try
    SetLength(arr, N);
    for i := 0 to N - 1 do
      arr[i] := Entry(PadKey(i * 2), 'v' + IntToStr(i));
    // yukleme
    usBt := NowUs;
    bt.LoadSorted(arr);
    usBt := NowUs - usBt;
    usSk := NowUs;
    sk.LoadSorted(arr);
    usSk := NowUs - usSk;
    WriteLn(Format('        yukleme %d girdi: B+tree %.1f ms, skiplist %.1f ms',
      [N, usBt / 1000, usSk / 1000]));

    // dar aralik: 21 anahtar
    usBt := NowUs;
    for q := 1 to 100000 do
    begin
      i := Rnd(N) * 2;
      bt.CollectRange(PadKey(i), PadKey(i + 40), True, True, True, True, c.Key, got);
    end;
    usBt := NowUs - usBt;
    usSk := NowUs;
    for q := 1 to 100000 do
    begin
      i := Rnd(N) * 2;
      sk.CollectRange(PadKey(i), PadKey(i + 40), True, True, True, True, c.Key, got);
    end;
    usSk := NowUs - usSk;
    WriteLn(Format('        100k dar aralik (21 anahtar): B+tree %.1f ms, skiplist %.1f ms',
      [usBt / 1000, usSk / 1000]));

    // genis aralik: 401 anahtar
    usBt := NowUs;
    for q := 1 to 10000 do
    begin
      i := Rnd(N) * 2;
      bt.CollectRange(PadKey(i), PadKey(i + 800), True, True, True, True, c.Key, got);
    end;
    usBt := NowUs - usBt;
    usSk := NowUs;
    for q := 1 to 10000 do
    begin
      i := Rnd(N) * 2;
      sk.CollectRange(PadKey(i), PadKey(i + 800), True, True, True, True, c.Key, got);
    end;
    usSk := NowUs - usSk;
    WriteLn(Format('        10k genis aralik (401 anahtar): B+tree %.1f ms, skiplist %.1f ms',
      [usBt / 1000, usSk / 1000]));

    // rastgele ekleme (yuklu agac)
    usBt := NowUs;
    for i := 0 to N - 1 do
      bt.Insert(Entry(PadKey(N * 2 + i), 'x' + IntToStr(i)));
    usBt := NowUs - usBt;
    usSk := NowUs;
    for i := 0 to N - 1 do
      sk.Insert(Entry(PadKey(N * 2 + i), 'x' + IntToStr(i)));
    usSk := NowUs - usSk;
    WriteLn(Format('        %d rastgele ekleme: B+tree %.1f ms, skiplist %.1f ms',
      [N, usBt / 1000, usSk / 1000]));
    if (bt.Count = sk.Count) then
      Ok('olcum sonrasi sayilar ayni')
    else
      Fail('olcum sonrasi sayilar farkli');
  finally
    bt.Free;
    sk.Free;
    c.Free;
  end;
end;

var
  N: Integer;
begin
  gPass := 0;
  gFail := 0;
  N := 50000;
  if ParamCount >= 1 then N := StrToIntDef(ParamStr(1), N);
  if N < 100 then N := 100;

  WriteLn('VDB v4 btreechk - B+tree sirali indeks kapisi');
  WriteLn('girdi=', N);
  WriteLn;

  TestLoadSorted(N);
  TestInsertAndAll(N);
  TestRanges(N);
  TestDelete(N);
  TestDuplicateKeys;
  TestNumericCompare(N div 10 + 10);
  TestParity(N);
  TestPerf(N div 5 + 100);

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('B+TREE INDEKS DOGRULANDI');
    Halt(0);
  end;
  WriteLn('B+TREE INDEKS HATALI');
  Halt(1);
end.
