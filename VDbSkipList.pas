{ H3: bellek-ici sirali indeks prototipi (skiplist).

  Mevcut TIdxEntries dilimi sorgu tarafinda cok hizli; kalan maliyet
  guncelleme sirasindaki O(N) birlestirme. Bu unit, TIdxEntry sozlesmesini
  (Key + Pk/Cov metinleri) bozmadan O(log N) ekleme/silme ve sirali
  aralik iterasyonu saglayan bagimsiz bir prototip sunar.

  NOT: Bu ilk adimda motora baglanmaz. btreechk gate'i veri yapisini
  bagimsiz bir oracle'a karsi dogrular ve 1M girdide olcer. Motora
  entegrasyon, TryGetMemIndex cagrilarinin aralik iterasyonuna
  tasinmasiyla ayri bir dilimde yapilacak. }
unit VDbSkipList;

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TVDbSkipEntry = record
    Key: string;    // indeks anahtari (VDbIdxJoin / kodlanmis deger)
    Value: string;  // sahip PK (veya covering payload)
    Cov: string;    // F-19 INCLUDE payload (opsiyonel)
  end;

  TVDbSkipEntryArray = array of TVDbSkipEntry;

  { Iki girdiyi karsilastirir. <0, 0, >0. Varsayilan: Key sonra Value. }
  TVDbSkipCompare = function(const A, B: TVDbSkipEntry): Integer of object;

  { Yalniz anahtarlari karsilastirir (aralik siniri aramalari icin). }
  TVDbSkipKeyCompare = function(const A, B: string): Integer of object;

  TVDbSkipNode = class
  public
    Entry: TVDbSkipEntry;
    Next: array of TVDbSkipNode;
    { H3 rank: Next[i]'ye kadar kac adet seviye-0 dugumu var (1 tabanli
      segment uzunlugu; Next[i]=nil ise 0). Boylece aralik sayimi O(log N). }
    Span: array of Integer;
  end;

  TVDbSkipList = class
  private
    FHead: TVDbSkipNode;
    FMaxLevel: Integer;
    FLevel: Integer;
    FCount: Int64;
    FRnd: Cardinal;
    FCompare: TVDbSkipCompare;
    function RandomLevel: Integer;
    function DefaultCompare(const A, B: TVDbSkipEntry): Integer;
  public
    constructor Create(AMaxLevel: Integer = 32; ASeed: Cardinal = 1); overload;
    constructor Create(ACompare: TVDbSkipCompare;
      AMaxLevel: Integer = 32; ASeed: Cardinal = 1); overload;
    destructor Destroy; override;
    procedure Clear;
    { Ayni Key+Value zaten varsa False doner (mukerrer girdi eklenmez). }
    function Insert(const Key, Value: string; const Cov: string = ''): Boolean; overload;
    function Insert(const E: TVDbSkipEntry): Boolean; overload;
    { Tam Key+Value eslesmesini siler. }
    function Delete(const Key, Value: string): Boolean;
    { Siralanmis girdi dizisini O(N) yukler (index insasi icin). }
    procedure LoadSorted(const Arr: TVDbSkipEntryArray);
    { Anahtar araligindaki ilk girdiyi dondurur. }
    function LowerBound(const Key: string; out E: TVDbSkipEntry): Boolean;
    { Anahtari tam eslesen ilk girdinin Value'sunu dondurur. }
    function Find(const Key: string; out Value: string): Boolean;
    { LoKey <= Key <= HiKey araligini sirali olarak toplar. }
    function Range(const LoKey, HiKey: string;
      out Arr: TVDbSkipEntryArray): Integer;
    { Anahtar karsilastiricisi ile sinirli aralik toplama/sayma.
      LoInc/HiInc false ise sinir dislayici; HasLo/HasHi false ise sinirsiz. }
    function CollectRange(const LoKey, HiKey: string;
      HasLo, HasHi, LoInc, HiInc: Boolean; ACompare: TVDbSkipKeyCompare;
      out Arr: TVDbSkipEntryArray): Integer;
    function CountRange(const LoKey, HiKey: string;
      HasLo, HasHi, LoInc, HiInc: Boolean;
      ACompare: TVDbSkipKeyCompare): Int64;
    { IncludeEqual=False: Key'den KUCUK girdi sayisi.
      IncludeEqual=True : Key'den KUCUK VEYA ESIT girdi sayisi. }
    function RankBefore(const Key: string; ACompare: TVDbSkipKeyCompare;
      IncludeEqual: Boolean): Int64;
    { Tum girdileri sirali olarak toplar (test/olcum icin). }
    function All(out Arr: TVDbSkipEntryArray): Integer;
    property Count: Int64 read FCount;
    property MaxLevel: Integer read FMaxLevel;
  end;

implementation

constructor TVDbSkipList.Create(AMaxLevel: Integer; ASeed: Cardinal);
begin
  Create(nil, AMaxLevel, ASeed);
end;

constructor TVDbSkipList.Create(ACompare: TVDbSkipCompare;
  AMaxLevel: Integer; ASeed: Cardinal);
begin
  inherited Create;
  if AMaxLevel < 1 then AMaxLevel := 1;
  if AMaxLevel > 62 then AMaxLevel := 62;
  FMaxLevel := AMaxLevel;
  FLevel := 0;
  FCount := 0;
  if ASeed = 0 then ASeed := 1;
  FRnd := ASeed;
  FCompare := ACompare;
  FHead := TVDbSkipNode.Create;
  SetLength(FHead.Next, FMaxLevel + 1);
  SetLength(FHead.Span, FMaxLevel + 1);
end;

destructor TVDbSkipList.Destroy;
begin
  Clear;
  FreeAndNil(FHead);
  inherited Destroy;
end;

procedure TVDbSkipList.Clear;
var
  n, x: TVDbSkipNode;
  i: Integer;
begin
  n := FHead.Next[0];
  while n <> nil do
  begin
    x := n.Next[0];
    n.Free;
    n := x;
  end;
  for i := 0 to High(FHead.Next) do
  begin
    FHead.Next[i] := nil;
    FHead.Span[i] := 0;
  end;
  FLevel := 0;
  FCount := 0;
end;

function TVDbSkipList.DefaultCompare(const A, B: TVDbSkipEntry): Integer;
begin
  Result := CompareStr(A.Key, B.Key);
  if Result = 0 then
    Result := CompareStr(A.Value, B.Value);
end;

function TVDbSkipList.RandomLevel: Integer;
begin
  { xorshift32: deterministik, tahsis yok. p = 1/4. }
  FRnd := FRnd xor (FRnd shl 13);
  FRnd := FRnd xor (FRnd shr 17);
  FRnd := FRnd xor (FRnd shl 5);
  Result := 0;
  while (Result < FMaxLevel) and ((FRnd and 3) = 0) do
  begin
    Inc(Result);
    FRnd := FRnd xor (FRnd shl 13);
    FRnd := FRnd xor (FRnd shr 17);
    FRnd := FRnd xor (FRnd shl 5);
  end;
end;

function TVDbSkipList.Insert(const Key, Value: string; const Cov: string): Boolean;
var
  e: TVDbSkipEntry;
begin
  e.Key := Key;
  e.Value := Value;
  e.Cov := Cov;
  Result := Insert(e);
end;

function TVDbSkipList.Insert(const E: TVDbSkipEntry): Boolean;
var
  upd: array of TVDbSkipNode;
  rankArr: array of Integer;
  x, n: TVDbSkipNode;
  i, lvl, rank, r, oldSpan: Integer;
  c: Integer;
begin
  SetLength(upd, FMaxLevel + 1);
  SetLength(rankArr, FMaxLevel + 1);
  rank := 0;
  x := FHead;
  for i := FLevel downto 0 do
  begin
    n := x.Next[i];
    while n <> nil do
    begin
      if Assigned(FCompare) then c := FCompare(n.Entry, E)
      else c := DefaultCompare(n.Entry, E);
      if c >= 0 then Break;
      rank := rank + x.Span[i];
      x := n;
      n := x.Next[i];
    end;
    upd[i] := x;
    rankArr[i] := rank;
  end;
  n := x.Next[0];
  if n <> nil then
  begin
    if Assigned(FCompare) then c := FCompare(n.Entry, E)
    else c := DefaultCompare(n.Entry, E);
    if c = 0 then Exit(False);   // ayni Key+Value
  end;
  lvl := RandomLevel;
  if lvl > FLevel then
  begin
    for i := FLevel + 1 to lvl do
    begin
      upd[i] := FHead;
      rankArr[i] := 0;
    end;
    FLevel := lvl;
  end;
  r := rank + 1;
  n := TVDbSkipNode.Create;
  n.Entry := E;
  SetLength(n.Next, lvl + 1);
  SetLength(n.Span, lvl + 1);
  for i := 0 to lvl do
  begin
    oldSpan := upd[i].Span[i];
    n.Next[i] := upd[i].Next[i];
    if n.Next[i] <> nil then
      n.Span[i] := oldSpan - (r - rankArr[i]) + 1
    else
      n.Span[i] := 0;
    upd[i].Next[i] := n;
    upd[i].Span[i] := r - rankArr[i];
  end;
  for i := lvl + 1 to FLevel do
    Inc(upd[i].Span[i]);
  Inc(FCount);
  Result := True;
end;

procedure TVDbSkipList.LoadSorted(const Arr: TVDbSkipEntryArray);
var
  prev: array of TVDbSkipNode;
  prevRank: array of Integer;
  n: TVDbSkipNode;
  i, j, lvl, r: Integer;
begin
  Clear;
  if Length(Arr) = 0 then Exit;
  SetLength(prev, FMaxLevel + 1);
  SetLength(prevRank, FMaxLevel + 1);
  for i := 0 to FMaxLevel do
  begin
    prev[i] := FHead;
    prevRank[i] := 0;
  end;
  for i := 0 to High(Arr) do
  begin
    lvl := RandomLevel;
    n := TVDbSkipNode.Create;
    n.Entry := Arr[i];
    SetLength(n.Next, lvl + 1);
    SetLength(n.Span, lvl + 1);
    r := i + 1;   // 1 tabanli sira
    for j := 0 to lvl do
    begin
      prev[j].Span[j] := r - prevRank[j];
      n.Next[j] := nil;
      n.Span[j] := 0;
      prev[j].Next[j] := n;
      prev[j] := n;
      prevRank[j] := r;
    end;
    if lvl > FLevel then FLevel := lvl;
  end;
  FCount := Length(Arr);
end;

function TVDbSkipList.Delete(const Key, Value: string): Boolean;
var
  e: TVDbSkipEntry;
  upd: array of TVDbSkipNode;
  x, n: TVDbSkipNode;
  i: Integer;
  c: Integer;
begin
  e.Key := Key;
  e.Value := Value;
  SetLength(upd, FMaxLevel + 1);
  x := FHead;
  for i := FLevel downto 0 do
  begin
    n := x.Next[i];
    while n <> nil do
    begin
      if Assigned(FCompare) then c := FCompare(n.Entry, e)
      else c := DefaultCompare(n.Entry, e);
      if c >= 0 then Break;
      x := n;
      n := x.Next[i];
    end;
    upd[i] := x;
  end;
  n := x.Next[0];
  if n = nil then Exit(False);
  if Assigned(FCompare) then c := FCompare(n.Entry, e)
  else c := DefaultCompare(n.Entry, e);
  if c <> 0 then Exit(False);
  for i := 0 to FLevel do
  begin
    if (i <= High(n.Next)) and (upd[i].Next[i] = n) then
    begin
      upd[i].Next[i] := n.Next[i];
      upd[i].Span[i] := upd[i].Span[i] + n.Span[i] - 1;
    end
    else if upd[i].Next[i] <> nil then
      Dec(upd[i].Span[i]);
  end;
  n.Free;
  Dec(FCount);
  while (FLevel > 0) and (FHead.Next[FLevel] = nil) do
    Dec(FLevel);
  Result := True;
end;

function TVDbSkipList.LowerBound(const Key: string;
  out E: TVDbSkipEntry): Boolean;
var
  x, n: TVDbSkipNode;
  i: Integer;
begin
  x := FHead;
  for i := FLevel downto 0 do
  begin
    n := x.Next[i];
    while (n <> nil) and (CompareStr(n.Entry.Key, Key) < 0) do
    begin
      x := n;
      n := x.Next[i];
    end;
  end;
  n := x.Next[0];
  if n = nil then Exit(False);
  E := n.Entry;
  Result := True;
end;

function TVDbSkipList.Find(const Key: string; out Value: string): Boolean;
var
  E: TVDbSkipEntry;
begin
  Result := LowerBound(Key, E) and (E.Key = Key);
  if Result then Value := E.Value;
end;

function TVDbSkipList.Range(const LoKey, HiKey: string;
  out Arr: TVDbSkipEntryArray): Integer;
var
  x, n: TVDbSkipNode;
  i, cap: Integer;
begin
  SetLength(Arr, 0);
  Result := 0;
  x := FHead;
  for i := FLevel downto 0 do
  begin
    n := x.Next[i];
    while (n <> nil) and (CompareStr(n.Entry.Key, LoKey) < 0) do
    begin
      x := n;
      n := x.Next[i];
    end;
  end;
  n := x.Next[0];
  cap := 0;
  while (n <> nil) and (CompareStr(n.Entry.Key, HiKey) <= 0) do
  begin
    if Result >= cap then
    begin
      if cap = 0 then cap := 16
      else cap := cap * 2;
      SetLength(Arr, cap);
    end;
    Arr[Result] := n.Entry;
    Inc(Result);
    n := n.Next[0];
  end;
  SetLength(Arr, Result);
end;

function TVDbSkipList.CollectRange(const LoKey, HiKey: string;
  HasLo, HasHi, LoInc, HiInc: Boolean; ACompare: TVDbSkipKeyCompare;
  out Arr: TVDbSkipEntryArray): Integer;
var
  x, n: TVDbSkipNode;
  i, cap, c: Integer;
begin
  SetLength(Arr, 0);
  Result := 0;
  x := FHead;
  if HasLo then
  begin
    for i := FLevel downto 0 do
    begin
      n := x.Next[i];
      while n <> nil do
      begin
        c := ACompare(n.Entry.Key, LoKey);
        if (c < 0) or ((c = 0) and (not LoInc)) then
        begin
          x := n;
          n := x.Next[i];
        end
        else
          Break;
      end;
    end;
  end;
  n := x.Next[0];
  cap := 0;
  while n <> nil do
  begin
    if HasHi then
    begin
      c := ACompare(n.Entry.Key, HiKey);
      if (c > 0) or ((c = 0) and (not HiInc)) then Break;
    end;
    if Result >= cap then
    begin
      if cap = 0 then cap := 16
      else cap := cap * 2;
      SetLength(Arr, cap);
    end;
    Arr[Result] := n.Entry;
    Inc(Result);
    n := n.Next[0];
  end;
  SetLength(Arr, Result);
end;

function TVDbSkipList.RankBefore(const Key: string;
  ACompare: TVDbSkipKeyCompare; IncludeEqual: Boolean): Int64;
var
  x, n: TVDbSkipNode;
  i, c: Integer;
begin
  Result := 0;
  x := FHead;
  for i := FLevel downto 0 do
  begin
    n := x.Next[i];
    while n <> nil do
    begin
      c := ACompare(n.Entry.Key, Key);
      if (c < 0) or (IncludeEqual and (c = 0)) then
      begin
        Inc(Result, x.Span[i]);
        x := n;
        n := x.Next[i];
      end
      else
        Break;
    end;
  end;
end;

function TVDbSkipList.CountRange(const LoKey, HiKey: string;
  HasLo, HasHi, LoInc, HiInc: Boolean;
  ACompare: TVDbSkipKeyCompare): Int64;
var
  lo, hi: Int64;
begin
  if HasLo then
    lo := RankBefore(LoKey, ACompare, not LoInc)
  else
    lo := 0;
  if HasHi then
    hi := RankBefore(HiKey, ACompare, HiInc)
  else
    hi := FCount;
  if hi <= lo then
    Result := 0
  else
    Result := hi - lo;
end;

function TVDbSkipList.All(out Arr: TVDbSkipEntryArray): Integer;
var
  n: TVDbSkipNode;
begin
  SetLength(Arr, FCount);
  Result := 0;
  n := FHead.Next[0];
  while n <> nil do
  begin
    Arr[Result] := n.Entry;
    Inc(Result);
    n := n.Next[0];
  end;
  SetLength(Arr, Result);
end;

end.
