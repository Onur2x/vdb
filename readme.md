# VDB — Relational Database Engine

VDB is a relational database engine written in pure Free Pascal. It needs no
external DLL, and all data lives in a single `.odb` file. A database that is in
use also keeps side files next to it (WAL, open cache, change log) — see
[ON_DISK_LAYOUT.md](docs/engineering/ON_DISK_LAYOUT.md). It is designed for
desktop and embedded applications as an alternative to SQLite.

> Turkish version: [readme_tr.md](readme_tr.md)

---

## Highlights

**Engine (v3 page engine, the default):**

- One data file (`.odb`); no server installation required. Side files are
  runtime state (WAL, `.idx` cache, change log) and are regenerated if missing.
- 4 KB pages, slotted heap, per-page CRC32; WAL replay recovers after a
  crash (verified by a kill -9 gate).
- Only dirty pages go to the WAL per commit; startup uses `.odb.idx` for a
  fast load and falls back to a full scan when it is damaged.
- Page-level AES-256-GCM file encryption; opening without the password is
  refused.
- `VERIFY`, `BACKUP TO`, `VACUUM` (atomic), `ANALYZE`, `SHOW STATS`.
- Rich SQL: JOINs, subqueries, CTEs, window functions, `UPSERT`, `RETURNING`,
  triggers, views, stored procedures.
- JSONB, XML/XPath, Spatial and Range types; HASH/RANGE/LIST partitioning.
- Parallel query execution, cost-based optimizer; H3 skiplist secondary index.
- RBAC, row level security; C/Delphi DLL API with 57 exports (`vdbapi`).

**Not in the v3 engine yet** (each raises an explicit `ecUnsupported` error
instead of returning silently wrong results): the v3 engine behind the TCP
server (`REPLICATION ... TCP`; file-mode log shipping works) and
`ARCHIVE WAL RESET` (the v3 change log is persistent and cannot be turned
off — PITR capability is preserved).

**Implemented but not covered by the current gates:** `SAVEPOINT` and partial
rollback, `AS OF`/PITR, file-mode replication, zone maps/pruning and
`ALTER DATABASE KEY`. They work on v3, but the old per-feature gates
(`v3sqlchk`, `pitrchk`, `replchk`, `prochk`, `soakchk`) were removed together
with the old `tests/gates` tree and nothing in [Test status](#test-status)
re-tests them. Treat that list as "needs a gate before relying on it".
The v2 engine (MVCC) stays in the tree as a **read-only/migration** path.

Writing a new application? See [UYGULAMA_GELISTIRME.md](UYGULAMA_GELISTIRME.md)
(Turkish).

---

## Architecture

```
SQL text → VDbParser → VDbAst → VDbExecutor → VDbTable → IVDbBackend → .odb
                                                            ├─ VDbBackendV3 → VDbPageEngine (v3, default)
                                                            └─ VDbBackendV2 → VDbCore (v2, read-only/migration)
```

| Unit | Role |
|---|---|
| `VDbFactory.pas` | **Application entry point**: `VdbOpen` / `VdbOpenOrCreate` / `VdbOpenWithPassword` |
| `VDbBackendApi.pas` | `IVdbBackend` contract (the SQL layer never sees the concrete engine) |
| `VDbPageEngine.pas` | v3 page engine (4 KB pages, WAL, recovery, `.idx` cache) |
| `VDbPageStore.pas` | Page store, file growth, byte-range locking |
| `VDbBackendV3.pas` | v3 implementation of `IVdbBackend` |
| `VDbBackendV2.pas` | v2 adapter for `IVdbBackend` (migration/legacy) |
| `VDbCore.pas` | v2 append-only key/value engine — **legacy, read-only** |
| `VDbTable.pas` | Schema, indexes, FKs, constraints, partitioning |
| `VDbAst.pas` | Type-safe AST model |
| `VDbParser.pas` | Tokenizer + recursive-descent parser |
| `VDbExecutor.pas` | Filtering, JOINs, grouping, sorting, window functions |
| `VDbSql.pas` | Public facade: `TVSql.Exec` |
| `VDbMigrate.pas` | v2 → v3 copy + byte-for-byte verification |
| `VDbWal.pas` | v2 write-ahead log (legacy) |
| `VDbSkipList.pas` | H3 skiplist index (rank/span) |
| `VDbCrypt.pas` | AES-256, GCM, key management |
| `VDbCryptoCore.pas` / `VDbKdf.pas` | Pure-Pascal crypto core and KDFs (no external DLL) |
| `VDbNet.pas` | VDBS TCP protocol |
| `VDbSqlServer.pas` | TCP SQL server |
| `VDbClientNet.pas` | TCP SQL client |
| `VDbJson.pas` | JSON import/export |
| `VDbDataSet.pas` | Lazarus/Delphi `TDataSet` bridge |

### On disk

All data lives in `<name>.odb`; opening that file alone works, and the engine
recreates any missing side file. While a database is in use, the engine also
keeps `<name>.odb.wal` (crash recovery), `<name>.odb.idx` (open-speed cache),
`<name>.odb.gen` and `<name>.odb.log/` (change log used for PITR). Copy the
whole set, or use `BACKUP TO` for a portable single file. Measured sizes,
reasoning and the gate that verifies it:
[ON_DISK_LAYOUT.md](docs/engineering/ON_DISK_LAYOUT.md).

---

## Quick start

### Build

```bash
# Windows (Lazarus 4.6+, FPC 3.2.4) - C API library
lazbuild -B vdbapi.lpi
# other projects: vdbcli.lpi, vdbmig.lpi, vdbserver.lpi

# Linux/macOS
./build_lib.sh
```

### First query (Pascal)

New code does not depend on the concrete engine type; the entry point is
`VDbFactory`. `VdbOpenOrCreate` creates the file as **v3** when it is missing
and opens it otherwise. An existing **v2** file is refused by default
(migration: `vdbmig`, see [GOC_V2_V3.md](GOC_V2_V3.md)).

```pascal
uses VDbBackendApi, VDbFactory, VDbTable, VDbSql;

var
  Be: IVdbBackend;
  Tb: TVTableDb;
  DB: TVSql;
  R: TSqlResult;
begin
  VdbOpenOrCreate('veritabani.odb', Be);   // out parameter (see note)
  Tb := TVTableDb.CreateBackend(Be);
  DB := TVSql.Create(Tb);
  try
    Tb.Open('.');
    DB.Exec('CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT, price FLOAT)', R);
    DB.Exec('INSERT INTO product (name, price) VALUES (''Laptop'', 15000)', R);
    DB.Exec('SELECT name, price FROM product WHERE price > 1000', R);
    // R.Cols, R.Rows, R.Data
  finally
    DB.Free;
    Tb.Free;
    Be := nil;                             // closes the engine (releases the file lock)
  end;
end;
```

> **Why an `out` parameter?** In FPC 3.2.4 a function **returning** an
> `IVdbBackend` leaves an extra reference on the result, so `Be := nil` does
> not close the engine and the same process cannot reopen the file ("file in
> use"). The `out` parameter form releases the reference exactly. Details are
> in the `VDbFactory.pas` header.

Encrypted file: `VdbOpenWithPassword(Path, Password, Be)`. Opening without the
password, or with a wrong one, is refused.

API details and SQL usage: [usage.md](usage.md)

---

## Test status

Last verified state (2026-11-14, Linux x86_64 and Windows i386, `tests/run_gates.sh`):

| Gate | Result |
|---|---|
| `sql_stubs` | 25 PASS / 0 FAIL |
| `sql_matrix` | 61 / 0 |
| `sql_fuzz` | 5 / 0 |
| `sql_differential` | 33 / 0 (live PostgreSQL comparison not run: `pg=not-run`) |
| `crypto_core` / `crypto_base64` / `crypto_kat` / `selftest_builtin` | PASS |
| `fixtures_builtin` | PASS |
| `wal_crash` / `kv_wal` | PASS |
| `backup_restore` | 25 / 0 |
| `page_integrity` | 14 / 0 |
| `btree_integrity` | 152 / 0 |
| `perf_baseline` | 16 / 0 |
| `single_file` | 22 / 0 |
| `server_harden` | 24 / 0 |
| `auth_throttle` | 16 / 0 |
| `tls_client` | 6 / 0 (Linux; skipped on Windows without OpenSSL DLL) |

That is **19 gates** on Linux (plus two OpenSSL opt-in gates skipped when
`VDB_CRYPTO_DLL` is unset) and **18 gates** on Windows (`tls_client` skipped).
Gate documents: [docs/engineering/](docs/engineering/).

```bash
# Linux / macOS / Git Bash: build and run every gate
tests/run_gates.sh /tmp/vdbgates
```

`tests/run_gates.sh` runs and builds every gate itself.
`tests/gates/*` and `tests/sql/sqltest` were removed with the old tree;
the SQL behaviour gate is now `sql_stubs` + `sql_matrix`.

---

## Performance

Full methodology, measurements and the SQLite comparison:
[speedtest.md](speedtest.md)

Highlights (1,000,000 rows):

| Operation | Time |
|---|---|
| `COUNT(*)` | 800 ms |
| `SELECT *` | 1,579 ms |
| `SUM(id)` | 2,265 ms |
| PK point lookup | 0 ms |
| `ScanAll` | 437 ms |
| 1M INSERT (single transaction) | 55.84 s (~17,907/s) |

Single-row (autocommit) writes, 20,000 rows, default `SyncWrite=True`:

| Operation | Before | After |
|---|---:|---:|
| `INSERT` | 3.70 ms/row | **0.430 ms/row (2,324/s)** |
| `UPDATE` (PK) | 6.94 ms/row | **0.387 ms/row (2,585/s)** |
| `DELETE` (PK) | 6.87 ms/row | **0.374 ms/row (2,673/s)** |

Details and root causes: [speedtest.md](speedtest.md#5-single-row-writes-autocommit--2026-10-24).
Because single-row writes now append, dead regions accumulate; the engine can
reclaim them with optional **automatic compaction** (`AutoCompactEnabled`,
**off by default**; `AutoCompactRatio=0.35`, `AutoCompactMinBytes=4 MB`;
when enabled, attempted at commit time only if the threshold is crossed).

H3 skiplist (100,000 rows): 100 × (`UPDATE` + indexed `COUNT(*)`) takes
**0.39–0.42 ms per cycle**, down from 24.99 ms — about **60–64x** faster.

### v3.0/v3.1 page engine (200,000 rows, same harness, median)

`benchcmp --backend=v2|v3`, 200k rows × 3 columns, same machine, back to back:

| Metric | v2 | **v3.0** | **v3.1** |
|---|---:|---:|---:|
| Data file (`.odb`) | 19.3 MB (96.4 B/row) | **15.5 MB (77.6 B/row)** | **15.5 MB (77.6 B/row)** |
| `+.odb.idx` (derived open cache) | — | +3.5 MB | +3.5 MB |
| **Total on disk** | **19.3 MB** | **19.0 MB** | **19.0 MB** |
| Open | 984 ms | **32 ms** | **27.8 ms** |
| PK point lookup | 6.25 µs | 6.25 µs | **5.13 µs** |
| Bulk INSERT | 4.46 µs/row | 6.64 µs/row | **5.79 µs/row** |
| Autocommit INSERT | 0.431 ms/row | 0.557 ms/row | **0.449 ms/row** |
| `COUNT(*)` | 31 ms | 62 ms | **0.1 ms** |

v3.0 opens the database **~31x** faster and shrinks the data file by **19.5 %**;
together with the `.odb.idx` it writes next to it (deletable, derived cache) the
total on disk shrinks by only **1.2 %**. The `.idx` is **always written** (v3.1
removed the v3.0 "skip above 50 MB" threshold: it is a derived, deletable cache,
so the size limit bought nothing while forcing a full scan on large databases
at open). PK and parse costs match v2.

v3.1 closed v3.0's three regressions: `COUNT(*)` **62 → 0.1 ms** (live per-table
counter), autocommit **0.557 → 0.449 ms** (only the pages changed by the
transaction go to the WAL; measured 63,373 → 8,252 B per commit), bulk INSERT
**6.64 → 5.79 µs** (256 KB file-growth chunks; page-engine writes 1.88 →
1.32 µs). What is left on autocommit is the durability floor: a single fsync
measures **0.330 ms**. File size did not change. Measurements and root causes:
[speedtest.md](speedtest.md#9-v30-page-engine--v2-and-v3-on-the-same-scale-2026-10-25).

### SQLite comparison (200,000 rows, median of 3, 2026-11-07)

`tests/bench/sqlitecmp.lpr` runs VDB v3 and SQLite 3.54.0 in the same process,
same data, same SQL, same disk. SQLite uses `journal_mode=DELETE` and
`synchronous=FULL`; VDB uses its defaults.

| Workload | VDB | SQLite | VDB/SQLite |
|---|---:|---:|---:|
| PK point / range SELECT | 22.2 / 30.5 us | 49.5 / 52.3 us | **0.45x / 0.58x (faster)** |
| `COUNT(*)` | 0.05 ms | 6.23 ms | **0.002x (faster)** |
| Autocommit PK UPDATE / DELETE | 0.52 / 0.43 ms | 1.81 / 1.80 ms | **0.29x / 0.24x (faster)** |
| Bulk INSERT | 10.78 us/row | 0.83 us/row | 13.0x slower |
| `SUM/AVG` / `GROUP BY` / `ORDER BY ... LIMIT` | 59.5 / 118.9 / 461.7 ms | 13.9 / 51.8 / 56.1 ms | 4.3x / 2.3x / 8.2x slower |
| File size (200k rows) | 17.7 MB | 10.3 MB | 1.72x larger |

VDB is ahead in 5 of 13 timed stages and behind in 8. Full method, per-stage
spread and root-cause discussion:
[speedtest.md section 10](speedtest.md#10-sqlite-comparison-after-p-144p-148-2026-11-07).

---

## Project layout

```
VDb*.pas            Engine units
tests/              Persistent gates (tests/run_gates.sh)
vdbapi.*            DLL / C API project
vdbcli.*            CLI
vdbserver.*         TCP server
vdbmig.*            v2 -> v3 migration tool
examples/           Sample projects
yonetim/            GUI admin
docs/               Architecture, engineering, security and migration notes
```

---

## Requirements

- Lazarus 4.6+ / Free Pascal 3.2.4
- No third-party crypto dependency: AES-256, SHA-256, HMAC, PBKDF2 and
  Argon2id are implemented in pure Object Pascal inside the repository
  (`VDbCryptoCore.pas`, `VDbKdf.pas`). No external DLL is required.
- Windows: `lazbuild`; Linux/macOS: `fpc` + `lazbuild`

---

## Security

- [SECURITY.md](SECURITY.md) — how to report a vulnerability (GitHub
  Security Advisories) and which risks are already accepted.
- [docs/security/THREAT_MODEL.md](docs/security/THREAT_MODEL.md) — trust
  boundaries, STRIDE table, and a risk register (`R-01`…) with the code
  evidence for each item. Open items include RAM DoS in the VDBS protocol,
  no TLS or login throttling in VDBS, and no query cost limits.
- [docs/security/SBOM.md](docs/security/SBOM.md) +
  [docs/security/vdb.cdx.json](docs/security/vdb.cdx.json) — component
  inventory (CycloneDX). No third-party package graph: the only optional
  surfaces are OpenSSL (opt-in crypto provider / TLS) and user-supplied
  plugins.
- [CHANGELOG.md](CHANGELOG.md) — what changed in the v3 hardening series.

This project does not claim to be "production ready" or security-audited.
The builtin crypto paths are pure Pascal: they have not been independently
reviewed and are not as hardened against cache-timing side channels as
OpenSSL (accepted risk R-07, `docs/architecture/CRYPTO_ADR.md` EK-B).

---

## License

Open source. See the `LICENSE` file for details.
Third-party notices: [NOTICE](NOTICE).
