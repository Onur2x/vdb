# VDB Speed Test and Performance Report

This document contains the engine's measured performance, the measurement
method, and a same-machine comparison against SQLite. Overview:
[readme_en.md](readme_en.md)

> Every number comes from a real run in this repository. Measurements were
> taken on Windows with a 32-bit (`i386-win32`) FPC 3.2.4 build, in a single
> process, using `QueryPerformanceCounter`. The same data, the same disk
> (`C:\temp`) and the same SQL text were used for both engines.

---

## 1. Test data

1,000,000-row table:

```sql
CREATE TABLE customer (
  id       INTEGER PRIMARY KEY,
  name     TEXT,
  age      INTEGER,
  balance  FLOAT,
  note     TEXT
);
```

Data generation is deterministic and reproducible from the same seed.

---

## 2. v2.1 performance release (1M rows)

| Query / operation | Before | v2.1 | Gain |
|---|---:|---:|---|
| `SELECT COUNT(*) FROM customer` | 3,200 ms | **800 ms** | **4x** |
| `SELECT * FROM customer` | 2,859 ms | **1,579 ms** | **1.8x** |
| `SELECT SUM(id) FROM customer` | 8,766 ms | **2,265 ms** | **3.9x** |
| `WHERE id = -30792` (negative PK) | 12,400 ms | **0 ms** | bug fix |
| `WHERE id > 100` (999,900 rows) | 13,000 ms | **~5,000 ms** | **2.6x** |
| First index use (lazy build) | 9–13 s | **~4.3 s** | **2–3x** |
| `ScanAll` (raw KV scan) | 7,016 ms | **437 ms** | **16x** |
| `ScanRows` (decoded scan) | 9,703 ms | **2,625 ms** | **3.7x** |
| `WHERE id = 524288` (PK point) | 0 ms | **0 ms** | — |
| `WHERE id BETWEEN 100 AND 200` | 125 ms | **125 ms** | PK lazy index |
| 1M INSERT (BEGIN/COMMIT) | — | **55.84 s** (17,907/s) | 118.9 MB ≈ 119 B/row |

### Micro-benchmarks

| Operation | Time |
|---|---:|
| `VDbParseInt` | 78 ns/call |
| `VDbParseFloat` | 515 ns/call |
| `VDbFloatToStr` | ~450 ns (was ~800 ns) |
| STR column decoding | 109 ns/column (was ~300 ns) |

### What changed in this release

- `ScanSnapshot` rewritten: offset-ordered block reads (8 MB window).
- Raw `COUNT(*)` path: no row decoding, only structure + hash validation.
- Aggregate gating: `SUM` no longer performs redundant `MIN/MAX` or parsing.
- `SortIdxEntries` pre-parse quicksort: index build ~10 s → ~1 s.
- CBO fix: use index length instead of row count when statistics are absent.
- Negative-literal fix: `id = -1` went from 12.4 s to 0 ms.
- `DecodeRow` ASCII fast path + raw-byte hash + preallocation.
- Allocation reductions in `VDbParseInt` / `VDbParseFloat` / `VDbCmpVal` /
  `VDbFloatToStr`.

The durability contract is unchanged: `SyncWriteInterval` defaults to 0 and
the crash suite passes with zero data loss.

---

## 3. H3 skiplist index (2026-10-19)

With H3 the canonical secondary index is a skiplist. Pending changes are
applied in O(log N) inside `FlushIdxPending`; the sorted array is only a cold
read cache. Rank/span fields make indexed `COUNT(*)` over a range O(log N).

### 100,000 rows — `idxbench`

Setup: 200 × 1,000 range, 100 cycles, each cycle performing `UPDATE` plus
indexed `COUNT(*)`.

| Measurement | Result |
|---|---:|
| 100-cycle total | **39.3–41.8 ms** |
| Per cycle | **0.39–0.42 ms** |
| Previous per cycle | 24.99 ms |
| Gain | **~60–64x** |
| Indexed `COUNT(*)` (no pending) | **0.01 ms** |
| First flush | **1.3 ms** |

### 1,000,000 entries — `skipchk`

| Operation | Time |
|---|---:|
| 1M insert | **1,110.3 ms** |
| 200,000 `LowerBound` | **423.8 ms** |
| 10,000 range scans | **336.3 ms** |
| 100,000 deletes | **271.7 ms** |

`skipchk` also compares rank/span values against a 200,000-element oracle by
brute force; result: **0 errors**.

`countchk` compares an indexed table against an unindexed oracle:
**120/120**.

---

## 4. Fair comparison with SQLite

Conditions:

- Same SQL text, same data generation, same disk (`C:\temp`), single process.
- Both engines on stock defaults:
  - VDB: `SyncWriteInterval = 0` (synchronous commits)
  - SQLite: `synchronous=FULL`, `journal=DELETE`
    (official sqlite.org 3.54.0 32-bit DLL)
- Timer: `QueryPerformanceCounter`.

| Phase (1M rows) | VDB | SQLite | VDB / SQLite |
|---|---:|---:|---:|
| `INSERT` 1M (BEGIN/COMMIT) | 24.1 s | 3.12 s | 7.7x |
| `SELECT COUNT(*)` ×10 avg | 713 ms | 37 ms | 19.5x |
| `SELECT SUM(balance)` ×5 avg | 722 ms | 82 ms | 8.8x |
| PK point lookups ×50,000 | **1.42 s** | 3.04 s | **0.47x — VDB 2.1x ahead** |
| `BETWEEN` 2,000×100 rows | 3.12 s | 211 ms | 14.8x |
| `UPDATE` 100k (transaction) | 4.25 s | 270 ms | 15.8x |
| `DELETE` 100k (transaction) | 2.92 s | 196 ms | 14.9x |

Improvement over the speed campaign (zero data loss throughout):

| Phase | Campaign start | Final |
|---|---:|---:|
| INSERT | 16.1x | 7.7x |
| COUNT | 26.8x | 19.5x |
| BETWEEN | ~35x | 14.8x |
| PK point | 0.59x | **0.47x (VDB ahead)** |

The SQL suite and the 8-step crash chain stayed green at every step.

---

## 5. Correctness gates

All performance changes were made while the following gates were green:

| Gate | Result |
|---|---|
| `sqltest` | 2527 / 2527 |
| `crashtest` | 8 / 8 (zero data loss) |
| `rawchk` | 29 / 29 |
| `mrowchk` | 0 errors |
| `fuzzchk` | 3000 / 3000 |
| `sqlite_diff` | 4000 / 4000 |
| `hashchk` | 80 / 80 |
| `copychk` | 17 / 17 |
| `zonechk` | 0 errors |
| `skipchk` | 0 errors |
| `countchk` | 120 / 120 |

Only `sqltest` remains in the repository; the others were one-off verification
tools. Their results are recorded here.

---

## 6. Reproducing the measurements

Correctness with `sqltest`:

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

Expected: `SONUC: gecen=2527 kalan=0`.

The benchmark programs (`idxbench`, `skipchk`, `countchk`) were removed during
cleanup. To repeat the numbers, generate a 1M-row dataset and run the relevant
SQL through `sqltest` or your own harness.

---

## 7. Observations

- VDB is strongest at **PK point lookups** and **single-file/embedded** use.
- SQLite is still clearly ahead on bulk `INSERT`, `UPDATE` and `DELETE`; this
  is a natural consequence of the append-only KV design.
- The H3 skiplist delivered the largest win by reducing index maintenance and
  indexed `COUNT(*)` cost to O(log N).
