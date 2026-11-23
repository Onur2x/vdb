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
    DECIMAL  -> FIXED_LEN_BYTE_ARRAY(16) (DECIMAL)

  Okuyucu ayrica pyarrow'un yazdigi dictionary sayfalarini, DataPage v1/v2
  ve INT96 zaman damgalarini da cozer. Nested/repeated alanlar reddedilir. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, Math, VDbTypes, VDbTable, VDbDecimal;

function VDbParquetExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;

function VDbParquetImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;

{ SKILL13: tipli API. NULL (tanim seviyesi 0) ile bos metin/bos ikili
  veri (tanim seviyesi 1, sifir uzunluk) ayrilir. Eski metin API'si
  korunur ve ayni cekirdegi kullanir; orada '' yine NULL sayilir. }
function VDbParquetExportCells(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;

function VDbParquetImportCells(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;

{ SKILL14: DECIMAL(p,s) icin Parquet DECIMAL mantiksal tipi. Tip dizisinde
  VCT_DECIMAL olan kolonlar FIXED_LEN_BYTE_ARRAY(16) olarak yazilir; (p,s)
  Prec/Scale dizileriyle verilir (nil ise 38 ve hucrelerden turetilen olcek).
  Okuma tarafinda ayni bilgi Prec/Scale olarak doner. }
function VDbParquetExportCellsEx(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Prec, Scale: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;

function VDbParquetImportCellsEx(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Prec, Scale: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;

{ SKILL13-E: toplu yazma. Her WriteBatch ayri bir satir grubu olur;
  veri bellekte birikmez, yalnizca satir grubu ustbilgisi tutulur.
  Kuyruk (footer) Close'ta yazilir.

  SKILL15: sayfa sikistirmasi (UNCOMPRESSED/SNAPPY, saf Pascal) ve satir
  grubu boyu ayarlanabilir. Codec 0/1 disinda bir deger acik hata verir
  (ZSTD/GZIP icin saglayici yoktur; sessiz geri dusme yoktur).
  MaxRowsPerGroup > 0 ise bir WriteBatch birden fazla satir grubuna bolunur. }
const
  PQ_CODEC_UNCOMPRESSED = 0;
  PQ_CODEC_SNAPPY = 1;

type
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
    TypeLength: Integer;
    DecScale: Integer;
    DecPrec: Integer;
    { SKILL15: sayfa sikistirma. TotalSize = diskteki toplam (baslik +
      sikistirilmis govde), CompressedSize ayni deger, UncompressedSize
      baslik + cozulmus govde. }
    Codec: Integer;
    CompressedSize: Int64;
    UncompressedSize: Int64;
  end;

  TParquetGroupWrite = record
    Cols: array of TColWrite;
    NumRows: Int64;
  end;

  TVdbParquetBatchEvent = procedure(const Cells: TVdbCellMatrix) of object;

  TVdbParquetWriter = class
  private
    FStream: TFileStream;
    FFields: TStrArray;
    FTypes: TByteArray;
    FPrec: TByteArray;
    FScale: TByteArray;
    FGroups: array of TParquetGroupWrite;
    FNumRows: Int64;
    FClosed: Boolean;
    FCodec: Integer;
    FMaxRowsPerGroup: Int64;
    { SKILL15-C/D: MaxRowsPerGroup > 0 iken satirlar burada biriktirilir ve
      grup dolunca (ya da Close'ta) diske yazilir. Bellek en fazla bir grup. }
    FPend: TVdbCellMatrix;
    procedure DeriveDecSpec(const Cells: TVdbCellMatrix);
    procedure DoWriteGroup(const Cells: TVdbCellMatrix);
    procedure FlushPending;
    function GetBytesWritten: Int64;
  public
    constructor Create(const FileName: string; const Fields: TStrArray;
      const Types: TByteArray);
    constructor CreateEx(const FileName: string; const Fields: TStrArray;
      const Types: TByteArray; const Prec, Scale: TByteArray);
    procedure WriteBatch(const Cells: TVdbCellMatrix);
    procedure Close;
    destructor Destroy; override;
    { SKILL15: sayfa sikistirma kodu (PQ_CODEC_UNCOMPRESSED/SNAPPY). }
    property Codec: Integer read FCodec write FCodec;
    { SKILL15: 0 = her WriteBatch tek satir grubu; > 0 ise bolunur. }
    property MaxRowsPerGroup: Int64 read FMaxRowsPerGroup write FMaxRowsPerGroup;
    { SKILL15-D: su ana kadar diske yazilmis bayt (akis kaniti icin). }
    property BytesWritten: Int64 read GetBytesWritten;
  end;

{ SKILL13-E: akis halinde okuma. Dosya butun olarak bellekte tutulmaz;
  her satir grubu (kolon dilimi) tek tek okunup OnBatch'e verilir. }
function VDbParquetReadBatches(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  const OnBatch: TVdbParquetBatchEvent; out Err: string): Boolean;

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
  CT_DECIMAL = 5;
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
    LogicalKind: Integer;   // 1=STRING, 5=DECIMAL, 6=DATE, 7=TIME, 8=TIMESTAMP, 10=INT
    LogicalUnit: Integer;   // 1=millis, 2=micros, 3=nanos
    TypeLength: Integer;    // FIXED_LEN_BYTE_ARRAY bayt uzunlugu
    DecScale: Integer;      // DECIMAL olcek
    DecPrec: Integer;       // DECIMAL hassasiyet
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

  TVdbCellArray = array of TVdbCell;
  TParquetSchemaArray = array of TParquetSchemaElem;

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

{ SKILL15-A: saf Pascal SNAPPY **yazici** (blok bicimi). Cikti:
  varint(cozulmus boy) + literal/copy etiketleri. Tampon buyumesi disinda
  bellek kullanmaz; harici DLL/bagimlilik yoktur. Ayni bicim hem kendi
  cozucumuzle (SnappyDecompress) hem pyarrow ile dogrulanir.
  Sikistirma orani icin 4 baytlik kayan pencere + hash tablosu kullanilir;
  eslesme bulunamazsa literal yazilir (gecerli SNAPPY, sadece daha buyuk). }
function SnappyCompress(const Src: TBytes; out Dst: TBytes): Boolean;
const
  HASH_BITS = 14;
  HASH_SIZE = 1 shl HASH_BITS;
  MAX_COPY2 = 64;
var
  n, ip, nextEmit, op, cap, h, cand, matchLen, i: Integer;
  table: array of Integer;
  buf: TBytes;
  U: LongWord;

  procedure Grow(AExtra: Integer);
  begin
    if op + AExtra <= cap then Exit;
    if cap < 128 then cap := 128;
    while op + AExtra > cap do cap := cap * 2;
    SetLength(buf, cap);
  end;

  procedure EmitVarint(AValue: LongWord);
  var
    V: LongWord;
  begin
    V := AValue;
    while V >= 128 do
    begin
      Grow(1);
      buf[op] := Byte((V and 127) or 128);
      Inc(op);
      V := V shr 7;
    end;
    Grow(1);
    buf[op] := Byte(V);
    Inc(op);
  end;

  procedure EmitLiteral(AStart, ALen: Integer);
  var
    L, nb, i2: Integer;
    V: LongWord;
  begin
    if ALen <= 0 then Exit;
    L := ALen - 1;
    if L < 60 then
    begin
      Grow(1 + ALen);
      buf[op] := Byte(L shl 2);
      Inc(op);
    end
    else
    begin
      V := LongWord(L);
      nb := 1;
      while (nb < 4) and ((V shr (8 * nb)) <> 0) do Inc(nb);
      Grow(1 + nb + ALen);
      buf[op] := Byte((59 + nb) shl 2);
      Inc(op);
      for i2 := 0 to nb - 1 do
      begin
        buf[op] := Byte(V shr (8 * i2));
        Inc(op);
      end;
    end;
    Move(Src[AStart], buf[op], ALen);
    Inc(op, ALen);
  end;

  procedure EmitCopy(AOffset, ALen: Integer);
  var
    L, chunk: Integer;
  begin
    L := ALen;
    while L > MAX_COPY2 do
    begin
      if L - MAX_COPY2 < 4 then chunk := 60 else chunk := MAX_COPY2;
      Grow(3);
      buf[op] := Byte(((chunk - 1) shl 2) or 2);
      Inc(op);
      buf[op] := Byte(AOffset and 255);
      buf[op + 1] := Byte((AOffset shr 8) and 255);
      Inc(op, 2);
      Dec(L, chunk);
    end;
    if L < 4 then Exit;
    Grow(3);
    buf[op] := Byte(((L - 1) shl 2) or 2);
    Inc(op);
    buf[op] := Byte(AOffset and 255);
    buf[op + 1] := Byte((AOffset shr 8) and 255);
    Inc(op, 2);
  end;

begin
  Result := False;
  Dst := nil;
  n := Length(Src);
  if n = 0 then
  begin
    // Gecerli bos SNAPPY blogu: yalnizca varint 0.
    SetLength(Dst, 1);
    Dst[0] := 0;
    Result := True;
    Exit;
  end;
  if n > 2000000000 then Exit;
  cap := n + (n div 32) + 64;
  SetLength(buf, cap);
  op := 0;
  EmitVarint(LongWord(n));
  SetLength(table, HASH_SIZE);
  for i := 0 to HASH_SIZE - 1 do table[i] := -1;
  ip := 0;
  nextEmit := 0;
  while ip + 4 <= n do
  begin
    U := LongWord(Src[ip]) or (LongWord(Src[ip + 1]) shl 8) or
         (LongWord(Src[ip + 2]) shl 16) or (LongWord(Src[ip + 3]) shl 24);
    h := Integer((QWord(U) * 506832829) shr 32) and (HASH_SIZE - 1);
    cand := table[h];
    table[h] := ip;
    if (cand >= 0) and ((ip - cand) <= 65535) and
       (Src[cand] = Src[ip]) and (Src[cand + 1] = Src[ip + 1]) and
       (Src[cand + 2] = Src[ip + 2]) and (Src[cand + 3] = Src[ip + 3]) then
    begin
      if ip > nextEmit then EmitLiteral(nextEmit, ip - nextEmit);
      matchLen := 4;
      while (ip + matchLen < n) and (Src[cand + matchLen] = Src[ip + matchLen]) do
        Inc(matchLen);
      EmitCopy(ip - cand, matchLen);
      Inc(ip, matchLen);
      nextEmit := ip;
      Continue;
    end;
    Inc(ip);
  end;
  if n > nextEmit then EmitLiteral(nextEmit, n - nextEmit);
  SetLength(buf, op);
  Dst := buf;
  Result := True;
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
  Result := FormatDateTime('hh:nn:ss', UnixToDateTime(secs));
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
  // UnixToDateTime: "1970-01-01 + secs/86400.0" FPC'de hassasiyet kaybediyor.
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(secs));
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
    Secs := DateTimeToUnix(d);
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
    CT_DECIMAL: Result := 5;
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

procedure ParseLogicalType(R: TThriftReader; var Kind, UnitKind: Integer;
  var DecScale, DecPrec: Integer);
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
    else if (t = TT_STRUCT) and (id = 5) then
    begin
      // DecimalType: 1=scale, 2=precision
      Kind := id;
      R.Push;
      while R.ReadField(id, t) do
      begin
        if id = 1 then
          DecScale := R.ReadI32
        else if id = 2 then
          DecPrec := R.ReadI32
        else
          R.Skip(t);
      end;
      R.Pop;
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
  SE.TypeLength := 0;
  SE.DecScale := 0;
  SE.DecPrec := 0;
  R.Push;
  while R.ReadField(id, t) do
  begin
    case id of
      1: SE.PType := R.ReadI32;
      2: SE.TypeLength := R.ReadI32;
      3: SE.Repetition := R.ReadI32;
      4: SE.Name := R.ReadBinary;
      5: SE.NumChildren := R.ReadI32;
      6: SE.Converted := R.ReadI32;
      7: SE.DecScale := R.ReadI32;
      8: SE.DecPrec := R.ReadI32;
      10:
        begin
          ParseLogicalType(R, lk, lu, SE.DecScale, SE.DecPrec);
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
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(secs));
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
    VCT_DECIMAL:
      begin
        Result := PT_FIXED;
        Converted := CT_DECIMAL;
        LogKind := 5;
      end;
  else
    begin
      Result := PT_BYTE_ARRAY;
      Converted := CT_UTF8;
      LogKind := 1;
    end;
  end;
end;

procedure WriteLogicalType(W: TThriftWriter; Kind, UnitKind: Integer;
  DecScale, DecPrec: Integer);
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
    5:
      begin
        W.Field(5, TT_STRUCT);
        W.BeginStruct;
        W.WriteI32Field(1, DecScale);
        W.WriteI32Field(2, DecPrec);
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

function ParquetCellStr(const C: TVdbCell): string;
begin
  case C.Kind of
    vckInt: Result := IntToStr(C.I);
    vckFloat: Result := VDbFloatToStr(C.F);
    vckBool: if C.I <> 0 then Result := 'true' else Result := 'false';
  else
    Result := C.S;
  end;
end;

{ SKILL14: Parquet DECIMAL degerleri FIXED_LEN_BYTE_ARRAY icinde buyuk-endian
  ikiye tumleyen (two's complement) tam sayidir; deger = tam / 10^olcek.
  Asagidaki yardimcilar 16 baytlik kanonik kanavi kullanir. }
procedure DecMulAddBE(var V: array of Byte; Mul, Add: Integer);
var
  i, carry, t: Integer;
begin
  carry := Add;
  for i := High(V) downto 0 do
  begin
    t := V[i] * Mul + carry;
    V[i] := Byte(t and $FF);
    carry := t shr 8;
  end;
  if carry <> 0 then
    raise Exception.Create('Parquet: DECIMAL 128 bit sinirini asiyor');
end;

function DecDigitsToFixed16(const Digits: string; Neg: Boolean): TBytes;
var
  i, k: Integer;
  zero: Boolean;
begin
  SetLength(Result, 16);
  FillChar(Result[0], 16, 0);
  for i := 1 to Length(Digits) do
    if (Digits[i] >= '0') and (Digits[i] <= '9') then
      DecMulAddBE(Result, 10, Ord(Digits[i]) - Ord('0'));
  zero := True;
  for k := 0 to 15 do
    if Result[k] <> 0 then
    begin
      zero := False;
      Break;
    end;
  if Neg and not zero then
  begin
    for k := 0 to 15 do
      Result[k] := Byte((not Result[k]) and $FF);
    for k := 15 downto 0 do
    begin
      Result[k] := Byte(Result[k] + 1);
      if Result[k] <> 0 then Break;
    end;
  end;
end;

function DecFixedToStr(const B: TBytes; P, Width, Scale: Integer): string;
var
  buf: array[0..15] of Byte;
  i, k, r: Integer;
  neg, isZero: Boolean;
  digs: string;
  d: TVdbDec;
begin
  if (Width <= 0) or (Width > 16) then
    raise Exception.CreateFmt('Parquet: gecersiz DECIMAL bayt uzunlugu %d', [Width]);
  if (P < 0) or (P + Width > Length(B)) then
    raise Exception.Create('Parquet: DECIMAL baytlari bitti');
  if (B[P] and $80) <> 0 then
    FillChar(buf, 16, $FF)
  else
    FillChar(buf, 16, 0);
  for i := 0 to Width - 1 do
    buf[16 - Width + i] := B[P + i];
  neg := (buf[0] and $80) <> 0;
  if neg then
  begin
    for k := 0 to 15 do
      buf[k] := Byte((not buf[k]) and $FF);
    for k := 15 downto 0 do
    begin
      buf[k] := Byte(buf[k] + 1);
      if buf[k] <> 0 then Break;
    end;
  end;
  digs := '';
  repeat
    r := 0;
    for i := 0 to 15 do
    begin
      r := r * 256 + buf[i];
      buf[i] := Byte(r div 10);
      r := r mod 10;
    end;
    digs := Chr(Ord('0') + r) + digs;
    isZero := True;
    for k := 0 to 15 do
      if buf[k] <> 0 then
      begin
        isZero := False;
        Break;
      end;
  until isZero;
  while (Length(digs) > 1) and (digs[1] = '0') do Delete(digs, 1, 1);
  if digs = '' then digs := '0';
  d.Digits := digs;
  d.Scale := Scale;
  if Scale < 0 then d.Scale := 0;
  d.Neg := neg and (digs <> '0');
  Result := VdbDecToStr(d);
end;

function BuildPageCells(ColIdx: Integer; const Fields: TStrArray;
  const Types: TByteArray; const DPrec, DScale: TByteArray;
  ACodec: Integer; const Cells: TVdbCellMatrix;
  out Header, Body: TBytes; out ARawSize: Int64): Boolean;
var
  bits, values, def: TBytes;
  n, i, present, boolPos, L: Integer;
  c: TVdbCell;
  s: string;
  iv: Int64;
  dv: Double;
  byt: Byte;
  ptype: Integer;
  conv, lk, lu: Integer;
  dsc, dpr: Integer;
  dd, dr: TVdbDec;
  de: string;
  db16: TBytes;
  cbody: TBytes;
  W: TThriftWriter;
begin
  Result := False;
  n := Length(Cells);
  SetLength(bits, (n + 7) div 8);
  if Length(bits) > 0 then FillChar(bits[0], Length(bits), 0);
  SetLength(values, 0);
  present := 0;
  // SKILL13: yalnizca vckNull tanim seviyesi 0'dir; bos metin/ikili
  // veri tanimli (seviye 1) ve sifir uzunluktadir.
  for i := 0 to n - 1 do
  begin
    c.Kind := vckNull;
    c.I := 0;
    c.F := 0;
    c.S := '';
    if ColIdx < Length(Cells[i]) then c := Cells[i][ColIdx];
    if c.Kind <> vckNull then
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
    c.Kind := vckNull;
    c.I := 0;
    c.F := 0;
    c.S := '';
    if ColIdx < Length(Cells[i]) then c := Cells[i][ColIdx];
    if c.Kind = vckNull then Continue;
    case ptype of
      PT_BOOLEAN:
        begin
          byt := 0;
          case c.Kind of
            vckBool, vckInt: if c.I <> 0 then byt := 1;
            vckFloat: if c.F <> 0 then byt := 1;
          else
            s := c.S;
            if s = '1' then byt := 1;
            if SameText(s, 'true') or SameText(s, 'yes') then byt := 1;
          end;
          if byt <> 0 then
            values[boolPos div 8] := values[boolPos div 8] or (1 shl (boolPos mod 8));
          Inc(boolPos);
        end;
      PT_INT32:
        begin
          if Types[ColIdx] = VCT_DATE then
          begin
            if c.Kind = vckInt then
              iv := c.I
            else if not TryDateDays(c.S, iv) then
              raise Exception.Create('Parquet: gecersiz DATE: ' + c.S);
            BufI32(values, Integer(iv));
          end
          else if Types[ColIdx] = VCT_TIME then
          begin
            if c.Kind = vckInt then
              iv := c.I
            else if not TryTimeSecs(c.S, iv) then
              raise Exception.Create('Parquet: gecersiz TIME: ' + c.S);
            BufI32(values, Integer(iv * 1000));
          end
          else
          begin
            if c.Kind = vckInt then
              iv := c.I
            else if c.Kind = vckFloat then
              iv := Trunc(c.F)
            else
              iv := StrToInt(c.S);
            BufI32(values, Integer(iv));
          end;
        end;
      PT_INT64:
        begin
          if Types[ColIdx] = VCT_DATETIME then
          begin
            if c.Kind = vckInt then
              iv := c.I
            else if not TryDateTimeSecs(c.S, iv) then
              raise Exception.Create('Parquet: gecersiz DATETIME: ' + c.S);
            BufI64(values, iv * 1000);
          end
          else
          begin
            if c.Kind = vckInt then
              iv := c.I
            else if c.Kind = vckFloat then
              iv := Trunc(c.F)
            else
              iv := StrToInt64(c.S);
            BufI64(values, iv);
          end;
        end;
      PT_DOUBLE:
        begin
          case c.Kind of
            vckFloat: dv := c.F;
            vckInt: dv := c.I;
            vckBool: if c.I <> 0 then dv := 1 else dv := 0;
          else
            dv := FloatFromStr(c.S);
          end;
          BufDouble(values, dv);
        end;
      PT_BYTE_ARRAY:
        BufByteArray(values, ParquetCellStr(c));
      PT_FIXED:
        begin
          if ColIdx < Length(DScale) then dsc := DScale[ColIdx] else dsc := 0;
          if ColIdx < Length(DPrec) then dpr := DPrec[ColIdx] else dpr := 0;
          if not VdbDecParse(ParquetCellStr(c), dd, de) then
            raise Exception.Create('Parquet: gecersiz DECIMAL: ' + ParquetCellStr(c));
          if dsc = 0 then dsc := dd.Scale;
          if not VdbDecRound(dd, dsc, dr, de) then
            raise Exception.Create('Parquet: DECIMAL yuvarlanamadi: ' + de);
          if (dpr > 0) and (VdbDecPrecision(dr) > dpr) then
            raise Exception.CreateFmt('Parquet: DECIMAL hassasiyet tasmasi (%d > %d)',
              [VdbDecPrecision(dr), dpr]);
          db16 := DecDigitsToFixed16(dr.Digits, dr.Neg);
          L := Length(values);
          SetLength(values, L + 16);
          Move(db16[0], values[L], 16);
        end;
    end;
  end;
  def := EncodeDefLevels(bits, n);
  SetLength(Body, Length(def) + Length(values));
  if Length(def) > 0 then Move(def[0], Body[0], Length(def));
  if Length(values) > 0 then Move(values[0], Body[Length(def)], Length(values));
  { SKILL15-A: sayfa govdesi (tanim seviyeleri + degerler) tek parca
    sikistirilir; DataPage v1'de tum govde sikistirilir. }
  ARawSize := Length(Body);
  if ACodec = CODEC_SNAPPY then
  begin
    if not SnappyCompress(Body, cbody) then
      raise Exception.Create('Parquet: SNAPPY sikistirma hatasi');
    Body := cbody;
  end
  else if ACodec <> CODEC_UNCOMPRESSED then
    raise Exception.CreateFmt(
      'Parquet: sikistirma desteklenmiyor (codec=%d); yalniz UNCOMPRESSED ve SNAPPY',
      [ACodec]);

  W := TThriftWriter.Create;
  try
    W.BeginStruct;
    W.WriteI32Field(1, PAGE_DATA);
    W.WriteI32Field(2, Integer(ARawSize));
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

{ Eski metin API'si: '' -> NULL, ayni cekirdek (belgelenmis sinir). }
procedure RowsToParquetCells(const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Cells: TVdbCellMatrix);
var
  i, j: Integer;
  s: string;
begin
  SetLength(Cells, Length(Rows));
  for i := 0 to High(Rows) do
  begin
    SetLength(Cells[i], Length(Fields));
    for j := 0 to High(Fields) do
    begin
      s := '';
      if j < Length(Rows[i]) then s := Rows[i][j];
      Cells[i][j].Kind := vckNull;
      Cells[i][j].I := 0;
      Cells[i][j].F := 0;
      Cells[i][j].S := '';
      if s <> '' then
      begin
        if Types[j] = VCT_BLOB then
          Cells[i][j].Kind := vckBlob
        else
          Cells[i][j].Kind := vckText;
        Cells[i][j].S := s;
      end;
    end;
  end;
end;

function BuildFileMetaGroups(const SchemaCols: array of TColWrite;
  const Groups: array of TParquetGroupWrite; TotalRows: Int64): TBytes;
var
  W: TThriftWriter;
  i, j, nGroups: Integer;
  total: Int64;
begin
  W := TThriftWriter.Create;
  try
    W.BeginStruct;
    W.WriteI32Field(1, 1); // version
    W.Field(2, TT_LIST);
    W.ListHeader(TT_STRUCT, Length(SchemaCols) + 1);
    // root
    W.BeginStruct;
    W.WriteBinaryField(4, 'schema');
    W.WriteI32Field(5, Length(SchemaCols));
    W.EndStruct;
    for i := 0 to High(SchemaCols) do
    begin
      W.BeginStruct;
      W.WriteI32Field(1, SchemaCols[i].PType);
      if SchemaCols[i].PType = PT_FIXED then
        if SchemaCols[i].TypeLength > 0 then
          W.WriteI32Field(2, SchemaCols[i].TypeLength)
        else
          W.WriteI32Field(2, 16);
      W.WriteI32Field(3, REP_OPTIONAL);
      W.WriteBinaryField(4, SchemaCols[i].Name);
      if SchemaCols[i].Converted >= 0 then
        W.WriteI32Field(6, SchemaCols[i].Converted);
      if SchemaCols[i].Converted = CT_DECIMAL then
      begin
        W.WriteI32Field(7, SchemaCols[i].DecScale);
        W.WriteI32Field(8, SchemaCols[i].DecPrec);
      end;
      WriteLogicalType(W, SchemaCols[i].LogicalKind, SchemaCols[i].LogicalUnit,
        SchemaCols[i].DecScale, SchemaCols[i].DecPrec);
      W.EndStruct;
    end;

    W.WriteI64Field(3, TotalRows);
    W.Field(4, TT_LIST);
    nGroups := 0;
    for i := 0 to High(Groups) do
      if Groups[i].NumRows > 0 then Inc(nGroups);
    W.ListHeader(TT_STRUCT, nGroups);
    for i := 0 to High(Groups) do
    begin
      if Groups[i].NumRows <= 0 then Continue;
      W.BeginStruct;
      W.Field(1, TT_LIST);
      W.ListHeader(TT_STRUCT, Length(Groups[i].Cols));
      total := 0;
      for j := 0 to High(Groups[i].Cols) do
      begin
        Inc(total, Groups[i].Cols[j].TotalSize);
        W.BeginStruct;
        W.WriteI64Field(2, Groups[i].Cols[j].DataOffset);
        W.Field(3, TT_STRUCT);
        W.BeginStruct;
        W.WriteI32Field(1, Groups[i].Cols[j].PType);
        W.Field(2, TT_LIST);
        W.ListHeader(TT_I32, 2);
        W.WriteI32Value(ENC_PLAIN);
        W.WriteI32Value(ENC_RLE);
        W.Field(3, TT_LIST);
        W.ListHeader(TT_BINARY, 1);
        W.WriteBinaryValue(Groups[i].Cols[j].Name);
        W.WriteI32Field(4, Groups[i].Cols[j].Codec);
        W.WriteI64Field(5, Groups[i].Cols[j].NumValues);
        W.WriteI64Field(6, Groups[i].Cols[j].CompressedSize);
        W.WriteI64Field(7, Groups[i].Cols[j].UncompressedSize);
        W.WriteI64Field(9, Groups[i].Cols[j].DataOffset);
        W.EndStruct;
        W.EndStruct;
      end;
      W.WriteI64Field(2, total);
      W.WriteI64Field(3, Groups[i].NumRows);
      W.EndStruct;
    end;
    W.WriteBinaryField(6, 'VDb Parquet');
    W.EndStruct;
    Result := W.Finish;
  finally
    W.Free;
  end;
end;

function BuildFileMeta(const Cols: array of TColWrite; NumRows: Int64): TBytes;
var
  Groups: array of TParquetGroupWrite;
  i: Integer;
begin
  if NumRows > 0 then
  begin
    SetLength(Groups, 1);
    Groups[0].NumRows := NumRows;
    SetLength(Groups[0].Cols, Length(Cols));
    for i := 0 to High(Cols) do
      Groups[0].Cols[i] := Cols[i];
  end;
  Result := BuildFileMetaGroups(Cols, Groups, NumRows);
end;

constructor TVdbParquetWriter.Create(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray);
begin
  CreateEx(FileName, Fields, Types, nil, nil);
end;

constructor TVdbParquetWriter.CreateEx(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Prec, Scale: TByteArray);
const
  Magic: array[0..3] of Char = ('P', 'A', 'R', '1');
var
  i: Integer;
begin
  if Length(Fields) <> Length(Types) then
    raise Exception.Create('Parquet: alan/tip sayisi uyusmuyor');
  SetLength(FFields, Length(Fields));
  for i := 0 to High(Fields) do FFields[i] := Fields[i];
  SetLength(FTypes, Length(Types));
  for i := 0 to High(Types) do FTypes[i] := Types[i];
  SetLength(FPrec, Length(Fields));
  SetLength(FScale, Length(Fields));
  if Length(Prec) = Length(Fields) then
    for i := 0 to High(Prec) do FPrec[i] := Prec[i];
  if Length(Scale) = Length(Fields) then
    for i := 0 to High(Scale) do FScale[i] := Scale[i];
  FNumRows := 0;
  FClosed := False;
  FCodec := CODEC_UNCOMPRESSED;
  FMaxRowsPerGroup := 0;
  FStream := TFileStream.Create(FileName, fmCreate);
  FStream.WriteBuffer(Magic, 4);
end;

procedure TVdbParquetWriter.DoWriteGroup(const Cells: TVdbCellMatrix);
var
  g: TParquetGroupWrite;
  i, cnt: Integer;
  Header, Body: TBytes;
  RawSize: Int64;
  conv, lk, lu: Integer;
begin
  if Length(Cells) = 0 then Exit;
  cnt := Length(Cells);
  SetLength(g.Cols, Length(FFields));
  g.NumRows := cnt;
  for i := 0 to High(FFields) do
  begin
    if not BuildPageCells(i, FFields, FTypes, FPrec, FScale, FCodec, Cells,
      Header, Body, RawSize) then
      raise Exception.Create('Parquet: sayfa olusturulamadi');
    g.Cols[i].Name := FFields[i];
    g.Cols[i].PType := ParquetTypeOf(FTypes[i], conv, lk, lu);
    g.Cols[i].Converted := conv;
    g.Cols[i].LogicalKind := lk;
    g.Cols[i].LogicalUnit := lu;
    g.Cols[i].VType := FTypes[i];
    g.Cols[i].Codec := FCodec;
    g.Cols[i].TypeLength := 0;
    g.Cols[i].DecScale := 0;
    g.Cols[i].DecPrec := 0;
    if FTypes[i] = VCT_DECIMAL then
    begin
      g.Cols[i].TypeLength := 16;
      if i < Length(FScale) then g.Cols[i].DecScale := FScale[i];
      if i < Length(FPrec) then g.Cols[i].DecPrec := FPrec[i];
    end;
    g.Cols[i].DataOffset := FStream.Position;
    if Length(Header) > 0 then FStream.WriteBuffer(Header[0], Length(Header));
    if Length(Body) > 0 then FStream.WriteBuffer(Body[0], Length(Body));
    g.Cols[i].TotalSize := Int64(Length(Header)) + Length(Body);
    g.Cols[i].CompressedSize := g.Cols[i].TotalSize;
    g.Cols[i].UncompressedSize := Int64(Length(Header)) + RawSize;
    g.Cols[i].NumValues := cnt;
  end;
  SetLength(FGroups, Length(FGroups) + 1);
  FGroups[High(FGroups)] := g;
  Inc(FNumRows, cnt);
end;

{ SKILL14: DECIMAL icin (p,s) verilmediyse hucrelerden turet. Oncelik
  hassasiyette: 0 = bildirilmedi. Olcek 0 ise ilk ondalik hucreden alinir. }
procedure TVdbParquetWriter.DeriveDecSpec(const Cells: TVdbCellMatrix);
var
  i, k: Integer;
  dd: TVdbDec;
  de: string;
begin
  for i := 0 to High(FFields) do
    if FTypes[i] = VCT_DECIMAL then
    begin
      if Length(FPrec) <= i then SetLength(FPrec, i + 1);
      if Length(FScale) <= i then SetLength(FScale, i + 1);
      if FPrec[i] = 0 then
      begin
        FPrec[i] := VDB_DEC_MAX_PREC;
        if FScale[i] = 0 then
          for k := 0 to High(Cells) do
            if (i < Length(Cells[k])) and (Cells[k][i].Kind <> vckNull) and
               VdbDecParse(ParquetCellStr(Cells[k][i]), dd, de) then
            begin
              FScale[i] := dd.Scale;
              Break;
            end;
      end;
    end;
end;

{ Birikmis satirlardan bir satir grubu yazar. MaxRowsPerGroup > 0 iken grup
  tam olarak o kadar satirdan olusur (son grup kalan kadar). }
procedure TVdbParquetWriter.FlushPending;
var
  cnt, rest, k, i: Integer;
  sub: TVdbCellMatrix;
begin
  if Length(FPend) = 0 then Exit;
  cnt := Length(FPend);
  if (FMaxRowsPerGroup > 0) and (Int64(cnt) > FMaxRowsPerGroup) then
    cnt := Integer(FMaxRowsPerGroup);
  SetLength(sub, cnt);
  for k := 0 to cnt - 1 do sub[k] := FPend[k];
  DoWriteGroup(sub);
  rest := Length(FPend) - cnt;
  for i := 0 to rest - 1 do FPend[i] := FPend[cnt + i];
  SetLength(FPend, rest);
end;

function TVdbParquetWriter.GetBytesWritten: Int64;
begin
  if FStream = nil then
    Result := 0
  else
    Result := FStream.Size;
end;

procedure TVdbParquetWriter.WriteBatch(const Cells: TVdbCellMatrix);
var
  i: Integer;
begin
  if FClosed then
    raise Exception.Create('Parquet: yazici kapatildi');
  if Length(Cells) = 0 then Exit;
  if (FCodec <> CODEC_UNCOMPRESSED) and (FCodec <> CODEC_SNAPPY) then
    raise Exception.CreateFmt(
      'Parquet: sikistirma desteklenmiyor (codec=%d); yalniz UNCOMPRESSED ve SNAPPY',
      [FCodec]);
  DeriveDecSpec(Cells);
  if FMaxRowsPerGroup <= 0 then
  begin
    DoWriteGroup(Cells);
    Exit;
  end;
  { SKILL15-C/D: satirlar grup tavani kadar biriktirilir; grup dolunca hemen
    diske yazilir. Bellekte en fazla bir satir grubu tutulur. }
  SetLength(FPend, Length(FPend) + Length(Cells));
  for i := 0 to High(Cells) do
    FPend[Length(FPend) - Length(Cells) + i] := Cells[i];
  while Int64(Length(FPend)) >= FMaxRowsPerGroup do
    FlushPending;
end;

procedure TVdbParquetWriter.Close;
const
  Magic: array[0..3] of Char = ('P', 'A', 'R', '1');
var
  SchemaCols: array of TColWrite;
  Meta: TBytes;
  L: LongWord;
  i: Integer;
  conv, lk, lu: Integer;
begin
  if FClosed then Exit;
  FClosed := True;
  if FStream = nil then Exit;
  { SKILL15-C/D: tavana ulasmamis son satirlar kapanista yazilir. }
  FlushPending;
  // Sema her zaman alan listesinden uretilir; satir grubu olmasa da gecerli.
  SetLength(SchemaCols, Length(FFields));
  for i := 0 to High(FFields) do
  begin
    SchemaCols[i].Name := FFields[i];
    SchemaCols[i].PType := ParquetTypeOf(FTypes[i], conv, lk, lu);
    SchemaCols[i].Converted := conv;
    SchemaCols[i].LogicalKind := lk;
    SchemaCols[i].LogicalUnit := lu;
    SchemaCols[i].VType := FTypes[i];
    SchemaCols[i].TypeLength := 0;
    SchemaCols[i].DecScale := 0;
    SchemaCols[i].DecPrec := 0;
    if FTypes[i] = VCT_DECIMAL then
    begin
      SchemaCols[i].TypeLength := 16;
      if i < Length(FScale) then SchemaCols[i].DecScale := FScale[i];
      if i < Length(FPrec) then SchemaCols[i].DecPrec := FPrec[i];
      // SKILL14: hic satir yazilmadiysa bildirilen (p,s) yine gecerli olmali.
      if SchemaCols[i].DecPrec = 0 then SchemaCols[i].DecPrec := VDB_DEC_MAX_PREC;
    end;
    SchemaCols[i].DataOffset := 0;
    SchemaCols[i].TotalSize := 0;
    SchemaCols[i].NumValues := 0;
    SchemaCols[i].Codec := 0;
    SchemaCols[i].CompressedSize := 0;
    SchemaCols[i].UncompressedSize := 0;
  end;
  Meta := BuildFileMetaGroups(SchemaCols, FGroups, FNumRows);
  if Length(Meta) > 0 then FStream.WriteBuffer(Meta[0], Length(Meta));
  L := LongWord(Length(Meta));
  FStream.WriteBuffer(L, 4);
  FStream.WriteBuffer(Magic, 4);
  FreeAndNil(FStream);
end;

destructor TVdbParquetWriter.Destroy;
begin
  try
    Close;
  except
    FreeAndNil(FStream);
  end;
  inherited;
end;

function VDbParquetExportCells(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;
begin
  Result := VDbParquetExportCellsEx(FileName, Fields, Types, nil, nil, Cells, Err);
end;

function VDbParquetExportCellsEx(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Prec, Scale: TByteArray;
  const Cells: TVdbCellMatrix; out Err: string): Boolean;
var
  w: TVdbParquetWriter;
begin
  Result := False;
  Err := '';
  try
    w := TVdbParquetWriter.CreateEx(FileName, Fields, Types, Prec, Scale);
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

function VDbParquetExport(const FileName: string;
  const Fields: TStrArray; const Types: TByteArray;
  const Rows: TStrMatrix; out Err: string): Boolean;
var
  Cells: TVdbCellMatrix;
  i: Integer;
begin
  Result := False;
  Err := '';
  if Length(Fields) <> Length(Types) then
  begin
    Err := 'Parquet: alan/tip sayisi uyusmuyor';
    Exit;
  end;
  for i := 0 to High(Rows) do
    if Length(Rows[i]) <> Length(Fields) then
    begin
      Err := 'Parquet: satir alan sayisi uyusmuyor';
      Exit;
    end;
  RowsToParquetCells(Fields, Types, Rows, Cells);
  Result := VDbParquetExportCells(FileName, Fields, Types, Cells, Err);
end;


{ --------------------------------------------------------- Parquet oku }

function LeafKind(SE: TParquetSchemaElem): Integer;
begin
  // 0=int, 1=date, 2=time, 3=timestamp, 4=bool, 5=float, 6=str, 7=blob, 8=decimal
  if SE.LogicalKind = 5 then Exit(8);
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
  if SE.PType = PT_FIXED then Exit(7);
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
    8: Result := VCT_DECIMAL;
  else
    Result := VCT_INT;
  end;
end;

function ParquetCellOf(const S: string; VType: Byte): TVdbCell;
begin
  Result.Kind := vckNull;
  Result.I := 0;
  Result.F := 0;
  Result.S := '';
  case VType of
    VCT_INT:
      begin
        if TryStrToInt64(S, Result.I) then
          Result.Kind := vckInt
        else
        begin
          Result.Kind := vckText;
          Result.S := S;
        end;
      end;
    VCT_FLOAT:
      begin
        Result.Kind := vckFloat;
        Result.F := FloatFromStr(S);
      end;
    VCT_BOOL:
      begin
        Result.Kind := vckBool;
        if SameText(S, 'true') or (S = '1') then Result.I := 1;
      end;
    VCT_BLOB:
      begin
        Result.Kind := vckBlob;
        Result.S := S;
      end;
  else
    begin
      Result.Kind := vckText;
      Result.S := S;
    end;
  end;
end;

procedure DecodeColumn(const Data: TBytes; Base: Int64;
  const CM: TParquetColumnMeta;
  const SE: TParquetSchemaElem; GroupRows: Integer; out Values: TStrArray;
  out Cells: TVdbCellArray);
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
  vtype: Byte;
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
    fw: Integer;
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
        PT_FIXED:
          begin
            fw := SE.TypeLength;
            if fw <= 0 then fw := 16;
            if (q < 0) or (q + fw > Length(B)) then
              raise Exception.Create('Parquet: fixed sozluk bitti');
            if SE.LogicalKind = 5 then
              Result[k] := DecFixedToStr(B, q, fw, SE.DecScale)
            else
            begin
              SetLength(ss, fw);
              Move(B[q], ss[1], fw);
              Result[k] := ValueToStr(SE.PType, SE.LogicalKind, SE.LogicalUnit,
                0, 0, False, ss);
            end;
            Inc(q, fw);
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
    k, bw, fw: Integer;
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
        PT_FIXED:
          begin
            fw := SE.TypeLength;
            if fw <= 0 then fw := 16;
            if (N > 0) and ((P < 0) or (P + Int64(N) * fw > Length(B))) then
              raise Exception.Create('Parquet: fixed veri bitti');
            for k := 0 to N - 1 do
            begin
              if SE.LogicalKind = 5 then
                strs[k] := DecFixedToStr(B, P, fw, SE.DecScale)
              else
              begin
                SetLength(strs[k], fw);
                Move(B[P], strs[k][1], fw);
              end;
              Inc(P, fw);
            end;
          end;
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
            PT_FIXED:
              Values[rowPos + k] := strs[cnt];
            PT_INT96:
              Values[rowPos + k] := int96[cnt];
          end;
        // SKILL13: tipli hucre. Kayan nokta sozluk disinda ham
        // Double'dan alinir (metin yuvarlamasina guvenilmez).
        if isDict then
          Cells[rowPos + k] := ParquetCellOf(strs[cnt], vtype)
        else if (SE.PType = PT_FLOAT) or (SE.PType = PT_DOUBLE) then
        begin
          Cells[rowPos + k].Kind := vckFloat;
          Cells[rowPos + k].I := 0;
          Cells[rowPos + k].F := vals[cnt];
          Cells[rowPos + k].S := '';
        end
        else
          Cells[rowPos + k] := ParquetCellOf(Values[rowPos + k], vtype);
        Inc(cnt);
      end;
    end;
    Inc(rowPos, NumVals);
  end;

begin
  SetLength(Values, GroupRows);
  for i := 0 to GroupRows - 1 do Values[i] := '';
  SetLength(Cells, GroupRows);
  for i := 0 to GroupRows - 1 do
  begin
    Cells[i].Kind := vckNull;
    Cells[i].I := 0;
    Cells[i].F := 0;
    Cells[i].S := '';
  end;
  vtype := VTypeOfLeaf(SE);
  SetLength(dict, 0);
  maxDef := 0;
  if SE.Repetition = REP_OPTIONAL then maxDef := 1;
  if SE.Repetition = REP_REPEATED then maxDef := 1;
  if SE.Repetition = REP_REPEATED then
    raise Exception.Create('Parquet: repeated (nested) alan desteklenmiyor');
  if (CM.Codec <> CODEC_UNCOMPRESSED) and (CM.Codec <> CODEC_SNAPPY) then
    raise Exception.CreateFmt('Parquet: sikistirma desteklenmiyor (codec=%d)', [CM.Codec]);
  off := CM.DataPageOffset - Base;
  if CM.DictPageOffset >= 0 then off := CM.DictPageOffset - Base;
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

procedure LoadParquetMeta(const FileName: string; out Meta: TParquetMeta;
  out FileSize, MetaStart: Int64);
var
  fs: TFileStream;
  tail, mbuf: TBytes;
  sz: Int64;
  metaLen: Integer;
begin
  fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    sz := fs.Size;
    if sz < 12 then
      raise Exception.Create('Parquet: dosya cok kucuk');
    SetLength(tail, 4);
    fs.ReadBuffer(tail[0], 4);
    if (Char(tail[0]) <> 'P') or (Char(tail[1]) <> 'A') or
       (Char(tail[2]) <> 'R') or (Char(tail[3]) <> '1') then
      raise Exception.Create('Parquet: PAR1 imzasi yok');
    SetLength(tail, 8);
    fs.Seek(sz - 8, soBeginning);
    fs.ReadBuffer(tail[0], 8);
    if (Char(tail[4]) <> 'P') or (Char(tail[5]) <> 'A') or
       (Char(tail[6]) <> 'R') or (Char(tail[7]) <> '1') then
      raise Exception.Create('Parquet: kuyruk PAR1 imzasi yok');
    metaLen := Integer(LE32(tail, 0));
    MetaStart := sz - 8 - metaLen;
    if (MetaStart < 4) or (metaLen <= 0) then
      raise Exception.Create('Parquet: gecersiz metadata boyu');
    SetLength(mbuf, metaLen);
    fs.Seek(MetaStart, soBeginning);
    fs.ReadBuffer(mbuf[0], metaLen);
  finally
    fs.Free;
  end;
  FileSize := sz;
  ParseFileMeta(mbuf, 0, metaLen, Meta);
end;

procedure ParquetLeaves(const Meta: TParquetMeta;
  out Leaves: TParquetSchemaArray);
var
  i, leafN: Integer;
begin
  if Length(Meta.Schema) < 2 then
    raise Exception.Create('Parquet: sema bos');
  if Meta.Schema[0].NumChildren <> Length(Meta.Schema) - 1 then
    raise Exception.Create('Parquet: nested sema desteklenmiyor');
  leafN := 0;
  SetLength(Leaves, Length(Meta.Schema) - 1);
  for i := 1 to High(Meta.Schema) do
  begin
    if Meta.Schema[i].NumChildren > 0 then
      raise Exception.Create('Parquet: nested sema desteklenmiyor');
    Leaves[leafN] := Meta.Schema[i];
    Inc(leafN);
  end;
  SetLength(Leaves, leafN);
end;

function VDbParquetImportCellsEx(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Prec, Scale: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;
var
  fs: TFileStream;
  Data: TBytes;
  sz64, metaStart: Int64;
  sz, i, j, leafN, total, base, r: Integer;
  Meta: TParquetMeta;
  leaves: TParquetSchemaArray;
  colVals: TStrArray;
  colCells: TVdbCellArray;
begin
  Result := False;
  Err := '';
  Fields := nil;
  Types := nil;
  Prec := nil;
  Scale := nil;
  Cells := nil;
  try
    LoadParquetMeta(FileName, Meta, sz64, metaStart);
    if sz64 > MaxInt then
      raise Exception.Create('Parquet: dosya cok buyuk');
    sz := Integer(sz64);
    fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Data, sz);
      if sz > 0 then fs.ReadBuffer(Data[0], sz);
    finally
      fs.Free;
    end;
    ParquetLeaves(Meta, leaves);
    leafN := Length(leaves);
    total := 0;
    for i := 0 to High(Meta.RowGroups) do
    begin
      if Integer(Meta.RowGroups[i].NumRows) < 0 then
        raise Exception.Create('Parquet: negatif satir sayisi');
      Inc(total, Integer(Meta.RowGroups[i].NumRows));
    end;
    SetLength(Fields, leafN);
    SetLength(Types, leafN);
    SetLength(Prec, leafN);
    SetLength(Scale, leafN);
    for i := 0 to leafN - 1 do
    begin
      Fields[i] := leaves[i].Name;
      Types[i] := VTypeOfLeaf(leaves[i]);
      Prec[i] := 0;
      Scale[i] := 0;
      if Types[i] = VCT_DECIMAL then
      begin
        if leaves[i].DecPrec > 0 then Prec[i] := leaves[i].DecPrec;
        if leaves[i].DecScale > 0 then Scale[i] := leaves[i].DecScale;
      end;
    end;
    SetLength(Cells, total);
    for i := 0 to total - 1 do
      SetLength(Cells[i], leafN);

    base := 0;
    for i := 0 to High(Meta.RowGroups) do
    begin
      if Length(Meta.RowGroups[i].Columns) <> leafN then
        raise Exception.Create('Parquet: satir grubu kolon sayisi uyusmuyor');
      for j := 0 to leafN - 1 do
      begin
        try
          DecodeColumn(Data, 0, Meta.RowGroups[i].Columns[j], leaves[j],
            Integer(Meta.RowGroups[i].NumRows), colVals, colCells);
        except
          on E: Exception do
            raise Exception.CreateFmt('Parquet: %s: %s', [leaves[j].Name, E.Message]);
        end;
        for r := 0 to Integer(Meta.RowGroups[i].NumRows) - 1 do
          Cells[base + r][j] := colCells[r];
      end;
      Inc(base, Integer(Meta.RowGroups[i].NumRows));
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Fields := nil;
      Types := nil;
      Prec := nil;
      Scale := nil;
      Cells := nil;
    end;
  end;
end;

function VDbParquetImportCells(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Cells: TVdbCellMatrix; out Err: string): Boolean;
var
  pr, sc: TByteArray;
begin
  Result := VDbParquetImportCellsEx(FileName, Fields, Types, pr, sc, Cells, Err);
end;

function VDbParquetImport(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  out Rows: TStrMatrix; out Err: string): Boolean;
var
  Cells: TVdbCellMatrix;
  i, j: Integer;
begin
  Rows := nil;
  Result := VDbParquetImportCells(FileName, Fields, Types, Cells, Err);
  if not Result then Exit;
  SetLength(Rows, Length(Cells));
  for i := 0 to High(Cells) do
  begin
    SetLength(Rows[i], Length(Cells[i]));
    for j := 0 to High(Cells[i]) do
      case Cells[i][j].Kind of
        vckInt: Rows[i][j] := IntToStr(Cells[i][j].I);
        vckFloat: Rows[i][j] := VDbFloatToStr(Cells[i][j].F);
        vckBool: if Cells[i][j].I <> 0 then Rows[i][j] := 'true'
                 else Rows[i][j] := 'false';
      else
        Rows[i][j] := Cells[i][j].S;   // vckNull -> ''
      end;
  end;
end;

function VDbParquetReadBatches(const FileName: string;
  out Fields: TStrArray; out Types: TByteArray;
  const OnBatch: TVdbParquetBatchEvent; out Err: string): Boolean;
var
  fs: TFileStream;
  sz64, metaStart: Int64;
  Meta: TParquetMeta;
  leaves: TParquetSchemaArray;
  i, j, leafN, rows, r: Integer;
  CM: TParquetColumnMeta;
  start, len: Int64;
  buf: TBytes;
  colVals: TStrArray;
  colCells: TVdbCellArray;
  cells: TVdbCellMatrix;
begin
  Result := False;
  Err := '';
  Fields := nil;
  Types := nil;
  fs := nil;
  try
    LoadParquetMeta(FileName, Meta, sz64, metaStart);
    ParquetLeaves(Meta, leaves);
    leafN := Length(leaves);
    SetLength(Fields, leafN);
    SetLength(Types, leafN);
    for i := 0 to leafN - 1 do
    begin
      Fields[i] := leaves[i].Name;
      Types[i] := VTypeOfLeaf(leaves[i]);
    end;
    fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    for i := 0 to High(Meta.RowGroups) do
    begin
      if Length(Meta.RowGroups[i].Columns) <> leafN then
        raise Exception.Create('Parquet: satir grubu kolon sayisi uyusmuyor');
      rows := Integer(Meta.RowGroups[i].NumRows);
      if rows < 0 then
        raise Exception.Create('Parquet: negatif satir sayisi');
      if rows = 0 then Continue;
      SetLength(cells, rows);
      for r := 0 to rows - 1 do
        SetLength(cells[r], leafN);
      for j := 0 to leafN - 1 do
      begin
        CM := Meta.RowGroups[i].Columns[j];
        start := CM.DataPageOffset;
        if CM.DictPageOffset >= 0 then start := CM.DictPageOffset;
        len := CM.TotalCompressed;
        if (start < 4) or (len <= 0) or (start + len > metaStart) then
          raise Exception.CreateFmt('Parquet: %s: kolon dilimi dosya disinda',
            [leaves[j].Name]);
        if len > MaxInt then
          raise Exception.Create('Parquet: kolon dilimi cok buyuk');
        SetLength(buf, Integer(len));
        fs.Seek(start, soBeginning);
        fs.ReadBuffer(buf[0], Integer(len));
        try
          DecodeColumn(buf, start, CM, leaves[j], rows, colVals, colCells);
        except
          on E: Exception do
            raise Exception.CreateFmt('Parquet: %s: %s', [leaves[j].Name, E.Message]);
        end;
        for r := 0 to rows - 1 do
          cells[r][j] := colCells[r];
      end;
      if Assigned(OnBatch) then OnBatch(cells);
      cells := nil;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Fields := nil;
      Types := nil;
      Result := False;
    end;
  end;
  FreeAndNil(fs);
end;

end.
