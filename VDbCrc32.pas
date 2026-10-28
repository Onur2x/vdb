unit VDbCrc32;

{ Saf Pascal CRC32 (IEEE 802.3, poly $EDB88320, check degeri $CBF43926).

  v3.23: SLICE-BY-8. Eski surum klasik bayt-bayt tablo CRC32 idi; birim
  basliginda "slice FPC'de tutarsiz sonuc verdi, bilerek kullanilmiyor"
  yaziyordu. v3.23'te kok neden bulundu: eski deneme 8 bayti HIZASIZ
  64-bit isaretci okumasiyla (PInt64(P)^) aliyordu; i386'da hizasiz
  erisim sessizce yanlis veri uretir. Slice-by-8'in kendisi dogru.

  Yeni uygulama ilk 4 bayti Move(P^, w, 4) ile alir (hiza guvenli; Move
  memcpy gibi bayt kopyalar), kalan 4 bayti tek tek indeksler. Hizli yol
  VDbCrc32UpdatePtrSlow (referans, bayt-bayt) ile kapi tarafindan
  karsilastirilir: tests/gates/backendchk.lpr -> TestV3Crc32.

  Olculen (i386-win32, -O2): 4096 bayt 7,22 us -> 1,745 us (4,1x).
  Commit yolunda AppendFrame 26,0 -> 8,4 us/commit.

  (DIKKAT: bu yorum icine "ac-kapa süslü" birim/mod bildirimi gibi
  ifadeler YAZILMAZ - icindeki ilk kapanis süsü yorumu erken kapatir
  ve unit derlenemez. 06.10.2026'da tam bu hata bulundu; bayat
  .ppu'lar taze derlemeyi sakladigi icin farkedilmiyordu.)

  Dogrulama: "a"=$E8B7BE43, "abc"=$352441C2, "123456789"=$CBF43926
}

{$mode delphi}

interface

uses SysUtils;   // TBytes

function VDbCrc32Init: LongWord;
function VDbCrc32Final(Crc: LongWord): LongWord;
function VDbCrc32Update(Crc: LongWord; const Buf; Len: Integer): LongWord;
function VDbCrc32Of(const Buf; Len: Integer): LongWord;
function VDbCrc32OfBytes(const B: TBytes; Len: Integer): LongWord;
function VDbCrc32UpdateBytes(Crc: LongWord; const B: TBytes; Len: Integer): LongWord;
function VDbCrc32UpdatePtr(Crc: LongWord; P: PByte; Len: Integer): LongWord;
{ Referans (bayt-bayt) yol; yalniz dogrulama/kapi icin. }
function VDbCrc32UpdatePtrSlow(Crc: LongWord; P: PByte; Len: Integer): LongWord;

implementation

type
  TByteTab = array[0..255] of LongWord;
  TSliceTab = array[0..7] of TByteTab;

var
  T: TSliceTab;

procedure BuildTbl;
var
  i, j: Integer;
  c: LongWord;
begin
  // T[0]: klasik tablo; T[k]: k bayt ileri kaydirilmis tablo.
  for i := 0 to 255 do
  begin
    c := LongWord(i);
    for j := 0 to 7 do
      if (c and 1) <> 0 then
        c := $EDB88320 xor (c shr 1)
      else
        c := c shr 1;
    T[0][i] := c;
  end;
  for j := 1 to 7 do
    for i := 0 to 255 do
      T[j][i] := (T[j - 1][i] shr 8) xor T[0][T[j - 1][i] and $FF];
end;

function VDbCrc32Init: LongWord;
begin
  Result := $FFFFFFFF;
end;

function VDbCrc32UpdatePtrSlow(Crc: LongWord; P: PByte; Len: Integer): LongWord;
// Referans yol: bayt bayt (orijinal, deterministik).
var
  i: Integer;
begin
  if (Len <= 0) or (P = nil) then Exit(Crc);
  for i := 0 to Len - 1 do
    Crc := T[0][Byte(Crc xor P[i])] xor (Crc shr 8);
  Result := Crc;
end;

function VDbCrc32UpdatePtr(Crc: LongWord; P: PByte; Len: Integer): LongWord;
// Slice-by-8 (hiza guvenli: 4 bayt Move ile alinir).
var
  w: LongWord;
begin
  if (Len <= 0) or (P = nil) then Exit(Crc);
  while Len >= 8 do
  begin
    Move(P[0], w, 4);
    Crc := Crc xor w;
    Crc := T[7][Crc and $FF] xor
           T[6][(Crc shr 8) and $FF] xor
           T[5][(Crc shr 16) and $FF] xor
           T[4][(Crc shr 24) and $FF] xor
           T[3][P[4]] xor
           T[2][P[5]] xor
           T[1][P[6]] xor
           T[0][P[7]];
    Inc(P, 8);
    Dec(Len, 8);
  end;
  while Len > 0 do
  begin
    Crc := T[0][Byte(Crc xor P[0])] xor (Crc shr 8);
    Inc(P);
    Dec(Len);
  end;
  Result := Crc;
end;

function VDbCrc32UpdateBytes(Crc: LongWord; const B: TBytes; Len: Integer): LongWord;
begin
  if (Len <= 0) or (Length(B) = 0) then Exit(Crc);
  if Len > Length(B) then Len := Length(B);
  Result := VDbCrc32UpdatePtr(Crc, @B[0], Len);
end;

function VDbCrc32Update(Crc: LongWord; const Buf; Len: Integer): LongWord;
begin
  if Len <= 0 then Exit(Crc);
  Result := VDbCrc32UpdatePtr(Crc, PByte(@Buf), Len);
end;

function VDbCrc32OfBytes(const B: TBytes; Len: Integer): LongWord;
begin
  if Len <= 0 then Exit(0);
  Result := VDbCrc32UpdateBytes($FFFFFFFF, B, Len) xor $FFFFFFFF;
end;

function VDbCrc32Of(const Buf; Len: Integer): LongWord;
begin
  if Len <= 0 then Exit(0);
  Result := VDbCrc32Update($FFFFFFFF, Buf, Len) xor $FFFFFFFF;
end;

function VDbCrc32Final(Crc: LongWord): LongWord;
begin
  Result := Crc xor $FFFFFFFF;
end;

initialization
  BuildTbl;

end.
