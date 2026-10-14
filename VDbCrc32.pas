unit VDbCrc32;

{ Saf Pascal CRC32 (IEEE 802.3, poly $EDB88320, check degeri $CBF43926).

  KLASIK bayt-bayt tablo CRC32. Bilerek slice-by-4/8 KULLANILMAZ.

  Neden: FPC 3.2.4 (i386-win32, mode delphi, -O2) ile slice
  varyantlari denendi ve 4'ten uzun girdilerde TUTARISIZ sonuc
  uretildi (her calistirmada farkli deger; 1-3 bayt dogruydu).
  Bu optimizasyon/veri-hazirligi hatasi; guvenilirlik CRC'de
  kritik oldugu icin bilerek geri alindi. Original algoritma
  FPC'de deterministik ve dogru calisiyor.

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

implementation

type
  TByteTab = array[0..255] of LongWord;

var
  T0: TByteTab;

procedure BuildTbl;
var
  i, j: Integer;
  c: LongWord;
begin
  for i := 0 to 255 do
  begin
    c := LongWord(i);
    for j := 0 to 7 do
      if (c and 1) <> 0 then
        c := $EDB88320 xor (c shr 1)
      else
        c := c shr 1;
    T0[i] := c;
  end;
end;

function VDbCrc32Init: LongWord;
begin
  Result := $FFFFFFFF;
end;

function VDbCrc32UpdatePtr(Crc: LongWord; P: PByte; Len: Integer): LongWord;
// Kayan isaretci ile bayt bayt (orijinal, deterministik yol).
var
  i: Integer;
begin
  if (Len <= 0) or (P = nil) then Exit(Crc);
  for i := 0 to Len - 1 do
    Crc := T0[Byte(Crc xor P[i])] xor (Crc shr 8);
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
