unit VDbBTreeDisk;
{ VDB v3.46 - AYRI B+TREE DISK SAYFA BICIMI (SKILL3 §13, BTREE_INTEGRITY §5-6)

  NEDEN VAR
  =========
  v3.45'e kadar tablo satirlari 4 KB sayfa yigini uzerinde duruyor ve
  ikincil dizin bellekteki `TVDbBTree` uzerinde tutuluyordu. Diskte
  sayfalanmis, kendi basina acilip dogrulanabilen bir B+Tree sayfa bicimi
  YOKTU (ayri indeks dosyasi `VDbIdxFile` duz sirali bir kayit dosyasidir,
  sayfa bicimi degildir). Bu birim o bosluk icin BAGIMSIZ uygulamadir.

  KAPSAM (durust sinir)
  =====================
  Bu birim v5 MOTOR DOSYA BICIMINE BAGLANMAMISTIR. Ne `VDbPageEngine` ne de
  SQL yolu onu kullanir; dolayisiyla v5 dosya bicimi, WAL ve kurtarma
  davranisi DEGISMEZ. Amac; sayfa bicimini, bolunmeyi, atomik commit'i,
  yirtik yazma tespitini ve cokme noktasinda onceki agacin hala okunabildigini
  OLCULEBILIR hale getirmektir. Kapisi `tests/btree_disk`'tir. Motora
  baglanirsa o gun ayrica kapi + kurtarma calismasi gerekir; bu birim o
  iddiayi TASIMAZ.

  SAYFA BICIMI
  ============
  Sayfa boyu 4096. Sayfa 0 ve 1 meta (A/B kopya), veri sayfalari 2'den
  baslar. Her sayfada 32 baytlik baslik:

    +0  PageNo   LongWord   (kendi numarasi; kayma tespiti icin)
    +4  Kind     Byte       1=ic, 2=yaprak, 3=meta
    +5  Level    Byte       yaprak=0, kokte buyur
    +6  NKeys    Word       hucre sayisi (ic sayfada 0. hucre en sol cocuk)
    +8  Reserved LongWord
    +12 Flags    LongWord
    +16 Crc      LongWord   sayfanin tamami (Crc alani 0 iken)
    +20 Reserved 12 bayt

  Basliktan sonra slot dizisi (Off:Word, Len:Word) buyur, hucre yuku sayfa
  sonundan geriye dogru yazilir. Yaprak hucresi 16 bayt (Key:QWord +
  Val:QWord), ic hucre 12 bayt (Key:QWord + Child:LongWord).

  Ic sayfada 0. hucrenin Key'i KULLANILMAZ; Child'i en sol cocuktur.
  i >= 1 icin Key_i, Child_i alt agacinin ayiricisidir ve yonlendirme
  kurali "Key_i <= K olan en buyuk i" seklindedir.

  ATOMIKLIK: GOLGE SAYFALAMA (shadow paging)
  ==========================================
  HICBIR sayfa YERINDE guncellenmez. Degisen her sayfa yeni bir sayfa
  numarasina kopyalanir ve kokten yapraga kadar yol yeniden yazilir; meta
  sayfasi en son yazilir. Meta yazimi COMMIT NOKTASIDIR:

    - commit'ten ONCE cokme: meta eski agaci gosterir ve o agacin sayfalari
      HIC degistirilmemistir -> ESKI AGAC AYNEN OKUNUR (veri kaybi yok,
      yalnizca yazilmis ama baglanmamis sayfalar "sizinti" olur; acilista
      erisilemeyen sayfalar serbest sayilir ve yeniden kullanilir).
    - commit SIRASINDA yirtik meta yazimi: her sayfanin CRC'si vardir,
      iki meta kopyasindan gecerli ve daha yeni olani secilir. Yeni kopya
      bozuksa eskisi kullanilir; eskisinin agaci da bozulmamistir (golge
      sayfalama). Boylece meta yazimi atomiktir.
    - commit'ten SONRA: eski surumlerin sayfalari serbest listeye doner.

  Islem sinirlari: `Insert`/`Delete` degisiklikleri HAZIRLAR, `Commit` (veya
  otomatik commit esigi) iki fsync ile kalicilastirir. `Sync` = `Commit`.

  BOZULMA VE HATA SINIRI
  ======================
  Okuma yolunda sayfa numarasi/kimligi tutmuyorsa (`Find`, `NextAfter`,
  `Walk`) `EBtdError` atilir; sessizce False donmek bozulmayi gizler ve
  daha tehlikelidir. `Verify` istisna SIZDIRMAZ: bozuk sayfayi bulgu
  olarak raporlar ve False doner. Sayfa CRC'si her okumada zorlanmaz
  (okuma basina 4 KB CRC maliyeti olurdu); CRC'nin kullanildigi yerler
  Verify ve acilistaki meta secimidir.

  SILME
  =====
  Bilerek "tembel" silme: anahtar yapraktan cikarilir, YALNIZCA bosalan
  sayfa agactan dusurulur; yarim dolu sayfalar birlestirilmez. Yukseklik
  yalnizca kok tek cocuga indiginde azalir. Doluluk maliyeti gizlenmez:
  kapi churn sonrasi dolulugu olcer. Ayirma (merge/redistribute) eklenirse
  ayri olcum ister.
}
{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, VDbCrc32, VDbSync;

const
  BTD_PAGE_SIZE   = 4096;
  BTD_MAGIC       = $31445442;   { 'BTD1' }
  BTD_VER         = 1;
  BTD_HDR_SIZE    = 32;
  BTD_META_PAGES  = 2;
  BTD_FIRST_DATA  = 2;

  BTD_KIND_INTERNAL = 1;
  BTD_KIND_LEAF     = 2;
  BTD_KIND_META     = 3;

  BTD_LEAF_CELL = 16;   { Key:QWord + Val:QWord }
  BTD_INT_CELL  = 12;   { Key:QWord + Child:LongWord }
  BTD_SLOT_SIZE = 4;

  { Bunun altinda kalan sayfa "az dolu" sayilir; kapi olcer, motor zorlamaz. }
  BTD_MIN_FILL_DEN = 4;

type
  EBtdError = class(Exception);

  TBtdPageBuf = array[0..BTD_PAGE_SIZE - 1] of Byte;

  TBtdNotifyProc = procedure of object;
  TBtdWalkProc = procedure(AKey, AVal: QWord) of object;

  TBtdTree = class
  private
    FFileName: string;
    FStream: THandleStream;
    FReadOnly: Boolean;
    FSeq: Int64;
    FRoot: LongWord;
    FPageCount: LongWord;
    FHeight: Integer;
    FNKeys: Int64;
    FPages: array of TBtdPageBuf;      { bu islemde yazilacak sayfalar }
    FPageNo: array of LongWord;        { 0 = tombstone (dusuruldu) }
    FMap: TDictionary<LongWord, Integer>;
    FFree: array of LongWord;          { yeniden kullanilabilir sayfalar }
    FFreeCount: Integer;
    FPending: array of LongWord;       { commit sonrasi serbest kalacak }
    FPendingCount: Integer;
    FOnBeforeMeta: TBtdNotifyProc;
    FSyncCount: Int64;
    FPagesWritten: Int64;
    FAutoCommit: Integer;
    FTxnOps: Integer;
    FCommitOnClose: Boolean;
    procedure InitializeNew;
    procedure LoadMeta;
    procedure MarkReachable;
    { Sprint D (6.2): sayfa yapisal dogrulamasi. CRC gecerli olsa bile
      NKeys/slot/hucre sinirlari ve anahtar sirasi tutmuyorsa sayfa
      bozuktur; pointer ve slot degerleri kullanilmaz. }
    function  CheckPageStruct(const P: TBtdPageBuf; ANo: LongWord;
      out AErr: string): Boolean;
    procedure WriteMeta;
    procedure ReadPage(ANo: LongWord; var P: TBtdPageBuf);
    procedure PutPage(ANo: LongWord; const P: TBtdPageBuf);
    function  BufIdx(ANo: LongWord): Integer;
    function  AllocPage(AKind, ALevel: Byte): LongWord;
    function  PageMut(ANo: LongWord): LongWord;
    procedure ReleasePage(ANo: LongWord);
    procedure PushFree(ANo: LongWord);
    procedure PushPending(ANo: LongWord);
    procedure DropBuf(ANo: LongWord);
    function  NewBuf: Integer;
    procedure NormalizeRoot;
    procedure AfterOp;
    function  SeekGE(ANo: LongWord; AKey: QWord;
      out AKey2, AVal: QWord): Boolean;
    function  FirstOf(ANo: LongWord; out AKey2, AVal: QWord): Boolean;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    procedure Commit;
    procedure Sync;
    function Insert(AKey, AVal: QWord): Boolean;
    function Delete(AKey: QWord): Boolean;
    function Find(AKey: QWord; out AVal: QWord): Boolean;
    function NextAfter(AKey: QWord; out AKey2, AVal: QWord): Boolean;
    procedure Walk(AProc: TBtdWalkProc);
    function Verify(out ARep: string): Boolean;
    function Count: Int64;
    function Height: Integer;
    function PageCount: LongWord;
    function FreePageCount: Integer;
    function RootPage: LongWord;
    function DenseLeaves(out ARep: string): Boolean;
    property OnBeforeMeta: TBtdNotifyProc read FOnBeforeMeta write FOnBeforeMeta;
    property AutoCommitEvery: Integer read FAutoCommit write FAutoCommit;
    { Kapanista otomatik commit. Varsayilan True. Testler, "commit
      edilmemis kapanis" durumunu birebir uretmek icin False yapar. }
    property CommitOnClose: Boolean read FCommitOnClose write FCommitOnClose;
    property SyncCount: Int64 read FSyncCount;
    property PagesWritten: Int64 read FPagesWritten;
    property ReadOnly: Boolean read FReadOnly;
  end;

implementation

type
  TBtdHdr = packed record
    PageNo: LongWord;
    Kind: Byte;
    Level: Byte;
    NKeys: Word;
    Reserved: LongWord;
    Flags: LongWord;
    Crc: LongWord;
    Tail: array[0..11] of Byte;
  end;
  PBtdHdr = ^TBtdHdr;

  TBtdSlot = packed record
    Off: Word;
    Len: Word;
  end;
  PBtdSlot = ^TBtdSlot;

  TBtdMetaRec = packed record
    Magic: LongWord;
    Ver: LongWord;
    PageSize: LongWord;
    Seq: Int64;
    Root: LongWord;
    PageCount: LongWord;
    Height: Word;
    Pad: Word;
    NKeys: Int64;
    Reserved: array[0..27] of Byte;
  end;
  PBtdMetaRec = ^TBtdMetaRec;

  TBtdKeyVal = record
    K, V: QWord;
  end;
  TBtdKeyChild = record
    K: QWord;
    C: LongWord;
  end;

function Hd(const P: TBtdPageBuf): PBtdHdr;
begin
  Result := PBtdHdr(@P[0]);
end;

function Slt(const P: TBtdPageBuf; AIdx: Integer): PBtdSlot;
begin
  Result := PBtdSlot(@P[BTD_HDR_SIZE + AIdx * BTD_SLOT_SIZE]);
end;

function CP(const P: TBtdPageBuf; AIdx: Integer): PByte;
begin
  Result := @P[Slt(P, AIdx)^.Off];
end;

function RQ(P: PByte): QWord;
begin
  Move(P^, Result, 8);
end;

procedure WQ(P: PByte; V: QWord);
begin
  Move(V, P^, 8);
end;

function RL(P: PByte): LongWord;
begin
  Move(P^, Result, 4);
end;

procedure WL(P: PByte; V: LongWord);
begin
  Move(V, P^, 4);
end;

function PageCrc(const P: TBtdPageBuf): LongWord;
var
  tmp: TBtdPageBuf;
begin
  tmp := P;
  Hd(tmp)^.Crc := 0;
  Result := VDbCrc32Of(tmp, BTD_PAGE_SIZE);
end;

function CrcOk(const P: TBtdPageBuf): Boolean;
begin
  Result := Hd(P)^.Crc = PageCrc(P);
end;

procedure InitPage(var P: TBtdPageBuf; AKind, ALevel: Byte);
begin
  FillChar(P, BTD_PAGE_SIZE, 0);
  Hd(P)^.Kind := AKind;
  Hd(P)^.Level := ALevel;
  Hd(P)^.NKeys := 0;
end;

function PageFree(const P: TBtdPageBuf): Integer;
var
  i, used: Integer;
begin
  used := BTD_HDR_SIZE + Integer(Hd(P)^.NKeys) * BTD_SLOT_SIZE;
  for i := 0 to Hd(P)^.NKeys - 1 do
    Inc(used, Slt(P, i)^.Len);
  Result := BTD_PAGE_SIZE - used;
end;

function LeafKey(const P: TBtdPageBuf; AIdx: Integer): QWord;
begin
  Result := RQ(CP(P, AIdx));
end;

function LeafVal(const P: TBtdPageBuf; AIdx: Integer): QWord;
begin
  Result := RQ(CP(P, AIdx) + 8);
end;

function IntKey(const P: TBtdPageBuf; AIdx: Integer): QWord;
begin
  Result := RQ(CP(P, AIdx));
end;

function IntChild(const P: TBtdPageBuf; AIdx: Integer): LongWord;
begin
  Result := RL(CP(P, AIdx) + 8);
end;

procedure SetChild(var P: TBtdPageBuf; AIdx: Integer; AChild: LongWord);
begin
  WL(CP(P, AIdx) + 8, AChild);
end;

procedure CellInsert(var P: TBtdPageBuf; AIdx: Integer;
  const ACell; ALen: Integer);
var
  tmp: TBtdPageBuf;
  i, src, n, dataEnd, len: Integer;
begin
  n := Hd(P)^.NKeys;
  if AIdx < 0 then AIdx := 0;
  if AIdx > n then AIdx := n;
  if PageFree(P) < ALen + BTD_SLOT_SIZE then
    raise EBtdError.Create('B+Tree: sayfada yer yok');
  FillChar(tmp, BTD_PAGE_SIZE, 0);
  Move(P[0], tmp[0], BTD_HDR_SIZE);
  dataEnd := BTD_PAGE_SIZE;
  for i := 0 to n do
  begin
    if i = AIdx then
    begin
      Dec(dataEnd, ALen);
      Move(ACell, tmp[dataEnd], ALen);
      len := ALen;
    end
    else
    begin
      src := i;
      if i > AIdx then src := i - 1;
      len := Slt(P, src)^.Len;
      Dec(dataEnd, len);
      Move(P[Slt(P, src)^.Off], tmp[dataEnd], len);
    end;
    Slt(tmp, i)^.Off := Word(dataEnd);
    Slt(tmp, i)^.Len := Word(len);
  end;
  Hd(tmp)^.NKeys := n + 1;
  P := tmp;
end;

procedure LeafInsertCell(var P: TBtdPageBuf; AIdx: Integer;
  AKey, AVal: QWord);
var
  cell: array[0..BTD_LEAF_CELL - 1] of Byte;
begin
  WQ(@cell[0], AKey);
  WQ(@cell[8], AVal);
  CellInsert(P, AIdx, cell, BTD_LEAF_CELL);
end;

procedure IntInsertCell(var P: TBtdPageBuf; AIdx: Integer;
  AKey: QWord; AChild: LongWord);
var
  cell: array[0..BTD_INT_CELL - 1] of Byte;
begin
  WQ(@cell[0], AKey);
  WL(@cell[8], AChild);
  CellInsert(P, AIdx, cell, BTD_INT_CELL);
end;

procedure CellRemove(var P: TBtdPageBuf; AIdx: Integer);
var
  tmp: TBtdPageBuf;
  i, src, n, dataEnd, len: Integer;
begin
  n := Hd(P)^.NKeys;
  if (AIdx < 0) or (AIdx >= n) then
    raise EBtdError.CreateFmt('B+Tree: hucre dizini bozuk (%d/%d)', [AIdx, n]);
  FillChar(tmp, BTD_PAGE_SIZE, 0);
  Move(P[0], tmp[0], BTD_HDR_SIZE);
  dataEnd := BTD_PAGE_SIZE;
  for i := 0 to n - 2 do
  begin
    src := i;
    if i >= AIdx then src := i + 1;
    len := Slt(P, src)^.Len;
    Dec(dataEnd, len);
    Move(P[Slt(P, src)^.Off], tmp[dataEnd], len);
    Slt(tmp, i)^.Off := Word(dataEnd);
    Slt(tmp, i)^.Len := Word(len);
  end;
  Hd(tmp)^.NKeys := n - 1;
  P := tmp;
end;

function LeafLowerBound(const P: TBtdPageBuf; AKey: QWord): Integer;
var
  lo, hi, mid: Integer;
begin
  lo := 0;
  hi := Hd(P)^.NKeys;
  while lo < hi do
  begin
    mid := (lo + hi) div 2;
    if LeafKey(P, mid) < AKey then lo := mid + 1 else hi := mid;
  end;
  Result := lo;
end;

function ChildIndex(const P: TBtdPageBuf; AKey: QWord): Integer;
var
  lo, hi, mid: Integer;
begin
  Result := 0;
  lo := 1;
  hi := Hd(P)^.NKeys - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if IntKey(P, mid) <= AKey then
    begin
      Result := mid;
      lo := mid + 1;
    end
    else
      hi := mid - 1;
  end;
end;

{ ---------------------------------------------------------------- TBtdTree }

constructor TBtdTree.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FReadOnly := False;
  FSeq := 0;
  FRoot := 0;
  FPageCount := BTD_FIRST_DATA;
  FHeight := 0;
  FNKeys := 0;
  FFreeCount := 0;
  FPendingCount := 0;
  FSyncCount := 0;
  FPagesWritten := 0;
  FAutoCommit := 512;
  FTxnOps := 0;
  FCommitOnClose := True;
  SetLength(FPages, 0);
  SetLength(FPageNo, 0);
  SetLength(FFree, 0);
  SetLength(FPending, 0);
  FMap := TDictionary<LongWord, Integer>.Create;
  { DIKKAT: `ACreate = True` Windows'ta fmCreate demektir ve VAR OLAN
    dosyayi SIFIRLAR (UNIX'te O_CREAT sifirlamaz). Bu yuzden var olan
    dosya yalnizca acilir; ayni desen VDbPageStore.pas:2339'da da var.
    Aksi halde her yeniden acilis sessiz bir VERI KAYBI olurdu. }
  if FileExists(AFileName) then
    FStream := VDbOpenStreamNoFlock(AFileName, False, False)
  else
    FStream := VDbOpenStreamNoFlock(AFileName, False, True);
  try
    if FStream.Size = 0 then
      InitializeNew
    else if FStream.Size < Int64(BTD_META_PAGES) * BTD_PAGE_SIZE then
      { Kesik dosya: sessizce yeni agac kurmak VERI KAYBI olurdu. }
      raise EBtdError.CreateFmt('B+Tree: dosya kesik (%d bayt)', [FStream.Size])
    else
      LoadMeta;
  except
    { Yarim kurulmus nesne: FPC yikiciyi YINE cagiracagi icin alanlari
      nil'e cekmek ZORUNLU; aksi halde cift serbest (access violation). }
    FreeAndNil(FMap);
    FreeAndNil(FStream);
    raise;
  end;
end;

destructor TBtdTree.Destroy;
begin
  try
    if (FStream <> nil) and (not FReadOnly) and FCommitOnClose then Commit;
  finally
    if FMap <> nil then FMap.Free;
    if FStream <> nil then FStream.Free;
    FStream := nil;
    inherited Destroy;
  end;
end;

procedure TBtdTree.InitializeNew;
var
  pg: TBtdPageBuf;
  m: PBtdMetaRec;
  i: Integer;
begin
  FSeq := 0;
  FRoot := 0;
  FPageCount := BTD_FIRST_DATA;
  FHeight := 0;
  FNKeys := 0;
  for i := 0 to BTD_META_PAGES - 1 do
  begin
    Inc(FSeq);
    FillChar(pg, BTD_PAGE_SIZE, 0);
    Hd(pg)^.Kind := BTD_KIND_META;
    Hd(pg)^.PageNo := LongWord(i);
    m := PBtdMetaRec(@pg[BTD_HDR_SIZE]);
    m^.Magic := BTD_MAGIC;
    m^.Ver := BTD_VER;
    m^.PageSize := BTD_PAGE_SIZE;
    m^.Seq := FSeq;
    m^.Root := FRoot;
    m^.PageCount := FPageCount;
    m^.Height := FHeight;
    m^.NKeys := FNKeys;
    FillChar(m^.Reserved, SizeOf(m^.Reserved), 0);
    Hd(pg)^.Crc := 0;
    Hd(pg)^.Crc := PageCrc(pg);
    FStream.Position := Int64(i) * BTD_PAGE_SIZE;
    FStream.WriteBuffer(pg, BTD_PAGE_SIZE);
  end;
  VDbFlushStream(FStream);
end;

procedure TBtdTree.LoadMeta;
var
  pg: TBtdPageBuf;
  m: PBtdMetaRec;
  i: Integer;
  bestOk: Boolean;
  bestSeq: Int64;
  meta: TBtdMetaRec;
  filePages: LongWord;
begin
  bestOk := False;
  bestSeq := 0;
  FillChar(meta, SizeOf(meta), 0);
  for i := 0 to BTD_META_PAGES - 1 do
  begin
    FStream.Position := Int64(i) * BTD_PAGE_SIZE;
    if FStream.Read(pg, BTD_PAGE_SIZE) <> BTD_PAGE_SIZE then Continue;
    if Hd(pg)^.Kind <> BTD_KIND_META then Continue;
    if not CrcOk(pg) then Continue;
    m := PBtdMetaRec(@pg[BTD_HDR_SIZE]);
    if (m^.Magic <> BTD_MAGIC) or (m^.Ver <> BTD_VER) or
       (m^.PageSize <> BTD_PAGE_SIZE) then Continue;
    if (m^.PageCount < BTD_FIRST_DATA) then Continue;
    if (m^.Root <> 0) and (m^.Root >= m^.PageCount) then Continue;
    if m^.Height > 64 then Continue;
    if bestOk and (m^.Seq <= bestSeq) then Continue;
    meta := m^;
    bestSeq := m^.Seq;
    bestOk := True;
  end;
  if not bestOk then
    raise EBtdError.Create('B+Tree: meta sayfalarinin ikisi de gecersiz');
  FSeq := meta.Seq;
  FRoot := meta.Root;
  FPageCount := meta.PageCount;
  FHeight := meta.Height;
  FNKeys := meta.NKeys;
  { Disk fiziksel olarak daha uzunsa (commit'ten once yazilmis ama
    baglanmamis sayfalar) evren dosya boyudur: erisilemeyen her sayfa
    serbesttir, boylece sizinti kendiliginden geri kazanilir. }
  filePages := LongWord(FStream.Size div BTD_PAGE_SIZE);
  if filePages > FPageCount then FPageCount := filePages;
  if FPageCount < BTD_FIRST_DATA then FPageCount := BTD_FIRST_DATA;
  MarkReachable;
end;

{ Agactan erisilebilen sayfalari isaretler ve geri kalanlari serbest listeye
  koyar. Dongu guvenligi icin isaret dizisi kullanilir. }
procedure TBtdTree.MarkReachable;
var
  mark: array of Byte;
  stack: array of LongWord;
  sp: Integer;
  no: LongWord;
  pg: TBtdPageBuf;
  i: Integer;
  err: string;

  procedure MarkAndPush(ANo: LongWord);
  begin
    if ANo < BTD_FIRST_DATA then Exit;
    if ANo >= FPageCount then Exit;
    if mark[ANo] <> 0 then Exit;
    mark[ANo] := 1;
    if sp >= Length(stack) then SetLength(stack, Length(stack) * 2 + 16);
    stack[sp] := ANo;
    Inc(sp);
  end;

begin
  SetLength(mark, FPageCount);
  FillChar(mark[0], FPageCount, 0);
  SetLength(stack, 64);
  sp := 0;
  if FRoot <> 0 then MarkAndPush(FRoot);
  while sp > 0 do
  begin
    Dec(sp);
    no := stack[sp];
    FStream.Position := Int64(no) * BTD_PAGE_SIZE;
    { Sprint D (6.1): eskiden kisa okuma ve CRC hatasi sessizce
      `Continue` ediliyordu; bozuk bir sayfa "erisilemez" sayilip serbest
      listeye dusuyor, ustune yeni veri yazilabiliyordu. Artik acik hata. }
    if FStream.Read(pg, BTD_PAGE_SIZE) <> BTD_PAGE_SIZE then
      raise EBtdError.CreateFmt(
        'B+Tree: agac sayfasi %d okunamadi (dosya kesik)', [no]);
    if not CrcOk(pg) then
      raise EBtdError.CreateFmt(
        'B+Tree: agac sayfasi %d CRC bozuk (serbest sayilamaz)', [no]);
    if not CheckPageStruct(pg, no, err) then
      raise EBtdError.CreateFmt('B+Tree: agac sayfasi %d bozuk: %s',
        [no, err]);
    if Hd(pg)^.Kind = BTD_KIND_INTERNAL then
      for i := 0 to Hd(pg)^.NKeys - 1 do
        MarkAndPush(IntChild(pg, i));
  end;
  FFreeCount := 0;
  if Length(FFree) < Integer(FPageCount) then
    SetLength(FFree, FPageCount);
  for i := BTD_FIRST_DATA to Integer(FPageCount) - 1 do
    if mark[i] = 0 then
    begin
      FFree[FFreeCount] := LongWord(i);
      Inc(FFreeCount);
    end;
end;

function TBtdTree.NewBuf: Integer;
begin
  Result := Length(FPages);
  SetLength(FPages, Result + 1);
  SetLength(FPageNo, Result + 1);
  FPageNo[Result] := 0;
  FillChar(FPages[Result], BTD_PAGE_SIZE, 0);
end;

function TBtdTree.BufIdx(ANo: LongWord): Integer;
begin
  if not FMap.TryGetValue(ANo, Result) then Result := -1;
end;

{ Sprint D (6.2): sayfa yapisal dogrulamasi. Slot offset/uzunluk, NKeys,
  hucre boyu, hucre cakismasi, anahtar sirasi ve ic dugum child sinirlari
  kontrol edilir. CRC gecerli olsa bile bozuk yapi kabul edilmez. }
function TBtdTree.CheckPageStruct(const P: TBtdPageBuf; ANo: LongWord;
  out AErr: string): Boolean;
var
  n, i, j: Integer;
  off, len, cellLen, minOff: Integer;
  k, pk: QWord;
  cno: LongWord;

  function Overlaps(AOff, ALen: Integer): Boolean;
  var
    q: Integer;
    o2, l2: Integer;
  begin
    Result := False;
    for q := 0 to i - 1 do
    begin
      o2 := Slt(P, q)^.Off;
      l2 := Slt(P, q)^.Len;
      if (AOff < o2 + l2) and (o2 < AOff + ALen) then Exit(True);
    end;
  end;

begin
  Result := False;
  AErr := '';
  n := Hd(P)^.NKeys;
  if (Hd(P)^.Kind <> BTD_KIND_INTERNAL) and (Hd(P)^.Kind <> BTD_KIND_LEAF) then
  begin
    AErr := Format('sayfa turu gecersiz (%d)', [Hd(P)^.Kind]);
    Exit;
  end;
  if Hd(P)^.Kind = BTD_KIND_LEAF then cellLen := BTD_LEAF_CELL
  else cellLen := BTD_INT_CELL;
  minOff := BTD_HDR_SIZE + n * BTD_SLOT_SIZE;
  if minOff > BTD_PAGE_SIZE then
  begin
    AErr := Format('NKeys cok buyuk (%d)', [n]);
    Exit;
  end;
  pk := 0;
  for i := 0 to n - 1 do
  begin
    off := Slt(P, i)^.Off;
    len := Slt(P, i)^.Len;
    if len <> cellLen then
    begin
      AErr := Format('hucre %d uzunlugu %d (beklenen %d)', [i, len, cellLen]);
      Exit;
    end;
    if off < minOff then
    begin
      AErr := Format('hucre %d ofseti %d slot alanina giriyor (min %d)',
        [i, off, minOff]);
      Exit;
    end;
    if off + len > BTD_PAGE_SIZE then
    begin
      AErr := Format('hucre %d sayfa disina tasiyor (%d+%d)', [i, off, len]);
      Exit;
    end;
    if Overlaps(off, len) then
    begin
      AErr := Format('hucre %d baska hucreyle cakisiyor', [i]);
      Exit;
    end;
    if Hd(P)^.Kind = BTD_KIND_LEAF then k := LeafKey(P, i)
    else k := IntKey(P, i);
    if (i > 0) and (k <= pk) then
    begin
      AErr := Format('anahtar sirasi bozuk (hucre %d: %u <= %u)',
        [i, k, pk]);
      Exit;
    end;
    pk := k;
    if Hd(P)^.Kind = BTD_KIND_INTERNAL then
    begin
      cno := IntChild(P, i);
      if (cno < BTD_FIRST_DATA) or (cno >= FPageCount) then
      begin
        AErr := Format('child %d aralik disi (%d)', [i, cno]);
        Exit;
      end;
      if cno = ANo then
      begin
        AErr := Format('child %d kendisini gosteriyor', [i]);
        Exit;
      end;
    end;
  end;
  Result := True;
end;

procedure TBtdTree.ReadPage(ANo: LongWord; var P: TBtdPageBuf);
var
  idx: Integer;
  err: string;
begin
  idx := BufIdx(ANo);
  if idx >= 0 then
  begin
    P := FPages[idx];
    Exit;
  end;
  if Int64(ANo) >= Int64(FPageCount) then
    raise EBtdError.CreateFmt('B+Tree: sayfa %d aralik disi', [ANo]);
  if FStream.Size < (Int64(ANo) + 1) * BTD_PAGE_SIZE then
    raise EBtdError.CreateFmt('B+Tree: dosya kesik, sayfa %d yok', [ANo]);
  FStream.Position := Int64(ANo) * BTD_PAGE_SIZE;
  if FStream.Read(P, BTD_PAGE_SIZE) <> BTD_PAGE_SIZE then
    raise EBtdError.CreateFmt('B+Tree: sayfa %d okunamadi', [ANo]);
  { Sprint D (6.1): diskten okunan her sayfa CRC ve yapisal olarak
    dogrulanir. Onceden Find/Insert/Delete yolunda hicbir kontrol yoktu;
    bozuk bir sayfa sessizce gecerli sayilip yanlis sonuc uretebiliyordu. }
  if Hd(P)^.PageNo <> ANo then
    raise EBtdError.CreateFmt(
      'B+Tree: sayfa %d kimligi yanlis (icinde %d)', [ANo, Hd(P)^.PageNo]);
  if not CrcOk(P) then
    raise EBtdError.CreateFmt('B+Tree: sayfa %d CRC bozuk', [ANo]);
  if not CheckPageStruct(P, ANo, err) then
    raise EBtdError.CreateFmt('B+Tree: sayfa %d bozuk: %s', [ANo, err]);
end;

{ Yeni bir sayfa surumu olusturur (golge sayfalama). }
procedure TBtdTree.PutPage(ANo: LongWord; const P: TBtdPageBuf);
var
  idx: Integer;
begin
  idx := BufIdx(ANo);
  if idx < 0 then
  begin
    idx := NewBuf;
    FPageNo[idx] := ANo;
    FMap.Add(ANo, idx);
  end;
  FPages[idx] := P;
end;

function TBtdTree.AllocPage(AKind, ALevel: Byte): LongWord;
var
  pg: TBtdPageBuf;
  idx: Integer;
begin
  if FFreeCount > 0 then
  begin
    Dec(FFreeCount);
    Result := FFree[FFreeCount];
  end
  else
  begin
    Result := FPageCount;
    Inc(FPageCount);
  end;
  InitPage(pg, AKind, ALevel);
  Hd(pg)^.PageNo := Result;
  idx := NewBuf;
  FPageNo[idx] := Result;
  FMap.Add(Result, idx);
  FPages[idx] := pg;
end;

{ Yerinde guncelleme YOK: sayfa bu islemde zaten yeniyse ayni numara
  kullanilir; aksi halde yeni bir sayfaya kopyalanir ve eskisi commit
  sonrasi serbest birakilir. }
function TBtdTree.PageMut(ANo: LongWord): LongWord;
var
  idx: Integer;
  pg: TBtdPageBuf;
begin
  idx := BufIdx(ANo);
  if idx >= 0 then Exit(ANo);
  Result := AllocPage(0, 0);
  ReadPage(ANo, pg);
  PutPage(Result, pg);
  PushPending(ANo);
end;

procedure TBtdTree.PushPending(ANo: LongWord);
begin
  if FPendingCount >= Length(FPending) then
    SetLength(FPending, Length(FPending) * 2 + 16);
  FPending[FPendingCount] := ANo;
  Inc(FPendingCount);
end;

procedure TBtdTree.PushFree(ANo: LongWord);
begin
  if ANo < BTD_FIRST_DATA then Exit;
  if FFreeCount >= Length(FFree) then
    SetLength(FFree, Length(FFree) * 2 + 16);
  FFree[FFreeCount] := ANo;
  Inc(FFreeCount);
end;

procedure TBtdTree.DropBuf(ANo: LongWord);
var
  idx: Integer;
begin
  idx := BufIdx(ANo);
  if idx < 0 then Exit;
  FMap.Remove(ANo);
  FPageNo[idx] := 0;   { tombstone: commit'te yazilmaz }
end;

procedure TBtdTree.ReleasePage(ANo: LongWord);
begin
  if ANo < BTD_FIRST_DATA then Exit;
  if BufIdx(ANo) >= 0 then
  begin
    { Bu islemde olusturuldu, diske hic gitmedi: hemen geri doner. }
    DropBuf(ANo);
    PushFree(ANo);
  end
  else
  begin
    PushPending(ANo);
  end;
end;

procedure TBtdTree.WriteMeta;
var
  pg: TBtdPageBuf;
  m: PBtdMetaRec;
  no: LongWord;
begin
  Inc(FSeq);
  no := LongWord(FSeq and 1);
  FillChar(pg, BTD_PAGE_SIZE, 0);
  Hd(pg)^.Kind := BTD_KIND_META;
  Hd(pg)^.PageNo := no;
  m := PBtdMetaRec(@pg[BTD_HDR_SIZE]);
  m^.Magic := BTD_MAGIC;
  m^.Ver := BTD_VER;
  m^.PageSize := BTD_PAGE_SIZE;
  m^.Seq := FSeq;
  m^.Root := FRoot;
  m^.PageCount := FPageCount;
  m^.Height := FHeight;
  m^.Pad := 0;
  m^.NKeys := FNKeys;
  FillChar(m^.Reserved, SizeOf(m^.Reserved), 0);
  if Assigned(FOnBeforeMeta) then FOnBeforeMeta();
  Hd(pg)^.Crc := 0;
  Hd(pg)^.Crc := PageCrc(pg);
  FStream.Position := Int64(no) * BTD_PAGE_SIZE;
  FStream.WriteBuffer(pg, BTD_PAGE_SIZE);
  Inc(FPagesWritten);
  { Meta yazimi COMMIT NOKTASI: buradan sonra eski surumler serbesttir. }
  VDbFlushStream(FStream);
  Inc(FSyncCount);
end;

procedure TBtdTree.Commit;
var
  i: Integer;
  touched: Boolean;
  pg: TBtdPageBuf;
begin
  if FReadOnly then Exit;
  touched := False;
  for i := 0 to Length(FPages) - 1 do
  begin
    if FPageNo[i] = 0 then Continue;
    { Golge kopya eski basligi tasir: kimlik ve CRC burada damgalanir. }
    pg := FPages[i];
    Hd(pg)^.PageNo := FPageNo[i];
    Hd(pg)^.Crc := 0;
    Hd(pg)^.Crc := PageCrc(pg);
    FPages[i] := pg;
    FStream.Position := Int64(FPageNo[i]) * BTD_PAGE_SIZE;
    FStream.WriteBuffer(pg, BTD_PAGE_SIZE);
    Inc(FPagesWritten);
    touched := True;
  end;
  if touched then
  begin
    { Meta'dan ONCE veri sayfalari durabil olmali. }
    VDbFlushStream(FStream);
    Inc(FSyncCount);
  end;
  WriteMeta;
  for i := 0 to FPendingCount - 1 do
    PushFree(FPending[i]);
  FPendingCount := 0;
  FMap.Clear;
  SetLength(FPages, 0);
  SetLength(FPageNo, 0);
  FTxnOps := 0;
end;

procedure TBtdTree.Sync;
begin
  Commit;
end;

procedure TBtdTree.AfterOp;
begin
  Inc(FTxnOps);
  if (FAutoCommit > 0) and (FTxnOps >= FAutoCommit) then Commit;
end;

procedure TBtdTree.NormalizeRoot;
var
  pg: TBtdPageBuf;
  c, r: LongWord;
begin
  while FRoot <> 0 do
  begin
    ReadPage(FRoot, pg);
    if Hd(pg)^.Kind <> BTD_KIND_INTERNAL then Break;
    if Hd(pg)^.NKeys > 1 then Break;
    c := IntChild(pg, 0);
    r := FRoot;
    FRoot := c;
    if FHeight > 1 then Dec(FHeight);
    ReleasePage(r);
  end;
end;

function TBtdTree.FirstOf(ANo: LongWord; out AKey2, AVal: QWord): Boolean;
var
  pg: TBtdPageBuf;
begin
  ReadPage(ANo, pg);
  while Hd(pg)^.Kind = BTD_KIND_INTERNAL do
  begin
    ANo := IntChild(pg, 0);
    ReadPage(ANo, pg);
  end;
  if Hd(pg)^.NKeys = 0 then
  begin
    AKey2 := 0;
    AVal := 0;
    Exit(False);
  end;
  AKey2 := LeafKey(pg, 0);
  AVal := LeafVal(pg, 0);
  Result := True;
end;

function TBtdTree.SeekGE(ANo: LongWord; AKey: QWord;
  out AKey2, AVal: QWord): Boolean;
var
  pg: TBtdPageBuf;
  idx, pos, n: Integer;
begin
  AKey2 := 0;
  AVal := 0;
  ReadPage(ANo, pg);
  if Hd(pg)^.Kind = BTD_KIND_LEAF then
  begin
    n := Hd(pg)^.NKeys;
    pos := LeafLowerBound(pg, AKey);
    if pos >= n then Exit(False);
    AKey2 := LeafKey(pg, pos);
    AVal := LeafVal(pg, pos);
    Exit(True);
  end;
  idx := ChildIndex(pg, AKey);
  if SeekGE(IntChild(pg, idx), AKey, AKey2, AVal) then Exit(True);
  if idx + 1 <= Hd(pg)^.NKeys - 1 then
    Exit(FirstOf(IntChild(pg, idx + 1), AKey2, AVal));
  Result := False;
end;

function TBtdTree.Find(AKey: QWord; out AVal: QWord): Boolean;
var
  k: QWord;
begin
  AVal := 0;
  Result := False;
  if FRoot = 0 then Exit;
  if not SeekGE(FRoot, AKey, k, AVal) then Exit;
  if k <> AKey then Exit(False);
  Result := True;
end;

function TBtdTree.NextAfter(AKey: QWord; out AKey2, AVal: QWord): Boolean;
begin
  AKey2 := 0;
  AVal := 0;
  if FRoot = 0 then Exit(False);
  Result := SeekGE(FRoot, AKey, AKey2, AVal);
end;

procedure TBtdTree.Walk(AProc: TBtdWalkProc);

  procedure Visit(ANo: LongWord);
  var
    P: TBtdPageBuf;
    i: Integer;
  begin
    ReadPage(ANo, P);
    if Hd(P)^.Kind = BTD_KIND_LEAF then
    begin
      for i := 0 to Hd(P)^.NKeys - 1 do
        AProc(LeafKey(P, i), LeafVal(P, i));
      Exit;
    end;
    for i := 0 to Hd(P)^.NKeys - 1 do
      Visit(IntChild(P, i));
  end;

begin
  if FRoot = 0 then Exit;
  Visit(FRoot);
end;

function TBtdTree.Insert(AKey, AVal: QWord): Boolean;
const
  MAX_DEPTH = 40;
var
  pathNo: array[0..MAX_DEPTH - 1] of LongWord;
  pathIdx: array[0..MAX_DEPTH - 1] of Integer;
  depth, n, i, j, pos, mid, idx, lvl: Integer;
  leafNo, curNo, pno, pnew, childNo, newRoot: LongWord;
  carryKey: QWord;
  splitPending: Boolean;
  pg, rp: TBtdPageBuf;
  ks: array of TBtdKeyVal;
  cs: array of TBtdKeyChild;
begin
  if FReadOnly then
    raise EBtdError.Create('B+Tree: salt okunur');
  if FRoot = 0 then
  begin
    childNo := AllocPage(BTD_KIND_LEAF, 0);
    ReadPage(childNo, pg);
    LeafInsertCell(pg, 0, AKey, AVal);
    PutPage(childNo, pg);
    FRoot := childNo;
    FHeight := 1;
    Inc(FNKeys);
    AfterOp;
    Exit(True);
  end;

  depth := 0;
  leafNo := FRoot;
  ReadPage(leafNo, pg);
  while Hd(pg)^.Kind = BTD_KIND_INTERNAL do
  begin
    if depth >= MAX_DEPTH then
      raise EBtdError.CreateFmt('B+Tree: agac cok derin (%d)', [MAX_DEPTH]);
    idx := ChildIndex(pg, AKey);
    pathNo[depth] := leafNo;
    pathIdx[depth] := idx;
    Inc(depth);
    leafNo := IntChild(pg, idx);
    ReadPage(leafNo, pg);
  end;

  n := Hd(pg)^.NKeys;
  pos := LeafLowerBound(pg, AKey);
  splitPending := False;
  carryKey := 0;
  childNo := 0;

  if (pos < n) and (LeafKey(pg, pos) = AKey) then
  begin
    curNo := PageMut(leafNo);
    ReadPage(curNo, pg);
    WQ(CP(pg, pos) + 8, AVal);
    PutPage(curNo, pg);
    Result := False;
  end
  else if PageFree(pg) >= BTD_LEAF_CELL + BTD_SLOT_SIZE then
  begin
    curNo := PageMut(leafNo);
    ReadPage(curNo, pg);
    LeafInsertCell(pg, LeafLowerBound(pg, AKey), AKey, AVal);
    PutPage(curNo, pg);
    Inc(FNKeys);
    Result := True;
  end
  else
  begin
    SetLength(ks, n + 1);
    for i := 0 to n - 1 do
    begin
      j := i;
      if i >= pos then j := i + 1;
      ks[j].K := LeafKey(pg, i);
      ks[j].V := LeafVal(pg, i);
    end;
    ks[pos].K := AKey;
    ks[pos].V := AVal;
    mid := (n + 1) div 2;
    curNo := PageMut(leafNo);
    ReadPage(curNo, pg);
    InitPage(pg, BTD_KIND_LEAF, 0);
    for i := 0 to mid - 1 do
      LeafInsertCell(pg, i, ks[i].K, ks[i].V);
    PutPage(curNo, pg);
    childNo := AllocPage(BTD_KIND_LEAF, 0);
    ReadPage(childNo, rp);
    for i := mid to n do
      LeafInsertCell(rp, i - mid, ks[i].K, ks[i].V);
    PutPage(childNo, rp);
    carryKey := ks[mid].K;
    splitPending := True;
    Inc(FNKeys);
    Result := True;
  end;

  { Ayiriciyi yukari tasi; her seviyede YENI surum uretilir. }
  while depth > 0 do
  begin
    Dec(depth);
    pno := pathNo[depth];
    idx := pathIdx[depth];
    pnew := PageMut(pno);
    ReadPage(pnew, pg);
    SetChild(pg, idx, curNo);
    if splitPending then
    begin
      if PageFree(pg) >= BTD_INT_CELL + BTD_SLOT_SIZE then
      begin
        IntInsertCell(pg, idx + 1, carryKey, childNo);
        PutPage(pnew, pg);
        splitPending := False;
      end
      else
      begin
        n := Hd(pg)^.NKeys;
        lvl := Hd(pg)^.Level;
        SetLength(cs, n + 1);
        for i := 0 to n - 1 do
        begin
          j := i;
          if i >= idx + 1 then j := i + 1;
          cs[j].K := IntKey(pg, i);
          cs[j].C := IntChild(pg, i);
        end;
        cs[idx + 1].K := carryKey;
        cs[idx + 1].C := childNo;
        mid := (n + 1) div 2;
        carryKey := cs[mid].K;
        InitPage(pg, BTD_KIND_INTERNAL, lvl);
        for i := 0 to mid - 1 do
          IntInsertCell(pg, i, cs[i].K, cs[i].C);
        PutPage(pnew, pg);
        childNo := AllocPage(BTD_KIND_INTERNAL, lvl);
        ReadPage(childNo, rp);
        IntInsertCell(rp, 0, 0, cs[mid].C);
        for i := mid + 1 to n do
          IntInsertCell(rp, i - mid, cs[i].K, cs[i].C);
        PutPage(childNo, rp);
      end;
    end
    else
      PutPage(pnew, pg);
    curNo := pnew;
  end;

  if splitPending then
  begin
    newRoot := AllocPage(BTD_KIND_INTERNAL, FHeight);
    ReadPage(newRoot, rp);
    IntInsertCell(rp, 0, 0, curNo);
    IntInsertCell(rp, 1, carryKey, childNo);
    PutPage(newRoot, rp);
    FRoot := newRoot;
    Inc(FHeight);
  end
  else
    FRoot := curNo;

  AfterOp;
end;

function TBtdTree.Delete(AKey: QWord): Boolean;
const
  MAX_DEPTH = 40;
var
  pathNo: array[0..MAX_DEPTH - 1] of LongWord;
  pathIdx: array[0..MAX_DEPTH - 1] of Integer;
  depth, n, pos: Integer;
  leafNo, curNo, pno, pnew: LongWord;
  unlink: Boolean;
  pg: TBtdPageBuf;
begin
  if FReadOnly then
    raise EBtdError.Create('B+Tree: salt okunur');
  if FRoot = 0 then Exit(False);

  depth := 0;
  leafNo := FRoot;
  ReadPage(leafNo, pg);
  while Hd(pg)^.Kind = BTD_KIND_INTERNAL do
  begin
    if depth >= MAX_DEPTH then
      raise EBtdError.CreateFmt('B+Tree: agac cok derin (%d)', [MAX_DEPTH]);
    pos := ChildIndex(pg, AKey);
    pathNo[depth] := leafNo;
    pathIdx[depth] := pos;
    Inc(depth);
    leafNo := IntChild(pg, pos);
    ReadPage(leafNo, pg);
  end;

  n := Hd(pg)^.NKeys;
  pos := LeafLowerBound(pg, AKey);
  if (pos >= n) or (LeafKey(pg, pos) <> AKey) then Exit(False);

  curNo := PageMut(leafNo);
  ReadPage(curNo, pg);
  CellRemove(pg, pos);
  PutPage(curNo, pg);
  Dec(FNKeys);
  unlink := (Hd(pg)^.NKeys = 0) and (leafNo <> FRoot);
  if unlink then
    ReleasePage(curNo);

  while depth > 0 do
  begin
    Dec(depth);
    pno := pathNo[depth];
    pos := pathIdx[depth];
    pnew := PageMut(pno);
    ReadPage(pnew, pg);
    if unlink then
    begin
      CellRemove(pg, pos);
      if Hd(pg)^.NKeys = 0 then
      begin
        PutPage(pnew, pg);
        ReleasePage(pnew);
      end
      else
      begin
        PutPage(pnew, pg);
        unlink := False;
        curNo := pnew;
      end;
    end
    else
    begin
      SetChild(pg, pos, curNo);
      PutPage(pnew, pg);
      curNo := pnew;
    end;
  end;

  if unlink then
    raise EBtdError.Create('B+Tree: kok bos kaldi (ic tutarsizlik)');

  FRoot := curNo;
  NormalizeRoot;
  AfterOp;
  Result := True;
end;

function TBtdTree.Count: Int64;
begin
  Result := FNKeys;
end;

function TBtdTree.Height: Integer;
begin
  Result := FHeight;
end;

function TBtdTree.PageCount: LongWord;
begin
  Result := FPageCount;
end;

function TBtdTree.FreePageCount: Integer;
begin
  Result := FFreeCount;
end;

function TBtdTree.RootPage: LongWord;
begin
  Result := FRoot;
end;

function TBtdTree.DenseLeaves(out ARep: string): Boolean;
var
  leaves, usedSlots, cells: Integer;

  procedure Visit(ANo: LongWord);
  var
    P: TBtdPageBuf;
    i: Integer;
  begin
    ReadPage(ANo, P);
    if Hd(P)^.Kind = BTD_KIND_LEAF then
    begin
      Inc(leaves);
      Inc(cells, Hd(P)^.NKeys);
      Inc(usedSlots, Hd(P)^.NKeys * BTD_LEAF_CELL);
      Exit;
    end;
    for i := 0 to Hd(P)^.NKeys - 1 do
      Visit(IntChild(P, i));
  end;

begin
  leaves := 0;
  cells := 0;
  usedSlots := 0;
  if FRoot <> 0 then Visit(FRoot);
  ARep := Format('yaprak=%d hucre=%d doluluk=%d/%d',
    [leaves, cells, usedSlots, leaves * BTD_PAGE_SIZE]);
  Result := leaves > 0;
end;

{ ------------------------------------------------------------- dogrulama }

type
  TBtdVerifyCtx = record
    Mark: array of Byte;
    Err: string;
    Hata: Boolean;
    Leaves: Integer;
  end;

function TBtdTree.Verify(out ARep: string): Boolean;
var
  ctx: TBtdVerifyCtx;
  pg: TBtdPageBuf;
  i, freeCnt: Integer;

  procedure Fail(const AMsg: string);
  begin
    if not ctx.Hata then ctx.Err := AMsg;
    ctx.Hata := True;
  end;

  function CheckNode(ANo, AExpectLevel: LongWord;
    out AMin, AMax: QWord; out ACount: Int64): Boolean;
  var
    P: TBtdPageBuf;
    j, k: Integer;
    cno: LongWord;
    cmn, cmx, prevMax, sep: QWord;
    ccount: Int64;
  begin
    Result := False;
    if ANo >= FPageCount then
    begin
      Fail(Format('sayfa %d aralik disi', [ANo]));
      Exit;
    end;
    if ctx.Mark[ANo] <> 0 then
    begin
      Fail(Format('sayfa %d iki kez referanslandi', [ANo]));
      Exit;
    end;
    ctx.Mark[ANo] := 1;
    { Bozuk bir alt-cocuk isaretcisi aralik disi cikabilir. Dogrulayici
      ISTISNA SIZDIRMAZ: bunu da bir bulgu olarak raporlar. }
    try
      ReadPage(ANo, P);
    except
      on E: EBtdError do
      begin
        Fail(E.Message);
        Exit;
      end;
    end;
    if Hd(P)^.PageNo <> ANo then
    begin
      Fail(Format('sayfa %d kimligi yanlis (%d)', [ANo, Hd(P)^.PageNo]));
      Exit;
    end;
    if not CrcOk(P) then
    begin
      Fail(Format('sayfa %d CRC bozuk', [ANo]));
      Exit;
    end;
    if Hd(P)^.Level <> AExpectLevel then
    begin
      Fail(Format('sayfa %d seviyesi %d, beklenen %d',
        [ANo, Hd(P)^.Level, AExpectLevel]));
      Exit;
    end;
    k := Hd(P)^.NKeys;
    if Hd(P)^.Kind = BTD_KIND_LEAF then
    begin
      if k = 0 then
      begin
        if ANo <> FRoot then
        begin
          Fail(Format('bos yaprak %d agacta kaldi', [ANo]));
          Exit;
        end;
        AMin := 0;
        AMax := 0;
        ACount := 0;
        Exit(True);
      end;
      Inc(ctx.Leaves);
      AMin := LeafKey(P, 0);
      AMax := AMin;
      for j := 0 to k - 1 do
      begin
        if LeafKey(P, j) > AMax then AMax := LeafKey(P, j);
        if j > 0 then
          if LeafKey(P, j) <= LeafKey(P, j - 1) then
          begin
            Fail(Format('yaprak %d icinde sira bozuk (%d)', [ANo, j]));
            Exit;
          end;
      end;
      ACount := k;
      Exit(True);
    end;
    if Hd(P)^.Kind <> BTD_KIND_INTERNAL then
    begin
      Fail(Format('sayfa %d turu agac icin gecersiz (%d)',
        [ANo, Hd(P)^.Kind]));
      Exit;
    end;
    if k < 1 then
    begin
      Fail(Format('ic sayfa %d hucre barindirmiyor', [ANo]));
      Exit;
    end;
    if AExpectLevel < 1 then
    begin
      Fail(Format('ic sayfa %d seviye 0', [ANo]));
      Exit;
    end;
    ACount := 0;
    AMin := 0;
    AMax := 0;
    prevMax := 0;
    for j := 0 to k - 1 do
    begin
      cno := IntChild(P, j);
      if not CheckNode(cno, AExpectLevel - 1, cmn, cmx, ccount) then Exit;
      if j = 0 then
      begin
        if ccount = 0 then
        begin
          Fail(Format('ic sayfa %d bos alt agac %d', [ANo, cno]));
          Exit;
        end;
        AMin := cmn;
      end
      else
      begin
        sep := IntKey(P, j);
        { Yonlendirme kurali: onceki alt agacin TUM anahtarlari ayiricidan
          KUCUK, bu alt agacin TUM anahtarlari ayiricidan BUYUK-ESIT.
          Tembel silme ayiriciyi bayatlatabilir (alt agacin min'i buyur);
          bu yuzden `sep <= cmn` istenir, `sep = cmn` DEGIL. }
        if not (sep > prevMax) then
        begin
          Fail(Format('ic sayfa %d ayirici %d onceki alt agaci kesiyor',
            [ANo, j]));
          Exit;
        end;
        if ccount > 0 then
          if not (sep <= cmn) then
          begin
            Fail(Format('ic sayfa %d ayirici %d alt agacla uyusmuyor',
              [ANo, j]));
            Exit;
          end;
      end;
      Inc(ACount, ccount);
      AMax := cmx;
      prevMax := cmx;
    end;
    Result := True;
  end;

var
  mn, mx: QWord;
  cnt: Int64;
  rootNo: LongWord;
  seq0, seq1: Int64;
begin
  Result := False;
  ARep := '';
  ctx.Hata := False;
  ctx.Err := '';
  ctx.Leaves := 0;
  if FPageCount < BTD_FIRST_DATA then
  begin
    ARep := 'sayfa sayaci gecersiz';
    Exit;
  end;
  { Bu islemde uretilen yeni sayfalar henuz diske yazilmamis olabilir
    (commit edilmedi); bu yuzden dosya boyu ile sayfa sayaci arasinda
    esitlik ZORLANMAZ. Kalici dogrulama acilistan sonra yapilir. }
  SetLength(ctx.Mark, FPageCount);
  FillChar(ctx.Mark[0], FPageCount, 0);

  { 1) Meta sayfalari: en az biri gecerli olmali. }
  seq0 := -1;
  seq1 := -1;
  for i := 0 to BTD_META_PAGES - 1 do
  begin
    FStream.Position := Int64(i) * BTD_PAGE_SIZE;
    if FStream.Read(pg, BTD_PAGE_SIZE) <> BTD_PAGE_SIZE then Continue;
    if Hd(pg)^.Kind <> BTD_KIND_META then Continue;
    if not CrcOk(pg) then Continue;
    if PBtdMetaRec(@pg[BTD_HDR_SIZE])^.Magic <> BTD_MAGIC then Continue;
    if i = 0 then seq0 := PBtdMetaRec(@pg[BTD_HDR_SIZE])^.Seq
    else seq1 := PBtdMetaRec(@pg[BTD_HDR_SIZE])^.Seq;
  end;
  if (seq0 < 0) and (seq1 < 0) then
  begin
    ARep := 'meta sayfalarinin ikisi de gecersiz';
    Exit;
  end;

  { 2) Agac yapisi (commit edilmemis yeni surumler dahil). }
  rootNo := FRoot;
  if rootNo = 0 then
  begin
    if FNKeys <> 0 then
    begin
      ARep := 'kok yok ama anahtar sayaci sifir degil';
      Exit;
    end;
    cnt := 0;
  end
  else
  begin
    if not CheckNode(rootNo, FHeight - 1, mn, mx, cnt) then
    begin
      ARep := ctx.Err;
      Exit;
    end;
    if cnt <> FNKeys then
    begin
      ARep := Format('anahtar sayaci %d, agacta %d', [FNKeys, cnt]);
      Exit;
    end;
  end;

  { 3) Serbest/sizinti sayimi: erisilemeyen sayfalar. }
  freeCnt := 0;
  for i := BTD_FIRST_DATA to Integer(FPageCount) - 1 do
    if ctx.Mark[i] = 0 then Inc(freeCnt);

  ARep := Format('sayfa=%d yukseklik=%d anahtar=%d yaprak=%d serbest=%d islem_sayfasi=%d',
    [FPageCount, FHeight, cnt, ctx.Leaves, freeCnt, Length(FPages)]);
  Result := True;
end;

end.
