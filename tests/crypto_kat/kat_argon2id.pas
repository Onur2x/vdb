unit kat_argon2id;
{ Argon2id known-answer tests against VDbArgon2id (VDbKdf.pas).

  Source: RFC 9106 section 5.3 "Argon2id Test Vectors" (the RFC text was
  fetched 2026-11-13; the expected tag below is byte-identical to the RFC).

  IMPORTANT correction: the task brief cited "RFC 9128 A.4" for the Argon2
  vector. RFC 9128 is a PIM/YANG model document and contains NO Argon2
  vectors; the correct document is RFC 9106 section 5.3. See Vectors.md.

  The H0 pre-hash inputs below are exactly the RFC's:
    Password = 32 x 0x01, Salt = 16 x 0x02, Secret = 8 x 0x03, AD = 12 x 0x04
    t = 3, m = 32 KiB, p = 4, tag length = 32.

  Also sealed here: determinism, parameter sensitivity, empty Secret/AD
  path, the Blake2bLong (>64-byte output) path, and the documented
  parameter-rejection guards (VDbArgon2id returns False - it does not
  raise - for p<1, t<1, HashLen<4 or MemoryKiB<8*p). }

{$mode delphi}{$H+}

interface

function RunKatArgon2id: Integer;

implementation

uses
  SysUtils, kat_common, VDbKdf;

const
  PRIM = 'Argon2id (VDbArgon2id)';
  SRC_RFC = 'RFC 9106 sec. 5.3 (Argon2id test vector)';
  EXPECTED_RFC =
    '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659';

function RfcVec(out Hash: TBytes): Boolean;
begin
  Result := VDbArgon2id(Rep($01, 32), Rep($02, 16), Rep($03, 8), Rep($04, 12),
    3, 32, 4, 32, Hash);
end;

function RunKatArgon2id: Integer;
var
  before: Integer;
  h1, h2: TBytes;
  ok1, ok2: Boolean;
  exp: TBytes;
  allSame: Boolean;
begin
  before := KatFailed;
  KatSection('Argon2id (RFC 9106)');

  { --- 1) the RFC 9106 5.3 vector itself --- }
  ok1 := False;
  try
    ok1 := RfcVec(h1);
    exp := HexToBytes(EXPECTED_RFC);
    if not ok1 then
      KatFail(PRIM, 'RFC 9106 5.3 vector', SRC_RFC,
        'VDbArgon2id returned False for valid RFC parameters')
    else if BEq(h1, exp) then
      KatPass(PRIM, 'RFC 9106 5.3 vector (t=3,m=32,p=4,taglen=32)', SRC_RFC)
    else
      KatFail(PRIM, 'RFC 9106 5.3 vector', SRC_RFC,
        'got ' + BytesToHexL(h1) + ' want ' + EXPECTED_RFC);
  except
    on E: Exception do
      KatFail(PRIM, 'RFC 9106 5.3 vector', SRC_RFC, 'exception: ' + E.Message);
  end;

  { --- 2) determinism: same inputs -> same tag --- }
  if ok1 then
  begin
    ok2 := RfcVec(h2);
    if ok2 and BEq(h1, h2) then
      KatPass(PRIM, 'determinism (repeat call, identical tag)', SRC_RFC)
    else
      KatFail(PRIM, 'determinism', SRC_RFC,
        'second call returned ' + BoolToStr(ok2, True) + ' / different tag');
    h2 := nil;
  end;

  { --- 3) parameter sensitivity: t=2 must change the tag --- }
  if ok1 then
  begin
    ok2 := VDbArgon2id(Rep($01, 32), Rep($02, 16), Rep($03, 8), Rep($04, 12),
      2, 32, 4, 32, h2);
    if ok2 and (not BEq(h1, h2)) then
      KatPass(PRIM, 'time-cost sensitivity (t=2 differs from t=3)',
        'derived from ' + SRC_RFC)
    else
      KatFail(PRIM, 'time-cost sensitivity', SRC_RFC,
        't=2 returned ok=' + BoolToStr(ok2, True) + ' with same-or-failed tag');
    h2 := nil;
  end;

  { --- 4) parameter sensitivity: p=2 must change the tag --- }
  if ok1 then
  begin
    ok2 := VDbArgon2id(Rep($01, 32), Rep($02, 16), Rep($03, 8), Rep($04, 12),
      3, 32, 2, 32, h2);
    if ok2 and (not BEq(h1, h2)) then
      KatPass(PRIM, 'lane-count sensitivity (p=2 differs from p=4)',
        'derived from ' + SRC_RFC)
    else
      KatFail(PRIM, 'lane-count sensitivity', SRC_RFC,
        'p=2 returned ok=' + BoolToStr(ok2, True) + ' with same-or-failed tag');
    h2 := nil;
  end;

  { --- 5) empty Secret/AD path (what .key files use) runs + is deterministic --- }
  ok1 := VDbArgon2id(StrB('pass'), Rep($02, 16), nil, nil, 2, 64, 1, 32, h1);
  ok2 := VDbArgon2id(StrB('pass'), Rep($02, 16), nil, nil, 2, 64, 1, 32, h2);
  if ok1 and ok2 and BEq(h1, h2) and (Length(h1) = 32) then
    KatPass(PRIM, 'empty Secret/AD path (runs, deterministic, 32B)',
      'self-consistency; production .key v2 path (BASELINE.md sec. 3)')
  else
    KatFail(PRIM, 'empty Secret/AD path', SRC_RFC,
      'ok1=' + BoolToStr(ok1, True) + ' ok2=' + BoolToStr(ok2, True));
  h1 := nil;
  h2 := nil;

  { --- 6) Blake2bLong path: HashLen > 64 (final hash is >64B, exercises
          the 1024-byte-length-encoded long-output construction).
          No official vector for len=100; sealed as determinism+length. --- }
  ok1 := VDbArgon2id(Rep($01, 32), Rep($02, 16), nil, nil, 2, 32, 1, 100, h1);
  ok2 := VDbArgon2id(Rep($01, 32), Rep($02, 16), nil, nil, 2, 32, 1, 100, h2);
  if ok1 and ok2 and (Length(h1) = 100) and BEq(h1, h2) then
    KatPass(PRIM, 'Blake2bLong path (HashLen=100 runs, deterministic)',
      'RFC 9106 sec. 3.4 long-output construction; determinism only ' +
      '(TODO: NIST CAVP''den dogrula - no official len-100 Argon2id tag exists)')
  else
    KatFail(PRIM, 'Blake2bLong path (HashLen=100)', SRC_RFC,
      'ok1=' + BoolToStr(ok1, True) + ' ok2=' + BoolToStr(ok2, True) +
      ' len=' + IntToStr(Length(h1)));
  h1 := nil;
  h2 := nil;

  { --- 7) documented rejection guards (must return False, not raise) --- }
  ok1 := True;
  try
    ok1 := ok1 and not VDbArgon2id(StrB('p'), Rep($02, 16), nil, nil, 3, 32, 4, 3, h1);
    ok1 := ok1 and not VDbArgon2id(StrB('p'), Rep($02, 16), nil, nil, 3, 15, 2, 32, h1);
    ok1 := ok1 and not VDbArgon2id(StrB('p'), Rep($02, 16), nil, nil, 0, 32, 1, 32, h1);
    ok1 := ok1 and not VDbArgon2id(StrB('p'), Rep($02, 16), nil, nil, 3, 32, 0, 32, h1);
    if ok1 then
      KatPass(PRIM, 'guards reject invalid params (HashLen<4, m<8p, t=0, p=0)',
        'VDbKdf.pas implementation contract (returns False, no exception)')
    else
      KatFail(PRIM, 'guards reject invalid params', SRC_RFC,
        'at least one invalid-parameter call returned True');
  except
    on E: Exception do
      KatFail(PRIM, 'guards reject invalid params', SRC_RFC,
        'unexpected exception: ' + E.ClassName + ' (' + E.Message + ')');
  end;
  h1 := nil;


  Result := KatFailed - before;
end;

end.
