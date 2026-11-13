# DCPcrypt Kullanım Envanteri (Phase 0 — DCPCRYPT_USAGE_INVENTORY)

> Tarih: 2026-11-13 · Yöntem: `uses` clausule taraması + çağrı noktası inceleme + .lpi/.lpr/build script taraması.
> Amaç (skill §0.4, §3.5): DCPcrypt'u derleme ve runtime'dan **çıkarmak** — ama primitifleri sıfırdan yazmadan.

## 1. Vendor'lanan dosyalar (kaldırılacak yüzeyin tamamı)

```
dcpcrypt/
  DCPcrypt2.pas        framework ( algoritma sınıfları, CFB/OFB sarmalama )
  DCPconst.pas         sabitler
  DCPblockciphers.pas  blok şifre tabanı
  DCPbase64.pas        Base64
  Ciphers/DCPrijndael.pas + .inc   AES
  Hashes/DCPsha256.pas             SHA-256
  MIT_license.txt, Readme.txt
  (+ derlenmiş .o/.ppu artifactları — build kirliği, depoya girmemeli)
```

**Kullanılan primitif = 3 tane:** AES-256 blok şifre, SHA-256, Base64. DCPcrypt'un geri kalanı (diğer cipher/hash'lar, packet formatı, compressed packet) **hiç kullanılmıyor**.

## 2. Doğrudan tüketici haritası

| Dosya | DCP primitive kullanımı | Satır kanıtı |
|---|---|---|
| `VDbCrypt.pas` | `TDCP_rijndael` (AES-256-ECB bloğu GCM'in CTR katmanı için), `TDCP_sha256`, HMAC-SHA256 iskeleti | `uses` satırı: `DCPcrypt2, DCPblockciphers, DCPrijndael, DCPsha256`; class-of trick `203-360`; `HmacSha256Raw` ~`640` |
| `VDbPgWire.pas` | `DCPbase64` — SCRAM mesajlarındaki base64 | `uses` + `VDbPgWire.pas:60` (base64 yorumu) |

**Başka hiçbir kök .pas dosyası DCP unit'lerini doğrudan kullanmıyor.** VDbCrypt/VDbKdf/VDbPageCrypto **facade**: `VDbCore, VDbTable, VDbBackendV3, VDbPageStore, VDbPageCrypto, VDbPageWal, VDbPgWire` yalnız bu facade'leri tanır. → Kaldırma blast-radius = **2 dosya**.

## 3. VDbCrypt.pas içindeki KENDİ-YAZIM katman (DCPcrypt'ten bağımsız, kalacak/korunacak kısım)

DCPcrypt yalnız **bloksal AES ve SHA-256** sağlıyor; modların tamamı elle yazılmış:

| Katman | Yer | Akıbet kararı (ADR'ye girer) |
|---|---|---|
| GCM: GHASH + Gctr Xor | `VDbCrypt.pas ~417-584` | OpenSSL EVP_aead_aes_256_gcm'e geç **veya** NIST KAT ile mühürle. Format değişmezse ikisi de geçerli; geçişte ciphertext uyumluluğu test edilmeli |
| AES-256-CBC/PKCS7 (eski envelope) | `~1007-1050` | legacy; yeni yazım yoksa salt-okunur bırak, provider'a devret |
| HMAC-SHA256 | `~640` | OpenSSL HMAC'a devret (kendi SHA256 iç implementasyonu zaten DCP'den geliyordu) |
| SHA-256 iç implementasyonu | `~100-380` (DCP sınıfını saran kendi transform'u) | OpenSSL veya FPC-external ile değiştir |
| CRC32 | `~735+` | DCP'den bağımsız kendi tablosu — kalsın (`VDbCrc32.pas` ayrıca var; tek kaynağa indirilecek) |
| CSPRNG `VDbCryptRandom` | `~48-49,666-723` | DCP'den bağımsız — kalsın, provider'a taşınabilir |
| `VDbKdf.pas` BLAKE2b+Argon2id | kendi yazımı, DCP bağımlılığı YOK | ADR: KAT ile mühürle veya libsodium/ARGON2 provider'ına taşı |

## 4. Format etkisi (veri uyumluluğu — skill "kaybetme" kırmızı çizgisi)

- `.key` dosyası formatı: Argon2id çıktıları + layout → primitif değişirse **bit düzeyinde aynı çıktı** zorunlu (KAT + mevcut .key dosyalarıyla round-trip testi).
- Sayfa zarı: `nonce|ct|tag`, AAD `VDB3PG|pageno|salt` → AES-GCM **standart**; provider değişse bile ciphertext uyumlu olmalı (uyumluluk testi: eski DCP tabanlı şifreli .odb'yi yeni provider ile aç).
- SCRAM verifier: RFC 5802 standart primitifler → base64/SHA256/HMAC değişimi verifier'ları bozmaz, yine de mevcut kullanıcı verifier'larıyla t-testi yapılır.
- Eski AES-CBC envelope dosyaları: decrypt-yaz-yeniden-encrypt göç yoluna ihtiyaç doğarsa `vdbmig`'e görev yazılır.

## 5. Derleme/dağıtım bağları (kaldırılacak satırlar)

- `vdbapi.lpi`: `PackageName="dcpcrypt"`, iki `-Fu...\dcpcrypt...` SearchPath satırı (biri olmayan `lib\i386-win32` dizinine işaret ediyor — zaten bozuk).
- `vdbcli.lpi`, `vdbmig.lpi`, `vdbserver.lpi`: `-Fu ...dcpcrypt(-Ciphers/-Hashes)` satırları.
- `build_dll.ps1:58-62` (`VDbCore->VDbCrypt->DCPcrypt` yorumlu).
- `build_lib.sh:67-69` (linux/mac yolları).
- `dcpcrypt/` klasörünün kendisi + LICENSE notu (MIT — attribution README'de geçiyor; kaldırınca README bağımlılık satırı güncellenir).

## 6. Önerilen hedef mimari (skill §3 birim adlarıyla)

```
VDbCrypto.pas        ← facade: bugünkü VDbCrypt public API'sini korur (breaking change yok)
VDbCryptoTypes.pas   ← TxCryptoError tipleri, enum'lar
VDbCryptoProvider.pas← provider arayüzü: Hash/Hmac/Aead/AesCbc(Legacy)/Random/Kdf
VDbCryptoOpenSSL.pas ← birinci provider: libeay/ssleay dinamik yükleme (VDbTls'deki kalıp AYNEN tekrar kullanılır)
VDbCryptoBuiltin.pas ← geçici ikinci provider: mevcut DCP tabanlı kod buraya TAŞINIR (silinmez), KAT ile mühürlenir
VDbCryptoRandom.pas  ← bugünkü VDbCryptRandom olduğu gibi taşınır
VDbCryptoKdf.pas     ← VDbKdf facade'i; provider arkasında Argon2id
VDbCryptoSelfTest.pas← NIST CAVP/KAT vektörleriyle açılış öz testi (skill §0.8 fail-closed)
```

Geçiş sırası (skill §16 görev 6→7→8 ile birebir):
1. Provider arayüzü + OpenSSL provider + SelfTest (henüz DCP duruyor, çift yol).
2. `VDbCrypt.pas` internal çağrıları provider'a bağla; `VDbPgWire` base64 → kendi küçük base64'ü veya FPC `MimeTypes`/kendi unit'i (DCPbase64'ün tek kullanım olduğu yer).
3. Hiçbir caller DCP unit'i import etmiyorken .lpi/.lpr/build script satırlarını sil, `dcpcrypt/` klasörünü depodan çıkar, gate'leri koştur.

**Yasak (skill §0.4):** bu geçişte "hızlı olsun" diye yeni elle-GCM/AES yazmak yok. OpenSSL provider birincildir; builtin provider yalnız **mevcut kanıtlanmış kodun taşınması + KAT mührü**dür.
