# VDB V3 — Production Hardening & DCPcrypt Removal Skill

> **Skill ID:** `VDB-V3-PRODUCTION-HARDENING-001`  
> **Scope:** VDB relational database engine (Free Pascal / Lazarus)  
> **Status:** Master implementation plan; execute in small, reviewable PRs  
> **Priority:** Critical / release-blocking  
> **Language:** Requirements and engineering notes in Turkish; identifiers and code comments may follow repository conventions.

## 0. AI Agent için bağlayıcı çalışma talimatı

Bu dokümanı uygulayan Windsurf/AI ajanı aşağıdaki kurallara kesinlikle uyar:

1. **Tek aktif geliştirme hattı V3'tür. V2'ye yeni özellik, bug-fix, refactor veya test ekleme.** V2 kaynaklarını bu çalışma kapsamında topluca silme; gerekiyorsa `legacy/v2` veya ayrı arşiv branch/tag ile salt okunur biçimde koru. V2 build/test pipeline'ını V3'ten ayır ve V2'yi release adayı olarak sunma.
2. Kullanıcının açık onayı olmadan büyük çaplı API kırılımı, veri dosyası formatı değişikliği, migration davranışı veya geriye dönük uyumluluk kaldırma yapma.
3. **DCPcrypt bağımlılığını VDB'nin build/runtime/packaging/test zincirinden kaldır.** Ancak AES, SHA, HMAC gibi kriptografik algoritmaları sıfırdan yazma. VDB'ye ait API/facade ve key lifecycle katmanı oluştur; algoritmalar güvenilir, bakımı yapılan kriptografik provider üzerinden çalışsın.
4. Kriptografi sağlayıcısını, TLS stack'ini ve DB encryption mekanizmasını birbirine karıştırma. TLS, data-at-rest encryption ve password hashing ayrı ihtiyaçlardır.
5. Her değişiklik küçük, izlenebilir commit/PR olsun. Önce mevcut davranışı testlerle kilitle; sonra refactor/migration yap. Testi geçmeyen değişikliği tamamlandı olarak işaretleme.
6. `TODO`, sahte başarı, no-op güvenlik kontrolü, testte gerçek kodu bypass etme, `except ... end` ile hatayı yutma, rastgele/varsayılan anahtar, sabit nonce veya zayıf fallback yasaktır.
7. Güvenlik veya durability belirsizliğinde **fail closed** davran: işlemi reddet, veri/anahtar durumunu bozma, açık ve denetlenebilir hata üret.
8. Repository'deki gerçek dosya, API, FPC/Lazarus sürümü ve CI düzenini incelemeden isim/konum varsayma. Aşağıdaki modül isimleri öneridir; mevcut naming convention ile uyumlandır.
9. Bir test veya sertifika/standart gerekliliğini karşılamıyorsa “production-ready”, “SIL”, “sertifikalı” veya “tam güvenli” iddiası kullanma.
10. Her faz sonunda: değişen dosyalar, kararlar, test komutları/sonuçları, bilinen riskler ve sonraki faz raporlanır.

## 1. Proje kararı ve hedef

### 1.1 V3 tek geliştirme hattı

- V3 ana branch/aktif ürün hattı olarak belirlenir.
- V2 yalnızca tarihsel referans/legacy olur; V2'ye yeni commit kabul edilmez.
- V2'den V3'e alınacak davranışlar doğrudan kopyalanmaz; gereksinim, test ve kod incelemesiyle yeniden doğrulanır.
- V3 sürüm numarası, changelog, release notes ve migration policy tek yerde tanımlanır.
- V2 veri dosyası gerekiyorsa V3'e geçiş için açık, testli ve geri dönüş planı olan migration aracı sağlanır. V2 formatını V3'ün iç çalışma formatı olarak sürdürme.

### 1.2 Ürün hedefi

VDB V3; güvenilir transaction/durability, tutarlı SQL davranışı, kontrollü ağ erişimi, izlenebilir güvenlik, taşınabilir build, belgeli backup/restore, test edilmiş upgrade/downgrade sınırları ve desteklenebilir release süreci olan profesyonel bir DBMS olarak geliştirilir.

**Önemli:** Bu plan üretim kalitesine ulaşma yol haritasıdır; tek başına bir sertifikasyon, bağımsız güvenlik değerlendirmesi veya gerçek workload altında güvenilirlik kanıtı değildir. “Production-ready” kararı ölçülebilir release gate'leri ve bağımsız incelemeyle verilir.

## 2. Başlangıç: repo envanteri ve baseline

### 2.1 Envanter

- V3 ana branch, tag, release ve çalışma ağacı durumunu kaydet.
- FPC, Lazarus, target CPU/OS, build mode, compiler flags, paketler ve CI matrisini belgele.
- `uses` zincirleri, `.lpk`, `.lpr`, `.pas`, `.lpi`, `.cfg`, `.yml/.yaml`, installer ve script'lerde DCPcrypt referanslarını ara.
- Üçüncü taraf bağımlılıkları için SBOM (CycloneDX veya SPDX) üret; her bağımlılık için sürüm, lisans, kaynak, bakım durumu, CVE takibi ve kullanım amacı kaydet.
- Modül haritası oluştur: SQL parser/executor, storage/page, WAL, transaction, B+Tree/index, replication, network/PG wire, TLS, auth/RBAC/RLS, backup/restore, observability, CLI/server/client.
- Testleri sınıflandır: unit, integration, regression, SQL conformance, recovery, protocol, security, performance, fuzz, soak.

### 2.2 Baseline / davranış kilidi

- V3 mevcut testlerini temiz ortamda çalıştır; sonuçları CI artifact olarak sakla.
- Bilinen SQL kapsamı (pass/fail/skip) ve her skip nedeni raporlanır; skip'ler başarı olarak sayılmaz.
- Mevcut WAL/recovery, crash recovery, index ve network testleri ayrı raporlanır.
- En azından veri dosyası formatı, wire protocol, SQL davranışı ve CLI konfigürasyonu için uyumluluk testleri oluştur.
- Baseline başarısız testler “known failures” listesine alınır; yeni regressions ile karıştırılmaz.

**Çıktı:** `docs/engineering/BASELINE.md`, `docs/architecture/MODULE_MAP.md`, dependency/SBOM raporu ve test baseline artifact'ı.

## 3. DCPcrypt kaldırma ve VDB Crypto mimarisi

### 3.1 Hedef mimari

VDB kendi kriptografi API'sini ve sağlayıcı soyutlamasını sunar; algoritma uygulamalarını kendisi üretmez.

Önerilen ayrım (mevcut repo yapısına göre isimler değişebilir):

- `VDbCrypto.pas`: public facade; VDB içindeki çağıran modüllerin tek giriş noktası.
- `VDbCryptoTypes.pas`: byte buffer, key handle, algorithm ID, error/result types; güvenli tip sınırları.
- `VDbCryptoProvider.pas`: provider interface/contract ve capability discovery.
- `VDbCryptoOpenSSL.pas`: OpenSSL tabanlı provider (uygun FPC binding ve desteklenen sürüm matrisiyle).
- `VDbCryptoRandom.pas`: OS/provider CSPRNG üzerinden random bytes.
- `VDbCryptoKdf.pas`: password/key derivation provider API.
- `VDbCryptoKeyStore.pas`: key metadata, key IDs, rotation ve key lifecycle; anahtarın plaintext saklanmasını engelleyen tasarım.
- `VDbCryptoEnvelope.pas`: VDB storage encryption envelope/header/version/nonce/tag metadata.
- `VDbCryptoSelfTest.pas`: provider startup/self-test ve test harness (self-test tek başına provider doğrulaması sayılmaz).
- `VDbCryptoErrors.pas`: sabit, belgeli hata kodları; ayrıntılı secret içermeyen loglama.

**API ilkeleri:**
- Algoritma/provider seçimi konfigürasyonla yapılabilir ama güvenli olmayan provider'a otomatik fallback yoktur.
- Secret ve key material normal log, exception, telemetry, dump veya debug output'a yazılmaz.
- Key handle/ID ile çalış; key bytes kopyalarını azalt, kullanım sonunda güvenli temizleme için platformun imkanlarını kullan. Pascal heap üzerinde kesin zeroization garantisi verilemiyorsa bunu açıkça belgele ve risk olarak kaydet.
- Crypto API bellek uzunluğu, buffer sınırı, nil pointer, overflow ve hata dönüşlerini doğrular.
- Provider yok, uyumsuz, self-test başarısız veya algoritma kullanılamıyor ise ilgili güvenlik özelliği etkinleşmez; plaintext'e düşme yok.
- FIPS/validated mode ancak kullanılan provider, platform, build ve operasyonel konfigürasyon gerçekten ilgili doğrulama kapsamındaysa iddia edilebilir. OpenSSL kullanmak tek başına FIPS uyumluluğu anlamına gelmez.

### 3.2 Algoritma politikası

- **AEAD/data-at-rest:** AES-256-GCM (provider destekli, nonce uniqueness kuralları uygulanmış) veya güvenlik incelemesiyle seçilmiş eşdeğer AEAD.
- **Hash:** SHA-256/ SHA-384 gibi standardize hash; hash'i password saklamak için tek başına kullanma.
- **MAC:** HMAC-SHA-256/384, ihtiyaç ve protokol tasarımına göre.
- **KDF:** password için Argon2id tercih edilir; platform/provider uyumluluğu ve parametrelerin benchmark ile belirlenmesi gerekir. Alternatif PBKDF2-HMAC ancak uyumluluk/standart gereksinimiyle ve yeterli maliyet parametreleriyle.
- **Key derivation:** HKDF-SHA-256/384, uygun context/domain separation ile.
- **Random:** OS CSPRNG/provider random API. `Random`, saat, PID, GUID veya tahmin edilebilir seed kriptografik random yerine kullanılamaz.
- MD5, SHA-1, DES, 3DES, RC4, ECB, çıplak CBC ve custom cipher yasak. Legacy okuma gerekiyorsa izole, açıkça deprecated, salt migration amaçlı ve yeni yazma kapalı olmalı.
- AEAD nonce/IV tekrarını önleyen mekanizma tasarla. Crash, restore, clone, backup restore, key rotation ve multi-process kullanımında uniqueness kanıtı gerekir. Sabit nonce veya yalnızca “random 12 byte” deyip collision/volume limitini değerlendirmemek kabul edilmez.
- Tag doğrulanmadan plaintext hiçbir kullanıcıya/SQL katmanına açılmaz. Authentication failure'da işlem durur; ayrıntılı oracle oluşturan farklı dış hata mesajları/log davranışları değerlendirilir.

### 3.3 Key management

- Database master key (DEK) ve key-encryption key (KEK) ayrımı; DEK wrapping/unwrap tasarımı.
- Key ID, version, creation time, algorithm, wrapped key, rotation status ve key source metadata.
- Key material: OS keystore, HSM/KMS veya dış key management entegrasyonu; geliştirme/test için ayrı ephemeral key fixture.
- Key'i DB dosyası, repo, config, environment log'u veya backup içinde plaintext saklama.
- Key rotation: aktif key, yeni yazmalar, eski key ile okuma, re-encryption/rekey job, crash resume, rollback ve audit.
- Key kaybı/yanlış key durumunda recovery'nin mümkün olmadığı açıkça dokümante edilir; “master password recovery” gibi güvenlik yanılsaması yaratma.
- Credential/secret redaction; password, token, key, connection string loglarda maskelenir.

### 3.4 TLS ve data-at-rest ayrımı

- TLS için kendi TLS protokolünü yazma. OpenSSL veya desteklenen, güncel ve güvenlik bakımına sahip TLS stack kullan.
- TLS minimum sürüm, cipher suite policy, certificate validation, hostname validation, CA trust, mutual TLS (opsiyonel), certificate rotation ve expiry alarmı belgelenir.
- TLS private key dosya izinleri/keystore ve sertifika yükleme hataları güvenli şekilde yönetilir.
- TLS kapalı/invalid certificate davranışı açık konfigürasyon ve güvenli varsayılanlarla belirlenir; production modda sessiz insecure fallback yok.
- TLS network transit korumasıdır; disk, WAL, temporary file, backup ve replica storage encryption ayrı kapsamdır.

### 3.5 DCPcrypt removal checklist

- [ ] DCPcrypt import/uses, unit, package, Lazarus package, build script, CI, docs ve test fixture referanslarını tarayıp envanterle.
- [ ] DCPcrypt'in hangi algoritma/API'lerinin hangi VDB modüllerinde kullanıldığını eşle.
- [ ] VDB Crypto facade/interface contract'ını tasarla ve review et.
- [ ] Provider bağımlılığını pinle; desteklenen OS/CPU ve library version matrisini belirle.
- [ ] Known-answer tests (NIST/RFC test vectors) ve boundary/error tests ekle.
- [ ] Provider implementation ve integration tests tamamla.
- [ ] Her caller'ı facade'a taşı; davranış ve error handling testleri ekle.
- [ ] Eski DCPcrypt kod yolunu feature flag ile geçici karşılaştırma gerekiyorsa yalnızca test ortamında kullan; release binary'de bırakma.
- [ ] DCPcrypt dependency/license/SBOM/build artifacts temizle.
- [ ] Fresh checkout + clean CI'da DCPcrypt olmadan tüm target'ları derle/test et.
- [ ] Binary dependency inspection ile DCPcrypt sembol/artefact kalmadığını doğrula.
- [ ] Release notes ve migration/key compatibility dokümanı yayınla.

## 4. Storage, WAL, transaction ve crash safety

Bu alan release blocker'dır. WAL ve recovery kodu özel olarak bağımsız review görmelidir.

### 4.1 WAL/commit invariant'ları

- Commit acknowledgment ancak gerekli WAL kayıtları ve commit marker dayanıklı storage'a flush/sync edildiğinde verilir (platform semantics açıkça doğrulanmalı).
- WAL record formatında magic, version, length, transaction ID, sequence/LSN, checksum, type ve sınır doğrulaması bulunur.
- Partial/torn record, invalid length, checksum mismatch, truncated tail, duplicate/out-of-order LSN ve disk-full durumları deterministik şekilde ele alınır.
- Recovery idempotent olmalı; aynı recovery tekrar çalıştığında state bozulmamalı.
- Recovery redo/undo veya seçilen modelin kuralları formal olarak belgelenir; transaction atomicity ve durability test edilir.
- Checkpoint: WAL truncation ancak checkpoint state ve gerekli durability garantileri doğrulandıktan sonra.
- Concurrent writers, page flush, checkpoint, backup ve recovery arasındaki lock/order kuralları belgelenir.
- Disk-full, permission failure, fsync/sync failure ve I/O error commit/rollback davranışı test edilir.
- WAL sequence wraparound/overflow ve file rotation sınırları test edilir.
- WAL içeriği hassas veri içerebilir; encryption at rest, access control, retention ve secure deletion beklentileri belirlenir.

### 4.2 Crash matrix

Her önemli state transition için process crash ve mümkünse OS/power-loss simülasyonu:
- WAL record yazılmadan önce/sonra;
- commit record yazılmadan önce/sonra;
- flush/sync öncesi/sonrası;
- page write öncesi/ortası/sonrası;
- checkpoint metadata ve checkpoint completion arasında;
- backup snapshot ve manifest arasında;
- replication send/ack sınırında.

Crash test sonrası invariant: committed transaction kaybolmaz; uncommitted transaction görünür olmaz; index/table state tutarlı kalır; recovery tamamlanır veya açık fatal recovery error verir.

### 4.3 Backup/restore

- Online backup için consistent snapshot/LSN ve gerekli WAL retention.
- Backup manifest: VDB version, format version, schema/catalog metadata, snapshot LSN, checksum, encryption/key ID, timestamp, backup type.
- Backup integrity verification ve restore validation ayrı komutlar.
- Restore testleri düzenli CI/soak pipeline'da; yalnızca backup üretmek başarı değildir.
- Full/incremental backup, restore order, point-in-time recovery (destekleniyorsa), retention ve offsite copy politikaları.
- Restore sırasında eksik/yanlış key, bozuk archive, checksum failure, path traversal ve disk exhaustion testleri.
- Backup'ın encryption key olmadan açılmadığı; key recovery planının gerçekçi olduğu doğrulanır.

## 5. SQL V3 uyumluluk ve correctness

- V3 SQL kapsamı bir compatibility matrix olarak tutulur: feature, expected behavior, test id, pass/fail/skip, known difference.
- PostgreSQL ile differential tests: desteklenen SQL subset'inde aynı schema/data/query için sonuç, NULL semantics, error class ve transaction davranışı karşılaştırılır.
- PostgreSQL referansı VDB'nin desteklemediği feature'lar için “not supported” olarak işaretlenir; sessizce farklı sonuç üretme kabul edilmez.
- Parser, binder, planner, executor, expression evaluator, aggregate, join, window, DML, DDL ve transaction davranışları ayrı test gruplarına ayrılır.
- SQL fuzzing: grammar-based generation, mutation, minimized repro case ve regression corpus.
- Null, collation, numeric overflow/precision, date/time/timezone, implicit cast, operator precedence, subquery, correlated query, CTE, window frames ve aggregate edge cases.
- Deterministic result ordering yalnızca ORDER BY ile garanti edilir; testler varsayılan ordering'e yanlış güvenmemeli.
- Error handling: syntax/semantic/constraint/permission/serialization errors doğru katmanda ve stabil biçimde.
- Query cancellation, statement timeout, memory limit, max rows/result size ve resource exhaustion davranışı.
- `VDbExecutor.pas` gibi büyük modülleri behavior-locked testlerle böl: SELECT, JOIN, aggregate, expression, DML, DDL, transaction, window. Her PR'da bir davranış alanı.

## 6. B+Tree, index ve storage verimliliği

- Insert/update/delete correctness; duplicate key, NULL, composite index, unique constraint ve concurrent modifications testleri.
- Delete sonrası leaf/internal node merge/redistribution veya bilinçli deferred-rebalance politikası belgelenir.
- Fragmentation, page utilization, tree height, dead entry ve index bloat ölçülür.
- Rebuild/reindex operasyonu, online/offline sınırları, crash recovery ve concurrent access davranışı.
- Index consistency checker: table/index karşılaştırması, orphan entry, duplicate/missing entry tespiti; repair yalnızca açık, güvenli modda.
- Page checksum, page version, free-space management, page split/merge ve overflow sınır testleri.
- Büyük dataset, skewed keys, monotonik keys, random keys, delete-heavy ve mixed workload benchmark.
- Query planner index seçimi ve stale statistics etkisi; ANALYZE/statistics güncelleme davranışı.

## 7. Security hardening

### 7.1 Threat model

- VDB server, client, replication, admin interface, backup, TLS, file system, plugin/extension ve build supply chain sınırlarını çiz.
- Trust boundaries, privileged operations, secrets, sensitive data, attacker capabilities ve abuse cases dokümante edilir.
- STRIDE veya eşdeğer threat model; risk register ve mitigations PR'larla güncellenir.

### 7.2 Authentication / authorization

- Authentication ve authorization ayrıdır; authenticated user otomatik admin değildir.
- Least privilege: role, grant/revoke, object-level permission, admin separation.
- Default production policy: remote access için güvenli auth zorunlu; `trust` yalnız loopback/test veya açıkça güvenilen izole ortam, üretim konfigürasyonunda kapalı.
- Password hashing: salt + Argon2id veya onaylı KDF; plaintext/reversible password storage yok.
- Login throttling, brute-force protection, credential rotation, session/token expiry ve audit.
- RLS/row policy bypass yolları; owner/admin semantics ve policy interaction testleri.
- Privilege escalation, role inheritance, object ownership ve grant revoke edge cases.

### 7.3 Network / protocol

- Frame length, packet count, nesting, encoding, integer overflow ve allocation limitleri doğrulanır.
- Malformed/oversized/partial/slow client, disconnect mid-frame, reconnect, duplicate request ve protocol version mismatch testleri.
- Connection quotas, per-user/per-IP limits (deployment context'e göre), idle timeout, query timeout ve bounded queues.
- Parser fuzzing; untrusted network input hiçbir zaman doğrudan memory allocation veya SQL execution'ı limitsiz tetiklememeli.
- PG wire compatibility varsa differential protocol tests; error packet, auth negotiation, startup parameters ve cancellation.
- TLS certificate verification ve secure defaults; downgrade/insecure fallback yok.

### 7.4 Data protection ve audit

- Secret redaction, structured logging, audit event taxonomy ve retention.
- Audit log manipülasyonu/silme yetkileri, clock drift ve log volume exhaustion.
- Sensitive data log/trace/crash dump'ta bulunmamalı.
- SQL injection için parameterized query, prepared statement ve internal SQL construction review.
- Path traversal, symlink, unsafe temp file, file permission ve race condition testleri.
- DoS: memory, CPU, disk, connection, query plan explosion, sort/hash spill ve replication lag limitleri.

## 8. Reliability, replication ve operasyon

- Replication consistency modelini (sync/async), acknowledged commit semantics, lag, failover ve split-brain riskini açıkça tanımla.
- WAL shipping, reconnect, duplicate/missing sequence, partial transfer ve corrupted replica tests.
- Failover/fencing ve single-writer guarantee; network partition altında iki primary oluşmaması.
- Replica rebuild/resync, snapshot + WAL catch-up ve interrupted resync recovery.
- Health/readiness/liveness ayrı; readiness storage/recovery/auth/config durumunu dikkate alır.
- Metrics: connections, query latency, throughput, transaction commit/rollback, WAL bytes/flush latency, checkpoint, cache hit/miss, page IO, replication lag, errors, resource use.
- Metrics endpoint auth/network exposure; sensitive labels/SQL text/credentials yok.
- Operational runbooks: startup, shutdown, backup, restore, upgrade, key rotation, failover, corruption, disk full, certificate expiry, incident response.

## 9. CI/CD ve release engineering

### 9.1 Build matrix

- Linux x86_64; Windows x86_64; macOS (repo ve FPC/OpenSSL destek durumuna göre); mümkünse ARM64.
- Debug + optimized/release; range/overflow/assertion checks uygun test modlarında.
- Clean checkout build; cached artifact'e bağımlı olmayan reproducible pipeline.
- FPC/Lazarus/compiler ve OpenSSL/provider sürümleri pinlenir; güncelleme PR'ı test edilir.
- CI failure release blocker; flaky testler quarantine'e alınsa bile issue, owner ve deadline gerekir.

### 9.2 Pipeline stages

1. Formatting/static checks ve compiler warnings.
2. Unit tests.
3. Integration tests (server/client, auth, TLS, storage).
4. SQL regression + PostgreSQL differential subset.
5. WAL/recovery/crash suite.
6. Security tests: fuzz smoke, malformed protocol, dependency scan, secret scan, SAST (uygun araçlar).
7. Performance regression thresholds.
8. Packaging/install/uninstall/upgrade smoke tests.
9. SBOM, artifact hashes, signed release artifact ve provenance.
10. Release candidate acceptance ve human approval.

### 9.3 Supply chain

- Dependency pinning, license review, vulnerability monitoring, source provenance.
- Build secrets least privilege; pull request fork'larında secret erişimi yok.
- Release signing key CI log/repository içinde bulunmaz; mümkünse HSM/managed signing.
- Artifact checksum/signature ve bağımsız verify instructions.
- Release notes: breaking changes, security fixes, migration, known issues, support matrix.
- Her release'in source commit, compiler/provider versions, build environment, SBOM ve test sonuçları arşivlenir.

## 10. Test stratejisi — zorunlu kalite kapıları

- **Unit:** deterministic, edge/boundary, error paths; coverage metriği tek başına yeterlilik değildir.
- **Integration:** gerçek server/client process, gerçek disk dosyaları, gerçek TLS/provider.
- **Regression:** her bug için minimal repro ve kalıcı test.
- **Differential:** PostgreSQL desteklenen subset; SQL ve protocol.
- **Property-based:** B+Tree invariants, transaction state, serialization, parser.
- **Fuzz:** SQL parser, wire protocol, WAL/page deserializer, backup archive, config parser. Crash/hang/memory blow-up triage.
- **Fault injection:** IO short write, sync failure, disk full, network reset, timeout, corruption, process kill.
- **Stress/soak:** concurrency, long duration, mixed read/write, memory leak, connection churn, checkpoint/replication.
- **Recovery:** crash matrix ve restore drills.
- **Performance:** stable dataset/workload, warm/cold cache, p50/p95/p99, throughput, memory, IO; hardware/environment metadata.
- **Security:** authz matrix, negative tests, privilege escalation, malformed inputs, dependency vulnerabilities.

Her test: test id, setup, expected result, failure diagnostics, seed/reproducibility ve minimum supported platform bilgisi taşımalı.

## 11. Modüler refactor ve API stabilitesi

- Refactor öncesi characterization tests; behavior değişikliği ile refactor aynı PR'da birleştirilmez.
- Public API, internal API ve on-disk/wire format ayrı versioning kurallarına sahip olur.
- Module boundaries: storage/page, WAL, transaction, index, SQL parser, planner, executor, network protocol, auth, crypto, observability.
- Circular dependency ve global mutable state azaltılır; resource ownership/cleanup açık.
- Exception/error propagation; error code ve context standardize edilir.
- Büyük executor parçaları küçük sorumluluklara ayrılır; her extraction davranış testleriyle.
- Compatibility policy: semantic versioning veya repo'nun mevcut versioning yaklaşımı; breaking changes migration note ile.

## 12. Dokümantasyon ve kullanıcıya dönük operasyon

Asgari docs set:

- `README.md`: VDB V3 nedir, status, build/test, limits ve non-production caveats.
- `docs/architecture/`: component diagram yerine text architecture, module map, data flow, lock order, WAL/recovery design, replication model.
- `docs/security/`: threat model, crypto policy, key management, TLS, auth/RBAC/RLS, vulnerability disclosure.
- `docs/operations/`: install, config, service, monitoring, backup/restore, upgrade, recovery, incident runbooks.
- `docs/sql/`: supported SQL matrix, PostgreSQL differences, examples.
- `docs/development/`: contribution, test taxonomy, CI, release process.
- `CHANGELOG.md`, `SECURITY.md`, `LICENSE`, dependency/SBOM notices.
- Config örnekleri güvenli default; gerçek secret içermez. Production deployment checklist ayrı.

## 13. Fazlar ve teslimatlar

### Phase 0 — V3 baseline / governance
- V2 freeze kararı, branch/tag politikası ve V3 release train.
- Repo envanteri, module map, dependency/SBOM, CI baseline, known failures.
- Architecture Decision Records (ADR) formatı ve risk register.

**Exit:** Baseline tekrarlanabilir; V3 kapsamı ve bilinen eksikler açık.

### Phase 1 — DCPcrypt removal design
- DCPcrypt kullanım envanteri ve migration mapping.
- Crypto facade/provider contract ADR.
- Algorithm, nonce, key storage, encryption envelope ve compatibility kararları.
- OpenSSL/provider destek matrisi ve licensing review.

**Exit:** Design review ve test planı onaylı; API ve migration davranışı belgeli.

### Phase 2 — Crypto provider + tests
- Provider adapter, CSPRNG, AEAD, hash/MAC/KDF API'leri.
- Known-answer vectors, negative tests, error tests, cross-platform CI.
- Key store abstraction ve key lifecycle metadata.

**Exit:** Provider testleri geçer; güvenli fallback yok; secret logging yok.

### Phase 3 — Caller migration / DCPcrypt removal
- Caller'ları facade'a taşı.
- DB files/WAL/backups/passwords/TLS kullanım alanlarını ayrı ayrı migrate et.
- DCPcrypt packages/imports/build references kaldır.
- Clean build + binary/SBOM scan.

**Exit:** DCPcrypt VDB runtime/build/release'de yok; tüm testler geçiyor; migration/compatibility açıklanmış.

### Phase 4 — WAL/storage correctness
- WAL record validation, flush/sync semantics, checkpoint, recovery, crash matrix.
- Backup/restore integrity ve restore drills.
- Page/index consistency checks.

**Exit:** Crash/recovery invariants kanıtlı testlerle; critical data-loss bug yok.

### Phase 5 — SQL V3 correctness
- SQL coverage matrix ve skip governance.
- PostgreSQL differential suite, parser/executor fuzz, minimized regression corpus.
- Executor behavior-locked modular refactor.

**Exit:** Supported SQL subset'in bilinen farklılıkları belgeli; kritik semantic regression yok.

### Phase 6 — Index/performance/reliability
- B+Tree deletion/rebalance strategy; fragmentation/reindex.
- Performance baselines ve regression thresholds.
- Concurrency/soak/replication/failover testleri.

**Exit:** Ölçülebilir benchmark, kabul edilen limits ve dayanıklılık raporu.

### Phase 7 — Security & operations
- Threat model, auth/RBAC/RLS, TLS, protocol fuzz, resource limits.
- Observability, runbooks, upgrade, backup/restore ve incident response.
- SAST/dependency scanning/SBOM/signing.

**Exit:** Security review findings triaged; critical/high findings release blocker olarak kapalı veya resmi risk acceptance.

### Phase 8 — Release candidate / independent review
- Release candidate build, full CI, install/upgrade/restore drills.
- Independent code/security review; remediation ve retest.
- Release notes, support matrix, known issues, signed artifacts.

**Exit:** Release checklist tamam; açık riskler şeffaf; release owner approval.

## 14. Release gate — “Production Ready” demek için

Aşağıdakiler tamamlanmadan production-ready etiketi kullanılmaz:

- [ ] V3 tek aktif development line; V2 legacy/frozen.
- [ ] DCPcrypt bağımlılığı source/build/runtime/package/SBOM'dan kaldırılmış.
- [ ] Crypto provider ve API threat/design review görmüş; known-answer testleri ve error handling geçiyor.
- [ ] AEAD nonce uniqueness, key rotation, key loss, backup/restore ve WAL encryption kararları belgeli/testli.
- [ ] TLS secure defaults, certificate validation ve production auth zorunluluğu testli.
- [ ] WAL/commit/checkpoint/recovery crash matrix geçiyor; committed data loss/uncommitted visibility yok.
- [ ] Backup restore drill başarılı; backup integrity doğrulanıyor.
- [ ] SQL V3 compatibility matrix güncel; skip/fail şeffaf; differential suite çalışıyor.
- [ ] Index/table consistency checks ve corruption handling testli.
- [ ] Cross-platform clean build ve CI green; flaky testler kontrol altında.
- [ ] Fuzzing corpus, security tests ve dependency scan pipeline'da.
- [ ] Critical/high security finding'ler kapalı veya risk sahibi tarafından yazılı kabul edilmiş.
- [ ] Performance/soak sonuçları ve supported workload/limits belgeli.
- [ ] SBOM, release signature, provenance, changelog ve upgrade instructions hazır.
- [ ] Runbook, monitoring, backup, restore, key rotation ve incident procedures mevcut.
- [ ] Independent review tamamlanmış; bulgular kapatılmış/izlenebilir.

**Bu kriterler yazılım kalite kapılarıdır; herhangi bir resmi sertifikasyonun yerine geçmez.** Üretim verisi ve kritik sistemler için ayrıca deployment mimarisi, işletim prosedürleri, yedekleme, güvenlik operasyonları ve bağımsız doğrulama gerekir.

## 15. AI ajanının çalışma biçimi / PR şablonu

Her PR şu formatta hazırlanır:

```text
PR title: [VDB-V3][PHASE-N] kısa açıklama

Problem / requirement:
- Hangi gereksinim veya risk çözülüyor?

Scope:
- Değişen modüller
- Değişmeyen davranışlar
- Data format/API etkisi

Implementation:
- Tasarım kararı ve gerekçe
- Error/failure behavior
- Security considerations

Tests:
- Komutlar
- Test sayısı ve sonuç
- Platform/compiler/provider matrisi
- Crash/fuzz/differential testleri (uygunsa)

Evidence:
- CI run
- Benchmark/recovery output
- SBOM/dependency scan (uygunsa)

Risks / rollback:
- Bilinen riskler
- Rollback/migration planı

Status:
- [ ] Review
- [ ] Tests pass
- [ ] Docs updated
- [ ] Release gate impact assessed
```

Ajan bir fazın tümünü tek seferde değiştirmeye çalışmaz. Önce planı issue/task listesine böler, bağımlılıkları sıralar, en küçük güvenli PR'ı uygular ve kullanıcıya sonuç raporu verir.

## 16. İlk uygulanacak görev sırası

1. `V3_ONLY_POLICY` — V2 freeze ve V3-only çalışma kuralını dokümante et.
2. `V3_BASELINE_AUDIT` — repo envanteri, CI/test baseline, known failures, module map.
3. `DCPCRYPT_USAGE_INVENTORY` — tüm referanslar ve kullanım alanları.
4. `CRYPTO_ARCHITECTURE_ADR` — provider/API/key/nonce/encryption envelope kararı.
5. `CRYPTO_TEST_HARNESS` — known-answer + negative tests + cross-platform CI.
6. `CRYPTO_PROVIDER_IMPLEMENTATION` — güvenilir provider adapter.
7. `DCPCRYPT_CALLER_MIGRATION` — caller'ları sırayla VDB facade'a geçir.
8. `DCPCRYPT_DEPENDENCY_REMOVAL` — packages, build, CI, docs, SBOM ve binary cleanup.
9. `WAL_RECOVERY_AUDIT` — commit/checkpoint/recovery/crash matrix.
10. `BACKUP_RESTORE_HARDENING` — integrity, restore drills, key scenarios.
11. `SQL_V3_DIFFERENTIAL` — PostgreSQL subset testleri ve coverage matrix.
12. `BTREE_INTEGRITY` — deletion/rebalance/fragmentation/consistency.
13. `SECURITY_HARDENING` — threat model, auth, TLS, protocol fuzz, resource controls.
14. `CI_RELEASE_GATES` — SBOM, signing, provenance, release checklist.
15. `RC_INDEPENDENT_REVIEW` — RC ve production readiness değerlendirmesi.

## 17. Kaynak ve standart referansları

- NIST Secure Software Development Framework (SSDF), SP 800-218 v1.1: https://csrc.nist.gov/Projects/SSDF  
  Güvenli geliştirme, kaynak/build koruması, release integrity, vulnerability response ve risk-temelli süreç için referans.
- NIST SP 800-218: https://csrc.nist.gov/pubs/sp/800/218/final  
- NIST SSDF DevSecOps mapping: https://pages.nist.gov/nccoe-devsecops/mapping-ssdf.html  
- Microsoft Cryptographic Recommendations (AES-GCM nonce uniqueness dahil): https://learn.microsoft.com/en-us/security/engineering/Cryptographic-Recommendations  
- NIST SP 800-38D (GCM): https://csrc.nist.gov/pubs/sp/800/38/d/final  
- PostgreSQL documentation (SQL behavior/differential reference): https://www.postgresql.org/docs/  
- OpenSSL documentation: https://docs.openssl.org/  

Standartlar ve provider sürümleri uygulama sırasında yeniden doğrulanır; tasarım kararları ADR'lerde tarih/sürüm ile kaydedilir.

---


# VDB V3 — Single-File Storage Architecture

## Objective

VDB V3 shall support a professional single-file database format in which the complete database state can be represented by one `.odb` file.

Example:

```text
metro.odb
```

The database file shall contain or logically encapsulate:

- Database metadata
- Data pages
- Index pages
- Transaction metadata
- WAL records
- Checkpoint metadata
- Recovery metadata
- Generation information
- Required integrity information

The user must not need to manually manage internal WAL, base, generation, or temporary storage files in the default embedded single-file mode.

## Current Storage Architecture Investigation

Before implementation:

1. Inspect V3 storage architecture.
2. Identify every code path creating `.odb.log`.
3. Identify WAL segment creation and rotation.
4. Identify base/generation file creation.
5. Identify checkpoint and compaction behavior.
6. Identify database open, close, recovery, backup, and restore flows.
7. Identify all filesystem dependencies and file naming conventions.
8. Document the current storage lifecycle.
9. Identify whether the current page-store architecture can be reused.
10. Do not assume that similarly named storage modules have identical responsibilities.

Relevant modules include:

- `VDbPageStore.pas`
- `VDbPageWal.pas`
- `VDbPageEngine.pas`
- `VDbBackendV3.pas`
- Generation and storage-related modules identified during repository inspection

## Required Storage Modes

### Mode A — Embedded Single-File

Default embedded database mode:

```text
database.odb
```

Requirements:

- All persistent database content resides in one file.
- No externally visible `.odb.log` directory is required.
- WAL must remain available internally.
- Crash recovery must remain reliable.
- Transactions must preserve ACID guarantees.
- Checkpointing must not corrupt the database.
- Database relocation must require only the `.odb` file when safely closed.
- Backup must produce a consistent database artifact.
- File format must support versioning and future migration.

### Mode B — Managed Storage

Optional advanced storage mode:

```text
database.odb
database.odb.log/
    wal/
    base/
```

This mode may use external WAL segments and base/generation files when appropriate for performance, scalability, operational recovery, or large databases.

The engine must clearly distinguish embedded and managed storage modes.

## Single-File Container Design

Design a versioned `.odb` container.

Suggested logical regions:

- Superblock
- Database metadata
- Page directory / allocation metadata
- Data page region
- Index page region
- WAL region
- Checkpoint region
- Recovery metadata region
- Free-space / allocation metadata

The exact layout must be determined through storage design and benchmarking.

Do not implement a simplistic concatenation of files.

The container must support:

- Explicit format version
- Database identity
- Validity markers
- Checksums
- Atomic metadata updates
- Safe page allocation
- Recovery boundaries
- File growth
- Free-space management
- Consistent checkpoint metadata
- Corruption detection

## WAL Requirements

Single-file mode MUST NOT eliminate WAL durability requirements.

Implement or adapt:

- Append-only WAL records
- Transaction commit records
- WAL checksums
- WAL sequence numbers
- Commit durability
- Recovery scanning
- Incomplete transaction detection
- Torn-write detection
- Checkpoint coordination
- Safe WAL reclamation
- Recovery after abrupt process termination
- Recovery after simulated power failure

WAL records must become durable before corresponding data pages are considered safely committed according to the defined durability policy.

## Checkpoint Requirements

Checkpoint implementation must:

- Establish a consistent checkpoint boundary.
- Preserve recoverability during checkpoint execution.
- Prevent premature WAL reclamation.
- Support interrupted checkpoint recovery.
- Validate metadata before accepting a checkpoint.
- Maintain a clear relationship between checkpoint LSN and durable WAL.
- Prevent old and new checkpoint metadata from becoming simultaneously invalid.
- Support crash injection at every critical checkpoint step.

## Backup and Restore

Single-file backup must not be implemented as an uncontrolled file copy while the database is actively writing.

Provide:

- Consistent online backup.
- Safe offline backup.
- Backup integrity verification.
- Restore validation.
- Database identity handling.
- Compatibility validation.
- Recovery after restoring a database with incomplete transactions.
- Backup/restore regression tests.

## Single-File Storage Tests

Required tests:

1. Create database and reopen.
2. Insert, update, delete, commit.
3. Rollback.
4. Crash before commit.
5. Crash after commit.
6. Crash during checkpoint.
7. Crash during file growth.
8. Crash during metadata update.
9. WAL recovery.
10. Checkpoint recovery.
11. Database file relocation.
12. Backup and restore.
13. Large database growth.
14. Concurrent readers and writers.
15. Storage corruption detection.
16. Interrupted transaction recovery.
17. Long-running stress test.
18. Cross-platform file handling.

## Migration Strategy

Do not abruptly replace the current storage engine.

1. Document current storage format.
2. Establish existing durability tests.
3. Design single-file container.
4. Implement a compatibility layer.
5. Create a single-file prototype.
6. Run existing SQL regression tests.
7. Run storage fault-injection tests.
8. Run performance comparisons.
9. Implement conversion from managed storage to single-file format.
10. Validate converted database integrity.
11. Add backward compatibility rules.
12. Release only after all storage gates pass.

## Production Acceptance Criteria

Single-file storage is production-ready only when:

- Database integrity survives all defined crash scenarios.
- WAL recovery is deterministic.
- Checkpoint recovery is verified.
- Backup/restore is reliable.
- No committed transaction is lost under the documented durability policy.
- No uncommitted transaction becomes visible after recovery.
- File corruption is detected rather than silently accepted.
- SQL regression results remain unchanged.
- Performance is measured against managed storage.
- Cross-platform CI passes.
- Migration tests pass.
- Storage format documentation is complete.

## Architectural Rule

The single-file design is a storage format and deployment capability, not a reason to remove WAL, checkpointing, transactions, or recovery mechanisms.

Correctness, durability, integrity, and recoverability take precedence over minimizing the number of files.



## Son talimat

**Bu skill'i VDB V3 repository'sinde uygulanabilir bir engineering backlog'a dönüştür.** İlk olarak Phase 0 envanter/baseline ve DCPcrypt kullanım haritasını çıkar. Repository kanıtı olmadan kod silme veya API değiştirme. Ardından her fazı küçük PR'larla uygula. Her PR'da test, dokümantasyon ve risk değerlendirmesi zorunludur. Hedef yalnız derlenen bir DB değil; veri kaybı, güvenlik, upgrade/restore ve operasyon davranışı test edilmiş, ölçülebilir ve bağımsız incelemeye hazır bir V3 ürünüdür.

---

# EK A — Phase 0 Uygulama Kanıtları ve Skill Revizyonları (2026-11-13)

> Bu bölüm skill'in soyut kurallarını **bu depodaki gerçekle** bağlar. İlk Phase-0 çıktısı üretildi:
> - `docs/engineering/BASELINE.md` — depo/denk/derleyici gerçeği, stub matrisi, gap listesi
> - `docs/engineering/DCPCRYPT_USAGE_INVENTORY.md` — tam kaldırma envanteri + hedef provider mimarisi
> - `docs/architecture/MODULE_MAP.md` — modül haritası

## A.1 Depo gerçeği (skill'in varsaydığı ama olmayan şeyler)

1. **Git deposu YOK.** `.git` yok; `.gitignore` duruyor ama işlevsiz. Skill §15 PR akışı ve §14 release gate kanıt zinciri **`git init` + ilk commit olmadan uygulanamaz**. Backlog'un 0. maddesidir.
2. **CI yok** (§9 tamamen hedef durumu anlatıyor; bugün sıfır pipeline). Kurulu toolchain: FPC 3.2.4 / Lazarus 4.4 — README'nin "Lazarus 4.6+" iddiası ortamla çelişiyor.
3. **`tests/` klasörü kalıcı değil** (oturumlar arasında kayboluyor; 15GB üretilmiş veri + gate script'leri bir oturumda var, diğerinde yok). Gate iddiaları commit'e bağlanana kadar **doğrulanamayan iddia** sayılacak.
4. Build-artifact kirliliği: kökte `.s` asmlist dump'ları, dcpcrypt altında `.o/.ppu`; `mtakip/` (ilgisiz proje) aynı kökte.
5. Kökte `sqltest.lpi` yok — README derleme komutu bayat.

## A.2 DCPcrypt gerçeği (kaldırma işi sanılandan küçük, borç sanılandan derin)

- Vendored yüzey 6 unit; **fiilen kullanılan 3 primitif**: AES-256 blok (`TDCP_rijndael`), SHA-256, Base64.
- Doğrudan tüketici **2 dosya**: `VDbCrypt.pas`, `VDbPgWire.pas:60` (base64). Gerisi facade üzerinden bakıyor → blast-radius küçük.
- **Ama**: GCM modu (GHASH+CTR) DCP'nin AES bloğu üstüne **elle yazılmış**; BLAKE2b+Argon2id `VDbKdf.pas` içinde sıfırdan. Skill §0.4'ün "kendi primitifini yazma" kuralı **fiilen ihlal edilmiş durumda** ve kod veri formatının parçası — silmek veri kaybı. Doğru tedavi: OpenSSL provider'a taşı + NIST KAT ile mühürle; builtin fallback yalnız kanıtlanmış mevcut kodun taşınması olabilir.
- OpenSSL zaten `VDbTls.pas` içinde dinamik yükleniyor → crypto provider için altyapı patenti hazır; DCPcrypt kaldırma ile TLS aynı bağımlılığı paylaşır, net bağımlılık sayısı düşmez ama tek modern stack'e iner.

## A.3 Kriptografi denetim bulguları (mevcut kod)

| Bulgu | Kanıt | Karar |
|---|---|---|
| Sayfa zarı sağlam: `nonce12\|ct\|tag16`, AAD=`VDB3PG\|pageno\|salt`, tag-before-plaintext | `VDbPageCrypto.pas:1-18` | korunur |
| **Nonce üretiminde hacim/çakışma analizi YOK** (sayfa başına rng nonce) | `VDbPageCrypto.pas:139` | Aşağıdaki A.4 kuralı bağlayıcıdır |
| KDF politikası çelişkisi: `.key`→Argon2id, sayfa-parola→**PBKDF2-SHA256 200k** | `VDbPageCrypto.pas:35` | ADR kararı + göç planı şart |
| CSPRNG fail-closed (OS kaynak yoksa hata) | `VDbCrypt.pas:48,666-723` | iyi, korunur |
| keycheck HMAC verifier'ı secret değil — doğru kullanım | `VDbPageCrypto.pas:16-18` | iyi |
| `Random()` yalnız trace-id ve changelog ID'sinde (kripto değil) | `VDbTrace.pas:159`, `VDbChangeLog.pas:650` | kripto dışı kabul; ID çakışması ayrıca test edilmeli |

## A.4 Skill'e eklenen bağlayıcı kurallar (revizyon)

- **R-1 (AEAD nonce politikası — §3.2'yi netleştirir):** Sayfa zarlarında random 12-byte nonce **ancak** şu üçü belgelenip test edilirse kabul: (a) sayfa başına yeniden-anahtarlama/klon senaryosunda nonce reuse analizi (aynı key+page+nonce kombinasyonunun doğamama gerekçesi), (b) beklenen ömür boyu şifrelenen sayfa sayısı ile birthday-bound hesabı (2^32 sınırının altında tasarım tavanı), (c) checkpoint/restore/backup-clone'un nonce durumunu bozmadığı testi. Alternatif ve **tercih edilen** tasarım: deterministic nonce = `key_gen(2) | page_no | rewrite_seq` — key-rotation sayacı ve sayfa yeniden-yazım sekansı zar içinde taşınır; reuse matematiksel olarak imkânsızlaşır. Hangisi seçilirse seçilsin karar `docs/architecture/CRYPTO_ADR.md` içinde kanıtla oturur.
- **R-2 (KDF tek politika):** Yeni yazımlarda parola tabanlı tüm türetmeler tek KDF politikasına bağlanır (hedef: Argon2id; PBKDF2 yalnız eski formatları okumak için salt-okunur kalır). Format versiyon alanı KDF kimliğini taşır.
- **R-3 (Doğrulanamayan iddia etiketi):** `tests/` veya CI kanıtına bağlanamış her "geçiyor" iddiası README/dokümanda `unverified` sayılır; release gate'te geçerli sayılmaz.
- **R-4 (Sunucu production koruması):** `vdbserver` `--trust` ile açılırsa yalnız loopback bind + açılışta kalın log uyarısı; `-h` ile dışa açık + trust = reddet. Auth başarısızlığında throttling/lockout (§7.1) implementasyona girer.
- **R-5 (Saf-Pascal / sıfır-dış-DLL sözleşmesi — SAHİP KARARI 2026-11-13, §0.4'teki "maintained provider" önceliğini değiştirir):** Çekirdek veritabanı ve şifreleme YALNIZ depo içindeki Free Pascal kaynak koduyla çalışmalıdır; hiçbir zorunlu akış harici DLL (OpenSSL dahil) yükleyemez/istemeden arayamaz. Varsayılan crypto provider = built-in (KAT-mühdar kendi kodumuz); OpenSSL yalnız opt-in cross-check/hızlandırma ve kullanıcı-isteğine-bağlı TLS özelliği olabilir. §3'ün "provider" mekanizması kalır, öncelik değişir. Kanıt kapısı: hiçbir DLL olmayan temiz makinede tüm sqltest + crypto gate'leri geçmeli. Ayrıntı: `docs/architecture/CRYPTO_ADR.md` EK-B.

## A.5 Güncellenmiş ilk-görev sırası (§16'nın yerine geçer)

0. `git init` + `.gitignore` düzeltmesi (artifact/d veri hariç) + ilk commit — **önce bu**.
1. ✅ V3_ONLY_POLICY + V3_BASELINE_AUDIT + DCPCRYPT_USAGE_INVENTORY → `docs/engineering/BASELINE.md`, `DCPCRYPT_USAGE_INVENTORY.md`, `docs/architecture/MODULE_MAP.md` (bu commit).
2. `CRYPTO_ARCHITECTURE_ADR` — A.3 tablosu + R-1/R-2 kararlarıyla yazılır.
3. `CRYPTO_TEST_HARNESS` — NIST KAT vektörleri + eski şifreli .odb round-trip fikstürleri (git LFS değil: küçük üretilmiş fikstür + üretici script).
4. `CRYPTO_PROVIDER_IMPLEMENTATION` (OpenSSL provider, SelfTest fail-closed).
5. `DCPCRYPT_CALLER_MIGRATION` → 6. `DCPCRYPT_DEPENDENCY_REMOVAL`.
7. `WAL_RECOVERY_AUDIT` + kalıcı crash-matrix testi (kill-9 script'i CI'a).
8. `SECURITY`: R-4 sunucu korumaları + `VDbTls` client doğrulama denetimi (`VDbTls.pas:164` çevresi).
9. Stub yüzey tutarlılığı (RETURNING/PROC/TRIGGER → ya implement ya dokümante `ecUnsupported` + test).
10. CI matrix (en az win/linux: build + sqltest + gate) — skill §9'un çekirdek kümesi.

Sonraki fazlar (§16'nın kalanı: SQL differential, BTree integrity, backup drills, replication, RC) sıra bekliyor.
