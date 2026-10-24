unit VDbPageWal;

{ VDB v3 - Sayfa imajli WAL (Sprint 1 / Gun 5)

  Amac: commit edilmis her sayfa degisikligi, veritabani dosyasina
  yazilmadan ONCE WAL'e yazilip fsync edilir. Boylece sayfa yaziminin
  yarida kalmesi (torn page) ya da surecin kill -9 ile olmesi veri
  kaybina yol acmaz.

  Dosya yerlesimi:
    kayit 0        : 4096 baytlik baslik (sihirli sayi, surum, sayfa boyu,
                     checkpoint LSN, CRC)
    sonraki kayitlar: cerceve ve commit kayitlari, ardisik

  Kayit basligi (20 bayt):
    Magic(4) | LSN(4) | PayloadLen(4) | PageNo(4) | Crc(4)

  - Cerceve (VFW1): PayloadLen = 4096, PageNo = sayfa numarasi, yuk = sayfa imaji.
  - Commit  (FWC1): PayloadLen = 0, PageNo = 0. Bu kayittan onceki tum
    cerceveler "commit edilmis" sayilir.

  Kurtarma: kayitlar bastan sona okunur. Bozuk/kesik kayit gorulunce
  DURULUR (kuyruk yarim kalmis demektir). Yalnizca bir commit kaydiyla
  kapanmis cerceveler uygulanir; commit'siz kuyruk atilir.

  Bilincli sinirlar:
  - Tek yazici.
  - WAL dosyasi checkpoint'te tamamen silinmez, basligi kalir (truncate).
  - Sayfa 0 (meta) WAL'e girmez; meta WAL commit'inden SONRA yazilir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbPage, VDbCrc32, VDbSync;

const
  VDB_WAL_MAGIC       = $334C5756;   // 'VWL3'
  VDB_WAL_VER         = 1;
  { Meta sayfa numarasi (VDbPageStore.VDB_HDR_PAGE ile ayni; bu birim
    depo birimine bagimli olmamak icin yerel sabit tutar). }
  VDB_WAL_META_PAGE   = 0;
  VDB_WAL_REC_FRAME   = $31574656;   // 'VFW1'
  VDB_WAL_REC_COMMIT  = $31435746;   // 'FWC1'
  VDB_WAL_REC_HDR     = 20;          // bayt

type
  EVdbWal = class(Exception);

  { Kurtarma sirasinda her onaylanmis cerceve icin cagrilir. }
  TVdbWalApplyProc = procedure(PageNo: LongWord; P: PVdbPage) of object;

  TVdbWalStats = record
    Frames: Integer;          // WAL'de commit edilmis cerceve sayisi
    Commits: Integer;
    TornTail: Boolean;        // kuyrukta bozuk/kesik kayit vardi
    Bytes: Int64;
  end;

  TVdbPageWal = class
  private
    type
      TPending = record
        PageNo: LongWord;
        Data: TVDbPageBuf;
      end;
    var
      FPath: string;
      FStream: TFileStream;
      FBuffer: array of TPending;    // commit bekleyen cerceveler
      FBufferCount: Integer;
      FLSN: LongWord;
      FHasContent: Boolean;
    procedure WriteHeader;
    procedure ReadHeader;
    function WriteRecord(Magic, PageNo, PayloadLen: LongWord;
      const Payload): LongWord;
    procedure AppendBuffer(PageNo: LongWord; P: PVdbPage);
    function BufferedPageIndex(PageNo: LongWord): Integer;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;

    { WAL dosyasini kesif/olustur (yoksa baslik yazar). }
    procedure Open;
    procedure Close;

    { WAL'de uygulanacak (commit edilmis) cerceve var mi? Acilista
      kurtarma gerekip gerekmedigine karar vermek icin. }
    function HasContent: Boolean;

    { Commit bekleyen cerceveyi ekler (bellekte). Ayni sayfa icin son
      ekleme kazanir. }
    procedure AppendFrame(PageNo: LongWord; P: PVdbPage);

    { Bekleyen cerceveleri diske yazar, commit kaydini ekler. DoSync=True
      ise fsync eder (P-DUR: commit fsync eder). }
    function Commit(DoSync: Boolean; LSN: LongWord): Boolean;

    { Commit edilmemis cerceveleri atar. }
    procedure Rollback;

    { WAL'i okuyup onaylanmis cerceveleri uygular. }
    function Recover(Apply: TVdbWalApplyProc; out Stats: TVdbWalStats): Boolean;

    { Checkpoint sonrasi WAL'i bosalt (yalniz baslik kalir). }
    procedure Truncate(CheckpointLSN: LongWord);

    property Path: string read FPath;
    property BufferedCount: Integer read FBufferCount;
  end;

implementation

type
  TPendingArray = array of TVdbPageWal.TPending;

{ Iki parca uzerinden tek CRC (baslik + yuk). }
function WalCrc(const Hdr; HdrLen: Integer; const Payload; PayLen: Integer): LongWord;
var
  c: LongWord;
begin
  c := VDbCrc32Init;
  c := VDbCrc32Update(c, Hdr, HdrLen);
  if PayLen > 0 then
    c := VDbCrc32Update(c, Payload, PayLen);
  Result := VDbCrc32Final(c);
end;

{ ------------------------------------------------------------------ baslik }

procedure TVDbPageWal.WriteHeader;
var
  buf: TVDbPageBuf;
  q: PLongWord;
  magic, ver: LongWord;
  ps: Word;
  lsn: LongWord;
begin
  FillChar(buf, SizeOf(buf), 0);
  magic := VDB_WAL_MAGIC;
  ver := VDB_WAL_VER;
  ps := VDB_PAGE_SIZE;
  lsn := FLSN;
  Move(magic, buf[0], 4);
  Move(ver, buf[4], 4);
  Move(ps, buf[8], 2);
  Move(lsn, buf[12], 4);
  q := PLongWord(@buf[VDB_PAGE_BODY_END]);
  q^ := VDbCrc32Of(buf, VDB_PAGE_BODY_END);
  FStream.Position := 0;
  FStream.WriteBuffer(buf, VDB_PAGE_SIZE);
end;

procedure TVDbPageWal.ReadHeader;
var
  buf: TVDbPageBuf;
  magic, ver, lsn, crc: LongWord;
  ps: Word;
  q: PLongWord;
begin
  if FStream.Size < VDB_PAGE_SIZE then
    raise EVdbWal.Create(Format('WAL dosyasi cok kucuk (%d bayt)', [FStream.Size]));
  FStream.Position := 0;
  FStream.ReadBuffer(buf, VDB_PAGE_SIZE);
  Move(buf[0], magic, 4);
  if magic <> VDB_WAL_MAGIC then
    raise EVdbWal.Create(Format('gecersiz WAL sihirli sayisi: $%.8x', [magic]));
  Move(buf[4], ver, 4);
  if ver <> VDB_WAL_VER then
    raise EVdbWal.Create(Format('desteklenmeyen WAL surumu: %d', [ver]));
  Move(buf[8], ps, 2);
  if ps <> VDB_PAGE_SIZE then
    raise EVdbWal.Create(Format('WAL sayfa boyu %d (beklenen %d)',
      [ps, VDB_PAGE_SIZE]));
  q := PLongWord(@buf[VDB_PAGE_BODY_END]);
  crc := q^;
  if VDbCrc32Of(buf, VDB_PAGE_BODY_END) <> crc then
    raise EVdbWal.Create('WAL basligi bozuk (CRC tutmadi)');
  Move(buf[12], lsn, 4);
  FLSN := lsn;
end;

{ ------------------------------------------------------------------ yasam }

constructor TVdbPageWal.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  FBufferCount := 0;
  FHasContent := False;
  FLSN := 0;
end;

destructor TVdbPageWal.Destroy;
begin
  try
    Close;
  except
    { yikici hata firlatmaz }
  end;
  inherited Destroy;
end;

procedure TVdbPageWal.Open;
var
  probe: TFileStream;
  hasFile: Boolean;
begin
  if FStream <> nil then Exit;
  hasFile := False;
  if FileExists(FPath) then
  begin
    { Sadece boyut kesfi; akis hemen kapatilir (dosya kilidi birakilsin). }
    probe := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone);
    try
      hasFile := probe.Size >= VDB_PAGE_SIZE;
    finally
      probe.Free;
    end;
  end;
  if hasFile then
  begin
    FStream := TFileStream.Create(FPath, fmOpenReadWrite or fmShareDenyWrite);
    try
      ReadHeader;
      FHasContent := FStream.Size > VDB_PAGE_SIZE;
    except
      FreeAndNil(FStream);
      raise;
    end;
  end
  else
  begin
    FStream := TFileStream.Create(FPath, fmCreate or fmShareDenyWrite);
    FLSN := 0;
    WriteHeader;
    VDbFlushStream(FStream);
    FHasContent := False;
  end;
end;

procedure TVdbPageWal.Close;
begin
  if FStream = nil then Exit;
  if FBufferCount > 0 then
    Rollback;
  FreeAndNil(FStream);
end;

function TVdbPageWal.HasContent: Boolean;
begin
  Result := FHasContent;
end;

{ ----------------------------------------------------------------- cerceve }

function TVdbPageWal.BufferedPageIndex(PageNo: LongWord): Integer;
var
  i: Integer;
begin
  for i := 0 to FBufferCount - 1 do
    if FBuffer[i].PageNo = PageNo then Exit(i);
  Result := -1;
end;

procedure TVdbPageWal.AppendBuffer(PageNo: LongWord; P: PVdbPage);
var
  i: Integer;
begin
  i := BufferedPageIndex(PageNo);
  if i >= 0 then
  begin
    Move(P^, FBuffer[i].Data, VDB_PAGE_SIZE);
    Exit;
  end;
  if FBufferCount >= Length(FBuffer) then
    SetLength(FBuffer, FBufferCount + 64);
  FBuffer[FBufferCount].PageNo := PageNo;
  Move(P^, FBuffer[FBufferCount].Data, VDB_PAGE_SIZE);
  Inc(FBufferCount);
end;

procedure TVdbPageWal.AppendFrame(PageNo: LongWord; P: PVdbPage);
begin
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  { Cerceve DISKE YAZILACAK bir imajdir: CRC'si simdi hesaplanir. Boylece
    kurtarma sirasinda yazilan sayfa PageVerify'dan gecer. }
  PageSeal(P);
  AppendBuffer(PageNo, P);
end;

procedure TVdbPageWal.Rollback;
begin
  FBufferCount := 0;
end;

function TVdbPageWal.WriteRecord(Magic, PageNo, PayloadLen: LongWord;
  const Payload): LongWord;
var
  hdr: array[0..VDB_WAL_REC_HDR - 1] of Byte;
  crc: LongWord;
begin
  Move(Magic, hdr[0], 4);
  Move(FLSN, hdr[4], 4);
  Move(PayloadLen, hdr[8], 4);
  Move(PageNo, hdr[12], 4);
  if PayloadLen > 0 then
    crc := WalCrc(hdr[0], 16, Payload, PayloadLen)
  else
    crc := WalCrc(hdr[0], 16, hdr[0], 0);
  Move(crc, hdr[16], 4);
  FStream.WriteBuffer(hdr[0], VDB_WAL_REC_HDR);
  if PayloadLen > 0 then
    FStream.WriteBuffer(Payload, PayloadLen);
  Result := crc;
end;

function TVdbPageWal.Commit(DoSync: Boolean; LSN: LongWord): Boolean;
var
  i: Integer;
begin
  Result := False;
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  if FBufferCount = 0 then Exit(True);   // yazacak bir sey yok
  FLSN := LSN;
  FStream.Position := FStream.Size;
  for i := 0 to FBufferCount - 1 do
    WriteRecord(VDB_WAL_REC_FRAME, FBuffer[i].PageNo, VDB_PAGE_SIZE,
      FBuffer[i].Data);
  WriteRecord(VDB_WAL_REC_COMMIT, 0, 0, LSN);
  if DoSync then
    VDbFlushStream(FStream);
  FBufferCount := 0;
  FHasContent := True;
  Result := True;
end;

{ ---------------------------------------------------------------- kurtarma }

function TVdbPageWal.Recover(Apply: TVdbWalApplyProc;
  out Stats: TVdbWalStats): Boolean;
var
  hdr: array[0..VDB_WAL_REC_HDR - 1] of Byte;
  magic, lsn, payLen, pageNo, crc: LongWord;
  calc: LongWord;
  payload: TVDbPageBuf;
  pending: TPendingArray;
  pendingCount: Integer;
  applied: TPendingArray;
  appliedCount: Integer;
  i, j: Integer;
  got: Integer;

  procedure AddTo(var arr: TPendingArray; var n: Integer;
    ANo: LongWord; const AData: TVDbPageBuf);
  var
    k: Integer;
  begin
    for k := 0 to n - 1 do
      if arr[k].PageNo = ANo then
      begin
        Move(AData, arr[k].Data, VDB_PAGE_SIZE);
        Exit;
      end;
    if n >= Length(arr) then
      SetLength(arr, n + 64);
    arr[n].PageNo := ANo;
    Move(AData, arr[n].Data, VDB_PAGE_SIZE);
    Inc(n);
  end;

begin
  Result := False;
  Stats.Frames := 0;
  Stats.Commits := 0;
  Stats.TornTail := False;
  Stats.Bytes := 0;
  pendingCount := 0;
  appliedCount := 0;
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  Stats.Bytes := FStream.Size - VDB_PAGE_SIZE;
  FStream.Position := VDB_PAGE_SIZE;
  while FStream.Position < FStream.Size do
  begin
    got := FStream.Read(hdr[0], VDB_WAL_REC_HDR);
    if got <> VDB_WAL_REC_HDR then
    begin
      Stats.TornTail := True;
      Break;
    end;
    Move(hdr[0], magic, 4);
    Move(hdr[4], lsn, 4);
    Move(hdr[8], payLen, 4);
    Move(hdr[12], pageNo, 4);
    Move(hdr[16], crc, 4);
    if (magic <> VDB_WAL_REC_FRAME) and (magic <> VDB_WAL_REC_COMMIT) then
    begin
      Stats.TornTail := True;
      Break;
    end;
    if (magic = VDB_WAL_REC_FRAME) and (payLen <> VDB_PAGE_SIZE) then
    begin
      Stats.TornTail := True;
      Break;
    end;
    if (magic = VDB_WAL_REC_COMMIT) and (payLen <> 0) then
    begin
      Stats.TornTail := True;
      Break;
    end;
    calc := WalCrc(hdr[0], 16, hdr[0], 0);
    if payLen > 0 then
    begin
      got := FStream.Read(payload[0], VDB_PAGE_SIZE);
      if got <> VDB_PAGE_SIZE then
      begin
        Stats.TornTail := True;
        Break;
      end;
      calc := WalCrc(hdr[0], 16, payload[0], VDB_PAGE_SIZE);
    end;
    if calc <> crc then
    begin
      Stats.TornTail := True;
      Break;
    end;

    if magic = VDB_WAL_REC_FRAME then
    begin
      AddTo(pending, pendingCount, pageNo, payload);
    end
    else
    begin
      { Commit: bekleyenleri onaylanmis kumeye tasi. }
      for j := 0 to pendingCount - 1 do
        AddTo(applied, appliedCount, pending[j].PageNo, pending[j].Data);
      pendingCount := 0;
      Inc(Stats.Commits);
      FLSN := lsn;
    end;
  end;

  { Commit'siz kuyruk atilir. Meta sayfa (0) EN SON uygulanir: once veri
    sayfalari yazilip dosya uzatilmali, yoksa meta'daki sayfa sayisi
    dosya boyutundan buyuk gorunur. }
  for i := 0 to appliedCount - 1 do
    if (applied[i].PageNo <> VDB_WAL_META_PAGE) and Assigned(Apply) then
      Apply(applied[i].PageNo, @applied[i].Data);
  for i := 0 to appliedCount - 1 do
    if (applied[i].PageNo = VDB_WAL_META_PAGE) and Assigned(Apply) then
      Apply(applied[i].PageNo, @applied[i].Data);
  Stats.Frames := appliedCount;
  Result := True;
end;

procedure TVdbPageWal.Truncate(CheckpointLSN: LongWord);
begin
  if FStream = nil then
    raise EVdbWal.Create('WAL acik degil');
  FLSN := CheckpointLSN;
  FBufferCount := 0;
  FStream.Size := VDB_PAGE_SIZE;
  WriteHeader;
  VDbFlushStream(FStream);
  FHasContent := False;
end;

end.
