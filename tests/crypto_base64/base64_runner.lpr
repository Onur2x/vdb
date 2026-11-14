program base64_runner;

{ ADIM 3 kapisi: VDbBase64 (RFC 4648) dogrulama.
  Neden: DCPbase64 kaldirildi; SCRAM-SHA-256 mesajlasmasi bu kodun
  uzerinde duruyor. Vektorler RFC 4648 bolum 10'dan (+ SCRAM'a ozgu
  rastgele uzunluklar icin round-trip).

  Cikis kodu = FAIL sayisi. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbBase64;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string);
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    WriteLn('FAIL ', AName, ' - ', ADetail);
  end;
end;

function HexOf(const B: TBytes): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to Length(B) - 1 do
    Result := Result + IntToHex(B[i], 2);
end;

procedure ChkVector(const AName, APlain, AEncoded: string);
var
  b: TBytes;
  enc: AnsiString;
  dec: TBytes;
begin
  b := nil;
  if APlain <> '' then
  begin
    SetLength(b, Length(APlain));
    Move(APlain[1], b[0], Length(APlain));
  end;
  enc := VDbBase64Encode(b);
  Chk(AName + '/encode', string(enc) = AEncoded, 'alindi="' + string(enc) +
    '" beklenen="' + AEncoded + '"');
  dec := VDbBase64Decode(AnsiString(AEncoded));
  Chk(AName + '/decode', HexOf(dec) = HexOf(b), 'alindi=' + HexOf(dec) +
    ' beklenen=' + HexOf(b));
end;

procedure ChkRoundTrip(const AName: string; ALen: Integer);
var
  b, d: TBytes;
  i: Integer;
  s: AnsiString;
begin
  SetLength(b, ALen);
  for i := 0 to ALen - 1 do
    b[i] := Byte((i * 37 + 11) and $FF);
  s := VDbBase64Encode(b);
  d := VDbBase64Decode(s);
  Chk('roundtrip/' + AName, HexOf(d) = HexOf(b),
    'uzunluk=' + IntToStr(ALen) + ' enc=' + string(s));
end;

procedure ChkReject(const AName: string; const ABad: AnsiString);
var
  raised: Boolean;
begin
  raised := False;
  try
    VDbBase64Decode(ABad);
  except
    on E: EVdbBase64Error do
      raised := True;
  end;
  Chk('reject/' + AName, raised, 'gecersiz girdi kabul edildi: "' + string(ABad) + '"');
end;

begin
  GPass := 0;
  GFail := 0;
  WriteLn('VDB base64 runner - RFC 4648');

  { RFC 4648 bolum 10 test vektorleri }
  ChkVector('rfc4648/empty', '', '');
  ChkVector('rfc4648/f', 'f', 'Zg==');
  ChkVector('rfc4648/fo', 'fo', 'Zm8=');
  ChkVector('rfc4648/foo', 'foo', 'Zm9v');
  ChkVector('rfc4648/foob', 'foob', 'Zm9vYg==');
  ChkVector('rfc4648/fooba', 'fooba', 'Zm9vYmE=');
  ChkVector('rfc4648/foobar', 'foobar', 'Zm9vYmFy');

  { SCRAM'da gorulen uzunluklar: nonce 18B, salt 16B, anahtar 32B }
  ChkRoundTrip('len18', 18);
  ChkRoundTrip('len16', 16);
  ChkRoundTrip('len32', 32);
  ChkRoundTrip('len1', 1);
  ChkRoundTrip('len2', 2);
  ChkRoundTrip('len3', 3);
  ChkRoundTrip('len255', 255);

  { Bosluk/satir sonu toleransi (SCRAM metinleri sarilabilir) }
  Chk('whitespace/crlf',
    HexOf(VDbBase64Decode(AnsiString('Zm9v' + #13#10 + 'YmFy'))) = '666F6F626172',
    'satir sonu yok sayilmadi');
  Chk('whitespace/space-tab',
    HexOf(VDbBase64Decode(AnsiString('Zm9v Yg=='))) = '666F6F62',
    'bosluk yok sayilmadi');

  { Gecersiz girdiler reddedilmeli }
  ChkReject('len-not-multiple-of-4', 'Zm9vY');
  ChkReject('bad-char', 'Zm9v!mFy');
  ChkReject('padding-in-middle', 'Zm=vYmFy');

  WriteLn('');
  WriteLn(IntToStr(GPass), ' passed / ', IntToStr(GFail), ' failed');
  if GFail = 0 then
    WriteLn('RESULT: PASS')
  else
    WriteLn('RESULT: FAIL');
  Halt(GFail);
end.
