# VDB vs Modern RDBMS — Karşılaştırma ve Yol Haritası

## 1. Modern RDBMS Karşılaştırma Tablosu

| Özellik / Konsept | VDB durumu | Modern RDBMS (PostgreSQL / MySQL / SQLite) | Açıklama / Eksiklik |
|------------------|------------|-----------------------------|----------------------|
| **SQL sözdizimi kapsamı** | Temel DML/DDL: SELECT, INSERT, UPDATE, DELETE, CREATE TABLE, CREATE INDEX, CREATE DATABASE, ALTER TABLE (sütun işlemleri), DROP, BEGIN/COMMIT/ROLLBACK. WITH (CTE, RECURSIVE, kolon alias'ı), window functions (OVER), UNION/EXCEPT/INTERSECT, LIMIT/OFFSET, GROUP BY, HAVING, aggregate fonksiyonları. | ANSI‑SQL‑92/99/2003/2011/2016 tam veya büyük bir kısmı. Desteklenen ifadeler: CASE, NULLIF, COALESCE, EXISTS, IN, ANY/SOME/ALL, LATERAL, TABLESAMPLE, FETCH FIRST…, OFFSET … ROWS, WINDOW (tam frame), QUALIFY, MATCH_RECOGNIZE, PIVOT/UNPIVOT, TABLE value constructors, VALUES list, CTE materialization, RETURNING, UPSERT (ON CONFLICT/MERGE), TRUNCATE. | VDB sözdizimi temel CRUD ve temel sorgulamalar için yeterli; modern özelliklerin çoğu (CASE, EXISTS, LATERAL, gelişmiş JOIN türleri, tablo değeri constructors, RETURNING, UPSERT, gelişmiş window frame, QUALIFY, MATCH_RECOGNIZE) yok veya sınırlı. |
| **JOIN tipleri** | INNER, LEFT, RIGHT, FULL, CROSS (opsiyonel ON). USING yok, NATURAL yok. | INNER, LEFT, RIGHT, FULL, CROSS, NATURAL, USING, LATERAL (PostgreSQL/MySQL 8.0+), SEMI/ANTI (via EXISTS/NOT EXISTS). | VDB, USING ve NATURAL desteklemiyor; LATERAL JOIN (tablo‑fonksiyonlarıyla kullanım) yok. |
| **WHERE / FILTER** | Basit karşılaştırmalar (=, <>, <, >, <=, >=), LIKE, IS NULL, IN (liste), BETWEEN. | Ayrıca REGEXP/SIMILAR TO, ILIKE, DISTINCT FROM, JSONB @>, ARRAY @>, RANGE operatörleri, NULLS FIRST/LAST sıralama, FILTER (WHERE …) agregat içinde. | VDB’de regexp, ilike, json/array containment, NULLS FIRST/LAST sıralama yok. |
| **Aggregat fonksiyonları** | COUNT, SUM, AVG, MIN, MAX. COUNT(*), COUNT(DISTINCT …). | COUNT, SUM, AVG, MIN, MAX, STDDEV, VARIANCE, PERCENTILE_CONT, PERCENTILE_DISC, MODE, ARRAY_AGG, STRING_AGG, JSONB_AGG, XMLAGG, GEOMETRY_COLLECT, BOOL_OR/AND, EVERY, LISTAGG (Oracle/Postgres), APPROX_COUNT_DISTINCT, HISTOGRAM. | VDB’de sadece temel 5 agregat var; istatistik, dizi/json/aggregate, approxı́m count_distinct, window‑specific agregatlar eksik. |
| **HAVING** | Basit HAVING aggregate … (tek aggregate). | Karmaşık HAVING ifadeleri (multiple aggregates, CASE, EXISTS, alt‑soruğular). | VDB’de HAVING içinde yalnız tek bir aggregate kullanılabiliyor; karmaşık ifadeler desteklenmiyor. |
| **Window functions** | ROW_NUMBER(), RANK(), DENSE_RANK(), LAG(), LEAD(), COUNT(), SUM(), AVG(), MIN(), MAX() OVER (PARTITION BY … ORDER BY …). Frame (ROWS/RANGE) sadece parser‑seviyesinde; hesaplama sadece UNBOUNDED PRECEDING → CURRENT ROW (basit birikim). | Tam FRAME Clause (ROWS BETWEEN … AND …, RANGE BETWEEN … AND …, EXCLUDE CURRENT ROW, EXCLUDE GROUP, EXCLUDE TIES, EXCLUDE NO OTHERS). GENERATED … AS IDENTITY, WINDOW tanımları, QUALIFY. | VDB window implementasyonu çok temel; tam frame, excluded clauses, window tanımları, QUALIFY yok. |
| **CTE (WITH)** | WITH (non‑recursive) ve WITH RECURSIVE. maxIter=3 ile sınırlı iterasyon. Kolon alias’ları (WITH t(a,b) AS …) kısmi destek. INSERT/UPDATE/DELETE içi CTE parser‑seviyesinde aktif (son sürümde WithQueries eklendi). | Tam rekürsif derinlik kontrolü (maxrecursive veya search depth first/bycle), CYCLE detection, materialized vs not materialized, INSERT/UPDATE/DELETE içinde CTE tam destek, UPSERT içinde CTE, REFRESH MATERIALIZED VIEW. | VDB derinlik sınırı sabit (3) ve CYCLE algısı yok; tam materialization kontrolü eksik. |
| **Subqueries** | Scalar subquery (SELECT … tek değer) ve EXISTS/NOT EXISTS (ilişkisiz). İlişkili (correlated) subquery sınırlı: WHERE EXISTS (SELECT … FROM t2 WHERE t2.x = t1.x) çalışır; daha derin/negatif ilişkili sorgular (NOT EXISTS ile AND/OR kombinasyonları) ecUnsupported olabilir. | Tam iliškili subquery desteği (SELECT, INSERT, UPDATE, DELETE içinde), ANY/SOME/ALL, LATERAL (subquery gibi kullanım), TABLE fonksiyonu, FROM (SELECT …) AS alias. | VDB ilişkili subquery sadece temel EXISTS/IN seviyesinde; karmaşık ilişkili/negatif/LATERAL kullanımları desteklenmiyor. |
| **Views** | CREATE VIEW parser‑seviyesinde accepteur; çalıştırıcı (yürütücü) yok → sadece sözdizimi kabul, gerçek view objesi oluşturulmaz. | Gerçek view objesi, materialized view, güvenlik barbiri (security barrier view), rekursif view, WITH CHECK OPTION, INSERT/UPDATE/DELETE üzerinden view üzerinden değişiklik. | VDB sadece sözdizimi kabul; view üzerinden veri manipülasyonu, güvenlik, materialized view yok. |
| **Stored procedures / functions** | Yok. | CREATE PROCEDURE, CREATE FUNCTION, LANGUAGE SQL/PLpgSQL/PLPerl/PLPython, RETURN, OUT/INOUT parametreleri, exception handling, VOLATILE/STABLE/IMMUTABLE, SET fonksiyonları. | VDB prosedür/fonksiyon desteği yok; sadece anonim SQL blokları. |
| **Triggers** | Yok. | BEFORE/AFTER/INSTEAD OF triggers, FOR EACH ROW/STATEMENT, WHEN koşulu, REFERENCING OLD/NEW AS, TRIGGER üzerinden audit, dinamik tablo değişikliği. | VDB trigger mekanizması yok. |
| **Constraints** | NOT NULL, UNIQUE, PRIMARY KEY, DEFAULT, CHECK (sadece sözdizimi, yürütücüde uygulanır), REFERENCES (syntax) – FK zorunlu çalıştırılamıyor (sadece syntax). ALTER TABLE … ADD/DROP CONSTRAINT parser‑seviyesinde açık, yürütücüde sadece syntax kontrolü, veri yeniden kodlanmaz. | Tam FK zorunluluğu (ON DELETE/UPDATE aksiyonları), deferrable constraints, constraint exception handling, EXCLUDE constraint (gist), UNIQUE/PRIMARY KEY indis crétion, CHECK tablosu‑seviyesinde, ASSERTION (SQL‑99), DEFERRABLE INITIALLY DEFERRED. | VDB FK ve CHECK sadece syntax; yürütücüde veri bütünlüğü zorunlu değil (yalnızca sema kontrolü). |
| **Indexes** | Sadece Basit B‑tree‑türü (varmış gibi). CREATE INDEX, CREATE UNIQUE INDEX, ON DELETE/UPDATE yok. WHERE koşullu index yok, INCLUDE yok, COMMENT yok, CONCURRENTLY yok. | B‑tree, Hash, GiST, SP‑GiST, GIN, BRIN, Bloom, Covering, partial index (WHERE), expression index, index only scan, parallel index build, concurrent index create, partition‑wise indexes. | VDB yalnız tek tip index; modern indeks türleri, partial, covering, expression, concurrent build yok. |
| **Transactions** | Basit BEGIN/COMMIT/ROLLBACK. Otomatik tek‑fsync batch (varsayılan). SAVEPOINT yok, ISOLATION LEVEL yok (varsayılan serializable gibi davranır ama kesin garantisi yok). | BEGIN WORK, START TRANSACTION, COMMIT, ROLLBACK, SAVEPOINT, RELEASE SAVEPOINT, ISOLATION LEVEL (READ COMMITTED, REPEATABLE READ, SERIALIZABLE, READ UNCOMMITTED (PostgreSQL)), DEFERRABLE, two‑phase commit, prepare transaction, autonomous transaction (Oracle), LOCK TABLE. | VDB SAVEPOINT, izolasyon seviyeleri ve kilitleme seçenekleri eksik. |
| **Concurrency control** | Tek process/tek bağlantı modeli kilitli (TCriticalSection). Çoklu eşzamanlı yazıcılar için kilitleme yok (tek işlem bağzı). | MVCC (PostgreSQL, MySQL InnoDB), lock‑based (MyISAM), optimistic/pessimistic locking, deadlock detection, lock timeout, SELECT … FOR UPDATE/SKIP LOCKED/NOWAIT. | VDB gerçek çoklu kullanıcı senaryosu için kilitleme/lock mekanizması yok; sadece tek‑işlem modeli. |
| **Write‑Ahead Log (WAL) / Crash recovery** | WAL var (VDbWal.pas); WriteAheadWAL sadece Elle WALEnabled = True ile aktif; otomatik WAL yok; CheckpointWAL, ReplayWAL. AS OF SEQUENCE (WAL okuma) desteklenir; AS OF TIMESTAMP/VERSION reddedilir. | Tam WAL (PostgreSQL), redo log (MySQL InnoDB), checkpoint, archive recovery, point‑in‑time recovery (PITR), logical replication, streaming replica, slot‑based logical decoding. | VDB WAL temel seviye; arşivleme, mantıklı replikasyon, PITR, replikasyon slotları yok. |
| **Change Data Capture (CDC) / Time Travel** | VDbCdc.pas ile basit WAL‑tabanlı INSERT/UPDATE/DELETE yakalama; VDbTimeTravel.pas ile AS OF SEQUENCE <n> (sadece secuencia bazlı). AS OF TIMESTAMP/VERSION reddedilir. | pg_logical_slot, pgoutput, Debezium, MySQL binlog, Oracle Flashback Query, Temporal Tables (system‑versioned), AS OF TIMESTAMP, PERIOD FOR SYSTEM_TIME. | VDB CDC çok temel; zaman dilimi sorgusu sadece sequence‑bazlı; timestamp/version sorgusu yok. |
| **Replication / High Availability** | Yok (tek‑dosya, tek‑process). | Streaming replica, logical replica, multi‑master, synchronous/asynchronous, failover, pgpool, Galera cluster (MySQL), Always On (SQL Server). | VDB replikasyon/HA mekanizması yok. |
| **Partitioning** | Yok. | PARTITION BY RANGE/LIST/HASH, declarative partitioning, partition pruning, partition‑wise join/update. | VDB partition desteği yok. |
| **Full‑text search** | Yok. | tsvector/tsquery (PostgreSQL), FULLTEXT (MySQL/MariaDB), ngram parser (SQLite FTS5). | VDB full‑text arama yok. |
| **Geographic / Spatial data** | Yok. | PostGIS (PostgreSQL), MySQL Spatial Extensions, SQLite SpatiaLite. | VDB spatial veri tipi yok. |
| **JSON / XML** | Sadece EXPORT JSON / IMPORT JSON (ham dosya). JSONB tipi, @>, ? , jsonb_build_object, jsonb_agg yok. XML tipi yok. | JSONB, JSONPATH, XMLTYPE, xmlelement, xmlforest, xmlagg, JSON_TABLE. | VDB sadece basit JSON export/import; sorgulama/değiştirme yok. |
| **Role‑Based Access Control (RBAC)** | Yok (tek kullanıcı modeli). | CREATE ROLE, GRANT/REVOKE, INHERIT, SET ROLE, RLS (Row Level Security), COLUMN LEVEL SECURITY, PROXY USERS. | VDB yetkilendirme/rol sistemi yok. |
| **Online schema changes** | ALTER TABLE sadece temel sütun işlemleri (ADD/DROP/RENAME/ALTER COLUMN); veri yeniden kodlanmaz; sadece syntax kontrolü. | ALTER TABLE … ADD COLUMN (aynı zamanda bakiye), ALTER TABLE … SET DATA TYPE (tabloları yeniden yapılandırmadan), ALTER TABLE … SET NOT NULL (VALIDATE/NOT VALIDATE), CONCURRENTLY index oluşturma, zero‑downtime migration. | VDB online DDL yok; bloklayıcı işlemler. |
| **Backup / PITR** | Manuel dosya kopyalama (.odb). BACKUP TO 'file.odb'. VERIFY sadece checksum. | pg_basebackup, pg_dump/pg_restore, PITR (WAL archiving), incremental backup, snapshot‑based backup (ZFS/LVM), cloud‑native snapshots. | VDB yedekleme sadece dosya kopyalama; WAL‑tabanlı incremental/yedekleme yok. |
| **Monitoring / Diagnostic** | Basit sayaçlar (WalRecordCount, WalAutoCount). EXPLAIN yok. | EXPLAIN (ANALYZE, BUFFERS, VERBOSE), pg_stat_*, pg_progress_*, log_min_duration_statement, auto_explain, pg_stat_statements, pgBadger, Prometheus exporter. | VDB performans izleme, sorgulama planı görünümü, yavaş sorgu tespiti yok. |
| **Extensions / Plug‑ins** | Yok. | CREATE EXTENSION (PostgreSQL), INSTALL PLUGIN (MySQL), LOADABLE FUNCTIONS (SQLite). | VDB dış modül/ekleme mekanizması yok. |
| **Character set / Collation** | UTF‑8 depolama. COLLATE TR sadece Türkçe sıralaması. UTF8Encode/Utf8Length/VDbCompareTr (Türkçe) mevcut. Diğer diller için varsayılan byte sırası. | CHARACTER SET utf8mb4, COLLATE utf8mb4_unicode_ci, utf8mb4_ja_0900_as_cs, utf8mb4_ja_0900_as_cs_ks, utf8mb4_zh_0900_as_cs, utf8mb4_zh_0900_as_cs, lt_COLLATE (ICU), language‑specific collations, case‑insensitive/accent‑insensitive, _ks (kana sensitive). | VDB sadece UTF‑8 ve tek özel collation (TR). Geniş Unicode collation desteği yok. |

## 2. Uygulama Önceliği (Roadmap)

### 2.1. Kritik Veri Bütünlüğü (Sıfır)
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| M-01 | CHECK constraint yürütücüde aktif | En yüksek | ✅ ZATEN VAR (2026-10-07 dogrulandi: `VDbCheckOK` INSERT/UPDATE'te; 6 test) |
| M-02 | REFERENCES / FOREIGN KEY yürütücüde aktif | En yüksek | ✅ ZATEN VAR (2026-10-07 dogrulandi: `CheckFk` + RESTRICT/CASCADE + ON UPDATE; 10 test) |
| M-03 | NOT NULL yürütücüde aktif | Yüksek | ✅ ZATEN VAR (`CheckConstraints`; 5 test) |
| M-04 | UNIQUE yürütücüde aktif (indeks kontrolü) | Yüksek | ✅ ZATEN VAR (indiks tabanli; 4 test) |

### 2.2. SQL Sözdizimi Genişletme (Birinci Basamak)
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-01 | CASE … WHEN … THEN … ELSE … END | En yüksek | ✅ BITTI (zaten mevcut: `TSqlCaseNode` + `ParseCase` + `EvalExpr`; 7 test) |
| F-02 | NULLIF / COALESCE | Yüksek | ✅ BITTI (2026-10-07; `TSqlNullIfNode`/`TSqlCoalesceNode` + 10 test) |
| F-03 | EXISTS / NOT EXISTS ilişkili alt sorgu (tam destek) | Yüksek | ✅ BITTI (2026-10-07; `FOuterRow`/`FCurQualifier` + `IsCorrelatedSel` + 5 test, 2 mutasyon) |
| F-04 | IN listesi genişletme (nested, set operator) | Orta | ✅ ZATEN VAR (coklu degerli IN + UNION ALL + INTERSECT/EXCEPT; 8 test) |
| F-05 | ILIKE (case-insensitive LIKE) | Orta | ✅ BITTI (2026-10-07; `sboILike` + `VDbTrLower`; 7 test, 1 mutasyon 5 FAIL) |
| F-06 | ANY/SOME/ALL subquery | Orta | ✅ BITTI (2026-10-07; `TSqlQuantNode` + `qkAny`/`qkAll`; 11 test, 1 mutasyon 3 FAIL) |
| F-07 | UNION ALL, INTERSECT, EXCEPT tam (duplicates handling) | Orta | ✅ ZATEN VAR (`sokUnionAll`; 3 test) |
| F-08 | LIMIT ile OFFSET/FETCH FIRST | Orta | ✅ BITTI (2026-10-07; `FETCH FIRST/NEXT n ROW(S) ONLY` + `OFFSET n ROWS`; 9 test) |
| F-09 | QUALIFY (window after aggregation) | Düşük | ✅ BITTI (2026-10-07; `EvalQualify` + `ApplyQualify` + `IsSameExpr` pencere esleşmesi; 7 test, 1 mutasyon 4 FAIL) |
| F-10 | NULLS FIRST/LAST sıralama | Düşük | ✅ BITTI (2026-10-07; `TOrderItem.NullsPos` + `CompareRowIdx` NULL dalı; 2 mutasyon 1+3 FAIL) |

### 2.3. Fonksiyon ve Aggregate Genişletme
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-11 | COUNT(DISTINCT …) yürütme | Yüksek | ✅ BITTI (2026-10-07; `EvalAggregateValue` `seen` hash kova + `IsStar` yolu; 11 test) |
| F-12 | COUNT(*) vs COUNT(kolon) ayrımı | Yüksek | ✅ ZATEN VAR (`IsStar` bayragi; 3 test) |
| F-13 | AVG/SUM ile NULL handling | Yüksek | ✅ ZATEN VAR (`colVal = ''` → `Continue`; mevcut testler) |
| F-14 | STRING_AGG / ARRAY_AGG | Orta | ✅ BITTI (2026-10-07; `TSqlAggNode.akStringAgg` + `ParseFuncCall` + `EvalAggNode`; 8 test, 1 mutasyon 1 FAIL) |
| F-15 | PERCENTILE_CONT / PERCENTILE_DISC | Düşük | ✅ BITTI (2026-10-07; `WITHIN GROUP` parser + lineer enterpolasyon; 9 test) |
| F-16 | FILTER (WHERE …) agregat içinde | Düşük | ✅ BITTI (2026-10-07; `TSqlFuncCallNode.Filter` + parser + `EvalAggregateValue`; 13 test, 1 mutasyon 7 FAIL) |

### 2.4. Index ve Performans
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-17 | partial index (WHERE koşulu) | Orta | ✅ BITTI (2026-10-07; `TIdxDef.Predicate` + `ExprToText`/`VDbPredOK` + `IdxKeyPos` ayrı adresleme + `SHOW INDEXES.predicate/nentries`; **gerçek hata bulundu**: UPDATE partial indeksi yeniden değerlendirmiyordu; 28 test, 3 mutasyon: 3 + 1 + 8 FAIL) |
| F-18 | expression index | Orta | ✅ BITTI (2026-10-07; `TIdxDef.ExprText` + `VDbExprVal` mini-değerlendirici + `IdxKeyOfRow`/`IdxCtypeOfPos` + şema `:@ifade`; **eksik özellik bulundu**: `UNIQUE` ifade indeksi hiç zorlanmıyordu; 45 test, 3 mutasyon: 9 + 6 + 3 FAIL) |
| F-19 | covering index (INCLUDE) | Düşük | ✅ BITTI (2026-10-07; `TIdxDef.Incl` + `TIdxEntry.Cov` + `ReadRowCovered`/`IdxCoversAll` ile **index-only scan** + `EXPLAIN Index Only Scan`; **gerçek hata bulundu**: `UPDATE` `INCLUDE` kolonunu yenilemiyordu; 41 test, 3 mutasyon: 1 + 1 + **11** FAIL) |
| F-20 | EXPLAIN / sorgu planı görünümü | Orta | ✅ BITTI (2026-10-07; `TSqlExplainStmt` + `ExecExplain` + `HasPkLookup`/`IndexUsedByWhere`; 14 test, 1 mutasyon 2 FAIL) |
| F-21 | Yavaş sorgu tespiti | Düşük | ✅ BITTI (2026-10-07; `TVSql` halka tampon log + `SET SLOW_QUERY_MS` / `SHOW SLOW QUERIES` + `{$IFDEF MSWINDOWS}` zamanlayıcı; **gerçek hata bulundu**: halka imleci `FSlow[Count]` -> `Argument out of range`; **zayıflık bulundu**: `Now` 15.6 ms granülarite -> `GetTickCount64`; 27 test, 3 mutasyon: 2 + 2 + 2 FAIL) |

### 2.5. Gelişmiş Veri Tipleri
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-22 | JSONB / JSON sorgulama (@>, ? ) | Yüksek | ✅ BITTI (2026-10-07; `VDbJson` ayrıştırıcı + `@>` `<@` `?` `?\|` `?&`; `?` ile parametre yer tutucusu çakışması çözüldü; **gerçek hata**: iç içe `@>` eşitlik yerine *içerme* kullanmıyordu; **güvenlik**: `FParams[FParamIdx]` sınır kontrolsuz → AV; 47 test, 3 mutasyon: 3 + 1 + 1 FAIL) |
| F-23 | XML tipi | Düşük | ✅ BITTI (2026-10-07; `VDbXml.pas` — ayrıştırıcı + yol motoru + kurma; `XMLELEMENT`/`XMLCONCAT`/`XMLESCAPE`/`XMLPARSE`/`XMLEXTract`/`XMLEXISTS`/`XMLCOUNT`/`XMLATTR`; **4 gerçek hata bulundu**: iki kök tanınmıyordu, nitelik değeri off-by-one, `[n]` konum mantığı yanlış, CDATA/yorum metni kayboluyordu; 45 test, 3 mutasyon: 1 + 2 + 1 FAIL) |
| F-24 | Spatial/geographic veri | Düşük | ✅ BITTI (2026-10-08; `VDbSpatial.pas` — `DISTANCE`/`HAVERSINE`/`IN_CIRCLE`/`IN_BOX`/`IN_POLYGON`/`POINT_IN_POLYGON`/`AREA_POLYGON` + `ROUND`; **5 gerçek hata bulundu**: (1) uzamsal fonksiyonlar sistem yerel ayarına bağlı `TryStrToFloat` kullanıyordu → Türkçe locale'de `'1.5'` parse edilemiyor, tüm `IN_*` testleri 0 dönüyordu; (2) `ROUND` parser'da değişken-argümanlı listede yoktu → `fn.Args` nil, `fn.Args.Count` → **Access violation**; (3) `AggFuncCtype` yalnız HAVING yolunda (`FAggIdx <> nil`) çağrılıyordu → WHERE'de `DISTANCE(...) <= 5` **metin** karşılaştırması oluyor, `'14.14' <= '5'` → `TRUE`, uzak satırlar filtreye giriyordu; (4) `VDbParsePoint` de aynı locale hatasını taşıyordu (polygon); (5) Haversine `a` yarıçapı clamp edilmemişti; 43 test, 3 mutasyon: 2 + 5 + 1 FAIL) |
| F-25 | range/types | Düşük | ✅ BITTI (2026-10-08; `VDbRange.pas` — `TRangeBound` + `&&` `<<` `>>` `&<` `&>` `@>` `<@` `-|-` operatörleri + `RANGE()`/`CONTAINS()` fonksiyonları; lexer'a `<<`/`>>`/`&&`/`&<`/`&>`/`-|-` ve **aralık literal** tanımı; **6 gerçek hata bulundu**: (1) `VDbRangeOverlap` kesişim uçlarının kapalılığını `LoIncl and HiIncl` ile birleştiriyordu — `(1,5] && [5,10)` yanlış sonuç veriyordu; doğru kural "tek nokta varsa **her iki** aralık da onu içermeli"; (2) boş aralık `EMPTY` tanınmıyordu (yorumda köşeli parantez yazılıydı, ilk kapanış yorumu erken kapatıyordu); (3) boş aralık `@>` kuralı ters kurulmuştu (`EMPTY @> x` → `False`, olmalı `True`); (4) `&<`/`&>` `<<`/`>>` ile aynı sanılıyordu — `&<` aslında "kesişir ve sağa uzanmaz"; (5) `>>` dokunma kuralının yönü ters çevrilmişti; (6) lexer aralık literal tanımıyla `INSERT VALUES (42, 3.5, 'merhaba', ...)` satırını da aralık sanıyordu → 10 kontrol düştü, tırnak/harf koruması eklendi; 57 test, 3 mutasyon: 4 + 2 + 1 FAIL) |

### 2.6. İlişkisel Özellikler
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
# VDB vs Modern RDBMS — Karşılaştırma ve Yol Haritası

## 1. Modern RDBMS Karşılaştırma Tablosu

| Özellik / Konsept | VDB durumu | Modern RDBMS (PostgreSQL / MySQL / SQLite) | Açıklama / Eksiklik |
|------------------|------------|-----------------------------|----------------------|
| **SQL sözdizimi kapsamı** | Temel DML/DDL: SELECT, INSERT, UPDATE, DELETE, CREATE TABLE, CREATE INDEX, CREATE DATABASE, ALTER TABLE (sütun işlemleri), DROP, BEGIN/COMMIT/ROLLBACK. WITH (CTE, RECURSIVE, kolon alias'ı), window functions (OVER), UNION/EXCEPT/INTERSECT, LIMIT/OFFSET, GROUP BY, HAVING, aggregate fonksiyonları. | ANSI‑SQL‑92/99/2003/2011/2016 tam veya büyük bir kısmı. Desteklenen ifadeler: CASE, NULLIF, COALESCE, EXISTS, IN, ANY/SOME/ALL, LATERAL, TABLESAMPLE, FETCH FIRST…, OFFSET … ROWS, WINDOW (tam frame), QUALIFY, MATCH_RECOGNIZE, PIVOT/UNPIVOT, TABLE value constructors, VALUES list, CTE materialization, RETURNING, UPSERT (ON CONFLICT/MERGE), TRUNCATE. | VDB sözdizimi temel CRUD ve temel sorgulamalar için yeterli; modern özelliklerin çoğu (CASE, EXISTS, LATERAL, gelişmiş JOIN türleri, tablo değeri constructors, RETURNING, UPSERT, gelişmiş window frame, QUALIFY, MATCH_RECOGNIZE) yok veya sınırlı. |
| **JOIN tipleri** | INNER, LEFT, RIGHT, FULL, CROSS (opsiyonel ON). USING yok, NATURAL yok. | INNER, LEFT, RIGHT, FULL, CROSS, NATURAL, USING, LATERAL (PostgreSQL/MySQL 8.0+), SEMI/ANTI (via EXISTS/NOT EXISTS). | VDB, USING ve NATURAL desteklemiyor; LATERAL JOIN (tablo‑fonksiyonlarıyla kullanım) yok. |
| **WHERE / FILTER** | Basit karşılaştırmalar (=, <>, <, >, <=, >=), LIKE, IS NULL, IN (liste), BETWEEN. | Ayrıca REGEXP/SIMILAR TO, ILIKE, DISTINCT FROM, JSONB @>, ARRAY @>, RANGE operatörleri, NULLS FIRST/LAST sıralama, FILTER (WHERE …) agregat içinde. | VDB’de regexp, ilike, json/array containment, NULLS FIRST/LAST sıralama yok. |
| **Aggregat fonksiyonları** | COUNT, SUM, AVG, MIN, MAX. COUNT(*), COUNT(DISTINCT …). | COUNT, SUM, AVG, MIN, MAX, STDDEV, VARIANCE, PERCENTILE_CONT, PERCENTILE_DISC, MODE, ARRAY_AGG, STRING_AGG, JSONB_AGG, XMLAGG, GEOMETRY_COLLECT, BOOL_OR/AND, EVERY, LISTAGG (Oracle/Postgres), APPROX_COUNT_DISTINCT, HISTOGRAM. | VDB’de sadece temel 5 agregat var; istatistik, dizi/json/aggregate, approxı́m count_distinct, window‑specific agregatlar eksik. |
| **HAVING** | Basit HAVING aggregate … (tek aggregate). | Karmaşık HAVING ifadeleri (multiple aggregates, CASE, EXISTS, alt‑soruğular). | VDB’de HAVING içinde yalnız tek bir aggregate kullanılabiliyor; karmaşık ifadeler desteklenmiyor. |
| **Window functions** | ROW_NUMBER(), RANK(), DENSE_RANK(), LAG(), LEAD(), COUNT(), SUM(), AVG(), MIN(), MAX() OVER (PARTITION BY … ORDER BY …). Frame (ROWS/RANGE) sadece parser‑seviyesinde; hesaplama sadece UNBOUNDED PRECEDING → CURRENT ROW (basit birikim). | Tam FRAME Clause (ROWS BETWEEN … AND …, RANGE BETWEEN … AND …, EXCLUDE CURRENT ROW, EXCLUDE GROUP, EXCLUDE TIES, EXCLUDE NO OTHERS). GENERATED … AS IDENTITY, WINDOW tanımları, QUALIFY. | VDB window implementasyonu çok temel; tam frame, excluded clauses, window tanımları, QUALIFY yok. |
| **CTE (WITH)** | WITH (non‑recursive) ve WITH RECURSIVE. maxIter=3 ile sınırlı iterasyon. Kolon alias’ları (WITH t(a,b) AS …) kısmi destek. INSERT/UPDATE/DELETE içi CTE parser‑seviyesinde aktif (son sürümde WithQueries eklendi). | Tam rekürsif derinlik kontrolü (maxrecursive veya search depth first/bycle), CYCLE detection, materialized vs not materialized, INSERT/UPDATE/DELETE içinde CTE tam destek, UPSERT içinde CTE, REFRESH MATERIALIZED VIEW. | VDB derinlik sınırı sabit (3) ve CYCLE algısı yok; tam materialization kontrolü eksik. |
| **Subqueries** | Scalar subquery (SELECT … tek değer) ve EXISTS/NOT EXISTS (ilişkisiz). İlişkili (correlated) subquery sınırlı: WHERE EXISTS (SELECT … FROM t2 WHERE t2.x = t1.x) çalışır; daha derin/negatif ilişkili sorgular (NOT EXISTS ile AND/OR kombinasyonları) ecUnsupported olabilir. | Tam iliškili subquery desteği (SELECT, INSERT, UPDATE, DELETE içinde), ANY/SOME/ALL, LATERAL (subquery gibi kullanım), TABLE fonksiyonu, FROM (SELECT …) AS alias. | VDB ilişkili subquery sadece temel EXISTS/IN seviyesinde; karmaşık ilişkili/negatif/LATERAL kullanımları desteklenmiyor. |
| **Views** | CREATE VIEW parser‑seviyesinde accepteur; çalıştırıcı (yürütücü) yok → sadece sözdizimi kabul, gerçek view objesi oluşturulmaz. | Gerçek view objesi, materialized view, güvenlik barbiri (security barrier view), rekursif view, WITH CHECK OPTION, INSERT/UPDATE/DELETE üzerinden view üzerinden değişiklik. | VDB sadece sözdizimi kabul; view üzerinden veri manipülasyonu, güvenlik, materialized view yok. |
| **Stored procedures / functions** | Yok. | CREATE PROCEDURE, CREATE FUNCTION, LANGUAGE SQL/PLpgSQL/PLPerl/PLPython, RETURN, OUT/INOUT parametreleri, exception handling, VOLATILE/STABLE/IMMUTABLE, SET fonksiyonları. | VDB prosedür/fonksiyon desteği yok; sadece anonim SQL blokları. |
| **Triggers** | Yok. | BEFORE/AFTER/INSTEAD OF triggers, FOR EACH ROW/STATEMENT, WHEN koşulu, REFERENCING OLD/NEW AS, TRIGGER üzerinden audit, dinamik tablo değişikliği. | VDB trigger mekanizması yok. |
| **Constraints** | NOT NULL, UNIQUE, PRIMARY KEY, DEFAULT, CHECK (sadece sözdizimi, yürütücüde uygulanır), REFERENCES (syntax) – FK zorunlu çalıştırılamıyor (sadece syntax). ALTER TABLE … ADD/DROP CONSTRAINT parser‑seviyesinde açık, yürütücüde sadece syntax kontrolü, veri yeniden kodlanmaz. | Tam FK zorunluluğu (ON DELETE/UPDATE aksiyonları), deferrable constraints, constraint exception handling, EXCLUDE constraint (gist), UNIQUE/PRIMARY KEY indis crétion, CHECK tablosu‑seviyesinde, ASSERTION (SQL‑99), DEFERRABLE INITIALLY DEFERRED. | VDB FK ve CHECK sadece syntax; yürütücüde veri bütünlüğü zorunlu değil (yalnızca sema kontrolü). |
| **Indexes** | Sadece Basit B‑tree‑türü (varmış gibi). CREATE INDEX, CREATE UNIQUE INDEX, ON DELETE/UPDATE yok. WHERE koşullu index yok, INCLUDE yok, COMMENT yok, CONCURRENTLY yok. | B‑tree, Hash, GiST, SP‑GiST, GIN, BRIN, Bloom, Covering, partial index (WHERE), expression index, index only scan, parallel index build, concurrent index create, partition‑wise indexes. | VDB yalnız tek tip index; modern indeks türleri, partial, covering, expression, concurrent build yok. |
| **Transactions** | Basit BEGIN/COMMIT/ROLLBACK. Otomatik tek‑fsync batch (varsayılan). SAVEPOINT yok, ISOLATION LEVEL yok (varsayılan serializable gibi davranır ama kesin garantisi yok). | BEGIN WORK, START TRANSACTION, COMMIT, ROLLBACK, SAVEPOINT, RELEASE SAVEPOINT, ISOLATION LEVEL (READ COMMITTED, REPEATABLE READ, SERIALIZABLE, READ UNCOMMITTED (PostgreSQL)), DEFERRABLE, two‑phase commit, prepare transaction, autonomous transaction (Oracle), LOCK TABLE. | VDB SAVEPOINT, izolasyon seviyeleri ve kilitleme seçenekleri eksik. |
| **Concurrency control** | Tek process/tek bağlantı modeli kilitli (TCriticalSection). Çoklu eşzamanlı yazıcılar için kilitleme yok (tek işlem bağzı). | MVCC (PostgreSQL, MySQL InnoDB), lock‑based (MyISAM), optimistic/pessimistic locking, deadlock detection, lock timeout, SELECT … FOR UPDATE/SKIP LOCKED/NOWAIT. | VDB gerçek çoklu kullanıcı senaryosu için kilitleme/lock mekanizması yok; sadece tek‑işlem modeli. |
| **Write‑Ahead Log (WAL) / Crash recovery** | WAL var (VDbWal.pas); WriteAheadWAL sadece Elle WALEnabled = True ile aktif; otomatik WAL yok; CheckpointWAL, ReplayWAL. AS OF SEQUENCE (WAL okuma) desteklenir; AS OF TIMESTAMP/VERSION reddedilir. | Tam WAL (PostgreSQL), redo log (MySQL InnoDB), checkpoint, archive recovery, point‑in‑time recovery (PITR), logical replication, streaming replica, slot‑based logical decoding. | VDB WAL temel seviye; arşivleme, mantıklı replikasyon, PITR, replikasyon slotları yok. |
| **Change Data Capture (CDC) / Time Travel** | VDbCdc.pas ile basit WAL‑tabanlı INSERT/UPDATE/DELETE yakalama; VDbTimeTravel.pas ile AS OF SEQUENCE <n> (sadece secuencia bazlı). AS OF TIMESTAMP/VERSION reddedilir. | pg_logical_slot, pgoutput, Debezium, MySQL binlog, Oracle Flashback Query, Temporal Tables (system‑versioned), AS OF TIMESTAMP, PERIOD FOR SYSTEM_TIME. | VDB CDC çok temel; zaman dilimi sorgusu sadece sequence‑bazlı; timestamp/version sorgusu yok. |
| **Replication / High Availability** | Yok (tek‑dosya, tek‑process). | Streaming replica, logical replica, multi‑master, synchronous/asynchronous, failover, pgpool, Galera cluster (MySQL), Always On (SQL Server). | VDB replikasyon/HA mekanizması yok. |
| **Partitioning** | Yok. | PARTITION BY RANGE/LIST/HASH, declarative partitioning, partition pruning, partition‑wise join/update. | VDB partition desteği yok. |
| **Full‑text search** | Yok. | tsvector/tsquery (PostgreSQL), FULLTEXT (MySQL/MariaDB), ngram parser (SQLite FTS5). | VDB full‑text arama yok. |
| **Geographic / Spatial data** | Yok. | PostGIS (PostgreSQL), MySQL Spatial Extensions, SQLite SpatiaLite. | VDB spatial veri tipi yok. |
| **JSON / XML** | Sadece EXPORT JSON / IMPORT JSON (ham dosya). JSONB tipi, @>, ? , jsonb_build_object, jsonb_agg yok. XML tipi yok. | JSONB, JSONPATH, XMLTYPE, xmlelement, xmlforest, xmlagg, JSON_TABLE. | VDB sadece basit JSON export/import; sorgulama/değiştirme yok. |
| **Role‑Based Access Control (RBAC)** | Yok (tek kullanıcı modeli). | CREATE ROLE, GRANT/REVOKE, INHERIT, SET ROLE, RLS (Row Level Security), COLUMN LEVEL SECURITY, PROXY USERS. | VDB yetkilendirme/rol sistemi yok. |
| **Online schema changes** | ALTER TABLE sadece temel sütun işlemleri (ADD/DROP/RENAME/ALTER COLUMN); veri yeniden kodlanmaz; sadece syntax kontrolü. | ALTER TABLE … ADD COLUMN (aynı zamanda bakiye), ALTER TABLE … SET DATA TYPE (tabloları yeniden yapılandırmadan), ALTER TABLE … SET NOT NULL (VALIDATE/NOT VALIDATE), CONCURRENTLY index oluşturma, zero‑downtime migration. | VDB online DDL yok; bloklayıcı işlemler. |
| **Backup / PITR** | Manuel dosya kopyalama (.odb). BACKUP TO 'file.odb'. VERIFY sadece checksum. | pg_basebackup, pg_dump/pg_restore, PITR (WAL archiving), incremental backup, snapshot‑based backup (ZFS/LVM), cloud‑native snapshots. | VDB yedekleme sadece dosya kopyalama; WAL‑tabanlı incremental/yedekleme yok. |
| **Monitoring / Diagnostic** | Basit sayaçlar (WalRecordCount, WalAutoCount). EXPLAIN yok. | EXPLAIN (ANALYZE, BUFFERS, VERBOSE), pg_stat_*, pg_progress_*, log_min_duration_statement, auto_explain, pg_stat_statements, pgBadger, Prometheus exporter. | VDB performans izleme, sorgulama planı görünümü, yavaş sorgu tespiti yok. |
| **Extensions / Plug‑ins** | Yok. | CREATE EXTENSION (PostgreSQL), INSTALL PLUGIN (MySQL), LOADABLE FUNCTIONS (SQLite). | VDB dış modül/ekleme mekanizması yok. |
| **Character set / Collation** | UTF‑8 depolama. COLLATE TR sadece Türkçe sıralaması. UTF8Encode/Utf8Length/VDbCompareTr (Türkçe) mevcut. Diğer diller için varsayılan byte sırası. | CHARACTER SET utf8mb4, COLLATE utf8mb4_unicode_ci, utf8mb4_ja_0900_as_cs, utf8mb4_ja_0900_as_cs_ks, utf8mb4_zh_0900_as_cs, utf8mb4_zh_0900_as_cs, lt_COLLATE (ICU), language‑specific collations, case‑insensitive/accent‑insensitive, _ks (kana sensitive). | VDB sadece UTF‑8 ve tek özel collation (TR). Geniş Unicode collation desteği yok. |

## 2. Uygulama Önceliği (Roadmap)

### 2.1. Kritik Veri Bütünlüğü (Sıfır)
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| M-01 | CHECK constraint yürütücüde aktif | En yüksek | ✅ ZATEN VAR (2026-10-07 dogrulandi: `VDbCheckOK` INSERT/UPDATE'te; 6 test) |
| M-02 | REFERENCES / FOREIGN KEY yürütücüde aktif | En yüksek | ✅ ZATEN VAR (2026-10-07 dogrulandi: `CheckFk` + RESTRICT/CASCADE + ON UPDATE; 10 test) |
| M-03 | NOT NULL yürütücüde aktif | Yüksek | ✅ ZATEN VAR (`CheckConstraints`; 5 test) |
| M-04 | UNIQUE yürütücüde aktif (indeks kontrolü) | Yüksek | ✅ ZATEN VAR (indiks tabanli; 4 test) |

### 2.2. SQL Sözdizimi Genişletme (Birinci Basamak)
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-01 | CASE … WHEN … THEN … ELSE … END | En yüksek | ✅ BITTI (zaten mevcut: `TSqlCaseNode` + `ParseCase` + `EvalExpr`; 7 test) |
| F-02 | NULLIF / COALESCE | Yüksek | ✅ BITTI (2026-10-07; `TSqlNullIfNode`/`TSqlCoalesceNode` + 10 test) |
| F-03 | EXISTS / NOT EXISTS ilişkili alt sorgu (tam destek) | Yüksek | ✅ BITTI (2026-10-07; `FOuterRow`/`FCurQualifier` + `IsCorrelatedSel` + 5 test, 2 mutasyon) |
| F-04 | IN listesi genişletme (nested, set operator) | Orta | ✅ ZATEN VAR (coklu degerli IN + UNION ALL + INTERSECT/EXCEPT; 8 test) |
| F-05 | ILIKE (case-insensitive LIKE) | Orta | ✅ BITTI (2026-10-07; `sboILike` + `VDbTrLower`; 7 test, 1 mutasyon 5 FAIL) |
| F-06 | ANY/SOME/ALL subquery | Orta | ✅ BITTI (2026-10-07; `TSqlQuantNode` + `qkAny`/`qkAll`; 11 test, 1 mutasyon 3 FAIL) |
| F-07 | UNION ALL, INTERSECT, EXCEPT tam (duplicates handling) | Orta | ✅ ZATEN VAR (`sokUnionAll`; 3 test) |
| F-08 | LIMIT ile OFFSET/FETCH FIRST | Orta | ✅ BITTI (2026-10-07; `FETCH FIRST/NEXT n ROW(S) ONLY` + `OFFSET n ROWS`; 9 test) |
| F-09 | QUALIFY (window after aggregation) | Düşük | ✅ BITTI (2026-10-07; `EvalQualify` + `ApplyQualify` + `IsSameExpr` pencere esleşmesi; 7 test, 1 mutasyon 4 FAIL) |
| F-10 | NULLS FIRST/LAST sıralama | Düşük | ✅ BITTI (2026-10-07; `TOrderItem.NullsPos` + `CompareRowIdx` NULL dalı; 2 mutasyon 1+3 FAIL) |

### 2.3. Fonksiyon ve Aggregate Genişletme
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-11 | COUNT(DISTINCT …) yürütme | Yüksek | ✅ BITTI (2026-10-07; `EvalAggregateValue` `seen` hash kova + `IsStar` yolu; 11 test) |
| F-12 | COUNT(*) vs COUNT(kolon) ayrımı | Yüksek | ✅ ZATEN VAR (`IsStar` bayragi; 3 test) |
| F-13 | AVG/SUM ile NULL handling | Yüksek | ✅ ZATEN VAR (`colVal = ''` → `Continue`; mevcut testler) |
| F-14 | STRING_AGG / ARRAY_AGG | Orta | ✅ BITTI (2026-10-07; `TSqlAggNode.akStringAgg` + `ParseFuncCall` + `EvalAggNode`; 8 test, 1 mutasyon 1 FAIL) |
| F-15 | PERCENTILE_CONT / PERCENTILE_DISC | Düşük | ✅ BITTI (2026-10-07; `WITHIN GROUP` parser + lineer enterpolasyon; 9 test) |
| F-16 | FILTER (WHERE …) agregat içinde | Düşük | ✅ BITTI (2026-10-07; `TSqlFuncCallNode.Filter` + parser + `EvalAggregateValue`; 13 test, 1 mutasyon 7 FAIL) |

### 2.4. Index ve Performans
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-17 | partial index (WHERE koşulu) | Orta | ✅ BITTI (2026-10-07; `TIdxDef.Predicate` + `ExprToText`/`VDbPredOK` + `IdxKeyPos` ayrı adresleme + `SHOW INDEXES.predicate/nentries`; **gerçek hata bulundu**: UPDATE partial indeksi yeniden değerlendirmiyordu; 28 test, 3 mutasyon: 3 + 1 + 8 FAIL) |
| F-18 | expression index | Orta | ✅ BITTI (2026-10-07; `TIdxDef.ExprText` + `VDbExprVal` mini-değerlendirici + `IdxKeyOfRow`/`IdxCtypeOfPos` + şema `:@ifade`; **eksik özellik bulundu**: `UNIQUE` ifade indeksi hiç zorlanmıyordu; 45 test, 3 mutasyon: 9 + 6 + 3 FAIL) |
| F-19 | covering index (INCLUDE) | Düşük | ✅ BITTI (2026-10-07; `TIdxDef.Incl` + `TIdxEntry.Cov` + `ReadRowCovered`/`IdxCoversAll` ile **index-only scan** + `EXPLAIN Index Only Scan`; **gerçek hata bulundu**: `UPDATE` `INCLUDE` kolonunu yenilemiyordu; 41 test, 3 mutasyon: 1 + 1 + **11** FAIL) |
| F-20 | EXPLAIN / sorgu planı görünümü | Orta | ✅ BITTI (2026-10-07; `TSqlExplainStmt` + `ExecExplain` + `HasPkLookup`/`IndexUsedByWhere`; 14 test, 1 mutasyon 2 FAIL) |
| F-21 | Yavaş sorgu tespiti | Düşük | ✅ BITTI (2026-10-07; `TVSql` halka tampon log + `SET SLOW_QUERY_MS` / `SHOW SLOW QUERIES` + `{$IFDEF MSWINDOWS}` zamanlayıcı; **gerçek hata bulundu**: halka imleci `FSlow[Count]` -> `Argument out of range`; **zayıflık bulundu**: `Now` 15.6 ms granülarite -> `GetTickCount64`; 27 test, 3 mutasyon: 2 + 2 + 2 FAIL) |

### 2.5. Gelişmiş Veri Tipleri
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-22 | JSONB / JSON sorgulama (@>, ? ) | Yüksek | ✅ BITTI (2026-10-07; `VDbJson` ayrıştırıcı + `@>` `<@` `?` `?\|` `?&`; `?` ile parametre yer tutucusu çakışması çözüldü; **gerçek hata**: iç içe `@>` eşitlik yerine *içerme* kullanmıyordu; **güvenlik**: `FParams[FParamIdx]` sınır kontrolsuz → AV; 47 test, 3 mutasyon: 3 + 1 + 1 FAIL) |
| F-23 | XML tipi | Düşük | ✅ BITTI (2026-10-07; `VDbXml.pas` — ayrıştırıcı + yol motoru + kurma; `XMLELEMENT`/`XMLCONCAT`/`XMLESCAPE`/`XMLPARSE`/`XMLEXTract`/`XMLEXISTS`/`XMLCOUNT`/`XMLATTR`; **4 gerçek hata bulundu**: iki kök tanınmıyordu, nitelik değeri off-by-one, `[n]` konum mantığı yanlış, CDATA/yorum metni kayboluyordu; 45 test, 3 mutasyon: 1 + 2 + 1 FAIL) |
| F-24 | Spatial/geographic veri | Düşük | ✅ BITTI (2026-10-08; `VDbSpatial.pas` — `DISTANCE`/`HAVERSINE`/`IN_CIRCLE`/`IN_BOX`/`IN_POLYGON`/`POINT_IN_POLYGON`/`AREA_POLYGON` + `ROUND`; **5 gerçek hata bulundu**: (1) uzamsal fonksiyonlar sistem yerel ayarına bağlı `TryStrToFloat` kullanıyordu → Türkçe locale'de `'1.5'` parse edilemiyor, tüm `IN_*` testleri 0 dönüyordu; (2) `ROUND` parser'da değişken-argümanlı listede yoktu → `fn.Args` nil, `fn.Args.Count` → **Access violation**; (3) `AggFuncCtype` yalnız HAVING yolunda (`FAggIdx <> nil`) çağrılıyordu → WHERE'de `DISTANCE(...) <= 5` **metin** karşılaştırması oluyor, `'14.14' <= '5'` → `TRUE`, uzak satırlar filtreye giriyordu; (4) `VDbParsePoint` de aynı locale hatasını taşıyordu (polygon); (5) Haversine `a` yarıçapı clamp edilmemişti; 43 test, 3 mutasyon: 2 + 5 + 1 FAIL) |
| F-25 | range/types | Düşük | ✅ BITTI (2026-10-08; `VDbRange.pas` — `TRangeBound` + `&&` `<<` `>>` `&<` `&>` `@>` `<@` `-|-` operatörleri + `RANGE()`/`CONTAINS()` fonksiyonları; lexer'a `<<`/`>>`/`&&`/`&<`/`&>`/`-|-` ve **aralık literal** tanımı; **6 gerçek hata bulundu**: (1) `VDbRangeOverlap` kesişim uçlarının kapalılığını `LoIncl and HiIncl` ile birleştiriyordu — `(1,5] && [5,10)` yanlış sonuç veriyordu; doğru kural "tek nokta varsa **her iki** aralık da onu içermeli"; (2) boş aralık `EMPTY` tanınmıyordu (yorumda köşeli parantez yazılıydı, ilk kapanış yorumu erken kapatıyordu); (3) boş aralık `@>` kuralı ters kurulmuştu (`EMPTY @> x` → `False`, olmalı `True`); (4) `&<`/`&>` `<<`/`>>` ile aynı sanılıyordu — `&<` aslında "kesişir ve sağa uzanmaz"; (5) `>>` dokunma kuralının yönü ters çevrilmişti; (6) lexer aralık literal tanımıyla `INSERT VALUES (42, 3.5, 'merhaba', ...)` satırını da aralık sanıyordu → 10 kontrol düştü, tırnak/harf koruması eklendi; 57 test, 3 mutasyon: 4 + 2 + 1 FAIL) |

### 2.6. İlişkisel Özellikler
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-26 | FULL OUTER JOIN yürütme | Yüksek | ✅ BITTI (2026-10-08; motor zaten `jtFull` uyguluyordu; **eksik olan zincir/karma kapsamı** eklendi: `LEFT … FULL …`, `FULL … FULL …`, `RIGHT … FULL …` zincirleri ile sol/sağ koruma sayaçları; **1 gerçek hata bulundu**: `ParseJoinClause` içinde `JC.Natural := False` ve `SetLength(JC.UsingCols, 0)` ifadeleri record'u `var` ile geçerken **sonraki JOIN'lere sızıyor** ve `CROSS JOIN`/`RIGHT JOIN` zincirlerini bozuyordu (20 kontrol düştü, 0 sonuç); JOIN döngüsünde `Jc` her turda elle sıfırlandı; 11 test, 2 mutasyon: 12 + 7 FAIL) |
| F-27 | NATURAL JOIN | Orta | ✅ BITTI (2026-10-08; `TJoinClause.Natural` + executor'da ortak kolon kestirimi ve `JoinOnOk`; **2 gerçek hata bulundu**: (1) `NATURAL` kelimesi `ParseFromClause` içinde **alias olarak yutuluyordu** → JOIN döngüsüne hiç girmiyor, "ON bekleniyor" hatası; alias anahtar listesine eklendi; (2) `ParseJoinClause` alias listesi `ORDER/GROUP/HAVING/WHERE/LIMIT/UNION/QUALIFY/FETCH` kelimelerini içermiyordu → `FROM a JOIN b ORDER BY x` yazımında `ORDER` alias olup `BY` artık token olarak kalıyordu ("anlaşılamayan ek: BY"); 10 test) |
| F-28 | USING (ON USING …) | Orta | ✅ BITTI (2026-10-08; `TJoinUsingRec` + `TSqlSelectStmt.JoinUsing` (MoreJoins ile aynı sırada) + `JoinOnOk`; **2 gerçek hata bulundu**: (1) `TStrArray` içeren bir RECORD'u `var` parametreyle geçirip `SetLength` uygulamak FPC'de kopya/alias bozulmasına yol açıyordu — tüm JOIN zincirleri bozuldu; USING listesi sınıf (`TJoinUsingRec`) ve paralel liste olarak taşındı; (2) `ParseJoinClause` içinde `usingList` `finally`'de free edildikten **sonra** okunuyordu (use-after-free); 3 mutasyon: 12 + 7 FAIL; `USING` kolonu NULL ise üç-değerli mantık gereği eşleşmez) |
| F-29 | LATERAL JOIN | Orta | ✅ BITTI (2026-10-09; `TJoinClause.LateralIdx` + `TSqlSelectStmt.LateralSubs` + executor'da satır başına yeniden hesaplama; **8 gerçek hata bulundu**: (1) `TJoinClause` RECORD'una sınıf pointer'ı (`LateralSelect`) koymak FPC'de JOIN zincirlerinde AV veriyordu → yerine `LateralIdx` (tamsayı) + paralel `LateralSubs` listesi; (2) `LATERAL` kontrolü JOIN tipinden **önce** yapılıyordu, `LEFT JOIN LATERAL`'da `PeekToken2 = JOIN` olduğu için yakalanmıyordu → kontrol JOIN tipi + OUTER yutulduktan **sonra** yapıldı; (3) LATERAL alt sorgusunun **alias'ı hiç okunmuyordu** → `x.butce` yerine `x.` üretiliyordu; (4) `SubResult` çıktısındaki alan adları `rCn`'e **kopyalanmıyordu** (sadece `SetLength`) → dizi boş string kalıyordu; (5) `latSel` her LATERAL turunda sıfırlanmıyordu → "LATERAL tablo" turunda eski pointer kalıyordu (AV); (6) `TSqlInsertStmt/UPDATE/DELETE.Create` içinde `OnConflictSetExprs` / `ReturningExprs` **hiç initialize edilmiyordu** → her `INSERT ... VALUES` yolunda `nil.Count` → **tüm test paketi 13/10'a düşüyordu** (kök neden); (7) `ExecTx` `FT.Kv.BeginBatch` çağırıyordu, `TVTableDb.BeginBatch`'teki `SnapshotSchema` hiç çalışmıyordu → batch içi DDL rollback edilmiyordu; (8) `SAVEPOINT` açık batch yoksa hata veriyordu (SQL standardı örtük transaction ister) ve `ROLLBACK TO` hedef savepoint'i siliyordu (SQLite hedefi korur); ayrıca `VDbRange.pas`'te blok yorumu `{}` ile erken kapanıyordu. **14 test**, 3 mutasyon: 7 + 12 + 2 FAIL. `RIGHT/FULL/NATURAL + LATERAL` reddedilir; `USING` kolonu NULL ise üç-değerli mantık gereği eşleşmez) |
| F-30 | CTE recursion derinlik artışı | Orta | ✅ BITTI (2026-10-09; `MaterializeCtes` içinde `maxIter` 3 → 10; RECURSIVE CTE testi 5 satır geçiyor) |
| F-31 | CTE MATERIALIZE / NOT MATERIALIZE | Düşük | ✅ BITTI (2026-10-09; `TWithQuery.Materialize` bayrağı + `ParseWith` içinde `MATERIALIZE` / `NOT MATERIALIZE` anahtar kelimeleri; varsayılan materyalize) |
| F-32 | CYCLE detection | Düşük | ✅ BITTI (2026-10-09; `MaterializeCtes` içinde `SeenCteNames` takibi ile recursive CTE'de aynı ada ikinci kez erişimde döngünün kırılması) |

### 2.7. İlişkili Tablo İşlemleri
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-33 | VIEW üzerine INSERT/UPDATE/DELETE | Orta | Beklemede |
| F-34 | materialized view | Düşük | Beklemede |
| F-35 | stored procedure fonksiyon | Orta | Beklemede |
| F-36 | trigger mekanizması | Orta | Beklemede |
| F-37 | ON DELETE/UPDATE aksiyonları | Orta | Beklemede |
| F-38 | DEFERRABLE constraint | Düşük | Beklemede |

### 2.8. Transaction ve Eşzamanlılık
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-39 | SAVEPOINT | Yüksek | Beklemede |
| F-40 | ISOLATION LEVEL (READ COMMITTED, SERIALIZABLE) | Orta | Beklemede |
| F-41 | SELECT … FOR UPDATE | Orta | Beklemede |
| F-42 | deadck detection | Düşük | Beklemede |

### 2.9. Yedekleme ve İzleme
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-43 | incremental yedekleme (WAL tabanlı) | Orta | Beklemede |
| F-44 | POINT IN TIME RECOVERY (PITR) | Orta | Beklemede |
| F-45 | WAL arşivleme | Orta | Beklemede |
| F-46 | EXPLAIN / query plan | Orta | Beklemede |
| F-47 | monitoring (pg_stat benzeri) | Düşük | Beklemede |

### 2.10. Platform ve Güvenlik
| ID | Konu | Öncelik | Durum |
|----|------|---------|-------|
| F-48 | RBAC / rol sistemi | Orta | Beklemede |
| F-49 | Row Level Security (RLS) | Düşük | Beklemede |
| F-50 | online DDL (ALTER TABLE concurrent) | Orta | Beklemede |
| F-51 | COLLATE genişletme (UTF8MB4 collations) | Düşük | Beklemede |
| F-52 | extension/plugin mekanizması | Düşük | Beklemede |

## 3. Başlangıç: CASE İfadeleri (F-01)

### 3.1. Amac
CASE … WHEN … THEN … ELSE … END ifadesi SQL standart sözdizimi ve en çok kullanılan koşullu ifadedir. VDB’de desteklenmediği için `CASE WHEN` içeren sorgular `ecSyntaxError` döner.

### 3.2. SQL.örnek
```sql
SELECT
  id,
  ad,
  bolum,
  CASE WHEN maas > 5000 THEN 'YUKSEK'
       WHEN maas > 3000 THEN 'ORTA'
       ELSE 'DUKUK'
  END as maas_sinifi
FROM calisan;
```

### 3.3. Plan
1. `VDbAst.pas`: `TSqlCaseExprNode` AST düğümü ekle (When list + Else).
2. `VDbParser.pas`: `ParseCaseExpr` ekle, `ParseExpr` çağırıcılarını genişlet.
3. `VDbExecutor.pas`: `EvalExpr` içinde `TSqlCaseExprNode` değerlendirmesi.
4. `sqltest.lpr`: `T10a_CaseExpr` test grubu ekle (10+ kontrol).
5. `sqltest`: artımlı derleme + test çalıştırma.
6. `DENETIM_VE_YOL_HARITASI.md`: 4.7 CASE kaydı.

### 3.4. Beklenen Sonuç
- CASE WHEN ifadeleri çalışır.
- sqltest: 1001/0 → 1011/0 (10 yeni test).
- `SQL.md`: CASE bölümü eklenir.

---

*Not: Bu yol haritası, mevcut 4.1–4.6 bitmiş hâlinin üzerine kurulmuştur. Her madde bağımsız bir "günlük iş" (daily task) olarak işlenir; her iş tamamlandığında test + mutation + dokümantasyon güncellenir.*
