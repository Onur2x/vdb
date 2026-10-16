# CHANGELOG — VDB (VeriTabanı)

Bu dosya sürümler arasında **ne yapıldığını** izler. Her sürümde: değişen
dosyalar, ölçülmüş etki ve (varsa) **bilinçli olarak yapılmayan** şeyler.

Sürümleme notu: motor dokümanlarında uzun süredir `2.0` (R-12 Full + 24 yol
haritası maddesi) ibaresi var; `v0.00x` serisi bu **performans/ölçüm**
akışını izler.

---

## v0.005 — 2026-10-16 — Hız turu: P-14/P-15 + adil kıyas (vsbench) + ölü kod temizliği

### Ne eklendi / değişti

- **P-14a — tahsis-siz `VDbNorm` hızlı yolu + `IsView` tek `TryGetValue`**
  (`VDbTable.pas`): ASCII-üstü/büyük harf/kabartma içermeyen dizilerde
  `Trim+LowerCase` hiç çağrılmıyor, aynı referans dönüyor (davranış bit-bit aynı;
  FPC `Trim`'in yalnız ' ' ve #9 sildiği `ttrim.pas` ile doğrulandı). Sema/kolon
  aramaları satır başına ~15 kez bu fonksiyondan geçiyor.
- **P-15a — `SortIdxEntries` decorated INT sort** (`VDbTable.pas`): INTEGER
  indeks anahtarları karşılaştırma başına yeniden parse edilmek yerine bir kez
  Int64'a çözülüp dekorlu anahtarla sıralanıyor; NULL-en-önde sıra ve
  `CompareStr(Pk)` tie-break birebir korundu; parse edilemeyende eski yola düşer.
  Lazy PK index rebuild 300K'da **2123 → 892 ms**; RANGE sorgularının kök
  nedeni bu tek-seferlik rebuild'miş (sorgu başına 25 ms sanılıyordu).
- **P-12 `TryStreamAgg`** (`VDbExecutor.pas`) ve **P-13 `ScanSnapshot` toplu
  okuma + counting-sort bucket** (`VDbCore.pas`): agregatlarda satır matrisi
  malzelleştirmesi yok; taramada satır başına 3 syscall yerine bucket başına tek
  toplu okuma.
- **R-26 tablo-tarama filtresi** kodla bu turda yayımlandı (ayrıntı v0.004).
- **`vsbench.dpr` (yeni): SQLite ile ADİL hız testi** — 1M satır, aynı SQL metni,
  aynı disk, tek süreç, iki taraf da stok varsayılanlar (VDB `SyncWriteInterval=0`
  = senkron commit; SQLite varsayılan journal modu). Çalıştırmak için `sqlite3.dll`
  exe'nin yanında olmalı. **Sonuçlar aşağıda dürüst haliyle yazılı.**
- **Ölü kod temizliği** (`VDbExecutor.pas`, `VDbSql.pas`, `VDbTable.pas` ve
  yardımcı dosyalar): kullanılmayan yordam/birim parçaları kaldırıldı; davranış
  değişmedi (aşağıdaki gauntlet sıfırdan doğruladı).

### Ölçülmüş sonuç — adil kıyas run3 → run4 (1M satır)

| Aşama | run3 VDB | run4 VDB | SQLite | VDB/SQLite (run4) |
|---|---|---|---|---|
| INSERT 1M (tx) | 56.4 sn | 59.7 sn | 3.70 sn | 16.1x |
| COUNT(*) x10 | 1.06 sn | 1.20 sn | 44.8 ms | 26.8x |
| SUM(bakiye) x5 | 1.10 sn | 1.35 sn | 94.4 ms | 14.3x |
| SELECT PK 50K | 1.95 sn | **2.51 sn** | 3.53 sn | **0.71x — VDB hızlı** |
| RANGE 2000x100 | 12.3 sn | **8.54 sn** | 245 ms | **34.9x** (55x'ten indi) |
| UPDATE 100k | 7.4 sn | 8.59 sn | 318.8 ms | 26.9x |
| DELETE 100k | 5.2 sn | 6.10 sn | 229.7 ms | 26.6x |

- Doğrulama: iki motorun COUNT/SUM'ı eşit (5.000.000.000), DELETE sonrası 900.000.
- Kalan boşluk **mimari**: SQLite prepared statement kullanıyor; P-14 mikro
  ölçeklerinde INSERT'imizin ~56 µs'si = parse ~12 + glue ~9 + Insert/commit ~16
  + sarmalayıcı ~3-5 + heap büyüme cezası ~15 µs.

### Bilinçli olarak YAPILMAYANLAR

- **P-16 nokta-okuma adayı — REDDEDİLDİ:** BETWEEN uçlarından `IntToStr` ile anahtar
  üretmek, INT PK'ların yazım şekliyle saklanması (`'010'` kalır) nedeniyle
  `'01000'` gibi satırları sessiz düşürürdü → semantik bozucu.
- **Plan cache — ERTELENDİ:** yürütücü AST'yi mutasyona uğratıyor (`Stmt.Table :=
  baseTable`, `Stmt.Body` sahiplik devri); önbellek ancak immutable-plan denetimiyle
  güvenli (v0.003 kararı yeniden doğrulandı).
- **Index-only COUNT — REDDEDİLDİ:** "veri bozuksa bağır" sözleşmesiyle çelişir.
- **P-15b peek-rebuild — SONRAKI ADAY:** `BuildPkIdx` hâlâ tam-decode `ScanRows`
  kullanıyor (~620 ms @300k); stream/peek rebuild orta riskli, ayrıca plan cache
  ile birlikte değerlendirilecek.

### Doğrulama (ölü kod temizliği sonrası SIFIRDAN)

- `fpc -B` derlemeleri hatasız (sqltest 55.383 satır; crashtest 44.364 satır).
- `sqltest` **2251/2251**, kalan=0, KESILDI yok (`sqltest_restart.log`).
- crashtest 8'li çarpma zinciri **8/8** "copme sonrasi veri kaybi/bozulma YOK"
  (`c8_restart.log`) — `SyncWriteInterval=0` dayanıklılık sözleşmesi değişmedi.

---

## v0.005 — 2026-10-16 — Speed round: P-14/P-15 + fair benchmark (vsbench) + dead-code cleanup (ENGLISH)

### Added / changed

- **P-14a — allocation-free `VDbNorm` fast path + single `TryGetValue` in `IsView`**
  (`VDbTable.pas`): strings without non-ASCII, uppercase or trim-requiring edge
  whitespace return the SAME reference — `Trim+LowerCase` is never called and
  behavior stays bit-identical (FPC `Trim` only strips ' ' and #9, verified with
  `ttrim.pas`). Schema/column lookups hit this ~15 times per row.
- **P-15a — decorated INT sort in `SortIdxEntries`** (`VDbTable.pas`): INTEGER index
  keys are decoded to Int64 once instead of re-parsed per comparison; NULL-first
  ordering and the `CompareStr(Pk)` tie-break preserved bit-for-bit; unparsable keys
  fall back to the legacy path. Lazy PK index rebuild at 300K: **2,123 → 892 ms**.
  The root cause of the RANGE gap turned out to be this one-time rebuild (previously
  mistaken for 25 ms per query).
- **P-12 `TryStreamAgg`** (`VDbExecutor.pas`) and **P-13 batched `ScanSnapshot` reads
  with counting-sort buckets** (`VDbCore.pas`): aggregates no longer materialize the
  row matrix; scans issue one batched read per bucket instead of 3 syscalls per row.
- **R-26 table-scan filter** shipped with this round (details in v0.004).
- **`vsbench.dpr` (new): FAIR speed test vs SQLite** — 1M rows, same SQL text, same
  disk, single process, both engines on stock defaults (VDB `SyncWriteInterval=0`
  = synchronous commit; SQLite default journal mode). Needs `sqlite3.dll` next to
  the exe. **Honest results below.**
- **Dead-code cleanup** (`VDbExecutor.pas`, `VDbSql.pas`, `VDbTable.pas` and helper
  files): unused routines/unit parts removed; behavior unchanged (gauntlet below
  re-verified from scratch).

### Measured — fair comparison run3 → run4 (1M rows)

| Phase | run3 VDB | run4 VDB | SQLite | VDB/SQLite (run4) |
|---|---|---|---|---|
| INSERT 1M (tx) | 56.4 s | 59.7 s | 3.70 s | 16.1x |
| COUNT(*) x10 | 1.06 s | 1.20 s | 44.8 ms | 26.8x |
| SUM(balance) x5 | 1.10 s | 1.35 s | 94.4 ms | 14.3x |
| SELECT PK 50K | 1.95 s | **2.51 s** | 3.53 s | **0.71x — VDB faster** |
| RANGE 2000x100 | 12.3 s | **8.54 s** | 245 ms | **34.9x** (down from 55x) |
| UPDATE 100k | 7.4 s | 8.59 s | 318.8 ms | 26.9x |
| DELETE 100k | 5.2 s | 6.10 s | 229.7 ms | 26.6x |

- Verification: COUNT/SUM identical across engines (5,000,000,000); 900,000 rows after DELETE.
- The remaining gap is **architectural**: SQLite uses prepared statements; our
  ~56 µs per INSERT breaks down as parse ~12 + glue ~9 + Insert/commit ~16 +
  wrapper ~3-5 + heap growth penalty ~15 µs (P-14 micro-benchmarks).

### Deliberately NOT done

- **P-16 point-read candidate — REJECTED:** generating keys with `IntToStr` from
  BETWEEN bounds would silently drop rows such as `'01000'`, since INT PKs are
  stored exactly as written (`'010'` stays). Semantics-breaking.
- **Plan cache — DEFERRED:** the executor mutates the AST (`Stmt.Table := baseTable`,
  `Stmt.Body` ownership transfer); a cache is only safe with an immutable-plan audit
  (v0.003 decision re-confirmed).
- **Index-only COUNT — REJECTED:** conflicts with the "shout if data is corrupt" contract.
- **P-15b peek-rebuild — NEXT CANDIDATE:** `BuildPkIdx` still full-decodes via
  `ScanRows` (~620 ms @300K); stream/peek rebuild is medium-risk, to be evaluated
  together with the plan cache.

### Verification (FROM SCRATCH after dead-code cleanup)

- Clean `fpc -B` builds (sqltest 55,383 lines; crashtest 44,364 lines).
- `sqltest` **2251/2251**, 0 remaining, no aborts (`sqltest_restart.log`).
- 8-crash crashtest chain **8/8** "no data loss/corruption after crash"
  (`c8_restart.log`) — the `SyncWriteInterval=0` durability contract unchanged.

---

## v0.004 — 2026-10-15 — Tablo-tarama filtresi (R-26): 240x hızlanma

### Ne eklendi

**R-26 — Tablo-tarama filtresi (Table-scan filter)** — `VDbCore.pas`, `VDbTable.pas`
- **Sorun:** `SELECT * FROM kucuk LIMIT 10` bir başkasındaki 150K satırlı
  tabloyı da okudu + çözdü + atıyor → 1.782 ms → **743x yavaş**.
- **Çözüm:** Her satırın `TableId`'si (ilk 2 bayt, little-endian) zaten
  `Recover`'da CRC için okunuyor ve `AppendRec`'te yazılıyor — buradan
  **bedava çıkar** ve `TDbLoc.TableId: Integer` alanına yazılır.
- `ScanSnapshot` / `ScanAll` artık opsiyonel `TableFilter: Integer`
  parametresi alır; `TableId >= 0` ve `TableId <> Filter` ise dosya
  okunmaz (en pahalı yol elenir).
- Dört çağrı sitesi (`ScanRowsPart`, `ALTER TABLE`, `RENAME TABLE`,
  `DROP TABLE`) `t.TableId` filtresi ile güncellendi.
- Şema kaydı (`VDB_SCHEMA_KEY = 0`) `VDB_SCHEMA_TAG = 'VSCH1'` ile
  tespit edilip `TableId := -1` atanır → filtre uygulanmaz, eski
  davranış **birebir korunur**.

### Ölçülmüş sonuç (aynı makine, autocommit/transaction karışık)

| Senaryo | Eski | Yeni | Kazanç |
|---|---|---|---|
| A=0, B LIMIT 10 | 2.4 ms | 2.3 ms | — |
| A=50K, B LIMIT 10 | 582 ms | 4.3 ms | **135x** |
| A=150K, B LIMIT 10 | 1.782 ms | **7.4 ms** | **240x** |

- Etiketler **aynı oturumda** (`AppendRec` yazar) VE **yeniden açmada**
  (`Recover` okur) doğru → uzun süreli sunucularda da geçerli.

### Speedtest (v0.004 sonrası) — VDB vs SQLite 3.54.0

| İşlem | VDB Fast (10ms) | SQLite WAL | Not |
|---|---|---|---|
| Batch INSERT 10K | 38K/sn | 1.5M/sn | SQLite WAL çok hızlı |
| **Multi-row VALUES (100/stmt)** | **57K/sn** | — | **1.5x batch** ✅ |
| Single INSERT (autocommit) | **16K/sn** | 51K/sn | **Group commit 16x** (eski 1K/sn) ✅ |
| SELECT PK (nokta) | 43K/sn | 338K/sn | — |
| **Range BETWEEN** | **401/sn** | 68K/sn | **Bottleneck** (string-matris materyalizasyonu) |
| UPDATE | 15K/sn | 53K/sn | — |
| DELETE | 20K/sn | 51K/sn | — |

- R-26 tek-tablo range'i iyileştirmez (diğer tablo filtresi yok);
  bottleneck burada **string-matris materyalizasyonu** (Aşama 3.1 hedefi).

### Değişen dosyalar

- `VDbCore.pas`: `TDbLoc.TableId`, `RowTagFunc` property, `AppendRec`,
  `Recover` (pendTag), `ScanSnapshot`/`ScanAll` filtre.
- `VDbTable.pas`: `VDbRowTagOf` callback, `TVTableDb.Create` ataması,
  4 `ScanAll` çağrısı filtreli.

### Doğrulama

- `sqltest` **2224 OK / 2 FAIL** (opsiyonel `vdboldtext.dll` /
  `vdbtestext.dll` eksik — önceden biliniyor). Yeni regresyon **yok**.

---

## v0.003 — 2026-10-14 — Performans turu: PK Lazy Index + Group Commit + SQLite kıyası

### Ne eklendi

**R-25 — PK Lazy Index** (`VDbTable.pas`, `VDbExecutor.pas`)
- PK kolonu üzerinde `T.Idx`'e dokunmadan tembel sıralı index kurulur
  (`FPkIdx` / `FPkIdxDirty` + `BuildPkIdx`).
- `TryGetMemIndex` PK kolonu için lazy index döndürür; kirli ise yeniden kurar.
- `IndexUsedByWhere` PK kolonunu tanır (`Ix := -2` → `<tablo>_pkey`);
  `if Length(Td.Idx) = 0 then Exit;` erken çıkışı kaldırıldı.
- **Etki:** `BETWEEN` / range sorguları Seq Scan yerine Index Scan kullanır.
  Range 26/sn → ~400/sn (**~15x**). `EXPLAIN` bunu `Index Scan using b_pkey`
  olarak gösterir.
- **Neden `T.Idx`'e otomatik PK index EKLENMEDİ:** testleri kırıyordu
  (`IndexNames`, indeks sayım testleri) ve `CheckConstraints` her INSERT'te
  `TryGetMemIndex` → `FlushIdxPending` → O(n log n) yeniden sıralama →
  35x yavaşlama üretiyordu.

**R-25 — Group Commit** (`VDbCore.pas`)
- `SyncWriteInterval` özelliği (PostgreSQL `commit_delay` benzeri, ms).
- `Put` / `Delete` / `Flush` / `CommitBatch` fsync kontrolü bu süreye bağlandı.
- **Kritik düzeltme:** `CommitBatch`'in de dahil edilmesi gerekti. Yalnız
  `Flush` güncellendiğinde kazanç ~%3 idi; `CommitBatch` dahil edilince
  UPDATE/DELETE gerçekten hızlandı.
- Varsayılan `0` = eski davranış (her yazmada fsync) — mevcut kod yolu
  davranışı **değişmez**.
- Dayanıklılık takası: `>0` ise en fazla o kadar ms gecikmeyle fsync;
  `FDirty` False bırakılmaz.

**Benchmark ve ölçüm araçları**
- `speedtest.dpr` — VDB vs SQLite 3.54.0 kıyası (aynı sema/veri/SQL).
  `ParamStr(1)` ile çalışma dizini; SQLite `sqlite3.dll` yanında olmalı.
  Çoklu VALUES satırı da içerir (aşağıda R-26).
- `parseprobe.dpr` — parse payını ölçer (yeni parser nesnesi vs saf parse vs tam Exec).
- `batchprobe.dpr` — tek satır vs çoklu VALUES.
- `layerprobe.dpr` — SQL katmanı / tablo katmanı ayrıştırması.

### Ölçülmüş sonuçlar (aynı makine, transaction içi)

| Katman / yol | Sonuç |
|---|---|
| Parse payı (nokta SELECT) | 4,7 µs/is = **%43** (tam Exec 10,9 µs) |
| Yazma yolu分解 (20K satır) | Tam yol 26,6 µs/satır; tablo katmanı 11,8 µs/satır → **SQL katmanı %56** |
| ÇOKLU VALUES (100/stmt) | 36K → **55K satır/sn (1,5x)** |

**VDB vs SQLite (en iyi modlar):** VDB group-commit UPDATE 15K/sn, DELETE 20K/sn
— SQLite'ın **kendi varsayılan dayanıklı moduna** (54-55/sn) karşı 280-370x.
Ama SQLite WAL'e (50K/sn yazma, 289K/sn nokta SELECT) karşı geride.

### Bilinçli olarak YAPILMAYANLAR (ölçülüp reddedilen)

- **AST / statement cache — REDDEDİLDİ.** Yürütücü AST'yi değiştiriyor:
  VIEW DML'de `Stmt.Table := baseTable` (VDbExecutor ~6561/7056/7307),
  CREATE TABLE'da `Stmt.Checks := ...` (~7538), trigger/function'da
  `Stmt.Body := nil` sahiplik devri (~8189). Cache'leme ikinci çalıştırmada
  bozardı. `EvalExpr` literal yolu zaten hızlı (`Exit(lit.AsString)`).
- **Tetik/RLS döngü-hoist — REDDEDİLDİ.** Kazanç küçük (boşken zaten hızlı
  çıkıyor) ama semantik risk var (tetik listesi satır başına yeniden
  değerlendiriliyor). Değmez.
- **Tip-değer yazma yolu — yapılmadı.** 11,8 µs/satır tabanı string-KV;
  altına inmek storage'ı tip-binary'a çevirmek demek (motorun yeniden yazımı).

### Diğer güncellemeler
- `quickbench.dpr` — `DROP TABLE IF EXISTS` (eski sabit `C:\temp\qb` hatası),
  group-commit benchmark satırları.
- `yol_haritasi.md` — R-25 eklendi (FAZ 2, kanıt satırı, §5.16 tarihçe).
- `SQL.md` — `EXPLAIN ... BETWEEN` → `Index Scan using <tablo>_pkey`.
- `docs/01-MOTOR.md` — VDbCore (SyncWriteInterval), VDbTable (PK lazy index),
  VDbExecutor (IndexUsedByWhere PK desteği).
- `docs/02-DOSYA-FORMATI.md` — §4 commit-flush → group commit.
- `README.md` — girişe PK Lazy Index + Group Commit.

### Doğrulama
- `sqltest` **2224 OK / 2 FAIL** (opsiyonel `vdboldtext.dll` / `vdbtestext.dll`
  eksik — önceden biliniyor). Yeni regresyon **yok**.

---

## v0.002 — Temel özellik turu (özet)

Motorun SQL/özellik kapsamını genişleten ve kararlı hâle getiren turlar
(ayrıntılar `yol_haritasi.md` §3-§5):

- R-12 Connection Pool + TCP SQL sunucusu (VDBS) — tam
- R-13 Partitioning, R-14 Parallel Query, R-15 Cost-Based Optimizer
- R-16 WAL Arşivleme + PITR, R-17 Streaming Replication (dosya + TCP)
- R-18 RBAC, R-19 Row Level Security, R-20 ICU Collation
- R-21 Extension/Plugin, R-22 CREATE INDEX CONCURRENTLY
- R-23 Cross-Platform C API, R-24 SHOW STATS
- MVCC, SAVEPOINT, UPSERT, RETURNING, Trigger, View, Stored Procedure,
  JSONB, Spatial, Range, CDC, TimeTravel, şifreleme (AES-256 + PBKDF2)

---

## v0.001 — İlk sürüm

Tek dosyada çalışan, append-only KV üzerine kurulmuş ilişkisel çekirdek
(`VDbCore` + `VDbTable`), SQL katmanı (`VDbParser` / `VDbAst` /
`VDbExecutor` / `VDbSql`), WAL, şifreleme, `TDataSet` köprüsü.
