# VDB V3 - Performans Regresyon Sonuclari

Tarih: 2026-11-25
Kapsam: guncel calisma agaci vs HEAD baseline (ea535ce)
Platform: Windows (i386-win32, fpc 3.2.4), tek makine

## Amac ve durust cerceve

Amac, SKILL8 turunda aaca eklenen degisikliklerin performansi
yavaslatmadigini olcmektir. Ancak bu turda N kod degisikligi KALMADI:
calisma agaci ile HEAD arasindaki tek fark iki Turkce yorum blogudur
(VDbPageEngine.pas, VDbPageStore.pas). Yani iki ikili SEMANTIK OLARAK
AYNI kodu calistirir.

Bu nedenle bu olcum iki isi birden yapar:

1. Yorum degisikliginin performansa etkisi olmadigini gosterir.
2. Ayni kodun iki bagimsiz kosusunda olculen sapmayi (gurultu tabanini)
   ortaya koyar. Asagidaki "regresyon" isaretleri bu gurultunun
   gorunur halidir; kod kaynakli bir yavaslama oldugu IDDIA EDILMEZ.

Bu bir karsilastirmali benchmark degildir; baska donanimda farkli cikar.

## Yontem

- Olcum: `tests/bench_scale/bench_scale.lpr` (saf native fpc).
- Guncel agac: `-FuD:\veritabani` -> `build/tscC/bench_scale.exe`.
- HEAD: `git archive HEAD` -> `build/headperf` -> `build/tscH/bench_scale.exe`.
- Iki profil, her ikisi de iki agacta AYNI parametrelerle:
  - profA: `VDB_BENCH_VDB_DURABLE=1`, `VDB_BENCH_SQLITE_SYNC=FULL`
  - profB: `VDB_BENCH_VDB_DURABLE=0`, `VDB_BENCH_SQLITE_SYNC=NORMAL`
- Boyutlar: `"5000,100000"`. Kosular SERI (paralel yok).
- Her kosu: `SONUC: 19 PASS, 0 FAIL`, `EXITCODE=0`
  (`build/bcA.log`, `build/bcB.log`, `build/bhA.log`, `build/bhB.log`).
- Karsilastirma yalniz `vdb` motoru icin yapildi (SQLite degeri referans
  olarak ayni kosuda uretildi, karsilastirmaya katilmadi).
- Oran = guncel / HEAD. Oran > 1 guncel agacin daha YAVAS oldugunu
  gosterir. Esik: oran >= 1.10 -> "regresyon" olarak isaretlendi.
- 44 faz (22 faz x 2 boyut) karsilastirildi; p50 ve p95 ayri ayri.

## profA (tam dayaniklilik: VDB fsync/commit = SQLite FULL)

`KARSILASTIRILAN_FAZ=44 REGRESYON_P50=1 REGRESYON_P95=1`

Esigi asan tek faz:

| boyut | faz | n | guncel p50 | HEAD p50 | oran | guncel p95 | HEAD p95 | oran |
|---|---|---|---|---|---|---|---|---|
| 5000 | concurrent_writers | 50 | 54149 | 43735 | 1.24 | 54149 | 43735 | 1.24 |

Diger 43 fazin tamami 1.10 esiginin altinda; cogu 0.90-1.06 bandinda.
One cikan iyilesmeler (guncel daha hizli): tx_commit 5000 -> 0.78,
recovery_open 5000 -> 0.76, group_by 5000 -> 0.74.

## profB (dengeli: VDB fsync checkpoint'e ertelenir = SQLite NORMAL)

`KARSILASTIRILAN_FAZ=44 REGRESYON_P50=6 REGRESYON_P95=6`

Esigi asan fazlar:

| boyut | faz | n | guncel p50 | HEAD p50 | oran | guncel p95 | HEAD p95 | oran |
|---|---|---|---|---|---|---|---|---|
| 5000 | backup | 1 | 2723 | 1741 | 1.56 | 2723 | 1741 | 1.56 |
| 5000 | bulk_insert | 5000 | 41345 | 36577 | 1.13 | 41345 | 36577 | 1.13 |
| 5000 | recovery_open | 1 | 16494 | 9166 | 1.80 | 16494 | 9166 | 1.80 |
| 5000 | restore | 1 | 23996 | 13810 | 1.74 | 23996 | 13810 | 1.74 |
| 100000 | index_composite | 1 | 4125288 | 3469680 | 1.19 | 4125288 | 3469680 | 1.19 |
| 100000 | schema | 1 | 1737 | 1464 | 1.19 | 1737 | 1464 | 1.19 |

## Yorum (durust)

- Dort fazin `n` degeri 1'dir (backup, recovery_open, restore, schema):
  tek ornekten olculur, en gurultulu fazlardir. profA'da ayni fazlar
  0.76-1.02 bandinda cikarken profB'de 1.56-1.80 cikmasi, farkin kod
  degil zamanlama/onbellek/dosya sistemi kaynakli oldugunu gosterir.
- Iki agac SEMANTIK OLARAK AYNI oldugu icin, burada isaretlenen fazlardan
  hicbiri "gercek performans regresyonu" olarak sunulamaz. Dogru ifade:
  "olculen sapma, bu makinede tek kosuluk gurultu tabaninin sinirlari
  icindedir; kod kaynakli regresyon tespit edilmedi ve aranamaz, cunku
  karsilastirilan iki ikili ayni kodu calistirir."
- Ayni sekilde "hic regresyon yok" da iddia edilmez; n=1 fazlarda sapma
  olcumu bu makinede 1.5x'e kadar cikabilmektedir.
- VDB'nin SQLite'a gore mutlak yavasligi (orn. 100000 satirda join,
  range_scan, delete) bu raporun konusu DEGILDIR; eski `build/tsc/profA`
  olcumleri bu turda kullanilmadi.

## Olculmemis olanlar (NOT-RUN)

- Linux uzerinde ayni perf kosusu: NOT-RUN.
- Cok kosuluk (tekrar ortalamasi / guven araligi) olcum: NOT-RUN.
  Her faz icin tek kosu alinmistir.
- Farkli donanim / disk / isletim sistemi: NOT-RUN.
- Uzun sureli (2 saat) yuk altinda perf drift: NOT-RUN.
- Bellek profili ayri olcum: bench_scale S6 kapisi RSS/peak/heap degeri
  uretir, ancak karsilastirmali bellek regresyon analizi NOT-RUN.

## Tekrar uretme

```
build\mkheadperf.cmd
build\btscC.cmd
build\btscH.cmd
build\perfall.cmd
python build\cmpmd.py build\tscC\profA\bench_scale.csv build\tscH\profA\bench_scale.csv vdb
python build\cmpmd.py build\tscC\profB\bench_scale.csv build\tscH\profB\bench_scale.csv vdb
```
