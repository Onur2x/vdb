# VDB KULLANIM KILAVUZU / VDB USAGE GUIDE

> **TR:** Bu kılavuz, VDB veritabanı motorunu kullanmak için ihtiyacınız olan tüm bilgileri içerir: kurulum, temel kullanım, ileri özellikler, sorun giderme ve en iyi uygulamalar.
>
> **EN:** This guide contains everything you need to use the VDB database engine: installation, basic usage, advanced features, troubleshooting, and best practices.

---

## 📑 İÇİNDEKİLER / TABLE OF CONTENTS

1. [Giriş / Introduction](#1-giriş--introduction)
2. [Kurulum / Installation](#2-kurulum--installation)
3. [Temel Kullanım / Basic Usage](#3-temel-kullanım--basic-usage)
4. [SQL Komutları / SQL Commands](#4-sql-komutları--sql-commands)
5. [Veri Tipleri / Data Types](#5-veri-tipleri--data-types)
6. [İlişkiler ve JOIN / Relationships and JOIN](#6-i̇lişkiler-ve-join--relationships-and-join)
7. [Transaction Yönetimi / Transaction Management](#7-transaction-yönetimi--transaction-management)
8. [Şifreleme / Encryption](#8-şifreleme--encryption)
9. [TCP SQL Sunucusu / TCP SQL Server](#9-tcp-sql-sunucusu--tcp-sql-server)
10. [DLL API Kullanımı / DLL API Usage](#10-dll-api-kullanımı--dll-api-usage)
11. [İleri Özellikler / Advanced Features](#11-ileri-özellikler--advanced-features)
12. [Performans İpuçları / Performance Tips](#12-performans-i̇puçları--performance-tips)
13. [Sorun Giderme / Troubleshooting](#13-sorun-giderme--troubleshooting)
14. [Sıkça Sorulan Sorular / FAQ](#14-sıkça-sorulan-sorular--faq)

---

## 1. GİRİŞ / INTRODUCTION

### TR: VDB Nedir?
VDB, Free Pascal ile yazılmış, harici bağımlılığı olmayan, tek dosyada çalışan bir ilişkisel veritabanı motorudur. Aşağıdaki senaryolar için idealdir:

- ✅ Masaüstü uygulamaları (tek kullanıcı, sıfır kurulum)
- ✅ Gömülü / IoT cihazları (düşük kaynak, crash-safe)
- ✅ Küçük web uygulamaları (düşük eşzamanlılık)
- ✅ Analitik / OLAP iş yükleri (paralel sorgu, bölümleme)
- ✅ SQLite alternatifi (daha fazla SQL özelliği)

### EN: What is VDB?
VDB is a relational database engine written in Free Pascal with zero external dependencies. It runs in a single file and is ideal for:
- Desktop applications (single user, zero installation)
- Embedded / IoT devices (low resource, crash-safe)
- Small web applications (low concurrency)
- Analytical / OLAP workloads (parallel query, partitioning)
- SQLite alternative (more SQL features)

---

## 2. KURULUM / INSTALLATION

### TR: Gereksinimler
1. **Lazarus 4.6+** (veya sadece Free Pascal Compiler 3.2.4)
2. **DCPcrypt** kütüphanesi (`dcpcrypt/` klasöründe, şifreleme için)
3. Windows, Linux veya macOS

### TR: Derleme Adımları
```bash
# 1. Depoyu klonlayın / Clone repository
git clone <repo-url>
cd veritabani

# 2. Test paketini derleyin / Build test suite
lazbuild -B sqltest.lpi

# 3. Testleri çalıştırın / Run tests
sqltest.exe  # Windows
./sqltest    # Linux/macOS

# 4. DLL API derleyin / Build DLL API
lazbuild -B vdbapi.lpi
# Çıktı: vdbapi.dll (Windows) veya libvdbapi.so (Linux)

# 5. Sunucu derleyin / Build server
lazbuild -B vdbserver.lpi
```

### EN: Requirements & Build Steps
Same as above. See commands in the TR section.

---

## 3. TEMEL KULLANIM / BASIC USAGE

### TR: Pascal ile Veritabanı Oluşturma
```pascal
uses VDbSql;

var
  DB: TVSql;
  R: TSqlResult;
begin
  // Veritabanını oluştur/aç / Create/open database
  DB := TVSql.Create('satis.odb');
  try
    // Tablo oluştur / Create table
    DB.Exec('''
      CREATE TABLE musteri (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ad TEXT NOT NULL,
        email TEXT UNIQUE,
        telefon TEXT,
        kayit_tarihi DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    ''', R);

    // Veri ekle / Insert data
    DB.Exec('INSERT INTO musteri (ad, email) VALUES (''Ali Veli'', ''ali@example.com'')', R);
    DB.Exec('INSERT INTO musteri (ad, email) VALUES (''Ayşe Yılmaz'', ''ayse@example.com'')', R);

    // Sorgula / Query
    DB.Exec('SELECT id, ad, email FROM musteri ORDER BY ad', R);
    
    WriteLn('Toplam kayıt: ', R.Rows);
    for var i := 0 to R.Rows - 1 do
      WriteLn(R.Data[i][0], ' - ', R.Data[i][1], ' - ', R.Data[i][2]);

  finally
    DB.Free;
  end;
end;
```

### EN: Creating a Database with Pascal
```pascal
uses VDbSql;

var
  DB: TVSql;
  R: TSqlResult;
begin
  DB := TVSql.Create('sales.odb');
  try
    // Create table
    DB.Exec('''
      CREATE TABLE customer (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT UNIQUE,
        phone TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    ''', R);

    // Insert data
    DB.Exec('INSERT INTO customer (name, email) VALUES (''John Doe'', ''john@example.com'')', R);
    DB.Exec('INSERT INTO customer (name, email) VALUES (''Jane Smith'', ''jane@example.com'')', R);

    // Query
    DB.Exec('SELECT id, name, email FROM customer ORDER BY name', R);
    
    WriteLn('Total records: ', R.Rows);
    for var i := 0 to R.Rows - 1 do
      WriteLn(R.Data[i][0], ' - ', R.Data[i][1], ' - ', R.Data[i][2]);

  finally
    DB.Free;
  end;
end;
```

### TR: SQL Betiği Çalıştırma
```pascal
// Birden fazla SQL cümlesini tek seferde çalıştırın
// Run multiple SQL statements at once
DB.Exec('''
  BEGIN;
  INSERT INTO musteri (ad) VALUES (''Test 1'');
  INSERT INTO musteri (ad) VALUES (''Test 2'');
  UPDATE musteri SET email = 'test@test.com' WHERE ad = ''Test 1'';
  COMMIT;
''', R);
```

---

## 4. SQL KOMUTLARI / SQL COMMANDS

### TR: Veritabanı Yönetimi
```sql
-- Veritabanı oluştur / Create database
CREATE DATABASE satis;
CREATE DATABASE IF NOT EXISTS satis;

-- Veritabanı listele / List databases
LIST DATABASES;
SHOW DATABASES;

-- Veritabanı aç / Open database
OPEN DATABASE satis;
USE satis;

-- Veritabanı kapat / Close database
CLOSE DATABASE;

-- Veritabanı sil / Drop database
DROP DATABASE satis;
DROP DATABASE IF EXISTS satis;
DELETE DATABASE satis;

-- Yedekle / Backup
BACKUP TO 'yedek.odb';

-- Doğrula / Verify
VERIFY;

-- Şifre değiştir / Change password
ALTER DATABASE KEY 'yeniParola123';
```

### TR: Tablo Yönetimi
```sql
-- Tablo oluştur / Create table
CREATE TABLE urun (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ad TEXT NOT NULL,
  fiyat FLOAT CHECK (fiyat > 0),
  stok INTEGER DEFAULT 0,
  kategori_id INTEGER REFERENCES kategori(id),
  aktif BOOL DEFAULT true,
  kayit DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Tablo bilgisi / Table info
DESCRIBE urun;
SHOW CREATE TABLE urun;
SHOW TABLES;

-- Tablo değiştir / Alter table
ALTER TABLE urun ADD COLUMN aciklama TEXT;
ALTER TABLE urun DROP COLUMN aciklama;
ALTER TABLE urun RENAME COLUMN ad TO urun_adi;
ALTER TABLE urun ALTER COLUMN fiyat TYPE FLOAT;

-- Tablo sil / Drop table
DROP TABLE urun;
DROP TABLE IF EXISTS urun;

-- İndeks oluştur / Create index
CREATE INDEX idx_urun_ad ON urun(ad);
CREATE UNIQUE INDEX idx_urun_kod ON urun(kod);
CREATE INDEX idx_urun_fiyat ON urun(fiyat) WHERE fiyat > 1000;

-- İndeks sil / Drop index
DROP INDEX idx_urun_ad;
```

### EN: Database & Table Management
See SQL examples above. Full reference in `SQL.md`.

---

## 5. VERİ TİPLERİ / DATA TYPES

### TR: Temel Tipler
| Tip | Açıklama | Örnek |
|---|---|---|
| `INTEGER` | Tam sayı (-2^63 → 2^63-1) | `42` |
| `FLOAT` | Çift duyarlıklı ondalık | `3.14159` |
| `TEXT` | UTF-8 metin (sınırsız) | `'Merhaba Dünya'` |
| `BOOL` | Boolean | `true`, `false` |
| `DATE` | Tarih (YYYY-MM-DD) | `'2026-10-14'` |
| `DATETIME` | Tarih + saat | `'2026-10-14 15:30:00'` |
| `TIME` | Saat | `'15:30:00'` |
| `BLOB` | İkili veri (fotoğraf, belge) | `X'89504E47...'` |

### TR: İleri Tipler
| Tip | Açıklama | Örnek |
|---|---|---|
| `JSONB` | JSON (sorgulanabilir) | `'{"ad":"Ali","yas":30}'` |
| `XML` | XML (XPath destekli) | `'<kisi><ad>Ali</ad></kisi>'` |
| `RANGE` | Aralık (int, date, ts) | `'2026-01-01,2026-12-31)'` |

### EN: Data Types
See tables above. Full details in `SQL.md`.

---

## 6. İLİŞKİLER VE JOIN / RELATIONSHIPS AND JOIN

### TR: Foreign Key
```sql
CREATE TABLE kategori (
  id INTEGER PRIMARY KEY,
  ad TEXT NOT NULL
);

CREATE TABLE urun (
  id INTEGER PRIMARY KEY,
  ad TEXT NOT NULL,
  kategori_id INTEGER REFERENCES kategori(id) ON DELETE CASCADE ON UPDATE CASCADE
);
```

### TR: JOIN Türleri
```sql
-- INNER JOIN / İç birleştirme
SELECT u.ad, k.ad AS kategori
FROM urun u
INNER JOIN kategori k ON u.kategori_id = k.id;

-- LEFT JOIN / Sol birleştirme
SELECT u.ad, k.ad AS kategori
FROM urun u
LEFT JOIN kategori k ON u.kategori_id = k.id;

-- CROSS JOIN / Çapraz birleştirme
SELECT u.ad, k.ad
FROM urun u
CROSS JOIN kategori k;

-- NATURAL JOIN / Doğal birleştirme
SELECT *
FROM urun
NATURAL JOIN kategori;

-- USING
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

### EN: JOIN Types
See examples above.

---

## 7. TRANSACTION YÖNETİMİ / TRANSACTION MANAGEMENT

### TR: Temel Transaction
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

ROLLBACK TO sp1;  -- 2. ve 3. kaydı geri alır, 1. kayıt kalır

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
```pascal
// TVSql varsayılan olarak otomatik transaction kullanır
// Birden fazla cümleyi tek fsync'te çalıştırır (hızlı!)
DB.Exec('''
  INSERT INTO musteri (ad) VALUES (''A'');
  INSERT INTO musteri (ad) VALUES (''B'');
  INSERT INTO musteri (ad) VALUES (''C'');
''', R);  // Tek transaction, tek fsync

// Kapatmak için / To disable:
DB.AutoTransaction := False;
```

---

## 8. ŞİFRELEME / ENCRYPTION

### TR: Parola Belirleme
```sql
-- Yeni veritabanını parolala / Encrypt new database
ALTER DATABASE KEY 'gucluParola123!';

-- Parola değiştir / Change password
ALTER DATABASE KEY 'yeniGucluParola456!';

-- Parolayı kaldır (şifreleme devre dışı) / Remove password
ALTER DATABASE KEY '';
```

### TR: Şifreli Veritabanını Açma
```pascal
// Parola ile aç / Open with password
DB := TVSql.Create('satis.odb');
DB.Password := 'gucluParola123!';  // Parola ata
DB.Open;  // Aç
```

### TR: Güvenlik Notları
- ✅ **AES-256** (FIPS-197) kayıt seviyesinde şifreleme
- ✅ Parola-türetmeli anahtar (PBKDF2 benzeri)
- ✅ `.key` dosyası otomatik oluşturulur, `.bak` yedeği korunur
- ✅ Yanlış parola ile açma → net hata mesajı
- ✅ WAL replay + şifreleme tam uyumlu
- ✅ Parola değiştirme (re-key) destekli

**⚠️ Uyarı:** Parolanızı kaybederseniz verilere erişemezsiniz! Güvenli yerde saklayın.

### EN: Encryption
See above. AES-256 record-level encryption with password-derived keys.

---

## 9. TCP SQL SUNUCUSU / TCP SQL SERVER

### TR: Sunucu Başlatma
```pascal
uses VDbSqlServer;

var
  Srv: TVdbSqlServer;
  Err: string;
begin
  // Sunucu oluştur / Create server
  Srv := TVdbSqlServer.Create('D:\veritabani\db', 54720);
  try
    // Başlat / Start
    if not Srv.Start(Err) then
    begin
      WriteLn('Hata: ', Err);
      Exit;
    end;
    
    WriteLn('Sunucu 54720 portunda çalışıyor...');
    
    // Çıkmak için bekle / Wait
    ReadLn;
    
  finally
    Srv.Free;
  end;
end;
```

### TR: İstemci Bağlantısı
```pascal
uses VDbClientNet;

var
  Cl: TVdbNetClient;
  R: TSqlResult;
  Ok: Boolean;
begin
  Cl := TVdbNetClient.Create;
  try
    // Bağlan / Connect
    if not Cl.Connect('127.0.0.1', 54720) then
    begin
      WriteLn('Bağlantı hatası');
      Exit;
    end;
    
    // Giriş yap / Login
    Ok := Cl.Login('admin', 'admin123');
    if not Ok then
    begin
      WriteLn('Giriş başarısız');
      Exit;
    end;
    
    // Sorgu çalıştır / Execute query
    R := Cl.Exec('SELECT 1+1');
    WriteLn('Sonuç: ', R.Data[0][0]);
    
    // Prepared statement (R-108)
    if Cl.Prepare('SELECT ad FROM musteri WHERE id = ?') then
    begin
      R := Cl.ExecutePrepared([1]);
      WriteLn('Müşteri: ', R.Data[0][0]);
    end;
    
    // Çıkış yap / Logout
    Cl.Logout;
    
  finally
    Cl.Free;
  end;
end;
```

### TR: Havuz / Kapasite (R-109)
- Varsayılan `FMaxConns = 4` (eşzamanlı bağlantı)
- 5. istemci → "kapasite dolu" hatası
- Her bağlantı bir havuz-slot'una eşlenir

### EN: TCP SQL Server
See examples above. Supports Login/Logout, Prepared Statements, and connection pooling (max 4 concurrent connections).

---

## 10. DLL API KULLANIMI / DLL API USAGE

### TR: C/Delphi İçin
```c
// vdbapi.h (veya doğrudan çağrı)
#include <windows.h>

typedef int (*VdbOpenFunc)(const char* dbPath);
typedef int (*VdbExecFunc)(const char* sql, int* resultHandle);
typedef int (*VdbGetFunc)(int resHandle, int row, int col, char* buf, int bufLen);
typedef void (*VdbCloseFunc)(int dbHandle);

// DLL yükle / Load DLL
HINSTANCE hLib = LoadLibrary("vdbapi.dll");
VdbOpenFunc VdbOpen = (VdbOpenFunc)GetProcAddress(hLib, "VdbOpen");
VdbExecFunc VdbExec = (VdbExecFunc)GetProcAddress(hLib, "VdbExec");
VdbGetFunc VdbGet = (VdbGetFunc)GetProcAddress(hLib, "VdbGet");
VdbCloseFunc VdbClose = (VdbCloseFunc)GetProcAddress(hLib, "VdbClose");

// Kullan / Use
int db = VdbOpen("satis.odb");
int res;
VdbExec("SELECT ad FROM musteri", &res);

char buf[256];
VdbGet(res, 0, 0, buf, sizeof(buf));
printf("İlk kayıt: %s\n", buf);

VdbClose(db);
FreeLibrary(hLib);
```

### TR: 57 Export Fonksiyon
Tam liste için `docs/03-API-DLL.md` dosyasına bakın.

**Öne çıkanlar:**
- `VdbOpen` / `VdbClose` — veritabanı yönetimi
- `VdbExec` — SQL çalıştırma
- `VdbGet` — sonuç okuma (2 aşamalı)
- `VdbWal*` — WAL yönetimi
- `VdbEncrypt*` — şifreleme
- `VdbCdc*` — Change Data Capture
- `VdbValueAt` — Time Travel

---

## 11. İLERİ ÖZELLİKLER / ADVANCED FEATURES

### TR: Trigger (R-05)
```sql
CREATE TRIGGER musteri_log
AFTER INSERT ON musteri
FOR EACH ROW
BEGIN
  INSERT INTO log (tablo, islem, kayit_id)
  VALUES (''musteri'', ''INSERT'', NEW.id);
END;

-- Tetikleyici sil / Drop trigger
DROP TRIGGER musteri_log;
```

### TR: View (R-06)
```sql
CREATE VIEW aktif_musteri AS
SELECT id, ad, email
FROM musteri
WHERE aktif = true;

-- View üzerinden sorgu / Query through view
SELECT * FROM aktif_musteri;

-- Materialized View (R-07)
CREATE MATERIALIZED VIEW musteri_ozet AS
SELECT kategori_id, COUNT(*) AS adet
FROM urun
GROUP BY kategori_id;

REFRESH MATERIALIZED VIEW musteri_ozet;
```

### TR: Stored Procedure (R-08)
```sql
CREATE FUNCTION toplam_fiyat(kategori_id INTEGER)
RETURNS FLOAT
LANGUAGE SQL
AS $$
  SELECT SUM(fiyat) FROM urun WHERE urun.kategori_id = $1;
$$;

-- Çağır / Call
SELECT toplam_fiyat(1);
```

### TR: Window Functions
```sql
SELECT
  ad,
  fiyat,
  ROW_NUMBER() OVER (ORDER BY fiyat DESC) AS sira,
  RANK() OVER (PARTITION BY kategori_id ORDER BY fiyat DESC) AS sira_kategori,
  AVG(fiyat) OVER (PARTITION BY kategori_id) AS ort_fiyat
FROM urun;
```

### TR: Common Table Expressions (CTE)
```sql
-- Basit CTE
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
```

### TR: JSONB Sorgulama (F-22)
```sql
-- JSON içinde arama / Search in JSON
SELECT *
FROM musteri
WHERE ayarlar ? 'tema';  -- 'tema' anahtarı var mı?

-- JSON değerini karşılaştır / Compare JSON value
SELECT *
FROM musteri
WHERE ayarlar @> '{"tema":"koyu"}';  -- İçeriyor mu?

-- JSON değeri çıkart / Extract JSON value
SELECT
  ad,
  ayarlar -> 'tema' AS tema,
  ayarlar -> 'bildirim' AS bildirim
FROM musteri;
```

### TR: RANGE Tipi (F-25)
```sql
-- Aralık sorgusu / Range query
SELECT *
FROM etkinlik
WHERE tarih_araligi @> '2026-10-14'::date;

-- Aralık kesişimi / Range intersection
SELECT *
FROM etkinlik
WHERE tarih_araligi && '[2026-10-01,2026-10-31)'::daterange;
```

### TR: EXPLAIN / ANALYZE
```sql
-- Sorgu planını göster / Show query plan
EXPLAIN SELECT * FROM urun WHERE fiyat > 1000;

-- Gerçek çalıştırma süresi ile / With actual execution time
EXPLAIN ANALYZE SELECT * FROM urun WHERE fiyat > 1000;
```

---

## 12. PERFORMANS İPUÇLARI / PERFORMANCE TIPS

### TR: İndeks Kullanımı
```sql
-- Sık sorgulanan kolonlara indeks ekleyin
CREATE INDEX idx_musteri_email ON musteri(email);
CREATE INDEX idx_urun_kategori ON urun(kategori_id, fiyat);

-- Partial index (daha küçük, daha hızlı)
CREATE INDEX idx_aktif ON musteri(id) WHERE aktif = true;

-- Expression index (hesaplanan değerler)
CREATE INDEX idx_tam_ad ON musteri(lower(ad || ' ' || soyad));
```

### TR: Toplu İşlemler
```pascal
// Toplu ekleme için transaction kullanın
DB.Exec('BEGIN', R);
for i := 1 to 10000 do
  DB.Exec('INSERT INTO log (mesaj) VALUES (''Kayıt ' + IntToStr(i) + ''')', R);
DB.Exec('COMMIT', R);

// veya otomatik transaction (daha hızlı!)
// Birden fazla cümleyi tek seferde gönderin
```

### TR: Sorgu Optimizasyonu
- ✅ `WHERE` clause'unda indeksli kolonlar kullanın
- ✅ `SELECT *` yerine sadece gereken kolonları seçin
- ✅ `LIKE '%...%'` yerine tam eşleşme veya indeks kullanın
- ✅ Büyük veri setlerinde `LIMIT` kullanın
- ✅ `EXPLAIN ANALYZE` ile planı kontrol edin

---

## 13. SORUN GİDERME / TROUBLESHOOTING

### TR: Sık Karşılaşılan Sorunlar

| Sorun | Çözüm |
|---|---|
| `Veritabanı dosyası açılamıyor` | Dosya yolunu kontrol edin, başka bir program açık olmasın |
| `Tablo zaten var` | `CREATE TABLE IF NOT EXISTS` kullanın veya önce `DROP TABLE` |
| `Yabancı anahtar hatası` | Referans edilen kayıt var mı kontrol edin, `ON DELETE CASCADE` ekleyin |
| `Parola yanlış` | `ALTER DATABASE KEY` ile parolayı sıfırlayın (yedekten geri yükleme gerekebilir) |
| `Kapasite dolu` (TCP) | `FMaxConns` değerini artırın veya bağlantıları kapatın |
| `Yavaş sorgu` | `EXPLAIN ANALYZE` çalıştırın, indeks ekleyin |
| `Bellek yetersiz` | `LIMIT` kullanın, büyük result set'leri sayfalayın |

### TR: Hata Kodları
Detaylı hata kodları için `VDbErr.pas` dosyasına veya `docs/01-MOTOR.md`'ye bakın.

---

## 14. SIKÇA SORULAN SORULAR / FAQ

### TR: VDB neden SQLite'dan farklı?
VDB, SQLite'a ek olarak şunları destekler:
- JSONB sorgulama (`?`, `@>`, `->`)
- Spatial veri tipleri (Point, Polygon)
- RANGE tipi
- Trigger + View + Stored Procedure
- Table Partitioning
- Parallel Query Execution
- Cost-Based Optimizer
- Streaming Replication (TCP)
- ICU Collation (Türkçe, Rusça, Japonca, vb.)

### TR: En büyük veri seti ne kadar olabilir?
Tek dosya `.odb` formatı ile pratikte milyonlarca kayıt. WAL + Incremental Backup ile daha büyük veri setleri için ölçeklenebilir.

### TR: Eşzamanlı erişim destekleniyor mu?
Evet, MVCC + Connection Pool ile. TCP SQL Sunucusu (R-12) ile eşzamanlı 4 bağlantı (varsayılan). Windows'ta dosya kilidi tek yazıcı kuralını zorlar.

### TR: Üretim ortamında kullanılabilir mi?
Evet. Test suite (%99.9+ yeşil), mutasyon testleri, crash-safe WAL, AES-256 şifreleme ile üretime hazır.

---

## 📞 DESTEK / SUPPORT

### TR
- **SQL Referansı:** `SQL.md`
- **Yol Haritası:** `yol_haritasi.md` (24 madde, tümü tamamlandı)
- **API Dokümantasyonu:** `docs/03-API-DLL.md`
- **Testler:** `sqltest.exe` çalıştırın
- **Sorunlar:** GitHub Issues

### EN
- **SQL Reference:** `SQL.md`
- **Roadmap:** `yol_haritasi.md` (24 items, all complete)
- **API Documentation:** `docs/03-API-DLL.md`
- **Tests:** Run `sqltest.exe`
- **Issues:** GitHub Issues

---

**Son güncelleme / Last updated:** 2026-10-14
**Sürüm / Version:** 2.0

---

## 📝 DEĞİŞİKLİK GÜNLÜĞÜ / CHANGELOG

### TR: 2026-10-14 (Bugün)
- ✅ README.md yeniden yazıldı (TR + EN)
- ✅ Kullanım kılavuzu oluşturuldu (bu dosya)
- ✅ Tüm yol haritası maddeleri tamamlandı (R-01 → R-24)
- ✅ R-12 TCP SQL Sunucusu tamamlandı (Auth + Prepared + Pool)
- ✅ Testler yeşil: 2224/2 (T107/T108/T109 OK)

### TR: 2026-10-13
- ✅ R-12 devam: T107 Auth/Oturum düzeltildi
- ✅ T108 Prepared Statement eklendi
- ✅ T109 Havuz-Kapasite testi eklendi
- ✅ Mutasyon testleri (3 kapı: FAIL→geri al→yeşil)
- ✅ `sqltest.exe` derlendi

### TR: 2026-10-12 ve öncesi
- ✅ R-01 → R-23 tamamlandı (tüm yol haritası)
- ✅ F-xx ek özellikler (ILIKE, JSONB, XML, Spatial, RANGE, vb.)
- ✅ Şifreleme (AES-256, FIPS-197)
- ✅ DLL API (57 export)
- ✅ Test suite: 2200+ test

### EN: 2026-10-14 (Today)
- ✅ README.md rewritten (TR + EN)
- ✅ Usage guide created (this file)
- ✅ All roadmap items completed (R-01 → R-24)
- ✅ R-12 TCP SQL Server completed (Auth + Prepared + Pool)
- ✅ Tests green: 2224/2 (T107/T108/T109 OK)

### EN: 2026-10-13
- ✅ R-12 continuation: T107 Auth/Session fixed
- ✅ T108 Prepared Statement added
- ✅ T109 Pool-Capacity test added
- ✅ Mutation tests (3 gates: FAIL→revert→green)
- ✅ `sqltest.exe` built

### EN: 2026-10-12 and earlier
- ✅ R-01 → R-23 completed (full roadmap)
- ✅ F-xx additional features (ILIKE, JSONB, XML, Spatial, RANGE, etc.)
- ✅ Encryption (AES-256, FIPS-197)
- ✅ DLL API (57 exports)
- ✅ Test suite: 2200+ tests