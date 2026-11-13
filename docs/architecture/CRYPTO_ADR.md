# CRYPTO ADR — VDB V3 Kriptografi Mimarisi Kararları

> **Durum:** Kabul edildi (K1–K6 bağlayıcı kararlar; uygulama sırası §3'te, EK A.5 4→5→6 görev kapılarına bağlı).
> **Tarih:** 2026-11-13 · **Ortam:** FPC 3.2.4 / Lazarus 4.4 (BASELINE.md §1).
> **Kaynaklar:** `docs/engineering/BASELINE.md` (§5, §8), `docs/engineering/DCPCRYPT_USAGE_INVENTORY.md` (§3–4, §6), `VDB_V3_PRODUCTION_HARDENING_SKILL.md` §3 + EK A.3/A.4 (R-1, R-2).
> **Kırmızı çizgi (skill §0.4):** Bu ADR hiçbir yerde **yeni kripto primitifi yazılmasını önermez**. OpenSSL provider birincildir; builtin provider yalnız **mevcut, kanıtlanmış kodun taşınması + KAT mührü**dür (INVENTORY §6 satır 78).
> **İddia sınırı:** Bu belge hiçbir primitifin, provider'ın veya sürümün "production-ready" olduğunu iddia etmez; FIPS iddiası skill §3.1 (satır 86) gereği doğrulanmış modül olmadan yapılmaz.

**API adlandırma düzeltmesi:** `DCPCRYPT_USAGE_INVENTORY.md` §3'te geçen `EVP_aead_aes_256_gcm`, BoringSSL'in tek-atımlık AEAD API'sidir; **OpenSSL'de bu sembol yoktur**. Bu ADR OpenSSL'in gerçek API'sini kullanır: `EVP_aes_256_gcm()` (EVP_CIPHER) + `EVP_CIPHER_CTX_*` + `EVP_CTRL_GCM_*`, MAC için `HMAC()`, PBKDF2 için `PKCS5_PBKDF2_HMAC()`.

> **SAHİP KARARI (2026-11-13, bu ADR'nin üstündedir — K1'in "OpenSSL birincil" önceliğini değiştirir):**
> VDB **saf native, bağımlılıksız, harici DLL'siz** bir veritabanıdır (readme.md:3-4 temel sözü; kullanıcı talimatı 2026-11-13). Bu yüzden **built-in provider birincil (default) provider'dır** — yani depoda satır satır duran ve KAT ile mühürlenmiş kendi kodumuz: `VDbCrypt.pas` GCM/HMAC/PBKDF2 + `VDbKdf.pas` BLAKE2b/Argon2id (RFC 9106 vektörlü). OpenSSL yalnız **opsiyonel hızlandırma/doğrulama provider'ıdır** ve hiçbir zorunlu akış OpenSSL'e bağlı çalışmaz. Provider seçimi konfigürasyonladır; default'ta hiçbir dış DLL aranmaz, yüklenmez, istenmez.
> Bu karar K6'nın "DLL yok → crypto kapalı" maddesini **geçersiz kılar** (yerine: DLL yok → builtin zaten çalışıyor, kimse bir şey fark etmez); K5'in çift-provider KAT'ı iki koşulda geçer: OpenSSL DLL'i varsa cross-check, yoksa builtin tek başına (mevcut kapı). DCPcrypt kaldırma gerekçesi (skill §0.4: bakımsız vendored stack) değişmez; kaldırmadan sonra builtin yolun AES/SHA-256 çekirdeği `VDbCryptoBuiltin` içine taşınmış KAT-mühdar kendi kodumuzdur (INVENTORY §6 "kod kopyalanır" satırı), harici bağımlılık değildir.

---

## 1. Bağlam ve Kuvvetli Durum

Bugünkü gerçek (doküman iddiası değil, dosya kanıtı — BASELINE kuralı):

**Primitif gerçeği.** Vendored DCPcrypt'tan **fiilen 3 primitif** kullanılıyor: AES-256 blok (`TDCP_rijndael`), SHA-256 (`TDCP_sha256`), Base64 (`DCPbase64`) (INVENTORY §1–2, EK A.2). Doğrudan tüketici **2 dosya**: `VDbCrypt.pas:181` (`uses DCPcrypt2, DCPblockciphers, DCPrijndael, DCPsha256, VDbKdf`) ve `VDbPgWire.pas:60` (`DCPbase64`, SCRAM base64'ü). Blast-radius = 2 dosya (INVENTORY §2).

**Kendi-yazım katman (silinemez, formatın parçası).** DCPcrypt yalnız blok AES + SHA-256 veriyor; modlar elle yazıldı (BASELINE §5 satır 82; INVENTORY §3):

| Katman | Kanıt | Not |
|---|---|---|
| AES-256-GCM (GHASH + CTR, GF(2^128)) | `VDbCrypt.pas:417` (`AesBlockOf`), `:429` (`GHashOf`), `:487` (`GcmCtrXor`), `:507/:549` (`GcmSeal/GcmOpen`) | DCP AES bloğu üstünde saf Pascal |
| BLAKE2b + Argon2id | `VDbKdf.pas:22-24`; başlık: RFC 9106 vektörleriyle doğrulanmış, yalnız Argon2id, secret/AD destekli (`VDbKdf.pas:2-10`), lane'ler thread'li (`:393+`) | DCP bağımlılığı YOK |
| HMAC-SHA256 iskeleti | `VDbCrypt.pas ~640` (`HmacSha256Raw`), `VDbCryptHmacSha256` | SHA-256 içi DCP'den |
| PBKDF2-SHA256 | `VDbCrypt.pas:72` (`VDbPbkdf2Sha256`), `VDB_PBKDF2_ITER = 200000` (`:56`) | |
| CSPRNG | `VDbCryptRandom` `VDbCrypt.pas:666-719`: Windows `CryptAcquireContext/CryptGenRandom` (`:683-692`), Unix `/dev/urandom` (`:700-715`); kaynak yoksa **fail-closed hata** (`:716-717`; LCG fallback kaldırıldı, `:696-699`) | DCP'den bağımsız, iyi |
| Eski zarflar | kayıt: `VDBAEAD1|nonce|GCM|tag` (yeni), `IV|len|AES-256-CTR|HMAC-tag` (eski, okunur) — `VDbCrypt.pas:11-20`; AES-CBC legacy bölgesi INVENTORY §3 (`~1007-1050`) | salt-okunur legacy |

**Facade gerçeği.** `VDbCrypt`, `VDbKdf`, `VDbPageCrypto` facade; `VDbCore, VDbTable, VDbBackendV3, VDbPageStore, VDbPageWal, VDbPgWire` yalnız facade'leri tanır (INVENTORY §2). Public API yüzeyi `VDbCrypt.pas:48-130`.

**Zar formatı (V3 sayfa şifreleme, default kapalı).** `nonce(12) | ct(4096) | tag(16) = 4124`; AAD = `'VDB3PG' | pageno LE32 | salt(16)` (`VDbPageCrypto.pas:8-10, 28-35, 112-124`). Tag doğrulanmadan plaintext açılmıyor; yanlış anahtar/bozuk zarf/sayfa karıştırma tek temiz hata (BASELINE §5 satır 76). **Nonce her `Seal` anında 12 rastgele bayt** (`VDbPageCrypto.pas:139`) — hacim/çakışma analizi YOK (BASELINE §5 satır 78; EK A.3 satır 750). Zarflar hem ana dosyada hem WAL'da (`VDbPageWal.pas:806` sarmalar, `:1242` açar) hem kopya/yedek yollarında (`VDbPageStore.pas:3701, 3902`).

**Meta/superblock.** Başlık sayfası: `VDB3` magic (`VDbPageStore.pas:38`), sürüm alanı bytes 4–7 (`VDB_FILE_VER=5`, eski 3/4 okunur: `:39-46`, kontrol `:1027-1031`, yazılabilir oturumda yerinde yükseltme deseni `:1054-1058`), şifreleme alanları: `SALT@36(16) | ITER@52(4) | KEYCHECK@56(16) | FLAGS@72(ENC biti) | DBID@76(8)` (`:79-87`); CRC sayfanın sonunda, offset 4092 (`VDbPage.pas:35`) → **offset 84 sonrası meta'da boş alan var**. Eski dosya→ `.gen` DB kimliği/nesil damgası klon-bayatlama koruması zaten var (C-2, `:84-103`). Yazar kilidi + `VDB_DEF_BUSY_MS` deseni mevcut (`:71-76`).

**KDF tutarsızlığı (R-2'nin konusu).** `.key` dosyası → Argon2id **v2** (yazım biçimi): başlık `VDBK\0|ver|tuzUz|…`, `VDB_KEYFILE_VER_ARGON2=2`, parametreler dosyadan okunur, **t=3, m=65536 KiB (64 MiB), p=4** (`VDbCrypt.pas:59-70`; RFC 9106 ikinci önerilen ayar notu `:68-69`; yazım `:835+`; dosyada SIR YOK — yalnız salt+parametre+verifier, `:91-99`). Buna karşın **sayfa şifreleme parola→key → PBKDF2-SHA256 200k iter** (`VDbPageCrypto.pas:35, 92-98`; `VDbPageStore.pas:956, 980-983`; iter meta'da saklanıyor, `<1` ise normalize `:981`). Aynı proje, iki KDF → karar bu ADR'de (BASELINE §8 madde 4).

**Keycheck.** 16 baytlık HMAC tabanlı doğrulayıcı meta/WAL başlığında açık durur — **secret değil, doğrulayıcı** (`VDbPageCrypto.pas:16-18, 67-77`; EK A.3 satır 753 "doğru kullanım"). Parmak izi 8 hex (`:79-90`).

**OpenSSL altyapısı (hazır kanal).** `VDbTls.pas` OpenSSL'i **dinamik** yüklüyor: `LoadPair` LoadLibrary/GetProcAddress + sembol kontrolü + eksik sembolde temiz hata (`:130-216`), `InitLibs` tek sefer + kilit + `VDB_SSL_DLL`/`VDB_CRYPTO_DLL` env override (`:218-230`), matris `libssl-3/libcrypto-3`, `1_1`, eski `ssleay32/libeay32` (`:6-8, 236, 241`). DLL yok → TLS **kapalı + temiz hata**, sessiz düşüş yok (`:2-8, 51-52`). BASELINE §2: OpenSSL zaten build'de → crypto provider için hazır kanal.

**SCRAM.** PG sunucu auth SCRAM-SHA-256; parola sunucuda durmuyor, verifier (`Salt|Iterations|StoredKey|ServerKey`) tutuluyor (`VDbPgWire.pas:65-72`); iterasyon kelepçesi **≥15000, ≤1.000.000** (`:2361-2362`); base64 DCP'den (`:60`).

**Kuvvetler.** (a) skill §0.4: yeni primitif yok; (b) "kaybetme" kırmızı çizgisi: eski şifreli `.odb`, `.key` v1/v2 ve SCRAM verifier'ları bit düzeyinde okunabilir kalmalı (INVENTORY §4); (c) C API 57 export — public API kırılmaz; (d) OpenSSL sürüm matrisi 1.0.2–3.x (VDbTls) ama OpenSSL'de Argon2 ancak ≥3.2'de `EVP_KDF` ile var; (e) BASELINE §5/§8'in somut borçları: nonce analizi, KDF politikası, DCP kaldırması; (f) Windows'ta CNG/CryptoAPI güvenilmez çıktı (denendi, `VDbCrypt.pas:4-9`) → tek modern stack OpenSSL.

---

## 2. Kararlar

### K1 — Provider mimarisi: OpenSSL birincil, builtin = taşınmış kanıtlanmış kod

**Karar.** INVENTORY §6'nın birim seti kurulur:

- `VDbCrypto.pas` — public facade. **Bugünkü `VDbCrypt.pas` interface'i (`:48-130`) imza değişikliği olmadan korunur** (`VDbCryptRandom/NewKey`, `VDbPbkdf2Sha256`, `VDbCryptDeriveKey/Verifier/KeyFromPassword`, `VDbCryptEncrypt/Decrypt/EncryptLegacy`, `VDbDapiProtect/Unprotect`, `VDbKeyFileWrite/Read`, `VDbCryptHmacSha256/Sha256/Aes256Block`, `VDbCryptGcmSeal/GcmOpen`, AeadSeal/Open). Çağıran hiçbir modül (VDbPageCrypto, VDbPgWire, VDbPageStore, …) çağrı noktasını değiştirmez; C API 57 export'a dokunulmaz.
- `VDbCryptoTypes.pas` — algoritma/kimlik enum'ları, `EVdbCryptoError` benzeri tipli sınırlar.
- `VDbCryptoProvider.pas` — provider sözleşmesi: `HashSHA256 / HmacSHA256 / AeadSeal / AeadOpen (AES-256-GCM) / AesCbcLegacyDecrypt (salt-okunur) / Pbkdf2Sha256 / Argon2id / Random / SelfTest / capabilities`.
- `VDbCryptoOpenSSL.pas` — **birincil** provider; K6'daki dinamik yükleme kalıbıyla (VDbTls birebir).
- `VDbCryptoBuiltin.pas` — **ikincil, açıkça opt-in**: bugünkü elle-yazım GCM katmanı (`VDbCrypt.pas:375-584`), HMAC/PBKDF2 iskeleti, BLAKE2b+Argon2id (`VDbKdf.pas`) ve DCP kökenli **AES blok + SHA-256 çekirdeği buraya TAŞINIR** (kod kopyalanır; `dcpcrypt/` klasör bağımlılığı kalkar, MIT attribution README'de kalır — INVENTORY §5 satır 58). Builtin, tüm KAT seti (K5) geçmeden release binary'ye giremez.
- `VDbCryptoRandom.pas` — `VDbCryptRandom` olduğu gibi taşınır (fail-closed davranışıyla).
- `VDbCryptoKdf.pas` — `VDbKdf` facade'ini provider arkasına alır (K3).
- `VDbCryptoSelfTest.pas` — K5.
- Seçim kuralı: **konfigürasyonla seçim, otomatik/gizli fallback YOK** (skill §3.1 satır 81). OpenSSL varsa varsayılan odur; builtin ancak açık opt-in ile ve açılış logunda provider adı + KAT mühür durumuyla görünür.

**Gerekçe.** Blast-radius 2 dosya ve facade'ler sağlam → provider arayüzü mevcut public API'nin **altına** gizlenebilir, breaking change zorlamadan (INVENTORY §2, §6). OpenSSL zaten build'de ve dinamik yükleme kalıbı kanıtlanmış (BASELINE §2). Elle-yazım GCM/Argon2 kodu veri formatının parçası; silmek veri kaybı, sıfırdan yazmak §0.4 ihlali (EK A.2) — tek doğru tedavi: taşı + KAT ile mühürle. Builtin'in DCP'den bağımsızlaşması, dcpcrypt klasörü silinirken K6'sız ortamlarda (OpenSSL DLL'siz) eski verinin okunabilir kalmasını da garanti eder.

**Sonuçlar.** +1 katman (provider dispatch) ihmal edilebilir maliyet; builtin kodun çift bakımı geçici yük (K5 mührüyle sınırlı, hedef: salt-okunur uyumluluk + selftest rolüne inmek); OpenSSL'sız kurulumlarda crypto politika gereği kapalı (K6) → operasyon dokümanında DLL dağıtımı zorunlu madde (BASELINE §8 madde 8). Builtin tek başına "provider doğrulaması" sayılmaz (skill §3.1 satır 77): cross-provider aynı-şifre-metni testleri kalıcı gate olur.

### K2 — AEAD nonce politikası (R-1): **SEÇİM (a) — deterministik nonce**; eski zar salt-okunur

**Karar.** Yeni yazımlar (crypto format v2) deterministik nonce kullanır — R-1'in "tercih edilen" dalı (skill satır 758):

```
v2 zarf (boyut DEĞİŞMEZ, 4124 bayt):
  nonce(12) = key_gen(2, LE) | page_no(4, LE) | rewrite_seq(6, LE)
            | ct(4096) | tag(16)
v2 AAD      = 'VDB3PG' | page_no(4, LE) | salt(16) | fmt(1)=0x02
```

- **Reuse matematiksel olarak imkânsız** (tek key-gen-instance işletimi içinde): nonce bir fonksiyondur `(key_gen, page_no, rewrite_seq)`; çakışma için aynı anahtar altında aynı `(page_no, rewrite_seq)` çiftine iki **farklı** düz metin oturmalı. Kural: `rewrite_seq` her seal'de katı artar, zarfın kendi nonce alanında şifre metniyle birlikte kalıcıdır (dışarıdan görünür) ve `next_seq = 1 + max(ana dosyadaki zarfın seq'si, WAL kayıtlarındaki seq'ler)`. **Recovery asla yeniden sarmalamaz**: WAL zarfı aynen (baybayt) replay edilir — `VDbPageWal.pas:806` zaten zarfı WAL'a yazar, `:1242` onu açar. Crash'ten sonra o sayfanın eski seq'li zarfı ya diskte ya WAL'dadır ve yeni yazım daha yüksek seq alır.
- **Birthday analizi deterministik modda isabetsizdir** (rastgele çarpışma uzayı yok); bunun yerine tasarım tavanı: 48-bit `rewrite_seq` → sayfa başına 2^48 yeniden-yazım; 16-bit `key_gen` rotasyon sayacı. R-1'in istediği hacim hesabı böyle karşılanır: random nonce'un 2^32 birthday tavanı tartışması ortadan kalkar.
- **Format sürümü nasıl taşınır (zar/superblock):** Per-zarf versiyon **tahmin edilmez** (v1 rastgele nonce ile ayırt etme kırılganıdır). Tek otorite **superblock**'tur: meta sayfada offset 84 sonrası boş alana (CRC@4092'ye kadar — §1) **crypto-v2 yapısı** yazılır: `crypto_fmt_ver(1)=2 | kdf_id(1) | key_gen(2) | kid(8) | argon(t:1, m_kib:4, p:1) | ayrılmış`. Eski dosyalarda bu yapı yoktur → v1 zar, rastgele nonce, mevcut `ITER@52` alanı ile okunur (salt-okunur uyumluluk). **Geçiş atomiktir:** v2 moduna geçiş, dosya-kopyası-üzerinden-toplu-reseal yoluyla yapılır (sayfa gez + Seal + yaz deseni kopya yollarında hazır: `VDbPageStore.pas:3691-3711, 3888-3909`), meta v2 yapısı yeni dosyaya yazılır, sonra atomik isim takası. Böylece hiçbir anda iki format aynı dosyada karışmaz; `LoadMeta`'nın yerinde yükseltme deseni (`:1054-1058`) korunur ama şifre formatı yükseltmesi **copy+swap** ile olur, yerinde değil.
- **Eski zar (v1, random nonce):** daima **salt-okunur** açılır; v2 moduna geçmemiş dosyalarda yazımlar bugünkü gibi random nonce ile devam eder (mevcut davranış, kapı: aşağıdaki testler). Random nonce yolu yalnız eski dosyalar içindir; yeni store yaratımları v2 başlar.
- **Kapanmayan açıklar politika ile kapatılır** (dürüst kapsam): (1) **klon+write** — aynı dosyanın iki kopyası aynı key_gen+seq ile yazarsa reuse olur: `.gen` DBID/nesil damgası bayat-yazımı zaten reddediyor (C-2, `VDbPageStore.pas:84-103`); ek kural: **encrypted DB kopyası yeni DBID ile açılırsa yazma için rekey zorunlu** (K4 rotasyon akışı), aksi halde salt-okunur. (2) **multi-process** — deterministik nonce tek-yazar discipline gerektirir: mevcut yazar kilidi (`VDB_DEF_BUSY_MS`, `:71-76`) şifreli dosyada zorunlu; kilidi aşan ikinci yazar kabul edilmez. (3) Replikasyon: V3 TCP replikasyonda şifreli sayfa zaten desteklenmiyor (BASELINE §4); gelecekte replika-başına-ayrı-anahtar tasarım kuralı olur.

**Gerekçe.** R-1 random nonce'u üç koşula bağladı: reuse analizi, birthday hesabı, clone/rollback testi (skill satır 758). Rastgele 12B'de bu üçünün sağlanması zor ve kırılgandır (crash+restore seq'siz ortamda nonce'u kaybeder, klon sessiz çarpıştırır; bugünkü kodda hiçbir analiz yok — BASELINE §5 satır 78). Deterministik tasarım reuse sınıfını konstrüksiyonla kapatır, zarf boyutunu değiştirmez, mevcut WAL-zarf mimarisiyle (`VDbPageWal.pas:806/1242`) doğal uyumludur ve skill'in açık tercihidir.

**Sonuçlar.** Zarf başına CSPRNG çağrısı kalkar (performans +); `VDbPageStore`'a per-page seq takibi (okunan zarfın nonce'undan türetilir — ek disk alanı gerektirmez) ve copy-reseal yolunu "crypto yükseltme/rekey" görevi olarak yeniden adlandırma işi girer; eski dosyalar okunmaya devam eder (kırmızı çizgi korunur); R-1'in (b) dalının birthday/klon/rollback analizleri (a) seçilse de **test edilmeye devam edilir** (kabul kriteri §5/4) çünkü klon ve rollback riskleri nonce üretimiyle değil işletim politikasıyla kapanır.

### K3 — Tek-KDF politikası (R-2): yeni yazımlar Argon2id; PBKDF2 salt-okunur legacy; SCRAM tek istisna

**Karar.**

1. **Hedef ve tek yazım KDF'i: Argon2id.** Paroladan depolama-anahtarı türeten **yeni her yazım** Argon2id'dir. Parametreler bugün `.key` v2'de kullanılan ve RFC 9106'nın ikinci önerilen ayarına oturan değerlerle sabitlenir (koddan, `VDbCrypt.pas:66-70`):
   - `t (time cost) = 3`, `m = 65536 KiB = 64 MiB`, `p (lanes) = 4`, çıktı 32 bayt.
   - **Storage hesabı:** türetme başına 64 MiB bellek (Argon2 blokları), `p=4` lane paralel thread'lerle işleniyor (`VDbKdf.pas:388-404` `TArgonLaneThread`); CPU maliyeti = 3 tam bellek pasası. Sunucuda eşzamanlı giriş × 64 MiB en-kötü bellek bütçesi **ölçülüp gate'e bağlanır** (sayı iddia edilmez); eşzamanlı parola türetimi için kuyruklama/limit, skill §7.1'in eksik throttling işiyle (BASELINE §5 satır 80) birlikte ele alınır.
   - Self-test **üretim parametresiyle değil**, RFC 9106 §5.1'in küçük parametreli vektörleriyle koşar (K5) — açılışı yavaşlatmaz.
2. **PBKDF2-SHA256-200k salt-okunur legacy.** Sayfa-parola yolu `VDbPageCrypto.pas:35` (`VDB_ENC_ITER=200000`) ve `:92-98` yalnız **eski `.odb` dosyalarını açmak** için kalır (meta'daki `ITER@52` alanından iterasyon okunur, `VDbPageStore.pas:980-983`); yeni yazımda kullanılmaz. `VDbCryptDeriveKey/VDbPbkdf2Sha256` facade API olarak kalır (K1 — breaking change yok), iç politikası "legacy-read" etiketlidir. `.key` v1 (PBKDF2, `VDB_KEYFILE_VER=1`) okunmaya devam eder; `.key` yazımı v2 (Argon2id) — bugünkü davranışın kodlaşması (`VDbCrypt.pas:25-26, 62-63, 835+`).
3. **KDF kimliği metadata'da (R-2 "format versiyon alanı KDF kimliğini taşır"):**
   - Yeni `.odb`: K2'nin crypto-v2 yapısındaki `kdf_id(1)` baytı + Argon2 parametre bloğu (`t, m_kib, p`) otoritedir. `kdf_id` enum: `1=PBKDF2-SHA256, 2=Argon2id` (SCRAM `3` almaz — bkz. 4).
   - Eski `.odb`: crypto-v2 yapısı yok → `kdf_id = PBKDF2`, iterasyon `ITER@52`'den.
   - `.key`: başlık sürüm baytı zaten KDF kimliği (`V1=PBKDF2`, `V2=Argon2id`; v2 başlığı `t/m/p`'yi dosyadan okur — `VDB_KEYFILE2_HEAD`, `VDbCrypt.pas:65`).
4. **Belgelenmiş tek istisna — SCRAM-SHA-256.** RFC 5802 SaltedPassword'u PBKDF2-HMAC-SHA256 ile **tanımlar**; değiştirmek wire protokolünü kırar. R-2'nin kapsamı "depolama anahtarı türetmeleri"dir; SCRAM verifier bir protokol artefaktıdır ve (a) sunucuda parola/key saklamaz (`VDbPgWire.pas:65-72`), (b) iterasyon kullanıcı-başına-saklanır ve kelepçelenir `≥15000, ≤1.000.000` (`:2361-2362`), (c) protokol KAT'ı K5'te test edilir. Argon2id'li auth mekanizması (SCRAM-SHA-256-PLUS değil, ayrı mekanizma) ileride ayrıca tartışılır — bu ADR kapsamı dışı.

**Gerekçe.** BASELINE §8 madde 4'ün "karar + göç planı şart" dediği çelişki (`.key`→Argon2id vs sayfa→PBKDF2-200k, BASELINE §5 satır 77) böyle kapanır: hedef teknoloji bellidir, eski veri formatı kırmızı çizgi gereği okunur, KDF kimliği formatla taşınır ki ileride parametre yükseltmesi (örn. m=128 MiB) ayırt edilebilsin. Argon2id'nin kaynağı `VDbKdf.pas` mevcut, RFC 9106 vektörleriyle doğrulanmış kanıtlanmış koddur — §0.4'e uygun (yeni primitif yazılmıyor).

**Sonuçlar.** Sayfa-şifreli yeni DB'lerde açılışta 64 MiB'lık türetme maliyeti (PBKDF2-200k'ya göre pahalıdır; kullanıcı etkisi ölçülür, değilse argon2 parametre düşürme kaçamağı **yasak**, bunun yerine parametre metadata'da yükseltilebilir olduğundan gelecek revizyona bırakılır); copy-reseal (K2) geçişi sırasında eski `ITER` alanı okunur kalır, yeni dosyada `kdf_id=Argon2id` yazılır; `.key` dosyalarında bit-düzeyi uyumluluk KAT + mevcut `.key` fikstürleriyle round-trip testiyle garanti edilir (INVENTORY §4 satır 47).

### K4 — Key management: DEK/KEK, key metadata, rotasyon; at-rest plaintext YOK

**Karar.**

1. **DEK/KEK ayrımı.** Sayfaları saran 32-baytlık anahtar bir **DEK**'dir ve CSPRNG ile rastgele üretilir (`VDbCryptRandom`, fail-closed — `VDbCrypt.pas:666-719`); parolanın kendisi veya doğrudan ham türetmesi DEK olarak **kullanılmaz**. DEK, bir **KEK** ile sarılır (wrap): `AES-256-GCM(DEK)`; wrap'ta AAD = key-metadata (kid|alg|kdf|key_gen) — domain separation. KEK kaynakları (yazım sırasıyla desteklenen):
   - (i) parola → **Argon2id** (K3) → KEK;
   - (ii) Windows DPAPI kullanıcı-kapsamı sarmalama — mevcut `VDbDapiProtect/VDbDapiUnprotect` kanalı (`VDbCrypt.pas:22-26, 88-89`), yalnız Windows, "kullanıcı hiç parola girmez" UX'i için;
   - (iii) dış KMS/HSM — tasarım-kapısı açık, uygulama bu ADR kapsamı dışı (skill §3.3 satır 104).
2. **Key metadata (key metadata'da kid/alg/kdf/rotasyon).** K2'nin crypto-v2 yapısı + `.key` başlığı genişletmesi: `kid (8B CSPRNG)`, `alg` (bugün için sabit AES-256-GCM), `kdf_id + parametreler` (K3), `key_gen` rotasyon sayacı, yaratılma zamanı, `wrapped DEK (nonce|ct|tag)`, `keycheck`.
3. **Keycheck verifier secret olarak kalmaz — doğru kullanım korunur.** Meta/WAL'daki 16B doğrulayıcı `HMAC-SHA256(key, 'VDB3-PAGE-KEY-v1')` öneki truncasyonu modelidir (`VDbPageCrypto.pas:16-18, 67-77`) — anahtarı vermez, türetilemez; EK A.3 satır 753 bunu "iyi" olarak onaylamış. v2'de label'a kid bağlanır (kötüye-anahatar-değişimi karıştırması ayrı hataya iner). Açılış akışı bugünkü `CheckEncryptionOnOpen` modeliyle aynı kalır: wrong-key tek temiz hata (`VDbPageStore.pas:969-1006`).
4. **Rotasyon akışı (rekey):** `key_gen+1` + yeni `kid` + yeni DEK üret → copy-based reseal geçişi (K2'nin yolu) → tüm sayfalar yeni `(key_gen, seq=1..)` uzayında — `(key, key_gen)` farklı olduğundan nonce uzayları ayrık, reuse imkânsız → meta/keycheck atomik güncellenir → eski DEK geçersiz. Crash-resume: kopya-idempotent; yarım kalan geçiş eski dosyayı bozmaz. **Döndürülemez karar olarak:** rekey tamamlanınca eski anahtarla eski dosya okunamaz; bu, operatöre yazılı uyarı ile bildirilir.
5. **Plaintext key at-rest YOK (bağlayıcı kural).** Diskte, repoda, config'te, log'da, backup'ta düz anahtar/başlık-yasak (skill §3.3 satır 105). Denetim noktaları: meta'da yalnız wrapped DEK + doğrulayıcı; `.key` dosyasında SIR YOK kuralı sürer (`VDbCrypt.pas:91-99`); log/exception redaksiyonu — skill §3.1 satır 82.
6. **Sıfırlama dürüstlüğü:** Pascal heap'te kesin zeroization garantisi verilmez (skill §3.1 satır 83) — anahtar tamponları kapsam sonunda best-effort `FillChar(#0)` temizlenir; bu bir **kabul edilmiş risk** olarak burada kayıtlıdır, "güvenli silindi" iddiası edilmez.
7. **Key kaybı = veri kaybı.** Master parola kurtarma diye bir şey yoktur; dokümante edilir (skill §3.3 satır 107).

**Gerekçe.** Bugün DEK ile parola türetmesi aynı şey — parola değişimi/rotasyonu tüm dosyayı yeniden-anahtarlama demek, anahtar metadata verisi (kid/alg/kdf) yok. DEK/KEK, rotasyonu "DEK'i unwrap et, yenisiyle reseal et, KEK'i sabit bırak" akışına çevirir; nonce güvenliği (K2) key_gen sayacıyla rotasyona bağlanmıştır; wrap AEAD'i K1'in provider'ından gelir (yeni primitif yok).

**Sonuçlar.** Meta yapısı büyür (K2 yapısının parçası — tek yerinde genişletme); DPAPI kanalı platform-kapalıdır (Windows dışı (ii)'yi kullanamaz, sessiz düşmez — hata verir); rotasyon sırasında 2× disk alanı (kopya) — operasyon dokümanına yazılır; uygulama işi `VDbCryptoKeyStore.pas` (INVENTORY §6'nın §3.1 eşleniği) + `vdbmig`'e rekey komutu.

### K5 — Self-Test: NIST/RFC KAT vektörleriyle açılış öz testi, fail-closed

**Karar.** `VDbCryptoSelfTest.pas`: provider init'i sırasında ve şifreleme **ilk kez etkinleşmeden önce** sabit KAT seti koşar. **Başarısızlık → crypto özelliği etkinleşmez, temiz hata, plaintext düşüşü yok** (skill §3.1 satır 85). Vektör-primitif eşlemesi:

| Primitif | Vektör seti | Not |
|---|---|---|
| AES-256 blok | FIPS-197 App. C.3 | kodun kendi notu zaten bu vektörü işaret ediyor (`VDbCrypt.pas:118-121`) |
| AES-256-GCM | NIST CAVP GCM vs (şifreleme + doğrulama + AAD + **negatif** tag-mismatch) | SP 800-38D; her iki provider |
| SHA-256 | FIPS 180-4 / CAVP SHAVS | |
| HMAC-SHA-256 | RFC 4231 (test case'ler, uzun-anahtar dahil) | |
| PBKDF2-HMAC-SHA256 | RFC 7914 §11 vektörleri | RFC 6070 **SHA-1-only**'dır, kullanılmaz |
| Argon2id | RFC 9106 §5.1 (v1.3; secret/AD dahil ham-çıktı vektörleri, küçük parametre) | builtin referans; OpenSSL ≥3.2 varsa cross-check |
| BLAKE2b | RFC 7693 App. A/B (BLAKE2b-512 dahil) | |
| HKDF-SHA-256 | RFC 5869 Case 1–3 | K4 alt-anahtar türetmeleri HKDF'e geçtiği an zorunlu; o ana dek "uygulanmadı" olarak işaretli |
| SCRAM-SHA-256 | RFC 5802 §5 / RFC 7677 örnek vektörü | protokol regresyonu — verifier yolu |

Kurallar: (1) vektörler derlenmiş sabit fikstürdür, runtime'da indirilmez; (2) **self-test tek başına provider doğrulaması değildir** (skill §3.1 satır 77) — üzerine cross-provider aynı-şifre-metni testi ve eski-veri round-trip fikstürleri (EK A.5 madde 3) gate olur; (3) builtin provider yalnız bu set geçerse release'e girer (K1); (4) hata mesajları secret ifşa etmez (skill §3.1 satır 82).

**Gerekçe.** BASELINE §5 satır 82'nin tedavisi ("KAT ile mühürle") mekanikleşir: elle-yazım GCM/Argon2/BLAKE2b taşınırken bit-düzeyi davranışın bozulmadığı vektörle kanıtlanır; OpenSSL provider'ın sembol sürüm farkları (1.1 vs 3.x) açılışta yakalanır. Fail-closed, CSPRNG'de zaten kurulmuş davranışın (VDbCrypt.pas:716) genelleştirilmesidir.

**Sonuçlar.** Test fikstürleri repoya (küçük, üretilmiş değil kaynak — EK A.5 madde 3'in "üretici script + küçük fikstür" kuralı); açılış maliyeti ms mertebesinde küçük-parametre koşuları; gate'e `crypto_selftest` koşusu eklenir (CI yok — BASELINE §8 madde 6; önce `git init` önkoşulu hatırlatılır, EK A.1).

### K6 — OpenSSL dinamik yükleme: DLL yok → crypto kapalı + temiz hata; sessiz düşüş YOK

**Karar.** `VDbCryptoOpenSSL.pas`, `VDbTls.pas` kalıbını **birebir** tekrarlar (INVENTORY §6 satır 66): `LoadPair`-benzeri LoadLibrary + `GetProcAddress` ile sembol bağlama, hepsi-bir-arada sembol doğrulaması (biri eksik → kütüphane geri bırakılır, temiz hata — `VDbTls.pas:188-203` deseni), `InitLibs`-benzeri init-once + lock (`:218+`), `VDB_CRYPTO_DLL` env override (VDbTls'teki `VDB_SSL_DLL`/`VDB_CRYPTO_DLL` kanalının aynısı, `:228-229`).

- **Sembol kümesi (libcrypto):** `EVP_aes_256_gcm`, `EVP_CIPHER_CTX_new/free`, `EVP_EncryptInit_ex/EncryptUpdate/EncryptFinal_ex` (+ decrypt), `EVP_CIPHER_CTX_ctrl` ile `EVP_CTRL_GCM_SET_IVLEN / SET_TAG / GET_TAG`, `HMAC`, `PKCS5_PBKDF2_HMAC`, RNG gerekirse `RAND_bytes`. **Argon2id/BLAKE2b OpenSSL'de istenmez** (Aşağıdaki destek matrisi) — K3'ün builtin referans KDF'iyle kalır.
- **Destek matrisi:** OpenSSL **1.1.x ve 3.x** crypto-provider için bağlayıcı; 1.0.2 hattı yalnız TLS'te miras kalır (`VDbTls.pas:6-8`), crypto provider 1.0.2'yi desteklemez — `EVP_CIPHER_CTX_new` (≥1.1) öncesi statik-context API farkı hata yüzeyini büyütür. Gerekçe ve matris dokümante edilir (skill §3.5 "library version matrisi" maddesi).
- **DLL yok / sembol eksik / selftest başarısız → şifreleme kapalı + temiz hata**: hata mesajı denenmiş dosya adlarını ve önerilen env override'ı söyler (VDbTls'nin `VDbTlsAvailable/VDbTlsLastError` sorgu deseni, `:51-52`). **Sessiz düşüş yok**: builtin provider otomatik devreye girmez; girerse yalnız açık opt-in'dir ve açılışta loglanır (K1). TLS davranışı değişmez.
- **FIPS:** OpenSSL'un varlığı FIPS uyumluluğu değildir (skill §3.1 satır 86). OpenSSL FIPS modülü ancak validated modül + uyumlu build + operasyonel konfigürasyonla ayrıca iddia edilir; bugün metinde hiçbir yerde FIPS/production-ready iddiası yoktur.

**Gerekçe.** Motorun çekirdek derlemesi OpenSSL'e bağımlı kalmasın — VDbTls'nin kuruluş gerekçesi bu (`VDbTls.pas:4-5`) ve BASELINE §5 satır 81 bu kalıbı "skill §3.4 ile uyumlu" onaylamış. Aynı kalıp = tek bağımlılık yönetimi, tek hata yüzü. Otomatik builtin fallback, "güvenli olmayan sağlayıcıya sessiz geçiş" yasağını (skill §3.1 satır 81) ihlal ederdi; opt-in + log bunu engeller.

**Sonuçlar.** Şifreleme isteyen dağıtımlar OpenSSL DLL'lerini yanında taşımak/kurmak zorundadır (SBOM + operasyon dokümanı maddesi; linux/mac'te `libcrypto.so.3`/`.dylib` ad eşlemesi build_lib.sh tarafında çözülür); Argon2id'nin OpenSSL 1.1/3.0-3.1'de olmaması **mimari ayıp değil karar**: KDF, RFC 9106 KAT'lı referans implementasyonla (VDbKdf) sürer — §0.4 taşınmış-kanıtlanmış-kod dalı; ≥3.2'de `EVP_KDF`/`EVP_KDF_ARGON2` (bu API adı doğrudur) yalnız opsiyonel cross-check'tir.

---

## 3. dcpcrypt kaldırma sırası (ENV 6 adım — INVENTORY §6 geçiş sırası + skill §3.5 checklist)

Her adımın çıkış koşulu: **dört target'ın derlemesi** (`vdbapi.lpr`, `vdbcli.lpr`, `vdbmig.lpr`, `vdbserver.lpr`; `build_dll.ps1` / `build_lib.sh`) **+ crypto gate'leri** (selftest + KAT + round-trip fikstürleri). Adımlar sıralı bağımlıdır; `git init` önkoşul (EK A.1 madde 1 — PR/diff/rollback bunun üstünde).

1. **Provider arayüzü + OpenSSL provider + SelfTest** — `VDbCryptoTypes/Provider/OpenSSL/Random/SelfTest` birimleri eklenir; DCP yerinde durur (**çift yol**). Gate: derleme + `crypto_selftest` + cross-provider KAT (OpenSSL ↔ bugünkü yol aynı vektörleri geçmeli). Henüz hiçbir caller taşınmaz.
2. **Caller migration** — `VDbCrypt.pas` iç implementasyonu provider'a bağlanır (facade imzaları sabit, K1); `VDbPageCrypto`, `.key` okuma/yazma ve GCM/AEAD yolları provider'dan geçer. Gate: eski şifreli `.odb` + `.key` v1/v2 round-trip fikstürleri + sqltest + davranış/hata-yolu testleri (INVENTORY §3 satır 37: "geçişte ciphertext uyumluluğu test edilmeli").
3. **base64** — `VDbPgWire.pas:60`'taki `DCPbase64` (tek kullanım yeri) kendi küçük base64 unit'sine ya da FPC `MimeTypes`'a taşınır (INVENTORY §6 satır 75). Gate: SCRAM tam regresyonu — RFC 5802 §5 vektörleri + **mevcut kullanıcı verifier'larıyla t-testi** (INVENTORY §4 satır 49).
4. **dcpcrypt klasörü + build satırları silinir** — hiçbir kök `.pas` DCP unit'i import etmiyorken: `vdbapi.lpi` `PackageName="dcpcrypt"` + iki `-Fu...dcpcrypt` satırı (biri zaten bozuk yola işaretli), `vdbcli/vdbmig/vdbserver.lpi` `-Fu` satırları, `build_dll.ps1:58-62`, `build_lib.sh:67-69`, `dcpcrypt/` klasörü (derlenmiş `.o/.ppu` kirliliğiyle birlikte — BASELINE A.1.4); README SBOM satırı + MIT attribution notu güncellenir (INVENTORY §5). Not: builtin provider'ın AES-blok/SHA-256 çekirdeği bu adımdan **önce** K1 uyarınca `VDbCryptoBuiltin.pas`'a taşınmış olur; klasör silmek kodu silmek değildir. Gate: **temiz checkout build** (skill §3.5).
5. **Gate'ler tam koşturulur** — sqltest tamamı + crypto suite (KAT/selftest/round-trip) + win+linux derleme matrisi (CI kurulana kadar tek komutluk yerel gate — BASELINE §8 madde 6, skill §9 pipeline-1).
6. **Doğrulama: dcpcrypt yalnız selftest/uyumluluk yolunda** — kaynak taraması (`DCP` import/uses kalmadı; INVENTORY §2 blast-radius kapanışı), binary tarama (DCP sembol/artefact yok — skill §3.5 son maddesi), builtin'in KAT mühür raporu; BASELINE §8 madde 2 kapatılır, `release notes + key-uyumluluk dokümanı` yayınlanır (skill §3.5 son madde).

---

## 4. Riskler ve Uyumluluk

| Risk / uyumluluk yüzeyi | Analiz | Azaltım |
|---|---|---|
| **Eski şifreli `.odb` round-trip** | AES-GCM standart primitiftir; zarf/AD değişmediği sürece (v1 dosyalar v1 kalır) provider değişimi ciphertext-uyumlu olmalıdır (INVENTORY §4 satır 48). Risk: elle-yazım GCM ile OpenSSL EVP arasında köşe-hata farkı (aad/uzunluk sınır durumları). | Cross-provider aynı-şifre-metni testi + **eski DCP tabanlı şifreli `.odb`'yi yeni provider ile açma fikstürü** (EK A.5 madde 3) her gate'te. v1 zar salt-okunur daima açılır (K2). |
| **Eski kayıt zarfları** | `IV|len|CTR|HMAC` eski kayıt formatı ve legacy CBC bölgesi (INVENTORY §3) yeni yazımda üretilmez. | Salt-okunur; decrypt-yaz-yeniden-encrypt gerekirse `vdbmig`'e görev yazılır (INVENTORY §4 satır 50). |
| **`.key` Argon2id round-trip** | v2 başlık `t/m/p`'yi dosyadan okur (parametre sabitine bağımlı değildir) → parametre değişse bile eski dosya açılır. Risk: builtin Argon2 taşımasında bit-düzeyi sapma. | RFC 9106 §5.1 KAT + **mevcut `.key` dosyalarıyla round-trip testi** (INVENTORY §4 satır 47). |
| **SCRAM verifier koruması** | RFC-standard primitifler; base64/SHA-256/HMAC değişimi verifier'ları **bozmamalı**; yine de mevcut verifier'larla t-testi zorunlu (INVENTORY §4 satır 49). K3 istisnası protokolü sabit tutar. | §3 adım 3 gate'i + RFC 5802 §5/RFC 7677 protokol KAT'ı (K5). |
| **Multi-process nonce** | v1 (random) nonce süreçler-arası çarpışmaya karşı duyarsızdır; v2 deterministik nonce **tek yazar** gerektirir. Bugünkü yazar kilidi (`VDB_DEF_BUSY_MS`, `VDbPageStore.pas:71-76`) ve `.gen` DBID/nesil kontrolü (C-2, `:84-103`) zemini hazır; şifreli dosyada kilitsiz ikinci yazar kabul edilmez. V3 TCP replikasyonda şifreli sayfa zaten desteklenmiyor (BASELINE §4) → bugün anahtar-paylaşımlı eşzaman-yazım senaryosu yok; gelecekte replika-başına-anahtar kuralı. | K2'nin kapanmayan-deklarasyonları test paketiyle bağlanır (§5 madde 4); crash/WAL-replay seq monotonluk testi. |
| **Klon/rollback + nonce** | Aynı dosya kopyası iki uçta yazılırsa deterministik nonce reuse riski doğar (nonce üretimi değil, işletim hatası). | Klon tespiti zaten var (DBID mismatch → durabil LSN geçersiz); ek kural: encrypted DB kopyasında yazma için **rekey zorunlu**, değilse salt-okunur (K2). |
| **OpenSSL runtime bağımlılığı** | Şifreleme, OpenSSL DLL'si olan makineye bağlanır; DLL'siz makinede crypto kapalı (K6). Mevcut "saf Pascal her yerde çalışır" rahatlığı bilinçli olarak daralır. | Operasyon dokümanı + temiz hata mesajı + opt-in builtin kaçağı (loglu). TLS zaten aynı bağımlılığı taşıyor — net yeni bağımlılık eklenmiyor (BASELINE §2). |
| **Argon2id bellek/CPU** | 64 MiB × eşzamanlı parola türetimi; zayıf donanımda giriş gecikmesi. | Parametreler metadata'da (ileride yükseltilebilir/düşürülebilir — düşüş ayrı ADR revizyonu); eşzamanlı-türetim kuyruğu, skill §7.1 throttling işiyle birlikte (BASELINE §5 satır 80). Sayısal profil gate'te ölçülür, iddia edilmez. |
| **Pascal heap zeroization** | Kesin sıfırlama garantisi yok (skill §3.1 satır 83). | K4/6'da kabul edilmiş risk olarak kayıtlı; best-effort `FillChar`, secret'ın log'a sızmaması kuralları. |
| **DPAPI platform bağımlılığı** | (ii) KEK kanalı Windows-özel; başka OS'ta sessizce devre dışı kalmaz — açık hata verir. | K4; platform matrisi dokümanı. |

## 5. Kabul Kriterleri (skill §3 + EK A R-1/R-2 bağları)

Bu ADR'nin kararları **şunlar kanıtlanmadan uygulanmış sayılmaz** (her madde bir gate'e bağlanır; `tests/`/CI kanıtı olmayan "geçiyor" R-3 gereği `unverified`dır):

1. **DCP'siz depo (skill §3.5):** hiçbir kaynak/binary DCP unit/sembolü içermez; `dcpcrypt/` yoktur; taze checkout'ta DCP'siz dört-target derlenir. (K1, §3 adım 4-6)
2. **Self-Test fail-closed (skill §3.1 satır 85, §0.8):** kasten bozulmuş vektör build'i → şifreleme etkinleşmez, temiz hata, plaintext yolu yok. K5 tablosundaki her vektör seti (AES-GCM CAVP, FIPS-197 C.3, FIPS 180-4/SHAVS, RFC 4231, RFC 7914 §11, RFC 9106 §5.1, RFC 7693, RFC 5869, RFC 5802/7677) **her iki provider'da** geçer. (K5, K6)
3. **R-1 kapandı (EK A.4 satır 758):** deterministik `key_gen|page_no|rewrite_seq` zarfı yazımda; reuse analizi bu ADR'de; **testler:** crash→WAL-replay sonrası seq monotonluğu ve recovery idempotency, checkpoint/restore/backup-clone'un nonce durumunu bozmadığı testi, clone-write denemesinin rekey-zorlamasıyla engellenmesi, çift-yazar denemesinin yazar kilidiyle reddi. R-1'in birthday-hacim hesabı deterministik mod için "uygulanamaz (konstrüksiyon gereği)" gerekçesiyle ve 48-bit tavan notuyla kapatılmış sayılır. (K2)
4. **R-2 kapandı (EK A.4 satır 759):** yeni yazımların parola-türetmeleri Argon2id (t=3, m=64 MiB, p=4 — `VDbCrypt.pas:66-70`); PBKDF2-200k yalnız salt-okunur eski `.odb`/`.key` v1 yolunda; **KDF kimliği metadata'da** (crypto-v2 `kdf_id`, `.key` başlık ver); SCRAM istisnası K3/4'teki gerekçeyle belgelenmiş ve iterasyon kelepçesi testli (`VDbPgWire.pas:2361-2362`). (K3)
5. **Uyumluluk (INVENTORY §4 kırmızı çizgisi):** eski şifreli `.odb` eski-zar round-trip'i; `.key` v1+v2 round-trip'i; SCRAM mevcut-verifier t-testi — üçü de fikstür olarak kalıcı gate. (K2/K3/K4, §4)
6. **Sessiz-düşüş yok (skill §3.1 satır 81, §3.4; BASELINE §5 satır 81 kalıbı):** OpenSSL yokluğunda hata temiz ve DLL-adı-söyleyen; builtin yalnız açık opt-in + açılış logu. (K6)
7. **Key yönetimi (skill §3.3):** diskte/config/log'da plaintext key yok; keycheck doğrulayıcısı secret-değil modelini korur (`VDbPageCrypto.pas:16-18` deseni, EK A.3 satır 753); rekey akışı crash-resume testli; key-kaybının kurtarılamaz olduğu dokümante. (K4)
8. **Dürüst iddia (R-3 + skill §3.1 satır 86):** hiçbir yerde FIPS veya "production-ready" iddiası yok; yukarıdakilerin tümü CI/commit kanıtına bağlanana kadar `unverified` etiketlidir.

---

*Bu ADR, EK A.5 madde 2 (`CRYPTO_ARCHITECTURE_ADR`) teslimidir; sıradaki görevler: madde 3 `CRYPTO_TEST_HARNESS` (KAT vektörleri + round-trip fikstürleri), madde 4 `CRYPTO_PROVIDER_IMPLEMENTATION`, madde 5-6 kaldırma — §3'teki adımlarla birebir.*

---

## EK-B — Sahip Kararı: Saf-Pascal / Sıfır-Dış-DLL Sözleşmesi (2026-11-13)

**Karar (bağlayıcı, proje sahibi):** VDB saf native, yalnız Free Pascal kaynak kodundan derlenen, **harici DLL/DPK bağımlılığı olmayan** bir veritabanıdır. Temel sözleşme readme.md:3-4'tedir ("written in pure Free Pascal. It needs no external DLL"). Bu karar bu ADR'deki provider önceliğini değiştirir (banner'a işlendi).

**Sonuçları:**
1. **Varsayılan provider = built-in** (K1 önceliği geçersiz). Sağlayıcı seçimi Adım 2B'de çevrilir; `VDbCryptoOpenSSL` kalır ama yalnızca açık opt-in/opsiyonel.
2. **TLS sunucu özelliği istisna değildir — opsiyonel özelliktir:** `vdbserver --tls` kullanıcının kendi makinesindeki OpenSSL'i *kullanıcının isteğiyle* dinamik yükler; çekirdek veritabanı ve şifreleme bundan bağımsızdır, DLL yoksa özellik temiz hatayla kapalıdır (bugünkü davranış sözleşmeyle uyumlu).
3. **Kabul edilen risk (dürüst kayıt):** built-in GCM/Argon2 saf-Pascal yolları cache-zamanı yan kanallarına OpenSSL kadar sert değildir ve bağımsız kripto incelemesinden geçmemiştir. Bu risk kabul edilmiştir; hafifletme: NIST/RFC KAT mührü (yapıldı), cross-provider aynı-şifre-metni testi (OpenSSL bulunan test makinesinde zorunlu gate), ileride bağımsız inceleme TODO'su.
4. **Doğrulama stratejisi değişmez:** KAT seti + fixture round-trip'leri built-in için her gate'te; OpenSSL cross-check bulunan ortamda ek gate. Selftest OpenSSL'suz da tam geçmeli (exit 0).
5. **Sırada ne değişmiyor:** dcpcrypt kaldırma (Adım 3-4) aynen uygulanır — vendored klasör gider, çekirdek AES/SHA-256 kodu attribution ile kendi birimlerimize taşınır; Base64 kendi unit'imize; sonuç **daha az** dosya/daha az üçüncü-parti izi, saf Pascal.
