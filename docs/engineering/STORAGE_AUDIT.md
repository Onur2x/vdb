# Depolama mimarisi denetimi (SKILL2 §18-27)

Bu belge `VDB_V3_PRODUCTION_HARDENING_SKILL2.md` icin yapilan **zorunlu depo
denetimini** (§18.1) ve **kabul matrisini** (§27) kaydeder. Kural: her satir
icin **kanit** yazilir; kanit yoksa "YOK" yazilir, tahmin yazilmaz.

Tarih: 2026-11-14. Kapsam: v3 sayfa motoru (`VDbPageStore`, `VDbPageWal`,
`VDbPageHeap`, `VDbPageEngine`, `VDbBackendV3`). v2 (`VDbCore`) donmus ve
salt-okunur; bu belgenin konusu degil.

---

## 1. §18.1 Zorunlu envanter

Skill "`VDbPageStore.pas` `.odb` yaziyor diye tek dosya varsayma" diyor.
Asagidaki tablo her bilesenin gercekte nerede oldugunu gosterir.

| Bilesen | Dosya | Ne yapiyor | Kanit |
|---|---|---|---|
| Sayfa deposu | `VDbPageStore.pas` | baslik sayfasi 0, sabit 4 KB sayfalar, CRC32, pool, freelist, dosya buyutme | `VDB_PAGE_SIZE=4096`, `VDB_FILE_VER=5`, `SaveMeta`, `NewPageNo`, `GrowTo` |
| WAL | `VDbPageWal.pas` | commit basina degisen sayfa imaji, geri alma/uygulama, Truncate | `TVdbPageWal.Create(ADbPath + '.wal')`; `Recover`, `Truncate` |
| Sayfa onbellegi | `VDbPageStore.pas` | cerceve havuzu + hash, pin/release, kirli sayfa takibi, saat (clock) tahliye | `TFrame`, `FPoolPages`, `FEvictions`, `TxnMark` |
| B+Tree | `VDbBTree.pas` | silme yeniden dengeleme, invariant kontrolu | `DeleteRec`, `RebalanceChild`, `CheckInvariants` |
| Islem yoneticisi | `VDbPageEngine.pas` | `BeginTxn`/`Commit`/`Rollback`, checkpoint, kurtarma | `Commit`, `Checkpoint`, `ApplyRecovered` |
| Checkpoint | `VDbPageEngine.pas` | kirli sayfalari WAL'e ve dosyaya yazar, WAL'i budar | `Checkpoint`, `FDurableLsn` |
| Kurtarma | `VDbPageEngine.pas` | acilista WAL replay, kesik kuyruk tespiti | `Open`, `WalRecoveryWarning` |
| Acma/olusturma | `VDbFactory.pas`, `VDbPageStore.pas` | dizin -> `veritabani.odb`; baslik dogrulama | `VdbOpen`, `VdbResolveFile`, `:1035-1071` |
| Degisim gunlugu | `VDbChangeLog.pas`, `VDbBackendV3.pas` | PITR/replikasyon segmentleri (`.log/` + `.gen` taban imaji) | `VDBLOG_DIR_SUFFIX='.log'`; `ChangeLogEnabled` (varsayilan **False**) |
| Surecler-arasi sayac | `VDbPageStore.pas` | `.gen`: degisiklik sayaci, durabil LSN, DB kimligi, bayt-aralik kilit bolgesi | `VDB_GEN_SIZE=24`, `VDB_GEN_SCOPE_OFF=24`, `VDbLockGenReserve` |
| Kapanis/temizlik | `VDbPageEngine.Close`, `VDbPageStore.Close` | checkpoint, WAL kapat, `.idx`/`.wal`/`.gen` sil | `DropSideFiles`, `FDropGenOnClose` |
| Yedek/geri yukleme | `VDbBackendV3.BackupTo`, `VerifyBackup` | tek dosyalik tutarli kopya | `tests/backup_restore` 25/0 |
| Dosya kilidi | `VDbSync.pas` | `flock`/`LockFileEx` ile paylasimli/disarida tutma | `VDbLockStream`, `VDbLockHeld` |

**Sonuc:** depo tek bir `.odb` dosyasina yazar; kalici veri oradadir. Yan
dosyalar (`.wal`, `.gen`) **calisma durumu**dur ve temiz kapanista silinir
(`ON_DISK_LAYOUT.md`). `.log/` yalniz `ChangeLogEnabled=True` iken olusur.

---

## 2. §18.2 Iki mod

| Mod | Skill'in istedigi | Bu depoda |
|---|---|---|
| Gomulu tek dosya | varsayilan; `database.odb` | **VAR** — kalici durum tek dosya (PHASE-9). Acikken `.wal` + `.gen` yaninda durur (WAL ayrimi bilincli) |
| Yonetilen depolama | `database/` + `wal/` + `storage/` | **YOK** — ayri dizin duzeni, segment rotasyonu ve coklu taban imaji uygulanmadi. Ihtiyac halinde `BACKUP TO` + harici arsivleme kullanilir |

Yonetilen mod **uygulanmadi** ve kullanici zorlanmiyor; skill de bunu
"optional advanced mode" olarak tanimliyor.

---

## 3. §18.3 Tek dosya gereksinimleri

| Gereksinim | Durum | Kanit / not |
|---|---|---|
| Sayfa tabanli | VAR | 4 KB, `VDB_PAGE_MAGIC` |
| Rastgele sayfa okuma/yazma | VAR | `ReadPageAt`/`WritePagesAt` |
| Acilis tum dosyayi RAM'e almaz | VAR | cerceve havuzu; `VDB_DEF_POOL=512` (2 MB) |
| Buyuk DB oransal RAM istemez | VAR | havuz sabit, `VDB_MAX_POOL=65536` (256 MB) ust sinir |
| Sayfa onbellegi aktif | VAR | `TVDBStoreStats` sayaclari |
| Tek dosya ugruna dayaniklilik bozulmadi | VAR | WAL hala ayri yazilir; `wal_crash` kapisi |
| Dosya buyumesi kontrollu | KISMI | `VDB_GROW_BYTES=262144` ile buyur; **otomatik kucultme yok** (`VACUUM` gerekir) |
| Format surumlu | VAR | `VDB_FILE_VER=5`, v3/v4 kabul |
| Yazarlar arasi kilit | VAR | `VDbLockStream` (exclusive) |
| Kapanista tum handle/kilit birakilir | VAR | `Close` sirasi (`ON_DISK_LAYOUT.md` §3) |
| Yeniden acilis tutarli durum | VAR | `single_file` SF6/SF9 |
| Surec sonlandiktan sonra kurtarma | VAR | `wal_crash`, `kv_wal` |
| Yarim yazimdan sonra kurtarma | VAR | `wal_crash` t2/torn-tail |
| Bozulma tespiti ve raporu | VAR | `VERIFY` + CRC32 |
| Bozulmayi **sessizce onarmama** | VAR | `VERIFY` yalnizca reddeder (`PAGE_INTEGRITY.md`) |

---

## 4. §19 WAL, checkpoint, kurtarma

`WAL_RECOVERY_AUDIT.md` WAL kayit bicimi, CRC, commit kaydi ve siralama
kurallarini yaziyor. Asagida skill'in istedigi **10 cokme noktasi** icin
mevcut kapsam:

| # | Cokme noktasi | Kapili mi | Kapi / senaryo |
|---|---|---|---|
| 1 | Islem basi | VAR | `wal_crash` t1b |
| 2 | Sayfa degisikligi (henuz commit yok) | VAR | `wal_crash` t6 (uygulanmamis kalir) |
| 3 | WAL kaydi yazimi | VAR | `wal_crash` t2 (kesik kayit) |
| 4 | WAL flush | VAR | `wal_crash` t1 (flush sonrasi kurtarma) |
| 5 | Commit kaydi yazimi | VAR | `wal_crash` t2/t7 |
| 6 | Commit kaydi flush | VAR | `crash_points` commit-6 (PRE_SYNC) / commit-7 (POST_SYNC) |
| 7 | Checkpoint basi | VAR | `crash_points` cp-1 (`CP_BEGIN`) |
| 8 | Checkpoint sayfa yazimi | VAR | `crash_points` cp-2 (`CP_BEFORE_FLUSH`) / cp-3 (`CP_AFTER_FLUSH`) |
| 9 | Checkpoint tamamlanmasi | VAR | `crash_points` cp-3 / cp-5 (`CP_DONE`) |
| 10 | WAL budama (Truncate) | VAR | `crash_points` cp-4 (`CP_AFTER_TRUNC`) |

**G1 KAPATILDI.** `tests/crash_points` (24 kontrol) checkpoint ve commit'in
**icine** enjeksiyon noktalari koyar (`VDB_CRASH_STAGE_*` +
`TVdbPageEngine.CrashAtStage` / `OnCrashPoint`) ve cocuk surecte gercek surec
olumu yapar (`SIGKILL` / `TerminateProcess`; `Close()` hic calismaz).
Enjeksiyon uretimde `0` (kapali) kalir; kanca atanmazsa motor **acik hata**
verir (`EVdbPageEngine`), sessiz devam etmez. Her noktadan sonra: yeniden
acilis, `VERIFY` temiz, onayli commit'ler duruyor (commit-6 icin kayip
serbest, tutarsizlik yasak), DB hala yazilabilir.

### §19.3 WAL yonetimi

| Kural | Durum |
|---|---|
| Sinirsiz WAL buyumesi yok | KISMI — checkpoint'te budanir; **boyut tavani yok**, cok uzun tek islem WAL'i buyutur |
| Yanlis budama yok | VAR — budama yalniz checkpoint sonrasi, `FDurableLsn` ile |
| Onayli commit kaybi yok | VAR — `wal_crash` + `backup_restore` |
| Ayni islemin iki kez uygulanmasi yok | VAR — `wal_crash` t6 (idempotent) |
| Kurtarma dongusu yok | VAR — kurtarma tek gecis |
| Bozuk checkpoint meta | VAR — baslik CRC |
| WAL segmentlerinin guvensiz silinmesi | VAR — v3'te segment rotasyonu yok; `.wal` yalniz **bosken** (4096 B) silinir |

---

## 5. §20 Sayfa onbellegi

| Gereksinim | Durum | Kanit |
|---|---|---|
| Ayarlanabilir boyut | VAR | `TVdbBackendV3.Create(APoolPages)`, 8..65536 |
| Hit/miss sayaci | VAR | `PageHits`, `PageMisses` |
| Pin/unpin | VAR | `Pins`, `GetPage`/`Release` |
| Kirli sayfa takibi | VAR | `Dirty`, `TxnMark`, `FTxnDirty` |
| Tahliye politikasi | VAR | clock (saat) — `FClock`, `FEvictions` |
| Kirli sayfa flush | VAR | `Checkpoint`/`Spill` |
| Gecersizlestirme | VAR | `RefreshIfStale`, `FViewLsn` |
| Eszamanli erisim | VAR | `FPageCs` + kilit |
| Bellek limiti | VAR | `VDB_MAX_POOL` |
| Metrik yayini | VAR | `GetCacheStats` -> `MetricsText` + `SHOW STATS`, `tests/cache_metrics` 21/0 |

### §20.2 Metrikler

`TVdbBackendV3.MetricsText` (Prometheus bicimi) sunlari veriyor:
`page_cache_hits_total`, `page_cache_misses_total`, `page_cache_pages`,
`page_cache_used`, `page_reads_total`, `page_writes_total`,
`page_evictions_total`, `wal_commits_total`, `checkpoints_total`,
`checkpoint_last_ms`, `checkpoint_duration_ms_total`, `wal_torn_tail` ve
G2 ile eklenenler: `page_cache_hit_ratio` (0..1, dort ondalik),
`page_cache_dirty_pages` (kirli cerceve sayisi), `page_flushes_total`,
`page_flush_pages_total`, `page_flush_last_ms`,
`page_flush_duration_ms_total`.

Ayni degerler `SHOW STATS` ciktisinda satir olarak da var: `cache_hits`,
`cache_misses`, `cache_hit_ratio`, `cache_pool_pages`, `cache_pool_used`,
`cache_dirty_pages`, `page_flushes`, `page_flush_pages`,
`page_flush_last_ms`, `page_flush_duration_ms_total`. Motor bunlari
`IVDbBackend.GetCacheStats` (`TVdbCacheStats`) uzerinden yayinlar; v2
`Supported=False` doner (v2'nin sayfa cerceve onbellegi yoktur, kendi okuma
onbellegi ayri raporlanir).

`tests/cache_metrics` (21 kontrol) metriklerin **gercekten hareket
ettigini** kanitlar: okuma trafigi hit/miss sayaclarini artirir; yazidan
sonra kirli sayfa > 0, checkpoint'ten sonra = 0; checkpoint flush sayacini
ve yazilan sayfa sayisini artirir; flush suresi mantiklidir (toplam >= son);
hit ratio aritmetigi `hits/(hits+misses)` ile uyusur; Prometheus ciktisi ve
`SHOW STATS` ayni gercek degerleri tasir. Sayaclar oturumluktur (yeniden
acilista sifirdan baslar). **G2 KAPATILDI.**

### §20.3 Tek dosya performansi

`perf_baseline` kapisi (16/0) tam dosya taramasi yapilmadigini, ekleme
suresinin karesel bozunmadigini olcuyor. "Tum dosyayi yeniden yazma" yok
(checkpoint yalniz kirli sayfalari yazar).

---

## 6. §21 Eszamanlilik ve kilitleme

| Gereksinim | Durum | Kanit |
|---|---|---|
| Izolasyon seviyeleri belgeli | **YOK** | yazili bir izolasyon belgesi yok (G3) |
| Kilit alma sirasi belgeli | KISMI | `AcquireDataWrite`/`AcquireDataRead` var; sira belgesi yok |
| Deadlock tespiti | YOK | tek yazar kilidi; deadlock beklenmiyor ama tespit yok |
| Islem zaman asimi | KISMI | `BusyMs` bekleme siniri var; islem suresi siniri yok |
| Windows kilidi | VAR | `LockFileEx` |
| Linux kilidi | VAR | `flock` |
| macOS kilidi | **DENENMEDI** | ayni POSIX yolu; macOS derlemesi hic kosmadi |
| Coklu okuyucu | VAR | paylasimli kilit |
| Celisen yazar engeli | VAR | exclusive kilit |
| Kilit sahipligi takibi | KISMI | `VDbLockHeld`, `FExclusiveAccess` |
| Normal kapanista birakma | VAR | `Close` |
| Surec olumu kalici kilit birakmaz | VAR | isletim sistemi kilitleri (handle kapaninca duser) |
| Kilit hatasi acik | VAR | `VDB_SOCK_INVALID`/istisna |
| Yalniz uygulama bayragina dayanmaz | VAR | OS kilitleri |

### §21.3 Coklu surec testleri

`tests/multiproc` kapisi (17 kontrol) **iki gercek isletim sistemi sureci**
kullanir: ebeveyn + cocuk (ayni ikili, mod adi `ParamStr(1)`).

| Kontrol | Ne kanitlar |
|---|---|
| MP1, MP10 | temiz kapanis hala tek dosya |
| MP2, MP3 | baska surec salt-okunur okur; iki okuyucu ayni anda acik kalir |
| MP4 | iki yazar oturumu ayni anda acilabilir (kilit **islem basina** alinir — v3.16/v3.18 tasarim karari) |
| MP5 | **es zamanli yazar + bayat onbellek**: bir surec yazip kapatirken ACIK kalan diger oturum yeni commitleri gorur (`gen` sayaci + `RefreshIfStaleForce`); iki yazar ardisik yazinca veri kaybi yok |
| MP6 | kapanistan sonra yeniden acilis tutarli |
| MP7 | `SIGKILL`/`TerminateProcess` (Close hic calismaz): onayli commitler korunur (`COUNT` 110), kilit kalici bloklamaz, `VERIFY` temiz |
| MP8 | olum sonrasi baska surec yazip kapatabilir (kurtarma dongusu yok) |
| MP9 | salt-okunur oturum yazmayi acikca reddeder |

**Onemli tasarim gercegi (belgelenmeli):** yazma kilidi oturum boyu
tutulmaz; iki yazar oturumu ayni anda acilabilir. Guvenlik, kisa exclusive
kilidin altinda `RefreshIfStaleForce` + `.gen` degisiklik sayaci ile saglanir.
Bu yuzden "ikinci yazar reddedilir" **yanlis** bir beklentidir; dogru iddia
"es zamanli yazarlar serilestirilir ve bayat onbellek tazelenir"dir.

**Yan bulgu (duzeltildi):** salt-okunur acilis `.gen` yoksa onu **yaratiyordu**
(`VDbOpenStreamNoFlock` create=True) ve RO kapanis onu silmedigi icin tek
dosyali bir veritabani salt-okunur acildiginda dizinde ikinci dosya kaliyordu.
Artik RO oturum dosya olusturmaz ve `.gen`'e yazmaz (yalniz sayaci okur).

---

## 7. §22 Benchmark

`perf_baseline` (16/0) + `PERF_BASELINE.md` su kategorileri olcuyor:
B+Tree ekleme/arama/silme/olcekleme, SQL ekleme, SQL nokta okuma, DB dosya
boyutu. Makine/derleyici/O1 bilgisi belgede yazili.

**Eksik (G5):** skill'in saydigi 18 kategoriden **acilis, kapanis, rastgele
ekleme/okuma, guncelleme, indeks olusturma, aralik sorgusu, islem, yedek,
geri yukleme** olculmuyor; **P50/P95/P99** yuzdelikleri, bellek kullanimi ve
WAL boyutu raporlanmiyor.

---

## 8. §23 Butunluk denetleyici

`IVdbBackend.Verify(out Report)` -> `TVdbPageEngine.Verify` su adimlari
yapiyor (satir 1483+): freelist zinciri, **tum sayfalar** (magic + CRC +
sayfa numarasi), heap hucreleri, overflow zincirleri, anahtar tekilligi.
`Verify` geriye uyum icin `VerifyEx(vmFull, False, Report)` cagirir; modlu
yol `VerifyEx(AMode, ADryRun, Report)`.

| Gereksinim | Durum |
|---|---|
| Baslik, surum, sayfa sinirlari, CRC, freelist | VAR |
| B+Tree yapisi/sirasi | VAR — `CheckInvariants` (ayri kapi, 152/0) |
| WAL tutarliligi incelemesi | VAR — `vmWal` (`FWal.Inspect`: commit/cerceve/bayt + kesik kuyruk); kesik kuyruk **UYARI** sayilir, bozulma degil |
| **Salt-okunur incelemede DB'yi degistirmeme** | **VAR** — `ADryRun=True` checkpoint'i atlar; `vdbcheck` her zaman `CreateReadOnly` acar (yazma yolu yok). Kanit: `integrity_check` denetim oncesi/sonrasi FNV-1a ozeti + boyut + dizin icerigi ayni |
| Modlar (hizli/tam/indeks/WAL/kurtarma) | VAR — `vmQuick` (CRC'siz), `vmFull`, `vmIndex`, `vmWal` |
| CLI (`VDB integrity-check database.odb`) | VAR — `vdbcheck [--quick\|--full\|--index\|--wal] [--dry-run] <db>`; cikis 0 temiz / 1 kullanim / 2 bozulma |
| Bozuklugu sessizce onarmama | VAR — `integrity_check` her bozulma senaryosunda dosya ozetinin degismedigini dogrular |
| Onarim akisi | YOK (bilincli: onarim uygulanmadi) |

**G6 kapsami (olculen sinirlama):** `vmQuick` ve `vmIndex` CRC hesaplamaz.
Ancak acilis taramasi (`TVdbPageHeap` `Reindex`) sayfa CRC'sini zaten
dogruladigi icin CRC bozuk bir sayfa bu modlarda da **acilis aninda**
yakalanir (`integrity_check` IC-C2). Kapi 32 kontrol: saglam DB dort modda
temiz + dosya degismedi, bozuk sihirli sayi (sayfa no ile), bozuk CRC,
bozuk freelist girdisi (ucreti yeniden hesaplanmis gecerli trunk), kesik WAL
kuyrugu (uyari), kesik dosya, CLI sozlesmesi.

---

## 9. §24 Format uyumlulugu ve gecis

| Gereksinim | Durum | Kanit |
|---|---|---|
| Format kimligi + surum | VAR | `VDB_FILE_MAGIC`, `VDB_FILE_VER=5` |
| Sayfa boyu + meta surumu | VAR | baslik sayfasi |
| Ozellik bayraklari | VAR | `VDB_META_FLAGS`, `VDB_META_FLAG_ENC` |
| Desteklenen/eski/yeni/bozuk ayrimi | VAR | `:1035`, `:1041-1044` |
| Uyumsuz DB'yi sessizce acmama | VAR | v2 -> "MIGRATE TO v3 calistirin" |
| Gecis acik ve dogrulanmis | KISMI | v3/v4 -> v5 yukseltme **otomatik** (yazilabilir acilista `SaveMeta`); gecis ilerlemesi/geri donusu yok |
| **Gecis testleri** | **YOK (G7)** | depoda v3/v4 fixture `.odb` dosyasi yok; yukseltme hic denenmedi |

---

## 10. §25 Limitler

| Limit | Deger | Durum |
|---|---|---|
| Azami sayfa sayisi | `LongWord` (2^32-1) | **tanimsiz/uygulanmiyor** |
| Azami DB boyu | teorik 16 TB | **tanimsiz** |
| Sayfa boyu | 4096 (sabit) | VAR |
| Azami islem boyu | yok | **tanimsiz** |
| Azami WAL boyu | yok | **tanimsiz** (G8) |
| Eszamanli islem | 1 yazar | dolayli |
| Azami onbellek | 65536 sayfa = 256 MB | VAR |
| B+Tree derinligi | `K=96`, dengeli | VAR (pratik sinir yok) |
| Azami SQL cumlesi | yok | **tanimsiz** (G8) |
| Azami sonuc | `VDB_MAX_RESULT_ROWS=2000000` | VAR |
| Azami baglanti | 64 (1..4096) | VAR |

### §25.2 Kaynak tuketimi testleri

| Senaryo | Durum |
|---|---|
| Disk dolu | **YOK (G8)** — gercek dosya sistemiyle denenmedi |
| Bellek tukenmesi | YOK |
| WAL buyumesi | KISMI (G1 ile ayni) |
| Onbellek tukenmesi | VAR — tahliye |
| Cok fazla baglanti | VAR — `server_harden` S (kapasite) |
| Cok fazla islem | dolayli |
| Asiri buyuk SQL | YOK (limit de yok) |
| Asiri indeks buyumesi | dolayli |

---

## 11. §26 Tasinabilirlik

| Gereksinim | Durum |
|---|---|
| Windows <-> Linux dosya tasima | KISMI — ayni `.odb` iki platformda acildi mi **kanit yok** (G9) |
| macOS | DENENMEDI |
| Mutlak yol bagimliligi yok | VAR — dosya ici yol saklanmiyor |
| Isaretci/padding/endian bagimliligi yok | VAR — tum kalici yapi `Move`+sabit ofset, kucuk-endian |
| Acik serilestirme kurallari | VAR — `VDB_PAGE_*` sabitleri |

---

## 12. §27 Kabul matrisi

| # | Madde | Durum | Kanit |
|---|---|---|---|
| 1 | Tek dosya modu calisiyor | **VAR** | `single_file` 35/0 |
| 2 | Acilis tum DB'yi RAM'e almaz | VAR | cerceve havuzu (kod) — ayri olcum yok |
| 3 | Sayfa tabanli rastgele erisim | VAR | `ReadPageAt` |
| 4 | WAL dayanikliligi dogrulandi | VAR | `wal_crash`, `kv_wal` |
| 5 | Cokme kurtarma testleri geciyor | VAR | `wal_crash` |
| 6 | Checkpoint kurtarma testleri | **VAR** | `crash_points` (cp-1..cp-5, commit-6/7) |
| 7 | Butunluk denetleyici calisiyor | **VAR** | `vdbcheck` (`--quick/--full/--index/--wal`, her zaman salt-okunur) + `integrity_check` 32/0 |
| 8 | B+Tree butunluk kontrolleri | VAR | `btree_integrity` 152/0 |
| 9 | Yedek/geri yukleme testleri | VAR | `backup_restore` 25/0 |
| 10 | Eszamanli erisim testleri | VAR | `multiproc` (MP2/MP3/MP5) |
| 11 | Coklu surec kilitleme testleri | VAR | `multiproc` MP4-MP9 (iki gercek surec) |
| 12 | Veritabani gecis testleri | **YOK** | G7 |
| 13 | Platformlar arasi dosya uyumu | **YOK** | G9 |
| 14 | Benchmark tekrarlanabilir | KISMI | G5 |
| 15 | Performans regresyon kapilari | VAR | `perf_baseline` |
| 16 | Disk dolu davranisi test edildi | **YOK** | G8 |
| 17 | Kaynak tuketimi davranisi test edildi | KISMI | G8 |
| 18 | Sessiz bozulma gozlenmedi | VAR | `page_integrity` 14/0 |
| 19 | Test edilen cokme senaryolarinda onayli commit kaybi yok | VAR | `wal_crash` |
| 20 | Mevcut V3 SQL testleri geciyor | VAR | `sql_matrix` 61/0, `sql_stubs` 25/0 |
| 21 | V2 donmus ve izole | VAR | `VDbCore` yalniz salt-okunur |

**Ozet: 16 VAR, 2 KISMI, 3 YOK.** Bu yuzden skill §27 "tamamlandi" sayilamaz
ve asagidaki bosluklar kapatilmadan "production" iddia edilmez.

---

## 13. Kapatilacak bosluklar

| No | Bosluk | Yapilacak |
|---|---|---|
| G1 | ~~Checkpoint cokme noktalari (7-9) ve WAL budama (10)~~ | **KAPATILDI** — `tests/crash_points` 24/0 (deterministik enjeksiyon + gercek surec olumu) |
| G2 | ~~Onbellek metrikleri eksik (hit ratio, kirli sayfa, flush)~~ | **KAPATILDI** — `GetCacheStats` + `MetricsText` + `SHOW STATS` + `tests/cache_metrics` 21/0 |
| G3 | Izolasyon/kilit belgesi yok | `docs/engineering/ISOLATION.md` |
| G4 | ~~Surecler-arasi kilitleme testleri yok~~ | **KAPATILDI** — `tests/multiproc` 17/0 (MP1-MP10) |
| G5 | Benchmark kategorileri ve yuzdelikler eksik | `perf_baseline` genislet veya `bench_report` kapisi |
| G6 | ~~Butunluk denetleyici CLI + modlar + salt-okunur~~ | **KAPATILDI** — `vdbcheck` (4 mod, her zaman `CreateReadOnly`) + `tests/integrity_check` 32/0 |
| G7 | Eski format fixture'lari ve gecis testleri | v3/v4 imaj uret + yukseltme kapisi |
| G8 | Limitler tanimsiz, disk dolu denenmedi | Limit tablosu + kontrollu hata + disk dolu simulasyonu |
| G9 | Platformlar arasi dosya uyumu kanitsiz | Windows'ta yaz, Linux'ta oku (ve tersi) kapisi |

Oncelik: G7/G9 (uyumluluk), G5 (golge),
G3/G8 (belge + sinir). G1, G2, G4 ve G6 kapatildi.
