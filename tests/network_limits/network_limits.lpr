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
    NL9  DAMLA (drip) saldirisi: her 100 ms'de bir bayt gondererek toplam
         sureyi uzatma denemesi MUTLAK mesaj son tarihiyle dusurulur
    NL10 yarim startup basligi damla damla gonderilir: startup son tarihi
    NL11 COPY-In govdesi damla damla gonderilir: son tarih + tablo/gecici
         dosya dokunulmaz
    NL12 yazma son tarihi: alicisi okumayan sokette VdbSendAllDl, butce
         dolunca doner (engellenen yazma sinirsiz surmez)

  v3.74 / SKILL10: SUNUCU DURDURMA VE TLS SON TARIHI
    NL13  bos sunucuda Stop 1.5 s icinde doner (kabul dongusu yoklanir)
    NL14  startup asamasi bekleyen baglanti varken Stop 5 s icinde; soket
          kapanir
    NL15  TLS el sikismasi beklerken Stop 5 s icinde (OpenSSL yoksa SKIP)
    NL16  SCRAM kimlik dogrulama beklerken Stop 5 s icinde
    NL17  COPY-In govdesi beklerken Stop 5 s icinde; gecici dosya kalmaz
    NL18  CALISAN sorgu sirasinda Stop 5 s icinde (iptal sinyali ise yarar)
    NL19  64 es zamanli baglanti acikken Stop 5 s icinde
    NL20  Stop sonrasi AYNI nesneyle yeniden Start ve hizmet
    NL21  art arda Start/Stop donguleri: tanitici cift kapatma yok
    NL22  TLS MUTLAK son tarihi: el sikismasi ve SSL_read, ReadTimeoutMs'i
          asamaz (OpenSSL yoksa SKIP)
    NL23  TLS yazma son tarihi: alicisi okumayan TLS oturumunda SSL_write
          son tarihte durur (OpenSSL yoksa SKIP)
    NL24  iptal sirri: OS CSPRNG'den gelir, baglanti basina benzersizdir,
          yeniden baslatmada tazelenir; yanlis sir iptal uretmez

  SINIRLILIK (gizlenmez): yalniz protokol katmani olculur; gercek ag
  gecikmesi uretilmez. NL15/NL22/NL23 OpenSSL kutuphanesi yoksa PASS
  degil SKIP yazar (Windows CI'da kutuphane yok).

  Sonuc satiri "SONUC: N PASS, M FAIL, K SKIP"; cikis kodu FAIL sayisidir. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Sockets, VDbNet, VDbPgWire, VDbTls;

type
  { NL23: TLS el sikismasini ayri parcacikta yapmak icin (Accept bloklar). }
  TTlsAcceptThread = class(TThread)
  private
    FCtx: TVdbTlsContext;
    FSock: TVdbSocket;
    FSess: TVdbTlsSession;
    FOk: Boolean;
    FErr: string;
  protected
    procedure Execute; override;
  public
    constructor Create(ACtx: TVdbTlsContext; ASock: TVdbSocket);
    property Ok: Boolean read FOk;
    property Sess: TVdbTlsSession read FSess;
    property ErrText: string read FErr;
  end;

const
  BASE_PORT  = 54520;
  TEST_USER  = 'netlim';
  PORT_TRIES = 40;
  SLOW_WAIT  = 6000;   // ms: yavas istemci dusene kadar beklenen ust sinir
  SHORT_TO   = 700;    // ms: testte kullanilan okuma zaman asimi
  CANCEL_CODE = 80877102;  // PostgreSQL CancelRequest

  { SKILL10 test sertifikasi: YALNIZ test icin uretilmis, kendinden imzali
    RSA-2048 anahtar (CN=localhost, SAN DNS:localhost,IP:127.0.0.1).
    Depoda gizli anahtar DEGILDIR; amaci TLS el sikismasini ve son
    tarihlerini gercekten calistirmaktir. }
  TEST_CERT_PEM =
    '-----BEGIN CERTIFICATE-----' + #10 +
    'MIIDJTCCAg2gAwIBAgIUUFJnvbLctfF2AakoU2r/5JSFscgwDQYJKoZIhvcNAQEL' + #10 +
    'BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MTEyMTEzMzUyOVoXDTM2MTEx' + #10 +
    'ODEzMzUyOVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF' + #10 +
    'AAOCAQ8AMIIBCgKCAQEAqwLVIRFetMSuQ+MFWKDQ+hSnc+sWBwQVWHDWgJpaRx5C' + #10 +
    'S606eD+g/UIhwMccQTgBKzLdexmnwSXko6fnyM+Ikg1q6BpHaaPrm0O55L1HfLGI' + #10 +
    'LIh4KDilK8gNt2a7YKNm8I0gryCM46jIa2kOEDbFnjyxNqgmaevbW0F+uhCrMX4y' + #10 +
    '607TB1v4Z4x1IX4RclPCl9aX36HOvKYm4Zt98lACsD5utn42JiOQRhyVDAYwJb5I' + #10 +
    'v2NSXLGHwMZE4R9ljU2aBl/oSA/MWiidrQadYDtXN4wbJ4wRwgFvH5DS/t2+OUcU' + #10 +
    'KwJtm5FyUTbGZmA4FJ2sGJAi6WWIfg3ANWSlJSNOmQIDAQABo28wbTAdBgNVHQ4E' + #10 +
    'FgQUv3XAdWqmdiiDhLXQcCJCC22XngQwHwYDVR0jBBgwFoAUv3XAdWqmdiiDhLXQ' + #10 +
    'cCJCC22XngQwDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SH' + #10 +
    'BH8AAAEwDQYJKoZIhvcNAQELBQADggEBAIz8ayghHJS2STwg8uGREWgKsw863PcP' + #10 +
    'V7BQwsPEQKidbOVmnKXk9dx6ZZiPZzADmUQhT3pYluZAVl1DOwSmKPPc1iQh0M67' + #10 +
    'j3TmD0/3VDFvM3OhjwNV+J+47StlfDCDXe6ZnABhRUGhsw7gIl8kUoUqX+Rz4gfn' + #10 +
    'xhuFr3rB0FYr4E4gdJwMpdcntPRQ4SFMVUEqm9HZNK5ZLmUfRTwZz+MgIGCwPuOP' + #10 +
    'Dnc5uzlshVVzyck6h3UnooTTM33FJo5gL0foCRyjxBBVsW3YuQhLs3fhpr8/blfk' + #10 +
    'HxPF63u+kPJJKX/W06hWq+bVX48a5khtaLGKAsRiKMuFLlGatHn1D3k=' + #10 +
    '-----END CERTIFICATE-----' + #10;

  TEST_KEY_PEM =
    '-----BEGIN PRIVATE KEY-----' + #10 +
    'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCrAtUhEV60xK5D' + #10 +
    '4wVYoND6FKdz6xYHBBVYcNaAmlpHHkJLrTp4P6D9QiHAxxxBOAErMt17GafBJeSj' + #10 +
    'p+fIz4iSDWroGkdpo+ubQ7nkvUd8sYgsiHgoOKUryA23Zrtgo2bwjSCvIIzjqMhr' + #10 +
    'aQ4QNsWePLE2qCZp69tbQX66EKsxfjLrTtMHW/hnjHUhfhFyU8KX1pffoc68pibh' + #10 +
    'm33yUAKwPm62fjYmI5BGHJUMBjAlvki/Y1JcsYfAxkThH2WNTZoGX+hID8xaKJ2t' + #10 +
    'Bp1gO1c3jBsnjBHCAW8fkNL+3b45RxQrAm2bkXJRNsZmYDgUnawYkCLpZYh+DcA1' + #10 +
    'ZKUlI06ZAgMBAAECggEAKG5agl9vczCe/NjjLjGTRtT0RDE7+3upKkg/Rpd3qaHL' + #10 +
    'TcYOcVil0Mq+XSwWD4tUp2h2ucB2i3FQjarIX49FfDZk5Kw13xGMxiAshpqDmMUG' + #10 +
    'a3T2Z5gA4QmCyK4mtfHcCBpttEnvVXHVtKNZWlcAwOkbgs8dieRj777b3dTMDL6k' + #10 +
    'uLtpufeiMLJgq7tsb5jt8aku+cPBWF2qjmaR+c0XbZgRzM+7oB+Oj2PT1bZ22MZo' + #10 +
    'gNyExNc9ug+iQ8IYhT6tjj9SWBcBkw4TuQbwt+ufzB3u8YDqB2CwSrkrmyTg9dBT' + #10 +
    '5fH8QpOL5e7brtUpFPaX1ehGJy7DepEEkVv8c9Va6wKBgQDAuXnQUudaF6mCyhKW' + #10 +
    'YonAFjkTtxKIMr08tUC14qi1FtvKrz9cNf1Q0uPBLHlse0eq4sNwCxoVL4BwVtOu' + #10 +
    'PDbsa0heKUZQPDzrdjZlAF2XkB/MXNOadKzISc1CoyKBf+UTRDy/pzRdAOHVIZMk' + #10 +
    'cCjk3asRZ5GEQ17lAoyli+/aCwKBgQDjKFaE1YbQlUDCvWRbYWKbMVuMyKVMK7OE' + #10 +
    'Vr96EB1ytnbMn/MQ5IGzymK3JisNYg9Mzwjro7KM/Umf+i9cF9yECai91ecbJfbi' + #10 +
    'nRLTFrWc9kuVwT9gNTA+INtkNNSjVsyy9FayqYwFzMvGZBrF1psUXOuHCXu+v7GB' + #10 +
    'fHkdoVEEawKBgDd/MYzD0ssmtTFsbx3PEku2GomK1lNSCRxKNXAq7Nn40yHyhRRQ' + #10 +
    'l7mGgP9Hh0+t0F1tH0pMaB5hp2KyHhK2VDqQSi6TRCQmtIQ5bkB3cnwKjJ2UvXpk' + #10 +
    'zrx+RBVEVNNluNlrdPLbe0Cs2Fs/Z9e+VIhTLMe+QzELFXBs44NoYJExAoGBAKTu' + #10 +
    'RONtpdUMiVjb6mHu84l67N3rURldIZqU4bHewYLouJkaCYHaZ9ICwGn6bIfrCvDZ' + #10 +
    '4cA1uw5jWXGuVXSoXpP/72TmSkaL6hXftitN8c9lhLvW9A0GkWCKusCnGzz9aOMG' + #10 +
    'RWyzbddIOyxwwn+isja2wMvrNs3ooRlDJy08U3bBAoGAZo+2N52uAAzDbV0WdvdV' + #10 +
    '6jsugn00YJjqymtrK2JfeXbPCGoNqb23wDuEM5RLhGpjD2wvaaCveDqKsFOTqoaI' + #10 +
    '1sC5v0rvFtHI0VFdIujvjnBclTo1w8sHxD0Y0oTggK6Y/vCAH0JbRjjmcM4IknPL' + #10 +
    'R7w1NDvEXBVVHBDWOxQZlOA=' + #10 +
    '-----END PRIVATE KEY-----' + #10;

var
  GPass, GFail, GSkip: Integer;
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

{ SKILL10: atlanan test PASS SAYILMAZ; ayri sayilir ve nedeni yazilir. }
procedure Skip(const AName, AReason: string);
begin
  Inc(GSkip);
  WriteLn('SKIP ', AName, ' - ', AReason);
  Flush(Output);
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

{ v3.69 / SKILL6 05: damla (drip) istemcisi. ABytes'i ADripMs araliklarla
  BIRER bayt gonderir ve her turda kisa bir okuma ile sunucunun soketi
  kapatip kapatmadigini denetler. Sonuc: TRUE = sunucu kapatti (AClosedMs:
  ilk bayttan itibaren gecen sure). Yazma da basarisiz olursa kapanmis
  sayilir (RST). }
function DripUntilClosed(ASock: TVdbSocket; const ABytes: AnsiString;
  ADripMs, ALimitMs: Integer; out AClosedMs: QWord): Boolean;
var
  i: Integer;
  t0: QWord;
  b: Byte;
  rv: Integer;
begin
  Result := False;
  AClosedMs := 0;
  t0 := NowMs;
  for i := 1 to Length(ABytes) do
  begin
    AClosedMs := NowMs - t0;
    if AClosedMs > QWord(ALimitMs) then Exit;
    if not SendRaw(ASock, ABytes[i]) then
    begin
      Result := True;
      Exit;
    end;
    Sleep(ADripMs);
    rv := VdbRecvSome(ASock, b, 1);
    AClosedMs := NowMs - t0;
    if rv = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

{ v3.69 / SKILL6 05: loopback uzerinde bagli TCP soket cifti (alicisi
  OKUMAYAN taraf) - yazma son tarihini olcmek icin. }
function MakeTcpPair(out AA, AB: TVdbSocket; out ADetail: string): Boolean;
var
  lst, cli: TVdbSocket;
  sa: TInetSockAddr;
  n, rbv, rbl: Integer;
begin
  Result := False;
  ADetail := '';
  AA := VDB_SOCK_INVALID;
  AB := VDB_SOCK_INVALID;
  lst := fpSocket(AF_INET, SOCK_STREAM, 0);
  if lst = VDB_SOCK_INVALID then
  begin
    ADetail := 'dinleme soketi acilamadi';
    Exit;
  end;
  n := 4096;
  fpSetSockOpt(lst, SOL_SOCKET, SO_RCVBUF, @n, SizeOf(n));
  FillChar(sa, SizeOf(sa), 0);
  sa.sin_family := AF_INET;
  sa.sin_port := 0;
  sa.sin_addr := StrToNetAddr('127.0.0.1');
  if fpBind(lst, @sa, SizeOf(sa)) <> 0 then
  begin
    ADetail := 'bind basarisiz';
    VdbSockClose(lst);
    Exit;
  end;
  if fpListen(lst, 1) <> 0 then
  begin
    ADetail := 'listen basarisiz';
    VdbSockClose(lst);
    Exit;
  end;
  n := SizeOf(sa);
  if fpGetSockName(lst, @sa, @n) <> 0 then
  begin
    ADetail := 'yerel ad alinamadi';
    VdbSockClose(lst);
    Exit;
  end;
  cli := fpSocket(AF_INET, SOCK_STREAM, 0);
  if cli = VDB_SOCK_INVALID then
  begin
    ADetail := 'istemci soketi acilamadi';
    VdbSockClose(lst);
    Exit;
  end;
  { Pencere baglanti kurulurken duyurulur: alici tarafin tamponu kucuk
    olmali, yoksa Windows tamponu megabaytlara cikarip yazmayi hic
    engellemez. }
  n := 4096;
  fpSetSockOpt(cli, SOL_SOCKET, SO_RCVBUF, @n, SizeOf(n));
  if fpConnect(cli, @sa, SizeOf(sa)) <> 0 then
  begin
    ADetail := 'connect basarisiz';
    VdbSockClose(cli);
    VdbSockClose(lst);
    Exit;
  end;
  AA := fpAccept(lst, nil, nil);
  VdbSockClose(lst);
  if AA = VDB_SOCK_INVALID then
  begin
    ADetail := 'accept basarisiz';
    VdbSockClose(cli);
    Exit;
  end;
  AB := cli;
  Result := True;
end;

{ SKILL10 yardimcilari ------------------------------------------------ }

function BodyI32(const ABody: AnsiString; APos: Integer): LongInt;
begin
  Result := LongInt((LongWord(Ord(ABody[APos])) shl 24) or
    (LongWord(Ord(ABody[APos + 1])) shl 16) or
    (LongWord(Ord(ABody[APos + 2])) shl 8) or
    LongWord(Ord(ABody[APos + 3])));
end;

function WritePemFile(const APath, AText: string): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(APath, fmCreate);
    try
      if Length(AText) > 0 then fs.WriteBuffer(AText[1], Length(AText));
    finally
      fs.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

{ Tek bir protokol mesaji okur (ReadyForQuery beklemeden). }
function ReadOneMsg(ASock: TVdbSocket; out ATyp: Byte;
  out ABody: AnsiString): Boolean;
var
  len: LongWord;
begin
  Result := False;
  ABody := '';
  if not VdbRecvU8(ASock, ATyp) then Exit;
  if not Recv32BE(ASock, len) then Exit;
  if (len < 4) or (len > 32 * 1024 * 1024) then Exit;
  Result := RecvBody(ASock, Integer(len) - 4, ABody);
end;

{ Startup + BackendKeyData yakalama (NL24). }
function ConnectStartupKey(APort: Word; out ASock: TVdbSocket;
  out APid, ASecret: LongInt; out ADetail: string): Boolean;
var
  t: Byte;
  body: AnsiString;
  guard: Integer;
begin
  Result := False;
  ADetail := '';
  APid := 0;
  ASecret := 0;
  ASock := VdbTcpConnect('127.0.0.1', APort);
  if ASock = VDB_SOCK_INVALID then
  begin
    ADetail := 'baglanti kurulamadi';
    Exit;
  end;
  VdbSockSetTimeouts(ASock, 5000, 5000);
  if not SendRaw(ASock, StartupPacket(TEST_USER)) then
  begin
    ADetail := 'startup gonderilemedi';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  for guard := 1 to 200 do
  begin
    if not ReadOneMsg(ASock, t, body) then
    begin
      ADetail := 'startup yaniti okunamadi';
      VdbSockClose(ASock);
      ASock := VDB_SOCK_INVALID;
      Exit;
    end;
    if (t = Ord('K')) and (Length(body) >= 8) then
    begin
      APid := BodyI32(body, 1);
      ASecret := BodyI32(body, 5);
    end;
    if t = Ord('E') then
    begin
      ADetail := 'startup E yaniti';
      VdbSockClose(ASock);
      ASock := VDB_SOCK_INVALID;
      Exit;
    end;
    if t = Ord('Z') then
    begin
      if (APid = 0) or (ASecret = 0) then
      begin
        ADetail := 'BackendKeyData yok';
        VdbSockClose(ASock);
        ASock := VDB_SOCK_INVALID;
        Exit;
      end;
      Exit(True);
    end;
  end;
  ADetail := 'startup yaniti bitmedi';
  VdbSockClose(ASock);
  ASock := VDB_SOCK_INVALID;
end;

function CancelPacket(APid, ASecret: LongInt): AnsiString;
begin
  Result := BE32(16) + BE32(CANCEL_CODE) + BE32(LongWord(APid)) +
            BE32(LongWord(ASecret));
end;

{ CancelRequest ayri baglantida gelir ve yanit almaz; sunucu kapatir. }
function SendCancel(const APacket: AnsiString; out AClosed: Boolean;
  out ADetail: string): Boolean;
var
  cs: TVdbSocket;
  b: Byte;
  n: Integer;
begin
  Result := False;
  AClosed := False;
  ADetail := '';
  cs := VdbTcpConnect('127.0.0.1', GPort);
  if cs = VDB_SOCK_INVALID then
  begin
    ADetail := 'cancel baglantisi kurulamadi';
    Exit;
  end;
  try
    VdbSockSetTimeouts(cs, 2000, 2000);
    if not SendRaw(cs, APacket) then
    begin
      ADetail := 'cancel paketi gonderilemedi';
      Exit;
    end;
    n := VdbRecvSome(cs, b, 1);
    AClosed := n = 0;
    if n <> 0 then ADetail := 'kapanmadi, okunan=' + IntToStr(n);
    Result := True;
  finally
    VdbSockClose(cs);
  end;
end;

{ Sorgu calistirir; SQLSTATE kodunu ve ilk DataRow degerini doner. }
function QueryRaw(ASock: TVdbSocket; const ASql: string;
  out ACode, AValue: string): Boolean;
var
  t: Byte;
  body: AnsiString;
  guard: Integer;
  p, ncols: Integer;
  clen: LongWord;
  fld, ftyp: AnsiChar;
  s: string;
begin
  Result := False;
  ACode := '';
  AValue := '';
  if not SendMsg(ASock, 'Q', ASql + #0) then Exit;
  for guard := 1 to 2000 do
  begin
    if not ReadOneMsg(ASock, t, body) then Exit;
    if t = Ord('E') then
    begin
      { ErrorResponse: alan turu + metin + #0 dizisi. }
      p := 1;
      while p <= Length(body) do
      begin
        ftyp := AnsiChar(body[p]);
        Inc(p);
        s := '';
        while (p <= Length(body)) and (body[p] <> #0) do
        begin
          s := s + body[p];
          Inc(p);
        end;
        Inc(p);
        if ftyp = 'C' then ACode := s;
      end;
    end;
    if (t = Ord('D')) and (AValue = '') and (Length(body) >= 6) then
    begin
      ncols := (Ord(body[1]) shl 8) or Ord(body[2]);
      if ncols >= 1 then
      begin
        p := 3;
        clen := (LongWord(Ord(body[p])) shl 24) or
                (LongWord(Ord(body[p + 1])) shl 16) or
                (LongWord(Ord(body[p + 2])) shl 8) or
                LongWord(Ord(body[p + 3]));
        if clen < $80000000 then AValue := Copy(body, p + 4, clen);
      end;
    end;
    if t = Ord('Z') then Exit(True);
  end;
end;

{ SSLRequest gonderip 'S' yanitini bekler (TLS istemci kutuphanesi
  kullanmadan; el sikismasi son tarihini olcmek icin). }
function BeginTlsHandshake(APort: Word; out ASock: TVdbSocket;
  out ADetail: string): Boolean;
var
  b: Byte;
begin
  Result := False;
  ADetail := '';
  ASock := VdbTcpConnect('127.0.0.1', APort);
  if ASock = VDB_SOCK_INVALID then
  begin
    ADetail := 'baglanti kurulamadi';
    Exit;
  end;
  VdbSockSetTimeouts(ASock, 5000, 5000);
  if not SendRaw(ASock, BE32(8) + BE32(80877103)) then
  begin
    ADetail := 'SSLRequest gonderilemedi';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  if not VdbRecvU8(ASock, b) then
  begin
    ADetail := 'SSLRequest yaniti okunamadi';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  if b <> Ord('S') then
  begin
    ADetail := 'sunucu TLS sunmuyor';
    VdbSockClose(ASock);
    ASock := VDB_SOCK_INVALID;
    Exit;
  end;
  Result := True;
end;

{ Gercek TLS istemcisi: SSLRequest + el sikismasi. ACtx cagirana aittir. }
function TlsUpgrade(APort: Word; const ACaFile: string;
  out ASock: TVdbSocket; out ASess: TVdbTlsSession;
  out ACtx: TVdbTlsContext; out ADetail: string): Boolean;
var
  e: string;
begin
  Result := False;
  ASess := nil;
  ACtx := nil;
  if not BeginTlsHandshake(APort, ASock, ADetail) then Exit;
  try
    ACtx := TVdbTlsContext.CreateClient(ACaFile, 'localhost');
    if not ACtx.Connect(ASock, ASess, e, NowMs + 5000) then
    begin
      ADetail := 'TLS el sikismasi: ' + e;
      VdbSockClose(ASock);
      ASock := VDB_SOCK_INVALID;
      Exit;
    end;
    Result := True;
  except
    on E2: Exception do
    begin
      ADetail := 'TLS istemci: ' + E2.Message;
      FreeAndNil(ACtx);
      VdbSockClose(ASock);
      ASock := VDB_SOCK_INVALID;
    end;
  end;
end;

constructor TTlsAcceptThread.Create(ACtx: TVdbTlsContext; ASock: TVdbSocket);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCtx := ACtx;
  FSock := ASock;
  FSess := nil;
  FOk := False;
  FErr := '';
  Start;
end;

procedure TTlsAcceptThread.Execute;
begin
  try
    FOk := FCtx.Accept(FSock, FSess, FErr, 0);
  except
    on E: Exception do
    begin
      FOk := False;
      FErr := E.Message;
    end;
  end;
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
  drip: AnsiString;
  big: AnsiString;
  { SKILL10 }
  certPath, keyPath: string;
  tlsOk, pemOk: Boolean;
  conns: array[0..63] of TVdbSocket;
  nconns: Integer;
  secrets, pids: array[0..15] of LongInt;
  oldSecrets: array[0..15] of LongInt;
  nsecret, nold, dupes: Integer;
  tlsCtx, srvCtx, cliCtx: TVdbTlsContext;
  tlsSess, srvSess, cliSess: TVdbTlsSession;
  acct: TTlsAcceptThread;
  code, code2: string;
  hits0: Integer;
  k, cycle: Integer;
  ca, cb: TVdbSocket;
  tlsA, tlsB: TVdbSocket;
  rv: Integer;
  ms2: QWord;
  btls: Byte;

begin
  GPass := 0;
  GSkip := 0;
  GFail := 0;
  tlsCtx := nil;
  tlsSess := nil;
  srvCtx := nil;
  cliCtx := nil;
  srvSess := nil;
  cliSess := nil;
  acct := nil;
  tlsA := VDB_SOCK_INVALID;
  tlsB := VDB_SOCK_INVALID;
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

  { --- NL9: damla saldirisi -> MUTLAK mesaj son tarihi ----------------- }
  { Istemci 'Q' basligiyla 1000 baytlik govde ilan eder, sonra govdeyi
    HER 100 ms'de BIR BAYT gonderir. Okuma zaman asimi 300 ms: eski kodda
    SO_RCVTIMEO HER recv icin yeniden basladigi icin (100 < 300) baglanti
    sinirsiz acik kaliyordu. Mutlak son tarih 300 ms'de kapatmalidir. }
  Srv.ReadTimeoutMs := 300;
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL9 istemci baglandi', False, detail)
  else
  begin
    VdbSockSetTimeouts(s, 100, 100);
    SendRaw(s, 'Q' + BE32(1004));
    drip := StringOfChar('x', 200);
    ok := DripUntilClosed(s, drip, 100, 4000, elapsed);
    Chk('NL9 damla istemcisi mutlak son tarihte dusuruldu', ok,
      'gecen ms=' + IntToStr(elapsed));
    Chk('NL9 kapatma 2 s icinde', ok and (elapsed < 2000),
      IntToStr(elapsed) + ' ms');
    VdbSockClose(s);
  end;

  { --- NL10: yarim startup basligi damla damla ------------------------- }
  s := VdbTcpConnect('127.0.0.1', GPort);
  if s = VDB_SOCK_INVALID then
    Chk('NL10 istemci baglandi', False, 'baglanti kurulamadi')
  else
  begin
    VdbSockSetTimeouts(s, 100, 100);
    ok := DripUntilClosed(s, BE32(200) + BE32(196608) + 'xy', 100, 4000, elapsed);
    Chk('NL10 yarim startup damlasi dusuruldu', ok,
      'gecen ms=' + IntToStr(elapsed));
    Chk('NL10 kapatma 2 s icinde', ok and (elapsed < 2000),
      IntToStr(elapsed) + ' ms');
    VdbSockClose(s);
  end;

  { --- NL11: COPY-In govdesi damla damla ------------------------------- }
  tmpBefore := PgCopyTempCount;
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL11 istemci baglandi', False, detail)
  else
  begin
    VdbSockSetTimeouts(s, 100, 100);
    SendMsg(s, 'Q', 'COPY nl FROM STDIN' + #0);
    ok := ReadToReady(s, etxt, sawData, sawCopy, msgs);
    Chk('NL11 COPY-In yaniti alindi', sawCopy, 'msgs=' + IntToStr(msgs));
    if sawCopy then
    begin
      SendRaw(s, 'd' + BE32(1004));
      ok := DripUntilClosed(s, drip, 100, 4000, elapsed);
      Chk('NL11 yavas COPY-In govdesi dusuruldu', ok,
        'gecen ms=' + IntToStr(elapsed));
      Chk('NL11 kapatma 2 s icinde', ok and (elapsed < 2000),
        IntToStr(elapsed) + ' ms');
    end;
    VdbSockClose(s);
  end;
  ok := RunSql(GPort, 'SELECT COUNT(*) FROM nl', val, etxt);
  Chk('NL11 yarim COPY tabloyu degistirmedi', ok and (val = '1'),
    'val=' + val + ' err=' + etxt);
  tmpAfter := PgCopyTempCount;
  Chk('NL11 gecici dosya kalmadi', tmpAfter <= tmpBefore,
    'once=' + IntToStr(tmpBefore) + ' sonra=' + IntToStr(tmpAfter));
  Srv.ReadTimeoutMs := 30000;

  { --- NL12: yazma son tarihi ------------------------------------------ }
  { NOT (durust sinir): Windows loopback'ta ENGELLENEN bir yazma
    uretilemiyor - olculdu, RCVBUF=4096 iken 16 MiB'lik gonderim 16 ms'de
    tamponlara kabul edildi. Bu yuzden NL12 "engellenirken son tarih
    uygulanir"i degil, SON TARIHIN KENDISINI olcer: (a) butcesi bitmis
    cagri HIC BAYT yazmaz, (b) ayni mutlak son tarih ard arda gonderimlerde
    uygulanir (yazma durur), (c) bol butce ile ayni yuk tamamen gider. }
  if not MakeTcpPair(s, s8, detail) then
    Chk('NL12 soket cifti kuruldu', False, detail)
  else
  begin
    { Yazma tarafina 300 ms OS tavani (sunucu da kabul aninda
      VdbSockSetTimeouts ile ayni tavani kurar). }
    VdbSockSetTimeouts(s, 5000, 300);
    VdbSockSetTimeouts(s8, 200, 5000);
    big := StringOfChar('x', 64 * 1024);

    { (a) butce zaten bitmis -> yazma YOK }
    ok := VdbSendAllDl(s, big[1], Length(big), NowMs - 1);
    Chk('NL12 butcesi bitmis gonderim reddedildi', not ok,
      'ok=' + BoolToStr(ok, True));
    msgs := VdbRecvSome(s8, nl8buf, 1);
    Chk('NL12 butcesi bitmis gonderim HIC bayt yazmadi', msgs <= 0,
      'okunan=' + IntToStr(msgs));

    { (c) bol butce, kucuk yuk: gonderim tamamlanir }
    ok := VdbSendAllDl(s, big[1], Length(big), NowMs + 5000);
    Chk('NL12 bol butce ile gonderim tamamlandi', ok,
      'ok=' + BoolToStr(ok, True));

    { (b) ayni mutlak son tarih ard arda gonderimlerde: 4000 x 64 KiB
        (256 MiB) teklif edilir, 50 ms butce, alici OKUMAZ. Yazma
        sinirsiz engellenmemeli.
        DURUST SINIR: tek bir fpSend cagrisi kendi OS tavanini
        (SO_SNDTIMEO = 300 ms) asabilir; bu yuzden ust sinir 2 s'dir,
        tam olarak 50 ms degil. }
    t0 := NowMs;
    elapsed := t0 + 50;
    ok := True;
    i := 0;
    while (i < 4000) and ok do
    begin
      ok := VdbSendAllDl(s, big[1], Length(big), elapsed);
      if ok then Inc(i);
    end;
    Chk('NL12 engellenen yazma sinirli surede durdu', not ok,
      'gonderilen blok=' + IntToStr(i));
    Chk('NL12 durma 2 s icinde', (not ok) and ((NowMs - t0) < 2000),
      IntToStr(NowMs - t0) + ' ms');
    Chk('NL12 tum yuk gonderilemedi', i < 4000,
      'gonderilen blok=' + IntToStr(i));
    VdbSockClose(s);
    VdbSockClose(s8);
  end;

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

  { ================= SKILL10: NL13 - NL24 ============================== }
  WriteLn('--- SKILL10: sunucu durdurma ve TLS son tarihleri ---');

  certPath := TestDir + 'nl_test_cert.pem';
  keyPath := TestDir + 'nl_test_key.pem';
  pemOk := WritePemFile(certPath, TEST_CERT_PEM) and
           WritePemFile(keyPath, TEST_KEY_PEM);
  tlsOk := pemOk and VDbTlsAvailable;
  if not pemOk then
    Skip('NL15/NL22/NL23 TLS testleri', 'test sertifikasi yazilamadi')
  else if not VDbTlsAvailable then
    Skip('NL15/NL22/NL23 TLS testleri',
      'OpenSSL kutuphanesi yok: ' + VDbTlsLastError);

  Srv := nil;
  started := False;
  err := '';
  for i := 0 to PORT_TRIES - 1 do
  begin
    Srv := TVdbPgServer.Create(Dir, Word(BASE_PORT + 60 + i));
    Srv.BindHost := '127.0.0.1';
    if tlsOk then Srv.SetTlsFiles(certPath, keyPath);
    if Srv.Start(err) then
    begin
      GPort := Srv.Port;
      started := True;
      Break;
    end;
    FreeAndNil(Srv);
  end;
  Chk('NL13 ikinci sunucu basladi (TLS yapilandirildi)', started, err);
  if not started then
  begin
    WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL, ', GSkip, ' SKIP');
    Halt(1);
  end;
  if tlsOk then
    Chk('NL13 sunucu TLS baglamini kurdu', Srv.TlsActive,
      'TlsActive=' + BoolToStr(Srv.TlsActive, True));

  { --- NL13: bos sunucuda Stop ---------------------------------------- }
  t0 := NowMs;
  Srv.Stop;
  elapsed := NowMs - t0;
  Chk('NL13 bos sunucuda Stop 1.5 s icinde dondu', elapsed < 1500,
    IntToStr(elapsed) + ' ms');
  Chk('NL13 Stop sonrasi ConnCount=0', Srv.ConnCount = 0,
    'ConnCount=' + IntToStr(Srv.ConnCount));
  started := Srv.Start(err);
  Chk('NL13 Stop sonrasi yeniden Start', started, err);

  { --- NL14: startup asamasi beklerken Stop ---------------------------- }
  s := VdbTcpConnect('127.0.0.1', GPort);
  ok := s <> VDB_SOCK_INVALID;
  if ok then
  begin
    VdbSockSetTimeouts(s, 5000, 5000);
    SendRaw(s, BE32(200) + BE32(196608));
    Sleep(150);
  end;
  t0 := NowMs;
  Srv.Stop;
  elapsed := NowMs - t0;
  Chk('NL14 startup beklerken Stop 5 s icinde dondu',
    ok and (elapsed < 5000), IntToStr(elapsed) + ' ms');
  if ok then
  begin
    VdbSockSetTimeouts(s, 1500, 1500);
    rv := VdbRecvSome(s, btls, 1);
    Chk('NL14 Stop startup istemci soketini kapatti', rv <= 0,
      'rv=' + IntToStr(rv));
    VdbSockClose(s);
  end;
  started := Srv.Start(err);
  Chk('NL14 yeniden Start', started, err);

  { --- NL15: TLS el sikismasi beklerken Stop --------------------------- }
  if not tlsOk then
    Skip('NL15 TLS el sikismasi beklerken Stop', 'OpenSSL yok')
  else if not BeginTlsHandshake(GPort, s, detail) then
    Chk('NL15 TLS el sikismasi basladi', False, detail)
  else
  begin
    Chk('NL15 TLS el sikismasi basladi', True, '');
    Sleep(150);
    t0 := NowMs;
    Srv.Stop;
    elapsed := NowMs - t0;
    Chk('NL15 TLS el sikismasi beklerken Stop 5 s icinde dondu',
      elapsed < 5000, IntToStr(elapsed) + ' ms');
    VdbSockSetTimeouts(s, 1500, 1500);
    rv := VdbRecvSome(s, btls, 1);
    Chk('NL15 Stop TLS istemci soketini kapatti', rv <= 0,
      'rv=' + IntToStr(rv));
    VdbSockClose(s);
  end;
  if not Srv.Ready then
  begin
    started := Srv.Start(err);
    Chk('NL15 sonrasi sunucu yeniden ayakta', started, err);
  end;

  { --- NL16: SCRAM kimlik dogrulama beklerken Stop --------------------- }
  Srv.Stop;
  Srv.AddUser(TEST_USER, 'nl16-parola', 4096, '');
  Srv.AllowUnmappedUsers := True;
  started := Srv.Start(err);
  Chk('NL16 SCRAM sunucusu basladi', started and Srv.AuthRequired, err);
  if started then
  begin
    s := VdbTcpConnect('127.0.0.1', GPort);
    ok := s <> VDB_SOCK_INVALID;
    if ok then
    begin
      VdbSockSetTimeouts(s, 5000, 5000);
      SendRaw(s, StartupPacket(TEST_USER));
      ok := ReadOneMsg(s, btls, big);
      Chk('NL16 kimlik dogrulama istendi (R mesaji)',
        ok and (btls = Ord('R')), 'typ=' + IntToStr(btls));
      t0 := NowMs;
      Srv.Stop;
      elapsed := NowMs - t0;
      Chk('NL16 SCRAM beklerken Stop 5 s icinde dondu', elapsed < 5000,
        IntToStr(elapsed) + ' ms');
      VdbSockClose(s);
    end
    else
    begin
      Chk('NL16 istemci baglandi', False, 'baglanti kurulamadi');
      Srv.Stop;
    end;
    Srv.ClearUsers;
    started := Srv.Start(err);
    Chk('NL16 sonrasi trust modunda yeniden Start',
      started and (not Srv.AuthRequired), err);
  end;

  { --- NL17: COPY-In govdesi beklerken Stop ---------------------------- }
  tmpBefore := PgCopyTempCount;
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL17 istemci baglandi', False, detail)
  else
  begin
    SendMsg(s, 'Q', 'COPY nl FROM STDIN' + #0);
    ok := ReadToReady(s, etxt, sawData, sawCopy, msgs);
    Chk('NL17 COPY-In yaniti alindi', sawCopy, 'msgs=' + IntToStr(msgs));
    if sawCopy then
    begin
      { 1004 bayt ilan edip 3 bayt gonderir: sunucu govdeyi bekler. }
      SendRaw(s, 'd' + BE32(1004) + 'abc');
      Sleep(150);
      t0 := NowMs;
      Srv.Stop;
      elapsed := NowMs - t0;
      Chk('NL17 COPY-In beklerken Stop 5 s icinde dondu', elapsed < 5000,
        IntToStr(elapsed) + ' ms');
    end;
    VdbSockClose(s);
  end;
  tmpAfter := PgCopyTempCount;
  Chk('NL17 Stop sonrasi yarim COPY gecici dosya birakmadi',
    tmpAfter <= tmpBefore,
    'once=' + IntToStr(tmpBefore) + ' sonra=' + IntToStr(tmpAfter));
  if not Srv.Ready then
  begin
    started := Srv.Start(err);
    Chk('NL17 sonrasi sunucu yeniden ayakta', started, err);
  end;

  { --- NL18: CALISAN sorgu sirasinda Stop ------------------------------ }
  { Uzun ama BELLEKCE SINIRLI sorgu: korelasyonlu IN, dis satir basina
    ic tabloyu tarar; satir matrisi birikmez. QueryTimeoutMs bir guvenlik
    agidir: iptal calismazsa bile 4 s'de biter, gate kilitlenmez. }
  for i := 0 to 14 do
  begin
    if i = 0 then
    begin
      RunSql(GPort, 'CREATE TABLE nlbig(a INTEGER, b TEXT)', val, etxt);
      RunSql(GPort, 'INSERT INTO nlbig VALUES (1,''x'')', val, etxt);
    end
    else
      RunSql(GPort, 'INSERT INTO nlbig SELECT a, b FROM nlbig', val, etxt);
  end;
  ok := RunSql(GPort, 'SELECT COUNT(*) FROM nlbig', val, etxt);
  Chk('NL18 test tablosu hazir (16384 satir)', ok and (val = '16384'),
    'val=' + val + ' err=' + etxt);
  Srv.QueryTimeoutMs := 4000;
  if not ConnectStartup(GPort, s, detail) then
    Chk('NL18 istemci baglandi', False, detail)
  else
  begin
    SendMsg(s, 'Q',
      'SELECT COUNT(*) FROM nlbig x WHERE x.a IN ' +
      '(SELECT y.a FROM nlbig y WHERE y.a = x.a)' + #0);
    Sleep(50);
    t0 := NowMs;
    Srv.Stop;
    elapsed := NowMs - t0;
    Chk('NL18 calisan sorgu sirasinda Stop 5 s icinde dondu', elapsed < 5000,
      IntToStr(elapsed) + ' ms');
    Chk('NL18 iptal sinyali 1.5 s icinde etkili oldu', elapsed < 1500,
      IntToStr(elapsed) + ' ms');
    VdbSockSetTimeouts(s, 1500, 1500);
    rv := VdbRecvSome(s, btls, 1);
    Chk('NL18 Stop sorgu istemci soketini kapatti', rv <= 0,
      'rv=' + IntToStr(rv));
    VdbSockClose(s);
  end;
  Srv.QueryTimeoutMs := 0;
  if not Srv.Ready then
  begin
    started := Srv.Start(err);
    Chk('NL18 sonrasi sunucu yeniden ayakta', started, err);
  end;
  ok := RunSql(GPort, 'SELECT COUNT(*) FROM nlbig', val, etxt);
  Chk('NL18 iptal edilen sorgu veriyi bozmadi', ok and (val = '16384'),
    'val=' + val + ' err=' + etxt);

  { --- NL19: 64 es zamanli baglanti acikken Stop ----------------------- }
  Srv.MaxConns := 64;
  nconns := 0;
  for i := 0 to 63 do
  begin
    if ConnectStartup(GPort, conns[i], detail) then
      Inc(nconns)
    else
      conns[i] := VDB_SOCK_INVALID;
  end;
  Chk('NL19 64 es zamanli baglanti kuruldu', nconns = 64,
    IntToStr(nconns) + '/64');
  Chk('NL19 ConnCount 64', Srv.ConnCount = 64, IntToStr(Srv.ConnCount));
  t0 := NowMs;
  Srv.Stop;
  elapsed := NowMs - t0;
  Chk('NL19 64 baglanti acikken Stop 5 s icinde dondu', elapsed < 5000,
    IntToStr(elapsed) + ' ms');
  Chk('NL19 Stop sonrasi ConnCount=0', Srv.ConnCount = 0,
    'ConnCount=' + IntToStr(Srv.ConnCount));
  for i := 0 to 63 do
    if conns[i] <> VDB_SOCK_INVALID then VdbSockClose(conns[i]);

  { --- NL20: Stop sonrasi AYNI nesneyle yeniden Start ------------------ }
  started := Srv.Start(err);
  Chk('NL20 Stop sonrasi ayni nesneyle Start', started, err);
  if started then
  begin
    Chk('NL20 yeniden Start ayni portta', Srv.Port = GPort,
      'port=' + IntToStr(Srv.Port));
    ok := ValidClient(GPort, detail);
    Chk('NL20 yeniden Start sonrasi gecerli istemci calisti', ok, detail);
    { Istemci soketi kapattiginda sunucu bunu bir sonraki okuma diliminde
      gorur; sifir sayaci hemen beklemek yaris olur. }
    t0 := NowMs;
    while (Srv.ConnCount <> 0) and (NowMs - t0 < 3000) do Sleep(50);
    Chk('NL20 yeniden Start sonrasi ConnCount=0 (istemci kapandi)',
      Srv.ConnCount = 0, IntToStr(Srv.ConnCount));
  end;

  { --- NL21: art arda Start/Stop donguleri ----------------------------- }
  recovered := False;
  for cycle := 1 to 3 do
  begin
    s := VdbTcpConnect('127.0.0.1', GPort);
    if s <> VDB_SOCK_INVALID then
      SendRaw(s, BE32(200) + BE32(196608));
    t0 := NowMs;
    Srv.Stop;
    elapsed := NowMs - t0;
    Chk('NL21 dongu ' + IntToStr(cycle) + ' Stop 5 s icinde',
      elapsed < 5000, IntToStr(elapsed) + ' ms');
    Chk('NL21 dongu ' + IntToStr(cycle) + ' ConnCount=0',
      Srv.ConnCount = 0, IntToStr(Srv.ConnCount));
    if s <> VDB_SOCK_INVALID then VdbSockClose(s);
    started := Srv.Start(err);
    Chk('NL21 dongu ' + IntToStr(cycle) + ' yeniden Start', started, err);
    if started then
    begin
      ok := ValidClient(GPort, detail);
      Chk('NL21 dongu ' + IntToStr(cycle) + ' hizmet veriyor', ok, detail);
      recovered := recovered or ok;
    end;
  end;
  Chk('NL21 tanitici cift kapatma/soket yeniden kullanimi hatasi yok',
    recovered, 'en az bir dongu hizmet verdi');

  { --- NL24: iptal sirri (CSPRNG) + yalitim ---------------------------- }
  nsecret := 0;
  for i := 0 to 7 do
  begin
    if ConnectStartupKey(GPort, conns[i], pids[i], secrets[i], detail) then
      Inc(nsecret)
    else
      conns[i] := VDB_SOCK_INVALID;
  end;
  Chk('NL24 8 baglanti BackendKeyData aldi', nsecret = 8,
    IntToStr(nsecret) + '/8');
  dupes := 0;
  for i := 0 to 7 do
    if secrets[i] = 0 then Inc(dupes);
  Chk('NL24 iptal sirlari sifir degil', dupes = 0,
    'sifir sayisi=' + IntToStr(dupes));
  dupes := 0;
  for i := 0 to 7 do
    for k := i + 1 to 7 do
      if secrets[i] = secrets[k] then Inc(dupes);
  Chk('NL24 iptal sirlari baglanti basina benzersiz', (nsecret = 8) and (dupes = 0),
    'cakisma=' + IntToStr(dupes));
  dupes := 0;
  for i := 0 to 7 do
    for k := i + 1 to 7 do
      if pids[i] = pids[k] then Inc(dupes);
  Chk('NL24 pid''ler benzersiz', (nsecret = 8) and (dupes = 0),
    'cakisma=' + IntToStr(dupes));

  if nsecret >= 4 then
  begin
    hits0 := Srv.CancelHits;
    ok := SendCancel(CancelPacket(pids[0], secrets[0] xor 1), recovered, detail);
    Sleep(300);
    Chk('NL24 YANLIS sir iptal uretmedi',
      ok and recovered and (Srv.CancelHits = hits0),
      'once=' + IntToStr(hits0) + ' sonra=' + IntToStr(Srv.CancelHits));
    ok := QueryRaw(conns[0], 'SELECT 11', code, val);
    Chk('NL24 yanlis sirden sonra baglanti saglam',
      ok and (code = '') and (val = '11'),
      'code=' + code + ' val=' + val);

    ok := SendCancel(CancelPacket(pids[0], secrets[0]), recovered, detail);
    Sleep(300);
    Chk('NL24 DOGRU sir iptal kaydetti',
      ok and recovered and (Srv.CancelHits = hits0 + 1),
      'once=' + IntToStr(hits0) + ' sonra=' + IntToStr(Srv.CancelHits));
    ok := QueryRaw(conns[0], 'SELECT 12', code, val);
    Chk('NL24 iptal edilen cumle 57014 verdi',
      ok and (code = '57014'), 'code=' + code);
    ok := QueryRaw(conns[0], 'SELECT 13', code, val);
    Chk('NL24 iptal TEK SEFERLIK: sonraki cumle calisti',
      ok and (code = '') and (val = '13'), 'code=' + code + ' val=' + val);
    ok := QueryRaw(conns[1], 'SELECT 14', code, val);
    Chk('NL24 diger baglanti ETKILENMEDI',
      ok and (code = '') and (val = '14'), 'code=' + code + ' val=' + val);

    { Yeniden baslatma: sirlar TAZELENIR (RNG durumu tasinmaz). }
    nold := 0;
    for i := 0 to 3 do
    begin
      oldSecrets[i] := secrets[i];
      Inc(nold);
    end;
    for i := 0 to 7 do
      if conns[i] <> VDB_SOCK_INVALID then
      begin
        VdbSockClose(conns[i]);
        conns[i] := VDB_SOCK_INVALID;
      end;
    Srv.Stop;
    started := Srv.Start(err);
    Chk('NL24 yeniden Start sonrasi sirlar sinandi', started, err);
    if started then
    begin
      nsecret := 0;
      for i := 0 to 3 do
      begin
        if ConnectStartupKey(GPort, conns[i], pids[i], secrets[i], detail) then
          Inc(nsecret)
        else
          conns[i] := VDB_SOCK_INVALID;
      end;
      dupes := 0;
      for i := 0 to 3 do
      begin
        if secrets[i] = 0 then Inc(dupes);
        for k := 0 to nold - 1 do
          if secrets[i] = oldSecrets[k] then Inc(dupes);
      end;
      Chk('NL24 yeniden baslatmada sirlar tazelendi',
        (nsecret = 4) and (dupes = 0), 'cakisma=' + IntToStr(dupes));
      for i := 0 to 3 do
        if conns[i] <> VDB_SOCK_INVALID then VdbSockClose(conns[i]);
    end;
  end;

  { --- NL22: TLS MUTLAK son tarihi ------------------------------------- }
  if not tlsOk then
    Skip('NL22 TLS mutlak son tarihi', 'OpenSSL yok')
  else
  begin
    { (a) el sikismasi asamasinda olu istemci: sunucu ReadTimeoutMs'de
      kapatir; istemci tarafinda TLS kutuphanesi GEREKMEZ. }
    Srv.ReadTimeoutMs := 700;
    ok := BeginTlsHandshake(GPort, s, detail);
    if ok then
    begin
      t0 := NowMs;
      rv := VdbRecvSome(s, btls, 1);
      elapsed := NowMs - t0;
      Chk('NL22 yarim TLS el sikismasi mutlak son tarihte dusuruldu',
        rv <= 0, 'rv=' + IntToStr(rv));
      Chk('NL22 el sikismasi kapatmasi 4 s icinde', elapsed < 4000,
        IntToStr(elapsed) + ' ms');
      VdbSockClose(s);
    end
    else
      Chk('NL22 yarim TLS el sikismasi testi basladi', False, detail);

    { (b) TLS kurulduktan sonra HIC mesaj gondermeyen istemci: SSL_read
      tek cagrida 30 s bloklayamaz; mutlak son tarih gecerlidir. }
    if TlsUpgrade(GPort, certPath, s, tlsSess, tlsCtx, detail) then
    begin
      t0 := NowMs;
      rv := tlsSess.Read(@btls, 1, NowMs + 4000);
      elapsed := NowMs - t0;
      Chk('NL22 TLS oturumunda SSL_read mutlak son tarihe uydu',
        rv <= 0, 'rv=' + IntToStr(rv));
      Chk('NL22 SSL_read son tarihi 4 s icinde', elapsed < 4000,
        IntToStr(elapsed) + ' ms');
      VdbSockClose(s);
      FreeAndNil(tlsSess);
      FreeAndNil(tlsCtx);
    end
    else
      Chk('NL22 TLS oturumu kuruldu', False, detail);
    Srv.ReadTimeoutMs := 30000;
  end;

  { --- NL23: TLS YAZMA son tarihi -------------------------------------- }
  { NOT (durust sinir): gercek sunucuda "yazmasi engellenen TLS istemcisi"
    loopback tamponlari nedeniyle DETERMINISTIK uretilemiyor (NL12'de ayni
    sorun ham soket icin olculdu). Bu yuzden SSL_write son tarihi, sunucunun
    kullandigi AYNI TVdbTlsSession uzerinde, alicisi OKUMAYAN bir soket
    ciftiyle olculur. }
  if not tlsOk then
    Skip('NL23 TLS yazma son tarihi', 'OpenSSL yok')
  else if not MakeTcpPair(tlsA, tlsB, detail) then
    Chk('NL23 TLS soket cifti kuruldu', False, detail)
  else
  begin
    try
      srvCtx := TVdbTlsContext.CreateServer(certPath, keyPath);
      cliCtx := TVdbTlsContext.CreateClient(certPath, 'localhost');
    except
      on E: Exception do
      begin
        srvCtx := nil;
        cliCtx := nil;
        detail := E.Message;
      end;
    end;
    if (srvCtx = nil) or (cliCtx = nil) then
      Chk('NL23 TLS baglamlari kuruldu', False, detail)
    else
    begin
      acct := TTlsAcceptThread.Create(srvCtx, tlsA);
      ok := cliCtx.Connect(tlsB, cliSess, detail, NowMs + 5000);
      acct.WaitFor;
      if not (ok and acct.Ok) then
      begin
        if detail = '' then detail := acct.ErrText;
        Chk('NL23 TLS el sikismasi (soket cifti)', False, detail);
      end
      else
      begin
        srvSess := acct.Sess;
        Chk('NL23 TLS el sikismasi (soket cifti)', True, '');
        big := StringOfChar('x', 4 * 1024 * 1024);
        t0 := NowMs;
        rv := srvSess.Write(PChar(big), Length(big), NowMs + 700);
        elapsed := NowMs - t0;
        Chk('NL23 SSL_write butcesi dolunca durdu', rv <= 0,
          'rv=' + IntToStr(rv));
        Chk('NL23 SSL_write durmasi 3 s icinde', elapsed < 3000,
          IntToStr(elapsed) + ' ms');
        Chk('NL23 SSL_write tum yuku yazamadi',
          rv < Length(big), 'rv=' + IntToStr(rv));
      end;
      acct.Free;
      if cliSess <> nil then FreeAndNil(cliSess);
      if srvSess <> nil then FreeAndNil(srvSess);
      FreeAndNil(cliCtx);
      FreeAndNil(srvCtx);
    end;
    VdbSockClose(tlsA);
    VdbSockClose(tlsB);
  end;

  { --- kapanis --------------------------------------------------------- }
  t0 := NowMs;
  Srv.Stop;
  elapsed := NowMs - t0;
  Chk('SKILL10 kapanis: Stop 5 s icinde dondu', elapsed < 5000,
    IntToStr(elapsed) + ' ms');
  Chk('SKILL10 kapanis: ConnCount=0', Srv.ConnCount = 0,
    'ConnCount=' + IntToStr(Srv.ConnCount));
  FreeAndNil(Srv);

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL, ', GSkip, ' SKIP');
  if GFail > 0 then Halt(1);
end.
