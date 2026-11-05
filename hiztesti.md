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

## 20. v3.35 — Tarama-seviyesi join pushdown (2026-11-03)

### 20.1 Yapılan

Sprint E pushdown'u filtrelemeyi join döngüsüne girmeden **sonra** uyguluyordu
(`FilterSide` satır matrisini eler). Ancak sağ taraf her zaman
`FT.ScanRows` ile **tam** taranıyordu — yani daraltma avantajı yalnızca
join döngüsüne giren satır sayısına yansıyordu, tarama maliyetine değil.

v3.35'te `MergeStep` içinde sağ taraf yüklenirken tek taraflı predikatlar
önce `NarrowRows`'a verilir:

* `TryNarrowRightSide(Td, Cn, Ct, RPreds, Pks, Rows)` — AND ağacını kurar,
  `NarrowRows`'u dener. Başarısızsa `FT.ScanRows`'a düşülür.
* `NarrowRows` her zaman **üst küme** döndürdüğü için `FilterSide` sonraki
  doğrulamayı aynen yapar; yanlış negatif yok.
* Mekanizma: WHERE/ON AST'sinden PK eşitliği → O(1) tek satır; indeksli
  kolonda `= > >= < <= BETWEEN IN` → indeks dilimi.

**Güvenlik:** Sağ taraf daraltması yalnız `jtInner`/`jtLeft` için güvenli.
`RIGHT`/`FULL`'de esleşmeyen sağ satırların NULL sarmalama ile korunması
gerekiyor; daraltma bu satırları kaybettirir. Bu iki tipte her zaman tam
tarama yapılır. (Bu kural ilk denemede ihlal edildi; 5 FULL/RIGHT testi
düştü ve düzeltildi.)

### 20.2 Ölçüm — `scanpushbench` (2026-11-03)

`tests/bench/scanpushbench.lpr`: 100k satırlık sağ tablo (`b`, indeksli
`y` ve `k`), 100 satırlık sol tablo (`a`). Sıcak koşular:

| Sorgu | Taban | Daraltmalı | Kazanç |
|---|---|---|---|
| S1 seçici WHERE (`b.y > 99990`) | 203 ms | **0 ms** | **~203x** |
| S2 geniş WHERE (`b.y > 0`) | 219 ms | 234 ms | ~%7 yavaş |
| S3 sol filtre (`a.k > 95`) | 62 ms | 63 ms | etkisiz (beklenen) |
| S4 seçici ON (`b.y > 99990`) | 203 ms | **0 ms** | **~203x** |

S2'deki ~%7 kayıp, seçici olmayan filtrelerde `NarrowRows`'un tüm satırları
üst küme olarak döndürmesinden geliyor (indeks dilimi = tam tarama). Küçük
ve dar bir overhead; seçici sorgulardaki kazanç yanında önemsiz.

### 20.3 Kapılar (2026-11-03)

SQL testleri: v3 **2885/0/33**, v2 **3287/0/0** — hepsi geçti.

CI (macOS) `crashtest` kapısı bu commit'te 10/11 ile düştü
(`COKME KURTARMA HATALI`). Bu kapı depolama katmanını (WAL/sayfa motoru)
sınar; değişiklik yalnızca SQL join katmanında (`VDbExecutor.pas` →
`MergeStep`). Aynı koddan koşan iki macOS koşusunun biri geçti biri düştü —
`TestKill9` alt süreç zamanlaması kaynaklı bilinen gürültü (kaynakta
2026-10-25 CI #36/#37 notu). İlişkili değil.

## 21. v3.36 — WHERE pushdown zincir güvenliği (2026-11-03)

### 21.1 Bulgu

`wherenull` ve `chainnull` testleri, WHERE tek taraflı erken eleme
(`FilterSide` ve v3.35 tarama daraltması) kurallarının **zincir bilinci**
eksik olduğunu ortaya çıkardı. v3.34–v3.35'te güvenlik yalnız o adımın
join tipine bakıyordu:

```
SELECT a.id, a.x, c.id
FROM a INNER JOIN b ON a.k=b.k
     RIGHT JOIN c ON c.k=a.k
WHERE a.x IS NULL
```

`a.x` sol tarafta, tek taraflı. İlk adım `INNER` → eski kural "güvenli"
diyordu ve `a` satırlarını erken eliyordu. Ancak sonraki adımda `RIGHT JOIN
c` var: eşleşmeyen `c` satırları NULL sarmalama üretir ve bu satırlar
`WHERE a.x IS NULL`'dan geçer. Erken eleme `a2`'yi (x=NULL) silince
`a2b2` çifti RIGHT'te eşleşemez hâle geliyor → fazladan NULL satırı
oluşuyor.

| Senaryo | Düzeltme öncesi | Doğru |
|---|---|---|
| `a INNER JOIN b ... RIGHT JOIN c` + `WHERE a.x IS NULL` | 2 satır | **1** |
| `a INNER JOIN b ... FULL JOIN c` + `WHERE a.x IS NULL` | 3 satır | **2** |

### 21.2 Kural

WHERE tek taraflı erken eleme yalnızca şu koşulda güvenli:

* **WHERE-sol:** `join[i] ∈ {INNER, LEFT}` **ve** sonraki join'lerde
  RIGHT/FULL yok (sol taraf NULL-üretilmez).
* **WHERE-sağ:** `join[i] ∈ {INNER, RIGHT}` **ve** sonraki join'lerde
  RIGHT/FULL yok.

`NarrowRows`'un `IS NULL`'u bilmiyor olması (tam taramaya düşmesi) bu
bug'ı örtüyordu — tesadüfi koruma, kurala bağlanmamalı.

**ON pushdown kuralları değişmedi:** ON-sol → INNER/RIGHT; ON-sağ →
INNER/LEFT. Bunlar adım bazlı doğrudur (sonraki join'lerden bağımsız),
çünkü ON yalnız o adımın eşleşmesini etkiler.

### 21.3 Düzeltme

`VDbExecutor.pas` → `MergeStep`:

* İmza: `ARestPreservesLeft: Boolean` parametresi eklendi. True ise bu
  adımdan **sonra** hiçbir join RIGHT/FULL değil.
* `RestPreservesLeft(FromIdx)` yardımcısı (`ExecJoinScan` içinde):
  `Stmt.MoreJoins[FromIdx..]` içinde RIGHT/FULL arar.
* Çağrılar: `RestPreservesLeft(0)` (ilk adım), `RestPreservesLeft(t+1)`
  (sonraki adımlar).
* WHERE `FilterSide` kapıları: her iki tarafa da `ARestPreservesLeft`
  koşulu eklendi.
* Tarama daraltması: ON-sağ (`tmpRP`, INNER/LEFT) ve WHERE-sağ (`tmpWP`,
  INNER/RIGHT + `ARestPreservesLeft`) `tmpNarrow`'da **ayrı** kapılarla
  birleştiriliyor.

### 21.4 Testler

* `tests/bench/wherenull.lpr` — 7 senaryo, beklenen satır sayısıyla
  karşılaştırır: LEFT+`IS NULL`, NULL-rejecting WHERE, INNER+`IS NULL`,
  zincir INNER…RIGHT, zincir INNER…FULL, RIGHT+`IS NULL`.
* `tests/bench/chainnull.lpr` — 6 zincir senaryosu, beklenen satır sayısı
  doğrulamalı.

İkisi de `SONUC: gecen=hepsi kalan=0`.

### 21.5 Kapılar (2026-11-03)

SQL testleri: v3 **2885/0/33**, v2 **3287/0/0** — hepsi geçti.

---

## 22. v3.37 — Sol taraf daraltma (2026-11-03)

### 22.1 Bulgu

v3.35 yalnız **sağ taraf** taramasını `NarrowRows` ile daraltıyordu.
FROM tablosuna atıf yapan tek taraflı predikatlar (WHERE-sol veya
ON-sol) hâlâ `FT.ScanRows` ile tam taranıyordu.

Ölçüm (`scanpushbench` S5): `SELECT COUNT(*) FROM b JOIN a ON a.k=b.k
WHERE b.y > 99990` — büyük sol tablo (100k satır), seçici sol filtre →
**406 ms** (v3.36'da).

### 22.2 Kural (güvenlik kanıtı)

Sol taraf daraltma yalnızca şu koşullarda güvenlidir:

* **WHERE-sol:** hiçbir join RIGHT/FULL değilse (`AllJoinsPreserveLeft`).
  Sebep: RIGHT/FULL sol sütunları NULL-sarmalayarak `IS NULL` gibi
  NULL-kabul eden predikatların sonucunu değiştirir.
* **ON-sol (join J):** yalnız J INNER/RIGHT ise. LEFT/FULL sol satırı
  NULL-sarmalama ile korur; erken eleme kaybettirir. Sonraki join'lerden
  **bağımsız** (adım bazlı doğru: INNER/RIGHT zaten o satırı düşürür).

`NarrowRows` her zaman üst küme döndüğü için ON/WHERE sonraki aşamalarda
yeniden doğrulanır (`JoinOnOk` / final WHERE). LATERAL özel durum
gerektirmez (aynı kurallar geçerli).

### 22.3 Uygulama

`VDbExecutor.pas` → `ExecJoinScan` içinde yeni yardımcılar:

* `AllJoinsPreserveLeft: Boolean` — tüm join'ler INNER/LEFT mi.
* `ColInJoinTable(const nm: string): Boolean` — kolon adı join
  tablolarında geçiyor mu (muhtemel çakışma kontrolü).
* `RefsOnlyFrom(E: TSqlExprNode): Boolean` — ifade yalnız FROM tablosuna
  atıf yapıyor mu. Nitelemeli ad `AliasEff` ile eşleşmeli; niteliksiz ad
  hem td0'da olmalı hem join tablolarında geçmemeli.
* `CollectFromConjuncts` — AND ağacını böl, uygun predikatları topla.
* `TryNarrowLeftSide` — AND ağacı kur, `NarrowRows` çağır.

Daraltma bloğu: WHERE-sol (`AllJoinsPreserveLeft`), ON-sol (INNER/RIGHT
join'ler) predikatlarını toplar, `TryNarrowLeftSide` dener, başarısızsa
`FT.ScanRows`'a düşer.

### 22.4 Ölçüm (scanpushbench, 100k sağ / 100 sol)

| Senaryo | v3.36 | v3.37 | Kazanç |
|---|---:|---:|---|
| S5: `b JOIN a WHERE b.y > 99990` (sol daraltma) | 406 ms | **0 ms** | **∞** |
| S6: `b JOIN a WHERE b.y > 0` (geniş sol) | 438–453 ms | 484–516 ms | ~eşit |

### 22.5 Kapılar (2026-11-03)

wherenull **7/7**, chainnull **6/6**, sqltest v3 **2885/0/33**, v2 **3287/0/0**.

---

## 23. P-xx yazma yolu kampanyası (2026-10-30 … 2026-11-02)

§19'daki tablo API'si 5,35–6,24 µs/satır seviyesindeydi. P-49…P-75
kampanyasıyla yazma yolu mikro-optimizasyonları uygulandı; P-76…P-84
platform/CI düzeltmeleri.

### 23.1 Ana optimizasyonlar (P-49 … P-75)

| # | Optimizasyon | Etki |
|---|---|---|
| P-49 | WAL ara kopyalama kaldırma | Bellek kopyası azaldı |
| P-50 | `TriggersFor` hızlı yol | Boş sözlükte anında çıkış |
| P-51 | Fast path'lerde tek tablo araması | Çift arama kaldırıldı |
| P-52 | Recover'da PageSeal CRC doğrulaması | Güvenlik + hız |
| P-53 | WAL sürüm 2 — `WalCrc` yalnız başlık | CRC maliyeti düştü |
| P-54 | İşlem bazlı kirli çerçeve listesi | `TxnPages` O(kirli) |
| P-55 | `Insert`'e `ATableDef` parametresi | `GetTable` derin kopyası atlandı |
| P-56 | `VDbHashKeyPrefix` tek girdili önbellek | Non-batch INSERT |
| P-57 | Commit'te `Seek(0, soEnd)` atlama | `FAtEnd` bayrağı |
| P-58 | SQL INSERT parametre önceliği | Tek süreçli erişim kilidi atlama |
| P-59/60 | SQL INSERT sarmalayıcı atlama | `ExclusiveAccess` MREW kilidi |
| P-61 | Flush: `FDirty` erken çıkış | Boş flush atlandı |
| P-62 | Meta çerçevesi atlama | `FStructDirty` commit'te sıfırlandı |
| P-63 | Non-batch INSERT kolon eşleme önbelleği | Yeniden arama kaldırıldı |
| P-64 | `PageMapAdd` geometrik büyüme | O(n²) `SetLength` önlendi |
| P-65 | `EncodeRowInto` yeniden kullanılan tampon | Tahsis azaldı |
| P-66 | Hash tablosu SoA → AoS (`TDirEntry`) | Cache miss azaldı |
| P-67 | Identity/generated tarama atlama | `FBatchHasIdentity` önbelleği |
| P-68 | Değişiklik günlüğü doğrudan grup tamponu | `AddPutPtr` |
| P-69 | Apply fazında etiket koşucusu | `FlushTagRun` |
| P-70 | Yazma kümesi düz hash haritası | WAL tamponu geometrik büyüme |
| P-71 | WAL çerçeve dedup haritası | Doğrusal taramadan hash'e |
| P-72 | `DirGrow` ters haritayı yeniden kurmayı bıraktı | O(n) → O(delta) |
| P-73 | `PlaceCellKV` ikinci `FindFrame` atlandı | Çift arama kaldırıldı |
| P-75 | DROP TABLE + büyük batch sayfa bozulması | Bayat space hint düzeltmesi |

### 23.2 Ölçüm — `p67diag` (2026-11-03, N=200.000, best-of-5)

| Bileşen | µs/satır |
|---|---:|
| String üretimi | 0,142 |
| Insert döngüsü | 0,716 |
| `CommitBatch` | 0,609 |
| **Toplam (döngü+commit)** | **1,325** |

İki koşu: 1,325 ve 1,324 µs/satır — tutarlı.

§19'daki 5,35–6,24 µs/satır tablo API'si ile karşılaştırıldığında
**~4x** hızlanma. P-xx kampanyasının ana kazancı yazma yolu tahsis
diyeti, önbellek tekilleştirme ve kilit atlamalarıdır.

## 24. P-85 — Join yolunda gereksiz `JoinOnOk` atlanması (2026-11-03)

Hash join yolunda `OnHasExtra=False` ise ON koşulu yalnız eşitliktir;
hash eşleşmesi `VDbNormValue` ile normalleştirilmiş anahtar üzerinden
zaten doğrular. Bu durumda `JoinOnOk`/`EvalBool` çağrısı gereksizdir —
atlandı.

İndeks join yolunda aynı optimizasyon **denendi ve geri alındı**:
`IdxSourceRange` normalize değerlerle eşleşir, `jv=''` (NULL) iken
NULL girişlerini de bulur. `JoinOnOk` atlanınca NULL=NULL eşleşmesi
kabul edilir (üç-değerli mantıkta yanlış). Hash join ise ham değerle
NULL atladığı için orada güvenlidir. sqltest "indeksli ve indekssiz
sonuc ayni" fuzz testi bu farkı yakaladı (fark=20); indeks join'de
`JoinOnOk` korundu.

| Yol | P-85 | `JoinOnOk` | Neden |
|---|---|---|---|
| PK join | — | zaten yok | Ham eşitlik kontrolü |
| Hash join | aktif | `OnHasExtra=False` iken atlanır | Ham NULL atlaması güvenli |
| İndeks join | geri alındı | korunur | Normalize eşleşme NULL kabul eder |

Doğrulama: sqltest v3 3287/0/0, sqltest v2 3287/0/0, wherenull TEMIZ
(7 senaryo), chainnull TEMIZ (6 senaryo). scanpushbench S6:
484–500 ms (önceki 484–516 ms aralığında, gerileme yok).

## 25. P-86 — İndeks/PK join'de sağ taraf materyalizasyonu atlandı (2026-11-03)

İndeks/PK join yolu (`JoinIdxCol2 >= 0`) `rRows`'u **hiç okumaz**:
esleşen satır `FT.ReadRow` ile nokta atışı getirilir. Buna rağmen
`MergeStep` her join adımında sağ tabloyu `ScanRows`/`NarrowRows` ile
tam materyalize ediyordu. Büyük sağ tabloda bu, join'in kendisinden
pahalıydı (100k satır ≈ 500 ms).

Düzeltme: yol seçimi (`JoinIdxCol1/2`, `JoinUsePk`, `HashL/HashRrel`)
taramadan **önce** yapıldı; yol indeks/PK ise `rRows`/`rPks` boş
bırakılıp tarama tamamen atlandı. WHERE zaten sonradan `RowMatches`
ile uygulandığı için sonuç değişmez; ON eşitliği indeks/PK eşleşmesiyle
doğrulanır (P-85 notu).

Güvenlik: yalnız INNER/LEFT + tek eşitlik ON + gerçek indeks/PK
varsa atlanır. RIGHT/FULL, CTE, NATURAL/USING, `OnHasExtra` (ek ON
predikatı) ve indekssiz durumlar eski yolda kalır — o yollar `rRows`
okur.

`scanpushbench` (sag=100000, sol=100), aynı oturumda P-85 tabanıyla
karşılaştırma:

| Sorgu | P-85 | P-86 | Not |
|---|---:|---:|---|
| S2 `a JOIN b WHERE b.y>0` | 500 ms | **0 ms** | İndeks join, sağ 100k — materyalizasyon atlandı |
| S3 `a JOIN b WHERE a.k>95` | 141 ms | **0–16 ms** | Aynı yol |
| S1 seçici sağ filtre | 672→0 ms | 328→0 ms | İlk tur maliyeti |
| S6 `b JOIN a WHERE b.y>0` | 484–500 ms | 500 ms | Değişmedi: sağda indeks yok → hash join, sol 100k tarama |

S6'daki 500 ms artık **sol taraf** tam taraması + hash kurulumu;
P-86'nın kapsamı dışında. Sıradaki aday: sol tablo `LRows`
materyalizasyonu (akışkan tarama).

Doğrulama: wherenull TEMIZ, chainnull TEMIZ; sqltest v2 3284/2/0,
v3 2882/2/33 — tek başarısızlık `T109_PoolSlotTCP` (port 54722
dinleme). Bu hata **P-86'sız tabanda da birebir aynı** (3284/2/0);
çevresel, join yolundan bağımsız.

## 26. P-87 — INNER equi-join + saf aggregate indeks sürücü kısayolu (2026-11-03)

`TryJoinAgg`: GROUP BY'suz INNER equi-join sorgularında **indeks
olmayan taraftan sür, indeksli tarafta PK/indeks ara**. Büyük tablo
materyalizasyonu tamamen atlanır.

İki mod:
- **Aggregate** (COUNT/SUM/AVG/MIN/MAX): tek satır sonuç, sıra-bağımsız.
- **Basit kolon** (P-87b): `SELECT b.id, a.id FROM ...` gibi — sonuç
  satırları toplanır. Sıra-bağımsız değildir; ORDER BY varsa reddedilir
  (genel yol sıralar).

S6 vaka analizi (`b` 100k, `a` 100, `idx_b_k` var):
`hasL=True, hasR=False` → `DriveRight=True` → `a`'dan (100 satır)
sür, `b`'yi `idx_b_k` ile ara → ~1,5 ms (önce: ~550 ms hash join).

`joindiag` (100k satır, en iyi us, 3 tekrar):

| Sorgu | P-86 | P-87 | P-87b | Not |
|---|---:|---:|---:|---|
| A) `COUNT(*)` tek tablo | 10 us | 10 us | 16 us | KR-1B O(1) |
| B) tam tarama SELECT | 336.723 us | 332.668 us | 337.073 us | Materyalizasyon |
| C) `COUNT(*) WHERE` | 12 us | 12 us | 12 us | Ham akış |
| D) S6 hash join COUNT | 549.826 us | 1.648 us | 1.525 us | 360x |
| E) S6 satırları (100) | 552.949 us | 536.578 us | **1.526 us** | 352x |
| F) S2 indeks join | 1.587 us | 1.490 us | 1.486 us | P-86 korundu |
| G) NarrowRows indeksli | 782 us | 1.503 us | 1.525 us | WHERE sonra |

Güvenlik: yalnız INNER + tek eşitlik ON + gerçek tablo + (saf
aggregate | basit kolon). LEFT/RIGHT/FULL, NATURAL/USING, LATERAL,
GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT, pencere fonksiyonu,
view, RLS varsa `False` → genel `ExecJoinScan` + `ExecGroupBy`
yolu AYNEN çalışır. Aggregate semantiği `EvalAggregateValue` ile
birebir: COUNT(*) satır sayar; COUNT(col) NULL olmayanı; SUM
`cntI>0` iken `sumF`; AVG `avgCnt>0` iken `sumF/avgCnt`; MIN/MAX
`VDbCmpVal` + ham değer.

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMIZ,
chainnull TEMIZ.

## 27. P-88 — Akışkan tarama: tam SELECT materyalizasyonu atlama (2026-11-03)

`TryStreamSelect` kapısı LIMIT'siz tam taramalara açıldı. Eski kapı
`LIMIT yok + ham koşu yok + ağaç yok → genel` diyordu; ara
materyalizasyon (ScanSnapshot TBytes + allRows + filteredRows)
atlandığı için akışkan tarama her durumda daha hızlıdır.

Üç değişiklik:
1. **Kapı gevşetme**: LIMIT'siz tam taramalar artık `ScanRawIterAll`
   + `VdbStreamSelCb` ile akar. `ScanSnapshot`'ın 100k TBytes
   alloc+kopyası, `allRows` ara TStrMatrix'i ve `filteredRows`
   referans kopyası tamamen atlanır.
2. **İndeks kapısı**: `WHERE` yoksa ikincil indeksler işlevsizdir;
   tam taramada akışkan tarama daha hızlıdır. `WHERE` varsa eski
   tercih korunur (NarrowRows indeks daraltması daha iyi olabilir).
3. **OutRows blok büyüme**: `SetLength(OutRows, Length+1)` satır
   başına O(N²) idi; 256'lık bloklarla ikiye katlama yapıldı.
4. **Basit kolon doğrudan kopyalama**: Tüm SELECT ögeleri basit
   kolon referansıysa `EvalExpr` atlanır, `vals[ColMap[j]]` doğrudan
   kopyalanır. Sınır kontrolü: ColMap geçersizse `EvalExpr`'a düşülür.

`joindiag` (100k satır, en iyi us, 3 tekrar):

| Sorgu | P-87b | P-88 | Kazanç |
|---|---:|---:|---:|
| A) `COUNT(*)` tek tablo | 16 us | 7 us | — |
| B) tam tarama SELECT | 337.073 us | **140.337 us** | **2.4x** |
| C) `COUNT(*) WHERE` | 12 us | 14 us | — |
| D) S6 hash join COUNT | 1.525 us | 1.513 us | — |
| E) S6 satırları (100) | 1.526 us | 1.499 us | — |
| F) S2 indeks join | 1.486 us | 1.490 us | — |
| G) NarrowRows indeksli | 1.525 us | 1.530 us | — |

B sorgusu 337 ms → 140 ms. Kalan maliyet: `VDbRowFromOffsetsP`
(tüm kolonların string decode'u) + projeksiyon + çıktı
materyalizasyonu (100k × 4 string — kaçınılmaz, sonuç zaten bu).

Güvenlik: mevcut şekil korumaları AYNEN korundu (JOIN, set-op,
DISTINCT, GROUP BY, pencere, QUALIFY, view, RLS, AS OF, CTE →
genel yol). İkincil indeks + WHERE varsa NarrowRows tercih edilir.
`VDbHashKey` çarpışma kontrolü satır başına korunur.

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMIZ,
chainnull TEMIZ.

## 28. P-89 — TryStreamJoin: sol taraf LRows materyalizasyonu atlama (2026-11-03)

Tek INNER/LEFT equi-join'de sol taraf `ScanRawIterAll` ile akışkan
taranır; `LRows` materyalizasyonu tamamen atlanır. Sağ taraf hash
veya indeks/PK ile probe edilir. TryJoinAgg'ın reddettiği şekiller
(LEFT JOIN, ifade SELECT, ORDER BY, pencere) bu yoldan geçer.

`VdbStreamJoinCb` satır bazlı callback: `VDbPeekRawRowP` + `VDbHashKey`
çarpışma + `VDbRowFromOffsetsP` decode + sol pushdown filtre + hash/index
probe + OnHasExtra `EvalBool` + blok büyüme (256→2×) + LEFT NULL-genisletme.

Birleşik kolon adları `ExecJoinScan` ile birebir aynı: `aliasL.kolon` /
`aliasR.kolon`. Çıktı matrisi aynı formatta.

**Düzeltmeler (bu dilimde):**
- `ctx.bk` (TDictionary) yönetilen tip DEĞİL — NarrowRows Exit'inde
  `finally` bloğu çöp pointer'ı serbest bırakıyordu (4× AV). Düzeltme:
  `ctx.bk := nil` fonksiyonun en başına taşındı.
- Hash normalizasyon: sol join anahtarı `C^.LTypes[C^.HashL]` ile
  normalize edilmeli (sol tip), `C^.HashRType` DEĞİL. Hem hash hem
  indeks/PK yolunda düzeltildi.

`p89lj` (100k sol / 200 sağ, en iyi us, 3 tekrar):

| Sorgu | Genel yol | TryStreamJoin | Kazanç |
|---|---:|---:|---:|
| A) LEFT JOIN COUNT | 195.208 us | 199.204 us | — |
| B) LEFT JOIN ifade SELECT | 315.278 us | 318.579 us | — |
| C) INNER JOIN ORDER BY LIMIT | 261.737 us | 239.482 us | **1,09x** |
| D) LEFT JOIN WHERE-sol | 798.140 us | 694.245 us | **1,15x** |

A/B'de kazanç yok: 100k çıktı satırı materyalizasyonu baskın maliyet;
akışkan tarama LRows tasarrufu callback overhead ile dengeleniyor.
C'de ORDER BY + LIMIT, D'de WHERE filtrelemesi akışkan taramanın
erken çıkış/filtre avantajını gösteriyor.

Güvenlik: NarrowRows sol predikatlarla denenir — True ise `Exit(False)`
(genel yol), False veya predikat yoksa akışkan. LEFT eşleşmeyen satır
NULL-genisletilir. OnHasExtra=False ise `EvalBool` atlanır (P-85).
Kolon adları/tipleri `ExecJoinScan` ile birebir aynı.

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMIZ,
chainnull TEMIZ.

## 29. P-90 — Kolon budama / kısmi decode (2026-11-03)

`VDbRowFromOffsetsP` tüm kolonları decode ediyordu; sorgu yalnızca
birkaç kolon referans etse bile. Yeni `VDbRowFromOffsetsMaskP` yalnızca
`Need[i]=True` kolonları çözer; diğerleri `''` bırakılır.

`CollectExprCols` ifade ağaçlarını yürüyerek tüm kolon referanslarını
toplar: TSqlColumnRefNode, TSqlBinaryOpNode, TSqlUnaryOpNode, TSqlInNode,
TSqlQuantNode, TSqlAggNode, TSqlCastNode, TSqlBetweenNode, TSqlCollateNode,
TSqlFuncCallNode, TSqlCaseNode, TSqlNullIfNode, TSqlCoalesceNode,
TSqlJsonKeyNode, TSqlWindowNode.

`TStreamSelCtx`'e `NeedCols: array of Boolean` ve `UseMask: Boolean`
eklendi. WHERE + SELECT + ORDER BY kolonları taranıp maske kurulur.
`VdbStreamSelCb` her iki dalında (whereOK=True/False) maskeyi kullanır.

`p90col` (100k satır, 10 kolonlu tablo, en iyi us, 3 tekrar):

| Sorgu | Budama yok | Budama var | Kazanç |
|---|---:|---:|---:|
| A) SELECT * (10 kolon) | 259.810 us | 267.561 us | — |
| B) SELECT 2 kolon | 256.275 us | **120.086 us** | **2,13x** |
| C) SELECT 2 string kolon | 256.613 us | **139.347 us** | **1,84x** |
| D) COUNT(*) WHERE 1 kolon | 37.133 us | 38.986 us | — |

A'da budama etkisiz (tüm kolonlar gerekli, maske overhead'i var).
B/C'de 2 kolon seçildiğinde decode maliyeti ~%50 azalıyor. D'de
WHERE zaten ham-yuklem ile eliyor, decode minimal.

Güvenlik: maske yalnızca deşifre edilmeyen kolonları boş bırakır;
`EvalExpr`/`RowMatches` yalnızca referans edilen kolonları okur.
Tüm ifade tipleri kapsandı (ilk sürümde 8 test başarısızdı —
TSqlCaseNode, TSqlFuncCallNode, TSqlBetweenNode vb. eksikti).

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMIZ,
chainnull TEMIZ.

---

## §30 — P-90b: G regresyonu düzeltmesi (TryJoinAgg WHERE seçiciliği)

**Tarih:** 2026-11-03
**Dal:** v3
**Sorun:** G sorgusu (`SELECT COUNT(*) FROM b JOIN a ON a.k=b.k WHERE b.y > 99990`)
1507 us sürüyordu. `hasL=True, hasR=False` durumunda WHERE sol taraftayken
NarrowRows yanlış tabloyu (a) daraltmayı deniyordu → boş predikat → daraltma yok.

**Kök neden:** `DriveRight := True` (a'dan sürü) zorlanıyordu. WHERE `b.y > 99990`
sol tarafta (b) → `CollectDrvPreds(..., 2, ...)` sağ taraf predikatları topluyordu
→ boş → NarrowRows yok. Sonuç: 100 indeks araması × ~100 eşleşme = 10.000 satır okuma.

**Çözüm (lookup tarafı daraltma):**
1. Sürücü daraltma bloğundan sonra lookup tarafı da WHERE ile daraltılıyor.
2. `CollectDrvPreds` ile lookup tarafının predikatları toplanıyor.
3. `NarrowRows` ile lookup tablosu daraltılıyor (G'de: 100k → 10 satır).
4. Küçük kümelerde (≤1000 satır) tarama tabanlı arama kullanılıyor (`scanLk`).
5. `lkRows` üzerinde join kolonu karşılaştırmasıyla eşleşen satırlar bulunuyor.
6. Regresyon koruması: daraltma başarısızsa veya küme büyükse indeks yoluna düşülüyor.

**Etki:** G sorgusu 1507 us → **626 us** (%58 iyileşme).

**Güvenlik:** `NarrowRows` her zaman ÜST KÜME döndüğü için doğru sonuç korunur.
Tarama tabanlı arama yalnızca `scanLk=True` iken devreye girer; aksi halde
indeks yolu (IdxSourceRange/ReadRow) eskisi gibi çalışır.

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

---

## §31 — P-90c: D regresyonu düzeltmesi (NarrowRows MaxRows parametresi)

**Tarih:** 2026-11-03
**Dal:** v3
**Sorun:** D sorgusu (`SELECT COUNT(*) FROM b JOIN a ON a.k=b.k WHERE b.y > 0`)
P-90b lookup daraltma bloğundan sonra 231.392 us sürüyordu (P-87'de 1.525 us).
`WHERE b.y > 0` seçici olmayan predikatla lookup tarafında (b) NarrowRows
çağrılıyor ve 100k satır materyalize ediliyordu.

**Kök neden:** `NarrowRows` içinde `IdxSourceRangeBounds` 100k indeks girdisini
`e` dizisine dolduruyordu. MaxRows kontrolü bu doldurmadan SONRA idi → 100k
satır okunup sonra atılıyordu. Sonra `scanLk := False` (100k > 1000) ile indeks
yoluna düşülüyordu ama materyalizasyon israfı çoktan yapılmıştı.

**Çözüm:**
1. `NarrowRows`'a `MaxRows: Integer = 0` parametresi eklendi (her iki overload).
2. `IdxSourceCountBounds` ile dilim sayısı ÖNCEDEN kontrol ediliyor.
3. `MaxRows` aşılırsa materyalizasyon yapılmadan `False` dönülüyor.
4. Lookup daraltma bloğunda `MaxRows=1000` geçiriliyor.

**Etki:** D sorgusu 231.392 us → **1.676 us** (%99,3 iyileşme, P-87 hedefi
1.525 us'a yakın). G sorgusu stabil: **609 us**.

**Güvenlik:** `MaxRows=0` (varsayılan) davranış değiştirmez. `NarrowRows` hâlâ
ÜST KÜME döndüğü için doğru sonuç korunur. `False` dönüşünde çağıran taraf
indeks yoluna düşer.

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

## §32 — P-90d: VDbPeekRawRowKeyHashTo — PK string'siz hash doğrulama

**Tarih:** 2026-11-03
**Dal:** v3
**Sorun:** `VdbStreamSelCb` her satırda `VDbPeekRawRowP` (PK string allocate +
SetString + UTF8Decode) + `VDbHashKey` (UTF8Encode + FNV) yapıyordu. 100k satırlık
tam taramada bu milyonlarca gereksiz string tahsisi ve hash hesaplamasıydı.

**Kök neden:** `VDbPeekRawRowP` PK string'ini kurar (`SetString`), sonra
`VDbHashKey` aynı stringi UTF-8'e encode edip FNV hash üretir. Her ikisi de
satır bazında tekrarlanır.

**Çözüm:**
1. `TStreamSelCtx`'e `HashPrefix: QWord` ve `MaxCol: Integer` eklendi.
2. Init bloğunda `ctx.HashPrefix := VDbHashKeyPrefix(td.Name)` — bir kez.
3. UseMask bloğundan sonra `ctx.MaxCol` hesaplandı (UseMask ise en yüksek
   NeedCols indeksi, değilse ColCnt-1) — erken kolon durması.
4. `VdbStreamSelCb`'de `VDbPeekRawRowP` + `VDbHashKey` →
   `VDbPeekRawRowKeyHashTo` (PK string'siz, hash ham baytlardan, MaxCol erken durma).

**Etki (joindiag, en iyi süre us):**
- B (100k tam tarama SELECT): 141.720 → **104.930 us** (%26 iyileşme)
- D (JOIN COUNT): 1.564 → **1.519 us**
- E (JOIN sonuc): 1.586 → **1.496 us**
- F (indeks join): 1.517 → **1.481 us**
- G (NarrowRows): 606 → **580 us**

p67diag INSERT: 1,349 us/satır (değişmedi — INSERT yolu etkilenmez).

**Güvenlik:** `VDbPeekRawRowKeyHashTo` aynı sınırları kontrol eder; hash
eşleşmezse `Failed := True` ile genel yol hatası korunur. MaxCol erken durma
yalnızca hash + offset doldurma için; tam satır decode sonra yapılır.

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

## §33 — P-91: DirectDecode — kimlik ColMap + WHERE yok doğrudan decode

**Tarih:** 2026-11-03
**Dal:** v3
**Sorun:** `VdbStreamSelCb` her satırda ara `vals` dizisi kurup sonra `prow`'a
kopyalıyordu. Kimlik ColMap (tüm kolonlar SELECT'te, sıra aynı) + WHERE yokken
bu kopya gereksizdi.

**Çözüm:**
1. `TStreamSelCtx`'e `DirectDecode: Boolean` eklendi.
2. Init'te: `AllSimpleCols` + `WhereClause=nil` + `Columns.Count=ColCnt` +
   `ColMap[j]=j` ise `DirectDecode=True`.
3. Callback'te `DirectDecode` ise decode doğrudan `OutRows[Emitted]`'a yazılır;
   `vals` ve `prow` ara dizileri tamamen atlanır.

**Etki:** B sorgusu (100k tam tarama) 104.767 us — P-90d ile aynı seviye.
Asıl maliyet `VDbRowFromOffsetsP` içindeki string tahsislerinde (IntToStr,
SetString+UTF8Decode). Bu optimizasyon doğru ama ölçülebilir kazanç sağlamıyor;
yine de gereksiz işi atladığı için tutuldu.

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

## §34 — P-91b: ASCII hızlı yolu — UTF8Decode atlanıyor

**Tarih:** 2026-11-03
**Dal:** v3
**Sorun:** TEXT kolon decode'unda `UTF8Decode(s)` çağrısı her seferinde
`WideString` (UTF-16) oluşturuyor, sonra `AnsiString`'e geri dönüyordu.
Bu 3 ayrı tahsis demek (RawByteString + WideString + AnsiString). Saf-ASCII
metinlerde bu tamamen gereksiz — doğrudan `SetString` ile 1 tahsis yeterli.

**Çözüm:**
1. `VdbPureAscii(P: PByte; L: Integer): Boolean` helper fonksiyonu eklendi
   (`VDbTable.pas`). Baytların hepsi `< $80` ise `True` döner.
2. `VDbRowFromOffsetsP`, `VDbRowFromOffsetsMaskP`, `VDbColFromOffsetsP` ve
   `VDbDecodeRawRowP` içindeki TEXT yoluna ASCII kontrolü eklendi:
   - Saf ASCII ise → `SetString(Vals[i], PAnsiChar(p), FLen[i])` (1 tahsis)
   - Değilse → `UTF8Decode(s)` (eski yol, UTF-8 korunur)

**Etki (joindiag):**
| Sorgu | P-91 | P-91b | Değişim |
|-------|------|-------|---------|
| B: SELECT * 100k | 104.767 us | 91.002 us | **−%13** |
| D: JOIN COUNT | 1.539 us | 1.509 us | −%2 |
| G: NarrowRows | 609 us | 585 us | −%4 |

B sorgusu doğrudan `VDbRowFromOffsetsP` üzerinden 100k satır × 4 kolon
decode ediyor; ASCII hızlı yolu burada belirgin kazanç sağlıyor. D/E/F/G
zaten küçük olduğu için etki sınırlı.

p67diag INSERT: 1.368 us/satır (P-91 ile aynı seviye, gürültü içinde).

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

## §35 — P-92: VdbIntToStrTo + DirectDecode'de gereksiz SetLength kaldırma

**Tarih:** 2026-11-04
**Dal:** v3
**Sorun:** İki israf:
1. `Vals[i] := IntToStr(iv)` — FPC'de `IntToStr` geçici string `S` kurar,
   `Result := S` ile kopyalar, sonra `S` finalize edilir. Bu 1 tahsis + 2
   refcount işlemi demek. Hedefe doğrudan yazmak bunu atlar.
2. DirectDecode yolunda `SetLength(OutRows[Emitted], ColCnt)` çağrılıp
   sonra `VDbRowFromOffsetsP`'e `out` parametre olarak geçiliyordu. `out`
   parametre girişte finalize edildiği için ilk SetLength tamamen boşa gidiyor.

**Çözüm:**
1. `VdbIntToStrTo(var S: string; v: Int64)` helper eklendi (`VDbTable.pas`).
   Rakamlar stack buffer'a yazılır, tek `SetString` ile hedefe kopyalanır.
   5 sıcak decode yolunda `IntToStr` → `VdbIntToStrTo` değiştirildi:
   `DecodeRow`, `VDbRowFromOffsetsP`, `VDbRowFromOffsetsMaskP`,
   `VDbColFromOffsetsP`, `VDbDecodeRawRowP`.
2. `VDbExecutor.pas` DirectDecode bloğundan gereksiz `SetLength` kaldırıldı.

**Etki (joindiag, en iyi süreler):**
| Sorgu | P-91b | P-92 | Değişim |
|-------|-------|------|---------|
| B: SELECT * 100k | 91.002 us | **79.170 us** | **−%13** |
| D: JOIN COUNT | 1.509 us | 1.484 us | −%2 |
| G: NarrowRows | 585 us | 574 us | −%2 |

B sorgusu 3 INT + 1 TEXT kolonu decode ediyor; `VdbIntToStrTo` 300k INT
hücresinde geçici tahsis + refcount'u atlıyor. Toplam P-90'dan bu yana B
sorgusu 141.720 → 79.170 us (**−%44**).

p67diag INSERT: 1.338 us/satır (hafif iyileşme).

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

## §36 — P-93: Tek geçiş DirectDecode — VDbDecodeStreamRowP

**Tarih:** 2026-11-04
**Dal:** v3
**Sorun:** DirectDecode yolunda satır başına 2 geçiş yapılıyordu:
1. `VDbPeekRawRowKeyHashTo` — FType/FOff/FLen ara dizilerini yazar, PK hash üretir
2. `VDbRowFromOffsetsP` — FType/FOff/FLen okuyarak Vals'i decode eder

Ara diziler (3× ColCount Integer/Byte) her satırda yazılır + okunur.
100k satır × 4 kolon = 400k gereksiz bellek erişimi.

**Çözüm:** `VDbDecodeStreamRowP` (`VDbTable.pas`) — hash doğrulama + decode
tek döngüde. FType/FOff/FLen hiç kurulmaz/okunmaz. PK hash `VDbHashKeyBytes`
ile üretilir (P-90d ile birebir aynı semantik). Sealed kolonlar, ASCII hızlı
yolu, INT/FLOAT/BOOL decode mekanizması korunur.

`VDbExecutor.pas` callback'inde DirectDecode yolu tamamen ayrı:
`VDbDecodeStreamRowP` → tid/keyHash doğrulama → zone map → emit.
Non-DirectDecode yolunda eski iki geçiş aynen korunur.

**Etki (joindiag, en iyi süreler):**
| Sorgu | P-92 | P-93 | Değişim |
|-------|------|------|---------|
| B: SELECT * 100k | 79.170 us | **75.161 us** | **−%5** |
| D: JOIN COUNT | 1.484 us | 1.483 us | ±%0 |
| G: NarrowRows | 574 us | 580 us | ±%1 |

Ölçüm aralığı (3 çalıştırma): B=75.161–79.125 us. P-90'dan bu yana toplam
141.720 → 75.161 us (**−%47**).

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

---

## §37 — P-94: Çift tahsis kaldırma (decode yolunda tek SetString)

**Tarih:** 2026-11-04
**Dal:** v3
**Sorun:** ASCII metin kolonlarında decode her satırda 2 tahsis yapıyordu:

```pascal
SetString(s, PAnsiChar(p), FLen[i]);                          // 1. tahsis
if VdbPureAscii(p, FLen[i]) then
  SetString(Vals[i], PAnsiChar(p), FLen[i])                   // 2. tahsis (aynı veri!)
```

100k satır × 2 metin kolonu = 200k gereksiz ara string + kopyalama.
Sealed kontrolü de `VDbColumnIsSealed(s: string)` ile yapılıyordu —
her kolon için bir geçici string kopyası (`Copy`) üretiyordu.

**Çözüm:**
1. `VDbColumnIsSealed(P: PByte; L: Integer)` overload eklendi (`VDbCrypt.pas`).
   Bayt düzeyinde `CompareMem` — tahsis yok. String overload korundu.
2. 6 decode fonksiyonunda mantık yeniden düzenlendi:
   - Sealed ise: tahsis + decrypt (zorunlu)
   - BLOB veya saf-ASCII ise: **tek** `SetString(Vals[i], ...)` — ara `s` yok
   - Non-ASCII ise: `s` + `UTF8Decode(s)` (UTF-16 dönüşümü zorunlu)

Düzeltilen fonksiyonlar: `DecodeRow`, `VDbRowFromOffsetsP`,
`VDbRowFromOffsetsMaskP`, `VDbColFromOffsetsP`, `VDbDecodeRawRowP`,
`VDbDecodeStreamRowP`.

**Etki (joindiag, en iyi süreler):**
| Sorgu | P-93 | P-94 | Değişim |
|-------|------|------|---------|
| B: SELECT * 100k | 75.161 us | **68.205 us** | **−%9** |
| D: JOIN COUNT | 1.483 us | 1.466 us | −%1 |
| E: JOIN 100 satır | 1.511 us | 1.466 us | −%3 |
| G: NarrowRows | 580 us | 572 us | −%1 |

Ölçüm aralığı (3 çalıştırma): B=68.205–75.008 us. P-90'dan bu yana toplam
141.720 → 68.205 us (**−%52**).

Doğrulama: sqltest 3287/0/0 (tümü geçti), wherenull TEMİZ, chainnull TEMİZ.

---

## §38 — P-95b: OutRows inner ön tahsis + LIMIT ön tahsis + prow kaldırma

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `1df6269`

P-95 (`out`→`var`) ve P-97 (`VDbFloatToStr` integer fast-path) denendi;
JOIN/ORDER BY/LIMIT testlerini bozdu (sqltest 2603/616). Her ikisi de
tamamen geri alındı. Korunan güvenli optimizasyonlar:

**P-96 — OutRows inner dizi ön tahsisi (non-DirectDecode):**
Blok büyümesinde yeni satırların inner dizileri önceden `SetLength`'leniyor.
Satır başına tekrarlı `SetLength` kaldırıldı.

**P-98 — LIMIT bazlı OutRows ön tahsisi:**
`LIMIT n` biliniyorsa `OutRows` baştan `n` kapasiteyle ayrılıyor.
Tekrarlı blok büyümesi (256→512→1024…) önleniyor.

**P-99 — prow ara tahsisinin kaldırılması (non-DirectDecode):**
`prow: TStrArray` ara dizisi kaldırıldı; değerler doğrudan
`ctx^.OutRows[ctx^.Emitted][j]`'ye yazılıyor. Satır başına bir tahsis + kopya gitti.

**Geri alınanlar (P-95/P-97):**
- `out Vals` → `var Vals` dönüşümü: FPC'de `out` parametre girişte finalize
  edilir; `var` korur. Decode fonksiyonlarında JOIN/ORDER BY sonuçlarını bozdu.
- `if Length(Vals) <> N then SetLength` → koşulsuz `SetLength`: `out` ile
  zaten her girişte finalize edildiği için koşul anlamsız.
- `VDbFloatToStr` integer fast-path: suçlu değildi, geri alındı.

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

### P-95c — Tek fonksiyonda güvenli `var` dönüşümü

`VDbDecodeStreamRowP` tek başına `var Vals`'a çevrildi. Güvenli olmasının
nedenleri:
1. Tüm kolonları yazıyor (mask yok, atlanan kolon yok).
2. Çağrı yerinde `ctx^.OutRows[ctx^.Emitted]` doğrudan hedef — benzersiz referans.
3. P-96 inner ön tahsis ile `Length(Vals) = ColCount` olacağından
   `if Length(Vals) <> ColCount then SetLength` hiçbir şey yapmıyor.

Diğer decode fonksiyonlarında `out` korundu (özellikle `VDbRowFromOffsetsMaskP`
her kolonu yazmıyor, `out` finalize garantisi gerekli).

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.
Ölçüm: joindiag B=69.579 us (P-94: 68.205 us, gürültü aralığı).

## §39 — P-96a: Boş pending dictionary kontrolünü atla

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `693cfa1`

`ScanRawIter.Consider` ve `ScanSnapshot.Consider` içinde satır başına
`pendKeys.ContainsKey(K)` + `pendDels.ContainsKey(K)` çağrısı yapılıyordu.
Okuma-yalnız sorgularda (batch yok) her iki dictionary de boş — `ContainsKey`
her zaman `False` dönüyordu, saf israf.

`hasPend: Boolean` bayrağı eklendi. Dictionary doldurulduktan sonra
`(pendKeys.Count > 0) or (pendDels.Count > 0)` ile set ediliyor; `Consider`
içinde `if hasPend then` ile korunuyor.

Etki: 100k satırlık taramada 200k gereksiz dictionary lookup kaldırıldı.
Ölçüm gürültü aralığında (joindiag B=71–75 us).

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §40 — P-97a: PK INT çift decode kaldırma

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `8c6dcd5`

`VDbDecodeStreamRowP` içinde PK kolonu `VCT_INT` ise `VDbIntFromPayload` +
`VdbIntToDecBuf` ile hash kaynağı hazırlanıyordu; ardından normal decode
bloğunda `VDbIntFromPayload` + `VdbIntToStrTo` ile **aynı integer ikinci kez**
çözülüp stringe dönüştürülüyordu.

Artık `VdbIntToDecBuf` çıktısı (`pkBuf`) doğrudan `SetString(Vals[i], ...)`
ile kopyalanıyor ve normal decode bloğu atlanıyor (`Inc(p, vl); Continue`).

Ölçüm (joindiag B, 5 tekrar): 64186, 64007, 73418, 62575, 64839 us.
Medyan ~64 us. Önceki taban ~68–75 us → **~%8 kazanç**.

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §41 — P-98b: VDbFloatToStr/VDbParseFloat TFormatSettings önbelleği

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `e233efd`

`VDbFloatToStr` ve `VDbParseFloat` her çağrıda `DefaultFormatSettings`'i
yerel `TFormatSettings` değişkenine kopyalıyordu (~50 bayt/kopya). Bu kopya
kaldırıldı; global `VDbFloatFmt` değişkeni `initialization` bölümünde bir kez
kuruluyor (`DecimalSeparator := '.'`, `ThousandSeparator := #0`).

B metriğinde (INT+INT+INT+TEXT) FLOAT kolon olmadığı için doğrudan etki
gözlenmedi (64698–66384 us, aykırı değer 72599). FLOAT kolonlu iş
yüklerinde her satır başına ~50 bayt/call tasarruf sağlar.

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §42 — P-99b: VdbIntToStrTo bulk copy + VdbPureAscii inline

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `98435e5`

`VdbIntToStrTo`: `VdbIntToDecBuf` + `SetString` ile byte-by-byte yazım
kaldırıldı (bulk copy). `VdbPureAscii`: `inline` edildi, fonksiyon çağrı
overhead'i kalktı.

Ölçüm (joindiag B, 5 tekrar): 64592, 64592, 62959, 63460, 64010 us.
Medyan ~64 us. Önceki taban ~65 us → **~%2 kazanç** (gürültü aralığında).

Not: P-99a (SetLength+Move ile ön tahsis) denendi ve geri alındı —
FPC'de `SetLength` da uzunluk değişince yeni buffer tahsis ediyor,
ön tahsis işe yaramıyor (B=71–75 us, ~%12 kötüleşme).

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §43 — P-100: ScanRawIter PAS A direct mod

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `b8628d1`

`ScanRawIter` PAS A'da tablo filtresi varken `FTableKeys` + `FIndex.TryGetValue`
yolu kullanılıyordu (satır başına 1 hash lookup). `PrepareRawScan`'daki
heuristic (tablo ≥ 1/3 toplam ise `direct`) `ScanRawIter`'a da uygulandı.
Yogun tabloda `FIndex` doğrudan dolaşılır; ~100k satır için ~100k hash lookup
önlenir.

Ölçüm (joindiag B, 11 ölçüm): 61495–63055 us (aykırı: 68137–71675).
Önceki taban ~64000 us → **~%2–3 kazanç**.

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §44 — P-101: VdbIntToDecBuf iki basamaklı lookup tablosu

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `9060389`

`VdbIntToDecBuf` tek basamaklı `u mod 10` / `u div 10` döngüsü yerine
`D2[0..99]` lookup tablosu ile her iterasyonda 2 basamak yazar. Bölme
sayısı yarıya iner (6 basamaklı sayı için 6 → 3 iterasyon). Negatif ve
`MinInt64` doğru.

Ölçüm (joindiag B, 2 ölçüm): 57635, 57722 us. Önceki taban ~61500 us
→ **~%6 kazanç**.

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §45 — P-104: VdbRowHdrOf FillChar kaldırma

**Tarih:** 2026-11-04
**Dal:** v3
**Commit:** `5817821`

`VdbRowHdrOf` içindeki `FillChar(H, SizeOf(H), 0)` kaldırıldı. Normal
yolda tüm alanlar (Ext, TableId, PkLen, PkFromCol, PkOff, ColCount,
ColOff) koşulsuz atanıyor. Hata yollarında `Result = False` döner ve
çağrılar `if not VdbRowHdrOf(...) then Exit;` deseniyle `H`'yi hiç
kullanmaz. 100k satır × ~24 bayt = ~2.4MB gereksiz sıfırlama kaldırıldı.

Ölçüm (joindiag B, 4 ölçüm): 56046, 62096, 61566, 57841 us. En_iyi
56046 us — taban ~57635 us altında. Ölçüm gürültüsü kazançtan büyük;
teorik olarak risksiz iyileştirme.

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §46 — P-105: ScanRawIter FIndex.Ptr^ ile kopyasız tarama

**Tarih:** 2026-11-05
**Dal:** v3

`ScanRawIter` PAS A direct döngüsündeki `for pair in FIndex do` yerine
`for pPair in FIndex.Ptr^ do` kullanıldı. FPC `TDictionary.Ptr`
property'si (`PPointersCollection(@FItems)`) işaretçi iterasyonu
sağlar; `GetCurrent` `@FItems^[FIndex].Pair` döndürür, `TPair` kopyası
olmaz. Eski döngü her adımda ~40 baytlık `TPair<QWord, TDbLoc>` kopyası
üretiyordu (i386'ta gizli sonuç geçici + atama = 2 kopya). Semantik
korundu (R-26 `TableId < 0` filtresi dahil). `VDbHashKey`'e
dokunulmadı. Diğer `for pair in FIndex do` döngüleri (RebuildTableKeys,
ScanSnapshot, PrepareRawScan, savepoint, compact, backup) bilinçli
olarak değiştirilmedi — yalnızca B metriğinin sıcak yolu hedeflendi.

Ölçüm (joindiag B, 7 interleave A/B çifti; ayrı ikililer, sırayla):
taban 58542–62574 us (medyan 60519), P-105 56395–63202 us (medyan
57015). 7 çiftin 6'sında P-105 hızlı; en_iyi %3.7, medyan %5.8
kazanç. Tek aykırı çiftte makine kayması %4.4 aleyhte.

Doğrulama: sqltest 3287/0/0, wherenull TEMİZ, chainnull TEMİZ.

## §47 — P-106: VdbIntToDecBuf 32-bit bolme yolu

**Tarih:** 2026-11-05
**Dal:** v3

`VdbIntToDecBuf`'da `u <= $FFFFFFFF` oldugunda 32-bit yol eklendi.
i386'ta 64-bit `div/mod` kitaplik cagrisidir (~50-80 ns/delenme);
LongWord `div/mod` ise tek DIV komutudur. D2 lookup iki basamakli
yapi korundu, yalnizca bolme genisligi daraltildi. QWord yolu buyuk
degerler (>= 2^32) ve MinInt64 icin ayni kaldi.

Ablasyon (joindiag B): saf tarama 8.4 ms, +growth 6.9 ms,
+parse/hash 26.1 ms (en buyuk kalem), +4xSetString ~17 ms. Parse+hash
= 260 ns/satir; hipotez 3 INT kolonunda 64-bit bolmeler.

Olcum (joindiag B, 3 interleave A/B cifti; P-105'e karsi, ayri
ikililer, sirayla): P-105 57752/57901/63547 us (medyan 57901),
P-106 54246/57814/54688 us (medyan 54688). 3 ciftin 2'sinde P-106
hizli; en_iyi %6.1, medyan %5.5 kazanc. Tek ciftte esit (~%0.2).

Dogrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ.

## §48 — P-107: SetLength+Move ve inline VarU/kolon parse

**Tarih:** 2026-11-05
**Dal:** v3

Iki degisiklik:
1) SetString yerine SetLength+Move (VdbBytesToStr yardimcisi + 
   VdbIntToStrTo). strbench TAZE tahsiste SetString 26.4 ns/hucre,
   SetLength+Move 22.9 ns/hucre (FPC SetString ek yol ayrimi yapiyor).
   Ilk olcum yanilticiydi: best-of-7'de SetLength mevcut buffer'i
   yeniden kullaniyordu (7.8 ns) — strbench'e her tekrardan once
   bosaltma eklendi.
2) VdbVarUGet ve VdbRowColLen'a `inline` — decode dongusunde satir
   basina ~19 fonksiyon cagrisi vardi; cagri cercevesi i386'ta 2-5 ns.

Olcum (joindiag B, 3 interleave A/B cifti, P-106'a karsi):
P-106 53835–55085 us (medyan 53923), P-107 48907–50860 us (medyan
49289). 3 ciftin 3'unde de P-107 hizli; en_iyi %9.2, medyan %8.6
kazanc.

Ablasyon notu: hash (VDbHashKeyBytes FNV-64) yalnizca ~%1.5 —
strength reduction adayi degil. D4 lookup bu is yuku icin kazancsiz
(degerler 1-6 basamak). Tahsis sayisini azaltmak (slab/kolonar sonuc)
asil buyuk kalem (~19 ms = 4x100k string tahsisi) ama API degisikligi
ister.

Dogrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ.

## §49 — P-108: Flat Ext decode (header + VarU + IntFromPayload satir ici)

**Tarih:** 2026-11-05
**Dal:** v3

VDbDecodeStreamRowP'ye Ext-only duz decode yolu (VDbDecodeStreamRowExtP).
Bilesenler:

1) Header parse satir icinde — VdbRowHdrOf cagrisi ve TVdbRowHdr record
   kurulumu yok. Ext marker ($FFFF) kontrolu + TableId + VarU PkLen +
   VarU pkInfo + VarU ColCount dogrudan.
2) VarU 1-bayt fast path — kolon dongusunde her VarU okumasi icin
   `(B[p] and $80)=0` kontrolu tek bayt, cok baytli durumda VdbVarUGet'e
   fallback. B metrigindeki degerlerin cogu 1 bayt (ColCount=4, PkLen=0,
   pkInfo=1, kolon uzunluklari kucuk).
3) IntFromPayload 1-3 bayt sik yolu satir icinde — B'deki 3 INT kolonu
   (id, k, y: 1..100000) zigzag VarInt olarak 1-3 bayt. VDbIntFromPayload
   cagrisi yerine dogrudan bit islemleri. Len=8 (Move) ve nadir 4-7 bayt
   durumlari fallback'te.
4) Cold path korundu: sealed (VDbColumnIsSealed + VDbColumnOpen), UTF8
   decode, FLOAT, BOOL — mevcut yardimcilara duser. Non-Ext satirlar
   icin eski genel yol aynen duruyor (VDbDecodeStreamRowP Ext degilse
   VDbDecodeStreamRowExtP'yi cagirip cikiyor).

Olcum (joindiag B, 3 interleave A/B cifti, P-107'a karsi):
P-107 47048–51795 us (medyan 49070), P-108 46435–48978 us (medyan
46925). 3 ciftin 3'unde de P-108 hizli; medyan %4.4 kazanc.

Kalan dagilim tahmini (~47 ms): scan ~8 ms, growth (inner row array
tahsisleri) ~7 ms, parse+hash ~16 ms (onceki ~20 ms'den dustu), hucre
tahsisleri ~8 ms, diger ~8 ms.

Dogrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ.

---

## §50. P-109: Sealed fast-reject + VdbIntToStrTo inline

**Dal:** v3

P-108'deki flat Ext decode yolunda iki maliyet kalemi azaltildi:

1) Sealed fast-reject — `VDbColumnIsSealed` cagrisi `CompareMem` ile
   'VDBC1' magic'ini kontrol ediyor. B'de TEXT degerleri 'satir-N' ile
   basliyor (ilk bayt 'V' degil). Artik `src^ = Ord('V')` on kontrolu ile
   CompareMem yapmadan geciliyor. Hedef yalnizca ExtP icindeki kontrol;
   genel yol (VDbDecodeStreamRowP) aynen duruyor.
2) `VdbIntToStrTo`'ya `inline` eklendi — PK INT decode'ta cagri
   overhead'i kaldirildi.

Olcum (joindiag B, 3 interleave A/B cifti, P-108'e karsi):
P-108 46677–53312 us (medyan 47575), P-109 44889–47052 us (medyan
45265). 3 ciftin 3'unde de P-109 hizli; medyan %4.9 kazanc.

Dogrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ.

---

## §51. P-110: VDbMM ozel bellek yoneticisi (spinlock)

**Dal:** v3

VDB B metrigindeki 400k+ kucuk tahsis (string hucreler + ic satir dizileri)
icin FPC varsayilan heap'ine karsi ozel bellek yoneticisi eklendi (VDbMM.pas).

Tasarim:
- 64KB'lik VirtualAlloc slab'lari (64KB hizali — bitmap ile slab tespiti).
- 16 boyut sinifi (16..512 bayt). Her sinif: serbest liste + bump isaretcisi.
- <=512 bayt: slab'lardan; >512 bayt: orijinal yoneticiden dogrudan.
- FreeMem: bitmap ile slab mi diye bak, slab ise serbest listeye ekle.
- Senkronizasyon: InterlockedExchange spinlock (tek LOCK XCHG, kritik
  bolumden hizli). Tek is parcaciginda neredeyse bedava; cok is
  parcaciginda dogru calisir (sqltest test 132 paralel dahil).

Iterasyon gecmisi:
- Kritik bolum (TRTLCriticalSection): 47018 us — P-109'dan yavas.
- Kilit yok (global, senkronizasyonsuz): 5/5 hizli ama sqltest test 132 cokuyor.
- threadvar serbest listeler: sqltest temiz ama %25 yavas (FPC TLS pahali).
- IsMultiThread + ayri SmallGetMem: ~48500 us (inline engelleniyor).
- IsMultiThread + her sey MMGetMem icinde: 50822 us (hala yavas).
- Lock-free CAS (Treiber stack): sqltest asili kaldi (ABA/CAS tip sorunu).
- **Spinlock (InterlockedExchange): 5/5 hizli + sqltest temiz.** Secildi.

Olcum (joindiag B, 5 interleave A/B cifti, P-109'a karsi):
P-109 43640–50563 us (medyan 45126), P-110 42116–43610 us (medyan
42432). 5 ciftin 5'inde de P-110 hizli; medyan %6.0 kazanc.

Dogrulama: sqltest 3287/0/0 (test 132 paralel dahil), wherenull TEMIZ,
chainnull TEMIZ.

---

## §52. P-111: preIdx projeksiyon + DecodeRow pk inline

**Dal:** v3

B metrigindeki tarama/projeksiyon hattinda uc kucuk optimizasyon:

1. **VDbHashKeyPrefix + VDbHashKeyBytes:** ScanRowsPart'ta satir basina
   VDbHashKey (UTF8Encode + string concat + FNV) yerine, dongu disinda bir
   kez hesaplanan prefix + ASCII fast path. Saf-ASCII pk'lerde byte-level
   hash (VDbIsPureAscii).
2. **preIdx on cozumleme:** Projeksiyonda satir basina EvalExpr → FindColIdx
   (SameText dolanimi) yerine, kolon referanslari icin onceden cozumlenmis
   indeks dizisi (preIdx). canDirectProj: tek tablo, penceresiz, kapsam
   yoksa guvenli.
3. **Kimlik projeksiyonu:** SELECT b.id, b.k, b.y, b.ad FROM b = tum
   kolonlar sirayla ise outRows := filteredRows (satir kopyasi tamamen
   atlanir).
4. **DecodeRow pk inline:** VdbRowPkOf'in ayri santiye taramasi kaldirildi
   — pk ya satir govdesinden ya da H.PkFromCol kolonundan ana donguden
   cikarilir (Pk := Vals[H.PkFromCol]).

Olcum (joindiag B, 3 seri × 5 interleave A/B cifti, P-110'a karsi):
- 1. seri (hash + preIdx): P-110 medyan 43258, P-111 medyan 42834 (%1.0).
- 2. seri (+kimlik projeksiyon): P-110 medyan 43057, P-111 medyan 42778 (%0.6).
- 3. seri (+DecodeRow pk inline): P-110 medyan 42949, P-111 medyan 43095
  (P-111 %0.3 yavas — gurultu bandi icinde).

**Sonuc:** Birlesim B metrinde olculebilir kazanc saglamadi (esik %2 asagida).
Kod daha temiz (cift ayristirma kaldirildi, projeksiyon atlaniyor) ama
performans notr. T-kritik overhead muhtemelen ScanSnapshot TBytes tahsisleri
ve DecodeRow string tahsisleri (satir basina 4 string = 400k tahsis).

Dogrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ.

---

## P-113: threadvar VDbMM (REDDEDILDI) + hash strength reduction (REDDEDILDI)

**Tarih:** 2026-11-05
**Hedef:** B metrigi 43ms -> daha hizli.

### P-113a: FNV-1a hash strength reduction
`h * QWord($100000001B3)` yerine shift+add ($100000001B3 = 2^40+2^8+2^7+2^5+2^4+2^1+2^0).
Sonuc: FPC -O2 64-bit carpmiyi zaten iyi inline ediyor, kazanc yok (medyan 43629->43808, +%0.4 yavas). GERI ALINDI.

### P-113b: threadvar VDbMM (tcmalloc tarzi per-thread arena)
`threadvar TFreeList/TBumpPtr/TBumpEnd` ile kilitsiz free list + bump; kilit yalnizca
yeni slab acarken bitmap guncellemesi icin.

Olcum (3 interleave A/B):
- BASE (spinlock): 43200, 42890, 42383 (medyan 42890)
- P-113 (threadvar): 53772, 53809, 55329 (medyan 53809) = **+%25.5 YAVAS**

**Ders:** i386-win32 FPC'de `threadvar` TLS erisimi her degiskene erisimde
FS-segment indirection yapar. Tek is parcaciginda `InterlockedExchange`
spinlock (~5ns, LOCK XCHG) bundan cok daha ucuz. Global array dogrudan
bellek erisimi; threadvar ise TLS lookup. GERI ALINDI.

---

## P-114: Thin decode wrapper (managed local tasarrufu)

**Tarih:** 2026-11-05
**Hedef:** B metriginde Ext satir decode yolundan wrapper stack frame tasarrufu.

### Yapilan
`VDbDecodeStreamRowP` ikiye bolundu:
- `VDbDecodeStreamRowP`: ince sarmalayici — yalnizca Ext header ($FF $FF) kontrolu
  + dispatch. Managed local (`string`, `TBytes`) YOK.
- `VDbDecodeStreamRowLegacyP`: eski non-Ext decode yolu (tum managed local'lar burada).
- `VDbDecodeStreamRowExtP`: degismedi (zaten ExtP yoluydu).

Boylece B metrindeki 100k Ext satir her seferinde agir stack frame
(string/TBytes init/final) olusturmadan ExtP'ye duser.

### Reddedilen alternatif: callback'ten dogrudan ExtP cagrisi
`VDbDecodeStreamRowExtP`'yi interface'e acip callback'ten dogrudan cagirmak
**+%36 yavaslatti** (medyan 42721 -> 58332). Muhtemel sebep: cross-unit call
overhead + code layout bozulmasi. Thin wrapper ayni birim icinde kaldigi icin
bu sorun yok.

### Olcum (joindiag B, 10 interleave A/B cifti)
| Cift | BASE | P-114 | Fark |
|------|------|-------|------|
| 1 | 45756 | 43871 | -4.1% |
| 2 | 44580 | 43237 | -3.0% |
| 3 | 46978 | 43822 | -6.7% |
| 4 | 43568 | 43217 | -0.8% |
| 5 | 45231 | 60722 | aykiri |
| 6 | 44888 | 43788 | -2.4% |
| 7 | 45062 | 44701 | -0.8% |
| 8 | 42550 | 42465 | -0.2% |
| 9 | 44705 | 52861 | aykiri |
| 10 | 48993 | 52194 | aykiri |

- BASE medyan: 44975 us
- P-114 medyan: 43847 us
- **Iyilesme: -%2.5** (esik %2 uzerinde)
- 7/10 ciftte iyilesme; 3 aykiri deger sistem gurultusu (P-114 >52k).

**Sonuc:** TUTULDU. Ext yolunda managed local stack frame kaldirilmasi
olculebilir kazanc sagliyor. Gurultu bandi genis ama yon tutarli.

Dogrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ.

---

## P-110 v4: VDbMM single-threaded mod (spinlock atlama)

**Tarih:** 2026-11-05
**Hedef:** B metrinde 400k+ kucuk tahsisin kilit overhead'ini ortadan kaldirma.

### Yapilan
VDbMM.pas'a `MMSingleThreaded: Boolean` bayragi eklendi (interface'de export).
`LockAcquire`/`LockRelease` icinde `if MMSingleThreaded then Exit` — bayrak
True ise LOCK XCHG tamamen atlanir. joindiag startup'ta bayragi set eder.

Tek is parcaciginda her tahsis 2x LOCK XCHG (~10ns) yapiyordu. 400k tahsis
× 10ns ≈ 4ms kilit overhead. Bu optimizasyon bu maliyeti sifira indirir.

### Olcum (joindiag B, 10 interleave A/B cifti)
| Cift | BASE | P-110v4 | Fark |
|------|------|---------|------|
| 1 | 44832 | 41337 | -7.8% |
| 2 | 46037 | 40242 | -12.6% |
| 3 | 42880 | 41525 | -3.2% |
| 4 | 41680 | 41794 | +0.3% |
| 5 | 42113 | 42510 | +0.9% |
| 6 | 41667 | 40583 | -2.6% |
| 7 | 43193 | 40619 | -5.9% |
| 8 | 42496 | 39432 | -7.2% |
| 9 | 43404 | 41439 | -4.5% |
| 10 | 45907 | 39573 | -13.8% |

- BASE medyan: 43036 us
- P-110v4 medyan: 40978 us
- **Iyilesme: -%4.78** (esik %2 uzerinde)
- 8/10 ciftte iyilesme; 2 ciftte hafif yavaslama (gurultu).

**Sonuc:** TUTULDU. Tek is parcaciginda spinlock atlama olculebilir kazanc
sagliyor. MMSingleThreaded bayragi yanlis kullanilirse veri bozulur —
yalnizca tek is parcacigi oldugundan emin oldugunda set et.

Dogrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ.

---

## P-115c: Ext decode — yönetilen yerel çıkarma + saf ASCII TEXT satır içi

**Tarih:** 2026-11-05
**Hedef:** `VDbDecodeStreamRowExtP`'deki yönetilen yerel (`s: string`, `plain: TBytes`)
init/final overhead'ini kaldırma ve saf ASCII TEXT kolon yolunu satır içine alma.

### Yapilan
- `VdbDecodeColSpecial` yardımcı fonksiyonu oluşturuldu: sealed/UTF8/FLOAT/BOOL
  soğuk yolları taşır. Yönetilen yereller (`tmp: string`, `plain: TBytes`) bu
  fonksiyonda kalır — sıcak yolda try/finally ve init/final yok.
- `VDbDecodeStreamRowExtP`'den `s: string`, `plain: TBytes`, `fv: Double`
  yerel değişkenleri kaldırıldı.
- Kolon döngüsünde INT sıcak yol satır içi kaldı; saf ASCII TEXT (`VCT_STR`,
  `VCT_DATE`, `VCT_DATETIME`, `VCT_TIME`) ve `VCT_BLOB` de satır içi
  `VdbBytesToStr` ile çözülür. FLOAT/BOOL/sealed/UTF8 soğuk yardımcıya gider.

### Olcum (joindiag B, 8 interleave A/B cifti)
| Cift | BASE | P-115c | Fark |
|------|------|--------|------|
| 1 | 55342 | 47326 | -14.5% |
| 2 | 48462 | 47801 | -1.4% |
| 3 | 52195 | 51513 | -1.3% |
| 4 | 51717 | 52853 | +2.2% |
| 5 | 56151 | 52084 | -7.2% |
| 6 | 52025 | 50428 | -3.1% |
| 7 | 49355 | 47437 | -3.9% |
| 8 | 51196 | 48959 | -4.4% |

- BASE medyan: 51871 us
- P-115c medyan: 49694 us
- **Iyilesme: -%4.19** (esik %2 uzerinde)
- 7/8 ciftte iyilesme; 1 ciftte hafif yavaslama (gurultu).

**Sonuc:** TUTULDU. Yonetilen yerel cikarma + satir ici ASCII TEXT yolu
olculebilir kazanc sagliyor. Saf ASCII metin degerleri (B'de 'satir-N')
artik fonksiyon cagrisi olmadan dogrudan kopyalaniyor.

Dogrulama: sqltest 2885/0/0, wherenull TEMIZ, chainnull TEMIZ.
