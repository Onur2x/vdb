# SQL yürütücü ölçek ölçümü (v3.47)

Kapı: `tests/sql_scale` (SS1-SS20, 34 kontrol).
Komut: `bash tests/run_gates.sh <WORK>` — kapı `sql_scale` satırı olarak koşar.

Bu belge **ölçüleni** yazar. Hiçbir yerde "bellek verimli", "sabit bellek",
"RSS şu kadardır" gibi bir iddia kurmaz; ölçüm aletinin kendisi de kapıda
doğrulanır.

## 1. Ne ölçülüyor

| Kademe | Tablo | Amaç |
|---|---|---|
| 100.000 satır | `t(id INTEGER PRIMARY KEY, b INTEGER, v TEXT)` | nokta okuma, aralık taraması, ORDER BY, LIMIT/OFFSET, toplama, GROUP BY/HAVING, JOIN, UPDATE/DELETE, karışık işlem |
| 1.000.000 satır | `m(id INTEGER PRIMARY KEY, v TEXT)` | toplu yükleme, LIMIT'siz tam tarama, ORDER BY, aralık taraması, tavan sonrası yazma |

Her kademede ölçülen: satır sayısı, değer doğruluğu, süre (`GetTickCount64`),
dosya boyu (`TFileStream`), yığın deltası (`GetHeapStatus.TotalAllocated`) ve
hata davranışı.

## 2. Sonuçlar (iki platformda aynı satır/değer, süreler farklı)

Windows i386 (FPC 3.2.4) / Linux x86_64 (FPC 3.2.2):

| Ölçüm | Windows | Linux |
|---|---|---|
| 100k ekleme | 656 ms | 1213 ms |
| 100k dosya boyu | 3.997.696 B | 3.997.696 B |
| 100k `ORDER BY id DESC LIMIT 5` | 0 ms | 7 ms |
| 100k `GROUP BY b` (10 grup) | 15 ms | 29 ms |
| 100k `UPDATE` 1000 satır | 93 ms | 154 ms |
| 1M ekleme | 6547 ms | 11849 ms |
| 1M dosya boyu | 37.543.936 B | 37.543.936 B |
| 1M ekleme sırasında yığın deltası | 43.084 KB | 43.704 KB |
| 1M LIMIT'siz `SELECT *` | 516 ms | 900 ms |
| 1M `SELECT *` yığın deltası | 3.934 KB (~4 B/satır) | 7.889 KB (~8 B/satır) |
| 1M `ORDER BY id LIMIT 100` | 859 ms (11.727 KB) | 1212 ms (23.446 KB) |
| 1M `ORDER BY id DESC LIMIT 3` | 797 ms | 970 ms |
| 1M `WHERE id > 999000` | 1000 satır | 1000 satır |

Doğruluk kontrolleri (iki platformda birebir): `SUM(id)` = 5.000.050.000,
`MIN`/`MAX` = 1/100000, `AVG(id)` = `50000.5`, `GROUP BY b` 10 grup × 10.000,
`HAVING COUNT(*) > 20000` → 0 grup, `HAVING COUNT(*) >= 10000` → 10 grup,
JOIN 100 eşleşme, `OFFSET 99997 LIMIT 3` → 99998..100000.

Yeniden açılış sonrası tam `VERIFY` (100k/104k satırlık dosya):
`sayfa=995 serbest=0 heap=994 tasma=0 trunk=0 anahtar=104194 lsn=405`,
satır sayısı 104093 korunur, dosya 4.263.936 B (küçülmez).
1M dosyası: `sayfa=9139 serbest=0 heap=9138 tasma=0 trunk=0 anahtar=1000001 lsn=2005`.

## 3. Bellek sayısının dürüst yorumu

`yigin_delta_kb`, `TotalAllocated` farkıdır: süreç içi ayırıcının toplam
ayırdığı bayt. **RSS değildir**, işletim sisteminden alınan sayfa sayısı
değildir ve serbest bırakılan blokların yeniden kullanımından etkilenir
(ölçüm, ekleme fazından kalan boş blokları yeniden kullanabilir).

Bu yüzden:

- Aletin kör olmadığı kapıda kanıtlanır: **SS20** 8 MB ayırır ve yığın
  deltasının en az 4 MB görünmesini şart koşar; ölçülen 7812 KB (beklenen
  8192 KB'nin %95'i).
- 1M LIMIT'siz `SELECT *` için ölçülen delta **satır başına tam bir işaretçi**
  (i386'da 4 B, x86_64'da 8 B). Bu, sonuç matrisinin dış dizisinin satır
  başına bir işaretçi tuttuğunu düşündürür; satırların kendisinin nerede
  durduğu bu kapıda **araştırılmadı**. Rapor bu sayıyı "verimli" diye
  yorumlamaz, yalnızca ölçüldüğü gibi aktarır.
- Tam taramanın gerçekten maddelleştiği ayrıca doğrulanır: 1.000.000 satır
  döner ve ilk/orta/son satır değerleri (`m1`, `m500000`, `m1000000`) tek tek
  kontrol edilir (paylaşılan/alias satır tamponu olsaydı bu kontrol düşerdi).

## 4. Sonuç kümesi tavanı (§4.2)

Tavan kodda vardır: `VDB_MAX_RESULT_ROWS = 2000000` (v3.37) ve yürütücünün
tarama/toplama/DISTINCT/JOIN yollarında `ecLimit` ile uygulanır
(`VDbExecutor.pas`; mesaj: `sonuc kumesi cok buyuk (%d satir siniri; LIMIT
kullanin)`).

Bu kapı tavanın **altında** davranışı ölçer: 1M satırlık LIMIT'siz `SELECT *`
kabul edilir ve tam döner (tavan 2M). Tavanın üstünü maddelleştirmek 32-bit
kapı sürecinde ~GB bellek ister ve ölçümü bozar; bu yol `tests/limits` L4
(`LIMIT` tavanın üstünde → `ecLimit`) ve yürütücüdeki `ecLimit` noktalarıyla
kapsanır. Bu, "2M satır üreten bir kapı var" demek değildir; olmayan şey
olduğu gibi yazılır.

## 5. İşlem ve dayanıklılık

- 5.000 satırlık tek işlem `COMMIT` sonrası görünür (SS12), `ROLLBACK`
  sonrası 0 hayalet satır (SS13).
- Büyük taramalardan sonra yazma yolu çalışmaya devam eder: `INSERT`,
  `UPDATE`, `DELETE` (SS18a/SS18b), tablo 1M'de kalır (SS18c), dosya
  `VERIFY` temiz (SS18d).
- Yeniden açılışta tam `VERIFY` + satır sayısı + commit'lenmiş satırlar +
  UPDATE sonucu korunur (SS14a-SS14d).

## 6. Bu kapının bulduğu kusur

**Yok.** Bu kapı yeni bir motor kusuru ortaya çıkarmadı; eklenen tek düzeltme
kapının kendi ölçüm aletiydi (ölü metrik `TotalCommitted` kaldırıldı, yerine
SS20 alet doğrulaması geldi). Bunu da olduğu gibi yazıyoruz: her yeni kapı bir
kusur bulmak zorunda değil, ama bulduğunu saklamak yasak.

## 7. Dürüst sınırlar

- Ölçümler tek makine, tek derleyici, `-O1`; donanımlar arası
  normalleştirilmedi.
- 10M satır kademesi koşmadı (32-bit süreçte süre/bellek bütçesi).
- Sonuç kümesi tavanı bu kapıda maddelleştirilerek sınanmadı (bkz. §4).
- `ORDER BY` sıralama yığını tavanı (`ecLimit siralama yigini asildi`) bu
  kapıda zorlanmadı; 1M `ORDER BY` yalnız LIMIT'li yollarda ölçüldü.
- LIMIT'siz tam taramanın bellek davranışı ölçüldü ama **kök nedeni
  araştırılmadı**; akış (streaming) yoktur, sonuç kümesi bellekte kurulur.
- Tablo satırları hâlâ 4 KB sayfa yığınında, ikincil indeksler bellekteki
  `TVDbBTree` içindedir; bu kapı disk tabanlı indeks ölçmez (o iş
  `btree_disk` ve ileride `sql_index_scale` kapsamındadır).
