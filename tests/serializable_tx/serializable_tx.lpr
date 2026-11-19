program serializable_tx;
{ v3.65 KALICI REGRESYON KAPISI - SERIALIZABLE izolasyon dogrulamasi (F-42).

  Bulgu: `TIsolationLevel` icinde SERIALIZABLE vardi ama commit aninda
  araya giren baska bir commit HIC kontrol edilmiyordu; yani SERIALIZABLE,
  REPEATABLE READ ile birebir ayni davraniyordu (write skew serbest).

  Bu kapida olculen:
    a) REPEATABLE READ ayni araya girmede COMMIT eder (eski davranis
       KORUNUR; V2/mevcut uygulamalar bozulmaz)
    b) SERIALIZABLE ayni araya girmede ecSerializationFailure (40001) ile
       REDDEDILIR ve islemin hicbir satiri yazilmaz
    c) cakisma yokken SERIALIZABLE COMMIT eder (yanlis abort yok)
    d) bayrak yapiskan degildir: REPEATABLE READ'a donunce yine commit eder
    e) PG tel protokolunde SQLSTATE 40001 gorunur

  Ayirt etme olcutu: (b) on-kapida (F-42 oncesi) COMMIT eder ve iki satir
  yazilir; duzeltmeden sonra hata doner ve yalniz A'nin satiri kalir.
  Her kontrol bagimsizdir; biri duserse digerleri yine olculur. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbFactory, VDbBackendApi, VDbBackendV3, VDbTable,
  VDbSql, VDbErr, VDbNet, VDbPgWire;

const
  TEST_USER  = 'vdbtest';
  BASE_PORT  = 54720;
  PORT_TRIES = 40;

var
  GDir, GDb: string;
  GPass, GFail: Integer;

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

function CountQ(S: TVSql; const ASql: string): Integer;
var
  r: TSqlResult;
begin
  Result := -1;
  r := S.Exec(ASql);
  if (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) then
    Result := StrToIntDef(Trim(r.Rows[0][0]), -1);
end;

type
  TOutcome = record
    Ok: Boolean;
    Code: TVDbErrorCode;
    Msg: string;
  end;

{ Tek bir SQL cumlesi calistirir; hata varsa yakalar (kapi dusurmez). }
function TryExec(S: TVSql; const ASql: string): TOutcome;
begin
  Result.Ok := False;
  Result.Code := ecNone;
  Result.Msg := '';
  try
    S.Exec(ASql);
    Result.Ok := True;
  except
    on E: EVDbException do
    begin
      Result.Code := E.ErrorCode;
      Result.Msg := E.Message;
    end;
    on E: Exception do
    begin
      Result.Code := ecGeneral;
      Result.Msg := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ --- A) dogrudan API: iki IVdbBackend, ayni dosya ------------------------ }
procedure CaseApi;
var
  A, B: IVdbBackend;
  TbA, TbB: TVTableDb;
  SqA, SqB: TVSql;
  { F-45: ayni TVTableDb/backend'i paylasan ek oturumlar (PG wire deseni). }
  SqC, SqD, SqE: TVSql;
  o, o2: TOutcome;
  n: Integer;
begin
  A := TVdbBackendV3.Create(GDb);
  TbA := TVTableDb.CreateBackend(A);
  TbA.Open(GDir);
  SqA := TVSql.Create(TbA);
  SqA.Exec('CREATE TABLE s (id INTEGER PRIMARY KEY, v TEXT)');

  B := nil;
  VdbOpen(GDb, B, False, False);
  TbB := TVTableDb.CreateBackend(B);
  TbB.Open(GDir);
  SqB := TVSql.Create(TbB);
  Chk('S1 iki oturum ayni dosyada acildi', (A <> nil) and (B <> nil));

  { --- a) REPEATABLE READ: araya giren commit COMMIT'i engellemez --- }
  SqA.Exec('BEGIN');
  SqA.Exec('INSERT INTO s (id, v) VALUES (1, ''a'')');
  SqB.Exec('BEGIN');
  o := TryExec(SqA, 'COMMIT');
  Chk('S2 A (yazar rezervasyonu) commit etti', o.Ok, o.Msg);
  o := TryExec(SqB, 'INSERT INTO s (id, v) VALUES (2, ''b'')');
  Chk('S3 REPEATABLE READ araya giren commit sonrasi INSERT kabul',
    o.Ok, o.Msg);
  o := TryExec(SqB, 'COMMIT');
  Chk('S4 REPEATABLE READ COMMIT eder (eski davranis korunur)', o.Ok, o.Msg);
  if not o.Ok then SqB.Exec('ROLLBACK');
  n := CountQ(SqB, 'SELECT COUNT(*) FROM s');
  Chk('S5 iki satir da kalici', n = 2, 'satir=' + IntToStr(n));

  { --- b) SERIALIZABLE: ayni araya girmede REDDEDILMELI --- }
  SqB.Exec('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
  SqA.Exec('BEGIN');
  SqA.Exec('INSERT INTO s (id, v) VALUES (10, ''a'')');
  SqB.Exec('BEGIN');
  o := TryExec(SqA, 'COMMIT');
  Chk('S6 A commit etti (araya giren commit)', o.Ok, o.Msg);
  o2 := TryExec(SqB, 'INSERT INTO s (id, v) VALUES (11, ''b'')');
  o := TryExec(SqB, 'COMMIT');
  Chk('S7 SERIALIZABLE araya giren commit sonrasi COMMIT REDDEDILIR',
    (not o.Ok) and o2.Ok, 'insert=' + o2.Msg + ' commit=' + o.Msg);
  Chk('S8 hata kodu ecSerializationFailure', o.Code = ecSerializationFailure,
    VDbErrorName(o.Code) + ' ' + o.Msg);
  Chk('S9 hata metni 40001 iceriyor', Pos('40001', o.Msg) > 0, o.Msg);
  o := TryExec(SqB, 'ROLLBACK');
  Chk('S10 iptal sonrasi ROLLBACK kabul', o.Ok, o.Msg);
  n := CountQ(SqB, 'SELECT COUNT(*) FROM s WHERE id = 11');
  Chk('S11 iptal edilen islem HICBIR satir yazmadi', n = 0,
    'id=11 sayisi=' + IntToStr(n));
  n := CountQ(SqB, 'SELECT COUNT(*) FROM s WHERE id = 10');
  Chk('S12 A''nin satiri korundu (veri kaybi yok)', n = 1,
    'id=10 sayisi=' + IntToStr(n));

  { --- c) cakisma yokken SERIALIZABLE commit eder --- }
  SqB.Exec('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
  SqB.Exec('BEGIN');
  SqB.Exec('INSERT INTO s (id, v) VALUES (12, ''c'')');
  o := TryExec(SqB, 'COMMIT');
  Chk('S13 cakisma yokken SERIALIZABLE COMMIT eder (yanlis abort yok)',
    o.Ok, o.Msg);

  { --- c2) okuma + yazma, cakisma yok --- }
  SqB.Exec('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
  SqB.Exec('BEGIN');
  n := CountQ(SqB, 'SELECT COUNT(*) FROM s');
  SqB.Exec('INSERT INTO s (id, v) VALUES (13, ''d'')');
  o := TryExec(SqB, 'COMMIT');
  Chk('S14 okuma+yazma, cakisma yok -> SERIALIZABLE commit',
    o.Ok and (n > 3), 'okunan=' + IntToStr(n) + ' ' + o.Msg);

  { --- d) bayrak yapiskan degil: REPEATABLE READ'a donus --- }
  SqB.Exec('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');
  SqA.Exec('BEGIN');
  SqA.Exec('INSERT INTO s (id, v) VALUES (20, ''a'')');
  SqB.Exec('BEGIN');
  o := TryExec(SqA, 'COMMIT');
  SqB.Exec('INSERT INTO s (id, v) VALUES (21, ''b'')');
  o2 := TryExec(SqB, 'COMMIT');
  Chk('S15 REPEATABLE READ''a donunce araya girme yine kabul',
    o.Ok and o2.Ok, 'a=' + o.Msg + ' b=' + o2.Msg);

  { --- e) PAYLASILAN backend (PG wire'da her baglanti ayni TVTableDb'yi
    kullanir): bir baglanticinin SERIALIZABLE secimi DIGERINI iptal
    ETMEMELIDIR. Eski tek alanli tasarimda A yanlislikla 40001 aliyordu. }
  SqC := TVSql.Create(TbA);
  SqD := TVSql.Create(TbA);
  SqE := TVSql.Create(TbA);

  SqC.Exec('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
  SqC.Exec('BEGIN');
  SqC.Exec('INSERT INTO s (id, v) VALUES (30, ''c'')');
  { E araya girer ve commit eder -> A'nin islemi sirasinda bir commit olur. }
  SqE.Exec('BEGIN');
  SqE.Exec('INSERT INTO s (id, v) VALUES (31, ''e'')');
  { D ayni backend'de SERIALIZABLE secer (eski kodda paylasilan alani
    kirletiyordu); hicbir islem baslatmaz. SIRA ONEMLI: bu secim E'nin
    BEGIN'inden SONRA gelir; eski kodda A'nin COMMIT'i bu yuzden 40001
    aliyordu. }
  SqD.Exec('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
  o := TryExec(SqE, 'COMMIT');
  Chk('S16 paylasilan backend: araya giren commit tamam', o.Ok, o.Msg);
  o := TryExec(SqC, 'COMMIT');
  Chk('S17 B''nin SERIALIZABLE secimi A''yi (READ COMMITTED) IPTAL ETMEZ',
    o.Ok, o.Msg);
  if not o.Ok then SqC.Exec('ROLLBACK');
  n := CountQ(SqC, 'SELECT COUNT(*) FROM s WHERE id = 30');
  Chk('S18 A''nin satiri yazildi (paylasilan alan sizmasi yok)', n = 1,
    'id=30 sayisi=' + IntToStr(n));

  { --- f) ayni paylasilan backend'de SERIALIZABLE oturum YINE denetlenir:
    bayrak islem bazli oldugu icin koruma kaybolmadi. }
  SqD.Exec('BEGIN');
  SqD.Exec('INSERT INTO s (id, v) VALUES (32, ''d'')');
  SqE.Exec('BEGIN');
  SqE.Exec('INSERT INTO s (id, v) VALUES (33, ''e'')');
  o := TryExec(SqE, 'COMMIT');
  o2 := TryExec(SqD, 'COMMIT');
  Chk('S19 paylasilan backend''de SERIALIZABLE yine REDDEDILIR',
    o.Ok and (not o2.Ok) and (o2.Code = ecSerializationFailure),
    'e=' + o.Msg + ' d=' + VDbErrorName(o2.Code) + ' ' + o2.Msg);
  SqD.Exec('ROLLBACK');
  n := CountQ(SqD, 'SELECT COUNT(*) FROM s WHERE id = 32');
  Chk('S20 iptal edilen serializable islem satir yazmadi', n = 0,
    'id=32 sayisi=' + IntToStr(n));

  FreeAndNil(SqE);
  FreeAndNil(SqD);
  FreeAndNil(SqC);

  FreeAndNil(SqB);
  FreeAndNil(TbB);
  B := nil;
  FreeAndNil(SqA);
  FreeAndNil(TbA);
  A := nil;
end;

{ --- B) PG tel protokolu: SQLSTATE 40001 gorunur mu --------------------- }

function BE32(AValue: LongWord): AnsiString;
begin
  SetLength(Result, 4);
  Result[1] := AnsiChar((AValue shr 24) and $FF);
  Result[2] := AnsiChar((AValue shr 16) and $FF);
  Result[3] := AnsiChar((AValue shr 8) and $FF);
  Result[4] := AnsiChar(AValue and $FF);
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
  params := 'user' + #0 + AUser + #0 + 'database' + #0 + 'seritx' + #0 + #0;
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

{ ErrorResponse govdesinden 'C' alanini (SQLSTATE) cikarir. Govde alan
  tipi + metin + #0 dizisidir. }
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

procedure CasePg;
var
  Srv: TVdbPgServer;
  PgDir, err, det: string;
  c1, c2: TVdbSocket;
  L, L2: TReply;
  portIdx: Integer;
  port: Word;
  ok: Boolean;
  n: Integer;
begin
  PgDir := GDir + 'pg' + PathDelim;
  if not DirectoryExists(PgDir) then ForceDirectories(PgDir);
  WipeDir(PgDir);

  Srv := nil;
  port := 0;
  err := '';
  for portIdx := 0 to PORT_TRIES - 1 do
  begin
    Srv := TVdbPgServer.Create(PgDir, Word(BASE_PORT + portIdx));
    if Srv.Start(err) then
    begin
      port := Word(BASE_PORT + portIdx);
      Break;
    end;
    FreeAndNil(Srv);
  end;
  Chk('P1 PG sunucusu acildi', Srv <> nil, err);
  if Srv = nil then Exit;

  try
    det := '';
    c1 := VDB_SOCK_INVALID;
    c2 := VDB_SOCK_INVALID;
    ok := ConnectStartup(port, c1, det);
    if ok then ok := ConnectStartup(port, c2, det);
    Chk('P2 iki PG baglantisi kuruldu', ok, det);
    if not ok then Exit;

    try
      ok := QExec(c1, 'CREATE TABLE p (id INTEGER PRIMARY KEY, v TEXT)', L) and
            (L.ErrText = '');
      if ok then
        ok := QExec(c1, 'INSERT INTO p VALUES (1, ''a'')', L) and
              (L.ErrText = '');
      Chk('P3 veri hazir', ok, L.ErrText);

      { SERIALIZABLE: araya giren commit -> 40001 }
      QExec(c1, 'BEGIN', L);
      QExec(c1, 'INSERT INTO p VALUES (2, ''a'')', L);
      QExec(c2, 'SET TRANSACTION ISOLATION LEVEL SERIALIZABLE', L2);
      QExec(c2, 'BEGIN', L2);
      QExec(c1, 'COMMIT', L);
      QExec(c2, 'INSERT INTO p VALUES (3, ''b'')', L2);
      ok := QExec(c2, 'COMMIT', L2);
      Chk('P4 SERIALIZABLE COMMIT ErrorResponse dondurdu',
        ok and (L2.ErrText <> ''), 'tip=' + string(L2.Types));
      Chk('P5 SQLSTATE 40001 (serialization_failure)', L2.SqlState = '40001',
        'sqlstate="' + L2.SqlState + '" ' + L2.ErrText);

      QExec(c2, 'ROLLBACK', L2);
      ok := QExec(c1, 'SELECT COUNT(*) FROM p', L) and (L.ErrText = '');
      n := -1;
      if ok and (Length(L.Rows) > 0) then n := StrToIntDef(Trim(L.Rows[0]), -1);
      Chk('P6 iptal edilen islem satir yazmadi (2 satir)', n = 2,
        'satir=' + IntToStr(n));

      { REPEATABLE READ: ayni araya girme kabul (eski davranis) }
      QExec(c1, 'BEGIN', L);
      QExec(c1, 'INSERT INTO p VALUES (4, ''a'')', L);
      QExec(c2, 'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ', L2);
      QExec(c2, 'BEGIN', L2);
      QExec(c1, 'COMMIT', L);
      QExec(c2, 'INSERT INTO p VALUES (5, ''b'')', L2);
      ok := QExec(c2, 'COMMIT', L2);
      Chk('P7 REPEATABLE READ COMMIT eder (hata yok)',
        ok and (L2.ErrText = ''), L2.ErrText);
      ok := QExec(c1, 'SELECT COUNT(*) FROM p', L) and (L.ErrText = '');
      n := -1;
      if ok and (Length(L.Rows) > 0) then n := StrToIntDef(Trim(L.Rows[0]), -1);
      Chk('P8 dort satir kalici', n = 4, 'satir=' + IntToStr(n));
    finally
      VdbSockClose(c1);
      VdbSockClose(c2);
    end;
  finally
    Srv.Stop;
    FreeAndNil(Srv);
  end;
end;

var
  base: string;

begin
  GPass := 0;
  GFail := 0;
  base := ExtractFilePath(ParamStr(0)) + 'tmp' + PathDelim;
  GDir := base;
  if not DirectoryExists(GDir) then ForceDirectories(GDir);
  WipeDir(GDir);
  GDb := GDir + 'seritx.odb';

  try
    CaseApi;
  except
    on E: Exception do
      Chk('A0 API bolumu coktu', False, E.ClassName + ': ' + E.Message);
  end;

  try
    CasePg;
  except
    on E: Exception do
      Chk('P0 PG bolumu coktu', False, E.ClassName + ': ' + E.Message);
  end;

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
