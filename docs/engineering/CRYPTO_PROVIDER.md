# VDB V3 - Kripto Provider Sozlesmesi ve OpenSSL Degerlendirmesi

Bu belge SKILL4 Sprint F kapsaminda kripto envanterini, provider tasarimini,
test vektorlerinin durumunu ve OpenSSL provider'inin **durust**
degerlendirmesini kaydeder. Ilgili belgeler: `docs/security/SBOM.md`,
`docs/security/THREAT_MODEL.md`, `docs/engineering/LIMITS.md`,
`docs/engineering/SERVER_HARDENING.md`, `NOTICE`, `ADR` kayitlari (K1/K3/K5/K6).

Tarih: 2026-11-17. Durus: **BETA CANDIDATE** - bu belge "production ready",
FIPS, SIL veya sertifikasyon iddiasi tasimaz.

---

## 1. Mevcut davranis (olculen, kodda)

| Konu | Davranis | Kaynak |
|---|---|---|
| Varsayilan provider | **`builtin`** (saf Pascal, sifir harici DLL) | `VDbCryptoProvider.pas` (`R-5`, `K1`) |
| OpenSSL | Yalnizca **ACIK opt-in** | `VDB_CRYPTO_PROVIDER=openssl` veya `VDbCryptoSelectProvider(VDB_PROVIDER_OPENSSL)` |
| Sessiz fallback | **YOK**. OpenSSL acikca secilip kullanilamiyorsa secim basarisiz olur; hata denen DLL adlarini + `VDB_CRYPTO_DLL` ipucunu soyler | `VDbCryptoProvider.pas`, `VDbCryptoOpenSSL.pas` |
| DLL arama | Acik secim olmadikca OpenSSL DLL'i **aranmaz/yuklenmez** | `R-5/b` |
| `VDB_CRYPTO_DLL` | Yalnizca libcrypto **dosya yolu ipucu**; provider secmez | `VDbCryptoOpenSSL.pas` |
| Sozlesme bicimi | Soyut sinif (vtable); fonksiyon-pointer kaydi degil | `VDbCryptoProvider.pas` (`R-5`) |
| Provider baslatma | Init-once + kilit | `VDbCryptoOpenSSL.pas` |

Birimler: `VDbCryptoBuiltin.pas`, `VDbCryptoCore.pas`,
`VDbCryptoOpenSSL.pas`, `VDbCryptoProvider.pas`, `VDbCryptoRandom.pas`,
`VDbCryptoSelfTest.pas`, `VDbCryptoTypes.pas`. Facade: `VDbCrypt.pas`.
DCPcrypt **tamamen kaldirildi** (bkz. `NOTICE`,
`docs/engineering/DCPCRYPT_USAGE_INVENTORY.md`).

---

## 2. Yetenek matrisi (koddan, `Capabilities` kumeleri)

| Yetenek | `builtin` | `openssl` | Not |
|---|---|---|---|
| `capHash` (SHA-256) | VAR | VAR | |
| `capHmac` (HMAC-SHA256, anahtar <= 64 B) | VAR | VAR | |
| `capHmacKeyOver64` (>64 B anahtar, RFC 2104) | **YOK** | VAR | Bilinen borc (ADR 6); builtin >64 B anahtari reddeder |
| `capAead` (AES-256-GCM seal/open) | VAR | VAR | |
| `capPbkdf2` (PBKDF2-HMAC-SHA256) | VAR | VAR | |
| `capArgon2id` | VAR | **YOK** | OpenSSL 1.1/3.0-3.1'de Argon2 yok (`K6`) |
| `capRandom` (CSPRNG) | VAR | VAR | |
| `capAes256Block` (tek blok AES-256, yalniz selftest/ic kullanim) | VAR | **YOK** | `K6` sembol setine ECB eklenmedi |

Sonuc: **`builtin` tek basina butun VDB ihtiyaclarini karsilar** (Argon2id
dahil). OpenSSL bir yetenek *eklemez*; yalnizca >64 B HMAC anahtari gibi
kenar durumlari destekler ve Argon2id'i **kaybeder**.

---

## 3. Test vektorleri ve kapilar

| Kapi | Ne dogrular | Durum |
|---|---|---|
| `crypto_core` | AES-256-CTR/GCM cekirdegi, SHA-256, HMAC | PASS |
| `crypto_base64` | Kodlama/cozme sinir durumlari | PASS |
| `crypto_kat` | Bilinen-cevap (known-answer) vektorleri | PASS |
| `selftest_builtin` | Provider selftest'i (builtin) | PASS |
| `fixtures_builtin` | Sabit test verisi butunlugu | PASS |
| `tls_client` | Istemci TLS (CA zorunlu, dogrulamasiz baglanti yok) | Windows'ta **SKIP**; Linux'ta OpenSSL kutuphanesi varsa kosar |
| `format_compat` | v3/v4 yukseltme, v6 reddi, yirtilma | PASS |

**Durust sinir**: `selftest_builtin` bir *duman* testidir; FIPS 140-3 veya
CAVP dogrulamasi degildir. `crypto_kat` yalnizca belgelenmis vektor
kumesini kapsar; rastgele/fuzz kripto analizi yapilmaz.

---

## 4. OpenSSL provider degerlendirmesi (SKILL4 §8)

**Karar: OpenSSL opt-in kalir, varsayilan olmaz.**

Gerekceler:

1. **Sifir harici DLL sozu** (`readme.md`): varsayilanin harici bagimliligi
   olamaz.
2. **Yetenek kaybi**: OpenSSL secildiginde `capArgon2id` ve
   `capAes256Block` duser. Yeni yazimlarin tek KDF'i Argon2id oldugu icin
   (`K3`) bu, guvenlik acisindan bir *geri* adimdir.
3. **Tedarik zinciri**: DLL yolu, surumu ve butunlugu ayri bir risk yuzeyi
   olur; `VDB_CRYPTO_DLL` bir yol ipucudur, imza dogrulamasi yapmaz.
4. **Davranis farki**: ayni SQL/DB islemi secilen provider'a gore farkli
   yetenek kumesi gorur; sessiz fark uretmemek icin opt-in + acik hata
   tercih edildi.

Kabul edilebilir kullanim: operatorun kendi ortaminda, acikca
`VDB_CRYPTO_PROVIDER=openssl` (veya API) ile secmesi ve `capArgon2id`
gerektiren yollarin kullanilmamasi. Bu durumda bile VDB bu kurulumu
"sertifikali" saymaz.

---

## 5. Bilinen limitler ve acik riskler

- **`capHmacKeyOver64` builtin'de yok** (ADR 6). 64 B uzeri HMAC anahtari
  `EVdbCryptoError` ile reddedilir; sessizce kirpilmaz.
- **Parola/KDF parametreleri** cagiranin sorumlulugundadir; VDB zayif
  parametre secimini engellemez, yalnizca API'yi sunar.
- **Anahtar saklama**: dosya anahtari surec belleginde tutulur; bellek
  sifreleme (mlock/zeroize garantisi) platforma baglidir ve burada
  iddia edilmez.
- **FIPS/SIL/certified**: **iddia edilmez**. Bu belge yalnizca olculen
  davranisi kaydeder.
- **OpenSSL surum matrisi**: 3.2+ Argon2 saglasa bile mevcut `K6` sembol
  seti Argon2'yi baglamaz; yeniden degerlendirme gerekir.

---

## 6. Yapilan duzeltmeler (ozet)

- DCPcrypt bagimliligi kaldirildi; yerine saf Pascal cekirdek
  (`VDbCryptoCore.pas`) geldi.
- Provider sozlesmesi soyut sinif olarak kayit altina alindi (`K1`).
- `R-5` ile varsayilan **builtin** yapildi; "OpenSSL birincil" onceligi
  kaldirildi, sessiz fallback yasagi korundu.
- `K6` ile yetenek sorgusu zorunlu hale getirildi (deneme-yanilma yok).

---

## 7. Gelecek is

1. `builtin` icin >64 B HMAC anahtar destegi (ADR 6 borcu).
2. Ayri `VDbCryptoKdf` birimi ve Argon2id parametre politikasi.
3. OpenSSL 3.2+ icin Argon2 sembol baglama ve yeniden degerlendirme.
4. Kripto fuzz/negatif test genisletmesi (bozuk tag, kirpik anahtar,
   yanlis nonce) - mevcut `crypto_kat` bunu kapsamaz.
