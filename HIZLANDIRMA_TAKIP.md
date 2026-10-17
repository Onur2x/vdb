# VDB Hızlandırma ve Optimizasyon Takip Tablosu

Bu doküman, VDB'nin SQLite hızına yaklaştırılması için yürütülen performans çalışmalarını, yapılan testleri ve tamamlanan adımları adım adım takip eder.

## Başlangıç Ölçümleri (17.10.2026 - speedtest.exe)
* **Range BETWEEN (500 sorgu x 200 satır):** SQLite WAL `0.009 sn` | VDB `0.737 sn` (**VDB ~84 kat yavaş**)
* **SELECT PK (10.000 nokta sorgu):** SQLite WAL `0.022 sn` | VDB `0.210 sn` (**VDB ~9.5 kat yavaş**)
* **Batch INSERT (10.000 satır tx):** SQLite WAL `0.007 sn` | VDB `0.081 sn` (**VDB ~11 kat yavaş**)
* **Tekil UPDATE (5.000 autocommit):** SQLite WAL `0.070 sn` | VDB `0.264 sn` (**VDB ~3.7 kat yavaş**)
* **Tekil INSERT (5.000 autocommit):** SQLite WAL `0.073 sn` | VDB `0.254 sn` (**VDB ~3.5 kat yavaş**)

---

## Yapılacak İşler Listesi (Görevler)

### FAZ 1: Range BETWEEN ve İndeks Filtreleme İyileştirmesi (84x Darboğaz)
- [x] **Görev 1.1:** `NarrowRows` indeks aralığı (BETWEEN / = / IN) tek koşulu tam olarak kapsadığında, sonuç satırlarını tekrar `RowMatches` ile satır satır AST evaluate yapmaktan kurtarmak (çift filtreleme bypass).
- [x] **Görev 1.2:** İndeks binary search (`IdxKeyLo`, `IdxKeyHi`, `VDbIdxCmp`) içinde `INT` indeksler için her karşılaştırmada yapılan `StrToInt64` (string parse) yükünü önlemek / tamsayı önbellekli arama.
- [x] **Görev 1.3:** Hız testi ile doğrulama ve süre karşılaştırması.

### FAZ 2: SELECT PK Nokta Sorguları için Hızlı Şerit (9.5x Darboğaz)
- [x] **Görev 2.1 (KR-6b):** Basit `SELECT <cols> FROM <table> WHERE <pk> = <val>` desenleri için AST Parser/Executor nesne tahsisini atlayan hafif `Fast-Path` SELECT mekanizması kurmak.
- [x] **Görev 2.2 (KR-6):** `TVSql` yaşam döngüsünde `FParser` ve `FExecutor` nesnelerinin her sorguda baştan `Create/Free` edilmesini engelleyip yeniden kullanıma almak.
- [x] **Görev 2.3:** Hız testi ile doğrulama ve süre karşılaştırması.

### FAZ 3: Batch INSERT ve Toplu Yazım Hızlandırması (11x Darboğaz)
- [x] **Görev 3.1:** Toplu yazım esnasında şema doğrulamasını ve tip kontrollerini her satırda tekrar tekrar yapmayıp batch düzeyinde önbelleğe almak (FBatchTableDef + FBatchColMap + EncodeRow dinamik ön-tahsis).
- [x] **Görev 3.2:** Hız testi ile doğrulama ve süre karşılaştırması.

---

### MİMARİ VE SİSTEM İYİLEŞTİRME ÖNERİLERİ (YOL HARİTASI MADDELERİ)

- [x] **Öneri KR-3 (ACİL): Git Rebase & Çakışma Temizliği**
  - Dosyalardaki çiftlenen blokların ve merge çakışma etiketlerinin (`<<<<<<< HEAD` / `=======` / `>>>>>>>`) temizlenmesi, yerel dal ile uzak GitHub deposunun (`origin/main`) eşitlenmesi. *(Tamamlandı)*

- [x] **Öneri KR-1 (KRİTİK): Tablo Taramalarında Tüm DB Yerine Hedef Tablo Dizinini Tarama**
  - `VDbTable.pas` içindeki `ScanRowsPart` tüm veritabanındaki tüm anahtarları tarayıp tablo id'sini sonradan eliyordu (R-26 yalnızca diğer tabloların KAYITLARINI okumayı önlüyordu; anahtar dolasimi hâlâ O(toplam) idi).
  - *Yapılan:* KV çekirdeğine (`VDbCore.pas`) tablo başına anahtar dizini eklendi: `FTableKeys: TDictionary<Integer, TList<QWord>>` (anahtar `-1` = etiketsiz kayıtlar/sema kaydı; R-26 gibi hiçbir filtrede elenmez). Dizin **türev önbellektir**: tek kaynağı `FIndex`'tir, asla bağımsız güncellenmez; `FIndex` her değiştiğinde (Put/Delete/CommitBatch/Kurtarma/Savepoint geri alma) yalnızca bir `Dirty` bayrağı kurulur. Filtreli bir tarama (`ScanSnapshot` ve `ScanRawIterAll`) bayrak kirliyse dizini `FIndex`'ten BİR KEZ (O(N)) yeniden kurar ve ardından **yalnızca hedef tablonun** anahtarlarını dolasir. Böylece **yazma yoluna sıfır ek maliyet** eklenir (bkz. mikro-ölçüm).

- [x] **Öneri KR-1B (HIZ): `SELECT COUNT(*)` O(1) — Doğrulanmış-Sonuç Önbelleği**
  - KR-1 ile hedef tablo anahtarları daralmıştı, ama `SELECT COUNT(*)` hâlâ o tablonun **tüm** kayıtlarını akışla (stream-agg) tarayıp sayıyordu (1M'de ~683 ms). Amaç: WHERE/JOIN/GROUP BY olmadan tekrarlı `COUNT(*)`'ı taramasız, O(1) yapmak.
  - *Yapılan (v0.012):* `VDbCore`'a doğrulanmış COUNT sonuçlarını tutan `FTableRowCount: TDictionary<Integer,Int64>` eklendi. `TVSqlExecutor.TryStreamAgg`, **tüm** seçme kolonları `COUNT(*)` olan tek-tablo sorgusunda ve **autocommit**'te önce bu cache'i dener; isabetse O(1) döner, isabetsse doğrulamalı stream-agg ile sayar ve sonucu cache'ler. Sayı **indeksten türetilmez**, doğrulamalı taramadan gelir → v0.005'te reddedilen "index-only COUNT" tuzağına düşmez. Her yazma (`AppendRec`/`Recover`/savepoint/etiket-değişimi) cache'i tamamen `Clear` eder; açık transaction'da (MVCC görünürlüğü cache'e yansımadığı için) cache kullanılmaz.
  - *Bilinçli ödün (kullanıcı onaylı):* dışarıdan bozulmuş/hash-çarpışmalı (desteklenmeyen) DB'de isabet, "bozukta bağır" yerine önbelleği döndürebilir; sağlam DB'de her yazmada sıfırlandığı için birebir doğrudur.
  - *Sonuç:* ilk COUNT ~757 ms (aynı doğrulama), sonraki COUNT **~0,01 ms**. `sqltest` 2251/2251, `crashtest` 8/8 yeşil. *(Tamamlandı)*

- [x] **Öneri KR-2 (KRİTİK): Geometrik Bellek Büyümesi (O(N²) SetLength Diyetine Son)**
  - FPC dinamik dizilerinde `SetLength(arr, n+1)` her seferinde tüm diziyi baştan kopyaladığı için `O(N²)` maliyet üretir.
  - *Yapılan:* `ScanSnapshot`, `ScanRowsPart`, `ScanViewRows`, `NarrowRows` ve `ExecGroupBy` içerisinde ön-tahsis ve toplu budama uygulandı. 2251/2251 test tam başarıyla geçti. *(Tamamlandı)*

- [x] **Öneri KR-4 (ORTA): Büyük Taramalarda Sıralı I/O ve Sayfa Önbelleği**
  - `ScanSnapshot` içinde P-13 doğrultusunda 2 MB'lik bucket tabanlı `counting sort` ve `VDB_SCAN_CHUNK_CAP` ile ardışık sıralı tampon okuması zaten aktif çalışmaktadır. *(Doğrulandı & Tamamlandı)*

- [x] **Öneri KR-5 (ORTA): FlushIdxPending İndeks Sıralamasında Delta Merge (2-Way Merge)**
  - İndekse 100 satır eklendiğinde bile tüm 1M satırlık indeks baştan QuickSort ile sıralanıyordu.
  - *Yapılan:* Bekleyen delta listesi tek başına sıralanıp, mevcut sıralı indeksle `O(N + delta)` iki yönlü birleştirme (2-way merge) ile birleştirildi. *(Tamamlandı)*

- [x] **Öneri KR-7 (İLERİ): Çoklu Okuma Paralelliği (RW Lock)**
  - Sunucu havuzunda ve çok iş parçacıklı okumalarda tek kilit (`TCriticalSection`) tüm okuyucuları tek sıraya sokuyordu.
  - *Yapılan:* `TVTableDb.FLock` nesnesi `TMultiReadExclusiveWriteSynchronizer` (MREW) mekanizmasına geçirildi; `BeginRead/EndRead` ve `BeginWrite/EndWrite` eklendi. `TVdbSqlServer` üzerindeki global `FLock` ve tek `Fsq` nesnesi kaldırılarak `TVdbServerConn` başına bağımsız `FSql: TVSql` tahsis edildi. Böylece paralel SELECT sorguları birbirini engellemeden eşzamanlı çalışabilmektedir. 2251/2251 test tam başarıyla geçti. *(Tamamlandı)*

- [x] **Öneri KR-8 (HIZ): Agrega Taramasında Allocation-Free pk-Hash (decode-on-demand)**
  - v0.012 KR-1B sonrası profil: `SELECT SUM` hâlâ ~720–800 ms. Değer zaten 8B binary'den `Move` ile okunuyordu (string yoktu); kalan maliyet, satır-döngüsü geri-cagrisinin **çarpışma denetimi için pk metnini kurması** idi: `VDbPeekRawRowP` satır başına `SetString` + `UTF8Decode` (2 tahsis), üstüne `VDbHashKey` bir string birleştirme + `UTF8Encode` daha ekliyordu.
  - *Yapılan (v0.013):* `VDbHashKey`'in FNV girdisi `UTF8(Norm(Table)+#0+Pk)`; `#0` ayırıcısı öneki Pk'dan ayırdığı için önek tohumu (`VDbHashKeyPrefix`) sorgu başına BİR KEZ hesaplanır, her satırda ham UTF-8 pk baytları tohuma katlanır (`VDbHashKeyBytes`). Yeni `VDbPeekRawRowKeyHash` pk stringi hiç kurmaz; `VdbAggRawCb` bunu kullanır. Sonuç `VDbHashKey` ile **bayt-bayt aynı** (`hashchk`: 80/80) → "bozukta bağır" sözleşmesi aynen korunur (KR-1B'nin cache-isabet ödününden farklı; hiçbir denetim atlanmaz). pk metni gereken yerde (`PkBuildPeekCb`) eski `VDbPeekRawRowP` durur.
  - *Sonuç:* `SUM(id)` 805→280 ms (~%65); aynı cb'yi paylaşan `COUNT(*)` doğrulama taraması 757→317 ms. `sqltest` 2251/2251, `crashtest` 8/8. *(Tamamlandı)*

---

## Tamamlanan Aşama ve Güncel Süre Kayıtları
### Adım 1.1 Sonrası Ölçümler (17.10.2026):
* **Range BETWEEN (500 x 200 satir):**
  * Önceki VDB süresi: `0.737 sn` (679/sn)
  * Yeni VDB süresi: `0.339 sn` (1.474/sn) -> **%117 HIZLANMA (2.17 kat daha hızlı!)**
* **SELECT PK (10.000 nokta):**
  * Önceki VDB süresi: `0.210 sn`
  * Yeni VDB süresi: `0.185 sn` -> **%13.5 HIZLANMA**

### Adım 2.1 Sonrası Ölçümler (17.10.2026 - FastPointSelect):
* **SELECT PK (10.000 nokta sorgu):**
  * Başlangıç VDB süresi: `0.210 sn` (47.728/sn)
  * Yeni VDB süresi: **`0.055 sn` (182.643/sn)** -> **%281 HIZLANMA (3.8 KAT DAHA HIZLI!)** 🚀
  * *SQLite WAL hızı:* `0.023 sn` (Fark 9.5 kattan 2.3 kata indi!)
* **Single INSERT 5000 (autocommit):**
  * Başlangıç VDB süresi: `0.254 sn` (19.674/sn)
  * Yeni VDB süresi: **`0.169 sn` (29.659/sn)** -> **%50 HIZLANMA!** 🚀

### Adım 3.1 Sonrası Ölçümler (17.10.2026 - Batch INSERT & EncodeRow Önbellek):
* **Batch INSERT 10.000 (tx):**
  * Başlangıç VDB süresi: `0.081 sn` (123.456/sn)
  * Yeni VDB süresi: **`0.069 sn` (145.256/sn)** -> **%17 HIZLANMA!** 🚀
* **Multi-row VALUES 10.000 (100/stmt):**
  * Önceki VDB süresi: `0.125 sn` (80.005/sn)
  * Yeni VDB süresi: **`0.110 sn` (90.971/sn)** -> **%14 HIZLANMA!** 🚀
* **Veri Bütünlüğü Doğrulaması:** `checksum=70000000` (Eksiksiz doğrulandı)

### Adım KR-5 Sonrası Ölçümler (17.10.2026 - 2-Way Delta Merge):
* **DELETE 5000 tek tek (İndeks silme ve yeniden süzme yolu):**
  * Önceki VDB süresi: `0.232 sn`
  * Yeni VDB süresi: **`0.217 sn`** -> **%7 HIZLANMA**
* **Veri Bütünlüğü Doğrulaması:** `checksum=70000000` (Eksiksiz doğrulandı)

### Adım KR-7 Sonrası Ölçümler (17.10.2026 - RW Lock & TVSql Per-Connection):
* **SELECT PK 10.000 (nokta):** `0.061 sn` (165.067/sn)
* **Single INSERT 5000 (autocommit):** `0.178 sn` (28.019/sn)
* **UPDATE 5000 tek tek:** `0.286 sn`
* **DELETE 5000 tek tek:** `0.234 sn`
* **Batch INSERT 10.000 (tx):** `0.086 sn`
* **Multi-row VALUES 10.000 (100/stmt):** `0.109 sn`
* **Sunucu Durumu:** TCP SQL Sunucusu çoklu bağlantı thread'leri bağımsız `FSql` örneğiyle çalışır hale getirildi, `FLock` darboğazı kaldırıldı, MREW kilit koruması sağlandı.
* **Tüm Testler:** 2251/2251 test tam başarıyla geçti (0 hata).
* **Veri Bütünlüğü Doğrulaması:** `checksum=70000000` (Eksiksiz doğrulandı)

### Adım KR-1 Sonrası Ölçümler (17.10.2026 - Tablo Başına Anahtar Dizini):
* **Mikro-test (karışık DB):** 20 tablo x 20.000 satır = 400.000 satır; hedef `t0` üzerinde tekrarlı `SELECT SUM(val)` taraması.
  * KR-1 ÖNCESİ: `21,4 / 21,6 ms` per tarama (iki koşu)
  * KR-1 SONRASI: `14,2 / 14,8 ms` per tarama (iki koşu)
  * **~1,48x hızlanma (yaklaşık %32 azalma).** Tablo sayısı arttıkça kazanç büyür (dolasilan anahtar sayısı O(toplam) -> O(tablo)).
  * **Doğruluk:** her iki sürümde de aynı sonuç (`chk=16000800000`, satır=20.000). Fark yok.
* **Tek tablolu kıyas (speedtest.exe):** KR-1 öncesi/sonrası ile aynı mertebede (ör. Range BETWEEN 0,355 sn / SELECT PK 0,057 sn); **tek tablolu iş yükünde regresyon yok.**
* **Regresyon kapısı:** `sqltest` 2251/2251 geçti; `crashtest` 8/8 `SONUC: GECTI` (veri kaybı/bozulma yok).

### Adım KR-1B Sonrası Ölçümler (17.10.2026 - `SELECT COUNT(*)` O(1) önbelleği):
* **Ayrıştırmalı profil (1M satır, tek süreç, aynı DB, `bench_profile.exe`):**
  * İlk `COUNT(*)` (cache boş): **757 ms** — doğrulamalı stream-agg; cache'i doldurur (tarama maliyeti KR-1B öncesiyle aynı).
  * Sonraki `COUNT(*)` (arada yazma yok): **0,01 ms** — O(1) cache isabeti.
  * `COUNT(*) x10` toplam: **758 ms** (757 doğrulama + 9 × ~0). v0.011 tabanı (önbelleksiz) x10 ≈ 698–713 ms; kazanç **tekrar başına** tam taramanın kalkması.
  * `SUM(id)`: 805 ms — cache kullanmaz, değişmedi (beklenen).
  * Sayı doğrulaması: cache isabetinde dahi `deger=1000000` (birebir).
* **Tasarım notu:** sayı `FIndex`'ten türetilmez, doğrulamalı taramanın çıktısı önbelleğe alınır. Böylece reopen sonrası `FRowTagFunc` atanmadan önce FIndex etiketlerinin -1 kalması (`VDbCore.pas:1238`) sayımı yanlışlamaz — ilk COUNT dosyayı doğrulamalı tarayıp doğru sayıyı üretir.
* **Regresyon kapısı:** `sqltest` **2251/2251** (0 hata; yeniden-başlatma sonrası `COUNT=3` dahil); `crashtest` **8/8** `SONUC: GECTI`.

### Adım KR-8 Sonrası Ölçümler (17.10.2026 - allocation-free pk-hash, decode-on-demand):
* **Bağlam:** KR-1B sonrası profil, agregalarda darboğazın değer değil, çarpışma denetimi için kurulan **pk string'i** olduğunu gösterdi (`VDbPeekRawRowP`: satır başına `SetString`+`UTF8Decode`, üstüne `VDbHashKey`'in string birleştirme + `UTF8Encode`'u).
* **Eşdeğerlik kanıtı (`hashchk`):** `VDbHashKeyBytes(VDbHashKeyPrefix(T), pkUtf8, n)` == `VDbHashKey(T, Pk)` — 8 tablo × 10 pk (boş, gömülü `#0`, Unicode, boşluklu, karışık büyük/küçük) = **80/80 birebir**. Semantik gevşetme YOK (hash değeri aynı).
* **Hız (1M satır, aynı DB, tek süreç, soğuk, `bench_profile.exe`):**
  * `SUM(id)`: **805 ms → 280 ms** (~2,9×, −%65).
  * İlk `COUNT(*)` (doğrulamalı tarama; aynı cb'yi paylaşır): **757 ms → 317 ms** (−%58).
  * Sonraki `COUNT(*)` (KR-1B cache isabeti): 0,01 ms (değişmedi, O(1)).
  * RAW I/O (77 MB): 11 ms (taban). Kalan ~269 ms = satır-başı kolon-dizini yürüyüşü + `Move` + ScanRawIter chunk makinesi (tahsis artık yok).
* **Regresyon kapısı:** `sqltest` **2251/2251** (0 hata; SUM/AVG/MIN/MAX + çarpışma/genel-yol dahil); `crashtest` **8/8** `SONUC: GECTI`.



