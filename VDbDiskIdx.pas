unit VDbDiskIdx;
{ Kalici (diskte) ikincil indeks deposu - SKILL12.

  VDbBTreeDisk'ten farki: anahtarlar sabit 8 bayt degil, DEGISKEN uzunlukta
  metindir. Boylece motorun gercek indeks anahtarlari (tek kolon metin, cok
  kolonlu "<len>:<val>..." kodlamasi) ve siralamasi dogrudan bu agacta
  saklanabilir. Siralama motordan enjekte edilir (TVDbDixCmp), boylece
  TIdxSkipCmp ile ayni sonuc uretilir.

  Model (veri kaybi yok):
    - Indeks turetmedir; dogru olan heap'tir. Stamp = heap commit sayaci.
    - Yazma sirasi: once heap commit (WAL + fsync), sonra indeks delta'si
      uygulanir ve meta Stamp = yeni sayac ile yazilir.
    - Arada cokme olursa Stamp uyusmaz; acilista indeks heap taramasindan
      yeniden kurulur. Bayat indeks asla servis edilmez.

  Sayfa duzeni: 4096 bayt. 0/1 meta (cift kopya = commit noktasi), veri 2'den
  baslar. Her sayfada CRC32 vardir ve okurken dogrulanir. Yazma COW'dur:
  hicbir sayfa yerinde guncellenmez, meta en son yazilir. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, VDbCrc32, VDbSync;

const
  DIX_PAGE_SIZE   = 4096;
  DIX_MAGIC       = $31584944; { 'DIX1' }
  DIX_VER         = 1;
  DIX_HDR_SIZE    = 32;
  DIX_META_PAGES  = 2;
  DIX_FIRST_DATA  = 2;
  DIX_LEAF        = 2;
  DIX_INTERNAL    = 1;
  DIX_META        = 3;
  DIX_CACHE_PAGES = 64;        { salt-okunur sayfa onbellegi: 256 KB }
  DIX_MAX_KEY     = 1000;      { daha buyuk anahtar/deger reddedilir }
  DIX_MAX_CELL    = 3000;      { tek hucre bir sayfaya sigmali }

  { SKILL12 cokme matrisi: DETERMINISTIK enjeksiyon noktalari. Uretimde
    VDbDixCrashStage = DIX_CRASH_NONE iken yalnizca bir tamsayi
    karsilastirmasi yapilir; kanca cagrilmaz. Testler sureci burada GERCEK
    olarak oldurur (Close/Destroy/finalization calismaz).

    Bolunme/birlestirme/kok degisimi BELLEKTE olur ve diske ancak Commit
    icinde iner; bu yuzden gozlenebilir cokme pencereleri sayfa yazimi ve
    meta yazimidir. }
  DIX_CRASH_NONE      = 0;
  DIX_CRASH_PRE_PAGE  = 1;  { sayfa yazimi oncesi: hicbir sey yazilmadi }
  DIX_CRASH_POST_PAGE = 2;  { sayfalar indi, META yazilmadi (eski commit) }
  DIX_CRASH_PRE_META  = 3;  { meta yazimi oncesi (POST_PAGE ile ayni durum) }
  DIX_CRASH_POST_META = 4;  { meta yazildi, fsync YOK }
  DIX_CRASH_MID_PAGES = 5;  { ilk sayfa indi, kalanlar inmedi, fsync YOK }

type
  TVdbDixCrashHook = procedure;

type
  EDixError = class(Exception);
  EDixCellTooLarge = class(EDixError);

  TDixPageBuf = array[0..DIX_PAGE_SIZE - 1] of Byte;

  TVDbDixEntry = record
    Key: string;
    Val: string;
    Cov: string;
  end;
  TVDbDixEntries = array of TVDbDixEntry;

  TDixSep = record
    { Ayirici = sag alt agacin ILK girisinin TAM anahtari (Key + Val).
      Yalniz Key tutmak yetmez: ayni anahtarin farkli pk'lari bir sayfa
      bolunmesinin iki yanina dusebilir ve o zaman "esitse saga git"
      yonlendirmesi soldaki pk'lari atlar (sessiz eksik satir). }
    Key: string;
    Val: string;
    Child: LongWord;
  end;
  TDixSepArray = array of TDixSep;

  { Siralama motordan enjekte edilir.
    CompareEntries: tam giris sirasi (anahtar + deger) = TIdxSkipCmp.FullCompare.
    CompareKeyBound: aralik siniri icin anahtar-only karsilastirma =
      TIdxSkipCmp.LeadCompare / ExactCompare. }
  TVDbDixCmp = class
  public
    function CompareEntries(const AKey1, AVal1, AKey2, AVal2: string): Integer; virtual; abstract;
    function CompareKeyBound(const AKey, ABound: string): Integer; virtual; abstract;
  end;

  TDixCursor = record
    PathNo: array[0..63] of LongWord;
    PathIdx: array[0..63] of Integer;
    Depth: Integer;
    Leaf: TVDbDixEntries;
    Pos: Integer;
    Valid: Boolean;
  end;

  TVDbDiskIdx = class
  private
    FFileName: string;
    FStream: THandleStream;
    FReadOnly: Boolean;
    FCmp: TVDbDixCmp;
    FSeq: Int64;
    FRoot: LongWord;
    FPageCount: LongWord;
    FHeight: Integer;
    FNKeys: Int64;
    FStamp: Int64;
    FSig: Int64;
    FPages: array of TDixPageBuf;
    FPageNo: array of LongWord;
    FMap: TDictionary<LongWord, Integer>;
    FFree: array of LongWord;
    FFreeCount: Integer;
    FPending: array of LongWord;
    FPendingCount: Integer;
    FCache: TDictionary<LongWord, TDixPageBuf>;
    FCacheQ: array of LongWord;
    FCacheN: Integer;
    FModified: Boolean;
    FTxnOps: Integer;
    FAutoCommit: Integer;
    FCommitOnClose: Boolean;
    FSyncCount: Int64;
    FPagesWritten: Int64;
    FPagesRead: Int64;
  private
    procedure ResetStorage;
    procedure LoadMeta;
    procedure MarkReachable;
    function NewPage(AKind, ALevel: Byte): LongWord;
    function BufIdx(ANo: LongWord): Integer;
    procedure StoreBuf(ANo: LongWord; const P: TDixPageBuf);
    procedure LoadBuf(ANo: LongWord; out P: TDixPageBuf);
    procedure ReadPage(ANo: LongWord; out P: TDixPageBuf);
    procedure ReadPageCached(ANo: LongWord; out P: TDixPageBuf);
    procedure DropCache;
    procedure PushPending(ANo: LongWord);
    procedure PushFree(ANo: LongWord);
    procedure ReleasePage(ANo: LongWord);
    function MutPage(ANo: LongWord; out AKind, ALevel: Byte): LongWord;
    procedure WriteMeta;
    procedure AfterOp;
    procedure CrashPoint(AStage: Integer);
    procedure EnsureWritable;
    procedure DecodeLeaf(const P: TDixPageBuf; out E: TVDbDixEntries);
    procedure DecodeInt(const P: TDixPageBuf; out S: TDixSepArray; out ALevel: Integer);
    procedure EncodeLeaf(var P: TDixPageBuf; ALevel: Integer; const E: TVDbDixEntries);
    procedure EncodeInt(var P: TDixPageBuf; ALevel: Integer; const S: TDixSepArray);
    procedure SetLeaf(ANo: LongWord; ALevel: Integer; const E: TVDbDixEntries);
    procedure SetInt(ANo: LongWord; ALevel: Integer; const S: TDixSepArray);
    function LeafSize(const E: TVDbDixEntries): Integer;
    function IntSize(const S: TDixSepArray): Integer;
    function CursorFirst(out C: TDixCursor): Boolean;
    function CursorSeekKey(out C: TDixCursor; const ABound: string; AInclusive: Boolean): Boolean;
    function CursorSeekGT(out C: TDixCursor; const AKey, AVal: string): Boolean;
    function CursorNext(var C: TDixCursor): Boolean;
    procedure DescendLeftmost(ANo: LongWord; var C: TDixCursor);
    function ChildIdxKey(const S: TDixSepArray; const AKey, AVal: string): Integer;
    function LeafLowerBoundKey(const E: TVDbDixEntries; const AKey: string): Integer;
    function KeyCmp(const A, B: string): Integer;
    function AppendEntry(var A: TVDbDixEntries; N: Integer; const E: TVDbDixEntry): Integer;
  public
    class function TryOpen(const AFileName: string; ACmp: TVDbDixCmp; AReadOnly: Boolean;
      out ATree: TVDbDiskIdx; out AReason: string): Boolean;
    class function CreateNew(const AFileName: string; ACmp: TVDbDixCmp): TVDbDiskIdx;
    destructor Destroy; override;
    procedure BuildSorted(const AEntries: TVDbDixEntries; AStamp, ASig: Int64);
    function Insert(const AKey, AVal, ACov: string): Boolean;
    function Remove(const AKey, AVal: string): Boolean;
    function CollectRange(const ALo, AHi: string; AHasLo, AHasHi, ALoInc, AHiInc: Boolean;
      out AEntries: TVDbDixEntries): Integer;
    function CountRange(const ALo, AHi: string; AHasLo, AHasHi, ALoInc, AHiInc: Boolean): Int64;
    function All(out AEntries: TVDbDixEntries): Integer;
    function Find(const AKey, AVal: string; out ACov: string): Boolean;
    function Count: Int64;
    function Height: Integer;
    function PageCount: LongWord;
    function RootPage: LongWord;
    function FreePageCount: Integer;
    function Verify(out AReport: string): Boolean;
    procedure Commit;
    property Stamp: Int64 read FStamp write FStamp;
    property Signature: Int64 read FSig write FSig;
    property FileName: string read FFileName;
    property PagesWritten: Int64 read FPagesWritten;
    { SKILL12: diskten okunan sayfa sayisi. Onbellek 64 sayfa ile sinirli
      oldugundan bu sayac "indeksin tamami yuklendi mi" sorusunu olcer. }
    property PagesRead: Int64 read FPagesRead;
    property SyncCount: Int64 read FSyncCount;
    property CommitOnClose: Boolean read FCommitOnClose write FCommitOnClose;
    property AutoCommitEvery: Integer read FAutoCommit write FAutoCommit;
    property ReadOnly: Boolean read FReadOnly;
  end;

function DixCellSize(const AKey, AVal, ACov: string): Integer;

{ UCUZ META OKUMASI: agaci ACMADAN (sayfa haritasi kurmadan) yalniz iki meta
  sayfasini okur ve damga/imza verir. Amac: "dosya hala benim tabanim mi?"
  kontrolu — yazan bir oturum, baska bir oturumun araya yazip yazmadigini
  tam agaci acmadan anlar. Dogrulama kurallari LoadMeta ile AYNIDIR. }
function VDbDixPeekMeta(const AFileName: string; out AStamp, ASig: Int64;
  out AReason: string): Boolean;

{ SKILL12: cokme enjeksiyonu. Ikisi de varsayilan olarak ETKISIZDIR. }
var
  VDbDixCrashStage: Integer;
  VDbDixCrashHook: TVdbDixCrashHook;

implementation

type
  TDixHdr = packed record
    PageNo: LongWord;
    Kind: Byte;
    Level: Byte;
    NKeys: Word;
    Reserved: LongWord;
    Flags: LongWord;
    Crc: LongWord;
    Tail: array[0..11] of Byte;
  end;
  PDixHdr = ^TDixHdr;

  TDixSlot = packed record
    Off: Word;
    Len: Word;
  end;
  PDixSlot = ^TDixSlot;

  TDixMetaRec = packed record
    Magic: LongWord;
    Ver: LongWord;
    PageSize: LongWord;
    Seq: Int64;
    Root: LongWord;
    PageCount: LongWord;
    Height: Word;
    Pad: Word;
    NKeys: Int64;
    Stamp: Int64;
    Sig: Int64;
    Reserved: array[0..7] of Byte;
  end;
  PDixMetaRec = ^TDixMetaRec;

function Hd(const P: TDixPageBuf): PDixHdr; inline;
begin
  Result := PDixHdr(@P[0]);
end;

function Slt(const P: TDixPageBuf; i: Integer): PDixSlot; inline;
begin
  Result := PDixSlot(@P[DIX_HDR_SIZE + i * 4]);
end;

function CP(const P: TDixPageBuf; i: Integer): PByte; inline;
begin
  Result := @P[Slt(P, i)^.Off];
end;

function DixCellSize(const AKey, AVal, ACov: string): Integer;
begin
  Result := 8 + Length(AKey) + Length(AVal) + Length(ACov);
end;

function PageCrc(const P: TDixPageBuf): LongWord;
var
  tmp: TDixPageBuf;
begin
  tmp := P;
  Hd(tmp)^.Crc := 0;
  Result := VDbCrc32Of(tmp, DIX_PAGE_SIZE);
end;

function CrcOk(const P: TDixPageBuf): Boolean;
begin
  Result := Hd(P)^.Crc = PageCrc(P);
end;

function VDbDixPeekMeta(const AFileName: string; out AStamp, ASig: Int64;
  out AReason: string): Boolean;
var
  fs: THandleStream;
  i, best: Integer;
  P: TDixPageBuf;
  M: PDixMetaRec;
  bestSeq: Int64;
begin
  Result := False;
  AStamp := 0;
  ASig := 0;
  AReason := '';
  if not FileExists(AFileName) then
  begin
    AReason := 'dosya yok';
    Exit;
  end;
  fs := nil;
  try
    try
      fs := VDbOpenStreamNoFlock(AFileName, True, False);
      if fs.Size < Int64(DIX_META_PAGES) * DIX_PAGE_SIZE then
      begin
        AReason := 'dosya cok kisa';
        Exit;
      end;
      best := -1;
      bestSeq := 0;
      for i := 0 to DIX_META_PAGES - 1 do
      begin
        fs.Position := Int64(i) * DIX_PAGE_SIZE;
        if fs.Read(P, DIX_PAGE_SIZE) <> DIX_PAGE_SIZE then Continue;
        if Hd(P)^.Kind <> DIX_META then Continue;
        if not CrcOk(P) then Continue;
        M := PDixMetaRec(@P[DIX_HDR_SIZE]);
        if (M^.Magic <> DIX_MAGIC) or (M^.Ver <> DIX_VER) or
           (M^.PageSize <> DIX_PAGE_SIZE) then
          Continue;
        if (M^.PageCount < DIX_FIRST_DATA) or (M^.Root >= M^.PageCount) then
          Continue;
        if (M^.Height < 1) or (M^.Height > 64) then
          Continue;
        if (best < 0) or (M^.Seq > bestSeq) then
        begin
          best := i;
          bestSeq := M^.Seq;
          AStamp := M^.Stamp;
          ASig := M^.Sig;
        end;
      end;
      if best < 0 then
      begin
        AReason := 'gecerli meta yok';
        Exit;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        AReason := E.ClassName + ': ' + E.Message;
        Exit;
      end;
    end;
  finally
    fs.Free;
  end;
end;

procedure InitPage(var P: TDixPageBuf; AKind, ALevel: Byte);
begin
  FillChar(P, DIX_PAGE_SIZE, 0);
  Hd(P)^.Kind := AKind;
  Hd(P)^.Level := ALevel;
  Hd(P)^.NKeys := 0;
end;

procedure WriteLeafCell(var P: TDixPageBuf; AOff: Integer;
  const AKey, AVal, ACov: string);
var
  o: Integer;
begin
  PWord(@P[AOff])^ := Length(AKey);
  PWord(@P[AOff + 2])^ := Length(AVal);
  PLongWord(@P[AOff + 4])^ := Length(ACov);
  o := AOff + 8;
  if Length(AKey) > 0 then
  begin
    Move(AKey[1], P[o], Length(AKey));
    Inc(o, Length(AKey));
  end;
  if Length(AVal) > 0 then
  begin
    Move(AVal[1], P[o], Length(AVal));
    Inc(o, Length(AVal));
  end;
  if Length(ACov) > 0 then
    Move(ACov[1], P[o], Length(ACov));
end;

procedure ReadLeafCell(const P: TDixPageBuf; AOff: Integer; out E: TVDbDixEntry);
var
  kl, vl: Word;
  cl: LongWord;
  o: Integer;
begin
  kl := PWord(@P[AOff])^;
  vl := PWord(@P[AOff + 2])^;
  cl := PLongWord(@P[AOff + 4])^;
  o := AOff + 8;
  SetLength(E.Key, kl);
  if kl > 0 then
  begin
    Move(P[o], E.Key[1], kl);
    Inc(o, kl);
  end;
  SetLength(E.Val, vl);
  if vl > 0 then
  begin
    Move(P[o], E.Val[1], vl);
    Inc(o, vl);
  end;
  SetLength(E.Cov, cl);
  if cl > 0 then
    Move(P[o], E.Cov[1], cl);
end;

procedure WriteIntCell(var P: TDixPageBuf; AOff: Integer; const AKey, AVal: string;
  AChild: LongWord);
var
  kl, vl: Integer;
begin
  kl := Length(AKey);
  vl := Length(AVal);
  PWord(@P[AOff])^ := kl;
  PWord(@P[AOff + 2])^ := vl;
  PLongWord(@P[AOff + 4])^ := AChild;
  if kl > 0 then
    Move(AKey[1], P[AOff + 8], kl);
  if vl > 0 then
    Move(AVal[1], P[AOff + 8 + kl], vl);
end;

procedure ReadIntCell(const P: TDixPageBuf; AOff: Integer; out AKey, AVal: string;
  out AChild: LongWord);
var
  kl, vl: Word;
begin
  kl := PWord(@P[AOff])^;
  vl := PWord(@P[AOff + 2])^;
  AChild := PLongWord(@P[AOff + 4])^;
  SetLength(AKey, kl);
  if kl > 0 then
    Move(P[AOff + 8], AKey[1], kl);
  SetLength(AVal, vl);
  if vl > 0 then
    Move(P[AOff + 8 + kl], AVal[1], vl);
end;

{ ------------------------------- nesne yasami ------------------------------ }

class function TVDbDiskIdx.CreateNew(const AFileName: string;
  ACmp: TVDbDixCmp): TVDbDiskIdx;
begin
  if FileExists(AFileName) then
    { Indeks turetmedir; eski dosyayi silmek kullanici verisini etkilemez. }
    if not DeleteFile(AFileName) then
      raise EDixError.Create('Indeks dosyasi silinemedi: ' + AFileName);
  Result := TVDbDiskIdx.Create;
  Result.FFileName := AFileName;
  Result.FCmp := ACmp;
  Result.FReadOnly := False;
  Result.FCommitOnClose := True;
  Result.FAutoCommit := 4096;
  Result.FMap := TDictionary<LongWord, Integer>.Create;
  Result.FCache := TDictionary<LongWord, TDixPageBuf>.Create;
  try
    Result.FStream := VDbOpenStreamNoFlock(AFileName, False, True);
  except
    Result.Free;
    raise;
  end;
  try
    Result.ResetStorage;
  except
    Result.Free;
    raise;
  end;
end;

class function TVDbDiskIdx.TryOpen(const AFileName: string; ACmp: TVDbDixCmp;
  AReadOnly: Boolean; out ATree: TVDbDiskIdx; out AReason: string): Boolean;
var
  T: TVDbDiskIdx;
begin
  Result := False;
  ATree := nil;
  AReason := '';
  if not FileExists(AFileName) then
  begin
    AReason := 'dosya yok';
    Exit;
  end;
  T := TVDbDiskIdx.Create;
  T.FFileName := AFileName;
  T.FCmp := ACmp;
  T.FReadOnly := AReadOnly;
  T.FCommitOnClose := True;
  T.FAutoCommit := 4096;
  T.FMap := TDictionary<LongWord, Integer>.Create;
  T.FCache := TDictionary<LongWord, TDixPageBuf>.Create;
  try
    T.FStream := VDbOpenStreamNoFlock(AFileName, AReadOnly, False);
    if T.FStream.Size < Int64(DIX_META_PAGES) * DIX_PAGE_SIZE then
      raise EDixError.Create('dosya cok kisa');
    T.LoadMeta;
    T.MarkReachable;
  except
    on E: Exception do
    begin
      AReason := E.ClassName + ': ' + E.Message;
      T.Free;
      Exit;
    end;
  end;
  ATree := T;
  Result := True;
end;

destructor TVDbDiskIdx.Destroy;
begin
  try
    if (not FReadOnly) and FCommitOnClose and FModified then
    try
      Commit;
    except
      { Kapatmada hata yutulur: indeks turetmedir, acilista Stamp uyusmazligi
        ile yeniden kurulur. Sessiz yanlis sonuc uretilmez. }
    end;
  finally
    FreeAndNil(FMap);
    FreeAndNil(FCache);
    FreeAndNil(FStream);
    inherited;
  end;
end;

procedure TVDbDiskIdx.ResetStorage;
begin
  FSeq := 0;
  FRoot := 0;
  FPageCount := DIX_META_PAGES;
  FHeight := 0;
  FNKeys := 0;
  FStamp := 0;
  FSig := 0;
  FPages := nil;
  FPageNo := nil;
  FMap.Clear;
  FCache.Clear;
  FCacheQ := nil;
  FCacheN := 0;
  FFree := nil;
  FFreeCount := 0;
  FPending := nil;
  FPendingCount := 0;
  FModified := False;
  FTxnOps := 0;
  FPagesRead := 0;
  if FStream.Size > 0 then
    FStream.Size := 0;
end;

procedure TVDbDiskIdx.LoadMeta;
var
  i, best: Integer;
  P: TDixPageBuf;
  M: PDixMetaRec;
  bestSeq: Int64;
  filePages: Int64;
begin
  best := -1;
  bestSeq := 0;
  for i := 0 to DIX_META_PAGES - 1 do
  begin
    FStream.Position := Int64(i) * DIX_PAGE_SIZE;
    if FStream.Read(P, DIX_PAGE_SIZE) <> DIX_PAGE_SIZE then
      Continue;
    if Hd(P)^.Kind <> DIX_META then
      Continue;
    if not CrcOk(P) then
      Continue;
    M := PDixMetaRec(@P[DIX_HDR_SIZE]);
    if (M^.Magic <> DIX_MAGIC) or (M^.Ver <> DIX_VER) or
       (M^.PageSize <> DIX_PAGE_SIZE) then
      Continue;
    if (M^.PageCount < DIX_FIRST_DATA) or (M^.Root >= M^.PageCount) then
      Continue;
    if (M^.Height < 1) or (M^.Height > 64) then
      Continue;
    if (best < 0) or (M^.Seq > bestSeq) then
    begin
      best := i;
      bestSeq := M^.Seq;
      FSeq := M^.Seq;
      FRoot := M^.Root;
      FPageCount := M^.PageCount;
      FHeight := M^.Height;
      FNKeys := M^.NKeys;
      FStamp := M^.Stamp;
      FSig := M^.Sig;
    end;
  end;
  if best < 0 then
    raise EDixError.Create('meta sayfalarinin ikisi de gecersiz');
  { Commit'ten once ayrilmis golge sayfalar dosyada kalabilir; page count'a
    katarak geri kazaniriz (MarkReachable bunlari serbest listeye atar). }
  filePages := FStream.Size div DIX_PAGE_SIZE;
  if filePages > FPageCount then
    FPageCount := LongWord(filePages);
end;

procedure TVDbDiskIdx.MarkReachable;
var
  mark: array of Byte;
  stack: array of LongWord;
  sp, i, k: Integer;
  P: TDixPageBuf;
  S: TDixSepArray;
  lvl: Integer;
begin
  SetLength(mark, FPageCount);
  for i := 0 to High(mark) do
    mark[i] := 0;
  if (FRoot < DIX_FIRST_DATA) or (FRoot >= FPageCount) then
    raise EDixError.Create('kok sayfa numarasi gecersiz');
  SetLength(stack, 64);
  stack[0] := FRoot;
  sp := 1;
  while sp > 0 do
  begin
    Dec(sp);
    i := stack[sp];
    if (i < DIX_FIRST_DATA) or (i >= FPageCount) then
      raise EDixError.CreateFmt('agac sayfa numarasi gecersiz: %d', [i]);
    if mark[i] <> 0 then
      Continue;
    mark[i] := 1;
    FStream.Position := Int64(i) * DIX_PAGE_SIZE;
    if FStream.Read(P, DIX_PAGE_SIZE) <> DIX_PAGE_SIZE then
      raise EDixError.CreateFmt('agac sayfasi %d dosyada yok', [i]);
    if Hd(P)^.PageNo <> i then
      raise EDixError.CreateFmt('agac sayfasi %d kimlik uyusmuyor', [i]);
    if not CrcOk(P) then
      raise EDixError.CreateFmt('agac sayfasi %d CRC bozuk', [i]);
    if Hd(P)^.Kind = DIX_INTERNAL then
    begin
      DecodeInt(P, S, lvl);
      if Length(S) = 0 then
        raise EDixError.CreateFmt('ic sayfa %d bos', [i]);
      if sp + Length(S) + 8 > Length(stack) then
        SetLength(stack, sp + Length(S) + 16);
      for k := 0 to High(S) do
      begin
        stack[sp] := S[k].Child;
        Inc(sp);
      end;
    end
    else if Hd(P)^.Kind <> DIX_LEAF then
      raise EDixError.CreateFmt('agac sayfasi %d turu gecersiz', [i]);
  end;
  FFree := nil;
  FFreeCount := 0;
  for i := DIX_FIRST_DATA to FPageCount - 1 do
    if mark[i] = 0 then
      PushFree(LongWord(i));
end;

{ ------------------------------- sayfa erisimi ----------------------------- }

function TVDbDiskIdx.BufIdx(ANo: LongWord): Integer;
begin
  if not FMap.TryGetValue(ANo, Result) then
    Result := -1;
end;

function TVDbDiskIdx.NewPage(AKind, ALevel: Byte): LongWord;
var
  P: TDixPageBuf;
begin
  if FFreeCount > 0 then
  begin
    Dec(FFreeCount);
    Result := FFree[FFreeCount];
    SetLength(FFree, FFreeCount);
  end
  else
  begin
    Result := FPageCount;
    Inc(FPageCount);
  end;
  InitPage(P, AKind, ALevel);
  Hd(P)^.PageNo := Result;
  StoreBuf(Result, P);
  FModified := True;
end;

procedure TVDbDiskIdx.StoreBuf(ANo: LongWord; const P: TDixPageBuf);
var
  idx: Integer;
begin
  if FMap.TryGetValue(ANo, idx) then
  begin
    FPages[idx] := P;
    Exit;
  end;
  idx := Length(FPages);
  SetLength(FPages, idx + 1);
  SetLength(FPageNo, idx + 1);
  FPages[idx] := P;
  FPageNo[idx] := ANo;
  FMap.Add(ANo, idx);
end;

procedure TVDbDiskIdx.LoadBuf(ANo: LongWord; out P: TDixPageBuf);
var
  idx: Integer;
begin
  idx := BufIdx(ANo);
  if idx >= 0 then
    P := FPages[idx]
  else
    ReadPage(ANo, P);
end;

procedure TVDbDiskIdx.ReadPage(ANo: LongWord; out P: TDixPageBuf);
var
  idx: Integer;
begin
  idx := BufIdx(ANo);
  if idx >= 0 then
  begin
    P := FPages[idx];
    Exit;
  end;
  if ANo >= FPageCount then
    raise EDixError.CreateFmt('sayfa numarasi aralik disi: %d', [ANo]);
  if FStream.Size < Int64(ANo + 1) * DIX_PAGE_SIZE then
    raise EDixError.CreateFmt('dosya kesik, sayfa %d yok', [ANo]);
  FStream.Position := Int64(ANo) * DIX_PAGE_SIZE;
  if FStream.Read(P, DIX_PAGE_SIZE) <> DIX_PAGE_SIZE then
    raise EDixError.CreateFmt('sayfa %d okunamadi', [ANo]);
  if Hd(P)^.PageNo <> ANo then
    raise EDixError.CreateFmt('sayfa %d kimlik uyusmuyor', [ANo]);
  if not CrcOk(P) then
    raise EDixError.CreateFmt('sayfa %d CRC bozuk', [ANo]);
  if (Hd(P)^.Kind <> DIX_LEAF) and (Hd(P)^.Kind <> DIX_INTERNAL) then
    raise EDixError.CreateFmt('sayfa %d turu gecersiz', [ANo]);
  Inc(FPagesRead);
end;

procedure TVDbDiskIdx.DropCache;
begin
  FCache.Clear;
  FCacheQ := nil;
  FCacheN := 0;
end;

procedure TVDbDiskIdx.ReadPageCached(ANo: LongWord; out P: TDixPageBuf);
var
  idx: Integer;
begin
  if FMap.TryGetValue(ANo, idx) then
  begin
    P := FPages[idx];
    Exit;
  end;
  if FCache.TryGetValue(ANo, P) then
    Exit;
  ReadPage(ANo, P);
  if FCacheN >= DIX_CACHE_PAGES then
  begin
    if Length(FCacheQ) > 0 then
    begin
      FCache.Remove(FCacheQ[0]);
      if Length(FCacheQ) > 1 then
        Move(FCacheQ[1], FCacheQ[0], (Length(FCacheQ) - 1) * SizeOf(LongWord));
      SetLength(FCacheQ, Length(FCacheQ) - 1);
      Dec(FCacheN);
    end;
  end;
  FCache.AddOrSetValue(ANo, P);
  idx := Length(FCacheQ);
  SetLength(FCacheQ, idx + 1);
  FCacheQ[idx] := ANo;
  Inc(FCacheN);
end;

procedure TVDbDiskIdx.PushPending(ANo: LongWord);
begin
  SetLength(FPending, FPendingCount + 1);
  FPending[FPendingCount] := ANo;
  Inc(FPendingCount);
end;

procedure TVDbDiskIdx.PushFree(ANo: LongWord);
begin
  SetLength(FFree, FFreeCount + 1);
  FFree[FFreeCount] := ANo;
  Inc(FFreeCount);
end;

procedure TVDbDiskIdx.ReleasePage(ANo: LongWord);
var
  idx: Integer;
begin
  idx := BufIdx(ANo);
  if idx >= 0 then
  begin
    FMap.Remove(ANo);
    FPageNo[idx] := 0;
    PushFree(ANo);
  end
  else
    PushPending(ANo);
end;

function TVDbDiskIdx.MutPage(ANo: LongWord; out AKind, ALevel: Byte): LongWord;
var
  old, P: TDixPageBuf;
begin
  if BufIdx(ANo) >= 0 then
  begin
    ReadPage(ANo, P);
    AKind := Hd(P)^.Kind;
    ALevel := Hd(P)^.Level;
    Exit(ANo);
  end;
  ReadPage(ANo, old);
  AKind := Hd(old)^.Kind;
  ALevel := Hd(old)^.Level;
  Result := NewPage(AKind, ALevel);
  Hd(old)^.PageNo := Result;
  StoreBuf(Result, old);
  PushPending(ANo);
  FModified := True;
end;

procedure TVDbDiskIdx.WriteMeta;
var
  P: TDixPageBuf;
  M: PDixMetaRec;
  no: LongWord;
begin
  Inc(FSeq);
  no := LongWord(FSeq and 1);
  InitPage(P, DIX_META, 0);
  Hd(P)^.PageNo := no;
  M := PDixMetaRec(@P[DIX_HDR_SIZE]);
  M^.Magic := DIX_MAGIC;
  M^.Ver := DIX_VER;
  M^.PageSize := DIX_PAGE_SIZE;
  M^.Seq := FSeq;
  M^.Root := FRoot;
  M^.PageCount := FPageCount;
  M^.Height := Word(FHeight);
  M^.Pad := 0;
  M^.NKeys := FNKeys;
  M^.Stamp := FStamp;
  M^.Sig := FSig;
  Hd(P)^.Crc := 0;
  Hd(P)^.Crc := PageCrc(P);
  CrashPoint(DIX_CRASH_PRE_META);
  FStream.Position := Int64(no) * DIX_PAGE_SIZE;
  FStream.WriteBuffer(P, DIX_PAGE_SIZE);
  Inc(FPagesWritten);
  { Yeni meta cekirdege gecti ama fsync YOK. SUREC olumunde (guclu kapanma
    degil) yazma gorunur kalir: sonraki acilis yeni Seq/Stamp'i okur. }
  CrashPoint(DIX_CRASH_POST_META);
  VDbFlushStream(FStream);
  Inc(FSyncCount);
end;

procedure TVDbDiskIdx.Commit;
var
  i: Integer;
  P: TDixPageBuf;
  written, midDone: Boolean;
begin
  if FReadOnly then
    Exit;
  { Cokme matrisi: sayfa yazimi oncesi (hicbir sey yazilmadi). }
  CrashPoint(DIX_CRASH_PRE_PAGE);
  written := False;
  midDone := False;
  for i := 0 to High(FPages) do
  begin
    if FPageNo[i] = 0 then
      Continue;
    P := FPages[i];
    Hd(P)^.PageNo := FPageNo[i];
    Hd(P)^.Crc := 0;
    Hd(P)^.Crc := PageCrc(P);
    FStream.Position := Int64(FPageNo[i]) * DIX_PAGE_SIZE;
    FStream.WriteBuffer(P, DIX_PAGE_SIZE);
    Inc(FPagesWritten);
    written := True;
    { Cokme matrisi: coklu sayfa yaziminin ORTASI. Yazilan sayfa cekirdege
      gecti, kalanlar inmedi, fsync yok, meta eski. Eski meta hala eski
      agaci gosterir; yeni sayfa serbest listeye ait oldugu icin erisilemez. }
    if not midDone then
    begin
      midDone := True;
      CrashPoint(DIX_CRASH_MID_PAGES);
    end;
  end;
  if written then
  begin
    VDbFlushStream(FStream);
    Inc(FSyncCount);
    { Sayfalar diske indi, META henuz yazilmadi: eski commit gecerli. }
    CrashPoint(DIX_CRASH_POST_PAGE);
  end;
  WriteMeta;
  { serbest birakilan sayfalar commit'ten SONRA yeniden kullanilabilir }
  for i := 0 to FPendingCount - 1 do
    PushFree(FPending[i]);
  FPending := nil;
  FPendingCount := 0;
  FMap.Clear;
  FPages := nil;
  FPageNo := nil;
  DropCache;
  FTxnOps := 0;
  FModified := False;
end;

procedure TVDbDiskIdx.AfterOp;
begin
  Inc(FTxnOps);
  if (FAutoCommit > 0) and (FTxnOps >= FAutoCommit) then
    Commit;
end;

procedure TVDbDiskIdx.CrashPoint(AStage: Integer);
begin
  { Uretimde iki tamsayi karsilastirmasi; kanca atanmadikca hicbir sey olmaz. }
  if (VDbDixCrashStage <> DIX_CRASH_NONE) and (AStage = VDbDixCrashStage) and
     Assigned(VDbDixCrashHook) then
    VDbDixCrashHook();
end;

procedure TVDbDiskIdx.EnsureWritable;
begin
  if FReadOnly then
    raise EDixError.Create('indeks salt-okunur acilmis');
end;

{ ------------------------------- karsilastirma ----------------------------- }

function TVDbDiskIdx.KeyCmp(const A, B: string): Integer;
begin
  { tam anahtar sirasi, deger (pk) katilmadan: yonlendirme icin }
  Result := FCmp.CompareEntries(A, '', B, '');
end;

function TVDbDiskIdx.ChildIdxKey(const S: TDixSepArray; const AKey, AVal: string): Integer;
var
  lo, hi, mid: Integer;
begin
  { Ayirici tam giris tasir; yonlendirme de tam girisle yapilir. Boylece
    ayni anahtarin pk'lari bolunme sinirinda kalsa bile her giris tam olarak
    bir yapraga duser (esitlikte saga gitmek soldaki pk'lari atlamaz). }
  Result := 0;
  if Length(S) < 2 then
    Exit;
  lo := 1;
  hi := High(S);
  while lo <= hi do
  begin
    mid := (lo + hi) shr 1;
    if FCmp.CompareEntries(S[mid].Key, S[mid].Val, AKey, AVal) <= 0 then
    begin
      Result := mid;
      lo := mid + 1;
    end
    else
      hi := mid - 1;
  end;
end;

function TVDbDiskIdx.LeafLowerBoundKey(const E: TVDbDixEntries; const AKey: string): Integer;
var
  lo, hi, mid: Integer;
begin
  lo := 0;
  hi := Length(E);
  while lo < hi do
  begin
    mid := (lo + hi) shr 1;
    if KeyCmp(E[mid].Key, AKey) < 0 then
      lo := mid + 1
    else
      hi := mid;
  end;
  Result := lo;
end;

function TVDbDiskIdx.AppendEntry(var A: TVDbDixEntries; N: Integer;
  const E: TVDbDixEntry): Integer;
begin
  if N >= Length(A) then
  begin
    if Length(A) = 0 then
      SetLength(A, 64)
    else
      SetLength(A, Length(A) * 2);
  end;
  A[N] := E;
  Result := N + 1;
end;

{ ------------------------------- kodlama ---------------------------------- }

procedure TVDbDiskIdx.DecodeLeaf(const P: TDixPageBuf; out E: TVDbDixEntries);
var
  i, n: Integer;
begin
  n := Hd(P)^.NKeys;
  SetLength(E, n);
  for i := 0 to n - 1 do
    ReadLeafCell(P, Slt(P, i)^.Off, E[i]);
end;

procedure TVDbDiskIdx.DecodeInt(const P: TDixPageBuf; out S: TDixSepArray;
  out ALevel: Integer);
var
  i, n: Integer;
begin
  n := Hd(P)^.NKeys;
  SetLength(S, n);
  for i := 0 to n - 1 do
    ReadIntCell(P, Slt(P, i)^.Off, S[i].Key, S[i].Val, S[i].Child);
  ALevel := Hd(P)^.Level;
end;

function TVDbDiskIdx.LeafSize(const E: TVDbDixEntries): Integer;
var
  i: Integer;
begin
  Result := DIX_HDR_SIZE + Length(E) * 4;
  for i := 0 to High(E) do
    Inc(Result, DixCellSize(E[i].Key, E[i].Val, E[i].Cov));
end;

function TVDbDiskIdx.IntSize(const S: TDixSepArray): Integer;
var
  i: Integer;
begin
  Result := DIX_HDR_SIZE + Length(S) * 4;
  for i := 0 to High(S) do
    Inc(Result, 8 + Length(S[i].Key) + Length(S[i].Val));
end;

procedure TVDbDiskIdx.EncodeLeaf(var P: TDixPageBuf; ALevel: Integer;
  const E: TVDbDixEntries);
var
  i, n, dataEnd, clen: Integer;
begin
  if LeafSize(E) > DIX_PAGE_SIZE then
    raise EDixError.Create('yaprak sayfa sigmiyor');
  InitPage(P, DIX_LEAF, ALevel);
  n := Length(E);
  Hd(P)^.NKeys := Word(n);
  dataEnd := DIX_PAGE_SIZE;
  for i := n - 1 downto 0 do
  begin
    clen := DixCellSize(E[i].Key, E[i].Val, E[i].Cov);
    Dec(dataEnd, clen);
    WriteLeafCell(P, dataEnd, E[i].Key, E[i].Val, E[i].Cov);
    Slt(P, i)^.Off := Word(dataEnd);
    Slt(P, i)^.Len := Word(clen);
  end;
end;

procedure TVDbDiskIdx.EncodeInt(var P: TDixPageBuf; ALevel: Integer;
  const S: TDixSepArray);
var
  i, n, dataEnd, clen: Integer;
begin
  if IntSize(S) > DIX_PAGE_SIZE then
    raise EDixError.Create('ic sayfa sigmiyor');
  InitPage(P, DIX_INTERNAL, ALevel);
  n := Length(S);
  Hd(P)^.NKeys := Word(n);
  dataEnd := DIX_PAGE_SIZE;
  for i := n - 1 downto 0 do
  begin
    clen := 8 + Length(S[i].Key) + Length(S[i].Val);
    Dec(dataEnd, clen);
    WriteIntCell(P, dataEnd, S[i].Key, S[i].Val, S[i].Child);
    Slt(P, i)^.Off := Word(dataEnd);
    Slt(P, i)^.Len := Word(clen);
  end;
end;

procedure TVDbDiskIdx.SetLeaf(ANo: LongWord; ALevel: Integer;
  const E: TVDbDixEntries);
var
  P: TDixPageBuf;
begin
  LoadBuf(ANo, P);
  EncodeLeaf(P, ALevel, E);
  StoreBuf(ANo, P);
end;

procedure TVDbDiskIdx.SetInt(ANo: LongWord; ALevel: Integer;
  const S: TDixSepArray);
var
  P: TDixPageBuf;
begin
  LoadBuf(ANo, P);
  EncodeInt(P, ALevel, S);
  StoreBuf(ANo, P);
end;

{ ------------------------------- imlec ------------------------------------ }

procedure TVDbDiskIdx.DescendLeftmost(ANo: LongWord; var C: TDixCursor);
var
  P: TDixPageBuf;
  S: TDixSepArray;
  lvl: Integer;
begin
  while True do
  begin
    ReadPageCached(ANo, P);
    if Hd(P)^.Kind = DIX_LEAF then
    begin
      DecodeLeaf(P, C.Leaf);
      C.Pos := 0;
      C.Valid := Length(C.Leaf) > 0;
      Exit;
    end;
    if C.Depth > 62 then
      raise EDixError.Create('agac derinligi asiri');
    DecodeInt(P, S, lvl);
    if Length(S) = 0 then
    begin
      C.Valid := False;
      Exit;
    end;
    C.PathNo[C.Depth] := ANo;
    C.PathIdx[C.Depth] := 0;
    Inc(C.Depth);
    ANo := S[0].Child;
  end;
end;

function TVDbDiskIdx.CursorFirst(out C: TDixCursor): Boolean;
begin
  C.Depth := 0;
  C.Valid := False;
  C.Leaf := nil;
  C.Pos := 0;
  if FRoot = 0 then
    Exit(False);
  DescendLeftmost(FRoot, C);
  Result := C.Valid;
end;

function TVDbDiskIdx.CursorSeekKey(out C: TDixCursor; const ABound: string;
  AInclusive: Boolean): Boolean;
var
  ANo: LongWord;
  P: TDixPageBuf;
  S: TDixSepArray;
  lvl, idx: Integer;
begin
  C.Depth := 0;
  C.Valid := False;
  C.Leaf := nil;
  C.Pos := 0;
  if FRoot = 0 then
    Exit(False);
  ANo := FRoot;
  while True do
  begin
    ReadPageCached(ANo, P);
    if Hd(P)^.Kind = DIX_LEAF then
      Break;
    if C.Depth > 62 then
      raise EDixError.Create('agac derinligi asiri');
    DecodeInt(P, S, lvl);
    { Sinir yalniz anahtar tasir; pk yerine '' verilir. FullCompare'da
      '' o anahtarin en kucuk pk'sidir, yani arama o anahtarin ILK
      gorundugu yapraga iner. }
    idx := ChildIdxKey(S, ABound, '');
    C.PathNo[C.Depth] := ANo;
    C.PathIdx[C.Depth] := idx;
    Inc(C.Depth);
    ANo := S[idx].Child;
  end;
  DecodeLeaf(P, C.Leaf);
  C.Pos := LeafLowerBoundKey(C.Leaf, ABound);
  if not AInclusive then
    while (C.Pos < Length(C.Leaf)) and
          (FCmp.CompareKeyBound(C.Leaf[C.Pos].Key, ABound) = 0) do
      Inc(C.Pos);
  C.Valid := C.Pos < Length(C.Leaf);
  Result := C.Valid;
end;

function TVDbDiskIdx.CursorNext(var C: TDixCursor): Boolean;
var
  d, idx, lvl: Integer;
  P: TDixPageBuf;
  S: TDixSepArray;
begin
  if not C.Valid then
    Exit(False);
  if C.Pos + 1 < Length(C.Leaf) then
  begin
    Inc(C.Pos);
    Exit(True);
  end;
  d := C.Depth - 1;
  while d >= 0 do
  begin
    idx := C.PathIdx[d] + 1;
    ReadPageCached(C.PathNo[d], P);
    DecodeInt(P, S, lvl);
    if idx < Length(S) then
    begin
      C.PathIdx[d] := idx;
      C.Depth := d + 1;
      DescendLeftmost(S[idx].Child, C);
      Exit(C.Valid);
    end;
    Dec(d);
    C.Depth := d + 1;
  end;
  C.Valid := False;
  Result := False;
end;

function TVDbDiskIdx.CursorSeekGT(out C: TDixCursor; const AKey, AVal: string): Boolean;
begin
  Result := CursorSeekKey(C, AKey, True);
  while Result and (FCmp.CompareKeyBound(C.Leaf[C.Pos].Key, AKey) = 0) and
        (FCmp.CompareEntries(C.Leaf[C.Pos].Key, C.Leaf[C.Pos].Val, AKey, AVal) <= 0) do
    Result := CursorNext(C);
end;

{ ------------------------------- toplu yukleme ---------------------------- }

procedure TVDbDiskIdx.BuildSorted(const AEntries: TVDbDixEntries; AStamp, ASig: Int64);
type
  TChildRef = record
    No: LongWord;
    FirstKey: string;
    FirstVal: string;
  end;
  TChildRefs = array of TChildRef;
var
  cur, nxt: TChildRefs;
  i, n, lvl, j, cnt: Integer;
  E: TVDbDixEntries;
  S: TDixSepArray;
  P: TDixPageBuf;
  firstKey, firstVal: string;
  cellLen, total: Integer;

  function PutPage(var AP: TDixPageBuf): LongWord;
  begin
    Result := FPageCount;
    Inc(FPageCount);
    Hd(AP)^.PageNo := Result;
    Hd(AP)^.Crc := 0;
    Hd(AP)^.Crc := PageCrc(AP);
    FStream.Position := Int64(Result) * DIX_PAGE_SIZE;
    FStream.WriteBuffer(AP, DIX_PAGE_SIZE);
    Inc(FPagesWritten);
  end;

begin
  EnsureWritable;
  ResetStorage;
  FStamp := AStamp;
  FSig := ASig;
  FNKeys := Length(AEntries);

  if Length(AEntries) = 0 then
  begin
    InitPage(P, DIX_LEAF, 1);
    FRoot := PutPage(P);
    FHeight := 1;
    VDbFlushStream(FStream);
    Inc(FSyncCount);
    WriteMeta;
    Exit;
  end;

  { 1. seviye: yapraklar }
  cur := nil;
  i := 0;
  n := Length(AEntries);
  while i < n do
  begin
    SetLength(E, 0);
    cnt := 0;
    total := DIX_HDR_SIZE;
    while i < n do
    begin
      cellLen := DixCellSize(AEntries[i].Key, AEntries[i].Val, AEntries[i].Cov);
      if cellLen > DIX_MAX_CELL then
        raise EDixCellTooLarge.CreateFmt('indeks hucresi cok buyuk (%d bayt)', [cellLen]);
      if total + 4 + cellLen > DIX_PAGE_SIZE then
      begin
        if cnt = 0 then
          raise EDixCellTooLarge.CreateFmt('indeks hucresi sayfaya sigmiyor (%d bayt)', [cellLen]);
        Break;
      end;
      SetLength(E, cnt + 1);
      E[cnt] := AEntries[i];
      Inc(cnt);
      Inc(total, 4 + cellLen);
      Inc(i);
    end;
    firstKey := E[0].Key;
    firstVal := E[0].Val;
    EncodeLeaf(P, 1, E);
    j := Length(cur);
    SetLength(cur, j + 1);
    cur[j].No := PutPage(P);
    cur[j].FirstKey := firstKey;
    cur[j].FirstVal := firstVal;
  end;

  { ust seviyeler }
  lvl := 1;
  while Length(cur) > 1 do
  begin
    Inc(lvl);
    nxt := nil;
    i := 0;
    while i < Length(cur) do
    begin
      SetLength(S, 1);
      S[0].Key := '';
      S[0].Val := '';
      S[0].Child := cur[i].No;
      firstKey := cur[i].FirstKey;
      firstVal := cur[i].FirstVal;
      Inc(i);
      total := IntSize(S);
      while i < Length(cur) do
      begin
        cellLen := 8 + Length(cur[i].FirstKey) + Length(cur[i].FirstVal);
        if total + 4 + cellLen > DIX_PAGE_SIZE then
          Break;
        j := Length(S);
        SetLength(S, j + 1);
        S[j].Key := cur[i].FirstKey;
        S[j].Val := cur[i].FirstVal;
        S[j].Child := cur[i].No;
        Inc(total, 4 + cellLen);
        Inc(i);
      end;
      EncodeInt(P, lvl, S);
      j := Length(nxt);
      SetLength(nxt, j + 1);
      nxt[j].No := PutPage(P);
      nxt[j].FirstKey := firstKey;
      nxt[j].FirstVal := firstVal;
    end;
    cur := nxt;
  end;

  FRoot := cur[0].No;
  FHeight := lvl;
  VDbFlushStream(FStream);
  Inc(FSyncCount);
  WriteMeta;
  DropCache;
end;

{ ------------------------------- yazma ------------------------------------ }

function TVDbDiskIdx.Insert(const AKey, AVal, ACov: string): Boolean;
var
  E: TVDbDixEntries;
  S, SL, SR: TDixSepArray;
  P: TDixPageBuf;
  pathNo: array[0..63] of LongWord;
  pathIdx: array[0..63] of Integer;
  depth, i, n, pos, mid, lvl, k: Integer;
  kindB, lvlB: Byte;
  curNo, newNo, leftNo, rightNo: LongWord;
  splitPending: Boolean;
  minChanged, updated: Boolean;
  carryKey, newMinKey, newMinVal, carryVal: string;
  carryChild: LongWord;
  cmp: Integer;
begin
  EnsureWritable;
  Result := False;
  if (Length(AKey) > DIX_MAX_KEY) or (Length(AVal) > DIX_MAX_KEY) or
     (DixCellSize(AKey, AVal, ACov) > DIX_MAX_CELL) then
    raise EDixCellTooLarge.Create('indeks anahtari/degeri cok buyuk');

  if FRoot = 0 then
  begin
    SetLength(E, 1);
    E[0].Key := AKey;
    E[0].Val := AVal;
    E[0].Cov := ACov;
    leftNo := NewPage(DIX_LEAF, 1);
    SetLeaf(leftNo, 1, E);
    FRoot := leftNo;
    FHeight := 1;
    FNKeys := 1;
    FModified := True;
    AfterOp;
    Exit(True);
  end;

  { kokten yapraga in }
  depth := 0;
  curNo := FRoot;
  while True do
  begin
    LoadBuf(curNo, P);
    if Hd(P)^.Kind = DIX_LEAF then
      Break;
    if depth > 62 then
      raise EDixError.Create('agac derinligi asiri');
    DecodeInt(P, S, lvl);
    i := ChildIdxKey(S, AKey, AVal);
    pathNo[depth] := curNo;
    pathIdx[depth] := i;
    Inc(depth);
    curNo := S[i].Child;
  end;

  DecodeLeaf(P, E);
  n := Length(E);
  pos := 0;
  while pos < n do
  begin
    cmp := FCmp.CompareEntries(E[pos].Key, E[pos].Val, AKey, AVal);
    if cmp >= 0 then
      Break;
    Inc(pos);
  end;

  splitPending := False;
  minChanged := False;
  updated := False;
  carryKey := '';
  carryVal := '';
  carryChild := 0;

  if (pos < n) and (FCmp.CompareEntries(E[pos].Key, E[pos].Val, AKey, AVal) = 0) then
  begin
    { ayni (anahtar, pk): yalniz kapsama guncellenir }
    if E[pos].Cov = ACov then
      Exit(False);
    E[pos].Cov := ACov;
    updated := True;
    leftNo := MutPage(curNo, kindB, lvlB);
    SetLeaf(leftNo, lvlB, E);
    curNo := leftNo;
  end
  else
  begin
    SetLength(E, n + 1);
    k := n;
    while k > pos do
    begin
      E[k] := E[k - 1];
      Dec(k);
    end;
    E[pos].Key := AKey;
    E[pos].Val := AVal;
    E[pos].Cov := ACov;
    Inc(n);
    if pos = 0 then
    begin
      minChanged := True;
      newMinKey := AKey;
      newMinVal := AVal;
    end;
    if LeafSize(E) <= DIX_PAGE_SIZE then
    begin
      leftNo := MutPage(curNo, kindB, lvlB);
      SetLeaf(leftNo, lvlB, E);
      curNo := leftNo;
    end
    else
    begin
      mid := n div 2;
      leftNo := MutPage(curNo, kindB, lvlB);
      SetLeaf(leftNo, lvlB, Copy(E, 0, mid));
      rightNo := NewPage(DIX_LEAF, lvlB);
      SetLeaf(rightNo, lvlB, Copy(E, mid, n - mid));
      carryKey := E[mid].Key;
      carryVal := E[mid].Val;
      carryChild := rightNo;
      splitPending := True;
      curNo := leftNo;
    end;
    Inc(FNKeys);
  end;
  FModified := True;

  { yukari cik: cocuk numaralari ve ayiricilar guncellenir }
  i := depth - 1;
  while i >= 0 do
  begin
    LoadBuf(pathNo[i], P);
    DecodeInt(P, S, lvl);
    S[pathIdx[i]].Child := curNo;
    if minChanged then
    begin
      { alt agacin en kucuk anahtari degisti: ayiriciyi tazele }
      if pathIdx[i] > 0 then
      begin
        S[pathIdx[i]].Key := newMinKey;
        S[pathIdx[i]].Val := newMinVal;
        minChanged := False;
      end;
    end;
    if splitPending then
    begin
      n := Length(S);
      SetLength(S, n + 1);
      k := n;
      while k > pathIdx[i] + 1 do
      begin
        S[k] := S[k - 1];
        Dec(k);
      end;
      S[pathIdx[i] + 1].Key := carryKey;
      S[pathIdx[i] + 1].Val := carryVal;
      S[pathIdx[i] + 1].Child := carryChild;
      splitPending := False;
    end;
    if IntSize(S) <= DIX_PAGE_SIZE then
    begin
      newNo := MutPage(pathNo[i], kindB, lvlB);
      SetInt(newNo, lvlB, S);
      curNo := newNo;
    end
    else
    begin
      n := Length(S);
      mid := n div 2;
      carryKey := S[mid].Key;
      carryVal := S[mid].Val;
      SL := Copy(S, 0, mid);
      SR := Copy(S, mid, n - mid);
      newNo := MutPage(pathNo[i], kindB, lvlB);
      SetInt(newNo, lvlB, SL);
      rightNo := NewPage(DIX_INTERNAL, lvl);
      SetInt(rightNo, lvlB, SR);
      carryChild := rightNo;
      curNo := newNo;
      splitPending := True;
    end;
    Dec(i);
  end;

  if splitPending then
  begin
    SetLength(S, 2);
    S[0].Key := '';
    S[0].Val := '';
    S[0].Child := curNo;
    S[1].Key := carryKey;
    S[1].Val := carryVal;
    S[1].Child := carryChild;
    newNo := NewPage(DIX_INTERNAL, FHeight + 1);
    SetInt(newNo, FHeight + 1, S);
    FRoot := newNo;
    Inc(FHeight);
  end
  else
    FRoot := curNo;

  AfterOp;
  Result := not updated;
end;

function TVDbDiskIdx.Remove(const AKey, AVal: string): Boolean;
var
  E: TVDbDixEntries;
  S: TDixSepArray;
  P: TDixPageBuf;
  pathNo: array[0..63] of LongWord;
  pathIdx: array[0..63] of Integer;
  depth, i, n, pos, lvl, k: Integer;
  kindB, lvlB: Byte;
  curNo, newNo: LongWord;
  unlink: Boolean;
begin
  EnsureWritable;
  Result := False;
  if FRoot = 0 then
    Exit;

  depth := 0;
  curNo := FRoot;
  while True do
  begin
    LoadBuf(curNo, P);
    if Hd(P)^.Kind = DIX_LEAF then
      Break;
    if depth > 62 then
      raise EDixError.Create('agac derinligi asiri');
    DecodeInt(P, S, lvl);
    i := ChildIdxKey(S, AKey, AVal);
    pathNo[depth] := curNo;
    pathIdx[depth] := i;
    Inc(depth);
    curNo := S[i].Child;
  end;

  DecodeLeaf(P, E);
  n := Length(E);
  pos := 0;
  while pos < n do
  begin
    if FCmp.CompareEntries(E[pos].Key, E[pos].Val, AKey, AVal) = 0 then
      Break;
    if FCmp.CompareEntries(E[pos].Key, E[pos].Val, AKey, AVal) > 0 then
    begin
      pos := n;
      Break;
    end;
    Inc(pos);
  end;
  if (pos >= n) or (FCmp.CompareEntries(E[pos].Key, E[pos].Val, AKey, AVal) <> 0) then
    Exit(False);

  k := pos;
  while k < n - 1 do
  begin
    E[k] := E[k + 1];
    Inc(k);
  end;
  SetLength(E, n - 1);
  Dec(n);
  Dec(FNKeys);
  FModified := True;

  unlink := False;
  if n > 0 then
  begin
    newNo := MutPage(curNo, kindB, lvlB);
    SetLeaf(newNo, lvlB, E);
    curNo := newNo;
  end
  else if depth = 0 then
  begin
    { kok yaprak bosaldi: agac bos ama gecerli kalir }
    newNo := MutPage(curNo, kindB, lvlB);
    SetLeaf(newNo, lvlB, E);
    curNo := newNo;
  end
  else
  begin
    ReleasePage(curNo);
    unlink := True;
    curNo := 0;
  end;

  i := depth - 1;
  while i >= 0 do
  begin
    LoadBuf(pathNo[i], P);
    DecodeInt(P, S, lvl);
    if unlink then
    begin
      n := Length(S);
      if (n <= 1) then
      begin
        { ic sayfa islevsiz kaldi }
        ReleasePage(pathNo[i]);
        unlink := True;
        curNo := 0;
        Dec(i);
        Continue;
      end;
      k := pathIdx[i];
      while k < n - 1 do
      begin
        S[k] := S[k + 1];
        Inc(k);
      end;
      SetLength(S, n - 1);
      unlink := False;
    end
    else
      S[pathIdx[i]].Child := curNo;
    newNo := MutPage(pathNo[i], kindB, lvlB);
    SetInt(newNo, lvlB, S);
    curNo := newNo;
    Dec(i);
  end;

  if curNo <> 0 then
    FRoot := curNo;

  { kok daraltma: tek cocuklu ic kok yok edilir }
  while True do
  begin
    LoadBuf(FRoot, P);
    if Hd(P)^.Kind <> DIX_INTERNAL then
      Break;
    DecodeInt(P, S, lvl);
    if Length(S) > 1 then
      Break;
    newNo := FRoot;
    FRoot := S[0].Child;
    ReleasePage(newNo);
    Dec(FHeight);
    if FHeight < 1 then
      FHeight := 1;
  end;

  AfterOp;
  Result := True;
end;

{ ------------------------------- okuma ------------------------------------ }

function TVDbDiskIdx.CollectRange(const ALo, AHi: string; AHasLo, AHasHi,
  ALoInc, AHiInc: Boolean; out AEntries: TVDbDixEntries): Integer;
var
  Cur: TDixCursor;
  ok: Boolean;
  cnt, c: Integer;
begin
  Result := 0;
  AEntries := nil;
  if AHasLo then
    ok := CursorSeekKey(Cur, ALo, ALoInc)
  else
    ok := CursorFirst(Cur);
  cnt := 0;
  while ok do
  begin
    if AHasHi then
    begin
      c := FCmp.CompareKeyBound(Cur.Leaf[Cur.Pos].Key, AHi);
      if (c > 0) or ((c = 0) and (not AHiInc)) then
        Break;
    end;
    cnt := AppendEntry(AEntries, cnt, Cur.Leaf[Cur.Pos]);
    ok := CursorNext(Cur);
  end;
  SetLength(AEntries, cnt);
  Result := cnt;
end;

function TVDbDiskIdx.CountRange(const ALo, AHi: string; AHasLo, AHasHi,
  ALoInc, AHiInc: Boolean): Int64;
var
  Cur: TDixCursor;
  ok: Boolean;
  c: Integer;
begin
  Result := 0;
  if AHasLo then
    ok := CursorSeekKey(Cur, ALo, ALoInc)
  else
    ok := CursorFirst(Cur);
  while ok do
  begin
    if AHasHi then
    begin
      c := FCmp.CompareKeyBound(Cur.Leaf[Cur.Pos].Key, AHi);
      if (c > 0) or ((c = 0) and (not AHiInc)) then
        Break;
    end;
    Inc(Result);
    ok := CursorNext(Cur);
  end;
end;

function TVDbDiskIdx.All(out AEntries: TVDbDixEntries): Integer;
var
  Cur: TDixCursor;
  ok: Boolean;
  cnt: Integer;
begin
  AEntries := nil;
  cnt := 0;
  ok := CursorFirst(Cur);
  while ok do
  begin
    cnt := AppendEntry(AEntries, cnt, Cur.Leaf[Cur.Pos]);
    ok := CursorNext(Cur);
  end;
  SetLength(AEntries, cnt);
  Result := cnt;
end;

function TVDbDiskIdx.Find(const AKey, AVal: string; out ACov: string): Boolean;
var
  Cur: TDixCursor;
  ok: Boolean;
begin
  Result := False;
  ACov := '';
  ok := CursorSeekKey(Cur, AKey, True);
  while ok and (FCmp.CompareKeyBound(Cur.Leaf[Cur.Pos].Key, AKey) = 0) do
  begin
    if FCmp.CompareEntries(Cur.Leaf[Cur.Pos].Key, Cur.Leaf[Cur.Pos].Val, AKey, AVal) = 0 then
    begin
      ACov := Cur.Leaf[Cur.Pos].Cov;
      Exit(True);
    end;
    ok := CursorNext(Cur);
  end;
end;

function TVDbDiskIdx.Count: Int64;
begin
  Result := FNKeys;
end;

function TVDbDiskIdx.Height: Integer;
begin
  Result := FHeight;
end;

function TVDbDiskIdx.PageCount: LongWord;
begin
  Result := FPageCount;
end;

function TVDbDiskIdx.RootPage: LongWord;
begin
  Result := FRoot;
end;

function TVDbDiskIdx.FreePageCount: Integer;
begin
  Result := FFreeCount;
end;

function TVDbDiskIdx.Verify(out AReport: string): Boolean;
var
  msg: TStringList;

  function NodeOK(ANo: LongWord; ADepth, AExpectLevel: Integer;
    out AFirstKey, AFirstVal, ALastKey, ALastVal: string; out ACount: Int64;
    out ALevel: Integer): Boolean;
  var
    P: TDixPageBuf;
    E: TVDbDixEntries;
    S: TDixSepArray;
    k: Integer;
    fk, lk, fv, lv: string;
    c: Int64;
    l: Integer;
  begin
    Result := False;
    AFirstKey := '';
    AFirstVal := '';
    ALastKey := '';
    ALastVal := '';
    ACount := 0;
    ALevel := 0;
    if ADepth > 63 then
    begin
      msg.Add('derinlik asiri');
      Exit;
    end;
    if (ANo < DIX_FIRST_DATA) or (ANo >= FPageCount) then
    begin
      msg.Add(Format('sayfa %d aralik disi', [ANo]));
      Exit;
    end;
    try
      ReadPage(ANo, P);
    except
      on E: Exception do
      begin
        msg.Add(Format('sayfa %d: %s', [ANo, E.Message]));
        Exit;
      end;
    end;
    ALevel := Hd(P)^.Level;
    if (AExpectLevel > 0) and (ALevel <> AExpectLevel) then
    begin
      msg.Add(Format('sayfa %d seviye %d, beklenen %d', [ANo, ALevel, AExpectLevel]));
      Exit;
    end;
    if Hd(P)^.Kind = DIX_LEAF then
    begin
      DecodeLeaf(P, E);
      if (Length(E) = 0) and (ANo <> FRoot) then
      begin
        msg.Add(Format('yaprak %d bos (kok degil)', [ANo]));
        Exit;
      end;
      for k := 0 to High(E) do
      begin
        if k > 0 then
          if FCmp.CompareEntries(E[k - 1].Key, E[k - 1].Val,
                                 E[k].Key, E[k].Val) >= 0 then
          begin
            msg.Add(Format('yaprak %d icinde sira bozuk (slot %d)', [ANo, k]));
            Exit;
          end;
        Inc(ACount);
      end;
      if Length(E) > 0 then
      begin
        AFirstKey := E[0].Key;
        AFirstVal := E[0].Val;
        ALastKey := E[High(E)].Key;
        ALastVal := E[High(E)].Val;
      end;
      Exit(True);
    end;
    if Hd(P)^.Kind <> DIX_INTERNAL then
    begin
      msg.Add(Format('sayfa %d turu gecersiz', [ANo]));
      Exit;
    end;
    DecodeInt(P, S, l);
    if Length(S) = 0 then
    begin
      msg.Add(Format('ic sayfa %d bos', [ANo]));
      Exit;
    end;
    for k := 0 to High(S) do
    begin
      if not NodeOK(S[k].Child, ADepth + 1, ALevel - 1, fk, fv, lk, lv, c, l) then
        Exit;
      if k = 0 then
      begin
        AFirstKey := fk;
        AFirstVal := fv;
      end
      else
      begin
        if (fk = '') and (lk = '') and (c = 0) then
        begin
          { bos alt agac: kok yaprakta gorulur, burada beklenmez }
          msg.Add(Format('sayfa %d alt agac %d bos', [ANo, k]));
          Exit;
        end;
        { Ayirici = sag alt agacin TAM ilk girisi olmali. Kucuk olursa yalniz
          yonlendirme yavaslar (dogru kalir); BUYUK olursa arama yanlis dala
          gider ve satir sessizce kaybolur - bu yuzden > 0 araniyor. }
        if FCmp.CompareEntries(S[k].Key, S[k].Val, fk, fv) > 0 then
        begin
          msg.Add(Format('sayfa %d ayirici %d gercek minimumdan buyuk', [ANo, k]));
          Exit;
        end;
        if FCmp.CompareEntries(AFirstKey, AFirstVal, fk, fv) > 0 then
        begin
          msg.Add(Format('sayfa %d alt agac sirasi bozuk', [ANo]));
          Exit;
        end;
      end;
      Inc(ACount, c);
      ALastKey := lk;
      ALastVal := lv;
    end;
    Result := True;
  end;

var
  fk, lk, fv, lv: string;
  c: Int64;
  lvl: Integer;
  n: Integer;
  EE: TVDbDixEntries;
begin
  Result := False;
  msg := TStringList.Create;
  try
    if FRoot = 0 then
    begin
      AReport := 'kok yok';
      Exit;
    end;
    if not NodeOK(FRoot, 0, FHeight, fk, fv, lk, lv, c, lvl) then
    begin
      AReport := Trim(msg.Text);
      Exit;
    end;
    n := All(EE);
    if n <> c then
    begin
      AReport := Format('gezinti sayisi %d, dugum toplami %d', [n, c]);
      Exit;
    end;
    if n <> FNKeys then
    begin
      AReport := Format('gezinti sayisi %d, meta sayaci %d', [n, FNKeys]);
      Exit;
    end;
    if msg.Count > 0 then
    begin
      AReport := Trim(msg.Text);
      Exit;
    end;
    AReport := Format('OK: %d anahtar, yukseklik %d, %d sayfa, %d serbest',
      [FNKeys, FHeight, FPageCount, FFreeCount]);
    Result := True;
  finally
    msg.Free;
  end;
end;

end.
