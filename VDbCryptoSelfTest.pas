unit VDbCryptoSelfTest;
{ VDbCryptoSelfTest - ADR K5: saglayici-basimsiz Known-Answer testleri.

   K5 madde 1 geregi bu birim YALNIZ VDbCryptoProvider + VDbCryptoTypes
   kullanir; somut saglayici birimlerini (OpenSSL/builtin) HIC import
   etmez - testler sozlesme fonksiyonlari uzerinden kosar. Runner
   zinciri (tests\crypto_selftest) iki somut birimi de kullanmak
   ZORUNDA oldugundan derlemeye dahil eder (K5 madde 5).

   Vektor kaynagi (hepsi kamuya acik standart vektor; sabitler
   tests\crypto_kat birimlerinden ve birincil kaynaklardan alindi,
   hafizadan YAZILMADI - R-3):
   - SHA-256: FIPS 180-4 (bos girdi ve "abc"); kat_sha256.pas ile ayni.
   - HMAC-SHA-256: RFC 4231 Test Case 1, 2, 6; kat_hmac_sha256.pas ile
     ayni. Case 6 (131 baytlik anahtar) yalnizca capHmacKeyOver64'i
     olan saglayicida kosar - builtin'de SKIP (bilinen borc, ADR 6).
   - AES-256-GCM: NIST SP 800-38D ornek tuple'lari; ct/tag degerleri
     repo KAT'iyla (kat_aes256gcm.pas) BIREBIR ayni kaynaktan: bagimsiz
     OpenSSL hesabi, NIST CAVP capraz-kontrolu TODO (KAT header'i).
     V2 = bos AAD; V3 = ayni key/iv/PT + 20B AAD (ct ayni, tag farkli -
     AAD'in tag'e bagliligini ayiran vektor). Seal V2, seal V3,
     open V3 (pozitif), tag-flip negatif.
   - PBKDF2-HMAC-SHA-256: RFC 7914 bolum 11 "passwd/salt" c=1
     dkLen=64 vektoru (rfc-editor.org 2026-11-13'te dogrulandi; Python
     hashlib ile capraz-kontrol edildi).
   - Argon2id: RFC 9106 test vektoru 3 (t=3, m=32 KiB, p=4, tag=32);
     kat_argon2id.pas ile ayni girdiler. Yalnizca builtin kosar:
     OpenSSL 1.1.1/3.x EVP sozlesmesinde Argon2id yoktur (K6).
   - AES-256 blok: FIPS 197 ek C.3. Yalnizca builtin kosar - K6 sembol
     setine BILEREK ECB sembolu eklenmedi.
   - Rastgele duman (K5 madde 2): iki 32-baytlik cekis farkli olmali;
     kalite kontrolu degil, "calisiyor mu" kontroludur.

   Yetenek tabancu: capability eksikse vektor SKIP isaretlenir - SKIP
   basarisizlik sayilmaz; FAIL sayaci K5 madde 3 geregi 0 olmali
   (SKIP'ler logda gerekcesiyle gorunur).
   Buradaki sabitler public test vektorleridir; gizli anahtar/sifre
   ICERMEZ. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, VDbCryptoTypes, VDbCryptoProvider;

{ K5 madde 3: ALog vektor vektor PASS/FAIL/SKIP satirlari + ozet;
  Result = (FAIL sayaci == 0). AProvider nil olamaz. }
function VDbCryptoSelfTestRun(AProvider: TVDbCryptoProvider;
  out ALog: string): Boolean;

implementation

const
  { --- public KAT vektor sabitleri (kaynak: ust blok + crypto_kat) --- }
  VEC_AES_KEY =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
  VEC_AES_PT = '00112233445566778899aabbccddeeff';
  VEC_AES_CT = '8ea2b7ca516745bfeafc49904b496089';

  VEC_SHA_ABC = '616263';
  VEC_SHA_ABC_DIGEST =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
  VEC_SHA_EMPTY_DIGEST =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  VEC_HMAC1_KEY  = '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b';
  VEC_HMAC1_DATA = '4869205468657265'; { "Hi There" }
  VEC_HMAC1_TAG  =
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7';
  VEC_HMAC2_KEY  = '4a656665'; { "Jefe" }
  VEC_HMAC2_DATA =
    '7768617420646f2079612077616e7420666f72206e6f7468696e673f';
  VEC_HMAC2_TAG  =
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843';
  VEC_HMAC6_KEY  =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
    'aaaaaa';  { 4x64+6 = 262 hex = 131 bayt 0xAA — RFC 4231 Case 6 }
  VEC_HMAC6_DATA =
    '54657374205573696e67204c6172676572205468616e20426c6f636b2d53697a' +
    '65204b6579202d2048617368204b6579204669727374';
  VEC_HMAC6_TAG  =
    '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54';

  VEC_PBK_PASS = '706173737764';     { "passwd" — RFC 7914 bolum 11 girdisi }
  VEC_PBK_SALT = '73616c74';         { "salt" }
  VEC_PBK_TAG  =
    '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc' +
    '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783';

  VEC_GCM_KEY    =
    'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308';
  VEC_GCM_IV     = 'cafebabefacedbaddecaf888';
  VEC_GCM_AAD    = 'feedfacedeadbeeffeedfacedeadbeefabaddad2';
  VEC_GCM_PT     = 'd9313225f88406e5a55909c5aff5269a86a7a953';
  VEC_GCM_CT     = '522dc1f099567d07f47f37a32a84427d643a8cdc';
  VEC_GCM_TAG_V2 = 'ea0c314d58d83c6c238093de1612a4de';
  VEC_GCM_TAG_V3 = '10501bc85651ae8f4176d6c5a5ea9f3f';

  VEC_ARGON_TAG  =
    '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659';

type
  TSelfTestRec = record
    Lines: TStringList;
    Pass, Fail, Skip: Integer;
    Provider: TVDbCryptoProvider;
  end;

function HexToBytes(const H: string): TBytes;
var
  i, n, v: Integer;
  c: Char;
begin
  n := Length(H);
  if (n mod 2) <> 0 then
    raise EVdbCryptoError.Create('hex vektor uzunlugu tek',
      VDB_CRYPTO_E_INTERNAL);
  SetLength(Result, n div 2);
  for i := 1 to n div 2 do
  begin
    v := 0;
    c := UpCase(H[(i - 1) * 2 + 1]);
    if (c >= '0') and (c <= '9') then v := Ord(c) - Ord('0')
    else if (c >= 'A') and (c <= 'F') then v := Ord(c) - Ord('A') + 10
    else raise EVdbCryptoError.Create('gecsiz hex vektor',
      VDB_CRYPTO_E_INTERNAL);
    v := v shl 4;
    c := UpCase(H[(i - 1) * 2 + 2]);
    if (c >= '0') and (c <= '9') then Inc(v, Ord(c) - Ord('0'))
    else if (c >= 'A') and (c <= 'F') then Inc(v, Ord(c) - Ord('A') + 10)
    else raise EVdbCryptoError.Create('gecsiz hex vektor',
      VDB_CRYPTO_E_INTERNAL);
    Result[i - 1] := Byte(v);
  end;
end;

function BytesToHexLower(const B: TBytes): string;
const
  DIGITS: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to High(B) do
  begin
    Result[i * 2 + 1] := DIGITS[B[i] shr 4];
    Result[i * 2 + 2] := DIGITS[B[i] and $0F];
  end;
end;

procedure NoteOk(var R: TSelfTestRec; const AName: string);
begin
  Inc(R.Pass);
  R.Lines.Add('PASS ' + AName);
end;

procedure NoteSkip(var R: TSelfTestRec; const AName, AWhy: string);
begin
  Inc(R.Skip);
  R.Lines.Add('SKIP ' + AName + ' - ' + AWhy);
end;

procedure NoteBad(var R: TSelfTestRec; const AName, ADetail: string);
begin
  Inc(R.Fail);
  R.Lines.Add('FAIL ' + AName + ' - ' + ADetail);
end;

{ Tek vektorluk esitlik kontrolu (sayaclari ExpectEq yonetir). }
procedure ExpectEq(var R: TSelfTestRec; const AName, AWant, AGot: string);
begin
  if SameText(AWant, AGot) then NoteOk(R, AName)
  else NoteBad(R, AName, 'beklenen=' + AWant + ' alinan=' + AGot);
end;

function MakeFiller(ByteVal: Byte; ALen: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, ALen);
  for i := 0 to ALen - 1 do
    Result[i] := ByteVal;
end;

function VDbCryptoSelfTestRun(AProvider: TVDbCryptoProvider;
  out ALog: string): Boolean;
var
  R: TSelfTestRec;
  caps: TVDbCryptoCaps;

  procedure ScrubBytes(var B: TBytes);
  var
    i: Integer;
  begin
    for i := 0 to High(B) do B[i] := 0;
    B := nil;
  end;

  { --- vektor govdeleleri: exception = FAIL (mesajiyla) --- }
  procedure DoShaEmpty;
  var
    dig: TBytes;
  begin
    try
      dig := R.Provider.HashSHA256(nil);
      ExpectEq(R, 'sha256/empty', VEC_SHA_EMPTY_DIGEST, BytesToHexLower(dig));
    except
      on E: Exception do
        NoteBad(R, 'sha256/empty', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(dig);
  end;

  procedure DoShaAbc;
  var
    dig, data: TBytes;
  begin
    try
      data := HexToBytes(VEC_SHA_ABC);
      dig := R.Provider.HashSHA256(data);
      ExpectEq(R, 'sha256/abc', VEC_SHA_ABC_DIGEST, BytesToHexLower(dig));
    except
      on E: Exception do
        NoteBad(R, 'sha256/abc', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(dig);
    ScrubBytes(data);
  end;

  procedure DoHmac(const AName, AKeyHex, ADataHex, ATagHex: string);
  var
    dig, k, d: TBytes;
  begin
    try
      k := HexToBytes(AKeyHex);
      d := HexToBytes(ADataHex);
      dig := R.Provider.HmacSHA256(k, d);
      ExpectEq(R, AName, ATagHex, BytesToHexLower(dig));
    except
      on E: Exception do
        NoteBad(R, AName, E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(dig);
    ScrubBytes(k);
    ScrubBytes(d);
  end;

  procedure DoPbkdf2;
  var
    dig, p, s: TBytes;
  begin
    try
      p := HexToBytes(VEC_PBK_PASS);
      s := HexToBytes(VEC_PBK_SALT);
      dig := R.Provider.Pbkdf2Sha256(p, s, 1, 64);
      ExpectEq(R, 'pbkdf2-sha256/rfc7914.c1', VEC_PBK_TAG,
        BytesToHexLower(dig));
    except
      on E: Exception do
        NoteBad(R, 'pbkdf2-sha256/rfc7914.c1', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(dig);
    ScrubBytes(p);
    ScrubBytes(s);
  end;

  procedure DoAesBlock;
  var
    dig, k, b: TBytes;
  begin
    try
      k := HexToBytes(VEC_AES_KEY);
      b := HexToBytes(VEC_AES_PT);
      dig := R.Provider.Aes256Block(k, b);
      ExpectEq(R, 'aes256-block/fips197.C3', VEC_AES_CT, BytesToHexLower(dig));
    except
      on E: Exception do
        NoteBad(R, 'aes256-block/fips197.C3', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(dig);
    ScrubBytes(k);
    ScrubBytes(b);
  end;

  { GCM seal: istenen ct+tag'i dogrular; AAD girisi cagiran verir. }
  procedure DoGcmSeal(const AName, AAadHex, ATagHex: string);
  var
    k, n, a, pt, gotct, gottag: TBytes;
    ok: Boolean;
  begin
    try
      k := HexToBytes(VEC_GCM_KEY);
      n := HexToBytes(VEC_GCM_IV);
      if AAadHex = '' then a := nil else a := HexToBytes(AAadHex);
      pt := HexToBytes(VEC_GCM_PT);
      ok := R.Provider.AeadSeal(k, n, pt, a, gotct, gottag);
      if not ok then
        NoteBad(R, AName + ' (seal False)', 'AeadSeal False dondu')
      else
      begin
        ExpectEq(R, AName + '.ct', VEC_GCM_CT, BytesToHexLower(gotct));
        ExpectEq(R, AName + '.tag', ATagHex, BytesToHexLower(gottag));
      end;
    except
      on E: Exception do
        NoteBad(R, AName, E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(k);
    ScrubBytes(n);
    ScrubBytes(a);
    ScrubBytes(pt);
    ScrubBytes(gotct);
    ScrubBytes(gottag);
  end;

  procedure DoGcmOpen;
  var
    k, n, a, ct, tg, plain: TBytes;
  begin
    try
      k := HexToBytes(VEC_GCM_KEY);
      n := HexToBytes(VEC_GCM_IV);
      a := HexToBytes(VEC_GCM_AAD);
      ct := HexToBytes(VEC_GCM_CT);
      tg := HexToBytes(VEC_GCM_TAG_V3);
      if not R.Provider.AeadOpen(k, n, ct, tg, a, plain) then
        NoteBad(R, 'gcm/open-v3', 'dogru tag reddedildi')
      else
        ExpectEq(R, 'gcm/open-v3.plain', VEC_GCM_PT, BytesToHexLower(plain));
    except
      on E: Exception do
        NoteBad(R, 'gcm/open-v3', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(k);
    ScrubBytes(n);
    ScrubBytes(a);
    ScrubBytes(ct);
    ScrubBytes(tg);
    ScrubBytes(plain);
  end;

  { Negatif: tag'in ilk baytini cevir -> red + Plain bos birakilmali
    (sozlesme: BASELINE 5 satir 76 anlamsal kopyasi). }
  procedure DoGcmTamper;
  var
    k, n, a, ct, tg, bad, plain: TBytes;
  begin
    try
      k := HexToBytes(VEC_GCM_KEY);
      n := HexToBytes(VEC_GCM_IV);
      a := HexToBytes(VEC_GCM_AAD);
      ct := HexToBytes(VEC_GCM_CT);
      tg := HexToBytes(VEC_GCM_TAG_V3);
      bad := tg;
      bad[0] := bad[0] xor $01;
      plain := MakeFiller($5A, 32); { kasarli baslangic: red bosaltmali }
      if R.Provider.AeadOpen(k, n, ct, bad, a, plain) then
        NoteBad(R, 'gcm/tamper-red', 'yanlis tag KABUL EDILDI')
      else if Length(plain) <> 0 then
        NoteBad(R, 'gcm/tamper-red', 'red sonrasi plain bos birakilmadi')
      else
        NoteOk(R, 'gcm/tamper-red');
    except
      on E: Exception do
        NoteBad(R, 'gcm/tamper-red', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(k);
    ScrubBytes(n);
    ScrubBytes(a);
    ScrubBytes(ct);
    ScrubBytes(tg);
    ScrubBytes(bad);
    ScrubBytes(plain);
  end;

  procedure DoArgon2id;
  var
    dig, pwd, salt, sec, ad: TBytes;
  begin
    try
      pwd := MakeFiller($01, 32);
      salt := MakeFiller($02, 16);
      sec := MakeFiller($03, 8);
      ad := MakeFiller($04, 12);
      if not R.Provider.Argon2id(pwd, salt, sec, ad, 3, 32, 4, 32, dig) then
      begin
        NoteBad(R, 'argon2id/rfc9106.v3', 'Argon2id False dondu');
        Exit;
      end;
      ExpectEq(R, 'argon2id/rfc9106.v3', VEC_ARGON_TAG, BytesToHexLower(dig));
    except
      on E: Exception do
        NoteBad(R, 'argon2id/rfc9106.v3', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(dig);
    ScrubBytes(pwd);
    ScrubBytes(salt);
    ScrubBytes(sec);
    ScrubBytes(ad);
  end;

  { K5 madde 2 duman kontrolu: kalite degil, "calisiyor mu". }
  procedure DoRandomSmoke;
  var
    b1, b2: TBytes;
  begin
    try
      if not R.Provider.RandomBytes(b1, 32) then
      begin
        NoteBad(R, 'random/smoke', 'RandomBytes False dondu');
        Exit;
      end;
      if Length(b1) <> 32 then
      begin
        NoteBad(R, 'random/smoke', 'uzunluk 32 degil');
        Exit;
      end;
      if not R.Provider.RandomBytes(b2, 32) then
      begin
        NoteBad(R, 'random/smoke', 'ikinci cekis False dondu');
        Exit;
      end;
      if (Length(b2) <> 32) or (BytesToHexLower(b1) = BytesToHexLower(b2)) then
        NoteBad(R, 'random/smoke', 'uzunluk ya da iki cekis birebir ayni')
      else
        NoteOk(R, 'random/smoke');
    except
      on E: Exception do
        NoteBad(R, 'random/smoke', E.ClassName + ': ' + E.Message);
    end;
    ScrubBytes(b1);
    ScrubBytes(b2);
  end;

begin
  Result := False;
  if AProvider = nil then
  begin
    ALog := 'FAIL selftest - saglayici nil';
    Exit;
  end;
  R.Lines := TStringList.Create;
  try
    R.Pass := 0;
    R.Fail := 0;
    R.Skip := 0;
    R.Provider := AProvider;
    caps := AProvider.Capabilities;
    R.Lines.Add('selftest: saglayici=' + AProvider.Name);

    DoShaEmpty;
    DoShaAbc;
    DoHmac('hmac-sha256/rfc4231.1', VEC_HMAC1_KEY, VEC_HMAC1_DATA,
      VEC_HMAC1_TAG);
    DoHmac('hmac-sha256/rfc4231.2', VEC_HMAC2_KEY, VEC_HMAC2_DATA,
      VEC_HMAC2_TAG);
    if capHmacKeyOver64 in caps then
      DoHmac('hmac-sha256/rfc4231.6-longkey', VEC_HMAC6_KEY, VEC_HMAC6_DATA,
        VEC_HMAC6_TAG)
    else
      NoteSkip(R, 'hmac-sha256/rfc4231.6-longkey',
        'capHmacKeyOver64 yok (VDbCrypt >64B anahtari reddeder - ADR6 borc)');
    DoPbkdf2;
    if capAes256Block in caps then
      DoAesBlock
    else
      NoteSkip(R, 'aes256-block/fips197.C3',
        'capAes256Block yok (K6 sembol setine ECB sembolu eklenmedi)');

    DoGcmSeal('gcm/seal-v2', '', VEC_GCM_TAG_V2);
    DoGcmSeal('gcm/seal-v3', VEC_GCM_AAD, VEC_GCM_TAG_V3);
    DoGcmOpen;
    DoGcmTamper;

    if capArgon2id in caps then
      DoArgon2id
    else
      NoteSkip(R, 'argon2id/rfc9106.v3',
        'capArgon2id yok (OpenSSL EVP sozlesmesinde Argon2id yok)');

    DoRandomSmoke;

    R.Lines.Add(Format('ozet: PASS=%d FAIL=%d SKIP=%d',
      [R.Pass, R.Fail, R.Skip]));
    ALog := R.Lines.Text;
    Result := R.Fail = 0;
  finally
    R.Lines.Free;
  end;
end;

end.
