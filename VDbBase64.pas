unit VDbBase64;

{ VDbBase64 - saf Pascal Base64 (RFC 4648, standart alfabe + '=' dolgu).

  Neden: SCRAM-SHA-256 mesajlari (VDbPgWire) bugune kadar DCPcrypt'in
  DCPbase64 unit'ini kullaniyordu. DCPcrypt bagimliligi kaldiriliyor
  (ADR §3 adim 3); bu unit tek kullanim noktasini kendi kodumuzla
  karsilar. Harici DLL/bagimlilik YOK.

  Davranis:
  - Encode: standart alfabe (A-Z a-z 0-9 + /), dolgu '=' ile.
  - Decode: bosluk/CR/LF yok sayilir; gecersiz karakter veya bozuk
    dolgu -> EVdbBase64Error. Cagiran taraf hatayi yakalar.
  - Bos girdi -> bos cikti (hem encode hem decode).
}

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  EVdbBase64Error = class(Exception);

{ Byte dizisini Base64 ASCII metnine cevirir. }
function VDbBase64Encode(const B: TBytes): AnsiString;

{ Base64 ASCII metnini byte dizisine cevirir. Gecersiz girdide
  EVdbBase64Error firlatir. }
function VDbBase64Decode(const S: AnsiString): TBytes;

implementation

const
  B64_ALPHABET: array[0..63] of AnsiChar =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function VDbBase64Encode(const B: TBytes): AnsiString;
var
  i, n, o: Integer;
  b0, b1, b2: Byte;
begin
  n := Length(B);
  if n = 0 then
    Exit('');
  SetLength(Result, ((n + 2) div 3) * 4);
  i := 0;
  o := 1;
  while i < n do
  begin
    b0 := B[i];
    if i + 1 < n then b1 := B[i + 1] else b1 := 0;
    if i + 2 < n then b2 := B[i + 2] else b2 := 0;

    Result[o] := B64_ALPHABET[b0 shr 2];
    Result[o + 1] := B64_ALPHABET[((b0 and $03) shl 4) or (b1 shr 4)];
    if i + 1 < n then
      Result[o + 2] := B64_ALPHABET[((b1 and $0F) shl 2) or (b2 shr 6)]
    else
      Result[o + 2] := '=';
    if i + 2 < n then
      Result[o + 3] := B64_ALPHABET[b2 and $3F]
    else
      Result[o + 3] := '=';

    Inc(i, 3);
    Inc(o, 4);
  end;
end;

function B64Value(C: AnsiChar; out V: Integer): Boolean;
begin
  Result := True;
  case C of
    'A'..'Z': V := Ord(C) - Ord('A');
    'a'..'z': V := Ord(C) - Ord('a') + 26;
    '0'..'9': V := Ord(C) - Ord('0') + 52;
    '+': V := 62;
    '/': V := 63;
  else
    V := 0;
    Result := False;
  end;
end;

function VDbBase64Decode(const S: AnsiString): TBytes;
var
  clean: AnsiString;
  i, n, o, pad, v, acc, bits: Integer;
  c: AnsiChar;
begin
  Result := nil;
  if S = '' then
    Exit;

  { Bosluk ve satir sonlarini at (SCRAM/PEM girdileri icin tolere). }
  SetLength(clean, Length(S));
  n := 0;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c = ' ') or (c = #9) or (c = #10) or (c = #13) then
      Continue;
    Inc(n);
    clean[n] := c;
  end;
  SetLength(clean, n);
  if n = 0 then
    Exit;

  if (n mod 4) <> 0 then
    raise EVdbBase64Error.Create('Base64 uzunlugu 4''un kati degil');

  pad := 0;
  if clean[n] = '=' then Inc(pad);
  if (n >= 2) and (clean[n - 1] = '=') then Inc(pad);
  if pad > 2 then
    raise EVdbBase64Error.Create('Base64 dolgu hatasi');

  SetLength(Result, (n div 4) * 3 - pad);
  o := 0;
  acc := 0;
  bits := 0;

  for i := 1 to n do
  begin
    c := clean[i];
    if c = '=' then
    begin
      { Dolgu yalniz sonda olabilir; kalan bitler sifir olmali. }
      if i <= n - pad then
        raise EVdbBase64Error.Create('Base64 dolgu ortada olamaz');
      Continue;
    end;
    if not B64Value(c, v) then
      raise EVdbBase64Error.Create('Base64 gecersiz karakter: ' + Char(c));
    acc := (acc shl 6) or v;
    Inc(bits, 6);
    if bits >= 8 then
    begin
      Dec(bits, 8);
      if o < Length(Result) then
        Result[o] := Byte((acc shr bits) and $FF);
      Inc(o);
      acc := acc and ((1 shl bits) - 1);
    end;
  end;

  if o <> Length(Result) then
    SetLength(Result, o);
end;

end.
