# VDB Engine - File Reference Map

Quick lookup: which file does what, key types, and where to look for bugs/features.

---

## Core Engine (Storage)

| File | Purpose | Key Types/Functions |
|------|---------|---------------------|
| `VDbCore.pas` | Append-only KV engine, recovery, WAL, encryption hook | `TVDb`, `TVDbRec`, `Put`, `Get`, `DeleteKey`, `CommitBatch`, `Recover`, `Verify`, `Compact` |
| `VDbSync.pas` | `fsync`, file locking, directory flush | `VDbFlushFile`, `VDbFlushDir`, `LockFile`, `UnlockFile` |
| `VDbCrc32.pas` | CRC32 (IEEE 802.3) | `Crc32`, `Crc32Buf` |
| `VDbWal.pas` | **STUB ONLY** - Real WAL is in `VDbCore` | `WriteAheadWAL`, `ReplayWAL` (do not use directly) |
| `VDbErr.pas` | Error codes + exception | `TVDbErrorCode`, `EVDbException`, `VDbErrorName` |

---

## Table Layer (Schema, Index, FK, Constraints)

| File | Purpose | Key Types/Functions |
|------|---------|---------------------|
| `VDbTable.pas` | Schema, indexes, FK, CHECK, triggers, table locks | `TVTableDb`, `TTableDef`, `TColumnDef`, `TIndexDef`, `TForeignKeyDef`, `TTriggerDef`, `Insert`, `UpdateWhere`, `DeleteWhere`, `FindRow`, `ScanRows`, `CreateTable`, `AlterTable`, `Lock/Unlock` |
| `VDbTypes.pas` | Shared type definitions | `TValue`, `TFieldType`, `TVDbResult`, `TVDbRow` |

---

## SQL Layer (Parser → AST → Executor)

| File | Purpose | Key Types/Functions |
|------|---------|---------------------|
| `VDbAst.pas` | Type-safe AST node definitions | `TSelectStmt`, `TInsertStmt`, `TUpdateStmt`, `TDeleteStmt`, `TCreateTableStmt`, `TExpr`, `TJoin`, `TWindowDef`, `TCTE`, `TFuncProcDef` |
| `VDbParser.pas` | Tokenizer + recursive-descent parser | `TParser`, `TToken`, `ParseStatement`, `ParseSelect`, `ParseExpr`, `SplitStatements` |
| `VDbExecutor.pas` | AST walker: filter, join, group, sort, window, set ops | `TVSqlExecutor`, `ExecSelect`, `ExecInsert`, `ExecUpdate`, `ExecDelete`, `ExecJoin`, `ExecGroupBy`, `ExecWindow`, `BuildAsOfRows` |
| `VDbSql.pas` | Public API: `TVSql.Exec`, script splitting, auto-tx, DB management | `TVSql`, `Exec`, `ExecAll`, `BeginBatch`, `CommitBatch`, `AbortBatch` |

---

## Advanced Features

| File | Purpose | Key Types/Functions |
|------|---------|---------------------|
| `VDbCrypt.pas` | Record-level encryption (AES-256-CTR + HMAC-SHA256) | `TVDbCrypt`, `CreateKeyFile`, `OpenKeyFile`, `SetEncryptionKey`, `RekeyWithPassword`, `HasEncryptedRecords` |
| `VDbCdc.pas` | Change Data Capture from WAL | `TVDbCdc`, `TCDCEvent`, `Start`, `Stop`, `OnChange` (callback), `TryPeek`, `TryDequeue` (poll) |
| `VDbTimeTravel.pas` | Historical reads from WAL | `TVTimeTravel`, `GetValueAt`, `GetRowAt`, `HistoryCount`, `ParseSnapshotSpec` |
| `VDbPool.pas` | Connection pool (N TVSql per engine) | `TVDbPool`, `Acquire`, `Release`, `Exec` |
| `VDbJson.pas` | EXPORT/IMPORT JSON | `ExportTableToJson`, `ImportTableFromJson` |
| `VDbDataSet.pas` | TDataSet descendant for DB-aware controls | `TVDbQuery`, `Open`, `ExecSQL`, `Edit`, `Post`, `Delete`, `Insert` |
| `VDbRange.pas` | Range query support | `TVDbRange` |
| `VDbSpatial.pas` | Spatial index (R-tree skeleton) | `TVDbSpatial` |
| `VDbText.pas` | Turkish text: Upper/Lower/Length, COLLATE TR | `TrUpper`, `TrLower`, `TrLength`, `TrCompare`, `TrWeight` |
| `VDbXml.pas` | XML export/import (legacy) | `ExportTableToXml`, `ImportTableFromXml` |

---

## API / External

| File | Purpose | Key Types/Functions |
|------|---------|---------------------|
| `vdbapi_core.pas` | DLL internal core | `VdbOpen`, `VdbClose`, `VdbExec`, `VdbPrepare`, `VdbStep`, `VdbColumn*` |
| `vdbapi.h` | C header for DLL | 54 exported functions |
| `vdbapi.lpr` / `vdbapi.pas` | DLL entry points | `VdbOpen`, `VdbExec`, `VdbCdcStart`, `VdbCdcPoll`, `VdbValueAt`, `VdbHistoryCount` |
| `VDbClient.pas` | Delphi/C++Builder client wrapper | `TVDbClient` |

---

## Test Files

| File | Purpose |
|------|---------|
| `sqltest.lpr` | Main test suite (1652 assertions) |
| `vdbapitest.lpr` | DLL C ABI tests (170) |
| `vdbclienttest.lpr` | Delphi client tests (101) |
| `vdbcrypttest.lpr` | Crypto unit tests (60) |
| `cdc_test.lpr` | CDC/TimeTravel tests (38) |
| `VDbTest.pas` | **STUB - unused** |

---

## GUI / Tools

| File | Purpose |
|------|---------|
| `guimain.pas` / `guimain.lfm` | Simple admin GUI |
| `had.lpr` | Advanced admin GUI (HAL) |
| `mtakipwebsrv.lpr` | Web server demo |

---

## Build / Config

| File | Purpose |
|------|---------|
| `sqltest.lpi` | Main test project |
| `vdbapi.lpi` | DLL project |
| `vdbcomponents.lpk` | TDataSet component package |
| `vdbgui.lpi` | GUI project |
| `cdc_test.lpi` | CDC test project |
| `build_dll.ps1` | PowerShell DLL build script |
| `packagefiles.xml` | Lazarus package file list |

---

## Documentation

| File | Purpose |
|------|---------|
| `README.md` | Project overview, architecture, SQL scope, error codes |
| `SQL.md` | Complete SQL reference |
| `DENETIM_VE_YOL_HARITASI.md` | Audit log + roadmap (F1-F3 fixes with mutation proofs) |
| `yol_haritasi.md` | Visual roadmap (R-01 to R-24) |
| `SIFRELEME_PLANI.md` | Encryption design, threat model |
| `DLL_KULLANIM.md` | C API usage, CDC/TimeTravel exports |
| `09-KARSILASTIRMA_VE_YOL_HARITASI.md` | Engine comparison |
| `AST_DONUSUM_PLANI.md` | AST transformation plan |
| `UYGULAMA_ANALIZ_VE_YOL_HARITASI.md` | Application analysis |
| `vdb_analiz_raporu.md` | Analysis report |

---

## Backup / Old Versions (Reference Only)

| File | Note |
|------|------|
| `VDbAst_backup.pas` | Old AST version |
| `VDbParser.pas.bak` / `.test` | Parser backups |
| `VDbTable_orig.pas` / `_test.pas` | Table layer backups |
| `VDbExecutor.pas` (305KB) | Current executor - largest file |
| `VDbParser.pas` (132KB) | Current parser |
| `VDbTable.pas` (234KB) | Current table layer |

---

## Quick Navigation Tips

- **Storage bug?** → `VDbCore.pas` (Put/Get/CommitBatch/Recover)
- **Schema/FK/Index bug?** → `VDbTable.pas` (Insert/UpdateWhere/DeleteWhere/AlterTable)
- **SQL parse error?** → `VDbParser.pas` (tokenizer, ParseSelect, ParseExpr)
- **Wrong query result?** → `VDbExecutor.pas` (ExecSelect, ExecJoin, ExecGroupBy, ExecWindow)
- **Encryption issue?** → `VDbCrypt.pas` + `VDbCore.pas` (encryption hook)
- **CDC not firing?** → `VDbCdc.pas` (Start, OnChange, poll mode)
- **AS OF SEQUENCE broken?** → `VDbExecutor.pas` (BuildAsOfRows) + `VDbTimeTravel.pas`
- **DLL export missing?** → `vdbapi.pas` + `vdbapi.h`
- **TDataSet not working?** → `VDbDataSet.pas` (TVDbQuery)
- **Turkish collation wrong?** → `VDbText.pas` (TrCompare, TrWeight)

---

## Mutation-Tested Fixes (F1-F3)

Search for these prefixes in code comments to find verified fixes:

- `F1-1` to `F1-23` — Critical (data loss/wrong result/crash)
- `F2-1` to `F2-23` — Medium (inconsistency/performance/roughness)
- `F3-1` to `F3-7` — Low (hygiene)

Each has a mutation proof in `DENETIM_VE_YOL_HARITASI.md` (revert fix → test fails).