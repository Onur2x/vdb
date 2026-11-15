program format_compat;
{ VDB V3 sertlestirme - SKILL2 §24 (G7) kapisi: FORMAT UYUMLULUGU / GOC.

Amac: motorun §24.2'deki AYRIMLARI gercekten yaptigini kanitlamak:
  * desteklenen format (v5)               -> acilir
  * daha eski DESTEKLENEN format (v3/v4)  -> acilir, okunur, yazmada 5'e yukselir
  * daha YENI desteklenmeyen format (v6+) -> ACILMAZ (sessizce gecmez)
  * bozuk format (baslik CRC / sayfa boyu / kesik dosya) -> ACILMAZ
  * v2 dosyasi                            -> net goc hatasi (MIGRATE TO v3)
  * yarim kalmis goc imzasi (surum yazildi, CRC yazilmadi) -> ACILMAZ

Durust sinirlar (bu kapi neyi KANITLAMAZ):
  - Imajlar SENTETIKTIR: gercek motorla uretilmis v5 dosyasinin baslik
    surum alani 3/4 yapilip CRC'si yeniden hesaplanarak turetilir. Satir
    govdesi kendi kendini tanimladigi icin (VDbTable.pas: [u16 $FFFF]
    isareti) v3/v4/v5 imajlari AYNI okuyucuyla okunur; motorun ayirt
    ettigi tek sey basliktir. Bu yuzden sentetik imaj, motorun gordugu
    sey bakimindan gercek bir eski-damgali dosyayla aynidir; ama gercek
    bir v3 dosyasindaki eski satir govdelerini ICERMEZ.
  - Surum yukseltmesi tek bir 4 KB'lik YERINDE baslik yazimidir (golge
    kopya yok). Bu yazim kesilirse dosya ACILMAZ (CRC tutmaz) — kapi bunu
    FC-G2 ile gosterir. Kesilmis goc icin tanimli kurtarma proseduru
    "yedekten geri yukle"dir; bkz. STORAGE_AUDIT.md §24.

Derleme: fpc (lpi gerektirmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageStore,
  VDbPage, VDbCrc32, VDbTable, VDbSql, VDbErr;

const
  ROWS = 40;

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

procedure WipeDir(const D: string);
var
  sr: TSearchRec;
begin
  ForceDirectories(D);
  if FindFirst(D + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(D + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ FNV-1a 64: dosyanin ICERIGI degisti mi? (Salt-okunur kaniti.) }
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

{ Baslik sayfasini (sayfa 0) yerinde duzenler. Verilen alanlar degistirilir;
  ARecomputeCrc=True ise baslik CRC'si YENIDEN hesaplanir, boylece imaj
  "gecerli baslik, baska surum" olur (motorun kabul/red karari bu durumda
  surum alanina kalir). False ise CRC BAYAT kalir = yarim yazilmis baslik. }
procedure PatchHeader(const APath: string;
  AHasMagic: Boolean; AMagic: LongWord;
  AHasVer: Boolean; AVer: LongWord;
  AHasPageSize: Boolean; APageSize: Word;
  ARecomputeCrc: Boolean);
var
  fs: TFileStream;
  buf: array of Byte;
  crc: LongWord;
begin
  SetLength(buf, VDB_PAGE_SIZE);
  fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := 0;
    fs.ReadBuffer(buf[0], VDB_PAGE_SIZE);
    if AHasMagic then Move(AMagic, buf[0], SizeOf(AMagic));
    if AHasVer then Move(AVer, buf[4], SizeOf(AVer));
    if AHasPageSize then Move(APageSize, buf[8], SizeOf(APageSize));
    if ARecomputeCrc then
    begin
      crc := VDbCrc32Of(buf[0], VDB_PAGE_BODY_END);
      Move(crc, buf[VDB_PAGE_BODY_END], SizeOf(crc));
    end;
    fs.Position := 0;
    fs.WriteBuffer(buf[0], VDB_PAGE_SIZE);
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

function SetVer(const APath: string; AVer: LongWord): Boolean;
begin
  PatchHeader(APath, False, 0, True, AVer, False, 0, True);
  Result := True;
end;

{ Acar (RO ya da yazilabilir), sayar, VERIFY eder ve KAPATIR.
  Basarisizlikta ACount=-1, AErr dolu doner. }
function Probe(const APath: string; AReadOnly: Boolean;
  out ACount: Int64; out ARep: string; out AVerified: Boolean;
  out AErr: string): Boolean;
var
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
begin
  Result := False;
  ACount := -1;
  ARep := '';
  AVerified := False;
  AErr := '';
  BeC := nil;
  Tb := nil;
  Sq := nil;
  try
    try
      if AReadOnly then
        BeC := TVdbBackendV3.CreateReadOnly(APath)
      else
        BeC := TVdbBackendV3.Create(APath, False);
      Be := BeC;
      Tb := TVTableDb.CreateBackend(Be);
      Tb.Open(ExtractFileDir(APath));
      Sq := TVSql.Create(Tb);
      R := Sq.Exec('SELECT COUNT(*) FROM t');
      ACount := StrToInt64Def(R.Rows[0][0], -1);
      try
        AVerified := BeC.Engine.Verify(ARep);
      except
        on E: Exception do
        begin
          ARep := 'verify hata: ' + E.Message;
          AVerified := False;
        end;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        AErr := E.ClassName + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    Sq.Free;
    Tb.Free;
    Be := nil;
    BeC := nil;
  end;
end;

{ Tek bir satiri birincil anahtarla okur (goc sonrasi icerik bozulmadi mi). }
function RowText(const APath: string; AId: Integer;
  out AVal, AErr: string): Boolean;
var
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
begin
  Result := False;
  AVal := '';
  AErr := '';
  BeC := nil;
  Tb := nil;
  Sq := nil;
  try
    try
      BeC := TVdbBackendV3.CreateReadOnly(APath);
      Be := BeC;
      Tb := TVTableDb.CreateBackend(Be);
      Tb.Open(ExtractFileDir(APath));
      Sq := TVSql.Create(Tb);
      R := Sq.Exec('SELECT v FROM t WHERE id = ' + IntToStr(AId));
      if Length(R.Rows) = 1 then
        AVal := R.Rows[0][0];
      Result := True;
    except
      on E: Exception do
      begin
        AErr := E.ClassName + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    Sq.Free;
    Tb.Free;
    Be := nil;
    BeC := nil;
  end;
end;

var
  D, Base: string;
  paths: array[0..7] of string;
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i: Integer;
  n: Int64;
  rep, err, v, h0, hNow: string;
  verified, ok: Boolean;
begin
  GPass := 0;
  GFail := 0;

  D := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/fc');
  WipeDir(D);
  Base := D + 'base.odb';

  { ---------- Temel: gercek motorla uretilmis v5 dosyasi ---------- }
  BeC := TVdbBackendV3.Create(Base);
  Be := BeC;
  try
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(D);
      Sq := TVSql.Create(Tb);
      try
        Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        for i := 1 to ROWS do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            MkVal(i) + ''')');
      finally
        Sq.Free;
      end;
    finally
      Tb.Free;
    end;
  finally
    Be := nil;
    BeC := nil;
  end;

  h0 := FileHash(Base);
  Info('FC temel dosya: ' + IntToStr(FileLen(Base)) + ' bayt, sha=' + h0);

  Chk('FC-A1 temel sihirli sayi',
    ReadDWordAt(Base, 0) = VDB_FILE_MAGIC,
    '$' + IntToHex(ReadDWordAt(Base, 0), 8));
  Chk('FC-A2 temel surum = 5', ReadDWordAt(Base, 4) = VDB_FILE_VER,
    'ver=' + IntToStr(ReadDWordAt(Base, 4)));
  Chk('FC-A3 temel sayfa boyu', ReadWordAt(Base, 8) = VDB_PAGE_SIZE,
    'ps=' + IntToStr(ReadWordAt(Base, 8)));

  ok := Probe(Base, True, n, rep, verified, err);
  Chk('FC-A4 temel dosya salt-okunur okunur',
    ok and (n = ROWS) and verified,
    'COUNT=' + IntToStr(n) + ' verify=' + rep + ' hata=' + err);

  { ---------- B: v4 damgali imaj (eski ama DESTEKLENEN) ---------- }
  paths[0] := D + 'fc_v4.odb';
  CopyDb(Base, paths[0]);
  SetVer(paths[0], VDB_FILE_VER_V4);
  h0 := FileHash(paths[0]);

  ok := Probe(paths[0], True, n, rep, verified, err);
  Chk('FC-B1 v4 damgali imaj salt-okunur acilir', ok,
    'hata=' + err);
  Chk('FC-B2 v4 satirlar okunur (COUNT=40, VERIFY temiz)',
    ok and (n = ROWS) and verified,
    'COUNT=' + IntToStr(n) + ' verify=' + rep);
  Chk('FC-B3 salt-okunur acilis YUKSELTME YAPMADI',
    FileHash(paths[0]) = h0, 'hash degisti mi');
  Chk('FC-B4 v4 surum alani hala 4',
    ReadDWordAt(paths[0], 4) = VDB_FILE_VER_V4,
    'ver=' + IntToStr(ReadDWordAt(paths[0], 4)));

  ok := Probe(paths[0], False, n, rep, verified, err);
  Chk('FC-B5 v4 imaj yazilabilir acilir', ok and (n = ROWS) and verified,
    'COUNT=' + IntToStr(n) + ' verify=' + rep + ' hata=' + err);
  Chk('FC-B6 yazilabilir acilis surumu 5e yukseltti',
    ReadDWordAt(paths[0], 4) = VDB_FILE_VER,
    'ver=' + IntToStr(ReadDWordAt(paths[0], 4)));

  ok := Probe(paths[0], True, n, rep, verified, err);
  Chk('FC-B7 yukseltme sonrasi satirlar duruyor',
    ok and (n = ROWS) and verified,
    'COUNT=' + IntToStr(n) + ' verify=' + rep);
  ok := RowText(paths[0], 7, v, err);
  Chk('FC-B8 yukseltme sonrasi icerik bozulmadi',
    ok and (v = MkVal(7)), 'v=' + v + ' beklenen=' + MkVal(7) + ' hata=' + err);

  { ---------- C: v3 damgali imaj ---------- }
  paths[1] := D + 'fc_v3.odb';
  CopyDb(Base, paths[1]);
  SetVer(paths[1], VDB_FILE_VER_V3);
  h0 := FileHash(paths[1]);

  ok := Probe(paths[1], True, n, rep, verified, err);
  Chk('FC-C1 v3 damgali imaj salt-okunur acilir, satirlar okunur',
    ok and (n = ROWS) and verified,
    'COUNT=' + IntToStr(n) + ' verify=' + rep + ' hata=' + err);
  Chk('FC-C2 v3 salt-okunur yukseltme yapmadi', FileHash(paths[1]) = h0,
    'hash degisti mi');

  ok := Probe(paths[1], False, n, rep, verified, err);
  Chk('FC-C3 v3 yazilabilir acilista 5e yukseldi',
    ok and (n = ROWS) and verified and (ReadDWordAt(paths[1], 4) = VDB_FILE_VER),
    'COUNT=' + IntToStr(n) + ' ver=' + IntToStr(ReadDWordAt(paths[1], 4)) +
    ' verify=' + rep);

  { ---------- D: daha YENI format (v6) -> RED ---------- }
  paths[2] := D + 'fc_v6.odb';
  CopyDb(Base, paths[2]);
  SetVer(paths[2], 6);
  h0 := FileHash(paths[2]);

  ok := Probe(paths[2], True, n, rep, verified, err);
  Chk('FC-D1 v6 salt-okunur acilista REDDEDILIR',
    (not ok) and Has(err, 'desteklenmeyen surum: 6'),
    'ok=' + BoolToStr(ok, True) + ' hata=' + err);
  ok := Probe(paths[2], False, n, rep, verified, err);
  Chk('FC-D2 v6 yazilabilir acilista da REDDEDILIR',
    (not ok) and Has(err, 'desteklenmeyen surum: 6'),
    'ok=' + BoolToStr(ok, True) + ' hata=' + err);
  Chk('FC-D3 reddedilen v6 dosyasi DEGISMEDI', FileHash(paths[2]) = h0,
    'hash degisti mi');

  { ---------- E: desteklenmeyen ESKI surum (v2 damgali) ---------- }
  paths[3] := D + 'fc_v2ver.odb';
  CopyDb(Base, paths[3]);
  SetVer(paths[3], 2);
  h0 := FileHash(paths[3]);
  ok := Probe(paths[3], True, n, rep, verified, err);
  Chk('FC-E1 surum 2 REDDEDILIR',
    (not ok) and Has(err, 'desteklenmeyen surum: 2'),
    'hata=' + err);
  Chk('FC-E2 reddedilen dosya DEGISMEDI', FileHash(paths[3]) = h0,
    'hash degisti mi');

  { ---------- F: v2 dosyasi ve taninmayan sihirli sayi ---------- }
  paths[4] := D + 'fc_v2magic.odb';
  CopyDb(Base, paths[4]);
  PatchHeader(paths[4], True, VDB_V2_MAGIC, False, 0, False, 0, True);
  ok := Probe(paths[4], True, n, rep, verified, err);
  Chk('FC-F1 v2 dosyasi net goc hatasi verir',
    (not ok) and Has(err, 'v2 formati') and Has(err, 'MIGRATE TO v3'),
    'hata=' + err);

  paths[5] := D + 'fc_badmagic.odb';
  CopyDb(Base, paths[5]);
  PatchHeader(paths[5], True, $12345678, False, 0, False, 0, True);
  ok := Probe(paths[5], True, n, rep, verified, err);
  Chk('FC-F2 taninmayan sihirli sayi REDDEDILIR',
    (not ok) and Has(err, 'gecersiz dosya sihirli sayisi'),
    'hata=' + err);

  { ---------- G: yarim kalmis goc imzasi ----------
    Migrasyon tek 4 KB'lik yerinde baslik yazimidir. Yazim kesilirse
    surum alani yeni degeri tasir ama CRC yazilmamis olur: TAM bu durum
    uretilir. Motor bunu "gecerli" saymamali. }
  paths[6] := D + 'fc_torn.odb';
  CopyDb(Base, paths[6]);
  SetVer(paths[6], VDB_FILE_VER_V4);
  PatchHeader(paths[6], False, 0, True, VDB_FILE_VER, False, 0, False);
  h0 := FileHash(paths[6]);
  ok := Probe(paths[6], True, n, rep, verified, err);
  Chk('FC-G1 yarim goc imzasi REDDEDILIR',
    (not ok) and Has(err, 'CRC tutmadi'),
    'hata=' + err);
  ok := Probe(paths[6], False, n, rep, verified, err);
  Chk('FC-G2 yarim goc imzasi yazilabilir acilista da REDDEDILIR',
    (not ok) and Has(err, 'CRC tutmadi'),
    'hata=' + err);
  Chk('FC-G3 yarim goc dosyasi DEGISMEDI', FileHash(paths[6]) = h0,
    'hash degisti mi');

  { ---------- H: bozuk format ayrimi ---------- }
  paths[7] := D + 'fc_badps.odb';
  CopyDb(Base, paths[7]);
  PatchHeader(paths[7], False, 0, False, 0, True, 8192, True);
  ok := Probe(paths[7], True, n, rep, verified, err);
  Chk('FC-H1 yanlis sayfa boyu REDDEDILIR',
    (not ok) and Has(err, 'sayfa boyu 8192'),
    'hata=' + err);

  CopyDb(Base, D + 'fc_short.odb');
  TruncateTo(D + 'fc_short.odb', VDB_PAGE_SIZE + 512);
  h0 := FileHash(D + 'fc_short.odb');
  ok := Probe(D + 'fc_short.odb', True, n, rep, verified, err);
  Chk('FC-H2 kesik dosya REDDEDILIR',
    (not ok) and Has(err, 'dosya kesik'),
    'hata=' + err);
  Chk('FC-H3 kesik dosyaya DOKUNULMADI',
    (FileHash(D + 'fc_short.odb') = h0) and
    (FileLen(D + 'fc_short.odb') = VDB_PAGE_SIZE + 512),
    'boyut=' + IntToStr(FileLen(D + 'fc_short.odb')));

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
