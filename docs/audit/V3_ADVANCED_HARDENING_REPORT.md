# VDB V3 - Ileri Sertlestirme Raporu (SKILL4)

Tarih: 2026-11-18
Surum: v3.56 (Sprint A + B + C + D + F1 + E; soak/F-21/F-22 = v3.50; Sprint F belgeleri v3.51)
Dosya bicimi: **v5** (`VDB_FILE_VER = 5`, degismedi)
Durus: **BETA CANDIDATE**

Bu rapor SKILL4'un istedigi A-J basliklarini izler. Kural: **kosmayan test
PASS gosterilmez**. Olculen her sayi kaynakli verilir; olculmeyen her alan
acikca "olculmedi" / "not-run" yazilir. Bu belge bagimsiz denetim, saha
kullanimi veya uygunluk degerlendirmesi olmadan "CERTIFIED", "FIPS", "SIL"
veya "PRODUCTION READY" iddiasi kurmaz. Nihai siniflandirma bolum J'dedir.

Yardimci belgeler: `docs/audit/V3_FINAL_AUDIT.md` (bulgu tablosu F1-F22),
`docs/engineering/CI.md` (kapi tablosu ve run log'lari),
`docs/engineering/WAL_RECOVERY_AUDIT.md`,
`docs/engineering/STORAGE_AUDIT.md`,
`docs/engineering/BTREE_INTEGRITY.md`,
`docs/engineering/PERF_BASELINE.md`,
`docs/engineering/DISK_BTREE_DESIGN.md`,
`docs/engineering/SQL_SCALE.md`,
`docs/engineering/CRYPTO_PROVIDER.md`,
`docs/engineering/NETWORK_SECURITY.md`,
`docs/engineering/RESOURCE_LIMITS.md`,
`docs/engineering/LIMITS.md`,
`docs/security/THREAT_MODEL.md`,
`docs/security/SBOM.md`.

---

## A. Genel sonuc

### A.1 Tamamlanan fazlar

| Sprint | Kapsam | Durum | Cikti |
|---|---|---|---|
| A | WAL yasam dongusu + kaynak sinirlari | Tamam | WAL sert tavani (v3.44), `wal_limit` 19/0, `docs/engineering/LIMITS.md` + `RESOURCE_LIMITS.md` |
| B | SQL yurutucu olcegi | Tamam | `sql_scale` 34/0 (100k/1M), `docs/engineering/SQL_SCALE.md` |
| C | PostgreSQL diferansiyeli | **Kismi** | `sql_differential` 33/0 `pg=not-run`; ayri CI isi `sql_differential_postgres` (canli kosmadi) |
| D | Indeks olcegi + disk B+Tree arastirmasi | Tamam (kapsam sinirli) | `sql_index_scale` 45/0, `btree_disk` 78/0, `DISK_BTREE_DESIGN.md` |
| E | Soak + bellek dayanikliligi | Tamam (gomulu motor, kisa kosu) | `soak` 20/0, F-21 ve F-22 duzeltmeleri (v3.50) |
| F | Kripto + ag guvenligi | Tamam | `CRYPTO_PROVIDER.md`, `NETWORK_SECURITY.md`, `RESOURCE_LIMITS.md` |
| G | Platform + CI + son rapor | Tamam (matris dar) | Bu rapor + `CI.md` bolum 3 matris kapsami |

### A.2 Tamamlanmayan / kismi kalan fazlar

- **Canli PostgreSQL diferansiyeli**: bu ortamda `psql`/sunucu yok; 33 kontrol
  karsilastirma beklemeden kosar ve `pg=not-run` yazar. Gercek farklilik
  analizi **olculmedi**.
- **Uzun sureli soak**: `soak` kapisi 25 sn kosar. 1 saat / 6 saat / 24 saat
  kosu **yapilmadi**.
- **Ag sunucusu soak'i**: `soak` gomulu motordur; `TVdbPgServer` altinda uzun
  sureli, cok baglantili kosu **olculmedi**.
- **Disk tabanli indeks**: `VDbBTreeDisk.pas` bagimsiz ve kapili bir bilesen
  olarak vardir, v5 motor dosya bicimine **bagli degildir**; ikincil indeksler
  hala bellektedir.
- **macOS / ARM64 / buyuk-endian**: **not-run** (bolum H).

### A.3 Mevcut V3 durumu

- Iki platformda tam kapi seti yesil: **Windows i386 48 kapi**, **Linux
  x86_64 49 kapi**, FAIL 0. Windows'ta `tls_client` bu ortamda OpenSSL DLL'i
  ile kostu (ayrinti: `CI.md`); OpenSSL istege bagli iki kapi Linux'ta SKIP.
- Acik kritik hata yok. Kapatilan son gercek kusurlar F-21/F-22 veri
  kaybiydi; ikisi de kalici regresyon kapisiyla kilitlendi (SO15/SO16/SO17).
  Sprint A/B'de kapatilan yetki ve atomiklik kusurlari `A.4`'te.
- V2 **dondurulmus** ve degismedi; v4 konteyner bicimi durduruldu.

### A.4 Denetim sprintleri (ONERILER_VE_HIZLANDIRMA2)

| Sprint | Kapsam | Durum | Cikti |
|---|---|---|---|
| A | 3.2 oturum kimligi, 3.3 upsert yetkisi, 3.4 MERGE RLS/trigger, 3.5 AFTER STATEMENT trigger sirasi | Tamam | `sql_authorization` 32/0 (yeni), `sql_atomicity` 23/0 (yeni) |
| B | SQL atomikligi: INSERT/UPDATE/DELETE/COPY/MERGE statement batch sinirlari, BEFORE STATEMENT trigger'lari | Tamam | `sql_atomicity` 88/0 (19 vaka) |
| C | 4.1 WAL-before-data checkpoint sirasi, 4.2 kurtarma basarisizliginda POISONED durumu | Tamam | `wal_recovery` 27/0 (yeni, 5 vaka) |
| D | 5.1 freelist butunlugu, 5.2 disk B+Tree sayfa butunlugu, 6.1/6.2 sayfa dogrulama | Tamam | `freelist` 32/0 (yeni, 9 vaka), `btree_disk` 78/0 |
| F | 8.2 LIMIT/OFFSET sinirlari, 8.4 ozyinelemeli CTE sinirlari + iptal, 8.5 sayisal tasma/CAST/ABS | Tamam (F1) | `sql_memory` 54/0 (yeni, 26 vaka) |
| F | 8.1 uctan uca streaming, portal maxRows, COPY OUT streaming, JOIN/ORDER BY/DISTINCT/GROUP BY bellek siniri, disk spill | **Acik (F2)** | tasarim isi; `R8`/`R13` |
| E | 7.1/7.2 sunucu okuma-yazma zaman asimi, 7.3 COPY gecici dosya sinir+izin, 7.4 baglanti yasam dongusu | Tamam | `network_limits` 22/0 (yeni, 8 vaka) |

Sprint A gercek kusurlari kapatti: baglanti artik yetkisiz baslamaz (global
`FSessionId` yetki kaynagi degil, yalniz LOGIN sayaci); `admin/admin123`
varsayilani kaldirildi; upsert yolu UPDATE yetkisi/RLS/ROW trigger uygular;
MERGE normal DML ile ayni RLS ve trigger kurallarina tabidir; AFTER STATEMENT
trigger'lari commit'ten once ateslenir.

Sprint B dort kusuru kapatti:

- **B1 (veri kalintisi)**: `INSERT` (tum yollar) ve `COPY` icin BEFORE
  STATEMENT trigger'i **batch acilmadan once** atesleniyordu; govdesindeki DML
  ana statement hata verse bile kalici olabiliyordu. Artik batch icinde.
- **B2 (eksik davranis)**: `UPDATE` ve `DELETE` icin BEFORE **STATEMENT**
  trigger'i **hic ateslenmiyordu** (yalniz satir seviyesi calisiyordu).
- **B3 (savunma)**: INSTEAD OF INSERT govdesi batch'siz satir satir
  calisiyordu. **Not**: parser `CREATE TRIGGER` icin yalniz BEFORE/AFTER
  ayristirir, `INSTEAD OF` uretilemedigi icin bu yol bu surumde ulasilamaz;
  duzeltme kod savunmasidir ve kapiyla dogrulanamaz.
- **B4 (veri kaybi)**: 0 satir eslesen `DELETE` dalinda kosulsuz `AbortBatch`
  cagriliyor, BEFORE STATEMENT trigger'inin yaptigi DML sessizce
  kayboluyordu; artik trigger calistiysa `CommitBatch`.

Kapinin kendisi dogrulandi: ayni test dosyasi duzeltme ONCESI kaynakla
(`git archive HEAD`) derlenip kosuldugunda **8 kontrol FAIL** (AT8 x3, AT9 x2,
AT10, AT18, AT19) ve cikis kodu 1; duzeltilmis agacta **88/0**. Yani kapi
gercekten kusuru yakaliyor, bos yesil degil.

Sprint C iki kusuru kapatti ve iki yeni sinir getirdi:

- **C1 / 4.1 (WAL-before-data, veri kaybi)**: checkpoint sirasi tersti.
  `FStore.Flush(True)` veri dosyasini fsync ediyor, WAL bariyeri
  (`AwaitDurable`) **ondan sonra** bekleniyordu. WAL fsync basarisiz olursa
  dayanikli olmayan commit'in veri sayfalari diskte kaliyor ve yeniden
  acilista "hayalet commit" goruluyordu. Yeni sira: WAL yaz, WAL fsync,
  durabil LSN dogrula, **sonra** veri sayfalarini yaz + fsync, sonra WAL'i
  yalniz durabil checkpoint sinirina kadar buda.
- **C2 / 4.2 (kurtarma basarisizligi)**: `RecoverAfterDurabilityFailure`
  hicbir istisna yakalamiyordu; hata `FLastCommitProblem` metni olarak
  yutuluyor ve motor yarim kurtarilmis halde kullanilabilir kaliyordu. Artik
  kurtarma hatasi motoru **POISONED** yapar: `Poisoned`/`PoisonReason`
  ozellikleri, `ecInvalidState` hata kodu ile tum okuma ve yazma giris
  noktalari (motor ve backend) reddeder; kapatip acma temiz baslangic verir.
- **Duzeltme (kurtarma sonrasi kilit)**: basarili kurtarma `FSyncErr`
  alanini temizlemedigi icin sonraki her `AwaitDurable` aninda hataya
  dusuyordu; artik basarili kurtarma bu durumu sifirlar.
- **Durust sinir**: `.gen` eslemesindeki durabil-LSN aynasi yalniz Windows'ta
  kurulur (`MapGen` tamamen `{$IFDEF WINDOWS}`). Linux'ta bu ayna yoktur;
  surecler arasi durabil-LSN paylasimi Linux'ta calismaz. Kapi bu yuzden
  motor duzeyindeki `Engine.DurableLsn` degerini olcer ve store aynasini
  yalniz raporlar (`store=0` Linux'ta beklenen degerdir).
- **Durust sinir**: kapi cokmeyi `SimulateCrash` ve hata kancalariyla taklit
  eder; gercek elektrik kesintisi dayanikliligi iddia edilmez. Gercek surec
  olumu `crash_points` kapisinda ayrica kosar, ancak isletim sistemi
  onbellegi fsync edilmemis baytlari koruyabildigi icin o kapi 4.1'i tek
  basina yakalayamazdi.

`wal_recovery` kapisi 5 vaka / 27 kontrol: hayalet commit yoklugu, checkpoint
bariyerinin veri yazimindan once kurulmasi, POISONED reddi ve kurtarma
sonrasi tekrar yazilabilirlik, basarili kurtarmanin durabil satiri koruyup
fsync edilmemis satiri atmasi, normal yolun zehirlenmemesi. Duzeltme oncesi
kaynakla derlenen sondada **3 kontrol FAIL** (wr1/durable-kept, wr1/no-ghost-row,
wr2/wal-durable-before-flush); duzeltilmis agacta 27/0.

Sprint D iki depolama butunlugu acigini kapatti:

- **D1 / 5.1 (freelist butunlugu, veri kaybi)**: serbest sayfa listesi
  (trunk zinciri) hicbir zaman dogrulanmiyordu. Ayni sayfa iki kez serbest
  birakilirsa ya da bir **trunk** sayfasi serbest birakilirsa, ayni fiziksel
  sayfa iki farkli sahibe verilebiliyor ve birinin satirlari digeri tarafindan
  ezilebiliyordu. `FreePage` artik (a) zaten serbest olan sayfayi, (b) trunk
  sayfasini, (c) **canli hucre tasiyan** heap sayfasini reddeder;
  `AllocPage` F-22 savunmasini ikinci hat olarak korur. Ayni sprintte
  `CollectFreePages` ve `VerifyFreeList` kurallari hizalandi: zincir dongusu,
  yinelenen girdi, aralik disi girdi ve `FreeCount` uyusmazligi **acik hata**
  olarak bildirilir (istisna degil, `False` + `Err` metni).
- **D2 / 5.2 + 6.1/6.2 (disk B+Tree sayfa butunlugu)**: diskten okunan
  sayfada CRC, sayfa kimligi ve yapisal tutarlilik dogrulanmiyordu; bozuk bir
  sayfa sessizce geziliyor ve `MarkReachable` onu **serbest** ilan edip geri
  kazanabiliyordu. `ReadPage` artik diskten okunan her sayfada `CheckPageStruct`
  calistirir (CRC + kimlik + yapisal sinir kontrolleri); `MarkReachable` kisa
  okuma, kotu CRC ve bozuk yapida `EBtdError` atar. **Sozlesme degisikligi**:
  bozuk B+Tree dosyasi artik **acilmaz**; `BD15`/`BD16` eski sessiz davranisi
  dogruladigi icin yeniden yazildi (`RestampCrc` ile "CRC gecerli, yapi bozuk"
  durumu uretiliyor).
- **Kapi kaniti**: `freelist` kapisi 9 vaka / 32 kontrol (FL1 cift serbest
  birakma, FL2 trunk serbest birakma, FL3 canli hucreli sayfa, FL4 cok trunk /
  bos trunk / sayac, FL5 zincir dongusu, FL6 yinelenen girdi, FL7 aralik disi
  girdi, FL8 bozuk freelist ile acilis, FL9 iki denetleyicinin ayni sonucu).
  Ayni test dosyasi duzeltme **oncesi** kaynakla (`git archive HEAD`)
  derlenip kosuldugunda **4 kontrol FAIL** (cift serbest birakma, trunk serbest
  birakma, canli sayfa, yinelenen girdi); duzeltilmis agacta 32/0. `btree_disk`
  78/0.
- **Kendi regresyonumuz (durust kayit)**: Sprint D'nin ilk hali `soak` kapisini
  kirdi (SO2/SO3/SO12/SO16/SO17, 5 FAIL; `freelist indeksi: girdi aralik disi`).
  Kok neden `FreeIndexEnsure` icindeki dongu sayacinin `LongWord` olmasiydi:
  `cnt = 0` iken `Integer(cnt) - 1 = -1`, sayac `LongWord` oldugu icin
  `$FFFFFFFF`'e donusuyor ve dongu sayfa disindaki cop girdileri okuyordu.
  Sayac `Integer` yapildi; `CollectFreePages` ve `VerifyFreeList`'teki ayni
  kalip `if cnt > 0` ile korunmus oldugu icin dokunulmadi. HEAD'agac soak'i
  20/0, duzeltilmis agac soak'i 20/0.
- **Durust sinir**: `VDbBTreeDisk` bagimsiz bir bilesendir; SQL motoruna
  **baglanmamistir**, ikincil indeksler hala bellekte tutulur. D2 bu bilesenin
  kendi sayfa yolu icin gecerlidir, motorun indeks yolu icin degil.

Sprint F iki parcaya ayrildi: **F1 (bu sprintte kapatildi)** 8.2/8.4/8.5
sinir ve sayisal uc davranislari; **F2 (acik)** 8.1/8.3 mimari bellek
sinirlari. F1 dort gercek kusur kapatti:

- **F1-a / 8.5 (CAST sessiz sarmasi, yanlis veri)**: `VDbParseInt` birikimi
  `res * 10 + d` ile **tasmayi denetlemeden** yapiyordu. Int64 araligini asan
  metin sarmalayip **yanlis sayi** donduruyordu:
  `CAST('9999999999999999999999' AS INTEGER)` -> `1864712049423024127`,
  `CAST('999999999999999999999999' AS INTEGER)` -> `2003764205206896639`.
  Artik birikim `QWord` + isaret basina tavan (`2^63-1` / `2^63`) ile yapilir,
  aralik disi metin gecersizdir ve `CAST` `ecTypeMismatch` atar.
  `-9223372036854775808` (`Low(Int64)`) gecerli kalir.
- **F1-b / 8.5 (ABS hassasiyet kaybi)**: `ABS` ilk olarak `VDbParseFloat`
  deniyordu; her tam sayi metni float olarak da gecerli oldugu icin **her
  zaman** float donuyordu: `ABS(9223372036854775806)` -> `9.22337203685478E18`.
  Artik once `VDbParseInt` denenir; sonuc tam sayi metni olarak doner.
- **F1-c / 8.5 (Low(Int64) isareti)**: `-v` ve `ABS` `Low(Int64)` uzerinde
  **sessizce sarmaliyordu** (isaret yanlis kaliyordu). Ikisi de artik
  `ecMathError` atar. Parser ayrica `-<tam sayi>` bicimini isaretle **birlikte**
  cozer; `ParsePrimary`'nin negatif dali onceden hic ulasilamiyordu.
- **F1-d / 8.4 (ozyinelemeli CTE sessiz kesmesi)**: `VDB_RECUR_MAX` (100.000
  tur) sinirina takilan ozyineleme **kismi sonucu hata vermeden** donduruyordu:
  `WITH r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r) SELECT n FROM r` ->
  `1..100001`, hata yok. Artik (a) sinir asimi `ecLimit` atar, (b) dogal bitiste
  `deltaRows` bosaltilir (yanlis pozitif yok), (c) tur basina `VDB_MAX_RESULT_ROWS`
  satir tavani uygulanir, (d) dongu `TickAbort` cagirir (iptal edilebilirlik).
- **Kapi kaniti**: `sql_memory` kapisi 26 vaka / 54 kontrol. Ayni test dosyasi
  duzeltme **oncesi** kaynakla (`git archive HEAD`) derlenip kosuldugunda
  **6 kontrol FAIL**: SM15 x2 (CAST 22/24 hane), SM20 x2 (`ABS` float +
  `ABS(Low)`), SM22 (sonsuz ozyineleme sessiz kesme), SM26 (`-v` sarmasi);
  duzeltilmis agacta 54/0. Kapinin geri kalan 48 kontrolu 8.2 LIMIT/OFFSET
  (LIMIT 0, negatif LIMIT/OFFSET, `OFFSET 2147483647`, tavan asimi,
  ORDER BY+LIMIT'in tam siralamanin **oneki** olmasi: ASC/DESC/cok anahtar/NULL)
  ve 3VL/NULL semantigini **dondurur**; bunlar duzeltme oncesinde de dogruydu
  ve gate'e yalnizca kilit olarak girdi.
- **Durust duzeltme (olcum kapisi)**: `perf_baseline` 47 kapili kosuda
  `btree/scale-linear` oranini **4,64** olctu ve kirmizi oldu. Ayni ikili tek
  basina uc kez kosuldugunda **1,50 / 1,98 / 2,32** cikti; yani gerileme degil,
  tam sureler birkac on ms iken tek bir zamanlayici duraklamasinin sisirmesi.
  Olcum her boyut icin **iki kez** yapilip **kucuk** olani alinir. **Esik
  degismedi (3,5)**; karesel davranis hala yakalanir. Bu, kapinin gecmesi icin
  esik gevsetme **degildir**; olcum gurultusunun alinmasidir.
- **Durust sinir (F2 acik)**: 8.1 uctan uca satir iteratoru/streaming hatti,
  PG portal `maxRows`, COPY OUT streaming, ORDER BY/DISTINCT/GROUP BY icin
  kontrollu **disk spill**, JOIN bellek butcesi ve hash birlestirme
  **uygulanmadi**. Sonuc hala `TSqlResult` icinde tamamen bellekte toplanir;
  tavan `VDB_MAX_RESULT_ROWS = 2.000.000`. Ozyinelemeli CTE satir tavani bu
  tavanla **ayni degeri** kullanir (daha kucuk bir butce yoktur).

Sprint E (ag katmani) dort gercek sinir kusurunu kapatti:

- **E1 / 7.1-7.2 (yavas istemci = kalici DoS, kullanilabilirlik)**: sunucu
  soketlerinde okuma/yazma zaman asimi **yoktu**. Kabul edilen her baglanti
  icin zamanlayici kurulmuyor; bir istemci tek bayt gonderip beklediginde
  `HandleQuery` sonsuza kadar blokluyor ve baglanti slotu **asla** bosalmiyordu.
  `MaxConns = 1` iken tek yarim acilmis baglanti sunucuyu kalici olarak
  kapatabiliyordu. Duzeltme: `VdbSockSetTimeouts` (`VDbNet.pas`,
  `SO_RCVTIMEO`/`SO_SNDTIMEO`; Windows'ta DWORD ms, Unix'te `timeval`) ve
  `TVdbPgServer` uzerinde `ReadTimeoutMs`/`WriteTimeoutMs`, varsayilan
  **30000 ms**, 0 = devre disi (eski davranis). Zaman asimi kabul edilen
  sokete, is parcacigi baslamadan once uygulanir.
- **E2 / 7.3 (sessiz cerceve dusurme, teshis edilebilirlik)**: on-kapa asan
  cerceve yalniz `Break` ile baglantiyi **sessizce** kapatiyordu; istemci
  nedenini ogrenemiyordu. Artik `MaxMessageBytes` (varsayilan **64 MiB**)
  asildiginda kontrollu bir `ErrorResponse` (`SQLSTATE 54000`) gonderilir ve
  baglanti kapatilir. **Durust sinir**: govde okunmaz (bellek sisirilmez);
  kapanis bilinclidir.
- **E3 / 7.3 (sinirsiz gecici dosya + izin)**: `COPY ... FROM STDIN` gecici
  dosyaya yazarken **toplam** boyut siniri yoktu; kimligi dogrulanmis bir
  istemci diski doldurabiliyordu. Artik `CopyMaxBytes` (varsayilan
  **256 MiB**) toplam sinir, parca basina ayrica tavan uygulanir; asimda
  kontrollu hata. Unix'te gecici dosya `fpChmod 0600` ile olusturulur
  (`BaseUnix`); Windows'ta `GetTempDir` zaten kullaniciya ozeldir.
- **E4 / 7.4 (kilitlenmeyen kapasite okumasi, veri yarisi)**: kapasite
  kontrolu `FConns.Count` alanini **kilitsiz** okuyor ve bitmis (Finished)
  is parcaciklarini da sayiyordu; bu yuzden bos slot varken "kapasite dolu"
  donulebiliyor ya da tersi olabiliyordu. `GetConnCount` artik kilit altinda
  ve yalniz canli baglantilari sayar (`ConnCount` ozelligi).
- **7.4 yasam dongusu incelemesi (kusur bulunmadi)**: `Stop`/`GcFinished`
  sirasi incelendi; `Stop` once dinleme soketini kapatip kabul dongusunu
  uyandiriyor, ardindan biten is parcaciklarini topluyor. Bu sirada bir
  **kusur bulunmadi**; kod degistirilmedi ve "duzeltildi" diye
  raporlanmaz.
- **Kapi kaniti**: `network_limits` kapisi 8 vaka / **22 kontrol** (NL0-NL7):
  zaman asimi kurulumu (okuma/yazma, devre disi, gecersiz soket), yavas
  istemcinin slotu birakmasi, `MaxConns=1` ile ikinci istemcinin girebilmesi,
  asiri cercevenin `54000` ile reddedilmesi, `CopyMaxBytes` toplam tavaninin
  uygulanmasi ve normal baglantinin etkilenmemesi. Duzeltme **oncesi**
  kaynakla (`git archive HEAD`) derlenen sondada **1 kontrol FAIL**:
  `H1` yarim startup sonrasi yeni istemci **6031 ms** sonra hala giremiyor
  (`MaxConns=1`, kalici DoS). Duzeltilmis agacta 22/0.
- **Durust sinir**: E1-E3 soket duzeyinde olculur; TLS el sikismasi icin
  **ayri** bir zaman asimi testi yoktur (el sikismasi ayni soket uzerinde
  kosar, dolayisiyla zaman asimi uygulanir, ama bu ayrica olculmedi).
  VDB'nin `COPY ... FROM STDIN` varsayilan bicimi PostgreSQL text degil
  **csv**'dir; tavan davranisi bu bicimle olculdu. F2 halen aciktir.

---

## B. WAL

| Konu | Olculen davranis | Kanit |
|---|---|---|
| WAL sert tavani | `VDB_WAL_MAX_BYTES`, varsayilan **64 MiB**. `VDbPageEngine.DoCommit` butun cerceveler tamponda ve `FWal.Bytes` kesinken, WAL'e **tek bayt yazilmadan once** kontrol eder; asimda `ecLimit`, commit kaydi yazilmaz, onceki onayli commit'ler durabil kalir | `wal_limit` 19/0 |
| Yumusak esik | `MaybeCheckpoint` tavanin **yarisinda** senkron checkpoint calistirir; kucuk yazimlar tavana yaklasmaz | `wal_limit`, `cache_metrics` 21/0 |
| Islem tavani | Tek islemde **1 048 576** degisen sayfa; 1M sayfalik islem ~4 GiB WAL uretir ve tavanda reddedilir (parcalanmalidir) | `txn_limit` 18/0 |
| Uzun islem | 300 kisa islem + 75 geri alma birebir dogrulanir; ic ice `BEGIN` ve islem yokken `COMMIT`/`ROLLBACK` sessiz no-op; tek yazar rezervasyonu + kontrollu `mesgul` | `txn_limit` TL1-TL8 |
| Checkpoint | `Checkpoint(True)` acik cagriyla ve esik/yumusak sinirda calisir; basarisiz checkpoint yan dosyalara dokunmaz | `soak` SO16, `single_file` 35/0 |
| Recovery | Kesik kuyruk geri kirpilir; `WriteChecked` tek yazma noktasi; commit kaydi yoksa satir durabil olmaz | `wal_crash`, `kv_wal`, `crash_points` 24/0 |
| WAL reclaim | Kapanista checkpoint basariliysa ve ayni dosyaya acik baska oturum yoksa `.wal`/`.gen` silinir; basarisizsa yan dosyalar korunur (veri kaybi yerine fazladan dosya) | `single_file`, `multi_writer` 12/0 |
| Crash testleri | Enjekte edilmis cokme noktalari, WAL yazma hatasi, disk dolu | `crash_points` 24/0, `disk_full` 16/0 |
| WAL-before-data (4.1) | Checkpoint WAL bariyerini (fsync + durabil LSN dogrulama) veri sayfalari yazilmadan **once** kurar; WAL fsync basarisizsa veri dosyasina dokunulmaz, yeniden acilista hayalet commit gorunmez | `wal_recovery` WR1, WR2 |
| POISONED (4.2) | Kurtarma basarisiz olursa motor `POISONED` olur: okuma ve yazma `ecInvalidState` ile reddedilir; kapatip acma temiz baslangic verir | `wal_recovery` WR3, WR4, WR5 |

**Durust sinir**: WAL ozellikle tek yazar rezervasyonu modeline dayanir;
cok yazarli yuksek cakisma altinda gecikme davranisi olculmedi. `VDB_WAL_MAX_BYTES=0`
tavani kapatir; bu modda "sinirsiz WAL" davranisi kasitlidir, koruma yoktur.
`.gen` eslemesindeki durabil-LSN aynasi yalniz Windows'ta kurulur; Linux'ta
store aynasi okunamaz (`Engine.DurableLsn` motor duzeyinde dogru calisir).
`wal_recovery` cokmeyi hata kancalariyla taklit eder; gercek elektrik
kesintisi dayanikliligi iddia edilmez.

---

## C. SQL Executor

| Konu | Olcum | Kanit |
|---|---|---|
| 100k satir | Ekleme **656 ms** (Windows i386) / **1213 ms** (Linux x86_64); dosya 3.997.696 B | `sql_scale` SS1-SS10 |
| 1M satir | Ekleme **6547 / 11849 ms**; dosya 37.543.936 B | `sql_scale` SS11-SS20 |
| 1M LIMIT'siz `SELECT *` | **516 / 900 ms**, tam 1M satir doner (ilk/orta/son deger dogrulanir) | `sql_scale` |
| ORDER BY / LIMIT / OFFSET / toplama / GROUP BY / HAVING / JOIN / UPDATE / DELETE | Hepsi dogru sonuc; karisik islem; buyuk islem commit/rollback; yeniden acilis + tam `VERIFY` temiz | `sql_scale` 34/0 |
| Toplam kontrol | 34 kontrol, iki platformda ayni satir/deger | `sql_scale` 34/0 |
| RAM | `TotalAllocated` deltasi (**RSS degil**); alet SS20'de 8 MB ayirmayla dogrulanir | `sql_scale` SS20 |
| LIMIT'siz tavan | `VDB_MAX_RESULT_ROWS = 2.000.000`; asimda `ecLimit`, kismi sonuc donmez | `limits` L4 18/0 |
| OOM | Enjekte edilen tahsis hatasi okuma ve yazma yolunda `EOutOfMemory`; sayfa ayirma atomik, taninmayan sayfa kalmaz, basarisiz commit hayalet satir birakmaz | `oom` 9/0 |
| Streaming | **YOK**. Yurutucu sonuc kumesini biriktirir; bu yuzden 2M+ satirlik LIMIT'siz tarama kapiya baglanmadi (32-bit surecte ~GB bellek) | `docs/engineering/SQL_SCALE.md` |

**Durust sinir**: F9 kismi kapali kalir - tavan **degerinin kendisi** (2M+)
maddelestirilmedi. Streaming olmadigi icin cok buyuk sonuc kumesi bellek
baskisi uretir; tavan bunu reddeder ama "akis halinde isler" denemez.

---

## D. PostgreSQL

| Konu | Durum |
|---|---|
| Gercek PostgreSQL surumu | **Kosulmadi**. Ayri CI isi `sql_differential_postgres` `postgres:16` servisi tanimlar; bu ortamda hic kosmadi |
| Calistirilan test sayisi | `sql_differential` **33/0**, ancak karsilastirma yapilmadan: `pg=not-run` |
| Uyumluluk | PG wire uyumlu **alt kume**; startup, basit ve genisletilmis sorgu, hata yollari |
| Farkliliklar | Canli PG ile olculmedi; bilinen sapmalar `docs/engineering/SQL_DIFFERENTIAL.md` icinde |
| Desteklenmeyen SQL | Kapsam `docs/engineering/SQL_COVERAGE.md`; indeks/DDL alt kumesi sinirli |
| SKIP davranisi | `run_pg.sh` baglanti yoksa **77 (SKIP)** doner ve PASS sayilmaz; is yesil gorse bile kanit uretmez |

**Durust sinir**: Burada "PostgreSQL ile uyumlu" iddiasi **kurulmaz**. 33
kontrol, diferansiyel altyapisinin ve SQL yuzeyinin kendi icinde tutarli
oldugunu gosterir; PostgreSQL'e karsi fark analizi yapilmamistir. Bu raporun
en buyuk olculmemis alani budur.

---

## E. SQL Index

| Konu | Olcum / durum | Kanit |
|---|---|---|
| Bellek tabanli indeks | **Var**: birincil anahtar ve `CREATE INDEX` ile ikincil indeksler `FMemIdx` / `TVDbBTree` icinde | `sql_index_scale` IX1-IX20 |
| Disk tabanli indeks | **Bagimsiz bilesen** `VDbBTreeDisk.pas` (4096 B sayfa, golge sayfalama, atomik commit, yirtik meta geri donusu). v5 motor dosya bicimine **bagli degil** | `btree_disk` 78/0 |
| 1M benchmark | `CREATE INDEX ix_m_v` **1016 / 1700 ms**; indeksten nokta okuma **0 / 1 ms**; yeniden acilis sonrasi ilk indeksli sorgu **1203 / 1586 ms**; indeks basina satir maliyeti **24 / 49 B**; `.odb.idx` 1M icin **10.985.254 B** (iki platformda ayni) | `sql_index_scale` 45/0 |
| 10M benchmark | **Yok** - kosmadi | - |
| Lookup performansi | Yukaridaki nokta okuma degerleri; plan dogrulamasi (`Index Scan using t_pkey`, `Index Only Scan using ix_t_w`, indekssizde `Seq Scan`) | `sql_index_scale` |
| Disk boyutu | `.odb.idx` **yeniden uretilebilir onbellek**tir; veri kaynagi degildir. Bozulursa veri kaybi olmadan tarama ile dogru sonuc | `sql_index_scale` IX18a/IX18b |
| Mimari oneri | Ikincil indeksleri `VDbBTreeDisk` uzerine tasimak **onkosullu** bir is: snake-case birlesme, sayfa yeniden dagitimi ve v5 dosya bicimine baglama gerekir. `DISK_BTREE_DESIGN.md` tasarimi yazar, uygulanmadi | `DISK_BTREE_DESIGN.md` bolum 7 |

**Durust sinir**: "VDB disk indeksi kullaniyor" demek bugun **yanlistir**.
Kapilar disk indeks olcmez; yalnizca bagimsiz `VDbBTreeDisk` bilesenini olcer.
100k indeks kurulumunda Windows'ta yigin deltasi **-104 KB** cikti (ayirici
bloklari yeniden kullandi), bu yuzden yalnizca 1M satir basina maliyet
raporlanir.

---

## F. Network

| Konu | Olcum | Kanit |
|---|---|---|
| Fuzz sayisi | **N1a-N15** (15 saldiri ailesi) + **120** yinelemeli tohumlanmis mutasyon + **4 is parcacigi x 8 eszamanli fuzz**; kapida **39 kontrol** | `net_fuzz` 39/0 |
| Crash sayisi | **0**. Her senaryodan sonra sunucunun hizmeye devam ettigi ayrica dogrulanir; her bozuk girdi yalniz o baglantiyi dusurur | `net_fuzz` |
| Seed | **Sabit/deterministik** (tekrar uretilebilir). Rastgele seed modu yok | `net_fuzz` |
| Soak suresi | Ag sunucusu soak'i **kosulmadi**. Gomulu motor `soak` kapisi **25 sn** (varsayilan, `VDB_SOAK_SECONDS`, 5..86400) | `soak` 20/0 |
| FD/RAM/thread olcumu | **Gomulu motor** soak'unda her turda: heap `TotalAllocated` deltasi (**RSS degil**), dosya tanitici/sap, is parcacigi, WAL bayti, dizin bayti, p50/p95 gecikme. SO5-SO10 tavan kontrolleri | `soak` SO5-SO10 |
| Kimlik dogrulama | SCRAM-SHA-256 (parola sunucuda saklanmaz); `AuthMaxFailures=5`, pencere 60 sn, **monotonik** `GetTickCount64` (F-20) | `auth_throttle` 16/0 |
| TLS | **Varsayilan kapali** (opt-in). Istemcide CA dosyasi zorunlu; dogrulamasiz baglanti yolu yok | `tls_client` 6/0 (yalniz Linux), `VDbTls.pas` |
| Baglanti tavani | `MaxConns` 64 (1..4096); asimda yeni baglanti `kapasite dolu` alir, mevcutlar calisir | `server_failure` 16/0 |
| Cerceve tavani | Agdan gelen tek metin cercevesi 64 MiB (`VDBS_MAX_RECV_STR`); PG telinde `MaxMessageBytes` (varsayilan **64 MiB**) asiminda kontrollu `ErrorResponse` (`SQLSTATE 54000`) ve baglanti kapanisi (Sprint E2) | `net_fuzz` N7, `network_limits` NL4 |
| Zaman asimi | Baglanti basina `ReadTimeoutMs`/`WriteTimeoutMs`, varsayilan **30000 ms**, 0 = kapali; yavas/yarim acilmis istemci slotu **birakir** (Sprint E1) | `network_limits` NL0-NL3, NL7 |
| COPY tavani | `COPY ... FROM STDIN` toplam `CopyMaxBytes` **256 MiB** + parca basina tavan; Unix'te gecici dosya `0600` (Sprint E3) | `network_limits` NL5, NL6 |
| Kapasite sayaci | `ConnCount` kilit altinda, yalniz canli baglantilar (Finished haric); `MaxConns` karari bu sayidan (Sprint E4) | `network_limits` NL1, NL2, NL7, `server_failure` 16/0 |

**Durust sinir**: `net_fuzz` sabit seed'li, sinirli bir senaryo kumesidir;
AFL/libFuzzer tarzi surekli fuzz kampanyasi **degildir**. Ag sunucusunun uzun
sureli FD/RAM/thread davranisi **olculmedi**; bu yuzden "ag sunucusunda sizinti
yok" iddiasi kurulmaz. mTLS, CRL/OCSP, IP basina hiz siniri, DDoS korumasi ve
denetim kaydi butunlugu **yoktur** ve iddia edilmez
(`NETWORK_SECURITY.md` bolum 3).

---

## G. Crypto

| Konu | Durum | Kanit |
|---|---|---|
| Mevcut algoritmalar | SHA-256, HMAC-SHA256, AES-256-GCM (nonce 12, tag 16), PBKDF2-HMAC-SHA256, Argon2id, CSPRNG, tek blok AES-256 (yalniz selftest) | `VDbCryptoProvider.pas`, `docs/engineering/CRYPTO_PROVIDER.md` |
| Varsayilan provider | **`builtin`** - saf Pascal, sifir harici DLL | `VDbCryptoProvider.pas` (R-5/K1) |
| OpenSSL | Yalniz **acik opt-in** (`VDB_CRYPTO_PROVIDER=openssl` veya API). Sessiz fallback **yok**; `VDB_CRYPTO_DLL` yalnizca yol ipucu | `VDbCryptoOpenSSL.pas` |
| Yetenek farki | `builtin` Argon2id + `capAes256Block` sunar, >64 B HMAC anahtari **sunmaz**. OpenSSL >64 B HMAC sunar, Argon2id ve `capAes256Block` **sunmaz** | Yetenek matrisi |
| Test vektorleri | `crypto_core` PASS, `crypto_base64` PASS, `crypto_kat` PASS, `selftest_builtin` PASS, `fixtures_builtin` PASS | `CI.md` kapi tablosu |
| Dosya bicimi uyumlulugu | `format_compat` 28/0 (v3/v4 yukseltme, v6 reddi, yirtilma) | `format_compat` |
| Acik riskler | `capHmacKeyOver64` borcu (ADR 6); KDF parametreleri cagiranin sorumlulugunda; anahtar surec belleginde (mlock/zeroize garantisi platforma bagli, iddia edilmez); OpenSSL 3.2+ Argon2 yeniden degerlendirilmeli | `CRYPTO_PROVIDER.md` bolum 5 |
| Bagimsiz denetim ihtiyaci | **VAR**. `crypto_kat`/`selftest_builtin` bir duman/vektor testidir; FIPS 140-3, CAVP veya bagimsiz kripto denetimi **degildir** | `CRYPTO_PROVIDER.md` bolum 3 |

**Durust sinir**: DCPcrypt tamamen kaldirildi (`NOTICE`). "Sertifikali
kripto" iddiasi yoktur. Provider secimi yetenek degistirir; operator
`openssl` secerse Argon2id gerektiren yollari kullanmamalidir.

---

## H. CI

| Platform | Kapi | PASS | FAIL | SKIP | NOT-RUN |
|---|---|---|---|---|---|
| Windows i386 (`windows-latest` / Git Bash) | 48 | **48** | 0 | OpenSSL istege bagli 2 | - |
| Linux x86_64 (`ubuntu-latest` / WSL x86_64) | 49 | **49** | 0 | OpenSSL istege bagli 2 (`VDB_CRYPTO_DLL` yok) | - |
| macOS (x86_64 / arm64) | - | - | - | - | **not-run** |
| linux/arm64 | - | - | - | - | **not-run** |
| windows/arm64 | - | - | - | - | **not-run** |
| Buyuk-endian | - | - | - | - | **not-run** |
| Canli PostgreSQL (`sql_differential_postgres`) | - | - | - | - | **not-run** (bu ortamda kosmadi) |

- Matris `.github/workflows/ci.yml` icinde **yalniz** `ubuntu-latest` ve
  `windows-latest` calistirir; `fail-fast: false`. macOS/ARM64 icin job
  **yoktur** cunku hic kosulmadi; dogrulanmamis platformu matrise eklemek
  yesil gorunen ama kanit uretmeyen bir kapi olurdu (`CI.md` bolum 3).
- Kanit: Windows `gatesE.log` (`KOSAN KAPI: 48`, `GATES_EXIT=0`), Linux
  `linE.log` (`KOSAN KAPI: 49`, `LIN_EXIT=0`). Sprint E oncesi kanit
  `gatesF.log` (47) / `linF.log` (48); daha once `gatesD.log` (46) /
  `linD.log` (47), ondan once `gatesB.log` (44) / `linC.log` (46) idi.
  Sayilar her sprint yalniz **eklenen** kapi kadar artar, kapi silinmez.
- Windows'ta `tls_client` bu kosuda OpenSSL DLL'leri ortamda oldugu icin
  **kostu** ve gecti; DLL'ler yoksa SKIP'e duser. Linux'ta 6/6 PASS.
- **NOT-RUN** satirlari "kosmuyor" degil "olculmedi" demektir; bu raporda
  PASS sayilmaz.

---

## I. Acik riskler

Her satir: onem, dosya, kok neden, etki, test, durum.

| # | Onem | Dosya / alan | Kok neden / etki | Test | Durum |
|---|---|---|---|---|---|
| R1 | **Yuksek** | `sql_differential` / CI | Canli PostgreSQL karsilastirmasi kosmadi; SQL uyumlulugu **olculmedi**, yalnizca kendi icinde tutarli | `sql_differential` 33/0 `pg=not-run` | **ACIK** |
| R2 | **Yuksek** | `tests/soak` | Uzun sureli (1h/6h/24h) kosu yapilmadi; uzun vadeli kaynak sizintisi iddia edilemez. Yalnizca 25 sn'lik kosuda SO5-SO10 tavanlari asilmadi | `soak` 20/0 | **ACIK** |
| R3 | **Yuksek** | `TVdbPgServer` | Ag sunucusu soak'i ve cok baglantili uzun sureli FD/RAM/thread davranisi olculmedi | - | **ACIK** |
| R4 | Orta | `net_fuzz` | Sabit seed + sabit uzunluklar; yeni hata sinifi yakalanmayabilir; surekli fuzz yok | `net_fuzz` 39/0 | **ACIK** |
| R5 | Orta | `VDbBTreeDisk` / motor | Ikincil indeksler bellekte; `.odb.idx` onbellektir. Disk indeks mimarisi tasarlandi, uygulanmadi. Sprint D sayfa dogrulamasini ekledi ama bilesen motora **bagli degil** | `btree_disk` 78/0, `sql_index_scale` 45/0 | **ACIK (tasarim)** |
| R6 | Orta | `VDbCryptoBuiltin` | `capHmacKeyOver64` yok; >64 B HMAC anahtari reddedilir (sessiz kirpma yok) | `crypto_*`, `selftest_builtin` | **ACIK (bilinen borc, ADR 6)** |
| R7 | Orta | `VDbPgWire` | TLS varsayilan kapali; operator acmazsa trafik duz metin. mTLS/CRL/OCSP yok | `tls_client` SKIP (Windows) | **ACIK (bilincli opt-in)** |
| R8 | Orta | `TVdbExecutor` | Uctan uca streaming **yok**; sonuc `TSqlResult` icinde tamamen bellekte toplanir, tavan `VDB_MAX_RESULT_ROWS = 2.000.000` (32-bit ~GB bellek). Sprint F1 yalniz 8.2/8.4/8.5 sinirlarini kapatti | `limits` L4 18/0, `sql_memory` 54/0 | **KISMI (F2 acik)** |
| R13 | Orta | `TVdbExecutor` / `TVdbPgWire` | PG portal `maxRows`, COPY OUT streaming, ORDER BY/DISTINCT/GROUP BY icin **disk spill**, JOIN bellek butcesi ve hash birlestirme uygulanmadi; `8.3`'teki `ExecMerge` O(n*m) olcumu yapilmadi | - | **ACIK (tasarim)** |
| R9 | Dusuk | `soak` olcum | Heap olcusu `TotalAllocated`, RSS degil; "RSS sizmaz" iddiasi yok | `soak` SO5 | **ACIK (olcum siniri)** |
| R10 | Dusuk | `bench_report` / `soak` | Gecikme tek makine, `-O1`; SLA degil, donanimlar arasi normallestirilmedi | `bench_report` 35/0 | **ACIK (olcum siniri)** |
| R11 | Dusuk | Platform matrisi | macOS/ARM64/buyuk-endian **not-run** | - | **ACIK** |
| R12 | Dusuk | `disk_full` sonrasi | Disk dolduktan sonraki operator toparlanmasi kapsam disi | `disk_full` 16/0 | **ACIK (kapsam)** |

Kapatilmis kritik bulgular (F1-F18) `docs/audit/V3_FINAL_AUDIT.md` bulgu
tablosundadir. Bu sprintte kapatilanlar:

- **F-21 (Yuksek, KAPALI)**: heap dizini yalniz canli anahtar sayisina gore
  buyuyordu; mezar taslari doldurunca `Insert` sessizce `False` donuyor,
  backend bunu "anahtar zaten var" sanip guncelleme dalina giriyor ve
  `toplu yazim basarisiz` veriyordu. `FUsed` canli + mezar tasi izler;
  doygunlukta `EVdbHeap` atar. Regresyon: SO15a-SO15d.
- **F-22 (Kritik, KAPALI)**: serbest birakilan sayfanin diskteki imaji
  silinmiyordu; yeniden acilista heap sayfasi sanilip icine satir yaziliyor,
  sonra `AllocPage` ayni sayfayi `PageInit` ile sifirlayarak onayli satirlari
  sessizce siliyordu (olculen: 2.000 satirdan 104'u, 520 tur churn; kayip
  icin checkpoint + yeniden acilis birlikte gerekiyordu). Duzeltme:
  `CollectFreePages`, `Open` atlamasi, `SpaceHintScan` filtresi, `AllocPage`
  savunmasi. Regresyon: SO16/SO17.

---

## J. Final classification

**BETA CANDIDATE**

Gerekce:

1. Kritik depolama/WAL/islem hatalari kapatildi ve her biri kalici bir
   regresyon kapisiyla kilitlendi; iki platformda **48/49** kapi yesil, FAIL 0.
2. Tek dosya sozlesmesi, kurtarma, sayfa butunlugu, sunucu hata yollari,
   bozuk ag girdisi, disk dolu, bellek tukenmesi, WAL sert tavani, B+Tree
   olcek/parcalanma, SQL 100k/1M olcegi, SQL indeks olcegi ve VACUUM geri
   kazanimi **olculdu**.
3. Olcum kapilari dort gercek kusur sinifi buldu ve kapatti: F17 (Unix fd
   sizintisi), F18 (sahte basarili VACUUM/dosya degistirme), F21 (sessiz dizin
   doygunlugu), F22 (serbest sayfanin sifirlanmasi = veri kaybi); ek olarak
   Sprint D'de cift/trunk/canli sayfa serbest birakma (freelist) ve disk
   B+Tree'de bozuk sayfanin sessizce geri kazanilmasi, Sprint F1'de CAST
   sessiz sarmasi, `ABS` hassasiyet kaybi, `Low(Int64)` isaret sarmasi ve
   ozyinelemeli CTE'nin sessiz kesilmesi, Sprint E'de zaman asimsiz
   baglantiyla **kalici DoS** (`MaxConns=1`), asiri cercevenin sessiz
   dusurulmesi, sinirsiz COPY gecici dosyasi ve kilitsiz kapasite okumasi.

**PRODUCTION CANDIDATE degildir** cunku:

- Canli PostgreSQL diferansiyeli **kosmadi** (`pg=not-run`);
- uzun sureli soak (1h/6h/24h) ve **ag sunucusu soak'i** kosmadi;
- disk tabanli ikincil indeks **yok** (tasarim var, uygulama yok);
- uctan uca streaming / disk spill / JOIN bellek butcesi **yok** (Sprint F2);
- macOS/ARM64 **not-run**;
- TLS varsayilan kapali ve mTLS/CRL/OCSP yok.

**PRODUCTION READY degildir** ve bu rapor boyle bir iddia kurmaz. Bagimsiz
denetim, gercek saha kullanimi ve uygunluk degerlendirmesi olmadan
**CERTIFIED / FIPS / SIL / formal compliance** iddiasi **olusturulmaz**.
