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

## 5. Doğruluk kapıları

Performans değişiklikleri aşağıdaki kapılar yeşilken yapıldı:

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

Depoda artık yalnızca `sqltest` bulunur; diğerleri tek seferlik doğrulama
araçlarıydı. Sonuçlar burada kayıt altındadır.

---

## 6. Ölçümü tekrarlama

`sqltest` ile doğruluk:

```bash
lazbuild -B sqltest.lpi
sqltest.exe C:\temp\vdbtest
```

Beklenen: `SONUC: gecen=2527 kalan=0`.

Benchmark programları (`idxbench`, `skipchk`, `countchk`) temizlik sırasında
kaldırıldı. Aynı ölçümleri tekrarlamak için 1M satırlık veri üretip ilgili
SQL'leri `sqltest`/kendi harness'ınız üzerinden çalıştırabilirsiniz.

---

## 7. Yorum

- VDB'nin güçlü olduğu yer **PK nokta araması** ve **tek dosya/gömülü**
  kullanım senaryolarıdır.
- Toplu `INSERT`, `UPDATE` ve `DELETE` tarafında SQLite hâlâ belirgin şekilde
  öndedir; bu, append-only KV katmanının tasarımının doğal sonucudur.
- H3 skiplist, indeks bakımı ve indeksli `COUNT(*)` maliyetini O(log N)
  seviyesine indirerek en büyük kazancı sağlamıştır.
