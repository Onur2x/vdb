unit VDbKdf;
{ VDbKdf - M6: saf Pascal BLAKE2b + Argon2id (v1.3).

  Neden: .key dosyasi PBKDF2-SHA256 kullaniyordu. Argon2id bellek-sert
  bir KDF'dir; GPU/ASIC ile paralel denemeyi pahali hale getirir.
  Dis bagimlilik yoktur; RFC 9106 test vektoru ile dogrulanir.

  Not: Yalnizca Argon2id (y=2) uygulanmistir; Argon2d/i yollarina
  ihtiyac yoktur. Gizli anahtar (secret) ve iliskili veri (AD)
  desteklenir; .key dosyasi bunlari bos kullanir. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  EVdbKdfError = class(Exception);

function VDbBlake2b(const Data: TBytes; OutLen: Integer): TBytes;
function VDbArgon2id(const Password, Salt, Secret, Ad: TBytes;
  TimeCost, MemoryKiB, Lanes, HashLen: Integer; out Hash: TBytes): Boolean;

implementation

const
  B2B_IV: array[0..7] of QWord = (
    QWord($6a09e667f3bcc908), QWord($bb67ae8584caa73b),
    QWord($3c6ef372fe94f82b), QWord($a54ff53a5f1d36f1),
    QWord($510e527fade682d1), QWord($9b05688c2b3e6c1f),
    QWord($1f83d9abfb41bd6b), QWord($5be0cd19137e2179));

  B2B_SIGMA: array[0..11, 0..15] of Byte = (
    (0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15),
    (14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3),
    (11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4),
    (7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8),
    (9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13),
    (2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9),
    (12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11),
    (13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10),
    (6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5),
    (10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0),
    (0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15),
    (14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3));

type
  TArgonBlock = array[0..127] of QWord;

function RotR64(X: QWord; N: Byte): QWord;
begin
  Result := (X shr N) or (X shl (64 - N));
end;

procedure B2G(var a, b, c, d: QWord; x, y: QWord);
begin
  a := a + b + x;
  d := RotR64(d xor a, 32);
  c := c + d;
  b := RotR64(b xor c, 24);
  a := a + b + y;
  d := RotR64(d xor a, 16);
  c := c + d;
  b := RotR64(b xor c, 63);
end;

procedure B2Compress(var h: array of QWord; const Block: array of Byte;
  T0, T1, F0, F1: QWord);
var
  v: array[0..15] of QWord;
  m: array[0..15] of QWord;
  i, r: Integer;
begin
  for i := 0 to 7 do
    v[i] := h[i];
  for i := 0 to 7 do
    v[8 + i] := B2B_IV[i];
  v[12] := v[12] xor T0;
  v[13] := v[13] xor T1;
  v[14] := v[14] xor F0;
  v[15] := v[15] xor F1;
  for i := 0 to 15 do
    Move(Block[i * 8], m[i], 8);
  for r := 0 to 11 do
  begin
    B2G(v[0], v[4], v[8], v[12], m[B2B_SIGMA[r, 0]], m[B2B_SIGMA[r, 1]]);
    B2G(v[1], v[5], v[9], v[13], m[B2B_SIGMA[r, 2]], m[B2B_SIGMA[r, 3]]);
    B2G(v[2], v[6], v[10], v[14], m[B2B_SIGMA[r, 4]], m[B2B_SIGMA[r, 5]]);
    B2G(v[3], v[7], v[11], v[15], m[B2B_SIGMA[r, 6]], m[B2B_SIGMA[r, 7]]);
    B2G(v[0], v[5], v[10], v[15], m[B2B_SIGMA[r, 8]], m[B2B_SIGMA[r, 9]]);
    B2G(v[1], v[6], v[11], v[12], m[B2B_SIGMA[r, 10]], m[B2B_SIGMA[r, 11]]);
    B2G(v[2], v[7], v[8], v[13], m[B2B_SIGMA[r, 12]], m[B2B_SIGMA[r, 13]]);
    B2G(v[3], v[4], v[9], v[14], m[B2B_SIGMA[r, 14]], m[B2B_SIGMA[r, 15]]);
  end;
  for i := 0 to 7 do
    h[i] := h[i] xor v[i] xor v[8 + i];
end;

function VDbBlake2b(const Data: TBytes; OutLen: Integer): TBytes;
var
  h: array[0..7] of QWord;
  block: array[0..127] of Byte;
  t0, t1: QWord;
  p, n, i: Integer;
begin
  if (OutLen < 1) or (OutLen > 64) then
    raise EVdbKdfError.Create('BLAKE2b cikti uzunlugu 1..64 olmali');
  for i := 0 to 7 do
    h[i] := B2B_IV[i];
  h[0] := h[0] xor QWord($01010000) xor QWord(OutLen);
  t0 := 0;
  t1 := 0;
  p := 0;
  while (Length(Data) - p) > 128 do
  begin
    Move(Data[p], block[0], 128);
    Inc(t0, 128);
    if t0 < 128 then Inc(t1);
    B2Compress(h, block, t0, t1, 0, 0);
    Inc(p, 128);
  end;
  n := Length(Data) - p;
  FillChar(block[0], 128, 0);
  if n > 0 then
    Move(Data[p], block[0], n);
  Inc(t0, QWord(n));
  if t0 < QWord(n) then Inc(t1);
  B2Compress(h, block, t0, t1, QWord($FFFFFFFFFFFFFFFF), 0);
  SetLength(Result, OutLen);
  i := 0;
  while i < OutLen do
  begin
    if (OutLen - i) >= 8 then
    begin
      Move(h[i div 8], Result[i], 8);
      Inc(i, 8);
    end
    else
    begin
      Move(h[i div 8], block[0], 8);
      Move(block[0], Result[i], OutLen - i);
      Inc(i, OutLen - i);
    end;
  end;
end;

procedure AppendLE32(var B: TBytes; V: LongWord);
var
  n, i: Integer;
begin
  n := Length(B);
  SetLength(B, n + 4);
  for i := 0 to 3 do
    B[n + i] := Byte((V shr (i * 8)) and $FF);
end;

function Blake2bLong(const X: TBytes; OutLen: Integer): TBytes;
var
  inBuf, v: TBytes;
  r, i, n, off: Integer;
begin
  SetLength(inBuf, 4 + Length(X));
  inBuf[0] := Byte(OutLen and $FF);
  inBuf[1] := Byte((OutLen shr 8) and $FF);
  inBuf[2] := Byte((OutLen shr 16) and $FF);
  inBuf[3] := Byte((OutLen shr 24) and $FF);
  if Length(X) > 0 then
    Move(X[0], inBuf[4], Length(X));
  if OutLen <= 64 then
    Exit(VDbBlake2b(inBuf, OutLen));

  SetLength(Result, OutLen);
  r := (OutLen + 31) div 32 - 2;
  v := VDbBlake2b(inBuf, 64);
  off := 0;
  for i := 1 to r do
  begin
    Move(v[0], Result[off], 32);
    Inc(off, 32);
    if i < r then
      v := VDbBlake2b(v, 64);
  end;
  n := OutLen - off;
  v := VDbBlake2b(v, n);
  Move(v[0], Result[off], n);
end;

procedure BlockFromBytes(var B: TArgonBlock; const Data: TBytes; Offset: Integer);
begin
  Move(Data[Offset], B[0], 1024);
end;

procedure BlockToBytes(const B: TArgonBlock; var Data: TBytes);
begin
  SetLength(Data, 1024);
  Move(B[0], Data[0], 1024);
end;

procedure ArgonG(var a, b, c, d: QWord);
var
  la, lb: QWord;
begin
  la := a and QWord($FFFFFFFF);
  lb := b and QWord($FFFFFFFF);
  a := a + b + (2 * la * lb);
  d := RotR64(d xor a, 32);
  la := c and QWord($FFFFFFFF);
  lb := d and QWord($FFFFFFFF);
  c := c + d + (2 * la * lb);
  b := RotR64(b xor c, 24);
  la := a and QWord($FFFFFFFF);
  lb := b and QWord($FFFFFFFF);
  a := a + b + (2 * la * lb);
  d := RotR64(d xor a, 16);
  la := c and QWord($FFFFFFFF);
  lb := d and QWord($FFFFFFFF);
  c := c + d + (2 * la * lb);
  b := RotR64(b xor c, 63);
end;

procedure ArgonRound(var w: array of QWord);
begin
  ArgonG(w[0], w[4], w[8], w[12]);
  ArgonG(w[1], w[5], w[9], w[13]);
  ArgonG(w[2], w[6], w[10], w[14]);
  ArgonG(w[3], w[7], w[11], w[15]);
  ArgonG(w[0], w[5], w[10], w[15]);
  ArgonG(w[1], w[6], w[11], w[12]);
  ArgonG(w[2], w[7], w[8], w[13]);
  ArgonG(w[3], w[4], w[9], w[14]);
end;

procedure ArgonP(var B: TArgonBlock);
var
  t: array[0..15] of QWord;
  i, r, c: Integer;
begin
  for r := 0 to 7 do
  begin
    for i := 0 to 15 do
      t[i] := B[r * 16 + i];
    ArgonRound(t);
    for i := 0 to 15 do
      B[r * 16 + i] := t[i];
  end;
  for c := 0 to 7 do
  begin
    for r := 0 to 7 do
    begin
      t[r * 2] := B[r * 16 + c * 2];
      t[r * 2 + 1] := B[r * 16 + c * 2 + 1];
    end;
    ArgonRound(t);
    for r := 0 to 7 do
    begin
      B[r * 16 + c * 2] := t[r * 2];
      B[r * 16 + c * 2 + 1] := t[r * 2 + 1];
    end;
  end;
end;

procedure ArgonFillBlock(const Prev, Ref: TArgonBlock; var Nxt: TArgonBlock;
  WithXor: Boolean);
var
  R, T: TArgonBlock;
  i: Integer;
begin
  for i := 0 to 127 do
    R[i] := Prev[i] xor Ref[i];
  T := R;
  if WithXor then
    for i := 0 to 127 do
      T[i] := T[i] xor Nxt[i];
  ArgonP(R);
  for i := 0 to 127 do
    Nxt[i] := T[i] xor R[i];
end;

procedure ArgonNextAddresses(var Address, Input: TArgonBlock);
var
  Zero: TArgonBlock;
  i: Integer;
begin
  Inc(Input[6]);
  for i := 0 to 127 do
    Zero[i] := 0;
  ArgonFillBlock(Zero, Input, Address, False);
  ArgonFillBlock(Zero, Address, Address, False);
end;

function VDbArgon2id(const Password, Salt, Secret, Ad: TBytes;
  TimeCost, MemoryKiB, Lanes, HashLen: Integer; out Hash: TBytes): Boolean;
var
  H0, hb, blkBytes, inBuf: TBytes;
  Mem: array of TArgonBlock;
  C: TArgonBlock;
  Input, Address: TArgonBlock;
  m, laneLen, segLen, p, t, lane, slice, cur, prev, ref: Integer;
  pass, i, j: Integer;
  refLane: Integer;
  sameLane: Boolean;
  refArea, startPos, refIndex, z: Int64;
  J1, J2: LongWord;
  x, y: QWord;
  dataInd: Boolean;
begin
  Result := False;
  Hash := nil;
  p := Lanes;
  t := TimeCost;
  if (p < 1) or (t < 1) or (HashLen < 4) or (MemoryKiB < 8 * p) then
    Exit;
  m := (MemoryKiB div (4 * p)) * (4 * p);
  if m < 8 * p then Exit;
  laneLen := m div p;
  segLen := laneLen div 4;

  { H0 = BLAKE2b-512(LE32(p)||LE32(T)||LE32(m)||LE32(t)||LE32(v)||
        LE32(y)||LE32(|P|)||P||LE32(|S|)||S||LE32(|K|)||K||LE32(|X|)||X) }
  SetLength(H0, 0);
  AppendLE32(H0, LongWord(p));
  AppendLE32(H0, LongWord(HashLen));
  AppendLE32(H0, LongWord(MemoryKiB));
  AppendLE32(H0, LongWord(t));
  AppendLE32(H0, $13);
  AppendLE32(H0, 2); // Argon2id
  AppendLE32(H0, LongWord(Length(Password)));
  if Length(Password) > 0 then
  begin
    i := Length(H0);
    SetLength(H0, i + Length(Password));
    Move(Password[0], H0[i], Length(Password));
  end;
  AppendLE32(H0, LongWord(Length(Salt)));
  if Length(Salt) > 0 then
  begin
    i := Length(H0);
    SetLength(H0, i + Length(Salt));
    Move(Salt[0], H0[i], Length(Salt));
  end;
  AppendLE32(H0, LongWord(Length(Secret)));
  if Length(Secret) > 0 then
  begin
    i := Length(H0);
    SetLength(H0, i + Length(Secret));
    Move(Secret[0], H0[i], Length(Secret));
  end;
  AppendLE32(H0, LongWord(Length(Ad)));
  if Length(Ad) > 0 then
  begin
    i := Length(H0);
    SetLength(H0, i + Length(Ad));
    Move(Ad[0], H0[i], Length(Ad));
  end;
  hb := VDbBlake2b(H0, 64);

  SetLength(Mem, m);
  for i := 0 to m - 1 do
    FillChar(Mem[i], 1024, 0);

  for lane := 0 to p - 1 do
    for j := 0 to 1 do
    begin
      SetLength(inBuf, Length(hb) + 8);
      Move(hb[0], inBuf[0], Length(hb));
      inBuf[Length(hb)] := Byte(j and $FF);
      inBuf[Length(hb) + 1] := Byte((j shr 8) and $FF);
      inBuf[Length(hb) + 2] := Byte((j shr 16) and $FF);
      inBuf[Length(hb) + 3] := Byte((j shr 24) and $FF);
      inBuf[Length(hb) + 4] := Byte(lane and $FF);
      inBuf[Length(hb) + 5] := Byte((lane shr 8) and $FF);
      inBuf[Length(hb) + 6] := Byte((lane shr 16) and $FF);
      inBuf[Length(hb) + 7] := Byte((lane shr 24) and $FF);
      blkBytes := Blake2bLong(inBuf, 1024);
      BlockFromBytes(Mem[lane * laneLen + j], blkBytes, 0);
    end;

  for pass := 0 to t - 1 do
    for slice := 0 to 3 do
      for lane := 0 to p - 1 do
      begin
        dataInd := (pass = 0) and (slice < 2);
        if dataInd then
        begin
          FillChar(Input[0], 1024, 0);
          Input[0] := QWord(pass);
          Input[1] := QWord(lane);
          Input[2] := QWord(slice);
          Input[3] := QWord(m);
          Input[4] := QWord(t);
          Input[5] := 2;
          Input[6] := 0;
          FillChar(Address[0], 1024, 0);
        end;
        if (pass = 0) and (slice = 0) then
        begin
          i := 2;
          if dataInd then
            ArgonNextAddresses(Address, Input);
        end
        else
          i := 0;
        while i < segLen do
        begin
          cur := lane * laneLen + slice * segLen + i;
          if (slice = 0) and (i = 0) then
            prev := lane * laneLen + laneLen - 1
          else
            prev := cur - 1;
          if dataInd then
          begin
            if (i mod 128) = 0 then
              ArgonNextAddresses(Address, Input);
            J1 := LongWord(Address[i mod 128] and QWord($FFFFFFFF));
            J2 := LongWord(Address[i mod 128] shr 32);
          end
          else
          begin
            J1 := LongWord(Mem[prev][0] and QWord($FFFFFFFF));
            J2 := LongWord(Mem[prev][0] shr 32);
          end;
          refLane := Integer(Int64(J2) mod p);
          if (pass = 0) and (slice = 0) then
            refLane := lane;
          sameLane := refLane = lane;
          if pass = 0 then
          begin
            if slice = 0 then
              refArea := i - 1
            else if sameLane then
              refArea := Int64(slice) * segLen + i - 1
            else if i = 0 then
              refArea := Int64(slice) * segLen - 1
            else
              refArea := Int64(slice) * segLen;
          end
          else
          begin
            if sameLane then
              refArea := Int64(laneLen) - segLen + i - 1
            else if i = 0 then
              refArea := Int64(laneLen) - segLen - 1
            else
              refArea := Int64(laneLen) - segLen;
          end;
          if refArea < 1 then refArea := 1;
          x := (QWord(J1) * QWord(J1)) shr 32;
          y := (QWord(refArea) * x) shr 32;
          z := refArea - 1 - Int64(y);
          if (pass = 0) or (slice = 3) then
            startPos := 0
          else
            startPos := Int64(slice + 1) * segLen;
          refIndex := (startPos + z) mod laneLen;
          ref := refLane * laneLen + Integer(refIndex);
          ArgonFillBlock(Mem[prev], Mem[ref], Mem[cur], pass > 0);
          Inc(i);
        end;
      end;

  C := Mem[0 * laneLen + laneLen - 1];
  for lane := 1 to p - 1 do
    for i := 0 to 127 do
      C[i] := C[i] xor Mem[lane * laneLen + laneLen - 1][i];
  BlockToBytes(C, inBuf);
  Hash := Blake2bLong(inBuf, HashLen);
  for i := 0 to High(Mem) do
    FillChar(Mem[i], 1024, 0);
  if Length(H0) > 0 then FillChar(H0[0], Length(H0), 0);
  if Length(hb) > 0 then FillChar(hb[0], Length(hb), 0);
  if Length(blkBytes) > 0 then FillChar(blkBytes[0], Length(blkBytes), 0);
  if Length(inBuf) > 0 then FillChar(inBuf[0], Length(inBuf), 0);
  Result := True;
end;

end.
