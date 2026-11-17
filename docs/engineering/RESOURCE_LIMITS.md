# VDB V3 - Kaynak Sinirlari ve Kaynak Yonetimi (Sprint F)

Bu belge SKILL4 Sprint F'nin kaynak sinirlari kalemidir. **Sinir degerlerinin
tek kaynagi `docs/engineering/LIMITS.md`'dir**; burada ayni sayilar tekrar
edilmez, yalnizca (a) sinirin nerede ve nasil zorlandigi, (b) sinirin
**olculdugu** kapi, (c) sinir asildiginda veri butunlugunun ne oldugu ve
(d) bilinen acik riskler toplanir. Bir sayi ile bu belge celisirse
`LIMITS.md` gecerlidir.

Durus: **BETA CANDIDATE**. Bu belge bir kapasite planlama garantisi ya da
"sinirsiz olcekte calisir" iddiasi degildir. Olculen her sey asagida
kaynakli verilir; olculmeyen sey acikca "olculmedi" yazilir.

---

## 1. Kaynak siniri siniflari

VDB'nin kaynak tuketimi dort katmanda sinirlanir. Her katman **fail-closed**
davranir: sinir asildiginda is **reddedilir**, sessizce kirpilmaz veya
yarim yazilmaz. Tek istisna bilincli olarak isaretlenmistir (§4).

| Katman | Tipik sinir | Nerede zorlanir | Asimda |
|---|---|---|---|
| Sayfa/dosya | sayfa boyu, sayfa sayisi, DB boyu, islem basina degisen sayfa | `VDbPageStore.ExtendFile` / `GrowTo` / `MarkPageDirty` | `ecLimit` (commit edilmez) |
| WAL | sert tavan `VDB_WAL_MAX_BYTES` | `VDbPageEngine.DoCommit`, cerceveler tampondayken | `ecLimit`; onceki commit'ler durabil |
| SQL | cumle boyu, tek deger, sonuc satiri, indeks derinligi | `VDbSql.CheckStmtSize`, `VDbTypes.VDB_MAX_VALUE`, `TVdbExecutor` | `ecLimit` |
| Ag | baglanti sayisi, tek cerceve boyu, giris denemesi | `TVdbSqlServer`, `VDbPgWire`, `VDbNet.VdbRecvStr` | baglanti reddi / o baglanti duser |

Sinir degerleri, birimleri ve hata kodlari icin bkz. `LIMITS.md` §tablo.
Asagida yalnizca yonetim ve kanit katmani ele alinir.

---

## 2. Neden bu sinirlar var (tehdit -> sinir eslemesi)

| Tehdit | Sinirin cevabi |
|---|---|
| Kimligi dogrulanmamis istemci sahte uzunluk onekiyle sunucuda gigabayt ayirmasi | agdan gelen tek cerceve tavani (`VDBS_MAX_RECV_STR`); asimda yalniz o baglanti duser |
| Tek bir dev islemin WAL'i diski doldurup butun veritabanini kirletmesi | WAL sert tavani + islem basina degisen sayfa tavani; commit **onaylanmaz** |
| Cok buyuk bir `SELECT`'in sunucu bellegini tuketmesi | sonuc satiri tavani; asimda `ecLimit`, kismi sonuc donmez |
| Cok buyuk bir tek degerin sayfa/tasma zincirini bozmasi | `VDB_MAX_VALUE`; reddedilir |
| Baglanti firtinasi (DDoS-benzeri) | `MaxConns`; tavan asilinca yeni baglanti `kapasite dolu` alir, mevcutlar calismaya devam eder |
| Parola deneme firtinasi | `AuthMaxFailures` + pencere + kilit (monotonik saat, F-20) |
| Iki yazarin ayni sayfalari ezmesi | dosya basina **tek yazar rezervasyonu**; ikincisi `BusyTimeoutMs` bekler, sonra kontrollu `mesgul` |

Bu esleme `docs/security/THREAT_MODEL.md` ile ayni varsayimlari paylasir;
orada listelenen ve burada **karsiligi olmayan** tehditler §5'tedir.

---

## 3. Sinirin olculdugu yer (kapi eslemesi)

Sinir iddialari olcumsuz birakilmaz. Her satir bir kapinin gercekten
zorladigi bir yolu gosterir; sonuclar `docs/engineering/CI.md` run
log'larindadir.

| Sinir alani | Kapi | Ne olcer |
|---|---|---|
| Sayfa sayisi / DB boyu / islem basina sayfa | `limits` (18/0), `txn_limit` (18/0) | tavan asiminda `ecLimit`, sayfa sayisi gerilemesinde veri kaybi olmamasi (TL6/TL8) |
| WAL sert tavani | `wal_limit` (19/0) | commit'in tavanda reddedilmesi, onceki commit'lerin durabil kalmasi, yumusak esik/checkpoint iliskisi |
| SQL cumle/deger/sonuc | `limits` (18/0), `sql_features` (32/0) | cumle ve deger tavaninda `ecLimit`; sonuc tavani |
| Onbellek basinci | `cache_pressure` (8/0), `cache_metrics` (21/0) | havuz dolarken tahliye/WAL'e spill; olcum sayaclarinin gercekten hareketi |
| Disk dolu | `disk_full` (16/0) | yazma hatasinda commit'in onaylanmamasi, veri kaybi olmamasi |
| Bellek tukenmesi | `oom` (9/0) | ayirma sirasinda hata -> sayfa geri alma, bozuk sayfa birakmama (v3.42) |
| Ag cercevesi / baglanti | `net_fuzz` (39/0), `server_failure` (16/0) | 70000 / 2^31-1 startup, 64MB+1 cerceve, 40 kisa cop baglanti, sonrasinda sunucunun hizmet vermeye devam etmesi |
| Giris sinirlama | `auth_throttle` (16/0) | esik, kilit, pencere, `AuthReset`; monotonik saat |
| Uzun sureli kaynak sizintisi | `soak` (20/0) | heap (TotalAllocated deltasi, **RSS degil**), FD/sap, is parcacigi, WAL/dizin bayti, p50/p95; SO5-SO10 tavanlari |

**Kapilar iki platformda ayni sonucu verir**: Windows i386 42 kapi, Linux
x86_64 43 kapi (`tls_client` Windows'ta SKIP, OpenSSL istege bagli iki kapi
Linux'ta SKIP). `sql_differential` yine `pg=not-run`.

---

## 4. Bilincli olarak sinir koyulmayan / sessiz davranan yerler

Bunlar kusur degil, kayitli tercihtir; ancak kapasite planlamasinda
bilinmelidir.

- **Sayfa havuzu tavani sessiz clamp**: tavan ustu istek kirpilir, hata
  verilmez. Bellek guvenligi icin istek reddi yerine kucuk havuzla devam
  edilir (`LIMITS.md` §"Bilincli olarak SINIR KOYULMAYAN yerler").
- **Islem sayisi tavani yok**: sinirlayan sey baglanti tavani + tek yazar
  rezervasyonudur; ikinci yazar bekler, sonra `mesgul`.
- **Ic ice `BEGIN`, islem yokken `COMMIT`/`ROLLBACK` sessiz no-op**: ikinci
  bir islem katmani acilmaz; bu SQL uyumlulugu icin bilincli.
- **Gercek zamanli kaynak izleme (metrics endpoint) YOK**: olcum kapilarda
  ve `MetricsText`/`SHOW STATS` uzerinden yapilir; harici izleme entegrasyonu
  yoktur ve iddia edilmez.

---

## 5. Acik riskler ve olculmemis alanlar

Durust sinirlar; bunlar **kapatilmis degildir** ve kapatilmis gibi
sunulmaz.

1. **Uzun sureli soak kosulmadi.** `soak` kapisi varsayilan 25 sn kosar.
   Gercek 1 saat / 6 saat / 24 saat kosu **yapilmadi**. Bu yuzden "uzun
   surede kaynak sizmaz" iddiasi verilemez; yalnizca kisa kosuda SO5-SO10
   tavanlarinin asilmadigi olculdu.
2. **Ag sunucusu soak'i kapsam disi.** `soak` gomulu motordur. `TVdbPgServer`
   altinda cok baglantili, uzun sureli kaynak davranisi **olculmedi**.
3. **Kapasite olcegi sinirli.** En buyuk olculen tablo 1.000.000 satir
   (`sql_scale`, `sql_index_scale`). 1 TiB'a yakin dosyalar, 4096 baglanti,
   65 536 sayfalik havuz gibi **tavan degerlerin kendisi** olculmedi; tavan
   yalnizca kod yolunda zorlanir (`limits`/`wal_limit` yapay senaryolarla).
4. **Gecikme bir SLA degildir.** `soak` p50/p95 ve `bench_report`
   P50/P95/P99 degerleri bu makinede olculmustur; baska donanim/yuk altinda
   garanti edilmez.
5. **Heap olcusu RSS degil.** `soak` SO5 `TotalAllocated` deltasini olcer
   (allocator'in verdigi bellek), isletim sisteminin RSS'ini degil. Bu
   yuzden "RSS sizmaz" iddiasi yoktur.
6. **Disk tukenmesi kalici cozulmedi.** `disk_full` kapisi yazma hatasinda
   veri kaybi olmadigini olcer; ancak disk dolduktan sonra operasyonun nasil
   toparlanacagi (operator mudahalesi) bu belgenin kapsami disidir.
7. **Es zamanli yazar olcegi.** Tek yazar rezervasyonu modeli olculen
   davranistir (`multi_writer` 12/0, `multiproc` 17/0); cok yazarlı yuksek
   cakisma oraninda gecikme davranisi olculmedi.

---

## 6. Degisiklik yaparken uyulacak kural

Bir sinir degeri ya da sinirin zorlandigi yol degisirse:

1. `LIMITS.md` (tek kaynak) guncellenir.
2. Ilgili kapi (`limits`, `wal_limit`, `txn_limit`, `disk_full`, `oom`,
   `net_fuzz`, `server_failure`, `auth_throttle`, `cache_pressure`) yeni
   davranisi **olcen** bir kontrol kazanir; kapi zayiflatilmaz.
3. Bu belgedeki esleme ve acik riskler yeniden degerlendirilir.
4. `CHANGELOG.md` ve `docs/engineering/CI.md` run log'u guncellenir.

Kapilarin hepsi gecmeden sinir degisikligi "tamam" sayilmaz.
