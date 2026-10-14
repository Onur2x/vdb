# VDB Engine - Common Patterns & How-To Guide

Quick reference for common coding patterns in this codebase.

---

## 1. Opening a Database (Correct Order)

```pascal
var
  Kv: TVDb;
  Tb: TVTableDb;
  Sq: TVSql;
begin
  Kv := TVDb.Create;
  Tb := TVTableDb.Create(Kv);
  Sq := TVSql.Create(Tb);
  try
    Kv.Open('/path/to/dbdir');      // 1. Open KV (creates/opens .odb)
    Tb.Open('/path/to/dbdir');      // 2. MUST CALL - loads schema from .odb
    // Now use Sq.Exec(...)
  finally
    Sq.Free; Tb.Free; Kv.Free;      // Reverse order
  end;
end;
```

⚠️ **Never skip `Tb.Open`** — schema won't load, "table not found" on restart.

---

## 2. Executing SQL

```pascal
// Single statement, returns result set (SELECT, SHOW, etc.)
R := Sq.Exec('SELECT * FROM users WHERE age > ?', [18]);
try
  for i := 0 to R.RowCount - 1 do
    WriteLn(R.Cols[0].AsString[i]);  // 'name' column
finally
  R.Free;
end;

// Multiple statements (DDL, batch) - no result set
Sq.ExecAll('CREATE TABLE t (id INT PRIMARY KEY); INSERT INTO t VALUES (1);');

// With explicit transaction
Sq.Exec('BEGIN');
try
  Sq.Exec('INSERT INTO t VALUES (2)');
  Sq.Exec('INSERT INTO t VALUES (3)');
  Sq.Exec('COMMIT');
except
  Sq.Exec('ROLLBACK');
  raise;
end;
```

---

## 3. Using Parameters (Prepared Statements)

```pascal
// Positional ? parameters
R := Sq.Exec('INSERT INTO users (name, email) VALUES (?, ?)', ['Ali', 'ali@test.com']);
R.Free;

// In TVDbQuery (TDataSet)
Qry.SQL.Text := 'SELECT * FROM users WHERE age > :minage';
Qry.Params[0].AsInteger := 18;
Qry.Open;
```

---

## 4. Encryption

```pascal
// Create encrypted DB with password
Kv.CreateKeyFile('/path/to/dbdir/mydb.key', 'secret123');
Kv.Open('/path/to/dbdir');  // Auto-detects .key file

// Or set key programmatically (32-byte raw key)
Kv.SetEncryptionKey(My32ByteKey);

// Check encryption status
if Kv.IsEncrypted then
  WriteLn('Fingerprint: ', Kv.EncryptionKeyFingerprint);  // First 8 hex

// Rotate key (re-encrypts all records)
Kv.RekeyWithPassword('newsecret123');
```

---

## 5. WAL (Write-Ahead Log) - Opt-In

```pascal
// Enable WAL (disabled by default for backward compat)
Kv.WALEnabled := True;
Kv.Open('/path/to/dbdir');

// Checkpoint (flush WAL to main, truncate WAL)
Kv.CheckpointWAL;

// Replay (emergency recovery only - auto mode replays on Open)
Kv.ReplayWAL;

// Read WAL directly (for CDC/TimeTravel)
Count := Kv.WalRecordCount;
Entry := Kv.ReadWalEntry(Index);
```

---

## 6. CDC (Change Data Capture)

```pascal
// Callback mode
Cdc := TVDbCdc.Create(Tb);
Cdc.OnChange := @MyChangeHandler;  // procedure(const Ev: TCDCEvent)
Cdc.Start;
// ... changes happen ...
Cdc.Stop;
Cdc.Free;

// Poll mode (for DLL/external)
Cdc := TVDbCdc.Create(Tb);
Cdc.Start;  // No callback = poll mode
// Later:
while Cdc.TryPeek(Event) do
  Process(Event);
Cdc.Stop;
```

**Event types:** `cdcInsert`, `cdcUpdate`, `cdcDelete`
**Event fields:** `TableName`, `Key`, `NewValues`, `OldValues`, `Seq`

---

## 7. Time Travel (AS OF SEQUENCE)

```pascal
// SQL level
R := Sq.Exec('SELECT * FROM users AS OF SEQUENCE 42');

// Pascal API
Tt := TVTimeTravel.Create(Tb);
Value := Tt.GetValueAt('users', '1', 42);  // JSON string at WAL index 42
Tt.GetRowAt('users', '1', 42, Fields);     // Parsed row
Count := Tt.HistoryCount;                   // Available history depth
Tt.Free;
```

⚠️ History only goes back to last `CheckpointWAL`.

---

## 8. Connection Pool (Multi-thread)

```pascal
Pool := TVDbPool.Create(TableDb, 8, 5000);  // 8 connections, 5s timeout
try
  // Shortcut for one-off
  R := Pool.Exec('SELECT * FROM users');
  R.Free;

  // Or acquire/release for transaction
  Sq := Pool.Acquire;
  try
    Sq.Exec('BEGIN');
    Sq.Exec('UPDATE users SET balance = balance - 100 WHERE id = 1');
    Sq.Exec('UPDATE users SET balance = balance + 100 WHERE id = 2');
    Sq.Exec('COMMIT');
  finally
    Pool.Release(Sq);
  end;
finally
  Pool.Free;
end;
```

---

## 9. TDataSet (DBGrid, FastReport, etc.)

```pascal
Qry := TVDbQuery.Create(nil);
try
  Qry.SqlEngine := Sq;  // Share TVSql (thread-safe via lock)
  Qry.SQL.Text := 'SELECT id, name, salary FROM users ORDER BY id';
  Qry.Open;
  
  DataSource1.DataSet := Qry;  // Connect to DBGrid
  
  // Editing
  Qry.Edit;
  Qry.FieldByName('salary').AsFloat := 9500;
  Qry.Post;  // Becomes UPDATE
  
  // Insert
  Qry.Insert;
  Qry.FieldByName('name').AsString := 'New User';
  Qry.FieldByName('salary').AsFloat := 5000;
  Qry.Post;  // Becomes INSERT
  
finally
  Qry.Free;
end;
```

**Requirements for editable result:**
- Single table
- Simple columns (no expressions)
- PK in output
- `CanModify = True`

---

## 10. Error Handling

```pascal
try
  R := Sq.Exec('INSERT INTO users (id) VALUES (1)');  // Duplicate PK
except
  on E: EVDbException do
    case E.ErrorCode of
      ecDuplicatePrimaryKey: ShowMessage('ID already exists');
      ecUniqueViolation: ShowMessage('Unique constraint violated');
      ecForeignKeyViolation: ShowMessage('Referenced record missing');
      ecNotNullViolation: ShowMessage('Required field empty');
      ecCheckViolation: ShowMessage('Check constraint failed');
      ecTableNotFound: ShowMessage('Table does not exist');
      ecColumnNotFound: ShowMessage('Column does not exist');
      ecSyntaxError: ShowMessage('SQL syntax error: ' + E.Message);
      ecPoolTimeout: ShowMessage('Connection pool exhausted');
      ecPoolClosed: ShowMessage('Pool is closed');
      ecDatabaseLocked: ShowMessage('Database locked by another process');
      ecCorrupt: ShowMessage('Database corruption detected');
    else
      ShowMessage('DB Error: ' + VDbErrorName(E.ErrorCode) + ' - ' + E.Message);
    end;
end;
```

---

## 11. Adding a New SQL Feature (Checklist)

### Parser (`VDbParser.pas`)
- [ ] Add token if new keyword (`TTokenType.ttMYKEYWORD`)
- [ ] Add parse rule in `ParseStatement` or `ParseSelect`
- [ ] Create AST node in `VDbAst.pas` (inherit from `TStmt`/`TExpr`)
- [ ] Handle in `SplitStatements` if new statement terminator

### AST (`VDbAst.pas`)
- [ ] Define node class with properties
- [ ] Implement `Accept` for visitor pattern (if used)
- [ ] Add to `TSelectStmt` / `TStmt` unions as needed

### Executor (`VDbExecutor.pas`)
- [ ] Add case in `ExecuteStatement` / `ExecSelect` 
- [ ] Implement execution logic
- [ ] Return `TVDbResult` with proper columns/rows
- [ ] Handle errors with `EVDbException(ecCode)`

### Tests (`sqltest.lpr`)
- [ ] Add test procedure
- [ ] Register with `Testler.Add`
- [ ] Cover happy path + error cases
- [ ] **Mutation test:** Revert executor change → test must fail

---

## 12. Debugging Tips

```pascal
// Enable SQL logging (in VDbSql.pas)
{$DEFINE VDB_SQL_DEBUG}
// Logs every Exec to console

// Trace parser (in VDbParser.pas)
{$DEFINE VDB_PARSER_TRACE}
// Shows token stream and parse tree

// Verify database integrity
R := Sq.Exec('VERIFY');
WriteLn(R.Cols[0].AsString[0]);  // JSON report

// Check WAL status
R := Sq.Exec('SHOW WAL STATUS');
```

---

## 13. Common Gotchas

| Issue | Cause | Fix |
|-------|-------|-----|
| "Table not found" after restart | Forgot `Tb.Open(dir)` | Always call `Tb.Open` after `Kv.Open` |
| Duplicate PK on INSERT | AutoInc not working | Ensure PK column is `INTEGER PRIMARY KEY` (no explicit value) |
| Turkish UPPER/LOWER wrong | System locale | Uses `VDbText.pas` - locale independent |
| ORDER BY COLLATE TR slow | No index usage | Correct - collation prevents index use |
| WAL growing forever | No checkpoint | Call `CheckpointWAL` periodically |
| CDC not seeing changes | Callback not set + poll not called | Either set `OnChange` OR call `TryPeek`/`TryDequeue` |
| DLL returns error 1001 | `ecDatabaseLocked` | Another process has DB open; use pool or close other |
| Encryption: "key not found" | `.key` file missing or wrong password | `OpenKeyFile` with correct password or `SetEncryptionKey` |

---

## 14. File Modification Guidelines

- **Keep public API stable** — All F1-F3 fixes were in `private` members
- **Add mutation test** — Every bug fix needs a test that fails when fix reverted
- **Turkish comments OK** — Code comments in Turkish; English in docs
- **No external deps** — Pure Pascal, only `LazUtils` for file locking
- **Append-only mindset** — Never overwrite records; `Compact` creates `.bak`

---

## 15. Performance Notes

- **Table lock per `Exec`** — Coarse-grained; readers block writers, writers block all
- **No query optimizer yet** — Rule-based only (R-15 roadmap)
- **Index lookup** — `TryIndexOrder` for ORDER BY, WHERE on indexed cols
- **JOIN algorithm** — Nested loop (hash join not implemented)
- **Window functions** — Materialize + sort (R-14 parallel query roadmap)
- **Large results** — Use `LIMIT` + `OFFSET`; streaming cursor skeleton exists (R-12)

---

## 16. Useful Grep Patterns

```bash
# Find all error codes
grep -r "ec[A-Z]" --include="*.pas" | sort -u

# Find all F1/F2/F3 fix comments
grep -r "F[1-3]-" --include="*.pas"

# Find AST node definitions
grep "^  T[A-Z].* = class" VDbAst.pas

# Find parser rules
grep "procedure Parse" VDbParser.pas

# Find executor entry points
grep "function Exec" VDbExecutor.pas

# Find test registrations
grep "Testler.Add" sqltest.lpr
```

---

## 17. Build Commands Reference

```bash
# Main test executable
lazbuild sqltest.lpi

# DLL (Windows)
lazbuild vdbapi.lpi
# Or: ./build_dll.ps1

# TDataSet component package
lazbuild vdbcomponents.lpk

# GUI tools
lazbuild vdbgui.lpi
lazbuild had.lpi

# CDC test
lazbuild cdc_test.lpi

# Web server demo
lazbuild mtakipwebsrv.lpi

# Run tests
./sqltest.exe
./cdc_test.exe
./vdbapitest.exe  # After ppc386 vdbapitest.lpr
./vdbclienttest.exe
./vdbcrypttest.exe
```

---

## 18. Roadmap Priority Order (From yol_haritasi.md)

1. **R-09** LATERAL JOIN 🟠
2. **R-10** Recursive CTE + CYCLE 🟡
3. **R-11** DEFERRABLE Constraints 🟡
4. **R-12** Multi-process Pool (TCP/named pipe) 🔴
5. **R-13** Table Partitioning 🔴
6. **R-14** Parallel Query Execution 🔴
7. **R-15** Cost-Based Optimizer (ANALYZE) 🔴
8. **R-16** Incremental Backup / WAL Archiving / PITR 🟠
9. **R-17** Streaming Replication 🔴
10. **R-18** RBAC / GRANT / SET ROLE 🟠
11. **R-19** Row Level Security (RLS) 🟠
12. **R-20** ICU Collation 🟡
13. **R-21** Extension/Plugin Mechanism 🔴
14. **R-22** Online DDL (CONCURRENTLY) 🔴
15. **R-23** Cross-platform DLL (.so/.dylib) 🟡
16. **R-24** Monitoring / pg_stat_statements 🟡