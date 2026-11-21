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
{$IFDEF MSWINDOWS}
  { v3.69 / SKILL6 05: Windows'ta Sockets birimi select/FDSet'i YENIDEN
    YAYINLAMAZ; bunlar winsock2'de tanimlidir. BILEREK once gelir: ortak
    adlar (psockaddr vb.) Sockets'ten cozulmeye devam eder. }
  WinSock2,
{$ENDIF}
  SysUtils, Classes, Sockets
{$IFDEF UNIX}
  , BaseUnix
{$ENDIF}
  ;

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

  { v3.39 / SKILL3 §12.1 (bozuk ag girdisi): gelen tek bir metin
    cercevesi icin ust sinir. Onceden 1 GB'lik bir uzunluk oneki
    kabul ediliyordu; kimligi dogrulanmamis bir istemci tek bir
    cerceveyle sunucuda 1 GB ayirmaya zorlayabiliyordu. 64 MiB,
    mesru her SQL cumlesi ve parametre kumesi icin fazlasiyla
    yeterlidir (VDbPgWire'daki on-kapa ile ayni deger). Asimda
    baglanti kontrollu sekilde duser; sunucu ve dosya etkilenmez. }
  VDBS_MAX_RECV_STR = 64 * 1024 * 1024;

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

{ SKILL10: engellemeyen accept. AListen once VdbSockSetNonBlocking ile
  non-blocking yapilmalidir. Bekleyen baglanti yoksa VDB_SOCK_INVALID
  doner ve AWouldBlock=True olur (hata DEGIL); gercek hata ile ayrimi
  icin tek yol budur. Boylece kabul dongusu Stop bayragini 200 ms
  icinde gorebilir; bloklu accept'i baska bir is parcacigindan
  kapatmaya (Windows'ta guvenilmez) GEREK KALMAZ. }
function VdbTcpAcceptNb(AListen: TVdbSocket;
  out AWouldBlock: Boolean): TVdbSocket;

{ SKILL10: soketi bloklamayan (non-blocking) kipe alir/geri alir.
  Windows: ioctlsocket(FIONBIO); Unix: fcntl(O_NONBLOCK). }
function VdbSockSetNonBlocking(ASock: TVdbSocket; AOn: Boolean): Boolean;

{ AHost:APort'a baglanir (ENGELLEME). Hata: VDB_SOCK_INVALID. }
function VdbTcpConnect(const AHost: string; APort: Word): TVdbSocket;

{ ALen baytin TAMAMINI gonderir. Karsi taraf kapatirsa/hata olursa False. }
function VdbSendAll(ASock: TVdbSocket; const ABuf; ALen: Integer): Boolean;

{ v3.56 / Sprint E: baglanti basina okuma/yazma zaman asimi. 0 = devre
  disi (eski davranis, sinirsiz bloklama). Windows SO_RCVTIMEO/
  SO_SNDTIMEO icin DWORD milisaniye bekler; Unix timeval (saniye,
  mikrosaniye) bekler — fark burada gizlenir. Donus: en az bir secenek
  kurulabildiyse True.

  Neden gerekli: engellenen bir recv, istemci tek bayt gonderip
  beklediginde is parcacigini ve baglanti slotunu SONSUZA KADAR tutuyordu
  (MaxConns kadar bos soket sunucuyu kalici olarak kapatabiliyordu). }
function VdbSockSetTimeouts(ASock: TVdbSocket; ARecvMs, ASendMs: Integer): Boolean;

{ ALen baytin TAMAMINI okur. Karsi taraf erken kapatirsa False. }
function VdbRecvAll(ASock: TVdbSocket; var ABuf; ALen: Integer): Boolean;

{ v3.69 / SKILL6 05: MUTLAK (toplam) zaman asimi. ASonTick = 0 ise
  davranis eskisi gibi kalir (yalniz SO_RCVTIMEO/SO_SNDTIMEO, yani HER
  okuma cagrisi icin ayri sure). Aksi halde islem select() ile beklenir ve
  ASonTick (monotonik ms, GetTickCount64) gecildiginde False doner.

  Neden gerekli: SO_RCVTIMEO tek bir recv cagrisina uygulanir. Istemci her
  zaman asimindan ONCE kucuk bir parca gonderirse toplam mesaj suresi
  sinirsiz uzuyordu (ornegin her 29 saniyede bir bayt). Bu fonksiyonlar
  ayni son tarihi tum parcalara uygular. }
function VdbRecvAllDl(ASock: TVdbSocket; var ABuf; ALen: Integer;
  ASonTick: QWord; AStopFlag: PInteger = nil): Boolean;
function VdbSendAllDl(ASock: TVdbSocket; const ABuf; ALen: Integer;
  ASonTick: QWord; AStopFlag: PInteger = nil): Boolean;

{ SKILL10: SELECT ile "hazir mi" beklemesi (en fazla 1000 ms'lik dilim).
  Kabul dongusu bunu kullanir; boylece bloklayan accept olmadan Stop
  bayragi en gec ~200 ms icinde gorulur. }
function VdbWaitSock(ASock: TVdbSocket; AYaz: Boolean; AMs: Integer): Boolean;

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

{$IFDEF UNIX}
const
  { SKILL10: FPC BaseUnix bu sabitleri O_NONBLOCK adiyla vermez;
    degerler Linux ve BSD/Darwin icin ayri ayri dogrulanmistir. }
  VDB_F_GETFL = 3;      // Linux ve BSD: F_GETFL
  VDB_F_SETFL = 4;      // Linux ve BSD: F_SETFL
  {$IFDEF DARWIN}
  VDB_O_NONBLOCK = $0004;
  {$ELSE}
  VDB_O_NONBLOCK = $0800;
  {$ENDIF}
{$ENDIF}

function VdbSockSetNonBlocking(ASock: TVdbSocket; AOn: Boolean): Boolean;
{$IFDEF MSWINDOWS}
var
  arg: u_long;
{$ELSE}
var
  flags: cint;
{$ENDIF}
begin
  Result := False;
  if ASock = VDB_SOCK_INVALID then Exit;
{$IFDEF MSWINDOWS}
  if AOn then arg := 1 else arg := 0;
  Result := ioctlsocket(ASock, FIONBIO, arg) = 0;
{$ELSE}
  flags := FpFcntl(ASock, VDB_F_GETFL, 0);
  if flags < 0 then Exit;
  if AOn then
    flags := flags or VDB_O_NONBLOCK
  else
    flags := flags and (not VDB_O_NONBLOCK);
  Result := FpFcntl(ASock, VDB_F_SETFL, flags) = 0;
{$ENDIF}
end;

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

function VdbTcpAcceptNb(AListen: TVdbSocket;
  out AWouldBlock: Boolean): TVdbSocket;
var
  dummy: TInetSockAddr;
  dl: tsocklen;
  e: Integer;
begin
  AWouldBlock := False;
  dl := SizeOf(dummy);
  Result := fpAccept(AListen, psockaddr(@dummy), @dl);
  if Result = VDB_SOCK_INVALID then
  begin
    { SKILL10: non-blocking accept'te "bekleyen baglanti yok" bir HATA
      degildir; ayirt edilmezse kabul dongusu sunucuyu durdururdu. }
    {$IFDEF MSWINDOWS}
    e := WSAGetLastError;
    AWouldBlock := (e = WSAEWOULDBLOCK) or (e = WSAEINTR);
    {$ELSE}
    e := fpgeterrno;
    AWouldBlock := (e = ESysEAGAIN) or (e = ESysEINTR);
    {$ENDIF}
    Exit;
  end;
  {$IFDEF DARWIN}
  VdbNoSigPipe(Result);
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

{ v3.69 / SKILL6 05: SELECT ile "hazir mi" beklemesi. AMs en fazla
  1000 ms'lik dilimlere bolunur; boylece uzun bir son tarih tek bir
  bloklamaya donusmez ve soket kapanisi (Stop/Wake -> shutdown) en gec
  bir saniye icinde gorulur. }
function VdbWaitSock(ASock: TVdbSocket; AYaz: Boolean; AMs: Integer): Boolean;
var
  fds: TFDSet;
  tv: TTimeVal;
begin
  Result := False;
  if (ASock = VDB_SOCK_INVALID) or (AMs <= 0) then Exit;
  if AMs > 1000 then AMs := 1000;
{$IFDEF MSWINDOWS}
  FD_ZERO(fds);
  FD_SET(ASock, fds);
  tv.tv_sec := AMs div 1000;
  tv.tv_usec := (AMs mod 1000) * 1000;
  if AYaz then
    Result := select(0, nil, @fds, nil, @tv) > 0
  else
    Result := select(0, @fds, nil, nil, @tv) > 0;
{$ELSE}
  fpFD_ZERO(fds);
  fpFD_SET(ASock, fds);
  tv.tv_sec := AMs div 1000;
  tv.tv_usec := (AMs mod 1000) * 1000;
  if AYaz then
    Result := fpSelect(ASock + 1, nil, @fds, nil, @tv) > 0
  else
    Result := fpSelect(ASock + 1, @fds, nil, nil, @tv) > 0;
{$ENDIF}
end;

function VdbRecvAllDl(ASock: TVdbSocket; var ABuf; ALen: Integer;
  ASonTick: QWord; AStopFlag: PInteger): Boolean;
var
  got, n: Integer;
  p: PByte;
  kalan: Int64;
  dilim: Integer;
begin
  if (ASonTick = 0) and (AStopFlag = nil) then
    Exit(VdbRecvAll(ASock, ABuf, ALen));
  Result := False;
  if (ASock = VDB_SOCK_INVALID) or (ALen < 0) then Exit;
  if ALen = 0 then Exit(True);
  got := 0;
  p := @ABuf;
  while got < ALen do
  begin
    { SKILL10: iptal bayragi her dilimde denetlenir. Windows'ta
      shutdown() bloklu select()'i uyandirmaz (olculdu); bu yuzden
      Stop yalnizca bayrakla zamaninda donebilir. }
    if (AStopFlag <> nil) and (AStopFlag^ <> 0) then Exit;
    if ASonTick <> 0 then
    begin
      kalan := Int64(ASonTick) - Int64(GetTickCount64);
      if kalan <= 0 then Exit;        // MUTLAK son tarih gecti
      if kalan > 200 then dilim := 200 else dilim := Integer(kalan);
    end
    else
      dilim := 200;                   // bayrak var, son tarih yok
    if not VdbWaitSock(ASock, False, dilim) then
      Continue;                       // dilim doldu; son tarih yeniden denetlenir
    n := fpRecv(ASock, p + got, ALen - got, 0);
    if n <= 0 then Exit;              // 0 = karsi taraf kapatti
    Inc(got, n);
  end;
  Result := True;
end;

function VdbSendAllDl(ASock: TVdbSocket; const ABuf; ALen: Integer;
  ASonTick: QWord; AStopFlag: PInteger): Boolean;
var
  sent, n: Integer;
  p: PByte;
  kalan: Int64;
  dilim: Integer;
begin
  if (ASonTick = 0) and (AStopFlag = nil) then
    Exit(VdbSendAll(ASock, ABuf, ALen));
  Result := False;
  if (ASock = VDB_SOCK_INVALID) or (ALen < 0) then Exit;
  if ALen = 0 then Exit(True);
  sent := 0;
  p := @ABuf;
  while sent < ALen do
  begin
    if (AStopFlag <> nil) and (AStopFlag^ <> 0) then Exit;
    if ASonTick <> 0 then
    begin
      kalan := Int64(ASonTick) - Int64(GetTickCount64);
      if kalan <= 0 then Exit;
      if kalan > 200 then dilim := 200 else dilim := Integer(kalan);
    end
    else
      dilim := 200;
    if not VdbWaitSock(ASock, True, dilim) then
      Continue;
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

{$IFNDEF MSWINDOWS}
function VdbMsToTimeval(AMs: Integer): TTimeVal;
begin
  if AMs < 0 then AMs := 0;
  Result.tv_sec := AMs div 1000;
  Result.tv_usec := (AMs mod 1000) * 1000;
end;
{$ENDIF}

function VdbSockSetTimeouts(ASock: TVdbSocket; ARecvMs, ASendMs: Integer): Boolean;
{ Bkz. arayuz. Windows'ta deger DWORD milisaniye; Unix'te timeval
  (tv_sec, tv_usec) ve 'long' makine kelimesi buyuklugundedir. }
{$IFDEF MSWINDOWS}
var
  rv, sv: DWORD;
{$ELSE}
var
  rv, sv: TTimeVal;
{$ENDIF}
  okR, okS: Boolean;
begin
  Result := False;
  if ASock = VDB_SOCK_INVALID then Exit;
  if (ARecvMs <= 0) and (ASendMs <= 0) then Exit(True);  // devre disi
  okR := ARecvMs <= 0;
  okS := ASendMs <= 0;
  {$IFDEF MSWINDOWS}
  if ARecvMs > 0 then
  begin
    rv := DWORD(ARecvMs);
    okR := fpSetSockOpt(ASock, SOL_SOCKET, SO_RCVTIMEO, @rv, SizeOf(rv)) = 0;
  end;
  if ASendMs > 0 then
  begin
    sv := DWORD(ASendMs);
    okS := fpSetSockOpt(ASock, SOL_SOCKET, SO_SNDTIMEO, @sv, SizeOf(sv)) = 0;
  end;
  {$ELSE}
  if ARecvMs > 0 then
  begin
    rv := VdbMsToTimeval(ARecvMs);
    okR := fpSetSockOpt(ASock, SOL_SOCKET, SO_RCVTIMEO, @rv, SizeOf(rv)) = 0;
  end;
  if ASendMs > 0 then
  begin
    sv := VdbMsToTimeval(ASendMs);
    okS := fpSetSockOpt(ASock, SOL_SOCKET, SO_SNDTIMEO, @sv, SizeOf(sv)) = 0;
  end;
  {$ENDIF}
  Result := okR and okS;
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
  if n > VDBS_MAX_RECV_STR then Exit(False);  // v3.39: bozuk uzunluk korumasi
  if n = 0 then Exit(True);
  SetLength(S, Integer(n));
  Result := VdbRecvAll(ASock, Pointer(S)^, Integer(n));
  if not Result then S := '';
end;

end.
