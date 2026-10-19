unit VDbMetricsHttp;

{ M9 (2026-10-19): Prometheus /metrics icin kucuk HTTP ucu.

  Amac: motordan BAGIMSIZ, tek islevli bir HTTP dinleyicisi. SQL
  sunucusunun ikili protokolune dokunmaz; ayri portta calisir.

    GET /metrics   -> 200 text/plain; version=0.0.4 (Prometheus)
    diger her sey  -> 404

  Metrik govdesini cagiran taraf saglar (TVdbMetricsProvider). Boylece
  TVSql/veritabani kilidi uygulamanin kontrolunde kalir; bu birim
  yalnizca tasima yapar. Tipik kullanim:

    Srv := TVdbMetricsHttpServer.Create(9187, @MetricsSnapshot);
    Srv.Start;   // ... Srv.Stop;

  Notlar / sinirlar:
    - Baglantilar SIRAYLA islenir (tek is parcacigi).
    - Windows'ta okuma zaman asimi 5 sn; diger platformlarda yok.
    - TLS yok; uretimde ters vekil arkasinda kullanin.
}

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Sockets, VDbNet;

type
  { Cagiranin metrik govdesini ureten geri cagrisi. Sunucu is parcaciginda
    cagrilir; uygulama kendi kilidini kullanmalidir. }
  TVdbMetricsProvider = function: string of object;

  TVdbMetricsHttpServer = class
  private
    FPort: Word;
    FProvider: TVdbMetricsProvider;
    FListen: TVdbSocket;
    FThread: TThread;
    FRunning: Boolean;
    FStop: Boolean;
    procedure Serve;
  public
    constructor Create(APort: Word; AProvider: TVdbMetricsProvider);
    destructor Destroy; override;
    { Dinlemeye baslar. Port kullanilamiyorsa False. }
    function Start: Boolean;
    { Dinleyiciyi kapatir ve is parcacigini bekler. }
    procedure Stop;
    property Port: Word read FPort;
    property Running: Boolean read FRunning;
  end;

{ Saf yardimcilar (ag olmadan test edilebilir). }
function VdbMetricsHttpResponse(const Request, MetricsBody: string): string;

implementation

const
  HTTP_MAX_REQ = 16384;

function VdbMetricsHttpResponse(const Request, MetricsBody: string): string;
var
  body: string;
  code: string;
begin
  body := '';
  code := '404 Not Found';
  if Pos('GET /metrics', Request) = 1 then
  begin
    code := '200 OK';
    body := MetricsBody;
  end
  else
    body := 'not found' + #10;
  Result := 'HTTP/1.1 ' + code + #13#10 +
    'Content-Type: text/plain; version=0.0.4; charset=utf-8' + #13#10 +
    'Content-Length: ' + IntToStr(Length(body)) + #13#10 +
    'Connection: close' + #13#10 +
    #13#10 + body;
end;

function ReadHttpRequest(ASock: TVdbSocket): string;
var
  buf: array[0..4095] of Char;
  n: Integer;
begin
  Result := '';
  repeat
    n := VdbRecvSome(ASock, buf[0], SizeOf(buf));
    if n <= 0 then Break;
    SetLength(Result, Length(Result) + n);
    Move(buf[0], Result[Length(Result) - n + 1], n);
    if Pos(#13#10#13#10, Result) > 0 then Break;
    if Pos(#10#10, Result) > 0 then Break;
  until Length(Result) >= HTTP_MAX_REQ;
end;

type
  TVdbMetricsHttpThread = class(TThread)
  private
    FServer: TVdbMetricsHttpServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TVdbMetricsHttpServer);
  end;

constructor TVdbMetricsHttpThread.Create(AServer: TVdbMetricsHttpServer);
begin
  inherited Create(True);
  FServer := AServer;
  FreeOnTerminate := False;
end;

procedure TVdbMetricsHttpThread.Execute;
begin
  FServer.Serve;
end;

constructor TVdbMetricsHttpServer.Create(APort: Word;
  AProvider: TVdbMetricsProvider);
begin
  inherited Create;
  FPort := APort;
  FProvider := AProvider;
  FListen := VDB_SOCK_INVALID;
  FThread := nil;
  FRunning := False;
  FStop := False;
end;

destructor TVdbMetricsHttpServer.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TVdbMetricsHttpServer.Start: Boolean;
begin
  Result := False;
  if FRunning then Exit(True);
  FListen := VdbTcpListen(FPort);
  if FListen = VDB_SOCK_INVALID then Exit;
  FRunning := True;
  FStop := False;
  FThread := TVdbMetricsHttpThread.Create(Self);
  FThread.Start;
  Result := True;
end;

procedure TVdbMetricsHttpServer.Stop;
begin
  if not FRunning then Exit;
  FRunning := False;
  FStop := True;
  if FThread <> nil then
  begin
    FThread.Terminate;
    { Engellenmis accept'i uyandirmak icin dinleme soketini kapat. }
    VdbSockClose(FListen);
    FListen := VDB_SOCK_INVALID;
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
end;

procedure TVdbMetricsHttpServer.Serve;
var
  s: TVdbSocket;
  req, body, resp: string;
  {$IFDEF MSWINDOWS}
  rcvTo: DWORD;
  {$ENDIF}
begin
  while not FStop do
  begin
    s := VdbTcpAccept(FListen);
    if s = VDB_SOCK_INVALID then Break;
    try
      {$IFDEF MSWINDOWS}
      rcvTo := 5000;
      fpsetsockopt(s, SOL_SOCKET, SO_RCVTIMEO, @rcvTo, SizeOf(rcvTo));
      {$ENDIF}
      req := ReadHttpRequest(s);
      body := '';
      if Assigned(FProvider) and (Pos('GET /metrics', req) = 1) then
      begin
        try
          body := FProvider();
        except
          body := '# provider error' + #10;
        end;
      end;
      resp := VdbMetricsHttpResponse(req, body);
      VdbSendAll(s, resp[1], Length(resp));
    finally
      VdbSockClose(s);
    end;
    if FStop then Break;
  end;
end;

end.
