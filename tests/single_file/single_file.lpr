program single_file;
{ V3 sertlestirme - Phase 6/7: "veri tek dosyada" sozlesmesi kapisi.

  README'ler "tek dosya (.odb)" diyor. Bu kapinin olctugu sey sudur:

    (a) Calisirken bir veritabani dizininde BIRDEN FAZLA dosya olusur:
        <ad>.odb (asil veri), <ad>.odb.wal (cokme kurtarma gunlugu),
        <ad>.odb.idx (acilis onbellegi), <ad>.odb.gen (degisim gunlugu
        taban imaji) ve <ad>.odb.log (degisim gunlugu dizini).
    (b) VERI acisindan tek dosya iddiasi DOGRUDUR: yalnizca <ad>.odb
        kopyalanip baska bir dizine konursa veritabani acilir, sema ve
        satirlar aynen okunur; hatta YAZILABILIR (motor eksik yan
        dosyalari yeniden uretir).
    (c) `BACKUP TO` de tek dosya uretir: yedek tek basina acilir.

  Kapi (b) ve (c)'yi kanitlar; (a)'yi yalnizca RAPORLAR (yan dosyalarin
  varligi bilinclidir, hata degildir). Boylece "tek dosya" ifadesi
  belgede dogru kapsamla yazilabilir: veri tek dosyada, calisma
  durumu (WAL/onbellek/gunluk) yan dosyalarda.

  Derleme: fpc (lpi gerekmez). Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbTable, VDbSql, VDbErr;

var
  GPass, GFail: Integer;

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
          DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function FreshDir(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(TestDir + 'sf_' + AName);
  WipeDir(Result);
  ForceDirectories(Result);
end;

{ Tek dosya kopyalama (FPC'de guvenilir FileCopy yok; akis kullanilir). }
function CopyOne(const ASrc, ADst: string): Boolean;
var
  fi, fo: TFileStream;
  buf: array of Byte;
  got: Integer;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  fi := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    fo := TFileStream.Create(ADst, fmCreate);
    try
      SetLength(buf, 65536);
      repeat
        got := fi.Read(buf[0], Length(buf));
        if got > 0 then
          fo.WriteBuffer(buf[0], got);
      until got <= 0;
      Result := True;
    finally
      fo.Free;
    end;
  finally
    fi.Free;
  end;
end;

{ Bir dizindeki <base>.odb* girdilerini ', ' ile birlestirir (rapor icin). }
function ListArtifacts(const ADir, ABase: string): string;
var
  sr: TSearchRec;
  s: string;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + ABase + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        s := sr.Name;
        if (sr.Attr and faDirectory) <> 0 then s := s + '/';
        if Result <> '' then Result := Result + ', ';
        Result := Result + s;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function CountFiles(const ADir: string): Integer;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ Yalniz ABase ile baslayan artefaktlari sayar (rapor temizligi). }
function CountArtifacts(const ADir, ABase: string): Integer;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + ABase + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function DbFileIn(const ADir: string): string;
var
  sr: TSearchRec;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.odb', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') and
         ((sr.Attr and faDirectory) = 0) then
      begin
        Result := IncludeTrailingPathDelimiter(ADir) + sr.Name;
        Break;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ Acar, COUNT(*) ve tek bir satiri dogrular.
  AFP: veritabani DOSYASININ tam yolu (dizin degil) - yedek farkli adla
  durdugu icin yol acikca verilir. }
function ReadCheck(const AFP, ATag: string; AExpected: Int64): Boolean;
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;
  got: Int64;
begin
  Result := False;
  try
    VdbOpen(AFP, Be, False, True);
  except
    on E: Exception do
    begin
      WriteLn('  ', ATag, ' acilamadi: ', E.ClassName, ': ', E.Message);
      Exit;
    end;
  end;
  try
    Chk(ATag + '/path', FileExists(Be.FilePath), Be.FilePath);
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(ExtractFileDir(Be.FilePath));
      Sq := TVSql.Create(Tb);
      try
        R := Sq.Exec('SELECT COUNT(*) FROM t');
        got := StrToInt64Def(R.Rows[0][0], -1);
        Chk(ATag + '/count', got = AExpected,
          'COUNT=' + IntToStr(got) + ' beklenen=' + IntToStr(AExpected));
        R := Sq.Exec('SELECT v FROM t WHERE id = 1');
        Chk(ATag + '/row1', (Length(R.Rows) = 1) and (R.Rows[0][0] = 'satir-1'),
          'v=' + R.Rows[0][0]);
        Result := True;
      finally
        Sq.Free;
      end;
    finally
      Tb.Free;
    end;
  finally
    Be := nil;
  end;
end;

function WriteMore(const ADir: string; AFrom, ATo: Integer): Boolean;
var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i: Integer;
begin
  Result := False;
  try
    VdbOpen(ADir, Be, False, True);
    try
      Tb := TVTableDb.CreateBackend(Be);
      try
        Tb.Open(ExtractFileDir(Be.FilePath));
        Sq := TVSql.Create(Tb);
        try
          for i := AFrom to ATo do
            Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''satir-' +
              IntToStr(i) + ''')');
          Result := True;
        finally
          Sq.Free;
        end;
      finally
        Tb.Free;
      end;
    finally
      Be := nil;
    end;
  except
    on E: Exception do
      WriteLn('  yazma hatasi: ', E.ClassName, ': ', E.Message);
  end;
end;

var
  d1, d2, d3: string;
  be: IVdbBackend;
  tb: TVTableDb;
  sq: TVSql;
  r: TSqlResult;
  i: Integer;
  src, dst, bk: string;
begin
  GPass := 0;
  GFail := 0;
  ForceDirectories(TestDir);

  { --- 1) Kaynak veritabani: 200 satir --- }
  d1 := FreshDir('src');
  VdbOpen(d1, be, True, True);
  try
    tb := TVTableDb.CreateBackend(be);
    try
      tb.Open(d1);
      sq := TVSql.Create(tb);
      try
        sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        for i := 1 to 200 do
          sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''satir-' +
            IntToStr(i) + ''')');
        r := sq.Exec('SELECT COUNT(*) FROM t');
        Chk('SF1 kaynak olustu', r.Rows[0][0] = '200', 'COUNT=' + r.Rows[0][0]);
      finally
        sq.Free;
      end;
    finally
      tb.Free;
    end;
    { Tek dosya yedek: veritabani ACIKKEN alinir (sozlesme). }
    bk := IncludeTrailingPathDelimiter(d1) + 'yedek.odb';
    try
      be.BackupTo(bk);
      Chk('SF2 BACKUP TO tek dosya uretti', FileExists(bk), bk);
    except
      on E: Exception do
        Chk('SF2 BACKUP TO tek dosya uretti', False, E.ClassName + ': ' + E.Message);
    end;
  finally
    be := nil;
  end;

  { --- 2) Calisirken olusan yan dosyalar (RAPOR, hata degil) --- }
  WriteLn('BILGI kaynak artefaktlar: ',
    ListArtifacts(d1, 'veritabani'));
  Chk('SF3 ana dosya var', FileExists(d1 + 'veritabani.odb'),
    d1 + 'veritabani.odb');
  Chk('SF4 calisirken birden fazla artefakt var',
    CountArtifacts(d1, 'veritabani') > 1,
    'adet=' + IntToStr(CountArtifacts(d1, 'veritabani')));

  { --- 5) YALNIZ .odb kopyasi: baska dizine tek dosya --- }
  d2 := FreshDir('only');
  Chk('SF5 kopya dizini bos basladi', CountFiles(d2) = 0,
    'adet=' + IntToStr(CountFiles(d2)));
  Chk('SF6 tek dosya kopyalandi',
    CopyOne(d1 + 'veritabani.odb', d2 + 'veritabani.odb'),
    d2 + 'veritabani.odb');
  Chk('SF7 kopya dizininde TEK dosya', CountFiles(d2) = 1,
    'adet=' + IntToStr(CountFiles(d2)) + ' -> ' + ListArtifacts(d2, ''));

  { --- 8) Yalniz .odb: okuma --- }
  Chk('SF8 yalniz .odb okunabiliyor',
    ReadCheck(d2 + 'veritabani.odb', 'SF8', 200), '');
  WriteLn('BILGI yalniz-.odb sonrasi artefaktlar: ', ListArtifacts(d2, 'veritabani'));

  { --- 9) Yalniz .odb: yazma (motor eksik yan dosyalari uretir) --- }
  Chk('SF9 yalniz .odb dosyaya yazilabiliyor', WriteMore(d2, 201, 210), '');
  Chk('SF10 yazma sonrasi tekrar acilip dogrulandi',
    ReadCheck(d2 + 'veritabani.odb', 'SF10', 210), '');

  { --- 11) BACKUP TO ciktisi tek basina acilir --- }
  d3 := FreshDir('backup');
  src := bk;
  dst := IncludeTrailingPathDelimiter(d3) + 'yedek.odb';
  Chk('SF11 yedek kopyalandi', CopyOne(src, dst), dst);
  Chk('SF12 yedek dizininde TEK dosya', CountFiles(d3) = 1,
    'adet=' + IntToStr(CountFiles(d3)));
  Chk('SF13 yedek tek basina okunabiliyor',
    ReadCheck(d3 + 'yedek.odb', 'SF13', 200), '');

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail <> 0 then
    Halt(1);
end.
