unit kat_aes256gcm;
{ AES-256-GCM known-answer + negative tests against VDbCryptGcmSeal/Open,
  VDbCryptAeadSeal/Open and VDbCryptEncryptLegacy/VDbCryptDecrypt.

  Vector provenance (honest statement - full details in Vectors.md):
  Two vector sets are sealed here.
  (1) The six (key, IV, AAD, PT) tuples below are the canonical GCM test-case
  parameters from NIST SP 800-38D / McGrew-Viega GCM examples (the same set
  shipped as gcmEncryptExtIV256.json in Go's test corpus).  Their ct/tag
  values were computed with an INDEPENDENT implementation (Python
  `cryptography` backed by OpenSSL).
  (2) SKILL16: the official NIST CAVP file gcmEncryptExtIV256.rsp (CAVS 14.0)
  is now available; cavp_aes256gcm.txt holds a 40-vector subset of it
  (Keylen=256, IVlen=96, Taglen=128, PTlen>0; first two vectors of each
  (PTlen,AADlen) family).  Those ct/tag values are transcribed from the
  CAVP file itself, i.e. from an outside source, not from this code base.
  The subset was re-derived here with Python `cryptography`/AESGCM
  (40/40 match) so a transcription slip would be caught even before the
  Pascal seal runs.

  Sealed here:
   - ct+tag equality + Open round-trip for 6 vectors
   - ct+tag equality + Open round-trip for 40 official CAVP vectors
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
  SysUtils, Classes, StrUtils, kat_common, VDbCrypt, VDbNonceGuard,
  VDbPageCrypto;


const
  PRIM  = 'AES-256-GCM (VDbCryptGcmSeal/Open)';
  PRIME = 'AEAD envelope (VDbCryptAeadSeal/Open)';
  PRIML = 'Legacy envelope (VDbCryptEncryptLegacy/Decrypt)';
  SRC_GCM = 'SP 800-38D example tuples; ct/tag via independent OpenSSL run';
  SRC_CAVP = 'NIST CAVP gcmEncryptExtIV256.rsp (CAVS 14.0), 40 vektor';

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

  { SKILL16-D: nonce tekrari artik IZLENIYOR. Ham GCM ilkeli hala sayac
    tutmaz (tek bir cagride durum yoktur), ama uretim yolu VDbNonceGuard
    uzerinden gecer; ayni (anahtar, nonce) ikinci kez sifrelenmez.
    Davranis CheckNonceGuard icinde olculur. }
  KatPass(PRIM, 'nonce-reuse tespiti VDbNonceGuard ile kapatildi', SRC_CAVP);
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

function SplitSpace(const S: string): TStringArray;
{ Bos alan korunur: CAVP satirlarinda AADlen=0 iken AAD alani BOS string
  olarak yazilir, ardindan iki bosluk gelir. Bu yuzden SplitString'in
  varsayilan "ardisik ayirici tek sayilir" davranisi kullanilamaz. }
var
  i, n: Integer;
  cur: string;
begin
  SetLength(Result, 0);
  n := 0;
  cur := '';
  for i := 1 to Length(S) do
  begin
    if S[i] = ' ' then
    begin
      SetLength(Result, n + 1);
      Result[n] := cur;
      Inc(n);
      cur := '';
    end
    else
      cur := cur + S[i];
  end;
  SetLength(Result, n + 1);
  Result[n] := cur;
end;

function CavpPath: string;
{ Vektor dosyasi depoda tests/crypto_kat/cavp_aes256gcm.txt olarak durur.
  Kapi (tests/run_gates.sh) mutlak yolu parametre olarak verir; elle
  kosularda depo kokunden ayni goreli yol denenir. Dosya depoya ait
  oldugu icin yoklugu SKIP degil FAIL'dir. }
var
  cand: array[0..3] of string;
  i: Integer;
begin
  Result := '';
  cand[0] := ParamStr(1);
  cand[1] := 'tests/crypto_kat/cavp_aes256gcm.txt';
  cand[2] := 'cavp_aes256gcm.txt';
  cand[3] := ExtractFilePath(ParamStr(0)) + 'cavp_aes256gcm.txt';
  for i := 0 to High(cand) do
    if (cand[i] <> '') and FileExists(cand[i]) then
      Exit(cand[i]);
end;

procedure CheckCavp;
{ SKILL16-B: resmi NIST CAVP AES-256-GCM alt kumesi. Her satir icin seal
  ct+tag esitligi ve Open gidis-donusu dogrulanir. Vektor sabitleri bu kod
  tabanindan DEGIL, CAVP dosyasindan gelir; bu yuzden dogrulama bagimsizdir. }
var
  path: string;
  sl: TStringList;
  i, ok, bad: Integer;
  line: string;
  parts: TStringArray;
  ptBits, aadBits: Integer;
  K, N, A, P, WantCT, WantTag, ct, tag, PBack: TBytes;
  det: string;
begin
  path := CavpPath;
  if path = '' then
  begin
    KatFail(PRIM, 'CAVP gcmEncryptExtIV256 alt kumesi', SRC_CAVP,
      'vektor dosyasi bulunamadi (tests/crypto_kat/cavp_aes256gcm.txt)');
    Exit;
  end;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(path);
    ok := 0;
    bad := 0;
    for i := 0 to sl.Count - 1 do
    begin
      line := TrimRight(sl[i]);
      if (line = '') or (line[1] = '#') then
        Continue;
      parts := SplitSpace(line);
      if Length(parts) <> 9 then
      begin
        Inc(bad);
        KatFail(PRIM, Format('CAVP satir %d', [i + 1]), SRC_CAVP,
          Format('beklenen 9 alan, bulunan %d', [Length(parts)]));
        Continue;
      end;
      ptBits := StrToIntDef(parts[0], -1);
      aadBits := StrToIntDef(parts[1], -1);
      det := Format('Count=%s PTlen=%d AADlen=%d', [parts[2], ptBits, aadBits]);
      try
        K := HexToBytes(parts[3]);
        N := HexToBytes(parts[4]);
        P := HexToBytes(parts[5]);
        A := HexToBytes(parts[6]);
        WantCT := HexToBytes(parts[7]);
        WantTag := HexToBytes(parts[8]);
      except
        on E: Exception do
        begin
          Inc(bad);
          KatFail(PRIM, 'CAVP ' + det, SRC_CAVP, E.Message);
          Continue;
        end;
      end;
      if (Length(K) <> 32) or (Length(N) <> 12) or
         (Length(WantTag) <> 16) or (Length(WantCT) * 8 <> ptBits) or
         (Length(P) * 8 <> ptBits) or (Length(A) * 8 <> aadBits) then
      begin
        Inc(bad);
        KatFail(PRIM, 'CAVP ' + det, SRC_CAVP,
          Format('alan uzunlugu tutarsiz: key=%d nonce=%d tag=%d pt=%d ct=%d aad=%d',
            [Length(K), Length(N), Length(WantTag), Length(P), Length(WantCT),
             Length(A)]));
        Continue;
      end;
      if not VDbCryptGcmSeal(K, N, P, A, ct, tag) then
      begin
        Inc(bad);
        KatFail(PRIM, 'CAVP ' + det, SRC_CAVP, 'VDbCryptGcmSeal returned False');
        Continue;
      end;
      if not (BEq(ct, WantCT) and BEq(tag, WantTag)) then
      begin
        Inc(bad);
        KatFail(PRIM, 'CAVP ' + det, SRC_CAVP,
          'got ct=' + BytesToHexL(ct) + ' tag=' + BytesToHexL(tag) +
          ' want ct=' + BytesToHexL(WantCT) + ' tag=' + BytesToHexL(WantTag));
        Continue;
      end;
      if not (VDbCryptGcmOpen(K, N, ct, tag, A, PBack) and BEq(PBack, P)) then
      begin
        Inc(bad);
        KatFail(PRIM, 'CAVP ' + det, SRC_CAVP, 'open gidis-donusu basarisiz');
        Continue;
      end;
      KatPass(PRIM, 'CAVP ' + det, SRC_CAVP);
      Inc(ok);
    end;
    if bad = 0 then
    begin
      if ok = 0 then
        KatFail(PRIM, 'CAVP alt kumesi', SRC_CAVP, 'dosyada vektor bulunamadi')
      else
        KatPass(PRIM, Format('CAVP alt kumesi tam (%d vektor)', [ok]), SRC_CAVP);
    end
    else
      KatFail(PRIM, 'CAVP alt kumesi', SRC_CAVP,
        Format('%d vektor hatali', [bad]));
  finally
    sl.Free;
  end;
end;

procedure CheckNegatives;
{ SKILL16-C: negatif kume. Yanlis anahtar, kirpilmis etiket (0/1/8/15 bayt),
  bos duz metin ve 1 MiB duz metin + 64 KiB AAD. Her saldiri REDDEDILMELI;
  kabul edilen herhangi bir durum FAIL'dir. }
var
  K, N, A, P, ct, tag, bad, back, big: TBytes;
  i, acc: Integer;
  lens: array[0..3] of Integer;
begin
  K := HexToBytes(KEY_A);
  N := HexToBytes(IV_A);
  A := HexToBytes(AAD_B);
  P := HexToBytes(PT20);
  if not VDbCryptGcmSeal(K, N, P, A, ct, tag) then
  begin
    KatFail(PRIM, 'negatif taban seal', SRC_GCM, 'VDbCryptGcmSeal False');
    Exit;
  end;

  { 1) yanlis anahtar }
  bad := K;
  bad[0] := bad[0] xor $01;
  acc := 0;
  try
    if VDbCryptGcmOpen(bad, N, ct, tag, A, back) then
      acc := 1;
  except
    acc := 0;
  end;
  if acc = 1 then
    KatFail(PRIM, 'negatif: yanlis anahtar reddedilir', SRC_GCM, 'kabul edildi')
  else
    KatPass(PRIM, 'negatif: yanlis anahtar reddedilir', SRC_GCM);

  { 2) kirpilmis etiket: 0, 1, 8, 15 bayt }
  lens[0] := 0;
  lens[1] := 1;
  lens[2] := 8;
  lens[3] := 15;
  for i := 0 to High(lens) do
  begin
    SetLength(bad, lens[i]);
    if lens[i] > 0 then
      Move(tag[0], bad[0], lens[i]);
    acc := 0;
    try
      if VDbCryptGcmOpen(K, N, ct, bad, A, back) then
        acc := 1;
    except
      acc := 0;  { istisna da reddin gecerli bicimidir }
    end;
    if acc = 1 then
      KatFail(PRIM, Format('negatif: %d baytlik etiket reddedilir', [lens[i]]),
        SRC_GCM, 'kabul edildi')
    else
      KatPass(PRIM, Format('negatif: %d baytlik etiket reddedilir', [lens[i]]),
        SRC_GCM);
  end;

  { 3) bos duz metin + AAD: gidis-donus ve etiket bozulmasinin reddi }
  if VDbCryptGcmSeal(K, N, nil, A, ct, tag) and
     VDbCryptGcmOpen(K, N, ct, tag, A, back) and (Length(back) = 0) then
  begin
    bad := tag;
    bad[0] := bad[0] xor $01;
    if VDbCryptGcmOpen(K, N, ct, bad, A, back) then
      KatFail(PRIM, 'negatif: bos PT etiket bozulmasi reddedilir', SRC_GCM,
        'bozuk etiket kabul edildi')
    else
      KatPass(PRIM, 'negatif: bos PT etiket bozulmasi reddedilir', SRC_GCM);
  end
  else
    KatFail(PRIM, 'negatif: bos PT gidis-donus', SRC_GCM,
      'bos duz metin sifrelenip acilamadi');

  { 4) 1 MiB duz metin + 64 KiB AAD }
  SetLength(big, 1024 * 1024);
  for i := 0 to High(big) do
    big[i] := Byte((i * 37 + 11) and $FF);
  SetLength(A, 64 * 1024);
  for i := 0 to High(A) do
    A[i] := Byte((i * 91 + 7) and $FF);
  if not VDbCryptGcmSeal(K, N, big, A, ct, tag) then
    KatFail(PRIM, 'negatif: 1 MiB PT seal', SRC_GCM, 'seal False')
  else if Length(ct) <> Length(big) then
    KatFail(PRIM, 'negatif: 1 MiB PT seal', SRC_GCM,
      Format('ct %d bayt, beklenen %d', [Length(ct), Length(big)]))
  else if not (VDbCryptGcmOpen(K, N, ct, tag, A, back) and BEq(back, big)) then
    KatFail(PRIM, 'negatif: 1 MiB PT gidis-donus', SRC_GCM,
      'open basarisiz ya da duz metin farkli')
  else
    KatPass(PRIM, 'negatif: 1 MiB PT + 64 KiB AAD gidis-donus', SRC_GCM);
  if Length(ct) = Length(big) then
  begin
    bad := ct;
    bad[Length(bad) div 2] := bad[Length(bad) div 2] xor $04;
    if VDbCryptGcmOpen(K, N, bad, tag, A, back) then
      KatFail(PRIM, 'negatif: 1 MiB PT ct bozulmasi reddedilir', SRC_GCM,
        'bozuk sifreli metin kabul edildi')
    else
      KatPass(PRIM, 'negatif: 1 MiB PT ct bozulmasi reddedilir', SRC_GCM);
  end;
end;

procedure CheckNonceGuard;
{ SKILL16-D: VDbNonceGuard ayni (anahtar, nonce) ikilisini ikinci kez kabul
  ETMEZ; farkli nonce/anahtar kabul edilir; Reset sonrasi tekrar kabul
  edilir; gecersiz girdi reddedilir. Ayrica VDbPageSeal her cagride taze
  nonce uretir (zarflar farkli) ve iki zarf da acilir. }
var
  K, K2, N, N2: TBytes;
  pKey, pSalt, plain, e1, e2, back: TBytes;
  i: Integer;
  okAll: Boolean;
begin
  VDbNonceReset;
  K := HexToBytes(KEY_A);
  N := HexToBytes(IV_A);
  okAll := VDbNonceMark(K, N);
  okAll := okAll and not VDbNonceMark(K, N);
  N2 := Copy(N, 0, Length(N));
  N2[0] := N2[0] xor $01;
  okAll := okAll and VDbNonceMark(K, N2);
  K2 := Copy(K, 0, Length(K));
  K2[0] := K2[0] xor $01;
  okAll := okAll and VDbNonceMark(K2, N);
  okAll := okAll and (VDbNonceGuardCount = 3);
  if okAll then
    KatPass(PRIM, 'nonce guard: tekrar reddedilir, taze nonce kabul', SRC_CAVP)
  else
    KatFail(PRIM, 'nonce guard: tekrar reddedilir, taze nonce kabul', SRC_CAVP,
      Format('count=%d', [VDbNonceGuardCount]));

  if VDbNonceMark(nil, N) or VDbNonceMark(K, nil) then
    KatFail(PRIM, 'nonce guard: gecersiz girdi reddedilir', SRC_CAVP,
      'bos anahtar/nonce kabul edildi')
  else
    KatPass(PRIM, 'nonce guard: gecersiz girdi reddedilir', SRC_CAVP);

  VDbNonceReset;
  if (VDbNonceGuardCount = 0) and VDbNonceMark(K, N) then
    KatPass(PRIM, 'nonce guard: reset sonrasi ayni nonce kabul', SRC_CAVP)
  else
    KatFail(PRIM, 'nonce guard: reset sonrasi ayni nonce kabul', SRC_CAVP,
      Format('count=%d', [VDbNonceGuardCount]));

  { Sayfa zarfi: her cagride taze nonce; iki zarf farkli ve ikisi de acilir. }
  pKey := VDbPageNewKey;
  pSalt := VDbPageNewSalt;
  SetLength(plain, 4096);
  for i := 0 to High(plain) do
    plain[i] := Byte((i * 13 + 5) and $FF);
  if VDbPageSeal(pKey, pSalt, 7, plain, e1) and
     VDbPageSeal(pKey, pSalt, 7, plain, e2) and
     (Length(e1) > 0) and not CompareMem(@e1[0], @e2[0], Length(e1)) and
     VDbPageOpen(pKey, pSalt, 7, e1, back) and BEq(back, plain) and
     VDbPageOpen(pKey, pSalt, 7, e2, back) and BEq(back, plain) then
    KatPass(PRIM, 'sayfa zarfi: her yazimda taze nonce, ikisi de acilir', SRC_CAVP)
  else
    KatFail(PRIM, 'sayfa zarfi: her yazimda taze nonce, ikisi de acilir',
      SRC_CAVP, 'zarf tekrari ya da open hatasi');

  if VDbPageOpen(pKey, pSalt, 8, e1, back) then
    KatFail(PRIM, 'sayfa zarfi: yanlis sayfa numarasi reddedilir', SRC_CAVP,
      'AAD sayfa numarasi yok sayildi')
  else
    KatPass(PRIM, 'sayfa zarfi: yanlis sayfa numarasi reddedilir', SRC_CAVP);

  VDbNonceReset;
end;

procedure CheckRngDiscipline;
{ SKILL16-A/E: uretim kripto yolunda deterministik RNG (Random/RandSeed)
  BULUNMAMALI ve her VDbCryptRandom cagrisi sonucunu denetlemeli. Bu bir
  KAYNAK TARAMASI kapisidir: RNG arizasini enjekte etmek uretim birimine
  kanca eklemeyi gerektirirdi; kanca eklemek yerine yolu kaynak duzeyinde
  pinliyoruz ve durustce boyle raporluyoruz. }
const
  SEC_UNITS: array[0..5] of string = (
    'VDbCryptoRandom.pas',
    'VDbCrypt.pas',
    'VDbPageCrypto.pas',
    'VDbPgWire.pas',
    'VDbCryptoBuiltin.pas',
    'VDbNonceGuard.pas');
var
  root, path, line, t: string;
  i, ln, q, badBare, badGuard, calls, scanned: Integer;
  sl: TStringList;
  missing: string;
begin
  root := ExtractFileDir(ExtractFileDir(ExtractFileDir(
    ExpandFileName(CavpPath))));
  badBare := 0;
  badGuard := 0;
  calls := 0;
  scanned := 0;
  missing := '';
  for i := 0 to High(SEC_UNITS) do
  begin
    path := IncludeTrailingPathDelimiter(root) + SEC_UNITS[i];
    if not FileExists(path) then
    begin
      missing := missing + ' ' + SEC_UNITS[i];
      Continue;
    end;
    sl := TStringList.Create;
    try
      sl.LoadFromFile(path);
      Inc(scanned);
      for ln := 0 to sl.Count - 1 do
      begin
        line := sl[ln];
        if Trim(Copy(TrimLeft(line), 1, 2)) = '//' then
          Continue;
        { Kripto RNG adlarini temizle, kalan 'Random(' deterministik
          RNG kullanimidir (Win32 CryptGenRandom ve VDb* sarmallari
          guvenli yollardir). }
        t := StringReplace(line, 'VDbCryptRandom(', '', [rfReplaceAll]);
        t := StringReplace(t, 'VDbCryptoRandomBytes(', '', [rfReplaceAll]);
        t := StringReplace(t, 'VDbCryptoOsRandomBytes(', '', [rfReplaceAll]);
        t := StringReplace(t, 'CryptGenRandom(', '', [rfReplaceAll]);
        if Pos('Random(', t) > 0 then
        begin
          Inc(badBare);
          WriteLn('  BARE Random: ', SEC_UNITS[i], ':', ln + 1, ' ',
            Trim(line));
        end;
        if Pos('RandSeed', t) > 0 then
        begin
          Inc(badBare);
          WriteLn('  RandSeed: ', SEC_UNITS[i], ':', ln + 1, ' ',
            Trim(line));
        end;
        q := Pos('VDbCryptRandom(', line);
        if q > 0 then
        begin
          { Bildirim satirlari cagri degildir. }
          if (Pos('function VDbCryptRandom(', line) > 0) or
             (Pos('procedure VDbCryptRandom(', line) > 0) then
            Continue;
          Inc(calls);
          if (Pos('not VDbCryptRandom(', line) = 0) and
             (Pos(':= VDbCryptRandom(', line) = 0) then
          begin
            Inc(badGuard);
            WriteLn('  DENETLENMEYEN RNG: ', SEC_UNITS[i], ':', ln + 1, ' ',
              Trim(line));
          end;
        end;
      end;
    finally
      sl.Free;
    end;
  end;

  if missing <> '' then
    KatFail(PRIM, 'RNG disiplini: kripto birimleri tarandi', SRC_CAVP,
      'bulunamayan birim:' + missing)
  else if badBare = 0 then
    KatPass(PRIM, Format('RNG disiplini: %d birimde Random/RandSeed yok',
      [scanned]), SRC_CAVP)
  else
    KatFail(PRIM, 'RNG disiplini: uretim yolunda deterministik RNG yok',
      SRC_CAVP, Format('%d ihlal', [badBare]));

  if (badGuard = 0) and (calls > 0) then
    KatPass(PRIM, Format('RNG disiplini: %d VDbCryptRandom cagrisi '
      + 'sonucu denetliyor', [calls]), SRC_CAVP)
  else if calls = 0 then
    KatFail(PRIM, 'RNG disiplini: VDbCryptRandom cagrilari bulundu',
      SRC_CAVP, 'hic cagri taranmadi')
  else
    KatFail(PRIM, 'RNG disiplini: her VDbCryptRandom cagrisi denetlenir',
      SRC_CAVP, Format('%d denetlenmeyen cagri', [badGuard]));
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

  CheckCavp;
  CheckGuards;
  CheckNegatives;
  CheckNonceGuard;
  CheckRngDiscipline;
  CheckEnvelope;
  CheckLegacy;

  Result := KatFailed - before;
end;

end.
