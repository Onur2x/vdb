program server_harden;

{ PHASE-2 kalici kapi: R-4 SUNUCU SERTLESTIRME.

  Skill EK-A R-4 / Â§7.2: acik (trust) mod YALNIZ loopback'e baglanabilir;
  disa acik adres + trust REDDEDILIR (sessizce loopback'e dusmek yok).
  Bu kapi karari hem saf fonksiyon duzeyinde (truth table) hem de gercek
  TVdbPgServer bind/connect yolu uzerinde kanitlar.

  Senaryolar:
   S1  loopback tanima tablosu (localhost/127.x/::1 evet, 0.0.0.0/LAN hayir)
   S2  trust + adres istenmedi  -> 127.0.0.1'e cekilir, hata yok
   S3  trust + 0.0.0.0          -> RED (hata dolu, sonuc bos)
   S4  trust + LAN adresi       -> RED
   S5  trust + localhost        -> 127.0.0.1 (ad cozumlemesi yok, sabit esleme)
   S6  auth var + adres yok     -> 0.0.0.0 (eski davranis korunur)
   S7  auth var + LAN adresi    -> kabul
   S8  gecersiz/cozulemeyen ad  -> RED
   S9  cozulemeyen adrese bind  -> dinleme soketi ACILMAZ (sessiz 0.0.0.0 yok)
   S10 gercek sunucu 127.0.0.1'e baglanir ve loopback'ten baglanti kabul eder
   S11 gercek sunucu yerel olmayan adrese baglanmayi reddeder

  Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbNet, VDbPgWire;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' - ', ADetail);
  end;
end;

function TestDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

function FreshDir(const AName: string): string;
var
  sr: TSearchRec;
begin
  Result := IncludeTrailingPathDelimiter(TestDir + PathDelim + 'sh_' + AName);
  if not DirectoryExists(Result) then
    ForceDirectories(Result)
  else if FindFirst(Result + PathDelim + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') and
        ((sr.Attr and faDirectory) = 0) then
        DeleteFile(Result + PathDelim + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ ------------------------------------------------------------------ S1 }

procedure TestLoopbackTable;
begin
  Chk('S1 localhost loopback', VdbHostIsLoopback('localhost'), 'localhost');
  Chk('S1 LOCALHOST buyuk harf', VdbHostIsLoopback('LocalHost'), 'LocalHost');
  Chk('S1 127.0.0.1 loopback', VdbHostIsLoopback('127.0.0.1'), '127.0.0.1');
  Chk('S1 127.9.8.7 loopback', VdbHostIsLoopback('127.9.8.7'), '127.9.8.7');
  Chk('S1 ::1 loopback', VdbHostIsLoopback('::1'), '::1');
  Chk('S1 0.0.0.0 loopback DEGIL', not VdbHostIsLoopback('0.0.0.0'), '0.0.0.0');
  Chk('S1 bos dizgi loopback DEGIL', not VdbHostIsLoopback(''), 'bos');
  Chk('S1 LAN adresi loopback DEGIL',
    not VdbHostIsLoopback('192.168.1.20'), '192.168.1.20');
  Chk('S1 bozuk 127 dizgisi DEGIL',
    not VdbHostIsLoopback('127.0.0.1x'), '127.0.0.1x');
  Chk('S1 127 tek parca DEGIL', not VdbHostIsLoopback('127'), '127');
end;

{ ------------------------------------------------------------------ S2..S8 }

procedure ChkResolve(const AName, AReq: string; ATrust: Boolean;
  const AExpect: string; AExpectErr: Boolean);
var
  h, e: string;
begin
  h := VdbResolveListenHost(AReq, ATrust, e);
  Chk(AName, (h = AExpect) and ((e <> '') = AExpectErr),
    'sonuc="' + h + '" hata="' + e + '"');
end;

procedure TestResolve;
begin
  ChkResolve('S2 trust + varsayilan -> loopback', '', True, '127.0.0.1', False);
  ChkResolve('S3 trust + 0.0.0.0 -> RED', '0.0.0.0', True, '', True);
  ChkResolve('S4 trust + LAN -> RED', '192.168.1.20', True, '', True);
  ChkResolve('S4b trust + 127.0.0.2 -> kabul', '127.0.0.2', True, '127.0.0.2', False);
  ChkResolve('S5 trust + localhost -> 127.0.0.1', 'localhost', True,
    '127.0.0.1', False);
  ChkResolve('S6 auth + varsayilan -> 0.0.0.0', '', False, '0.0.0.0', False);
  ChkResolve('S7 auth + LAN -> kabul', '192.168.1.20', False,
    '192.168.1.20', False);
  ChkResolve('S8 gecersiz ad -> RED', 'veritabani.local', False, '', True);
  ChkResolve('S8b IPv6 -> IPv4 esleme', '::1', False, '127.0.0.1', False);
end;

{ ------------------------------------------------------------------ S9 }

procedure TestListenHost;
var
  s: TVdbSocket;
begin
  s := VdbTcpListen('cozulemez-ad', 54397);
  Chk('S9 cozulemez adrese dinleme acilmaz', s = VDB_SOCK_INVALID,
    'soket gecerli dondu');
  if s <> VDB_SOCK_INVALID then VdbSockClose(s);

  s := VdbTcpListen('127.0.0.1', 54397);
  Chk('S9b loopback dinleme acilir', s <> VDB_SOCK_INVALID, 'bind basarisiz');
  if s <> VDB_SOCK_INVALID then VdbSockClose(s);
end;

{ ------------------------------------------------------------------ S10 }

procedure TestServerLoopback;
var
  srv: TVdbPgServer;
  sock: TVdbSocket;
  dir, err: string;
  port, i: Integer;
  started: Boolean;
begin
  dir := FreshDir('bind');
  srv := nil;
  port := 0;
  started := False;
  err := '';
  for i := 0 to 59 do
  begin
    srv := TVdbPgServer.Create(dir, Word(54300 + i));
    srv.AddUser('harden', 'parola123');
    srv.BindHost := '127.0.0.1';
    if srv.Start(err) then
    begin
      port := 54300 + i;
      started := True;
      Break;
    end;
    FreeAndNil(srv);
  end;
  Chk('S10 loopback bind ile sunucu basladi', started, err);
  if not started then
  begin
    if srv <> nil then srv.Free;
    Exit;
  end;
  try
    sock := VdbTcpConnect('127.0.0.1', Word(port));
    Chk('S10b loopback baglanti kabul edildi', sock <> VDB_SOCK_INVALID,
      'connect basarisiz (port ' + IntToStr(port) + ')');
    if sock <> VDB_SOCK_INVALID then VdbSockClose(sock);
  finally
    srv.Stop;
    srv.Free;
  end;
end;

{ ------------------------------------------------------------------ S11 }

procedure TestServerForeignBind;
var
  srv: TVdbPgServer;
  dir, err: string;
  ok: Boolean;
begin
  dir := FreshDir('foreign');
  srv := TVdbPgServer.Create(dir, 54396);
  srv.AddUser('harden', 'parola123');
  { TEST-NET-3 (RFC 5737): bu makineye ait olmayan, yonlendirilmeyen adres. }
  srv.BindHost := '203.0.113.7';
  ok := srv.Start(err);
  Chk('S11 yerel olmayan adres reddedildi',
    (not ok) and (err <> '') and (Pos('203.0.113.7', err) > 0),
    'Start sonucu=' + BoolToStr(ok, True) + ' hata="' + err + '"');
  srv.Free;
end;

begin
  GPass := 0;
  GFail := 0;
  WriteLn('server_harden: R-4 sunucu sertlestirme kapisi');
  TestLoopbackTable;
  TestResolve;
  TestListenHost;
  TestServerLoopback;
  TestServerForeignBind;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  Halt(GFail);
end.
