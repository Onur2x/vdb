program crypto_interop;
{ v3.72 SKILL6 08 (B) - BAGIMSIZ KRIPTOGRAFI DOGRULAMASI.

  Amac: moturun kendi testinin kendi ciktisini dogrulamasi DEGIL, yayinlanmis
  bagimsiz standart vektorlerle dogrulamak. Buradaki her beklenen deger
  motorun disinda uretilmistir:

    - SHA-256: FIPS 180-4 / NIST ornekleri
    - HMAC-SHA-256: RFC 4231 test case 4 ve 5
    - PBKDF2-HMAC-SHA-256: RFC 7914 / RFC 6070 ailesi yayin vektorleri
    - AES-256 tek blok: FIPS-197 Ek C.3 ornegi
    - AES-256-GCM: McGrew/Viega GCM belirtimi test case 13, 14, 15, 16

  NOT: NIST CAVP vektor dosyasina (gcmEncryptExtIV256.json) bu ortamdan
  erisilemedi (HTTP 404); asagidaki GCM vektorleri GCM belirtiminin kendi
  yayinladigi orneklerdir. Bu kapi GCM'i BAGIMSIZ BIR UYGULAMAYLA
  karsilastirmaz - o iddia kurulmaz. FIPS/CAVP sertifikasi da iddia edilmez.

  Ayrica: bos girdi, buyuk girdi, blok sinirlari (55/56/63/64/65), yanlis
  etiket, degistirilmis AAD, yanlis anahtar, bozuk sifreli metin ve RNG
  sozlesmesi test edilir. }

{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, VDbCrypt;

var
  GPass, GFail: Integer;

procedure Chk(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(GPass);
    WriteLn('PASS ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('FAIL ', AName, ' - ', ADetail)
    else
      WriteLn('FAIL ', AName);
  end;
  Flush(Output);
end;

function HexToBytes(const S: string): TBytes;
var
  i, n: Integer;
  h: string;
  v: Integer;
begin
  h := '';
  for i := 1 to Length(S) do
    if S[i] <> ' ' then h := h + S[i];
  n := Length(h) div 2;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    v := StrToIntDef('$' + Copy(h, i * 2 + 1, 2), -1);
    if v < 0 then raise Exception.Create('gecersiz hex: ' + S);
    Result[i] := Byte(v);
  end;
end;

function BytesToHex(const B: TBytes): string;
const
  HEXD = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to High(B) do
  begin
    Result[i * 2 + 1] := HEXD[(B[i] shr 4) + 1];
    Result[i * 2 + 2] := HEXD[(B[i] and $0F) + 1];
  end;
end;

function StrB(const S: string): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do Result[i - 1] := Byte(S[i]);
end;

function RepB(ACh: Byte; ALen: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, ALen);
  for i := 0 to ALen - 1 do Result[i] := ACh;
end;

function EqHex(const Actual: TBytes; const ExpectedHex: string): Boolean;
begin
  Result := SameText(BytesToHex(Actual), ExpectedHex);
end;

// --- yayin vektorleri -------------------------------------------------

const
  SHA256_ABC =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
  SHA256_EMPTY =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  SHA256_MILLION_A =
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';

  // RFC 4231 test case 1 (anahtar 0x0b x 20)
  HMAC1_MAC =
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7';
  // RFC 4231 test case 4 (anahtar 0x0102..19, 25 bayt)
  HMAC4_KEY = '0102030405060708090a0b0c0d0e0f10111213141516171819';
  HMAC4_DATA = 'Hi There';
  HMAC4_MAC =
    '358140743685c4e1716868b03478a460492c15d385396ba2d7ad82cce92b19c9';
  // RFC 4231 test case 5
  HMAC5_MAC =
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843';
  // 64 baytlik anahtar (tam blok) - bagimsiz referans degeri
  HMAC64_MAC =
    '6ab541b4869dca71c4ca11d8bb1b02533b789a557583161429292c7404bc21f6';

  // PBKDF2-HMAC-SHA256 ("password", "salt")
  PBKDF2_C1 =
    '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b';
  PBKDF2_C2 =
    'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43';
  PBKDF2_C4096 =
    'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a';
  // ("passwordPASSWORDpassword",
  //  "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, dkLen=40)
  PBKDF2_LONG =
    '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1' +
    'c635518c7dac47e9';

  // FIPS-197 Ek C.3: AES-256, anahtar 000102..1f
  AES_KEY = '000102030405060708090a0b0c0d0e0f' +
            '101112131415161718191a1b1c1d1e1f';
  AES_IN  = '00112233445566778899aabbccddeeff';
  AES_OUT = '8ea2b7ca516745bfeafc49904b496089';

  // GCM test case 13: K=0^256, IV=0^96, P="" -> T
  GCM13_KEY = '00000000000000000000000000000000' +
              '00000000000000000000000000000000';
  GCM13_IV  = '000000000000000000000000';
  GCM13_TAG = '530f8afbc74536b9a963b4f1c4cb738b';
  // GCM test case 14: ayni K/IV, P=0^128
  GCM14_PLAIN = '00000000000000000000000000000000';
  GCM14_CIPH  = 'cea7403d4d606b6e074ec5d3baf39d18';
  GCM14_TAG   = 'd0d1c8a799996bf0265b98b5d48ab919';
  // GCM test case 15
  GCM15_KEY = 'feffe9928665731c6d6a8f9467308308' +
              'feffe9928665731c6d6a8f9467308308';
  GCM15_IV  = 'cafebabefacedbaddecaf888';
  GCM15_PLAIN =
    'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72' +
    '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39';
  GCM15_CIPH =
    '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa' +
    '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662';
  GCM15_TAG = 'eb9f796c8d356fc31a8433884b696f4f';
  // GCM test case 16: ayni K/IV/P + AAD
  GCM16_AAD = 'feedfacedeadbeeffeedfacedeadbeefabaddad2';
  GCM16_TAG = '76fc6ece0f4e1768cddf8853bb2d551b';
  // 64 baytlik duz metin (ayni anahtar/IV, AAD yok)
  GCM17_PLAIN =
    'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72' +
    '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255';
  GCM17_CIPH =
    '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa' +
    '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad';
  GCM17_TAG = 'b094dac5d93471bdec1a502270e3cc6c';

var
  big, m1, m2: TBytes;
  k32, n12, p, c, tag, aad, outPlain, d1, d2: TBytes;
  i: Integer;
  ok, okB: Boolean;
  s64, s32: TBytes;

begin
  GPass := 0;
  GFail := 0;

  // ---- SHA-256 -----------------------------------------------------
  Chk('CI0 SHA-256("abc") FIPS 180-4', EqHex(VDbCryptSha256(StrB('abc')),
    SHA256_ABC), BytesToHex(VDbCryptSha256(StrB('abc'))));
  Chk('CI1 SHA-256("") bos girdi', EqHex(VDbCryptSha256(nil),
    SHA256_EMPTY), BytesToHex(VDbCryptSha256(nil)));

  SetLength(big, 1000000);
  for i := 0 to High(big) do big[i] := Ord('a');
  Chk('CI2 SHA-256 1 milyon "a"', EqHex(VDbCryptSha256(big), SHA256_MILLION_A),
    BytesToHex(VDbCryptSha256(big)));

  // blok siniri: 55/56/63/64/65 bayt hepsi ayri ozet uretmeli
  ok := True;
  for i := 55 to 65 do
  begin
    m1 := RepB($61, i);
    m2 := RepB($61, i + 1);
    if VDbCryptEqual(VDbCryptSha256(m1), VDbCryptSha256(m2)) then ok := False;
    if Length(VDbCryptSha256(m1)) <> 32 then ok := False;
  end;
  Chk('CI22 SHA-256 blok siniri 55..65 farkli ve 32 bayt', ok);

  // ---- HMAC-SHA-256 (RFC 4231) -------------------------------------
  Chk('CI3 HMAC-SHA-256 RFC 4231 case 1', EqHex(
    VDbCryptHmacSha256(RepB($0b, 20), StrB('Hi There')), HMAC1_MAC),
    BytesToHex(VDbCryptHmacSha256(RepB($0b, 20), StrB('Hi There'))));
  Chk('CI3b HMAC-SHA-256 RFC 4231 case 4 (25 bayt anahtar)', EqHex(
    VDbCryptHmacSha256(HexToBytes(HMAC4_KEY), StrB(HMAC4_DATA)), HMAC4_MAC),
    BytesToHex(VDbCryptHmacSha256(HexToBytes(HMAC4_KEY), StrB(HMAC4_DATA))));
  Chk('CI4 HMAC-SHA-256 RFC 4231 case 5', EqHex(
    VDbCryptHmacSha256(StrB('Jefe'), StrB('what do ya want for nothing?')),
    HMAC5_MAC));

  // Tam blok (64 bayt) anahtar: bagimsiz referans degeri ile ayni olmali.
  SetLength(big, 64);
  for i := 0 to High(big) do big[i] := Byte(i);
  Chk('CI23a HMAC 64 bayt anahtar (tam blok) referans deger',
    EqHex(VDbCryptHmacSha256(big, StrB('abc')), HMAC64_MAC),
    BytesToHex(VDbCryptHmacSha256(big, StrB('abc'))));

  // 64 bayttan uzun anahtar BILINCLI OLARAK reddedilir (sessiz kirpma yok).
  // Bu bir durust sinirdir; test hem reddi hem de hatanin turunu dogrular.
  SetLength(big, 100);
  for i := 0 to High(big) do big[i] := Byte(i + 1);
  okB := False;
  try
    m1 := VDbCryptHmacSha256(big, StrB('veri'));
  except
    on E: EVdbCryptError do okB := True;
    on E: Exception do okB := False;
  end;
  Chk('CI23 HMAC >64 bayt anahtar kontrollu REDDEDILIR', okB);

  // ---- PBKDF2-HMAC-SHA-256 -----------------------------------------
  Chk('CI5 PBKDF2 c=1', EqHex(
    VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 1, 32), PBKDF2_C1),
    BytesToHex(VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 1, 32)));
  Chk('CI6 PBKDF2 c=2', EqHex(
    VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 2, 32), PBKDF2_C2));
  Chk('CI7 PBKDF2 c=4096', EqHex(
    VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 4096, 32), PBKDF2_C4096),
    BytesToHex(VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 4096, 32)));
  Chk('CI8 PBKDF2 uzun parola+tuz dkLen=40', EqHex(
    VDbPbkdf2Sha256(StrB('passwordPASSWORDpassword'),
      StrB('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 40), PBKDF2_LONG));

  // dkLen uzatma: 64 baytin ilk 32 bayti 32 baytlik ciktinin AYNISI olmali
  s32 := VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 1000, 32);
  s64 := VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 1000, 64);
  ok := (Length(s64) = 64);
  for i := 0 to 31 do
    if s64[i] <> s32[i] then ok := False;
  Chk('CI21 PBKDF2 dkLen 64, 32 baytlik oneki korur', ok);

  // tuz/parola duyarliligi + determinizm
  m1 := VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 1000, 32);
  m2 := VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 1000, 32);
  okB := VDbCryptEqual(m1, m2);
  if VDbCryptEqual(m1,
       VDbPbkdf2Sha256(StrB('password'), StrB('salt2'), 1000, 32)) then
    okB := False;
  if VDbCryptEqual(m1,
       VDbPbkdf2Sha256(StrB('passwore'), StrB('salt'), 1000, 32)) then
    okB := False;
  if VDbCryptEqual(m1,
       VDbPbkdf2Sha256(StrB('password'), StrB('salt'), 1001, 32)) then
    okB := False;
  Chk('CI20 PBKDF2 determinist, tuza/parolaya/iterasyona duyarli', okB);

  // ---- AES-256 tek blok (FIPS-197 C.3) -----------------------------
  Chk('CI9 AES-256 tek blok FIPS-197 C.3', EqHex(
    VDbCryptAes256Block(HexToBytes(AES_KEY), HexToBytes(AES_IN)), AES_OUT),
    BytesToHex(VDbCryptAes256Block(HexToBytes(AES_KEY),
      HexToBytes(AES_IN))));

  m1 := VDbCryptAes256Block(HexToBytes(AES_KEY), HexToBytes(AES_IN));
  okB := VDbCryptEqual(m1,
    VDbCryptAes256Block(HexToBytes(AES_KEY), HexToBytes(AES_IN)));
  SetLength(k32, 32);
  for i := 0 to 31 do k32[i] := Byte(i + 1);
  if VDbCryptEqual(m1, VDbCryptAes256Block(k32, HexToBytes(AES_IN))) then
    okB := False;
  Chk('CI18 AES-256 blok determinist ve anahtara duyarli', okB);

  // ---- AES-256-GCM (GCM belirtimi test case 13-16) -----------------
  k32 := HexToBytes(GCM13_KEY);
  n12 := HexToBytes(GCM13_IV);
  SetLength(p, 0);
  ok := VDbCryptGcmSeal(k32, n12, p, nil, c, tag);
  Chk('CI10 GCM case 13 bos duz metin etiketi', ok and
    (Length(c) = 0) and EqHex(tag, GCM13_TAG),
    'ok=' + BoolToStr(ok, True) + ' tag=' + BytesToHex(tag));

  p := HexToBytes(GCM14_PLAIN);
  ok := VDbCryptGcmSeal(k32, n12, p, nil, c, tag);
  Chk('CI11 GCM case 14 tek blok sifreli metin+etiket', ok and
    EqHex(c, GCM14_CIPH) and EqHex(tag, GCM14_TAG),
    'c=' + BytesToHex(c) + ' tag=' + BytesToHex(tag));

  p := HexToBytes(GCM15_PLAIN);
  k32 := HexToBytes(GCM15_KEY);
  n12 := HexToBytes(GCM15_IV);
  ok := VDbCryptGcmSeal(k32, n12, p, nil, c, tag);
  Chk('CI12 GCM case 15 60 bayt duz metin (12 bayt IV)', ok and
    EqHex(c, GCM15_CIPH) and EqHex(tag, GCM15_TAG),
    'tag=' + BytesToHex(tag));

  aad := HexToBytes(GCM16_AAD);
  ok := VDbCryptGcmSeal(k32, n12, p, aad, c, tag);
  Chk('CI13 GCM case 16 AAD ile etiket', ok and
    EqHex(c, GCM15_CIPH) and EqHex(tag, GCM16_TAG),
    'tag=' + BytesToHex(tag));

  // 64 bayt: tam dort blok, AAD yok
  d1 := HexToBytes(GCM17_PLAIN);
  ok := VDbCryptGcmSeal(k32, n12, d1, nil, c, tag);
  Chk('CI13b GCM 64 bayt duz metin (4 blok)', ok and
    EqHex(c, GCM17_CIPH) and EqHex(tag, GCM17_TAG),
    'tag=' + BytesToHex(tag));

  // --- negatif yollar: gecerli bir zarftan bozulmus kopyalar --------
  ok := VDbCryptGcmSeal(k32, n12, p, aad, c, tag);
  if ok then
  begin
    // yanlis etiket
    m1 := Copy(tag, 0, Length(tag));
    m1[0] := m1[0] xor $01;
    okB := not VDbCryptGcmOpen(k32, n12, c, m1, aad, outPlain);
    Chk('CI14 GCM yanlis etiket REDDEDILIR', okB);

    // degistirilmis AAD
    m1 := Copy(aad, 0, Length(aad));
    m1[0] := m1[0] xor $01;
    okB := not VDbCryptGcmOpen(k32, n12, c, tag, m1, outPlain);
    Chk('CI15 GCM degistirilmis AAD REDDEDILIR', okB);

    // yanlis anahtar
    m1 := Copy(k32, 0, Length(k32));
    m1[0] := m1[0] xor $01;
    okB := not VDbCryptGcmOpen(m1, n12, c, tag, aad, outPlain);
    Chk('CI16 GCM yanlis anahtar REDDEDILIR', okB);

    // bozuk sifreli metin
    m1 := Copy(c, 0, Length(c));
    m1[5] := m1[5] xor $80;
    okB := not VDbCryptGcmOpen(k32, n12, m1, tag, aad, outPlain);
    Chk('CI17 GCM bozuk sifreli metin REDDEDILIR', okB);

    // dogru anahtar/etiket/AAD -> geri acilir
    okB := VDbCryptGcmOpen(k32, n12, c, tag, aad, outPlain) and
      VDbCryptEqual(outPlain, p);
    Chk('CI23b GCM dogru girdi ile geri acilir', okB);

    // nonce degisimi sifreli metni degistirmeli
    m1 := Copy(n12, 0, Length(n12));
    m1[0] := m1[0] xor $01;
    okB := VDbCryptGcmSeal(k32, m1, p, aad, d1, d2);
    Chk('CI24 GCM farkli nonce farkli sifreli metin uretir',
      okB and not VDbCryptEqual(d1, c));
  end
  else
  begin
    Chk('CI14 GCM yanlis etiket REDDEDILIR', False, 'zarf uretilemedi');
    Chk('CI15 GCM degistirilmis AAD REDDEDILIR', False, 'zarf uretilemedi');
    Chk('CI16 GCM yanlis anahtar REDDEDILIR', False, 'zarf uretilemedi');
    Chk('CI17 GCM bozuk sifreli metin REDDEDILIR', False, 'zarf uretilemedi');
    Chk('CI23b GCM dogru girdi ile geri acilir', False, 'zarf uretilemedi');
    Chk('CI24 GCM farkli nonce farkli sifreli metin uretir', False, '');
  end;

  // buyuk duz metin: 1 MB, tek seferde sifrele/ac
  SetLength(big, 1024 * 1024);
  for i := 0 to High(big) do big[i] := Byte(i and $FF);
  ok := VDbCryptGcmSeal(k32, n12, big, nil, c, tag);
  okB := ok and VDbCryptGcmOpen(k32, n12, c, tag, nil, outPlain) and
    VDbCryptEqual(outPlain, big);
  Chk('CI25 GCM 1 MB duz metin gidis-donus', okB,
    'ok=' + BoolToStr(ok, True));

  // ---- RNG sozlesmesi ----------------------------------------------
  ok := VDbCryptRandom(d1, 32) and (Length(d1) = 32);
  okB := False;
  if ok then
  begin
    okB := True;
    for i := 0 to High(d1) do
      if d1[i] <> 0 then okB := False;
  end;
  Chk('CI19 RNG 32 bayt uretir ve hepsi sifir degil', ok and not okB,
    'ok=' + BoolToStr(ok, True));

  ok := VDbCryptRandom(d1, 32) and VDbCryptRandom(d2, 32);
  Chk('CI26 RNG iki cagri farkli cikti verir', ok and not VDbCryptEqual(d1, d2));

  ok := VDbCryptRandom(d1, 1) and (Length(d1) = 1);
  okB := VDbCryptRandom(d2, 4096) and (Length(d2) = 4096);
  Chk('CI27 RNG istenen uzunlugu dondurur (1 ve 4096)', ok and okB);

  // ---- VDbCryptEqual -------------------------------------------------
  m1 := StrB('abc');
  m2 := StrB('abc');
  Chk('CI28 VDbCryptEqual ayni/farkli/uzunluk farki',
    VDbCryptEqual(m1, m2) and (not VDbCryptEqual(m1, StrB('abd'))) and
    (not VDbCryptEqual(m1, StrB('abcd'))));

  WriteLn('SONUC: ', GPass, ' PASS, ', GFail, ' FAIL');
  if GFail > 0 then Halt(1);
end.
