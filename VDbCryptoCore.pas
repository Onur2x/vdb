unit VDbCryptoCore;

{ VDbCryptoCore - saf Pascal kripto cekirdegi (AES-256, SHA-256, HMAC-SHA256).

  NEDEN VAR (CRYPTO_ADR 3. adim / adim 4): proje bugune kadar AES ve SHA-256
  primitiflerini depoya gomulu DCPcrypt 2.0 (MIT, David Barton) uzerinden
  aliyordu. Hedef sozlesme "saf native, harici DLL veya harici bagimlilik
  yok" (readme.md:3-4). DCPcrypt tamamen kaldirildi; gereken cekirdek burada
  kendi kodumuz olarak duruyor. Harici DLL, harici unit, platform API'si YOK.

  ALGORITMA REFERANSLARI:
    * AES-256 blok sifreleme + big-endian CTR akis modu -> FIPS-197,
      NIST SP 800-38A.
    * SHA-256 -> FIPS 180-4.
    * HMAC-SHA256 -> RFC 2104 / FIPS 198-1.

  BAGIMLILIK KURALI: bu birim HICBIR VDb* birimini `uses` ETMEZ (yalniz
  SysUtils). Boylece VDbCrypt (yerel yol) ve VDbCryptoBuiltin bu cekirdegi
  kullanirken dongu/ozyineleme olusamaz.

  DAVRANIS UYUMLULUGU (kritik): eski DCPcrypt kullanimiyla bit-birebir ayni
  cikti uretilmelidir; aksi halde mevcut veritabani dosyalari acilamaz.
  Bu yuzden CTR semantigi DCP ile aynidir:
      keystream = E(Counter);  cikti = girdi xor keystream;
      sonra Counter BIG-ENDIAN 1 artar.
  Ilk blok counter'in KENDISINI sifreler (once artirma yok). Sifreleme ve
  desifreleme ayni islemdir (XOR akis modu).

  DOGRULAMA KAPILARI: tests/crypto_kat (NIST KAT, 98 vektor),
  tests/crypto_fixtures (22 vektor; builtin <-> OpenSSL capraz),
  tests/crypto_selftest, tests/crypto_base64. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  EVdbCryptoCoreError = class(Exception);

  { Genisletilmis AES-256 anahtar programi: 15 tur anahtari x 4 kelime. }
  TVdbAes256Ctx = record
    RK: array[0..59] of LongWord;
  end;

  { Durumlu AES-256-CTR akis baglami (DCP Init + EncryptCTR yerine). }
  TVdbAes256Ctr = record
    Ctx: TVdbAes256Ctx;
    Ctr: array[0..15] of Byte;
  end;

{ 32 baytlik anahtardan tur anahtarlarini uretir. }
procedure VDbAes256ExpandKey(const Key: TBytes; out Ctx: TVdbAes256Ctx);

{ Tek 16 baytlik blok sifreleme (ECB, dolgu YOK). InB/OutB ayni adres
  olabilir (in-place). }
procedure VDbAes256EncryptBlock(const Ctx: TVdbAes256Ctx; InB, OutB: PByte);

{ CTR akisini kurar: anahtar 32 bayt olmali; IV 16 baytlik tampona
  isaret eden bir PByte'dir (kopyalanir). }
procedure VDbAes256CtrInit(const Key: TBytes; IV: PByte; out C: TVdbAes256Ctr);

{ Akis modunda Len bayt sifreler/cozer (XOR). Cagrilar arasinda counter
  durumu korunur; bu yuzden 16'lik parcalar halinde cagirmak tek seferde
  cagirmakla ayni sonucu verir. }
procedure VDbAes256CtrCrypt(var C: TVdbAes256Ctr; InB, OutB: PByte;
  Len: Integer);

{ SHA-256 ozeti (32 bayt). }
function VDbSha256(const Data: TBytes): TBytes;

{ HMAC-SHA256 (32 bayt). Anahtar 64 bayttan uzunsa hata firlatir; eski
  VDbCrypt davranisiyla ayni (capHmacKeyOver64 yok). }
function VDbHmacSha256(const Key, Data: TBytes): TBytes;

implementation

const
  { FIPS-197 AES S-box. }
  AES_SBOX: array[0..255] of Byte = (
    $63,$7c,$77,$7b,$f2,$6b,$6f,$c5,$30,$01,$67,$2b,$fe,$d7,$ab,$76,
    $ca,$82,$c9,$7d,$fa,$59,$47,$f0,$ad,$d4,$a2,$af,$9c,$a4,$72,$c0,
    $b7,$fd,$93,$26,$36,$3f,$f7,$cc,$34,$a5,$e5,$f1,$71,$d8,$31,$15,
    $04,$c7,$23,$c3,$18,$96,$05,$9a,$07,$12,$80,$e2,$eb,$27,$b2,$75,
    $09,$83,$2c,$1a,$1b,$6e,$5a,$a0,$52,$3b,$d6,$b3,$29,$e3,$2f,$84,
    $53,$d1,$00,$ed,$20,$fc,$b1,$5b,$6a,$cb,$be,$39,$4a,$4c,$58,$cf,
    $d0,$ef,$aa,$fb,$43,$4d,$33,$85,$45,$f9,$02,$7f,$50,$3c,$9f,$a8,
    $51,$a3,$40,$8f,$92,$9d,$38,$f5,$bc,$b6,$da,$21,$10,$ff,$f3,$d2,
    $cd,$0c,$13,$ec,$5f,$97,$44,$17,$c4,$a7,$7e,$3d,$64,$5d,$19,$73,
    $60,$81,$4f,$dc,$22,$2a,$90,$88,$46,$ee,$b8,$14,$de,$5e,$0b,$db,
    $e0,$32,$3a,$0a,$49,$06,$24,$5c,$c2,$d3,$ac,$62,$91,$95,$e4,$79,
    $e7,$c8,$37,$6d,$8d,$d5,$4e,$a9,$6c,$56,$f4,$ea,$65,$7a,$ae,$08,
    $ba,$78,$25,$2e,$1c,$a6,$b4,$c6,$e8,$dd,$74,$1f,$4b,$bd,$8b,$8a,
    $70,$3e,$b5,$66,$48,$03,$f6,$0e,$61,$35,$57,$b9,$86,$c1,$1d,$9e,
    $e1,$f8,$98,$11,$69,$d9,$8e,$94,$9b,$1e,$87,$e9,$ce,$55,$28,$df,
    $8c,$a1,$89,$0d,$bf,$e6,$42,$68,$41,$99,$2d,$0f,$b0,$54,$bb,$16);

  { FIPS 180-4 SHA-256 yuvarlak sabitleri. }
  SHA256_K: array[0..63] of LongWord = (
    $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
    $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
    $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
    $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
    $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
    $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
    $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
    $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);

{ ------------------------------- AES-256 ------------------------------- }

function XTime(X: Byte): Byte; inline;
begin
  if (X and $80) <> 0 then
    Result := Byte((X shl 1) xor $1B)
  else
    Result := Byte(X shl 1);
end;

function AesSubWord(W: LongWord): LongWord; inline;
begin
  Result := (LongWord(AES_SBOX[(W shr 24) and $FF]) shl 24) or
            (LongWord(AES_SBOX[(W shr 16) and $FF]) shl 16) or
            (LongWord(AES_SBOX[(W shr 8) and $FF]) shl 8) or
             LongWord(AES_SBOX[W and $FF]);
end;

procedure VDbAes256ExpandKey(const Key: TBytes; out Ctx: TVdbAes256Ctx);
var
  i: Integer;
  temp: LongWord;
  rcon: Byte;
begin
  if Length(Key) <> 32 then
    raise EVdbCryptoCoreError.Create('AES-256: anahtar 32 bayt olmali');
  FillChar(Ctx, SizeOf(Ctx), 0);
  for i := 0 to 7 do
    Ctx.RK[i] := (LongWord(Key[4 * i]) shl 24) or
                 (LongWord(Key[4 * i + 1]) shl 16) or
                 (LongWord(Key[4 * i + 2]) shl 8) or
                  LongWord(Key[4 * i + 3]);
  rcon := 1;
  for i := 8 to 59 do
  begin
    temp := Ctx.RK[i - 1];
    if (i mod 8) = 0 then
    begin
      { RotWord + SubWord + Rcon }
      temp := (temp shl 8) or (temp shr 24);
      temp := AesSubWord(temp) xor (LongWord(rcon) shl 24);
      rcon := XTime(rcon);
    end
    else if (i mod 8) = 4 then
      temp := AesSubWord(temp);
    Ctx.RK[i] := Ctx.RK[i - 8] xor temp;
  end;
end;

procedure AesAddRoundKey(var St: array of Byte; const Ctx: TVdbAes256Ctx;
  Round: Integer);
var
  i: Integer;
  w: LongWord;
begin
  for i := 0 to 15 do
  begin
    w := Ctx.RK[Round * 4 + (i div 4)];
    St[i] := St[i] xor Byte((w shr (24 - 8 * (i mod 4))) and $FF);
  end;
end;

procedure AesSubBytes(var St: array of Byte);
var
  i: Integer;
begin
  for i := 0 to 15 do
    St[i] := AES_SBOX[St[i]];
end;

{ Durum column-major: St[r + 4c]. Satir r, r bayt sola kaydirilir. }
procedure AesShiftRows(var St: array of Byte);
var
  tmp: array[0..15] of Byte;
  r, c: Integer;
begin
  for r := 0 to 15 do
    tmp[r] := St[r];
  for r := 0 to 3 do
    for c := 0 to 3 do
      St[r + 4 * c] := tmp[r + 4 * ((c + r) mod 4)];
end;

procedure AesMixColumns(var St: array of Byte);
var
  c: Integer;
  a0, a1, a2, a3, t, u: Byte;
begin
  for c := 0 to 3 do
  begin
    a0 := St[4 * c];
    a1 := St[4 * c + 1];
    a2 := St[4 * c + 2];
    a3 := St[4 * c + 3];
    t := a0 xor a1 xor a2 xor a3;
    u := a0;
    St[4 * c] := a0 xor t xor XTime(a0 xor a1);
    St[4 * c + 1] := a1 xor t xor XTime(a1 xor a2);
    St[4 * c + 2] := a2 xor t xor XTime(a2 xor a3);
    St[4 * c + 3] := a3 xor t xor XTime(a3 xor u);
  end;
end;

procedure VDbAes256EncryptBlock(const Ctx: TVdbAes256Ctx; InB, OutB: PByte);
var
  st: array[0..15] of Byte;
  i, r: Integer;
begin
  for i := 0 to 15 do
    st[i] := InB[i];
  AesAddRoundKey(st, Ctx, 0);
  for r := 1 to 13 do
  begin
    AesSubBytes(st);
    AesShiftRows(st);
    AesMixColumns(st);
    AesAddRoundKey(st, Ctx, r);
  end;
  AesSubBytes(st);
  AesShiftRows(st);
  AesAddRoundKey(st, Ctx, 14);
  for i := 0 to 15 do
    OutB[i] := st[i];
end;

procedure VDbAes256CtrInit(const Key: TBytes; IV: PByte; out C: TVdbAes256Ctr);
var
  i: Integer;
begin
  VDbAes256ExpandKey(Key, C.Ctx);
  for i := 0 to 15 do
    C.Ctr[i] := IV[i];
end;

{ DCP blockciphers IncCounter ile ayni: BIG-ENDIAN artirma. }
procedure AesIncCounter(var Ctr: array of Byte);
var
  i: Integer;
begin
  i := 15;
  while i >= 0 do
  begin
    Inc(Ctr[i]);
    if Ctr[i] <> 0 then
      Exit;
    Dec(i);
  end;
end;

procedure VDbAes256CtrCrypt(var C: TVdbAes256Ctr; InB, OutB: PByte;
  Len: Integer);
var
  ks: array[0..15] of Byte;
  n, i: Integer;
begin
  while Len > 0 do
  begin
    VDbAes256EncryptBlock(C.Ctx, @C.Ctr[0], @ks[0]);
    AesIncCounter(C.Ctr);
    if Len < 16 then
      n := Len
    else
      n := 16;
    for i := 0 to n - 1 do
      OutB[i] := InB[i] xor ks[i];
    Inc(InB, n);
    Inc(OutB, n);
    Dec(Len, n);
  end;
end;

{ ------------------------------- SHA-256 ------------------------------- }

function Ror32(X: LongWord; N: Byte): LongWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure Sha256Block(const Blk: TBytes; Off: Integer; var H: array of LongWord);
var
  W: array[0..63] of LongWord;
  i: Integer;
  a, b, c, d, e, f, g, hh, t1, t2, s0, s1, ch, maj: LongWord;
begin
  for i := 0 to 15 do
    W[i] := (LongWord(Blk[Off + 4 * i]) shl 24) or
            (LongWord(Blk[Off + 4 * i + 1]) shl 16) or
            (LongWord(Blk[Off + 4 * i + 2]) shl 8) or
             LongWord(Blk[Off + 4 * i + 3]);
  for i := 16 to 63 do
  begin
    s0 := Ror32(W[i - 15], 7) xor Ror32(W[i - 15], 18) xor (W[i - 15] shr 3);
    s1 := Ror32(W[i - 2], 17) xor Ror32(W[i - 2], 19) xor (W[i - 2] shr 10);
    W[i] := W[i - 16] + s0 + W[i - 7] + s1;
  end;

  a := H[0]; b := H[1]; c := H[2]; d := H[3];
  e := H[4]; f := H[5]; g := H[6]; hh := H[7];
  for i := 0 to 63 do
  begin
    s1 := Ror32(e, 6) xor Ror32(e, 11) xor Ror32(e, 25);
    ch := (e and f) xor ((not e) and g);
    t1 := hh + s1 + ch + SHA256_K[i] + W[i];
    s0 := Ror32(a, 2) xor Ror32(a, 13) xor Ror32(a, 22);
    maj := (a and b) xor (a and c) xor (b and c);
    t2 := s0 + maj;
    hh := g; g := f; f := e; e := d + t1;
    d := c; c := b; b := a; a := t1 + t2;
  end;
  H[0] := H[0] + a; H[1] := H[1] + b; H[2] := H[2] + c; H[3] := H[3] + d;
  H[4] := H[4] + e; H[5] := H[5] + f; H[6] := H[6] + g; H[7] := H[7] + hh;
end;

function VDbSha256(const Data: TBytes): TBytes;
var
  H: array[0..7] of LongWord;
  buf: TBytes;
  n, total, i: Integer;
  bits: QWord;
begin
  Result := nil;
  n := Length(Data);
  total := n + 1 + 8;
  if (total mod 64) <> 0 then
    total := total + (64 - (total mod 64));
  SetLength(buf, total);
  if n > 0 then
    Move(Data[0], buf[0], n);
  buf[n] := $80;
  bits := QWord(n) * 8;
  for i := 0 to 7 do
    buf[total - 1 - i] := Byte((bits shr (8 * i)) and $FF);

  H[0] := $6a09e667; H[1] := $bb67ae85; H[2] := $3c6ef372; H[3] := $a54ff53a;
  H[4] := $510e527f; H[5] := $9b05688c; H[6] := $1f83d9ab; H[7] := $5be0cd19;

  i := 0;
  while i < total do
  begin
    Sha256Block(buf, i, H);
    Inc(i, 64);
  end;

  SetLength(Result, 32);
  for i := 0 to 7 do
  begin
    Result[4 * i] := Byte((H[i] shr 24) and $FF);
    Result[4 * i + 1] := Byte((H[i] shr 16) and $FF);
    Result[4 * i + 2] := Byte((H[i] shr 8) and $FF);
    Result[4 * i + 3] := Byte(H[i] and $FF);
  end;
end;

{ ---------------------------- HMAC-SHA256 ---------------------------- }

function VDbHmacSha256(const Key, Data: TBytes): TBytes;
var
  k: array[0..63] of Byte;
  ip, op, inner: TBytes;
  i, dn: Integer;
begin
  if Length(Key) > 64 then
    raise EVdbCryptoCoreError.Create(
      'HMAC-SHA256: anahtar 64 bayttan uzun (capHmacKeyOver64 yok)');
  dn := Length(Data);
  FillChar(k, SizeOf(k), 0);
  if Length(Key) > 0 then
    Move(Key[0], k[0], Length(Key));

  SetLength(ip, 64 + dn);
  SetLength(op, 64 + 32);
  for i := 0 to 63 do
  begin
    ip[i] := k[i] xor $36;
    op[i] := k[i] xor $5C;
  end;
  if dn > 0 then
    Move(Data[0], ip[64], dn);

  inner := VDbSha256(ip);
  Move(inner[0], op[64], 32);
  Result := VDbSha256(op);

  { Anahtar/is tamponlarini sifirla: gizli malzeme bellekte kalmasin. }
  FillChar(k, SizeOf(k), 0);
  if Length(ip) > 0 then
    FillChar(ip[0], Length(ip), 0);
  if Length(op) > 0 then
    FillChar(op[0], Length(op), 0);
  if Length(inner) > 0 then
    FillChar(inner[0], Length(inner), 0);
end;

end.
