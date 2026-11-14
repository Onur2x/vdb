unit VDbMM;
{ P-110: Ozel bellek yoneticisi — kucuk blok serbest liste + bump allocator.
  VDB B metrigindeki 400k+ kucuk tahsis (string hucreler + ic satir dizileri)
  icin FPC varsayilan heap'ine karsi hizli yol.

  Tasarim:
  - 64KB'lik slab'lar (Windows: VirtualAlloc, Unix: mmap; 64KB hizali).
  - 16 boyut sinifi (16..512 bayt). Her sinif: serbest liste + bump isaretcisi.
  - <=512 bayt: slab'lardan; >512 bayt: orijinal yoneticiden dogrudan.
  - FreeMem: slab kayit defteri (hash kumesi) ile slab mi diye bak, slab ise
    serbest listeye ekle, degilse orijinal yoneticinin FreeMem'ine birak.

  Senkronizasyon (P-110 v3): InterlockedExchange spinlock. Tek is parcaciginda
  tek LOCK XCHG (~5ns), cok is parcaciginda dogru. Kritik bolumden hizli.
  P-110 v4: MMSingleThreaded=True ise kilit tamamen atlanir (~10ns/tahsis).

  Guvenlik: her slab basliginda dogrulama sihirli sayisi; kayit defteri yalnizca
  bizim slab'larimizi isaretler; eski tahsisler (kurulumdan once) orijinal
  yoneticide kalir.

  TASINABILIRLIK (2026-11): slab ayirma Windows'ta VirtualAlloc, Unix'te
  fpmmap ile yapilir. Eski 64KB-bitmap (`SlabBits`, `P shr 16`) yalniz 32-bit
  adres uzayini kapsiyordu; 64-bit hedeflerde tasma yapardi. Yerine tam
  anahtarli (slab taban adresi) acik adresleme hash kumesi geldi.}
{$mode delphi}{$H+}

interface

var
  { P-110 v4: tek is parcacigi bayragi. True ise LockAcquire/LockRelease
    tamamen atlanir (LOCK XCHG ~10ns/tahsis). Yanlis kullanilirse veri
    bozulur — yalnizca tek is parcacigi oldugundan emin oldugunda set et. }
  MMSingleThreaded: Boolean;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows;
  {$ELSE}
  BaseUnix;
  {$ENDIF}

const
  SLAB_SIZE      = 65536;
  SLAB_HDR       = 16;
  SLAB_MAGIC     = $5644424D;             // 'VDBM'
  MAX_SMALL      = 512;
  NUM_CLASSES    = 16;

type
  PFreeNode = ^TFreeNode;
  TFreeNode = record
    Next: PFreeNode;
  end;

  PSlabHdr = ^TSlabHdr;
  TSlabHdr = record
    Magic: Cardinal;
    SizeClass: Integer;
    Pad: array[0..3] of Byte;
  end;

var
  ClassSize: array[0..NUM_CLASSES-1] of PtrUInt =
    (16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512);

  FreeList: array[0..NUM_CLASSES-1] of PFreeNode;
  BumpPtr: array[0..NUM_CLASSES-1] of PByte;
  BumpEnd: array[0..NUM_CLASSES-1] of PByte;

  { Slab kayit defteri: 64KB hizali taban adreslerinin (adres shr 16) acik
    adresleme hash kumesi. 0 = bos yuva. Tablo OldMM ile buyutulur (recursion
    yok). Slab'lar calisma suresince OS'e iade edilmez; silme yolu yoktur. }
  SlabKeys: Pointer;               // PtrUInt dizisi (GetMem ile)
  SlabUsed: PByte;                 // bayrak dizisi
  SlabCap: Integer = 0;
  SlabCount: Integer = 0;
  MMLock: LongInt;
  OldMM: TMemoryManager;

// ---------------------------------------------------------------------------

procedure LockAcquire; inline;
begin
  if MMSingleThreaded then Exit;
  while InterlockedExchange(MMLock, 1) <> 0 do
    ; // spin — kisa kritik bolum, contention nadir
end;

procedure LockRelease; inline;
begin
  if MMSingleThreaded then Exit;
  InterlockedExchange(MMLock, 0);
end;

// ---------------------------------------------------------------------------

function ClassFor(Size: PtrUInt): Integer; inline;
var
  lo, hi, mid: Integer;
begin
  lo := 0; hi := NUM_CLASSES - 1;
  while lo < hi do
  begin
    mid := (lo + hi) div 2;
    if Size <= ClassSize[mid] then hi := mid
    else lo := mid + 1;
  end;
  Result := lo;
end;

// ---------------------------------------------------------------------------
// Slab kayit defteri. Cagiranlar (MMFreeMem/ReallocMem/MemSize) yabanci
// isaretcilerle de gelebilir; bu yuzden arama TAM anahtar esitligi ister.

function SlabKeyAt(ABase: Pointer; I: Integer): PtrUInt; inline;
begin
  Result := PPtrUInt(PByte(ABase) + PtrUInt(I) * SizeOf(PtrUInt))^;
end;

procedure SlabKeyPut(ABase: Pointer; I: Integer; AKey: PtrUInt); inline;
begin
  PPtrUInt(PByte(ABase) + PtrUInt(I) * SizeOf(PtrUInt))^ := AKey;
end;

function SlabKeyGet(I: Integer): PtrUInt; inline;
begin
  Result := SlabKeyAt(SlabKeys, I);
end;

procedure SlabKeySet(I: Integer; AKey: PtrUInt); inline;
begin
  SlabKeyPut(SlabKeys, I, AKey);
end;

procedure SlabRebuild(ANewCap: Integer);
var
  nk: Pointer;
  nu: PByte;
  i, j: Integer;
begin
  nk := OldMM.GetMem(PtrUInt(ANewCap) * SizeOf(PtrUInt));
  nu := PByte(OldMM.GetMem(PtrUInt(ANewCap)));
  if (nk = nil) or (nu = nil) then
  begin
    if nk <> nil then OldMM.FreeMem(nk);
    if nu <> nil then OldMM.FreeMem(nu);
    Exit;
  end;
  FillChar(nu^, ANewCap, 0);
  if SlabCap > 0 then
  begin
    for i := 0 to SlabCap - 1 do
      if SlabUsed[i] <> 0 then
      begin
        j := Integer(SlabKeyGet(i) and PtrUInt(ANewCap - 1));
        while nu[j] <> 0 do j := (j + 1) and (ANewCap - 1);
        SlabKeyPut(nk, j, SlabKeyAt(SlabKeys, i));
        nu[j] := 1;
      end;
    OldMM.FreeMem(SlabKeys);
    OldMM.FreeMem(SlabUsed);
  end;
  SlabKeys := nk;
  SlabUsed := nu;
  SlabCap := ANewCap;
end;

function SlabRegister(AKey: PtrUInt): Boolean;
var
  i: Integer;
begin
  if (SlabCap = 0) or ((SlabCount + 1) * 2 > SlabCap) then
  begin
    if SlabCap = 0 then SlabRebuild(1024)
    else SlabRebuild(SlabCap * 2);
  end;
  if SlabCap = 0 then Exit(False);
  i := Integer(AKey and PtrUInt(SlabCap - 1));
  while SlabUsed[i] <> 0 do i := (i + 1) and (SlabCap - 1);
  SlabKeySet(i, AKey);
  SlabUsed[i] := 1;
  Inc(SlabCount);
  Result := True;
end;

function SlabIsRegistered(AKey: PtrUInt): Boolean;
var
  i: Integer;
begin
  Result := False;
  if SlabCap = 0 then Exit;
  i := Integer(AKey and PtrUInt(SlabCap - 1));
  while SlabUsed[i] <> 0 do
  begin
    if SlabKeyGet(i) = AKey then Exit(True);
    i := (i + 1) and (SlabCap - 1);
  end;
end;

function IsOurSlab(P: Pointer): Boolean;
begin
  LockAcquire;
  Result := SlabIsRegistered(PtrUInt(P) shr 16);
  LockRelease;
end;

// ---------------------------------------------------------------------------
// Platform slab ayirma. Unix'te mmap 64KB hizali olmadigi icin 2 slab
// ayirip fazlaysini geri birakiriz (onek/sonek sayfa boyunun katidir).

function SlabAlloc: PSlabHdr;
{$IFDEF MSWINDOWS}
begin
  Result := VirtualAlloc(nil, SLAB_SIZE, MEM_COMMIT or MEM_RESERVE,
    PAGE_READWRITE);
end;
{$ELSE}
var
  base, aligned: Pointer;
  pre, post: PtrUInt;
begin
  Result := nil;
  base := fpmmap(nil, SLAB_SIZE * 2, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if base = MAP_FAILED then Exit;
  aligned := Pointer((PtrUInt(base) + (SLAB_SIZE - 1)) and
    not PtrUInt(SLAB_SIZE - 1));
  pre := PtrUInt(aligned) - PtrUInt(base);
  post := PtrUInt(base) + SLAB_SIZE * 2 - (PtrUInt(aligned) + SLAB_SIZE);
  if pre > 0 then fpMunmap(base, pre);
  if post > 0 then fpMunmap(Pointer(PtrUInt(aligned) + SLAB_SIZE), post);
  Result := PSlabHdr(aligned);
end;
{$ENDIF}

procedure SlabRelease(ASlab: PSlabHdr);
begin
  {$IFDEF MSWINDOWS}
  VirtualFree(ASlab, 0, MEM_RELEASE);
  {$ELSE}
  fpMunmap(ASlab, SLAB_SIZE);
  {$ENDIF}
end;

// ---------------------------------------------------------------------------
// Ana tahsis yolu — MMGetMem icine dogrudan gomulu (inline icin).

function MMGetMem(Size: PtrUInt): Pointer;
var
  sc: Integer;
  node: PFreeNode;
  slab: PSlabHdr;
  idx: PtrUInt;
begin
  if Size = 0 then Size := 1;
  if Size > MAX_SMALL then
  begin
    Result := OldMM.GetMem(Size);
    Exit;
  end;

  sc := ClassFor(Size);

  LockAcquire;

  // 1) Serbest listeden al
  node := FreeList[sc];
  if node <> nil then
  begin
    FreeList[sc] := node^.Next;
    Result := node;
    LockRelease;
    Exit;
  end;

  // 2) Bump tahsis
  if BumpPtr[sc] <> nil then
  begin
    Result := BumpPtr[sc];
    Inc(BumpPtr[sc], ClassSize[sc]);
    if BumpPtr[sc] >= BumpEnd[sc] then BumpPtr[sc] := nil;
    LockRelease;
    Exit;
  end;

  LockRelease;

  // 3) Yeni slab. OS cagrisi yavas oldugu icin kilit disinda.
  slab := SlabAlloc;
  if slab = nil then
  begin
    Result := OldMM.GetMem(Size);
    Exit;
  end;
  slab^.Magic := SLAB_MAGIC;
  slab^.SizeClass := sc;
  idx := PtrUInt(slab) shr 16;

  LockAcquire;
  // R2-A-2: kilit disindayken baska is parcacigi ayni sinifa slab yayinladiysa
  // onun bump alanindan al; bizim slab'i OS'e iade et. Aksi halde ikinci yayin
  // birincinin kalan bump alanini cope atardi.
  if BumpPtr[sc] <> nil then
  begin
    Result := BumpPtr[sc];
    Inc(BumpPtr[sc], ClassSize[sc]);
    if BumpPtr[sc] >= BumpEnd[sc] then BumpPtr[sc] := nil;
    LockRelease;
    SlabRelease(slab);
    Exit;
  end;
  // R2-A-1: kayit defteri guncellemesi de kilit altinda; aksi halde ayni
  // anahtari goren iki is parcacigi ayni slab'i iki kez yayinlayabilir.
  if not SlabRegister(idx) then
  begin
    LockRelease;
    SlabRelease(slab);
    Result := OldMM.GetMem(Size);
    Exit;
  end;
  BumpPtr[sc] := PByte(slab) + SLAB_HDR;
  BumpEnd[sc] := PByte(slab) + SLAB_HDR +
    ((SLAB_SIZE - SLAB_HDR) div ClassSize[sc]) * ClassSize[sc];
  Result := BumpPtr[sc];
  Inc(BumpPtr[sc], ClassSize[sc]);
  LockRelease;
end;

function MMFreeMem(P: Pointer): PtrUInt;
var
  slab: PSlabHdr;
  sc: Integer;
  node: PFreeNode;
begin
  if P = nil then Exit(0);
  if not IsOurSlab(P) then
  begin
    Result := OldMM.FreeMem(P);
    Exit;
  end;
  slab := PSlabHdr(PtrUInt(P) and PtrUInt(not (SLAB_SIZE - 1)));
  if slab^.Magic <> SLAB_MAGIC then Exit(0);
  sc := slab^.SizeClass;
  if (sc < 0) or (sc >= NUM_CLASSES) then Exit(0);
  LockAcquire;
  node := PFreeNode(P);
  node^.Next := FreeList[sc];
  FreeList[sc] := node;
  LockRelease;
  Result := 0;
end;

function MMFreeMemSize(P: Pointer; Size: PtrUInt): PtrUInt;
begin
  Result := MMFreeMem(P);
end;

function MMAllocMem(Size: PtrUInt): Pointer;
begin
  Result := MMGetMem(Size);
  if Result <> nil then
    FillChar(Result^, Size, 0);
end;

function MMReallocMem(var P: Pointer; Size: PtrUInt): Pointer;
{ Sozlesme (Delphi/FPC ReallocMem ile birebir):
    - P = nil, Size = 0  -> nil (tahsis yapilmaz).
    - P = nil, Size > 0  -> yeni blok; basarisizsa nil.
    - Size = 0           -> blok serbest, P := nil, sonuc nil.
    - Hata (OOM / bozuk slab basligi) -> sonuc nil ve P DEGISMEZ;
      eski blok gecerli kalir. Cagiran eski isaretcisini kullanmaya
      devam edebilir; yarim Move / cift serbest olmaz.

  R2-B-YENI-2: bozuk baslikta "sessizce P'yi koruyup nil donme" davranisi
  artik bilincli ve belgelenmis sozlesmedir; ek olarak P=nil/Size=0
  birlesimi de sozlesmeye uygun hale getirildi (onceki surum 1 baytlik
  blok donduruyordu). }
var
  oldSize: PtrUInt;
  newP: Pointer;
  slab: PSlabHdr;
  sc: Integer;
begin
  if P = nil then
  begin
    if Size = 0 then Exit(nil);
    P := MMGetMem(Size);
    Exit(P);
  end;
  if Size = 0 then
  begin
    MMFreeMem(P);
    P := nil;
    Exit(nil);
  end;

  if IsOurSlab(P) then
  begin
    slab := PSlabHdr(PtrUInt(P) and PtrUInt(not (SLAB_SIZE - 1)));
    // R2-A-3: MMFreeMem'deki sihirli sayi denetimi burada da gerekli; aksi
    // halde bozuk baslik ClassSize[slab^.SizeClass] ile sinir disi okuma yapar.
    sc := slab^.SizeClass;
    if (slab^.Magic <> SLAB_MAGIC) or (sc < 0) or (sc >= NUM_CLASSES) then
      // Hata sozlesmesi: P korunur, nil doner. Blok bizim ama boyu
      // bilinmiyor; oldugu gibi birakmak tek guvenli secenek.
      Exit(nil);
    oldSize := ClassSize[sc];
    if Size <= oldSize then Exit(P);
    newP := MMGetMem(Size);
    if newP = nil then
      // Hata sozlesmesi: P korunur (eski blok serbest BIRAKILMAZ).
      Exit(nil);
    Move(P^, newP^, oldSize);
    MMFreeMem(P);
    P := newP;
    Exit(P);
  end;

  Result := OldMM.ReAllocMem(P, Size);
end;

function MMMemSize(P: Pointer): PtrUInt;
var
  slab: PSlabHdr;
  sc: Integer;
begin
  if P = nil then Exit(0);
  if IsOurSlab(P) then
  begin
    slab := PSlabHdr(PtrUInt(P) and PtrUInt(not (SLAB_SIZE - 1)));
    // R2-A-3: bozuk baslikta SizeClass sinir disi olabilir; dogrulamadan
    // ClassSize'a indeksleme yapma. Bilinmeyen boyut icin 0 (guvenli) don.
    sc := slab^.SizeClass;
    if (slab^.Magic <> SLAB_MAGIC) or (sc < 0) or (sc >= NUM_CLASSES) then
      Exit(0);
    Result := ClassSize[sc];
    Exit;
  end;
  Result := OldMM.MemSize(P);
end;

procedure MMInitThread;
begin
  if Assigned(OldMM.InitThread) then OldMM.InitThread;
end;

procedure MMDoneThread;
begin
  if Assigned(OldMM.DoneThread) then OldMM.DoneThread;
end;

procedure MMRelocateHeap;
begin
  if Assigned(OldMM.RelocateHeap) then OldMM.RelocateHeap;
end;

function MMGetHeapStatus: THeapStatus;
begin
  Result := OldMM.GetHeapStatus;
end;

function MMGetFPCHeapStatus: TFPCHeapStatus;
begin
  Result := OldMM.GetFPCHeapStatus;
end;

// ---------------------------------------------------------------------------

procedure Install;
var
  mm: TMemoryManager;
begin
  if IsMemoryManagerSet then Exit;
  GetMemoryManager(OldMM);

  mm := OldMM;
  mm.GetMem := @MMGetMem;
  mm.FreeMem := @MMFreeMem;
  mm.FreeMemSize := @MMFreeMemSize;
  mm.AllocMem := @MMAllocMem;
  mm.ReAllocMem := @MMReallocMem;
  mm.MemSize := @MMMemSize;
  mm.InitThread := @MMInitThread;
  mm.DoneThread := @MMDoneThread;
  mm.RelocateHeap := @MMRelocateHeap;
  mm.GetHeapStatus := @MMGetHeapStatus;
  mm.GetFPCHeapStatus := @MMGetFPCHeapStatus;
  SetMemoryManager(mm);
end;

initialization
  Install;

end.