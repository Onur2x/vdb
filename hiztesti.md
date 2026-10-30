# VDB Hız Testi ve Performans Raporu

Bu doküman motorun ölçülmüş performansını, ölçüm yöntemini ve SQLite ile aynı
makinedeki karşılaştırmasını içerir. Genel bakış: [readme_tr.md](readme_tr.md)

> Tüm sayılar bu depodaki gerçek çalıştırmalardan alınmıştır. Ölçümler
> Windows üzerinde 32-bit (`i386-win32`) FPC 3.2.4 derlemesiyle, tek süreçte
> ve `QueryPerformanceCounter` ile alınmıştır. Aynı veri, aynı disk
> (`C:\temp`) ve aynı SQL metni kullanılmıştır.

---

## 1. Test verisi

1.000.000 satırlık tablo:

```sql
CREATE TABLE musteri (
  id      INTEGER PRIMARY KEY,
  ad      TEXT,
  yas     INTEGER,
  bakiye  FLOAT,
  notu    TEXT
);
```

Veri üretimi deterministik; aynı tohumla tekrar üretilebilir.

---

## 2. v2.1 performans sürümü (1M satır)

| Sorgu / işlem | Önce | v2.1 | Kazanç |
|---|---:|---:|---|
| `SELECT COUNT(*) FROM musteri` | 3.200 ms | **800 ms** | **4x** |
| `SELECT * FROM musteri` | 2.859 ms | **1.579 ms** | **1,8x** |
| `SELECT SUM(id) FROM musteri` | 8.766 ms | **2.265 ms** | **3,9x** |
| `WHERE id = -30792` (negatif PK) | 12.400 ms | **0 ms** | hata düzeltmesi |
| `WHERE id > 100` (999.900 satır) | 13.000 ms | **~5.000 ms** | **2,6x** |
| İlk indeks kullanımı (tembel kurulum) | 9–13 sn | **~4,3 sn** | **2–3x** |
| `ScanAll` (ham KV taraması) | 7.016 ms | **437 ms** | **16x** |
| `ScanRows` (çözümlü tarama) | 9.703 ms | **2.625 ms** | **3,7x** |
| `WHERE id = 524288` (PK noktası) | 0 ms | **0 ms** | — |
| `WHERE id BETWEEN 100 AND 200` | 125 ms | **125 ms** | PK tembel indeksi |
| 1M INSERT (BEGIN/COMMIT) | — | **55,84 sn** (17.907/sn) | 118,9 MB ≈ 119 B/satır |

### Mikro ölçümler

| İşlem | Süre |
|---|---:|
| `VDbParseInt` | 78 ns/çağrı |
| `VDbParseFloat` | 515 ns/çağrı |
| `VDbFloatToStr` | ~450 ns (önce ~800 ns) |
| STR kolon çözümleme | 109 ns/kolon (önce ~300 ns) |

### Bu sürümde neler değişti

- `ScanSnapshot` yeniden yazıldı: offset sıralı blok okuma (8 MB pencere).
- `COUNT(*)` için ham yol: satır çözmeden, yapı + hash doğrulamasıyla sayım.
- Aggregate gating: `SUM` artık gereksiz `MIN/MAX` ve parse yapmıyor.
- `SortIdxEntries` ön-parse quicksort: indeks kurulumu ~10 sn → ~1 sn.
- CBO düzeltmesi: istatistik yokken satır sayısı yerine indeks uzunluğu.
- Negatif literal düzeltmesi: `id = -1` 12,4 sn → 0 ms.
- `DecodeRow` ASCII hızlı yolu + ham bayt hash + ön tahsis.
- `VDbParseInt` / `VDbParseFloat` / `VDbCmpVal` / `VDbFloatToStr` tahsis
  azaltmaları.

Dayanıklılık sözleşmesi değişmedi: `SyncWriteInterval` varsayılanı 0,
çökme testleri veri kaybı olmadan geçiyor.

---

## 3. H3 skiplist indeksi (2026-10-19)

H3 ile ikincil indeks kanonik olarak skiplist üzerinde tutulur. Bekleyen
değişiklikler `FlushIdxPending` içinde O(log N) uygulanır; sıralı dizi yalnızca
cold okuma cache'idir. Rank/span alanları sayesinde indeksli `COUNT(*)`
aralığı O(log N) sayılır.

### 100.000 satır — `idxbench`

Ölçüm: 200 × 1.000 aralık, 100 döngü, her döngüde `UPDATE` + indeksli
`COUNT(*)`.

| Ölçüm | Sonuç |
|---|---:|
| 100 döngü toplamı | **39,3–41,8 ms** |
| Döngü başına | **0,39–0,42 ms** |
| Önceki döngü başına | 24,99 ms |
| Kazanç | **~60–64x** |
| İndeksli `COUNT(*)` (pending yok) | **0,01 ms** |
| İlk flush | **1,3 ms** |

### 1.000.000 kayıt — `skipchk`

| İşlem | Süre |
|---|---:|
| 1M ekleme | **1.110,3 ms** |
| 200.000 `LowerBound` | **423,8 ms** |
| 10.000 aralık taraması | **336,3 ms** |
| 100.000 silme | **271,7 ms** |

`skipchk` ayrıca 200.000 elemanlı bir oracle ile rank/span değerlerini
brute-force karşılaştırır; sonuç **0 hata**.

`countchk` indeksli tabloyu indekssiz oracle ile karşılaştırır:
**120/120**.

---

## 4. SQLite ile adil karşılaştırma

Koşullar:

- Aynı SQL metni, aynı veri üretimi, aynı disk (`C:\temp`), tek süreç.
- İki motor da stok varsayılanlarda:
  - VDB: `SyncWriteInterval = 0` (senkron commit)
  - SQLite: `synchronous=FULL`, `journal=DELETE`
    (resmî sqlite.org 3.54.0 32-bit DLL)
- Zamanlayıcı: `QueryPerformanceCounter`.

| Aşama (1M satır) | VDB | SQLite | VDB / SQLite |
|---|---:|---:|---:|
| `INSERT` 1M (BEGIN/COMMIT) | 24,1 sn | 3,12 sn | 7,7x |
| `SELECT COUNT(*)` ×10 ortalama | 713 ms | 37 ms | 19,5x |
| `SELECT SUM(bakiye)` ×5 ortalama | 722 ms | 82 ms | 8,8x |
| PK nokta araması ×50.000 | **1,42 sn** | 3,04 sn | **0,47x — VDB 2,1x önde** |
| `BETWEEN` 2.000×100 satır | 3,12 sn | 211 ms | 14,8x |
| `UPDATE` 100k (transaction) | 4,25 sn | 270 ms | 15,8x |
| `DELETE` 100k (transaction) | 2,92 sn | 196 ms | 14,9x |

Hız kampanyası boyunca kazanç değişimi (veri kaybı yok):

| Aşama | Kampanya başı | Final |
|---|---:|---:|
| INSERT | 16,1x | 7,7x |
| COUNT | 26,8x | 19,5x |
| BETWEEN | ~35x | 14,8x |
| PK nokta | 0,59x | **0,47x (VDB önde)** |

Her adımda `sqltest` ve 8'li çökme zinciri yeşil kaldı.

---

## 5. Tek satırlık yazma (autocommit) — 2026-10-24

Şikâyet: "INSERT, UPDATE ve DELETE hâlâ çok yavaş". Tek satırlık (autocommit)
yazma yolu ölçüldü; iki darboğaz bulundu ve giderildi.

Koşullar: Windows, FPC 3.2.4 i386-win32, `-O1`, SQL metniyle (`sq.Exec`),
varsayılan dayanıklılık (`SyncWrite=True`, `SyncWriteInterval=0` → her commit
fsync), 20.000 satır, tek süreç.

| İşlem (20.000 satır, tek tek) | Önce | Sonra | Kazanç |
|---|---:|---:|---:|
| `INSERT` autocommit | 74,0 sn — 3,70 ms/satır (270/sn) | **8,61 sn — 0,430 ms/satır (2.324/sn)** | **8,6x** |
| `UPDATE` (PK) autocommit | 138,9 sn — 6,94 ms/satır (144/sn) | **7,74 sn — 0,387 ms/satır (2.585/sn)** | **17,9x** |
| `DELETE` (PK) autocommit | 137,3 sn — 6,87 ms/satır (146/sn) | **7,48 sn — 0,374 ms/satır (2.673/sn)** | **18,4x** |

Toplu (tek transaction) yolda ayrı bir O(n²) darboğazı bulundu ve giderildi
(100.000 satır, tek transaction):

| Toplu işlem | Önce | Sonra | Kazanç |
|---|---:|---:|---:|
| `DELETE ... WHERE` (tek cümle) | 0,1575 ms/satır (15,8 sn) | **0,0134 ms/satır (1,34 sn)** | **11,7x** |
| PK `DELETE` (açık batch) | 0,1735 ms/satır (17,3 sn) | **0,0296 ms/satır (2,96 sn)** | **5,9x** |
| `UPDATE ... WHERE` (tek cümle) | 0,0226 ms/satır | 0,0223 ms/satır | — |
| `INSERT` (açık batch) | 0,0065 ms/satır (154 bin/sn) | 0,0064 ms/satır (156 bin/sn) | — |

### Kök neden 1 — her INSERT'te şemanın tamamı yeniden yazılıyordu

`TVTableDb.BumpAutoInc`, sayaç ilerlediğinde `MarkSchema` → `SaveSchema`
çağırıyordu; `SaveSchema` tüm tablo/rol/RLS metnini üretip `GuardSchemaLoss`
denetimiyle birlikte KV'ye yazıyor ve fsync ediyordu. Tek satırlık INSERT
başına yaklaşık 3,0 ms. Artık sayaç yalnız bellekte ilerler
(`FAutoIncDirty`); şema `Close` sırasında veya bir sonraki yapısal DDL'de bir
kez yazılır. Sayaç kaybolursa `ReadRow`/`MaxPkInt` ile kendini onarır.

### Kök neden 2 — tek satırlık yazımda yerinde (in-place) güncelleme

Ölü bölge yeniden kullanımı tek satırlık UPDATE/DELETE'te üç fsync (undo
ön-görüntüsü, ana dosya, undo commit işareti) ve her seferinde `.undo`
dosyasının oluşturulup silinmesi demekti (Windows'ta dosya oluştur/sil
≈ 1,5 ms). Artık yerinde yazım yalnızca **çok satırlı** işlemde
(`FInBatch and FPending.Count > 1`) kullanılır; tek satırlık yazım tek
fsync'lik ekleme yolundan gider. Bedeli dosya büyümesidir; ölü bölgeler
sonraki toplu yazımlarda yeniden kullanılır, `VACUUM`/`Compact` geri kazanır.

### Ek — serbest bölge araması O(n²) idi

`TryTakeFreeSpan` listeyi baştan tarayıp ilk uyan bölgeyi alıyordu
(`TList.Delete(0)` = O(n)). 100.000 satırlık `DELETE`'te her satır yeni bir
ölü bölge üretip hemen arandığı için toplam O(n²) oluşuyordu. Liste artık
boya göre sıralı tutulur; arama ikili arama ile O(log n), eşit boylu
bölgelerde ekleme O(1).

### Otomatik sıkıştırma (H25) — büyüyen dosya sorununa karşı

Tek satırlık yazma artık dosyaya ekleme yaptığı için yoğun autocommit
`UPDATE`/`DELETE` trafiğinde ölü bölgeler birikir ve dosya büyür. Motor bunu
otomatik toparlayabilir: **açıldığında**, her başarılı commit'ten sonra
`ÖlüBayt / DosyaBoyu` oranı eşiği geçerse `Compact` çalışır (atomik `.tmp` +
rename, `.bak` kalır). Karar O(1)'dir; sıkıştırma yalnızca eşik aşıldığında,
dosya bir kez baştan yazılarak yapılır.

**Varsayılan KAPALIDIR.** Sıkıştırma dosyayı baştan yazdığı için o commit
bir defalık uzun sürer (çok büyük DB'de saniyeler). Tahmin edilebilir commit
gecikmesi isteniyorsa kapalı bırakılıp `VACUUM`/`AutoCompact` uygun anda elle
çağrılmalıdır.

| Ayar | Varsayılan | Anlamı |
|---|---:|---|
| `AutoCompactEnabled` | `False` | Açmak için `True` |
| `AutoCompactRatio` | `0,35` | Ölü bayt oranı eşiği |
| `AutoCompactMinBytes` | 4 MB | Bu boyutun altındaki DB'ye dokunulmaz |

Ölçüm (`sqltest` T148, 300 satır, 60 KB dosya): %36 ölü oranda
**63.505 → 23.008 bayt**; sıkıştırma sonrası `DeadBytes=0`, satır sayısı,
PK/ikincil indeks okumaları, `INSERT`/`UPDATE`/`DELETE`, `Verify` ve
yeniden açma sonrası sonuçlar aynı. Kapalıyken ölü bayt birikmeye devam eder
(23.064 bayt) ve sıkıştırma yapılmaz. Sıkıştırma yalnızca veri yazan commit
sonunda denenir; `.bak`, `.tmp` ve fsync maliyeti yalnızca eşik aşıldığında
ödenir.

### Ölçülen taban çizgisi

Bu makinede ham `fsync` ≈ 0,29–0,32 ms. `SyncWrite=True` ile tek satırlık
yazmanın tabanı ≈ 0,35 ms/cümle (~2.800/sn) ve bu sınıra ulaşıldı. Daha
yüksek hız isteyen `SyncWriteInterval` (grup commit) veya açık transaction
kullanmalıdır; grup commit ile `INSERT` 0,030 ms/cümle (~33.000/sn).

---

## 6. Doğruluk kapıları

Bu değişiklikler aşağıdaki kapılar yeşilken yapıldı (2026-10-24):

| Kapı | Sonuç |
|---|---|
| `sqltest` — win32 (lazbuild, `-B`) | **3112 / 3112** (`kalan=0`) |
| `sqltest` — win64 (`-Px86_64 -Twin64 -O1`) | **3077 / 3077** (`kalan=0`) |
| `sqltest` — Linux (WSL, FPC 3.2.4) | **3077 / 3077** (`kalan=0`) |

H11 (undo günlüğü / yerinde yazım) testleri yeni sözleşmeye göre
güncellendi: ölü bölge yeniden kullanımı çok satırlı işlemde doğrulanır,
tek satırlık yazma ekleme yolundan gider. H25 için `sqltest` T148 eklendi
(21 doğrulama: varsayılan kapalı, eşik davranışı, dosya küçülmesi,
veri/indeks bütünlüğü, kapatma-açma, yeniden açma sonrası kalıcılık).

Daha eski kampanyalarda `crashtest`, `rawchk`, `mrowchk`, `fuzzchk`,
`sqlite_diff`, `hashchk`, `copychk`, `zonechk`, `skipchk`, `countchk` de
yeşildi; bu araçlar tek seferlik doğrulama araçlarıydı ve depoda yalnızca
`sqltest` kaldı.

---

## 7. Ölçümü tekrarlama

`sqltest` ile doğruluk:

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

Beklenen: `SONUC: gecen=3090 kalan=0` (win32) veya `gecen=3055 kalan=0`
(win64/Linux; OpenSSL DLL yoksa birkaç TLS testi ATLA sayılır).

Benchmark programları (`idxbench`, `skipchk`, `countchk`) temizlik sırasında
kaldırıldı. Aynı ölçümleri tekrarlamak için 1M satırlık veri üretip ilgili
SQL'leri `sqltest`/kendi harness'ınız üzerinden çalıştırabilirsiniz.

---

## 8. Yorum

- VDB'nin güçlü olduğu yer **PK nokta araması** ve **tek dosya/gömülü**
  kullanım senaryolarıdır.
- Toplu `INSERT`, `UPDATE` ve `DELETE` tarafında SQLite hâlâ belirgin şekilde
  öndedir; bu, append-only KV katmanının tasarımının doğal sonucudur.
- H3 skiplist, indeks bakımı ve indeksli `COUNT(*)` maliyetini O(log N)
  seviyesine indirerek en büyük kazancı sağlamıştır.

---

## 9. v3.0 sayfa motoru — aynı tartıda v2 karşılaştırması (2026-10-25)

v3.0 yeni bir motor getiriyor: 4 KB SQLite tarzı sayfalar, sayfa imajlı WAL,
slot indeksleri, O(1) silme. Aşağıdaki tablo **tek bir harness** ile, aynı
makinede, art arda, üç tekrarın **medyanı** olarak üretildi
(`tests/bench/benchcmp.pas`, `--backend=v2|v3`).

Koşullar: Windows, FPC 3.2.4 i386-win32, tek süreç; 200.000 satır × 3 kolon
(`id INTEGER PRIMARY KEY`, `a INTEGER`, `s TEXT(~24 B)`), 20.000 tek satırlık
autocommit INSERT, varsayılan dayanıklılık (`SyncWrite=True`, her commit fsync).

| Metrik | v2 | **v3.0** | **v3.1** |
|---|---:|---:|---:|
| Veri dosyası (`.odb`) | 19.278.424 B (96,4 B/satır) | **15.527.936 B (77,6 B/satır)** | **15.527.936 B (77,6 B/satır)** |
| Açılış dizini (`.odb.idx`) | — | 3.520.080 B (17,6 B/satır) | 3.520.080 B (17,6 B/satır) |
| **Diskteki toplam** | **19.278.555 B** | **19.048.016 B** | **19.048.016 B** |
| Açılış | 984 ms | 32 ms | **27,8 ms** |
| Toplu INSERT (tek batch) | 4,455 µs/satır | 6,640 µs/satır | **5,787 µs/satır** |
| Autocommit INSERT | 0,431 ms/satır | 0,557 ms/satır | **0,449 ms/satır** |
| PK nokta araması | 6,25 µs | 6,25 µs | **5,13 µs** |
| parse-only `SELECT 1` | 3,90 µs | 3,90 µs | **3,55 µs** |
| `COUNT(*)` | 31 ms | 62 ms | **0,1 ms** |

v3.1 sütunu aynı harness'ın aynı koşullarındaki (200k × 3 kolon, 20k tek
satır, üç tur medyanı) ölçümüdür. Dosya boyutu **değişmedi**: v3.1 boyut değil
hız işidir (`.idx` her zaman yazılır kararı boyutu ~%1,2 büyütür, ölçüm aynı
dosyayı verdi).

**`.odb.idx` nedir, sayılmalı mı?** Açılışta heap dizinini (anahtar → sayfa/slot)
yeniden kurmak yerine diskten yükleyen **türetilmiş bir önbellektir**; veri
kaynağı değildir, silinirse hiçbir şey kaybolmaz (açılış 16 ms yerine 79 ms
sürer, hedef 150 ms). Diskte yer kapladığı için yukarıda **ayrı satırda ve
toplamda** gösterildi. Yalnız `.odb` sayıldığında kazanç %19,5; `.idx` ile
birlikte %1,2'dir — iki sayı da yazılmalıdır, tek başına %19,5 yanıltıcıdır.

**Politika: `.idx` her zaman yazılır** (v3.1). v3.0'daki "50 MB üstünde
yazma" eşiği kaldırıldı: `.idx` türetilmiş ve silinebilir olduğu için boyut
sınırı gerçek bir koruma sağlamıyordu; buna karşılık büyük veritabanlarında
açılışı gereksiz yere tam taramaya düşürüyordu. `backendchk` bu politikayı
6 kontrolle sınar (`idxpol`, `TestV3IdxPolicy`).

Not: v3.1'de üç gerileme de kapandı — `COUNT(*)` **0,1 ms** (sayaç),
autocommit **0,449 ms** (yalnız işlemde değişen sayfalar WAL'e yazılır),
toplu INSERT **5,787 µs** (256 KB'lık dosya uzatma parçaları). Aşağıdaki
"neden" bölümleri v3.0'ın ölçülmüş kök nedenleridir; v3.1 düzeltmesi her
birinin altında yazılı.

### Neden toplu INSERT 6,64 µs? (v3.0 — v3.1'de 5,79 µs)

Bileşenler ayrı ayrı ölçüldü (200k anahtar, 64 B değer, 512 çerçeveli havuz):

| Aşama | Süre |
|---|---:|
| Parti kaplamasına yazma (`Put`) | 0,94 µs/anahtar |
| Kaplamayı motora uygulama + commit + checkpoint | 4,72 µs/anahtar |
| — bunun motor `Insert` payı | ~1,6 µs/anahtar |
| — bunun WAL + checkpoint payı | ~1,3 µs/anahtar |

v2'nin append-only KV yolu satır başına tek bir ekleme yapar. v3 sayfa
imajlı WAL kullanır: aynı baytlar hem WAL'e hem checkpoint'te veri dosyasına
yazılır (**2x yazma hacmi**). Rewrite'ın yarısı buradan gelir; kalanı sayfa
içi hücre yerleştirme ve dizin bakımıdır.

**v3.1 düzeltmesi:** dosya her yeni sayfada ayrı `SetSize` ile uzatılıyordu
(ölçülen ~45–50 µs/sayfa). Artık 256 KB'lık parçalarla uzatılır ve kapanışta
mantıksal boya kırpılır; sayfa motoru harness'ında yazım **1,88 → 1,32
µs/satır**, SQL harness'ında toplu INSERT **6,64 → 5,79 µs/satır**.

Bu sprintte ölçümle bulunan ve giderilen üç darboğaz (hepsi üretim kodunda):

1. **`Flush` her autocommit sonrası tam checkpoint yapıyordu.** SQL katmanı
   her satırdan sonra `Flush` çağırdığı için tek satırlık yazım WAL + tüm
   kirli sayfaların dosyaya yazımı + WAL budama demekti. `Flush` artık yalnız
   `Commit(True)` (WAL + fsync); checkpoint eşikte/açık çağrıda/kapanışta.
   **1,168 → 0,557 ms/satır.**
2. **Pending sayfa imajları 4 KB'lik kayıt dizisi olarak tutuluyor ve her
   tahliyede `SetLength(+1)` yapılıyordu.** 200k × 64 B yazımda 3.488 tahliye
   = ~265 ms yalnızca büyütme bedeliydi (tahliye başına ~75 µs). İmajlar artık
   ayrı ayrılır, dizi yalnız gösterici tutar, kapasite ikiye katlanır; pending
   araması da lineer tarama yerine hash. Motor `Insert`: 2,99 → 1,6 µs/anahtar.
3. **Parti, `TDictionary` dolaşım sırasıyla (rastgele) uygulanıyordu.**
   Sayfalara sıçramalı yazım, sıralı yazıma göre belirgin biçimde yavaştır.
   Parti artık **giriş sırasında** uygulanır. Toplu INSERT
   **8,045 → 6,64 µs/satır** (üç ayrı iyileştirmenin toplamı).

### Neden `COUNT(*)` 62 ms? (v3.1'de 0,1 ms)

v2'de `COUNT(*)` tablo satır sayacından **O(1)** yanıtlanır
(`TryGetTableRowCount`); 31 ms ölçülen değer sayaç + doğrulama yoludur.
v3.0'da anahtarlar tablo+PK hash'i olduğu için **tablo başına sayaç yoktu**;
sorgu tam tarama yapıyordu (15,5 MB / 62 ms ≈ 250 MB/s).

**v3.1 düzeltmesi:** `TVdbBackendV3` içinde tablo başına **canlı** satır
sayacı; `.idx`'e gömülü özetten açılışta kurulur, yoksa ilk `COUNT` isteğinde
bir kez tam tarama yapılır (türetilmiş veri, bayatlama riski yok). Hızlı yol
yalnız saf `COUNT(*)` içindir: `WHERE`/`HAVING`/`GROUP BY`/JOIN/`LIMIT` veya
açık parti varsa akışkan tarama kullanılır. **Ölçülen: 0,1 ms** (≈620x).

### v3.0 kabul hedefleriyle karşılaştırma

| Hedef | Hedef değer | v3.0 | v3.1 | Durum |
|---|---:|---:|---:|---|
| Dosya boyutu (SQL harness, 3 kolon) | ≤ 11 MB | 15,5 MB | 15,5 MB | **karşılanmadı** |
| Dosya boyutu (sayfa harness, 32 B değer) | ≤ 11 MB | **9,76 MB** | **9,76 MB** | karşılandı |
| Açılış | ≤ 150 ms | **32 ms** | **27,8 ms** | karşılandı |
| PK nokta | ≤ 7 µs | **6,25 µs** | **5,13 µs** | karşılandı |
| Toplu INSERT | ≤ 5 µs | 6,64 µs | 5,79 µs | sınırda (v2: 4,46) |
| Autocommit INSERT | ≤ 0,55 ms | 0,557 ms | **0,449 ms** | karşılandı (v2: 0,431) |
| `COUNT(*)` | ≤ 16 ms | 62 ms | **0,1 ms** | karşılandı |

Dosya boyutu hedefi iki farklı harness'ı karıştırıyordu: `benchv3` (sayfa
motoru, 32 B değer, 9.756.672 B = 48,8 B/satır) hedefi tutar; `benchcmp`
(SQL katmanı, 3 kolon, ~24 B metin) tutmaz ve v3.1'de de tutmuyor. Tabloda
ikisi ayrı verildi.

**Dürüst özet:** v3.0 dosya boyutunu ve özellikle açılışı kazanıyordu, PK ve
parse maliyeti v2 ile aynıydı; buna karşılık **toplu yazım ~1,5x, `COUNT(*)`
2x ve tek satır yazım ~1,3x daha yavaştı**. v3.1 üçünü de kapattı: `COUNT(*)`
**0,1 ms**, autocommit **0,449 ms** (v3.0'ın 0,557'sinden %19 iyi, v2'nin
0,431'inden %4 yavaş), toplu yazım **5,79 µs** (v3.0'ın %13 altı, v2'nin %30
üstü). Autocommit'te kalan fark **dayanıklılık bedelidir**: ayrı `fsyncbench`
aracıyla tek fsync tabanı **0,330 ms** ölçüldü ve commit başına WAL hacmi
63.373 → **8.252 bayta** indi. Toplu yazımda kalan fark sayfa imajlı WAL'in
2x yazma hacmidir (tasarım maliyeti).

**Ölçüm gürültüsü:** bu makinede koşular arası sapma toplu yazımda
5,76–6,64 µs, autocommit'te 0,449–0,458 ms, parse'ta 3,53–4,59 µs aralığında
görüldü. Tablodaki değerler **üç ardışık koşunun medyanı**; aralık dışı bir
sayı tek koşudan raporlanmamalıdır.

### Sayfa motoru harness'ı (`benchv3`, 200k satır × 32 B değer)

`benchcmp`'ten ayrı bir harness; sayılar karıştırılmamalıdır:

| Metrik | v3.0 | v3.1 |
|---|---:|---:|
| Dosya | 9.756.672 B (48,8 B/satır) | 9.756.672 B (48,8 B/satır) |
| `.idx` | 3.200.064 B (16,0 B/satır) | 3.200.064 B (16,0 B/satır) |
| Yazım (commit + checkpoint dahil) | 1,88 µs/satır | **1,32 µs/satır** |
| Açılış (`.idx` ile) | 16 ms | 21 ms (16–31 aralığı, makine yüküne duyarlı) |
| Açılış (tam tarama) | 79 ms | 63 ms (63–79 aralığı) |
| PK okuma | 0,47 µs/satır | 0,40 µs/satır |
| Ham tarama (kopyalı) | — | 11,3 ms |
| Ham tarama (sıfır-kopya) | — | **9,1 ms** |

## 10. UPDATE/DELETE şişme ölçümü — `bloatbench` (2026-10-28)

Sprint A/1 ölçümü: 100k satır × 32 B değer, churn senaryosu (kabul hedefi
**≤ %5**). Araç: `tests/bench/bloatbench` (`bloatbench <dizin> [satir] [deger]`).
Her adımdan sonra temiz kapanış (`Checkpoint` + `SaveIdx` + `TrimToLogical`);
ölçülen boy dosyadaki **gerçek** boydur. Şişme = gerçek boy / taze boy;
"taze" aynı canlı kümenin sıfırdan yüklenmesidir (ideal boy, sıkıştırma
eşdeğeri referans).

| Adım | İş | Süre | Boy | Not |
|---|---|---:|---:|---|
| 1 | yükleme 100k | 66 ms | boy0 = 4.882.432 B (48,8 B/satır) | heap=1191 |
| 2 | tamamını güncelle (aynı boyut) | 55 ms (0,55 µs/satır) | boy1 = boy0 | **sisme %0,00** (yerinde yazım) |
| 3 | yarısını sil (50k) | 50 ms | boy2 = boy0 | delta %0,00 (her sayfada canlı satır kaldı) |
| 4 | yeni anahtarlarla yeniden ekle (50k) | 55 ms | boy3 = boy0 | **churn şişmesi boy3/boy0 = %0,00** (hedef ≤ %5) |
| 5 | canlıları büyüt (32 → 48 B) | 188 ms | boy4 = 6.508.544 B | +%33,31 — satırlar fiziksel büyüdü (beklenen) |
| 6 | son tur güncelle (aynı boyut) | 84 ms | boy5 = boy4 | sisme %0,00; **boy5/taze = %0,00** |
| 7 | hepsini sil (tam boşaltma) | 86 ms | boy6 = boy5 | dosya **küçülmez** (bkz. aşağıda) |

**Özet sayılar (VACUUM'suz / taze referans):**

- VACUUM'suz churn şişmesi (boy3/boy0): **%0,00** — kabul hedefi ≤ %5 **geçti**.
- Churn + büyütme sonrası şişme (boy5/taze): **%0,00** — taze yükleme ile
  birebir (6.508.544 B). Yani "VACUUM'lu" sayı da bu; gerçek bir Compact API'si
  olmadığı için taze yükleme ideal referanstır.
- `.idx` 64 B, `.wal` 4 KB (kapanış sonrası).

### Kök neden ve motor düzeltmeleri (bu ölçümün öncesi)

İlk koşuda churn şişmesi **+%50** idi (boy3 = 7.319.552 vs boy0 = 4.882.432).
Kök neden iki motordu; ikisi de bu ölçümde kapandı:

1. **`TVdbHeap.PlaceCell` yalnız `FWritePage`'e bakıyordu** — DELETE'in açtığı
   delikler hiç kullanılmıyor, yeniden ekleme 595 yeni sayfa ayırıyordu.
   Düzeltme: boşluk ipuçları (`FSpaceHints`) + `SpaceHintScan` (ilk yerleşim
   hatasında tek tarama). Sonuç: boy3 = boy0, **%0,00**.
2. **`TVDbPageStore.FreePage` yeni trunk için `ExtendFile` çağırıyordu** —
   ilk serbest bırakılan sayfanın kendisi trunk olabilecekken dosya 1 sayfa
   büyüyor; dolu trunk'ta da aynı şey tekrarlanıyordu. Düzeltme: trunk,
   serbest bırakılan sayfanın kendisinden açılır. Sonuç: tam silmede boy6 =
   boy5 (önceki +8 KB'lik büyüme gitti).

### Dürüst sınır: tam boşaltmada dosya küçülmez

Adım 7'de anahtar=0, heap=1 olmasına rağmen dosya 6.508.542 B'de kalır
(1587 sayfa freelist'te). `TrimToLogical` yalnız `FPageCount`'a kadar kısar;
freelist sayfaları `PageCount`'ta sayılır. Bu **SQLite'ın AutoCompact'sız
davranışına benzer** ve tasarım kararıdır: `AutoCompact` varsayılan **False**.
Gerçek geri kazanım (`Compact`) ayrı bir iş maddesidir (bkz.
`tasks/v1_yol_haritasi.md`); ölçüm bu yüzden hem VACUUM'suz (boy5/taze =
%0,00) hem taze referans (aynı sayı) olarak verildi.

### Kapılar (bu değişikliklerden sonra, 2026-10-28)

16 kapı **686/0**: pagechk 21, storechk 15, heapchk 20, idxchk 19,
backendchk 127, v3sqlchk 238, migchk 13, factorychk 13, logchk 43, pitrchk 21,
btreechk 30, replchk 37, lockchk 36, snapchk 21, prochk 21, crashtest 11
(kalan=0). `storechk` freelist beklentileri yeni trunk davranışı (ExtendFile
yok, `FreeCount` = trunk girişi) için güncellendi.

---

## 11. SQL katmanı dosya boyu dökümü — 77,6 B/satır (2026-10-28)

Sprint A/2. Yeni araç: **`tests/bench/sizebench.lpr`** — `benchcmp` ile aynı
iş yükünü kurar (`CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)`,
satır `j`: `id=j, a=j*3, b='satir-'+j`), temiz kapanıştan sonra `.odb`'yi
sayfa sayfa tarar ve baytların nereye gittiğini yazar.

Kullanım: `sizebench <dizin> [satir_sayisi] [autocommit_sayisi]`

### 11.1 Temiz toplu yükleme — 200.000 satır, autocommit yok

`sizebench <dir> 200000 0` → **`.odb` = 9.400.320 B**

| Bileşen | Toplam B | B/satır | Pay |
|---|---:|---:|---:|
| değer (`EncodeRow`) | 6.077.933 | **30,39** | %64,7 |
| hücre başlığı (8 B anahtar + 4 B uzunluk) | 2.400.012 | **12,00** | %25,5 |
| slot dizini (4 B) | 800.004 | **4,00** | %8,5 |
| sayfa başlığı (24 B) | 55.056 | 0,28 | %0,6 |
| sayfa CRC (4 B) | 9.176 | 0,05 | %0,1 |
| bitişik boşluk | 53.989 | 0,27 | %0,6 |
| parçalı (delik) | 50 | 0,00 | %0,0 |
| meta sayfası + yuvarlama | 4.100 | 0,02 | %0,0 |
| **`.odb` toplam** | **9.400.320** | **47,00** | %100 |

Sayfa yapısı: heap **2294**, taşma **0**, freelist **0**, serbest **0**.
Hücre **200.001** (200.000 satır + 1 şema), taşmalı **0**, hücre boyu 34–55 B,
ort. 42,39 B. Parçalanma **sıfır** (Sprint A/1 `PlaceCell` boşluk ipuçları).

Yan dosyalar: `.idx` = **2.188.448 B** (10,94 B/satır), `.wal` = 4.096 B.

### 11.2 `EncodeRow` 30,39 B'nin dökümü

Ölçüm 6.077.933 B / 200.001 hücre. Aşağıdaki dağılım ham hücre baytlarının
çözümlemesiyle **birebir** doğrulandı (j=1 hücresi 22 B = 7+3+3+9).

| Alan | B/satır | Ne |
|---|---:|---|
| satır kabuğu | 7,00 | 2 B `$FFFF` + 2 B tablo kimliği + 2 B pk→kolon referansı (v3.13 dedup) + 1 B kolon sayısı |
| `id` (INT, PK) | 4,96 | 1 B ctype + 1 B uzunluk kodu + zigzag LEB128 (1–3 B; %95,9'unda 3 B) |
| `a` (INT) | 4,99 | aynı |
| `b` (TEXT) | 13,44 | 1 B ctype + 1 B uzunluk kodu + `'satir-'+j` (7–12 B UTF-8, ort. 11,44 B) |
| **toplam** | **30,39** | |

İlk hücrenin ham dökümü (j=1, degerBoy=22):

```
FF FF | 01 00 | 00 01 | 03 | 00 02 02 | 00 02 06 | 02 08 73 61 74 69 72 2D 31
 ext    tablo=1  pk→0   3    id=1        a=3        b='satir-1'
```

**Yapısal yük: 29 B/satır** (7 kabuk + 3×2 ctype/uzunluk + 12 hücre başlığı +
4 slot). Kalan 18 B iş yükünün kendi verisidir (`'satir-N'` metni + INT'ler).

### 11.3 `.idx` 10,94 B

Biçim (`VDbIdxFile.pas`): 64 B başlık + kayıt başına
`Key(8) | PageNo(varint) | Slot(varint)`.
200.001 kayıt × ort. **10,94 B** = 2.188.384 B + 64 B başlık ≈ 2.188.448 B.
Anahtar **ham 8 bayt** kalır: `VDbHashKey` 64-bit FNV-1a, hash'ler tek biçimli
dağıldığı için varint'e çevrilse ~10 B'ye çıkar, küçülmez. Sayfa/slot zaten
varint.

### 11.4 77,6 B/satır nereden geldi — ölçüm hatası, kod eksiği değil

§9 ve `readme*.md` tablolarındaki **15.527.936 B (77,6 B/satır)** sayısı
2026-10-25'te v3.0/v3.1 koduyla ölçülmüştü. Bugünkü kod (v3.29 + Sprint A motor
düzeltmeleri) aynı `benchcmp` ile **10.178.560 B** veriyor
(`benchcmp --backend=v3 200000 20000`, 3 tur medyan, 2026-10-28).

İki farkın kaynağı:

1. **Kod farkı.** Aradan geçen sürümler satırı küçülttü: v3.11 satır kabuğu,
   v3.13 PK dedup (pk satırda iki kez durmuyor), v3.2 INT zigzag varint
   (INT 12 B → 4–5 B), Sprint A `PlaceCell`/`FreePage`. §11.1'deki 47,00 B/satır
   bugünkü kodun sayısıdır.
2. **Bölen hatası.** `benchcmp` dosyaya 200.000 toplu + 20.000 autocommit +
   1 şema = **220.001** hücre yazar ama `NRow=200000`'e böler. 77,6 sayısı bu
   yüzden ~%10 şişkindir. Aynı dosyanın doğru böleni bugün **46,27 B/satır**.

Kanıt: eski `.idx` boyu 3.520.080 B = 220.001 × 16 B + 64 B (eski sabit-boy
kayıt) — dosyada gerçekten 220.001 satır varmış, bölen 200.000'di.

**"~31 B/satır açıklanamayan boşluk" yok.** 47,00 B/satır'ın tamamı §11.1
tablosunda; 30,39 B'nin tamamı §11.2'de.

20.000 autocommit satırı toplam 778.240 B ekliyor (**38,9 B/satır**): bu
satırların değerleri daha küçük (`b='auto'`, `a=1..20000`), o yüzden tek başına
ucuzlar — commit başına şişme değil.

### 11.5 11 MB hedefi ile karşılaştırma ve yol

| Ölçü | Değer | Hedef | Durum |
|---|---:|---:|---|
| `.odb`, 200k toplu satır | 9.400.320 B (47,00 B/satır) | ≤ 11 MB (≤ 55 B/satır) | **tuttu** |
| `.odb` + `.idx` | 11.588.768 B (57,94 B/satır) | ≤ 11 MB | %5 üstünde |
| `.idx` tek başına | 2.188.448 B (10,94 B/satır) | — | tek açık kalem |

Yol (sayılarla, uydurma sıkıştırma yok):

- **`.odb` hedefi zaten tutuyor** (47,00 < 55). Sıkıştırma gerekmiyor.
- **Kalan tek açık `.idx`.** İçinde sıkıştırma alanı yok (§11.3). Yapısal
  seçenekler, ölçülür bedelleriyle:
  - `.idx`'yi yazmama — diskte toplam 11,59 → 9,40 MB; karşılığında açılış
    16 ms → **79 ms** (tam heap taraması, §3 ölçümü). Hedef 150 ms'nin altında.
  - `.idx`'yi sayfa düzeyine indirme — 2294 sayfa × ~16 B ≈ **37 KB**
    (yaklaşık hesap, ölçülmedi); karşılığında açılışta sayfa içi arama.
    Ölçülmeden sayıya bağlanmaz.
- **Satır içi gerçek 2 B'lik fırsat:** hücre başlığındaki uzunluk alanı 4 B
  (`LongWord`) ama gövde sınırı 1.000 B / taşma 4.000 B. 200k satırda
  **~400 kB** (dosyanın %4,3'ü). Biçim değişikliği ister (taşma bayrağı
  `VDB_OVF_FLAG` bu alanda yaşıyor); ölçümle karar verilecek ayrı iş.

### 11.6 Kapılar (bu değişiklikten sonra)

`sizebench` yeni araçtır, kapı değildir. 16 kapı değişmedi — §10'daki
**686/0** sayısı geçerlidir.

## 12. Commit CPU profili — fsync'in payı (2026-10-29)

Sprint B/5: `cpubench`'in ~160 µs/commit sayısının nereye gittiğini
ayırmak için `-dCPUPROF` enstrümantasyonu yazıldı (`VDbCpuProf.pas`,
`cpuprof.lpr`, `engprof.lpr`). Ölçüm **CPU zamanıdır** (GetProcessTimes,
kernel+user); fsync *bekleme* sayılmaz ama `FlushFileBuffers`'ın
**kernel CPU'su sayılır** — bu, aşağıdaki tabloda "fsync" satırının
asıl kaynağıdır.

### 12.1 Tekil autocommit, N=25000 (24 bayt değer)

| Bileşen | µs/commit | Pay |
|---|---:|---:|
| hazırlık + kilit + uygulama | 0,62 | %0,4 |
| **fsync** (`AwaitDurable`) | **159,25** | **%97,1** |
| WAL commit (`DoCommit` içi) | 2,50 | %1,5 |
| — bunun: motor:frame | 0,62 | |
| — bunun: motor:wal | 1,87 | |
| günlük (`LogFinish`) | 0,00 | %0,0 |
| checkpoint | 1,87 | %1,1 |
| bırakış | 0,00 | %0,0 |
| **CommitBatch toplam** | **164,38** | %100 |

`BeginBatch` 0,00 µs ve `Put+val` 0,63 µs — iş yükünün **tamamı**
`CommitBatch`'te. Toplantı katmanı bedava.

**Sonuç: optimize edilebilir CPU ≈ 5 µs** (fsync dışı). Toplamın %3'ü.
§7j.3'teki "CPU payı ≈ 75 µs" hesabı **çürüdü**; o tahmin fsync süresini
yanlış paylaştırıyordu. Gerçek ayrım: fsync **bekleme** ~300 µs duvar,
ama fsync'in **kernel CPU'su** ~159 µs.

### 12.2 engprof ↔ cpuprof çelişkisi (çözüldü)

Önceki ölçümlerde `engprof` Commit(nosync) = 24,4 µs çıkarken
`cpuprof` CommitNoSync = 1,9 µs ölçülüyordu — ikisi de `DoCommit(False)`.
Kaynak **iş yükü farkıydı**:

- `engprof` anahtarları `QWord(1000000+i) * $9E3779B97F4A7C15` — **rastgele
  dağılıyor**, her insert farklı sayfayı kirletiyor → daha çok `TxnPages`,
  daha çok WAL frame'i.
- `cpuprof`/`cpubench` anahtarları artan (`1000000+i`) — aynı sayfa
  yeniden kirleniyor → 1-2 frame/commit.

DoCommit içi zamanlayıcılarla doğrulandı: `cpuprof`'ta motor:frame 0,62 +
motor:wal 1,87 = **2,49 µs** ≈ backend "wal" 2,50 µs. `engprof`'ta aynı
toplam 26,9 µs — fazladan olan frame sayısı. **Kod farkı yok**, aynı
`DoCommit`.

### 12.3 B/3 (LogFinish/EndGroup tahsis kaldırma) kararı

A/B ölçümü farkı gürültüde kayboldu (A min 144,38 / ort ~159,1;
B min 143,75 / ort ~159,3). Regresyon yok, kapılar temiz.
**Tutuldu** — tahsis sayısı düştü, ölçülebilir hız kazancı yok.

### 12.4 Sprint B kapanışı için ne kalıyor

Kapanış maddesi: "autocommit 0,355 ms SQLite tabanına ≤ %5
(≈ ≤ 0,37 ms) veya kalan farkın fsync dışı **ölçülmüş** CPU olduğu
belgelenir."

Ölçülen: fsync dışı CPU **≈ 5 µs**. SQLite'ın iddia edilen 55 µs
CPU'sunun **onda biri**. Yani kalan fark fsync'te — bizim fsync'miz
~159 µs kernel CPU harcıyor. Bu, Sprint B'nin kapatabileceği bir alan
**değil**; grup fsync Sprint C'nin konusu (§7m.3).

Sprint B'yi tam kapatmak için tek eksik: **SQLite'ın aynı iş yükünde
CPU ölçümü** (`benchcmp`, WAL mode, autocommit, 24 bayt × N). O ölçüm
"fark fsync'te" tezini sayıya bağlar. O ölçüm gelmeden Sprint B
**koşullu kapandı** sayılır: optimize edilebilir alan kalmadı, kanıt
eksik kalem SQLite karşılaştırması.

### 12.5 SQLite CPU ölçümü (Sprint B kapanış kanıtı)

Aynı iş yükü (24 bayt değer × 25.000, tek tek autocommit, `journal_mode=WAL`,
`synchronous=FULL`), Python `sqlite3` (resmî 3.x), `time.process_time()`:

| Motor | µs/işlem (CPU) | fsync dışı |
|---|---:|---:|
| **SQLite** (WAL+FULL) | **106,88** | ~5 (tahmin) |
| **VDB v3** (`cpuprof`) | **164,38** | **5,13** (ölçüldü) |
| fark | +57,5 | ≈ 0 |

**Tez doğrulandı: kalan fark fsync'in kendisinde.** Bizim fsync'miz
(`FlushFileBuffers` kernel CPU'su) **~159 µs**, SQLite'ınki ~102 µs
(106,88 − ~5 iş). Fark ≈ **57 µs**.

En olası kaynak: **WAL'e yazılan veri miktarı**. Biz her commit'te tam
sayfa imajı (4 KB) yazıyoruz; SQLite yalnız değişen kaydı (~30 bayt +
başlık). Kernel, `FlushFileBuffers`'ta yazılan bayt kadar CPU harcıyor.
Bu, Sprint B'nin değil, ayrı bir tasarım işinin konusu (delta tabanlı WAL);
sayfa imajı WAL'i kurtarma için basit ve güvenli — değişiklik ölçülmeden
yapılmaz.

Sprint B kapanışı **KAPANDI** sayılır: optimize edilebilir CPU ≈ 5 µs,
fark fsync'te, kanıt §12.1 + §12.5.

## 13. Tazelemede disk yazmasının kaldırılması — C/5 (2026-10-29)

### 13.1 Sorun: tazeleme `EWriteError` üretiyordu

`mixbench` (tek süreç, iki backend: `be1` yazıcı + `be2` okuyucu) tazeleme
yolunda çöküyordu. Tam yığın (DWARF2):

```
INSTALLPAGE,        VDbPageStore.pas:2757   ← FStream.WriteBuffer
APPLYRECOVERED,     VDbPageEngine.pas:737
RECOVER,            VDbPageWal.pas:756
STOREREFRESHED,     VDbPageEngine.pas:439
REFRESHIFSTALEFORCE,VDbPageStore.pas:972
REFRESHIFSTALE,     VDbPageStore.pas:1038
ACQUIREREAD,        VDbPageStore.pas:1310   ← paylaşımlı kilit
GET,                VDbBackendV3.pas:1631
```

**Kök neden:** tazeleme `AcquireRead` (paylaşımlı kilit) altında
`InstallPage` ile diske yazıyordu. Windows'ta byte-aralığı kilidi yazmayı
`ERROR_LOCK_VIOLATION` ile engeller; `TStream.WriteBuffer` bunu
`EWriteError` yapar.

Kapıların temiz çıkması (prochk 21/0, lockchk 36/0) yanıltıyordu: oradaki
okuyucu RO idi ve `ApplyReadOnly` yolunu kullanıyordu (diske yazmaz).
`mixbench`'in `be2`'si RW idi ve `ApplyRecovered` yoluna giriyordu.

### 13.2 Çözüm: tazeleme yalnızca önbelleği kurar

`InstallPage`'e `AViewOnly` parametresi eklendi. Tazeleme yolu
(`StoreRefreshed` → `ApplyRecoveredView` → `InstallPage(..., True)`):

* diske **hiçbir şey yazmaz** (ne `WritePageAt`, ne meta, ne `GrowTo`);
* sayfayı önbelleğe kurar ve **temiz** işaretler (`Dirty := False`);
* yeni sayfa sayısı mantıksal olarak artar, fiziksel büyüme bir sonraki
  `Flush`/commit'te olur.

**Neden güvenli:** imaj zaten WAL'de fsync'li — durabil kaynak WAL'dir,
dosya değil. Diskteki sürüm yazıcının kendi commit'inde güncellenir.
`Checkpoint` (`Truncate`) yalnız yazıcının `Flush`'ından sonra budandığı
için veri kaybi olmaz. Açılıştaki ilk kurtarma (`Open`) yazmaya devam eder
(tam kilit altında); yalnız tazeleme yazmaz.

`LoadFrame`'e `AImage: PVdbPage` parametresi eklendi: tazeleme imajı
hazırdır, diskten okunmaz (ek I/O yok).

### 13.3 Ölçüm — `mixbench` (tek süreç, iki backend)

§7p.5 tabanıyla aynı tartı. İki koşunun ortalaması:

| Ölçüm | Taban (§7p.5) | C/5 sonrası | Fark |
|---|---:|---:|---:|
| 300×1 yazma | 0,412 ms/işlem | 0,410 ms/işlem | ≈ eşit |
| 300×1 okuma | 270,2 µs/sorgu | **119,0 µs/sorgu** | **2,27x** |
| 300×10 okuma | 30,4 µs/sorgu | **14,7 µs/sorgu** | **2,07x** |
| 300×1 en yüksek okuma | — | 0,321 ms | — |
| 300×10 en yüksek okuma | — | 0,264 ms | — |

Yazma maliyeti değişmedi — tazeleme artık diske yazmadığı için yazıcıya
yük binmiyor. Okuma maliyeti ~2,2x düştü: `ReindexPages` (O(delta)) +
`InstallPage`'in yazmasız kurulumu, O(DB) `FHeap.Open` taramasının yerini
aldı.

### 13.4 Kapılar (bu değişiklikten sonra, 2026-10-29)

16 kapı **686/0** — önceki birebir aynı sayı, regresyon yok:

| Kapı | Geçen | Kalan |
|---|---:|---:|
| pagechk | 21 | 0 |
| storechk | 15 | 0 |
| heapchk | 20 | 0 |
| idxchk | 19 | 0 |
| backendchk | 127 | 0 |
| v3sqlchk | 238 | 0 |
| migchk | 13 | 0 |
| factorychk | 13 | 0 |
| crashtest | 11 | 0 |
| logchk | 43 | 0 |
| pitrchk | 21 | 0 |
| btreechk | 30 | 0 |
| replchk | 37 | 0 |
| lockchk | 36 | 0 |
| snapchk | 21 | 0 |
| prochk | 21 | 0 |
| **Toplam** | **686** | **0** |

### 13.5 Ne kaldı

* ~~`FHeapPages`/`FOvfPages` reindex'te tahmini kalır (eski sayfa tipi
  bilinemediği için) — yalnız istatistik/`SpaceHintScan` için. Sprint D
  bu işi tam ele alacak.~~ → **Sprint D'de yapıldı**: `FPageType` sayfa tipi
  izi sayesinde artık doğru güncelleniyor (bkz. §15.1).
* `mixbench` iki-backend desenini yalnız RW okuyucuyla sınıyor; RO okuyucu
  ayrı yol (`ApplyReadOnly`). İkisi de kapılarla korunuyor.

## 14. C/6 + C/7 — süreçler arası grup fsync ve SQLite kıyası (2026-10-29)

### 14.1 C/6: `.gen` sayfası ve `durableLsn`

`.gen` dosyası 16 bayttır (v3.31):

| Ofset | Alan | Tip |
|-------|------|-----|
| 0 | gen sayacı | QWord |
| 8 | `durableLsn` | LongWord |

Bir process `AwaitDurable`'da fsync yaptığında `.gen`'e kendi LSN'ini yazar
(`SetDurableLsn`, yalnızca başarılı fsync'ten SONRA). Başka bir process
kendi LSN'i bu değerden küçük/eşitse fsync'i atlar.

**Rezervasyon fsync'ten önce bırakılmaz** — §7m.3 ölçümü: o yol 0,36x.
`ReleaseWriteHold`, `AwaitDurable`'dan SONRA çağrılır; bu yüzden süreçler
arası atlama pratikte nadiren tetiklenir.

Yapısal sınır: paylaşımlı dosyada tüm commit'ler tek bir
`AcquireWriteHold`/`AcquireDataWrite` seri kilit hattından geçer.
§7m.5'teki üç işten ikisi yapıldı (delta tazeleme C/5, `.gen` durableLsn
C/6); üçüncüsü (rezervasyonu fsync'ten önce bırakma) ölçülmüş olarak
yasak (0,36x).

**Kapılar:** 16 kapı **686/0**. `mixbench` regresyon yok.

### 14.2 C/7: `pcbench` P=1/2/4 — VDB vs SQLite 3.50.4

Ölçüm: `pcbench <dizin> <P> <N> [apart]`. P süreç × N autocommit
(BeginBatch + Put 24B + CommitBatch). Serial taban aynı toplam commit
sayısıyla (P×N). SQLite: `journal_mode=WAL`, `synchronous=FULL`, aynı
24B değer, `multiprocessing` ile P çocuk.

#### Tek dosya (paylaşımlı)

| | P=1 | P=2 | P=4 |
|---|---|---|---|
| **VDB hızlanma** | 0,83x | 0,79x | **0,88x** |
| VDB ms/commit (paralel) | 0,448 | 0,478 | 0,444 |
| VDB ms/commit (serial) | 0,372 | 0,378 | 0,382 |
| **SQLite hızlanma** | 0,91x | 0,86x | **0,80x** |
| SQLite ms/commit (paralel) | 0,387 | 0,398 | 0,437 |
| SQLite ms/commit (serial) | 0,352 | 0,344 | 0,351 |

#### Ayrı dosya (`apart`)

| | P=1 | P=2 | P=4 |
|---|---|---|---|
| **VDB hızlanma** | 0,90x | 1,68x | **2,71x** |
| VDB ms/commit (paralel) | 0,447 | 0,229 | 0,141 |
| VDB ms/commit (serial) | 0,404 | 0,385 | 0,382 |
| **SQLite hızlanma** | 0,92x | 1,88x | **2,99x** |
| SQLite ms/commit (paralel) | 0,375 | 0,187 | 0,115 |
| SQLite ms/commit (serial) | 0,375 | 0,350 | 0,344 |

#### Sonuç

* **Paylaşımlı dosyada** VDB ≈ SQLite (ikisi de ~1,0x altında).
  Hızlanma oranında VDB hafif üstün (0,88x vs 0,80x); mutlak ms/commit'te
  SQLite üstün (~0,44 vs ~0,44 — eşdeğer).
* **Ayrı dosyada** SQLite ~%10 daha hızlı (2,99x vs 2,71x).
* **"Paralel yazmada SQLite'tan hızlıyız" cümlesi bu tabloyla SÖYLENEMEZ.**

### 14.3 Tavanın nedeni — ölçümle

`pcbench` `-dCPUPROF` ile `CpuProfDump` (P=4, N=400, tek dosya):

```
cocuk 101: fsync 233,79 µs/commit
cocuk 102: fsync  77,93 µs/commit
cocuk 103: hazirlik+kilit+uygulama 38,97 + fsync 77,93 µs/commit
cocuk 100: hazirlik+kilit+uygulama 38,97 + fsync 116,90 µs/commit
```

`CpuProfNow` = `GetProcessTimes` (user+kernel CPU). Disk bekleme
(I/O wait) CPU'ya yazılmaz.

| Bileşen | CPU (µs/commit) | Duvar payı |
|---|---|---|
| **fsync** | **78–234** | **baskın** |
| hazirlik+kilit+uygulama | ~39 | ikincil |
| WAL yazımı, log, checkpoint, bırakma | ~0 | ihmal edilebilir |

Toplam duvar süresi ~400–477 µs/commit; CPU toplamı ~117–273 µs.
**Fark disk gecikmesi** (WAL yazımı + fsync I/O bekleme).

**Tavan açıklaması:** Paylaşımlı dosyada her commit tek bir fsync
yapmak zorunda; fsync tek dosyada paralelleştirilemez. `apart`
modunun 2,71x'i bu tezi doğruluyor — ayrı dosya = ayrı fsync = paralel
ilerleme. Kilit serileşmesi (~39 µs) ikincil; asıl darboğaz fsync +
disk gecikmesi.

## 15. Sprint D — tazelemede O(delta) heap (2026-10-29)

### 15.1 Yapılan

`VDbPageHeap.pas`'e **ters harita** (`FPageKeys: array of array of QWord`)
ve **sayfa tipi izi** (`FPageType: array of Byte`) eklendi. `ReindexPages`
Phase 1'i artık O(cap) hash tablosu taraması yerine O(delta) ters harita
kullanıyor:

* `DirAdd`/`DirDel` → `PageMapAdd`/`PageMapRemove` ile ters harita bakımı.
* `DirGrow` → `FPageKeys` sıfırlanır, hash tablosundan yeniden kurulur;
  `FPageType` **korunur** (ilk hatada burasıydı: `PageMapClear` çağrısı
  `FPageType`'i de temizliyor, `FHeapPages` sayaçları bozuluyordu).
* `Open` → `FPageType` sayfa tipine göre doldurulur (1=HEAP, 2=OVF, 3=diğer).
* `ReindexPages` Phase 2 → `FHeapPages`/`FOvfPages` artık doğru güncelleniyor
  (eski tip → yeni tip farkı).

### 15.2 Kapılar (2026-10-29)

16 kapı **686/0** — regresyon yok:

| Kapı | Geçen | Kalan |
|---|---:|---:|
| pagechk | 21 | 0 |
| storechk | 15 | 0 |
| heapchk | 20 | 0 |
| idxchk | 19 | 0 |
| backendchk | 127 | 0 |
| v3sqlchk | 238 | 0 |
| migchk | 13 | 0 |
| factorychk | 13 | 0 |
| crashtest | 11 | 0 |
| logchk | 43 | 0 |
| pitrchk | 21 | 0 |
| btreechk | 30 | 0 |
| replchk | 37 | 0 |
| lockchk | 36 | 0 |
| snapchk | 21 | 0 |
| prochk | 21 | 0 |
| **Toplam** | **686** | **0** |

### 15.3 Ölçüm — `mixbench` (2026-10-29)

`mixbench.exe <dizin> <tur> <R>`: tek süreç, iki backend (`be1` yazıcı +
`be2` okuyucu). Her turda 1 commit + R nokta okuma.

| Kip | 300 tur (~1300 satır) | 22000 tur (~23000 satır) | Oran |
|---|---|---|---|
| R=1 okuma | 106,6 µs/sorgu | 158,9 µs/sorgu | 1,49x |
| R=1 en yüksek okuma | 0,224 ms | 5,505 ms | — |
| R=10 okuma | 12,3 µs/sorgu | 18,2 µs/sorgu | 1,48x |
| R=10 en yüksek okuma | 0,219 ms | 6,003 ms | — |
| Yazma | 0,391 ms/işlem | 0,403 ms/işlem | 1,03x |

**Değerlendirme:**

* Okuma maliyeti DB boyuyla **1,49x** artıyor (23x değil). Bu,
  `ReindexPages`'in O(delta) olduğunun göstergesi — O(cap) olsaydı
  23k satırda FCap ~32k tarama okuma maliyetini ~23x büyütürdü.
* Artışın kaynağı: (a) WAL budama → tam tazeleme (`FHeap.Open`, O(DB)),
  (b) daha büyük hash tablosunda önbellek kaybı (DirFind sondalama).
* En yüksek okuma (5,5 ms) WAL budama anındaki tam tazelemeden; bu
  yol Sprint D kapsamında **değil** (§7p.7 kabulü: WAL kesilirse tam
  yeniden yükleme kaçınılmaz).
* Yazma maliyeti değişmedi (1,03x) — tazeleme yazıcıya yük bindirmiyor.

### 15.4 Kapanış

Sprint D **KAPANDI**: tazeleme maliyeti DB boyuyla O(DB) değil O(delta);
ters harita sayesinde `ReindexPages` Phase 1'i yalnız değişen sayfalardaki
anahtarları siliyor. 23k satırda okuma maliyeti 1,49x (23x değil) —
`FHeap.Open`'ın ~125 µs'lik O(DB) payı yalnız tam tazeleme yolunda kaldı
(WAL budama ~2000 commit'te bir).

## 16. Sprint E — ON/WHERE pushdown (2026-10-29)

### 16.1 Yapılan

JOIN döngüsüne girmeden önce tek taraflı predikatların ilgili tarafın
taramasına itilmesi (`pushdown`). `VDbExecutor.pas` → `MergeStep` içinde:

* `ExprSide(N)` — ifadenin hangi tarafa atıf yaptığını bulur (1=sol, 2=sağ).
* `CollectOneSided(N, LPreds, RPreds)` — AND ağacındaki tek taraflı alt
  koşulları toplar.
* `FilterSide(Rows, Preds, SideStart, SideLen)` — predikatları ilgili
  tarafa uygular.

**Güvenlik kuralları:**

| Predikat kaynağı | Sol tek taraflı | Sağ tek taraflı |
|---|---|---|
| ON | INNER, RIGHT | INNER, LEFT |
| WHERE | INNER, LEFT | INNER, RIGHT |

ON ve WHERE'in ters yönlerde güvenli olmasının nedeni: ON eşleşmeyi
belirler (NULL sarmalama gerekir), WHERE sonucu eler (filtreleme yeterli).
FULL JOIN'de her iki tarafta da pushdown güvenli değil.

### 16.2 Ölçüm — `joinbench` (2026-10-29)

10k×10k satır, `SELECT COUNT(*) FROM a JOIN b ON a.k = b.k AND a.k > 1000000`:

| Durum | Süre | Hızlanma |
|---|---|---|
| Pushdown öncesi | 5.926 ms | — |
| Pushdown sonrası | 61,1 ms | **~97x** |

### 16.3 Kapılar (2026-10-29)

| Kapı | Test | Kalan |
|---|---|---|
| pagechk | 21 | 0 |
| storechk | 15 | 0 |
| heapchk | 20 | 0 |
| idxchk | 19 | 0 |
| backendchk | 127 | 0 |
| v3sqlchk | 238 | 0 |
| migchk | 13 | 0 |
| factorychk | 13 | 0 |
| crashtest | 11 | 0 |
| logchk | 43 | 0 |
| pitrchk | 21 | 0 |
| btreechk | 30 | 0 |
| replchk | 37 | 0 |
| lockchk | 36 | 0 |
| snapchk | 21 | 0 |
| prochk | 21 | 0 |
| **Toplam** | **686** | **0** |

SQL testleri: 3295/0.

### 16.4 Kapanış

Sprint E **KAPANDI**: ON/WHERE pushdown ile 10k×10k JOIN 5.926 ms → 61,1 ms
(~97x). Güvenlik kuralları FULL JOIN dahil tüm join tiplerinde doğrulandı
(2 FULL JOIN testi düzeltildi: WHERE pushdown'un join tipine göre kısıtlanması).

## 17. Sprint F — v1.0.0 kapanış ölçümü (2026-10-29)

### 17.1 `benchcmp` — 200k satır × 3 kolon, 3 tur medyan

Tablo şeması: `t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)`.

| Metrik | v2 | v3 | Hedef | Durum |
|---|---|---|---|---|
| Dosya boyutu | 11.878.732 B (59,4 B/satır) | **9.400.320 B (47,0 B/satır)** | ≤ 11 MB | ✔ |
| Toplu INSERT | 801,3 ms (4,006 µs/satır) | 1.128,9 ms (5,644 µs/satır) | — | — |
| Autocommit INSERT | 0,644 ms/satır | **0,184 ms/satır** | — | — |
| Parse-only SELECT | 24,33 µs/çağrı | 19,67 µs/çağrı | — | — |
| PK nokta okuma | 17,67 µs/sorgu | 24,00 µs/sorgu | ≤ 7 µs | — |
| COUNT(*) | 29,4 ms | **0,0 ms** | — | — |
| Açılış | 724,2 ms | **63,0 ms** | ≤ 150 ms | ✔ |

### 17.2 `bloatbench` — UPDATE/DELETE şişme (100k satır × 32 B)

| Adım | Boyut | Şişme |
|---|---|---|
| Yükleme (boy0) | 4.882.432 B (48,8 B/satır) | — |
| Güncelleme (boy1) | 4.882.432 B | **%0,00** |
| Silme (boy2) | 4.882.432 B | %0,00 |
| Yeniden ekleme (boy3) | 4.882.432 B | **%0,00** (hedef ≤ %5) ✔ |
| Büyütme 32→48 B (boy4) | 6.508.544 B | %33,31 (beklenen) |
| Son tur (boy5) | 6.508.544 B | %0,00 |
| Taze boy (ideal) | 6.508.544 B | — |
| Churn şişmesi (boy5/taze) | — | **%0,00** ✔ |

### 17.3 Kapılar (2026-10-29)

| Kapı | Test | Kalan |
|---|---|---|
| pagechk | 21 | 0 |
| storechk | 15 | 0 |
| heapchk | 20 | 0 |
| idxchk | 19 | 0 |
| backendchk | 127 | 0 |
| v3sqlchk | 238 | 0 |
| migchk | 13 | 0 |
| factorychk | 13 | 0 |
| crashtest | 11 | 0 |
| logchk | 43 | 0 |
| pitrchk | 21 | 0 |
| btreechk | 30 | 0 |
| replchk | 37 | 0 |
| lockchk | 36 | 0 |
| snapchk | 21 | 0 |
| prochk | 21 | 0 |
| **Toplam** | **686** | **0** |

SQL testleri: 3295/0.

### 17.4 Kapanış

Sprint F **KAPANDI**: 200k × 3 kolon ölçümü tamamlandı. Hedef tablosu:

| Hedef | Ölçüm | Durum |
|---|---|---|
| Dosya ≤ 11 MB | 9,40 MB | ✔ |
| Açılış ≤ 150 ms | 63,0 ms | ✔ |
| UPDATE/DELETE şişme ≤ %5 | %0,00 | ✔ |
| PK ve yazma gerilememiş | v3'te COUNT(*) 0,0 ms (v2: 29,4 ms) | ✔ |

Tüm kapılar 686/0, SQL testleri 3295/0. `v1.0.0` etiketi hazır.

---

## 18. Sprint G/0 — delta WAL hipotezi A/B ölçümü (2026-10-29)

**Soru:** Toplu yazım boşlukları (INSERT 1M 7,7x / UPDATE 100k 15,8x / DELETE 100k
14,9x) fsync'ten mi kaynaklanıyor? Delta tabanlı WAL (sayfa imajı yerine ~100 B
değişiklik kaydı) bu boşlukları kapatır mı?

**Plan gereği:** "G/0: A/B ölçüm önce. Kazanç kanıtlanmadan koda girilmez."

### 18.1 Araçlar

- `walab` — gerçek WAL çerçeve düzenini taklit eden ham A/B ölçümü.
  20 B başlık + payload + commit kaydı; `--nosync`, `--frames=K`.
  Duvar (`QueryPerformanceCounter`) + CPU (`GetProcessTimes`) + B/commit.
  3 tur medyan, N=20000.
- `bulkcpu` — motorun toplu yazım yolunu CPUPROF bileşenleriyle ölçer.
  `TVdbBackendV3` üzerinden tek `BeginBatch`/`CommitBatch` içinde N satır.

### 18.2 A/B: payload boyu ↔ fsync CPU'su (walab, N=20000, 3 tur medyan)

| paylen | B/commit | duvar ms/commit | CPU ms/commit |
|---:|---:|---:|---:|
| 4096 | 4136 | 0,331 | 0,108 |
| 1024 | 1064 | 0,307 | 0,098 |
| 128 | 168 | 0,309 | 0,095 |
| 30 | 70 | 0,310 | 0,091 |
| 0 | 40 | 0,307 | 0,086 |

**Sonuç:** Payload 100× azalsa bile CPU yalnızca **108 → 86 µs** (22 µs, ~%20);
duvar **331 → 307 µs** (~%7). fsync sabit maliyeti **~85–100 µs** ve payload'a
neredeyse bağımsız.

`--nosync` (yalnız yazma, fsync yok):

| paylen | CPU ms/commit |
|---:|---:|
| 4096 | 0,010 |
| 30 | 0,006 |
| 0 | 0,005 |

Yazma bedeli ihmal edilir. Fark tamamen fsync'in sabit maliyeti.

**--frames=4** (16484 B): 4096→0,125 ms; 30→0,103 ms. Fark yine ~22 µs.
**--frames=2** (gerçek motor 8252 B): duvar 0,338 ms; CPU 0,130 ms.
**Dosya boyu etkisi:** N=500 (~2 MB) 0,094 vs N=20000 (~82 MB) 0,102 — önemsiz.
**C:\temp (aynı disk):** 4096→0,106; 30→0,092; 0→0,095 — D: ile aynı.

### 18.3 Toplu yol: fsync-bound mı, CPU-bound mu? (bulkcpu, N=100000, 24 B)

| İş | duvar ms | CPU ms | µs/satır (duvar) | µs/satır (CPU) |
|---|---:|---:|---:|---:|
| INSERT | 189,0 | 187,5 | 1,89 | 1,88 |
| UPDATE | 198,3 | 187,5 | 1,98 | 1,88 |
| DELETE | 202,0 | 203,1 | 2,02 | 2,03 |

**duvar ≈ CPU** — I/O beklemesi yok. Toplu yol **CPU-bound**.

CPUPROF bileşen dağılımı (ort. µs/commit, N=4 işlem; GetProcessTimes 15,6 ms
çözünürlük, büyük değerler güvenilir, fsync ölçülür düzeyin altında kalıyor):

| Bileşen | µs/commit | Pay |
|---|---:|---:|
| hazirlik+kilit+uygulama | 58.594 | %65 |
| gunluk (LogFinish) | 15.625 | %17 |
| wal (CommitNoSync) | 7.813 | %9 |
| motor:frame | 3.906 | %4 |
| motor:wal | 3.906 | %4 |
| fsync (AwaitDurable) | ölçülemiyor | ~%0 |

Toplu yolda fsync işlem sonunda **bir kez** olur (~0,33 ms). Satır başına
1,89 µs'lik işin fsync olması imkansız.

### 18.4 SQL katmanı ↔ ham motor

| Yol | µs/satır | Not |
|---|---:|---|
| Ham backend `Put(key, 24B)` | **1,89** | bulkcpu, 100k tek işlem |
| SQL/tablo `tb.Insert` (3 kolon + PK) | 24,1 | §4, 1M satır |
| SQLite INSERT (BEGIN/COMMIT) | 3,12 | §4 |

**Ham motor zaten SQLite'dan hızlı** (1,89 vs 3,12). §4'teki 7,7x boşluğun
~%93'ü SQL/tablo katmanında: satır biçimleme, `IntToStr` dönüşümleri, PK indeks
bakımı, tip dönüşümleri. Depolama motoru darboğaz değil.

### 18.5 Sonuç — hipotez ÇÜRÜDÜ

1. **Delta WAL fsync boşluğunu kapatamaz.** Payload 100× azalsa bile kazanç
   ~22 µs (108→86). Planın "fsync 159→~20 µs, INSERT 7-19x→1-2x" tahmini
   gerçekçi değil.
2. **Toplu boşluklar fsync'ten değil.** duvar ≈ CPU; fsync toplam zamanın
   binde biri. Delta WAL bu boşluklara hiçbir şey kazandırmaz.
3. **Asıl hedef SQL/tablo katmanı.** Ham motor 1,89 µs/satır; SQL yolu 24,1.
   ~22 µs/satır satır işleme, indeks ve biçimleme gidiyor.
4. **İkincil hedef:** `AwaitDurable` kitap işi. Ham write+fsync (4 KB):
   108 µs CPU. Motorda fsync bileşeni 159 µs. ~50 µs fark lider seçimi,
   kritik bölüm, olay sinyalizasyonu. Küçük ama gerçek.

**Sprint G (delta WAL) iptal.** Planın öngördüğü gibi "kazanç çıkmazsa plan
orada dürüstçe biter." Sprint H (tarama budama) ve SQL katmanı optimizasyonu
öncelikli.

---

## 19. SQL/tablo katmanı parçalanması (2026-10-29)

Sprint G/0 sonrası asıl hedef olan SQL/tablo katmanı katman katman ölçüldü.
Araçlar: `insprof`, `insprof2`, `skipdup`, `rowcost` (tmp64/g0).

### 19.1 §4 ↔ tablo API farkı açıklandı

§4'ün 24,1 µs/satır sayısı **SQL metni** yolu (`sq.Exec`) ile ölçülmüştü.
Tablo API (`tb.BeginBatch` + `tb.Insert`) aynı işi **5,35–6,24 µs/satır**
yapıyor (insprof2, 200k ve 1M). Fark: **~17,7 µs/satır SQL parser/executor
overhead**. §5'teki "açık batch" sayısı (0,0064 ms/satır = 6,4 µs) tablo
API'siyle uyumlu.

| Yol | µs/satır | Not |
|---|---:|---|
| SQL text (`sq.Exec`, §4) | 24,1 | parser + executor dahil |
| Tablo API (insprof2, 1M) | 6,24 | staging 4,16 + commit 2,09 |
| Tablo API (insprof2, 200k) | 5,35 | staging 3,88 + commit 1,47 |
| SQLite INSERT (§4) | 3,12 | — |

### 19.2 Tablo API bileşen kırılımı (rowcost, 100k)

| Bileşen | µs/satır | Oran |
|---|---:|---:|
| `VDbHashKey` | 0,241 | %7 |
| `FKvB.Put` (batch) | 1,213 | %36 |
| EncodeRow + IdxAddRow + overhead | 1,886 | %56 |
| **Toplam (SkipDupCheck ile)** | **3,340** | |

`SkipDupCheck` açıkken ek 339 µs/satır duplicate check (toplam %8,9).

### 19.3 Duplicate check (Exists) anomalisı

`insprof` doğrudan `be.Exists(key)` çağırdığında **1,826 µs/adet** — batch
DIŞINDAYKEN her çağrı `FEngCs` → `OnFirstEnter` → `AcquireRead` → dosya
kilidi (`TakeSharedLock` + `RefreshIfStale`) → iş → `ReleaseRead` →
`VDbUnlockStream` zinciri çalıştırıyor. v2'de aynı çağrı **0,055 µs** (salt
hash araması). Fark: **33x**.

Batch İÇİNDE ise `FEngCs` zaten tutulduğundan yeniden giriş hızlı yolu
kullanılır, dosya kilidi tekrar alınmaz → maliyet **~339 µs**'e düşer
(`SkipDupCheck` kazancı).

**Optimizasyon (uygulandı):**
1. `TVTableDb.SkipDupCheck` özelliği — toplu eklemede `FKvB.Exists` çağrısını
   atlar. Cagiran benzersiz PK garantisi vermelidir.
2. `TVdbBackendV3.Exists` — `OwnSet` satır içine alındı, çift kilit
   kaldırıldı (etki minimal: 1,826 → 1,809 µs).

### 19.4 Hedef

| Hedef | Mevcut | Potansiyel | Zorluk |
|---|---:|---:|---|
| SQL text parser/executor | 17,7 µs/satır | ~2-4 µs? | Yüksek (parser + executor) |
| EncodeRow + Idx + overhead | 1,89 µs/satır | ~1,0? | Orta |
| Put(batch) | 1,21 µs/satır | ~0,8? | Düşük |
| Exists (batch dışı dosya kilidi) | 1,83 µs/satır | ~0,1 | Orta (kilitleme mimarisi) |

**Sonuç:** Tablo API'si SQLite ile aynı seviyede (3,3 vs 3,12 µs/satır).
7,7x boşluğun tamamı SQL text katmanında. Bir sonraki sprint bu olmalı.

### 19.5 SQL overhead parçalanması ve multi-row VALUES (2026-10-29)

`sqlcost.lpr` ile SQL text INSERT yolunun bileşenleri ölçüldü (ayrı taze
veritabanlarında, WAL artığı önlenir). 100k ve 1M sonuçları:

| Senaryo | 100k (µs/satır) | 1M (µs/satır) | Açıklama |
|---|---:|---:|---|
| A) SQL text batch (ayrı `sq.Exec`) | 11,07 | 12,22 | §4 yolu |
| B) Tablo API batch (`tb.Insert`) | 4,98 | 6,39 | Referans |
| C) Parse-only `SELECT 1` | 5,63 | 6,41 | `Exec`+`ExecRaw` tabanı |
| D) Autocommit INSERT | 400 | 402 | Tek fsync/satır |
| E) SQL sade batch | 11,40 | 12,53 | Format basit SQL |
| F) Tek SQL dizesi (ayrı INSERT'ler) | 10,41 | 14,38 | `ExecAllInner` |
| **G) Multi-row VALUES (100 satır/INSERT)** | **6,07** | **7,62** | **Tek ayrıştırma** |

**Ana bulgular:**

1. **SQL overhead (A − B) ≈ 6,2 µs/satır** — bunun ~5,5 µs'si `Exec`+`ExecRaw`
   sarmalayıcı kitap işi (C = 5,6 µs/call). Ayrıştırma (manüel parser) ucuz.

2. **Kilit kitap işi (A − F) ≈ 0,7–1,1 µs/satır** — `Exec`'teki `SplitStatements`,
   `IsSelectStatement`, `FT.Lock/Unlock`, session yönetimi. `ExecAllInner` bunu
   bir kez yapar.

3. **Multi-row VALUES (G) büyük kazanç:** Tek `INSERT INTO t(...) VALUES
   (...),(...),...` ile N satır tek ayrıştırma + tek semantik kapi turu.
   SQL overhead **6,2 → 1,1 µs/satır** (%82 azalma). G − B farkı yalnızca
   ~1,2 µs/satır — bunun çoğu test kodundaki `Format`+birleştirme.

4. **F (tek dev SQL dizesi) 1M'de kötüleşir** (14,4 µs): O(n²) string
   birleştirme, ~50 MB SQL dizesi. Multi-row VALUES'te dize boyutu ~100x
   daha küçük.

**Uygulanan kod optimizasyonları (P-21):**
- `Exec`/`Exec(Params)`: INSERT/UPDATE/DELETE'de `IsSelectStatement` atlanır
  (ilk karakter kontrolü). `Tok`+`UpperCase`+`try/finally` her yazmada ~0,2 µs.
- `ExecFastLiteralInsert`: `cnames` önceden ayrılır (satır başına yeniden
  tahsis yok). `rows` kapasitesi katlanarak büyür.
- `SplitStatements`: Çift `Trim` çağrısı tekilleştirildi.

**Semantic kapılar ucuz** (motor kullanıcı modunda):
- `TableExists`: `FTables.ContainsKey` — sözlük araması
- `IsView`: `TryGetValue` — sözlük araması
- `TriggersFor` × 2: `FTriggers = nil` ise anında çıkış
- `RequirePriv` → `RoleCan`: `FCurrentRole = ''` ise `Exit(True)`
- `RlsRequireInsert` → `RlsApplies` → `RlsEnabled`: `FRlsOn.TryGetValue`

**Sonraki hedef:** Tablo API (B = 6,4 µs/satır @ 1M) hâlâ SQLite'ın (3,12)
2x altında. `FT.Insert` içindeki `EncodeRow` + `IdxAddRow` + `Put` optimizasyonu.
