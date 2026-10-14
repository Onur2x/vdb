# VDB SQL referansi

Bu dosya `VDbSql.pas` icindeki **gercekten ayristirilan** komutlari listeler.
Listede olmayan bir sey calismaz (asagida "Desteklenmeyenler" bolumu).

**Betik calistirma:** `TVSql.Exec` metni `;` ile ayrilmis **coklu cumle** olarak
kabul edir ve hepsini sirayla calistirir (bolum 5b).

**Otomatik transaction (varsayilan acik):** `;` ile ayrilmis cumlelerin hepsi
batch uyumluysa **TEK `BeginBatch`/`CommitBatch`** icinde calistirilir:
- tek fsync -> belirgin hizli (300 komut: 1 ms, kapali hali 94 ms)
- hata olursa **hicbir cumle uygulanmaz** (ya hep ya hic — bu **yalniz tum
  cumleler batch-uyumluysa** gecerlidir; tumu degilse durum 5b'de acikca
  anlatilmistir: o cumleden itibaren tek tek commit)

Devreye girmeyen durumlar (bu cumleler varsa eski davranis korunur):
`BEGIN`/`COMMIT`/`ROLLBACK`/`END`, `CREATE`/`DROP`/`DELETE DATABASE`,
`OPEN`/`USE`/`CLOSE`, `BACKUP`, `VERIFY`, `VACUUM`, `REINDEX`, `EXPORT`,
`IMPORT`. Kapatmak icin: `TVSql.AutoTransaction := False`.

## Komut listesi (ozet)

| Komut | Durum |
|---|---|
| `BEGIN` / `COMMIT` / `ROLLBACK` | var |
| `CREATE TABLE` | var (PRIMARY KEY, NOT NULL, UNIQUE, DEFAULT, CHECK, REFERENCES, AUTOINCREMENT, ON DELETE/UPDATE aksiyonlari) |
| `CREATE INDEX` | var |
| `CREATE DATABASE` | var (`IF NOT EXISTS`) |
| `OPEN DATABASE` / `USE` | var (etkin veritabanini degistirir, sonrasi otomatik `Verify`) |
| `CLOSE DATABASE` | var (kapatir, dosya kilidini birakir) |
| `DROP TABLE` / `DROP INDEX` / `DROP DATABASE` / `DELETE DATABASE` | var (`IF EXISTS` sadece DATABASE'te) |
| `BACKUP TO 'dosya.odb'` / `VERIFY` | var |
| `ALTER TABLE` | var (ADD/DROP/RENAME/ALTER COLUMN) |
| `ALTER DATABASE KEY 'yeniParola'` | var (parola rotasyonu: encryped kayit yeniden sifrelenir, `.key` guncellenir, `.bak` korunur) |
| `INSERT` | var (4 bicim + **çoklu `VALUES`** + `INSERT ... SELECT`) |
| `SELECT` | var (`*`, kolon listesi, AS, `DISTINCT`, JOIN (**`CROSS` dahil**), WHERE, GROUP BY, HAVING, ORDER BY, LIMIT, OFFSET, aggregate, `UNION`/`EXCEPT`/`INTERSECT`) |
| `UPDATE` / `DELETE` | var (`SET` icinde `+ - * / %` aritmetigi) |
| `LIST DATABASES` / `SHOW DATABASES` / `SHOW TABLES` | var |
| `DESCRIBE t` / `DESC t` | var (kolon semasi) |
| `SHOW INDEXES [FROM] t` | var |
| `SHOW CREATE TABLE t` | var |
| `VACUUM` / `REINDEX` | var |
| `EXPORT JSON` / `IMPORT JSON` | var |
| `CREATE ROLE` / `DROP ROLE` | var (R-18; `SUPERUSER`) |
| `GRANT` / `REVOKE` | var (R-18; `SELECT/INSERT/UPDATE/DELETE/ALL ON tablo\|* TO/FROM rol`) |
| `SET ROLE` | var (R-18; `rol` ya da `NONE`) |
| `CREATE POLICY` / `DROP POLICY` | var (R-19; `FOR ... USING (...) [WITH CHECK (...)]`) |
| `ALTER TABLE ... ENABLE/DISABLE ROW LEVEL SECURITY` | var (R-19) |
| `SET CONSTRAINTS [ALL] DEFERRED/IMMEDIATE` | var (R-11; yalniz `DEFERRABLE` FK icin) |
| `WITH RECURSIVE` + `CYCLE` | var (R-10; dongu korumasi) |
| `COLLATE <ad>` (ORDER BY, WHERE, kolon tanimi) | var (R-20; dil etiketi tasinan motor: `tr`, `ru`, `de`, `ja`, `he`, `ar`, `zh`, `C`/`BINARY`, `-u-ks`, `-u-kc`, `-s1..-s4`) |

---

## 0. Sema sorgulari

```sql
DESCRIBE ebe;                  -- veya: DESC ebe;
SHOW INDEXES FROM ebe;         -- FROMsuz bicim de calisir: SHOW INDEXES ebe
SHOW CREATE TABLE ebe;
```

`DESCRIBE` sutunlari dondurur: `name, type, pk, notnull, unique, default`.
`SHOW INDEXES` her indeks icin `name, columns, unique, type` dondurur.
`SHOW CREATE TABLE` tek satirlik `CREATE TABLE` metni verir.

Yonetim programinda bu uc sorgu **Sema** sekmesinden tek tikla
calistirilir; sorgu SQL sekmesine de yazilir, duzenlenip tekrar
calistirilabilir.

**Bilinen sinir:** `SHOW CREATE TABLE` `AUTOINCREMENT` niteligi
uretmez (otoincrement semada saklanmaz, yalniz calisma aninda sayac
tutulur) ve metin `DEFAULT` degerini tirnaksiz yazar
(`DEFAULT x`). Bunlar sema **okuma** komutlari oldugu icin yazma
tutarliligini etkilemez, ama bir `CREATE TABLE` metnini oldugu gibi
geri calistirmak kullaniciya gore degere baglidir.

---

## 0c. COLLATE (R-20) — Dil etiketi tasiyan collation motoru

`ORDER BY x COLLATE <ad>` ve `WHERE x = y COLLATE <ad>` ile
kolon tanimlari (`ad TEXT COLLATE tr`) desteklenir.

**Motor sabit bir dil listesine KILITLI DEGILDIR:** locale etiketi
`tr`, `de`, `ja`, `he-IL`, `zh-Hans`, `pt-BR` gibi HEPPSI calisir;
alfabe dilden (dil kodunun ilk iki harfi) veya kod noktasi
araligindan (`$0370` = Yunan, `$0400` = Kiril) secilir.

Desteklenen ana diller / alfabeler (tamamlanmamis, genisletilebilir):
`tr`/`TR` (Turkce, i/ı ayri), `en` (Latin), `de` (Almanca), `ru` (Kiril),
`el` (Yunan), `ar` (Arap), `he` (Ibran), `de` (Alman), `zh` (Han),
`ja` (Japon / Hiragana), `ko` (Hangul), `th`/`lo`/`km` (Tay / Lao / Khmer).

| Anahtar | Islev |
|---|---|
| `<ad>` | Dil etiketi (`tr`, `ru`, `zh`, `C`, `BINARY`, `pt-BR`) |
| `-u-ks` | Vurgu **duyarlı** (accent) |
| `-u-kn` | Vurgu duyarsiz (varsayilan) |
| `-u-kc` | Buyuk/kucuk **duyarlı** |
| `-s1`..`-s4` | Kuvvet seviyesi (`vsPrimary..Quaternary`) |

Varsayilan kuvvet `vsPrimary`: ne vurgu ne buyuk/kucuk ayrilir
(`ARMUT` = `armut`). Tertiary (`vsTertiary`) case duyarlidir.

Ornek:
```sql
ORDER BY ad COLLATE tr-u-ks        -- vurgu duyarlı (accent)
ORDER BY ad COLLATE tr-u-kc        -- buyuk/kucuk duyarlı
ORDER BY ad COLLATE C              -- ham kod noktası (bayt) sırası
CREATE TABLE t (ad TEXT COLLATE tr)  -- kolon varsayılanı kalıcı (sema)
```

`COLLATE` metni UTF-8 kodlu `AnsiString` olarak saklanir; tirnakli
yazim (`"tr-TR-u-kn"`) de kabul edilir.

---

## 0b. WAL (yazma oncesi gunluk) — API, SQL degil

WAL bir **SQL komutu degil**, dogrudan API'dir (`had` uzerinden de
kullanilir):

| Metot | Islev |
|---|---|
| `WalPath` | `.odb` dosyasinin `.wal` yolu |
| `WriteAheadWAL(Key, Value, Flags)` | gunluge bir kayit yazar (`Flags`: `VDB_FLAG_PUT` / `VDB_FLAG_DEL`) |
| `ReplayWAL` | gecerli kayitlari ana dosyaya **tek batch'te** uygular, sonra `.wal` siler |
| `CheckpointWAL` | once replay, sonra sil |
| `HasWAL` | bekleyen kayit var mi |
| `WalRecordCount` | bekleyen **gecerli** kayit sayisi (yalnizca okur) |

### Kayit formati (21 bayt baslik)

```
LongWord Magic = $57414C52 ('WALR')
QWord    Key
Byte     Flags        // 0 = PUT, 1 = DEL
LongWord ValLen
LongWord Crc          // CRC32(Seq=0 || Key || ValLen || Flags || Value)
```

`CRC` **magic'i kapsamaz**.

### Davranis

- `ReplayWAL`: kayitlar sirayla okunur; **magic / bayrak / uzunluk / CRC**
  tutmuyorsa kuyruk **orada kesilir**, o ana kadar olanlar uygulanir.
  Yirtik kuyruk veya CRC bozuk kayit **hicbir zaman** uygulanmaz.
- Gecerli kayitlar **tek `BATCHEND` ile** yazilir: ya hep uygulanir ya
  hicbiri. Boylece yari uygulanmis replay, sonraki `Open`'da `Recover`
  tarafindan geri sarilir.
- `.wal` dosyasi `ReplayWAL` sonunda **silinir** (bozuk kuyruk da
  silinir: bozuk kayit zaten hic uygulanamaz, tutmanin kurtarma degeri
  yoktur).
- `WriteAheadWAL` mevcut dosyaya **ekler**; deger dosyaya `fsync` edilir.

### DIKKAT

`Put`/`Delete` **varsayilan olarak** WAL yazmaz. Elle mod opt-in'tir:
`WriteAheadWAL` cagrildiktan sonra kayit `.wal`'a yazilir ve ana dosyaya
**yazilmaz**; veri ancak `ReplayWAL`/`CheckpointWAL` ile kalicilik kazanir.

### Otomatik WAL (write-ahead) - `WALEnabled`

Elle `WriteAheadWAL` cagrisini unutma riskini kaldiran mod:

| Metot | Islev |
|---|---|
| `WALEnabled` (property) | `True` ise her kalici yazma once `.wal`'a, sonra ana dosyaya |
| `WalAutoCount` | bu oturumda otomatik gunluge yazilan kayit sayisi |

```pascal
Kv.WALEnabled := True;        // varsayilan KAPALI
Kv.Put(1, veri);              // .wal'a yaz -> ana dosyaya yaz
Kv.WalRecordCount;            // 1
Kv.WalAutoCount;              // 1
```

Kurallar:

- **Varsayilan KAPALI.** Acik degilse motor davranisi **degismez**.
- **Siralama onemli:** once `.wal` (`fsync`), sonra ana dosya. Yazma
  cagrisi donmeden cokerse kayit `.wal`'da kalir.
- **WAL yazilamazsa islem hata doner**, ana dosyaya **yazilmaz**.
- **`BeginBatch` icinde yazma gunluğe girmez.** Kayitlar biriktirilir ve
  `CommitBatch`'te **bir kez** hem gunluge hem ana dosyaya yazilir. (Batch
  icinde yazilsaydi her satir icin ayri `fsync` gerekirdi.)
- **`ReplayWAL` kendi kaydini yeniden yazmaz** (yoksa dongu + dosya
  buyumesi olurdu).
- **`Close` durumu sifirlar.** Ayni nesne yeniden `Open` edilirse
  `WALEnabled = False` olur; eski bir `True` sessizce devam etmez.
- `ReplayWAL`/`CheckpointWAL` elle modla ayni calisir.

> **`ReplayWAL` otomatik modda cift uygular.** Kayitlar ana dosyaya zaten
> yazildigi icin replay ayni kayitlari tekrar yazar. `PUT`/`DEL`
> idempotent oldugundan veri bozulmaz, ama ayni kayit tekrar yazilir.
> Otomatik modda `ReplayWAL` yerine **`CheckpointWAL`** kullanin; `Replay`
> yalniz "ana dosyaya yazilmamis kayit" senaryosu icin gereklidir.

### WAL'den okuma: CDC, Time Travel ve `AS OF` (API + SQL)

`.wal` dosyasi iki bircok birim tarafindan **ayni bicimde** okunur
(`TVDbWalHead`, `VDbCore` interface'inde; 21 bayt baslik + deger):

| Metot / birim | Islev |
|---|---|
| `Kv.WalRecordCount` | gecmis kayit sayisi (dogrulamali sayim) |
| `Kv.ReadWalEntry(I, Key, Flags, Value)` | I. gecisli kayit (magic/CRC/yirtik kuyruk dogrulamali) |
| `VDbCdc.pas` (`TVDbCdc`) | WAL'den INSERT/UPDATE/DELETE olayi uretir; `Start` otomatik WAL'i acar |
| `VDbTimeTravel.pas` (`TVTimeTravel`) | `GetValueAt`/`GetRowAt` ile onceki deger (Seq = WAL kayit indeksi) |

`SELECT ... AS OF ...` artik **SQL olarak** da baglidir — asagidaki
"`SELECT ... AS OF SEQUENCE`" bolumune bakin (§0b alti).

### `SELECT ... AS OF SEQUENCE <n>` (WAL gecmisinden okuma)

WAL acikken (`WALEnabled = True`) tek tablo sorgulari gecmis bir ana da
okunabilir:

```sql
SELECT * FROM k AS OF SEQUENCE 12 ORDER BY id;
SELECT ad FROM k AS x AS OF SEQUENCE 12 WHERE id = 1;   -- alias'li
SELECT COUNT(*) FROM k AS OF SEQUENCE 12;
```

- **`n` = WAL kayit indeksi** (0 tabanli; `n >= WalRecordCount` ise son
  kayda kirpilir). `n` dahil tum kayitlar uygulanmis goruntu okunur.
- **Kurallar** (hepsi son checkpoint'ten beri penceresine gore):
  - pencerede hic gormeyen + hic degismeyen anahtar -> mevcut hali aynen,
  - N'ye kadar son islem **PUT** -> o anki deger WAL'dedir (UPDATE oncesi
    deger gorunur, silinmis satir o an geri gelir),
  - N'ye kadar son islem **DEL** -> satir o an yoktur,
  - N sonrasi eklenmis satir o an gorunmez; N sonrasi silinmis satir
    N'deki degeriyle gorunur.
- **WHERE / ORDER BY / LIMIT / GROUP BY / aggregate / pencere** gecmis
  veriye aynen uygulanir (once gecmis kurulur, sonra normal yoldan gecer).
- **Acikca reddedilenler (`ecUnsupported`, sessiz yanlis cevap yok):**
  - `AS OF TIMESTAMP` / `AS OF VERSION` — WAL'de ne zaman damgasi ne
    surum numarasi vardir; yalnizca `SEQUENCE` cozumlenir.
  - `JOIN` veya `WITH` (CTE) ile birlikte — gecmis goruntusu tek tabloya
    bakar.
  - gecmis yokken (WAL kapali ya da `CheckpointWAL`/`ReplayWAL` sonrasi).
  - gecmis satir farkli kolon sayisina sahipse (`ALTER TABLE` sonrasinda).
- **Sinirlar (bilerek):**
  - Gecmis yalnizca **son checkpoint'ten beriyi** kapsar; checkpoint
    gunlugu siler.
  - Pencere onceden gelip pencerede DEGISMIS bir satirin eski degeri
    WAL'de yoksa ("WAL acilmadan once yazilmis") o satir o an gorunmez —
    bu durum "pencere sonrasi eklenmis" ile ayni gorunumdur ve kod
    bunu ayirt edemez.
  - Alt sorgu / `EXISTS` ifadeleri **guncel** veriye bakar; yalnizca
    `FROM` tablosu gecmise alinir.
  - Salt okumadir: gecmis goruntusu uzerinde yazma yapilmaz.

---

## 1. Transaction

```sql
BEGIN;
COMMIT;
ROLLBACK;
```

```sql
SAVEPOINT sp1;
INSERT INTO t VALUES(1);
SAVEPOINT sp2;
INSERT INTO t VALUES(2);
ROLLBACK TO SAVEPOINT sp2;  -- geri don sp2'ye (id=2 geri alinir)
RELEASE SAVEPOINT sp1;      -- sp1 serbest birak, nested savepoint'ler gecerli kalir
COMMIT;
```

`ROLLBACK` **DDL dahil**: batch basinda alinan sema yedegi geri yuklenir
(`CREATE TABLE`, `DROP TABLE`, `ALTER TABLE`, `CREATE INDEX` geri alinir).

**SAVEPOINT / Nested Transaction (R-02):**
- `SAVEPOINT name` — transaction icinde bir geri donus noktasi olusturur
- `ROLLBACK TO SAVEPOINT name` — o savepoint'e geri don, o sonrasi islemler iptal
- `RELEASE SAVEPOINT name` — savepoint serbest birak, nested savepoint'ler gecerli kalir
- Nested savepoint desteklenir (sp1 -> sp2 -> sp3...)
- `ROLLBACK TO` sadece hedef savepoint'e kadar geri sarar; onceki savepoint'ler gecerli kalir
- `RELEASE` savepoint'i siler; child savepoint'ler gecerli kalir (merge olur)
- `COMMIT` tum savepoint'leri temizler; `ROLLBACK` (savepoint'siz) transaction'i tamamen geri alir

## 2. CREATE TABLE

```sql
CREATE TABLE kisi (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,  -- PK otomatik NOT NULL + UNIQUE
  ad     TEXT    NOT NULL,
  yas    INTEGER DEFAULT 0,
  email  TEXT    UNIQUE,                     -- UNIQUE kisit
  aktif  BOOLEAN DEFAULT 1,
  not1   FLOAT,
  dogum  DATE,
  kayit  DATETIME,
  saat   TIME,
  resim  BLOB,
  CHECK (yas >= 0)                          -- tablo-seviyesi CHECK
);
```

### AUTOINCREMENT

```sql
CREATE TABLE Musteriler (
  ID    INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  Kod   TEXT NOT NULL DEFAULT 'M000',
  Ad    TEXT NOT NULL DEFAULT 'İsimsiz'
);
INSERT INTO Musteriler(Ad) VALUES('Ali');   -- ID = 1 otomatik
```

Motor `INTEGER PRIMARY KEY` degeri verilmediginde **her zaman** otomatik artirir.
`AUTOINCREMENT` anahtar sozcugu bu davranisi **acikca belirtir** ve semada
kaydedilir; ayrica sunlar kabul edilir:

| Yazim | Anlami |
|---|---|
| `AUTOINCREMENT` / `AUTO_INCREMENT` | INTEGER PRIMARY KEY (MySQL yazimi) |
| `SERIAL` | tip olarak INTEGER + otomatik artma (PostgreSQL yazimi) |
| `IDENTITY[(seed,inc)]` | tip olarak INTEGER + otomatik artma (MSSQL yazimi) |

`IDENTITY`/`SERIAL` parantezli argumanlari kabul edilir ama **yok sayilir**
(seed/inc her zaman 1'dir). `AUTOINCREMENT` yalniz `INTEGER` kolonunda ve
`ALTER TABLE ... ADD` ile de kullanilabilir; baska bir tipte hata verir.

### Kolon ici kisitler

```sql
CREATE TABLE t (
  a INTEGER NOT NULL,
  b TEXT UNIQUE,
  c INTEGER DEFAULT 5,
  d INTEGER REFERENCES ebeveyn(id),     -- FK (hedef sutun verilmezse PK olur)
  e INTEGER CHECK (e > 0)               -- kolon ici CHECK
);
```

Tipler: `INTEGER|INT|BIGINT|SMALLINT`, `FLOAT|DOUBLE|REAL|DECIMAL|NUMERIC`,
`BOOLEAN|BOOL`, `DATE`, `DATETIME|TIMESTAMP`, `TIME`, `BLOB|BINARY`.
Diger her sey `TEXT` sayilir.

Sinirda taninip yok sayilan yazimlar: `DEFERRABLE`,
`NOT DEFERRABLE`, `INITIALLY DEFERRED`, `GENERATED ALWAYS AS (...)`.
(`COLLATE` yalniz `ORDER BY ... COLLATE TR` biciminde anlamlidir;
bkz. siralama notlari.)
Bilinmeyen bir anahtar sozcugu **sessizce yutulmaz**, hatayi soyleyerek verir
(`"FOO" taninmiyor (bu konumda , veya ) bekleniyor)`).

### BLOB (ikili veri: fotograf, belge)

```sql
CREATE TABLE foto(id INTEGER PRIMARY KEY, ham BLOB);
INSERT INTO foto(id, ham) VALUES(?, ?);   -- parametre ile (bayt aynen tasinir)
SELECT ham FROM foto WHERE id = 1;
SELECT LENGTH(ham) FROM foto;             -- bayt sayisi
```

Kurallar:
- `BLOB` ham bayttir: `Trim`, `NULL` literali cevimi, `UTF-8` normalize
  uygulanmaz. Gecersiz `UTF-8` (`C0`...), basi/sonu bosluk bayti
  (`<= $20`), icindeki `#0` ve `NULL` metni aynen korunur.
- `INSERT` icin `?` parametresi kullanin; SQL metnine gomulu ikili
  sabit desteklenmez.
- `EXPORT/IMPORT JSON` turu kayipsizdir (`#0` iceren hucre hex-nesne
  olarak yazilir). `LENGTH` metinde karakter, `BLOB`'da bayt sayar.
- Sinir: `TDataSet` (`TVDbQuery`) `BLOB`'u metin alani gibi gosterir;
  `#0` iceren degerler gridde kirpilir (motor verisi saglamdir).

### FOREIGN KEY aksiyonlari

```sql
CREATE TABLE coc (
  id  INTEGER PRIMARY KEY,
  pid INTEGER REFERENCES eb(id) ON DELETE CASCADE ON UPDATE SET NULL
);
```

| Yazim | Karsilik |
|---|---|
| (yok) / `RESTRICT` / `NO ACTION` | kullaniliyorsa hata (varsayilan) |
| `CASCADE` | ebeveyn silinince cocuk da silinir; ebeveyn `UNIQUE`/PK kolonu degisince cocuk FK kolonu yeni degere gelir |
| `SET NULL` | ebeveyn silinince cocuk FK kolonu NULL olur |
| `SET DEFAULT` | ebeveyn silinince cocuk FK kolonuna kolonun `DEFAULT` degeri yazilir (`DEFAULT` yoksa NULL) |

Hepsi tablo-seviyesinde de yazilabilir:

```sql
CREATE TABLE coc (
  id  INTEGER PRIMARY KEY,
  pid INTEGER,
  FOREIGN KEY (pid) REFERENCES eb(id) ON DELETE CASCADE
);
```

Aksiyonlar semada saklanir (dosyada 5 alanli olarak yazilir; **eski 3 alanli
sema dosyalari geriye uyumlu** okunur ve `RESTRICT` sayilir).

> **Iki asamali denetim.** Bir silme/guncellemede **tum** cocuk FK'lar once
> denetlenir; herhangi biri `RESTRICT` ise hicbir yazma yapilmadan hata
> verilir. Kaskadlar ancak denetim basarili olduktan sonra uygulanir.
> Aksi halde tablolarin siralamasina bagli olarak kismi kaskad yan etkileri
> birikirdi.

### FK tetikleyicisi hangi degisiklikte devreye girer

`UPDATE` sirasinda bir cocuk FK'nin `RefCol` degeri degisiyorsa
(UNIQUE olmasa bile) `ON UPDATE` aksiyonu uygulanir.

## 3. CREATE / DROP INDEX

```sql
CREATE INDEX ix_ad ON kisi(ad);
DROP INDEX ix_ad;
```

Indeks **bellek ici**, veriden turetilir; crash-safe (yeniden kurulur).
`WHERE <indexli kolon> = ...` hizli yoldan gider. `REINDEX` ile elle kurulur.

## 4. Veritabani olusturma / acma / silme / yedekleme

```sql
CREATE DATABASE satis;                  -- satis.odb (TEK dosya, klasor YOK)
CREATE DATABASE IF NOT EXISTS satis;
OPEN DATABASE satis;                    -- etkin veritabanini degistir
USE satis;                              -- OPEN DATABASE kisayolu
CLOSE DATABASE;                         -- kapat (dosya kilidi birakilir)
DROP DATABASE satis;                    -- sil  (etkin olan silinemez)
DELETE DATABASE satis;                  -- DROP ile ayni
LIST DATABASES;                         -- aktif olan '*' isaretli
SHOW DATABASES;                         -- ayni
BACKUP TO 'yedek.odb';                  -- tutarli yedek al
VERIFY;                                 -- salt-okunur butunluk denetimi
```

Yeni veritabani **etkin veritabaninin bulundugu klasore** olusur ve dosya adi
veritabani adiyla aynidir:

```
D:\veritabani\db\veritabani.odb   <- etkin
D:\veritabani\db\satis.odb        <- CREATE DATABASE satis;   (ayni klasor)
```

Veritabani adi **dosya adidir** (`veritabani.odb` -> `veritabani`), klasor adi
degil. Klasor icine gomulmez. `OPEN DATABASE satis.odb` da yazabilirsin
(uzanti otomatik atilir).

**`OPEN DATABASE` / `CLOSE` davranisi**
- Motor nesnesi **ayni kalir**; yalnizca dosya degisir. Programdaki
  `TVDb` / `TVTableDb` / `TVSql` referanslari gecerli olmaya devam eder.
- Acilis sonrasi **otomatik `Verify`** calisir; sonuc `Msg` alaninda yazar.
- **Var olmayan** veritabani icin bos dosya **OLUSTURULMAZ**; hata verir.
- `CLOSE DATABASE` sonrasi diger tum komutlar net hata verir:
  `veritabani kapali - OPEN DATABASE <ad> ile ac (LIST DATABASES)`.
- Bu komutlar otomatik transaction disindadir (karisirlik olmasin diye).

Once `\<ad>\veritabani.odb` (klasor) olarak olusturulmus veritabanlari da
okunur ve listelenir; `CREATE`/`DROP` var olan yerlesimi kullanir.
Guvenlik: ad `..`, yol ayirici (`\ / : * ? " < > |`) ve 64 karakterden uzun
ise reddedilir; **etkin** veritabani `DROP`/`DELETE` ile silinemez.

## 4b. Şifreleme — `ALTER DATABASE KEY` (2026-10-05)

Parola **rotasyonu** (re-key): tum sifreli kayitlar eski anahtarla
cozulup yeni anahtarla yeniden yazilir. Motor API'sinde karsiligi
`TVDb.RekeyWithPassword`'dur.

```sql
ALTER DATABASE KEY 'yeni-parola-1';     -- etkin veritabani uzerinde
```

- **On kosul:** anahtar zaten yuklu olmalidir (`OpenKeyFile` /
  `SetEncryptionKey`). Anahtarsiz cagri hata doner.
- **Karisik dosya:** duz metin kayitlar duz kalir; yalnizca
  `VDB_FLAG_ENCRYPTED` tasiyanlar yeniden sifrelenir.
- **Atomik:** yeni `.key` once `.key.tmp`'ye yazilir, veri tmp cikisi +
  atomik rename ile degisir. Sonrasinda:
  - `veritabani.odb.bak` = eski (eski anahtarli) veri
  - `veritabani.key.bak` = eski `.key` (eski parola ile acilir)
- **Batch acikken cagrilamaz** (acik `BEGIN` varsa hata).
- Sonuc: `Res.Msg = 'OK'`, `Affected = 1`.

Dogrulama (`sqltest` T77): rekey → yeni parola ile `OpenKeyFile`
kabul, eski parola reddi, veri okunuyor, `.key.bak` hala eski parolayla
aciliyor.

İlgili API (motor): `CreateKeyFile`, `OpenKeyFile`, `SetEncryptionKey`,
`ClearEncryptionKey`, `IsEncrypted`, `HasEncryptedRecords`, `KeyPath`,
`EncryptionKeyFingerprint`, `RekeyWithPassword`.
`VERIFY` raporunda `sifreli=N` sayaci vardir. Ayrinti: `README.md`
(*Şifreleme*), `DLL_KULLANIM.md` (`VdbEncrypt*`).

## 5. INSERT — coklu kayit

```sql
INSERT INTO t(a,b) VALUES (1,'x');     -- sutun listesi
INSERT INTO t VALUES (1,'x','y');       -- sutun listesi YOK -> sirayla
INSERT INTO t() VALUES ();              -- yalnizca DEFAULT'lar
INSERT INTO t DEFAULT VALUES;           -- kisayol
```

### COKMULU SATIR (virgulle ayrilmis deger gruplari)

```sql
INSERT INTO personel (ad, unvan, sehir, departman, maas) VALUES
('Mehmet', 'Yönetici', 'İstanbul', 'Yazılım', 9200),
('Samet',  'Uzman',   'Ankara',   'Finans',  4800),
('Kenan',  'Yönetici', 'İstanbul', 'Yazılım', 9700),
('Veli',   'Uzman',   'İzmir',    'Satış',   5200);
```

- Tüm gruplar **tek bir atomik batch** içinde yazılır: 4. satır `CHECK`
  ihlali verirse **hiçbiri** yazılmaz (yarım yazım = veri tutarsızlığı).
- `Affected` yazılan satır sayısıdır (4).
- Tüm grupların değer sayısı eşit olmak zorundadır; değilse hata verilir.
- `INSERT INTO t DEFAULT VALUES, DEFAULT VALUES` ve
  `INSERT INTO t() VALUES (), ()` da çoklu satır ekler.
- Artık token varsa hata verilir — `VALUES (1,'a') BLA` sessizce yutulmaz.

### INSERT INTO ... SELECT

```sql
INSERT INTO hedef(id, ad) SELECT id, ad FROM kaynak;
INSERT INTO hedef(ad, id) SELECT ad, id FROM kaynak WHERE id > 10;
```

Eşleme **pozisyoneldir**: hedef sutun listesi varsa sorgu çıktısının sırasıyla,
yoksa hedef tablonun tüm sütunlarıyla sırayla eşleşir. Sonuç da tek atomik
batch içinde yazılır.

### UPSERT — ON CONFLICT (R-03)

```sql
-- Cakismada atla
INSERT INTO t(id, val) VALUES(1, 'a') ON CONFLICT(id) DO NOTHING;

-- Cakismada guncelle (EXCLUDED ile yeni deger)
INSERT INTO t(id, val) VALUES(1, 'b') ON CONFLICT(id) DO UPDATE SET val = EXCLUDED.val;

-- Sayac artirma
INSERT INTO t(id, cnt) VALUES(1, 0) ON CONFLICT(id) DO UPDATE SET cnt = cnt + 1;

-- INSERT ... SELECT ile upsert
INSERT INTO hedef(id, val) SELECT id, val FROM kaynak
  ON CONFLICT(id) DO UPDATE SET val = EXCLUDED.val;
```

**Desteklenen ozellikler:**
- `ON CONFLICT (kolon) DO NOTHING` — cakismada hicbir sey yapma
- `ON CONFLICT (kolon) DO UPDATE SET ...` — cakismada guncelle
- `EXCLUDED` pseudo-table — cakisan satirin yeni degerlerine erisim (`EXCLUDED.val`)
- `INSERT ... SELECT ... ON CONFLICT` — toplu upsert
- Hedef kolon listesi opsiyonel (PK uzerinden cakisma tespiti)

### Deger / sutun sayisi kurali

```sql
CREATE TABLE t(a TEXT, b INTEGER);
INSERT INTO t(a,b) VALUES('x',1);   -- dogru
INSERT INTO t(a,b) VALUES('x');     -- HATA: sutun 2, deger 1
INSERT INTO t VALUES('x',1);        -- dogru (liste yok -> sirayla)
INSERT INTO t VALUES('x');          -- HATA: sutun 2, deger 1
```

Ayni sutun iki kez verilirse de hata verilir.

## 5b. BIRDEN FAZLA CUMLE (";" ile)

`Exec` betiği **`;` ile ayrılmış tüm cümleleri sırayla çalıştırır**:

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t(v) VALUES ('a'),('b'),('c');
UPDATE t SET v = 'z' WHERE id = 2;
DELETE FROM t WHERE id = 3;
```

- `;` **tırnak dışında** böler: `VALUES ('a;b')` tek değerdir, `''` kaçışlı
  tırnak doğru sayılır.
- `Affected` tüm cümlelerin **toplamıdır**.
- `TSqlResult.Fields` / `.Rows`, **satır döndüren son** cümlenin sonucudur.
  INSERT/UPDATE/DELETE satır döndürmez → `Fields` boş kalır.
- `TSqlResult.LastTable` son cümlenin dokunduğu tabloyu tutar; arayüz
  (GUI) sonucu boşsa bu tabloyu yeniden çizer.
- `TSqlResult.Stmts` çalıştırılan cümle sayısıdır.
- Hatalı bir cümlede betik **durur**; *o ana kadar* uygulanan cümleler
  commit edilmiş olarak kalır (otomatik transaction yalnızca **tüm
  cümleler batch-uyumluysa** devreye girer; `StmtBatchSafe` dışı bir cümle
  varsa — örneğin `BEGIN`/`COMMIT`, `CREATE`/`DROP`/`DELETE DATABASE`,
  `VACUUM`, `VERIFY`, `EXPORT`/`IMPORT` — o cümleden itibaren otomatik
  batch kapatılır ve **cümleler tek tek (küme-atomik) commit edilir**).
  Tüm betiği tek transaction içinde geri almak için başına `BEGIN;`
  sonuna `COMMIT;`/`ROLLBACK;` ekleyin.
- `CREATE`/`DROP`/`DELETE DATABASE` gibi "dosya seviyesi" komutlar
  batch içinde geri alınamaz; `ROLLBACK` onların etkisini geri almaz.

## 6. SELECT

```sql
SELECT * FROM t;
SELECT a, b FROM t;
SELECT a AS x, b y FROM t;              -- AS'li ve AS'siz alias
SELECT COUNT(*) FROM t;
SELECT 1;                               -- FROM'suz: tek satir
SELECT 'abc' AS x, NULL, 2.5;
```

`FROM` yoksa tek satır döner. Alan adı değerin kendisidir (`AS` ile
değiştirilebilir). `FROM`'suz `SELECT`'te kolon kullanılamaz — tablo gerekiyorsa
`FROM` yazılmalıdır.

Tablo alias'ı da nitelemeli ad üretir:

```sql
SELECT x.ad FROM t x;                   -- SELECT, WHERE, ORDER BY, GROUP BY
SELECT x.ad FROM t x WHERE x.yas > 20 ORDER BY x.id;
```

### DISTINCT

```sql
SELECT DISTINCT dept FROM personel;
SELECT DISTINCT dept, unvan FROM personel;
SELECT DISTINCT * FROM personel;
SELECT DISTINCT dept FROM personel ORDER BY dept;
```

Tekillestirme **projeksiyon sonrasi, `OFFSET`/`LIMIT` oncesi** yapilir.
Boylece `SELECT DISTINCT d ... ORDER BY d LIMIT 2` 5 satirdan degil, 3 tekil
satirdan ilk 2'sini doner. `DISTINCT` sorgusu her zaman tam taramaya duser
(indexli hizli yol kullanilmaz), cunku tekillestirme `LIMIT`'tan once
uygulanmalidir.

### JOIN

```sql
SELECT t.a, e.ad
FROM t INNER JOIN ebeveyn e ON t.pid = e.id;

SELECT t.a, e.ad
FROM t LEFT JOIN ebeveyn e ON t.pid = e.id;   -- eslesmeyenlerde e.* NULL

SELECT t.a FROM cocuk c JOIN ebeveyn ON c.pid = ebeveyn.id;  -- nitelemeli

SELECT a.ad, b.ad FROM stok a CROSS JOIN renk b;             -- ON'suz cartesius
SELECT a.ad, b.ad FROM stok a CROSS JOIN renk b ON b.aktif = 1; -- ON yazildiysa INNER gibi
```

`INNER`, `LEFT`, `RIGHT` ve `FULL` var (`OUTER` yazimi opsiyonel:
`LEFT OUTER JOIN` = `LEFT JOIN`). **`CROSS JOIN` da var** (2026-10-06):
`ON` **yoksa cartesius** carpanidir (her sol x her sag satir; kosul her
zaman dogru sayilir), `ON` yazildiysa INNER gibi filtre uygular;
`OUTER` ile birlestirilemez (`CROSS OUTER` -> `ecSyntaxError`).
**Zincir `JOIN` serbest** (soldan derine uygulanir, `A JOIN B JOIN C ...`);
turler karisabilir (`A LEFT JOIN B RIGHT JOIN C`, `A CROSS JOIN B JOIN C ...`).

```sql
SELECT p.ad, e.ad
FROM per p RIGHT JOIN eb e ON p.eid = e.id;   -- eslesmeyen eb satiri NULL-solla korunur

SELECT p.ad, e.ad
FROM per p FULL JOIN eb e ON p.eid = e.id;    -- iki taraf da korunur
```

Notlar:
- `RIGHT`/`FULL` klasik ic ice donguyle calisir (sol kume materyaldir,
  indeksli hizli yol uygulanamaz); cikti sirasi (sol kolonlar, sag
  kolonlar) degismez.
- Sonuc siniri: adim basi 2M satir (`ecLimit`).
- **`JOIN` + `GROUP BY`/aggregate desteklidir** (4.2, 2026-10-06): gruplama
  birlesim ciktisi uzerinden yapilir; `WHERE` (join kosulu her satirda),
  `HAVING` ve `ORDER BY`/`LIMIT` ayni kurallarla calisir. Aggregate'li
  sorguda `GROUP BY` yoksa sonuc **tek satirdir**.

```sql
SELECT m.sehir, COUNT(*) AS n
FROM siparis s JOIN musteri m ON s.mid = m.id
GROUP BY m.sehir ORDER BY n DESC;          -- nitelikli GROUP BY + aggregate
SELECT COUNT(*), SUM(s.tutar) FROM siparis s JOIN musteri m ON s.mid = m.id;
```

### Alt sorgular (iliskisiz)

```sql
SELECT ad FROM musteri WHERE bid IN (SELECT id FROM bolge);
SELECT ad FROM musteri WHERE bid NOT IN (SELECT id FROM bolge);
SELECT ad FROM musteri WHERE bid = (SELECT id FROM bolge WHERE ad = 'Ege');
SELECT ad FROM musteri WHERE EXISTS (SELECT id FROM bolge WHERE id = 1);
SELECT ad, (SELECT ad FROM bolge WHERE id = 1) AS b FROM musteri WHERE id = 1;
```

Kurallar:
- `IN` alt sorgusu **tek kolon** dondurmeli; skaler alt sorgu **tek satir
  x tek kolon** (satir yoksa `NULL`, cok satirsa hata).
- Iliskisiz ic sorgu **cumle basi bir kez** calisir (onbellekli); dis satir
  basina tekrar calismaz.
- **Iliskili** alt sorgu (ic sorgunun dis tabloya basvurmasi) **desteklenir**
  (F-03, 2026-10-07): dis satir basina yeniden calisir, onbelleklenmez.
  Ayrinti: "Iliskili (Correlated) Alt Sorgu" bolumu.
- `NULL` kurali liste davranisiyla aynidir: `NULL` deger eslesmez,
  `NOT IN` belirsizligi satiri eler.

### WITH-CTE (gecici adlandirilmis sonuc)

```sql
WITH tr AS (SELECT id, ad FROM musteri WHERE bid = 1)
SELECT ad FROM tr ORDER BY id;

WITH e AS (SELECT id FROM musteri WHERE bid = 1),
     x AS (SELECT id FROM e WHERE id > 1)
SELECT * FROM x;

WITH m AS (SELECT id, bid FROM musteri WHERE bid IS NOT NULL)
SELECT b.ad FROM bolge b JOIN m ON m.bid = b.id;
```

Kurallar:
- Liste sirayla materyallestirilir; sonraki CTE oncekileri gorebilir.
- `FROM` ve `JOIN` taraflarinda kullanilabilir; `WHERE`/`GROUP BY`/
  `ORDER BY`/`LIMIT` aynen calisir. Tek-tablo ic sorgularda kolon
  tipleri korunur (sayisal kiyas/siralama dogru calisir).
- Desteklenmez: `WITH RECURSIVE`, kolon alias'lari (`x(a,b)`),
  `WITH` + `INSERT/UPDATE/DELETE` (acik hata verirler).

### Kosullu ifade (CASE)

```sql
SELECT ad, CASE WHEN yas >= 18 THEN 'resit' ELSE 'cocuk' END AS durum
FROM personel;

SELECT CASE sehir WHEN 'Ankara' THEN 1 WHEN 'Izmir' THEN 2 ELSE 0 END AS kod
FROM personel;

SELECT ad FROM personel
WHERE CASE WHEN maas > 5000 THEN 1 ELSE 0 END = 1;
```

Kurallar:
- Aranan (`WHEN kosul`) ve sade (`CASE x WHEN deger`) bicimler var;
  `WHEN...THEN` zincirlenebilir, `ELSE` opsiyoneldir (yoksa `NULL`).
- `SELECT`, `WHERE`, `ORDER BY` icinde calisir; ic ice `CASE` serbesttir.
- Sade bicimde `NULL` eslesmez; tip-bilgili kiyas yapilir
  (sayisal kolonda `20` ile `'20'` eslesir).

### Pencere fonksiyonlari (OVER)

```sql
SELECT ad, ROW_NUMBER() OVER (PARTITION BY bolge ORDER BY tutar) AS rn
FROM satis;

SELECT ad, RANK() OVER (PARTITION BY bolge ORDER BY tutar) AS r,
       DENSE_RANK() OVER (PARTITION BY bolge ORDER BY tutar) AS dr
FROM satis;

SELECT ad, SUM(tutar) OVER (PARTITION BY bolge) AS toplam,
       COUNT(*) OVER (PARTITION BY bolge) AS adet
FROM satis;

SELECT ad, LAG(ad) OVER (ORDER BY id) AS onceki,
       LEAD(ad, 2, 'yok') OVER (ORDER BY id) AS sonraki
FROM satis;
```

Kurallar:
- Desteklenenler: `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `COUNT`, `SUM`,
  `AVG`, `MIN`, `MAX`, `LAG`, `LEAD`. Cerceve (`ROWS`/`RANGE`) yok:
  agregalar partition genelini hesaplar.
- `OVER` ici `PARTITION BY`/`ORDER BY` opsiyoneldir; bos `OVER ()`
  tum kumeyi tek partition sayar.
- `LAG`/`LEAD` varsayilan offseti 1'dir; ucuncu arguman partition
  disi icin varsayilan degerdir (yoksa `NULL`).
- Yalniz `SELECT` listesinde ust-duzey oge olarak kullanilabilir
  (`WHERE`/`HAVING`/`ORDER BY`/`JOIN ON` ve ic ice kullanim hata verir).
- `GROUP BY`/aggregate ile birlestirilemez; `ORDER BY` takma adla
  degil taban kolonla yazilir (motorun genel kurali).

### WHERE

Operatorler:

| Tur | Operatorler |
|---|---|
| karsilastirma | `=` `!=` `<>` `<` `>` `<=` `>=` |
| metin | `LIKE` / `NOT LIKE` (`%`, `?`, `_`) |
| kume | `IN (...)` / `NOT IN (...)`, `BETWEEN a AND b` / `NOT BETWEEN` |
| null | `IS NULL` / `IS NOT NULL` |
| mantik | `AND` `OR` `NOT` parantez |

```sql
WHERE a = 1
WHERE a <> 1
WHERE a >= 10 AND b = 'x'
WHERE a = 1 OR (b = 'x' AND c > 5)
WHERE ad LIKE 'A%'
WHERE ad IS NULL
WHERE ad IS NOT NULL
WHERE yas BETWEEN 18 AND 65
WHERE yas NOT BETWEEN 18 AND 65
WHERE sehir IN ('Izmir','Istanbul','Ankara')
WHERE sehir NOT IN ('Izmir','Istanbul')
WHERE NOT ad LIKE 'A%'
```

- `AND` / `OR` / parantez serbest karisim.
- `IS NULL` / `IS NOT NULL` **disinda hicbir operator NULL ile eslesmez**
  (`= NULL`, `<> NULL`, `> NULL`, `LIKE`, `IN`, `BETWEEN` dahil — hepsi
  0 satir doner). Tirnaksiz `NULL` literal deger WHERE'de de NULL sayilir.
- **NULL tarafi bilesik deger:** `x NOT IN (1,2,NULL)` satiri **dondurmez**
  (UNKNOWN), `x IN (1,2,NULL)` yalniz `x=1`/`x=2` ise dondurur.
- `IN (...)` icinde `?` parametresi kullanilabilir: `WHERE id IN (?,?,?)`.
- `IN (SELECT ...)` alt sorgu olarak calisir (bkz. alt sorgular bolumu).
- **Artik token reddedilir**: yazim hatasi ya da desteklenmeyen bir cumle
  sessizce yutulmaz, hata verir. (Sessizce yutulmak filtrelenmemis veri
  gosterirdi.)
- **`NOT (...)` tek kosul olmak zorunda.** Kosul temsili "OR'lu AND'ler"
  (DNF) oldugu icin `NOT (a=1 OR b=2)` ifade edilemez; bu yuzden De Morgan
  onerisi veren bir hata verilir: `a<>1 AND b<>2`.
  `NOT (a=1 AND b=2)` calisir.

### Tip-bilgili karsilastirma

Sadece **sayisal** kolonlarda deger sayisalla lastirilir:

```sql
-- y TEXT:  '007' ile '7' ESLESMEZ
-- n INTEGER: 7 ile '7' ESLESIR
```

Tirnaksiz sayi literal de metindir: `WHERE s = 7` TEXT kolonda `'7'` ile
karsilastirir (yani `'007'` ile eslesmez). `BETWEEN` de ayni kurali kullanir:
metin kolonda **byte (UTF-8) sirasi** esas alinir, `'007' < '7'`.

### Sayi bicimi her zaman nokta (locale bagimsiz)

```sql
INSERT INTO t(f) VALUES(2.5);     -- dogru
INSERT INTO t(f) VALUES(2,5);     -- HATA: virgul ayiractir, 2 deger olur
SELECT f FROM t;                  -- '2.5'  (tr-TR sistemde bile)
```

### Siralama / dilimleme

```sql
ORDER BY a                 -- varsayilan ASC
ORDER BY a DESC
ORDER BY a ASC, b DESC     -- coklu
LIMIT 10
LIMIT 10 OFFSET 20
OFFSET 20
```

`ORDER BY` **sorgunun en sonunda** yazilir. `OFFSET`/`LIMIT` sirali cikti
uzerinde uygulanir.

Siralama kurallari:

- **NULL (bos deger) her zaman en basta** siralanir; `DESC` ile en sonda.
- INTEGER kolonlar **tam sayi** olarak karsilastirilir (2^53'ten buyuk
  degerler de dogru siralanir).
- `ORDER BY <indeksli kolon>` indeksten okur; `LIMIT` kucukse yalnizca
  gereken kadar satir okunur (100.000 satirlik tabloda `LIMIT 10` ~0 ms).
- Indeks **tembel** kurulur: bir kolona ilk `ORDER BY`/`WHERE` yapilana kadar
  dosya acilisi beklemez. Indekslenmis bir tabloyu acmak, hicbir indeksi
  kullanmayan kadar hizlidir.

### GROUP BY + HAVING

```sql
SELECT dept, COUNT(*), SUM(maas), AVG(maas), MIN(maas), MAX(maas)
FROM personel
GROUP BY dept;
```

Aggregate fonksiyonlari: `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`.

`GROUP BY` kolon cozumleme **`SELECT`/`WHERE` ile ayni kuraldir**
(`FindColIdx`): nitelikli (`x.dept`, JOIN'de `m.sehir`) ve sade (`dept`)
yazim kabul edilir; sade yazim ilk eslesen kolona gider. Eslesmeyen kolon
`GROUP BY kolonu bulunamadi: ...` hatasi verir — **sessizce tek gruba
dusmez**. `JOIN` ciktisi uzerinde de aynen calisir (bkz. §JOIN).

`HAVING` yalniz `GROUP BY` veya aggregate tasiyan `SELECT` ile kullanilabilir
ve **cikti alanlarina gore** cozumlenir:

```sql
SELECT dept, COUNT(*) AS adet FROM personel
GROUP BY dept HAVING adet > 2;

SELECT dept, SUM(maas) AS top FROM personel
GROUP BY dept HAVING top >= 400;

SELECT dept, COUNT(*) AS adet FROM personel
GROUP BY dept HAVING dept = 'satis';
```

Kurallar:
- `HAVING` **gruplama kolonu** ya da `SELECT` listesinde **alias verilmis bir
  aggregate** uzerinden yazilir.
- **4.3 (2026-10-06): `HAVING` icinde dogrudan aggregate (`HAVING COUNT(*) > 1`)
  artik desteklenir**; `SELECT` listesinde alias olmasa da calisir (`HAVING
  COUNT(*) > 5`). Tip bilgisi `FindColIdx` ile cozulur (metin sirasi yerine
  sayisal karsilastirma). Alias kullanmaya devam edilebilir.
- `HAVING`'siz yazim `HAVING yalnizca GROUP BY veya aggregate ile kullanilabilir`
  hatasi verir (sessizce yutulmaz).

### Kume islemleri: UNION / UNION ALL / EXCEPT / INTERSECT

```sql
SELECT v FROM a UNION     SELECT v FROM b;   -- tekillestirir
SELECT v FROM a UNION ALL SELECT v FROM b;   -- tekrarlari korur
SELECT v FROM a EXCEPT    SELECT v FROM b;
SELECT v FROM a INTERSECT SELECT v FROM b;
SELECT v FROM a UNION SELECT v FROM b ORDER BY v LIMIT 2;
```

- Sutun sayilari esit olmak zorundadir, degilse hata verir.
- `ORDER BY` / `LIMIT` / `OFFSET` **birlesmis sonuca** uygulanir, sag
  tabloya degil. (Sag tabloya uygulansaydi sonuc fazla satir donerdi.)
- Anahtar sozcuk tirnak disinda, tam kelime olarak aranir: `'union'` gibi bir
  metin icindeki kelime operator sayilmaz.
- Zincirleme kullanilabilir (`a UNION b UNION c`).

### Skaler fonksiyonlar ve Turkce siralama

```sql
SELECT UPPER(ad), LOWER(sehir) FROM kisi;
SELECT LENGTH(ad) FROM kisi;            -- karakter sayisi (metin)
SELECT LENGTH(ham) FROM foto;           -- bayt sayisi (BLOB)
SELECT ad FROM kisi ORDER BY ad COLLATE TR;
SELECT ad FROM kisi ORDER BY ad COLLATE TR DESC;
SELECT ad FROM kisi WHERE UPPER(ad) = UPPER('cocuk');  -- harf duyarsiz arama
```

- `UPPER`/`LOWER` Turkce duyarlidir (`i->İ`, `I->ı`; sistem yerel
  ayarindan bagimsiz). `LENGTH` metinde karakter, `BLOB`'da bayt sayar.
- `COLLATE TR` Turk alfabesi sirasi uygular
  (`...c,ç,d...g,ğ,h,ı,i...o,ö,p...s,ş,t...u,ü,v...`); harf-disi
  karakterler kod noktasina gore harflerden once gelir. Bilinmeyen ad
  hata verir (yalniz `TR` desteklenir).
- `COLLATE TR` indeksi kullanmaz (indeks bayt duzenindedir); dogru ama
  yavas yola duser. `=` karsilastirmasi bayt-ayni kalir (degismedi).

## 7. UPDATE

```sql
UPDATE t SET a = 1;
UPDATE t SET a = 1, b = 'x' WHERE id = 5;
UPDATE t SET a = NULL WHERE id = 5;      -- NULL yazmak icin bos deger
```

`WHERE` yoksa **tum satirlar** guncellenir. UNIQUE / PK / CHECK / FK ihlali
hata verir; **degisen referans kolonunda** cocuk tabloya `ON UPDATE` aksiyonu
uygulanir (`CASCADE` cocuk FK kolonunu yeni degere ceker).

### SET icinde aritmetik (satir basina hesaplanir)

```sql
UPDATE t SET sayac = sayac + 1;             -- en sik kullanim
UPDATE t SET sayac = sayac - 1 WHERE id = 5;
UPDATE t SET puan  = puan * 2;
UPDATE t SET yarim = yarim / 2;              -- INTEGER kolonda tam bolme
UPDATE t SET kalan = kalan % 3;
UPDATE t SET toplam = fiyat * adet;          -- kolon + kolon
UPDATE t SET n = 5 WHERE id = 3;             -- duz deger (eski davranis)
```

Kurallar:

- Islemler: `+  -  *  /  %`. Sadece **sayisal** kolonlarda (INTEGER, FLOAT,
  BOOLEAN). Metin kolonda aritmetik **hata verir** (sessizce sayiya
  cevrilmez — veri bozulmaz).
- `/` INTEGER kolonda **tam bolmedir** (`7 / 2` -> `3`); FLOAT kolonda
  kayan nokta. Sifira bolme ve sifira modulo hata verir.
- Ifadenin **sol tarafı bir kolon olmak zorundadır**: `SET b = n * 2`
  -> `b := n * 2` (SQL semantiği; hedef kolon `b` degil, ifade `n * 2`).
- NULL baslayan bir kolonda `NULL + 1` sonucu **NULL** kalır.
- `LIMIT` yoktur; `WHERE` ile daraltın. Tum satirlarda ayni islem yapılacaksa
  tek `UPDATE ... WHERE ...` yazmak 5000 ayri komuttan hizlidir.

## 8. DELETE

```sql
DELETE FROM t;
DELETE FROM t WHERE id = 5;
```

Cocuk tablo varsa `ON DELETE` aksiyonu uygulanir; `RESTRICT` ise silmeyi
engeller. Ayni anda birden fazla cocuk varsa once hepsi denetlenir.

## 9. Bakim

```sql
SHOW TABLES;          -- tablo + satir sayilari
VACUUM;               -- compact: olu surumler + tombstone'lari temizler (.bak birakir)
REINDEX;              -- bellek indekslerini veriden yeniden kurar
```

## 10. JSON degisim

```sql
EXPORT JSON 'yedek.json';                -- sema + tum veri
EXPORT TABLE kisi JSON 'kisi.json';      -- tek tablo
IMPORT JSON 'yedek.json';                -- sema dahil (pk/notnull/unique/
                                        -- default/checks/fks/aksiyonlar)
```

## 11. Parametreli calistirma (SQL metninde tek tirnak gerekmez)

```pascal
r := sq.Exec('SELECT * FROM t WHERE ad = ? AND yas > ?', ['Ali', '20']);
```

`?` sirayla `Params` dizisinden gelir. Tirnak/escape sorunu olmaz.

---

## Desteklenmeyenler (bilerek yok)

- `WITH RECURSIVE` — **R-10 ile desteklenir** (gercek ozyineleme: anchor `UNION ALL` recursive; delta/semi-naive degerlendirme; `CYCLE col SET is_cycle USING path` ile sonsuz dongu korumasi). Asagidakiler hâlâ sinirli: `WITH` kolon alias'lari, `WITH` + DML (4.5'te acildi ama DML yurutucusu kismi).
- `Pencere cercevesi` (`ROWS`/`RANGE` tam partisi) — **4.6 acik** (ParseOver `ROWS`/`RANGE` + ComputeWindows basit birikim; tam frame `FOLLOWING` / `UNBOUNDED` + `BETWEEN ... AND` sinirlidir).
- `NOT (...)` cok kosullu `OR` (`Length>1`) — **4.4 acik** (`NegateGroup` De Morgan tek-koşullu `NOT (a OR b)` -> `NOT a AND NOT b`; DNF temsil siniri cok kosullu OR'yi ifade edemez, AST `NotNode` ile calisir, `ParseWhereGroups` hash-join WHERE yolu ile tam DNF dispatch yok).
- `ALTER TABLE ... ADD/DROP CONSTRAINT` (CHECK/FK) — **parser acik** (`ataAddConstraint`), yurutucu sinirli (sema kontrol, veri yeniden kodlanmaz).
- `CREATE VIEW` — **tam destek** (VIEW DML: INSERT/UPDATE/DELETE çalışıyor; basit updatable view, alias kolon mapping, base table redirection; non-updatable view DML'de reddedilir).
- `CREATE TRIGGER`, `CREATE PROCEDURE` — **parser acik**, yurutucu/kalemi sinirlidir.
- `Iliskili alt sorgu` (correlated subquery) — **F-03 ile desteklenir** (EXISTS/NOT EXISTS/IN/skaler; onbellek devre disi; 2 seviye derinlik siniri).
- `PRAGMA` — **parser + admin acik** (`admPragma` + `ExecAdmin` case); bilgi komutlari `SHOW` ile iliskilidir.
- **`SELECT ... AS OF TIMESTAMP/VERSION`** — zaman yolculugu sorgusunda
  yalnizca **`AS OF SEQUENCE <n>`** cozumlenur (n = WAL kayit indeksi).
  `TIMESTAMP`/`VERSION` **reddedilir**: WAL kayitlarinda ne zaman damgasi
  ne surum numarasi vardir. Buna ek olarak `JOIN` + `AS OF`, `WITH` +
  `AS OF`, gecmisi olmayan istek (WAL kapali / checkpoint sonrasi) ve
  gecmis semasi farkli satirlar `ecUnsupported` ile **acikca hata verir** —
  sessizce guncel cevap donmez. Ayrinti §0b ->
  "`SELECT ... AS OF SEQUENCE`". API karsiligi: `TVTimeTravel.GetValueAt` /
  `GetRowAt` (WAL gecmisinden okur) ve `ParseSnapshotSpec` (yalniz metni
  dogrular; `TVTimeTravel.ExecSnapshot` aktif snapshot'ta acikca hata verir).

## ILIKE (F-05, 2026-10-07)

`LIKE` buyuk/kucuk harfe **duyarlidir**. `ILIKE` (PostgreSQL/SQLite uyumu) ayni
deseni **duyarsiz** uygular; jokerler (`%`, `_`) aynen calisir:

```sql
SELECT ad FROM t WHERE ad LIKE  'ali%';    -- sadece 'ali...'
SELECT ad FROM t WHERE ad ILIKE 'ali%';    -- 'Ali', 'ALI', 'ali' hepsi
SELECT ad FROM t WHERE ad ILIKE '%OE%';    -- icinde oe/OE
SELECT ad FROM t WHERE ad ILIKE 'z_e';     -- _ tek karakter
SELECT ad FROM t WHERE ad NOT ILIKE 'a%';  -- NOT ILIKE desteklenir
```

- Turkce `I` donusumu dogru calisir: `ILIKE 'ali'` -> `Ali`, `ALI`, `ali` eslesir.
- `NULL` deger `ILIKE` ile eslesmez (uc-degerli mantik: satir elenir).

---

## ANY / SOME / ALL (F-06, 2026-10-07)

Kuantifikatorlar alt sorgu kumesi uzerinde **toplu karsilastirma** yapar:

```sql
-- x = ANY (kume)  ==  x IN (kume)
SELECT id FROM t WHERE n = ANY (SELECT n FROM u WHERE n > 15);

-- x > SOME (kume)  ==  x > ANY (kume)   (SOME, ANY'in es adi)
SELECT id FROM t WHERE n > SOME (SELECT n FROM u WHERE n < 25);

-- x < ALL (kume)  ->  tum satirlar icin x < deger
SELECT id FROM t WHERE n < ALL (SELECT n FROM u WHERE n > 15);
```

Kurallar:
- `ANY`/`SOME`: **en az bir** satir saglarsa `TRUE`.
- `ALL`: **tum** satirlar saglarsa `TRUE`; **bos kume** `TRUE` doner (vakuum).
- Alt sorgu **tek kolon** dondurmeli, aksi halde hata.
- Alt sorgu degerinde `NULL` varsa sonuc `UNKNOWN` olabilir (satir elenir).
- Yalniz `=`, `<>`, `<`, `<=`, `>`, `>=` ile kullanilir.
- Alt sorgu **iliskili** olabilir (dis satira baglanabilir).

---

## FETCH FIRST / NEXT (F-08, 2026-10-07)

`LIMIT`/`OFFSET`in SQL:2008 standart yazimi:

```sql
SELECT * FROM t ORDER BY id FETCH FIRST 10 ROWS ONLY;   -- LIMIT 10
SELECT * FROM t ORDER BY id FETCH NEXT 5 ROWS ONLY;     -- LIMIT 5
SELECT * FROM t ORDER BY id FETCH FIRST ROWS ONLY;      -- LIMIT 1 (n yoksa 1)
SELECT * FROM t ORDER BY id FETCH FIRST 5 ROWS ONLY OFFSET 10 ROWS;
```

Kurallar:
- `FIRST` ve `NEXT` ayni anlama gelir (`OFFSET`aten baslar).
- `n` yazilmazsa `1` kabul edilir (`FETCH NEXT ROWS ONLY`).
- `ROW` ve `ROWS` ikisi de kabul edilir.
- `FETCH WITH TIES` **desteklenmez** (bag ile kirpilma gerekir; `LUSTE` kullanin).
- `OFFSET n ROWS` yazimi `LIMIT`/`OFFSET` yolunda da kabul edilir.

---

## NULLS FIRST / NULLS LAST (F-10, 2026-10-07)

Varsayilan: NULL "en kucuk" sayilir (SQL:2003) -> `ASC`'de **once**, `DESC`'de **sonra**.
Isterseniz yonu degistirebilirsiniz:

```sql
SELECT * FROM t ORDER BY ad ASC NULLS LAST;    -- NULL'lar en sona
SELECT * FROM t ORDER BY ad ASC NULLS FIRST;   -- NULL'lar en basa
SELECT * FROM t ORDER BY ad DESC NULLS FIRST;  -- yön bagimsiz: NULL'lar basa
SELECT * FROM t ORDER BY ad DESC NULLS LAST;   -- yön bagimsiz: NULL'lar sona
```

Kurallar:
- `NULLS FIRST/LAST` **yön bagimsizdir**: `DESC` ile terslenmez.
- Sira serbest: `ORDER BY ad COLLATE TR DESC NULLS LAST`.
- `NULLS` sonrasi yalniz `FIRST` veya `LAST` gelir; `NULLS MIDDLE` hata verir.
- Pencere fonksiyonlarinun kendi `ORDER BY`'si icinde de kullanilabilir.

---

## QUALIFY (F-09, 2026-10-07)

Pencere fonksiyonu hesaplandiktan **sonra** uygulanan filtre
(`HAVING` gibi ama gruplamadan sonra; Snowflake/Oracle/DuckDB uyumu):

```sql
-- Her partition'da ilk satiri getir
SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn
  FROM t
 QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) = 1;

-- Her partition'da ilk 2 satiri getir
SELECT ad, ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) AS rn
  FROM t
 QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY v) <= 2;
```

Kurallar:
- `QUALIFY` **yalnizca pencere fonksiyonu iceren** sorgularda kullanilabilir;
  aksi halde `ecUnsupported` verir.
- Sira: `FROM` -> `WHERE` -> `GROUP BY`/`HAVING` -> `QUALIFY` -> `ORDER BY` -> `LIMIT`.
- `QUALIFY` sonrasi `ORDER BY`/`LIMIT` normal calisir.

---

## COUNT/SUM/AVG/MIN/MAX(DISTINCT) (F-11)

Aggregate'lerde `DISTINCT` tekrarli degerleri bir kez sayar:

```sql
CREATE TABLE t(id INTEGER, v INTEGER);
INSERT INTO t VALUES(1,10),(2,20),(3,10),(4,30),(5,20);

SELECT COUNT(v) FROM t;               -- 5
SELECT COUNT(DISTINCT v) FROM t;      -- 3  (10, 20, 30)
SELECT SUM(v) FROM t;                 -- 90
SELECT SUM(DISTINCT v) FROM t;        -- 60 (10+20+30)
SELECT AVG(DISTINCT v) FROM t;        -- 20
SELECT MIN(DISTINCT v) FROM t;        -- 10
SELECT MAX(DISTINCT v) FROM t;        -- 30
```

- `NULL` degerler `DISTINCT` kumesine **girmez** (SQL standardi).
- `GROUP BY` + `HAVING` ile birlikte calisir:
  `SELECT ad FROM t GROUP BY ad HAVING COUNT(DISTINCT v) > 1`
- `COUNT(DISTINCT *)` her zaman **1** doner (tek yildiz).

---

## STRING_AGG (F-14)

Metin degerleri bir metinde birlestirir (PostgreSQL/Oracle uyumu):

```sql
SELECT STRING_AGG(ad, ', ') FROM t;              -- varsayilan ayirac: ','
SELECT STRING_AGG(ad, ' | ') FROM t;             -- ozel ayirac
SELECT STRING_AGG(DISTINCT ad, ',') FROM t;      -- tekrarlar elenir
SELECT ad, STRING_AGG(ad, ',') FROM t GROUP BY ad;
```

- Ayirac ikinci argumandir; verilmezse `,` kullanilir.
- `DISTINCT` tekrarli degerleri eler.
- `NULL` degerler atlanir.
- Sadece `GROUP BY`/aggregate sorgularinda kullanilabilir.
- Cikti sirasi tablo satir sirasina baglidir (deterministik degil).

---

## PERCENTILE_CONT / PERCENTILE_DISC (F-15)

Yuzdelik hesaplama (PostgreSQL uyumu):

```sql
SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM t;  -- medyan
SELECT PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY v) FROM t;  -- kesilmis medyan
SELECT PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY v) FROM t;  -- p90
```

- `PERCENTILE_CONT(0.5)`: iki komsu deger arasinda **enterpolasyon** yapar.
- `PERCENTILE_DISC(0.5)`: gercek bir veri degeri doner (kesilmis).
- Oran **0..1** araliginda olmali (`0.5` = yuzde 50).
- `WITHIN GROUP (ORDER BY kolon)` zorunludur.
- `NULL` degerler atlanir; hepsi NULL ise sonuc NULL.
- Sayisal degerler varsa lineer enterpolasyon, metin degerlerde ilk nokta doner.

---

## FILTER (WHERE ...) (F-16)

Aggregate'e satir filtresi ekler (PostgreSQL/Oracle/SQL Server uyumu):

```sql
SELECT COUNT(*) FILTER (WHERE p = 1) FROM t;        -- sadece p=1 satirlari
SELECT SUM(v) FILTER (WHERE v > 20) FROM t;        -- sadece v>20 toplanir
SELECT AVG(v) FILTER (WHERE p = 2) FROM t;
SELECT COUNT(DISTINCT ad) FILTER (WHERE v > 15) FROM t;
```

- Yalniz `COUNT`/`SUM`/`AVG`/`MIN`/`MAX` ile kullanilir (aggregate olmayan
  fonksiyonda hata verir).
- `DISTINCT` ile birlikte calisir.
- `GROUP BY` + `HAVING` icinde de kullanilir:
  `SELECT p FROM t GROUP BY p HAVING SUM(v) FILTER (WHERE v > 15) > 0`
- Filtre sonucu bos kume ise: `COUNT` → `0`, `SUM`/`AVG`/`MIN`/`MAX` → `NULL`.
- `OVER` (pencere) ile birlikte **kullanilamaz**.

---

## EXPLAIN / EXPLAIN ANALYZE (F-20)

Sorgu planini raporlar. `QUERY PLAN` tek kolonlu sonuc doner:

```sql
EXPLAIN SELECT * FROM ex;                    -- Seq Scan on ex
EXPLAIN SELECT * FROM ex WHERE id = 1;       -- Index Scan ... _pkey
EXPLAIN SELECT * FROM ex WHERE v = 10;       -- Index Scan using ix_v
EXPLAIN SELECT a.* FROM ex a JOIN ex b ON a.id = b.id;  -- Nested Loop Join
EXPLAIN SELECT ad, COUNT(*) FROM ex GROUP BY ad;       -- + Aggregate, Group
EXPLAIN ANALYZE SELECT * FROM ex WHERE id = 1;  -- calistirir + Actual Rows
```

Plan satirlari:
| Satir | Anlami |
|---|---|
| `Seq Scan on T` | tam tarama |
| `Index Scan using IX on T` | indeks kullanimi (`IX` = indeks adi) |
| `Index Scan using T_pkey on T` | PK nokta aramasi |
| `Nested Loop Join` + `-> Seq Scan` | JOIN (ic ice dongu) |
| `CTE Scan on T` | CTE materyalinden okuma |
| `Aggregate` / `Group` | GROUP BY/aggregate |
| `WindowAgg` | pencere fonksiyonu |
| `Qualify` | QUALIFY filtresi (F-09) |
| `Sort` / `Limit` | ORDER BY / LIMIT |
| `Actual Rows: n` | yalniz ANALYZE: gercek satir sayisi |
| `Execution Time: n ms` | yalniz ANALYZE: gecen sure |

- `EXPLAIN` cumleyi **calistirmaz** (veri degismez).
- `EXPLAIN ANALYZE` cumleyi **calistirir** ve sureyi olcer.
- `INSERT`/`UPDATE`/`DELETE` icin de calisir (`Insert on T`, `Update on T`, …).

---

## PARTIAL INDEX (F-17)

`WHERE` kosuluyla sinirlandirilmis indeks — yalnizca kosulu saglayan satirlar
indekslenir. Klasik kullanim: tablonun %2'si `aktif = 1` ise, tum tabloyu
indekslemek yerine yalnizca aktif satirlar indekslenir.

```sql
CREATE INDEX ix_aktif ON pi(v) WHERE aktif = 1;
CREATE INDEX ix_ikili  ON pi(v) WHERE aktif = 1 AND v > 25;
CREATE INDEX ix_sehir ON pi2(n) WHERE sehir = 'Istanbul';
CREATE UNIQUE INDEX ux_pi ON pi(ad) WHERE aktif = 1;
CREATE INDEX ix_cok   ON pi(aktif, v) WHERE v >= 30;   -- cok kolonlu
```

Yazim desteklenen kosul dilinde:

| Bicim | Ornek |
|---|---|
| karsilastirma | `aktif = 1`, `v > 25`, `v <= 100`, `ad <> 'x'` |
| `IS [NOT] NULL` | `ad IS NOT NULL` |
| `IN` listesi | `sehir IN ('Istanbul','Ankara')` |
| birlestiriciler | `a = 1 AND b > 2`, `a = 1 OR b > 2` |
| parantez | `(a = 1 AND b > 2) OR c = 3` |

Karmaşık ifadeler (`LIKE`, fonksiyon cagrisi, `NOT`, alt sorgu) **desteklenmez**
— parser kabul eder ama indeks **bos** kurulur (kayıt sayısı 0). Bu
bilinçlidir: indeks yalnizca daraltma aracıdır, yanlış bir indeks girdisi
sorgu sonucunu bozamaz (`WHERE` yeniden doğrular). `LIKE`/`NOT` gibi bir
koşulla indeks kurmak istiyorsanız normal indeks kullanın.

`SHOW INDEXES` çıktısı:

| Kolon | Anlamı |
|---|---|
| `index` | indeks adı |
| `unique` | UNIQUE mi |
| `columns` | indeks kolonları |
| `ncols` | kolon sayısı |
| `kind` | `tek kolunlu` / `cok kolunlu` |
| `predicate` | partial koşulu metni (`''` = normal indeks) |
| `nentries` | **indeks içindeki kayıt sayısı** (partial'da tablo satır sayısından küçük olabilir) |

```sql
-- pi: 5 satır, aktif=1 olan 3 satır
SHOW INDEXES FROM pi;
  index     | unique | columns | ncols | kind       | predicate   | nentries
  ix_aktif  | False  | v       | 1     | tek kolunlu | (aktif = 1) | 3
```

`nentries` partial indeksin **içeriğini doğrulamak için** tek gözlenebilir
ölçütür: sorgu sonuçları indeksin doluluğundan bağımsız olduğu için (indeks
sadece ön daraltma yapar) kayıt sayısını görmek zorunludur.

Sema korunur: veritabanı kapatılıp açıldığında `predicate` yeniden okunur ve
`REINDEX` aynı kayıt kümesini üretir.

Yazma yolu kuralları:

- `INSERT`: koşulu sağlayan satır indekslenir, sağlamayan **girmez**.
- `DELETE`: satır indeksden düşer.
- `UPDATE`: koşul indeks kolonlarından **bağımsız** olabileceğinden
  (`CREATE INDEX ix ON t(v) WHERE aktif = 1` + `UPDATE t SET aktif = 0`)
  partial indeksler her UPDATE'te yeniden değerlendirilir.

Aynı kolonda hem normal hem partial indeks bir arada bulunabilir.

---

## EXPRESSION INDEX (F-18)

İfadenin **değerine** göre indeks — kolon yerine. Klasik kullanım: büyük/küçük
harf duyarsız arama (`LOWER(ad)`), uzunluk, aritmetik ifade.

```sql
CREATE INDEX ix_lower ON ei(LOWER(ad));
CREATE INDEX ix_upper ON ei(UPPER(ad));
CREATE INDEX ix_trim  ON ei(TRIM(ad));
CREATE INDEX ix_len   ON ei(LENGTH(ad));
CREATE INDEX ix_sum   ON ei(n + 1);
CREATE INDEX ix_abs   ON ei(ABS(f - 3.5));
CREATE UNIQUE INDEX ux_ei ON ei(LOWER(ad));
CREATE INDEX ix_low   ON ei(LOWER(ad)) WHERE aktif = 1;   -- partial + ifade
```

### Desteklenen ifade dili

| Tür | Örnek |
|---|---|
| fonksiyon | `LOWER` `UPPER` `TRIM` `LENGTH` `ABS` (tek argüman) |
| aritmetik | `+` `-` `*` `/` |
| atom | kolon, sayı, `'metin'` |
| karışım | `(n * 2) + 1`, `LENGTH(TRIM(ad))` |

**Türkçe büyük/küçük harf kuralı uygulanır** (`VDbTrLower`/`VDbTrUpper`):

```sql
SELECT ad FROM ei WHERE LOWER(ad) = 'velı';   -- 'VELI' bulunur  (noktasız ı)
SELECT ad FROM ei WHERE LOWER(ad) = 'veli';   -- bulunmaz        (noktalı i)
SELECT ad FROM ei WHERE UPPER(ad) = 'ALİ';    -- 'Ali' bulunur   (noktalı İ)
```

Bu, `LOWER()` fonksiyonunun motor genelinde zaten kullandığı semantikle
**aynıdır** — indeks ve tarama aynı sonucu üretir.

### NULL davranışı

SQL'e uygun olarak **NULL yayılır**: `LOWER(NULL)`, `LENGTH(NULL)` ve
`n + 1` (n NULL iken) → NULL. NULL anahtarlı satırlar **indekslenmez**
(`nentries` bunu yansıtır). NULL `UNIQUE` ihlali sayılmaz.

### Tip çıkarımı

İfadenin tipi değerlendirme sırasında çıkarılır: sayısal kolon/işlem →
`INTEGER`/`REAL`, aksi halde metin. **Tip güvenle belirlenemiyorsa indeks
o satıra girmez** (güvenli taraf) — yanlış sıralamadan dolayı **satır
kaybı yaşanamaz**.

### Gözlem

`SHOW INDEXES` çıktısında:

| Kolon | Değer |
|---|---|
| `columns` | indeks ifadesi (`LOWER(ad)`) |
| `kind` | `ifade` |
| `expr` | ifade metni (kolon indeksinde `''`) |
| `nentries` | indekslenen satır sayısı |

Sema korunur: `CREATE INDEX …:@LOWER(ad)` olarak düz metinle yazılır (ifade
dilinde `:`, `#`, `|` geçemediği için hex gerekmez), yeniden açılışta geri
okunur.

Yazma yolu `INSERT`/`UPDATE`/`DELETE` ile birlikte çalışır; `UNIQUE` ifade
indeksi `CREATE UNIQUE INDEX` ile gerçekten zorlanır (aksiyi `CheckConstraints`
denetler).

> **Kapsam notu:** İfade indeksi şu an **içerik ve kısıt** tarafında tam
> çalışır; `EXPLAIN`/sorgu hızlandırma (planner) entegrasyonu ayrı bir
> adımdır. Sorgu doğruluğu hiçbir zaman indeksin varlığına bağlı değildir —
> `WHERE` daima yeniden uygulanır.

---

## COVERING INDEX — `INCLUDE` (F-19)

Anahtar kolonlara ek olarak **yalnızca okunacak** kolonları indeksin içinde
taşır. Böylece tablo satırına hiç dokunmadan sonuç üretilebilir
(*index-only scan*).

```sql
CREATE INDEX ix_a ON ci(a) INCLUDE (b, c);
CREATE UNIQUE INDEX ix_u ON t(a) INCLUDE (b);
CREATE INDEX ix_c3 ON ci3(n) INCLUDE (et) WHERE et > 1;   -- partial ile birlikte
```

### `INCLUDE` kolonları anahtar **değildir**

| Özellik | Davranış |
|---|---|
| Sıralama / aralık taraması | `INCLUDE` kolonları **girermez** |
| `UNIQUE` denetimi | `INCLUDE` kolonları **girermez** (benzersizlik yalnız anahtarda) |
| Tekrarlı kolon | Anahtar kolonla aynı → hata (`INCLUDE kolonu anahtar kolonla ayni`) |
| Tekrarlı `INCLUDE` | Hata (`INCLUDE kolonu iki kez`) |
| Olmayan kolon | Hata (`INCLUDE kolonu yok`) |

### Index-only scan ne zaman kullanılır?

Sorgu satırları, indeks girdisindeki **anahtar + `INCLUDE` + PK** kolonlarıyla
tam olarak karşılandığında tablo okunmaz:

```sql
-- ci(id, a, b, c); CREATE INDEX ix_a ON ci(a) INCLUDE (b, c)
EXPLAIN SELECT b, c FROM ci WHERE a = 20;
-- Index Only Scan using ix_a on ci

-- ci2(id, a, b, d); CREATE INDEX ix_a2 ON ci2(a) INCLUDE (b)
-- 'd' kapsanmadigi icin tablo okunmak ZORUNDA
EXPLAIN SELECT b FROM ci2 WHERE a = 20;
-- Index Scan using ix_a2 on ci2
```

**PK kolonu özeldir:** satır adresi (`Entry.Pk`) zaten PK değerini içerdiğinden
kapsama sayılır — PostgreSQL'deki “indeks TID + PK saklar” davranışının
karşılığı.

Kapsama denetimi **iki bağımsız katmanda** yapılır (karar + satır üretimi):
ikisi de devre dışı kalırsa kapsanmayan kolon sessizce boş kalır ve **sorgu
sonucu yanlış** olur. Bu yüzden her iki katman da testlerle doğrulanmıştır.

### `INCLUDE` kolonu değişirse

`UPDATE ci SET c = 555` — `c` indeks anahtarı olmadığı için "değişen kolon"
taraması onu kaçırırdı. `INCLUDE` kolonları bu nedenle indeksin bağımlılık
setine **dahildir** ve her değişiklikte girdi yenilenir.

### Gözlem

`SHOW INDEXES.include` kolonu listeyi virgülle gösterir
(`b,c` / `et` / normal indekste `''`).

Sema biçimi: `ix_ad:anahtar$include1;include2#hex(koşul)`
(`$` ifade indeksi metnindeki `+` ile, `,` ise sema satırının kolon listesi
ayırıcısıyla çakıştığı için seçildi; `;` ile ayrıldı).

---

## YAVAS SORGU TESPİTİ (F-21)

Her cümlenin süresi ölçülür; eşiği aşanlar **halka tampon** bir günlüğe
yazılır.

```sql
SET SLOW_QUERY_MS = 200;    -- 200 ms üstü cümleler kaydedilir
SET MAX_SLOW_ENTRIES = 100; -- halka tampon boyutu
SHOW SLOW QUERIES;           -- kayıtları en yavaştan başlayarak raporlar
```

### Eşik anlamı

| Değer | Anlamı |
|---|---|
| `-1` | **kapalı** (varsayılan — hiçbir günlük yazılmaz) |
| `0` | **her cümle** kaydedilir (“hepsini ölç” / teşhis modu) |
| `N > 0` | süresi **≥ N ms** olan cümleler kaydedilir |

> `0` modu teşhis ve test için: süre ölçümü bazı donanımlarda `0 ms`
> okunabildiği için “her cümle” kipi deterministik davranış verir.

### `SHOW SLOW QUERIES` çıktısı

| Kolon | Anlamı |
|---|---|
| `ms` | ölçülen süre (ms) |
| `rows` | dönen satır sayısı (`-1` yoksa) |
| `seq` | yavaştan hızlıya sıra numarası |
| `sql` | cümlenin tam metni (500 karaktere kırpılır) |

### Halka tampon

Günlük **sınırsız büyümez**: `MAX_SLOW_ENTRIES` dolunca en eski kayıt düşer
ve yerine yeni kayıt gelir.

### Ölçümün kapsamı

Süre **ayrıştırma + yürütme** toplamıdır (kullanıcının beklediği süre).
`SELECT`, `INSERT`, `UPDATE`, `DELETE` ve `DDL` — hepsi ölçülür.

### Programatik API (DLL/ODBC katmanı için)

```pascal
sq.SlowThresholdMs := 200;     // ölçüm + kayıt aç
sq.LastElapsedMs;              // son cümlenin süresi
sq.SlowQueryCount;             // kaç kayıt var
sq.ClearSlow;                  // günlüğü temizle
```

### Zamanlayıcı çözünürlüğü — önemli not

FPC `SysUtils.Now` Windows’ta `GetSystemTimeAsFileTime` üzerinden çalışır ve
**~15.6 ms** granülariteye sahiptir; bu yuvarlamayla “hangi sorgu yavaş?”
sorusu pratikte cevaplanamaz (çoğu sorgu `0 ms` okunur). Bu yüzden:

| Platform | Kaynak | Duyarlılık |
|---|---|---|
| Windows | `GetTickCount64` | ~1 ms |
| Diğer | `Now` farkı | ~1–15 ms (platforma göre) |

Ölçüm `{$IFDEF MSWINDOWS}` ile seçilir; çağıran kod iki durumda da aynı tipte
(`Int64` ms) sonuç alır.

---

## JSONB SORGULAMA (F-22)

JSON metni (genelde `TEXT` kolonunda) üzerinde PostgreSQL `jsonb` operatörleri.
Motor JSON'u ayrıştırır ve **yapısal** karşılaştırma yapar — metin eşitliği değil.

```sql
CREATE TABLE j(id INTEGER PRIMARY KEY, d TEXT);
INSERT INTO j VALUES(1,'{"ad":"Ali","yas":30,"etiket":["a","b"],
                        "adres":{"il":"Ankara","ilce":"Cankaya"}}');

SELECT * FROM j WHERE d @> '{"ad":"Ali"}';                    -- içerme
SELECT * FROM j WHERE d @> '{"adres":{"il":"Ankara"}}';        -- iç içe
SELECT * FROM j WHERE d ?  'ad';                              -- anahtar var mı
SELECT * FROM j WHERE d ?| ('ad','yok');                      -- en az biri
SELECT * FROM j WHERE d ?& ('ad','yas');                      -- hepsi
SELECT * FROM j WHERE '{"ad":"Ali"}' <@ d;                     -- ters yön
```

### `?` iki anlamlı — parametre yer tutucusu da

`?` hem JSONB anahtar operatörü hem de parametre yer tutucusudur. Ayrım kuralı:

| Durum | Anlam |
|---|---|
| `Exec(sql)` — parametre **bağlanmamış** | `?` = **anahtar operatörü** |
| `Exec(sql, params)` — parametre **bağlanmış** | `?` = **yer tutucu** |

Yani parametreli API değişmez, ama `d ? 'anahtar'` yazılabilir. Parametreler
tukendikten sonra gelen `?` yine operatördür:

```pascal
sq.Exec('SELECT ... WHERE d @> ? AND d ? ''a''', ['{"a":1}']);
--        ^^^^^^^^^^^ yer tutucu            ^^^^^^^ operator
```

### `@>` = **içerme**, eşitlik değil

En sık yapılan hata: `@>` "eşit mi" sanmak. İçermedir — sol tarafta **fazladan
anahtar/öğe olabilir**:

```sql
-- d = {"ad":"Ali","yas":30,"etiket":["a","b"],"adres":{...}}
d @> '{"ad":"Ali","yas":30}'   -> TRUE   (fazla anahtarlar sorun değil)
d @> '{"ad":"Ali","yas":31}'   -> FALSE  (değer farklı)
```

İç içe değerlerde de **içerme** kullanılır:
`{"adres":{"il":"Ankara"}}`, `{"adres":{"il":"Ankara","ilce":"Cankaya"}}` içinde
bulunur.

### Anahtar sırası önemsizdir

JSON bir sözlüktür; anahtar sırası semantik değildir. Eşleşme **adla** yapılır:

```sql
d @> '{"adres":{"ilce":"Cankaya","il":"Ankara"}}'   -> TRUE
```

Konum bazlı karşılaştırma **yanlış eşleşme** üretir:
`{"a":{"x":1},"b":{"x":1}}` içinde `{"zzz":{"x":1}}` bulunmaz (anahtar yok).

### NULL davranışı

SQL'e uygun: JSON metni `NULL` ise sonuç **UNKNOWN** (`WHERE` filtresine girmez).
`?|`/`?&` listelerindeki `NULL` öğeler yok sayılır.

### Geçersiz JSON → `FALSE`, hata değil

Ayrıştırılamayan metin (ör. `'{bozuk'`) hata vermez, `@>` sonucu `FALSE` olur.
Bu **bilinçlidir**: sorgu bir satırı yanlışlıkla dışlamak yerine içerir; kullanıcı
kendi filtresini düzeltir. Veri katmanı bozulmaz.

### Dizi JSON'u

| İfade | Sonuç |
|---|---|
| `["a","b"] ? 'a'` | `TRUE` — dizide `?` **eleman** arar |
| `["a","b"] @> '"a"'` | `TRUE` |
| `["a","b"] @> '["c"]'` | `FALSE` |
| `["a","b"] @> '["a","b","c"]'` | `TRUE` (her öğe bulunur) |

> **Kapsam:** `?` operatörü çift taraflı kullanılamaz (`col ? 'a' ? 'b'` desteklenmez).
> `->` / `->>` yol erişimi ve GIN indeksleme bu sürümde **yok**.

---

## XML (F-23)

XML metni (`TEXT` kolonunda) üzerinde ayrıştırma, yol eşleştirme ve kurma.

```sql
CREATE TABLE x(id INTEGER PRIMARY KEY, d TEXT);
INSERT INTO x VALUES(1,'<katalog><kitap id="1" tur="roman"><ad>Sefuller</ad><yil>1856</yil></kitap></katalog>');

SELECT XMLEXTract(d, '/katalog/kitap/ad') FROM x;   -- 'Sefuller'
SELECT XMLCOUNT(d, '//kitap') FROM x;               -- 2
SELECT XMLATTR(d, '/katalog/kitap', 'tur') FROM x;   -- 'roman'
SELECT XMLEXISTS(d, '//ad') FROM x;                 -- True
```

### Fonksiyonlar

| Fonksiyon | Anlamı |
|---|---|
| `XMLELEMENT(ad, icerik [, icerik...])` | `<ad>icik</ad>` üretir; özel karakterler kaçışlanır |
| `XMLCONCAT(a, b, ...)` | parçaları birleştirir |
| `XMLESCAPE(s)` | `& < > " '` kaçışları |
| `XMLPARSE(s)` | geçerliyse aynı metin, değilse `NULL` |
| `XMLEXTract(xml, yol)` | ilk eşleşen öğenin **metni** |
| `XMLEXISTS(xml, yol)` | eşleşme var mı (`True`/`False`) |
| `XMLCOUNT(xml, yol)` | eşleşen öğe **sayısı** |
| `XMLATTR(xml, yol, 'ad')` | eşleşen öğenin nitelik değeri (yoksa `NULL`) |

### Desteklenen yol alt kümesi

| Yol | Anlam |
|---|---|
| `/katalog/kitap` | mutlak yol (ilk adım **kök düğümün kendisiyle** eşleşir) |
| `kitap/ad` | göreli yol (ilk adım kökün **çocuklarıyla** eşleşir) |
| `//kitap` | tüm torunlar arasında ara (BFS) |
| `/katalog/*` | tüm çocuklar |
| `kitap[@tur='roman']` | nitelik filtresi |
| `kitap[@id]` | nitelik **varlığı** filtresi |
| `kitap[2]` | aynı adlı kardeşler arasında **bu düğümün** 2. konumda olması |

### Ayrıştırma kuralları

- **İkinci kök → geçersiz**: `<a/><b/>` iki kök içerir, `XMLPARSE` `NULL` döner.
- **Uyuşmayan kapanış → geçersiz**: `<a></b>` geçersiz.
- **Kapanmamış etiket → geçersiz**: `<a>x` geçersiz.
- **Özgeçmeler çözülür**: `&amp; &lt; &gt; &quot; &apos; &#65; &#x41;`
- **CDATA** metin olarak alınır: `<![CDATA[x < y]]>` → `x < y`
- **Yorumlar** atlanır: `<!-- ... -->`
- **Kendi kapanan etiket**: `<a/>` geçerli
- **Derinlik sınırı**: 64

### Geçersiz XML → `NULL`, hata değil

Ayrıştırılamayan metin (ör. `bozuk metin`) hata vermez; sorgu fonksiyonları
`NULL`/`False` döner. Bu **bilinçlidir**: sorgu bir satırı yanlışlıkla dışlamak
yerine içerir; kullanıcı kendi filtresini düzeltir.

> **Kapsam:** `text()` dışı XPath fonksiyonları, eksenler (`ancestor::`,
> `following::`), union (`|`), namespace öneki **desteklenmez**.

---

## SPATIAL SORGULAR (F-24)

Mesafe, daire, kutu (`bounding box`) ve çokgen testleri. Koordinatlar `REAL`
kolonlarda ya da `TEXT` içinde `"x,y"` metni olarak saklanır.

```sql
CREATE TABLE sp(id INTEGER PRIMARY KEY, ad TEXT, x REAL, y REAL);
INSERT INTO sp VALUES(1,'A',0,0),(2,'B',3,4),(3,'C',10,10),(4,'D',1,1),(5,'E',5,5);

SELECT DISTANCE(0, 0, 3, 4);                        -- 5
SELECT COUNT(*) FROM sp WHERE DISTANCE(x, y, 0, 0) <= 5;   -- 3 (A,B,D)
SELECT ROUND(HAVERSINE(41.010, 28.960, 39.925, 32.835));  -- 349 (km)
SELECT COUNT(*) FROM sp WHERE IN_CIRCLE(x, y, 0, 0, 5);    -- 3
SELECT COUNT(*) FROM sp WHERE IN_BOX(x, y, 0, 0, 5, 5);     -- 4
SELECT COUNT(*) FROM sp WHERE IN_POLYGON(x, y, '0,0;10,0;10,10;0,10');  -- 4
SELECT AREA_POLYGON('0,0;10,0;10,10;0,10');                  -- 100
```

### Fonksiyonlar

| Fonksiyon | Anlamı |
|---|---|
| `DISTANCE(x1, y1, x2, y2)` | Öklid (düzlem) mesafesi |
| `HAVERSINE(lat1, lon1, lat2, lon2)` | Küre üzeri mesafe, **km** (R = 6371) |
| `IN_CIRCLE(x, y, cx, cy, r)` | daire içinde mi (`True`/`False`), **sınır dahil** |
| `IN_BOX(x, y, x1, y1, x2, y2)` | dikdörtgen içinde mi; köşe sırası serbest |
| `IN_POLYGON(x, y, 'x,y;x,y;…')` | çokgen içinde mi (ray casting) |
| `POINT_IN_POLYGON(x, y, '…')` | `IN_POLYGON` ile aynı (PostGIS uyumlu ad) |
| `AREA_POLYGON('x,y;…')` | çokgen alanı (Shoelace) |
| `ROUND(sayi [, ondalik])` | yuvarlama (`ondalik` 0–15) |

### Çokgen biçimi

Noktalar `;` ile ayrılır, her nokta `x,y`. **En az 3 nokta** gerekir; 3'ten
az olanı geçersiz sayılır ve `False`/`0` döner.

```sql
'0,0;10,0;10,10;0,10'   -- 10x10 kare
```

### Kurallar

- **Ondalık ayırıcı daima `.`** — sistem yerel ayarından bağımsızdır. Türkçe
  yerel ayarda çalışan bir sistemde `'5.5'` doğru ayrıştırılır.
- **Haversine yarıçapı** `R = 6371.0` km. Koordinatlar **ondalık derece**.
- `IN_CIRCLE` **sınırı içerir** (`<=`): tam yarıçap uzaklığındaki nokta eşleşir.
- `IN_BOX` köşeleri verildiği sırayla değil, otomatik `min`/`max` ile
  normalleştirilir: `IN_BOX(x,y,5,5,0,0)` ile `IN_BOX(x,y,0,0,5,5)` aynıdır.
- Bozuk koordinat veya eksik argüman **hata vermez**, `NULL`/`False`/`0` döner.
- Uzamsal sonuçlar `WHERE` içinde tip-bilgili karşılaştırılır:
  `DISTANCE(...) <= 5` metin karşılaştırması **değildir**. Aksi hâlde
  `'14.14' <= '5'` → `TRUE` olur ve uzak noktalar yanlışlıkla filtreye girer.

> **Kapsam:** coğrafi tipler (geometri sütunları, GiST/SP-GiST indeksleri,
> projeksiyon dönüşümü, küre-yüzey alanı) bu sürümde **yok**; tüm
> hesaplamalar düzlem (Euclidean) veya küre (haversine) üzerinde yapılır.

## RANGE (ARALIK) TİPİ (F-25)

PostgreSQL'in range tipleri (`int4range`, `numrange`, `daterange`) VDB'de
`TEXT` kolonunda tutulan bir "kutu" olarak modellenir. Dosya formatı, tablo
şeması ve indeks kodu değişmez; yetenek tamamen sorgu katmanındadır.

```sql
CREATE TABLE rez(id INTEGER PRIMARY KEY, ad TEXT, donem TEXT);
INSERT INTO rez VALUES(1,'Oda1','[1,5)'),(2,'Oda2','[3,8]'),(3,'Oda3','(8,12]');

SELECT ad FROM rez WHERE donem && '[4,6]';     -- Oda1, Oda2
SELECT ad FROM rez WHERE donem @> '[3,8]';     -- Oda2 (+ boş aralıklar)
SELECT CONTAINS('[1,5)', 3);                   -- True
```

### Yazım

| Yazım | Anlam |
|---|---|
| `[a,b]` | iki uç **dahil** |
| `(a,b)` | iki uç **hariç** |
| `[a,b)` / `(a,b]` | sol/sağ kapalı ya da açık |
| `[a..b]` | ayırıcı `..` olur; kanonik biçim |
| `*` | `-infinity` / `+infinity` (`[1,*)` = 1 ve üzeri) |
| `EMPTY` | boş aralık (iki köşeli parantez de kabul edilir) |

En az 3 karakter gerekir. Alt sınır > üst sınır veya iki uç açıkken eşitse
aralık **geçersizdir** → `NULL` döner.

### Operatörler

| Operatör | Anlamı | PostgreSQL karşılığı |
|---|---|---|
| `&&` | kesişim var mı | `&&` |
| `<<` | tamamen önce (değer paylaşılmaz) | `<<` |
| `>>` | tamamen sonra | `>>` |
| `&<` | kesişir **ve** sağa uzanmaz | `&<` |
| `&>` | kesişir **ve** sola uzanmaz | `&>` |
| `@>` | diğerini içerir | `@>` |
| `<@` | diğerinin içinde | `<@` |
| `-|-` | bitişik (kesişim yok, uç değer dokunuyor) | `-|-` |

### Fonksiyonlar

| Fonksiyon | Anlamı |
|---|---|
| `RANGE(alt, ust [, '[]'\|'[)'\|'(]'\|'()'])` | kanonik aralık metni üretir |
| `CONTAINS(aralik, deger)` | tek nokta aralığın içinde mi |

### Kritik kurallar

- **Boş aralık** (`EMPTY`) her şeyi **kapsar**: `EMPTY @> x` → `True`.
  Buna karşılık `&&`, `<<`, `>>`, `-|-` boş aralık için `False` döner.
- **Kesişim tek noktaysa** o değeri **her iki** aralık da içermelidir.
  `(1,5] && [5,10)` → `True` (5'i ikisi de içerir).
  `(1,5) && [5,10)` → `False` (5'i kimse içermez).
  Kaba "alt sınır kapalı mı" kuralı burada **yanlış** sonuç verir.
- **`<<` / `>>` dokunma durumu:** değer paylaşılmıyorsa "önce/sonra" sayılır.
  `[1,5) << [5,10]` → `True`; `(1,5] << [5,10)` → `False`.
- Aralık literal'ı **tırnaksız** da yazılabilir (`'[1,5)'` veya `[1,5)`).
- Aralık içeriği **sayısal**, **metin** (`'[a,m)'`) veya **ISO tarih/saat**
  olabilir; karşılaştırma önce sayısal dener, olmazsa metin.
- Bozuk aralık metni hata vermez, `NULL` döner.

> **Kapsam:** aralık birleştirme (`+`), fark (`-`), çok boyutlu aralık
> (`box`, `tstzrange`), GiST/SP-GiST indeksleri ve aralık kısıtları bu
> sürümde **yok**. `&&` indeks kullanmaz; tam tarama yapılır.

---

## NATURAL JOIN ve USING (F-27, F-28)

Ortak kolonlarda örtük eşitlik kurar; `ON` yazılmaz.

```sql
CREATE TABLE a(kid INTEGER PRIMARY KEY, ad TEXT, sehir TEXT);
CREATE TABLE b(kid INTEGER PRIMARY KEY, sehir TEXT);

SELECT * FROM a NATURAL JOIN b;              -- kid VE sehir eşit olmalı
SELECT * FROM a JOIN b USING(kid);           -- sadece kid eşitliği
SELECT * FROM a JOIN b USING(kid, sehir);    -- iki kolon birden
SELECT * FROM a NATURAL LEFT JOIN b;         -- sol taraf korunur
```

### NATURAL JOIN

Tarafların **ortak adlı tüm kolonlarında** eşitlik kurar. Ortak kolon
yoksa `ecSyntaxError` verir. Sıra önemli değildir (küme işlemi).

| Yazım | Anlam |
|---|---|
| `NATURAL JOIN t` | INNER (sol taraf varsayılandır) |
| `NATURAL LEFT\|RIGHT\|FULL JOIN t` | dış birleşim |

### USING (kolon, …)

Yalnızca **verilen** kolonlarda eşitlik kurar; `USING` kolonu her iki
tarafta da bulunmalıdır, aksi hâlde `ecColumnNotFound`. `USING` kolonu
`SELECT`/`WHERE` içinde **tek adla** kullanılabilir (çiftte yazılmaz).

### Kurallar

- **Üç-değerli mantık:** `USING`/`NATURAL` kolonundan biri `NULL` ise
  satır **eşleşmez**. `NULL = NULL` bilinmezdir.
- `NATURAL` ile `USING` aynı klamada kullanılamaz.
- `NATURAL JOIN t` sonrası da `JOIN … ON …` ile zincir kurulabilir.
- Uzamsal/JSONB operatörlerinden ayrıdır; `&&` aralık, `NATURAL` eşitliktir.

---

## RBAC — rol, izin, SET ROLE (R-18)

```sql
CREATE ROLE okuyucu;
CREATE ROLE yonetici SUPERUSER;

GRANT SELECT ON t TO okuyucu;
GRANT INSERT, UPDATE ON t TO okuyucu;   -- virgullu liste desteklenir
GRANT ALL ON * TO yonetici;             -- '*' = tum tablolar

REVOKE INSERT ON t FROM okuyucu;

SET ROLE okuyucu;    -- etkin rol
SET ROLE NONE;       -- rolden cik

DROP ROLE okuyucu;
```

### Kurallar

| Konu | Davranis |
|---|---|
| Rol belirtilmemisse | motor kullanicisi modu: **her cumleyi calistirir**. Yetki sistemi opt-in'dir. |
| `SUPERUSER` | her cumleyi calistirir, RLS politikalarini da atlar |
| Izin turleri | `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `ALL` |
| `ON tablo` / `ON *` | `*` tum tablolara gecerlidir |
| Denetim noktasi | `SELECT`/`INSERT`/`UPDATE`/`DELETE` yurutucu girislerinde; hata `yetkisiz: rol "r" tablo "t" uzerinde INSERT iznine sahip degil` |
| Kalicilik | roller + izinler sema kaydinda saklanir, dosya tasindiginda tasinir |
| `DROP ROLE` | o role verilmis tum izinler de silinir |

### API

```pascal
tb.RoleExists('okuyucu'): Boolean;
tb.RoleCan('t', Ord(pkSelect)): Boolean;   // super rol veya rol yoksa True
tb.RequirePriv('t', Ord(pkInsert));        // yetki yoksa hata firlatir
tb.CurrentRole: string;                    // '' = motor kullanicisi
tb.RoleCount / tb.GrantCount: Integer;
```

---

## ROW LEVEL SECURITY (R-19)

```sql
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t DISABLE ROW LEVEL SECURITY;

CREATE POLICY p_sel ON t FOR SELECT USING (oid <= 3);
CREATE POLICY p_ins ON t FOR INSERT WITH CHECK (oid <= 10);
CREATE POLICY p_upd ON t FOR UPDATE USING (oid <= 4) WITH CHECK (oid <= 2);
CREATE POLICY p_del ON t FOR DELETE USING (oid <= 1);
CREATE POLICY p_all ON t FOR ALL USING (owner = 'Ali');   -- FOR opsiyonel
CREATE POLICY p_def ON t USING (oid > 0);                  -- FOR ALL varsayilan

DROP POLICY p_sel ON t;
```

### Anlambilim

| Konu | Davranis |
|---|---|
| Ne zaman uygulanir | Tabloda RLS acik **ve** etkin rol bir super olmayan bir rol. Rol `NONE` ise veya super ise RLS uygulanmaz. |
| Politika **yoksa** | hicbir satir gorunmez, hicbir satir yazilamaz (deny-by-default) |
| `USING` | satirlarin gorunurlugu. Ayni komut icin birden fazla politika varsa **OR**'lanir. |
| `WITH CHECK` | yeni satirlarin yazilabilirligi. Birden fazlasa **AND**'lanir. |
| `WITH CHECK` yoksa | INSERT icin `USING`, UPDATE icin `USING` kullanilir |
| `FOR` verilmezse | `ALL` |
| `FOR <komut>` verilirse | politika **yalnizca** o komutu etkiler. `FOR SELECT` bir `UPDATE`'i kisitlamaz. |
| Politika ifadesi | normal tablo kolonlarina basvurur; metin olarak saklanir, sema kaydinda **hex**'lenir (`\|` ayiracini icerebilir) |

### Cumle bazli davranis

| Cumle | Uygulanan kosul |
|---|---|
| `SELECT` | `FOR SELECT` ve `FOR ALL` politikalarinin `USING` kosullari |
| `UPDATE` | Once `USING` (gorunmeyen satir guncellenmez), sonra `WITH CHECK` (yeni satir yazilabilir olmali) |
| `DELETE` | `USING` (gorunmeyen satir silinmez) |
| `INSERT` | `WITH CHECK` (yoksa `USING`) |

### Kalicilik

Sema kaydinda iki satir turu kullanilir:

```
#L|t|1                       -- tablo t icin RLS acik
#P|t|pp|1|286F6964203C3D2031|2D   -- politika: tablo|ad|cmd|using(hex)|check(hex)
```

`cmd`: `0`=ALL, `1`=SELECT, `2`=INSERT, `3`=UPDATE, `4`=DELETE.

### API

```pascal
tb.RlsEnabled('t'): Boolean;
tb.RlsApplies('t'): Boolean;              // RLS acik + etkin rol super degil
tb.RlsUsing('t', 1): TStrArray;           // SELECT icin USING kosullari
tb.RlsCheck('t', 3): TStrArray;           // UPDATE icin WITH CHECK kosullari
tb.PolicyCount: Integer;
```

---

## DEFERRABLE kisitlar — `SET CONSTRAINTS` (R-11)

```sql
CREATE TABLE cev(
  id   INTEGER PRIMARY KEY,
  pid  INTEGER REFERENCES ebe(id) DEFERRABLE
);

SET CONSTRAINTS ALL DEFERRED;
INSERT INTO cev VALUES(1, 99);   -- ebeveyn henuz yok -> hata VERMEZ
INSERT INTO ebe VALUES(99, 'x'); -- sonra ebeveyn
COMMIT;                         -- burada FK denetlenir

SET CONSTRAINTS ALL IMMEDIATE;  -- bekleyen denetimler ANINDA yurutulur
```

| Konu | Davranis |
|---|---|
| Kapsam | yalniz **REFERANS DOGRULAMASI (FK)** ertelenir |
| Ertelenmeyen | PK / UNIQUE / NOT NULL — indeks ve satir butunlugu icindir, ertelenmez |
| `ALL` verilmezse | kisit adi listesi beklenir (denetim `DEFERRABLE` ise gecerli, degilse uyari yerine gecersiz sayilir) |
| `COMMIT` | kanca `CommitBatch` icinde, hicbir kayit yazilmadan ONCE calisir |
| `ROLLBACK` | ertelenen kayit listesi temizlenir, hicbiri uygulanmaz |

---

## Ozyineleme + dongu korumasi (R-10)

```sql
WITH RECURSIVE zincir(id, parent, depth) AS (
  SELECT id, parent, 0 FROM node WHERE id = 1
  UNION ALL
  SELECT n.id, n.parent, z.depth + 1
  FROM node n JOIN zincir z ON n.parent = z.id
) CYCLE id SET is_cycle USING path
SELECT * FROM zincir;
```

| Konu | Davranis |
|---|---|
| `CYCLE <kolon>` | dongu tespitinde kullanilacak kolon |
| `SET <kolon>` | dongulu satir isaretlenecek **cikti** kolonu (`TRUE`/`FALSE`) |
| `USING <kolon>` | zinciri gosteren yol kolonu |
| Degerlendirme | **delta (semi-naive)** — yalnizca son adimda eklenen satirlar yeniden kullanilir |
| Dongu kesme | `is_cycle = TRUE` olan satirdan sonra genisleme uretilmez |
| Kolon tipleri | literal sayilar CTE kolon tipine `INTEGER` olarak cikarilir |
| Atlanan kolon hatasi | `CYCLE` kolonu CTE sonucunda yoksa hata verir |

---

## Semantik notlari

## NULLIF ve COALESCE (F-02, 2026-10-07)

```sql
-- NULLIF(a,b): a = b ise NULL, degilse a
SELECT NULLIF(10, 10);        -- NULL
SELECT NULLIF(10, 20);        -- 10
SELECT NULLIF(NULL, 5);       -- NULL   (NULL girdi -> NULL)
SELECT NULLIF(5, NULL);       -- 5      (NULL ile karsilasmaz)

-- COALESCE(a,b,c,...): ilk non-NULL deger
SELECT COALESCE(NULL, NULL, 7);   -- 7
SELECT COALESCE(NULL, 3, 7);      -- 3
SELECT COALESCE(1, 2, 3);         -- 1
SELECT COALESCE(NULL, NULL);      -- NULL  (hepsi NULL)

-- birlikte kullanilabilir
SELECT COALESCE(NULLIF(a, b), 0) FROM t;
SELECT NULLIF(COALESCE(a, 99), 99) FROM t;   -- NULL'a normalize
```

Kurallar:
- Her iki ifade de `EvalExpr` ile degerlendirilir (kolon, literal, fonksiyon olabilir).
- `NULLIF` **iki** arguman ister; `COALESCE` **bir veya daha fazla** arguman alir.
- Bos deger (`''`) = NULL: `COALESCE` bos string'i atlar.
- Ic ice kullanilabilir (`NULLIF(COALESCE(...), ...)`).

---

## Iliskili (Correlated) Alt Sorgu (F-03, 2026-10-07)

Ic sorgu **dis sorgunun satirina bagli** oldugunda calisir:

```sql
CREATE TABLE musteri(id INTEGER PRIMARY KEY, ad TEXT, bid INTEGER);
CREATE TABLE bolge(id INTEGER PRIMARY KEY, ad TEXT);
INSERT INTO musteri VALUES(1,'Ali',1),(2,'Veli',2),(3,'Zoe',NULL);
INSERT INTO bolge VALUES(1,'Ege'),(2,'Ic Anadolu');

-- EXISTS: her musteri icin bolgede ayni id var mi? -> hepsi icin EVET
SELECT a.ad FROM musteri a
 WHERE EXISTS (SELECT 1 FROM bolge b WHERE b.id = a.id);   -- 3 satir

-- NOT EXISTS: karsi musteri yok mu? -> hepsi icin VAR
SELECT a.ad FROM musteri a
 WHERE NOT EXISTS (SELECT 1 FROM bolge b WHERE b.id = a.id); -- 0 satir

-- IN: musterinin bolgesi listede var mi? (NULL bid elenir)
SELECT a.ad FROM musteri a
 WHERE a.bid IN (SELECT b.id FROM bolge b WHERE b.id = a.id); -- 2 satir

-- skaler alt sorgu: musterinin bolge adi
SELECT a.ad, (SELECT b.ad FROM bolge b WHERE b.id = a.id) AS bolge
  FROM musteri a ORDER BY a.id;
```

Kurallar:
- Nitelikli referans (`a.id`) **once ic kapsamda**, bulunamazsa **dis kapsamda** aranir.
- Iliskili alt sorgu **onbelleklenmez** (`IsCorrelatedSel` tespiti): sonuc dis satira baglidir.
- Uc-degerli mantik korunur: `NOT IN` alt sorgusunda NULL varsa satir elenir.
- Skaler alt sorgu birden fazla satir dondururse hata verir (`ecInvalidArgument`).
- **Derinlik siniri:** 2 seviye (dis sorgu -> ic sorgu). Ic ice 3+ seviye sinirli.

---


  `WHERE` tarafinda uc-degerli mantik: `IS NULL` disinda hicbir operator
  NULL'a eslesmez. `CHECK` tarafinda ise **bilinmez ihlal sayilmaz**:
  `CHECK (p >= 0)` olan opsiyonel bir kolona NULL yazabilirsin; yalniz
  kosulun kesin `FALSE` olmasi ihlaldir.
  *(F1-14 ile uyumlandi: `=`, `<>`, `<`, `<=`, `>`, `>=` ve `LIKE`
  bir tarafi NULL ise sonuc `UNKNOWN` (`''`) doner. Boylece
  `NOT (NULL = 1)` artik `TRUE` degil `UNKNOWN` -> satir filtreye girmez.
  WHERE'de NULL satirlari zaten eleniyordu; degisim `SELECT NULL = 1`
  gibi deger gosteren ifadelerde ve `NOT` ile zincirlenmis
  kosullarda gorunur.)*
- **Atomik batch:** `COMMIT` bir `BATCHEND` isareti + tek fsync yazar.
  Recovery isareti gormeden onceki kayitlari geri sarar.
- **Batch ici gorunurluk:** `BEGIN` ile acikken yazilan satirlar ayni
  transaction icindeki `SELECT`/`UPDATE`/`DELETE` ve kisit denetimlerinde gorunur.
- **PK arama O(1):** `WHERE pk = x` dogrudan hash anahtarindan okur.
- **ALTER TABLE** satirlari yeniden kodlar; donusturulemeyen deger hata verir
  (sessiz veri kaybi yok). `ADD COLUMN` ile eklenen kolonun `DEFAULT`'u eski
  satirlara **yazilmaz** (yeni kolon NULL kalir) — standart SQL de ayni seyi yapar.
- **Sayi/tarih cikti bicimi locale'den bagimsiz**: ondalik `nokta`,
  tarih `YYYY-MM-DD`, tarih-saat `YYYY-MM-DD HH:MM:SS`, saat `HH:MM:SS`.
- **Yazilim dosya surumu:** `VDB_FILE_VER = 2`. Eski surumlu dosyalar ilk
  acilista yerinde yukseltilir; daha yeni surumlu dosyalar temiz bir hatayla
  reddedilir (veri bozulmaz).
- **`ORDER BY` bilinmeyen kolon hatasi (F1-21).** `ORDER BY yokBoyleBirKolon`
  artik sessizce yok sayilmaz; `ecColumnNotFound` verir. Once giris sirasiyla
  donuyordu, yani sonuc kararsizdi. `ORDER BY <alias>` yazimi **taban kolon**
  adini gostermelidir (`SELECT ... AS adet ... ORDER BY adet` -> `ORDER BY adet`
  calisir, `ORDER BY 1` ve ifade-ORDER BY desteklenmez ve `kidx<0` oldugu icin
  hata verir).
- **Set-op kuyrugu (F1-11/F1-12).** `UNION`/`UNION ALL`/`EXCEPT`/`INTERSECT`
  icin `ORDER BY`, `OFFSET` ve `LIMIT` **birlestirme sonrasina** uygulanir:
  `SELECT id FROM a UNION SELECT id FROM b ORDER BY id LIMIT 2 OFFSET 1`
  -> once iki taraf birlestirilir, sonra siralanir, sonra kirpilir.
  Sutun sayilari esit degilse `ecSyntaxError` verilir (eski matris
  karsilastirilirdi). aggregate/`GROUP BY` ile set-op birlestirilemez
  (`ecUnsupported`).
- **`OFFSET` yazimlari (F1-10).** `LIMIT n OFFSET m`, `OFFSET m LIMIT n` ve
  `OFFSET m` (limit'siz) desteklenir. Negatif veya sayi disi deger
  `ecSyntaxError`/`ecLimit` verir (sessizce yutulmaz).
- **Satir sirasi garantisi yok.** `ORDER BY` kullanilmayan bir `SELECT` satir
  sirasi garantisi vermez (indeks/PK okuma sirasi olabilir). Testlerde ve
  uygulamada belirli satir bekleniyorsa `ORDER BY` yazilmalidir.
- **`UPDATE` `ON DELETE CASCADE` tetiklemez (F1-4 tamamlayici).** Satir
  yerinde guncellenir (`Delete`+`Insert` DEGIL). `ON DELETE CASCADE` yalniz
  gercek `DELETE` cumlesinde calisir; `ON UPDATE CASCADE` ise bir cocuk FK'nin
  `RefCol`u degistiginde calisir. Ilgisiz kolonun guncellenmesi hicbir cocuk
  satiri etkilemez. `UPDATE` PK kolonunu **guncelleyemez** (`ecUnsupported`).
- **`UPDATE` bilinmeyen kolon hatasi (F1-16).** `UPDATE t SET yok = 1`
  `ecColumnNotFound` verir; eskiden atlanir, satir silinip aynen yazilirdi.
- **`UPDATE ... SET` aritmetigi satira gore hesaplanir** (`SET n = n + 1`).

## F2 Notlari (2026-10-04)

Bu bolum F2 duzeltmeleriyle motorun SEMANTIGININ degistigi yerleri belgeler.
Ayrica F2 sirasinda iki yeni gercek hata bulundu ve duzeltildi: **F2-22**
(PK'siz tablo) ve **F2-23** (`CREATE UNIQUE INDEX`).

### Tablo anahtari (F2-22) - KRITIK ANLAM DEGISIMI

`PRIMARY KEY` tanimlanmamis bir tabloda **ilk kolon artik anahtar degildir**.
`CREATE TABLE t(a TEXT, b TEXT)` ile:

- `a` kolonu UNIQUE degildir. Ayni `a` degeriyle **cok satir** eklenebilir
  (eskiden `duplicate PK` hatasi veriyordu).
- `a` kolonu `DROP COLUMN` / `ALTER COLUMN ... TYPE` / `SET NOT NULL`
  kisitlarindan muaftir (eskiden "PK kolonu dusurulemez" ile reddediliyordu).
- Satirlar motor tarafindan uretilen **sentetik anahtarla** (`@1`, `@2`, ...)
  ayirt edilir. Bu anahtar semada kalicidir; yeniden acilista korunur.
  `UPDATE`/`DELETE` bu anahtarla calisir.
- PRIMARY KEY tanimlanmis tabloda davranış **degismedi**.

### UNIQUE (F2-23)

`CREATE UNIQUE INDEX` artik **gercekten zorlanir** (tek ve cok kolonlu).
Daha once `UNIQUE` kelimesi parser'da yutuluyor, motora tasinmiyordu; sonuc
komut sessizce HIC BIR SEY yapmiyordu. Kisit `INSERT` ve `UPDATE` sirasinda
denetlenir ve semada saklanir (yeniden acilista da gecerlidir).
Kolon seviyesi `col TEXT UNIQUE` zaten zorlaniyordu ve degismedi.

### Diger F2 davranislari

- **Kendine referansli FK artik kurulabilir** (`dugum(id, parent REFERENCES
  dugum(id))`). `DELETE`/`UPDATE CASCADE` zincirinde dongu `FCascadeDepth`
  ile korunur (azami 32).
- **`ALTER COLUMN` PK ve FK kaynak kolonlarinin tipini degistiremez** ve yeni
  tipte mevcut satirlar `CHECK`/`NOT NULL` kurallarina gore yeniden dogrulanir.
- **`DROP COLUMN`, kolonu iceren indeksleri de kaldirir** (cok kolonlu indeks
  dahil) ve bekleyen indeks islemlerini temizler.
- **`DROP TABLE`, cocuk tablolarda o tabloya isaret eden FK*TANIMLARINI* da
  kaldirir**; aksi halde cocuk tablo kalici olarak kullanilamaz hale geliyordu.
- **`ORDER BY` artik `SELECT` alias'ina gore calisir**
  (`... AS rn ... ORDER BY rn`) ve `SELECT` listesinde olmayan bir taban
  kolona gore de siralama yapabilir. Tanimsiz kolon `ecColumnNotFound` verir.
- **`IN (SELECT ...)`** deger kumesi alt sorgu basina bir kez kurulur.
  Iliskili (correlated) alt sorgular desteklenmez.
- **`DROP`/`RENAME` sonrasi "kasitli silindi" isareti kalici semaya
  yazildiktan sonra temizlenir.**

### DDL ve butunluk

`ALTER TABLE` veri yeniden kodlamasi ile sema yazimini **tek batch'te** yapar;
hata halinde ikisi de geri alinir. `CREATE TABLE` bos ad reddedilir.
Bozuk sema satiri `ecSchemaCorrupt` ile reddedilir (sessizce atlanmaz).
Bozuk/yarim dosya `EVDbException(ecCorrupt)` ile acilamaz.

### F3-7 notu: cok kolonlu indeks ve "leading column" kurali

`CREATE INDEX ix ON t(a, b, c)` kuruldugunde `WHERE a = 10` filtresi indeksin
**ilk kolonu** uzerinden arar (gercek RDBMS'lerin leading-column kurali).
`WHERE b = 200` (ilk kolon degil) indeks kullanmaz, tam tarama yapar.

Bu kural **dogru uygulanir**: `WHERE a = 10` yalnizca `a = 10` olan satirlari
doner; `a` ek bir filtreyle birlikte verilirse ikisi de uygulanir.
Cok kolonlu indeks, ilk kolona uygulanan `=` / `<=` / `>` / `>=` /
`BETWEEN` / `IN` filtrelerinde satirlari **dikkate almaz**; sonuc her zaman
tam dogrulanir.
