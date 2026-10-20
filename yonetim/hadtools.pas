unit hadtools;

{ VDb Manager dosya araclari: CSV disari/iceri, SQL dump,
  kayitli sorgular dosyasi. ASCII-Turkce. }

{$mode delphi}

interface

uses
  Classes, SysUtils, VDbTable, VDbJson;

function SqlQuote(const V: string): string;
procedure TableToCSV(Tb: TVTableDb; const Table, Path: string);
function CSVToTable(Tb: TVTableDb; const Table, Path: string;
  HasHeader: Boolean): Integer;
procedure DumpToSQL(Tb: TVTableDb; const Path: string);
procedure LoadSavedQueries(const Path: string; Names, Sqls: TStrings);
procedure SaveSavedQueries(const Path: string; Names, Sqls: TStrings);
// 2026-10-04: indeks taniminda "a,b,c" listesini ayirmak icin
// (cok kolonlu indeks olusturma). Once yalniz uygulama iciydi.
procedure SplitCSV(const S: string; out Cells: TStrArray; Delim: Char = ',');

implementation

function SqlQuote(const V: string): string;
var
  t: string;
  f: Double;
  fs: TFormatSettings;
begin
  t := Trim(V);
  if t = '' then Exit('NULL');
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  if TryStrToFloat(t, f, fs) then Exit(t);
  Result := '''' + StringReplace(t, '''', '''''', [rfReplaceAll]) + '''';
end;

function CsvCell(const V: string): string;
begin
  if (Pos(',', V) > 0) or (Pos('"', V) > 0) or (Pos(#10, V) > 0) or
     (Pos(#13, V) > 0) then
    Result := '"' + StringReplace(V, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := V;
end;

procedure TableToCSV(Tb: TVTableDb; const Table, Path: string);
var
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  sl: TStringList;
  i, j: Integer;
  line: string;
begin
  td := Tb.GetTable(Table);
  Tb.ScanRows(Table, pks, rows);
  sl := TStringList.Create;
  try
    line := '';
    for j := 0 to High(td.Cols) do
    begin
      if j > 0 then line := line + ',';
      line := line + CsvCell(td.Cols[j].Name);
    end;
    sl.Add(line);
    for i := 0 to High(pks) do
    begin
      line := '';
      for j := 0 to High(td.Cols) do
      begin
        if j > 0 then line := line + ',';
        line := line + CsvCell(rows[i][j]);
      end;
      sl.Add(line);
    end;
    sl.SaveToFile(Path);
  finally
    sl.Free;
  end;
end;

procedure SplitCSV(const S: string; out Cells: TStrArray; Delim: Char = ',');
var
  i: Integer;
  cur: string;
  inQ: Boolean;
begin
  SetLength(Cells, 0);
  cur := '';
  inQ := False;
  i := 1;
  while i <= Length(S) do
  begin
    if inQ then
    begin
      if S[i] = '"' then
      begin
        if (i < Length(S)) and (S[i + 1] = '"') then
        begin
          cur := cur + '"';
          Inc(i, 2);
        end
        else
        begin
          inQ := False;
          Inc(i);
        end;
      end
      else
      begin
        cur := cur + S[i];
        Inc(i);
      end;
    end
    else
    begin
      if S[i] = Delim then
      begin
        SetLength(Cells, Length(Cells) + 1);
        Cells[High(Cells)] := cur;
        cur := '';
        Inc(i);
      end
      else if S[i] = '"' then
      begin
        inQ := True;
        Inc(i);
      end
      else
      begin
        cur := cur + S[i];
        Inc(i);
      end;
    end;
  end;
  SetLength(Cells, Length(Cells) + 1);
  Cells[High(Cells)] := cur;
end;

function DetectDelim(const S: string): Char;
var
  i, sc, cc: Integer;
begin
  sc := 0;
  cc := 0;
  for i := 1 to Length(S) do
    if S[i] = ';' then
      Inc(sc)
    else if S[i] = ',' then
      Inc(cc);
  if sc > cc then
    Result := ';'
  else
    Result := ',';
end;

function CSVToTable(Tb: TVTableDb; const Table, Path: string;
  HasHeader: Boolean): Integer;
var
  td: TTableDef;
  sl: TStringList;
  i, j, r0: Integer;
  cells: TStrArray;
  cnames: array of string;
  batch: array of TStrArray;
  n: Integer;
  delim: Char;
begin
  Result := 0;
  td := Tb.GetTable(Table);
  sl := TStringList.Create;
  try
    sl.LoadFromFile(Path);
    if sl.Count = 0 then Exit;
    delim := DetectDelim(sl[0]);
    SetLength(cnames, Length(td.Cols));
    r0 := 0;
    if HasHeader then
    begin
      SplitCSV(sl[0], cells, delim);
      for j := 0 to High(td.Cols) do
        if j <= High(cells) then
          cnames[j] := LowerCase(Trim(cells[j]))
        else
          cnames[j] := td.Cols[j].Name;
      r0 := 1;
    end
    else
      for j := 0 to High(td.Cols) do
        cnames[j] := td.Cols[j].Name;
    SetLength(batch, 0);
    n := 0;
    for i := r0 to sl.Count - 1 do
    begin
      if Trim(sl[i]) = '' then Continue;
      SplitCSV(sl[i], cells, delim);
      SetLength(batch, n + 1);
      SetLength(batch[n], Length(td.Cols));
      for j := 0 to High(td.Cols) do
        if j <= High(cells) then
          batch[n][j] := cells[j]
        else
          batch[n][j] := '';
      Inc(n);
      if n >= 500 then
      begin
        Tb.BatchInsert(Table, cnames, batch);
        Inc(Result, n);
        SetLength(batch, 0);
        n := 0;
      end;
    end;
    if n > 0 then
    begin
      Tb.BatchInsert(Table, cnames, batch);
      Inc(Result, n);
    end;
  finally
    sl.Free;
  end;
end;

procedure DumpToSQL(Tb: TVTableDb; const Path: string);
var
  sl: TStringList;
  tables: TStrArray;
  ti, i, j, k: Integer;
  td: TTableDef;
  pks: TStrArray;
  rows: TStrMatrix;
  s: string;
begin
  tables := Tb.TableNames;
  sl := TStringList.Create;
  try
    sl.Add('-- VDb SQL dokumu');
    sl.Add('-- Tarih: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    sl.Add('');
    for ti := 0 to High(tables) do
    begin
      td := Tb.GetTable(tables[ti]);
      sl.Add('CREATE TABLE ' + td.Name + ' (');
      for i := 0 to High(td.Cols) do
      begin
        s := '  ' + td.Cols[i].Name + ' ' + VDbCtypeName(td.Cols[i].Ctype);
        if i = td.PkIndex then s := s + ' PRIMARY KEY';
        if td.Cols[i].NotNull then s := s + ' NOT NULL';
        if td.Cols[i].Unique then s := s + ' UNIQUE';
        if td.Cols[i].HasDef then s := s + ' DEFAULT ' + SqlQuote(td.Cols[i].Def);
        if (i < High(td.Cols)) or (Length(td.Fks) > 0) then s := s + ',';
        sl.Add(s);
      end;
      for i := 0 to High(td.Fks) do
      begin
        s := '  FOREIGN KEY (' + td.Cols[td.Fks[i].Col].Name +
          ') REFERENCES ' + td.Fks[i].RefTable + '(' + td.Fks[i].RefCol + ')' +
          ' ON DELETE ' + td.Fks[i].OnDelete +
          ' ON UPDATE ' + td.Fks[i].OnUpdate;
        if i < High(td.Fks) then s := s + ',';
        sl.Add(s);
      end;
      sl.Add(');');
      for i := 0 to High(td.Idx) do
        if (td.Idx[i].Col >= 0) and (td.Idx[i].Col < Length(td.Cols)) then
          sl.Add('CREATE INDEX ' + td.Idx[i].Name + ' ON ' + td.Name +
            ' (' + td.Cols[td.Idx[i].Col].Name + ');');
      Tb.ScanRows(td.Name, pks, rows);
      if Length(pks) > 0 then
      begin
        s := 'INSERT INTO ' + td.Name + ' (';
        for j := 0 to High(td.Cols) do
        begin
          if j > 0 then s := s + ', ';
          s := s + td.Cols[j].Name;
        end;
        s := s + ') VALUES ';
        sl.Add(s);
        for i := 0 to High(pks) do
        begin
          s := '  (';
          for j := 0 to High(td.Cols) do
          begin
            if j > 0 then s := s + ', ';
            s := s + SqlQuote(rows[i][j]);
          end;
          if i < High(pks) then
            s := s + '),'
          else
            s := s + ');';
          sl.Add(s);
          if (i mod 200 = 199) and (i < High(pks)) then
          begin
            s := 'INSERT INTO ' + td.Name + ' (';
            for k := 0 to High(td.Cols) do
            begin
              if k > 0 then s := s + ', ';
              s := s + td.Cols[k].Name;
            end;
            sl.Add(Copy(s, 1, Length(s)) + ') VALUES ');
            s := '';
          end;
        end;
      end;
      sl.Add('');
    end;
    sl.SaveToFile(Path);
  finally
    sl.Free;
  end;
end;

procedure LoadSavedQueries(const Path: string; Names, Sqls: TStrings);
var
  sl: TStringList;
  i: Integer;
  nm, sq: string;
begin
  Names.Clear;
  Sqls.Clear;
  if not FileExists(Path) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(Path);
    i := 0;
    while i < sl.Count do
    begin
      if (Trim(sl[i]) <> '') and (sl[i][1] = '[') and
         (sl[i][Length(sl[i])] = ']') then
      begin
        nm := Copy(sl[i], 2, Length(sl[i]) - 2);
        Inc(i);
        sq := '';
        while (i < sl.Count) and (Trim(sl[i]) <> '---') do
        begin
          if sq <> '' then sq := sq + sLineBreak;
          sq := sq + sl[i];
          Inc(i);
        end;
        Names.Add(nm);
        Sqls.Add(sq);
      end;
      Inc(i);
    end;
  finally
    sl.Free;
  end;
end;

procedure SaveSavedQueries(const Path: string; Names, Sqls: TStrings);
var
  sl: TStringList;
  i: Integer;
begin
  sl := TStringList.Create;
  try
    for i := 0 to Names.Count - 1 do
    begin
      sl.Add('[' + Names[i] + ']');
      if i < Sqls.Count then
        sl.Add(Sqls[i]);
      sl.Add('---');
    end;
    sl.SaveToFile(Path);
  finally
    sl.Free;
  end;
end;

end.
