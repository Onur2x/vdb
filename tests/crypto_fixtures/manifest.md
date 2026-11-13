# Kriptografik Uyumluluk Fixture Manifesti (Goc Plani Adim 2A)

Bu klasordeki fixture'lar **goc-oncesi (dcpcrypt / saf Pascal) kodun** urettiği
eski-format dosyalarini bit duzeyinde sabitler. Adim 2B'de VDbCrypt.pas OpenSSL
provider'ina tasindiktan sonra `gen_fixtures verify` bu dosyalari COZEMEZSE
**GOC KIRICIDIR** (bkz. README.md).

Ureten: `gen_fixtures.lpr` (bu klasor). Tum parola/tuz/nonce degerleri
**TEST fixture, production entropy degil** — kaynakta sabittir.

sha256 sabitleme cift kapilidir:
1. `gen_fixtures.lpr` icindeki `PIN_*` sabitleri (verify modu bunlari kontrol eder),
2. asagidaki tablo + `fixtures\sha256.txt` (makine-okunur snapshot).

| Fixture | sha256 | Deterministik? | Ureten API yolu |
|---|---|---|---|
| `key_v1_pbkdf2.key` | `da99477949f4df280c94e8523fa36e9290015c63d33cc901714af7779de10508` | Evet (pinli) | Baslik ORTUK kurulur; anahtar `VDbCryptDeriveKey` (PBKDF2-SHA256, iter=1000), dogrulayici `VDbCryptVerifier`; okuma kapisi `VDbKeyFileRead` |
| `key_v2_argon2id.key` | `bb781020f2a51434ffb5d1f2471665b6dcbc78aaa567c55d8d6ad21da63829b7` | Evet (pinli) | Baslik `VDbKeyFileWrite` bicimiyle elle; anahtar `VDbArgon2id(t=3,m=65536,p=4)` sabit tuzla; tureyen anahtar KAT: `f85e028352a0390777b20ecfbd10d1f2ffa9f74d52095c86e61da4e5cc796d48` |
| `key_v2_argon2id_write.key` | (RNG — pinlenmez) | Hayir: `VDbCryptNewSalt` CSPRNG | **Canli `VDbKeyFileWrite`** girdi/ciktisi; verify: `VDbKeyFileRead` round-trip |
| `page_envelope_v1.bin` | `bbbfbf6c9d12439e831296854e510d19c6e9903465198a327b69603f2c995dce` | Evet (pinli) | Ham `VDbCryptGcmSeal` sabit nonce + `BuildAad` sozlesmesi (VDbPageSeal'in o nonce ile birebir ayni cikisi); okuma kapisi `VDbPageOpen` |
| `record_envelope_v1.bin` | `5adf0d8bcab20c472dc27368f390c3f7ea3e93ccb8173046d5ac49ce6b8294ef` | Evet (pinli) | `VDbCryptAeadSeal` sabit nonce; okuma kapi `VDbCryptAeadOpen` + `VDbCryptDecrypt` |
| `record_legacy_v1.bin` | (RNG — pinlenmez) | Hayir: `VDbCryptRandom` IV | Canli `VDbCryptEncryptLegacy`; verify: `VDbCryptDecrypt` eski CTR+HMAC yolu |
| `scram_verifier.txt` | `68d758a8ea0d813b3b18efff6cf71e58205b10830bba4265a6bd81d36398e595` | Evet (pinli) | `VDbPgWire.AddUser` turetim formulu (VDbPbkdf2Sha256 → HMAC 'Client Key' → SHA256 → HMAC 'Server Key'), sabit tuz, iter=15000 (clamp tabani, VDbPgWire.pas ~2361) |
| `store_odb_v1\` | (RNG — pinlenmez) | Hayir: DBID + sayfa nonce'lari + LSN | Canli `TVdbPageEngine.CreateWithPassword` → `Open(True)` → 4x `Insert` → `Commit` → `Checkpoint` → `Close` (parola → PBKDF2-200000, VDB_ENC_ITER). verify: parolayla AC + satirlari dogrula |

RNG iceren fixture'lar her `gen` kosumunda degisir; kapilari **verify modunun
fonksiyonel round-trip**idir (byte-hash degil). Deterministik olanlar hem pin
hash hem fonksiyonel round-trip ile korunur.

## Test sabitleri (tek kullanim yerleri gen_fixtures.lpr)

- Parolalar: `VdbFixt!2026` (.key v1/v2), `VdbFixt!2026store` (store).
- Tuz/anahtar/nonce desenleri `Pat(n, seed)` = bayt `seed+i`:
  saltV1 seed=0xA1, saltV2 seed=0xB2, sayfa anahtari 0x10, sayfa tuzu 0x20,
  sayfa nonce 0x30 (sabit), kayit anahtari 0x40, kayit nonce 0x50 (sabit),
  SCRAM tuzu 0x60.
- Sayfa duz-metin deseni: `plain[i] = byte(i*7 + (i shr 8)*13 + 1)` (4096 B).
- Kayit duz-metni: `VDB fixture kayit duz-metni 0123456789abcdef` (44 B).
- v1 PBKDF2 iterasyonu 1000: **VDbKeyFileRead'in kabul ettigi alt sinir** —
  format kapisi (güvenlik kapisi degil).

## Format offset tablolari

### `key_v1_pbkdf2.key` (58 B) — eski .key, PBKDF2-SHA256
Bugunku kod v1 **yazmiyor**; dosya VDbKeyFileRead'in v1 okuma yolunun
belgelendirdigi bicimle üreticide ORTUK kuruldu ve ACCEPT'i dogrulandi.

| Offset | Uzunluk | Alan | Fixture degeri |
|---|---|---|---|
| 0 | 4 | `'VDBK'` imza | `56 44 42 4B` |
| 4 | 1 | surum | `01` |
| 5 | 1 | tuz uzunlugu | `10` (16) |
| 6 | 4 | iterasyon (LE32) | `E8 03 00 00` (1000) |
| 10 | 16 | tuz | `A1..B0` |
| 26 | 32 | dogrulayici | `HMAC-SHA256(anahtar,'VDB-KEY-VERIFY')` |

### `key_v2_argon2id.key` / `key_v2_argon2id_write.key` (63 B) — yeni .key, Argon2id

| Offset | Uzunluk | Alan | Fixture degeri |
|---|---|---|---|
| 0 | 4 | `'VDBK'` imza | `56 44 42 4B` |
| 4 | 1 | surum | `02` |
| 5 | 1 | tuz uzunlugu | `10` (16) |
| 6 | 4 | Argon2 t (LE32) | `03 00 00 00` |
| 10 | 4 | Argon2 m KiB (LE32) | `00 00 01 00` (65536) |
| 14 | 1 | Argon2 p (lanes) | `04` |
| 15 | 16 | tuz | handcrafted: `B2..C1`; write.key: rastgele |
| 31 | 32 | dogrulayici | `HMAC-SHA256(anahtar,'VDB-KEY-VERIFY')` |

### `page_envelope_v1.bin` (4124 B) — sayfa zarfi (VDB3 sayfa sifreleme)
VDbPageCrypto.pas: `nonce | AES-256-GCM(sifreli 4096 B) | tag`.
AAD dosyada DEGILDIR, turetilir: `'VDB3PG' | LE32(sayfaNo) | tuz(16)`.

| Offset | Uzunluk | Alan | Fixture degeri |
|---|---|---|---|
| 0 | 12 | nonce | `30..3B` (sabit test nonce) |
| 12 | 4096 | sifreli sayfa | GCM ciktisi |
| 4108 | 16 | GCM etiketi | — |
| (AAD) | 6+4+16 | baglam | `'VDB3PG'` , LE32(7) , tuz `20..2F` |

### `record_envelope_v1.bin` (80 B) — kayit zarfi 'VDBAEAD1' (VDbCryptEncrypt yolu)

| Offset | Uzunluk | Alan | Fixture degeri |
|---|---|---|---|
| 0 | 8 | `'VDBAEAD1'` | imza |
| 8 | 12 | nonce | `50..5B` (sabit test nonce) |
| 20 | 44 | sifreli metin | GCM ciktisi (duz-metin 44 B) |
| 64 | 16 | GCM etiketi | AAD = yok (nil) |

### `record_legacy_v1.bin` (100 B) — M6-oncesi CTR+HMAC zarfi (yalniz OKUNUR yol)

| Offset | Uzunluk | Alan | Fixture degeri |
|---|---|---|---|
| 0 | 16 | IV | **rastgele** (RNG) |
| 16 | 4 | duz-metin uzunlugu (LE32) | `2C 00 00 00` (44) |
| 20 | 48 | AES-256-CTR sifreli (16'ya doldurulmus) | — |
| 68 | 32 | HMAC-SHA256 etiketi | `K_mac = HMAC(master,'VDB-MAC-v1')`, veri = IV‖len‖sifreli |

### `scram_verifier.txt` — SCRAM-SHA-256 dogrulayici satirlari
`user / password / salt_b64 / salt_hex / iterations / storedkey_b64 /
storedkey_hex / serverkey_b64 / serverkey_hex` (satir bazli, `#` aciklama).
Sunucu sozlesmesi: Postgres SCRAM-SHA-256; `iterations` clamp araligi
[15000, 1000000] (VDbPgWire.pas).

### `store_odb_v1\` — canli sifreli depo (VDB3 kapali format)
Dosyalar: `fixture.odb` (+ `.wal`, `.gen`, `.idx`). Anahtar bayt-duzeyi
pinlenmez (DBID/sayfa-nonce/LSN RNG); kapilar:
- baslik sayfa 0: `'VDB3'` imza + surum 5 (offset 4, LE32),
- meta (sayfa-0 govde): tuz @36 (16B), iter @52 (LE32 = 200000),
  keycheck @56 (16B = `VDbPageKeyCheck` = HMAC(`'VDB3-PAGE-KEY-v1'`)[0..15]),
  bayrak @72 (bit0 ENC), DBID @76 — bkz. VDbPageStore.pas VDB_META_*,
- her veri sayfi 4124 B'lik zarf: `nonce|ct(4096)|tag(16)` (yukaridaki bicim),
- verify: `TVdbPageEngine.CreateWithPassword(path,'VdbFixt!2026store').Open(False,True,0)`
  → 4 satir `TryGet` + sayim + yanlis parola reddi.

## Goc sonrasi (2B) bu tablo nasil kullanilir
`gen_fixtures verify` exit-code 0 donerse uyumluluk korunmustur. Basarisiz her
kontrol exit code'a sayi olarak gecer; hangi fixture'in kitigini stdout
PASS/FAIL satirlari soyler.
