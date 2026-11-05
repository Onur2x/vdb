program strbench;
{ P-105 arastirma: 400k SetString + serbest birakma taban maliyeti.
  B metriigindeki (joindiag) 400k hucre uretiminin ASAGI SINIRINI olcer.
  Kullanim: strbench [tekrar=100000] }
{$mode delphi}{$H+}
uses
  Windows, SysUtils;

var
  gQpf: Int64;
  N, r, k: Integer;
  rows: array of array of string;
  t0, t1, best: Int64;
  src: array[0..31] of AnsiChar;

function NowUs: Int64;
var
  c: Int64;
begin
  if gQpf = 0 then
    if not QueryPerformanceFrequency(gQpf) then gQpf := 1000;
  QueryPerformanceCounter(c);
  if gQpf >= 1000000 then
    Result := c div (gQpf div 1000000)
  else if gQpf >= 1000 then
    Result := (c * 1000) div gQpf
  else
    Result := c * 1000;
end;

begin
  N := 100000;
  if ParamCount >= 1 then N := StrToIntDef(ParamStr(1), 100000);
  SetLength(rows, N, 4);
  for k := 0 to 31 do src[k] := AnsiChar(Ord('a') + (k and 15));

  // 1) 4x SetString (kucuk string) — B metrigindeki hucre uretimi
  //    NOT: her tekrardan once hucreler bosaltildi (taze tahsis olcumu;
  //    aksi halde SetLength mevcut buffer'i yeniden kullanir ve yaniltir).
  best := High(Int64);
  for r := 1 to 7 do
  begin
    for k := 0 to N - 1 do
    begin
      rows[k][0] := ''; rows[k][1] := ''; rows[k][2] := ''; rows[k][3] := '';
    end;
    t0 := NowUs;
    for k := 0 to N - 1 do
    begin
      SetString(rows[k][0], @src[0], 5);
      SetString(rows[k][1], @src[4], 6);
      SetString(rows[k][2], @src[8], 3);
      SetString(rows[k][3], @src[12], 8);
    end;
    t1 := NowUs;
    if t1 - t0 < best then best := t1 - t0;
  end;
  WriteLn(Format('4x SetString x %d satir : %8.1f ms  (%.1f ns/hucre)',
    [N, best / 1000, best * 1000.0 / (N * 4)]));

  // 2) yalnizca serbest birakma (SetLength(0) tum diziyi sifirlar)
  best := High(Int64);
  for r := 1 to 7 do
  begin
    // once doldur
    for k := 0 to N - 1 do
    begin
      SetString(rows[k][0], @src[0], 5);
      SetString(rows[k][1], @src[4], 6);
      SetString(rows[k][2], @src[8], 3);
      SetString(rows[k][3], @src[12], 8);
    end;
    t0 := NowUs;
    for k := 0 to N - 1 do
    begin
      rows[k][0] := '';
      rows[k][1] := '';
      rows[k][2] := '';
      rows[k][3] := '';
    end;
    t1 := NowUs;
    if t1 - t0 < best then best := t1 - t0;
  end;
  WriteLn(Format('4x serbest birakma       : %8.1f ms  (%.1f ns/hucre)',
    [best / 1000, best * 1000.0 / (N * 4)]));

  // 3) SetLength+Move (P-103 tarzi, on-tahsis YOK)
  //    taze tahsis: her tekrardan once hucreler bosaltildi
  best := High(Int64);
  for r := 1 to 7 do
  begin
    for k := 0 to N - 1 do
    begin
      rows[k][0] := ''; rows[k][1] := ''; rows[k][2] := ''; rows[k][3] := '';
    end;
    t0 := NowUs;
    for k := 0 to N - 1 do
    begin
      SetLength(rows[k][0], 5); Move(src[0], rows[k][0][1], 5);
      SetLength(rows[k][1], 6); Move(src[4], rows[k][1][1], 6);
      SetLength(rows[k][2], 3); Move(src[8], rows[k][2][1], 3);
      SetLength(rows[k][3], 8); Move(src[12], rows[k][3][1], 8);
    end;
    t1 := NowUs;
    if t1 - t0 < best then best := t1 - t0;
  end;
  WriteLn(Format('4x SetLength+Move        : %8.1f ms  (%.1f ns/hucre)',
    [best / 1000, best * 1000.0 / (N * 4)]));

  // 4) refcount atamasi (paylasimli kopya)
  best := High(Int64);
  for r := 1 to 7 do
  begin
    for k := 0 to N - 1 do
    begin
      SetString(rows[k][0], @src[0], 5);
      SetString(rows[k][1], @src[4], 6);
    end;
    t0 := NowUs;
    for k := 0 to N - 1 do
    begin
      rows[k][2] := rows[k][0];
      rows[k][3] := rows[k][1];
    end;
    t1 := NowUs;
    if t1 - t0 < best then best := t1 - t0;
    rows[k-1][2] := ''; rows[k-1][3] := '';
  end;
  WriteLn(Format('2x refcount atamasi      : %8.1f ms  (%.1f ns/hucre)',
    [best / 1000, best * 1000.0 / (N * 2)]));

  WriteLn('TEMIZ');
end.