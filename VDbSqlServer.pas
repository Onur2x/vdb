unit VDbSqlServer;

{ R-12 Full (2026-10-13): TCP SQL SUNUCUSU — "VDBS" protokolu.

  VDbNet tasima katmani (R-17 Full) uzerine kurulur; protokol buradadir:

    Baglanti acilir ve SUNUCU ilk mesaji gonderir (el sikisma):
      4 bayt 'VDBS' + u8 protokol surumu + str sunucu bilgisi

    ISTEMCI -> SUNUCU (her cerceve: u8 tur + govde):
      $10 QUERY   str sql
      $11 PING    (govde yok)
      $1F BYE     (govde yok)

    SUNUCU -> ISTEMCI:
      $20 RESULT  u8 status(0) + u32 affected + u32 nFields + alan adlari
                  + u64 nRows + satirlar (hucre = str) + str msg
                  + u8 $00 SONU ISARETI
      $21 ERROR   str msg + u8 $00 SONU ISARETI
      $2F PONG    u8 $00 SONU ISARETI

  Motor erisimi TEK NOKTADAN: tek TVSql ornegi + TCriticalSection altinda
  SERI yurutum — R-12 1. asamanin (VDbPool) serilestirilmis modelinin aynen
  korunmasi; eszamanlilik/kapasite havuzun isidir, sunucu sadece dogru
  sira garantisini verir.

  Kapanis kurali (VDbNet notu): Windows'ta engellenmis accept'i
  uyandirmanin tek guvenli yolu DINLEME soketini KAPATMAKTIR; engellenmis
  recv'ler icin VdbSockShutdown kullanilir (soketin kapanisini baglanti
  thread'i kendisi yapar). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, VDbTypes, VDbCore, VDbTable, VDbSql, VDbAst,
  VDbNet;

{ Protokol sabitleri (VDBS_*) VDbNet birimindedir: tasima katmaniyla
  paylasildigi icin hem sunucu hem istemci oradan okur. }

type
  TVdbSqlServer = class;

  { Her istemci baglantisi icin bir thread.
    KR-7: Her baglanti kendi TVSql ornegiyle calisir (FSql); ayni Ftb
    paylasilir. Okuma sorgulari paralel, yazma serilestirme Ftb.Lock
    (TMultiReadExclusiveWriteSynchronizer) ile saglanir. }
  TVdbServerConn = class(TThread)
  private
    FServer: TVdbSqlServer;
    FSock: TVdbSocket;
    FSql: TVSql;    // KR-7: baglantiya ozel SQL motoru (ayni Ftb paylasilir)
    FSessionActive: Boolean; // KR-7: baglanti bazli oturum durumu
    FPreparedSql: string;   // KR-7: baglantiya ozel hazirlanmis SQL
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TVdbSqlServer; ASock: TVdbSocket);
    destructor Destroy; override;
    { Stop sirasinda engellenmis recv'yi uyandirir (kapanis Execute'ta). }
    procedure Wake;
    property Sock: TVdbSocket read FSock;
  end;

  { Kabul dongusu: VdbTcpAccept -> baglanti thread'i uretir. }
  TVdbServerAccept = class(TThread)
  private
    FServer: TVdbSqlServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TVdbSqlServer);
  end;

  TVdbSqlServer = class
  private
    FDir: string;
    FPort: Word;
    FListen: TVdbSocket;
    Fkv: TVDb;
    Ftb: TVTableDb;
    // KR-7: Fsq ve FLock kaldirildi. Her baglanti kendi TVSql ornegini
    // kullanir (TVdbServerConn.FSql). Ftb'nin MREW kilidi serilestirir.
    FConnsLock: TCriticalSection; // baglanti listesi
    FConns: TList;                // TVdbServerConn
    FAccept: TVdbServerAccept;
    FReady: Boolean;
    FStopping: Boolean;
    FLastErr: string;
    FServed: Integer;             // islenen QUERY cercevesi (hata dahil)
    FSessionId: Integer;        // genel oturum durumu (login/logout icin)
    FUser: string;              // R-12 devam: auth
    FPass: string;              // R-12 devam
    FMaxConns: Integer;      // R-12 devam: maksimum TCP baglanti
    procedure SetMaxConns(AValue: Integer);
    procedure AddConn(AConn: TVdbServerConn);
    procedure CloseEngine;
  public
    constructor Create(const ADir: string; APort: Word);
    destructor Destroy; override;
    { Motoru acar, dinleme soketini kurar ve kabul thread'ini baslatir.
      Dinleme SENKRON kurulur: port musait degilse hemen False. }
    function Start(out AErr: string): Boolean;
    { Kabul thread'ini bitirir, tum baglantilari uyandirir ve bekler,
      motoru kapatir. Cagrilmasi guvenlidir (idempotent). }
    procedure Stop;
    property Ready: Boolean read FReady;
    property Port: Word read FPort;
    property LastError: string read FLastErr;
    property Served: Integer read FServed;
    property Dir: string read FDir;
    property SessionId: Integer read FSessionId;
    { Eszamanli TCP baglanti siniri (varsayilan 64). Start'tan once
      veya calisirken degistirilebilir; 1..4096 araligina kirpilir. }
    property MaxConns: Integer read FMaxConns write SetMaxConns;
  end;

implementation

{ ------------------------------------------------------------ yanit yazici }

function SendResultFrame(ASock: TVdbSocket; const Res: TSqlResult): Boolean;
var
  i, c: Integer;
begin
  Result := False;
  if not VdbSendU8(ASock, VDBS_RSP_RESULT) then Exit;
  if not VdbSendU8(ASock, 0) then Exit;               // status = OK
  if not VdbSendU32(ASock, Cardinal(Res.Affected)) then Exit;
  if not VdbSendU32(ASock, Cardinal(Length(Res.Fields))) then Exit;
  for i := 0 to High(Res.Fields) do
    if not VdbSendStr(ASock, Res.Fields[i]) then Exit;
  if not VdbSendU64(ASock, UInt64(Length(Res.Rows))) then Exit;
  for i := 0 to High(Res.Rows) do
    for c := 0 to High(Res.Rows[i]) do
      if not VdbSendStr(ASock, Res.Rows[i][c]) then Exit;
  if not VdbSendStr(ASock, Res.Msg) then Exit;
  Result := VdbSendU8(ASock, VDBS_TERM);
end;

function SendErrorFrame(ASock: TVdbSocket; const AMsg: string): Boolean;
begin
  Result := False;
  if not VdbSendU8(ASock, VDBS_RSP_ERROR) then Exit;
  if not VdbSendStr(ASock, AMsg) then Exit;
  Result := VdbSendU8(ASock, VDBS_TERM);
end;

function SendPongFrame(ASock: TVdbSocket): Boolean;
begin
  Result := False;
  if not VdbSendU8(ASock, VDBS_RSP_PONG) then Exit;
  Result := VdbSendU8(ASock, VDBS_TERM);
end;

{ -------------------------------------------------------- baglanti thread }

constructor TVdbServerConn.Create(AServer: TVdbSqlServer; ASock: TVdbSocket);
begin
  inherited Create(True);            // askida basla; listeye ekle -> Start
  FreeOnTerminate := False;
  FServer := AServer;
  FSock := ASock;
  FSql := TVSql.Create(AServer.Ftb); // KR-7: baglantiya ozel SQL moturu
  FSessionActive := (AServer.SessionId <> 0); // varsayilan aktif oturum
  FPreparedSql := '';
  AServer.AddConn(Self);
  Start;
end;

destructor TVdbServerConn.Destroy;
begin
  if FSql <> nil then
  begin
    FSql.Free;
    FSql := nil;
  end;
  inherited Destroy;
end;

procedure TVdbServerConn.Wake;
begin
  if FSock <> VDB_SOCK_INVALID then
    VdbSockShutdown(FSock);
end;

procedure TVdbServerConn.Execute;
// KR-7: FSql bu baglantiyin TVSql ornegi. Okuma sorguları Ftb MREW kilidiyle
// paralel calisir; yazma serilestirme Ftb.Lock ile saglanir.
var
  typ: Byte;
  sql, user, pass, sqlP: string;
  mag: array[0..3] of AnsiChar;
  Res: TSqlResult;
  err: string;
begin
  try
    { 1) El sikisma: SUNUCU ilk mesaji gonderir. }
    mag[0] := 'V'; mag[1] := 'D'; mag[2] := 'B'; mag[3] := 'S';
    if not VdbSendAll(FSock, mag, 4) then Exit;
    if not VdbSendU8(FSock, VDBS_PROTO_VER) then Exit;
    if not VdbSendStr(FSock, 'VDB TCP SQL Server') then Exit;

    { 2) Komut dongusu. }
    while not Terminated do
    begin
      if not VdbRecvU8(FSock, typ) then Break;
      case typ of
        VDBS_CMD_QUERY:
          begin
            if not VdbRecvStr(FSock, sql) then Break;
            if not FSessionActive then
            begin
              if not VdbSendU8(FSock, VDBS_RSP_ERROR) then Break;
              if not VdbSendStr(FSock, 'oturum yok') then Break;
              if not VdbSendU8(FSock, VDBS_TERM) then Break;
            end
            else
            begin
              err := '';
              Res := Default(TSqlResult);
              try
                Res := FSql.Exec(sql);
              except
                on E: Exception do
                  err := E.Message;
              end;
              InterlockedIncrement(FServer.FServed);
              if err <> '' then
              begin
                if not SendErrorFrame(FSock, err) then Break;
              end
              else
              begin
                if not SendResultFrame(FSock, Res) then Break;
              end;
            end;
          end;
        VDBS_CMD_LOGIN:
          begin
            user := ''; pass := '';
            if not VdbRecvStr(FSock, user) then Break;
            if not VdbRecvStr(FSock, pass) then Break;
            // auth kontrolu
            if (user = FServer.FUser) and (pass = FServer.FPass) then
            begin
              FSessionActive := True;
              FServer.FSessionId := 1;  // genel gozlem icin
              if not VdbSendU8(FSock, VDBS_RSP_AUTH) then Break;
              if not VdbSendU8(FSock, 0) then Break;   // status: OK
              if not VdbSendU8(FSock, VDBS_TERM) then Break;
            end
            else
            begin
              FSessionActive := False;
              if not VdbSendU8(FSock, VDBS_RSP_AUTH) then Break;
              if not VdbSendU8(FSock, 1) then Break;   // status: FAIL
              if not VdbSendU8(FSock, VDBS_TERM) then Break;
            end;
          end;
        VDBS_CMD_LOGOUT:
          begin
            FSessionActive := False;
            Break;
          end;
        VDBS_CMD_PREPARE:
          begin
            if not VdbRecvStr(FSock, sqlP) then Break;
            if False and (sqlP = '') then Break; // mutasyon: etki test
            FPreparedSql := sqlP;
            if not VdbSendU8(FSock, $44) then Break; // RSP_PREPARE
            if not VdbSendU8(FSock, 0) then Break;   // OK
            if not VdbSendU8(FSock, VDBS_TERM) then Break;
          end;
        VDBS_CMD_EXECUTE:
          begin
            if FPreparedSql <> '' then
            begin
              err := '';
              Res := Default(TSqlResult);
              try
                Res := FSql.Exec(FPreparedSql);
              except
                on E: Exception do
                  err := E.Message;
              end;
              InterlockedIncrement(FServer.FServed);
              if err <> '' then
              begin
                if not SendErrorFrame(FSock, err) then Break;
              end
              else
              begin
                if not SendResultFrame(FSock, Res) then Break;
              end;
            end
            else
            begin
              if not VdbSendU8(FSock, VDBS_RSP_ERROR) then Break;
              if not VdbSendStr(FSock, 'hazirlanmis sorgu yok') then Break;
              if not VdbSendU8(FSock, VDBS_TERM) then Break;
            end;
          end;
        VDBS_CMD_PING:
          if not SendPongFrame(FSock) then Break;
        VDBS_CMD_BYE:
          Break;
      else
        Break;  // bilinmeyen tur: protokol hatasi -> baglanti kapanir
      end;
    end;
  finally
    { Thread FConns listesinde KALIR (sahip: sunucu); cikista objeyi
      kendisi serbest birakamaz (kendinden bekleme = deadlock). Listeyi
      yeniden baglanti kabul ederken AddConn toplar, kapanista Stop
      hepsini bekleyip serbest birakir. }
    VdbSockClose(FSock);
    FSock := VDB_SOCK_INVALID;
  end;
end;

{ ---------------------------------------------------------- kabul thread }

constructor TVdbServerAccept.Create(AServer: TVdbSqlServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
  Start;
end;

procedure TVdbServerAccept.Execute;
var
  sock: TVdbSocket;
begin
  while not FServer.FStopping do
  begin
    sock := VdbTcpAccept(FServer.FListen);
    if sock = VDB_SOCK_INVALID then Break;   // dinleme kapatildi
    if FServer.FStopping then
    begin
      VdbSockClose(sock);
      Break;
    end;
    { R-12 devam: kapasite (havuz-slot sayisi) kontrolu }
    if FServer.FConns.Count >= FServer.FMaxConns then
    begin
      // kapasite dolu -> baglanti refet (slot bosalana kadar)
      VdbSendU8(sock, VDBS_RSP_ERROR);
      VdbSendStr(sock, 'kapasite dolu');
      VdbSendU8(sock, VDBS_TERM);
      VdbSockClose(sock);
      Continue;
    end;
    { Sahiplik baglanti listesinde (AddConn); burada referans tutulmaz. }
    TVdbServerConn.Create(FServer, sock);
  end;
end;

{ ------------------------------------------------------------- sunucu }

constructor TVdbSqlServer.Create(const ADir: string; APort: Word);
begin
  inherited Create;
  FDir := ADir;
  FPort := APort;
  FListen := VDB_SOCK_INVALID;
  FConnsLock := TCriticalSection.Create;
  FConns := TList.Create;
  FMaxConns := 64;
end;

procedure TVdbSqlServer.SetMaxConns(AValue: Integer);
begin
  if AValue < 1 then AValue := 1;
  if AValue > 4096 then AValue := 4096;
  FMaxConns := AValue;
end;

destructor TVdbSqlServer.Destroy;
begin
  Stop;
  FConns.Free;
  FConnsLock.Free;
  inherited;
end;

procedure TVdbSqlServer.CloseEngine;
begin
  if Ftb <> nil then begin Ftb.Close; Ftb.Free; Ftb := nil; end;
  if Fkv <> nil then begin Fkv.Close; Fkv.Free; Fkv := nil; end;
end;

function TVdbSqlServer.Start(out AErr: string): Boolean;
begin
  Result := False;
  AErr := '';
  if FReady then
  begin
    AErr := 'sunucu zaten aktif';
    Exit;
  end;
  { 1) motor }
  try
    Fkv := TVDb.Create;
    Fkv.Open(FDir);
    Ftb := TVTableDb.Create(Fkv);
    Ftb.Open(FDir);
  except
    on E: Exception do
    begin
      AErr := 'motor acilamadi: ' + E.Message;
      CloseEngine;
      Exit;
    end;
  end;
  { 2) dinleme (SENKRON: port musait degilse hemen belli olur) }
  FListen := VdbTcpListen(FPort);
  if FListen = VDB_SOCK_INVALID then
  begin
    AErr := 'dinleme kurulamadi (port ' + IntToStr(FPort) + ')';
    CloseEngine;
    Exit;
  end;
  { 3) kabul thread'i }
  FStopping := False;
  FReady := True;
  FLastErr := '';
  FServed := 0;
  FSessionId := 1;     // varsayilan aktif oturum
  FUser := 'admin';    // varsayilan oturum bilgileri
  FPass := 'admin123';
  FAccept := TVdbServerAccept.Create(Self);
  Result := True;
end;

procedure TVdbSqlServer.Stop;
var
  snap: array of TVdbServerConn;
  i, n: Integer;
begin
  if not FReady then Exit;
  FStopping := True;
  { 1) dinlemeyi uyandir + KAPAT. Unix'te close() tek basina engellenmis
    accept()'i uyandirmaz; once shutdown gerekir (yoksa WaitFor sonsuza
    kadar bekler). Windows'ta dinleme soketinde shutdown hata doner,
    accept'i kapatma uyandirir. }
  if FListen <> VDB_SOCK_INVALID then
  begin
    VdbSockShutdown(FListen);
    VdbSockClose(FListen);
    FListen := VDB_SOCK_INVALID;
  end;
  if FAccept <> nil then
  begin
    FAccept.WaitFor;
    FreeAndNil(FAccept);
  end;
  { 2) tum baglantilari uyan -> bekle -> serbest birak }
  FConnsLock.Enter;
  try
    n := FConns.Count;
    SetLength(snap, n);
    for i := 0 to n - 1 do
      snap[i] := TVdbServerConn(FConns[i]);
  finally
    FConnsLock.Leave;
  end;
  for i := 0 to High(snap) do
    snap[i].Wake;
  for i := 0 to High(snap) do
  begin
    snap[i].WaitFor;
    snap[i].Free;
  end;
  FConnsLock.Enter;
  try
    FConns.Clear;
  finally
    FConnsLock.Leave;
  end;
  { 3) motoru kapat }
  CloseEngine;
  FReady := False;
end;

procedure TVdbSqlServer.AddConn(AConn: TVdbServerConn);
var
  i: Integer;
  c: TVdbServerConn;
begin
  FConnsLock.Enter;
  try
    FConns.Add(AConn);
    { Bitmis (BYE/kapanmis) baglanti thread'lerini topla: Execute kendini
      serbest birakamaz, sahip listedir. Finished thread'in WaitFor'su
      aninda doner; bellek burada geri kazanilir (uzun omurlu sunucuda
      liste buyumez). }
    i := 0;
    while i < FConns.Count do
    begin
      c := TVdbServerConn(FConns[i]);
      if c.Finished then
      begin
        c.WaitFor;
        c.Free;
        FConns.Delete(i);
      end
      else
        Inc(i);
    end;
  finally
    FConnsLock.Leave;
  end;
end;

end.
