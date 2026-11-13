# VDB V3 Baseline Denetimi (Phase 0 — V3_BASELINE_AUDIT)

> Tarih: 2026-11-13 · Denetim yöntemi: kod + derleme girdisi + bağımlılık taraması (doküman iddiası değil, dosya kanıtı).
> Kural: Bu dosya "bugün gerçekten ne var" sorusunun tek cevabıdır. README iddiası ile çelişirse burada yazan geçerlidir.

## 1. Depo gerçeği (kritik bulgular)

| Konu | Gerçek | Kanıt |
|---|---|---|
| **Git deposu YOK** | `fatal: not a git repository` — `.git` dizini yok, `.gitignore` dosyası var ama aktif değil | 2026-11-13 `git rev-parse` çıktısı |
| CI/CD YOK | `.github/`, gitlab/azure/jenkins konfigürasyonu yok | kök tarama |
| Compiler | FPC **3.2.4**, Lazarus **4.4** | `fpc -iV`, `lazbuild --version` |
| README sürüm iddiası | README "Lazarus 4.6+" der — kurulu 4.4. Ya README bayat ya ortam güncellenmemiş | readme.md |
| `sqltest.lpi` kökte YOK | README'deki `lazbuild sqltest.lpi` komutu bu depoda çalışmaz; testler `tests/` altında | kök dizin listesi |
| `tests/` değişken | Klasör bir oturumda 15GB üretilmiş veriyle mevcut, sonraki oturumda yok. Gate sonuçları bu yüzden **bu depoda doğrulanamaz durumda** | iki ayrı dizin taraması |
| Build-artifact kirliliği | Kökte FPC asmlist dump'ları (`VDb*.s`, x86-32) ve dcpcrypt altında `.o/.ppu` duruyor | kök/dcpcrypt listesi |
| Karışık içerik | `mtakip/` (ilgisiz web projesi), `backup/` (73MB .odb), `yonetim/` (GUI) aynı kökte yaşıyor | dizin listesi |

**Sonuç:** Skill'in Phase-0 çıktıları (BASELINE, MODULE_MAP, test taksonomisi) üretilmiş oldu; ancak Phase 1+ iş akışı (küçük PR, diff izleme, rollback) **önce `git init` + ilk commit** gerektirir. Bu bir öneri değil, ön koşuldur.

## 2. Üretim hedefleri ve bağımlılık SBOM

Hedefler (derleme girdileri):
- `vdbapi.lpr` → ana DLL/SO (57-export C API, `vdbapi.h`)
- `vdbcli.lpr` → CLI; `vdbmig.lpr` → migrasyon; `vdbserver.lpr` → PG-wire sunucu
- Kütüphane derleme: `build_dll.ps1` (win), `build_lib.sh` (linux/mac)

Dış bağımlılık envanteri (tam liste — kod taramasıyla doğrulandı):
| Bağımlılık | Tür | Kullanan | Not |
|---|---|---|---|
| **DCPcrypt** (vendored, MIT) | kaynak, `dcpcrypt/` | yalnız `VDbCrypt.pas` (AES bloğu + SHA-256), `VDbPgWire.pas` (base64) | kaldırma hedefi — envanter: `DCPCRYPT_USAGE_INVENTORY.md` |
| **OpenSSL** | runtime, `VDbTls.pas` içinden **dinamik yükleme** (libssl-3 / 1.1 / 1.0.2) | sadece TLS yolu | OpenSSL zaten build'de var → crypto provider için hazır kanal |
| FPC RTL | Classes, SysUtils, Math, Threads, Sockets, Process | her yer | taşınabilirlik katmanı: `VDbPlatform.pas`, `VDbSync.pas` |

Başka üçüncü parti bağımlılık **yok** (http/curl/json/xml/parquet/zip hepsi kendi kodu).

## 3. Modül haritası (kodu okumak isteyene)

```
SQL metni → VDbParser (AST) → VDbExecutor (825KB, çalıştırma) → VDbTable (şema+heap+index)
                                                        ↓
                                   VDbBackendV3 (V3 orkestrasyon) / VDbBackendApi, V2 (legacy)
                                                        ↓
storage: VDbPageStore (143KB: page I/O + WAL + snapshot + şifreleme bağları)
         VDbPageEngine / VDbPageHeap / VDbPage (sayfa formatı)
         VDbPageWal (WAL), VDbPageCrypto (AES-GCM sayfa zarı), VDbWal (eski v2 WAL)
         VDbBTree / VDbIdxFile / VDbSkipList / VDbRange (index)
crypto:  VDbCrypt (kripto cephesi + el yazması GCM/HMAC/CRC) ← DCPcrypt
         VDbKdf (el yazması BLAKE2b + Argon2id), VDbCrc32
         VDbTls (OpenSSL ince sarmalayıcı), VDbPgWire (PG sunucu protokolü, SCRAM)
dağıtık: VDbReplication / VDbReplV3, VDbCdc, VDbSync, VDbChangeLog
yüzeyler: vdbapi_core (C API), VDbNet (kendi TCP protokolü), VDbClient/ClientNet,
          VDbConsole, VDbMetricsHttp, VDbPgWire, VDbParquet/Xml/Json (içe/dışa aktarım)
```

Detaylısı: `docs/architecture/MODULE_MAP.md`.

## 4. Desteklenmeyen / stub yüzeyler (kod kanıtıyla)

README "yok" dediklerini zaten dürüstçe sayıyor; koda bakınca ek olarak:

| Yüzey | Gerçek durum | Kanıt |
|---|---|---|
| `INSERT ... RETURNING` / `UPSERT ... RETURNING` | **uygulanmadı** — `ecUnsupported` | `VDbCore.pas:6605`, `VDbCore.pas:6616` |
| RETURNING (UPDATE/DELETE) | kısmi — tablo tarafında "stubs" etiketi | `VDbTable.pas:899` |
| TRIGGER | çalışıyor ama eksik: `F-36 ... stubbed here, not fully implemented` | `VDbExecutor.pas:20423` |
| STORED PROCEDURE / UDF çağrısı | iskelet — `F-35 ... stub` | `VDbTable.pas:13023`, `VDbTable.pas:13372` |
| V3 TCP replikasyon, ARCHIVE WAL RESET | `ecUnsupported` (README doğruluyor) | readme.md + kod |
| V3 TCP replikasyonda şifreli sayfa | desteklenmiyor | readme.md |
| V2 | legacy, salt-okunur donmuş (skill kararıyla uyumlu) | `VDbBackendApi.pas:66` |

**Test edilebilirlik uyarısı:** "SQL feature var" iddiası, yukarıdakiler için en az bir `ecUnsupported`/stub yolunun test edilmesini gerektirir. Gate'lerin bunları ayırt edip etmediği `tests/` klasörü oturumda olmadığı için bu denetimde doğrulanamadı.

## 5. Güvenlik yüzeyi — bugünkü gerçek

- **Sayfa şifreleme (V3, default kapalı):** AES-256-GCM; zar formatı `nonce(12) | ct | tag(16)`, AAD = `"VDB3PG" | pageno LE32 | salt(16)`. Tag doğrulanmadan plaintext kullanılmıyor; mix-up/tamper tek temiz hataya iner. `VDbPageCrypto.pas:1-18`.
- **KDF tutarsızlığı:** `.key` dosyası → Argon2id (kendi el yazması impl); **sayfa şifreleme parola→key → PBKDF2-SHA256 200k iter** (`VDbPageCrypto.pas:35`). Skill §3.2 "Argon2id tercih" diyor → karar ADR'de verilmeli.
- **Nonce yönetimi:** sayfa başına `Seal` anında 12 rastgele bayt (`VDbPageCrypto.pas:139`, CSPRNG). Skill §3.2'nin istediği **çalışma/hacim analizi (birthday bound, klon/rollback senaryoları) YOK** — en somut kriptografi borcu budur.
- **CSPRNG:** `VDbCryptRandom` Windows `RtlGenRandom`/`CryptGenRandom` + Unix `/dev/urandom`; yoksa **fail-closed hata** (`VDbCrypt.pas:48-49,666-723`). İyi.
- **PG sunucu auth:** SCRAM-SHA-256, parola sunucuda durmuyor (verifier). Kullanıcı tanımlıysa auth zorunlu; tanımsızsa trust **yalnız açık `--trust` flag'iyle** (`VDbPgWire.pas:65-67`, `vdbserver.lpr:67`). `--require-tls` var. İyi haber: sessiz trust default'u yok. Kalan risk: production'ta yanlışlıkla `--trust`/`--user` baytsız başlatma — skill §7.1 throttling/lockout istiyor, kodda izine rastlanmadı.
- **TLS:** gerçek OpenSSL dinamik wrapper; DLL yoksa TLS **kapalı + temiz hata** (sessiz düşüş yok) — skill §3.4 ile uyumlu. `VDbTls.pas:8`. İnceleme notu: `SSL_CTX_set_verify` referansı var (`VDbTls.pas:164`) — client tarafı sertifika/host doğrulama politikası ayrıca denetlenmeli.
- **Kendi yazdığı primitifler (skill §0.4 ihlali — itiraf listesi):** GCM modu (GHASH+CTR) `VDbCrypt.pas` içinde el yazması (DCPcrypt'in AES bloğu üstünde); BLAKE2b + Argon2id `VDbKdf.pas` içinde sıfırdan. Bunlar silinemez — silmek veri formatını kırar. Yol: provider'a taşı + **NIST Wychepore/CTRH KAT testleri** ile mühürle.
- **Rastgelelik hijyeni:** kripto yolları CSPRNG kullanıyor. `Random()` kullanımları yalnız trace-id (`VDbTrace.pas:159-160`) ve changelog çakışma-sekansı (`VDbChangeLog.pas:650`) — kripto değil ama ID çakışması veri doğuluğu konusu.

## 6. Storage/WAL — bugünkü gerçek (skill §4 ve PART 2 karşılığı)

- V3 varsayılan: 4KB sayfa, slotted heap, sayfa başına CRC32, `.odb` + `.odb.wal` + `.odb.log`; `.odb.idx` türetilmiş önbellek (silinirse full-scan fallback).
- Dirty-page-only WAL commit; `PRAGMA sync_mode` ∈ {off, normal, full}; kill-9 kapılı recovery testi README'de tanımlı (bu oturumda koşturulamadı).
- Snapshot = anlık kopya (README bunu dürüstçe "gelecek iş" diye not ediyor).
- **PART 2 (single-file container) karşılığı bugün YOK** — bugün Mode B (managed multi-file). Bu bir uyumsuzluk değil; skill'in migration stratejisi ("mevcut formatı belgele, sonra öner") tam olarak bu dosyadır.

## 7. Test/performans iddialarının denetim sonucu

README 2026-11-07 için 2887✅/0❌/33⏭ ve 35 gate iddia ediyor. **Doğrulama durumu: bu oturumda kısmen imkânsız** — `tests/` klasörü oturumlar arasında kayboluyor (yetim süreç/suite koşu kavgası hafızasıyla tutarlı) ve git yok, yani commit'e bağlanmış kanıt yok. Yapılacak ilk iş: `git init`, `tests/` üretilmiş verisini temizleyip kaynakları commit'lemek, gate'i tek komutla koşturulur hale getirmek (skill §9 pipeline-1).

## 8. Somut gap listesi (öncelik sırası)

1. **git yok** → her şeyi kilitleyen engel. `git init` + ilk commit + `.gitignore` düzeltmesi (`.s`, `*.o`, `*.ppu`, `backup/`, `mtakip/` hariç tut; üretilmiş test verisi hariç).
2. **DCPcrypt kaldırma** → envanter hazır (`DCPCRYPT_USAGE_INVENTORY.md`); OpenSSL provider yolu açık.
3. **GCM nonce güvenlik analizi + KAT testleri** → `VDbPageCrypto` + `VDbCrypt` + `VDbKdf`.
4. **KDF politikası kararı** (PBKDF2-200k vs Argon2id) + format uyumluluk planı.
5. **RETURNING/PROC/TRIGGER stub'ları** → ya tamamla ya README'de "deneysel" olarak işaretleyip `ecUnsupported` tutarlılığını teste bağla.
6. **CI yok** → skill §9 matrix en azından win+linux build + sqltest + gate'leri kapsamalı.
7. **Sunucu sertleştirme** → `--trust` production koruması (yalnız loopback zorunluluğu + log uyarısı), throttling/lockout, `VDbTls` client doğrulama denetimi.
8. Docs seti (`docs/security/*`, `docs/operations/*`, SECURITY.md, CHANGELOG) — README tek dosyada her şeyi taşıyamayacak kadar büyüdü.
