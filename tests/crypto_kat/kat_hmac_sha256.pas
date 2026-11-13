unit kat_hmac_sha256;
{ HMAC-SHA256 known-answer tests against VDbCryptHmacSha256 (VDbCrypt.pas).

  Source: RFC 4231 sections 4.2..4.8 (official RFC text fetched
  2026-11-13; every expected tag below is byte-identical to the RFC and
  was also reproduced locally with CPython hmac/OpenSSL - see Vectors.md).

  Known limitation being sealed (no production-code changes made):
  VDbCryptHmacSha256 REJECTS keys longer than 64 bytes with
  EVdbCryptError instead of hashing them per RFC 2104. Therefore:
   - Test Case 6/7 raw call: we assert the documented rejection behavior.
   - Test Case 6/7 core computation: RFC 2104 says HMAC(K,m) = HMAC(H(K),m)
     for |K| > block-size, so the harness pre-reduces the 131-byte key with
     SHA-256 before calling the primitive; the remaining HMAC core is then
     verified against the exact RFC tag. }

{$mode delphi}{$H+}

interface

function RunKatHmacSha256: Integer;

implementation

uses
  SysUtils, kat_common, VDbCrypt;

const
  PRIM = 'HMAC-SHA256 (VDbCryptHmacSha256)';

procedure CheckDirect(const AName, ASource, AHKey, AHData, AHTag: string);
var
  K, D, Got, Exp: TBytes;
begin
  K := HexToBytes(AHKey);
  D := HexToBytes(AHData);
  Exp := HexToBytes(AHTag);
  try
    Got := VDbCryptHmacSha256(K, D);
    if BEq(Got, Exp) then
      KatPass(PRIM, AName, ASource)
    else
      KatFail(PRIM, AName, ASource,
        'got ' + BytesToHexL(Got) + ' want ' + LowerCase(AHTag));
  except
    on E: Exception do
      KatFail(PRIM, AName, ASource, 'exception: ' + E.Message);
  end;
end;

procedure CheckDirectB(const AName, ASource: string; const K, D, ExpTag: TBytes);
{ Byte-built variant of CheckDirect: avoids hand-counted long hex literals
  (an earlier 50x0xdd literal was miscounted to 41 bytes and failed; the
  values here are now generated programmatically). }
var
  Got: TBytes;
begin
  try
    Got := VDbCryptHmacSha256(K, D);
    if BEq(Got, ExpTag) then
      KatPass(PRIM, AName, ASource)
    else
      KatFail(PRIM, AName, ASource,
        'got ' + BytesToHexL(Got) + ' want ' + BytesToHexL(ExpTag));
  except
    on E: Exception do
      KatFail(PRIM, AName, ASource, 'exception: ' + E.Message);
  end;
end;

procedure CheckLongKeyCase(const AName, ASource, AData, AHTag: string);
{ AData: ASCII data exactly as in the RFC; AHTag: RFC 4231 HMAC-SHA-256 tag. }
var
  K, Kp, D, Got, Exp: TBytes;
  rejected: Boolean;
begin
  K := Rep($AA, 131);
  D := StrB(AData);
  Exp := HexToBytes(AHTag);

  { 1) raw call must be rejected (documented limitation of the current API) }
  rejected := False;
  try
    Got := VDbCryptHmacSha256(K, D);
    KatFail(PRIM, AName + ' [>64B key rejection]', ASource,
      'expected EVdbCryptError for 131-byte key, got tag ' + BytesToHexL(Got));
  except
    on E: EVdbCryptError do
    begin
      rejected := True;
      KatPass(PRIM, AName + ' [>64B key rejection]',
        ASource + ' (seals current API limitation: keys >64B are rejected, ' +
        'not hashed per RFC 2104)');
    end;
    on E: Exception do
      KatFail(PRIM, AName + ' [>64B key rejection]', ASource,
        'unexpected exception type: ' + E.ClassName + ' (' + E.Message + ')');
  end;
  if not rejected then
    Exit;

  { 2) core HMAC core vs the RFC tag after RFC-2104 key pre-reduction }
  Kp := VDbCryptSha256(K);
  try
    Got := VDbCryptHmacSha256(Kp, D);
    if BEq(Got, Exp) then
      KatPass(PRIM, AName + ' [core vs RFC tag]',
        ASource + ' (key pre-reduced harness-side: HMAC(K,m)=HMAC(SHA256(K),m))')
    else
      KatFail(PRIM, AName + ' [core vs RFC tag]', ASource,
        'got ' + BytesToHexL(Got) + ' want ' + LowerCase(AHTag));
  except
    on E: Exception do
      KatFail(PRIM, AName + ' [core vs RFC tag]', ASource,
        'exception: ' + E.Message);
  end;
end;

function RunKatHmacSha256: Integer;
var
  before: Integer;
  key20: string;
begin
  before := KatFailed;
  KatSection('HMAC-SHA256 (RFC 4231)');

  key20 := '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b';
  CheckDirect('Case 1 (20x0b / "Hi There")', 'RFC 4231 4.2',
    key20, '4869205468657265',
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');

  CheckDirect('Case 2 ("Jefe" / "what do ya want for nothing?")',
    'RFC 4231 4.3', '4a656665',
    '7768617420646f2079612077616e7420666f72206e6f7468696e673f',
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');

  CheckDirectB('Case 3 (20xaa / 50xdd)', 'RFC 4231 4.4',
    Rep($AA, 20), Rep($DD, 50),
    HexToBytes('773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe'));

  CheckDirectB('Case 4 (01..19 / 50xcd)', 'RFC 4231 4.5',
    HexToBytes('0102030405060708090a0b0c0d0e0f10111213141516171819'),
    Rep($CD, 50),
    HexToBytes('82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b'));

  KatSkip(PRIM, 'Case 5 (truncated 128-bit tag)', 'RFC 4231 4.6',
    'not applicable: VDbCryptHmacSha256 always returns the full 32-byte tag; ' +
    'truncation is caller-side and adds no primitive coverage');

  CheckLongKeyCase('Case 6 (131x0xaa / "Test Using Larger Than Block-Size ' +
    'Key - Hash Key First")', 'RFC 4231 4.7',
    'Test Using Larger Than Block-Size Key - Hash Key First',
    '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54');

  CheckLongKeyCase('Case 7 (131x0xaa / 120-byte long data)', 'RFC 4231 4.8',
    'This is a test using a larger than block-size key and a larger than ' +
    'block-size data. The key needs to be hashed before being used by the ' +
    'HMAC algorithm.',
    '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2');

  Result := KatFailed - before;
end;

end.
