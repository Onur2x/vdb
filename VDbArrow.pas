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
  SysUtils, Classes, DateUtils, VDbTypes, VDbTable, VDbDecimal;

function VDbArrowExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;

function VDbArrowImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;

{ SKILL13: tipli (TVdbCellMatrix) API. NULL ile bos metin/bos ikili
  veri bu yolda birbirinden ayrilir: vckNull -> gecerlilik biti 0,
  vckText/vckBlob (S = '') -> gecerli, sifir uzunluklu deger.
  Eski metin API'si korunur ve ayni cekirdegi kullanir; orada '' yine
  NULL sayilir (belgelenmis sinir). }
function VDbArrowExportCells(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;

function VDbArrowImportCells(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;

{ SKILL14: DECIMAL(p,s) icin Arrow Decimal128. Tip dizisinde VCT_DECIMAL
  olan kolonlarin hassasiyet/olcekleri Prec/Scale dizileriyle verilir
  (nil ise hucrelerden turetilir); boylece kolon semasindaki (p,s) aynen
  dosyaya yazilir. Okuma tarafinda ayni bilgi Prec/Scale olarak doner. }
function VDbArrowExportCellsEx(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Prec, Scale: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;

function VDbArrowImportCellsEx(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Prec, Scale: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;

{ SKILL13-E: toplu (batch) yazma/okuma. Dosya boyu buyuse de bellekte
  tek bir yigin tutulur; her cagri yalnizca o yigini isler. }
type
  TVdbArrowWriter = class
  private
    FStream: TFileStream;
    FFields: TStrArray;
    FTypes: TByteArray;
    FPrec: TByteArray;
    FScale: TByteArray;
    FClosed: Boolean;
    procedure WriteChunk(const Meta: TBytes; const Body: TBytes; BodyLen: Integer);
  public
    constructor Create(const FileName: string; const Fields: TStrArray;
      const Types: TByteArray);
    constructor CreateEx(const FileName: string; const Fields: TStrArray;
      const Types, Prec, Scale: TByteArray);
    procedure WriteBatch(const Cells: TVdbCellMatrix);
    procedure Close;
    destructor Destroy; override;
  end;

  TVdbArrowBatchEvent = procedure(const Cells: TVdbCellMatrix) of object;

{ SKILL13-E: akis halinde okuma. Dosya bellekte butun olarak tutulmaz;
  her RecordBatch tek tek okunup OnBatch'e verilir. }
function VDbArrowReadBatches(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  const OnBatch: TVdbArrowBatchEvent; out Err: string): Boolean;

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
    DecPrec: Integer;   // SKILL14: Arrow Decimal precision
    DecScale: Integer;  // SKILL14: Arrow Decimal scale
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
    VCT_DECIMAL: Result := 7;   // Decimal (SKILL14: Decimal128)
    VCT_DATE: Result := 8;      // Date
    VCT_TIME: Result := 9;      // Time
    VCT_DATETIME: Result := 10; // Timestamp
    else Result := 5;           // Utf8
  end;
end;

{ SKILL14: Arrow Decimal tablosu: precision (0), scale (1), bitWidth (2).
  bitWidth 128 -> degerler 16 bayt ikiye tumleyen little-endian. }
function MakeTypeTable(Doc: TFbDoc; Ctype: Byte;
  APrec, AScale: Byte): TFbNode;
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
    VCT_DECIMAL:
      begin
        Result := Doc.Table(2);
        if APrec = 0 then APrec := VDB_DEC_MAX_PREC;
        Result.AddScalar(0, ffI32, APrec);
        Result.AddScalar(1, ffI32, AScale);
        Result.AddScalar(2, ffI32, 128);
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

function MakeField(Doc: TFbDoc; const Name: string; Ctype: Byte;
  APrec, AScale: Byte): TFbNode;
begin
  Result := Doc.Table(6);
  Result.AddOffset(0, Doc.Str(Name));
  Result.AddScalar(1, ffBool, 1);
  Result.AddScalar(2, ffI8, ArrowTypeId(Ctype));
  Result.AddOffset(3, MakeTypeTable(Doc, Ctype, APrec, AScale));
end;

function MakeSchema(Doc: TFbDoc; const Fields: TStrArray;
  const Types: TByteArray; const Prec, Scale: TByteArray): TFbNode;
var
  vec: TFbNode;
  i, p, s: Integer;
begin
  vec := Doc.VecOff;
  for i := 0 to High(Fields) do
  begin
    p := 0;
    s := 0;
    if (i < Length(Prec)) then p := Prec[i];
    if (i < Length(Scale)) then s := Scale[i];
    vec.AddChild(MakeField(Doc, Fields[i], Types[i], Byte(p), Byte(s)));
  end;
  Result := Doc.Table(3);
  Result.AddScalar(0, ffI16, 0); // Little
  Result.AddOffset(1, vec);
end;

function MakeSchemaMessage(const Fields: TStrArray;
  const Types, Prec, Scale: TByteArray): TBytes;
var
  doc: TFbDoc;
  msg: TFbNode;
begin
  doc := TFbDoc.Create;
  try
    msg := doc.Table(4);
    msg.AddScalar(0, ffI16, 4); // MetadataVersion V5
    msg.AddScalar(1, ffI8, 1);  // MessageHeader.Schema
    msg.AddOffset(2, MakeSchema(doc, Fields, Types, Prec, Scale));
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
  out BodyLen: Integer; out Err: string): Boolean; forward;

{ SKILL13: tipli huceler icin deger cozumleyicileri. Hucere turu kolon
  turuyle uyusmuyorsa metin olarak yorumlanir; boylece eski metin yolu
  aynen korunur (or. "TRUE" yine true olur, cozulemeyen sayi 0 yazilir
  ama gecerlilik biti 1 kalir). }
function CellAsInt(const C: TVdbCell; out V: Int64): Boolean;
begin
  Result := True;
  case C.Kind of
    vckInt: V := C.I;
    vckFloat: V := Trunc(C.F);
    vckBool: if C.I <> 0 then V := 1 else V := 0;
  else
    if not VDbParseInt(C.S, V) then V := 0;
  end;
end;

function CellAsFloat(const C: TVdbCell; out V: Double): Boolean;
begin
  Result := True;
  case C.Kind of
    vckFloat: V := C.F;
    vckInt: V := C.I;
    vckBool: if C.I <> 0 then V := 1 else V := 0;
  else
    if not VDbParseFloat(C.S, V) then V := 0;
  end;
end;

function CellAsBool(const C: TVdbCell): Boolean;
var
  s: string;
begin
  case C.Kind of
    vckBool, vckInt: Result := C.I <> 0;
    vckFloat: Result := C.F <> 0;
  else
    s := LowerCase(C.S);
    Result := (s = 'true') or (s = '1');
  end;
end;

function CellAsStr(const C: TVdbCell): string;
begin
  case C.Kind of
    vckInt: Result := IntToStr(C.I);
    vckFloat: Result := VDbFloatToStr(C.F);
    vckBool: if C.I <> 0 then Result := 'true' else Result := 'false';
  else
    Result := C.S;
  end;
end;

{ SKILL14: 128-bit ondalik yardimcilari. Arrow Decimal128 degeri 16
  bayt ikiye tumleyen little-endian tam sayidir (deger = tam / 10^olcek). }
procedure DecMulAdd(var V: array of Byte; Mul, Add: Integer);
var
  i, carry, t: Integer;
begin
  carry := Add;
  for i := 0 to High(V) do
  begin
    t := V[i] * Mul + carry;
    V[i] := Byte(t and $FF);
    carry := t shr 8;
  end;
end;

function DecDigitsTo128(const Digits: string): TBytes;
var
  i: Integer;
begin
  SetLength(Result, 16);
  FillChar(Result[0], 16, 0);
  for i := 1 to Length(Digits) do
    if (Digits[i] >= '0') and (Digits[i] <= '9') then
      DecMulAdd(Result, 10, Ord(Digits[i]) - Ord('0'));
end;

procedure Dec128Negate(var V: TBytes);
var
  i, carry: Integer;
begin
  carry := 1;
  for i := 0 to 15 do
  begin
    V[i] := Byte((not V[i]) and $FF);
    if carry > 0 then
    begin
      V[i] := Byte(V[i] + 1);
      if V[i] <> 0 then carry := 0;
    end;
  end;
end;

function Dec128ToDigits(const V: TBytes): string;
var
  tmp: TBytes;
  i, r, k: Integer;
  buf: string;
  isZero: Boolean;
begin
  SetLength(tmp, 16);
  Move(V[0], tmp[0], 16);
  buf := '';
  while True do
  begin
    r := 0;
    for i := 15 downto 0 do
    begin
      r := r * 256 + tmp[i];
      tmp[i] := Byte(r div 10);
      r := r mod 10;
    end;
    buf := Chr(Ord('0') + r) + buf;
    isZero := True;
    for k := 0 to 15 do
      if tmp[k] <> 0 then
      begin isZero := False; Break; end;
    if isZero then Break;
  end;
  while (Length(buf) > 1) and (buf[1] = '0') do Delete(buf, 1, 1);
  if buf = '' then buf := '0';
  Result := buf;
end;

{ Hucre degerini verilen olcekte Decimal128 baytlarina cevirir.
  SKILL14: sessiz kirpma YOK. Ayristirilamayan, 128 bite sigmayan ya da
  bildirilen hassasiyeti asan deger hata dondurur (kesme yerine hata). }
function DecimalCellTo128(const C: TVdbCell; APrec, AScale: Integer;
  out V: TBytes; out Err: string): Boolean;
var
  d, r: TVdbDec;
  e: string;
begin
  Result := False;
  Err := '';
  SetLength(V, 16);
  FillChar(V[0], 16, 0);
  if not VdbDecParse(CellAsStr(C), d, e) then
  begin
    Err := 'Arrow: gecersiz DECIMAL: ' + CellAsStr(C);
    Exit;
  end;
  if not VdbDecRound(d, AScale, r, e) then
  begin
    Err := 'Arrow: DECIMAL yuvarlanamadi: ' + e;
    Exit;
  end;
  if Length(r.Digits) > 38 then
  begin
    Err := 'Arrow: DECIMAL 128 bite sigmiyor: ' + CellAsStr(C);
    Exit;
  end;
  if (APrec > 0) and (VdbDecPrecision(r) > APrec) then
  begin
    Err := Format('Arrow: DECIMAL hassasiyet tasmasi (%d > %d): %s',
      [VdbDecPrecision(r), APrec, CellAsStr(C)]);
    Exit;
  end;
  V := DecDigitsTo128(r.Digits);
  if r.Neg and (r.Digits <> '0') then
    Dec128Negate(V);
  Result := True;
end;
procedure LegacyCellOf(const S: string; Ctype: Byte; out C: TVdbCell);
var
  iv: Int64;
  fv: Double;
begin
  C.Kind := vckNull;
  C.I := 0;
  C.F := 0;
  C.S := '';
  if S = '' then Exit;
  case Ctype of
    VCT_INT:
      if VDbParseInt(S, iv) then
      begin C.Kind := vckInt; C.I := iv; end
      else
      begin C.Kind := vckText; C.S := S; end;
    VCT_FLOAT:
      if VDbParseFloat(S, fv) then
      begin C.Kind := vckFloat; C.F := fv; end
      else
      begin C.Kind := vckText; C.S := S; end;
    VCT_BOOL:
      begin
        C.Kind := vckBool;
        if (S = 'True') or (S = 'true') or (S = '1') then C.I := 1;
      end;
    VCT_BLOB:
      begin C.Kind := vckBlob; C.S := S; end;
  else
    begin C.Kind := vckText; C.S := S; end;
  end;
end;

function ExportBodyCells(const Fields: TStrArray; const Types: TByteArray;
  const Cells: TVdbCellMatrix; out Nodes, Buffers, Body: TBytes;
  out BodyLen: Integer; out Err: string;
  const DPrec: TByteArray = nil; const DScale: TByteArray = nil): Boolean;
var
  n, i, j, nulls, bitLen: Integer;
  validity, data, offs: TBytes;
  c: TVdbCell;
  s: string;
  iv: Int64;
  fv: Double;
  p, dsc, dpr: Integer;
  cdec: TVdbDec;
  dErr: string;
  db: TBytes;
begin
  Result := False;
  BodyLen := 0;
  SetLength(Body, 0);
  SetLength(Nodes, 0);
  SetLength(Buffers, 0);
  n := Length(Cells);
  if Length(Fields) <> Length(Types) then
  begin
    Err := 'Arrow: alan/tip sayisi uyusmuyor';
    Exit;
  end;
  SetLength(Nodes, Length(Fields) * 16);

  for j := 0 to High(Fields) do
  begin
    // SKILL13: NULL yalnizca vckNull'dur; '' gecerli bos degerdir.
    nulls := 0;
    for i := 0 to n - 1 do
      if (j >= Length(Cells[i])) or (Cells[i][j].Kind = vckNull) then Inc(nulls);
    bitLen := (n + 7) div 8;
    SetLength(validity, bitLen);
    if bitLen > 0 then
    begin
      FillChar(validity[0], bitLen, 0);
      for i := 0 to n - 1 do
        if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
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
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
            begin
              CellAsInt(Cells[i][j], iv);
              WI64(data, i * 8, iv);
            end;
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_FLOAT:
        begin
          SetLength(data, n * 8);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
            begin
              CellAsFloat(Cells[i][j], fv);
              Move(fv, data[i * 8], 8);
            end;
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_BOOL:
        begin
          bitLen := (n + 7) div 8;
          SetLength(data, bitLen);
          if Length(data) > 0 then FillChar(data[0], bitLen, 0);
          for i := 0 to n - 1 do
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
              if CellAsBool(Cells[i][j]) then
                data[i shr 3] := data[i shr 3] or (1 shl (i and 7));
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_DATE:
        begin
          SetLength(data, n * 4);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
            begin
              c := Cells[i][j];
              if c.Kind = vckInt then
                iv := c.I
              else if not DateToDays(c.S, iv) then
                iv := 0;
              WI32(data, i * 4, LongInt(iv));
            end;
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_DATETIME:
        begin
          SetLength(data, n * 8);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
            begin
              c := Cells[i][j];
              if c.Kind = vckInt then
                iv := c.I
              else if not DateTimeToSecs(c.S, iv) then
                iv := 0;
              WI64(data, i * 8, iv);
            end;
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_TIME:
        begin
          SetLength(data, n * 4);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
            begin
              c := Cells[i][j];
              if c.Kind = vckInt then
                iv := c.I
              else if not TimeToSecs(c.S, iv) then
                iv := 0;
              WI32(data, i * 4, LongInt(iv));
            end;
          AddBuffer(Body, BodyLen, Buffers, data);
        end;
      VCT_DECIMAL:
        begin
          { SKILL14: 16 bayt Decimal128. Olcek, kolon icin bildirilen
            DScale'den gelir; bildirilmemisse hucrenin kendi olcegi
            kullanilir. Hassasiyet DPrec'ten gelir; bildirilmemisse 38
            (Decimal128 ust siniri) kabul edilir. Tasma hata verir. }
          if j < Length(DScale) then
            dsc := DScale[j]
          else
          begin
            dsc := 0;
            for i := 0 to n - 1 do
              if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) and
                 VdbDecParse(CellAsStr(Cells[i][j]), cdec, dErr) then
              begin
                dsc := cdec.Scale;
                Break;
              end;
          end;
          if j < Length(DPrec) then
            dpr := DPrec[j]
          else
            dpr := VDB_DEC_MAX_PREC;
          SetLength(data, n * 16);
          if Length(data) > 0 then FillChar(data[0], Length(data), 0);
          for i := 0 to n - 1 do
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
            begin
              if not DecimalCellTo128(Cells[i][j], dpr, dsc, db, dErr) then
              begin
                Err := dErr;
                Exit;
              end;
              Move(db[0], data[i * 16], 16);
            end;
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
            if (j < Length(Cells[i])) and (Cells[i][j].Kind <> vckNull) then
            begin
              s := CellAsStr(Cells[i][j]);
              if Length(data) < p + Length(s) then
                SetLength(data, p + Length(s) + 64);
              if Length(s) > 0 then
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

{ Eski metin API'si: '' -> NULL (belgelenmis sinir), ayni cekirdek. }
function ExportBody(const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Nodes, Buffers, Body: TBytes;
  out BodyLen: Integer; out Err: string): Boolean;
var
  i, j: Integer;
  Cells: TVdbCellMatrix;
begin
  if Length(Fields) <> Length(Types) then
  begin
    Result := False;
    Err := 'Arrow: alan/tip sayisi uyusmuyor';
    Exit;
  end;
  SetLength(Cells, Length(Rows));
  for i := 0 to High(Rows) do
  begin
    SetLength(Cells[i], Length(Fields));
    for j := 0 to High(Fields) do
      if j < Length(Rows[i]) then
        LegacyCellOf(Rows[i][j], Types[j], Cells[i][j])
      else
        LegacyCellOf('', Types[j], Cells[i][j]);
  end;
  Result := ExportBodyCells(Fields, Types, Cells, Nodes, Buffers, Body,
    BodyLen, Err, nil, nil);
end;

function BuildBuffers(const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Nodes, Buffers, Body: TBytes;
  out BodyLen: Integer; out Err: string): Boolean;
begin
  Result := ExportBody(Fields, Types, Rows, Nodes, Buffers, Body, BodyLen, Err);
end;

constructor TVdbArrowWriter.Create(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray);
begin
  CreateEx(FileName, Fields, Types, nil, nil);
end;

constructor TVdbArrowWriter.CreateEx(const FileName: string;
  const Fields: TStrArray; const Types, Prec, Scale: TByteArray);
var
  schemaMsg: TBytes;
  i: Integer;
begin
  if Length(Fields) <> Length(Types) then
    raise Exception.Create('Arrow: alan/tip sayisi uyusmuyor');
  SetLength(FFields, Length(Fields));
  for i := 0 to High(Fields) do FFields[i] := Fields[i];
  SetLength(FTypes, Length(Types));
  for i := 0 to High(Types) do FTypes[i] := Types[i];
  SetLength(FPrec, 0);
  SetLength(FScale, 0);
  if Length(Prec) > 0 then
  begin
    SetLength(FPrec, Length(Prec));
    for i := 0 to High(Prec) do FPrec[i] := Prec[i];
  end;
  if Length(Scale) > 0 then
  begin
    SetLength(FScale, Length(Scale));
    for i := 0 to High(Scale) do FScale[i] := Scale[i];
  end;
  { SKILL14: Arrow semasi ilk yazimda sabitlenir; bu yuzden DECIMAL
    kolonun (p,s) bilgisi ONCEDEN verilmek zorundadir. Sessizce 0
    hassasiyetli gecersiz sema yazmak yerine acik hata verilir. }
  for i := 0 to High(FTypes) do
    if FTypes[i] = VCT_DECIMAL then
    begin
      if (i >= Length(FPrec)) or (FPrec[i] < 1) or (FPrec[i] > VDB_DEC_MAX_PREC) then
        raise Exception.CreateFmt(
          'Arrow: DECIMAL hassasiyeti 1..%d olmali', [VDB_DEC_MAX_PREC]);
      if (i >= Length(FScale)) or (FScale[i] > FPrec[i]) then
        raise Exception.Create('Arrow: DECIMAL olcegi hassasiyetten buyuk olamaz');
    end;
  FClosed := False;
  FStream := TFileStream.Create(FileName, fmCreate);
  try
    schemaMsg := MakeSchemaMessage(FFields, FTypes, FPrec, FScale);
    WriteChunk(schemaMsg, nil, 0);
  except
    FreeAndNil(FStream);
    raise;
  end;
end;

procedure TVdbArrowWriter.WriteChunk(const Meta: TBytes; const Body: TBytes;
  BodyLen: Integer);
var
  metaLen: Integer;
  pad: TBytes;
begin
  if FClosed then
    raise Exception.Create('Arrow: yazici kapatildi');
  metaLen := AlignUp(Length(Meta), 8);
  SetLength(pad, 8);
  WU32(pad, 0, $FFFFFFFF);
  WU32(pad, 4, LongWord(metaLen));
  FStream.WriteBuffer(pad[0], 8);
  if Length(Meta) > 0 then
    FStream.WriteBuffer(Meta[0], Length(Meta));
  if metaLen > Length(Meta) then
  begin
    SetLength(pad, metaLen - Length(Meta));
    FillChar(pad[0], Length(pad), 0);
    FStream.WriteBuffer(pad[0], Length(pad));
  end;
  if BodyLen > 0 then
  begin
    if BodyLen > Length(Body) then
      raise Exception.Create('Arrow: govde tamponu kisa');
    FStream.WriteBuffer(Body[0], BodyLen);
  end;
end;

procedure TVdbArrowWriter.WriteBatch(const Cells: TVdbCellMatrix);
var
  nodes, buffers, body, rbMsg: TBytes;
  bodyLen: Integer;
  err: string;
begin
  if not ExportBodyCells(FFields, FTypes, Cells, nodes, buffers, body, bodyLen,
    err, FPrec, FScale) then
    raise Exception.Create(err);
  bodyLen := AlignUp(bodyLen, 8);
  if Length(body) < bodyLen then
    SetLength(body, bodyLen);
  rbMsg := MakeRecordBatchMessage(Length(Cells), nodes, buffers, bodyLen);
  WriteChunk(rbMsg, body, bodyLen);
end;

procedure TVdbArrowWriter.Close;
var
  pad: TBytes;
begin
  if FClosed then Exit;
  FClosed := True;
  if FStream = nil then Exit;
  SetLength(pad, 8);
  WU32(pad, 0, $FFFFFFFF);
  WU32(pad, 4, 0);
  FStream.WriteBuffer(pad[0], 8);
  FreeAndNil(FStream);
end;

destructor TVdbArrowWriter.Destroy;
begin
  try
    Close;
  except
    // yikici icinde istisna yukseltilmez; kismi dosya zaten gecersizdir.
    FreeAndNil(FStream);
  end;
  inherited;
end;

function VDbArrowExportCellsEx(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Prec, Scale: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;
var
  w: TVdbArrowWriter;
begin
  Result := False;
  Err := '';
  try
    w := TVdbArrowWriter.CreateEx(FileName, Fields, Types, Prec, Scale);
    try
      w.WriteBatch(Cells);
      w.Close;
      Result := True;
    finally
      w.Free;
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

function VDbArrowExportCells(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;
begin
  Result := VDbArrowExportCellsEx(FileName, Fields, Types, nil, nil, Cells, Err);
end;

function VDbArrowExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;
var
  Cells: TVdbCellMatrix;
  i, j: Integer;
begin
  Result := False;
  Err := '';
  if Length(Fields) <> Length(Types) then
  begin
    Err := 'Arrow: alan/tip sayisi uyusmuyor';
    Exit;
  end;
  SetLength(Cells, Length(Rows));
  for i := 0 to High(Rows) do
  begin
    SetLength(Cells[i], Length(Fields));
    for j := 0 to High(Fields) do
      if j < Length(Rows[i]) then
        LegacyCellOf(Rows[i][j], Types[j], Cells[i][j])
      else
        LegacyCellOf('', Types[j], Cells[i][j]);
  end;
  Result := VDbArrowExportCells(FileName, Fields, Types, Cells, Err);
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
    7: // Decimal (SKILL14): precision (0), scale (1), bitWidth (2)
      begin
        AF.Ctype := VCT_DECIMAL;
        AF.DecPrec := FbInt32(B, FbField(B, TypeTable, 0), 0);
        AF.DecScale := FbInt32(B, FbField(B, TypeTable, 1), 0);
        AF.BitWidth := FbInt32(B, FbField(B, TypeTable, 2), 128);
        if AF.BitWidth <> 128 then
          raise Exception.CreateFmt('Arrow: yalniz Decimal128 desteklenir (bitWidth=%d)',
            [AF.BitWidth]);
        if (AF.DecPrec < 1) or (AF.DecPrec > VDB_DEC_MAX_PREC) or
           (AF.DecScale < 0) or (AF.DecScale > AF.DecPrec) then
          raise Exception.Create('Arrow: gecersiz DECIMAL hassasiyet/olcek');
      end;
    8: // Date
      begin
        AF.Ctype := VCT_DATE;
        // Arrow semasinda Date.unit varsayilani MILLISECOND'dur; pyarrow bu
        // degeri varsayilana esit oldugunda tabloya hic yazmaz (date64).
        AF.TimeUnit := FbInt16(B, FbField(B, TypeTable, 0), 1);
        if not (AF.TimeUnit in [0, 1]) then
          raise Exception.Create('Arrow: desteklenmeyen Date birimi');
      end;
    9: // Time
      begin
        AF.Ctype := VCT_TIME;
        // Arrow semasinda Time.unit varsayilani MILLISECOND'dur (bitWidth 32).
        // pyarrow time32[ms] icin unit alanini yazmaz; 0 varsaymak saniyeye
        // dusurup degeri 1000 kat sisiriyordu (time32[s] ise acikca 0 yazar).
        AF.TimeUnit := FbInt16(B, FbField(B, TypeTable, 0), 1);
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

function CellOf(Kind: TVdbCellKind; I: Int64; F: Double;
  const S: string): TVdbCell;
begin
  Result.Kind := Kind;
  Result.I := I;
  Result.F := F;
  Result.S := S;
end;

procedure ArrowDecodeCells(const B: TBytes; const AF: TArrowFieldArray;
  RBPos, BodyStart: Integer; BodyLen: Int64; var Cells: TVdbCellMatrix);
var
  rowCount, oldRows, i, j, bufIdx, bufCount, nodeCount: Integer;
  row64: Int64;
  nodesField, bufsField, dataBytes, offBytes: Integer;
  vOff, vLen, dOff, dLen, oOff, oLen, o1, o2: Int64;
  iv: Int64;
  uv: QWord;
  s: string;
  fv: Double;
  precision: Integer;
  valid: Boolean;
  db: TBytes;
  dd: TVdbDec;
  neg: Boolean;
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

  oldRows := Length(Cells);
  if rowCount > MaxInt - oldRows then
    raise Exception.Create('Arrow: satir sayisi cok buyuk');
  SetLength(Cells, oldRows + rowCount);
  for i := 0 to rowCount - 1 do
    SetLength(Cells[oldRows + i], Length(AF));

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
          Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '');
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
        // SKILL13: sifir uzunluklu metin/ikili GECERLI bir degerdir.
        if AF[j].Ctype = VCT_BLOB then
          Cells[oldRows + i][j] := CellOf(vckBlob, 0, 0, s)
        else
          Cells[oldRows + i][j] := CellOf(vckText, 0, 0, s);
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
                Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '')
              else if AF[j].IsSigned then
              begin
                iv := ReadSignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                Cells[oldRows + i][j] := CellOf(vckInt, iv, 0, '');
              end
              else
              begin
                uv := ReadUnsignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                // Int64'e sigmayan isaretsiz deger metin olarak korunur.
                if uv <= QWord(High(Int64)) then
                  Cells[oldRows + i][j] := CellOf(vckInt, Int64(uv), 0, '')
                else
                  Cells[oldRows + i][j] := CellOf(vckText, 0, 0, UIntToStr(uv));
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
                Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '')
              else
              begin
                fv := FbFloatAt(B, BodyStart + dOff + Int64(i) * dataBytes, precision);
                Cells[oldRows + i][j] := CellOf(vckFloat, 0, fv, '');
              end;
            end;
          end;
        VCT_BOOL:
          begin
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '')
              else if (B[BodyStart + dOff + (i shr 3)] and (1 shl (i and 7))) <> 0 then
                Cells[oldRows + i][j] := CellOf(vckBool, 1, 0, '')
              else
                Cells[oldRows + i][j] := CellOf(vckBool, 0, 0, '');
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
                Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '')
              else
              begin
                iv := ReadSignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                if AF[j].TimeUnit = 1 then iv := SecondsDiv(iv, 86400000);
                // Tarih/saat tipli hucrede de ISO metin olarak tasinir.
                Cells[oldRows + i][j] := CellOf(vckText, 0, 0, ArrowDateStr(iv));
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
                Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '')
              else
              begin
                iv := ReadSignedAt(B, BodyStart + dOff + Int64(i) * dataBytes, dataBytes);
                case AF[j].TimeUnit of
                  1: iv := SecondsDiv(iv, 1000);
                  2: iv := SecondsDiv(iv, 1000000);
                  3: iv := SecondsDiv(iv, 1000000000);
                end;
                Cells[oldRows + i][j] := CellOf(vckText, 0, 0, ArrowTimeStr(iv));
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
                Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '')
              else
              begin
                iv := RI64(B, BodyStart + dOff + Int64(i) * 8);
                case AF[j].TimeUnit of
                  1: iv := SecondsDiv(iv, 1000);
                  2: iv := SecondsDiv(iv, 1000000);
                  3: iv := SecondsDiv(iv, 1000000000);
                end;
                Cells[oldRows + i][j] := CellOf(vckText, 0, 0, ArrowDateTimeStr(iv));
              end;
            end;
          end;
        VCT_DECIMAL:
          begin
            { SKILL14: 16 bayt ikiye tumleyen little-endian Decimal128.
              Metin olarak kanonik ondalik degere cevrilir. }
            if dLen < Int64(rowCount) * 16 then
              raise Exception.Create('Arrow: Decimal tamponu cok kisa');
            for i := 0 to rowCount - 1 do
            begin
              valid := ValidAt(B, BodyStart, vOff, vLen, i);
              if not valid then
                Cells[oldRows + i][j] := CellOf(vckNull, 0, 0, '')
              else
              begin
                SetLength(db, 16);
                Move(B[BodyStart + dOff + Int64(i) * 16], db[0], 16);
                neg := (db[15] and $80) <> 0;
                if neg then Dec128Negate(db);
                dd.Neg := neg;
                dd.Digits := Dec128ToDigits(db);
                dd.Scale := AF[j].DecScale;
                Cells[oldRows + i][j] := CellOf(vckText, 0, 0, VdbDecToStr(dd));
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

{ SKILL13: hucre matrisinden metin matrisi uretir; NULL '' olur. }
procedure ArrowCellsToRows(const Cells: TVdbCellMatrix; out Rows: TStrMatrix);
var
  i, j: Integer;
begin
  SetLength(Rows, Length(Cells));
  for i := 0 to High(Cells) do
  begin
    SetLength(Rows[i], Length(Cells[i]));
    for j := 0 to High(Cells[i]) do
      Rows[i][j] := CellAsStr(Cells[i][j]);
  end;
end;

function ReadArrowCells(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string;
  out Prec, Scale: TByteArray): Boolean;
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
  Cells := nil;
  Prec := nil;
  Scale := nil;
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
        raise Exception.Create('Arrow: govde siniri asiyor');
      hdrField := FbField(B, root, 2);
      hdr := FbOffsetOf(B, hdrField);
      case headerType of
        1:
          begin
            ArrowParseSchema(B, hdr, AF);
            SetLength(Fields, Length(AF));
            SetLength(Types, Length(AF));
            SetLength(Prec, Length(AF));
            SetLength(Scale, Length(AF));
            for i := 0 to High(AF) do
            begin
              Fields[i] := AF[i].Name;
              Types[i] := AF[i].Ctype;
              Prec[i] := Byte(AF[i].DecPrec);
              Scale[i] := Byte(AF[i].DecScale);
            end;
            haveSchema := True;
          end;
        3:
          begin
            if not haveSchema then
              raise Exception.Create('Arrow: RecordBatch oncesi Schema yok');
            ArrowDecodeCells(B, AF, hdr, bodyStart, bodyLen, Cells);
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
      Cells := nil;
      Prec := nil;
      Scale := nil;
      Err := E.Message;
      Result := False;
    end;
  end;
end;

function VDbArrowImportCellsEx(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Prec, Scale: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;
begin
  Result := ReadArrowCells(FileName, Fields, Types, Cells, Err, Prec, Scale);
end;

function VDbArrowImportCells(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;
var
  pr, sc: TByteArray;
begin
  Result := ReadArrowCells(FileName, Fields, Types, Cells, Err, pr, sc);
end;

function VDbArrowImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;
var
  Cells: TVdbCellMatrix;
  pr, sc: TByteArray;
begin
  Rows := nil;
  Result := ReadArrowCells(FileName, Fields, Types, Cells, Err, pr, sc);
  if Result then
    ArrowCellsToRows(Cells, Rows);
end;

function VDbArrowReadBatches(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  const OnBatch: TVdbArrowBatchEvent; out Err: string): Boolean;
var
  fs: TFileStream;
  meta: TBytes;
  AF: TArrowFieldArray;
  metaLen, root, typePos, headerType, hdr, blPos, i: Integer;
  bodyLen: Int64;
  haveSchema: Boolean;
  cells: TVdbCellMatrix;
begin
  Fields := nil;
  Types := nil;
  Err := '';
  haveSchema := False;
  AF := nil;
  fs := nil;
  try
    fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    while fs.Position + 8 <= fs.Size do
    begin
      SetLength(meta, 8);
      fs.ReadBuffer(meta[0], 8);
      if RU32(meta, 0) <> $FFFFFFFF then
        raise Exception.Create('Arrow: gecersiz stream devam isareti');
      metaLen := Integer(RU32(meta, 4));
      if metaLen = 0 then Break;   // EOS
      if (metaLen < 0) or (fs.Position + metaLen > fs.Size) then
        raise Exception.Create('Arrow: metadata siniri asiyor');
      SetLength(meta, metaLen);
      fs.ReadBuffer(meta[0], metaLen);
      root := Integer(RU32(meta, 0));
      typePos := FbField(meta, root, 1);
      if typePos = 0 then
        raise Exception.Create('Arrow: mesaj tipi alani yok');
      headerType := meta[typePos];
      blPos := FbField(meta, root, 3);
      if blPos <> 0 then bodyLen := RI64(meta, blPos) else bodyLen := 0;
      if (bodyLen < 0) or (bodyLen > MaxInt) then
        raise Exception.Create('Arrow: gecersiz govde uzunlugu');
      if fs.Position + bodyLen > fs.Size then
        raise Exception.Create('Arrow: govde siniri asiyor');
      hdr := FbOffsetOf(meta, FbField(meta, root, 2));
      case headerType of
        1:
          begin
            ArrowParseSchema(meta, hdr, AF);
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
            // Govde metadata'nin hemen ardina eklenir; tek yigin.
            SetLength(meta, metaLen + Integer(bodyLen));
            if bodyLen > 0 then
              fs.ReadBuffer(meta[metaLen], bodyLen);
            cells := nil;
            ArrowDecodeCells(meta, AF, hdr, metaLen, bodyLen, cells);
            if Assigned(OnBatch) then OnBatch(cells);
          end;
        else
          raise Exception.CreateFmt('Arrow: desteklenmeyen mesaj tipi %d',
            [headerType]);
      end;
      if (headerType <> 3) and (bodyLen > 0) then
        fs.Seek(bodyLen, soCurrent);
    end;
    if not haveSchema then
      raise Exception.Create('Arrow: Schema mesaji bulunamadi');
    Result := True;
  except
    on E: Exception do
    begin
      Fields := nil;
      Types := nil;
      Err := E.Message;
      Result := False;
    end;
  end;
  FreeAndNil(fs);
end;

end.

end.
