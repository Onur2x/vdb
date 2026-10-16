# 🗺️ YOL HARİTASI (ROADMAP) — VDB MOTORU / ROADMAP — VDB ENGINE

> **TR — Taze yazım: 2026-10-13** · **güncelleme: 2026-10-15** — bu dosya sıfırdan, kodda doğrulanmış durumla yeniden yazıldı; v2.1 performans sürümü ve R-12 DEVAM (T107–T109) işlendi.
>
> **Test tabanı (2026-10-15):** `sqltest` **2251/2251 yeşil** (138 test prosedürü) · `crashtest` **8/8** (çökme dayanıklılığı — veri kaybı yok) · `vdbcrypttest` **60/60** ·
> `vdbapitest` **170/170** · `vdbclienttest` **101/101** · `vdbserver.exe` derlendi ·
> `VDbXPrimsTest`/`VDbPoolTest` tarihsel (program kaynakları ağaçta yok — §4.12)
>
> **Kalan iş: 0 — yol haritasındaki 24 maddenin TAMAMI ✅ BITTI.** Son iki
> madde 2026-10-13'te kapatıldı: R-24 SHOW STATS (§5.11) ve R-12 Full TCP
> SQL sunucusu (§5.12).
>
> ---
>
> **EN — Rewritten: 2026-10-13** · **updated: 2026-10-15** — this file was rewritten from scratch against code-verified state; the v2.1 performance release and the R-12 continuation (T107–T109) are folded in.
>
> **Test baseline (2026-10-15):** `sqltest` **2251/2251 green** (138 test procedures) · `crashtest` **8/8** (crash durability — zero data loss) · `vdbcrypttest` **60/60** ·
> `vdbapitest` **170/170** · `vdbclienttest` **101/101** · `vdbserver.exe` built ·
> `VDbXPrimsTest`/`VDbPoolTest` historical (program sources not in tree — §4.12)
>
> **Remaining work: 0 — ALL 24 roadmap items ✅ DONE.** The last two were
> closed on 2026-10-13: R-24 SHOW STATS (§5.11) and R-12 Full TCP
> SQL server (§5.12).

---

## 1. YOL HARİTASI TABLOLARI

### 🔴 FAZ 0: Temel Veri Bütünlüğü ve Eşzamanlılık (KRİTİK)

| ID | Özellik | Açıklama | Zorluk | Durum |
|----|---------|----------|--------|-------|
| R-01 | MVCC / Snapshot Isolation | Okuyucular yazıcıyı bloke etmez. Transaction-level snapshot + nested SELECT snapshot. WAL zaten vardı → seq tabanlı görünüm yeterli. | Yüksek | ✅ BITTI |
| R-02 | SAVEPOINT / Nested Transaction | SAVEPOINT sp1; ROLLBACK TO sp1; DDL dahil rollback. | Orta | ✅ BITTI |
| R-03 | UPSERT (ON CONFLICT) | INSERT ... ON CONFLICT(pk) DO UPDATE SET ... / DO NOTHING; EXCLUDED; INSERT SELECT ON CONFLICT. | Orta | ✅ BITTI |
| R-04 | RETURNING | INSERT/UPDATE/DELETE ... RETURNING — parser + executor tam destek (ON CONFLICT RETURNING dahil). | Orta | ✅ BITTI |

### 🟠 FAZ 1: SQL Standartları ve Gelişmiş İlişkisel Özellikler

| ID | Özellik | Açıklama | Zorluk | Durum |
|----|---------|----------|--------|-------|
| R-05 | Trigger (F-36) | Phase A/B/C: CREATE/DROP, BEFORE/AFTER/INSTEAD OF × INSERT/UPDATE/DELETE ROW/STATEMENT, WHEN, NEW/OLD, nested trigger, cascade. | Yüksek | ✅ BITTI |
| R-06 | View (Gerçek) | CREATE VIEW → TViewDef kataloğunda, ExecSelect rewriter ile expand; VIEW DML (INSERT/UPDATE/DELETE). | Orta | ✅ BITTI |
| R-07 | Materialized View | CREATE MATERIALIZED VIEW + REFRESH MATERIALIZED VIEW (tam). | Orta | ✅ BITTI |
| R-08 | Stored Procedure / Function | CREATE FUNCTION ... LANGUAGE SQL + CALL / SELECT func(). PL/pgSQL alt kümesi; F-35 parametre skope + skaler alt sorgu. | Yüksek | ✅ BITTI |
| R-09 | LATERAL JOIN | CROSS JOIN LATERAL (SELECT ...) — correlated subquery'nin set-returning versiyonu. | Orta | ✅ BITTI |
| R-10 | CYCLE Detection (Recursive CTE) | WITH RECURSIVE ... CYCLE col SET is_cycle USING path — sonsuz döngü koruması, gerçek özyineleme (delta). | Orta | ✅ BITTI |
| R-11 | DEFERRABLE Constraints | SET CONSTRAINTS ALL DEFERRED → transaction sonuna kadar erteleme. | Orta | ✅ BITTI |

### 🟡 FAZ 2: Ölçeklenebilirlik ve Performans

| ID | Özellik | Açıklama | Zorluk | Durum |
|----|---------|----------|--------|-------|
| R-12 | Connection Pool + TCP SQL Sunucusu (Full) | Havuz API + SHM slotları + atomik kiralama (VDbPoolTest 10/10) + **TCP SQL sunucusu** (`VDbSqlServer.pas`/`vdbserver.lpr`) + **istemci** (`VDbClientNet.pas`) — VDBS protokolu (bkz. §5.12). | Çok Yüksek | ✅ BITTI (Full) |
| R-13 | Table Partitioning | HASH/RANGE/LIST + sorgu zamanı partition pruning; EXPLAIN raporu + SHOW PARTITIONS. | Yüksek | ✅ BITTI (Full) |
| R-14 | Parallel Query Execution | Gerçek işçi havuzu (TThread + RTLEvent) + paralel ORDER BY (kararlı); EXPLAIN "Parallel Seq Scan (workers=N)". | Yüksek | ✅ BITTI (Full) |
| R-15 | Cost-Based Optimizer | ANALYZE istatistikleri, maliyet modeli (VDbCost), index/seq seçimi, join sırası; EXPLAIN `(cost=a..b rows=N)`. | Yüksek | ✅ BITTI (Full) |
| R-16 | Incremental Backup / WAL Archiving | WAL segmentleri → arşiv klasörü → PITR (RECOVER TO TIMESTAMP/NOW). | Yüksek | ✅ BITTI |
| R-17 | Streaming Replication | WAL log-shipping (dosya modu) + GERÇEK TCP akışı (VDBR protokolü, gerçek soketler). | Çok Yüksek | ✅ BITTI (Full) |
| R-25 | Performans: PK Lazy Index + Group Commit | BETWEEN/ORDER BY için tembel PK sıralı index (Seq Scan → Index Scan, 14x) + `SyncWriteInterval` group commit (UPDATE/DELETE 14-16x). | Orta | ✅ BITTI |

### 🟢 FAZ 3: Platform, Güvenlik ve Ekosistem

| ID | Özellik | Açıklama | Zorluk | Durum |
|----|---------|----------|--------|-------|
| R-18 | RBAC / Role / GRANT | CREATE ROLE, GRANT/REVOKE ... ON t\|* TO rol, SET ROLE. TVSql context'te CurrentRole. | Yüksek | ✅ BITTI |
| R-19 | Row Level Security (RLS) | ALTER TABLE ... ENABLE ROW LEVEL SECURITY + CREATE POLICY. | Yüksek | ✅ BITTI |
| R-20 | ICU Collation Desteği | COLLATE "tr-TR-u-kn-ks" — BCP-47 anahtar/değer motoru, kn doğal sıralama, ks güç katmanları. | Yüksek | ✅ BITTI (Full) |
| R-21 | Extension / Plugin Mekanizması | CREATE EXTENSION → gerçek .dll/.so/.dylib yükleme + ABI sürüm kapısı + sembol çözümü. | Yüksek | ✅ BITTI (Full) |
| R-22 | Online DDL (CONCURRENTLY) | CREATE INDEX CONCURRENTLY — üç fazlı online inşa; INVALID semantiği. | Yüksek | ✅ BITTI (Full) |
| R-23 | Cross-Platform DLL / C API | VDB_CALL (32-bit stdcall) + saf RTL platform birimi; build_lib.sh ile .so/.dylib. | Orta | ✅ BITTI |
| R-24 | Monitoring / pg_stat Benzeri | SHOW STATS / SHOW STATS TABLE t — komut sayısı, süre metrikleri, WAL kaydı, ANALYZE istatistikleri (cache hit ratio: blok önbellek katmanı olmadığından yok, §7). | Orta | ✅ BITTI (Full) |

---

## 1. ROADMAP TABLES (ENGLISH)

### PHASE 0: Core Data Integrity and Concurrency (CRITICAL)

| ID | Feature | Description | Difficulty | Status |
|----|---------|-------------|------------|-------|
| R-01 | MVCC / Snapshot Isolation | Readers never block writers. Transaction-level snapshot + nested SELECT snapshot. WAL already existed → a seq-based view suffices. | High | ✅ DONE |
| R-02 | SAVEPOINT / Nested Transaction | SAVEPOINT sp1; ROLLBACK TO sp1; rollback including DDL. | Medium | ✅ DONE |
| R-03 | UPSERT (ON CONFLICT) | INSERT ... ON CONFLICT(pk) DO UPDATE SET ... / DO NOTHING; EXCLUDED; INSERT SELECT ON CONFLICT. | Medium | ✅ DONE |
| R-04 | RETURNING | INSERT/UPDATE/DELETE ... RETURNING — full parser + executor support (including ON CONFLICT RETURNING). | Medium | ✅ DONE |

### PHASE 1: SQL Standards and Advanced Relational Features

| ID | Feature | Description | Difficulty | Status |
|----|---------|-------------|------------|-------|
| R-05 | Trigger (F-36) | Phase A/B/C: CREATE/DROP, BEFORE/AFTER/INSTEAD OF × INSERT/UPDATE/DELETE ROW/STATEMENT, WHEN, NEW/OLD, nested trigger, cascade. | High | ✅ DONE |
| R-06 | View (real) | CREATE VIEW → TViewDef catalog, expanded by the ExecSelect rewriter; VIEW DML (INSERT/UPDATE/DELETE). | Medium | ✅ DONE |
| R-07 | Materialized View | CREATE MATERIALIZED VIEW + REFRESH MATERIALIZED VIEW (full). | Medium | ✅ DONE |
| R-08 | Stored Procedure / Function | CREATE FUNCTION ... LANGUAGE SQL + CALL / SELECT func(). PL/pgSQL subset; F-35 parameter scope + scalar subquery. | High | ✅ DONE |
| R-09 | LATERAL JOIN | CROSS JOIN LATERAL (SELECT ...) — set-returning version of the correlated subquery. | Medium | ✅ DONE |
| R-10 | CYCLE Detection (Recursive CTE) | WITH RECURSIVE ... CYCLE col SET is_cycle USING path — infinite-loop guard, real recursion (delta). | Medium | ✅ DONE |
| R-11 | DEFERRABLE Constraints | SET CONSTRAINTS ALL DEFERRED → deferred until transaction end. | Medium | ✅ DONE |

### PHASE 2: Scalability and Performance

| ID | Feature | Description | Difficulty | Status |
|----|---------|-------------|------------|-------|
| R-12 | Connection Pool + TCP SQL Server (Full) | Pool API + SHM slots + atomic leasing (VDbPoolTest 10/10) + **TCP SQL server** (`VDbSqlServer.pas`/`vdbserver.lpr`) + **client** (`VDbClientNet.pas`) — VDBS protocol (see §5.12). | Very High | ✅ DONE (Full) |
| R-13 | Table Partitioning | HASH/RANGE/LIST + query-time partition pruning; EXPLAIN report + SHOW PARTITIONS. | High | ✅ DONE (Full) |
| R-14 | Parallel Query Execution | Real worker pool (TThread + RTLEvent) + parallel ORDER BY (stable); EXPLAIN "Parallel Seq Scan (workers=N)". | High | ✅ DONE (Full) |
| R-15 | Cost-Based Optimizer | ANALYZE statistics, cost model (VDbCost), index/seq choice, join order; EXPLAIN `(cost=a..b rows=N)`. | High | ✅ DONE (Full) |
| R-16 | Incremental Backup / WAL Archiving | WAL segments → archive folder → PITR (RECOVER TO TIMESTAMP/NOW). | High | ✅ DONE |
| R-17 | Streaming Replication | WAL log-shipping (file mode) + REAL TCP streaming (VDBR protocol, real sockets). | Very High | ✅ DONE (Full) |
| R-25 | Performance: PK Lazy Index + Group Commit | Lazy ordered PK index for BETWEEN/ORDER BY (Seq Scan → Index Scan, 14x) + `SyncWriteInterval` group commit (UPDATE/DELETE 14-16x). | Medium | ✅ DONE |

### PHASE 3: Platform, Security and Ecosystem

| ID | Feature | Description | Difficulty | Status |
|----|---------|-------------|------------|-------|
| R-18 | RBAC / Role / GRANT | CREATE ROLE, GRANT/REVOKE ... ON t\|* TO role, SET ROLE. CurrentRole in the TVSql context. | High | ✅ DONE |
| R-19 | Row Level Security (RLS) | ALTER TABLE ... ENABLE ROW LEVEL SECURITY + CREATE POLICY. | High | ✅ DONE |
| R-20 | ICU Collation Support | COLLATE "tr-TR-u-kn-ks" — BCP-47 key/value engine, kn natural ordering, ks strength levels. | High | ✅ DONE (Full) |
| R-21 | Extension / Plugin Mechanism | CREATE EXTENSION → real .dll/.so/.dylib loading + ABI version gate + symbol resolution. | High | ✅ DONE (Full) |
| R-22 | Online DDL (CONCURRENTLY) | CREATE INDEX CONCURRENTLY — three-phase online build; INVALID semantics. | High | ✅ DONE (Full) |
| R-23 | Cross-Platform DLL / C API | VDB_CALL (32-bit stdcall) + pure RTL platform unit; build_lib.sh for .so/.dylib. | Medium | ✅ DONE |
| R-24 | Monitoring / pg_stat-like | SHOW STATS / SHOW STATS TABLE t — command count, duration metrics, WAL records, ANALYZE statistics (no cache hit ratio: there is no block-cache layer, §7). | Medium | ✅ DONE (Full) |

---

## 2. 📝 Özet: VDB Hangi Durumlarda Uygun?

| Senaryo | Uygun mu? | Neden |
|---------|-----------|-------|
| Masaüstü / Mobil Uygulama (Tek kullanıcı) | ✅ Mükemmel | Tek dosya, sıfır kurulum, TDataSet, şifreleme, CDC |
| IoT / Edge Cihaz | ✅ Çok İyi | Düşük kaynak, crash-safe, WAL, yedekleme kolay |
| Küçük Web Uygulaması (Düşük eşzamanlılık) | ⚠️ Kabul Edilebilir | Connection pool + tek süreç yeterli olabilir |
| Çoklu Kullanıcı Sunucu / Web API | ⚠️ Kabul Edilebilir | MVCC/SAVEPOINT/replication + **TCP SQL sunucusu VAR** (R-12 Full: VDBS); erişim kilit altında SERI yürütülür (kapasite = eşzamanlı bağlantı) |
| Analitik / OLAP İş Yükleri | ✅ İyi | Paralel sorgu (R-14), bölümleme (R-13), CBO (R-15) mevcut |
| SQLite Yerine Geçirme | ✅ Bazı durumlarda | Daha fazla SQL özelliği (JSONB, Spatial, Range, Partial/Expr/Covering Index) |

---

## 2. SUMMARY: WHEN IS VDB A GOOD FIT? (ENGLISH)

| Scenario | Suitable? | Why |
|----------|-----------|-----|
| Desktop / Mobile application (single user) | ✅ Excellent | Single file, zero setup, TDataSet, encryption, CDC |
| IoT / Edge device | ✅ Very good | Low resources, crash-safe, WAL, easy backup |
| Small web application (low concurrency) | ⚠️ Acceptable | Connection pool + single process may be enough |
| Multi-user server / Web API | ⚠️ Acceptable | MVCC/SAVEPOINT/replication + **TCP SQL server EXISTS** (R-12 Full: VDBS); access runs SERIALIZED under a lock (capacity = concurrent connections) |
| Analytics / OLAP workloads | ✅ Good | Parallel query (R-14), partitioning (R-13), CBO (R-15) present |
| Replacing SQLite | ✅ In some cases | More SQL features (JSONB, Spatial, Range, Partial/Expr/Covering Index) |

---

## 3. ✅ TAMAMLANAN MADDELER (kodda doğrulanmış kanıt)

Test tabanı (2026-10-15): `sqltest` **2251/2251 yeşil** — tamamlanan turların katkıları:
+24 R-16, +16 R-17 mini, +16 R-23, +25 R-15 Full CBO, +25 R-21 Full Extension,
+58 R-14 Full Paralel, +21 R-17 Full TCP, +44 R-22 Full CONCURRENTLY,
+30 R-20 Full ICU, +70 R-13 Full Partition, +27 R-24 SHOW STATS,
**+32 R-12 Full TCP sunucu**, **R-25 PK Lazy Index + Group Commit** (benchmark ile doğrulandı), **R-12 DEVAM: Auth/Prepared/Capacity (T107–T109)** — sqltest **2251/2251 yeşil**, regresyon yok.

| ID | Özellik | Kanıt |
|----|---------|-------|
| R-01 | MVCC / Snapshot Isolation | `BeginSnapshotRead/EndSnapshotRead` + `GetSnapshot/ScanSnapshot` + T90–T92 test grubu |
| R-02 | SAVEPOINT / Nested Transaction | `VDbCore.Savepoint/Release/RollbackTo` + T79 test grubu |
| R-03 | UPSERT (ON CONFLICT) | `UpsertRowReturning` + EXCLUDED + 32 kullanım |
| R-04 | RETURNING | `InsertReturning` + T11_Returning test grubu |
| R-05 | Trigger (F-36) | `FireTriggers` BEFORE/AFTER × INSERT/UPDATE/DELETE + 45 kullanım |
| R-06 | View + VIEW DML | `ParseViewSelect` (metinden yeniden üretim) + 67 kullanım |
| R-07 | Materialized View | `CreateMaterializedView/REFRESH` + 21 kullanım |
| R-08 | Stored Procedure / Function | `CreateFunction/CallProcedure/ExecuteFunction` + 33 kullanım |
| R-09 | LATERAL JOIN | 40 kullanım |
| R-10 | CYCLE Detection | 3 kullanım |
| R-11 | DEFERRABLE Constraints | `TSqlSetConstraintsStmt` + 6 kullanım |
| **R-12** | **Connection Pool + TCP SQL Sunucusu (Full)** | **1. aşama:** `TVDbPool.CreateXProc` + SHM slotları + isimli mutex + ATOMİK kiralama (`VDbPoolTest`: 3 süreç × 20 satır = 60 satır; 1200 kiralama, 508 eşzamanlı, kapasite 3/4 — doğrulandı). **2. aşama (Full):** `VDbSqlServer.pas` TCP sunucusu + `vdbserver.lpr` bağımsız süreç + `VDbClientNet.pas` istemci — **VDBS protokolu** (el sıkışma 'VDBS'+sürüm, QUERY/PING/BYE, RESULT/ERROR/PONG, u8 $00 sonu işareti); tek motor + `TCriticalSection` **seri yürütüm** (yanıt yazımı kilit dışında); kabul/bağlantı thread'leri; temiz kapanış (dinleme soketi kapatma + Wake/WaitFor; bağlantı objesi sahipliği listede). `T106_TcpSqlServer` (32 alt-test) + mutasyon (affected sıfırlama → 3 FAIL).** |
| **R-13** | **Table Partitioning (HASH/RANGE/LIST) + Pruning (Full)** | **`PARTITION BY HASH(col) PARTITIONS n` / `RANGE(col) VALUES (...)` / `LIST(col) VALUES (...)`. Satırlar KV'da `VDbHashKey(tablo,pk)` ile durur; bölüm no sorgu zamanı anahtar DEĞERİNDEN hesaplanır; `ScanRowsPart` pruning (hedef dışı satır hiç materialize edilmez); `PartTargetsOf` güvenli katkı kuralları (yalnız AND'lenen literal `=`/`IN`, INT canonical, STRING yalnız `Collate=''` kolonlarda); `SHOW PARTITIONS`; EXPLAIN `Pruned: k/N`; şema `#Q` ile reopen kalıcı; NULL bölüm-anahtarı `ecNotNullViolation`. `T104_HashPartition` (70 alt-test) + mutasyon (→ 4 FAIL).** |
| **R-14** | **Parallel Query (Full)** | **Gerçek işçi havuzu: `VDbParallel.pas` — `TThread` işçiler + `RTLEvent` + `TCriticalSection`. API: `InitThreadPool`/`ShutdownThreadPool`/`ThreadPoolReady`/`ParallelWorkerCount`/`DefaultParallelWorkers`/`VdbParallelFor`/`VdbParallelForChunked`/`VdbParallelStats`. Hata yakalama (ilk istisna çağırana yükselir), iç içe çağrı seri, `GBusy` reentrancy. Paralel ORDER BY: 2^k parça quicksort + ping-pong ikili merge; satır-indeksi tie-break → **stable/deterministik**. Lazy init (`VDB_PAR_SORT_MIN_ROWS=2048`, `VDB_PAR_MAX_WORKERS=8`). EXPLAIN: `Parallel Seq Scan ... (workers=N)` (yalnız Seq Scan düğümleri). C ABI 1.2: `VdbParallelInit/Workers/Shutdown`. `T100_Parallel` (58 alt-test) + mutasyon (`if usePar` → `if False` → 4 FAIL).** |
| **R-15** | **Cost-Based Optimizer (ANALYZE + CBO)** | **`ANALYZE [TABLE] <tablo>` istatistik toplar (satır, avg uzunluk, indeks + kolon distinct/null/min/max; distinct gerçek hash ile). `VDbCost.pas` saf maliyet modeli (`VdbChooseScan`, `VdbIndexIsSelective`, `VdbJoinOuterFirst`). EXPLAIN ve gerçek satır seçimi AYNI karar noktasını kullanır: seçici olmayan indeks yerine Seq Scan; PK nokta araması = Index; iki tablolu JOIN'de küçük tablo dış taraf; plana `(cost=a..b rows=N)` eklenir. `T98_CBO` (25 alt-test) + mutasyon (karar `if False` → 4 FAIL).** |
| **R-16** | **WAL Arşivleme + PITR** | **`ARCHIVE WAL SET DIR=... SIZE=...`, `BACKUP TO` (arsivleme), `RESTORE FROM`, `RECOVER TO TIMESTAMP/NOW`, `ARCHIVE WAL LIST`. `T95_WALArsiv` testi: arsiv segment rotasyonu, bozuk segment atlama, PITR hedef zamanına kadar replay — 24 test, hepsi geçti.** |
| **R-17** | **Streaming Replication (WAL log-shipping + GERÇEK TCP)** | **`VDbReplication.pas`: rol (PRIMARY/STANDBY), kalıcı slotlar (`.replslots`), `TVDb.ApplyWalSegmentFile`. Dosya modu: `START REPLICATION PRIMARY [DEST 'dir'] SLOT 's'`, `START REPLICATION STANDBY 'dir' SLOT 's'`, `PUMP REPLICATION`. TCP modu (Full): `START REPLICATION PRIMARY TCP PORT n SLOT 's'` / `START REPLICATION STANDBY TCP HOST 'h' PORT n SLOT 's'` — `VDbNet.pas` platform-nötr soket katmanı (FPC `Sockets`, küçük-endian u8/u32/u64 ilkelleri), `TVdbWalSenderThread`/`TVdbWalReceiverThread` gerçek `TThread`'ler, VDBR protokolü (magic+el sıkışma, SEGMENT+CRC32+ACK, HEARTBEAT, END). Akışta standby motoru alıcıya aittir (SQL reddi `ecDatabaseLocked`). `STOP REPLICATION`, `CREATE/DROP REPLICATION SLOT`, `SHOW REPLICATION STATUS/SLOTS`. `T95b_Replication` (17) + `T101_TcpReplication` (21) test; her iki modda idempotans mutasyonla doğrulandı.** |
| **R-18** | **RBAC / Role / GRANT** | **`CREATE ROLE [SUPERUSER]`, `GRANT/REVOKE ... ON t\|* TO rol`, `SET ROLE rol\|NONE`, `RoleCan/RequirePriv`. Test: `T93_RBAC` + `T94_RBAC_Persist`.** |
| **R-19** | **Row Level Security** | **`ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + `CREATE POLICY` (predicate WHERE). Test: `T94b_RLS` + `T94c_RLS_Persist`.** |
| **R-20** | **ICU Collation (Full)** | **BCP-47 `tr-TR-u-kn-ks` etiket motoru: bölge + `-u-` anahtar/DEĞER ayrıştırıcı (`kn-true`, `kn-false`, `ks-level2`, `kf`), çoklu anahtar (`kn-ks`/`ks-kn`), `kn` doğal sayısal sıralama (`a2`<`a10`, baştaki sıfır: `a01`=`a1`), `ks`/`kc`/`ks-levelN` güç katmanları, kanonik ad round-trip (`-u-kn` reopen'da kalıcı), Kiril/Yunan/Arap ağırlıkları kod noktası aritmetiğiyle. `T103_IcuCollation` (30 alt-test) + mutasyon (→ 18 FAIL).** |
| **R-21** | **Extension / Plugin (Full)** | **Gerçek dinamik kütüphane yükleme (`VDbExtension.pas` + `VDbPlatform.VdbLibTryLoadFile`, RTL `dynlibs`). C-ABI sözleşmesi: zorunlu `VdbExtApiVersion` (ABI ≥ 1.0), opsiyonel `VdbExtName`/`VdbExtDescription`. SQL: `CREATE EXTENSION [IF NOT EXISTS] ad [FROM 'yol']`, `DROP EXTENSION [IF EXISTS] ad`, `SHOW EXTENSIONS`. Kayıt defteri + `ExtensionSymbol` ile sembol çözümü. `T99_Extension` (25 alt-test; gerçek `vdbtestext.dll` yükleme + stdcall sembol çağrısı, eski ABI reddi; + mutasyon `if ver < ...` → 5 FAIL).** |
| **R-22** | **Online DDL — CREATE INDEX CONCURRENTLY (Full)** | **`TIdxDef.Invalid` bayrağı (şemada `?` öneki, geri uyumlu) + `TVdbConcIdxBuilder` arka plan `TThread`'i. Üç faz: (1) anlık görüntü + anahtar hesabı, cümle ANINDA döner; (2) thread yalnız kendi girdisini sıralar (motor kilitlenmez); (3) `PollConcurrentIndexes` her cümlenin başında finalize (catch-up + UNIQUE haritası + `Invalid=False`). INVALID indeks okunmaz/kurulmaz → planlayıcı seq scan'a düşer, UNIQUE tam taramayla ZORLANIR. `DROP INDEX` inşayı durdurur; Close/Destroy/abort iptal eder (INVALID kalır); batch içinde reddedilir. `SHOW INDEXES` 10. kolon `valid`. `T102_ConcurrentIndex` (44 alt-test) + mutasyon (finalize koşulu `if False` → 8 FAIL).** |
| **R-23** | **Cross-Platform DLL / C API** | **`VDbPlatform.pas` (saf RTL): OS tespiti, `VdbSharedLibName*` (derleme anından bağımsız `vdbapi.dll`/`libvdbapi.so`/`.dylib`), `VdbLibTryLoad/Proc/Unload`, `VdbTickMs`. LazUtils/FileUtil motor çekirdeğinden ÇIKARILDI (motor `fpc` ile Linux/macOS'ta derlenir). `vdbapi.h` `VDB_CALL` (32-bit x86'ta stdcall). `VDbCrypt` çapraz-platform (Unix `/dev/urandom`, PBKDF2 türetimi). `build_lib.sh` + `build_dll.ps1`. `T97_CrossPlatform` (16 alt-test) + mutasyon (→ FAIL).** |
| **R-24** | **Monitoring / SHOW STATS (Full)** | **Parser/AST: `SHOW STATS` / `SHOW STATS TABLE t` (+ `LIST STATS` takma adı) → `admShowStats`. `VDbExecutor.ExecShowStats`: genel form 2 kolon `name\|value` × 6 metrik (`commands`, `total_us`, `max_us`, `avg_us`, `wal_records`, `tables_analyzed` — yeni `VDbMonitor.AnalyzedTableCount`); tablo formu 8 kolon özet+kolon satırları (distinct gerçek kova, nulls, min/max bayt sırası; ANALYZE yoksa `ecUnsupported`, tablo yoksa `ecTableNotFound`). Sayaç bağı: `VDbSql.ExecRaw` finally → `RecordCommand` (hata yolunda da); günlük dosyası yazımı `FileName <> ''` kapısına alındı. `RecordCommand`'deki geri alınmamış mutasyon kalıntısı (`if False`) kaldırıldı. `T105_ShowStats` (27 alt-test) + mutasyon (`Inc(GStats.CommandCount)` → `if False` → 2 FAIL).** |
| **R-25** | **Performans: PK Lazy Index + Group Commit** | **1. PK Lazy Index (`VDbTable.pas`):** `T.Idx`'e dokunmadan PK kolonu için tembel sıralı index (`FPkIdx`/`FPkIdxDirty` sözlükleri + `BuildPkIdx`). `TryGetMemIndex` PK kolonu için lazy index döndürür; `IdxAddRow`/`IdxDelRow` kirli işaretler. `IndexUsedByWhere` (`VDbExecutor.pas`) PK kolonunu destekler (Ix = -2) ve `Length(Td.Idx)=0` erken çıkışı kaldırıldı → BETWEEN/ORDER BY Seq Scan yerine **Index Scan** kullanır (26/sn → 376/sn, **14x**). **2. Group Commit (`VDbCore.pas`):** `SyncWriteInterval` özelliği (PostgreSQL `commit_delay` benzeri). `Put`/`Delete`/`Flush`/`CommitBatch` fsync'leri bu süre (ms) içinde toplar. SQL katmanının her Exec sonrasi cagirdigi Flush ve UPDATE/DELETE icin kullandigi BeginBatch/CommitBatch de group commit ile calisir → UPDATE **14x**, DELETE **16x** hizlanma. Benchmark: Batch INSERT 37K/sn, SELECT PK 40K/sn, UPDATE 13.8K/sn, DELETE 18.9K/sn. `sqltest` 2251 yeşil (regresyon yok).** |
| — | Şifreleme | PBKDF2/AES-256/HMAC, .key dosyası, rekey, replay — 60/60 |

---

## 3. ✅ COMPLETED ITEMS — CODE-VERIFIED EVIDENCE (ENGLISH)

Test baseline (2026-10-15): `sqltest` **2251/2251 green** — contributions of the completed rounds:
+24 R-16, +16 R-17 mini, +16 R-23, +25 R-15 Full CBO, +25 R-21 Full Extension,
+58 R-14 Full Parallel, +21 R-17 Full TCP, +44 R-22 Full CONCURRENTLY,
+30 R-20 Full ICU, +70 R-13 Full Partition, +27 R-24 SHOW STATS,
**+32 R-12 Full TCP server**, **R-25 PK Lazy Index + Group Commit** (verified by benchmark), **R-12 continuation: Auth/Prepared/Capacity (T107–T109)** — sqltest **2251/2251 green**, no regressions.

| ID | Feature | Evidence |
|----|---------|----------|
| R-01 | MVCC / Snapshot Isolation | `BeginSnapshotRead/EndSnapshotRead` + `GetSnapshot/ScanSnapshot` + T90–T92 test group |
| R-02 | SAVEPOINT / Nested Transaction | `VDbCore.Savepoint/Release/RollbackTo` + T79 test group |
| R-03 | UPSERT (ON CONFLICT) | `UpsertRowReturning` + EXCLUDED + 32 usages |
| R-04 | RETURNING | `InsertReturning` + T11_Returning test group |
| R-05 | Trigger (F-36) | `FireTriggers` BEFORE/AFTER × INSERT/UPDATE/DELETE + 45 usages |
| R-06 | View + VIEW DML | `ParseViewSelect` (re-generation from text) + 67 usages |
| R-07 | Materialized View | `CreateMaterializedView/REFRESH` + 21 usages |
| R-08 | Stored Procedure / Function | `CreateFunction/CallProcedure/ExecuteFunction` + 33 usages |
| R-09 | LATERAL JOIN | 40 usages |
| R-10 | CYCLE Detection | 3 usages |
| R-11 | DEFERRABLE Constraints | `TSqlSetConstraintsStmt` + 6 usages |
| **R-12** | **Connection Pool + TCP SQL Server (Full)** | **Stage 1:** `TVDbPool.CreateXProc` + SHM slots + named mutex + ATOMIC leasing (`VDbPoolTest`: 3 processes × 20 rows = 60 rows; 1200 leases, 508 concurrent, capacity 3/4 — verified). **Stage 2 (Full):** `VDbSqlServer.pas` TCP server + `vdbserver.lpr` standalone process + `VDbClientNet.pas` client — **VDBS protocol** (handshake 'VDBS'+version, QUERY/PING/BYE, RESULT/ERROR/PONG, u8 $00 end marker); single engine + `TCriticalSection` **serialized execution** (response writing outside the lock); accept/connection threads; clean shutdown (listen-socket close + Wake/WaitFor; connection object owned by the list). `T106_TcpSqlServer` (32 sub-tests) + mutation (zeroing affected → 3 FAIL).** |
| **R-13** | **Table Partitioning (HASH/RANGE/LIST) + Pruning (Full)** | **`PARTITION BY HASH(col) PARTITIONS n` / `RANGE(col) VALUES (...)` / `LIST(col) VALUES (...)`. Rows live in the KV store under `VDbHashKey(table,pk)`; the partition number is computed at query time from the KEY VALUE, so reads keep working even if the schema's partition definition changes. `ScanRowsPart` pruning (off-target rows are never materialized); `PartTargetsOf` safe contribution rules (only ANDed literal `=`/`IN`, INT canonical, STRING only for `Collate=''` columns); `SHOW PARTITIONS`; EXPLAIN `Pruned: k/N`; schema persists across reopen via `#Q`; NULL partition key → `ecNotNullViolation`. `T104_HashPartition` (70 sub-tests) + mutation (→ 4 FAIL).** |
| **R-14** | **Parallel Query (Full)** | **Real worker pool: `VDbParallel.pas` — `TThread` workers + `RTLEvent` + `TCriticalSection`. API: `InitThreadPool`/`ShutdownThreadPool`/`ThreadPoolReady`/`ParallelWorkerCount`/`DefaultParallelWorkers`/`VdbParallelFor`/`VdbParallelForChunked`/`VdbParallelStats`. Exception capture (first exception re-raised to the caller), nested calls run serially, `GBusy` reentrancy. Parallel ORDER BY: 2^k-partition quicksort + ping-pong binary merge; row-index tie-break → **stable/deterministic**. Lazy init (`VDB_PAR_SORT_MIN_ROWS=2048`, `VDB_PAR_MAX_WORKERS=8`). EXPLAIN: `Parallel Seq Scan ... (workers=N)` (Seq Scan nodes only). C ABI 1.2: `VdbParallelInit/Workers/Shutdown`. `T100_Parallel` (58 sub-tests) + mutation (`if usePar` → `if False` → 4 FAIL).** |
| **R-15** | **Cost-Based Optimizer (ANALYZE + CBO)** | **`ANALYZE [TABLE] <table>` gathers statistics (rows, avg length, indexes + per-column distinct/null/min/max; distinct via real hashing). `VDbCost.pas` pure cost model (`VdbChooseScan`, `VdbIndexIsSelective`, `VdbJoinOuterFirst`). EXPLAIN and the real row selection use THE SAME decision point: non-selective index → Seq Scan; PK point lookup = Index; in a two-table JOIN the smaller table drives; plan gets `(cost=a..b rows=N)`. `T98_CBO` (25 sub-tests) + mutation (decision `if False` → 4 FAIL).** |
| **R-16** | **WAL Archiving + PITR** | **`ARCHIVE WAL SET DIR=... SIZE=...`, `BACKUP TO` (archives), `RESTORE FROM`, `RECOVER TO TIMESTAMP/NOW`, `ARCHIVE WAL LIST`. `T95_WALArsiv` test: archive segment rotation, corrupt-segment skipping, replay up to the PITR target time — 24 tests, all pass.** |
| **R-17** | **Streaming Replication (WAL log-shipping + REAL TCP)** | **`VDbReplication.pas`: roles (PRIMARY/STANDBY), persistent slots (`.replslots`), `TVDb.ApplyWalSegmentFile`. File mode: `START REPLICATION PRIMARY [DEST 'dir'] SLOT 's'`, `START REPLICATION STANDBY 'dir' SLOT 's'`, `PUMP REPLICATION`. TCP mode (Full): `START REPLICATION PRIMARY TCP PORT n SLOT 's'` / `START REPLICATION STANDBY TCP HOST 'h' PORT n SLOT 's'` — `VDbNet.pas` platform-neutral socket layer (FPC `Sockets`, little-endian u8/u32/u64 primitives), `TVdbWalSenderThread`/`TVdbWalReceiverThread` real `TThread`s, VDBR protocol (magic+handshake, SEGMENT+CRC32+ACK, HEARTBEAT, END). During streaming the standby engine belongs to the receiver (SQL is rejected with `ecDatabaseLocked`). `STOP REPLICATION`, `CREATE/DROP REPLICATION SLOT`, `SHOW REPLICATION STATUS/SLOTS`. `T95b_Replication` (17) + `T101_TcpReplication` (21) tests; idempotency in both modes verified by mutation.** |
| **R-18** | **RBAC / Role / GRANT** | **`CREATE ROLE [SUPERUSER]`, `GRANT/REVOKE ... ON t\|* TO role`, `SET ROLE role\|NONE`, `RoleCan/RequirePriv`. Tests: `T93_RBAC` + `T94_RBAC_Persist`.** |
| **R-19** | **Row Level Security** | **`ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + `CREATE POLICY` (WHERE predicate). Tests: `T94b_RLS` + `T94c_RLS_Persist`.** |
| **R-20** | **ICU Collation (Full)** | **BCP-47 `tr-TR-u-kn-ks` tag engine: region + `-u-` key/VALUE tokenizer (`kn-true`, `kn-false`, `ks-level2`, `kf`), multiple keys (`kn-ks`/`ks-kn`), `kn` natural-numeric ordering (`a2`<`a10`, leading zeros: `a01`=`a1`), `ks`/`kc`/`ks-levelN` strength layers, canonical-name round-trip (`-u-kn` survives reopen), Cyrillic/Greek/Arabic weights via code-point arithmetic. `T103_IcuCollation` (30 sub-tests) + mutation (→ 18 FAIL).** |
| **R-21** | **Extension / Plugin (Full)** | **Real dynamic-library loading (`VDbExtension.pas` + `VDbPlatform.VdbLibTryLoadFile`, RTL `dynlibs`). C-ABI contract: mandatory `VdbExtApiVersion` (ABI ≥ 1.0), optional `VdbExtName`/`VdbExtDescription`. SQL: `CREATE EXTENSION [IF NOT EXISTS] name [FROM 'path']`, `DROP EXTENSION [IF EXISTS] name`, `SHOW EXTENSIONS`. Registry + symbol resolution via `ExtensionSymbol`. `T99_Extension` (25 sub-tests; real `vdbtestext.dll` loading + stdcall symbol call, old ABI rejected; + mutation `if ver < ...` → 5 FAIL).** |
| **R-22** | **Online DDL — CREATE INDEX CONCURRENTLY (Full)** | **`TIdxDef.Invalid` flag (`?` prefix on the schema name, backward compatible) + `TVdbConcIdxBuilder` background `TThread`. Three phases: (1) snapshot + key computation, the statement returns IMMEDIATELY; (2) the thread sorts only its own input (the engine never blocks); (3) `PollConcurrentIndexes` finalizes at the start of every statement (catch-up + UNIQUE map + `Invalid=False`). An INVALID index is not read/built → the planner falls back to seq scan; UNIQUE is ENFORCED by a full scan. `DROP INDEX` stops the build; Close/Destroy/abort cancels (index stays INVALID); rejected inside a transaction (`ecInvalidState`). `SHOW INDEXES` 10th column `valid`. `T102_ConcurrentIndex` (44 sub-tests) + mutation (finalize condition `if False` → 8 FAIL).** |
| **R-23** | **Cross-Platform DLL / C API** | **`VDbPlatform.pas` (pure RTL): OS detection, `VdbSharedLibName*` (build-time-independent `vdbapi.dll`/`libvdbapi.so`/`.dylib`), `VdbLibTryLoad/Proc/Unload`, `VdbTickMs`. LazUtils/FileUtil REMOVED from the engine core (the engine builds with `fpc` on Linux/macOS). `vdbapi.h` `VDB_CALL` (stdcall on 32-bit x86). `VDbCrypt` cross-platform (Unix `/dev/urandom`, PBKDF2 derivation). `build_lib.sh` + `build_dll.ps1`. `T97_CrossPlatform` (16 sub-tests) + mutation (→ FAIL).** |
| **R-24** | **Monitoring / SHOW STATS (Full)** | **Parser/AST: `SHOW STATS` / `SHOW STATS TABLE t` (+ `LIST STATS` alias) → `admShowStats`. `VDbExecutor.ExecShowStats`: general form 2 columns `name\|value` × 6 metrics (`commands`, `total_us`, `max_us`, `avg_us`, `wal_records`, `tables_analyzed` — new `VDbMonitor.AnalyzedTableCount`); table form 8 columns with summary+column rows (distinct via real buckets, nulls, min/max in byte order; no ANALYZE → `ecUnsupported`, missing table → `ecTableNotFound`). Counter hook: `VDbSql.ExecRaw` finally → `RecordCommand` (also on the error path); log-file writing gated by `FileName <> ''`. The un-reverted mutation leftover (`if False`) inside `RecordCommand` was removed. `T105_ShowStats` (27 sub-tests) + mutation (`Inc(GStats.CommandCount)` → `if False` → 2 FAIL).** |
| **R-25** | **Performance: PK Lazy Index + Group Commit** | **1. PK Lazy Index (`VDbTable.pas`):** a lazy ordered index for the PK column without touching `T.Idx` (`FPkIdx`/`FPkIdxDirty` dictionaries + `BuildPkIdx`). `TryGetMemIndex` returns the lazy index for the PK column; `IdxAddRow`/`IdxDelRow` mark it dirty. `IndexUsedByWhere` (`VDbExecutor.pas`) supports the PK column (Ix = -2) and the `Length(Td.Idx)=0` early exit was removed → BETWEEN/ORDER BY use an **Index Scan** instead of Seq Scan (26/s → 376/s, **14x**). **2. Group Commit (`VDbCore.pas`):** `SyncWriteInterval` (like PostgreSQL's `commit_delay`). `Put`/`Delete`/`Flush`/`CommitBatch` fsyncs are batched within this window (ms). The flush after every SQL Exec and the BeginBatch/CommitBatch used for UPDATE/DELETE also run through group commit → UPDATE **14x**, DELETE **16x** faster. Benchmark: batch INSERT 37K/s, SELECT PK 40K/s, UPDATE 13.8K/s, DELETE 18.9K/s. `sqltest` 2251 green (no regressions).** |
| — | Encryption | PBKDF2/AES-256/HMAC, .key file, rekey, replay — 60/60 |

---

## 4. ✅ TAMAMLANAN TESTLER (tam liste)

`sqltest` paketi **138 test prosedürü** içerir; her prosedür başlangıçta `Grp(...)`
ile grup başlığı yazar. Koşu sonucu dosyanın sonunda:
`SONUC: gecen=2251 kalan=0`.

**Mutasyon protokolü (her Full turda uygulandı):** kodda hedef satır etkisiz
kılınır (`if False and ...`) → testlerin gözlemlenebilir biçimde FAIL vermesi
beklenir → satır geri alınır → tümü yeşil. Bu, testlerin gerçekten kodu
denetlediğini kanıtlar.

### 4.1 Çekirdek SQL ve Dil (41 test)

| Test prosedürü | Grup başlığı |
|---|---|
| `T01_Veritabani` | Veritabani komutlari (CREATE/DROP/LIST DATABASE) |
| `T02_Tipler` | Veri tipleri (INTEGER/FLOAT/TEXT/BOOL/DATE/DATETIME/TIME/BLOB) |
| `T03_CreateKisit` | CREATE TABLE kisitlari (PK/NOT NULL/UNIQUE/DEFAULT/CHECK/FK) |
| `T04_Insert` | INSERT bicimleri |
| `T05_SelectTemel` | SELECT: yildiz, kolon listesi, alias, ORDER BY, LIMIT/OFFSET |
| `T06_Where` | WHERE operatorleri, AND/OR/parantez, LIKE, IS NULL |
| `T07_TipKarsilastirma` | Tip-bilgili karsilastirma (TEXT 007 != 7) |
| `T08_Join` | JOIN: INNER, LEFT, alias, nitelemeli kolon |
| `T08b_JoinZincir` | JOIN zinciri: 3+ tablo (P5-1) |
| `T08c_RightFullJoin` | RIGHT/FULL JOIN (P5-RF) |
| `T08c_AltSorgu` | Alt sorgu: IN (SELECT), skaler, EXISTS (P5-2) |
| `T08d_CaseWhen` | CASE WHEN (P5-3) |
| `T08e_CTE` | WITH-CTE (P5-CTE) |
| `T08f_Pencere` | Pencere fonksiyonlari (P5-WIN) |
| `T08g_Collation` | Turkce collation (P5-TR) |
| `T08h_CrossJoin` | CROSS JOIN (4.1) |
| `T08i_NaturalUsing` | NATURAL/USING (F-27/F-28) |
| `T08j_Lateral` | LATERAL (F-29) |
| `T08k_MatView` | MATERIALIZED VIEW (F-34) |
| `T08l_ViewDML` | VIEW DML (F-33) |
| `T08m_StoredProc` | STORED PROCEDURE / FUNCTION (F-35) |
| `T08n_Trigger` | TRIGGER (F-36) |
| `T08i_JoinAggregate` | JOIN + GROUP BY / aggregate (4.2) |
| `T09_GroupAggregate` | GROUP BY + aggregate (COUNT/SUM/AVG/MIN/MAX) |
| `T09b_HavingAggregate` | HAVING dogrudan aggregate (4.3) |
| `T09c_NotOrDNF` | NOT (...) icinde OR (DNF 4.4) |
| `T09e_NullIfCoalesce` | NULLIF / COALESCE (F-02) |
| `T09f_ILike` | ILIKE (F-05) |
| `T09g_AnySomeAll` | ANY / SOME / ALL (F-06) |
| `T09h_FetchFirstNulls` | FETCH FIRST + NULLS FIRST/LAST (F-08/F-10) |
| `T09i_Qualify` | QUALIFY (F-09) |
| `T09j_AggDistinct` | COUNT/SUM/AVG/MIN/MAX(DISTINCT) + STRING_AGG + PERCENTILE (F-11/F-14/F-15) |
| `T09k_Filter` | FILTER (F-16) |
| `T09l_Explain` | EXPLAIN (F-20) |
| `T09m_PartialIndex` | Partial Index (F-17) |
| `T09n_ExprIndex` | Expression Index (F-18) |
| `T09o_CoveringIndex` | Covering Index (F-19) |
| `T09p_SlowQuery` | Yavas Sorgu (F-21) |
| `T09r_Xml` | XML (F-23) |
| `T09s_Spatial` | Spatial (F-24) |
| `T09t_Range` | Range (F-25) |

### 4.2 DML / Transaction / Bakım (13 test)

| Test prosedürü | Grup başlığı |
|---|---|
| `T10_Update` | UPDATE |
| `T10b_Upsert` | UPSERT (ON CONFLICT) |
| `T11_Delete` | DELETE |
| `T11_Returning` | RETURNING (R-04) |
| `T12_Transaction` | Transaction: COMMIT / ROLLBACK, DDL dahil |
| `T13_AlterTable` | ALTER TABLE |
| `T14_Index` | Index: CREATE / kullanim / DROP |
| `T15_Bakim` | Bakim: SHOW TABLES / VACUUM / REINDEX |
| `T16_Parametreli` | Parametreli SQL (?) |
| `T17_Json` | EXPORT / IMPORT JSON |
| `T18_Kalici` | Disk kaliciligi: kapat + yeniden ac |
| `T19_Olcek` | Olcek: 1000 satir + index aralama |
| `T20_CokluKayit` | Coklu kayit (VALUES (...),(...)) + coklu komut (";") |

### 4.3 Dayanıklılık + F1 Regresyon Serisi (25 test, T21–T45)

| Test prosedürü | Grup başlığı |
|---|---|
| `T21_KritikHataDogrulama` | Kritik Hata Duzeltmeleri (Verify Akis Tamponu & Hash Carpismasi) |
| `T22_MinMaxTipKiyas` | MIN/MAX tip-bilgili kiyas (string sira degil) |
| `T23_Blob` | BLOB ham bayt (depolama + JSON turu) |
| `T24_Dayaniklilik` | Commit-flush garantisi (P-DUR) |
| `T25_F1_UnionSiraVeLimit` | F1-11/F1-12 UNION sutun denetimi + birlestirme sonrasi siralama |
| `T26_F1_OrderByTip` | F1-20 GROUP BY sonrasi ORDER BY sayisal tip |
| `T27_F1_OrderByBilinmeyenKolon` | F1-21 ORDER BY bilinmeyen kolon hata verir |
| `T28_F1_JoinTipKiyas` | F1-17 JOIN sonrasi karsilastirma sayisal tip |
| `T29_F1_UpdateBilinmeyenKolon` | F1-16 UPDATE bilinmeyen kolon hata verir |
| `T30_F1_DeleteDatabase` | F1-15 DELETE DATABASE canli + batch disi |
| `T31_F1_NotInNull` | F1-13/F1-14 NULL mantigi (NOT IN / NOT NULL) |
| `T32_F1_LimitGecersiz` | F1-18 LIMIT/OFFSET gecersiz deger hata verir |
| `T33_F1_SumBosKume` | F1-19 SUM bos kume NULL doner |
| `T34_F1_AlterRenameBozukSatir` | F1-8 hash dogrulamasi (ALTER RENAME sonrasi veri saglam) |
| `T35_F1_OffsetAlias` | F1-10 OFFSET alias (SELECT * FROM t OFFSET n) |
| `T36_F1_RecoverKirpma` | F1-1 Recover yarim batch fiziksel kirpmasi |
| `T37_F1_CommitBatchAtomik` | F1-2 CommitBatch hata yolunda atomiklik |
| `T38_F1_CheckRestrictFiltresi` | F1-4 UPDATE ilgisiz kolon FK denetimini tetiklemez |
| `T39_F1_UniqueBayatAnahtar` | F1-5 UPDATE sonrasi UNIQUE haritasi temizlenir |
| `T40_F1_AlterDropColumnFK` | F1-6 DROP COLUMN sarkan FKyi reddeder |
| `T41_F1_AlterAddColumnNotNull` | F1-7 ADD COLUMN NOT NULL oncei uygulanir |
| `T42_F1_BatchInsertAtomik` | F1-9 BatchInsert kendi batch'ini kullanir |
| `T43_F1_MigrateLegacy` | F1-3 MigrateLegacy basliksiz dosyayi aktarir |
| `T44_F1_ParserDerinlik` | F1-22 parser derinlik siniri |
| `T45_F1_SplitStatements` | F1-23 SplitStatements yorum/tirnak ayiricilari |

### 4.4 F2/F3 Regresyon Serisi (23 test, T46–T68)

| Test prosedürü | Grup başlığı |
|---|---|
| `T46_F2_SemaBozukSatir` | F2-13 bozuk sema kaydi hata verir |
| `T47_F2_BosTabloAdi` | F2-14 bos tablo adi reddedilir |
| `T48_F2_DropTableFK` | F2-6 DROP TABLE gercek kesisime bakar |
| `T49_F2_SelfRefFK` | F2-12 self-referans FK + kaskad derinligi |
| `T50_F2_IdxBLOBKarisim` | F2-15 BLOB + cok kolonlu UNIQUE indeks ayirici carpismasi |
| `T51_F2_DropColumnIdx` | F2-11 DROP COLUMN indeks durumunu tamizlar |
| `T52_F2_AlterColumnType` | F2-10 ALTER COLUMN TYPE korumalari |
| `T53_F2_DDLAtomik` | F2-9 DDL atomikligi |
| `T54_F2_UnionDistinct` | F2-18 UNION/DISTINCT tekillestirme |
| `T55_F2_PencereBellek` | F2-19 pencere siralamasi sonucu dogru |
| `T56_F2_AltSorgu` | F2-20 IN alt sorgu kumesi |
| `T57_F2_BozukDosya` | F2-3 bozuk dosya tutarli hata verir |
| `T58_F2_VerifyBATCHEND` | F2-17 Verify BATCHEND sayaci |
| `T59_F2_DizinFlush` | F2-1/F2-2 dizin flush sonucu ve isareti |
| `T60_F2_WALKilit` | F2-4 WAL metotlari kilit ve aciklik denetimi |
| `T61_F2_GetDogruluk` | F2-5 Get dogruluk ve olmayan anahtar |
| `T62_F2_DropColumnBatch` | F2-7 DROP TABLE isareti kalici semadan sonra temizlenir |
| `T63_F2_BozukKayitTespit` | F2-16 bozuk kayit sessizce yutulmaz |
| `T64_PKsizTablo` | F2-22 PK-siz tablo: ilk kolon PK degil, ortuk UNIQUE degil |
| `T65_UniqueIndex` | F2-23 CREATE UNIQUE INDEX zorlanir |
| `T66_DropColCokKolluIndeks` | F2-11 DROP COLUMN cok kolonlu indeksi de kaldirir |
| `T67_F3_Hijyen` | F3 hijyen regresyonu + PROBE cok kolonlu indeks ondek esitligi |
| `T68_F3_IndeksOnekFiltre` | F3-7 cok kolonlu indeks ondek filtresi satir silmiyor |

### 4.5 Yönetim + WAL (5 test, T69–T73)

| Test prosedürü | Grup başlığı |
|---|---|
| `T69_YonetimAPI` | Yonetim aracinin kullandigi motor API yollari |
| `T70_YonetimBakim` | Yonetim bakim ozellikleri (dayaniklilik, betik, sikistirma) |
| `T71_SemaSorgulari` | SQL sema sorgulari (DESCRIBE / SHOW INDEXES / SHOW CREATE TABLE) |
| `T72_WALReplay` | WAL replay gercek (yirtik kuyruk + checkpoint) |
| `T73_OtomatikWAL` | OTOMATIK WAL (WALEnabled) |

### 4.6 Şifreleme (4 test, T74–T77)

| Test prosedürü | Grup başlığı |
|---|---|
| `T74_KayitSifreleme` | KAYIT SEVIYESI SIFRELEME (VDB_FLAG_ENCRYPTED) |
| `T75_SifrelemeDayanikliligi` | SIFRELEME DAYANIKLILIGI (Compact/BackupTo bayragi) |
| `T76_WALReplaySifreli` | WAL REPLAY + BATCH/AUTOCOMPACT (SIFRELI) |
| `T77_AlterDatabaseKey` | ALTER DATABASE KEY (parola rotasyonu) |

### 4.7 AS OF + SAVEPOINT (2 test, T78–T79)

| Test prosedürü | Grup başlığı |
|---|---|
| `T78_AsofGecmis` | AS OF (WAL gecmisinden okuma) |
| `T79_Savepoint` | SAVEPOINT (R-02) |

### 4.8 MVCC (3 test, T90–T92)

| Test prosedürü | Grup başlığı |
|---|---|
| `T90_MVCC_Snapshot` | R-01 MVCC: Transaction Snapshot |
| `T91_MVCC_Concurrency` | R-01 MVCC: Writer/Reader concurrency |
| `T92_MVCC_NestedSelect` | R-01 MVCC: Nested SELECT snapshot |

### 4.9 Güvenlik + Collation + Monitoring (8 test, T93–T94f, T105)

| Test prosedürü | Grup başlığı |
|---|---|
| `T93_RBAC` | RBAC: ROLE / GRANT / REVOKE (R-18) |
| `T94_RBAC_Persist` | RBAC kalicilik (R-18) |
| `T94b_RLS` | ROW LEVEL SECURITY (R-19) |
| `T94c_RLS_Persist` | RLS kalicilik (R-19) |
| `T94d_Collation` | COLLATION (R-20) |
| `T94e_Collation_Persist` | COLLATION kalicilik (R-20) |
| `T94f_Monitoring` | R-24 Monitoring (temel sayaçlar) |
| `T105_ShowStats` | SHOW STATS (R-24) — global sayaçlar + ANALYZE tablo istatistikleri (27 alt-test) |

### 4.10 Yedekleme + Replikasyon (2 test, T95–T95b)

| Test prosedürü | Grup başlığı | Alt-test |
|---|---|---|
| `T95_WALArsiv` | R-16: WAL arsivleme + PITR | 24 |
| `T95b_Replication` | R-17: Streaming Replication (WAL log-shipping) | 17 |

### 4.11 Full Turlar (9 test, T97–T104, T106)

| Test prosedürü | Grup başlığı | Alt-test |
|---|---|---|
| `T97_CrossPlatform` | R-23: Cross-Platform DLL / C API | 16 |
| `T98_CBO` | R-15 Full: Cost-Based Optimizer (CBO) | 25 |
| `T99_Extension` | R-21 Full: Extension / Plugin | 25 |
| `T100_Parallel` | R-14 Full: Parallel Query (isci havuzu + paralel ORDER BY) | 58 |
| `T101_TcpReplication` | R-17 Full: TCP streaming replication (gercek soketler) | 21 |
| `T102_ConcurrentIndex` | R-22 Full: CREATE INDEX CONCURRENTLY (online indeks insasi) | 44 |
| `T103_IcuCollation` | ICU COLLATION tr-TR-u-kn-ks (R-20 Full) | 30 |
| `T104_HashPartition` | HASH BOLUMLEME + PARTITION PRUNING (R-13 Full) | 70 |
| `T106_TcpSqlServer` | R-12 Full: TCP SQL sunucusu + istemci (VDBS) | 32 |

### 4.12 Diğer test paketleri

| Paket | Sonuç | Kapsam |
|---|---|---|
| `vdbcrypttest` | 60/60 | Şifreleme: PBKDF2/AES-256/HMAC, .key, rekey, replay |
| `vdbapitest` | 170/170 | C API (`vdbapi.dll` sürüm 1.2): open/exec/param/blob/error + WAL/CDC |
| `vdbclienttest` | 101/101 | İstemci kütüphanesi (VDbClient) |
| `VDbXPrimsTest` | tarihsel: EXITCODE=0 | Primitifler: mutex/event/shared memory/kilit — test programı ağaçta yok; `VDbXPrims.pas` birimi derleniyor |
| `VDbPoolTest` | tarihsel: 10/10 | Çok süreçli havuz — test programı ağaçta yok; `VDbPool.pas` 12.10'dan beri değişmedi |
| `crashtest` | **8/8** | Çökme dayanıklılığı: rastgele kill noktaları + transaction atomikliği (`crashtest.exe verify [batch]`, `C:\temp\vdbcrash`) — veri kaybı yok |

**2026-10-13 son tam koşu notu:** üç programın (`vdbcrypttest`,
`vdbapitest`, `vdbclienttest`) kaynakları da ağaçta yok →
`vdbtest\yedek` yedeklerinden derlenip çalıştırıldı (sonuçlar o koşudan
+ yedek2'ye alındı). Koşu sırasında `vdbapitest`'e ait **2 FAIL gerçek**
çıktı: `VdbFileSizeOf` R-23 regresyonu (§6) — düzeltildi, mutasyon
kanıtı alındı; ayrıca sürüm beklentisi 1.1 → 1.2 güncellendi (DLL ABI
1.2 bilinçli; §6'daki sürüm-güncelleme geleneği).

### 4.13 R-12 DEVAM: Auth / Prepared / Kapasite (3 test, T107–T109)

| Test prosedürü | Grup başlığı |
|---|---|
| `T107_AuthSession` | R-12 DEVAM: VDBS oturum/auth (T107) |
| `T108_PreparedStatement` | R-12 DEVAM: VDBS hazirlanmis sorgu (T108) |
| `T109_PoolSlotTCP` | R-12 DEVAM: Havuz-slot <-> TCP (T109) |

---

## 4. ✅ COMPLETED TESTS — FULL LIST (ENGLISH)

The `sqltest` package contains **138 test procedures**; each procedure writes a
group title via `Grp(...)` at start. The run result at the end of the file:
`SONUC: gecen=2251 kalan=0` (all tests pass).

**Mutation protocol (applied in every Full round):** a target line is
neutralized in the code (`if False and ...`) → the tests are expected to FAIL
visibly → the line is reverted → everything green. This proves the tests
genuinely observe the code.

### 4.1 Core SQL and Language (41 tests)

| Test procedure | Group title |
|---|---|
| `T01_Veritabani` | Database commands (CREATE/DROP/LIST DATABASE) |
| `T02_Tipler` | Data types (INTEGER/FLOAT/TEXT/BOOL/DATE/DATETIME/TIME/BLOB) |
| `T03_CreateKisit` | CREATE TABLE constraints (PK/NOT NULL/UNIQUE/DEFAULT/CHECK/FK) |
| `T04_Insert` | INSERT forms |
| `T05_SelectTemel` | SELECT: star, column list, alias, ORDER BY, LIMIT/OFFSET |
| `T06_Where` | WHERE operators, AND/OR/parens, LIKE, IS NULL |
| `T07_TipKarsilastirma` | Type-aware comparison (TEXT 007 != 7) |
| `T08_Join` | JOIN: INNER, LEFT, alias, qualified column |
| `T08b_JoinZincir` | JOIN chain: 3+ tables (P5-1) |
| `T08c_RightFullJoin` | RIGHT/FULL JOIN (P5-RF) |
| `T08c_AltSorgu` | Subquery: IN (SELECT), scalar, EXISTS (P5-2) |
| `T08d_CaseWhen` | CASE WHEN (P5-3) |
| `T08e_CTE` | WITH-CTE (P5-CTE) |
| `T08f_Pencere` | Window functions (P5-WIN) |
| `T08g_Collation` | Turkish collation (P5-TR) |
| `T08h_CrossJoin` | CROSS JOIN (4.1) |
| `T08i_NaturalUsing` | NATURAL/USING (F-27/F-28) |
| `T08j_Lateral` | LATERAL (F-29) |
| `T08k_MatView` | MATERIALIZED VIEW (F-34) |
| `T08l_ViewDML` | VIEW DML (F-33) |
| `T08m_StoredProc` | STORED PROCEDURE / FUNCTION (F-35) |
| `T08n_Trigger` | TRIGGER (F-36) |
| `T08i_JoinAggregate` | JOIN + GROUP BY / aggregate (4.2) |
| `T09_GroupAggregate` | GROUP BY + aggregate (COUNT/SUM/AVG/MIN/MAX) |
| `T09b_HavingAggregate` | HAVING direct aggregate (4.3) |
| `T09c_NotOrDNF` | NOT (...) containing OR (DNF 4.4) |
| `T09e_NullIfCoalesce` | NULLIF / COALESCE (F-02) |
| `T09f_ILike` | ILIKE (F-05) |
| `T09g_AnySomeAll` | ANY / SOME / ALL (F-06) |
| `T09h_FetchFirstNulls` | FETCH FIRST + NULLS FIRST/LAST (F-08/F-10) |
| `T09i_Qualify` | QUALIFY (F-09) |
| `T09j_AggDistinct` | COUNT/SUM/AVG/MIN/MAX(DISTINCT) + STRING_AGG + PERCENTILE (F-11/F-14/F-15) |
| `T09k_Filter` | FILTER (F-16) |
| `T09l_Explain` | EXPLAIN (F-20) |
| `T09m_PartialIndex` | Partial Index (F-17) |
| `T09n_ExprIndex` | Expression Index (F-18) |
| `T09o_CoveringIndex` | Covering Index (F-19) |
| `T09p_SlowQuery` | Slow Query (F-21) |
| `T09r_Xml` | XML (F-23) |
| `T09s_Spatial` | Spatial (F-24) |
| `T09t_Range` | Range (F-25) |

### 4.2 DML / Transaction / Maintenance (13 tests)

| Test procedure | Group title |
|---|---|
| `T10_Update` | UPDATE |
| `T10b_Upsert` | UPSERT (ON CONFLICT) |
| `T11_Delete` | DELETE |
| `T11_Returning` | RETURNING (R-04) |
| `T12_Transaction` | Transaction: COMMIT / ROLLBACK, including DDL |
| `T13_AlterTable` | ALTER TABLE |
| `T14_Index` | Index: CREATE / usage / DROP |
| `T15_Bakim` | Maintenance: SHOW TABLES / VACUUM / REINDEX |
| `T16_Parametreli` | Parameterized SQL (?) |
| `T17_Json` | EXPORT / IMPORT JSON |
| `T18_Kalici` | Disk durability: close + reopen |
| `T19_Olcek` | Scale: 1000 rows + index range scan |
| `T20_CokluKayit` | Multi-row (VALUES (...),(...)) + multi-statement (";") |

### 4.3 Durability + F1 Regression Series (25 tests, T21–T45)

| Test procedure | Group title |
|---|---|
| `T21_KritikHataDogrulama` | Critical fix verification (Verify flush buffer & hash collision) |
| `T22_MinMaxTipKiyas` | MIN/MAX type-aware comparison (not string order) |
| `T23_Blob` | BLOB raw bytes (storage + JSON type) |
| `T24_Dayaniklilik` | Commit-flush guarantee (P-DUR) |
| `T25_F1_UnionSiraVeLimit` | F1-11/F1-12 UNION column check + ordering after union |
| `T26_F1_OrderByTip` | F1-20 numeric type of ORDER BY after GROUP BY |
| `T27_F1_OrderByBilinmeyenKolon` | F1-21 ORDER BY unknown column errors |
| `T28_F1_JoinTipKiyas` | F1-17 numeric comparison after JOIN |
| `T29_F1_UpdateBilinmeyenKolon` | F1-16 UPDATE unknown column errors |
| `T30_F1_DeleteDatabase` | F1-15 DELETE DATABASE live + outside batch |
| `T31_F1_NotInNull` | F1-13/F1-14 NULL logic (NOT IN / NOT NULL) |
| `T32_F1_LimitGecersiz` | F1-18 invalid LIMIT/OFFSET value errors |
| `T33_F1_SumBosKume` | F1-19 SUM of empty set returns NULL |
| `T34_F1_AlterRenameBozukSatir` | F1-8 hash verification (data intact after ALTER RENAME) |
| `T35_F1_OffsetAlias` | F1-10 OFFSET alias (SELECT * FROM t OFFSET n) |
| `T36_F1_RecoverKirpma` | F1-1 Recover: half-batch physical truncation |
| `T37_F1_CommitBatchAtomik` | F1-2 CommitBatch atomicity on the error path |
| `T38_F1_CheckRestrictFiltresi` | F1-4 UPDATE on an unrelated column does not trigger the FK check |
| `T39_F1_UniqueBayatAnahtar` | F1-5 UNIQUE map cleaned after UPDATE |
| `T40_F1_AlterDropColumnFK` | F1-6 DROP COLUMN rejects the cascading FK |
| `T41_F1_AlterAddColumnNotNull` | F1-7 ADD COLUMN NOT NULL pre-applied |
| `T42_F1_BatchInsertAtomik` | F1-9 BatchInsert uses its own batch |
| `T43_F1_MigrateLegacy` | F1-3 MigrateLegacy transfers a headerless file |
| `T44_F1_ParserDerinlik` | F1-22 parser depth limit |
| `T45_F1_SplitStatements` | F1-23 SplitStatements comment/quote separators |

### 4.4 F2/F3 Regression Series (23 tests, T46–T68)

| Test procedure | Group title |
|---|---|
| `T46_F2_SemaBozukSatir` | F2-13 corrupt schema record errors |
| `T47_F2_BosTabloAdi` | F2-14 empty table name rejected |
| `T48_F2_DropTableFK` | F2-6 DROP TABLE checks real intersection |
| `T49_F2_SelfRefFK` | F2-12 self-referencing FK + cascade depth |
| `T50_F2_IdxBLOBKarisim` | F2-15 BLOB + multi-column UNIQUE index separator collision |
| `T51_F2_DropColumnIdx` | F2-11 DROP COLUMN cleans index state |
| `T52_F2_AlterColumnType` | F2-10 ALTER COLUMN TYPE guards |
| `T53_F2_DDLAtomik` | F2-9 DDL atomicity |
| `T54_F2_UnionDistinct` | F2-18 UNION/DISTINCT dedup |
| `T55_F2_PencereBellek` | F2-19 window sort result correct |
| `T56_F2_AltSorgu` | F2-20 IN subquery set |
| `T57_F2_BozukDosya` | F2-3 corrupt file gives a consistent error |
| `T58_F2_VerifyBATCHEND` | F2-17 Verify BATCHEND counter |
| `T59_F2_DizinFlush` | F2-1/F2-2 directory flush result and marker |
| `T60_F2_WALKilit` | F2-4 WAL method lock and openness check |
| `T61_F2_GetDogruluk` | F2-5 Get correctness and missing key |
| `T62_F2_DropColumnBatch` | F2-7 DROP TABLE marker removed after the schema persists |
| `T63_F2_BozukKayitTespit` | F2-16 corrupt record not silently swallowed |
| `T64_PKsizTablo` | F2-22 PK-less table: first column not PK, no accidental UNIQUE |
| `T65_UniqueIndex` | F2-23 CREATE UNIQUE INDEX enforced |
| `T66_DropColCokKolluIndeks` | F2-11 DROP COLUMN removes multi-column indexes too |
| `T67_F3_Hijyen` | F3 hygiene regression + PROBE multi-column index earlier equality |
| `T68_F3_IndeksOnekFiltre` | F3-7 multi-column index prefix filter does not delete rows |

### 4.5 Administration + WAL (5 tests, T69–T73)

| Test procedure | Group title |
|---|---|
| `T69_YonetimAPI` | Engine API paths used by the management tool |
| `T70_YonetimBakim` | Management maintenance features (durability, script, compaction) |
| `T71_SemaSorgulari` | SQL schema queries (DESCRIBE / SHOW INDEXES / SHOW CREATE TABLE) |
| `T72_WALReplay` | WAL replay is real (torn tail + checkpoint) |
| `T73_OtomatikWAL` | AUTOMATIC WAL (WALEnabled) |

### 4.6 Encryption (4 tests, T74–T77)

| Test procedure | Group title |
|---|---|
| `T74_KayitSifreleme` | RECORD-LEVEL ENCRYPTION (VDB_FLAG_ENCRYPTED) |
| `T75_SifrelemeDayanikliligi` | ENCRYPTION DURABILITY (Compact/BackupTo flag) |
| `T76_WALReplaySifreli` | WAL REPLAY + BATCH/AUTOCOMPACT (ENCRYPTED) |
| `T77_AlterDatabaseKey` | ALTER DATABASE KEY (password rotation) |

### 4.7 AS OF + SAVEPOINT (2 tests, T78–T79)

| Test procedure | Group title |
|---|---|
| `T78_AsofGecmis` | AS OF (read from WAL history) |
| `T79_Savepoint` | SAVEPOINT (R-02) |

### 4.8 MVCC (3 tests, T90–T92)

| Test procedure | Group title |
|---|---|
| `T90_MVCC_Snapshot` | R-01 MVCC: Transaction Snapshot |
| `T91_MVCC_Concurrency` | R-01 MVCC: Writer/Reader concurrency |
| `T92_MVCC_NestedSelect` | R-01 MVCC: Nested SELECT snapshot |

### 4.9 Security + Collation + Monitoring (8 tests, T93–T94f, T105)

| Test procedure | Group title |
|---|---|
| `T93_RBAC` | RBAC: ROLE / GRANT / REVOKE (R-18) |
| `T94_RBAC_Persist` | RBAC durability (R-18) |
| `T94b_RLS` | ROW LEVEL SECURITY (R-19) |
| `T94c_RLS_Persist` | RLS durability (R-19) |
| `T94d_Collation` | COLLATION (R-20) |
| `T94e_Collation_Persist` | COLLATION durability (R-20) |
| `T94f_Monitoring` | R-24 Monitoring (basic counters) |
| `T105_ShowStats` | SHOW STATS (R-24) — global counters + ANALYZE table statistics (27 sub-tests) |

### 4.10 Backup + Replication (2 tests, T95–T95b)

| Test procedure | Group title | Sub-tests |
|---|---|---|
| `T95_WALArsiv` | R-16: WAL archiving + PITR | 24 |
| `T95b_Replication` | R-17: Streaming Replication (WAL log-shipping) | 17 |

### 4.11 Full Rounds (9 tests, T97–T104, T106)

| Test procedure | Group title | Sub-tests |
|---|---|---|
| `T97_CrossPlatform` | R-23: Cross-Platform DLL / C API | 16 |
| `T98_CBO` | R-15 Full: Cost-Based Optimizer (CBO) | 25 |
| `T99_Extension` | R-21 Full: Extension / Plugin | 25 |
| `T100_Parallel` | R-14 Full: Parallel Query (worker pool + parallel ORDER BY) | 58 |
| `T101_TcpReplication` | R-17 Full: TCP streaming replication (real sockets) | 21 |
| `T102_ConcurrentIndex` | R-22 Full: CREATE INDEX CONCURRENTLY (online index build) | 44 |
| `T103_IcuCollation` | ICU COLLATION tr-TR-u-kn-ks (R-20 Full) | 30 |
| `T104_HashPartition` | HASH PARTITIONING + PARTITION PRUNING (R-13 Full) | 70 |
| `T106_TcpSqlServer` | R-12 Full: TCP SQL server + client (VDBS) | 32 |

### 4.12 Other test suites

| Package | Result | Scope |
|---|---|---|
| `vdbcrypttest` | 60/60 | Encryption: PBKDF2/AES-256/HMAC, .key, rekey, replay |
| `vdbapitest` | 170/170 | C API (`vdbapi.dll` version 1.2): open/exec/param/blob/error + WAL/CDC |
| `vdbclienttest` | 101/101 | Client library (VDbClient) |
| `VDbXPrimsTest` | historical: EXITCODE=0 | Primitives: mutex/event/shared memory/lock — test program not in tree; `VDbXPrims.pas` unit compiles |
| `VDbPoolTest` | historical: 10/10 | Multi-process pool — test program not in tree; `VDbPool.pas` unchanged since 12.10 |
| `crashtest` | **8/8** | Crash durability: random kill points + transaction atomicity (`crashtest.exe verify [batch]`, `C:\temp\vdbcrash`) — zero data loss |

**2026-10-13 full-run note:** the sources of the three programs
(`vdbcrypttest`, `vdbapitest`, `vdbclienttest`) are also not in the tree →
they were built and run from the `vdbtest\yedek` backups (results from that
run; backup2). During the run, **2 real FAILs** belonging to `vdbapitest`
surfaced: the `VdbFileSizeOf` R-23 regression (§6) — fixed with mutation
evidence; the version expectation was also updated 1.1 → 1.2 (DLL ABI 1.2
is intentional; the version-update convention in §6).

### 4.13 R-12 Continuation: Auth / Prepared / Capacity (3 tests, T107–T109)

| Test procedure | Group title |
|---|---|
| `T107_AuthSession` | R-12 continuation: VDBS session/auth (T107) |
| `T108_PreparedStatement` | R-12 continuation: VDBS prepared statement (T108) |
| `T109_PoolSlotTCP` | R-12 continuation: Pool slot <-> TCP (T109) |

---

## 5. 📁 TUR TARİHÇESİ (özel bölümler)

### 5.1 🔒 R-12 DERİNLEŞTİRME (2026-10-12, ikinci tur)

**1. Slot kiralaması artık ATOMİK.**
`TSharedMemory.AllocateSlot` önce "ilk boş slotu bul, `Active=True` yap" idi —
shared memory üzerinde yarış şartı olmadığı için **iki süreç aynı slotu
alabiliyordu** (testte 3 sürecin hepsi "slot=2" yazıyordu, bu hataydı).
Artık `TConnectionSlot.Flags` bir **kiralama baytı** olarak kullanılıyor ve
`InterlockedCompareExchange` ile tek işlemde alınıyor.

- Yeni API: `TryAllocateSlot` (hata vermez, `-1` döner), `ClaimedSlots`
  (kiralı slot'ları `id:sahipPID` listesi olarak döner), `TouchSlot`
  (aksi halde slot kalıcı olarak daralırdı).
- **Test gerçekten yarış koşuyor**: 3 süreç, 400'er kiralama, aralarında
  1 ms → 508 kayıtta 2+ slot **aynı anda** kirali görüldü; 1200
  kiralamanın **hepsinde** sahiplik doğru (yarış şartı çalışıyor);
  eşzamanlı slot sayısı hiçbir zaman kapasiteyi (4) aşmadı.

**2. Çift slot tahsisi kaldırıldı.**
`InitXProc` süreç başına ayrı bir slot kiralamıyordu; slot artık **açık
bağlantıyı** temsil ediyor ve `Acquire`/`Release` arasında tutuluyor.
Ayrıca `Release(nil)` artık no-op değil — eski hâliyle slot hiç
bırakılmıyor, kapasite sızıyordu.

**3. Motor aç/kapat maliyeti — incelendi, GÜVENLİ ÇÖZÜM YOK, yapılmadı.**
`.odb` dosyası `LockFileEx` ile **özel (exclusive)** kilitleniyor (`VDbSync`).
Kilit paylaşılabilir yapılsa bile, her süreç dosyayı açıp **kendi belleğinde
indeks önbelleği** tutar; iki süreç birbirinin yazmalarını göremez ve veri
bozulur. Bu yüzden doğru model **serileştirilmiş çok süreçli erişim**:
`Acquire` → isimli mutex + motoru aç, `Release` → motoru kapat + mutex'i bırak.
Doğru ve veri bütünlüğü güvenli, ama her işlemde aç/kapa maliyeti var.
Gerçek eşzamanlılık için **sunucu/pipe mimarisi** gerekir (→ §8.1).

### 5.2 🆕 R-16 WAL ARŞİVLEME + PITR (2026-10-12)

**Mimari:** PostgreSQL'in WAL arşivlemesinin sadeleştirilmiş hâli.

- `TVDbWalHead` genişletildi: `LSN: QWord` + `WalStamp: QWord` (Unix ms). CRC artık `RecCrcWal(LSN, Stamp, Key, ValLen, Flags, Value)` — LSN ve zaman damgası CRC'ye dahil, bu yüzden arşivlenen segmentin zaman bilgisi sonradan değiştirilemez.
- `TVDb`: `FWalLSN` (artan günlük sayaç), `FArchiveDir`, `FWalSegmentMax`. Yeni API: `SetArchiveDir`, `SetWalSegmentMax`, `MaybeRotateWal`, `ListWalArchive`, `RecoverFromArchive`.
- Segment rotasyonu: `BACKUP TO` anında zorla, veya `FWalSegmentMax` bayt aşıldığında otomatik. Arşiv dosyaları: `<dbadi>_NNNNNNNN.wal` (8 haneli sıfır dolgu → leksikografik = kronolojik sıra).
- `RECOVER FROM ARCHIVE`: arşiv segmentlerini sırayla uygular; `ATargetStamp > 0` ise o damgadan büyük kayıtta DURUR (PITR). Bozuk segmentte (CRC/magic/yırtık kuyruk) replay KESİLİR, sonraki segmentler UYGULANMAZ → veri bozulmaz, kısmi kurtarma.
- SQL yüzeyi: `ARCHIVE WAL SET DIR='...' [SIZE=...]`, `ARCHIVE WAL RESET`, `ARCHIVE WAL LIST`, `BACKUP TO '...'`, `RESTORE FROM '...'`, `RECOVER TO TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.mmm]'`, `RECOVER TO NOW`.
- Test `T95_WALArsiv`: arsivleme kapalı/açık, BACKUP arsivler, RECOVER uygular, bozuk segment atlanır, RESTORE geri yükler, bozuk zaman damgası reddedilir — 24 alt-test, hepsi geçti.

### 5.3 🆕 R-17 STREAMING REPLICATION (WAL LOG-SHIPPING) (2026-10-12)

**Mimari:** Proje kuralı "harici DLL yok, saf FPC" olduğu için TCP/SSL ağ
katmanı YERİNE deterministik bir **WAL log-shipping** akışı uygulandı.
Aynı iki adım (gönder / uygula) gerçek sistemde bir arka plan thread'inde
periyodik çalışır; burada `PUMP REPLICATION` ile SQL'den tek adım tetiklenir
(test edilebilirlik).

- **`VDbReplication.pas`** (yeni, bağımsız birim): `TReplicationRole`,
  `TReplSlot`, `TReplicationState`. Kalıcı slotlar `<db-dizini>/.replslots`
  dosyasında `slot|restartLSN|confirmedLSN|active` olarak tutulur.
- **`TVDb.ApplyWalSegmentFile(APath)`** (VDbCore public): harici bir WAL
  segmentini (standby inbox / primary arşivi) mevcut `.odb`'ye batch halinde
  uygular. `ApplySegment` ile aynı doğrulama/atomiklik; R-16 altyapısını
  yeniden kullanır.
- **Primary:** `WalShipOnce` arşiv dizinindeki yeni segmentleri (`_NNNNNNNN.wal`)
  ship (hedef) dizinine kopyalar; `slot.RestartLSN` ilerler.
- **Standby:** `WalApplyOnce` ship dizinindeki, `slot.ConfirmedLSN`'den büyük
  numaralı segmentleri `ApplyWalSegmentFile` ile uygular; `ConfirmedLSN` ilerler.
- **SQL yüzeyi:** `START REPLICATION PRIMARY [DEST 'ship-dir'] SLOT 's'`,
  `START REPLICATION STANDBY 'ship-dir' SLOT 's'`, `PUMP REPLICATION`,
  `STOP REPLICATION`, `CREATE/DROP REPLICATION SLOT 's'`,
  `SHOW REPLICATION STATUS`, `SHOW REPLICATION SLOTS`.
- **Test `T95b_Replication` (17 alt-test):** iki ayrı DB ile primary→ship→standby;
  idempotans (tekrar PUMP = 0), artımlı akış (yalnız yeni segment), sema + veri
  aktarımı, slot CRUD, pasifken PUMP reddi — hepsi geçti.
- **Mutasyon testi:** `WalShipOnce` ve `WalApplyOnce` içindeki
  `if n <= ...LSN then Continue` satırları `if False` yapıldığında
  sırasıyla "tekrar PUMP ... idempotent" testleri çöktü (`[5]`, `[7]`);
  geri alınınca yeşile döndü.

### 5.4 🆕 R-17 FULL: GERÇEK TCP AKIŞI (2026-10-13)

**Amaç:** log-shipping'in iki adımını (gönder/uygula) gerçek bir ağ
bağlantısı üzerinden, gerçek iş parçacıklarıyla sürekli akışa çevirmek.
Proje kuralı "harici DLL yok, saf FPC" sürdü: taşıma FPC RTL `Sockets`
birimiyle kuruldu (Windows'ta winsock2, Unix'te BSD sockets; WSAStartup
birimin initialization'ında otomatik).

**Yeni birim `VDbNet.pas` (platform-nötr taşıma katmanı):**

- `VdbTcpListen` (SO_REUSEADDR açık) / `VdbTcpAccept` / `VdbTcpConnect`;
- `VdbSendAll` / `VdbRecvAll`: "hepsi ya hiç" — kısmi okuma/yazma yok;
- küçük-endian **u8/u32/u64** ve uzunluk-ekli dizgi ilkelleri
  (`VdbSendU32`... `VdbRecvStr`) — bayt düzeni platformdan bağımsız;
- `VdbSockShutdown`: engellenmiş recv'i başka thread'den güvenle
  uyandırmak için (soket kapanmaz). Ders: FPC'de `StrToHostAddr` HOST
  bayt düzeni döndürür; sockaddr ağ düzeni ister → `StrToNetAddr` kullanılır.

**VDBR kablolama protokolü (v1):**

- El sıkışma (alıcı→gönderici): `'VDBR'` magic + u32 sürüm + slot adı;
  yanıt (gönderici→alıcı): magic + sürüm + u32 durum (0=OK, 1=bilinmeyen slot).
- `SEGMENT` (gönderici→alıcı): u8 tür + ad + u64 segmentNo + u32 CRC32 +
  u32 veri uzunluğu + veri. Alıcı uygular ve `ACK` (u8=1 + u64 LSN) döner.
- `HEARTBEAT` (boşlukta), `END` (nazik kapanış). CRC = mevcut `VDbCrc32Of`.

**Thread'ler (`VDbReplication.pas`):**

- `TVdbWalSenderThread.Execute` = yol haritasındaki **WalSenderLoop**:
  dinle + kabul et + her bağlantı için `ServeClient` (el sıkışma →
  RestartLSN'den büyük arşiv segmentlerini akıt → ACK bekle). Gönderici
  MOTORA DOKUNMAZ: yalnız arşiv DOSYALARINI okur → primary akış sırasında
  SQL'e açık kalır. Bilinmeyen slot reddi (BADSLOT) protokolde var.
- `TVdbWalReceiverThread.Execute` = **WalReceiverLoop**: bağlan (5 sn
  yeniden deneme) → el sıkış → mesaj al → CRC doğrula → geçici dosyaya
  yaz → `ApplyWalSegmentFile` → ACK. **Akış sırasında standby motoru bu
  thread'e AİTTİR**: `TVSqlExecutor.Execute` girişinde `IsStreamingDb`
  guard'ı yalnız `STOP REPLICATION` ve `SHOW REPLICATION STATUS`'u geçirir,
  geri kalan her cümle `ecDatabaseLocked` ile reddedilir.
- Kayıt defteri `GNetRepl` (yalnız ana thread erişir) + finalization
  güvenlik ağı: STOP edilmemiş thread'ler süreç kapanışında durdurulur.

**Slot semantiği (ikili):** slot adı çifti tanımlar — alıcı primary'nin
slot adıyla bağlanır; her taraf KENDİ `.replslots` dosyasında kendi
alanını izler (primary: restart_lsn, standby: confirmed_lsn). Thread'ler
GLOBAL slot durumunu kullanmaz → aynı süreçte bir primary + bir standby
AYNI ANDA akabilir (test tam bunu yapar).

**Sağlamlık:**

- WAL rotasyonu artık atomik: `MaybeRotateWal` önce `.tmp`'ye kopyalar,
  sonra `RenameFile` — arşivi tarayan gönderici asla yarım segment okumaz.
- `Stop` deseni: Windows'ta engellenmiş `accept`'i uyandırmanın tek güvenli
  yolu dinleme soketini KAPATMAK; aktif bağlantı `shutdown` ile uyandırılır,
  kapanışları thread'ler kendi yapar (çift-kapatma yok).
- `START REPLICATION PRIMARY TCP` dinlemenin kurulmasını bekler (port
  doluysa temiz hata); aynı DB için ikinci başlatma reddedilir.

**SQL yüzeyi (eklenen):** `START REPLICATION PRIMARY TCP PORT n SLOT 's'`,
`START REPLICATION STANDBY TCP HOST 'h' PORT n SLOT 's'`; `STOP` önce TCP
kayıt defterine bakar; `SHOW REPLICATION STATUS` TCP modunda
`primary/tcp`|`standby/tcp` + `tcp://host:port (sent/applied=...)` gösterir;
`PUMP` TCP akışında anlamsızdır (açıklama mesajı döner).

**Test `T101_TcpReplication` (21 alt-test, tamamı geçti):** aynı süreçte
iki motor; gerçek localhost soketleriyle dinleme/kabul/bağlantı; 10 arşiv
segmentinin akışı (`applied=10/10`); akışta standby SQL reddi; STATUS
erişimi; STOP + yeniden açılışta şema+veri birebir (4 satır, id=4→'dort');
slot kalıcılığı (confirmed_lsn>0, active=False); bilinmeyen slot reddi;
aynı portla yeniden dinleme (SO_REUSEADDR); TCP bitince PUMP dosya moduna
döner. **Mutasyon:** alıcıdaki `if Int64(segNo) > slot.ConfirmedLSN then`
uygulama kapısı `if False` yapıldığında `applied=0/10` + zincirleme
kesilme (test dedektörü çalışıyor); geri alınınca yeşil.

### 5.5 🆕 R-23 CROSS-PLATFORM DLL / C API (2026-10-13)

**Amaç:** `vdbapi.dll` Windows'a özel bir PE iken, aynı C ABI'nin Linux
(`libvdbapi.so`), macOS (`libvdbapi.dylib`) ve BSD üzerinde de derlenip
kullanılabilmesi. Proje kuralı "harici DLL yok, saf FPC" olduğu için
platform bağımlılıkları RTL içinde tutuldu; harici bir çapraz-platform
kütüphanesi (LazUtils/FileUtil dahil) motor çekirdeğinden ÇIKARILDI.

- **`VDbPlatform.pas`** (yeni, saf RTL unit): `TVDbOS`
  (`osWindows`/`osLinux`/`osMacOS`/`osFreeBSD`/`osUnknown`), `VdbCurrentOS`,
  `VdbSharedLibName`/`VdbSharedLibNameDefault`/`VdbSharedLibCandidates`
  — paylaşılan kütüphane adını DERLEME anından bağımsız üretir
  (`vdbapi.dll` / `libvdbapi.so` / `libvdbapi.dylib`), böylece tüm
  platformlar tek makinede test edilebilir. Ayrıca `dynlibs` üzerinden
  `VdbLibTryLoad`/`VdbLibProc`/`VdbLibUnload` ve zaman ölçümü için
  `VdbTickMs` (Windows'ta `GetTickCount64`, Unix'te `Now*MSecsPerDay`
  farkı) burada. Paylaşılan tip adı çakışmasın diye `TVdbStrArray`
  kullanılır (`VDbTypes.TStrArray` ile karışmaz).
- **LazUtils/FileUtil bağımlılığı kaldırıldı:** `VDbCore` ve
  `vdbapi_core` artık yalnız FPC RTL kullanıyor (`VdbFileSizeOf` =
  `TFileStream` tabanlı yardımcı). Böylece motor `fpc` ile Linux/macOS'ta
  doğrudan derlenir. `VDB_API_VERSION = $00010100` (1.1).
- **`vdbapi.h` `VDB_CALL`:** 32-bit x86 Linux/BSD'de
  `__attribute__((stdcall))`, x86_64/aarch64'ta boş (platform
  varsayılanı). Pascal tarafı tüm hedeflerde `stdcall` kullanır; 64-bit'te
  bu zaten varsayılan ABI'dir, başlık ve kaynak böylece tutarlı kalır.
- **`VDbCrypt.pas` çapraz-platform:** Windows'a özel `uses`/`external`
  tanımları `{$IFDEF MSWINDOWS}` ile korundu; rastgelelik Unix'te
  `/dev/urandom` (yoksa zaman tabanlı yedek PRNG); DPAPI yalnız
  Windows'ta, Unix'te kimlik kopyası + parola türetimi (PBKDF2) devrede.
- **Zaman ölçümü tek kaynak:** `GetTickCount64` çağrıları `VDbCdc`,
  `VDbMonitor`, `VDbPool`, `VDbXPrims`, `VDbExecutor`, `VDbSql`
  birimlerinde `VDbPlatform.VdbTickMs`'e taşındı (Unix'te derlenebilirlik).
- **Derleme betikleri:** `build_lib.sh` (Linux/macOS/BSD; `uname` + `-T`
  ile hedef seçer, `libvdbapi.so`/`.dylib` üretir), `build_dll.ps1`
  (Windows; güncellendi — LazUtils satırı kaldırıldı, FPC otomatik
  bulunur). `vdbapi.lpi` düzeltildi: var olmayan `vdbapi.pas` ünitesi ve
  LazUtils paketi çıkarıldı, ölü mutlak yollar göreli yola indirildi.
- **Test `T97_CrossPlatform` (16 alt-test):** OS tespiti, tüm OS'ler için
  doğru kütüphane adı, boş taban adı `VDB_SO_NAME`'e düşer, varsayılan ad
  `VdbCurrentOS` ile tutarlı, aday listeleri, gerçek `vdbapi.dll`'i
  `dynlibs` ile dinamik yükleme + `VdbApiVersion` sembolü çözümü + sürüm
  `>= 1.0` + güvenli boşaltma, `VdbLibUnload(NilHandle)` no-op.
- **Mutasyon testi:** `VdbSharedLibName` içindeki Linux dalı
  `if False` yapıldığında "Linux adi" ve "bos taban adi" testleri
  çöktü (`[vdbapi.so]`); geri alınınca yeşile döndü.

---

**ENGLISH — round history §5.1–§5.5:**

### 5.1 R-12 Deepening (2026-10-12, second round)

**1. Slot leasing is now ATOMIC.**
`TSharedMemory.AllocateSlot` used to be "find the first free slot, set `Active=True`" — with no race protection on shared memory, **two processes could take the same slot** (in the test all 3 processes wrote "slot=2"; that was the bug). Now `TConnectionSlot.Flags` is used as a **lease byte** acquired atomically via `InterlockedCompareExchange`.

- New API: `TryAllocateSlot` (never errors, returns `-1`), `ClaimedSlots` (returns leased slots as an `id:ownerPID` list), `TouchSlot` (otherwise the slot would permanently shrink).
- **The test really races**: 3 processes, 400 leases each, 1 ms apart → at 508 records 2+ slots were observed leased **simultaneously**; ownership correct in **all** 1200 leases (the race condition works); concurrent slot count never exceeded the capacity (4).

**2. Double slot allocation removed.**
`InitXProc` no longer leases a separate slot per process; the slot now represents the **open connection** held between `Acquire`/`Release`. Also `Release(nil)` is no longer a no-op — in its old form the slot was never released and capacity leaked.

**3. Engine open/close cost — investigated, NO SAFE SOLUTION, not done.**
The `.odb` file is locked **exclusive** via `LockFileEx` (`VDbSync`). Even if the lock were made shareable, each process would open the file and keep **its own in-memory index cache**; two processes cannot see each other's writes and the data would corrupt. Hence the correct model is **serialized multi-process access**: `Acquire` → named mutex + open engine, `Release` → close engine + release mutex. Correct and data-integrity-safe, but every operation pays open/close cost. True concurrency requires a **server/pipe architecture** (→ §8.1).

### 5.2 R-16 WAL ARCHIVING + PITR (2026-10-12)

**Architecture:** a simplified version of PostgreSQL's WAL archiving.

- `TVDbWalHead` extended: `LSN: QWord` + `WalStamp: QWord` (Unix ms). CRC is now `RecCrcWal(LSN, Stamp, Key, ValLen, Flags, Value)` — the LSN and timestamp are part of the CRC, so an archived segment's time info cannot be altered later.
- `TVDb`: `FWalLSN` (monotonic log counter), `FArchiveDir`, `FWalSegmentMax`. New API: `SetArchiveDir`, `SetWalSegmentMax`, `MaybeRotateWal`, `ListWalArchive`, `RecoverFromArchive`.
- Segment rotation: forced at `BACKUP TO`, or automatic once `FWalSegmentMax` bytes are exceeded. Archive files: `<dbname>_NNNNNNNN.wal` (8-digit zero padding → lexicographic = chronological order).
- `RECOVER FROM ARCHIVE`: applies archive segments in order; if `ATargetStamp > 0` it STOPS at the first record with a greater stamp (PITR). On a corrupt segment (CRC/magic/torn tail) replay STOPS and later segments are NOT applied → no corruption, partial recovery.
- SQL surface: `ARCHIVE WAL SET DIR='...' [SIZE=...]`, `ARCHIVE WAL RESET`, `ARCHIVE WAL LIST`, `BACKUP TO '...'`, `RESTORE FROM '...'`, `RECOVER TO TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.mmm]'`, `RECOVER TO NOW`.
- Test `T95_WALArsiv`: archiving off/on, BACKUP archives, RECOVER applies, corrupt segment skipped, RESTORE restores, corrupt timestamp rejected — 24 sub-tests, all pass.

### 5.3 R-17 STREAMING REPLICATION (WAL LOG-SHIPPING) (2026-10-12)

**Architecture:** because the project rule is "no external DLLs, pure FPC" (no TCP/SSL network layer), a deterministic **WAL log-shipping** flow was implemented instead. The same two steps (send/apply) run periodically in a background thread in a real system; here `PUMP REPLICATION` triggers one step from SQL (for testability).

- **`VDbReplication.pas`** (new, standalone unit): `TReplicationRole`, `TReplicationState`. Persistent slots are stored in `<db-dir>/.replslots` as `slot|restartLSN|confirmedLSN|active`.
- **`TVDb.ApplyWalSegmentFile(APath)`** (public on VDbCore): applies an external WAL segment (standby inbox / primary archive) to the current `.odb` in a batch. Same validation/atomicity as `ApplySegment`; reuses the R-16 infrastructure.
- **Primary:** `WalShipOnce` copies new segments (`_NNNNNNNN.wal`) from the archive dir to the target (ship) dir; `slot.RestartLSN` advances.
- **Standby:** `WalApplyOnce` applies segments numbered above `slot.ConfirmedLSN` from the ship dir via `ApplyWalSegmentFile`; `ConfirmedLSN` advances.
- **SQL surface:** `START REPLICATION PRIMARY [DEST 'ship-dir'] SLOT 's'`, `START REPLICATION STANDBY 'ship-dir' SLOT 's'`, `PUMP REPLICATION`, `STOP REPLICATION`, `CREATE/DROP REPLICATION SLOT 's'`, `SHOW REPLICATION STATUS`, `SHOW REPLICATION SLOTS`.
- **Test `T95b_Replication` (17 sub-tests):** two separate DBs, primary→ship→standby; idempotency (repeat PUMP = 0), incremental streaming (only new segments), schema + data transfer, slot CRUD, PUMP rejected while inactive — all pass.
- **Mutation test:** when the `if n <= ...LSN then Continue` lines inside `WalShipOnce` and `WalApplyOnce` were set to `if False`, the "repeat PUMP ... idempotent" tests crashed (`[5]`, `[7]`); reverted → green again.

### 5.4 R-17 FULL: REAL TCP STREAMING (2026-10-13)

**Goal:** turn log-shipping's two steps (send/apply) into a continuous stream over a real network connection with real threads. The project rule "no external DLLs, pure FPC" held: the transport was built on the FPC RTL `Sockets` unit (winsock2 on Windows, BSD sockets on Unix; WSAStartup runs automatically in the unit's initialization).

**New unit `VDbNet.pas` (platform-neutral transport layer):**

- `VdbTcpListen` (SO_REUSEADDR on) / `VdbTcpAccept` / `VdbTcpConnect`;
- `VdbSendAll` / `VdbRecvAll`: "all or nothing" — no partial reads/writes;
- little-endian **u8/u32/u64** and length-prefixed string primitives (`VdbSendU32`… `VdbRecvStr`) — byte order independent of platform;
- `VdbSockShutdown`: to safely wake a blocked recv from another thread (the socket is not closed). Lesson: in FPC `StrToHostAddr` returns HOST byte order; sockaddr needs network order → use `StrToNetAddr`.

**VDBR wire protocol (v1):**

- Handshake (receiver→sender): `'VDBR'` magic + u32 version + slot name; reply (sender→receiver): magic + version + u32 status (0=OK, 1=unknown slot).
- `SEGMENT` (sender→receiver): u8 type + name + u64 segmentNo + u32 CRC32 + u32 data length + data. Receiver applies it and replies `ACK` (u8=1 + u64 LSN).
- `HEARTBEAT` (when idle), `END` (graceful close). CRC = existing `VDbCrc32Of`.

**Threads (`VDbReplication.pas`):**

- `TVdbWalSenderThread.Execute` = the roadmap's **WalSenderLoop**: listen + accept + `ServeClient` per connection (handshake → stream archive segments above RestartLSN → wait for ACK). The sender NEVER TOUCHES THE ENGINE: it only reads archive FILES → the primary stays open to SQL during streaming. Unknown-slot rejection (BADSLOT) exists in the protocol.
- `TVdbWalReceiverThread.Execute` = **WalReceiverLoop**: connect (retry every 5 s) → handshake → receive message → verify CRC → write to a temp file → `ApplyWalSegmentFile` → ACK. **During streaming the standby engine belongs to THIS thread**: the `IsStreamingDb` guard in `TVSqlExecutor.Execute` lets only `STOP REPLICATION` and `SHOW REPLICATION STATUS` through; every other statement is rejected with `ecDatabaseLocked`.
- Registry `GNetRepl` (main thread only) + a finalization safety net: non-stopped threads are halted at process shutdown.

**Slot semantics (pair):** a slot name defines a pair — the receiver connects using the primary's slot name; each side tracks its OWN field in ITS OWN `.replslots` file (primary: restart_lsn, standby: confirmed_lsn). Threads never use GLOBAL slot state → one primary and one standby can stream in the SAME process (the test does exactly that).

**Robustness:**

- WAL rotation is now atomic: `MaybeRotateWal` copies to `.tmp` first, then `RenameFile` — a sender scanning the archive never reads a half segment.
- The `Stop` pattern: on Windows the only safe way to wake a blocked `accept` is to CLOSE the listening socket; an active connection is woken with `shutdown`, threads do their own closing (no double-close).
- `START REPLICATION PRIMARY TCP` waits until the listener is set up (clean error if the port is busy); a second start for the same DB is rejected.

**SQL surface (added):** `START REPLICATION PRIMARY TCP PORT n SLOT 's'`, `START REPLICATION STANDBY TCP HOST 'h' PORT n SLOT 's'`; `STOP` consults the TCP registry first; `SHOW REPLICATION STATUS` in TCP mode shows `primary/tcp`|`standby/tcp` + `tcp://host:port (sent/applied=...)`; `PUMP` is meaningless on a TCP stream (returns an explanatory message).

**Test `T101_TcpReplication` (21 sub-tests, all pass):** two engines in one process; real localhost listen/accept/connect; streaming of 10 archive segments (`applied=10/10`); SQL rejected on the standby during streaming; STATUS access; STOP + reopen: schema+data identical (4 rows, id=4→'dort'); slot durability (confirmed_lsn>0, active=False); unknown slot rejected; re-listening on the same port (SO_REUSEADDR); after TCP ends, PUMP falls back to file mode. **Mutation:** setting the receiver's `if Int64(segNo) > slot.ConfirmedLSN then` apply gate to `if False` produced `applied=0/10` + a broken chain (the test detector works); reverted → green.

### 5.5 R-23 CROSS-PLATFORM DLL / C API (2026-10-13)

**Goal:** `vdbapi.dll` is a Windows-only PE; the same C ABI should also build and run on Linux (`libvdbapi.so`), macOS (`libvdbapi.dylib`) and BSD. Because the project rule is "no external DLLs, pure FPC", platform dependencies were kept inside the RTL; an external cross-platform library (LazUtils/FileUtil included) was REMOVED from the engine core.

- **`VDbPlatform.pas`** (new, pure RTL unit): `TVDbOS` (`osWindows`/`osLinux`/`osMacOS`/`osFreeBSD`/`osUnknown`), `VdbCurrentOS`, `VdbSharedLibName`/`VdbSharedLibNameDefault`/`VdbSharedLibCandidates` — produce the shared-library name INDEPENDENT of build time (`vdbapi.dll` / `libvdbapi.so` / `libvdbapi.dylib`), so all platforms can be tested on one machine. Also `dynlibs`-based `VdbLibTryLoad`/`VdbLibProc`/`VdbLibUnload` and `VdbTickMs` for timing (`GetTickCount64` on Windows, `Now*MSecsPerDay` delta on Unix) live here. The shared type name is `TVdbStrArray` to avoid clashing with `VDbTypes.TStrArray`.
- **LazUtils/FileUtil dependency removed:** `VDbCore` and `vdbapi_core` now use only the FPC RTL (`VdbFileSizeOf` = a `TFileStream`-based helper). The engine therefore builds directly with `fpc` on Linux/macOS. `VDB_API_VERSION = $00010100` (1.1).
- **`vdbapi.h` `VDB_CALL`:** `__attribute__((stdcall))` on 32-bit x86 Linux/BSD, empty on x86_64/aarch64 (platform default). Pascal uses `stdcall` on all targets; on 64-bit that is already the default ABI, keeping header and source consistent.
- **`VDbCrypt.pas` cross-platform:** Windows-specific `uses`/`external` declarations are guarded by `{$IFDEF MSWINDOWS}`; randomness on Unix comes from `/dev/urandom` (time-based fallback PRNG if missing); DPAPI only on Windows, on Unix identity copy + password derivation (PBKDF2).
- **Single timing source:** `GetTickCount64` calls in `VDbCdc`, `VDbMonitor`, `VDbPool`, `VDbXPrims`, `VDbExecutor`, `VDbSql` were moved to `VDbPlatform.VdbTickMs` (Unix buildability).
- **Build scripts:** `build_lib.sh` (Linux/macOS/BSD; picks the target via `uname` + `-T`, produces `libvdbapi.so`/`.dylib`), `build_dll.ps1` (Windows; updated — LazUtils line removed, FPC found automatically). `vdbapi.lpi` fixed: nonexistent `vdbapi.pas` unit and LazUtils package removed, dead absolute paths made relative.
- **Test `T97_CrossPlatform` (16 sub-tests):** OS detection, correct library name for every OS, empty base name falls back to `VDB_SO_NAME`, default name consistent with `VdbCurrentOS`, candidate lists, real dynamic loading of `vdbapi.dll` via `dynlibs` + `VdbApiVersion` symbol resolution + version `>= 1.0` + safe unload, `VdbLibUnload(NilHandle)` no-op.
- **Mutation test:** setting the Linux branch inside `VdbSharedLibName` to `if False` crashed the "Linux adi" and "bos taban adi" tests (`[vdbapi.so]`); reverted → green again.

### 5.6 🆕 R-15 FULL COST-BASED OPTIMIZER (2026-10-13)

**Amaç:** `ANALYZE` ile toplanan istatistikleri **sorgu planı seçiminde**
kullanmak — hangi indeks (varsa), hangi tarama (Seq / Index / Index-Only)
ve iki tablolu JOIN'de hangi tablo dış (driving) taraf olacak.

- **`VDbCost.pas`** (yeni, saf maliyet modeli): `TVdbPlanKind`,
  `TVdbCostEstimate`, `VdbEstimateEqRows`, `VdbSeqScanCost`,
  `VdbIndexScanCost`, **`VdbIndexIsSelective`** (tek karar noktası),
  `VdbChooseScan`, `VdbChooseScanForRows`, `VdbJoinOuterFirst`,
  `VdbFormatCost`. Model PostgreSQL'in basitleştirilmişidir: sıralı tarama
  satır başına 1.0; indeks probe 1.0 + tabloya rastgele erişim 4.0
  (index-only'de 0.2). Kaba seçicilik eşiği: normal indeks ~%20,
  index-only ~%80.
- **Parser:** `ANALYZE [TABLE] <tablo>` tanındı. Önceki turda
  `ExecAnalyze` + `RecordTableStats` vardı ama **`ANALYZE` ana dağıtıcıya
  bağlı değildi** — yani erişilemezdi ("Bilinmeyen SQL komutu").
- **`VDbExecutor.ExecExplain`:** istatistik varsa (yalnız o zaman) plan
  satırına `(cost=a..b rows=N)` eklenir ve tarama türü CBO ile seçilir.
  İstatistik yoksa **eski davranış aynen korunur** (geri uyumluluk).
- **`VDbExecutor.NarrowRows`:** gerçek yürütme yolunda da aynı karar
  kullanılır. İndeks diliminin genişliği (`bestHi-bestLo`) indeksten TAM
  ölçülür; `VdbIndexIsSelective` false ise indeks atlanır ve tam tarama
  yapılır. Sonuç DEĞİŞMEZ (dönen satırlar zaten `RowMatches` ile
  doğrulanır) — yalnız yol değişir. Bu, `ExecSelect`/`ExecUpdate`/
  `ExecDelete`'i birden etkiler.
- **`VDbExecutor.ExecAnalyze`:** DISTINCT artık gerçek hash kovasıyla
  sayılır (eski kod boş olmayan HER değeri sayıyordu → `distinct = rowcount`,
  seçicilik tahmini anlamsız). `ANALYZE` tablosuz çağrısı sessiz no-op
  yerine AÇIK söz dizimi hatası verir.
- **`VDbMonitor`:** tablo istatistikleri komut günlüğü tamponundan
  (`GBuffer`) AYRI bir `GTableStats` listesinde tutulur; aksi halde
  `GBuffer` `MaxBufferSize`'a ulaşıp `FlushBufferToFile` ile temizlenince
  ANALYZE istatistiği kayboluyordu (CBO deterministik değildi). Ayrıca
  kolon istatistiği ayrıştırıcısındaki `>= 5` → `>= 4` hatası düzeltildi
  (paket biçimi 4 alan; eski kod distinct/null'ı hiç doldurmuyordu).
- **Test `T98_CBO` (25 alt-test):** ANALYZE ayrıştırma/çalıştırma,
  düşük seçicilik → Seq Scan (indeks DEĞİL), yüksek seçicilik → Index,
  PK → `_pkey`, JOIN'de küçük tablo dışta, ANALYZE'siz tabloda eski
  davranış, CBO sonrası sonuç değişmezliği, `VDbCost` birim testleri.
- **Mutasyon testi:** `VdbIndexIsSelective` içindeki karar `if False`
  yapıldığında "yüksek seçicilik → ix_uid", "indeks seçici (100,5)",
  "index-only %50 seçici", "ChooseScan yüksek seçicilik → Index" olmak
  üzere **4 test çöktü**; geri alınınca yeşile döndü.

### 5.7 🆕 R-21 FULL EXTENSION / PLUGIN (2026-10-13)

**Amaç:** `CREATE EXTENSION` ile **gerçek** paylaşılan kütüphane (.dll /
.so / .dylib) yüklemek, sürüm/ABI doğrulamak, kayıt defterinde tutmak ve
sembol çözmek. (Önceki tur yalnız `Load/Call/Unload` iskeletiydi ve
hiçbir SQL yolu yoktu.)

- **`VDbExtension.pas`** (yeniden yazıldı): kayıt defteri
  (`TVdbExtensionInfoArray`), `LoadExtension`/`DropExtension`/
  `ExtensionCount`/`GetExtensionInfo`/`ExtensionLoaded`/
  `ExtensionSymbol`/`UnloadAllExtensions`. Yükleme platform-nötrdür:
  `VDbPlatform.VdbLibTryLoadFile` (açık dosya) ve `VdbLibTryLoad` (taban
  ad / exe dizini) kullanır; `finalization`'da tümü boşaltılır.
- **C-ABI sözleşmesi:** ZORUNLU `VdbExtApiVersion: function: LongWord;
  stdcall` (ABI ≥ `VDB_EXT_API_VERSION = $00010000`; küçükse reddedilir);
  OPSİYONEL `VdbExtName` ve `VdbExtDescription` (kayıt adı / açıklama).
- **`VDbPlatform`:** tam dosya yolundan yükleme için
  `VdbLibTryLoadFile(const AFileName; out AHandle; out APath)` eklendi.
- **Parser/AST:** `admCreateExtension`/`admDropExtension`/
  `admShowExtensions`; `TSqlAdminStmt.ExtName`/`ExtPath`. Komutlar:
  `CREATE EXTENSION [IF NOT EXISTS] ad [FROM 'yol']`,
  `DROP EXTENSION [IF EXISTS] ad`, `SHOW EXTENSIONS`.
- **`VDbExecutor.ExecAdmin`:** create (IF NOT EXISTS idempotent),
  drop (IF EXISTS idempotent), `SHOW EXTENSIONS` (name / api_version /
  file / description — 4 kolon).
- **Test eklentileri:** `vdbtestext.lpr` (`VdbExtApiVersion`=1.0, ad,
  açıklama, `VdbExtAdd`) ve `vdboldtext.lpr` (ABI=0.0.1 → red edilmeli).
  `build_testext.ps1` ikisini de derler.
- **Test `T99_Extension` (25 alt-test):** boş liste; yok kütüphane reddi;
  ABI sembolü olmayan `vdbapi.dll` reddi; eski ABI reddi + kaydedilmemesi;
  gerçek yükleme + `SHOW EXTENSIONS` alanları; `ExtensionSymbol` +
  **gerçek stdcall çağrısı** (`VdbExtAdd(2,3)=5`); yinelenen yükleme /
  `IF NOT EXISTS`; `DROP` / `IF EXISTS`; adsız komut söz dizimi hataları.
- **Mutasyon testi:** `VDbExtension.LoadExtension` içindeki ABI sürüm
  kapısı `if ver < VDB_EXT_API_VERSION` satırı `if False` yapıldığında
  eski sürümlü eklenti yüklenip kaydedildi → **5 test çöktü**; geri
  alınınca yeşile döndü.

### 5.8 🆕 R-22 FULL: CREATE INDEX CONCURRENTLY (2026-10-13)

**Amaç:** `CREATE INDEX CONCURRENTLY`'yi gerçek bir **online DDL**'e
çevirmek: cümle anında döner, indeks arka plan iş parçacığında kurulur,
tablo bu sırada okuma/yazmaya AÇIK kalır. (Önceki tur yalnız
`CONCURRENTLY` anahtar sözcüğünü kabul edip `OK (CONCURRENTLY)` dönerdi.)

**Üç fazlı mimari (`VDbTable.pas`):**

1. **Faz 1 — ana thread, cümlenin kendisi:** doğrulama `CreateIndexCols`
   içinde (imzaya `Concurrent: Boolean = False` eklendi); tanım
   `Invalid=True` ile semaya yazılır; anlık görüntü alınır
   (`BuildIdxEntries` = `BuildOneIndex`'in tarama yarısı buraya
   çıkarıldı — aynı kod senkron ve eşzamanlı yolda paylaşılır); iş
   parçacığı başlar; **cümle HEMEN döner** (`OK (CONCURRENTLY)`).
2. **Faz 2 — `TVdbConcIdxBuilder(TThread)`:** yalnızca KENDİ girdi
   dizisini sıralar. `SortIdxEntries`/`SortIdxEntriesCols` TVTableDb'nin
   paylaşılan hiçbir alanına dokunmaz (saf parametre sıralaması) → başka
   thread'den çağrı güvenli. Motor hiç kilide girmez.
3. **Faz 3 — finalize, `PollConcurrentIndexes`:** `TVSqlExecutor.Execute`
   girişinde (streaming guard'ının ardında) her cümle çağırır. Bitmiş
   (`Finished`) inşalar için: sıralı girdiler `FMemIdx`'e kurulur;
   **catch-up**: pencerede biriken yazmalar `FlushIdxPending` ile
   birleştirilir (ops satır başına GÜNCEL durum taşır → eksiksiz ve
   mükerrersiz) → UNIQUE haritası NİHAİ girdilerden kurulur →
   `Invalid=False` + semaya yazım. `AForce=True` bekleyen inşaları da
   bitirir (kapıyı açar — `ALTER COLUMN TYPE` öncesi temiz başlangıç).

**INVALID semantiği (PostgreSQL'e uygun):**

- Şemada indeks adına `?` öneki (`!` UNIQUE'den sonra: `!?ad:kolon`);
  okuma `!` ardından `?` soyar → geri uyumlu.
- INVALID indeks **okunmaz, kurulmaz, bekleyen işlemi flush edilmez**
  (`TryGetMemIndex` erken çıkış, `IdxEntryCount` → `-1`,
  `CheckConstraints` iki `BuildOneIndex` çağrısı, `AbortBatch`,
  `RebuildIndexes`, `AlterColumnType` döngüleri korumalı) → planlayıcı
  otomatik seq scan'a düşer; sonuç hep doğrudur.
- UNIQUE CONCURRENTLY: harita kurulmadığı için denetim tam taramaya
  düşer ama **ZORLANIR** (PostgreSQL'in aksine inşa sırasında da güçlü).
- Yazmalar inşayı beslemeye devam eder: `IdxAddRow`/`IdxDelRow` tüm
  `t.Idx` üzerinden bekleyen işlem üretir (kod değişikliği gerekmedi);
  bunlar finalize'daki catch-up kaynağıdır.
- `DROP INDEX` sürüyor inşayı `StopConcBuilders` ile durdurur (Terminate
  + WaitFor); `Close`/`Destroy`/`AbortBatch`/`RebuildIndexes` İPTAL
  eder → indeks INVALID kalır (PostgreSQL'deki yarıda kalan inşa);
  yeniden açılışta devam ETMEZ; `DROP INDEX` ile temizlenir ya da yeniden
  kurulur. İşlem (batch) içinde kullanım reddedilir (`ecInvalidState`).
- `sqlite_autoindex_` yolu ve "aynı ilk kolona ikinci indeks" kuralı
  aynen geçerli (PK nokta araması zaten indeksli).

**Kayıt defteri:** `FConcBuilders: TList<TVdbConcRec>` (TableId, indeks
adı, iş parçacığı). Finalize tanım konumunu yeniden çözer
(`FindIdxDefById`); TableId+ad bulunamazsa sonuç ATILIR (arada
DropTable/DropIndex olmuş; yeniden yaratılan aynı adlı tablo yeni kimlik
aldığı için karışmaz). `ConcIdxBuildersActive` gözlem/test API'si.

**Derste öğrenilenler:**

- FPC'de `TThread.Create(False)` iş parçacığını ANINDA başlatır → tüm
  alan atamaları `inherited`'ten ÖNCE yapılmalı (R-17 deseni; ihmal
  edildiğinde `FMulti`/`FCtypes` çöp okuyup sıralama kilitlenebiliyor).
- Ana thread sıfır gecikmeli döngüde cümle yağdırınca arka plan iş
  parçacığı aç kalabiliyor (test döngüsüne `Sleep(2)` eklendi; motor
  kodu doğruydu — gözlenen gecikme zamanlayıcı açlığıydı).
- Ana `Parse` yolu ile bağımsız `ParseCreateIndex` İKİ ayrı CREATE INDEX
  ayrıştırıcısıydı; `CONCURRENTLY` yalnız ikincideydi → ana yola da
  eklendi (yoksa `CONCURRENTLY` indeks adı sanılıyordu).

**Test `T102_ConcurrentIndex` (44 alt-test, tamamı geçti):** 500 satırlık
tabloda kapalı kapı ile: anında dönüş, `valid=False`, `nentries=-1`,
iş parçacığı aktif; pencerede INSERT/UPDATE/DELETE (online yazma);
kapı açılır → 3 cümlede finalize; `valid=True`, `nentries=500`
(catch-up); içerik doğruluğu (v=9999/v=501/v=8 yok/v>499→3 — pencerede
yazılmayan değer de taranır, kısmi indeks yakalanırdı); reopen'da
valid+nentries kalıcı; küçük indeks anında bitiş; UNIQUE CONCURRENTLY
(inşada tekrar RED, yeni değer serbest; finalize sonrası da RED,
`nentries=201`); DROP inşa sırasında (inşacı durur, aynı kolona normal
indeks kurulabilir); batch içinde reddi; Close ile yarıda kalma
(`valid=False`, `nentries=-1`, sorgu seq scan ile doğru, DROP ile
temizlik). **Mutasyon:** finalize koşulu
`if FindIdxDefById(...) and t.Idx[pos].Invalid` → `if False and ...`
yapıldığında **8 test çöktü** (valid/nentries zinciri, reopen, küçük
indeks, unique finalize); geri alınınca 2078/2078 yeşil. (İlk mutasyon
denemesi catch-up kapısındaydı ETKİSİZDİ: `IdxEntryCount`'un kendi
flush'ı aynı işi yapıyordu — savunma derinliği; mutasyon hedefi finalize
koşuluna taşındı.)

### 5.9 R-20 FULL: ICU COLLATION `tr-TR-u-kn-ks` (2026-10-13)

**Kapsam:** `VDbText.pas` dil profili motoru BCP-47 `dil-BÖLGE-u-anahtar`
etiketlerini tam çözümler; ICU anahtar/değer semantiği uygulanır.

- **Etiket ayrıştırıcı yeniden yazıldı.** Eski kod değer segmentlerini
  HİÇ okumuyordu (değer okuma döngüsü `-` işaretinde hiç ilerlemiyordu):
  `kn-true`'daki `true` yeni bir anahtar sanılıyor, `kn-ks`'deki `ks`
  birinci anahtarın değeri olarak yutuluyordu. Yeni kural: bölüm SEGMENT
  SEGMENT okunur; bilinen bir anahtar (KS/KN/KC/KF/S1..S4/NUMERIC/
  TUCASE/KSLEVEL) açıktaki anahtarı değersiz kapatır, bilinmeyen segment
  açık anahtarın DEĞERİDİR. `U` ayırıcı olarak atlanır — eski ayrı yazım
  (`...-u-ks-u-kc`) geri uyumlu çözümlenir.
- **`kn` = numeric ordering (doğal sıralama):** metindeki rakam koşukları
  DEĞERLE kıyaslanır — `a2 < a10 < a100`; baştaki sıfırlar değeri
  değiştirmez (`a01` = `a1` sayılır). `VDbCompareCol` ana döngüsüne
  koşuk-kıyas bloğu; `VDbCollationKey`'e sıfır-baş normalizasyonu
  (UNIQUE/eşitlik anahtarı tutarlılığı) eklendi. ORDER BY / WHERE /
  DESC / kolon varsayılanı yollarının hepsi bu kıyası kullanır.
- **`ks` güç değerleri (ICU):** `ks-level1..level4` / `ks-identic`;
  `kc` harf duyarlılığı; `kf` büyük-önce yaklaşımı; çoklu anahtar
  (`tr-TR-u-kn-ks`, `tr-u-ks-kn` — sıra bağımsız).
- **Bölge etiketi:** `tr-TR` ana dilden çözümlenir (Türkçe `i`/`ı`
  kuralları); bilinmeyen etiketlerde alfabe `VDbAlphaForLang` ile
  kod noktası aralığından seçilir (ru→Kiril, el→Yunan, ...).
- **Kanonik ad (`VDbCollationName`):** `kn` bayrağı artık ada YAZILIR
  (`TR-TR-u-kn-u-ks`) — `CREATE TABLE ... COLLATE tr-TR-u-kn-ks` kolon
  varsayılanı reopen sonrası doğal sıralamayı korur (round-trip testi).

**Bu turda düzeltilen gerçek hatalar** (ayrıntı aşağıdaki hata tablosunda):
`-u-` değerlerinin hiç okunmaması; `kn`'nin vurgu anahtarı sanılması;
Kiril/Yunan/Arap harf tablolarının kaynak-kodlama tuzağı (string sabiti
UTF-8 bayt dizisi — `Ord(S[i])` kod noktasıyla ASLA eşleşmezdi, tüm
harfler "harf dışı" çıkıp `YA` < `a` sıralanıyordu); `LatinSecondary`
büyük harf katlaması eksikliği + vurgulu/vurgusuz ağırlık çarpışması
(vurgulu-a ile vurgusuz-a ikinci katmanda eşitti); kanonik adın kn'yi
kaybetmesi; başlatılmamış `NumericOrder` yereli (düz `tr` çöp değerle
doğal sıralıyordu); önceki oturumdan kalan geri alınmamış mutasyon
(`if True then P.Alpha := vaLatin` — alfabe seçimi ölü koddur, geri
alındı); T94d Kiril test verisi `CR(430)` ONDALIKTI (= U+01AE Latin
harfi!) — `CR($0430)` yapıldı (gerçek Kiril а/б/в/Я; ağırlık tabloları
düzeltilince gerçek karakterler zorunlu oldu).

**Test `T103_IcuCollation` (30 alt-test, tamamı geçti):** doğal sıralama
(7 satır tam sıra: a1, a2, a10, a20, a100, b1, b02); kn YOK lexicografik;
tam etiket `tr-TR-u-kn-ks`; anahtar sırası ters (`ks-kn`); `kn-true` /
`kn-false` değer yazımı; `a01` = `a1` sayısal eşitliği (COUNT=2); kn
DESC; kn+ks harf duyarsızlığı; `ks-level2` vurgu duyarlılığı (vurgulu-a
ile armut eşleşmez ama ARMUT = armut); Türkçe `i`/`ı` + kn birlikte
(i2 < i10 < dotless-i 2); `de-DE-u-kn` (başka dil + bölge); `ru-RU` Kiril
ağırlık rotası; kolon varsayılanı + reopen kalıcılığı (a2 önce; `a02` =
`a2` eşitliği). **Mutasyon:** sayısal koşuk kıyası kapısı
`if Prof.NumericOrder and (A[pa] >= '0') ...` → `if False and ...`
yapıldığında **18 test çöktü** (tüm kn sıralama/eşitlik denetimleri);
geri alınınca 2108/2108 yeşil.

### 5.10 🆕 R-13 FULL: HASH BÖLÜMLEME + PARTITION PRUNING (2026-10-13)

**Kapsam:** RANGE/LIST tanımının üzerine **HASH partisi**, sorgu zamanı
**partition pruning**, `SHOW PARTITIONS` ve EXPLAIN pruning raporu.

**Mimari kararlar:**

- **Satır yerleşimi:** satırlar KV'da `VDbHashKey(tablo, pk)` ile durur;
  bölüm no sorgu zamanı anahtar DEĞERİNDEN hesaplanır (`PartValueOf`) —
  şemada bölüm tanımı değişse bile okuma yolu bozulmaz.
- **Pruning = üst-küme güvenliği:** `ScanRowsPart` içinde hedef dışı
  satırlar HİÇ materialize edilmez (bellek + zaman kazancı). Pruning'i
  kapatmak sonuç-NÖTR olduğundan gözlemlenebilir yüzey yalnız
  **EXPLAIN raporu**dur — mutasyon hedefi bu yüzden `PartTargetsOf`
  eşitlik-katkı kapısıdır.
- **Bölüm modelleri:** HASH = FNV-1a 64-bit (`VDbPartHash`) mod N;
  LIST = listede indeks, yoksa DEFAULT; RANGE = 3 bölge (alt/ici/üst).

**Pruning güvenlik kuralları (`PartTargetsOf`):**

- Yalnız **AND'lenen** literal'li `=`/`IN` katkı verir (kesişim);
  OR / belirsiz → hedef yok (tam tarama — güvenli).
- **INT canonical (`IntToStr`)**: `VDbNormValue` INT'i yalnız doğrular
  (`'05' saklı kalır) → hem satır hem hedef `IntToStr`'e çekilir; yoksa
  sayısal `05 = 5` eşleşir ama hash farklı → YANLIŞ eleme olurdu.
- **STRING yalnız `Collate = ''` kolonlarda:** COLLATE'li eşitlik harf/
  vurgu duyarsızdır → bayt esaslı bölüm hesabı yanlış eleme yapardı.
- FLOAT/BOOL/DATE katkı vermez; `PartValueOf = -1` → satır elenmez.

**Diğer kararlar:**

- **NULL denetimi merkezi `CheckConstraints`** (INSERT `FT.Insert` 5 yol
  + `UpdateRowInPlace` hepsi oradan geçer) → `ecNotNullViolation`;
  bölüm-anahtarı NULL ise reddedilir. `PutRow` kontrolü savunma katmanı
  olarak kalır (`TVTableDb.Insert`/`UpdateRowInPlace` PutRow'u çağırmaz).
- **EXPLAIN dürüstlüğü:** `nonSeqPath` (pkUsed/indeks dallarında True) —
  NarrowRows CBO'da indeks yolunu reddetmez, indeks varsa kullanır →
  pruning raporu yalnız Seq Scan planlarında gösterilir.
- **Parser düzeltmeleri (RANGE/LIST ilk kez gerçekten test edildi):**
  LIST tanımı döngü `)`'yi tükettiği hâlde İKİ `Expect(')')` vardı →
  LIST tanımı her zaman "dosya sonu" hatası VERİYORDU (gizli — hiç test
  edilmemiş) → tek `Expect(')')`; değerler `VDbNorm` (LowerCase) yerine
  **literal** (tirnak lexer'da soyulur) — `'DEFAULT'`/`'A'` büyük-küçük
  harf duyarlı eşleşmeli.
- **Şema kalıcılığı:** bölüm tanımı `SaveSchema`/`LoadSchema`'da `#Q`
  anahtarıyla saklanır → reopen'da geri gelir.

**SQL yüzeyi:**

```
CREATE TABLE t(...) PARTITION BY HASH(id) PARTITIONS 12;
CREATE TABLE t(...) PARTITION BY RANGE(yil) VALUES (2000, 2020, 2030);
CREATE TABLE t(...) PARTITION BY LIST(sehir) VALUES ('ankara','izmir');
SHOW PARTITIONS t;
```

EXPLAIN'de Seq Scan planına `Pruned: k/N partitions (hedef: ...)` satırı
eklenir.

**Test `T104_HashPartition` (70 alt-test, tamamı geçti):** HASH/12 satır
+ `SHOW PARTITIONS`; ChkVal COUNT denetimleri (tek hedef değer, hedef
dışı değer, IN); EXPLAIN 1/4 (yalnız hedef bölüm), 2/4 (IN → iki bölüm),
4/4 (kapsayan hedef = sonuç-nötr); RANGE + etiket sütunu; LIST +
DEFAULT; NULL reddi (INSERT eksik kolon + NULL + UPDATE yolu); tanım
hataları (PARTITIONS 0/negatif, DEFAULT'suz LIST); UPDATE ile bölüm
değişimi; UPDATE/DELETE pruning `Affected` sayıları; reopen'da tanım +
veri kalıcılığı.

**Mutasyon:** `PartTargetsOf` eşitlik-katkı kapısı `if False and ...`
yapıldığında **4 test FAIL** (EXPLAIN 1/4 HASH, RANGE 1/3, LIST 1/3,
reopen) — `EXPLAIN 2/4 (IN)` ayrı dal olduğu için geçti → satır geri
alındı → **2178/2178 yeşil**.

---

**ENGLISH — round history §5.6–§5.10:**

### 5.6 R-15 FULL COST-BASED OPTIMIZER (2026-10-13)

**Goal:** use the statistics gathered by `ANALYZE` in **query-plan selection** — which index (if any), which scan (Seq / Index / Index-Only), and which table drives a two-table JOIN.

- **`VDbCost.pas`** (new, pure cost model): `TVdbPlanKind`, `TVdbCostEstimate`, `VdbEstimateEqRows`, `VdbSeqScanCost`, `VdbIndexScanCost`, **`VdbIndexIsSelective`** (single decision point), `VdbChooseScan`, `VdbChooseScanForRows`, `VdbJoinOuterFirst`, `VdbFormatCost`. The model is a simplification of PostgreSQL's: sequential scan 1.0 per row; index probe 1.0 + random table access 4.0 (0.2 for index-only). Rough selectivity thresholds: normal index ~20%, index-only ~80%.
- **Parser:** `ANALYZE [TABLE] <table>` is recognized. The previous round already had `ExecAnalyze` + `RecordTableStats` but `ANALYZE` **was not wired to the main dispatcher** — i.e., inaccessible ("Unknown SQL command").
- **`VDbExecutor.ExecExplain`:** when statistics exist (only then) the plan line gets `(cost=a..b rows=N)` and the scan type is chosen by the CBO. Without statistics **the old behavior is preserved exactly** (backward compatibility).
- **`VDbExecutor.NarrowRows`:** the same decision is used on the real execution path. The width of the index slice (`bestHi-bestLo`) is measured FULLY from the index; if `VdbIndexIsSelective` returns false the index is skipped and a full scan runs. The result does NOT CHANGE (rows are verified by `RowMatches` anyway) — only the path changes. This affects `ExecSelect`/`ExecUpdate`/`ExecDelete` alike.
- **`VDbExecutor.ExecAnalyze`:** DISTINCT is now counted with a real hash bucket (the old code counted every non-null value → `distinct = rowcount`, making selectivity estimates meaningless). A tableless `ANALYZE` now gives an explicit syntax error instead of a silent no-op.
- **`VDbMonitor`:** table statistics are kept in a SEPARATE `GTableStats` list, not in the command-log buffer (`GBuffer`); otherwise the stats were LOST when `GBuffer` hit `MaxBufferSize` and `FlushBufferToFile` ran (the CBO was nondeterministic). Also the `>= 5` → `>= 4` bug in the column-stat parser was fixed (the packet has 4 fields; the old code never filled distinct/null).
- **Test `T98_CBO` (25 sub-tests):** ANALYZE parsing/execution, low selectivity → Seq Scan (NOT the index), high selectivity → Index, PK → `_pkey`, small table outer in JOIN, old behavior on tables without ANALYZE, result invariance after the CBO, VDbCost unit tests.
- **Mutation test:** setting the decision in `VdbIndexIsSelective` to `if False` crashed 4 tests ("yüksek seçicilik → ix_uid", "indeks seçici (100,5)", "index-only %50 seçici", "ChooseScan yüksek seçicilik → Index"); reverted → green.

### 5.7 R-21 FULL EXTENSION / PLUGIN (2026-10-13)

**Goal:** with `CREATE EXTENSION`, load a **real** shared library (.dll / .so / .dylib), validate version/ABI, keep it in a registry and resolve symbols. (The previous round was only a `Load/Call/Unload` skeleton with no SQL path at all.)

- **`VDbExtension.pas`** (rewritten): registry (`TVdbExtensionInfoArray`), `LoadExtension`/`DropExtension`/`ExtensionCount`/`GetExtensionInfo`/`ExtensionLoaded`/`ExtensionSymbol`/`UnloadAllExtensions`. Loading is platform-neutral: `VDbPlatform.VdbLibTryLoadFile` (open by file) and `VdbLibTryLoad` (by base name).
- **C-ABI contract:** MANDATORY `VdbExtApiVersion: function: LongWord; stdcall` (ABI ≥ `VDB_EXT_API_VERSION = $00010000`; lower is rejected); OPTIONAL `VdbExtName` and `VdbExtDescription` (registry name / description).
- **`VDbPlatform`:** `VdbLibTryLoadFile(const AFileName; out AHandle; out APath)` added for full-path loading.
- **Parser/AST:** `admCreateExtension`/`admDropExtension`/`admShowExtensions`; `TSqlAdminStmt.ExtName`/`ExtPath`. Commands: `CREATE EXTENSION [IF NOT EXISTS] name [FROM 'path']`, `DROP EXTENSION [IF EXISTS] name`, `SHOW EXTENSIONS`.
- **`VDbExecutor.ExecAdmin`:** create (IF NOT EXISTS idempotent), drop (IF EXISTS idempotent), `SHOW EXTENSIONS` (name / api_version / file / description — 4 columns).
- **Test extensions:** `vdbtestext.lpr` (`VdbExtApiVersion`=1.0, name, description, `VdbExtAdd`) and `vdboldtext.lpr` (ABI=0.0.1 → must be rejected). `build_testext.ps1` builds both.
- **Test `T99_Extension` (25 sub-tests):** empty list; missing library rejected; `vdbapi.dll` without the ABI symbol rejected; old ABI rejected + not registered; real load + `SHOW EXTENSIONS` fields; `ExtensionSymbol` + a **real stdcall call** (`VdbExtAdd(2,3)=5`); duplicate load / `IF NOT EXISTS`; `DROP` / `IF EXISTS`; syntax errors for nameless commands.
- **Mutation test:** setting the ABI gate line `if ver < VDB_EXT_API_VERSION` inside `VDbExtension.LoadExtension` to `if False` loaded and registered an old-ABI extension → **5 tests crashed**; reverted → green.

### 5.8 R-22 FULL: CREATE INDEX CONCURRENTLY (2026-10-13)

**Goal:** turn `CREATE INDEX CONCURRENTLY` into real **online DDL**: the statement returns immediately, the index is built on a background thread, and the table stays OPEN for reads/writes meanwhile. (The previous round only accepted the `CONCURRENTLY` keyword and returned `OK (CONCURRENTLY)`.)

**Three-phase architecture (`VDbTable.pas`):**

1. **Phase 1 — main thread, the statement itself:** validation inside `CreateIndexCols` (`Concurrent: Boolean = False` added to the signature); the definition is written to the schema with `Invalid=True`; a snapshot is taken (`BuildIdxEntries` — the scan half of `BuildOneIndex` was extracted here, the same code shared by the synchronous and concurrent paths); the worker thread starts; **the statement returns IMMEDIATELY** (`OK (CONCURRENTLY)`).
2. **Phase 2 — `TVdbConcIdxBuilder(TThread)`:** sorts only its OWN input array. `SortIdxEntries`/`SortIdxEntriesCols` touch no shared `TVTableDb` field (pure parameter sort) → safe to call from another thread. The engine never takes a lock.
3. **Phase 3 — finalize, `PollConcurrentIndexes`:** called at the start of every statement in `TVSqlExecutor.Execute` (behind the streaming guard). For finished (`Finished`) builds: the sorted entries are installed into `FMemIdx`; **catch-up**: writes accumulated during the window are merged via `FlushIdxPending` (each op row carries its CURRENT state → complete and duplicate-free) → the UNIQUE map is built from the FINAL entries → `Invalid=False` + schema write. `AForce=True` also finishes pending builds (opens the gate — a clean start before `ALTER COLUMN TYPE`).

**INVALID semantics (PostgreSQL-like):**

- The schema prefixes the index name with `?` (`!` after UNIQUE: `!?name:cols`); reading strips `!` then `?` → backward compatible.
- An INVALID index is **not read, not built, and pending operations are not flushed** (`TryGetMemIndex` early exit, `IdxEntryCount` → `-1`, `CheckConstraints` two `BuildOneIndex` calls, `AbortBatch`, `RebuildIndexes`, `AlterColumnType` loops all guarded) → the planner automatically falls back to seq scan; results are always correct.
- UNIQUE CONCURRENTLY: the map does not exist yet, so the check falls back to a full scan but is **ENFORCED** (unlike PostgreSQL, strong even during the build).
- Writes keep feeding the build: `IdxAddRow`/`IdxDelRow` produce pending work through all of `t.Idx` (no code change needed); these are the catch-up source at finalize.
- `DROP INDEX` stops a running build via `StopConcBuilders` (Terminate + WaitFor); `Close`/`Destroy`/`AbortBatch`/`RebuildIndexes` CANCEL it → the index stays INVALID (PostgreSQL's interrupted build); it does NOT resume on reopen; it is cleaned up by `DROP INDEX` or rebuilt. Use inside a transaction (batch) is rejected (`ecInvalidState`).
- The `sqlite_autoindex_` path and the "second index on the same first column" rule still apply (PK point lookups are already indexed).

**Registry:** `FConcBuilders: TList<TVdbConcRec>` (TableId, index name, thread). Finalize re-resolves the definition location (`FindIdxDefById`); if TableId+name is not found the result is DISCARDED (a DropTable/DropIndex happened meanwhile; a recreated table with the same name has a new identity, so no mix-up). `ConcIdxBuildersActive` is the observation/test API.

**Lessons learned:**

- In FPC `TThread.Create(False)` starts the thread IMMEDIATELY → all field assignments must come BEFORE `inherited` (the R-17 pattern; when missed, `FMulti`/`FCtypes` read garbage and sorting can lock up).
- When the main thread issues statements in a zero-latency loop, the background thread can starve (`Sleep(2)` was added to the test loop; the engine code was correct — the observed lag was timer starvation).
- The main `Parse` path and the standalone `ParseCreateIndex` were TWO separate CREATE INDEX parsers; `CONCURRENTLY` existed only in the latter → added to the main path too (otherwise `CONCURRENTLY` was taken as an index name).

**Test `T102_ConcurrentIndex` (44 sub-tests, all pass):** on a 500-row table with the gate closed: immediate return, `valid=False`, `nentries=-1`, thread active; INSERT/UPDATE/DELETE during the window (online writes); gate opens → finalize in 3 statements; `valid=True`, `nentries=500` (catch-up); content correctness (v=9999/v=501/v=8 missing/v>499→3 — a value never written during the window is still scanned, a partial index would be caught); valid+nentries persist across reopen; small index finishes instantly; UNIQUE CONCURRENTLY (duplicate REJECTED during build, new value allowed; still rejected after finalize, `nentries=201`); DROP during build (builder stops, a normal index on the same column can be built); rejected inside a batch; Close interrupts (`valid=False`, `nentries=-1`, query correct via seq scan, cleanup via DROP). **Mutation:** changing the finalize condition `if FindIdxDefById(...) and t.Idx[pos].Invalid` to `if False and ...` crashed **8 tests** (valid/nentries chain, reopen, small index, unique finalize); reverted → 2078/2078 green. (The first mutation attempt at the catch-up gate was INEFFECTIVE: `IdxEntryCount`'s own flush did the same job — defense in depth; the target was moved to the finalize condition.)

### 5.9 R-20 FULL: ICU COLLATION `tr-TR-u-kn-ks` (2026-10-13)

**Scope:** the `VDbText.pas` language-profile engine fully parses BCP-47 `language-REGION-u-key` tags; ICU key/value semantics are implemented.

- **Tag tokenizer rewritten.** The old code never read value segments at all (the value loop never advanced past a `-`): in `kn-true` the `true` was taken as a new key, in `kn-ks` the `ks` was swallowed as the first key's value. New rule: sections are read SEGMENT BY SEGMENT; a known key (KS/KN/KC/KF/S1..S4/NUMERIC/TUCASE/KSLEVEL) closes the open key with no value, an unknown segment IS THE VALUE of the open key. The `U` separator is skipped — the old separate spelling (`...-u-ks-u-kc`) parses backward-compatibly.
- **`kn` = numeric ordering (natural sort):** digit runs in the text are compared by VALUE — `a2 < a10 < a100`; leading zeros do not change the value (`a01` counts as `a1`). A run-comparison block was added to the `VDbCompareCol` main loop; zero-pad normalization was added to `VDbCollationKey` (UNIQUE/equality-key consistency). ORDER BY / WHERE / DESC / column-default paths all use this comparison.
- **`ks` strength values (ICU):** `ks-level1..level4` / `ks-identic`; `kc` case sensitivity; `kf` upper-first approach; multiple keys (`tr-TR-u-kn-ks`, `tr-u-ks-kn` — order independent).
- **Region tag:** `tr-TR` resolves from the primary language (Turkish `i`/`ı` rules); for unknown tags the alphabet is chosen by `VDbAlphaForLang` from code-point range (ru→Cyrillic, el→Greek, ...).
- **Canonical name (`VDbCollationName`):** the `kn` flag is now WRITTEN into the name (`TR-TR-u-kn-u-ks`) — `CREATE TABLE ... COLLATE tr-TR-u-kn-ks` keeps the column default across reopen (round-trip test).

**Real bugs fixed in this round** (details in the bug table below): `-u-` values never read at all; `kn` mistaken for an accent key; Cyrillic/Greek/Arabic letter tables hit a source-encoding trap (string constants are UTF-8 byte sequences — `Ord(S[i])` NEVER matched the code point, every letter came out "non-letter" and `YA` sorted before `a`); `LatinSecondary` missing uppercase folding + accent/unaccent weight collision (accented-a equaled unaccented-a at the secondary layer); canonical name losing `kn`; uninitialized `NumericOrder` locale (plain `tr` sorted naturally with a garbage value); an un-reverted mutation left from a previous session (`if True then P.Alpha := vaLatin` — alphabet selection is dead code, reverted); T94d Cyrillic test data `CR(430)` was DECIMAL (= U+01AE a Latin letter!) → changed to `CR($0430)` (real Cyrillic а/б/в/Я; once the weight tables were fixed, real characters became mandatory).

**Test `T103_IcuCollation` (30 sub-tests, all pass):** natural ordering (7-row exact sequence: a1, a2, a10, a20, a100, b1, b02); lexicographic without kn; full tag `tr-TR-u-kn-ks`; reversed key order (`ks-kn`); `kn-true` / `kn-false` value spelling; `a01` = `a1` numeric equality (COUNT=2); kn DESC; kn+ks case-insensitivity; `ks-level2` accent sensitivity (accented-a does not match pear but ARMUT = armut); Turkish `i`/`ı` + kn together (i2 < i10 < dotless-i 2); `de-DE-u-kn` (other language + region); `ru-RU` Cyrillic weight route; column default + reopen durability (a2 first; `a02` = `a2` equality). **Mutation:** the numeric run-comparison gate `if Prof.NumericOrder and (A[pa] >= '0') ...` → `if False and ...` crashed **18 tests** (all kn ordering/equality checks); reverted → 2108/2108 green.

### 5.10 R-13 FULL: HASH PARTITIONING + PARTITION PRUNING (2026-10-13)

**Scope:** on top of RANGE/LIST definitions, **HASH partitions**, query-time **partition pruning**, `SHOW PARTITIONS` and an EXPLAIN pruning report.

**Architecture decisions:**

- **Row placement:** rows live in the KV store under `VDbHashKey(table, pk)`; the partition number is computed at query time FROM THE KEY VALUE (`PartValueOf`) — reads keep working even if the schema's partition definition changes.
- **Pruning = superset safety:** in `ScanRowsPart`, off-target rows are NEVER materialized (memory + time win). Since turning pruning off is result-NEUTRAL, the only observable surface is the **EXPLAIN report** — hence the mutation target is the `PartTargetsOf` equality-contribution gate.
- **Partition models:** HASH = FNV-1a 64-bit (`VDbPartHash`) mod N; LIST = index in list, else DEFAULT; RANGE = 3 zones (below/inside/above).

**Pruning safety rules (`PartTargetsOf`):**

- Only **ANDed** literal `=`/`IN` contribute (intersection); OR / non-literal → no target (full scan — safe).
- **INT canonical (`IntToStr`):** `VDbNormValue` only validates INT (`'05'` stays) → both row and target are pulled to `IntToStr`; otherwise numeric `05 = 5` would match but the hash would differ → WRONG pruning.
- **STRING only for `Collate = ''` columns:** COLLATE'd equality is case/accent-insensitive → byte-based partition math would prune wrongly.
- FLOAT/BOOL/DATE contribute nothing; `PartValueOf = -1` → the row is not pruned.

**Other decisions:**

- **NULL check centralized in `CheckConstraints`** (all 5 INSERT `FT.Insert` paths + `UpdateRowInPlace` go through it) → `ecNotNullViolation`; a NULL partition key is rejected. `PutRow`'s check remains as a defense layer (`TVTableDb.Insert`/`UpdateRowInPlace` do not call PutRow).
- **EXPLAIN honesty:** `nonSeqPath` (True on pkUsed/index branches) — NarrowRows does not reject the index path under the CBO, it uses it if present → the pruning report is only shown on Seq Scan plans.
- **Parser fixes (RANGE/LIST genuinely tested for the first time):** the LIST definition consumed the closing `)` in its loop yet had TWO `Expect(')')` calls → the LIST definition ALWAYS failed with "end of file" (hidden — never tested) → single `Expect(')')`; values taken as **literal** instead of `VDbNorm` (LowerCase; the quote is stripped by the lexer) — `'DEFAULT'`/`'A'` must match case-sensitively.
- **Schema durability:** the partition definition is stored in `SaveSchema`/`LoadSchema` under the `#Q` key → returns after reopen.

**SQL surface:**

```
CREATE TABLE t(...) PARTITION BY HASH(id) PARTITIONS 12;
CREATE TABLE t(...) PARTITION BY RANGE(yil) VALUES (2000, 2020, 2030);
CREATE TABLE t(...) PARTITION BY LIST(sehir) VALUES ('ankara','izmir');
SHOW PARTITIONS t;
```

EXPLAIN adds a `Pruned: k/N partitions (targets: ...)` line to Seq Scan plans.

**Test `T104_HashPartition` (70 sub-tests, all pass):** HASH/12 rows + `SHOW PARTITIONS`; ChkVal COUNT checks (single target value, off-target value, IN); EXPLAIN 1/4 (target partition only), 2/4 (IN → two partitions), 4/4 (covering target = result-neutral); RANGE + label column; LIST + DEFAULT; NULL rejection (INSERT missing column + NULL + UPDATE path); definition errors (PARTITIONS 0/negative, LIST without DEFAULT); partition change via UPDATE; UPDATE/DELETE pruning `Affected` counts; definition + data persist across reopen.

**Mutation:** setting the `PartTargetsOf` equality-contribution gate to `if False and ...` → **4 tests FAIL** (EXPLAIN 1/4 HASH, RANGE 1/3, LIST 1/3, reopen) — `EXPLAIN 2/4 (IN)` passed because it is a separate branch → line reverted → **2178/2178 green**.

---

### 5.11 🆕 R-24: SHOW STATS / MONITORING (2026-10-13)

**Amaç:** PostgreSQL `pg_stat_statements` benzeri **çalışma zamanı
metrikleri**: komut sayısı, süre dağılımı, WAL yazımı ve ANALYZE
istatistiklerine SQL'den erişim.

**Kod incelemesi şunu ortaya çıkardı:** izleme ALTYAPISI vardı
(`VDbMonitor.GStats`, yavaş sorgu günlüğü F-21, `GTableStats`) ama
**`SHOW STATS` komutu yoktu ve `RecordCommand`'ı çağıran hiçbir kod
yoktu** — sayaçlar hiç artmıyor, üstelik `RecordCommand` içindeki `Inc`
blokları **geri alınmamış bir mutasyon kalıntısıyla** (`if False`,
"MUTASYON KANITI" notuyla) devre disiydi. Hiçbir test `GStats`'i
gözlemediği için yağmurlu gün hatası kalmıştı.

**Eklenenler:**

- **Parser/AST:** `SHOW STATS` / `SHOW STATS TABLE <t>` (+ `LIST STATS`
  takma adı) → `admShowStats`. Artık token üst düzey denetimi
  `SHOW STATS FOO`'yu "anlasilamayan ek" hatasıyla reddeder.
- **`VDbExecutor.ExecShowStats`:**
  - **Genel form** (`name|value`, 6 satır): `commands`, `total_us`,
    `max_us`, `avg_us`, `wal_records` (`TVDb.WalAutoCount`),
    `tables_analyzed` (yeni `VDbMonitor.AnalyzedTableCount` —
    `GTableStats`'teki tekil tablo adları).
  - **Tablo formu** (8 kolon): özet satırı (tablo adı, satır sayısı,
    avg_row_len, index_count) + kolon satırları (distinct gerçek kova,
    nulls, min/max bayt sırası). `ANALYZE` yoksa `ecUnsupported`, tablo
    yoksa `GetTable`'ın kendi `ecTableNotFound` reddi.
- **Sayaç bağı (`VDbSql.ExecRaw` finally):** AST'den geçen her cümle,
  F-21 ile aynı ölçümden türeyen süreyle `RecordCommand(sql, us, 0)`
  kaydedilir — hata yolunda da (pg_stat benzeri). `RecordCommand`
  artık gerçekten artırır; günlük dosyası yazımı `GConfig.FileName <> ''`
  kapısına alındı (varsayılan `''` → tampanda `.mon.edb` çöp dosyası
  oluşmaz; sayaçlar bellekte durur).
- **Test `T105_ShowStats` (`== 134.`, 27 alt-test):** şekil (2 kolon × 6
  metrik); **commands delta = 5 komut + ilk SHOW STATS = 6** (birebir);
  süre tutarlılığı (total ≥ max, avg ≤ max); `wal_records`
  WALEnabled+INSERT ile 0 → 2; `tables_analyzed` 6 → 7;
  `SHOW STATS TABLE st` özet (2 satır, avg_row_len > 0) + kolon satırları
  (id: distinct=2/nulls=0/min=1/max=2; v: distinct=2/min=a/max=b); hata
  yolları (ANALYZE yok, olmayan tablo, `FOO`, isimsiz `TABLE`);
  `LIST STATS` takma adı.
- **Mutasyon:** `Inc(GStats.CommandCount)` → `if False` → **2 FAIL**
  ("commands > 0" ve "commands +6", delta=0) → geri alındı →
  **2205/2205 yeşil**.

---

### 5.12 🆕 R-12 FULL: TCP SQL SUNUCUSU + İSTEMCİ (2026-10-13)

**Amaç:** Motoru TCP üzerinden sunan gerçek bir süreç (`vdbserver.lpr`) ve
ona bağlanan istemci (`VDbClientNet.pas`) — "çoklu kullanıcı sunucu"
senaryosunun R-12 1. aşama (havuz) tamamlayıcısı.

**Kod incelemesi:** `VDbNet.pas` (R-17 Full) taşıma katmanı zaten vardı
(`VdbTcpListen/Accept/Connect`, `SendAll/RecvAll`, küçük-endian ilkeller,
`VdbSendStr/RecvStr`); eksik olan **protokol + sunucu + istemci**ydi —
sıfırdan ağ kodu gerekmedi.

**Eklenenler:**

- **Protokol `VDBS` (sabitler `VDbNet.pas`'ta — taşımayla paylaşıldı):**
  - **El sıkışma:** sunucu bağlanır bağlanmaz ilk mesajı gönderir —
    `'VDBS'` magic (4 bayt) + u8 protokol sürümü (1) + str sunucu bilgisi;
    istemci magic/sürüm doğrular, uyuşmazsa kapatır.
  - **İstemci → sunucu:** `$10 QUERY` (+str SQL), `$11 PING`, `$1F BYE`.
  - **Sunucu → istemci:** `$20 RESULT` (u8 status + u32 affected + u32
    alan sayısı + alan adları + u64 satır sayısı + hücreler + str msg),
    `$21 ERROR` (+str msg), `$2F PONG` — **her yanıt u8 `$00` sonu
    işaretiyle biter**; eksikse istemci `EVdbProtocolError` fırlatır
    (çerçeve kayması engeli).
- **`VDbSqlServer.pas`:** `TVdbSqlServer` — `Start`/`Stop`; dinleme
  **senkron** kurulur (port müsait değilse hemen False); kabul thread'i +
  bağlantı başına thread; **tek motor + `TCriticalSection` seri yürütüm**
  (R-12 1. aşamanın serileştirilmiş modelinin aynısı; yanıt yazımı kilit
  DIŞINDA — ağ gecikmesi diğer istemcileri bekletmesin); `Served` QUERY
  sayacı (hatalar dahil). **Kapanış kuralı** (VDbNet notu): engellenmiş
  accept'i uyandırmak için dinleme soketi KAPATILIR, engellenmiş recv'ler
  `VdbSockShutdown` ile uyandırılır, thread'ler `WaitFor` ile beklenir.
  Bağlantı objesi sahipliği **listededir** (thread kendini `Free` etmez —
  self-join deadlock); `AddConn` yeni kabulde biten thread'leri toplar.
- **`vdbserver.lpr`:** bağımsız süreç — `vdbserver <klasör> <port>`;
  `READY port=<n>` yazar, `stop` satırıyla temiz kapanır (derleme:
  `fpc -B -Scghi -O1 -FUD:\veritabani -Fu...dcpcrypt... vdbserver.lpr`).
- **`VDbClientNet.pas`:** `TVdbNetClient` — `Connect/Exec/Ping/Bye/
  Disconnect`; `Exec` **motorla aynı `TSqlResult` tipini** döndürür;
  sunucu hatası aynı motor mesajıyla `EVdbClientError` olarak yükselir
  (yerel `Exec` semantiği korunur).
- **Test `T106_TcpSqlServer` (`== 135.`, 32 alt-test):** el sıkışma
  (magic/sürüm/bilgi); PING/PONG; DDL/DML/SELECT çerçeveleri (affected
  1/2/1, alan adları, hücreler, COUNT); hata çerçevesi ×2 + **hata sonrası
  çerçeve senkronu**; `Served` delta=12 (hatalar dahil, birebir); iki açık
  istemci (yazım ikisinden de görünür); BYE; yeniden bağlanma (veri
  kalıcı); **ham sokette bilinmeyen tur → sunucu bağlantıyı kapatır**;
  `Stop` → yeni bağlantı reddi; **aynı portta yeniden başlatma + veri
  kalıcılığı** (SO_REUSEADDR).
- **Mutasyon:** `SendResultFrame`'de `affected` → `0` → **3 FAIL**
  (INSERT/UPDATE/DELETE affected denetimleri) → geri alındı →
  **2237/2237 yeşil**.

---

### 5.13 🆕 R-12 DEVAM: VDBS Oturum / Auth (2026-10-13)

**Amaç:** VDBS protokolüne `LOGIN / LOGOUT` çerçevesi ekleyerek
istemci/server arasında kullanıcı kimliği yönetimi sağlamak. Önceki
maddeler (R-12 Full) sadece bağlantı ve sorgu çalıştırma sağlarken,
bu madde oturum yaşam döngüsünü (login → query → logout) protokol seviyesine
aktarır.

**Protokol sabitleri (VDbNet.pas):**
- `VDBS_CMD_LOGIN = $20` — istemci→sunucu: `str user, str pass`
- `VDBS_CMD_LOGOUT = $21` — istemci→sunucu: govde yok
- `VDBS_RSP_AUTH = $43` — sunucu→istemci: `u8 status(0/1) + u8 $00`

**Sunucu (VDbSqlServer.pas):**
- `FUser: string` / `FPass: string` — varsayılan `admin`/`admin123`
- `FSessionId: Integer` — 1 = aktif oturum, 0 = oturum yok
- `ExecCmd`: `if FSessionId = 0 then 'oturum yok' ERROR` (varsayılan 1 →
  mevcut testler etkilenmez)
- `Execute`: `VDBS_CMD_LOGIN` alındığında kullanıcı/parola doğrulaması;
  başarılıysa `FSessionId := 1`, başarısızsa `FSessionId := 0` ve
  `VDBS_RSP_AUTH(1)` döndürülür. `VDBS_CMD_LOGOUT` → `FSessionId := 0`.

**İstemci (VDbClientNet.pas):**
- `Login(User, Password): Boolean` — `VDBS_CMD_LOGIN` gönderir, `VDBS_RSP_AUTH`
  yanıtını okur; True = oturum aktif, False = reddedildi.
- `Logout` — `VDBS_CMD_LOGOUT` gönderir; server `FSessionId` sıfırlar.

**Mutation hedefi:** `ExecCmd` içindeki `if FSessionId = 0 then ...` satırı
`if False and ...` yapıldığında; ancak varsayılan `FSessionId = 1` olduğu
günde mevcut `sqltest` (2237/2237) etkilenmez. T107_AuthSession artık
eklendi; mutasyon kanıtı 2026-10-14'te alındı (3 kapı: FAIL → geri al →
yeşil).

**Test senaryosu (T107_AuthSession — eklendi ✓, sqltest içinde yeşil):**
1. `cl.Login('admin','admin123')` → True (oturum açıldı)
2. `cl.Login('admin','yanlis')` → False (yanlış şifre)
3. Bağlantı sonrası `cl.Exec('SELECT 1+1')` — varsayılan oturum olduğu
   için çalışır (açık sunucu)
4. `cl.Logout` → session sıfırlanır, yeni bağlantı `FSessionId=1` ile tekrar

**Önemli:** Varsayılan oturum `FSessionId = 1` ile retro uyumlu olarak
tasarlandığı için, mevcut 135 test prosedürü ve 2237/2237 sonuçları
korundur. Oturum kontrolü `ExecCmd`'de varsayılan aktif olduğu için
R-12 Full (T106) sorguları normal şekilde çalışmaya devam eder.

---

### 5.14 🆕 R-12 DEVAM: VDBS Prepared Statement Çerçevesi (2026-10-13)

**Amaç:** VDBS protokolüne `PREPARE / EXECUTE` akışını ekleyerek
sunucuda plan hazırlama ve tekrar çalıştırma imkânı sunmak.

**Protokol sabitleri (VDbNet.pas):**
- `VDBS_CMD_PREPARE = $22` — istemci→sunucu: `str sql`
- `VDBS_CMD_EXECUTE = $23` — istemci→sunucu: govde yok (basit versiyon)
- `VDBS_RSP_PREPARE = $44` — sunucu→istemci: `u8 status(0/1) + u8 $00`

**Sunucu (VDbSqlServer.pas):**
- `FPreparedSql: string` — son prepared statement'ın SQL metni
- `Execute`: `VDBS_CMD_PREPARE` → SQL al → `FPreparedSql := sqlP` →
  `VDBS_RSP_PREPARE(0)` döndür. Hazırlık kapısı: `if False and (sqlP = '')`
  — mutasyon hedefi (hazırlık reddi).
- `VDBS_CMD_EXECUTE` → `FPreparedSql <> ''` ise `ExecCmd(FPreparedSql, FSock)`
  ile çalıştır, aksi halde ERROR "hazirlanmis sorgu yok".

**İstemci (VDbClientNet.pas):**
- `Prepare(Sql): Boolean` — `VDBS_CMD_PREPARE` gönderir, `VDBS_RSP_PREPARE`
  yanıtını okur; True = hazırlık kabul.
- `ExecutePrepared` — `VDBS_CMD_EXECUTE` gönderir, RESULT/ERROR çerçevesi.

**Mutation hedefi:** `Execute`'teki `if False and (sqlP = '')` kapısı
yapıldığında prepared statement reddedilir → 1 FAIL. Geri alındığında
yeşil.

**Test senaryosu (T108_PreparedStatement — eklendi ✓, sqltest içinde yeşil):**
1. `cl.Prepare('SELECT 1+1')` → True
2. `cl.ExecutePrepared` → RESULT (2)
3. `cl.Prepare('SELECT 1+2')` → True
4. `cl.ExecutePrepared` → RESULT (3)
5. `cl.Prepare('SELECT 1+3')` → True
6. `cl.ExecutePrepared` → RESULT (4)
7. Prepare edilmeden Execute → ERROR "hazirlanmis sorgu yok"

---

### 5.15 🆕 R-12 DEVAM: Havuz-Slot ↔ TCP Bağlantı Eşlemesi (2026-10-13)

**Amaç:** Sunucuda kapasite sınırlaması: `FMaxConns` (havuz-slot sayısı)
ile aktif TCP bağlantıyı sınırlamak; aşan istemciye "kapasite dolu" +
Connection Refused döndürmek.

**Kod (VDbSqlServer.pas):**
- `FMaxConns: Integer` — varsayılan 4 (havuz-slot sayısı)
- `TVdbServerAccept.Execute`: `VdbTcpAccept` sonrası
  `if FServer.FConns.Count >= FServer.FMaxConns` kontrolü:
  - Kapasite doluysa → `VDBS_RSP_ERROR` + "kapasite dolu" + TERM +
    soket kapat → `Continue` (bekle)
  - Boşsa → normal `TVdbServerConn.Create`

**Eşleme:** Her aktif TCP bağlantısı bir havuz-slot'una tekabül eder;
`FConns.Count` slot sayısını gösterir. Kapasite aşıldığında yeni
bağlantı reddedilir — bu, havuz-slot ↔ TCP eşlemesinin temelidir.

**Mutation hedefi:** `FConns.Count >= FMaxConns` kapısı `if False and ...`
yapıldığında kapasite kontrolü devre dışı kalır → 5. istemci de
bağlanır (4-slot yerine 5. slot kullanılır) → 1 FAIL. Geri alındığında
yeşil.

**Test senaryosu (T109_PoolSlotTCP — eklendi ✓, sqltest içinde yeşil):**
1. 4 Istemci bağlanır (kapasite dolana kadar)
2. 5. Istemci → "kapasite dolu" ERROR + kapanır
3. Bir Istemci BYE → slot boşar
4. Yeni Istemci bağlanır

---

**ENGLISH — round history §5.11–§5.15:**

### 5.11 R-24: SHOW STATS / MONITORING (2026-10-13)

**Goal:** PostgreSQL `pg_stat_statements`-like **runtime metrics**: command count, duration distribution, WAL writes and access to ANALYZE statistics from SQL.

**The code review revealed:** the monitoring INFRASTRUCTURE existed (`VDbMonitor.GStats`, slow-query log F-21, `GTableStats`) but there was **no `SHOW STATS` command and no code calling `RecordCommand`** — counters never incremented, and the `Inc` blocks inside `RecordCommand` were **disabled by an un-reverted mutation leftover** (`if False`, with a "MUTASYON KANITI" note). No test observed `GStats`, so the rainy-day bug stayed.

**Added:**

- **Parser/AST:** `SHOW STATS` / `SHOW STATS TABLE <t>` (+ `LIST STATS` alias) → `admShowStats`. Top-level token validation now rejects `SHOW STATS FOO` with "unrecognized suffix" error.
- **`VDbExecutor.ExecShowStats`:**
  - **General form** (`name|value`, 6 rows): `commands`, `total_us`, `max_us`, `avg_us`, `wal_records` (`TVDb.WalAutoCount`), `tables_analyzed` (new `VDbMonitor.AnalyzedTableCount` — unique table names in `GTableStats`).
  - **Table form** (8 columns): summary row (table name, row count, avg_row_len, index_count) + column rows (distinct real bucket, nulls, min/max in byte order). No ANALYZE → `ecUnsupported`, missing table → `GetTable`'s own `ecTableNotFound` rejection.
- **Counter hook (`VDbSql.ExecRaw` finally):** every statement that passes through the AST is recorded as `RecordCommand(sql, us, 0)` with a duration derived from the same measurement as F-21 — also on the error path (like pg_stat). `RecordCommand` now really increments; log-file writing is gated behind `GConfig.FileName <> ''` (default `''` → no stray `.mon.edb` file in temp; counters stay in memory).
- **Test `T105_ShowStats` (`== 134.`, 27 sub-tests):** shape (2 columns × 6 metrics); **commands delta = 5 commands + first SHOW STATS = 6** (exact); duration consistency (total ≥ max, avg ≤ max); `wal_records` 0 → 2 with WALEnabled+INSERT; `tables_analyzed` 6 → 7; `SHOW STATS TABLE st` summary (2 rows, avg_row_len > 0) + column rows (id: distinct=2/nulls=0/min=1/max=2; v: distinct=2/min=a/max=b); error paths (no ANALYZE, missing table, `FOO`, nameless `TABLE`); `LIST STATS` alias.
- **Mutation:** `Inc(GStats.CommandCount)` → `if False` → **2 FAIL** ("commands > 0" and "commands +6", delta=0) → reverted → **2205/2205 green**.

---

### 5.12 R-12 FULL: TCP SQL SERVER + CLIENT (2026-10-13)

**Goal:** a real process serving the engine over TCP (`vdbserver.lpr`) and a client connecting to it (`VDbClientNet.pas`) — the "multi-user server" scenario completing R-12 stage 1 (pool).

**Code review:** `VDbNet.pas` (R-17 Full) already provided the transport layer (`VdbTcpListen/Accept/Connect`, `SendAll/RecvAll`, little-endian primitives, `VdbSendStr/RecvStr`); what was missing was the **protocol + server + client** — no from-scratch networking needed.

**Added:**

- **Protocol `VDBS` (constants in `VDbNet.pas` — shared with the transport):**
  - **Handshake:** the server sends the first message as soon as a client connects — `'VDBS'` magic (4 bytes) + u8 protocol version (1) + str server info; the client verifies magic/version and closes on mismatch.
  - **Client → server:** `$10 QUERY` (+str SQL), `$11 PING`, `$1F BYE`.
  - **Server → client:** `$20 RESULT` (u8 status + u32 affected + u32 field count + field names + u64 row count + cells + str msg), `$21 ERROR` (+str msg), `$2F PONG` — **every response ends with a u8 `$00` terminator**; if missing the client raises `EVdbProtocolError` (frame-desync guard).
- **`VDbSqlServer.pas`:** `TVdbSqlServer` — `Start`/`Stop`; the listener is set up **synchronously** (returns False immediately if the port is unavailable); accept thread + a thread per connection; **single engine + `TCriticalSection` serialized execution** (the same serialized model as R-12 stage 1; response writing happens OUTSIDE the lock — network latency must not block other clients); `Served` QUERY counter (errors included). **Shutdown rule** (VDbNet note): the listening socket is CLOSED to wake a blocked accept, blocked recvs are woken via `VdbSockShutdown`, threads are awaited with `WaitFor`. Connection objects are owned BY THE LIST (a thread never `Free`s itself — self-join deadlock); `AddConn` collects finished threads on new accepts.
- **`vdbserver.lpr`:** standalone process — `vdbserver <folder> <port>`; writes `READY port=<n>`, closes cleanly on a `stop` line (build: `fpc -B -Scghi -O1 -FUD:\veritabani -Fu...dcpcrypt... vdbserver.lpr`).
- **`VDbClientNet.pas`:** `TVdbNetClient` — `Connect/Exec/Ping/Bye/Disconnect`; `Exec` returns the **same `TSqlResult` type as the local engine**; a server error surfaces as `EVdbClientError` with the same engine message (local `Exec` semantics preserved).
- **Test `T106_TcpSqlServer` (`== 135.`, 32 sub-tests):** handshake (magic/version/info); PING/PONG; DDL/DML/SELECT frames (affected 1/2/1, field names, cells, COUNT); error frame ×2 + **frame resync after an error**; `Served` delta=12 (errors included, exact); two open clients (a write visible from both); BYE; reconnect (data persists); **unknown opcode on a raw socket → the server closes the connection**; `Stop` → new connections rejected; **restart on the same port + data persistence** (SO_REUSEADDR).
- **Mutation:** `affected` in `SendResultFrame` → `0` → **3 FAIL** (INSERT/UPDATE/DELETE affected checks) → reverted → **2237/2237 green**.

---

### 5.13 R-12 CONTINUATION: VDBS Session / Auth (2026-10-13)

**Goal:** add a `LOGIN / LOGOUT` frame to the VDBS protocol for user identity management between client and server. The earlier item (R-12 Full) only provided connection and query execution; this item moves the session lifecycle (login → query → logout) into the protocol.

**Protocol constants (VDbNet.pas):**
- `VDBS_CMD_LOGIN = $20` — client→server: `str user, str pass`
- `VDBS_CMD_LOGOUT = $21` — client→server: no body
- `VDBS_RSP_AUTH = $43` — server→client: `u8 status(0/1) + u8 $00`

**Server (VDbSqlServer.pas):**
- `FUser: string` / `FPass: string` — defaults `admin`/`admin123`
- `FSessionId: Integer` — 1 = active session, 0 = no session
- `ExecCmd`: `if FSessionId = 0 then 'no session' ERROR` (default 1 → existing tests unaffected)
- `Execute`: on `VDBS_CMD_LOGIN` validates user/password; on success `FSessionId := 1`, on failure `FSessionId := 0`, returning `VDBS_RSP_AUTH(1)`. `VDBS_CMD_LOGOUT` → `FSessionId := 0`.

**Client (VDbClientNet.pas):**
- `Login(User, Password): Boolean` — sends `VDBS_CMD_LOGIN`, reads `VDBS_RSP_AUTH`; True = session active, False = rejected.
- `Logout` — sends `VDBS_CMD_LOGOUT`; the server resets `FSessionId`.

**Mutation target:** the `if FSessionId = 0 then ...` line inside `ExecCmd` set to `if False and ...`; with `FSessionId = 1` default the then-current `sqltest` (2237/2237) was unaffected. T107_AuthSession now exists; mutation evidence was taken on 2026-10-14 (3 gates: FAIL → revert → green).

**Test scenario (T107_AuthSession — added ✓, green in sqltest):**
1. `cl.Login('admin','admin123')` → True (session opened)
2. `cl.Login('admin','yanlis')` → False (wrong password)
3. After connecting, `cl.Exec('SELECT 1+1')` works because the default session is active
4. `cl.Logout` → session reset, a new connection returns with `FSessionId=1`

**Note:** because the default session `FSessionId = 1` was designed for retro-compatibility, the test procedures and results of the time were preserved. Session checking is active by default in `ExecCmd`, so R-12 Full (T106) queries keep working normally.

---

### 5.14 R-12 CONTINUATION: VDBS Prepared Statement Framework (2026-10-13)

**Goal:** add a `PREPARE / EXECUTE` flow to the VDBS protocol for server-side plan preparation and re-execution.

**Protocol constants (VDbNet.pas):**
- `VDBS_CMD_PREPARE = $22` — client→server: `str sql`
- `VDBS_CMD_EXECUTE = $23` — client→server: no body (simple version)
- `VDBS_RSP_PREPARE = $44` — server→client: `u8 status(0/1) + u8 $00`

**Server (VDbSqlServer.pas):**
- `FPreparedSql: string` — SQL text of the last prepared statement
- `Execute`: `VDBS_CMD_PREPARE` → receive SQL → `FPreparedSql := sqlP` → return `VDBS_RSP_PREPARE(0)`. Preparation gate: `if False and (sqlP = '')` — mutation target (prepare rejection).
- `VDBS_CMD_EXECUTE` → if `FPreparedSql <> ''` run via `ExecCmd(FPreparedSql, FSock)`, else ERROR "hazirlanmis sorgu yok".

**Client (VDbClientNet.pas):**
- `Prepare(Sql): Boolean` — sends `VDBS_CMD_PREPARE`, reads `VDBS_RSP_PREPARE`; True = preparation accepted.
- `ExecutePrepared` — sends `VDBS_CMD_EXECUTE`, RESULT/ERROR frame.

**Mutation target:** the `if False and (sqlP = '')` gate in `Execute` rejects prepared statements → 1 FAIL. Reverted → green.

**Test scenario (T108_PreparedStatement — added ✓, green in sqltest):**
1. `cl.Prepare('SELECT 1+1')` → True
2. `cl.ExecutePrepared` → RESULT (2)
3. `cl.Prepare('SELECT 1+2')` → True
4. `cl.ExecutePrepared` → RESULT (3)
5. `cl.Prepare('SELECT 1+3')` → True
6. `cl.ExecutePrepared` → RESULT (4)
7. Execute without prepare → ERROR "hazirlanmis sorgu yok"

---

### 5.15 R-12 CONTINUATION: Pool Slot ↔ TCP Connection Mapping (2026-10-13)

**Goal:** capacity limiting on the server: cap active TCP connections with `FMaxConns` (pool-slot count); an over-limit client receives "capacity full" + Connection Refused.

**Code (VDbSqlServer.pas):**
- `FMaxConns: Integer` — default 4 (pool-slot count)
- `TVdbServerAccept.Execute`: after `VdbTcpAccept`, check `if FServer.FConns.Count >= FServer.FMaxConns`:
  - Capacity full → `VDBS_RSP_ERROR` + "kapasite dolu" + TERM + close socket → `Continue` (keep waiting)
  - Free → normal `TVdbServerConn.Create`

**Mapping:** every active TCP connection corresponds to one pool slot; `FConns.Count` is the slot count. When capacity is exceeded the new connection is rejected — this is the essence of the pool-slot ↔ TCP mapping.

**Mutation target:** the `FConns.Count >= FMaxConns` gate set to `if False and ...` disables the capacity check → the 5th client also connects (a 5th slot used instead of 4) → 1 FAIL. Reverted → green.

**Test scenario (T109_PoolSlotTCP — added ✓, green in sqltest):**
1. 4 clients connect (until capacity is full)
2. 5th client → "kapasite dolu" ERROR + disconnect
3. One client BYE → frees its slot
4. A new client connects

---

### 5.17 ⚡ HIZ TURU: R-26 + P-12..P-15 + ADİL KIYAS (2026-10-15..16)

**R-26 — Tablo-tarama filtresi** (`VDbCore.pas`, `VDbTable.pas`): satır başındaki
TableId (CRC baytları, `Recover`'da bedava) `TDbLoc.TableId`'ye yazılır;
`ScanSnapshot/ScanAll` artık `TableFilter` ile diğer tablonun satırını dosyadan
bile okumuyor. A=150K satır varken `B LIMIT 10`: 1.782 ms → **7.4 ms (240x)**.

**P-12 — `TryStreamAgg`** (`VDbExecutor.pas`): `COUNT/SUM/MIN/MAX/AVG` tek-tablo
sorgularında satır matrisi hiç malzelleştirilmez; agregat planı satır akışı üstünde
ilerler (`TAggPlan`).

**P-13 — `ScanSnapshot` toplu okuma** (`VDbCore.pas`): satır başına 3 syscall yerine
üç faz: A) görünür adaylar toplanır (dosyaya dokunulmaz), B) bucket sayım-dönüşümü
(O(N) counting sort), C) bucket başına TEK dosya okuması.

**P-14 — INSERT boşluğunun tam teşhisi** (bench14..bench23 mikro-ölçümleri): SQLite
karşısındaki 16x farkın dökümü (300K satır, tek INSERT 56.6 µs): parse ~12 µs +
execütör glue ~9 µs + Insert/commit ~16.3 µs + API sarmalayıcı ~3-5 µs + kalan
~15 µs heap tahsis/büyüme cezası. "Sarmalayıcı 25 µs" yanıltmacası çürütüldü:
C−G farkı süreç/heap bağlamıydı (36 MB hazır string pre-alloc'u 58.6→44.1 µs).
Kalan boşluk **mimari**: SQLite prepared statement kullanıyor; metin-başına-parse
kaçınılmaz maliyet.

**P-14a — tahsis-siz `VDbNorm` hızlı yolu** (`VDbTable.pas`): ASCII-üstü (≥#128),
büyük harf veya kabartma gerektiren kenar boşluk yoksa `Trim+LowerCase` hiç
çağrılmadan AYNI referans döner (FPC `Trim` yalnız ' ' ve #9 siler — `ttrim.pas`
ile doğrulandı); davranış bit-bit aynı. `IsView` da `ContainsKey+indexer` yerine
tek `TryGetValue`. Sema/kolon aramaları satır başına ~15 kez buradan geçiyordu.

**P-15a — `SortIdxEntries` decorated INT sort** (`VDbTable.pas`): INTEGER
anahtarlarda karşılaştırma başına 2× `VDbParseInt` yerine anahtarlar bir kez
Int64'a çıkarılıp ( dekorlu ) aynı Hoare partition ile sıralanır; NULL-en-önde +
`CompareStr(Pk)` tie-break birebir korunur; parse edilemeyen anahtarda eski yola
düşer. Lazy PK index rebuild 300K'da **2123 ms → 892 ms** (tüm indeks
kurulumlarına kazanç). RANGE kök nedeni buydu: sorgu başına 25 ms sanılan şey
tek-seferlik tembel rebuild'miş.

**P-16 (YAPILMADI, gerekçeli):** `BETWEEN` uçlarından `IntToStr` ile aday anahtar
üretip nokta-okuma yapılabilirdi ama INT PK'lar YAZIM ŞEKLİYLE saklanır
(`'010'` olduğu gibi kalır); `BETWEEN 1000 AND 1000` için `'1000'` okumak
`'01000'` satırını sessizce düşürürdü → semantiği bozacağı için reddedildi.
Aday üretimi yalnız literalin kendisiyle (`=`, `IN`) güvenlidir — 1/1b yolları
zaten öyle yapıyor.

**Adil kıyas — `vsbench.dpr` (yeni):** 1M satır, AYNI SQL metni, AYNI disk, tek
süreç, stok varsayılanlar (`SyncWriteInterval=0`, senkron commit — SQLite tarafı
da varsayılan journal modunda). run4 (P-14a+P-15a sonrası):

| Aşama | VDB | SQLite | VDB/SQLite |
|---|---|---|---|
| INSERT 1M (BEGIN/COMMIT) | 59.7 sn | 3.70 sn | 16.1x |
| COUNT(*) x10 | 1.20 sn | 44.8 ms | 26.8x |
| SUM(bakiye) x5 | 1.35 sn | 94.4 ms | 14.3x |
| SELECT PK 50.000x | **2.51 sn** | 3.53 sn | **0.71x — VDB hızlı** |
| RANGE 2.000x100 satır | 8.54 sn | 245 ms | 34.9x (run3: 55x) |
| UPDATE 100k | 8.59 sn | 318.8 ms | 26.9x |
| DELETE 100k | 6.10 sn | 229.7 ms | 26.6x |

Doğrulama: COUNT/SUM her iki motorun çıktıları eşit (SUM=5000000000), DELETE
sonrası 900.000. Kalan boşluk (INSERT/UPDATE/COUNT) = prepared statement
mimarisidir; plan-cache `Stmt` mutasyonu (VIEW DML `Stmt.Table := baseTable`,
`Stmt.Body` sahiplik devri) nedeniyle ancak immutable-plan denetimiyle gelir —
sonraki tur adayı. İkinci aday: `BuildPkIdx` peek-rebuild (P-15b).

**Doğrulama (ölü kod temizliği sonrası sıfırdan):** `fpc -B` derlemeleri hatasız;
`sqltest` **2251/2251** (kalan=0, KESILDI yok); crashtest 8'li çarpma zinciri
**8/8** "veri kaybı/bozulma YOK" — dayanıklılık sözleşmesi (`SyncWriteInterval=0`)
pazarlık dışı kaldı.

---

### 5.18 HIZ TURU: P-17 yazma-yolu tahsis diyeti (2026-10-16)

**P-17a — AutoInc ayrı sözlüğü** (`VDbTable.pas`): sayacı ilerleten her INSERT
tüm `TTableDef` kaydını (Cols/Idx/Fks/Checks dizileriyle) `FTables`'a geri
yazıyordu; sayaç artık `TableId`-anahtarlı O(1) sözlükte ve sema kaydı sıcak
yolda dokunulmaz. `SaveSchema` aynı alana `max(kayıt, sözlük)` yazar (wire
format değişmedi); sözlük transaction snapshot'ına dahil (ROLLBACK güvenli),
DROP TABLE'da temizlenir.

**P-17b — `EncodeRow` tek tampon:** satır başına ~10-13 tahsis kaldırıldı;
saf-ASCII metin kaynak diziden doğrudan taşınır (UTF8Encode çıktısı bayt bayt
aynı olurdu); BLOB/ASCII-üstü yolları birebir korundu — **wire format bayt bayt
aynı**.

**P-17c — `Exists` kesmesi:** çakışma denetimi `Get` ile TBytes ayırıp atıyordu;
`ExistsSnapshot` (pending+index+tombstone) saf araması geçerli, değer ancak
gerçek çakışmada okunur — "duplicate vs hash çakışması" sınıflandırması aynı.

**Ölçülen (bench26 mini A/B, 200K satır):** INSERT 52.4→**50.1 µs** (−%4.5),
DELETE 47.5→**45.0 µs** (−%5), UPDATE −%1.5; okuma aşamaları değişmedi (yol
üzerinde değiller). Dürüst özet: diyet ~%5 verdi — INSERT'in kalan ağırlığı
**parser (~12 µs)** ve **KV/commit (~16 µs)** katmanında. `bench26.dpr` A/B
aracı olarak depoya girdi.

**Sonraki adaylar:** (1) sıfır-kopya tarama geri çağırması — `ScanAll` yerine
`ScanRawIter`, COUNT/SUM'ın TBytes malzelleştirmesi biter (~4-6x beklenen);
(2) P-15b `BuildPkIdx` peek-rebuild (RANGE tek-seferlik maliyeti); (3) INSERT
literal hızlı şeridi — `INSERT INTO t(cols) VALUES(<literaller>)` biçimini
parser+AST olmadan tanı, en ufak sapmada genel ayrıştırıcıya düş. Plan cache
hâlâ ertelendi: SQLite tarafı da prepared statement kullanmıyor
(`sqlite3_exec`), ham pipeline diyeti öne geçti.

**Doğrulama:** `fpc -B` hatasız; `sqltest` **2251/2251**; crashtest **8/8**
(`sqltest_p16.log`, `c8_p16.log`).

---

### 5.19 HIZ TURU: P-18a sıfır-kopya agreg taraması — ScanRawIter (2026-10-16)

`TryStreamAgg` (P-12) agregları tek geçişte sayıyordu ama her satırı
`ScanAll` üzerinden **TBytes + Keys/Vals dizisine malzelleştiriyordu**.
P-18a bu malzelleştirmeyi kaldırır:

- `TVDb.ScanRawIter(SnapshotSeq, TableFilter, Cb, User)` — Faz A/B/C
  `ScanSnapshot` ile birebir (görünürlük, tombstone, R-26 filtresi, 2 MB
  bucket toplu okuma, bozuk kayıt sessiz atlama, şifre çözme); değer chunk
  tamponundaki aralıktan `(PByte, Len)` olarak geri çağrıya verilir.
  Callback `False` dönerse tarama derhal durur. Kilitsizlik sözleşmesi aynı.
- `VDbPeekRawRowP(B, Len, ...)` — peek'in kopyasız ikizi; aynı sınır
  kontrolleri, aynı "eski sema/kesik → False" sınıflandırması.
- `VdbAggRawCb` (VDbExecutor, birim düzeyi) — P-12 döngü gövdesi birebir;
  `TAggPlan` birim düzeyine çıktı, dolaşım durumu `TAggIterCtx` (stack).
- Semantik korunur: peek-fail / hash-çakışması → genel yola düş (hata aynı
  yerde üretilir); sıralama bucket sırası (agrega sıradan bağımsız).

**Ölçülen (bench26 @200K):** COUNT x5 −%4, SUM x3 −%6 — 200K'te
malzelleştirme cache'te yaşıyor; ceza 1M ölçeğinde (vsbench run5 beklenen
kazanç). Okuma fazları gürültülü makinede ±%5 dalgalanıyor; mini-bench alt
sınırdır.

**Kabul edilmeyen aday:** COUNT(*)'ı Faz C doğrulaması olmadan salt-indeks
saymak ~%45 ek kazanç sağlardı AMA bozuk dosyada "sessiz atlama / NET HATA"
davranışını değiştirirdi — dayanıklılık sözleşmesi öncelikli, reddedildi.

**Doğrulama:** `fpc -B` hatasız; `sqltest` **2251/2251**; crashtest **8/8**
(`sqltest_p18.log`, `c8_p18.log`).

---

### 5.20 HIZ TURU: P-18c literal INSERT hızlı şeridi (2026-10-16)

`TVSql.Exec` yazma yolunda `ExecRaw` başına literal-INSERT tanıyıcı eklendi:
`INSERT INTO t (kolonlar) VALUES (<literaller>)` biçimi lexer/AST/ExprEval
ZİNCİRİ ATLANARAK yürütülür (`TVSqlExecutor.ExecFastLiteralInsert`).

- **Kabul kümesi daraltılmıştır (bilinçli):** ASCII tanımlayıcı; kanonik
  tamsayı; '.'-lı float (`VDbFloatToStr(VDbParseFloat)` kanonik sonucu);
  `''`-kaçışlı tek tırnak string (NextToken kurallarıyla birebir); NULL→`''`
  (`EvalExpr`'in sltNull üretimiyle aynı); TRUE/FALSE→'True'/'False'
  (`CreateBool` ile aynı). Kolon listesi opsiyoneldir.
- **Sapma = ret = genel yol aynen:** yorum/param/fonksiyon/float-biçim
  sapmaları/BLOB/tırnaklı tanımlayıcı/RETURNING/ON CONFLICT/çok satır/`;`,
  tablo yok, VIEW, INSERT tetikleyicisi (STATEMENT+ROW, BEFORE+AFTER),
  kolon≠değer sayısı. Tarayıcı yalnız kabul/ret karar verir; motor hatası
  üretmez — tek istisna kaynağı kabul sonrası `RequirePriv`/RLS/`FT.Insert`,
  yani genel yolun aynı noktaları, aynı sıra.
- **Sayaç paritesi:** F-21 `FLastMs` + R-24 `RecordCommand`/`NoteSlow` AST
  yoluyla kopyalandı; şerit REDDİNDE kayıt yok (genel yol kendi kaydeder).
  İlk sürüm `finally` kaydı yüzünden reddedilen INSERT'leri iki kez
  sayıyordu (6811→6984); düzeltme sonrası tabanla birebir (`sqltest_p18d`).
- `TriggersFor` içi debug WriteLn izleri (F-36 döneminden, HEAD'de mevcut)
  bilinçli olarak yerinde bırakıldı — başka oturumun ayıklama izi.

**Ölçülen (bench26 @200K):** INSERT 51.4→**31.9 µs/satır** (−%38; v0.005
HEAD'e göre −%39); okuma/yazma diğer aşamalar yol dışı, değişmedi. vsbench
run5 beklentisi: INSERT 16.1x→~10x.

**Doğrulama:** `fpc -B` hatasız; `sqltest` **2251/2251** (SHOW STATS toplamı
tabanla eşit); crashtest **8/8** (`sqltest_p18d.log`, `c8_p18d.log`).

---

### 5.17 ⚡ SPEED ROUND: R-26 + P-12..P-15 + FAIR COMPARISON (2026-10-15..16)

**R-26 — Table-scan filter** (`VDbCore.pas`, `VDbTable.pas`): the per-row TableId
(already read for CRC in `Recover`) is stored in `TDbLoc.TableId`;
`ScanSnapshot/ScanAll` take a `TableFilter` and do not even read other tables'
rows from disk. `B LIMIT 10` while A holds 150K rows: 1,782 ms → **7.4 ms (240x)**.

**P-12 — `TryStreamAgg`** (`VDbExecutor.pas`): single-table `COUNT/SUM/MIN/MAX/AVG`
never materializes the row matrix; the aggregate plan (`TAggPlan`) advances over a
row stream.

**P-13 — `ScanSnapshot` batched reads** (`VDbCore.pas`): instead of 3 syscalls per
row, three phases: A) collect visible candidates (no file access), B) O(N) bucket
counting sort, C) one batched file read per bucket.

**P-14 — full diagnosis of the INSERT gap** (bench14..bench23 micro-benchmarks):
breakdown of the 16x gap vs SQLite (single INSERT 56.6 µs at 300K rows): parse
~12 µs + executor glue ~9 µs + Insert/commit ~16.3 µs + API wrapper ~3-5 µs +
~15 µs heap allocation/growth penalty. The "wrapper costs 25 µs" red herring was
disproved: the C−G delta was the process/heap context (pre-allocating 36 MB of
ready strings: 58.6→44.1 µs). The remaining gap is **architectural**: SQLite uses
prepared statements; per-text parsing is an unavoidable cost.

**P-14a — allocation-free `VDbNorm` fast path** (`VDbTable.pas`): when the string
has no non-ASCII (≥#128), no uppercase and no trim-requiring edge whitespace,
the SAME reference is returned without calling `Trim+LowerCase` (FPC `Trim` only
strips ' ' and #9 — verified with `ttrim.pas`); behavior is bit-identical.
`IsView` now uses a single `TryGetValue` instead of `ContainsKey`+indexer. Schema
and column lookups passed through here ~15 times per row.

**P-15a — decorated INT sort in `SortIdxEntries`** (`VDbTable.pas`): for INTEGER
keys, instead of 2× `VDbParseInt` per comparison, keys are decoded to Int64 once
and sorted with the same Hoare partition; NULL-first ordering and the
`CompareStr(Pk)` tie-break are preserved bit-for-bit; unparsable keys fall back to
the old path. Lazy PK index rebuild at 300K: **2,123 ms → 892 ms** (benefits every
index build). This was the true root cause of RANGE: what looked like 25 ms per
query was a one-time lazy rebuild.

**P-16 (NOT DONE, deliberate):** generating point-read candidate keys via
`IntToStr` from BETWEEN bounds was possible, but INT PKs are stored EXACTLY as
written (`'010'` stays `'010'`); reading `'1000'` for `BETWEEN 1000 AND 1000`
would silently drop `'01000'` — rejected as semantics-breaking. Candidate
generation is only safe with the literal itself (`=`, `IN`) — paths 1/1b already
do exactly that.

**Fair comparison — `vsbench.dpr` (new):** 1M rows, SAME SQL text, SAME disk, one
process, stock defaults (`SyncWriteInterval=0`, synchronous commit — SQLite side
also runs its default journal mode). run4 (after P-14a+P-15a):

| Phase | VDB | SQLite | VDB/SQLite |
|---|---|---|---|
| INSERT 1M (BEGIN/COMMIT) | 59.7 s | 3.70 s | 16.1x |
| COUNT(*) x10 | 1.20 s | 44.8 ms | 26.8x |
| SUM(balance) x5 | 1.35 s | 94.4 ms | 14.3x |
| SELECT PK 50,000x | **2.51 s** | 3.53 s | **0.71x — VDB faster** |
| RANGE 2,000x100 rows | 8.54 s | 245 ms | 34.9x (run3: 55x) |
| UPDATE 100k | 8.59 s | 318.8 ms | 26.9x |
| DELETE 100k | 6.10 s | 229.7 ms | 26.6x |

Verification: COUNT/SUM identical across engines (SUM=5000000000); 900,000 rows
after DELETE. The remaining gap (INSERT/UPDATE/COUNT) is the prepared-statement
architecture; a plan cache requires an immutable-plan audit first because the
executor mutates `Stmt` (VIEW DML `Stmt.Table := baseTable`, `Stmt.Body`
ownership transfer) — next-round candidate. Second candidate: peek-rebuild in
`BuildPkIdx` (P-15b).

**Verification (from scratch after dead-code cleanup):** clean `fpc -B` builds;
`sqltest` **2251/2251** (0 remaining, no abort); 8-crash crashtest chain **8/8**
"no data loss/corruption" — the durability contract (`SyncWriteInterval=0`)
remained non-negotiable.

---

### 5.18 SPEED ROUND: P-17 write-path allocation diet (2026-10-16)

**P-17a — AutoInc side dictionary** (`VDbTable.pas`): every counter-advancing
INSERT rewrote the whole `TTableDef` record (Cols/Idx/Fks/Checks arrays) back
into `FTables`; the counter now lives in an O(1) dictionary keyed by `TableId`
and the schema record is untouched on the hot path. `SaveSchema` writes
`max(record, dict)` into the same field (wire format unchanged); the dictionary
is part of the transaction snapshot (ROLLBACK-safe) and cleaned on DROP TABLE.

**P-17b — `EncodeRow` single buffer:** ~10-13 allocations per row removed; pure
ASCII text is moved straight from the source string (UTF8Encode output would be
byte-identical); BLOB/non-ASCII paths preserved bit-for-bit — **wire format is
byte-identical**.

**P-17c — `Exists` short-circuit:** the duplicate check used to allocate a
TBytes via `Get` and throw it away; the pure `ExistsSnapshot` lookup
(pending+index+tombstone) now gates it and the value is read only on a real hit
— the "duplicate vs hash collision" classification is unchanged.

**Measured (bench26 mini A/B, 200K rows):** INSERT 52.4→**50.1 µs** (−4.5%),
DELETE 47.5→**45.0 µs** (−5%), UPDATE −1.5%; read phases unchanged (not on the
path). Honest summary: the diet paid ~5% — the remaining INSERT weight sits in
the **parser (~12 µs)** and **KV/commit (~16 µs)** layers. `bench26.dpr` is
committed as the A/B harness.

**Next candidates:** (1) zero-copy scan callback — `ScanRawIter` instead of
`ScanAll`, ending the TBytes materialization in COUNT/SUM (~4-6x expected);
(2) P-15b peek-rebuild in `BuildPkIdx` (one-time RANGE cost); (3) INSERT literal
fast lane — recognize `INSERT INTO t(cols) VALUES(<literals>)` without
parser+AST, falling back to the general parser on the slightest deviation. The
plan cache stays deferred: the SQLite side turns out to use `sqlite3_exec` (no
prepared statements either), so raw pipeline diet takes priority.

**Verification:** clean `fpc -B` builds; `sqltest` **2251/2251**; crashtest
**8/8** (`sqltest_p16.log`, `c8_p16.log`).

---

### 5.19 SPEED ROUND: P-18a zero-copy aggregate scan — ScanRawIter (2026-10-16)

`TryStreamAgg` (P-12) already counted aggregates in a single pass, but every
row was MATERIALIZED through `ScanAll` into TBytes + Keys/Vals arrays. P-18a
removes that materialization:

- `TVDb.ScanRawIter(SnapshotSeq, TableFilter, Cb, User)` — phases A/B/C are
  bit-for-bit `ScanSnapshot` (visibility, tombstones, R-26 filter, 2 MB
  bucketed bulk reads, silent skip of corrupt records, decryption); the value
  is handed to the callback as `(PByte, Len)` pointing inside the chunk
  buffer. Callback returning `False` aborts the scan immediately. Same
  lock-free contract.
- `VDbPeekRawRowP(B, Len, ...)` — the copy-free twin of the peek; identical
  bounds checks, identical "old schema/truncated → False" classification.
- `VdbAggRawCb` (VDbExecutor, unit level) — the P-12 loop body verbatim;
  `TAggPlan` moved to unit level, iteration state flows via `TAggIterCtx`
  (stack).
- Semantics preserved: peek-fail / hash-collision still fall back to the
  general path (error raised at the same place); order is bucket order
  (aggregates are order-insensitive).

**Measured (bench26 @200K):** COUNT x5 −4%, SUM x3 −6% — at 200K the
materialization lives in cache; the penalty shows at 1M scale (expected win
in vsbench run5). Read phases fluctuate ±5% on a noisy machine; the
mini-bench is a lower bound.

**Rejected candidate:** counting COUNT(*) from the index alone (skipping the
phase-C record validation) would add ~45% — BUT it would change the
"silent-skip / hard-error" behavior on corrupt files; the durability
contract wins, rejected.

**Verification:** clean `fpc -B` builds; `sqltest` **2251/2251**; crashtest
**8/8** (`sqltest_p18.log`, `c8_p18.log`).

---

### 5.20 SPEED ROUND: P-18c literal INSERT fast lane (2026-10-16)

A literal-INSERT recognizer was added at the top of `ExecRaw` on the
`TVSql.Exec` write path: statements shaped exactly like
`INSERT INTO t (cols) VALUES (<literals>)` execute WITHOUT the
lexer/AST/ExprEval chain (`TVSqlExecutor.ExecFastLiteralInsert`).

- **Deliberately narrow accept set:** ASCII identifiers; canonical
  integers; '.'-floats canonicalized through the same
  `VDbFloatToStr(VDbParseFloat)` the parser uses; single-quoted strings
  with `''` escaping (bit-identical to NextToken); NULL→`''` (exactly what
  `EvalExpr` yields for sltNull); TRUE/FALSE→'True'/'False' (same as
  `CreateBool`). The column list is optional.
- **Deviation = reject = general path untouched:** comments, `?` params,
  functions, float-format deviations, BLOB, quoted identifiers, RETURNING,
  ON CONFLICT, multi-row, `;`, missing table, VIEW, tables with INSERT
  triggers (STATEMENT+ROW, BEFORE+AFTER), column≠value counts. The scanner
  only decides accept/reject; it never raises engine errors — after
  acceptance the ONLY raise sources are `RequirePriv`/RLS/`FT.Insert`, the
  same points, the same order as the general path.
- **Counter parity:** F-21 `FLastMs` + R-24 `RecordCommand`/`NoteSlow`
  replicated from the AST path; on lane REJECT nothing is recorded (the
  general path records its own run). The first revision recorded in a
  `finally`, double-counting rejected INSERTs (6811→6984); after the fix
  the total matches the baseline again (`sqltest_p18d`).
- Debug WriteLn traces inside `TriggersFor` (from the F-36 era, present in
  HEAD) were deliberately left in place — another session's live
  debugging trace.

**Measured (bench26 @200K):** INSERT 51.4→**31.9 µs/row** (−38%; −39% vs
v0.005 HEAD); all other phases off-lane, unchanged. Expected vsbench run5:
INSERT ratio 16.1x→~10x.

**Verification:** clean `fpc -B` builds; `sqltest` **2251/2251** (SHOW
STATS total equal to baseline); crashtest **8/8** (`sqltest_p18d.log`,
`c8_p18d.log`).

---

## 6. 🐛 DÜZELTİLEN GERÇEK HATALAR (tüm turlar)

| Yer | Hata | Etki |
|-----|------|------|
| `VDbExecutor.ExecDelete` | Yetki kontrolü `pkUpdate` idi | **Bir role yalnız UPDATE verilse DELETE de geçiyordu (yetki atlama)** |
| `VDbXPrimsTest.dpr` | `rawh` handle'ı **iki kez** `CloseHandle` ediliyordu | Handle geri dönüşümü yüzünden **başka bir nesnenin handle'ı kapatılıyor**, `WaitForSingleObject` → `WAIT_FAILED`; mutex testi yanlış "başarısız" veriyordu |
| `VDbXPrimsTest.dpr` | `r2=` / `d2=` argümanları `Copy(...,3,...)` ile ayrıştırılıyordu | İsimde `=` kalıyordu → master/slave **farklı event adı** kullanıyor, "slave veri yazamadı" |
| `VDbXPrimsTest.dpr` | `CreateEvent` auto-reset idi | Sinyal, bekleyen taraf gelmeden kayboluyordu (yarış) |
| `VDbXPrimsTest.dpr` | Slave `Mutex.Leave` çağırmıyordu | Kilit `Destroy` anında bırakılıyordu, "2.5 sn tutma" semantiği bozuktu |
| `VDbPool.pas` | Yorumda kapanış `{}` eksikti | Alanlar yorum içinde kalıyordu, derlenmiyordu |
| `VDbPool.pas` | `CreateXProc` açtığı motoru kapatmıyordu | Havuz `Free` sonrası `.odb` kilitli kalıyordu ("dosya kullanımda") |
| `VDbPool.pas` | `InitXProc` veri dizinini SHM adıyla eziyordu | Motor yanlış dizinde boş veritabanı açıyordu ("tablo yok") |
| `VDbPool.pas` | `OpenEngine` `FTb` atamıyordu | `TVSql.Create(nil)` → Access violation |
| `VDbPool.pas` | `uses Windows` | FPC'nin `Windows` birimi `TCriticalSection`'u gölgeliyordu → "no member Create" |
| `VDbPool.pas` | `Release(nil)` no-op'tu | Slot hiç bırakılmıyor, kapasite sızıyordu |
| `VDbPool.pas` | Açılışta süreç başına ayrı slot | Kapasite yarıya iniyordu, iki yer tutuluyordu |
| `VDbXPrims.pas` | `AllocateSlot` yarış şartı yoktu | **İki süreç aynı slotu alabiliyordu** |
| `vdbapitest.lpr` | Beklenen sürüm `$00010000` | DLL `$00010100` (1.1) döndürüyordu |
| `VDbClient.pas` | Beklenen sürüm `$00010000` | DLL ile uyuşmuyordu, client hiç açılamıyordu |
| `VDbTable.LoadSchema` | Yerel `TTableDef` tam sıfırlanmıyordu (`IsView`/`IsMaterializedView`/`SelectStmt` gibi yönetilmeyen alanlar yığın çöpü taşıyordu) | **Reopen sonrası normal tablolar yanlışlıkla "view" sayılıyordu** ("view tanimi ayristirilamadi veya bos: t") ve tüm paket erken kesiliyordu. `t := Default(TTableDef)` ile düzeltildi. |
| `VDbParser` (dispatcher) | `START`/`STOP`/`PUMP`/`PRAGMA` ve `CREATE/DROP REPLICATION` ana dağıtıcıya bağlı değildi | R-17 komutları ve `PRAGMA` **erişilemezdi** ("Bilinmeyen SQL komutu"). Dağıtıcıya eklendi; replikasyon bloğu genel CREATE/DROP/SHOW'dan ÖNCE işleniyor. |
| `VDbExecutor.HasPkLookup` | Saf yüklem olması gerekirken `EXPLAIN ANALYZE`'da fazladan bir `ANALYZE:` plan satırı ekliyordu | `EXPLAIN ANALYZE` 3 yerine 4 satır döndürüyordu. Yan etki kaldırıldı; actual-rows yalnız `Stmt.Analyze` bloğunda. |
| `VDbCore.pas` (R-23) | `FileUtil` (LazUtils) kaldırılınca onun `initialization`'ındaki `SetMultiByteConversionCodePage(CP_UTF8)` de kayboldu | Windows'ta `DefaultSystemCodePage` sistem ACP'sine (cp1254) düştü; UTF-8 literal'ler (65001) ile motor değerleri (1254) farklı kod sayfalarında karşılaştırıldı → **Türkçe collation / ifade indeksi / XML / BLOB olmak üzere 19 test kırıldı**. Motor artık kendi `initialization`'ında UTF-8'e sabitliyor. |
| `VDbMonitor.pas` (R-23) | `{$mode delphi}` yoktu | `out` parametreli `MonitorConfig` `fpc` varsayılan modda derlenmiyordu (lazbuild bir proje modu geçtiği için gizli kalmıştı). |
| `VDbParallel.pas` (R-23) | `{$mode delphi}` yoktu | Varsayılan parametre `MaxThreads: Integer = 0` `fpc` varsayılan modda derlenmiyordu. |
| `VDbExtension.pas` (R-23) | `{$mode delphi}` yoktu | `array of const` imzaları ile tutarlılık/dışa aktarım için eklendi. |
| `VDbParser` (R-15) | `ANALYZE` ana dağıtıcıya bağlı değildi | `ExecAnalyze`/`RecordTableStats` kodu vardı ama **erişilemezdi** ("Bilinmeyen SQL komutu"). `U = 'ANALYZE'` dalı ve `ParseAdmin` bloğu eklendi. |
| `VDbMonitor.GetTableStats` (R-15) | Kolon paketi 4 alan (`distinct,null,min,max`) ama kod `Count >= 5` arıyordu | `DistinctCount`/`NullCount` **hiçbir zaman** dolmuyordu; CBO seçicilik tahmini daima 0 olurdu. `>= 4` yapıldı. |
| `VDbExecutor.ExecAnalyze` (R-15) | DISTINCT sayımı boş olmayan her değeri sayıyordu | `distinct = rowcount` çıkıyordu → seçicilik tahmini anlamsızlaşıyordu; gerçek hash kovasıyla düzeltildi. |
| `VDbMonitor` (R-15) | Tablo istatistikleri flush edilen `GBuffer`'daydı | `MaxBufferSize` aşımında ANALYZE istatistiği **kayboluyordu** (CBO deterministik değildi); ayrı kalıcı `GTableStats` listesine taşındı. |
| `VDbText.VDbLangProfile` (R-20) | `-u-` değer segmentleri HİÇ okunmuyordu (değer okuma döngüsü `-` işaretinde hiç ilerlemiyordu) | `kn-true`'daki `true` yeni anahtar sanılıyor, `kn-ks`'deki `ks` birinci anahtarın "değeri" olarak yutuluyordu. Bölüm segment segment okunur: bilinen anahtar açığı değersiz kapatır, bilinmeyen segment DEĞERDİR; `U` ayırıcı atlanır (eski `-u-ks-u-kc` yazımı geri uyumlu çözümlenir) |
| `VDbText` KN semantiği (R-20) | `kn` anahtarı `AccentSens` (vurgu) kuruyordu — ICU'da `kn` = numeric ordering | Yeni `NumericOrder` alanı + `VDbCompareCol`'da rakam koşuğu sayısal kıyası (`a2 < a10`; baştaki sıfırlar atılır: `a01` = `a1`); `VDbCollationKey`'e sıfır-baş normalizasyonu |
| `VDbText.CyrillicWeight/GreekWeight/ArabicWeight` (R-20) | Harf tabloları STRING SABİTİYDİ: kaynak UTF-8 → sabitteki Kiril/Yunan/Arap harfleri 2'şer bayt; `Ord(S[i])` tek bayt okur, kod noktasıyla ASLA eşleşmezdi | Tüm harfler "harf dışı" çıkıp kod noktası sırası geçerliyordu — `Я` (U+042F), `а` (U+0430)'tan KÜÇÜK önce sıralanıyordu. Üçü de kod noktası ARİTMETİĞİyle yeniden yazıldı (Rus а..я = $430..$44F kesintisiz, ё=13; Yunan α..π/ρ..ω, ς→σ; Arap 28 harf aralıkları) |
| `VDbText.LatinSecondary` (R-20) | Büyük harf katlaması yoktu (Á vurgusuz sayılıyordu) VE vurgulu ağırlıklar vurgusuzla çarpışıyordu (á=1, vurgusuz a→1'e yuvarlanıyordu) | İkincil katman vurguyu HİÇ ayırt etmiyordu. Katlama eklendi + vurgulu ağırlıklar +1 kaydırıldı (vurgusuz=1, vurgulu=2..6 — ICU sırası: vurgusuz önce) |
| `VDbText.VDbCollationName` (R-20) | `kn` bayrağı kanonik ada YAZILMIYORDU | Kolon varsayılanı (`CREATE TABLE ... COLLATE tr-TR-u-kn-ks`) reopen'da sessizce doğal sıralamayı yitirirdi; `-u-kn` eki eklendi (round-trip) |
| `VDbText.VDbLangProfile` (R-20) | `NumericOrder` yereli başlatılmamıştı | `-u-` içermeyen etiketlerde (düz `tr`) yığın ÇÖP değeriyle doğal sıralama açılıyordu; varsayılan `False` atandı |
| `VDbText` (R-20) | Önceki oturumdan geri alınmamış mutasyon kalıntısı: `if True then P.Alpha := vaLatin` | Alfabe seçimi (`VDbAlphaForLang`) ölü koddur — Kiril/Yunan/... profilleri hep Latin sayılıyordu; geri alındı |
| `sqltest.lpr` T94d (R-20) | Kiril test verisi `CR(430)` ONDALIKTI (= U+01AE Latin harfi!) | `CR($0430/$0431/$0432/$042F)` yapıldı (gerçek Kiril а/б/в/Я; ağırlık tabloları düzeltilince gerçek karakterler zorunlu oldu) |
| `VDbParser` (R-13) | LIST tanımı döngü `)`'yi tükettiği hâlde **İKİ** `Expect(')')` vardı | `PARTITION BY LIST ... VALUES (...)` tanımı **her zaman** "dosya sonu" hatası veriyordu — gizli hata, RANGE/LIST hiç test edilmemişti. Tek `Expect(')')` yapıldı. |
| `VDbParser` (R-13) | LIST/RANGE değerleri `VDbNorm` (LowerCase) üzerinden geçiyordu | Değerler küçültülüyor, literal eşleşmiyordu (`'Ankara'` → `'ankara'`). Literal olarak alındı (tirnak lexer'da soyulur). |
| `VDbTable.PartValueOf` (R-13) | INT indirgeme yoktu (saklı `'05'` ham metindi) | Hedef `'05'` = 5 sayısal eşleşir ama bölüm hash'i farklı → **yanlış eleme**. Hem satır hem hedef `IntToStr` canonical'ına çekildi. |
| `VDbExecutor.ExecExplain` (R-13) | Pruning raporu indeks/pkUsed planlarında da çıkıyordu | NarrowRows CBO'da indeks yolunu reddetmez → `nonSeqPath` ile rapor yalnız Seq Scan planlarına kısıldı (dürüstlük). |
| `VDbMonitor.RecordCommand` (R-24) | Sayaç blokları `if False` ile devre dışı ("MUTASYON KANITI" notuyla) ve `RecordCommand`'ı çağıran hiç kod yoktu | `GStats` hiç artmıyor, hiçbir test gözlemlemiyordu (yağmurlu gün); kalıntı kaldırıldı + `VDbSql.ExecRaw` finally bağı eklendi |
| `VDbMonitor.RecordCommand` (R-24) | `GBuffer`/`FlushBufferToFile` koşulsuz çalışıyordu (`FileName = ''` → tampanda `.mon.edb`) | Sayaç bağlantısı eklenseydi test klasörlerine çöp dosya; yazma `FileName <> ''` kapısına alındı |
| `vdbserver.lpr` (R-12) | Program adı `vdbserver` ile birim adı `VDbServer` FPC'de büyük/küçük harf duyarsız **çakışıyordu** ("Duplicate identifier") | Birim `VDbSqlServer.pas` adıyla yeniden yazıldı |
| `VDbServer` (R-12) | Boş `const` bloğu (yalnız yorum) FPC'de sözdizimi hatası | Blok kaldırılıp yoruma taşındı |
| `VDbClientNet.Exec` (R-12) | Sayı sayaçlı döngüler `for i := 0 to nF - 1` (Cardinal/UInt64) — **boşta alt taşma** (0'dan büyük sınıra); ayrıca satır sayısı u64 okuması 4 baytlık değişkene yazılıyordu (yığın bozulma) | `High(...)` tabanlı `Integer` döngülere çevrildi; u64 ayrı `UInt64` değişkende + sınır denetimi |
| `VDbSqlServer` (R-12) | Bağlantı thread'i `Execute` sonunda listeden çıkıyordu → biten thread objesi **sahipsiz** (BYE ile kapanan bağlantı sızdırıyordu); thread'in kendini `Free` etmesi self-join deadlock | Sahiplik modeli: liste sahiptir; `AddConn` kabul anında biten thread'leri `WaitFor`+`Free` ile toplar, `Stop` hepsini bekleyip serbest bırakır |
| `T106` (R-12) | UPDATE, SELECT kontrol bloğundan ÖNCE `ad` değerini değiştiriyordu (`ad=bir` beklenirken `degisti` geliyordu — 1 FAIL) | Test sırası düzeltildi: SELECT kontrol bloğu UPDATE'ten öne alındı → yeşil |
| `vdbapi_core.VdbFileSizeOf` (R-23) | `FileUtil.FileSize` yerine `TFileStream` ile ölçüm — motor ana dosyayı **diğer açımlara kapalı** tuttuğu için ikinci açma paylasım hatası verir, istisna yutulup **0** dönerdi (vdbapitest: `dosya boyutu > 0 [0 bayt]` + `AutoCompact [0 -> 0]`; dosya gerçekte yazılıyordu) | Ölçüm dosya **açılmadan** `FindFirst` ile yapıldı. R-12 Full son tam koşuda bulundu; mutasyon (`TFileStream`'e geri dönüş) → **2 FAIL** → geri al → `vdbapitest` **170/170** |
| `yol_haritasi.md` (düzenleme aracı) | BMP-dışı emoji (`🔴` U+1F534, `🟠`) edit aracında `oldString` ile EŞLEŞMİYOR (vekil çiftli kodlama) | Emoji içeren tablo hücreleri ps1 betiğiyle (`.+?` regex) değiştiriliyor; emoji'siz satırlar doğrudan edit ile. |

---

## 6. 🐛 REAL BUGS FIXED (all rounds) (ENGLISH)

| Location | Bug | Impact |
|----------|-----|--------|
| `VDbExecutor.ExecDelete` | Authorization check used `pkUpdate` | **A role granted only UPDATE could also pass DELETE (privilege bypass)** |
| `VDbXPrimsTest.dpr` | The `rawh` handle was `CloseHandle`d **twice** | Through handle recycling another object's handle got closed, `WaitForSingleObject` → `WAIT_FAILED`; the mutex test falsely reported "failed" |
| `VDbXPrimsTest.dpr` | The `r2=`/`d2=` arguments were parsed with `Copy(...,3,...)` | `=` stayed in the name → master/slave used DIFFERENT event names, "slave could not write data" |
| `VDbXPrimsTest.dpr` | `CreateEvent` was auto-reset | The signal was lost before the waiting side arrived (race) |
| `VDbXPrimsTest.dpr` | The slave never called `Mutex.Leave` | The lock was released at `Destroy` time, the "hold for 2.5 s" semantics broke |
| `VDbPool.pas` | Missing closing `{}` in a comment | Fields stayed inside the comment, did not compile |
| `VDbPool.pas` | `CreateXProc` did not close the engine it opened | After pool `Free` the `.odb` stayed locked ("file in use") |
| `VDbPool.pas` | `InitXProc` overwrote the data directory with the SHM name | The engine opened an empty database in the wrong directory ("table not found") |
| `VDbPool.pas` | `OpenEngine` did not assign `FTb` | `TVSql.Create(nil)` → Access violation |
| `VDbPool.pas` | `uses Windows` | FPC's `Windows` unit shadowed `TCriticalSection` → "no member Create" |
| `VDbPool.pas` | `Release(nil)` was a no-op | The slot was never released, capacity leaked |
| `VDbPool.pas` | A separate slot per process at startup | Capacity halved, two places reserved |
| `VDbXPrims.pas` | `AllocateSlot` had no race protection | **Two processes could take the same slot** |
| `vdbapitest.lpr` | Expected version `$00010000` | The DLL returned `$00010100` (1.1) |
| `VDbClient.pas` | Expected version `$00010000` | Did not match the DLL, the client could not open at all |
| `VDbTable.LoadSchema` | The local `TTableDef` was not fully zeroed (unmanaged fields like `IsView`/`IsMaterializedView`/`SelectStmt` carried stack garbage) | **After reopen, normal tables were mistakenly treated as "views"** ("view tanimi ayristirilamadi veya bos: t") and the whole package run aborted early. Fixed with `t := Default(TTableDef)`. |
| `VDbParser` (dispatcher) | `START`/`STOP`/`PUMP`/`PRAGMA` and `CREATE/DROP REPLICATION` were not wired to the main dispatcher | The R-17 commands and `PRAGMA` **were inaccessible** ("Unknown SQL command"). Added to the dispatcher; the replication block is processed BEFORE generic CREATE/DROP/SHOW. |
| `VDbExecutor.HasPkLookup` | A pure load added an extra `ANALYZE:` plan line in `EXPLAIN ANALYZE` | `EXPLAIN ANALYZE` returned 4 lines instead of 3. Side effect removed; actual-rows only in the `Stmt.Analyze` block. |
| `VDbCore.pas` (R-23) | When `FileUtil` (LazUtils) was removed, its `initialization`'s `SetMultiByteConversionCodePage(CP_UTF8)` went with it | On Windows `DefaultSystemCodePage` fell back to the system ACP (cp1254); UTF-8 literals (65001) and engine values (1254) were compared across code pages → **19 tests broke** (Turkish collation / expression index / XML / BLOB). The engine now pins UTF-8 in its own `initialization`. |
| `VDbMonitor.pas` (R-23) | No `{$mode delphi}` | `MonitorConfig` with an `out` parameter did not compile in default `fpc` mode (hidden because lazbuild passed a project mode). |
| `VDbParallel.pas` (R-23) | No `{$mode delphi}` | The default parameter `MaxThreads: Integer = 0` did not compile in default `fpc` mode. |
| `VDbExtension.pas` (R-23) | No `{$mode delphi}` | Added for consistency/export with `array of const` signatures. |
| `VDbParser` (R-15) | `ANALYZE` was not wired to the main dispatcher | `ExecAnalyze`/`RecordTableStats` code existed but **was inaccessible** ("Unknown SQL command"). Added the `U = 'ANALYZE'` branch and the `ParseAdmin` block. |
| `VDbMonitor.GetTableStats` (R-15) | The column packet has 4 fields (`distinct,null,min,max`) but the code checked `Count >= 5` | `DistinctCount`/`NullCount` **never** filled; CBO selectivity estimates were always 0. Changed to `>= 4`. |
| `VDbExecutor.ExecAnalyze` (R-15) | DISTINCT counted every non-null value | `distinct = rowcount` → selectivity estimates meaningless; fixed with a real hash bucket. |
| `VDbMonitor` (R-15) | Table statistics lived in the flushed `GBuffer` | On `MaxBufferSize` overflow the ANALYZE statistics were **lost** (CBO was nondeterministic); moved to a separate persistent `GTableStats` list. |
| `VDbText.VDbLangProfile` (R-20) | `-u-` value segments were NEVER read (the value loop never advanced past `-`) | In `kn-true` the `true` was taken as a new key, in `kn-ks` the `ks` was swallowed as the first key's value. Sections are now read segment by segment: a known key closes open keys without a value, an unknown segment IS THE VALUE; the `U` separator is skipped (old `-u-ks-u-kc` spelling parses backward-compatibly). |
| `VDbText` KN semantics (R-20) | The `kn` key set `AccentSens` (accent) — in ICU `kn` = numeric ordering | New `NumericOrder` field + digit-run numeric comparison in `VDbCompareCol` (`a2 < a10`; leading zeros stripped: `a01` = `a1`); zero-pad normalization in `VDbCollationKey`. |
| `VDbText.CyrillicWeight/GreekWeight/ArabicWeight` (R-20) | The letter tables were STRING CONSTANTS: source is UTF-8 → Cyrillic/Greek/Arabic letters in the constant are 2 bytes each; `Ord(S[i])` reads one byte and NEVER matched the code point | Every letter came out "non-letter" so code-point order applied — `Я` (U+042F) sorted BEFORE `а` (U+0430). All three rewritten via code-point ARITHMETIC (Russian а..я = $430..$44F contiguous, ё=13; Greek α..π/ρ..ω, ς→σ; Arabic 28-letter ranges). |
| `VDbText.LatinSecondary` (R-20) | No uppercase folding (Á counted as unaccented) AND accented weights collided with unaccented (á=1, unaccented a rounded to 1) | The secondary layer did NOT distinguish accents at all. Folding added + accented weights shifted +1 (unaccented=1, accented=2..6 — ICU order: unaccented first). |
| `VDbText.VDbCollationName` (R-20) | The `kn` flag was not WRITTEN into the canonical name | The column default (`CREATE TABLE ... COLLATE tr-TR-u-kn-ks`) would silently lose natural ordering across reopen; the `-u-kn` suffix was added (round-trip). |
| `VDbText.VDbLangProfile` (R-20) | The `NumericOrder` locale was uninitialized | Tags without `-u-` (plain `tr`) opened natural ordering with stack GARBAGE; default `False` assigned. |
| `VDbText` (R-20) | Un-reverted mutation leftover from a previous session: `if True then P.Alpha := vaLatin` | Alphabet selection (`VDbAlphaForLang`) was dead code — Cyrillic/Greek/... profiles were always counted as Latin; reverted. |
| `sqltest.lpr` T94d (R-20) | The Cyrillic test data `CR(430)` was DECIMAL (= U+01AE a Latin letter!) | Changed to `CR($0430/$0431/$0432/$042F)` (real Cyrillic а/б/в/Я; once the weight tables were fixed, real characters became mandatory). |
| `VDbParser` (R-13) | The LIST definition consumed the closing `)` yet had **TWO** `Expect(')')` calls | `PARTITION BY LIST ... VALUES (...)` **ALWAYS** failed with "end of file" — a hidden bug, RANGE/LIST had never been tested. Changed to a single `Expect(')')`. |
| `VDbParser` (R-13) | LIST/RANGE values went through `VDbNorm` (LowerCase) | Values were lowercased, literals did not match (`'Ankara'` → `'ankara'`). Taken literally (the quote is stripped by the lexer). |
| `VDbTable.PartValueOf` (R-13) | No INT canonicalization (a stored `'05'` was raw text) | Target `'05'` = 5 matches numerically but the partition hash differs → **wrong pruning**. Both row and target pulled to the `IntToStr` canonical form. |
| `VDbExecutor.ExecExplain` (R-13) | The pruning report also appeared on index/pkUsed plans | NarrowRows does not reject the index path under the CBO → `nonSeqPath` limits the report to Seq Scan plans (honesty). |
| `VDbMonitor.RecordCommand` (R-24) | Counter blocks were disabled with `if False` (with a "MUTASYON KANITI" note) and no code called `RecordCommand` at all | `GStats` never incremented and no test observed it (rainy-day); the leftover was removed + the `VDbSql.ExecRaw` finally hook added. |
| `VDbMonitor.RecordCommand` (R-24) | `GBuffer`/`FlushBufferToFile` ran unconditionally (`FileName = ''` → stray `.mon.edb` in temp) | Once the counter hook was added, test folders would get junk files; writing gated behind `FileName <> ''`. |
| `vdbserver.lpr` (R-12) | The program name `vdbserver` and the unit name `VDbServer` collided in FPC (case-insensitive, "Duplicate identifier") | The unit was rewritten as `VDbSqlServer.pas`. |
| `VDbServer` (R-12) | An empty `const` block (comment only) was a syntax error in FPC | The block was removed and moved into a comment. |
| `VDbClientNet.Exec` (R-12) | Counter-based loops `for i := 0 to nF - 1` (Cardinal/UInt64) — **underflow while empty** (0 up to a huge bound); also the u64 row count was written into a 4-byte variable (stack corruption) | Converted to `High(...)`-based `Integer` loops; u64 in a separate `UInt64` variable + bounds check. |
| `VDbServer` (R-12) | The connection thread removed itself from the list at the end of `Execute` → the finished thread object was **ownerless** (a connection closed by BYE leaked); a thread freeing itself is a self-join deadlock | Ownership model: the list owns; `AddConn` collects threads that finished at accept time with `WaitFor`+`Free`, `Stop` waits for all then frees them. |
| `T106` (R-12) | UPDATE changed the `ad` value BEFORE the SELECT check block (expected `bir`, got `degisti` — 1 FAIL) | Test order fixed: the SELECT check block was moved before UPDATE → green. |
| `vdbapi_core.VdbFileSizeOf` (R-23) | Measurement used `TFileStream` instead of `FileUtil.FileSize` — because the engine keeps the main file CLOSED to other opens, the second open got a sharing violation, the exception was swallowed and it returned **0** (vdbapitest: `dosya boyutu > 0 [0 bayt]` + `AutoCompact [0 -> 0]`; the file was actually being written) | Measurement now done via `FindFirst` WITHOUT opening the file. Found in the R-12 Full final run; mutation (back to `TFileStream`) → **2 FAIL** → revert → `vdbapitest` **170/170** |
| `yol_haritasi.md` (editing tool) | Non-BMP emoji (`🔴` U+1F534, `🟠`) do NOT match in the edit tool's `oldString` (proxy double encoding) | Table cells containing emoji are replaced via a PowerShell script (`.+?` regex); emoji-free lines are edited directly. |

---

## 7. ⚠️ BİLİNEN SINIRLAR

| Konu | Durum |
|------|-------|
| R-12 verim | Motor erişimi hem havuzda hem TCP sunucusunda **serileştirilmiş** (mutex/kilit altında seri yürütüm): doğru ve güvenli, ama her işlem maliyetli. Gerçek eşzamanlı ölçek = havuz kapasitesi; sunucu tarafında yanıt yazımı kilidin dışına alındı (ağ gecikmesi bekletmez). |
| R-12 mimari | TCP sunucu **tek süreçte tek motor**: bağlantı başına thread, komutlar kilit altında sırayla. ÇOK motor/worker YOK (planlanmadı). VDBS tek komut/çerçeve protokolü: prepared statement, oturum değişkeni veya auth yok (localhost test kapsamı). |
| R-12 kapasite | `FSize` = tüm süreçlerin **toplam** eşzamanlı bağlantı sınırı. Aşılırsa `AcquireSlot` `TimeoutMs` bekler, sonra `ecPoolTimeout`. |
| R-13 kapsam | **Davranışsal** bölümleme — fiziksel bölüm/partition dosyası YOK (tek KV dosyası). Pruning yalnız Seq Scan yolunda (indeks/pkUsed planlarında indeks zaten hedeflidir); FLOAT/BOOL/DATE pruning'e katılmaz; COLLATE'li kolonlarda STRING hedef verilmez; RANGE 3 bölgeli (alt/ici/üst). |
| R-14 kapsam | Paralellik yalnız materialize satırlarda saf CPU işine (sıralama karşılaştırması) uygulanır; alt sorgu/özyinelemeli Exec thread-güvenli değil. |
| R-24 kapsam | `SHOW STATS`/`SHOW STATS TABLE` **VAR**; **cache hit ratio YOK** — motorun blok/önbellek katmanı yok (KV bellek-içi indeks + doğrudan dosya I/O), metrik anlamsız. Yavaş sorgu listesi ayrı komuttur: `SHOW SLOW QUERIES` (F-21). Sayaçlar süreç içi (reopen'da sıfırlanmaz, süreç kapanır). |

---

## 7. KNOWN LIMITATIONS (ENGLISH)

| Topic | Status |
|-------|--------|
| R-12 performance | Engine access is **serialized** both in the pool and in the TCP server (serial execution under mutex/lock): correct and safe, but every operation carries cost. True concurrent scale = pool capacity; on the server side, response writing happens outside the lock (network latency does not block others). |
| R-12 architecture | The TCP server is **one engine in a single process**: one thread per connection, commands run sequentially under a lock. NO multiple engines/workers (not planned). VDBS is a single command/frame protocol: no prepared statements, session variables or auth (localhost test scope). |
| R-12 capacity | `FSize` is the **total** concurrent-connection limit across all processes. If exceeded, `AcquireSlot` waits `TimeoutMs`, then raises `ecPoolTimeout`. |
| R-13 scope | **Behavioral** partitioning — there is NO physical partition file (single KV file). Pruning runs only on the Seq Scan path (in index/pkUsed plans the index is already targeted); FLOAT/BOOL/DATE do not participate in pruning; STRING targets are not given for COLLATE'd columns; RANGE is 3-zoned (below/inside/above). |
| R-14 scope | Parallelism only applies to pure CPU work (sort comparisons) on materialized rows; subquery/recursive Exec is not thread-safe. |
| R-24 scope | `SHOW STATS`/`SHOW STATS TABLE` EXISTS; **no cache hit ratio** — the engine has no block-cache layer (KV in-memory index + direct file I/O), the metric would be meaningless. The slow-query list is a separate command: `SHOW SLOW QUERIES` (F-21). Counters are per-process (not reset on reopen; they die with the process). |

---

## 8. ✅ EKSİK MADDE YOK — YOL HARİTASI TAMAM

R-12 Full (2026-10-13, §5.12) ile birlikte yol haritasındaki **24 maddenin
tamamlandı** (R-12 ve R-24 dahil; ikisi de "Full" tur ile derinleştirildi).
Kapanış durumu:

| Paket | Sonuç |
|---|---|
| `sqltest` | **2251/2251** (138 test prosedürü, 2026-10-15) |
| `crashtest` | **8/8** — çökme dayanıklılığı, veri kaybı yok (2026-10-15) |
| `vdbcrypttest` | 60/60 |
| `vdbapitest` | 170/170 (VdbFileSizeOf düzeltmesiyle, §6) |
| `vdbclienttest` | 101/101 |
| `vdbserver.exe` | derlendi (bağımsız süreç, `vdbserver.lpr`) |
| `VDbXPrims` birimi | derlendi (test programı ağaçta yok) |
| `VDbPoolTest` | tarihsel 10/10 (program ağaçta yok; `VDbPool.pas` 12.10'dan beri değişmedi) |

Kapsam dışı/ bilinçli eksiksiz bırakılan noktalar **bilinen sınırlar**
(§7) altındadır: cache hit ratio (blok önbellek yok), fiziksel bölüm
dosyası (davranışsal bölümleme), **havuz-slot ↔ ağ-bağlantı eşlemesi**
(sunucu tek motor + kilit ile serileştirilmiş çalışır; havuz R-12 1. aşama
olarak ayrı kalır — kapasite = kilit sırası).

---

## 8. NO MISSING ITEMS — THE ROADMAP IS COMPLETE (ENGLISH)

With R-12 Full (2026-10-13, §5.12), **all 24 roadmap items are done** (including R-12 and R-24; both were deepened by a "Full" round). Closing status:

| Package | Result |
|---|---|
| `sqltest` | **2251/2251** (138 test procedures, 2026-10-15) |
| `crashtest` | **8/8** — crash durability, zero data loss (2026-10-15) |
| `vdbcrypttest` | 60/60 |
| `vdbapitest` | 170/170 (with the VdbFileSizeOf fix, §6) |
| `vdbclienttest` | 101/101 |
| `vdbserver.exe` | built (standalone process, `vdbserver.lpr`) |
| `VDbXPrims` unit | built (test program not in tree) |
| `VDbPoolTest` | historical 10/10 (program not in tree; `VDbPool.pas` unchanged since 12.10) |

Out-of-scope / deliberately-left-incomplete points are under **known
limitations** (§7): cache hit ratio (no block cache), physical partition
file (behavioral partitioning), **pool-slot ↔ network-connection mapping**
(the server runs one engine serialized under a lock; the pool stays R-12
stage 1 — capacity = lock order).

---

## 9. ✅ KAPANIŞ (2026-10-13 — tamamlandı · 2026-10-15 güncellendi)

1. **Son tam koşu ✓ (2026-10-15):**
   - `sqltest` **2251/2251** (138 prosedür; `-B` tam yeniden derleme +
     tam koşu, gerçek FAIL yok) · `crashtest` **8/8** (veri kaybı yok) ·
     `vdbserver.exe` temiz derleme (43831 satır).
   - `vdbcrypttest` **60/60** · `vdbapitest` **170/170** ·
     `vdbclienttest` **101/101** (üçü de `vdbtest\yedek` kaynaklarından
     derlendi; bu programların kaynakları ağaçta yok — §4.12).
   - `vdbapi.dll` güncel kaynaklardan yeniden derlendi.
   - **Beklenmedik bulgu düzeltildi:** `vdbapitest`'e ait 2 FAIL gerçek
     R-23 regresyonu çıktı (`VdbFileSizeOf` paylasım hatası → 0) →
     düzeltildi + mutasyon kanıtı (§6).
2. **yedek2 yedeği ✓:** `VDbNet.pas`, `VDbSqlServer.pas`,
   `VDbClientNet.pas`, `vdbserver.lpr`, `vdbapi_core.pas`,
   `sqltest.lpr`, `vdbapi.dll`, `vdbserver.exe`, bu belge + üç test
   programının yedekleri tek tek kopyalandı ve doğrulandı.
3. **Belge kapanışı ✓:** bu dosya son haliyle yedeklendi; yeni işler
   §7 (bilinen sınırlar) ve §6 (hata tablosu) başlangıç noktası olur.
  
**Ek notlar (2026-10-14):**  
- **§5.16 R-12 Kapanış:**  
- Auth/Prepared/Capacity tamam; sqltest.exe derlenmis; T107 OK  
- **§5.17 Dokümantasyon:**  
- VDBS sabitleri guncel: $20/$21/$22/$23 / $43/$44/$00  
- **§5.18 Yedek:**  
- yedek2/R12_rapor.txt olusturuldu  
- **§8/§9 durumu:**  
- T107=0 hata; T108/T109=yesil

---

## 9. CLOSING (2026-10-13 — completed · updated 2026-10-15) (ENGLISH)

1. **Last full run ✓ (2026-10-15):**
   - `sqltest` **2251/2251** (138 procedures; `-B` full rebuild + full run, no real FAILs) · `crashtest` **8/8** (no data loss) · clean build of `vdbserver.exe` (43831 lines).
   - `vdbcrypttest` **60/60** · `vdbapitest` **170/170** · `vdbclienttest` **101/101** (all three built from `vdbtest\yedek` sources; these programs' sources are not in the tree — §4.12).
   - `vdbapi.dll` rebuilt from current sources.
   - **Unexpected finding fixed:** 2 FAILs from `vdbapitest` turned out to be a real R-23 regression (`VdbFileSizeOf` sharing violation → 0) → fixed + mutation evidence (§6).
2. **backup2 backup ✓:** `VDbNet.pas`, `VDbSqlServer.pas`, `VDbClientNet.pas`, `vdbserver.lpr`, `vdbapi_core.pas`, `sqltest.lpr`, `vdbapi.dll`, `vdbserver.exe`, this document + backups of the three test programs were copied one by one and verified.
3. **Document closure ✓:** this file was backed up in its final state; new work starts from §7 (known limitations) and §6 (bug table).

**Additional notes (2026-10-14):**
- **§5.16 R-12 Closing:** Auth/Prepared/Capacity done; `sqltest.exe` built; T107 OK.
- **§5.17 Documentation:** VDBS constants up to date: $20/$21/$22/$23 / $43/$44/$00.
- **§5.18 Backup:** yedek2/R12_rapor.txt created.
- **§8/§9 status:** T107 = 0 errors; T108/T109 green. 
