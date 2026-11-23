program interop_external;
{ v3.72 / SKILL6 08 (A) KALICI REGRESYON KAPISI - HARICI yazilimla
  Arrow/Parquet uyumlulugu.

  `tests/interop_format` yalniz VDB <-> VDB tutarliligini olcer. Bu kapi
  "kendi yazdigini kendi okuyor" kanitini ASAR: dosyalari BAGIMSIZ bir
  uygulama (Apache Arrow / pyarrow) dogrular ve VDB'nin yazmadigi dosyalari
  VDB'nin okuyabildigini gosterir.

  Kapida olculen:
    X1  pyarrow (bagimsiz uygulama) VDB'nin yazdigi Arrow dosyasini
        sema + deger olarak birebir dogrular
    X2  pyarrow VDB'nin yazdigi Parquet dosyasini dogrular (PAR1 meta veri)
    X3  pyarrow harici Arrow/Parquet dosyalari uretir (2 batch / 3 row group,
        SNAPPY dahil)
    X4  VDB harici Arrow IPC stream'i birebir okur
    X5  VDB harici Parquet (UNCOMPRESSED) birebir okur
    X6  VDB harici Parquet (SNAPPY) birebir okur
    X7  NULL / bos metin siniri: harici dosyada NULL olan metin ile gercek
        '' ayni sekilde ('' olarak) gelir - belgelenmis sinir, veri kaybi
        degil; satir sayisi korunur

  DIS BAGIMLILIK: python3 + pyarrow. Yoksa kapi **SKIP** (exit 77) verir ve
  gerekce yazilir; ASLA PASS sayilmaz. pyarrow depoya BAGIMLILIK DEGILDIR:
  yalniz dogrulama aracidir, uretim kodu ona bagli degildir.
  pyarrow normal import edilemiyorsa `VDB_PY_LIBS` ortam degiskeni ile
  ek sys.path verilebilir. }
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process, VDbTypes, VDbArrow, VDbParquet;

const
  SKIP_CODE = 77;

var
  GPass, GFail: Integer;
  GDir, GScript: string;
  GPy: string;
  GPyOK: Boolean;

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

function TryExe(const AExe: string; const AArg: string; out AOut: string): Boolean;
begin
  AOut := '';
  try
    Result := RunCommand(AExe, [AArg], AOut);
  except
    Result := False;
  end;
end;

{ FPC RunCommand arguman listesini OLDUGU GIBI gecirir; icine tirnak
  gomulurse python tek bozuk arguman gorur. Bu yuzden cok argumanli
  cagrilar bu yardimciyi kullanir. }
function TryExe2(const AExe: string; const AArgs: array of string;
  out AOut: string): Boolean;
begin
  AOut := '';
  try
    Result := RunCommand(AExe, AArgs, AOut);
  except
    Result := False;
  end;
end;

{ Python yorumlayicisini bulur ve pyarrow'un gercekten import edilebildigini
  dogrular. Bulunamazsa gerekce dondurur. }
function FindPython(out AReason: string): Boolean;
var
  cand: array[0..4] of string;
  i: Integer;
  outp: string;
begin
  Result := False;
  AReason := '';
  cand[0] := GetEnvironmentVariable('VDB_INTEROP_PY');
  cand[1] := 'python';
  cand[2] := 'python3';
  cand[3] := 'py';
  cand[4] := 'C:\Python314\python.exe';
  for i := 0 to High(cand) do
  begin
    if cand[i] = '' then Continue;
    if (Pos('\', cand[i]) > 0) and (not FileExists(cand[i])) then Continue;
    if not TryExe(cand[i], '--version', outp) then Continue;
    if (Pos('Python', outp) = 0) and (Pos('python', outp) = 0) then Continue;
    GPy := cand[i];
    if TryExe2(GPy, [GScript, 'selftest'], outp) and
       (Pos('OK pyarrow', outp) > 0) then
    begin
      Result := True;
      Exit;
    end;
    AReason := 'python bulundu (' + GPy + ') ama pyarrow yok: ' +
      Trim(StringReplace(outp, #13, ' ', [rfReplaceAll]));
  end;
  if AReason = '' then
    AReason := 'python3 bulunamadi (VDB_INTEROP_PY ile yol verilebilir)';
end;

{ python cagrisi. Argumanlar AYRI eleman olarak gecilir: Windows'ta FPC
  komut satirini kendisi kurup tirnaklari yorumlar, Linux'ta ise argv
  dizisini oldugu gibi execv'e verir; tek elemana gomulmus tirnak ikinci
  durumda bozuk arguman olur. }
function RunPyArgs(const AArgs: array of string; out AOut: string): Boolean;
begin
  try
    Result := RunCommand(GPy, AArgs, AOut);
  except
    Result := False;
    AOut := 'python calistirilamadi';
  end;
end;

{ sinir disi indekste '' doner: bir import basarisiz oldugunda ayrinti
  metnini kurarken imlecin erisim ihlali ile dusmesini engeller. }
function CellText(const M: TStrMatrix; ARow, ACol: Integer): string;
begin
  Result := '';
  if (ARow >= 0) and (ARow < Length(M)) and (ACol >= 0) and
    (ACol < Length(M[ARow])) then
    Result := M[ARow][ACol];
end;

function Clean(const S: string): string;
begin
  Result := Trim(StringReplace(StringReplace(S, #13, ' ', [rfReplaceAll]),
    #10, ' | ', [rfReplaceAll]));
  if Length(Result) > 400 then Result := Copy(Result, 1, 400) + '...';
end;

function RowOf(const A, B, C, D, E, F, G, H: string): TStrArray;
begin
  SetLength(Result, 8);
  Result[0] := A; Result[1] := B; Result[2] := C; Result[3] := D;
  Result[4] := E; Result[5] := F; Result[6] := G; Result[7] := H;
end;

{ Saat metni. Daha once FormatDateTime('hh:nn:ss', 0.5 + i/86400) ile
  hesaplaniyordu: kayan nokta toplami bazi platformlarda 12:00:00.999...
  verip saniye ASAGI yuvarlandigi icin test kendi urettigi veriyi yanlis
  bekliyordu. Beklenti artik tam sayidan kurulur. }
function ClockStr(const AHour, AMin, ASec: Word): string;
begin
  Result := Format('%.2d:%.2d:%.2d', [AHour, AMin, ASec]);
end;

{ verify.py `gen` ile uretilen 6 satirlik tablonun TAM icerigini dogrular.
  name alani: satir 4 NULL, satir 5 gercek '' -> ikisi de '' gelir. }
function CheckExternal(const M: TStrMatrix; out Reason: string): Boolean;
var
  i: Integer;
  sc: Double;
  d: TDateTime;
begin
  Result := False;
  Reason := '';
  if Length(M) <> 6 then
  begin
    Reason := 'satir ' + IntToStr(Length(M)) + ' <> 6';
    Exit;
  end;
  for i := 0 to 5 do
  begin
    if Length(M[i]) <> 8 then
    begin
      Reason := 'kolon (satir ' + IntToStr(i) + ')=' + IntToStr(Length(M[i]));
      Exit;
    end;
    if M[i][0] <> IntToStr(i) then
    begin
      Reason := 'id ' + IntToStr(i) + '=' + M[i][0];
      Exit;
    end;
    if not TryStrToFloat(M[i][1], sc) or (Abs(sc - i / 2.0) > 1e-12) then
    begin
      Reason := 'score ' + IntToStr(i) + '=' + M[i][1];
      Exit;
    end;
    if i < 4 then
    begin
      if M[i][2] <> 'n-' + IntToStr(i) then
      begin
        Reason := 'name ' + IntToStr(i) + '=' + M[i][2];
        Exit;
      end;
    end
    else if M[i][2] <> '' then
    begin
      Reason := 'name ' + IntToStr(i) + ' (NULL/bos) =' + M[i][2];
      Exit;
    end;
    if (M[i][3] = 'true') <> (i mod 2 = 0) then
    begin
      Reason := 'ok ' + IntToStr(i) + '=' + M[i][3];
      Exit;
    end;
    d := EncodeDate(2026, 3, 1) + i;
    if Pos(FormatDateTime('yyyy-mm-dd', d), M[i][4]) <> 1 then
    begin
      Reason := 'born ' + IntToStr(i) + '=' + M[i][4];
      Exit;
    end;
    if Pos(FormatDateTime('yyyy-mm-dd', EncodeDate(2026, 3, 1)) + ' ' +
      ClockStr(12, 0, i), M[i][5]) <> 1 then
    begin
      Reason := 'seen ' + IntToStr(i) + '=' + M[i][5];
      Exit;
    end;
    if Pos(ClockStr(12, 0, i), M[i][6]) <> 1 then
    begin
      Reason := 'at ' + IntToStr(i) + '=' + M[i][6];
      Exit;
    end;
    if i <> 3 then
    begin
      if M[i][7] <> 'x' + IntToStr(i) then
      begin
        Reason := 'blob ' + IntToStr(i) + '=' + M[i][7];
        Exit;
      end;
    end
    else if M[i][7] <> '' then
    begin
      Reason := 'blob 3 (NULL) =' + M[i][7];
      Exit;
    end;
  end;
  Result := True;
end;

{ ext_vdb_units.arrow: Date/Time birim varsayilanlari. Arrow'da Date.unit ve
  Time.unit varsayilani MILLISECOND'dur; pyarrow varsayilana esit birimi
  YAZMAZ, bu yuzden time32[ms] ve date64[ms] "birimsiz" tablo olarak gelir.
  Varsayilan 0 (SECOND) varsayilirsa time32[ms] 1000 kat, date64 ise gun
  sanilip tamamen yanlis okunuyordu (SKILL6 08'de bulunan gercek defect). }
function CheckUnits(const M: TStrMatrix; out Reason: string): Boolean;
var
  i, j: Integer;
  want: array[0..4] of string;
begin
  Result := False;
  Reason := '';
  if Length(M) <> 3 then
  begin
    Reason := 'satir ' + IntToStr(Length(M)) + ' <> 3';
    Exit;
  end;
  for i := 0 to 2 do
  begin
    if Length(M[i]) <> 5 then
    begin
      Reason := 'kolon (satir ' + IntToStr(i) + ')=' + IntToStr(Length(M[i]));
      Exit;
    end;
    want[0] := '2026-03-01';
    want[1] := ClockStr(12, 0, i);
    want[2] := want[1];
    want[3] := want[1];
    want[4] := want[1];
    for j := 0 to 4 do
      if Pos(want[j], M[i][j]) <> 1 then
      begin
        Reason := 'alan ' + IntToStr(j) + ' satir ' + IntToStr(i) + '=' +
          M[i][j] + ' beklenen=' + want[j];
        Exit;
      end;
  end;
  Result := True;
end;

function CNull: TVdbCell;
begin
  Result.Kind := vckNull; Result.I := 0; Result.F := 0; Result.S := '';
end;

function CInt(const AValue: Int64): TVdbCell;
begin
  Result.Kind := vckInt; Result.I := AValue; Result.F := 0; Result.S := '';
end;

function CFlt(const AValue: Double): TVdbCell;
begin
  Result.Kind := vckFloat; Result.I := 0; Result.F := AValue; Result.S := '';
end;

function CBool(const AValue: Boolean): TVdbCell;
begin
  Result.Kind := vckBool; Result.S := '';
  if AValue then Result.I := 1 else Result.I := 0;
  Result.F := 0;
end;

function CText(const AValue: string): TVdbCell;
begin
  Result.Kind := vckText; Result.I := 0; Result.F := 0; Result.S := AValue;
end;

function CBlob(const AValue: string): TVdbCell;
begin
  Result.Kind := vckBlob; Result.I := 0; Result.F := 0; Result.S := AValue;
end;

{ SKILL13 tipli kapsam: 5 alan, 4 satir. verify.py CELL_ROWS ile AYNI.
  Satir 0 bos metin + bos ikili GERCEK deger; satir 1 dort alan NULL;
  satir 3 metin NULL ama ikili bos. }
procedure MakeCells(out C: TVdbCellMatrix);
begin
  SetLength(C, 4, 5);
  C[0][0] := CInt(1); C[0][1] := CText(''); C[0][2] := CBlob('');
  C[0][3] := CFlt(1.5); C[0][4] := CBool(True);
  C[1][0] := CInt(2); C[1][1] := CNull; C[1][2] := CNull;
  C[1][3] := CNull; C[1][4] := CNull;
  C[2][0] := CInt(3); C[2][1] := CText('x'); C[2][2] := CBlob('AB');
  C[2][3] := CFlt(2.0); C[2][4] := CBool(False);
  C[3][0] := CInt(4); C[3][1] := CNull; C[3][2] := CBlob('');
  C[3][3] := CFlt(0.0); C[3][4] := CBool(True);
end;

function SliceCells(const C: TVdbCellMatrix; AFrom, ACount: Integer): TVdbCellMatrix;
var
  i, j: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
  begin
    SetLength(Result[i], Length(C[AFrom + i]));
    for j := 0 to High(C[AFrom + i]) do
      Result[i][j] := C[AFrom + i][j];
  end;
end;

{ Tipli gidis-donus: tur (Kind) ve yuk birebir ayni olmali. NULL'un
  vckNull kalmasi bu karsilastirmanin ta kendisidir. }
function SameCells(const A, B: TVdbCellMatrix; out Reason: string): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  Reason := '';
  if Length(A) <> Length(B) then
  begin
    Reason := 'satir ' + IntToStr(Length(A)) + '<>' + IntToStr(Length(B));
    Exit;
  end;
  for i := 0 to High(A) do
  begin
    if Length(A[i]) <> Length(B[i]) then
    begin
      Reason := 'kolon ' + IntToStr(i);
      Exit;
    end;
    for j := 0 to High(A[i]) do
    begin
      if A[i][j].Kind <> B[i][j].Kind then
      begin
        Reason := 'tur ' + IntToStr(i) + ',' + IntToStr(j) + ' ' +
          IntToStr(Ord(A[i][j].Kind)) + '<>' + IntToStr(Ord(B[i][j].Kind));
        Exit;
      end;
      case A[i][j].Kind of
        vckInt, vckBool:
          if A[i][j].I <> B[i][j].I then
          begin
            Reason := 'tam ' + IntToStr(i) + ',' + IntToStr(j);
            Exit;
          end;
        vckFloat:
          if A[i][j].F <> B[i][j].F then
          begin
            Reason := 'ondalik ' + IntToStr(i) + ',' + IntToStr(j);
            Exit;
          end;
        vckText, vckBlob:
          if A[i][j].S <> B[i][j].S then
          begin
            Reason := 'metin ' + IntToStr(i) + ',' + IntToStr(j) + ' uzunluk ' +
              IntToStr(Length(A[i][j].S)) + '<>' + IntToStr(Length(B[i][j].S));
            Exit;
          end;
      end;
    end;
  end;
  Result := True;
end;

type
  TCellCollector = class
  public
    All: TVdbCellMatrix;
    Sizes: array of Integer;
    procedure Add(const Cells: TVdbCellMatrix);
    procedure Reset;
  end;

procedure TCellCollector.Reset;
begin
  All := nil;
  Sizes := nil;
end;

procedure TCellCollector.Add(const Cells: TVdbCellMatrix);
var
  i, j, base: Integer;
begin
  SetLength(Sizes, Length(Sizes) + 1);
  Sizes[High(Sizes)] := Length(Cells);
  base := Length(All);
  SetLength(All, base + Length(Cells));
  for i := 0 to High(Cells) do
  begin
    SetLength(All[base + i], Length(Cells[i]));
    for j := 0 to High(Cells[i]) do
      All[base + i][j] := Cells[i][j];
  end;
end;

function SumSizes(const C: TCellCollector): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(C.Sizes) do
    Result := Result + C.Sizes[i];
end;

function AllSizes(const C: TCellCollector; AWant: Integer): Boolean;
var
  i: Integer;
begin
  Result := Length(C.Sizes) > 0;
  for i := 0 to High(C.Sizes) do
    if C.Sizes[i] <> AWant then
      Result := False;
end;

var
  GFields, GOutFields, GFixFields: TStrArray;
  GTypes, GOutTypes, GFixTypes: TByteArray;
  GRows, GOut: TStrMatrix;
  GCells, GWant, GCells2: TVdbCellMatrix;
  CFields: TStrArray;
  CTypes: TByteArray;
  CCells: TCellCollector;
  WArrow: TVdbArrowWriter;
  WParquet: TVdbParquetWriter;
  bigText, bigBlob: string;
  Err, outp, reason: string;
  ok, okA, okB: Boolean;
  p, q: string;

begin
  DefaultFormatSettings.DecimalSeparator := '.';
  GPass := 0;
  GFail := 0;
  if ParamStr(1) <> '' then GDir := IncludeTrailingPathDelimiter(ParamStr(1))
  else GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'tmp' +
    PathDelim;
  if not DirectoryExists(GDir) then ForceDirectories(GDir);
  if ParamStr(2) <> '' then
    GScript := ExpandFileName(IncludeTrailingPathDelimiter(ParamStr(2)) + 'verify.py')
  else if FileExists(ExtractFilePath(ParamStr(0)) + 'verify.py') then
    GScript := ExpandFileName(ExtractFilePath(ParamStr(0)) + 'verify.py')
  else
    GScript := ExpandFileName(IncludeTrailingPathDelimiter(
      ExtractFilePath(ExtractFileDir(ParamStr(0)))) + 'interop_external' +
      PathDelim + 'verify.py');
  if not FileExists(GScript) then
  begin
    WriteLn('SKIP interop_external | verify.py bulunamadi');
    Halt(SKIP_CODE);
  end;

  GPy := '';
  GPyOK := FindPython(reason);
  if not GPyOK then
  begin
    WriteLn('SKIP interop_external | ', reason);
    Halt(SKIP_CODE);
  end;

  { ---- 1) VDB yazar, pyarrow dogrular ---- }
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

  p := GDir + 'vdb_out.arrow';
  q := GDir + 'vdb_out.parquet';
  err := '';
  okA := VDbArrowExport(p, GFields, GTypes, GRows, err);
  ok := okA and RunPyArgs([GScript, 'check', p, 'arrow'], outp) and
    (Pos('OK arrow', outp) > 0);
  Chk('X1 pyarrow VDB Arrow ciktisini dogrular', ok,
    Clean(err + ' ' + outp));

  err := '';
  okB := VDbParquetExport(q, GFields, GTypes, GRows, err);
  ok := okB and RunPyArgs([GScript, 'check', q, 'parquet'], outp) and
    (Pos('OK parquet', outp) > 0);
  Chk('X2 pyarrow VDB Parquet ciktisini dogrular', ok,
    Clean(err + ' ' + outp));

  { ---- 2) pyarrow yazar, VDB okur ---- }
  ok := RunPyArgs([GScript, 'gen', ExcludeTrailingPathDelimiter(GDir)],
    outp) and (Pos('GEN ext_vdb.arrow', outp) > 0)
    and (Pos('GEN ext_vdb.parquet', outp) > 0)
    and (Pos('GEN ext_vdb_snappy.parquet', outp) > 0);
  Chk('X3 pyarrow harici dosyalari uretir', ok, Clean(outp));

  err := '';
  ok := VDbArrowImport(GDir + 'ext_vdb.arrow', GOutFields, GOutTypes, GOut, err)
    and CheckExternal(GOut, reason);
  Chk('X4 VDB harici Arrow IPC stream''i birebir okur', ok,
    reason + ' ' + err);

  err := '';
  ok := VDbParquetImport(GDir + 'ext_vdb.parquet', GOutFields, GOutTypes, GOut,
    err) and CheckExternal(GOut, reason);
  Chk('X5 VDB harici Parquet (UNCOMPRESSED) birebir okur', ok,
    reason + ' ' + err);

  err := '';
  ok := VDbParquetImport(GDir + 'ext_vdb_snappy.parquet', GOutFields, GOutTypes,
    GOut, err) and CheckExternal(GOut, reason);
  Chk('X6 VDB harici Parquet (SNAPPY) birebir okur', ok, reason + ' ' + err);

  { ---- 3) NULL / bos metin siniri ---- }
  err := '';
  ok := VDbParquetImport(GDir + 'ext_vdb.parquet', GOutFields, GOutTypes, GOut,
    err);
  ok := ok and (Length(GOut) = 6) and (Length(GOut[4]) = 8) and
    (Length(GOut[5]) = 8) and (CellText(GOut, 4, 2) = '') and
    (CellText(GOut, 5, 2) = '') and (CellText(GOut, 3, 7) = '');
  Chk('X7 NULL ve gercek '''' ikisi de '''' gelir (belgelenmis sinir)', ok,
    'null_alan=''' + CellText(GOut, 4, 2) + ''' bos_alan=''' +
    CellText(GOut, 5, 2) + ''' ' + err);

  { ---- 4) Date/Time birim varsayilanlari ---- }
  err := '';
  ok := VDbArrowImport(GDir + 'ext_vdb_units.arrow', GOutFields, GOutTypes,
    GOut, err) and CheckUnits(GOut, reason);
  Chk('X8 date64/date32 ve time32/64 birimleri dogru okunur', ok,
    reason + ' ' + err);

  { ---- 5) SKILL13: tipli export/import, NULL ile bos ayrimi ---- }
  SetLength(CFields, 5);
  CFields[0] := 'id'; CFields[1] := 'name'; CFields[2] := 'blob';
  CFields[3] := 'score'; CFields[4] := 'ok';
  SetLength(CTypes, 5);
  CTypes[0] := VCT_INT; CTypes[1] := VCT_STR; CTypes[2] := VCT_BLOB;
  CTypes[3] := VCT_FLOAT; CTypes[4] := VCT_BOOL;
  MakeCells(GWant);

  err := '';
  ok := VDbArrowExportCells(GDir + 'vdb_cells.arrow', CFields, CTypes, GWant,
    err);
  ok := ok and RunPyArgs([GScript, 'checkcells', GDir + 'vdb_cells.arrow',
    'arrow'], outp) and (Pos('OK cells', outp) > 0);
  Chk('Y1 tipli Arrow: NULL / bos metin / bos ikili ayrilir', ok,
    Clean(err + ' ' + outp));

  err := '';
  ok := VDbParquetExportCells(GDir + 'vdb_cells.parquet', CFields, CTypes, GWant,
    err);
  ok := ok and RunPyArgs([GScript, 'checkcells', GDir + 'vdb_cells.parquet',
    'parquet'], outp) and (Pos('OK cells', outp) > 0);
  Chk('Y2 tipli Parquet: NULL / bos metin / bos ikili ayrilir', ok,
    Clean(err + ' ' + outp));

  ok := RunPyArgs([GScript, 'gennulls', ExcludeTrailingPathDelimiter(GDir)],
    outp) and (Pos('GEN ext_nulls.arrow', outp) > 0) and
    (Pos('GEN ext_nulls.parquet', outp) > 0);
  Chk('Y3 pyarrow NULL/bos ayrimi tasiyan dosyalari uretir', ok, Clean(outp));

  err := '';
  ok := VDbArrowImportCells(GDir + 'ext_nulls.arrow', GOutFields, GOutTypes,
    GCells, err) and SameCells(GCells, GWant, reason);
  Chk('Y4 tipli import (Arrow): NULL vckNull, bos gercek deger', ok,
    reason + ' ' + err);

  err := '';
  ok := VDbParquetImportCells(GDir + 'ext_nulls.parquet', GOutFields, GOutTypes,
    GCells, err) and SameCells(GCells, GWant, reason);
  Chk('Y5 tipli import (Parquet): NULL vckNull, bos gercek deger', ok,
    reason + ' ' + err);

  err := '';
  ok := VDbArrowImportCells(GDir + 'vdb_cells.arrow', GOutFields, GOutTypes,
    GCells, err) and SameCells(GCells, GWant, reason);
  Chk('Y6 tipli Arrow gidis-donus birebir (tur + deger)', ok,
    reason + ' ' + err);

  err := '';
  ok := VDbParquetImportCells(GDir + 'vdb_cells.parquet', GOutFields, GOutTypes,
    GCells, err) and SameCells(GCells, GWant, reason);
  Chk('Y7 tipli Parquet gidis-donus birebir (tur + deger)', ok,
    reason + ' ' + err);

  { ---- 6) Batch yazici / okuyucu (spec E) ---- }
  CCells := TCellCollector.Create;
  try
    ok := True;
    WArrow := TVdbArrowWriter.Create(GDir + 'vdb_batch.arrow', CFields, CTypes);
    try
      WArrow.WriteBatch(SliceCells(GWant, 0, 2));
      WArrow.WriteBatch(SliceCells(GWant, 2, 1));
      WArrow.WriteBatch(SliceCells(GWant, 3, 1));
    finally
      WArrow.Free;  { dosyayi EOS ile kapatir }
    end;
    err := '';
    ok := ok and VDbArrowReadBatches(GDir + 'vdb_batch.arrow', GOutFields,
      GOutTypes, CCells.Add, err);
    ok := ok and (Length(CCells.Sizes) = 3) and (CCells.Sizes[0] = 2) and
      (CCells.Sizes[1] = 1) and (CCells.Sizes[2] = 1) and
      SameCells(CCells.All, GWant, reason);
    ok := ok and RunPyArgs([GScript, 'checkcells', GDir + 'vdb_batch.arrow',
      'arrow'], outp) and (Pos('OK cells', outp) > 0);
  finally
    CCells.Free;
  end;
  Chk('Y8 Arrow batch yazici: 3 batch, kapali dosyadan tekrar okunur', ok,
    Clean(err + ' ' + outp + ' ' + reason));

  CCells := TCellCollector.Create;
  try
    ok := True;
    WParquet := TVdbParquetWriter.Create(GDir + 'vdb_batch.parquet', CFields,
      CTypes);
    try
      WParquet.WriteBatch(SliceCells(GWant, 0, 2));
      WParquet.WriteBatch(SliceCells(GWant, 2, 1));
      WParquet.WriteBatch(SliceCells(GWant, 3, 1));
    finally
      WParquet.Free;
    end;
    err := '';
    ok := ok and VDbParquetReadBatches(GDir + 'vdb_batch.parquet', GOutFields,
      GOutTypes, CCells.Add, err);
    ok := ok and (Length(CCells.Sizes) = 3) and (CCells.Sizes[0] = 2) and
      (CCells.Sizes[1] = 1) and (CCells.Sizes[2] = 1) and
      SameCells(CCells.All, GWant, reason);
    ok := ok and RunPyArgs([GScript, 'checkcells', GDir + 'vdb_batch.parquet',
      'parquet'], outp) and (Pos('rg=3', outp) > 0);
  finally
    CCells.Free;
  end;
  Chk('Y9 Parquet batch yazici: 3 row group, kapali dosyadan tekrar okunur',
    ok, Clean(err + ' ' + outp + ' ' + reason));

  { ---- 7) Cok buyuk metin / ikili ---- }
  bigText := StringOfChar('A', 1024 * 1024);
  bigBlob := StringOfChar('B', 512 * 1024);
  SetLength(GCells2, 1, 2);
  GCells2[0][0] := CText(bigText);
  GCells2[0][1] := CBlob(bigBlob);
  SetLength(CFields, 2);
  CFields[0] := 't'; CFields[1] := 'b';
  SetLength(CTypes, 2);
  CTypes[0] := VCT_STR; CTypes[1] := VCT_BLOB;

  err := '';
  ok := VDbArrowExportCells(GDir + 'vdb_big.arrow', CFields, CTypes, GCells2,
    err) and VDbArrowImportCells(GDir + 'vdb_big.arrow', GOutFields, GOutTypes,
    GCells, err) and SameCells(GCells, GCells2, reason);
  Chk('Y10 1 MB metin + 512 KB ikili Arrow tipli gidis-donus', ok,
    reason + ' ' + err);

  err := '';
  ok := VDbParquetExportCells(GDir + 'vdb_big.parquet', CFields, CTypes,
    GCells2, err) and VDbParquetImportCells(GDir + 'vdb_big.parquet',
    GOutFields, GOutTypes, GCells, err) and SameCells(GCells, GCells2, reason);
  Chk('Y11 1 MB metin + 512 KB ikili Parquet tipli gidis-donus', ok,
    reason + ' ' + err);

  { ---- 8) Buyuk dosyada batch/grup bazli okuma ---- }
  ok := RunPyArgs([GScript, 'genbig', ExcludeTrailingPathDelimiter(GDir)],
    outp) and (Pos('batches=40', outp) > 0);
  CCells := TCellCollector.Create;
  try
    err := '';
    ok := ok and VDbArrowReadBatches(GDir + 'ext_big.arrow', GOutFields,
      GOutTypes, CCells.Add, err);
    ok := ok and (Length(CCells.Sizes) = 40) and AllSizes(CCells, 250) and
      (SumSizes(CCells) = 10000) and (Length(CCells.All) = 10000) and
      (CCells.All[9999][0].Kind = vckInt) and (CCells.All[9999][0].I = 9999) and
      (CCells.All[9999][1].S = 'r9999');
  finally
    CCells.Free;
  end;
  Chk('Y12 buyuk Arrow stream batch bazli okunur (40 batch / 10000 satir)', ok,
    Clean(outp + ' ' + err));

  ok := RunPyArgs([GScript, 'genbigparquet',
    ExcludeTrailingPathDelimiter(GDir)], outp) and (Pos('groups=50', outp) > 0);
  CCells := TCellCollector.Create;
  try
    err := '';
    ok := ok and VDbParquetReadBatches(GDir + 'ext_big.parquet', GOutFields,
      GOutTypes, CCells.Add, err);
    ok := ok and (Length(CCells.Sizes) = 50) and AllSizes(CCells, 200) and
      (SumSizes(CCells) = 10000) and (Length(CCells.All) = 10000) and
      (CCells.All[9999][0].I = 9999) and (CCells.All[9999][1].S = 'r9999');
  finally
    CCells.Free;
  end;
  Chk('Y13 buyuk Parquet row group bazli okunur (50 grup / 10000 satir)', ok,
    Clean(outp + ' ' + err));

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
