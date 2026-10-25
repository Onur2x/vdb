# v3.0 Kapsam Raporu (Sprint 2.9 / 2.10)

Tarih: 2026-10-24 · Dal: `v3` · Motor: sayfa tabanlı v3 (4 KB sayfa, WAL + checkpoint)

Bu rapor `sqltest --backend=v3` koşusunun **ölçülmüş** sonucunu ve v3'te
koşmayan testlerin gerekçelerini kaydeder. Sessiz yeşil yoktur: koşmayan her
test `ATLA` olarak **sayılır ve raporlanır**.

## 1. Sonuç

| Koşu | Komut | Geçen | Kalan | Atlanan |
|---|---|---|---|---|
| v2 (taban çizgisi) | `sqltest <dir> --backend=v2` | **3116** | **0** | 0 |
| v3 (yeni motor) | `sqltest <dir> --backend=v3` | **2252** | **0** | **58** |

v3 koşusunda test içi bölüm atlaması yoktur. Sprint 3.3'te `VACUUM`
(Compact) v3'e geldiği için `T19_Olcek` içindeki VACUUM bölümü ve
`T15_Bakim` testinin tamamı artık v3'te de koşar.

`--backend=v3` verilmediğinde program eskisi gibi v2 yolunu kullanır; v2
kapısı CI'da **3116/3116** ile aynen korunur.

Bilinmeyen backend adı reddedilir (`exit 2`).

### Koşucu değişikliği

Eski koşucu tüm testleri **tek bir `try`** içinde çağırıyordu: ilk istisna
kalan tüm testleri durduruyordu. Yeni koşucu her testi kendi `try/except`'inde
koşar (`TTestRec` dizisi + `BuildTests`), böylece tek hata diğerlerini
maskelemez; hata `!! KESILDI (<test>): <sınıf>: <mesaj>` olarak yazılır ve
sayaca eklenir.

## 2. v3'te neden koşmayan testler (58)

Üç grup vardır. Gruplama test gövdesinin gerçekten dokunduğu yüzeye göre
otomatik tarandı (`kv.`, `pkv.`, `myKv`, `TVDb.Create`); `T79_Savepoint` elle
eklendi (kapsam dışı bırakılan `SAVEPOINT` komutu).

### (a) Gövdesi doğrudan v2 veri dosyası / WAL / arşiv API'sine dokunur — 33

Bunlar `TVDb`'nin `kv.` arayüzünü (WAL kuyruğu, `Verify`, arşiv, zone map,
`.idx` durumu, `DataFileSize` vb.) doğrudan çağırır. v3'te `Kv = nil` olduğu
için test gövdesi anlamsızdır; **arayüzle** koşan eşdeğerleri v3 kapılarında
(`backendchk`, `v3sqlchk`) vardır.

| Test | Dokunduğu yüzey |
|---|---|
| T21_KritikHataDogrulama | `kv.` (3) + VERIFY |
| T24_Dayaniklilik | `kv.` (8) |
| T42_F1_BatchInsertAtomik | `kv.` (1) |
| T46_F2_SemaBozukSatir | `kv.` (4), `myKv` |
| T53_F2_DDLAtomik | `kv.` (3) |
| T64_F2_PKsizTablo | `kv.` (3) |
| T65_F2_UniqueIndex | `kv.` (3) |
| T70_YonetimBakim | `myKv` + VACUUM/REINDEX/AUTOCOMPACT |
| T78_AsofGecmis | `kv.` (15) |
| T92_MVCC_Isoaltion | `kv.` (21) |
| T95_WALArsiv | `kv.` (15) + BACKUP/ARCHIVE/RECOVER/RESTORE |
| T95b_Replication | `kv.` (1) + START REPLICATION |
| T101_TcpReplication | `kv.`, `pkv.` (6) + BACKUP/ARCHIVE |
| T105_ShowStats | `kv.` (2) |
| T122_KvStore | `kv.` (1) |
| T125_KolonSifreleme | `kv.` (17) |
| T132_H12_StreamTopN | `kv.` (1) + VACUUM/BACKUP/VERIFY/SAVEPOINT |
| T36_F1_RecoverKirpma | `myKv` + RECOVER |
| T37_F1_CommitBatchAtomik | `myKv` |
| T43_F1_MigrateLegacy | `myKv` |
| T57_F2_BozukDosya | `myKv` |
| T58_F2_VerifyBATCHEND | `myKv` |
| T59_F2_DizinFlush | `myKv` |
| T60_F2_WALKilit | `myKv` |
| T61_F2_GetDogruluk | `myKv` |
| T63_F2_BozukKayitTespit | `myKv` + RECOVER |
| T69_YonetimAPI | `myKv` |
| T72_WALReplay | `myKv` + RECOVER |
| T73_OtomatikWAL | `myKv` |
| T74_KayitSifreleme | `myKv` (kayıt şifreleme; v3.0'da sayfa şifreleme Sprint 3.4) |
| T75_SifrelemeDayaniklilik | `myKv` |
| T76_ReplayWALSifreleme | `myKv` |
| T77_AlterDatabaseKey | `kv.` (7) |

### (b) Test kendi v2 veritabanını açar (`TVDb.Create`) — 24

Bunlar ayrı bir v2 dosyası açıp v2 motorunun davranışını sınar (H-serisi
hızlandırma testleri, RLS/RBAC kalıcılığı, GENERATED, izolasyon, CBO/MCV,
SQLancer stil diferansiyel). v3 eşdeğerleri `v3sqlchk` (115/115) ve bu koşudaki
SQL testleriyle kapsanır.

`T94_RBAC_Persist`, `T94c_RLS_Persist`, `T117_Generated`, `T126_F42_TxIsolation`,
`T127_H5_BlockCrc`, `T128_H11_Undo`, `T129_H11_InPlace`, `T130_PkRangeCtype`,
`T131_H12_TopN`, `T133_H13_StreamGroupBy`, `T134_H12c_MultiTopN`,
`T135_H14_FloatSort`, `T136_H13_GroupDiff`, `T137_H15_StreamHaving`,
`T138_H16_StreamDistinct`, `T139_H17_StreamFilteredCount`,
`T140_H18_RawExactCount`, `T141_H19_RawLikeCount`, `T142_H20_RawBoolTree`,
`T143_H21_RawTreeSelectPaths`, `T144_H22_DeepOffsetLive`, `T145_H8_MCV`,
`T147_M8_SqlancerStil`, `T148_H25_AutoCompact`

### (c) kapsam dışı bırakılan yönetim komutunu sınar (elle eklendi) - 1

| Test | Komut | v3 karşılığı |
|---|---|---|
| T79_Savepoint | SAVEPOINT / ROLLBACK TO | v3.1 (sayfa düzeyi undo) |

Sprint 3.3'te `VACUUM`/`Compact` de v3'e geldiği için `T15_Bakim` artık
listede değil; v3'te tam koşar. `SAVEPOINT` ise **sessiz geçmez**:
`ecUnsupported` + "v3 sayfa motorunda henüz desteklenmiyor (v3.1)" hatası
verir (Sprint 2.7/2.9).

## 3. Bu adımda bulunan ve düzeltilen gerçek hatalar

v3 koşusu yalnız "kapsam" değil, **gerçek kusurlar** ortaya çıkardı:

1. **Zone map `Kv = nil` çökmesi (v3, AV).** `ExecSelect`'in zone-map yolu
   `FT.Kv.DataSeqValue`/`DataEpochValue`/`DataFileSize` alanlarını koşulsuz
   okuyordu. Sonuç: v3'te **sıradan** `WHERE tamsayi = 7` sorgusu erişim
   ihlali veriyordu (55+ doğrulama bu yüzden düşüyordu). Düzeltme: harita
   yalnız `Kv <> nil` iken kullanılır/inşa edilir; v3 tam tarama yapar.
   Kapsam: `T06_Where`, `T07_TipKarsilastirma`, `T08e_CTE`, `T08l_ViewDML`,
   `T09g_AnySomeAll`, `T09o_CoveringIndex`, `T20_CokluKayit`, `T31_F1_NotInNull`,
   `T44_F1_ParserDerinlik`, `T56_F2_AltSorgu`, `T68_F3_CokKolluOndek`,
   `T08k_MatView`, `T09p_SlowQuery`, `T17_Json`, `T23_Blob` hepsi yeşile döndü.

2. **`IMPORT JSON` v3'te AV.** `VDbJson.VDbImportJson` doğrudan
   `Tb.Kv.BeginBatch` çağırıyordu. Düzeltme: `Tb.BeginBatch` (backend-bağımsız).
   `T17_Json` ve `T23_Blob` artık v3'te tam koşar.

3. **Tablo düzeyi `UNIQUE(...)` sessizce yok sayılıyordu (v2'de de).**
   `CREATE TABLE t(a TEXT, b TEXT, UNIQUE(a))` cümlesinde parser `UNIQUE(...)`
   bloğunu **yutup atıyordu**: ne kolon bayrağı ne indeks oluşuyordu, yani
   kısıt hiç uygulanmıyor, tekrar eden değer kabul ediliyordu. Düzeltme:
   `TSqlCreateTableStmt.Uniques` + `CREATE TABLE` sonrası UNIQUE indeks kurulumu.
   Bu bir **veri bütünlüğü** hatasıydı ve her iki motoru da etkiliyordu.

4. **`ON CONFLICT(<unique hedef>)` hiç uygulanmamıştı.** `UpsertRowReturning`
   yalnız PK çakışmasını ele alıyordu; PK'sız tabloda `ON CONFLICT(a) DO UPDATE`
   yeni satır ekliyordu (3. maddedeki kısıt boşluğu bunu maskeliyordu).
   Düzeltme: `FindConflictPk` (indeks varsa aralık araması, yoksa tam tarama) +
   çakışma `CheckConstraints`'ten **önce** çözülür (`ExcludePk` ile satırın
   kendi değeri ihlal sayılmaz). Regresyon: `T10b_Upsert`'e tablo düzeyi
   UNIQUE + UNIQUE hedefli UPSERT kontrolleri eklendi (v2 ve v3'te koşar).

5. **Yönetim komutlarında çökme yerine açık hata.** `Kv = nil` iken
   `VERIFY`/`VACUUM`/`BACKUP`/arşiv/replication/`SHOW STATUS` gibi komutlar
   AV veriyordu. Düzeltme: `ExecAdmin` başında v3 için `ecUnsupported`.

6. **CI'da `crashtest` 42 dakika asıldı** (2.8 koşusu `cancelled`).
   Bir alt süreçte Windows çalışma-zamanı hata kutusu konsolsuz süreçte
   kapanmıyordu. Düzeltme: `crashtest` başında `SetErrorMode`
   (`SEM_NOGPFAULTERRORBOX` vb.) + CI adımında 300 sn sert süre sınırı.

## 4. v3.0 kapsamı dışı (bilinçli) ve planlanan sürüm

| Yetenek | Durum | Sürüm |
|---|---|---|
| `VERIFY` (sayfa CRC + heap) | **var** (Sprint 3.1) | 3.1 ✔ |
| `BACKUP` / `RESTORE` (tek `.odb`, checkpoint sonrası sayfa kopyası) | **var** (Sprint 3.2) | 3.2 ✔ |
| PITR (`RECOVER TO`) / WAL arşivi / `AS OF` | **Hepsi var (v4)**: mantıksal değişim günlüğü (`<db>.log`) + `AS OF TIMESTAMP/VERSION` + `ARCHIVE WAL SET/LIST` + `RECOVER TO` (canlıya yazmaz, `<db>.recovered` üretir). `AS OF SEQUENCE` de çalışır (sayfa imajlı WAL) | v4 ✔ |
| `VACUUM` / `Compact` (canlı kayıtlar yeni dosyaya, atomik değişim) | **var** (Sprint 3.3) | 3.3 ✔ |
| `AutoCompact` | **var** (v3.2) — v2 ile aynı varsayılan (KAPALI, %35, 4 MB); ölü alan = freelist sayfası × 4096 | 3.3 ✔ |
| Sayfa düzeyi **AES-256-GCM** şifreleme (zarf: nonce+şifre+tag = 4124 B) | **var** (Sprint 3.4) | 3.4 ✔ |
| `ALTER DATABASE KEY` | **var** (v3.2): dosya bütünü yeni parola ile yeniden şifrelenir (tmp + `.bak`, hata→eski kimlik) | 3.2 ✔ |
| Kolon düzeyi `ENCRYPTED` | **var** (v3.2): değerler dosya şifrelemesiyle korunur; şifresiz dosyada açık hata; `.colkey` biçimi v2 ile aynı | 3.2 ✔ |
| `START REPLICATION` / `PUMP` / slot / `SHOW` / `STOP` | **yok**; hepsi `ecUnsupported` + "v3.1: mantıksal günlük" (Sprint 3.5) | 3.5 ✔ (gerçek replikasyon v3.2) |
| Zone map (bölüm budama) | **kapalı**: v3 düz tam tarama yapar; sonuçlar birebir doğru (Sprint 3.7) | 3.7 ✔ (budama v3.2) |
| `SAVEPOINT` | **var** (v3.2) — v2 ile aynı sözleşme (yinelenen isim hata, hedef rollback sonrası kalır, RELEASE commit etmez) | 3.2 ✔ |
| B+tree / BETWEEN hızlandırma / `.idx` varint | yok | v3.2 |

## 5. Yeniden üretme

```
lazbuild -B sqltest.lpi
sqltest.exe <dir> --backend=v2   # SONUC: gecen=3196 kalan=0 atlanan=0
sqltest.exe <dir2> --backend=v3  # SONUC: gecen=2755 kalan=0 atlanan=33
```

Kapılar (v3.2 sonrası yeniden koşuldu, hepsi yeşil):
`pagechk 21/21`, `storechk 15/15`, `heapchk 20/20`, `idxchk 17/17`,
`crashtest 11/11`, `backendchk 108/108` (v3.1: 19 sayaç kontrolü eklendi),
`v3sqlchk 132/132`, `migchk 13/13`, `factorychk 13/13`.

## 4b. Uygulama giriş noktası: `VDbFactory` (2026-10-25)

Uygulamalar motorun somut tipini bilmez; tek giriş noktası `VDbFactory`'dir:

```pascal
VdbOpenOrCreate(Path, Be);             // v3; dosya yoksa oluşturur
VdbOpen(Path, Be);                     // v3; v2 dosyasını REDDEDER
VdbOpen(Path, Be, True, True);         // yalnız göç araçları: v2'ye izin
VdbOpenWithPassword(Path, Parola, Be); // şifreli v3
```

- Varsayılan **v3**'tür; v2 dosyası `EVdbFactory` ile reddedilir ve
  `vdbmig copy` komutu gösterilir.
- Giriş noktaları arayüzü **`out` parametreyle** verir: FPC 3.2.4'te arayüz
  döndüren fonksiyon fazladan bir referans bırakıyor, motor (dolayısıyla dosya
  kilidi) kapanmıyordu. `probe5`/`probe6` ile ölçüldü.
- `TVTableDb.Destroy` artık `FKvB`'yi bırakır; `tbl.Free` tek başına da
  dosyayı kapatır.
- `examples/` (01–06, 09–12) ve `yonetim/` bu giriş noktasına geçirildi;
  `factorychk` kapısı politikayı CI'da doğrular (13/13).
- `examples/07` ve `08` (TCP sunucu/istemci) **v2 motorunda kalır**:
  `VDbSqlServer` hâlâ `TVDb` kullanıyor; sunucunun `IVdbBackend`'e taşınması
  M7 kapsamındadır (v3.2). İstemci (08) protokolü değişmediği için v2
  sunucuyla çalışmaya devam eder.

**Göç aracı (`vdbmig`, 2026-10-25):** `migchk` motoru doğrular; `vdbmig` CLI'si
de gerçek bir v2 dosyasıyla sınandı ve CI'ya kapı olarak eklendi —
`copy` → 0, aynı hedefe ikinci `copy` → 2 (üzerine yazmaz), `verify` → 0.
Ölçüm: 5.031 kayıt 31 ms, 200.001 kayıt 547 ms kopya + 219 ms doğrulama
(v3 dosya v2'nin %85,5'i). Ayrıntı: `GOC_V2_V3.md`.

### Fuzz / diferansiyel oracle (Sprint 3.11)

v3'te ham kayıt yolu (`Kv`) olmadığı için `sqltest`'in mevcut diferansiyel
testleri zayıflar: `T111` aynı yolu iki kez koşar, `T147` (SQLancer stili)
zaten yalnız v2 yolunu sınadığı için ATLA listesindedir. Bunun yerine
depolama yolundan **tamamen bağımsız** bir oracle eklendi:

`v3sqlchk TestFuzzOracle` — **8/8**:
- 400 satır; `a INTEGER` ve `s TEXT` sütunlarında ~%20/%25 **NULL**.
- **240 rasgele 3VL yüklemi**: `= <> < <= > >=`, `IS [NOT] NULL`,
  `IN` / `NOT IN` (liste bilerek NULL içerir), `BETWEEN`/`NOT BETWEEN`,
  `AND`/`OR`/`NOT`, parantez; derinlik 3.
- Beklenen küme Pascal'da üç değerli mantıkla hesaplanır ve SQL ile
  **`COUNT(*)` + `ORDER BY id` satır kümesi** olarak birebir karşılaştırılır
  (sayı tutup satırın yanlış olması yakalanır).
- Tohum sabittir (`RandSeed := 20261025`) → koşu tekrarlanabilir.
- Yeniden açılıştan sonra 40 sorgu aynı sonucu verir + `VERIFY` geçer.

`crashtest` üç platformda da **11/11**; ölçülen kill -9 sonucu: commit
edilmiş **2025 satırın tamamı** yerinde.

### Platform kapıları (Sprint 3.8-3.10)

Her satır gerçekten koşulmuş bir kapıdır; hiçbirinde `kalan > 0` yoktur.

| Kapı | win32 | win64 `-O-` | win64 `-O1` | Linux/WSL x86_64 |
|---|---|---|---|---|
| `backendchk` | 108/108 | 108/108 | 108/108 | 108/108 |
| `v3sqlchk` | 128/128 | 128/128 | 128/128 | 128/128 |
| `pagechk` / `storechk` | 21/21 · 15/15 | 21/21 · 15/15 | 21/21 · 15/15 | 21/21 · 15/15 |
| `heapchk` / `idxchk` | 20/20 · 17/17 | 20/20 · 17/17 | 20/20 · 17/17 | 20/20 · 17/17 |
| `migchk` / `crashtest` | 13/13 · 11/11 | 13/13 · 11/11 | 13/13 · 11/11 | 13/13 · 11/11 |
| `sqltest --backend=v2` | 3116/0/0 | 3081/0/0 | 3081/0/0 | 3081/0/0 |
| `sqltest --backend=v3` | 2252/0/58 | 2217/0/58 | 2217/0/58 | 2217/0/58 |

**win32'deki 35 fazla kontrol hata değil, ortam farkıdır.** Tamamı DLL/OpenSSL
yükleyen alt dallardır: `130. Extension/Plugin` (25→8),
`179. pgwire TLS/OpenSSL` (10→0), `128. Cross-Platform DLL / C API` (16→13),
`131. paralel ABI` (58→53). Bu dallar ikili bulamayınca "vdbapi.dll yok →
atlandı" / "TLS testi (OpenSSL DLL bulunamadı)" yazar. Bu ortamda eklenti ve
OpenSSL ikilileri yalnız **32 bit** olduğu için win64 ve Linux aynı sayıyı
(3081/2217) verir — yani fark platformdan değil, **64 bit ikili yokluğundan**
kaynaklanır. Çekirdek v3 yollarında hiçbir kontrol eksilmemiştir.

#### Linux kapısının bulduğu üç gerçek kusur (düzeltildi)

1. **`cthreads`**: FPC/Unix'te `TEvent`/`TThread` kullanan programın ilk
   `uses` birimi `cthreads` olmazsa `ESyncObjectException: Failed to create
   OS basic event` atar. Sekiz kapı programına `{$IFDEF UNIX}cthreads,{$ENDIF}`
   eklendi (kütüphane tüketicisi `vdbapi.lpr`'de zaten vardı).
2. **Unix'te `TFileStream` = `flock`**: motor dosyayı `LOCK_EX` ile tuttuğu
   için canlı `.odb`'yi ikinci kez açmak (salt-okunur **boy ölçümü bile**)
   `EAGAIN` veriyordu; `VACUUM` bu yüzden Linux'ta düşüyordu. Yeni
   `VDbSync.VDbFileBytes` boyu `stat()` ile **açmadan** ölçer; `VACUUM` ve WAL
   boyut keşfi buna geçti. `VDbPageStore.Open` ayrıca ham OS hatası yerine
   açık kilit hatası verir (`VDbIsSharingViolation` FPC'nin `Try again`
   metnini de tanır). Kapı: `v3sqlchk TestDoubleOpen` **6/6**.
3. **`crashtest` kill -9**: alt süreç, **işaret dosyası** (yine flock'lu
   `TStringList.SaveToFile`) yüzünden ölüyordu; motor verisiyle ilgisi yoktu.
   İşaret dosyası artık Unix'te ham `fpOpen/fpRead/fpWrite` ile yazılır/okunur
   ve alt süreç tanı dosyası bırakır. Linux'ta da **11/11**.


### Replikasyon, PITR ve zone map kararları (Sprint 3.5-3.7 → v4 güncellemesi)

Durum **2026-10-26**: PITR dilimi tamamlandı (mantıksal değişim günlüğü);
replikasyon ve zone map hâlâ sırada.

| Yetenek | Bugünkü davranış | Test |
|---|---|---|
| `AS OF SEQUENCE n` | **Çalışır** (v3.2): WAL penceresindeki n'inci commit'in tam görüntüsü geçici bir kopyada kurulur (canlı dosyaya yazılmaz); n = commit sayısı, sınır aşılırsa son commit'e kırpılır | `sqltest T155` (iki backend) + `v3sqlchk` AS OF SEQUENCE kontrolleri |
| `AS OF TIMESTAMP t` / `AS OF VERSION v` | **Çalışır (v4)**: `<db>.log` mantıksal günlüğünden hedefe en yakın taban + ileri replay. `TIMESTAMP` metni yerel saat → UTC. Hedef en eski tabandan önceyse **açık hata**; son kayıttan ileriyse son duruma **kırpılır** (`Actual*` ile bildirilir) | `pitrchk` 21 kontrol, `v3sqlchk` TestPitrSql, `sqltest` T155 (v3 dalı) |
| `ARCHIVE WAL SET DIR='x'` | **Çalışır (v4)**: günlük setinin tam kopyasını `x`'e çıkarır; birincil günlüğe dokunmaz, tekrarlandıkça tazeler. `RESET` **yoktur** — günlük kalıcıdır, silinirse PITR yeteneği kaybolur | `pitrchk` arşiv kontrolleri, `v3sqlchk` |
| `ARCHIVE WAL LIST` | **Çalışır (v4)**: tek satır kapsam (`min_seq`, `max_seq`, `min_time`, `max_time`, `bases`) | `pitrchk`, `v3sqlchk` |
| `RECOVER TO [TIMESTAMP\|NOW]` | **Çalışır (v4)**: canlı dosyaya **yazmaz**; `<db>.recovered` üretir (taban + ileri replay). Kullanıcı doğrular, `RESTORE FROM` ile devreye alır | `pitrchk` (dosya açılıp `Verify` TEMİZ), `v3sqlchk` |
| Replikasyon komutları | `ecUnsupported` — mantıksal günlük artık var (v4), protokol sıradaki dilim | `v3sqlchk` 9 kontrol: hiçbiri dosya bırakmaz, veri bozulmaz, yeniden açılış sağlam |
| Zone map | **budama yok**: `Kv = nil` olduğu için v3 genel tam tarama yolunu kullanır | `v3sqlchk` 22 kontrol: 3000 satırda 8 aralık + eşitlik/`IN`/`<>`/karma sorgular Pascal'da hesaplanan beklentiyle **birebir** |

v4 günlük tasarımı (ayrıntı `VDbChangeLog.pas` başında):

- `<db>.log\seg-NNNNNN.vlog` segmentleri (16 MB, yalnız **grup sınırında**
  rotasyon) + `<db>.log\base\b-<seq>-<lsn>.odb` taban imajları.
- Kayıt: anahtar + **eski değer** + yeni değer + UTC ms + grup seq.
  Magic: `VLG1`/`VLR1`/`VLB1`/`VLE1`. **Yarım grup replay edilmez.**
- Replay KV düzeyindedir (ham bayt) — SQL yeniden kodlaması yok.
- Yazım **WAL commit'inden SONRA**. Günlük yazılamazsa **veri kaybı olmaz**;
  yalnız `FLogProblem` işaretlenir ve PITR/replikasyon istekleri net hata
  verir. Günlük açılamazsa yazma yolu hiç değişmez.
- `BASE` kaydı yeni nesil açar: `Flags` bit0=1 → nesil kopması (`RESTORE`),
  replay **durur**; bit0=0 → saf checkpoint (`VACUUM`, `ALTER KEY`, ilk
  taban), replay **devam eder**. `END` kaydı motor LSN'ini taşır; açılışta
  uyuşmazlıkta nesil kopması yazılır ve öncesi için PITR açıkça reddedilir.
- Günlük otomatik silinmez/kırpılmaz (silinirse PITR yeteneği kaybolur).

Ölçülen maliyet (`pitrbench`, 20.000 satır / 100 commit, QPC, tek koşu):

| Ölçüm | Değer |
|---|---|
| Yazma | 308 ms → 15,4 µs/satır, 3,08 ms/commit |
| Günlük boyu | 1.934.517 bayt → 96,5 bayt/satır |
| `AS OF TIMESTAMP` (tam sayım) | ortalama 556 ms (3/3 doğru) |
| `BuildLogSnapshot` (son durum) | 516 ms, 1.228.800 bayt |
| `ArchiveLogSet` | 3 ms, 1.934.517 bayt |

Ayrıca v4 sırasında **sessiz yanlış sonuç** bulundu ve düzeltildi:
indeksli `IN (…, negatif, …)` listesinde negatif öğe AST'de
`TSqlUnaryOpNode(suoNeg)` olduğu için daraltma hesabından **sessizce
atlanıyor**, indeks dilimi daralıyor ve o grubun satırları **okunmadan**
düşüyordu (hata yok). Aynı hata PK `IN` ve `= -3` yolunda da vardı. Tek
yardımcı (`VdbInConstText`) düz/negatif sabiti çözer, çözemezse daraltma
yapılmaz (güvenli taraf). Kapı: `v3sqlchk TestIndexInNegative` (17 kontrol).

Gerekçe: v3 WAL'i **sayfa imajı** tutar; `AS OF SEQUENCE` bununla çalışır.
Satır düzeyinde eski değer ve zaman damgası **yoktu** — bu yüzden v4'te
paralel bir **mantıksal** günlük eklendi. Zone map ise v2'nin ham kayıt
ofsetlerine dayanır; v3 heap hücre biçiminde yeniden inşa edilmesi gerekir
(sıradaki performans dilimi).

### Sayfa şifreleme (Sprint 3.4)

Varsayılan **kapalı**; v3 dosyası eskisi gibi düz metindir. Şifreli dosya
`CreateWithKey` (32 bayt AES-256) veya `CreateWithPassword` (PBKDF2-SHA256,
200000 tur) ile açılır:

```
b := TVdbBackendV3.CreateWithKey('veri.odb', anahtar, True);
b.Encrypted        // True
b.KeyFingerprint   // 8 hex
```

Zarf sırası: sayfa imajı → CRC32 (`PageSeal`) → AES-256-GCM
(`nonce 12 | şifre 4096 | tag 16` = **4124 bayt**). AAD sayfa numarasına ve
dosya tuzuna bağlıdır. Meta sayfa 0 düz metin kalır (yalnız sayfa sayısı,
freelist, LSN, tuz, iterasyon, anahtar doğrulayıcı; kullanıcı verisi yok).
WAL çerçeveleri de aynı zarfla yazılır. Anahtarsız/yanlış anahtarlı açma,
bozuk zarf ve farklı anahtarlı `RESTORE` **net hata** verir; sessiz bozuk
veri dönmez. `VACUUM` aynı anahtarla yeni dosya üretir.

Bilinçli sınır: `ALTER DATABASE KEY` (mevcut v3 dosyasını yeniden
şifreleme) bu sürümde yoktur (`ecUnsupported`); anahtar dosya oluştururken
seçilir.
