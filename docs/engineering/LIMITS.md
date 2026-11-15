# VDB V3 - Isletim Sinirlari ve Kaynak Yonetimi

Bu belge SKILL2 §25 ve SKILL3 §12'nin istedigi **acik sinirlari** listeler.
Kural: her sinir asildiginda motor **kontrollu** `EVDbException` dondurur
(`ecLimit` / `ecIOError` / `ecCorrupt`), surec cokmez ve veritabani dosyasi
gecerli kalir. Sinir denemelerinden sonra ayni veritabani normal calismaya
devam eder; bunu `tests/limits` kapisi olcer (18 kontrol).

| Sinir | Deger | Nerede zorlanir | Hata |
|---|---|---|---|
| Sayfa boyu | 4096 B (sabit) | `VDbPage.pas` `VDB_PAGE_SIZE` | - |
| Sayfa sayisi | 16 777 215 (`$00FFFFFF`) | `VDbPageStore.ExtendFile` | `ecLimit` |
| Veritabani boyu | 1 TiB | `VDbPageStore.ExtendFile` + `GrowTo` | `ecLimit` |
| Tek islemde degisen sayfa | 1 048 576 | `VDbPageStore.MarkPageDirty` | `ecLimit` |
| WAL boyu | turetilmis: 8 MB esik + 4 GiB (islem tavani x 4096) | `MaybeCheckpoint` (8 MB'de checkpoint) + islem tavani | - |
| Tek SQL cumlesi | 4 MiB | `VDbSql.CheckStmtSize` (`Exec`, parametreli `Exec`, `ExecRaw`) | `ecLimit` |
| Tek deger | 16 MiB | `VDbTypes.VDB_MAX_VALUE` (API `Put` yolu) | `ecLimit` |
| Sonuc satiri | 2 000 000 | `VDbExecutor` cikti buyume yollari + LIMIT/JOIN/DISTINCT | `ecLimit` |
| Onbellek (sayfa havuzu) | varsayilan 512, tavan 65 536 (=256 MB) | `VDbPageStore` clamp | sessiz clamp |
| Baglanti (sunucu) | varsayilan 64, ayar araligi 1..4096 | `VDbSqlServer`, `VDbPgWire` | baglanti reddi |
| Agdan gelen tek cerceve | 64 MiB | `VDbNet.VdbRecvStr` (`VDBS_MAX_RECV_STR`) | baglanti duser |
| Indeks derinligi | skiplist 62 seviye; B+Tree dengeli | `VDbSkipList` | - |
| Es zamanli islem | oturum basina 1 acik islem (ic ice `BEGIN` sessiz no-op); dosya basina 1 yazar rezervasyonu | `VDbBackendV3.BeginBatch` + `VDbPageStore` kilit modeli | busy suresi asilirsa `mesgul` (`EVdbPageStore`) |

**Onbellek tukenmesi bir hata degildir.** Havuz tablodan kucuk oldugunda
motor sayfa tahliye eder (kirli sayfa WAL'e dokulur) ve sonra yeniden
yukler; bu yol `tests/cache_pressure` kapisi ile olculur (8 sayfalik havuz,
~100 sayfalik tablo, tam tarama + tek islemde toplu guncelleme + yeniden
acilis).

**Bozuk sayfa bir hata turudur, sessiz gecmez.** Normal okuma yolu her
sayfa imajini dogrular (`CheckReadImage`): freelist trunk sayfalari atlanir,
yeni uzatilmis bos sayfaya izin verilir; sihirli sayi taninmiyorsa ya da
basliktaki sayfa numarasi istenenden farkliysa `ecCorrupt`; CRC ise
`VerifyOnRead` (varsayilan acik) iken denetlenir. Yani diskteki tek bozuk
bayt yanlis satir uretmek yerine kontrollu hata verir. `tests/page_corrupt`
kapisi bunu her veri sayfasinda olcer.

**Disk dolu kontrollu bir hatadir, sessiz veri kaybi degil.** Tum disk
yazmalari tek noktadan gecer (`WriteBytesChecked`; WAL icin `WriteChecked`):
`THandleStream.Write` kisa yazmayi 0'a cevirdigi icin yarim yazma acikca
algilanir ve kontrollu `ecIOError` uretilir; enjekte edilebilen hata yolu da
ayni noktadadir. Dosya buyutme (`GrowTo`) basarisiz olursa mantiksal boy
artirilmaz. Hata aninda sayfa cercevesi **kirli** kalir (temiz isaretlenip
veri kaybolmaz), islem `ROLLBACK` ile temizlenir, hata giderilince checkpoint
ve yeni commit calisir. WAL commit kaydi yazilamazsa kesik kuyruk geri
kirpilir ve commit **hayalet satir** birakmaz: ayni oturumda `COUNT(*)` de,
yeniden acilis da durabil satir kumesini gosterir. `tests/disk_full` bunu
sayfa, meta ve WAL yazmalarinda sert hata + yarim yazma senaryosuyla olcer
ve yeniden acilista tum onayli satirlari + `VERIFY` temizligini dogrular.

**Meta sayfa monotoniktir.** Iki oturum ayni dosyaya yazdiginda geride kalan
(gorunume gore bayat) oturumun `SaveMeta` cagrisi diskteki **daha yuksek** LSN
ve sayfa sayisini geri alamaz: yazmadan once diskteki meta okunur ve `LSN`
ile `FPageCount` yalnizca **yukari** tasinir. Aksi halde LSN gerilemesi
dosyayi `EVdbPageStale` ile okunamaz hale getiriyor, sayfa sayisi gerilemesi
ise kapanistaki `TrimToLogical` ile onayli sayfalari kirpiyordu (veri
kaybi). `tests/txn_limit` (TL6/TL8) bu yolu olcer.

**Sunucu tarafinda iki sinir var.** Baglanti sayisi `MaxConns` ile
sinirlidir (varsayilan 64, ayar araligi 1..4096); tavan asilirsa yeni
baglanti `RSP_ERROR` + `kapasite dolu` alir ve kapanir, mevcut baglantilar
calismaya devam eder. Agdan gelen tek bir metin cercevesi ise
`VDBS_MAX_RECV_STR` (64 MiB) ile sinirlidir: bu, kimligi dogrulanmamis bir
istemcinin sahte uzunluk onekiyle sunucuda gigabaytlar ayirmasini onler.
Asimda yalniz o baglanti duser; sunucu ve veritabani dosyasi etkilenmez.
`tests/server_failure` kapisi bu yollarin hepsini olcer.

## Bilincli olarak SINIR KOYULMAYAN yerler

- **Onbellek tavani sessiz clamp**: `APoolPages > VDB_MAX_POOL` istegi
  kirpilir, hata verilmez. Bu bir bellek guvenligi siniri; istek reddi
  yerine kucuk havuzla devam etmek daha az surpriz uretir.
- **WAL sert tavani yok**: 8 MB'de checkpoint tetiklenir; acik islem ya da
  kilit nedeniyle checkpoint ertelenirse WAL buyumeye devam eder. Ust sinir
  islem tavaniyla turetilir (en kotu durum ~4 GiB). Bu davranis bilinclidir:
  sert bir WAL tavani, mesru uzun islemleri commit aninda reddederdi.
- **Islem sayisi tavani yok; sinirlayan kaynak yazar rezervasyonu**:
  es zamanli islem sayisi baglanti tavaniyla sinirlidir ve dosya
  basina **tek yazar rezervasyonu** vardir. Bir oturum yazarken digeri
  `BusyTimeoutMs` kadar bekler; sure asilirsa kontrollu `mesgul` hatasi alir
  (veri kaybi yok, islem `ROLLBACK` ile temizlenir, rezervasyon birakilinca
  yeniden denenebilir). Oturum basina en fazla bir acik islem vardir: ic ice
  `BEGIN`, islem yokken `COMMIT` ve `ROLLBACK` **sessiz no-op**'tur; ikinci
  bir islem katmani acilmaz. `tests/txn_limit` bunu 300 kisa islem, 75
  geri alma ve yazar cakismasi senaryosuyla olcer.

## Kapanis (SKILL2 §25.3)

`TVdbPageEngine.Close` sirasi:

1. Yeni is kabul edilmez (nesne kapaniyor).
2. Acik islem varsa commit edilmemis sayfalar atilir (WAL'de onay yok).
3. Checkpoint calisir; basarisizsa yan dosyalara **dokunulmaz**.
4. Checkpoint basariliysa ve ayni surecte ayni dosyaya acik **baska oturum
   yoksa** `.wal`/`.gen` silinir (tek dosya sozlesmesi).
5. Dosya kilidi ve tutamaklar birakilir.

Kapanis hatalari yutulmaz: checkpoint sonucu `False` ise yan dosyalar
korunur, yani veri kaybi yerine "fazladan dosya" tercih edilir. Bu yolu
`tests/single_file`, `tests/multi_writer` (MW2/MW4) ve `tests/crash_points`
olcer. **Sunucu kapanisi** (`VDbSqlServer.Stop`) ayri bir kapiyla
olculmuyor; bu belgede sinir olarak kayitli.
