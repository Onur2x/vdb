program xprocc;
{ P-148: GERCEK AYRI SUREC okuma -> yazma penceresi kapisi.

  P-146, ayni surec icindeki iki TVdbBackendV3 ornegi arasindaki pencereyi
  (genchk BolumCrossBackend) dogruluyordu. Bu kapi ayni sozlesmeyi IKI AYRI
  ISLEM ile sinar: ebeveyn surec yazar rezervasyonunu tutar, cocuk surec
  bu yuzden IYIMSER modda acilir, bir anahtari okur, ebeveyn yabanci
  commit(ler) yazar, sonra cocuk yazmayi dener.

  Kontroller:
    (a) ayri surec ABA (v0 -> v1 -> v0) cakismasi yakalanir; lost update yok
    (b) okumadan SONRA eszamanli ilgisiz commit konservatif cakisma verir
    (c) 4b: okumadan ONCE yabanci commit cakisma URETMEZ
    (d) cocuk surec temiz kapanir; kilit/isaret temizligi ve son yazar
        kilidinin serbest kaldigi dogrulanir

  Kullanim:
    xprocc <dizin>
    xprocc --cocuk <mod> <dizin> <hazir> <bitti> <sonuc>
      mod: aba | unrel | pre

  Sinirlar: bekleme SABIT uyku degil, sinyal dosyasi yoklamasidir; sureler
  comerttir (hazir 30 sn, bitis 60 sn). Cocuk surec zaman asiminda
  sonlandirilir. }
{$mode delphi}{$H+}
uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process, VDbBackendApi, VDbBackendV3;

const
  { Ebeveyn yabanci commit'leri beklerken cocugun okuma zamani. }
  HAZIR_MS  = 30000;
  BITTI_MS  = 60000;
  SUREC_MS  = 60000;

var
  gFail, gPass: Integer;

const
  { Cocuk surec sonuc sinyalleri (cikis kodlari). }
  CK_OK       = 0;   { beklenen sonuc alindi }
  CK_IYIMSER  = 3;   { cocuk iyimser baslamadi / acilamadi }
  CK_BEKLEME  = 5;   { sinyal zaman asimi }
  CK_BEKLEMEDI= 4;   { beklenen cakisma sonucu alinmadi }
  CK_HATA     = 6;   { beklenmeyen istisna }

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

function BB(X: Boolean): string;
begin
  if X then Result := '1' else Result := '0';
end;

function DbYolu(const D: string): string;
begin
  Result := IncludeTrailingPathDelimiter(D) + 'veritabani.odb';
end;

procedure SilDosya(const P: string);
begin
  if FileExists(P) then DeleteFile(P);
end;

procedure SilYanDosyalar(const Db: string);
begin
  SilDosya(Db + '.gen');
  SilDosya(Db + '.wal');
  SilDosya(Db + '.idx');
  SilDosya(Db + '.log');
  SilDosya(Db + '.meta');
  SilDosya(Db + '.undo');
end;

function Oku(be: TVdbBackendV3; K: QWord): string;
var v: TBytes;
begin
  if be.Get(K, v) then Result := S(v) else Result := '<yok>';
end;

procedure IsaretBirak(const P: string);
var f: TFileStream;
begin
  f := TFileStream.Create(P, fmCreate);
  f.Free;
end;

{ Sinyal dosyasini yokla; SABIT Sleep yok, comert zaman asimi var. }
function BekleDosya(const P: string; Ms: Integer): Boolean;
var t0: QWord;
begin
  t0 := GetTickCount64;
  while not FileExists(P) do
  begin
    if (GetTickCount64 - t0) > QWord(Ms) then Exit(False);
    Sleep(10);
  end;
  Result := True;
end;

{ Cocuk sonucunu anahtar=deger satirlari olarak yazar. }
procedure SonucYaz(const P, Iyimser, Okunan, Cakisti, CommitOk: string);
var sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Add('iyimser=' + Iyimser);
    sl.Add('okunan=' + Okunan);
    sl.Add('cakisti=' + Cakisti);
    sl.Add('commit_ok=' + CommitOk);
    sl.SaveToFile(P);
  finally
    sl.Free;
  end;
end;

function Alan(const P, Ad: string): string;
var sl: TStringList;
begin
  Result := '';
  if not FileExists(P) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(P);
    Result := Trim(sl.Values[Ad]);
  finally
    sl.Free;
  end;
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

{ Surecin bitmesini bekle; zaman asiminda sonlandir. }
function SurecBekle(p: TProcess; Ms: Integer): Boolean;
var
  t0: QWord;
begin
  t0 := GetTickCount64;
  while p.Running do
  begin
    if (GetTickCount64 - t0) > QWord(Ms) then
    begin
      p.Terminate(9);
      t0 := GetTickCount64;
      while p.Running and ((GetTickCount64 - t0) < 5000) do Sleep(10);
      Exit(False);
    end;
    Sleep(10);
  end;
  Result := True;
end;

{ --------------------------------------------------------------- cocuk }
{ Rezervasyon ebeveynde oldugu icin bu surec IYIMSER baslamali. Mod:
    aba   : K1 oku -> sinyal -> bekle -> K1 yaz (cakisma BEKLENIR)
    unrel : K1 oku -> sinyal -> bekle -> K1 yaz (ilgisiz commit sonrasi;
            konservatif cakisma BEKLENIR)
    pre   : sinyal -> bekle -> K1 oku -> K1 yaz (okumadan ONCE yabanci
            commit; cakisma BEKLENMEZ) }
function Cocuk(const Mod_, Dizin, Hazir, Bitti, Sonuc: string): Integer;
var
  be: TVdbBackendV3;
  cakisti, commitOk, iyimser: Boolean;
  msg, okunan, yeni: string;
begin
  Result := CK_HATA;
  be := nil;
  okunan := '';
  try
    try
      be := TVdbBackendV3.Create(DbYolu(Dizin), False, 512, 20000);
    except
      on E: Exception do
      begin
        WriteLn('cocuk ', Mod_, ' ACILAMADI: ', E.ClassName, ': ', E.Message);
        SonucYaz(Sonuc, '0', '<yok>', '0', '0');
        Exit(CK_IYIMSER);
      end;
    end;
    try
      be.BeginBatch;
      iyimser := be.Engine.Store.LockHoldDepth = 0;
      WriteLn('cocuk ', Mod_, ': iyimser=', BB(iyimser),
        ' rezervasyon=', IntToStr(be.Engine.Store.LockHoldDepth));
      if not iyimser then
      begin
        SonucYaz(Sonuc, '0', okunan, '0', '0');
        be.AbortBatch;
        Exit(CK_IYIMSER);
      end;

      if Mod_ = 'pre' then
      begin
        { Yabanci commit okumadan ONCE olmali. }
        IsaretBirak(Hazir);
        if not BekleDosya(Bitti, BITTI_MS) then
        begin
          SonucYaz(Sonuc, '1', '<zaman-asimi>', '0', '0');
          be.AbortBatch;
          Exit(CK_BEKLEME);
        end;
        okunan := Oku(be, 1);
      end
      else
      begin
        okunan := Oku(be, 1);
        IsaretBirak(Hazir);
        if not BekleDosya(Bitti, BITTI_MS) then
        begin
          SonucYaz(Sonuc, '1', okunan, '0', '0');
          be.AbortBatch;
          Exit(CK_BEKLEME);
        end;
      end;

      if Mod_ = 'pre' then yeni := 'v4' else yeni := 'v2';
      be.Put(1, B(yeni));
      cakisti := CommitCakisma(be, msg);
      commitOk := not cakisti;
      if cakisti then
      begin
        WriteLn('cocuk ', Mod_, ': cakisma yakalandi: ', msg);
        be.AbortBatch;
      end
      else
        WriteLn('cocuk ', Mod_, ': cakisma YOK');
      SonucYaz(Sonuc, '1', okunan, BB(cakisti), BB(commitOk));

      if Mod_ = 'pre' then
      begin
        if commitOk then Result := CK_OK else Result := CK_BEKLEMEDI;
      end
      else
      begin
        if cakisti then Result := CK_OK else Result := CK_BEKLEMEDI;
      end;
    finally
      be.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('cocuk ', Mod_, ' HATA: ', E.ClassName, ': ', E.Message);
      SonucYaz(Sonuc, '1', okunan, '0', '0');
      Result := CK_HATA;
    end;
  end;
end;

{ ------------------------------------------------------------ senaryo }
{ Ebeveyn akisi:
  1) tohum DB (K1=v0, K2=sabit), kapat
  2) ebeveyn backend ac + BeginBatch -> yazar rezervasyonu ELDE
  3) cocuk surec baslat (rezervasyon onda olmadigi icin iyimser)
  4) cocuk hazir sinyalini bekle
  5) ebeveyn yabanci commit:
       aba   : K1 v0 -> v1 -> v0 (ABA)
       unrel : ilgisiz K2 = y
       pre   : ilgisiz K2 = y (cocuk HENUZ okumadi)
  6) bitti sinyali, cocuk cikisini bekle
  7) cocuk sonuc dosyasi + taze backend ile son deger dogrula }
function Senaryo(const Ust, Ad, Mod_: string): Boolean;
var
  dir, db, hazir, bitti, sonuc: string;
  be: TVdbBackendV3;
  p: TProcess;
  hazirGeldi, bittiGeldi: Boolean;
  pExit: Integer;
  iyimser, cakisti, commitOk, okunan: string;
  oncekiFail: Integer;
  son: string;
begin
  Result := True;
  WriteLn;
  WriteLn('--- senaryo ', Ad, ' (mod=', Mod_, ')');
  oncekiFail := gFail;
  dir := IncludeTrailingPathDelimiter(Ust) + Ad;
  ForceDirectories(dir);
  db := DbYolu(dir);
  hazir := IncludeTrailingPathDelimiter(dir) + 'cocuk_hazir';
  bitti := IncludeTrailingPathDelimiter(dir) + 'ebeveyn_bitti';
  sonuc := IncludeTrailingPathDelimiter(dir) + 'cocuk_sonuc';

  SilDosya(hazir);
  SilDosya(bitti);
  SilDosya(sonuc);
  SilDosya(db);
  SilYanDosyalar(db);

  { 1) Tohum. }
  be := TVdbBackendV3.Create(db, True, 512, 20000);
  try
    be.BeginBatch;
    be.Put(1, B('v0'));
    be.Put(2, B('sabit'));
    be.CommitBatch;
  finally
    be.Free;
  end;

  { 2) Ebeveyn rezervasyonu. }
  be := TVdbBackendV3.Create(db, False, 512, 20000);
  try
    be.BeginBatch;
    Ok(Ad + ': ebeveyn yazar rezervasyonunu tutuyor',
      be.Engine.Store.LockHoldDepth > 0,
      IntToStr(be.Engine.Store.LockHoldDepth));

    p := TProcess.Create(nil);
    hazirGeldi := False;
    try
      p.Executable := ParamStr(0);
      p.Parameters.Add('--cocuk');
      p.Parameters.Add(Mod_);
      p.Parameters.Add(dir);
      p.Parameters.Add(hazir);
      p.Parameters.Add(bitti);
      p.Parameters.Add(sonuc);
      p.Options := [];      { cikti ebeveyn konsoluna dussun }
      p.Execute;

      { 4) Cocuk okumayi bitirip sinyal verene kadar bekle. }
      hazirGeldi := BekleDosya(hazir, HAZIR_MS);
      Ok(Ad + ': cocuk hazir sinyali geldi', hazirGeldi,
        IntToStr(HAZIR_MS) + ' ms sinir');

      if not hazirGeldi then
      begin
        be.AbortBatch;
        SurecBekle(p, 1000);
      end
      else
      begin
        { 5) Ebeveyn yabanci commit. }
        if Mod_ = 'aba' then
        begin
          be.Put(1, B('v1'));
          be.CommitBatch;
          be.BeginBatch;
          be.Put(1, B('v0'));
          be.CommitBatch;
          WriteLn('ebeveyn: K1 v0 -> v1 -> v0 (ABA) commit edildi');
        end
        else
        begin
          be.Put(2, B('y'));
          be.CommitBatch;
          WriteLn('ebeveyn: ilgisiz K2=y commit edildi');
        end;

        { 6) Bitis sinyali + cocuk cikisi. }
        IsaretBirak(bitti);
        bittiGeldi := SurecBekle(p, SUREC_MS);
        Ok(Ad + ': cocuk zamaninda tamamlandi', bittiGeldi,
          IntToStr(SUREC_MS) + ' ms sinir');
      end;

      pExit := p.ExitStatus;
      Ok(Ad + ' (d): cocuk surec temiz kapandi (cikis 0)',
        (not p.Running) and (pExit = CK_OK), IntToStr(pExit));

      iyimser := Alan(sonuc, 'iyimser');
      okunan := Alan(sonuc, 'okunan');
      cakisti := Alan(sonuc, 'cakisti');
      commitOk := Alan(sonuc, 'commit_ok');
      Ok(Ad + ': cocuk iyimser (rezervasyon ebeveynde) basladi',
        iyimser = '1', 'iyimser=' + iyimser);
      Ok(Ad + ': cocuk K1=v0 okudu', okunan = 'v0', 'okunan=' + okunan);
      Ok(Ad + ' (d): cocuk sonuc dosyasi yazildi',
        FileExists(sonuc), sonuc);

      if Mod_ = 'pre' then
        Ok(Ad + ' (c) 4b: okumadan ONCE yabanci commit cakisma VERMEZ',
          (cakisti = '0') and (commitOk = '1'),
          'cakisti=' + cakisti + ' commit_ok=' + commitOk)
      else if Mod_ = 'unrel' then
        Ok(Ad + ' (b): okumadan SONRA ilgisiz commit konservatif cakisma verir',
          (cakisti = '1') and (commitOk = '0'),
          'cakisti=' + cakisti + ' commit_ok=' + commitOk)
      else
        Ok(Ad + ' (a): ayri surec ABA cakismasi yakalanir',
          (cakisti = '1') and (commitOk = '0'),
          'cakisti=' + cakisti + ' commit_ok=' + commitOk);
    finally
      if p.Running then
      begin
        p.Terminate(9);
        SurecBekle(p, 5000);
      end;
      p.Free;
    end;
  finally
    be.AbortBatch;
    be.Free;
  end;

  { 7) Taze backend: son deger + yazar kilidi serbestligi. }
  be := TVdbBackendV3.Create(db, False, 512, 20000);
  try
    son := Oku(be, 1);
    if Mod_ = 'pre' then
      Ok(Ad + ' (c): cocuk yazimi uygulandi (K1=v4)', son = 'v4', son)
    else
      Ok(Ad + ' (a/b): sessiz guncelleme kaybi YOK (K1=v0)', son = 'v0', son);

    { (d) Cocuk kapandiktan sonra yazar kilidi serbest olmali. }
    be.BeginBatch;
    be.Put(99, B('son'));
    be.CommitBatch;
    Ok(Ad + ' (d): cocuk sonrasi yazar kilidi serbest',
      Oku(be, 99) = 'son', Oku(be, 99));
  finally
    be.AbortBatch;
    be.Free;
  end;

  { Isaret dosyalari temizligi. }
  SilDosya(hazir);
  SilDosya(bitti);
  Ok(Ad + ' (d): sinyal dosyalari temizlendi',
    (not FileExists(hazir)) and (not FileExists(bitti)),
    'hazir/bitti');

  Result := gFail = oncekiFail;
end;

{ --------------------------------------------------------------- ana }
var
  ust: string;
  oncekiFail: Integer;
  okA, okB, okC: Boolean;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--cocuk') then
  begin
    if ParamCount < 6 then
    begin
      WriteLn('kullanim: xprocc --cocuk <mod> <dizin> <hazir> <bitti> <sonuc>');
      ExitCode := 2;
      Exit;
    end;
    ExitCode := Cocuk(ParamStr(2), ParamStr(3), ParamStr(4),
      ParamStr(5), ParamStr(6));
    Exit;
  end;

  if ParamCount < 1 then
  begin
    WriteLn('kullanim: xprocc <dizin>');
    ExitCode := 2;
    Exit;
  end;

  ust := ParamStr(1);
  ForceDirectories(ust);
  oncekiFail := gFail;

  WriteLn('=== P-148: ayri surec okuma -> yazma penceresi ===');
  okA := Senaryo(ust, 's_aba', 'aba');
  okB := Senaryo(ust, 's_unrel', 'unrel');
  okC := Senaryo(ust, 's_pre', 'pre');

  WriteLn;
  if (gFail = oncekiFail) and okA and okB and okC then
    WriteLn('AYRI SUREC OKUMA PENCERESI DOGRULANDI')
  else
    WriteLn('AYRI SUREC OKUMA PENCERESI DOGRULANAMADI');
  WriteLn('---');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail > 0 then ExitCode := 1;
end.
