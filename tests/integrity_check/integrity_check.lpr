program integrity_check;
{ SKILL2 §23 — BUTUNLUK DENETLEYICI kapisi (G6).

Dogrulanan sozlesme:
  * §23.2 dort mod: --quick / --full / --index / --wal, her biri ayri
    denetim derinligi; kod COGALTILMAZ, tek govde + bayraklar.
  * §23.3 salt-okunur: denetim veritabanini DEGISTIRMEZ, sessiz onarim
    YAPMAZ, yan dosya (.wal/.idx/.gen) OLUSTURMAZ. Kanit: denetimden once
    ve sonra dosyanin FNV-1a ozeti + boyutu + dizin icerigi AYNI.
  * Uyari ile bozulma AYRILIR: kesik WAL kuyrugu (torn tail) cokme sonrasi
    normaldir -> UYARI, cikis 0. Yapisal/CRC hatalari -> BOZULMA, cikis 2.

Senaryolar:
  A  saglam DB: dort mod da temiz; rapor bicimi; dosya degismedi
  B  sayfa sihirli sayisi bozuk -> 'sayfa N taninmiyor' (yapisal)
  C  sayfa CRC bozuk -> full 'sayfa N bozuk'; quick GORMEMELI (dokumante
     sinirlama, durust rapor)
  D  freelist trunk sayfasi bozuk -> 'freelist' hatasi (quick/index de gorur)
  E  kesik WAL kuyrugu -> UYARI, temiz; DB bozulmasi degil
  F  dosya kesik (truncated) -> acilis/denetim hatasi, cikis 2
  G  CLI: kullanim hatasi 1, bozulma 2, temiz 0

Kullanim: integrity_check <vdbcheck-yolu>
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process,
  VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine, VDbPageStore, VDbPage,
  VDbCrc32;

const
  ROWS = 300;
  VAL_LEN = 200;

var
  GPass, GFail: Integer;
  GChecker: string;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' | ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' | ', ADetail);
  end;
  Flush(Output);
end;

procedure Info(const AText: string);
begin
  WriteLn('BILGI ', AText);
  Flush(Output);
end;

{ ---------------------------------------------------------------- dosya }

function MkVal(AKey, ALen: Integer): TBytes;
var
  s: AnsiString;
begin
  s := 'satir-' + IntToStr(AKey) + ':';
  while Length(s) < ALen do
    s := s + 'x';
  SetLength(s, ALen);
  SetLength(Result, ALen);
  if ALen > 0 then
    Move(s[1], Result[0], ALen);
end;

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp');
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
  p: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        p := IncludeTrailingPathDelimiter(ADir) + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
        begin
          WipeDir(p);
          RemoveDir(p);
        end
        else
          SysUtils.DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function ListFiles(const ADir: string): string;
var
  sr: TSearchRec;
  s: string;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        s := sr.Name;
        if (sr.Attr and faDirectory) <> 0 then s := s + '/';
        if Result <> '' then Result := Result + ',';
        Result := Result + s;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function FileHash(const APath: string): string;
var
  fs: TFileStream;
  b: Byte;
  h: QWord;
begin
  h := QWord(14695981039346656037);
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    while fs.Read(b, 1) = 1 do
    begin
      h := h xor QWord(b);
      h := h * QWord(1099511628211);
    end;
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

procedure CopyDb(const ASrc, ADst: string);
var
  a, b: TFileStream;
begin
  a := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    b := TFileStream.Create(ADst, fmCreate);
    try
      b.CopyFrom(a, 0);
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure WriteByteAt(const APath: string; AOffset: Int64; AValue: Byte);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := AOffset;
    fs.WriteBuffer(AValue, 1);
  finally
    fs.Free;
  end;
end;

{ Trunk sayfasinin ILK girdisini aralik disi bir sayfa numarasina cevirir ve
  CRC'yi YENIDEN hesaplar. Boylece sayfa hala gecerli bir trunk imajidir
  (acilis taramasi gecer) ama freelist denetimi hatayi yakalar. }
function CorruptTrunkEntry(const APath: string; APageNo, ABadEntry: LongWord): Boolean;
var
  fs: TFileStream;
  buf: array of Byte;
  crc: LongWord;
begin
  Result := False;
  SetLength(buf, VDB_PAGE_SIZE);
  fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE;
    fs.ReadBuffer(buf[0], VDB_PAGE_SIZE);
    { [16..19] = ilk girdi }
    Move(ABadEntry, buf[VDB_TRUNK_HDR], SizeOf(ABadEntry));
    crc := VDbCrc32Of(buf[0], VDB_PAGE_BODY_END);
    { CRC, govde sonunda 4 bayt. }
    Move(crc, buf[VDB_PAGE_BODY_END], SizeOf(crc));
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE;
    fs.WriteBuffer(buf[0], VDB_PAGE_SIZE);
    Result := True;
  finally
    fs.Free;
  end;
end;

function ReadByteAt(const APath: string; AOffset: Int64): Byte;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    fs.Position := AOffset;
    fs.ReadBuffer(Result, 1);
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

procedure AppendGarbage(const APath: string; ABytes: Integer);
var
  fs: TFileStream;
  junk: array[0..63] of Byte;
  i: Integer;
begin
  for i := Low(junk) to High(junk) do
    junk[i] := Byte($A0 + i);
  fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := fs.Size;
    fs.WriteBuffer(junk, ABytes);
  finally
    fs.Free;
  end;
end;

procedure TruncateTo(const APath: string; ASize: Int64);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Size := ASize;
  finally
    fs.Free;
  end;
end;

{ ---------------------------------------------------------------- DB }

procedure CreateBase(const APath: string; ARows: Integer);
var
  Be: IVdbBackend;
  k: Integer;
begin
  VdbOpen(APath, Be, True, True);
  try
    Be.BeginBatch;
    for k := 1 to ARows do
      Be.Put(k, MkVal(k, VAL_LEN));
    Be.CommitBatch;
  finally
    Be := nil;
  end;
end;

{ Salt-okunur acar, modu kosar. Acilis/denetim hatasi da "yakalandi"
  sayilir; metin ARep icinde doner. }
function VerifyMode(const APath: string; AMode: TVdbVerifyMode;
  out ARep: string): Boolean;
var
  Be: TVdbBackendV3;
begin
  ARep := '';
  Result := False;
  Be := nil;
  try
    try
      Be := TVdbBackendV3.CreateReadOnly(APath);
    except
      on E: Exception do
      begin
        ARep := 'acilamadi: ' + E.Message;
        Exit;
      end;
    end;
    try
      Result := Be.Engine.VerifyEx(AMode, True, ARep);
    except
      on E: Exception do
      begin
        ARep := 'denetim hatasi: ' + E.Message;
        Result := False;
      end;
    end;
  finally
    Be.Free;
  end;
end;

function Has(const AHaystack, ANeedle: string): Boolean;
begin
  Result := Pos(ANeedle, AHaystack) > 0;
end;

{ ---------------------------------------------------------------- CLI }

function RunCli(const AArgs: array of string; out AOut: string): Integer;
var
  P: TProcess;
  i: Integer;
  buf: array[0..4095] of AnsiChar;
  n: LongInt;
begin
  AOut := '';
  P := TProcess.Create(nil);
  try
    P.Executable := GChecker;
    for i := Low(AArgs) to High(AArgs) do
      P.Parameters.Add(AArgs[i]);
    P.Options := [poUsePipes, poStderrToOutput, poWaitOnExit];
    P.Execute;
    repeat
      n := P.Output.Read(buf, SizeOf(buf));
      if n > 0 then
        AOut := AOut + Copy(buf, 1, n);
    until n <= 0;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

procedure ChkCli(const AName: string; const AArgs: array of string;
  AExpectExit: Integer; const ANeedle: string);
var
  outS: string;
  rc: Integer;
begin
  rc := RunCli(AArgs, outS);
  Chk(AName, (rc = AExpectExit) and Has(outS, ANeedle),
    'exit=' + IntToStr(rc) + ' bekle=' + IntToStr(AExpectExit) +
    ' cikti=' + Trim(outS));
end;

{ ---------------------------------------------------------------- ana }

var
  D, A, B, C, E, F, DbA: string;
  rep, h0, hNow, files0: string;
  sz0, szNow: Int64;
  ok: Boolean;
  rc: Integer;
  trunk: LongWord;
  Be: TVdbBackendV3;
  W: IVdbBackend;
  k: Integer;
begin
  GPass := 0;
  GFail := 0;
  GChecker := '';
  if ParamCount >= 1 then
    GChecker := ParamStr(1);

  D := TestDir;
  WipeDir(D);
  ForceDirectories(D);
  if GChecker = '' then
  begin
    WriteLn('FAIL arguman | vdbcheck yolu verilmedi');
    Halt(1);
  end;
  if not FileExists(GChecker) then
  begin
    WriteLn('FAIL arguman | vdbcheck bulunamadi: ' + GChecker);
    Halt(1);
  end;

  { ---------------- A: saglam veritabani ---------------- }
  A := IncludeTrailingPathDelimiter(D + 'a');
  ForceDirectories(A);
  DbA := A + 'veritabani.odb';
  CreateBase(DbA, ROWS);

  h0 := FileHash(DbA);
  sz0 := FileLen(DbA);
  files0 := ListFiles(A);
  Info('saglam DB: boyut=' + IntToStr(sz0) + ' dosyalar=' + files0);

  ok := VerifyMode(DbA, vmFull, rep);
  Chk('IC-A1 full temiz', ok and Has(rep, 'sayfa=') and
    Has(rep, 'anahtar=' + IntToStr(ROWS)), rep);

  ok := VerifyMode(DbA, vmQuick, rep);
  Chk('IC-A2 quick temiz + mod etiketi',
    ok and Has(rep, 'mod=quick') and Has(rep, 'anahtar=denetlenmedi'), rep);

  ok := VerifyMode(DbA, vmIndex, rep);
  Chk('IC-A3 index temiz + mod etiketi',
    ok and Has(rep, 'mod=index') and Has(rep, 'anahtar=' + IntToStr(ROWS)), rep);

  ok := VerifyMode(DbA, vmWal, rep);
  Chk('IC-A4 wal temiz (icerik yok)',
    ok and Has(rep, 'wal=') and Has(rep, 'torn=hayir'), rep);

  hNow := FileHash(DbA);
  szNow := FileLen(DbA);
  Chk('IC-A5 denetim dosyayi DEGISTIRMEDI',
    (hNow = h0) and (szNow = sz0),
    'hash ' + h0 + '->' + hNow + ' boyut ' + IntToStr(sz0) + '->' +
    IntToStr(szNow));
  Chk('IC-A6 yan dosya OLUSMADI', ListFiles(A) = files0,
    'dosyalar=' + ListFiles(A));

  { ---------------- B: sayfa sihirli sayisi bozuk ---------------- }
  B := IncludeTrailingPathDelimiter(D + 'b');
  ForceDirectories(B);
  CopyDb(DbA, B + 'veritabani.odb');
  WriteByteAt(B + 'veritabani.odb', VDB_PAGE_SIZE, $00);
  h0 := FileHash(B + 'veritabani.odb');

  ok := VerifyMode(B + 'veritabani.odb', vmFull, rep);
  Chk('IC-B1 bozuk sihirli sayi -> yapisal hata (sayfa 1)',
    (not ok) and Has(rep, 'sayfa 1') and Has(rep, 'taninmiyor'), rep);

  ok := VerifyMode(B + 'veritabani.odb', vmQuick, rep);
  Chk('IC-B2 quick de yapisal hatayi gorur', not ok, rep);

  Chk('IC-B3 sessiz onarim YOK', FileHash(B + 'veritabani.odb') = h0,
    'hash=' + FileHash(B + 'veritabani.odb'));
  ChkCli('IC-B4 CLI bozulmada cikis 2', ['--full', B + 'veritabani.odb'],
    2, 'BOZUK');

  { ---------------- C: sayfa CRC bozuk ---------------- }
  C := IncludeTrailingPathDelimiter(D + 'c');
  ForceDirectories(C);
  CopyDb(DbA, C + 'veritabani.odb');
  WriteByteAt(C + 'veritabani.odb',
    Int64(VDB_PAGE_SIZE) + Int64(VDB_PAGE_SIZE div 2), $5A);
  h0 := FileHash(C + 'veritabani.odb');

  ok := VerifyMode(C + 'veritabani.odb', vmFull, rep);
  Chk('IC-C1 CRC bozuk -> full yakalar',
    (not ok) and Has(rep, 'sayfa 1') and Has(rep, 'bozuk'), rep);

  ok := VerifyMode(C + 'veritabani.odb', vmQuick, rep);
  Chk('IC-C2 acilis taramasi CRC''yi zaten yakalar',
    not ok and Has(rep, 'bozuk'), rep);

  Chk('IC-C3 sessiz onarim YOK', FileHash(C + 'veritabani.odb') = h0,
    'hash=' + FileHash(C + 'veritabani.odb'));

  { ---------------- D: freelist trunk bozuk ---------------- }
  E := IncludeTrailingPathDelimiter(D + 'd');
  ForceDirectories(E);
  trunk := 0;
  Be := TVdbBackendV3.Create(E + 'veritabani.odb', True);
  try
    W := Be;
    W.BeginBatch;
    for k := 1 to ROWS do
      W.Put(k, MkVal(k, VAL_LEN));
    W.CommitBatch;
    { Sayfa bosalt: freelist olussun. }
    W.BeginBatch;
    for k := 1 to ROWS - 20 do
      W.Delete(k);
    W.CommitBatch;
    trunk := Be.Engine.Store.GetFreeTrunk;
  finally
    { TVdbBackendV3 referans sayimli: arayuz birakilinca nesne kendini
      serbest birakir. Ayrica Free cagirmak cift serbest birakmaya yol acar. }
    W := nil;
    Be := nil;
  end;
  Chk('IC-D0 on kosul: freelist trunk var', trunk > 0,
    'trunk=' + IntToStr(trunk));

  if trunk > 0 then
  begin
    { Trunk sayfasinin GIRDI bolgesini boz: sihirli sayi gecerli kalir
      (acilis taramasi gecer) ama CRC/girdi denetimi freelist'te yakalar. }
    Info('trunk sayfa ilk 4 bayt: ' + IntToHex(QWord(
      ReadDWordAt(E + 'veritabani.odb', Int64(trunk) * VDB_PAGE_SIZE)), 8) +
      ' beklenen trunk=' + IntToHex(QWord(VDB_TRUNK_MAGIC), 8) +
      ' sayfa=' + IntToHex(QWord(VDB_PAGE_MAGIC), 8));
    { Girdi aralik disi + CRC yeniden hesaplandi: sayfa gecerli trunk kalir. }
    Chk('IC-D0b bozulma uygulandi',
      CorruptTrunkEntry(E + 'veritabani.odb', trunk, $00FFFFF0), 'girdi=00FFFFF0');
    ok := VerifyMode(E + 'veritabani.odb', vmFull, rep);
    Chk('IC-D1 bozuk freelist -> full yakalar',
      (not ok) and Has(rep, 'freelist'), rep);
    ok := VerifyMode(E + 'veritabani.odb', vmQuick, rep);
    Chk('IC-D2 quick freelist hatasini gorur',
      (not ok) and Has(rep, 'freelist'), rep);
    ok := VerifyMode(E + 'veritabani.odb', vmIndex, rep);
    Chk('IC-D3 index freelist hatasini gorur',
      (not ok) and Has(rep, 'freelist'), rep);
  end;

  { ---------------- E: kesik WAL kuyrugu = UYARI ---------------- }
  F := IncludeTrailingPathDelimiter(D + 'e');
  ForceDirectories(F);
  Be := TVdbBackendV3.Create(F + 'veritabani.odb', True);
  try
    Be.Engine.DropWalOnClose := False;
    W := Be;
    W.BeginBatch;
    for k := 1 to 40 do
      W.Put(k, MkVal(k, VAL_LEN));
    W.CommitBatch;
    { Canli WAL'de commit sayisi: mod onu gormeli. }
    ok := Be.Engine.VerifyEx(vmWal, True, rep);
    Chk('IC-E1 canli WAL incelemesi',
      ok and Has(rep, 'torn=hayir') and (not Has(rep, 'commit=0')), rep);
  finally
    W := nil;
    Be := nil;
  end;

  Chk('IC-E2 WAL dosyasi birakildi (DropWalOnClose=False)',
    FileExists(F + 'veritabani.odb.wal'), ListFiles(F));

  if FileExists(F + 'veritabani.odb.wal') then
  begin
    { Kesik kuyruk: yarim kayit basligi (23 bayt). }
    AppendGarbage(F + 'veritabani.odb.wal', 23);
    h0 := FileHash(F + 'veritabani.odb');
    ok := VerifyMode(F + 'veritabani.odb', vmWal, rep);
    Chk('IC-E3 kesik kuyruk UYARI (bozulma degil)',
      ok and Has(rep, 'UYARI') and Has(rep, 'torn=evet'), rep);
    ok := VerifyMode(F + 'veritabani.odb', vmFull, rep);
    Chk('IC-E4 kesik WAL veritabani bozulmasi DEGIL',
      ok and Has(rep, 'anahtar=40'), rep);
    Chk('IC-E5 WAL incelemesi DB dosyasina dokunmadi',
      FileHash(F + 'veritabani.odb') = h0,
      'hash=' + FileHash(F + 'veritabani.odb'));
  end;

  { ---------------- F: kesik dosya ---------------- }
  E := IncludeTrailingPathDelimiter(D + 'f');
  ForceDirectories(E);
  CopyDb(DbA, E + 'veritabani.odb');
  TruncateTo(E + 'veritabani.odb', VDB_PAGE_SIZE + 512);
  sz0 := FileLen(E + 'veritabani.odb');
  ChkCli('IC-F1 kesik dosya -> cikis 2',
    ['--full', E + 'veritabani.odb'], 2, 'BOZUK');
  Chk('IC-F2 kesik dosya onarilmadi', FileLen(E + 'veritabani.odb') = sz0,
    'boyut=' + IntToStr(FileLen(E + 'veritabani.odb')));

  { ---------------- G: CLI sozlesmesi ---------------- }
  ChkCli('IC-G1 kullanim hatasi -> 1', [], 1, 'kullanim');
  ChkCli('IC-G2 bilinmeyen secenek -> 1', ['--bogus', DbA], 1, 'bilinmeyen');
  ChkCli('IC-G3 dosya yok -> 1', ['--full', D + 'yok.odb'], 1, 'dosya yok');
  ChkCli('IC-G4 saglam DB --full -> 0', ['--full', DbA], 0, 'TEMIZ full:');
  ChkCli('IC-G5 saglam DB --quick -> 0', ['--quick', DbA], 0, 'TEMIZ quick:');
  ChkCli('IC-G6 saglam DB --index -> 0', ['--index', DbA], 0, 'TEMIZ index:');
  ChkCli('IC-G7 saglam DB --wal -> 0', ['--wal', DbA], 0, 'TEMIZ wal:');

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
