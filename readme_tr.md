# VDB — İlişkisel Veritabanı Motoru

VDB (VeriTabanı), Free Pascal ile yazılmış, harici bir DLL gerektirmeyen,
tek dosyada (`.odb`) çalışan ilişkisel veritabanı motorudur. Masaüstü ve gömülü
uygulamalar için SQLite'a alternatif olarak geliştirilmiştir.

> Bu dosya `dokuman/` klasöründedir ve bilerek Git'e eklenmez.
> İngilizce sürüm: [readme.md](readme.md)

---

## Öne çıkanlar

**Motor (v3 sayfa motoru, varsayılan):**

- Tek dosya depolama (`.odb`), ayrı sunucu kurulumu gerekmez.
- 4 KB sayfa, slotted heap, sayfa başına CRC32; çökme sonrası açılışta
  WAL replay ile kurtarma (kill -9 testiyle doğrulanmış).
- Commit başına yalnız değişen sayfalar WAL'e yazılır; açılışta `.odb.idx`
  ile hızlı yükleme (bozuksa tam tarama).
- Sayfa düzeyinde AES-256-GCM dosya şifreleme; parolasız açılış reddedilir.
- `VERIFY`, `BACKUP TO`, `VACUUM` (atomik), `ANALYZE`, `SHOW STATS`.
- Zengin SQL: JOIN, alt sorgu, CTE, pencere fonksiyonları, `UPSERT`,
  `RETURNING`, trigger, view, stored procedure.
- JSONB, XML/XPath, Spatial, Range tipleri; HASH/RANGE/LIST bölümleme.
- Paralel sorgu, cost-based optimizer; H3 skiplist ikincil indeks.
- RBAC, row level security; 57 exportlu C/Delphi DLL API'si (`vdbapi`).

**v3.1'de henüz yok** (açık `ecUnsupported` hatası verir, sessiz yanlış
sonuç üretmez): `SAVEPOINT` ve kısmi geri alma, PITR/WAL arşivi,
replikasyon, zone map, `ALTER DATABASE KEY`, TCP sunucusunda v3 motoru.
Bunlar v3.2 kapsamındadır. v2 motoru (MVCC, `SAVEPOINT`, PITR,
replikasyon) ağaçta **salt-okunur/göç** yolu olarak durur.

Yeni uygulama yazıyorsanız: [UYGULAMA_GELISTIRME.md](UYGULAMA_GELISTIRME.md).

---

## Mimari

```
SQL metni → VDbParser → VDbAst → VDbExecutor → VDbTable → IVDbBackend → .odb
                                                            ├─ VDbBackendV3 → VDbPageEngine (v3, varsayılan)
                                                            └─ VDbBackendV2 → VDbCore (v2, salt-okunur/göç)
```

| Birim | Görev |
|---|---|
| `VDbFactory.pas` | **Uygulama giriş noktası**: `VdbOpen` / `VdbOpenOrCreate` / `VdbOpenWithPassword` |
| `VDbBackendApi.pas` | `IVdbBackend` sözleşmesi (SQL katmanı motorun somut tipini bilmez) |
| `VDbPageEngine.pas` | v3 sayfa motoru (4 KB sayfa, WAL, kurtarma, `.idx` önbelleği) |
| `VDbPageStore.pas` | Sayfa deposu, dosya büyütme, bayt-aralığı kilidi |
| `VDbBackendV3.pas` | `IVdbBackend`'in v3 gerçeklemesi |
| `VDbBackendV2.pas` | `IVdbBackend`'in v2 adaptörü (göç/legacy) |
| `VDbCore.pas` | v2 append-only anahtar/değer motoru — **legacy, salt-okunur** |
| `VDbTable.pas` | Şema, indeks, FK, kısıtlar, bölümleme |
| `VDbAst.pas` | Tip güvenli AST modeli |
| `VDbParser.pas` | Tokenizer + recursive-descent parser |
| `VDbExecutor.pas` | Filtre, JOIN, gruplama, sıralama, pencere fonksiyonları |
| `VDbSql.pas` | Dış cephe: `TVSql.Exec` |
| `VDbMigrate.pas` | v2 → v3 kopyalama + bayt-bayt doğrulama |
| `VDbWal.pas` | v2 write-ahead log (legacy) |
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

Yeni uygulamalar motorun somut tipini bilmez; giriş noktası `VDbFactory`'dir.
`VdbOpenOrCreate` dosya yoksa **v3** olarak oluşturur, varsa açar. Var olan
**v2** dosyası varsayılan olarak reddedilir (göç: `vdbmig`, bkz.
[GOC_V2_V3.md](GOC_V2_V3.md)).

```pascal
uses VDbBackendApi, VDbFactory, VDbTable, VDbSql;

var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Db: TVSql;
  R: TSqlResult;
begin
  VdbOpenOrCreate('veritabani.odb', Be);   // out parametre (bkz. not)
  Tb := TVTableDb.CreateBackend(Be);
  Db := TVSql.Create(Tb);
  try
    Tb.Open('.');
    R := Db.Exec('CREATE TABLE urun (id INTEGER PRIMARY KEY, ad TEXT, fiyat FLOAT)');
    R := Db.Exec('INSERT INTO urun (ad, fiyat) VALUES (''Laptop'', 15000)');
    R := Db.Exec('SELECT ad, fiyat FROM urun WHERE fiyat > 1000');
    // R.Cols, R.Rows, R.Data
  finally
    Db.Free;
    Tb.Free;
    Be := nil;                             // motoru kapatır (dosya kilidi bırakılır)
  end;
end;
```

> **Neden `out` parametre?** FPC 3.2.4'te `function ...: IVdbBackend` biçiminde
> arayüz **döndüren** bir fonksiyon, sonuca fazladan bir referans bırakıyor;
> `Be := nil` motoru kapatmıyor ve aynı süreçte dosya yeniden açılamıyor
> ("dosya kullanımda"). Aynı iş `out` parametreyle yapıldığında referans tam
> bırakılıyor. Ölçüm: `probe5`/`probe6`; ayrıntı `VDbFactory.pas` başlığında.

Şifreli dosya: `VdbOpenWithPassword(Path, Parola, Be)`. Parolasız veya yanlış
parolayla açılış reddedilir.

API ayrıntıları ve SQL kullanımı: [kullanim.md](kullanim.md)

---

## Test durumu

Son doğrulanan durum (2026-10-25, `v3` dalı):

| Kapı | Sonuç |
|---|---|
| `sqltest` (v2 motoru) | **3116 / 0 / 0** |
| `sqltest --backend=v3` | **2252 / 0 / 58** (58 atla: v2'ye özgü yollar) |
| `crashtest` | 11 / 11 (veri kaybı yok) |
| `pagechk` | 21 / 21 |
| `storechk` | 15 / 15 |
| `heapchk` | 20 / 20 |
| `idxchk` | 17 / 17 |
| `backendchk` | 108 / 108 |
| `v3sqlchk` | 128 / 128 |
| `migchk` | 13 / 13 |
| `factorychk` | 13 / 13 |

`atlanan=58` sessiz yeşil değildir: yalnız v2 motorunun veri dosyası / WAL /
arşiv / SAVEPOINT yollarını kullanan testler sayılır ve raporlanır.

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest                  # v2 motoru
sqltest.exe C:\temp\vdbtest --backend=v3     # v3 sayfa motoru
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
çalışır). Bu davranış **v2 motoruna** aittir; **v3 sayfa motorunda ölü-bayt
eşiği yoktur** — v3'te sıkıştırma her zaman açık bir işlemdir (`VACUUM`).

H3 skiplist (100.000 satır): 100 × (`UPDATE` + indeksli `COUNT(*)`)
**0,39–0,42 ms/döngü** — önceki 24,99 ms'e göre **~60–64x**.

### v3.0/v3.1 sayfa motoru (200.000 satır, aynı harness, medyan)

`benchcmp --backend=v2|v3`, 3 kolonlu 200k satır, aynı makine, art arda:

| Metrik | v2 | **v3.0** | **v3.1** |
|---|---:|---:|---:|
| Veri dosyası (`.odb`) | 19,3 MB (96,4 B/satır) | **15,5 MB (77,6 B/satır)** | **15,5 MB (77,6 B/satır)** |
| `+.odb.idx` (türetilmiş açılış önbelleği) | — | +3,5 MB | +3,5 MB |
| **Diskteki toplam** | **19,3 MB** | **19,0 MB** | **19,0 MB** |
| Açılış | 984 ms | **32 ms** | **27,8 ms** |
| PK nokta araması | 6,25 µs | 6,25 µs | **5,13 µs** |
| Toplu INSERT | 4,46 µs/satır | 6,64 µs/satır | **5,79 µs/satır** |
| Autocommit INSERT | 0,431 ms/satır | 0,557 ms/satır | **0,449 ms/satır** |
| `COUNT(*)` | 31 ms | 62 ms | **0,1 ms** |

v3.0 açılışı **~31x** hızlandırıyor, veri dosyasını **%19,5** küçültüyor; ama
yanına yazdığı `.odb.idx` (silinebilir, türetilmiş önbellek) ile birlikte
diskteki toplam yalnız **%1,2** küçülüyor. `.idx` **her zaman yazılır** (v3.1,
boyut eşiği kaldırıldı). PK ve parse maliyeti v2 ile aynı.

v3.1 v3.0'ın üç gerilemesini kapattı: `COUNT(*)` **62 → 0,1 ms** (tablo başına
canlı sayaç), autocommit **0,557 → 0,449 ms** (WAL'e yalnız işlemde değişen
sayfalar; ölçülen WAL hacmi 63.373 → 8.252 B/commit), toplu INSERT
**6,64 → 5,79 µs** (256 KB'lık dosya uzatma parçaları; sayfa motoru yazımı
1,88 → 1,32 µs). Autocommit'te kalan fark dayanıklılık tabanıdır: tek fsync
**0,330 ms** ölçüldü. Dosya boyutu değişmedi.
Kök nedenler ve tüm ölçümler:
[hiztesti.md](hiztesti.md#9-v30-sayfa-motoru--aynı-tartıda-v2-karşılaştırması-2026-10-25).

---

## Proje yapısı

```
VDb*.pas            Motor birimleri (giriş noktası: VDbFactory.pas)
sqltest.lpi/lpr     SQL test paketi (v2 + --backend=v3)
factorychk.lpi/lpr  Uygulama giriş noktası kapısı (v3/v2 politikası)
vdbmig.lpi/lpr      v2 -> v3 göç aracı (bkz. GOC_V2_V3.md)
vdbapi.*            DLL / C API projesi
examples/           Örnek projeler (hepsi VDbFactory ile v3 açar)
yonetim/            GUI yönetici (v3; v2 dosyasında vdbmig yönlendirir)
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
