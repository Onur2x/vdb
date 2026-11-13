unit VDbSpatial;

{ F-24: SPATIAL DESTEGI â€” mesafe, daire, bounding box, cokgen.
  Koordinatlar TEXT kolonunda "x,y" biciminde saklanir (VDB spatial tipi
  yoktur; bu bir "spatial sorgu katmani"dir).

  Desteklenen fonksiyonlar:
    DISTANCE(x1, y1, x2, y2)              -> Oklid mesafesi
    HAVERSINE(lat1, lon1, lat2, lon2)     -> kure mesafesi (km)
    IN_CIRCLE(x, y, cx, cy, r)            -> daire icinde mi (True/False)
    IN_BOX(x, y, x1, y1, x2, y2)          -> bounding box icinde mi
    IN_POLYGON(x, y, 'x1,y1;x2,y2;...')   -> cokgen icinde mi (ray casting)
    AREA_POLYGON('x1,y1;x2,y2;...')       -> cokgen alani (Shoelace)
    POINT_IN_POLYGON(x, y, 'x1,y1;...')   -> IN_POLYGON ile ayni (PG uyumlu adi)

  Cokgen bicimi: noktalar ';' ile ayrilir, her nokta 'x,y'.
  Ornek: '0,0;10,0;10,10;0,10' -> kare.

  Ray casting algoritmasi: yatay bir isin cokgen kenarlariyla kesisim
  sayar; tek sayi -> icinde, cift -> disinda. Kenar durumlari (duz kenar,
  kose noktasi) ozel olarak ele alinir. }

{$mode delphi}

interface

uses
  Classes, SysUtils, Math, VDbCore, VDbTable, VDbTypes;

function VDbDistance(x1, y1, x2, y2: Double): Double;
function VDbHaversine(lat1, lon1, lat2, lon2: Double): Double;
function VDbInCircle(x, y, cx, cy, r: Double): Boolean;
function VDbInBox(x, y, x1, y1, x2, y2: Double): Boolean;
function VDbInPolygon(x, y: Double; const PolyStr: string): Boolean;
function VDbAreaPolygon(const PolyStr: string): Double;
function VDbParsePoint(const S: string; out X, Y: Double): Boolean;
function VDbParsePolygon(const S: string; out Pts: TStrArray): Boolean;

implementation

function VDbSplit(const S: string; D: Char): TStrArray;
var
  i, n: Integer;
  cur: string;
begin
  SetLength(Result, 0);
  if S = '' then Exit;
  n := 0;
  cur := '';
  for i := 1 to Length(S) do
  begin
    if S[i] = D then
    begin
      SetLength(Result, n + 1);
      Result[n] := cur;
      Inc(n);
      cur := '';
    end
    else
      cur := cur + S[i];
  end;
  SetLength(Result, n + 1);
  Result[n] := cur;
end;

function VDbParsePoint(const S: string; out X, Y: Double): Boolean;
var
  p: Integer;
  sx, sy: string;
begin
  Result := False;
  X := 0; Y := 0;
  p := Pos(',', S);
  if p = 0 then Exit;
  sx := Trim(Copy(S, 1, p - 1));
  sy := Trim(Copy(S, p + 1, MaxInt));
  // VDbParseFloat ondalik ayiricini '.' olarak sabitler. Duz TryStrToFloat
  // sistem localesine baglidir; Turkce locale'de '10.5' parse edilemez ve tum
  // polygon kontrolleri yanlis sonuc verir.
  if not VDbParseFloat(sx, X) then Exit;
  if not VDbParseFloat(sy, Y) then Exit;
  Result := True;
end;

function VDbParsePolygon(const S: string; out Pts: TStrArray): Boolean;
var
  parts: TStrArray;
  i, n: Integer;
  x, y: Double;
begin
  Result := False;
  SetLength(Pts, 0);
  if Trim(S) = '' then Exit(False);
  parts := VDbSplit(Trim(S), ';');
  n := 0;
  SetLength(Pts, Length(parts));
  for i := 0 to High(parts) do
  begin
    if not VDbParsePoint(parts[i], x, y) then Exit(False);
    Pts[n] := parts[i];
    Inc(n);
  end;
  SetLength(Pts, n);
  Result := n >= 3;   // cokgen en az 3 nokta
end;

function VDbDistance(x1, y1, x2, y2: Double): Double;
begin
  Result := Sqrt(Sqr(x2 - x1) + Sqr(y2 - y1));
end;

function VDbHaversine(lat1, lon1, lat2, lon2: Double): Double;
const
  R = 6371.0;   // Derya yaricapi (km)
var
  dlat, dlon, a: Double;
begin
  dlat := DegToRad(lat2 - lat1);
  dlon := DegToRad(lon2 - lon1);
  a := Sin(dlat / 2) * Sin(dlat / 2) +
       Cos(DegToRad(lat1)) * Cos(DegToRad(lat2)) *
       Sin(dlon / 2) * Sin(dlon / 2);
  // Haversine yaricapinda 'a' matematiksel olarak [0,1] icinde olmalidir;
  // yuvarlama hatasi 1'in cok az uzerine (1+2e-16) cikabilir. Sqrt/ArcSin
  // alan hatasi (EInvalidOp) verir; bu yuzden once clamp edilir.
  if a > 1 then a := 1;
  if a < 0 then a := 0;
  Result := R * (2 * ArcSin(Sqrt(a)));
end;

function VDbInCircle(x, y, cx, cy, r: Double): Boolean;
begin
  Result := Sqr(x - cx) + Sqr(y - cy) <= Sqr(r);
end;

function VDbInBox(x, y, x1, y1, x2, y2: Double): Boolean;
var
  loX, hiX, loY, hiY: Double;
begin
  if x1 < x2 then begin loX := x1; hiX := x2; end
  else begin loX := x2; hiX := x1; end;
  if y1 < y2 then begin loY := y1; hiY := y2; end
  else begin loY := y2; hiY := y1; end;
  Result := (x >= loX) and (x <= hiX) and (y >= loY) and (y <= hiY);
end;

function VDbInPolygon(x, y: Double; const PolyStr: string): Boolean;
// Ray casting: yatay isin kenarlarla kesisim sayar. Tek -> icinde.
var
  pts: TStrArray;
  i, j, n: Integer;
  x1, y1, x2, y2: Double;
  intersect: Boolean;
begin
  Result := False;
  if not VDbParsePolygon(PolyStr, pts) then Exit;
  n := Length(pts);
  if n < 3 then Exit;
  j := n - 1;
  for i := 0 to n - 1 do
  begin
    VDbParsePoint(pts[i], x1, y1);
    VDbParsePoint(pts[j], x2, y2);
    // Kenar (x1,y1)-(x2,y2) yatay isini kesiyor mu?
    intersect := ((y1 > y) <> (y2 > y)) and
                 (x < (x2 - x1) * (y - y1) / (y2 - y1) + x1);
    if intersect then Result := not Result;
    j := i;
  end;
end;

function VDbAreaPolygon(const PolyStr: string): Double;
// Shoelace formulu: |sum(x_i * y_{i+1} - x_{i+1} * y_i)| / 2
var
  pts: TStrArray;
  i, n: Integer;
  x1, y1, x2, y2: Double;
  sum: Double;
begin
  Result := 0;
  if not VDbParsePolygon(PolyStr, pts) then Exit;
  n := Length(pts);
  if n < 3 then Exit;
  sum := 0;
  for i := 0 to n - 1 do
  begin
    VDbParsePoint(pts[i], x1, y1);
    VDbParsePoint(pts[(i + 1) mod n], x2, y2);
    sum := sum + (x1 * y2 - x2 * y1);
  end;
  Result := Abs(sum) / 2;
end;

end.


