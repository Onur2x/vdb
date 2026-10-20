# VDB — Relational Database Engine

VDB is a relational database engine written in pure Free Pascal. It needs no
external DLL and stores a database in a single `.odb` file. It is designed for
desktop and embedded applications as an alternative to SQLite.

> This file lives in `dokuman/` and is intentionally not tracked by Git.
> Turkish version: [readme_tr.md](readme_tr.md)

---

## Highlights

- Single-file storage (`.odb`); no server installation required.
- Rich SQL: JOINs, subqueries, CTEs, window functions, `UPSERT`, `RETURNING`,
  triggers, views, stored procedures.
- MVCC / snapshot isolation, `SAVEPOINT`, `DEFERRABLE` constraints.
- WAL, automatic WAL, checkpointing, PITR, streaming replication.
- AES-256 record-level encryption, `.key` file and password rotation.
- JSONB, XML/XPath, Spatial and Range types.
- HASH / RANGE / LIST partitioning with partition pruning.
- Parallel query execution and a cost-based optimizer (`ANALYZE`, `EXPLAIN`).
- H3 skiplist secondary index; indexed `COUNT(*)` in O(log N).
- TCP SQL server/client and a connection pool.
- RBAC, row level security, ICU-compatible collations.
- C/Delphi DLL API with 57 exports (`vdbapi`).
- `SHOW STATS`, `/metrics` and OpenTelemetry span recording.

---

## Architecture

```
SQL text → VDbParser → VDbAst → VDbExecutor → VDbTable → VDbCore → .odb
```

| Unit | Role |
|---|---|
| `VDbCore.pas` | Append-only key/value engine, locking, file I/O |
| `VDbTable.pas` | Schema, indexes, FKs, constraints, partitioning |
| `VDbAst.pas` | Type-safe AST model |
| `VDbParser.pas` | Tokenizer + recursive-descent parser |
| `VDbExecutor.pas` | Filtering, JOINs, grouping, sorting, window functions |
| `VDbSql.pas` | Public facade: `TVSql.Exec` |
| `VDbWal.pas` | Write-ahead log, replay, checkpoint |
| `VDbSkipList.pas` | H3 skiplist index (rank/span) |
| `VDbCrypt.pas` | AES-256, GCM, key management |
| `VDbNet.pas` | VDBS TCP protocol |
| `VDbSqlServer.pas` | TCP SQL server |
| `VDbClientNet.pas` | TCP SQL client |
| `VDbJson.pas` | JSON import/export |
| `VDbDataSet.pas` | Lazarus/Delphi `TDataSet` bridge |

---

## Quick start

### Build

```bash
# Windows (Lazarus 4.6+, FPC 3.2.4)
lazbuild -B sqltest.lpi
lazbuild -B vdbapi.lpi

# Linux/macOS
./build_lib.sh
```

### First query (Pascal)

```pascal
uses VDbSql;

var
  DB: TVSql;
  R: TSqlResult;
begin
  DB := TVSql.Create('database.odb');
  try
    DB.Exec('CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT, price FLOAT)', R);
    DB.Exec('INSERT INTO product (name, price) VALUES (''Laptop'', 15000)', R);
    DB.Exec('SELECT name, price FROM product WHERE price > 1000', R);
    // R.Cols, R.Rows, R.Data
  finally
    DB.Free;
  end;
end;
```

API details and SQL usage: [usage.md](usage.md)

---

## Test status

Last verified state (2026-10-19):

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

Only the `sqltest` suite remains in the repository; the other gates were
one-off verification tools removed during cleanup. Their results are recorded
above.

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

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

H3 skiplist (100,000 rows): 100 × (`UPDATE` + indexed `COUNT(*)`) takes
**0.39–0.42 ms per cycle**, down from 24.99 ms — about **60–64x** faster.

---

## Project layout

```
VDb*.pas            Engine units
sqltest.lpi/lpr     SQL test suite
vdbapi.*            DLL / C API project
dcpcrypt/           Encryption dependency
dokuman/            These documents (not tracked)
```

---

## Requirements

- Lazarus 4.6+ / Free Pascal 3.2.4
- DCPcrypt (bundled in `dcpcrypt/`)
- Windows: `lazbuild`; Linux/macOS: `fpc` + `lazbuild`

---

## License

Open source. See the `LICENSE` file for details.
