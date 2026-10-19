program gcmchk;
{$mode delphi}{$H+}
uses SysUtils, VDbCrypt;

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

var
  key, nonce, plain, aad, ct, tag, back: TBytes;
  ok: Boolean;
  fails: Integer;

procedure Check(const Name, Got, Want: string);
begin
  if LowerCase(Got) = LowerCase(Want) then
    Writeln('OK   ', Name)
  else
  begin
    Writeln('FAIL ', Name, ' got=', Got, ' want=', Want);
    Inc(fails);
  end;
end;

begin
  fails := 0;
  key := HexBytes('0000000000000000000000000000000000000000000000000000000000000000');
  nonce := HexBytes('000000000000000000000000');
  plain := nil;
  aad := nil;
  ok := VDbCryptGcmSeal(key, nonce, plain, aad, ct, tag);
  if not ok then begin Writeln('FAIL seal1'); Inc(fails); end
  else
  begin
    Check('gcm256 empty ct', BytesHex(ct), '');
    Check('gcm256 empty tag', BytesHex(tag), '530f8afbc74536b9a963b4f1c4cb738b');
  end;

  plain := HexBytes('00000000000000000000000000000000');
  ok := VDbCryptGcmSeal(key, nonce, plain, aad, ct, tag);
  if not ok then begin Writeln('FAIL seal2'); Inc(fails); end
  else
  begin
    Check('gcm256 16B ct', BytesHex(ct), 'cea7403d4d606b6e074ec5d3baf39d18');
    Check('gcm256 16B tag', BytesHex(tag), 'd0d1c8a799996bf0265b98b5d48ab919');
  end;

  key := HexBytes('feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308');
  nonce := HexBytes('cafebabefacedbaddecaf888');
  plain := HexBytes('d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255');
  ok := VDbCryptGcmSeal(key, nonce, plain, aad, ct, tag);
  if not ok then begin Writeln('FAIL seal3'); Inc(fails); end
  else
  begin
    Check('gcm256 64B ct', BytesHex(ct),
      '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa' +
      '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad');
    Check('gcm256 64B tag', BytesHex(tag), 'b094dac5d93471bdec1a502270e3cc6c');
  end;

  if not VDbCryptGcmOpen(key, nonce, ct, tag, aad, back) then
  begin Writeln('FAIL open3'); Inc(fails); end
  else
    Check('gcm256 roundtrip', BytesHex(back), BytesHex(plain));

  tag[0] := tag[0] xor $01;
  if VDbCryptGcmOpen(key, nonce, ct, tag, aad, back) then
  begin Writeln('FAIL tamper accepted'); Inc(fails); end
  else
    Writeln('OK   tamper rejected');

  { Zarfli API + VDbCryptEncrypt/Decrypt }
  key := HexBytes('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  plain := VDbCryptStrToBytes('merhaba VDB AEAD');
  if not VDbCryptEncrypt(key, plain, ct) then
  begin Writeln('FAIL envelope seal'); Inc(fails); end
  else
  begin
    Check('envelope magic', Copy(BytesHex(ct), 1, 16), '5644424145414431');
    if not VDbCryptDecrypt(key, ct, back) then
    begin Writeln('FAIL envelope open'); Inc(fails); end
    else
      Check('envelope roundtrip', BytesHex(back), BytesHex(plain));
    ct[High(ct)] := ct[High(ct)] xor $80;
    try
      VDbCryptDecrypt(key, ct, back);
      Writeln('FAIL envelope tamper accepted');
      Inc(fails);
    except
      on E: EVdbCryptError do
        Writeln('OK   envelope tamper rejected');
    end;
  end;

  ct := nil;
  if not VDbCryptEncryptLegacy(key, plain, ct) then
  begin Writeln('FAIL legacy seal'); Inc(fails); end
  else
  begin
    if VDbCryptIsAead(ct) then
    begin Writeln('FAIL legacy marked AEAD'); Inc(fails); end
    else
      Writeln('OK   legacy envelope');
    if not VDbCryptDecrypt(key, ct, back) then
    begin Writeln('FAIL legacy open'); Inc(fails); end
    else
      Check('legacy roundtrip', BytesHex(back), BytesHex(plain));
  end;

  Writeln('FAILS=', fails);
  if fails <> 0 then Halt(1);
end.
