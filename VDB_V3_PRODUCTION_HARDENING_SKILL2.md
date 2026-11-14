# VDB V3 — Production Storage Architecture & Hardening Supplement

## 18. SQLite-Style Single-File Database Architecture

### Objective

VDB V3 must support a user-friendly, portable, single-file database architecture similar to SQLite from an operational perspective, while retaining its own storage engine, WAL implementation, page management, transaction system, and recovery mechanisms.

**Target user experience:**

```text
my_database.odb
```

The user should be able to create, open, close, copy, move, and distribute a database primarily through this single file.

### 18.1 Mandatory Repository Inspection

Before implementation, inspect and document:

- `VDbPageStore.pas`
- `VDbPageWal.pas`
- Page cache implementation
- B+Tree storage
- Transaction manager
- Checkpoint implementation
- Recovery implementation
- Database creation/opening paths
- External storage backend
- `.odb.log` generation
- WAL segment creation
- Base/generation file creation
- Database shutdown and cleanup
- Backup and restore implementation

Do not assume the existing storage architecture is fully single-file merely because `VDbPageStore.pas` writes an `.odb` file.

### 18.2 Storage Architecture Modes

Implement or preserve two clearly separated storage modes.

#### Embedded Single-File Mode

Default mode:

```text
database.odb
```

The database container must internally manage:

- Database metadata
- Page allocation metadata
- Data pages
- Index pages
- Transaction metadata
- Checkpoint metadata
- Format version
- Recovery metadata
- Database configuration metadata
- Required persistent storage structures

Temporary operational files may exist when required by durability or implementation constraints, but must be managed safely and documented.

#### Managed Storage Mode

Optional advanced mode:

```text
database/
    database.odb
    wal/
    storage/
```

This mode may support:

- External WAL segments
- Multiple base generations
- Advanced checkpoint management
- Large database maintenance
- Specialized deployment configurations

Do not force users to use Managed Storage Mode for ordinary database operation.

### 18.3 Single-File Requirements

- Database must remain page-based.
- Random page reads and writes must be supported.
- Opening a database must not load the entire file into RAM.
- Large databases must not require proportional RAM usage.
- Page Cache must remain active.
- WAL durability must not be removed to achieve a single-file appearance.
- Database file growth must be controlled.
- Database format must be versioned.
- File locking must protect against conflicting writers.
- Database close must release all handles and locks.
- Database reopening must restore consistent state.
- Recovery must work after process termination.
- Recovery must work after simulated incomplete writes.
- Database corruption must be detected and reported.

### 18.4 SQLite Comparison Boundary

VDB must not copy SQLite implementation internals.

The target is operational simplicity:

- One primary database file
- Portable database
- Embedded database operation
- Predictable recovery
- Low deployment complexity

VDB must retain its own:

- Page format
- B+Tree
- WAL
- Transaction manager
- SQL engine
- Recovery algorithm
- Database format

---

## 19. WAL, Checkpoint, Recovery and File Lifecycle

### 19.1 WAL Durability

Review and enforce the following:

- WAL record format
- WAL record checksums
- Commit record semantics
- WAL flush ordering
- Data page flush ordering
- Checkpoint ordering
- WAL truncation
- WAL reuse
- WAL rotation
- WAL segment recovery
- WAL corruption detection
- Incomplete transaction recovery
- Committed transaction recovery
- Checkpoint crash recovery

Never acknowledge a durable commit before the configured durability requirements have been satisfied.

### 19.2 Crash Consistency

Create deterministic crash tests at:

- Transaction begin
- Page modification
- WAL record write
- WAL flush
- Commit record write
- Commit record flush
- Checkpoint begin
- Checkpoint page write
- Checkpoint completion
- WAL truncation

After every crash scenario:

- Reopen database.
- Run recovery.
- Validate committed transactions.
- Validate rollback of incomplete transactions.
- Verify indexes and page structures.
- Verify database consistency.

### 19.3 WAL Management

The implementation must prevent:

- Unbounded WAL growth
- Incorrect WAL truncation
- Lost committed transactions
- Duplicate transaction replay
- Recovery loops
- Corrupt checkpoint metadata
- Unsafe deletion of WAL segments

WAL cleanup must be based on validated recovery and checkpoint rules, not file age alone.

---

## 20. Page Cache and Single-File Performance

### 20.1 Page Cache Requirements

Implement or verify:

- Configurable cache size
- Cache hit/miss counters
- Page pin/unpin
- Dirty page tracking
- Eviction policy
- Dirty page flushing
- Page invalidation
- Concurrent cache access
- Cache consistency
- Memory limits

### 20.2 Cache Metrics

Expose:

- Cache capacity
- Current cache usage
- Cache hit count
- Cache miss count
- Hit ratio
- Dirty page count
- Eviction count
- Page read count
- Page write count
- Flush duration

### 20.3 Storage Performance

Single-file mode must not introduce unnecessary full-file scans.

Avoid:

- Loading entire database into memory
- Rewriting the entire database for ordinary updates
- Full database scans for simple page allocation
- Unnecessary page copies
- Excessive synchronization
- Excessive WAL flushes
- Unbounded dirty page accumulation

Performance must be evaluated using measured benchmarks rather than assumptions.

---

## 21. Concurrency, Locking and Isolation

### 21.1 Transaction Isolation

Audit and document:

- Supported isolation levels
- Read/write conflict behavior
- Lock acquisition order
- Deadlock detection
- Transaction timeout
- Concurrent commit behavior
- Concurrent reads
- Concurrent writes
- Index modification concurrency

### 21.2 File Locking

Implement or verify platform-specific locking for:

- Windows
- Linux
- macOS

Requirements:

- Multiple readers must be supported according to the selected architecture.
- Conflicting writers must be prevented.
- Lock ownership must be tracked.
- Lock release must occur on normal shutdown.
- Process termination must not permanently block database access.
- Lock errors must be explicit.
- Locking must not rely exclusively on application-level flags.

### 21.3 Multiprocess Safety

Test:

- Two processes opening the same database.
- Two processes attempting writes.
- Reader process during writer activity.
- Writer termination.
- Database reopening after termination.
- Lock contention.
- Simultaneous checkpoint requests.

Do not claim multiprocess safety until these tests pass.

---

## 22. Performance Benchmark and Regression System

### 22.1 Mandatory Benchmark Categories

Create repeatable benchmarks for:

- Database creation
- Database opening
- Database closing
- Sequential inserts
- Random inserts
- Sequential reads
- Random reads
- Updates
- Deletes
- Index creation
- Indexed lookups
- Range queries
- Transactions
- Concurrent transactions
- WAL recovery
- Checkpoint
- Database backup
- Database restore

### 22.2 Benchmark Metrics

Record:

- Operations per second
- Average latency
- P50 latency
- P95 latency
- P99 latency
- Maximum latency
- Memory usage
- Database size
- WAL size
- Cache hit ratio
- CPU usage where available

### 22.3 Benchmark Reproducibility

Each benchmark must document:

- Dataset size
- Hardware
- Operating system
- Compiler version
- Build configuration
- Database configuration
- Cache configuration
- Transaction settings
- Test procedure

Do not compare benchmarks with different conditions without documenting the differences.

### 22.4 Performance Regression Gates

Define acceptable regression thresholds for critical benchmarks.

Performance regression must be:

- Detected
- Reported
- Reproducible
- Investigated

Do not optimize by weakening correctness, transaction durability, or integrity checks.

---

## 23. Database Integrity Checker

### 23.1 Integrity Check Command

Implement a database integrity inspection facility.

Example conceptual interface:

```text
VDB integrity-check database.odb
```

The command must inspect:

- Database header
- Format version
- Page boundaries
- Page identifiers
- Page checksums
- Page allocation metadata
- Free page structures
- B+Tree structure
- B+Tree ordering
- Parent/child references
- Index consistency
- Transaction metadata
- WAL consistency
- Checkpoint consistency
- Internal metadata references

### 23.2 Integrity Check Modes

Support clearly documented modes:

- Quick structural check
- Full database check
- Index consistency check
- WAL inspection
- Recovery validation

### 23.3 Integrity Check Safety

The integrity checker must:

- Avoid modifying the database during read-only inspection.
- Report the exact failure category.
- Report affected page IDs where possible.
- Distinguish warnings from corruption.
- Never silently repair corruption.
- Require explicit authorization for repair operations.

### 23.4 Recovery and Repair

If repair functionality is implemented:

- Create a backup before modification.
- Use a separate repair workflow.
- Record all repair actions.
- Preserve recoverable data.
- Report unrecoverable structures.
- Verify the repaired database afterward.

---

## 24. Database Format Compatibility and Migration

### 24.1 Format Versioning

Every database must contain:

- Format identifier
- Format version
- Compatible reader version information where applicable
- Required feature flags
- Page size
- Metadata version

### 24.2 Compatibility Rules

The engine must distinguish:

- Supported database format
- Older supported format
- Newer unsupported format
- Corrupted format
- Incomplete migration

Never silently open an incompatible database as if it were valid.

### 24.3 Migration

If format migration is supported:

- Migration must be explicit.
- Original database must remain recoverable.
- Migration must be crash-safe.
- Migration must validate the result.
- Migration must record its progress.
- Interrupted migration must have a defined recovery procedure.
- Migration must not silently destroy data.

### 24.4 Upgrade Tests

Test:

- Opening older database versions
- Migrating older database versions
- Interrupted migration
- Migration rollback
- Migration validation
- Reopening migrated databases
- Index consistency after migration

---

## 25. Operational Limits and Resource Management

### 25.1 Explicit Limits

Define and document:

- Maximum database size
- Maximum page count
- Maximum page size
- Maximum transaction size
- Maximum WAL size
- Maximum concurrent transactions
- Maximum cache memory
- Maximum index depth
- Maximum SQL statement size
- Maximum result size
- Maximum connection count

Limits must be enforced safely.

### 25.2 Resource Exhaustion

Test:

- Disk full
- Memory exhaustion
- WAL growth
- Cache exhaustion
- Too many connections
- Too many transactions
- Oversized SQL statements
- Excessive index growth

The engine must return controlled errors rather than crash or corrupt the database.

### 25.3 Shutdown

Shutdown must:

- Stop accepting new work.
- Handle active transactions according to documented rules.
- Flush required WAL data.
- Complete or safely interrupt checkpoint operations.
- Release file handles.
- Release locks.
- Report shutdown failures.

---

## 26. Backup, Restore and Portability

### 26.1 Backup

Implement a consistent backup mechanism.

Backup must not produce a database containing:

- Inconsistent pages
- Missing committed transactions
- Invalid checkpoint metadata
- Incomplete index structures

### 26.2 Backup Verification

Every backup test must:

1. Create a database.
2. Insert test data.
3. Commit transactions.
4. Create backup.
5. Restore backup.
6. Reopen restored database.
7. Run integrity check.
8. Compare data and indexes.

### 26.3 Portability

Test moving database files between:

- Windows
- Linux
- macOS

Database files must not depend on:

- Absolute filesystem paths
- Host-specific pointers
- Native structure padding
- Endianness assumptions
- Compiler-specific binary layouts

Persistent structures must use explicit serialization rules.

---

## 27. Final Production Acceptance Gates

The VDB V3 storage architecture must not be considered complete until:

- [ ] Single-file database mode works.
- [ ] Database opening does not load the entire database into RAM.
- [ ] Page-based random access works.
- [ ] WAL durability is validated.
- [ ] Crash recovery tests pass.
- [ ] Checkpoint recovery tests pass.
- [ ] Database integrity checker works.
- [ ] B+Tree integrity checks pass.
- [ ] Backup and restore tests pass.
- [ ] Concurrent access tests pass.
- [ ] Multiprocess locking tests pass.
- [ ] Database migration tests pass.
- [ ] Cross-platform file compatibility is validated.
- [ ] Performance benchmarks are reproducible.
- [ ] Performance regression gates are established.
- [ ] Disk-full behavior is tested.
- [ ] Resource exhaustion behavior is tested.
- [ ] No silent corruption is observed.
- [ ] No committed transaction is lost under tested crash scenarios.
- [ ] Existing V3 SQL tests remain passing.
- [ ] V2 remains frozen and isolated.

## 28. Mandatory AI Agent Implementation Rules

The AI agent must:

1. Inspect the existing V3 repository before modifying files.
2. Identify existing implementations before creating replacements.
3. Avoid duplicate storage engines.
4. Avoid duplicate WAL implementations unless explicitly justified.
5. Avoid unnecessary executable files.
6. Preserve existing passing tests.
7. Add regression tests for every behavior change.
8. Never weaken transaction durability for performance.
9. Never remove integrity checks to increase benchmark results.
10. Never claim production readiness without evidence.
11. Never claim SIL, certification, or safety compliance without an applicable independent verification process.
12. Document architectural changes.
13. Keep V2 isolated and unchanged.
14. Work exclusively on V3.

### Final Objective

VDB V3 should become a portable, reliable, page-based database engine with a simple single-file deployment experience, robust WAL and recovery, predictable performance, strong integrity checks, and professionally maintained compatibility and testing infrastructure.

Single-file operation is a storage and deployment objective; it is not a substitute for transaction durability, crash consistency, or database integrity.
