program core_smoke;

{ ADIM 4 on-kapisi: VDbCryptoCore'un bilinen-vektor dogrulamasi.
  VDbCrypt'e dokunmadan once AES-256 / SHA-256 / HMAC / CTR'nin
  dogru oldugunu kanitlar. Referanslar:
    * AES-256 ECB  -> FIPS-197 Ek C.3
    * AES-256 CTR  -> NIST SP 800-38A F.5.5
    * SHA-256      -> FIPS 180-4 ornekleri
    * HMAC-SHA256  -> RFC 4231 test case 1 ve 2
  Cikis kodu = FAIL sayisi. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, VDbCryptoCore;

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
  Result := LowerCase(Result);
end;

function HexBytes(const S: string): TBytes;
var
  i, n: Integer;
begin
  n := Length(S) div 2;
  SetLength(Result, n);
  for i := 0 to n - 1 do
    Result[i] := StrToInt('$' + Copy(S, i * 2 + 1, 2));
end;

function AsciiBytes(const S: string): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    Result[i - 1] := Byte(S[i]);
end;

function RepeatByte(B: Byte; N: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
    Result[i] := B;
end;

procedure TestAesEcb;
var
  key, pt, outb: TBytes;
  ctx: TVdbAes256Ctx;
  buf: array[0..15] of Byte;
  i: Integer;
begin
  key := HexBytes('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  pt := HexBytes('00112233445566778899aabbccddeeff');
  VDbAes256ExpandKey(key, ctx);
  VDbAes256EncryptBlock(ctx, @pt[0], @buf[0]);
  SetLength(outb, 16);
  for i := 0 to 15 do
    outb[i] := buf[i];
  Chk('aes256/ecb-fips197-c3',
    HexOf(outb) = '8ea2b7ca516745bfeafc49904b496089',
    'alindi=' + HexOf(outb));
end;

procedure TestAesCtr;
var
  key, iv, pt, ct, outb: TBytes;
  st: TVdbAes256Ctr;
begin
  key := HexBytes('603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4');
  iv := HexBytes('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
  pt := HexBytes('6bc1bee22e409f96e93d7e117393172a');
  ct := HexBytes('601ec313775789a5b7a7f504bbf3d228');
  SetLength(outb, 16);
  VDbAes256CtrInit(key, @iv[0], st);
  VDbAes256CtrCrypt(st, @pt[0], @outb[0], 16);
  Chk('aes256/ctr-sp800-38a-f55', HexOf(outb) = HexOf(ct),
    'alindi=' + HexOf(outb));

  { Ayni akisla geri cozulmeli. }
  VDbAes256CtrInit(key, @iv[0], st);
  VDbAes256CtrCrypt(st, @outb[0], @outb[0], 16);
  Chk('aes256/ctr-roundtrip', HexOf(outb) = HexOf(pt),
    'alindi=' + HexOf(outb));
end;

procedure TestSha;
var
  d: TBytes;
begin
  Chk('sha256/empty',
    HexOf(VDbSha256(nil)) =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'alindi=' + HexOf(VDbSha256(nil)));

  d := AsciiBytes('abc');
  Chk('sha256/abc',
    HexOf(VDbSha256(d)) =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'alindi=' + HexOf(VDbSha256(d)));

  d := AsciiBytes('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq');
  Chk('sha256/two-block',
    HexOf(VDbSha256(d)) =
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    'alindi=' + HexOf(VDbSha256(d)));
end;

procedure TestHmac;
var
  k, d: TBytes;
begin
  { RFC 4231 test case 1 }
  k := RepeatByte($0b, 20);
  d := AsciiBytes('Hi There');
  Chk('hmac/rfc4231-1',
    HexOf(VDbHmacSha256(k, d)) =
      'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
    'alindi=' + HexOf(VDbHmacSha256(k, d)));

  { RFC 4231 test case 2: anahtar "Jefe" }
  k := AsciiBytes('Jefe');
  d := AsciiBytes('what do ya want for nothing?');
  Chk('hmac/rfc4231-2',
    HexOf(VDbHmacSha256(k, d)) =
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    'alindi=' + HexOf(VDbHmacSha256(k, d)));

  { 64 baytlik anahtar sinirda calismali; 65 bayt reddedilmeli. }
  k := RepeatByte($aa, 64);
  d := AsciiBytes('sinir');
  Chk('hmac/key64-ok', Length(VDbHmacSha256(k, d)) = 32, 'uzunluk yanlis');

  k := RepeatByte($aa, 65);
  try
    VDbHmacSha256(k, d);
    Chk('hmac/key65-reject', False, 'hata firlatilmadi');
  except
    on E: EVdbCryptoCoreError do
      Chk('hmac/key65-reject', True, '');
  end;
end;

begin
  GPass := 0;
  GFail := 0;
  WriteLn('VDB crypto core smoke - known vectors');
  TestAesEcb;
  TestAesCtr;
  TestSha;
  TestHmac;
  WriteLn('');
  WriteLn(IntToStr(GPass), ' passed / ', IntToStr(GFail), ' failed');
  if GFail = 0 then
    WriteLn('RESULT: PASS')
  else
    WriteLn('RESULT: FAIL');
  Halt(GFail);
end.
