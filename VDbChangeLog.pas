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
    property SegMax: Int64 read FSegMax write FSegMax;

    procedure BeginGroup;
    procedure AddPut(ATableId: Integer; AKey: QWord;
      const AOld, ANew: TBytes);
    procedure AddDel(ATableId: Integer; AKey: QWord; const AOld: TBytes);
    procedure AbortGroup;
    { Grubu diske yazar + fsync eder. Basarida ASeq/ATsMs dolar.
      Gunluk kapaliysa True doner ve hicbir sey yapmaz. AEngineLsn: commit
      sonrasi motor LSN'i (END kaydinda saklanir; acilista bosluk denetimi). }
    function EndGroup(AEngineLsn: LongWord; out ASeq, ATsMs: Int64): Boolean;
    { Taban isareti. ABaseName: <log>\base\ altindaki dosya adi (cagiran
      kopyalamis olmali). Yeni Gen uretir; yeni Seq doner.
      AFlags bit0=1 = NESIL KOPMASI (RESTORE): replay bu tabanda DURUR. }
    function WriteBase(ADbLsn: LongWord; ADbBytes: Int64; ATsMs: Int64;
      AFlags: LongWord; const ABaseName: string): Int64;
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
  end;

function VdbLogNowMs: Int64;
function VdbLogDirOf(const ADbPath: string): string;
{ SQL 'AS OF TIMESTAMP' metnini gunluk zamanina (UTC unix ms) cevirir.
  Kabul: 'YYYY-MM-DD' | 'YYYY-MM-DD HH:MM' | 'YYYY-MM-DD HH:MM:SS[.mmm]'
  Ayirici olarak 'T' de olabilir, sonda 'Z' yok sayilir. }
function VdbLogParseTimestamp(const S: string; out Ms: Int64): Boolean;
{ Gunluk zamanini okunabilir yerel metne cevirir (hata mesajlari icin). }
function VdbLogFormatTimestamp(Ms: Int64): string;
{ v2 sozdiziminden gelen "duvar saati" epoch'unu (NowUnixMS kurali) GERCEK
  UTC epoch'a cevirir. Yalnizca PITR hedefi olarak kullanilir; hedef tarihteki
  yerel UTC farki (yaz saati dahil) uygulanir. }
function VdbLogWallMsToUtcMs(WallMs: Int64): Int64;

implementation

function ReadOneRecord(S: TFileStream; out E: TVdbLogEntry;
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
  total := 0;
  for i := 0 to FGroup.Count - 1 do
    total := total + VDBLOG_REC_HDR + 4 +
      RecPayloadLen(FGroup[i].OldVal, FGroup[i].NewVal);
  total := total + VDBLOG_REC_HDR + 4 + 4;   // END + sayi
  SetLength(all, total);
  pos := 0;
  for i := 0 to FGroup.Count - 1 do
  begin
    payload := TakePayload(FGroup[i].Kind, FGroup[i].OldVal, FGroup[i].NewVal);
    rec := BuildRec(VDBLOG_MAGIC_REC, FGroup[i].Kind, seq, ts,
      FGroup[i].TableId, FGroup[i].Key, payload);
    Move(rec[0], all[pos], Length(rec));
    pos := pos + Length(rec);
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
    FSeg.WriteBuffer(all[0], total);
    VDbFlushStream(FSeg);
    if FSeg.Size >= FSegMax then
      OpenNewSeg(FSegNo + 1);
  except
    on E: Exception do
    begin
      FError := 'degisim gunlugu yazilamadi: ' + E.Message;
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
function ReadOneRecord(S: TFileStream; out E: TVdbLogEntry;
  out AIsEnd: Boolean; out EndCount: LongWord): Boolean;
var
  hdr, payload, all: TBytes;
  rl, oldLen, newLen, nb: Integer;
  crcCalc, crcStored: LongWord;
begin
  Result := False;
  AIsEnd := False;
  EndCount := 0;
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

function TVdbLogReader.ListBases: TVdbLogBaseArray;
var
  i, n: Integer;
  S: TFileStream;
  hdr: TBytes;
  E: TVdbLogEntry;
  b: TVdbLogBase;
  isEnd: Boolean;
  cnt: LongWord;
begin
  Result := nil;
  n := 0;
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
        if isEnd then Continue;
        if E.Kind <> VDBLOG_KIND_BASE then Continue;
        b.Seq := E.Seq;
        b.TsMs := E.TsMs;
        b.Gen := E.Gen;
        b.DbLsn := E.DbLsn;
        b.DbBytes := E.DbBytes;
        b.Name := E.BaseName;
        b.Flags := E.Flags;
        SetLength(Result, n + 1);
        Result[n] := b;
        Inc(n);
      end;
    finally
      S.Free;
    end;
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

end.
