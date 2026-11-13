unit VDbTrace;

{ M9 (2026-10-19): hafif, istege bagli OpenTelemetry-uyumlu span kaydi.

  Amac: parse/execute asamalarini gorunur kilmak. Varsayilan KAPALI;
  kapaliyken VDbTraceBegin nil doner ve ek maliyet yoktur.

  Kayitlar sabit kapasiteli halka tamponda tutulur (512 span). Disa
  aktarim icin iki govde uretilir:

    - VDbTraceGetJSON    : duz JSON dizisi (in-process tanilama)
    - VDbTraceGetOTLPJSON: OTLP/HTTP JSON (resourceSpans/scopeSpans/spans)

  VDbTraceExportOTLP bu govdeyi HTTP POST ile bir OTLP alicisina yollar
  (varsayilan http://127.0.0.1:4318/v1/traces). Ag cagrisi SENKRONDUR ve
  yalnizca cagiran isterse yapilir; SQL yolunda otomatik export YOKTUR.
  TLS yoktur: https yerine yerel toplayici/ters vekil kullanin. }

{$mode delphi}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TVDbTraceSpan = class
  private
    FTraceID, FSpanID, FParentID, FName: string;
    FStartNs: Int64;
    FAttrKeys: array[0..7] of string;
    FAttrVals: array[0..7] of string;
    FAttrCount: Integer;
  end;

procedure VDbTraceSetEnabled(const AValue: Boolean);
function VDbTraceGetEnabled: Boolean;
function VDbTraceBegin(const AName: string; AParent: TVDbTraceSpan): TVDbTraceSpan;
procedure VDbTraceSetAttr(ASpan: TVDbTraceSpan; const AKey, AValue: string);
procedure VDbTraceEnd(var ASpan: TVDbTraceSpan);
procedure VDbTraceClear;
function VDbTraceGetJSON: string;

{ Ayni halka tampondaki span'leri OTLP/HTTP JSON govdesine cevirir. }
function VDbTraceGetOTLPJSON: string;

{ OTLP endpoint'ini ayristirir. Bos girdi varsayilanlari dondurur:
  host=127.0.0.1, port=4318, yol=/v1/traces. Yalniz http semasi. }
function VdbParseOtlpEndpoint(const AEndpoint: string;
  out AHost, APath: string; out APort: Word): Boolean;

{ Govdeyi HTTP POST ile yollar. Yalnizca 2xx basaridir; hata metni AError. }
function VDbTraceExportOTLP(const AEndpoint: string;
  out AError: string): Boolean;

{ M9: 'sql.fetch' gibi cocuk span'leri o anki 'sql.execute' span'ine
  baglamak icin thread-local ebeveyn. VDbSql execute span'ini kurarken
  set eder; nil'a geri almayi unutmayin. }
procedure VDbTraceSetCurrent(ASpan: TVDbTraceSpan);
function VDbTraceBeginChild(const AName: string): TVDbTraceSpan;

implementation

uses
  DateUtils, Sockets, VDbNet;

const
  VDB_TRACE_CAP = 512;
  VDB_TRACE_MAX_ATTRS = 8;

type
  TVDbTraceAttr = record
    Key, Value: string;
  end;
  TVDbTraceRecord = record
    TraceID, SpanID, ParentID, Name: string;
    StartNs, EndNs: Int64;
    Attrs: array[0..VDB_TRACE_MAX_ATTRS - 1] of TVDbTraceAttr;
    AttrCount: Integer;
  end;

threadvar
  { M9: cocuk span'lerin ebeveyni (thread basina). }
  GTraceCurrent: TVDbTraceSpan;

var
  GTraceEnabled: Boolean = False;
  GTraceLock: TCriticalSection;
  GTraceRecords: array[0..VDB_TRACE_CAP - 1] of TVDbTraceRecord;
  GTraceHead: Integer = 0;
  GTraceCount: Integer = 0;
  GIDCounter: QWord = 0;

function NowUnixNano: Int64;
begin
  // OTel epoch: 1970-01-01 UTC, nanosaniye.
  Result := Round((LocalTimeToUniversal(Now) - 25569.0) * 86400.0 * 1000000000.0);
end;

function JsonEsc(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if Ord(c) < 32 then
        Result := Result + '\u' + IntToHex(Ord(c), 4)
      else
        Result := Result + c;
    end;
  end;
end;

procedure VDbTraceSetEnabled(const AValue: Boolean);
begin
  GTraceLock.Enter;
  try
    GTraceEnabled := AValue;
  finally
    GTraceLock.Leave;
  end;
end;

function VDbTraceGetEnabled: Boolean;
begin
  Result := GTraceEnabled;
end;

function VDbTraceBegin(const AName: string; AParent: TVDbTraceSpan): TVDbTraceSpan;
begin
  Result := nil;
  if not GTraceEnabled then Exit;
  Result := TVDbTraceSpan.Create;
  Result.FName := AName;
  Result.FStartNs := NowUnixNano;
  GTraceLock.Enter;
  try
    Inc(GIDCounter);
    Result.FSpanID := IntToHex(GIDCounter, 16);
    if AParent <> nil then
    begin
      Result.FTraceID := AParent.FTraceID;
      Result.FParentID := AParent.FSpanID;
    end
    else
    begin
      Result.FTraceID := IntToHex(Random(MaxInt), 8) +
        IntToHex(Random(MaxInt), 8) + IntToHex(GIDCounter, 16);
      Result.FParentID := '';
    end;
  finally
    GTraceLock.Leave;
  end;
end;

procedure VDbTraceSetCurrent(ASpan: TVDbTraceSpan);
begin
  GTraceCurrent := ASpan;
end;

function VDbTraceBeginChild(const AName: string): TVDbTraceSpan;
begin
  Result := VDbTraceBegin(AName, GTraceCurrent);
end;

procedure VDbTraceSetAttr(ASpan: TVDbTraceSpan; const AKey, AValue: string);
begin
  if ASpan = nil then Exit;
  if ASpan.FAttrCount >= VDB_TRACE_MAX_ATTRS then Exit;
  ASpan.FAttrKeys[ASpan.FAttrCount] := AKey;
  ASpan.FAttrVals[ASpan.FAttrCount] := AValue;
  Inc(ASpan.FAttrCount);
end;

procedure VDbTraceEnd(var ASpan: TVDbTraceSpan);
var
  rec: TVDbTraceRecord;
  i: Integer;
begin
  if ASpan = nil then Exit;
  rec.TraceID := ASpan.FTraceID;
  rec.SpanID := ASpan.FSpanID;
  rec.ParentID := ASpan.FParentID;
  rec.Name := ASpan.FName;
  rec.StartNs := ASpan.FStartNs;
  rec.EndNs := NowUnixNano;
  rec.AttrCount := ASpan.FAttrCount;
  for i := 0 to ASpan.FAttrCount - 1 do
  begin
    rec.Attrs[i].Key := ASpan.FAttrKeys[i];
    rec.Attrs[i].Value := ASpan.FAttrVals[i];
  end;
  GTraceLock.Enter;
  try
    GTraceRecords[GTraceHead] := rec;
    GTraceHead := (GTraceHead + 1) mod VDB_TRACE_CAP;
    if GTraceCount < VDB_TRACE_CAP then Inc(GTraceCount);
  finally
    GTraceLock.Leave;
  end;
  FreeAndNil(ASpan);
end;

procedure VDbTraceClear;
begin
  GTraceLock.Enter;
  try
    GTraceHead := 0;
    GTraceCount := 0;
  finally
    GTraceLock.Leave;
  end;
end;

function VDbTraceGetJSON: string;
var
  i, k, idx, a: Integer;
  rec: TVDbTraceRecord;
begin
  GTraceLock.Enter;
  try
    Result := '[';
    for k := 0 to GTraceCount - 1 do
    begin
      idx := (GTraceHead - GTraceCount + k + VDB_TRACE_CAP) mod VDB_TRACE_CAP;
      rec := GTraceRecords[idx];
      if k > 0 then Result := Result + ',';
      Result := Result + '{"traceId":"' + rec.TraceID + '"';
      Result := Result + ',"spanId":"' + rec.SpanID + '"';
      Result := Result + ',"parentSpanId":"' + rec.ParentID + '"';
      Result := Result + ',"name":"' + JsonEsc(rec.Name) + '"';
      Result := Result + ',"startTimeUnixNano":"' + IntToStr(rec.StartNs) + '"';
      Result := Result + ',"endTimeUnixNano":"' + IntToStr(rec.EndNs) + '"';
      Result := Result + ',"attributes":{';
      for a := 0 to rec.AttrCount - 1 do
      begin
        if a > 0 then Result := Result + ',';
        Result := Result + '"' + JsonEsc(rec.Attrs[a].Key) + '":"' +
          JsonEsc(rec.Attrs[a].Value) + '"';
      end;
      Result := Result + '}}';
    end;
    Result := Result + ']';
  finally
    GTraceLock.Leave;
  end;
end;

function VDbTraceGetOTLPJSON: string;
var
  k, idx, a: Integer;
  rec: TVDbTraceRecord;
  spans, one, attrs, parent: string;
begin
  GTraceLock.Enter;
  try
    spans := '';
    for k := 0 to GTraceCount - 1 do
    begin
      idx := (GTraceHead - GTraceCount + k + VDB_TRACE_CAP) mod VDB_TRACE_CAP;
      rec := GTraceRecords[idx];

      attrs := '';
      for a := 0 to rec.AttrCount - 1 do
      begin
        if a > 0 then attrs := attrs + ',';
        attrs := attrs + '{"key":"' + JsonEsc(rec.Attrs[a].Key) +
          '","value":{"stringValue":"' + JsonEsc(rec.Attrs[a].Value) + '"}}';
      end;

      { OTLP'de kok span'in parentSpanId alani BOS GONDERILMEZ. }
      parent := '';
      if rec.ParentID <> '' then
        parent := ',"parentSpanId":"' + LowerCase(rec.ParentID) + '"';

      one := '{"traceId":"' + LowerCase(rec.TraceID) + '"' +
        ',"spanId":"' + LowerCase(rec.SpanID) + '"' + parent +
        ',"name":"' + JsonEsc(rec.Name) + '"' +
        ',"kind":1' +
        ',"startTimeUnixNano":"' + IntToStr(rec.StartNs) + '"' +
        ',"endTimeUnixNano":"' + IntToStr(rec.EndNs) + '"' +
        ',"attributes":[' + attrs + ']}';

      if spans <> '' then spans := spans + ',';
      spans := spans + one;
    end;

    Result := '{"resourceSpans":[{"resource":{"attributes":[' +
      '{"key":"service.name","value":{"stringValue":"vdb"}}]},' +
      '"scopeSpans":[{"scope":{"name":"vdb.trace","version":"1.0"},' +
      '"spans":[' + spans + ']}]}]}';
  finally
    GTraceLock.Leave;
  end;
end;

function VdbParseOtlpEndpoint(const AEndpoint: string;
  out AHost, APath: string; out APort: Word): Boolean;
var
  s, scheme, portStr: string;
  p, v: Integer;
begin
  Result := False;
  AHost := '127.0.0.1';
  APort := 4318;
  APath := '/v1/traces';

  s := Trim(AEndpoint);
  if s = '' then Exit(True);

  p := Pos('://', s);
  if p > 0 then
  begin
    scheme := LowerCase(Copy(s, 1, p - 1));
    if scheme <> 'http' then Exit;   // TLS desteklenmiyor
    s := Copy(s, p + 3, Length(s));
  end;

  p := Pos('/', s);
  if p > 0 then
  begin
    APath := Copy(s, p, Length(s));
    s := Copy(s, 1, p - 1);
  end;

  p := Pos(':', s);
  if p > 0 then
  begin
    portStr := Copy(s, p + 1, Length(s));
    v := StrToIntDef(portStr, -1);
    if (v < 1) or (v > 65535) then Exit;
    APort := Word(v);
    s := Copy(s, 1, p - 1);
  end;

  if s = '' then Exit;
  AHost := s;
  Result := True;
end;

function VDbTraceExportOTLP(const AEndpoint: string;
  out AError: string): Boolean;
var
  host, path, body, req, resp, codeStr: string;
  port: Word;
  sock: TVdbSocket;
  buf: array[0..4095] of Char;
  n, p, code: Integer;
  {$IFDEF MSWINDOWS}
  rcvTo: DWORD;
  {$ENDIF}
begin
  Result := False;
  AError := '';
  if not VdbParseOtlpEndpoint(AEndpoint, host, path, port) then
  begin
    AError := 'gecersiz OTLP endpoint (yalniz http://host[:port][/yol])';
    Exit;
  end;

  body := VDbTraceGetOTLPJSON;
  req := 'POST ' + path + ' HTTP/1.1' + #13#10 +
    'Host: ' + host + ':' + IntToStr(port) + #13#10 +
    'Content-Type: application/json' + #13#10 +
    'Content-Length: ' + IntToStr(Length(body)) + #13#10 +
    'Connection: close' + #13#10 + #13#10 + body;

  sock := VdbTcpConnect(host, port);
  if sock = VDB_SOCK_INVALID then
  begin
    AError := 'OTLP alicisina baglanilamadi: ' + host + ':' + IntToStr(port);
    Exit;
  end;
  try
    {$IFDEF MSWINDOWS}
    rcvTo := 5000;
    fpsetsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, @rcvTo, SizeOf(rcvTo));
    {$ENDIF}
    if not VdbSendAll(sock, req[1], Length(req)) then
    begin
      AError := 'OTLP istegi gonderilemedi';
      Exit;
    end;
    resp := '';
    repeat
      n := VdbRecvSome(sock, buf[0], SizeOf(buf));
      if n > 0 then
      begin
        SetLength(resp, Length(resp) + n);
        Move(buf[0], resp[Length(resp) - n + 1], n);
      end;
    until n <= 0;
  finally
    VdbSockClose(sock);
  end;

  p := Pos(' ', resp);
  if p = 0 then
  begin
    AError := 'OTLP yaniti okunamadi';
    Exit;
  end;
  codeStr := Copy(resp, p + 1, 3);
  code := StrToIntDef(codeStr, 0);
  if (code >= 200) and (code < 300) then
    Result := True
  else
    AError := 'OTLP alicisi HTTP ' + codeStr + ' dondurdu';
end;

initialization
  Randomize;
  GTraceLock := TCriticalSection.Create;

finalization
  GTraceLock.Free;

end.
