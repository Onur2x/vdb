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
| `maint_lock` | **surecler arasi bakim kilidi** (SKILL5 7.1-7.4). Iki gercek surec: (a) ML1 tek surecte `VACUUM` basarili ve satir sayisi korunur; (b) ML2a-ML2e cocuk surec `BeginBatch` ile **acik yazma islemi** tutarken ebeveyn `Compact` `bakim kilidi alinamadi: acik bir yazma islemi var` ile **reddedilir** (fail-closed), cocuk commit etmesine ragmen 5 satir korunur - cocuk tarafi MARKER'dan once `CHILD wtxn RESERVE-HELD=TRUE` yazarak `.gen` yazar rezervasyonunun gercekten tutuldugunu kanitlar; (c) ML3a-ML3c acik **salt-okunur oturum** varken bakim ya reddedilir (Windows: acik handle rename'i engeller) ya da sonrasinda o oturum `veritabani dosyasi degistirildi ... eski dosyaya bagli` hatasi alir - bayat okuma (COUNT=100) yasak; (d) ML4/ML4b/ML4c ikinci surecten `Compact` sonrasi satirlar korunur ve `Verify` temiz; (e) ML5 `.tmp` kalintisi kalmaz; (f) ML6a/ML6b dizin fsync'inin **cagrildigini ve kapsamini** kanitlar (kanca cagri sayisi + fsync edilen dizinler); (g) ML7a-ML7c fsync **basarisiz** oldugunda bakimin **fail-closed** oldugunu, `.bak`tan geri dondugunu ve verinin korundugunu kanitlar (**19 PASS / 0 FAIL**; on-kapi Windows 16/3, Linux 16/3 - on-kapida ML6a `cagri=0`, ML6b bos dizin listesi, ML7a zorla fsync hatasina ragmen VACUUM "basarili") |
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
| `sql_authorization` | **SQL yetki/RLS/trigger kapisi** (Sprint A, 3.2-3.4): baglanti yetkisiz baslar (kimlik yoksa `Start` reddeder, varsayilan `admin/admin123` kaldirildi); `GRANT`/`REVOKE` sonrasi izinli/izinsiz DML; RLS policy `USING`/`WITH CHECK` (SELECT/INSERT/UPDATE/DELETE); **upsert** yolunun UPDATE yetkisi, RLS ve ROW trigger uygulamasi; **MERGE** hedef satir RLS filtresi + BEFORE/AFTER ROW ve STATEMENT trigger'lari. **AU8-AU11 (Sprint C2)**: rol **oturum bazlidir** - tek `TVTableDb` uzerindeki iki `TVSql` oturumundan birinin `SET ROLE` cagrisi digerinin yazma yetkisini **etkilemez** (AU8); bilinmeyen rol adi SELECT/INSERT/ALL icin **reddedilir**, motor kullanici modu serbest kalir (AU9, fail-open kapandi); oturum kapsami ve `SET ROLE NONE` semantigi (AU10); `DROP ROLE` silinen rolu oturumdan temizler (AU11). **AU12 (Sprint M, SKILL6 02)**: kimligi dogrulanmis principal **SQL rolune baglanir** (`BindSessionPrincipal`); rolsuz principal **yetkisizdir** (bos rol artik sinirsiz yetki degil, fail-closed) ve RLS uygulanir; `SET ROLE NONE` **taban role** doner (eskiden yetki yukselmesiydi); uye olunmayan role gecis `ecPermissionDenied` ile **reddedilir** (yalniz Super taban rol serbest); oturum kimlikleri **benzersiz ve sifir degil** (isaretci kirpintisi kaldirildi) ve `TVSql.Destroy` oturum durumunu **siler** (rol mirasi yok). 62 kontrol, iki platformda 62/0. Duzeltme oncesi kaynakla (`git archive HEAD` = `7b54faa`, yalniz `BindSessionPrincipal`/`SessionId` icin **API seam** (davranis HEAD)) derlenen sonda **6 kontrol FAIL**: AU12 rolsuz principal SELECT/INSERT, app rollu principal INSERT denetlenmiyor, `SET ROLE NONE` yetki yukselmesi, uye olunmayan role gecis. Sprint C2 on-kapisinda ayrica AU8 x2 / AU9 x3 FAIL idi |
| `sql_atomicity` | **SQL statement atomikligi kapisi** (Sprint A 3.5 + Sprint B): AFTER/BEFORE **STATEMENT** ve ROW trigger hatalarinda statement'in **tamami** geri alinir, trigger govdesindeki DML de geri alinir; ana tablo/indeks/audit degismez. AT1-AT5: AFTER STATEMENT hatasi (cok satir INSERT, UPDATE, DELETE, tek satir INSERT, COPY). AT6-AT10: BEFORE STATEMENT gercekten atesleniyor + DML'i statement ile kalici; BEFORE INSERT/UPDATE/DELETE hatasi; 0 satir eslesen DELETE'te trigger DML'i korunur (B4). AT11-AT12: BEFORE/AFTER ROW hatasi. AT13: 2. satirda duplicate PK -> hic satir kalmaz. AT14: MERGE AFTER STATEMENT hatasi. AT15: RETURNING tutarliligi (basarili -> satirlar yazilir; hatali -> iz yok). AT16: hatali statement sonrasi yeniden acilista iz yok. AT17: explicit transaction icinde statement hatasi + `ROLLBACK`. AT18/AT19: BEFORE STATEMENT trigger DML'i ana INSERT/COPY hatasiyla geri alinir (B1). **AT20-AT24 (Sprint B2)**: explicit transaction icinde statement hatasindan sonra `COMMIT` yarim yazimi **kalici yapmaz** (AT20); onceki basarili statement'in satiri korunur, hatali statement'in satiri kalmaz (AT21); hatali statement'in anahtari sonraki statement'ta yeniden kullanilabilir, yani kaplama defteri temizlenir (AT22); UNIQUE cakismasiyla yarida kalan `UPDATE` geri alinir, onceki `UPDATE` korunur (AT23); kullanici `SAVEPOINT`'i ortuk kapsamdan etkilenmez, `ROLLBACK TO`/`RELEASE` calisir (AT24). 24 vaka, **138 kontrol**, iki platformda 138/0. Kapi duzeltme oncesi kaynakla derlenen sonda 6 kontrol FAIL verir (AT20 x2, AT21 x2, AT22, AT23 - hepsi COMMIT sonrasi yarim yazim), yani bos yesil degildir. ONEMLI: eski 8 FAIL iddiasi AT8/AT9/AT10/AT18/AT19 icindi; bu sprintte ayni kaynakla olculen guncel deger 6 FAIL'dir |
| `limits` | **kaynak sinirlari** (SKILL2 §25): 4 MiB'tan buyuk SQL, 16 MB'lik INSERT ve 2M ustu `LIMIT` kontrollu `ecLimit` ile reddedilir; reddedilen islem **hicbir satir birakmaz**, ayni veritabani sorgulanmaya devam eder, kapanis temiz (yalniz `.odb`) ve yeniden acilista veri bozulmamis olur; belgelenen tavanlar (`LIMITS.md`) tutarli |
| `sql_memory` | **SQL sinir ve sayisal uc davranis kapisi** (Sprint F1, 8.2 + 8.4 + 8.5): 26 vaka, **54 kontrol**. SM1-SM7 tam siralamanin (ASC/DESC, NULL ilk/son) **onegi** olarak `ORDER BY ... LIMIT/OFFSET` (tek ve cok anahtar) - streaming kisayolu ile genel yurutucu ayni sonucu verir. SM8 `LIMIT 0`; SM9 negatif `LIMIT`/`OFFSET` -> `ecSyntaxError`; SM10 `OFFSET 1000000000`/`2147483647` -> 0 satir; SM11 tavan asimi (`VDB_MAX_RESULT_ROWS+1`, `LIMIT+OFFSET` toplami) -> `ecLimit` (kismi sonuc yok). SM12-SM14 3VL (`= NULL`, `IS NULL`, `NOT`, `IN`/`NOT IN` NULL'lu, `BETWEEN NULL`) ve `COUNT(col)` 5 / `COUNT(*)` 6 / `AVG` 3.5. SM15 `CAST` 22/24 haneli metin ve `'abc'` -> `ecTypeMismatch` (tasma sessiz sarma **yok**); SM16 Int64 max/min tam; SM17 `-9223372036854775808` literali tam; SM18 `+`/`*` tasmasi -> `ecMathError`; SM19 `1/0` ve `1.0/0.0`; SM20 `ABS` tam sayi hassasiyeti + `ABS(Low(Int64))` -> `ecMathError`; SM26 kolondaki `Low(Int64)` korunur, `SELECT -v` -> `ecMathError`. SM21 ozyinelemeli CTE 100 satir (COUNT/MIN/MAX); SM22 **sinirsiz** ozyineleme -> `ecLimit` (sessiz kesme yok) ve tablo saglam; SM23 `QueryTimeoutMs := 60` ile derin ozyineleme -> `ecQueryTimeout`; SM24 `CancelQuery` -> `ecCancelled`, ardindan `ResetCancel` ve normal sorgu. SM25 kapanis temiz (yalniz `.odb`), yeniden acilista 6 satir ve ayni sira. Iki platformda 54/0. Duzeltme oncesi kaynakla (`git archive HEAD`) derlenen sonda **6 kontrol FAIL** (SM15 x2 CAST sarmasi, SM20 x2 `ABS` float/`ABS(Low)`, SM22 sessiz kesme, SM26 isaret sarmasi) |
| `wal_recovery` | **WAL-before-data ve kurtarma basarisizligi kapisi** (Sprint C, 4.1 + 4.2): checkpoint WAL bariyerini (fsync + durabil LSN dogrulama) veri sayfalari yazilmadan **once** kurar; WAL fsync hata enjeksiyonuyla checkpoint basarisiz olur ve yeniden acilista **hayalet commit gorunmez** (WR1: `COUNT` tabanda kalir, anahtar yok). WR2 `CP_BEFORE_FLUSH` kancasinda `Engine.DurableLsn >= Wal.WrittenLsn` olcer (eski sirada `durable=0 written=3`). Kurtarma basarisizligi motoru **POISONED** yapar: `ecInvalidState` ile backend okumasi, motor okumasi ve yazma reddedilir, `PoisonReason` dolu; kapatip acma temiz baslangic ve yazilabilirlik verir (WR3). Basarili kurtarma durabil satiri korur, fsync edilmemis satiri atar, motoru yeniden yazilabilir kilar (WR4). Normal yol zehirlenmez (WR5). 5 vaka, **27 kontrol**, iki platformda 27/0. Duzeltme oncesi kaynakla derlenen sonda 3 kontrol FAIL (`wr1/durable-kept`, `wr1/no-ghost-row`, `wr2/wal-durable-before-flush`) |
| `freelist` | **serbest sayfa listesi butunlugu kapisi** (Sprint D, 5.1): freelist indeksi (trunk zinciri) tembel bit eslemleriyle tutulur (`FFreeBits`/`FTrunkBits`, yalniz `FreeIndexEnsure` zincirden kurar, `FreePage`/`AllocPage` gunceller). FL1 ayni sayfayi ikinci kez serbest birakmayi, FL2 **trunk** sayfasini serbest birakmayi, FL3 **canli hucre tasiyan** heap sayfasini serbest birakmayi reddeder (`EVdbPageStore`); FL4 cok trunk / trunk dolmasi / bos trunk ve `FreeCount` tutarliligini; FL5 trunk zinciri **dongusunde** acik hata verir, sonsuz dongu yok; FL6 yinelenen, FL7 aralik disi serbest girdide acik hata; FL8 bozuk freelist ile **acilis** (heap taramasi) acik hata verir; FL9 saglikli depoda `CollectFreePages` ile `VerifyFreeList` ayni sonucu verir. 9 vaka, **32 kontrol**, iki platformda 32/0. Duzeltme oncesi kaynakla (`git archive HEAD`) derlenen sonda **4 kontrol FAIL** (cift serbest birakma, trunk, canli sayfa, yinelenen girdi) |
| `cache_pressure` | **onbellek tukenmesi / tahliye** (SKILL3 §12.1): 8 sayfalik havuzla (~32 KB) havuzdan cok daha buyuk bir tablo uzerinde calisilir. Tam tarama **butun satirlari** dogru okur (tahliye + yeniden yukleme veri kaybetmez), `PoolUsed` havuz boyunu asmaz, miss sayaci gercek tahliyeyi kanitlar, tek islemde 2000 satir guncellemesi (kirli sayfa tahliye yolu) commit edilir ve **yeniden acilista** guncel veri kalicidir; temiz kapanistan sonra yalniz `.odb` kalir |
| `page_corrupt` | **okuma yolunda sayfa butunlugu** (SKILL3 §5.3/§12.1): normal okuma yolu artik dogrulama yapar. Her veri sayfasinin govdesinde tek bayt bozulmasi, bozuk sihirli sayi ve yanlis sayfa imaji (sayfa 2 imaji sayfa 3'e kopyalanmis) kontrollu `ecCorrupt` uretir; dosyanin saglam kopyasi hala kusursuz taranir (kapi yanlis pozitif uretmez). Sifreli dosyada GCM etiketi zaten dogruluyor |
| `server_harden` | dinleme adresi, `--trust` sinirlari, TLS zorunlulugu. **S12-S15 (Sprint G1, F-37)**: `TVdbPgServer` artik **guvenli varsayilanlarla** gelir - bind varsayilani `127.0.0.1`, uzak (loopback disi) adres ancak kimlik dogrulama **ve** `RequireTls=True` ile kabul edilir (`AllowInsecureRemote=True` bilincli kacis kapisi); `Start` ham adresi degil, `VdbResolveListenHost` ile **cozulmus** adresi dinler ve karar motor/soket acilmadan verilir. **36 kontrol**, iki platformda 36/0; on-kapi (HEAD + yalnizca yeni API kabugu) **6 FAIL** |
| `server_failure` | **sunucu hata yollari ve guvenli varsayilanlar** (SKILL3 §12.1, SKILL5 §5.1/§5.2/§9.3): (a) `MaxConns=1` iken ikinci baglanti `RSP_ERROR` + `kapasite dolu` alip kapanir, birinci baglanti sorguya devam eder; (b) yeni baglantiya 64 bayt cop ($FF) yazilip kapatilir, sunucu yasar; (c) `CMD_QUERY` ardindan sahte **96 MiB** uzunluk oneki gonderilir - v3.39 `VDBS_MAX_RECV_STR` (64 MiB) oneki tahsis yapmadan reddeder, sunucu yasar; (d) acik baglanti varken `Stop` doner ve `Ready=False` olur; (e) `.odb` dosyasi yerinde kalir ve yeniden acilip satirlari okur; (f) v3.62 guvenli varsayilanlar: SF9/SF9b varsayilan bind `127.0.0.1` ve kacis kapisi kapali, SF10/SF10b uzak bind politika ile reddedilir ve motor acilmaz, SF11 opt-in politikadan gecer, SF12/SF12b sessiz baglanti sunucu zaman asiminda kapanir, SF13 zaman asimi kurulamazsa baglanti sunulmaz, SF14/SF14b/SF14c esik sonrasi dogru parola reddedilir ve `AuthReset` sonrasi kabul, SF15/SF15b canli baglanti sayimi 1 -> 0 (**30 PASS / 0 FAIL**; on-kapi 7 FAIL) |
| `disk_full` | **disk dolu / kisa yazma** (SKILL3 §12.1 + SKILL5 8.1): sayfa, meta ve **WAL** yazmalari tek noktadan (`WriteBytesChecked` / `WriteChecked`) gecer; enjekte edilen sert hata ve yarim yazma (gercek `ENOSPC` davranisi) kontrollu `ecIOError` uretir, surec cokmez, cerceve **kirli** kalir. Basarisiz commit **hayalet satir** birakmaz (ayni oturumda `COUNT(*)` durabil durumla ayni). Hata + `ROLLBACK` sonrasi onayli satirlar durur, hata giderilince checkpoint ve yeni commit calisir, yeniden acilista tum onayli satirlar okunur ve `VERIFY` temizdir. **DF10a-DF10c (Sprint D2)**: checkpoint hata yolunda surecler arasi yazma kilidi **sizmaz** - meta yazimina sert hata enjekte edilip checkpoint `ecIOError` ile dusuruldukten sonra **ikinci bir backend** ayni dosyaya yazabilir ve yazdigi satiri okuyabilir. 16 -> **19 kontrol**, iki platformda 19/0. Duzeltme oncesi kaynakla (`git archive a3b97da`) **4 kontrol FAIL** (DF10b/DF10c + DF6/DF6b - sizinti kapanistan sonra da yeniden acilisi kilitliyordu) |
| `txn_limit` | **islem sayisi / yazar cakismasi** (SKILL3 §12.2): 300 kisa islem ve 300 islemin 75'i geri alinarak commit sayisi birebir dogrulanir (sessiz kayip yok). Belgelenen v3 semantigi olculur: ic ice `BEGIN`, islem yokken `COMMIT`/`ROLLBACK` **sessiz no-op**'tur (tek islem katmani). Dosya basina **tek yazar rezervasyonu** vardir: bir oturum tutarken digeri kisa busy suresiyle kontrollu `mesgul` hatasi alir, `ROLLBACK` ile temizlenir, rezervasyon birakilinca ayni islem basariyla tamamlanir; yeniden acilista tum satirlar + `VERIFY` temiz |
| `oom` | **bellek tukenmesi** (SKILL3 §12.1): `VDbMM`'e yalniz test icin `MMInjectFault` kancasi eklendi (esik ustundeki tahsislerde bir kez `EOutOfMemory`, sonra kapanir). Okuma ve yazma yollari ayri olculur; nil donen tahsis `SetLength` icinde `EAccessViolation`'a donustugu icin **yanlis** bir benzetimdi, gercek heap gibi `EOutOfMemory` atiliyor. **Bulunan gercek hata (F16, KRITIK):** yazma sirasindaki tahsis hatasi dosyada taninmayan sayfa birakiyordu (`EVdbHeap: sayfa N taninmiyor`); `ExtendFile` once buyutup sonra `Inc(FPageCount)` yapar, `AllocPage` yalnizca bu cagrinin actigi sayfayi geri alir. Hata sonrasi oturum yazmaya devam eder, hayalet satir yok, checkpoint ve yeniden acilis 200 satir + temiz `VERIFY` |
| `btree_scale` | **B+Tree olcek + VACUUM geri kazanma** (SKILL3 §13 olcum-once kurali: "olculebilir bir sorun olmadan spekulatif B+Tree degisikligi yok"): bellekteki `TVDbBTree`'ye 1.000.000 anahtar karisik sirada eklenir; yukseklik **4**, **14.965** yaprak, ortalama doluluk **66/96**, degismezler temiz, `All()` artan, 8.000 rastgele `Find`, `CountRange`/`RankBefore` analitik beklentiyle ayni. Olcek olcusu toplam sure degil **islem basina** maliyettir: 10x veride **3,75x Windows / 4,55x Linux** (karesel agacta ~10x); i386'da 1M anahtar onbellek disina tasindigi icin toplam oran 35-46x cikar ve tek basina yanilticidir. Yarisi silinip yeniden eklenince yaprak sayisi 14.965 -> 14.979 (**1,00x**), yani churn sonrasi yaprak parcalanmasi yok. Diskte 6.000 satir -> %90 sil (dosya kuculmez; `GetDeadBytes` yalniz freelist sayfalarini sayar) -> `VACUUM` **iki platformda da** 1,60 MB'i 151 KB'a indirir (**%90 kazanc**), satir sayisi birebir kalir, sonrasinda 600 satir daha eklemek dosyayi sisirmez, yeniden acilis ve `VERIFY` temiz. Kapi yazilirken **iki gercek motor hatasi** olculdu ve ayni commit'te duzeltildi (v3.43): Unix'te her acilista sizan dosya tanitici (F17) ve basarisiz dosya degistirmeyi basarili bildiren sessiz yutma (F18) - Linux'un yer kazanmadan `VACUUM` kazanci bildirmesinin nedeni buydu |
| `wal_limit` | **WAL icin sert boy tavani** (SKILL3 §6.3: "Any WAL limit must fail safely without corrupting committed data"): `VDB_WAL_MAX_BYTES` = 64 MiB varsayilan, `WalMaxBytes` ozelligi ile degistirilebilir (0 = kapali). Kapi tavani 300 000 bayta indirir ve su davranisi kilitler: 100 autocommit ekleme tavanin cok altinda kalir ve rahatlatma checkpoint'i **gercekten** calisir (`checkpoint 0 -> 11`); `VAL_LEN=6000` ile 250 satirlik **tek** islem commit aninda `ecLimit` alir ve mesaj tavani adlandirir (`WAL boyu siniri asildi (2090928 bayt > 300000 bayt)`); reddedilen islem **hayalet satir birakmaz** (`COUNT(*)` 100'de kalir), hemen ardindan gelen kucuk yazim basarilidir (ret kilidi yok), WAL tavanin altina doner, onceki onayli satirlar bozulmadan okunur; ayni islem `WalMaxBytes := 0` ile commit edilir (350 satir), acik checkpoint sonrasi yazim devam eder (355 satir, WAL tekrar tavan altinda) ve yeniden acilis 355 satiri + temiz `VERIFY` verir. Sert kontrol `DoCommit` icinde, butun cerceveler tampona girdikten ve `FWal.Bytes` kesinlestikten SONRA ama WAL'e tek bayt yazilmadan ONCE yapilir; temizlik backend'in mevcut `RecoverAfterDurabilityFailure` yolundadir (cift kurtarma yok). Iki platformda birebir ayni cikti: **19 PASS / 0 FAIL** |
| `net_fuzz` | **genis ag fuzz'i** (SKILL3 §6/§11: bozuk ag girdisi sunucuyu dusurmemeli): gercek `TVdbPgServer` (PG wire) loopback'te **trust** modda, `MaxConns=256` (kapasite asla basarisizlik nedeni olmasin diye). 15 saldiri ailesi + tohumlanmis deterministik mutasyon dongusu: startup uzunlugu `70000` ve `2^31-1`, kesik startup, `0`/`4`/`0xFFFFFFFF`, bilinmeyen protokol kodu, 512 rastgele bayt, gecerli startup sonrasi 30 rastgele mesaj tipi, `Q` uzunlugu `64MB+1`, `Q` uzunlugu `3`, ilan edilip kesilen `Q` govdesi, NUL'suz/kontrol baytli/bos sorgu, 20 ardisik `SSLRequest` (her biri `N`, sonra ayni sokette gercek sorgu), 40 kisa cop baglanti, 120 yinelemeli tohumlanmis mutasyon (her 20 yinelemede canlilik kontrolu), bozuk genisletilmis protokol (`P`/`B`/`E`/`D`) ve 4 is parcacigi x 8 eszamanli fuzz. Her saldiridan SONRA gecerli bir istemci startup'i tamamlayip `SELECT 1` calistirir; kapi sunucunun cokmedigini, baglanti kabul etmeye devam ettigini ve gercek sorgu yaniti verdigini boyle olcer. Kapi yazilirken bir **test istemcisi** hatasi ortaya cikti (genisletilmis protokol hatasindan sonra sunucu yalnizca `Sync` bekledigi icin istemci `Z` bekleyip kilitleniyordu; saldiri dizisi her bozuk mesajdan sonra `Sync` gonderir) - sunucu tarafinda degisiklik gerekmedi. Iki platformda birebir ayni: **39 PASS / 0 FAIL** |
| `network_limits` | **ag kaynak sinirlari** (Sprint E, F-29..F-32): gercek `TVdbPgServer` loopback'te, `MaxConns=1` ve kisa zaman asimlariyla (`ReadTimeoutMs`/`WriteTimeoutMs` 500-1000 ms) NL0-NL7 (22 kontrol). (a) yarim **startup** birakip bekleyen istemci zaman asimiyla duser ve slot bosalir, ayni kapida yeni istemci startup'i tamamlayip `SELECT 1` alir (kurtarma 6 s icinde) ve `ConnCount` sifira doner; (b) kimlik dogrulamasindan sonra yarim **sorgu** cercevesi birakan istemci 4 s icinde dusurulur; (c) 64 MiB'i asan cerceve **sessizce** dusurulmez, kontrollu `ErrorResponse` (`SQLSTATE 54000`) alir (sunucu ayakta kalir); (d) `COPY ... FROM STDIN` toplam boyut tavani (`CopyMaxBytes`) asilinca kontrollu hata, tablo **degismez**, gecici dosya kalmaz; (e) tavan altindaki kucuk COPY normal calisir; (f) acik baglanti varken `Stop` 5 s icinde doner ve `ConnCount=0` olur. On-kapi (duzeltme oncesi kaynak): `MaxConns=1` + yarim startup -> ikinci istemci 6031 ms sonra **hala giremiyor** (`H1` FAIL, kalici DoS). **NL8 (Sprint E2)**: zaman asimi **kurulamazsa** baglanti **sunulmaz** - soket protokol mesaji gonderilmeden kapanir, slot tuketilmez (`ConnCount` sifir kalir) ve kanca kaldirilinca sunucu normal istemciyi kabul eder. **26 kontrol**; iki platformda **26 PASS / 0 FAIL**. On-kapi (duzeltme oncesi kurulum: HEAD + yalnizca test kancasi, fail-closed blogu cikarilmis) **1 kontrol FAIL** (NL8 slot: `ConnCount=1`, baglanti sunulmus) - ayirt edici olan slot kontroludur, cunku ilk iki NL8 kontrolu istemcinin kendi 700 ms okuma zaman asimi nedeniyle baseline'da da gecer. **NL9-NL12 (Sprint O, F-47): MUTLAK mesaj son tarihi**. ONCEDEN zaman asimi her `recv`/`send` cagrisi icin ayri uygulaniyordu, yani istemci her zaman asimindan once kucuk bir parca gondererek toplam mesaj suresini **sinirsiz** uzatabiliyordu. NL9 `Q` basligiyla 1000 baytlik govde ilan edip govdeyi **her 100 ms'de bir bayt** gonderir (`ReadTimeoutMs` 300 ms): damla istemcisi mutlak son tarihte **2 s icinde** dusurulur. NL10 ayni saldiriyi yarim **startup** basliginda, NL11 yavas **COPY-In** govdesinde dener; NL11 ayrica yarim COPY'nin tabloyu **degistirmedigini** ve gecici dosya birakmadigini dogrular. NL12 **yazma** tarafinin son tarihini olcer: butcesi bitmis `VdbSendAllDl` **hic bayt** yazmaz, ayni mutlak son tarih ard arda gonderimlerde uygulanir (256 MiB teklif 50 ms'de durur) ve bol butce ile ayni yuk tamamen gider. **41 kontrol**; iki platformda **41 PASS / 0 FAIL**. On-kapi (`git archive HEAD` = `4203135` + yalniz API seam'i: `VdbRecvAllDl`/`VdbSendAllDl` bildirilir ve `ASonTick`i yok sayarak eski fonksiyonlara delege eder; davranis HEAD) **32 PASS / 9 FAIL**; ayirt edici: NL9 damla 4156 ms'de **hala acik**, NL10 2188 ms, NL11 4171 ms, NL12 butcesi bitmis cagri `ok=True` ve 1 bayt yazmis. **Durust sinir**: Windows loopback'ta **engellenen** yazma deterministik uretilemiyor (olculdu: `RCVBUF=4096` iken 16 MiB 16 ms'de tamponlara kabul edildi), bu yuzden NL12 "engellenirken son tarih"i degil son tarihin **kendisini** olcer; tek bir `fpSend` kendi OS tavanini (`SO_SNDTIMEO`) asabildigi icin ust sinir 2 s'dir. TLS'te `select()` kullanilamaz: son tarih her parca oncesi denetlenir ve tek bir `SSL_read`in ust siniri yine `SO_RCVTIMEO`'dur. **SKILL10 (Sprint U, F-54): durdurma ve TLS mutlak son tarihi.** NL7 kusuru kanitlandi: yarim `startup` birakan bir istemci varken `Stop` **29703 ms** suruyordu (5 s siniri asiliyordu). `Stop` artik once yeni kabulu durdurur (`FStopping`), kabul is parcacigini `VdbWaitSock` 200 ms'lik dilimlerle uyandirip **dinleme soketini kapatmadan once** sonlandirir, sonra baglanti listesinin kopyasini alip her birini `Wake` (RequestCancel + `shutdown`) ile uyandirir ve bekler; motor ancak **butun** baglanti is parcaciklari bittikten sonra kapatilir. Dinleme soketi non-blocking kipli (`VdbSockSetNonBlocking`), kabul `VdbTcpAcceptNb` ile yapilir ve `WOULDBLOCK`ta doner. TLS el sikismasi ve `SSL_read`/`SSL_write` mutlak son tarihle 500 ms'lik dilimlerde denetlenir (`-2` = son tarih asildi). CancelRequest siriti artik xorshift32 degil `VDbCryptRandom` CSPRNG'dir; RNG basarisizsa baglanti `SQLSTATE 28000` ile reddedilir. **NL13-NL24** eklendi (kabul/startup/TLS-el-sikismasi/SCRAM/COPY/sorgu durdurma, 64 baglanti, yeniden baslatma, tanitici yeniden kullanimi, TLS son tarihi, TLS yazma son tarihi, sirit benzersizligi/izolasyonu). Windows **97 PASS / 0 FAIL / 4 SKIP** (SKIP: TLS kontrolleri NL15/NL22/NL23 - bu makinede OpenSSL yok), Linux **110 PASS / 0 FAIL / 0 SKIP** (TLS kontrolleri dahil); ayni NL7 tekrari **29703 ms -> 312 ms**. **Durust sinir**: TLS son tarihi tek bir `SSL_read`/`SSL_write` cagrisini kesemez; ust sinir yine `SO_RCVTIMEO`/`SO_SNDTIMEO`'dur |
| `pg_cancel` | **PostgreSQL CancelRequest ve sorgu iptali** (Sprint O, F-47; SKILL6 05): gercek `TVdbPgServer` loopback trust modda, iki baglanti (`A`, `B`). ONCEDEN her baglantiya ayni `BackendKeyData(1, 0)` gonderiliyordu (secret 0) ve **CancelRequest (kod 80877102) hic islenmiyordu**, yani calisan bir sorguyu iptal etmenin yolu yoktu. (a) PC1 `BackendKeyData` pid/secret **benzersiz** ve **sifir degil** (pid `InterlockedIncrement` ile 1000den, secret xorshift32; global `Random` kullanilmaz); (b) PC2 dogru pid+secret ile iptal **calisir**: bekleyen cumle `SQLSTATE 57014` + `sorgu iptal edildi` alir ve iptal **tek seferliktir** (sonraki cumle normal calisir); (c) PC3 **yanlis secret** ile iptal **reddedilir**, hedef sorgu etkilenmez; (d) PC4 **adresleme**: `B` iptal edilirken `A` calismaya devam eder (baska baglanti kesinlikle iptal edilmez); (e) PC5 bilinmeyen pid zararsiz; (f) PC6 bozuk uzunlukta (12) CancelRequest **yanit uretmez**, baglanti kapanir ve sunucu ayakta kalir; (g) PC7 kapanmis baglanti icin CancelRequest zararsiz; (h) PC8 **atomiklik**: `BEGIN` + `INSERT` iceren islem iptal edilir, sonraki `INSERT` `57014` alir, `ROLLBACK` sonrasi `COUNT=0`; otomatik commit edilen cumle iptal edilince de `COUNT=0` (yarim DML commit edilmez); iptalden sonra atilan DML normal commit edilir (`COUNT=1`); (i) PC9 `Stop` sonrasi `ConnCount=0`. **31 PASS / 0 FAIL**, iki platformda ayni. On-kapi (`git archive HEAD` = `4203135`, **seam gerekmedi**) **3 PASS / 4 FAIL**; ayirt edici: PC0/PC1/PC7 `BackendKeyData` hic gelmiyor (secret 0), PC8 baglanti acilamadigi icin atomiklik olculemiyor. **Durust sinir**: iptal **isbirlikci** noktalarda etkilidir (`TickAbort` her 1024 satirda bir `CheckAbort`); bloklayan tek bir disk G/C'sini veya derin tek bir fonksiyon cagrisini kesmez. |
| `pg_portal_stream` | **genisletilmis protokol portal imleci ve kaynak sinirlari** (Sprint J, F-40; SKILL5 9.5 + 10.1): gercek `TVdbPgServer` loopback trust modda, genisletilmis protokol (`P`/`B`/`E`/`D`/`S`/`C`) ile PP0-PP12 ve PS0-PS10 (35 kontrol). (a) `Execute` `maxRows=10` ile **ilk 10 satiri** gonderir ve `PortalSuspended` doner; ayni portaltekrar `Execute` **kaldigi yerden** 11..20 verir, sorgu yeniden calistirilmaz; kalan 5 satirda `CommandComplete`; tukenmis portal 0 satir doner (kopya yok). (b) `maxRows=0` tum 25 satiri tek seferde verir. (c) **`Sync` portali dusurmez**: partiler arasinda `Sync` gonderilse de imlec korunur (JDBC `fetchSize`/libpq deseni); `Describe Portal` (`D`) satir tuketmeden `RowDescription` doner; portal `Close` (`C`) sonrasi `portal yok` hatasi. (d) **Kaynak sinirlari**: `MaxPortals` asiminda kontrollu hata ve acik portallar bozulmadan onceki sonuc korunur; `MaxPrepared`/`MaxStmtSqlBytes` asiminda kontrollu hata; `MaxPortalResultBytes` asiminda portal sonucu **derhal birakilir** (OOM yok). **35 PASS / 0 FAIL** (SKILL6 04 ile PS0-PS10 eklendi; PP0-PP12 korunur), iki platformda ayni. Sprint J on-kapisi (22 kontrol, `git archive HEAD` + yalnizca alan/property/varsayilan seam'i) **6 PASS / 16 FAIL** idi; ayirt edici 16 kontrol: PP1/PP1b/PP1c/PP2/PP2b/PP2c/PP3/PP3b/PP4 (`maxRows` imleci yok, ilk `Execute` 25 satirin tamamini gonderir), PP6a/PP6 (`Sync` portali dusurur -> `portal yok: po6`), PP10/PP10b (`Describe` oncesi `Sync` portali siliyor), PP7 (portal siniri yok), PP8 (prepared statement siniri yok), PP9 (sonuc bellek siniri yok). PP0/PP0b/PP0c/PP5/PP11/PP12 bilerek **ayirt edici degildir** (sunucunun acilmasi, `maxRows=0` yolu ve `Close` sonrasi `portal yok` HEAD'de de gecer). **SKILL6 04 (Sprint R)**: portal ve `COPY OUT` artik **gercek satir akisindan** beslenir (`TVdbRowCursor`, `TryStreamSelectChunk`, sayfa pencereli devam); `MaxPortalResultBytes` her uretilen parcada denetlenir, devam ettirilemeyen imlec sessizce kesilmez. PS0-PS10 bunu olcer: PS7a akisli 800 satiri 120 KB butce icinde bitirir, PS7b ayni sonucu `ORDER BY` ile maddesellestirip RED alir, PS7c akisli yolda da butcenin uygulandigini gosterir, PS8/PS9 `COPY OUT` iki bicimde de 800 `CopyData` uretir, PS10 `Close` ile imlecin birakildigini dogrular. On-kapi (ayni 35 kontrol, `git archive HEAD`, `e31d186`) **33 PASS / 2 FAIL**: ayirt edici iki kontrol PS7a (maddeselestirilen 800 satir 245043 bayt > 120000 butce -> RED) ve PS4 (`maxRows=1` ile 25 adimda 24 tekil satir) iken diger 33 kontrol HEAD'de de gecer. **Durust sinir**: ORDER BY, GROUP BY, DISTINCT, JOIN, UNION, pencere, alt sorgu, NULL tasiyan tablo, KV deposu ve toplu acilis tek seferlik genel yola duser ve orada butce maddeselestirme **sonrasi** denetlenir; gomulu `Exec` yolu hala tamamen maddeselestirir. `Sync`'in portallari dusurmemesi kapatilmayan portalin baglanti sonuna kadar yasamasi anlamina gelir; bu `MaxPortals` + `MaxPortalResultBytes` ile sinirlidir |
| `serializable_tx` | **SERIALIZABLE gercekten denetleniyor mu** (Sprint K, F-41; SKILL5 6.x): iki ayri `IVdbBackend` (tek surecte ama **ayri depo tanitici** = gercek yazar rezervasyonu cakismasi) ve ayrica gercek PG teli. S1-S15 (API) + P1-P8 (PG). Senaryo: A `BEGIN` + `INSERT` (yazma rezervasyonunu tutar), B `BEGIN` (optimistik kipe duser ve snapshot alir), A `COMMIT`, B farkli anahtara `INSERT` + `COMMIT`. (a) REPEATABLE READ'de B **commit eder** (eski davranis korunur). (b) SERIALIZABLE'de B **reddedilir**: `ecSerializationFailure`, metinde SQLSTATE **40001**, ve `ROLLBACK` sonrasi B'nin yazdigi satir **yoktur** (write skew kapandi). (c) Ara giris olmayan SERIALIZABLE islem commit eder; `SET ... REPEATABLE READ` sonrasi bayrak **yapismaz** (tekrar commit eder). PG tarafinda ayni senaryo `ErrorResponse` + `40001` uretir. Ayrica S16-S20 (Sprint L, F-44; SKILL6 01) **paylasilan backend alanini** hedefler: A READ COMMITTED islem acmisken B `SET TRANSACTION ... SERIALIZABLE` der ve bu **A'nin commit'ini iptal ETMEZ** (S17) ve A'nin satiri **kalir** (S18); ters yonde B'nin gercek SERIALIZABLE islemi araya giren commit'ten sonra **reddedilir** (S19) ve **hicbir satir yazmaz** (S20). **28 PASS / 0 FAIL**. On-kapi (`git archive HEAD` = `7b54faa`, **seam gerekmedi**) **24 PASS / 4 FAIL**; ayirt edici sekiz kontrol: S7 (SERIALIZABLE commit kabul edildi), S8 (kod `ecNone`), S9 (40001 yok), S11 (iptal edilen islem **yazmis**), S17 (READ COMMITTED commit'i haksiz 40001), S18 (satir kayboldu), S19 (gercek SERIALIZABLE reddedilmiyor), S20 (iptal edilen islem yazmis); P4/P5 (PG'de ErrorResponse ve 40001 yok), P6 (3 satir, 2 olmali), P8 (5 satir, 4 olmali). **Durust sinir**: tam **SSI degildir** - predicate/aralik kilidi ve okuma kumesi izleme yok, araya giren **herhangi** bir commit islemi iptal eder (muhafazakar; bedeli gereksiz yeniden deneme, veri kaybi degil). Oturum duzeyi `SET SESSION CHARACTERISTICS` yok. V2 `SetTxIsolation` cagrisini **yok sayar** (V2 donmus). |
| `pg_msg_nul` | **PG mesaj alanlarinda eksik NUL sonlandiricisi** (Sprint K, F-42; SKILL5 9.x): `VDbPgWire.ReadCStr` onceden tampon sonuna kadar okuyup sonlandirici yoklugunu **sessizce yutuyordu**; bozuk paket protokol ihlali olarak reddedilmiyor, alanlar sessizce birlestirilerek isleniyordu. N0-N8 (10 kontrol): N1 duzgun `Parse`+`Bind`+`Execute` calisir (kontrol); N2 sonlandiricisiz `Parse` (SQL alani NUL'suz) **ErrorResponse** alir, `ParseComplete` **yok**; N3 hata metni eksik sonlandiriciyi adlandirir ('NUL'); N4 baglanti **yasamaya devam eder** ve `SELECT 3` dogru doner; N5 sonlandiricisiz `Bind` icin hata metni 'NUL' der (baseline bunun yerine yanlis teshis `prepared statement yok: st5yok` uretiyordu); N5b sonlandirilmis ama bilinmeyen ad hala `prepared statement yok`; N6 baglanti yasar; N7 eksik sonlandiricili **baslangic paketi** reddedilir (`ReadyForQuery` gelmez); N8 sunucu olmez, yeni baglanti `SELECT 7` yapar. **10 PASS / 0 FAIL**. On-kapi (`git archive HEAD`, **seam gerekmedi**) **6 PASS / 4 FAIL**: ayirt edici N2 (baseline `1Z` donuyor), N3, N5 (yanlis teshis), N7 (baseline bozuk baslangic paketini kabul ediyor, `RSSSSKZ`); N1/N5b/N6/N8 koruyucu kontrollerdir. |
| `merge_hash` | **MERGE eslesme karmasikligi** (Sprint K, F-43; SKILL5 10.x): `ExecMerge` eslesmesi kaba kuvvet `O(hedef x kaynak)` idi; her hedef satiri icin tum kaynak satirlari dolasilip `ON` kosulu her cift icin yeniden degerlendiriliyordu. Olculen baseline: 8000 hedef x 8400 kaynak icin tek `MERGE` **130781 ms**, ikinci kosu **142672 ms**. M1-M13 (19 kontrol): M2 buyuk `MERGE` (`ON t.id = s.id`, MATCHED UPDATE + NOT MATCHED INSERT) **10 s siniri** icinde biter (duzeltilmis yapida **62 ms**); M3 toplam 8400 satir; M4 8000 satir guncellendi; M5 400 satir eklendi; M6 ayni `MERGE` tekrarinda **0 ekleme**; M7 sayisal kanon (`'05'` ile `5` eslesir); M8 NULL anahtar **hic eslesmez**; M9/M9b coklu kaynak eslesmesi hala `birden cok kaynak` hatasi verir ve hedef **degismez**; M10/M10b esitlik disi `ON` eski yola duser ve dogru sonuc verir; M11/M11b cok kolonlu anahtar dogru; M12/M12b `WHEN MATCHED THEN DELETE`; M13 yalniz UPDATE. **19 PASS / 0 FAIL**. On-kapi (`git archive HEAD`, **seam gerekmedi**) **18 PASS / 1 FAIL**: **yalnizca M2** ayirt edicidir (130781 ms > 10 s); M3-M13 semantik **koruyucu** kontrollerdir ve baseline'da da gecer - hizi olcmezler, hizli yolun eski davranisi bozmadigini kanitlarlar. **Durust sinir**: hizli yol yalnizca `AND` zinciri + `sboEq` + iki tarafi da kolon referansi olan `ON` icin devreye girer; karmasik `ON`, `COLLATE` ve metin karsilastirmasinda (`VCT_STR` + `FCurTable <> ''`) eski kaba kuvvet dongusu **aynen** calisir. | **Sprint P (F-48, SKILL6 07): `UPDATE ... FROM` esitlik birlestirmesi.** Ayni kusur `UPDATE ... FROM` icin de vardi: `ExecUpdate` hedef satirlarini kaynak satirlariyla **kartezyen** dolasiyordu (4000 hedef x 2500 kaynak = ~6.9 milyon tam WHERE degerlendirmesi, **olculen 13063 ms**). Yeni kod (`UfCollectEq`/`UfHash`/`UfBuildJoin`) WHERE icindeki **guvenli** esitliklerden (`sboEq` + iki tarafi da kolon referansi + `VCT_STR` + iki tarafta bos collation) hash anahtari kurar; kaynak tarafi azalan sirada basa eklenir ki **ilk eslesen kaynak satiri kazanir** semantigi korunsun; NULL anahtar atlanir; her aday icin tam WHERE yeniden degerlendirilir; uygun conjunct yoksa eski yol aynen calisir. Yeni kontroller **U1-U9**: U1/U2 satir sayilari (2500 guncellendi, 1500 korundu), **U3 4000 x 2500 guncellemenin 4 s siniri icinde bitmesi (16 ms)**, U4/U4b ilk-eslesen-kazanir ve kopya satir olusmamasi, U5 NULL anahtar eslesmez, U6 sayisal denklikte (`5` vs `05`) hash kullanilmaz ve eski yol dogru sonuc verir, U7 esitlik-disi WHERE eski yolda dogru, U8/U8b coklu kolon, U9 alt sorgu kaynagi (`FROM (SELECT ...)`). Kapi **19 -> 30 kontrol**, **30 PASS / 0 FAIL**. On-kapi (`git archive HEAD` = `ab103aa`, seam gerekmedi) **29 PASS / 1 FAIL**; tek ayirt edici **U3**: `sure=13063ms sinir=4000ms` (~815x). U1/U2/U4-U9 baseline icinde de gecer (eski yol dogru, yalniz yavas) - regresyon korumasidir. **Durust sinir**: maliyet modeli/spill-to-disk karari hala yok; `UPDATE ... FROM` icinde JOIN parser tarafindan reddedilir.
| `null_empty` | **SQL NULL ile bos metin ayrimi** (Sprint Q, F-49; SKILL6 03): `tests/sql_features` deseniyle yazilmis kapi; `TVdbBackendV3` + `TVSql` dogrudan kullanilir. **NE1-NE51 (41 kontrol)** dort asamayi olcer. **Ifade semantigi (2a)**: `NULL IS NULL` True, `'' IS NULL` False, `NULL = ''` UNKNOWN, `'' = ''` True, `NULL = NULL` UNKNOWN, `1 + NULL` UNKNOWN, `NULL AND FALSE` False, `NULL AND TRUE` UNKNOWN, `NULL OR TRUE` True, `NOT NULL` UNKNOWN; test ayrimi varsaymaz, her ifade `SELECT (<ifade>) IS NULL` olarak kosulur. **Depolama (1 + 2b)**: `NULL` ve `''` yazilip diskten geri okunur (ayni baglanti, yeniden acilan dosya, indeksli/indekssiz tablo), `COUNT(kolon)` NULL'i saymaz, `UNIQUE` iki NULL'a izin verir, `GROUP BY`/`DISTINCT` NULL ile `''`i ayirir, `ORDER BY ... NULLS FIRST/LAST` dogru sirada. **Yazma (2c)**: `UPDATE`, `UPDATE ... WHERE`, `INSERT ... SELECT`, `UPSERT`, `INSERT RETURNING`, FK cascade, `ALTER TABLE` (ADD COLUMN / TYPE) ve `COPY` sonrasi ayrim korunur; hizli INSERT seritleri ve maske tasimayan covered-index/stream yollari NULL gorunce genel satir yoluna duser. **PG wire**: `DataRowMsgFmt` NULL'i `-1` yazar, Bind `plen = -1` parametreyi NULL yapar; parametre maskesi `TVSql.Exec(Sql, Params, ParamNulls)` ile tasinir. **41 PASS / 0 FAIL** her iki platformda. **On-kapi** (`git archive HEAD` = `a30676e`): **30 PASS / 11 FAIL** (NE24, NE28, NE31, NE34 dahil) -- yani kapi ayirt edici. **Durust sinir**: `COPY TO` text/Arrow/Parquet disa aktarimi NULL'i hala `''` yazar (bicimde ayrim yok); covered-index hizli yolu ve projeksiyon oncesi `ORDER BY` siralamasi maskeyi tasimaz; `ExecGroupBy` `Res.RowNulls`i doldurmaz; 2c oncesi yazilmis satirlar `HasNulls` isaretlenene kadar eski kurala (`''` = NULL) tabidir. Bunlar gosterim/okuma kapsamidir, veri kaybi degildir. Bicim v5 ve V2 degismedi (`format_compat` 28/0). **SKILL09 (Sprint T, F-53): NULL operator semantigi tamamlandi.** ONCEDEN `TSqlInNode`, `IN` alt sorgusu, `IN` listesi, `ANY`/`ALL` ve `BETWEEN` NULL ile `''`i ayirt etmiyordu: `IN` kumesinde `''` NULL sayiliyor, alt sorgu/liste yollarinda NULL maskesi tasinmiyor, uc degerli mantik uygulanmiyordu. Artik sol islenen NULL ise sonuc **UNKNOWN**; `''` gercek degerdir; liste veya alt sorguda NULL varsa ve eslesme yoksa sonuc **UNKNOWN** olur (hem `IN` hem `NOT IN`); `IN` onbellek sozlugu `''` anahtarini gercek anahtar olarak tutar ve NULL ayri bayrakta tasinir; `ANY` bos kume False, `ALL` bos kume True. **NE52-NE136 (85 yeni kontrol)** eklendi; `null_empty` 41 -> **126 PASS / 0 FAIL** iki platformda. **On-kapi** (`git archive 2ccbecb`): **85 PASS / 41 FAIL** - kapi ayirt edici. Bicim v5 ve V2 degismedi. |
| `btree_disk` | **ayri B+Tree disk sayfa bicimi** (SKILL3 §13'un son acik kalemi): `VDbBTreeDisk.pas` **bagimsiz** birimdir, v5 motor dosya bicimine, WAL'e ve kurtarmaya **bagli DEGILDIR** (v5 bicimi ve kurtarma davranisi degismez). 4096 baytlik sayfa, 32 baytlik baslik (`PageNo`/`Kind`/`Level`/`NKeys`/`Flags` + sayfa CRC'si), slotlu hucre duzeni sayfa sonundan geriye; yaprak hucresi 16 bayt (`Key:QWord + Val:QWord`), ic hucre 12 bayt (`Key:QWord + Child:LongWord`), ic sayfada 0. hucrenin anahtari kullanilmaz ve en sol cocuktur, yonlendirme "`Key_i <= K` olan en buyuk `i`". **Golge sayfalama**: hicbir sayfa yerinde guncellenmez, degisen sayfalar yeni numaralara kopyalanir ve meta en son yazilir; meta yazimi **commit noktasidir**. Iki A/B meta sayfasi vardir, acilista CRC'den gecen **en yuksek `Seq`** kazanir. Kapi BD1-BD18: 1000 anahtar ekle/oku/guncelle + artan `Walk`, yeniden acilis + temiz `Verify` (dosya kuculmez 57.344 -> 57.344 B), yarisi silinip yeniden acilma, azalan 2000 ve karisik 3000/6000, 6000 `NextAfter` alt-sinir taramasi (sirali listeyle birebir), bolunme agirlikli 6000 anahtar (yukseklik 2, 36 yaprak), churn sonrasi doluluk olcumu (`yaprak=36 hucre=6000 doluluk=96000/147456`, ~%65), sayfa geri kazanimi (75 -> 75 sayfa; sayac sismez), **yirtik meta** (en yeni meta bozulunca onceki 300 anahtarlik agac aynen acilir, yeni 300 anahtar gorunmez), **cokme noktasi** (`OnBeforeMeta` kancasi meta yazimindan hemen once dosyayi kopyalar; kopya onceki 200 anahtari TAM okur = veri kaybi yok), yalniz-CRC bozulmasi (`Verify` FAIL, okuma hala 500/500 bulur), yapisal bozulma (`Verify` FAIL ve okuma yolu kontrollu `EBtdError`, **access violation yok**) ve kesik dosya (`EBtdError`, sessizce yeni agac KURMAZ). **Sprint D (5.2/6.1/6.2)**: `ReadPage` artik diskten okunan **her** sayfada `CheckPageStruct` calistirir (CRC + sayfa kimligi + yapisal sinirlar) ve `MarkReachable` kisa okuma/kotu CRC/bozuk yapida `EBtdError` atar; bozuk sayfa artik serbest ilan edilip geri kazanilamaz. Bu bir **sozlesme degisikligidir**: bozuk B+Tree dosyasi acilmaz. BD15/BD16 eski sessiz davranisi dogruladigi icin yeniden yazildi (`RestampCrc` ile \"CRC gecerli, yapi bozuk\" durumu uretilir). `btree_disk` iki platformda **78/0**. Kapi yazilirken **uc gercek kusur** bulundu ve duzeltildi: Windows'ta `fmCreate` ile yeniden acilisin dosyayi **sifirlamasi** (`FileExists` ayrimi, `VDbPageStore` ile ayni desen), kurucu istisna yolunda **cift serbest birakma** (`FreeAndNil` + nil kontrolleri) ve `Verify`'in bozuk sayfada **istisna sizdirmasi**. Iki platformda birebir ayni: **78 PASS / 0 FAIL** |
| `sql_scale` | **SQL yurutucu olcek olcumu** (SKILL4 §4): iki kademe - 100.000 satir `t(id INTEGER PRIMARY KEY, b INTEGER, v TEXT)` ve 1.000.000 satir `m(id INTEGER PRIMARY KEY, v TEXT)` - uzerinde SS1-SS20 (34 kontrol, iki platformda ayni satir/deger, yalniz sureler farkli). Kapsam: toplu yukleme + `COUNT`, nokta okuma, `WHERE` + projeksiyon, `ORDER BY`/`LIMIT`, `OFFSET`, `COUNT`/`SUM`/`AVG`/`MIN`/`MAX`, `GROUP BY` + `HAVING`, 100 satirlik boyut tablosuyla `JOIN`, 1000 satirlik `UPDATE` ve `DELETE`, 300 karisik insert/update/delete, 5000 satirlik islem `COMMIT`/`ROLLBACK` (hayalet satir yok), yeniden acilis + tam `VERIFY`, ve 1M uzerinde LIMIT'li/LIMIT'siz okuma. Olculen: 100k ekleme 656 ms (Windows i386) / 1213 ms (Linux x86_64), dosya 3.997.696 B; 1M ekleme 6547/11849 ms, dosya 37.543.936 B, yigin deltasi 43.084/43.704 KB; 1M LIMIT'siz `SELECT *` 516/900 ms (tum 1M satir doner ve ilk/orta/son deger tek tek dogrulanir), 1M `ORDER BY id LIMIT 100` 859/1212 ms. **Durust olcum siniri**: `yigin_delta_kb` `GetHeapStatus.TotalAllocated` deltasidir, RSS degildir ve blok yeniden kullanimi onu etkiler; aletin kor olmadigi SS20'de 8 MB ayirma ile kanitlanir (7812 KB olculdu). Sonuc kumesi tavani `VDB_MAX_RESULT_ROWS` = 2.000.000'dir (v3.37) ve bu kapida tavanin **altinda** olculur; tavanin ustunu maddelestirmek 32-bit kapida ~GB bellek ister, o yol `tests/limits` L4 ile kapsanir - bu, "2M satir ureten kapi" demek degildir. LIMIT'siz tam taramanin kok nedeni arastirilmadi ve akis (streaming) yoktur. Kapi yeni motor kusuru bulmadi; tek duzeltme kapinin kendi olcum aletiydi (olu `TotalCommitted` metrigi kaldirildi). Bkz. `docs/engineering/SQL_SCALE.md`. |
| `sql_index_scale` | **SQL indeks olcegi** (SKILL4 §6): 100.000 ve 1.000.000 satirlik tablolarda IX1-IX20 (45 kontrol, iki platformda birebir ayni). Kapsam: birincil anahtar nokta okumasi ve plani (`Index Scan using t_pkey`), indekssiz plan (`Seq Scan`), `CREATE INDEX` ile ikincil indekste esitlik/aralik sorgusu (`Index Only Scan using ix_t_w`), mukerrer anahtar reddi (`ecUniqueViolation`) ve hayalet satir olmamasi, mukerrer `UPDATE` reddi, indeks uzerinden gorunen `UPDATE`/`DELETE`, 300 karisik insert/update/delete, `REINDEX`, `VACUUM`, `VACUUM` ve yeniden acilis sonrasi dogruluk, tam `VERIFY`, `SHOW INDEXES FROM t`, tablo adi olmadan `SHOW INDEXES` icin `ecSyntaxError` (F-19 duzeltmesi), `.odb.idx` yan dosyasinin bozulmasinda veri kaybi olmadan tarama ile dogru sonuc. Olculen (Windows/Linux): 1M `CREATE INDEX ix_m_v` 1016/1700 ms, 1M indeksten nokta okuma 0/1 ms, yeniden acilis sonrasi ilk indeksli sorgu 1203/1586 ms, indeks basina satir maliyeti 24/49 B, `.odb.idx` 1M icin 10.985.254 B (iki platformda ayni). **Durust sinir**: `yigin_delta_kb` `TotalAllocated` deltasidir, RSS degildir ve 100k indeks kurulumunda Windows'ta **-104 KB** cikti (ayirici bloklari yeniden kullandi), bu yuzden yalnizca 1M satir basina maliyet raporlanir. Ikincil indeksler SKILL12 ile artik **kalici disk B+Tree'sindedir** (`VDbDiskIdx.pas`, v5 motoruna entegre; ayni oturumda sicak `FSkipIdx`, yeniden acilista disk agaci kullanilir) - eski "yalniz bellekte `FMemIdx`/`TVDbBTree`" ifadesi artik gecerli degildir. Bu kapi yine de yalnizca SQL davranisini ve maliyeti olcer; disk indeksinin kaliciligi, cokme matrisi ve olcek iddialari `disk_index_integration`, `disk_index_crash` ve `disk_index_scale` kapilarindadir. `.odb.idx` hala yeniden uretilebilir bir onbellektir (veri kaynagi degildir) ve `VDbBTreeDisk.pas` bagimsiz/format-bagimsiz kalir (bu kapi onu olcmez). `.idx` varsayilan silme davranisi degismedi, kapi `KeepIdxOnClose` ile acik katilir. Bkz. `docs/engineering/DISK_BTREE_DESIGN.md`. |
| `soak` | **gomulu motor soak kapisi** (SKILL4 §7, E): acik `TVDbBackendV3` uzerinde 2000 canli satirlik tablo ile tur bazli churn (her tur 100 ekle + en eski 100 sil + bir guncelleme) kosar; varsayilan sure `VDB_SOAK_SECONDS` = 25 sn (5..86400), `VDB_SOAK_CP` her N turda zorunlu `Checkpoint(True)`, `VDB_SOAK_REOPEN` her N turda kapat/ac. Her turda orneklenen metrikler: heap (`TotalAllocated` deltasi, RSS **degil**), dosya tanitici/sap, is parcacigi, WAL bayti, dizin bayti, gecikme p50/p95. SO1-SO17 (20 kontrol): isinma sayimi, son canli sayim, sifir is yuku hatasi, >= 5 ornek, heap ilk/son pencere ortalama buyumesi <= 8192 KB, FD/sap ortalama buyumesi <= 4, is parcacigi ortalamasi <= 2, sabit is yukunde dosya buyumesi <= 8 MB, p95 <= 20000 ms, WAL tavani, kapanista tam `VERIFY`, yeniden acilis sayimi, son eklenen satirin okunmasi, soak tamamlanmasi, **SO15a-d** dizin doygunlugu (F-21 regresyonu: 200 canli satir, 40 tur x 20 ekle/sil, hata yok, yeniden acilista okunur) ve **SO16/SO17** uc sayimin tutarliligi (F-22 regresyonu: `COUNT(*)` == `COUNT(*) WHERE id > 0` == `COUNT(DISTINCT id)`, checkpoint ve yeniden acilis sonrasi). **Durust sinir**: bu bir **gomulu motor** soak'idir, ag sunucusu soak'i degildir; kapi 25 sn kosar ve gercek 1 saat / 6 saat / 24 saat soak **kosulmadi**, bu yuzden uzun sureli kaynak sizintisi iddia edilemez; heap olcusu RSS degildir. Kapi iki gercek motor kusuru buldu ve duzeltti: **F-21** (dizin doygunlugunda `Insert` sessizce `False` donuyordu) ve **F-22** (serbest listedeki sayfa yeniden acilista heap sayfasi olarak dizine ekleniyor, sonra `AllocPage` tarafindan sifirlanarak canli satirlar sessizce siliniyordu) |
| `interop_format` | **Arrow/Parquet bicim uyumlulugu, saf Pascal** (SKILL6 08): F0-F22, **27 kontrol**. Dis arac yoktur, her zaman kosar. (a) VDB kendi yazdigi Arrow IPC stream ve Parquet dosyalarini birebir geri okur (tum tipler: int/float/str/bool/date/datetime/time/blob, NULL ve bos metin dahil), yeniden acilista ayni degerler gelir. (b) Depoda **duran** pyarrow uretimi fiksturler (`tests/interop_format/fixtures/ext.arrow`, `ext.parquet`, `ext_snappy.parquet`; 50 satir x 7 kolon, 3 batch / 3 row group) VDB tarafindan okunur ve **her hucre** beklenen degere karsi dogrulanir (F15a/F15b/F15c). Fiksturler devingen veridir (uretim betigi `generate_fixtures.py` kayitta kalir). (c) **tipli hucre yolu (F17-F22, SKILL13)**: `TVdbCellMatrix` ile NULL / gercek bos metin / gercek bos ikili ayrimi her iki bicimde gidis-donus korunur (F17/F18); eski metin API'sinin `''` ile NULL'i birlestiren siniri **korunur ve belgelenir** (F19); toplu yazici (`TVdbArrowWriter`/`TVdbParquetWriter`) 3 partiyi yazar, okuyucu 2/1/1 boyutlarini ayni hucrelerle dondurur (F20/F21); 1 MB metin + 512 KB ikili tipli gidis-donus (F22). On-kapi (`git archive HEAD` = `bfb6020`): kapi **derlenmez** - 26 x `Error` (`Identifier not found` x 8 yeni API adi: `VDbArrowExportCells`, `VDbArrowImportCells`, `TVdbArrowWriter`, `VDbArrowReadBatches`, `VDbParquetExportCells`, `VDbParquetImportCells`, `TVdbParquetWriter`, `VDbParquetReadBatches`); ozellik HEAD'de yoktur. Durust sinir: iki bicimde de DECIMAL yoktur (SKILL14 sonrasi); VDB Parquet yazarken yalniz UNCOMPRESSED uretir (SNAPPY yalniz okunur, saf Pascal ile uygulanmistir); tipli okumada Arrow DATE/TIME/DATETIME hucreleri `vckText` ISO metni, Parquet sozluk (dictionary) kodlanmis FLOAT degerleri metin uzerinden gelir |
| `interop_external` | **pyarrow ile karsilikli dogrulama** (SKILL6 08): X1-X8 + Y1-Y13, **21 kontrol**. (a) VDB'nin urettigi Arrow/Parquet dosyalarini **pyarrow** (harici, depo disi) acar ve hucre hucre dogrular (X1/X2). (b) pyarrow harici dosyalari uretir (`ext_vdb.arrow` 2 batch, `ext_vdb.parquet` NONE + `row_group_size=2`, `ext_vdb_snappy.parquet`) ve VDB bunlari birebir okur (X3-X6). (c) X7 NULL ile gercek `''` sinirini **belgeler**: `TStrMatrix` NULL maskesi tasimadigi icin ikisi de `''` olarak gelir. (d) X8 `date64[ms]`, `time32[s]`, `time32[ms]`, `time64[us]`, `time64[ns]` birimlerini tek tek dogrular. **Bu kapi bir gercek kusur buldu ve kapatti**: Arrow semasinda `Date.unit`/`Time.unit` varsayilani MILLISECOND oldugu icin pyarrow `date64[ms]`/`time32[ms]` icin `unit` alanini **hic yazmaz**; okuyucu varsayilani SECOND/DAY sanip degeri 1000 kat kaydiriyordu (`00:00:00`, `0000-00-00`). `VDbArrow.pas` `ArrowParseType` artik Date/Time icin varsayilan `1` (MILLISECOND) kullanir (F-51). (e) **tipli hucre yolu (Y1-Y13, SKILL13)**: VDB'nin tipli ciktisini pyarrow `checkcells` hucre hucre dogrular - NULL sayilari kolon basina bildirilir ve **bos metin/bos ikili NULL DEGILDIR** (Y1/Y2); pyarrow'un NULL + gercek `''`/`b''` karisik iki partili/iki row-grouplu dosyasi VDB tarafindan `TVdbCellMatrix` olarak **birebir** geri okunur (Y3/Y4/Y5); tipli gidis-donus (Y6/Y7); 3 partili Arrow yazimi okuyucuda 2/1/1 doner ve dosya pyarrow ile hala okunur (Y8); 3 partili Parquet yazimi **3 row group** uretir (`rg=3`, Y9); 1 MB metin + 512 KB ikili (Y10/Y11); pyarrow 40 batch x 250 satir Arrow (Y12) ve 50 row group x 200 satir Parquet (Y13) dosyalarini VDB **parti parti** okur (satir sayilari, son satir ve boyutlar dogrulanir). On-kapi (`git archive HEAD` = `bfb6020`): kapi **derlenmez** - 29 x `Error` (`Identifier not found` x 8 yeni API adi); ozellik HEAD'de yoktur. (Tarihce: SKILL6'da ayni kapi HEAD'e karsi yalniz `VDbArrow.pas` birim yolu one alinarak derlenebiliyordu ve **6 PASS / 2 FAIL** veriyordu; ayirt edici olan X4 ve X8 idi.) Python+pyarrow yoksa kapi **77 (SKIP)** doner ve PASS sayilmaz; `VDB_INTEROP_PY` (yorumlayici) ve `VDB_PY_LIBS` (depo disi pyarrow dizini) ile yol verilebilir |
| `crypto_interop` | **yayinlanmis kripto vektorleriyle saf Pascal dogrulama** (SKILL6 08): **33 kontrol**. Vektorler Pascal kaynagina gomuludur (harici dosya/DLL yok): FIPS 180-4 SHA-256, RFC 4231 HMAC-SHA256 (1, 2, 3, 4, 5, 6, 7 ve 64 baytlik anahtar; >64 bayt anahtar RFC 8018'den bilincli sapma olarak **reddedilir**), RFC 7914 scrypt/PBKDF2-SHA256 ve RFC 6070 PBKDF2 test vektorleri, FIPS-197 Ek C.3 AES-128, NIST GCM spesifikasyonu ornekleri (GCM15/GCM16/GCM17, 64 baytlik ek veri dahil). Beklenen etiket/deger sabitleri bagimsiz Python ile bir kez dogrulanmistir. On-kapi (`git archive HEAD` = `16b0b09`) **33/0** - bu commit kripto modulune dokunmadigi icin kapi **koruyucudur** |
| `crypto_interop_ext` | **bagimsiz Python kripto diferansiyeli** (SKILL6 08): CE0-CE24, **25 kontrol**. `hashlib`, `hmac`, `hashlib.pbkdf2_hmac` (harici, depo disi) ile ayni girdiler uzerinde VDB'nin saf Pascal ciktisi karsilastirilir; sabit vektorun disinda rastgele olmayan ama farkli uzunluklarda girdiler de kapsanir. CE24 **64 bayttan uzun parola reddini** olcer (fail-closed; RFC 8018'den bilincli sapma, ADR 6). Python yoksa **77 (SKIP)**, PASS sayilmaz. On-kapi **25/0** - **koruyucu** |
| `bench_sqlite` | **VDB - SQLite karsilastirmali olcum** (SKILL6 08): **24 kontrol**. Ayni is iki motorda kosar (VDB + Python standart `sqlite3`), sonuclar **is birebir esit mi** diye 12 anahtar uzerinden dogrulanir (satir sayilari, toplamlar, aralik/nokta sonuclari); hiz **yalniz raporlanir**. Olculen (Windows i386, SQLite 3.50.4, WAL): sema 4/3 ms, 20k ekleme 45/5, indeks 8/1, 1000 nokta okuma 67/4, 50 aralik 132/3, group by 2/1, join 351/0, update 5/1, tam tarama 2/0, delete 9/0; DB boyu 229376 (VDB dizin agaci) / 167936 (sqlite dosyasi) bayt. Linux x86_64 (SQLite 3.37.2): 5/2, 105/4, 9/1, 13/4, 108/3, 2/1, 57/0, 7/0, 1/0, 8/0; ayni DB boyu. Her kosu `NOT: bu sayilar tek bir kosunun olcumudur; ustunluk iddiasi yoktur.` satirini yazar. Python yoksa **77 (SKIP)**. On-kapi **24/0** - **koruyucu** (bu commit motor olcum yoluna dokunmaz) |
| `disk_index_integration` | **kalici disk indeksi motor entegrasyonu** (SKILL12): `VDbDiskIdx.pas` **kendi kendine yeterli** yeni birimdir (saf Pascal; harici DLL/bagimlilik yok) - degisken uzunlukta hucre, 4096 baytlik sayfa, sayfa CRC'si, COW yazim, cift kopya meta (commit noktasi) ve **enjekte edilen karsilastirici** (motorun `TIdxSkipCmp` sirasi ile bit bit ayni). Indeks **turetilmis** veridir: dogru olan heap'tir, yazma sirasi "once heap commit (WAL + fsync), sonra indeks delta'si" seklindedir. Damga **tablo basina durabil commit sayacidir** (yeni `IVDbBackend.StoreScopeStamp`; `ReadGenScope(TableId)`) - surecler arasi karsilastirilabilir; `.gen` yoksa 0 doner ve damga uyusmazligi **yeniden insa** demektir (bayat indeks asla servis edilmez). `.dix` yan dosyasi varsa `.gen` kapanista **silinmez** (yoksa her yeni surec tum indeksleri yeniden kurardi); `.dix` yoksa tek-dosya davranisi (v3.32) aynen korunur. Kapi D1-D47 (**49 kontrol**): kalicilik ve `DiskIdxHits>0`/`DiskIdxBuilds=0` ile diskten servis (dosya RAM'e tam yuklenmez), kapanista tanitici sizintisi yok (D2b), aralik/bilesik/mukerrer/NULL, `UPDATE`/`DELETE` ve `ROLLBACK`, damgasi bayat `.dix` reddi + yeniden insa, sayfa/meta bozulmasinda red + yeniden insa (**yanlis satir yok**), islem icinde `CREATE INDEX` (commit sonrasi yazilir, `ABORT` temizler), `REINDEX`/`VACUUM`/`DROP INDEX`, ayri surecte salt-okunur okur (**yeniden insa YOK**) ve iki yazar cakismasi. `EXPLAIN` yalniz tablo metaverisine baktigi icin plan etiketi kanit sayilmaz; kanit `DiskIdxHits`/`DiskIdxBuilds` sayaclaridir. **Durust sinir**: hucre sayfaya sigmiyorsa (cok uzun TEXT anahtar/deger) indeks diskte tutulmaz ve bellek yolunda kalir - bu sinir aciktir. On-kapi (`git archive HEAD` = `e911ee8`): kapi **derlenmez** (22 x `Error: (5038) identifier idents no member "DiskIdxHits"/"DiskIdxBuilds"`) - ozellik HEAD'de **YOKTUR**, yani kapi ayirt edicidir; bu bir davranis farki degil, ozelligin yoklugudur. Bkz. `docs/engineering/DISK_BTREE_DESIGN.md` |
| `disk_index_crash` | **disk indeksi cokme matrisi** (SKILL12): cocuk surec **gercekten oldurulur** (`TerminateProcess` / `SIGKILL`; `Close`, `Destroy` ve finalization calismaz), ebeveyn her asmadan sonra yeniden acar. Enjeksiyon noktalari: `precommit` (heap commit'inden once), `heap` (engine `COMMIT_POST_SYNC` - heap onaylandi, indeks dosyasina **hic** dokunulmadi), `prepage`, `midpages` (coklu sayfa yaziminin ortasi: ilk sayfa cekirdege gecti), `postpage`, `premeta`, `postmeta` (meta yazildi, fsync yok). Is yuku **tek islemdir** ve agacta cok sayida bolunme/birlestirme uretir (300 anahtar guncelleme + 201 silme + 200 ekleme). Asama basina 8 kontrol (**56 kontrol**): surec oldu mu (cikis degeri platforma baglidir - Windows'ta `TerminateProcess(9)` -> `rc=9`, Unix'te `fpKill(SIGKILL)` -> FPC `TProcess` sinyal olumunu **negatif** sinyal numarasi olarak verir, `rc=-9`; iki degeri de yalniz gercek hard-kill uretir, `Halt(9)` yedegi Unix'te kabul edilmez), heap satir sayisi beklenen durumda mi, heap kumesi is yukunden **bagimsiz** hesaplanan beklentiye uyuyor mu, **indeksli sonuc = heap'ten turetilen sonuc**, indeks kaynagi (`builds`/`hits` beklentisi asamaya gore), `vmFull` temiz, `.dix` gecerli boyutta ve kapanistan sonra yazilabilir (tanitici sizmadi). Beklenti: yalniz **tam yazilmis meta** (`postmeta`) dosyadan servis edilir (`builds=0`, `hits>0`); diger tum pencerelerde `builds>=1`. Yani "heap onaylandi ama indeks yazilmadi" penceresi gercekten olculur ve **sessiz eksik satir gorulmez**. On-kapi (`git archive HEAD` = `e911ee8`): `Fatal: (10022) Can't find unit VDbDiskIdx used by dixcrash` - birim HEAD'de **yoktur**, kapi ayirt edicidir |
| `disk_index_scale` | **disk indeksi olcek kapisi** (SKILL12): `dixscale [satir]` (varsayilan 1.000.000; CI'da **200.000** ile kosar). 1M satirlik `t(id INTEGER PRIMARY KEY, a TEXT, n INTEGER, b TEXT)` uzerinde iki ikincil indeks (`ix_a`, `ix_n`) kurulur, kapatilip yeniden acilir. S1-S18 (**17 kontrol**): iki `.dix` dosyasi yazildi, yeniden acilista satir sayisi, esitlik ve aralik sonucu **bagimsiz hesapla** ayni, yeniden insa **YOK** (`builds=0`) ve **disk`ten servis** (`hits>0`), ikinci soguk acilista ayni sonuclar ve hala insa yok, `UPDATE`/`DELETE` sonrasi kalici sonuclar; **S15-S18 yapisal kanit**: `.dix` dogrudan acilir, `PageCount>100` ve `Height>=2` olculur, tek `Find` icin **okunan sayfa sayisi <= 8** (1M'de olculen: 3 sayfa / 5886 sayfa / yukseklik 3) - indeksin tamami RAM'e alinmiyor, salt-okunur onbellek 64 sayfa (256 KB) ile sinirlidir. Olculen 1M (Windows i386): yazim 14.516 ms, `.dix` 45.232.128 B (guncelleme sonrasi 49.139.712 B), soguk acilis + ilk sorgu 531 ms. 200k kosusunda: 2.797 ms, 8.892.416 B, 1157 sayfa, yukseklik 3, arama basina 3 sayfa. **Durust sinir**: `heap_delta` yalniz **BILGI** olarak yazilir (`TotalAllocated` deltasi RSS degildir ve SQL planlayici/onbellek ayirmalarini da icerir), bu yuzden bellek iddiasi PASS/FAIL uretmez - kanit S18'dir. **10M kosusu BASARISIZDIR**: 32-bit ikilide `CREATE INDEX` once tum indeksi bellekte `TIdxEntries` olarak maddelestirdigi icin 10M satirda `EOutOfMemory` alinir (ekleme dongusu tamamlanir, indeks kurulumu coker). Bu **olculmus bir sinirdir**, PASS degildir; 10M icin akisli/toplu indeks insasi gerekir ve bu yapilmadi. On-kapi (`git archive HEAD` = `e911ee8`): `Fatal: (10022) Can't find unit VDbDiskIdx used by dixscale` - birim HEAD'de **yoktur**, kapi ayirt edicidir |
| `auth_throttle` | SCRAM deneme sinirlama/kilit |
| `spill_core` | **spill cekirdegi** (SKILL11): `VDbSpill.pas` biriminin saf Pascal kendini testi (**29 kontrol**). Kosu dosyasi bicimi (magic `VDBSPL1`, alan sayisi, NULL maskesi) gidis-donus, `TVdbSpillWriter`/`Reader` bayt muhasebesi, `VdbSpillStableSortRows` kararliligi, 4 kosunun `TVdbSpillMerger` ile birlestirilmesinin **tek seferlik kararli siralama ile birebir** ayni olmasi, gecici dizin/manifest yazimi (DB/PID/VER/RUN), olu pid dizinlerinin toplanmasi, canli pid'in korunmasi, `VdbSpillRowBytes`/`MatrixBytes` muhasebesi. Harici arac/DLL yok. Iki platformda 29/0. |
| `stream_spill` | **imlec duzeyinde dis siralama** (SKILL11): `tests/stream_spill` (**31 kontrol**, SS1-SS13). SS1 ORDER BY'in gercekten kosu dosyalarina tasdigi (`FSpillRuns>1`); SS2/SS3 imlec ciktisinin maddesel `Exec` ile **bit bit** ayni olmasi (deger + sira), `LIMIT/OFFSET` imlecte; SS4 satir 10x artinca tepe bellegin **plato** yapmasi (olculen 10k=1.097.519 B, 100k=1.376.531 B, oran 1,25); SS5 normal bitiste gecici dizin kalmamasi; SS6 `Cancel` sonrasi temizlik; SS7 **tarama sirasinda hata** (CAST bozuk deger) sonrasi temizlik; SS8 baska surecten kalan artik dizinin toplanmasi, CANLI pid dizininin korunmasi; SS9 `OpenCursor`/`NextChunk` (NextBatch)/`Free` (CloseCursor) yolu; SS10 64 MiB butce ile 100k satir; SS11 **1M satir ORDER BY** (35 kosu, tepe ~2,7 MB, Windows i386'da ~34 sn); SS12 belgelenen maddesel fallback'larin (GROUP BY, DISTINCT, JOIN, UNION ALL, pencere, **NULL tasiyan tablo**) maddesel yolda kalip ayni sonucu vermesi (iki yol karistirilmaz); SS13 tuketilmis imlecte `ReleaseBuffers` ile teslim tamponunun ve dis siralama kaynaklarinin birakilmasi (`LiveBytes` kuculur, `PeakBytes` kaniti korunur, imlec tukenmis kalir, ikinci cagri zararsiz - bitmis portallar sonuc bellegi butcesinde yer tutmaz). Butce dis siralama icin `VdbSpillBudgetOverride` ile kucultulur; spill kok dizini kendi calisma dizinidir, gercek `%TEMP%` kirlenmez. On-kapi (`git archive HEAD` = `ee5be42`): kapi **derlenmez** - 15 x `Error: (5038) identifier idents no member "FExtSort"/"FSpillRuns"/"FSpillBytes"/"PeakBytes"`; ozellik HEAD'de yoktur. |
| `selftest_builtin` | provider SelfTest (builtin) |
| `tls_client` | istemci CA + sunucu adi dogrulamasi (OpenSSL varsa) |

Kosullu kapilar:

- `fixtures_openssl`, `selftest_openssl`: yalniz `VDB_CRYPTO_DLL` verilmisse.
- `tls_client`: OpenSSL yuklenemezse kapi **77** ile kendini atlar
  (`SKIP`); bu "gecti" sayilmaz, kosan kapi sayisina da eklenmez.
- `interop_external`, `crypto_interop_ext`, `bench_sqlite`: Python (ve
  `interop_external` icin pyarrow) bulunamazsa kapi **77** ile atlar.
  `VDB_INTEROP_PY` yorumlayicinin yolunu, `VDB_PY_LIBS` depo disindaki
  pyarrow dizinini gosterir. Bu kapilar da PASS sayilmaz; araclar depoya
  **bagimlilik olarak eklenmez**.

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

### Matris kapsami ve olculmeyen platformlar (v3.51)

Matris **yalniz** `ubuntu-latest` (x86_64) ve `windows-latest` (i386) uzerinde
kosar. Su platformlar icin **job yoktur ve hic kosulmadi**:

| Platform | Durum | Neden |
|---|---|---|
| macOS (x86_64 / arm64) | **not-run** | Bu ortamda macOS makine yok; `run_gates.sh` Unix dalini kullanir ve tasinabilirlik notlari (bkz. §5) macOS icin de yazildi, ama **kapilar macOS'ta kosulmadi**. |
| linux/arm64 | **not-run** | Yalniz x86_64 Linux olculdu; ARM'da ne derleme ne kapi kosumu yapildi. |
| windows/arm64 | **not-run** | Ayni sekilde olculmedi. |
| Buyuk-endian | **not-run** | Kalici yapi kucuk-endian varsayar; `portability` kapisi bunu ayni platformda olcer, endian degistirmez. |

Bu satirlar "kosmuyor" degil **"olculmedi"** demektir ve raporda da boyle
gecer (`docs/audit/V3_ADVANCED_HARDENING_REPORT.md` bolum B/G). Dogrulanmamis
bir platformu matrise eklemek, yesil gorunen ama hicbir sey kanitlamayan bir
kapi uretirdi; bu yuzden eklenmedi. ARM/macOS eklenecekse once gercek bir
kosum yapilmali, sonra job yazilmalidir.

### Ayri is: `sql_differential_postgres` (v3.48)

Canli PostgreSQL diferansiyeli (SKILL4 §5) **kendi isidir** ve `gates`
matrisine dahil degildir; boylece PG servisi kapilarin suresini ve
sonucunu etkilemez:

1. `ubuntu-latest` + `postgres:16` **servisi** (`pg_isready` health check,
   `POSTGRES_DB=vdb_diff`, kullanici/parola `vdb`).
2. `apt-get install fpc postgresql-client`.
3. `sql_differential` saf `fpc` ile derlenir (`build/pg`).
4. `tests/sql_differential/run_pg.sh` korpusu `--emit` ile psql betigine
   cevirir, `psql` ile kosar ve ciktiyi `--pg=` ile kapiya verir.
5. Cikti her zaman artifact olarak yuklenir (`pg-run.out`, `emit.sql`,
   `pg.out`, `psql.err`).

Cikis kodlari PASS/SKIP/FAIL ayrimini korur:

| Kod | Anlam | Durum |
|---|---|---|
| 0 | canli karsilastirma kosuldu ve gecti | PASS |
| 77 | `psql` yok / baglanti kurulamadi | **SKIP = not-run**, PASS sayilmaz |
| 1 | kosuldu, fark bulundu | FAIL |

77 durumunda is yesil kalir ama check-run'a `::warning::canli PostgreSQL
kosmadi (SKIP, PASS sayilmaz)` yazilir; bu satir olmadan "yesil = PG
dogrulandi" diye okunmamalidir. Bu is **bu ortamda hic kosmadi** (yerelde
`psql` yok); yerelde yalniz SKIP dali dogrulandi (cikis 77). Ilk gercek
kosum CI'da olacaktir.

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
    sikismasi (protokol surumu 1 + ad) dogru; giris + `CREATE TABLE` +
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
- Otuz ikinci kosu (v3.47, SQL yurutucu olcek olcumu): **iki platform da
  YESIL**. Git Bash/Windows **40 kapi** PASS (`tls_client` SKIP), WSL
  x86_64 Linux **41 kapi** PASS (OpenSSL istege bagli iki kapi SKIP).
  Yeni kapi `sql_scale` **34 PASS / 0 FAIL**, iki platformda ayni
  satir/deger (yalniz sureler farkli). Diger butun kapilar degismedi
  (`sql_differential` yine `pg=not-run`).
  - **Iki kademe**: 100.000 satir `t(id, b, v)` ve 1.000.000 satir
    `m(id, v)`. Olculen: 100k ekleme 656 ms (Windows i386) / 1213 ms
    (Linux x86_64), dosya 3.997.696 B; 1M ekleme 6547 / 11849 ms, dosya
    37.543.936 B, yigin deltasi 43.084 / 43.704 KB; 1M LIMIT'siz
    `SELECT *` 516 / 900 ms (tum 1M satir doner), 1M `ORDER BY id
    LIMIT 100` 859 / 1212 ms, 1M `WHERE id > 999000` 1000 satir.
  - **Dogruluk, hizdan ayri olculur**: `SUM(id)` = 5.000.050.000,
    `MIN`/`MAX` = 1/100000, `AVG(id)` = `50000.5`, `GROUP BY b` 10 grup x
    10.000, `HAVING COUNT(*) > 20000` -> 0 ve `>= 10000` -> 10, `JOIN`
    100 eslesme, `OFFSET 99997 LIMIT 3` -> 99998..100000. 1M tam
    taramada ilk/orta/son deger (`m1`, `m500000`, `m1000000`) tek tek
    dogrulanir; paylasilan/alias satir tamponu olsa bu kontrol duserdi.
  - **Bellek sayisi durustce yorumlanir**: `yigin_delta_kb`
    `GetHeapStatus.TotalAllocated` deltasidir, **RSS degildir** ve bos
    bloklarin yeniden kullanimi onu etkiler. Aletin kor olmadigi kapida
    kanitlanir (SS20: 8 MB ayirma, 7812 KB olculdu = beklenenin %95'i).
    LIMIT'siz taramada olculen delta satir basina tam bir isaretci
    (i386 4 B, x86_64 8 B); bu sayinin kok nedeni **arastirilmadi**,
    rapor onu "verimlilik" diye yorumlamaz.
  - **Sonuc kumesi tavani**: `VDB_MAX_RESULT_ROWS` = 2.000.000 (v3.37)
    tarama/toplama/`DISTINCT`/`JOIN` yollarinda `ecLimit` ile uygulanir.
    Bu kapi tavanin **altinda** olcer; ustunu maddelestirmek 32-bit
    kapida ~GB bellek ister, o yol `tests/limits` L4 ile kapsanir. Yani
    "2M satir ureten bir kapi" yoktur ve olmayan sey oyle yazilmaz.
  - **Dayaniklilik**: 5000 satirlik islem `COMMIT` sonrasi gorunur,
    `ROLLBACK` sonrasi hayalet satir yok; buyuk taramalardan sonra
    `INSERT`/`UPDATE`/`DELETE` calisir (1M'de kalir) ve yeniden acilista
    tam `VERIFY` temizdir (`sayfa=995 serbest=0 heap=994 tasma=0
    trunk=0 anahtar=104194 lsn=405` ve `sayfa=9139 serbest=0 heap=9138
    tasma=0 trunk=0 anahtar=1000001 lsn=2005`).
  - **Bu kapi yeni motor kusuru bulmadi**; tek duzeltme kapinin kendi
    olcum aletiydi (olu `TotalCommitted` metrigi kaldirildi, yerine SS20
    alet dogrulamasi geldi). Durust sinir: satirlar hala 4 KB sayfa
    yigininda ve ikincil indeksler bellekteki `TVDbBTree` icinde, bu
    yuzden bu kosu disk indeks olcmez (bkz.
    `docs/engineering/SQL_SCALE.md`).
- Otuz ucuncu kosu (v3.49, SQL indeks olcegi + disk tasarimi): **iki
  platform da YESIL**. Git Bash/Windows **41 kapi** PASS (`tls_client`
  SKIP), WSL x86_64 Linux **42 kapi** PASS (OpenSSL istege bagli iki kapi
  SKIP). Yeni kapi `sql_index_scale` **45 PASS / 0 FAIL**, iki platformda
  birebir ayni. Diger butun kapilar degismedi (`sql_differential` yine
  `pg=not-run`); parser'a dokunuldugu icin `sql_matrix`, `sql_features`,
  `sql_stubs` bu kosuda ayni sekilde PASS.
  - **Kapsam**: 100.000 ve 1.000.000 satirlik tablolarda birincil anahtar
    nokta okumasi ve plani (`Index Scan using t_pkey`), indekssiz plan
    (`Seq Scan`), `CREATE INDEX` sonrasi ikincil indekste esitlik/aralik
    (`Index Only Scan using ix_t_w`), mukerrer anahtar reddi
    (`ecUniqueViolation`) ve hayalet satir olmamasi, mukerrer `UPDATE`
    reddi, indeks uzerinden gorunen `UPDATE`/`DELETE`, 300 karisik
    insert/update/delete, `REINDEX`, `VACUUM`, `VACUUM` ve yeniden acilis
    sonrasi dogruluk, tam `VERIFY`, `SHOW INDEXES FROM t`, ve `.odb.idx`
    yan dosyasi bozuldugunda veri kaybi olmadan tarama ile dogru sonuc.
  - **Olculen (Windows/Linux)**: 100k ekleme 688/1028 ms; 100k
    `CREATE INDEX` 172/237 ms; 1M ekleme 6625/11083 ms; 1M `CREATE INDEX
    ix_m_v` 1016/1700 ms; 1M indeksten nokta okuma 0/1 ms; yeniden acilis
    sonrasi ilk indeksli sorgu 1203/1586 ms; indeks basina satir maliyeti
    24/49 B; `.odb.idx` 100k 1.083.868 B ve 1M 10.985.254 B (iki
    platformda ayni).
  - **Bellek sayisi durustce yorumlanir**: `yigin_delta_kb`
    `TotalAllocated` deltasidir, RSS degildir; 100k indeks kurulumunda
    Windows'ta **-104 KB** olctu (ayirici bloklari yeniden kullandi), bu
    yuzden yalnizca 1M satir basina maliyet raporlanir. Yeniden acilis
    sonrasi ilk indeksli sorgunun 1,2-1,6 s surmesi, indeksin bellekte
    oldugunun ve ilk kullanimda yeniden kuruldugunun dogrudan kanitidir.
  - **F-19 duzeltmesi**: tablo adi olmadan `SHOW INDEXES` artik dosya
    sonuna kadar okuyup `Beklenmedik dosya sonu konum=N` yerine
    `ecSyntaxError` ile `SHOW INDEXES icin tablo adi gerekir (ornek: SHOW
    INDEXES FROM t)` diyor. Kapi bunu IX18a/IX18b'de dogrular.
  - **Durust sinir**: ikincil indeksler hala bellekteki
    `FMemIdx`/`TVDbBTree` icindedir; `.odb.idx` yalnizca yeniden
    uretilebilir bir onbellektir (veri kaynagi **degildir**) ve
    `VDbBTreeDisk.pas` v5 motor dosya bicimine **bagli degildir**. Bu
    kapi disk indeks olcmez; "VDB disk indeksi kullaniyor" demek bugun
    yanlistir. Tasarim `docs/engineering/DISK_BTREE_DESIGN.md` icinde
    yazildi, 10M kademesi kosmadi. `.idx` varsayilan silme davranisi
    degismedi; kapi olcmek icin `KeepIdxOnClose` ile acik katilir.
  - **Bu kosuda bulunan gercek kusur (F-20)**: `auth_throttle` ilk Linux
    kosusunda T3b/T3c/T3d'yi dusurdu (13/3), yalitilmis kosuda ise 5/5
    geciyordu. Kok neden `VDbPgWire` icindeki ceza penceresinin duvar
    saatiyle (`Now`) olculmesiydi; saat geriye adim atinca kilit uzuyor,
    ileri gidince erken aciliyordu. Ceza/pencere artik `GetTickCount64`
    tabanli **monotonik** milisaniye ile olculur; ayarlar, API ve
    davranis aynidir. Duzeltmeden sonra kapi 8/8 kosuda 16/16 PASS.
- Otuz dorduncu kosu (v3.50, gomulu motor soak kapisi): **iki platform da
  YESIL**. Git Bash/Windows **42 kapi** PASS (`tls_client` SKIP), WSL
  x86_64 Linux **43 kapi** PASS (OpenSSL istege bagli iki kapi SKIP). Yeni
  kapi `soak` **20 PASS / 0 FAIL**, iki platformda birebir ayni.
  - **Kapsam**: acik `TVDbBackendV3` uzerinde 2.000 canli satirlik tablo ve
    tur bazli churn (100 ekle + en eski 100 sil + bir guncelleme, canli
    satir 2.000'de kalir). Varsayilan 25 sn (`VDB_SOAK_SECONDS`, 5..86400),
    her `VDB_SOAK_CP` turda zorunlu `Checkpoint(True)`, her `VDB_SOAK_REOPEN`
    turda kapat/ac. Her turda orneklenen: yigin (`TotalAllocated` deltasi,
    RSS **degil**), dosya tanitici/sap, is parcacigi, WAL bayti, dizin
    bayti, gecikme p50/p95. SO1-SO14 sabitlik/tavan kontrolleri, SO15a-d
    F-21 dizin doygunlugu regresyonu, SO16/SO17 F-22 uc-sayim regresyonu.
  - **Olculen**: dort varyant (cp+reopen, yalniz reopen, yalniz cp, hicbiri)
    Windows'ta 20/20, Linux 12 sn'lik kosuda 20/20 PASS.
  - **Bu kosuda bulunan iki gercek kusur**: **F-21** — heap dizini canli
    sayiya gore buyuyordu; mezar taslari doldurunca `Insert` sessizce
    `False` donuyor ve toplu yazim hatasi veriyordu (artik `FUsed` canli +
    mezar tasi izler ve doygunlukta `EVdbHeap` atar). **F-22** — serbest
    listedeki sayfa yeniden acilista heap sayfasi sanilip icine satir
    yaziliyor, sonra `AllocPage` onu `PageInit` ile sifirlayarak onayli
    satirlari sessizce siliyordu (olculen: 2.000 satirdan 104'u; kayip
    checkpoint + yeniden acilis birlikte gerektiriyordu). Duzeltmeler
    `CollectFreePages`, `Open` atlamasi, `SpaceHintScan` filtresi ve
    `AllocPage` savunmasi; regresyon SO15/SO16/SO17.
  - **Durust sinir**: bu bir **gomulu motor** soak'idir; ag sunucusu
    (TVdbPgServer) soak'i ayri is kalemidir ve burada kosulmaz. Kapi 25 sn
    kosar; gercek 1 saat / 6 saat / 24 saat soak **kosulmadi**, bu yuzden
    uzun sureli kaynak sizintisi iddia edilemez. Yigin olcusu RSS degildir.
    Cokme/kurtarma yollari `wal_crash`, `crash_points`, `page_corrupt`
    kapilarinda olculur; soak'ta cokme simule edilmez.
- Otuz besinci kosu (v3.51, platform kapsami ve son audit): **yeni kapi
  yok, davranis degisikligi yok**. Bu kosu matrisin **kapsamini** kayda
  gecirir; kod, kapi listesi ve sonuclar otuz dorduncu kosuyla aynidir
  (Windows 42 / Linux 43 PASS, 0 FAIL).
  - **Matris**: yalniz `ubuntu-latest` (x86_64) ve `windows-latest`
    (i386). `fail-fast: false` korunur; bir platformun kirilmasi digerini
    gizlemez.
  - **Olculmeyen platformlar (not-run, job YOK)**: macOS (x86_64/arm64),
    linux/arm64, windows/arm64, buyuk-endian. Bunlar icin job eklenmedi
    cunku bu projede **hic kosulmadi**; dogrulanmamis bir platformu
    matrise eklemek yesil gorunen ama hicbir sey kanitlamayan bir kapi
    uretirdi. Ayrim bu belgenin bolum 3 tablosunda ve
    `docs/audit/V3_ADVANCED_HARDENING_REPORT.md` bolum B/H'de yazili.
  - **Canli PostgreSQL** hala `pg=not-run`: `sql_differential` 33/0
    kosar ama gercek sunucuya baglanmaz; ayri is
    `sql_differential_postgres` baglanti yoksa **77 (SKIP)** doner ve
    PASS sayilmaz.
  - **Son audit**: `docs/audit/V3_ADVANCED_HARDENING_REPORT.md` A-J
    bolumleriyle yazildi; siniflandirma **BETA CANDIDATE**. Uzun soak
    (1/6/24 saat), ag sunucusu soak'i, disk indeks ve macOS/ARM64
    olculmedi; bunlar acik risk olarak listelenir.
- Otuz altinci kosu (v3.52, Sprint A + B): **iki platform da YESIL**.
  Git Bash/Windows **44 kapi** PASS, WSL x86_64 Linux **45 kapi** PASS,
  FAIL 0 (`gatesB.log`, `linB.log`; `tls_client` Windows'ta OpenSSL DLL'leri
  ortamda oldugu icin kostu, Linux'ta 6/6).
  - **Sprint A** (3.2-3.5): oturum kimligi (baglanti yetkisiz baslar, global
    `FSessionId` yetki kaynagi degil, `admin/admin123` kaldirildi), upsert
    yolu UPDATE yetkisi/RLS/ROW trigger uygular, MERGE RLS + trigger
    pariteligi, AFTER STATEMENT trigger'lari commit'ten once. Yeni kapi
    `sql_authorization` (32/0) ve `sql_atomicity` (Sprint A'da 23/0).
  - **Sprint B** (SQL atomikligi): `ExecInsert`/`ExecCopy` BEFORE STATEMENT
    trigger'i batch icinde ateslenir (B1); `ExecUpdate`/`ExecDelete` BEFORE
    STATEMENT trigger'i artik atesleniyor (B2, eskiden hic yoktu); 0 satir
    eslesen DELETE'te trigger DML'i korunur (B4, eskiden kosulsuz
    `AbortBatch`). `INSTEAD OF` govdesi batch'e alindi ama parser bu zamani
    uretmedigi icin bu yol **ulasilamaz** (B3, kod savunmasi; kapi yok).
  - **Kapi buyudu**: `sql_atomicity` 5 vaka/23 kontrol -> **19 vaka/88
    kontrol**. Duzeltme oncesi kaynakla (`git archive HEAD` + ayni test)
    **8 kontrol FAIL** (AT8 x3, AT9 x2, AT10, AT18, AT19) ve exit 1; yani
    kapi kusuru gercekten yakaliyor. Duzeltilmis agacta 88/0.
  - **Durust sinir**: `sql_atomicity` degisiklikleri gomulu motorda olcer;
    ag sunucusu uzerinden ayni senaryolar kosulmadi. `INSTEAD OF` ve
    procedure/`IF` iceren trigger govdeleri desteklenmiyor, kapilar bunlari
    kapsamaz.
- Otuz yedinci kosu (v3.53, Sprint C): **iki platform da YESIL**.
  Git Bash/Windows **45 kapi** PASS, WSL x86_64 Linux **46 kapi** PASS,
  FAIL 0 (`gatesC.log`, `linC.log`; Windows'ta `tls_client` bu kosuda
  `VDB_CRYPTO_DLL` yok diye SKIP, Linux'ta 6/0).
  - **4.1 WAL-before-data**: checkpoint sirasi duzeltildi. Eskiden
    `FStore.Flush(True)` veri dosyasini fsync ediyor, WAL bariyeri
    (`AwaitDurable`) **sonra** bekleniyordu; WAL fsync basarisiz olunca
    dayanikli olmayan commit'in veri sayfalari diskte kaliyor ve yeniden
    acilista **hayalet commit** goruluyordu. Yeni sira: WAL yaz, WAL fsync,
    durabil LSN dogrula, sonra veri sayfalari + fsync, sonra WAL'i yalniz
    durabil checkpoint sinirina kadar buda.
  - **4.2 POISONED**: `RecoverAfterDurabilityFailure` hicbir istisna
    yakalamiyordu (hata yalniz `FLastCommitProblem` metniydi). Artik kurtarma
    hatasi motoru POISONED yapar ve `ecInvalidState` ile tum okuma/yazma
    reddedilir; kapatip acma temiz baslar. Basarili kurtarma `FSyncErr`
    alanini temizler (eskiden her sonraki `AwaitDurable` aninda hataya
    dusuyordu).
  - **Yeni kapi**: `wal_recovery` 5 vaka **27 kontrol**, iki platformda 27/0.
    Duzeltme oncesi kaynakla derlenen sonda **3 kontrol FAIL**; ayrica ilk
    denemede ekledigim bariyer kontrolu yanlis bir invaryanti olcuyordu
    (`store LSN` ile `durable LSN` karsilastirmasi; WAL bosken mesru
    checkpoint'leri kiriyordu) ve 5 kapi kirmizi oldu; duzeltme sonrasi
    hepsi yesil.
  - **Durust sinir**: `.gen` eslemesindeki durabil-LSN aynasi **yalniz
    Windows'ta** kurulur (`MapGen` tamamen `{$IFDEF WINDOWS}`); Linux'ta
    surecler arasi durabil-LSN paylasimi **yoktur**. Kapi bu yuzden motor
    duzeyindeki `Engine.DurableLsn` degerini olcer (Linux'ta `store=0`
    beklenen degerdir). Cokme `SimulateCrash` ve hata kancalariyla taklit
    edilir; gercek elektrik kesintisi dayanikliligi iddia **edilmez**.
- Otuz sekizinci kosu (v3.54, Sprint D): **iki platform da YESIL**.
  Git Bash/Windows **46 kapi** PASS, WSL x86_64 Linux **47 kapi** PASS,
  FAIL 0 (`gatesD.log` -> `KOSAN KAPI: 46`, `GATES_EXIT=0`; `linD.log` ->
  `KOSAN KAPI: 47`, `LIN_EXIT=0`).
  - **5.1 freelist butunlugu**: serbest sayfa listesi dogrulanmiyordu; ayni
    sayfa iki kez ya da bir **trunk** sayfasi serbest birakilirsa ayni fiziksel
    sayfa iki sahibe verilebiliyor ve biri digerinin satirlarini ezebiliyordu.
    `FreePage` artik cift serbest birakma, trunk ve **canli hucre tasiyan**
    sayfa icin reddeder; `CollectFreePages`/`VerifyFreeList` zincir dongusu,
    yinelenen girdi, aralik disi girdi ve `FreeCount` uyusmazligini `False` +
    `Err` ile bildirir. Yeni kapi `freelist` 9 vaka **32 kontrol**, iki
    platformda 32/0; duzeltme oncesi kaynakla **4 kontrol FAIL**
    (cift serbest birakma, trunk, canli sayfa, yinelenen girdi).
  - **5.2 + 6.1/6.2 disk B+Tree sayfa butunlugu**: `ReadPage` diskten okunan her
    sayfada CRC + kimlik + yapisal sinir dogrular; `MarkReachable` kisa okuma,
    kotu CRC ve bozuk yapida `EBtdError` atar (eskiden bozuk sayfa sessizce
    serbest ilan edilip geri kazanilabiliyordu). **Sozlesme degisikligi**:
    bozuk dosya acilmaz; `BD15`/`BD16` yeniden yazildi (`RestampCrc` ile
    "CRC gecerli, yapi bozuk"). `btree_disk` 78/0.
  - **Kendi regresyonumuz (durust kayit)**: Sprint D'nin ilk hali mevcut `soak`
    kapisini kirdi (SO2/SO3/SO12/SO16/SO17, 5 FAIL). Kok neden
    `FreeIndexEnsure` dongu sayacinin `LongWord` olmasiydi: `cnt = 0` iken
    `Integer(cnt) - 1 = -1`, sayac `LongWord` oldugu icin `$FFFFFFFF` olup
    dongu sayfa disindaki cop girdileri okuyordu (`freelist indeksi: girdi
    aralik disi`). Sayac `Integer` yapildi; `CollectFreePages` ve
    `VerifyFreeList` ayni kalibi `if cnt > 0` ile korudugu icin dokunulmadi.
    HEAD soak 20/0, duzeltilmis agac soak 20/0. Kapi **gevsetilmedi**.
  - **Durust sinir**: `VDbBTreeDisk` motora bagli degildir; disk indeks yolu
    hala yoktur (R5 acik). Sprint D motorun indeks yolunu degistirmez.
- Otuz dokuzuncu kosu (v3.55, Sprint F1): **iki platform da YESIL**.
  Git Bash/Windows **47 kapi** PASS, WSL x86_64 Linux **48 kapi** PASS,
  FAIL 0 (`gatesF.log` -> `KOSAN KAPI: 47`, `GATES_EXIT=0`; `linF.log` ->
  `KOSAN KAPI: 48`, `LIN_EXIT=0`).
  - **8.5 CAST sessiz sarmasi**: `VDbParseInt` birikimi tasmayi
    denetlemiyordu; `CAST('9999999999999999999999' AS INTEGER)` sessizce
    `1864712049423024127` donuyordu (24 hane: `2003764205206896639`).
    Birikim artik `QWord` + isaret basina tavan (`2^63-1` / `2^63`) ile
    yapilir; aralik disi metin `ecTypeMismatch` uretir, `Low(Int64)` gecerli.
  - **8.5 ABS hassasiyeti**: `ABS` once float denedigi icin her tam sayida
    float donuyordu (`ABS(9223372036854775806)` -> `9.22337203685478E18`).
    Artik once `VDbParseInt`; `ABS(Low(Int64))` -> `ecMathError`.
  - **8.5 Low(Int64) isareti**: tekli eksi `Low(Int64)` uzerinde sessizce
    sariliyordu; artik `ecMathError`. Parser `-<tamsayi>` bicimini isaretle
    birlikte cozer (`ParsePrimary`'nin isaretli dali onceden ulasilamiyordu).
  - **8.4 ozyinelemeli CTE**: `VDB_RECUR_MAX` sinirina takilan ozyineleme
    **kismi sonucu hata vermeden** donduruyordu (`1..100001`). Artik
    `ecLimit`; dogal bitiste `deltaRows` bosaltilir; tur basina
    `VDB_MAX_RESULT_ROWS` satir tavani; dongude `TickAbort` (iptal/timeout).
  - Yeni kapi `sql_memory` 26 vaka **54 kontrol**, iki platformda 54/0;
    duzeltme oncesi kaynakla **6 kontrol FAIL** (SM15 x2, SM20 x2, SM22,
    SM26). Kapinin kalan 48 kontrolu 8.2 LIMIT/OFFSET ve 3VL/NULL semantigini
    **dondurur** (duzeltme oncesinde de dogruydu).
  - **Olcum kapisi duzeltmesi (durust kayit)**: bu kosuda `perf_baseline`
    `btree/scale-linear` oranini 4,64 olctu (esik 3,50) ve kirmizi oldu; ayni
    ikili tek basina 3 kez 1,50 / 1,98 / 2,32 verdi (tam sureler ~50 ms,
    zamanlayici gurultusu). Olcum artik her boyut icin iki kez kosup **kucuk**
    degeri alir. **Esik degismedi**; karesel davranis hala yakalanir.
  - **Durust sinir (F2 acik)**: 8.1 uctan uca streaming, PG portal `maxRows`,
    COPY OUT streaming, ORDER BY/DISTINCT/GROUP BY **disk spill**, JOIN bellek
    butcesi/hash birlestirme ve 8.3 `ExecMerge` O(n*m) olcumu **yapilmadi**;
    sonuc hala `TSqlResult` icinde bellekte toplanir (R8/R13 acik).
- Kirkinci kosu (v3.56, Sprint E - ag sinirlari ve zaman asimlari): **iki
  platform da YESIL**. Git Bash/Windows **48 kapi** PASS, WSL x86_64 Linux
  **49 kapi** PASS, FAIL 0 (`gatesE.log` -> `KOSAN KAPI: 48`,
  `GATES_EXIT=0`; `linE.log` -> `KOSAN KAPI: 49`, `LIN_EXIT=0`).
  - **E1 zaman asimlari (F-29, YUKSEK)**: baglanti soketlerinde okuma/yazma
    zaman asimi **yoktu**. Tek bayt gonderip bekleyen istemci `HandleQuery`
    icinde sonsuza kadar blokluyor, is parcacigi ve baglanti slotu
    bosalmiyordu; `MaxConns = 1` iken tek yarim baglanti sunucuyu **kalici
    olarak** kapatabiliyordu. `VDbNet.VdbSockSetTimeouts`
    (`SO_RCVTIMEO`/`SO_SNDTIMEO`; Windows `DWORD` ms, Unix `timeval`) ve
    `ReadTimeoutMs`/`WriteTimeoutMs` (varsayilan **30000 ms**, 0 = kapali)
    eklendi; zaman asimi **kabul aninda** kurulur, yani startup ve TLS el
    sikismasi da kapsanir. On-kapi olcumu (duzeltme oncesi kaynak,
    `netlim_head.lpr`): `MaxConns=1` + yarim startup -> ikinci istemci
    **6031 ms** sonra hala giremiyor (`H1` FAIL).
  - **E2 mesaj boyutu (F-30, ORTA)**: on-kapa asan cerceve `Break` ile
    **sessizce** baglantiyi kapatiyordu; istemci nedenini ogrenemiyordu.
    `MaxMessageBytes` (varsayilan 64 MiB) asiminda kontrollu `ErrorResponse`
    `SQLSTATE 54000` gonderilir; govde okunmaz, baglanti kapatilir.
  - **E3 COPY toplam boyutu (F-31, ORTA)**: `COPY ... FROM STDIN` yalniz
    **parca** basina sinirlaniyordu; istemci sinirsiz sayida parca gondererek
    gecici dosyayla diski doldurabiliyordu. Toplam `CopyMaxBytes` (varsayilan
    **256 MiB**) eklendi; Unix'te gecici dosya `fpChmod 0600` ile
    kisitlanir (`PgRestrictTempFile`).
  - **E4 kapasite sayaci (F-32, ORTA)**: accept dongusu `FConns.Count`'u
    **kilitsiz** okuyor ve bitmis (`Finished`) is parcaciklarini da sayiyordu.
    `GetConnCount` kilit altinda yalniz canli baglantilari sayar; kapasite
    karari bunu kullanir.
  - **7.4 yasam dongusu incelemesi**: `Stop`/`GcFinished` sirasi incelendi ve
    **dogru** bulundu; bu maddede kod degisikligi yapilmadi (bu bir duzeltme
    degil, dogrulama kaydidir).
  - **Yeni kapi `network_limits`** (NL0-NL7) **22 PASS / 0 FAIL**, iki
    platformda birebir ayni; kapi bir **platform derleme hatasi** yakaladi
    (`VdbMsToTimeval` donus tipi `array[0..1] of Int64` `{$mode delphi}`'de
    gecersiz; blok `{$IFNDEF MSWINDOWS}` icinde oldugu icin Windows kosusu
    bunu derlemez ve hatayi goremezdi; `TTimeVal` ile duzeltildi).
  - **Durust sinir**: TLS'a ozgu bir zaman asimi testi yok (ayni soket
    zaman asimini devralir, ayrica olculmedi); `COPY` varsayilan bicimi
    PostgreSQL text degil **csv**'dir (virgul); Sprint F2 (streaming, disk
    spill) **acik** kalmaya devam eder.
- Kirk birinci kosu (v3.57, Sprint B2 - acik islemde statement atomikligi):
  **iki platform da YESIL**. Git Bash/Windows **48 kapi** PASS, WSL x86_64
  Linux **49 kapi** PASS, FAIL 0 (`gatesG.log` -> `KOSAN KAPI: 48`,
  `SUITE_EXIT=0`; `linG.log` -> `KOSAN KAPI: 49`, `SUITE_EXIT=0`).
  Windows'ta `tls_client` SKIP (OpenSSL DLL yok; `VDB_TLS_FIXTURES`
  verilmezse fikstur bulunamayip FAIL eder - SKIP != PASS), Linux'ta 6/0.
  - **6.1 acik islemde statement atomikligi (F-33, KRITIK, KAPALI)**:
    explicit transaction icinde yarida hata veren bir DML cumlesinin
    yazdigi satirlar kaplamada kaliyordu ve sonraki `COMMIT` bunlari
    **kalici** hale getiriyordu. Olcum (`txnprobe`): `BEGIN` -> cok satirli
    INSERT trigger hatasiyla basarisiz -> islem icinde 2 satir -> `COMMIT` ->
    hala 2 satir. Mevcut kapi bunu **yakalamiyordu**, cunku AT17 yalniz
    `ROLLBACK` sonrasina bakiyordu. Duzeltme: her yazma cumlesi cevresinde
    **ortuk savepoint** (`BeginStmtScope`/`ReleaseStmtScope`/
    `RollbackStmtScope`, `IVDbBackend` uzerinde). Basarili cumle kapsami
    yalnizca kapatir (veri commit edilmez); hata yolunda **yalniz o
    cumlenin** yazimlari dusurulur, onceki cumlelerin yazimlari korunur.
    Kapsam yalnizca yazma anahtar sozcuguyle baslayan cumlelerde, acik
    yazma kumesi varken ve ic ice girmeden (`FStmtScopeDepth=0`) acilir;
    islem denetim cumleleri (`BEGIN`/`COMMIT`/`ROLLBACK`/`SAVEPOINT`) ve DDL
    **disarida** kalir, aksi halde kapsam kapanisi kullanicinin
    savepoint'ini silebilirdi. Kimlik bulunamazsa sessiz doner ve hata
    yolu asil istisnayi maskelemez.
  - **Bellek siniri**: yeni anahtarlar icin gunluk girisi **yazilmaz**;
    kapsam kapanirken `BatchOrder`/`BatchMap`/`Before` kapsam acilisindaki
    uzunluga kirpilir. Boylece 200k satirlik toplu INSERT satir basina
    sozluk girdisi **odemez**; maliyet yalnizca gercekten degistirilen eski
    anahtarlar kadardir.
  - **Olcumun buldugu ikinci kusur**: `TVSql.Exec` (iki asiri yukleme de)
    hizli yol kosulundaki `InBatch` denetimini **yazma oturumu
    sabitlenmeden once** yapiyordu. `InBatch`/savepoint/`BatchMap` oturum
    basina oldugu icin acik islemde bu denetim **cagiranin ortam
    oturumuna** bakiyor, `False` donuyor ve literal/parametreli INSERT hizli
    yolu statement kapsami **acmadan** yaziyordu. Duzeltme: oturum
    sabitlemesi `Exec`/`ExecRaw` govdesinin **tamamini** sarar ve acik
    islemde iki hizli yol da atlanir. Bu kusur yalnizca olcumle bulundu;
    ilk duzeltme tek basina AT21/AT22'yi yesile cevirmiyordu.
  - **Kapinin buyumesi**: `sql_atomicity` 19 vaka/88 kontrol -> **24
    vaka/138 kontrol**. Yeni AT20-AT24: COMMIT sonrasi yarim yazim yok
    (AT20), onceki statement korunur (AT21), hatali statement'in anahtari
    sonraki statement'ta yeniden kullanilabilir (AT22), yarida kalan UPDATE
    geri alinir (AT23), kullanici `SAVEPOINT`'i ortuk kapsamdan etkilenmez
    (AT24). Duzeltme oncesi kaynakla (`git archive 4214586`, bos cwd'de
    derlenerek) **6 kontrol FAIL** (AT20 x2, AT21 x2, AT22, AT23) ve exit
    1; duzeltilmis agacta 138/0.
  - **Duzenlenen kapi (durust kayit)**: AT23'un ilk hali `UPDATE t SET id=1`
    kullaniyordu; bu **degisiklik yapilmadan** `PK kolonu guncellenemez`
    ile dusuyor, yani sahte yesil uretiyordu. Gercek yarim-yazim icin
    `CREATE UNIQUE INDEX` + `UPDATE ... SET v` cakismasi kullanildi. AT24'un
    ilk hali backend API'sini dogrudan cagiriyordu (oturum sabitlenmedigi
    icin yanlis olcum); SQL-only hale getirildi ve `ROLLBACK TO s1`in
    gercekten bir sey sildigini kanitlayan **basarili** bir ara INSERT
    eklendi.
  - **V2 dondurulmus**: `TVdbBackendV2.BeginStmtScope` -1 doner, digerleri
    bos. V2 davranisi **degismedi**; bedeli, V2 yoluyla acik islemde
    statement atomikligi **olmamasidir** (bilinen ve belgelenmis sinir).
  - **Durust sinir**: kapsam kaplama (yazma kumesi) duzeyinde calisir;
    yarim yazilmis **disk sayfasina** karsi ek koruma degildir (o
    `wal_recovery`/POISONED ve `page_integrity` konusudur). Kapsam yalnizca
    **acik islem** icinde acilir: otomatik commit'li tek cumle zaten
    ya-hep-ya-hic yazilir. Ag sunucusu uzerinden ayni senaryolar
    kosulmadi.
- Kirk ikinci kosu (v3.58, Sprint C2 - oturum bazli rol izolasyonu):
  **iki platform da YESIL**. Git Bash/Windows **48 kapi** PASS, WSL x86_64
  Linux **49 kapi** PASS, FAIL 0 (`gatesH.log` -> `KOSAN KAPI: 48`,
  `SUITE_EXIT=0`; `linH.log` -> `KOSAN KAPI: 49`, `SUITE_EXIT=0`).
  Windows'ta `tls_client` SKIP (OpenSSL DLL yok; `VDB_TLS_FIXTURES` verilmezse
  fikstur bulunamayip FAIL eder - SKIP != PASS), Linux'ta 6/0.
  - **3.1 rol izolasyonu (F-34, KRITIK, KAPALI)**: `TVTableDb` tek nesnedir
    ve tum baglantilar onu paylasir (PG wire bir `Ftb` olusturur, her
    istemciye ayri `TVSql` verir). Rol tek bir alanda (`FCurrentRole`)
    tutuldugu icin **bir istemcinin `SET ROLE` cagrisi tum istemcilerin
    etkin rolunu degistiriyordu**; ikinci baglanti kendi iradesi disinda
    kisitli rolle calisip yazma yetkisini kaybediyordu.
  - **Ayni alanda ikinci kusur (fail-open)**: `RoleCan`, `FRoles`'ta
    **bulunmayan** bir rol adi icin `True` donuyordu; yazim hatasiyla verilen
    rol tam yetki veriyordu. Artik **reddedilir** (`False`).
  - **Duzeltme**: rol `VDbGetTxnSession` anahtarli `FRoleBySession`
    sozlugunde tutulur; `EffectiveRole` once oturumun rolune, yoksa gomulu
    varsayilana duser ve `RoleCan`/`RlsApplies`/`RequirePriv`/`CurrentRole`
    onu kullanir. `SET ROLE` oturum varsa sozluge yazar (oturum yoksa gomulu
    davranis aynen surer). `DROP ROLE` silinen rolu **tum oturumlardan**
    dusurur; yoksa o oturumda "bilinmeyen rol" kalir ve fail-closed kurali
    oturumu kilitlerdi.
  - **Kapinin buyumesi**: `sql_authorization` 32 kontrol -> **51 kontrol**.
    Yeni AU8 (iki `TVSql` oturumu tek `TVTableDb` uzerinde: birinin
    `SET ROLE app` cagrisi digerinin yazma yetkisini **etkilemez** - asil
    izolasyon kaniti), AU9 (bilinmeyen rol SELECT/INSERT/ALL icin reddedilir,
    motor kullanici modu serbest), AU10 (oturum kapsami ve `SET ROLE NONE`
    semantigi), AU11 (`DROP ROLE` oturumdaki rolu temizler). Duzeltme oncesi
    kaynakla (`git archive 05136af`, bos cwd'de derlenerek) **5 kontrol FAIL**
    (AU8 x2 izolasyon, AU9 x3 fail-open) ve exit 1; duzeltilmis agacta 51/0.
  - **Durust sinir (kismi kapanis)**: bu sprint **sizintiyi** ve
    **fail-open** kusurunu kapatti. Rol **degistirme yetkisi** (kim hangi
    role gecebilir) ve SCRAM kullanicisi -> SQL rolu eslemesi (SKILL5 3.1
    yetki denetimi + 3.2) **hala ACIK**: principal ile SQL rolu arasinda
    kalici bir esleme yok ve bu, kalici sema/dosya bicimi degisikligi
    gerektirir; bicim v5 degismedi. Bu nedenle "yetkisiz rol yukseltmesi
    tamamen kapandi" denmiyor. Kisitli bir rolu `SET ROLE NONE` ile birakip
    oturum kullanici moduna donmek mumkundur (PostgreSQL de bunu oturum
    kullanicisina donus sayar). Bu yasak **denendi** ve geri alindi: mevcut
    AU1-AU7 temizligi `SET ROLE NONE` kullandigi icin 7 kontrolu dusurdu ve
    principal eslemesi olmadan guvenlik eklemiyordu. Sinir olarak belgelendi.

- Kirk ucuncu kosu (v3.59, Sprint D2 - checkpoint hata yolunda kilit sizintisi):
  iki platform da YESIL. Git Bash/Windows **48 kapi** PASS, WSL x86_64 Linux
  **49 kapi** PASS, FAIL 0 (`gatesI.log` -> `KOSAN KAPI: 48`, `SUITE_EXIT=0`;
  `linI.log` -> `KOSAN KAPI: 49`, `SUITE_EXIT=0`). Windows'ta `tls_client`
  yine **SKIP** (ortamda OpenSSL DLL'i yok; `VDB_TLS_FIXTURES` verilmezse
  kapi fikstur yolundan FAIL eder - SKIP != PASS); Linux'ta kostu: 6/0.
  - **SKILL5 8.1 / F-35 (KRITIK, KAPALI)**: checkpoint sirasindaki ilk sayfa
    yazimi (`WritePageAt`/`SaveMeta` -> `EnsureIoWrite`) surecler arasi
    **exclusive dosya kilidini** alir ve `FAutoWrite` kurar; `EndIoWrite`
    yalnizca **normal yolun sonunda** cagriliyordu. Bu yuzden `AwaitDurable`,
    durabilite bariyeri dogrulamasi, `FStore.Flush` (disk dolu / IO hatasi)
    veya `FWal.Truncate` hata verdiginde kilit bu surecte **asili** kaliyordu:
    diger tum yazarlar busy timeout'a dusuyor, kalici disk-dolu durumunda
    sizinti kendiliginden temizlenmiyordu. Olculen (duzeltme oncesi kaynak,
    `git archive a3b97da`): hata sonrasi ikinci backend 400 ms icinde kilit
    alamadi, hatta kapatip yeniden acma 4000 ms icinde basarisiz.
  - **Duzeltme**: `TVdbPageEngine.Checkpoint` govdesi `try ... finally
    FStore.EndIoWrite; end;` ile sarildi; normal yoldaki ikinci cagri
    kaldirildi (tek birakma noktasi). Kilit her durumda birakilir; sayfa/WAL
    durumu degismez, yalnizca kilit sahipligi duser. Salt-okunur erken cikis
    `try` disinda kalir (kilit zaten alinmiyor).
  - **Kapi**: `disk_full` 16 -> **19** kontrol. DF10a (meta yazimina sert hata
    -> checkpoint kontrollu `ecIOError`), DF10b (hata sonrasi **ikinci
    backend** ayni dosyaya yazabilir), DF10c (yazilan satir okunur). Ikinci
    backend icin ayri tablo (`lockprobe`) kullanildi; boylece DF5/DF6'nin
    sabit satir sayilari (160) degismedi.
  - **Durust sinir**: kapi hatayi **enjekte eder** (gercek `ENOSPC` olculmedi)
    ve ikinci backend **ayni surecte** acilir; kilit dosya tanitici
    (Windows `LockFileEx` handle / POSIX `flock` open file description)
    basina oldugu icin bu ayrim icin yeterlidir, ancak ayri bir isletim
    sistemi sureciyle tekrarlanmadi. Checkpoint hata verdiginde WAL/veri
    dosyasi tutarliligi bu vakada olculmez (o is `wal_recovery`/POISONED ve
    DF9 yollarinda). V2 ve dosya bicimi v5 degismedi.

- Kirk dorduncu kosu (v3.60, Sprint E2 - zaman asimi kurulumunda fail-open):
  iki platform da YESIL. Git Bash/Windows **48 kapi** PASS, WSL x86_64 Linux
  **49 kapi** PASS, FAIL 0 (`gatesJ.log` -> `KOSAN KAPI: 48`, `SUITE_EXIT=0`;
  `linJ.log` -> `KOSAN KAPI: 49`, `SUITE_EXIT=0`). Windows'ta `tls_client`
  yine **SKIP** (OpenSSL DLL'i yok; SKIP != PASS); Linux'ta kostu: 6/0.
  - **SKILL5 9.1 / F-36 (YUKSEK, KAPALI)**: `TVdbPgAccept.Execute` kabul
    ettigi sokette `VdbSockSetTimeouts` cagiriyor ama **donus degerini
    yutuyordu** (fail-open). Kurulum basarisiz olsa da baglanti sunuluyor ve
    o sokette **sinirsiz bloklama** suruyordu; tek bayt gonderip bekleyen
    istemci is parcacigini ve slotu surekli tutabiliyor, `MaxConns` kadar bos
    soket sunucuyu **kalici** kapatabiliyordu. Yani Sprint E1'in zaman asimi
    korumasi en cok ihtiyac duyulan yerde sessizce devre disi kalabiliyordu.
  - **Duzeltme**: fail-closed. Zaman asimi kurulamazsa baglanti **hic
    sunulmaz**: protokol mesaji gonderilmeden kapatilir, slot tuketilmez.
    Iki zaman asimi da `0` ise (yapilandirmayla bilerek kapatilmis) kurulum
    basarili sayilir; bu durumda fail-closed devreye girmez. Kapi icin
    sunucuya **test-only** kanca eklendi (`SockTimeoutFunc`; uretimde `nil`,
    varsayilan gercek `VdbSockSetTimeouts` cagrisi). `VdbSockSetTimeouts`
    sozlesmesi degismedi.
  - **Kapi**: `network_limits` 22 -> **26** kontrol (NL8). Kanca "kurulum
    basarisiz" dondurur, istemci baglanip tek bayt bekler: soket kapanir,
    kapatma 3 s icinde olur, `ConnCount` sifir kalir; kanca kaldirilinca
    sunucu normal istemciyi kabul eder. On-kapi (duzeltme oncesi kurulum:
    HEAD + yalnizca test kancasi, fail-closed blogu cikarilmis) **1 kontrol
    FAIL**: NL8 slot kontrolu (`ConnCount=1`, baglanti sunulmus).
  - **Durust sinir**: baseline "HEAD + test kancasi" olarak kuruldu (kanca
    olmadan kapi derlenemez); fail-closed blogu disinda hicbir sey
    degistirilmedi. NL8'in ilk iki kontrolu (soket kapandi / 3 s icinde)
    baseline'da da gecer, cunku istemcinin kendi 700 ms okuma zaman asimi
    "veri gelmedi" sonucunu uretir; **ayirt edici olan slot kontroludur**.
    Gercek `setsockopt` hatasi enjekte edilmedi, hata yolu kanca ile taklit
    edildi. FPC 3.2.4 / Delphi modu notu: yordam degiskenine `<> nil`
    karsilastirmasi ayni rutinde sonraki cagriyi "Wrong number of parameters"
    ile bozuyor; `Assigned()` kullanildi (olculdu). V2 ve dosya bicimi v5
    degismedi.

- Kirk besinci kosu (v3.61, Sprint G1 - PG sunucusu guvensiz varsayilanlari):
  iki platform da YESIL. Git Bash/Windows **48 kapi** PASS, WSL x86_64 Linux
  **49 kapi** PASS, FAIL 0 (`gatesJ.log` -> `KOSAN KAPI: 48`, `SUITE_EXIT=0`;
  `linJ.log` -> `KOSAN KAPI: 49`, `SUITE_EXIT=0`). Windows'ta `tls_client`
  yine **SKIP** (OpenSSL DLL'i yok; SKIP != PASS); Linux'ta kostu: 6/0.
  - **F-37 (KRITIK, KAPALI)**: `TVdbPgServer` uc noktadan guvensizdi.
    (a) `FBindHost` varsayilani `'0.0.0.0'` idi: kutuphane kullanan her surec
    farkinda olmadan tum arayuzlerde dinliyordu. (b) Kullanici eklenmemisse
    kimlik dogrulama **trust** idi; agdan gelen herkes `AuthOk` alip tam
    veritabani erisimi kazaniyordu. (c) `Start`, dinleme adresini **ham**
    `VdbTcpListen`'e veriyordu ve o anda var olan `VdbResolveListenHost`
    kuralini ("trust yalniz loopback", ad normalizasyonu) **hic cagirmiyordu** -
    yani S1-S9'da dogrulanan R-4 politikasi PG sunucusunda etkisizdi.
  - **Duzeltme**: fail-closed ve guvenli varsayilan. Bind varsayilani
    `'127.0.0.1'`; `Start` once **saf** `ExposureError` kararini verir
    (loopback disi adres yalniz kimlik dogrulama **ve** `RequireTls=True` ile
    kabul edilir; `AllowInsecureRemote=True` varsayilan **False** olan bilincli
    kacis kapisidir), sonra adi `VdbResolveListenHost` ile normalize eder ve
    dinlemeye **cozulmus** adresi verir. Red karari motor/soket acilmadan
    verilir; hata metni istenen adresi ve eksik kosulu icerir. Yerel trust
    modu (varsayilan loopback) korunur. V2 ve dosya bicimi v5 degismedi.
  - **Kapi**: `server_harden` 25 -> **36** kontrol (S12-S15). S12 varsayilan
    bind; S12b loopback+trust kabul; S13/S13b trust ya da TLS'siz uzak adres
    RED; S13c auth+zorunlu TLS uzak kabul; S13d LAN+auth+TLS'siz RED;
    S13e/S13f kacis kapisi acilir/kapanir; S14 gercek `Start` uzak adreste
    **politika** hatasi verir; S14b kacis kapisi politikadan gecer (bind yine
    basarisiz); S15/S15b varsayilan ayarla trust+loopback hala acilir ve
    hizmet verir. On-kapi (duzeltme oncesi kurulum: HEAD + yalnizca yeni API
    kabugu; `ExposureError` bos doner) **6 FAIL**: S12, S13, S13b, S13d,
    S13f, S14.
  - **Durust sinir**: S15/S15b bilerek **ayirt edici degildir**; amaclari
    asiri siki bir duzeltmenin yerel gelistirme yolunu kirmadigini
    gostermektir. S13c yalniz bayraklara bakar; `RequireTls=True` + sertifika
    yok durumu `Start` tarafindan ayrica reddedilir (bu daha eski bir yol,
    degismedi). Gercek TLS el sikismasi bu kapida olculmez (`tls_client`
    kapisi ve Linux kosusu kapsar).

- Kirk altinci kosu (v3.62, Sprint H - ozel TCP SQL sunucusu guvenligi):
  iki platform da YESIL. Git Bash/Windows **48 kapi** PASS, WSL x86_64 Linux
  **49 kapi** PASS, FAIL 0 (`gatesJ.log` -> `KOSAN KAPI: 48`, `SUITE_EXIT=0`;
  `linJ.log` -> `KOSAN KAPI: 49`, `SUITE_EXIT=0`). Windows'ta `tls_client`
  yine **SKIP** (OpenSSL DLL'i yok; SKIP != PASS); Linux'ta kostu: 6/0.
  - **F-38 (KRITIK, KAPALI)**: ozel TCP SQL sunucusu (`VDbSqlServer`) PG
    sunucusundan bagimsiz olarak dort noktadan guvensizdi. (a) `Start`
    dinlemeyi tek argumanli `VdbTcpListen(FPort)` ile aciyordu = `'0.0.0.0'`:
    farkinda olmadan tum arayuzlerde dinleme; protokolde TLS yok, parola
    **acik metin**. (b) `LOGIN` parolayi duz `=` ile karsilastiriyor ve deneme
    sayisinda **sinir yoktu** (PG tarafinda ceza defteri varken burada yok;
    30 s'de sinirsiz deneme). (c) Kabul edilen sokette **hic zaman asimi
    kurulmuyordu**: tek bayt gonderip bekleyen istemci is parcacigini ve
    slotunu tutup `MaxConns` kadar bos soketle sunucuyu kapatabiliyordu.
    (d) `FConns.Count` **kilitsiz** okunuyor ve `GcFinished` kabul dongusunde
    kilitsiz cagriliyordu; bitmis thread listede kalirsa slot geri
    kazanilmiyordu (olculen: baglanti kapandi, sayim `1`'de kaldi).
  - **Duzeltme**: fail-closed ve guvenli varsayilan. Bind varsayilani
    `'127.0.0.1'`; `Start` once saf `ExposureError` karari verir (kimlik
    dogrulama ve/veya TLS yok ise loopback disi adres **reddedilir**;
    `AllowInsecureRemote=True` varsayilan **False**), sonra ad
    `VdbResolveListenHost` ile normalize edilir; karar motor/soket acilmadan
    verilir. Parola **sabit zamanli** karsilastirma (uzunluk + XOR birikimi)
    ve her iki alan; kullanici bazli + global ceza defteri (5 hata / 60 s ->
    30 s kilit, 200 global hata) esik asilinca **dogru parola da reddedilir**.
    Soket zaman asimi kabulde kurulur, kurulamazsa baglanti **sunulmaz**
    (`SockTimeoutFunc` test kancasi, uretimde nil). Sayim/GC kilit altinda.
    V2 ve dosya bicimi v5 degismedi.
  - **Kapi**: `server_failure` 16 -> **30** kontrol (SF9-SF15). SF9 varsayilan
    bind; SF9b kacis kapisi kapali; SF10/SF10b uzak bind politika ile reddedilir
    ve motor acilmaz; SF11 opt-in politikadan gecer; SF12/SF12b sessiz baglanti
    sunucu zaman asiminda kapanir (olculen 797 ms); SF13 zaman asimi
    kurulamazsa baglanti sunulmaz; SF14/SF14b/SF14c esik sonrasi dogru parola
    reddedilir, `AuthReset` sonrasi kabul; SF15/SF15b canli sayim 1 -> 0.
    On-kapi (duzeltme oncesi kurulum: HEAD + yalnizca yeni API kabugu;
    politika/kilit/zaman asimi yok) **7 FAIL**: SF9, SF10, SF10b, SF12b, SF13,
    SF14b, SF15b.
  - **Durust sinir**: SF9b/SF11/SF14/SF14c/SF15 bilerek **ayirt edici
    degildir**; asiri siki bir duzeltmenin normal yolu kirmadigini korurlar.
    SF11 yalniz "politika metni yok" kosuluna bakar (adres bu makinede
    olmadigi icin bind yine basarisiz olur); gercek uzak erisim bu kapida
    olculmez. Sabit zamanli karsilastirmanin **zamanlama** farki olculmedi;
    kapi yalniz davranisi (esik, kilit, red) dogrular.

- Kirk yedinci kosu (v3.63, Sprint I - surecler arasi bakim kilidi):
  iki platform da YESIL. Git Bash/Windows **49 kapi** PASS, WSL x86_64 Linux
  **50 kapi** PASS, FAIL 0 (`gatesJ.log` -> `KOSAN KAPI: 49`, `SUITE_EXIT=0`;
  `linJ.log` -> `KOSAN KAPI: 50`, `SUITE_EXIT=0`). Windows'ta `tls_client`
  yine **SKIP** (OpenSSL DLL'i yok; SKIP != PASS); Linux'ta kostu: 6/0.
  - **F-39 (KRITIK, KAPALI)**: dosya degistirme (`VACUUM`/`Compact`/
    `Restore`/`Rekey` -> `SwapDbFileWith`) yalniz **surec-ici** `FEngCs`
    kilidiyle korunuyordu. Canli dosya kapatilip `.bak`a rename edilirken
    baska bir surec eski dosyayi acik tutabiliyordu; **Linux'ta acik fd eski
    inode'a baglidir**, yani o surec `.bak` inode'una yazmaya devam eder ve
    iki surec **farkli fiziksel dosyalara** yazar (sessiz veri kaybi).
    Olculen (iki surec, Linux): cocuk `wtxn` ile 5 satir commit etti,
    ebeveyn ayni anda `Compact` yapti; Compact **25 ms'de basarili** oldu,
    cocuk `COMMITTED` bildirdi, 5 satir **kayboldu** (COUNT 100'de kaldi).
    Ayni senaryonun okuma tarafi: acik salt-okunur oturum `Compact` sonrasi
    **bayat** veriyi okumaya devam ediyordu (COUNT=100).
  - **Duzeltme**: iki katmanli, fail-closed bakim kilidi. (a) `.gen`
    uzerindeki **yazar rezervasyonu** motor kapanmadan **once** yoklanir -
    Unix'te `Store.Close` `.gen` dosyasini sildigi icin **sira kritiktir**
    (ilk uygulama gen-probe'u motor kapandiktan sonraya koydu ve Linux'ta
    hatayi yakalamadi). (b) motor kapandiktan sonra canli dosya uzerinde OS
    seviyesinde TAM kilit (`VDbOpenProbeStream` + `VDbLockStream`;
    `FILE_SHARE_DELETE` isteyen handle sayesinde Windows'ta rename
    engellenmez). Ikisi de `MaintenanceLockMs` (varsayilan 3000) boyunca
    10 ms araliklarla yoklanir; **alinamazsa degistirmeye baslanmaz** ve
    `bakim kilidi alinamadi ... dosya DEGISTIRILMEDI` hatasi verilir (motor
    eski dosyayla geri kurulur). Kilitler yeni motor acilmadan hemen once
    birakilir (ayni surecte oz-kilitlenme onlenir). Ek olarak
    `TVdbPageStore` acilistaki dosya kimligini (`VDbFileIdentity`: Windows
    birim seri no + indeks, Unix dev + inode) saklar ve okuma/yazma
    kilitlerinde dogrular; kimlik degistiyse `veritabani dosyasi
    degistirildi ... bu oturum eski dosyaya bagli` hatasi verilir. V2 ve
    dosya bicimi v5 degismedi.
  - **Kapi**: yeni `maint_lock` **13** kontrol (ML1-ML5). ML1 tek surecte
    `VACUUM`; ML2a-ML2e acik yazma islemi varken Compact RED + cocuk commit
    etmesine ragmen 5 satir korunur (cocuk `RESERVE-HELD=TRUE` ile premisi
    kanitlar); ML3a-ML3c acik salt-okunur oturum: ya bakim reddedilir
    (Windows, acik handle rename'i engeller) ya da o oturum fail-closed
    kimlik hatasi alir; ML4/ML4b/ML4c ikinci surecten Compact sonrasi
    satirlar korunur ve `Verify` temiz; ML5 `.tmp` kalintisi yok.
    On-kapi (duzeltme oncesi kurulum: `git archive` HEAD + yalnizca
    `VDbOpenProbeStream` seam'i) Windows **12 PASS / 1 FAIL** (ML2b:
    `mevcut dosya .bak yapilamadi`, "bakim kilidi" metni yok, 15 ms),
    Linux **11 PASS / 2 FAIL** (ML2b: hata bos = Compact basarili = 5 satir
    kaybi; ML3c: bayat COUNT=100).
  - **Durust sinir**: ML2c/ML2e sayimlari on-kapida da **gecer** (kaybolan
    satirlar yeni dosyada gorunmez, sayim ayni kalir); kaybi goren kontrol
    ML2b'dir. **Kilit yarisi** (ayni anda iki `Compact`) ve Windows
    **oz-kilitlenme** senaryosu bu kapida olculmedi. Kimlik dogrulamasinin
    getirdigi ek maliyet olculmedi.
- Kirk sekizinci kosu (v3.64, Sprint J - PG portal `maxRows` ve kaynak
  sinirlari): iki platform da YESIL. Git Bash/Windows **50 kapi** PASS,
  WSL x86_64 Linux **51 kapi** PASS, FAIL 0 (`gatesJ.log` ->
  `KOSAN KAPI: 50`, `SUITE_EXIT=0`; `linJ.log` -> `KOSAN KAPI: 51`,
  `SUITE_EXIT=0`). Windows'ta `tls_client` yine **SKIP** (OpenSSL DLL'i
  yok; SKIP != PASS); Linux'ta kostu: 6/0.
  - **F-40 (KRITIK, KAPALI)**: PostgreSQL genisletilmis protokolunde uc
    ayri kaynak/bellek kusuru vardi. (a) `Execute` govdesindeki
    `Int32 maxRows` alani **hic okunmuyordu**; her `Execute` sonucun
    **tammini** bastan gonderiyor, imlec ve `PortalSuspended` yoktu
    (SKILL5 10.1). (b) `Sync` isleyicisi `Portals.Clear` cagiriyordu;
    gercek istemciler (JDBC `fetchSize`, libpq) her partiden sonra `Sync`
    gonderdigi icin ikinci `Execute` her zaman `portal yok` aliyordu -
    yani `maxRows` uygulansa bile **olu kod** olurdu (olculen:
    `portal yok: po1`). (c) `Stmts`/`Portals` sozlukleri ve
    `TPgPortal.Res` **sinirsizdi**: istemci `Sync` gondermeden binlerce
    portal acip her birine tam sonuc kumesi koyabiliyor, baglanti basina
    sinirsiz bellek tuketebiliyordu (SKILL5 9.5).
  - **Duzeltme**: `TPgPortal.Sent` imleci eklendi; `Execute` `maxRows`
    kadar satir gonderir (0 = sinirsiz, negatif = 0), kalan varsa
    `PortalSuspended` (`'s'`), tukenince `CommandComplete`; sorgu
    **yeniden calistirilmaz**, tukenmis portal 0 satir doner (kopya yok).
    `Sync` artik portallari **dusurmez** (portal `Close`, ayni adla
    yeniden `Bind` veya baglanti sonu bitirir). Bellek korumasi kesin
    sinirlarla: `MaxPrepared` (512), `MaxStmtSqlBytes` (4 MiB),
    `MaxPortals` (256), `MaxPortalResultBytes` (64 MiB), hepsi `0` =
    sinirsiz; asimda kontrollu hata doner ve portal sonucu **derhal
    birakilir** (sunucu sureci OOM ile olmez). Bicim v5 ve V2 degismedi.
  - **Kapi**: yeni `pg_portal_stream` **22** kontrol (PP0-PP12);
    SKILL6 04 ile **35**'e cikti (PS0-PS10 akisli portal/COPY OUT).
    PP1/PP1b/PP1c/PP2/PP2b/PP2c/PP3/PP3b/PP4 `maxRows` imleci (10+10+5,
    imlec korunur, tukenmis portal 0 satir); PP5 `maxRows=0`; PP6a/PP6
    `Sync` sonrasi portal **YASAR**; PP10/PP10b `Describe` satir
    tuketmeden `RowDescription`; PP7/PP8/PP9 kaynak sinirlari. On-kapi
    (`git archive HEAD` + yalnizca alan/property/varsayilan seam'i)
    **6 PASS / 16 FAIL**; ayirt edici 16 kontrol yukaridaki maddelerdir.
    PP0/PP0b/PP0c/PP5/PP11/PP12 bilerek **ayirt edici degildir**.
  - **Durust sinir**: bu, uctan uca (executor duzeyinde) streaming
    **degildir**; sonuc kumesi bellekte tam uretilir ve imlec onun
    uzerinde ilerler - sinir asilirsa istek **reddedilir**. Gercek satir
    yineleyici ve `COPY OUT` streaming hala **ACIK** (SKILL5 10.2).
    `Sync`'in portallari artik dusurmemesi, kapatilmayan portalin baglanti
    sonuna kadar yasadigi anlamina gelir; bu `MaxPortals` +
    `MaxPortalResultBytes` ile sinirlidir.

- Kirk dokuzuncu kosu (v3.65, Sprint K - SERIALIZABLE denetimi, eksik NUL
  sonlandiricisi, MERGE karmasikligi): iki platform da YESIL.
  Git Bash/Windows **53 kapi** PASS, WSL x86_64 Linux **54 kapi** PASS,
  FAIL 0 (`gatesJ.log` -> `KOSAN KAPI: 53`, `SUITE_EXIT=0`; `linJ.log` ->
  `KOSAN KAPI: 54`, `SUITE_EXIT=0`). Windows'ta `tls_client` yine **SKIP**
  (OpenSSL DLL'i yok; SKIP != PASS); Linux'ta kostu: 6/0. Uc yeni kapinin
  hepsi iki platformda ayni sonucu verdi (`serializable_tx` 23/0,
  `pg_msg_nul` 10/0, `merge_hash` 19/0).
  - **F-41 (KRITIK, KAPALI)**: `SET TRANSACTION ISOLATION LEVEL
    SERIALIZABLE` yalnizca **adi** degistiriyordu; commit aninda hicbir
    dogrulama yoktu, davranis REPEATABLE READ ile **birebir ayniydi**
    (VDbAst.pas yorumu bunu zaten kabul ediyordu) ve **write skew**
    mumkundu. Bu sprint onceki uc bulgunun devami olarak ele alindi.
  - **Duzeltme (F-41)**: backend'e `Serializable` bayragi
    (`IVdbBackend`; V3 gercek denetim, **V2 saklar ama yok sayar**),
    `TWriteSet.StartGen` + yeni `StartStoreGen` (`.gen`, baska sureclerin
    commit'lerini de gorur). `CommitBatch`, `VerifyNoConflict` sonrasi ve
    `ApplyBatch` **oncesinde**, araya giren commit varsa
    `ecSerializationFailure` (**SQLSTATE 40001**) firlatir; yazma
    uygulanmadigi icin **veri kaybi yok**. Yeni hata kodu `VDbErr`,
    `vdbapi_core` (`VDB_E_SQL`) ve PG `SQLSTATE` tablosuna eklendi.
  - **Kapi (F-41)**: yeni `serializable_tx` **23** kontrol (S1-S15 API,
    P1-P8 PG teli). On-kapi (`git archive HEAD` + yalnizca
    `ecSerializationFailure` enum/`VDbErrorName` seam'i, davranis yok)
    **15 PASS / 8 FAIL**; ayirt edici: S7/S8/S9/S11 ve P4/P5/P6/P8.
    REPEATABLE READ ayni ara giriste commit etmeye devam eder (S1/S2).
  - **Durust sinir (F-41)**: tam **SSI degildir**; predicate/aralik kilidi
    yok, araya giren herhangi bir commit islemi iptal eder (muhafazakar,
    bedeli gereksiz yeniden deneme).
  - **F-42 (ORTA, KAPALI)**: `VDbPgWire.ReadCStr` eksik NUL
    sonlandiricisini **sessizce yutuyordu**; bozuk `Parse`/`Bind` paketi
    protokol ihlali olarak reddedilmiyor, sonlandiricisiz prepared statement
    adi "prepared statement yok" gibi **yanlis teshis** uretiyor, baslangic
    paketinde eksik NUL kabul ediliyordu. Duzeltme: `ReadCStr(..., out
    AOk: Boolean)`; dokuz cagri yerinin hepsi fail-closed (`ExtFail` ->
    ErrorResponse, `ReadStartup`/SCRAM `Exit`).
  - **Kapi (F-42)**: yeni `pg_msg_nul` **10** kontrol (N0-N8). On-kapi
    (`git archive HEAD`, **seam gerekmedi**) **6 PASS / 4 FAIL**; ayirt
    edici N2 (baseline `1Z` = ParseComplete), N3, N5 (yanlis teshis), N7
    (bozuk baslangic paketi kabul ediliyor).
  - **F-43 (ORTA, KAPALI)**: `ExecMerge` eslesmesi kaba kuvvet
    `O(hedef x kaynak)` idi (olculen baseline: 8000 x 8400 icin
    **130781 ms**, ikinci kosu **142672 ms**). Duzeltme: yalnizca `AND`
    zinciri + `sboEq` + iki tarafi da kolon referansi olan `ON` icin
    kanonik anahtar + sirali hedef + **ikili arama** (`O((H+S)logH)`);
    **her aday satir yine tam `ON` kosuluyla dogrulanir**, semantik
    degismez; karmasik `ON`, `COLLATE` ve metin karsilastirmasinda eski
    dongu aynen calisir.
  - **Kapi (F-43)**: yeni `merge_hash` **19** kontrol (M1-M13); buyuk
    `MERGE` duzeltilmis yapida **62 ms**. On-kapi (`git archive HEAD`,
    **seam gerekmedi**) **18 PASS / 1 FAIL**: **yalnizca M2** (10 s
    siniri) ayirt edicidir; M3-M13 semantik **koruyucu** kontrollerdir ve
    baseline'da da gecer (hizi olcmezler).

- Ellinci kosu (v3.66, Sprint L - SERIALIZABLE seciminin islem/oturum
  kapsami, SKILL6 01): iki platform da YESIL.
  Git Bash/Windows **53 kapi** PASS, WSL x86_64 Linux **54 kapi** PASS,
  FAIL 0 (`gatesJ.log` -> `KOSAN KAPI: 53`, `SUITE_EXIT=0`; `linJ.log` ->
  `KOSAN KAPI: 54`, `SUITE_EXIT=0`). Windows'ta `tls_client` yine **SKIP**
  (OpenSSL DLL'i yok; SKIP != PASS); Linux'ta kostu: 6/0. Yeni kapi dizini
  **eklenmedi**; mevcut `serializable_tx` 23 -> **28** kontrole buyudu.
  - **F-44 (KRITIK, KAPALI; kod etiketi F-45)**: `SERIALIZABLE` secimi
    backend genelinde **tek bir alanda** (`FSerializable`) tutuluyordu ve
    PG sunucusu **tum baglantilari ayni `TVTableDb`'ye** bagladigi icin bir
    baglanti bayragi **butun oturumlar** adina aciyordu. Iki yonlu kusur:
    (a) A READ COMMITTED islem yazmisken B `SET TRANSACTION ...
    SERIALIZABLE` deyince A'nin `COMMIT`'i haksiz `40001` aliyor ve
    **A'nin satiri kayboluyordu** (veri kaybi); (b) gercek SERIALIZABLE
    islem araya giren commit'i gormuyor, **hic reddedilmiyordu** (write
    skew). Ayrica `.gen` okunamazsa `ReadGen` `0` donduruyor ve "arada
    commit yok" **fail-open** varsayimi yapilabiliyordu.
  - **Duzeltme (F-44)**: bayrak artik **islem bazli**:
    `IVdbBackend.SetTxIsolation` (eski `Serializable` property kaldirildi)
    `BEGIN`'den hemen once cagrilir; backend bayragi **oturum kimligine
    gore** (`FPendingSerializable`) saklar; `BeginBatch` bunu yalniz o
    oturumun yeni `TWriteSet.Serializable` alanina kopyalar ve siler;
    `CommitBatch` **yalniz kendi kumesine** bakar. `.gen` icin
    `VDbPageStore.TryReadGen(out AGen): Boolean` eklendi; okunamazsa
    **muhafazakar reddetme** ("degismedi" varsayimi degil). Reddedilen
    commit `ecSerializationFailure` (**40001**) verir ve **hicbir satir
    uygulanmaz**; kilit/rezervasyon birakilir. V2 `SetTxIsolation`'i **yok
    sayar** (V2 donmus), bicim v5 degismedi.
  - **Kapi (F-44)**: `serializable_tx` **28** kontrol (S1-S15 API, P1-P8 PG,
    S16-S20 yeni). On-kapi (`git archive HEAD` = `7b54faa`, **seam
    gerekmedi**) **24 PASS / 4 FAIL**; ayirt edici: S17 (READ COMMITTED
    commit'i haksiz `40001`), S18 (satir kayboldu), S19 (gercek
    SERIALIZABLE reddedilmiyor), S20 (iptal edilen islem yazdi). Onceki
    kosunun ayirt edicileri (S7/S8/S9/S11, P4/P5/P6/P8) da yine FAIL.
  - **Durust sinir (F-44)**: tam **SSI degildir**; predicate/aralik kilidi
    ve okuma kumesi izleme yok, araya giren **herhangi** bir commit islemi
    iptal eder (PostgreSQL'den **daha fazla** iptal uretebilir; veri kaybi
    degil, gereksiz yeniden deneme). Oturum duzeyi
    `SET SESSION CHARACTERISTICS` ve `SERIALIZABLE READ ONLY DEFERRABLE`
    **yok - ACIK**.

- Elli birinci kosu (v3.67, Sprint M - kimlik dogrulama / RBAC baglantisi,
  SKILL6 02):
  - **Windows i386 53 kapi**, **Linux x86_64 54 kapi**, FAIL 0
    (`gatesJ.log` / `linJ.log`, `SUITE_EXIT=0`). `tls_client` Windows'ta
    SKIP (OpenSSL DLL yok), Linux'ta 6/0.
  - Yeni kapi dizini eklenmedi; iki sprint de mevcut kapilari buyuttu
    (`serializable_tx` 23 -> 28, `sql_authorization` 51 -> 62). Kapi
    sayisi Windows 53 / Linux 54 kaldi (AU12 iki platformda 62/0).
  - **F-45 (KRITIK, KAPALI; kod etiketi F-46)**: SCRAM yalnizca kimligi
    dogruluyordu, dogrulanan uzak kullanici **SQL rolune baglanmiyordu**;
    bos rol `RoleCan` icinde **sinirsiz** anlamina geliyordu, `SET ROLE
    NONE` bu yuzden bir **yetki yukselmesiydi**, `SET ROLE` uyeligi
    denetlenmiyordu, oturum kimligi isaretci kirpintisiydi ve
    `TVSql.Destroy` rol kaydini temizlemiyordu (sonraki baglanti miras
    alabiliyordu).
  - **Duzeltme (F-45)**: `BindSessionPrincipal`/`SessionUser`/
    `SessionBaseRole`/`ReleaseSessionState`; principal bagliyken bos rol
    **fail-closed** (reddedilir, RLS uygulanir), `SET ROLE NONE` taban
    role doner, uye olunmayan rol `ecPermissionDenied`; `AddUser` artik
    `ASqlRole` alir, eslenmemis kullanici varsayilan olarak **28000** ile
    reddedilir (`AllowUnmappedUsers` bilincli feragat), `--user
    K:P[:ROL]` ve `--allow-unmapped-users` sunucu anahtarlari; oturum
    kimligi `InterlockedIncrement` ile uretilir ve `Destroy` tum oturum
    yetki durumunu siler. `vdbserver.lpr` ve iki test
    yalnizca kurulum satiri ekledi (kontrol silinmedi).
  - **Kapi (F-45)**: `sql_authorization` **62/0**. On-kapi
    (`git archive HEAD` = `7b54faa` + yalniz API seam'i, davranis HEAD):
    **56 PASS / 6 FAIL**; ayirt edici: AU12 rolsuz principal SELECT,
    AU12 rolsuz principal INSERT, AU12 app roluyle SELECT (onceki izinsiz
    INSERT satiri sayiyi bozdu), AU12 app roluyle INSERT (yetki
    denetlenmedi, dogrudan PK cakismasina gitti), AU12 NONE sonrasi
    yetki yukselmesi, AU12 uye olunmayan role gecis.
  - **Durust sinir (F-45)**: kalici kullanici/rol katalogu **yok**
    (roller bellekte, sunucu sahibi tanimlar); rol uyeligi **duz**
    (rolun role devri / grant edilmesi yok); `AllowUnmappedUsers`
    varsayilan **kapali** ve acikca feragattir; v2 backend degismedi.

- Elli ikinci kosu (v3.68, Sprint N - dosya degistirmede dizin fsync,
  SKILL6 06):
  - **Windows i386 53 kapi**, **Linux x86_64 54 kapi**, FAIL 0
    (`gatesJ.log` / `linJ.log`, `SUITE_EXIT=0`). Windows'ta `tls_client`
    yine **SKIP** (OpenSSL DLL yok; SKIP != PASS), Linux'ta 6/0.
  - Yeni kapi dizini eklenmedi; `maint_lock` 13 -> **19** kontrole buyudu.
    Kapi sayisi Windows 53 / Linux 54 kaldi (`maint_lock` iki platformda
    19/0).
  - **F-46 (YUKSEK, KAPALI; kod etiketi F-47)**: atomik dosya degistirme
    (`SwapDbFileWith` = VACUUM/Compact/Restore/Rekey) eski dosyayi `.bak`a
    rename ediyor, yeni dosyayi yerine koyuyor, eski WAL/`.idx`i siliyor ve
    `.gen` LSN'ini sifirliyordu, ama bu adimlardan sonra **dizin fsync'i
    yoktu**. Guclu kapanma/cokme sonrasi dizin girdisi diske inmeyebilir:
    ne canli dosya ne `.bak` yerinde bulunur ya da **silinen eski WAL geri
    gelip yeni dosyaya uygulanir** (sessiz bozulma).
  - **Duzeltme (F-46)**: her kritik adimdan sonra `VDbFlushDir` - `.bak`
    rename'i sonrasi, yeni dosya yerine konduktan sonra (kaynak dizin farkli
    ise orasi da), eski WAL/`.idx` silindikten sonra, `.gen` LSN
    sifirlandiktan sonra. `VDbFlushDir` **False** donerse islem basarili
    sayilmaz: `SwapDbFileWith` hata verir ve `.bak`tan geri doner; geri
    donus rename'i de fsync edilir ve o da basarisizsa **acik hata** verilir.
    Windows'ta NTFS gunlugu nedeniyle fsync gerekmez (`VDbFlushDir` True).
    Test kancalari `VdbFlushDirHook` / `VdbFlushDirForceFail` uretimde
    `nil` / `False`. V2 ve bicim v5 degismedi.
  - **Kapi (F-46)**: `maint_lock` **19/0** (ML6a/ML6b fsync cagrisi ve
    kapsami, ML7a/ML7b/ML7c zorla fsync hatasinda fail-closed + `.bak`tan
    geri donus + veri korunumu). On-kapi (`git archive HEAD` = `8af4161` +
    yalniz API seam'i: kanca tipi/degiskenleri bildirilir, `VDbFlushDir`
    onlari yok sayar; davranis HEAD) **16 PASS / 3 FAIL**; ayirt edici:
    ML6a (`cagri=0`), ML6b (bos dizin listesi), ML7a (fsync zorla
    basarisizken VACUUM "basarili").
  - **Durust sinir (F-46)**: kapi fsync'in **cagrildigini** ve hata yolunun
    fail-closed oldugunu olcer; gercek **guc kesintisi** bu ortamda
    uretilemez, dolayisiyla "cokme sonrasi kesin kalici" iddiasi yalniz
    POSIX dizin fsync garantisine dayanir. `tests/crash_points` surec
    oldurmeye dayanir ve fsync kaybini **taklit etmez**.
- Elli ucuncu kosu (v3.69, Sprint O - ag mutlak zaman asimi ve sorgu
  iptali, SKILL6 05):
  - **Windows i386 54 kapi**, **Linux x86_64 55 kapi**, FAIL 0
    (`gatesK.log` / `linK.log`, `SUITE_EXIT=0`). Windows'ta `tls_client`
    yine **SKIP** (OpenSSL DLL yok; SKIP != PASS), Linux'ta 6/0.
  - Yeni kapi `pg_cancel` (**31** kontrol) eklendi; `network_limits`
    26 -> **41** kontrole buyudu (NL9-NL12). Kapi sayisi Windows
    53 -> 54 / Linux 54 -> 55. `network_limits` 41/0, `pg_cancel` 31/0
    iki platformda.
  - **F-47 (YUKSEK, KAPALI; kod etiketi F-48)**: iki kusur. (a) Ag
    zaman asimi **her `recv`/`send` cagrisi icin ayri** uygulaniyordu
    (`SO_RCVTIMEO`/`SO_SNDTIMEO`), yani istemci her zaman asimindan once
    kucuk bir parca gondererek toplam mesaj suresini **sinirsiz**
    uzatabiliyordu (her 29 saniyede bir bayt). (b) PostgreSQL
    **CancelRequest (kod 80877102) hic islenmiyordu** ve her baglantiya
    ayni `BackendKeyData(1, 0)` gonderiliyordu (secret 0), yani calisan
    bir sorguyu iptal etmenin yolu yoktu (`ecCancelled`/`ecQueryTimeout`
    SQLSTATE'i de yanlislikla `42000`e dusuyordu).
  - **Duzeltme (F-47)**: `VDbNet`te `VdbRecvAllDl`/`VdbSendAllDl` +
    `VdbWaitSock` (monotonik `GetTickCount64` mutlak son tarih; `select()`
    ile bekleme 1000 ms'lik dilimlere bolunur, kapanis en gec 1 s'de
    gorulur). `TVdbPgIo` `SetDeadlineMs` (her mesaj basinda tazelenir:
    baslik + govde ayni son tarihe tabi; TLS ve SCRAM tek son tarihe
    dahil; COPY-In her `d` parcasinda) ve `SetSendBudgetMs` (her
    `SendAll`da tazelenir, uzun sonuc kumesinde bayat son tarih yok).
    Her baglantiya **benzersiz** `BackendKeyData`: pid
    `InterlockedIncrement` (1000den), secret xorshift32 (global `Random`
    kullanilmaz). `ReadStartup` 80877102'yi tanir (yanit **yok**,
    baglanti kapanir); `HandleCancel` kilit altinda yalniz **pid+secret
    eslesen** baglantinin `TVSql.CancelQuery`sini cagirir, bilinmeyen
    pid zararsiz. `ecCancelled`/`ecQueryTimeout` -> `57014`.
  - **Kapi (F-47)**: `network_limits` **41/0** (NL9 damla: 300 ms
    zaman asimina ragmen her 100 ms'de bir bayt -> 2 s icinde
    dusurulur; NL10 yarim startup; NL11 yavas COPY-In + tablo
    degismedi + gecici dosya yok; NL12 yazma son tarihi) ve `pg_cancel`
    **31/0** (PC0-PC9: benzersiz anahtar, dogru baglanti iptali +
    tek seferlik, yanlis secret reddedilir, A/B adresleme, bozuk/kapali
    baglanti zararsiz, islem atomikligi). On-kapi (`git archive HEAD` =
    `4203135`; `network_limits` icin yalniz API seam'i: `VdbRecvAllDl`/
    `VdbSendAllDl` bildirilir ve `ASonTick`i yok sayarak eski
    fonksiyonlara delege eder, `pg_cancel` seam gerekmedi) **32 PASS /
    9 FAIL** ve **3 PASS / 4 FAIL**; ayirt edici: NL9 damla 4156 ms'de
    hala acik, NL10 2188 ms, NL11 4171 ms, NL12 butcesi bitmis cagri
    `ok=True` ve 1 bayt yazmis; PC0/PC1/PC7 `BackendKeyData` hic
    gelmiyor (secret 0), PC8 atomiklik olculemiyor.
  - **Durust sinir (F-47)**: (a) Windows loopback'ta **engellenen**
    yazma deterministik uretilemiyor (olculdu: `RCVBUF=4096` iken 16 MiB
    16 ms'de tamponlara kabul edildi), bu yuzden NL12 "engellenirken son
    tarih"i degil son tarihin **kendisini** olcer; tek bir `fpSend`
    kendi OS tavanini (`SO_SNDTIMEO`) asabildigi icin ust sinir 2 s'dir.
    (b) TLS'te `select()` kullanilamaz: son tarih her parca oncesi
    denetlenir, tek bir `SSL_read`in ust siniri yine `SO_RCVTIMEO`dur.
    (c) Iptal **isbirlikci** noktalarda etkilidir (`TickAbort` her 1024
    satirda bir `CheckAbort`); bloklayan tek bir disk G/C'sini veya
    derin tek bir fonksiyon cagrisini kesmez.
- Elli dorduncu kosu (v3.70, Sprint P - UPDATE ... FROM hash join,
  SKILL6 07): **Windows i386 54 kapi**, **Linux x86_64 55 kapi**, FAIL 0,
  `SUITE_EXIT=0` (`gatesL.log` / `linL.log`). Kapi **sayisi degismedi**;
  `tests/merge_hash` 19 -> **30** kontrole buyudu (U1-U9).
  - **Kusur (F-48)**: `UPDATE ... FROM` esitlik birlestirmesi kaba kuvvet
    **O(hedef x kaynak)** idi (`ExecUpdate`: `for i ... for fi ...
    RowMatches`, ilk eslesende durur). 4000 x 2500 satirda ~6.9 milyon tam
    WHERE degerlendirmesi: **olculen 13063 ms**.
  - **Duzeltme**: WHERE icindeki **guvenli** esitliklerden hash anahtari
    (`UfCollectEq` yalniz `sboEq` + iki tarafi da kolon referansi +
    `VCT_STR` + iki tarafta bos collation), FNV-1a anahtar, kaynak tarafi
    azalan sirada basa eklenir (ilk eslesen kaynak satiri kazanir),
    NULL anahtar atlanir, her aday icin tam WHERE yeniden degerlendirilir,
    uygun conjunct yoksa eski yol aynen calisir. Ayni yuk: **16 ms**.
  - **Kapi (F-48)**: `merge_hash` **30 PASS / 0 FAIL**; U3 sure siniri
    (4 s) ayirt edici, U1/U2/U4-U9 semantik koruyucu (satir sayilari,
    ilk-eslesen-kazanir, NULL, sayisal denklik fallback, esitlik-disi
    fallback, coklu kolon, alt sorgu kaynagi).
  - **On-kapi**: `git archive HEAD` = `ab103aa`, **seam gerekmedi** ->
    **29 PASS / 1 FAIL**; tek ayirt edici **U3** `sure=13063ms`.
  - **Durust sinir (F-48)**: bir maliyet modeli degil; cardinality,
    distinct/NULL orani, hash bellek tahmini ve spill-to-disk karari hala
    yok. `UPDATE ... FROM` icinde JOIN kaynagi parser tarafindan reddedilir
    (`ecUnsupported`).

- Elli besinci kosu (v3.72, Sprint Q - NULL/bos metin ayrimi uctan uca,
  SKILL6 03 asama 2b + 2c): **Windows i386 55 kapi**, **Linux x86_64 56
  kapi**, FAIL 0, `SUITE_EXIT=0` (`gatesN.log` / `linN.log`). Windows'ta
  `fixtures_openssl`, `selftest_openssl` ve `tls_client` SKIP
  (`VDB_CRYPTO_DLL` yok), Linux'ta `tls_client` 6/0 kosar; ilk ikisi iki
  platformda da SKIP (harici OpenSSL fixture'i yok) ve SKIP PASS sayilmaz.
  - **Kapi** `tests/null_empty` **41 PASS / 0 FAIL** (NE1-NE51). Kapi sayisi
    degismedi (Windows 55, Linux 56); kontrol sayisi 14 -> 41 buyudu.
  - **Asama 2b (okuma maskesi)**: `ReadRowEx`/`ScanRowsEx`/`ScanRowsPartEx`
    -> `allNulls` -> filtre/RLS/join -> projeksiyon (`FNarrowNulls`,
    `FAggNulls`) -> `TSqlResult.RowNulls`. `COUNT(kolon)`, `UNIQUE`,
    `GROUP BY`/`DISTINCT`, `ORDER BY ... NULLS FIRST/LAST` ve `IS NULL`
    depolanmis degeri artik maskeden okur.
  - **Asama 2c (yazma maskesi)**: `TTableDef.HasNulls` + sema satiri
    `#N|<tablo>` NULL tasiyan tabloyu indeks/covered-index/stream/COPY hizli
    yollarindan genel satir yoluna yonlendirir. `InsertEx`,
    `InsertReturning`, `UpdateRowInPlace`, `PutRow`, `UpdateWhere`,
    `UpsertRowReturning`, FK cascade ve `RewriteTable`/`RewriteTableRows`
    maskeyi tasir. Parametre maskesi `ParseEx` + `TVSql.Exec(Sql, Params,
    ParamNulls)` ile SQL katmanindan gecer (tek atimlik `FPendParamNulls`,
    plan onbellegi yeniden baglanir). PG wire NULL'i `-1` yazar
    (`DataRowMsgFmt(..., Nulls)`, `PgRowNulls`, Bind `plen = -1`).
  - **Bu kosuda kapanan iki gercek kusur**: (i) hizli INSERT seritleri maske
    tasimadigi icin NULL literalini `''` yazip `HasNulls`i hic isaretlemiyordu;
    sonrasinda her `''` NULL saklaniyordu = **veri kaybi**. Serit artik NULL
    literal/parametrede genel yola birakir (`ExecFastLiteralInsert` icinde
    `ReadValue` NULL bildirir; parametreli seritler `VDbNullsAny` ile
    atlanir). (ii) `ALTER TABLE ADD COLUMN` icinde `RewriteTable`
    `oldNulls` dizisini boyutlandirmiyordu (`EAccessViolation`; `sql_matrix`
    D6); `SetLength(oldNulls, Length(keys))` eklendi.
  - **On-kapi**: `git archive HEAD` = `a30676e` -> **30 PASS / 11 FAIL**
    (`NE24`, `NE28`, `NE31`, `NE34` ve depolama bloklari); ayirt edici.
  - **Durust sinir (F-49)**: `COPY TO` text/Arrow/Parquet disa aktarimi
    NULL'i hala `''` yazar (bicimde ayrim yok); covered-index hizli yolu ve
    projeksiyon oncesi `ORDER BY` siralamasi maskeyi tasimaz; `ExecGroupBy`
    `Res.RowNulls`i doldurmaz; 2c oncesi yazilmis satirlar `HasNulls`
    isaretlenene kadar eski kurala (`''` = NULL) tabidir. Bunlar
    gosterim/okuma kapsamidir, veri kaybi degildir.
    `format_compat` 28/0: dosya bicimi (v5) bit bazi degismedi.

- Elli altinci kosu (v3.73, SKILL6 08 - dis sistem uyumlulugu: Arrow/Parquet
  interop, bagimsiz kripto dogrulamasi, SQLite karsilastirmasi): **Linux
  x86_64 60 PASS**, **Windows i386 59 PASS**, FAIL 0, `SUITE_EXIT=0`
  (`gatesP.log` / `linP.log`). Iki platformda da `fixtures_openssl`,
  `selftest_openssl` SKIP (`VDB_CRYPTO_DLL` yok) ve `interop_external`
  SKIP (pyarrow yok); Windows'ta `tls_client` de SKIP, Linux'ta
  `tls_client` 6/0 kosar. SKIP PASS sayilmaz ve kosan kapi sayisina
  eklenmez (`KOSAN KAPI: 59` Windows, `60` Linux).
  - **Yeni kapilar (5)**: `interop_format` 21/0, `interop_external` 8/0,
    `crypto_interop` 33/0, `crypto_interop_ext` 25/0, `bench_sqlite` 24/0.
    `interop_external` suite kosusunda SKIP oldugu icin ayrica
    `VDB_PY_LIBS` (depo disi pyarrow dizini) verilerek kosturuldu - 8/0.
    Kosan kapi sayisi Windows 55 -> **59**, Linux 56 -> **60** (Linux'ta
    `interop_external` SKIP).
  - **Bulunan ve kapatilan gercek kusur (F-51)**: Arrow semasinda
    `Date.unit`/`Time.unit` varsayilani MILLISECOND'dir, bu yuzden pyarrow
    `date64[ms]`/`time32[ms]` icin `unit` alanini **hic yazmaz**; okuyucu
    varsayilani SECOND/DAY sanip degeri 1000 kat kaydiriyordu
    (`00:00:00`, `0000-00-00`, `1971-02-17`). `VDbArrow.pas`
    `ArrowParseType` Date/Time icin varsayilan **1** kullanir. VDB'nin
    kendi yazdigi dosyalar etkilenmez (`MakeTypeTable` `unit=0` alanini
    acikca yazar); `format_compat` 28/0 ve `interop_format` 21/0 degismedi.
  - **On-kapi**: `git archive HEAD` = `16b0b09`, degisen tek uretim dosyasi
    `VDbArrow.pas` icin HEAD kopyasi birim yolunda **one** alinarak
    derlendi. `interop_format` 21/0, `crypto_interop` 33/0,
    `crypto_interop_ext` 25/0, `bench_sqlite` 24/0 -> **koruyucu**;
    `interop_external` **6 PASS / 2 FAIL** -> **ayirt edici X4 ve X8**.
    Yani bos yesil degildir: bir ayirt edici kapi, kusurun duzeltilmedigi
    kaynakta gercekten duser.
  - **Durust sinir (SKILL6 08)**: (a) iki bicimde de DECIMAL yoktur ve VDB
    Parquet yazarken yalniz UNCOMPRESSED uretir (SNAPPY yalniz okunur,
    saf Pascal uygulamasidir); (b) `TStrMatrix` NULL maskesi tasimadigi
    icin disa aktarimda NULL ve `''` ayni gorunur (X7 bunu **belgeler**,
    gecmez demez); (c) pyarrow, Python `hashlib`/`hmac`/`sqlite3` yalniz
    depo **disindan** kullanilir - depo bagimliligi veya harici DLL
    eklenmedi; araclar yoksa ilgili kapi **77 (SKIP)** doner ve PASS
    sayilmaz; (d) `bench_sqlite` hiz **ustunlugu iddia etmez**, yalniz ayni
    isin ayni sonucu verdigini ve olculen sureleri yazar; (e) gercek
    PostgreSQL istemcileri (`psql`, JDBC, Npgsql) bu ortamda **yoktur**,
    bu yuzden istemci matrisi kosmadi - `server_version = 14.0` bir
    **uyumluluk sertifikasi degil**, yalniz bildirilen degerdir.

- Elli yedinci kosu (v3.74, SKILL09 + SKILL10 - NULL operator semantigi,
  sunucu durdurma ve TLS mutlak son tarihi): **Linux x86_64 60 PASS**,
  **Windows i386 59 PASS**, FAIL 0, `SUITE_EXIT=0` (`gatesQ.log` /
  `linQ.log`). SKIP'ler: iki platformda `fixtures_openssl`,
  `selftest_openssl`, `interop_external`; Windows'ta ayrica `tls_client`.
  SKIP PASS sayilmaz ve kosan kapi sayisina eklenmez (Windows 59, Linux
  60; Linux'ta `tls_client` kosar). `interop_external` ayni makinede
  `VDB_PY_LIBS` (depo disi pyarrow 26.0.1 dizini) verilerek ayrica
  kosturuldu: **8 PASS / 0 FAIL** (Windows); Linux'ta SKIP, cunku o
  dizin bir Windows tekerlegi ve WSL python3'te pip yok.
  - **SKILL09 (`0c00225`, Sprint T, F-53)**: `VDbExecutor.pas` +356/-91.
    `IN`/`NOT IN`, `IN` alt sorgusu, `ANY`/`ALL` ve `BETWEEN` icin NULL
    semantigi tamamlandi: sol islenen NULL -> **UNKNOWN**, `''` gercek
    deger, liste/alt sorguda NULL -> eslesme yoksa **UNKNOWN** (hem `IN`
    hem `NOT IN`), `ANY` bos kume False, `ALL` bos kume True.
    `null_empty` 41 -> **126 PASS / 0 FAIL** (NE52-NE136, 85 yeni
    kontrol). On-kapi `git archive 2ccbecb`: **85 PASS / 41 FAIL** -
    ayirt edici. Bicim v5 ve V2 degismedi (`format_compat` 28/0).
  - **SKILL10 (Sprint U, F-54)**: `VDbNet.pas` +133, `VDbPgWire.pas`
    +211, `VDbTls.pas` +86, `tests/network_limits/network_limits.lpr`
    +932, `tests/bench_sqlite/bench_sqlite.lpr` +33. `Stop` 29703 ms ->
    **312 ms** (ayni NL7 tekrari, ayni makine, 5 s sinirinin altinda);
    yeni kabul once durur, baglantilar uyandirilip beklenir, motor ancak
    butun baglanti is parcaciklari bittikten sonra kapanir; dinleme
    soketi non-blocking + `VdbTcpAcceptNb`; TLS el sikismasi ve
    `SSL_read`/`SSL_write` 500 ms dilimli mutlak son tarih (`-2`);
    CancelRequest siriti `VDbCryptRandom` CSPRNG, RNG basarisizsa
    `SQLSTATE 28000` (fail-closed). `network_limits` Windows'ta
    **97 PASS / 0 FAIL / 4 SKIP** (NL13-NL24 eklendi; SKIP:
    NL15/NL22/NL23 TLS - bu makinede OpenSSL yok), Linux'ta
    **110 PASS / 0 FAIL / 0 SKIP** (TLS kontrolleri dahil hepsi kosar).
  - **Durust sinir (SKILL10)**: TLS son tarihi tek bir `SSL_read` /
    `SSL_write` cagrisini kesemez, ust sinir `SO_RCVTIMEO` /
    `SO_SNDTIMEO`'dur. TLS kontrolleri Windows'ta OpenSSL olmadigi icin
    SKIP'tir ve PASS sayilmaz; ayni kontroller Linux kosusunda
    (`network_limits` 110/0, 0 SKIP) gercekten kosmustur.

- Elli sekizinci kosu (v3.75, SKILL12 - kalici disk indeksi): **Linux
  x86_64 63 PASS**, **Windows i386 62 PASS**, FAIL 0, `SUITE_EXIT=0`
  (`gatesR.log` Windows, `linQ.log` Linux). Uc yeni kapi (65 derleme,
  hepsi `BUILD OK`): `disk_index_integration` **49/0**,
  `disk_index_crash` **56/0**, `disk_index_scale` **17/0** (CI'da 200k
  satir; 1M ayrica kosuldu). SKIP'ler degismedi ve PASS sayilmaz:
  iki platformda `fixtures_openssl`, `selftest_openssl`,
  `interop_external` (pyarrow yok), Windows'ta ayrica `tls_client`.
  Kosan kapi sayisi 59/60 -> **62/63**.
  - **Yeni kapilar (3)**: `VDbDiskIdx.pas` (saf Pascal, degisken
    uzunluklu hucre, 4096 bayt sayfa, sayfa CRC, COW yazim, cift meta,
    enjekte karsilastirici) v5 motoruna entegre edildi; damga tablo
    basina durabil commit sayacidir (yeni `IVDbBackend.StoreScopeStamp`
    -> `ReadGenScope(TableId)`). `.dix` yan dosyasi varken `.gen`
    kapanista silinmez; `.dix` yoksa tek-dosya davranisi aynen korunur
    (`format_compat` 28/0, bicim v5 degismedi).
  - **On-kapi (ayirt edicilik)**: `git archive HEAD` = `e911ee8`
    agacinda uc kapi da **derlenmez** - `dji` icin 22 x
    `Error: (5038) identifier idents no member "DiskIdxHits"/"DiskIdxBuilds"`,
    `dixcrash`/`dixscale` icin `Fatal: (10022) Can't find unit
    VDbDiskIdx`. Ozellik HEAD'de **yoktur**; bu bir davranis farki
    degil, yokluktur. Kapilar yalniz yeni uygulamaya karsi gecebilir.
  - **Cokme kapisi (gercek surec olumu)**: 7 noktada cocuk surec
    oldurulur (`precommit`, `heap`, `prepage`, `midpages`, `postpage`,
    `premeta`, `postmeta`). Cikis degeri platforma baglidir: Windows
    `TerminateProcess(9)` -> `rc=9`; Unix `fpKill(SIGKILL)` -> FPC
    `TProcess` **negatif** sinyal numarasi verir, `rc=-9`. Ilk Linux
    kosusunda kapi yalniz `9` bekledigi icin 7 `/olduruldu` kontrolu
    FAIL verdi (49/7); kapi platforma gore beklenen degeri ayirt edecek
    sekilde duzeltildi ve Linux `Halt(9)` yedegini **kabul etmez** -
    yani zayiflatilmadi, sikilastirildi. Sonuc iki platformda 56/0.
  - **Durust sinir (SKILL12)**: (a) 1M satir olculdu, **10M
    basarisizdir** - 32-bit ikilide `CREATE INDEX` once tum indeksi
    bellekte `TIdxEntries` olarak maddelestirdigi icin `EOutOfMemory`
    alinir (ekleme dongusu tamamlanir, indeks kurulumu coker); 10M icin
    akisli/toplu indeks insasi gerekir ve **yapilmadi** - bu bir olcum
    siniridir, PASS degildir; (b) hucre sayfaya sigmiyorsa (cok uzun
    TEXT anahtar/deger) indeks diskte tutulmaz, bellek yolunda kalir;
    (c) `disk_index_scale` icindeki `heap_delta` yalniz **BILGI**'dir
    (`TotalAllocated` deltasi RSS degildir), bellek iddiasi PASS/FAIL
    uretmez - kanit S18 yapisal olcumudur (tek `Find` icin <= 8 sayfa;
    1M'de 3 sayfa / 5886 sayfa / yukseklik 3).

- Elli dokuzuncu kosu (v3.76, SKILL11 - genel akis / dis siralama):
  **Linux x86_64 65 PASS**, **Windows i386 64 PASS**, FAIL 0,
  `SUITE_EXIT=0`. Iki yeni kapi: `spill_core` **29/0**,
  `stream_spill` **31/0**. Kosan kapi sayisi 62/63 -> **64/65**.
  SKIP'ler degismedi ve PASS sayilmaz: iki platformda
  `fixtures_openssl`, `selftest_openssl`, `interop_external` (pyarrow
  yok), Windows'ta ayrica `tls_client`.
  - **Yeni birim (1)**: `VDbSpill.pas` (saf Pascal, harici DLL/arac
    yok): kosu dosyasi bicimi (`VDBSPL1`, alan sayisi + NULL maskesi,
    uzunluk onekli kayit), `TVdbSpillWriter`/`Reader`, k-yonlu
    `TVdbSpillMerger`, kararli siralama, gecici dizin + manifest
    (`DB`/`PID`/`VER`/`RUN`), artik (orphan) toplama, bayt muhasebesi.
    Kosu dosyalari `vdbspill_<hash>_<pid>_<sayac>/` altinda `.vspill`
    uzantisiyla durur ve **kalici indekslerle (`vdbidx_*.dix`)
    karistirilmaz**; kapanista/iptal/hata yolunda tek cagriyla silinir.
  - **Dis siralama**: `ORDER BY` indeksten gelmiyorsa sonuc artik tek
    seferde maddeselestirilmiyor; imlec, siralamayi **AYNI**
    `BuildSortCols` + **AYNI** `VdbSortCompareRows` ile parca parca
    yapip kosu dosyalarina yaziyor, tarama bitince birlestiriyor
    (tepe bellek satir sayisindan bagimsiz; sirasi bit bit ayni).
    `OFFSET`/`LIMIT` birlestirme ciktisina imlec duzeyinde uygulanir.
    Ayni turda `TVdbRowCursor`'in `LIMIT`/`OFFSET`'i akisli yolda
    **yok saydigi** eski hata da duzeltildi (SKILL6 iddiasinin aksine
    imlec bu sinirlari uygulamiyordu); artik uygular ve maddesel dal
    cift uygulamayi onlemek icin kendi `FSkip`/`FLimit`'ini sifirlar.
  - **Gercek bellek muhasebesi**: `TVdbRowCursor.LiveBytes` artik
    yalniz hucre metnini degil dizi kapasitesini/isaretcilerini,
    string heap'ini, siralama kayitlarini, teslim tamponunu, kosu
    parcasini, NULL maskesini ve birlestirici pencerelerini sayar
    (`VdbSpillRowBytes`/`MatrixBytes` tek kaynak). `PeakBytes` yasam
    boyu tepeyi verir; portal butcesi (`MaxPortalResultBytes`, 64 MiB)
    ayni sayaci kullanir.
  - **Tuketilmis portal tamponu (olculen Linux regresyonu)**: gercek
    muhasebe, ayni anda acik 12 portalda (her biri son satir tamponunu
    tutuyordu) `pg_portal_stream` PS7a'yi Linux x86_64'te kirdi:
    `total=122635 > 120000` (Windows i386 4 bayt isaretci sayesinde
    geciyordu). Kesin cozum butceyi gevsetmek degil **tamponu
    birakmak** oldu: `TVdbRowCursor.ReleaseBuffers` akis bitince teslim
    tamponunu, maddesel yedegi ve dis siralama kaynaklarini birakir;
    imlec NESNESI yasar (portal `Describe` onu bulur, sorguyu yeniden
    calistirmaz) ve tukenmis kalir. `PullPortalChunk` tukenme dalinda
    bunu cagirir. Ayni kosuda `total=106441`'e indi (esik
    degistirilmedi), PS7b/PS7c hala kontrollu RED. SS13 bunu kalici
    olarak olcer.
  - **On-kapi (ayirt edicilik)**: `git archive HEAD` = `ee5be42`
    agacinda `stream_spill` **derlenmez** - 15 x
    `Error: (5038) identifier idents no member
    "FExtSort"/"FSpillRuns"/"FSpillBytes"/"PeakBytes"`. Ozellik
    HEAD'de **yoktur**; kapi yalniz yeni uygulamaya karsi gecebilir.
  - **Durust sinir (SKILL11)**: dis siralama yalnizca **duz kolon adi**
    ile yazilmis `ORDER BY` anahtarlari icin devrededir. Ifade
    anahtarlari, projeksiyonda olmayan (gizli) anahtarlar, `JOIN`,
    `GROUP BY`, `DISTINCT`, `UNION`, pencere, alt sorgu ve **NULL
    tasiyan tablolar** maddesel yolda kalir; iki yol asla karistirilmaz
    (SS12 bunu dogrular). NULL tablolar bilincli olarak disaridadir:
    kosu dosyasi NULL maskesi tasimadigi icin birlestirme karsilastirmasi
    maskesiz satirlari gorur ve NULL sirasi maddesel yoldan sapabilirdi.
    Hash partitioning / hash join / GROUP BY spill'i **yapilmadi**;
    bu operatorler icin bellek garantisi verilmez. Gecici dizin
    kurulamazsa sorgu dusmez, eski maddesel yol calisir (sonuc ayni,
    bellek garantisi kaybolur).
  - **Olcum (Windows i386)**: `stream_spill` yaklasik 50 sn; 1M satir
    yazimi ~10 sn, 1M satir ORDER BY ~34 sn, 35 kosu, tepe ~2,7 MB.
    `spill_core` < 1 sn.

- Altmisinci kosu (v3.77, SKILL13 - tipli disa aktarim + NULL korunumu +
  parti bazli akis): **Linux x86_64 65 PASS** (varsayilan) ve **66 PASS**
  (depo disi pyarrow ile), **Windows i386 65 PASS**, FAIL 0,
  `SUITE_EXIT=0`. Kosan kapi sayisi degismedi (yeni kapi ikilisi
  eklenmedi); `interop_format` **27/0**, `interop_external` **21/0**
  oldu. SKIP'ler PASS sayilmaz: iki platformda `fixtures_openssl`,
  `selftest_openssl`; Linux'ta (pyarrow yoksa) `interop_external`,
  Windows'ta `tls_client`.
  - **Sorun**: `TStrMatrix` NULL maskesi tasimadigi icin her iki bicimde
    de disa aktarimda `''` ile NULL **ayni** yaziliyordu (Arrow
    gecerlilik biti yalniz hucre metni bos degilse 1; Parquet tanim
    seviyesi yalniz `Rows[i][j] <> ''` iken 1). Okuma tarafinda tip de
    kayboluyordu: tam sayi/ondalik metne cevriliyor, NULL bos metne
    donuyordu; "alan yok" ile "alan var ama bos" ayirt edilemiyordu.
    Ayrica tum dosya tek `RecordBatch` / tek row group oldugu icin
    parti parti yazma/okuma yolu yoktu.
  - **Tipli API (yeni, eskiyi bozmaz)**: `VDbArrowExportCells`,
    `VDbArrowImportCells`, `VDbArrowReadBatches`, `TVdbArrowWriter`;
    `VDbParquetExportCells`, `VDbParquetImportCells`,
    `VDbParquetReadBatches`, `TVdbParquetWriter`. Hepsi
    `TVdbCellMatrix` (`VDbTypes.pas`'ta **zaten vardi**, yeniden
    kullanildi) ile calisir.
  - **Tekil cekirdek**: eski `TStrMatrix` API'leri **kaynak ve davranis
    uyumlu** kalir; matrisi `LegacyCellOf` / `RowsToParquetCells` ile
    hucreye cevirip **ayni** yazma cekirdegine (`ExportBodyCells` /
    `BuildPageCells`) verir. Okuma da tek cekirdekten gecer
    (`ArrowDecodeCells` / `DecodeColumn(..., out Cells)`) ve eski metin
    API'si hucreleri metne cevirir. Boylece iki yol asla ayrisamaz.
  - **Anlam**: gecerlilik `Kind <> vckNull`'dir; yani `vckText`/
    `vckBlob` + `S=''` **gecerli bos degerdir** ve Parquet'te tanim
    seviyesi 1 olur. Arrow'da kolon basina gecerlilik bitmap'i, Parquet'te
    dogru tanim seviyeleri yazilir; `vckNull` tanim seviyesi 0.
  - **Parti akisi**: Arrow yazici semayi bir kez yazip her `WriteBatch`
    icin bir `RecordBatch` ekler, okuyucu her partiyi geri cagiriya verir.
    Parquet yazici her partiyi **bir row group** yapar; okuyucu her grup
    icin yalniz o grubun kolon parcasini okur (dosyanin tamami degil).
    Iki yonde de tepe bellek dosya boyuyla sinirsiz buyumez.
  - **Kapi kaniti**: `interop_format` F17-F22 (tipli gidis-donus, eski
    metin API sinirinin korunmasi, 3 partili yazici, 1 MB metin +
    512 KB ikili) ve `interop_external` Y1-Y13 (pyarrow `checkcells`
    NULL sayilari + "bos NULL degildir", pyarrow'un NULL/bos karisik
    dosyasi, 40 batch ve 50 row group dosyalari). On-kapi
    (`git archive HEAD` = `bfb6020`): iki kapi da **derlenmez** - 26 ve
    29 x `Error`; 8 yeni simgenin hepsi `Identifier not found`.
  - **Kapi ILK KEZ Linux'ta kostu ve uc test-hatasi ortaya cikti**
    (motor hatasi degil): (a) `RunPy` python argumanlarini tek bir
    dizgede gomuyordu; Windows'ta FPC komut satirini kendisi kurdugu
    icin calisiyordu, Linux'ta `execv` dizgeyi oldugu gibi gectigi icin
    `verify.py` "bilinmeyen mod" dedi - argumanlar artik ayri eleman
    olarak gecilir (`RunPyArgs`). (b) X7 ayrintisi basarisiz import
    sonrasi `GOut[4][2]`'ye kosulsuz erisip erisim ihlaliyle (exit 217)
    dusuyordu; artik sinir denetimli `CellText` kullanilir. (c) Saat
    beklentileri `0,5 + i/86400` kayan nokta toplamindan kuruluyordu;
    x86_64'te `12:00:00.999...` cikip saniye asagi yuvarlandigi icin
    kapi **kendi urettigi veriyi** yanlis bekliyordu (`interop_external`
    X4/X5/X6/X8, `interop_format` F15a/b/c). Beklentiler artik tam
    sayidan kurulur. Bu ucul da kapiyi zayiflatmadan duzeltildi.
  - **Durust sinir**: iki bicimde de DECIMAL yoktur (SKILL14 sonrasi);
    VDB Parquet yazarken yalniz UNCOMPRESSED uretir (SNAPPY yalniz
    okunur); tipli okumada Arrow DATE/TIME/DATETIME hucreleri `vckText`
    ISO metni, Parquet sozluk (dictionary) kodlanmis FLOAT degerleri
    metin uzerinden gelir. Parti okuyuculari geri cagirinin ne kadar
    tuttugunu **sinirlamaz**; bellek tavanini cagiran taraf secer.
    pyarrow depo disidir (Windows 26.0.1, WSL 20.0.0 tekerlekten
    `PYTHONPATH` ile) ve yoksa kapi **77 (SKIP)** doner, PASS sayilmaz.

