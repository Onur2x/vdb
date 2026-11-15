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
