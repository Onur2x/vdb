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
  - SILME YENIDEN DENGELENIR (v4.1): silme yolunda her ust dugum, cocugu
    minimum dolulugun altina dustuyse once kardesten anahtar ODUNC ALIR
    (rotate), kardes de doluysa ayiriciyi asagi indirip dugumleri BIRLESTIRIR
    (merge). Yaprak birlestirmesi Next/Prev zincirini yerinde onarir.
    Kok tek cocuga indiginde agac cokertilir. Sonuc: bos veya az dolu
    dugum agacta KALMAZ (kok haric); derinlik ve doluluk sinirlidir.
    Onceden silme hic yeniden dengelenmiyordu: bos/az dolu yapraklar
    agacta kaliyor, yaprak sayisi ve derinlik gereksiz buyuyordu.
  - Minimum doluluk: yaprakta FMaxKeys div 2, ic dugumde
    (FMaxKeys-1) div 2 anahtar. Birlestirme bu sinirlarla tasmaz
    (yaprak: 2*(K div 2) <= K; ic: 2*((K-1) div 2)+1 <= K).
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
    Next: TVDbBTreeNode;                // yaprak zinciri (ileri)
    Prev: TVDbBTreeNode;                // yaprak zinciri (geri; birlestirme icin)
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
    function MinKeysOf(N: TVDbBTreeNode): Integer;
    procedure RebalanceChild(P: TVDbBTreeNode; Idx: Integer);
    procedure BorrowLeft(P: TVDbBTreeNode; Idx: Integer);
    procedure BorrowRight(P: TVDbBTreeNode; Idx: Integer);
    procedure MergeAt(P: TVDbBTreeNode; Idx: Integer);
    function GetHeight: Integer;
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
    { Tanilama olcumleri (kapi icin): agac yuksekligi ve yaprak sayisi. }
    function LeafCount: Integer;
    property Count: Int64 read FCount;
    property MaxKeys: Integer read FMaxKeys;
    property Height: Integer read GetHeight;
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
      if nr.Next <> nil then nr.Next.Prev := nr;
      nr.Prev := N;
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
  nr: TVDbBTreeNode;
begin
  e.Key := Key;
  e.Value := Value;
  e.Cov := '';
  Result := DeleteRec(FRoot, e);
  if not Result then Exit;
  Dec(FCount);
  { Kok artik ayirici tasimiyorsa (tek cocuk kaldiysa) agac cokertilir:
    yukseklik ve "kok haric minimum doluluk" kurali korunur. }
  while (FRoot <> nil) and (not FRoot.IsLeaf) and
        (Length(FRoot.Entries) = 0) do
  begin
    nr := FRoot.Children[0];
    FRoot.Children[0] := nil;
    SetLength(FRoot.Children, 0);
    FRoot.Free;
    FRoot := nr;
  end;
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
    { Son hucrenin string referanslari temizlenir (dizi kisaltilirken
      kalan slot sizmasin). }
    if Length(N.Entries) > 0 then
    begin
      N.Entries[High(N.Entries)].Key := '';
      N.Entries[High(N.Entries)].Value := '';
      N.Entries[High(N.Entries)].Cov := '';
    end;
    SetLength(N.Entries, Length(N.Entries) - 1);
    Dec(N.SubCount);
    Exit(True);
  end;
  pos := ChildPos(N, E);
  Result := DeleteRec(N.Children[pos], E);
  if Result then
  begin
    Dec(N.SubCount);
    RebalanceChild(N, pos);
  end;
end;

function TVDbBTree.MinKeysOf(N: TVDbBTreeNode): Integer;
begin
  if N = nil then Exit(0);
  if N.IsLeaf then Result := FMaxKeys div 2
  else Result := (FMaxKeys - 1) div 2;
  { Cok kucuk FMaxKeys'te (4) formul 1'in altina dusmez ama savunma
    amacli taban konur: minimum 1 anahtar. }
  if Result < 1 then Result := 1;
end;

procedure TVDbBTree.RebalanceChild(P: TVDbBTreeNode; Idx: Integer);
var
  C, L, R: TVDbBTreeNode;
  mn: Integer;
begin
  if (P = nil) or (Idx < 0) or (Idx > High(P.Children)) then Exit;
  C := P.Children[Idx];
  if C = nil then Exit;
  mn := MinKeysOf(C);
  if Length(C.Entries) >= mn then Exit;
  { 1) Once kardesten odunc al (rotate); dugum sayisi degismez. }
  if Idx > 0 then
  begin
    L := P.Children[Idx - 1];
    if Length(L.Entries) > MinKeysOf(L) then
    begin
      BorrowLeft(P, Idx);
      Exit;
    end;
  end;
  if Idx < High(P.Children) then
  begin
    R := P.Children[Idx + 1];
    if Length(R.Entries) > MinKeysOf(R) then
    begin
      BorrowRight(P, Idx);
      Exit;
    end;
  end;
  { 2) Kardesler de doluysa ayiriciyi asagi indirip birlestir. }
  if Idx > 0 then MergeAt(P, Idx - 1)
  else MergeAt(P, Idx);
end;

procedure TVDbBTree.BorrowLeft(P: TVDbBTreeNode; Idx: Integer);
var
  C, S: TVDbBTreeNode;
  e: TVDbSkipEntry;
  sc: TVDbBTreeNode;
  i: Integer;
begin
  C := P.Children[Idx];
  S := P.Children[Idx - 1];
  if C.IsLeaf then
  begin
    e := S.Entries[High(S.Entries)];
    S.Entries[High(S.Entries)].Key := '';
    S.Entries[High(S.Entries)].Value := '';
    S.Entries[High(S.Entries)].Cov := '';
    SetLength(S.Entries, Length(S.Entries) - 1);
    SetLength(C.Entries, Length(C.Entries) + 1);
    for i := High(C.Entries) downto 1 do
      C.Entries[i] := C.Entries[i - 1];
    C.Entries[0] := e;
    P.Entries[Idx - 1] := C.Entries[0];
    S.SubCount := Length(S.Entries);
    C.SubCount := Length(C.Entries);
    Exit;
  end;
  { Ic dugum: ayirici asagi iner, kardesin son cocugu buraya tasinir. }
  e := S.Entries[High(S.Entries)];
  S.Entries[High(S.Entries)].Key := '';
  S.Entries[High(S.Entries)].Value := '';
  S.Entries[High(S.Entries)].Cov := '';
  SetLength(S.Entries, Length(S.Entries) - 1);
  sc := S.Children[High(S.Children)];
  S.Children[High(S.Children)] := nil;
  SetLength(S.Children, Length(S.Children) - 1);
  SetLength(C.Entries, Length(C.Entries) + 1);
  for i := High(C.Entries) downto 1 do
    C.Entries[i] := C.Entries[i - 1];
  C.Entries[0] := P.Entries[Idx - 1];
  SetLength(C.Children, Length(C.Children) + 1);
  for i := High(C.Children) downto 1 do
    C.Children[i] := C.Children[i - 1];
  C.Children[0] := sc;
  P.Entries[Idx - 1] := e;
  Inc(C.SubCount, sc.SubCount);
  Dec(S.SubCount, sc.SubCount);
end;

procedure TVDbBTree.BorrowRight(P: TVDbBTreeNode; Idx: Integer);
var
  C, S: TVDbBTreeNode;
  e: TVDbSkipEntry;
  sc: TVDbBTreeNode;
  i: Integer;
begin
  C := P.Children[Idx];
  S := P.Children[Idx + 1];
  if C.IsLeaf then
  begin
    e := S.Entries[0];
    for i := 0 to High(S.Entries) - 1 do
      S.Entries[i] := S.Entries[i + 1];
    S.Entries[High(S.Entries)].Key := '';
    S.Entries[High(S.Entries)].Value := '';
    S.Entries[High(S.Entries)].Cov := '';
    SetLength(S.Entries, Length(S.Entries) - 1);
    SetLength(C.Entries, Length(C.Entries) + 1);
    C.Entries[High(C.Entries)] := e;
    P.Entries[Idx] := S.Entries[0];
    S.SubCount := Length(S.Entries);
    C.SubCount := Length(C.Entries);
    Exit;
  end;
  { Ic dugum: kardesin ilk cocugu buraya, ayirici yukari cikar. }
  e := P.Entries[Idx];
  sc := S.Children[0];
  for i := 0 to High(S.Children) - 1 do
    S.Children[i] := S.Children[i + 1];
  S.Children[High(S.Children)] := nil;
  SetLength(S.Children, Length(S.Children) - 1);
  P.Entries[Idx] := S.Entries[0];
  for i := 0 to High(S.Entries) - 1 do
    S.Entries[i] := S.Entries[i + 1];
  S.Entries[High(S.Entries)].Key := '';
  S.Entries[High(S.Entries)].Value := '';
  S.Entries[High(S.Entries)].Cov := '';
  SetLength(S.Entries, Length(S.Entries) - 1);
  SetLength(C.Entries, Length(C.Entries) + 1);
  C.Entries[High(C.Entries)] := e;
  SetLength(C.Children, Length(C.Children) + 1);
  C.Children[High(C.Children)] := sc;
  Inc(C.SubCount, sc.SubCount);
  Dec(S.SubCount, sc.SubCount);
end;

procedure TVDbBTree.MergeAt(P: TVDbBTreeNode; Idx: Integer);
var
  L, R: TVDbBTreeNode;
  i, nL, nR: Integer;
begin
  if (P = nil) or (Idx < 0) or (Idx + 1 > High(P.Children)) then Exit;
  L := P.Children[Idx];
  R := P.Children[Idx + 1];
  nL := Length(L.Entries);
  nR := Length(R.Entries);
  if L.IsLeaf then
  begin
    SetLength(L.Entries, nL + nR);
    for i := 0 to nR - 1 do
      L.Entries[nL + i] := R.Entries[i];
    L.SubCount := L.SubCount + R.SubCount;
    SetLength(R.Entries, 0);
    { Yaprak zinciri yerinde onarilir: R cikar, Prev baglantisi tazelenir. }
    L.Next := R.Next;
    if R.Next <> nil then R.Next.Prev := L;
    R.Next := nil;
    R.Prev := nil;
    R.Free;
  end
  else
  begin
    { Ic dugum: L + ayirici + R anahtarlari. Birlestirme tasmaz:
      2*((K-1) div 2) + 1 <= K. }
    SetLength(L.Entries, nL + 1 + nR);
    L.Entries[nL] := P.Entries[Idx];
    for i := 0 to nR - 1 do
      L.Entries[nL + 1 + i] := R.Entries[i];
    SetLength(R.Entries, 0);
    nR := Length(R.Children);
    nL := Length(L.Children);
    SetLength(L.Children, nL + nR);
    for i := 0 to nR - 1 do
      L.Children[nL + i] := R.Children[i];
    SetLength(R.Children, 0);
    L.SubCount := L.SubCount + R.SubCount;
    R.Free;
  end;
  { Ayirici ve sag cocuk ust dugumden cikarilir. }
  for i := Idx to High(P.Entries) - 1 do
    P.Entries[i] := P.Entries[i + 1];
  if Length(P.Entries) > 0 then
  begin
    P.Entries[High(P.Entries)].Key := '';
    P.Entries[High(P.Entries)].Value := '';
    P.Entries[High(P.Entries)].Cov := '';
  end;
  SetLength(P.Entries, Length(P.Entries) - 1);
  for i := Idx + 1 to High(P.Children) - 1 do
    P.Children[i] := P.Children[i + 1];
  P.Children[High(P.Children)] := nil;
  SetLength(P.Children, Length(P.Children) - 1);
end;

function TVDbBTree.GetHeight: Integer;
var
  n: TVDbBTreeNode;
begin
  Result := 0;
  n := FRoot;
  while n <> nil do
  begin
    Inc(Result);
    if n.IsLeaf then Break;
    n := n.Children[0];
  end;
end;

function TVDbBTree.LeafCount: Integer;
var
  n: TVDbBTreeNode;
begin
  Result := 0;
  n := LeftmostLeaf;
  while n <> nil do
  begin
    Inc(Result);
    n := n.Next;
  end;
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
    Result := Default(TVDbSkipEntry);
    Exit;
  end;
  Result := x.Entries[0];
end;

procedure TVDbBTree.LoadSorted(const Arr: TVDbSkipEntryArray);
var
  cur, nxt: array of TVDbBTreeNode;
  leaf, prev, nd: TVDbBTreeNode;
  i, j, k, cnt, total, nLeaf, base, rem, nn, c: Integer;
  sp: TVDbSkipEntry;
begin
  Clear;
  total := Length(Arr);
  if total = 0 then Exit;
  SetLength(cur, 0);
  { Yapraklar ESIT dagitilir: son yaprak "artik" olup minimumun altina
    dusmez; boylece yukleme sonrasi agac da silme sonrasiyla ayni doluluk
    sozlesmesini saglar. }
  nLeaf := (total + FMaxKeys - 1) div FMaxKeys;
  if nLeaf < 1 then nLeaf := 1;
  i := 0;
  prev := nil;
  for k := 0 to nLeaf - 1 do
  begin
    cnt := total div nLeaf;
    if k < (total mod nLeaf) then Inc(cnt);
    leaf := TVDbBTreeNode.Create;
    leaf.IsLeaf := True;
    SetLength(leaf.Entries, cnt);
    for j := 0 to cnt - 1 do
      leaf.Entries[j] := Arr[i + j];
    leaf.SubCount := cnt;
    if prev <> nil then
    begin
      prev.Next := leaf;
      leaf.Prev := prev;
    end;
    prev := leaf;
    SetLength(cur, Length(cur) + 1);
    cur[High(cur)] := leaf;
    Inc(i, cnt);
  end;
  // ust seviyeler
  while Length(cur) > 1 do
  begin
    c := Length(cur);
    { Dugum basina cocuk sayisi esit dagitilir; son dugum eksik cocuklu
      kalmaz. nn = ceil(c / (K+1)). }
    nn := (c + FMaxKeys) div (FMaxKeys + 1);
    if nn < 1 then nn := 1;
    SetLength(nxt, 0);
    i := 0;
    for k := 0 to nn - 1 do
    begin
      cnt := c div nn;
      if k < (c mod nn) then Inc(cnt);
      if cnt < 2 then cnt := 2;   // savunma: ic dugum en az 2 cocuk
      if i + cnt > c then cnt := c - i;
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
      base := 0;
      for j := 0 to cnt - 1 do
        Inc(base, nd.Children[j].SubCount);
      nd.SubCount := base;
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
    while (x <> nil) and (not x.IsLeaf) do
      x := x.Children[0];
    if (x = nil) or (Length(x.Entries) = 0) then
      Exit(Default(TVDbSkipEntry));
    Result := x.Entries[0];
  end;

  function MaxOf(N: TVDbBTreeNode): TVDbSkipEntry;
  var
    x: TVDbBTreeNode;
  begin
    x := N;
    while (x <> nil) and (not x.IsLeaf) do
      x := x.Children[High(x.Children)];
    if (x = nil) or (Length(x.Entries) = 0) then
      Exit(Default(TVDbSkipEntry));
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
      { Kok disinda bos yaprak KALMAZ (silme yeniden dengelenir). }
      if (Length(N.Entries) = 0) and (N <> FRoot) then
        Exit('bos yaprak dugum');
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

  { Minimum doluluk: kok haric her dugum MinKeysOf kadar anahtar tasir.
    Bu, silme sonrasi bos/az dolu dugum kalmadiginin dogrudan kanitidir. }
  function MinWalk(N: TVDbBTreeNode; IsRoot: Boolean): string;
  var
    i, need: Integer;
  begin
    Result := '';
    if N = nil then Exit('nil dugum');
    if not IsRoot then
    begin
      need := MinKeysOf(N);
      if Length(N.Entries) < need then
        Exit(Format('minimum doluluk ihlali: %d < %d',
          [Length(N.Entries), need]));
    end;
    if not N.IsLeaf then
    begin
      if Length(N.Children) < 2 then
        Exit(Format('ic dugumde %d cocuk (en az 2 olmali)',
          [Length(N.Children)]));
      for i := 0 to High(N.Children) do
      begin
        Result := MinWalk(N.Children[i], False);
        if Result <> '' then
        begin
          Result := Format('cocuk %d: %s', [i, Result]);
          Exit;
        end;
      end;
    end;
  end;

var
  n, prevN: TVDbBTreeNode;
  i, cnt: Integer;
begin
  Result := Walk(FRoot);
  if Result <> '' then Exit;
  Result := MinWalk(FRoot, True);
  if Result <> '' then Exit;
  // yaprak zinciri: Prev/Next tutarliligi + global sira + sayi
  cnt := 0;
  prevN := nil;
  n := LeftmostLeaf;
  while n <> nil do
  begin
    if not n.IsLeaf then Exit('yaprak zincirinde ic dugum');
    if n.Prev <> prevN then Exit('yaprak zinciri Prev baglantisi bozuk');
    if (prevN <> nil) and (Length(prevN.Entries) > 0) and
       (Length(n.Entries) > 0) then
      if Cmp(prevN.Entries[High(prevN.Entries)], n.Entries[0]) >= 0 then
        Exit('yaprak zinciri sirasi bozuk');
    Inc(cnt, Length(n.Entries));
    prevN := n;
    n := n.Next;
  end;
  if Int64(cnt) <> FCount then
    Exit(Format('zincirde %d girdi, FCount %d', [cnt, FCount]));
end;

end.
