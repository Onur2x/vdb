# VDB — İlişkisel Veritabanı Motoru

VDB (VeriTabanı), Free Pascal ile yazılmış, harici bir DLL gerektirmeyen,
tek dosyada (`.odb`) çalışan ilişkisel veritabanı motorudur. Masaüstü ve gömülü
uygulamalar için SQLite'a alternatif olarak geliştirilmiştir.

> Bu dosya `dokuman/` klasöründedir ve bilerek Git'e eklenmez.
> İngilizce sürüm: [readme.md](readme.md)

---

## Öne çıkanlar

- Tek dosya depolama (`.odb`), ayrı sunucu kurulumu gerekmez.
- Zengin SQL: JOIN, alt sorgu, CTE, pencere fonksiyonları, `UPSERT`,
  `RETURNING`, trigger, view, stored procedure.
- MVCC / snapshot isolation, `SAVEPOINT`, `DEFERRABLE` kısıtlar.
- WAL, otomatik WAL, checkpoint, PITR, streaming replication.
- AES-256 kayıt seviyesi şifreleme, `.key` dosyası ve parola rotasyonu.
- JSONB, XML/XPath, Spatial, Range tipleri.
- HASH / RANGE / LIST bölümleme ve partition pruning.
- Paralel sorgu, cost-based optimizer (`ANALYZE` + `EXPLAIN`).
- H3 skiplist ikincil indeks; indeksli `COUNT(*)` O(log N).
- TCP SQL sunucusu/istemcisi, connection pool.
- RBAC, row level security, ICU uyumlu collation.
- 57 exportlu C/Delphi DLL API'si (`vdbapi`).
- `SHOW STATS`, `/metrics`, OpenTelemetry span kaydı.

---

## Mimari

```
SQL metni → VDbParser → VDbAst → VDbExecutor → VDbTable → VDbCore → .odb
```

| Birim | Görev |
|---|---|
| `VDbCore.pas` | Append-only anahtar/değer motoru, kilitler, dosya G/Ç |
| `VDbTable.pas` | Şema, indeks, FK, kısıtlar, bölümleme |
| `VDbAst.pas` | Tip güvenli AST modeli |
| `VDbParser.pas` | Tokenizer + recursive-descent parser |
| `VDbExecutor.pas` | Filtre, JOIN, gruplama, sıralama, pencere fonksiyonları |
| `VDbSql.pas` | Dış cephe: `TVSql.Exec` |
| `VDbWal.pas` | Write-ahead log, replay, checkpoint |
| `VDbSkipList.pas` | H3 skiplist indeksi (rank/span destekli) |
| `VDbCrypt.pas` | AES-256, GCM, anahtar yönetimi |
| `VDbNet.pas` | VDBS TCP protokolü |
| `VDbSqlServer.pas` | TCP SQL sunucusu |
| `VDbClientNet.pas` | TCP SQL istemcisi |
| `VDbJson.pas` | JSON dışa/içe aktarma |
| `VDbDataSet.pas` | Lazarus/Delphi `TDataSet` köprüsü |

---

## Hızlı başlangıç

### Derleme

```bash
# Windows (Lazarus 4.6+, FPC 3.2.4)
lazbuild -B sqltest.lpi
lazbuild -B vdbapi.lpi

# Linux/macOS
./build_lib.sh
```

### İlk sorgu (Pascal)

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
    DB.Exec('SELECT ad, fiyat FROM urun WHERE fiyat > 1000', R);
    // R.Cols, R.Rows, R.Data
  finally
    DB.Free;
  end;
end;
```

API ayrıntıları ve SQL kullanımı: [kullanim.md](kullanim.md)

---

## Test durumu

Son doğrulanan durum (2026-10-19):

| Kapı | Sonuç |
|---|---|
| `sqltest` | 2527 / 2527 |
| `crashtest` | 8 / 8 (veri kaybı yok) |
| `rawchk` | 29 / 29 |
| `mrowchk` | 0 hata |
| `fuzzchk` | 3000 / 3000 |
| `sqlite_diff` | 4000 / 4000 |
| `hashchk` | 80 / 80 |
| `copychk` | 17 / 17 |
| `zonechk` | 0 hata |
| `skipchk` | 0 hata |
| `countchk` | 120 / 120 |

Depoda artık yalnızca `sqltest` paketi bulunur; diğer kapılar tek seferlik
doğrulama araçlarıydı ve temizlik sırasında kaldırıldı. Sonuçlar yukarıdaki
gibi kayıt altına alınmıştır.

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

---

## Performans

Ölçümlerin tamamı, yöntemi ve SQLite karşılaştırması:
[hiztesti.md](hiztesti.md)

Öne çıkanlar (1.000.000 satır):

| İşlem | Süre |
|---|---|
| `COUNT(*)` | 800 ms |
| `SELECT *` | 1.579 ms |
| `SUM(id)` | 2.265 ms |
| PK nokta araması | 0 ms |
| `ScanAll` | 437 ms |
| 1M INSERT (tek transaction) | 55,84 sn (~17.907/sn) |

Tek satırlık (autocommit) yazma, 20.000 satır, varsayılan `SyncWrite=True`:

| İşlem | Önce | Sonra |
|---|---:|---:|
| `INSERT` | 3,70 ms/satır | **0,430 ms/satır (2.324/sn)** |
| `UPDATE` (PK) | 6,94 ms/satır | **0,387 ms/satır (2.585/sn)** |
| `DELETE` (PK) | 6,87 ms/satır | **0,374 ms/satır (2.673/sn)** |

Ayrıntı ve kök nedenler: [hiztesti.md](hiztesti.md#5-tek-satırlık-yazma-autocommit--2026-10-24).
Tek satırlık yazım dosyaya ekleme yaptığı için ölü bölgeler birikir; motor
bunu **isteğe bağlı otomatik sıkıştırma** ile toparlayabilir
(`AutoCompactEnabled`, varsayılan **kapalı**; eşik `AutoCompactRatio=0,35`,
`AutoCompactMinBytes=4 MB`; açıkken commit sonunda yalnızca eşik aşıldığında
çalışır).

H3 skiplist (100.000 satır): 100 × (`UPDATE` + indeksli `COUNT(*)`)
**0,39–0,42 ms/döngü** — önceki 24,99 ms'e göre **~60–64x**.

### v3.0 sayfa motoru (200.000 satır, aynı harness, medyan)

`benchcmp --backend=v2|v3`, 3 kolonlu 200k satır, aynı makine, art arda:

| Metrik | v2 | **v3.0** |
|---|---:|---:|
| Veri dosyası (`.odb`) | 19,3 MB (96,4 B/satır) | **15,5 MB (77,6 B/satır)** |
| `+.odb.idx` (türetilmiş açılış önbelleği) | — | +3,5 MB |
| **Diskteki toplam** | **19,3 MB** | **19,0 MB** |
| Açılış | 984 ms | **32 ms** |
| PK nokta araması | 6,25 µs | **6,25 µs** |
| Toplu INSERT | 4,46 µs/satır | 6,64 µs/satır |
| Autocommit INSERT | 0,431 ms/satır | 0,557 ms/satır |
| `COUNT(*)` | 31 ms | 62 ms |

v3.0 açılışı **~31x** hızlandırıyor, veri dosyasını **%19,5** küçültüyor; ama
yanına yazdığı `.odb.idx` (silinebilir, türetilmiş önbellek) ile birlikte
diskteki toplam yalnız **%1,2** küçülüyor. `.idx` **boyuta göre otomatik**
yazılır: 50 MB'ın altındaki veritabanlarında hızlı açılış için yazılır,
üstünde yazılmaz (açılış tam taramaya düşer, hedefin çok altında kalır).
PK ve parse maliyeti v2 ile aynı.
Toplu yazım ~1,5x, `COUNT(*)` 2x ve tek satır yazım ~1,3x daha yavaş. Kök
nedenler (sayfa imajlı WAL'in 2x yazma hacmi, tablo başına satır sayacının
olmaması) ve v3.1 planı:
[hiztesti.md](hiztesti.md#9-v30-sayfa-motoru--aynı-tartıda-v2-karşılaştırması-2026-10-25).

---

## Proje yapısı

```
VDb*.pas            Motor birimleri
sqltest.lpi/lpr     SQL test paketi
vdbapi.*            DLL / C API projesi
examples/           Örnek projeler
yonetim/            GUI yönetici
dcpcrypt/           Şifreleme bağımlılığı
dokuman/            Bu dokümanlar (Git dışı)
```

---

## Gereksinimler

- Lazarus 4.6+ / Free Pascal 3.2.4
- DCPcrypt (`dcpcrypt/` klasöründe gelir)
- Windows: `lazbuild`; Linux/macOS: `fpc` + `lazbuild`

---

## Lisans

Açık kaynak. Ayrıntılar için `LICENSE` dosyasına bakın.
