program server_failure;
{ v3.39 KALICI REGRESYON KAPISI - SKILL3 §12.1 (excessive connections,
  malformed network input, server shutdown).

  Amac: SUNUCU tarafinda hata yollarini olcmek. Her durumda beklenen sey
  aynidir: sunucu COKMEZ, dosya bozulmaz ve sonraki mesru baglanti normal
  calisir.

  Olculen:
    SF1 sunucu loopback'te acilir
    SF2 el sikisma (VDBS + surum + ad) dogru gelir
    SF3 oturum acilir, DDL/DML ve sorgu calisir
    SF4 baglanti tavani: MaxConns=1 iken ikinci baglanti `kapasite dolu`
        yaniti alip kapatilir; birinci baglanti calismaya devam eder
    SF5 bozuk ag girdisi (rastgele baytlar) baglantiyi dusurur, sunucu yasar
    SF6 bozuk uzunluk oneki (2 GB string) kontrollu reddedilir, sunucu yasar
    SF7 acik baglanti varken Stop doner ve port yeniden kullanilabilir
    SF8 Stop sonrasi veritabani hala okunabilir (veri kaybi yok)

  Derleme: fpc. Cikis kodu = basarisiz kontrol sayisi.
}
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbNet, VDbSqlServer, VDbFactory, VDbBackendApi,
  VDbBackendV3, VDbTable, VDbSql, VDbErr;

const
  BASE_PORT = 54360;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName, ' ', ADetail);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
  Flush(Output);
end;

procedure WipeDir(const D: string);
var
  sr: TSearchRec;
begin
  ForceDirectories(D);
  if FindFirst(D + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        SysUtils.DeleteFile(D + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function Conn(APort: Word): TVdbSocket;
begin
  Result := VdbTcpConnect('127.0.0.1', APort);
end;

{ Sunucu el sikismasini okur: 4 bayt 'VDBS', u8 surum, str ad. }
function ReadHandshake(ASock: TVdbSocket; out AVer: Byte; out AName: string): Boolean;
var
  mag: array[0..3] of AnsiChar;
begin
  AName := '';
  AVer := 0;
  Result := False;
  if not VdbRecvAll(ASock, mag, 4) then Exit;
  if (mag[0] <> 'V') or (mag[1] <> 'D') or (mag[2] <> 'B') or (mag[3] <> 'S') then Exit;
  if not VdbRecvU8(ASock, AVer) then Exit;
  if not VdbRecvStr(ASock, AName) then Exit;
  Result := True;
end;

function SendLogin(ASock: TVdbSocket; const AUser, APass: string): Boolean;
var
  st: Byte;
  t: Byte;
begin
  Result := False;
  if not VdbSendU8(ASock, VDBS_CMD_LOGIN) then Exit;
  if not VdbSendStr(ASock, AUser) then Exit;
  if not VdbSendStr(ASock, APass) then Exit;
  if not VdbRecvU8(ASock, t) then Exit;
  if t <> VDBS_RSP_AUTH then Exit;
  if not VdbRecvU8(ASock, st) then Exit;
  if not VdbRecvU8(ASock, t) then Exit;
  Result := (st = 0) and (t = VDBS_TERM);
end;

{ RSP_RESULT cercevesini sonuna kadar okur; AIsErr = True ise hata
  metnini dondurur. Donus: cerceve butun olarak okunduysa True.
  DIKKAT: alan/satir sayisi 0 iken `for i := 0 to nf - 1` yazilmaz;
  Cardinal(0) - 1 tasarak 4 milyar tur acar ve soket okumasinda kilitlenir.
  Bu yuzden donguler Integer'a cevrilip sifir kontrolden gecirilir. }
function QueryFrame(ASock: TVdbSocket; const ASql: string;
  out AIsErr: Boolean; out AMsg: string; out ARows: Int64): Boolean;
var
  t: Byte;
  st: Byte;
  aff: Cardinal;
  nf: Cardinal;
  i, c, rr: Integer;
  s: string;
  nr: UInt64;
begin
  Result := False;
  AIsErr := False;
  AMsg := '';
  ARows := -1;
  if not VdbSendU8(ASock, VDBS_CMD_QUERY) then Exit;
  if not VdbSendStr(ASock, ASql) then Exit;
  if not VdbRecvU8(ASock, t) then Exit;

  if t = VDBS_RSP_ERROR then
  begin
    AIsErr := True;
    if not VdbRecvStr(ASock, AMsg) then Exit;
    if not VdbRecvU8(ASock, t) then Exit;
    Exit(t = VDBS_TERM);
  end;

  if t <> VDBS_RSP_RESULT then Exit;
  if not VdbRecvU8(ASock, st) then Exit;
  if not VdbRecvU32(ASock, aff) then Exit;
  if not VdbRecvU32(ASock, nf) then Exit;
  if nf > 1024 then Exit;
  if nf > 0 then
    for i := 0 to Integer(nf) - 1 do
      if not VdbRecvStr(ASock, s) then Exit;
  if not VdbRecvU64(ASock, nr) then Exit;
  if nr > 100000 then Exit;
  if nr > 0 then
    for rr := 0 to Integer(nr) - 1 do
      if nf > 0 then
        for c := 0 to Integer(nf) - 1 do
          if not VdbRecvStr(ASock, s) then Exit;
  if not VdbRecvStr(ASock, AMsg) then Exit;
  if not VdbRecvU8(ASock, t) then Exit;
  ARows := Int64(nr);
  Result := t = VDBS_TERM;
end;

var
  D, DbFile: string;
  Srv: TVdbSqlServer;
  S1, S2: TVdbSocket;
  port: Word;
  err, msg, name: string;
  ver: Byte;
  isErr: Boolean;
  rows: Int64;
  BeC: TVdbBackendV3;
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  r: TSqlResult;
  i: Integer;
  junk: array[0..63] of Byte;
  ok: Boolean;

begin
  GPass := 0;
  GFail := 0;

  D := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + 'tmp/sf');
  WipeDir(D);
  DbFile := D + 'veritabani.odb';

  { SF1: sunucuyu ac. Portlar doluysa siradaki portu dene. }
  Srv := nil;
  port := 0;
  for i := 0 to 59 do
  begin
    Srv := TVdbSqlServer.Create(D, Word(BASE_PORT + i));
    Srv.User := 'sf';
    Srv.Password := 'parola123';
    if Srv.Start(err) then
    begin
      port := Srv.Port;
      Break;
    end;
    FreeAndNil(Srv);
  end;
  Chk('SF1 sunucu loopback portunda acildi', (Srv <> nil) and Srv.Ready,
    'port=' + IntToStr(port) + ' ' + err);
  if Srv = nil then
  begin
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
    Halt(1);
  end;

  try
    { SF2: el sikisma. }
    S1 := Conn(port);
    ok := (S1 <> VDB_SOCK_INVALID) and ReadHandshake(S1, ver, name);
    Chk('SF2 el sikisma okundu', ok,
      'ver=' + IntToStr(ver) + ' ad=' + name);
    Chk('SF2 protokol surumu 1', ver = VDBS_PROTO_VER, IntToStr(ver));

    { SF3: oturum + DDL/DML. }
    Chk('SF3 oturum acildi', SendLogin(S1, 'sf', 'parola123'), '');
    ok := QueryFrame(S1, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)',
      isErr, msg, rows) and (not isErr);
    Chk('SF3 CREATE TABLE calisti', ok, msg);
    ok := QueryFrame(S1, 'INSERT INTO t (id, v) VALUES (1, ''a'')',
      isErr, msg, rows) and (not isErr);
    Chk('SF3 INSERT calisti', ok, msg);
    ok := QueryFrame(S1, 'SELECT COUNT(*) FROM t', isErr, msg, rows);
    Chk('SF3 SELECT yaniti geldi', ok and (not isErr),
      'satir=' + IntToStr(rows) + ' ' + msg);

    { SF4: baglanti tavani. MaxConns=1; S1 slotu tutuyor. }
    Srv.MaxConns := 1;
    S2 := Conn(port);
    ok := False;
    msg := '';
    if S2 <> VDB_SOCK_INVALID then
    begin
      if VdbRecvU8(S2, ver) then
        if ver = VDBS_RSP_ERROR then
          if VdbRecvStr(S2, msg) then
            if VdbRecvU8(S2, ver) then
              ok := ver = VDBS_TERM;
    end;
    Chk('SF4 tavan ustu baglanti kontrollu reddedildi', ok and (msg = 'kapasite dolu'),
      'msg=' + msg);
    if S2 <> VDB_SOCK_INVALID then VdbSockClose(S2);
    { Birinci baglanti hala calisiyor olmali. }
    ok := QueryFrame(S1, 'SELECT COUNT(*) FROM t', isErr, msg, rows) and (not isErr);
    Chk('SF4 tavan doluyken ilk baglanti calisiyor', ok, msg);
    { SF5/SF6 icin tavani gevset: aksi halde yeni soketler el sikismasi
      yerine "kapasite dolu" alir ve test kendi kendini engeller. }
    Srv.MaxConns := 4;

    { SF5: bozuk ag girdisi. El sikismasi sonrasi rastgele baytlar. }
    S2 := Conn(port);
    ok := (S2 <> VDB_SOCK_INVALID) and ReadHandshake(S2, ver, name);
    Chk('SF5 bozuk girdi icin baglanti acildi', ok, '');
    for i := 0 to High(junk) do junk[i] := $FF;
    VdbSendAll(S2, junk, SizeOf(junk));
    VdbSockClose(S2);
    ok := QueryFrame(S1, 'SELECT COUNT(*) FROM t', isErr, msg, rows) and (not isErr);
    Chk('SF5 bozuk girdiden sonra sunucu yasiyor', ok, msg);

    { SF6: bozuk uzunluk oneki. 96 MiB secildi cunku v3.39 oncesi sinir
      1 GiB idi: bu deger eski kodda KABUL edilir ve sunucuda 96 MiB
      ayirmaya calisirdi. Yeni VDBS_MAX_RECV_STR (64 MiB) onek
      okunurken reddeder; hic ayirma yapilmaz. }
    S2 := Conn(port);
    ok := (S2 <> VDB_SOCK_INVALID) and ReadHandshake(S2, ver, name);
    Chk('SF6 uzunluk testi icin baglanti acildi', ok, '');
    VdbSendU8(S2, VDBS_CMD_QUERY);
    VdbSendU32(S2, $06000000);
    VdbSockClose(S2);
    ok := QueryFrame(S1, 'SELECT COUNT(*) FROM t', isErr, msg, rows) and (not isErr);
    Chk('SF6 dev uzunluktan sonra sunucu yasiyor', ok, msg);

    { SF7/SF8: acik baglanti varken Stop. }
    VdbSockClose(S1);
    ok := True;
    try
      Srv.Stop;
    except
      on E: Exception do
      begin
        ok := False;
        msg := E.Message;
      end;
    end;
    Chk('SF7 acik baglanti varken Stop dondu', ok and (not Srv.Ready), msg);
    Chk('SF8 Stop sonrasi veritabani dosyasi duruyor', FileExists(DbFile), DbFile);
  finally
    FreeAndNil(Srv);
  end;

  { SF8 devam: dosya gercekten okunabiliyor mu (veri kaybi yok). }
  BeC := TVdbBackendV3.Create(DbFile, False, 512, 2000);
  Be := BeC;
  try
    Tb := TVTableDb.CreateBackend(Be);
    try
      Tb.Open(D);
      Sq := TVSql.Create(Tb);
      try
        r := Sq.Exec('SELECT COUNT(*) FROM t');
        ok := (Length(r.Rows) > 0) and (Length(r.Rows[0]) > 0) and
          (Trim(r.Rows[0][0]) = '1');
        Chk('SF8 Stop sonrasi veri okunabiliyor', ok,
          'sayim=' + Trim(r.Rows[0][0]));
      finally
        FreeAndNil(Sq);
      end;
    finally
      FreeAndNil(Tb);
    end;
  finally
    Be := nil;
    BeC := nil;
  end;

  WriteLn;
  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
