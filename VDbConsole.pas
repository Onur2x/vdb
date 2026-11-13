unit VDbConsole;

{ P-179: vdb komut satiri kabugu icin oturum birimi.

  Amac: CLI'nin tum mantigini (dot komutlari, bicimlendirme, CSV import)
  arayuzden bagimsiz tutmak; boylece kapida (clichk) gercek REPL olmadan
  satir satir surulebilir.

  Dot komutlari:
    .help                 komut listesi
    .tables               tablolar ve satir sayilari
    .schema [tablo]       CREATE TABLE metinleri
    .backup <yol>         BACKUP TO
    .restore <yol>        RESTORE FROM
    .import <dosya> <tablo> [ayrac]   CSV (baslik satiri kolon adlari)
    .mode table|csv|box   cikti bicimi
    .quit / .exit         cikis

  Diger satirlar SQL'dir; ';' ile ayrilmis coklu cumle desteklenir.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, VDbCore, VDbBackendApi, VDbFactory, VDbTable, VDbSql, VDbAst;

type
  TVdbCliMode = (cmTable, cmCsv, cmBox);

  TVdbCli = class
  private
    FPath: string;
    FBe: IVdbBackend;
    FTb: TVTableDb;
    FSql: TVSql;
    FMode: TVdbCliMode;
    function FmtResult(const R: TSqlResult): string;
    function FmtRows(const Fields: TStrArray; const Rows: TStrMatrix): string;
    function DoMeta(const Cmd, Arg: string): string;
    function DoImport(const Args: string): string;
    function DoBackup(const Dest: string; Restore: Boolean): string;
    function SqlQuote(const S: string): string;
  public
    constructor Create(const ADbPath: string);
    destructor Destroy; override;
    { Tek satir isler. `Quit` True ise REPL kapanmalidir. Hata metni
      'HATA: ' ile baslar (cagiran ayirt edebilsin). }
    function RunLine(const Line: string; out Quit: Boolean): string;
    { Script'i satir satir isler; ciktilari birlestirir. }
    function RunScript(const Script: TStrings): string;
    property Mode: TVdbCliMode read FMode write FMode;
    property DbPath: string read FPath;
    property Sql: TVSql read FSql;
    property TableDb: TVTableDb read FTb;
  end;

function VdbCliModeFromName(const S: string; out M: TVdbCliMode): Boolean;
function VdbCliCsvEscape(const S: string): string;
{ CSV satirini alanlara ayirir (tirnakli alan, "" kacisi). }
function VdbCliSplitCsv(const Line: string; const Delim: Char): TStrArray;

implementation

function VdbCliModeFromName(const S: string; out M: TVdbCliMode): Boolean;
begin
  Result := True;
  if SameText(S, 'table') then M := cmTable
  else if SameText(S, 'csv') then M := cmCsv
  else if SameText(S, 'box') then M := cmBox
  else Result := False;
end;

function VdbCliCsvEscape(const S: string): string;
begin
  if (Pos(',', S) > 0) or (Pos('"', S) > 0) or (Pos(#10, S) > 0) or
    (Pos(#13, S) > 0) then
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := S;
end;

function VdbCliSplitCsv(const Line: string; const Delim: Char): TStrArray;
var
  i, n: Integer;
  cur: string;
  inQ: Boolean;
  c: Char;
begin
  SetLength(Result, 0);
  n := 0;
  cur := '';
  inQ := False;
  i := 1;
  while i <= Length(Line) do
  begin
    c := Line[i];
    if inQ then
    begin
      if c = '"' then
      begin
        if (i < Length(Line)) and (Line[i + 1] = '"') then
        begin
          cur := cur + '"';
          Inc(i);
        end
        else
          inQ := False;
      end
      else
        cur := cur + c;
    end
    else if c = '"' then
      inQ := True
    else if c = Delim then
    begin
      SetLength(Result, n + 1);
      Result[n] := cur;
      Inc(n);
      cur := '';
    end
    else
      cur := cur + c;
    Inc(i);
  end;
  SetLength(Result, n + 1);
  Result[n] := cur;
  if (n = 0) and (Result[0] = '') then
    SetLength(Result, 0);
end;

constructor TVdbCli.Create(const ADbPath: string);
begin
  inherited Create;
  FMode := cmTable;
  FPath := ADbPath;
  VdbOpenOrCreate(ADbPath, FBe);
  FTb := TVTableDb.CreateBackend(FBe);
  FSql := TVSql.Create(FTb);
  FTb.Open(ADbPath);
end;

destructor TVdbCli.Destroy;
begin
  FSql.Free;
  FTb.Free;
  FBe := nil;
  inherited;
end;

function TVdbCli.SqlQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

function TVdbCli.FmtRows(const Fields: TStrArray; const Rows: TStrMatrix): string;
var
  i, j, w, nc: Integer;
  widths: array of Integer;
  sl: TStringList;
  line: string;

  function PadRight(const S: string; W: Integer): string;
  begin
    Result := S;
    while Length(Result) < W do Result := Result + ' ';
  end;

begin
  nc := Length(Fields);
  if nc = 0 then Exit('');
  SetLength(widths, nc);
  for j := 0 to nc - 1 do
    widths[j] := Length(Fields[j]);
  for i := 0 to High(Rows) do
    for j := 0 to nc - 1 do
    begin
      if j > High(Rows[i]) then Continue;
      w := Length(Rows[i][j]);
      if w > widths[j] then widths[j] := w;
    end;

  sl := TStringList.Create;
  try
    if FMode = cmCsv then
    begin
      line := '';
      for j := 0 to nc - 1 do
      begin
        if j > 0 then line := line + ',';
        line := line + VdbCliCsvEscape(Fields[j]);
      end;
      sl.Add(line);
      for i := 0 to High(Rows) do
      begin
        line := '';
        for j := 0 to nc - 1 do
        begin
          if j > 0 then line := line + ',';
          if j <= High(Rows[i]) then
            line := line + VdbCliCsvEscape(Rows[i][j]);
        end;
        sl.Add(line);
      end;
      Exit(sl.Text);
    end;

    line := '';
    for j := 0 to nc - 1 do
    begin
      if j > 0 then line := line + ' | ';
      line := line + PadRight(Fields[j], widths[j]);
    end;
    sl.Add(line);
    line := '';
    for j := 0 to nc - 1 do
    begin
      if j > 0 then line := line + '-+-';
      line := line + StringOfChar('-', widths[j]);
    end;
    sl.Add(line);
    for i := 0 to High(Rows) do
    begin
      line := '';
      for j := 0 to nc - 1 do
      begin
        if j > 0 then line := line + ' | ';
        if j <= High(Rows[i]) then
          line := line + PadRight(Rows[i][j], widths[j])
        else
          line := line + PadRight('', widths[j]);
      end;
      sl.Add(line);
    end;
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function TVdbCli.FmtResult(const R: TSqlResult): string;
begin
  if Length(R.Fields) > 0 then
    Result := FmtRows(R.Fields, R.Rows)
  else if R.Msg <> '' then
    Result := R.Msg + #10
  else if R.Affected > 0 then
    Result := 'Etkilenen satir: ' + IntToStr(R.Affected) + #10
  else
    Result := 'OK' + #10;
end;

function TVdbCli.DoBackup(const Dest: string; Restore: Boolean): string;
var
  R: TSqlResult;
begin
  if Dest = '' then Exit('HATA: yol gerekli' + #10);
  try
    if Restore then
      R := FSql.Exec('RESTORE FROM ' + SqlQuote(Dest))
    else
      R := FSql.Exec('BACKUP TO ' + SqlQuote(Dest));
    Result := FmtResult(R);
  except
    on E: Exception do Result := 'HATA: ' + E.Message + #10;
  end;
end;

function TVdbCli.DoImport(const Args: string): string;
var
  p: Integer;
  FileName, TableName, DelimS, A: string;
  Delim: Char;
  sl, lines: TStringList;
  cols: TStrArray;
  rows: array of TStrArray;
  vals: TStrArray;
  i, j, n, done: Integer;
  fs: TFileStream;
begin
  Result := '';
  A := Trim(Args);
  p := Pos(' ', A);
  if p = 0 then Exit('HATA: .import <dosya> <tablo> [ayrac]' + #10);
  FileName := Copy(A, 1, p - 1);
  A := Trim(Copy(A, p + 1, MaxInt));
  p := Pos(' ', A);
  if p = 0 then
  begin
    TableName := A;
    Delim := ',';
  end
  else
  begin
    TableName := Copy(A, 1, p - 1);
    DelimS := Trim(Copy(A, p + 1, MaxInt));
    if DelimS = '' then Delim := ',' else Delim := DelimS[1];
  end;
  if not FileExists(FileName) then
    Exit('HATA: dosya yok: ' + FileName + #10);

  sl := TStringList.Create;
  lines := TStringList.Create;
  try
    try
      fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
      try
        sl.LoadFromStream(fs);
      finally
        fs.Free;
      end;
    except
      on E: Exception do Exit('HATA: dosya okunamadi: ' + E.Message + #10);
    end;
    for i := 0 to sl.Count - 1 do
      if Trim(sl[i]) <> '' then
        lines.Add(sl[i]);
    if lines.Count < 2 then
      Exit('HATA: CSV en az baslik + bir veri satiri icermeli' + #10);
    cols := VdbCliSplitCsv(lines[0], Delim);
    if Length(cols) = 0 then
      Exit('HATA: baslik satiri bos' + #10);
    done := 0;
    FTb.BeginBatch;
    try
      n := 0;
      SetLength(rows, 0);
      for i := 1 to lines.Count - 1 do
      begin
        vals := VdbCliSplitCsv(lines[i], Delim);
        if Length(vals) <> Length(cols) then
          raise Exception.Create('satir ' + IntToStr(i + 1) + ': ' +
            IntToStr(Length(vals)) + ' alan, beklenen ' + IntToStr(Length(cols)));
        SetLength(rows, n + 1);
        SetLength(rows[n], Length(cols));
        for j := 0 to High(cols) do
          rows[n][j] := vals[j];
        Inc(n);
        if n >= 500 then
        begin
          FTb.BatchInsert(TableName, cols, rows);
          Inc(done, n);
          n := 0;
          SetLength(rows, 0);
        end;
      end;
      if n > 0 then
      begin
        FTb.BatchInsert(TableName, cols, rows);
        Inc(done, n);
      end;
      FTb.CommitBatch;
    except
      FTb.AbortBatch;
      raise;
    end;
    Result := 'Ice aktarilan satir: ' + IntToStr(done) + #10;
  except
    on E: Exception do Result := 'HATA: ' + E.Message + #10;
  end;
end;

function TVdbCli.DoMeta(const Cmd, Arg: string): string;
var
  R: TSqlResult;
  names: TStrArray;
  i: Integer;
begin
  R := Default(TSqlResult);
  if Cmd = '.tables' then
  begin
    names := FTb.TableNames;
    SetLength(R.Fields, 1);
    R.Fields[0] := 'table';
    SetLength(R.Rows, Length(names));
    for i := 0 to High(names) do
    begin
      SetLength(R.Rows[i], 1);
      R.Rows[i][0] := names[i];
    end;
    Exit(FmtRows(R.Fields, R.Rows));
  end;
  if Cmd = '.schema' then
  begin
    if Trim(Arg) <> '' then
    begin
      try
        R := FSql.Exec('SHOW CREATE TABLE ' + Arg);
        Exit(FmtResult(R));
      except
        on E: Exception do Exit('HATA: ' + E.Message + #10);
      end;
    end;
    Result := '';
    names := FTb.TableNames;
    for i := 0 to High(names) do
    begin
      try
        R := FSql.Exec('SHOW CREATE TABLE ' + names[i]);
        Result := Result + FmtResult(R) + #10;
      except
        on E: Exception do Result := Result + 'HATA: ' + names[i] + ': ' +
          E.Message + #10;
      end;
    end;
    Exit;
  end;
  Result := 'HATA: bilinmeyen komut: ' + Cmd + #10;
end;

function TVdbCli.RunLine(const Line: string; out Quit: Boolean): string;
var
  s, cmd, arg: string;
  p: Integer;
  R: TSqlResult;
  st: TStrArray;
begin
  Quit := False;
  Result := '';
  s := Trim(Line);
  if s = '' then Exit;
  if s[1] = '.' then
  begin
    p := Pos(' ', s);
    if p = 0 then
    begin
      cmd := LowerCase(s);
      arg := '';
    end
    else
    begin
      cmd := LowerCase(Copy(s, 1, p - 1));
      arg := Trim(Copy(s, p + 1, MaxInt));
    end;
    if (cmd = '.quit') or (cmd = '.exit') or (cmd = '.q') then
    begin
      Quit := True;
      Exit('bye' + #10);
    end;
    if cmd = '.help' then
      Exit('.tables | .schema [tablo] | .backup <yol> | .restore <yol>' + #10 +
        '.import <dosya> <tablo> [ayrac] | .mode table|csv|box | .quit' + #10);
    if cmd = '.mode' then
    begin
      if VdbCliModeFromName(arg, FMode) then
        Exit('mod=' + LowerCase(arg) + #10)
      else
        Exit('HATA: mod table, csv veya box olmali' + #10);
    end;
    if cmd = '.backup' then Exit(DoBackup(arg, False));
    if cmd = '.restore' then Exit(DoBackup(arg, True));
    if cmd = '.import' then Exit(DoImport(arg));
    if (cmd = '.tables') or (cmd = '.schema') then Exit(DoMeta(cmd, arg));
    Exit('HATA: bilinmeyen komut: ' + cmd + ' (.help)' + #10);
  end;
  try
    st := FSql.SplitStatements(s);
    if Length(st) = 0 then Exit;
    R := FSql.ExecAll(st);
    Result := FmtResult(R);
  except
    on E: Exception do Result := 'HATA: ' + E.Message + #10;
  end;
end;

function TVdbCli.RunScript(const Script: TStrings): string;
var
  i: Integer;
  q: Boolean;
begin
  Result := '';
  for i := 0 to Script.Count - 1 do
  begin
    Result := Result + RunLine(Script[i], q);
    if q then Break;
  end;
end;

end.
