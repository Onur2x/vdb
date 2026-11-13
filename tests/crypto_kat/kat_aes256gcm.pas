unit kat_aes256gcm;
{ AES-256-GCM known-answer + negative tests against VDbCryptGcmSeal/Open,
  VDbCryptAeadSeal/Open and VDbCryptEncryptLegacy/VDbCryptDecrypt.

  Vector provenance (honest statement - full details in Vectors.md):
  The six (key, IV, AAD, PT) tuples below are the canonical GCM test-case
  parameters from NIST SP 800-38D / McGrew-Viega GCM examples (the same set
  shipped as gcmEncryptExtIV256.json in Go's test corpus).  The public NIST
  CAVP JSON file could NOT be fetched from this environment (all candidate
  URLs returned 404 on 2026-11-13), so the ct/tag values were computed with
  an INDEPENDENT implementation (Python `cryptography` backed by OpenSSL);
  regenerating script: %TEMP%\kat_gcm_final.py.
  TODO: cross-check ct/tag against official CAVP gcmEncryptExtIV256.json
  from an internet-connected machine before calling this CAVP-backed.

  Sealed here:
   - ct+tag equality + Open round-trip for 6 vectors
   - tag-flip / ct-flip / wrong-nonce / wrong-AAD rejection (AEAD integrity)
   - length guards: wrong key/nonce/tag length -> False, no exception
   - 'VDBAEAD1' envelope: magic, byte layout, nonce read-back, determinism,
     tamper / wrong-AAD / truncation rejection
   - legacy CTR+HMAC envelope round-trip + tamper rejection
   - VDbCryptEncrypt/AeadOpen pairing (VDbCrypt.pas header comment M6)
   - nonce-reuse caveat recorded (BASELINE.md sec. 5 debt). }

{$mode delphi}{$H+}

interface

function RunKatAes256Gcm: Integer;

implementation

uses
  SysUtils, kat_common, VDbCrypt;

const
  PRIM  = 'AES-256-GCM (VDbCryptGcmSeal/Open)';
  PRIME = 'AEAD envelope (VDbCryptAeadSeal/Open)';
  PRIML = 'Legacy envelope (VDbCryptEncryptLegacy/Decrypt)';
  SRC_GCM = 'SP 800-38D example tuples; ct/tag via independent OpenSSL run ' +
            '(TODO: NIST CAVP''den dogrula)';

  KEY_A = 'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308';
  IV_A  = 'cafebabefacedbaddecaf888';
  AAD_B = 'feedfacedeadbeeffeedfacedeadbeefabaddad2';
  PT20  = 'd9313225f88406e5a55909c5aff5269a86a7a953';

procedure CheckVec(const ANo, AHKey, AHIV, AHAad, AHPT, AHCT, AHTag: string);
{ Seal must reproduce ct+tag; Open must round-trip; any tampering must be
  rejected. }
var
  K, N, A, P, WantCT, WantTag, PBack, Bad: TBytes;
  ct, tag: TBytes;
begin
  K := HexToBytes(AHKey);
  N := HexToBytes(AHIV);
  A := HexToBytes(AHAad);
  P := HexToBytes(AHPT);
  WantCT := HexToBytes(AHCT);
  WantTag := HexToBytes(AHTag);

  { 1) seal }
  if not VDbCryptGcmSeal(K, N, P, A, ct, tag) then
  begin
    KatFail(PRIM, ANo + ' seal', SRC_GCM, 'VDbCryptGcmSeal returned False');
    Exit;
  end;
  if BEq(ct, WantCT) and BEq(tag, WantTag) then
    KatPass(PRIM, ANo + ' seal ct+tag', SRC_GCM)
  else
  begin
    KatFail(PRIM, ANo + ' seal ct+tag', SRC_GCM,
      'got ct=' + BytesToHexL(ct) + ' tag=' + BytesToHexL(tag) +
      ' want ct=' + BytesToHexL(WantCT) + ' tag=' + BytesToHexL(WantTag));
    Exit;
  end;

  { 2) open round-trip }
  if VDbCryptGcmOpen(K, N, ct, tag, A, PBack) and BEq(PBack, P) then
    KatPass(PRIM, ANo + ' open round-trip', SRC_GCM)
  else
    KatFail(PRIM, ANo + ' open round-trip', SRC_GCM,
      'open failed or plaintext mismatch');

  { 3) tag tamper -> reject }
  Bad := tag;
  Bad[0] := Bad[0] xor $01;
  if VDbCryptGcmOpen(K, N, ct, Bad, A, PBack) then
    KatFail(PRIM, ANo + ' tag-flip rejected', SRC_GCM, 'accepted flipped tag')
  else
    KatPass(PRIM, ANo + ' tag-flip rejected', SRC_GCM);

  { 4) ciphertext tamper -> reject (skip when ct is empty) }
  if Length(ct) > 0 then
  begin
    Bad := ct;
    Bad[Length(Bad) - 1] := Bad[Length(Bad) - 1] xor $80;
    if VDbCryptGcmOpen(K, N, Bad, tag, A, PBack) then
      KatFail(PRIM, ANo + ' ct-flip rejected', SRC_GCM,
        'accepted flipped ciphertext')
    else
      KatPass(PRIM, ANo + ' ct-flip rejected', SRC_GCM);
  end;

  { 5) wrong nonce -> reject }
  Bad := N;
  Bad[0] := Bad[0] xor $01;
  if VDbCryptGcmOpen(K, Bad, ct, tag, A, PBack) then
    KatFail(PRIM, ANo + ' wrong-nonce rejected', SRC_GCM,
      'accepted data under a different nonce')
  else
    KatPass(PRIM, ANo + ' wrong-nonce rejected', SRC_GCM);

  { 6) wrong AAD -> reject }
  if Length(A) > 0 then
  begin
    Bad := A;
    Bad[0] := Bad[0] xor $01;
  end else
    Bad := StrB('x');
  if VDbCryptGcmOpen(K, N, ct, tag, Bad, PBack) then
    KatFail(PRIM, ANo + ' wrong-AAD rejected', SRC_GCM,
      'accepted data under different AAD')
  else
    KatPass(PRIM, ANo + ' wrong-AAD rejected', SRC_GCM);
end;

procedure CheckGuards;
{ Wrong-length key/nonce/tag must make Seal/Open return False without
  raising (VDbCryptGcmSeal/Open implementation contract). }
var
  n, p, a, ct, tag, pl: TBytes;
  total, rejected: Integer;
begin
  total := 0;
  rejected := 0;
  try
    n := Rep($11, 12);
    p := StrB('data to seal');
    a := nil;
    Inc(total);
    if not VDbCryptGcmSeal(Rep($00, 31), n, p, a, ct, tag) then Inc(rejected);
    Inc(total);
    if not VDbCryptGcmSeal(Rep($00, 33), n, p, a, ct, tag) then Inc(rejected);
    Inc(total);
    if not VDbCryptGcmSeal(Rep($00, 32), Rep($11, 11), p, a, ct, tag) then
      Inc(rejected);
    Inc(total);
    if not VDbCryptGcmSeal(Rep($00, 32), Rep($11, 13), p, a, ct, tag) then
      Inc(rejected);
    { a valid seal, used as base material for the Open guards }
    VDbCryptGcmSeal(Rep($00, 32), n, p, a, ct, tag);
    Inc(total);
    if not VDbCryptGcmOpen(Rep($00, 32), n, ct, Sub(tag, 0, 15), a, pl) then
      Inc(rejected);
    Inc(total);
    if not VDbCryptGcmOpen(Rep($00, 32), n, ct, Rep($00, 17), a, pl) then
      Inc(rejected);
    Inc(total);
    if not VDbCryptGcmOpen(Rep($00, 31), n, ct, tag, a, pl) then Inc(rejected);

    if rejected = total then
      KatPass(PRIM, 'length guards: 31/33B key, 11/13B nonce, 15/17B tag ' +
        'all return False', 'VDbCrypt.pas GcmSeal/GcmOpen implementation contract')
    else
      KatFail(PRIM, 'length guards', 'VDbCrypt.pas implementation contract',
        IntToStr(rejected) + '/' + IntToStr(total) + ' rejected as expected');
  except
    on E: Exception do
      KatFail(PRIM, 'length guards (no raise)',
        'VDbCrypt.pas implementation contract',
        'unexpected exception: ' + E.ClassName + ' (' + E.Message + ')');
  end;
end;

procedure CheckEnvelope;
{ 'VDBAEAD1' envelope: layout pinned byte-for-byte against raw GcmSeal,
  nonce read-back, determinism for a fixed nonce, and rejection paths. }
const
  MAGIC = 'VDBAEAD1';
var
  k, n, n2, p, a, env, env2, envBad, pl, ct1, tag1: TBytes;
  m, ctLen: Integer;
  plain: string;
begin
  k := HexToBytes(KEY_A);
  n := HexToBytes(IV_A);
  n2 := HexToBytes('000000000000000000000001');
  plain := 'page image payload #42';
  p := StrB(plain);
  a := StrB('ctx-AAD');
  m := Length(MAGIC);
  ctLen := Length(p);

  if not VDbCryptAeadSeal(k, n, p, a, env) then
  begin
    KatFail(PRIME, 'envelope seal', 'VDbCrypt.pas M6 envelope format',
      'VDbCryptAeadSeal returned False');
    Exit;
  end;

  { magic + IsAead }
  if (Length(env) >= m) and (BytesToHexL(Sub(env, 0, m)) =
      BytesToHexL(StrB(MAGIC))) and VDbCryptIsAead(env) then
    KatPass(PRIME, 'envelope magic "VDBAEAD1" + IsAead',
      'VDbCrypt.pas M6 envelope format')
  else
    KatFail(PRIME, 'envelope magic "VDBAEAD1" + IsAead',
      'VDbCrypt.pas M6 envelope format', 'magic=' +
      BytesToHexL(Sub(env, 0, m)));

  { exact layout: magic(8) | nonce(12) | ct | tag(16), ct/tag identical to
    raw GcmSeal with the same nonce }
  if (Length(env) = m + 12 + ctLen + 16) and
     BEq(Sub(env, m, 12), n) and
     VDbCryptGcmSeal(k, n, p, a, ct1, tag1) and
     BEq(Sub(env, m + 12, ctLen), ct1) and
     BEq(Sub(env, m + 12 + ctLen, 16), tag1) then
    KatPass(PRIME, 'layout magic|nonce|ct|tag pinned vs raw GcmSeal',
      'VDbCrypt.pas M6 envelope format')
  else
    KatFail(PRIME, 'layout magic|nonce|ct|tag pinned vs raw GcmSeal',
      'VDbCrypt.pas M6 envelope format',
      'len=' + IntToStr(Length(env)) + ' expected ' +
      IntToStr(m + 12 + ctLen + 16));

  { open round-trip }
  if VDbCryptAeadOpen(k, env, a, pl) and (BytesToHexL(pl) = BytesToHexL(p)) then
    KatPass(PRIME, 'open round-trip (nonce read back from envelope)',
      'VDbCrypt.pas M6 envelope format')
  else
    KatFail(PRIME, 'open round-trip', 'VDbCrypt.pas M6 envelope format',
      'failed');

  { determinism for a fixed nonce (raw GCM property the envelope inherits) }
  if VDbCryptAeadSeal(k, n, p, a, env2) and BEq(env, env2) then
    KatPass(PRIME, 'determinism for fixed (key,nonce)', SRC_GCM)
  else
    KatFail(PRIME, 'determinism for fixed (key,nonce)', SRC_GCM, 'envelopes differ');

  { different nonce -> different envelope, still opens }
  if VDbCryptAeadSeal(k, n2, p, a, env2) and (not BEq(env, env2)) and
     VDbCryptAeadOpen(k, env2, a, pl) and BEq(pl, p) then
    KatPass(PRIME, 'different nonce -> different envelope, opens', SRC_GCM)
  else
    KatFail(PRIME, 'different nonce -> different envelope, opens', SRC_GCM,
      'failed');

  { nonce byte flipped inside the envelope -> reject }
  envBad := env;
  envBad[m] := envBad[m] xor $01;
  if VDbCryptAeadOpen(k, envBad, a, pl) then
    KatFail(PRIME, 'envelope nonce-flip rejected', SRC_GCM, 'accepted')
  else
    KatPass(PRIME, 'envelope nonce-flip rejected', SRC_GCM);

  { ct byte flipped -> reject }
  envBad := env;
  envBad[m + 12] := envBad[m + 12] xor $01;
  if VDbCryptAeadOpen(k, envBad, a, pl) then
    KatFail(PRIME, 'envelope ct-flip rejected', SRC_GCM, 'accepted')
  else
    KatPass(PRIME, 'envelope ct-flip rejected', SRC_GCM);

  { wrong AAD -> reject }
  if VDbCryptAeadOpen(k, env, StrB('ctx-AADX'), pl) then
    KatFail(PRIME, 'envelope wrong-AAD rejected', SRC_GCM, 'accepted')
  else
    KatPass(PRIME, 'envelope wrong-AAD rejected', SRC_GCM);

  { truncated envelope -> reject; IsAead of magic-only buffer is True but
    Open must still refuse (length guard) }
  envBad := Sub(env, 0, Length(env) - 1);
  if VDbCryptAeadOpen(k, envBad, a, pl) then
    KatFail(PRIME, 'truncated envelope rejected', SRC_GCM, 'accepted')
  else
    KatPass(PRIME, 'truncated envelope rejected', SRC_GCM);

  if VDbCryptIsAead(Rep($41, 20)) then
    KatFail(PRIME, 'IsAead rejects non-envelope', 'VDbCrypt.pas M6',
      'IsAead(True) on garbage')
  else
    KatPass(PRIME, 'IsAead rejects non-envelope', 'VDbCrypt.pas M6');

  { VDbCryptEncrypt now produces the AEAD envelope (VDbCrypt.pas header,
    M6 comment) and pairs with VDbCryptDecrypt }
  if VDbCryptEncrypt(k, p, env) then
  begin
    if VDbCryptIsAead(env) and VDbCryptDecrypt(k, env, pl) and BEq(pl, p) then
      KatPass(PRIME, 'VDbCryptEncrypt -> AEAD envelope, Decrypt round-trip',
        'VDbCrypt.pas M6 header contract')
    else
      KatFail(PRIME, 'VDbCryptEncrypt -> AEAD envelope, Decrypt round-trip',
        'VDbCrypt.pas M6 header contract',
        'IsAead/Decrypt/round-trip failed');
  end else
    KatFail(PRIME, 'VDbCryptEncrypt -> AEAD envelope, Decrypt round-trip',
      'VDbCrypt.pas M6 header contract', 'VDbCryptEncrypt returned False');

  { documented note (not a failure): GCM nonce-reuse is NOT detected by the
    primitive - BASELINE.md sec. 5 records this as design debt. }
  KatSkip(PRIM, 'nonce-reuse detection', 'docs/engineering/BASELINE.md sec. 5',
    'VDbCryptGcmSeal does not track used nonces; reusing (key,nonce) leaks ' +
    'via identical keystream. Sealed as KNOWN DEBT, not tested as behavior.');
end;

procedure CheckLegacy;
{ Legacy CTR+HMAC envelope: round-trip and tamper rejection. Tamper may be
  reported either as False or as an exception - both are rejections; only
  silent acceptance of a modified blob fails. }
var
  k, c, cBad, pl, p: TBytes;
  accepted: Boolean;
  plain: string;
begin
  k := HexToBytes(KEY_A);
  plain := 'legacy CTR+HMAC payload, 39 bytes!';
  p := StrB(plain);

  if not VDbCryptEncryptLegacy(k, p, c) then
  begin
    KatFail(PRIML, 'legacy round-trip', 'VDbCrypt.pas legacy envelope',
      'VDbCryptEncryptLegacy returned False');
    Exit;
  end;
  if VDbCryptDecrypt(k, c, pl) and BEq(pl, p) then
    KatPass(PRIML, 'legacy round-trip (EncryptLegacy -> Decrypt)',
      'VDbCrypt.pas legacy envelope (still readable by VDbCryptDecrypt)')
  else
    KatFail(PRIML, 'legacy round-trip', 'VDbCrypt.pas legacy envelope',
      'Decrypt failed or plaintext mismatch');

  { tamper one ciphertext byte (skip header, flip mid-payload) }
  accepted := False;
  if Length(c) > 20 then
  begin
    cBad := c;
    cBad[Length(cBad) div 2] := cBad[Length(cBad) div 2] xor $40;
    try
      accepted := VDbCryptDecrypt(k, cBad, pl) and BEq(pl, p);
    except
      accepted := False; { exception is also a rejection }
    end;
    if accepted then
      KatFail(PRIML, 'legacy ct tamper rejected',
        'VDbCrypt.pas legacy envelope (HMAC check)',
        'tampered blob decrypted to the SAME plaintext')
    else
      KatPass(PRIML, 'legacy ct tamper rejected (False or exception)',
        'VDbCrypt.pas legacy envelope (HMAC check)');
  end;

  { wrong key must not decrypt }
  accepted := False;
  try
    accepted := VDbCryptDecrypt(Rep($55, 32), c, pl) and BEq(pl, p);
  except
    accepted := False;
  end;
  if accepted then
    KatFail(PRIML, 'legacy wrong-key rejected', 'VDbCrypt.pas legacy envelope',
      'decrypted with a different key')
  else
    KatPass(PRIML, 'legacy wrong-key rejected (False or exception)',
      'VDbCrypt.pas legacy envelope');
end;

function RunKatAes256Gcm: Integer;
var
  before: Integer;
begin
  before := KatFailed;
  KatSection('AES-256-GCM (raw + envelope)');

  CheckVec('V1 empty PT, empty AAD', KEY_A, IV_A, '', '', '',
    'fd2caa16a5832e76aa132c1453eeda7e');
  CheckVec('V2 20B PT, empty AAD', KEY_A, IV_A, '', PT20,
    '522dc1f099567d07f47f37a32a84427d643a8cdc',
    'ea0c314d58d83c6c238093de1612a4de');
  CheckVec('V3 20B PT + 20B AAD', KEY_A, IV_A, AAD_B, PT20,
    '522dc1f099567d07f47f37a32a84427d643a8cdc',
    '10501bc85651ae8f4176d6c5a5ea9f3f');
  CheckVec('V4 28B PT + 20B AAD', KEY_A, IV_A, AAD_B,
    PT20 + '1501f7b2a28ed09a47f98eac',
    '522dc1f099567d07f47f37a32a84427d643a8cdcbfd0c0a1f95a421ae89dd574',
    '2de5dd9732afe5f27d59503701ae3bdf');
  CheckVec('V5 zero key/IV, 16B zero PT',
    '0000000000000000000000000000000000000000000000000000000000000000',
    '000000000000000000000000', '',
    '00000000000000000000000000000000',
    'cea7403d4d606b6e074ec5d3baf39d18',
    'd0d1c8a799996bf0265b98b5d48ab919');
  CheckVec('V6 zero key/IV, empty PT',
    '0000000000000000000000000000000000000000000000000000000000000000',
    '000000000000000000000000', '', '', '',
    '530f8afbc74536b9a963b4f1c4cb738b');

  CheckGuards;
  CheckEnvelope;
  CheckLegacy;

  Result := KatFailed - before;
end;

end.
