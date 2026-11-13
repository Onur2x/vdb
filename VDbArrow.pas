unit VDbArrow;
{ M2: Arrow IPC stream (uncompressed, flat schema) disa/içe aktarma.

  Bu birim yalnizca motorun kendi skaler tiplerini tasir:
  INT -> Int64, FLOAT -> Float64, BOOL -> Bool, TEXT -> Utf8,
  BLOB -> Binary, DATE -> Date32[DAY], DATETIME -> Timestamp[SECOND],
  TIME -> Time32[SECOND].

  Dosya bicimi Arrow IPC **stream** formatidir (ARROW1 dosya footer'i yok).
  Metadata FlatBuffers olarak, gövde ise 8 bayt hizali tamponlarla yazilir.
  Dis bagimlilik yoktur; okuyucu yalnizca bu alt kümeyi cozer. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, VDbTypes, VDbTable;

function VDbArrowExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;

function VDbArrowImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;

implementation

type
  TFbKind = (fbTable, fbString, fbVecOff, fbVecStruct);
  TFbFieldKind = (ffI8, ffBool, ffI16, ffI32, ffI64, ffOffset);

  TFbNode = class;
  TFbField = record
    Slot: Integer;
    Kind: TFbFieldKind;
    I64: Int64;
    Node: TFbNode;
    Off: Integer;
  end;

  TFbNode = class
  public
    Kind: TFbKind;
    Fields: array of TFbField;
    Children: array of TFbNode;
    Data: TBytes;       // string baytlari veya struct-vector gövdesi
    Count: Integer;
    MaxSlot: Integer;
    Pos: Integer;
    VPos: Integer;
    Size: Integer;
    VTableSize: Integer;
    TableSize: Integer;
    TableAlign: Integer;
    constructor Create(AKind: TFbKind);
    procedure AddScalar(ASlot: Integer; AKind: TFbFieldKind; AValue: Int64);
    procedure AddOffset(ASlot: Integer; ANode: TFbNode);
    procedure AddChild(ANode: TFbNode);
  end;

  TFbDoc = class
  public
    Nodes: TList;
    constructor Create;
    destructor Destroy; override;
    function Table(AMaxSlot: Integer): TFbNode;
    function Str(const S: string): TFbNode;
    function VecOff: TFbNode;
    function VecStruct(ACount: Integer): TFbNode;
  end;

  TArrowField = record
    Name: string;
    Ctype: Byte;
    TypeId: Byte;
    BitWidth: Integer;
    IsSigned: Boolean;
    Precision: Integer;
    TimeUnit: Integer;
    TimeBits: Integer;
    LargeOffsets: Boolean;
  end;
  TArrowFieldArray = array of TArrowField;

function AlignUp(V, A: Integer): Integer;
begin
  if A <= 1 then Exit(V);
  Result := (V + A - 1) and not (A - 1);
end;

function FbSize(K: TFbFieldKind): Integer;
begin
  case K of
    ffI8, ffBool: Result := 1;
    ffI16: Result := 2;
    ffI32, ffOffset: Result := 4;
    ffI64: Result := 8;
    else Result := 4;
  end;
end;

function FbAlign(K: TFbFieldKind): Integer;
begin
  Result := FbSize(K);
end;

constructor TFbNode.Create(AKind: TFbKind);
begin
  inherited Create;
  Kind := AKind;
  MaxSlot := -1;
  Pos := -1;
  VPos := -1;
end;

procedure TFbNode.AddScalar(ASlot: Integer; AKind: TFbFieldKind; AValue: Int64);
var
  n: Integer;
begin
  n := Length(Fields);
  SetLength(Fields, n + 1);
  Fields[n].Slot := ASlot;
  Fields[n].Kind := AKind;
  Fields[n].I64 := AValue;
  Fields[n].Node := nil;
  Fields[n].Off := 0;
  if ASlot > MaxSlot then MaxSlot := ASlot;
end;

procedure TFbNode.AddOffset(ASlot: Integer; ANode: TFbNode);
var
  n: Integer;
begin
  n := Length(Fields);
  SetLength(Fields, n + 1);
  Fields[n].Slot := ASlot;
  Fields[n].Kind := ffOffset;
  Fields[n].I64 := 0;
  Fields[n].Node := ANode;
  Fields[n].Off := 0;
  if ASlot > MaxSlot then MaxSlot := ASlot;
end;

procedure TFbNode.AddChild(ANode: TFbNode);
var
  n: Integer;
begin
  n := Length(Children);
  SetLength(Children, n + 1);
  Children[n] := ANode;
  Count := Length(Children);
end;

constructor TFbDoc.Create;
begin
  inherited Create;
  Nodes := TList.Create;
end;

destructor TFbDoc.Destroy;
var
  i: Integer;
begin
  for i := 0 to Nodes.Count - 1 do
    TFbNode(Nodes[i]).Free;
  Nodes.Free;
  inherited Destroy;
end;

function TFbDoc.Table(AMaxSlot: Integer): TFbNode;
begin
  Result := TFbNode.Create(fbTable);
  Result.MaxSlot := AMaxSlot;
  Nodes.Add(Result);
end;

function TFbDoc.Str(const S: string): TFbNode;
begin
  Result := TFbNode.Create(fbString);
  Result.Data := TEncoding.UTF8.GetBytes(S);
  Result.Size := 4 + Length(Result.Data) + 1;
  Result.Count := Length(Result.Data);
  Nodes.Add(Result);
end;

function TFbDoc.VecOff: TFbNode;
begin
  Result := TFbNode.Create(fbVecOff);
  Nodes.Add(Result);
end;

function TFbDoc.VecStruct(ACount: Integer): TFbNode;
begin
  Result := TFbNode.Create(fbVecStruct);
  Result.Count := ACount;
  SetLength(Result.Data, ACount * 16);
  Nodes.Add(Result);
end;

procedure WU16(var B: TBytes; P: Integer; V: Word);
begin
  B[P] := Byte(V);
  B[P + 1] := Byte(V shr 8);
end;

procedure WU32(var B: TBytes; P: Integer; V: LongWord);
begin
  B[P] := Byte(V);
  B[P + 1] := Byte(V shr 8);
  B[P + 2] := Byte(V shr 16);
  B[P + 3] := Byte(V shr 24);
end;

procedure WI32(var B: TBytes; P: Integer; V: LongInt);
begin
  WU32(B, P, LongWord(V));
end;

procedure WU64(var B: TBytes; P: Integer; V: QWord);
begin
  WU32(B, P, LongWord(V and $FFFFFFFF));
  WU32(B, P + 4, LongWord(V shr 32));
end;

procedure WI64(var B: TBytes; P: Integer; V: Int64);
begin
  WU64(B, P, QWord(V));
end;

function RU16(const B: TBytes; P: Integer): Word;
begin
  Result := Word(B[P]) or (Word(B[P + 1]) shl 8);
end;

function RU32(const B: TBytes; P: Integer): LongWord;
begin
  Result := LongWord(B[P]) or (LongWord(B[P + 1]) shl 8) or
    (LongWord(B[P + 2]) shl 16) or (LongWord(B[P + 3]) shl 24);
end;

function RI32(const B: TBytes; P: Integer): LongInt;
begin
  Result := LongInt(RU32(B, P));
end;

function RU64(const B: TBytes; P: Integer): QWord;
begin
  Result := QWord(RU32(B, P)) or (QWord(RU32(B, P + 4)) shl 32);
end;

function RI64(const B: TBytes; P: Integer): Int64;
begin
  Result := Int64(RU64(B, P));
end;

procedure PrepareTable(N: TFbNode);
var
  s, i, off, a, maxA: Integer;
begin
  N.VTableSize := 4 + 2 * (N.MaxSlot + 1);
  off := 4;
  maxA := 4;
  for s := 0 to N.MaxSlot do
    for i := 0 to High(N.Fields) do
      if N.Fields[i].Slot = s then
      begin
        a := FbAlign(N.Fields[i].Kind);
        off := AlignUp(off, a);
        N.Fields[i].Off := off;
        Inc(off, FbSize(N.Fields[i].Kind));
        if a > maxA then maxA := a;
        Break;
      end;
  N.TableAlign := maxA;
  N.TableSize := AlignUp(off, maxA);
end;

var
  GBuildCur: Integer;

procedure PlaceNode(N: TFbNode); forward;

procedure PlaceChildren(N: TFbNode);
var
  i, j: Integer;
begin
  if N.Kind = fbTable then
  begin
    for i := 0 to High(N.Fields) do
      if (N.Fields[i].Kind = ffOffset) and (N.Fields[i].Node <> nil) then
        PlaceNode(N.Fields[i].Node);
  end
  else if N.Kind = fbVecOff then
    for j := 0 to High(N.Children) do
      PlaceNode(N.Children[j]);
end;

procedure PlaceNode(N: TFbNode);
begin
  if N.Pos >= 0 then Exit;
  case N.Kind of
    fbTable:
      begin
        PrepareTable(N);
        N.VPos := AlignUp(GBuildCur, 2);
        N.Pos := AlignUp(N.VPos + N.VTableSize, N.TableAlign);
        N.Size := N.TableSize;
        GBuildCur := N.Pos + N.TableSize;
        PlaceChildren(N);
      end;
    fbString:
      begin
        N.Size := 4 + Length(N.Data) + 1;
        N.Pos := AlignUp(GBuildCur, 4);
        GBuildCur := N.Pos + N.Size;
      end;
    fbVecOff:
      begin
        N.Size := 4 + 4 * N.Count;
        N.Pos := AlignUp(GBuildCur, 4);
        GBuildCur := N.Pos + N.Size;
        PlaceChildren(N);
      end;
    fbVecStruct:
      begin
        N.Size := 4 + N.Count * 16;
        N.Pos := AlignUp(GBuildCur + 4, 8) - 4;
        GBuildCur := N.Pos + N.Size;
      end;
  end;
end;

procedure SerializeNode(var B: TBytes; N: TFbNode);
var
  i, s, fp: Integer;
  f: TFbField;
begin
  case N.Kind of
    fbTable:
      begin
        // vtable
        WU16(B, N.VPos, Word(N.VTableSize));
        WU16(B, N.VPos + 2, Word(N.TableSize));
        for s := 0 to N.MaxSlot do
        begin
          f.Kind := ffI8;
          f.Off := 0;
          for i := 0 to High(N.Fields) do
            if N.Fields[i].Slot = s then
            begin
              f := N.Fields[i];
              Break;
            end;
          WU16(B, N.VPos + 4 + 2 * s, Word(f.Off));
        end;
        WI32(B, N.Pos, N.Pos - N.VPos);
        for i := 0 to High(N.Fields) do
        begin
          f := N.Fields[i];
          fp := N.Pos + f.Off;
          case f.Kind of
            ffI8, ffBool: B[fp] := Byte(f.I64);
            ffI16: WU16(B, fp, Word(f.I64));
            ffI32: WI32(B, fp, LongInt(f.I64));
            ffI64: WI64(B, fp, f.I64);
            ffOffset:
              WU32(B, fp, LongWord(f.Node.Pos - fp));
          end;
        end;
        for i := 0 to High(N.Fields) do
          if (N.Fields[i].Kind = ffOffset) and (N.Fields[i].Node <> nil) then
            SerializeNode(B, N.Fields[i].Node);
      end;
    fbString:
      begin
        WU32(B, N.Pos, LongWord(Length(N.Data)));
        if Length(N.Data) > 0 then
          Move(N.Data[0], B[N.Pos + 4], Length(N.Data));
        B[N.Pos + 4 + Length(N.Data)] := 0;
      end;
    fbVecOff:
      begin
        WU32(B, N.Pos, LongWord(N.Count));
        for i := 0 to High(N.Children) do
          WU32(B, N.Pos + 4 + 4 * i,
            LongWord(N.Children[i].Pos - (N.Pos + 4 + 4 * i)));
        for i := 0 to High(N.Children) do
          SerializeNode(B, N.Children[i]);
      end;
    fbVecStruct:
      begin
        WU32(B, N.Pos, LongWord(N.Count));
        if Length(N.Data) > 0 then
          Move(N.Data[0], B[N.Pos + 4], Length(N.Data));
      end;
  end;
end;

function FinishDoc(Doc: TFbDoc; Root: TFbNode): TBytes;
begin
  GBuildCur := 4;
  PlaceNode(Root);
  SetLength(Result, AlignUp(GBuildCur, 8));
  if Length(Result) > 0 then
    FillChar(Result[0], Length(Result), 0);
  WU32(Result, 0, LongWord(Root.Pos));
  SerializeNode(Result, Root);
end;

{ ---------------------------------------------------------------- Arrow yaz }

function ArrowTypeId(Ctype: Byte): Byte;
begin
  case Ctype of
    VCT_INT: Result := 2;       // Int
    VCT_FLOAT: Result := 3;     // FloatingPoint
    VCT_BLOB: Result := 4;      // Binary
    VCT_BOOL: Result := 6;      // Bool
    VCT_DATE: Result := 8;      // Date
    VCT_TIME: Result := 9;      // Time
    VCT_DATETIME: Result := 10; // Timestamp
    else Result := 5;           // Utf8
  end;
end;

function MakeTypeTable(Doc: TFbDoc; Ctype: Byte): TFbNode;
begin
  case Ctype of
    VCT_INT:
      begin
        Result := Doc.Table(1);
        Result.AddScalar(0, ffI32, 64);
        Result.AddScalar(1, ffBool, 1);
      end;
    VCT_FLOAT:
      begin
        Result := Doc.Table(0);
        Result.AddScalar(0, ffI16, 2); // DOUBLE
      end;
    VCT_DATE:
      begin
        Result := Doc.Table(0);
        Result.AddScalar(0, ffI16, 0); // DAY
      end;
    VCT_DATETIME:
      begin
        Result := Doc.Table(1);
        Result.AddScalar(0, ffI16, 0); // SECOND
      end;
    VCT_TIME:
      begin
        Result := Doc.Table(1);
        Result.AddScalar(0, ffI16, 0); // SECOND
        Result.AddScalar(1, ffI32, 32);
      end;
    else
      Result := Doc.Table(0);          // Utf8 / Binary / Bool: bos tablo
  end;
end;

function MakeField(Doc: TFbDoc; const Name: string; Ctype: Byte): TFbNode;
begin
  Result := Doc.Table(6);
  Result.AddOffset(0, Doc.Str(Name));
  Result.AddScalar(1, ffBool, 1);
  Result.AddScalar(2, ffI8, ArrowTypeId(Ctype));
  Result.AddOffset(3, MakeTypeTable(Doc, Ctype));
end;

function MakeSchema(Doc: TFbDoc; const Fields: TStrArray;
  const Types: TByteArray): TFbNode;
var
  vec: TFbNode;
  i: Integer;
begin
  vec := Doc.VecOff;
  for i := 0 to High(Fields) do
    vec.AddChild(MakeField(Doc, Fields[i], Types[i]));
  Result := Doc.Table(3);
  Result.AddScalar(0, ffI16, 0); // Little
  Result.AddOffset(1, vec);
end;

function MakeSchemaMessage(const Fields: TStrArray;
  const Types: TByteArray): TBytes;
var
  doc: TFbDoc;
  msg: TFbNode;
begin
  doc := TFbDoc.Create;
  try
    msg := doc.Table(4);
    msg.AddScalar(0, ffI16, 4); // MetadataVersion V5
    msg.AddScalar(1, ffI8, 1);  // MessageHeader.Schema
    msg.AddOffset(2, MakeSchema(doc, Fields, Types));
    msg.AddScalar(3, ffI64, 0);
    Result := FinishDoc(doc, msg);
  finally
    doc.Free;
  end;
end;

function MakeRecordBatchMessage(Rows: Integer; const Nodes, Buffers: TBytes;
  BodyLen: Integer): TBytes;
var
  doc: TFbDoc;
  msg, rb, nv, bv: TFbNode;
begin
  doc := TFbDoc.Create;
  try
    // Nodes/Buffers onceden 16'lik struct dizisi olarak hazirlandi.
    nv := doc.VecStruct(Length(Nodes) div 16);
    if Length(Nodes) > 0 then
      Move(Nodes[0], nv.Data[0], Length(Nodes));
    bv := doc.VecStruct(Length(Buffers) div 16);
    if Length(Buffers) > 0 then
      Move(Buffers[0], bv.Data[0], Length(Buffers));

    rb := doc.Table(4);
    rb.AddScalar(0, ffI64, Rows);
    rb.AddOffset(1, nv);
    rb.AddOffset(2, bv);

    msg := doc.Table(4);
    msg.AddScalar(0, ffI16, 4);
    msg.AddScalar(1, ffI8, 3); // RecordBatch
    msg.AddOffset(2, rb);
    msg.AddScalar(3, ffI64, BodyLen);
    Result := FinishDoc(doc, msg);
  finally
    doc.Free;
  end;
end;

procedure AppendBuf(var Body: TBytes; var BodyLen: Integer;
  const Data: TBytes; out Off, Len: Int64);
begin
  BodyLen := AlignUp(BodyLen, 8);
  if BodyLen + Length(Data) > Length(Body) then
    SetLength(Body, AlignUp(BodyLen + Length(Data) + 64, 64));
  Off := BodyLen;
  Len := Length(Data);
  if Len > 0 then
    Move(Data[0], Body[BodyLen], Len);
  Inc(BodyLen, Len);
end;

procedure WriteStructI64(var B: TBytes; P: Integer; V: Int64);
begin
  WI64(B, P, V);
end;

procedure AddBuffer(var Body: TBytes; var BodyLen: Integer;
  var Buffers: TBytes; const Data: TBytes);
var
  off, len: Int64;
begin
  AppendBuf(Body, BodyLen, Data, off, len);
  SetLength(Buffers, Length(Buffers) + 16);
  WriteStructI64(Buffers, Length(Buffers) - 16, off);
  WriteStructI64(Buffers, Length(Buffers) - 8, len);
end;

function DateToDays(const S: string; out Days: Int64): Boolean;
var
  d: TDateTime;
  fs: TFormatSettings;
  y, m, dd: Word;
begin
  fs := DefaultFormatSettings;
  fs.DateSeparator := '-';
  fs.ShortDateFormat := 'yyyy-mm-dd';
  Result := TryStrToDate(S, d, fs);
  if not Result then Result := TryStrToDate(S, d);
  if Result then
  begin
    DecodeDate(d, y, m, dd);
    Days := Trunc(EncodeDate(y, m, dd) - EncodeDate(1970, 1, 1));
  end;
end;

function TimeToSecs(const S: string; out Secs: Int64): Boolean;
var
  d: TDateTime;
  fs: TFormatSettings;
  h, n, ss, ms: Word;
begin
  fs := DefaultFormatSettings;
  fs.TimeSeparator := ':';
  fs.LongTimeFormat := 'hh:nn:ss';
  Result := TryStrToTime(S, d, fs);
  if not Result then Result := TryStrToTime(S, d);
  if Result then
  begin
    DecodeTime(d, h, n, ss, ms);
    Secs := Int64(h) * 3600 + Int64(n) * 60 + ss;
  end;
end;

function DateTimeToSecs(const S: string; out Secs: Int64): Boolean;
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
    Secs := DateTimeToUnix(d);
end;

function ExportBody(const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Nodes, Buffers, Body: TBytes;
  out BodyLen: Integer; out Err: string): Boolean;
var
  n, i, j, nulls, bitLen: Integer;
  validity, data, offs: TBytes;
  s: string;
  iv: Int64;
  fv: Double;
  bv: Boolean;
  p: Integer;
begin
  Result := False;
  BodyLen := 0;
  SetLength(Body, 0);
  SetLength(Nodes, 0);
  SetLength(Buffers, 0);
  n := Length(Rows);
  if Length(Fields) <> Length(Types) then
  begin
    Err := 'Arrow: alan/tip sayisi uyusmuyor';
    Exit;
  end;
  SetLength(Nodes, Length(Fields) * 16);
  SetLength(Buffers, 0);

  for j := 0 to High(Fields) do
  begin
    nulls := 0;
    for i := 0 to n - 1 do
    begin
      if (j >= Length(Rows[i])) or (Rows[i][j] = '') then Inc(nulls);
    end;
    bitLen := (n + 7) div 8;
    SetLength(validity, bitLen);
    if bitLen > 0 then
    begin
      FillChar(validity[0], bitLen, 0);
      for i := 0 to n - 1 do
        if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
          validity[i shr 3] := validity[i shr 3] or (1 shl (i and 7));
    end;

    WriteStructI64(Nodes, j * 16, n);
    WriteStructI64(Nodes, j * 16 + 8, nulls);

    AddBuffer(Body, BodyLen, Buffers, validity);

    case Types[j] of
      VCT_INT:
        begin
          SetLength(data, n * 8);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
            begin
              if VDbParseInt(Rows[i][j], iv) then
                WI64(data, i * 8, iv);
            end;
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_FLOAT:
        begin
          SetLength(data, n * 8);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
              if VDbParseFloat(Rows[i][j], fv) then
                Move(fv, data[i * 8], 8);
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_BOOL:
        begin
          bitLen := (n + 7) div 8;
          SetLength(data, bitLen);
          if Length(data) > 0 then FillChar(data[0], bitLen, 0);
          for i := 0 to n - 1 do
            if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
            begin
              s := LowerCase(Rows[i][j]);
              bv := (s = 'true') or (s = '1');
              if bv then
                data[i shr 3] := data[i shr 3] or (1 shl (i and 7));
            end;
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_DATE:
        begin
          SetLength(data, n * 4);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
              if DateToDays(Rows[i][j], iv) then
                WI32(data, i * 4, LongInt(iv));
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_DATETIME:
        begin
          SetLength(data, n * 8);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
              if DateTimeToSecs(Rows[i][j], iv) then
                WI64(data, i * 8, iv);
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_TIME:
        begin
          SetLength(data, n * 4);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
              if TimeToSecs(Rows[i][j], iv) then
                WI32(data, i * 4, LongInt(iv));
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      else
        begin
          // Utf8 / Binary: offset + veri
          SetLength(offs, (n + 1) * 4);
          FillChar(offs[0], Length(offs), 0);
          SetLength(data, 0);
          p := 0;
          for i := 0 to n - 1 do
          begin
            if (j < Length(Rows[i])) and (Rows[i][j] <> '') then
            begin
              s := Rows[i][j];
              if Length(data) < p + Length(s) then
                SetLength(data, p + Length(s) + 64);
              Move(s[1], data[p], Length(s));
              Inc(p, Length(s));
            end;
            WI32(offs, (i + 1) * 4, LongInt(p));
          end;
          SetLength(data, p);
          AddBuffer(Body, BodyLen, Buffers, offs);
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
    end;
  end;
  Result := True;
end;

function BuildBuffers(const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Nodes, Buffers, Body: TBytes;
  out BodyLen: Integer; out Err: string): Boolean;
begin
  Result := ExportBody(Fields, Types, Rows, Nodes, Buffers, Body, BodyLen, Err);
end;

function VDbArrowExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;
var
  schemaMsg, rbMsg: TBytes;
  nodes, buffers, body: TBytes;
  bodyLen, metaLen: Integer;
  fs: TFileStream;
  cont: LongWord;
  pad: TBytes;
begin
  Result := False;
  Err := '';
  try
    schemaMsg := MakeSchemaMessage(Fields, Types);
    if not BuildBuffers(Fields, Types, Rows, nodes, buffers, body, bodyLen, Err) then
      Exit;
    bodyLen := AlignUp(bodyLen, 8);
    if Length(body) < bodyLen then
      SetLength(body, bodyLen);
    rbMsg := MakeRecordBatchMessage(Length(Rows), nodes, buffers, bodyLen);
    fs := TFileStream.Create(FileName, fmCreate);
    try
      // Schema mesaji
      cont := $FFFFFFFF;
      metaLen := AlignUp(Length(schemaMsg), 8);
      SetLength(pad, 4);
      WU32(pad, 0, cont);
      fs.WriteBuffer(pad[0], 4);
      WU32(pad, 0, LongWord(metaLen));
      fs.WriteBuffer(pad[0], 4);
      if Length(schemaMsg) > 0 then
        fs.WriteBuffer(schemaMsg[0], Length(schemaMsg));
      if metaLen > Length(schemaMsg) then
      begin
        SetLength(pad, metaLen - Length(schemaMsg));
        FillChar(pad[0], Length(pad), 0);
        fs.WriteBuffer(pad[0], Length(pad));
      end;
      // RecordBatch mesaji
      metaLen := AlignUp(Length(rbMsg), 8);
      WU32(pad, 0, cont);
      fs.WriteBuffer(pad[0], 4);
      WU32(pad, 0, LongWord(metaLen));
      fs.WriteBuffer(pad[0], 4);
      if Length(rbMsg) > 0 then
        fs.WriteBuffer(rbMsg[0], Length(rbMsg));
      if metaLen > Length(rbMsg) then
      begin
        SetLength(pad, metaLen - Length(rbMsg));
        FillChar(pad[0], Length(pad), 0);
        fs.WriteBuffer(pad[0], Length(pad));
      end;
      if bodyLen > 0 then
        fs.WriteBuffer(body[0], bodyLen);
      // EOS
      WU32(pad, 0, cont);
      fs.WriteBuffer(pad[0], 4);
      WU32(pad, 0, 0);
      fs.WriteBuffer(pad[0], 4);
    finally
      fs.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

function FbField(const B: TBytes; Table, Slot: Integer): Integer;
var
  vt, vs, off: Integer;
begin
  Result := 0;
  if (Table <= 0) or (Table + 4 > Length(B)) then Exit;
  vt := Table - RI32(B, Table);
  if (vt < 0) or (vt + 4 > Length(B)) then Exit;
  vs := RU16(B, vt);
  if 4 + 2 * Slot + 2 > vs then Exit;
  off := RU16(B, vt + 4 + 2 * Slot);
  if off = 0 then Exit;
  if Table + off + 1 > Length(B) then Exit;
  Result := Table + off;
end;

function FbOffsetOf(const B: TBytes; FieldPos: Integer): Integer;
begin
  Result := 0;
  if (FieldPos <= 0) or (FieldPos + 4 > Length(B)) then Exit;
  Result := FieldPos + Integer(RU32(B, FieldPos));
  if (Result < 0) or (Result + 4 > Length(B)) then
    raise Exception.Create('Arrow: FlatBuffer offset siniri asiyor');
end;

function FbStringOf(const B: TBytes; FieldPos: Integer): string;
var
  t, n: Integer;
begin
  Result := '';
  if FieldPos <= 0 then Exit;
  t := FbOffsetOf(B, FieldPos);
  n := Integer(RU32(B, t));
  if (n < 0) or (t + 4 + n > Length(B)) then
    raise Exception.Create('Arrow: string siniri asiyor');
  SetLength(Result, n);
  if n > 0 then
    Move(B[t + 4], Result[1], n);
end;

function FbVecLen(const B: TBytes; FieldPos: Integer): Integer;
var
  t: Integer;
begin
  Result := 0;
  if FieldPos <= 0 then Exit;
  t := FbOffsetOf(B, FieldPos);
  Result := Integer(RU32(B, t));
  if Result < 0 then
    raise Exception.Create('Arrow: negatif vektor uzunlugu');
end;

function FbVecOffElem(const B: TBytes; FieldPos, Index: Integer): Integer;
var
  t, e: Integer;
begin
  Result := 0;
  t := FbOffsetOf(B, FieldPos);
  e := t + 4 + 4 * Index;
  if e + 4 > Length(B) then
    raise Exception.Create('Arrow: vektor elemani siniri asiyor');
  Result := e + Integer(RU32(B, e));
  if (Result < 0) or (Result + 4 > Length(B)) then
    raise Exception.Create('Arrow: vektor hedefi siniri asiyor');
end;

function FbVecStructElem(const B: TBytes; FieldPos, Index: Integer): Integer;
var
  t: Integer;
begin
  t := FbOffsetOf(B, FieldPos);
  // Struct vektorunde elemanlar uzunluk on ekinin hemen ardindan,
  // 8 bayt hizali olarak baslar; yazici bu hizayi garantiler.
  Result := t + 4 + Index * 16;
  if Result + 16 > Length(B) then
    raise Exception.Create('Arrow: struct vektoru siniri asiyor');
end;

function ReadFileBytes(const FN: string): TBytes;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(FN, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

function FbInt16(const B: TBytes; P: Integer; Default: Integer): Integer;
begin
  if P = 0 then Exit(Default);
  Result := SmallInt(RU16(B, P));
end;

function FbInt32(const B: TBytes; P: Integer; Default: Integer): Integer;
begin
  if P = 0 then Exit(Default);
  Result := RI32(B, P);
end;

function FbBool(const B: TBytes; P: Integer; Default: Boolean): Boolean;
begin
  if P = 0 then Exit(Default);
  Result := B[P] <> 0;
end;

procedure ArrowParseType(const B: TBytes; TypeId, TypeTable: Integer;
  var AF: TArrowField);
begin
  AF.TypeId := TypeId;
  case TypeId of
    2: // Int
      begin
        AF.Ctype := VCT_INT;
        AF.BitWidth := FbInt32(B, FbField(B, TypeTable, 0), 32);
        AF.IsSigned := FbBool(B, FbField(B, TypeTable, 1), False);
        if not (AF.BitWidth in [8, 16, 32, 64]) then
          raise Exception.CreateFmt('Arrow: desteklenmeyen Int bit genisligi %d',
            [AF.BitWidth]);
      end;
    3: // FloatingPoint
      begin
        AF.Ctype := VCT_FLOAT;
        AF.Precision := FbInt16(B, FbField(B, TypeTable, 0), 2);
        if not (AF.Precision in [1, 2]) then
          raise Exception.Create('Arrow: yalniz float32/float64 desteklenir');
      end;
    4: AF.Ctype := VCT_BLOB;
    5: AF.Ctype := VCT_STR;
    6: AF.Ctype := VCT_BOOL;
    8: // Date
      begin
        AF.Ctype := VCT_DATE;
        AF.TimeUnit := FbInt16(B, FbField(B, TypeTable, 0), 0);
        if not (AF.TimeUnit in [0, 1]) then
          raise Exception.Create('Arrow: desteklenmeyen Date birimi');
      end;
    9: // Time
      begin
        AF.Ctype := VCT_TIME;
        AF.TimeUnit := FbInt16(B, FbField(B, TypeTable, 0), 0);
        AF.TimeBits := FbInt32(B, FbField(B, TypeTable, 1), 32);
        if not (AF.TimeUnit in [0, 1, 2, 3]) then
          raise Exception.Create('Arrow: desteklenmeyen Time birimi');
      end;
    10: // Timestamp
      begin
        AF.Ctype := VCT_DATETIME;
        AF.TimeUnit := FbInt16(B, FbField(B, TypeTable, 0), 0);
        if not (AF.TimeUnit in [0, 1, 2, 3]) then
          raise Exception.Create('Arrow: desteklenmeyen Timestamp birimi');
      end;
    19: // LargeBinary
      begin
        AF.Ctype := VCT_BLOB;
        AF.LargeOffsets := True;
      end;
    20: // LargeUtf8
      begin
        AF.Ctype := VCT_STR;
        AF.LargeOffsets := True;
      end;
    else
      raise Exception.CreateFmt('Arrow: desteklenmeyen alan tipi (id=%d)', [TypeId]);
  end;
end;

procedure ArrowParseSchema(const B: TBytes; SchemaPos: Integer;
  out AF: TArrowFieldArray);
var
  fv, n, i, ft, namePos, typePos, childPos, dictPos: Integer;
  typeId: Byte;
begin
  AF := nil;
  fv := FbField(B, SchemaPos, 1);
  n := FbVecLen(B, fv);
  SetLength(AF, n);
  for i := 0 to n - 1 do
  begin
    ft := FbVecOffElem(B, fv, i);
    AF[i].Name := 'col' + IntToStr(i + 1);
    namePos := FbField(B, ft, 0);
    if namePos > 0 then
      AF[i].Name := FbStringOf(B, namePos);
    dictPos := FbField(B, ft, 4);
    if dictPos > 0 then
      raise Exception.Create('Arrow: dictionary-encoded alan desteklenmiyor');
    childPos := FbField(B, ft, 5);
    if (childPos > 0) and (FbVecLen(B, childPos) > 0) then
      raise Exception.Create('Arrow: iç içe (nested) alan desteklenmiyor');
    typePos := FbField(B, ft, 2);
    if typePos = 0 then
      raise Exception.Create('Arrow: alan tipi alani yok');
    typeId := B[typePos];
    typePos := FbOffsetOf(B, FbField(B, ft, 3));
    ArrowParseType(B, typeId, typePos, AF[i]);
  end;
end;

function ArrowBuf(const B: TBytes; BufVecField, Index, BodyStart: Integer;
  BodyLen: Int64; out Off, Len: Int64): Boolean;
var
  q: Integer;
begin
  q := FbVecStructElem(B, BufVecField, Index);
  Off := RI64(B, q);
  Len := RI64(B, q + 8);
  Result := (Off >= 0) and (Len >= 0) and (Off <= BodyLen) and
    (Len <= BodyLen - Off);
end;

function ValidAt(const B: TBytes; BodyStart: Integer;
  ValOff, ValLen: Int64; Row: Integer): Boolean;
begin
  if ValLen = 0 then Exit(True);
  Result := (B[BodyStart + ValOff + (Row shr 3)] and (1 shl (Row and 7))) <> 0;
end;

function ReadSignedAt(const B: TBytes; P: Integer; Bytes: Integer): Int64;
begin
  case Bytes of
    1: Result := Int8(B[P]);
    2: Result := SmallInt(RU16(B, P));
    4: Result := LongInt(RU32(B, P));
    else Result := RI64(B, P);
  end;
end;

function ReadUnsignedAt(const B: TBytes; P: Integer; Bytes: Integer): QWord;
begin
  case Bytes of
    1: Result := B[P];
    2: Result := RU16(B, P);
    4: Result := RU32(B, P);
    else Result := RU64(B, P);
  end;
end;

function FbFloatAt(const B: TBytes; P: Integer; Precision: Integer): Double;
var
  f32: Single;
begin
  if Precision = 1 then
  begin
    Move(B[P], f32, 4);
    Result := f32;
  end
  else
    Move(B[P], Result, 8);
end;

function SecondsDiv(V: Int64; Divi: Int64): Int64;
begin
  if V >= 0 then Exit(V div Divi);
  Result := -(((-V) + Divi - 1) div Divi);
end;

function ArrowDateStr(Days: Int64): string;
begin
  Result := FormatDateTime('yyyy-mm-dd', EncodeDate(1970, 1, 1) + Days);
end;

function ArrowDateTimeStr(Secs: Int64): string;
begin
  // UnixToDateTime: 1970-01-01 + Secs/86400.0 ifadesi FPC'de sabit
  // katlama sirasinda hassasiyet kaybediyor (03:04:05 -> 03:02:48).
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(Secs));
end;

function ArrowTimeStr(Secs: Int64): string;
begin
  Result := FormatDateTime('hh:nn:ss', UnixToDateTime(Secs));
end;

procedure ArrowDecodeBatch(const B: TBytes; const AF: TArrowFieldArray;
  RBPos, BodyStart: Integer; BodyLen: Int64; var Rows: TStrMatrix);
var
  rowCount, oldRows, i, j, bufIdx, bufCount, nodeCount: Integer;
  row64: Int64;
  nodesField, bufsField, dataBytes, offBytes: Integer;
  vOff, vLen, dOff, dLen, oOff, oLen, o1, o2: Int64;
  iv: Int64;
  uv: QWord;
  s: string;
  precision: Integer;
  valid: Boolean;
begin
  row64 := RI64(B, FbField(B, RBPos, 0));
  if (row64 < 0) or (row64 > MaxInt) then
    raise Exception.Create('Arrow: gecersiz satir sayisi');
  rowCount := Integer(row64);
  nodesField := FbField(B, RBPos, 1);
  bufsField := FbField(B, RBPos, 2);
  nodeCount := FbVecLen(B, nodesField);
  bufCount := FbVecLen(B, bufsField);
  if nodeCount <> Length(AF) then
    raise Exception.CreateFmt('Arrow: dugum/alan sayisi uyusmuyor (%d/%d)',
      [nodeCount, Length(AF)]);

  oldRows := Length(Rows);
  if rowCount > MaxInt - oldRows then
    raise Exception.Create('Arrow: satir sayisi cok buyuk');
  SetLength(Rows, oldRows + rowCount);
  for i := 0 to rowCount - 1 do
    SetLength(Rows[oldRows + i], Length(AF));

  bufIdx := 0;
  for j := 0 to High(AF) do
  begin
    if bufIdx >= bufCount then
      raise Exception.Create('Arrow: tampon sayisi beklenenden az');
    if not ArrowBuf(B, bufsField, bufIdx, BodyStart, BodyLen, vOff, vLen) then
      raise Exception.Create('Arrow: gecersiz validity tamponu');
    Inc(bufIdx);
    if (vLen > 0) and (vLen < (Int64(rowCount) + 7) div 8) then
      raise Exception.Create('Arrow: validity tamponu cok kisa');

    if AF[j].Ctype in [VCT_STR, VCT_BLOB] then
    begin
      if bufIdx + 1 >= bufCount then
        raise Exception.Create('Arrow: string tamponlari eksik');
      if not ArrowBuf(B, bufsField, bufIdx, BodyStart, BodyLen, oOff, oLen) then
        raise Exception.Create('Arrow: gecersiz offset tamponu');
      Inc(bufIdx);
      if not ArrowBuf(B, bufsField, bufIdx, BodyStart, BodyLen, dOff, dLen) then
        raise Exception.Create('Arrow: gecersiz veri tamponu');
      Inc(bufIdx);
      if AF[j].LargeOffsets then offBytes := 8 else offBytes := 4;
      if oLen < Int64(rowCount + 1) * offBytes then
        raise Exception.Create('Arrow: offset tamponu cok kisa');

      for i := 0 to rowCount - 1 do
      begin
        valid := ValidAt(B, BodyStart, vOff, vLen, i);
        if not valid then
        begin
          Rows[oldRows + i][j] := '';
          Continue;
        end;
        if offBytes = 4 then
        begin
          o1 := RI32(B, BodyStart + oOff + i * 4);
          o2 := RI32(B, BodyStart + oOff + (i + 1) * 4);
        end
        else
        begin
          o1 := RI64(B, BodyStart + oOff + i * 8);
          o2 := RI64(B, BodyStart + oOff + (i + 1) * 8);
        end;
        if (o1 < 0) or (o2 < o1) or (o2 > dLen) then
          raise Exception.Create('Arrow: string offset araligi gecersiz');
        SetLength(s, o2 - o1);
        if o2 > o1 then
          Move(B[BodyStart + dOff + o1], s[1], o2 - o1);
        Rows[oldRows + i][j] := s;
      end;
    end
    else
    begin
      if bufIdx >= bufCount then
        raise Exception.Create('Arrow: veri tamponu eksik');
      if not ArrowBuf(B, bufsField, bufIdx, BodyStart, BodyLen, dOff, dLen) then
        raise Exception.Create('Arrow: gecersiz veri tamponu');
      Inc(bufIdx);

      case AF[j].Ctype of
        VCT_INT:
          begin
            dataBytes := AF[j].BitWidth div 8;
            if dLen < Int64(rowCount) * dataBytes then
              raise Exception.Create('Arrow: Int tamponu cok kisa');
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Rows[oldRows + i][j] := ''
              else if AF[j].IsSigned then
              begin
                iv := ReadSignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                Rows[oldRows + i][j] := IntToStr(iv);
              end
              else
              begin
                uv := ReadUnsignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                Rows[oldRows + i][j] := UIntToStr(uv);
              end;
            end;
          end;
        VCT_FLOAT:
          begin
            precision := AF[j].Precision;
            if precision = 1 then dataBytes := 4 else dataBytes := 8;
            if dLen < Int64(rowCount) * dataBytes then
              raise Exception.Create('Arrow: Float tamponu cok kisa');
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Rows[oldRows + i][j] := ''
              else
                Rows[oldRows + i][j] :=
                  VDbFloatToStr(FbFloatAt(B, BodyStart + dOff + Int64(i) * dataBytes, precision));
            end;
          end;
        VCT_BOOL:
          begin
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Rows[oldRows + i][j] := ''
              else if (B[BodyStart + dOff + (i shr 3)] and (1 shl (i and 7))) <> 0 then
                Rows[oldRows + i][j] := 'true'
              else
                Rows[oldRows + i][j] := 'false';
            end;
          end;
        VCT_DATE:
          begin
            if AF[j].TimeUnit = 1 then dataBytes := 8 else dataBytes := 4;
            if dLen < Int64(rowCount) * dataBytes then
              raise Exception.Create('Arrow: Date tamponu cok kisa');
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Rows[oldRows + i][j] := ''
              else
              begin
                iv := ReadSignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                if AF[j].TimeUnit = 1 then iv := SecondsDiv(iv, 86400000);
                Rows[oldRows + i][j] := ArrowDateStr(iv);
              end;
            end;
          end;
        VCT_TIME:
          begin
            dataBytes := AF[j].TimeBits div 8;
            if dLen < Int64(rowCount) * dataBytes then
              raise Exception.Create('Arrow: Time tamponu cok kisa');
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Rows[oldRows + i][j] := ''
              else
              begin
                iv := ReadSignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                case AF[j].TimeUnit of
                  1: iv := SecondsDiv(iv, 1000);
                  2: iv := SecondsDiv(iv, 1000000);
                  3: iv := SecondsDiv(iv, 1000000000);
                end;
                Rows[oldRows + i][j] := ArrowTimeStr(iv);
              end;
            end;
          end;
        VCT_DATETIME:
          begin
            if dLen < Int64(rowCount) * 8 then
              raise Exception.Create('Arrow: Timestamp tamponu cok kisa');
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Rows[oldRows + i][j] := ''
              else
              begin
                iv := RI64(B, BodyStart + dOff + Int64(i) * 8);
                case AF[j].TimeUnit of
                  1: iv := SecondsDiv(iv, 1000);
                  2: iv := SecondsDiv(iv, 1000000);
                  3: iv := SecondsDiv(iv, 1000000000);
                end;
                Rows[oldRows + i][j] := ArrowDateTimeStr(iv);
              end;
            end;
          end;
      end;
    end;
  end;
  if bufIdx <> bufCount then
    raise Exception.CreateFmt('Arrow: kullanilmayan tamponlar (%d/%d)',
      [bufIdx, bufCount]);
end;

function VDbArrowImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;
var
  B: TBytes;
  pos, metaLen, metaStart, bodyStart, headerType, root, hdrField, hdr, blPos: Integer;
  bodyLen: Int64;
  cont: LongWord;
  AF: TArrowFieldArray;
  haveSchema: Boolean;
  i: Integer;
  typePos: Integer;
begin
  Fields := nil;
  Types := nil;
  Rows := nil;
  Err := '';
  haveSchema := False;
  try
    B := ReadFileBytes(FileName);
    pos := 0;
    while pos + 8 <= Length(B) do
    begin
      cont := RU32(B, pos);
      metaLen := Integer(RU32(B, pos + 4));
      Inc(pos, 8);
      if cont <> $FFFFFFFF then
        raise Exception.Create('Arrow: gecersiz stream devam isareti');
      if metaLen = 0 then Break;
      if pos + metaLen > Length(B) then
        raise Exception.Create('Arrow: metadata siniri asiyor');
      metaStart := pos;
      root := metaStart + Integer(RU32(B, metaStart));
      typePos := FbField(B, root, 1);
      if typePos = 0 then
        raise Exception.Create('Arrow: mesaj tipi alani yok');
      headerType := B[typePos];
      blPos := FbField(B, root, 3);
      if blPos <> 0 then bodyLen := RI64(B, blPos) else bodyLen := 0;
      if bodyLen < 0 then
        raise Exception.Create('Arrow: negatif gövde uzunlugu');
      bodyStart := metaStart + metaLen;
      if (bodyStart + bodyLen > Length(B)) or (bodyLen > MaxInt) then
        raise Exception.Create('Arrow: gövde siniri asiyor');
      hdrField := FbField(B, root, 2);
      hdr := FbOffsetOf(B, hdrField);
      case headerType of
        1:
          begin
            ArrowParseSchema(B, hdr, AF);
            SetLength(Fields, Length(AF));
            SetLength(Types, Length(AF));
            for i := 0 to High(AF) do
            begin
              Fields[i] := AF[i].Name;
              Types[i] := AF[i].Ctype;
            end;
            haveSchema := True;
          end;
        3:
          begin
            if not haveSchema then
              raise Exception.Create('Arrow: RecordBatch oncesi Schema yok');
            ArrowDecodeBatch(B, AF, hdr, bodyStart, bodyLen, Rows);
          end;
        else
          raise Exception.CreateFmt('Arrow: desteklenmeyen mesaj tipi %d',
            [headerType]);
      end;
      pos := bodyStart + Integer(bodyLen);
    end;
    if not haveSchema then
      raise Exception.Create('Arrow: Schema mesaji bulunamadi');
    Result := True;
  except
    on E: Exception do
    begin
      Fields := nil;
      Types := nil;
      Rows := nil;
      Err := E.Message;
      Result := False;
    end;
  end;
end;

end.
