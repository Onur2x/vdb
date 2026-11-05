unit VDbMM;
{ P-110: Ozel bellek yoneticisi — kucuk blok serbest liste + bump allocator.
  VDB B metrigindeki 400k+ kucuk tahsis (string hucreler + ic satir dizileri)
  icin FPC varsayilan heap'ine karsi hizli yol.

  Tasarim:
  - 64KB'lik VirtualAlloc slab'lari (64KB hizali — bitmap ile slab bulma).
  - 16 boyut sinifi (16..512 bayt). Her sinif: serbest liste + bump isaretcisi.
  - <=512 bayt: slab'lardan; >512 bayt: orijinal yoneticiden dogrudan.
  - FreeMem: bitmap ile slab mi diye bak, slab ise serbest listeye ekle,
    degilse orijinal yoneticinin FreeMem'ine birak.

  Senkronizasyon (P-110 v3): InterlockedExchange spinlock. Tek is parcaciginda
  tek LOCK XCHG (~5ns), cok is parcaciginda dogru. Kritik bolumden hizli.

  Guvenlik: her slab basliginda dogrulama sihirli sayisi; bitmap yalnizca
  bizim slab'larimizi isaretler; eski tahsisler (kurulumdan once) orijinal
  yoneticide kalir.}
{$mode delphi}{$H+}

interface

implementation

uses
  Windows;

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

  SlabBits: array[0..8191] of Byte;
  MMLock: LongInt;
  OldMM: TMemoryManager;

// ---------------------------------------------------------------------------

procedure LockAcquire; inline;
begin
  while InterlockedExchange(MMLock, 1) <> 0 do
    ; // spin — kisa kritik bolum, contention nadir
end;

procedure LockRelease; inline;
begin
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

function IsOurSlab(P: Pointer): Boolean; inline;
var
  idx: PtrUInt;
begin
  idx := PtrUInt(P) shr 16;
  Result := (SlabBits[idx shr 3] and (1 shl (idx and 7))) <> 0;
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

  // 3) Yeni slab (VirtualAlloc — kendi icinde guvenli)
  slab := VirtualAlloc(nil, SLAB_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  if slab = nil then
  begin
    Result := OldMM.GetMem(Size);
    Exit;
  end;
  slab^.Magic := SLAB_MAGIC;
  slab^.SizeClass := sc;
  idx := PtrUInt(slab) shr 16;
  SlabBits[idx shr 3] := SlabBits[idx shr 3] or (1 shl (idx and 7));

  LockAcquire;
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
var
  oldSize: PtrUInt;
  newP: Pointer;
  slab: PSlabHdr;
begin
  if P = nil then
  begin
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
    oldSize := ClassSize[slab^.SizeClass];
    if Size <= oldSize then Exit(P);
    newP := MMGetMem(Size);
    if newP = nil then Exit(nil);
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
begin
  if P = nil then Exit(0);
  if IsOurSlab(P) then
  begin
    slab := PSlabHdr(PtrUInt(P) and PtrUInt(not (SLAB_SIZE - 1)));
    Result := ClassSize[slab^.SizeClass];
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