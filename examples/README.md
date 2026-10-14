# VDB Örnekleri / VDB Examples

> **TR:** Bu klasör, VDB veritabanı motorunun kullanımını gösteren 10 örnek program içerir. Her örnek, farklı bir özelliği demonstrate eder.
>
> **EN:** This folder contains 10 example programs demonstrating VDB database engine usage. Each example demonstrates a different feature.

---

## 📁 Örnekler / Examples

| # | Klasör / Folder | Açıklama / Description | Özellik / Feature |
|---|---|---|---|
| 01 | `01_basit_kullanim` | Temel kullanım / Basic usage | CREATE TABLE, INSERT, SELECT |
| 02 | `02_sql_sorgulari` | SQL sorguları / SQL queries | SELECT, WHERE, ORDER BY, GROUP BY, JOIN |
| 03 | `03_crud_islemleri` | CRUD işlemleri / CRUD operations | INSERT, SELECT, UPDATE, DELETE |
| 04 | `04_transaction` | Transaction yönetimi / Transaction management | BEGIN, COMMIT, ROLLBACK, SAVEPOINT |
| 05 | `05_join_islemleri` | JOIN işlemleri / JOIN operations | INNER, LEFT, RIGHT, CROSS JOIN |
| 06 | `06_sifreleme` | Şifreleme / Encryption | AES-256, Password |
| 07 | `07_tcp_sunucu` | TCP SQL sunucusu / TCP SQL server | R-12: Server |
| 08 | `08_tcp_istemci` | TCP SQL istemcisi / TCP SQL client | R-12: Client, Login, Prepare |
| 09 | `09_json_veri` | JSON işlemleri / JSON operations | JSONB, ?, @>, -> operators |
| 10 | `10_ileri_ozellikler` | İleri özellikler / Advanced features | Trigger, View, Window Functions, CTE |

---

## 🚀 Nasıl Çalıştırılır / How to Run

### TR
Her örnek bağımsız bir Lazarus konsol programıdır. Derlemek için:

```bash
# Örnek 1'i derle / Build example 1
cd examples/01_basit_kullanim
lazbuild ornek01.lpi

# Çalıştır / Run
ornek01.exe
```

veya tüm örnekleri derlemek için:

```bash
# Proje dosyalarını oluştur / Create project files
# (Her örnek için .lpi dosyası gerekli)

# veya doğrudan FPC ile / Or with FPC directly
fpc ornek01.lpr
```

### EN
Each example is a standalone Lazarus console program. To build:

```bash
# Build example 1
cd examples/01_basit_kullanim
lazbuild ornek01.lpi

# Run
ornek01.exe
```

---

## 📋 Örnek Açıklamaları / Example Descriptions

### 01 — Basit Kullanım / Basic Usage
**TR:** VDB'nin en temel kullanımını gösterir: veritabanı oluşturma, tablo oluşturma, veri ekleme ve okuma.
**EN:** Shows the most basic VDB usage: creating a database, creating a table, inserting and reading data.

**Özellikler / Features:**
- ✅ `CREATE TABLE`
- ✅ `INSERT INTO`
- ✅ `SELECT`
- ✅ `AUTOINCREMENT`

---

### 02 — SQL Sorguları / SQL Queries
**TR:** VDB'nin desteklediği SQL sorgularını demonstrate eder.
**EN:** Demonstrates SQL queries supported by VDB.

**Özellikler / Features:**
- ✅ `SELECT` (temel / basic)
- ✅ `WHERE` (filtreleme / filtering)
- ✅ `ORDER BY` (sıralama / sorting)
- ✅ `GROUP BY` + `HAVING`
- ✅ `JOIN`
- ✅ Subquery (alt sorgu)

---

### 03 — CRUD İşlemleri / CRUD Operations
**CRUD** = **C**reate, **R**ead, **U**pdate, **D**elete

**TR:** Temel CRUD işlemlerini gösterir.
**EN:** Demonstrates basic CRUD operations.

**Özellikler / Features:**
- ✅ `INSERT` (Create)
- ✅ `SELECT` (Read)
- ✅ `UPDATE` (Update)
- ✅ `DELETE` (Delete)

---

### 04 — Transaction Yönetimi / Transaction Management
**TR:** Transaction işlemlerini gösterir: BEGIN/COMMIT, ROLLBACK, SAVEPOINT.
**EN:** Demonstrates transaction management: BEGIN/COMMIT, ROLLBACK, SAVEPOINT.

**Özellikler / Features:**
- ✅ `BEGIN`
- ✅ `COMMIT`
- ✅ `ROLLBACK`
- ✅ `SAVEPOINT`
- ✅ Nested transaction (iç içe)

---

### 05 — JOIN İşlemleri / JOIN Operations
**TR:** JOIN türlerini gösterir.
**EN:** Demonstrates JOIN types.

**Özellikler / Features:**
- ✅ `INNER JOIN`
- ✅ `LEFT JOIN`
- ✅ `RIGHT JOIN`
- ✅ `CROSS JOIN`
- ✅ Self JOIN

---

### 06 — Şifreleme / Encryption
**TR:** AES-256 şifrelemeyi gösterir.
**EN:** Demonstrates AES-256 encryption.

**Özellikler / Features:**
- ✅ Parola ile veritabanı / Database with password
- ✅ Şifreli veri / Encrypted data
- ✅ Parola değiştirme / Password change

---

### 07 — TCP SQL Sunucusu / TCP SQL Server (R-12)
**TR:** TCP SQL sunucusunu gösterir.
**EN:** Demonstrates TCP SQL server.

**Özellikler / Features:**
- ✅ Sunucu başlatma / Start server
- ✅ Port dinleme / Listen on port
- ✅ İstemci kabul / Accept clients
- ✅ `FMaxConns` (4 bağlantı / 4 connections)

---

### 08 — TCP SQL İstemcisi / TCP SQL Client (R-12)
**TR:** TCP SQL istemcisini gösterir.
**EN:** Demonstrates TCP SQL client.

**Özellikler / Features:**
- ✅ `Connect` (bağlan)
- ✅ `Login` / `Logout`
- ✅ `Exec` (SQL çalıştır)
- ✅ `Prepare` / `ExecutePrepared`

---

### 09 — JSON İşlemleri / JSON Operations
**TR:** JSON desteklerini gösterir.
**EN:** Demonstrates JSON support.

**Özellikler / Features:**
- ✅ `JSONB` veri tipi
- ✅ `?` operatörü (anahtar arama)
- ✅ `@>` operatörü (içerme)
- ✅ `->` operatörü (değer çıkarma)

---

### 10 — İleri Özellikler / Advanced Features
**TR:** İleri özellikleri demonstrate eder.
**EN:** Demonstrates advanced features.

**Özellikler / Features:**
- ✅ `TRIGGER` (tetikleyici)
- ✅ `VIEW` (görünüm)
- ✅ Window Functions (`ROW_NUMBER`, `SUM OVER`, `AVG OVER`)
- ✅ CTE (`WITH` clause)
- ✅ Recursive CTE

---

## 🛠️ Gereksinimler / Requirements

### TR
- Lazarus 4.6+ veya Free Pascal 3.2.4
- VDB motor birimleri (ana dizinde)
- DCPcrypt (şifreleme için)

### EN
- Lazarus 4.6+ or Free Pascal 3.2.4
- VDB engine units (in main directory)
- DCPcrypt (for encryption)

---

## 📝 Notlar / Notes

### TR
1. Her örnek bağımsızdır ve tek başına çalışır
2. Örnekler `.odb` dosyaları oluşturur (test verisi)
3. TCP örnekleri (07, 08) birlikte çalıştırılmalı
4. Örneklerde hata yönetimi basitleştirilmiştir

### EN
1. Each example is standalone
2. Examples create `.odb` files (test data)
3. TCP examples (07, 08) should be run together
4. Error handling is simplified in examples

---

## 📚 İlgili Belgeler / Related Documents

### TR
- `README.md` — Proje özeti
- `KILAVUZ_TR_EN.md` — Kullanım kılavuzu
- `SQL_TR_EN.md` — SQL referansı
- `docs/03-API-DLL.md` — DLL API

### EN
Same related documents.

---

**Son güncelleme / Last updated:** 2026-10-14
**Toplam örnek / Total examples:** 10