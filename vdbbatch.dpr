program vdbbatch;
{ M8: SQLite diferansiyel testi icin toplu SQL calistirici.

  Kullanim: vdbbatch.exe <veritabani_dizini> <sql_dosyasi>
  SQL dosyasinda her satir bir komuttur. Her komut icin cikti blogu:

    R                 -> sonuc kumesi basliyor
    <kolonlar TAB ile>
    .                 -> blok sonu

  Hata durumunda:
    E
    <hata mesaji>
    .

  Bos satirlar atlanir. Cikti, Python'daki sqlite3 sonuclariyla
  karsilastirilmak uzere tasarlandi. }
{$mode delphi}{$H+}
uses
  SysUtils, Classes, VDbCore, VDbTable, VDbSql;

var
  kv: TVDb;
  tb: TVTableDb;
  sq: TVSql;
  lines: TStringList;
  stmt, row: string;
  res: TSqlResult;
  i, j, k: Integer;

begin
  if ParamCount < 2 then
  begin
    Writeln(ErrOutput, 'Kullanim: vdbbatch.exe <db_dizini> <sql_dosyasi>');
    Halt(2);
  end;

  lines := TStringList.Create;
  kv := TVDb.Create;
  tb := TVTableDb.Create(kv);
  sq := TVSql.Create(tb);
  try
    lines.LoadFromFile(ParamStr(2));
    kv.Open(ParamStr(1));
    tb.Open(ParamStr(1));

    for i := 0 to lines.Count - 1 do
    begin
      stmt := Trim(lines[i]);
      if stmt = '' then Continue;
      try
        res := sq.Exec(stmt);
        Writeln('R');
        for j := 0 to High(res.Rows) do
        begin
          row := '';
          for k := 0 to High(res.Rows[j]) do
          begin
            if k > 0 then row := row + #9;
            row := row + res.Rows[j][k];
          end;
          Writeln(row);
        end;
        Writeln('.');
      except
        on E: Exception do
        begin
          Writeln('E');
          Writeln(StringReplace(E.Message, sLineBreak, ' ', [rfReplaceAll]));
          Writeln('.');
        end;
      end;
    end;
  finally
    sq.Free;
    tb.Free;
    kv.Free;
    lines.Free;
  end;
end.
