program factorychk;

{ VDB - VDbFactory kapisi

  Amac: uygulamalarin tek giris noktasi (VdbFactory) su kurallara uyuyor mu?
    1) Yol cozumu: dizin -> <dizin>\veritabani.odb
    2) Yoksa v3 OLUSTUR (VDB3 imzasi), varsa ac
    3) Var olan v2 (VODB) dosyasi varsayilan olarak REDDEDILIR
    4) AllowV2=True ile v2 acilir ve motor SAHIPLENIR (kapaninca TVDb serbest)
    5) Sifreli v3: parola ile acilir; parolasiz acilis reddedilir
    6) Taninmayan bicim net hata verir

  Kullanim: factorychk [gecici_dizin]
}

{$mode delphi}{$H+}

uses
  { FPC/Unix: cthreads programin EN BASINDA olmali (TEvent/TThread). }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, VDbBackendApi, VDbBackendV3, VDbCore, VDbFactory;

var
  gPass, gFail: Int64;
  gDir: string;

procedure Ok(const S: string);
begin
  Inc(gPass);
  WriteLn('   OK   ', S);
end;

procedure Fail(const S: string);
begin
  Inc(gFail);
  WriteLn('   FAIL ', S);
end;

function P(const N: string): string;
begin
  Result := IncludeTrailingPathDelimiter(gDir) + N;
end;

procedure CleanDir;
var
  sr: TSearchRec;
  base, p: string;
begin
  base := IncludeTrailingPathDelimiter(gDir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
      begin
        p := base + sr.Name;
        if (sr.Attr and faDirectory) = 0 then
          DeleteFile(p);
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function MakeV2(const Dir: string): Boolean;
var
  kv: TVDb;
  v: TBytes;
begin
  Result := False;
  kv := TVDb.Create;
  try
    kv.Open(Dir);
    SetLength(v, 4);
    v[0] := 1; v[1] := 2; v[2] := 3; v[3] := 4;
    kv.Put(7, v);
    kv.Close;
    Result := True;
  finally
    kv.Free;
  end;
end;

procedure TestResolve;
var
  d, f: string;
begin
  WriteLn('1) yol cozumu');
  d := P('vt');
  ForceDirectories(d);
  f := VdbResolveFile(d);
  if SameText(f, IncludeTrailingPathDelimiter(d) + 'veritabani.odb') then
    Ok('dizin -> veritabani.odb: ' + f)
  else
    Fail('dizin cozumu yanlis: ' + f);
end;

procedure TestCreateV3;
var
  be: IVdbBackend;
  f: string;
begin
  WriteLn('2) v3 olusturma / acma');
  f := P('yeni.odb');
  be := VdbOpen(f);
  try
    if be.Count = 0 then
      Ok('bos veritabani: Count=0')
    else
      Fail('Count=0 bekleniyordu, gelen=' + IntToStr(be.Count));
    if SameText(be.FilePath, f) then
      Ok('FilePath dogru')
    else
      Fail('FilePath: ' + be.FilePath);
  finally
    be := nil;
  end;
  { Bicim kontrolu dosya KAPALIYKEN yapilir: v3 motoru dosyayi bayt-araligi
    kilidiyle tutar, ayni surecte ikinci okuma paylasim ihlaline ugrar. }
  if VdbFamilyOfFile(f) = vdfV3 then
    Ok('olusan dosya v3 imzali')
  else
    Fail('olusan dosya v3 degil');
  { Ayni dosyayi yeniden ac: yeni dosya olusturulmamali, icerik korunmali. }
  be := VdbOpen(f, False);
  try
    if be.Count = 0 then
      Ok('yeniden acildi (v3, Count=0)')
    else
      Fail('yeniden acilamadi');
  finally
    be := nil;
  end;
end;

procedure kvFreeCheck(const Dir: string); forward;

procedure TestV2Policy;
var
  be: IVdbBackend;
  d, f: string;
  refused: Boolean;
  msg: string;
begin
  WriteLn('3) v2 politikasi');
  d := P('eski_v2');
  ForceDirectories(d);
  if not MakeV2(d) then
  begin
    Fail('test icin v2 veritabani olusturulamadi');
    Exit;
  end;
  f := VdbResolveFile(d);
  if VdbFamilyOfFile(f) <> vdfV2 then
  begin
    Fail('test dosyasi v2 imzali degil');
    Exit;
  end;

  refused := False;
  msg := '';
  try
    be := VdbOpen(d, False);
    be := nil;
  except
    on E: EVdbFactory do
    begin
      refused := True;
      msg := E.Message;
    end;
  end;
  if refused then
    Ok('v2 varsayilan olarak reddedildi')
  else
    Fail('v2 kabul edildi (reddedilmeliydi)');
  if Pos('vdbmig', msg) > 0 then
    Ok('hata mesaji goc aracini gosteriyor')
  else
    Fail('hata mesaji yonlendirici degil: ' + msg);

  be := VdbOpen(d, False, True);
  try
    if be.Count = 1 then
      Ok('AllowV2=True: v2 acildi (Count=1)')
    else
      Fail('AllowV2 Count=1 bekleniyordu, gelen=' + IntToStr(be.Count));
  finally
    be := nil;
  end;

  { Sahiplik: Be nil olduktan sonra TVDb kapanmis ve dosya serbest olmali.
    Ayni dizini yeniden acabiliyorsak kapanis tamam demektir. }
  kvFreeCheck(d);
end;

procedure kvFreeCheck(const Dir: string);
var
  kv: TVDb;
begin
  kv := TVDb.Create;
  try
    kv.Open(Dir);
    Ok('v2 sahipligi: kapanistan sonra dizin yeniden acilabildi');
    kv.Close;
  finally
    kv.Free;
  end;
end;

procedure TestPassword;
var
  be: IVdbBackend;
  f: string;
  refused: Boolean;
begin
  WriteLn('4) sifreli v3');
  f := P('sifreli.odb');
  be := VdbOpenWithPassword(f, 'gizli-parola');
  be := nil;
  if VdbFamilyOfFile(f) = vdfV3 then
    Ok('sifreli dosya olustu (v3 imzali)')
  else
    Fail('sifreli dosya olusmadi');

  refused := False;
  try
    be := VdbOpen(f, False);
    be := nil;
  except
    on E: Exception do
      refused := True;
  end;
  if refused then
    Ok('parolasiz acilis reddedildi')
  else
    Fail('parolasiz acilis kabul edildi');

  be := VdbOpenWithPassword(f, 'gizli-parola', False);
  try
    Ok('dogru parola ile acildi (Count=' + IntToStr(be.Count) + ')');
  finally
    be := nil;
  end;
end;

procedure TestUnknown;
var
  f: TFileStream;
  be: IVdbBackend;
  refused: Boolean;
  b: array[0..7] of Byte;
begin
  WriteLn('5) taninmayan bicim');
  f := TFileStream.Create(P('bozuk.odb'), fmCreate);
  try
    FillChar(b, SizeOf(b), 0);
    f.WriteBuffer(b, SizeOf(b));
  finally
    f.Free;
  end;
  refused := False;
  try
    be := VdbOpen(P('bozuk.odb'), False);
    be := nil;
  except
    on E: EVdbFactory do
      refused := True;
  end;
  if refused then
    Ok('taninmayan dosya reddedildi')
  else
    Fail('taninmayan dosya kabul edildi');
end;

begin
  gPass := 0;
  gFail := 0;
  if ParamCount >= 1 then
    gDir := ParamStr(1)
  else
    gDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
      'factorychk_tmp';
  gDir := ExcludeTrailingPathDelimiter(ExpandFileName(gDir));
  ForceDirectories(gDir);
  CleanDir;

  WriteLn('VDB v3 factorychk - uygulama giris noktasi kapisi');
  WriteLn('dizin=', gDir);
  WriteLn;

  TestResolve;
  TestCreateV3;
  TestV2Policy;
  TestPassword;
  TestUnknown;

  WriteLn;
  WriteLn('================================================');
  WriteLn(Format('SONUC: gecen=%d kalan=%d', [gPass, gFail]));
  if gFail = 0 then
  begin
    WriteLn('FACTORY DOGRULANDI');
    Halt(0);
  end;
  WriteLn('FACTORY HATALI');
  Halt(1);
end.
