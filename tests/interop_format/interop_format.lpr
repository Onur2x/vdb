program interop_format;
{ v3.72 / SKILL6 08 (A) KALICI REGRESYON KAPISI - Arrow ve Parquet
  bicimlerinin kendi icinde tutarliligi ve bicim kurallari.

  Bu kapida olculen:
    F1  Arrow: 8 destekli tip round trip (degerler birebir)
    F2  Arrow: alan adlari ve tipleri korunur
    F3  Arrow: dosya gercek Arrow IPC stream imzasiyla baslar
    F4  Parquet: ayni 8 tip round trip (degerler birebir)
    F5  Parquet: alan adlari ve tipleri korunur
    F6  Parquet: dosya PAR1 ile baslar ve PAR1 ile biter
    F7  Sifir satir: iki bicimde de sema korunur, satir 0
    F8  Buyuk dosya: 20000 satir iki bicimde de birebir geri okunur
    F9  Cok kolon: 60 kolon iki bicimde de korunur
    F10 Buyuk deger: 100000 baytlik metin + 300000 baytlik BLOB
    F11 UTF-8 metin bozulmadan doner
    F12 Bos metin hucresi kaybolmaz ('' -> '')
    F13 Bozuk dosya: False + Err dolu, istisna sizmaz
    F14 Olmayan dosya: False + Err dolu
    F15 Harici uretilmis dosyalar (pyarrow) okunur: Arrow IPC stream,
        Parquet UNCOMPRESSED, Parquet SNAPPY
    F16 Ayni veri iki bicimde de ayni degerleri verir (capraz kontrol)

  NOT (durust sinir): neither format supports DECIMAL; Parquet yazimi
  her zaman UNCOMPRESSED'dir (SNAPPY yalnizca okunur). Bu kapi yalniz
  VDB <-> VDB tutarliligini olcer; HARICI dogrulama
  `tests/interop_external` kapisindedir ve orasi SKIP olabilir. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbTypes, VDbArrow, VDbParquet;

var
  GPass, GFail: Integer;
  GDir: string;
  GFixDir: string;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
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

function RowOf(const A, B, C, D, E, F, G, H: string): TStrArray;
begin
  SetLength(Result, 8);
  Result[0] := A; Result[1] := B; Result[2] := C; Result[3] := D;
  Result[4] := E; Result[5] := F; Result[6] := G; Result[7] := H;
end;

function RepStr(const S: string; N: Integer): string;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 1 to N do Result[i] := S[1];
end;

function FileHead(const APath: string; AN: Integer): AnsiString;
var
  fs: TFileStream;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  SetLength(Result, AN);
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size < AN then SetLength(Result, fs.Size);
    if Length(Result) > 0 then fs.ReadBuffer(Result[1], Length(Result));
  finally
    fs.Free;
  end;
end;

function FileTail(const APath: string; AN: Integer): AnsiString;
var
  fs: TFileStream;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size < AN then Exit;
    SetLength(Result, AN);
    fs.Position := fs.Size - AN;
    fs.ReadBuffer(Result[1], AN);
  finally
    fs.Free;
  end;
end;

function WriteBytes(const APath: string; const B: TBytes): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(APath, fmCreate);
    try
      if Length(B) > 0 then fs.WriteBuffer(B[0], Length(B));
      Result := True;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

function StrToB(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

{ --- Karsilastirma yardimcilari --- }

function CmpMatrix(const A, B: TStrMatrix; out BadI, BadJ: Integer;
  out AVal, BVal: string; out Reason: string): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  BadI := -1; BadJ := -1; AVal := ''; BVal := '';
  Reason := '';
  if Length(A) <> Length(B) then
  begin
    Reason := 'satir sayisi ' + IntToStr(Length(A)) + ' <> ' + IntToStr(Length(B));
    Exit;
  end;
  for i := 0 to High(A) do
  begin
    if Length(A[i]) <> Length(B[i]) then
    begin
      Reason := 'kolon sayisi (satir ' + IntToStr(i) + ')';
      BadI := i;
      Exit;
    end;
    for j := 0 to High(A[i]) do
      if A[i][j] <> B[i][j] then
      begin
        BadI := i; BadJ := j; AVal := A[i][j]; BVal := B[i][j];
        Reason := 'deger farki';
        Exit;
      end;
  end;
  Result := True;
end;

{ Harici fixture'in TAM icerigini dogrular: 50 satir, 7 kolon.
  Degerler generate_fixtures.py ile deterministiktir. }
function CheckFixture(const M: TStrMatrix; out Reason: string): Boolean;
var
  i: Integer;
  d: TDateTime;
  sc: Double;
begin
  Result := False;
  Reason := '';
  if Length(M) <> 50 then
  begin
    Reason := 'satir ' + IntToStr(Length(M)) + ' <> 50';
    Exit;
  end;
  for i := 0 to 49 do
  begin
    if Length(M[i]) <> 7 then
    begin
      Reason := 'kolon (satir ' + IntToStr(i) + ')=' + IntToStr(Length(M[i]));
      Exit;
    end;
    if M[i][0] <> IntToStr(i) then
    begin
      Reason := 'id satir ' + IntToStr(i) + '=' + M[i][0];
      Exit;
    end;
    if M[i][1] <> 'row-' + IntToStr(i) then
    begin
      Reason := 'name satir ' + IntToStr(i) + '=' + M[i][1];
      Exit;
    end;
    if not TryStrToFloat(M[i][2], sc) or (Abs(sc - i / 4.0) > 1e-9) then
    begin
      Reason := 'score satir ' + IntToStr(i) + '=' + M[i][2];
      Exit;
    end;
    if (M[i][3] = 'true') <> (i mod 2 = 0) then
    begin
      Reason := 'flag satir ' + IntToStr(i) + '=' + M[i][3];
      Exit;
    end;
    d := EncodeDate(2026, 1, 1) + i;
    if Pos(FormatDateTime('yyyy-mm-dd', d), M[i][4]) <> 1 then
    begin
      Reason := 'born satir ' + IntToStr(i) + '=' + M[i][4];
      Exit;
    end;
    if Pos(FormatDateTime('yyyy-mm-dd hh:nn:ss',
      EncodeDate(2026, 1, 1) + (i * 7) / 86400.0), M[i][5]) <> 1 then
    begin
      Reason := 'seen satir ' + IntToStr(i) + '=' + M[i][5];
      Exit;
    end;
    if M[i][6] <> 'B' + IntToStr(i) then
    begin
      Reason := 'blob satir ' + IntToStr(i) + '=' + M[i][6];
      Exit;
    end;
  end;
  Result := True;
end;

var
  GFields: TStrArray;
  GTypes: TByteArray;
  GRows, GOut, GOut2: TStrMatrix;
  GOutFields: TStrArray;
  GOutTypes: TByteArray;
  Err: string;
  okA, okB, ok: Boolean;
  p, q: string;
  i, j, badI, badJ: Integer;
  aVal, bVal, reason: string;

begin
  { Bicim dizeleri her zaman '.' ondalik ayirici kullanir; yerel ayar
    (or. Turkce ',') testi yanlis dusurmemeli. }
  DefaultFormatSettings.DecimalSeparator := '.';
  GPass := 0;
  GFail := 0;
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp' +
    PathDelim;
  if not DirectoryExists(GDir) then ForceDirectories(GDir);
  GFixDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    '..' + PathDelim + 'interop_format' + PathDelim + 'fixtures' + PathDelim;
  GFixDir := ExpandFileName(GFixDir);
  { Kosucu fixture dizinini ARGUMAN olarak verir (kapi calisma dizini
    $WORK altinda oldugu icin kaynak agaci oradan gorunmez). }
  if ParamStr(1) <> '' then
    GFixDir := IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)))
  else if not DirectoryExists(GFixDir) then
    GFixDir := IncludeTrailingPathDelimiter(ExpandFileName(
      IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
      'fixtures'));

  SetLength(GFields, 8);
  GFields[0] := 'id'; GFields[1] := 'score'; GFields[2] := 'name';
  GFields[3] := 'ok'; GFields[4] := 'born'; GFields[5] := 'seen';
  GFields[6] := 'at'; GFields[7] := 'blob';

  SetLength(GTypes, 8);
  GTypes[0] := VCT_INT; GTypes[1] := VCT_FLOAT; GTypes[2] := VCT_STR;
  GTypes[3] := VCT_BOOL; GTypes[4] := VCT_DATE; GTypes[5] := VCT_DATETIME;
  GTypes[6] := VCT_TIME; GTypes[7] := VCT_BLOB;

  SetLength(GRows, 4);
  GRows[0] := RowOf('42', '2.5', 'hello', 'true', '2026-11-21',
    '2026-11-21 13:45:07', '13:45:07', 'ABC');
  GRows[1] := RowOf('-7', '-0.25', 'merhaba dunya', 'false', '1970-01-01',
    '2000-01-01 00:00:00', '00:00:00', '');
  GRows[2] := RowOf('0', '0', '', 'true', '2024-02-29',
    '1999-12-31 23:59:59', '23:59:59', 'x');
  GRows[3] := RowOf('2147483647', '123456.75', 'satir 4', 'false',
    '2038-01-19', '2038-01-19 03:14:08', '23:59:59', 'binary');

  { ---------------- Arrow round trip ---------------- }
  p := GDir + 'vdb1.arrow';
  err := '';

  okA := False; okB := False;
  try
    okA := VDbArrowExport(p, GFields, GTypes, GRows, err);
  except
    on E: Exception do err := 'istisna: ' + E.Message;
  end;
  Chk('F0 Arrow disa aktarim basarili', okA, err);

  err := '';
  okB := False;
  if okA then
    try
      okB := VDbArrowImport(p, GOutFields, GOutTypes, GOut, err);
    except
      on E: Exception do err := 'istisna: ' + E.Message;
    end;
  ok := okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  Chk('F1 Arrow 8 tip round trip degerleri birebir',
    ok, reason + ' [' + IntToStr(badI) + ',' + IntToStr(badJ) + '] ' +
    aVal + ' <> ' + bVal + ' ' + err);

  ok := okB and (Length(GOutFields) = 8) and (Length(GOutTypes) = 8);
  if ok then
    for i := 0 to 7 do
      if GOutFields[i] <> GFields[i] then ok := False;
  if ok then
    for i := 0 to 7 do
      if GOutTypes[i] <> GTypes[i] then ok := False;
  Chk('F2 Arrow alan adlari ve tipleri korunur', ok,
    'alan=' + IntToStr(Length(GOutFields)) + ' tip=' + IntToStr(Length(GOutTypes)));

  ok := (Length(FileHead(p, 4)) = 4) and (FileHead(p, 4)[1] = #$FF);
  Chk('F3 Arrow dosyasi IPC stream imzasiyla baslar', ok,
    'ilk bayt=' + IntToStr(Ord(FileHead(p, 1)[1])));

  { ---------------- Parquet round trip ---------------- }
  q := GDir + 'vdb1.parquet';
  err := '';
  okA := False;
  try
    okA := VDbParquetExport(q, GFields, GTypes, GRows, err);
  except
    on E: Exception do err := 'istisna: ' + E.Message;
  end;
  Chk('F0b Parquet disa aktarim basarili', okA, err);

  err := '';
  okB := False;
  GOutFields := nil; GOutTypes := nil; GOut := nil;
  if okA then
    try
      okB := VDbParquetImport(q, GOutFields, GOutTypes, GOut, err);
    except
      on E: Exception do err := 'istisna: ' + E.Message;
    end;
  ok := okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  Chk('F4 Parquet 8 tip round trip degerleri birebir',
    ok, reason + ' [' + IntToStr(badI) + ',' + IntToStr(badJ) + '] ' +
    aVal + ' <> ' + bVal + ' ' + err);

  ok := okB and (Length(GOutFields) = 8) and (Length(GOutTypes) = 8);
  if ok then
    for i := 0 to 7 do
      if GOutFields[i] <> GFields[i] then ok := False;
  if ok then
    for i := 0 to 7 do
      if GOutTypes[i] <> GTypes[i] then ok := False;
  Chk('F5 Parquet alan adlari ve tipleri korunur', ok,
    'alan=' + IntToStr(Length(GOutFields)) + ' tip=' + IntToStr(Length(GOutTypes)));

  Chk('F6 Parquet dosyasi PAR1 ile baslar ve biter',
    (FileHead(q, 4) = 'PAR1') and (FileTail(q, 4) = 'PAR1'),
    'bas=' + FileHead(q, 4) + ' son=' + FileTail(q, 4));

  { ---------------- sifir satir ---------------- }
  err := '';
  okA := VDbArrowExport(GDir + 'z.arrow', GFields, GTypes, nil, err);
  okB := okA and VDbArrowImport(GDir + 'z.arrow', GOutFields, GOutTypes, GOut, err);
  ok := okB and (Length(GOut) = 0) and (Length(GOutFields) = 8);
  err := '';
  okA := VDbParquetExport(GDir + 'z.parquet', GFields, GTypes, nil, err);
  okB := okA and VDbParquetImport(GDir + 'z.parquet', GOutFields, GOutTypes,
    GOut, err);
  ok := ok and okB and (Length(GOut) = 0) and (Length(GOutFields) = 8);
  Chk('F7 Sifir satir: sema korunur, satir 0', ok, err);

  { ---------------- buyuk dosya: 20000 satir ---------------- }
  SetLength(GRows, 20000);
  for i := 0 to 19999 do
    GRows[i] := RowOf(IntToStr(i), '0.5', 'satir-' + IntToStr(i), 'true',
      '2026-01-01', '2026-01-01 00:00:00', '00:00:00', 'B' + IntToStr(i));
  err := '';
  okA := VDbArrowExport(GDir + 'big.arrow', GFields, GTypes, GRows, err);
  okB := okA and VDbArrowImport(GDir + 'big.arrow', GOutFields, GOutTypes,
    GOut, err);
  ok := okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  Chk('F8a Arrow 20000 satir birebir', ok,
    reason + ' [' + IntToStr(badI) + '] ' + err);

  err := '';
  okA := VDbParquetExport(GDir + 'big.parquet', GFields, GTypes, GRows, err);
  okB := okA and VDbParquetImport(GDir + 'big.parquet', GOutFields, GOutTypes,
    GOut, err);
  ok := okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  Chk('F8b Parquet 20000 satir birebir', ok,
    reason + ' [' + IntToStr(badI) + '] ' + err);

  { ---------------- cok kolon: 60 ---------------- }
  SetLength(GFields, 60);
  SetLength(GTypes, 60);
  for j := 0 to 59 do
  begin
    GFields[j] := 'c' + IntToStr(j);
    GTypes[j] := VCT_INT;
  end;
  SetLength(GRows, 3);
  for i := 0 to 2 do
  begin
    SetLength(GRows[i], 60);
    for j := 0 to 59 do GRows[i][j] := IntToStr(i * 100 + j);
  end;
  err := '';
  okA := VDbArrowExport(GDir + 'wide.arrow', GFields, GTypes, GRows, err);
  okB := okA and VDbArrowImport(GDir + 'wide.arrow', GOutFields, GOutTypes,
    GOut, err);
  ok := okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  err := '';
  okA := VDbParquetExport(GDir + 'wide.parquet', GFields, GTypes, GRows, err);
  okB := okA and VDbParquetImport(GDir + 'wide.parquet', GOutFields, GOutTypes,
    GOut, err);
  ok := ok and okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  Chk('F9 Cok kolon (60) iki bicimde de korunur', ok, reason + ' ' + err);

  { ---------------- buyuk deger ---------------- }
  SetLength(GFields, 2);
  GFields[0] := 'txt'; GFields[1] := 'bin';
  SetLength(GTypes, 2);
  GTypes[0] := VCT_STR; GTypes[1] := VCT_BLOB;
  p := RepStr('A', 100000);
  q := RepStr('B', 300000);
  SetLength(GRows, 1);
  SetLength(GRows[0], 2);
  GRows[0][0] := p;
  GRows[0][1] := q;
  err := '';
  okA := VDbArrowExport(GDir + 'huge.arrow', GFields, GTypes, GRows, err);
  okB := okA and VDbArrowImport(GDir + 'huge.arrow', GOutFields, GOutTypes,
    GOut, err);
  ok := okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  err := '';
  okA := VDbParquetExport(GDir + 'huge.parquet', GFields, GTypes, GRows, err);
  okB := okA and VDbParquetImport(GDir + 'huge.parquet', GOutFields, GOutTypes,
    GOut, err);
  ok := ok and okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  Chk('F10 Buyuk deger (100 KB metin + 300 KB BLOB)', ok,
    reason + ' uzunluk=' + IntToStr(Length(aVal)) + ' ' + err);

  { ---------------- UTF-8 ---------------- }
  SetLength(GFields, 1);
  GFields[0] := 'u';
  SetLength(GTypes, 1);
  GTypes[0] := VCT_STR;
  SetLength(GRows, 1);
  SetLength(GRows[0], 1);
  GRows[0][0] := #196#177#196#159#195#188#197#159#195#182#195#167 +
    ' ' + #196#176#73 + ' '#226#130#172;
  err := '';
  okA := VDbArrowExport(GDir + 'u.arrow', GFields, GTypes, GRows, err);
  okB := okA and VDbArrowImport(GDir + 'u.arrow', GOutFields, GOutTypes, GOut,
    err);
  ok := okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  err := '';
  okA := VDbParquetExport(GDir + 'u.parquet', GFields, GTypes, GRows, err);
  okB := okA and VDbParquetImport(GDir + 'u.parquet', GOutFields, GOutTypes,
    GOut, err);
  ok := ok and okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason);
  Chk('F11 UTF-8 metin bozulmadan doner', ok, reason + ' ' + err);

  { ---------------- bos metin ---------------- }
  GRows[0][0] := '';
  err := '';
  okA := VDbParquetExport(GDir + 'e.parquet', GFields, GTypes, GRows, err);
  okB := okA and VDbParquetImport(GDir + 'e.parquet', GOutFields, GOutTypes,
    GOut, err);
  ok := okB and (Length(GOut) = 1) and (GOut[0][0] = '');
  Chk('F12 Bos metin hucresi kaybolmaz ('''' -> '''')', ok, err);

  { ---------------- bozuk / olmayan dosya ---------------- }
  SetLength(GRows, 1);
  SetLength(GRows[0], 8);
  for j := 0 to 7 do GRows[0][j] := '1';
  SetLength(GFields, 8);
  GFields[0] := 'a'; GFields[1] := 'b'; GFields[2] := 'c'; GFields[3] := 'd';
  GFields[4] := 'e'; GFields[5] := 'f'; GFields[6] := 'g'; GFields[7] := 'h';
  SetLength(GTypes, 8);
  for j := 0 to 7 do GTypes[j] := VCT_INT;

  WriteBytes(GDir + 'bad.arrow', StrToB('bu bir arrow dosyasi degil'));
  WriteBytes(GDir + 'bad.parquet', StrToB('bu bir parquet dosyasi degil GARBAGE'));

  err := '';
  okA := VDbArrowImport(GDir + 'bad.arrow', GOutFields, GOutTypes, GOut, err);
  ok := (not okA) and (err <> '');
  err := '';
  okB := VDbParquetImport(GDir + 'bad.parquet', GOutFields, GOutTypes, GOut, err);
  ok := ok and (not okB) and (err <> '');
  Chk('F13 Bozuk dosya reddedilir (False + Err dolu)', ok, 'err=' + err);

  err := '';
  okA := VDbArrowImport(GDir + 'yok.arrow', GOutFields, GOutTypes, GOut, err);
  ok := (not okA) and (err <> '');
  err := '';
  okB := VDbParquetImport(GDir + 'yok.parquet', GOutFields, GOutTypes, GOut, err);
  ok := ok and (not okB) and (err <> '');
  Chk('F14 Olmayan dosya reddedilir (False + Err dolu)', ok, 'err=' + err);

  { ---------------- harici uretilmis dosyalar (fixture) ---------------- }
  ok := True;
  err := '';

  if not FileExists(GFixDir + 'ext.arrow') then
  begin
    ok := False;
    err := 'fixture yok: ' + GFixDir + 'ext.arrow';
  end
  else
  begin
    okA := VDbArrowImport(GFixDir + 'ext.arrow', GOutFields, GOutTypes, GOut, err);
    ok := okA and CheckFixture(GOut, reason);
  end;
  Chk('F15a Harici Arrow IPC stream okunur (tam icerik)', ok,
    'alan=' + IntToStr(Length(GOutFields)) + ' satir=' + IntToStr(Length(GOut)) +
    ' ' + reason + ' ' + err);

  err := '';
  ok := True;
  if not FileExists(GFixDir + 'ext.parquet') then
  begin
    ok := False;
    err := 'fixture yok: ext.parquet';
  end
  else
  begin
    okA := VDbParquetImport(GFixDir + 'ext.parquet', GOutFields, GOutTypes,
      GOut, err);
    ok := okA and CheckFixture(GOut, reason);
  end;
  Chk('F15b Harici Parquet (UNCOMPRESSED) okunur (tam icerik)', ok,
    'satir=' + IntToStr(Length(GOut)) + ' ' + reason + ' ' + err);

  err := '';
  ok := True;
  if not FileExists(GFixDir + 'ext_snappy.parquet') then
  begin
    ok := False;
    err := 'fixture yok: ext_snappy.parquet';
  end
  else
  begin
    okA := VDbParquetImport(GFixDir + 'ext_snappy.parquet', GOutFields,
      GOutTypes, GOut, err);
    ok := okA and CheckFixture(GOut, reason);
  end;
  Chk('F15c Harici Parquet (SNAPPY) okunur (tam icerik)', ok,
    'satir=' + IntToStr(Length(GOut)) + ' ' + reason + ' ' + err);

  { ---------------- capraz: Arrow ve Parquet ayni degeri verir ---------- }
  SetLength(GFields, 3);
  GFields[0] := 'id'; GFields[1] := 'name'; GFields[2] := 'ok';
  SetLength(GTypes, 3);
  GTypes[0] := VCT_INT; GTypes[1] := VCT_STR; GTypes[2] := VCT_BOOL;
  SetLength(GRows, 5);
  for i := 0 to 4 do
  begin
    SetLength(GRows[i], 3);
    GRows[i][0] := IntToStr(i * 11);
    GRows[i][1] := 'capraz-' + IntToStr(i);
    if Odd(i) then GRows[i][2] := 'true' else GRows[i][2] := 'false';
  end;
  err := '';
  okA := VDbArrowExport(GDir + 'x.arrow', GFields, GTypes, GRows, err) and
    VDbArrowImport(GDir + 'x.arrow', GOutFields, GOutTypes, GOut, err);
  err := '';
  okB := VDbParquetExport(GDir + 'x.parquet', GFields, GTypes, GRows, err) and
    VDbParquetImport(GDir + 'x.parquet', GOutFields, GOutTypes, GOut2, err);
  ok := okA and okB and CmpMatrix(GRows, GOut, badI, badJ, aVal, bVal, reason) and
    CmpMatrix(GOut, GOut2, badI, badJ, aVal, bVal, reason);
  Chk('F16 Ayni veri iki bicimde ayni sonucu verir', ok, reason + ' ' + err);

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
