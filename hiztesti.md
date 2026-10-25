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

| Metrik | v2 | **v3** | Fark |
|---|---:|---:|---|
| Veri dosyası (`.odb`) | 19.278.424 B (96,4 B/satır) | **15.527.936 B (77,6 B/satır)** | **−19,5 %** |
| Açılış dizini (`.odb.idx`) | — | 3.520.080 B (17,6 B/satır) | +3,5 MB |
| **Diskteki toplam** | **19.278.555 B** | **19.048.016 B** | **−1,2 %** |
| Açılış | 984 ms | **32 ms** | **30,8x hızlı** |
| Toplu INSERT (tek batch) | 4,455 µs/satır | 6,640 µs/satır | 1,49x yavaş |
| Autocommit INSERT | 0,431 ms/satır | 0,557 ms/satır | 1,29x yavaş |
| PK nokta araması | 6,25 µs | **6,25 µs** | eşit |
| parse-only `SELECT 1` | 3,90 µs | **3,90 µs** | eşit |
| `COUNT(*)` | 31 ms | 62 ms | 2,0x yavaş |

**`.odb.idx` nedir, sayılmalı mı?** Açılışta heap dizinini (anahtar → sayfa/slot)
yeniden kurmak yerine diskten yükleyen **türetilmiş bir önbellektir**; veri
kaynağı değildir, silinirse hiçbir şey kaybolmaz (açılış 16 ms yerine 79 ms
sürer, hedef 150 ms). Diskte yer kapladığı için yukarıda **ayrı satırda ve
toplamda** gösterildi. Yalnız `.odb` sayıldığında kazanç %19,5; `.idx` ile
birlikte %1,2'dir — iki sayı da yazılmalıdır, tek başına %19,5 yanıltıcıdır.

**Varsayılan politika boyuta göre otomatiktir** (`TVdbPageEngine.IdxMaxBytes`,
eşik **50 MB**): bu boyutun altındaki veritabanlarında `.idx` yazılır (açılış
hızlı), üstünde yazılmaz ve daha önce yazılmış `.idx` silinir (diskte ~%18–23
tasarruf, açılış tam tarama). Eşik `IdxMaxBytes := 0` ile kaldırılabilir.
`backendchk` bu politikayı 6 kontrolle sınar (`idxpol)`).

Not: `autocommit`, `toplu INSERT` ve `COUNT(*)` dışındaki satırlarda v3
gerilemiyor. Bu tablodaki üç gerileme **ölçülmüş ve kabul edilmiş**
maliyetlerdir (aşağıda kök nedenleriyle).

### Neden toplu INSERT 6,64 µs?

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

### Neden `COUNT(*)` 62 ms?

v2'de `COUNT(*)` tablo satır sayacından **O(1)** yanıtlanır
(`TryGetTableRowCount`); 31 ms ölçülen değer sayaç + doğrulama yoludur.
v3'te anahtarlar tablo+PK hash'i olduğu için **tablo başına sayaç yok**;
sorgu tam tarama yapar. Tarama satır çözmeden (ham hücre) çalışır, yani
maliyet CPU değil **okunacak bayt**tır: 15,5 MB / 62 ms ≈ 250 MB/s.
Bu bir v3.1 işidir (tablo başına canlı satır sayacı).

### v3.0 kabul hedefleriyle karşılaştırma

| Hedef | Hedef değer | Ölçülen | Durum |
|---|---:|---:|---|
| Dosya boyutu (SQL harness, 3 kolon) | ≤ 11 MB | 15,5 MB | **karşılanmadı** |
| Dosya boyutu (sayfa harness, 32 B değer) | ≤ 11 MB | **9,76 MB** | karşılandı |
| Açılış | ≤ 150 ms | **32 ms** | karşılandı (4,7x pay) |
| PK nokta | ≤ 7 µs | **6,25 µs** | karşılandı |
| Toplu INSERT | ≤ 5 µs | 6,64 µs | **karşılanmadı** (v2: 4,46) |
| Autocommit INSERT | ≤ 0,55 ms | 0,557 ms | **sınırda** (v2: 0,431) |
| `COUNT(*)` | ≤ 16 ms | 62 ms | **karşılanmadı** |

Dosya boyutu hedefi iki farklı harness'ı karıştırıyordu: `benchv3` (sayfa
motoru, 32 B değer, 9.756.672 B = 48,8 B/satır) hedefi tutar; `benchcmp`
(SQL katmanı, 3 kolon, ~24 B metin) tutmaz. Tabloda ikisi ayrı verildi.

**Dürüst özet:** v3.0 dosya boyutunu ve özellikle açılışı kazanıyor, PK ve
parse maliyeti v2 ile aynı; buna karşılık **toplu yazım ~1,5x, `COUNT(*)` 2x
ve tek satır yazım ~1,3x daha yavaş**. v3.1'in konusu bu üç madde: mantıksal
(küçük) WAL çerçevesi, tablo başına satır sayacı, dosya uzatmasını toplu
yapma (ölçülen: sayfa başına 45–50 µs tek tek uzatma).

### Sayfa motoru harness'ı (`benchv3`, 200k satır × 32 B değer)

`benchcmp`'ten ayrı bir harness; sayılar karıştırılmamalıdır:

| Metrik | Ölçülen |
|---|---:|
| Dosya | 9.756.672 B (48,8 B/satır) |
| `.idx` | 3.200.064 B (16,0 B/satır) |
| Yazım (commit + checkpoint dahil) | 1,88 µs/satır |
| Açılış (`.idx` ile) | 16 ms |
| Açılış (tam tarama) | 79 ms |
| PK okuma | 0,47 µs/satır |
