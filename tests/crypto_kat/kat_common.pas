unit kat_common;
{ kat_common - shared PASS/FAIL reporting and byte/hex helpers for the
  VDB crypto KAT harness.

  Purpose (engineering skill EK A R-1, section 3): seal VDbCrypt / VDbKdf /
  VDbPageCrypto primitives against official NIST/RFC known-answer vectors so
  the "self-written primitive" debt is closed by tests, not by code changes.

  This unit does NOT touch production code; it only reports. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

var
  KatPassed: Integer;
  KatFailed: Integer;
  KatSkipped: Integer;

procedure KatResetCounters;
procedure KatSection(const ATitle: string);
procedure KatPass(const APrimitive, AVector, ASource: string);
procedure KatFail(const APrimitive, AVector, ASource, ADetail: string);
{ KatSkip is also used to record documented notes (non-runnable checks,
  design limitations, TODO items). }
procedure KatSkip(const APrimitive, AVector, ASource, AReason: string);
function KatTotalFailed: Integer;

{ --- byte/hex helpers (ASCII-only sources; no locale dependencies) --- }

function HexToBytes(const H: string): TBytes;
function BytesToHexL(const B: TBytes): string;
function StrB(const S: string): TBytes;
function Rep(const B: Byte; N: Integer): TBytes;
function BEq(const A, B: TBytes): Boolean;
function Sub(const A: TBytes; Of_, Len: Integer): TBytes;
procedure PutLE32(var B: TBytes; Of_: Integer; V: LongWord);

implementation

procedure KatResetCounters;
begin
  KatPassed := 0;
  KatFailed := 0;
  KatSkipped := 0;
end;

procedure KatSection(const ATitle: string);
begin
  Writeln;
  Writeln('--- ', ATitle, ' ---');
end;

procedure KatPass(const APrimitive, AVector, ASource: string);
begin
  Inc(KatPassed);
  Writeln('PASS | ', APrimitive, ' | ', AVector, ' | ', ASource);
end;

procedure KatFail(const APrimitive, AVector, ASource, ADetail: string);
begin
  Inc(KatFailed);
  Writeln('FAIL | ', APrimitive, ' | ', AVector, ' | ', ASource);
  Writeln('      -> ', ADetail);
end;

procedure KatSkip(const APrimitive, AVector, ASource, AReason: string);
begin
  Inc(KatSkipped);
  Writeln('SKIP | ', APrimitive, ' | ', AVector, ' | ', ASource);
  Writeln('     note: ', AReason);
end;

function KatTotalFailed: Integer;
begin
  Result := KatFailed;
end;

function HexNib(C: Char; var N: Byte): Boolean;
begin
  Result := True;
  case C of
    '0'..'9': N := Byte(C) - Byte('0');
    'a'..'f': N := Byte(C) - Byte('a') + 10;
    'A'..'F': N := Byte(C) - Byte('A') + 10;
  else
    Result := False;
  end;
end;

function HexToBytes(const H: string): TBytes;
{ Accepts hex with spaces/newlines; empty string -> empty (length 0) TBytes. }
var
  i, n, k: Integer;
  hi, lo: Byte;
  c: Char;
begin
  n := 0;
  for i := 1 to Length(H) do
    if not (H[i] in [' ', #9, #10, #13]) then
      Inc(n);
  if (n mod 2) <> 0 then
    raise Exception.Create('HexToBytes: odd number of hex digits');
  SetLength(Result, n div 2);
  k := 0;
  i := 1;
  while i <= Length(H) do
  begin
    c := H[i];
    if c in [' ', #9, #10, #13] then
    begin
      Inc(i);
      Continue;
    end;
    if not HexNib(c, hi) then
      raise Exception.Create('HexToBytes: bad digit "' + c + '"');
    Inc(i);
    while (i <= Length(H)) and (H[i] in [' ', #9, #10, #13]) do
      Inc(i);
    if i > Length(H) then
      raise Exception.Create('HexToBytes: truncated pair');
    if not HexNib(H[i], lo) then
      raise Exception.Create('HexToBytes: bad digit "' + H[i] + '"');
    Result[k] := Byte((hi shl 4) or lo);
    Inc(k);
    Inc(i);
  end;
end;

function BytesToHexL(const B: TBytes): string;
const
  Digs: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to Length(B) - 1 do
  begin
    Result[i * 2 + 1] := Digs[B[i] shr 4];
    Result[i * 2 + 2] := Digs[B[i] and $0F];
  end;
end;

function StrB(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function Rep(const B: Byte; N: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
    Result[i] := B;
end;

function BEq(const A, B: TBytes): Boolean;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  if Length(A) = 0 then
    Exit(True);
  Result := CompareMem(@A[0], @B[0], Length(A));
end;

function Sub(const A: TBytes; Of_, Len: Integer): TBytes;
begin
  if (Len < 0) or (Of_ < 0) or (Of_ + Len > Length(A)) then
    raise Exception.Create('Sub: range ' + IntToStr(Of_) + '+' +
      IntToStr(Len) + ' out of ' + IntToStr(Length(A)));
  SetLength(Result, Len);
  if Len > 0 then
    Move(A[Of_], Result[0], Len);
end;

procedure PutLE32(var B: TBytes; Of_: Integer; V: LongWord);
var
  i: Integer;
begin
  if (Of_ < 0) or (Of_ + 4 > Length(B)) then
    raise Exception.Create('PutLE32: range out of bounds');
  for i := 0 to 3 do
    B[Of_ + i] := Byte((V shr (i * 8)) and $FF);
end;

end.
