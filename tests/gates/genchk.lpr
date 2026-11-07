program genchk;
{ P-139 kapisi.
  Bolum 1 (C-2): `.gen` ile DB kimligi eslesmesi ve durabil LSN'in
    gecersiz kilinmasi. Silinip yeniden olusturulan ya da baska bir
    dosyayla degistirilen veritabaninda eski yuksek durabil LSN
    KULLANILMAMALI.
  Bolum 2 (B-06): FAlien (yabanci commit defteri) denetimi before-image
    OLAN anahtarlarda da calismali; aksi halde kaybolan guncelleme olur.
    Iyimser oturum, `.gen` rezervasyon kilidi ayri bir handle ile
    tutularak zorlanir; iki oturum da before-image kaydeder.
  Kullanim: genchk <dizin> }
{$mode delphi}{$H+}
uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  VDbBackendApi, VDbBackendV3, VDbPageStore, VDbSync,
  VDbCore, VDbTable, VDbSql, VDbTypes, VDbExecutor;

const
  { Testte yazilan bayat durabil LSN; gercek commit LSN'lerinden cok buyuk. }
  STALE_DUR = LongWord($B0000000);

var
  gSid: Cardinal = 0;
  gPass: Integer = 0;
  gFail: Integer = 0;

function SidFunc: Cardinal;
begin
  Result := gSid;
end;

procedure Ok(const Ad: string; Kosul: Boolean; const Ayrinti: string);
begin
  if Kosul then
  begin
    Inc(gPass);
    WriteLn('   OK   ', Ad, '   [', Ayrinti, ']');
  end
  else
  begin
    Inc(gFail);
    WriteLn('   FAIL ', Ad, '   [', Ayrinti, ']');
  end;
end;

function B(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function S(const V: TBytes): string;
begin
  SetLength(Result, Length(V));
  if Length(V) > 0 then Move(V[0], Result[1], Length(V));
end;

function Oku(be: TVdbBackendV3; K: QWord): string;
var v: TBytes;
begin
  if be.Get(K, v) then Result := S(v) else Result := '<yok>';
end;

{ .gen: 0 = gen sayaci (QWord), 8 = durabil LSN (LongWord), 16 = DB kimligi. }
procedure ReadGenFile(const Path: string; out Sayac: QWord;
  out Durabil: LongWord; out Kimlik: QWord);
var
  fs: TFileStream;
  z: LongWord;
begin
  Sayac := 0; Durabil := 0; Kimlik := 0;
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size >= 8 then
    begin
      fs.Position := 0;
      fs.ReadBuffer(Sayac, 8);
    end;
    if fs.Size >= 12 then
    begin
      fs.Position := 8;
      fs.ReadBuffer(z, 4);
      Durabil := z;
    end;
    if fs.Size >= VDB_GEN_ID_OFF + 8 then
    begin
      fs.Position := VDB_GEN_ID_OFF;
      fs.ReadBuffer(Kimlik, 8);
    end;
  finally
    fs.Free;
  end;
end;

procedure WriteStaleDurable(const Path: string; V: LongWord);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmOpenReadWrite or fmShareDenyNone);
  try
    fs.Position := 8;
    fs.WriteBuffer(V, 4);
  finally
    fs.Free;
  end;
end;

procedure SilDosya(const Path: string);
begin
  if FileExists(Path) then DeleteFile(Path);
end;

procedure KopyalaDosya(const Kaynak, Hedef: string);
var
  src, dst: TFileStream;
begin
  src := TFileStream.Create(Kaynak, fmOpenRead or fmShareDenyNone);
  try
    dst := TFileStream.Create(Hedef, fmCreate);
    try
      dst.CopyFrom(src, 0);
    finally
      dst.Free;
    end;
  finally
    src.Free;
  end;
end;

procedure SilYanDosyalar(const Db: string);
begin
  SilDosya(Db + '.wal');
  SilDosya(Db + '.idx');
  SilDosya(Db + '.undo');
end;

{ --------------------------------------------------- Bolum 1: C-2 }

procedure BolumC2(const Dir: string);
var
  db, gen: string;
  be: TVdbBackendV3;
  sayac1, sayac2, id1, id2, id3, id4: QWord;
  dur1, dur2, dur3, dur4: LongWord;
  oncekiFail: Integer;
  db2, wal2: string;
begin
  WriteLn('--- C-2: DB nesli / durabil LSN ---');
  oncekiFail := gFail;
  db := IncludeTrailingPathDelimiter(Dir) + 'c2a.odb';
  gen := db + '.gen';
  SilYanDosyalar(db);
  SilDosya(gen);
  SilDosya(db);

  { 1) Ilk olusturma + commit: `.gen` 24 bayt, kimlik ve durabil LSN dolu. }
  be := TVdbBackendV3.Create(db, True, 512);
  try
    be.BeginBatch;
    be.Put(1, B('a'));
    be.Put(2, B('b'));
    be.CommitBatch;
  finally
    be.Free;
  end;
  ReadGenFile(gen, sayac1, dur1, id1);
  Ok('yeni DB kimligi uretildi', id1 <> 0, Format('$%.16x', [id1]));
  Ok('commit sonrasi durabil LSN > 0', dur1 > 0, IntToStr(dur1));

  { 2) Ayni dosyayi yeniden acmak kimligi DEGISTIRMEMELI ve durabil LSN'i
    sifirlamamali. }
  be := TVdbBackendV3.Create(db, False, 512);
  be.Free;
  ReadGenFile(gen, sayac2, dur2, id2);
  Ok('yeniden acilista kimlik korunur', id2 = id1,
    Format('$%.16x / $%.16x', [id2, id1]));
  Ok('yeniden acilista durabil LSN korunur', (dur2 > 0) and (dur2 >= dur1),
    IntToStr(dur2));

  { 3) Bayat yuksek LSN yaz; DB dosyasini sil, `.gen` KALSIN; yeniden
    olustur. Kimlik degismeli, durabil LSN kalici olarak sifirlanmali. }
  WriteStaleDurable(gen, STALE_DUR);
  SilYanDosyalar(db);
  SilDosya(db);
  be := TVdbBackendV3.Create(db, True, 512);
  try
    be.BeginBatch;
    be.Put(1, B('yeni'));
    be.CommitBatch;
  finally
    be.Free;
  end;
  ReadGenFile(gen, sayac2, dur3, id3);
  Ok('yeniden olusturulan DB yeni kimlik aldi', (id3 <> 0) and (id3 <> id1),
    Format('$%.16x / eski $%.16x', [id3, id1]));
  Ok('bayat durabil LSN sifirlandi, commit sonrasi kucuk LSN',
    (dur3 > 0) and (dur3 < STALE_DUR),
    Format('%d (bayat %d)', [dur3, STALE_DUR]));

  { 4) Baska bir veritabaninin dosyasi, eski `.gen` korunarak yerine
    konursa: kimlik uyusmaz -> durabil LSN gecersiz. }
  db2 := IncludeTrailingPathDelimiter(Dir) + 'c2b.odb';
  wal2 := db2 + '.gen';
  SilYanDosyalar(db2);
  SilDosya(wal2);
  SilDosya(db2);
  be := TVdbBackendV3.Create(db2, True, 512);
  try
    be.BeginBatch;
    be.Put(1, B('baska'));
    be.CommitBatch;
  finally
    be.Free;
  end;
  WriteStaleDurable(gen, STALE_DUR);
  SilYanDosyalar(db);
  SilDosya(db);
  KopyalaDosya(db2, db);
  be := TVdbBackendV3.Create(db, False, 512);
  be.Free;
  ReadGenFile(gen, sayac2, dur4, id4);
  Ok('degistirilen DB dosyasinin kimligi benimsendi', id4 <> id3,
    Format('$%.16x / eski $%.16x', [id4, id3]));
  Ok('kimlik uyusmazliginda bayat durabil LSN sifirlandi',
    dur4 < STALE_DUR, Format('%d (bayat %d)', [dur4, STALE_DUR]));

  if gFail = oncekiFail then
    WriteLn('DB NESLI VE DURABIL LSN DOGRULANDI')
  else
    WriteLn('DB NESLI VE DURABIL LSN DOGRULANAMADI');
end;

{ --------------------------------------------------- Bolum 2: B-06 }

procedure BolumB06(const Dir: string);
var
  db, gen: string;
  be: TVdbBackendV3;
  cakisti: Boolean;
  msg: string;
  oncekiFail: Integer;
begin
  WriteLn('--- B-06: FAlien cakisma denetimi ---');
  oncekiFail := gFail;
  db := IncludeTrailingPathDelimiter(Dir) + 'b06.odb';
  gen := db + '.gen';
  SilYanDosyalar(db);
  SilDosya(gen);
  SilDosya(db);
  be := TVdbBackendV3.Create(db, True, 512);
  try
    gSid := 0;
    be.BeginBatch;
    be.Put(1, B('v0'));
    be.Put(2, B('sabit'));
    be.CommitBatch;

    { B-06 senaryosu (tek surec, uc oturum). Before-image'in YAKALAMA
      NESLI ile yabanci commit sirasi ayirt edilir:

      (a) Yabanci commit before-image'den SONRA gelirse deger artik
          gecersizdir; commit DURMALIDIR. Deger karsilastirmasi bunu
          cogunlukla yakalar; ABA durumunda (yabanci commit AYNI degeri
          yeniden yazdi) yakalayamaz -- nesil kesin ayirir. }

    gSid := 1;
    be.BeginBatch;
    be.Put(3, B('s1'));             // ilgisiz yazim (abort ile geri donmeli)
    gSid := 2;
    be.BeginBatch;
    be.Put(2, B('x'));
    be.CommitBatch;                 // S1'i before-image'e zorlar, FAlien[2]
    gSid := 1;
    be.Put(1, B('v1'));             // before-image = v0, CapGen = g1
    gSid := 3;
    be.BeginBatch;
    be.Put(1, B('v0'));             // ABA: ayni deger yeniden yazilir
    be.CommitBatch;                 // FAlien[1] = g2 > CapGen
    gSid := 1;
    cakisti := False;
    msg := '';
    try
      be.CommitBatch;               // nesil denetimi cakisma vermeli
    except
      on E: Exception do
      begin
        msg := E.Message;
        cakisti := Pos('cakisma', msg) > 0;
      end;
    end;
    Ok('capture sonrasi yabanci commit (ABA) cakisma verir', cakisti, msg);
    be.AbortBatch;
    gSid := 0;
    Ok('S1 yazimi uygulanmadi (deger v0)', Oku(be, 1) = 'v0', Oku(be, 1));
    Ok('S1 ilgisiz yazimi geri alindi', Oku(be, 3) = '<yok>', Oku(be, 3));

    { (b) v3.6/v3sqlchk 4b semantigi: yabanci commit before-image'den
          ONCE geldiyse oturum yeni degeri gorur; cakisma YOKTUR ve son
          yazar kazanir. }
    gSid := 1;
    be.BeginBatch;
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('v5'));
    be.CommitBatch;                 // S1'i uyarir, FAlien[1] = g
    gSid := 1;
    be.Put(1, B('v6'));             // before-image = v5, CapGen = g
    cakisti := False;
    msg := '';
    try
      be.CommitBatch;
    except
      on E: Exception do
      begin
        msg := E.Message;
        cakisti := Pos('cakisma', msg) > 0;
      end;
    end;
    Ok('capture oncesi yabanci commit cakisma VERMEZ (4b)', not cakisti, msg);
    gSid := 0;
    Ok('son yazar degeri korunur', Oku(be, 1) = 'v6', Oku(be, 1));

    { Kontrol: cakisma yokken tek oturumluk commit calisir (yanlis pozitif
      yok). }
    gSid := 0;
    be.BeginBatch;
    be.Put(3, B('son'));
    be.CommitBatch;
    Ok('kontrol: temiz commit basarili', Oku(be, 3) = 'son', Oku(be, 3));
  finally
    gSid := 0;
    be.Free;
  end;

  if gFail = oncekiFail then
    WriteLn('FALIEN CAKISMA DENETIMI DOGRULANDI')
  else
    WriteLn('FALIEN CAKISMA DENETIMI DOGRULANAMADI');
end;

{ --------------------------------------------------- Bolum 3: R-yeni }

function ScanSayCb(Key: QWord; Buf: PByte; Len: Integer;
  User: Pointer): Boolean;
begin
  Result := True;
end;

{ Commit dener. Cakisma hatasi alinirsa True ve hata metni doner. }
function CommitCakisma(be: TVdbBackendV3; out msg: string): Boolean;
begin
  Result := False;
  msg := '';
  try
    be.CommitBatch;
  except
    on E: Exception do
    begin
      msg := E.Message;
      Result := Pos('cakisma', msg) > 0;
    end;
  end;
end;

procedure BolumReadSet(const Dir: string);
var
  db, gen: string;
  be: TVdbBackendV3;
  cakisti: Boolean;
  msg: string;
  oncekiFail: Integer;
begin
  WriteLn('--- R-yeni: okuma kumesi penceresi ---');
  oncekiFail := gFail;
  db := IncludeTrailingPathDelimiter(Dir) + 'rset.odb';
  gen := db + '.gen';
  SilYanDosyalar(db);
  SilDosya(gen);
  SilDosya(db);
  be := TVdbBackendV3.Create(db, True, 512);
  try
    gSid := 0;
    be.BeginBatch;
    be.Put(1, B('v0'));
    be.Put(2, B('sabit'));
    be.Put(3, B('uc'));
    be.CommitBatch;

    { 1) PENCERE KAPANMALI: S1 K'yi G0'da okur; S2 G0+1'de commit eder;
      S1 Put aninda before-image S2'nin degerini (v1) yakalar. Deger
      karsilastirmasi esit gorunse de OKUMA NESLI esigi yakalar. }
    gSid := 1;
    be.BeginBatch;
    Ok('1: S1 okumasi v0', Oku(be, 1) = 'v0', Oku(be, 1));
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('v1'));
    be.CommitBatch;
    gSid := 1;
    be.Put(1, B('v2'));
    cakisti := CommitCakisma(be, msg);
    Ok('1: read->NoteBefore penceresi cakisma verir', cakisti, msg);
    be.AbortBatch;
    gSid := 0;
    Ok('1: S1 yazimi uygulanmadi (v1 korunur)', Oku(be, 1) = 'v1', Oku(be, 1));

    { 2) 4b KORUNUR: S1 once yabanci commit'i gorur, SONRA yazar; okuma
      nesli yabanci commit nesline esit oldugu icin cakisma YOK. S1'in
      okuma goruntusu StartGen'e sabitlendigi icin okunan DEGER eski
      anlik goruntudur (v1); onemli olan esigin cakismamasi. }
    gSid := 1;
    be.BeginBatch;
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('v3'));
    be.CommitBatch;
    gSid := 1;
    Ok('2: S1 sabitlenmis anlik goruntu degerini gorur (v1)',
      Oku(be, 1) = 'v1', Oku(be, 1));
    be.Put(1, B('v4'));
    cakisti := CommitCakisma(be, msg);
    Ok('2: okuma yabanci commit SONRASI ise cakisma yok',
      (not cakisti) and (msg = ''), msg);
    if cakisti then be.AbortBatch;
    gSid := 0;
    Ok('2: son yazar degeri korunur', Oku(be, 1) = 'v4', Oku(be, 1));

    { 3) ANAHTAR HASSASIYETI: S1 baska bir anahtari (3) okur; anahtar 1'i
      okumadan yazar. Yanlis pozitif olmamali. }
    gSid := 1;
    be.BeginBatch;
    Ok('3: S1 baska anahtari okur', Oku(be, 3) = 'uc', Oku(be, 3));
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('v5'));
    be.CommitBatch;
    gSid := 1;
    be.Put(1, B('v6'));
    cakisti := CommitCakisma(be, msg);
    Ok('3: okunmayan anahtar cakisma VERMEZ',
      (not cakisti) and (msg = ''), msg);
    if cakisti then be.AbortBatch;
    gSid := 0;
    Ok('3: blind write degeri korunur', Oku(be, 1) = 'v6', Oku(be, 1));

    { 4) OKUMA YOKSA DAVRANIS AYNI: ReadGen bos, ScanGen = -1 -> eski
      CapGen yolu (blind write son yazar kazanir). }
    gSid := 1;
    be.BeginBatch;
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('v7'));
    be.CommitBatch;
    gSid := 1;
    be.Put(1, B('v8'));
    cakisti := CommitCakisma(be, msg);
    Ok('4: okuma yoksa eski davranis (cakisma yok)',
      (not cakisti) and (msg = ''), msg);
    if cakisti then be.AbortBatch;
    gSid := 0;
    Ok('4: son yazar degeri korunur', Oku(be, 1) = 'v8', Oku(be, 1));

    { 5) SCANGEN (ikinci katman): S1 write-set acikken tarar; tarama
      nesli G0. S2 G0+1'de commit eder; S1 blind write yapsa bile
      konservatif cakisma beklenir. }
    gSid := 1;
    be.BeginBatch;
    cakisti := be.ScanRawIterAll(-1, @ScanSayCb, nil);
    Ok('5: S1 write-set acikken tarama basarili', cakisti, '');
    gSid := 2;
    be.BeginBatch;
    be.Put(1, B('v9'));
    be.CommitBatch;
    gSid := 1;
    be.Put(1, B('v10'));
    cakisti := CommitCakisma(be, msg);
    Ok('5: tarama sonrasi yabanci commit cakisma verir', cakisti, msg);
    be.AbortBatch;
    gSid := 0;
    Ok('5: S1 yazimi uygulanmadi (v9 korunur)', Oku(be, 1) = 'v9', Oku(be, 1));
  finally
    gSid := 0;
    be.Free;
  end;

  if gFail = oncekiFail then
    WriteLn('OKUMA KUMESI PENCERESI DOGRULANDI')
  else
    WriteLn('OKUMA KUMESI PENCERESI DOGRULANAMADI');
end;

{ ------------------------------------------------- Bolum 4: P-145 }

type
  { On-okuma ile yazim arasina deterministik olarak yabanci bir commit
    enjekte eder (ikinci TVSql oturumu). Gercek iplik/zamanlama yerine
    motorun P-145 gozlem noktalarini kullanir. }
  TAutocommitProbe = class
  public
    Etkin: Boolean;
    FireStage: Integer;      { 0 = on-okumadan once, 1 = sonra }
    Did: Boolean;
    S2: TVSql;
    HariciDeger: string;
    procedure Run(Stage: Integer);
  end;

procedure TAutocommitProbe.Run(Stage: Integer);
begin
  if Did or (not Etkin) or (Stage <> FireStage) then Exit;
  Did := True;                       { yeniden giris korumasi }
  gSid := 2;
  try
    { Yabanci oturum ayni satiri gunceller ve commit eder. }
    S2.Exec(Format('UPDATE t SET v=''%s'' WHERE id >= 1', [HariciDeger]));
  finally
    gSid := 1;
  end;
end;

function SqlDene(Sq: TVSql; const Sql: string; out msg: string): Boolean;
begin
  Result := True;
  msg := '';
  try
    Sq.Exec(Sql);
  except
    on E: Exception do
    begin
      Result := False;
      msg := E.Message;
    end;
  end;
end;

function SqlDeger(Sq: TVSql; const Sql: string): string;
var
  r: TSqlResult;
begin
  Result := '<hata>';
  try
    r := Sq.Exec(Sql);
    if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
      Result := r.Rows[0][0]
    else
      Result := '<yok>';
  except
    on E: Exception do Result := '<hata:' + E.Message + '>';
  end;
end;

procedure BolumAutocommit(const Dir: string);
var
  db: string;
  be: IVdbBackend;
  tb1, tb2: TVTableDb;
  sq1, sq2: TVSql;
  pr: TAutocommitProbe;
  cakisti, basarili: Boolean;
  msg: string;
  oncekiFail: Integer;
begin
  WriteLn('--- P-145: autocommit on-okuma penceresi ---');
  oncekiFail := gFail;
  db := IncludeTrailingPathDelimiter(Dir) + 'p145auto.odb';
  SilYanDosyalar(db);
  SilDosya(db + '.gen');
  SilDosya(db);
  gSid := 0;
  be := TVdbBackendV3.Create(db, True, 512);
  tb1 := nil; tb2 := nil; sq1 := nil; sq2 := nil; pr := nil;
  try
    tb1 := TVTableDb.CreateBackend(be);
    tb1.Open(Dir);
    sq1 := TVSql.Create(tb1);
    gSid := 1;
    SqlDene(sq1, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)', msg);
    SqlDene(sq1, 'INSERT INTO t VALUES (1, ''v0'')', msg);
    { Yabanci oturum: ayni backend uzerinde ikinci tablo/SQL nesnesi. }
    tb2 := TVTableDb.CreateBackend(be);
    tb2.Open(Dir);
    sq2 := TVSql.Create(tb2);

    pr := TAutocommitProbe.Create;
    pr.S2 := sq2;
    pr.Etkin := False;

    {$IF DECLARED(VdbDmlProbe)}
    VdbDmlProbe := pr.Run;
    try
      { 1) ANA PENCERE: S1 on-okumayi yapar; hemen ardindan yabanci
        oturum ayni satiri commit eder; S1 sonra yazar. Okuma nesli
        esigi sayesinde CAKISMA beklenir. }
      gSid := 1;
      pr.Etkin := True; pr.FireStage := 1; pr.Did := False;
      pr.HariciDeger := 'v1';
      basarili := SqlDene(sq1, 'UPDATE t SET v=''v2'' WHERE id >= 1', msg);
      cakisti := (not basarili) and (Pos('cakisma', msg) > 0);
      Ok('1: on-okuma->yazim arasi yabanci commit cakisma verir',
        cakisti, msg);
      Ok('1: S1 yazimi uygulanmadi', SqlDeger(sq1,
        'SELECT v FROM t WHERE id = 1') = 'v1',
        SqlDeger(sq1, 'SELECT v FROM t WHERE id = 1'));

      { 2) YANLIS POZITIF KONTROLU: arada yabanci commit YOKKEN ayni
        UPDATE basarili olmali. }
      gSid := 1;
      pr.Etkin := False;
      basarili := SqlDene(sq1, 'UPDATE t SET v=''v3'' WHERE id >= 1', msg);
      Ok('2: yabanci commit yokken ayni UPDATE basarili',
        basarili and (msg = ''), msg);
      Ok('2: kontrol degeri uygulandi', SqlDeger(sq1,
        'SELECT v FROM t WHERE id = 1') = 'v3',
        SqlDeger(sq1, 'SELECT v FROM t WHERE id = 1'));

      { 3) 4b KORUNUR: yabanci commit on-okumadan ONCE ise okuma nesli
        yabanci nesle esitlenir; cakisma YOK. }
      gSid := 1;
      pr.Etkin := True; pr.FireStage := 0; pr.Did := False;
      pr.HariciDeger := 'v4';
      basarili := SqlDene(sq1, 'UPDATE t SET v=''v5'' WHERE id >= 1', msg);
      Ok('3: yabanci commit on-okumadan ONCE ise cakisma yok (4b)',
        basarili and (msg = ''), msg);
      Ok('3: S1 yazimi uygulandi', SqlDeger(sq1,
        'SELECT v FROM t WHERE id = 1') = 'v5',
        SqlDeger(sq1, 'SELECT v FROM t WHERE id = 1'));

      { 4) DELETE AYNI PENCERE (indeks dilimi): on-okuma indeksten
        yapilir; yabanci commit sonrasi cakisma beklenir. }
      gSid := 1;
      pr.Etkin := True; pr.FireStage := 1; pr.Did := False;
      pr.HariciDeger := 'v6';
      basarili := SqlDene(sq1, 'DELETE FROM t WHERE id >= 1', msg);
      Ok('4: probe tetiklendi', pr.Did, BoolToStr(pr.Did, True));
      cakisti := (not basarili) and (Pos('cakisma', msg) > 0);
      Ok('4: DELETE (indeks dilimi) on-okuma penceresi cakisma verir',
        cakisti, msg);
      Ok('4: satir silinmedi', SqlDeger(sq1,
        'SELECT v FROM t WHERE id = 1') = 'v6',
        SqlDeger(sq1, 'SELECT v FROM t WHERE id = 1'));

      { 5) DELETE AYNI PENCERE (tam tarama): WHERE indekslenemez kolonda;
        on-okuma ScanGen ile izlenir; yabanci commit sonrasi cakisma. }
      gSid := 1;
      pr.Etkin := True; pr.FireStage := 1; pr.Did := False;
      pr.HariciDeger := 'v7';
      basarili := SqlDene(sq1, 'DELETE FROM t WHERE v <> ''zzz''', msg);
      cakisti := (not basarili) and (Pos('cakisma', msg) > 0);
      Ok('5: DELETE (tam tarama) on-okuma penceresi cakisma verir',
        cakisti, msg);
      Ok('5: satir silinmedi', SqlDeger(sq1,
        'SELECT v FROM t WHERE id = 1') = 'v7',
        SqlDeger(sq1, 'SELECT v FROM t WHERE id = 1'));
    finally
      VdbDmlProbe := nil;
    end;
    {$ELSE}
    { HEAD (yama oncesi) kaynaginda gozlem noktasi yoktur; senaryo
      deterministik olarak KURULAMAZ. Bolum bilerek FAIL eder. }
    Ok('P-145 on-kosulu: VdbDmlProbe tanimli', False,
      'kaynaka P-145 yamasi uygulanmamis');
    Ok('1: on-okuma->yazim arasi yabanci commit cakisma verir',
      False, 'atlandi (gozlem noktasi yok)');
    Ok('2: yabanci commit yokken ayni UPDATE basarili', False,
      'atlandi (gozlem noktasi yok)');
    Ok('3: yabanci commit on-okumadan ONCE ise cakisma yok (4b)',
      False, 'atlandi (gozlem noktasi yok)');
    Ok('4: DELETE (indeks dilimi) on-okuma penceresi cakisma verir', False,
      'atlandi (gozlem noktasi yok)');
    Ok('5: DELETE (tam tarama) on-okuma penceresi cakisma verir', False,
      'atlandi (gozlem noktasi yok)');
    {$ENDIF}
  finally
    {$IF DECLARED(VdbDmlProbe)}
    VdbDmlProbe := nil;
    {$ENDIF}
    gSid := 0;
    if pr <> nil then pr.Free;
    if sq2 <> nil then sq2.Free;
    if sq1 <> nil then sq1.Free;
    if tb2 <> nil then begin tb2.Close; tb2.Free; end;
    if tb1 <> nil then begin tb1.Close; tb1.Free; end;
    be := nil;
  end;

  if gFail = oncekiFail then
    WriteLn('AUTOCOMMIT ON-OKUMA PENCERESI DOGRULANDI')
  else
    WriteLn('AUTOCOMMIT ON-OKUMA PENCERESI DOGRULANAMADI');
end;

{ ------------------------------------------------- Bolum 5: P-146 }

{ AYRI TVdbBackendV3 ornekleri = ayri motor, ayri onbellek, ayri
  FCommitGen/FAlien ve ayri store handle'i; `.gen` eslemesi ayni fiziksel
  dosya bolumunu paylasir. Ayri surec GEREKMEZ: dosya-bolgesi kilitleri
  surec ayrimi yapmaz, ayni surecteki farkli handle da birbiriyle cakisir
  (tasarim Bolum 5.1). Rezervasyon B'de tutulurken A'nin BeginBatch'i
  iyimser moda duser; FCommitGen/FAlien backend-yerel oldugu icin HEAD'de
  bu pencere sessizce kacar. }
procedure BolumCrossBackend(const Dir: string);
var
  db: string;
  seed, beB, beA: TVdbBackendV3;
  cakisti: Boolean;
  msg: string;
  oncekiFail: Integer;
begin
  WriteLn('--- P-146: surec/backend''ler arasi okuma->yazma penceresi ---');
  oncekiFail := gFail;
  db := IncludeTrailingPathDelimiter(Dir) + 'cxproc.odb';
  SilYanDosyalar(db);
  SilDosya(db + '.gen');
  SilDosya(db);

  { Tohum: K1 = v0, K2 = sabit (tek commit). }
  gSid := 10;
  seed := TVdbBackendV3.Create(db, True, 512);
  try
    seed.BeginBatch;
    seed.Put(1, B('v0'));
    seed.Put(2, B('sabit'));
    seed.CommitBatch;
  finally
    seed.Free;
  end;

  beB := TVdbBackendV3.Create(db, False, 512);
  beA := TVdbBackendV3.Create(db, False, 512);
  try
    { --- Cekirdek: capraz backend ABA penceresi --- }
    { B rezervasyonu tutar; A'nin rezervasyon denemesi basarisiz olur ve
      islem iyimser acilir (LockHoldDepth = 0 bunu dogrular). }
    gSid := 10;
    beB.BeginBatch;
    gSid := 1;
    beA.BeginBatch;
    Ok('1: A iyimser basladi (rezervasyon B''de)',
      beA.Engine.Store.LockHoldDepth = 0,
      IntToStr(beA.Engine.Store.LockHoldDepth));
    Ok('1: A K1=v0 okur', Oku(beA, 1) = 'v0', Oku(beA, 1));
    { B: v0 -> v1 -> v0 (ABA); iki ayri commit, `.gen` iki kez ilerler. }
    gSid := 10;
    beB.Put(1, B('v1'));
    beB.CommitBatch;
    beB.BeginBatch;
    beB.Put(1, B('v0'));
    beB.CommitBatch;
    { A okudugu degeri yazar. Deger karsilastirmasi ABA sonrasi esit gorunur
      (v0); bunu YALNIZCA canli store damgasi ayirt eder. }
    gSid := 1;
    beA.Put(1, B('v2'));
    cakisti := CommitCakisma(beA, msg);
    Ok('1: capraz backend read->write penceresi cakisma verir', cakisti, msg);
    beA.AbortBatch;
    gSid := 10;
    Ok('1: A yazimi uygulanmadi (v0 korunur)', Oku(beA, 1) = 'v0',
      Oku(beA, 1));

    { --- 4b capraz backend: yabanci commit OKUMADAN ONCE --- }
    gSid := 10;
    beB.BeginBatch;
    gSid := 1;
    beA.BeginBatch;
    { B, A'nin okumasindan ONCE ilgisiz anahtari commit eder. }
    gSid := 10;
    beB.Put(2, B('x'));
    beB.CommitBatch;
    gSid := 1;
    Ok('2: A K1 okur (4b)', Oku(beA, 1) = 'v0', Oku(beA, 1));
    beA.Put(1, B('v4'));
    cakisti := CommitCakisma(beA, msg);
    Ok('2: 4b: okumadan onceki yabanci commit cakisma VERMEZ',
      (not cakisti) and (msg = ''), msg);
    if cakisti then beA.AbortBatch;
    Ok('2: 4b: son yazar degeri korunur', Oku(beA, 1) = 'v4', Oku(beA, 1));

    { --- Sinir 1: okunmayan anahtar (blind write) --- }
    gSid := 10;
    beB.BeginBatch;
    gSid := 1;
    beA.BeginBatch;
    gSid := 10;
    beB.Put(2, B('z'));            // ilgisiz anahtar; K1'e dokunmaz
    beB.CommitBatch;
    gSid := 1;
    beA.Put(1, B('v6'));           // K1 OKUNMADAN yazilir
    cakisti := CommitCakisma(beA, msg);
    Ok('3: okunmayan anahtara blind write cakisma VERMEZ',
      (not cakisti) and (msg = ''), msg);
    if cakisti then beA.AbortBatch;
    Ok('3: blind write degeri korunur', Oku(beA, 1) = 'v6', Oku(beA, 1));

    { --- Sinir 2 (bilincli konservatif): okumadan SONRA ilgisiz commit --- }
    { Tasarim geregi store sayaci GLOBALDIR; anahtar hassasiyeti yoktur.
      A K1'i okuduktan sonra B BASKA bir anahtari commit ederse bile
      cakisma beklenir (veri kaybi yerine konservatif abort). }
    gSid := 10;
    beB.BeginBatch;
    gSid := 1;
    beA.BeginBatch;
    Ok('4: A K1 okur (konservatif)', Oku(beA, 1) = 'v6', Oku(beA, 1));
    gSid := 10;
    beB.Put(2, B('y'));            // K1'e DOKUNMAZ
    beB.CommitBatch;
    gSid := 1;
    beA.Put(1, B('v7'));
    cakisti := CommitCakisma(beA, msg);
    Ok('4: konservatif: ilgisiz commit sonrasi cakisma verir (tasarim)',
      cakisti, msg);
    beA.AbortBatch;
    gSid := 10;
    Ok('4: konservatif: A yazimi uygulanmadi', Oku(beA, 1) = 'v6',
      Oku(beA, 1));
  finally
    gSid := 0;
    beA.Free;
    beB.Free;
  end;

  if gFail = oncekiFail then
    WriteLn('CAPRAZ BACKEND OKUMA PENCERESI DOGRULANDI')
  else
    WriteLn('CAPRAZ BACKEND OKUMA PENCERESI DOGRULANAMADI');
end;

var
  dir: string;

begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'kullanim: genchk <dizin>');
    Halt(2);
  end;
  dir := ParamStr(1);
  ForceDirectories(dir);
  VdbSessionIdFunc := @SidFunc;
  try
    BolumC2(dir);
    BolumB06(dir);
    BolumReadSet(dir);
    BolumAutocommit(dir);
    BolumCrossBackend(dir);
  finally
    VdbSessionIdFunc := nil;
  end;
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
    WriteLn('TEMIZ')
  else
    Halt(1);
end.
