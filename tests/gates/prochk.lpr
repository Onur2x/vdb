program prochk;
{ SUREÇLER ARASI COK YAZARLILIK KANITI (v3.16).
  Iki AYRI islem ayni veritabani dosyasina yazar; ikisi de commit etmeli ve
  tum satirlar eksiksiz olmali (veri kaybi yok).

  Kullanim:
    prochk <dizin>            -> ana surec: dosyayi kurar, 2 cocuk baslatir,
                                 bekler, sonucu dogrular
    prochk --cocuk <dizin> <on-ek> <adet>
                              -> cocuk: kendi anahtarlariyla parti yazar }
{$mode delphi}{$H+}
uses
  SysUtils, Classes, Process, VDbBackendApi, VDbBackendV3;

const
  COCUK_ADET = 40;

var
  gFail, gPass: Integer;

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

function DbYolu(const D: string): string;
begin
  Result := IncludeTrailingPathDelimiter(D) + 'veritabani.odb';
end;

{ v3.18: sifreli dosyada cok surecli yazma. Ayni parola, ayni dosya, iki
  ayri surec; ikisi de commit etmeli ve satirlar eksiksiz olmali. Sifreli
  yolun busy timeout'u artik verilebiliyor (CreateWithPassword ... ABusyMs);
  bu kapi o parametreyi ve sifreli WAL paylasimini birlikte sinar. }
function CocukSifreli(const Dizin, Onek, Parola: string; Adet: Integer): Integer;
var
  be: TVdbBackendV3;
  i: Integer;
  anahtar: QWord;
  faz: string;
begin
  Result := 0;
  faz := 'acilis';
  try
    be := TVdbBackendV3.CreateWithPassword(DbYolu(Dizin), Parola, False, 256, 20000);
    try
      faz := 'beginbatch';
      be.BeginBatch;
      faz := 'sleep';
      Sleep(400);
      faz := 'yazim';
      for i := 1 to Adet do
      begin
        if Onek = 'A' then anahtar := 3000 + QWord(i)
        else anahtar := 4000 + QWord(i);
        be.Put(anahtar, B(Onek + '-' + IntToStr(i)));
      end;
      faz := 'commit';
      be.CommitBatch;
      WriteLn('cocuk-sifreli ', Onek, ': ', Adet, ' satir yazildi, toplam=', be.Count);
    finally
      be.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('cocuk-sifreli ', Onek, ' HATA [', faz, ']: ', E.ClassName, ': ', E.Message);
      Result := 4;
    end;
  end;
end;

{ --------------------------------------------------------------- cocuk }
function Cocuk(const Dizin, Onek: string; Adet: Integer): Integer;
var
  be: TVdbBackendV3;
  i: Integer;
  anahtar: QWord;
  v: TBytes;
  faz: string;
begin
  Result := 0;
  faz := 'acilis';
  try
    be := TVdbBackendV3.Create(DbYolu(Dizin), False, 256, 20000);
  except
    on E: Exception do
    begin
      WriteLn('cocuk ', Onek, ' ACILAMADI [', faz, ']: ', E.ClassName, ': ', E.Message);
      raise;
      Exit(3);
    end;
  end;
  try
    faz := 'beginbatch';
    be.BeginBatch;
    { Gercek yaris: iki surec ayni anda acik islemde olsun. }
    faz := 'sleep';
    Sleep(400);
    faz := 'yazim';
    for i := 1 to Adet do
    begin
      if Onek = 'A' then anahtar := 1000 + QWord(i)
      else anahtar := 2000 + QWord(i);
      be.Put(anahtar, B(Onek + '-' + IntToStr(i)));
    end;
    faz := 'commit';
    be.CommitBatch;
    WriteLn('cocuk ', Onek, ': ', Adet, ' satir yazildi, toplam=', be.Count);
  except
    on E: Exception do
    begin
      WriteLn('cocuk ', Onek, ' HATA [', faz, ']: ', E.ClassName, ': ', E.Message);
      Result := 4;
    end;
  end;
  be.Free;
end;

{ v3.18 DUZELTME KAPISI — KAPANIS CHECKPOINT'I TAZELEME YAPMALI.
  Olculen kusur: A sureci commit edip ACIK kalirken B commit ederse, A
  kapanirken BELLEKTEPI BAYAT sayfalari diske yazip WAL'i kendi bayat
  LSN'inde kesiyordu -> B'nin onaylanmis commit'i yok oluyordu
  (prochk kosu 20: 40 satir kayboldu). Bu cocuk o durumu KOSULLU degil,
  SIRAYA bagli olarak uretir: commit eder, hazir isareti birakir, bekler.
  Ana surec bu arada yazar ve kapanir. Sonra cocuk kapanir. }
function Tut(const Dizin, HazirDosya: string; Ms: Integer): Integer;
var
  be: TVdbBackendV3;
  i: Integer;
  f: TFileStream;
  faz: string;
begin
  Result := 0;
  faz := 'acilis';
  try
    be := TVdbBackendV3.Create(DbYolu(Dizin), False, 256, 20000);
    try
      faz := 'beginbatch';
      be.BeginBatch;
      faz := 'yazim';
      for i := 1 to 5 do
        be.Put(QWord(5000 + i), B('tut-' + IntToStr(i)));
      faz := 'commit';
      be.CommitBatch;
      faz := 'isaret';
      f := TFileStream.Create(HazirDosya, fmCreate);
      f.Free;
      faz := 'sleep';
      Sleep(Ms);
      faz := 'kapanis';
    finally
      be.Free;      // <-- kusur BURADA: bayat bellekle checkpoint
    end;
    WriteLn('tut: 5 satir yazildi, bekledi, kapandi');
  except
    on E: Exception do
    begin
      WriteLn('tut HATA [', faz, ']: ', E.ClassName, ': ', E.Message);
      Result := 4;
    end;
  end;
end;

procedure TestKapanisTazeleme(const Ust: string);
var
  dir, hazir: string;
  be: TVdbBackendV3;
  p: TProcess;
  i, n, eksik: Integer;
  v: TBytes;
  t0: QWord;
  geldi: Boolean;
  ana: TVdbBackendV3;
begin
  WriteLn;
  WriteLn('--- kapanis checkpoint''i tazeleme yapar (v3.18 veri kaybi)');
  dir := IncludeTrailingPathDelimiter(Ust) + 'kapanis';
  ForceDirectories(dir);
  hazir := IncludeTrailingPathDelimiter(dir) + 'hazir.txt';

  DeleteFile(DbYolu(dir));
  DeleteFile(DbYolu(dir) + '.gen');
  DeleteFile(DbYolu(dir) + '.wal');
  DeleteFile(DbYolu(dir) + '.idx');
  DeleteFile(DbYolu(dir) + '.log');
  DeleteFile(hazir);

  { Tohum: 5 satir, temiz kapanis. }
  be := TVdbBackendV3.Create(DbYolu(dir), True, 256, 20000);
  try
    for i := 1 to 5 do be.Put(QWord(i), B('tohum-' + IntToStr(i)));
  finally
    be.Free;
  end;

  { Tutan cocuk: commit eder, isaret birakir, ACIK bekler. }
  p := TProcess.Create(nil);
  try
    p.Executable := ParamStr(0);
    p.Parameters.Add('--tut');
    p.Parameters.Add(dir);
    p.Parameters.Add(hazir);
    p.Parameters.Add('1500');
    p.Options := [];
    p.Execute;

    t0 := GetTickCount64;
    while (not FileExists(hazir)) and ((GetTickCount64 - t0) < 15000) do
      Sleep(10);
    geldi := FileExists(hazir);
    Ok('tutan cocuk commit etti ve bekliyor', geldi,
      IntToStr(GetTickCount64 - t0) + ' ms');

    { Cocuk ACIK ve beklemedeyken ANA surec yazar. ANA SUREC ACIK KALIR:
      kaybin olustugu pencere tam olarak budur. Ana surec commit eder ve
      cerceveleri WAL'de durur; sonra BAYAT oturum (tutan cocuk) kapanip
      WAL'i kendi bayat LSN'inde keserse ana surecin onaylanmis commit'i
      yok olur. Ana surec once kapansaydi veri .odb'ye tasinmis olurdu ve
      kusur GORUNMEZDI (bu tuzak olculerek bulundu). }
    ana := nil;
    if geldi then
    begin
      ana := TVdbBackendV3.Create(DbYolu(dir), False, 256, 20000);
      ana.BeginBatch;
      for i := 1 to 5 do
        ana.Put(QWord(6000 + i), B('ana-' + IntToStr(i)));
      ana.CommitBatch;
      Ok('ana surec yazdi ve ACIK kaliyor', True, '5 satir, WAL''de');
    end;

    { Bayat oturum simdi kapanir. }
    while p.Running do Sleep(10);
    Ok('tutan cocuk cikis kodu 0', p.ExitStatus = 0, IntToStr(p.ExitStatus));

    { Ana surec en son kapanir. }
    if ana <> nil then
    begin
      ana.Free;
      Ok('ana surec kapandi', True, 'checkpoint + WAL budama');
    end;
  finally
    p.Free;
  end;
  if FileExists(hazir) then DeleteFile(hazir);

  { TAZE acilis: 5 tohum + 5 tutan + 5 ana = 15. }
  be := TVdbBackendV3.Create(DbYolu(dir), False, 256, 20000);
  try
    n := be.Count;
    Ok('kapanis sonrasi toplam satir 15', n = 15, IntToStr(n));
    eksik := 0;
    for i := 1 to 5 do
    begin
      if not be.Get(QWord(5000 + i), v) then Inc(eksik);
      if not be.Get(QWord(6000 + i), v) then Inc(eksik);
    end;
    Ok('tutan ve ana surecin satirlari korundu', eksik = 0,
      'eksik=' + IntToStr(eksik));
  finally
    be.Free;
  end;
end;

procedure TestSifreliCokSurecli(const Ust: string);
var
  dir, sifre: string;
  be: TVdbBackendV3;
  p1, p2: TProcess;
  i, n, eksik: Integer;
  v: TBytes;
  reddedildi: Boolean;
begin
  WriteLn;
  WriteLn('--- sifreli dosyada cok surecli yazma (v3.18)');
  dir := IncludeTrailingPathDelimiter(Ust) + 'sifreli';
  ForceDirectories(dir);
  sifre := 'cok-surec-parola';

  DeleteFile(DbYolu(dir));
  DeleteFile(DbYolu(dir) + '.gen');
  DeleteFile(DbYolu(dir) + '.wal');
  DeleteFile(DbYolu(dir) + '.idx');
  DeleteFile(DbYolu(dir) + '.log');
  DeleteFile(DbYolu(dir) + '.meta');
  DeleteFile(DbYolu(dir) + '.undo');

  { Tohum: sifreli dosya, 5 satir, kapanir. }
  be := TVdbBackendV3.CreateWithPassword(DbYolu(dir), sifre, True, 256, 20000);
  try
    for i := 1 to 5 do be.Put(QWord(i), B('tohum-' + IntToStr(i)));
    Ok('sifreli tohum 5 satir', be.Count = 5, IntToStr(be.Count));
    Ok('dosya gercekten sifreli', be.Encrypted, BoolToStr(be.Encrypted, True));
  finally
    be.Free;
  end;

  { Iki cocuk AYNI ANDA sifreli dosyaya yazar. }
  p1 := TProcess.Create(nil);
  p2 := TProcess.Create(nil);
  try
    p1.Executable := ParamStr(0);
    p1.Parameters.Add('--cocuk-sifreli');
    p1.Parameters.Add(dir);
    p1.Parameters.Add('A');
    p1.Parameters.Add(sifre);
    p1.Parameters.Add(IntToStr(COCUK_ADET));
    p1.Options := [];
    p1.Execute;

    p2.Executable := ParamStr(0);
    p2.Parameters.Add('--cocuk-sifreli');
    p2.Parameters.Add(dir);
    p2.Parameters.Add('B');
    p2.Parameters.Add(sifre);
    p2.Parameters.Add(IntToStr(COCUK_ADET));
    p2.Options := [];
    p2.Execute;

    while p1.Running or p2.Running do Sleep(10);

    Ok('sifreli cocuk A cikis kodu 0', p1.ExitStatus = 0, IntToStr(p1.ExitStatus));
    Ok('sifreli cocuk B cikis kodu 0', p2.ExitStatus = 0, IntToStr(p2.ExitStatus));
  finally
    p1.Free;
    p2.Free;
  end;

  { Dogrulama: dogru parola ile ac, TUM satirlar yerinde mi? }
  be := TVdbBackendV3.CreateWithPassword(DbYolu(dir), sifre, False, 256, 20000);
  try
    n := be.Count;
    Ok('sifreli toplam satir 5 + 2*' + IntToStr(COCUK_ADET),
      n = 5 + 2 * COCUK_ADET, IntToStr(n));
    eksik := 0;
    for i := 1 to COCUK_ADET do
    begin
      if not be.Get(QWord(3000 + i), v) then Inc(eksik);
      if not be.Get(QWord(4000 + i), v) then Inc(eksik);
    end;
    Ok('sifreli hicbir satir kaybolmadi', eksik = 0, 'eksik=' + IntToStr(eksik));
  finally
    be.Free;
  end;

  { Yanlis parola hala reddedilir (sifreleme butunlugu korunuyor). }
  reddedildi := False;
  try
    be := TVdbBackendV3.CreateWithPassword(DbYolu(dir), 'yanlis-parola', False, 256, 2000);
    try
      be.Count;
    finally
      be.Free;
    end;
  except
    on E: Exception do reddedildi := True;
  end;
  Ok('yanlis parola reddedildi', reddedildi, BoolToStr(reddedildi, True));
end;

{ --------------------------------------------------------------- ana }
var
  be: TVdbBackendV3;
  p1, p2: TProcess;
  i, n: Integer;
  v: TBytes;
  eksik: Integer;
  kume: string;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--tut') then
  begin
    ExitCode := Tut(ParamStr(2), ParamStr(3), StrToIntDef(ParamStr(4), 1500));
    Exit;
  end;
  if (ParamCount >= 1) and (ParamStr(1) = '--cocuk') then
  begin
    ExitCode := Cocuk(ParamStr(2), ParamStr(3), StrToIntDef(ParamStr(4), COCUK_ADET));
    Exit;
  end;

  if (ParamCount >= 4) and (ParamStr(1) = '--cocuk-sifreli') then
  begin
    ExitCode := CocukSifreli(ParamStr(2), ParamStr(3), ParamStr(4),
      StrToIntDef(ParamStr(5), COCUK_ADET));
    Exit;
  end;

  if ParamCount < 1 then
  begin
    WriteLn('kullanim: prochk <dizin>');
    ExitCode := 2;
    Exit;
  end;

  if DirectoryExists(ParamStr(1)) then
  begin
    DeleteFile(DbYolu(ParamStr(1)));
    { v3.17: yan dosyalar da silinir; eski bir .gen sayaci ya da .wal
      kalirsa yeni kosu bayat durumla baslar. }
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.odb.gen');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.odb.wal');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.idx');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.log');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.meta');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'veritabani.undo');
  end;
  ForceDirectories(ParamStr(1));

  { Tohum: tek surec 5 satir yazar ve KAPATIR. }
  be := TVdbBackendV3.Create(DbYolu(ParamStr(1)), True, 256, 20000);
  try
    for i := 1 to 5 do be.Put(QWord(i), B('tohum-' + IntToStr(i)));
    Ok('tohum 5 satir', be.Count = 5, IntToStr(be.Count));
  finally
    be.Free;
  end;

  { Iki cocuk AYNI ANDA ayni dosyaya yazar. }
  p1 := TProcess.Create(nil);
  p2 := TProcess.Create(nil);
  try
    p1.Executable := ParamStr(0);
    p1.Parameters.Add('--cocuk');
    p1.Parameters.Add(ParamStr(1));
    p1.Parameters.Add('A');
    p1.Parameters.Add(IntToStr(COCUK_ADET));
    p1.Options := [];   // cikti ebeveyn konsoluna dussun (hata mesaji gorunsun)
    p1.Execute;

    p2.Executable := ParamStr(0);
    p2.Parameters.Add('--cocuk');
    p2.Parameters.Add(ParamStr(1));
    p2.Parameters.Add('B');
    p2.Parameters.Add(IntToStr(COCUK_ADET));
    p2.Options := [];   // cikti ebeveyn konsoluna dussun
    p2.Execute;

    { poWaitOnExit KULLANILMAZ: o secenek Execute'i bloklar ve cocuklar
      sirayla kosar (yanlis pozitif yesil). Ikisi de arka planda kosar. }
    while p1.Running or p2.Running do Sleep(10);

    Ok('cocuk A cikis kodu 0', p1.ExitStatus = 0, IntToStr(p1.ExitStatus));
    Ok('cocuk B cikis kodu 0', p2.ExitStatus = 0, IntToStr(p2.ExitStatus));
  finally
    p1.Free;
    p2.Free;
  end;

  { Dogrulama: yeni bir oturum ac, TUM satirlar yerinde mi? }
  be := TVdbBackendV3.Create(DbYolu(ParamStr(1)), False, 256, 20000);
  try
    n := be.Count;
    Ok('toplam satir 5 + 2*' + IntToStr(COCUK_ADET), n = 5 + 2 * COCUK_ADET,
      IntToStr(n));

    eksik := 0;
    for i := 1 to COCUK_ADET do
    begin
      if not be.Get(QWord(1000 + i), v) then Inc(eksik);
      if not be.Get(QWord(2000 + i), v) then Inc(eksik);
    end;
    Ok('hicbir satir kaybolmadi', eksik = 0, 'eksik=' + IntToStr(eksik));

    if be.Get(QWord(1007), v) then kume := S(v) else kume := '<yok>';
    Ok('cocuk A degeri dogru', kume = 'A-7', kume);
    if be.Get(QWord(2033), v) then kume := S(v) else kume := '<yok>';
    Ok('cocuk B degeri dogru', kume = 'B-33', kume);
    Ok('tohum satiri korundu', be.Exists(3), BoolToStr(be.Exists(3), True));
  finally
    be.Free;
  end;

  { v3.18 DUZELTME KAPISI: kapanis checkpoint'i tazeleme yapar. }
  TestKapanisTazeleme(ParamStr(1));

  { v3.18: sifreli dosyada cok surecli yazma. }
  TestSifreliCokSurecli(ParamStr(1));

  WriteLn('---');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail > 0 then ExitCode := 1;
end.
