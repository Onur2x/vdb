unit VDbPgWire;

{ M1 (2026-10-19): PostgreSQL wire protocol (v3) — MINIMAL sunucu.

  Amac: mevcut PostgreSQL istemcilerinin (psql, bazi suruculer) VDB'ye
  "basit sorgu" (Simple Query, 'Q') ile baglanabilmesi.

  Desteklenen:
    - StartupMessage v3 (SSLRequest/GSSENCRequest -> 'N')
    - AuthenticationOk (trust; parola istenmez)
    - ParameterStatus (server_version, client_encoding, DateStyle,
      integer_datetimes)
    - BackendKeyData, ReadyForQuery
    - 'Q' simple query: RowDescription + DataRow* + CommandComplete
    - Extended query protocol: Parse ('P'), Bind ('B'), Describe ('D'),
      Execute ('E'), Close ('C'), Flush ('H'), Sync ('S') — ancak
      YALNIZCA PARAMETRESIZ sorgular (0 parametre). Prepared statement
      adlari ve portal adlari desteklenir; Describe Portal sorguyu
      calistirip sonucu onbellege alir.
    - ErrorResponse + ReadyForQuery; hata sonrasi Sync'e kadar mesajlar
      yutulur (PostgreSQL semantigi).
    - 'X' Terminate

  DESTEKLENMEYEN (bilincli sinir):
    - Sorgu parametreleri ($1, $2 ...), COPY, SSL/TLS, gercek tip OID'leri.
      Parametreli Parse/Bind hata dondurur (baglanti Sync ile devam eder).
    - NULL ile bos metin ayrimi: motor ikisini de '' olarak tutar;
      DataRow'da her ikisi de uzunluk 0 olarak gonderilir.
    - Tum alanlar TEXT (OID 25) olarak bildirilir.

  Eszamanlilik: VDbSqlServer ile ayni model — baglanti basina TVSql,
  paylasilan TVTableDb; yazmalar Ftb kilidiyle serilesir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, VDbTypes, VDbCore, VDbTable, VDbSql, VDbAst,
  VDbNet;

type
  TVdbPgServer = class;

  TVdbPgConn = class(TThread)
  private
    FServer: TVdbPgServer;
    FSock: TVdbSocket;
    FSql: TVSql;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TVdbPgServer; ASock: TVdbSocket);
    destructor Destroy; override;
    procedure Wake;
    property Sock: TVdbSocket read FSock;
  end;

  TVdbPgAccept = class(TThread)
  private
    FServer: TVdbPgServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TVdbPgServer);
  end;

  TVdbPgServer = class
  private
    FDir: string;
    FPort: Word;
    FListen: TVdbSocket;
    Fkv: TVDb;
    Ftb: TVTableDb;
    FConnsLock: TCriticalSection;
    FConns: TList;
    FAccept: TVdbPgAccept;
    FReady: Boolean;
    FStopping: Boolean;
    FLastErr: string;
    FServed: Integer;
    FMaxConns: Integer;
    procedure AddConn(AConn: TVdbPgConn);
    procedure CloseEngine;
  public
    constructor Create(const ADir: string; APort: Word);
    destructor Destroy; override;
    function Start(out AErr: string): Boolean;
    procedure Stop;
    property Ready: Boolean read FReady;
    property Port: Word read FPort;
    property LastError: string read FLastErr;
    property Served: Integer read FServed;
    property Dir: string read FDir;
  end;

implementation

type
  TPgPortal = record
    Sql: string;
    Done: Boolean;
    Res: TSqlResult;
    Err: string;
  end;

{ ---------------------------------------------------- ag bayt duzeni (BE) }

function NetI16(V: SmallInt): AnsiString;
var
  u: Word;
begin
  u := Word(V);
  Result := AnsiChar(u shr 8) + AnsiChar(u and $FF);
end;

function NetI32(V: LongInt): AnsiString;
var
  u: Cardinal;
begin
  u := Cardinal(V);
  Result := AnsiChar(u shr 24) + AnsiChar((u shr 16) and $FF) +
    AnsiChar((u shr 8) and $FF) + AnsiChar(u and $FF);
end;

function PgMsg(const T: AnsiChar; const Body: AnsiString): AnsiString;
begin
  Result := T + NetI32(Length(Body) + 4) + Body;
end;

function RecvI32(S: TVdbSocket; out V: LongInt): Boolean;
var
  b: array[0..3] of Byte;
begin
  Result := VdbRecvAll(S, b, 4);
  if Result then
    V := LongInt((Cardinal(b[0]) shl 24) or (Cardinal(b[1]) shl 16) or
      (Cardinal(b[2]) shl 8) or Cardinal(b[3]));
end;

function NetToI32(const S: AnsiString; Ofs: Integer): LongInt;
begin
  Result := LongInt((Cardinal(Ord(S[Ofs])) shl 24) or
    (Cardinal(Ord(S[Ofs + 1])) shl 16) or
    (Cardinal(Ord(S[Ofs + 2])) shl 8) or Cardinal(Ord(S[Ofs + 3])));
end;

function ReadCStr(const Buf: AnsiString; var P: Integer): string;
var
  st: Integer;
begin
  Result := '';
  st := P;
  while (P <= Length(Buf)) and (Buf[P] <> #0) do Inc(P);
  if P > st then
    Result := Copy(Buf, st, P - st);
  if P <= Length(Buf) then Inc(P);   // #0'i atla
end;

{ -------------------------------------------------------- mesaj uretimi }

function AuthOkMsg: AnsiString;
begin
  Result := PgMsg('R', NetI32(0));
end;

function ParamMsg(const Nm, Val: string): AnsiString;
begin
  Result := PgMsg('S', Nm + #0 + Val + #0);
end;

function BackendKeyMsg(Pid, Secret: LongInt): AnsiString;
begin
  Result := PgMsg('K', NetI32(Pid) + NetI32(Secret));
end;

function ReadyMsg: AnsiString;
begin
  Result := PgMsg('Z', 'I');
end;

function RowDescMsg(const Fields: TStrArray): AnsiString;
var
  body: AnsiString;
  i: Integer;
begin
  body := NetI16(Length(Fields));
  for i := 0 to High(Fields) do
    body := body + Fields[i] + #0 + NetI32(0) + NetI16(0) + NetI32(25) +
      NetI16(-1) + NetI32(-1) + NetI16(0);
  Result := PgMsg('T', body);
end;

function DataRowMsg(const Row: TStrArray): AnsiString;
var
  body: AnsiString;
  i: Integer;
  v: string;
begin
  body := NetI16(Length(Row));
  for i := 0 to High(Row) do
  begin
    v := Row[i];
    body := body + NetI32(Length(v)) + v;
  end;
  Result := PgMsg('D', body);
end;

function CommandMsg(const Tag: string): AnsiString;
begin
  Result := PgMsg('C', Tag + #0);
end;

function ErrorMsg(const Msg: string): AnsiString;
var
  body: AnsiString;
begin
  body := 'S' + 'ERROR' + #0 + 'V' + 'ERROR' + #0 + 'C' + '42000' +
    #0 + 'M' + Msg + #0 + #0;
  Result := PgMsg('E', body);
end;

function CommandTag(const Sql: string; const Res: TSqlResult): string;
var
  s, w1, w2: string;
  i, n: Integer;
begin
  if Length(Res.Fields) > 0 then
    Exit('SELECT ' + IntToStr(Length(Res.Rows)));
  s := UpperCase(Trim(Sql));
  w1 := '';
  w2 := '';
  n := 0;
  i := 1;
  while (i <= Length(s)) and (n < 2) do
  begin
    while (i <= Length(s)) and (s[i] = ' ') do Inc(i);
    if i > Length(s) then Break;
    if n = 0 then
    begin
      while (i <= Length(s)) and (s[i] <> ' ') do
      begin
        w1 := w1 + s[i];
        Inc(i);
      end;
    end
    else
    begin
      while (i <= Length(s)) and (s[i] <> ' ') do
      begin
        w2 := w2 + s[i];
        Inc(i);
      end;
    end;
    Inc(n);
  end;
  if w1 = 'INSERT' then Exit('INSERT 0 ' + IntToStr(Res.Affected));
  if w1 = 'UPDATE' then Exit('UPDATE ' + IntToStr(Res.Affected));
  if w1 = 'DELETE' then Exit('DELETE ' + IntToStr(Res.Affected));
  if ((w1 = 'CREATE') or (w1 = 'DROP') or (w1 = 'ALTER')) and (w2 <> '') then
    Exit(w1 + ' ' + w2);
  if w1 = '' then Exit('SELECT 0');
  Result := w1;
end;

function SendPg(S: TVdbSocket; const M: AnsiString): Boolean;
begin
  Result := False;
  if M = '' then Exit(True);
  Result := VdbSendAll(S, M[1], Length(M));
end;

{ ------------------------------------------------ startup + basit sorgu }

function ReadStartup(S: TVdbSocket; out AUser: string): Boolean;
var
  len, code: LongInt;
  body: AnsiString;
  p: Integer;
  k, v: string;
begin
  Result := False;
  AUser := '';
  while True do
  begin
    if not RecvI32(S, len) then Exit;
    if (len < 8) or (len > 65536) then Exit;
    SetLength(body, len - 4);
    if (len - 4) > 0 then
      if not VdbRecvAll(S, body[1], len - 4) then Exit;
    code := NetToI32(body, 1);
    if (code = 80877103) or (code = 80877104) then
    begin
      // SSLRequest / GSSENCRequest: sifreleme yok -> tek bayt 'N'.
      if not VdbSendU8(S, Ord('N')) then Exit;
      Continue;
    end;
    if code <> 196608 then Exit;       // yalnizca 3.0
    p := 5;
    while p <= Length(body) do
    begin
      k := ReadCStr(body, p);
      if k = '' then Break;
      v := ReadCStr(body, p);
      if k = 'user' then AUser := v;
    end;
    Exit(True);
  end;
end;

function HandleQuery(S: TVdbSocket; FSql: TVSql; const Sql: string;
  out AServed: Boolean): Boolean;
var
  Res: TSqlResult;
  err: string;
  i: Integer;
begin
  Result := False;
  AServed := True;
  err := '';
  Res := Default(TSqlResult);
  try
    Res := FSql.Exec(Sql);
  except
    on E: Exception do
      err := E.Message;
  end;
  if err <> '' then
  begin
    if not SendPg(S, ErrorMsg(err)) then Exit;
    Exit(SendPg(S, ReadyMsg));
  end;
  if Length(Res.Fields) > 0 then
  begin
    if not SendPg(S, RowDescMsg(Res.Fields)) then Exit;
    for i := 0 to High(Res.Rows) do
      if not SendPg(S, DataRowMsg(Res.Rows[i])) then Exit;
  end;
  if not SendPg(S, CommandMsg(CommandTag(Sql, Res))) then Exit;
  Result := SendPg(S, ReadyMsg);
end;

{ ------------------------------------------------------- baglanti thread }

constructor TVdbPgConn.Create(AServer: TVdbPgServer; ASock: TVdbSocket);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
  FSock := ASock;
  FSql := TVSql.Create(AServer.Ftb);
  AServer.AddConn(Self);
  Start;
end;

destructor TVdbPgConn.Destroy;
begin
  if FSql <> nil then
  begin
    FSql.Free;
    FSql := nil;
  end;
  inherited Destroy;
end;

procedure TVdbPgConn.Wake;
begin
  if FSock <> VDB_SOCK_INVALID then
    VdbSockShutdown(FSock);
end;

procedure TVdbPgConn.Execute;
var
  typ: Byte;
  len: LongInt;
  payload: AnsiString;
  sql, user: string;
  served: Boolean;
  Stmts: TDictionary<string, string>;
  Portals: TDictionary<string, TPgPortal>;
  skipUntilSync: Boolean;
  p, np, nf, i2, nParams, nFmt, maxRows: Integer;
  nm, q, kind: string;
  pt: TPgPortal;

  function TakeI16: Integer;
  begin
    Result := 0;
    if p + 1 <= Length(payload) then
    begin
      Result := (Ord(payload[p]) shl 8) or Ord(payload[p + 1]);
      Inc(p, 2);
    end;
  end;

  procedure ExtFail(const Msg: string);
  begin
    skipUntilSync := True;
    SendPg(FSock, ErrorMsg(Msg));
  end;

  function ExecutePortal(var P: TPgPortal): Boolean;
  begin
    Result := False;
    P.Err := '';
    P.Res := Default(TSqlResult);
    try
      P.Res := FSql.Exec(P.Sql);
      Result := True;
    except
      on E: Exception do P.Err := E.Message;
    end;
    P.Done := True;
  end;

begin
  Stmts := nil;
  Portals := nil;
  try
    if not ReadStartup(FSock, user) then Exit;
    Stmts := TDictionary<string, string>.Create;
    Portals := TDictionary<string, TPgPortal>.Create;
    if not SendPg(FSock, AuthOkMsg) then Exit;
    if not SendPg(FSock, ParamMsg('server_version', '14.0 (VDB)')) then Exit;
    if not SendPg(FSock, ParamMsg('client_encoding', 'UTF8')) then Exit;
    if not SendPg(FSock, ParamMsg('DateStyle', 'ISO')) then Exit;
    if not SendPg(FSock, ParamMsg('integer_datetimes', 'on')) then Exit;
    if not SendPg(FSock, BackendKeyMsg(1, 0)) then Exit;
    if not SendPg(FSock, ReadyMsg) then Exit;

    skipUntilSync := False;
    while not Terminated do
    begin
      if not VdbRecvU8(FSock, typ) then Break;
      if typ = Ord('X') then Break;          // Terminate
      if not RecvI32(FSock, len) then Break;
      if (len < 4) or (len > 64 * 1024 * 1024) then Break;
      SetLength(payload, len - 4);
      if (len - 4) > 0 then
        if not VdbRecvAll(FSock, payload[1], len - 4) then Break;

      // Hata sonrasi Sync'e kadar tum mesajlari yut.
      if skipUntilSync and (typ <> Ord('S')) then Continue;

      if typ = Ord('Q') then
      begin
        sql := payload;
        while (sql <> '') and (sql[Length(sql)] = #0) do
          SetLength(sql, Length(sql) - 1);
        Stmts.Remove('');
        Portals.Remove('');
        if not HandleQuery(FSock, FSql, sql, served) then Break;
        if served then InterlockedIncrement(FServer.FServed);
      end
      else if typ = Ord('P') then            // Parse
      begin
        p := 1;
        nm := ReadCStr(payload, p);
        q := ReadCStr(payload, p);
        nParams := TakeI16;
        if nParams > 0 then
          ExtFail('parametreli prepared statement desteklenmiyor (' +
            IntToStr(nParams) + ' parametre)')
        else
        begin
          Stmts.AddOrSetValue(nm, q);
          if not SendPg(FSock, PgMsg('1', '')) then Break;
        end;
      end
      else if typ = Ord('B') then            // Bind
      begin
        p := 1;
        nm := ReadCStr(payload, p);          // portal
        q := ReadCStr(payload, p);           // statement
        nFmt := TakeI16;
        Inc(p, nFmt * 2);
        nParams := TakeI16;
        for i2 := 1 to nParams do
        begin
          maxRows := 0;
          if p + 3 <= Length(payload) then
          begin
            maxRows := LongInt((Cardinal(Ord(payload[p])) shl 24) or
              (Cardinal(Ord(payload[p + 1])) shl 16) or
              (Cardinal(Ord(payload[p + 2])) shl 8) or
              Cardinal(Ord(payload[p + 3])));
            Inc(p, 4);
            if maxRows > 0 then Inc(p, maxRows);
          end;
        end;
        nFmt := TakeI16;
        if nParams > 0 then
          ExtFail('sorgu parametreleri desteklenmiyor')
        else if not Stmts.TryGetValue(q, sql) then
          ExtFail('prepared statement yok: ' + q)
        else
        begin
          pt := Default(TPgPortal);
          pt.Sql := sql;
          pt.Done := False;
          Portals.AddOrSetValue(nm, pt);
          if not SendPg(FSock, PgMsg('2', '')) then Break;
        end;
      end
      else if typ = Ord('D') then            // Describe
      begin
        if Length(payload) >= 2 then
        begin
          kind := AnsiChar(payload[1]);
          p := 2;
          nm := ReadCStr(payload, p);
          if kind = 'S' then
          begin
            if not SendPg(FSock, PgMsg('t', NetI16(0))) then Break;  // 0 parametre
            if not SendPg(FSock, PgMsg('n', '')) then Break;          // NoData
          end
          else if Portals.TryGetValue(nm, pt) then
          begin
            if not pt.Done then
            begin
              ExecutePortal(pt);
              Portals.AddOrSetValue(nm, pt);
            end;
            if pt.Err <> '' then
              ExtFail(pt.Err)
            else if Length(pt.Res.Fields) > 0 then
            begin
              if not SendPg(FSock, RowDescMsg(pt.Res.Fields)) then Break;
            end
            else if not SendPg(FSock, PgMsg('n', '')) then Break;
          end
          else
            ExtFail('portal yok: ' + nm);
        end;
      end
      else if typ = Ord('E') then            // Execute
      begin
        p := 1;
        nm := ReadCStr(payload, p);
        if Portals.TryGetValue(nm, pt) then
        begin
          if not pt.Done then
          begin
            ExecutePortal(pt);
            Portals.AddOrSetValue(nm, pt);
          end;
          if pt.Err <> '' then
            ExtFail(pt.Err)
          else
          begin
            for i2 := 0 to High(pt.Res.Rows) do
              if not SendPg(FSock, DataRowMsg(pt.Res.Rows[i2])) then Break;
            if not SendPg(FSock, CommandMsg(CommandTag(pt.Sql, pt.Res))) then Break;
            InterlockedIncrement(FServer.FServed);
          end;
        end
        else
          ExtFail('portal yok: ' + nm);
      end
      else if typ = Ord('C') then            // Close
      begin
        if Length(payload) >= 2 then
        begin
          kind := AnsiChar(payload[1]);
          p := 2;
          nm := ReadCStr(payload, p);
          if kind = 'S' then Stmts.Remove(nm) else Portals.Remove(nm);
        end;
        if not SendPg(FSock, PgMsg('3', '')) then Break;
      end
      else if typ = Ord('S') then            // Sync
      begin
        skipUntilSync := False;
        if not SendPg(FSock, ReadyMsg) then Break;
      end
      else if typ = Ord('H') then            // Flush: hemen gonderiyoruz, no-op
      begin
      end
      else
      begin
        // Bilinmeyen mesaj turu: protokol bozulmasin diye kapat.
        Break;
      end;
    end;
  finally
    Portals.Free;
    Stmts.Free;
    VdbSockClose(FSock);
  end;
end;

{ --------------------------------------------------------- kabul thread }

constructor TVdbPgAccept.Create(AServer: TVdbPgServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
  Start;
end;

procedure TVdbPgAccept.Execute;
var
  sock: TVdbSocket;
begin
  while not FServer.FStopping do
  begin
    sock := VdbTcpAccept(FServer.FListen);
    if sock = VDB_SOCK_INVALID then Break;
    if FServer.FConns.Count >= FServer.FMaxConns then
    begin
      VdbSockClose(sock);   // startup oncesi: protokol mesaji gondermeden kapat
      Continue;
    end;
    TVdbPgConn.Create(FServer, sock);
  end;
end;

{ --------------------------------------------------------------- sunucu }

constructor TVdbPgServer.Create(const ADir: string; APort: Word);
begin
  inherited Create;
  FDir := ADir;
  FPort := APort;
  FListen := VDB_SOCK_INVALID;
  FConnsLock := TCriticalSection.Create;
  FConns := TList.Create;
  FMaxConns := 16;
end;

destructor TVdbPgServer.Destroy;
begin
  Stop;
  FConns.Free;
  FConnsLock.Free;
  inherited;
end;

procedure TVdbPgServer.CloseEngine;
begin
  if Ftb <> nil then begin Ftb.Close; Ftb.Free; Ftb := nil; end;
  if Fkv <> nil then begin Fkv.Close; Fkv.Free; Fkv := nil; end;
end;

function TVdbPgServer.Start(out AErr: string): Boolean;
begin
  Result := False;
  AErr := '';
  if FReady then
  begin
    AErr := 'sunucu zaten aktif';
    Exit;
  end;
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
  FListen := VdbTcpListen(FPort);
  if FListen = VDB_SOCK_INVALID then
  begin
    AErr := 'dinleme kurulamadi (port ' + IntToStr(FPort) + ')';
    CloseEngine;
    Exit;
  end;
  FStopping := False;
  FReady := True;
  FLastErr := '';
  FServed := 0;
  FAccept := TVdbPgAccept.Create(Self);
  Result := True;
end;

procedure TVdbPgServer.Stop;
var
  snap: array of TVdbPgConn;
  i, n: Integer;
begin
  if not FReady then Exit;
  FStopping := True;
  if FListen <> VDB_SOCK_INVALID then
  begin
    VdbSockClose(FListen);
    FListen := VDB_SOCK_INVALID;
  end;
  if FAccept <> nil then
  begin
    FAccept.WaitFor;
    FreeAndNil(FAccept);
  end;
  FConnsLock.Enter;
  try
    n := FConns.Count;
    SetLength(snap, n);
    for i := 0 to n - 1 do
      snap[i] := TVdbPgConn(FConns[i]);
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
  CloseEngine;
  FReady := False;
end;

procedure TVdbPgServer.AddConn(AConn: TVdbPgConn);
begin
  FConnsLock.Enter;
  try
    FConns.Add(AConn);
  finally
    FConnsLock.Leave;
  end;
end;

end.
