# CI ve kalici kapi kosucusu

Bu belge, V3 sertlestirmesinin **gercekten kosan** kapi kumesini ve CI
matrisini kaydeder. Amac, "geciyor" iddialarini tek bir komuta ve tek bir
CI isine baglamak.

## 1. Tek komut

```sh
./tests/run_gates.sh            # cikti: build/gates/ (yok sayilir)
./tests/run_gates.sh /tmp/vdbk # istege bagli calisma dizini
```

Betik saf `fpc` kullanir (Lazarus IDE/`.lpi` gerekmez), Linux/macOS ile
Windows Git Bash'te ayni sekilde calisir. Tum kapilari **kendisi derler**;
onceden derlenmis ikiliye guvenmez.

Cikis kodu 0 = kosan tum kapilar gecti, 1 = en az biri basarisiz.

## 2. Kosan kapilar

| Kapi | Ne dogrular |
|---|---|
| `sql_stubs` | RETURNING/TRIGGER/FUNCTION/PROCEDURE yuzeyi; sessiz yanlis sonuc yok |
| `sql_matrix` | SQL davranis matrisi: DDL/DML/SELECT/JOIN/agregat/transaction/hata yollari + bos tabloda referans dogrulamasi (bkz. `SQL_COVERAGE.md`) |
| `sql_fuzz` | ayristirici dayaniklilik: 3000 deterministik bozuk girdi, istisna sizintisi/heap buyumesi/sure siniri |
| `sql_differential` | PostgreSQL diferansiyel korpusu + sapma yonetisimi (bkz. `SQL_DIFFERENTIAL.md`) |
| `btree_integrity` | B+Tree silme/denge/doluluk + yaprak zinciri Next/Prev (bkz. `BTREE_INTEGRITY.md`) |
| `perf_baseline` | B+Tree/SQL performans tavanlari + olcekleme orani + dogruluk (bkz. `PERF_BASELINE.md`) |
| `bench_report` | `perf_baseline`'in kapsamadigi **18 kategori** (olusturma, acilis, kapanis, sirali/rastgele ekleme ve okuma, guncelleme, silme, indeks olusturma/arama, aralik, islem, eszamanli islem, WAL kurtarma, checkpoint, yedek, geri yukleme); her kategori icin P50/P95/P99/max + islem/sn, CSV + meta dosyasi, bellek ve DB/WAL boyu; ayrica kategori basina **dogruluk** kontrolu (hizli ama yanlis olcum kapidan gecemez) |
| `single_file` | "tek dosya" sozlesmesi: temiz kapanistan sonra dizinde yalniz `<ad>.odb`; tek dosya kopyasi acilir/yazilir; `BACKUP TO` tek dosya (bkz. `ON_DISK_LAYOUT.md`) |
| `region_stream` | `TRegionStream` dosya-ici pencere: mantiksal uzunluk, fsync, sinir kontrolu (v4 icin yazildi, motorda kullanilmiyor) |
| `multiproc` | iki **gercek surec**: es zamanli yazar + bayat onbellek tazeleme, `SIGKILL`/`TerminateProcess` sonrasi kurtarma, RO yazmayi reddetme (bkz. `STORAGE_AUDIT.md` §21.3) |
| `multi_writer` | tek dosyada **iki oturum**: iki yazar sirayla commit eder, WAL LSN kesin artar, ikinci oturum kapaninca `.wal`/`.gen` silinmez, birinci oturum kendi onayli satirlarini korur, temiz kapanistan sonra yalniz `.odb` kalir, 12/12 satir kalici, yedek+geri yukleme 18/18 |
| `crash_points` | **deterministik cokme enjeksiyonu**: 7 checkpoint/commit asamasinin ortasinda gercek surec olumu (`SIGKILL`/`TerminateProcess`), sonra yeniden acilis + `VERIFY` + onayli commit kontrolu (bkz. `STORAGE_AUDIT.md` §4) |
| `integrity_check` | **butunluk denetleyici** (`vdbcheck`): dort mod (`--quick/--full/--index/--wal`), her zaman salt-okunur; saglam DB dort modda temiz, bozuk sihirli sayi/CRC/freelist girdisi/kesik WAL kuyrugu ayri kategorilerde yakalanir, dosya ozeti degismez (bkz. `STORAGE_AUDIT.md` §8) |
| `cache_metrics` | **onbellek metrikleri gercekten hareket ediyor mu**: hit/miss okuma trafigiyle artar, kirli sayfa yazidan sonra > 0 / checkpoint'ten sonra = 0, flush sayaci + yazilan sayfa + sure artar, hit ratio aritmetigi dogru, `MetricsText` ve `SHOW STATS` ayni degerleri tasir (bkz. `STORAGE_AUDIT.md` §5) |
| `format_compat` | **format uyumlulugu / goc**: v5 acilir; v3/v4 damgali imaj salt-okunur acilir ve dosya DEGISMEZ, yazilabilir acilista 5'e yukselir (satirlar + `VERIFY` bozulmaz); v6 (daha yeni), surum 2, v2 sihirli sayisi, yanlis sayfa boyu, kesik dosya ve **yarim yazilmis baslik** REDDEDILIR ve reddedilen dosyanin hash'i degismez (bkz. `STORAGE_AUDIT.md` §9) |
| `crypto_core` | saf Pascal AES/GCM/SHA/HMAC cekirdegi |
| `crypto_base64` | base64 kodlayici/cozucu |
| `fixtures_builtin` | eski `.odb`/anahtar fixture'lari **builtin** provider ile acilir |
| `crypto_kat` | NIST KAT vektorleri (AES-GCM, SHA-256, HMAC, Argon2id, Blake2b) |
| `wal_crash` | WAL yirtik kuyruk/kurtarma matrisi |
| `kv_wal` | KV katmani WAL kurtarma matrisi |
| `backup_restore` | yedek/geri yukleme butunlugu + tatbikat (B0-B24) |
| `page_integrity` | sayfa/heap/freelist bozulma matrisi (I0-I13) |
| `sql_features` | parser'da olup kapisi olmayan SQL ozellikleri: `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT` (kismi geri alma gercekten yalniz sonraki satirlari atar), `ON CONFLICT DO NOTHING\|DO UPDATE` (cift anahtar degeri bozmaz), `VACUUM`/`REINDEX`/`ANALYZE <tablo>` (bakim veriyi korur, indeks aramasi dogru kalir), `WITH` (CTE), `ROW_NUMBER() OVER (ORDER BY ...)`, `ALTER TABLE ... RENAME TO` |
| `limits` | **kaynak sinirlari** (SKILL2 §25): 4 MiB'tan buyuk SQL, 16 MB'lik INSERT ve 2M ustu `LIMIT` kontrollu `ecLimit` ile reddedilir; reddedilen islem **hicbir satir birakmaz**, ayni veritabani sorgulanmaya devam eder, kapanis temiz (yalniz `.odb`) ve yeniden acilista veri bozulmamis olur; belgelenen tavanlar (`LIMITS.md`) tutarli |
| `cache_pressure` | **onbellek tukenmesi / tahliye** (SKILL3 §12.1): 8 sayfalik havuzla (~32 KB) havuzdan cok daha buyuk bir tablo uzerinde calisilir. Tam tarama **butun satirlari** dogru okur (tahliye + yeniden yukleme veri kaybetmez), `PoolUsed` havuz boyunu asmaz, miss sayaci gercek tahliyeyi kanitlar, tek islemde 2000 satir guncellemesi (kirli sayfa tahliye yolu) commit edilir ve **yeniden acilista** guncel veri kalicidir; temiz kapanistan sonra yalniz `.odb` kalir |
| `page_corrupt` | **okuma yolunda sayfa butunlugu** (SKILL3 §5.3/§12.1): normal okuma yolu artik dogrulama yapar. Her veri sayfasinin govdesinde tek bayt bozulmasi, bozuk sihirli sayi ve yanlis sayfa imaji (sayfa 2 imaji sayfa 3'e kopyalanmis) kontrollu `ecCorrupt` uretir; dosyanin saglam kopyasi hala kusursuz taranir (kapi yanlis pozitif uretmez). Sifreli dosyada GCM etiketi zaten dogruluyor |
| `server_harden` | dinleme adresi, `--trust` sinirlari, TLS zorunlulugu |
| `server_failure` | **sunucu hata yollari** (SKILL3 §12.1): (a) `MaxConns=1` iken ikinci baglanti `RSP_ERROR` + `kapasite dolu` alip kapanir, birinci baglanti sorguya devam eder; (b) yeni baglantiya 64 bayt cop ($FF) yazilip kapatilir, sunucu yasar; (c) `CMD_QUERY` ardindan sahte **96 MiB** uzunluk oneki gonderilir - v3.39 `VDBS_MAX_RECV_STR` (64 MiB) oneki tahsis yapmadan reddeder, sunucu yasar; (d) acik baglanti varken `Stop` doner ve `Ready=False` olur; (e) `.odb` dosyasi yerinde kalir ve yeniden acilip satirlari okur |
| `disk_full` | **disk dolu / kisa yazma** (SKILL3 §12.1): sayfa, meta ve **WAL** yazmalari tek noktadan (`WriteBytesChecked` / `WriteChecked`) gecer; enjekte edilen sert hata ve yarim yazma (gercek `ENOSPC` davranisi) kontrollu `ecIOError` uretir, surec cokmez, cerceve **kirli** kalir. Basarisiz commit **hayalet satir** birakmaz (ayni oturumda `COUNT(*)` durabil durumla ayni). Hata + `ROLLBACK` sonrasi onayli satirlar durur, hata giderilince checkpoint ve yeni commit calisir, yeniden acilista tum onayli satirlar okunur ve `VERIFY` temizdir |
| `txn_limit` | **islem sayisi / yazar cakismasi** (SKILL3 §12.2): 300 kisa islem ve 300 islemin 75'i geri alinarak commit sayisi birebir dogrulanir (sessiz kayip yok). Belgelenen v3 semantigi olculur: ic ice `BEGIN`, islem yokken `COMMIT`/`ROLLBACK` **sessiz no-op**'tur (tek islem katmani). Dosya basina **tek yazar rezervasyonu** vardir: bir oturum tutarken digeri kisa busy suresiyle kontrollu `mesgul` hatasi alir, `ROLLBACK` ile temizlenir, rezervasyon birakilinca ayni islem basariyla tamamlanir; yeniden acilista tum satirlar + `VERIFY` temiz |
| `oom` | **bellek tukenmesi** (SKILL3 §12.1): `VDbMM`'e yalniz test icin `MMInjectFault` kancasi eklendi (esik ustundeki tahsislerde bir kez `EOutOfMemory`, sonra kapanir). Okuma ve yazma yollari ayri olculur; nil donen tahsis `SetLength` icinde `EAccessViolation`'a donustugu icin **yanlis** bir benzetimdi, gercek heap gibi `EOutOfMemory` atiliyor. **Bulunan gercek hata (F16, KRITIK):** yazma sirasindaki tahsis hatasi dosyada taninmayan sayfa birakiyordu (`EVdbHeap: sayfa N taninmiyor`); `ExtendFile` once buyutup sonra `Inc(FPageCount)` yapar, `AllocPage` yalnizca bu cagrinin actigi sayfayi geri alir. Hata sonrasi oturum yazmaya devam eder, hayalet satir yok, checkpoint ve yeniden acilis 200 satir + temiz `VERIFY` |
| `btree_scale` | **B+Tree olcek + VACUUM geri kazanma** (SKILL3 §13 olcum-once kurali: "olculebilir bir sorun olmadan spekulatif B+Tree degisikligi yok"): bellekteki `TVDbBTree`'ye 1.000.000 anahtar karisik sirada eklenir; yukseklik **4**, **14.965** yaprak, ortalama doluluk **66/96**, degismezler temiz, `All()` artan, 8.000 rastgele `Find`, `CountRange`/`RankBefore` analitik beklentiyle ayni. Olcek olcusu toplam sure degil **islem basina** maliyettir: 10x veride **3,75x Windows / 4,55x Linux** (karesel agacta ~10x); i386'da 1M anahtar onbellek disina tasindigi icin toplam oran 35-46x cikar ve tek basina yanilticidir. Yarisi silinip yeniden eklenince yaprak sayisi 14.965 -> 14.979 (**1,00x**), yani churn sonrasi yaprak parcalanmasi yok. Diskte 6.000 satir -> %90 sil (dosya kuculmez; `GetDeadBytes` yalniz freelist sayfalarini sayar) -> `VACUUM` **iki platformda da** 1,60 MB'i 151 KB'a indirir (**%90 kazanc**), satir sayisi birebir kalir, sonrasinda 600 satir daha eklemek dosyayi sisirmez, yeniden acilis ve `VERIFY` temiz. Kapi yazilirken **iki gercek motor hatasi** olculdu ve ayni commit'te duzeltildi (v3.43): Unix'te her acilista sizan dosya tanitici (F17) ve basarisiz dosya degistirmeyi basarili bildiren sessiz yutma (F18) - Linux'un yer kazanmadan `VACUUM` kazanci bildirmesinin nedeni buydu |
| `wal_limit` | **WAL icin sert boy tavani** (SKILL3 §6.3: "Any WAL limit must fail safely without corrupting committed data"): `VDB_WAL_MAX_BYTES` = 64 MiB varsayilan, `WalMaxBytes` ozelligi ile degistirilebilir (0 = kapali). Kapi tavani 300 000 bayta indirir ve su davranisi kilitler: 100 autocommit ekleme tavanin cok altinda kalir ve rahatlatma checkpoint'i **gercekten** calisir (`checkpoint 0 -> 11`); `VAL_LEN=6000` ile 250 satirlik **tek** islem commit aninda `ecLimit` alir ve mesaj tavani adlandirir (`WAL boyu siniri asildi (2090928 bayt > 300000 bayt)`); reddedilen islem **hayalet satir birakmaz** (`COUNT(*)` 100'de kalir), hemen ardindan gelen kucuk yazim basarilidir (ret kilidi yok), WAL tavanin altina doner, onceki onayli satirlar bozulmadan okunur; ayni islem `WalMaxBytes := 0` ile commit edilir (350 satir), acik checkpoint sonrasi yazim devam eder (355 satir, WAL tekrar tavan altinda) ve yeniden acilis 355 satiri + temiz `VERIFY` verir. Sert kontrol `DoCommit` icinde, butun cerceveler tampona girdikten ve `FWal.Bytes` kesinlestikten SONRA ama WAL'e tek bayt yazilmadan ONCE yapilir; temizlik backend'in mevcut `RecoverAfterDurabilityFailure` yolundadir (cift kurtarma yok). Iki platformda birebir ayni cikti: **19 PASS / 0 FAIL** |
| `net_fuzz` | **genis ag fuzz'i** (SKILL3 §6/§11: bozuk ag girdisi sunucuyu dusurmemeli): gercek `TVdbPgServer` (PG wire) loopback'te **trust** modda, `MaxConns=256` (kapasite asla basarisizlik nedeni olmasin diye). 15 saldiri ailesi + tohumlanmis deterministik mutasyon dongusu: startup uzunlugu `70000` ve `2^31-1`, kesik startup, `0`/`4`/`0xFFFFFFFF`, bilinmeyen protokol kodu, 512 rastgele bayt, gecerli startup sonrasi 30 rastgele mesaj tipi, `Q` uzunlugu `64MB+1`, `Q` uzunlugu `3`, ilan edilip kesilen `Q` govdesi, NUL'suz/kontrol baytli/bos sorgu, 20 ardisik `SSLRequest` (her biri `N`, sonra ayni sokette gercek sorgu), 40 kisa cop baglanti, 120 yinelemeli tohumlanmis mutasyon (her 20 yinelemede canlilik kontrolu), bozuk genisletilmis protokol (`P`/`B`/`E`/`D`) ve 4 is parcacigi x 8 eszamanli fuzz. Her saldiridan SONRA gecerli bir istemci startup'i tamamlayip `SELECT 1` calistirir; kapi sunucunun cokmedigini, baglanti kabul etmeye devam ettigini ve gercek sorgu yaniti verdigini boyle olcer. Kapi yazilirken bir **test istemcisi** hatasi ortaya cikti (genisletilmis protokol hatasindan sonra sunucu yalnizca `Sync` bekledigi icin istemci `Z` bekleyip kilitleniyordu; saldiri dizisi her bozuk mesajdan sonra `Sync` gonderir) - sunucu tarafinda degisiklik gerekmedi. Iki platformda birebir ayni: **39 PASS / 0 FAIL** |
| `btree_disk` | **ayri B+Tree disk sayfa bicimi** (SKILL3 §13'un son acik kalemi): `VDbBTreeDisk.pas` **bagimsiz** birimdir, v5 motor dosya bicimine, WAL'e ve kurtarmaya **bagli DEGILDIR** (v5 bicimi ve kurtarma davranisi degismez). 4096 baytlik sayfa, 32 baytlik baslik (`PageNo`/`Kind`/`Level`/`NKeys`/`Flags` + sayfa CRC'si), slotlu hucre duzeni sayfa sonundan geriye; yaprak hucresi 16 bayt (`Key:QWord + Val:QWord`), ic hucre 12 bayt (`Key:QWord + Child:LongWord`), ic sayfada 0. hucrenin anahtari kullanilmaz ve en sol cocuktur, yonlendirme "`Key_i <= K` olan en buyuk `i`". **Golge sayfalama**: hicbir sayfa yerinde guncellenmez, degisen sayfalar yeni numaralara kopyalanir ve meta en son yazilir; meta yazimi **commit noktasidir**. Iki A/B meta sayfasi vardir, acilista CRC'den gecen **en yuksek `Seq`** kazanir. Kapi BD1-BD18: 1000 anahtar ekle/oku/guncelle + artan `Walk`, yeniden acilis + temiz `Verify` (dosya kuculmez 57.344 -> 57.344 B), yarisi silinip yeniden acilma, azalan 2000 ve karisik 3000/6000, 6000 `NextAfter` alt-sinir taramasi (sirali listeyle birebir), bolunme agirlikli 6000 anahtar (yukseklik 2, 36 yaprak), churn sonrasi doluluk olcumu (`yaprak=36 hucre=6000 doluluk=96000/147456`, ~%65), sayfa geri kazanimi (75 -> 75 sayfa; sayac sismez), **yirtik meta** (en yeni meta bozulunca onceki 300 anahtarlik agac aynen acilir, yeni 300 anahtar gorunmez), **cokme noktasi** (`OnBeforeMeta` kancasi meta yazimindan hemen once dosyayi kopyalar; kopya onceki 200 anahtari TAM okur = veri kaybi yok), yalniz-CRC bozulmasi (`Verify` FAIL, okuma hala 500/500 bulur), yapisal bozulma (`Verify` FAIL ve okuma yolu kontrollu `EBtdError`, **access violation yok**) ve kesik dosya (`EBtdError`, sessizce yeni agac KURMAZ). Kapi yazilirken **uc gercek kusur** bulundu ve duzeltildi: Windows'ta `fmCreate` ile yeniden acilisin dosyayi **sifirlamasi** (`FileExists` ayrimi, `VDbPageStore` ile ayni desen), kurucu istisna yolunda **cift serbest birakma** (`FreeAndNil` + nil kontrolleri) ve `Verify`'in bozuk sayfada **istisna sizdirmasi**. Iki platformda birebir ayni: **78 PASS / 0 FAIL** |
| `auth_throttle` | SCRAM deneme sinirlama/kilit |
| `selftest_builtin` | provider SelfTest (builtin) |
| `tls_client` | istemci CA + sunucu adi dogrulamasi (OpenSSL varsa) |

Kosullu kapilar:

- `fixtures_openssl`, `selftest_openssl`: yalniz `VDB_CRYPTO_DLL` verilmisse.
- `tls_client`: OpenSSL yuklenemezse kapi **77** ile kendini atlar
  (`SKIP`); bu "gecti" sayilmaz, kosan kapi sayisina da eklenmez.

## 3. CI matrisi

`.github/workflows/ci.yml` — `ubuntu-latest` + `windows-latest`:

1. `actions/checkout`
2. Windows: `gcarreno/setup-lazarus` (Lazarus 4.4 / FPC 3.2.2,
   **commit SHA'sina pinli**; surum yukseltmesi bilincli bir PR'dir).
   Unix: `apt-get install fpc` (Ubuntu deposu, FPC 3.2.2). Linux'ta
   `lazbuild` gerekmez, bu yuzden ucuncu-taraf kurulum action'i yerine
   depo paketi kullanilir; ariza nedeni dogrudan logda gorunur.
3. Surum dokumu (`fpc -iV`, varsa `lazbuild --version`)
4. Windows: `lazbuild vdbapi|vdbcli|vdbmig|vdbserver.lpi`
   Unix: `bash build_lib.sh` (paylasilan kutuphane)
5. `bash tests/run_gates.sh`
6. Basarisizlikta `build/gates/*.log`, `gates.out` ve apt loglari artifact
   olarak yuklenir. Ayrica ilk 10 hata satiri ve kuyruk **check-run
   anotasyonu** olarak yazilir; log indirme yetkisi olmayan bir okuyucu da
   ariza nedenini gorebilir.

`fail-fast: false`: bir platformun kirilmasi digerinin sonucunu gizlemez.

## 4. Kapsam disi (bilerek)

- **`sqltest` (`tests/sql`) yok.** Eski agacla birlikte kaldirildi
  (README'deki komut bu nedenle bayat). SQL davranis kapisi artik
  `sql_stubs` + `sql_matrix`'dir; matrisin kapsami ve bilinen farklari
  `docs/engineering/SQL_COVERAGE.md`'de yazilidir.
- Kapsam/olcum (coverage) **bu fazda yok**. SBOM (`docs/security/SBOM.md`
  + `vdb.cdx.json`) ve lisans/atif envanteri (`NOTICE`) artik **var**;
  imzalama ve provenance **yoktur** cunku bu surumde yayinlanan ikili
  yoktur (`SBOM.md` imzalama karari). SQL ayristirici fuzz'i (`sql_fuzz`)
  vardir; diger protokol/kapilar icin fuzz yoktur.
- macOS/ARM64 matrisi yok; kod Unix dallari uzerinden tasinabilir
  tutulmustur ama macOS'ta kosulmadi.
- TLS kapisi sertifika uretimi icin `tests/tls_fixtures` (Python
  `gen_certs.py` ile uretilmis, depoya islenmis) kullanir.

## 5. Tasinabilirlik notlari (bu fazda duzeltildi)

Unix derlemesi daha once hic denenmemisti; asagidaki gercek engeller
kaldirildi:

- `VDbMM`: `uses Windows` kosullu; slab ayirma Windows'ta `VirtualAlloc`,
  Unix'te `fpmmap` (64 KB hizalama onek/sonek `fpMunmap` ile iade).
  Eski 32-bit adres varsayimli slab bitmap'i yerine platformdan bagimsiz
  **slab kayit defteri** (acik adresleme hash) kullanilir.
- `VDbSync.VDbEventName`: Unix'te `TEvent` bos adla olusturulamaz
  (`ESyncObjectException`); olay adlari surec-ici benzersiz uretilir.
- `VDbXPrims`: `fcntl` birimi FPC'de yok → `BaseUnix.FpFcntl` + `FLock`;
  POSIX kilit sabitleri platforma gore (`VDB_F_*`) tanimlandi. `shm_open`
  sarmalayicisi FPC 3.2.2'de bulunmadigi icin Linux'ta `/dev/shm`, diger
  Unix'lerde gecici dizin uzerinden `fpOpen`/`fpUnlink` kullanilir.
- `VDbTls`: Unix kutuphane adlari (`libssl.so.3`, `.so.1.1`, `.so`,
  macOS `.dylib`) eklendi; `SIGPIPE` surec duzeyinde yok sayilir (karsi
  taraf el sikismasini kesince OpenSSL yazma yolu sureci oldurmesin).
- Test programlari Unix'te `cthreads` thread driver'ini `uses` eder.
- `tests/run_gates.sh` Git Bash/MSYS altinda `fpc`'ye **native Windows
  yolu** verir (`cygpath -w`). Aksi halde native `fpc.exe` POSIX yolunu
  (`/d/repo`) surucu-goreli (`\d\repo`) sanip `Path does not exist` ile
  duser. Bu, ilk CI kosusunda Windows isini kirian gercek nedendi.
- Betik, kaynak dizindeki eski `gen_fixtures` ikilisini derlemeden once
  siler: bayat ikili `fixtures_builtin` kapisini yanlislikla PASS
  gosterebiliyordu.

## 6. Bilinen sinirlar

- Windows'ta TLS kapisi OpenSSL DLL'lerini `VDB_SSL_DLL`/`VDB_CRYPTO_DLL`
  ile bulur; CI'da bu degiskenler tanimli olmadigi icin kapi 77 ile atlar.
  Bu **TLS dogrulamasinin CI'da kosmadigi** anlamina gelir; yerelde
  kosulmustur (6/6).
- Ilk GitHub Actions kosusu (`a8526b2`, run 433) **basarisiz** oldu:
  `gates (ubuntu-latest)` "Setup FPC / Lazarus" adiminda, `gates
  (windows-latest)` "Build and run gates" adiminda dustu. Windows nedeni
  yerelde birebir yeniden uretildi ve duzeltildi (yukaridaki `cygpath`
  maddesi). Ubuntu nedeninin adim logu anonim erisimle okunamadi
  (GitHub log indirme kimlik dogrulamasi istiyor); bu yuzden o adim
  ucuncu-taraf action'dan bagimsiz, ciktisini acikca loglayan `apt-get`
  kurulumuna cevrildi.
- Ikinci GitHub Actions kosusu (`e1c4654`, run "CI" #43551308899):
  `gates (ubuntu-latest)` **basarisiz**, `gates (windows-latest)` hala
  kosuyordu. Ubuntu'nun dustugu adim artik okunabildi (check-run
  anotasyonu): `BUILD FAIL crypto_fixtures` / `MISSING fixtures_builtin`.
  Kok neden yerelde birebir uretildi: **temiz checkout'ta
  `tests/crypto_fixtures/lib` dizini yoktur ve `fpc -FU` hedef dizini
  kendisi yaratmaz** (`Can't create object file .../lib/VDbCryptoCore.o`).
  WSL'de dizin eski kosulardan kalmis oldugu icin sorun gorunmuyordu.
  Betik artik derlemeden once `mkdir -p "$FI/lib"` yapar. Ayrica
  basarisizlik anotasyonu artik `Error:`/`Fatal:` satirlarini da tasir;
  onceki surum yalniz "BUILD FAIL <ad>" yazdigi icin kok neden gizlenmisti.
- Ucuncu kosu (`7ae62c2`, run 43552816622): `gates (ubuntu-latest)`
  **basarili** (Linux ilk kez yesil); `gates (windows-latest)`
  **basarisiz** — adim 8 "Build and run gates". Anotasyon kok nedeni
  gosterdi: `FAIL scram_verifier.txt: sha256 pini` +
  `AddUser formulu yeniden-turetimi` → `fixtures_builtin (exit 2)`.
  Kok neden yerelde birebir uretildi: Windows runner'da
  `core.autocrlf=true` temiz checkout'ta fixture metnini CRLF'e cevirir
  (666 → 678 bayt); kapi `gen_fixtures verify` kosar (yeniden uretmez) ve
  pin bayt duzeyindedir. Yerelde gorulmemesinin nedeni, dosyanin
  generator tarafindan LF ile yeniden yazilmis olmasiydi. Duzeltme:
  `.gitattributes` icinde `tests/crypto_fixtures/fixtures/** -text`.
  Temiz klonda dogrulandi: duzeltme oncesi 20/2 FAIL (CI ile ayni),
  sonrasi 22/0 PASS.
- Dorduncu kosu (`3997bbe`, run 43555965650): **iki platform da YESIL**
  (Ubuntu + Windows `success`). CRLF duzeltmesi ve `cygpath`
  duzeltmesi boylece CI'da dogrulandi.
- Besinci kosu (`0381d53`, run 43558258898): **iki platform da YESIL**
  (`success`). Bu kosu Phase 4 `backup_restore` kapisini (B0-B24) ilk kez
  CI'da kosturdu.
- Altinci kosu (`a1048e9`, run 43562165305): **iki platform da YESIL**
  (`success`). Bu kosu Phase 4 `page_integrity` kapisini (I0-I13) ilk kez
  CI'da kosturdu; trunk sayfasi yanlis-pozitif duzeltmesi ve `cur`
  Release duzeltmesi CI'da dogrulandi.
- Yedinci kosu (`929348c`, run 43564347378): **iki platform da YESIL**
  (`success`). `sql_differential` kapisi (PostgreSQL korpusu + sapma
  yonetisimi) ilk kez CI'da kosturuldu; yerel kanit Git Bash/Windows
  **15 kapi** PASS (tls_client SKIP), WSL x86_64 Linux **16 kapi** PASS.
  `sql_matrix`: 61 PASS, 0 FAIL (iki platformda).
  `backup_restore`: 25 PASS, 0 FAIL (iki platformda).
  `page_integrity`: 14 PASS, 0 FAIL (iki platformda).
  `sql_differential`: 33 PASS, 0 FAIL, `pg=not-run` (psql yok).
- Sekizinci kosu (`7569cc4`, run 43567310636): **iki platform da YESIL**
  (`success`). `btree_integrity` kapisi ilk kez CI'da kosturuldu; silme
  yeniden dengeleme + kok cokertme + `Prev` zinciri CI'da dogrulandi;
  152 PASS / 0 FAIL. Yerel kanit Git Bash/Windows **16 kapi** PASS
  (tls_client SKIP), WSL x86_64 Linux **17 kapi** PASS.
- Dokuzuncu kosu (`2bcd8da`, run 43568883549): **iki platform da YESIL**
  (`success`). `perf_baseline` kapisi eklendi; yerel kanit
  Git Bash/Windows **17 kapi** PASS (tls_client SKIP), WSL x86_64 Linux
  **18 kapi** PASS (tls_client 6/0 dahil). `perf_baseline`: 16 PASS,
  0 FAIL (iki platformda).
  Olculen (WSL x86_64, FPC 3.2.2): btree.insert 100k **361 ms**,
  btree.find 5k **9 ms**, btree.delete 100k **312 ms**, olcek
  25k->50k **59->118 ms (oran 2.00)**, sql.insert 3k **9 662 ms**,
  sql.point-select 3k **1 101 ms**, db dosyasi **102 400 bayt**.
- Onuncu kosu (`7ee3cdc`, run 43586157557): **iki platform da YESIL**
  (`success`). `single_file` kapisi eklendi; README'lerdeki "tek dosya"
  ifadesi olculen gercege gore duzeltildi ve `ON_DISK_LAYOUT.md` yazildi.
  Yerel kanit Git Bash/Windows **18 kapi** PASS (tls_client SKIP),
  WSL x86_64 Linux **19 kapi** PASS. `single_file`: 22 PASS, 0 FAIL
  (yalniz `.odb` kopyasi okunur *ve* yazilir; `BACKUP TO` ciktisi tek
  basina acilir).
- Onbirinci kosu (`c9df6b8`, run 43598523216): **iki platform da YESIL**
  (`success`). Bu kosu **yalniz belge** getirdi (`docs/security/`,
  `SECURITY.md`, `NOTICE`, `CHANGELOG.md`, README guvenlik bolumu); kapi
  kumesi, kaynak kodu ve CI matrisi degismedi, dolayisiyla kapi sonuclari
  onuncu kosuyla aynidir. `fail-fast: false` sayesinde iki platform da
  gercekten kosmustur.
- Onikinci kosu (`b86cddb`, run 43600343657): **iki platform da YESIL**
  (`success`). Bu kosu da **yalniz belge** getirdi (`RC_REVIEW.md`,
  `CI.md` kosu gecmisi, README/CHANGELOG baglantilari); kapi kumesi
  degismedi.
- Onucuncu kosu (PHASE-9 commit'i): **yerel kanit** Git
  Bash/Windows **18 kapi** PASS (`tls_client` SKIP), WSL x86_64 Linux
  **19 kapi** PASS. **Tek dosya davranisi degisti**: kapanis artik WAL'i
  checkpoint ettikten sonra `.wal` ve `.gen` dosyalarini siler, `.idx`
  yalniz `KeepIdxOnClose` aciksa yazilir, degisim gunlugu varsayilan
  kapalidir (`ChangeLogEnabled`). `single_file` kapisi 22 -> **35 PASS,
  0 FAIL** (SF1-SF20: kapanistan sonra dizinde tek dosya, tekrar acma,
  yazma, `.odb` kopyasi, `BACKUP TO`). `wal_crash`, `kv_wal`,
  `backup_restore`, `page_integrity`, `perf_baseline` etkilenmedi.
  **Windows dersi:** `VDbPageStore.pas` icinde nitelenmemis
  `DeleteFile(AnsiString)` i386 FPC 3.2.4'te derlenmiyor
  (`expected "PChar"`) — WSL'de ayni hata cikmadigi icin yalniz Windows
  kosusu yakaladi; cozum `SysUtils.DeleteFile(...)`.
- Ondorduncu kosu (PHASE-11 commit'i): **yerel kanit** WSL x86_64 Linux
  **21 kapi** PASS, Git Bash/Windows i386 **20 kapi** PASS (`tls_client`
  SKIP). Iki yeni kapi eklendi: `region_stream` (13/0, tasarim araci) ve
  `multiproc` (**17 PASS, 0 FAIL**). `multiproc` iki gercek isletim sistemi
  sureci calistirir: es zamanli yazar, bir surec yazarken **acik kalan**
  diger oturumun yeni commit'leri gormesi (`gen` sayaci +
  `RefreshIfStaleForce`), `SIGKILL`/`TerminateProcess` sonrasi onayli
  commit'lerin korunmasi ve kilidin kalici bloklamamasi, `VERIFY`
  temizligi, salt-okunur oturumun yazmayi reddetmesi.
  **Yan bulgu (duzeltildi):** salt-okunur acilis `.gen` yoksa onu
  **yaratiyordu** (`VDbOpenStreamNoFlock(..., create=True)`) ve RO kapanis
  onu silmedigi icin tek dosyali bir veritabani salt-okunur acildiginda
  dizinde ikinci dosya kaliyordu. Artik RO oturum `.gen` olusturmaz ve
  dosyaya yazmaz, yalniz sayaci okur (`VDbPageStore.pas`).
  **Belgelenen tasarim gercegi:** yazma kilidi oturum boyu **tutulmaz**,
  islem basina alinir; iki yazar oturumu ayni anda acilabilir. Bu yuzden
  "ikinci yazar reddedilir" yanlis bir beklentidir; dogru iddia "es
  zamanli yazarlar serilestirilir ve bayat onbellek tazelenir"dir
  (`STORAGE_AUDIT.md` §21.3).
  Diger kapilar degismedi: `sql_stubs` 25/0, `sql_matrix` 61/0,
  `sql_fuzz` 5/0, `sql_differential` 33/0 (`pg=not-run`), `wal_crash`,
  `kv_wal`, `backup_restore` 25/0, `page_integrity` 14/0,
  `btree_integrity` 152/0, `perf_baseline` 16/0, `single_file` 35/0,
  `server_harden` 24/0, `auth_throttle` 16/0, `tls_client` 6/0.
- Onbesinci kosu (PHASE-12 commit'i): **yerel kanit** WSL x86_64 Linux
  **22 kapi** PASS, Git Bash/Windows i386 **21 kapi** PASS (`tls_client`
  SKIP). Yeni kapi `crash_points` (**24 PASS, 0 FAIL**) SKILL2 §19.2'nin
  deterministik cokme noktalarini kapatir: `VDbPageEngine` icine
  `VDB_CRASH_STAGE_*` sabitleri, `CrashAtStage` ve `OnCrashPoint` kancasi
  konuldu; test cocuk surecte kancayi **gercek surec olumune**
  (`SIGKILL`/`TerminateProcess`; `Close()` hic calismaz) baglar.
  Denenen noktalar: checkpoint basi, sayfa yazimi oncesi/sonrasi, WAL
  budama sonrasi, checkpoint sonu, commit kaydinin fsync oncesi ve
  sonrasi. Her noktadan sonra dosya yeniden acilir, `VERIFY` temiz
  cikar, onayli commit'ler durur (fsync oncesi noktada kayip serbesttir
  ama tutarsizlik yasaktir) ve DB hala yazilabilir. Enjeksiyon uretimde
  `0` (kapali) kalir; kanca atanmazsa motor **acik hata** verir, sessizce
  devam etmez. Diger kapilar degismedi (`multiproc` 17/0 dahil).
- Onaltinci kosu (PHASE-13 commit'i): **yerel kanit** WSL x86_64 Linux
  **23 kapi** PASS, Git Bash/Windows i386 **22 kapi** PASS (`tls_client`
  SKIP). Yeni kapi `integrity_check` (**32 PASS, 0 FAIL**) SKILL2 §23'u
  kapatir: `TVdbPageEngine.VerifyEx(AMode, ADryRun, Report)` dort mod
  sunar (`vmQuick`, `vmFull`, `vmIndex`, `vmWal`); eski `Verify` geriye
  uyum icin `VerifyEx(vmFull, False, ...)` cagirir. `ADryRun=True` acik
  commit checkpoint'ini **atlar**, boylece denetim veritabanini
  degistirmez. `TVdbPageWal.Inspect` WAL kuyrugunu uygulamadan okur ve
  tarama durumunu geri yukler; kesik kuyruk **uyari** sayilir, bozulma
  degil. Yeni arac `vdbcheck [--quick|--full|--index|--wal] [--dry-run]
  <db>` veritabani **her zaman** `CreateReadOnly` ile acar (yazma yolu
  yok) ve cikis kodu verir: 0 temiz, 1 kullanim hatasi, 2 bozulma.
  Kapi, denetim oncesi/sonrasi dosyanin FNV-1a ozeti + boyutu + dizin
  icerigi ayni oldugunu dogrular; bozuk sihirli sayi, bozuk CRC, bozuk
  freelist girdisi ve kesik WAL kuyrugu ayri ayri sinanir.
- Onyedinci kosu (PHASE-14 commit'i): **yerel kanit** WSL x86_64 Linux
  **24 kapi** PASS, Git Bash/Windows i386 **23 kapi** PASS (`tls_client`
  SKIP). Yeni kapi `cache_metrics` (**21 PASS, 0 FAIL**) SKILL2 §20.2'yi
  kapatir: `TVDbStoreStats` kirli cerceve sayisini ve flush sayacini/
  sayfa sayisini/suresini tasir; ayni degerler `IVDbBackend.GetCacheStats`
  (`TVdbCacheStats`) ile motordan bagimsiz yayinlanir, `MetricsText`
  (Prometheus) ve `SHOW STATS` (SQL) ayni gercek sayilari gosterir.
  Kapi sabit metrik yalanini yakalar: her kontrol sayacin **is yapinca
  arttigini** (ya da is bitince sifira dondugunu) olcer; okuma trafigi
  hit/miss'i, yazi kirli sayfayi, checkpoint flush sayacini artirir,
  checkpoint sonrasi kirli sayfa 0'dir. Diger kapilar degismedi
  (`integrity_check` 32/0, `crash_points` 24/0 dahil).
- Onsekizinci kosu (PHASE-15 commit'i): **yerel kanit** WSL x86_64 Linux
  **25 kapi** PASS, Git Bash/Windows i386 **24 kapi** PASS (`tls_client`
  SKIP). Yeni kapi `format_compat` (**28 PASS, 0 FAIL**) SKILL2 §24.2/§24.4
  ayrimlarini kapatir: saglam v5 dosyasi acilir; baslik surum alani 3/4
  yapilip CRC'si yeniden hesaplanmis **sentetik v3/v4 imaji** salt-okunur
  acilir, satirlar okunur ve dosya **degismez** (FNV-1a ozeti ayni: RO
  acilis yukseltme yapmaz); ayni imaj yazilabilir acilista basligi 5'e
  yukseltir, satir sayisi ve `VERIFY` bozulmaz; **surum 6** (daha yeni),
  **surum 2**, v2 sihirli sayisi, taninmayan sihirli sayi, yanlis sayfa
  boyu, kesik dosya ve **yarim yazilmis baslik** (surum yazildi, CRC
  yazilmadi) REDDEDILIR; reddedilen dosyalarin hash'i ve boyutu degismez.
  Kapinin durust siniri belgede yazili: imajlar sentetiktir (satir govdesi
  kendi kendini tanimlar, motorun ayirt ettigi tek sey basliktir) ve
  yukseltme tek 4 KB'lik **yerinde** baslik yazimidir — kesilirse dosya
  acilmaz, kurtarma "yedekten geri yukle"dir. Diger kapilar degismedi
  (`cache_metrics` 21/0, `integrity_check` 32/0, `crash_points` 24/0 dahil).
- Ondokuzuncu kosu (PHASE-16 commit'i): **yerel kanit** WSL x86_64 Linux
  **26 kapi** PASS, Git Bash/Windows i386 **25 kapi** PASS (`tls_client`
  SKIP). Yeni kapi `portability` (**29 PASS, 0 FAIL**) SKILL2 §26.3'u
  kapatir. Kapi iki modludur cunku asil iddia **iki platform arasinda
  gercek dosya aktarimi**dir: `--write <dizin>` veritabanini kurar ve
  `manifest.txt` yazar (satir sayisi, icerik ozeti, bayt, dosya ozeti),
  `--read <dizin>` ayni dosyayi **salt-okunur** acar ve manifestteki
  degerleri dogrular. Argumansiz kosu ayni platformda yaz/oku turu +
  bayt bayt kopya + ikinci bagimsiz yazim karsilastirmasidir.
  Olculen (her iki platform, 400 satir): kendi platformunda **29/0**;
  **Windows i386 -> Linux x86_64 13/0** ve **Linux -> Windows 13/0**
  (ayni imza `B9352F5CB8B5F0C5`, `VERIFY` temiz, dosya ozeti degismedi,
  `.wal`/`.gen` olusmadi, baslik sihirli sayisi/surumu/sayfa boyu ayni).
  **Bulunan gercek hata (duzeltildi):** `VDbTable.SaveSchema` sema metnini
  RTL'in `sl.Text` ozelligiyle yaziyordu, yani satir sonu **platforma
  bagimliydi** (Windows CRLF). Bu, katalog kaydinin 2 bayt uzun olmasina ve
  ayni veriyi tasiyan iki imajin farkli olmasina yol aciyordu (sayfa 1'de
  3697 bayt kayma, `FreeSpace`/`ContentOff` farkli). Sema artik acikca
  `#10` ile birlestirilir; okuma yolu hem CRLF hem LF kabul eder ve bicim
  surumu degismedi. Duzeltmeden sonra bagimsiz uretilen iki imaj
  **yalnizca 13 baytta** farklidir ve bu 13 bayt tamamen **ucucu
  meta**dir: olusturma zamani (ofset 28), rastgele DB kimligi (76..83) ve
  sayfa 0 CRC'si (4092..4095). Kapi bunu `PT6/PT7` ile kilitler.
  **Durust sinir:** buyuk-endian makine ve macOS denenmedi; kalici yapi
  kucuk-endian ve sabit ofset varsayar (bkz. `STORAGE_AUDIT.md` §11).
  Diger kapilar degismedi (`format_compat` 28/0, `cache_metrics` 21/0,
  `integrity_check` 32/0, `crash_points` 24/0 dahil).

- Yirminci kosu (PHASE-17 commit'i): **iki platform da YESIL**. Yerel kanit
  Git Bash/Windows **27 kapi** PASS (`tls_client` SKIP), WSL x86_64 Linux
  **28 kapi** PASS. Iki yeni kapi eklendi:
  - `multi_writer` **12 PASS / 0 FAIL**. Ayni dosyaya iki oturum yazarken
    olculen **onayli commit kaybi** siniflarini kilitler: (a) v3.32
    `InstallPage` artik `TxnMark = FTxnId` olmadan sayfayi silmiyor;
    (b) v3.33 `.gen` surec ici referans sayaci sayesinde ikinci oturumun
    kapanisi dosyayi ayaklar altindan cekmiyor; (c) v3.34/v3.35 WAL kuyruk
    LSN'i (`FTailPos`/`FTailLsn`, `SyncTail`, `TailLsn`) tohumlanip iki
    oturumun ayni LSN'i uretmesi engellendi; (d) v3.36 `DropSideFiles`
    baska oturum acikken yan dosyalara dokunmuyor ve WAL commit'i her zaman
    dosya sonuna konumlanip bayat ekleme konumunu eziyor.
  - `bench_report` **35 PASS / 0 FAIL**. 18 kategori + P50/P95/P99/max +
    CSV/meta + bellek/WAL boyu + kategori basina dogruluk kontrolu.
    Deterministik tohum (20251115); indeksli arama id tabani 300000 ->
    **2000000** (eski taban `BR5` rastgele araligiyla cakisip sahte
    "duplicate PK" uretiyordu).
  Diger kapilar degismedi (`portability` 29/0, `format_compat` 28/0,
  `cache_metrics` 21/0, `integrity_check` 32/0, `crash_points` 24/0,
  `multiproc` 17/0 dahil).
- Yirmi birinci kosu (PHASE-18 commit'i, SKILL3 denetimi): **iki platform da
  YESIL**. Git Bash/Windows **29 kapi** PASS (`tls_client` SKIP), WSL x86_64
  Linux **30 kapi** PASS. Iki yeni kapi:
  - `sql_features` **32 PASS / 0 FAIL**. SKILL3 §9.1/§10.1'in "uygulanmis ama
    test edilmemis" listesini kapatir: `SAVEPOINT` / `ROLLBACK TO SAVEPOINT`
    / `RELEASE SAVEPOINT` (kismi geri alma gercekten yalniz sonraki satirlari
    atar; `RELEASE` sonrasi commit iki satiri da korur), `ON CONFLICT
    DO NOTHING` / `DO UPDATE` (cift anahtar eski degeri korur / gunceller,
    satir sayisi artmaz), `VACUUM` / `REINDEX` / `ANALYZE <tablo>` (bakim
    sonrasi satir sayisi ve indeksli arama dogru), `WITH` (CTE),
    `ROW_NUMBER() OVER (ORDER BY id)` (1..3), `ALTER TABLE ... RENAME TO`
    (satirlar tasinir, eski ad kapanir). `ANALYZE` tablo adi ister; bu
    davranis da kapida kilitli.
  - `limits` **18 PASS / 0 FAIL**. SKILL2 §25 / SKILL3 §12 kaynak sinirlari:
    4 MiB'tan buyuk SQL, 16 MB'lik INSERT ve 2M ustu `LIMIT` kontrollu
    `ecLimit` ile reddedilir; reddedilen islem **satir birakmaz**, tablo
    sorgulanabilir kalir, kapanistan sonra yalniz `.odb` vardir ve yeniden
    acilista veri bozulmamistir. Belgelenen tavanlar
    `docs/engineering/LIMITS.md`'de listelenir ve kapida tutarliligi olculur
    (`VDB_MAX_PAGES` 16 777 215,
    `VDB_MAX_DB_BYTES` 1 TiB, `VDB_MAX_TXN_PAGES` 1 048 576,
    `VDB_MAX_POOL` 65 536, `VDB_MAX_SQL_STMT` 4 MiB, `VDB_MAX_VALUE` 16 MiB,
    `VDB_MAX_RESULT_ROWS` 2 000 000).
  Motor tarafinda bu kosuda eklenen sinirlar: `ExtendFile` sayfa/boy tavani
  ve `GrowTo` boy tavani (`ecLimit`), `MarkPageDirty` islem sayfa tavani
  (`ecLimit`), `VDbExecutor` cikti buyumesinde 2M satir tavani (`ecLimit`,
  hem DirectDecode hem genel yol). Denetim raporu:
  `docs/audit/V3_FINAL_AUDIT.md`.
  Diger kapilar degismedi (`portability` 29/0, `format_compat` 28/0,
  `cache_metrics` 21/0, `integrity_check` 32/0, `crash_points` 24/0,
  `multiproc` 17/0, `multi_writer` 12/0, `bench_report` 35/0 dahil).
- Yirmi ikinci kosu (PHASE-19 commit'i, SKILL3 §12.1 onbellek tukenmesi):
  **iki platform da YESIL**. Git Bash/Windows **30 kapi** PASS (`tls_client`
  SKIP), WSL x86_64 Linux **31 kapi** PASS. Yeni kapi:
  - `cache_pressure` **8 PASS / 0 FAIL**. Havuz 8 sayfaya (32 KB) indirilip
    ~100 sayfalik tablo uzerinde calisilir. Olculen: (a) kucuk havuz istegi
    kabul edilir ve `PoolPages=8` raporlanir; (b) havuzdan buyuk tablo
    yazilir; (c) tam tarama **butun 2000 satiri** dogru okur (tahliye +
    yeniden yukleme sessiz veri kaybi uretmez); (d) `PoolUsed` havuz boyunu
    asmaz; (e) miss sayaci havuz boyunun cok uzerine cikar, yani tahliye
    gercekten olmustur; (f) tek islemde 2000 satir guncellemesi (kirli
    sayfa tahliyesi WAL'e dokulur) commit edilir; (g) kapanistan sonra
    yalniz `.odb` kalir; (h) yeniden acilista guncel veri kalicidir.
  Diger kapilar degismedi.
- Yirmi ucuncu kosu (PHASE-20 commit'i, SKILL3 §5.3/§12.1 okuma yolu
  butunlugu): **iki platform da YESIL**. Git Bash/Windows **31 kapi** PASS
  (`tls_client` SKIP), WSL x86_64 Linux **32 kapi** PASS. Motor degisikligi
  ve yeni kapi:
  - **Motor**: `TVDbPageStore.ReadPageAt` okunan sayfa imajini artik
    `CheckReadImage` ile dogruluyor. Onceden okuma yolu hicbir butunluk
    denetimi yapmiyordu: tek bir bozuk bayt sessizce yanlis satirlara
    cozuluyordu (`PageVerify`/`PageCheckStruct` yalniz `Verify`/`vdbcheck`
    tarafindan kullaniliyordu). Denetim: trunk sayfalari atlanir (ham
    `VFT1` imaji), yeni uzatilmis bos sayfaya izin verilir; sihirli sayi
    bozuksa, basliktaki sayfa numarasi istenenden farkliysa ya da CRC
    tutmuyorsa kontrollu `ecCorrupt`. `VerifyOnRead` ozelligi (varsayilan
    acik) dogrulamayi kapatabilir; sifreli dosyada GCM etiketi zaten
    dogruladigi icin o yol degismedi.
  - `page_corrupt` **8 PASS / 0 FAIL**. Olculen: saglam dosya tam okunur;
    `VerifyOnRead` varsayilan acik; her veri sayfasinin govdesindeki tek
    bayt bozulmasi yakalanir (17/17 sayfa); bozuk sihirli sayi ve yanlis
    sayfa imaji kontrollu `ecCorrupt`; saglam kopya bayt bayt degismemis
    ve hala kusursuz taranir (yanlis pozitif yok).
  Diger kapilar degismedi (`cache_pressure` 8/0, `limits` 18/0,
  `sql_features` 32/0, `multi_writer` 12/0, `bench_report` 35/0 dahil).
- Yirmi dorduncu kosu (PHASE-21 commit'i, SKILL3 §12.1 sunucu hata yollari):
  **iki platform da YESIL**. Git Bash/Windows **32 kapi** PASS (`tls_client`
  SKIP), WSL x86_64 Linux **33 kapi** PASS. Bir motor duzeltmesi ve bir
  yeni kapi:
  - **v3.39 `VDbNet.VdbRecvStr`**: gelen tek metin cercevesinin uzunluk
    oneki icin ust sinir yoktu (eski sinir 1 GiB). Kimligi dogrulanmamis
    bir istemci tek cerceveyle sunucuda ~1 GiB ayirmaya zorlayabiliyordu.
    `VDBS_MAX_RECV_STR = 64 MiB` eklendi: onek tahsis yapilmadan reddedilir
    ve yalniz baglanti duser; sunucu ve dosya etkilenmez.
  - `server_failure` **16 PASS / 0 FAIL**. Olculen: sunucu acilir; el
    sıkışması (protokol surumu 1 + ad) dogru; giris + `CREATE TABLE` +
    `INSERT` + `SELECT COUNT(*)`; `MaxConns=1` iken tavan ustu baglanti
    `RSP_ERROR` + `kapasite dolu` alip kapanir ve mevcut baglanti calismaya
    devam eder; 64 bayt cop bayt ($FF) sunucuyu oldurmez; `CMD_QUERY` +
    sahte 96 MiB uzunluk oneki (v3.39 oncesi kabul edilirdi) reddedilir ve
    sunucu yasar; acik baglanti varken `Stop` doner ve `Ready=False` olur;
    `.odb` yerinde kalir, yeniden acilir ve satiri okur.
  Diger kapilar degismedi.
- Yirmi besinci kosu (PHASE-22 commit'i, SKILL3 §12.1 disk dolu + §12.2
  islem sayisi): **iki platform da YESIL**. Git Bash/Windows **34 kapi** PASS
  (`tls_client` SKIP), WSL x86_64 Linux **35 kapi** PASS (OpenSSL istege
  bagli iki kapi SKIP). Iki motor duzeltmesi ve iki yeni kapi:
  - **v3.40 disk dolu / kisa yazma** (`WriteBytesChecked`): butun sayfa ve
    meta yazmalari tek noktadan gecer; `THandleStream.Write` kisa yazmayi
    `0`'a cevirdiginden ENOSPC sessiz kalabiliyordu. Enjekte edilen hata ya
    da kisa yazma kontrollu `ecIOError` uretir, cerceve kirli kalir.
    `GrowTo` basarisiz buyumeyi `ecIOError`'a cevirir ve mantiksal boyu
    artirmaz.
  - **v3.40 monoton meta** (`SaveMeta`): gorunumu bayat bir oturum kendi
    dusuk LSN'ini ve sayfa sayisini meta sayfaya yazabiliyordu. LSN
    gerilemesi yeniden acilisi `EVdbPageStale` ile kilitliyor, sayfa sayisi
    gerilemesi `TrimToLogical` uzerinden onayli sayfalari kirpabiliyordu.
    Artik meta yalnizca yukari tasinir.
  - `disk_full` **9 PASS / 0 FAIL**. Olculen: kontrollu yazma; sert yazma
    hatasi; kisa yazma; `ROLLBACK` sonrasi onayli satirlar; hata sonrasi
    yazmanin devami; checkpoint; yeniden acilis + `VERIFY`.
  - `txn_limit` **18 PASS / 0 FAIL**. Olculen: 300 kisa islem ve 300
    islemin 75'i geri alinarak commit sayisi birebir; oturum basina tek
    acik islem (ic ice `BEGIN`, islem yokken `COMMIT`/`ROLLBACK` sessiz
    no-op); dosya basina tek yazar rezervasyonu kisa busy suresinde
    kontrollu `mesgul`, `ROLLBACK` ile temizlenir ve birakilinca islem
    tamamlanir; temiz kapanis tek dosya; yeniden acilista 578 satir +
    temiz `VERIFY`.
  Diger kapilar degismedi.
- Yirmi altinci kosu (PHASE-23 commit'i, SKILL3 §12.1 disk dolu - WAL
  yolu): **iki platform da YESIL**. Git Bash/Windows **34 kapi** PASS
  (`tls_client` SKIP), WSL x86_64 Linux **35 kapi** PASS (OpenSSL istege
  bagli iki kapi SKIP). Bu kosuda uc motor duzeltmesi ve `disk_full`
  kapisinin WAL/meta kapsami dogrulandi:
  - **v3.41 WAL yazma hatasi** (`VDbPageWal.WriteChecked`): WAL commit
    kaydi ve basligi tek noktadan yazilir; gercek `EWriteError` ve kisa
    yazma kontrollu `ecIOError`'a cevrilir, yarim kuyruk `startPos`'a geri
    kirpilir ve `FWrittenBytes`/`FAtEnd` tutarli kalir.
  - **v3.41 hayalet commit** (`TVdbBackendV3.CommitBatch`/`AbortBatch`):
    `CommitNoSync` ve etiket sayaci birlestirme `pendExc` korumasinin
    DISINDAYDI; WAL yazimi basarisiz oldugunda yazma kumesi coktan
    silindigi icin kurtarma atlaniyor, satirlar ayni oturumda gorunmeye
    devam ediyor ve durabil hale gelebiliyordu. Artik ikisi de koruma
    icinde; hata yolunda `RecoverAfterDurabilityFailure` (+
    `FWal.Rollback`) calisir ve canli satir sayaci gecersiz kilinir;
    `AbortBatch` kendi `TagDelta`'sini temizler.
  - `disk_full` **16 PASS / 0 FAIL** (`9`'dan genisletildi). Yeni olcum:
    WAL commit yazimi hatasi kontrollu `ecIOError`, basarisiz commit
    HAYALET satir birakmaz (ayni oturumda `COUNT(*)` = durabil kume),
    meta sayfa yazimi hatasi checkpoint'te kontrollu hata verir; ardindan
    checkpoint basarili, yeniden acilis + `VERIFY` temiz.
  - `txn_limit` **18 PASS / 0 FAIL** (degismedi).
  Diger kapilar degismedi.
- Yirmi yedinci kosu (PHASE-24 commit'i, SKILL3 §12.1 bellek tukenmesi):
  **iki platform da YESIL**. Git Bash/Windows **35 kapi** PASS
  (`tls_client` SKIP), WSL x86_64 Linux **36 kapi** PASS (OpenSSL istege
  bagli iki kapi SKIP). Bu kosuda bir KRITIK kusur bulundu ve kapatildi:
  - **F16 (KRITIK) - atomik olmayan sayfa ayirma**
    (`VDbPageStore.ExtendFile`/`AllocPage`): commit sirasinda bir tahsis
    basarisiz oldugunda sayfa numarasi `FPageCount`'a eklenmis ama sayfa
    dosyada HIC baslatilmamis oluyordu. Yeniden acilis taramasi bu sifir
    sayfayi `EVdbHeap: sayfa N taninmiyor (ne VDbPage ne trunk)` diye
    reddediyordu, yani veritabani ACILMIYORDU. Artik `ExtendFile` once
    dosyayi buyutur sonra `Inc(FPageCount)` yapar; `AllocPage` yalnizca
    BU cagrinin actigi sayfayi geri alir (numarayi yayinlamaz). Freelist
    sayfasi sizinti olarak kalabilir; diskteki imaji gecerli oldugu icin
    bozulma degil.
  - **Yeni kapi `oom` 9 PASS / 0 FAIL**: `VDbMM` uzerinde YALNIZ test
    icin enjeksiyon (`MMInjectFault`/`MMInjectClear`/`MMInjectHits`/
    `MMInjectActive`; esik ustu tek tahsis `EOutOfMemory` verir, sonra
    kendini kapatir). Okuma ve yazma yolu ayri olculur; basarisiz commit
    hayalet satir birakmaz, hata sonrasi yazma devam eder, checkpoint
    basarili, yeniden acilista 200 satir + temiz `VERIFY`.
  - Not: enjeksiyonun `nil` dondurmesi YANLIS bir simulasyondu - FPC RTL
    `SetLength` icinde `nil`'i `EAccessViolation`'a ceviriyor; gercek
    yigin `EOutOfMemory` firlatir, enjeksiyon da oyle yapar.
  - `disk_full` **16 PASS / 0 FAIL**, `txn_limit` **18 PASS / 0 FAIL**
    (degismedi; ayni kosuda yeniden dogrulandi).
  Diger kapilar degismedi.
- Yirmi sekizinci kosu (PHASE-25 commit'i, SKILL3 §13 B+Tree olcek + VACUUM):
  **iki platform da YESIL**. Git Bash/Windows **36 kapi** PASS
  (`tls_client` SKIP), WSL x86_64 Linux **37 kapi** PASS (OpenSSL istege
  bagli iki kapi SKIP). Kapi once yalniz olcum olarak yazildi; Linux'ta
  BS11 kirmizi cikinca **iki gercek motor hatasi** olculdu ve duzeltildi
  (v3.43) - yani SKILL3'un "olculebilir sorun olmadan degisiklik yok"
  kurali tam olarak isini yapti: sorun olculdu, sonra duzeltildi.
  - **F17 (KRITIK): Unix'te her acilis bir dosya tanitici sizdiriyordu.**
    `VDbSync.VDbOpenStreamNoFlock` fd'yi `FpOpen` ile acip
    `THandleStream`'e sariyordu; FPC'nin `THandleStream.Destroy` handle'i
    KAPATMAZ. Windows'ta belirti vermez; WSL `/mnt/d` (9p) uzerinde ise
    sinsi: acik handle'i olan bir dosyanin `rename`'i True doner ama
    tembel uygulanir (dosya iki adin altinda da gorunmez). Bu yuzden
    `VACUUM`'in `.bak` degisimi yeni dosyayi acamadi, eskisini geri
    koydu ve **VACUUM hic yer kazanmadi** (BS11 `eski=1601536
    yeni=1449984`). Duzeltme: `TVDbFdStream = class(THandleStream)` +
    `Destroy`'da `FpClose(Handle)` (repodaki tek `THandleStream.Create`).
  - **F18 (KRITIK): basarisiz dosya degistirme sessizce basarili
    gorunuyordu.** `SwapDbFileWith`'in dis `except`'i hatayi yutuyordu;
    `.bak` geri kurulumu basarisiz olsa bile `Compact`/`RESTORE`/`REKEY`
    normal donuyor, VACUUM sahte `kazanc` sayilari basiyordu (F17 ile
    birlesince Linux'ta tam olarak bu oldu). Artik acik hata firlatilir ve
    hata yukari tasinir; backend `FEng=nil` ile kilitsiz birakilmaz.
  - **Yeni kapi `btree_scale` 15 PASS / 0 FAIL** (BS1-BS14), iki
    platformda da: bellekte 1.000.000 anahtar (karisik sirada) ->
    yukseklik **4**, **14.965** yaprak, ortalama doluluk **66/96**,
    degismezler temiz, `All()` artan, 8.000/8.000 `Find`,
    `CountRange(k100000..k199999)=100000`, `RankBefore(k500000)=500000`.
  - Olcek (platform adiyla): Windows 100k **219 ms**, 1M **8.203 ms**;
    Linux 100k **281 ms**, 1M **12.789 ms**. Toplam oran 35-46x
    YANILTICI (i386/x86_64'te 1M anahtar onbellek disina tasar); dogru
    olcu **islem basina** maliyet: Windows **3,75x**, Linux **4,55x**,
    karesel agacta ~10x olurdu. Esik 6.
  - Churn: 500.000 silme 1.265 ms (Windows) / 1.466 ms (Linux),
    yukseklik 4'te kalir; yarisi yeniden eklenince yaprak 14.965 ->
    14.979 (**1,00x**) - yaprak parcalanmasi yok.
  - Disk (iki platformda da ayni): 6.000 satir 1.449.984 bayt mantiksal /
    1.601.536 fiziksel; %90 silinince dosya KUCULMEZ (belgelenen
    davranis, `oluBayt=0` cunku `GetDeadBytes` yalniz freelist
    sayfalarini sayar); `VACUUM` 1.601.536 -> 151.552 bayt (**%90
    kazanc**); satir sayisi 600 birebir, degerler dogru; yeniden 600
    satir eklenince 294.912 bayt (tavan 1.449.984, sisme yok); yeniden
    acilis + `VERIFY` temiz (`sayfa=72 serbest=0 heap=71 tasma=0
    trunk=0 anahtar=1201 lsn=5`).
  - `oom` **9 PASS / 0 FAIL**, `disk_full` **16 PASS / 0 FAIL**,
    `txn_limit` **18 PASS / 0 FAIL** (degismedi; ayni kosuda yeniden
    dogrulandi).
- Yirmi dokuzuncu kosu (PHASE-26 commit'i, SKILL3 §6.3 WAL sert boy tavani):
  **iki platform da YESIL**. Git Bash/Windows **37 kapi** PASS
  (`tls_client` SKIP), WSL x86_64 Linux **38 kapi** PASS (OpenSSL istege
  bagli iki kapi SKIP). Yeni kapi `wal_limit` **19 PASS / 0 FAIL**, iki
  platformda birebir ayni cikti.
  - **Yeni kapi `wal_limit` 19 PASS / 0 FAIL** (WL0-WL9b): `WalMaxBytes`
    tavanini 300 000 bayta indirir; 100 autocommit ekleme tavanin cok
    altinda kalir ve rahatlatma checkpoint'i gercekten calisir
    (`checkpoint 0 -> 11`, `wal=20580`); `VAL_LEN=6000` ile 250 satirlik
    tek islem commit aninda `ecLimit` alir
    (`WAL boyu siniri asildi (2090928 bayt > 300000 bayt)`); reddedilen
    islem hayalet satir birakmaz (`COUNT(*) = 100`), hemen ardindan gelen
    kucuk yazim basarilidir (ret kilidi yok), silme sayiyi geri getirir,
    WAL tavanin altina doner (`wal=49432`); ayni islem `WalMaxBytes := 0`
    ile commit edilir (350 satir); tavan yeniden acilip acik checkpoint
    yapildiktan sonra 5 satir daha eklenir (355 satir, `wal=86516`) ve
    yeniden acilis + `VERIFY` temizdir.
  - **Tasarim (olculen bir yanlis yol dahil)**: ilk denemede otomatik
    rahatlatma `MaybeCheckpoint` icinde `Wal.Bytes >= WalMaxBytes`
    kosuluna baglanmisti; **bu dal olu koddur**, cunku basarili her commit
    `Bytes <= cap` birakir. Ilk kosu tam olarak bunu gosterdi: tavan 300
    000 iken 100 autocommit eklemenin 2 cercevelik son commit'i
    `309040 > 300000` ile reddedildi. Duzeltme: sert kontrol yalniz
    `DoCommit` icinde (commit kaydi yazilmadan once) kalir; rahatlatma
    `MaybeCheckpoint` icinde tavanin **yarisinda** tetiklenir
    (`FWalMaxBytes div 2`), yani kucuk yazimlar tavana hic yaklasmaz ve
    yalnizca tek basina sigmayan bir islem reddedilir.
  - `MaybeCheckpoint` ayrica `FEng = nil` ve `FEng.InTxn` korumalarini
    tasir: acik islem varken checkpoint KIRLI sayfalari diske yazar ve
    yarim islemi kalicilastirirdi.
  - Diger kapilar degismedi (`sql_differential` yine `pg=not-run`).
- Otuzuncu kosu (PHASE-26 ikinci commit'i, genis ag fuzz'i): **iki
  platform da YESIL**. Git Bash/Windows **38 kapi** PASS (`tls_client`
  SKIP), WSL x86_64 Linux **39 kapi** PASS (OpenSSL istege bagli iki kapi
  SKIP). Yeni kapi `net_fuzz` **39 PASS / 0 FAIL**, iki platformda birebir
  ayni cikti.
  - **Yeni kapi `net_fuzz` 39 PASS / 0 FAIL**: onceki en genis ag testi
    `server_failure` icindeki iki bozuk cerceveydi (SF5: 64 x `$FF`,
    SF6: `$06000000` uzunluk oneki) ve o kapi **VDB ikili protokolunu**
    hedefliyordu, PG wire'i degil. Yeni kapi gercek `TVdbPgServer`'i
    loopback'te trust modda, `MaxConns=256` ile dener (kapasite asla
    basarisizlik nedeni olmasin; SF4 zaten `MaxConns` sinirini olcuyor).
  - **Oracle her saldirida ayni**: bozuk girdiden sonra sunucu cokmemeli ve
    **gecerli** bir istemci startup'i tamamlayip `SELECT 1` yanitini
    almalidir; kapi "sunucu ayakta" demiyor, gercek sorgu yanitini olcuyor.
  - **Saldiri aileleri (N1-N15)**: startup uzunlugu `70000` ve `2^31-1`
    (baslik gonderilir, dev tahsis yapilmaz), kesik startup (100 ilan, 10
    bayt), `0`/`4`/`0xFFFFFFFF`, bilinmeyen protokol kodu `196609`, 512
    rastgele bayt, gecerli startup sonrasi 30 rastgele mesaj tipi/govdesi,
    `Q` uzunlugu `64MB+1`, `Q` uzunlugu `3`, ilan edilip kesilen `Q`
    govdesi, NUL'suz + kontrol baytli (`$01`, `$1b`, gomulu NUL) + bos
    sorgu, **20 ardisik `SSLRequest`** (her biri `N` yaniti, sonra ayni
    sokette gercek startup + sorgu), 40 kisa cop baglanti (accept/temizlik
    yolu), 120 yinelemeli **tohumlanmis** mutasyon dongusu (kendi LCG'si,
    `Randomize`/uyku yok; her 20 yinelemede canlilik kontrolu, en az 100
    baglanti sarti), bozuk genisletilmis protokol (`P` bos, `P` 2 OID ilan
    edip 4 bayt gonderme, `B` olmayan statement'a baglanma, bos `E`/`D`)
    ve 4 is parcacigi x 8 eszamanli fuzz.
  - **Kapi yazilirken bulunan hata test istemcisindeydi, sunucuda degil**:
    genisletilmis protokol hatasindan sonra sunucu `skipUntilSync` ile
    yalnizca `Sync` bekler ve `Z` gondermez; istemci `Z` bekledigi icin
    N14 kilitlendi. Duzeltme: her bozuk mesajdan sonra `Sync` gonderilir ve
    sonra gercek sorgu ile toparlanma dogrulanir. Sunucu davranisi **dogru**
    cikti, bu yuzden motor tarafinda degisiklik yapilmadi; kapinin degeri
    tam olarak bu davranisi kilitlemesidir.
  - `MaybeCheckpoint`, `DoCommit` ve `wal_limit` degismedi; diger kapilar
    ayni (`sql_differential` yine `pg=not-run`).
- Otuz birinci kosu (PHASE-27, ayri B+Tree disk sayfa bicimi): **iki
  platform da YESIL**. Git Bash/Windows **39 kapi** PASS (`tls_client`
  SKIP), WSL x86_64 Linux **40 kapi** PASS (OpenSSL istege bagli iki kapi
  SKIP). Yeni kapi `btree_disk` **78 PASS / 0 FAIL**, iki platformda
  birebir ayni cikti. Diger butun kapilar degismedi (`sql_differential`
  yine `pg=not-run`).
  - **Yeni birim `VDbBTreeDisk.pas`, ama v5'e BAGLI DEGIL**: bu kosu v5
    motor dosya bicimini, WAL'i ve kurtarma davranisini **degistirmez**;
    tablo satirlari hala 4 KB sayfa yigini uzerindedir ve ikincil
    indeksler hala bellekteki `TVDbBTree`'dir. Burada olculen sey sayfa
    biciminin kendisidir (bolunme, siralama, atomik commit, yirtik meta
    geri donusu, cokme noktasi, bozulma tespiti, sayfa geri kazanimi).
  - **Golge sayfalama (shadow paging) ile atomik commit**: degisen her
    sayfa yeni bir numaraya kopyalanir, kokten yapraga yol yeniden
    yazilir, **meta en son** yazilir ve meta yazimi commit noktasidir.
    Meta'dan once cokme olursa eski agacin sayfalari hic degismemistir;
    baglanmamis sayfalar acilista erisilemez oldugu icin serbest sayilir
    ve yeniden kullanilir (sizinti kendiliginden geri kazanilir).
  - **Yirtik meta**: iki A/B kopyadan CRC'den gecen en yuksek `Seq`
    kazanir; en yeni kopya bozuksa eskisi kullanilir ve eskisinin agaci
    da bozulmamis oldugu icin meta yazimi atomiktir. Olculen: 300
    anahtarlik onceki agac aynen acilir, 301-600 gorunmez.
  - **Cokme noktasi olcumu**: `OnBeforeMeta` kancasi meta yazimindan
    hemen once dosyayi kopyalar; kopya acildiginda onceki 200 anahtarin
    TAMAMI bulunur ve `Verify` temizdir (veri kaybi yok). Asil dosya
    commit'ten sonra 400 anahtarla devam eder.
  - **Silme tembel**: yalnizca bosalan sayfa agactan dusurulur, yarim
    dolu sayfalar birlestirilmez; yukseklik yalnizca kok tek cocuga
    indiginde azalir. Doluluk maliyeti gizlenmez, olculur: churn sonrasi
    `yaprak=36 hucre=6000 doluluk=96000/147456` (~%65). Birlestirme/
    yeniden dagitma yoktur; eklenirse ayri olcum ister.
  - **Kapi yazilirken bulunan uc gercek kusur** (ucu de ayni commit'te
    duzeltildi): (1) Windows'ta `VDbOpenStreamNoFlock(..., Create=True)`
    `fmCreate`'e dustugu icin **her yeniden acilis dosyayi sifirliyordu**
    - `FileExists` ayrimiyla duzeltildi (`VDbPageStore` ile ayni desen);
    (2) kurucunun istisna yolunda `FMap`/`FStream` serbest birakilip nil
    yapilmadigi icin yikici ikinci kez serbest birakiyordu (access
    violation) - `FreeAndNil` + nil kontrolleri; (3) `Verify` bozuk bir
    alt-cocuk isaretcisinde istisna sizdiriyordu - artik bunu da bulgu
    olarak raporlar ve `False` doner.
  - Bozuk dosyada okuma yolunun siniri belgelendi: `Find`/`NextAfter`/
    `Walk` aralik disi sayfa numarasinda **kontrollu `EBtdError`** atar
    (sessiz `False` bozulmayi gizler ve daha tehlikelidir); sayfa CRC'si
    her okumada zorlanmaz (okuma basina 4 KB CRC maliyeti), CRC `Verify`
    icinde ve acilista meta seciminde kullanilir.
