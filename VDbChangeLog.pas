unit VDbChangeLog;

{ VDB v4 - MANTIKSAL DEGISIM GUNLUGU (SQLite tarzi PITR/replikasyon temeli)

  NE: Veritabanindaki her COMMIT'in mantiksal kayitlarini (anahtar + eski
  deger + yeni deger + zaman damgasi) ayri bir gunluk dizinine yazar.
  Sayfa imajli WAL'den FARKI: WAL yalnizca son checkpoint'ten beri olan
  degisiklikleri tutar ve "hangi satir degisti" bilgisini vermez. Bu gunluk
  KALICIDIR, checkpoint'lerle silinmez ve satir duzeyindedir; boylece
    - RECOVER TO TIMESTAMP  (taban imaj + ileri replay),
    - AS OF TIMESTAMP/VERSION (gecmis okuma),
    - replikasyon (segment tasima)
  mumkun olur.

  DOSYA DUZENI:  <db>.log\seg-000001.vlog, seg-000002.vlog, ...
                 <db>.log\base\b-<seq>-<lsn>.odb   (taban imaj)

  KAYIT BICIMI (kucuk endian):
    Segment basligi 512 B: Magic 'VLG1' | Ver u32 | Gen u32 | SegNo u32 |
                           DbGuid u64 | CreatedTsMs i64 | CRC32(0..511)
    Kayit basligi 40 B   : Magic 'VLR1' | RecLen u32 | Seq u64 | TsMs i64 |
                           Kind u8 | Pad u8*3 | TableId u32 | Key u64
    Yuk (Kind'e gore)    :
      1 = PUT : OldLen u32 | NewLen u32 | Old | New
      2 = DEL : OldLen u32 | NewLen u32 | Old | (NewLen=0)
      3 = BASE: Gen u32 | DbLsn u32 | DbBytes u64 | NameLen u32 | Ad (UTF-8)
               (Seq/TsMs = tabanin gunlukteki noktasi)
    Crc32 u32            : baslik + yuk uzerinde

  GRUP (ISLEM) BUTUNLUGU:
    Bir commit'in kayitlari arasina 'VLG0' (END) kaydi konur. Replay yalniz
    END'i gorulmus VE sayisi tutan gruplari uygular; kesik kuyruk atilir.
    Yani yarim islem PITR/replikasyona SIZMAZ.

  TEMEL KURAL: Bu dosya TURETILMIS DEGIL, KALICI bir kayittir. Silinirse
  gecmis kaybolur (veri kaybi degil, PITR yetenegi kaybi). Bu yuzden
  otomatik silinmez/kirpilmaz; yalnizca segment rotasyonu olur.

  ANAHTAR SOZLESMESI: Replay KV duzeyindedir (anahtar + ham deger baytlari),
  yani SQL yeniden kodlamasi YOKTUR; vdbmig ile ayni guvence (bayt bayt).
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, DateUtils, VDbCrc32, VDbSync;

const
  VDBLOG_DIR_SUFFIX   = '.log';
  VDBLOG_SEG_MAX      = 16 * 1024 * 1024;   // segment rotasyon esigi
  VDBLOG_SEG_HDR      = 512;
  VDBLOG_REC_HDR      = 40;
  VDBLOG_GROUP_MAX    = 128 * 1024 * 1024;  // tek grupta azami bellek
  VDBLOG_MAGIC_SEG    = LongWord($31474C56);  // 'VLG1'
  VDBLOG_MAGIC_REC    = LongWord($31524C56);  // 'VLR1'
  VDBLOG_MAGIC_END    = LongWord($30474C56);  // 'VLG0'
  VDBLOG_MAGIC_BASE   = LongWord($31424C56);  // 'VLB1'
  VDBLOG_VER          = 1;

  VDBLOG_KIND_PUT     = 1;
  VDBLOG_KIND_DEL     = 2;
  VDBLOG_KIND_BASE    = 3;

type
  EVdbChangeLog = class(Exception);

  TVdbLogChange = record
    Kind: Byte;              // VDBLOG_KIND_PUT / _DEL
    TableId: Integer;
    Key: QWord;
    OldVal: TBytes;
    NewVal: TBytes;
  end;

  TVdbLogEntry = record
    Kind: Byte;              // PUT / DEL / BASE
    Seq: Int64;              // commit (grup) sirasi; monoton
    TsMs: Int64;             // commit zamani (UTC, epoch ms)
    TableId: Integer;
    Key: QWord;
    OldVal: TBytes;
    NewVal: TBytes;
    // BASE icin
    Gen: LongWord;
    DbLsn: LongWord;
    DbBytes: Int64;
    BaseName: string;
    Flags: LongWord;         // bit0=1 -> nesil kopmasi (RESTORE); replay burada DURUR
  end;

  TVdbLogVisit = procedure(const E: TVdbLogEntry) of object;

  TVdbLogBase = record
    Seq: Int64;
    TsMs: Int64;
    Gen: LongWord;
    DbLsn: LongWord;
    DbBytes: Int64;
    Name: string;
    Flags: LongWord;
  end;

  TVdbLogBaseArray = array of TVdbLogBase;

  { v3.7: budama sonucu (olculen, tahmin degil). }
  TVdbLogPruneResult = record
    DroppedSegments: Integer;
    DroppedBaseFiles: Integer;
    BytesFreed: Int64;
  end;

  TVdbLogBaseNameArray = array of string;

  { v4 replikasyon: bir grubun HAM baytlari. Kayitlar yeniden kodlanmaz;
    tasima bayt bayt yapilir (goc ile ayni guvence). }
  TVdbLogRawGroup = record
    Seq: Int64;
    TsMs: Int64;
    Kind: Byte;             // VDBLOG_KIND_BASE = taban isareti; 0 = veri grubu
    Gen: LongWord;
    Flags: LongWord;
    BaseName: string;
    Data: TBytes;           // cerceveler (kayitlar [+ END]); taban icin tek BASE
  end;

  TVdbLogRawGroupArray = array of TVdbLogRawGroup;
  TVdbLogEntryArray = array of TVdbLogEntry;

  { ------------------------------------------------------------- yazici }
  TVdbChangeLog = class
  private
    FDbPath: string;
    FDir: string;
    FSeg: TFileStream;
    FSegNo: LongWord;
    FGroup: TList<TVdbLogChange>;
    FGroupBytes: Int64;
    FSegMax: Int64;             // rotasyon esigi (test icin degistirilebilir)
    FSeq: Int64;
    FGen: LongWord;
    FGuid: QWord;
    FInGroup: Boolean;
    FEnabled: Boolean;
    FSyncGroups: Boolean;
    FError: string;
    FLocal: TVdbLogChange;      // Add* icin gecici
    function SegPath(No: LongWord): string;
    procedure WriteSegHeader(S: TFileStream; SegNo: LongWord);
    procedure OpenNewSeg(No: LongWord);
    function ScanTail(out ALastSeq: Int64; out ALastGen: LongWord;
      out ALastSeg: LongWord): Boolean;
    function BuildRec(AMagic: LongWord; AKind: Byte; ASeq, ATsMs: Int64;
      ATableId: Integer; AKey: QWord; const Payload: TBytes): TBytes;
    function TakePayload(Kind: Byte; const AOld, ANew: TBytes): TBytes;
  public
    constructor Create;
    destructor Destroy; override;

    { ADbPath: .odb dosya yolu; gunluk <ADbPath>.log\ altina yazilir.
      ACreate=False ve dizin yoksa gunluk KAPALI kalir (Enabled=False) —
      sessizce baska yere yazmaz. }
    procedure Open(const ADbPath: string; ACreate: Boolean);
    procedure Close;
    property Enabled: Boolean read FEnabled;
    property Dir: string read FDir;
    property LastSeq: Int64 read FSeq;
    property Generation: LongWord read FGen;
    property Guid: QWord read FGuid;
    property LastError: string read FError;
    { v3.19 — GRUP SONU fsync. VARSAYILAN False (hizli).
      True:  her grup END kaydindan sonra fsync — gunlugun diske yazildigi
             AN GARANTI. Bedeli: commit basina ~0,3 ms (olculdu).
      False: grup yalniz isletim sistemine yazilir; fsync SEGMENT
             ROTASYONUNDA (16 MB), Close'da ve acik Flush'ta yapilir.
             Boylece SUREC cokmesinde kayip YOKTUR (OS tamponu yasar);
             yalniz elektrik kesintisi/makine cokmesinde son segmentin
             (en fazla 16 MB) kuyrugu kaybolabilir. VERITABANI VERISI
             bundan ETKILENMEZ: WAL her commit'te fsync edilir; kayip
             yalniz PITR/gunluk kuyrugudur. }
    property SyncGroups: Boolean read FSyncGroups write FSyncGroups;
    property SegMax: Int64 read FSegMax write FSegMax;

    procedure BeginGroup;
    procedure AddPut(ATableId: Integer; AKey: QWord;
      const AOld, ANew: TBytes);
    procedure AddDel(ATableId: Integer; AKey: QWord; const AOld: TBytes);
    procedure AbortGroup;
    { Grubu diske yazar (SyncGroups=True ise fsync de eder). Basarida
      ASeq/ATsMs dolar.
      Gunluk kapaliysa True doner ve hicbir sey yapmaz. AEngineLsn: commit
      sonrasi motor LSN'i (END kaydinda saklanir; acilista bosluk denetimi). }
    function EndGroup(AEngineLsn: LongWord; out ASeq, ATsMs: Int64): Boolean;
    { Taban isareti. ABaseName: <log>\base\ altindaki dosya adi (cagiran
      kopyalamis olmali). Yeni Gen uretir; yeni Seq doner.
      AFlags bit0=1 = NESIL KOPMASI (RESTORE): replay bu tabanda DURUR. }
    function WriteBase(ADbLsn: LongWord; ADbBytes: Int64; ATsMs: Int64;
      AFlags: LongWord; const ABaseName: string): Int64;
    { REPLIKA: baska bir dugumun veri grubunu AYNEN ekler. Seq alanlari
      YEREL siraya cevrilir, END kaydinin motor LSN'i AEngineLsn yapilir ve
      her cercevenin CRC'si yeniden hesaplanir. Taban (BASE) kaydi KABUL
      EDILMEZ (taban kurulumu RESTORE ile yapilir).
      Basarida yeni yerel seq, hatada 0 + FError. }
    function AppendForeignGroup(const ARaw: TBytes;
      AEngineLsn: LongWord): Int64;
    procedure Flush;
  end;

  { ------------------------------------------------------------- okuyucu }
  TVdbLogReader = class
  private
    FDbPath: string;
    FDir: string;
    FSegs: TList<LongWord>;
    function SegPath(No: LongWord): string;
    procedure CollectSegs;
    { v3.7: bir segmentin ozeti (budama karari icin). }
    function SegSpan(const APath: string; out AMaxSeq, AMaxTs,
      ABytes: Int64; out ANames: TVdbLogBaseNameArray): Boolean;
  public
    constructor Create(const ADbPath: string);
    destructor Destroy; override;
    property Dir: string read FDir;
    function Exists: Boolean;
    function SegmentCount: Integer;
    { Son gecerli grubun sirasi ve o grubun END kaydindaki motor LSN'i.
      Hic grup yoksa False (yalniz taban isaretleri var). }
    function LastState(out ALastSeq: Int64; out ALastEndLsn: LongWord): Boolean;
    { Taban isaretlerini (BASE) sirayla dondurur. }
    function ListBases: TVdbLogBaseArray;
    { Gunlugu bastan sona okur; yalniz TAM gruplari ziyaret eder.
      FromSeq  : bu siradan KUCUK/ESIT gruplar atlanir (taban secimi).
      ToSeq    : bu siradan BUYUK gruplarda durulur (grup uygulanmaz).
      ToTsMs   : bu zamandan SONRAKI gruplarda durulur.
      BASE kayitlari Cb'ye ziyaret edilir; FromSeq'ten sonra gelen ve
      nesil kopmasi isaretli (Flags bit0) BASE kaydi replay'i DURDURUR.
      Donus: True = kesik/bozuk kuyruk ya da nesil kopmasi nedeniyle erken
      durdu (Reason anlatir); False = gunlugun sonuna kadar temiz okundu. }
    function Replay(FromSeq, ToSeq, ToTsMs: Int64; Cb: TVdbLogVisit;
      out AppliedGroups: Int64; out StoppedReason: string): Boolean;

    { v4 replikasyon: mevcut sira araligi (taban + tam gruplar). Yoksa False. }
    function SeqRange(out AMinSeq, AMaxSeq: Int64): Boolean;
    { FromSeq'ten BUYUK ilk AMaxGroups grubu HAM baytlariyla dondurur.
      Yalniz TAM gruplar doner (kesik kuyruk asla). Bellek siniri icin
      parti parti cagrilir; AMore = kesme sinirina takildik (daha olabilir). }
    function ExtractGroups(FromSeq: Int64; AMaxGroups: Integer;
      out AMore: Boolean): TVdbLogRawGroupArray;

    { v3.7: gunlukteki EN ESKI kaydin zamani (gunluk bos/okunamazsa False). }
    function OldestGroupTsMs(out ATsMs: Int64): Boolean;
    { v3.7: BUDAMA. Yalniz TAM segmentlerden olusan ONEK silinir; aktif
      (en yeni) segment ve yeni tabanin kapsadigi aralik korunur.
      CutoffMs : bu zamandan ESKI gruplar budanabilir; <=0 = zaman kurali kapali.
      KeepBases: en az bu kadar taban imaji korunur (>=1; oneri 2).
      Guvenlik: hic taban isareti yoksa HICBIR sey silinmez.
      Donus False: AErr'de neden; kismi silme olmus olabilir (AR dolu). }
    function Prune(CutoffMs: Int64; KeepBases: Integer;
      out AR: TVdbLogPruneResult; out AErr: string): Boolean;
  end;

function VdbLogNowMs: Int64;
function VdbLogDirOf(const ADbPath: string): string;

{ v3.7: gunluk budama - politika "N gun VEYA K taban imaji, hangisi daha
  uzun bir gecmis tutuyorsa". KeepDays <= 0 = zaman kurali kapali.
  VdbLogPruneAt: kesim noktasi ACIKCA verilir (test/operasyon icin). }
function VdbLogPruneAt(const ADbPath: string; CutoffMs: Int64;
  KeepBases: Integer; out AR: TVdbLogPruneResult;
  out AErr: string): Boolean;
function VdbLogPrune(const ADbPath: string; KeepDays, KeepBases: Integer;
  out AR: TVdbLogPruneResult; out AErr: string): Boolean;{ SQL 'AS OF TIMESTAMP' metnini gunluk zamanina (UTC unix ms) cevirir.
  Kabul: 'YYYY-MM-DD' | 'YYYY-MM-DD HH:MM' | 'YYYY-MM-DD HH:MM:SS[.mmm]'
  Ayirici olarak 'T' de olabilir, sonda 'Z' yok sayilir. }
function VdbLogParseTimestamp(const S: string; out Ms: Int64): Boolean;
{ Gunluk zamanini okunabilir yerel metne cevirir (hata mesajlari icin). }
function VdbLogFormatTimestamp(Ms: Int64): string;
{ v2 sozdiziminden gelen "duvar saati" epoch'unu (NowUnixMS kurali) GERCEK
  UTC epoch'a cevirir. Yalnizca PITR hedefi olarak kullanilir; hedef tarihteki
  yerel UTC farki (yaz saati dahil) uygulanir. }
function VdbLogWallMsToUtcMs(WallMs: Int64): Int64;

{ REPLIKASYON: ham grup baytlarini kayitlara cozer (END atilir; taban
  kaydi cozulmez -> False). Basarida True. }
function VdbLogDecodeGroup(const AData: TBytes;
  out AEntries: TVdbLogEntryArray): Boolean;

implementation

function ReadOneRecordRaw(S: TStream; out E: TVdbLogEntry;
  out AIsEnd: Boolean; out EndCount: LongWord; out ARaw: TBytes): Boolean;
  forward;

function ReadOneRecord(S: TStream; out E: TVdbLogEntry;
  out AIsEnd: Boolean; out EndCount: LongWord): Boolean; forward;

function VdbLogNowMs: Int64;
var
  dt: TDateTime;
begin
  dt := LocalTimeToUniversal(Now);
  Result := Int64(DateTimeToUnix(dt, False)) * 1000 + MilliSecondOf(dt);
end;

function VdbLogDirOf(const ADbPath: string): string;
begin
  Result := ADbPath + VDBLOG_DIR_SUFFIX;
end;

function VdbLogParseTimestamp(const S: string; out Ms: Int64): Boolean;
var
  t: string;
  y, mo, d, h, mi, se, ms_: Integer;
  dt: TDateTime;
  i: Integer;
begin
  Ms := 0;
  Result := False;
  t := Trim(S);
  if (Length(t) >= 2) and (t[1] = '''') and (t[Length(t)] = '''') then
    t := Copy(t, 2, Length(t) - 2);
  t := StringReplace(t, 'T', ' ', [rfReplaceAll]);
  if (Length(t) > 0) and (t[Length(t)] = 'Z') then
    Delete(t, Length(t), 1);
  t := Trim(t);
  if Length(t) < 10 then Exit;
  if (t[5] <> '-') or (t[8] <> '-') then Exit;
  y := StrToIntDef(Copy(t, 1, 4), -1);
  mo := StrToIntDef(Copy(t, 6, 2), -1);
  d := StrToIntDef(Copy(t, 9, 2), -1);
  h := 0; mi := 0; se := 0; ms_ := 0;
  if Length(t) >= 16 then
  begin
    if t[11] <> ' ' then Exit;
    h := StrToIntDef(Copy(t, 12, 2), -1);
    mi := StrToIntDef(Copy(t, 15, 2), -1);
    if Length(t) >= 19 then
    begin
      if t[14] <> ':' then Exit;
      if t[17] <> ':' then Exit;
      se := StrToIntDef(Copy(t, 18, 2), -1);
      if Length(t) >= 20 then
      begin
        if t[20] <> '.' then Exit;
        i := Length(t) - 20;
        if (i < 1) or (i > 3) then Exit;
        ms_ := StrToIntDef(Copy(t, 21, i), -1);
        while i < 3 do
        begin
          ms_ := ms_ * 10;
          Inc(i);
        end;
      end;
    end
    else if t[14] <> ':' then
      Exit;
  end;
  if (y < 1970) or (y > 9999) or (mo < 1) or (mo > 12) or (d < 1) or (d > 31)
    or (h < 0) or (h > 23) or (mi < 0) or (mi > 59) or
    (se < 0) or (se > 59) or (ms_ < 0) or (ms_ > 999) then
    Exit;
  try
    dt := EncodeDateTime(y, mo, d, h, mi, se, ms_);
  except
    Exit;
  end;
  Ms := Int64(DateTimeToUnix(dt, False)) * 1000 + ms_;
  Result := True;
end;

function VdbLogFormatTimestamp(Ms: Int64): string;
var
  dt: TDateTime;
begin
  if Ms <= 0 then Exit('0');
  dt := UnixToDateTime(Ms div 1000, False);   { UTC -> yerel saat }
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', dt) + '.' +
    Format('%.3d', [Ms mod 1000]);
end;

function VdbLogWallMsToUtcMs(WallMs: Int64): Int64;
var
  dt: TDateTime;
begin
  if WallMs <= 0 then Exit(0);
  { Duvar saati degerini alan olarak coz, sonra yerelden UTC'ye cevir. }
  dt := UnixToDateTime(WallMs div 1000, True);
  Result := Int64(DateTimeToUnix(dt, False)) * 1000 + (WallMs mod 1000);
end;

{ ------------------------------------------------------- bayt yardimcilari }

procedure PutU32(var B: TBytes; Pos: Integer; V: LongWord);
begin
  Move(V, B[Pos], 4);
end;procedure PutU64(var B: TBytes; Pos: Integer; V: QWord);
begin
  Move(V, B[Pos], 8);
end;

function ReadU32(const B: TBytes; Pos: Integer): LongWord;
begin
  Move(B[Pos], Result, 4);
end;

function ReadU64(const B: TBytes; Pos: Integer): QWord;
begin
  Move(B[Pos], Result, 8);
end;

function ReadI64(const B: TBytes; Pos: Integer): Int64;
begin
  Move(B[Pos], Result, 8);
end;

function RecPayloadLen(const AOld, ANew: TBytes): Integer;
begin
  Result := 8 + Length(AOld) + Length(ANew);
end;

{ ================================================================ yazici }

constructor TVdbChangeLog.Create;
begin
  inherited Create;
  FGroup := TList<TVdbLogChange>.Create;
  FSeq := 0;
  FGen := 1;
  FGuid := 0;
  FEnabled := False;
  FSegNo := 0;
  FGroupBytes := 0;
  FSegMax := VDBLOG_SEG_MAX;
  FSyncGroups := False;
end;

destructor TVdbChangeLog.Destroy;
begin
  Close;
  FGroup.Free;
  inherited Destroy;
end;

function TVdbChangeLog.SegPath(No: LongWord): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + 'seg-' +
    Format('%.6d', [No]) + '.vlog';
end;

procedure TVdbChangeLog.WriteSegHeader(S: TFileStream; SegNo: LongWord);
var
  h: TBytes;
  crc: LongWord;
begin
  SetLength(h, VDBLOG_SEG_HDR);
  FillChar(h[0], VDBLOG_SEG_HDR, 0);
  PutU32(h, 0, VDBLOG_MAGIC_SEG);
  PutU32(h, 4, VDBLOG_VER);
  PutU32(h, 8, FGen);
  PutU32(h, 12, SegNo);
  PutU64(h, 16, FGuid);
  PutU64(h, 24, QWord(VdbLogNowMs));
  crc := VDbCrc32OfBytes(h, VDBLOG_SEG_HDR - 4);
  PutU32(h, VDBLOG_SEG_HDR - 4, crc);
  S.WriteBuffer(h[0], VDBLOG_SEG_HDR);
end;

procedure TVdbChangeLog.OpenNewSeg(No: LongWord);
var
  p: string;
begin
  if FSeg <> nil then
  begin
    try
      VDbFlushStream(FSeg);
    except
    end;
    FreeAndNil(FSeg);
  end;
  p := SegPath(No);
  FSeg := TFileStream.Create(p, fmCreate or fmShareDenyNone);
  try
    WriteSegHeader(FSeg, No);
    VDbFlushStream(FSeg);
    VDbFlushDir(FDir);
  except
    FreeAndNil(FSeg);
    raise;
  end;
  FSegNo := No;
end;

{ Var olan segmentlerin sonunu okur: son grup sirasi, Gen ve segment no.
  Bozuk/kesik kuyruk sessizce atlanir (yalniz TAM gruplar gecerlidir). }
function LogTailState(S: TFileStream; out ASeq: Int64; out ALsn: LongWord;
  out AIsEnd: Boolean): Boolean;
const
  { Kuyruk penceresi: BASE yuku taban dosya adini da tasir; 2 KB fazlasiyla
    yeter (tipik taban adi < 40 bayt). }
  WINMAX = 2048;
var
  b, rec: TBytes;
  avail, win, off, rl: Integer;
  magic: LongWord;
  total: Int64;
begin
  Result := False;
  ASeq := 0;
  ALsn := 0;
  AIsEnd := False;
  total := S.Size;
  if total < VDBLOG_SEG_HDR + VDBLOG_REC_HDR + 8 then Exit;
  avail := Integer(total - VDBLOG_SEG_HDR);
  if avail > WINMAX then win := WINMAX else win := avail;
  S.Position := total - win;
  SetLength(b, win);
  if S.Read(b[0], win) <> win then Exit;
  { Kuyruktaki son kayit END (grup sonu) ya da BASE (checkpoint tabani)
    olabilir; ikisi de sira numarasini ve motor LSN'ini tasir. Aday baslangic
    ancak toplam uzunlugu dosya sonuna TAM oturuyorsa ve CRC tutuyorsa kabul
    edilir; aksi halde False -> cagiran tam tarama yapar (guvenli yol). }
  for off := win - (VDBLOG_REC_HDR + 8) downto 0 do
  begin
    magic := ReadU32(b, off);
    if (magic <> VDBLOG_MAGIC_END) and
       (magic <> VDBLOG_MAGIC_BASE) then Continue;
    rl := Integer(ReadU32(b, off + 4));
    if (rl < 0) or (off + VDBLOG_REC_HDR + rl + 4 <> win) then Continue;
    SetLength(rec, VDBLOG_REC_HDR + rl + 4);
    Move(b[off], rec[0], Length(rec));
    if ReadU32(rec, VDBLOG_REC_HDR + rl) <> VDbCrc32OfBytes(rec,
      VDBLOG_REC_HDR + rl) then Continue;
    ASeq := ReadI64(rec, 8);
    AIsEnd := (magic = VDBLOG_MAGIC_END);
    if AIsEnd then
      ALsn := LongWord(ReadU64(rec, 32))     { END: Key = motor LSN }
    else
      ALsn := ReadU32(rec, VDBLOG_REC_HDR + 4);  { BASE: yukte DbLsn }
    Exit(True);
  end;
end;

function TVdbChangeLog.ScanTail(out ALastSeq: Int64; out ALastGen: LongWord;
  out ALastSeg: LongWord): Boolean;
var
  sr: TSearchRec;
  segs: TList<LongWord>;
  i: Integer;
  p: string;
  S: TFileStream;
  hdr: TBytes;
  rl: Integer;
  kind: Integer;
  seq: Int64;
  tailLsn: LongWord;
  tailEnd: Boolean;

  procedure NoteSeg(const FileName: string);
  var
    v: LongWord;
  begin
    if Copy(FileName, 1, 4) <> 'seg-' then Exit;
    v := LongWord(StrToIntDef(Copy(FileName, 5, 6), 0));
    if v > 0 then segs.Add(v);
  end;

begin
  Result := False;
  ALastSeq := 0;
  ALastGen := 0;
  ALastSeg := 0;
  segs := TList<LongWord>.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(FDir) + 'seg-*.vlog',
      faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) = 0 then NoteSeg(ExtractFileName(sr.Name));
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    if segs.Count = 0 then Exit;
    segs.Sort;
    ALastSeg := segs[segs.Count - 1];
    for i := 0 to segs.Count - 1 do
    begin
      p := SegPath(segs[i]);
      if not FileExists(p) then Continue;
      S := TFileStream.Create(p, fmOpenRead or fmShareDenyNone);
      try
        SetLength(hdr, VDBLOG_SEG_HDR);
        if S.Read(hdr[0], VDBLOG_SEG_HDR) <> VDBLOG_SEG_HDR then Continue;
        if ReadU32(hdr, 0) <> VDBLOG_MAGIC_SEG then Continue;
        ALastGen := ReadU32(hdr, 8);
        FGuid := ReadU64(hdr, 16);
        { v3.5: KAPALI segment ise son sira numarasi O(1) okunur. Eskiden
          TUM gecmis her acilista bastan sona taraniyordu: 57 MB gunluk
          (600k kayit) acilisi 20 s'ye cikariyordu. Aktif segment (henuz
          END yazilmamis) tam taranir; boyutu tek segmentle sinirlidir. }
        if LogTailState(S, seq, tailLsn, tailEnd) then
        begin
          if seq > ALastSeq then ALastSeq := seq;
          Continue;
        end;
        SetLength(hdr, VDBLOG_REC_HDR);
        while S.Position + VDBLOG_REC_HDR <= S.Size do
        begin
          if S.Read(hdr[0], VDBLOG_REC_HDR) <> VDBLOG_REC_HDR then Break;
          kind := hdr[24];
          seq := ReadI64(hdr, 8);
          rl := Integer(ReadU32(hdr, 4));
          if (ReadU32(hdr, 0) = VDBLOG_MAGIC_END) or
             (ReadU32(hdr, 0) = VDBLOG_MAGIC_BASE) then
          begin
            if seq > ALastSeq then ALastSeq := seq;
          end
          else if ReadU32(hdr, 0) <> VDBLOG_MAGIC_REC then
            Break;
          if kind = VDBLOG_KIND_BASE then
            if seq > ALastSeq then ALastSeq := seq;
          if (rl < 0) or (S.Position + rl + 4 > S.Size) then Break;
          S.Position := S.Position + rl + 4;
        end;
      finally
        S.Free;
      end;
    end;
    Result := True;
  finally
    segs.Free;
  end;
end;

function NewLogGuid: QWord;
begin
  Randomize;
  Result := (QWord(Random(MaxInt)) shl 33) xor (QWord(Random(MaxInt)) shl 2)
    xor QWord(GetTickCount64) xor QWord(VdbLogNowMs);
end;

procedure TVdbChangeLog.Open(const ADbPath: string; ACreate: Boolean);
var
  lastSeq: Int64;
  lastGen, lastSeg: LongWord;
begin
  Close;
  FDbPath := ADbPath;
  FDir := VdbLogDirOf(ADbPath);
  FEnabled := False;
  FError := '';
  if not DirectoryExists(FDir) then
  begin
    if not ACreate then Exit;
    if not ForceDirectories(IncludeTrailingPathDelimiter(FDir) + 'base') then
    begin
      FError := 'gunluk dizini olusturulamadi: ' + FDir;
      Exit;
    end;
    FGuid := NewLogGuid;
    FGen := 1;
    FSeq := 0;
    OpenNewSeg(1);
    FEnabled := True;
    Exit;
  end;
  ForceDirectories(IncludeTrailingPathDelimiter(FDir) + 'base');
  if not ScanTail(lastSeq, lastGen, lastSeg) then
  begin
    FGuid := NewLogGuid;
    FGen := 1;
    FSeq := 0;
    OpenNewSeg(1);
    FEnabled := True;
    Exit;
  end;
  FSeq := lastSeq;
  if lastGen = 0 then lastGen := 1;
  FGen := lastGen;
  if lastSeg = 0 then lastSeg := 1;
  try
    FSeg := TFileStream.Create(SegPath(lastSeg),
      fmOpenReadWrite or fmShareDenyNone);
    FSeg.Seek(0, soEnd);
    FSegNo := lastSeg;
  except
    on E: Exception do
    begin
      FError := 'gunluk segmenti acilamadi: ' + E.Message;
      Exit;
    end;
  end;
  FEnabled := True;
end;

procedure TVdbChangeLog.Flush;
begin
  if FSeg <> nil then
    VDbFlushStream(FSeg);
end;

procedure TVdbChangeLog.Close;
begin
  if FInGroup then AbortGroup;
  if FSeg <> nil then
  begin
    try
      VDbFlushStream(FSeg);
    except
    end;
    FreeAndNil(FSeg);
  end;
  FEnabled := False;
end;

function TVdbChangeLog.BuildRec(AMagic: LongWord; AKind: Byte; ASeq, ATsMs: Int64;
  ATableId: Integer; AKey: QWord; const Payload: TBytes): TBytes;
var
  total: Integer;
  crc: LongWord;
begin
  total := VDBLOG_REC_HDR + Length(Payload) + 4;
  SetLength(Result, total);
  FillChar(Result[0], VDBLOG_REC_HDR, 0);
  PutU32(Result, 0, AMagic);;
  PutU32(Result, 4, LongWord(Length(Payload)));
  Move(ASeq, Result[8], 8);
  Move(ATsMs, Result[16], 8);
  Result[24] := AKind;
  PutU32(Result, 28, LongWord(ATableId));
  PutU64(Result, 32, AKey);
  if Length(Payload) > 0 then
    Move(Payload[0], Result[VDBLOG_REC_HDR], Length(Payload));
  crc := VDbCrc32OfBytes(Result, total - 4);
  PutU32(Result, total - 4, crc);
end;

function TVdbChangeLog.TakePayload(Kind: Byte; const AOld,
  ANew: TBytes): TBytes;
begin
  SetLength(Result, RecPayloadLen(AOld, ANew));
  PutU32(Result, 0, LongWord(Length(AOld)));
  if Kind = VDBLOG_KIND_PUT then
    PutU32(Result, 4, LongWord(Length(ANew)))
  else
    PutU32(Result, 4, 0);
  if Length(AOld) > 0 then
    Move(AOld[0], Result[8], Length(AOld));
  if (Kind = VDBLOG_KIND_PUT) and (Length(ANew) > 0) then
    Move(ANew[0], Result[8 + Length(AOld)], Length(ANew));
end;

{ v3.10 (2026-10-26): grup kodlamasi YERINDE. ONCEDEN her satir icin
  TakePayload (1 bellek ayirma + 2 kopya) ve BuildRec (1 bellek ayirma +
  kopya) cagriliyor, sonra ucuncu kez grup tamponuna kopyalaniyordu:
  satir basina 2 ayirma + 3 kopya. Bu yardimci kaydi dogrudan grup
  tamponuna yazar; uretilen baytlar BuildRec+TakePayload ile BIREBIR
  aynidir (alan alan ayni sira, ayni CRC). }
function PutChangeRecAt(var Buf: TBytes; Pos: Integer; AMagic: LongWord;
  AKind: Byte; ASeq, ATsMs: Int64; ATableId: Integer; AKey: QWord;
  const AOld, ANew: TBytes): Integer;
var
  payloadLen, recLen, p: Integer;
begin
  payloadLen := 8 + Length(AOld);
  if AKind = VDBLOG_KIND_PUT then Inc(payloadLen, Length(ANew));
  recLen := VDBLOG_REC_HDR + payloadLen + 4;
  FillChar(Buf[Pos], VDBLOG_REC_HDR, 0);
  PutU32(Buf, Pos, AMagic);
  PutU32(Buf, Pos + 4, LongWord(payloadLen));
  Move(ASeq, Buf[Pos + 8], 8);
  Move(ATsMs, Buf[Pos + 16], 8);
  Buf[Pos + 24] := AKind;
  PutU32(Buf, Pos + 28, LongWord(ATableId));
  PutU64(Buf, Pos + 32, AKey);
  p := Pos + VDBLOG_REC_HDR;
  PutU32(Buf, p, LongWord(Length(AOld)));
  if AKind = VDBLOG_KIND_PUT then
    PutU32(Buf, p + 4, LongWord(Length(ANew)))
  else
    PutU32(Buf, p + 4, 0);
  Inc(p, 8);
  if Length(AOld) > 0 then
  begin
    Move(AOld[0], Buf[p], Length(AOld));
    Inc(p, Length(AOld));
  end;
  if (AKind = VDBLOG_KIND_PUT) and (Length(ANew) > 0) then
  begin
    Move(ANew[0], Buf[p], Length(ANew));
    Inc(p, Length(ANew));
  end;
  PutU32(Buf, Pos + recLen - 4, VDbCrc32Of(Buf[Pos], recLen - 4));
  Result := Pos + recLen;
end;

procedure TVdbChangeLog.BeginGroup;
begin
  if not FEnabled then Exit;
  if FInGroup then AbortGroup;
  FGroup.Clear;
  FGroupBytes := 0;
  FInGroup := True;
end;

procedure TVdbChangeLog.AddPut(ATableId: Integer; AKey: QWord;
  const AOld, ANew: TBytes);
begin
  if not FInGroup then Exit;
  FLocal.Kind := VDBLOG_KIND_PUT;
  FLocal.TableId := ATableId;
  FLocal.Key := AKey;
  FLocal.OldVal := AOld;
  FLocal.NewVal := ANew;
  FGroup.Add(FLocal);
  FGroupBytes := FGroupBytes + VDBLOG_REC_HDR + 4 + RecPayloadLen(AOld, ANew);
  if FGroupBytes > VDBLOG_GROUP_MAX then
    raise EVdbChangeLog.Create(Format(
      'degisim gunlugu: tek islem %d bayti asti (sinir %d)',
      [FGroupBytes, VDBLOG_GROUP_MAX]));
end;

procedure TVdbChangeLog.AddDel(ATableId: Integer; AKey: QWord;
  const AOld: TBytes);
begin
  if not FInGroup then Exit;
  FLocal.Kind := VDBLOG_KIND_DEL;
  FLocal.TableId := ATableId;
  FLocal.Key := AKey;
  FLocal.OldVal := AOld;
  FLocal.NewVal := nil;
  FGroup.Add(FLocal);
  FGroupBytes := FGroupBytes + VDBLOG_REC_HDR + 4 + 8 + Length(AOld);
  if FGroupBytes > VDBLOG_GROUP_MAX then
    raise EVdbChangeLog.Create(Format(
      'degisim gunlugu: tek islem %d bayti asti (sinir %d)',
      [FGroupBytes, VDBLOG_GROUP_MAX]));
end;

procedure TVdbChangeLog.AbortGroup;
begin
  FGroup.Clear;
  FGroupBytes := 0;
  FInGroup := False;
end;

function TVdbChangeLog.EndGroup(AEngineLsn: LongWord;
  out ASeq, ATsMs: Int64): Boolean;
var
  i, total, pos: Integer;
  all, rec, payload: TBytes;
  seq, ts: Int64;
  posBefore: Int64;
  r: TVdbLogChange;
begin
  ASeq := FSeq;
  ATsMs := 0;
  Result := True;
  if not FEnabled then Exit;
  if not FInGroup then Exit;
  if FGroup.Count = 0 then
  begin
    FInGroup := False;
    Exit;
  end;
  seq := FSeq + 1;
  ts := VdbLogNowMs;
  { v3.10: toplam boyut FGroupBytes'ten gelir (Add* zaten tam sayiyor);
    ONCEDEN tum grup bir kez daha dolasilip toplaniyordu. }
  total := Integer(FGroupBytes) + VDBLOG_REC_HDR + 4 + 4;   // END + sayi
  SetLength(all, total);
  pos := 0;
  for i := 0 to FGroup.Count - 1 do
  begin
    r := FGroup[i];
    pos := PutChangeRecAt(all, pos, VDBLOG_MAGIC_REC, r.Kind, seq, ts,
      r.TableId, r.Key, r.OldVal, r.NewVal);
  end;
  SetLength(payload, 4);
  PutU32(payload, 0, LongWord(FGroup.Count));
  rec := BuildRec(VDBLOG_MAGIC_END, 0, seq, ts, 0, AEngineLsn, payload);
  Move(rec[0], all[pos], Length(rec));
  pos := pos + Length(rec);
  if pos <> total then
  begin
    AbortGroup;
    raise EVdbChangeLog.Create('degisim gunlugu: ic boyut uyusmazligi');
  end;
  try
    if FSeg = nil then
      OpenNewSeg(FSegNo + 1);
    posBefore := FSeg.Size;
    FSeg.WriteBuffer(all[0], total);
    if FSyncGroups then
      VDbFlushStream(FSeg);
    if FSeg.Size >= FSegMax then
      OpenNewSeg(FSegNo + 1);
  except
    on E: Exception do
    begin
      FError := 'degisim gunlugu yazilamadi: ' + E.Message;
      { Yarim grup birakma: kuyruk kesilirse sonraki gruplar da okunamaz. }
      try
        if (FSeg <> nil) and (FSeg.Size > posBefore) then
          FSeg.Size := posBefore;
      except
      end;
      AbortGroup;
      Exit(False);
    end;
  end;
  FSeq := seq;
  ASeq := seq;
  ATsMs := ts;
  FGroup.Clear;
  FGroupBytes := 0;
  FInGroup := False;
end;

function TVdbChangeLog.WriteBase(ADbLsn: LongWord; ADbBytes: Int64;
  ATsMs: Int64; AFlags: LongWord; const ABaseName: string): Int64;
var
  payload, rec: TBytes;
  seq: Int64;
  nb: Integer;
begin
  Result := FSeq;
  if not FEnabled then Exit;
  if FInGroup then AbortGroup;
  seq := FSeq + 1;
  if ATsMs <= 0 then ATsMs := VdbLogNowMs;
  nb := Length(ABaseName);
  SetLength(payload, 24 + nb);
  Inc(FGen);
  PutU32(payload, 0, FGen);
  PutU32(payload, 4, ADbLsn);
  PutU64(payload, 8, QWord(ADbBytes));
  PutU32(payload, 16, AFlags);
  PutU32(payload, 20, LongWord(nb));
  if nb > 0 then
    Move(ABaseName[1], payload[24], nb);
  rec := BuildRec(VDBLOG_MAGIC_BASE, VDBLOG_KIND_BASE, seq, ATsMs, 0, 0, payload);
  if FSeg = nil then
    OpenNewSeg(FSegNo + 1);
  FSeg.WriteBuffer(rec[0], Length(rec));
  VDbFlushStream(FSeg);
  FSeq := seq;
  Result := seq;
end;

{ REPLIKA: yabanci grubu yerel siraya cevirerek yaz.
  Cerceve duzeni: 40 B baslik | yuk (RecLen) | Crc32
  Baslikta: Magic u32 @0, RecLen u32 @4, Seq i64 @8, TsMs i64 @16.
  END kaydinda Key (u64 @32) = motor LSN. }
function TVdbChangeLog.AppendForeignGroup(const ARaw: TBytes;
  AEngineLsn: LongWord): Int64;
var
  ms: TMemoryStream;
  frame: TBytes;
  pos, fl, rl, n: Integer;
  magic: LongWord;
  newSeq: Int64;
  crc: LongWord;
  total: Int64;
  posBefore: Int64;
begin
  Result := 0;
  FError := '';
  if not FEnabled then
  begin
    FError := 'degisim gunlugu kapali';
    Exit;
  end;
  if FInGroup then
  begin
    FError := 'acik grup varken replika grubu eklenemez';
    Exit;
  end;
  n := Length(ARaw);
  if n < VDBLOG_REC_HDR + 4 then
  begin
    FError := 'replika grubu cok kisa';
    Exit;
  end;
  if ReadU32(ARaw, 0) = VDBLOG_MAGIC_BASE then
  begin
    FError := 'taban kaydi replika gunlugune eklenemez (RESTORE kullanin)';
    Exit;
  end;
  newSeq := FSeq + 1;
  ms := TMemoryStream.Create;
  try
    pos := 0;
    while pos + VDBLOG_REC_HDR + 4 <= n do
    begin
      magic := ReadU32(ARaw, pos);
      if (magic <> VDBLOG_MAGIC_REC) and (magic <> VDBLOG_MAGIC_END) then
      begin
        FError := Format('replika grubunda gecersiz cerceve (offset %d)', [pos]);
        Exit;
      end;
      rl := Integer(ReadU32(ARaw, pos + 4));
      fl := VDBLOG_REC_HDR + rl + 4;
      if (rl < 0) or (pos + fl > n) then
      begin
        FError := Format('replika grubunda kirik cerceve (offset %d)', [pos]);
        Exit;
      end;
      frame := Copy(ARaw, pos, fl);
      PutU64(frame, 8, QWord(newSeq));
      if magic = VDBLOG_MAGIC_END then
        PutU64(frame, 32, QWord(AEngineLsn));
      crc := VDbCrc32OfBytes(frame, fl - 4);
      PutU32(frame, fl - 4, crc);
      ms.WriteBuffer(frame[0], fl);
      pos := pos + fl;
    end;
    if pos <> n then
    begin
      FError := 'replika grubunda artik bayt var';
      Exit;
    end;
    total := ms.Size;
    try
      if FSeg = nil then
        OpenNewSeg(FSegNo + 1);
      posBefore := FSeg.Size;
      ms.Position := 0;
      FSeg.CopyFrom(ms, total);
      VDbFlushStream(FSeg);
      if FSeg.Size >= FSegMax then
        OpenNewSeg(FSegNo + 1);
    except
      on E: Exception do
      begin
        FError := 'gunluk yazilamadi: ' + E.Message;
        try
          if (FSeg <> nil) and (FSeg.Size > posBefore) then
            FSeg.Size := posBefore;
        except
        end;
        Exit;
      end;
    end;
  finally
    ms.Free;
  end;
  FSeq := newSeq;
  Result := newSeq;
end;

{ =============================================================== okuyucu }

constructor TVdbLogReader.Create(const ADbPath: string);
begin
  inherited Create;
  FDbPath := ADbPath;
  FDir := VdbLogDirOf(ADbPath);
  FSegs := TList<LongWord>.Create;
  CollectSegs;
end;

destructor TVdbLogReader.Destroy;
begin
  FSegs.Free;
  inherited Destroy;
end;

function TVdbLogReader.SegPath(No: LongWord): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + 'seg-' +
    Format('%.6d', [No]) + '.vlog';
end;

procedure TVdbLogReader.CollectSegs;
var
  sr: TSearchRec;
  v: LongWord;
  q: string;
begin
  FSegs.Clear;
  if not DirectoryExists(FDir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(FDir) + 'seg-*.vlog',
    faAnyFile, sr) = 0 then
  begin
    repeat
      q := ExtractFileName(sr.Name);
      if Copy(q, 1, 4) = 'seg-' then
      begin
        v := LongWord(StrToIntDef(Copy(q, 5, 6), 0));
        if v > 0 then FSegs.Add(v);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  FSegs.Sort;
end;

function TVdbLogReader.Exists: Boolean;
begin
  Result := FSegs.Count > 0;
end;

function TVdbLogReader.SegmentCount: Integer;
begin
  Result := FSegs.Count;
end;

function TVdbLogReader.LastState(out ALastSeq: Int64;
  out ALastEndLsn: LongWord): Boolean;
var
  i: Integer;
  S: TFileStream;
  hdr: TBytes;
  E: TVdbLogEntry;
  isEnd: Boolean;
  cnt: LongWord;
  tailSeq: Int64;
  tailLsn: LongWord;
  tailEnd: Boolean;
begin
  Result := False;
  ALastSeq := 0;
  ALastEndLsn := 0;
  CollectSegs;
  for i := 0 to FSegs.Count - 1 do
  begin
    if not FileExists(SegPath(FSegs[i])) then Continue;
    S := TFileStream.Create(SegPath(FSegs[i]), fmOpenRead or fmShareDenyNone);
    try
      SetLength(hdr, VDBLOG_SEG_HDR);
      if S.Read(hdr[0], VDBLOG_SEG_HDR) <> VDBLOG_SEG_HDR then Continue;
      if ReadU32(hdr, 0) <> VDBLOG_MAGIC_SEG then Continue;
      { v3.5: son kayit O(1) okunur. Eskiden her ACILISTA tum gunluk
        (600k kayit / 57 MB) bastan sona CRC'lenerek okunuyordu: acilis
        20 s'ye cikiyordu. Kuyruk END ise durum odur; BASE ise ya da kuyruk
        bozuksa o segment tam taranir (davranis eskisiyle AYNI). }
      if LogTailState(S, tailSeq, tailLsn, tailEnd) then
      begin
        if tailEnd then
        begin
          ALastSeq := tailSeq;
          ALastEndLsn := tailLsn;
          Result := True;
          Continue;
        end;
      end;
      S.Position := VDBLOG_SEG_HDR;
      while ReadOneRecord(S, E, isEnd, cnt) do
      begin
        if not isEnd then Continue;
        ALastSeq := E.Seq;
        ALastEndLsn := LongWord(E.Key);
        Result := True;
      end;
    finally
      S.Free;
    end;
  end;
end;

{ Segment akisindan TEK bir kaydi okur (baslik + yuk + crc dogrulamasi).
  End=True ise kayit grup sonudur (END); EndCount grup kayit sayisidir.
  Kesik/bozuk kuyrukta False doner. }
function ReadOneRecordRaw(S: TStream; out E: TVdbLogEntry;
  out AIsEnd: Boolean; out EndCount: LongWord; out ARaw: TBytes): Boolean;
var
  hdr, payload, all: TBytes;
  rl, oldLen, newLen, nb: Integer;
  crcCalc, crcStored: LongWord;
begin
  Result := False;
  AIsEnd := False;
  EndCount := 0;
  ARaw := nil;
  FillChar(E, SizeOf(E), 0);
  SetLength(hdr, VDBLOG_REC_HDR);
  if S.Position + VDBLOG_REC_HDR > S.Size then Exit;
  if S.Read(hdr[0], VDBLOG_REC_HDR) <> VDBLOG_REC_HDR then Exit;
  rl := Integer(ReadU32(hdr, 4));
  if (rl < 0) or (S.Position + rl + 4 > S.Size) then Exit;
  SetLength(payload, rl);
  if rl > 0 then
    if S.Read(payload[0], rl) <> rl then Exit;
  SetLength(all, VDBLOG_REC_HDR + rl + 4);
  Move(hdr[0], all[0], VDBLOG_REC_HDR);
  if rl > 0 then
    Move(payload[0], all[VDBLOG_REC_HDR], rl);
  if S.Read(all[VDBLOG_REC_HDR + rl], 4) <> 4 then Exit;
  crcCalc := VDbCrc32OfBytes(all, Length(all) - 4);
  crcStored := ReadU32(all, Length(all) - 4);
  if crcCalc <> crcStored then Exit;
  ARaw := all;

  E.Seq := ReadI64(hdr, 8);
  E.TsMs := ReadI64(hdr, 16);
  E.Kind := hdr[24];
  if ReadU32(hdr, 0) = VDBLOG_MAGIC_END then
  begin
    if rl <> 4 then Exit;
    AIsEnd := True;
    EndCount := ReadU32(payload, 0);
    E.Key := ReadU64(hdr, 32);      // END: motor LSN'i
    Exit(True);
  end;
  if ReadU32(hdr, 0) = VDBLOG_MAGIC_BASE then
  begin
    if rl < 24 then Exit;
    E.Kind := VDBLOG_KIND_BASE;
    E.Gen := ReadU32(payload, 0);
    E.DbLsn := ReadU32(payload, 4);
    E.DbBytes := Int64(ReadU64(payload, 8));
    E.Flags := ReadU32(payload, 16);
    nb := Integer(ReadU32(payload, 20));
    E.BaseName := '';
    if (nb > 0) and (24 + nb <= rl) then
    begin
      SetLength(E.BaseName, nb);
      Move(payload[24], E.BaseName[1], nb);
    end;
    Exit(True);
  end;
  if ReadU32(hdr, 0) <> VDBLOG_MAGIC_REC then Exit;
  if rl < 8 then Exit;
  E.TableId := Integer(ReadU32(hdr, 28));
  E.Key := ReadU64(hdr, 32);
  oldLen := Integer(ReadU32(payload, 0));
  newLen := Integer(ReadU32(payload, 4));
  if (oldLen < 0) or (newLen < 0) or (8 + oldLen + newLen > rl) then Exit;
  if oldLen > 0 then
  begin
    SetLength(E.OldVal, oldLen);
    Move(payload[8], E.OldVal[0], oldLen);
  end;
  if (E.Kind = VDBLOG_KIND_PUT) and (newLen > 0) then
  begin
    SetLength(E.NewVal, newLen);
    Move(payload[8 + oldLen], E.NewVal[0], newLen);
  end;
  Result := True;
end;

{ Geriye uyumlu sarmalayici: ham baytlari istemeyen cagirilar. }
function ReadOneRecord(S: TStream; out E: TVdbLogEntry;
  out AIsEnd: Boolean; out EndCount: LongWord): Boolean;
var
  dummy: TBytes;
begin
  Result := ReadOneRecordRaw(S, E, AIsEnd, EndCount, dummy);
end;

function VdbLogDecodeGroup(const AData: TBytes;
  out AEntries: TVdbLogEntryArray): Boolean;
var
  ms: TMemoryStream;
  E: TVdbLogEntry;
  isEnd: Boolean;
  cnt: LongWord;
  raw: TBytes;
  n: Integer;
begin
  AEntries := nil;
  Result := False;
  n := 0;
  ms := TMemoryStream.Create;
  try
    if Length(AData) > 0 then
      ms.WriteBuffer(AData[0], Length(AData));
    ms.Position := 0;
    while ReadOneRecordRaw(ms, E, isEnd, cnt, raw) do
    begin
      if isEnd then
      begin
        Result := True;
        Break;
      end;
      if E.Kind = VDBLOG_KIND_BASE then Exit;
      SetLength(AEntries, n + 1);
      AEntries[n] := E;
      Inc(n);
    end;
  finally
    ms.Free;
  end;
end;

function TVdbLogReader.ListBases: TVdbLogBaseArray;
var
  i, n, rl, pos, segSize, nb: Integer;
  S: TFileStream;
  buf, rec: TBytes;
  b: TVdbLogBase;
  magic: LongWord;
begin
  Result := nil;
  n := 0;
  CollectSegs;
  for i := 0 to FSegs.Count - 1 do
  begin
    if not FileExists(SegPath(FSegs[i])) then Continue;
    S := TFileStream.Create(SegPath(FSegs[i]), fmOpenRead or fmShareDenyNone);
    try
      segSize := Integer(S.Size);
      if (segSize < VDBLOG_SEG_HDR) or (segSize > 256 * 1024 * 1024) then
        Continue;
      { v3.5: segment TEK okumada bellege alinir ve kayitlar bellekte
        atlanir. Eskiden her kayit icin ayri Read/Seek (3 sistem cagrisi)
        yapiliyordu: 600k kayitli 57 MB gunlukte acilis ~6 s. }
      SetLength(buf, segSize);
      S.Position := 0;
      if S.Read(buf[0], segSize) <> segSize then Continue;
      if ReadU32(buf, 0) <> VDBLOG_MAGIC_SEG then Continue;
      pos := VDBLOG_SEG_HDR;
      while pos + VDBLOG_REC_HDR <= segSize do
      begin
        magic := ReadU32(buf, pos);
        if (magic <> VDBLOG_MAGIC_REC) and (magic <> VDBLOG_MAGIC_END) and
           (magic <> VDBLOG_MAGIC_BASE) then
          Break;
        rl := Integer(ReadU32(buf, pos + 4));
        if (rl < 0) or (pos + VDBLOG_REC_HDR + rl + 4 > segSize) then Break;
        if magic = VDBLOG_MAGIC_BASE then
        begin
          { Taban kaydi TAM (CRC dahil) dogrulanir. }
          SetLength(rec, VDBLOG_REC_HDR + rl + 4);
          Move(buf[pos], rec[0], Length(rec));
          if ReadU32(rec, Length(rec) - 4) = VDbCrc32OfBytes(rec,
            Length(rec) - 4) then
          begin
            b.Seq := ReadI64(rec, 8);
            b.TsMs := ReadI64(rec, 16);
            b.Gen := ReadU32(rec, VDBLOG_REC_HDR);
            b.DbLsn := ReadU32(rec, VDBLOG_REC_HDR + 4);
            b.DbBytes := Int64(ReadU64(rec, VDBLOG_REC_HDR + 8));
            b.Flags := ReadU32(rec, VDBLOG_REC_HDR + 16);
            nb := Integer(ReadU32(rec, VDBLOG_REC_HDR + 20));
            b.Name := '';
            if (nb > 0) and (24 + nb <= rl) then
            begin
              SetLength(b.Name, nb);
              Move(rec[VDBLOG_REC_HDR + 24], b.Name[1], nb);
            end;
            SetLength(Result, n + 1);
            Result[n] := b;
            Inc(n);
          end;
        end;
        pos := pos + VDBLOG_REC_HDR + rl + 4;
      end;
    finally
      S.Free;
    end;
  end;
end;

function TVdbLogReader.SeqRange(out AMinSeq, AMaxSeq: Int64): Boolean;
var
  i: Integer;
  S: TFileStream;
  hdr: TBytes;
  E: TVdbLogEntry;
  isEnd: Boolean;
  cnt: LongWord;
begin
  AMinSeq := 0;
  AMaxSeq := 0;
  Result := False;
  CollectSegs;
  for i := 0 to FSegs.Count - 1 do
  begin
    if not FileExists(SegPath(FSegs[i])) then Continue;
    S := TFileStream.Create(SegPath(FSegs[i]), fmOpenRead or fmShareDenyNone);
    try
      SetLength(hdr, VDBLOG_SEG_HDR);
      if S.Read(hdr[0], VDBLOG_SEG_HDR) <> VDBLOG_SEG_HDR then Continue;
      if ReadU32(hdr, 0) <> VDBLOG_MAGIC_SEG then Continue;
      while ReadOneRecord(S, E, isEnd, cnt) do
      begin
        { Yalniz TAM noktalar sayilir: grup sonu (END) ve taban isareti. }
        if (not isEnd) and (E.Kind <> VDBLOG_KIND_BASE) then Continue;
        if (not Result) or (E.Seq < AMinSeq) then AMinSeq := E.Seq;
        if (not Result) or (E.Seq > AMaxSeq) then AMaxSeq := E.Seq;
        Result := True;
      end;
    finally
      S.Free;
    end;
  end;
end;

function TVdbLogReader.ExtractGroups(FromSeq: Int64; AMaxGroups: Integer;
  out AMore: Boolean): TVdbLogRawGroupArray;
var
  i: Integer;
  S: TFileStream;
  hdr, raw: TBytes;
  E: TVdbLogEntry;
  isEnd: Boolean;
  cnt: LongWord;
  ms: TMemoryStream;
  g: TVdbLogRawGroup;
  done, open: Boolean;
begin
  Result := nil;
  AMore := False;
  if AMaxGroups <= 0 then AMaxGroups := MaxInt;
  CollectSegs;
  ms := TMemoryStream.Create;
  open := False;
  done := False;
  try
    for i := 0 to FSegs.Count - 1 do
    begin
      if done then Break;
      if not FileExists(SegPath(FSegs[i])) then Continue;
      S := TFileStream.Create(SegPath(FSegs[i]), fmOpenRead or fmShareDenyNone);
      try
        SetLength(hdr, VDBLOG_SEG_HDR);
        if S.Read(hdr[0], VDBLOG_SEG_HDR) <> VDBLOG_SEG_HDR then Continue;
        if ReadU32(hdr, 0) <> VDBLOG_MAGIC_SEG then Continue;
        while ReadOneRecordRaw(S, E, isEnd, cnt, raw) do
        begin
          if E.Seq <= FromSeq then Continue;
          if E.Kind = VDBLOG_KIND_BASE then
          begin
            { Taban isareti tek kayittir; yarim veri grubu varsa atilir. }
            ms.Clear;
            open := False;
            g.Kind := VDBLOG_KIND_BASE;
            g.Seq := E.Seq;
            g.TsMs := E.TsMs;
            g.Gen := E.Gen;
            g.Flags := E.Flags;
            g.BaseName := E.BaseName;
            g.Data := raw;
            SetLength(Result, Length(Result) + 1);
            Result[High(Result)] := g;
            if Length(Result) >= AMaxGroups then
            begin
              done := True;
              AMore := True;
              Break;
            end;
            Continue;
          end;
          if not open then
          begin
            ms.Clear;
            open := True;
          end;
          ms.WriteBuffer(raw[0], Length(raw));
          if isEnd then
          begin
            g.Kind := 0;
            g.Seq := E.Seq;
            g.TsMs := E.TsMs;
            g.Gen := 0;
            g.Flags := 0;
            g.BaseName := '';
            SetLength(g.Data, ms.Size);
            if ms.Size > 0 then
            begin
              ms.Position := 0;
              ms.ReadBuffer(g.Data[0], ms.Size);
            end;
            SetLength(Result, Length(Result) + 1);
            Result[High(Result)] := g;
            ms.Clear;
            open := False;
            if Length(Result) >= AMaxGroups then
            begin
              done := True;
              AMore := True;
              Break;
            end;
          end;
        end;
      finally
        S.Free;
      end;
      { Segment sonu: END gormemis yarim grup ASLA tasinmaz. }
      ms.Clear;
      open := False;
    end;
  finally
    ms.Free;
  end;
end;

function TVdbLogReader.Replay(FromSeq, ToSeq, ToTsMs: Int64;
  Cb: TVdbLogVisit; out AppliedGroups: Int64;
  out StoppedReason: string): Boolean;
var
  i: Integer;
  S: TFileStream;
  hdr: TBytes;
  E: TVdbLogEntry;
  isEnd: Boolean;
  cnt: LongWord;
  group: TList<TVdbLogEntry>;
  k: Integer;
begin
  Result := False;
  AppliedGroups := 0;
  StoppedReason := '';
  CollectSegs;
  if FSegs.Count = 0 then
  begin
    StoppedReason := 'gunluk bos';
    Exit;
  end;
  group := TList<TVdbLogEntry>.Create;
  try
    if FromSeq <= 0 then
    begin
      StoppedReason := 'taban secilmedi (FromSeq=0)';
      Exit(True);
    end;
    for i := 0 to FSegs.Count - 1 do
    begin
      if not FileExists(SegPath(FSegs[i])) then Continue;
      S := TFileStream.Create(SegPath(FSegs[i]), fmOpenRead or fmShareDenyNone);
      try
        SetLength(hdr, VDBLOG_SEG_HDR);
        if S.Read(hdr[0], VDBLOG_SEG_HDR) <> VDBLOG_SEG_HDR then
        begin
          StoppedReason := 'kesik segment basligi';
          Exit(True);
        end;
        if ReadU32(hdr, 0) <> VDBLOG_MAGIC_SEG then
        begin
          StoppedReason := 'bozuk segment basligi';
          Exit(True);
        end;
        group.Clear;
        while ReadOneRecord(S, E, isEnd, cnt) do
        begin
          if isEnd then
          begin
            if cnt <> LongWord(group.Count) then
            begin
              StoppedReason := 'grup sayisi tutmuyor';
              Exit(True);
            end;
            if (group.Count > 0) and (group[0].Seq > FromSeq) then
            begin
              if (ToSeq > 0) and (group[0].Seq > ToSeq) then
              begin
                StoppedReason := 'seq siniri';
                Exit(False);
              end;
              if (ToTsMs > 0) and (group[0].TsMs > ToTsMs) then
              begin
                StoppedReason := 'zaman siniri';
                Exit(False);
              end;
              if Assigned(Cb) then
                for k := 0 to group.Count - 1 do
                  Cb(group[k]);
              Inc(AppliedGroups);
            end;
            group.Clear;
            Continue;
          end;
          if E.Kind = VDBLOG_KIND_BASE then
          begin
            if group.Count > 0 then
            begin
              StoppedReason := 'grup icinde BASE kaydi';
              Exit(True);
            end;
            if (E.Seq > FromSeq) and ((E.Flags and 1) <> 0) then
            begin
              { Hedef zamani bu kopmadan ONCE ise kurtarma hala gecerli:
                taban + gruplar hedefe kadar tam. }
              if (ToTsMs > 0) and (E.TsMs > ToTsMs) then
              begin
                StoppedReason := 'zaman siniri';
                Exit(False);
              end;
              StoppedReason := 'nesil kopmasi (yeni Gen=' + IntToStr(E.Gen) + ')';
              Exit(True);
            end;
            if Assigned(Cb) then Cb(E);
            Continue;
          end;
          group.Add(E);
        end;
        // segment bitti: grup tamamlanmadiysa kesik kuyruk
        if group.Count > 0 then
        begin
          StoppedReason := 'kesik grup (segment sonu)';
          group.Clear;
          Exit(True);
        end;
        if S.Position < S.Size then
        begin
          StoppedReason := 'kesik kuyruk (' + IntToStr(S.Size - S.Position) +
            ' bayt artik)';
          Exit(True);
        end;
      finally
        S.Free;
      end;
    end;
  finally
    group.Free;
  end;
end;

function TVdbLogReader.OldestGroupTsMs(out ATsMs: Int64): Boolean;
var
  i: Integer;
  S: TFileStream;
  buf: TBytes;
  segSize, pos, rl: Integer;
  magic: LongWord;
begin
  ATsMs := 0;
  Result := False;
  CollectSegs;
  for i := 0 to FSegs.Count - 1 do
  begin
    if not FileExists(SegPath(FSegs[i])) then Continue;
    S := TFileStream.Create(SegPath(FSegs[i]), fmOpenRead or fmShareDenyNone);
    try
      segSize := Integer(S.Size);
      if (segSize < VDBLOG_SEG_HDR) or (segSize > 256 * 1024 * 1024) then
        Continue;
      SetLength(buf, segSize);
      S.Position := 0;
      if S.Read(buf[0], segSize) <> segSize then Continue;
      if ReadU32(buf, 0) <> VDBLOG_MAGIC_SEG then Continue;
      pos := VDBLOG_SEG_HDR;
      while pos + VDBLOG_REC_HDR <= segSize do
      begin
        magic := ReadU32(buf, pos);
        if (magic <> VDBLOG_MAGIC_REC) and (magic <> VDBLOG_MAGIC_END) and
           (magic <> VDBLOG_MAGIC_BASE) then Break;
        rl := Integer(ReadU32(buf, pos + 4));
        if (rl < 0) or (pos + VDBLOG_REC_HDR + rl + 4 > segSize) then Break;
        { Ilk gecerli kaydin zamani = gunlugun en eski noktasi. }
        ATsMs := ReadI64(buf, pos + 16);
        Exit(True);
      end;
    finally
      S.Free;
    end;
  end;
end;

function TVdbLogReader.SegSpan(const APath: string;
  out AMaxSeq, AMaxTs, ABytes: Int64;
  out ANames: TVdbLogBaseNameArray): Boolean;
var
  S: TFileStream;
  buf, rec: TBytes;
  segSize, pos, rl, nb, n: Integer;
  magic: LongWord;
  sq, tsm: Int64;
begin
  Result := False;
  AMaxSeq := 0;
  AMaxTs := 0;
  ABytes := 0;
  ANames := nil;
  if not FileExists(APath) then Exit;
  S := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    segSize := Integer(S.Size);
    if (segSize < VDBLOG_SEG_HDR) or (segSize > 256 * 1024 * 1024) then Exit;
    ABytes := segSize;
    SetLength(buf, segSize);
    S.Position := 0;
    if S.Read(buf[0], segSize) <> segSize then Exit;
    if ReadU32(buf, 0) <> VDBLOG_MAGIC_SEG then Exit;
    pos := VDBLOG_SEG_HDR;
    n := 0;
    while pos + VDBLOG_REC_HDR <= segSize do
    begin
      magic := ReadU32(buf, pos);
      if (magic <> VDBLOG_MAGIC_REC) and (magic <> VDBLOG_MAGIC_END) and
         (magic <> VDBLOG_MAGIC_BASE) then Break;
      rl := Integer(ReadU32(buf, pos + 4));
      if (rl < 0) or (pos + VDBLOG_REC_HDR + rl + 4 > segSize) then Break;
      sq := ReadI64(buf, pos + 8);
      tsm := ReadI64(buf, pos + 16);
      if sq > AMaxSeq then AMaxSeq := sq;
      if tsm > AMaxTs then AMaxTs := tsm;
      if magic = VDBLOG_MAGIC_BASE then
      begin
        { Taban adi yalniz CRC'si TUTAN kayittan alinir: bozuk bir kaydin
          adi yuzunden saglam imaj silinmesin. }
        SetLength(rec, VDBLOG_REC_HDR + rl + 4);
        Move(buf[pos], rec[0], Length(rec));
        if ReadU32(rec, Length(rec) - 4) = VDbCrc32OfBytes(rec,
          Length(rec) - 4) then
        begin
          nb := Integer(ReadU32(rec, VDBLOG_REC_HDR + 20));
          if (nb > 0) and (24 + nb <= rl) then
          begin
            SetLength(ANames, n + 1);
            SetLength(ANames[n], nb);
            Move(rec[VDBLOG_REC_HDR + 24], ANames[n][1], nb);
            Inc(n);
          end;
        end;
      end;
      pos := pos + VDBLOG_REC_HDR + rl + 4;
    end;
    Result := True;
  finally
    S.Free;
  end;
end;

function TVdbLogReader.Prune(CutoffMs: Int64; KeepBases: Integer;
  out AR: TVdbLogPruneResult; out AErr: string): Boolean;
var
  bases: TVdbLogBaseArray;
  i, j: Integer;
  keepFrom, baseFloor, maxSeq, maxTs, size: Int64;
  names, doomed: TVdbLogBaseNameArray;
  p, bp: string;
begin
  AR.DroppedSegments := 0;
  AR.DroppedBaseFiles := 0;
  AR.BytesFreed := 0;
  AErr := '';
  Result := False;
  if KeepBases < 1 then KeepBases := 1;
  CollectSegs;
  if FSegs.Count = 0 then Exit(True);
  bases := ListBases;
  { Taban yoksa "silinen gruplar bir tabanla kapsaniyor" KANITLANAMAZ:
    hicbir sey silinmez (veri kaybi riski sifir). }
  if Length(bases) = 0 then Exit(True);

  { Zorunlu alt sinir: EN YENI tabanin sirasi. Bu siradan itibaren her grup
    (taban + ileri replay) canli durum icin gerekli. }
  keepFrom := bases[0].Seq;
  for i := 1 to High(bases) do
    if bases[i].Seq > keepFrom then keepFrom := bases[i].Seq;
  { "En az KeepBases taban imaji" kurali daha ESKI bir sinir koyar: bu,
    zaman kurali ne derse desin o tabanin kapsadigi gecmisi KORUR
    (yani iki kuraldan HANGISI DAHA UZUN tutuyorsa o kazanir). }
  if Length(bases) >= KeepBases then
  begin
    baseFloor := bases[Length(bases) - KeepBases].Seq;
    if baseFloor < keepFrom then keepFrom := baseFloor;
  end;

  doomed := nil;
  { ONEK: yalniz bastan kesintisiz silinir. Aktif (en yeni) segment her
    zaman korunur: yazici ona ekleme yapiyor olabilir. }
  for i := 0 to FSegs.Count - 2 do
  begin
    p := SegPath(FSegs[i]);
    if not FileExists(p) then Continue;
    if not SegSpan(p, maxSeq, maxTs, size, names) then
    begin
      AErr := 'segment okunamadi: ' + ExtractFileName(p);
      Exit;                       { onek kurali: buradan ileriye dokunma }
    end;
    if maxSeq >= keepFrom then Break;
    if (CutoffMs > 0) and (maxTs >= CutoffMs) then Break;
    if not DeleteFile(p) then
    begin
      AErr := 'segment silinemedi: ' + ExtractFileName(p);
      Exit;
    end;
    Inc(AR.DroppedSegments);
    Inc(AR.BytesFreed, size);
    for j := 0 to High(names) do
    begin
      SetLength(doomed, Length(doomed) + 1);
      doomed[High(doomed)] := names[j];
    end;
  end;

  { Silinen segmentlerdeki BASE isaretleri artik okunamaz: imaj dosyalari
    da erisilemez durumdadir, birlikte silinir. }
  for i := 0 to High(doomed) do
  begin
    if doomed[i] = '' then Continue;
    bp := IncludeTrailingPathDelimiter(FDir) + 'base' + PathDelim + doomed[i];
    if not FileExists(bp) then Continue;
    if DeleteFile(bp) then Inc(AR.DroppedBaseFiles)
    else
    begin
      AErr := 'taban imaji silinemedi: ' + doomed[i];
      Exit;
    end;
  end;
  Result := True;
end;

function VdbLogPruneAt(const ADbPath: string; CutoffMs: Int64;
  KeepBases: Integer; out AR: TVdbLogPruneResult;
  out AErr: string): Boolean;
var
  r: TVdbLogReader;
begin
  r := TVdbLogReader.Create(ADbPath);
  try
    Result := r.Prune(CutoffMs, KeepBases, AR, AErr);
  finally
    r.Free;
  end;
end;

function VdbLogPrune(const ADbPath: string; KeepDays, KeepBases: Integer;
  out AR: TVdbLogPruneResult; out AErr: string): Boolean;
var
  cut: Int64;
begin
  if KeepDays > 0 then
    cut := VdbLogNowMs - Int64(KeepDays) * Int64(86400000)
  else
    cut := 0;
  Result := VdbLogPruneAt(ADbPath, cut, KeepBases, AR, AErr);
end;

end.
