unit VDbSpill;
{ SKILL11: gecici (spill) dosya altyapisi - saf Pascal, harici bagimlilik yok.

  Neden ayri birim: bellek butcesi asildiginda ara sonuclar diske tasinir.
  Bu dosyalar KULLANICI VERITABANI DEGILDIR ve kalici indekslerle
  (`vdbidx_*.dix`) karistirilmamalidir:
    - Kok dizin: `%TEMP%/vdbspill_*` (test icin `VDB_SPILL_DIR` ile
      degistirilebilir). Kullanici DB'sinin yaninda dosya BIRAKILMAZ.
    - Uzanti `.vspill`, ilk baytlari `VDBSPL1` imzasidir.
    - `manifest.txt` hangi DB icin, hangi pid ile, hangi kosu dosyalarinin
      yazildigini kaydeder. Boylece surec coktugunde (Close/Destroy
      calismadan) geride kalan dizin, bir SONRAKI acilista sahibi pid'in
      olu oldugu gorulerek silinir.
    - Canli baska bir surece ait dizin ASLA silinmez (pid canliysa veya
      canliligi belirlenemiyorsa dokunulmaz).

  Kayit bicimi (kucuk-endian, imza disinda):
    'VDBSPL1' | Int32 surum(=1) | Int32 alan sayisi
    satir:    Byte maskVarMi (0/1) | alanlar sirayla:
              Int32 uzunluk (-1 = SQL NULL) + uzunluk bayt
    Boylece NULL semantigi kaynakla AYNIDIR: acik NULL korunur, maskesi
    olmayan satirda `''` yine "bilinmiyor" olarak kalir. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbTypes, VDbTable
  {$IFDEF WINDOWS}, Windows {$ENDIF}
  {$IFDEF UNIX}, BaseUnix, Errors {$ENDIF};

const
  VDBSPILL_MAGIC: array[0..6] of AnsiChar = ('V', 'D', 'B', 'S', 'P', 'L', '1');
  VDBSPILL_VER        = 1;
  VDBSPILL_EXT        = '.vspill';
  VDBSPILL_MANIFEST   = 'manifest.txt';
  VDBSPILL_DIR_PREFIX = 'vdbspill_';
  VDBSPILL_BUF        = 65536;

type
  { Satir karsilastiricisi: A/B, cagiranin tuttugu matris icindeki INDEKS.
    Boylece motorun kendi karsilastiricisi (VdbSortCompareRows) dogrudan
    kullanilir ve siralama semantigi kopyalanmaz. }
  TVdbSpillIdxCmp = function(A, B: Integer): Integer of object;

  { Istatistikler: kapi kaniti (ayni surecte toplanir). }
  TVdbSpillStats = record
    RunsWritten: Int64;
    BytesWritten: Int64;
    RowsWritten: Int64;
    RowsRead: Int64;
    OrphansRemoved: Integer;
    DirsCreated: Integer;
  end;

var
  VdbSpillStats: TVdbSpillStats;
  { Bos degilse kok dizin olarak bu kullanilir (testler icin). Uretimde
    bos birakilir; o zaman `VDB_SPILL_DIR`, yoksa sistem gecici dizini. }
  VdbSpillRootOverride: string = '';
  { 0 = varsayilan butce. Testler dusurerek kosu sayisini kanitlar. }
  VdbSpillBudgetOverride: Int64 = 0;

procedure VdbSpillResetStats;
function VdbSpillRoot: string;
function VdbSpillPid: Cardinal;
function VdbSpillPidAlive(APid: Cardinal): Boolean;
procedure VdbDeleteTree(const ADir: string);
{ Dis siralama parca butcesi (bayt). Varsayilan 8 MiB; testler
  `VdbSpillBudgetOverride` ile dusurebilir. Butce SATIR degil BAYT
  cinsindendir. }
function VdbSpillExtSortBudget: Int64;

type
  { Bir DB oturumu icin spill dizini. Sahibi islem kapanirken kendi kosu
    dosyalarini, manifesti ve dizini siler. }
  TVdbSpillDir = class
  private
    FDir: string;
    FDbPath: string;
    FRuns: TStrArray;      // dizin ici dosya adlari (yol degil)
    FNextRun: Integer;
    FClosed: Boolean;
    procedure SaveManifest;
  public
    constructor Create(const ADbPath: string);
    destructor Destroy; override;
    function NewRunPath: string;
    procedure DropFile(const APath: string);
    procedure Close;
    property Dir: string read FDir;
    property DbPath: string read FDbPath;
  end;

  { Kosu dosyasi yazici: tamponlu, satir satir. }
  TVdbSpillWriter = class
  private
    FPath: string;
    FFS: TFileStream;
    FBuf: TBytes;
    FBufLen: Integer;
    FFields: Integer;
    FRows: Int64;
    FBytes: Int64;
    procedure Flush;
    procedure PutRaw(const P; N: Integer);
    procedure PutI32(V: Int32);
  public
    constructor Create(const APath: string; AFieldCount: Integer);
    destructor Destroy; override;
    procedure WriteRow(const Row: TStrArray; const Nulls: TNulArr = nil);
    procedure Finish;
    property Rows: Int64 read FRows;
    property Bytes: Int64 read FBytes;
    property Path: string read FPath;
  end;

  { Kosu dosyasi okuyucu: pencere tamponu, satir satir. }
  TVdbSpillReader = class
  private
    FPath: string;
    FFS: TFileStream;
    FWin: TBytes;
    FWinPos: Integer;
    FWinLen: Integer;
    FFields: Integer;
    FRows: Int64;
    function Fill: Boolean;
    function TakeRaw(var Dst; N: Integer): Boolean;
    function TakeI32(out V: Int32): Boolean;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    function Next(out Row: TStrArray; out Nulls: TNulArr): Boolean;
    property Rows: Int64 read FRows;
    property Path: string read FPath;
    property FieldCount: Integer read FFields;
  end;

  { K-yollu birlestirme: her kosudan bir "kafa" satiri tutar, en kucugu
    verir. Bellek O(k) satirdir; satir sayisiyla buyumez. }
  TVdbSpillMerger = class
  private
    FReaders: array of TVdbSpillReader;
    FHeads: TStrMatrix;
    FHeadNulls: TNullMatrix;
    FHas: array of Boolean;
    FHeap: array of Integer;
    FHeapN: Integer;
    FCmp: TVdbSpillIdxCmp;
    FReady: Boolean;
    FCount: Integer;
    procedure Build;
    procedure Sift(Pos: Integer);
  public
    constructor Create(const APaths: TStrArray);
    destructor Destroy; override;
    function Next(out Row: TStrArray; out Nulls: TNulArr): Boolean;
    function RowCount: Int64;
    { Birlestiricinin SU AN tuttugu bellek: her okuyucunun pencere
      tamponu + kafa satirlari + yigin. SKILL11 D: birlestirme bellegi de
      butceye sayilir; kosu sayisiyla buyur, satir sayisiyla degil. }
    function MemBytes: Int64;
    { Karsilastirici FHeads uzerinde A/B indeksleriyle cagrilir. }
    property Heads: TStrMatrix read FHeads;
    property HeadNulls: TNullMatrix read FHeadNulls;
    property Cmp: TVdbSpillIdxCmp read FCmp write FCmp;
    property ReaderCount: Integer read FCount;
  end;

{ Kararli (stable) satir siralamasi: esit anahtarlarda GIRIS SIRASI korunur.
  Boylece parca-parca siralama + birlestirme, tek seferde siralamayla AYNI
  toplam sonucu verir (esitlikler dahil). }
procedure VdbSpillStableSortRows(var Rows: TStrMatrix; var Nulls: TNullMatrix;
  const Cmp: TVdbSpillIdxCmp);

{ Bir satirin bellekte kapladigi GERCEK bayt (metin + dizi kapasitesi +
  isaretci). SKILL11 bolum D: yalniz hucre metni sayilmaz. }
function VdbSpillRowBytes(const Row: TStrArray): Int64;
function VdbSpillMatrixBytes(const Rows: TStrMatrix): Int64;

implementation

procedure VdbSpillResetStats;
begin
  VdbSpillStats := Default(TVdbSpillStats);
end;

function VdbSpillRoot: string;
var
  s: string;
begin
  if VdbSpillRootOverride <> '' then
    Exit(IncludeTrailingPathDelimiter(VdbSpillRootOverride));
  s := SysUtils.GetEnvironmentVariable('VDB_SPILL_DIR');
  if s = '' then s := GetTempDir;
  Result := IncludeTrailingPathDelimiter(s);
end;

function VdbSpillPid: Cardinal;
begin
  {$IFDEF WINDOWS}
  Result := GetCurrentProcessId;
  {$ELSE}
  Result := Cardinal(fpGetPid);
  {$ENDIF}
end;

function VdbSpillPidAlive(APid: Cardinal): Boolean;
var
  err: Integer;
  {$IFDEF WINDOWS}
  h: THandle;
  {$ENDIF}
begin
  Result := False;
  if APid = 0 then Exit;
  {$IFDEF WINDOWS}
  h := OpenProcess(SYNCHRONIZE, False, APid);
  if h = 0 then
  begin
    { Erisim reddedildiyse surec VARDIR (baska kullanici/oturum). }
    err := GetLastError;
    Exit(err = 5);
  end;
  try
    Result := WaitForSingleObject(h, 0) = WAIT_TIMEOUT;
  finally
    CloseHandle(h);
  end;
  {$ELSE}
  if fpKill(APid, 0) = 0 then Exit(True);
  err := fpGetErrno;
  { EPERM: surec var ama sinyal gonderemiyoruz -> canli say. }
  Result := (err = ESysEPERM);
  {$ENDIF}
end;

function VdbSpillExtSortBudget: Int64;
begin
  if VdbSpillBudgetOverride > 0 then
    Result := VdbSpillBudgetOverride
  else
    Result := 8 * 1024 * 1024;
end;

procedure VdbDeleteTree(const ADir: string);
var
  sr: TSearchRec;
  p: string;
begin
  if ADir = '' then Exit;
  p := IncludeTrailingPathDelimiter(ADir);
  if SysUtils.FindFirst(p + '*', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if (sr.Attr and faDirectory) <> 0 then
          VdbDeleteTree(p + sr.Name)
        else
          SysUtils.DeleteFile(p + sr.Name);
      until SysUtils.FindNext(sr) <> 0;
    finally
      SysUtils.FindClose(sr);
    end;
  end;
  RemoveDir(ADir);
end;

{ Manifest icinden "ANAHTAR<TAB>deger" satirinin degerini alir. }
function VdbManifestValue(const AKey, AText: string): string;
var
  p, q: Integer;
  line: string;
begin
  Result := '';
  p := 1;
  while p <= Length(AText) do
  begin
    q := p;
    while (q <= Length(AText)) and (AText[q] <> #10) do Inc(q);
    line := Copy(AText, p, q - p);
    if line <> '' then
    begin
      if line[Length(line)] = #13 then
        Delete(line, Length(line), 1);
      if Copy(line, 1, Length(AKey) + 1) = AKey + #9 then
        Exit(Copy(line, Length(AKey) + 2, MaxInt));
    end;
    p := q + 1;
  end;
end;

{ ---------------- TVdbSpillDir ---------------- }

constructor TVdbSpillDir.Create(const ADbPath: string);
var
  root, tag, nm, mp: string;
  sr: TSearchRec;
  sl: TStringList;
  dbLine, pidLine: string;
  opid: Cardinal;
  i, tries: Integer;
  h: Cardinal;
begin
  inherited Create;
  FDbPath := ADbPath;
  FNextRun := 0;
  FClosed := False;
  FRuns := nil;

  { Dizin adi: DB yolunun FNV-1a karmasi + pid + saat. Ayni anda calisan
    iki imlec bile ayri dizin kullanir. }
  h := 2166136261;
  for i := 1 to Length(ADbPath) do
  begin
    h := h xor Cardinal(Ord(ADbPath[i]));
    h := h * 16777619;
  end;
  tag := IntToHex(h, 8);
  FDir := VdbSpillRoot + VDBSPILL_DIR_PREFIX + tag + '_' +
    IntToStr(VdbSpillPid) + '_' + IntToStr(Int64(Trunc(Now * 86400000.0)) and $FFFFFF);

  { 1) Ayni DB icin OLU sahipli artik dizinleri topla. }
  root := VdbSpillRoot;
  if SysUtils.FindFirst(root + VDBSPILL_DIR_PREFIX + '*', faDirectory, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if (sr.Attr and faDirectory) = 0 then Continue;
        nm := ExcludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(root + sr.Name));
        if SameText(nm, ExcludeTrailingPathDelimiter(FDir)) then Continue;
        mp := IncludeTrailingPathDelimiter(nm) + VDBSPILL_MANIFEST;
        if not FileExists(mp) then
          { Manifest yok: yarim kalmis dizin, sahibi bilinmiyor -> SILINMEZ
            (baska canli surec yaziyor olabilir). }
          Continue;
        sl := TStringList.Create;
        try
          try
            sl.LoadFromFile(mp);
          except
            Continue;
          end;
          dbLine := VdbManifestValue('DB', sl.Text);
          pidLine := VdbManifestValue('PID', sl.Text);
          if (dbLine = '') or (dbLine <> FDbPath) then Continue;
          opid := Cardinal(StrToInt64Def(pidLine, 0));
          if (opid <> 0) and (opid <> VdbSpillPid) and
             (not VdbSpillPidAlive(opid)) then
          begin
            VdbDeleteTree(nm);
            Inc(VdbSpillStats.OrphansRemoved);
          end;
        finally
          sl.Free;
        end;
      until SysUtils.FindNext(sr) <> 0;
    finally
      SysUtils.FindClose(sr);
    end;
  end;

  { 2) Kendi dizinimizi ac. Ad cakismasi olursa sonuna sayac ekle. }
  tries := 0;
  while DirectoryExists(FDir) do
  begin
    Inc(tries);
    FDir := FDir + '_' + IntToStr(tries);
  end;
  if not ForceDirectories(FDir) then
    raise Exception.Create('spill dizini olusturulamadi: ' + FDir);
  Inc(VdbSpillStats.DirsCreated);
  SaveManifest;
end;

destructor TVdbSpillDir.Destroy;
begin
  try
    Close;
  except
    { Temizlik hatasi cagiranin sorgusunu bozmaz; artik dizin bir sonraki
      acilista pid olu oldugu icin toplanir. }
  end;
  inherited;
end;

procedure TVdbSpillDir.SaveManifest;
var
  sl: TStringList;
  i: Integer;
begin
  sl := TStringList.Create;
  try
    sl.LineBreak := #10;
    sl.Add('DB' + #9 + FDbPath);
    sl.Add('PID' + #9 + IntToStr(VdbSpillPid));
    sl.Add('VER' + #9 + IntToStr(VDBSPILL_VER));
    for i := 0 to High(FRuns) do
      sl.Add('RUN' + #9 + FRuns[i]);
    sl.SaveToFile(IncludeTrailingPathDelimiter(FDir) + VDBSPILL_MANIFEST);
  finally
    sl.Free;
  end;
end;

function TVdbSpillDir.NewRunPath: string;
var
  nm: string;
begin
  repeat
    nm := 'run' + IntToStr(FNextRun) + VDBSPILL_EXT;
    Inc(FNextRun);
  until not FileExists(IncludeTrailingPathDelimiter(FDir) + nm);
  SetLength(FRuns, Length(FRuns) + 1);
  FRuns[High(FRuns)] := nm;
  SaveManifest;
  Result := IncludeTrailingPathDelimiter(FDir) + nm;
end;

procedure TVdbSpillDir.DropFile(const APath: string);
var
  nm: string;
  i, j: Integer;
begin
  nm := ExtractFileName(APath);
  try
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(FDir) + nm);
  except
  end;
  j := 0;
  for i := 0 to High(FRuns) do
    if FRuns[i] <> nm then
    begin
      FRuns[j] := FRuns[i];
      Inc(j);
    end;
  if j <> Length(FRuns) then SetLength(FRuns, j);
  SaveManifest;
end;

procedure TVdbSpillDir.Close;
var
  i: Integer;
begin
  if FClosed then Exit;
  FClosed := True;
  for i := 0 to High(FRuns) do
    try
      SysUtils.DeleteFile(IncludeTrailingPathDelimiter(FDir) + FRuns[i]);
    except
    end;
  FRuns := nil;
  try
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(FDir) + VDBSPILL_MANIFEST);
  except
  end;
  RemoveDir(ExcludeTrailingPathDelimiter(FDir));
end;

{ ---------------- TVdbSpillWriter ---------------- }

constructor TVdbSpillWriter.Create(const APath: string; AFieldCount: Integer);
var
  hdr: array[0..10] of Byte;
begin
  inherited Create;
  FPath := APath;
  FFields := AFieldCount;
  FRows := 0;
  FBytes := 0;
  SetLength(FBuf, VDBSPILL_BUF);
  FBufLen := 0;
  FFS := TFileStream.Create(APath, fmCreate);
  hdr[0] := Ord('V'); hdr[1] := Ord('D'); hdr[2] := Ord('B');
  hdr[3] := Ord('S'); hdr[4] := Ord('P'); hdr[5] := Ord('L');
  hdr[6] := Ord('1');
  hdr[7] := VDBSPILL_VER;
  hdr[8] := Byte((Cardinal(AFieldCount) shr 0) and $FF);
  hdr[9] := Byte((Cardinal(AFieldCount) shr 8) and $FF);
  hdr[10] := Byte((Cardinal(AFieldCount) shr 16) and $FF);
  { 11. bayt (alan sayisinin 4. bayti) 0 kabul edilir; alan sayisi 16M'i
    gecemez, bu yuzden 1 bayt yeterli olacakti. Basligi 11 bayt tutuyoruz. }
  PutRaw(hdr, SizeOf(hdr));
  Inc(VdbSpillStats.RunsWritten);
end;

destructor TVdbSpillWriter.Destroy;
begin
  try
    Finish;
  except
  end;
  FreeAndNil(FFS);
  inherited;
end;

procedure TVdbSpillWriter.PutRaw(const P; N: Integer);
var
  pb: PByte;
  avail: Integer;
begin
  if N <= 0 then Exit;
  pb := @P;
  while N > 0 do
  begin
    if FBufLen >= Length(FBuf) then Flush;
    avail := Length(FBuf) - FBufLen;
    if avail > N then avail := N;
    Move(pb^, FBuf[FBufLen], avail);
    Inc(FBufLen, avail);
    Inc(pb, avail);
    Dec(N, avail);
  end;
end;

procedure TVdbSpillWriter.PutI32(V: Int32);
var
  b: array[0..3] of Byte;
begin
  b[0] := Byte(Cardinal(V) and $FF);
  b[1] := Byte((Cardinal(V) shr 8) and $FF);
  b[2] := Byte((Cardinal(V) shr 16) and $FF);
  b[3] := Byte((Cardinal(V) shr 24) and $FF);
  PutRaw(b, 4);
end;

procedure TVdbSpillWriter.Flush;
begin
  if (FFS <> nil) and (FBufLen > 0) then
  begin
    FFS.WriteBuffer(FBuf[0], FBufLen);
    Inc(FBytes, FBufLen);
    FBufLen := 0;
  end;
end;

procedure TVdbSpillWriter.WriteRow(const Row: TStrArray; const Nulls: TNulArr);
var
  i, n: Integer;
  hasMask: Byte;
  p: PAnsiChar;
begin
  if FFS = nil then raise Exception.Create('spill yazici kapali');
  hasMask := 0;
  if Length(Nulls) > 0 then hasMask := 1;
  PutRaw(hasMask, 1);
  for i := 0 to FFields - 1 do
  begin
    if i > High(Row) then
    begin
      PutI32(0);
      Continue;
    end;
    if (hasMask = 1) and (i <= High(Nulls)) and Nulls[i] then
      PutI32(-1)
    else
    begin
      n := Length(Row[i]);
      PutI32(Int32(n));
      if n > 0 then
      begin
        p := PAnsiChar(Row[i]);
        PutRaw(p^, n);
      end;
    end;
  end;
  Inc(FRows);
  Inc(VdbSpillStats.RowsWritten);
end;

procedure TVdbSpillWriter.Finish;
begin
  if FFS = nil then Exit;
  Flush;
  FreeAndNil(FFS);
  Inc(VdbSpillStats.BytesWritten, FBytes);
end;

{ ---------------- TVdbSpillReader ---------------- }

constructor TVdbSpillReader.Create(const APath: string);
var
  hdr: array[0..10] of Byte;
  i: Integer;
  ver, nf: Cardinal;
begin
  inherited Create;
  FPath := APath;
  FWinPos := 0;
  FWinLen := 0;
  FRows := 0;
  SetLength(FWin, VDBSPILL_BUF);
  FFS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if FFS.Read(hdr, SizeOf(hdr)) <> SizeOf(hdr) then
      raise Exception.Create('spill kosusu bozuk (baslik): ' + APath);
    for i := 0 to 6 do
      if AnsiChar(hdr[i]) <> VDBSPILL_MAGIC[i] then
        raise Exception.Create('spill kosusu imzasi gecersiz: ' + APath);
    ver := Cardinal(hdr[7]);
    if ver <> VDBSPILL_VER then
      raise Exception.Create('spill surumu desteklenmiyor: ' + APath);
    nf := Cardinal(hdr[8]) or (Cardinal(hdr[9]) shl 8) or
      (Cardinal(hdr[10]) shl 16);
    FFields := Integer(nf);
    if FFields > 100000 then
      raise Exception.Create('spill alan sayisi gecersiz: ' + APath);
  except
    FreeAndNil(FFS);
    raise;
  end;
end;

destructor TVdbSpillReader.Destroy;
begin
  FreeAndNil(FFS);
  inherited;
end;

function TVdbSpillReader.Fill: Boolean;
begin
  if FFS = nil then Exit(False);
  FWinLen := FFS.Read(FWin[0], Length(FWin));
  FWinPos := 0;
  Result := FWinLen > 0;
end;

function TVdbSpillReader.TakeRaw(var Dst; N: Integer): Boolean;
var
  pb: PByte;
  avail: Integer;
begin
  pb := @Dst;
  while N > 0 do
  begin
    if FWinPos >= FWinLen then
      if not Fill then Exit(False);
    avail := FWinLen - FWinPos;
    if avail > N then avail := N;
    Move(FWin[FWinPos], pb^, avail);
    Inc(FWinPos, avail);
    Inc(pb, avail);
    Dec(N, avail);
  end;
  Result := True;
end;

function TVdbSpillReader.TakeI32(out V: Int32): Boolean;
var
  b: array[0..3] of Byte;
begin
  Result := TakeRaw(b, 4);
  if not Result then Exit;
  V := Int32(Cardinal(b[0]) or (Cardinal(b[1]) shl 8) or
    (Cardinal(b[2]) shl 16) or (Cardinal(b[3]) shl 24));
end;

function TVdbSpillReader.Next(out Row: TStrArray; out Nulls: TNulArr): Boolean;
var
  hasMask: Byte;
  i, n: Integer;
  v: Int32;
  s: string;
begin
  Row := nil;
  Nulls := nil;
  Result := False;
  if FFS = nil then Exit;
  if not TakeRaw(hasMask, 1) then Exit;   // satir basi okunamadi = EOF
  SetLength(Row, FFields);
  if hasMask = 1 then SetLength(Nulls, FFields);
  for i := 0 to FFields - 1 do
  begin
    if not TakeI32(v) then
      raise Exception.Create('spill kosusu yarim kaldi: ' + FPath);
    if v = -1 then
    begin
      Row[i] := '';
      if Length(Nulls) = 0 then SetLength(Nulls, FFields);
      Nulls[i] := True;
    end
    else
    begin
      n := v;
      if n < 0 then raise Exception.Create('spill uzunlugu gecersiz: ' + FPath);
      if n > 0 then
      begin
        SetLength(s, n);
        if not TakeRaw(PAnsiChar(s)^, n) then
          raise Exception.Create('spill kosusu yarim kaldi: ' + FPath);
      end
      else
        s := '';
      Row[i] := s;
      if Length(Nulls) > 0 then Nulls[i] := False;
    end;
  end;
  Inc(FRows);
  Inc(VdbSpillStats.RowsRead);
  Result := True;
end;

{ ---------------- TVdbSpillMerger ---------------- }

constructor TVdbSpillMerger.Create(const APaths: TStrArray);
var
  i: Integer;
begin
  inherited Create;
  FCount := Length(APaths);
  SetLength(FReaders, FCount);
  SetLength(FHeads, FCount);
  SetLength(FHeadNulls, FCount);
  SetLength(FHas, FCount);
  SetLength(FHeap, FCount);
  FHeapN := 0;
  FReady := False;
  for i := 0 to FCount - 1 do
  begin
    FReaders[i] := TVdbSpillReader.Create(APaths[i]);
    FHas[i] := FReaders[i].Next(FHeads[i], FHeadNulls[i]);
  end;
end;

destructor TVdbSpillMerger.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FReaders) do
    FreeAndNil(FReaders[i]);
  inherited;
end;

procedure TVdbSpillMerger.Sift(Pos: Integer);
var
  l, r, best, t: Integer;
  c: Integer;
  mcmp: TVdbSpillIdxCmp;
begin
  mcmp := FCmp;
  while True do
  begin
    l := 2 * Pos + 1;
    r := l + 1;
    best := Pos;
    if l < FHeapN then
    begin
      c := 0;
      if Assigned(mcmp) then c := mcmp(FHeap[l], FHeap[best]);
      if (c < 0) or ((c = 0) and (FHeap[l] < FHeap[best])) then best := l;
    end;
    if r < FHeapN then
    begin
      c := 0;
      if Assigned(mcmp) then c := mcmp(FHeap[r], FHeap[best]);
      if (c < 0) or ((c = 0) and (FHeap[r] < FHeap[best])) then best := r;
    end;
    if best = Pos then Break;
    t := FHeap[Pos];
    FHeap[Pos] := FHeap[best];
    FHeap[best] := t;
    Pos := best;
  end;
end;

procedure TVdbSpillMerger.Build;
var
  i: Integer;
begin
  FHeapN := 0;
  for i := 0 to FCount - 1 do
    if FHas[i] then
    begin
      FHeap[FHeapN] := i;
      Inc(FHeapN);
    end;
  i := (FHeapN div 2) - 1;
  while i >= 0 do
  begin
    Sift(i);
    Dec(i);
  end;
  FReady := True;
end;

function TVdbSpillMerger.Next(out Row: TStrArray; out Nulls: TNulArr): Boolean;
var
  top: Integer;
  hRow: TStrArray;
  hNulls: TNulArr;
begin
  Row := nil;
  Nulls := nil;
  Result := False;
  if not FReady then Build;
  if FHeapN = 0 then Exit;
  top := FHeap[0];
  Row := FHeads[top];
  Nulls := FHeadNulls[top];
  FHas[top] := FReaders[top].Next(hRow, hNulls);
  if FHas[top] then
  begin
    FHeads[top] := hRow;
    FHeadNulls[top] := hNulls;
  end
  else
  begin
    FHeads[top] := nil;
    FHeadNulls[top] := nil;
    Dec(FHeapN);
    FHeap[0] := FHeap[FHeapN];
  end;
  if FHeapN > 0 then Sift(0);
  Result := True;
end;

function TVdbSpillMerger.RowCount: Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FReaders) do
    if FReaders[i] <> nil then Inc(Result, FReaders[i].Rows);
end;

function TVdbSpillMerger.MemBytes: Int64;
var
  i: Integer;
begin
  { Okuyucu basina bir VDBSPILL_BUF penceresi + kafa satirlari + yigin. }
  Result := Int64(Length(FReaders)) * VDBSPILL_BUF;
  Inc(Result, VdbSpillMatrixBytes(FHeads));
  Inc(Result, Int64(Length(FHeap) + Length(FHas)) * SizeOf(Integer));
  for i := 0 to High(FReaders) do
    Inc(Result, 256);   { okuyucu nesnesi + dosya tanitici payi }
end;

{ ---------------- siralamalar / bayt hesabi ---------------- }

procedure VdbSpillStableSortRows(var Rows: TStrMatrix; var Nulls: TNullMatrix;
  const Cmp: TVdbSpillIdxCmp);
var
  n, i, w, lo, mid, hi, a, b, k: Integer;
  idx, tmp, sw: TIntArray;
  nRows: TStrMatrix;
  nNulls: TNullMatrix;
  hasNulls: Boolean;
begin
  n := Length(Rows);
  if n < 2 then Exit;
  hasNulls := Length(Nulls) > 0;
  SetLength(idx, n);
  SetLength(tmp, n);
  for i := 0 to n - 1 do idx[i] := i;
  w := 1;
  while w < n do
  begin
    lo := 0;
    while lo < n do
    begin
      mid := lo + w;
      if mid > n then mid := n;
      hi := lo + 2 * w;
      if hi > n then hi := n;
      a := lo;
      b := mid;
      k := lo;
      while (a < mid) and (b < hi) do
      begin
        { <= : esitlikte once gelen korunur (stable). }
        if Cmp(idx[a], idx[b]) <= 0 then
        begin
          tmp[k] := idx[a];
          Inc(a);
        end
        else
        begin
          tmp[k] := idx[b];
          Inc(b);
        end;
        Inc(k);
      end;
      while a < mid do
      begin
        tmp[k] := idx[a];
        Inc(a);
        Inc(k);
      end;
      while b < hi do
      begin
        tmp[k] := idx[b];
        Inc(b);
        Inc(k);
      end;
      lo := lo + 2 * w;
    end;
    sw := idx;
    idx := tmp;
    tmp := sw;
    w := w * 2;
  end;
  SetLength(nRows, n);
  if hasNulls then SetLength(nNulls, n);
  for i := 0 to n - 1 do
  begin
    nRows[i] := Rows[idx[i]];
    if hasNulls then nNulls[i] := Nulls[idx[i]];
  end;
  Rows := nRows;
  if hasNulls then Nulls := nNulls;
end;

function VdbSpillRowBytes(const Row: TStrArray): Int64;
var
  i: Integer;
begin
  { Dizi basligi + eleman basina isaretci (FPC AnsiString elemani =
    pointer) + metin govdesi + StrRec basligi. SKILL11 D: yalniz metin
    degil, kapasite/isaretci de sayilir. }
  Result := 32 + Int64(Length(Row)) * SizeOf(Pointer);
  for i := 0 to High(Row) do
    Inc(Result, Int64(Length(Row[i])) + 16);
end;

function VdbSpillMatrixBytes(const Rows: TStrMatrix): Int64;
var
  i: Integer;
begin
  Result := 32 + Int64(Length(Rows)) * SizeOf(Pointer);
  for i := 0 to High(Rows) do
    Inc(Result, VdbSpillRowBytes(Rows[i]));
end;

end.
