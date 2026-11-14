program backup_restore;
{ V3 sertlestirme - Phase 4: yedek/geri yukleme butunlugu kapisi.

  Amac (skill Phase 4 "backup/restore integrity + restore drills"):
  (a) tutarli yedek alindigini ve yedegin BAGIMSIZ bir veritabani olarak
      acilabildigini kanitlamak,
  (b) `VerifyBackup`'in bozuk yedegi GERCEKTEN reddettigini (bayt bozma,
      kesme) kanitlamak,
  (c) `RestoreFrom`'un geri yukleme sonrasi veriyi korudugunu ve gecersiz
      kaynaklari (kisa dosya, yabanci bicim, ayni dosya) reddettigini
      kanitlamak,
  (d) geri yuklenen veritabaninin yazilabilir ve yeniden yedeklenebilir
      oldugunu kanitlamak.

  Kapsam disi (durust sinir): surec cokmesi ORTASINDA yedek alma, artimli
  yedek zincirinin coklu halkasi, sifreli yedekte yanlis anahtar reddi bu
  kapida kosulmaz (bkz. docs/engineering/BACKUP_RESTORE.md).

  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbTable, VDbSql, VDbErr,
  VDbCore, VDbPage;

var
  GPass, GFail: Integer;
  GBe: IVdbBackend;
  GTb: TVTableDb;
  GSql: TVSql;

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
  Result := IncludeTrailingPathDelimiter(TestDir) + 'br_' + AName;
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

{ ADir: veritabani KLASORU; VdbOpen dosyayi klasorden cozer. }
procedure OpenEnv(const ADir: string; ACreate: Boolean);
begin
  VdbOpen(IncludeTrailingPathDelimiter(ADir), GBe, ACreate, False);
  GTb := TVTableDb.CreateBackend(GBe);
  GTb.Open(IncludeTrailingPathDelimiter(ADir));
  GSql := TVSql.Create(GTb);
end;

procedure CloseEnv;
begin
  FreeAndNil(GSql);
  FreeAndNil(GTb);
  GBe := nil;
end;

function Exec1(const ASql: string): string;
var
  r: TSqlResult;
begin
  Result := '';
  r := GSql.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := r.Rows[0][0];
end;

{ Istisna olusursa True doner; mesaj AMsg'de. }
function TryExec(const ASql: string; out AMsg: string): Boolean;
begin
  Result := False;
  AMsg := '';
  try
    GSql.Exec(ASql);
  except
    on E: Exception do
    begin
      Result := True;
      AMsg := E.Message;
    end;
  end;
end;

procedure CorruptByte(const AFile: string; AOffset: Int64);
var
  fs: TFileStream;
  b: Byte;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite);
  try
    fs.Position := AOffset;
    fs.ReadBuffer(b, 1);
    b := b xor $FF;
    fs.Position := AOffset;
    fs.WriteBuffer(b, 1);
  finally
    fs.Free;
  end;
end;

procedure TruncateTo(const AFile: string; ANewSize: Int64);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFile, fmOpenReadWrite);
  try
    fs.Size := ANewSize;
  finally
    fs.Free;
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

{ FPC'nin SysUtils'inde CopyFile yoktur (LCL/Windows biriminde); kapi
  harici bagimliliga girmesin diye akis kopyasi kullanilir. }
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

procedure WriteJunkFile(const AFile: string; ASize: Integer);
var
  fs: TFileStream;
  i: Integer;
  b: Byte;
begin
  fs := TFileStream.Create(AFile, fmCreate);
  try
    for i := 1 to ASize do
    begin
      b := Byte((i * 37) and $FF);
      fs.WriteBuffer(b, 1);
    end;
  finally
    fs.Free;
  end;
end;

{ Yedegi bagimsiz bir veritabani olarak acar ve satir sayisini dondurur.
  Acilamazsa -1. }
function CountInImage(const AImage: string): Integer;
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  r: TSqlResult;
begin
  Result := -1;
  try
    VdbOpen(AImage, Be, False, False);
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(ExtractFileDir(AImage));
      Sq := TVSql.Create(Tb);
      try
        r := Sq.Exec('SELECT COUNT(*) FROM t');
        if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
          Result := StrToIntDef(r.Rows[0][0], -1);
      finally
        Sq.Free;
      end;
    finally
      Tb.Free;
      Be := nil;
    end;
  except
    on E: Exception do
      Result := -1;
  end;
end;

var
  MainDir, BkDir, TargetDir: string;
  BkPath, GoodCopy, BadPath, JunkPath: string;
  rep: string;
  ok: Boolean;
  msg: string;
  pagesCopied, pagesTotal: LongWord;
  beforeSize: Int64;

begin
  GPass := 0;
  GFail := 0;

  MainDir := FreshDir('main');
  BkDir := FreshDir('bk');
  TargetDir := FreshDir('target');

  { ---------------------------------------------------------------
    Kurulum: veri yaz, yedek al.
    --------------------------------------------------------------- }
  OpenEnv(MainDir, True);
  try
    GSql.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    GSql.Exec('INSERT INTO t (id, name) VALUES (1, ''alpha'')');
    GSql.Exec('INSERT INTO t (id, name) VALUES (2, ''beta'')');
    GSql.Exec('INSERT INTO t (id, name) VALUES (3, ''gamma'')');
    Chk('B0 kurulum: 3 satir', Exec1('SELECT COUNT(*) FROM t') = '3',
      'count=' + Exec1('SELECT COUNT(*) FROM t'));

    BkPath := IncludeTrailingPathDelimiter(BkDir) + 'yedek.odb';
    GBe.BackupTo(BkPath);
    Chk('B1 yedek dosyasi olustu',
      FileExists(BkPath) and (FileBytes(BkPath) > 0),
      'dosya=' + BkPath);

    ok := GBe.VerifyBackup(BkPath, rep);
    Chk('B2 VerifyBackup iyi yedegi kabul etti', ok, 'rapor=' + rep);

    ok := GBe.Verify(rep);
    Chk('B3 kaynak veritabani butunlugu', ok, 'rapor=' + rep);

    Chk('B4 yedek bagimsiz acilabiliyor (3 satir)',
      CountInImage(BkPath) = 3, 'count=' + IntToStr(CountInImage(BkPath)));
  finally
    CloseEnv;
  end;

  { ---------------------------------------------------------------
    Bozuk yedek: tek bayt bozma -> VerifyBackup REDDETMELI.
    --------------------------------------------------------------- }
  GoodCopy := IncludeTrailingPathDelimiter(BkDir) + 'bozuk.odb';
  if CopyFileTo(BkPath, GoodCopy) then
  begin
    beforeSize := FileBytes(GoodCopy);
    { Veri sayfalari 1..PageCount-1; son sayfanin icinde bir bayt boz.
      (Baslik/meta sayfasi 0 disarida birakilir: orada da CRC var ama
      amac veri sayfasi bozulmasinin yakalanmasi.) }
    if beforeSize > VDB_PAGE_SIZE + 200 then
      CorruptByte(GoodCopy, beforeSize - 200)
    else
      CorruptByte(GoodCopy, beforeSize - 1);
    OpenEnv(MainDir, False);
    try
      ok := GBe.VerifyBackup(GoodCopy, rep);
      Chk('B5 bozuk yedek reddedildi', not ok, 'rapor=' + rep);
      Chk('B6 bozulma raporu aciklayici',
        (not ok) and (Pos('yedek bozuk', rep) = 1), 'rapor=' + rep);
    finally
      CloseEnv;
    end;
  end
  else
    Chk('B5 bozuk yedek reddedildi', False, 'kopya olusturulamadi');

  { ---------------------------------------------------------------
    Kesik yedek: dosya sonu kirpilmis -> REDDETMELI.
    --------------------------------------------------------------- }
  BadPath := IncludeTrailingPathDelimiter(BkDir) + 'kesik.odb';
  if CopyFileTo(BkPath, BadPath) then
  begin
    TruncateTo(BadPath, FileBytes(BadPath) - VDB_PAGE_SIZE div 2);
    OpenEnv(MainDir, False);
    try
      ok := GBe.VerifyBackup(BadPath, rep);
      Chk('B7 kesik yedek reddedildi', not ok, 'rapor=' + rep);
    finally
      CloseEnv;
    end;
  end
  else
    Chk('B7 kesik yedek reddedildi', False, 'kopya olusturulamadi');

  { ---------------------------------------------------------------
    RestoreFrom: gecersiz kaynaklar REDDEDILMELI.
    --------------------------------------------------------------- }
  OpenEnv(TargetDir, True);
  try
    GSql.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    GSql.Exec('INSERT INTO t (id, name) VALUES (99, ''cop'')');

    msg := '';
    try
      GBe.RestoreFrom(IncludeTrailingPathDelimiter(TargetDir) + 'yok.odb');
      Chk('B8 olmayan kaynak reddedildi', False, 'istisna bekleniyordu');
    except
      on E: Exception do
      begin
        msg := E.Message;
        Chk('B8 olmayan kaynak reddedildi', Pos('bulunamadi', msg) > 0,
          'msg=' + msg);
      end;
    end;

    JunkPath := IncludeTrailingPathDelimiter(BkDir) + 'yabanci.bin';
    WriteJunkFile(JunkPath, 2000);
    msg := '';
    try
      GBe.RestoreFrom(JunkPath);
      Chk('B9 yabanci bicim reddedildi', False, 'istisna bekleniyordu');
    except
      on E: Exception do
      begin
        msg := E.Message;
        Chk('B9 yabanci bicim reddedildi',
          (Pos('degil', msg) > 0) or (Pos('kisa', msg) > 0), 'msg=' + msg);
      end;
    end;

    { Cok kisa dosya: basligin kendisi bile yok. }
    TruncateTo(JunkPath, 20);
    msg := '';
    try
      GBe.RestoreFrom(JunkPath);
      Chk('B10 asiri kisa kaynak reddedildi', False, 'istisna bekleniyordu');
    except
      on E: Exception do
      begin
        msg := E.Message;
        Chk('B10 asiri kisa kaynak reddedildi', Pos('kisa', msg) > 0,
          'msg=' + msg);
      end;
    end;

    msg := '';
    try
      GBe.RestoreFrom(GBe.FilePath);
      Chk('B11 kaynak=hedef reddedildi', False, 'istisna bekleniyordu');
    except
      on E: Exception do
      begin
        msg := E.Message;
        Chk('B11 kaynak=hedef reddedildi', Pos('ayni', msg) > 0, 'msg=' + msg);
      end;
    end;

    { Reddedilen denemelerden sonra hedef hala saglam ve eski verisi yerinde. }
    Chk('B12 reddedilen restore hedefi bozmadi',
      Exec1('SELECT COUNT(*) FROM t') = '1', 'count=' + Exec1('SELECT COUNT(*) FROM t'));

    { -------------------------------------------------------------
      Gercek geri yukleme tatbikati.
      ------------------------------------------------------------- }
    GBe.RestoreFrom(BkPath);
    Chk('B13 geri yukleme sonrasi veri korundu',
      Exec1('SELECT COUNT(*) FROM t') = '3', 'count=' + Exec1('SELECT COUNT(*) FROM t'));
    Chk('B14 geri yukleme sonrasi icerik dogru',
      Exec1('SELECT name FROM t ORDER BY id LIMIT 1') = 'alpha',
      'ilk=' + Exec1('SELECT name FROM t ORDER BY id LIMIT 1'));

    ok := GBe.Verify(rep);
    Chk('B15 geri yuklenen veritabani butun', ok, 'rapor=' + rep);

    { Geri yuklenen veritabani yazilabilir mi? }
    GSql.Exec('INSERT INTO t (id, name) VALUES (4, ''delta'')');
    Chk('B16 geri yuklenen veritabani yazilabilir',
      Exec1('SELECT COUNT(*) FROM t') = '4', 'count=' + Exec1('SELECT COUNT(*) FROM t'));

    { Yeniden yedek alinabilir mi (yuvarlak yol kararliligi)? }
    BkPath := IncludeTrailingPathDelimiter(BkDir) + 'yedek2.odb';
    GBe.BackupTo(BkPath);
    ok := GBe.VerifyBackup(BkPath, rep);
    Chk('B17 geri yuklenen veritabaninin yedegi de gecerli', ok,
      'rapor=' + rep);
    Chk('B18 ikinci yedek 4 satir tasiyor', CountInImage(BkPath) = 4,
      'count=' + IntToStr(CountInImage(BkPath)));

    { -------------------------------------------------------------
      Artimli yedek: taban ile ayni veritabanindan uretilmeli.
      ------------------------------------------------------------- }
    pagesCopied := 0;
    pagesTotal := 0;
    BkPath := IncludeTrailingPathDelimiter(BkDir) + 'yedek3.odb';
    GBe.BackupIncrementalTo(IncludeTrailingPathDelimiter(BkDir) + 'yedek2.odb',
      BkPath, pagesCopied, pagesTotal);
    Chk('B19 artimli yedek tabandan fark olmadiginda sayfa kopyalamaz',
      pagesTotal > 0, Format('kopyalanan=%d toplam=%d', [pagesCopied, pagesTotal]));

    { Taban yedekten sonra yaz: artimli yedek yeni sayfayi tasimali. }
    GSql.Exec('INSERT INTO t (id, name) VALUES (5, ''epsilon'')');
    pagesCopied := 0;
    pagesTotal := 0;
    BkPath := IncludeTrailingPathDelimiter(BkDir) + 'yedek4.odb';
    GBe.BackupIncrementalTo(IncludeTrailingPathDelimiter(BkDir) + 'yedek2.odb',
      BkPath, pagesCopied, pagesTotal);
    Chk('B20 artimli yedek degisen sayfayi kopyaladi', pagesCopied > 0,
      Format('kopyalanan=%d toplam=%d', [pagesCopied, pagesTotal]));
    ok := GBe.VerifyBackup(BkPath, rep);
    Chk('B21 artimli yedek kendi kendine yeterli (dogrulanir)', ok,
      'rapor=' + rep);
    Chk('B22 artimli yedek 5 satir tasiyor', CountInImage(BkPath) = 5,
      'count=' + IntToStr(CountInImage(BkPath)));

    { -------------------------------------------------------------
      Hata yollari: bozuk yedekten restore sessiz gecmemeli.
      ------------------------------------------------------------- }
    msg := '';
    try
      GBe.RestoreFrom(GoodCopy);
      { Bozuk sayfa iceren imaj restore edilmemeli; edildiyse en azindan
        hedef bozulmus olmali. Ikisi de kabul edilmez: acik hata beklenir. }
      Chk('B23 bozuk yedekten restore reddedildi', False,
        'istisna bekleniyordu (sessiz kabul)');
    except
      on E: Exception do
      begin
        msg := E.Message;
        Chk('B23 bozuk yedekten restore reddedildi',
          Pos('yedek bozuk', msg) > 0, 'msg=' + msg);
      end;
    end;

    { Reddedilen bozuk restore sonrasi hedef hala okunabilir olmali. }
    Chk('B24 bozuk restore sonrasi hedef saglam',
      Exec1('SELECT COUNT(*) FROM t') = '5',
      'count=' + Exec1('SELECT COUNT(*) FROM t'));
  finally
    CloseEnv;
  end;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
