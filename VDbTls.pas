unit VDbTls;
{ VDbTls - M1: sunucu/istemci TLS'i icin ince OpenSSL sarmalayicisi.

  Neden dinamik yukleme: motorun cekirdek derlemesi OpenSSL'e bagimli
  olmasin. DLL yoksa TLS ozelligi kapali kalir; sunucu TLS istendiginde
  acik bir hata verir. Desteklenen kutuphaneler: OpenSSL 3
  (libssl-3/libcrypto-3), OpenSSL 1.1 (libssl-1_1/libcrypto-1_1) ve
  eski 1.0.2 (ssleay32/libeay32).

  Not: Sertifika/anahtar PEM dosyasidir. Yolun ASCII olmasi onerilir;
  OpenSSL dosya adini yerel kod sayfasiyla acar. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, VDbNet;

type
  EVdbTlsError = class(Exception);

  TVdbTlsSession = class;

  TVdbTlsContext = class
  private
    FCtx: Pointer;
    FIsClient: Boolean;
  public
    constructor CreateServer(const ACertFile, AKeyFile: string);
    constructor CreateClient;
    destructor Destroy; override;
    function Accept(ASock: TVdbSocket; out ASession: TVdbTlsSession;
      out AErr: string): Boolean;
    function Connect(ASock: TVdbSocket; out ASession: TVdbTlsSession;
      out AErr: string): Boolean;
    property IsClient: Boolean read FIsClient;
  end;

  TVdbTlsSession = class
  private
    FSSL: Pointer;
  public
    constructor Create(ASSL: Pointer);
    destructor Destroy; override;
    function Read(ABuf: Pointer; ALen: Integer): Integer;
    function Write(ABuf: Pointer; ALen: Integer): Integer;
    procedure Shutdown;
  end;

function VDbTlsAvailable: Boolean;
function VDbTlsLastError: string;

implementation

uses
  {$IFDEF WINDOWS}Windows, {$ENDIF}dynlibs;

const
  SSL_FILETYPE_PEM = 1;
  SSL_VERIFY_NONE = 0;
  SSL_ERROR_WANT_READ = 2;
  SSL_ERROR_WANT_WRITE = 3;
  SSL_ERROR_ZERO_RETURN = 6;

type
  TfnOpenSslInit = function(AOpts: QWord; ASettings: Pointer): Integer; cdecl;
  TfnMethod = function: Pointer; cdecl;
  TfnCtxNew = function(AMethod: Pointer): Pointer; cdecl;
  TfnCtxFree = procedure(ACtx: Pointer); cdecl;
  TfnCtxUseFile = function(ACtx: Pointer; const AFile: PAnsiChar;
    AType: Integer): Integer; cdecl;
  TfnCtxCheckKey = function(ACtx: Pointer): Integer; cdecl;
  TfnCtxSetVerify = procedure(ACtx: Pointer; AMode: Integer;
    ACallback: Pointer); cdecl;
  TfnSslNew = function(ACtx: Pointer): Pointer; cdecl;
  TfnSslFree = procedure(ASsl: Pointer); cdecl;
  TfnBioNewSocket = function(AFd, ACloseFlag: Integer): Pointer; cdecl;
  TfnSslSetBio = procedure(ASsl, ARbio, AWbio: Pointer); cdecl;
  TfnSslAccept = function(ASsl: Pointer): Integer; cdecl;
  TfnSslConnect = function(ASsl: Pointer): Integer; cdecl;
  TfnSslRead = function(ASsl: Pointer; ABuf: Pointer; ALen: Integer): Integer; cdecl;
  TfnSslWrite = function(ASsl: Pointer; ABuf: Pointer; ALen: Integer): Integer; cdecl;
  TfnSslShutdown = function(ASsl: Pointer): Integer; cdecl;
  TfnSslGetError = function(ASsl: Pointer; ARet: Integer): Integer; cdecl;
  TfnErrGetError = function: QWord; cdecl;
  TfnErrString = procedure(AErr: QWord; ABuf: PAnsiChar; ALen: NativeUInt); cdecl;
  TfnVoid = procedure; cdecl;
  TfnInt = function: Integer; cdecl;

var
  GLock: SyncObjs.TCriticalSection;
  GInitDone: Boolean;
  GInitOk: Boolean;
  GInitErr: string;
  GOpenSslInit: TfnOpenSslInit;
  GServerMethod, GClientMethod: TfnMethod;
  GCtxNew: TfnCtxNew;
  GCtxFree: TfnCtxFree;
  GCtxUseCert, GCtxUseKey: TfnCtxUseFile;
  GCtxCheckKey: TfnCtxCheckKey;
  GCtxSetVerify: TfnCtxSetVerify;
  GSslNew: TfnSslNew;
  GSslFree: TfnSslFree;
  GBioNewSocket: TfnBioNewSocket;
  GSslSetBio: TfnSslSetBio;
  GSslAccept: TfnSslAccept;
  GSslConnect: TfnSslConnect;
  GSslRead: TfnSslRead;
  GSslWrite: TfnSslWrite;
  GSslShutdown: TfnSslShutdown;
  GSslGetError: TfnSslGetError;
  GErrGetError: TfnErrGetError;
  GErrString: TfnErrString;

function LastOpenSslError: string;
var
  e: QWord;
  buf: array[0..255] of AnsiChar;
begin
  Result := '';
  if not Assigned(GErrGetError) then Exit;
  e := GErrGetError();
  if (e = 0) or (not Assigned(GErrString)) then Exit;
  FillChar(buf, SizeOf(buf), 0);
  GErrString(e, @buf[0], SizeOf(buf) - 1);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
end;

function LoadPair(const ASslName, ACryptoName: string;
  out AErr: string): Boolean;
var
  hs, hc: TLibHandle;

  function Sym(AHandle: TLibHandle; const AName: string): Pointer;
  begin
    Result := GetProcAddress(AHandle, PAnsiChar(AnsiString(AName)));
  end;

var
  p: Pointer;
begin
  Result := False;
  AErr := '';
  hc := LoadLibrary(ACryptoName);
  if hc = NilHandle then
  begin
    AErr := ACryptoName + ' yuklenemedi: ' + GetLoadErrorStr;
    Exit;
  end;
  hs := LoadLibrary(ASslName);
  if hs = NilHandle then
  begin
    AErr := ASslName + ' yuklenemedi: ' + GetLoadErrorStr;
    UnloadLibrary(hc);
    Exit;
  end;

  GCtxNew := TfnCtxNew(Sym(hs, 'SSL_CTX_new'));
  GCtxFree := TfnCtxFree(Sym(hs, 'SSL_CTX_free'));
  GCtxUseCert := TfnCtxUseFile(Sym(hs, 'SSL_CTX_use_certificate_file'));
  GCtxUseKey := TfnCtxUseFile(Sym(hs, 'SSL_CTX_use_PrivateKey_file'));
  GCtxCheckKey := TfnCtxCheckKey(Sym(hs, 'SSL_CTX_check_private_key'));
  GCtxSetVerify := TfnCtxSetVerify(Sym(hs, 'SSL_CTX_set_verify'));
  GSslNew := TfnSslNew(Sym(hs, 'SSL_new'));
  GSslFree := TfnSslFree(Sym(hs, 'SSL_free'));
  GSslSetBio := TfnSslSetBio(Sym(hs, 'SSL_set_bio'));
  GSslAccept := TfnSslAccept(Sym(hs, 'SSL_accept'));
  GSslConnect := TfnSslConnect(Sym(hs, 'SSL_connect'));
  GSslRead := TfnSslRead(Sym(hs, 'SSL_read'));
  GSslWrite := TfnSslWrite(Sym(hs, 'SSL_write'));
  GSslShutdown := TfnSslShutdown(Sym(hs, 'SSL_shutdown'));
  GSslGetError := TfnSslGetError(Sym(hs, 'SSL_get_error'));
  GBioNewSocket := TfnBioNewSocket(Sym(hc, 'BIO_new_socket'));
  GErrGetError := TfnErrGetError(Sym(hc, 'ERR_get_error'));
  GErrString := TfnErrString(Sym(hc, 'ERR_error_string_n'));

  p := Sym(hs, 'TLS_server_method');
  if p = nil then p := Sym(hs, 'SSLv23_server_method');
  GServerMethod := TfnMethod(p);
  p := Sym(hs, 'TLS_client_method');
  if p = nil then p := Sym(hs, 'SSLv23_client_method');
  GClientMethod := TfnMethod(p);

  p := Sym(hs, 'OPENSSL_init_ssl');
  GOpenSslInit := TfnOpenSslInit(p);

  if (not Assigned(GCtxNew)) or (not Assigned(GCtxFree)) or
     (not Assigned(GCtxUseCert)) or (not Assigned(GCtxUseKey)) or
     (not Assigned(GCtxCheckKey)) or (not Assigned(GCtxSetVerify)) or
     (not Assigned(GSslNew)) or (not Assigned(GSslFree)) or
     (not Assigned(GSslSetBio)) or (not Assigned(GSslAccept)) or
     (not Assigned(GSslConnect)) or (not Assigned(GSslRead)) or
     (not Assigned(GSslWrite)) or (not Assigned(GSslShutdown)) or
     (not Assigned(GSslGetError)) or (not Assigned(GBioNewSocket)) or
     (not Assigned(GErrGetError)) or (not Assigned(GErrString)) or
     (not Assigned(GServerMethod)) or (not Assigned(GClientMethod)) then
  begin
    AErr := ASslName + ': gerekli OpenSSL sembolleri eksik';
    UnloadLibrary(hs);
    UnloadLibrary(hc);
    Exit;
  end;

  if Assigned(GOpenSslInit) then
    GOpenSslInit(0, nil)
  else
  begin
    p := Sym(hs, 'SSL_library_init');
    if p <> nil then TfnInt(p)();
    p := Sym(hs, 'SSL_load_error_strings');
    if p <> nil then TfnVoid(p)();
  end;

  Result := True;
end;

function InitLibs: Boolean;
var
  err, envSsl, envCrypto: string;
begin
  if GInitDone then Exit(GInitOk);
  GLock.Enter;
  try
    if GInitDone then Exit(GInitOk);
    GInitDone := True;
    GInitOk := False;
    envSsl := SysUtils.GetEnvironmentVariable('VDB_SSL_DLL');
    envCrypto := SysUtils.GetEnvironmentVariable('VDB_CRYPTO_DLL');
    if (envSsl <> '') and (envCrypto <> '') then
      if LoadPair(envSsl, envCrypto, err) then
      begin
        GInitOk := True;
        Exit(True);
      end;
    if LoadPair('libssl-3.dll', 'libcrypto-3.dll', err) then
    begin
      GInitOk := True;
      Exit(True);
    end;
    if LoadPair('libssl-1_1.dll', 'libcrypto-1_1.dll', err) then
    begin
      GInitOk := True;
      Exit(True);
    end;
    if LoadPair('ssleay32.dll', 'libeay32.dll', err) then
    begin
      GInitOk := True;
      Exit(True);
    end;
    GInitErr := err;
    Result := False;
  finally
    GLock.Leave;
  end;
end;

function VDbTlsAvailable: Boolean;
begin
  Result := InitLibs;
end;

function VDbTlsLastError: string;
begin
  if InitLibs then Result := '' else Result := GInitErr;
end;

{ ---------------------------------------------------------------- baglam }

constructor TVdbTlsContext.CreateServer(const ACertFile, AKeyFile: string);
var
  method: Pointer;
  cert, key: AnsiString;

  procedure FailCtx(const AMsg: string);
  begin
    if FCtx <> nil then
    begin
      GCtxFree(FCtx);
      FCtx := nil;
    end;
    raise EVdbTlsError.Create(AMsg);
  end;

begin
  inherited Create;
  FCtx := nil;
  FIsClient := False;
  if not InitLibs then
    FailCtx('OpenSSL yuklenemedi: ' + GInitErr);
  method := GServerMethod();
  if method = nil then
    FailCtx('OpenSSL sunucu metodu yok');
  FCtx := GCtxNew(method);
  if FCtx = nil then
    FailCtx('SSL_CTX_new basarisiz: ' + LastOpenSslError);
  cert := AnsiString(ACertFile);
  key := AnsiString(AKeyFile);
  if GCtxUseCert(FCtx, PAnsiChar(cert), SSL_FILETYPE_PEM) <> 1 then
    FailCtx('sertifika yuklenemedi (' + ACertFile + '): ' + LastOpenSslError);
  if GCtxUseKey(FCtx, PAnsiChar(key), SSL_FILETYPE_PEM) <> 1 then
    FailCtx('ozel anahtar yuklenemedi (' + AKeyFile + '): ' + LastOpenSslError);
  if GCtxCheckKey(FCtx) <> 1 then
    FailCtx('sertifika/anahtar uyusmuyor: ' + LastOpenSslError);
end;

constructor TVdbTlsContext.CreateClient;
var
  method: Pointer;

  procedure FailCtx(const AMsg: string);
  begin
    if FCtx <> nil then
    begin
      GCtxFree(FCtx);
      FCtx := nil;
    end;
    raise EVdbTlsError.Create(AMsg);
  end;

begin
  inherited Create;
  FCtx := nil;
  FIsClient := True;
  if not InitLibs then
    FailCtx('OpenSSL yuklenemedi: ' + GInitErr);
  method := GClientMethod();
  if method = nil then
    FailCtx('OpenSSL istemci metodu yok');
  FCtx := GCtxNew(method);
  if FCtx = nil then
    FailCtx('SSL_CTX_new basarisiz: ' + LastOpenSslError);
  GCtxSetVerify(FCtx, SSL_VERIFY_NONE, nil);
end;

destructor TVdbTlsContext.Destroy;
begin
  if (FCtx <> nil) and Assigned(GCtxFree) then
    GCtxFree(FCtx);
  FCtx := nil;
  inherited Destroy;
end;

function TVdbTlsContext.Accept(ASock: TVdbSocket;
  out ASession: TVdbTlsSession; out AErr: string): Boolean;
var
  ssl, bio: Pointer;
  r, e: Integer;

  function FailCtx(const AMsg: string): Boolean;
  begin
    if ssl <> nil then GSslFree(ssl);
    ssl := nil;
    AErr := AMsg;
    Result := False;
  end;

begin
  Result := False;
  ASession := nil;
  AErr := '';
  if FCtx = nil then Exit(FailCtx('TLS baglami yok'));
  ssl := GSslNew(FCtx);
  if ssl = nil then Exit(FailCtx('SSL_new basarisiz: ' + LastOpenSslError));
  bio := GBioNewSocket(Integer(ASock), 0);
  if bio = nil then Exit(FailCtx('BIO_new_socket basarisiz: ' + LastOpenSslError));
  GSslSetBio(ssl, bio, bio);
  while True do
  begin
    r := GSslAccept(ssl);
    if r = 1 then Break;
    e := GSslGetError(ssl, r);
    if (e <> SSL_ERROR_WANT_READ) and (e <> SSL_ERROR_WANT_WRITE) then
      Exit(FailCtx('TLS el sikismasi basarisiz (SSL hata ' + IntToStr(e) + '): ' +
        LastOpenSslError));
  end;
  ASession := TVdbTlsSession.Create(ssl);
  Result := True;
end;

function TVdbTlsContext.Connect(ASock: TVdbSocket;
  out ASession: TVdbTlsSession; out AErr: string): Boolean;
var
  ssl, bio: Pointer;
  r, e: Integer;

  function FailCtx(const AMsg: string): Boolean;
  begin
    if ssl <> nil then GSslFree(ssl);
    ssl := nil;
    AErr := AMsg;
    Result := False;
  end;

begin
  Result := False;
  ASession := nil;
  AErr := '';
  if FCtx = nil then Exit(FailCtx('TLS baglami yok'));
  ssl := GSslNew(FCtx);
  if ssl = nil then Exit(FailCtx('SSL_new basarisiz: ' + LastOpenSslError));
  bio := GBioNewSocket(Integer(ASock), 0);
  if bio = nil then Exit(FailCtx('BIO_new_socket basarisiz: ' + LastOpenSslError));
  GSslSetBio(ssl, bio, bio);
  while True do
  begin
    r := GSslConnect(ssl);
    if r = 1 then Break;
    e := GSslGetError(ssl, r);
    if (e <> SSL_ERROR_WANT_READ) and (e <> SSL_ERROR_WANT_WRITE) then
      Exit(FailCtx('TLS istemci el sikismasi basarisiz (SSL hata ' +
        IntToStr(e) + '): ' + LastOpenSslError));
  end;
  ASession := TVdbTlsSession.Create(ssl);
  Result := True;
end;

{ ---------------------------------------------------------------- oturum }

constructor TVdbTlsSession.Create(ASSL: Pointer);
begin
  inherited Create;
  FSSL := ASSL;
end;

destructor TVdbTlsSession.Destroy;
begin
  if FSSL <> nil then
  begin
    if Assigned(GSslShutdown) then GSslShutdown(FSSL);
    GSslFree(FSSL);
  end;
  FSSL := nil;
  inherited Destroy;
end;

function TVdbTlsSession.Read(ABuf: Pointer; ALen: Integer): Integer;
var
  r, e: Integer;
begin
  if (FSSL = nil) or (ALen <= 0) then Exit(0);
  while True do
  begin
    r := GSslRead(FSSL, ABuf, ALen);
    if r > 0 then Exit(r);
    e := GSslGetError(FSSL, r);
    if (e = SSL_ERROR_WANT_READ) or (e = SSL_ERROR_WANT_WRITE) then
      Continue;
    if e = SSL_ERROR_ZERO_RETURN then Exit(0);
    Exit(-1);
  end;
end;

function TVdbTlsSession.Write(ABuf: Pointer; ALen: Integer): Integer;
var
  r, e: Integer;
begin
  if (FSSL = nil) or (ALen <= 0) then Exit(0);
  while True do
  begin
    r := GSslWrite(FSSL, ABuf, ALen);
    if r > 0 then Exit(r);
    e := GSslGetError(FSSL, r);
    if (e = SSL_ERROR_WANT_READ) or (e = SSL_ERROR_WANT_WRITE) then
      Continue;
    Exit(-1);
  end;
end;

procedure TVdbTlsSession.Shutdown;
begin
  if FSSL <> nil then GSslShutdown(FSSL);
end;

initialization
  GLock := SyncObjs.TCriticalSection.Create;

finalization
  GLock.Free;

end.
