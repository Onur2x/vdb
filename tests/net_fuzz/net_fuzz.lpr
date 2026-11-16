program net_fuzz;
{ v3.45 KALICI REGRESYON KAPISI - SKILL3 §12.6 genis ag fuzz'i.

  Amac: PostgreSQL tel protokolunu (TVdbPgServer) LOOPBACK uzerinde,
  TRUST modunda, BOZUK ve RASTGELE girdilerle dovmek. Her saldiridan
  sonra SUNUCUNUN HALA HIZMET VERDIGI dogrulanir: yeni bir istemci
  baslangic (startup) el sikismasini bitirip `SELECT 1` calistirabilir.

  Olculen:
    N1  startup uzunlugu 70000 ve 2^31-1 (govde gonderilmez)
    N2  kesik startup (100 bayt ilan edilir, 10 bayt gonderilir, kapat)
    N3  startup uzunlugu 0, 4, 0xFFFFFFFF
    N4  bilinmeyen protokol kodu (196609)
    N5  512 rastgele bayt
    N6  gecerli startup + rastgele tip/govdeli mesajlar
    N7  'Q' basligi 64 MB + 1 uzunlukla
    N8  'Q' uzunlugu 3 (< 4)
    N9  'Q' uzunlugu 100 ilan edilip 20 bayt gonderilip kapatma
    N10 NUL'suz sorgu, kontrol baytlari, bos 'Q'
    N11 tek baglantida 20 ardisik SSLRequest ('N' beklenir) + normal sorgu
    N12 40 kisa cop baglanti (accept/temizlik yolu)
    N13 ~120 yinelemeli deterministik mutasyon dongusu (tohumlu LCG)
    N14 bozuk genisletilmis protokol ('P','B','E','D','S')
    N15 4 is parcacigi x 8 yineleme eszamanli fuzz

  SINIRLILIK (gizlenmez): fuzz DETERMINISTIK ve tohumludur (uyku yok,
  `Random` kullanilmaz); gercek ag/kutuphane hatasi uretilmez, yalniz
  protokol katmani zorlanir. Baglanti hatasi (port tukendi vb.) FAIL
  sayilir, sessizce atlanmaz.

  Beklenen: her bozuk girdi icin sunucu COKMEZ; bir sonraki gecerli
  istemci calisir; sonuc satiri "SONUC: N PASS, M FAIL"; cikis kodu = FAIL. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbNet, VDbPgWire;

const
  BASE_PORT  = 54410;
  VALID_USER = 'netfuzz';
  PORT_TRIES = 60;

var
  GPass, GFail: Integer;
  GPort: Word;
  TestDir: string;
  FuzzState: LongWord = 20261116;

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

{ Tohumlu LCG: tekrar uretilebilir "rastgele" baytlar. }
function NextRand: LongWord;
begin
  FuzzState := FuzzState * 1103515245 + 12345;
  Result := (FuzzState shr 8) and $FFFFFF;
end;

function RandBytes(ALen: Integer): AnsiString;
var
  i: Integer;
begin
  SetLength(Result, ALen);
  for i := 1 to ALen do
    Result[i] := AnsiChar(NextRand and $FF);
end;

{ PostgreSQL tel bicimi BUYUK-endian Int32 kullanir; VDbNet yardimcilari
  kucuk-endian'dir, bu yuzden burada yerel donusum yapilir. }
function BE32(AValue: LongWord): AnsiString;
begin
  SetLength(Result, 4);
  Result[1] := AnsiChar((AValue shr 24) and $FF);
  Result[2] := AnsiChar((AValue shr 16) and $FF);
  Result[3] := AnsiChar((AValue shr 8) and $FF);
  Result[4] := AnsiChar(AValue and $FF);
end;

function SendRaw(ASock: TVdbSocket; const AData: AnsiString): Boolean;
var
  n: Integer;
begin
  n := Length(AData);
  if n = 0 then Exit(True);
  Result := VdbSendAll(ASock, AData[1], n);
end;

function RecvBody(ASock: TVdbSocket; ALen: Integer; out AData: AnsiString): Boolean;
var
  tmp: array of Byte;
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
  params := 'user' + #0 + AUser + #0 + 'database' + #0 + 'netfuzz' + #0 + #0;
  Result := BE32(4 + 4 + Length(params)) + BE32(196608) + params;
end;

function SendMsg(ASock: TVdbSocket; ATyp: AnsiChar; const ABody: AnsiString): Boolean;
begin
  Result := SendRaw(ASock, ATyp + BE32(4 + Length(ABody)) + ABody);
end;

{ Sunucudan 'Z' (ReadyForQuery) gelene kadar mesajlari okur. }
function ReadUntilReady(ASock: TVdbSocket; out ASawErr: Boolean;
  out AMsgs: Integer; out ASawData: Boolean): Boolean;
var
  t: Byte;
  len: LongWord;
  body: AnsiString;
  guard: Integer;
begin
  Result := False;
  ASawErr := False;
  AMsgs := 0;
  ASawData := False;
  for guard := 1 to 600 do
  begin
    if not VdbRecvU8(ASock, t) then Exit;
    if not Recv32BE(ASock, len) then Exit;
    if (len < 4) or (len > 16 * 1024 * 1024) then Exit;
    if not RecvBody(ASock, Integer(len) - 4, body) then Exit;
    Inc(AMsgs);
    if t = Ord('E') then ASawErr := True;
    if (t = Ord('D')) or (t = Ord('C')) or (t = Ord('T')) then ASawData := True;
    if t = Ord('Z') then Exit(True);
  end;
end;

{ ORACLE: yeni bir istemci startup yapip `SELECT 1` calistirabiliyor mu? }
function ValidClient(APort: Word; out ADetail: string): Boolean;
var
  s: TVdbSocket;
  sawErr, sawData: Boolean;
  msgs: Integer;
begin
  Result := False;
  ADetail := '';
  s := VdbTcpConnect('127.0.0.1', APort);
  if s = VDB_SOCK_INVALID then
  begin
    ADetail := 'baglanti kurulamadi';
    Exit;
  end;
  try
    if not SendRaw(s, StartupPacket(VALID_USER)) then
    begin
      ADetail := 'startup gonderilemedi';
      Exit;
    end;
    if not ReadUntilReady(s, sawErr, msgs, sawData) then
    begin
      ADetail := 'startup yaniti okunamadi';
      Exit;
    end;
    if sawErr then
    begin
      ADetail := 'startup E yaniti';
      Exit;
    end;
    if not SendMsg(s, 'Q', 'SELECT 1' + #0) then
    begin
      ADetail := 'sorgu gonderilemedi';
      Exit;
    end;
    if not ReadUntilReady(s, sawErr, msgs, sawData) then
    begin
      ADetail := 'sorgu yaniti okunamadi';
      Exit;
    end;
    if sawErr then
    begin
      ADetail := 'sorgu E yaniti';
      Exit;
    end;
    if (not sawData) or (msgs < 2) then
    begin
      ADetail := 'sorgu verisi yok (msgs=' + IntToStr(msgs) + ')';
      Exit;
    end;
    Result := True;
  finally
    VdbSockClose(s);
  end;
end;

procedure ChkAlive(const AAfter: string);
var
  d: string;
begin
  Chk(AAfter + ': sunucu hala hizmet veriyor', ValidClient(GPort, d), d);
end;

{ Yeni baglanti acar, verilen baytlari yollar ve kapatir. Donus: baglanti
  kurulabildi mi (kurulamadiysa test anlamsiz olurdu -> FAIL). }
function AttackBytes(const AData: AnsiString): Boolean;
var
  s: TVdbSocket;
begin
  Result := False;
  s := VdbTcpConnect('127.0.0.1', GPort);
  if s = VDB_SOCK_INVALID then Exit;
  try
    SendRaw(s, AData);
    Result := True;
  finally
    VdbSockClose(s);
  end;
end;

function FreshDir(const AName: string): string;
var
  d: string;
  sr: TSearchRec;
  found: Boolean;
begin
  d := TestDir + PathDelim + 'nf_' + AName;
  Result := IncludeTrailingPathDelimiter(d);
  found := FindFirst(IncludeTrailingPathDelimiter(d) + '*', faAnyFile, sr) = 0;
  if found then
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

type
  { N15: eszamanli fuzz. Her is parcacigi KENDI tohumunu kullanir; ortak
    durum yoktur, bu yuzden kilit gerekmez. }
  TFuzzThread = class(TThread)
  private
    FPort: Word;
    FIter: Integer;
    FSeed: LongWord;
    FConnected: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Word; AIter: Integer; ASeed: LongWord);
    property Connected: Integer read FConnected;
  end;

constructor TFuzzThread.Create(APort: Word; AIter: Integer; ASeed: LongWord);
begin
  FPort := APort;
  FIter := AIter;
  FSeed := ASeed;
  FConnected := 0;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TFuzzThread.Execute;
var
  i, j, n: Integer;
  s: TVdbSocket;
  buf: AnsiString;
begin
  for i := 1 to FIter do
  begin
    s := VdbTcpConnect('127.0.0.1', FPort);
    if s = VDB_SOCK_INVALID then Continue;
    Inc(FConnected);
    try
      FSeed := FSeed * 1103515245 + 12345;
      n := (FSeed shr 18) mod 200;
      SetLength(buf, n);
      for j := 1 to n do
      begin
        FSeed := FSeed * 1103515245 + 12345;
        buf[j] := AnsiChar(FSeed shr 17);
      end;
      SendRaw(s, buf);
    finally
      VdbSockClose(s);
    end;
  end;
end;

var
  Srv: TVdbPgServer;
  Dir, err, detail: string;
  started: Boolean;
  i, j, k, msgs: Integer;
  s: TVdbSocket;
  ok, ready, sawErr, sawData: Boolean;
  len: LongWord;
  body, mut: AnsiString;
  b1: Byte;
  threads: array[0..3] of TFuzzThread;
  connTotal: Integer;
  nOn: Integer;

begin
  GPass := 0;
  GFail := 0;
  TestDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp';
  ForceDirectories(TestDir);
  Dir := FreshDir('net_fuzz');

  Srv := nil;
  started := False;
  GPort := 0;
  err := '';
  for i := 0 to PORT_TRIES - 1 do
  begin
    Srv := TVdbPgServer.Create(Dir, Word(BASE_PORT + i));
    Srv.BindHost := '127.0.0.1';
    { Kapasite bu kapinin konusu DEGIL (SF4 onu olcer); 256 ile "baglanti
      doldu" yanlis FAIL'i elenir. }
    Srv.MaxConns := 256;
    if Srv.Start(err) then
    begin
      GPort := Srv.Port;
      started := True;
      Break;
    end;
    FreeAndNil(Srv);
  end;
  Chk('N0 sunucu loopback uzerinde basladi', started, err);
  if not started then
  begin
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  try
    { --- N1: asiri buyuk startup uzunlugu (govde gonderilmez) --- }
    Chk('N1a startup uzunlugu 70000 reddedildi',
      AttackBytes(BE32(70000)), 'baglanti kurulamadi');
    ChkAlive('N1a');
    Chk('N1b startup uzunlugu 2^31-1 reddedildi',
      AttackBytes(BE32($7FFFFFFF)), 'baglanti kurulamadi');
    ChkAlive('N1b');

    { --- N2: kesik startup --- }
    ok := False;
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
    begin
      ok := SendRaw(s, BE32(100) + '0123456789');
      VdbSockClose(s);
    end;
    Chk('N2 kesik startup (100 ilan, 10 bayt)', ok, 'gonderilemedi');
    ChkAlive('N2');

    { --- N3: gecersiz startup uzunluklari --- }
    ok := AttackBytes(BE32(0)) and AttackBytes(BE32(4)) and
          AttackBytes(BE32($FFFFFFFF));
    Chk('N3 startup uzunluklari 0 / 4 / 0xFFFFFFFF', ok, 'gonderilemedi');
    ChkAlive('N3');

    { --- N4: bilinmeyen protokol kodu --- }
    Chk('N4 bilinmeyen protokol kodu 196609',
      AttackBytes(BE32(8) + BE32(196609)), 'gonderilemedi');
    ChkAlive('N4');

    { --- N5: tamamen rastgele 512 bayt --- }
    Chk('N5 512 rastgele bayt',
      AttackBytes(RandBytes(512)), 'gonderilemedi');
    ChkAlive('N5');

    { --- N6: gecerli startup + rastgele mesajlar --- }
    ready := False;
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
    begin
      try
        if SendRaw(s, StartupPacket(VALID_USER)) and
           ReadUntilReady(s, sawErr, msgs, sawData) and (not sawErr) then
        begin
          ready := True;
          for k := 1 to 30 do
          begin
            len := 4 + (NextRand mod 300);
            SetLength(body, len - 4);
            for j := 1 to Length(body) do
              body[j] := AnsiChar(NextRand and $FF);
            if not SendMsg(s, AnsiChar(Byte(NextRand)), body) then Break;
          end;
        end;
      finally
        VdbSockClose(s);
      end;
    end;
    Chk('N6 gecerli startup + 30 rastgele mesaj', ready, 'el sikismasi olmadi');
    ChkAlive('N6');

    { --- N7: 'Q' basligi 64 MB + 1 --- }
    ok := False;
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
    begin
      try
        ok := SendRaw(s, 'Q' + BE32(64 * 1024 * 1024 + 1));
      finally
        VdbSockClose(s);
      end;
    end;
    Chk('N7 Q uzunlugu 64MB+1', ok, 'gonderilemedi');
    ChkAlive('N7');

    { --- N8: 'Q' uzunlugu 3 (< 4) --- }
    Chk('N8 Q uzunlugu 3', AttackBytes('Q' + BE32(3)), 'gonderilemedi');
    ChkAlive('N8');

    { --- N9: 'Q' ilan edilen uzunluktan az govde --- }
    ok := False;
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
    begin
      try
        ok := SendRaw(s, 'Q' + BE32(100) + StringOfChar('x', 20));
      finally
        VdbSockClose(s);
      end;
    end;
    Chk('N9 kesik Q govdesi (100 ilan, 20 bayt)', ok, 'gonderilemedi');
    ChkAlive('N9');

    { --- N10: NUL'suz sorgu, kontrol baytlari, bos sorgu --- }
    ok := False;
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
    begin
      try
        if SendRaw(s, StartupPacket(VALID_USER)) and
           ReadUntilReady(s, sawErr, msgs, sawData) and (not sawErr) then
        begin
          ok := SendMsg(s, 'Q', 'SELECT 1');            // NUL yok
          ok := ok and SendMsg(s, 'Q', #1#27#0#7);      // kontrol baytlari
          ok := ok and SendMsg(s, 'Q', '');             // bos sorgu
          ok := ok and ReadUntilReady(s, sawErr, msgs, sawData);
        end;
      finally
        VdbSockClose(s);
      end;
    end;
    Chk('N10 NULsuz / kontrol baytli / bos sorgu', ok, 'yanit alinamadi');
    ChkAlive('N10');

    { --- N11: tek baglantida 20 SSLRequest, ardindan normal akis --- }
    ok := False;
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
    begin
      try
        ok := True;
        for k := 1 to 20 do
        begin
          if not SendRaw(s, BE32(8) + BE32(80877103)) then
          begin
            ok := False;
            Break;
          end;
          if not VdbRecvU8(s, b1) then
          begin
            ok := False;
            Break;
          end;
          if b1 <> Ord('N') then ok := False;
        end;
        if ok then
        begin
          ok := SendRaw(s, StartupPacket(VALID_USER)) and
                ReadUntilReady(s, sawErr, msgs, sawData) and (not sawErr) and
                SendMsg(s, 'Q', 'SELECT 1' + #0) and
                ReadUntilReady(s, sawErr, msgs, sawData) and (not sawErr);
        end;
      finally
        VdbSockClose(s);
      end;
    end;
    Chk('N11 20 ardisik SSLRequest + normal sorgu', ok, 'N veya eldiven yok');
    ChkAlive('N11');

    { --- N12: 40 kisa cop baglanti --- }
    connTotal := 0;
    for k := 1 to 40 do
      if AttackBytes('zzz') then Inc(connTotal);
    Chk('N12 40 kisa cop baglanti', connTotal = 40,
      'baglanti=' + IntToStr(connTotal));
    ChkAlive('N12');

    { --- N13: deterministik mutasyon dongusu --- }
    connTotal := 0;
    for k := 1 to 120 do
    begin
      mut := '';
      if (k mod 3) <> 0 then mut := StartupPacket(VALID_USER);
      mut := mut + RandBytes(Integer(NextRand mod 200));
      if AttackBytes(mut) then Inc(connTotal);
      if (k mod 20) = 0 then ChkAlive('N13 dongu ' + IntToStr(k));
    end;
    Chk('N13 120 yinelemeli mutasyon', connTotal >= 100,
      'baglanti=' + IntToStr(connTotal));
    ChkAlive('N13');

    { --- N14: bozuk genisletilmis protokol --- }
    ok := False;
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
    begin
      try
        if SendRaw(s, StartupPacket(VALID_USER)) and
           ReadUntilReady(s, sawErr, msgs, sawData) and (not sawErr) then
        begin
          ok := True;
          // 'P' bos govde. Genisletilmis protokolde hata sonrasi sunucu
          // yalnizca Sync ('S') bekler; bu yuzden her bozuk mesajdan SONRA
          // 'S' gonderilir ve 'Z' (ReadyForQuery) beklenir.
          ok := ok and SendMsg(s, 'P', '') and SendMsg(s, 'S', '') and
                ReadUntilReady(s, sawErr, msgs, sawData);
          // 'P' 2 parametre OID'i ilan edip yalniz 4 bayt gonderme
          ok := ok and SendMsg(s, 'P', #0'SELECT 1'#0#0#2#0#0#0#0#0) and
                SendMsg(s, 'S', '') and
                ReadUntilReady(s, sawErr, msgs, sawData);
          // 'B' olmayan prepared statement'a baglanma
          ok := ok and SendMsg(s, 'B', #0'yokboyle'#0#0#0#0#0#0#0) and
                SendMsg(s, 'S', '') and
                ReadUntilReady(s, sawErr, msgs, sawData);
          // 'E' / 'D' bos
          ok := ok and SendMsg(s, 'E', '') and SendMsg(s, 'D', '') and
                SendMsg(s, 'S', '') and
                ReadUntilReady(s, sawErr, msgs, sawData);
          // 'S' ile toparlan; ardindan ayni baglantida gercek sorgu
          ok := ok and SendMsg(s, 'S', '') and
                ReadUntilReady(s, sawErr, msgs, sawData) and
                SendMsg(s, 'Q', 'SELECT 1' + #0) and
                ReadUntilReady(s, sawErr, msgs, sawData) and (not sawErr);
        end;
      finally
        VdbSockClose(s);
      end;
    end;
    Chk('N14 bozuk genisletilmis protokol + toparlanma', ok, 'akis bozuldu');
    ChkAlive('N14');

    { --- N15: eszamanli fuzz (4 is parcacigi x 8 yineleme) --- }
    for i := 0 to 3 do
      threads[i] := TFuzzThread.Create(GPort, 8, LongWord(777 + i * 13));
    nOn := 0;
    for i := 0 to 3 do
    begin
      threads[i].WaitFor;
      nOn := nOn + threads[i].Connected;
      threads[i].Free;
    end;
    Chk('N15 4 is parcacigi x 8 eszamanli fuzz', nOn >= 24,
      'baglanti=' + IntToStr(nOn));
    ChkAlive('N15');

    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  finally
    Srv.Stop;
    FreeAndNil(Srv);
  end;
  Halt(GFail);
end.
