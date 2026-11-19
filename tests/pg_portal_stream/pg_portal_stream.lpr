{ pg_portal_stream - PostgreSQL genisletilmis protokol: portal ve akis kapisi

  Amac: SKILL5 9.5 (portal / prepared statement kaynak sinirlari) ve 10.1
  (Execute maxRows) bulgularini AYIRT EDICI bicimde olcmek.

  Onceden:
    - Execute govdesindeki Int32 maxRows HIC okunmuyordu; her Execute tum
      sonucu bastan gonderiyordu (imlec yok, PortalSuspended yok).
    - Stmts/Portals sozlukleri ve TPgPortal.Res sinirsizdi: bir istemci Sync
      gondermeden binlerce portal acip her birine tam sonuc koyabiliyordu.

  Kontroller:
    PP1  maxRows=10 -> 10 DataRow + PortalSuspended ('s'), CommandComplete YOK
    PP2  ayni portal tekrar Execute(maxRows=10) -> SONRAKI 10 satir (imlec)
    PP3  ucuncu Execute(maxRows=10) -> kalan 5 satir + CommandComplete ('C')
    PP4  tukenmis portal tekrar Execute -> 0 satir (kopya yok) + CommandComplete
    PP5  maxRows=0 -> 25 satirin tamami tek Execute'ta
    PP6  Sync portallari dusurur -> Execute 'portal yok' hatasi
    PP7  MaxPortals=4 -> 5. Bind 'portal siniri' ile reddedilir, baglanti yasar
    PP8  MaxPrepared=3 -> 4. Parse 'prepared statement siniri' ile reddedilir
    PP9  MaxPortalResultBytes=200 -> sonuc REDDEDILIR (OOM yok), sunucu yasar
    PP10 Describe Portal RowDescription doner ve satir TUKETMEZ
    PP11 portal Close sonrasi Execute 'portal yok'
    PP12 tum bunlardan sonra YENI istemci normal sorgu yapabilir

  Sonuc: "SONUC: N PASS, M FAIL"; FAIL > 0 ise Halt(1).
}
program pg_portal_stream;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbNet, VDbPgWire;

const
  BASE_PORT  = 54560;
  TEST_USER  = 'ppstream';
  PORT_TRIES = 40;
  NROWS      = 25;

var
  GPass, GFail: Integer;
  GPort: Word;
  TestDir: string;

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
  params := 'user' + #0 + AUser + #0 + 'database' + #0 + 'ppstream' + #0 + #0;
  Result := BE32(4 + 4 + Length(params)) + BE32(196608) + params;
end;

function SendMsg(ASock: TVdbSocket; ATyp: AnsiChar;
  const ABody: AnsiString): Boolean;
begin
  Result := SendRaw(ASock, ATyp + BE32(4 + Length(ABody)) + ABody);
end;

type
  TMsgLog = record
    Types: AnsiString;      // sirayla gelen mesaj turleri
    Rows: array of string;  // DataRow ilk kolon metinleri
    ErrText: string;
    NDataRow: Integer;
    NSuspend: Integer;
    NComplete: Integer;
  end;

{ DataRow govdesinden ilk kolonun metnini cikarir. }
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

{ ReadyForQuery ('Z') gelene kadar okur. COPY-In ('G') gorulurse orada durur
  (bu kapida COPY kullanilmiyor; guvenlik icin). }
function ReadUntilReady(ASock: TVdbSocket; var L: TMsgLog): Boolean;
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
      'E': if Length(body) > 1 then
             L.ErrText := L.ErrText + StringReplace(Copy(body, 2, Length(body)),
               #0, ' ', [rfReplaceAll]);
      'D':
        begin
          Inc(L.NDataRow);
          SetLength(L.Rows, Length(L.Rows) + 1);
          L.Rows[High(L.Rows)] := FirstCol(body);
        end;
      's': Inc(L.NSuspend);
      'C': Inc(L.NComplete);
      'G': Exit(True);
      'Z': Exit(True);
    end;
  end;
end;

function ConnectStartup(APort: Word; out ASock: TVdbSocket;
  out ADetail: string): Boolean;
var
  L: TMsgLog;
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

{ --- genisletilmis protokol yardimcilari ------------------------------- }

function BindMsg(const APortal, AStmt: string): AnsiString;
begin
  { portal adi + statement adi + 0 parametre formati + 0 parametre +
    0 sonuc formati }
  Result := APortal + #0 + AStmt + #0 + BE16(0) + BE16(0) + BE16(0);
end;

function ExecuteMsg(const APortal: string; AMaxRows: Integer): AnsiString;
begin
  Result := APortal + #0 + BE32(LongWord(AMaxRows));
end;

function ParseMsg(const AName, ASql: string): AnsiString;
begin
  Result := AName + #0 + ASql + #0 + BE16(0);
end;

{ Tek bir genisletilmis protokol turu gonderir ve Sync ile bitirip
  ReadyForQuery'ye kadar okur. }
function ExtRoundTrip(ASock: TVdbSocket; var L: TMsgLog): Boolean;
begin
  FillChar(L, SizeOf(L), 0);
  if not SendMsg(ASock, 'S', '') then Exit(False);
  Result := ReadUntilReady(ASock, L);
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
  D: string;
  err, det, vals: string;
  s: TVdbSocket;
  L: TMsgLog;
  i, j, portIdx: Integer;
  ok: Boolean;
  rowList: string;

begin
  GPass := 0;
  GFail := 0;
  D := ExtractFilePath(ParamStr(0));
  TestDir := D + 'tmp' + PathDelim;
  if not DirectoryExists(TestDir) then
    ForceDirectories(TestDir);
  WipeDir(TestDir);

  Srv := nil;
  GPort := 0;
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
  Chk('PP0 sunucu acildi', Srv <> nil, err);
  if Srv = nil then
  begin
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  { --- veri hazirla: 25 satir --- }
  ok := False;
  det := '';
  if ConnectStartup(GPort, s, det) then
  begin
    try
      FillChar(L, SizeOf(L), 0);
      vals := 'CREATE TABLE t (id INTEGER, pad TEXT)';
      if SendMsg(s, 'Q', vals + #0) and ReadUntilReady(s, L) and (L.ErrText = '') then
      begin
        vals := 'INSERT INTO t VALUES ';
        for i := 1 to NROWS do
        begin
          if i > 1 then vals := vals + ',';
          vals := vals + '(' + IntToStr(i) + ',''r' + IntToStr(i) + ''')';
        end;
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'Q', vals + #0) and ReadUntilReady(s, L) and
              (L.ErrText = '');
        if not ok then det := 'INSERT: ' + L.ErrText;
      end
      else
        det := 'CREATE: ' + L.ErrText;
    finally
      VdbSockClose(s);
    end;
  end
  else
    det := 'baglanti: ' + det;
  Chk('PP0b 25 satir hazir', ok, det);
  if not ok then
  begin
    Srv.Stop;
    FreeAndNil(Srv);
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  { --- ana senaryo (tek baglanti) --- }
  det := '';
  if ConnectStartup(GPort, s, det) then
  begin
    try
      { Parse + Bind: adli statement ve portal }
      FillChar(L, SizeOf(L), 0);
      ok := SendMsg(s, 'P', ParseMsg('st1', 'SELECT id FROM t ORDER BY id')) and
            SendMsg(s, 'B', BindMsg('po1', 'st1')) and
            ExtRoundTrip(s, L) and (L.ErrText = '');
      Chk('PP0c Parse+Bind kabul', ok, 'hata=' + L.ErrText);
      if not ok then
      begin
        L.ErrText := '';
      end
      else
      begin
        { PP1: maxRows=10 }
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'E', ExecuteMsg('po1', 10)) and ExtRoundTrip(s, L);
        rowList := '';
        for j := 0 to High(L.Rows) do rowList := rowList + L.Rows[j] + ',';
        Chk('PP1 maxRows=10 -> 10 satir', ok and (L.NDataRow = 10),
          'satir=' + IntToStr(L.NDataRow) + ' hata=' + L.ErrText);
        Chk('PP1b PortalSuspended', (L.NSuspend = 1) and (L.NComplete = 0),
          's=' + IntToStr(L.NSuspend) + ' C=' + IntToStr(L.NComplete));
        Chk('PP1c ilk satirlar 1..10', rowList = '1,2,3,4,5,6,7,8,9,10,',
          'gelen=' + rowList);

        { PP2: devam }
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'E', ExecuteMsg('po1', 10)) and ExtRoundTrip(s, L);
        rowList := '';
        for j := 0 to High(L.Rows) do rowList := rowList + L.Rows[j] + ',';
        Chk('PP2 maxRows=10 devam -> 10 satir', ok and (L.NDataRow = 10),
          'satir=' + IntToStr(L.NDataRow) + ' hata=' + L.ErrText);
        Chk('PP2b imlec kaldigi yerden (11..20)',
          rowList = '11,12,13,14,15,16,17,18,19,20,', 'gelen=' + rowList);
        Chk('PP2c hala PortalSuspended', L.NSuspend = 1,
          's=' + IntToStr(L.NSuspend));

        { PP3: son parca }
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'E', ExecuteMsg('po1', 10)) and ExtRoundTrip(s, L);
        rowList := '';
        for j := 0 to High(L.Rows) do rowList := rowList + L.Rows[j] + ',';
        Chk('PP3 kalan 5 satir (21..25)',
          ok and (L.NDataRow = 5) and (rowList = '21,22,23,24,25,'),
          'satir=' + IntToStr(L.NDataRow) + ' gelen=' + rowList);
        Chk('PP3b CommandComplete ve suspend YOK',
          (L.NComplete = 1) and (L.NSuspend = 0),
          'C=' + IntToStr(L.NComplete) + ' s=' + IntToStr(L.NSuspend));

        { PP4: tukenmis portal: kopya satir YOK }
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'E', ExecuteMsg('po1', 10)) and ExtRoundTrip(s, L);
        Chk('PP4 tukenmis portal 0 satir (kopya yok)',
          ok and (L.NDataRow = 0) and (L.NComplete = 1),
          'satir=' + IntToStr(L.NDataRow) + ' C=' + IntToStr(L.NComplete));

        { PP5: maxRows=0 -> tamami }
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'B', BindMsg('po2', 'st1')) and
              SendMsg(s, 'E', ExecuteMsg('po2', 0)) and
              ExtRoundTrip(s, L);
        Chk('PP5 maxRows=0 -> 25 satir', ok and (L.NDataRow = NROWS) and
          (L.NComplete = 1) and (L.NSuspend = 0),
          'satir=' + IntToStr(L.NDataRow) + ' C=' + IntToStr(L.NComplete));

        { PP6: Sync portali DUSURMEZ; imlec korunur (v3.64 duzeltmesi).
          Onkapi: Sync Portals.Clear yapiyordu -> "portal yok". }
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'B', BindMsg('po6', 'st1')) and
              SendMsg(s, 'E', ExecuteMsg('po6', 10)) and ExtRoundTrip(s, L);
        Chk('PP6a yeni portal ilk 10', ok and (L.NDataRow = 10) and
          (L.NSuspend = 1), 'satir=' + IntToStr(L.NDataRow) +
          ' hata=' + L.ErrText);
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'E', ExecuteMsg('po6', 0)) and ExtRoundTrip(s, L);
        Chk('PP6 Sync sonrasi portal YASAR (imlec korunur)',
          ok and (L.ErrText = '') and (L.NDataRow = 15) and (L.NComplete = 1),
          'hata=' + L.ErrText + ' satir=' + IntToStr(L.NDataRow));

        { PP10: Describe Portal satir TUKETMEZ }
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'P', ParseMsg('st2', 'SELECT id FROM t ORDER BY id')) and
              SendMsg(s, 'B', BindMsg('po3', 'st2')) and ExtRoundTrip(s, L);
        if ok and (L.ErrText = '') then
        begin
          FillChar(L, SizeOf(L), 0);
          ok := SendMsg(s, 'D', 'P' + 'po3' + #0) and ExtRoundTrip(s, L);
          Chk('PP10 Describe Portal RowDescription doner',
            ok and (Pos('T', L.Types) > 0) and (L.ErrText = ''),
            'turler=' + string(L.Types) + ' hata=' + L.ErrText);
          FillChar(L, SizeOf(L), 0);
          ok := SendMsg(s, 'E', ExecuteMsg('po3', 10)) and ExtRoundTrip(s, L);
          rowList := '';
          for j := 0 to High(L.Rows) do rowList := rowList + L.Rows[j] + ',';
          Chk('PP10b Describe satir tuketmedi (1..10)',
            ok and (rowList = '1,2,3,4,5,6,7,8,9,10,'), 'gelen=' + rowList);

          { PP11: portal Close sonrasi Execute }
          FillChar(L, SizeOf(L), 0);
          ok := SendMsg(s, 'C', 'P' + 'po3' + #0) and ExtRoundTrip(s, L);
          FillChar(L, SizeOf(L), 0);
          ok := SendMsg(s, 'E', ExecuteMsg('po3', 10)) and ExtRoundTrip(s, L);
          Chk('PP11 Close sonrasi portal yok',
            ok and (Pos('portal yok', L.ErrText) > 0), 'hata=' + L.ErrText);
        end
        else
        begin
          Chk('PP10 Describe Portal RowDescription doner', False,
            'hazirlik: ' + L.ErrText);
          Chk('PP11 Close sonrasi portal yok', False, 'hazirlik basarisiz');
        end;

        { PP7: MaxPortals=4 -> 5. Bind reddedilir }
        { Once acik portallari kapat ki sayim sifirdan baslasin (v3.64'te
          portallar Sync'te dusmedigi icin bu gerekli). }
        SendMsg(s, 'C', 'P' + 'po1' + #0);
        SendMsg(s, 'C', 'P' + 'po2' + #0);
        SendMsg(s, 'C', 'P' + 'po6' + #0);
        Srv.MaxPortals := 4;
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'S', '');
        ReadUntilReady(s, L);
        L.ErrText := '';
        ok := True;
        for j := 1 to 5 do
        begin
          FillChar(L, SizeOf(L), 0);
          if not (SendMsg(s, 'B', BindMsg('pcol' + IntToStr(j), 'st1')) and
                  SendMsg(s, 'S', '') and ReadUntilReady(s, L)) then
            ok := False;
          if j < 5 then
          begin
            if (L.ErrText <> '') then ok := False;
          end
          else if Pos('portal siniri', L.ErrText) = 0 then
            ok := False;
        end;
        Chk('PP7 MaxPortals=4 -> 5. portal reddedilir', ok,
          'hata=' + L.ErrText);
        Srv.MaxPortals := 256;

        { PP8: MaxPrepared=3 -> 4. Parse reddedilir }
        Srv.MaxPrepared := 3;
        FillChar(L, SizeOf(L), 0);
        SendMsg(s, 'S', '');
        ReadUntilReady(s, L);
        for j := 1 to 4 do
        begin
          FillChar(L, SizeOf(L), 0);
          SendMsg(s, 'P', ParseMsg('sp' + IntToStr(j), 'SELECT 1'));
          SendMsg(s, 'S', '');
          ReadUntilReady(s, L);
        end;
        Chk('PP8 MaxPrepared=3 -> 4. statement reddedilir',
          Pos('prepared statement siniri', L.ErrText) > 0, 'hata=' + L.ErrText);
        Srv.MaxPrepared := 512;

        { PP9: bellek siniri -> RED, OOM yok }
        Srv.MaxPortalResultBytes := 200;
        FillChar(L, SizeOf(L), 0);
        ok := SendMsg(s, 'P', ParseMsg('st3', 'SELECT id FROM t ORDER BY id')) and
              SendMsg(s, 'B', BindMsg('po9', 'st3')) and
              SendMsg(s, 'E', ExecuteMsg('po9', 0)) and
              ExtRoundTrip(s, L);
        Chk('PP9 sonuc bellegi siniri -> kontrollu RED',
          ok and (Pos('portal sonuc bellegi siniri', L.ErrText) > 0) and
          (L.NDataRow = 0),
          'hata=' + L.ErrText + ' satir=' + IntToStr(L.NDataRow));
        Srv.MaxPortalResultBytes := Int64(64) * 1024 * 1024;
      end;
    finally
      VdbSockClose(s);
    end;
  end
  else
    Chk('PP0c Parse+Bind kabul', False, 'baglanti: ' + det);

  { PP12: sunucu hala saglikli }
  det := '';
  ok := False;
  if ConnectStartup(GPort, s, det) then
  begin
    try
      FillChar(L, SizeOf(L), 0);
      ok := SendMsg(s, 'Q', 'SELECT COUNT(*) FROM t' + #0) and
            ReadUntilReady(s, L) and (L.ErrText = '');
      Chk('PP12 yeni istemci sayim yapabilir',
        ok and (Length(L.Rows) = 1) and (L.Rows[0] = IntToStr(NROWS)),
        'satir=' + L.ErrText + ' deger=' + L.Rows[0]);
    finally
      VdbSockClose(s);
    end;
  end
  else
    Chk('PP12 yeni istemci sayim yapabilir', False, 'baglanti: ' + det);

  Srv.Stop;
  FreeAndNil(Srv);
  WipeDir(TestDir);

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
