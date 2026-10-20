unit VDbParquet;
{ M2: Parquet (dosya formati) disa/ice aktarma.

  Bu birim, motorun skaler tiplerini kapsayan **duz (flat)** Parquet
  dosyalarini okur/yazar. Dis bagimlilik yoktur:
  - Thrift Compact Protocol (metadata)
  - PLAIN / RLE-bitpacked / dictionary sayfa kodlayicilari
  - Sikistirma: yalniz UNCOMPRESSED

  Tip eslemesi:
    INT      -> INT64
    FLOAT    -> DOUBLE
    BOOL     -> BOOLEAN
    TEXT     -> BYTE_ARRAY (UTF8)
    BLOB     -> BYTE_ARRAY
    DATE     -> INT32 (DATE)
    DATETIME -> INT64 (TIMESTAMP_MILLIS)
    TIME     -> INT32 (TIME_MILLIS)

  Okuyucu ayrica pyarrow'un yazdigi dictionary sayfalarini, DataPage v1/v2
  ve INT96 zaman damgalarini da cozer. Nested/repeated alanlar reddedilir. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, Math, VDbTypes, VDbTable;

function VDbParquetExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;

function VDbParquetImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;

implementation

const
  // Parquet Type
  PT_BOOLEAN = 0;
  PT_INT32 = 1;
  PT_INT64 = 2;
  PT_INT96 = 3;
  PT_FLOAT = 4;
  PT_DOUBLE = 5;
  PT_BYTE_ARRAY = 6;
  PT_FIXED = 7;

  // ConvertedType
  CT_UTF8 = 0;
  CT_DATE = 6;
  CT_TIME_MILLIS = 7;
  CT_TIME_MICROS = 8;
  CT_TIMESTAMP_MILLIS = 9;
  CT_TIMESTAMP_MICROS = 10;
  CT_INT_64 = 18;
  CT_JSON = 19;
  CT_BSON = 20;

  // FieldRepetitionType
  REP_REQUIRED = 0;
  REP_OPTIONAL = 1;
  REP_REPEATED = 2;

  // Encoding
  ENC_PLAIN = 0;
  ENC_PLAIN_DICTIONARY = 2;
  ENC_RLE = 3;
  ENC_BIT_PACKED = 4;
  ENC_RLE_DICTIONARY = 8;

  // CompressionCodec
  CODEC_UNCOMPRESSED = 0;
  CODEC_SNAPPY = 1;

  // PageType
  PAGE_DATA = 0;
  PAGE_INDEX = 1;
  PAGE_DICTIONARY = 2;
  PAGE_DATA_V2 = 3;

  // Thrift Compact types
  TT_STOP = 0;
  TT_TRUE = 1;
  TT_FALSE = 2;
  TT_BYTE = 3;
  TT_I16 = 4;
  TT_I32 = 5;
  TT_I64 = 6;
  TT_DOUBLE = 7;
  TT_BINARY = 8;
  TT_LIST = 9;
  TT_SET = 10;
  TT_MAP = 11;
  TT_STRUCT = 12;

type
  TThriftWriter = class
  private
    FBuf: TBytes;
    FLen: Integer;
    FLast: array of SmallInt;
    FDepth: Integer;
    procedure Need(N: Integer);
    procedure PutB(B: Byte);
    procedure Varint(V: QWord);
    procedure ZigZag(V: Int64);
  public
    constructor Create;
    function Finish: TBytes;
    procedure BeginStruct;
    procedure EndStruct;
    procedure Field(Id: Integer; Typ: Byte);
    procedure WriteBoolField(Id: Integer; V: Boolean);
    procedure WriteI32Field(Id: Integer; V: Integer);
    procedure WriteI64Field(Id: Integer; V: Int64);
    procedure WriteBinaryField(Id: Integer; const S: string);
    procedure ListHeader(ElemType: Byte; Count: Integer);
    procedure WriteI32Value(V: Integer);
    procedure WriteI64Value(V: Int64);
    procedure WriteBinaryValue(const S: string);
  end;

  TThriftReader = class
  private
    FData: TBytes;
    FPos: Integer;
    FLimit: Integer;
    FLast: array of Integer;
    FDepth: Integer;
    procedure Need(N: Integer);
    function GetB: Byte;
    function Varint: QWord;
    function ZigZag: Int64;
  public
    constructor Create(const Data: TBytes; Pos, Len: Integer);
    property Pos: Integer read FPos;
    procedure Push;
    procedure Pop;
    function ReadField(out Id: Integer; out Typ: Byte): Boolean;
    function ReadI32: Integer;
    function ReadI64: Int64;
    function ReadBinary: string;
    function ReadListHeader(out ElemType: Byte; out Count: Integer): Boolean;
    procedure Skip(Typ: Byte);
  end;

  TParquetSchemaElem = record
    Name: string;
    PType: Integer;
    Repetition: Integer;
    Converted: Integer;
    NumChildren: Integer;
    LogicalKind: Integer;   // 1=STRING, 6=DATE, 7=TIME, 8=TIMESTAMP, 10=INT
    LogicalUnit: Integer;   // 1=millis, 2=micros, 3=nanos
  end;

  TParquetColumnMeta = record
    PType: Integer;
    Codec: Integer;
    NumValues: Int64;
    DataPageOffset: Int64;
    DictPageOffset: Int64;
    TotalCompressed: Int64;
    TotalUncompressed: Int64;
    Encodings: array of Integer;
    Path: TStrArray;
  end;

  TParquetRowGroup = record
    NumRows: Int64;
    Columns: array of TParquetColumnMeta;
  end;

  TParquetMeta = record
    NumRows: Int64;
    Schema: array of TParquetSchemaElem;
    RowGroups: array of TParquetRowGroup;
  end;

  TColWrite = record
    Name: string;
    PType: Integer;
    Converted: Integer;
    LogicalKind: Integer;
    LogicalUnit: Integer;
    VType: Byte;
    DataOffset: Int64;
    TotalSize: Int64;
    NumValues: Int64;
  end;

  TPageHeader = record
    PageType: Integer;
    Uncompressed: Integer;
    Compressed: Integer;
    // DataPage v1
    DataNumValues: Integer;
    DataEncoding: Integer;
    DefEncoding: Integer;
    RepEncoding: Integer;
    // Dictionary page
    DictNumValues: Integer;
    DictEncoding: Integer;
    // DataPage v2
    V2NumValues: Integer;
    V2NumNulls: Integer;
    V2NumRows: Integer;
    V2Encoding: Integer;
    V2DefLen: Integer;
    V2RepLen: Integer;
    V2IsCompressed: Boolean;
  end;

  TInt64Arr = array of Int64;

{ ------------------------------------------------------------ Thrift yaz }

constructor TThriftWriter.Create;
begin
  inherited Create;
  SetLength(FBuf, 256);
  FLen := 0;
  FDepth := 0;
end;

procedure TThriftWriter.Need(N: Integer);
var
  cap: Integer;
begin
  if FLen + N <= Length(FBuf) then Exit;
  cap := Length(FBuf) * 2;
  if cap < FLen + N + 64 then cap := FLen + N + 64;
  SetLength(FBuf, cap);
end;

procedure TThriftWriter.PutB(B: Byte);
begin
  Need(1);
  FBuf[FLen] := B;
  Inc(FLen);
end;

procedure TThriftWriter.Varint(V: QWord);
begin
  while V >= $80 do
  begin
    PutB(Byte(V) or $80);
    V := V shr 7;
  end;
  PutB(Byte(V));
end;

procedure TThriftWriter.ZigZag(V: Int64);
begin
  Varint((QWord(V) shl 1) xor QWord(V shr 63));
end;

function TThriftWriter.Finish: TBytes;
begin
  Result := nil;
  SetLength(Result, FLen);
  if FLen > 0 then
    Move(FBuf[0], Result[0], FLen);
end;

procedure TThriftWriter.BeginStruct;
begin
  Inc(FDepth);
  SetLength(FLast, FDepth);
  FLast[FDepth - 1] := 0;
end;

procedure TThriftWriter.EndStruct;
begin
  if FDepth <= 0 then Exit;
  PutB(TT_STOP);
  Dec(FDepth);
end;

procedure TThriftWriter.Field(Id: Integer; Typ: Byte);
var
  d: Integer;
begin
  if FDepth <= 0 then
    raise Exception.Create('Thrift: struct disinda alan');
  d := Id - FLast[FDepth - 1];
  if (d > 0) and (d <= 15) then
    PutB(Byte((d shl 4) or Typ))
  else
  begin
    PutB(Typ);
    ZigZag(Id);
  end;
  FLast[FDepth - 1] := Id;
end;

procedure TThriftWriter.WriteBoolField(Id: Integer; V: Boolean);
begin
  if V then
    Field(Id, TT_TRUE)
  else
    Field(Id, TT_FALSE);
end;

procedure TThriftWriter.WriteI32Field(Id: Integer; V: Integer);
begin
  Field(Id, TT_I32);
  ZigZag(V);
end;

procedure TThriftWriter.WriteI64Field(Id: Integer; V: Int64);
begin
  Field(Id, TT_I64);
  ZigZag(V);
end;

procedure TThriftWriter.WriteBinaryField(Id: Integer; const S: string);
begin
  Field(Id, TT_BINARY);
  WriteBinaryValue(S);
end;

procedure TThriftWriter.ListHeader(ElemType: Byte; Count: Integer);
begin
  if Count < 15 then
    PutB(Byte((Count shl 4) or ElemType))
  else
  begin
    PutB(Byte($F0 or ElemType));
    Varint(Count);
  end;
end;

procedure TThriftWriter.WriteI32Value(V: Integer);
begin
  ZigZag(V);
end;

procedure TThriftWriter.WriteI64Value(V: Int64);
begin
  ZigZag(V);
end;

procedure TThriftWriter.WriteBinaryValue(const S: string);
var
  i: Integer;
begin
  Varint(Length(S));
  Need(Length(S));
  for i := 1 to Length(S) do
  begin
    FBuf[FLen] := Byte(S[i]);
    Inc(FLen);
  end;
end;

{ ----------------------------------------------------------- Thrift oku }

constructor TThriftReader.Create(const Data: TBytes; Pos, Len: Integer);
begin
  inherited Create;
  if (Pos < 0) or (Len < 0) or (Pos + Len > Length(Data)) then
    raise Exception.Create('Thrift: gecersiz aralik');
  FData := Data;
  FPos := Pos;
  FLimit := Pos + Len;
  FDepth := 0;
end;

procedure TThriftReader.Need(N: Integer);
begin
  if FPos + N > FLimit then
    raise Exception.Create('Thrift: veri bitti');
end;

function TThriftReader.GetB: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TThriftReader.Varint: QWord;
var
  shift: Integer;
  b: Byte;
begin
  Result := 0;
  shift := 0;
  repeat
    b := GetB;
    Result := Result or (QWord(b and $7F) shl shift);
    Inc(shift, 7);
    if shift > 63 then
      raise Exception.Create('Thrift: varint tasmasi');
  until (b and $80) = 0;
end;

function TThriftReader.ZigZag: Int64;
var
  v: QWord;
begin
  v := Varint;
  Result := Int64((v shr 1) xor (0 - (v and 1)));
end;

procedure TThriftReader.Push;
begin
  Inc(FDepth);
  SetLength(FLast, FDepth);
  FLast[FDepth - 1] := 0;
end;

procedure TThriftReader.Pop;
begin
  if FDepth > 0 then Dec(FDepth);
end;

function TThriftReader.ReadField(out Id: Integer; out Typ: Byte): Boolean;
var
  b: Byte;
  d: Integer;
begin
  if FDepth <= 0 then
    raise Exception.Create('Thrift: struct disinda alan');
  b := GetB;
  if b = TT_STOP then
  begin
    Id := 0;
    Typ := TT_STOP;
    Exit(False);
  end;
  Typ := b and $0F;
  d := b shr 4;
  if d = 0 then
    Id := Integer(ZigZag)
  else
    Id := FLast[FDepth - 1] + d;
  FLast[FDepth - 1] := Id;
  Result := True;
end;

function TThriftReader.ReadI32: Integer;
begin
  Result := Integer(ZigZag);
end;

function TThriftReader.ReadI64: Int64;
begin
  Result := ZigZag;
end;

function TThriftReader.ReadBinary: string;
var
  n: Integer;
begin
  n := Integer(Varint);
  Need(n);
  SetLength(Result, n);
  if n > 0 then
    Move(FData[FPos], Result[1], n);
  Inc(FPos, n);
end;

function TThriftReader.ReadListHeader(out ElemType: Byte; out Count: Integer): Boolean;
var
  b: Byte;
begin
  b := GetB;
  ElemType := b and $0F;
  Count := b shr 4;
  if Count = 15 then
  begin
    Count := Integer(Varint);
    if Count < 0 then
      raise Exception.Create('Thrift: gecersiz liste boyu');
  end;
  Result := True;
end;

procedure TThriftReader.Skip(Typ: Byte);
var
  n, i: Integer;
  et: Byte;
  kt, vt: Byte;
  sz: Integer;
begin
  case Typ of
    TT_TRUE, TT_FALSE:
      ;
    TT_BYTE:
      GetB;
    TT_I16, TT_I32, TT_I64:
      Varint;
    TT_DOUBLE:
      begin
        Need(8);
        Inc(FPos, 8);
      end;
    TT_BINARY:
      begin
        n := Integer(Varint);
        Need(n);
        Inc(FPos, n);
      end;
    TT_LIST, TT_SET:
      begin
        ReadListHeader(et, n);
        for i := 1 to n do
          Skip(et);
      end;
    TT_MAP:
      begin
        sz := Integer(Varint);
        if sz > 0 then
        begin
          kt := GetB;
          vt := kt and $0F;
          kt := kt shr 4;
          for i := 1 to sz do
          begin
            Skip(kt);
            Skip(vt);
          end;
        end;
      end;
    TT_STRUCT:
      begin
        Push;
        while ReadField(i, et) do
          Skip(et);
        Pop;
      end;
  else
    raise Exception.CreateFmt('Thrift: bilinmeyen tip %d', [Typ]);
  end;
end;

{ --------------------------------------------------------------- yardim }

function LE32(const B: TBytes; P: Integer): LongWord;
begin
  Result := LongWord(B[P]) or (LongWord(B[P + 1]) shl 8) or
            (LongWord(B[P + 2]) shl 16) or (LongWord(B[P + 3]) shl 24);
end;

function LE64(const B: TBytes; P: Integer): Int64;
begin
  Result := Int64(LongWord(B[P]) or (LongWord(B[P + 1]) shl 8) or
                  (LongWord(B[P + 2]) shl 16) or (LongWord(B[P + 3]) shl 24));
  Result := Result or (Int64(LongWord(B[P + 4]) or (LongWord(B[P + 5]) shl 8) or
                  (LongWord(B[P + 6]) shl 16) or (LongWord(B[P + 7]) shl 24)) shl 32);
end;

procedure BufI32(var B: TBytes; V: Integer);
var
  L: Integer;
  U: LongWord;
begin
  L := Length(B);
  SetLength(B, L + 4);
  U := LongWord(V);
  B[L] := Byte(U);
  B[L + 1] := Byte(U shr 8);
  B[L + 2] := Byte(U shr 16);
  B[L + 3] := Byte(U shr 24);
end;

procedure BufI64(var B: TBytes; V: Int64);
var
  L: Integer;
  U: QWord;
begin
  L := Length(B);
  SetLength(B, L + 8);
  U := QWord(V);
  B[L] := Byte(U);
  B[L + 1] := Byte(U shr 8);
  B[L + 2] := Byte(U shr 16);
  B[L + 3] := Byte(U shr 24);
  B[L + 4] := Byte(U shr 32);
  B[L + 5] := Byte(U shr 40);
  B[L + 6] := Byte(U shr 48);
  B[L + 7] := Byte(U shr 56);
end;

procedure BufDouble(var B: TBytes; V: Double);
var
  L: Integer;
begin
  L := Length(B);
  SetLength(B, L + 8);
  Move(V, B[L], 8);
end;

procedure BufByteArray(var B: TBytes; const S: string);
var
  L, N: Integer;
begin
  N := Length(S);
  BufI32(B, N);
  if N > 0 then
  begin
    L := Length(B);
    SetLength(B, L + N);
    Move(S[1], B[L], N);
  end;
end;

function ReadVarintBuf(const B: TBytes; var P: Integer): QWord;
var
  shift: Integer;
  c: Byte;
begin
  Result := 0;
  shift := 0;
  repeat
    if P >= Length(B) then
      raise Exception.Create('RLE: veri bitti');
    c := B[P];
    Inc(P);
    Result := Result or (QWord(c and $7F) shl shift);
    Inc(shift, 7);
    if shift > 63 then
      raise Exception.Create('RLE: varint tasmasi');
  until (c and $80) = 0;
end;

function ReadLEWidth(const B: TBytes; var P: Integer; Width: Integer): QWord;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to Width - 1 do
  begin
    if P >= Length(B) then
      raise Exception.Create('RLE: veri bitti');
    Result := Result or (QWord(B[P]) shl (8 * i));
    Inc(P);
  end;
end;

function SnappyDecompress(const Src: TBytes; out Dst: TBytes): Boolean;
var
  ip, op, n, len, offset, nb, i: Integer;
  tag: Byte;
begin
  Result := False;
  Dst := nil;
  ip := 0;
  if Length(Src) = 0 then Exit;
  n := Integer(ReadVarintBuf(Src, ip));
  if n < 0 then Exit;
  SetLength(Dst, n);
  op := 0;
  while ip < Length(Src) do
  begin
    tag := Src[ip];
    Inc(ip);
    case tag and 3 of
      0:
        begin
          len := tag shr 2;
          if len < 60 then
            Inc(len)
          else
          begin
            nb := len - 59;
            if ip + nb > Length(Src) then Exit;
            len := 0;
            for i := 0 to nb - 1 do
              len := len or (Integer(Src[ip + i]) shl (8 * i));
            Inc(ip, nb);
            Inc(len);
          end;
          if (len < 0) or (ip + len > Length(Src)) or (op + len > Length(Dst)) then Exit;
          if len > 0 then
            Move(Src[ip], Dst[op], len);
          Inc(ip, len);
          Inc(op, len);
        end;
      1:
        begin
          len := ((tag shr 2) and 7) + 4;
          if ip >= Length(Src) then Exit;
          offset := ((tag shr 5) shl 8) or Src[ip];
          Inc(ip);
          if (offset <= 0) or (offset > op) or (op + len > Length(Dst)) then Exit;
          for i := 1 to len do
          begin
            Dst[op] := Dst[op - offset];
            Inc(op);
          end;
        end;
      2:
        begin
          len := (tag shr 2) + 1;
          if ip + 2 > Length(Src) then Exit;
          offset := Integer(Src[ip]) or (Integer(Src[ip + 1]) shl 8);
          Inc(ip, 2);
          if (offset <= 0) or (offset > op) or (op + len > Length(Dst)) then Exit;
          for i := 1 to len do
          begin
            Dst[op] := Dst[op - offset];
            Inc(op);
          end;
        end;
      3:
        begin
          len := (tag shr 2) + 1;
          if ip + 4 > Length(Src) then Exit;
          offset := Integer(Src[ip]) or (Integer(Src[ip + 1]) shl 8) or
                    (Integer(Src[ip + 2]) shl 16) or (Integer(Src[ip + 3]) shl 24);
          Inc(ip, 4);
          if (offset <= 0) or (offset > op) or (op + len > Length(Dst)) then Exit;
          for i := 1 to len do
          begin
            Dst[op] := Dst[op - offset];
            Inc(op);
          end;
        end;
    end;
  end;
  Result := op = Length(Dst);
end;

function DecodeRle(const B: TBytes; var P: Integer; BitWidth: Integer;
  Count: Integer): TInt64Arr;
var
  outN: Integer;
  hdr: QWord;
  run, groups, g, bi, v, bitPos, base, total: Integer;
  widthBytes: Integer;
  val: QWord;
begin
  Result := nil;
  SetLength(Result, Count);
  if BitWidth = 0 then
  begin
    for outN := 0 to Count - 1 do Result[outN] := 0;
    Exit;
  end;
  outN := 0;
  while outN < Count do
  begin
    hdr := ReadVarintBuf(B, P);
    if (hdr and 1) = 0 then
    begin
      run := Integer(hdr shr 1);
      widthBytes := (BitWidth + 7) div 8;
      val := ReadLEWidth(B, P, widthBytes);
      for bi := 1 to run do
      begin
        if outN >= Count then Break;
        Result[outN] := Int64(val);
        Inc(outN);
      end;
    end
    else
    begin
      groups := Integer(hdr shr 1);
      if groups <= 0 then Break;
      total := groups * 8;
      base := P;
      if base + groups * BitWidth > Length(B) then
        raise Exception.Create('RLE: bit-packed veri bitti');
      for g := 0 to total - 1 do
      begin
        if outN >= Count then Break;
        v := 0;
        bitPos := g * BitWidth;
        for bi := 0 to BitWidth - 1 do
          v := v or (((B[base + (bitPos + bi) div 8] shr ((bitPos + bi) mod 8)) and 1) shl bi);
        Result[outN] := v;
        Inc(outN);
      end;
      Inc(P, groups * BitWidth);
    end;
  end;
end;

function EncodeDefLevels(const Bits: TBytes; Count: Integer): TBytes;
var
  groups, g, b, L: Integer;
  enc: TBytes;
  byt: Byte;
begin
  Result := nil;
  if Count <= 0 then
  begin
    SetLength(Result, 4);
    FillChar(Result[0], 4, 0);
    Exit;
  end;
  groups := (Count + 7) div 8;
  SetLength(enc, 0);
  // bit-packed header: (groups << 1) | 1
  L := groups shl 1 or 1;
  while L >= $80 do
  begin
    SetLength(enc, Length(enc) + 1);
    enc[High(enc)] := Byte(L) or $80;
    L := L shr 7;
  end;
  SetLength(enc, Length(enc) + 1);
  enc[High(enc)] := Byte(L);
  SetLength(enc, Length(enc) + groups);
  for g := 0 to groups - 1 do
  begin
    byt := 0;
    for b := 0 to 7 do
    begin
      if (g * 8 + b < Count) and ((g * 8 + b) div 8 < Length(Bits)) and
         (((Bits[(g * 8 + b) div 8] shr ((g * 8 + b) mod 8)) and 1) <> 0) then
        byt := byt or (1 shl b);
    end;
    enc[Length(enc) - groups + g] := byt;
  end;
  SetLength(Result, Length(enc) + 4);
  FillChar(Result[0], 4, 0);
  L := Length(enc);
  Result[0] := Byte(L);
  Result[1] := Byte(L shr 8);
  Result[2] := Byte(L shr 16);
  Result[3] := Byte(L shr 24);
  if Length(enc) > 0 then
    Move(enc[0], Result[4], Length(enc));
end;

{ --------------------------------------------------------- tip donusum }

function DateStrFromDays(Days: Int64): string;
begin
  Result := FormatDateTime('yyyy-mm-dd', EncodeDate(1970, 1, 1) + Days);
end;

function TimeStrFromMillis(MS: Int64): string;
var
  secs: Int64;
begin
  secs := MS div 1000;
  if secs < 0 then secs := 0;
  Result := FormatDateTime('hh:nn:ss', secs / 86400.0);
end;

function TimestampStr(Value: Int64; UnitKind: Integer): string;
var
  secs: Int64;
begin
  case UnitKind of
    1: secs := Value div 1000;
    2: secs := Value div 1000000;
    3: secs := Value div 1000000000;
  else
    secs := Value div 1000;
  end;
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    EncodeDate(1970, 1, 1) + secs / 86400.0);
end;

function TryDateDays(const S: string; out Days: Int64): Boolean;
var
  d: TDateTime;
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DateSeparator := '-';
  fs.ShortDateFormat := 'yyyy-mm-dd';
  Result := TryStrToDate(S, d, fs);
  if not Result then Result := TryStrToDate(S, d);
  if Result then
    Days := Round(d - EncodeDate(1970, 1, 1));
end;

function TryTimeSecs(const S: string; out Secs: Int64): Boolean;
var
  d: TDateTime;
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.TimeSeparator := ':';
  fs.LongTimeFormat := 'hh:nn:ss';
  Result := TryStrToTime(S, d, fs);
  if not Result then Result := TryStrToTime(S, d);
  if Result then
    Secs := Round(d * 86400.0);
end;

function TryDateTimeSecs(const S: string; out Secs: Int64): Boolean;
var
  d: TDateTime;
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DateSeparator := '-';
  fs.TimeSeparator := ':';
  fs.ShortDateFormat := 'yyyy-mm-dd';
  fs.LongTimeFormat := 'hh:nn:ss';
  Result := TryStrToDateTime(S, d, fs);
  if not Result then Result := TryStrToDateTime(S, d);
  if Result then
    Secs := Round((d - EncodeDate(1970, 1, 1)) * 86400.0);
end;

function FloatFromStr(const S: string): Double;
var
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  Result := StrToFloat(S, fs);
end;

function LogicalFromConverted(C: Integer): Integer;
begin
  case C of
    CT_UTF8, CT_JSON, CT_BSON: Result := 1;
    CT_DATE: Result := 6;
    CT_TIME_MILLIS, CT_TIME_MICROS: Result := 7;
    CT_TIMESTAMP_MILLIS, CT_TIMESTAMP_MICROS: Result := 8;
    CT_INT_64: Result := 10;
  else
    Result := 0;
  end;
end;

function UnitFromConverted(C: Integer): Integer;
begin
  case C of
    CT_TIME_MICROS, CT_TIMESTAMP_MICROS: Result := 2;
  else
    Result := 1;
  end;
end;

{ -------------------------------------------------------- Parquet meta oku }

procedure ParseTimeUnit(R: TThriftReader; var UnitKind: Integer);
var
  id: Integer;
  t: Byte;
begin
  R.Push;
  while R.ReadField(id, t) do
  begin
    if (id >= 1) and (id <= 3) and (t = TT_STRUCT) then
    begin
      UnitKind := id;
      R.Skip(t);
    end
    else
      R.Skip(t);
  end;
  R.Pop;
end;

procedure ParseTimeType(R: TThriftReader; var UnitKind: Integer);
var
  id: Integer;
  t: Byte;
begin
  R.Push;
  while R.ReadField(id, t) do
  begin
    if (id = 2) and (t = TT_STRUCT) then
      ParseTimeUnit(R, UnitKind)
    else
      R.Skip(t);
  end;
  R.Pop;
end;

procedure ParseLogicalType(R: TThriftReader; var Kind, UnitKind: Integer);
var
  id: Integer;
  t: Byte;
begin
  Kind := 0;
  UnitKind := 1;
  R.Push;
  while R.ReadField(id, t) do
  begin
    if (t = TT_STRUCT) and ((id = 1) or (id = 6) or (id = 10)) then
    begin
      Kind := id;
      R.Skip(t);
    end
    else if (t = TT_STRUCT) and ((id = 7) or (id = 8)) then
    begin
      Kind := id;
      ParseTimeType(R, UnitKind);
    end
    else
      R.Skip(t);
  end;
  R.Pop;
end;

procedure ParseSchemaElem(R: TThriftReader; var SE: TParquetSchemaElem);
var
  id: Integer;
  t: Byte;
  lk, lu: Integer;
begin
  SE.Name := '';
  SE.PType := -1;
  SE.Repetition := -1;
  SE.Converted := -1;
  SE.NumChildren := 0;
  SE.LogicalKind := 0;
  SE.LogicalUnit := 1;
  R.Push;
  while R.ReadField(id, t) do
  begin
    case id of
      1: SE.PType := R.ReadI32;
      2: R.Skip(t);
      3: SE.Repetition := R.ReadI32;
      4: SE.Name := R.ReadBinary;
      5: SE.NumChildren := R.ReadI32;
      6: SE.Converted := R.ReadI32;
      10:
        begin
          ParseLogicalType(R, lk, lu);
          SE.LogicalKind := lk;
          SE.LogicalUnit := lu;
        end;
    else
      R.Skip(t);
    end;
  end;
  R.Pop;
  if (SE.LogicalKind = 0) and (SE.Converted >= 0) then
  begin
    SE.LogicalKind := LogicalFromConverted(SE.Converted);
    if SE.LogicalKind = 7 then SE.LogicalUnit := UnitFromConverted(SE.Converted);
    if SE.LogicalKind = 8 then SE.LogicalUnit := UnitFromConverted(SE.Converted);
  end;
end;

procedure ParseColumnMeta(R: TThriftReader; var CM: TParquetColumnMeta);
var
  id, i, n: Integer;
  t: Byte;
  et: Byte;
begin
  CM.PType := -1;
  CM.Codec := 0;
  CM.NumValues := 0;
  CM.DataPageOffset := 0;
  CM.DictPageOffset := -1;
  CM.TotalCompressed := 0;
  CM.TotalUncompressed := 0;
  SetLength(CM.Encodings, 0);
  SetLength(CM.Path, 0);
  R.Push;
  while R.ReadField(id, t) do
  begin
    case id of
      1: CM.PType := R.ReadI32;
      2:
        begin
          R.ReadListHeader(et, n);
          SetLength(CM.Encodings, n);
          for i := 0 to n - 1 do
            CM.Encodings[i] := R.ReadI32;
        end;
      3:
        begin
          R.ReadListHeader(et, n);
          SetLength(CM.Path, n);
          for i := 0 to n - 1 do
            CM.Path[i] := R.ReadBinary;
        end;
      4: CM.Codec := R.ReadI32;
      5: CM.NumValues := R.ReadI64;
      6: CM.TotalUncompressed := R.ReadI64;
      7: CM.TotalCompressed := R.ReadI64;
      9: CM.DataPageOffset := R.ReadI64;
      11: CM.DictPageOffset := R.ReadI64;
    else
      R.Skip(t);
    end;
  end;
  R.Pop;
end;

procedure ParseColumnChunk(R: TThriftReader; var CM: TParquetColumnMeta);
var
  id: Integer;
  t: Byte;
begin
  CM.PType := -1;
  CM.Codec := 0;
  CM.NumValues := 0;
  CM.DataPageOffset := 0;
  CM.DictPageOffset := -1;
  CM.TotalCompressed := 0;
  CM.TotalUncompressed := 0;
  SetLength(CM.Encodings, 0);
  SetLength(CM.Path, 0);
  R.Push;
  while R.ReadField(id, t) do
  begin
    case id of
      2: R.Skip(t); // file_offset
      3: ParseColumnMeta(R, CM);
    else
      R.Skip(t);
    end;
  end;
  R.Pop;
end;

procedure ParseRowGroup(R: TThriftReader; var RG: TParquetRowGroup);
var
  id, i, n: Integer;
  t: Byte;
  et: Byte;
begin
  RG.NumRows := 0;
  SetLength(RG.Columns, 0);
  R.Push;
  while R.ReadField(id, t) do
  begin
    case id of
      1:
        begin
          R.ReadListHeader(et, n);
          SetLength(RG.Columns, n);
          for i := 0 to n - 1 do
            ParseColumnChunk(R, RG.Columns[i]);
        end;
      3: RG.NumRows := R.ReadI64;
    else
      R.Skip(t);
    end;
  end;
  R.Pop;
end;

procedure ParseFileMeta(const Data: TBytes; MetaStart, MetaLen: Integer;
  out Meta: TParquetMeta);
var
  R: TThriftReader;
  id, i, n: Integer;
  t: Byte;
  et: Byte;
begin
  Meta.NumRows := 0;
  SetLength(Meta.Schema, 0);
  SetLength(Meta.RowGroups, 0);
  R := TThriftReader.Create(Data, MetaStart, MetaLen);
  try
    R.Push;
    while R.ReadField(id, t) do
    begin
      case id of
        1: R.Skip(t);
        2:
          begin
            R.ReadListHeader(et, n);
            SetLength(Meta.Schema, n);
            for i := 0 to n - 1 do
              ParseSchemaElem(R, Meta.Schema[i]);
          end;
        3: Meta.NumRows := R.ReadI64;
        4:
          begin
            R.ReadListHeader(et, n);
            SetLength(Meta.RowGroups, n);
            for i := 0 to n - 1 do
              ParseRowGroup(R, Meta.RowGroups[i]);
          end;
      else
        R.Skip(t);
      end;
    end;
    R.Pop;
  finally
    R.Free;
  end;
end;

{ ------------------------------------------------------------ sayfa oku }

procedure ParsePageHeader(const Data: TBytes; Offset: Int64;
  out H: TPageHeader; out HeaderLen: Integer);
var
  R: TThriftReader;
  id, start: Integer;
  t: Byte;
  b: Byte;
begin
  FillChar(H, SizeOf(H), 0);
  H.V2IsCompressed := True;
  start := Integer(Offset);
  R := TThriftReader.Create(Data, start, Length(Data) - start);
  try
    R.Push;
    while R.ReadField(id, t) do
    begin
      case id of
        1: H.PageType := R.ReadI32;
        2: H.Uncompressed := R.ReadI32;
        3: H.Compressed := R.ReadI32;
        4: R.Skip(t);
        5:
          begin
            R.Push;
            while R.ReadField(id, t) do
            begin
              case id of
                1: H.DataNumValues := R.ReadI32;
                2: H.DataEncoding := R.ReadI32;
                3: H.DefEncoding := R.ReadI32;
                4: H.RepEncoding := R.ReadI32;
              else
                R.Skip(t);
              end;
            end;
            R.Pop;
          end;
        7:
          begin
            R.Push;
            while R.ReadField(id, t) do
            begin
              case id of
                1: H.DictNumValues := R.ReadI32;
                2: H.DictEncoding := R.ReadI32;
              else
                R.Skip(t);
              end;
            end;
            R.Pop;
          end;
        8:
          begin
            R.Push;
            while R.ReadField(id, t) do
            begin
              case id of
                1: H.V2NumValues := R.ReadI32;
                2: H.V2NumNulls := R.ReadI32;
                3: H.V2NumRows := R.ReadI32;
                4: H.V2Encoding := R.ReadI32;
                5: H.V2DefLen := R.ReadI32;
                6: H.V2RepLen := R.ReadI32;
                7:
                  begin
                    b := t;
                    H.V2IsCompressed := (b = TT_TRUE);
                  end;
              else
                R.Skip(t);
              end;
            end;
            R.Pop;
          end;
      else
        R.Skip(t);
      end;
    end;
    R.Pop;
    HeaderLen := R.Pos - start;
  finally
    R.Free;
  end;
end;

function ReadPlainI32(const B: TBytes; var P: Integer): Integer;
begin
  if P + 4 > Length(B) then raise Exception.Create('Parquet: INT32 veri bitti');
  Result := Integer(LE32(B, P));
  Inc(P, 4);
end;

function ReadPlainI64(const B: TBytes; var P: Integer): Int64;
begin
  if P + 8 > Length(B) then raise Exception.Create('Parquet: INT64 veri bitti');
  Result := LE64(B, P);
  Inc(P, 8);
end;

function ReadPlainDouble(const B: TBytes; var P: Integer): Double;
begin
  if P + 8 > Length(B) then raise Exception.Create('Parquet: DOUBLE veri bitti');
  Move(B[P], Result, 8);
  Inc(P, 8);
end;

function ReadPlainByteArray(const B: TBytes; var P: Integer): string;
var
  n: Integer;
begin
  if P + 4 > Length(B) then raise Exception.Create('Parquet: BYTE_ARRAY veri bitti');
  n := Integer(LE32(B, P));
  Inc(P, 4);
  if n < 0 then raise Exception.Create('Parquet: negatif BYTE_ARRAY boyu');
  if P + n > Length(B) then raise Exception.Create('Parquet: BYTE_ARRAY veri bitti');
  SetLength(Result, n);
  if n > 0 then
    Move(B[P], Result[1], n);
  Inc(P, n);
end;

function ReadPlainInt96(const B: TBytes; var P: Integer): string;
var
  nanos: Int64;
  julian: LongWord;
  days: Int64;
  secs: Int64;
begin
  if P + 12 > Length(B) then raise Exception.Create('Parquet: INT96 veri bitti');
  nanos := LE64(B, P);
  julian := LE32(B, P + 8);
  Inc(P, 12);
  days := Int64(julian) - 2440588;
  secs := days * 86400 + nanos div 1000000000;
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    EncodeDate(1970, 1, 1) + secs / 86400.0);
end;

function TimeValueStr(V: Int64; UnitKind: Integer): string;
begin
  if UnitKind = 2 then
    Result := TimeStrFromMillis(V div 1000)
  else
    Result := TimeStrFromMillis(V);
end;

function ValueToStr(PType, LogicalKind, LogicalUnit: Integer;
  IV: Int64; DV: Double; BV: Boolean; const SV: string): string;
begin
  case PType of
    PT_BOOLEAN:
      if BV then Result := 'true' else Result := 'false';
    PT_INT32:
      begin
        if LogicalKind = 6 then
          Result := DateStrFromDays(IV)
        else if LogicalKind = 7 then
          Result := TimeValueStr(IV, LogicalUnit)
        else
          Result := IntToStr(IV);
      end;
    PT_INT64:
      begin
        if LogicalKind = 8 then
          Result := TimestampStr(IV, LogicalUnit)
        else if LogicalKind = 7 then
          Result := TimeValueStr(IV, LogicalUnit)
        else
          Result := IntToStr(IV);
      end;
    PT_FLOAT, PT_DOUBLE:
      Result := VDbFloatToStr(DV);
    PT_BYTE_ARRAY:
      Result := SV;
  else
    Result := SV;
  end;
end;

{ --------------------------------------------------------- Parquet yaz }

function ParquetTypeOf(Ctype: Byte; out Converted, LogKind, LogUnit: Integer): Integer;
begin
  Converted := -1;
  LogKind := 0;
  LogUnit := 1;
  case Ctype of
    VCT_INT:
      begin
        Result := PT_INT64;
        Converted := CT_INT_64;
        LogKind := 0;
      end;
    VCT_FLOAT:
      Result := PT_DOUBLE;
    VCT_BOOL:
      Result := PT_BOOLEAN;
    VCT_DATE:
      begin
        Result := PT_INT32;
        Converted := CT_DATE;
        LogKind := 6;
      end;
    VCT_DATETIME:
      begin
        Result := PT_INT64;
        Converted := CT_TIMESTAMP_MILLIS;
        LogKind := 8;
        LogUnit := 1;
      end;
    VCT_TIME:
      begin
        Result := PT_INT32;
        Converted := CT_TIME_MILLIS;
        LogKind := 7;
        LogUnit := 1;
      end;
    VCT_BLOB:
      Result := PT_BYTE_ARRAY;
  else
    begin
      Result := PT_BYTE_ARRAY;
      Converted := CT_UTF8;
      LogKind := 1;
    end;
  end;
end;

procedure WriteLogicalType(W: TThriftWriter; Kind, UnitKind: Integer);
begin
  if Kind = 0 then Exit;
  W.Field(10, TT_STRUCT);
  W.BeginStruct;
  case Kind of
    1, 6:
      begin
        W.Field(Kind, TT_STRUCT);
        W.BeginStruct;
        W.EndStruct;
      end;
    7, 8:
      begin
        W.Field(Kind, TT_STRUCT);
        W.BeginStruct;
        W.WriteBoolField(1, False);
        W.Field(2, TT_STRUCT);
        W.BeginStruct;
        W.Field(UnitKind, TT_STRUCT);
        W.BeginStruct;
        W.EndStruct;
        W.EndStruct;
        W.EndStruct;
      end;
  end;
  W.EndStruct;
end;

function BuildPage(ColIdx: Integer; const Fields: TStrArray;
  const Types: TByteArray; const Rows: TStrMatrix;
  out Header, Body: TBytes): Boolean;
var
  bits, values, def: TBytes;
  n, i, present, boolPos: Integer;
  s: string;
  iv: Int64;
  dv: Double;
  byt: Byte;
  ptype: Integer;
  conv, lk, lu: Integer;
  W: TThriftWriter;
begin
  Result := False;
  n := Length(Rows);
  SetLength(bits, (n + 7) div 8);
  if Length(bits) > 0 then FillChar(bits[0], Length(bits), 0);
  SetLength(values, 0);
  present := 0;
  for i := 0 to n - 1 do
  begin
    s := '';
    if ColIdx < Length(Rows[i]) then s := Rows[i][ColIdx];
    if s <> '' then
    begin
      bits[i div 8] := bits[i div 8] or (1 shl (i mod 8));
      Inc(present);
    end;
  end;
  ptype := ParquetTypeOf(Types[ColIdx], conv, lk, lu);
  boolPos := 0;
  if ptype = PT_BOOLEAN then
  begin
    SetLength(values, (present + 7) div 8);
    if Length(values) > 0 then FillChar(values[0], Length(values), 0);
  end;
  for i := 0 to n - 1 do
  begin
    s := '';
    if ColIdx < Length(Rows[i]) then s := Rows[i][ColIdx];
    if s = '' then Continue;
    case ptype of
      PT_BOOLEAN:
        begin
          byt := 0;
          if s = '1' then byt := 1;
          if SameText(s, 'true') or SameText(s, 'yes') then byt := 1;
          if byt <> 0 then
            values[boolPos div 8] := values[boolPos div 8] or (1 shl (boolPos mod 8));
          Inc(boolPos);
        end;
      PT_INT32:
        begin
          if Types[ColIdx] = VCT_DATE then
          begin
            if not TryDateDays(s, iv) then
              raise Exception.Create('Parquet: gecersiz DATE: ' + s);
            BufI32(values, Integer(iv));
          end
          else if Types[ColIdx] = VCT_TIME then
          begin
            if not TryTimeSecs(s, iv) then
              raise Exception.Create('Parquet: gecersiz TIME: ' + s);
            BufI32(values, Integer(iv * 1000));
          end
          else
            BufI32(values, StrToInt(s));
        end;
      PT_INT64:
        begin
          if Types[ColIdx] = VCT_DATETIME then
          begin
            if not TryDateTimeSecs(s, iv) then
              raise Exception.Create('Parquet: gecersiz DATETIME: ' + s);
            BufI64(values, iv * 1000);
          end
          else
            BufI64(values, StrToInt64(s));
        end;
      PT_DOUBLE:
        begin
          dv := FloatFromStr(s);
          BufDouble(values, dv);
        end;
      PT_BYTE_ARRAY:
        BufByteArray(values, s);
    end;
  end;
  def := EncodeDefLevels(bits, n);
  SetLength(Body, Length(def) + Length(values));
  if Length(def) > 0 then Move(def[0], Body[0], Length(def));
  if Length(values) > 0 then Move(values[0], Body[Length(def)], Length(values));

  W := TThriftWriter.Create;
  try
    W.BeginStruct;
    W.WriteI32Field(1, PAGE_DATA);
    W.WriteI32Field(2, Length(Body));
    W.WriteI32Field(3, Length(Body));
    W.Field(5, TT_STRUCT);
    W.BeginStruct;
    W.WriteI32Field(1, n);
    W.WriteI32Field(2, ENC_PLAIN);
    W.WriteI32Field(3, ENC_RLE);
    W.WriteI32Field(4, ENC_RLE);
    W.EndStruct;
    W.EndStruct;
    Header := W.Finish;
  finally
    W.Free;
  end;
  Result := True;
end;

function BuildFileMeta(const Cols: array of TColWrite; NumRows: Int64): TBytes;
var
  W: TThriftWriter;
  i: Integer;
  total: Int64;
begin
  W := TThriftWriter.Create;
  try
    W.BeginStruct;
    W.WriteI32Field(1, 1); // version
    W.Field(2, TT_LIST);
    W.ListHeader(TT_STRUCT, Length(Cols) + 1);
    // root
    W.BeginStruct;
    W.WriteBinaryField(4, 'schema');
    W.WriteI32Field(5, Length(Cols));
    W.EndStruct;
    for i := 0 to High(Cols) do
    begin
      W.BeginStruct;
      W.WriteI32Field(1, Cols[i].PType);
      W.WriteI32Field(3, REP_OPTIONAL);
      W.WriteBinaryField(4, Cols[i].Name);
      if Cols[i].Converted >= 0 then
        W.WriteI32Field(6, Cols[i].Converted);
      WriteLogicalType(W, Cols[i].LogicalKind, Cols[i].LogicalUnit);
      W.EndStruct;
    end;

    W.WriteI64Field(3, NumRows);
    W.Field(4, TT_LIST);
    if NumRows > 0 then
    begin
      W.ListHeader(TT_STRUCT, 1);
      W.BeginStruct;
      W.Field(1, TT_LIST);
      W.ListHeader(TT_STRUCT, Length(Cols));
      total := 0;
      for i := 0 to High(Cols) do
      begin
        Inc(total, Cols[i].TotalSize);
        W.BeginStruct;
        W.WriteI64Field(2, Cols[i].DataOffset);
        W.Field(3, TT_STRUCT);
        W.BeginStruct;
        W.WriteI32Field(1, Cols[i].PType);
        W.Field(2, TT_LIST);
        W.ListHeader(TT_I32, 2);
        W.WriteI32Value(ENC_PLAIN);
        W.WriteI32Value(ENC_RLE);
        W.Field(3, TT_LIST);
        W.ListHeader(TT_BINARY, 1);
        W.WriteBinaryValue(Cols[i].Name);
        W.WriteI32Field(4, CODEC_UNCOMPRESSED);
        W.WriteI64Field(5, Cols[i].NumValues);
        W.WriteI64Field(6, Cols[i].TotalSize);
        W.WriteI64Field(7, Cols[i].TotalSize);
        W.WriteI64Field(9, Cols[i].DataOffset);
        W.EndStruct;
        W.EndStruct;
      end;
      W.WriteI64Field(2, total);
      W.WriteI64Field(3, NumRows);
      W.EndStruct;
    end
    else
      W.ListHeader(TT_STRUCT, 0);
    W.WriteBinaryField(6, 'VDb Parquet');
    W.EndStruct;
    Result := W.Finish;
  finally
    W.Free;
  end;
end;

function VDbParquetExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;
var
  fs: TFileStream;
  Cols: array of TColWrite;
  i, n: Integer;
  Header, Body, Meta: TBytes;
  Magic: array[0..3] of Char = ('P', 'A', 'R', '1');
  L: LongWord;
  conv, lk, lu: Integer;
begin
  Result := False;
  Err := '';
  try
    if Length(Fields) <> Length(Types) then
      raise Exception.Create('Parquet: alan/tip sayisi uyusmuyor');
    n := Length(Rows);
    for i := 0 to High(Rows) do
      if Length(Rows[i]) <> Length(Fields) then
        raise Exception.Create('Parquet: satir alan sayisi uyusmuyor');

    SetLength(Cols, Length(Fields));
    for i := 0 to High(Fields) do
    begin
      Cols[i].Name := Fields[i];
      Cols[i].PType := ParquetTypeOf(Types[i], conv, lk, lu);
      Cols[i].Converted := conv;
      Cols[i].LogicalKind := lk;
      Cols[i].LogicalUnit := lu;
      Cols[i].VType := Types[i];
      Cols[i].DataOffset := 4;
      Cols[i].TotalSize := 0;
      Cols[i].NumValues := n;
    end;

    fs := TFileStream.Create(FileName, fmCreate);
    try
      fs.WriteBuffer(Magic, 4);
      if n > 0 then
        for i := 0 to High(Cols) do
        begin
          if not BuildPage(i, Fields, Types, Rows, Header, Body) then
            raise Exception.Create('Parquet: sayfa olusturulamadi');
          Cols[i].DataOffset := fs.Position;
          if Length(Header) > 0 then fs.WriteBuffer(Header[0], Length(Header));
          if Length(Body) > 0 then fs.WriteBuffer(Body[0], Length(Body));
          Cols[i].TotalSize := Int64(Length(Header)) + Length(Body);
        end;
      Meta := BuildFileMeta(Cols, n);
      if Length(Meta) > 0 then fs.WriteBuffer(Meta[0], Length(Meta));
      L := LongWord(Length(Meta));
      fs.WriteBuffer(L, 4);
      fs.WriteBuffer(Magic, 4);
    finally
      fs.Free;
    end;
    Result := True;
  except
    on E: Exception do
      Err := E.Message;
  end;
end;

{ --------------------------------------------------------- Parquet oku }

function LeafKind(SE: TParquetSchemaElem): Integer;
begin
  // 0=int, 1=date, 2=time, 3=timestamp, 4=bool, 5=float, 6=str, 7=blob
  if SE.LogicalKind = 6 then Exit(1);
  if SE.LogicalKind = 7 then Exit(2);
  if SE.LogicalKind = 8 then Exit(3);
  if SE.PType = PT_BOOLEAN then Exit(4);
  if (SE.PType = PT_FLOAT) or (SE.PType = PT_DOUBLE) then Exit(5);
  if SE.PType = PT_BYTE_ARRAY then
  begin
    if (SE.LogicalKind = 1) or (SE.Converted = CT_UTF8) or
       (SE.Converted = CT_JSON) or (SE.Converted = CT_BSON) then
      Exit(6)
    else
      Exit(7);
  end;
  Result := 0;
end;

function VTypeOfLeaf(SE: TParquetSchemaElem): Byte;
begin
  case LeafKind(SE) of
    1: Result := VCT_DATE;
    2: Result := VCT_TIME;
    3: Result := VCT_DATETIME;
    4: Result := VCT_BOOL;
    5: Result := VCT_FLOAT;
    6: Result := VCT_STR;
    7: Result := VCT_BLOB;
  else
    Result := VCT_INT;
  end;
end;

procedure DecodeColumn(const Data: TBytes; const CM: TParquetColumnMeta;
  const SE: TParquetSchemaElem; GroupRows: Integer; out Values: TStrArray);
var
  off: Int64;
  H: TPageHeader;
  HL, BodyPos, BodyLen, p, i: Integer;
  body, rawBody, valRaw, valBody: TBytes;
  lvlLen: Integer;
  dict: TStrArray;
  levels: TInt64Arr;
  rowPos, seen: Integer;
  maxDef: Integer;
  defLen, defPos: Integer;
  encoding: Integer;
  nums: array of Int64;
  vals: array of Double;
  bools: array of Boolean;
  strs: array of string;
  int96: array of string;

  function DecodeDictPage(const B: TBytes; Count: Integer): TStrArray;
  var
    q, k: Integer;
    si: Int64;
    sd: Double;
    sb: Boolean;
    ss: string;
  begin
    Result := nil;
    SetLength(Result, Count);
    q := 0;
    for k := 0 to Count - 1 do
    begin
      case SE.PType of
        PT_BOOLEAN:
          begin
            if q div 8 >= Length(B) then raise Exception.Create('Parquet: bool sozluk bitti');
            sb := ((B[q div 8] shr (q mod 8)) and 1) <> 0;
            Inc(q);
            Result[k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, 0, 0, sb, '');
          end;
        PT_INT32:
          begin
            si := ReadPlainI32(B, q);
            Result[k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, si, 0, False, '');
          end;
        PT_INT64:
          begin
            si := ReadPlainI64(B, q);
            Result[k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, si, 0, False, '');
          end;
        PT_FLOAT, PT_DOUBLE:
          begin
            sd := ReadPlainDouble(B, q);
            Result[k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, 0, sd, False, '');
          end;
        PT_BYTE_ARRAY:
          begin
            ss := ReadPlainByteArray(B, q);
            Result[k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, 0, 0, False, ss);
          end;
        PT_INT96:
          begin
            ss := ReadPlainInt96(B, q);
            Result[k] := ss;
          end;
      else
        raise Exception.CreateFmt('Parquet: desteklenmeyen fiziksel tip %d', [SE.PType]);
      end;
    end;
  end;

  function PageBody(const Raw: TBytes; Expected: Integer): TBytes;
  begin
    Result := Raw;
    if CM.Codec = CODEC_UNCOMPRESSED then Exit;
    if CM.Codec <> CODEC_SNAPPY then
      raise Exception.CreateFmt('Parquet: sikistirma desteklenmiyor (codec=%d)', [CM.Codec]);
    if not SnappyDecompress(Raw, Result) then
      raise Exception.Create('Parquet: SNAPPY cozme hatasi');
    if (Expected >= 0) and (Length(Result) <> Expected) then
      raise Exception.Create('Parquet: SNAPPY boyu uyusmuyor');
  end;

  procedure ReadValues(const B: TBytes; var P: Integer; N: Integer;
    Enc: Integer; const DictArr: TStrArray);
  var
    k, bw: Integer;
    ind: TInt64Arr;
    bitPos: Integer;
  begin
    SetLength(nums, N);
    SetLength(vals, N);
    SetLength(bools, N);
    SetLength(strs, N);
    SetLength(int96, N);
    if Enc = ENC_PLAIN then
    begin
      case SE.PType of
        PT_BOOLEAN:
          begin
            bitPos := 0;
            for k := 0 to N - 1 do
            begin
              if P + (bitPos div 8) >= Length(B) then
                raise Exception.Create('Parquet: bool veri bitti');
              bools[k] := ((B[P + (bitPos div 8)] shr (bitPos mod 8)) and 1) <> 0;
              Inc(bitPos);
            end;
            Inc(P, (N + 7) div 8);
          end;
        PT_INT32:
          for k := 0 to N - 1 do nums[k] := ReadPlainI32(B, P);
        PT_INT64:
          for k := 0 to N - 1 do nums[k] := ReadPlainI64(B, P);
        PT_FLOAT, PT_DOUBLE:
          for k := 0 to N - 1 do vals[k] := ReadPlainDouble(B, P);
        PT_BYTE_ARRAY:
          for k := 0 to N - 1 do strs[k] := ReadPlainByteArray(B, P);
        PT_INT96:
          for k := 0 to N - 1 do int96[k] := ReadPlainInt96(B, P);
      else
        raise Exception.CreateFmt('Parquet: desteklenmeyen fiziksel tip %d', [SE.PType]);
      end;
    end
    else if Enc = ENC_RLE then
    begin
      if SE.PType <> PT_BOOLEAN then
        raise Exception.CreateFmt('Parquet: RLE kodlamasi yalniz BOOLEAN icin destekleniyor (tip=%d)', [SE.PType]);
      if P + 4 > Length(B) then
        raise Exception.Create('Parquet: RLE deger boyu yok');
      bitPos := Integer(LE32(B, P));
      Inc(P, 4);
      if (bitPos < 0) or (P + bitPos > Length(B)) then
        raise Exception.Create('Parquet: RLE deger boyu gecersiz');
      ind := DecodeRle(B, P, 1, N);
      P := P - 4 + bitPos + 4;
      for k := 0 to N - 1 do
        bools[k] := ind[k] <> 0;
    end
    else if (Enc = ENC_PLAIN_DICTIONARY) or (Enc = ENC_RLE_DICTIONARY) then
    begin
      if P >= Length(B) then raise Exception.Create('Parquet: sozluk indeks verisi bitti');
      bw := B[P];
      Inc(P);
      ind := DecodeRle(B, P, bw, N);
      for k := 0 to N - 1 do
      begin
        if (ind[k] < 0) or (ind[k] >= Length(DictArr)) then
          raise Exception.Create('Parquet: sozluk indeksi aralik disi');
        strs[k] := DictArr[ind[k]];
      end;
    end
    else
      raise Exception.CreateFmt('Parquet: desteklenmeyen kodlama %d', [Enc]);
  end;

  procedure FillRows(const B: TBytes; Levels: TInt64Arr; NumVals: Integer;
    ValStart: Integer; Enc: Integer; const DictArr: TStrArray);
  var
    k, cnt: Integer;
    vp: Integer;
    isDict: Boolean;
  begin
    cnt := 0;
    if Levels <> nil then
    begin
      for k := 0 to NumVals - 1 do
        if Levels[k] <> 0 then Inc(cnt);
    end
    else
      cnt := NumVals;
    vp := ValStart;
    ReadValues(B, vp, cnt, Enc, DictArr);
    isDict := (Enc = ENC_PLAIN_DICTIONARY) or (Enc = ENC_RLE_DICTIONARY);
    cnt := 0;
    for k := 0 to NumVals - 1 do
    begin
      if (rowPos + k < 0) or (rowPos + k >= GroupRows) then Continue;
      if (Levels <> nil) and (Levels[k] = 0) then
        Values[rowPos + k] := ''
      else
      begin
        if isDict then
          Values[rowPos + k] := strs[cnt]
        else
          case SE.PType of
            PT_BOOLEAN:
              Values[rowPos + k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, 0, 0, bools[cnt], '');
            PT_INT32, PT_INT64:
              Values[rowPos + k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, nums[cnt], 0, False, '');
            PT_FLOAT, PT_DOUBLE:
              Values[rowPos + k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, 0, vals[cnt], False, '');
            PT_BYTE_ARRAY:
              Values[rowPos + k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit, 0, 0, False, strs[cnt]);
            PT_INT96:
              Values[rowPos + k] := int96[cnt];
          end;
        Inc(cnt);
      end;
    end;
    Inc(rowPos, NumVals);
  end;

begin
  SetLength(Values, GroupRows);
  for i := 0 to GroupRows - 1 do Values[i] := '';
  SetLength(dict, 0);
  maxDef := 0;
  if SE.Repetition = REP_OPTIONAL then maxDef := 1;
  if SE.Repetition = REP_REPEATED then maxDef := 1;
  if SE.Repetition = REP_REPEATED then
    raise Exception.Create('Parquet: repeated (nested) alan desteklenmiyor');
  if (CM.Codec <> CODEC_UNCOMPRESSED) and (CM.Codec <> CODEC_SNAPPY) then
    raise Exception.CreateFmt('Parquet: sikistirma desteklenmiyor (codec=%d)', [CM.Codec]);
  off := CM.DataPageOffset;
  if CM.DictPageOffset >= 0 then off := CM.DictPageOffset;
  rowPos := 0;
  seen := 0;
  while (off + 8 < Length(Data)) and (seen < CM.NumValues) do
  begin
    ParsePageHeader(Data, off, H, HL);
    BodyPos := Integer(off) + HL;
    BodyLen := H.Compressed;
    if (BodyPos < 0) or (BodyLen < 0) or (BodyPos + BodyLen > Length(Data)) then
      raise Exception.Create('Parquet: sayfa govdesi dosya disinda');
    SetLength(body, BodyLen);
    if BodyLen > 0 then Move(Data[BodyPos], body[0], BodyLen);
    if H.PageType = PAGE_DICTIONARY then
    begin
      body := PageBody(body, H.Uncompressed);
      dict := DecodeDictPage(body, H.DictNumValues);
      Inc(off, HL + BodyLen);
      Continue;
    end;
    if H.PageType = PAGE_DATA then
    begin
      body := PageBody(body, H.Uncompressed);
      p := 0;
      levels := nil;
      defLen := 0;
      if maxDef > 0 then
      begin
        if p + 4 > Length(body) then raise Exception.Create('Parquet: def level boyu yok');
        defLen := Integer(LE32(body, p));
        Inc(p, 4);
        defPos := p;
        levels := DecodeRle(body, p, 1, H.DataNumValues);
        if p > defPos + defLen then
          raise Exception.Create('Parquet: def level uzunlugu uyusmuyor');
        p := defPos + defLen;
      end;
      encoding := H.DataEncoding;
      FillRows(body, levels, H.DataNumValues, p, encoding, dict);
      Inc(seen, H.DataNumValues);
      Inc(off, HL + BodyLen);
      Continue;
    end;
    if H.PageType = PAGE_DATA_V2 then
    begin
      // V2'de seviye baytlari sikistirilmaz; yalniz deger govdesi sikistirilir.
      if (CM.Codec <> CODEC_UNCOMPRESSED) and H.V2IsCompressed then
      begin
        lvlLen := H.V2RepLen + H.V2DefLen;
        if (lvlLen < 0) or (lvlLen > Length(body)) then
          raise Exception.Create('Parquet: V2 seviye boyu gecersiz');
        rawBody := body;
        SetLength(valRaw, Length(rawBody) - lvlLen);
        if Length(valRaw) > 0 then
          Move(rawBody[lvlLen], valRaw[0], Length(valRaw));
        if not SnappyDecompress(valRaw, valBody) then
          raise Exception.Create('Parquet: SNAPPY cozme hatasi (V2)');
        if Length(valBody) <> H.Uncompressed - lvlLen then
          raise Exception.Create('Parquet: SNAPPY boyu uyusmuyor (V2)');
        SetLength(body, lvlLen + Length(valBody));
        if lvlLen > 0 then Move(rawBody[0], body[0], lvlLen);
        if Length(valBody) > 0 then Move(valBody[0], body[lvlLen], Length(valBody));
      end;
      p := 0;
      if H.V2RepLen > 0 then Inc(p, H.V2RepLen);
      levels := nil;
      if maxDef > 0 then
      begin
        defPos := p;
        levels := DecodeRle(body, p, 1, H.V2NumValues);
        p := defPos + H.V2DefLen;
      end;
      encoding := H.V2Encoding;
      FillRows(body, levels, H.V2NumValues, p, encoding, dict);
      Inc(seen, H.V2NumValues);
      Inc(off, HL + BodyLen);
      Continue;
    end;
    // INDEX_PAGE veya bilinmeyen: atla
    Inc(off, HL + BodyLen);
  end;
end;

function VDbParquetImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;
var
  fs: TFileStream;
  Data: TBytes;
  sz, metaStart, metaLen, i, j, leafN, total, base, r: Integer;
  Meta: TParquetMeta;
  leaves: array of TParquetSchemaElem;
  colVals: TStrArray;
begin
  Result := False;
  Err := '';
  SetLength(Fields, 0);
  SetLength(Types, 0);
  SetLength(Rows, 0);
  try
    fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      sz := fs.Size;
      SetLength(Data, sz);
      if sz > 0 then fs.ReadBuffer(Data[0], sz);
    finally
      fs.Free;
    end;
    if sz < 12 then
      raise Exception.Create('Parquet: dosya cok kucuk');
    if (Char(Data[0]) <> 'P') or (Char(Data[1]) <> 'A') or
       (Char(Data[2]) <> 'R') or (Char(Data[3]) <> '1') then
      raise Exception.Create('Parquet: PAR1 imzasi yok');
    if (Char(Data[sz - 4]) <> 'P') or (Char(Data[sz - 3]) <> 'A') or
       (Char(Data[sz - 2]) <> 'R') or (Char(Data[sz - 1]) <> '1') then
      raise Exception.Create('Parquet: kuyruk PAR1 imzasi yok');
    metaLen := Integer(LE32(Data, sz - 8));
    metaStart := sz - 8 - metaLen;
    if (metaStart < 4) or (metaLen <= 0) then
      raise Exception.Create('Parquet: gecersiz metadata boyu');
    ParseFileMeta(Data, metaStart, metaLen, Meta);

    // Duz sema: kok + yapraklar. Nested reddedilir.
    if Length(Meta.Schema) < 2 then
      raise Exception.Create('Parquet: sema bos');
    if Meta.Schema[0].NumChildren <> Length(Meta.Schema) - 1 then
      raise Exception.Create('Parquet: nested sema desteklenmiyor');
    leafN := 0;
    SetLength(leaves, Length(Meta.Schema) - 1);
    for i := 1 to High(Meta.Schema) do
    begin
      if Meta.Schema[i].NumChildren > 0 then
        raise Exception.Create('Parquet: nested sema desteklenmiyor');
      leaves[leafN] := Meta.Schema[i];
      Inc(leafN);
    end;
    SetLength(leaves, leafN);

    total := 0;
    for i := 0 to High(Meta.RowGroups) do
    begin
      if Integer(Meta.RowGroups[i].NumRows) < 0 then
        raise Exception.Create('Parquet: negatif satir sayisi');
      Inc(total, Integer(Meta.RowGroups[i].NumRows));
    end;
    SetLength(Fields, leafN);
    SetLength(Types, leafN);
    for i := 0 to leafN - 1 do
    begin
      Fields[i] := leaves[i].Name;
      Types[i] := VTypeOfLeaf(leaves[i]);
    end;
    SetLength(Rows, total);
    for i := 0 to total - 1 do
    begin
      SetLength(Rows[i], leafN);
      for j := 0 to leafN - 1 do Rows[i][j] := '';
    end;

    base := 0;
    for i := 0 to High(Meta.RowGroups) do
    begin
      if Length(Meta.RowGroups[i].Columns) <> leafN then
        raise Exception.Create('Parquet: satir grubu kolon sayisi uyusmuyor');
      for j := 0 to leafN - 1 do
      begin
        try
          DecodeColumn(Data, Meta.RowGroups[i].Columns[j], leaves[j],
            Integer(Meta.RowGroups[i].NumRows), colVals);
        except
          on E: Exception do
            raise Exception.CreateFmt('Parquet: %s: %s', [leaves[j].Name, E.Message]);
        end;
        for r := 0 to Integer(Meta.RowGroups[i].NumRows) - 1 do
          Rows[base + r][j] := colVals[r];
      end;
      Inc(base, Integer(Meta.RowGroups[i].NumRows));
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      SetLength(Fields, 0);
      SetLength(Types, 0);
      SetLength(Rows, 0);
    end;
  end;
end;

end.