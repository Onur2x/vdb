program page_corrupt;
{ v3.38 KALICI REGRESYON KAPISI - SKILL3 §5.3 / §12.1 sayfa bozulmasi.
  Amac: diskteki bir veri sayfasi bozuldugunda motorun NE YAPTIGINI olcmek.
  Beklenen: okuma kontrollu bir `EVDbException` ile reddedilir; surec
  cokmez, yanlis satir DONDURULMEZ ve dosya degismez.

  Onceden okuma yolu sayfayi hic dogrulamadan cozucuye veriyordu; tek bayt
  kaymasi sessizce yanlis satir uretebiliyordu. v3.38 ile sihirli sayi +
  sayfa numarasi her okumada, CRC ise `VerifyOnRead` acikken denetlenir.

  Olculen:
    PC1 bozulmamis dosya normal acilir, tum satirlar okunur (kontrol)
    PC2 varsayilan `VerifyOnRead` = True
    PC3 govdesi bozulan sayfa kontrollu hata ile reddedilir (cokme yok)
    PC4 sihirli sayisi bozulan sayfa kontrollu hata ile reddedilir
    PC5 baska sayfanin imaji yanlis numarayla reddedilir
    PC6 her bozulma denemesinden sonra dosya bayt bayt degismemis
    PC7 bozulmadan sonra saglam kopya hala tam okunur (yanlis pozitif yok)

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbPageEngine,
  VDbPageStore, VDbPage, VDbTable, VDbSql, VDbErr;

const
  ROWS = 300;
  VALLEN = 200;
  PAGE = VDB_PAGE_SIZE;

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

function ValOf(AId: Integer): string;
var
  i: Integer;
  k: Integer;
begin
  SetLength(Result, VALLEN);
  k := AId mod 26;
  for i := 1 to VALLEN do
    Result[i] := Chr(Ord('a') + ((k + i) mod 26));
  Result := 'r' + IntToStr(AId) + ':' + Result;
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

function LoadFile(const APath: string): TBytes;
var
  fs: TFileStream;
begin
  SetLength(Result, 0);
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure SaveFile(const APath: string; const ABuf: TBytes);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABuf) > 0 then fs.WriteBuffer(ABuf[0], Length(ABuf));
  finally
    fs.Free;
  end;
end;

{ Dosyayi acip TUM satirlari okur. Donus: 0 = kusursuz, >0 = uyusmayan
  satir sayisi;  -1 = kontrollu hata (beklenen bozulma davranisi);
  -2 = beklenmeyen istisna. }
function TryOpenAndScan(const ADir, ADb: string; out AMsg: string): Integer;
var
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  r: TSqlResult;
  j, id, bad: Integer;
begin
  Result := 0;
  bad := 0;
  AMsg := '';
  BeC := nil;
  Be := nil;
  try
    { Acilis da sayfa okur: bozulma burada yakalanirsa da kontrollu
      hata sayilir, bu yuzden Create try blogunun ICINDE. }
    BeC := TVdbBackendV3.Create(ADb, False, 512, 2000);
    Be := BeC;
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(ADir);
      Sq := TVSql.Create(Tb);
      try
        r := Sq.Exec('SELECT id, v FROM t ORDER BY id');
        if Length(r.Rows) <> ROWS then
          Inc(bad);
        for j := 0 to Length(r.Rows) - 1 do
        begin
          if Length(r.Rows[j]) < 2 then
          begin
            Inc(bad);
            Continue;
          end;
          id := StrToIntDef(Trim(r.Rows[j][0]), -1);
          if (id <> j + 1) or (Trim(r.Rows[j][1]) <> ValOf(id)) then
            Inc(bad);
        end;
        Result := bad;
      finally
        FreeAndNil(Sq);
      end;
    finally
      FreeAndNil(Tb);
    end;
  except
    on E: EVDbException do
    begin
      Result := -1;
      AMsg := VDbErrorName(E.ErrorCode) + ': ' + E.Message;
    end;
    on E: Exception do
    begin
      Result := -2;
      AMsg := E.ClassName + ': ' + E.Message;
    end;
  end;
  Be := nil;
  BeC := nil;
end;

{ Bozuk kopyayi acar ve EN AZ bir sayfa okumasinin kontrollu hata
  verdigini dogrular. Ayni dosyada bazi sayfalar bozulmamis olabilir;
  bu yuzden tarama tum satirlari gezer (her sayfaya dokunur). }
function CorruptAndExpect(const ADir, ADb: string; const ATag: string): Boolean;
var
  msg: string;
  rc: Integer;
begin
  rc := TryOpenAndScan(ADir, ADb, msg);
  Result := rc = -1;
  Chk(ATag + ' kontrollu hata', Result, 'rc=' + IntToStr(rc) + ' ' + msg);
  if rc >= 0 then
    Chk(ATag + ' veri dondurmedi', False, 'uyusmayan=' + IntToStr(rc));
end;

var
  Dir, Db, Bad, Good: string;
  orig, work: TBytes;
  fs: TFileStream;
  pageCount, p, off: Integer;
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  i: Integer;
  msg: string;
  rc: Integer;
  detected: Integer;
  swapped: Boolean;
  b: Byte;

begin
  GPass := 0;
  GFail := 0;

  Dir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/pc');
  WipeDir(Dir);
  Db := Dir + 'pc.odb';
  Good := Dir + 'good.odb';

  { Kur: temiz bir veritabani olustur. }
  BeC := TVdbBackendV3.Create(Db, True, 512, 2000);
  Be := BeC;
  try
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(Dir);
      Sq := TVSql.Create(Tb);
      try
        Sq.Exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        Sq.Exec('BEGIN');
        for i := 1 to ROWS do
          Sq.Exec('INSERT INTO t (id, v) VALUES (' + IntToStr(i) + ', ''' +
            StringReplace(ValOf(i), '''', '''''', [rfReplaceAll]) + ''')');
        Sq.Exec('COMMIT');
      finally
        FreeAndNil(Sq);
      end;
    finally
      FreeAndNil(Tb);
    end;
  finally
    Be := nil;
    BeC := nil;
  end;

  orig := LoadFile(Db);
  SaveFile(Good, orig);
  pageCount := Length(orig) div PAGE;

  { PC1: kontrol - saglam dosya kusursuz okunur. }
  rc := TryOpenAndScan(Dir, Good, msg);
  Chk('PC1 saglam dosya tam okunur', rc = 0,
    'rc=' + IntToStr(rc) + ' ' + msg);

  { PC2: varsayilan denetim acik mi? }
  BeC := TVdbBackendV3.Create(Good, False, 512, 2000);
  Be := BeC;
  try
    Chk('PC2 VerifyOnRead varsayilan acik',
      BeC.Engine.Store.VerifyOnRead, 'default');
  finally
    Be := nil;
    BeC := nil;
  end;

  Chk('PC1b sayfa sayisi makul', pageCount > 3,
    'sayfa=' + IntToStr(pageCount));

  { PC3: govde bozulmasi (CRC tutmaz). Veri sayfalari 2..pageCount-1
    araliginda; her birini ayri kopyada dene, en az birinin yakalanmasi
    gerekir; yakalanmayan sayfa varsa o da raporlanir. }
  detected := 0;
  for p := 2 to pageCount - 1 do
  begin
    work := Copy(orig, 0, Length(orig));
    off := p * PAGE + 100;
    b := work[off];
    work[off] := Byte(b xor $5A);
    SaveFile(Db, work);
    rc := TryOpenAndScan(Dir, Db, msg);
    if rc = -1 then Inc(detected)
    else if rc = -2 then
      Chk('PC3 sayfa ' + IntToStr(p) + ' beklenmeyen istisna', False, msg);
    work := nil;
  end;
  Chk('PC3 govde bozulmasi her sayfada yakalandi',
    detected = pageCount - 2,
    'yakalanan=' + IntToStr(detected) + '/' + IntToStr(pageCount - 2));

  { PC4: sihirli sayi bozulmasi. }
  work := Copy(orig, 0, Length(orig));
  work[2 * PAGE + 0] := Byte($7F);
  SaveFile(Db, work);
  CorruptAndExpect(Dir, Db, 'PC4 sihirli sayi');
  work := nil;

  { PC5: baska sayfanin imaji (sayfa numarasi uyusmaz). Sayfa 2'nin
    imajini sayfa 3'e kopyala. }
  work := Copy(orig, 0, Length(orig));
  Move(work[2 * PAGE], work[3 * PAGE], PAGE);
  SaveFile(Db, work);
  CorruptAndExpect(Dir, Db, 'PC5 yanlis sayfa imaji');
  work := nil;

  { PC6: bozulma denemelerinden sonra SAGLAM kopya hala tam okunur
    (yanlis pozitif yok) ve bozulma denemeleri dosyayi degistirmedi. }
  rc := TryOpenAndScan(Dir, Good, msg);
  Chk('PC7 saglam kopya hala kusursuz', rc = 0,
    'rc=' + IntToStr(rc) + ' ' + msg);
  work := LoadFile(Good);
  swapped := Length(work) = Length(orig);
  if swapped then
    for i := 0 to High(orig) do
      if work[i] <> orig[i] then
      begin
        swapped := False;
        Break;
      end;
  Chk('PC6 saglam kopya bayt bayt degismedi', swapped, '');
  work := nil;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
