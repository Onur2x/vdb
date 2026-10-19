unit VDbTrace;

{ M9 (2026-10-19): hafif, istege bagli OpenTelemetry-uyumlu span kaydi.

  Amac: parse/execute asamalarini gorunur kilmak. Varsayilan KAPALI;
  kapaliyken VDbTraceBegin nil doner ve ek maliyet yoktur.

  Kayitlar sabit kapasiteli halka tamponda tutulur (512 span). Disa
  aktarim icin VDbTraceGetJSON OTel span alanlarina yakin bir JSON
  dizisi uretir. Ag uzerinden OTLP export bu birimin kapsami disinda. }

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

implementation

uses
  DateUtils;

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

initialization
  Randomize;
  GTraceLock := TCriticalSection.Create;

finalization
  GTraceLock.Free;

end.
