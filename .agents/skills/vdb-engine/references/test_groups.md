# VDB Engine - Test Groups Reference

Quick lookup: which test group covers what feature. Use to run targeted tests or find relevant assertions.

---

## sqltest.exe Test Groups (1652 total)

Run all: `./sqltest.exe`
Run specific: Search `Testler.Add('GROUP NAME', @TestProc)` in `sqltest.lpr`

| Group | Tests | Coverage |
|-------|-------|----------|
| **1. Veritabani komutlari** | 10 | CREATE/DROP/LIST DATABASE, IF NOT EXISTS, path validation |
| **2. Veri tipleri** | 15 | INTEGER/FLOAT/TEXT/BOOL/DATE/DATETIME/TIME/BLOB, type coercion, locale |
| **3. CREATE TABLE kisitlari** | 13 | PK, NOT NULL, UNIQUE, DEFAULT, CHECK, FK |
| **4. INSERT bicimleri** | 8 | Column list, positional, multi-row, DEFAULT, NULL |
| **5. SELECT temelleri** | 12 | *, alias, WHERE, ORDER BY, LIMIT, OFFSET, DISTINCT |
| **6. WHERE karsilastirmalari** | 18 | =, <>, <, <=, >, >=, LIKE, IN, BETWEEN, IS NULL, AND/OR/NOT |
| **7. JOIN islemleri** | 15 | INNER, LEFT, RIGHT, FULL, CROSS, chain, deep nesting |
| **8. GROUP BY + aggregate** | 14 | COUNT/SUM/AVG/MIN/MAX, HAVING, GROUP BY + ORDER BY |
| **9. Kume islemleri** | 12 | UNION/ALL, EXCEPT, INTERSECT, column count check |
| **10. Alt sorgular** | 10 | IN (SELECT), scalar, EXISTS, uncorrelated |
| **11. WITH CTE** | 8 | Chain CTEs, CTE + JOIN, recursive not supported |
| **12. CASE WHEN** | 8 | Searched + simple, ELSE NULL, NULL handling |
| **13. Pencere fonksiyonlari** | 16 | ROW_NUMBER, RANK, DENSE_RANK, LAG, LEAD, aggregates OVER |
| **14. INSERT...SELECT** | 6 | Basic, with WHERE, multi-table |
| **15. UPSERT (ON CONFLICT)** | 18 | DO UPDATE, DO NOTHING, EXCLUDED, INSERT SELECT ON CONFLICT |
| **16. UPDATE** | 12 | Basic, arithmetic, WHERE, multi-col, unknown column error |
| **17. DELETE** | 8 | Basic, WHERE, LIMIT, JOIN not supported |
| **18. Transaction** | 12 | BEGIN/COMMIT/ROLLBACK, DDL in tx, nested, auto-tx |
| **19. SAVEPOINT (R-02)** | 7 | SAVEPOINT, ROLLBACK TO, RELEASE, nested |
| **20. DDL** | 15 | ALTER TABLE (ADD/DROP/RENAME COLUMN, TYPE), CREATE/DROP INDEX |
| **21. VACUUM/REINDEX/VERIFY** | 6 | VACUUM, REINDEX, VERIFY, BACKUP |
| **22. SHOW/LIST** | 8 | SHOW TABLES, COLUMNS, INDEXES, CREATE TABLE, DATABASES |
| **23. EXPORT/IMPORT JSON** | 8 | EXPORT TABLE, IMPORT TABLE, BLOB handling |
| **24. Parametreler (?)** | 10 | Positional params, type binding, count mismatch |
| **25. Turkiyece (COLLATE TR)** | 12 | UPPER/LOWER/LENGTH TR, ORDER BY COLLATE TR, weight table |
| **26. BLOB** | 8 | Insert/select/update binary, hex display, JSON export |
| **27. Crash kurtarma** | 12 | Power loss sim, torn write, CRC corruption, Verify |
| **28. Legacy gecis** | 6 | V1 .odb migration, MigrateLegacy |
| **29. F1/F2/F3 regresyon** | 25 | Mutation-tested fixes from audit |
| **30. Sema sorgulari** | 10 | DESCRIBE, SHOW INDEXES, SHOW CREATE TABLE |
| **31. WAL replay** | 10 | WAL recovery, torn tail, CRC, checkpoint, auto-WAL |
| **32. Otomatik WAL** | 14 | Put/Delete auto-log, CommitBatch logging, write-fail rollback |
| **33. Sifreleme** | 16 | Encrypted write/read, .key file, ALTER DATABASE KEY, WAL+enc |
| **34. AS OF SEQUENCE (T78)** | 31 | Historical query, deleted rows, UPDATE before, limits, errors |
| **35. OFFSET alias** | 4 | OFFSET in alias list, OFFSET n LIMIT m syntax |
| **36. UNION ORDER/LIMIT** | 8 | Set op + ORDER BY + LIMIT + OFFSET (post-merge) |
| **37. NOT IN NULL** | 6 | NOT IN with NULL in list returns no rows |
| **38. NULL mantigi** | 10 | =/<>/LIKE with NULL = UNKNOWN, NOT NULL = UNKNOWN |
| **39. SUM bos kume** | 4 | SUM empty = NULL, COUNT empty = 0 |
| **40. GROUP BY ORDER BY tip** | 9 | COUNT→INT, SUM/AVG→FLOAT for sorting |
| **41. ORDER BY bilinmeyen** | 4 | Unknown column = error not silent |
| **42. Derinlik kontrolu** | 3 | 256 nest limit, paren/NOT chain |
| **43. SplitStatements** | 13 | Quotes, comments, semicolons in strings |
| **44. FK CASCADE/RESTRICT** | 12 | ON DELETE/UPDATE CASCADE, SET NULL, RESTRICT |
| **45. UNIQUE bos string** | 6 | Empty string exempt from UNIQUE |
| **46. BatchInsert** | 6 | Multi-row, AutoInc, schema flush |
| **47. ALTER COLUMN TYPE** | 8 | PK type change blocked, FK/CHECK revalidate |
| **48. Self-referans FK** | 6 | Self-FK, cascade depth limit |
| **49. BLOB indeks** | 4 | BLOB in composite index rejected |
| **50. Verify rapor** | 4 | BATCHEND not counted as PUT |
| **51. UNION O(N^2)** | 4 | RowEncodeKey dedup, ecLimit |
| **52. Pencere bellek** | 4 | Index-sort vs tmp matrix |
| **53. Alt sorgu materyalizasyon** | 4 | IN/EXISTS single-column projection |
| **54. StmtBatchSafe** | 4 | Auto-tx atomicity rules |
| **55. F-35 Function/Proc** | 32 | CREATE FUNCTION/PROCEDURE, CALL, RETURN, scalar subquery |
| **56. Trigger (F-36)** | 42 | BEFORE/AFTER ROW/STATEMENT, WHEN, INSTEAD OF, nested |
| **57. View (R-06)** | 18 | CREATE VIEW, VIEW DML (INSERT/UPDATE/DELETE) |
| **58. Materialized View (R-07)** | 10 | CREATE MATERIALIZED VIEW, REFRESH |
| **59. RETURNING** | 12 | INSERT/UPDATE/DELETE/ON CONFLICT RETURNING |
| **60. DELETE DATABASE** | 4 | DROP DATABASE in ExecRaw with StmtBatchSafe check |

---

## Other Test Suites

### vdbapitest.lpr (170 tests) - DLL C ABI
- Open/Close, Exec, Prepare/Step/Finalize
- Column metadata, blob, params
- Transaction, savepoint
- Encryption, CDC poll, TimeTravel
- Error codes, edge cases

### vdbclienttest.lpr (101 tests) - TDataSet
- TVDbQuery: Open, Navigate, Edit/Post/Delete/Insert
- Params, bookmarks, field types
- CanModify logic, PK handling, NULL semantics

### vdbcrypttest.lpr (60 tests) - Crypto Unit
- PBKDF2 vectors, HMAC-SHA256, AES-256-CTR
- .key file format, fingerprint, rekey
- 68-position loop test

### cdc_test.exe (38 tests) - CDC/TimeTravel
- INSERT/UPDATE/DELETE event capture
- OldValues for UPDATE/DELETE
- Schema record skipping
- AS OF SEQUENCE point-in-time reads
- Checkpoint boundary (history wiped)

---

## Running Specific Groups

```bash
# All tests
./sqltest.exe

# Filter output for specific group (manual)
./sqltest.exe 2>&1 | grep -A 20 "=== 15. UPSERT"

# Run single test file (if extracted)
# Not directly supported - sqltest runs all groups sequentially
```

---

## Adding a New Test

1. Open `sqltest.lpr`
2. Find `Testler.Add('GROUP NAME', @TestProc)` pattern
3. Add your test procedure:
```pascal
procedure TestMyFeature;
var
  R: TVDbResult;
begin
  R := Sq.Exec('SELECT 1');
  AssertEquals('desc', 'expected', R.Cols[0].AsString[0]);
  R.Free;
end;
```
4. Register: `Testler.Add('My Feature', @TestMyFeature);`
5. **Mutation test:** Revert your fix → run test → verify it FAILS

---

## Test Infrastructure

| Function | Purpose |
|----------|---------|
| `AssertEquals(desc, expected, actual)` | String comparison |
| `AssertTrue(desc, condition)` | Boolean check |
| `AssertError(code, sql)` | Expect specific error code |
| `AssertRowCount(desc, expected, result)` | Row count check |
| `TempDir` | Auto-cleanup temp directory per test run |

---

## Continuous Integration

No CI configured. Manual verification:
```bash
lazbuild sqltest.lpi && ./sqltest.exe
lazbuild vdbapi.lpi && ppc386 vdbapitest.lpr && ./vdbapitest.exe
lazbuild vdbcomponents.lpk
lazbuild cdc_test.lpi && ./cdc_test.exe
```

All must show 0 failures before commit.