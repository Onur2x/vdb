# CHANGELOG — VDB (VeriTabanı)

Bu dosya sürümler arasında **ne yapıldığını** izler. Her sürümde: değişen
dosyalar, ölçülmüş etki ve (varsa) **bilinçli olarak yapılmayan** şeyler.

Sürümleme notu: motor dokümanlarında uzun süredir `2.0` (R-12 Full + 24 yol
haritası maddesi) ibaresi var; `v0.00x` serisi bu **performans/ölçüm**
akışını izler.

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
