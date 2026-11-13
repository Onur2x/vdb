program vdbcli;

{ P-179: vdb komut satiri kabugu (SQLite'tan gecis icin gorunur arayuz).

  Kullanim:
    vdbcli <veritabani> [secenekler]
    vdbcli <veritabani> -c "SQL; SQL"
    vdbcli <veritabani> betik.sql

  Secenekler:
    -c, --command SQL    verilen SQL/dot komutlarini calistirip cik
    --mode table|csv|box cikti bicimi (varsayilan table)
    -q, --quiet          etkilesim ipucunu yazma

  Etkilesimde satirlar ';' ile bitene kadar biriktirilir; '.komut' tek
  satirda calisir. '.quit' / '.exit' veya EOF ile cikilir.
}

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbConsole;

var
  dbPath, cmd, modeS, buf, line: string;
  cli: TVdbCli;
  i: Integer;
  quiet, quit: Boolean;
  mode: TVdbCliMode;
  script, one: TStringList;
begin
  if ParamCount < 1 then
  begin
    WriteLn('kullanim: vdbcli <veritabani> [-c "SQL"] [betik.sql]');
    WriteLn('         [--mode table|csv|box] [-q]');
    Halt(2);
  end;
  dbPath := ParamStr(1);
  cmd := '';
  modeS := '';
  script := nil;
  quiet := False;
  i := 2;
  while i <= ParamCount do
  begin
    line := ParamStr(i);
    if (line = '-c') or (line = '--command') then
    begin
      if i = ParamCount then
      begin
        WriteLn('-c icin SQL gerekli');
        Halt(2);
      end;
      Inc(i);
      cmd := ParamStr(i);
    end
    else if line = '--mode' then
    begin
      if i = ParamCount then
      begin
        WriteLn('--mode icin deger gerekli');
        Halt(2);
      end;
      Inc(i);
      modeS := ParamStr(i);
    end
    else if (line = '-q') or (line = '--quiet') then
      quiet := True
    else if (line <> '') and (line[1] <> '-') then
    begin
      if not FileExists(line) then
      begin
        WriteLn('betik bulunamadi: ', line);
        Halt(2);
      end;
      script := TStringList.Create;
      script.LoadFromFile(line);
    end
    else
    begin
      WriteLn('bilinmeyen secenek: ', line);
      Halt(2);
    end;
    Inc(i);
  end;

  cli := nil;
  try
    cli := TVdbCli.Create(dbPath);
    if modeS <> '' then
    begin
      if not VdbCliModeFromName(modeS, mode) then
      begin
        WriteLn('gecersiz mod: ', modeS);
        Halt(2);
      end;
      cli.Mode := mode;
    end;
    if cmd <> '' then
    begin
      one := TStringList.Create;
      try
        one.Add(cmd);
        Write(cli.RunScript(one));
      finally
        one.Free;
      end;
      Exit;
    end;
    if script <> nil then
    begin
      Write(cli.RunScript(script));
      Exit;
    end;

    if not quiet then
    begin
      WriteLn('VDB kabuk - .help ile komutlar, .quit ile cikis');
      WriteLn('veritabani: ', cli.DbPath);
    end;
    buf := '';
    while True do
    begin
      if not quiet then
      begin
        if buf = '' then Write('vdb> ') else Write('...> ');
        Flush(Output);
      end;
      if EOF then Break;
      ReadLn(line);
      if buf = '' then
      begin
        buf := line;
        if (Trim(buf) <> '') and (Trim(buf)[1] = '.') then
        begin
          Write(cli.RunLine(buf, quit));
          buf := '';
          if quit then Break;
          Continue;
        end;
      end
      else
        buf := buf + #10 + line;
      if Trim(buf) <> '' then
      begin
        line := Trim(buf);
        if (line <> '') and (line[Length(line)] = ';') then
        begin
          Write(cli.RunLine(buf, quit));
          buf := '';
          if quit then Break;
        end;
      end;
    end;
    if Trim(buf) <> '' then
      Write(cli.RunLine(buf, quit));
  finally
    cli.Free;
    script.Free;
  end;
end.
