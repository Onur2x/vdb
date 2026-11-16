# Degisim gunlugu

Surum numarasi `vdbapi.lpr`/`vdbapi.h` icindeki `VdbApiVersion` ile
birlikte ilerler. Bu dosya yalnizca **kayda deger** degisiklikleri tutar;
commit gecmisi ayrintili kayittir.

## Yayinlanmamis (v3 sertlestirme, 2026-11)

Hedef: harici DLL'siz, saf Pascal bir veritabani oldugu sozlesmesini
korumak; iddialari **kanitlanabilir** hale getirmek. Bu seri "production
ready" iddiasi tasimaz (bkz. `SECURITY.md`, `docs/security/THREAT_MODEL.md`).

### Guvenlik

- **Kripto provider sozlesmesi** (ADR K1): varsayilan `builtin` (saf
  Pascal) provider. OpenSSL yalnizca acikca secilirse kullanilir; sessiz
  fallback yok. DCPcrypt tamamen kaldirildi; yerine `VDbCryptoCore.pas`
  (AES-256-CTR/GCM cekirdegi, SHA-256, HMAC) geldi. AES/SHA cekirdeginin
  kokeni MIT lisansli referans uygulamadir (bkz. `NOTICE`, `p7-sbom`).
- **Sunucu sertlestirme**: dinleme adresi cozumleme fail-closed
  (`VdbResolveListenHost`); `--trust` modunda loopback disi adres
  **reddedilir**; PG wire'da SCRAM-SHA-256, `RequireTls`, giris hiz siniri
  ve kilit (`AuthMaxFailures=5`, `AuthFailureWindowSeconds=60`,
  `AuthLockoutSeconds=30`, `AuthGlobalMaxFailures=200`); bilinmeyen
  kullanici ile yanlis parola ayni hatayi verir.
- **Desteklenmeyen yollar sessiz yanlis sonuc uretmez**: uygulanmamis SQL
  yuzeyi `ecUnsupported` ile reddedilir (`docs/engineering/SQL_STUB_SURFACE.md`).

### Dayaniklilik

- **WAL kurtarma denetimi** ve `wal_crash` matrisi; WAL dosyasi hicbir
  yerde silinmez, checkpoint basligi yeniden yazar.
- **Yedek/geri yukleme**: `RestoreFrom` yazmadan once tam sayfa dogrulamasi
  yapar; `Verify`/`VerifyBackup` yalnizca reddeder, onarmaz. Iki gercek hata
  kapatildi (freelist trunk yanlis pozitifi; bozuk yedek uzerine sessiz
  yazma) — `docs/engineering/BACKUP_RESTORE.md`.
- **Sayfa/indeks butunlugu** kapisi `page_integrity` (I0-I13).
- **Coklu surec kapisi** `multiproc` (17 kontrol, iki gercek isletim sistemi
  sureci): es zamanli yazar + bayat onbellek tazeleme, `SIGKILL` /
  `TerminateProcess` sonrasi onayli commit'lerin korunmasi ve kilidin kalici
  bloklamamasi, `VERIFY` temizligi, salt-okunur oturumun yazmayi reddetmesi.
  Belgelendi: yazma kilidi **islem basina** alinir, oturum boyu tutulmaz, bu
  yuzden iki yazar oturumu ayni anda acilabilir — `STORAGE_AUDIT.md` §21.3.
- **Duzeltildi:** salt-okunur acilis `.gen` yoksa onu **yaratiyordu** ve RO
  kapanis silmedigi icin tek dosyali bir veritabani salt-okunur acildiginda
  dizinde ikinci dosya kaliyordu. Artik RO oturum `.gen` olusturmaz, dosyaya
  yazmaz; yalniz degisiklik sayacini okur.
- **Deterministik cokme noktalari** kapisi `crash_points` (24 kontrol):
  `VDbPageEngine`'e `VDB_CRASH_STAGE_*` + `CrashAtStage` / `OnCrashPoint`
  eklendi; checkpoint basi, sayfa yazimi oncesi/sonrasi, WAL budama sonrasi,
  checkpoint sonu, commit kaydinin fsync oncesi/sonrasi noktalarinda surec
  **gercekten** oldurulur (`SIGKILL`/`TerminateProcess`). Her noktadan sonra
  yeniden acilis + `VERIFY` + onayli commit kontrolu yapilir. Enjeksiyon
  uretimde kapalidir (`0`) ve kanca yoksa acik hata verir.
- **Butunluk denetleyici** `vdbcheck` (yeni arac) + `integrity_check`
  kapisi (32 kontrol): `VerifyEx(AMode, ADryRun, Report)` dort mod sunar
  (`quick`, `full`, `index`, `wal`); eski `Verify` geriye uyum icin tam
  denetim yapar. `ADryRun=True` acik commit checkpoint'ini atlar, bu yuzden
  denetim **veritabanini degistirmez**; arac dosyayi her zaman salt-okunur
  acar ve cikis kodu verir (0 temiz / 1 kullanim / 2 bozulma). WAL kuyrugu
  uygulanmadan incelenir (`FWal.Inspect`), kesik kuyruk **uyari** sayilir.
  Kapi; bozuk sihirli sayi, bozuk CRC, bozuk freelist girdisi, kesik WAL
  kuyrugu ve kesik dosyayi ayri ayri dener ve her senaryoda dosyanin
  FNV-1a ozeti + boyutunun degismedigini dogrular.
- **Onbellek metrikleri** `cache_metrics` kapisi (21 kontrol):
  `TVDbStoreStats` kirli cerceve sayisini (`DirtyPages`) ve flush
  sayaci/sayfa sayisi/suresini tasir; `IVDbBackend.GetCacheStats`
  (`TVdbCacheStats`; v2 `Supported=False`) motordan bagimsiz yayin yapar.
  Ayni degerler Prometheus ciktisinda (`page_cache_hit_ratio`,
  `page_cache_dirty_pages`, `page_flushes_total`, `page_flush_pages_total`,
  `page_flush_last_ms`, `page_flush_duration_ms_total`) ve `SHOW STATS`
  satirlarinda (`cache_hits`, `cache_hit_ratio`, `cache_dirty_pages`,
  `page_flushes`, ...) gorunur. Kapi metriklerin gercekten hareket
  ettigini olcer; sabit/sahte deger kapiyi kirar.
- **Format uyumlulugu** `format_compat` kapisi (28 kontrol): v5 dosyasi
  acilir; baslik surumu 3/4 yapilip CRC'si yeniden hesaplanmis sentetik
  v3/v4 imaji salt-okunur acilir, okunur ve **dosya degismez**; ayni imaj
  yazilabilir acilista basligi 5'e yukseltir (satirlar ve `VERIFY`
  bozulmaz). Surum 6 (daha yeni), surum 2, v2 sihirli sayisi, taninmayan
  sihirli sayi, yanlis sayfa boyu, kesik dosya ve **yarim yazilmis
  baslik** (surum yazildi, CRC yazilmadi) reddedilir; reddedilen
  dosyalarin hash'i ve boyutu degismez. Sinirlar belgede: imajlar
  sentetiktir ve yukseltme tek 4 KB'lik yerinde baslik yazimidir
  (kesilirse dosya acilmaz; kurtarma yedekten geri yuklemedir).
- **Tasinabilirlik** `portability` kapisi (29 kontrol) SKILL2 §26.3'u
  kapatir: ayni `.odb` dosyasi **iki platform arasinda gercekten tasindi**.
  Kapi iki modludur — `--write <dizin>` kurar ve platformdan bagimsiz
  `manifest.txt` yazar, `--read <dizin>` dosyayi **salt-okunur** acip
  satir sayisini, icerik ozetini, dosya ozetini/boyunu ve `VERIFY`
  sonucunu dogrular. Olculen: kendi platformunda 29/0; **Windows i386 ->
  Linux x86_64 13/0** ve **Linux -> Windows 13/0** (ayni imza, temiz
  `VERIFY`, dosya ozeti degismedi, `.wal`/`.gen` olusmadi).
  **Bulunan gercek hata:** `VDbTable.SaveSchema` sema metnini RTL'in
  `sl.Text` ozelligiyle yaziyordu, yani satir sonu **platforma
  bagimliydi** (Windows CRLF). Windows'ta yazilan bir veritabani Linux'ta
  aciliyordu ama katalog kaydi 2 bayt uzun oldugu icin ayni veriyi tasiyan
  iki imaj farkli baytlara sahipti (sayfa 1'de 3697 bayt kayma). Sema
  artik acikca `#10` ile birlestirilir; okuma yolu hem CRLF hem LF kabul
  eder, bicim surumu degismedi ve alan/sozdizimi hash'i yoktur. Duzeltme
  sonrasi bagimsiz uretilen iki imaj **yalnizca 13 baytta** farklidir ve
  bu baytlar tamamen **ucucu meta**dir: olusturma zamani (28), rastgele DB
  kimligi (76..83) ve sayfa 0 CRC'si (4092..4095). Kapi `PT6/PT7` ile
  bunu kilitler (ikinci yazim yalniz ucucu alanlarda farkli; sema
  kaydinda CR yok). Durust sinir: buyuk-endian makine ve macOS
  denenmedi.
- **Duzeltildi - cok yazarli tek dosyada onayli commit kaybi** (olculen,
  `tests/multi_writer` kapsiyla kilitlendi). Ayni `.odb` dosyasina iki oturum
  yazdiginda dort ayri hata birlikte veri kaybediyordu:
  (a) **v3.32** `InstallPage` tazeleme sirasinda, `TxnMark` bu oturuma ait
  olmayan sayfalari da siliyordu; artik yalniz `TxnMark = FTxnId` olan sayfa
  dusurulur.
  (b) **v3.33** ikinci oturumun kapanisi `.gen` dosyasini siliyordu; iki
  oturum farkli nesil kimligi tasiyip birbirinin onayli sayfalarini eziyordu.
  Artik surec ici **referans sayaci** (`GGenRefCs`/`GenRefAdd`/`GenRefDrop`/
  `GenRefOthers`) var; `.gen` yalniz gercekten son oturumda silinir.
  (c) **v3.34/v3.35** her oturum kendi LSN'ini ilerlettigi icin iki oturum
  **ayni LSN'i** uretiyordu ve kurtarma `lsn <= MinLSN` kayitlarini atliyordu.
  WAL kuyrugu artik `FTailPos`/`FTailLsn` ile izlenir (`SyncTail`, `TailLsn`)
  ve `DoCommit` LSN'i kuyruktan tohumlar.
  (d) **v3.36** kapanista `DropSideFiles` bos `.wal`i siliyor, diger oturumun
  acik tutamagi yetim kaliyordu; ayni surecte baska oturum varsa
  (`OtherOpenSessions`) yan dosyalara artik dokunulmaz. Ayrica `Wal.Commit`
  her zaman **dosya sonuna** konumlanir; bayat `FAtEnd` konumu yeni commit'i
  eski kaydin uzerine yazabiliyordu.
- **Cok yazarli regresyon kapisi** `multi_writer` (12 kontrol): iki oturum
  sirayla commit eder; WAL commit LSN'leri **kesin artar**; ikinci oturum
  kapaninca `.wal`/`.gen` korunur; birinci oturum kendi onayli satirlarini
  gorur; temiz kapanistan sonra yalniz `.odb` kalir; 12/12 satir kalici;
  yedek + geri yukleme 18/18.
- **Olculebilir benchmark kapisi** `bench_report` (35 kontrol, 18 kategori):
  olusturma, acilis, kapanis, sirali/rastgele ekleme ve nokta okuma,
  guncelleme, silme, indeks olusturma, indeksli arama, aralik sorgusu,
  islem, eszamanli islem (iki oturum), WAL kurtarma, checkpoint, yedek, geri
  yukleme. Her kategori icin P50/P95/P99/max, ortalama ve islem/sn; CSV
  (`bench_report.csv`) + meta (`bench_meta.txt`); FPC heap bellegi ve
  DB/WAL boyu. Kapi ayrica **dogruluk** kontrol eder (satirlar gercekten
  kalici mi), yani hizli ama yanlis bir olcum gecemez. `perf_baseline`'in
  kapsamadigi kategorileri kapatir (SKILL2 §22, `STORAGE_AUDIT.md` §7).
- **Belgelenmis kaynak sinirlari** (SKILL2 §25, SKILL3 §12): motor artik
  "sinirsiz" degil. Asimda kontrollu `EVDbException` doner, surec cokmez,
  dosya gecerli kalir:
  - `VDbPageStore.ExtendFile` — sayfa sayisi tavani `VDB_MAX_PAGES`
    (16 777 215) ve veritabani boyu tavani `VDB_MAX_DB_BYTES` (1 TiB);
    `GrowTo` de ayni boy tavanini zorlar. Onceden `FPageCount` sinirsiz
    artiyordu; LongWord tasmasi iki farkli sayfaya ayni numarayi verebilirdi.
  - `VDbPageStore.MarkPageDirty` — tek islemde degisen sayfa tavani
    `VDB_MAX_TXN_PAGES` (1 048 576). Butce disi dev bir islem WAL'i ve
    bellegi sinirsiz buyutemez.
  - `VDbExecutor` cikti buyumesi (hem `DirectDecode` hem genel yol) — 2M
    satir tavaninda `ecLimit`. Onceden `LIMIT`'siz tam tarama bellek dolana
    kadar buyuyordu (kontrolsuz OOM).
  - `VDbSql.CheckStmtSize` — tek cumle boyu `VDB_MAX_SQL_STMT` (4 MiB);
    `Exec`, parametreli `Exec` ve `ExecRaw` ayni kapidan gecer.
  Tum tavanlar ve sinir koyulmayan yerlerin gerekcesi
  `docs/engineering/LIMITS.md`'de.
- **Sinir regresyon kapisi** `limits` (18 kontrol): 4 MiB'tan buyuk SQL,
  16 MB'lik INSERT ve 2M ustu `LIMIT` kontrollu `ecLimit` ile reddedilir;
  reddedilen islem **satir birakmaz**, tablo sorgulanabilir kalir, kapanistan
  sonra yalniz `.odb` vardir, yeniden acilista veri bozulmamistir; belgelenen
  tavanlarin tutarliligi da olculur. SKILL3 §12'yi kismen kapatir.
- **Onbellek tukenmesi regresyon kapisi** `cache_pressure` (8 kontrol,
  SKILL3 §12.1): havuz 8 sayfaya indirilip (~32 KB) havuzdan cok daha buyuk
  bir tablo uzerinde calisilir. Olculen: tam tarama butun satirlari dogru
  okur (tahliye + yeniden yukleme sessiz veri kaybi uretmez), `PoolUsed`
  havuz boyunu asmaz, miss sayaci gercek tahliyeyi kanitlar, tek islemde
  2000 satirlik guncelleme (kirli sayfa tahliyesi WAL'e dokulur) commit
  edilir ve yeniden acilista guncel veri kalicidir; kapanistan sonra yalniz
  `.odb` kalir.
- **Duzeltildi - okuma yolunda sayfa butunlugu denetlenmiyordu** (v3.38,
  `tests/page_corrupt` kapisiyla kilitlendi). `TVDbPageStore.ReadPageAt`
  sayfayi dogrudan okuyup onbellege aliyordu; `PageVerify`/`PageCheckStruct`
  yalnizca `Verify`/`vdbcheck` tarafindan kullaniliyordu. Sonuc: diskte tek
  bir bozuk bayt (yirtik yazma, bozuk sektor, yanlis sayfa) **sessizce
  yanlis satirlara** cozuluyordu. Artik okunan her imaj `CheckReadImage` ile
  dogrulanir: trunk sayfalari atlanir (ham `VFT1`), yeni uzatilmis bos
  sayfaya izin verilir; sihirli sayi taninmiyorsa, basliktaki sayfa numarasi
  istenenden farkliysa ya da CRC tutmuyorsa kontrollu `ecCorrupt` doner.
  `VerifyOnRead` ozelligi (varsayilan acik) yalnizca CRC denetimini kapatir;
  sayfa kimligi/sihirli sayi denetimi her zaman aciktir. Sifreli dosyada
  GCM etiketi zaten dogrulama yaptigi icin o yol degismedi. Maliyet: her
  sikistirilmamis okumada bir CRC32 daha hesaplanir; `bench_report`
  sayilari bu maliyeti **icerir** (dogrulama kapatilarak ayrica
  olculmedi).
- **Bozuk sayfa regresyon kapisi** `page_corrupt` (8 kontrol, SKILL3
  §5.3/§12.1): saglam dosya tam okunur; `VerifyOnRead` varsayilan acik; her
  veri sayfasinin govdesindeki tek bayt bozulmasi yakalanir (17/17 sayfa);
  bozuk sihirli sayi ve yanlis sayfa imaji (sayfa 2 imaji sayfa 3'e
  kopyalanmis) kontrollu `ecCorrupt`; dosyanin saglam kopyasi bayt bayt
  degismeden kalir ve hala kusursuz taranir (yanlis pozitif yok).
- **Duzeltildi - agdan gelen cerceve boyu sinirsizdi** (v3.39, `tests/
  server_failure` kapisiyla kilitlendi). `VDbNet.VdbRecvStr` uzunluk
  onekini yalniz 1 GiB'a karsi koruyordu; **kimligi dogrulanmamis** bir
  istemci tek bir cerceveyle sunucuda ~1 GiB ayirmaya zorlayabiliyordu
  (bellek tuketimi / hizmet reddi). Artik `VDBS_MAX_RECV_STR = 64 MiB`:
  onek tahsis yapilmadan reddedilir, yalniz o baglanti duser, sunucu ve
  dosya etkilenmez. Mesru her SQL cumlesi ve parametre kumesi bu sinirin
  cok altindadir (PgWire on-kapasi da 64 MiB).
- **Sunucu hata yollari regresyon kapisi** `server_failure` (16 kontrol,
  SKILL3 §12.1): sunucu acilir; el sıkışması protokol surumu 1 + ad ile
  dogru; giris + `CREATE TABLE` + `INSERT` + `SELECT COUNT(*)`;
  `MaxConns=1` iken tavan ustu baglanti `RSP_ERROR` + `kapasite dolu`
  alip kapanir ve mevcut baglanti calismaya devam eder; 64 bayt cop bayt
  ($FF) sunucuyu oldurmez; `CMD_QUERY` + sahte **96 MiB** uzunluk oneki
  (v3.39 oncesi kabul edilirdi) reddedilir ve sunucu yasar; acik baglanti
  varken `Stop` doner ve `Ready=False` olur; `.odb` yerinde kalir, yeniden
  acilir ve satiri okur.
- **Duzeltildi - disk dolu / kisa yazma sessiz kalabiliyordu** (v3.40,
  `tests/disk_full` kapisiyla kilitlendi). `THandleStream.Write` kisa yazmayi
  `0`'a cevirdigi icin ENOSPC tek basina sessiz veri kaybina yol acabilirdi.
  Artik butun sayfa/meta yazmalari tek noktadan (`WriteBytesChecked`) gecer:
  enjekte edilen hata ya da kisa yazma kontrollu `ecIOError` uretir, cerceve
  **kirli** kalir (sessizce temiz isaretlenmez), `GrowTo` basarisiz
  buyumeyi `ecIOError`'a cevirir ve mantiksal boyu artirmaz. Hata
  giderilince checkpoint ve yeni commit'ler calisir; yeniden acilista tum
  onayli satirlar okunur ve `VERIFY` temizdir.
- **Duzeltildi - meta sayfa gerileyebiliyordu** (v3.40, `tests/txn_limit`
  kapisiyla kilitlendi). Görünümü bayat bir oturum kendi **dusuk** LSN'ini ve
  sayfa sayisini meta sayfaya yazabiliyordu: LSN gerilemesi yeniden acilista
  `EVdbPageStale` ile okumayi kilitliyor, sayfa sayisi gerilemesi ise
  `TrimToLogical` uzerinden onayli sayfalari **kirpabiliyordu**. Artik
  `SaveMeta` diskteki meta sayfayi okur ve LSN ile sayfa sayisini yalnizca
  **yukari** tasir (monoton meta kurali); sayfa sayisi buyurse freelist
  alanlari da diskteki degerden alinir.
- **Duzeltildi - WAL yazma hatasi ham `EWriteError` siziyordu** (v3.41,
  `tests/disk_full` DF8/DF9). WAL commit kaydi `WriteBuffer` ile yaziliyordu;
  disk dolu / kisa yazmada hata ham RTL istisnasi olarak cikiyor ve cagiran
  bunu `ecIOError` olarak ayirt edemiyordu. Artik WAL'in tek yazma noktasi
  `WriteChecked`: enjekte edilen hata ve kisa yazma kontrollu `ecIOError`
  uretir, kesik kuyruk geri kirpilir, `FWrittenBytes`/`FAtEnd` tutarli kalir.
  Meta sayfa yazimi da ayni enjeksiyonla olculur (DF9).
- **Duzeltildi - basarisiz commit HAYALET COMMIT birakabiliyordu** (v3.41,
  KRITIK, `tests/disk_full` DF8). `CommitNoSync` ve etiket sayaci birlestirme
  `pendExc` denetiminin **disinda** oldugu icin WAL yazimi basarisiz
  oldugunda yazma kumesi coktan kaldirilmis, durabilite kurtarma blogu
  atlanmis, satirlar hem ayni oturumda gorunup hem sonradan **durabil**
  olabiliyordu; canli tablo sayaci da commit'ten once artirildigi icin
  `COUNT(*)` sisiyordu. Artik ikisi de `pendExc` blogunun icinde;
  basarisizlikta `RecoverAfterDurabilityFailure` calisir (WAL bellek tamponu
  `Rollback` ile temizlenir) ve canli sayac `FTagCountsValid := False` ile
  gecersiz kilinir; `AbortBatch` kendi etiket deltasini temizler. Olculen:
  `COMMIT` kontrollu `ecIOError`, ayni oturumda `COUNT(*)` = durabil 120,
  yeniden acilista 160 satir + temiz `VERIFY` (DF8c).
- **Disk dolu regresyon kapisi** `disk_full` (16 kontrol, SKILL3 §12.1):
  sayfa/meta/**WAL** yazmalarinda sert hata ve kisa yazma, `ROLLBACK`,
  hata sonrasi yazmanin devami, hayalet satir birakmama, checkpoint, yeniden
  acilis ve `VERIFY`.
- **Islem sayisi / yazar cakismasi regresyon kapisi** `txn_limit` (18
  kontrol, SKILL3 §12.2): 300 kisa islem ve 300 islemin 75'i geri alinarak
  commit sayisi birebir dogrulanir; oturum basina tek acik islem vardir ve
  ic ice `BEGIN`, islem yokken `COMMIT`/`ROLLBACK` belgelenmis sessiz
  no-op'tur; dosya basina tek yazar rezervasyonu kisa busy suresinde
  kontrollu `mesgul` hatasi verir, `ROLLBACK` ile temizlenir ve birakilinca
  islem yeniden tamamlanir; temiz kapanis tek dosya birakir, yeniden
  acilista 578 satir ve temiz `VERIFY`.
- **Bellek tukenmesi regresyon kapisi** `oom` (9 kontrol, SKILL3 §12.1):
  `VDbMM`'e yalniz test icin enjeksiyon kancasi eklendi
  (`MMInjectFault`/`MMInjectClear`/`MMInjectHits`/`MMInjectActive`; esik
  ustundeki tahsislerde bir kez `EOutOfMemory` atar, sonra kapanir). Okuma
  ve yazma yollari ayri olculdu; nil donen tahsis `SetLength` icinde
  `EAccessViolation`'a donustugu icin **yanlis** bir benzetimdi, gercek
  heap gibi `EOutOfMemory` atiliyor. **Bulunan gercek hata (F16,
  KRITIK):** yazma sirasindaki tahsis hatasi dosyada taninmayan sayfa
  birakiyordu (`EVdbHeap: sayfa N taninmiyor`). `ExtendFile` artik once
  buyutur, sonra `Inc(FPageCount)` yapar; `AllocPage` yalnizca bu cagrinin
  actigi sayfayi geri alir (`FPageCount`, `FFreshPage`). Kapi: hata
  sonrasi oturum yazmaya devam eder, hayalet satir yok, checkpoint
  basarili, yeniden acilis 200 satir ve temiz `VERIFY`.
- **B+Tree olcek ve VACUUM geri kazanma kapisi** `btree_scale` (15 kontrol,
  SKILL3 §13 olcum-once kurali: "olculebilir bir sorun olmadan spekulatif
  B+Tree degisikligi yok"): bellekteki `TVDbBTree`'ye 1.000.000 anahtar
  karisik sirada eklenir — yukseklik **4**, **14.965** yaprak, ortalama
  doluluk **66/96**, degismezler temiz, `All()` artan, 8.000 rastgele
  `Find`, `CountRange`/`RankBefore` analitik beklentiyle ayni. Olcek olcusu
  toplam sure degil **islem basina** maliyettir: 10x veride 3,75x Windows /
  4,55x Linux (karesel agacta ~10x); 1M anahtar onbellek disina tasindigi
  icin toplam oran 35-46x cikar ve tek basina yanilticidir. Yarisi silinip yeniden
  eklenince yaprak sayisi 14.965 -> 14.979 (**1,00x**) kalir, yani churn
  sonrasi yaprak parcalanmasi olmaz. Diskte 6.000 satir yazilir, %90'i
  silinir (dosya kuculmez; `GetDeadBytes` yalniz freelist sayfalarini
  sayar, sayfa ici olu alani degil — belgelenmis sinir), `VACUUM` 1,60 MB
  dosyayi 151 KB'a indirir (**%90 kazanc**), satir sayisi birebir kalir,
  sonrasinda 600 satir daha eklemek dosyayi sisirmez, yeniden acilis ve
  `VERIFY` temizdir. Kapi yazilirken **iki gercek hata** olculdu (asagida
  F17/F18): Linux'ta VACUUM hic yer kazanmiyordu ama "kazandi" diyordu.
- **Duzeltildi - Unix'te her acilis bir dosya tanitici sizdiriyordu**
  (v3.43, KRITIK; `tests/btree_scale` BS11 ile ortaya cikti).
  `VDbOpenStreamNoFlock` fd'yi `FpOpen` ile aciyor, sonra `THandleStream`
  ile sariyordu; FPC'nin `THandleStream.Destroy` handle'i **kapatmaz**.
  Sonuc: acilan her veritabani dosyasi kapanistan sonra da acik kaliyordu
  (surec basina bir fd; uzun omurlu sunucuda tukenme riski). Windows'ta
  belirti vermez, ama WSL `/mnt/d` (9p) uzerinde **sinsi**: acik handle'li
  dosyanin `rename`'i `True` doner ama tembel uygulanir — dosya iki ad
  altinda da gorunmez. Bu yuzden VACUUM'un `.bak` takasi "basarili" gorunup
  yeni dosya acilamadiginda eski dosya geri kuruluyor, yani **VACUUM hic
  yer kazanmiyordu** (BS11: `eski=1601536 yeni=1449984`). Cozum: UNIX
  yolunda `TVDbFdStream = class(THandleStream)` ve `Destroy` icinde
  `FpClose(Handle)` (depodaki tek `THandleStream.Create` cagrisiydi).
  Duzeltmeden sonra Linux (drvfs) ve Windows ayni sonucu verir:
  `1601536 -> 151552`, yeniden acilis `sayfa=72`.
- **Duzeltildi - basarisiz dosya degistirme sessizce basarili
  gorunuyordu** (v3.43, KRITIK; ayni kapi). `SwapDbFileWith`'in dis
  `except` blogu hatayi **yutuyordu**: `.bak`'tan geri donus de basarisiz
  olsa `Compact`/`RESTORE`/`REKEY` normal donuyor, VACUUM "kazanc"
  sayilari yanlis raporlaniyordu. Artik geri donus basarisizsa acik
  `EVdbBackendV3` hatasi verilir ve hata yukari tasinir; ayrica backend
  `FEng=nil` ile kilitsiz birakilmaz.
- **Ozellik regresyon kapisi** `sql_features` (32 kontrol): SKILL3 §9.1/
  §10.1'in "uygulanmis ama test edilmemis" listesini kapatir — `SAVEPOINT` /
  `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT` (kismi geri alma gercekten
  yalniz sonraki satirlari atar), `ON CONFLICT DO NOTHING|DO UPDATE` (cift
  anahtar degeri korur/gunceller, satir sayisi artmaz), `VACUUM`, `REINDEX`,
  `ANALYZE <tablo>` (bakim sonrasi satir sayisi ve indeksli arama dogru),
  `WITH` (CTE), `ROW_NUMBER() OVER (ORDER BY ...)`, `ALTER TABLE ... RENAME
  TO`. Bu ozellikler `readme.md`'de "kapisi yok" olarak isaretliydi; artik
  var.
- **Denetim raporu** `docs/audit/V3_FINAL_AUDIT.md` (SKILL3 §18 formati):
  bulgular (siddet/dosya kok neden/duzeltme/test), kapi sonuclari, kalan
  riskler ve durust siniflandirma **BETA CANDIDATE** (certified/SIL iddiasi
  yok).

### SQL

- **Davranis matrisi** `sql_matrix` (61 durum) + `ValidateExprCols`
  (bos tabloda sessiz referans hatasi kapatildi) — `SQL_COVERAGE.md`.
- **PostgreSQL diferansiyel korpusu** `sql_differential` + skip governance
  (10 ayni / 4 bildirilmis fark) — `SQL_DIFFERENTIAL.md`. Canli `psql`
  olmadigi icin `pg=not-run`.

### Performans

- **B+Tree silme yeniden dengelenir**: borrow -> merge -> kok cokertme;
  min doluluk yaprak `K div 2`, ic dugum `(K-1) div 2`;
  `CheckInvariants` sikilastirildi (`tests/btree_integrity`, 152 kontrol).
- **`perf_baseline` kapisi**: mutlak sure yerine genis tavan + olceklenme
  orani (karesel bozunma tespiti) — `PERF_BASELINE.md`.

### Tek dosya (v3.32)

- **Temiz kapanistan sonra dizinde yalnizca `<db>.odb` kalir.** `Close`
  sirasi: checkpoint -> WAL handle kapat -> `.idx` sil -> `.wal` sil (yalniz
  bos ise) -> `FStore.Close` `.gen` sil (tam kilit bizdeyken). Checkpoint
  atlanirsa yan dosyalara **dokunulmaz**; yarim kalan bir commit'i silmek
  veri kaybi olurdu.
- `.gen` **degisim gunlugu degil**, page store'un surecler-arasi sayaci +
  durabil LSN + bayt aralik kilit bolgesidir; kapanista silinip sonraki
  acilista ayni kimlikle yeniden uretilir (durabil LSN 0'dan baslar =
  yalnizca fazladan bir fsync, fail-safe).
- **Degisim gunlugu (PITR/replikasyon) artik opt-in**: `ChangeLogEnabled`
  varsayilan `False`; kapaliyken `.log/` ve changelog taban imaji hic
  olusmaz ve `LogStatus` bunu acikca soyler (sessiz yalan yok).
- Acilis `.idx` onbellegi olmadan tam tarama yapar; hiz isteyen
  `KeepIdxOnClose=True` ile eski davranisi secer (o zaman dizinde ikinci
  dosya kalir). `DropWalOnClose`/`DropGenOnClose` de kapatilabilir.
- `tests/single_file` 22 -> **35 kontrol** (SF1-SF20): kapanistan sonra tek
  dosya, tek dosyaya yazma, `.odb` kopyasi, `BACKUP TO` ciktisi.

### Belgeler

- **"Tek dosya" ifadesi once gercege gore duzeltildi**: veri `<db>.odb`
  icinde, ama calisan bir veritabani `.wal`, `.idx`, `.gen`, `.log/` ile
  birlikte **bes girdiydi**. Yalniz `.odb` kopyasi acilir ve yazilabilir
  (motor eksik yan dosyalari yeniden uretir); tasinabilir tek dosya icin
  `BACKUP TO`. `tests/single_file` ve `docs/engineering/ON_DISK_LAYOUT.md`.
- README'lerdeki eski/yanlis bilgiler duzeltildi: mimari zincir (v2-only
  anlatimi), derleme komutlari (`sqltest.lpi` yok), ilk sorgu ornegi
  (`TVSql.Create` bir `TVTableDb` alir), export sayisi (57), test tablosu
  (19 kapi Linux / 18 Windows).
- Ozellik listesindeki "kapi testleriyle dogrulanmistir" iddialari
  duzeltildi: `SAVEPOINT`, `AS OF`/PITR, dosya modu replikasyon, zone map
  ve `ALTER DATABASE KEY` **uygulanmistir ama mevcut kapilarca test
  edilmemektedir**.
- Guvenlik belgeleri: `docs/security/THREAT_MODEL.md` (STRIDE + R-01..R-12
  risk kaydi), `SECURITY.md` (GitHub Security Advisories uzerinden ifsa),
  `docs/security/SBOM.md` + CycloneDX 1.5 `vdb.cdx.json`, kok `NOTICE`.
- `docs/engineering/RC_REVIEW.md`: surum adayi degerlendirmesi — kapilarin
  kanitladigi sey, skill §16 kalemlerinin durumu, VDBS risklerinin yayini
  engelledigi nokta ve yayin oncesi kalan isler.

### Altyapi

- CI matrisi Ubuntu + Windows; kapilar `tests/run_gates.sh` uzerinden
  (Unix) ve Git Bash uzerinden kosar. Kapilar `tests/gates`/`tests/sql`
  eski agacindan bagimsizdir.
