unit VDbPage;

{ VDB v3 - Sayfa Cekirdegi (Sprint 1 / Gun 1)

  Sabit 4096 baytlik sayfa. Slotted-page yerlesimi:

    0   ..  23   baslik (24 bayt)
    24  ..  ...  slot dizini (her slot 4 bayt: Off, Len), yukari dogru buyur
    ... .. 4091   hucre govdesi, asagi dogru buyur
    4092 .. 4095  CRC32 (0..4091 uzerinde)

  Slot.Off = 0 ise slot BOSTUR (silinmis). Silinen hucrenin baytlari
  yerinde kalir; FragBytes ile muhasebe edilir ve PageCompact ile
  geri kazanilir. Boylece silme O(1)'dir.

  Bu birim dosya/IO bilmez; yalnizca 4 KB'lik bir tampon uzerinde
  calisir. Buffer pool, WAL ve heap katmanlari bunun uzerine gelir.

  Butunluk kurali: her yazma isleminden sonra cagiran PageSeal(P) ile
  CRC'yi tazelemelidir. PageVerify hem yapiyi hem CRC'yi denetler.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, VDbCrc32;

const
  VDB_PAGE_SIZE      = 4096;
  VDB_PAGE_HDR       = 24;
  VDB_PAGE_CRC_LEN   = 4;
  { Govdenin bitisi (CRC'nin basladigi yer). }
  VDB_PAGE_BODY_END  = VDB_PAGE_SIZE - VDB_PAGE_CRC_LEN;   // 4092
  VDB_PAGE_MAGIC     = $5056;   // 'VP' (little endian)
  VDB_PAGE_VER       = 1;

  { Sayfa tipleri. 0 = serbest (freelist'te). }
  VDB_PAGE_FREE      = 0;
  VDB_PAGE_HEAP      = 1;   // slotted heap sayfasi (satir/anahtar hucreleri)
  VDB_PAGE_OVERFLOW  = 2;   // tasma zinciri parcasi
  VDB_PAGE_FREETRUNK = 3;   // freelist trunk sayfasi
  VDB_PAGE_META      = 4;   // veritabani basligi / kok bilgisi

  { Bir hucrenin tasiyabilecegi en buyuk bayt (tek sayfada). }
  VDB_PAGE_CELL_MAX  = VDB_PAGE_BODY_END - VDB_PAGE_HDR - SizeOf(Word) * 2;

type
  TVDbPageBuf = array[0..VDB_PAGE_SIZE - 1] of Byte;
  PVdbPage   = ^TVDbPageBuf;

  PVdbPageHdr = ^TVDbPageHdr;
  TVDbPageHdr = packed record
    Magic:      Word;      // VDB_PAGE_MAGIC
    PageType:   Byte;      // VDB_PAGE_*
    Flags:      Byte;      // bit0: tasma zinciri var
    PageNo:     LongWord;  // kendi sayfa numarasi (tutarlilik denetimi)
    SlotCount:  Word;      // slot dizinindeki slot sayisi (boslar dahil)
    FreeSpace:  Word;      // slot dizini ile govde arasindaki bos bayt
    ContentOff: Word;      // hucre govdesinin basladigi ofset
    FragBytes:  Word;      // silinmis hucrelerin kapladigi olu bayt
    Reserved1:  Word;
    Reserved2:  Word;
    LSN:        LongWord;  // sayfayi en son degistiren WAL kaydi
  end;

  PVdbPageSlot = ^TVDbPageSlot;
  TVDbPageSlot = packed record
    Off: Word;   // 0 = bos slot
    Len: Word;
  end;

{ --- temel --- }
function PageInit(P: PVdbPage; PageNo: LongWord; PageType: Byte): Boolean;

{ CRC'yi hesaplar ve son 4 bayta yazar. Her yazmadan sonra cagrilmali. }
function PageSeal(P: PVdbPage): Boolean;

{ Yapi denetimi (CRC HARIC). Her yazma isleminden sonra cagrilabilir. }
function PageCheckStruct(P: PVdbPage; out Err: string): Boolean;

{ Yapi + CRC denetimi. Sayfa diske yazilmadan once PageSeal cagrilmis
  olmalidir; bu fonksiyon okunan/saklanan sayfalar icindir. }
function PageVerify(P: PVdbPage; out Err: string): Boolean;

function PageCrcStored(P: PVdbPage): LongWord;
function PageCrcCalc(P: PVdbPage): LongWord;

{ --- okuma --- }
function PageTypeOf(P: PVdbPage): Byte;
function PageNoOf(P: PVdbPage): LongWord;
function PageSlotCount(P: PVdbPage): Integer;
function PageLiveCount(P: PVdbPage): Integer;
function PageFragBytes(P: PVdbPage): Integer;
{ Yeni bir hucre icin kullanilabilir bayt (sikistirma olmadan). }
function PageFreeBytes(P: PVdbPage): Integer;
{ Sikistirma sonrasi kullanilabilir bayt. }
function PageTotalFree(P: PVdbPage): Integer;
function PageSlotIsLive(P: PVdbPage; Slot: Integer): Boolean;

{ Hucreyi sayfa icinde gosterir (kopyalamaz). }
function PageGetCell(P: PVdbPage; Slot: Integer; out Data: PByte;
  out Len: Integer): Boolean;

{ --- yazma --- }
{ Bos slot varsa onu kullanir, yoksa slot dizinini buyutur.
  Yer yoksa False; bu durumda cagiran sayfayi bolmelidir. }
function PageInsertCell(P: PVdbPage; const Data; Len: Integer;
  out Slot: Integer): Boolean;

{ Ayni boyutta yerinde yazar. Farkli boyutta once yeni hucre ekler,
  basarili olursa eskisini siler (veri kaybi olmaz). }
function PageUpdateCell(P: PVdbPage; Slot: Integer; const Data; Len: Integer;
  out NewSlot: Integer): Boolean;

function PageDeleteCell(P: PVdbPage; Slot: Integer): Boolean;

{ Olu baytlari temizler, slot dizinini sikistirir. Crc tazelenir. }
function PageCompact(P: PVdbPage): Boolean;

{ Slot dizinini bastan yazar (kurtarma/onarim icin). Govdeye dokunmaz. }
function PageRebuildSlots(P: PVdbPage;
  const Slots: array of TVDbPageSlot): Boolean;

{ Hucre govdesini disariya kopyalar (tasma/tanimlama icin). }
function PageReadCellCopy(P: PVdbPage; Slot: Integer; out B: TBytes): Boolean;

implementation

const
  SLOT_SIZE = SizeOf(TVDbPageSlot);   // 4

function PageHdr(P: PVdbPage): PVdbPageHdr; inline;
begin
  Result := PVdbPageHdr(PByte(P));
end;

function PageSlotPtr(P: PVdbPage; Slot: Integer): PVdbPageSlot; inline;
begin
  Result := PVdbPageSlot(PByte(P) + VDB_PAGE_HDR + Slot * SLOT_SIZE);
end;

function PageMaxSlots: Integer; inline;
begin
  Result := (VDB_PAGE_BODY_END - VDB_PAGE_HDR) div SLOT_SIZE;
end;

function PageCrcCalc(P: PVdbPage): LongWord;
begin
  Result := VDbCrc32Of(P^, VDB_PAGE_BODY_END);
end;

function PageCrcStored(P: PVdbPage): LongWord;
var
  q: PLongWord;
begin
  q := PLongWord(PByte(P) + VDB_PAGE_BODY_END);
  Result := q^;
end;

function PageSeal(P: PVdbPage): Boolean;
var
  q: PLongWord;
begin
  Result := False;
  if P = nil then Exit;
  q := PLongWord(PByte(P) + VDB_PAGE_BODY_END);
  q^ := PageCrcCalc(P);
  Result := True;
end;

function PageInit(P: PVdbPage; PageNo: LongWord; PageType: Byte): Boolean;
var
  H: PVdbPageHdr;
begin
  Result := False;
  if P = nil then Exit;
  if PageType > VDB_PAGE_META then Exit;
  FillChar(P^, VDB_PAGE_SIZE, 0);
  H := PageHdr(P);
  H^.Magic := VDB_PAGE_MAGIC;
  H^.PageType := PageType;
  H^.Flags := 0;
  H^.PageNo := PageNo;
  H^.SlotCount := 0;
  H^.ContentOff := VDB_PAGE_BODY_END;
  H^.FreeSpace := VDB_PAGE_BODY_END - VDB_PAGE_HDR;
  H^.FragBytes := 0;
  H^.LSN := 0;
  Result := PageSeal(P);
end;

function PageCheckStruct(P: PVdbPage; out Err: string): Boolean;
var
  H: PVdbPageHdr;
  i, j, n, off, len, maxSlots, gapEnd: Integer;
  used: array[0..VDB_PAGE_SIZE - 1] of Boolean;
  s: PVdbPageSlot;
begin
  Result := False;
  Err := '';
  if P = nil then
  begin
    Err := 'sayfa nil';
    Exit;
  end;
  H := PageHdr(P);
  if H^.Magic <> VDB_PAGE_MAGIC then
  begin
    Err := Format('sihirli sayi bozuk: $%.4x', [H^.Magic]);
    Exit;
  end;
  if H^.PageType > VDB_PAGE_META then
  begin
    Err := Format('gecersiz sayfa tipi: %d', [H^.PageType]);
    Exit;
  end;
  maxSlots := PageMaxSlots;
  n := H^.SlotCount;
  if (n < 0) or (n > maxSlots) then
  begin
    Err := Format('slot sayisi gecersiz: %d (max %d)', [n, maxSlots]);
    Exit;
  end;
  gapEnd := VDB_PAGE_HDR + n * SLOT_SIZE;
  if (H^.ContentOff < gapEnd) or (H^.ContentOff > VDB_PAGE_BODY_END) then
  begin
    Err := Format('govde ofseti gecersiz: %d (sinir %d..%d)',
      [H^.ContentOff, gapEnd, VDB_PAGE_BODY_END]);
    Exit;
  end;
  if H^.FreeSpace <> Word(H^.ContentOff - gapEnd) then
  begin
    Err := Format('bos alan tutarsiz: yazili %d, olmasi gereken %d',
      [H^.FreeSpace, H^.ContentOff - gapEnd]);
    Exit;
  end;
  if H^.FragBytes > Word(VDB_PAGE_BODY_END - H^.ContentOff) then
  begin
    Err := Format('olu bayt gecersiz: %d', [H^.FragBytes]);
    Exit;
  end;

  FillChar(used, SizeOf(used), 0);
  for i := 0 to n - 1 do
  begin
    s := PageSlotPtr(P, i);
    if s^.Off = 0 then
    begin
      if s^.Len <> 0 then
      begin
        Err := Format('bos slot %d icin uzunluk %d', [i, s^.Len]);
        Exit;
      end;
      Continue;
    end;
    len := s^.Len;
    off := s^.Off;
    if len = 0 then
    begin
      Err := Format('slot %d uzunlugu sifir', [i]);
      Exit;
    end;
    if (off < H^.ContentOff) or (off + len > VDB_PAGE_BODY_END) then
    begin
      Err := Format('slot %d sinir disi: off=%d len=%d', [i, off, len]);
      Exit;
    end;
    for j := off to off + len - 1 do
    begin
      if used[j] then
      begin
        Err := Format('slot %d hucreleri cakisiyor (bayt %d)', [i, j]);
        Exit;
      end;
      used[j] := True;
    end;
  end;
  Result := True;
end;

function PageVerify(P: PVdbPage; out Err: string): Boolean;
begin
  Result := PageCheckStruct(P, Err);
  if not Result then Exit;
  if PageCrcCalc(P) <> PageCrcStored(P) then
  begin
    Err := 'CRC tutmadi (bozuk sayfa)';
    Result := False;
  end;
end;

function PageTypeOf(P: PVdbPage): Byte;
begin
  Result := PageHdr(P)^.PageType;
end;

function PageNoOf(P: PVdbPage): LongWord;
begin
  Result := PageHdr(P)^.PageNo;
end;

function PageSlotCount(P: PVdbPage): Integer;
begin
  Result := PageHdr(P)^.SlotCount;
end;

function PageLiveCount(P: PVdbPage): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to PageSlotCount(P) - 1 do
    if PageSlotPtr(P, i)^.Off <> 0 then Inc(Result);
end;

function PageFragBytes(P: PVdbPage): Integer;
begin
  Result := PageHdr(P)^.FragBytes;
end;

function PageFreeBytes(P: PVdbPage): Integer;
begin
  Result := PageHdr(P)^.FreeSpace;
end;

function PageTotalFree(P: PVdbPage): Integer;
begin
  Result := PageFreeBytes(P) + PageFragBytes(P);
end;

function PageSlotIsLive(P: PVdbPage; Slot: Integer): Boolean;
begin
  Result := False;
  if (Slot < 0) or (Slot >= PageSlotCount(P)) then Exit;
  Result := PageSlotPtr(P, Slot)^.Off <> 0;
end;

function PageGetCell(P: PVdbPage; Slot: Integer; out Data: PByte;
  out Len: Integer): Boolean;
var
  s: PVdbPageSlot;
begin
  Data := nil;
  Len := 0;
  Result := False;
  if (Slot < 0) or (Slot >= PageSlotCount(P)) then Exit;
  s := PageSlotPtr(P, Slot);
  if s^.Off = 0 then Exit;
  Data := PByte(P) + s^.Off;
  Len := s^.Len;
  Result := True;
end;

function PageReadCellCopy(P: PVdbPage; Slot: Integer; out B: TBytes): Boolean;
var
  d: PByte;
  n: Integer;
begin
  SetLength(B, 0);
  Result := PageGetCell(P, Slot, d, n);
  if not Result then Exit;
  SetLength(B, n);
  if n > 0 then Move(d^, B[0], n);
end;

{ Yer var mi? NeedNewSlot=True ise slot dizini 4 bayt buyuyecek. }
function PageRoomFor(P: PVdbPage; Len, NeedNewSlot: Integer): Boolean;
var
  H: PVdbPageHdr;
  gapEnd: Integer;
begin
  H := PageHdr(P);
  gapEnd := VDB_PAGE_HDR + (H^.SlotCount + NeedNewSlot) * SLOT_SIZE;
  Result := (H^.ContentOff >= gapEnd) and (H^.ContentOff - gapEnd >= Len);
end;

function PageCompact(P: PVdbPage): Boolean;
var
  H: PVdbPageHdr;
  tmp: PVdbPage;
  i, n, dst: Integer;
  s, sNew: PVdbPageSlot;
begin
  Result := False;
  if P = nil then Exit;
  H := PageHdr(P);
  if (H^.FragBytes = 0) and (PageLiveCount(P) = H^.SlotCount) then
  begin
    Result := True;   // sikistirilacak bir sey yok
    Exit;
  end;
  GetMem(tmp, VDB_PAGE_SIZE);
  try
    FillChar(tmp^, VDB_PAGE_SIZE, 0);
    Move(H^, PageHdr(tmp)^, VDB_PAGE_HDR);
    dst := VDB_PAGE_BODY_END;
    { DIKKAT: slot indeksleri KARARLIDIR. Sikistirma yalnizca govdeyi
      yeniden paketler; slot i her zaman ayni hucreyi gosterir. Ust
      katman (heap) slot indeksi tutabilir. }
    n := H^.SlotCount;
    for i := 0 to n - 1 do
    begin
      s := PageSlotPtr(P, i);
      sNew := PageSlotPtr(tmp, i);
      if s^.Off = 0 then
      begin
        sNew^.Off := 0;
        sNew^.Len := 0;
        Continue;
      end;
      Dec(dst, s^.Len);
      Move((PByte(P) + s^.Off)^, (PByte(tmp) + dst)^, s^.Len);
      sNew^.Off := dst;
      sNew^.Len := s^.Len;
    end;
    PageHdr(tmp)^.ContentOff := dst;
    PageHdr(tmp)^.FragBytes := 0;
    PageHdr(tmp)^.FreeSpace := dst - (VDB_PAGE_HDR + n * SLOT_SIZE);
    { Govdeyi ve basligi geri yaz (CRC haric; PageSeal tazeler). }
    Move(tmp^, P^, VDB_PAGE_BODY_END);
    Result := PageSeal(P);
  finally
    FreeMem(tmp);
  end;
end;

function PageInsertCell(P: PVdbPage; const Data; Len: Integer;
  out Slot: Integer): Boolean;
var
  H: PVdbPageHdr;
  i, freeSlot, newOff, needSlot: Integer;
begin
  Result := False;
  Slot := -1;
  if P = nil then Exit;
  if (Len <= 0) or (Len > VDB_PAGE_CELL_MAX) then Exit;
  H := PageHdr(P);

  { Bos slot var mi? }
  freeSlot := -1;
  for i := 0 to H^.SlotCount - 1 do
    if PageSlotPtr(P, i)^.Off = 0 then
    begin
      freeSlot := i;
      Break;
    end;
  if freeSlot >= 0 then needSlot := 0 else needSlot := 1;

  if not PageRoomFor(P, Len, needSlot) then
  begin
    { O once sikistirmayi dene. }
    if H^.FragBytes > 0 then
    begin
      if not PageCompact(P) then Exit;
      H := PageHdr(P);
      if not PageRoomFor(P, Len, needSlot) then Exit;
    end
    else
      Exit;
  end;

  newOff := H^.ContentOff - Len;
  if newOff < VDB_PAGE_HDR + (H^.SlotCount + needSlot) * SLOT_SIZE then Exit;
  Move(Data, (PByte(P) + newOff)^, Len);
  H^.ContentOff := newOff;

  if needSlot = 1 then
  begin
    Slot := H^.SlotCount;
    Inc(H^.SlotCount);
  end
  else
    Slot := freeSlot;

  PageSlotPtr(P, Slot)^.Off := newOff;
  PageSlotPtr(P, Slot)^.Len := Len;
  H^.FreeSpace := H^.ContentOff - (VDB_PAGE_HDR + H^.SlotCount * SLOT_SIZE);
  Result := True;
end;

function PageUpdateCell(P: PVdbPage; Slot: Integer; const Data; Len: Integer;
  out NewSlot: Integer): Boolean;
var
  s: PVdbPageSlot;
begin
  NewSlot := Slot;
  Result := False;
  if P = nil then Exit;
  if (Slot < 0) or (Slot >= PageSlotCount(P)) then Exit;
  s := PageSlotPtr(P, Slot);
  if s^.Off = 0 then Exit;
  if Len = s^.Len then
  begin
    Move(Data, (PByte(P) + s^.Off)^, Len);
    Result := True;
    Exit;
  end;
  { Farkli boyut: once yeni hucreyi ekle, basariliysa eskisini sil. }
  if not PageInsertCell(P, Data, Len, NewSlot) then
  begin
    NewSlot := Slot;
    Exit;
  end;
  PageDeleteCell(P, Slot);
  Result := True;
end;

function PageDeleteCell(P: PVdbPage; Slot: Integer): Boolean;
var
  H: PVdbPageHdr;
  s: PVdbPageSlot;
begin
  Result := False;
  if P = nil then Exit;
  if (Slot < 0) or (Slot >= PageSlotCount(P)) then Exit;
  s := PageSlotPtr(P, Slot);
  if s^.Off = 0 then Exit;
  H := PageHdr(P);
  Inc(H^.FragBytes, s^.Len);
  s^.Off := 0;
  s^.Len := 0;
  { Sondaki bos slotlari kirp (slot dizini buyumesin). }
  while (H^.SlotCount > 0) and
        (PageSlotPtr(P, H^.SlotCount - 1)^.Off = 0) do
    Dec(H^.SlotCount);
  H^.FreeSpace := H^.ContentOff -
    (VDB_PAGE_HDR + H^.SlotCount * SLOT_SIZE);
  Result := True;
end;

function PageRebuildSlots(P: PVdbPage;
  const Slots: array of TVDbPageSlot): Boolean;
var
  i, n: Integer;
begin
  Result := False;
  n := Length(Slots);
  if n > PageMaxSlots then Exit;
  PageHdr(P)^.SlotCount := n;
  for i := 0 to n - 1 do
    PageSlotPtr(P, i)^ := Slots[i];
  PageHdr(P)^.FreeSpace := PageHdr(P)^.ContentOff -
    (VDB_PAGE_HDR + n * SLOT_SIZE);
  Result := True;
end;

end.
