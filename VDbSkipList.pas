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
  end;

  TVDbSkipEntryArray = array of TVDbSkipEntry;

  { Iki girdiyi karsilastirir. <0, 0, >0. Varsayilan: Key sonra Value. }
  TVDbSkipCompare = function(const A, B: TVDbSkipEntry): Integer of object;

  TVDbSkipNode = class
  public
    Entry: TVDbSkipEntry;
    Next: array of TVDbSkipNode;
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
    function Insert(const Key, Value: string): Boolean;
    { Tam Key+Value eslesmesini siler. }
    function Delete(const Key, Value: string): Boolean;
    { Anahtar araligindaki ilk girdiyi dondurur. }
    function LowerBound(const Key: string; out E: TVDbSkipEntry): Boolean;
    { Anahtari tam eslesen ilk girdinin Value'sunu dondurur. }
    function Find(const Key: string; out Value: string): Boolean;
    { LoKey <= Key <= HiKey araligini sirali olarak toplar. }
    function Range(const LoKey, HiKey: string;
      out Arr: TVDbSkipEntryArray): Integer;
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
    FHead.Next[i] := nil;
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

function TVDbSkipList.Insert(const Key, Value: string): Boolean;
var
  e: TVDbSkipEntry;
  upd: array of TVDbSkipNode;
  x, n: TVDbSkipNode;
  i, lvl: Integer;
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
  if n <> nil then
  begin
    if Assigned(FCompare) then c := FCompare(n.Entry, e)
    else c := DefaultCompare(n.Entry, e);
    if c = 0 then Exit(False);   // ayni Key+Value
  end;
  lvl := RandomLevel;
  if lvl > FLevel then
  begin
    for i := FLevel + 1 to lvl do
      upd[i] := FHead;
    FLevel := lvl;
  end;
  n := TVDbSkipNode.Create;
  n.Entry := e;
  SetLength(n.Next, lvl + 1);
  for i := 0 to lvl do
  begin
    n.Next[i] := upd[i].Next[i];
    upd[i].Next[i] := n;
  end;
  Inc(FCount);
  Result := True;
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
    if upd[i].Next[i] = n then
      upd[i].Next[i] := n.Next[i];
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
