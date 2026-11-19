program pg_cancel;

{$mode delphi}{$H+}

{ v3.69 / SKILL6 05: PostgreSQL CancelRequest (kod 80877102).

  ONCEKI DURUM: sunucu CancelRequest'i TANIMIYORDU ve her baglantiya
  `BackendKeyMsg(1, 0)` ile AYNI pid/secret veriliyordu. Bir istemci
  iptal istegi gonderemiyordu; gonderebilse bile hangi baglantinin
  kesilecegi belirsizdi.

  BU KAPI SUNLARI OLCER:
  PC1  her baglanti BENZERSIZ pid + secret alir
  PC2  dogru pid/secret -> o baglantiya bekleyen iptal; bir sonraki
       cumle 57014 (query_canceled) ile biter, baglanti KULLANILABILIR kalir
  PC3  yanlis secret -> iptal YOK (baska baglanti kesilemez)
  PC4  ADRESLEME: A'yi degil B'yi iptal eden istek yalniz B'yi etkiler
  PC5  bilinmeyen pid -> iptal YOK
  PC6  bozuk CancelRequest (yanlis uzunluk) -> yanit yok, baglanti kapanir,
       sunucu ayakta
  PC7  baglanti kapandiktan sonra gelen CancelRequest -> kimse etkilenmez
  PC8  iptal atomikligi: iptal edilen INSERT commit EDILMEZ, tablo degismez;
       yarim DML geri alinir
  PC9  Stop temiz kapanir

  Kapi sozlesmesi: `SONUC: N PASS, M FAIL` + FAIL varsa Halt(1). }

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Sockets, VDbNet, VDbPgWire;

const
  BASE_PORT   = 54560;
  PORT_TRIES  = 40;
  TEST_USER   = 'pgcancel';
  CANCEL_CODE = 80877102;

type
  TPgConn = record
    Sock: TVdbSocket;
    Pid: LongInt;
    Secret: LongInt;
  end;

  TPgResult = record
    Ready: Boolean;
    ErrCode: string;
    ErrMsg: string;
    Values: string;
    Rows: Integer;
  end;

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

function NetI32At(const ABuf: AnsiString; AOfs: Integer): LongInt;
begin
  Result := LongInt((Cardinal(Ord(ABuf[AOfs])) shl 24) or
    (Cardinal(Ord(ABuf[AOfs + 1])) shl 16) or
    (Cardinal(Ord(ABuf[AOfs + 2])) shl 8) or
    Cardinal(Ord(ABuf[AOfs + 3])));
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
  params := 'user' + #0 + AUser + #0 + 'database' + #0 + 'pgcancel' + #0 + #0;
  Result := BE32(4 + 4 + Length(params)) + BE32(196608) + params;
end;

function SendMsg(ASock: TVdbSocket; ATyp: AnsiChar; const ABody: AnsiString): Boolean;
begin
  Result := SendRaw(ASock, ATyp + BE32(4 + Length(ABody)) + ABody);
end;

{ ErrorResponse/NoticeResponse govdesi: (alan etiketi, NUL ile biten
  metin)* sonunda tek bir 0 bayti. SQLSTATE 'C' alanindadir. }
function PgField(const ABody: AnsiString; ATag: AnsiChar): string;
var
  i, j: Integer;
  tag: AnsiChar;
begin
  Result := '';
  i := 1;
  while i <= Length(ABody) do
  begin
    if ABody[i] = #0 then Exit;
    tag := ABody[i];
    Inc(i);
    j := i;
    while (j <= Length(ABody)) and (ABody[j] <> #0) do Inc(j);
    if tag = ATag then
    begin
      Result := Copy(ABody, i, j - i);
      Exit;
    end;
    i := j + 1;
  end;
end;

{ DataRow govdesi: int16 kolon sayisi, sonra her kolon icin int32 uzunluk
  (-1 = NULL) + deger. Gate yalniz 1. kolonu olcer. }
function FirstValue(const ABody: AnsiString): string;
var
  ncols, p: Integer;
  clen: LongWord;
begin
  Result := '';
  if Length(ABody) < 6 then Exit;
  ncols := (Ord(ABody[1]) shl 8) or Ord(ABody[2]);
  if ncols < 1 then Exit;
  p := 3;
  clen := (LongWord(Ord(ABody[p])) shl 24) or
          (LongWord(Ord(ABody[p + 1])) shl 16) or
          (LongWord(Ord(ABody[p + 2])) shl 8) or
          LongWord(Ord(ABody[p + 3]));
  if clen < $80000000 then
    Result := Copy(ABody, p + 4, clen);
end;

procedure CloseConn(var C: TPgConn);
begin
  if C.Sock <> VDB_SOCK_INVALID then
  begin
    VdbSockClose(C.Sock);
    C.Sock := VDB_SOCK_INVALID;
  end;
end;

{ ReadyForQuery ('Z') gelene kadar okur. 'K' (BackendKeyData) ile
  pid/secret'i toplar; hata alanlarini SQLSTATE olarak ayristirir. }
function Pump(var C: TPgConn; var R: TPgResult): Boolean;
var
  t: Byte;
  len: LongWord;
  body: AnsiString;
  guard: Integer;
begin
  Result := False;
  for guard := 1 to 2000 do
  begin
    if not VdbRecvU8(C.Sock, t) then Exit;
    if not Recv32BE(C.Sock, len) then Exit;
    if (len < 4) or (len > 32 * 1024 * 1024) then Exit;
    if not RecvBody(C.Sock, Integer(len) - 4, body) then Exit;
    case AnsiChar(t) of
      'K':
        begin
          if Length(body) >= 8 then
          begin
            C.Pid := NetI32At(body, 1);
            C.Secret := NetI32At(body, 5);
          end;
        end;
      'E':
        begin
          R.ErrCode := PgField(body, 'C');
          R.ErrMsg := PgField(body, 'M');
        end;
      'D':
        begin
          Inc(R.Rows);
          if R.Values = '' then R.Values := FirstValue(body);
        end;
      'Z':
        begin
          R.Ready := True;
          Exit(True);
        end;
    end;
  end;
end;

function OpenConn(const AUser: string; out C: TPgConn;
  out ADetail: string): Boolean;
var
  R: TPgResult;
begin
  Result := False;
  ADetail := '';
  C.Sock := VDB_SOCK_INVALID;
  C.Pid := 0;
  C.Secret := 0;
  C.Sock := VdbTcpConnect('127.0.0.1', GPort);
  if C.Sock = VDB_SOCK_INVALID then
  begin
    ADetail := 'baglanti kurulamadi';
    Exit;
  end;
  VdbSockSetTimeouts(C.Sock, 5000, 5000);
  if not SendRaw(C.Sock, StartupPacket(AUser)) then
  begin
    ADetail := 'startup gonderilemedi';
    CloseConn(C);
    Exit;
  end;
  R.Ready := False;
  R.ErrCode := '';
  if not Pump(C, R) then
  begin
    ADetail := 'startup yaniti okunamadi';
    CloseConn(C);
    Exit;
  end;
  if R.ErrCode <> '' then
  begin
    ADetail := 'startup hatasi ' + R.ErrCode + ' ' + R.ErrMsg;
    CloseConn(C);
    Exit;
  end;
  if (C.Pid = 0) or (C.Secret = 0) then
  begin
    ADetail := 'BackendKeyData yok';
    CloseConn(C);
    Exit;
  end;
  Result := True;
end;

function QuerySql(var C: TPgConn; const ASql: string;
  out R: TPgResult): Boolean;
begin
  R.Ready := False;
  R.ErrCode := '';
  R.ErrMsg := '';
  R.Values := '';
  R.Rows := 0;
  if not SendMsg(C.Sock, 'Q', AnsiString(ASql) + #0) then Exit(False);
  Result := Pump(C, R);
end;

function CancelPacket(APid, ASecret: LongInt): AnsiString;
begin
  Result := BE32(16) + BE32(CANCEL_CODE) + BE32(LongWord(APid)) +
            BE32(LongWord(ASecret));
end;

{ CancelRequest AYRI bir baglantida gelir ve YANIT ALMAZ. Sunucu istegi
  isleyip baglantiyi kapatmalidir: AClosed = ilk okuma 0 (FIN). }
function SendCancel(const APacket: AnsiString; out AClosed: Boolean;
  out ADetail: string): Boolean;
var
  s: TVdbSocket;
  b: Byte;
  n: Integer;
begin
  Result := False;
  AClosed := False;
  ADetail := '';
  s := VdbTcpConnect('127.0.0.1', GPort);
  if s = VDB_SOCK_INVALID then
  begin
    ADetail := 'cancel baglantisi kurulamadi';
    Exit;
  end;
  try
    VdbSockSetTimeouts(s, 2000, 2000);
    if not SendRaw(s, APacket) then
    begin
      ADetail := 'cancel paketi gonderilemedi';
      Exit;
    end;
    n := VdbRecvSome(s, b, 1);
    AClosed := n = 0;
    if n <> 0 then ADetail := 'kapanmadi, okunan=' + IntToStr(n);
    Result := True;
  finally
    VdbSockClose(s);
  end;
end;

function CancelConn(const C: TPgConn; out AClosed: Boolean;
  out ADetail: string): Boolean;
begin
  Result := SendCancel(CancelPacket(C.Pid, C.Secret), AClosed, ADetail);
end;

function FreshDir(const AName: string): string;
var
  d: string;
  sr: TSearchRec;
begin
  d := TestDir + PathDelim + AName;
  Result := IncludeTrailingPathDelimiter(d);
  if FindFirst(IncludeTrailingPathDelimiter(d) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') and
         ((sr.Attr and faDirectory) = 0) then
        DeleteFile(IncludeTrailingPathDelimiter(d) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ForceDirectories(d);
end;

var
  Srv: TVdbPgServer;
  Dir, err, detail, val: string;
  started: Boolean;
  i: Integer;
  A, B, D: TPgConn;
  R: TPgResult;
  closed: Boolean;
  ok, t1, t2, t3: Boolean;

begin
  GPass := 0;
  GFail := 0;
  TestDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp';
  ForceDirectories(TestDir);
  Dir := FreshDir('pg_cancel');

  Srv := nil;
  started := False;
  GPort := 0;
  err := '';
  for i := 0 to PORT_TRIES - 1 do
  begin
    Srv := TVdbPgServer.Create(Dir, Word(BASE_PORT + i));
    Srv.BindHost := '127.0.0.1';
    if Srv.Start(err) then
    begin
      GPort := Srv.Port;
      started := True;
      Break;
    end;
    FreeAndNil(Srv);
  end;
  Chk('PC0 sunucu loopback uzerinde basladi', started, err);
  if not started then
  begin
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  ok := False;
  detail := '';
  if OpenConn(TEST_USER, A, detail) then
  begin
    ok := QuerySql(A, 'CREATE TABLE pc(a INTEGER, b TEXT)', R);
    ok := ok and (R.ErrCode = '');
    detail := R.ErrCode + ' ' + R.ErrMsg;
  end;
  Chk('PC0 tablo olusturuldu', ok, detail);

  { --- PC1: benzersiz BackendKeyData ----------------------------------- }
  detail := '';
  ok := OpenConn(TEST_USER, B, detail);
  Chk('PC1 ikinci baglanti acildi', ok, detail);
  if ok then
  begin
    Chk('PC1 pid''ler benzersiz', A.Pid <> B.Pid,
      'A=' + IntToStr(A.Pid) + ' B=' + IntToStr(B.Pid));
    Chk('PC1 secret''lar benzersiz', A.Secret <> B.Secret,
      'A=' + IntToStr(A.Secret) + ' B=' + IntToStr(B.Secret));
    Chk('PC1 pid/secret sifir degil', (A.Pid > 0) and (A.Secret <> 0) and
      (B.Pid > 0) and (B.Secret <> 0),
      'A=' + IntToStr(A.Pid) + '/' + IntToStr(A.Secret) +
      ' B=' + IntToStr(B.Pid) + '/' + IntToStr(B.Secret));

    { --- PC2: dogru pid/secret -> bekleyen iptal ----------------------- }
    ok := CancelConn(A, closed, detail);
    Chk('PC2 CancelRequest yanitsiz kapandi', ok and closed, detail);
    ok := QuerySql(A, 'SELECT 1', R);
    Chk('PC2 iptal edilen cumle 57014 ile bitti', ok and (R.ErrCode = '57014'),
      'code=' + R.ErrCode + ' msg=' + R.ErrMsg + ' ready=' + BoolToStr(R.Ready, True));
    ok := QuerySql(A, 'SELECT 2', R);
    Chk('PC2 iptal TEK SEFERLIK: sonraki cumle calisti',
      ok and (R.ErrCode = '') and (R.Values = '2'),
      'code=' + R.ErrCode + ' val=' + R.Values);

    { --- PC3: yanlis secret -> iptal YOK ------------------------------- }
    ok := SendCancel(CancelPacket(A.Pid, A.Secret xor 1), closed, detail);
    Chk('PC3 yanlis secret yanitsiz kapandi', ok and closed, detail);
    ok := QuerySql(A, 'SELECT 3', R);
    Chk('PC3 yanlis secret iptal ETMEDI',
      ok and (R.ErrCode = '') and (R.Values = '3'),
      'code=' + R.ErrCode + ' val=' + R.Values);

    { --- PC4: ADRESLEME ----------------------------------------------- }
    ok := CancelConn(B, closed, detail);
    Chk('PC4 B icin CancelRequest kapandi', ok and closed, detail);
    t1 := QuerySql(B, 'SELECT 4', R);
    t1 := t1 and (R.ErrCode = '57014');
    Chk('PC4 adreslenen baglanti iptal edildi', t1,
      'code=' + R.ErrCode + ' val=' + R.Values);
    t2 := QuerySql(A, 'SELECT 5', R);
    Chk('PC4 diger baglanti ETKILENMEDI',
      t2 and (R.ErrCode = '') and (R.Values = '5'),
      'code=' + R.ErrCode + ' val=' + R.Values);

    { --- PC5: bilinmeyen pid ------------------------------------------ }
    ok := SendCancel(CancelPacket(B.Pid + 100000, B.Secret), closed, detail);
    Chk('PC5 bilinmeyen pid yanitsiz kapandi', ok and closed, detail);
    ok := QuerySql(B, 'SELECT 6', R);
    Chk('PC5 bilinmeyen pid iptal ETMEDI',
      ok and (R.ErrCode = '') and (R.Values = '6'),
      'code=' + R.ErrCode + ' val=' + R.Values);

    { --- PC6: bozuk CancelRequest (uzunluk 12) ------------------------ }
    ok := SendCancel(BE32(12) + BE32(CANCEL_CODE) + BE32(1), closed, detail);
    Chk('PC6 bozuk paket kabul edilmedi ve baglanti kapandi',
      ok and closed, detail);
    detail := '';
    ok := OpenConn(TEST_USER, D, detail);
    Chk('PC6 bozuk paketten sonra sunucu yeni istemci aliyor', ok, detail);
    if ok then
    begin
      ok := QuerySql(D, 'SELECT 7', R);
      Chk('PC6 yeni baglanti calisiyor', ok and (R.Values = '7'),
        'code=' + R.ErrCode + ' val=' + R.Values);
    end;
  end;

  { --- PC7: baglanti kapandiktan sonra CancelRequest -------------------- }
  if D.Sock <> VDB_SOCK_INVALID then
  begin
    CloseConn(D);
    Sleep(200);
    ok := SendCancel(CancelPacket(D.Pid, D.Secret), closed, detail);
    Chk('PC7 kapanmis baglanti icin CancelRequest zararsiz', ok and closed,
      detail);
    detail := '';
    ok := OpenConn(TEST_USER, D, detail);
    Chk('PC7 sunucu ayakta', ok, detail);
  end
  else
  begin
    Chk('PC7 kapanmis baglanti icin CancelRequest zararsiz', False,
      'baglanti yok');
    Chk('PC7 sunucu ayakta', False, 'baglanti yok');
  end;

  { --- PC8: iptal atomikligi ------------------------------------------- }
  if D.Sock <> VDB_SOCK_INVALID then
  begin
    t1 := QuerySql(D, 'BEGIN', R) and (R.ErrCode = '');
    Chk('PC8 BEGIN', t1, R.ErrCode + ' ' + R.ErrMsg);
    t2 := QuerySql(D, 'INSERT INTO pc VALUES (1,''x'')', R) and (R.ErrCode = '');
    Chk('PC8 islem ici INSERT yazildi', t2, R.ErrCode + ' ' + R.ErrMsg);
    ok := CancelConn(D, closed, detail);
    t3 := QuerySql(D, 'INSERT INTO pc VALUES (2,''y'')', R);
    Chk('PC8 iptal edilen INSERT 57014 ile bitti',
      t3 and (R.ErrCode = '57014'),
      'code=' + R.ErrCode + ' msg=' + R.ErrMsg);
    t3 := QuerySql(D, 'ROLLBACK', R) and (R.ErrCode = '');
    Chk('PC8 ROLLBACK', t3, R.ErrCode + ' ' + R.ErrMsg);
    t3 := QuerySql(D, 'SELECT COUNT(*) FROM pc', R);
    Chk('PC8 yarim DML COMMIT EDILMEDI (tablo bos)',
      t3 and (R.ErrCode = '') and (R.Values = '0'),
      'code=' + R.ErrCode + ' val=' + R.Values);

    { otomatik commit: iptal edilen tek cumle de yazmamali }
    ok := CancelConn(D, closed, detail);
    t3 := QuerySql(D, 'INSERT INTO pc VALUES (3,''z'')', R);
    Chk('PC8 otomatik commit iptali 57014', t3 and (R.ErrCode = '57014'),
      'code=' + R.ErrCode + ' msg=' + R.ErrMsg);
    t3 := QuerySql(D, 'SELECT COUNT(*) FROM pc', R);
    Chk('PC8 iptal edilen otomatik commit yazmadi',
      t3 and (R.ErrCode = '') and (R.Values = '0'),
      'code=' + R.ErrCode + ' val=' + R.Values);

    { iptal tuketildi: sonraki DML normal calisir }
    t3 := QuerySql(D, 'INSERT INTO pc VALUES (4,''w'')', R);
    Chk('PC8 iptalden sonra DML calisti', t3 and (R.ErrCode = ''),
      'code=' + R.ErrCode + ' msg=' + R.ErrMsg);
    t3 := QuerySql(D, 'SELECT COUNT(*) FROM pc', R);
    Chk('PC8 son INSERT yazildi', t3 and (R.Values = '1'),
      'code=' + R.ErrCode + ' val=' + R.Values);
  end
  else
    Chk('PC8 atomiklik', False, 'baglanti yok');

  CloseConn(A);
  CloseConn(B);
  CloseConn(D);

  { --- PC9: temiz kapanis ---------------------------------------------- }
  Srv.Stop;
  Chk('PC9 Stop sonrasi baglanti sayaci sifir', Srv.ConnCount = 0,
    IntToStr(Srv.ConnCount));
  FreeAndNil(Srv);

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
