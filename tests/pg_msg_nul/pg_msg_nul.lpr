program pg_msg_nul;
{ v3.65 KALICI REGRESYON KAPISI - PG mesaj alanlarinda NUL sonlandirici (F-43).

  Bulgu: `ReadCStr` payload icinde #0 bulamazsa sessizce dizinin sonuna kadar
  okur ve P'yi Length+1'e tasir; cagiran taraf "alan bitti" saniyor. Yani
  sonlandiricisi EKSIK bir Parse/Bind/Startup paketi kabul ediliyor, alan
  siniri kayboluyor ve sonraki alanlar (parametre OID'leri vb.) sessizce 0
  kabul ediliyordu.

  Bu kapida olculen:
    a) NUL ile biten normal paketler hala calisir (kontrol)
    b) Parse'te SQL alani NUL'suz -> ErrorResponse (on-kapi: ParseComplete)
    c) Bind'de statement adi NUL'suz -> ErrorResponse (on-kapi: BindComplete)
    d) Startup parametreleri eksik sonlandirilmis -> baglanti reddedilir
    e) hata sonrasi baglanti yasar (Sync -> ReadyForQuery -> normal sorgu)
    f) sunucu cokmez: yeni baglanti normal calisir

  On-kapi (F-43 oncesi HEAD) bu kapida SEAM GEREKTIRMEZ; gate yalniz mevcut
  genel API'yi kullanir. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbNet, VDbPgWire;

const
  TEST_USER  = 'vdbtest';
  BASE_PORT  = 54760;
  PORT_TRIES = 40;

var
  GPass, GFail: Integer;
  GPort: Word;
  TestDir: string;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('FAIL ', AName, ' - ', ADetail)
    else
      WriteLn('FAIL ', AName);
  end;
  Flush(Output);
end;

function BE32(AValue: LongWord): AnsiString;
begin
  SetLength(Result, 4);
  Result[1] := AnsiChar((AValue shr 24) and $FF);
  Result[2] := AnsiChar((AValue shr 16) and $FF);
  Result[3] := AnsiChar((AValue shr 8) and $FF);
  Result[4] := AnsiChar(AValue and $FF);
end;

function BE16(AValue: Word): AnsiString;
begin
  SetLength(Result, 2);
  Result[1] := AnsiChar((AValue shr 8) and $FF);
  Result[2] := AnsiChar(AValue and $FF);
end;

function SendRaw(ASock: TVdbSocket; const AData: AnsiString): Boolean;
begin
  Result := False;
  if Length(AData) = 0 then Exit(True);
  Result := VdbSendAll(ASock, AData[1], Length(AData));
end;

function RecvBody(ASock: TVdbSocket; ALen: Integer; out AData: AnsiString): Boolean;
var
  tmp: TBytes;
begin
  AData := '';
  if ALen <= 0 then Exit(True);
  SetLength(tmp, ALen);
  Result := VdbRecvAll(ASock, tmp[0], ALen);
  if Result then
  begin
    SetLength(AData, ALen);
    Move(tmp[0], AData[1], ALen);
  end;
end;

function Recv32BE(ASock: TVdbSocket; out AValue: LongWord): Boolean;
var
  b: array[0..3] of Byte;
begin
  Result := VdbRecvAll(ASock, b, 4);
  if not Result then Exit;
  AValue := (LongWord(b[0]) shl 24) or (LongWord(b[1]) shl 16) or
            (LongWord(b[2]) shl 8) or LongWord(b[3]);
end;

function StartupPacket(const AUser: string): AnsiString;
var
  params: AnsiString;
begin
  params := 'user' + #0 + AUser + #0 + 'database' + #0 + 'nulcheck' + #0 + #0;
  Result := BE32(4 + 4 + Length(params)) + BE32(196608) + params;
end;

function SendMsg(ASock: TVdbSocket; ATyp: AnsiChar;
  const ABody: AnsiString): Boolean;
begin
  Result := SendRaw(ASock, ATyp + BE32(4 + Length(ABody)) + ABody);
end;

type
  TReply = record
    Types: AnsiString;
    Rows: array of string;
    ErrText: string;
    SqlState: string;
  end;

function ErrSqlState(const ABody: AnsiString): string;
var
  i, st: Integer;
  f: AnsiChar;
  s: string;
begin
  Result := '';
  i := 1;
  while i <= Length(ABody) do
  begin
    f := ABody[i];
    if f = #0 then Break;
    Inc(i);
    st := i;
    while (i <= Length(ABody)) and (ABody[i] <> #0) do Inc(i);
    s := Copy(ABody, st, i - st);
    Inc(i);
    if f = 'C' then Result := s;
  end;
end;

function FirstCol(const ABody: AnsiString): string;
var
  ncols, clen: Integer;
begin
  Result := '';
  if Length(ABody) < 6 then Exit;
  ncols := (Ord(ABody[1]) shl 8) or Ord(ABody[2]);
  if ncols < 1 then Exit;
  clen := (Integer(Ord(ABody[3])) shl 24) or (Integer(Ord(ABody[4])) shl 16) or
          (Integer(Ord(ABody[5])) shl 8) or Integer(Ord(ABody[6]));
  if (clen < 0) or (Length(ABody) < 7 + clen - 1) then Exit;
  if clen = 0 then Exit;
  Result := Copy(ABody, 7, clen);
end;

function ReadUntilReady(ASock: TVdbSocket; var L: TReply): Boolean;
var
  t: Byte;
  len: LongWord;
  body: AnsiString;
  guard: Integer;
begin
  Result := False;
  for guard := 1 to 5000 do
  begin
    if not VdbRecvU8(ASock, t) then Exit;
    if not Recv32BE(ASock, len) then Exit;
    if (len < 4) or (len > 64 * 1024 * 1024) then Exit;
    if not RecvBody(ASock, Integer(len) - 4, body) then Exit;
    L.Types := L.Types + AnsiChar(t);
    case AnsiChar(t) of
      'E':
        begin
          L.SqlState := ErrSqlState(body);
          L.ErrText := L.ErrText + StringReplace(body, #0, ' ', [rfReplaceAll]);
        end;
      'D':
        begin
          SetLength(L.Rows, Length(L.Rows) + 1);
          L.Rows[High(L.Rows)] := FirstCol(body);
        end;
      'Z': Exit(True);
    end;
  end;
end;

function ConnectStartup(APort: Word; out ASock: TVdbSocket;
  out ADetail: string): Boolean;
var
  L: TReply;
begin
  Result := False;
  ADetail := '';
  ASock := VdbTcpConnect('127.0.0.1', APort);
  if ASock = VDB_SOCK_INVALID then
  begin
    ADetail := 'baglanti kurulamadi';
    Exit;
  end;
  VdbSockSetTimeouts(ASock, 8000, 8000);
  if not SendRaw(ASock, StartupPacket(TEST_USER)) then
  begin
    ADetail := 'startup gonderilemedi';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  FillChar(L, SizeOf(L), 0);
  if not ReadUntilReady(ASock, L) then
  begin
    ADetail := 'startup yaniti okunamadi';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  if L.ErrText <> '' then
  begin
    ADetail := 'startup E yaniti: ' + L.ErrText;
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  Result := True;
end;

function QExec(ASock: TVdbSocket; const ASql: string; var L: TReply): Boolean;
begin
  FillChar(L, SizeOf(L), 0);
  Result := SendMsg(ASock, 'Q', ASql + #0) and ReadUntilReady(ASock, L);
end;

{ Sync gonderip ReadyForQuery'ye kadar okur. }
function SyncRound(ASock: TVdbSocket; var L: TReply): Boolean;
begin
  FillChar(L, SizeOf(L), 0);
  Result := SendMsg(ASock, 'S', '') and ReadUntilReady(ASock, L);
end;

procedure WipeDir(const ADir: string);
var
  sr: TSearchRec;
begin
  if FindFirst(ADir + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(ADir + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

var
  Srv: TVdbPgServer;
  err, det: string;
  s, s2: TVdbSocket;
  L, L2: TReply;
  portIdx, n: Integer;
  ok: Boolean;

begin
  GPass := 0;
  GFail := 0;
  TestDir := ExtractFilePath(ParamStr(0)) + 'tmp' + PathDelim;
  if not DirectoryExists(TestDir) then ForceDirectories(TestDir);
  WipeDir(TestDir);

  Srv := nil;
  GPort := 0;
  err := '';
  for portIdx := 0 to PORT_TRIES - 1 do
  begin
    Srv := TVdbPgServer.Create(TestDir, Word(BASE_PORT + portIdx));
    if Srv.Start(err) then
    begin
      GPort := Word(BASE_PORT + portIdx);
      Break;
    end;
    FreeAndNil(Srv);
  end;
  Chk('N0 sunucu acildi', Srv <> nil, err);
  if Srv = nil then
  begin
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  { --- a) kontrol: NUL ile biten normal paketler calisir --- }
  det := '';
  if ConnectStartup(GPort, s, det) then
  begin
    try
      FillChar(L, SizeOf(L), 0);
      ok := SendMsg(s, 'P', 'st1' + #0 + 'SELECT 1' + #0 + BE16(0)) and
            SendMsg(s, 'B', 'po1' + #0 + 'st1' + #0 + BE16(0) + BE16(0) +
              BE16(0)) and
            SendMsg(s, 'E', 'po1' + #0 + BE32(0)) and
            SyncRound(s, L);
      Chk('N1 NUL ile biten Parse+Bind+Execute hala calisir',
        ok and (L.ErrText = '') and (Pos('1', L.Types) > 0),
        'tipler=' + string(L.Types) + ' ' + L.ErrText);
    finally
      VdbSockClose(s);
    end;
  end
  else
    Chk('N1 NUL ile biten Parse+Bind+Execute hala calisir', False, det);

  { --- b) Parse: SQL alani NUL'suz -> ErrorResponse --- }
  det := '';
  ok := False;
  if ConnectStartup(GPort, s, det) then
  begin
    try
      FillChar(L, SizeOf(L), 0);
      ok := SendMsg(s, 'P', 'st2' + #0 + 'SELECT 2') and   { NUL yok }
            SyncRound(s, L);
      Chk('N2 Parse: eksik NUL -> ErrorResponse',
        ok and (L.ErrText <> '') and (Pos('1', L.Types) = 0),
        'tipler=' + string(L.Types) + ' ' + L.ErrText);
      Chk('N3 hata metni sonlandiriciyi adlandiriyor',
        Pos('NUL', L.ErrText) > 0, L.ErrText);
      { e) hata sonrasi baglanti yasar }
      ok := QExec(s, 'SELECT 3', L) and (L.ErrText = '');
      n := -1;
      if ok and (Length(L.Rows) > 0) then n := StrToIntDef(Trim(L.Rows[0]), -1);
      Chk('N4 hata sonrasi baglanti yasar ve sorgu calisir', ok and (n = 3),
        'deger=' + IntToStr(n) + ' ' + L.ErrText);
    finally
      VdbSockClose(s);
    end;
  end
  else
  begin
    Chk('N2 Parse: eksik NUL -> ErrorResponse', False, det);
    Chk('N3 hata metni sonlandiriciyi adlandiriyor', False, det);
    Chk('N4 hata sonrasi baglanti yasar ve sorgu calisir', False, det);
  end;

  { --- c) Bind: statement adi NUL'suz -> ErrorResponse --- }
  det := '';
  ok := False;
  if ConnectStartup(GPort, s, det) then
  begin
    try
      SendMsg(s, 'P', 'st5' + #0 + 'SELECT 5' + #0 + BE16(0));
      SyncRound(s, L);
      FillChar(L, SizeOf(L), 0);
      { statement adi payload'in SONUNA kadar gidiyor: hic #0 yok.
        On-kapi adi 'st5yok' sanip "prepared statement yok" der; duzeltme
        ise alan cercevesini once kontrol eder. }
      ok := SendMsg(s, 'B', 'po5' + #0 + 'st5yok') and
            SyncRound(s, L);
      Chk('N5 Bind: eksik NUL -> hata metni sonlandiriciyi adlandiriyor',
        ok and (L.ErrText <> '') and (Pos('NUL', L.ErrText) > 0) and
        (Pos('2', L.Types) = 0),
        'tipler=' + string(L.Types) + ' ' + L.ErrText);
      { kontrol: NUL ile biten ama TANIMSIZ statement -> normal arama yolu }
      FillChar(L, SizeOf(L), 0);
      ok := SendMsg(s, 'B', 'po6' + #0 + 'yokst' + #0 + BE16(0) + BE16(0) +
              BE16(0)) and
            SyncRound(s, L);
      Chk('N5b kontrol: tanimsiz statement -> prepared statement yok',
        ok and (Pos('prepared statement yok', L.ErrText) > 0),
        'tipler=' + string(L.Types) + ' ' + L.ErrText);
      ok := QExec(s, 'SELECT 6', L) and (L.ErrText = '');
      Chk('N6 Bind hatasi sonrasi baglanti yasar', ok, L.ErrText);
    finally
      VdbSockClose(s);
    end;
  end
  else
  begin
    Chk('N5 Bind: eksik NUL -> hata metni sonlandiriciyi adlandiriyor',
      False, det);
    Chk('N5b kontrol: tanimsiz statement -> prepared statement yok',
      False, det);
    Chk('N6 Bind hatasi sonrasi baglanti yasar', False, det);
  end;

  { --- d) Startup: parametreler eksik sonlandirilmis -> reddedilir --- }
  s2 := VdbTcpConnect('127.0.0.1', GPort);
  ok := s2 <> VDB_SOCK_INVALID;
  if ok then
  begin
    try
      VdbSockSetTimeouts(s2, 4000, 4000);
      FillChar(L, SizeOf(L), 0);
      { 'user'#0 + kullanici, ardindan hic #0 yok ve cift #0 yok }
      ok := SendRaw(s2, BE32(4 + 4 + 5 + Length(TEST_USER)) + BE32(196608) +
            'user' + #0 + TEST_USER) and ReadUntilReady(s2, L);
      Chk('N7 Startup: eksik sonlandirici -> baglanti reddedilir',
        (not ok) or (Pos('Z', L.Types) = 0),
        'tipler=' + string(L.Types) + ' ' + L.ErrText);
    finally
      VdbSockClose(s2);
    end;
  end
  else
    Chk('N7 Startup: eksik sonlandirici -> baglanti reddedilir', False,
      'baglanti kurulamadi');

  { --- f) sunucu cokmedi: yeni baglanti normal calisir --- }
  det := '';
  ok := False;
  if ConnectStartup(GPort, s, det) then
  begin
    try
      ok := QExec(s, 'SELECT 7', L) and (L.ErrText = '');
      n := -1;
      if ok and (Length(L.Rows) > 0) then n := StrToIntDef(Trim(L.Rows[0]), -1);
      Chk('N8 sunucu cokmedi: yeni baglanti normal calisir', ok and (n = 7),
        'deger=' + IntToStr(n) + ' ' + L.ErrText);
    finally
      VdbSockClose(s);
    end;
  end
  else
    Chk('N8 sunucu cokmedi: yeni baglanti normal calisir', False, det);

  Srv.Stop;
  FreeAndNil(Srv);

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
