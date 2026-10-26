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

{ --------------------------------------------------------------- cocuk }
function Cocuk(const Dizin, Onek: string; Adet: Integer): Integer;
var
  be: TVdbBackendV3;
  i: Integer;
  anahtar: QWord;
  v: TBytes;
begin
  Result := 0;
  try
    be := TVdbBackendV3.Create(DbYolu(Dizin), False, 256, 20000);
  except
    on E: Exception do
    begin
      WriteLn('cocuk ', Onek, ' ACILAMADI: ', E.ClassName, ': ', E.Message);
      raise;
      Exit(3);
    end;
  end;
  try
    be.BeginBatch;
    { Gercek yaris: iki surec ayni anda acik islemde olsun. }
    Sleep(400);
    for i := 1 to Adet do
    begin
      if Onek = 'A' then anahtar := 1000 + QWord(i)
      else anahtar := 2000 + QWord(i);
      be.Put(anahtar, B(Onek + '-' + IntToStr(i)));
    end;
    be.CommitBatch;
    WriteLn('cocuk ', Onek, ': ', Adet, ' satir yazildi, toplam=', be.Count);
  except
    on E: Exception do
    begin
      WriteLn('cocuk ', Onek, ' HATA: ', E.ClassName, ': ', E.Message);
      Result := 4;
    end;
  end;
  be.Free;
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
  if (ParamCount >= 1) and (ParamStr(1) = '--cocuk') then
  begin
    ExitCode := Cocuk(ParamStr(2), ParamStr(3), StrToIntDef(ParamStr(4), COCUK_ADET));
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

  WriteLn('---');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail > 0 then ExitCode := 1;
end.
