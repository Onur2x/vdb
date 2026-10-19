program argonchk;
{$mode delphi}{$H+}
uses SysUtils, VDbKdf;

function BytesOf(B: Byte; N: Integer): TBytes;
begin
  SetLength(Result, N);
  if N > 0 then FillChar(Result[0], N, B);
end;

function HexBytes(const S: string): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(S) div 2);
  for i := 1 to Length(Result) do
    Result[i - 1] := StrToInt('$' + Copy(S, (i - 1) * 2 + 1, 2));
end;

function BytesHex(const B: TBytes): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(B) do
    Result := Result + IntToHex(B[i], 2);
end;

procedure Check(const Name, Got, Want: string);
begin
  if LowerCase(Got) = LowerCase(Want) then
    Writeln('OK   ', Name)
  else
    Writeln('FAIL ', Name, ' got=', Got, ' want=', Want);
end;

var
  pwd, salt, secret, ad, h: TBytes;
  ok: Boolean;
begin
  Check('blake2b-512 abc', BytesHex(VDbBlake2b(HexBytes('616263'), 64)),
    'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1' +
    '7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923');
  Check('blake2b-256 empty', BytesHex(VDbBlake2b(nil, 32)),
    '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8');

  pwd := BytesOf($01, 32);
  salt := BytesOf($02, 16);
  secret := BytesOf($03, 8);
  ad := BytesOf($04, 12);
  ok := VDbArgon2id(pwd, salt, secret, ad, 3, 32, 4, 32, h);
  if not ok then
  begin
    Writeln('FAIL argon2id returned false');
    Halt(1);
  end;
  Check('argon2id RFC9106', BytesHex(h),
    '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659');
end.
