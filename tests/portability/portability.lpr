program portability;
{ VDB V3 sertlestirme - SKILL2 §26.3 kapisi: PLATFORMLAR ARASI DOSYA TASIMA.

Amac: `.odb` dosyasinin isletim sistemine, derleyiciye, isaretci boyuna ya da
yapisal dolguya (padding) bagimli OLMADIGINI kanitlamak.

Iki mod:
  --write <dir> : <dir>/veritabani.odb kurar (deterministik veri) ve
                  <dir>/manifest.txt yazar (satir sayisi, icerik ozeti,
                  dosya boyu, dosya FNV-1a ozeti).
  --read  <dir> : manifest.txt'i okur, veritabanini SALT-OKUNUR acar,
                  satir sayisini ve icerik ozetini dogrular, VERIFY calistirir
                  ve dosyanin DEGISMEDIGINI (FNV-1a ayni) kanitlar.
                  Cikis kodu = basarisiz kontrol sayisi.
  (argumansiz)  : ayni platformda yaz/oku turu + bicim duzeyi kontrolleri.

Neden iki mod: dosya bir platformda yazilip DIGERINDE okunabilsin diye.
`--write <paylasilan dizin>` bir platformda kosar, `--read <ayni dizin>` diger
platformda; manifest metin dosyasidir (platformdan bagimsiz).

Durust sinirlar:
  - Bu kapi ENDIANNESS'i yalnizca pratikte sinar: x86_64 Linux (kucuk-endian)
    <-> i386 Windows (kucuk-endian). Buyuk-endian bir makinede kosulmadi;
    kalici yapi `Move` + sabit ofset ile yazildigi icin buyuk-endian'da
    okunmayacaktir (bkz. STORAGE_AUDIT.md §11).
  - macOS denenmedi (elde macOS makinesi yok).

Derleme: fpc (lpi gerektirmez).
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageStore,
  VDbPage, VDbCrc32, VDbTable, VDbSql, VDbErr;

const
  ROWS = 400;
  DB_NAME = 'veritabani.odb';
  MANIFEST = 'manifest.txt';

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
  Flush(Output);
end;

procedure ResetCounters;
begin
  GPass := 0;
  GFail := 0;
end;

procedure Summary;
begin
  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
end;

procedure Info(const S: string);
begin
  WriteLn('BILGI ', S);
  Flush(Output);
end;

function Has(const AHaystack, ANeedle: string): Boolean;
begin
  Result := Pos(ANeedle, AHaystack) > 0;
end;

function MkVal(AKey: Integer): string;
var
  i: Integer;
begin
  SetLength(Result, 40);
  for i := 1 to Length(Result) do
    Result[i] := Chr(Ord('a') + ((AKey + i) mod 26));
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
  d: string;
begin
  d := IncludeTrailingPathDelimiter(ADir);
  ForceDirectories(d);
  if FindFirst(d + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(d + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ ---------------------------------------------------------------- dosya }

function FileHash(const APath: string): string;
var
  fs: TFileStream;
  buf: array[0..8191] of Byte;
  n, i: Integer;
  h: QWord;
begin
  h := QWord(14695981039346656037);
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    repeat
      n := fs.Read(buf, SizeOf(buf));
      for i := 0 to n - 1 do
      begin
        h := h xor QWord(buf[i]);
        h := h * QWord(1099511628211);
      end;
    until n <= 0;
  finally
    fs.Free;
  end;
  Result := IntToHex(h, 16);
end;

function FileLen(const APath: string): Int64;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

function ReadDWordAt(const APath: string; AOffset: Int64): LongWord;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    fs.Position := AOffset;
    fs.ReadBuffer(Result, SizeOf(Result));
  finally
    fs.Free;
  end;
end;

function ReadWordAt(const APath: string; AOffset: Int64): Word;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    fs.Position := AOffset;
    fs.ReadBuffer(Result, SizeOf(Result));
  finally
    fs.Free;
  end;
end;

{ Platformdan bagimsiz kopya (SysUtils.CopyFile her hedefte yok). }
function CopyDb(const ASrc, ADst: string): Boolean;
var
  a, b: TFileStream;
begin
  Result := False;
  a := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    b := TFileStream.Create(ADst, fmCreate);
    try
      b.CopyFrom(a, 0);
      Result := True;
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

{ ATag'in dosyadaki ilk konumu (0 tabanli ofset). }
function FindBytes(const APath: string; const ATag: AnsiString;
  out AOfs: Int64): Boolean;
var
  fs: TFileStream;
  buf: array[0..8191] of Byte;
  n, i, j, m: Integer;
  ofs: Int64;
begin
  Result := False;
  AOfs := -1;
  m := Length(ATag);
  if m = 0 then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    ofs := 0;
    repeat
      n := fs.Read(buf, SizeOf(buf));
      if n >= m then
        for i := 0 to n - m do
        begin
          j := 1;
          while (j <= m) and (buf[i + j - 1] = Byte(ATag[j])) do
            Inc(j);
          if j > m then
          begin
            AOfs := ofs + i;
            Exit(True);
          end;
        end;
      if n < m then Break;
      { Son m-1 bayt sonraki blokla birlesebilir: biraz geri sar. }
      fs.Position := fs.Position - (m - 1);
      Inc(ofs, n - (m - 1));
    until False;
  finally
    fs.Free;
  end;
end;

{ [AStart, AStart+ALen) araliginda AB bayti var mi? }
function RangeHasByte(const APath: string; AStart, ALen: Int64;
  AB: Byte): Boolean;
var
  fs: TFileStream;
  buf: array[0..8191] of Byte;
  n, i: Integer;
  left: Int64;
begin
  Result := False;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    fs.Position := AStart;
    left := ALen;
    while left > 0 do
    begin
      n := SizeOf(buf);
      if Int64(n) > left then
        n := Integer(left);
      n := fs.Read(buf, n);
      if n <= 0 then Break;
      for i := 0 to n - 1 do
        if buf[i] = AB then
          Exit(True);
      Dec(left, n);
    end;
  finally
    fs.Free;
  end;
end;

{ Imajda "ucucu" sayilan ofsetler: bunlar her veritabaninda farklidir ve
  PLATFORMDAN bagimsiz olarak da farklidir:
    28..35  FCreated  (olusturma zamani)
    76..83  FDbId     (rastgele veritabani kimligi, C-2)
    4092..95 sayfa 0'in CRC'si (ustteki iki alan degistigi icin) }
function IsVolatileOfs(AOfs: Int64): Boolean;
begin
  Result := ((AOfs >= 28) and (AOfs <= 35)) or
            ((AOfs >= 76) and (AOfs <= 83)) or
            ((AOfs >= VDB_PAGE_BODY_END) and (AOfs < VDB_PAGE_SIZE));
end;

{ Iki imaji bayt bayt karsilastirir. ADiffs = farkli bayt sayisi;
  AFirstBad = ucucu OLMAYAN ilk fark ofseti (-1 = yalnizca ucucu alanlar
  farkli). Boylar esit degilse AFirstBad = 0. }
procedure DiffImages(const A, B: string; out ADiffs, AFirstBad: Int64);
var
  fa, fb: TFileStream;
  ba, bb: array[0..8191] of Byte;
  na, nb, i, k: Integer;
  ofs: Int64;
begin
  ADiffs := 0;
  AFirstBad := -1;
  fa := TFileStream.Create(A, fmOpenRead or fmShareDenyNone);
  try
    fb := TFileStream.Create(B, fmOpenRead or fmShareDenyNone);
    try
      if fa.Size <> fb.Size then
      begin
        AFirstBad := 0;
        Exit;
      end;
      ofs := 0;
      repeat
        na := fa.Read(ba, SizeOf(ba));
        nb := fb.Read(bb, SizeOf(bb));
        if na <> nb then
        begin
          AFirstBad := ofs;
          Exit;
        end;
        for i := 0 to na - 1 do
          if ba[i] <> bb[i] then
          begin
            Inc(ADiffs);
            k := i;
            if (AFirstBad < 0) and not IsVolatileOfs(ofs + k) then
              AFirstBad := ofs + k;
          end;
        Inc(ofs, na);
      until na <= 0;
    finally
      fb.Free;
    end;
  finally
    fa.Free;
  end;
end;

{ ---------------------------------------------------------- veri imzasi }

{ Satir iceriginden platformdan bagimsiz bir ozet: her satir icin
  id + '|' + v + '\n' baytlari uzerinden FNV-1a. Ayni veri her platformda
  ayni ozeti vermek ZORUNDA. }
function DataSignature(ADbPath: string; out ARows: Int64;
  out AErr: string): string;
var
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
  i: Integer;
  h: QWord;
  line: AnsiString;

  procedure Feed(const S: string);
  var
    k: Integer;
    b: Byte;
  begin
    line := AnsiString(S);
    for k := 1 to Length(line) do
    begin
      b := Byte(line[k]);
      h := h xor QWord(b);
      h := h * QWord(1099511628211);
    end;
  end;

begin
  Result := '';
  ARows := -1;
  AErr := '';
  BeC := nil;
  Tb := nil;
  Sq := nil;
  h := QWord(14695981039346656037);
  try
    try
      BeC := TVdbBackendV3.CreateReadOnly(ADbPath);
      Be := BeC;
      Tb := TVTableDb.CreateBackend(Be);
      Tb.Open(ExtractFileDir(ADbPath));
      Sq := TVSql.Create(Tb);
      R := Sq.Exec('SELECT id, v FROM t ORDER BY id');
      ARows := Length(R.Rows);
      for i := 0 to Length(R.Rows) - 1 do
      begin
        Feed(R.Rows[i][0]);
        Feed('|');
        Feed(R.Rows[i][1]);
        Feed(#10);
      end;
      Result := IntToHex(h, 16);
    except
      on E: Exception do
      begin
        AErr := E.ClassName + ': ' + E.Message;
        ARows := -1;
      end;
    end;
  finally
    Sq.Free;
    Tb.Free;
    Be := nil;
    BeC := nil;
  end;
end;

{ ---------------------------------------------------------------- yazma }

function CreateDb(const ADir: string; out ADbPath, AErr: string): Boolean;
var
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i: Integer;
begin
  Result := False;
  AErr := '';
  ADbPath := IncludeTrailingPathDelimiter(ADir) + DB_NAME;
  BeC := nil;
  Tb := nil;
  Sq := nil;
  try
    try
      BeC := TVdbBackendV3.Create(ADbPath);
      Be := BeC;
      Tb := TVTableDb.CreateBackend(Be);
      Tb.Open(IncludeTrailingPathDelimiter(ADir));
      Sq := TVSql.Create(Tb);
      Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      for i := 1 to ROWS do
        Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
          MkVal(i) + ''')');
      Sq.Free;
      Sq := nil;
      Tb.Free;
      Tb := nil;
      { Kapanis: temiz kapanis tek dosya birakir; yan dosyalar silinir. }
      Be := nil;
      BeC := nil;
      Result := True;
    except
      on E: Exception do
        AErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    Sq.Free;
    Tb.Free;
    Be := nil;
    BeC := nil;
  end;
end;

procedure WriteManifest(const ADir, ADbPath, ASig: string; ARows: Int64);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Add('format=v3');
    sl.Add('db=' + DB_NAME);
    sl.Add('rows=' + IntToStr(ARows));
    sl.Add('signature=' + ASig);
    sl.Add('bytes=' + IntToStr(FileLen(ADbPath)));
    sl.Add('filehash=' + FileHash(ADbPath));
    sl.SaveToFile(IncludeTrailingPathDelimiter(ADir) + MANIFEST);
  finally
    sl.Free;
  end;
end;

function ReadManifest(const ADir: string; out ARows: Int64;
  out ASig, AHash: string; out ABytes: Int64): Boolean;
var
  sl: TStringList;
  i: Integer;
  s: string;

  function Val(const AName, ADef: string): string;
  var
    k: Integer;
  begin
    Result := ADef;
    for k := 0 to sl.Count - 1 do
      if Copy(sl[k], 1, Length(AName) + 1) = AName + '=' then
        Exit(Copy(sl[k], Length(AName) + 2, Length(sl[k])));
  end;

begin
  Result := False;
  ARows := -1;
  ASig := '';
  AHash := '';
  ABytes := 0;
  s := IncludeTrailingPathDelimiter(ADir) + MANIFEST;
  if not FileExists(s) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(s);
    ARows := StrToInt64Def(Val('rows', '-1'), -1);
    ASig := Val('signature', '');
    AHash := Val('filehash', '');
    ABytes := StrToInt64Def(Val('bytes', '0'), 0);
    Result := (ARows > 0) and (ASig <> '') and (AHash <> '');
  finally
    sl.Free;
  end;
end;

{ ---------------------------------------------------------- yaz / oku modu }

function ModeWrite(const ADir: string; AReset: Boolean): Integer;
var
  p, err, sig: string;
  n: Int64;
begin
  if AReset then
    ResetCounters;
  WipeDir(ADir);
  if not CreateDb(ADir, p, err) then
  begin
    Chk('PW1 veritabani olusturuldu', False, 'hata=' + err);
    Exit(GFail);
  end;
  sig := DataSignature(p, n, err);
  Chk('PW1 veritabani olusturuldu ve geri okundu', n = ROWS,
    'satir=' + IntToStr(n) + ' hata=' + err);
  Chk('PW2 icerik ozeti hesaplandi', sig <> '', 'imza=' + sig);
  if (n <> ROWS) or (sig = '') then
    Exit(GFail);
  WriteManifest(ADir, p, sig, n);
  Info('PW yazildi: ' + p + ' satir=' + IntToStr(n) + ' imza=' + sig +
    ' bayt=' + IntToStr(FileLen(p)) + ' dosya=' + FileHash(p));
  Result := GFail;
end;

function ModeRead(const ADir: string; AReset: Boolean): Integer;
var
  p, sig, wantSig, wantHash, err, rep: string;
  n, wantRows, wantBytes: Int64;
  h0: string;
  BeC: TVdbBackendV3;
  verified, manOk: Boolean;
begin
  if AReset then
    ResetCounters;
  p := IncludeTrailingPathDelimiter(ADir) + DB_NAME;
  { Dikkat: FPC parametreleri SAGDAN sola degerlendirir; bu yuzden manifest
    once okunur, sonra ayrinti metni kurulur. Aksi halde `out` degiskenler
    ayrintida cop deger olarak gorunur. }
  manOk := ReadManifest(ADir, wantRows, wantSig, wantHash, wantBytes);
  Chk('PR1 manifest okunur', manOk,
    'satir=' + IntToStr(wantRows) + ' imza=' + wantSig + ' bayt=' +
    IntToStr(wantBytes));
  Chk('PR1 dosya var', FileExists(p), p);
  if (not FileExists(p)) or (wantRows <= 0) then
    Exit(GFail);

  { Icerik: sayi ve ozet ayni olmali. Ozet platformdan bagimsizdir. }
  sig := DataSignature(p, n, err);
  Chk('PR2 satir sayisi ayni', n = wantRows,
    'okunan=' + IntToStr(n) + ' beklenen=' + IntToStr(wantRows) + ' hata=' + err);
  Chk('PR3 icerik ozeti ayni', sig = wantSig,
    'okunan=' + sig + ' beklenen=' + wantSig);

  { Dosya baytlari tasinirken degismedi mi? }
  h0 := FileHash(p);
  Chk('PR4 dosya ozeti ayni', h0 = wantHash,
    'okunan=' + h0 + ' beklenen=' + wantHash);
  Chk('PR5 dosya boyu ayni', FileLen(p) = wantBytes,
    'okunan=' + IntToStr(FileLen(p)) + ' beklenen=' + IntToStr(wantBytes));

  { Motorun kendi denetimi: sayfalar, CRC, freelist, heap, indeks. }
  verified := False;
  rep := '';
  BeC := nil;
  try
    try
      BeC := TVdbBackendV3.CreateReadOnly(p);
      verified := BeC.Engine.Verify(rep);
    except
      on E: Exception do
        rep := 'hata: ' + E.Message;
    end;
  finally
    BeC := nil;
  end;
  Chk('PR6 VERIFY temiz', verified, rep);

  { Salt-okunur okuma dosyayi DEGISTIRMEMELI (yan dosya da birakmamali). }
  Chk('PR7 salt-okunur okuma dosyayi degistirmedi', FileHash(p) = h0,
    'once=' + h0 + ' sonra=' + FileHash(p));
  Chk('PR7 yan dosya olusmadi', not FileExists(p + '.wal'),
    'wal=' + BoolToStr(FileExists(p + '.wal'), True));
  Chk('PR7 .gen olusmadi', not FileExists(p + '.gen'),
    'gen=' + BoolToStr(FileExists(p + '.gen'), True));

  { Bicim kimligi: tasima sonrasi baslik ayni yerde ve ayni degerde. }
  Chk('PR8 baslik sihirli sayisi', ReadDWordAt(p, 0) = VDB_FILE_MAGIC,
    '$' + IntToHex(ReadDWordAt(p, 0), 8));
  Chk('PR8 baslik surumu', ReadDWordAt(p, 4) = VDB_FILE_VER,
    'ver=' + IntToStr(ReadDWordAt(p, 4)));
  Chk('PR8 sayfa boyu', ReadWordAt(p, 8) = VDB_PAGE_SIZE,
    'ps=' + IntToStr(ReadWordAt(p, 8)));

  Result := GFail;
end;

{ ------------------------------------------------- ayni platform turu }

function SelfRoundTrip: Integer;
var
  A, B, C: string;
  ok: Boolean;
  diffs, bad, schemaOfs: Int64;
  schemaLen: LongWord;
begin
  ResetCounters;
  A := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/port/a');
  WipeDir(A);
  { Yazma modu kendi PASS'larini (PW1/PW2) ayni sayaclara ekler. }
  ok := ModeWrite(A, False) = 0;
  Chk('PT1 yazma basarili', ok, A);
  Chk('PT2 temiz kapanis tek dosya birakti',
    FileExists(A + DB_NAME) and (not FileExists(A + DB_NAME + '.wal')) and
    (not FileExists(A + DB_NAME + '.gen')),
    'odb=' + BoolToStr(FileExists(A + DB_NAME), True) +
    ' wal=' + BoolToStr(FileExists(A + DB_NAME + '.wal'), True) +
    ' gen=' + BoolToStr(FileExists(A + DB_NAME + '.gen'), True));

  { Kopya: farkli bir dizine BAYT BAYT kopyalanmis dosya (tasima taklidi). }
  B := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/port/b');
  WipeDir(B);
  ok := CopyDb(A + DB_NAME, B + DB_NAME);
  Chk('PT3 kopya olustu', ok and FileExists(B + DB_NAME), B + DB_NAME);
  ok := CopyDb(A + MANIFEST, B + MANIFEST);
  Chk('PT3 manifest kopyalandi', ok and FileExists(B + MANIFEST),
    B + MANIFEST);
  Chk('PT4 kopya bayt bayt ayni',
    FileHash(A + DB_NAME) = FileHash(B + DB_NAME),
    FileHash(B + DB_NAME));

  { Okuma modu da ayni sayaclara ekler; tek ozet tum turu kapsar. }
  ok := ModeRead(B, False) = 0;
  Chk('PT5 kopya okunabilir ve dogrulanabilir', ok, B);

  { PT6/PT7: ayni platformda IKINCI bagimsiz yazim. Kalici imaj, ucucu meta
    alanlari (olusturma zamani, DB kimligi, sayfa 0 CRC) DISINDA bayt bayt
    ayni olmali. Bu, sema metninin platformdan bagimsiz yazildigini (satir
    sonu #10) ve baska bir LineEnding/siralama sizintisi olmadigini kilitler. }
  C := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/port/c');
  WipeDir(C);
  ok := ModeWrite(C, False) = 0;
  Chk('PT6 ikinci yazim basarili', ok, C);
  DiffImages(A + DB_NAME, C + DB_NAME, diffs, bad);
  Chk('PT6 imajlar yalnizca ucucu meta alanlarinda farkli', bad < 0,
    'fark=' + IntToStr(diffs) + ' ilk_kotu_ofset=' + IntToStr(bad));
  Chk('PT6 ucucu fark makul (<= 32 bayt)', diffs <= 32,
    'fark=' + IntToStr(diffs));
  { Sema metni #10 ile yazilir: CR (0x0D) YALNIZCA RTL'in LineEnding'inden
    gelebilir; satir degerleri a..z. Bu yuzden sema kaydinin cevresinde
    (VSCH1 etiketinden sonraki 512 bayt) CR aranir. Tum dosyada aramak
    yanlis olurdu: rastgele salt/kimlik baytlari 0x0D icerebilir. }
  ok := FindBytes(A + DB_NAME, AnsiString(VDB_SCHEMA_TAG), schemaOfs);
  Chk('PT7 sema kaydi imajda bulundu', ok, 'ofset=' + IntToStr(schemaOfs));
  { Kaydin uzunlugu, etiketten hemen ONCEKI u32 alandir; pencereyi o
    uzunlukla sinirla ve yalnizca sema metninde CR ara. }
  schemaLen := 0;
  if ok and (schemaOfs >= 4) then
    schemaLen := ReadDWordAt(A + DB_NAME, schemaOfs - 4);
  Chk('PT7 sema kaydinin uzunlugu makul',
    (schemaLen > 10) and (schemaLen < 4000), 'uzunluk=' + IntToStr(schemaLen));
  Chk('PT7 sema metninde CR (0x0D) yok',
    (schemaLen > 10) and (schemaLen < 4000) and
    (not RangeHasByte(A + DB_NAME, schemaOfs, schemaLen, 13)),
    'satir sonu = #10 (platformdan bagimsiz), uzunluk=' +
    IntToStr(schemaLen));

  Result := GFail;
  Summary;
end;

var
  mode: string;
begin
  if ParamCount >= 1 then
  begin
    mode := ParamStr(1);
    if (mode = '--write') and (ParamCount >= 2) then
    begin
      ModeWrite(ParamStr(2), True);
      Summary;
      Halt(GFail);
    end
    else if (mode = '--read') and (ParamCount >= 2) then
    begin
      ModeRead(ParamStr(2), True);
      Summary;
      Halt(GFail);
    end
    else
    begin
      WriteLn('kullanim: portability [--write <dizin> | --read <dizin>]');
      Halt(2);
    end;
  end;

  { Ayni platformda yaz/oku turu + kopya tasima taklidi. }
  Halt(SelfRoundTrip);
end.
