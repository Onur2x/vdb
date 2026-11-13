unit kat_page_envelope;
{ Page-encryption envelope tests against VDbPageCrypto (VDbPageCrypto.pas).

  No official KAT exists for a custom page envelope, so the seal here is
  structural + cryptographic consistency:
   - Seal/Open round-trip for a 4096-byte page image
   - Envelope layout pinned byte-for-byte: nonce(12)|ct(4096)|tag(16), and
     ct/tag must equal a raw VDbCryptGcmSeal over the AAD
     'VDB3PG' || LE32(PageNo) || Salt  (BuildAad contract, VDbPageCrypto.pas)
   - Random nonce per seal; same (key,salt,page) twice -> different envelope
   - Tamper (ct/tag/nonce), wrong page number, wrong salt, wrong key and
     truncated envelopes must all be rejected with False
   - Wrong key/plain length -> EVdbPageCrypto (raise contract of Seal);
     Open with wrong key/envelope length returns False without raising
   - VDbPageKeyCheck == first 16 bytes of HMAC-SHA256(key,'VDB3-PAGE-KEY-v1')
   - VDbPageKeyFingerprint: 8 lowercase hex chars, deterministic, key-sensitive
   - VDbPageKeyFromPassword: deterministic, salt-sensitive, raises on
     Iterations < 1. }

{$mode delphi}{$H+}

interface

function RunKatPageEnvelope: Integer;

implementation

uses
  SysUtils, kat_common, VDbCrypt, VDbPageCrypto;

const
  PRIM = 'Page envelope (VDbPageCrypto)';
  SRC_IMPL = 'VDbPageCrypto.pas implementation contract';

function MakePlain: TBytes;
var
  i: Integer;
begin
  SetLength(Result, 4096);
  for i := 0 to 4095 do
    Result[i] := Byte(i * 7 + (i shr 8) * 13 + 1);
end;

procedure CheckRoundTripAndLayout;
var
  key, salt, plain, env, env2, pl, aad, n, ct, tag, ct2, tag2: TBytes;
  pageno: LongWord;
  manual: Boolean;
begin
  key := Rep($11, VDB_ENC_KEY_LEN);
  salt := Rep($22, VDB_ENC_SALT_LEN);
  pageno := $01020304;
  plain := MakePlain;

  if not VDbPageSeal(key, salt, pageno, plain, env) then
  begin
    KatFail(PRIM, 'Seal/Open round-trip', SRC_IMPL, 'VDbPageSeal returned False');
    Exit;
  end;
  if Length(env) <> VDB_ENC_ENVELOPE then
  begin
    KatFail(PRIM, 'Seal/Open round-trip', SRC_IMPL,
      'envelope length ' + IntToStr(Length(env)) + ' != 4124');
    Exit;
  end;

  if VDbPageOpen(key, salt, pageno, env, pl) and BEq(pl, plain) then
    KatPass(PRIM, 'Seal/Open round-trip (4096B page, 4124B envelope)', SRC_IMPL)
  else
    KatFail(PRIM, 'Seal/Open round-trip', SRC_IMPL,
      'Open failed or plaintext mismatch');

  { layout + AAD pinned: env = nonce | GcmSeal(key,nonce,plain,AAD).ct | tag,
    AAD = 'VDB3PG' || LE32(pageno) || salt }
  aad := StrB('VDB3PG');
  SetLength(aad, 10 + Length(salt));
  // rebuild properly: magic already in place, write LE32 at 6..9 then salt
  PutLE32(aad, 6, pageno);
  Move(salt[0], aad[10], Length(salt));
  n := Sub(env, 0, VDB_ENC_NONCE_LEN);
  manual := VDbCryptGcmSeal(key, n, plain, aad, ct, tag);
  if manual and BEq(Sub(env, 12, 4096), ct) and
     BEq(Sub(env, 12 + 4096, 16), tag) then
    KatPass(PRIM, 'layout nonce|ct|tag + AAD "VDB3PG"|LE32(PageNo)|Salt pinned',
      SRC_IMPL)
  else
    KatFail(PRIM, 'layout nonce|ct|tag + AAD "VDB3PG"|LE32(PageNo)|Salt pinned',
      SRC_IMPL, 'raw recomputation differs (manual=' + BoolToStr(manual, True) + ')');

  { random nonce per seal: same inputs -> different envelope }
  if VDbPageSeal(key, salt, pageno, plain, env2) then
  begin
    if (not BEq(env, env2)) and
       not BEq(Sub(env, 0, VDB_ENC_NONCE_LEN),
               Sub(env2, 0, VDB_ENC_NONCE_LEN)) and
       VDbPageOpen(key, salt, pageno, env2, pl) and BEq(pl, plain) then
      KatPass(PRIM, 'fresh random nonce per seal (both open, envelopes differ)',
        SRC_IMPL + ' (nonce uniqueness probabilistic, 2^-96 collision)')
    else
      KatFail(PRIM, 'fresh random nonce per seal', SRC_IMPL,
        'envelopes or nonces identical, or second open failed');
  end else
    KatFail(PRIM, 'fresh random nonce per seal', SRC_IMPL,
      'second VDbPageSeal returned False');

  { --- rejection paths --- }
  // ct byte flip
  ct2 := env;
  ct2[2000] := ct2[2000] xor $01;
  if VDbPageOpen(key, salt, pageno, ct2, pl) then
    KatFail(PRIM, 'ct tamper rejected', SRC_IMPL, 'accepted tampered ct')
  else
    KatPass(PRIM, 'ct tamper rejected', SRC_IMPL);

  // tag byte flip
  ct2 := env;
  ct2[VDB_ENC_NONCE_LEN + 4096 + 3] := ct2[VDB_ENC_NONCE_LEN + 4096 + 3] xor $80;
  if VDbPageOpen(key, salt, pageno, ct2, pl) then
    KatFail(PRIM, 'tag tamper rejected', SRC_IMPL, 'accepted tampered tag')
  else
    KatPass(PRIM, 'tag tamper rejected', SRC_IMPL);

  // nonce byte flip
  ct2 := env;
  ct2[5] := ct2[5] xor $04;
  if VDbPageOpen(key, salt, pageno, ct2, pl) then
    KatFail(PRIM, 'nonce tamper rejected', SRC_IMPL, 'accepted tampered nonce')
  else
    KatPass(PRIM, 'nonce tamper rejected', SRC_IMPL);

  // wrong page number
  if VDbPageOpen(key, salt, pageno + 1, env, pl) then
    KatFail(PRIM, 'wrong PageNo rejected (AAD binding)', SRC_IMPL,
      'opened under a different page number')
  else
    KatPass(PRIM, 'wrong PageNo rejected (AAD binding)', SRC_IMPL);

  // wrong salt
  if VDbPageOpen(key, Rep($99, VDB_ENC_SALT_LEN), pageno, env, pl) then
    KatFail(PRIM, 'wrong salt rejected (AAD binding)', SRC_IMPL,
      'opened under a different salt')
  else
    KatPass(PRIM, 'wrong salt rejected (AAD binding)', SRC_IMPL);

  // wrong key
  if VDbPageOpen(Rep($77, VDB_ENC_KEY_LEN), salt, pageno, env, pl) then
    KatFail(PRIM, 'wrong key rejected', SRC_IMPL, 'opened with wrong key')
  else
    KatPass(PRIM, 'wrong key rejected', SRC_IMPL);

  // truncated / oversized envelope -> False, no raise
  if VDbPageOpen(key, salt, pageno, Sub(env, 0, VDB_ENC_ENVELOPE - 1), pl) then
    KatFail(PRIM, 'truncated envelope rejected', SRC_IMPL, 'accepted')
  else
    KatPass(PRIM, 'truncated envelope rejected', SRC_IMPL);

  if VDbPageOpen(key, salt, pageno, Sub(env, 0, 0), pl) then
    KatFail(PRIM, 'empty envelope rejected', SRC_IMPL, 'accepted')
  else
    KatPass(PRIM, 'empty envelope rejected', SRC_IMPL);

  // Open with wrong key length: False, no raise (implementation exits early)
  try
    if VDbPageOpen(Rep($11, 31), salt, pageno, env, pl) then
      KatFail(PRIM, 'Open wrong key length -> False (no raise)', SRC_IMPL,
        'accepted 31-byte key')
    else
      KatPass(PRIM, 'Open wrong key length -> False (no raise)', SRC_IMPL);
  except
    on E: Exception do
      KatFail(PRIM, 'Open wrong key length -> False (no raise)', SRC_IMPL,
        'unexpected exception: ' + E.ClassName);
  end;

  // Seal with wrong key length / wrong plain length -> EVdbPageCrypto
  try
    VDbPageSeal(Rep($11, 31), salt, pageno, plain, env);
    KatFail(PRIM, 'Seal wrong key length -> EVdbPageCrypto', SRC_IMPL,
      'no exception raised');
  except
    on E: EVdbPageCrypto do
      KatPass(PRIM, 'Seal wrong key length -> EVdbPageCrypto', SRC_IMPL);
    on E: Exception do
      KatFail(PRIM, 'Seal wrong key length -> EVdbPageCrypto', SRC_IMPL,
        'wrong class: ' + E.ClassName);
  end;

  try
    VDbPageSeal(key, salt, pageno, Sub(plain, 0, 4095), env);
    KatFail(PRIM, 'Seal 4095B page -> EVdbPageCrypto', SRC_IMPL,
      'no exception raised');
  except
    on E: EVdbPageCrypto do
      KatPass(PRIM, 'Seal 4095B page -> EVdbPageCrypto', SRC_IMPL);
    on E: Exception do
      KatFail(PRIM, 'Seal 4095B page -> EVdbPageCrypto', SRC_IMPL,
        'wrong class: ' + E.ClassName);
  end;
end;

procedure CheckKeyDerivation;
var
  key, salt, salt2, kc1, kc2, h: TBytes;
  fp1, fp2: string;
  i: Integer;
  okChars: Boolean;
begin
  key := Rep($AB, VDB_ENC_KEY_LEN);
  salt := Rep($CD, VDB_ENC_SALT_LEN);

  { KeyCheck == first 16 bytes of HMAC-SHA256(key, 'VDB3-PAGE-KEY-v1') }
  kc1 := VDbPageKeyCheck(key);
  h := VDbCryptHmacSha256(key, VDbCryptStrToBytes('VDB3-PAGE-KEY-v1'));
  if (Length(kc1) = VDB_ENC_CHECK_LEN) and BEq(kc1, Sub(h, 0, 16)) then
    KatPass(PRIM, 'KeyCheck = HMAC-SHA256(key,"VDB3-PAGE-KEY-v1")[0..15]',
      SRC_IMPL)
  else
    KatFail(PRIM, 'KeyCheck = HMAC-SHA256(key,"VDB3-PAGE-KEY-v1")[0..15]',
      SRC_IMPL, 'got ' + BytesToHexL(kc1) + ' want ' + BytesToHexL(Sub(h, 0, 16)));

  kc2 := VDbPageKeyCheck(key);
  if BEq(kc1, kc2) then
    KatPass(PRIM, 'KeyCheck deterministic', SRC_IMPL)
  else
    KatFail(PRIM, 'KeyCheck deterministic', SRC_IMPL, 'differs between calls');

  { fingerprint: 8 lowercase hex, deterministic, key-sensitive }
  fp1 := VDbPageKeyFingerprint(key);
  fp2 := VDbPageKeyFingerprint(key);
  okChars := (Length(fp1) = 8) and (fp1 = fp2);
  if okChars then
    for i := 1 to 8 do
      if not (fp1[i] in ['0'..'9', 'a'..'f']) then
        okChars := False;
  if okChars then
    KatPass(PRIM, 'fingerprint = 8 lowercase hex, deterministic', SRC_IMPL)
  else
    KatFail(PRIM, 'fingerprint = 8 lowercase hex, deterministic', SRC_IMPL,
      'got "' + fp1 + '"');
  fp2 := VDbPageKeyFingerprint(Rep($AC, VDB_ENC_KEY_LEN));
  if fp1 <> fp2 then
    KatPass(PRIM, 'fingerprint key-sensitive', SRC_IMPL)
  else
    KatFail(PRIM, 'fingerprint key-sensitive', SRC_IMPL,
      'two different keys share a fingerprint');

  { password-based derivation: deterministic + salt-sensitive + guard }
  kc1 := VDbPageKeyFromPassword(StrB('correct horse'), salt, 1000);
  kc2 := VDbPageKeyFromPassword(StrB('correct horse'), salt, 1000);
  if (Length(kc1) = VDB_ENC_KEY_LEN) and BEq(kc1, kc2) then
    KatPass(PRIM, 'KeyFromPassword deterministic (PBKDF2-SHA256, 1000 iter)',
      SRC_IMPL)
  else
    KatFail(PRIM, 'KeyFromPassword deterministic', SRC_IMPL, 'mismatch');

  salt2 := Rep($CE, VDB_ENC_SALT_LEN);
  kc2 := VDbPageKeyFromPassword(StrB('correct horse'), salt2, 1000);
  if not BEq(kc1, kc2) then
    KatPass(PRIM, 'KeyFromPassword salt-sensitive', SRC_IMPL)
  else
    KatFail(PRIM, 'KeyFromPassword salt-sensitive', SRC_IMPL, 'same key');

  try
    VDbPageKeyFromPassword(StrB('x'), salt, 0);
    KatFail(PRIM, 'KeyFromPassword Iterations=0 -> EVdbPageCrypto', SRC_IMPL,
      'no exception raised');
  except
    on E: EVdbPageCrypto do
      KatPass(PRIM, 'KeyFromPassword Iterations=0 -> EVdbPageCrypto', SRC_IMPL);
    on E: Exception do
      KatFail(PRIM, 'KeyFromPassword Iterations=0 -> EVdbPageCrypto', SRC_IMPL,
        'wrong class: ' + E.ClassName);
  end;
end;

function RunKatPageEnvelope: Integer;
var
  before: Integer;
begin
  before := KatFailed;
  KatSection('Page envelope (VDbPageCrypto)');
  CheckRoundTripAndLayout;
  CheckKeyDerivation;
  KatSkip(PRIM, 'official KAT vector', 'n/a',
    'custom page-envelope format has no RFC/NIST vector; sealed structurally ' +
    'against raw AES-256-GCM vectors above instead');
  Result := KatFailed - before;
end;

end.
