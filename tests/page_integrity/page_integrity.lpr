program page_integrity;
{ V3 sertlestirme - Phase 4: sayfa/heap/freelist tutarlilik kapisi.

  Amac (skill Phase 4 "page/index consistency checks"): bozuk bir sayfa,
  yinelenen anahtar, sahipsiz tasma sayfasi, tutmayan tasma uzunlugu,
  bozuk freelist ve kesik dosyanin SESSIZCE kabul EDILMEDIGINI kanitlamak.

  Yaklasim: saglam bir yedek imaji alinir; her senaryo icin imajin bir
  KOPYASI bayt duzeyinde bozulur ve (a) acilisin acik hata vermesi ya da
  (b) `Verify`'in raporlu reddi beklenir. Son kontrol, temel imajin hic
  degismedigini gosterir.

  Kapsam (durust sinir): ayri indeks dosyasi (VDbIdxFile) bu kapida
  kullanilmaz; "indeks" burada heap anahtar dizini + freelist zinciri
  olarak dogrulanir. Bkz. docs/engineering/PAGE_INTEGRITY.md.

  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbTable, VDbSql, VDbErr,
  VDbCore, VDbPage, VDbCrc32;

const
  { Baslik sayfasi alanlari (VDbPageStore.LoadMeta ile ayni). }
  META_PAGECOUNT = 12;
  META_FREETRUNK = 16;
  { Freelist trunk yerlesimi (VDbPageStore.Trunk* ile ayni). }
  TRUNK_ENTRY    = 16;
  { Heap hucre basligi: [8 bayt anahtar][4 bayt uzunluk][govde] }
  CELL_HDR       = 12;
  OVF_FLAG       = $80000000;
  LEN_MASK       = $7FFFFFFF;

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
end;

function TestDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'tmp';
end;

function FreshDir(const AName: string): string;
var
  sr: TSearchRec;
  p: string;
begin
  Result := IncludeTrailingPathDelimiter(TestDir) + 'pi_' + AName;
  if FindFirst(Result + PathDelim + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') and
         ((sr.Attr and faDirectory) = 0) then
      begin
        p := Result + PathDelim + sr.Name;
        DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ForceDirectories(Result);
end;

function CopyFileTo(const Src, Dst: string): Boolean;
var
  a, b: TFileStream;
begin
  Result := False;
  if not FileExists(Src) then Exit;
  a := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
  try
    b := TFileStream.Create(Dst, fmCreate);
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

function FileBytes(const AFile: string): Int64;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    Result := fs.Size;
  finally
    fs.Free;
  end;
end;

procedure TruncateBy(const AFile: string; ABytes: Int64);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite);
  try
    fs.Size := fs.Size - ABytes;
  finally
    fs.Free;
  end;
end;

procedure LoadPage(const AFile: string; APageNo: LongWord; var B: TVDbPageBuf);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE;
    fs.ReadBuffer(B, VDB_PAGE_SIZE);
  finally
    fs.Free;
  end;
end;

procedure SavePage(const AFile: string; APageNo: LongWord; var B: TVDbPageBuf);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite);
  try
    fs.Position := Int64(APageNo) * VDB_PAGE_SIZE;
    fs.WriteBuffer(B, VDB_PAGE_SIZE);
  finally
    fs.Free;
  end;
end;

function MetaPageCount(const AFile: string): LongWord;
var
  B: TVDbPageBuf;
begin
  LoadPage(AFile, 0, B);
  Move(B[META_PAGECOUNT], Result, SizeOf(Result));
end;

function MetaFreeTrunk(const AFile: string): LongWord;
var
  B: TVDbPageBuf;
begin
  LoadPage(AFile, 0, B);
  Move(B[META_FREETRUNK], Result, SizeOf(Result));
end;

{ Freelist trunk sayfasinin CRC'sini tazele (TrunkSeal ile ayni). }
procedure SealTrunk(var B: TVDbPageBuf);
var
  q: PLongWord;
begin
  q := PLongWord(@B[VDB_PAGE_BODY_END]);
  q^ := VDbCrc32Of(B, VDB_PAGE_BODY_END);
end;

function CellLen(const B: TVDbPageBuf; ASlot: Integer): LongWord;
var
  d: PByte;
  dl: Integer;
begin
  Result := 0;
  if not PageGetCell(@B, ASlot, d, dl) then Exit;
  if dl < CELL_HDR then Exit;
  Move((d + 8)^, Result, SizeOf(Result));
end;

{ OVF isaretli ilk hucreyi bulur. }
function FindOvfCell(const AFile: string; out APageNo: LongWord;
  out ASlot: Integer): Boolean;
var
  pno, n: LongWord;
  i: Integer;
  B: TVDbPageBuf;
begin
  Result := False;
  APageNo := 0;
  ASlot := -1;
  n := MetaPageCount(AFile);
  pno := 1;
  while pno < n do
  begin
    LoadPage(AFile, pno, B);
    if PageTypeOf(@B) = VDB_PAGE_HEAP then
      for i := 0 to PageSlotCount(@B) - 1 do
        if (CellLen(B, i) and OVF_FLAG) <> 0 then
        begin
          APageNo := pno;
          ASlot := i;
          Exit(True);
        end;
    Inc(pno);
  end;
end;

function FindSplittableHeapPage(const AFile: string; out APageNo: LongWord): Boolean;
var
  pno, n: LongWord;
  B: TVDbPageBuf;
begin
  Result := False;
  APageNo := 0;
  n := MetaPageCount(AFile);
  pno := 1;
  while pno < n do
  begin
    LoadPage(AFile, pno, B);
    if (PageTypeOf(@B) = VDB_PAGE_HEAP) and
       (PageLiveCount(@B) > 0) and
       (PageFreeBytes(@B) > 64) then
    begin
      APageNo := pno;
      Exit(True);
    end;
    Inc(pno);
  end;
end;

{ Imaji acar; acilirsa Verify sonucunu doner.
  Returns: 0 = acildi (AVerified/AReport gecerli), 1 = acilis reddetti
  (AMsg = istisna metni). }
function OpenAndVerify(const AFile: string; out AVerified: Boolean;
  out AMsg: string): Integer;
var
  Be: IVdbBackend;
  rep: string;
begin
  Result := 0;
  AVerified := False;
  AMsg := '';
  try
    VdbOpenReadOnly(AFile, Be);
    try
      AVerified := Be.Verify(rep);
      AMsg := rep;
    finally
      Be := nil;
    end;
  except
    on E: Exception do
    begin
      Result := 1;
      AMsg := E.Message;
    end;
  end;
end;

procedure OpenEnv(const ADir: string; ACreate: Boolean; out Be: IVdbBackend;
  out Tb: TVTableDb; out Sq: TVSql);
begin
  VdbOpen(IncludeTrailingPathDelimiter(ADir), Be, ACreate, False);
  Tb := TVTableDb.CreateBackend(Be);
  Tb.Open(IncludeTrailingPathDelimiter(ADir));
  Sq := TVSql.Create(Tb);
end;

function Rep1(const S: string): string;
begin
  Result := S;
  if Length(Result) > 160 then
  begin
    SetLength(Result, 160);
    Result := Result + '...';
  end;
end;

{ Ayni sayfadaki 0. hucreyi kopyalayip ikinci kez ekler. }
function DuplicateFirstCell(const AFile: string; APageNo: LongWord): Boolean;
var
  B: TVDbPageBuf;
  d: PByte;
  dl, slot: Integer;
begin
  Result := False;
  LoadPage(AFile, APageNo, B);
  if not PageGetCell(@B, 0, d, dl) then Exit;
  if not PageInsertCell(PVdbPage(@B), d^, dl, slot) then Exit;
  PageSeal(PVdbPage(@B));
  SavePage(AFile, APageNo, B);
  Result := True;
end;

{ Tasma hucrenin ilan edilen uzunlugunu 4000 bayt sisirir. }
function InflateOvfLength(const AFile: string; APageNo: LongWord;
  ASlot: Integer): Boolean;
var
  B: TVDbPageBuf;
  d: PByte;
  dl: Integer;
  len: LongWord;
begin
  Result := False;
  LoadPage(AFile, APageNo, B);
  if not PageGetCell(@B, ASlot, d, dl) then Exit;
  if dl < CELL_HDR + 4 then Exit;
  Move((d + 8)^, len, SizeOf(len));
  len := ((len and LEN_MASK) + 4000) or (len and OVF_FLAG);
  Move(len, (d + 8)^, SizeOf(len));
  PageSeal(PVdbPage(@B));
  SavePage(AFile, APageNo, B);
  Result := True;
end;

var
  MainDir, FreeDir: string;
  GoodImg, Work, FreeImg: string;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  rep: string;
  ok: Boolean;
  rc: Integer;
  pno: LongWord;
  slot, i: Integer;
  B: TVDbPageBuf;
  big, ins: string;
  trunk, badEntry: LongWord;

begin
  GPass := 0;
  GFail := 0;

  MainDir := FreshDir('main');
  FreeDir := FreshDir('free');

  { -----------------------------------------------------------------
    Temel imaj: 3 kucuk satir + 1 tasma gerektiren buyuk satir.
    ----------------------------------------------------------------- }
  OpenEnv(MainDir, True, Be, Tb, Sq);
  try
    Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    Sq.Exec('INSERT INTO t (id, name) VALUES (1, ''alpha'')');
    Sq.Exec('INSERT INTO t (id, name) VALUES (2, ''beta'')');
    Sq.Exec('INSERT INTO t (id, name) VALUES (3, ''gamma'')');
    big := StringOfChar('x', 9000);
    ins := 'INSERT INTO t (id, name) VALUES (4, ''' + big + ''')';
    Sq.Exec(ins);
    GoodImg := IncludeTrailingPathDelimiter(MainDir) + 'temel.odb';
    Be.BackupTo(GoodImg);
    Chk('I0 temel imaj alindi',
      FileExists(GoodImg) and (FileBytes(GoodImg) > 0),
      'bayt=' + IntToStr(FileBytes(GoodImg)));

    ok := Be.Verify(rep);
    Chk('I1 temiz veritabani butun', ok and (Pos('sayfa=', rep) = 1),
      'rapor=' + Rep1(rep));
    Chk('I2 Verify raporu anahtar ve lsn tasiyor',
      (Pos('anahtar=', rep) > 0) and (Pos('lsn=', rep) > 0),
      'rapor=' + Rep1(rep));
  finally
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
  end;

  rc := OpenAndVerify(GoodImg, ok, rep);
  Chk('I3 temel imaj bagimsiz aciliyor ve butun', (rc = 0) and ok,
    'rapor=' + Rep1(rep));

  { -----------------------------------------------------------------
    A) Yinelenen anahtar: ayni sayfada ayni hucre iki kez.
    ----------------------------------------------------------------- }
  Work := IncludeTrailingPathDelimiter(MainDir) + 'dup.odb';
  if CopyFileTo(GoodImg, Work) and FindSplittableHeapPage(Work, pno) then
  begin
    if DuplicateFirstCell(Work, pno) then
    begin
      rc := OpenAndVerify(Work, ok, rep);
      Chk('I4 yinelenen anahtar acilista reddedildi',
        (rc = 1) and (Pos('yinelenen anahtar', rep) > 0), 'msg=' + Rep1(rep));
    end
    else
      Chk('I4 yinelenen anahtar acilista reddedildi', False, 'hucre eklenemedi');
  end
  else
    Chk('I4 yinelenen anahtar acilista reddedildi', False, 'kopya/sayfa yok');

  { -----------------------------------------------------------------
    B) CRC bozulmasi: govde baytini cevir, CRC'yi tazeleme.
    ----------------------------------------------------------------- }
  Work := IncludeTrailingPathDelimiter(MainDir) + 'crc.odb';
  if CopyFileTo(GoodImg, Work) and FindSplittableHeapPage(Work, pno) then
  begin
    LoadPage(Work, pno, B);
    B[200] := B[200] xor $FF;
    SavePage(Work, pno, B);
    rc := OpenAndVerify(Work, ok, rep);
    Chk('I5 CRC bozuk sayfa acilista reddedildi',
      (rc = 1) and (Pos('bozuk', rep) > 0), 'msg=' + Rep1(rep));
  end
  else
    Chk('I5 CRC bozuk sayfa acilista reddedildi', False, 'kopya/sayfa yok');

  { -----------------------------------------------------------------
    C) Sihirli sayi bozulmasi: sayfa taninmiyor.
    ----------------------------------------------------------------- }
  Work := IncludeTrailingPathDelimiter(MainDir) + 'magic.odb';
  if CopyFileTo(GoodImg, Work) and FindSplittableHeapPage(Work, pno) then
  begin
    LoadPage(Work, pno, B);
    B[0] := B[0] xor $FF;
    SavePage(Work, pno, B);
    rc := OpenAndVerify(Work, ok, rep);
    Chk('I6 taninmayan sayfa acilista reddedildi',
      (rc = 1) and (Pos('taninmiyor', rep) > 0), 'msg=' + Rep1(rep));
  end
  else
    Chk('I6 taninmayan sayfa acilista reddedildi', False, 'kopya/sayfa yok');

  { -----------------------------------------------------------------
    D) Heap sayfasi tasma sayfasina cevrilir: sahipsiz tasma.
    ----------------------------------------------------------------- }
  Work := IncludeTrailingPathDelimiter(MainDir) + 'orphan.odb';
  if CopyFileTo(GoodImg, Work) and FindSplittableHeapPage(Work, pno) then
  begin
    LoadPage(Work, pno, B);
    PageInit(PVdbPage(@B), pno, VDB_PAGE_OVERFLOW);
    SavePage(Work, pno, B);
    rc := OpenAndVerify(Work, ok, rep);
    Chk('I7 sahipsiz tasma sayfasi Verify tarafindan reddedildi',
      (rc = 0) and (not ok) and (Pos('sahipsiz tasma', rep) > 0),
      'rapor=' + Rep1(rep));
  end
  else
    Chk('I7 sahipsiz tasma sayfasi Verify tarafindan reddedildi', False,
      'kopya/sayfa yok');

  { -----------------------------------------------------------------
    E) Tasma uzunlugu sisirilir: zincir ilan edilen bayti tutmaz.
    ----------------------------------------------------------------- }
  Work := IncludeTrailingPathDelimiter(MainDir) + 'ovflen.odb';
  if CopyFileTo(GoodImg, Work) and FindOvfCell(Work, pno, slot) then
  begin
    if InflateOvfLength(Work, pno, slot) then
    begin
      rc := OpenAndVerify(Work, ok, rep);
      Chk('I8 tutmayan tasma uzunlugu Verify tarafindan reddedildi',
        (rc = 0) and (not ok) and (Pos('tasma', rep) > 0),
        'rapor=' + Rep1(rep));
    end
    else
      Chk('I8 tutmayan tasma uzunlugu Verify tarafindan reddedildi', False,
        'hucre yamalanamadi');
  end
  else
    Chk('I8 tutmayan tasma uzunlugu Verify tarafindan reddedildi', False,
      'kopya/tasma hucre yok');

  { -----------------------------------------------------------------
    F) Kesik dosya.
    ----------------------------------------------------------------- }
  Work := IncludeTrailingPathDelimiter(MainDir) + 'kesik.odb';
  if CopyFileTo(GoodImg, Work) then
  begin
    TruncateBy(Work, VDB_PAGE_SIZE div 2);
    rc := OpenAndVerify(Work, ok, rep);
    Chk('I9 kesik dosya acilista reddedildi',
      (rc = 1) and (Pos('dosya kesik', rep) > 0), 'msg=' + Rep1(rep));
  end
  else
    Chk('I9 kesik dosya acilista reddedildi', False, 'kopya yok');

  { -----------------------------------------------------------------
    G) Baslik (meta) sayfasi CRC bozulmasi.
    ----------------------------------------------------------------- }
  Work := IncludeTrailingPathDelimiter(MainDir) + 'meta.odb';
  if CopyFileTo(GoodImg, Work) then
  begin
    LoadPage(Work, 0, B);
    B[200] := B[200] xor $FF;
    SavePage(Work, 0, B);
    rc := OpenAndVerify(Work, ok, rep);
    Chk('I10 bozuk baslik acilista reddedildi',
      (rc = 1) and (Pos('baslik sayfasi CRC', rep) > 0), 'msg=' + Rep1(rep));
  end
  else
    Chk('I10 bozuk baslik acilista reddedildi', False, 'kopya yok');

  { -----------------------------------------------------------------
    H) Freelist: bosaltilan veritabaninda trunk girdisi aralik disi.
    ----------------------------------------------------------------- }
  OpenEnv(FreeDir, True, Be, Tb, Sq);
  try
    Sq.Exec('CREATE TABLE f (id INTEGER PRIMARY KEY, pad TEXT)');
    big := StringOfChar('y', 200);
    for i := 1 to 200 do
      Sq.Exec('INSERT INTO f (id, pad) VALUES (' + IntToStr(i) +
        ', ''' + big + ''')');
    Sq.Exec('DELETE FROM f');
    FreeImg := IncludeTrailingPathDelimiter(FreeDir) + 'bos.odb';
    Be.BackupTo(FreeImg);
  finally
    FreeAndNil(Sq);
    FreeAndNil(Tb);
    Be := nil;
  end;

  Work := IncludeTrailingPathDelimiter(FreeDir) + 'trunk.odb';
  if CopyFileTo(FreeImg, Work) then
  begin
    trunk := MetaFreeTrunk(Work);
    if trunk = 0 then
      Chk('I11 bozuk freelist girdisi Verify tarafindan reddedildi', False,
        'freelist trunk yok (silme bos sayfa birakmadi)')
    else
    begin
      LoadPage(Work, trunk, B);
      badEntry := MetaPageCount(Work) + 100;
      Move(badEntry, B[TRUNK_ENTRY], SizeOf(LongWord));
      SealTrunk(B);
      SavePage(Work, trunk, B);
      rc := OpenAndVerify(Work, ok, rep);
      Chk('I11 bozuk freelist girdisi Verify tarafindan reddedildi',
        (rc = 0) and (not ok) and
        ((Pos('freelist', rep) > 0) or (Pos('aralik disi', rep) > 0)),
        'rapor=' + Rep1(rep));
      rc := OpenAndVerify(FreeImg, ok, rep);
      Chk('I12 temiz bosaltilmis imaj butun (trunk sayfalari taranmaz)',
        (rc = 0) and ok, 'rapor=' + Rep1(rep));
    end;
  end
  else
    Chk('I11 bozuk freelist girdisi Verify tarafindan reddedildi', False,
      'kopya yok');

  { -----------------------------------------------------------------
    Son: temel imaj hic bozulmadi.
    ----------------------------------------------------------------- }
  rc := OpenAndVerify(GoodImg, ok, rep);
  Chk('I13 temel imaj tum senaryolardan sonra hala butun', (rc = 0) and ok,
    'rapor=' + Rep1(rep));

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
