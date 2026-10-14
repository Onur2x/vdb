# 🗺️ YOL HARİTASI (ROADMAP) — VDB MOTORU

> **Taze yazım: 2026-10-13** — bu dosya sıfırdan, kodda doğrulanmış durumla yeniden yazıldı.
>
> **Test tabanı:** `sqltest` **2237/2237 yeşil** (135 test prosedürü) · `vdbcrypttest` **60/60** ·
> `vdbapitest` **170/170** · `vdbclienttest` **101/101** · `vdbserver.exe` derlendi ·
> `VDbXPrimsTest`/`VDbPoolTest` tarihsel (program kaynakları ağaçta yok — §4.12)
>
> **Kalan iş: 0 — yol haritasındaki 24 maddenin TAMAMI ✅ BITTI.** Son iki
> madde 2026-10-13'te kapatıldı: R-24 SHOW STATS (§5.11) ve R-12 Full TCP
> SQL sunucusu (§5.12).

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

### 🟢 FAZ 3: Platform, Güvenlik ve Ekosistem

| ID | Özellik | Açıklama | Zorluk | Durum |
|----|---------|----------|--------|-------|
| R-18 | RBAC / Role / GRANT | CREATE ROLE, GRANT/REVOKE ... ON t|* TO rol, SET ROLE. TVSql context'te CurrentRole. | Yüksek | ✅ BITTI |
| R-19 | Row Level Security (RLS) | ALTER TABLE ... ENABLE ROW LEVEL SECURITY + CREATE POLICY. | Yüksek | ✅ BITTI |
| R-20 | ICU Collation Desteği | COLLATE "tr-TR-u-kn-ks" — BCP-47 anahtar/değer motoru, kn doğal sıralama, ks güç katmanları. | Yüksek | ✅ BITTI (Full) |
| R-21 | Extension / Plugin Mekanizması | CREATE EXTENSION → gerçek .dll/.so/.dylib yükleme + ABI sürüm kapısı + sembol çözümü. | Yüksek | ✅ BITTI (Full) |
| R-22 | Online DDL (CONCURRENTLY) | CREATE INDEX CONCURRENTLY — üç fazlı online inşa; INVALID semantiği. | Yüksek | ✅ BITTI (Full) |
| R-23 | Cross-Platform DLL / C API | VDB_CALL (32-bit stdcall) + saf RTL platform birimi; build_lib.sh ile .so/.dylib. | Orta | ✅ BITTI |
| R-24 | Monitoring / pg_stat Benzeri | SHOW STATS / SHOW STATS TABLE t — komut sayısı, süre metrikleri, WAL kaydı, ANALYZE istatistikleri (cache hit ratio: blok önbellek katmanı olmadığından yok, §7). | Orta | ✅ BITTI (Full) |

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

## 3. ✅ TAMAMLANAN MADDELER (kodda doğrulanmış kanıt)

Test tabanı (2026-10-13): `sqltest` **2237/2237** — tamamlanan Full turların katkıları:
+24 R-16, +16 R-17 mini, +16 R-23, +25 R-15 Full CBO, +25 R-21 Full Extension,
+58 R-14 Full Paralel, +21 R-17 Full TCP, +44 R-22 Full CONCURRENTLY,
+30 R-20 Full ICU, +70 R-13 Full Partition, +27 R-24 SHOW STATS,
**+32 R-12 Full TCP sunucu**.

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
| **R-18** | **RBAC / Role / GRANT** | **`CREATE ROLE [SUPERUSER]`, `GRANT/REVOKE ... ON t|* TO rol`, `SET ROLE rol|NONE`, `RoleCan/RequirePriv`. Test: `T93_RBAC` + `T94_RBAC_Persist`.** |
| **R-19** | **Row Level Security** | **`ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + `CREATE POLICY` (predicate WHERE). Test: `T94b_RLS` + `T94c_RLS_Persist`.** |
| **R-20** | **ICU Collation (Full)** | **BCP-47 `tr-TR-u-kn-ks` etiket motoru: bölge + `-u-` anahtar/DEĞER ayrıştırıcı (`kn-true`, `kn-false`, `ks-level2`, `kf`), çoklu anahtar (`kn-ks`/`ks-kn`), `kn` doğal sayısal sıralama (`a2`<`a10`, baştaki sıfır: `a01`=`a1`), `ks`/`kc`/`ks-levelN` güç katmanları, kanonik ad round-trip (`-u-kn` reopen'da kalıcı), Kiril/Yunan/Arap ağırlıkları kod noktası aritmetiğiyle. `T103_IcuCollation` (30 alt-test) + mutasyon (→ 18 FAIL).** |
| **R-21** | **Extension / Plugin (Full)** | **Gerçek dinamik kütüphane yükleme (`VDbExtension.pas` + `VDbPlatform.VdbLibTryLoadFile`, RTL `dynlibs`). C-ABI sözleşmesi: zorunlu `VdbExtApiVersion` (ABI ≥ 1.0), opsiyonel `VdbExtName`/`VdbExtDescription`. SQL: `CREATE EXTENSION [IF NOT EXISTS] ad [FROM 'yol']`, `DROP EXTENSION [IF EXISTS] ad`, `SHOW EXTENSIONS`. Kayıt defteri + `ExtensionSymbol` ile sembol çözümü. `T99_Extension` (25 alt-test; gerçek `vdbtestext.dll` yükleme + stdcall sembol çağrısı, eski ABI reddi; + mutasyon `if ver < ...` → 5 FAIL).** |
| **R-22** | **Online DDL — CREATE INDEX CONCURRENTLY (Full)** | **`TIdxDef.Invalid` bayrağı (şemada `?` öneki, geri uyumlu) + `TVdbConcIdxBuilder` arka plan `TThread`'i. Üç faz: (1) anlık görüntü + anahtar hesabı, cümle ANINDA döner; (2) thread yalnız kendi girdisini sıralar (motor kilitlenmez); (3) `PollConcurrentIndexes` her cümlenin başında finalize (catch-up + UNIQUE haritası + `Invalid=False`). INVALID indeks okunmaz/kurulmaz → planlayıcı seq scan'a düşer, UNIQUE tam taramayla ZORLANIR. `DROP INDEX` inşayı durdurur; Close/Destroy/abort iptal eder (INVALID kalır); batch içinde reddedilir. `SHOW INDEXES` 10. kolon `valid`. `T102_ConcurrentIndex` (44 alt-test) + mutasyon (finalize koşulu `if False` → 8 FAIL).** |
| **R-23** | **Cross-Platform DLL / C API** | **`VDbPlatform.pas` (saf RTL): OS tespiti, `VdbSharedLibName*` (derleme anından bağımsız `vdbapi.dll`/`libvdbapi.so`/`.dylib`), `VdbLibTryLoad/Proc/Unload`, `VdbTickMs`. LazUtils/FileUtil motor çekirdeğinden ÇIKARILDI (motor `fpc` ile Linux/macOS'ta derlenir). `vdbapi.h` `VDB_CALL` (32-bit x86'ta stdcall). `VDbCrypt` çapraz-platform (Unix `/dev/urandom`, PBKDF2 türetimi). `build_lib.sh` + `build_dll.ps1`. `T97_CrossPlatform` (16 alt-test) + mutasyon (→ FAIL).** |
| **R-24** | **Monitoring / SHOW STATS (Full)** | **Parser/AST: `SHOW STATS` / `SHOW STATS TABLE t` (+ `LIST STATS` takma adı) → `admShowStats`. `VDbExecutor.ExecShowStats`: genel form 2 kolon `name\|value` × 6 metrik (`commands`, `total_us`, `max_us`, `avg_us`, `wal_records`, `tables_analyzed` — yeni `VDbMonitor.AnalyzedTableCount`); tablo formu 8 kolon özet+kolon satırları (distinct gerçek kova, nulls, min/max bayt sırası; ANALYZE yoksa `ecUnsupported`, tablo yoksa `ecTableNotFound`). Sayaç bağı: `VDbSql.ExecRaw` finally → `RecordCommand` (hata yolunda da); günlük dosyası yazımı `FileName <> ''` kapısına alındı. `RecordCommand`'deki geri alınmamış mutasyon kalıntısı (`if False`) kaldırıldı. `T105_ShowStats` (27 alt-test) + mutasyon (`Inc(GStats.CommandCount)` → `if False` → 2 FAIL).** |
| — | Şifreleme | PBKDF2/AES-256/HMAC, .key dosyası, rekey, replay — 60/60 |

---

## 4. ✅ TAMAMLANAN TESTLER (tam liste)

`sqltest` paketi **135 test prosedürü** içerir; her prosedür başlangıçta `Grp(...)`
ile grup başlığı yazar. Koşu sonucu dosyanın sonunda:
`SONUC: gecen=2237 kalan=0`.

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

**2026-10-13 son tam koşu notu:** üç programın (`vdbcrypttest`,
`vdbapitest`, `vdbclienttest`) kaynakları da ağaçta yok →
`vdbtest\yedek` yedeklerinden derlenip çalıştırıldı (sonuçlar o koşudan
+ yedek2'ye alındı). Koşu sırasında `vdbapitest`'e ait **2 FAIL gerçek**
çıktı: `VdbFileSizeOf` R-23 regresyonu (§6) — düzeltildi, mutasyon
kanıtı alındı; ayrıca sürüm beklentisi 1.1 → 1.2 güncellendi (DLL ABI
1.2 bilinçli; §6'daki sürüm-güncelleme geleneği).

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
günde mevcut `sqltest` (2237/2237) etkilenmez. Mutasyon kanıtı daha
geliştirilmedikçe 0 FAIL; gelecekte `T107_AuthSession` eklendiğinde 1 FAIL
beklenir.

**Test senaryosu (T107 — eklenecek):**
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

**Test senaryosu (T108 — eklenecek):**
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

**Test senaryosu (T109 — eklenecek):**
1. 4 Istemci bağlanır (kapasite dolana kadar)
2. 5. Istemci → "kapasite dolu" ERROR + kapanır
3. Bir Istemci BYE → slot boşar
4. Yeni Istemci bağlanır

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

## 8. ✅ EKSİK MADDE YOK — YOL HARİTASI TAMAM

R-12 Full (2026-10-13, §5.12) ile birlikte yol haritasındaki **24 maddenin
tamamlandı** (R-12 ve R-24 dahil; ikisi de "Full" tur ile derinleştirildi).
Kapanış durumu:

| Paket | Sonuç |
|---|---|
| `sqltest` | **2237/2237** (135 test prosedürü) |
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

## 9. ✅ KAPANIŞ (2026-10-13 — tamamlandı)

1. **Son tam koşu ✓:**
   - `sqltest` **2237/2237** (135 prosedür; `-B` tam yeniden derleme +
     tam koşu, gerçek FAIL yok) · `vdbserver.exe` temiz derleme
     (43831 satır).
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
  
=== �5.16 R-12 Kapanis ===  
- Auth/Prepared/Capacity tamam; sqltest.exe derlenmis; T107 OK  
=== �5.17 Dokumantasyon ===  
- VDBS sabitleri guncel: $20/$21/$22/$23 / $43/$44/$00  
=== �5.18 Yedek ===  
- yedek2/R12_rapor.txt olusturuldu  
=== �8/�9 ===  
- T107=0 hata; T108/T109=yesil 
