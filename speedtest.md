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

## 5. Single-row writes (autocommit) — 2026-10-24

Complaint: "insert, update and delete are still very slow". The single-row
(autocommit) write path was measured; two bottlenecks were found and fixed.

Conditions: Windows, FPC 3.2.4 i386-win32, `-O1`, via SQL text (`sq.Exec`),
default durability (`SyncWrite=True`, `SyncWriteInterval=0` → fsync on every
commit), 20,000 rows, single process.

| Operation (20,000 rows, one at a time) | Before | After | Gain |
|---|---:|---:|---:|
| `INSERT` autocommit | 74.0 s — 3.70 ms/row (270/s) | **8.61 s — 0.430 ms/row (2,324/s)** | **8.6x** |
| `UPDATE` (PK) autocommit | 138.9 s — 6.94 ms/row (144/s) | **7.74 s — 0.387 ms/row (2,585/s)** | **17.9x** |
| `DELETE` (PK) autocommit | 137.3 s — 6.87 ms/row (146/s) | **7.48 s — 0.374 ms/row (2,673/s)** | **18.4x** |

The bulk (single transaction) path held a separate O(n²) bottleneck, also
fixed (100,000 rows, single transaction):

| Bulk operation | Before | After | Gain |
|---|---:|---:|---:|
| `DELETE ... WHERE` (one statement) | 0.1575 ms/row (15.8 s) | **0.0134 ms/row (1.34 s)** | **11.7x** |
| PK `DELETE` (open batch) | 0.1735 ms/row (17.3 s) | **0.0296 ms/row (2.96 s)** | **5.9x** |
| `UPDATE ... WHERE` (one statement) | 0.0226 ms/row | 0.0223 ms/row | — |
| `INSERT` (open batch) | 0.0065 ms/row (154k/s) | 0.0064 ms/row (156k/s) | — |

### Root cause 1 — the whole schema was rewritten on every INSERT

`TVTableDb.BumpAutoInc` called `MarkSchema` → `SaveSchema` whenever the
counter advanced; `SaveSchema` serialized the entire table/role/RLS text, ran
the `GuardSchemaLoss` check, wrote it to the KV store and fsynced. That cost
~3.0 ms on every single-row INSERT. The counter now only advances in memory
(`FAutoIncDirty`); the schema is written once on `Close` or on the next
structural DDL. A lost counter self-heals via `ReadRow`/`MaxPkInt`.

### Root cause 2 — in-place updates on single-row writes

Reusing a dead span for a single-row UPDATE/DELETE meant three fsyncs (undo
pre-image, main file, undo commit marker) plus creating and deleting the
`.undo` file on every write (≈1.5 ms on Windows). In-place writing is now used
only for **multi-row** operations (`FInBatch and FPending.Count > 1`);
single-row writes take the append path with a single fsync. The trade-off is
file growth: dead spans are reused by later bulk writes and reclaimed by
`VACUUM`/`Compact`.

### Extra — free-span lookup was O(n²)

`TryTakeFreeSpan` scanned the list from the start and took the first fitting
span (`TList.Delete(0)` is O(n)). A 100,000-row `DELETE` produced a new dead
span per row and immediately searched, giving O(n²) overall. The list is now
kept sorted by size: lookup is a binary search (O(log n)), insertion of
equal-sized spans is O(1).

### Automatic compaction (H25) — against file growth

Single-row writes now append, so heavy autocommit `UPDATE`/`DELETE` traffic
accumulates dead regions and the file grows. The engine can reclaim them on its
own: when **enabled**, after every successful commit, if
`DeadBytes / FileSize` crosses the threshold, `Compact` runs (atomic `.tmp` +
rename, the old file stays as `.bak`). The decision is O(1); the file is
rewritten in one pass only when the threshold is actually crossed.

**It is OFF by default.** Compaction rewrites the whole file, so that one
commit takes longer (seconds on a very large database). If commit latency must
stay predictable, leave it off and call `VACUUM`/`AutoCompact` explicitly at a
suitable time.

| Setting | Default | Meaning |
|---|---:|---|
| `AutoCompactEnabled` | `False` | Set `True` to turn it on |
| `AutoCompactRatio` | `0.35` | Dead-byte ratio threshold |
| `AutoCompactMinBytes` | 4 MB | Databases below this size are never compacted |

Measurement (`sqltest` T148, 300 rows, 60 KB file): at 36% dead,
**63,505 → 23,008 bytes**; afterwards `DeadBytes=0` and row counts, PK and
secondary-index reads, `INSERT`/`UPDATE`/`DELETE`, `Verify`, and results after
reopening are all unchanged. With the feature disabled the dead bytes keep
accumulating (23,064 bytes) and nothing is compacted. Compaction is only
attempted after a commit that wrote data; the `.bak`, `.tmp` and fsync cost is
paid only when the threshold is crossed.

### Measured floor

Raw `fsync` on this machine is ≈0.29–0.32 ms. With `SyncWrite=True` the floor
for a single-row write is ≈0.35 ms/statement (~2,800/s), and that floor is
reached. Users needing more should use `SyncWriteInterval` (group commit) or
an explicit transaction; with group commit an `INSERT` costs 0.030 ms
(~33,000/s).

---

## 6. Correctness gates

All performance changes were made while the following gates were green
(2026-10-24):

| Gate | Result |
|---|---|
| `sqltest` — win32 (lazbuild, `-B`) | **3112 / 3112** (`kalan=0`) |
| `sqltest` — win64 (`-Px86_64 -Twin64 -O1`) | **3077 / 3077** (`kalan=0`) |
| `sqltest` — Linux (WSL, FPC 3.2.4) | **3077 / 3077** (`kalan=0`) |

The H11 (undo journal / in-place) tests were updated to the new contract:
dead-span reuse is verified for multi-row transactions, while single-row
writes take the append path. H25 added `sqltest` T148 (21 checks: default-off,
threshold behaviour, file shrinking, data/index integrity, disable/re-enable, and
durability after reopening).

Earlier campaigns also ran `crashtest`, `rawchk`, `mrowchk`, `fuzzchk`,
`sqlite_diff`, `hashchk`, `copychk`, `zonechk`, `skipchk` and `countchk`
green; those were one-off tools and only `sqltest` remains in the repository.

---

## 7. Reproducing the measurements

Correctness with `sqltest`:

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

Expected: `SONUC: gecen=3090 kalan=0` (win32) or `gecen=3055 kalan=0`
(win64/Linux; a few TLS/OpenSSL tests are skipped when the DLL is missing).

The benchmark programs (`idxbench`, `skipchk`, `countchk`) were removed during
cleanup. To repeat the numbers, generate a 1M-row dataset and run the relevant
SQL through `sqltest` or your own harness.

---

## 8. Observations

- VDB is strongest at **PK point lookups** and **single-file/embedded** use.
- SQLite is still clearly ahead on bulk `INSERT`, `UPDATE` and `DELETE`; this
  is a natural consequence of the append-only KV design.
- The H3 skiplist delivered the largest win by reducing index maintenance and
  indexed `COUNT(*)` cost to O(log N).

---

## 9. v3.0 page engine — v2 and v3 on the same scale (2026-10-25)

v3.0 brings a new engine: 4 KB SQLite-style pages, page-image WAL, slot
indexes, O(1) deletes. The table below comes from **one harness**, on the same
machine, back to back, as the **median of three runs**
(`tests/bench/benchcmp.pas`, `--backend=v2|v3`).

Conditions: Windows, FPC 3.2.4 i386-win32, single process; 200,000 rows ×
3 columns (`id INTEGER PRIMARY KEY`, `a INTEGER`, `s TEXT(~24 B)`), 20,000
single-row autocommit INSERTs, default durability (`SyncWrite=True`, fsync on
every commit).

| Metric | v2 | **v3** | Difference |
|---|---:|---:|---|
| Data file (`.odb`) | 19,278,424 B (96.4 B/row) | **15,527,936 B (77.6 B/row)** | **−19.5 %** |
| Open index (`.odb.idx`) | — | 3,520,080 B (17.6 B/row) | +3.5 MB |
| **Total on disk** | **19,278,555 B** | **19,048,016 B** | **−1.2 %** |
| Open | 984 ms | **32 ms** | **30.8x faster** |
| Bulk INSERT (one batch) | 4.455 µs/row | 6.640 µs/row | 1.49x slower |
| Autocommit INSERT | 0.431 ms/row | 0.557 ms/row | 1.29x slower |
| PK point lookup | 6.25 µs | **6.25 µs** | equal |
| parse-only `SELECT 1` | 3.90 µs | **3.90 µs** | equal |
| `COUNT(*)` | 31 ms | 62 ms | 2.0x slower |

**What is `.odb.idx`, and should it count?** It is a **derived cache** of the
heap index (key → page/slot) loaded at open instead of rebuilt; it is not a data
source and deleting it loses nothing (open takes 79 ms instead of 16 ms, target
150 ms). It does take disk, so it is shown on its own line and in the total.
Counting `.odb` alone the win is 19.5 %; with `.idx` it is 1.2 % — both numbers
belong in the report, the 19.5 % alone is misleading.

**The default policy is size-based automation** (`TVdbPageEngine.IdxMaxBytes`,
threshold **50 MB**): below it the `.idx` is written (fast open), above it is
not written and a previously written `.idx` is deleted (~18–23 % disk saving,
open falls back to a full scan). Set `IdxMaxBytes := 0` to remove the limit.
`backendchk` covers this with 6 checks (`idxpol)`).

Everything except bulk insert, autocommit insert and `COUNT(*)` is on par with
or better than v2. Those three regressions are **measured and accepted** costs
(root causes below).

### Why bulk INSERT costs 6.64 µs

Components measured separately (200k keys, 64 B values, 512-frame pool):

| Phase | Time |
|---|---:|
| Writing into the batch overlay (`Put`) | 0.94 µs/key |
| Applying the overlay + commit + checkpoint | 4.72 µs/key |
| — engine `Insert` share | ~1.6 µs/key |
| — WAL + checkpoint share | ~1.3 µs/key |

v2's append-only KV path appends each row once. v3 uses page-image WAL: the same
bytes go to the WAL and, at checkpoint, to the data file — **2x write volume**.
Half of the difference comes from that; the rest is in-page cell placement and
index maintenance.

Three bottlenecks found by measurement this sprint, all fixed in production
code:

1. **`Flush` ran a full checkpoint after every autocommit.** The SQL layer calls
   `Flush` after each row, so a single-row write meant WAL + flushing every
   dirty page to the data file + WAL truncation. `Flush` now only does
   `Commit(True)` (WAL + fsync); checkpoint happens on the threshold, an
   explicit call, or close. **1.168 → 0.557 ms/row.**
2. **Pending page images were kept as an array of 4 KB records grown with
   `SetLength(+1)` on every eviction.** In a 200k × 64 B write, 3,488 evictions
   cost ~265 ms in growth alone (~75 µs each). Images are now allocated
   separately, the array holds only pointers and doubles in capacity, and the
   pending lookup is a hash instead of a linear scan. Engine `Insert`:
   2.99 → 1.6 µs/key.
3. **The batch was applied in `TDictionary` order (random).** Scattered page
   writes are markedly slower than sequential ones. The batch is now applied in
   **insertion order**. Bulk INSERT **8.045 → 6.64 µs/row** (sum of the three
   improvements).

### Why `COUNT(*)` costs 62 ms

In v2, `COUNT(*)` is answered **O(1)** from a per-table row counter
(`TryGetTableRowCount`); the 31 ms figure is that counter plus validation. In
v3 keys are a table+PK hash, so there is **no per-table counter** and the query
scans. The scan runs on raw cells (no row decoding), so the cost is bytes read,
not CPU: 15.5 MB / 62 ms ≈ 250 MB/s. This is v3.1 work (a per-table live row
counter).

### Against the v3.0 acceptance targets

| Target | Target value | Measured | Status |
|---|---:|---:|---|
| File size (SQL harness, `.odb` only) | ≤ 11 MB | 15.5 MB | **missed** |
| File size (SQL harness, `.odb` + `.idx`) | ≤ 11 MB | 19.0 MB | **missed** |
| File size (page harness, 32 B values) | ≤ 11 MB | **9.76 MB** (+3.20 MB `.idx`) | met (`.odb` only) |
| Open | ≤ 150 ms | **32 ms** | met (4.7x headroom) |
| PK point | ≤ 7 µs | **6.25 µs** | met |
| Bulk INSERT | ≤ 5 µs | 6.64 µs | **missed** (v2: 4.46) |
| Autocommit INSERT | ≤ 0.55 ms | 0.557 ms | **borderline** (v2: 0.431) |
| `COUNT(*)` | ≤ 16 ms | 62 ms | **missed** |

The file-size target mixed two harnesses: `benchv3` (page engine, 32 B values,
9,756,672 B = 48.8 B/row) meets it; `benchcmp` (SQL layer, 3 columns, ~24 B
text) does not. Both are listed separately. Note also that v3 writes a
derived `.odb.idx` next to the data file (3.5 MB for 200k rows); it can be
deleted at any time (open then does a full scan, 79 ms, still under target),
but it does occupy disk, so both figures are given.

**Honest summary:** v3.0 wins on file size and especially open time; PK and
parse costs are identical to v2. On the other hand bulk writes are ~1.5x,
`COUNT(*)` 2x and single-row writes ~1.3x slower. v3.1 targets exactly those
three: a logical (smaller) WAL frame, a per-table row counter, and batched file
extension (measured: 45–50 µs per single-page extension).

### Page-engine harness (`benchv3`, 200k rows × 32 B values)

A separate harness from `benchcmp`; do not mix the numbers:

| Metric | Measured |
|---|---:|
| File | 9,756,672 B (48.8 B/row) |
| `.idx` | 3,200,064 B (16.0 B/row) |
| Write (commit + checkpoint included) | 1.88 µs/row |
| Open (with `.idx`) | 16 ms |
| Open (full scan) | 79 ms |
| PK read | 0.47 µs/row |
