unit VDbVector;
{ M4: vektor yakinlik aramasi.

  Vektorler JSON sayi dizisi olarak saklanir ("[0.1,0.2,...]"). Bu birim
  DB'den bagimsizdir: yalnizca HNSW grafigini ve mesafe fonksiyonlarini
  tutar. SQL tarafi (VDbExecutor) tablo/kolon basina tembel bir indeks
  kurar; veri degisince (DataSeq) yeniden kurar.

  Desteklenen metrikler: l2/euclidean, cosine/cos, l1/manhattan.
  `dot` bilincli olarak yoktur: VECTOR_DISTANCE dot'ta ham ic carpim
  dondurur ve "kucuk olan yakin" varsayimi bozulur.}

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Math, VDbJson, VDbTypes;

type
  TVdbIntVec = array of Integer;
  TVdbIntVec2 = array of TVdbIntVec;

  TVdbVectorIndex = class
  private
    FDim: Integer;
    FMetric: string;
    FM: Integer;
    FEfConstruction: Integer;
    FEfSearch: Integer;
    FIds: TStrArray;
    FVecs: array of TDoubleArray;
    FLevels: TByteArray;
    FLinks: array of TVdbIntVec2;
    FEntry: Integer;
    FMaxLevel: Integer;
    FCount: Integer;
    FRand: QWord;
    FVisitEpoch: Integer;
    FVisited: array of Integer;
    function Dist(const A, B: TDoubleArray): Double;
    function RandomLevel: Integer;
    function Greedy(const Q: TDoubleArray; Ep, Layer: Integer): Integer;
    function SearchLayer(const Q: TDoubleArray; Ep, Ef, Layer: Integer): TVdbIntVec;
    procedure SelectNeighbors(const Cand: TVdbIntVec;
      MaxN: Integer; out Res: TVdbIntVec);
    procedure AddLink(Node, Layer, Other: Integer);
  public
    constructor Create(ADim: Integer; const AMetric: string;
      AM: Integer = 12; AEfConstruction: Integer = 64;
      AEfSearch: Integer = 64);
    procedure Clear;
    procedure Add(const AId: string; const AVec: TDoubleArray);
    { En yakin K kaydi dondurur. Ids/Dists mesafeye gore artan sirali. }
    function Search(const Q: TDoubleArray; K: Integer;
      out Ids: TStrArray; out Dists: TDoubleArray): Boolean;
    property Dim: Integer read FDim;
    property Metric: string read FMetric;
    property Count: Integer read FCount;
  end;

{ JSON sayi dizisini vektore cevirir. }
function VDbVectorParse(const S: string; out V: TDoubleArray): Boolean;
{ Iki vektor arasindaki mesafe. Gecersiz metrik/boyut -> NaN. }
function VDbVectorDistance(const A, B: TDoubleArray; const Metric: string): Double;
{ Metrik adini normalize eder; desteklenmiyorsa '' doner. }
function VDbVectorMetric(const S: string): string;

implementation

function VDbVectorMetric(const S: string): string;
var
  m: string;
begin
  m := LowerCase(Trim(S));
  if (m = '') or (m = 'l2') or (m = 'euclidean') then Exit('l2');
  if (m = 'cosine') or (m = 'cos') then Exit('cosine');
  if (m = 'l1') or (m = 'manhattan') then Exit('l1');
  Result := '';
end;

function VDbVectorParse(const S: string; out V: TDoubleArray): Boolean;
begin
  Result := VDbJsonNumArray(S, V);
end;

function VDbVectorDistance(const A, B: TDoubleArray; const Metric: string): Double;
var
  i: Integer;
  dot, na, nb, s: Double;
  m: string;
begin
  Result := NaN;
  if Length(A) <> Length(B) then Exit;
  if Length(A) = 0 then Exit;
  m := VDbVectorMetric(Metric);
  if m = '' then Exit;
  dot := 0; na := 0; nb := 0; s := 0;
  for i := 0 to High(A) do
  begin
    dot := dot + A[i] * B[i];
    na := na + A[i] * A[i];
    nb := nb + B[i] * B[i];
    s := s + Sqr(A[i] - B[i]);
  end;
  if m = 'cosine' then
  begin
    if (na = 0) or (nb = 0) then Exit;
    Exit(1 - dot / (Sqrt(na) * Sqrt(nb)));
  end;
  if m = 'l1' then
  begin
    s := 0;
    for i := 0 to High(A) do s := s + Abs(A[i] - B[i]);
    Exit(s);
  end;
  Result := Sqrt(s);
end;

{ ---------------------------------------------------------------- HNSW }

constructor TVdbVectorIndex.Create(ADim: Integer; const AMetric: string;
  AM, AEfConstruction, AEfSearch: Integer);
begin
  inherited Create;
  FDim := ADim;
  FMetric := VDbVectorMetric(AMetric);
  if FMetric = '' then FMetric := 'l2';
  FM := Max(4, AM);
  FEfConstruction := Max(FM, AEfConstruction);
  FEfSearch := Max(16, AEfSearch);
  FEntry := -1;
  FMaxLevel := -1;
  FCount := 0;
  FRand := QWord(88172645463325252);
  FVisitEpoch := 0;
end;

procedure TVdbVectorIndex.Clear;
begin
  FIds := nil;
  FVecs := nil;
  FLevels := nil;
  FLinks := nil;
  FVisited := nil;
  FEntry := -1;
  FMaxLevel := -1;
  FCount := 0;
  FVisitEpoch := 0;
end;

function TVdbVectorIndex.Dist(const A, B: TDoubleArray): Double;
var
  i: Integer;
  dot, na, nb, s: Double;
begin
  dot := 0; na := 0; nb := 0; s := 0;
  for i := 0 to High(A) do
  begin
    dot := dot + A[i] * B[i];
    if FMetric = 'cosine' then
    begin
      na := na + A[i] * A[i];
      nb := nb + B[i] * B[i];
    end
    else if FMetric = 'l1' then
      s := s + Abs(A[i] - B[i])
    else
      s := s + Sqr(A[i] - B[i]);
  end;
  if FMetric = 'cosine' then
  begin
    if (na = 0) or (nb = 0) then Exit(1.0);
    Exit(1 - dot / (Sqrt(na) * Sqrt(nb)));
  end;
  if FMetric = 'l1' then Exit(s);
  Result := s;   // l2: kare (siralama icin yeterli)
end;

function TVdbVectorIndex.RandomLevel: Integer;
begin
  // xorshift64*; (0,1) araliginda.
  FRand := FRand xor (FRand shr 12);
  FRand := FRand xor (FRand shl 25);
  FRand := FRand xor (FRand shr 27);
  Result := Trunc(-Ln(((FRand shr 11) + 1) / 9007199254740993.0) /
    Ln(Max(2, FM)));
  if Result < 0 then Result := 0;
  if Result > 16 then Result := 16;
end;

function TVdbVectorIndex.Greedy(const Q: TDoubleArray; Ep,
  Layer: Integer): Integer;
var
  best, n, cand, pass: Integer;
  bestD, d: Double;
begin
  best := Ep;
  bestD := Dist(Q, FVecs[best]);
  repeat
    cand := best;
    for n := 0 to High(FLinks[best][Layer]) do
    begin
      pass := FLinks[best][Layer][n];
      d := Dist(Q, FVecs[pass]);
      if d < bestD then
      begin
        bestD := d;
        cand := pass;
      end;
    end;
    if cand = best then Break;
    best := cand;
  until False;
  Result := best;
end;

function TVdbVectorIndex.SearchLayer(const Q: TDoubleArray; Ep, Ef,
  Layer: Integer): TVdbIntVec;
var
  cand, res: TVdbIntVec;
  candD, resD: TDoubleArray;
  i, j, n, cur, nc: Integer;
  d, cd: Double;

  procedure CandInsert(AIdx: Integer; ADist: Double);
  var
    k: Integer;
  begin
    k := Length(cand);
    SetLength(cand, k + 1);
    SetLength(candD, k + 1);
    while (k > 0) and (candD[k - 1] > ADist) do
    begin
      cand[k] := cand[k - 1];
      candD[k] := candD[k - 1];
      Dec(k);
    end;
    cand[k] := AIdx;
    candD[k] := ADist;
  end;

  procedure ResInsert(AIdx: Integer; ADist: Double);
  var
    k: Integer;
  begin
    k := Length(res);
    SetLength(res, k + 1);
    SetLength(resD, k + 1);
    while (k > 0) and (resD[k - 1] > ADist) do
    begin
      res[k] := res[k - 1];
      resD[k] := resD[k - 1];
      Dec(k);
    end;
    res[k] := AIdx;
    resD[k] := ADist;
  end;

begin
  Inc(FVisitEpoch);
  if FVisitEpoch = 0 then
  begin
    FillChar(FVisited[0], Length(FVisited) * SizeOf(Integer), 0);
    FVisitEpoch := 1;
  end;
  SetLength(cand, 0);
  SetLength(candD, 0);
  SetLength(res, 0);
  SetLength(resD, 0);

  d := Dist(Q, FVecs[Ep]);
  FVisited[Ep] := FVisitEpoch;
  CandInsert(Ep, d);
  ResInsert(Ep, d);

  while Length(cand) > 0 do
  begin
    cur := cand[0];
    cd := candD[0];
    for i := 1 to High(cand) do
    begin
      cand[i - 1] := cand[i];
      candD[i - 1] := candD[i];
    end;
    SetLength(cand, Length(cand) - 1);
    SetLength(candD, Length(candD) - 1);

    if (Length(res) >= Ef) and (cd > resD[High(resD)]) then
      Break;

    for n := 0 to High(FLinks[cur][Layer]) do
    begin
      nc := FLinks[cur][Layer][n];
      if FVisited[nc] = FVisitEpoch then Continue;
      FVisited[nc] := FVisitEpoch;
      d := Dist(Q, FVecs[nc]);
      if (Length(res) < Ef) or (d < resD[High(resD)]) then
      begin
        CandInsert(nc, d);
        ResInsert(nc, d);
        if Length(res) > Ef then
        begin
          SetLength(res, Ef);
          SetLength(resD, Ef);
        end;
      end;
    end;
  end;

  Result := res;
end;

procedure TVdbVectorIndex.SelectNeighbors(
  const Cand: TVdbIntVec; MaxN: Integer; out Res: TVdbIntVec);
var
  i, n: Integer;
begin
  // SearchLayer zaten mesafeye gore artan sirali; ilk MaxN yeterli.
  n := Min(MaxN, Length(Cand));
  SetLength(Res, n);
  for i := 0 to n - 1 do Res[i] := Cand[i];
end;

procedure TVdbVectorIndex.AddLink(Node, Layer, Other: Integer);
var
  i, n, maxLinks: Integer;
  dists: TDoubleArray;
  ids: TVdbIntVec;

  procedure SortByDist;
  var
    a, b: Integer;
    t: Integer;
    td: Double;
  begin
    for a := 1 to n - 1 do
    begin
      t := ids[a];
      td := dists[a];
      b := a - 1;
      while (b >= 0) and (dists[b] > td) do
      begin
        ids[b + 1] := ids[b];
        dists[b + 1] := dists[b];
        Dec(b);
      end;
      ids[b + 1] := t;
      dists[b + 1] := td;
    end;
  end;

begin
  n := Length(FLinks[Node][Layer]);
  SetLength(FLinks[Node][Layer], n + 1);
  FLinks[Node][Layer][n] := Other;
  maxLinks := FM;
  if Layer = 0 then maxLinks := 2 * FM;
  if n + 1 <= maxLinks then Exit;

  SetLength(ids, n + 1);
  SetLength(dists, n + 1);
  for i := 0 to n do
  begin
    ids[i] := FLinks[Node][Layer][i];
    dists[i] := Dist(FVecs[Node], FVecs[ids[i]]);
  end;
  SortByDist;
  SetLength(FLinks[Node][Layer], maxLinks);
  for i := 0 to maxLinks - 1 do
    FLinks[Node][Layer][i] := ids[i];
end;

procedure TVdbVectorIndex.Add(const AId: string; const AVec: TDoubleArray);
var
  idx, level, lc, ep, i: Integer;
  q: TDoubleArray;
  w, nbrs: TVdbIntVec;

  procedure Grow;
  var
    cap: Integer;
  begin
    cap := Length(FIds);
    if FCount < cap then Exit;
    if cap = 0 then cap := 16 else cap := cap * 2;
    SetLength(FIds, cap);
    SetLength(FVecs, cap);
    SetLength(FLevels, cap);
    SetLength(FLinks, cap);
    SetLength(FVisited, cap);
  end;

begin
  if Length(AVec) <> FDim then Exit;
  Grow;
  idx := FCount;
  Inc(FCount);
  FIds[idx] := AId;
  FVecs[idx] := Copy(AVec);
  level := RandomLevel;
  FLevels[idx] := Byte(level);
  SetLength(FLinks[idx], level + 1);
  for lc := 0 to level do SetLength(FLinks[idx][lc], 0);

  if FEntry < 0 then
  begin
    FEntry := idx;
    FMaxLevel := level;
    Exit;
  end;

  q := AVec;
  ep := FEntry;
  for lc := FMaxLevel downto level + 1 do
    ep := Greedy(q, ep, lc);

  for lc := Min(level, FMaxLevel) downto 0 do
  begin
    w := SearchLayer(q, ep, FEfConstruction, lc);
    SelectNeighbors(w, FM, nbrs);
    SetLength(FLinks[idx][lc], Length(nbrs));
    for i := 0 to High(nbrs) do
      FLinks[idx][lc][i] := nbrs[i];
    for i := 0 to High(nbrs) do
      AddLink(nbrs[i], lc, idx);
    if Length(w) > 0 then ep := w[0];
  end;

  if level > FMaxLevel then
  begin
    FEntry := idx;
    FMaxLevel := level;
  end;
end;

function TVdbVectorIndex.Search(const Q: TDoubleArray; K: Integer;
  out Ids: TStrArray; out Dists: TDoubleArray): Boolean;
var
  ep, lc, i, n: Integer;
  w: TVdbIntVec;
  d: Double;
begin
  SetLength(Ids, 0);
  SetLength(Dists, 0);
  Result := False;
  if (K <= 0) or (FCount = 0) or (Length(Q) <> FDim) then Exit;
  ep := FEntry;
  for lc := FMaxLevel downto 1 do
    ep := Greedy(Q, ep, lc);
  w := SearchLayer(Q, ep, Max(FEfSearch, K), 0);
  n := Min(K, Length(w));
  SetLength(Ids, n);
  SetLength(Dists, n);
  for i := 0 to n - 1 do
  begin
    Ids[i] := FIds[w[i]];
    d := Dist(Q, FVecs[w[i]]);
    if FMetric = 'l2' then d := Sqrt(d);
    Dists[i] := d;
  end;
  Result := n > 0;
end;

end.
