program gen_fixtures;
{ gen_fixtures - VDB kriptografik UYUMLULUK FIXTURE ureticisi (Goc Plani Adim 2A)

  AMAC: dcpcrypt -> OpenSSL goci (Adim 2B) ONCESINDE, bugunku (goc-oncesi)
  kodun urettiği eski-format dosyalarini bit duzeyinde sabitlemek. Goc
  sonrasi `gen_fixtures verify` bu fixture'lari COZEMEZSE GOC KIRICIDIR.

  !! TEST FIXTURE — PRODUCTION ENTROPY DEGIL !!
  Buradaki tum parola/tuz/nonce degerleri SABITTEST DEGERLERIDIR ve kasıtlı
  olarak CSPRNG yerine sabitlenmistir (tekrar kosurulabilirlik icin). Bu
  degerler HICBIR gercek veride kullanilmaz/kullanilmamali.

  Ciktilar (exe'nin yanindaki fixtures\ altina yazilir):
    key_v1_pbkdf2.key        v1 (.key, PBKDF2-SHA256, iter=1000) - ORTUK uretim:
                             bugun v1 YAZILMIYOR; VDbKeyFileRead'in v1 okuma
                             yolunun belgelenmis basligina gore elle kurulur ve
                             VDbKeyFileRead ile ACCEPT dogrulanir. Deterministik.
    key_v2_argon2id.key      v2 (.key, Argon2id t=3 m=65536 p=4) - SABIT test
                             tuz ile, VDbKeyFileWrite ile BIREBIR ayni bicimde
                             elle kurulur. Deterministik.
    key_v2_argon2id_write.key bugunku VDbKeyFileWrite gercek cikisi (RASTGELE
                             tuz icerir -> byte-reprodüksiyon beklenmez; verify
                             modu VDbKeyFileRead round-trip ile dogrular).
    page_envelope_v1.bin     sayfa zarfi nonce(12)|ct(4096)|tag(16)=4124B,
                             AAD='VDB3PG'|LE32(pageno)|salt(16). Nonce SABIT
                             tutulmak icin ham VDbCryptGcmSeal ile elle
                             kurulur (VDbPageSeal'in o nonce'la üretecegi
                             baytlarla birebir aynidir); VDbPageOpen ile
                             round-trip dogrulanir. Deterministik.
    record_envelope_v1.bin   kayit zarfi 'VDBAEAD1'|nonce(12)|ct|tag(16),
                             sabit nonce ile VDbCryptAeadSeal. Deterministik.
    record_legacy_v1.bin     eski CTR+HMAC zarfi (VDbCryptEncryptLegacy,
                             RASTGELE IV -> verify modda VDbCryptDecrypt ile
                             fonksiyonel dogrulama; sha256 pinlenmez).
    scram_verifier.txt       SCRAM-SHA-256 dogrulayicisi, VDbPgWire.AddUser
                             turetim formuluyle (VDbPbkdf2Sha256 + HMAC
                             'Client Key' + SHA256 + HMAC 'Server Key'),
                             sabit test tuz, iter=15000 (AddUset clamp tabani).
                             Deterministik.
    store_odb_v1\fixture.odb gercek sifreli depo (TVdbPageEngine, parola ->
                             PBKDF2-200k, sayfa zarfi) + .wal/.gen yan
                             dosyalari. DBID/nonce/LSN RNG icerir ->
                             byte-reprodüksiyon BEKLENMEZ; kapı: ayni parola
                             ile AC + satirlari dogrula (verify modu).

  Kullanim:
    gen_fixtures            fixture'lari uretir + kendi icinde dogrular
    gen_fixtures gen        ayni sey (agayik adlandirma)
    gen_fixtures verify     mevcut fixture dosyalarini cozer; PASS/FAIL basar
  Cikis kodu: basarisiz kontrol sayisi (0 = hesi gecti).

  Derleme (FPC 3.2.4 i386-win32, cwd = bu klasor; -Fu bayraklari yola BITISIK
  yazilmali, bosluklu bicim sessizce bozuyor):
    fpc -MObjFPC -Scghi -O1 -g -l -vewnhibq -FuD:\veritabani -FuD:\veritabani\dcpcrypt -FuD:\veritabani\dcpcrypt\Ciphers -FuD:\veritabani\dcpcrypt\Hashes "-FUD:\veritabani\tests\crypto_fixtures\lib" gen_fixtures.lpr

  Argon2 fixture (t=3, m=65536 KiB, p=4) saf Pascal'da birkac saniye surer;
  PBKDF2-200000 (store) de saniye mertebesindedir. Bu NORMALDIR.

  sha256 pinleri: `gen` modunun bastigi PIN_* satirlari asagidaki sabitlere
  yapistirilir; `verify` hem fonksiyonel round-trip hem de pin karsilastirmasi
  yapar. Pin 'UNPINNED' ise o kontrol SKIP edilir (henuz ilk uretim olmamis). }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  VDbCrypt, VDbKdf, VDbPageCrypto, VDbPageEngine;

{ ======================= TEST SABITLERI =======================
  !! TEST fixture, production entropy degil — bkz. dosya basi. ============ }
const
  PW_MASTER = 'VdbFixt!2026';        { .key v1 + v2 parolasi (>=8 karakter) }
  PW_WRONG  = 'VdbFixt!2026YANLIS';  { negatif test parolasi (v1 icin ucuz) }
  PW_STORE  = 'VdbFixt!2026store';   { store_odb_v1 parolasi }
  V1_ITER   = 1000;                  { v1 iterasyonu: VDbKeyFileRead alt siniri }

  PAGE_PAGENO = 7;                   { AAD'e baglanan sayfa numarasi }

  SCRAM_USER = 'vdbtest';
  SCRAM_PASS = 'scram-fixture-pass';
  SCRAM_ITER = 15000;   { VDbPgWire.AddUser clamp tabani (>=15000, <=1000000) }

  { sha256 pinleri — `gen_fixtures gen` cikisindaki PINS blogundan yapistirilir.
    Goc sonrasi (2B) bu hash'ler degisti ise KDF/zarf kodu KIRILMIS demektir. }
  PIN_KEY_V1_SHA256      = 'da99477949f4df280c94e8523fa36e9290015c63d33cc901714af7779de10508';
  PIN_KEY_V2_SHA256      = 'bb781020f2a51434ffb5d1f2471665b6dcbc78aaa567c55d8d6ad21da63829b7';
  PIN_KEY_V2_KEY_HEX     = 'f85e028352a0390777b20ecfbd10d1f2ffa9f74d52095c86e61da4e5cc796d48';
    { handcrafted key_v2_argon2id.key dosyasindan Argon2id ile tureyen 32B anahtar }
  PIN_PAGE_SHA256        = 'bbbfbf6c9d12439e831296854e510d19c6e9903465198a327b69603f2c995dce';
  PIN_REC_AEAD_SHA256    = '5adf0d8bcab20c472dc27368f390c3f7ea3e93ccb8173046d5ac49ce6b8294ef';
  PIN_SCRAM_SHA256       = '68d758a8ea0d813b3b18efff6cf71e58205b10830bba4265a6bd81d36398e595';

  STORE_DIR_NAME = 'store_odb_v1';
  STORE_DB_NAME  = 'fixture.odb';

type
  TRow = record
    Key: QWord;
    Val: TBytes;
  end;
  TRowArray = array of TRow;

var
  GPass, GFail: Integer;
  FxD: string; { fixtures dizini, yolu ayiran ile biter }

{ ======================= kucuk yardimcilar ======================= }

function Pat(Count: Integer; Seed: Byte): TBytes;
{ Deterministik desen baytlari — TEST fixture, production entropy degil. }
var
  i: Integer;
begin
  SetLength(Result, Count);
  for i := 0 to Count - 1 do
    Result[i] := Byte((Seed + i) and $FF);
end;

function StrB(const S: string): TBytes;
begin
  Result := VDbCryptStrToBytes(S);
end;

function B2Hex(const B: TBytes): string;
var
  local: TBytes;
  i: Integer;
begin
  local := B; { i386 acik-dizi parametresi kuiskisina karsi yereel kopya }
  Result := '';
  for i := 0 to High(local) do
    Result := Result + LowerCase(IntToHex(local[i], 2));
end;

function B64Enc(const Input: TBytes): string;
const
  CH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  B: TBytes;
  i, n: Integer;
  v: LongWord;
begin
  B := Input;
  Result := '';
  i := 0;
  n := Length(B);
  while i < n do
  begin
    v := LongWord(B[i]) shl 16;
    if i + 1 < n then v := v or (LongWord(B[i + 1]) shl 8);
    if i + 2 < n then v := v or LongWord(B[i + 2]);
    Result := Result + CH[((v shr 18) and 63) + 1] + CH[((v shr 12) and 63) + 1];
    if i + 1 < n then
      Result := Result + CH[((v shr 6) and 63) + 1]
    else
      Result := Result + '=';
    if i + 2 < n then
      Result := Result + CH[(v and 63) + 1]
    else
      Result := Result + '=';
    Inc(i, 3);
  end;
end;

procedure SaveBin(const Path: string; const Data: TBytes);
var
  f: TFileStream;
  B: TBytes;
begin
  B := Data;
  f := TFileStream.Create(Path, fmCreate);
  try
    if Length(B) > 0 then
      f.WriteBuffer(B[0], Length(B));
  finally
    f.Free;
  end;
end;

function LoadBin(const Path: string): TBytes;
var
  f: TFileStream;
  n: Int64;
begin
  n := 0;
  f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    n := f.Size;
    SetLength(Result, n);
    if n > 0 then
      f.ReadBuffer(Result[0], n);
  finally
    f.Free;
  end;
end;

function Sha256HexFile(const Path: string): string;
var
  B: TBytes;
  h: TBytes;
begin
  B := LoadBin(Path);
  h := VDbCryptSha256(B);
  Result := B2Hex(h);
end;

procedure Ok(const What: string);
begin
  Inc(GPass);
  Writeln('PASS  ', What);
end;

procedure No(const What, Why: string);
begin
  Inc(GFail);
  Writeln('FAIL  ', What, '  -- ', Why);
end;

function EqBytes(const A, B: TBytes): Boolean;
var
  la, lb: TBytes;
  i: Integer;
begin
  la := A;
  lb := B;
  if Length(la) <> Length(lb) then Exit(False);
  for i := 0 to High(la) do
    if la[i] <> lb[i] then Exit(False);
  Result := True;
end;

procedure CheckPin(const Path, Pin: string; const Label_: string);
begin
  if Pin = 'UNPINNED' then
  begin
    Writeln('SKIP  ', Label_, ': sha256 pini tanimli degil');
    Exit;
  end;
  if not FileExists(Path) then
  begin
    No(Label_ + ': sha256 pini', 'dosya yok: ' + Path);
    Exit;
  end;
  if Sha256HexFile(Path) = LowerCase(Pin) then
    Ok(Label_ + ': sha256 pini')
  else
    No(Label_ + ': sha256 pini',
      'dosya byte-duzeyinde degisti (GOC KIRICI olabilir)');
end;

{ ======================= fixture sabit degerleri ======================= }

function SaltV1: TBytes;    begin Result := Pat(16, $A1); end;
function SaltV2: TBytes;    begin Result := Pat(16, $B2); end;
function KeyPg: TBytes;     begin Result := Pat(32, $10); end;
function SaltPg: TBytes;    begin Result := Pat(16, $20); end;
function NoncePg: TBytes;   begin Result := Pat(12, $30); end;
function KeyRec: TBytes;    begin Result := Pat(32, $40); end;
function NonceRec: TBytes;  begin Result := Pat(12, $50); end;
function SaltScram: TBytes; begin Result := Pat(16, $60); end;

function PlainPg: TBytes;
var
  i: Integer;
begin
  SetLength(Result, 4096);
  for i := 0 to 4095 do
    Result[i] := Byte(i * 7 + (i shr 8) * 13 + 1);
end;

function RecPlain: TBytes;
begin
  Result := StrB('VDB fixture kayit duz-metni 0123456789abcdef');
end;

function PageAad(Salt: TBytes; PageNo: LongWord): TBytes;
{ VDbPageCrypto.BuildAad sozlesmesi: 'VDB3PG' | LE32(PageNo) | Salt }
const
  AAD_MAGIC: array[0..5] of AnsiChar = 'VDB3PG';
var
  n: LongWord;
begin
  SetLength(Result, 6 + 4 + Length(Salt));
  Move(AAD_MAGIC[0], Result[0], 6);
  n := PageNo;
  Move(n, Result[6], 4);
  if Length(Salt) > 0 then
    Move(Salt[0], Result[10], Length(Salt));
end;

function StoreRows: TRowArray;
begin
  SetLength(Result, 4);
  Result[0].Key := 1;       Result[0].Val := StrB('vdb-fixture-row-one');
  Result[1].Key := 2;       Result[1].Val := StrB('vdb-fixture-row-two');
  Result[2].Key := 3;       Result[2].Val := StrB('vdb-fixture-row-three');
  Result[3].Key := 1000000; Result[3].Val := Pat(32, $77);
end;

function StoreDbPath: string;
begin
  Result := FxD + STORE_DIR_NAME + PathDelim + STORE_DB_NAME;
end;

{ ======================= uretim yollari ======================= }

procedure GenKeyV1;
{ v1 .key: 'VDBK' | ver=1 | saltLen | iter(LE32) | salt | verifier(32).
  Bugunku kod v1 YAZMIYOR; VDbKeyFileRead'in v1 okuma yolunun belgelenmis
  bicimi burada ORTUK olarak uretilir (TEST fixture, production entropy degil). }
var
  key, verifier, buf, salt: TBytes;
  i: Integer;
begin
  salt := SaltV1;
  key := VDbCryptDeriveKey(PW_MASTER, salt, V1_ITER);
  verifier := VDbCryptVerifier(key);
  SetLength(buf, 10 + Length(salt) + 32);
  buf[0] := Ord('V'); buf[1] := Ord('D'); buf[2] := Ord('B'); buf[3] := Ord('K');
  buf[4] := VDB_KEYFILE_VER;
  buf[5] := Byte(Length(salt));
  for i := 0 to 3 do
    buf[6 + i] := Byte((LongWord(V1_ITER) shr (i * 8)) and $FF);
  Move(salt[0], buf[10], Length(salt));
  Move(verifier[0], buf[10 + Length(salt)], 32);
  SaveBin(FxD + 'key_v1_pbkdf2.key', buf);
end;

function KeyV2Derived: TBytes;
{ Sabit test tuzla Argon2id anahtari (VDbKeyFileWrite ayni primitifi kullanir). }
var
  pw, salt, h: TBytes;
begin
  pw := StrB(PW_MASTER);
  salt := SaltV2;
  if not VDbArgon2id(pw, salt, nil, nil, VDB_ARGON2_TIME, VDB_ARGON2_MEMORY_KIB,
    VDB_ARGON2_LANES, VDB_KEY_LEN, h) or (Length(h) <> VDB_KEY_LEN) then
    raise Exception.Create('Argon2id turetimi basarisiz');
  Result := h;
end;

procedure GenKeyV2Handcrafted;
{ v2 .key: 'VDBK' | ver=2 | saltLen | t(LE32) | m(LE32) | p | salt | verifier(32)
  — VDbKeyFileWrite ile BIREBIR ayni bicim, sabit test tuzla (deterministik). }
var
  key, verifier, buf, salt: TBytes;
  i: Integer;
  t, m: Integer;
begin
  t := VDB_ARGON2_TIME;
  m := VDB_ARGON2_MEMORY_KIB;
  salt := SaltV2;
  key := KeyV2Derived;
  verifier := VDbCryptVerifier(key);
  SetLength(buf, 15 + Length(salt) + 32);
  buf[0] := Ord('V'); buf[1] := Ord('D'); buf[2] := Ord('B'); buf[3] := Ord('K');
  buf[4] := VDB_KEYFILE_VER_ARGON2;
  buf[5] := Byte(Length(salt));
  for i := 0 to 3 do
    buf[6 + i] := Byte((LongWord(t) shr (i * 8)) and $FF);
  for i := 0 to 3 do
    buf[10 + i] := Byte((LongWord(m) shr (i * 8)) and $FF);
  buf[14] := VDB_ARGON2_LANES;
  Move(salt[0], buf[15], Length(salt));
  Move(verifier[0], buf[15 + Length(salt)], 32);
  SaveBin(FxD + 'key_v2_argon2id.key', buf);
end;

procedure GenKeyV2WritePath;
{ Bugunku gercek VDbKeyFileWrite cikisi (RASTGELE salt — verify mod fonksiyonel
  dogrular; sha256 pinlenmez). Goc-oncesi yazim yolunun CANLI kaniti. }
var
  key: TBytes;
  it: Integer;
begin
  if not VDbKeyFileWrite(FxD + 'key_v2_argon2id_write.key', PW_MASTER, key, it) then
    raise Exception.Create('VDbKeyFileWrite basarisiz');
end;

procedure GenPageEnvelope;
{ Sayfa zarfi, sabit nonce: VDbPageSeal'in o nonce ile uretecegi baytlarin
  birebir aynisi (BuildAad sozlesmesi yeniden kullanilir). Deterministik. }
var
  ct, tag, aad, env: TBytes;
begin
  aad := PageAad(SaltPg, PAGE_PAGENO);
  if not VDbCryptGcmSeal(KeyPg, NoncePg, PlainPg, aad, ct, tag) then
    raise Exception.Create('VDbCryptGcmSeal basarisiz');
  if Length(ct) <> 4096 then
    raise Exception.Create('beklenmeyen ct uzunlugu');
  SetLength(env, 12 + 4096 + 16);
  Move(NoncePg[0], env[0], 12);
  Move(ct[0], env[12], 4096);
  Move(tag[0], env[12 + 4096], 16);
  SaveBin(FxD + 'page_envelope_v1.bin', env);
end;

procedure GenRecordAead;
{ Kayit zarfi 'VDBAEAD1'|nonce|ct|tag, sabit nonce ile (deterministik). }
var
  env: TBytes;
begin
  if not VDbCryptAeadSeal(KeyRec, NonceRec, RecPlain, nil, env) then
    raise Exception.Create('VDbCryptAeadSeal basarisiz');
  SaveBin(FxD + 'record_envelope_v1.bin', env);
end;

procedure GenRecordLegacy;
{ Eski CTR+HMAC zarfi (Rastgele IV — verify mod fonksiyonel dogrular). }
var
  env: TBytes;
begin
  if not VDbCryptEncryptLegacy(KeyRec, RecPlain, env) then
    raise Exception.Create('VDbCryptEncryptLegacy basarisiz');
  SaveBin(FxD + 'record_legacy_v1.bin', env);
end;

function ScramText: string;
{ VDbPgWire.AddUser turetim formulu (satirlar ~2349-2379):
    sp       = PBKDF2-HMAC-SHA256(P, salt, iter, 32)
    ck       = HMAC(sp, 'Client Key')
    StoredKey= SHA256(ck)
    ServerKey= HMAC(sp, 'Server Key')
  clamps: iter en az 15000, en cok 1000000 (VDbPgWire.pas satir ~2361-2362).
  Sabit test tuz ile deterministik. }
var
  sp, ck, stored, srvk, salt, pw: TBytes;
  iter: Integer;
begin
  iter := SCRAM_ITER;
  if iter < 15000 then iter := 15000;
  if iter > 1000000 then iter := 1000000;
  pw := StrB(SCRAM_PASS);
  salt := SaltScram;
  sp := VDbPbkdf2Sha256(pw, salt, iter, 32);
  ck := VDbCryptHmacSha256(sp, StrB('Client Key'));
  stored := VDbCryptSha256(ck);
  srvk := VDbCryptHmacSha256(sp, StrB('Server Key'));
  Result :=
    '# VDB SCRAM-SHA-256 verifier fixture - TEST fixture, production entropy degil' + #10 +
    '# Turetim: VDbPgWire.AddUser formulu (PBKDF2-SHA256 + HMAC "Client Key" + SHA256 + HMAC "Server Key")' + #10 +
    '# iter clamp: [15000, 1000000] (VDbPgWire.pas); fixture degeri clamp tabani' + #10 +
    'user=' + SCRAM_USER + #10 +
    'password=' + SCRAM_PASS + #10 +
    'salt_b64=' + B64Enc(salt) + #10 +
    'salt_hex=' + B2Hex(salt) + #10 +
    'iterations=' + IntToStr(iter) + #10 +
    'storedkey_b64=' + B64Enc(stored) + #10 +
    'storedkey_hex=' + B2Hex(stored) + #10 +
    'serverkey_b64=' + B64Enc(srvk) + #10 +
    'serverkey_hex=' + B2Hex(srvk) + #10;
end;

procedure GenScram;
begin
  SaveBin(FxD + 'scram_verifier.txt', StrB(ScramText));
end;

procedure CleanStoreDir;
var
  base: string;
  i: Integer;
  exts: array[0..4] of string;
begin
  ForceDirectories(FxD + STORE_DIR_NAME);
  base := StoreDbPath;
  exts[0] := '';
  exts[1] := '.wal';
  exts[2] := '.gen';
  exts[3] := '.idx';
  exts[4] := '.tmp';
  for i := 0 to High(exts) do
    if FileExists(base + exts[i]) then
      SysUtils.DeleteFile(base + exts[i]);
end;

procedure GenStore;
{ Gercek sifreli depo: parola -> PBKDF2-200000 (VDB_ENC_ITER) -> sayfa zarfi.
  DBID/nonce/LSN RNG icerir; byte-reprodüksiyon beklenmez. }
var
  eng: TVdbPageEngine;
  rows: TRowArray;
  i: Integer;
begin
  CleanStoreDir;
  rows := StoreRows;
  eng := TVdbPageEngine.CreateWithPassword(StoreDbPath, PW_STORE);
  try
    eng.Open(True);
    if not eng.Encrypted then
      raise Exception.Create('depo sifreli acilmadi');
    for i := 0 to High(rows) do
      if not eng.Insert(rows[i].Key, rows[i].Val) then
        raise Exception.Create('Insert basarisiz (key=' + IntToStr(rows[i].Key) + ')');
    if not eng.Commit then
      raise Exception.Create('Commit basarisiz');
    if not eng.Checkpoint then
      raise Exception.Create('Checkpoint basarisiz');
    eng.Close;
  finally
    eng.Free;
  end;
end;

{ ======================= dogrulama yollari ======================= }

procedure VerifyKeyV1;
const
  L = 'key_v1_pbkdf2.key';
var
  p: string;
  key, want: TBytes;
  iter: Integer;
  badKey: TBytes;
  badIter: Integer;
begin
  p := FxD + 'key_v1_pbkdf2.key';
  CheckPin(p, PIN_KEY_V1_SHA256, L);
  if not FileExists(p) then
  begin
    No(L + ': VDbKeyFileRead round-trip', 'dosya yok');
    Exit;
  end;
  try
    if VDbKeyFileRead(p, PW_MASTER, key, iter) then
    begin
      if iter <> V1_ITER then
        No(L + ': VDbKeyFileRead round-trip', 'iter ' + IntToStr(iter) +
          ' != ' + IntToStr(V1_ITER))
      else
      begin
        want := VDbCryptDeriveKey(PW_MASTER, SaltV1, V1_ITER);
        if EqBytes(key, want) then
          Ok(L + ': VDbKeyFileRead ACCEPT v1 + anahtar PBKDF2 ile ayni (iter=1000 clamp-tabani)')
        else
          No(L + ': VDbKeyFileRead round-trip', 'tureyen anahtar dosya dogrulayicisiyla tutmadi');
      end;
    end
    else
      No(L + ': VDbKeyFileRead round-trip', 'dogru parola reddedildi');
    if VDbKeyFileRead(p, PW_WRONG, badKey, badIter) then
      No(L + ': yanlis parola reddi', 'yanlis parola kabul edildi')
    else
      Ok(L + ': yanlis parola reddi');
  except
    on E: Exception do
      No(L + ': VDbKeyFileRead round-trip', 'istisna: ' + E.Message);
  end;
end;

procedure VerifyKeyV2Handcrafted;
const
  L = 'key_v2_argon2id.key';
var
  p: string;
  key: TBytes;
  iter: Integer;
begin
  p := FxD + 'key_v2_argon2id.key';
  CheckPin(p, PIN_KEY_V2_SHA256, L);
  if not FileExists(p) then
  begin
    No(L + ': VDbKeyFileRead round-trip', 'dosya yok');
    Exit;
  end;
  try
    if VDbKeyFileRead(p, PW_MASTER, key, iter) then
    begin
      if (PIN_KEY_V2_KEY_HEX <> 'UNPINNED') and (B2Hex(key) <> LowerCase(PIN_KEY_V2_KEY_HEX)) then
        No(L + ': Argon2id tureyen anahtar pini', 'anahtar baytlari degisti (KDF KIRILDI)')
      else if PIN_KEY_V2_KEY_HEX = 'UNPINNED' then
        Writeln('SKIP  ', L, ': tureyen anahtar pini tanimli degil')
      else
        Ok(L + ': Argon2id tureyen anahtar pini');
      Ok(L + ': VDbKeyFileRead ACCEPT v2 (Argon2id t=3 m=65536 p=4, sabit tuz)');
    end
    else
      No(L + ': VDbKeyFileRead round-trip', 'dogru parola reddedildi');
  except
    on E: Exception do
      No(L + ': VDbKeyFileRead round-trip', 'istisna: ' + E.Message);
  end;
end;

procedure VerifyKeyV2WritePath;
const
  L = 'key_v2_argon2id_write.key';
var
  p: string;
  buf: TBytes;
  key: TBytes;
  iter: Integer;
begin
  p := FxD + 'key_v2_argon2id_write.key';
  if not FileExists(p) then
  begin
    No(L + ': canli VDbKeyFileWrite cikisi', 'dosya yok');
    Exit;
  end;
  try
    buf := LoadBin(p);
    if (Length(buf) < 47) or (buf[0] <> Ord('V')) or (buf[4] <> VDB_KEYFILE_VER_ARGON2) then
    begin
      No(L + ': canli VDbKeyFileWrite cikisi', 'baslik/imza hatali');
      Exit;
    end;
    if VDbKeyFileRead(p, PW_MASTER, key, iter) and (Length(key) = VDB_KEY_LEN) then
      Ok(L + ': VDbKeyFileRead round-trip (rastgele tuz, canli yazim yolu)')
    else
      No(L + ': canli VDbKeyFileWrite cikisi', 'round-trip basarisiz');
  except
    on E: Exception do
      No(L + ': canli VDbKeyFileWrite cikisi', 'istisna: ' + E.Message);
  end;
end;

procedure VerifyPageEnvelope;
const
  L = 'page_envelope_v1.bin';
var
  p: string;
  env, plain: TBytes;
begin
  p := FxD + 'page_envelope_v1.bin';
  CheckPin(p, PIN_PAGE_SHA256, L);
  if not FileExists(p) then
  begin
    No(L + ': VDbPageOpen round-trip', 'dosya yok');
    Exit;
  end;
  try
    env := LoadBin(p);
    if Length(env) <> VDB_ENC_ENVELOPE then
    begin
      No(L + ': VDbPageOpen round-trip',
        'zarf uzunlugu ' + IntToStr(Length(env)) + ' != 4124');
      Exit;
    end;
    if VDbPageOpen(KeyPg, SaltPg, PAGE_PAGENO, env, plain) and
       EqBytes(plain, PlainPg) then
      Ok(L + ': VDbPageOpen cozdü (nonce|ct|tag, AAD=VDB3PG|LE32|salt, sabit nonce)')
    else
      No(L + ': VDbPageOpen round-trip', ' cozme baarisiz veya duz-metin farkli');
    { AAD baglama negatif testi: sayfa numarasi degisirse reddetmeli }
    if VDbPageOpen(KeyPg, SaltPg, PAGE_PAGENO + 1, env, plain) then
      No(L + ': yanlis PageNo reddi (AAD baglama)', 'farkli sayfada cozuldu')
    else
      Ok(L + ': yanlis PageNo reddi (AAD baglama)');
  except
    on E: Exception do
      No(L + ': VDbPageOpen round-trip', 'istisna: ' + E.Message);
  end;
end;

procedure VerifyRecordAead;
const
  L = 'record_envelope_v1.bin';
var
  p: string;
  env, plain: TBytes;
begin
  p := FxD + 'record_envelope_v1.bin';
  CheckPin(p, PIN_REC_AEAD_SHA256, L);
  if not FileExists(p) then
  begin
    No(L + ': VDbCryptAeadOpen round-trip', 'dosya yok');
    Exit;
  end;
  try
    env := LoadBin(p);
    if not VDbCryptIsAead(env) then
    begin
      No(L + ': VDbCryptAeadOpen round-trip', 'VDBAEAD1 imzasi yok');
      Exit;
    end;
    if VDbCryptAeadOpen(KeyRec, env, nil, plain) and EqBytes(plain, RecPlain) then
      Ok(L + ': VDbCryptAeadOpen cozdü (VDBAEAD1, sabit nonce)')
    else
      No(L + ': VDbCryptAeadOpen round-trip', 'cozme baarisiz');
    if VDbCryptDecrypt(KeyRec, env, plain) and EqBytes(plain, RecPlain) then
      Ok(L + ': VDbCryptDecrypt ayni zarfi cozdü (uyusturmasiz)')
    else
      No(L + ': VDbCryptDecrypt uyusturmasiz cozme', 'baarisiz');
  except
    on E: Exception do
      No(L + ': VDbCryptAeadOpen round-trip', 'istisna: ' + E.Message);
  end;
end;

procedure VerifyRecordLegacy;
const
  L = 'record_legacy_v1.bin';
var
  p: string;
  env, plain: TBytes;
begin
  p := FxD + 'record_legacy_v1.bin';
  if not FileExists(p) then
  begin
    No(L + ': VDbCryptDecrypt legacy CTR+HMAC', 'dosya yok');
    Exit;
  end;
  try
    env := LoadBin(p);
    if VDbCryptDecrypt(KeyRec, env, plain) and EqBytes(plain, RecPlain) then
      Ok(L + ': VDbCryptDecrypt legacy CTR+HMAC zarfi cozdü (rastgele IV, fonksiyonel)')
    else
      No(L + ': VDbCryptDecrypt legacy CTR+HMAC', 'cozme baarisiz');
  except
    on E: Exception do
      No(L + ': VDbCryptDecrypt legacy CTR+HMAC', 'istisna: ' + E.Message);
  end;
end;

procedure VerifyScram;
const
  L = 'scram_verifier.txt';
var
  p: string;
begin
  p := FxD + 'scram_verifier.txt';
  CheckPin(p, PIN_SCRAM_SHA256, L);
  if not FileExists(p) then
  begin
    No(L + ': AddUser formulu yeniden-turetimi', 'dosya yok');
    Exit;
  end;
  try
    if EqBytes(LoadBin(p), StrB(ScramText)) then
      Ok(L + ': AddUser formulu birebir yeniden turetildi (salt/iter/storedkey/serverkey)')
    else
      No(L + ': AddUser formulu yeniden-turetimi', 'dosya icerigi bugunku turetimle farkli');
  except
    on E: Exception do
      No(L + ': AddUser formulu yeniden-turetimi', 'istisna: ' + E.Message);
  end;
end;

procedure VerifyStore;
const
  L = 'store_odb_v1/' + STORE_DB_NAME;
var
  eng: TVdbPageEngine;
  rows: TRowArray;
  i: Integer;
  val: TBytes;
  opened: Boolean;
begin
  if not FileExists(StoreDbPath) then
  begin
    No(L + ': parolayla ac + satirlari dogrula', 'dosya yok');
    Exit;
  end;
  opened := False;
  rows := StoreRows;
  try
    eng := TVdbPageEngine.CreateWithPassword(StoreDbPath, PW_STORE);
    try
      eng.Open(False, True); { salt-okunur: fixture dosyalari degismemeli }
      opened := True;
      try
        if not eng.Encrypted then
          No(L + ': parolayla ac', 'Encrypted=True degil')
        else if eng.Count <> Length(rows) then
          No(L + ': satir sayisi', 'Count=' + IntToStr(eng.Count) +
            ' beklenen ' + IntToStr(Length(rows)))
        else
        begin
          for i := 0 to High(rows) do
          begin
            if eng.TryGet(rows[i].Key, val) and EqBytes(val, rows[i].Val) then
              Ok(L + ': satir ' + IntToStr(i + 1) + ' (key=' +
                IntToStr(rows[i].Key) + ') dogru')
            else
              No(L + ': satir ' + IntToStr(i + 1) + ' (key=' +
                IntToStr(rows[i].Key) + ')', 'TryGet yok/yanlis deger');
          end;
        end;
      finally
        eng.Close;
      end;
    finally
      eng.Free;
    end;
    if opened then
      Ok(L + ': parolayla ACILDI (PBKDF2-200000 + keycheck)');
  except
    on E: Exception do
      No(L + ': parolayla ac', 'istisna: ' + E.Message);
  end;
  { negatif: yanlis parola reddi (keycheck yolu) }
  try
    eng := TVdbPageEngine.CreateWithPassword(StoreDbPath, PW_WRONG);
    try
      eng.Open(False, True);
      No(L + ': yanlis parola reddi', 'yanlis parolayla acildi!');
      eng.Close;
    except
      on E: Exception do
        Ok(L + ': yanlis parola reddi (keycheck)');
    end;
    eng.Free;
  except
    { Create/Open oncesi istisna da reddin kendisidir }
    Ok(L + ': yanlis parola reddi (keycheck)');
  end;
end;

{ ======================= ortak akis ======================= }

function VerifyAll: Integer;
begin
  GPass := 0;
  GFail := 0;
  Writeln('== fixture dogrulama (verify) ==');
  VerifyKeyV1;
  VerifyKeyV2Handcrafted;
  VerifyKeyV2WritePath;
  VerifyPageEnvelope;
  VerifyRecordAead;
  VerifyRecordLegacy;
  VerifyScram;
  VerifyStore;
  Writeln;
  Writeln(Format('%d passed / %d failed', [GPass, GFail]));
  if GFail = 0 then
    Writeln('RESULT: PASS')
  else
    Writeln('RESULT: FAIL');
  Result := GFail;
end;

procedure WriteSha256Manifest;
var
  lines: TStringList;
  p: string;

  procedure Add(const Rel, Abs: string);
  begin
    if FileExists(Abs) then
      lines.Add(Sha256HexFile(Abs) + '  ' + Rel);
  end;

begin
  lines := TStringList.Create;
  try
    Add('key_v1_pbkdf2.key', FxD + 'key_v1_pbkdf2.key');
    Add('key_v2_argon2id.key', FxD + 'key_v2_argon2id.key');
    Add('key_v2_argon2id_write.key', FxD + 'key_v2_argon2id_write.key');
    Add('page_envelope_v1.bin', FxD + 'page_envelope_v1.bin');
    Add('record_envelope_v1.bin', FxD + 'record_envelope_v1.bin');
    Add('record_legacy_v1.bin', FxD + 'record_legacy_v1.bin');
    Add('scram_verifier.txt', FxD + 'scram_verifier.txt');
    Add(STORE_DIR_NAME + '/' + STORE_DB_NAME, StoreDbPath);
    Add(STORE_DIR_NAME + '/' + STORE_DB_NAME + '.wal', StoreDbPath + '.wal');
    Add(STORE_DIR_NAME + '/' + STORE_DB_NAME + '.gen', StoreDbPath + '.gen');
    Add(STORE_DIR_NAME + '/' + STORE_DB_NAME + '.idx', StoreDbPath + '.idx');
    lines.Add('# NOT: key_v2_argon2id_write.key, record_legacy_v1.bin ve ' +
      'store_odb_v1/* RNG icerir; her uretimde degisirler (verify modu ile dogrulanirlar).');
    SaveBin(FxD + 'sha256.txt', StrB(lines.Text + #10));
  finally
    lines.Free;
  end;
end;

function GenerateAll: Integer;
var
  key: TBytes;
begin
  ForceDirectories(FxD);
  Writeln('== fixture uretimi (gen) — TEST fixture, production entropy degil ==');
  Writeln('Dizin: ', FxD);
  GenKeyV1;                  Writeln('yazildi : key_v1_pbkdf2.key');
  GenKeyV2Handcrafted;       Writeln('yazildi : key_v2_argon2id.key (Argon2id, birkac saniye)');
  key := KeyV2Derived;
  GenKeyV2WritePath;         Writeln('yazildi : key_v2_argon2id_write.key (canli VDbKeyFileWrite)');
  GenPageEnvelope;           Writeln('yazildi : page_envelope_v1.bin');
  GenRecordAead;             Writeln('yazildi : record_envelope_v1.bin');
  GenRecordLegacy;           Writeln('yazildi : record_legacy_v1.bin (rastgele IV)');
  GenScram;                  Writeln('yazildi : scram_verifier.txt');
  Write('yaziliyor : store_odb_v1 (PBKDF2-200000, birkac saniye)... ');
  GenStore;
  Writeln('bitti');

  Writeln;
  Writeln('--- PINS (gen_fixtures.lpr PIN_* sabitlerine yapistirin) ---');
  Writeln('PIN_KEY_V1_SHA256   = ''', Sha256HexFile(FxD + 'key_v1_pbkdf2.key'), ''';');
  Writeln('PIN_KEY_V2_SHA256   = ''', Sha256HexFile(FxD + 'key_v2_argon2id.key'), ''';');
  Writeln('PIN_KEY_V2_KEY_HEX  = ''', B2Hex(key), ''';');
  Writeln('PIN_PAGE_SHA256     = ''', Sha256HexFile(FxD + 'page_envelope_v1.bin'), ''';');
  Writeln('PIN_REC_AEAD_SHA256 = ''', Sha256HexFile(FxD + 'record_envelope_v1.bin'), ''';');
  Writeln('PIN_SCRAM_SHA256    = ''', Sha256HexFile(FxD + 'scram_verifier.txt'), ''';');
  Writeln('--- PINS bitti ---');
  Writeln;
  WriteSha256Manifest;
  Writeln('yazildi : sha256.txt');
  Writeln;

  { uretim sonrasi kendi kapimizdan gec: }
  Result := VerifyAll;
end;

begin
  FxD := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'fixtures' + PathDelim;
  if (ParamCount >= 1) and SameText(ParamStr(1), 'verify') then
    Halt(VerifyAll)
  else if (ParamCount = 0) or SameText(ParamStr(1), 'gen') then
    Halt(GenerateAll)
  else
  begin
    Writeln('kullanim: gen_fixtures [gen|verify]');
    Halt(2);
  end;
end.
