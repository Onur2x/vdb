# Performans taban çizgisi ve regresyon eşikleri (Phase 6)

Bu belge `p6-perf-baseline` kaleminin neyi ölçtüğünü, hangi eşikleri
kilitlediğini ve **neleri iddia etmediğini** kaydeder.

## 1. Kapı

| Kapı | Dosya | Ne yapar |
|---|---|---|
| `perf_baseline` | `tests/perf_baseline/perf_baseline.lpr` | B+Tree ekleme/arama/silme, ölçekleme oranı, SQL ekleme/nokta sorgusu ölçer; geniş tavanlar ve ölçek eşiğiyle regresyonu reddeder |

Kapı `build/gates/` altında derlenir ve `tests/run_gates.sh` içinde koşar.
Süre ~10-15 sn (baskın kısım SQL ekleme).

## 2. Neden ölçekleme + geniş tavan?

Mutlak milisaniye makineye, yüke ve dosya sistemine bağlıdır; CI
makinesinde süre 3-5 katı olabilir. Bu yüzden:

- **Tavanlar geniştir** (aşağıdaki tablo): amaç mikro-benchmark yarışı
  değil, patolojik bozunmayı yakalamaktır.
- **Ölçekleme oranı** asıl sinyaldir: 25 000 ve 50 000 anahtar için
  ekleme süresi oranı `<= 3.50` olmalı. Doğrusal-üstü (O(n log n))
  davranış ~2x verir; **karesel** bozunma ~4x verir ve kapıyı kırar.
  Oran, mutlak hızdan bağımsızdır.

## 3. Ölçülen değerler

Ortam: **WSL2 x86_64 Linux, FPC 3.2.2, `-O1`**, tek oturum, sıcak
dosya sistemi önbelleği.

| Ölçüm | Boyut | Süre | Not |
|---|---|---|---|
| `btree.insert` | 100 000 anahtar (karışık sıra) | **361 ms** | `h=3`, `leaf=1499` |
| `btree.find` | 5 000 nokta arama | **9 ms** | tümü bulundu |
| `btree.delete` | 100 000 anahtar (sıralı) | **312 ms** | silme sonrası invariant temiz |
| `btree.scale` | 25 000 → 50 000 | **59 → 118 ms**, oran **2.00** | eşik 3.50 |
| `sql.insert` | 3 000 satır | **9 662 ms** | ~3.2 ms/satır (PK indeks + WAL) |
| `sql.point-select` | 3 000 sorgu | **1 101 ms** | ~0.37 ms/sorgu |
| `sql.file` | — | 102 400 bayt | 3 000 satır; dosya adı `veritabani.odb` |

B+Tree sayıları **bellek içi** ağaçtır (`TVDbBTree`); diske yazma yoktur.
`sql.*` sayıları tam motoru (sayfa, WAL, indeks) içerir.

## 4. Eşikler

| Kontrol | Eşik |
|---|---|
| `btree/ceil-insert` | `<= 60 000 ms` |
| `btree/ceil-delete` | `<= 60 000 ms` |
| `btree/ceil-find` | `<= 15 000 ms` |
| `btree/scale-linear` | oran `<= 3.50` |
| `sql/ceil-insert` | `<= 120 000 ms` |
| `sql/ceil-select` | `<= 60 000 ms` |

Eşikler ölçülen değerlerin **~6-150 katı** üstündedir. Bu bilinçlidir:
kapının işi "bu makine hızlı mı" sorusunu yanıtlamak değil, "bir değişiklik
algoritmik bozunma mı getirdi" sorusunu yakalamaktır.

## 5. Doğruluk kontrolleri (performansla birlikte)

Hız ölçerken sessizce yanlış sonuç üretilmesini engellemek için aynı
koşumda şunlar da denetlenir:

| Kontrol | Ne der |
|---|---|
| `btree/count`, `btree/all`, `btree/sorted` | 100 000 girdi sayıldı, tamamı sıralı çıktı |
| `btree/inv`, `btree/del-inv` | `CheckInvariants` ekleme ve silme sonrası temiz |
| `btree/find-all` | 5 000 aramanın tümü bulundu |
| `sql/inserted` | 3 000 nokta sorgusunun tümü **doğru** değeri döndürdü |
| `sql/count` | `COUNT(*)` = 3 000 |
| `sql/file` | motorun bildirdiği dosya yolu gerçekten var |

`sql/file` ilk yazımda yanlış çalışıyordu: dosya adı `vdb.odb` diye
**varsayılmıştı**, oysa motor `veritabani.odb` üretiyor (`VdbResolveFile`
dizini çözer). Ölçüm `Be.FilePath` üzerinden yapılacak şekilde
düzeltildi — dosya adı/uzantı artık tahmin edilmiyor.

## 6. Kapsam dışı (dürüst sınırlar)

- **Mutlak hız garantisi yok.** Bu sayılar bir makinede bir kez ölçüldü;
  donanım, işletim sistemi ve derleyici sürümüyle değişir.
- **Eşzamanlılık / çok iş parçacığı** ölçülmez (tek oturum).
- **Disk fsync / WAL dayanıklılık maliyeti** ölçülmez; o `wal_crash` ve
  `kv_wal` kapılarının konusudur. Buradaki süreler sayfa önbelleği açık
  normal yoldur.
- **Bellek tüketimi** (RSS, tepe heap) ölçülmez.
- **`sql_fuzz` girdi başına zaman aşımı** hâlâ ayrı bir kalemdir.
- Kapı, yeni bir algoritma değişikliğinde eşiklerin **kendiliğinden**
  güncellenmesini sağlamaz: davranış bilinçli değişirse bu belge ve
  eşikler birlikte güncellenmelidir.
