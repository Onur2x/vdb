# VDB V3 - Hizlandirilmis Dayaniklilik Raporu (SKILL8)

Tarih: 2026-11-25
Kapsam: hizlandirilmis dayaniklilik kapilari (crash, islem, freelist, kirli
cerceve, fazli soak)
Platform: Windows (i386-win32, fpc 3.2.4)
Baz alinan surum: HEAD `ea535ce` (= `origin/main`)

## 1. Ozet (durust)

Kisa ve orta vadeli kapilar YESIL, tek uzun sureli kapi KIRMIZI:

| Kapi | Kapsam | Sonuc | Kanit |
|---|---|---|---|
| Tam kapi seti | 72 kapi | 68 PASS / 4 SKIP / 0 FAIL | `build/gates15.log` |
| Crash stress | 100 zorla sonlandirma | 101 PASS / 0 FAIL | `build/c100.log` |
| Islem stress | 1000 islem dongusu | 34 PASS / 0 FAIL | `build/tx1000.log` |
| Freelist repro | 1200/1500/4000 tur | fark=0, cift kayit=0 | `build/f30.log`, `build/f31.log`, `build/f33.log` |
| Kirli cerceve | 5 kontrol | 5 PASS / 0 FAIL | `build/dr_fix2.log` |
| Fazli soak | 900 s (kisaltilmis) | **FAIL** (T2/T4/T6/T7) | `build/soakS.log`, `build/soakH900.log` |
| Fazli soak | 7200 s (planlanan) | **FAIL** (concurrency fazi) | `build/soak2h.log` |

**Sonuc: urun "tam dayanikli" ILAN EDILMEZ.** Coklu yazici ile calisan uzun
sureli is yuku altinda freelist tutarsizligi olusmaktadir. Bu kusur bu
calismada DUZELTILMEDI (bkz. bolum 5).

## 2. Yontem

- Tum kosular saf `fpc` ile derlenen native ikililerle yapildi; harici DLL,
  veritabani motoru veya ucuncu taraf bagimlilik YOKTUR.
- Kosular SERI yapildi (ayni anda tek olcum); paralel olcum yoktur.
- Surecler arasi yarisa karsi her test kendi izole gecici dizininde kosar;
  kullanicinin gercek veritabani dosyalarina dokunulmaz.
- Olcumler `GetTickCount` tabanlidir (mikrosaniye); tek makine, tek disk.

## 3. Kapilarin ayrintisi

### 3.1 Tam kapi seti

`tests/run_gates.sh` ile 72 kapi derlenip kosuldu: 68 PASS, 4 SKIP, 0 FAIL
(`SUITE_EXIT=0`). SKIP nedenleri ortam eksikligidir, kapi hatasi degildir:

- `pg_client_matrix`: gercek PostgreSQL istemcisi bulunamadi.
- `fixtures_openssl`, `selftest_openssl`, `tls_client`: `VDB_CRYPTO_DLL`
  tanimli degil.

SKIP edilen kapilar PASS SAYILMAZ; bu dort kapi bu raporda dogrulanmamis
kabul edilir.

### 3.2 Crash recovery stress

`tests/crash_stress` 100 dongu: 60 commit oncesi, 20 commit sonrasi, 20
checkpoint icinde sonlandirma. Her dongude kurtarma sonrasi anahtar sayisi
beklenen ile ayni (30/30), `Verify` temiz, dosya yeniden yazilabilir.
Ayrintili rapor: `CRASH_RECOVERY_STRESS_REPORT.md`.

### 3.3 Islem stress

`tests/tx_stress` 1000 dongu: atomiklik, izolasyon, PK ihlali, ifade hatasi,
cakisma. 34 PASS / 0 FAIL; commit p50 = 1275 us, p95 = 1855 us,
max = 3434 us; rollback p50 = 187 us; izolasyon ihlali = 0.
Ayrintili rapor: `TRANSACTION_STRESS_REPORT.md`.

### 3.4 Freelist repro (iki oturum)

Iki oturumlu silme/ekleme dongusu: 1200, 1500 ve tek oturumlu 4000 tur.
Tumunde `fark=0`, `KUME_FARKI` 0/0, `CIFT_KAYIT n=0`, `canli_hucre=0`,
`VERIFY` temiz.

NOT: Ayni repro HEAD uzerinde de temiz gecmektedir. Yani bu test, incelenen
kusurlar icin AYIRT EDICI bir kapi degildir; yalniz regresyon nobetcisidir.

### 3.5 Kirli cerceve kapisi

`tests/dirty_refresh`: A oturumu flush etmeden commit eder (cerceve kirli
kalir), B oturumu ayni sayfayi silip diske indirir, A tam tazeleme yapip
ayni sayfaya yazar. Beklenen: B'nin silmesi geri gelmez. Sonuc 5/5 PASS.
Bu kapinin once/sonra ayrimi uretilemedigi icin kapi "mevcut davranisi
kilitler", "duzeltmeyi kanitlar" diye sunulmaz.

### 3.6 Fazli soak (KIRMIZI)

Iki asamali dogrulama yapildi:

1. 7200 s planli kosu (`build/soak2h.log`) concurrency fazinda 3 hata verdi
   (freelist tutarsizligi, yazma sayfasi okunamadi, WAL kimligi
   dogrulanamadi) ve durduruldu.
2. Ayni kusurun kaynagini ayirmak icin 900 s'lik kisaltilmis kosu iki kez
   yapildi: guncel agac (`build/soakS.log`) ve HEAD (`build/soakH900.log`).

Sonuclar:

```
GUNCEL AGAC (900 s):
FAIL T2 eszamanli is parcacigi 0 - freelist bozuk: freelist trunk sihirli
     sayisi bozuk
FAIL T2 eszamanli is parcacigi 1 - yazma sayfasi okunamadi
FAIL T4 hizli=1616 tarama=2865 distinct=2865
FAIL T6 once=1616 sonra=2865
FAIL T7 once=1186703 sonra=1193006
SOAK_EXIT=217

HEAD (900 s):
FAIL T2 eszamanli is parcacigi 0 - freelist bozuk: freelist trunk sihirli
     sayisi bozuk
FAIL T2 eszamanli is parcacigi 1 - freelist bozuk: freelist trunk sihirli
     sayisi bozuk
FAIL T2 eszamanli is parcacigi 2 - WAL veritabani kimligi dogrulanamadi
PASS T4 hizli=3189 tarama=3189 distinct=3189
PASS T6 once=3189 sonra=3189
PASS T7 once=1419136 sonra=1419136
SOAK_EXIT=217
```

Yorum:

- Freelist bozulmasi **HEAD'de de vardir**; bu calismada eklenen
  degisikliklerin urunu degildir.
- Guncel agacta satir sayisinin tutarsiz olmasi (1616 / 2865) bu turda
  denenen `LoadMeta` monoton degisikliginin etkisidir; degisiklik geri
  alinmistir (bkz. bolum 5).
- Hicbir asamada "veri kaybi yok" denmez. Kanit veritabani dosyasi
  (`build/soak_fail_evidence/tmp/`) `vdbcheck --full` ile TEMIZ cikti
  (`sayfa=50 serbest=0 heap=49 tasma=0 trunk=0 anahtar=4600`), yani
  bozulma kalici dosyada degil, calisma zamani bellekteki freelist
  gorunumundedir. Bu, cift tahsis riski demektir ve veri kaybi riski
  olarak raporlanir.

## 4. Denenen ve geri alinan sertlestirmeler

Bu turda iki kod degisikligi denendi; ikisi de geri alindi. Agac, davranis
olarak HEAD ile aynidir; kalan fark yalnizca aciklayici yorumlardir.

### 4.1 `DropCacheAll` (tam tazelemede kirli cerceveleri de at)

- Motivasyon: tam tazeleme yolunda `DropCache` kirli cerceveleri tutuyor;
  bu oturumun eski imaji, dosyadaki daha yeni imajin uzerine yazilabiliyor.
- Denendi: `tests/dirty_refresh` 5/5 PASS verdi.
- Ancak tam kapi setinde `bench_report` kapisi kirmizi oldu
  (`gates14`): "sema yazimi reddedildi: diskteki 4 tablodan 1 tanesi
  listeden kayboldu (lc)". Kok neden: sema katmani store tazelemesinden
  haberdar edilmiyor; tazeleme sonrasi diskte 4 tablo, bellekte 3 tablo
  kalinca DDL reddediliyor.
- Geri alindi. Guvenli cozum sema tazeleme mimarisi gerektirir; bu
  calismanin kapsami disindadir.

### 4.2 `LoadMeta` monoton sayfa sayaci

- Motivasyon: tazeleme sirasinda sayfa sayacinin geri dusmesi ve ayni
  sayfanin yeniden tahsisi.
- Denendi: hedeflenen kusur hicbir kosuda deterministik olarak
  uretilemedi (HEAD de temiz gecti).
- Buna karsilik coklu yazici soak'unda satir sayisi tutarsizligini
  KOTULESTIRDI (guncel agac T4/T6/T7 FAIL, HEAD PASS). Nedeni: sayfa
  sayaci yerelden, freelist basi ise bayat diskten okunuyor; meta tek
  tutarli anlik goruntuden gelmiyor.
- Geri alindi.

## 5. Bilinen sinirlar (acik)

1. **Coklu yazici freelist tutarsizligi (ACIK, onceden mevcut).** Uzun
   sureli es zamanli yazma yukunde `freelist trunk sihirli sayisi bozuk`
   ve `sayfa N serbest listede ama M canli hucre tasiyor` hatalari olusuyor.
   HEAD'de de tekrarlanir. Duzeltilmedi.
2. **Sema tazeleme boslugu (ACIK, onceden mevcut).** Ikinci bir oturum
   tablo yaratip kapandiktan sonra birinci oturum DDL yazarsa, sema kaydi
   bayat onbellekten okunup yeni tablo semadan dusurulebilir. `DropCacheAll`
   bu durumu gorunur kiliyor ama sema katmani tazelenmedigi icin cozmuyor.
3. **Kirli cerceve yolu.** Tam tazelemede kirli cerceve korunur; WAL
   kurtarma cogu durumda daha yeni imaji geri kurar (`dirty_refresh` 5/5
   PASS), ancak WAL'de kurtarilacak kare kalmadiginda koruma yoktur.
4. Kapsam disi: isletim sistemi cokmesi, guc kesintisi, disk denetim hatasi
   (bit rot), 2 saatten uzun soak, 24 saatlik dayaniklilik iddiasi, cok
   buyuk veri hacminde kurtarma suresi.

## 6. Tekrar uretme

```
build\bfre.cmd
build\tfre\freelist_repro.exe seq

build\bdr.cmd
build\tdr\dirty_refresh.exe

build\bcrash.cmd
build\tcrash\crash_stress.exe 100

build\btx.cmd
build\ttx\tx_stress.exe 1000

build\bsoak.cmd
build\tsoak\soak_phased.exe            (mod: phased, VDB_PHASED_SECONDS)

C:\PROGRA~1\Git\bin\bash.exe build\sg15.sh   (tam kapi seti)
```

Sayilarin ham kaynagi `build/` altindaki loglardir; bu dizin surum
kontrolune DAHIL EDILMEZ.
