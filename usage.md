# VDB Usage Guide

This guide covers using the engine from a Pascal application, from the DLL/C
API, and through SQL. For an overview see [readme_en.md](readme_en.md); for
performance see [speedtest.md](speedtest.md).

---

## 1. Setup and build

Requirements:

- Lazarus 4.6+ / Free Pascal 3.2.4
- `dcpcrypt/` (bundled in the repository)

```bash
# SQL test suite
lazbuild -B sqltest.lpi

# DLL / C API
lazbuild -B vdbapi.lpi

# Linux/macOS library
./build_lib.sh
```

Outputs:

| File | Description |
|---|---|
| `sqltest.exe` | SQL test suite |
| `vdbapi.dll` / `.so` | C/Delphi DLL API |

---

## 2. Pascal API — `TVSql`

Use the `VDbSql` unit. `TVSql.Exec` runs one SQL string (or several statements
separated by `;`) and returns a `TSqlResult`.

```pascal
uses VDbSql, VDbTypes;

var
  DB: TVSql;
  R: TSqlResult;
begin
  DB := TVSql.Create('D:\data\app.odb');
  try
    DB.Exec('CREATE TABLE customer (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'name TEXT NOT NULL, ' +
      'email TEXT UNIQUE, ' +
      'created DATETIME DEFAULT CURRENT_TIMESTAMP)', R);
  finally
    DB.Free;
  end;
end;
```

### Result structure

| Field | Meaning |
|---|---|
| `R.Cols` | Column names |
| `R.Rows` | Row count |
| `R.Data[i][j]` | Cell value (text) |
| `R.Affected` | Affected rows (DML/DDL) |
| `R.Msg` | Engine message |

Values travel as text; the application performs numeric/date conversion.

### Parameterized execution

```pascal
DB.ExecParams('INSERT INTO customer (name, email) VALUES (?, ?)',
  ['John', 'john@example.com'], R);
```

### Transactions

```pascal
DB.Exec('BEGIN', R);
try
  DB.Exec('INSERT INTO customer (name) VALUES (''Jane'')', R);
  DB.Exec('UPDATE customer SET email = ''j@x'' WHERE name = ''Jane''', R);
  DB.Exec('COMMIT', R);
except
  DB.Exec('ROLLBACK', R);
  raise;
end;
```

`SAVEPOINT name`, `ROLLBACK TO name` and `RELEASE name` are supported.

### MVCC / batches

```pascal
DB.BeginBatch;
try
  DB.Exec('INSERT INTO customer (name) VALUES (''pending'')', R);
  // Your own writes are visible inside the batch.
  DB.CommitBatch;
except
  DB.AbortBatch;
  raise;
end;
```

### WAL

```pascal
DB.WALEnabled := True;          // mirror every write into the .wal file
DB.ReplayWAL;                   // apply a pending log at startup
DB.CheckpointWAL;               // fold the log into the main file and delete it
```

`SyncWriteInterval = 0` (the default) writes synchronously on every commit.
Higher values enable group commit; on a crash at most that many operations may
be lost.

### Indexes

```sql
CREATE INDEX ix_customer_name ON customer (name);
CREATE UNIQUE INDEX ux_email ON customer (email);
CREATE INDEX ix_partial ON customer (name) WHERE name IS NOT NULL;
CREATE INDEX ix_expr ON customer (LOWER(name));
CREATE INDEX ix_cover ON customer (name) INCLUDE (email);
CREATE INDEX CONCURRENTLY ix_online ON customer (email);
```

Secondary indexes live in the H3 skiplist. `COUNT(*)` and range queries use
the index in O(log N). For a multi-column index the range is narrowed by the
leading column only; remaining predicates are checked per row.

### Statistics and plans

```sql
ANALYZE customer;
EXPLAIN SELECT * FROM customer WHERE id = 5;
EXPLAIN ANALYZE SELECT * FROM customer WHERE age > 30;
SHOW STATS;
SHOW SLOW QUERIES;
```

---

## 3. SQL usage

### Tables and data

```sql
CREATE TABLE product (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  name     TEXT NOT NULL,
  price    FLOAT DEFAULT 0,
  stock    INTEGER DEFAULT 0,
  tags     JSONB,
  created  DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO product (name, price, stock) VALUES ('Laptop', 15000, 5);
INSERT INTO product (name, price, stock) VALUES
  ('Mouse', 250, 40),
  ('Keyboard', 600, 25);

SELECT name, price FROM product
WHERE price BETWEEN 200 AND 20000
ORDER BY price DESC
LIMIT 10;

UPDATE product SET stock = stock - 1 WHERE id = 1;
DELETE FROM product WHERE stock = 0;
```

### JOINs and subqueries

```sql
SELECT p.name, s.qty
FROM product p
JOIN sale s ON s.product_id = p.id
WHERE s.sold_at >= '2026-01-01';

SELECT name FROM product
WHERE price > (SELECT AVG(price) FROM product);
```

### CTEs and window functions

```sql
WITH expensive AS (
  SELECT * FROM product WHERE price > 1000
)
SELECT name, price,
       ROW_NUMBER() OVER (ORDER BY price DESC) AS rn
FROM expensive;
```

### UPSERT and RETURNING

```sql
INSERT INTO product (id, name, price) VALUES (1, 'Laptop', 14000)
ON CONFLICT (id) DO UPDATE SET price = excluded.price
RETURNING id, name, price;
```

### JSONB

```sql
SELECT tags -> 'color' FROM product;
SELECT * FROM product WHERE tags ? 'promo';
SELECT * FROM product WHERE tags @> '{"color":"blue"}';
```

### Range and Spatial

```sql
SELECT * FROM booking
WHERE period && '[2026-01-01, 2026-02-01)';

SELECT * FROM place
WHERE ST_Distance(location, ST_Point(29.0, 41.0)) < 1000;
```

### Encryption

```sql
ALTER DATABASE KEY 'strongPassword123';      -- initial password
ALTER DATABASE KEY 'newStrongPassword456';   -- rotation
```

The password derives a key stored in a `.key` file; a `.bak` copy is kept.
Reading without the key (or with the wrong one) raises an error instead of
silently returning corrupted data.

### RBAC and RLS

```sql
CREATE ROLE reader;
GRANT SELECT ON customer TO reader;
SET ROLE reader;

ALTER TABLE customer ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_self ON customer FOR SELECT USING (owner = current_user());
```

### Maintenance and backup

```sql
BACKUP DATABASE TO 'D:\backup\app-backup.odb';
COMPACT;
RESTORE FROM 'D:\backup\app-backup.odb';
ARCHIVE WAL SET DIR = 'D:\archive';
RECOVER;
```

---

## 4. TCP SQL server

```pascal
uses VDbSqlServer, VDbClientNet;

var
  Srv: TVdbSqlServer;
  Cl: TVdbNetClient;
  R: TSqlResult;
  Err: string;
begin
  Srv := TVdbSqlServer.Create('D:\db', 54720);
  try
    if not Srv.Start(Err) then
      raise Exception.Create(Err);

    Cl := TVdbNetClient.Create;
    try
      Cl.Connect('127.0.0.1', 54720);
      if Cl.Login('admin', 'admin123') then
      begin
        R := Cl.Exec('SELECT COUNT(*) FROM customer');
        WriteLn(R.Data[0][0]);
        Cl.Logout;
      end;
    finally
      Cl.Free;
    end;
  finally
    Srv.Free;
  end;
end;
```

The server speaks the VDBS protocol and supports prepared statements
(`Prepare` / `ExecutePrepared`) plus a connection pool. A PostgreSQL wire
implementation (`VDbPgWire`) is also available for simple and extended query
flows.

---

## 5. DLL / C API

`vdbapi.dll` (Linux: `libvdbapi.so`) exports 57 functions.

```pascal
function VdbOpen(const DbPath: PAnsiChar): Integer; stdcall;
function VdbExec(const Sql: PAnsiChar; var ResultHandle: Integer): Integer; stdcall;
function VdbGet(ResHandle, Row, Col: Integer; Buf: PAnsiChar; BufLen: Integer): Integer; stdcall;
procedure VdbClose(DbHandle: Integer); stdcall;
```

From C:

```c
#include "vdbapi.h"

int db = VdbOpen("database.odb");
int res = 0;
VdbExec("SELECT 1+1", &res);
char buf[64];
VdbGet(res, 0, 0, buf, sizeof(buf));
VdbClose(db);
```

Rules:

- All text is UTF-8.
- `VdbGet` is two-phase: query the buffer size first, then fetch the value.
- A database should be opened by one program at a time.
- Match the DLL bitness with the application bitness.

---

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `tablo yok: x` (no such table) | Run `CREATE TABLE x` first |
| `UNIQUE ihlali` | Value already exists; use `UPSERT` |
| `RLS politika ihlali` | The role's policy does not cover the written row |
| `yetkisiz: ...` | Grant the privilege or `SET ROLE NONE` |
| Keyless read error | Open the `.key` password with `OpenKeyFile` |
| `AS OF ... desteklenmiyor` | WAL is off or a checkpoint removed the history |

---

## 7. Examples

Example projects are not tracked in this repository; the engine units,
`vdbapi` and the `sqltest` suite are the supported contents.

---

## 8. Tests

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

Expected final line: `SONUC: gecen=2755 kalan=0`.
