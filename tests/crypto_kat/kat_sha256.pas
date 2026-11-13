unit kat_sha256;
{ SHA-256 known-answer tests against VDbCryptSha256 (VDbCrypt.pas).

  Sources of the expected digests (byte-exact; see Vectors.md):
   - ""      : FIPS 180-4 message-digest example (empty message)
   - "abc"   : FIPS 180-4 Appendix B.1
   - 56-byte "abcdbcde...nopq": FIPS 180-4 Appendix B.2 (2-block message;
     exercises the padding boundary where the length field spills into
     the second block because len mod 64 = 56)
   - 56 x 0x61 ('a'): same len-mod-64=56 boundary requested by the task;
     value cross-checked against CPython hashlib (OpenSSL backend)
   - 1,000,000 x 'a': NIST long-message example; value cross-checked
     against CPython hashlib (OpenSSL backend).
     NOTE: the frequently quoted value cdc536f9b7d6... is WRONG for
     SHA-256; the verified answer is cdc76e5c9914... (see Vectors.md). }

{$mode delphi}{$H+}

interface

function RunKatSha256: Integer;

implementation

uses
  SysUtils, kat_common, VDbCrypt;

const
  PRIM = 'SHA-256 (VDbCryptSha256)';

procedure CheckVec(const AName, ASource, AH: string; const Msg: TBytes);
var
  Got, Exp: TBytes;
begin
  Exp := HexToBytes(AH);
  try
    Got := VDbCryptSha256(Msg);
    if BEq(Got, Exp) then
      KatPass(PRIM, AName, ASource)
    else
      KatFail(PRIM, AName, ASource,
        'got ' + BytesToHexL(Got) + ' want ' + LowerCase(AH));
  except
    on E: Exception do
      KatFail(PRIM, AName, ASource, 'exception: ' + E.Message);
  end;
end;

function RunKatSha256: Integer;
var
  before: Integer;
  m: TBytes;
  i: Integer;
begin
  before := KatFailed;
  KatSection('SHA-256 (VDbCrypt)');

  CheckVec('empty message', 'FIPS 180-4 (empty message digest)',
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    nil);

  CheckVec('"abc"', 'FIPS 180-4 App. B.1',
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    StrB('abc'));

  CheckVec('56-byte "abcdbcde...nopq" (2-block padding boundary)',
    'FIPS 180-4 App. B.2',
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    StrB('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'));

  CheckVec('56 x 0x61 (len mod 64 = 56 boundary)',
    'cross-checked vs CPython hashlib/OpenSSL (see Vectors.md)',
    'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
    Rep($61, 56));

  m := Rep($61, 1000000);
  CheckVec('1,000,000 x 0x61',
    'NIST long-message example; cross-checked vs CPython hashlib/OpenSSL',
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    m);
  m := nil;
  i := 0; // keep i referenced (no-op)

  Result := KatFailed - before;
end;

end.
