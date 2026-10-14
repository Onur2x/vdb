# VDB SQL REFERANSI / VDB SQL REFERENCE

> **TR:** Bu belge, VDB veritabanı motorunun desteklediği tüm SQL komutlarını, veri tiplerini ve ileri özellikleri açıklar. 24 yol haritası maddesi (R-01 → R-24) ve 20+ ek özellik (F-xx) tamamlanmıştır.
>
> **EN:** This document describes all SQL commands, data types, and advanced features supported by the VDB database engine. All 24 roadmap items (R-01 → R-24) and 20+ additional features (F-xx) are complete.

---

## 📑 İÇİNDEKİLER / TABLE OF CONTENTS

1. [Sema Sorguları / Schema Queries](#1-sema-sorguları--schema-queries)
2. [Veri Tipleri / Data Types](#2-veri-tipleri--data-types)
3. [Transaction Yönetimi / Transaction Management](#3-transaction-yönetimi--transaction-management)
4. [CREATE TABLE](#4-create-table)
5. [CREATE / DROP INDEX](#5-create--drop-index)
6. [Veritabanı Yönetimi / Database Management](#6-veritabanı-yönetimi--database-management)
7. [INSERT](#7-insert)
8. [SELECT](#8-select)
9. [UPDATE](#9-update)
10. [DELETE](#10-delete)
11. [JOIN Türleri / JOIN Types](#11-join-türleri--join-types)
12. [Gelişmiş Özellikler / Advanced Features](#12-gelişmiş-özellikler--advanced-features)
13. [JSONB Sorgulama / JSONB Queries](#13-jsonb-sorgulama--jsonb-queries)
14. [XML](#14-xml)
15. [Spatial Sorgular / Spatial Queries](#15-spatial-sorgular--spatial-queries)
16. [RANGE Tipi / RANGE Type](#16-range-tipi--range-type)
17. [Window Functions / Pencere Fonksiyonları](#17-window-functions--pencere-fonksiyonları)
18. [EXPLAIN / ANALYZE](#18-explain--analyze)
19. [WAL (Write-Ahead Logging)](#19-wal-write-ahead-logging)
20. [Time Travel / CDC](#20-time-travel--cdc)
21. [Şifreleme / Encryption](#21-şifreleme--encryption)
22. [Collation (R-20)](#22-collation-r-20)
23. [Desteklenmeyenler / Unsupported](#23-desteklenmeyenler--unsupported)

---

## 1. SEMA SORGULARI / SCHEMA QUERIES

### TR
```sql
-- Tablo yapısı / Table structure
DESCRIBE musteri;
-- veya
DESC musteri;

-- İndeksler / Indexes
SHOW INDEXES FROM musteri;
SHOW INDEXES musteri;  -- FROMsuz da çalışır

-- CREATE TABLE metni / CREATE TABLE statement
SHOW CREATE TABLE musteri;

-- Tabloları listele / List tables
SHOW TABLES;
```

### EN
```sql
-- Table structure
DESCRIBE customer;
-- or
DESC customer;

-- Indexes
SHOW INDEXES FROM customer;
SHOW INDEXES customer;

-- CREATE TABLE statement
SHOW CREATE TABLE customer;

-- List tables
SHOW TABLES;
```

**Dönen kolonlar / Returned columns:**
- `DESCRIBE`: `name, type, pk, notnull, unique, default`
- `SHOW INDEXES`: `name, columns, unique, type`

---

## 2. VERİ TİPLERİ / DATA TYPES

### TR: Temel Tipler
| Tip | Açıklama | Örnek | Boyut |
|---|---|---|---|
| `INTEGER` | Tam sayı | `42`, `-1`, `9223372036854775807` | 8 bayt |
| `FLOAT` | Çift duyarlıklı ondalık | `3.14159`, `-0.001` | 8 bayt |
| `TEXT` | UTF-8 metin | `'Merhaba Dünya'` | sınırsız |
| `BOOL` | Boolean | `true`, `false` | 1 bayt |
| `DATE` | Tarih | `'2026-10-14'` | 8 bayt |
| `DATETIME` | Tarih + saat | `'2026-10-14 15:30:00'` | 8 bayt |
| `TIME` | Saat | `'15:30:00'` | 8 bayt |
| `BLOB` | İkili veri | `X'89504E47...'` | sınırsız |

### TR: İleri Tipler
| Tip | Açıklama | Örnek |
|---|---|---|
| `JSONB` | JSON (sorgulanabilir) | `'{"ad":"Ali","yas":30}'` |
| `XML` | XML (XPath destekli) | `'<kisi><ad>Ali</ad></kisi>'` |
| `RANGE` | Aralık | `'[2026-01-01,2026-12-31)'` |

### EN: Data Types
Same types as above. See examples for syntax.

---

## 3. TRANSACTION YÖNETİMİ / TRANSACTION MANAGEMENT

### TR: Temel
```sql
BEGIN;
INSERT INTO musteri (ad) VALUES (''Ahmet'');
UPDATE musteri SET email = 'ahmet@example.com' WHERE ad = ''Ahmet'';
COMMIT;  -- veya ROLLBACK;
```

### TR: SAVEPOINT (R-02)
```sql
BEGIN;
INSERT INTO musteri (ad) VALUES (''1. kayıt'');
SAVEPOINT sp1;
INSERT INTO musteri (ad) VALUES (''2. kayıt'');
SAVEPOINT sp2;
INSERT INTO musteri (ad) VALUES (''3. kayıt'');

ROLLBACK TO sp1;  -- 2. ve 3. kaydı geri alır

COMMIT;
```

### TR: Nested Transaction (İç İçe)
```sql
BEGIN;
  -- Dış transaction
  INSERT INTO log (mesaj) VALUES (''başlangıç'');
  
  BEGIN;
    -- İç transaction
    INSERT INTO musteri (ad) VALUES (''İç kayıt'');
  COMMIT;  -- Sadece iç transaction'ı commit eder
  
  INSERT INTO log (mesaj) VALUES (''son'');
COMMIT;  -- Dış transaction'ı commit eder
```

### TR: Otomatik Transaction (Batch)
TVSql varsayılan olarak otomatik transaction kullanır. `;` ile ayrılmış cümleler tek `BeginBatch`/`CommitBatch` içinde çalışır (tek fsync, hızlı!).

```pascal
DB.Exec('''
  INSERT INTO musteri (ad) VALUES (''A'');
  INSERT INTO musteri (ad) VALUES (''B'');
  INSERT INTO musteri (ad) VALUES (''C'');
''', R);  // Tek transaction, tek fsync

DB.AutoTransaction := False;  // Kapatmak için
```

### EN: Transaction Management
See examples above.

---

## 4. CREATE TABLE

### TR: Temel
```sql
CREATE TABLE musteri (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ad TEXT NOT NULL,
  email TEXT UNIQUE,
  telefon TEXT,
  yas INTEGER CHECK (yas >= 0 AND yas <= 150),
  aktif BOOL DEFAULT true,
  kayit_tarihi DATETIME DEFAULT CURRENT_TIMESTAMP,
  kategori_id INTEGER REFERENCES kategori(id) ON DELETE CASCADE ON UPDATE CASCADE
);
```

### TR: AUTOINCREMENT
```sql
CREATE TABLE log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- Otomatik artan / Auto-increment
  mesaj TEXT NOT NULL
);
```

### TR: Kolon İçi Kısıtlar
```sql
CREATE TABLE urun (
  id INTEGER PRIMARY KEY,
  ad TEXT NOT NULL,                      -- NOT NULL
  kod TEXT UNIQUE,                        -- UNIQUE
  fiyat FLOAT CHECK (fiyat > 0),         -- CHECK
  stok INTEGER DEFAULT 0,                -- DEFAULT
  kategori_id INTEGER REFERENCES kategori(id)  -- FOREIGN KEY
);
```

### TR: BLOB (İkili Veri)
```sql
CREATE TABLE fotograf (
  id INTEGER PRIMARY KEY,
  musteri_id INTEGER REFERENCES musteri(id),
  resim BLOB NOT NULL,  -- Fotoğraf, belge, vb.
  boyut INTEGER
);

INSERT INTO fotograf (musteri_id, resim, boyut)
VALUES (1, X'89504E470D0A1A0A...', 12345);
```

### TR: FOREIGN KEY Aksiyonları
```sql
CREATE TABLE siparis (
  id INTEGER PRIMARY KEY,
  musteri_id INTEGER REFERENCES musteri(id)
    ON DELETE CASCADE      -- Ana kayıt silinince bu da silinir
    ON UPDATE CASCADE      -- Ana kayıt güncellenince bu da güncellenir
    ON DELETE SET NULL      -- veya SET NULL
    ON DELETE RESTRICT      -- veya RESTRICT (silme engellenir)
    ON DELETE NO ACTION     -- veya NO ACTION (varsayılan)
);
```

### TR: FK Tetikleyici Ne Zaman Çalışır?
- `ON DELETE` → `DELETE` ve `DROP TABLE` (ana tablo)
- `ON UPDATE` → `UPDATE` (PK kolonu)
- `INSERT` → FK doğrulaması (anahtar yoksa hata)

### EN: CREATE TABLE
See examples above. Supports all standard SQL constraints.

---

## 5. CREATE / DROP INDEX

### TR
```sql
-- Basit indeks / Simple index
CREATE INDEX idx_musteri_ad ON musteri(ad);

-- Unique indeks / Unique index
CREATE UNIQUE INDEX idx_musteri_email ON musteri(email);

-- Çoklu kolonlu / Multi-column
CREATE INDEX idx_urun_kategori_fiyat ON urun(kategori_id, fiyat);

-- Partial index (R-xx, F-17)
CREATE INDEX idx_aktif ON musteri(id) WHERE aktif = true;

-- Expression index (F-18)
CREATE INDEX idx_tam_ad ON musteri(lower(ad || ' ' || soyad));

-- Covering index (F-19)
CREATE INDEX idx_email_cover ON musteri(email) INCLUDE (ad, telefon);

-- İndeks sil / Drop index
DROP INDEX idx_musteri_ad;
```

### EN
See examples above.

---

## 6. VERİTABANI YÖNETİMİ / DATABASE MANAGEMENT

### TR
```sql
-- Oluştur / Create
CREATE DATABASE satis;
CREATE DATABASE IF NOT EXISTS satis;

-- Listele / List
LIST DATABASES;
SHOW DATABASES;

-- Aç / Open
OPEN DATABASE satis;
USE satis;

-- Kapat / Close
CLOSE DATABASE;

-- Sil / Drop
DROP DATABASE satis;
DROP DATABASE IF EXISTS satis;
DELETE DATABASE satis;

-- Yedekle / Backup
BACKUP TO 'yedek.odb';

-- Doğrula / Verify
VERIFY;

-- Şifreleme (R-xx)
ALTER DATABASE KEY 'gucluParola123!';
ALTER DATABASE KEY '';  -- Şifrelemeyi kaldır
```

### EN
See examples above.

---

## 7. INSERT

### TR: Temel
```sql
-- Tek kayıt / Single row
INSERT INTO musteri (ad, email) VALUES (''Ali'', ''ali@example.com'');

-- Çoklu kayıt (çoklu VALUES) / Multiple rows
INSERT INTO musteri (ad, email) VALUES
  (''Ali'', ''ali@example.com''),
  (''Ayşe'', ''ayse@example.com''),
  (''Mehmet'', ''mehmet@example.com'');

-- Sütun listesi olmadan / Without column list
INSERT INTO musteri VALUES (1, ''Ali'', ''ali@example.com'');

-- SELECT'ten ekle / Insert from SELECT
INSERT INTO musteri_arşiv (id, ad, email)
SELECT id, ad, email FROM musteri WHERE aktif = false;
```

### TR: UPSERT (R-03)
```sql
-- Varsa güncelle, yoksa ekle / Update if exists, else insert
INSERT INTO musteri (id, ad, email) VALUES (1, ''Ali'', ''yeni@example.com'')
ON CONFLICT(id) DO UPDATE SET ad = EXCLUDED.ad, email = EXCLUDED.email;

-- Varsa hiçbir şey yapma / Do nothing if exists
INSERT INTO musteri (id, ad) VALUES (1, ''Ali'')
ON CONFLICT(id) DO NOTHING;

-- INSERT SELECT ile / With INSERT SELECT
INSERT INTO musteri_arşiv (id, ad)
SELECT id, ad FROM musteri
ON CONFLICT(id) DO UPDATE SET ad = EXCLUDED.ad;
```

### TR: RETURNING (R-04)
```sql
INSERT INTO musteri (ad, email) VALUES (''Ali'', ''ali@example.com'')
RETURNING id, ad, email;

UPDATE musteri SET email = 'yeni@example.com' WHERE id = 1
RETURNING id, ad, email;

DELETE FROM musteri WHERE id = 1
RETURNING id, ad;
```

### EN: INSERT
See examples above. Supports multi-row VALUES, INSERT SELECT, UPSERT (ON CONFLICT), and RETURNING.

---

## 8. SELECT

### TR: Temel
```sql
-- Tüm kolonlar / All columns
SELECT * FROM musteri;

-- Belirli kolonlar / Specific columns
SELECT id, ad, email FROM musteri;

-- Alias / Alias
SELECT ad AS musteri_adi, email AS eposta FROM musteri;

-- DISTINCT
SELECT DISTINCT kategori_id FROM urun;

-- LIMIT / OFFSET
SELECT * FROM musteri LIMIT 10;
SELECT * FROM musteri LIMIT 10 OFFSET 20;

-- FETCH FIRST (F-08)
SELECT * FROM musteri FETCH FIRST 10 ROWS ONLY;
```

### TR: WHERE
```sql
-- Karşılaştırma / Comparison
SELECT * FROM musteri WHERE yas > 18;
SELECT * FROM musteri WHERE yas >= 18 AND yas <= 65;
SELECT * FROM musteri WHERE ad = ''Ali'';
SELECT * FROM musteri WHERE ad <> ''Ali'';

-- IN / NOT IN
SELECT * FROM musteri WHERE id IN (1, 2, 3);
SELECT * FROM musteri WHERE id NOT IN (1, 2, 3);

-- BETWEEN
SELECT * FROM musteri WHERE yas BETWEEN 18 AND 65;

-- LIKE / NOT LIKE
SELECT * FROM musteri WHERE ad LIKE ''A%'';
SELECT * FROM musteri WHERE ad NOT LIKE ''%test%'';

-- ILIKE (F-05) — büyük/küçük harf duyarsız
SELECT * FROM musteri WHERE ad ILIKE ''ali'';

-- IS NULL / IS NOT NULL
SELECT * FROM musteri WHERE email IS NULL;
SELECT * FROM musteri WHERE email IS NOT NULL;

-- EXISTS
SELECT * FROM musteri m WHERE EXISTS (
  SELECT 1 FROM siparis s WHERE s.musteri_id = m.id
);

-- ANY / SOME / ALL (F-06)
SELECT * FROM urun WHERE fiyat > ANY (SELECT fiyat FROM urun WHERE kategori_id = 1);
SELECT * FROM urun WHERE fiyat > ALL (SELECT fiyat FROM urun WHERE kategori_id = 1);
```

### TR: ORDER BY
```sql
-- Artan / Ascending
SELECT * FROM musteri ORDER BY ad;

-- Azalan / Descending
SELECT * FROM musteri ORDER BY ad DESC;

-- Çoklu kolon / Multiple columns
SELECT * FROM musteri ORDER BY kategori_id, ad DESC;

-- NULLS FIRST / NULLS LAST (F-10)
SELECT * FROM musteri ORDER BY email NULLS FIRST;
SELECT * FROM musteri ORDER BY email NULLS LAST;

-- COLLATE (R-20)
SELECT * FROM musteri ORDER BY ad COLLATE ''tr-TR-u-kn-ks'';
```

### TR: GROUP BY + HAVING
```sql
SELECT
  kategori_id,
  COUNT(*) AS adet,
  AVG(fiyat) AS ort_fiyat,
  SUM(fiyat) AS toplam_fiyat,
  MIN(fiyat) AS en_ucuz,
  MAX(fiyat) AS en_pahali
FROM urun
GROUP BY kategori_id
HAVING COUNT(*) > 5
ORDER BY toplam_fiyat DESC;
```

### TR: Aggregate Fonksiyonlar
```sql
-- Temel / Basic
SELECT COUNT(*) FROM musteri;
SELECT COUNT(DISTINCT kategori_id) FROM urun;
SELECT SUM(fiyat) FROM urun;
SELECT AVG(fiyat) FROM urun;
SELECT MIN(fiyat), MAX(fiyat) FROM urun;

-- STRING_AGG (F-14)
SELECT kategori_id, STRING_AGG(ad, '', '') AS urunler
FROM urun
GROUP BY kategori_id;

-- PERCENTILE (F-15)
SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fiyat) AS medyan FROM urun;
SELECT PERCENTILE_DISC(0.9) WITHIN GROUP (ORDER BY fiyat) AS p90 FROM urun;

-- FILTER (F-16)
SELECT
  COUNT(*) AS toplam,
  COUNT(*) FILTER (WHERE fiyat > 1000) AS pahali,
  COUNT(*) FILTER (WHERE fiyat <= 1000) AS ucuz
FROM urun;
```

### TR: Alt Sorgular (Subquery)
```sql
-- Skaler alt sorgu / Scalar subquery
SELECT ad, (SELECT COUNT(*) FROM siparis WHERE musteri_id = m.id) AS siparis_sayisi
FROM musteri m;

-- IN ile / With IN
SELECT * FROM musteri
WHERE id IN (SELECT musteri_id FROM siparis WHERE tutar > 1000);

-- EXISTS ile / With EXISTS
SELECT * FROM musteri m
WHERE EXISTS (SELECT 1 FROM siparis s WHERE s.musteri_id = m.id);

-- Korelasyonlu / Correlated
SELECT * FROM urun u
WHERE fiyat > (SELECT AVG(fiyat) FROM urun WHERE kategori_id = u.kategori_id);
```

### TR: WITH-CTE (R-xx)
```sql
-- Basit CTE / Simple CTE
WITH pahali_urun AS (
  SELECT * FROM urun WHERE fiyat > 1000
)
SELECT * FROM pahali_urun;

-- Recursive CTE (R-10)
WITH RECURSIVE hiyerarsi AS (
  SELECT id, ad, ust_id, 0 AS seviye
  FROM kategori
  WHERE ust_id IS NULL
  
  UNION ALL
  
  SELECT k.id, k.ad, k.ust_id, h.seviye + 1
  FROM kategori k
  JOIN hiyerarsi h ON k.ust_id = h.id
)
SELECT * FROM hiyerarsi;

-- CYCLE detection (R-10)
WITH RECURSIVE hiyerarsi AS (
  SELECT id, ad, ust_id, 0 AS seviye, '' AS yol
  FROM kategori
  WHERE ust_id IS NULL
  
  UNION ALL
  
  SELECT k.id, k.ad, k.ust_id, h.seviye + 1, h.yol || k.id || ''-''
  FROM kategori k
  JOIN hiyerarsi h ON k.ust_id = h.id
  WHERE NOT k.id::text = ANY(string_to_array(h.yol, ''-''))
)
SELECT * FROM hiyerarsi;
```

### TR: CASE (Koşullu İfade)
```sql
SELECT
  ad,
  fiyat,
  CASE
    WHEN fiyat < 100 THEN ''Ucuz''
    WHEN fiyat < 1000 THEN ''Orta''
    ELSE ''Pahalı''
  END AS fiyat_araligi
FROM urun;

-- Basit CASE / Simple CASE
SELECT
  ad,
  CASE kategori_id
    WHEN 1 THEN ''Elektronik''
    WHEN 2 THEN ''Giyim''
    ELSE ''Diğer''
  END AS kategori_adi
FROM urun;
```

### TR: Kümeler / Set Operations
```sql
-- UNION (birleşim, tekrarsız)
SELECT ad FROM musteri
UNION
SELECT ad FROM musteri_arşiv;

-- UNION ALL (birleşim, tekrarlı)
SELECT ad FROM musteri
UNION ALL
SELECT ad FROM musteri_arşiv;

-- EXCEPT (fark)
SELECT ad FROM musteri
EXCEPT
SELECT ad FROM musteri_arşiv;

-- INTERSECT (kesişim)
SELECT ad FROM musteri
INTERSECT
SELECT ad FROM musteri_arşiv;
```

### EN: SELECT
See examples above. Full SELECT support including DISTINCT, WHERE, ORDER BY, GROUP BY, HAVING, subqueries, CTEs, CASE, set operations.

---

## 9. UPDATE

### TR
```sql
-- Temel / Basic
UPDATE musteri SET email = 'yeni@example.com' WHERE id = 1;

-- Çoklu kolon / Multiple columns
UPDATE musteri
SET email = 'yeni@example.com', telefon = '555-1234'
WHERE id = 1;

-- SET içinde aritmetik / Arithmetic in SET
UPDATE urun
SET fiyat = fiyat * 1.1  -- %10 zam
WHERE kategori_id = 1;

UPDATE urun
SET stok = stok - 1
WHERE id = 1;

-- RETURNING (R-04)
UPDATE musteri SET aktif = false WHERE yas < 18
RETURNING id, ad;
```

### EN
See examples above.

---

## 10. DELETE

### TR
```sql
-- Temel / Basic
DELETE FROM musteri WHERE id = 1;

-- Tüm kayıtları sil / Delete all
DELETE FROM musteri;

-- JOIN ile / With JOIN
DELETE FROM siparis
WHERE musteri_id IN (SELECT id FROM musteri WHERE aktif = false);

-- RETURNING (R-04)
DELETE FROM musteri WHERE yas < 18
RETURNING id, ad;
```

### EN
See examples above.

---

## 11. JOIN TÜRLERİ / JOIN TYPES

### TR
```sql
-- INNER JOIN / İç birleştirme
SELECT u.ad, k.ad AS kategori
FROM urun u
INNER JOIN kategori k ON u.kategori_id = k.id;

-- LEFT JOIN / Sol birleştirme
SELECT u.ad, k.ad AS kategori
FROM urun u
LEFT JOIN kategori k ON u.kategori_id = k.id;

-- RIGHT JOIN / Sağ birleştirme
SELECT u.ad, k.ad AS kategori
FROM urun u
RIGHT JOIN kategori k ON u.kategori_id = k.id;

-- FULL OUTER JOIN / Tam dış birleştirme
SELECT u.ad, k.ad AS kategori
FROM urun u
FULL OUTER JOIN kategori k ON u.kategori_id = k.id;

-- CROSS JOIN / Çapraz birleştirme
SELECT u.ad, k.ad
FROM urun u
CROSS JOIN kategori k;

-- NATURAL JOIN (F-27)
SELECT *
FROM urun
NATURAL JOIN kategori;

-- USING (F-28)
SELECT *
FROM urun
JOIN kategori USING (kategori_id);

-- LATERAL JOIN (R-09)
SELECT u.ad, alt.toplam
FROM urun u
CROSS JOIN LATERAL (
  SELECT SUM(fiyat) AS toplam
  FROM siparis
  WHERE urun_id = u.id
) alt;
```

### EN
See examples above.

---

## 12. GELİŞMİŞ ÖZELLİKLER / ADVANCED FEATURES

### TR: Trigger (R-05)
```sql
-- AFTER INSERT
CREATE TRIGGER musteri_log_insert
AFTER INSERT ON musteri
FOR EACH ROW
BEGIN
  INSERT INTO log (tablo, islem, kayit_id)
  VALUES (''musteri'', ''INSERT'', NEW.id);
END;

-- BEFORE UPDATE
CREATE TRIGGER musteri_guncelleme
BEFORE UPDATE ON musteri
FOR EACH ROW
WHEN NEW.yas < OLD.yas  -- Koşul / Condition
BEGIN
  UPDATE musteri SET yas = OLD.yas WHERE id = NEW.id;
END;

-- INSTEAD OF (View üzerinde)
CREATE TRIGGER view_insert
INSTEAD OF INSERT ON musteri_view
FOR EACH ROW
BEGIN
  INSERT INTO musteri (ad, email) VALUES (NEW.ad, NEW.email);
END;

-- Tetikleyici sil / Drop trigger
DROP TRIGGER musteri_log_insert;
```

### TR: View (R-06)
```sql
-- Basit view / Simple view
CREATE VIEW aktif_musteri AS
SELECT id, ad, email
FROM musteri
WHERE aktif = true;

-- View üzerinden sorgu / Query through view
SELECT * FROM aktif_musteri;

-- View'da DML / DML on view
INSERT INTO aktif_musteri (ad, email) VALUES (''Ali'', ''ali@example.com'');
UPDATE aktif_musteri SET email = 'yeni@example.com' WHERE id = 1;
DELETE FROM aktif_musteri WHERE id = 1;

-- View sil / Drop view
DROP VIEW aktif_musteri;

-- Materialized View (R-07)
CREATE MATERIALIZED VIEW musteri_ozet AS
SELECT kategori_id, COUNT(*) AS adet
FROM urun
GROUP BY kategori_id;

REFRESH MATERIALIZED VIEW musteri_ozet;
```

### TR: Stored Procedure / Function (R-08)
```sql
CREATE FUNCTION toplam_fiyat(kategori_id INTEGER)
RETURNS FLOAT
LANGUAGE SQL
AS $$
  SELECT SUM(fiyat) FROM urun WHERE urun.kategori_id = $1;
$$;

-- Çağır / Call
SELECT toplam_fiyat(1);

-- Prosedür / Procedure
CREATE PROCEDURE musteri_ekle(ad TEXT, email TEXT)
LANGUAGE SQL
AS $$
  INSERT INTO musteri (ad, email) VALUES (ad, email);
$$;

CALL musteri_ekle(''Ali'', ''ali@example.com'');
```

### TR: DEFERRABLE Constraints (R-11)
```sql
CREATE TABLE siparis (
  id INTEGER PRIMARY KEY,
  musteri_id INTEGER REFERENCES musteri(id) DEFERRABLE INITIALLY DEFERRED
);

-- Transaction sonuna kadar ertele / Defer until commit
SET CONSTRAINTS ALL DEFERRED;

BEGIN;
INSERT INTO siparis (musteri_id) VALUES (999);  -- Henüz yok
INSERT INTO musteri (id) VALUES (999);           -- Sonra ekle
COMMIT;  -- Şimdi doğrulanır
```

### TR: Partitioning (R-13)
```sql
-- HASH partitioning
CREATE TABLE log (
  id INTEGER,
  tarih DATE,
  mesaj TEXT
) PARTITION BY HASH(id) PARTITIONS 4;

-- RANGE partitioning
CREATE TABLE satis (
  id INTEGER,
  tarih DATE,
  tutar FLOAT
) PARTITION BY RANGE(tarih) (
  PARTITION p2026_q1 VALUES LESS THAN (''2026-04-01''),
  PARTITION p2026_q2 VALUES LESS THAN (''2026-07-01''),
  PARTITION p2026_q3 VALUES LESS THAN (''2026-10-01''),
  PARTITION p2026_q4 VALUES LESS THAN (''2027-01-01'')
);

-- LIST partitioning
CREATE TABLE musteri (
  id INTEGER,
  ulke TEXT
) PARTITION BY LIST(ulke) (
  PARTITION tr VALUES IN (''TR''),
  PARTITION us VALUES IN (''US''),
  PARTITION de VALUES IN (''DE'')
);

-- Partition pruning (otomatik)
SELECT * FROM satis WHERE tarih >= ''2026-04-01'' AND tarih < ''2026-07-01'';
-- Sadece p2026_q2 partition'ı taranır
```

### TR: RBAC / Role / GRANT (R-18)
```sql
-- Rol oluştur / Create role
CREATE ROLE yonetici SUPERUSER;
CREATE ROLE kullanici;

-- Yetki ver / Grant
GRANT SELECT, INSERT ON musteri TO kullanici;
GRANT ALL ON * TO yonetici;

-- Yetki al / Revoke
REVOKE INSERT ON musteri FROM kullanici;

-- Rol ata / Set role
SET ROLE kullanici;
SET ROLE NONE;
```

### TR: Row Level Security (R-19)
```sql
-- RLS'i etkinleştir / Enable RLS
ALTER TABLE musteri ENABLE ROW LEVEL SECURITY;

-- Politika oluştur / Create policy
CREATE POLICY musteri_goruntule ON musteri
  FOR SELECT
  USING (aktif = true);

CREATE POLICY musteri_ekle ON musteri
  FOR INSERT
  WITH CHECK (yas >= 18);

-- Politika sil / Drop policy
DROP POLICY musteri_goruntule ON musteri;

-- RLS'i devre dışı bırak / Disable RLS
ALTER TABLE musteri DISABLE ROW LEVEL SECURITY;
```

---

## 13. JSONB SORGULAMA / JSONB QUERIES (F-22)

### TR
```sql
-- JSON sorgula / Query JSON
SELECT *
FROM musteri
WHERE ayarlar ? 'tema';  -- 'tema' anahtarı var mı?

-- İçerme (containment)
SELECT *
FROM musteri
WHERE ayarlar @> '{"tema":"koyu"}';

-- Değer çıkart / Extract value
SELECT
  ad,
  ayarlar -> 'tema' AS tema,
  ayarlar ->> 'bildirim' AS bildirim,  -- Metin olarak / As text
  ayarlar -> 'ayarlar' -> 'dil' AS dil  -- İçe içe / Nested
FROM musteri;

-- Dizi sorgusu / Array query
SELECT *
FROM musteri
WHERE ayarlar -> 'etiketler' ? 'vip';
```

### TR: Notlar
- `?` iki anlamlıdır: JSON anahtar arama VE parametre yer tutucusu
- `@>` = **içerme**, eşitlik değil
- Anahtar sırası önemsizdir
- Geçersiz JSON → `FALSE`, hata değil
- `NULL` → `NULL`

### EN: JSONB Queries
See examples above.

---

## 14. XML (F-23)

### TR
```sql
-- XPath sorgusu / XPath query
SELECT
  xml_value(metin, '/kisi/ad') AS ad,
  xml_value(metin, '/kisi/yas') AS yas
FROM belge;

-- Fonksiyonlar / Functions
SELECT xml_exists(metin, '/kisi/ad') FROM belge;
SELECT xml_count(metin, '/kisi/iletisim') FROM belge;
```

### TR: Notlar
- Desteklenen yol alt kümesi: `/a/b`, `//a`, `@attr`, `[1]`
- Geçersiz XML → `NULL`, hata değil
- Ayrıştırma kuralları: UTF-8, `<?xml ...?>` başlığı destekli

### EN: XML
See examples above.

---

## 15. SPATIAL SORGULAR / SPATIAL QUERIES (F-24)

### TR
```sql
-- Point
SELECT * FROM lokasyon
WHERE ST_Distance(konum, ST_Point(41.0, 29.0)) < 1000;

-- Polygon
SELECT * FROM bolge
WHERE ST_Contains(sinir, ST_Point(41.0, 29.0));

-- Fonksiyonlar / Functions
SELECT
  ST_Point(x, y),
  ST_Distance(p1, p2),
  ST_Contains(polygon, point),
  ST_Area(polygon),
  ST_Perimeter(polygon)
FROM lokasyon;
```

### TR: Çokgen Biçimi
```sql
-- Polygon (kapalı)
ST_Polygon(''((0,0),(10,0),(10,10),(0,10),(0,0))'')

-- LineString
ST_LineString(''((0,0),(5,5),(10,0))'')
```

### EN: Spatial Queries
See examples above.

---

## 16. RANGE TİPİ / RANGE TYPE (F-25)

### TR
```sql
-- Yazım / Syntax
'[2026-01-01,2026-12-31)'::daterange
'[1,10]'::int4range
'[2026-01-01 00:00,2026-12-31 23:59:59]'::tsrange

-- Operatörler / Operators
SELECT * FROM etkinlik WHERE tarih_araligi @> '2026-10-14'::date;
SELECT * FROM etkinlik WHERE tarih_araligi && '[2026-10-01,2026-10-31)'::daterange;
SELECT * FROM etkinlik WHERE tarih_araligi << '[2026-01-01,2027-01-01)'::daterange;

-- Fonksiyonlar / Functions
SELECT
  lower(tarih_araligi),
  upper(tarih_araligi),
  isempty(tarih_araligi),
  range_merge(r1, r2)
FROM etkinlik;
```

### EN: RANGE Type
See examples above.

---

## 17. WINDOW FUNCTIONS / PENCERE FONKSİYONLARI

### TR
```sql
SELECT
  ad,
  fiyat,
  kategori_id,
  
  -- Sıralama / Ranking
  ROW_NUMBER() OVER (ORDER BY fiyat DESC) AS sira,
  RANK() OVER (ORDER BY fiyat DESC) AS rütbe,
  DENSE_RANK() OVER (ORDER BY fiyat DESC) AS yoğun_rütbe,
  NTILE(4) OVER (ORDER BY fiyat DESC) AS çeyrek,
  
  -- Toplama / Aggregate
  AVG(fiyat) OVER (PARTITION BY kategori_id) AS ort_kategori,
  SUM(fiyat) OVER (PARTITION BY kategori_id) AS toplam_kategori,
  COUNT(*) OVER (PARTITION BY kategori_id) AS adet_kategori,
  
  -- Kaydırma / Lead-Lag
  LAG(fiyat) OVER (ORDER BY id) AS onceki_fiyat,
  LEAD(fiyat) OVER (ORDER BY id) AS sonraki_fiyat,
  FIRST_VALUE(ad) OVER (PARTITION BY kategori_id ORDER BY fiyat) AS en_ucuz,
  LAST_VALUE(ad) OVER (PARTITION BY kategori_id ORDER BY fiyat) AS en_pahali
  
FROM urun
ORDER BY fiyat DESC;
```

### TR: RANGE / ROWS
```sql
SELECT
  ad,
  fiyat,
  AVG(fiyat) OVER (
    ORDER BY fiyat
    ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING  -- 5 satır penceresi
  ) AS kayan_ort
FROM urun;
```

### EN: Window Functions
See examples above.

---

## 18. EXPLAIN / ANALYZE (F-20)

### TR
```sql
-- Sorgu planını göster / Show query plan
EXPLAIN SELECT * FROM urun WHERE fiyat > 1000;

-- Gerçek çalıştırma süresi ile / With actual execution time
EXPLAIN ANALYZE SELECT * FROM urun WHERE fiyat > 1000;
```

### TR: Örnek Çıktı
```
Seq Scan on urun  (cost=0.00..100.00 rows=500 width=100)
  Filter: (fiyat > 1000)
  Rows Removed by Filter: 500
Execution Time: 0.123 ms
```

### TR: Paralel Sorgu (R-14)
```
Parallel Seq Scan on urun  (cost=0.00..25.00 rows=125 width=100)
  Workers: 4
```

### EN: EXPLAIN / ANALYZE
See examples above.

---

## 19. WAL (WRITE-AHEAD LOGGING)

### TR: API (SQL değil)
WAL yönetimi SQL ile değil, API ile yapılır (`VDbWal*` fonksiyonları).

```pascal
// Otomatik WAL
VdbWalSetAuto(h, 1);  // Aç
VdbWalSetAuto(h, 0);  // Kapat

// Manuel WAL
VdbWalWrite(h, ...);
VdbWalReplay(h);
VdbWalCheckpoint(h);
```

### TR: `SELECT ... AS OF SEQUENCE`
```sql
-- WAL geçmişinden oku / Read from WAL history
SELECT * FROM musteri AS OF SEQUENCE 12345;
```

### TR: Time Travel
```sql
-- Belirli bir zamandaki değeri oku / Read value at specific time
SELECT VdbValueAt(''musteri'', 1, 12345) FROM RDB$DATABASE;
```

### EN: WAL
See examples above.

---

## 20. TIME TRAVEL / CDC

### TR: CDC (Change Data Capture)
```pascal
VdbCdcStart(h);
// ~50ms'de bir WAL taranır
n := VdbCdcPollSize(h);
VdbCdcPoll(h, buf, n);  // Olayı oku ve tüket
VdbCdcStop(h);
```

### TR: Time Travel
```pascal
// Geçmişteki değeri oku
VdbValueAt(h, 'musteri', pk, seq, buf, len);
VdbHistoryCount(h);
```

### EN: CDC / Time Travel
See examples above.

---

## 21. ŞİFRELEME / ENCRYPTION

### TR
```sql
-- Parola belirle / Set password
ALTER DATABASE KEY 'gucluParola123!';

-- Parola değiştir / Change password
ALTER DATABASE KEY 'yeniGucluParola456!';

-- Parolayı kaldır / Remove password
ALTER DATABASE KEY '';
```

### TR: API
```pascal
VdbEncryptEnable(h, key, len);
VdbEncryptDisable(h);
VdbEncryptIsEncrypted(h);
VdbEncryptCreateKeyFile(h, path, pass);
VdbRekeyWithPassword(h, oldPass, newPass);
```

### TR: Güvenlik
- ✅ AES-256 (FIPS-197) kayıt seviyesinde şifreleme
- ✅ Parola-türetmeli anahtar (PBKDF2 benzeri)
- ✅ `.key` dosyası + `.bak` koruma
- ✅ Yanlış parola → net hata
- ✅ WAL replay + şifreleme tam uyumlu

### EN: Encryption
See examples above.

---

## 22. COLLATION (R-20)

### TR
```sql
-- Türkçe sıralama / Turkish sorting
SELECT * FROM musteri ORDER BY ad COLLATE ''tr'';

-- Doğal sıralama / Natural sorting (kn)
SELECT * FROM musteri ORDER BY ad COLLATE ''tr-TR-u-kn'';

-- Güç katmanları / Strength layers (ks)
SELECT * FROM musteri ORDER BY ad COLLATE ''tr-TR-u-kn-ks'';

-- Dil etiketleri / Language tags
COLLATE ''tr''     -- Türkçe
COLLATE ''ru''     -- Rusça
COLLATE ''de''     -- Almanca
COLLATE ''ja''     -- Japonca
COLLATE ''he''     -- İbranice
COLLATE ''ar''     -- Arapça
COLLATE ''zh''     -- Çince
COLLATE ''C''      -- Binary
COLLATE ''BINARY'' -- Binary
```

### TR: Seviyeler
- `-s1` → `-s4`: Güç katmanları (birincil, ikincil, üçüncül, dördüncül)
- `-u-kc`: Vurgu duyarlı
- `-u-kn`: Doğal sıralama (sayılar sayı olarak)

### EN: Collation
See examples above.

---

## 23. DESTEKLENMEYENLER / UNSUPPORTED

### TR
Bilerek desteklenmeyen özellikler:
- Stored Procedure (PL/pgSQL tam)
- Trigger (FOR EACH STATEMENT)
- Window frame (RANGE dışında)
- Full-text search
- Geospatial (GEOGRAPHY tipi)
- Sharding

### EN
Intentionally unsupported features:
- Full PL/pgSQL stored procedures
- Triggers (FOR EACH STATEMENT)
- Window frames (beyond RANGE)
- Full-text search
- Geospatial (GEOGRAPHY type)
- Sharding

---

## 24. PERFORMANS İPUÇLARI / PERFORMANCE TIPS

### TR
1. **İndeks kullanın:** Sık sorgulanan kolonlara indeks ekleyin
2. **WHERE clause:** İndeksli kolonlar kullanın
3. **SELECT *:** Sadece gereken kolonları seçin
4. **LIMIT:** Büyük result set'lerde sayfalama yapın
5. **EXPLAIN ANALYZE:** Sorgu planını kontrol edin
6. **Transaction:** Toplu işlemlerde transaction kullanın
7. **Partial index:** Küçük ve hızlı indeksler
8. **Expression index:** Hesaplanan değerler için

### EN
Same tips as above.

---

## 25. HIZLI REFERANS / QUICK REFERENCE

### TR: En Çok Kullanılanlar
```sql
-- Sorgu / Query
SELECT * FROM tablo WHERE kolon = 'değer' ORDER BY kolon LIMIT 10;

-- Ekle / Insert
INSERT INTO tablo (kolon1, kolon2) VALUES ('değer1', 'değer2');

-- Güncelle / Update
UPDATE tablo SET kolon = 'yeni' WHERE id = 1;

-- Sil / Delete
DELETE FROM tablo WHERE id = 1;

-- Tablo oluştur / Create table
CREATE TABLE tablo (id INTEGER PRIMARY KEY, ad TEXT NOT NULL);

-- İndeks / Index
CREATE INDEX idx_ad ON tablo(ad);

-- Sayı / Count
SELECT COUNT(*) FROM tablo;

-- Birleştirme / Join
SELECT * FROM tablo1 t1 JOIN tablo2 t2 ON t1.id = t2.id;
```

### EN: Most Used
See above.

---

**Son güncelleme / Last updated:** 2026-10-14
**Sürüm / Version:** 2.0
**Kapsam / Scope:** R-01 → R-24 + F-xx (tümü tamamlandı / all complete)

---

## 26. İLGİLİ BELGELER / RELATED DOCUMENTS

### TR
- `README.md` — Proje özeti
- `KILAVUZ_TR_EN.md` — Kullanım kılavuzu
- `yol_haritasi.md` — Yol haritası (24 madde)
- `docs/01-MOTOR.md` — Motor birimleri
- `docs/02-DOSYA-FORMATI.md` — Dosya formatı
- `docs/03-API-DLL.md` — DLL API
- `DLL_KULLANIM.md` — DLL kullanım kılavuzu

### EN
Same related documents.

---

**Toplam Özellik / Total Features:**
- ✅ 24 yol haritası maddesi (R-01 → R-24)
- ✅ 20+ ek özellik (F-xx)
- ✅ 2224 test (sqltest)
- ✅ 57 DLL export
- ✅ AES-256 şifreleme
- ✅ TCP SQL sunucusu (R-12)