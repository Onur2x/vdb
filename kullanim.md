# VDB Kullanım Kılavuzu

Bu kılavuz motoru Pascal uygulamasından, DLL/C API'sinden ve SQL üzerinden
nasıl kullanacağınızı anlatır. Genel bakış için [readme_tr.md](readme_tr.md),
performans için [hiztesti.md](hiztesti.md).

---

## 1. Kurulum ve derleme

Gereksinimler:

- Lazarus 4.6+ / Free Pascal 3.2.4
- `dcpcrypt/` klasörü (depoda gelir)

```bash
# SQL test paketi
lazbuild -B sqltest.lpi

# DLL / C API
lazbuild -B vdbapi.lpi

# Linux/macOS kütüphane
./build_lib.sh
```

Üretilenler:

| Dosya | Açıklama |
|---|---|
| `sqltest.exe` | SQL test paketi |
| `vdbapi.dll` / `.so` | C/Delphi DLL API |

---

## 2. Pascal API — `TVSql`

`VDbSql` birimini kullanın. `TVSql.Exec` tek bir SQL metnini (veya `;` ile
ayrılmış birden fazla cümleyi) çalıştırır ve `TSqlResult` döndürür.

```pascal
uses VDbSql, VDbTypes;

var
  DB: TVSql;
  R: TSqlResult;
  i, j: Integer;
begin
  DB := TVSql.Create('D:\veri\uygulama.odb');
  try
    DB.Exec('CREATE TABLE musteri (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'ad TEXT NOT NULL, ' +
      'email TEXT UNIQUE, ' +
      'kayit DATETIME DEFAULT CURRENT_TIMESTAMP)', R);
  finally
    DB.Free;
  end;
end;
```

### Sonuç yapısı

| Alan | Anlamı |
|---|---|
| `R.Cols` | Kolon adları |
| `R.Rows` | Satır sayısı |
| `R.Data[i][j]` | Hücre değeri (metin) |
| `R.Affected` | Etkilenen satır sayısı (DML/DDL) |
| `R.Msg` | Sunucu/motor mesajı |

Değerler metin olarak taşınır. Sayı/tarih dönüşümünü uygulama yapar.

### Parametreli çalıştırma

Tek tırnak kaçırma derdi olmadan değer bağlayabilirsiniz:

```pascal
DB.ExecParams('INSERT INTO musteri (ad, email) VALUES (?, ?)',
  ['Ahmet', 'ahmet@example.com'], R);
```

### Transaction

```pascal
DB.Exec('BEGIN', R);
try
  DB.Exec('INSERT INTO musteri (ad) VALUES (''Ayşe'')', R);
  DB.Exec('UPDATE musteri SET email = ''a@x'' WHERE ad = ''Ayşe''', R);
  DB.Exec('COMMIT', R);
except
  DB.Exec('ROLLBACK', R);
  raise;
end;
```

`SAVEPOINT ad`, `ROLLBACK TO ad`, `RELEASE ad` desteklenir.

### MVCC / batch

```pascal
DB.BeginBatch;
try
  DB.Exec('INSERT INTO musteri (ad) VALUES (''Bekleyen'')', R);
  // Aynı batch içinde kendi yazımız görünür.
  DB.CommitBatch;
except
  DB.AbortBatch;
  raise;
end;
```

### WAL

```pascal
DB.WALEnabled := True;          // her yazımı .wal dosyasına da yaz
DB.ReplayWAL;                   // açılışta bekleyen günlüğü uygula
DB.CheckpointWAL;               // günlüğü ana dosyaya işle ve sil
```

`SyncWriteInterval = 0` (varsayılan) her commit'te senkron yazar; daha yüksek
değerler grup commit sağlar, çökme anında en fazla o kadar iş kaybolabilir.

### İndeksler

```sql
CREATE INDEX ix_musteri_ad ON musteri (ad);
CREATE UNIQUE INDEX ux_email ON musteri (email);
CREATE INDEX ix_kismi ON musteri (ad) WHERE ad IS NOT NULL;   -- partial
CREATE INDEX ix_ifade ON musteri (LOWER(ad));                 -- expression
CREATE INDEX ix_kapak ON musteri (ad) INCLUDE (email);        -- covering
CREATE INDEX CONCURRENTLY ix_online ON musteri (email);       -- online
```

İkincil indeksler H3 skiplist üzerinde tutulur. `COUNT(*)` ve aralık
sorguları indeksten O(log N) yararlanır; çok kolonlu indekste aralık yalnızca
leading kolona göre daraltılır, kalan koşullar satır üzerinde doğrulanır.

### İstatistik ve plan

```sql
ANALYZE musteri;
EXPLAIN SELECT * FROM musteri WHERE id = 5;
EXPLAIN ANALYZE SELECT * FROM musteri WHERE yas > 30;
SHOW STATS;
SHOW SLOW QUERIES;
```

---

## 3. SQL kullanımı

### Tablo ve veri

```sql
CREATE TABLE urun (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ad      TEXT NOT NULL,
  fiyat   FLOAT DEFAULT 0,
  stok    INTEGER DEFAULT 0,
  etiket  JSONB,
  kayit   DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO urun (ad, fiyat, stok) VALUES ('Laptop', 15000, 5);
INSERT INTO urun (ad, fiyat, stok) VALUES
  ('Mouse', 250, 40),
  ('Klavye', 600, 25);

SELECT ad, fiyat FROM urun
WHERE fiyat BETWEEN 200 AND 20000
ORDER BY fiyat DESC
LIMIT 10;

UPDATE urun SET stok = stok - 1 WHERE id = 1;
DELETE FROM urun WHERE stok = 0;
```

### JOIN ve alt sorgu

```sql
SELECT u.ad, s.adet
FROM urun u
JOIN satis s ON s.urun_id = u.id
WHERE s.tarih >= '2026-01-01';

SELECT ad FROM urun
WHERE fiyat > (SELECT AVG(fiyat) FROM urun);
```

### CTE ve pencere fonksiyonu

```sql
WITH pahali AS (
  SELECT * FROM urun WHERE fiyat > 1000
)
SELECT ad, fiyat,
       ROW_NUMBER() OVER (ORDER BY fiyat DESC) AS sira
FROM pahali;
```

### UPSERT ve RETURNING

```sql
INSERT INTO urun (id, ad, fiyat) VALUES (1, 'Laptop', 14000)
ON CONFLICT (id) DO UPDATE SET fiyat = excluded.fiyat
RETURNING id, ad, fiyat;
```

### JSONB

```sql
SELECT etiket -> 'renk' FROM urun;
SELECT * FROM urun WHERE etiket ? 'kampanya';
SELECT * FROM urun WHERE etiket @> '{"renk":"mavi"}';
```

### Range ve Spatial

```sql
SELECT * FROM rezervasyon
WHERE sure && '[2026-01-01, 2026-02-01)';

SELECT * FROM nokta
WHERE ST_Distance(konum, ST_Point(29.0, 41.0)) < 1000;
```

### Şifreleme

```sql
ALTER DATABASE KEY 'gucluParola123';       -- ilk parola
ALTER DATABASE KEY 'yeniGucluParola456';   -- rotasyon
```

Parola `.key` dosyasına türetilir; `.bak` yedeği korunur. Anahtarsız veya
yanlış anahtarla okuma sessizce bozuk veri döndürmez, hata verir.

### RBAC ve RLS

```sql
CREATE ROLE okuyucu;
GRANT SELECT ON musteri TO okuyucu;
SET ROLE okuyucu;

ALTER TABLE musteri ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_self ON musteri FOR SELECT USING (sahip = current_user());
```

### Bakım ve yedek

```sql
BACKUP DATABASE TO 'D:\yedek\uygulama-yedek.odb';
COMPACT;
RESTORE FROM 'D:\yedek\uygulama-yedek.odb';
ARCHIVE WAL SET DIR = 'D:\arsiv';
RECOVER;
```

---

## 4. TCP SQL sunucusu

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
        R := Cl.Exec('SELECT COUNT(*) FROM musteri');
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

Sunucu VDBS protokolünü konuşur; hazırlanmış sorgu (`Prepare` /
`ExecutePrepared`) ve connection pool desteklenir. Ayrıca PostgreSQL wire
protokolü (`VDbPgWire`) ile basit ve genişletilmiş sorgu akışı sunulur.

---

## 5. DLL / C API

`vdbapi.dll` (Linux: `libvdbapi.so`) 57 fonksiyon dışa aktarır.

```pascal
function VdbOpen(const DbPath: PAnsiChar): Integer; stdcall;
function VdbExec(const Sql: PAnsiChar; var ResultHandle: Integer): Integer; stdcall;
function VdbGet(ResHandle, Row, Col: Integer; Buf: PAnsiChar; BufLen: Integer): Integer; stdcall;
procedure VdbClose(DbHandle: Integer); stdcall;
```

C tarafında:

```c
#include "vdbapi.h"

int db = VdbOpen("veritabani.odb");
int res = 0;
VdbExec("SELECT 1+1", &res);
char buf[64];
VdbGet(res, 0, 0, buf, sizeof(buf));
VdbClose(db);
```

Kurallar:

- Tüm metinler UTF-8'dir.
- `VdbGet` iki aşamalıdır: önce tampon boyutu sorgulanır, sonra değer alınır.
- Aynı veritabanı aynı anda tek programda açılmalıdır.
- 32-bit DLL ile 32-bit uygulama eşleşmelidir.

---

## 6. Sık karşılaşılan durumlar

| Belirti | Çözüm |
|---|---|
| `tablo yok: x` | Önce `CREATE TABLE x` çalıştırın |
| `UNIQUE ihlali` | Aynı değer zaten var; `UPSERT` kullanın |
| `RLS politika ihlali` | Rolün politikası yazılan satırı kapsamıyor |
| `yetkisiz: ...` | `GRANT` ile izin verin veya `SET ROLE NONE` |
| `anahtarsız okuma` | `.key` parolasını `OpenKeyFile` ile açın |
| `AS OF ... desteklenmiyor` | WAL kapalı veya checkpoint geçmişi silmiş |

---

## 7. Örnekler

Örnek projeler bu depoda tutulmaz; desteklenen içerik motor birimleri,
`vdbapi` ve `sqltest` paketidir.

---

## 8. Testler

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

Beklenen son çıktı: `SONUC: gecen=2755 kalan=0`.
