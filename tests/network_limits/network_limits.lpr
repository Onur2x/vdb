program network_limits;
{ v3.56 KALICI REGRESYON KAPISI - Sprint E (SKILL3 7.1 + 7.2 + 7.3).

  Amac: PostgreSQL tel protokolunde (TVdbPgServer) AG KAYNAK SINIRLARINI
  loopback uzerinde, TRUST modunda olcmek. Her sinir asimindan sonra
  SUNUCUNUN HALA HIZMET VERDIGI dogrulanir.

  Olculen:
    NL0  sunucu basladi, varsayilan sinirlar (64 MiB mesaj, 30 s zaman
         asimi, 256 MiB COPY) korunuyor
    NL1  YAVAS/SAHTE ISTEMCI: tam olmayan startup gonderip bekleyen
         istemci, okuma zaman asimi ile DUSURULUR; MaxConns=1 iken bile
         sonraki gecerli istemci baglanabilir (onceden slot kalici
         kilitleniyordu)
    NL2  zaman asimi sonrasi baglanti sayaci (ConnCount) sifira doner
    NL3  kimlik dogrulamasindan SONRA yarim mesaj: sunucu soketi kapatir
    NL4  mesaj boyutu siniri: MaxMessageBytes asilinca KONTROLLU hata
         (ErrorResponse) doner; onceden sessizce baglanti dusuruluyordu
    NL5  COPY toplam boyut siniri: sinir asilinca hata, tablo degismez,
         gecici dosya kalmaz
    NL6  kucuk COPY sinirlarla calismaya devam eder (regresyon korumasi)
    NL7  Stop, yarim baglanti acikken 5 s icinde doner ve ConnCount=0
    NL8  zaman asimi KURULAMAZSA baglanti hic sunulmaz (fail-closed):
         kabul dongusu soketi protokol mesaji gondermeden kapatir ve
         baglanti slotu tuketilmez; kanca kaldirilinca sunucu normale doner

  SINIRLILIK (gizlenmez): yalniz protokol katmani olculur; gercek ag
  gecikmesi uretilmez. TLS el sikismasi zamani ayni SO_RCVTIMEO
  mekanizmasini kullanir ama burada ayrica olculmez.

  Sonuc satiri "SONUC: N PASS, M FAIL"; cikis kodu FAIL sayisidir. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbNet, VDbPgWire;

const
  BASE_PORT  = 54520;
  TEST_USER  = 'netlim';
  PORT_TRIES = 40;
  SLOW_WAIT  = 6000;   // ms: yavas istemci dusene kadar beklenen ust sinir
  SHORT_TO   = 700;    // ms: testte kullanilan okuma zaman asimi

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

function NowMs: QWord;
begin
  Result := GetTickCount64;
end;

{ PostgreSQL tel bicimi BUYUK-endian Int32 kullanir. }
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
  params := 'user' + #0 + AUser + #0 + 'database' + #0 + 'netlim' + #0 + #0;
  Result := BE32(4 + 4 + Length(params)) + BE32(196608) + params;
end;

function SendMsg(ASock: TVdbSocket; ATyp: AnsiChar; const ABody: AnsiString): Boolean;
begin
  Result := SendRaw(ASock, ATyp + BE32(4 + Length(ABody)) + ABody);
end;

{ ReadyForQuery ('Z') gelene kadar okur. Hata metinleri ve COPY-In yaniti
  ('G') da toplanir; boylece sinir mesaji icerik olarak dogrulanabilir. }
function ReadToReady(ASock: TVdbSocket; out AErrText: string;
  out ASawData, ASawCopyIn: Boolean; out AMsgs: Integer): Boolean;
var
  t: Byte;
  len: LongWord;
  body: AnsiString;
  guard: Integer;
begin
  Result := False;
  AErrText := '';
  ASawData := False;
  ASawCopyIn := False;
  AMsgs := 0;
  for guard := 1 to 2000 do
  begin
    if not VdbRecvU8(ASock, t) then Exit;
    if not Recv32BE(ASock, len) then Exit;
    if (len < 4) or (len > 32 * 1024 * 1024) then Exit;
    if not RecvBody(ASock, Integer(len) - 4, body) then Exit;
    Inc(AMsgs);
    if t = Ord('E') then
    begin
      { ErrorResponse: alanlar 'kod + metin + #0'. Metni kabaca al. }
      if Length(body) > 1 then AErrText := AErrText + Copy(body, 2, Length(body));
    end;
    if (t = Ord('D')) or (t = Ord('C')) or (t = Ord('T')) then ASawData := True;
    if t = Ord('G') then
    begin
      { COPY-In yaniti: bundan sonra 'Z' GELMEZ (istemci veri gonderecek).
        Bu yuzden burada durmak zorunlu; aksi halde gate kendi kendini
        kilitlerdi. }
      ASawCopyIn := True;
      Exit(True);
    end;
    if t = Ord('Z') then Exit(True);
  end;
end;

function ConnectStartup(APort: Word; out ASock: TVdbSocket;
  out ADetail: string): Boolean;
var
  errText: string;
  sawData, sawCopy: Boolean;
  msgs: Integer;
begin
  Result := False;
  ADetail := '';
  ASock := VdbTcpConnect('127.0.0.1', APort);
  if ASock = VDB_SOCK_INVALID then
  begin
    ADetail := 'baglanti kurulamadi';
    Exit;
  end;
  if not SendRaw(ASock, StartupPacket(TEST_USER)) then
  begin
    ADetail := 'startup gonderilemedi';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  if not ReadToReady(ASock, errText, sawData, sawCopy, msgs) then
  begin
    ADetail := 'startup yaniti okunamadi';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  if errText <> '' then
  begin
    ADetail := 'startup E yaniti';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  Result := True;
end;

{ ORACLE: yeni istemci startup + `SELECT 1` yapabiliyor mu? }
function ValidClient(APort: Word; out ADetail: string): Boolean;
var
  s: TVdbSocket;
  errText: string;
  sawData, sawCopy: Boolean;
  msgs: Integer;
begin
  Result := False;
  ADetail := '';
  if not ConnectStartup(APort, s, ADetail) then Exit;
  try
    if not SendMsg(s, 'Q', 'SELECT 1' + #0) then
    begin
      ADetail := 'sorgu gonderilemedi';
      Exit;
    end;
    if not ReadToReady(s, errText, sawData, sawCopy, msgs) then
    begin
      ADetail := 'sorgu yaniti okunamadi';
      Exit;
    end;
    if errText <> '' then
    begin
      ADetail := 'sorgu E yaniti';
      Exit;
    end;
    if not sawData then
    begin
      ADetail := 'sorgu verisi yok (msgs=' + IntToStr(msgs) + ')';
      Exit;
    end;
    Result := True;
  finally
    VdbSockClose(s);
  end;
end;

{ v3.60 / SKILL5 9.1: zaman asimi kurulumunu BASARISIZ gibi gosteren
  kanca. Gercek bir sokette setsockopt(SO_RCVTIMEO) hatasi tasinabilir
  sekilde tetiklenemedigi icin kabul dongusunun fail-closed davranisi
  boyle olculur. }
function FailTimeouts(ASock: TVdbSocket; ARecvMs, ASendMs: Integer): Boolean;
begin
  Result := False;
end;

{ Basit sorgu calistirir; hata metnini ve ilk DataRow degerini doner. }
function RunSql(APort: Word; const ASql: string; out AValue: string;
  out AErrText: string): Boolean;
var
  s: TVdbSocket;
  sawData, sawCopy: Boolean;
  msgs: Integer;
  t: Byte;
  len: LongWord;
  body: AnsiString;
  p: Integer;
  ncols: Integer;
  clen: LongWord;
  d: string;
begin
  Result := False;
  AValue := '';
  AErrText := '';
  if not ConnectStartup(APort, s, d) then
  begin
    AErrText := 'baglanti: ' + d;
    Exit;
  end;
  try
    if not SendMsg(s, 'Q', ASql + #0) then
    begin
      AErrText := 'gonderilemedi';
      Exit;
    end;
    for msgs := 1 to 2000 do
    begin
      if not VdbRecvU8(s, t) then Exit;
      if not Recv32BE(s, len) then Exit;
      if (len < 4) or (len > 32 * 1024 * 1024) then Exit;
      if not RecvBody(s, Integer(len) - 4, body) then Exit;
      if t = Ord('E') then
        AErrText := AErrText + Copy(body, 2, Length(body));
      if (t = Ord('D')) and (AValue = '') then
      begin
        { DataRow: int16 kolon sayisi, sonra her kolon icin int32 uzunluk. }
        if Length(body) >= 6 then
        begin
          ncols := (Ord(body[1]) shl 8) or Ord(body[2]);
          if ncols >= 1 then
          begin
            p := 3;
            clen := (LongWord(Ord(body[p])) shl 24) or
                    (LongWord(Ord(body[p + 1])) shl 16) or
                    (LongWord(Ord(body[p + 2])) shl 8) or
                    LongWord(Ord(body[p + 3]));
            if clen < $80000000 then
              AValue := Copy(body, p + 4, clen);
          end;
        end;
      end;
      if t = Ord('Z') then
      begin
        Result := True;
        Exit;
      end;
    end;
  finally
    VdbSockClose(s);
  end;
end;

function PgCopyTempCount: Integer;
var
  sr: TSearchRec;
  d: string;
begin
  Result := 0;
  d := IncludeTrailingPathDelimiter(GetTempDir);
  if FindFirst(d + 'vdb_pgcopy_*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) = 0 then Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function FreshDir(const AName: string): string;
var
  d: string;
  sr: TSearchRec;
begin
  d := TestDir + PathDelim + 'nl_' + AName;
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
  Dir, err, detail, val, etxt: string;
  started: Boolean;
  i, msgs: Integer;
  s, sStall, s8: TVdbSocket;
  nl8buf: Byte;
  nl8got: Integer;
  sawData, sawCopy: Boolean;
  t0: QWord;
  elapsed: QWord;
  ok, recovered: Boolean;
  payload, chunk: AnsiString;
  line: AnsiString;
  bt: Byte;
  tmpBefore, tmpAfter: Integer;
  connZero: Boolean;

begin
  GPass := 0;
  GFail := 0;
  TestDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp';
  ForceDirectories(TestDir);
  Dir := FreshDir('network_limits');

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
  Chk('NL0 sunucu loopback uzerinde basladi', started, err);
  if not started then
  begin
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  Chk('NL0 varsayilan mesaj siniri 64 MiB',
    Srv.MaxMessageBytes = 64 * 1024 * 1024,
    IntToStr(Srv.MaxMessageBytes));
  Chk('NL0 varsayilan okuma zaman asimi 30 s', Srv.ReadTimeoutMs = 30000,
    IntToStr(Srv.ReadTimeoutMs));
  Chk('NL0 varsayilan COPY toplam siniri 256 MiB',
    Srv.CopyMaxBytes = Int64(256) * 1024 * 1024, IntToStr(Srv.CopyMaxBytes));

  ok := RunSql(GPort, 'CREATE TABLE nl(a INTEGER, b TEXT)', val, etxt);
  Chk('NL0 tablo olusturuldu', ok and (etxt = ''), etxt);

  { --- NL1: yavas istemci + slot kurtarma ------------------------------ }
  Srv.MaxConns := 1;
  Srv.ReadTimeoutMs := SHORT_TO;
  sStall := VdbTcpConnect('127.0.0.1', GPort);
  if sStall = VDB_SOCK_INVALID then
    Chk('NL1 yavas istemci baglandi', False, 'baglanti kurulamadi')
  else
  begin
    { 100 bayt ilan edip yalniz 4 bayt gonderir, sonra HICBIR SEY
      gondermez: eski kodda bu soket slotu sonsuza kadar tutuyordu. }
    SendRaw(sStall, BE32(100) + BE32(196608));
    t0 := NowMs;
    recovered := False;
    while (NowMs - t0) < SLOW_WAIT do
    begin
      if ValidClient(GPort, detail) then
      begin
        recovered := True;
        Break;
      end;
      Sleep(150);
    end;
    elapsed := NowMs - t0;
    Chk('NL1 yavas istemci zaman asimiyla dusuruldu, yeni istemci girdi',
      recovered, 'gecen ms=' + IntToStr(elapsed) + ' ' + detail);
    Chk('NL1 kurtarma 6 s icinde', elapsed < SLOW_WAIT,
      IntToStr(elapsed) + ' ms');
    VdbSockClose(sStall);
  end;

  { --- NL2: ConnCount sifira doner ------------------------------------ }
  connZero := False;
  t0 := NowMs;
  while (NowMs - t0) < 4000 do
  begin
    if Srv.ConnCount = 0 then
    begin
      connZero := True;
      Break;
    end;
    Sleep(100);
  end;
  Chk('NL2 zaman asimi sonrasi baglanti sayaci sifir', connZero,
    'ConnCount=' + IntToStr(Srv.ConnCount));

  Srv.MaxConns := 8;
  { NL3 de kisa zaman asimi kullanir: aksi halde sunucu 30 s bekler ve
    istemci kendi 5 s zaman asimiyla doner; bu "kapatti" kaniti olmaz. }
  Srv.ReadTimeoutMs := SHORT_TO;

  { --- NL3: kimlik dogrulamasindan sonra yarim mesaj ------------------- }
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL3 istemci baglandi', False, detail)
  else
  begin
    VdbSockSetTimeouts(s, 5000, 5000);
    { 'Q' basligi 100 bayt ilan eder, 10 bayt gonderilir; govde eksik. }
    SendRaw(s, 'Q' + BE32(100) + 'SELECT 1  ');
    t0 := NowMs;
    ok := VdbRecvU8(s, bt);
    elapsed := NowMs - t0;
    { Sunucu zaman asiminda soketi kapatir -> okuma 0/False doner. }
    Chk('NL3 yarim mesaj sonrasi sunucu soketi kapatti', (not ok),
      'gecen ms=' + IntToStr(elapsed));
    Chk('NL3 kapatma 4 s icinde', elapsed < 4000, IntToStr(elapsed) + ' ms');
    VdbSockClose(s);
  end;
  Srv.ReadTimeoutMs := 30000;

  { --- NL4: mesaj boyutu siniri --------------------------------------- }
  Srv.MaxMessageBytes := 4096;
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL4 istemci baglandi', False, detail)
  else
  begin
    payload := 'SELECT 1';
    while Length(payload) < 5000 do payload := payload + ' ';
    SendMsg(s, 'Q', payload + #0);
    ok := ReadToReady(s, etxt, sawData, sawCopy, msgs);
    Chk('NL4 sinir asilinca kontrollu hata dondu',
      (not ok) or (Pos('mesaj boyutu siniri asildi', etxt) > 0),
      'ok=' + BoolToStr(ok, True) + ' msgs=' + IntToStr(msgs));
    VdbSockClose(s);
  end;
  Chk('NL4 sinir asimindan sonra sunucu ayakta', ValidClient(GPort, detail), detail);
  Srv.MaxMessageBytes := 64 * 1024 * 1024;

  { --- NL5: COPY toplam boyut siniri ---------------------------------- }
  Srv.CopyMaxBytes := 4096;
  tmpBefore := PgCopyTempCount;
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL5 istemci baglandi', False, detail)
  else
  begin
    SendMsg(s, 'Q', 'COPY nl FROM STDIN' + #0);
    ok := ReadToReady(s, etxt, sawData, sawCopy, msgs);
    Chk('NL5 COPY-In yaniti alindi', sawCopy, 'msgs=' + IntToStr(msgs));
    if sawCopy then
    begin
      chunk := StringOfChar('x', 1024);
      for i := 1 to 8 do
        SendRaw(s, 'd' + BE32(4 + Length(chunk)) + chunk);
      t0 := NowMs;
      ok := ReadToReady(s, etxt, sawData, sawCopy, msgs);
      elapsed := NowMs - t0;
      Chk('NL5 toplam boyut siniri asilinca hata dondu',
        (not ok) or (Pos('COPY toplam boyut siniri asildi', etxt) > 0),
        'ok=' + BoolToStr(ok, True) + ' msgs=' + IntToStr(msgs));
      Chk('NL5 hata 5 s icinde', elapsed < 5000, IntToStr(elapsed) + ' ms');
    end;
    VdbSockClose(s);
  end;
  ok := RunSql(GPort, 'SELECT COUNT(*) FROM nl', val, etxt);
  Chk('NL5 reddedilen COPY tabloyu degistirmedi', ok and (val = '0'),
    'val=' + val + ' err=' + etxt);
  tmpAfter := PgCopyTempCount;
  Chk('NL5 gecici dosya kalmadi', tmpAfter <= tmpBefore,
    'once=' + IntToStr(tmpBefore) + ' sonra=' + IntToStr(tmpAfter));
  Chk('NL5 sinir asimindan sonra sunucu ayakta', ValidClient(GPort, detail), detail);

  { --- NL6: kucuk COPY hala calisir (regresyon korumasi) --------------- }
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL6 istemci baglandi', False, detail)
  else
  begin
    SendMsg(s, 'Q', 'COPY nl FROM STDIN' + #0);
    ok := ReadToReady(s, etxt, sawData, sawCopy, msgs);
    if sawCopy then
    begin
      { NOT (gizlenmez): motorun COPY varsayilan bicimi csv'dir (ayirici
        ','). PostgreSQL'de COPY FROM STDIN varsayilani text (tab) olur;
        bu ONCEDEN VAR OLAN bir protokol farkidir, Sprint E kapsaminda
        degistirilmedi. Bu yuzden gate virgullu satir gonderir. }
      line := '7' + ',' + 'yedi' + #10;
      SendRaw(s, 'd' + BE32(4 + Length(line)) + line);
      SendMsg(s, 'c', '');
      ok := ReadToReady(s, etxt, sawData, sawCopy, msgs);
      Chk('NL6 kucuk COPY basarili', ok and (etxt = ''), etxt);
    end
    else
      Chk('NL6 kucuk COPY basarili', False, 'COPY-In yaniti yok');
    VdbSockClose(s);
  end;
  ok := RunSql(GPort, 'SELECT COUNT(*) FROM nl', val, etxt);
  Chk('NL6 kucuk COPY satiri yazildi', ok and (val = '1'),
    'val=' + val + ' err=' + etxt);

  { --- NL8: zaman asimi kurulamazsa baglanti SUNULMAZ (fail-closed) ---- }
  Srv.SockTimeoutFunc := @FailTimeouts;
  s8 := VdbTcpConnect('127.0.0.1', GPort);
  if s8 = VDB_SOCK_INVALID then
    Chk('NL8 istemci baglandi', False, 'baglanti kurulamadi')
  else
  begin
    VdbSockSetTimeouts(s8, SHORT_TO, SHORT_TO);
    t0 := NowMs;
    { Tek bayt bile okunmamali: sunucu protokol mesaji gondermeden kapatir. }
    nl8got := VdbRecvSome(s8, nl8buf, 1);
    elapsed := NowMs - t0;
    Chk('NL8 zaman asimi kurulamazsa baglanti SUNULMADI (soket kapandi)',
      nl8got <= 0, 'rv=' + IntToStr(nl8got));
    Chk('NL8 kapatma 3 s icinde', elapsed < 3000, IntToStr(elapsed) + ' ms');
    VdbSockClose(s8);
  end;
  Chk('NL8 basarisiz baglanti slot tuketmedi', Srv.ConnCount = 0,
    'ConnCount=' + IntToStr(Srv.ConnCount));
  Srv.SockTimeoutFunc := nil;
  ok := ValidClient(GPort, etxt);
  Chk('NL8 kanca kaldirilinca sunucu normal istemciyi kabul ediyor',
    ok, etxt);

  { --- NL7: Stop yarim baglanti acikken doner -------------------------- }
  sStall := VdbTcpConnect('127.0.0.1', GPort);
  if sStall <> VDB_SOCK_INVALID then
    SendRaw(sStall, BE32(200) + BE32(196608));
  t0 := NowMs;
  Srv.Stop;
  elapsed := NowMs - t0;
  Chk('NL7 Stop yarim baglanti acikken 5 s icinde dondu', elapsed < 5000,
    IntToStr(elapsed) + ' ms');
  Chk('NL7 Stop sonrasi baglanti sayaci sifir', Srv.ConnCount = 0,
    'ConnCount=' + IntToStr(Srv.ConnCount));
  if sStall <> VDB_SOCK_INVALID then VdbSockClose(sStall);
  FreeAndNil(Srv);

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
