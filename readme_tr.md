# VDB — İlişkisel Veritabanı Motoru

VDB (VeriTabanı), Free Pascal ile yazılmış, harici bir DLL gerektirmeyen
ilişkisel veritabanı motorudur. Tüm veri tek bir `.odb` dosyasında durur;
kullanımdaki bir veritabanının yanında çalışma durumu dosyaları da oluşur
(WAL, açılış önbelleği, değişim günlüğü) — bkz.
[ON_DISK_LAYOUT.md](docs/engineering/ON_DISK_LAYOUT.md). Masaüstü ve gömülü
uygulamalar için SQLite'a alternatif olarak geliştirilmiştir.

> İngilizce sürüm: [readme.md](readme.md)

---

## Öne çıkanlar

**Motor (v3 sayfa motoru, varsayılan):**

- Tek veri dosyası (`.odb`), ayrı sunucu kurulumu gerekmez. Yan dosyalar
  çalışma durumudur (WAL, `.idx` önbelleği, değişim günlüğü); eksikse motor
  bunları yeniden üretir.
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

**v3 motorunda henüz yok** (açık `ecUnsupported` hatası verir, sessiz
yanlış sonuç üretmez): TCP sunucusunda v3 motoru (`REPLICATION ... TCP`;
dosya modu log-shipping çalışır) ve `ARCHIVE WAL RESET` (v3 değişim
günlüğü kalıcıdır, kapatılamaz — PITR yeteneği korunur).

**Var ama mevcut kapılarla denenmiyor:** `SAVEPOINT` ve kısmi geri alma,
`AS OF`/PITR, dosya modu replikasyon, zone map/budama ve
`ALTER DATABASE KEY`. Bunlar v3'te çalışır; ancak eski özellik kapıları
(`v3sqlchk`, `pitrchk`, `replchk`, `prochk`, `soakchk`) eski `tests/gates`
ağacıyla birlikte kaldırıldı ve [Test durumu](#test-durumu) bölümündeki
hiçbir kapı bunları yeniden sınamıyor. Bu listeyi "güvenmeden önce kapı
yazılmalı" olarak oku. v2 motoru (MVCC) ağaçta **salt-okunur/göç** yolu
olarak durur.

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
| `VDbCryptoCore.pas` / `VDbKdf.pas` | Saf Pascal kripto çekirdeği ve KDF'ler (harici DLL yok) |
| `VDbNet.pas` | VDBS TCP protokolü |
| `VDbSqlServer.pas` | TCP SQL sunucusu |
| `VDbClientNet.pas` | TCP SQL istemcisi |
| `VDbJson.pas` | JSON dışa/içe aktarma |
| `VDbDataSet.pas` | Lazarus/Delphi `TDataSet` köprüsü |

### Disk üzerinde

Tüm veri `<ad>.odb` içindedir; yalnız bu dosya açıldığında da çalışır ve motor
eksik yan dosyaları yeniden üretir. Kullanımdaki veritabanının yanında ayrıca
`<ad>.odb.wal` (çökme kurtarma), `<ad>.odb.idx` (açılış hızı önbelleği),
`<ad>.odb.gen` ve `<ad>.odb.log/` (PITR için değişim günlüğü) bulunur. Klasör
kopyalarken tümünü birlikte kopyala; taşınabilir tek dosya için `BACKUP TO`
kullan. Ölçülen boyutlar, gerekçeler ve bunu doğrulayan kapı:
[ON_DISK_LAYOUT.md](docs/engineering/ON_DISK_LAYOUT.md).

---

## Hızlı başlangıç

### Derleme

```bash
# Windows (Lazarus 4.6+, FPC 3.2.4) — C API kütüphanesi
lazbuild -B vdbapi.lpi
# diğer projeler: vdbcli.lpi, vdbmig.lpi, vdbserver.lpi

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

Son doğrulanan durum (2026-11-14, Linux x86_64 ve Windows i386, `tests/run_gates.sh`):

| Kapı | Sonuç |
|---|---|
| `sql_stubs` | 25 PASS / 0 FAIL |
| `sql_matrix` | 61 / 0 |
| `sql_fuzz` | 5 / 0 |
| `sql_differential` | 33 / 0 (canlı PostgreSQL karşılaştırması koşulmadı: `pg=not-run`) |
| `crypto_core` / `crypto_base64` / `crypto_kat` / `selftest_builtin` | PASS |
| `fixtures_builtin` | PASS |
| `wal_crash` / `kv_wal` | PASS |
| `backup_restore` | 25 / 0 |
| `page_integrity` | 14 / 0 |
| `btree_integrity` | 152 / 0 |
| `perf_baseline` | 16 / 0 |
| `single_file` | 22 / 0 |
| `server_harden` | 24 / 0 |
| `auth_throttle` | 16 / 0 |
| `tls_client` | 6 / 0 (Linux; OpenSSL DLL'i olmayan Windows'ta atlanır) |

Linux'ta **19 kapı** (OpenSSL isteğe bağlı iki kapı `VDB_CRYPTO_DLL` yoksa
atlanır), Windows'ta **18 kapı** (`tls_client` atlanır). Kapı belgeleri:
[docs/engineering/](docs/engineering/).

```bash
# Linux / macOS / Git Bash: tüm kapıları derle ve koş
tests/run_gates.sh /tmp/vdbgates
```

`tests/run_gates.sh` tüm kapıları kendisi derler ve koşar.
`tests/gates/*` ve `tests/sql/sqltest` eski ağaçla birlikte kaldırıldı;
SQL davranış kapısı artık `sql_stubs` + `sql_matrix`'dir.

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

### SQLite karşılaştırması (200.000 satır, 3 turun medyanı, 2026-11-07)

`tests/bench/sqlitecmp.lpr` VDB v3 ile SQLite 3.54.0'ı aynı süreçte, aynı
veriyle, aynı SQL ile ve aynı diskte koşar. SQLite
`journal_mode=DELETE` ve `synchronous=FULL` kullanır; VDB varsayılanları.

| İş yükü | VDB | SQLite | VDB/SQLite |
|---|---:|---:|---:|
| PK nokta / aralık SELECT | 22,2 / 30,5 us | 49,5 / 52,3 us | **0,45x / 0,58x (hızlı)** |
| `COUNT(*)` | 0,05 ms | 6,23 ms | **0,002x (hızlı)** |
| Autocommit PK UPDATE / DELETE | 0,52 / 0,43 ms | 1,81 / 1,80 ms | **0,29x / 0,24x (hızlı)** |
| Toplu INSERT | 10,78 us/satır | 0,83 us/satır | 13,0x yavaş |
| `SUM/AVG` / `GROUP BY` / `ORDER BY ... LIMIT` | 59,5 / 118,9 / 461,7 ms | 13,9 / 51,8 / 56,1 ms | 4,3x / 2,3x / 8,2x yavaş |
| Dosya boyu (200k satır) | 17,7 MB | 10,3 MB | 1,72x büyük |

VDB ölçülen 13 aşamadan 5'inde önde, 8'inde geride. Tam yöntem, aşama
yayılımları ve kök nedenler:
[hiztesti.md bölüm 53](hiztesti.md#53-p-144p-148-sonrası-sqlite-karşılaştırması-07112026).

---

## Proje yapısı

```
VDb*.pas            Motor birimleri (giriş noktası: VDbFactory.pas)
tests/              Kalıcı kapılar (tests/run_gates.sh)
vdbmig.lpi/lpr      v2 -> v3 göç aracı (bkz. GOC_V2_V3.md)
vdbapi.*            DLL / C API projesi
vdbcli.*            Komut satırı
vdbserver.*         TCP sunucu
examples/           Örnek projeler (hepsi VDbFactory ile v3 açar)
yonetim/            GUI yönetici (v3; v2 dosyasında vdbmig yönlendirir)
docs/               Mimari, mühendislik ve göç notları
dokuman/            Yerel doküman kopyaları (Git dışı)
```

---

## Gereksinimler

- Lazarus 4.6+ / Free Pascal 3.2.4
- Üçüncü parti şifreleme bağımlılığı yok: AES-256, SHA-256, HMAC,
  PBKDF2 ve Argon2id depo içinde saf Object Pascal ile yazılmıştır
  (`VDbCryptoCore.pas`, `VDbKdf.pas`). Harici DLL gerekmez.
- Windows: `lazbuild`; Linux/macOS: `fpc` + `lazbuild`

---

## Lisans

Açık kaynak. Ayrıntılar için `LICENSE` dosyasına bakın.
