unit VDbPageHeap;

{ VDB v3 - Slotted Heap (Sprint 1 / Gun 3-4)

  Anahtar -> deger eslemesini sayfa tabanli depo uzerinde tutar.
  Anahtar QWord (v2'deki PK/kolon anahtari ile ayni sozlesme).

  Hucre bicimi (sayfa icinde):
    Key      : QWord
    Len      : LongWord   (bit31 = tasma bayragi)
    [veri]                Len bayt          (tasma yoksa)
    [ilkTasmaSayfasi]     LongWord          (tasma varsa)

  Hucre basligi 12 bayt. v2'de satir basina ~62 bayt ek yuk vardi;
  burada 12 bayt + slot 4 bayt = 16 bayt, sayfa basligi amortize.

  Tasma: MAX_INLINE'dan buyuk degerler zincir sayfalarina bolunur.
  Zincir sayfalari VDbPage formatindadir (tip VDB_PAGE_OVERFLOW, tek
  hucre: ilk 4 bayt sonraki sayfa numarasi, gerisi veri). Boylece
  tasma sayfalari da CRC ile korunur ve yapi denetiminden gecer.

  Dizin: key -> (sayfa, slot) BELLEKTE acik adresleme tablosu. Acilista
  tum heap sayfalari taranarak kurulur. Sprint 1.10'da ayni bilgi
  .odb.idx yan dosyasindan hizli yuklenecek; tarama yalniz yedek yol
  olarak kalacak.

  Bilincli sinirlar:
  - Tek yazici; thread guvenligi cagirana ait.
  - Anahtar sirasi YOK (aralik sorgusu v3.1 / B+tree).
  - Sayfa ici silme O(1); bosalan SAYFA freelist'e doner.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, VDbPage, VDbPageStore;

const
  VDB_CELL_HDR      = 12;
  VDB_OVF_FLAG      = $80000000;
  VDB_LEN_MASK      = $7FFFFFFF;   // tasma bayragi disindaki uzunluk
  VDB_MAX_INLINE    = 1000;   // bundan buyuk degerler tasma zincirine
  VDB_OVF_CHUNK     = 4000;   // zincir sayfasi basina veri bayti

var
  { Tanilama: True ise heap katmani adim adim iz birakir. }
  VDB_HEAP_TRACE: Boolean = False;

type
  EVdbHeap = class(Exception);

  TVdbHeapStats = record
    Keys: Integer;
    HeapPages: LongWord;
    OverflowPages: LongWord;
    DirCapacity: LongWord;
    DirLoad: Double;
    BytesPerKey: Double;
  end;

  TVdbHeap = class
  public
    type
      TLoc = packed record
        PageNo: LongWord;
        Slot: Word;
      end;
      TScanProc = procedure(Key: QWord; const Value: TBytes) of object;
  private
    FStore: TVDbPageStore;
    FKey: array of QWord;
    FLoc: array of TLoc;
    FUsed: array of Byte;
    FCap: LongWord;
    FCount: Integer;
    FWritePage: LongWord;
    FHeapPages: LongWord;
    FOvfPages: LongWord;
    FLastErr: string;
    function DirHash(K: QWord): LongWord;
    function DirFind(K: QWord; out Idx: LongWord): Boolean;
    procedure DirGrow;
    procedure DirAdd(K: QWord; const L: TLoc);
    function DirDel(K: QWord): Boolean;
    procedure DirReset;
    procedure PlaceCell(const Cell; CellLen: Integer;
      out L: TLoc);
    function BuildCell(Key: QWord; const Value: TBytes;
      out Cell: TBytes): Boolean;
    procedure WriteOverflow(const Value: TBytes; out FirstPage: LongWord);
    function ReadOverflow(FirstPage: LongWord; Len: Integer;
      out Value: TBytes): Boolean;
    procedure FreeOverflow(FirstPage: LongWord);
    function ReadCellAt(const L: TLoc; out Key: QWord; out Value: TBytes): Boolean;
    function DeleteAt(const L: TLoc; out FreedPage: Boolean): Boolean;
    function InsertRaw(Key: QWord; const Value: TBytes; out L: TLoc): Boolean;
  public
    constructor Create(AStore: TVDbPageStore);
    { Tum heap sayfalarini tarayip dizini kurar. }
    procedure Open;

    { Yeni anahtar ekler. Anahtar zaten varsa False. }
    function Insert(Key: QWord; const Value: TBytes): Boolean;
    { Var olan anahtari gunceller. Anahtar yoksa False. }
    function Update(Key: QWord; const Value: TBytes): Boolean;
    function Delete(Key: QWord): Boolean;
    function TryGet(Key: QWord; out Value: TBytes): Boolean;
    function Contains(Key: QWord): Boolean;

    { Tum kayitlari gezer (sayfa sirasi; anahtar sirasi garantisi YOK). }
    procedure ScanAll(Cb: TScanProc);

    procedure Flush(DoSync: Boolean = True);
    function Stats: TVdbHeapStats;

    property Count: Integer read FCount;
    property Store: TVDbPageStore read FStore;
    { Son basarisiz okumanin nedeni (tanilama icin). }
    property LastError: string read FLastErr;
  end;

implementation

{ ============================================================ bellek dizini }

function TVdbHeap.DirHash(K: QWord): LongWord;
begin
  { karisim: ust ve alt 32 biti birlestir, sonra fibonacci carpimi }
  Result := LongWord((K xor (K shr 32)) and $FFFFFFFF) * LongWord(2654435761);
  Result := Result and (FCap - 1);
end;

function TVdbHeap.DirFind(K: QWord; out Idx: LongWord): Boolean;
var
  h: LongWord;
  guard: LongWord;
begin
  Result := False;
  Idx := 0;
  if FCap = 0 then Exit;
  h := DirHash(K);
  guard := 0;
  while FUsed[h] <> 0 do
  begin
    if (FUsed[h] = 1) and (FKey[h] = K) then
    begin
      Idx := h;
      Exit(True);
    end;
    h := (h + 1) and (FCap - 1);
    Inc(guard);
    if guard > FCap then
    begin
      FLastErr := Format('dizin arama dongusu (cap=%d, count=%d)', [FCap, FCount]);
      Exit(False);
    end;
  end;
end;

procedure TVdbHeap.DirGrow;
var
  oldKey: array of QWord;
  oldLoc: array of TLoc;
  oldUsed: array of Byte;
  oldCap: LongWord;
  i: LongWord;
begin
  oldKey := FKey;
  oldLoc := FLoc;
  oldUsed := FUsed;
  oldCap := FCap;
  if FCap = 0 then FCap := 256 else FCap := FCap * 2;
  SetLength(FKey, FCap);
  SetLength(FLoc, FCap);
  SetLength(FUsed, FCap);
  { DIKKAT: SetLength buyuturken eski baytlari KORUR. Yeni tabloda
    eski dolu isaretleri kalirsa hem yinelenen kayit olur hem de sondalama
    zinciri kapanarak sonsuz donguye girer. Bu yuzden acikca sifirla. }
  FillChar(FUsed[0], FCap, 0);
  FCount := 0;
  if oldCap > 0 then
    for i := 0 to oldCap - 1 do
      if oldUsed[i] = 1 then
        DirAdd(oldKey[i], oldLoc[i]);
end;

procedure TVdbHeap.DirAdd(K: QWord; const L: TLoc);
var
  h: LongWord;
  guard: LongWord;
begin
  if (FCap = 0) or ((FCount + 1) * 4 > Integer(FCap) * 3) then
    DirGrow;
  h := DirHash(K);
  guard := 0;
  while FUsed[h] = 1 do
  begin
    h := (h + 1) and (FCap - 1);
    Inc(guard);
    if guard > FCap then
      raise EVdbHeap.Create(Format(
        'dizin ekleme dongusu (cap=%d, count=%d)', [FCap, FCount]));
  end;
  FUsed[h] := 1;
  FKey[h] := K;
  FLoc[h] := L;
  Inc(FCount);
end;

function TVdbHeap.DirDel(K: QWord): Boolean;
var
  h: LongWord;
begin
  Result := False;
  if not DirFind(K, h) then Exit;
  { Tombstone: silme sirasinda zinciri koparmamak icin 2 = olu. }
  FUsed[h] := 2;
  Dec(FCount);
  Result := True;
end;

procedure TVdbHeap.DirReset;
begin
  if FCap > 0 then
    FillChar(FUsed[0], FCap, 0);
  FCount := 0;
end;

{ ================================================================== tasma }

procedure TVdbHeap.WriteOverflow(const Value: TBytes; out FirstPage: LongWord);
var
  total, nChunks, i, ofs, chunk, slot: Integer;
  pageNo, nextNo: LongWord;
  P: PVdbPage;
  cell: TBytes;
begin
  total := Length(Value);
  nChunks := (total + VDB_OVF_CHUNK - 1) div VDB_OVF_CHUNK;
  if nChunks < 1 then nChunks := 1;
  nextNo := 0;
  FirstPage := 0;
  { Sondan basa yaz: her sayfa bir sonrakini bilir, tek pin yeter. }
  for i := nChunks - 1 downto 0 do
  begin
    ofs := i * VDB_OVF_CHUNK;
    chunk := total - ofs;
    if chunk > VDB_OVF_CHUNK then chunk := VDB_OVF_CHUNK;
    if chunk < 0 then chunk := 0;
    if not FStore.AllocPage(VDB_PAGE_OVERFLOW, pageNo, P) then
      raise EVdbHeap.Create('tasma sayfasi ayrilamadi');
    Inc(FOvfPages);
    SetLength(cell, 4 + chunk);
    Move(nextNo, cell[0], 4);
    if chunk > 0 then
      Move(Value[ofs], cell[4], chunk);
    if not PageInsertCell(P, cell[0], Length(cell), slot) then
    begin
      FStore.Release(pageNo, False);
      FStore.FreePage(pageNo);
      Dec(FOvfPages);
      raise EVdbHeap.Create('tasma sayfasina sigmadi (ic hata)');
    end;
    FStore.Release(pageNo, True);
    nextNo := pageNo;
  end;
  FirstPage := nextNo;
end;

function TVdbHeap.ReadOverflow(FirstPage: LongWord; Len: Integer;
  out Value: TBytes): Boolean;
var
  pageNo, nextNo: LongWord;
  P: PVdbPage;
  d: PByte;
  dl, got, take: Integer;
  e: string;
begin
  Result := False;
  FLastErr := '';
  SetLength(Value, 0);
  if Len <= 0 then
  begin
    Result := True;
    Exit;
  end;
  SetLength(Value, Len);
  got := 0;
  pageNo := FirstPage;
  if pageNo = 0 then
  begin
    FLastErr := 'tasma zinciri bos (ilk sayfa 0)';
    Exit;
  end;
  while pageNo <> 0 do
  begin
    if not FStore.GetPage(pageNo, P) then
    begin
      FLastErr := Format('tasma sayfasi %d okunamadi', [pageNo]);
      Exit;
    end;
    if not PageCheckStruct(P, e) then
    begin
      FStore.Release(pageNo, False);
      FLastErr := Format('tasma sayfasi %d yapisi bozuk: %s', [pageNo, e]);
      Exit;
    end;
    if PageTypeOf(P) <> VDB_PAGE_OVERFLOW then
    begin
      FStore.Release(pageNo, False);
      FLastErr := Format('sayfa %d tasma sayfasi degil (tip %d)',
        [pageNo, PageTypeOf(P)]);
      Exit;
    end;
    if not PageGetCell(P, 0, d, dl) then
    begin
      FStore.Release(pageNo, False);
      FLastErr := Format('tasma sayfasi %d hucre 0 yok', [pageNo]);
      Exit;
    end;
    if dl < 4 then
    begin
      FStore.Release(pageNo, False);
      FLastErr := Format('tasma sayfasi %d hucre cok kisa (%d)', [pageNo, dl]);
      Exit;
    end;
    Move(d^, nextNo, 4);
    take := dl - 4;
    if got + take > Len then take := Len - got;
    if take > 0 then
      Move((d + 4)^, Value[got], take);
    Inc(got, take);
    FStore.Release(pageNo, False);
    pageNo := nextNo;
  end;
  Result := got = Len;
  if not Result then
    FLastErr := Format('tasma eksik: %d/%d bayt', [got, Len]);
end;

procedure TVdbHeap.FreeOverflow(FirstPage: LongWord);
var
  pageNo, nextNo: LongWord;
  P: PVdbPage;
  d: PByte;
  dl: Integer;
begin
  pageNo := FirstPage;
  while pageNo <> 0 do
  begin
    if not FStore.GetRawPage(pageNo, P) then Exit;
    nextNo := 0;
    if PageGetCell(P, 0, d, dl) and (dl >= 4) then
      Move(d^, nextNo, 4);
    FStore.Release(pageNo, False);
    FStore.FreePage(pageNo);
    if FOvfPages > 0 then Dec(FOvfPages);
    pageNo := nextNo;
  end;
end;

{ =================================================================== hucre }

function TVdbHeap.BuildCell(Key: QWord; const Value: TBytes;
  out Cell: TBytes): Boolean;
var
  len: LongWord;
  zero: LongWord;
begin
  Result := False;
  len := Length(Value);
  zero := 0;
  if len > VDB_MAX_INLINE then
  begin
    { Tasma: hucre yalnizca anahtar + bayrakli uzunluk + ilk sayfa. }
    SetLength(Cell, VDB_CELL_HDR + 4);
    Move(Key, Cell[0], 8);
    len := len or VDB_OVF_FLAG;
    Move(len, Cell[8], 4);
    Move(zero, Cell[VDB_CELL_HDR], 4);
    Result := True;
    Exit;
  end;
  SetLength(Cell, VDB_CELL_HDR + Integer(len));
  Move(Key, Cell[0], 8);
  Move(len, Cell[8], 4);
  if len > 0 then
    Move(Value[0], Cell[VDB_CELL_HDR], len);
  Result := True;
end;

procedure TVdbHeap.PlaceCell(const Cell; CellLen: Integer; out L: TLoc);
var
  pageNo: LongWord;
  P: PVdbPage;
  slot: Integer;
  tries: Integer;
begin
  { Once son yazma sayfasini dene, sonra yeni sayfa ayir. }
  tries := 0;
  while True do
  begin
    Inc(tries);
    if VDB_HEAP_TRACE then
    begin
      WriteLn(Format('        trace: PlaceCell tur=%d sayfa=%d hucre=%d',
        [tries, FWritePage, CellLen]));
      System.Flush(Output);
    end;
    if tries > 64 then
      raise EVdbHeap.Create(Format(
        'PlaceCell: 64 denemede yazilamadi (hucre=%d bayt, son sayfa=%d)',
        [CellLen, FWritePage]));
    if FWritePage <> 0 then
    begin
      if not FStore.GetPage(FWritePage, P) then
        raise EVdbHeap.Create('yazma sayfasi okunamadi');
      if PageInsertCell(P, Cell, CellLen, slot) then
      begin
        FStore.Release(FWritePage, True);
        L.PageNo := FWritePage;
        L.Slot := slot;
        Exit;
      end;
      FStore.Release(FWritePage, False);
    end;
    if not FStore.AllocPage(VDB_PAGE_HEAP, pageNo, P) then
      raise EVdbHeap.Create('heap sayfasi ayrilamadi');
    Inc(FHeapPages);
    FWritePage := pageNo;
    FStore.Release(pageNo, True);
  end;
end;

function TVdbHeap.ReadCellAt(const L: TLoc; out Key: QWord;
  out Value: TBytes): Boolean;
var
  P: PVdbPage;
  d: PByte;
  dl: Integer;
  len: LongWord;
  first: LongWord;
  ovf: Boolean;
begin
  Result := False;
  SetLength(Value, 0);
  if not FStore.GetPage(L.PageNo, P) then Exit;
  if not PageGetCell(P, L.Slot, d, dl) then
  begin
    FStore.Release(L.PageNo, False);
    Exit;
  end;
  if dl < VDB_CELL_HDR then
  begin
    FStore.Release(L.PageNo, False);
    Exit;
  end;
  Move(d^, Key, 8);
  Move((d + 8)^, len, 4);
  ovf := (len and VDB_OVF_FLAG) <> 0;
  len := len and VDB_LEN_MASK;
  if ovf then
  begin
    if dl < VDB_CELL_HDR + 4 then
    begin
      FStore.Release(L.PageNo, False);
      Exit;
    end;
    Move((d + VDB_CELL_HDR)^, first, 4);
    FStore.Release(L.PageNo, False);
    Result := ReadOverflow(first, len, Value);
    Exit;
  end;
  SetLength(Value, len);
  if len > 0 then
    Move((d + VDB_CELL_HDR)^, Value[0], len);
  FStore.Release(L.PageNo, False);
  Result := True;
end;

function TVdbHeap.DeleteAt(const L: TLoc; out FreedPage: Boolean): Boolean;
var
  P: PVdbPage;
  d: PByte;
  dl: Integer;
  len: LongWord;
  first: LongWord;
  empty: Boolean;
begin
  Result := False;
  FreedPage := False;
  if not FStore.GetPage(L.PageNo, P) then Exit;
  if not PageGetCell(P, L.Slot, d, dl) then
  begin
    FStore.Release(L.PageNo, False);
    Exit;
  end;
  if dl >= VDB_CELL_HDR + 4 then
  begin
    Move((d + 8)^, len, 4);
    if (len and VDB_OVF_FLAG) <> 0 then
    begin
      Move((d + VDB_CELL_HDR)^, first, 4);
      FStore.Release(L.PageNo, False);
      if first <> 0 then
        FreeOverflow(first);
      if not FStore.GetPage(L.PageNo, P) then Exit;
    end;
  end;
  if not PageDeleteCell(P, L.Slot) then
  begin
    FStore.Release(L.PageNo, False);
    Exit;
  end;
  empty := PageLiveCount(P) = 0;
  FStore.Release(L.PageNo, True);
  if empty and (L.PageNo <> FWritePage) then
  begin
    FStore.FreePage(L.PageNo);
    if FHeapPages > 0 then Dec(FHeapPages);
    FreedPage := True;
  end;
  Result := True;
end;

function TVdbHeap.InsertRaw(Key: QWord; const Value: TBytes;
  out L: TLoc): Boolean;
var
  cell: TBytes;
  first: LongWord;
begin
  Result := False;
  if not BuildCell(Key, Value, cell) then Exit;
  if Length(Value) > VDB_MAX_INLINE then
  begin
    WriteOverflow(Value, first);
    Move(first, cell[VDB_CELL_HDR], 4);
  end;
  PlaceCell(cell[0], Length(cell), L);
  Result := True;
end;

{ =================================================================== genel }

constructor TVdbHeap.Create(AStore: TVDbPageStore);
begin
  inherited Create;
  if AStore = nil then
    raise EVdbHeap.Create('heap icin depo gerekli');
  FStore := AStore;
  FCap := 0;
  DirGrow;   // 256
  FCount := 0;
  FWritePage := 0;
  FHeapPages := 0;
  FOvfPages := 0;
end;

procedure TVdbHeap.Open;
var
  pno, lastHeap: LongWord;
  P: PVdbPage;
  i, n: Integer;
  pgType: Byte;
  magic: Word;
  e: string;
  key: QWord;
  len: LongWord;
  d: PByte;
  dl: Integer;
  L: TLoc;
  ovf: Boolean;
begin
  DirReset;
  FWritePage := 0;
  FHeapPages := 0;
  FOvfPages := 0;
  lastHeap := 0;
  for pno := 1 to FStore.PageCount - 1 do
  begin
    if not FStore.GetRawPage(pno, P) then Continue;
    try
      Move(P^[0], magic, SizeOf(magic));
      if magic <> VDB_PAGE_MAGIC then
      begin
        { Freelist trunk sayfasi olabilir; AMA yalnizca gercekten trunk ise
          atlanir. Aksi halde bozuk sayfa sessizce yok sayilirdi. }
        if FStore.IsTrunkPage(P) then
          Continue;
        raise EVdbHeap.Create(Format(
          'sayfa %d taninmiyor (ne VDbPage ne trunk) - acilis taramasi', [pno]));
      end;
      if not PageVerify(P, e) then
        raise EVdbHeap.Create(Format('sayfa %d bozuk (acilis taramasi): %s',
          [pno, e]));
      pgType := PageTypeOf(P);
      if pgType = VDB_PAGE_OVERFLOW then
      begin
        Inc(FOvfPages);
        Continue;
      end;
      if pgType <> VDB_PAGE_HEAP then Continue;
      Inc(FHeapPages);
      lastHeap := pno;
      n := PageSlotCount(P);
      for i := 0 to n - 1 do
      begin
        if not PageGetCell(P, i, d, dl) then Continue;
        if dl < VDB_CELL_HDR then
          raise EVdbHeap.Create(Format('sayfa %d slot %d: hucre cok kisa', [pno, i]));
        Move(d^, key, 8);
        Move((d + 8)^, len, 4);
        ovf := (len and VDB_OVF_FLAG) <> 0;
        if ovf and (dl < VDB_CELL_HDR + 4) then
          raise EVdbHeap.Create(Format(
            'sayfa %d slot %d: tasma isaretli ama zincir yok', [pno, i]));
        L.PageNo := pno;
        L.Slot := i;
        { Ayni anahtar iki kez: dosya bozuk. }
        if Contains(key) then
          raise EVdbHeap.Create(Format('yinelenen anahtar $%.16x (sayfa %d)',
            [key, pno]));
        DirAdd(key, L);
      end;
    finally
      FStore.Release(pno, False);
    end;
  end;
  FWritePage := lastHeap;
end;

function TVdbHeap.Insert(Key: QWord; const Value: TBytes): Boolean;
var
  L: TLoc;
begin
  Result := False;
  if Contains(Key) then Exit;
  if not InsertRaw(Key, Value, L) then Exit;
  DirAdd(Key, L);
  Result := True;
end;

function TVdbHeap.Update(Key: QWord; const Value: TBytes): Boolean;
var
  idx: LongWord;
  L: TLoc;
  P: PVdbPage;
  d: PByte;
  dl: Integer;
  len: LongWord;
  oldVal: TBytes;
  inPlace, freed: Boolean;
begin
  Result := False;
  if not DirFind(Key, idx) then Exit;
  L := FLoc[idx];

  { Ayni uzunlukta ve tasma yoksa YERINDE yaz: slot ve sayfa degismez,
    yeni hucre ayrilmaz. En sik guncelleme yolu budur. }
  if FStore.GetPage(L.PageNo, P) then
  begin
    inPlace := False;
    if PageGetCell(P, L.Slot, d, dl) and (dl >= VDB_CELL_HDR) then
    begin
      Move((d + 8)^, len, 4);
      if ((len and VDB_OVF_FLAG) = 0) and (Integer(len) = Length(Value)) then
      begin
        if len > 0 then
          Move(Value[0], (d + VDB_CELL_HDR)^, len);
        inPlace := True;
      end;
    end;
    FStore.Release(L.PageNo, inPlace);
    if inPlace then Exit(True);
  end;

  { Farkli boyut / tasma siniri degisti: eski degeri sakla, sil, ekle.
    Ekleme basarisiz olursa eski deger geri konur (veri kaybi yok). }
  if not ReadCellAt(L, Key, oldVal) then Exit;
  if not DeleteAt(L, freed) then Exit;
  DirDel(Key);
  if not InsertRaw(Key, Value, L) then
  begin
    if InsertRaw(Key, oldVal, L) then
      DirAdd(Key, L);
    Exit(False);
  end;
  DirAdd(Key, L);
  Result := True;
end;

function TVdbHeap.Delete(Key: QWord): Boolean;
var
  idx: LongWord;
  L: TLoc;
  freed: Boolean;
begin
  Result := False;
  if not DirFind(Key, idx) then Exit;
  L := FLoc[idx];
  if not DeleteAt(L, freed) then Exit;
  DirDel(Key);
  Result := True;
end;

function TVdbHeap.TryGet(Key: QWord; out Value: TBytes): Boolean;
var
  idx: LongWord;
  k: QWord;
  P: PVdbPage;
  d: PByte;
  dl: Integer;
  len: LongWord;
  first: LongWord;
  released: Boolean;
begin
  Result := False;
  SetLength(Value, 0);
  if not DirFind(Key, idx) then Exit;
  if not FStore.GetPage(FLoc[idx].PageNo, P) then Exit;
  released := False;
  if not PageGetCell(P, FLoc[idx].Slot, d, dl) then
  begin
    FStore.Release(FLoc[idx].PageNo, False);
    Exit;
  end;
  if dl < VDB_CELL_HDR then
  begin
    FStore.Release(FLoc[idx].PageNo, False);
    Exit;
  end;
  Move(d^, k, 8);
  if k <> Key then
  begin
    FStore.Release(FLoc[idx].PageNo, False);
    Exit;   { bayat dizin kaydi }
  end;
  Move((d + 8)^, len, 4);
  if (len and VDB_OVF_FLAG) <> 0 then
  begin
    len := len and VDB_LEN_MASK;
    if dl >= VDB_CELL_HDR + 4 then
    begin
      Move((d + VDB_CELL_HDR)^, first, 4);
      FStore.Release(FLoc[idx].PageNo, False);
      released := True;
      Result := ReadOverflow(first, len, Value);
    end;
    if not released then
      FStore.Release(FLoc[idx].PageNo, False);
    Exit;
  end;
  SetLength(Value, len);
  if len > 0 then
    Move((d + VDB_CELL_HDR)^, Value[0], len);
  FStore.Release(FLoc[idx].PageNo, False);
  Result := True;
end;

function TVdbHeap.Contains(Key: QWord): Boolean;
var
  idx: LongWord;
begin
  Result := DirFind(Key, idx);
end;

procedure TVdbHeap.ScanAll(Cb: TScanProc);
var
  pno: LongWord;
  P: PVdbPage;
  i, n, j: Integer;
  magic: Word;
  key: QWord;
  len: LongWord;
  d: PByte;
  dl: Integer;
  ogKey: array of QWord;
  ogOvf: array of LongWord;
  ogLen: array of Integer;
  v: TBytes;
begin
  if not Assigned(Cb) then Exit;
  for pno := 1 to FStore.PageCount - 1 do
  begin
    SetLength(ogKey, 0);
    SetLength(ogOvf, 0);
    SetLength(ogLen, 0);
    if not FStore.GetRawPage(pno, P) then Continue;
    try
      Move(P^[0], magic, SizeOf(magic));
      if magic <> VDB_PAGE_MAGIC then Continue;
      if PageTypeOf(P) <> VDB_PAGE_HEAP then Continue;
      n := PageSlotCount(P);
      for i := 0 to n - 1 do
      begin
        if not PageGetCell(P, i, d, dl) then Continue;
        if dl < VDB_CELL_HDR then Continue;
        Move(d^, key, 8);
        Move((d + 8)^, len, 4);
        if (len and VDB_OVF_FLAG) <> 0 then
        begin
          if dl < VDB_CELL_HDR + 4 then Continue;
          { Tasma okumasi kendi pinlerini alir; sayfayi biraktiktan
            sonra islenecek. }
          j := Length(ogKey);
          SetLength(ogKey, j + 1);
          SetLength(ogOvf, j + 1);
          SetLength(ogLen, j + 1);
          ogKey[j] := key;
          ogLen[j] := Integer(len and VDB_LEN_MASK);
          Move((d + VDB_CELL_HDR)^, ogOvf[j], 4);
          Continue;
        end;
        SetLength(v, len);
        if len > 0 then
          Move((d + VDB_CELL_HDR)^, v[0], len);
        Cb(key, v);
      end;
    finally
      FStore.Release(pno, False);
    end;
    for j := 0 to High(ogKey) do
      if ReadOverflow(ogOvf[j], ogLen[j], v) then
        Cb(ogKey[j], v);
  end;
end;

procedure TVdbHeap.Flush(DoSync: Boolean);
begin
  FStore.Flush(DoSync);
end;

function TVdbHeap.Stats: TVdbHeapStats;
begin
  Result.Keys := FCount;
  Result.HeapPages := FHeapPages;
  Result.OverflowPages := FOvfPages;
  Result.DirCapacity := FCap;
  if FCap > 0 then
    Result.DirLoad := FCount / FCap
  else
    Result.DirLoad := 0;
  if FCount > 0 then
    Result.BytesPerKey := FStore.Stats.FileBytes / FCount
  else
    Result.BytesPerKey := 0;
end;

end.
