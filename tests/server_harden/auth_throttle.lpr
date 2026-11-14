{ R-4 kalici kapi: kimlik dogrulama denemesi sinirlama (throttling/lockout).

  Kapsam: TVdbPgServer'in ceza defteri (bellek ici). Ag uzerinden SCRAM
  denemesi yapilmaz; sayac/kilit kararlari dogrudan API ile dogrulanir.
  Boylece kapÄ± hizli ve deterministiktir; SCRAM akisinin bu API'yi
  cagirdigi VDbPgWire.DoScramAuth icinde tek satirlik kancalarla sabittir.

  Kosum: auth_throttle.exe  (fpc ile derlenir, .lpi gerekmez) }
program auth_throttle;
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbPgWire;

var
  GPass, GFail: Integer;
  TestDir: string;

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

function FreshDir(const AName: string): string;
var
  sr: TSearchRec;
begin
  Result := IncludeTrailingPathDelimiter(TestDir) + 'at_' + AName;
  if DirectoryExists(Result) then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(Result) + '*', faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Name <> '.') and (sr.Name <> '..') then
          DeleteFile(IncludeTrailingPathDelimiter(Result) + sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end
  else
    ForceDirectories(Result);
end;

function NewServer(const AName: string): TVdbPgServer;
begin
  Result := TVdbPgServer.Create(FreshDir(AName), 54000);
  Result.AddUser('kilit', 'parola123');
end;

procedure TestDefaults;
var
  s: TVdbPgServer;
  i: Integer;
begin
  s := NewServer('default');
  try
    Chk('T1a baslangicta kilit yok', not s.AuthLocked('kilit'), '');
    for i := 1 to 4 do
      s.NoteAuthFailure('kilit');
    Chk('T1b 4 hata sonrasi kilit yok', not s.AuthLocked('kilit'),
      'sayac=' + IntToStr(s.AuthFailureCount('kilit')));
    s.NoteAuthFailure('kilit');
    Chk('T1c 5 hata sonrasi kilitli', s.AuthLocked('kilit'),
      'sayac=' + IntToStr(s.AuthFailureCount('kilit')));
    Chk('T1d baska kullanici etkilenmez', not s.AuthLocked('baska'), '');
    s.NoteAuthSuccess('kilit');
    Chk('T1e basarili giris kilidi ve sayaci siler',
      (not s.AuthLocked('kilit')) and (s.AuthFailureCount('kilit') = 0), '');
  finally
    s.Free;
  end;
end;

procedure TestDisabled;
var
  s: TVdbPgServer;
  i: Integer;
begin
  s := NewServer('disabled');
  try
    s.AuthMaxFailures := 0;
    s.AuthGlobalMaxFailures := 0;
    for i := 1 to 20 do
      s.NoteAuthFailure('kilit');
    Chk('T2a AuthMaxFailures=0 kilidi kapatir', not s.AuthLocked('kilit'),
      'sayac=' + IntToStr(s.AuthFailureCount('kilit')));
    s.AuthMaxFailures := 3;
    s.AuthLockoutSeconds := 0;
    s.AuthReset;
    for i := 1 to 10 do
      s.NoteAuthFailure('kilit');
    Chk('T2b AuthLockoutSeconds=0 kilit uretmez', not s.AuthLocked('kilit'),
      'sayac=' + IntToStr(s.AuthFailureCount('kilit')));
  finally
    s.Free;
  end;
end;

procedure TestWindowExpiry;
var
  s: TVdbPgServer;
  i: Integer;
begin
  s := NewServer('window');
  try
    s.AuthMaxFailures := 3;
    s.AuthFailureWindowSeconds := 1;
    s.AuthLockoutSeconds := 1;
    for i := 1 to 3 do
      s.NoteAuthFailure('kilit');
    Chk('T3a esik asildi -> kilitli', s.AuthLocked('kilit'), '');
    Sleep(1200);
    Chk('T3b kilit suresi doldu -> acik', not s.AuthLocked('kilit'), '');
    Chk('T3c pencere doldu -> sayac sifir', s.AuthFailureCount('kilit') = 0, '');
    s.NoteAuthFailure('kilit');
    Chk('T3d yeni pencerede tek hata kilit kurmaz',
      (not s.AuthLocked('kilit')) and (s.AuthFailureCount('kilit') = 1), '');
  finally
    s.Free;
  end;
end;

procedure TestGlobalSpray;
var
  s: TVdbPgServer;
  i: Integer;
  u: string;
begin
  s := NewServer('global');
  try
    s.AuthMaxFailures := 100;
    s.AuthFailureWindowSeconds := 60;
    s.AuthLockoutSeconds := 60;
    s.AuthGlobalMaxFailures := 3;
    for i := 1 to 3 do
    begin
      u := 'sahte' + IntToStr(i);
      s.NoteAuthFailure(u);
    end;
    Chk('T4a toplam esik asildi -> herkes kilitli',
      s.AuthLocked('baska') and s.AuthLocked('kilit'), '');
    s.AuthReset;
    Chk('T4b AuthReset her seyi siler',
      (not s.AuthLocked('baska')) and (not s.AuthLocked('kilit')), '');
  finally
    s.Free;
  end;
end;

procedure TestMisc;
var
  s: TVdbPgServer;
begin
  s := NewServer('misc');
  try
    s.NoteAuthFailure('');
    Chk('T5a bos kullanici adi sayilmaz', not s.AuthLocked(''), '');
    s.NoteAuthFailure('KILIT');
    Chk('T5b kullanici adi buyuk/kucuk harf duyarli',
      (not s.AuthLocked('kilit')) and (s.AuthFailureCount('KILIT') = 1), '');
    s.ClearUsers;
    Chk('T5c ClearUsers cezalari da siler',
      (not s.AuthLocked('KILIT')) and (s.AuthFailureCount('KILIT') = 0), '');
  finally
    s.Free;
  end;
end;

begin
  GPass := 0;
  GFail := 0;
  TestDir := IncludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(ParamStr(0)))) + 'tmp';
  ForceDirectories(TestDir);
  WriteLn('ceza defteri kipi: bellek ici, diske yazilmaz');
  TestDefaults;
  TestDisabled;
  TestWindowExpiry;
  TestGlobalSpray;
  TestMisc;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  Halt(GFail);
end.
