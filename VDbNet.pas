unit VDbNet;

{ R-17 Full (2026-10-13): GERCEK AG KATMANI — platform-notr TCP yardimcilari.

  Proje kurali "harici DLL yok, saf FPC" suruyor: WinSock2 (Windows) ve
  BSD sockets (Unix) FPC RTL `Sockets` birimi uzerinden kullanilir.
  Windows'ta birimin initialization blogu WSAStartup'i kendi yapar; bu
  yuzden burada acik bir baslatma yoktur.

  Katman YALNIZCA tasimadir; protokol bilgisi (magic, mesaj turleri,
  el sikisma) VDbReplication birimindedir. Burada sunlar saglanir:

    - VdbTcpListen / VdbTcpAccept / VdbTcpConnect
    - VdbSendAll / VdbRecvAll ("hepsi ya hic": kismi okuma/yazma yok)
    - kucuk-endian u8/u32/u64 ve uzunluk-ekli dizgi ilkelleri
    - VdbSockShutdown: engellenmis recv/accept cagrisini baska
      is parcacigindan GUVENLE uyandirmak icin (soketi KAPATMAZ).

  Engellenmis accept'i Windows'ta uyandirmanin guvenli yolu dinleme
  soketini KAPATMAKTIR (shutdown dinleme soketinde tanimli degildir);
  bu VdbReplication'daki Stop yordamlarinin sorumlulugudur. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Sockets;

const
  { TSocket (cint) uzayinda gecersiz soket gosterimi. }
  VDB_SOCK_INVALID = -1;

  { fpShutdown "how" degeri: 2 = both (alindi/gonderildi kapat). }
  VDB_SHUT_RDWR = 2;

  { ---- VDBS: TCP SQL sunucu/istemci protokolu (R-12 Full) ----
    Tasima katmani paylasildigi icin protokol sabitleri de burada:
    hem VDbSqlServer hem VDbClientNet bunlari gorur. (VDBR replikasyon
    protokolu oldugu gibi VDbReplication'dadir.) }
  VDBS_MAGIC = 'VDBS';
  VDBS_PROTO_VER = 1;
  VDBS_TERM = $00;          // her yanit cercevesinin son isareti

  VDBS_CMD_QUERY = $10;
  VDBS_CMD_PING = $11;
  VDBS_CMD_BYE = $1F;
  VDBS_CMD_LOGIN = $20;   // R-12 devam: oturum ac (str user, str pass)
  VDBS_CMD_LOGOUT = $21;  // R-12 devam: oturum kapat
  VDBS_CMD_PREPARE = $22; // R-12 devam: hazirla (str sql) -> VDBS_RSP_PREPARE
  VDBS_CMD_EXECUTE = $23; // R-12 devam: calistir (str params -> VDBS_RSP_RESULT)

  VDBS_RSP_RESULT = $40;  // u8 status(0) + u32 affected + alanlar + satirlar + str msg
  VDBS_RSP_ERROR = $41;   // str msg
  VDBS_RSP_PONG = $42;
  VDBS_RSP_AUTH = $43;    // oturum: u8 status(0/1) + u8 $00
  VDBS_RSP_PREPARE = $44; // hazirlik: u8 status(0/1) + u8 $00

type
  TVdbSocket = TSocket;

{ Dinleme soketi kurar (tum arayuzler = 0.0.0.0, SO_REUSEADDR acik —
  testler ardisik ayni portla yeniden baslayabilsin diye).
  Hata: VDB_SOCK_INVALID. }
function VdbTcpListen(APort: Word; ABacklog: Integer = 16): TVdbSocket; overload;

{ R-4: yalniz AHost arayuzune baglanan dinleme soketi. AHost noktali
  IPv4 gosterimidir ('127.0.0.1', '0.0.0.0', LAN adresi); bos = 0.0.0.0.
  Ad cozumlemesi YAPILMAZ — adlari VdbResolveListenHost cevirir.
  Cozulemeyen adres sessizce 0.0.0.0'a dusmez. Hata: VDB_SOCK_INVALID. }
function VdbTcpListen(const AHost: string; APort: Word;
  ABacklog: Integer = 16): TVdbSocket; overload;

{ R-4: AHost yalniz loopback mi? 'localhost', '::1' ve 127.0.0.0/8
  evet; '0.0.0.0', bos dizgi, LAN/WAN adresleri hayir. Karar VERIR,
  DNS sorgulamaz — boylece hosts dosyasi olmayan makinede de ayni
  sonucu verir. }
function VdbHostIsLoopback(const AHost: string): Boolean;

{ R-4: dinleme adresini cozer. ATrustOnlyLoopback=True (kimlik dogrulama
  kapali acik mod) iken istenen adres loopback degilse AErr dolar ve
  sonuc bos olur — cagiran baslatmayi REDDEDER. Istek bos ise trust
  modunda '127.0.0.1', aksi halde '0.0.0.0'. }
function VdbResolveListenHost(const ARequested: string;
  ATrustOnlyLoopback: Boolean; out AErr: string): string;

{ Baglantiyi kabul eder (ENGELLEME). Istemgi kapattiginda/hatada
  VDB_SOCK_INVALID doner. }
function VdbTcpAccept(AListen: TVdbSocket): TVdbSocket;

{ AHost:APort'a baglanir (ENGELLEME). Hata: VDB_SOCK_INVALID. }
function VdbTcpConnect(const AHost: string; APort: Word): TVdbSocket;

{ ALen baytin TAMAMINI gonderir. Karsi taraf kapatirsa/hata olursa False. }
function VdbSendAll(ASock: TVdbSocket; const ABuf; ALen: Integer): Boolean;

{ ALen baytin TAMAMINI okur. Karsi taraf erken kapatirsa False. }
function VdbRecvAll(ASock: TVdbSocket; var ABuf; ALen: Integer): Boolean;

{ En fazla ALen bayt okur (kismi okuma normaldir).
  0 = karsi taraf kapatti, <0 = hata. HTTP basligi gibi "bitis
  isaretine kadar oku" kullanimlari icin. }
function VdbRecvSome(ASock: TVdbSocket; var ABuf; ALen: Integer): Integer;

{ ---- Protokol ilkelleri (hepsi KUCUK ENDIAN; platformdan bagimsiz) ---- }
function VdbSendU8(ASock: TVdbSocket; AV: Byte): Boolean;
function VdbRecvU8(ASock: TVdbSocket; out AV: Byte): Boolean;
function VdbSendU32(ASock: TVdbSocket; AV: Cardinal): Boolean;
function VdbRecvU32(ASock: TVdbSocket; out AV: Cardinal): Boolean;
function VdbSendU64(ASock: TVdbSocket; AV: UInt64): Boolean;
function VdbRecvU64(ASock: TVdbSocket; out AV: UInt64): Boolean;
{ u32 uzunluk + ham baytlar. }
function VdbSendStr(ASock: TVdbSocket; const S: string): Boolean;
function VdbRecvStr(ASock: TVdbSocket; out S: string): Boolean;

{ Soketi kapatir. Gecersiz gosterime dokunmaz. }
procedure VdbSockClose(ASock: TVdbSocket);

{ Yalnizca shutdown: engellenmis bir recv/send cagrisinin donmesi icin.
  Soket hala aciktir; kapanisini sahibi is parcacigi yapar. }
procedure VdbSockShutdown(ASock: TVdbSocket);

implementation

procedure VdbSockClose(ASock: TVdbSocket);
begin
  if ASock <> VDB_SOCK_INVALID then
    CloseSocket(ASock);
end;

procedure VdbSockShutdown(ASock: TVdbSocket);
begin
  if ASock <> VDB_SOCK_INVALID then
    fpShutdown(ASock, VDB_SHUT_RDWR);
end;

{$IFDEF DARWIN}
procedure VdbNoSigPipe(s: TVdbSocket);
{ P-77: macOS'ta MSG_NOSIGNAL yoktur; SIGPIPE soket duzeyinde
  SO_NOSIGPIPE ile kesilir (Linux'te fpSend'e MSG_NOSIGNAL verilir,
  Windows'ta SIGPIPE kavrami yoktur). Kabul edilen soketler bunu
  KALITAMAZ — her yeni sokette bir kez kurulur. }
var
  one: Integer;
begin
  one := 1;
  fpSetSockOpt(s, SOL_SOCKET, SO_NOSIGPIPE, @one, SizeOf(one));
end;
{$ENDIF}

function VdbTcpListen(APort: Word; ABacklog: Integer): TVdbSocket;
begin
  Result := VdbTcpListen('0.0.0.0', APort, ABacklog);
end;

function VdbTcpListen(const AHost: string; APort: Word;
  ABacklog: Integer): TVdbSocket;
var
  s: TVdbSocket;
  addr: TInetSockAddr;
  one: Integer;
  h: string;
begin
  Result := VDB_SOCK_INVALID;
  s := fpSocket(AF_INET, SOCK_STREAM, 0);
  if s = VDB_SOCK_INVALID then Exit;
  {$IFDEF DARWIN}VdbNoSigPipe(s);{$ENDIF}
  one := 1;
  { Testler ayni portta ardişikan yeniden baslayabilsin diye. }
  fpSetSockOpt(s, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(APort);
  { StrToHostAddr DEGIL: o HOST bayt duzeni dondurur. sockaddr isteyen
    ag cagrilarinda ag (network) duzeni gereklidir -> StrToNetAddr. }
  h := Trim(AHost);
  if h = '' then h := '0.0.0.0';
  addr.sin_addr := StrToNetAddr(h);
  if addr.sin_addr.s_addr = 0 then
  begin
    { '0.0.0.0' ile cozulemeyen ad ayni degeri verir; ikincisini
      'her arayuz' diye sessizce kabul etmek R-4'u delerdi. }
    if (h <> '0.0.0.0') and (h <> '0') then
    begin
      CloseSocket(s);
      Exit;
    end;
  end;
  if fpBind(s, psockaddr(@addr), tsocklen(SizeOf(addr))) <> 0 then
  begin
    CloseSocket(s);
    Exit;
  end;
  if fpListen(s, ABacklog) <> 0 then
  begin
    CloseSocket(s);
    Exit;
  end;
  Result := s;
end;

function VdbHostIsNumericV4(const AHost: string): Boolean;
var
  i, dots: Integer;
begin
  Result := False;
  if (AHost = '') or (Length(AHost) > 15) then Exit;
  dots := 0;
  for i := 1 to Length(AHost) do
    if AHost[i] = '.' then Inc(dots)
    else if not (AHost[i] in ['0'..'9']) then Exit;
  Result := dots = 3;
end;

function VdbHostIsLoopback(const AHost: string): Boolean;
var
  h: string;
begin
  h := LowerCase(Trim(AHost));
  if (h = 'localhost') or (h = '::1') or (h = '[::1]') then Exit(True);
  Result := VdbHostIsNumericV4(h) and (Copy(h, 1, 4) = '127.');
end;

function VdbResolveListenHost(const ARequested: string;
  ATrustOnlyLoopback: Boolean; out AErr: string): string;
var
  h: string;
begin
  AErr := '';
  h := LowerCase(Trim(ARequested));
  if h = '' then
  begin
    if ATrustOnlyLoopback then Result := '127.0.0.1' else Result := '0.0.0.0';
    Exit;
  end;
  { Tasima katmani IPv4'tur (AF_INET). Ad cozumlemesi burada YAPILMAZ:
    tek destekli ad 'localhost'tur ve acikca IPv4 loopback'e eslenir.
    Boylece DNS/hosts dosyasina bagli, makineden makineye degisen bir
    guvenlik karari olusmaz. }
  if (h = 'localhost') or (h = '::1') or (h = '[::1]') then
  begin
    Result := '127.0.0.1';
    Exit;
  end;
  if (Pos(':', h) > 0) or ((h <> '0.0.0.0') and (not VdbHostIsNumericV4(h))) then
  begin
    AErr := 'gecersiz dinleme adresi (IPv4 noktali gosterim bekleniyor): ' + h;
    Result := '';
    Exit;
  end;
  if ATrustOnlyLoopback and (not VdbHostIsLoopback(h)) then
  begin
    AErr := 'acik (trust) mod yalniz loopback adresine baglanabilir; ' +
      'istenen adres: ' + h;
    Result := '';
    Exit;
  end;
  Result := h;
end;

function VdbTcpAccept(AListen: TVdbSocket): TVdbSocket;
var
  dummy: TInetSockAddr;
  dl: tsocklen;
begin
  dl := SizeOf(dummy);
  Result := fpAccept(AListen, psockaddr(@dummy), @dl);
  {$IFDEF DARWIN}
  if Result <> VDB_SOCK_INVALID then
    VdbNoSigPipe(Result);   { kabul edilen soket SO_NOSIGPIPE'i kalitamaz }
  {$ENDIF}
end;

function VdbTcpConnect(const AHost: string; APort: Word): TVdbSocket;
var
  s: TVdbSocket;
  addr: TInetSockAddr;
begin
  Result := VDB_SOCK_INVALID;
  s := fpSocket(AF_INET, SOCK_STREAM, 0);
  if s = VDB_SOCK_INVALID then Exit;
  {$IFDEF DARWIN}VdbNoSigPipe(s);{$ENDIF}
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(APort);
  { Bkz. VdbTcpListen: ag bayt duzeni icin StrToNetAddr. }
  addr.sin_addr := StrToNetAddr(AHost);
  if fpConnect(s, psockaddr(@addr), tsocklen(SizeOf(addr))) <> 0 then
  begin
    CloseSocket(s);
    Exit;
  end;
  Result := s;
end;

function VdbSendAll(ASock: TVdbSocket; const ABuf; ALen: Integer): Boolean;
var
  sent, n: Integer;
  p: PByte;
begin
  Result := False;
  if (ASock = VDB_SOCK_INVALID) or (ALen < 0) then Exit;
  if ALen = 0 then Exit(True);
  sent := 0;
  p := @ABuf;
  while sent < ALen do
  begin
    { Unix: karsi taraf kapatmissa send() SIGPIPE uretir ve sureci
      sonlandirir (sqltest'te R-17 TCP testinde gorulen exit 141).
      MSG_NOSIGNAL ile EPIPE normal hata olarak doner; dongu False ile
      cikar. Windows'ta bayrak yoktur. macOS'ta MSG_NOSIGNAL YOKTUR
      (P-77: olculen 'Identifier not found'); SIGPIPE yerine soket
      duzeyinde SO_NOSIGPIPE kurulur (bkz. VdbTcpConnect/SocketPair
      cagrilari) ve bayrak 0 gecer. }
{$IFDEF LINUX}
    n := fpSend(ASock, p + sent, ALen - sent, MSG_NOSIGNAL);
{$ELSE}
    n := fpSend(ASock, p + sent, ALen - sent, 0);
{$ENDIF}
    if n <= 0 then Exit;
    Inc(sent, n);
  end;
  Result := True;
end;

function VdbRecvAll(ASock: TVdbSocket; var ABuf; ALen: Integer): Boolean;
var
  got, n: Integer;
  p: PByte;
begin
  Result := False;
  if (ASock = VDB_SOCK_INVALID) or (ALen < 0) then Exit;
  if ALen = 0 then Exit(True);
  got := 0;
  p := @ABuf;
  while got < ALen do
  begin
    n := fpRecv(ASock, p + got, ALen - got, 0);
    if n <= 0 then Exit;  // 0 = karsi taraf kapatii
    Inc(got, n);
  end;
  Result := True;
end;

function VdbRecvSome(ASock: TVdbSocket; var ABuf; ALen: Integer): Integer;
begin
  Result := -1;
  if (ASock = VDB_SOCK_INVALID) or (ALen <= 0) then Exit(0);
  Result := fpRecv(ASock, @ABuf, ALen, 0);
end;

function VdbSendU8(ASock: TVdbSocket; AV: Byte): Boolean;
begin
  Result := VdbSendAll(ASock, AV, 1);
end;

function VdbRecvU8(ASock: TVdbSocket; out AV: Byte): Boolean;
begin
  Result := VdbRecvAll(ASock, AV, 1);
end;

function VdbSendU32(ASock: TVdbSocket; AV: Cardinal): Boolean;
var
  b: array[0..3] of Byte;
begin
  b[0] := Byte(AV and $FF);
  b[1] := Byte((AV shr 8) and $FF);
  b[2] := Byte((AV shr 16) and $FF);
  b[3] := Byte((AV shr 24) and $FF);
  Result := VdbSendAll(ASock, b, 4);
end;

function VdbRecvU32(ASock: TVdbSocket; out AV: Cardinal): Boolean;
var
  b: array[0..3] of Byte;
begin
  AV := 0;
  if not VdbRecvAll(ASock, b, 4) then Exit(False);
  AV := Cardinal(b[0]) or (Cardinal(b[1]) shl 8) or
    (Cardinal(b[2]) shl 16) or (Cardinal(b[3]) shl 24);
  Result := True;
end;

function VdbSendU64(ASock: TVdbSocket; AV: UInt64): Boolean;
var
  b: array[0..7] of Byte;
  i: Integer;
begin
  for i := 0 to 7 do
    b[i] := Byte((AV shr (8 * i)) and $FF);
  Result := VdbSendAll(ASock, b, 8);
end;

function VdbRecvU64(ASock: TVdbSocket; out AV: UInt64): Boolean;
var
  b: array[0..7] of Byte;
  i: Integer;
begin
  AV := 0;
  if not VdbRecvAll(ASock, b, 8) then Exit(False);
  for i := 0 to 7 do
    AV := AV or (UInt64(b[i]) shl (8 * i));
  Result := True;
end;

function VdbSendStr(ASock: TVdbSocket; const S: string): Boolean;
var
  n: Cardinal;
begin
  n := Cardinal(Length(S));
  if not VdbSendU32(ASock, n) then Exit(False);
  if n = 0 then Exit(True);
  Result := VdbSendAll(ASock, Pointer(S)^, Integer(n));
end;

function VdbRecvStr(ASock: TVdbSocket; out S: string): Boolean;
var
  n: Cardinal;
begin
  S := '';
  if not VdbRecvU32(ASock, n) then Exit(False);
  if n > $40000000 then Exit(False);  // 1 GB sinir: bozuk uzunluk korumasi
  if n = 0 then Exit(True);
  SetLength(S, Integer(n));
  Result := VdbRecvAll(ASock, Pointer(S)^, Integer(n));
  if not Result then S := '';
end;

end.
