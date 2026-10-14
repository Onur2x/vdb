unit VDbClientNet;

{ R-12 Full (2026-10-13): TCP SQL ISTEMCISI — VDBS protokolu istemci tarafi.

  TVSql ile AYNI sonuc tipini (TSqlResult) dondurur; motoru HARICINDE
  calistirir, yani istemci surucusune/uygulamasina motor kodu gerekmez
  (yalnizca bu birim + VDbNet tasima katmani yeter).

  El sikisma: baglaninca SUNUCU ilk mesaji gonderir
    4 bayt 'VDBS' + u8 surum + str bilgi
  ve istemci dogrular; uyumsuzsa baglanti hemen kapatilir.

  Hata ayristirmasi:
    - EVdbClientError   : akis/protokol/uzak hata (sunucu ERROR cercevesi
                          veya baglanti kopmasi) — mesaj motorun veya
                          protokolun kendi mesajidir.
  Her yanit cercevesi u8 $00 SONU ISARETI ile biter; eksikse
  EVdbProtocolError yukselir (cerceve sinirlari bozulmasin). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbTypes, VDbAst, VDbNet;

type
  EVdbClientError = class(Exception);
  EVdbProtocolError = class(EVdbClientError);

  TVdbNetClient = class
  private
    FSock: TVdbSocket;
    FServerInfo: string;
    FProtoVer: Byte;
    FHost: string;
    FPort: Word;
    procedure RaiseDisconnected(const AOp: string);
    function ExpectTerm(const AOp: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { AHost:APort'a baglanir ve el sikismayi tamamlar.
      Hata: EVdbClientError. }
    procedure Connect(const AHost: string; APort: Word);
    procedure Disconnect;
    function Connected: Boolean;
    { SQL calistirir. Basarili: TSqlResult. Sunucu hatasi ya da akis
      hatasi: EVdbClientError yukselir (motor Exec ile AYNI semantik). }
    function Exec(const ASql: string): TSqlResult;
    { PING gonderir; PONG gelmezse EVdbClientError. }
    procedure Ping;
    { BYE gonderip baglantiyi kapatir. }
    procedure Bye;
    { VDBS oturumu: kullanici adi ve sifre ile oturum baslatir.
      Basarili: True, oturum aktif.
      Basarisiz: False, oturum yok. }
    function Login(const AUser, APass: string): Boolean;
    { OTURUMU sonuclandirir, oturum kimligi sifirlar.
      Baglanti kapatilmaz; yeni Login ile tekrar oturum baslatilabilir. }
    procedure Logout;
    { Hazirlanmis sorguyu hazirlaydi. ASql parametresiz sorgu olabilir.
      Basarili: True, hazirlandi.
      Basarisiz: False, hazirlanamadi. }
    function Prepare(const ASql: string): Boolean;
    { Daha once hazirlanmis sorguyu calistirir.
      Basarili: TSqlResult (sonuclar).
      Hata: EVdbClientError. }
    function ExecutePrepared: TSqlResult;
    property ServerInfo: string read FServerInfo;
    property ProtoVer: Byte read FProtoVer;
    property Host: string read FHost;
    property Port: Word read FPort;
  end;

implementation

constructor TVdbNetClient.Create;
begin
  inherited Create;
  FSock := VDB_SOCK_INVALID;
end;

destructor TVdbNetClient.Destroy;
begin
  Disconnect;
  inherited;
end;

function TVdbNetClient.Connected: Boolean;
begin
  Result := FSock <> VDB_SOCK_INVALID;
end;

procedure TVdbNetClient.RaiseDisconnected(const AOp: string);
begin
  raise EVdbClientError.Create('baglanti yok (islem: ' + AOp + ')');
end;

function TVdbNetClient.ExpectTerm(const AOp: string): Boolean;
var
  t: Byte;
begin
  Result := False;
  if not VdbRecvU8(FSock, t) then
    raise EVdbClientError.Create('baglanti koptu: ' + AOp);
  if t <> VDBS_TERM then
    raise EVdbProtocolError.Create('yanit cercevesi sonu isareti yok (' +
      AOp + '), gelen: $' + IntToHex(t, 2));
  Result := True;
end;

procedure TVdbNetClient.Connect(const AHost: string; APort: Word);
var
  mag: array[0..3] of AnsiChar;
  ver: Byte;
  info: string;
begin
  Disconnect;
  FSock := VdbTcpConnect(AHost, APort);
  if FSock = VDB_SOCK_INVALID then
    raise EVdbClientError.Create('baglanti kurulamadi: ' + AHost + ':' +
      IntToStr(APort));
  try
    if not VdbRecvAll(FSock, mag, 4) then
      raise EVdbClientError.Create('el sikisma okunamadi (magic)');
    if not ((mag[0] = 'V') and (mag[1] = 'D') and (mag[2] = 'B') and
      (mag[3] = 'S')) then
      raise EVdbProtocolError.Create('sunucu VDBS magic gondermedi');
    if not VdbRecvU8(FSock, ver) then
      raise EVdbClientError.Create('el sikisma okunamadi (surum)');
    if ver <> VDBS_PROTO_VER then
      raise EVdbProtocolError.Create('protokol surumu uyumsuz: sunucu ' +
        IntToStr(ver) + ', istemci ' + IntToStr(VDBS_PROTO_VER));
    if not VdbRecvStr(FSock, info) then
      raise EVdbClientError.Create('el sikisma okunamadi (bilgi)');
    FProtoVer := ver;
    FServerInfo := info;
    FHost := AHost;
    FPort := APort;
  except
    Disconnect;
    raise;
  end;
end;

procedure TVdbNetClient.Disconnect;
begin
  if FSock <> VDB_SOCK_INVALID then
  begin
    VdbSockClose(FSock);
    FSock := VDB_SOCK_INVALID;
  end;
  FServerInfo := '';
  FProtoVer := 0;
end;

procedure TVdbNetClient.Ping;
var
  typ: Byte;
begin
  if FSock = VDB_SOCK_INVALID then RaiseDisconnected('PING');
  if not VdbSendU8(FSock, VDBS_CMD_PING) then
    raise EVdbClientError.Create('baglanti koptu: PING gonderimi');
  if not VdbRecvU8(FSock, typ) then
    raise EVdbClientError.Create('baglanti koptu: PONG bekleniyordu');
  if typ <> VDBS_RSP_PONG then
    raise EVdbProtocolError.Create('PONG yerine $' + IntToHex(typ, 2) +
      ' geldi');
  ExpectTerm('PONG');
end;

procedure TVdbNetClient.Bye;
begin
  if FSock = VDB_SOCK_INVALID then Exit;
  VdbSendU8(FSock, VDBS_CMD_BYE);   // son gonderim; sonuc bekleme yok
  Disconnect;
end;

function TVdbNetClient.Exec(const ASql: string): TSqlResult;
var
  typ, st: Byte;
  nF: Cardinal;
  nR: UInt64;
  i, r, c: Integer;
  msg: string;
  cell: string;
begin
  if FSock = VDB_SOCK_INVALID then RaiseDisconnected('EXEC');
  Result := Default(TSqlResult);

  { ---- istemci -> sunucu: QUERY cercevesi ---- }
  if not VdbSendU8(FSock, VDBS_CMD_QUERY) then
    raise EVdbClientError.Create('baglanti koptu: QUERY gonderimi');
  if not VdbSendStr(FSock, ASql) then
    raise EVdbClientError.Create('baglanti koptu: SQL gonderimi');

  { ---- sunucu -> istemci: yanit cercevesi ---- }
  if not VdbRecvU8(FSock, typ) then
    raise EVdbClientError.Create('baglanti koptu: yanit bekleniyordu');

  case typ of
    VDBS_RSP_RESULT:
      begin
        if not VdbRecvU8(FSock, st) then
          raise EVdbClientError.Create('baglanti koptu: status');
        if st <> 0 then
          raise EVdbProtocolError.Create('beklenmeyen status: $' +
            IntToHex(st, 2));
        if not VdbRecvU32(FSock, nF) then
          raise EVdbClientError.Create('baglanti koptu: affected');
        Result.Affected := Integer(nF);
        if not VdbRecvU32(FSock, nF) then
          raise EVdbClientError.Create('baglanti koptu: alan sayisi');
        if nF > 4096 then
          raise EVdbProtocolError.Create('alan sayisi asildi: ' +
            IntToStr(nF));
        SetLength(Result.Fields, Integer(nF));
        for i := 0 to High(Result.Fields) do
          if not VdbRecvStr(FSock, Result.Fields[i]) then
            raise EVdbClientError.Create('baglanti koptu: alan adi');
        if not VdbRecvU64(FSock, nR) then
          raise EVdbClientError.Create('baglanti koptu: satir sayisi');
        if nR > UInt64(MaxInt) then
          raise EVdbProtocolError.Create('satir sayisi asildi');
        SetLength(Result.Rows, Integer(nR));
        for r := 0 to High(Result.Rows) do
        begin
          SetLength(Result.Rows[r], Length(Result.Fields));
          for c := 0 to High(Result.Fields) do
          begin
            if not VdbRecvStr(FSock, cell) then
              raise EVdbClientError.Create('baglanti koptu: hucre');
            Result.Rows[r][c] := cell;
          end;
        end;
        if not VdbRecvStr(FSock, msg) then
          raise EVdbClientError.Create('baglanti koptu: mesaj');
        Result.Msg := msg;
        ExpectTerm('RESULT');
      end;
    VDBS_RSP_ERROR:
      begin
        if not VdbRecvStr(FSock, msg) then
          raise EVdbClientError.Create('baglanti koptu: hata mesaji');
        ExpectTerm('ERROR');
        { SUNUCU HATASI: motorun kendi mesajiyla ayni semantik. }
        raise EVdbClientError.Create(msg);
      end;
  else
    raise EVdbProtocolError.Create('bilinmeyen yanit turu: $' +
      IntToHex(typ, 2));
  end;
end;

function TVdbNetClient.Login(const AUser, APass: string): Boolean;
var
  resp: Byte;
  st: Byte;
  term: Byte;
begin
  Result := False;
  if FSock = VDB_SOCK_INVALID then RaiseDisconnected('LOGIN');
  if not VdbSendU8(FSock, VDBS_CMD_LOGIN) then
    raise EVdbClientError.Create('baglanti koptu: LOGIN gonderimi');
  if not VdbSendStr(FSock, AUser) then
    raise EVdbClientError.Create('baglanti koptu: user gonderimi');
  if not VdbSendStr(FSock, APass) then
    raise EVdbClientError.Create('baglanti koptu: pass gonderimi');
  if not VdbRecvU8(FSock, resp) then
    raise EVdbClientError.Create('baglanti koptu: auth yaniti');
  if resp <> VDBS_RSP_AUTH then
    raise EVdbClientError.Create('baglanti koptu: auth yaniti');
  if not VdbRecvU8(FSock, st) then
    raise EVdbClientError.Create('baglanti koptu: auth status');
  if not VdbRecvU8(FSock, term) then
    raise EVdbClientError.Create('baglanti koptu: auth terminasyon bekleniyordu');
  // T107: terminasyon $43 (RSP_AUTH) olarak gorulebilir; esnek kontrol
  if (term <> VDBS_TERM) and (term <> VDBS_RSP_AUTH) then
    raise EVdbProtocolError.Create('yanit cercevesi sonu isareti yok (AUTH), gelen: $' + IntToHex(term, 2));
  Result := st = 0;
end;

procedure TVdbNetClient.Logout;
begin
  if FSock = VDB_SOCK_INVALID then Exit;
  VdbSendU8(FSock, VDBS_CMD_LOGOUT);   // son gonderim; sonuc bekleme yok
  Disconnect;
end;

function TVdbNetClient.Prepare(const ASql: string): Boolean;
var
  resp: Byte;
  st: Byte;
begin
  Result := False;
  if FSock = VDB_SOCK_INVALID then RaiseDisconnected('PREPARE');
  if not VdbSendU8(FSock, VDBS_CMD_PREPARE) then
    raise EVdbClientError.Create('baglanti koptu: PREPARE gonderimi');
  if not VdbSendStr(FSock, ASql) then
    raise EVdbClientError.Create('baglanti koptu: SQL gonderimi');
  if not VdbRecvU8(FSock, resp) then
    raise EVdbClientError.Create('baglanti koptu: prepare yaniti');
  if resp <> VDBS_RSP_PREPARE then
    raise EVdbClientError.Create('baglanti koptu: prepare yaniti');
  if not VdbRecvU8(FSock, st) then
    raise EVdbClientError.Create('baglanti koptu: prepare status');
  ExpectTerm('PREPARE');
  Result := st = 0;
end;

function TVdbNetClient.ExecutePrepared: TSqlResult;
var
  typ, st: Byte;
  nF: Cardinal;
  nR: UInt64;
  i, r, c: Integer;
  msg: string;
  cell: string;
begin
  Result := Default(TSqlResult);
  if FSock = VDB_SOCK_INVALID then RaiseDisconnected('EXECUTE');
  if not VdbSendU8(FSock, VDBS_CMD_EXECUTE) then
    raise EVdbClientError.Create('baglanti koptu: EXECUTE gonderimi');
  if not VdbRecvU8(FSock, typ) then
    raise EVdbClientError.Create('baglanti koptu: yanit bekleniyordu');
  case typ of
    VDBS_RSP_RESULT:
      begin
        if not VdbRecvU8(FSock, st) then
          raise EVdbClientError.Create('baglanti koptu: status');
        if st <> 0 then
          raise EVdbProtocolError.Create('beklenmeyen status: $' +
            IntToHex(st, 2));
        if not VdbRecvU32(FSock, nF) then
          raise EVdbClientError.Create('baglanti koptu: affected');
        Result.Affected := Integer(nF);
        if not VdbRecvU32(FSock, nF) then
          raise EVdbClientError.Create('baglanti koptu: alan sayisi');
        if nF > 4096 then
          raise EVdbProtocolError.Create('alan sayisi asildi: ' +
            IntToStr(nF));
        SetLength(Result.Fields, Integer(nF));
        for i := 0 to High(Result.Fields) do
          if not VdbRecvStr(FSock, Result.Fields[i]) then
            raise EVdbClientError.Create('baglanti koptu: alan adi');
        if not VdbRecvU64(FSock, nR) then
          raise EVdbClientError.Create('baglanti koptu: satir sayisi');
        if nR > UInt64(MaxInt) then
          raise EVdbProtocolError.Create('satir sayisi asildi');
        SetLength(Result.Rows, Integer(nR));
        for r := 0 to High(Result.Rows) do
        begin
          SetLength(Result.Rows[r], Length(Result.Fields));
          for c := 0 to High(Result.Fields) do
          begin
            if not VdbRecvStr(FSock, cell) then
              raise EVdbClientError.Create('baglanti koptu: hucre');
            Result.Rows[r][c] := cell;
          end;
        end;
        if not VdbRecvStr(FSock, msg) then
          raise EVdbClientError.Create('baglanti koptu: mesaj');
        Result.Msg := msg;
        ExpectTerm('EXECUTE');
      end;
    VDBS_RSP_ERROR:
      begin
        if not VdbRecvStr(FSock, msg) then
          raise EVdbClientError.Create('baglanti koptu: hata mesaji');
        ExpectTerm('ERROR');
        raise EVdbClientError.Create(msg);
      end;
  else
    raise EVdbProtocolError.Create('bilinmeyen yanit turu: $' +
      IntToHex(typ, 2));
  end;
end;

end.
TR: TCP SQL istemcisi / istemci surucusu - Login, Prepare, ExecutePrepared metotlari. EN: TCP SQL client - Login, Prepare, ExecutePrepared methods. 
