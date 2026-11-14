program tls_client_gate;
{ VDB-V3 / R-4: TLS istemci dogrulama kapisi.

  Kanitlanan sozlesme:
    - TVdbTlsContext.CreateClient CA dosyasi olmadan kurulamaz.
    - CA'si dogru + sunucu adi dogru  -> el sikismasi basarili, veri akar.
    - CA'si yanlis                      -> el sikismasi REDDEDILIR.
    - Adi uyusmayan sertifika           -> REDDEDILIR (X509_check_host).
    - Sunucu tarafi SSLv2/SSLv3 teklif etmez (guvenli varsayilan).

  Fikstur: tests/tls_fixtures/*.crt (gen_certs.py ile uretilir).
  OpenSSL yoksa kapi 77 ile ATLANDI der (basarisiz sayilmaz). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbNet, VDbTls;

var
  GPass: Integer = 0;
  GFail: Integer = 0;

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

function FixtureDir: string;
var
  cand: array[0..4] of string;
  i: Integer;
  base: string;
begin
  Result := SysUtils.GetEnvironmentVariable('VDB_TLS_FIXTURES');
  if (Result <> '') and FileExists(IncludeTrailingPathDelimiter(Result) + 'ca.crt') then
  begin
    Result := IncludeTrailingPathDelimiter(Result);
    Exit;
  end;
  base := ExtractFilePath(ExpandFileName(ParamStr(0)));
  cand[0] := base + 'tls_fixtures' + PathDelim;
  cand[1] := base + '..' + PathDelim + 'tls_fixtures' + PathDelim;
  cand[2] := base + '..' + PathDelim + '..' + PathDelim + 'tests' + PathDelim +
    'tls_fixtures' + PathDelim;
  cand[3] := base + '..' + PathDelim + '..' + PathDelim + '..' + PathDelim +
    'tests' + PathDelim + 'tls_fixtures' + PathDelim;
  cand[4] := base + '..' + PathDelim + '..' + PathDelim + '..' + PathDelim +
    '..' + PathDelim + 'tests' + PathDelim + 'tls_fixtures' + PathDelim;
  for i := 0 to 4 do
    if FileExists(ExpandFileName(cand[i] + 'ca.crt')) then
    begin
      Result := ExpandFileName(cand[i]);
      Exit;
    end;
  Result := '';
end;

type
  { Istemci denemelerini karsilayan tek is parcacigi: her baglanti icin
    el sikismasi + 4 baytlik yanki. Basarisiz el sikismasi sunucuyu
    durdurmaz; hata listeye yazilir ve sonraki baglanti beklenir. }
  TServerThread = class(TThread)
  private
    FCtx: TVdbTlsContext;
    FListen: TVdbSocket;
    FCount: Integer;
  public
    Errors: TStringList;
    constructor Create(ACtx: TVdbTlsContext; AListen: TVdbSocket;
      ACount: Integer);
    destructor Destroy; override;
    procedure Execute; override;
  end;

constructor TServerThread.Create(ACtx: TVdbTlsContext; AListen: TVdbSocket;
  ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCtx := ACtx;
  FListen := AListen;
  FCount := ACount;
  Errors := TStringList.Create;
end;

destructor TServerThread.Destroy;
begin
  Errors.Free;
  inherited Destroy;
end;

procedure TServerThread.Execute;
var
  i: Integer;
  sock: TVdbSocket;
  sess: TVdbTlsSession;
  err: string;
  buf: array[0..7] of AnsiChar;
  n: Integer;
begin
  for i := 1 to FCount do
  begin
    sock := VdbTcpAccept(FListen);
    if sock = VDB_SOCK_INVALID then
    begin
      Errors.Add('accept basarisiz');
      Break;
    end;
    sess := nil;
    if not FCtx.Accept(sock, sess, err) then
    begin
      Errors.Add('sunucu el sikismasi: ' + err);
      if sess <> nil then sess.Free;
      VdbSockClose(sock);
      Continue;
    end;
    try
      n := sess.Read(@buf[0], 4);
      if n = 4 then
        sess.Write(@buf[0], 4);
    finally
      sess.Free;
    end;
    VdbSockClose(sock);
  end;
end;

type
  TClientOutcome = record
    Ok: Boolean;
    Err: string;
    Echo: string;
  end;

{ Tek deneme: baglan + el sikismasi + yanki. Kurucu istisnasi da
  basarisizlik olarak raporlanir (CA yok vb.). }
function TryClient(const ACaFile, AHostName: string; APort: Word): TClientOutcome;
var
  sock: TVdbSocket;
  ctx: TVdbTlsContext;
  sess: TVdbTlsSession;
  err: string;
  buf: array[0..7] of AnsiChar;
  n: Integer;
begin
  Result.Ok := False;
  Result.Err := '';
  Result.Echo := '';
  sock := VdbTcpConnect('127.0.0.1', APort);
  if sock = VDB_SOCK_INVALID then
  begin
    Result.Err := 'TCP baglantisi kurulamadi';
    Exit;
  end;
  ctx := nil;
  sess := nil;
  try
    try
      ctx := TVdbTlsContext.CreateClient(ACaFile, AHostName);
    except
      on E: Exception do
      begin
        Result.Err := 'kurucu: ' + E.Message;
        Exit;
      end;
    end;
    if not ctx.Connect(sock, sess, err) then
    begin
      Result.Err := err;
      Exit;
    end;
    try
      buf[0] := 'P';
      buf[1] := 'I';
      buf[2] := 'N';
      buf[3] := 'G';
      if sess.Write(@buf[0], 4) <> 4 then
      begin
        Result.Err := 'yazma basarisiz';
        Exit;
      end;
      FillChar(buf, SizeOf(buf), 0);
      n := sess.Read(@buf[0], 4);
      if n <> 4 then
      begin
        Result.Err := 'okuma basarisiz';
        Exit;
      end;
      Result.Echo := string(AnsiString(PAnsiChar(@buf[0])));
      Result.Ok := Result.Echo = 'PING';
      if not Result.Ok then
        Result.Err := 'yanki uyusmuyor: ' + Result.Echo;
    finally
      sess.Free;
      sess := nil;
    end;
  finally
    if sess <> nil then sess.Free;
    ctx.Free;
    VdbSockClose(sock);
  end;
end;

var
  fx: string;
  sctx: TVdbTlsContext;
  lst: TVdbSocket;
  thr: TServerThread;
  port, i: Integer;
  o: TClientOutcome;
  raised: Boolean;

begin
  fx := FixtureDir;
  if fx = '' then
  begin
    WriteLn('FAIL fikstur dizini bulunamadi (tests/tls_fixtures)');
    Halt(1);
  end;
  WriteLn('fikstur: ', fx);

  if not VDbTlsAvailable then
  begin
    WriteLn('ATLANDI: OpenSSL yuklenemedi: ', VDbTlsLastError);
    Halt(77);
  end;
  WriteLn('OpenSSL: yuklendi');

  { --- 1. Kurucu sozlesmesi (ag gerekmez) --- }
  raised := False;
  try
    sctx := TVdbTlsContext.CreateClient('', '');
    sctx.Free;
  except
    on E: EVdbTlsError do raised := True;
  end;
  Chk('C1 CA olmadan istemci kurulamaz', raised, 'EVdbTlsError beklenir');

  raised := False;
  try
    sctx := TVdbTlsContext.CreateClient(fx + 'yok_boyle_ca.crt', 'localhost');
    sctx.Free;
  except
    on E: EVdbTlsError do raised := True;
  end;
  Chk('C2 var olmayan CA reddedilir', raised, 'EVdbTlsError beklenir');

  { --- 2. Sunucu kur (gercek TLS) --- }
  sctx := TVdbTlsContext.CreateServer(fx + 'server.crt', fx + 'server.key');
  lst := VDB_SOCK_INVALID;
  port := 0;
  for i := 0 to 40 do
  begin
    lst := VdbTcpListen('127.0.0.1', Word(54700 + i));
    if lst <> VDB_SOCK_INVALID then
    begin
      port := 54700 + i;
      Break;
    end;
  end;
  if lst = VDB_SOCK_INVALID then
  begin
    WriteLn('FAIL S0 dinleme soketi kurulamadi');
    sctx.Free;
    Halt(1);
  end;
  WriteLn('sunucu: 127.0.0.1:', port);

  thr := TServerThread.Create(sctx, lst, 3);
  thr.Start;

  { --- 3. Pozitif: dogru CA + dogru ad --- }
  o := TryClient(fx + 'ca.crt', 'localhost', Word(port));
  Chk('C3 dogru CA + localhost kabul', o.Ok, o.Err + o.Echo);

  { --- 4. Negatif: yanlis CA --- }
  o := TryClient(fx + 'wrong_ca.crt', 'localhost', Word(port));
  Chk('C4 yanlis CA reddedilir', (not o.Ok) and (o.Err <> ''), o.Err);

  { --- 5. Negatif: ad uyusmazligi (sertifika example.invalid) --- }
  o := TryClient(fx + 'ca.crt', 'example.invalid', Word(port));
  Chk('C5 ad uyusmazligi reddedilir',
    (not o.Ok) and (Pos('uyusmuyor', o.Err) > 0), o.Err);

  thr.WaitFor;
  Chk('S1 sunucu tarafi hatalari beklenen',
    thr.Errors.Count >= 1, 'kayit=' + IntToStr(thr.Errors.Count));
  for i := 0 to thr.Errors.Count - 1 do
    WriteLn('  sunucu: ', thr.Errors[i]);
  thr.Free;
  VdbSockClose(lst);
  sctx.Free;

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  Halt(GFail);
end.
