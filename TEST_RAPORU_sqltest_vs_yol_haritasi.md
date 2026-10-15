# sqltest.exe Test Raporu — Yol Haritası Karşılaştırması (TEST REPORT — sqltest vs Roadmap)

> **TR** — Bu rapor `sqltest.exe` sonuçlarını `yol_haritasi.md` maddeleriyle madde madde karşılaştırır.
> **Tarih:** 2026-10-15 · **sqltest:** 2251/2251 · **crashtest:** 8/8
>
> **EN** — This report compares `sqltest.exe` results item by item against `yol_haritasi.md`.
> **Date:** 2026-10-15 · **sqltest:** 2251/2251 · **crashtest:** 8/8

---

## 1. Test Sonuçları / Test Results

```
$ ./sqltest.exe
SONUC: gecen=2251 kalan=0
TUM SQL TESTLERI GECTI
```

**TR:**

- **Toplam test:** 2251 — **138 test prosedürü** (T01…T109)
- **Başarısız:** 0
- Yanında koşulan paketler: `crashtest` **8/8** (çökme dayanıklılığı, veri kaybı yok) ·
  `vdbcrypttest` **60/60** · `vdbapitest` **170/170** · `vdbclienttest` **101/101** ·
  `vdbserver.exe` derlendi · `vdbapi.dll` derlendi

**EN:**

- **Total tests:** 2251 — **138 test procedures** (T01…T109)
- **Failed:** 0
- Companion suites: `crashtest` **8/8** (crash durability, zero data loss) ·
  `vdbcrypttest` **60/60** · `vdbapitest` **170/170** · `vdbclienttest` **101/101** ·
  `vdbserver.exe` built · `vdbapi.dll` built

---

## 2. Yol Haritası Madde Madde Kontrolü / Roadmap Item Check

### TR

| ID | Harita İddiası | sqltest Karşılığı | Durum |
|----|----------------|-------------------|-------|
| R-01 | MVCC / Snapshot Isolation — BITTI | T90/T91/T92 MVCC (transaction snapshot, yazar-okuyucu eşzamanlılığı, nested SELECT snapshot) | UYUMLU ✅ |
| R-02 | SAVEPOINT — BITTI | T79_Savepoint | UYUMLU ✅ |
| R-03 | UPSERT (ON CONFLICT) — BITTI | T10b_Upsert | UYUMLU ✅ |
| R-04 | RETURNING — BITTI | T11_Returning | UYUMLU ✅ |
| R-05 | Trigger (F-36) — BITTI | T08n_Trigger (BEFORE/AFTER/INSTEAD OF, ROW/STATEMENT, WHEN, OLD/NEW, nested) | UYUMLU ✅ |
| R-06 | View + VIEW DML — BITTI | T08l_ViewDML + T08k_MatView ilgili | UYUMLU ✅ |
| R-07 | Materialized View — BITTI | T08k_MatView | UYUMLU ✅ |
| R-08 | Stored Procedure / Function — BITTI | T08m_StoredProc | UYUMLU ✅ |
| R-09 | LATERAL JOIN — BITTI | T08j_Lateral | UYUMLU ✅ |
| R-10 | CYCLE Detection (Recursive CTE) — BITTI | T08e_CTE | UYUMLU ✅ |
| R-11 | DEFERRABLE Constraints — BITTI | T12_Transaction (SET CONSTRAINTS) | UYUMLU ✅ |
| R-12 | Havuz + TCP SQL Sunucusu (Full) — BITTI | T106 (32 alt-test) + T107/T108/T109 (auth/prepared/capacity) + VDbPoolTest 10/10 (tarihsel) | UYUMLU ✅ |
| R-13 | HASH/RANGE/LIST Bölümleme + Pruning (Full) — BITTI | T104_HashPartition (70 alt-test) | UYUMLU ✅ |
| R-14 | Parallel Query (Full) — BITTI | T100_Parallel (58 alt-test) | UYUMLU ✅ |
| R-15 | Cost-Based Optimizer (Full) — BITTI | T98_CBO (25 alt-test) | UYUMLU ✅ |
| R-16 | WAL Arşivleme + PITR — BITTI | T95_WALArsiv (24 alt-test) | UYUMLU ✅ |
| R-17 | Streaming Replication (Full) — BITTI | T95b (17) + T101_TcpReplication (21) | UYUMLU ✅ |
| R-18 | RBAC / Role / GRANT — BITTI | T93_RBAC + T94_RBAC_Persist | UYUMLU ✅ |
| R-19 | Row Level Security — BITTI | T94b_RLS + T94c_RLS_Persist | UYUMLU ✅ |
| R-20 | ICU Collation (Full) — BITTI | T94d/e + T103_IcuCollation (30 alt-test) | UYUMLU ✅ |
| R-21 | Extension / Plugin (Full) — BITTI | T99_Extension (25 alt-test) | UYUMLU ✅ |
| R-22 | Online DDL CONCURRENTLY (Full) — BITTI | T102_ConcurrentIndex (44 alt-test) | UYUMLU ✅ |
| R-23 | Cross-Platform DLL / C API — BITTI | T97_CrossPlatform (16) + vdbapitest 170/170 | UYUMLU ✅ |
| R-24 | Monitoring / SHOW STATS (Full) — BITTI | T94f + T105_ShowStats (27 alt-test) | UYUMLU ✅ |
| R-25 | PK Lazy Index + Group Commit — BITTI | bench ölçümleri (4x COUNT, 14x UPDATE…) + sqltest regresyonu yok | UYUMLU ✅ |

**TR sonuç:** Haritadaki **24+1 maddenin tamamı** test karşılığıyla doğrulandı.

### EN

| ID | Roadmap Claim | sqltest Counterpart | Status |
|----|---------------|---------------------|--------|
| R-01 | MVCC / Snapshot Isolation — DONE | T90/T91/T92 MVCC (transaction snapshot, writer/reader concurrency, nested SELECT snapshot) | CONSISTENT ✅ |
| R-02 | SAVEPOINT — DONE | T79_Savepoint | CONSISTENT ✅ |
| R-03 | UPSERT (ON CONFLICT) — DONE | T10b_Upsert | CONSISTENT ✅ |
| R-04 | RETURNING — DONE | T11_Returning | CONSISTENT ✅ |
| R-05 | Trigger (F-36) — DONE | T08n_Trigger (BEFORE/AFTER/INSTEAD OF, ROW/STATEMENT, WHEN, OLD/NEW, nested) | CONSISTENT ✅ |
| R-06 | View + VIEW DML — DONE | T08l_ViewDML (+ T08k_MatView related) | CONSISTENT ✅ |
| R-07 | Materialized View — DONE | T08k_MatView | CONSISTENT ✅ |
| R-08 | Stored Procedure / Function — DONE | T08m_StoredProc | CONSISTENT ✅ |
| R-09 | LATERAL JOIN — DONE | T08j_Lateral | CONSISTENT ✅ |
| R-10 | CYCLE Detection (Recursive CTE) — DONE | T08e_CTE | CONSISTENT ✅ |
| R-11 | DEFERRABLE Constraints — DONE | T12_Transaction (SET CONSTRAINTS) | CONSISTENT ✅ |
| R-12 | Pool + TCP SQL Server (Full) — DONE | T106 (32 sub-tests) + T107/T108/T109 (auth/prepared/capacity) + VDbPoolTest 10/10 (historical) | CONSISTENT ✅ |
| R-13 | HASH/RANGE/LIST Partitioning + Pruning (Full) — DONE | T104_HashPartition (70 sub-tests) | CONSISTENT ✅ |
| R-14 | Parallel Query (Full) — DONE | T100_Parallel (58 sub-tests) | CONSISTENT ✅ |
| R-15 | Cost-Based Optimizer (Full) — DONE | T98_CBO (25 sub-tests) | CONSISTENT ✅ |
| R-16 | WAL Archiving + PITR — DONE | T95_WALArsiv (24 sub-tests) | CONSISTENT ✅ |
| R-17 | Streaming Replication (Full) — DONE | T95b (17) + T101_TcpReplication (21) | CONSISTENT ✅ |
| R-18 | RBAC / Role / GRANT — DONE | T93_RBAC + T94_RBAC_Persist | CONSISTENT ✅ |
| R-19 | Row Level Security — DONE | T94b_RLS + T94c_RLS_Persist | CONSISTENT ✅ |
| R-20 | ICU Collation (Full) — DONE | T94d/e + T103_IcuCollation (30 sub-tests) | CONSISTENT ✅ |
| R-21 | Extension / Plugin (Full) — DONE | T99_Extension (25 sub-tests) | CONSISTENT ✅ |
| R-22 | Online DDL CONCURRENTLY (Full) — DONE | T102_ConcurrentIndex (44 sub-tests) | CONSISTENT ✅ |
| R-23 | Cross-Platform DLL / C API — DONE | T97_CrossPlatform (16) + vdbapitest 170/170 | CONSISTENT ✅ |
| R-24 | Monitoring / SHOW STATS (Full) — DONE | T94f + T105_ShowStats (27 sub-tests) | CONSISTENT ✅ |
| R-25 | PK Lazy Index + Group Commit — DONE | bench measurements (4x COUNT, 14x UPDATE…) + no sqltest regression | CONSISTENT ✅ |

**EN result:** **all 24+1 roadmap items** are verified by their test counterparts.

---

## 3. Eski Bulguların Güncel Durumu / Status of Older Findings

**TR:**

| # | Eski bulgu (önceki rapor, sqltest 1671) | Güncel durum |
|---|------------------------------------------|--------------|
| 1 | **R-01 MVCC "KRİTİK UYARSIZLIK"** — `FSnapshotDepth` yoktu, `GetSnapshot/…` hiç çağrılmıyordu, test yoktu | **ÇÖZÜLDÜ ✅** — `BeginSnapshotRead/EndSnapshotRead` + `GetSnapshot/ScanSnapshot` kodda; T90/T91/T92 testleri eklendi ve yeşil |
| 2 | R-05 notu eski sayı içeriyordu ("1645/1646", "1 edge case hariç") | **ÇÖZÜLDÜ ✅** — `yol_haritasi.md` 2026-10-13'te sıfırdan yeniden yazıldı; bayat not yok |
| 3 | R-08 notu eski sayı içeriyordu ("F-35 … 32/32") | **ÇÖZÜLDÜ ✅** — aynı yeniden yazım temizledi |
| 4 | R-05'te `ON DELETE CASCADE` **trigger** testi yok | **AÇIK (opsiyonel)** — sqltest envanterinde trigger bazlı CASCADE testi hâlâ yok (FK düzeyindeki cascade testleri mevcut) |

**EN:**

| # | Older finding (previous report, sqltest 1671) | Current status |
|---|-----------------------------------------------|----------------|
| 1 | **R-01 MVCC "CRITICAL MISMATCH"** — `FSnapshotDepth` missing, `GetSnapshot/…` never called, no tests | **RESOLVED ✅** — `BeginSnapshotRead/EndSnapshotRead` + `GetSnapshot/ScanSnapshot` in code; T90/T91/T92 added and green |
| 2 | R-05 note contained stale numbers ("1645/1646", "1 edge case excluded") | **RESOLVED ✅** — `yol_haritasi.md` was rewritten from scratch on 2026-10-13; no stale notes remain |
| 3 | R-08 note contained a stale number ("F-35 … 32/32") | **RESOLVED ✅** — cleaned by the same rewrite |
| 4 | No `ON DELETE CASCADE` **trigger** test in R-05 | **OPEN (optional)** — still no trigger-based CASCADE test in the sqltest inventory (FK-level cascade tests exist) |

---

## 4. Özet Karar / Summary Verdict

**TR:**

| Kategori | Durum |
|----------|-------|
| sqltest çalışıyor mu? | ✅ Evet — **2251/2251**, hata yok (2026-10-15) |
| Haritada BITTI olanlar test ediliyor mu? | ✅ Evet — R-01…R-25'in **tamamı** sqltest'te karşılığa sahip |
| BITTI ama kodsuz madde? | ❌ Yok — eski R-01 MVCC bulgusu çözüldü |
| Eski/bayat notlar? | ❌ Yok — yol haritası yeniden yazımıyla temizlendi |
| Kalan opsiyonel açık | ⚠️ Tek madde: trigger bazlı `ON DELETE CASCADE` testi |
| Dayanıklılık | ✅ crashtest 8/8 — kill noktalarında veri kaybı yok |

**EN:**

| Category | Status |
|----------|--------|
| Does sqltest run? | ✅ Yes — **2251/2251**, no failures (2026-10-15) |
| Are roadmap DONE items tested? | ✅ Yes — **all** of R-01…R-25 have sqltest counterparts |
| DONE but codeless items? | ❌ None — the old R-01 MVCC finding is resolved |
| Stale notes? | ❌ None — cleaned by the roadmap rewrite |
| Remaining optional gap | ⚠️ One: a trigger-based `ON DELETE CASCADE` test |
| Durability | ✅ crashtest 8/8 — no data loss at kill points |

---

## 5. Sonraki Adımlar / Next Steps

**TR:**

1. Zorunlu iş **yok** — yol haritası 0 kalan, testler tam yeşil.
2. Opsiyonel: R-05'e `ON DELETE CASCADE` tetikleyicisi testi eklemek.
3. Yayın: `vdbapi.dll` GitHub Releases'a **v2.1** asset'i olarak yüklenecek.

**EN:**

1. **No mandatory work** — zero remaining roadmap items, all tests green.
2. Optional: add an `ON DELETE CASCADE` trigger test to R-05.
3. Release: `vdbapi.dll` will be uploaded as the **v2.1** GitHub Release asset.
