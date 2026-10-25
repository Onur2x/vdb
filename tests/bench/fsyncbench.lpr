program fsyncbench;

{ v3.1: autocommit hedefinin (<=0,55 ms) I/O tabanini olcmek icin kucuk
  arac. Her turda 4 KB'lik bir cerceve dosyaya eklenip fsync edilir;
  bu, bir autocommit isleminin WAL maliyetinin ALT siniridir.

  Kullanim: fsyncbench [tekrar] [bayt] [--nosync] }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, VDbSync;

var
  gQpf: Int64;

function NowUs: Int64;
{$IFDEF MSWINDOWS}
var
  c: Int64;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then
    Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then
    Result := (c * 1000) div gQpf
  else
    Result := c * 1000;
  {$ELSE}
  Result := GetTickCount64 * 1000;
  {$ENDIF}
end;

var
  N, PayLen, i, t: Integer;
  sync: Boolean;
  fn: string;
  fs: TFileStream;
  buf: TBytes;
  us: array[0..2] of Int64;
  t0: Int64;
  med: Int64;
begin
  N := 20000;
  PayLen := 4096;
  sync := True;
  t := 0;
  for i := 1 to ParamCount do
  begin
    if LowerCase(ParamStr(i)) = '--nosync' then sync := False
    else
    begin
      Inc(t);
      if t = 1 then N := StrToIntDef(ParamStr(i), N)
      else if t = 2 then PayLen := StrToIntDef(ParamStr(i), PayLen);
    end;
  end;

  fn := IncludeTrailingPathDelimiter(GetTempDir) + 'vdb_fsyncbench.dat';
  SetLength(buf, PayLen);
  FillChar(buf[0], PayLen, $5A);

  for t := 0 to 2 do
  begin
    if FileExists(fn) then DeleteFile(fn);
    fs := TFileStream.Create(fn, fmCreate);
    try
      t0 := NowUs;
      for i := 1 to N do
      begin
        fs.Position := fs.Size;
        fs.WriteBuffer(buf[0], PayLen);
        if sync then VDbFlushStream(fs);
      end;
      us[t] := NowUs - t0;
    finally
      fs.Free;
    end;
    WriteLn(Format('tur %d: %d islem  toplam %.1f ms  %.3f ms/islem',
      [t + 1, N, us[t] / 1000.0, us[t] / 1000.0 / N]));
  end;
  med := us[0];
  if us[1] < med then med := us[1];
  if us[2] < med then med := us[2];
  WriteLn;
  WriteLn(Format('FSYNC TABANI (%d B/islem): %.3f ms/islem',
    [PayLen, med / 1000.0 / N]));
  if FileExists(fn) then DeleteFile(fn);
end.
