# VDbCrypto KAT — Vektör Kaynakları (Vector Provenance)

Her vektörün nereden alındığı ve nasıl doğrulandığı **dürüstçe** aşağıdadır.
"resmî doğrulandı" diyemediğimiz her yer TODO olarak işaretlidir.

> Görev brief'indeki atıf düzeltmesi: Argon2 KAT'ı için "RFC 9128 A.4" denmiş;
> **RFC 9128 bir PIM/YANG modelidir, Argon2 vektörü içermez.** Doğru kaynak
> **RFC 9106 §5.3**'tür (metin 2026-11-13'te-fetch edildi, aşağıdaki tag RFC
> metni ile bayt-bayt aynıdır).

## 1. SHA-256 — `VDbCryptSha256`

| Girdi | Beklenen (hex) | Kaynak |
|---|---|---|
| boş | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | FIPS 180-4 (boş mesaj) |
| `"abc"` | `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` | FIPS 180-4 App. B.1 |
| `"abcdbcde…nopq"` (56B) | `248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1` | FIPS 180-4 App. B.2 |
| 56 × `0x61` | `b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a` | CPython hashlib ile çapraz doğrulandı (len mod 64 = 56 sınırı) |
| 1 000 000 × `0x61` | `cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0` | NIST uzun-mesaj örneği; CPython hashlib ile çapraz doğrulandı |

⚠ İnternette dolaşan `cdc536f9b7d6…` değeri SHA-256 için **YANLIŞTIR**;
doğrulanan doğru değer `cdc76e5c9914…`.

## 2. HMAC-SHA256 — `VDbCryptHmacSha256` (RFC 4231 §4.2–4.8)

RFC metni 2026-11-13'te fetch edildi; tüm tag'ler RFC ile bayt-bayt aynı ve
ayrıca yerelde CPython `hmac` ile üretildi.

- Case 1–4: doğrudan test (20×`0x0b`; `"Jefe"`; 20×`0xaa`; `01..19`).
- Case 5: **SKIP** — API her zaman tam 32B tag döner; kesme (truncation) test
  primitifi ilgilendirmiyor.
- Case 6–7 (131×`0xaa` anahtar): `VDbCryptHmacSha256` 64B üzeri anahtarı
  RFC 2104 gereği hash'lemek yerine **`EVdbCryptError` ile reddediyor**.
  Test iki parçalı: (a) ham çağrının reddedilmesi seal'lenir (dokümante
  limitasyon), (b) harness tarafında `K ← SHA-256(K)` ön-indirgemesi sonrası
  HMAC çekirdeği RFC tag'i ile doğrulanır (`HMAC(K,m)=HMAC(H(K),m)`).

## 3. AES-256-GCM — `VDbCryptGcmSeal/Open` (6 vektör)

(key, IV, AAD, PT) demetleri NIST SP 800-38D / McGrew-Viega örnekleridir.
**NIST CAVP `gcmEncryptExtIV256.json` bu ortamdan indirilemedi** (denenen tüm
URL'ler 404, 2026-11-13). ct/tag değerleri **bağımsız bir implementasyonla**
(Python `cryptography` → OpenSSL) yerelde hesaplandı; üretici script:
`%TEMP%\kat_gcm_final.py`.

| # | PT | AAD | ct | tag |
|---|---|---|---|---|
| V1 | boş | boş | boş | `fd2caa16a5832e76aa132c1453eeda7e` |
| V2 | `d931…a953` (20B) | boş | `522dc1f099567d07f47f37a32a84427d643a8cdc` | `ea0c314d58d83c6c238093de1612a4de` |
| V3 | V2 PT | `feed…dad2` (20B) | V2 ct | `10501bc85651ae8f4176d6c5a5ea9f3f` |
| V4 | 28B | V3 AAD | `522d…d574` (28B) | `2de5dd9732afe5f27d59503701ae3bdf` |
| V5 | 16×`0x00` (sıfır anahtar/IV) | boş | `cea7403d4d606b6e074ec5d3baf39d18` | `d0d1c8a799996bf0265b98b5d48ab919` |
| V6 | boş (sıfır anahtar/IV) | boş | boş | `530f8afbc74536b9a963b4f1c4cb738b` |

Anahtar `feffe992…8308` (32B), IV `cafebabefacedbaddecaf888`.
**TODO: NIST CAVP'den doğrula** — internete erişimli bir makinede
`gcmEncryptExtIV256.json` ile çapraz kontrol yapılmalı.

Ayrıca: uzunluk guard'ları, `VDBAEAD1` zarf düzeni (magic|nonce|ct|tag,
nonce okuma, determinizm, tahrifat reddi) ve legacy CTR+HMAC zarf
round-trip/tahrifat testleri seal'leniyor.

## 4. Argon2id — `VDbArgon2id` (RFC 9106 §5.3)

```
P = 32×0x01  S = 16×0x02  Secret = 8×0x03  AD = 12×0x04
t = 3   m = 32 KiB   p = 4   taglen = 32
tag = 0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659
```

RFC metniyle bayt-bayt doğrulandı (H0 ön-hash'ı ayrıca yerelde BLAKE2b ile
üretildi ve eşleşti). Ek seal'ler: determinizm, t=2 / p=2 parametre
hassasiyeti, boş Secret/AD yolu, HashLen=100 (Blake2bLong >64B yolu,
deterministik; resmî 100B tag yok), geçersiz parametre guard'ları
(HashLen<4, m<8p, t=0, p=0 → `False`).

## 5. BLAKE2b — `VDbBlake2b`

| Girdi | OutLen | Beklenen | Kaynak |
|---|---|---|---|
| `"abc"` | 64 | `ba80a53f…d4009923` | **RFC 7693 App. A** (resmî) |
| `"abc"` | 32 | `bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319` | resmî BLAKE2 vektör seti; hashlib çapraz-control |
| boş | 64 | `786a02f7…afe9be2ce` | CPython hashlib |
| 128×`0x61` | 64 | `fc6c71f6…1d3a8f3b` | CPython hashlib (tam 2 blok) |
| 200×`0x61` | 64 | `93235585…9577d209` | CPython hashlib (kısmi 3. blok) |

OutLen sözleşmesi: 1..64 çalışır; 0 ve 65 → `EVdbKdfError`.

## 6. Sayfa zarfı — `VDbPageCrypto`

Özel format; resmî KAT **yok**. Bunun yerine yapısal mühürleme:
4124B zarf düzeni (`nonce12|ct4096|tag16`), AAD'nin
`'VDB3PG'|LE32(PageNo)|Salt` olduğu ham `VDbCryptGcmSeal` ile bayt-bayt
pin'lenir; tahrifat/yanlış sayfa/yanlış salt/yanlış anahtar/truncation
reddi; `KeyCheck = HMAC-SHA256(key,"VDB3-PAGE-KEY-v1")[0..15]`; parmak izi
8 küçük-hex; `KeyFromPassword` deterministik + tuz-hassas + `Iter<1` →
`EVdbPageCrypto`.

## Bilinen borçlar (test değil, not)

- GCM nonce-tekrarı primitif tarafından tespit edilmiyor
  (`docs/engineering/BASELINE.md` §5 borcu) — `SKIP` notu olarak kayıtlı.
- HMAC >64B anahtar reddi → üretim kodu değişirse Case 6/7 ham-çağrı testi
  güncellenmeli.
