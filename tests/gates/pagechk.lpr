program pagechk;

{ VDB v3 - Sayfa cekirdegi dogrulama (Sprint 1 / Gun 1 kabul kapisi)

  Yapar:
    1) 8 sayfa uzerinde 100.000 rastgele ekle/sil/guncelle/sikistir islemi.
       Her islemden sonra sayfa yapisi + CRC denetlenir.
    2) Referans model: her sayfa icin slot -> (canli, baytlar). Sonda
       sayfadaki canli slotlarla referans BIREBIR karsilastirilir.
    3) Sayfa dolana kadar ekleme; tasma yok, veri kaybi yok.
    4) Bozulma testi: tek bayt degisince PageVerify HATA vermeli.
    5) Sikistirma testi: silinen baytlar PageCompact ile geri kazanilmali.

  Cikis kodu: 0 = hepsi gecti, 1 = en az bir hata.

  Kullanim: pagechk [islem_sayisi] [sayfa_sayisi]
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, VDbPage;

const
  DEF_OPS    = 100000;
  DEF_PAGES  = 8;

type
  TRefCell = record
    Live: Boolean;
    Data: TBytes;
  end;
  TRefPage = record
    Cells: array of TRefCell;
    Inited: Boolean;
  end;

var
  gSeed: LongWord;
  gPass, gFail: Int64;

procedure Say(const S: string);
begin
  WriteLn(S);
end;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function Rnd: LongWord;
begin
  { xorshift32 — deterministik, tekrar uretilebilir. }
  gSeed := gSeed xor (gSeed shl 13);
  gSeed := gSeed xor (gSeed shr 17);
  gSeed := gSeed xor (gSeed shl 5);
  Result := gSeed;
end;

function RndRange(N: Integer): Integer;
begin
  if N <= 0 then Exit(0);
  Result := Integer(Rnd mod LongWord(N));
end;

procedure FillRandom(var B: TBytes; Len: Integer);
var
  i: Integer;
begin
  SetLength(B, Len);
  for i := 0 to Len - 1 do
    B[i] := Byte(Rnd and $FF);
end;

{ --- referans model --- }

procedure RefReset(var R: TRefPage);
begin
  SetLength(R.Cells, 0);
  R.Inited := True;
end;

procedure RefEnsure(var R: TRefPage; N: Integer);
var
  i, old: Integer;
begin
  old := Length(R.Cells);
  if N <= old then Exit;
  SetLength(R.Cells, N);
  for i := old to N - 1 do
  begin
    R.Cells[i].Live := False;
    SetLength(R.Cells[i].Data, 0);
  end;
end;

function RefLiveCount(const R: TRefPage): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(R.Cells) do
    if R.Cells[i].Live then Inc(Result);
end;

function RefPickLive(var R: TRefPage; out Slot: Integer): Boolean;
var
  i, n, k: Integer;
begin
  Result := False;
  Slot := -1;
  n := RefLiveCount(R);
  if n = 0 then Exit;
  k := RndRange(n);
  for i := 0 to High(R.Cells) do
    if R.Cells[i].Live then
    begin
      if k = 0 then
      begin
        Slot := i;
        Exit(True);
      end;
      Dec(k);
    end;
end;

{ Sayfadaki canli slotlari referansla karsilastirir. Fark varsa Err dolu. }
function ComparePage(P: PVdbPage; var R: TRefPage; out Err: string): Boolean;
var
  i, n, nRef: Integer;
  d: PByte;
  len: Integer;
begin
  Result := False;
  Err := '';
  n := PageSlotCount(P);
  nRef := Length(R.Cells);
  if n > nRef then
  begin
    Err := Format('sayfada %d slot var, referansta %d', [n, nRef]);
    Exit;
  end;
  for i := 0 to nRef - 1 do
  begin
    if i >= n then
    begin
      if R.Cells[i].Live then
      begin
        Err := Format('slot %d sayfada yok ama referansta canli', [i]);
        Exit;
      end;
      Continue;
    end;
    if PageSlotIsLive(P, i) <> R.Cells[i].Live then
    begin
      Err := Format('slot %d canlilik farki: sayfa=%s referans=%s',
        [i, BoolToStr(PageSlotIsLive(P, i), True),
             BoolToStr(R.Cells[i].Live, True)]);
      Exit;
    end;
    if not R.Cells[i].Live then Continue;
    if not PageGetCell(P, i, d, len) then
    begin
      Err := Format('slot %d okunamadi (canli olmaliydi)', [i]);
      Exit;
    end;
    if len <> Length(R.Cells[i].Data) then
    begin
      Err := Format('slot %d uzunluk farki: sayfa=%d referans=%d',
        [i, len, Length(R.Cells[i].Data)]);
      Exit;
    end;
    if (len > 0) and not CompareMem(d, @R.Cells[i].Data[0], len) then
    begin
      Err := Format('slot %d icerik farki', [i]);
      Exit;
    end;
  end;
  Result := True;
end;

function CheckPage(P: PVdbPage; var R: TRefPage; const Etiket: string): Boolean;
var
  e: string;
begin
  Result := False;
  if not PageVerify(P, e) then
  begin
    Fail(Etiket + ': sayfa gecersiz — ' + e);
    Exit;
  end;
  if not ComparePage(P, R, e) then
  begin
    Fail(Etiket + ': referans farki — ' + e);
    Exit;
  end;
  Ok(Etiket + ': sayfa gecerli, referans birebir');
  Result := True;
end;

{ --- 1) rastgele islemler --- }

procedure TestRandom(Ops, NumPages: Integer);
var
  pages: array of PVdbPage;
  refs: array of TRefPage;
  i, p, len, slot, newSlot, nIns, nDel, nUpd, nFull, nComp, nVer: Integer;
  b: TBytes;
  e: string;
  page: PVdbPage;
  ref: TRefPage;
  op: Integer;
begin
  SetLength(pages, NumPages);
  SetLength(refs, NumPages);
  for i := 0 to NumPages - 1 do
  begin
    GetMem(pages[i], VDB_PAGE_SIZE);
    PageInit(pages[i], LongWord(i), VDB_PAGE_HEAP);
    RefReset(refs[i]);
  end;
  nIns := 0; nDel := 0; nUpd := 0; nFull := 0; nComp := 0; nVer := 0;

  for i := 1 to Ops do
  begin
    p := RndRange(NumPages);
    page := pages[p];
    op := RndRange(100);
    if op < 45 then
    begin
      { ekle }
      len := 1 + RndRange(400);
      FillRandom(b, len);
      if PageInsertCell(page, b[0], len, slot) then
      begin
        RefEnsure(refs[p], slot + 1);
        refs[p].Cells[slot].Live := True;
        refs[p].Cells[slot].Data := Copy(b);
        Inc(nIns);
      end
      else
        Inc(nFull);
    end
    else if op < 70 then
    begin
      { sil }
      if RefPickLive(refs[p], slot) then
      begin
        if not PageDeleteCell(page, slot) then
          Fail(Format('islem %d: silme basarisiz (sayfa %d slot %d)', [i, p, slot]));
        refs[p].Cells[slot].Live := False;
        SetLength(refs[p].Cells[slot].Data, 0);
        Inc(nDel);
      end;
    end
    else if op < 92 then
    begin
      { guncelle }
      if RefPickLive(refs[p], slot) then
      begin
        if RndRange(2) = 0 then
          len := Length(refs[p].Cells[slot].Data)   // ayni boyut: yerinde
        else
          len := 1 + RndRange(400);
        FillRandom(b, len);
        if PageUpdateCell(page, slot, b[0], len, newSlot) then
        begin
          RefEnsure(refs[p], newSlot + 1);
          if newSlot <> slot then
            refs[p].Cells[slot].Live := False;
          refs[p].Cells[newSlot].Live := True;
          refs[p].Cells[newSlot].Data := Copy(b);
          Inc(nUpd);
        end;
      end;
    end
    else if op < 97 then
    begin
      { sikistir }
      if not PageCompact(page) then
        Fail(Format('islem %d: PageCompact basarisiz (sayfa %d)', [i, p]));
      Inc(nComp);
    end
    else
    begin
      Inc(nVer);
    end;

    if not PageCheckStruct(page, e) then
    begin
      Fail(Format('islem %d: sayfa %d bozuldu — %s', [i, p, e]));
      Break;
    end;
  end;

  { Sonda: sayfalari muhurle (CRC) ve referansla birebir karsilastir. }
  for i := 0 to NumPages - 1 do
    PageSeal(pages[i]);
  for i := 0 to NumPages - 1 do
    if not CheckPage(pages[i], refs[i], Format('rastgele/son sayfa %d', [i])) then
      Break;

  Ok(Format('rastgele: %d islem (ekle=%d sil=%d guncelle=%d dolu=%d sikistir=%d dogrula=%d)',
    [Ops, nIns, nDel, nUpd, nFull, nComp, nVer]));

  for i := 0 to NumPages - 1 do
    FreeMem(pages[i]);
end;

{ --- 2) sayfayi doldur --- }

procedure TestFill;
var
  page: PVdbPage;
  ref: TRefPage;
  b: TBytes;
  slot, n, cap: Integer;
  e: string;
  total: Integer;
begin
  GetMem(page, VDB_PAGE_SIZE);
  PageInit(page, 999, VDB_PAGE_HEAP);
  RefReset(ref);
  n := 0;
  total := 0;
  while True do
  begin
    SetLength(b, 100);
    FillChar(b[0], 100, Byte(n and $FF));
    if not PageInsertCell(page, b[0], 100, slot) then Break;
    RefEnsure(ref, slot + 1);
    ref.Cells[slot].Live := True;
    ref.Cells[slot].Data := Copy(b);
    Inc(n);
    Inc(total, 100);
  end;
  cap := PageTotalFree(page);
  PageSeal(page);
  if n < 30 then
    Fail(Format('doldurma: cok az hucre sigdi (%d)', [n]))
  else
    Ok(Format('doldurma: 100 baytlik %d hucre sigdi (%d bayt veri, kalan bos %d)',
      [n, total, cap]));
  if not CheckPage(page, ref, 'doldurma') then
    Say('   (doldurma karsilastirmasi basarisiz)');
  { Doluyken ekleme denemesi veri bozmamali. }
  SetLength(b, 100);
  FillChar(b[0], 100, $AA);
  if PageInsertCell(page, b[0], 100, slot) then
    Fail('doldurma: dolu sayfaya ekleme basarili oldu (beklenmiyordu)')
  else
    Ok('doldurma: dolu sayfada ekleme reddedildi');
  PageSeal(page);
  if not CheckPage(page, ref, 'doldurma/dolu') then
    Say('   (dolu sayfa karsilastirmasi basarisiz)');
  FreeMem(page);
end;

{ --- 3) bozulma --- }

procedure TestCorruption;
var
  page, copyPage: PVdbPage;
  b: TBytes;
  slot: Integer;
  e: string;
  i: Integer;
  caught: Integer;
begin
  GetMem(page, VDB_PAGE_SIZE);
  GetMem(copyPage, VDB_PAGE_SIZE);
  PageInit(page, 7, VDB_PAGE_HEAP);
  for i := 1 to 5 do
  begin
    SetLength(b, 20 + i);
    FillChar(b[0], Length(b), Byte(i * 7));
    if not PageInsertCell(page, b[0], Length(b), slot) then
      Fail('bozulma: kurulum eklemesi basarisiz');
  end;
  PageSeal(page);
  caught := 0;
  { Baslik, slot dizini ve govde bolgelerinden birer bayt boz. }
  for i := 0 to 3 do
  begin
    Move(page^, copyPage^, VDB_PAGE_SIZE);
    case i of
      0: copyPage^[0] := copyPage^[0] xor $FF;        // sihirli sayi
      1: copyPage^[VDB_PAGE_HDR] :=
           copyPage^[VDB_PAGE_HDR] xor $FF;            // slot dizini
      2: copyPage^[VDB_PAGE_BODY_END - 1] :=
           copyPage^[VDB_PAGE_BODY_END - 1] xor $FF;   // govde sonu
      3: copyPage^[VDB_PAGE_BODY_END] :=
           copyPage^[VDB_PAGE_BODY_END] xor $FF;       // CRC
    end;
    if not PageVerify(copyPage, e) then Inc(caught);
  end;
  if caught = 4 then
    Ok('bozulma: 4/4 bolgede bozulma yakalandi')
  else
    Fail(Format('bozulma: yalniz %d/4 bozulma yakalandi', [caught]));
  if PageVerify(page, e) then
    Ok('bozulma: bozulmamis sayfa saglam')
  else
    Fail('bozulma: saglam sayfa reddedildi — ' + e);
  FreeMem(copyPage);
  FreeMem(page);
end;

{ --- 4) sikistirma --- }

procedure TestCompact;
var
  page: PVdbPage;
  b: TBytes;
  slot, i, before, after, n, len: Integer;
  e: string;
  p2: PByte;
begin
  GetMem(page, VDB_PAGE_SIZE);
  PageInit(page, 3, VDB_PAGE_HEAP);
  n := 0;
  for i := 1 to 40 do
  begin
    SetLength(b, 60);
    FillChar(b[0], 60, Byte(i));
    if not PageInsertCell(page, b[0], 60, slot) then Break;
    Inc(n);
  end;
  for i := 0 to n - 1 do
    if Odd(i) then PageDeleteCell(page, i);
  before := PageFreeBytes(page);
  if PageFragBytes(page) <= 0 then
    Fail('sikistirma: silme sonrasi olu bayt olusmadi')
  else
    Ok(Format('sikistirma: silme sonrasi olu bayt %d', [PageFragBytes(page)]));
  if not PageCompact(page) then
    Fail('sikistirma: PageCompact basarisiz');
  after := PageFreeBytes(page);
  if PageFragBytes(page) <> 0 then
    Fail('sikistirma: olu bayt sifirlanmadi')
  else if after < before + 60 * (n div 2) - 8 then
    Fail(Format('sikistirma: bos alan beklenen kadar artmadi (%d -> %d)', [before, after]))
  else
    Ok(Format('sikistirma: bos alan %d -> %d', [before, after]));
  { Sikistirma sonrasi hucreler dogru mu? }
  if not PageVerify(page, e) then
    Fail('sikistirma: sayfa gecersiz — ' + e)
  else
  begin
    Ok('sikistirma: sayfa gecerli');
    { Slot indeksleri KARARLI: eski 2k numarali slot hala ayni indekste,
      yalnizca govde yeniden paketlendi (ilk bayt = 2k+1). }
    n := 0;
    for i := 0 to 39 do
    begin
      if not Odd(i) then
      begin
        if not PageGetCell(page, i, p2, len) then
        begin
          Fail(Format('sikistirma: canli slot %d okunamadi', [i]));
          Break;
        end;
        if (len <> 60) or (p2^ <> Byte(i + 1)) then
        begin
          Fail(Format('sikistirma: slot %d icerigi yanlis (len=%d, ilk=%d)',
            [i, len, p2^]));
          Break;
        end;
        Inc(n);
      end
      else if PageSlotIsLive(page, i) then
      begin
        Fail(Format('sikistirma: silinmis slot %d canli gorunuyor', [i]));
        Break;
      end;
    end;
    if n = 20 then
      Ok('sikistirma: 20 canli hucre ayni slot indeksinde korundu');
  end;
  FreeMem(page);
end;

{ --- 5) yapisal sabitler --- }

procedure TestLayout;
begin
  if SizeOf(TVDbPageHdr) <> VDB_PAGE_HDR then
    Fail(Format('yerlesim: baslik %d bayt (beklenen %d)',
      [SizeOf(TVDbPageHdr), VDB_PAGE_HDR]))
  else
    Ok(Format('yerlesim: baslik %d bayt, slot %d bayt, sayfa %d bayt',
      [VDB_PAGE_HDR, SizeOf(TVDbPageSlot), VDB_PAGE_SIZE]));
  if SizeOf(TVDbPageBuf) <> VDB_PAGE_SIZE then
    Fail('yerlesim: TVDbPageBuf boyu yanlis')
  else
    Ok('yerlesim: TVDbPageBuf 4096 bayt');
end;

var
  Ops, NumPages: Integer;
begin
  gPass := 0;
  gFail := 0;
  gSeed := $12345678;
  Ops := StrToIntDef(ParamStr(1), DEF_OPS);
  NumPages := StrToIntDef(ParamStr(2), DEF_PAGES);
  if NumPages < 1 then NumPages := 1;

  Say('VDB v3 pagechk - sayfa cekirdegi dogrulama');
  Say(Format('islem=%d sayfa=%d tohum=$%.8x', [Ops, NumPages, gSeed]));
  Say('');

  TestLayout;
  TestFill;
  TestCorruption;
  TestCompact;
  TestRandom(Ops, NumPages);

  Say('');
  Say('================================================');
  Say(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
    Say('SAYFA CEKIRDEGI DOGRULANDI')
  else
    Say('SAYFA CEKIRDEGI HATALI');
  if gFail <> 0 then
    Halt(1);
end.
