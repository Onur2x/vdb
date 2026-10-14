# VDb SQL Motoru — AST (Soyut Sözdizim Ağacı) Dönüşüm Planı

Bu belge, **VDb** SQL motorunun monolitik (ayrıştırma + çalıştırmanın iç içe olduğu) yapısından **AST (Abstract Syntax Tree)** tabanlı modern bir derleyici/yorumlayıcı mimarisine dönüştürülme adımlarını, mimari tasarımını ve mevcut durumunu içerir. 

> 📌 **Kota veya oturum kesintisi olursa:** Bu belgedeki **"4. Adım Adım Uygulama ve İlerleme Takibi"** tablosuna bakarak en son işaretli `[x]` adımından hemen sonraki `[ ]` adımından devam edilecektir.

---

## 1. Mimari Tasarım ve Hedefler

### 1.1 Mevcut Mimari (Monolitik)
```
SQL Metni ──> TVSql.ExecRaw (4300+ satır tek blok)
                ├── Token ayrıştırma
                ├── SQL mantığı doğrulama
                ├── Disk / Tablo okuma-yazma
                └── Sonuç kümesi oluşturma
```
* **Dezavantajları:** Token ayrıştırma ile çalıştırma iç içe; alt sorgu (subquery), CTE (`WITH ...`), sorgu optimizasyonu (query planner) ve hata konumlandırması eklemek aşırı zor ve riskli.

### 1.2 Hedef Mimari (AST Pipeline)
```
SQL Metni
    │
    ▼
┌────────────────────────┐
│      VDbParser.pas     │  Tokenizasyon + Sözdizimi Analizi (Syntax Analysis)
└───────────┬────────────┘
            │ Üretir (AST Ağacı)
            ▼
┌────────────────────────┐
│       VDbAst.pas       │  Tip Güvenli AST Düğüm Modeli (Statements & Expressions)
└───────────┬────────────┘
            │ Ağaç Gezintisi (Tree Walker / Visitor)
            ▼
┌────────────────────────┐
│     VDbExecutor.pas    │  Yürütücü (TVTableDb ve TVDb ile etkileşim)
└───────────┬────────────┘
            │ Üretir
            ▼
        TSqlResult
```
* **Avantajları:**
  1. **%100 Modülerlik:** Ayrıştırıcı sadece ağaç kurar; motor sadece ağacı çalıştırır.
  2. **Geriye Dönük Uyumluluk:** `VDbSql.pas` dışa açık cephe (facade) olarak kalır; `sqltest.exe`, `vdbgui.exe` ve `had.exe` hiçbir değişikliğe gerek duymadan çalışmaya devam eder.
  3. **V2 Özelliklerine Hazır:** Subquery (`WHERE x IN (SELECT ...)`), CTE, JOIN optimizasyonu gibi özellikler doğrudan AST düğümü olarak kolayca eklenebilir.
  4. **Bellek Güvenliği:** Her AST düğümü kendi alt ağacını serbest bırakan sanal `destructor`'a sahiptir (`Node.Free` tüm ağacı temizler).

---

## 2. Modül Yapısı ve Sınıf Hiyerarşisi

### 2.1 `VDbAst.pas` (Düğüm Tipleri)
* **Temel Düğüm:** `TSqlNode = class` (Sanal `destructor Destroy; override;`)
* **İfade Düğümleri (`TSqlExprNode`):**
  * `TSqlLiteralNode`: Sayısal, metin, boolean, null veya tarih sabitleri.
  * `TSqlColumnRefNode`: Kolon başvuruları (`col` veya `tbl.col`).
  * `TSqlBinaryOpNode`: İkili işlemler (`+`, `-`, `*`, `/`, `=`, `<>`, `>`, `<`, `>=`, `<=`, `LIKE`, `AND`, `OR`).
  * `TSqlUnaryOpNode`: Tekli işlemler (`NOT`, `-`, `IS NULL`, `IS NOT NULL`).
  * `TSqlInNode`: `IN (...)` ve `NOT IN (...)` listeleri.
  * `TSqlBetweenNode`: `BETWEEN a AND b` aralıkları.
  * `TSqlFunctionCallNode`: Toplama/fonksiyon çağrıları (`COUNT(*)`, `SUM(x)`, `AVG`, `MIN`, `MAX`).
* **Cümle Düğümleri (`TSqlStmtNode`):**
  * `TSqlSelectStmt`: Kolonlar, DISTINCT, FROM tablosu, JOIN (INNER/LEFT, ON), WHERE ifadesi, GROUP BY, HAVING, ORDER BY, LIMIT, OFFSET, Kümeler (UNION, EXCEPT, INTERSECT).
  * `TSqlInsertStmt`: Tablo adı, hedef kolonlar, `VALUES` listesi (çoklu satır destekli) veya `SELECT` kaynağı.
  * `TSqlUpdateStmt`: Tablo adı, `SET col = expr` atamaları, WHERE ifadesi.
  * `TSqlDeleteStmt`: Tablo adı, WHERE ifadesi.
  * `TSqlCreateTableStmt`: Tablo adı, `Cols: TColArray`, kısıtlar (PK, UNIQUE, CHECK, FOREIGN KEY).
  * `TSqlAlterTableStmt`: Tablo adı, eylem (ADD, DROP, RENAME, TYPE, DEFAULT, NOT NULL), parametreler.
  * `TSqlDropTableStmt`: Tablo adı, `IfExists: Boolean`.
  * `TSqlCreateIndexStmt`: İndeks adı, tablo adı, kolon adı.
  * `TSqlDropIndexStmt`: İndeks adı.
  * `TSqlTransactionStmt`: Türü (`BEGIN`, `COMMIT`, `ROLLBACK`).
  * `TSqlAdminStmt`: Veritabanı ve bakım komutları (`CREATE/DROP/OPEN DATABASE`, `VACUUM`, `REINDEX`, `VERIFY`, `SHOW TABLES`, `LIST DATABASES`).
  * `TSqlJsonStmt`: `EXPORT JSON` ve `IMPORT JSON`.

### 2.2 `VDbParser.pas` (Sözdizim Ayrıştırıcı)
* SQL betiğini alır, parametreleri (`?`) bağlar.
* Özyinelemeli iniş (Recursive-descent) tekniği ile token akışını AST cümle düğümlerine (`TSqlStmtNode`) dönüştürür.
* Sözdizim hatası durumunda token konumunu ve anlamlı hata mesajını fırlatır.

### 2.3 `VDbExecutor.pas` (Yürütücü)
* AST cümle düğümünü (`TSqlStmtNode`) ve `TVTableDb` referansını alır.
* İlgili tablo işlemlerini yürütür, filtreleri uygular ve `TSqlResult` üretir.
* Otomatik işlem (AutoTransaction) ve güvenli geri sarma (Rollback) mantığını yönetir.

---

## 3. Uygulama Stratejisi (Sıfır Kesinti & Sürekli Yeşil Testler)

Aşırı büyük bir kod tabanında doğrudan "her şeyi sil ve sıfırdan yaz" yaklaşımı testlerin bozulmasına yol açar. Bu yüzden **"Strangler Fig" (Kademeli Geçiş)** stratejisi uygulanacaktır:

1. **Aşama 1 (AST Model):** `VDbAst.pas` dosyası bağımsız olarak oluşturulur ve test edilir.
2. **Aşama 2 (Yürütücü Çekirdeği):** `VDbExecutor.pas` oluşturulur, AST düğümlerini `TVTableDb` çağrılarına dönüştüren metotlar yazılır.
3. **Aşama 3 (Ayrıştırıcı):** `VDbParser.pas` oluşturulur; DDL (CREATE/DROP/ALTER) ve DML (INSERT/UPDATE/DELETE/SELECT) cümlelerini parse eden mantık modüler olarak eklenir.
4. **Aşama 4 (TVSql Entegrasyonu):** `VDbSql.pas` içindeki `ExecRaw` kademeli olarak `VDbParser` + `VDbExecutor` ardışık düzenine yönlendirilir.
5. **Aşama 5 (Doğrulama & Temizlik):** `sqltest.lpr` (288 test) her adımda derlenip çalıştırılarak hiçbir regresyon olmadığı kanıtlanır.

---

## 4. Adım Adım Uygulama ve İlerleme Takibi

| Faz | Adım | Açıklama | Dosya(lar) | Durum |
|:---:|:---:|:---|:---|:---:|
| **Faz 1** | 1.1 | `AST_DONUSUM_PLANI.md` belgesinin oluşturulması | `AST_DONUSUM_PLANI.md` | [x] |
| **Faz 1** | 1.2 | `VDbAst.pas` unit'inin oluşturulması (Temel düğüm ve tüm İfade/Sabit düğümleri) | `VDbAst.pas` | [x] |
| **Faz 1** | 1.3 | `VDbAst.pas` içine Cümle Düğümlerinin eklenmesi (SELECT, INSERT, UPDATE, DDL vb.) | `VDbAst.pas` | [x] |
| **Faz 2** | 2.1 | `VDbExecutor.pas` unit'inin oluşturulması (DML ve DDL yürütme iskeleti) | `VDbExecutor.pas` | [x] |
| **Faz 2** | 2.2 | `VDbExecutor.pas` içinde İfade Çözümleyici (Expression Evaluator) tamamlanması | `VDbExecutor.pas` | [x] |
| **Faz 3** | 3.1 | `VDbParser.pas` oluşturulması: Tokenizer ve Temel İfade / WHERE Parser | `VDbParser.pas` | [x] |
| **Faz 3** | 3.2 | `VDbParser.pas`: DDL Parser (CREATE, ALTER, DROP, INDEX, ADMIN) | `VDbParser.pas` | [x] |
| **Faz 3** | 3.3 | `VDbParser.pas`: DML Parser (INSERT, UPDATE, DELETE, TX) | `VDbParser.pas` | [x] |
| **Faz 3** | 3.4 | `VDbParser.pas`: SELECT Parser (JOIN, GROUP BY, HAVING, ORDER, LIMIT, Kümeler) | `VDbParser.pas` | [x] |
| **Faz 4** | 4.1 | `VDbSql.pas` Facade entegrasyonu (Parser -> Executor hattına bağlama) | `VDbSql.pas` | [x] |
| **Faz 4** | 4.2 | Parametreli sorgu (`?`) ve betik ayrıştırma (`;`) entegrasyonu | `VDbSql.pas` | [x] |
| **Faz 5** | 5.1 | `sqltest.lpr` derleme ve 288+ testin eksiksiz yeşil olduğunu doğrulama | `sqltest.lpr` | [x] |
| **Faz 5** | 5.2 | GUI projelerinin (`vdbgui.lpi`, `had.lpi`) derleme ve çalışma doğrulaması | `vdbgui`, `had` | [x] |
| **Faz 5** | 5.3 | Eski kullanılmayan kodların temizliği ve mimari özet raporu | Proje geneli | [x] |

---

## 5. Kota Kesintisi Durumunda Kurtarma ve Devam Prosedürü

Eğer işlem sırasında oturum kesilirse veya kota biterse, yeni sohbette yapılması gerekenler:

1. `d:\veritabani\AST_DONUSUM_PLANI.md` dosyasını açıp yukarıdaki tabloda en son `[x]` olan adıma bakın.
2. Sıradaki `[ ]` adımını modele şu şekilde iletin:
   > *"AST dönüşüm planındaki Faz X Adım Y.Z üzerinden devam edelim."*
3. Her adım bitiminde `sqltest.exe` derlenip çalıştırılarak sistemin kararlılığı korunur.
