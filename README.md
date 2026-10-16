# VDB — İlişkisel Veritabanı Motoru / Relational Database Engine

> **TR:** Free Pascal ile yazılmış, harici DLL gerektirmeyen, tek dosyali (`.odb`) ilişkisel veritabanı motoru. SQL desteği, TCP SQL sunucusu, şifreleme, CDC, Time Travel, ve daha fazlası. **v2.1 performans sürümü:** 1M satırda `COUNT(*)` 800 ms, PK araması 0 ms, `SUM` 2,3 sn — veri kaybı yok (ölçümler aşağıda).
>
> **EN:** A relational database engine written in pure Free Pascal. No external DLL required. Single-file (`.odb`) storage. SQL support, TCP SQL server, encryption, CDC, Time Travel, and more. **v2.1 performance release:** `COUNT(*)` in 800 ms, PK lookups at 0 ms, `SUM` in 2.3 s at 1M rows — zero data loss (measurements below).

---

## 📌 ÖZET / SUMMARY

### TR: Bu Proje Nedir?
VDB (VeriTabanı), masaüstü ve gömülü uygulamalar için tasarlanmış, yüksek performanslı, tek dosyada çalışan bir ilişkisel veritabanı motorudur. SQLite'a alternatif olarak geliştirilmiş; JSONB, Spatial, Range, Trigger, View, Stored Procedure, Partitioning, Parallel Query, Cost-Based Optimizer, PK Lazy Index (BETWEEN için Index Scan) ve Group Commit (`SyncWriteInterval`) gibi ileri özellikleri destekler.

### EN: What Is This Project?
VDB is a high-performance, single-file relational database engine designed for desktop and embedded applications. Developed as an alternative to SQLite, it supports advanced features like JSONB, Spatial, Range types, Triggers, Views, Stored Procedures, Partitioning, Parallel Query, a Cost-Based Optimizer, PK Lazy Index (Index Scan for BETWEEN), and Group Commit (`SyncWriteInterval`).

---

## 🏗️ MİMARİ / ARCHITECTURE

### TR: Katmanlar
```
SQL Metni → VDbParser → VDbAst → VDbExecutor → VDbTable → VDbCore → .odb
```

| Birim / Unit | Rol / Role |
|---|---|
| `VDbCore.pas` | Düşük seviye append-only KV motor + kilit / Low-level append-only KV engine + locking |
| `VDbTable.pas` | Tablo katmanı (şema, indeks, FK, kısıtlar) / Table layer (schema, index, FK, constraints) |
| `VDbAst.pas` | Tip-güvenli AST düğüm modeli / Type-safe AST node model |
| `VDbParser.pas` | Tokenizer + recursive-descent parser |
| `VDbExecutor.pas` | AST yürütücü (filtre, join, gruplama, sıralama) / AST executor (filter, join, grouping, sorting) |
| `VDbSql.pas` | Dış cephe (`TVSql.Exec`) / External facade |
| `VDbErr.pas` | Hata kodları + `EVDbException` / Error codes + exception |
| `VDbText.pas` | Türkçe metin desteği (`TrUpper/Lower`, `COLLATE TR`) / Turkish text support |
| `VDbCrypt.pas` | AES-256 şifreleme (FIPS-197) / AES-256 encryption |
| `VDbWal.pas` | Write-Ahead Logging / WAL |
| `VDbNet.pas` | TCP protokolü (VDBS) / TCP protocol |
| `VDbSqlServer.pas` | TCP SQL sunucusu / TCP SQL server |
| `VDbClientNet.pas` | TCP SQL istemcisi / TCP SQL client |
| `VDbJson.pas` | JSON dışarı/içeri / JSON export/import |
| `VDbDataSet.pas` | `TDataSet` bağlantısı (Lazarus/Delphi) / TDataSet bridge |

---

## 🚀 HIZLI BAŞLANGIÇ / QUICK START

### TR: Derleme
```bash
# Windows (Lazarus 4.6+)
lazbuild -B sqltest.lpi
# veya
lazbuild -B vdbapi.lpi

# Linux/macOS
./build_lib.sh
```

### EN: Build
```bash
# Windows (Lazarus 4.6+)
lazbuild -B sqltest.lpi
# or
lazbuild -B vdbapi.lpi

# Linux/macOS
./build_lib.sh
```

---

## 💻 KULLANIM / USAGE

### TR: Temel SQL
```sql
-- Veritabanı oluştur / Create database
CREATE DATABASE satis;

-- Tablo oluştur / Create table
CREATE TABLE musteri (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ad TEXT NOT NULL,
  email TEXT UNIQUE,
  kayit_tarihi DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Veri ekle / Insert data
INSERT INTO musteri (ad, email) VALUES ('Ahmet', 'ahmet@example.com');
INSERT INTO musteri (ad, email) VALUES ('Ayşe', 'ayse@example.com');

-- Sorgula / Query
SELECT ad, email FROM musteri WHERE ad LIKE 'A%' ORDER BY ad;

-- Güncelle / Update
UPDATE musteri SET email = 'yeni@example.com' WHERE id = 1;

-- Sil / Delete
DELETE FROM musteri WHERE id = 2;
```

### EN: Basic SQL
```sql
-- Create database
CREATE DATABASE sales;

-- Create table
CREATE TABLE customer (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT UNIQUE,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Insert data
INSERT INTO customer (name, email) VALUES ('John', 'john@example.com');
INSERT INTO customer (name, email) VALUES ('Jane', 'jane@example.com');

-- Query
SELECT name, email FROM customer WHERE name LIKE 'J%' ORDER BY name;

-- Update
UPDATE customer SET email = 'new@example.com' WHERE id = 1;

-- Delete
DELETE FROM customer WHERE id = 2;
```

### TR: Pascal API
```pascal
uses VDbSql;

var
  DB: TVSql;
  R: TSqlResult;
begin
  DB := TVSql.Create('veritabani.odb');
  try
    DB.Exec('CREATE TABLE urun (id INTEGER PRIMARY KEY, ad TEXT, fiyat FLOAT)', R);
    DB.Exec('INSERT INTO urun (ad, fiyat) VALUES (''Laptop'', 15000)', R);
    DB.Exec('SELECT * FROM urun WHERE fiyat > 1000', R);
    // R.Rows, R.Cols, R.Data kullan
  finally
    DB.Free;
  end;
end;
```

### EN: Pascal API
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
    DB.Exec('SELECT * FROM product WHERE price > 1000', R);
    // Use R.Rows, R.Cols, R.Data
  finally
    DB.Free;
  end;
end;
```

### TR: TCP SQL Sunucusu (R-12)
```pascal
uses VDbSqlServer, VDbClientNet;

// Sunucu başlat / Start server
var
  Srv: TVdbSqlServer;
  Err: string;
begin
  Srv := TVdbSqlServer.Create('D:\db', 54720);
  if not Srv.Start(Err) then
    WriteLn('Sunucu başlatılamadı: ', Err);
end;

// İstemci bağlan / Client connect
var
  Cl: TVdbNetClient;
  R: TSqlResult;
begin
  Cl := TVdbNetClient.Create;
  try
    Cl.Connect('127.0.0.1', 54720);
    if Cl.Login('admin', 'admin123') then
    begin
      R := Cl.Exec('SELECT 1+1');
      WriteLn('Sonuç: ', R.Data[0][0]);
      Cl.Logout;
    end;
  finally
    Cl.Free;
  end;
end;
```

### EN: TCP SQL Server (R-12)
```pascal
uses VDbSqlServer, VDbClientNet;

// Start server
var
  Srv: TVdbSqlServer;
  Err: string;
begin
  Srv := TVdbSqlServer.Create('D:\db', 54720);
  if not Srv.Start(Err) then
    WriteLn('Server failed: ', Err);
end;

// Client connect
var
  Cl: TVdbNetClient;
  R: TSqlResult;
begin
  Cl := TVdbNetClient.Create;
  try
    Cl.Connect('127.0.0.1', 54720);
    if Cl.Login('admin', 'admin123') then
    begin
      R := Cl.Exec('SELECT 1+1');
      WriteLn('Result: ', R.Data[0][0]);
      Cl.Logout;
    end;
  finally
    Cl.Free;
  end;
end;
```

---

## 🔐 GÜVENLİK / SECURITY

### TR: Şifreleme (AES-256)
```sql
-- Parola belirle / Set password
ALTER DATABASE KEY 'gucluParola123';

-- Parola değiştir / Change password
ALTER DATABASE KEY 'yeniGucluParola456';
```

**Özellikler / Features:**
- ✅ AES-256 (FIPS-197) kayıt seviyesi şifreleme / record-level encryption
- ✅ Parola-türetmeli anahtar yönetimi / password-derived key management
- ✅ `.key` dosyası + `.bak` koruma / key file + backup protection
- ✅ WAL replay + şifreleme / WAL replay + encryption

### EN: Encryption (AES-256)
See above SQL examples. Features include AES-256 record-level encryption, password-derived key management, and `.key` file backup protection.

---

## 📊 SQL ÖZELLİKLERİ / SQL FEATURES

### TR: Desteklenen Özellikler (24 Ana Madde)
| Özellik | Durum |
|---|---|
| MVCC / Snapshot Isolation | ✅ |
| SAVEPOINT / Nested Transaction | ✅ |
| UPSERT (ON CONFLICT) | ✅ |
| RETURNING | ✅ |
| Trigger (BEFORE/AFTER/INSTEAD OF) | ✅ |
| View + Materialized View | ✅ |
| Stored Procedure / Function | ✅ |
| LATERAL JOIN | ✅ |
| WITH RECURSIVE + CYCLE | ✅ |
| DEFERRABLE Constraints | ✅ |
| Connection Pool + TCP SQL Sunucusu | ✅ |
| Table Partitioning (HASH/RANGE/LIST) | ✅ |
| Parallel Query Execution | ✅ |
| Cost-Based Optimizer (CBO) | ✅ |
| Incremental Backup / WAL Archiving | ✅ |
| Streaming Replication (TCP) | ✅ |
| RBAC / Role / GRANT | ✅ |
| Row Level Security (RLS) | ✅ |
| ICU Collation (tr, ru, de, ja, he, ar, zh) | ✅ |
| Extension / Plugin (DLL) | ✅ |
| Online DDL (CONCURRENTLY) | ✅ |
| Cross-Platform DLL / C API | ✅ |
| Monitoring / SHOW STATS | ✅ |

### EN: Supported Features (24 Major Items)
All 24 roadmap items (R-01 to R-24) are **completed and tested**. See `yol_haritasi.md` for detailed roadmap.

---

## 📈 VERİ TİPLERİ / DATA TYPES

### TR
| Tip | Açıklama |
|---|---|
| `INTEGER` | Tam sayı (AUTOINCREMENT destekli) |
| `FLOAT` | Ondalık sayı |
| `TEXT` | Metin (UTF-8, COLLATE destekli) |
| `BOOL` | Boolean (true/false) |
| `DATE` | Tarih (YYYY-MM-DD) |
| `DATETIME` | Tarih+saat |
| `TIME` | Saat |
| `BLOB` | İkili veri (fotoğraf, belge) |
| `JSONB` | JSON sorgulanabilir (`?`, `@>`, `->`) |
| `XML` | XML sorgulama (XPath) |
| `RANGE` | Aralık tipi (int, date, ts) |

### EN
Same types as above. See `SQL.md` for detailed syntax and examples.

---

## ⚡ PERFORMANS (v2.1) / PERFORMANCE (v2.1)

### TR: 1.000.000 Satır Ölçümleri (2026-10-15)

> v2.1, motorun iç okuma/yazma yollarını yeniden yazan performans sürümüdür. Ölçümler 1M satırlık tabloda (`id, ad, yas, bakiye, notu`) alınmıştır. **Dayanıklılık sözleşmesi değişmedi:** `SyncWriteInterval` varsayılanı 0 (grup commit isteğe bağlı); çökme testleri veri kaybı olmadan geçiyor.

| Sorgu / işlem (1M satır) | Önce | v2.1 | Kazanç |
|---|---|---|---|
| `SELECT COUNT(*) FROM musteri` | 3.200 ms | **800 ms** | **4x** — decode'suz ham sayım |
| `SELECT * FROM musteri` | 2.859 ms | **1.579 ms** | **1,8x** — ASCII hızlı yol + ham hash + ön-tahsis |
| `SELECT SUM(id) FROM musteri` | 8.766 ms | **2.265 ms** | **3,9x** — aggregate gating + sabit float ayarları |
| `WHERE id = -30792` (negatif PK) | 12.400 ms | **0 ms** | negatif-literal hat düzeltmesi |
| `WHERE id > 100` (999.900 satır) | 13.000 ms | **~5.000 ms** | **2,6x** — CBO istatistik-yok düzeltmesi |
| İlk indeks kullanımı (tembel kurulum) | 9–13 sn | **~4,3 sn** | **2–3x** — ön-parse quicksort |
| `ScanAll` (ham KV taraması) | 7.016 ms | **437 ms** | **16x** — offset-sıralı blok okuma (8 MB pencere) |
| `ScanRows` (çözümlü tarama) | 9.703 ms | **2.625 ms** | **3,7x** |
| `WHERE id = 524288` (PK noktası) | 0 ms | 0 ms | — |
| `WHERE id BETWEEN 100 AND 200` | 125 ms | 125 ms | PK tembel indeksi |
| 1M INSERT (BEGIN/COMMIT) | — | 55,84 sn (17.907/sn) | 118,9 MB ≈ 119 B/satır |

**Mikro ölçüler (v2.1):** `VDbParseInt` 78 ns/çağrı · `VDbParseFloat` 515 ns · `VDbFloatToStr` ~450 ns (önce ~800 ns) · STR kolon çözümleme 109 ns/kolon (önce ~300 ns).

**v2.1 içinde ne var:**
- ✅ `ScanSnapshot` yeniden yazımı — offset-sıralı blok okuma
- ✅ COUNT(*) ham yolu — satır çözmeden, yalnızca yapı+hash doğrulamasıyla sayım (bozuk satır tespiti birebir korunur)
- ✅ Aggregate gating — SUM artık MIN/MAX ve fazla parse yapmıyor
- ✅ `SortIdxEntries` ön-parse quicksort — indeks kurulumu ~10 sn → ~1 sn
- ✅ CBO düzeltmesi — istatistik yoksa satır sayısı yerine indeks uzunluğu (EXPLAIN metni aynı, karar noktası tek)
- ✅ Negatif-literal düzeltmesi — `id = -1` gibi sorgular 12,4 sn sürüyordu
- ✅ `DecodeRow` ASCII hızlı yolu + ham-bayt hash doğrulaması + ön-tahsis
- ✅ `VDbParseInt`/`VDbParseFloat`/`VDbCmpVal`/`VDbFloatToStr` tahsis azaltmaları
- ✅ Çökme dayanıklılığı test paketi (kill noktaları + transaction atomikliği)
- ✅ `bench1m.dpr` faz 2 Int64 taşma düzeltmesi

### EN: 1,000,000-Row Measurements (2026-10-15)

> v2.1 is a performance release that rewrites the engine's internal read/write paths. Numbers measured on a 1M-row table (`id, ad, yas, bakiye, notu`). **Durability contract unchanged:** `SyncWriteInterval` defaults to 0 (group commit optional); crash tests pass with zero data loss.

| Query / operation (1M rows) | Before | v2.1 | Gain |
|---|---|---|---|
| `SELECT COUNT(*) FROM musteri` | 3,200 ms | **800 ms** | **4x** — decode-free raw counting |
| `SELECT * FROM musteri` | 2,859 ms | **1,579 ms** | **1.8x** — ASCII fast path + raw hash + prealloc |
| `SELECT SUM(id) FROM musteri` | 8,766 ms | **2,265 ms** | **3.9x** — aggregate gating + static float settings |
| `WHERE id = -30792` (negative PK) | 12,400 ms | **0 ms** | negative-literal bug fix |
| `WHERE id > 100` (999,900 rows) | 13,000 ms | **~5,000 ms** | **2.6x** — CBO no-stats fix |
| First index use (lazy build) | 9–13 s | **~4.3 s** | **2–3x** — pre-parse quicksort |
| `ScanAll` (raw KV scan) | 7,016 ms | **437 ms** | **16x** — offset-ordered block reads (8 MB window) |
| `ScanRows` (decoded scan) | 9,703 ms | **2,625 ms** | **3.7x** |
| `WHERE id = 524288` (PK point) | 0 ms | 0 ms | — |
| `WHERE id BETWEEN 100 AND 200` | 125 ms | 125 ms | PK lazy index |
| 1M INSERT (BEGIN/COMMIT) | — | 55.84 s (17,907/s) | 118.9 MB ≈ 119 B/row |

**Micro (v2.1):** `VDbParseInt` 78 ns/call · `VDbParseFloat` 515 ns · `VDbFloatToStr` ~450 ns (was ~800 ns) · STR column decoding 109 ns/column (was ~300 ns).

Every v2.1 change preserves behavior — the SQL suite (2251/2251) and the crash-durability suite (kill at arbitrary points, single-commit and mid-batch transactions) pass.

### ⚖️ Adil kıyas: SQLite ile aynı makinede / Fair comparison vs SQLite (v2.1 final)

> **TR:** Aynı SQL metni, aynı veri üretimi, aynı disk (C:\temp), tek süreç,
> iki motor da **stok varsayılanlarla**: VDB `SyncWriteInterval=0` (senkron
> commit), SQLite `synchronous=FULL` + journal DELETE (resmî sqlite.org
> 3.54.0 32-bit DLL). Ölçüm QueryPerformanceCounter.
> **EN:** Same SQL text, same data, same disk, one process, both engines on
> **stock defaults**: VDB synchronous commits, SQLite FULL + journal DELETE.

| Aşama / Phase (1M satır) | VDB | SQLite | VDB/SQLite |
|---|---|---|---|
| `INSERT` 1M (BEGIN/COMMIT) | 24,1 s | 3,12 s | 7,7x |
| `SELECT COUNT(*)` x10 ort. | 713 ms | 37 ms | 19,5x |
| `SELECT SUM(bakiye)` x5 ort. | 722 ms | 82 ms | 8,8x |
| PK nokta araması 50.000x | **1,42 s** | 3,04 s | **0,47x — VDB 2,1x önde** |
| `BETWEEN` 2.000×100 satır | 3,12 s | 211 ms | 14,8x |
| `UPDATE` 100k (tx) | 4,25 s | 270 ms | 15,8x |
| `DELETE` 100k (tx) | 2,92 s | 196 ms | 14,9x |

Hız kampanyası (P-12…P-21) başlangıcına göre İYİLEŞME — **veri kaybı yok**:
sqltest 2251/2251 ve 8'li çökme zinciri 8/8 her adımda yeşil kaldı.
Kampanya başı: INSERT 16,1x, COUNT 26,8x, BETWEEN ~35x. (`vsbench_run9.log`)
Campaign start → final: INSERT 16.1x→7.7x, COUNT 26.8x→19.5x,
BETWEEN ~35x→14.8x, PK point 0.59x→**0.47x (VDB ahead)** — with zero data
loss (2251/2251 SQL tests + 8/8 crash chain green at every step).

---

## 🧪 TEST SONUÇLARI / TEST RESULTS

### TR: Mevcut Durum (2026-10-15)
```
sqltest:      2251/2251  (tümü yeşil)
crashtest:    8/8        (çökme dayanıklılığı — veri kaybı YOK)
vdbcrypttest:   60/60
vdbapitest:    170/170
vdbclienttest: 101/101
```

**R-12 Tamamlandı:**
- ✅ Auth/Oturum (`Login`/`Logout`)
- ✅ Prepared Statement (`Prepare`/`ExecutePrepared`)
- ✅ Havuz-Kapasite (`FMaxConns=4`)
- ✅ Mutasyon: 3 kapı (FAIL→geri al→yeşil)

### EN: Current Status (2026-10-15)
sqltest **2251/2251 (all green)**, crash-durability suite **8/8** (kill at arbitrary points, zero data loss), plus crypt (60/60), DLL API (170/170) and client (101/101) suites green. All R-12 features (Auth, Prepared Statements, Pool Capacity) are complete and mutation-tested.

---

## 🔧 DLL API (57 EXPORT)

### TR: Delphi/Lazarus Kullanımı
```pascal
// vdbapi.dll veya vdbapi.so kullan
function VdbOpen(const DbPath: PAnsiChar): Integer; stdcall;
function VdbExec(const Sql: PAnsiChar; var ResultHandle: Integer): Integer; stdcall;
function VdbGet(ResHandle, Row, Col: Integer; Buf: PAnsiChar; BufLen: Integer): Integer; stdcall;
procedure VdbClose(DbHandle: Integer); stdcall;
```

**57 export fonksiyon** — detaylar `docs/03-API-DLL.md` ve `DLL_KULLANIM.md`.

### EN: Delphi/Lazarus Usage
See above. 57 exported functions for C/Delphi/FPC interop. Full list in `docs/03-API-DLL.md`.

---

## 📚 DOKÜMANTASYON / DOCUMENTATION

### TR: Ana Dosyalar
| Dosya | İçerik |
|---|---|
| `README.md` | Bu dosya — genel bakış + kullanım |
| `SQL.md` | SQL referansı (tüm komutlar) |
| `yol_haritasi.md` | Yol haritası (R-01 → R-24, tümü bitti) |
| `docs/01-MOTOR.md` | Motor birimleri |
| `docs/02-DOSYA-FORMATI.md` | `.odb` / `.wal` dosya formatı |
| `docs/03-API-DLL.md` | DLL API (57 export) |
| `docs/04-VERITABANI-DOSYALARI.md` | Veritabanı dosyaları |
| `DLL_KULLANIM.md` | DLL kullanım kılavuzu |
| `SIFRELEME_PLANI.md` | Şifreleme planı (AES-256) |
| `TEST_RAPORU_sqltest_vs_yol_haritasi.md` | Test raporu |

### EN: Main Files
| File | Content |
|---|---|
| `README.md` | This file — overview + usage |
| `SQL.md` | SQL reference (all commands) |
| `yol_haritasi.md` | Roadmap (R-01 → R-24, all complete) |
| `docs/01-MOTOR.md` | Engine units |
| `docs/02-DOSYA-FORMATI.md` | `.odb` / `.wal` file format |
| `docs/03-API-DLL.md` | DLL API (57 exports) |
| `docs/04-VERITABANI-DOSYALARI.md` | Database files |
| `DLL_KULLANIM.md` | DLL usage guide |
| `SIFRELEME_PLANI.md` | Encryption plan (AES-256) |
| `TEST_RAPORU_sqltest_vs_yol_haritasi.md` | Test report |

---

## 📋 YAPILAN İŞLER (CHANGELOG) / WORK COMPLETED

### TR: v2.1 — Performans Sürümü (2026-10-15)
- ✅ 1M satırda COUNT(*) **4x**, SUM **3,9x**, ScanAll **16x** hızlandırma (ölçümler yukarıda)
- ✅ Negatif-literal hat düzeltmesi — `WHERE id = -1` 12,4 sn → **0 ms**
- ✅ CBO istatistik-yok daraltma düzeltmesi — `WHERE id > 100` 13 sn → **~5 sn**
- ✅ Çökme dayanıklılığı test paketi eklendi (8/8 — veri kaybı yok, transaction atomikliği korunuyor)
- ✅ Dayanıklılık sözleşmesi korundu (`SyncWriteInterval` varsayılanı 0)
- ✅ `bench1m.dpr` faz 2 Int64 taşma düzeltmesi
- ✅ Tüm testler yeşil: sqltest **2251/2251**

### EN: v2.1 — Performance Release (2026-10-15)
- ✅ At 1M rows: COUNT(*) **4x**, SUM **3.9x**, ScanAll **16x** faster (measurements above)
- ✅ Negative-literal fix — `WHERE id = -1`: 12.4 s → **0 ms**
- ✅ CBO no-stats narrowing fix — `WHERE id > 100`: 13 s → **~5 s**
- ✅ Crash-durability suite added (8/8 — zero data loss, transaction atomicity preserved)
- ✅ Durability contract preserved (`SyncWriteInterval` default 0)
- ✅ `bench1m.dpr` phase 2 Int64 overflow fix
- ✅ All tests green: sqltest **2251/2251**

### TR: Tüm Yol Haritası Tamamlandı (R-01 → R-24)

**FAZ 0 — Temel Veri Bütünlüğü:**
- ✅ R-01: MVCC / Snapshot Isolation
- ✅ R-02: SAVEPOINT / Nested Transaction
- ✅ R-03: UPSERT (ON CONFLICT)
- ✅ R-04: RETURNING

**FAZ 1 — SQL Standartları:**
- ✅ R-05: Trigger (BEFORE/AFTER/INSTEAD OF)
- ✅ R-06: View (gerçek, DML destekli)
- ✅ R-07: Materialized View + REFRESH
- ✅ R-08: Stored Procedure / Function (PL/pgSQL alt kümesi)
- ✅ R-09: LATERAL JOIN
- ✅ R-10: CYCLE Detection (Recursive CTE)
- ✅ R-11: DEFERRABLE Constraints

**FAZ 2 — Ölçeklenebilirlik:**
- ✅ R-12: Connection Pool + TCP SQL Sunucusu (VDBS protokolü)
- ✅ R-13: Table Partitioning (HASH/RANGE/LIST)
- ✅ R-14: Parallel Query Execution (TThread worker pool)
- ✅ R-15: Cost-Based Optimizer (ANALYZE + maliyet modeli)
- ✅ R-16: Incremental Backup / WAL Archiving (PITR)
- ✅ R-17: Streaming Replication (WAL log-shipping + TCP)

**FAZ 3 — Platform & Güvenlik:**
- ✅ R-18: RBAC / Role / GRANT
- ✅ R-19: Row Level Security (RLS)
- ✅ R-20: ICU Collation (tr, ru, de, ja, he, ar, zh)
- ✅ R-21: Extension / Plugin (DLL yükleme)
- ✅ R-22: Online DDL (CONCURRENTLY)
- ✅ R-23: Cross-Platform DLL / C API (57 export)
- ✅ R-24: Monitoring / SHOW STATS

**Ek Özellikler (F-xx):**
- ✅ ILIKE, ANY/SOME/ALL, FETCH FIRST, NULLS FIRST/LAST
- ✅ QUALIFY, COUNT/SUM/AVG(DISTINCT), STRING_AGG
- ✅ PERCENTILE_CONT/DISC, FILTER (WHERE ...)
- ✅ EXPLAIN / EXPLAIN ANALYZE
- ✅ PARTIAL INDEX, EXPRESSION INDEX, COVERING INDEX (INCLUDE)
- ✅ Yavaş Sorgu Tespiti (SHOW SLOW QUERIES)
- ✅ JSONB sorgulama (`?`, `@>`, `->`)
- ✅ XML (XPath)
- ✅ SPATIAL (Point, Polygon)
- ✅ RANGE tipi (int, date, ts)
- ✅ NATURAL JOIN, USING

### EN: Full Roadmap Completed (R-01 → R-24)
All 24 roadmap items plus 20+ additional features (F-xx series) are **implemented, tested, and documented**. See `yol_haritasi.md` for detailed status and `SQL.md` for syntax reference.

---

## 🛠️ DERLEME / BUILD

### TR
```bash
# Test paketi / Test suite
lazbuild -B sqltest.lpi

# DLL API / DLL API
lazbuild -B vdbapi.lpi

# Sunucu / Server
lazbuild -B vdbserver.lpi

# GUI yönetici / GUI admin (yonetim/)
lazbuild -B yonetim/had.lpi

# Linux/macOS kütüphane / library
./build_lib.sh
```

### EN
```bash
# Test suite
lazbuild -B sqltest.lpi

# DLL API
lazbuild -B vdbapi.lpi

# Server
lazbuild -B vdbserver.lpi

# GUI admin (yonetim/)
lazbuild -B yonetim/had.lpi

# Linux/macOS library
./build_lib.sh
```

**Gereksinimler / Requirements:**
- Lazarus 4.6+ (Free Pascal 3.2.4)
- DCPcrypt (şifreleme / encryption) — `dcpcrypt/` klasöründe
- Windows: `lazbuild` (Lazarus IDE ile gelir)
- Linux/macOS: `fpc` + `lazbuild`

---

## 📞 DESTEK / SUPPORT

### TR
- Sorunlar için: GitHub Issues
- SQL referansı: `SQL.md`
- Yol haritası: `yol_haritasi.md`
- Testler: `sqltest.exe` çalıştırın

### EN
- For issues: GitHub Issues
- SQL reference: `SQL.md`
- Roadmap: `yol_haritasi.md`
- Tests: Run `sqltest.exe`

---

## 📄 LİSANS / LICENSE

### TR
Bu proje açık kaynak olarak yayınlanmıştır. Detaylar için `LICENSE` dosyasına bakın.

### EN
This project is open source. See `LICENSE` file for details.

---

**Son güncelleme / Last updated:** 2026-10-15
**Sürüm / Version:** 2.1 — Performans Sürümü / Performance Release (COUNT(*) 4x, SUM 3,9x, ScanAll 16x @ 1M satır; veri kaybı yok / zero data loss)