{ v4: bellekte sirali indeks — B+tree.

  Amac: motorun sirali indeksini (TIdxSkip) skiplist yerine gercek bir
  B+tree ile beslemek. Sozlesme TVDbSkipList ile AYNIDIR (ayni metot
  imzalari, ayni karsilastirici tipleri), yani TIdxSkip icin damla yerine
  gecerlidir.

  Tasarim (bilincli olarak sade, veri kaybi riski dusuk):
  - Yaprak dugumler Entries[] dizisinde FULL sirada tutulur; yapraklar
    Next ile baglidir (aralik taramasi icin).
  - Ic dugumler Entries[i] = sag cocugun (Children[i+1]) ALT SINIR anahtari.
  - Ekleme: yaprak bolunmesi + ust dugum bolunmesi, kok bolunmesi.
  - SILME YENIDEN DENGELENMEZ: girdi yapraktan cikarilir, dugum birlestirme
    veya anahtar odunc alma YAPILMAZ. Bos yaprak agacta kalir (taramada
    atlanir). Bu, B+tree arama degismezlerini bozmaz: ayirici anahtar
    "sag alt agacin alt siniri" olarak GECERLI kalir (silinen anahtar
    yalnizca alt siniri asagi ceker, yukari cekmez), cunku arama
    "E >= ayirici -> saga" kuralini kullanir ve yapraklar zincirle baglidir.
    Ayni davranis, gercek uygulamalarda "lazy delete" olarak bilinir.
  - SubCount: her dugumde alt agactaki girdi sayisi; RankBefore/CountRange
    O(log N) kalir.

  Es anlamli (ayni Key, farkli Value/Pk) girdiler FullCompare ile toplam
  sirada durur; aralik sinirlari yalniz anahtar karsilastiricisi (LeadCompare)
  ile olculur — skiplist ile birebir ayni sozlesme. }
unit VDbBTree;

{$mode delphi}{$H+}

interface

uses
  SysUtils, VDbSkipList;

type
  TVDbBTreeNode = class
  public
    IsLeaf: Boolean;
    Entries: TVDbSkipEntryArray;        // yaprak: girdiler; ic: ayiricilar
    Children: array of TVDbBTreeNode;   // yalniz ic dugum
    Next: TVDbBTreeNode;                // yaprak zinciri
    SubCount: Int64;                    // alt agactaki girdi sayisi
  end;

  TVDbBTree = class
  private
    FRoot: TVDbBTreeNode;
    FMaxKeys: Integer;
    FCount: Int64;
    FCompare: TVDbSkipCompare;
    function Cmp(const A, B: TVDbSkipEntry): Integer;
    function KeyCmp(const A, B: string): Integer;
    function LeafPos(N: TVDbBTreeNode; const E: TVDbSkipEntry;
      out Found: Boolean): Integer;
    function ChildPos(N: TVDbBTreeNode; const E: TVDbSkipEntry): Integer;
    function InsertRec(N: TVDbBTreeNode; const E: TVDbSkipEntry;
      out SplitEntry: TVDbSkipEntry; out RightNode: TVDbBTreeNode): Boolean;
    function DeleteRec(N: TVDbBTreeNode; const E: TVDbSkipEntry): Boolean;
    function LeftmostLeaf: TVDbBTreeNode;
    function SeekLeaf(const Key: string; ACompare: TVDbSkipKeyCompare;
      LoInc: Boolean): TVDbBTreeNode;
    function SeekLeafAt(const Key: string; ACompare: TVDbSkipKeyCompare;
      LoInc: Boolean; out Pos: Integer): TVDbBTreeNode;
    function MinEntry(N: TVDbBTreeNode): TVDbSkipEntry;
    procedure FreeTree(N: TVDbBTreeNode);
  public
    constructor Create(AMaxKeys: Integer = 96); overload;
    constructor Create(ACompare: TVDbSkipCompare; AMaxKeys: Integer = 96); overload;
    destructor Destroy; override;
    procedure Clear;
    { Ayni Key+Value zaten varsa False doner. }
    function Insert(const Key, Value: string; const Cov: string = ''): Boolean; overload;
    function Insert(const E: TVDbSkipEntry): Boolean; overload;
    function Delete(const Key, Value: string): Boolean;
    { Sirali girdi dizisini O(N) yukler. }
    procedure LoadSorted(const Arr: TVDbSkipEntryArray);
    function LowerBound(const Key: string; out E: TVDbSkipEntry): Boolean;
    function Find(const Key: string; out Value: string): Boolean;
    { LoKey <= Key <= HiKey }
    function Range(const LoKey, HiKey: string;
      out Arr: TVDbSkipEntryArray): Integer;
    function CollectRange(const LoKey, HiKey: string;
      HasLo, HasHi, LoInc, HiInc: Boolean; ACompare: TVDbSkipKeyCompare;
      out Arr: TVDbSkipEntryArray): Integer;
    function CountRange(const LoKey, HiKey: string;
      HasLo, HasHi, LoInc, HiInc: Boolean;
      ACompare: TVDbSkipKeyCompare): Int64;
    function RankBefore(const Key: string; ACompare: TVDbSkipKeyCompare;
      IncludeEqual: Boolean): Int64;
    function All(out Arr: TVDbSkipEntryArray): Integer;
    { Yapi degismezlerini dogrular; '' = sorun yok. Kapi/test icin. }
    function CheckInvariants: string;
    property Count: Int64 read FCount;
    property MaxKeys: Integer read FMaxKeys;
  end;

implementation

constructor TVDbBTree.Create(AMaxKeys: Integer);
begin
  Create(nil, AMaxKeys);
end;

constructor TVDbBTree.Create(ACompare: TVDbSkipCompare; AMaxKeys: Integer);
begin
  inherited Create;
  if AMaxKeys < 4 then AMaxKeys := 4;
  if AMaxKeys > 1024 then AMaxKeys := 1024;
  FMaxKeys := AMaxKeys;
  FCompare := ACompare;
  FCount := 0;
  FRoot := TVDbBTreeNode.Create;
  FRoot.IsLeaf := True;
  FRoot.SubCount := 0;
end;

destructor TVDbBTree.Destroy;
begin
  FreeTree(FRoot);
  FRoot := nil;
  inherited Destroy;
end;

procedure TVDbBTree.FreeTree(N: TVDbBTreeNode);
var
  i: Integer;
begin
  if N = nil then Exit;
  if not N.IsLeaf then
    for i := 0 to High(N.Children) do
      FreeTree(N.Children[i]);
  N.Free;
end;

procedure TVDbBTree.Clear;
begin
  FreeTree(FRoot);
  FRoot := TVDbBTreeNode.Create;
  FRoot.IsLeaf := True;
  FRoot.SubCount := 0;
  FCount := 0;
end;

function TVDbBTree.Cmp(const A, B: TVDbSkipEntry): Integer;
begin
  if Assigned(FCompare) then Result := FCompare(A, B)
  else
  begin
    Result := CompareStr(A.Key, B.Key);
    if Result = 0 then Result := CompareStr(A.Value, B.Value);
  end;
end;

function TVDbBTree.KeyCmp(const A, B: string): Integer;
begin
  Result := CompareStr(A, B);
end;

function TVDbBTree.LeafPos(N: TVDbBTreeNode; const E: TVDbSkipEntry;
  out Found: Boolean): Integer;
var
  lo, hi, mid: Integer;
begin
  lo := 0;
  hi := Length(N.Entries);
  while lo < hi do
  begin
    mid := (lo + hi) div 2;
    if Cmp(N.Entries[mid], E) < 0 then lo := mid + 1
    else hi := mid;
  end;
  Result := lo;
  Found := (lo < Length(N.Entries)) and (Cmp(N.Entries[lo], E) = 0);
end;

function TVDbBTree.ChildPos(N: TVDbBTreeNode; const E: TVDbSkipEntry): Integer;
var
  lo, hi, mid: Integer;
begin
  lo := 0;
  hi := Length(N.Entries);
  while lo < hi do
  begin
    mid := (lo + hi) div 2;
    if Cmp(N.Entries[mid], E) <= 0 then lo := mid + 1
    else hi := mid;
  end;
  Result := lo;
end;

function TVDbBTree.Insert(const Key, Value: string; const Cov: string): Boolean;
var
  e: TVDbSkipEntry;
begin
  e.Key := Key;
  e.Value := Value;
  e.Cov := Cov;
  Result := Insert(e);
end;

function TVDbBTree.Insert(const E: TVDbSkipEntry): Boolean;
var
  sp: TVDbSkipEntry;
  right, newRoot: TVDbBTreeNode;
begin
  Result := InsertRec(FRoot, E, sp, right);
  if not Result then Exit;
  Inc(FCount);
  if right <> nil then
  begin
    newRoot := TVDbBTreeNode.Create;
    newRoot.IsLeaf := False;
    SetLength(newRoot.Entries, 1);
    newRoot.Entries[0] := sp;
    SetLength(newRoot.Children, 2);
    newRoot.Children[0] := FRoot;
    newRoot.Children[1] := right;
    newRoot.SubCount := FRoot.SubCount + right.SubCount;
    FRoot := newRoot;
  end;
end;

function TVDbBTree.InsertRec(N: TVDbBTreeNode; const E: TVDbSkipEntry;
  out SplitEntry: TVDbSkipEntry; out RightNode: TVDbBTreeNode): Boolean;
var
  pos, cnt, mid, i: Integer;
  found: Boolean;
  nr: TVDbBTreeNode;
  sp: TVDbSkipEntry;
  sub: Int64;
begin
  Result := False;
  RightNode := nil;
  if N.IsLeaf then
  begin
    pos := LeafPos(N, E, found);
    if found then Exit;   // ayni Key+Value
    cnt := Length(N.Entries);
    SetLength(N.Entries, cnt + 1);
    for i := cnt downto pos + 1 do
      N.Entries[i] := N.Entries[i - 1];
    N.Entries[pos] := E;
    Inc(N.SubCount);
    Result := True;
    if Length(N.Entries) > FMaxKeys then
    begin
      mid := Length(N.Entries) div 2;
      nr := TVDbBTreeNode.Create;
      nr.IsLeaf := True;
      SetLength(nr.Entries, Length(N.Entries) - mid);
      for i := mid to High(N.Entries) do
        nr.Entries[i - mid] := N.Entries[i];
      nr.SubCount := Length(nr.Entries);
      SplitEntry := nr.Entries[0];
      RightNode := nr;
      for i := High(N.Entries) downto mid do
        N.Entries[i].Key := '';      // refcount: SetLength asagida birakir
      SetLength(N.Entries, mid);
      N.SubCount := mid;
      nr.Next := N.Next;
      N.Next := nr;
    end;
    Exit;
  end;
  pos := ChildPos(N, E);
  if not InsertRec(N.Children[pos], E, sp, nr) then Exit(False);
  Inc(N.SubCount);
  Result := True;
  if nr = nil then Exit;
  // ayiriciyi ve yeni cocugu ekle
  cnt := Length(N.Entries);
  SetLength(N.Entries, cnt + 1);
  for i := cnt downto pos + 1 do
    N.Entries[i] := N.Entries[i - 1];
  N.Entries[pos] := sp;
  cnt := Length(N.Children);
  SetLength(N.Children, cnt + 1);
  for i := cnt - 1 downto pos + 1 do
    N.Children[i + 1] := N.Children[i];
  N.Children[pos + 1] := nr;
  RightNode := nil;
  if Length(N.Entries) > FMaxKeys then
  begin
    mid := Length(N.Entries) div 2;
    SplitEntry := N.Entries[mid];
    nr := TVDbBTreeNode.Create;
    nr.IsLeaf := False;
    SetLength(nr.Entries, Length(N.Entries) - mid - 1);
    for i := mid + 1 to High(N.Entries) do
      nr.Entries[i - mid - 1] := N.Entries[i];
    for i := High(N.Entries) downto mid do
    begin
      N.Entries[i].Key := '';
      N.Entries[i].Value := '';
      N.Entries[i].Cov := '';
    end;
    SetLength(N.Entries, mid);
    SetLength(nr.Children, Length(N.Children) - mid - 1);
    for i := mid + 1 to High(N.Children) do
      nr.Children[i - mid - 1] := N.Children[i];
    for i := High(N.Children) downto mid + 1 do
      N.Children[i] := nil;
    SetLength(N.Children, mid + 1);
    sub := 0;
    for i := 0 to High(nr.Children) do
      Inc(sub, nr.Children[i].SubCount);
    nr.SubCount := sub;
    Dec(N.SubCount, sub);
    RightNode := nr;
  end;
end;

function TVDbBTree.Delete(const Key, Value: string): Boolean;
var
  e: TVDbSkipEntry;
begin
  e.Key := Key;
  e.Value := Value;
  e.Cov := '';
  Result := DeleteRec(FRoot, e);
  if Result then Dec(FCount);
end;

function TVDbBTree.DeleteRec(N: TVDbBTreeNode; const E: TVDbSkipEntry): Boolean;
var
  pos, i: Integer;
  found: Boolean;
begin
  if N.IsLeaf then
  begin
    pos := LeafPos(N, E, found);
    if not found then Exit(False);
    for i := pos to High(N.Entries) - 1 do
      N.Entries[i] := N.Entries[i + 1];
    SetLength(N.Entries, Length(N.Entries) - 1);
    Dec(N.SubCount);
    Exit(True);
  end;
  pos := ChildPos(N, E);
  Result := DeleteRec(N.Children[pos], E);
  if Result then Dec(N.SubCount);
end;

function TVDbBTree.LeftmostLeaf: TVDbBTreeNode;
begin
  Result := FRoot;
  while (Result <> nil) and (not Result.IsLeaf) do
    Result := Result.Children[0];
end;

function TVDbBTree.SeekLeaf(const Key: string; ACompare: TVDbSkipKeyCompare;
  LoInc: Boolean): TVDbBTreeNode;
var
  lo, hi, mid: Integer;
  c: Integer;
begin
  Result := FRoot;
  while (Result <> nil) and (not Result.IsLeaf) do
  begin
    lo := 0;
    hi := Length(Result.Entries);
    while lo < hi do
    begin
      mid := (lo + hi) div 2;
      c := ACompare(Result.Entries[mid].Key, Key);
      if (c < 0) or ((c = 0) and (not LoInc)) then lo := mid + 1
      else hi := mid;
    end;
    Result := Result.Children[lo];
  end;
end;

function TVDbBTree.SeekLeafAt(const Key: string; ACompare: TVDbSkipKeyCompare;
  LoInc: Boolean; out Pos: Integer): TVDbBTreeNode;
var
  lo, hi, mid: Integer;
  c: Integer;
begin
  Result := FRoot;
  while (Result <> nil) and (not Result.IsLeaf) do
  begin
    lo := 0;
    hi := Length(Result.Entries);
    while lo < hi do
    begin
      mid := (lo + hi) div 2;
      c := ACompare(Result.Entries[mid].Key, Key);
      if (c < 0) or ((c = 0) and (not LoInc)) then lo := mid + 1
      else hi := mid;
    end;
    Result := Result.Children[lo];
  end;
  Pos := 0;
  if (Result = nil) or (not Result.IsLeaf) then Exit;
  lo := 0;
  hi := Length(Result.Entries);
  while lo < hi do
  begin
    mid := (lo + hi) div 2;
    c := ACompare(Result.Entries[mid].Key, Key);
    if (c < 0) or ((c = 0) and (not LoInc)) then lo := mid + 1
    else hi := mid;
  end;
  Pos := lo;
end;

function TVDbBTree.MinEntry(N: TVDbBTreeNode): TVDbSkipEntry;
var
  x: TVDbBTreeNode;
begin
  x := N;
  while (x <> nil) and (not x.IsLeaf) do
    x := x.Children[0];
  if (x = nil) or (Length(x.Entries) = 0) then
  begin
    FillChar(Result, SizeOf(Result), 0);
    Exit;
  end;
  Result := x.Entries[0];
end;

procedure TVDbBTree.LoadSorted(const Arr: TVDbSkipEntryArray);
var
  cur, nxt: array of TVDbBTreeNode;
  leaf, prev, nd: TVDbBTreeNode;
  i, j, k, cnt, total: Integer;
  sp: TVDbSkipEntry;
begin
  Clear;
  total := Length(Arr);
  if total = 0 then Exit;
  SetLength(cur, 0);
  i := 0;
  prev := nil;
  while i < total do
  begin
    cnt := total - i;
    if cnt > FMaxKeys then cnt := FMaxKeys;
    leaf := TVDbBTreeNode.Create;
    leaf.IsLeaf := True;
    SetLength(leaf.Entries, cnt);
    for j := 0 to cnt - 1 do
      leaf.Entries[j] := Arr[i + j];
    leaf.SubCount := cnt;
    if prev <> nil then prev.Next := leaf;
    prev := leaf;
    SetLength(cur, Length(cur) + 1);
    cur[High(cur)] := leaf;
    Inc(i, cnt);
  end;
  // ust seviyeler
  while Length(cur) > 1 do
  begin
    SetLength(nxt, 0);
    i := 0;
    while i <= High(cur) do
    begin
      cnt := High(cur) - i + 1;
      if cnt > FMaxKeys + 1 then cnt := FMaxKeys + 1;   // cocuk sayisi
      nd := TVDbBTreeNode.Create;
      nd.IsLeaf := False;
      SetLength(nd.Children, cnt);
      for j := 0 to cnt - 1 do
        nd.Children[j] := cur[i + j];
      SetLength(nd.Entries, cnt - 1);
      for j := 1 to cnt - 1 do
      begin
        sp := MinEntry(nd.Children[j]);
        nd.Entries[j - 1] := sp;
      end;
      k := 0;
      for j := 0 to cnt - 1 do
        Inc(k, nd.Children[j].SubCount);
      nd.SubCount := k;
      SetLength(nxt, Length(nxt) + 1);
      nxt[High(nxt)] := nd;
      Inc(i, cnt);
    end;
    cur := nxt;
  end;
  FreeTree(FRoot);
  FRoot := cur[0];
  FCount := total;
end;

function TVDbBTree.All(out Arr: TVDbSkipEntryArray): Integer;
var
  n: TVDbBTreeNode;
  i: Integer;
begin
  SetLength(Arr, FCount);
  Result := 0;
  n := LeftmostLeaf;
  while n <> nil do
  begin
    for i := 0 to High(n.Entries) do
    begin
      Arr[Result] := n.Entries[i];
      Inc(Result);
    end;
    n := n.Next;
  end;
  SetLength(Arr, Result);
end;

function TVDbBTree.LowerBound(const Key: string; out E: TVDbSkipEntry): Boolean;
var
  n: TVDbBTreeNode;
  i: Integer;
begin
  n := SeekLeaf(Key, KeyCmp, True);
  while n <> nil do
  begin
    for i := 0 to High(n.Entries) do
      if CompareStr(n.Entries[i].Key, Key) >= 0 then
      begin
        E := n.Entries[i];
        Exit(True);
      end;
    n := n.Next;
  end;
  Result := False;
end;

function TVDbBTree.Find(const Key: string; out Value: string): Boolean;
var
  E: TVDbSkipEntry;
begin
  Result := LowerBound(Key, E) and (E.Key = Key);
  if Result then Value := E.Value;
end;

function TVDbBTree.Range(const LoKey, HiKey: string;
  out Arr: TVDbSkipEntryArray): Integer;
begin
  Result := CollectRange(LoKey, HiKey, True, True, True, True, KeyCmp, Arr);
end;

function TVDbBTree.CollectRange(const LoKey, HiKey: string;
  HasLo, HasHi, LoInc, HiInc: Boolean; ACompare: TVDbSkipKeyCompare;
  out Arr: TVDbSkipEntryArray): Integer;
var
  n: TVDbBTreeNode;
  i, c, cap, pos: Integer;
  done: Boolean;
begin
  SetLength(Arr, 0);
  Result := 0;
  if FRoot = nil then Exit;
  if HasLo then
    n := SeekLeafAt(LoKey, ACompare, LoInc, pos)
  else
  begin
    n := LeftmostLeaf;
    pos := 0;
  end;
  cap := 0;
  done := False;
  while (n <> nil) and (not done) do
  begin
    // ilk yaprakta HasLo zaten saglandi (Pos'e kadar atlandi); sonraki
    // yapraklarin tamami alt sinirin ustunde.
    for i := pos to High(n.Entries) do
    begin
      if HasHi then
      begin
        c := ACompare(n.Entries[i].Key, HiKey);
        if (c > 0) or ((c = 0) and (not HiInc)) then
        begin
          done := True;
          Break;
        end;
      end;
      if Result >= cap then
      begin
        if cap = 0 then cap := 16
        else cap := cap * 2;
        SetLength(Arr, cap);
      end;
      Arr[Result] := n.Entries[i];
      Inc(Result);
    end;
    pos := 0;
    n := n.Next;
  end;
  SetLength(Arr, Result);
end;

function TVDbBTree.RankBefore(const Key: string;
  ACompare: TVDbSkipKeyCompare; IncludeEqual: Boolean): Int64;
var
  n: TVDbBTreeNode;
  i, c, lo, hi, mid: Integer;
begin
  Result := 0;
  n := FRoot;
  if n = nil then Exit;
  while not n.IsLeaf do
  begin
    lo := 0;
    hi := Length(n.Entries);
    while lo < hi do
    begin
      mid := (lo + hi) div 2;
      c := ACompare(n.Entries[mid].Key, Key);
      if (c < 0) or (IncludeEqual and (c = 0)) then lo := mid + 1
      else hi := mid;
    end;
    for i := 0 to lo - 1 do
      Inc(Result, n.Children[i].SubCount);
    n := n.Children[lo];
  end;
  for i := 0 to High(n.Entries) do
  begin
    c := ACompare(n.Entries[i].Key, Key);
    if (c < 0) or (IncludeEqual and (c = 0)) then Inc(Result)
    else Break;
  end;
end;

function TVDbBTree.CountRange(const LoKey, HiKey: string;
  HasLo, HasHi, LoInc, HiInc: Boolean;
  ACompare: TVDbSkipKeyCompare): Int64;
var
  lo, hi: Int64;
begin
  if HasLo then lo := RankBefore(LoKey, ACompare, not LoInc)
  else lo := 0;
  if HasHi then hi := RankBefore(HiKey, ACompare, HiInc)
  else hi := FCount;
  if hi <= lo then Result := 0
  else Result := hi - lo;
end;

function TVDbBTree.CheckInvariants: string;

  function MinOf(N: TVDbBTreeNode): TVDbSkipEntry;
  var
    x: TVDbBTreeNode;
  begin
    x := N;
    while not x.IsLeaf do
      x := x.Children[0];
    Result := x.Entries[0];
  end;

  function MaxOf(N: TVDbBTreeNode): TVDbSkipEntry;
  var
    x: TVDbBTreeNode;
  begin
    x := N;
    while not x.IsLeaf do
      x := x.Children[High(x.Children)];
    Result := x.Entries[High(x.Entries)];
  end;

  function Walk(N: TVDbBTreeNode): string;
  var
    i, total: Integer;
    mn, mx: TVDbSkipEntry;
  begin
    Result := '';
    if N = nil then Exit('nil dugum');
    if N.IsLeaf then
    begin
      if Int64(Length(N.Entries)) <> N.SubCount then
        Exit(Format('yaprak SubCount %d <> %d', [N.SubCount, Length(N.Entries)]));
      for i := 1 to High(N.Entries) do
        if Cmp(N.Entries[i - 1], N.Entries[i]) >= 0 then
          Exit(Format('yaprak sirasi bozuk (index %d)', [i]));
      Exit;
    end;
    if Length(N.Children) <> Length(N.Entries) + 1 then
      Exit(Format('ic dugum: %d cocuk, %d ayirici',
        [Length(N.Children), Length(N.Entries)]));
    total := 0;
    for i := 0 to High(N.Children) do
    begin
      Result := Walk(N.Children[i]);
      if Result <> '' then
      begin
        Result := Format('cocuk %d: %s', [i, Result]);
        Exit;
      end;
      Inc(total, N.Children[i].SubCount);
      if i > 0 then
      begin
        mn := MinOf(N.Children[i]);
        if Cmp(N.Entries[i - 1], mn) > 0 then
          Exit(Format('ayirici %d sag alt agacin alt sinirindan buyuk', [i - 1]));
        mx := MaxOf(N.Children[i - 1]);
        if Cmp(mx, N.Entries[i - 1]) >= 0 then
          Exit(Format('sol alt agac %d ayiriciya esit/buyuk', [i - 1]));
      end;
    end;
    if Int64(total) <> N.SubCount then
      Exit(Format('ic dugum SubCount %d <> %d', [N.SubCount, total]));
  end;

var
  n: TVDbBTreeNode;
  i, cnt: Integer;
begin
  Result := Walk(FRoot);
  if Result <> '' then Exit;
  // yaprak zinciri: global sira + sayi
  cnt := 0;
  n := LeftmostLeaf;
  while (n <> nil) and (n.Next <> nil) do
  begin
    if Length(n.Entries) > 0 then
      if Cmp(n.Entries[High(n.Entries)], n.Next.Entries[0]) >= 0 then
        Exit('yaprak zinciri sirasi bozuk');
    if n.Next.IsLeaf = False then Exit('yaprak zincirinde ic dugum');
    Inc(cnt, Length(n.Entries));
    n := n.Next;
  end;
  if n <> nil then Inc(cnt, Length(n.Entries));
  if Int64(cnt) <> FCount then
    Exit(Format('zincirde %d girdi, FCount %d', [cnt, FCount]));
end;

end.
