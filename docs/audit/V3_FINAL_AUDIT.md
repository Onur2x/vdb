# VDB V3 - Derin Denetim ve Sertlestirme Raporu

SKILL3 (VDB V3 Deep Repository Audit, Bug Fixing & Production Hardening)
§18 formatina gore. Tarih: 2026-11-15.

## Summary

- **Depo durumu**: `D:\veritabani`, dal `main`, dosya bicimi **v5**
  (`VDB_FILE_VER = 5`). v4 konteyner calismasi sahibi tarafindan
  DURDURULDU (veri kaybi riski); bicim degismedi.
- **Derleyici**: Free Pascal 3.2.4.
- **Platformlar**: Windows i386 (`C:\lazarus\fpc\3.2.4\bin\i386-win32`) ve
  WSL x86_64 Linux, ayni kaynak, ayni `tests/run_gates.sh`.
- **Denetim kapsami**: SKILL2 §18-28 ve SKILL3 §5-§15, §19. Depolama
  motoru, WAL/kurtarma, islem izolasyonu, B+Tree, SQL yurutucu, guvenlik,
  kaynak sinirlari, performans, tasinabilirlik, belge.
- **Kosulan testler**: `tests/run_gates.sh` - Linux **39 kapi**, Windows
  **38 kapi** (`tls_client` atlanir), tamami PASS.

## Findings

| # | Siddet | Dosya / islev | Kok neden | Duzeltme | Test | Durum |
|---|---|---|---|---|---|---|
| F1 | **KRITIK** | `VDbPageStore.InstallPage` | Tazeleme sirasinda sayfa, `TxnMark` bu isleme ait olmasa da siliniyordu; baska oturumun **onayli** sayfalari kayboluyordu | `TxnMark = FTxnId` kosulu (v3.32) | `multi_writer` MW3/MW4 | KAPALI |
| F2 | **KRITIK** | `VDbPageStore.Close`, `.gen` | Ikinci oturumun kapanisi `.gen` dosyasini siliyordu; iki oturum farkli nesil kimligi tasiyip birbirinin sayfalarini eziyordu | Surec ici referans sayaci `GGenRefCs`/`GenRefAdd`/`GenRefDrop`/`GenRefOthers` (v3.33) | `multi_writer` MW2 | KAPALI |
| F3 | **KRITIK** | `VDbPageEngine.DoCommit` | LSN yalnizca oturum onbelleginden aliniyordu; checkpoint WAL'i kirptiktan sonra iki oturum **ayni LSN**'i uretiyor, kurtarma `lsn <= MinLSN` kayitlarini atlayarak onayli commit'i siliyordu | WAL kuyruk LSN'i (`FTailPos`/`FTailLsn`, `SyncTail`, `TailLsn`) ile tohumlama, sonra `FStore.SetLSN` (v3.34/v3.35) | `multi_writer` MW1 (LSN kesin artan) | KAPALI |
| F4 | **KRITIK** | `VDbPageEngine.DropSideFiles` | Kapanan ikinci oturum, BOS `.wal`'i siliyordu; birinci oturumun acik tutamagi yetim kaliyor, sonraki commit'ler gorunmez oluyordu | `FStore.OtherOpenSessions > 0` iken yan dosyalara dokunma (v3.36) | `multi_writer` MW2/MW4 | KAPALI |
| F5 | **KRITIK** | `VDbPageWal.Commit` | `FAtEnd` bayat konumu guveniyordu; baska oturum araya kayit eklediyse yeni commit eski kaydin **uzerine** yaziyordu (WAL'de sessiz delik) | Her commit `FStream.Seek(0, soEnd)` (v3.36) | `multi_writer` MW1/MW4 | KAPALI |
| F6 | ORTA | `VDbPageStore.ExtendFile` | Sayfa sayaci sinirsizdi; LongWord tasmasi iki farkli sayfaya ayni numarayi verebilirdi (sessiz bozulma) | `VDB_MAX_PAGES` + `VDB_MAX_DB_BYTES` ile kontrollu `ecLimit` (v3.37) | `limits` L5/L6 | KAPALI |
| F7 | ORTA | `VDbPageStore.MarkPageDirty` | Tek islem sinirsiz sayfa kirletebiliyordu (bellek/WAL sisirme) | `VDB_MAX_TXN_PAGES` (1M) `ecLimit` (v3.37) | `limits` L5 | KAPALI |
| F8 | ORTA | `VDbSql.Exec`/`ExecRaw` | Tek SQL cumlesi boyu sinirsizdi; dev bir metin motoru bellek tuketerek cokertiyordu | `VDB_MAX_SQL_STMT` (4 MiB) + `CheckStmtSize` (v3.37) | `limits` L1/L3 | KAPALI |
| F9 | ORTA | `VDbExecutor` cikti buyumesi | LIMIT'siz tam tarama bellek dolana kadar buyuyordu (kontrolsuz OOM) | 2M satirda kontrollu `ecLimit` (v3.37) | `limits` L4 (parser yolu); tam tarama yolu **testsiz** | KISMI |
| F10 | DUSUK | `tests/bench_report` BR11 | Indeks testi id tabani `300000`, BR5 rastgele araligiyla cakisiyordu; sahte "duplicate PK" | Taban `2000000` | `bench_report` 35/0 | KAPALI |
| F11 | **ORTA** | `VDbPageStore.ReadPageAt` | Normal okuma yolu hicbir butunluk denetimi yapmiyordu: `PageVerify`/`PageCheckStruct` yalniz `Verify`/`vdbcheck` tarafindaydi. Diskteki tek bozuk bayt, yanlis sayfa numarasi ya da bozuk sihirli sayi **sessizce** yanlis satirlara cozuluyordu (sessiz veri bozulmasi) | `CheckReadImage` okuma yolunda: trunk atlanir, bos sayfaya izin, sihirli sayi/sayfa kimligi her zaman, CRC `VerifyOnRead` ile (varsayilan acik) `ecCorrupt` (v3.38) | `page_corrupt` 8/0; `page_integrity` I5/I6 ve `integrity_check` IC-B1 hala ayni davranisi dogruluyor | KAPALI |
| F12 | **ORTA** | `VDbNet.VdbRecvStr` | Agdan gelen metin cercevesinin uzunluk onegi yalniz 1 GiB'a karsi korunuyordu; kimligi **dogrulanmamis** bir istemci sahte onekle sunucuda ~1 GiB ayirmaya zorlayabiliyordu (bellek tuketimi / DoS). Sunucu ayrica 96 MiB'lik onegi kabul edip tahsis deniyordu | `VDBS_MAX_RECV_STR` = 64 MiB; onek **tahsis yapilmadan** reddedilir, yalniz o baglanti duser (v3.39) | `server_failure` SF6 (96 MiB sahte onek + sunucu yasamaya devam) | KAPALI |
| F13 | **KRITIK** | `VDbPageStore.SaveMeta` | Bayat gorunumlu bir oturum kendi **dusuk** `FLSN` ve `FPageCount` degerini meta sayfaya yaziyordu. Sonuc: (a) yeniden acilista sayfa LSN'i meta gorunum LSN'inden buyuk kalip `EVdbPageStale` ile okuma reddediliyordu, (b) regresen sayfa sayaci `TrimToLogical` uzerinden **onayli sayfalari kirpabiliyordu** (veri kaybi) | Meta sayfa monotonik: `SaveMeta` yazmadan once diskteki meta okunur, LSN ve sayfa sayaci yalniz **artirilir** (`FreeTrunk`/`FreeCount` sayfa sayaci kazaninca esitlenir) (v3.40) | `txn_limit` TL6/TL8 (yazar cakismasi + yeniden acilis 578 satir + `VERIFY`) | KAPALI |
| F14 | ORTA | `VDbPageStore.WritePageAt` / `SaveMeta` / `InstallPage` / `GrowTo` | Disk doldu (ENOSPC) yolunda `THandleStream.Write` kisa yazmayi `0`'a cevirdigi icin yazma **sessizce** basarisiz olabiliyordu; buyume yolunda ham `EWriteError` siziyordu | Tek yazma noktasi `WriteBytesChecked`: enjekte edilen hata + kisa yazma kontrollu `ecIOError`; cerceve **kirli** kalir; `GrowTo` mantiksal boyu artirmaz (v3.40) | `disk_full` 16/0 (sayfa, meta ve WAL yazmalari) | KAPALI |
| F15 | **KRITIK** | `VDbBackendV3.CommitBatch` / `AbortBatch` / `VDbPageWal.Commit` | (a) WAL commit yazimi `WriteBuffer` ile yapiliyordu; kisa yazma ham `EWriteError` olarak siziyordu. (b) `CommitNoSync` ve `MergeTagDeltas` `pendExc` denetiminin **disinda** oldugu icin WAL yazimi basarisiz oldugunda yazma kumesi kaldirilmis, kurtarma blogu atlanmis ama satirlar hem ayni oturumda gorunup hem sonradan **durabil** olabiliyordu (hayalet commit). (c) Canli tablo sayaci commit'ten **once** artirildigi icin basarisiz commit sayaci sisiriyordu (`COUNT(*)` 130 vs durabil 120) | WAL tek yazma noktasi `WriteChecked` -> kontrollu `ecIOError`, kesik kuyruk geri kirpilir; `CommitNoSync` + `MergeTagDeltas` `pendExc` blogunun icine alindi, basarisizlikta `RecoverAfterDurabilityFailure` (+`FWal.Rollback`) ve `FTagCountsValid := False`; `AbortBatch` kendi `TagDelta`'sini temizler (v3.41) | `disk_full` DF8/DF8b/DF8c (WAL yazma hatasi -> kontrollu `ecIOError`, ayni oturumda `COUNT(*)` = durabil 120, yeniden acilis 160 + `VERIFY`) | KAPALI |
| F16 | **KRITIK** | `VDbPageStore.ExtendFile` / `AllocPage` | Sayfa ayirma iki adimda **gorunur** hale geliyordu: `ExtendFile` once `FPageCount`'u artirip sonra dosyayi buyutuyordu, `AllocPage` ise sayfa numarasini yayinladiktan sonra okuyup baslatiyordu. Arada gelen bir tahsis (`EOutOfMemory`, gercek heap davranisi) sayfa numarasini **taninmayan bir sayfa** olarak dosyada birakiyordu; yeniden acilis taramasi `EVdbHeap: sayfa N taninmiyor (ne VDbPage ne trunk)` ile dosyayi acamiyordu | `ExtendFile` once buyutur, **sonra** `Inc(FPageCount)` yapar; `AllocPage` `GetPageInternal`/`PageInit` hatasinda yalnizca bu cagrinin actigi sayfayi geri alir (`FPageCount`, `FFreshPage`). Freelist'ten gelen sayfa sizinti olarak kalir, ama disaridaki imaji gecerli sayfa/trunk oldugu icin bozulma degildir (v3.42) | `oom` 9/0 (okuma + yazma yolunda enjekte `EOutOfMemory`, hayalet satir yok, yeniden acilis + `VERIFY` temiz) | KAPALI |
| F17 | **KRITIK** | `VDbSync.VDbOpenStreamNoFlock` (UNIX dali) | fd `FpOpen` ile aciliyor, `THandleStream` ile sariliyordu; FPC'nin `THandleStream.Destroy` handle'i **kapatmaz**, yani acilan her veritabani kapanistan sonra da acik kaliyordu (surec basina bir fd sizintisi). Windows'ta belirti vermez; WSL `/mnt/d` (9p) uzerinde acik handle'li dosyanin `rename`'i `True` doner ama **tembel** uygulanir (dosya iki ad altinda da gorunmez), bu yuzden VACUUM'un `.bak` takasi yeni dosyayi acamayip eski dosyaya donuyordu | UNIX yolunda `TVDbFdStream = class(THandleStream)`, `Destroy` icinde `FpClose(Handle)`; `Open` `TVDbFdStream.Create(fd)` dondurur (depodaki tek `THandleStream.Create` cagrisiydi) (v3.43) | `btree_scale` BS11 (Linux drvfs ve Windows ayni: `eski=1601536 yeni=151552`, yeniden acilis `sayfa=72`) | KAPALI |
| F18 | **KRITIK** | `TVdbBackendV3.SwapDbFileWith` | Dis `except` blogu hatayi **yutuyordu**: `.bak`'tan geri donus de basarisiz olsa `Compact`/`RESTORE`/`REKEY` normal donuyordu. F17 ile birlesince Linux'ta VACUUM hic yer kazanmadigi halde "kazandi" sayilari raporlaniyordu (sahte basari) | Geri donus basarisizsa acik `EVdbBackendV3` hatasi; hata yukari tasinir, backend `FEng=nil` ile kilitsiz birakilmaz (v3.43) | `btree_scale` BS11/BS12 (her iki platformda `1601536 -> 151552`, `COUNT` 600, `VERIFY` temiz); `backup_restore` 25/0 | KAPALI |

### Kapatilan test bosluklari (SKILL2 §22, SKILL3 §10.1)

- `bench_report` (35 kontrol, 18 kategori, P50/P95/P99, CSV+meta) - yeni.
- `multi_writer` (12 kontrol) - yeni.
- `sql_features` (32 kontrol) - yeni: `SAVEPOINT` / `ROLLBACK TO` /
  `RELEASE SAVEPOINT`, `ON CONFLICT DO NOTHING|DO UPDATE`, `VACUUM`,
  `REINDEX`, `ANALYZE <tablo>`, `WITH` (CTE), `ROW_NUMBER() OVER`,
  `ALTER TABLE ... RENAME TO`.
- `limits` (18 kontrol) - yeni: asiri SQL / asiri INSERT / asiri LIMIT
  kontrollu `ecLimit`, sinir sonrasi veri butunlugu, belgelenen tavanlar.
- `cache_pressure` (8 kontrol) - yeni: 8 sayfalik havuzla ~100 sayfalik
  tablo; tahliye + yeniden yukleme veri kaybetmez, `PoolUsed` havuz boyunu
  asmaz, kirli sayfa tahliyesi commit sonrasi kalicidir (SKILL3 §12.1
  "cache exhaustion").
- `page_corrupt` (8 kontrol) - yeni: okuma yolunda sayfa butunlugu (her veri
  sayfasinda tek bayt bozulmasi, bozuk sihirli sayi, yanlis sayfa imaji ->
  kontrollu `ecCorrupt`; saglam kopya yanlis pozitif uretmez).
- `server_failure` (16 kontrol) - yeni: sunucu hata yollari (baglanti tavani
  `kapasite dolu`, cop baytlar, sahte 96 MiB uzunluk oneki, acik baglanti
  varken `Stop`, dosyanin yeniden acilip okunmasi).
- `disk_full` (16 kontrol) - yeni: disk dolu / kisa yazma yolu (sayfa, meta ve
  **WAL** yazmalarinda hata kontrollu `ecIOError`, hata sonrasi cerceve kirli
  kalir, basarisiz commit **hayalet satir** birakmaz - ayni oturumda `COUNT(*)`
  durabil durumla ayni -, `ROLLBACK` ve ardindan gelen commit calisir, hata
  giderilince checkpoint basarili, yeniden acilista tum onayli satirlar + temiz
  `VERIFY`; SKILL3 §12.1).
- `txn_limit` (18 kontrol) - yeni: islem sayisi basinci ve yazar cakismasi
  (ic ice `BEGIN`, islem yokken `COMMIT`/`ROLLBACK` sessiz no-op; 300 kisa
  islem ve 75 geri almanin commit sayisi birebir dogrulanir; dosya basina tek yazar
  rezervasyonu -> kisa busy suresiyle kontrollu `mesgul`, `ROLLBACK`,
  birakilinca yeniden tamamlama; yeniden acilis 578 satir + temiz `VERIFY`;
  SKILL3 §12.2).

## Test Results

| Sonuc | Linux | Windows |
|---|---|---|
| PASS (kapi) | **39** | **38** |
| FAIL | 0 | 0 |
| SKIP (`VDB_CRYPTO_DLL` yok) | 2 (`fixtures_openssl`, `selftest_openssl`) | 3 (+`tls_client`) |
| Calistirilmayan | canli PostgreSQL karsilastirmasi (`sql_differential` `pg=not-run`) | ayni |

Kapi toplamlari (ikisi de ayni): sql_stubs 25/0, sql_matrix 61/0,
sql_fuzz 5/0, sql_differential 33/0, crypto_* PASS, wal_crash, kv_wal,
backup_restore 25/0, page_integrity 14/0, btree_integrity 152/0,
perf_baseline 16/0, single_file 35/0, region_stream 13/0, multiproc 17/0,
crash_points 24/0, integrity_check 32/0, cache_metrics 21/0,
format_compat 28/0, portability 29/0, multi_writer 12/0, bench_report 35/0,
sql_features 32/0, limits 18/0, cache_pressure 8/0, page_corrupt 8/0,
server_harden 24/0, server_failure 16/0, auth_throttle 16/0,
disk_full 16/0, txn_limit 18/0, oom 9/0, btree_scale 15/0, wal_limit 19/0,
net_fuzz 39/0,
selftest_builtin PASS, tls_client 6/0 (yalniz Linux).

## Remaining Risks

**Bilinen hatalar**: acik kritik hata yok. F9 kismi: LIMIT'siz dev tarama
icin tavan kodda var ama 2M satir ureten bir kapi yok (kapi suresi icin
bilincli olarak disarida).

**Eksik testler** (SKILL3 §12.1'den kalanlar):

| Test | Durum |
|---|---|
| Disk dolu (ENOSPC) | VAR (`disk_full`: kisa yazma/sert yazma hatasi -> kontrollu `ecIOError`, cerceve kirli kalir, `ROLLBACK` sonrasi veri bozulmaz, yeniden acilis + `VERIFY` temiz) |
| Bellek tahsis hatasi | VAR (`oom`: enjekte edilen tahsis hatasi okuma ve yazma yolunda `EOutOfMemory` olarak yuzeye cikar; sayfa ayirma atomik oldugu icin dosyada taninmayan sayfa kalmaz, basarisiz commit hayalet satir birakmaz, yeniden acilis + `VERIFY` temiz) |
| WAL tukenmesi | VAR (`wal_limit`: sert boy tavani `VDB_WAL_MAX_BYTES` 64 MiB; tavani asan tek islem commit aninda `ecLimit` alir, commit kaydi yazilmaz, onceki onayli satirlar korunur, hayalet satir olusmaz, ret sonrasi yazim devam eder, yeniden acilis + `VERIFY` temiz) |
| Onbellek tukenmesi / tahliye | VAR (`cache_pressure`: 8 sayfalik havuz, kirli tahliye, yeniden acilis) |
| Asiri baglanti | VAR (`server_failure` SF4: `MaxConns=1` iken ikinci baglanti `RSP_ERROR` + `kapasite dolu` alir, birincisi calismaya devam eder) |
| Asiri islem | VAR (`txn_limit`: 300 kisa islem + 75 geri alma birebir dogrulanir; ic ice `BEGIN` / islem yokken `COMMIT`/`ROLLBACK` sessiz no-op; dosya basina tek yazar rezervasyonu, kisa busy suresiyle kontrollu `mesgul` ve birakilinca yeniden tamamlama) |
| Bozuk ag girdisi | VAR (`net_fuzz`: gercek PG wire sunucusu loopback'te trust modda, `MaxConns=256` ile 15 saldiri ailesi + 120 yinelemeli tohumlanmis mutasyon + 4 eszamanli is parcacigi; her saldiridan sonra gecerli istemci startup'i tamamlayip `SELECT 1` yaniti alir. Ayrica `server_failure` SF5/SF6 ikili protokolde cop baytlar ve sahte 96 MiB uzunluk oneki) |
| Bozuk veritabani / WAL | VAR (`page_integrity`, `integrity_check`, `wal_crash`, `format_compat`) |
| Gecersiz sifreleme anahtari | VAR (`crypto_fixtures`) |
| Sayfa numarasi / yirtik yazma bozulmasi | VAR (`page_corrupt`: normal okuma yolu her sayfayi dogrular; `page_integrity`, `integrity_check`) |
| Sunucu kapanisi | VAR (`server_failure` SF7/SF8: acik baglanti varken `Stop` doner, dosya yeniden acilip okunur) |
| 1M anahtar olcek (bellekteki B+Tree) | VAR (`btree_scale` BS1-BS8: 1.000.000 anahtar, yukseklik 4, 14.965 yaprak, doluluk 66/96; islem basina maliyet 10x veride 3,75x Windows / 4,55x Linux - karesel degil; yarisi silinip yeniden eklenince yaprak sayisi 14.965 -> 14.979 = 1,00x) |
| VACUUM sonrasi geri kazanma / parcalanma | VAR (`btree_scale` BS9-BS14: 6.000 satir 1.601.536 bayt; %90 silme dosyayi kucultmez (sayfalar yeniden kullanilir), `VACUUM` **iki platformda da** 1.601.536 -> 151.552 bayt = %90 kazanc; sayim birebir, yeniden ekleme sismez, yeniden acilis + `VERIFY` temiz. Bu kapi ayrica F17/F18'i ortaya cikardi: Linux VACUUM'u yer kazanmadan basarili gorunuyordu) |
| Ayri B+Tree disk sayfa bicimi | KISMI (`tests/btree_disk` BD1-BD18: bagimsiz `VDbBTreeDisk.pas` icin 4096 baytlik sayfa bicimi, golge sayfalama ile atomik commit, yirtik meta geri donusu, cokme noktasinda onceki agacin tam okunmasi, yalniz-CRC ve yapisal bozulma tespiti, sayfa geri kazanimi - iki platformda 78 kontrol, 0 FAIL. **v5 motor dosya bicimine bagli DEGILDIR**: tablo satirlari hala 4 KB sayfa yigini, ikincil indeksler bellekteki `TVDbBTree`; birlesme/yeniden dagitma yok - bkz. `docs/engineering/BTREE_INTEGRITY.md` §7) |

**Desteklenmeyen ozellikler**: v4 konteyner bicimi (durduruldu), dis
bagimlilik yok (saf native, harici DLL yok - OpenSSL istege bagli).

**Dogrulanmamis platformlar**: yalniz Windows i386 ve Linux x86_64
olculdu; macOS/ARM derlemesi denenmedi.

**Guvenlik sinirlari**: sifreleme (AES-256-GCM, PBKDF2) `crypto_*` ve
`server_harden`/`auth_throttle` ile olculuyor; resmi FIPS/SIL iddiasi
YOKTUR ve bu rapor boyle bir iddia kurmaz. TLS yalniz istege bagli harici
OpenSSL ile, yani varsayilan yapida ag sifrelemesi yok.

**Performans sinirlari**: olcumler tek makine, tek derleyici, `-O1`
kosullarinda; `bench_report` tekrarlanabilir (sabit tohum 20251115) ama
donanimlar arasi karsilastirma icin normallestirilmedi. Canli PostgreSQL
karsilastirmasi kosmadi.

## Production Readiness

**BETA CANDIDATE**

Gerekce: kritik depolama/WAL/islem hatalari kapatildi ve her biri kalici
bir regresyon kapisiyla kilitlendi; iki platformda 40/39 kapi yesil; tek
dosya sozlesmesi, kurtarma, sayfa butunlugu, sunucu hata yollari, bozuk ag
girdisi (genis fuzz), disk dolu,
islem sayisi basinci, bellek tukenmesi, WAL sert boy tavani, B+Tree
olcek/parcalanma ve VACUUM geri kazanimi ile tasinabilirlik olculdu. Olcum
kapisinin kendisi iki kritik hata buldu (F17 Unix fd sizintisi, F18 sahte
basarili dosya degistirme); ikisi de kapatildi ve ayni kapiyla kilitlendi.
Buna karsin ayri B+Tree disk sayfa bicimi yalnizca **bagimsiz ve kapili bir
bilesen** olarak vardir (`VDbBTreeDisk`), v5 motor dosya bicimine bagli
degildir; canli PostgreSQL diferansiyeli kosmadi; TLS varsayilan olarak
kapali. Bu nedenle "PRODUCTION CANDIDATE" degil.

Bu siniflandirma bagimsiz dogrulama (harici denetim, resmi sertifika)
olmadigi icin "certified"/"SIL"/"formal compliance" iddiasi icermez.
