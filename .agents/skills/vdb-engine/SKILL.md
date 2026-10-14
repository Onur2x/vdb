---
name: vdb-engine
description: VDB (VeriTabani) embedded database engine - Free Pascal/Lazarus. Use when working on the VDB codebase: reading/writing SQL, parser, executor, storage engine, encryption, CDC, Time Travel, DLL API, TDataSet components, or test suite.
---

# VDB Engine Skill

**Project:** VDB Motor v2 — Saf Free Pascal, tek dosyalı (`.odb`), harici DLL'siz ilişkisel veritabanı motoru.

**Location:** `D:/veritabani` (proje kökü)

**Current Status (2026-10-11):** ✅ **Production-ready core** — 1652/1652 tests passing

---

## Quick Context for Any AI

### What Works (✅ Done)
- **Full SQL:** SELECT (JOIN, CTE, window fn, UNION/EXCEPT/INTERSECT), INSERT/UPDATE/DELETE, UPSERT (`ON CONFLICT`), RETURNING
- **DDL:** CREATE/DROP/ALTER TABLE, INDEX, FUNCTION/PROCEDURE (F-35), TRIGGER (F-36 Phase A/B/C), VIEW (R-06), MATERIALIZED VIEW (R-07)
- **Transaction:** BEGIN/COMMIT/ROLLBACK, SAVEPOINT (nested), DDL in transaction
- **Storage:** Append-only KV (Bitcask), CRC32, batch commit, WAL (opt-in), Compact/Backup/Verify
- **Encryption:** AES-256-CTR + HMAC-SHA256 per-record, `.key` file (PBKDF2), `ALTER DATABASE KEY`
- **CDC/Time Travel:** `TVDbCdc` (poll + callback), `TVDbTimeTravel` (`AS OF SEQUENCE` in SQL)
- **API:** `TVSql.Exec`, `TVDbPool`, `TVDbQuery` (TDataSet), `vdbapi.dll` (C ABI, 54 exports)
- **Turkish:** `UPPER/LOWER/LENGTH` (İ/ı/Ğ/ğ/Ş/ş/Ö/ö/Ü/ü/Ç/ç), `COLLATE TR`

### What's Missing (🟠 Roadmap)
| Priority | Feature | Status |
|----------|---------|--------|
| R-09 | LATERAL JOIN | 🟠 High |
| R-10 | Recursive CTE + CYCLE | 🟡 Medium |
| R-11 | DEFERRABLE Constraints | 🟡 Medium |
| R-12 | Multi-process pool (TCP/named pipe) | 🔴 Very High |
| R-13 | Table Partitioning | 🔴 Very High |
| R-14 | Parallel Query Execution | 🔴 Very High |
| R-15 | Cost-Based Optimizer (ANALYZE) | 🔴 Very High |
| R-16 | Incremental Backup / WAL Archiving / PITR | 🟠 High |
| R-17 | Streaming Replication | 🔴 Very High |
| R-18 | RBAC / GRANT / SET ROLE | 🟠 High |
| R-19 | Row Level Security (RLS) | 🟠 High |
| R-20 | ICU Collation | 🟡 Medium |
| R-21 | Extension/Plugin Mechanism | 🔴 Very High |
| R-22 | Online DDL (CONCURRENTLY) | 🔴 Very High |
| R-23 | Cross-platform DLL (.so/.dylib) | 🟡 Medium |
| R-24 | Monitoring / pg_stat_statements | 🟡 Medium |

---

## Essential Commands

```bash
# Build & Test
lazbuild sqltest.lpi          # Main test suite → sqltest.exe (1652 tests)
./sqltest.exe                 # Run tests
lazbuild cdc_test.lpi         # CDC/Time Travel test
lazbuild vdbcomponents.lpk    # TDataSet component package
lazbuild vdbgui.lpi           # GUI admin tool
lazbuild vdbapi.lpi           # DLL (vdbapi.dll)

# Key test files
sqltest.exe                   # 1652 assertions
vdbapitest.lpr                # 170 DLL ABI tests
vdbclienttest.lpr             # 101 TDataSet tests
vdbcrypttest.lpr              # 60 crypto tests
cdc_test.exe                  # 38 CDC/TimeTravel tests
```

---

## Architecture (Read Order)

```
SQL → VDbParser.pas → VDbAst.pas → VDbExecutor.pas → VDbTable.pas → VDbCore.pas → .odb
```

| Unit | Role | Key Types |
|------|------|-----------|
| `VDbCore.pas` | Low-level append-only KV + `TCriticalSection` | `TVDb`, `TVDbRec` |
| `VDbTable.pas` | Schema, indexes, FK, constraints, table locks | `TVTableDb`, `TTableDef` |
| `VDbAst.pas` | Type-safe AST nodes | `TSelectStmt`, `TExpr`, `TJoin` |
| `VDbParser.pas` | Tokenizer + recursive-descent parser | `TParser`, `TToken` |
| `VDbExecutor.pas` | AST walker (filter, join, group, sort, window) | `TVSqlExecutor` |
| `VDbSql.pas` | Public API `TVSql.Exec` | `TVSql`, `TVDbResult` |
| `VDbCrypt.pas` | Record-level encryption | `TVDbCrypt` |
| `VDbCdc.pas` | Change Data Capture from WAL | `TVDbCdc`, `TCDCEvent` |
| `VDbTimeTravel.pas` | Historical reads from WAL | `TVTimeTravel` |
| `VDbPool.pas` | Connection pool (N TVSql per engine) | `TVDbPool` |
| `VDbDataSet.pas` | TDataSet descendant `TVDbQuery` | `TVDbQuery` |

---

## Critical Rules (Read Before Editing)

1. **Open Order:** `Kv.Create → Kv.Open(dir) → Tb.Create(Kv) → Tb.Open(dir) → Sq.Create(Tb)`
2. **Tb.Open is MANDATORY** — loads schema from `.odb`; skipping causes "table not found" on restart
3. **No `TVDb.Open`** — only `Create + Open(path)`
4. **WAL is opt-in** — `WALEnabled` property; default OFF for backward compat
5. **Encryption:** `.wal` writes PLAINTEXT (emergency recovery); threat model in `SIFRELEME_PLANI.md`
6. **Concurrency:** `TVSql.Exec` holds table lock; use `TVDbPool` for multi-thread
7. **All errors:** `EVDbException(ErrorCode)` — codes in `VDbErr.pas`
8. **Mutation tests exist** — Every F1 fix has a mutation proof (revert fix → test fails)

---

## Key Files to Read First

- `README.md` — Overview, architecture, SQL scope, error codes, concurrency, pool, Turkish support
- `SQL.md` — Complete SQL reference (0b: `AS OF SEQUENCE`, F-35 functions/procedures)
- `DENETIM_VE_YOL_HARITASI.md` — **Audit log + roadmap** — F1-F3 fixes with mutation proofs
- `yol_haritasi.md` — Visual roadmap with priorities (R-01 to R-24)
- `SIFRELEME_PLANI.md` — Encryption design, threat model, key rotation
- `DLL_KULLANIM.md` — C API, CDC/TimeTravel poll exports
- `09-KARSILASTIRMA_VE_YOL_HARITASI.md` — Comparison with SQLite/other engines

---

## Common Tasks

### Run Full Test Suite
```bash
lazbuild sqltest.lpi && ./sqltest.exe
# Expect: "SONUC: gecen=1652 kalan=0"
```

### Add a New SQL Feature
1. **Parser:** `VDbParser.pas` — add token, parse rule, AST node in `VDbAst.pas`
2. **Executor:** `VDbExecutor.pas` — implement execution logic
3. **Tests:** Add to `sqltest.lpr` (search for `Testler.Add`)
4. **Mutation test:** Revert change → verify test fails

### Debug Encryption
```pascal
// Check if encrypted records exist
Kv.HasEncryptedRecords
// Get key fingerprint (first 8 hex)
Kv.EncryptionKeyFingerprint
// Rekey
Kv.RekeyWithPassword('newpass')
```

### CDC/Time Travel from DLL
```c
// Start CDC (poll mode - no callback)
VdbCdcStart(handle, 0, 100000);  // maxPending=100k
// Poll
int count = VdbCdcPollSize(handle);
VdbCdcPoll(handle, buffer, bufSize, &written);
// Time Travel
VdbValueAt(handle, "tablo", "pk", seq, buf, &len);
VdbHistoryCount(handle);
```

---

## Project-Specific Conventions

- **No external deps** — Pure Pascal, only `LazUtils` for file locking
- **Private fixes** — All F1-F3 fixes in `private` members; public API unchanged
- **Turkish identifiers** — Code comments/messages in Turkish; English in docs
- **Append-only** — Never overwrite records; `Compact` rewrites to `.bak`
- **CRC32 per record** — Corruption detected on read; `Verify` reports
- **Batch commit** — `BATCHEND` marker + `fsync` = atomic durability

---

## When You're Stuck

1. Check `DENETIM_VE_YOL_HARITASI.md` — most bugs already documented with fix location
2. Run `sqltest.exe` — see which test group fails
3. Look for `F1-` / `F2-` / `F3-` prefixes in code comments — mutation-tested fixes
4. `VDbErr.pas` — error codes map to exact failure reasons
5. `VDbText.pas` — Turkish collation/upper/lower edge cases

---

## Skill Commands

```bash
/skill:vdb-engine status          # Show current test status
/skill:vdb-engine next            # Show next roadmap item to work on
/skill:vdb-engine test <group>    # Run specific test group
/skill:vdb-engine explain <file>  # Explain a Pascal unit's role
```

Use `/skill:vdb-engine` with arguments to invoke specific workflows.