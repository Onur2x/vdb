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
| `START REPLICATION` / `PUMP` / slot / `SHOW` / `STOP` | **var (v4)**: mantıksal grup taşıma (sayfa imajı değil), dosya tabanlı slot + `PUMP`; boşluk/bozukluk/nesil kopması reddedilir, ikincil kendi seq uzayına yeniden numaralar | v4 ✔ |
| Zone map (bölüm budama) | **kapalı**: v3 düz tam tarama yapar; sonuçlar birebir doğru (Sprint 3.7) | sayfa düzeyinde v4 sonrası |
| `SAVEPOINT` | **var** (v3.2) — v2 ile aynı sözleşme (yinelenen isim hata, hedef rollback sonrası kalır, RELEASE commit etmez) | 3.2 ✔ |
| B+tree / BETWEEN hızlandırma | **var (v4)**: bellek içi gerçek B+tree (`VDbBTree.pas`) `TIdxSkip` içinde; disk biçimi/WAL/PITR/göç değişmedi. `WHERE kolon op sabit ORDER BY kolon LIMIT k` → önce indeks dilimi | v4 ✔ |
| `.idx` varint | yok | sırada |

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

Durum **2026-10-27**: PITR, B+tree, replikasyon, sayfa düzeyi zone map, `.idx`
varint, satır INT varint ve **çok oturumlu yazma (MVCC, v3.4)** dilimleri
tamamlandı; **snapshot isolation da tamamlandı (v3.15)**; **süreçler arası
çok yazarlılık da tamamlandı (v3.16 — kilit işlem kapsamlı, `<db>.gen`
sayacıyla önbellek tazeleme, `prochk` 8/8 gerçek iki süreç)**. Yol haritasında
açık madde kalmadı.

| Yetenek | Bugünkü davranış | Test |
|---|---|---|
| `AS OF SEQUENCE n` | **Çalışır** (v3.2): WAL penceresindeki n'inci commit'in tam görüntüsü geçici bir kopyada kurulur (canlı dosyaya yazılmaz); n = commit sayısı, sınır aşılırsa son commit'e kırpılır | `sqltest T155` (iki backend) + `v3sqlchk` AS OF SEQUENCE kontrolleri |
| `AS OF TIMESTAMP t` / `AS OF VERSION v` | **Çalışır (v4)**: `<db>.log` mantıksal günlüğünden hedefe en yakın taban + ileri replay. `TIMESTAMP` metni yerel saat → UTC. Hedef en eski tabandan önceyse **açık hata**; son kayıttan ileriyse son duruma **kırpılır** (`Actual*` ile bildirilir) | `pitrchk` 21 kontrol, `v3sqlchk` TestPitrSql, `sqltest` T155 (v3 dalı) |
| `ARCHIVE WAL SET DIR='x'` | **Çalışır (v4)**: günlük setinin tam kopyasını `x`'e çıkarır; birincil günlüğe dokunmaz, tekrarlandıkça tazeler. `RESET` **yoktur** — günlük kalıcıdır, silinirse PITR yeteneği kaybolur | `pitrchk` arşiv kontrolleri, `v3sqlchk` |
| `ARCHIVE WAL LIST` | **Çalışır (v4)**: tek satır kapsam (`min_seq`, `max_seq`, `min_time`, `max_time`, `bases`) | `pitrchk`, `v3sqlchk` |
| `RECOVER TO [TIMESTAMP\|NOW]` | **Çalışır (v4)**: canlı dosyaya **yazmaz**; `<db>.recovered` üretir (taban + ileri replay). Kullanıcı doğrular, `RESTORE FROM` ile devreye alır | `pitrchk` (dosya açılıp `Verify` TEMİZ), `v3sqlchk` |
| Replikasyon komutları | **Çalışır (v4)**: sayfa imajı değil **mantıksal grup** taşınır — `<dest>\<slot>\g-<seq>.vrgp` (64 B `VRG1` başlık + CRC'li gövde, tmp+rename atomik), taban imajı `<dest>\<slot>\bases\` (ilk taşımada). İkincil tabanı `RestoreFrom` ile kurar, grupları **tek işlem** uygular ve gelen grubu **kendi** seq uzayına yeniden numaralar. Konum `<db>.repl\<slot>.slot` (`last_seq`) — kalıcı. Taşıma dosya tabanlıdır (`SHIP_DIR`); TCP reddedilir. Retler: bozuk dosya, **sırada boşluk** (atlanmaz), nesil kopması (`Flags bit0=1`) | `replchk` 13 grup **37/0** (iki gerçek DB, ham KV birebir, artımlı, idempotent tekrar, bozukluk/boşluk/nesil), `v3sqlchk TestReplicationV3` **179/0** |
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
yapılmaz (güvenli taraf). Kapı: `v3sqlchk TestIndexInNegative` (indeksli
satır, PK ve COUNT yolları + negatif sabitli `=`/aralık/`BETWEEN`).

Gerekçe: v3 WAL'i **sayfa imajı** tutar; `AS OF SEQUENCE` bununla çalışır.
Satır düzeyinde eski değer ve zaman damgası **yoktu** — bu yüzden v4'te
paralel bir **mantıksal** günlük eklendi. Zone map ise v2'nin ham kayıt
ofsetlerine dayanır; v3 heap hücre biçiminde yeniden inşa edilmesi gerekir
(sıradaki performans dilimi).

### Sıralı indeks: bellek içi B+tree (v4, 2026-10-26)

Sıralı indeks skiplist'ten **B+tree**'ye taşındı: `VDbBTree.pas`
(`TVDbBTree`), `TVDbSkipList` ile aynı sözleşmeyi uygular ve `TIdxSkip`
içinde damla yerine geçer. `.idx` dosya biçimi, WAL, checkpoint, PITR ve göç
**değişmedi** — indeks türetilmiş veridir.

- Yaprakta 96 anahtar; dolunca 48/48 bölünür. İç düğümde 96 ayırıcı + 97
  çocuk. Yapraklar zincirli; aralık taraması zincirden akar.
- **Silme yeniden dengelenmez** (birleştirme/ödünç alma yok): boşalan yaprak
  ağaçta kalır, taramada atlanır. Arama değişmezleri bozulmaz (ayırıcı yalnız
  aşağı çekilir) ve veri kaybı riski düşük kalır.
- Her düğümde `SubCount`; `RankBefore`/`CountRange` O(log N). Eş anlamlı
  anahtarlar (aynı `Key`, farklı PK) toplam sırada durur; aralık sınırları
  anahtar karşılaştırıcısıyla ölçülür (skiplist ile birebir).

| Ölçüm (`btreechk`, QPC) | B+tree | skiplist |
|---|---|---|
| `LoadSorted` 10.100 girdi | **0,5 ms** | 1,1 ms |
| 100.000 dar aralık (21 anahtar) | 588,8 ms | **503,4 ms** |
| 10.000 geniş aralık (401 anahtar) | **278,1 ms** | 306,9 ms |
| 10.100 rastgele ekleme | 8,8 ms | 8,2 ms |

Dürüst sonuç: toplu yükleme ~2x hızlı, geniş aralık ~%9 hızlı, **dar aralık
~%17 yavaş** (düğüm inişinde daha çok anahtar karşılaştırması). Motor
düzeyinde fark görünmüyor: 1071 satırlık aralık iki yapıda da **2,3 ms**
(sorgu, satır okuma/kopyalama ile sınırlı).

Ek düzeltme: `WHERE <indeksli kolon> <op> sabit ORDER BY <aynı kolon> LIMIT k`
sorgusunda koşulsuz "akışlı top-N" (tam tarama) seçiliyordu. Artık WHERE
sıralama kolonunu sınırlıyorsa önce indeks dilimi denenir. Ölçülen
(`idxbench`, 50.000 satır): **16,6 → 3,0 ms**.

Kapı: `btreechk` (12. kapı) **30/0** — bağımsız oracle'a karşı `LoadSorted`,
ekleme/silme/`All`, 64 sınır kombinasyonu, `CountRange` = `CollectRange`
uzunluğu, `RankBefore`, eş anlamlı anahtarlar, sayısal karşılaştırıcı,
**yapı değişmezleri** (`CheckInvariants`) ve **skiplist paritesi**.

### Çok okuyucu / tek yazıcı + busy timeout (v3.2, 2026-10-26)

Kilitleme artık **paylaşımlı okuyucu / tam yazıcı**: N salt-okunur oturum aynı
anda okur, yazar tam kilit ister; kilit alınamazsa `ABusyMs` bekler ve net
"veritabani mesgul" hatası verir. Varsayılan bekleme **0** (hemen hata) —
v2/önceki v3 ile aynı; beklemek isteyen çağıran açıkça süre verir.

- Karar veren kilit `LockFileEx`/`flock`'tur; dosya iki tarafta da
  `fmShareDenyNone` açılır (eski `fmShareDenyWrite` OS düzeyinde ikinci açılışı
  engelliyor, busy timeout'a yer bırakmıyordu).
- `VdbOpenReadOnly` / `TVdbBackendV3.CreateReadOnly`: hiç yazmaz, `<db>.log`
  açmaz, WAL'i `fmOpenRead` açar. Onaylanmış WAL çerçeveleri `InstallReadOnlyPage`
  ile bellek katmanına alınır; `LoadFrame` önce oraya bakar. Çökme sonrası bile
  `.odb`/`.wal` **bayt bayt** değişmez.
- Yazma denemesi salt-okunur oturumda açık hata verir; `VERIFY` çalışır.
- Busy beklemesi gerçek süreyle ölçülür (`GetTickCount64`): ölçülen
  `busy=400 → 397 ms`, `busy=350 → 356 ms`, `busy=0 → 1–2 ms`.
- Çok **oturumlu** yazma v3.4'te geldi (aynı backend, READ COMMITTED, ilk commit
  kazanır). **Süreçler arası çok yazarlılık v3.16'da geldi:** ikinci süreç artık
  reddedilmez; kilit **işlem kapsamlı** alınır (oturum boyu değil), önbellek
  `<db>.gen` değişiklik sayacıyla tazelenir. Yazarlar **sıralıdır**: bir yazma
  işlemi açıkken diğer süreçler `ABusyMs` bekler, sonra net hata alır.

Kapı: `lockchk` (14. kapı) **29/0** ve `prochk` (16. kapı) **8/0**. Gerçek
**çocuk süreçler** kullanılır, yani kilit gerçek işletim sistemi kilididir: aynı
anda iki okuyucu, iki yazarın **sırayla** commit etmesi, yazar varken
salt-okunur oturumun **açılabilmesi**, salt-okunur yazma reddi + `VERIFY`,
`<db>.log` oluşmaması, çökme sonrası WAL'den okuma ve diskte sıfır bayt
değişim. `prochk` iki süreç paralel yazar; **satır kaybı yok**
(5 + 40 + 40 = 85). 32 ve 64 bit yeşil.

Yol boyunca bulunan iki gerçek kusur: (1) `VdbOpenReadOnly` biçim keşfi için
dosyanın ilk 4 baytını okuyordu; yazar tam aralık kilidi tutarken bu okuma
başarısız olup **yanlış** "Veritabani yok" hatası veriyordu — biçim doğrulaması
motorun açılışına bırakıldı, kilit hatası doğru mesajla dönüyor. (2) busy
beklemesi sabit `Sleep(20)` sayımıyla ölçülüyordu; Windows zamanlayıcı
çözünürlüğü hedefi %50'den fazla aşırtıyordu.

### `.idx` varint (v3.2, 2026-10-26)

Kalıcı anahtar dizini **VER 2**: kayıtlar `Key(8) | PageNo(varint) | Slot(varint)`.
Satır anahtarı `VDbHashKey` ile üretilen **sanki-rastgele 64 bit** değerdir;
varint/delta onu büyütürdü, bu yüzden anahtar **ham 8 bayt** kalır. Kayıtlar
sıralanmaz (heap hash sırası korunur) — yükleyici sıraya zaten bağımlı değil,
böylece checkpoint'te sıralama maliyeti ödenmez.

| Ölçüm (`idxchk`, 50.000 satır) | VER 1 | VER 2 |
|---|---|---|
| `.idx` boyu | 800.064 B | **539.396 B** (−32,6%) |
| satır başına | 16,0 B | **10,8 B** |
| idx ile açılış | — | 6 ms (tam tarama 18 ms) |

- Yazıcı **yalnız VER 2** üretir; okuyucu VER 1'i de okur (eski dosyalar
  çalışmaya devam eder). Eski bir ikili VER 2 dosyasını görürse onu reddeder ve
  **tam tarama** yapar — `.idx` hiçbir zaman veri kaynağı değildir, kayıp yok.
- CRC artık kodlanmış **bayt akışı** üzerinde hesaplanır (kayıt dizisi
  üzerinden yeniden kodlamaya gerek yok); bozuk/kesik dosya sessizce atlanır.
- Kapı: `idxchk` **19/0** — VER 1 uyumu (elle yazılmış eski biçim, 500 kayıt
  birebir) ve varint sınırları (1…2³¹−1 sayfa, 1…65535 slot) ayrıca sınanır.

### Satır INT varint (v3.2, 2026-10-26)

Satır yükü şeması **değişmedi** (`ctype(1) | vlen(i32) | payload`); yalnız INT
kolonunun yükü sıkıştı: **zigzag LEB128**. `vlen = 1..7` → varint, `vlen = 8` →
**eski biçim** (ham little-endian Int64). Varint 8 bayttan fazla gerektiren
büyük değerler (|v| ≥ 2⁵⁵) yine `vlen = 8` ile ham yazılır; böylece 8 baytlık
yük hiçbir zaman "varint mi ham mı" belirsizliği taşımaz.

- **Eski satırlar okunur** (sahadaki dosyalar bozulmaz). Eski bir ikili yeni
  satır görürse INT alanında `vlen ≠ 8` ile karşılaşıp satırı **açıkça
  reddeder**; sessizce yanlış sayı üretmez. (İleri uyumluluk yok: eski ikili
  yeni dosyada INT içeren satırları okuyamaz.)
- Kanonik olmayan varint (kesik, uzatılmış, > 7 bayt) reddedilir.
- `VDbIntFromPayload` tek çözüm noktasıdır: `DecodeRow`, `VDbDecodeRawRowP`,
  `VDbRowFromOffsetsP`, `VDbColFromOffsetsP` ve `VDbExecutor`'ın 8 ham-okuma
  hızlı yolu (toplam/filtre/sıralama/zone map) bunu kullanır.

| Ölçüm (`rowmeas`, 100.000 satır: 6 INT + 2 TEXT, 32 bit) | Önce | Sonra |
|---|---|---|
| `.odb` boyu | 14.131.200 B | **10.752.000 B** (−23,9%) |
| satır başına | 141,3 B | **107,5 B** |
| toplu ekleme (500'lük gruplar) | 1167 ms | 1133 ms |
| `SUM(a)` (100k satır) | 20 ms | 19 ms |
| yeniden açılış | 3398 ms | 3372 ms |

**Bulunan ve düzeltilen hata:** zigzag kodlamada `V shr 63` kullanılmıştı;
Pascal'da `shr` **mantıksal** kaydırdığı için negatif değerlerde sonuç −1 değil 1
oluyordu ve `-9223372036854775807` **−2** olarak saklanıyordu. Kapı testi
(v3sqlchk `rowint`) bunu yakaladı; kodlama dallanmaya çevrildi
(`V<0 → 2|V|−1`, `−(V+1)` ile taşma yok).

**Gerçek veri kanıtı:** 6399 satırlık canlı `mtakip.odb` (eski biçimde yazılmış)
kopyası, **eski** ve **yeni** ikili ile satır satır çözülüp FNV-1a özeti
alındı: ikisi de `1DF4A420FF9A2488` (6399 satır; çözülemeyen 1 kayıt ikisinde de
şema meta satırı). Yani eski dosyalar birebir aynı değerlerle okunuyor.

Kapı: `v3sqlchk` **186/0** — 12 uç Int64 değeri (1…6 baytlık varintler + 8 bayt
ham dönüşü), `ORDER BY` sırası, `WHERE` ön elemesi, `VERIFY`, depoda alanın
gerçekten 1 bayt olduğu, elle kurulmuş **eski biçim** satırın çözülmesi ve bozuk
varint reddi.

### Sayfa düzeyi zone map (v3.3, 2026-10-26)

v2'deki zone map v2'nin **ekleme sıralı** veri dosyasına bağlıydı; v3'te
(`Kv = nil`) hiç kullanılmıyordu. v3.3'te v3 için **sayfa düzeyi** zone map
eklendi: bucket = **heap sayfa numarası**, her (sayfa, kolon) için min/max.

- Kapsam: yalnızca `AND` ile bağlanmış INT/FLOAT karşılaştırmaları
  (`= <> < <= > >=`, `IN`) ve `BETWEEN`. `OR`/`NOT`/ifade içeren koşullar
  haritaya girmez (güvenli taraf).
- **NULL**: satır min/max'a katılmaz (NULL için karşılaştırma FALSE'tur);
  bir sayfada o kolonun **tüm** değerleri NULL ise sayfa elenebilir.
- Harita tablo başına önbelleklenir. Geçerlilik **içerik damgası** iledir:
  her motor örneği benzersiz bir taban alır, damga **yalnızca veri
  değiştiren commit**'te ilerler. Salt-okunur işlemin commit'i (WAL'e meta
  çerçevesi yazsa bile) damgayı ilerletmez; böylece harita boşa gitmez.
- **Kritik güvenlik kuralı**: oturumda commit edilmemiş değişiklik varsa
  (`Backend.Dirty`) veya toplu yazım açıksa harita **ne kullanılır ne inşa
  edilir** — aksi halde aynı işlemde yazılan satırlar haritada görünmez ve
  budama satır kaybettirirdi. Kapı testi bunu ayrıca sınar.
- Atlama, disk okumasından **önce** olur: `Skip[pageNo] <> 0` olan sayfa hiç
  açılmaz (`TVdbHeap.ScanAllRawPaged` → `ScanRawIterAllPaged`).
- v2 tarafı değişmedi: `TVdbBackendV2.ScanRawIterAllPaged` `False` döner ve
  çağıran tam taramaya düşer.

| Ölçüm (`zmbench`, 100.000 satır × 3 kolon, 32 bit) | Değer |
|---|---|
| toplu ekleme (tek işlem) | 1056 ms |
| seçici sorgu — **ilk** koşu (harita inşası + tam tarama) | 72,2 ms |
| seçici sorgu — harita hazır (3 koşu medyanı) | **0,17 ms** |
| atlanan sayfa | **1525 / 1527** |
| orta seçicilik (`a > 150000`, 50.000 satır) | 73,7 → 73,1 ms (**kazanç yok**) |
| filtresiz (100.000 satır) | 144,9 ms |

Yorum: kazanç **seçici** yüklemlerde ve harita **kurulduktan sonra** gelir;
haritanın kurulduğu ilk sorgu tam tarama bedelini öder. Yarısını seçen bir
yüklemede satır üretimi baskın olduğu için ölçülebilir kazanç yoktur — bu
yüzden iddia yalnızca seçici yüklemler için geçerlidir.

`SHOW STATS` v3 çıktısına `zone_pruned_pages` (son taramada atlanan sayfa
sayısı) eklendi; v3 metrik satırı 12 → **13** oldu.

Kapı: `v3sqlchk` **196/0** — `TestPageZoneMap`: harita inşasında budama yok,
ikinci koşuda budama var (268 sayfa), sonuç birebir aynı, tam aralıkta yalnızca
boş sayfalar atlanır, NULL satır budamayı bozmaz, **commit edilmemiş işlemde
harita kullanılmaz**, commit sonrası yeni satırlar doğru sayılır.

### Çok oturumlu yazma / MVCC (v3.4, 2026-10-26)

Kapsam **süreç içi çok oturumlu yazma**dır: aynı `IVdbBackend` üzerinde birden
çok `TVSql` (veya `VDbSetTxnSession`) oturumu **aynı anda yazabilir**.

- **Okuma: READ COMMITTED.** Her oturum kendi yazma kümesinde (`TWriteSet`)
  yazar; commit edilmemiş yazı başka oturuma görünmez, kendi oturumuna görünür.
- **İlk commit kazanır.** Commit anında, uygulamadan **önce**, yazılan her
  anahtarın *before-image*'ı (ilk yazma anındaki motor değeri) güncel motor
  değeriyle karşılaştırılır (`VerifyNoConflict`). Değişmişse commit
  `EVdbBackendV3` ile durur — `yazma cakismasi: $… baska bir oturum tarafindan
  degistirildi (islem geri alindi)`; **yarım uygulama olmaz**. Kaybeden oturum
  `ROLLBACK` ile kümesini temizler.
- **GLOBAL duruma dokunan işlemler çoklu yazmada reddedilir:** DDL
  (`MarkSchema`), `SAVEPOINT`/`ROLLBACK TO`/`RELEASE`, `DEFERRABLE` FK ertelemesi
  ve bekleyen erteleme denetimi `RequireSoleTxn` / `IVdbBackend.SoleWriter`
  üzerinden açık `ecLockConflict` verir (sessiz karışıklık yerine).
- **Kilit:** tek backend içinde `FEngCs` (`TVdbGate`, v3.9) motoru ve `FSets`'i
  serileştirir; **işlem boyunca tutulmaz**. v3.16'dan beri `TVdbGate`'in
  0→1 / 1→0 geçişleri dosya kilidini de sürer (`AcquireRead`/`ReleaseRead`);
  yazma girişi paylaşımlıyı bırakıp tam kilidi alır (`AcquireWrite`), çıkışta
  bırakır. Aynı iş parçacığından iç içe giriş kritik bölüme hiç girmez.
  Güvenlik ağı: paylaşımlı kilit altında bir yazma ilkeli çağrılırsa kilit
  kendiliğinden tam kilide yükselir (`FAutoWrite`).
- **Bilinçli sınırlar:** yazarlar **sıralıdır** (uzun işlem diğer süreçlerin
  okuyucularını da bekletir); **açık bir salt-okunur oturum** paylaşımlı kilidi
  oturum boyu tuttuğu için yazarları bloklar (`lockchk` bölüm 3); adil kuyruk
  yoktur; canlı veritabanının **sürüm yükseltmesi** çok süreçli kullanımda
  desteklenmez. **Süreçler arası DDL** (başka süreç açıkken `CREATE/DROP/ALTER`)
  sınanmadı ve desteklenmez: şema oturum açılışında yüklenir. Şifreli dosyada
  çok süreçli yazma kod yolunda var ama ayrı bir kapıyla sınanmadı. Snapshot
  isolation süreç **içinde** var (v3.15), süreçler arasında görünürlük "son
  commit" düzeyindedir.

| Ölçüm (`benchcmp`, 200k × 3 kolon, 3 koşu medyanı, 32 bit) | Değer |
|---|---|
| toplu INSERT — before-image **kapalı** (A/B) | 6,532 µs/satır |
| toplu INSERT — before-image **açık** | **7,466 µs/satır** (+%14,3) |
| toplu INSERT — v3.10 sonrası (aynı iş) | **6,115 µs/satır** (v2 3,822 → 1,60x) |
| toplu INSERT — v3.11 sonrası (satır gövdesi varint) | **5,771 µs/satır** (v2 3,822 → 1,51x) |
| `.odb` boyu (200k × 3 kolon) — v3.11 | 11.912 KB → **10.040 KB** (−%15,7) |
| autocommit INSERT | 1,024 ms |
| açılış (200k satır) | 39,0 ms |

Yorum: çakışma denetiminin bedeli satır başına **0,93 µs**'dir; yeni anahtarda
`TryGet` boşa gider ama *var olan* anahtarı ayırt etmek için zorunludur
(vazgeçilirse kayıp güncelleme koruması kalkar). Tek oturumlu yüklerde de
ödenir; doğruluk önceliği nedeniyle bilinçli kabul edildi.

Kapı: `v3sqlchk` **228/0** — `TestMultiSession` (32 kontrol): izolasyon, READ
COMMITTED, ilk-commit-kazanır çakışma reddi, DDL reddi, motor düzeyi `Delete`
çakışması. `sqltest` v3 **2759/0/33**, v2 **3196/0/0**, 14 kapı yeşil.

### Açılış yolunda ölçülen 20 s darboğazı (v3.5, 2026-10-26)

200.000 satırlık veritabanı + 57 MB değişim günlüğü (600k kayıt) ile **açılış
20.043 ms** ölçüldü. Nedenleri ve düzeltmeleri:

| Yer | Önce | Sonra |
|---|---|---|
| `TVdbChangeLog.ScanTail` — tüm segment geçmişi | 20.043 ms (açılış) | — |
| `TVdbLogReader.ListBases` — her kaydı okuyup CRC | 5.967 ms | **21 ms** |
| `TVdbLogReader.LastState` — her kaydı okuyup CRC | 7.080 ms | **0 ms** |
| **toplam açılış** (200k satır) | **20.043 ms** | **39–46 ms** |

- `LogTailState`: segment kuyruğundaki son kayıt **O(1)** okunur (END veya BASE;
  toplam uzunluk dosya sonuna tam oturmalı ve CRC tutmalı). Tutmazsa — yarım
  grup/çökme — o segment **eskisi gibi tam taranır**; güvenli yol korunur.
- `ListBases`: segment **tek okumada** belleğe alınır, kayıt yükleri atlanır;
  yalnız BASE kaydı CRC ile doğrulanır.
- Davranış değişmedi: bozuk/yarım kuyruk tam taramaya düşer, CRC'siz BASE
  kabul edilmez.

Kapı: değişim günlüğü 28/0, PITR 21/0, replikasyon 37/0, çökme kurtarma 11/0.

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

### Satır gövdesi varint ve dosya sürümü 4 (v3.11, 2026-10-26)

Satır gövdesi v1 her kolonda **sabit 4 baytlık** uzunluk, pk ve kolon sayısı
için 2 baytlık alan taşıyordu. v2 gövde bunları varint'e çevirir:

```
v1: [u16 tableId][u16 pkLen][pk][u16 colCount]
    + her kolon: [u8 ctype][i32 vlen][payload]        (vlen = -1 => NULL)
v2: [u16 $FFFF][u16 tableId][varint pkLen][pk][varint colCount]
    + her kolon: [u8 ctype][varint lenCode][payload]  (0 => NULL, aksi
                                                        halde len+1)
```

Ayırt edici `$FFFF`, bu motorda **hiçbir zaman** geçerli bir tablo kimliği
değildir (`CreateTable` ve `CreateMaterializedView` sınırı; şema yüklemesi
böyle bir kaydı açık hatayla reddeder). Bu yüzden eski bir satırın v2
sanılması mümkün değil.

**Dosya sürümü 3 → 4.** Satır biçimi değiştiği hâlde başlık 3 kalsaydı eski
bir ikili v2 gövdeyi v1 sanıp satırı düşürebilir ya da yanlış değer
üretebilirdi. Sürüm 4 bunu kapatır:

- sürüm 3 dosyalar **açılır**; aynı dosyada v1 ve v2 satır bir arada okunur
  (eski satır güncellenince v2 yazılır), ilk **yazılabilir** açılışta başlık
  4'e yükseltilir; salt-okunur açılış yazmaz;
- eski ikili `desteklenmeyen surum: 4` ile **açık hata** verir (ölçüldü:
  v3.10 ikilisi yeni dosyada tam bu hatayı verdi);
- `RESTORE` ve `VERIFY` yolları sürüm 3'ü kabul eder.

| Ölçüm (200k × 3 kolon, 3 koşu medyanı, 32 bit) | v3.10 | v3.11 |
|---|---|---|
| hazırlama | 4,003 µs/satır | **3,933 µs/satır** |
| commit | 2,128 µs/satır | **1,863 µs/satır** |
| **TOPLAM** (log=on) | 6,157 µs/satır | **5,771 µs/satır** (−%6,3) |
| `.odb` boyu | 11.912 KB | **10.040 KB** (−%15,7) |
| tam tarama (200k satır) | 32,00 ms | 30–33 ms (fark yok) |
| sabit 3 kolonlu satır | 39 bayt | **30 bayt** |

**Geriye dönük okuma kanıtı (gerçek eski dosya):** v3.10 kaynağından ayrı bir
worktree'de derlenen ikili 500 satırlık DB yazdı; yeni ikili aynı dosyada
`COUNT=500` ve tüm değerlerin FNV özetinde **birebir** aynı sonucu verdi.
Ardından 250 satır `UPDATE` edilip dosya karışık biçime getirildi:
dokunulmayan 250 satırın özeti yine birebir aynı kaldı.

Kapı: `sqltest` v3 **2822/0/33**, v2 **3256/0/0** (yeni `T157_SatirGovdesi`
19 kontrol: elle kurulmuş v1/v2 gövdenin aynı değerleri vermesi, `$FFFF`
işaretinin ham taramada görülmesi, satırın **tam 30 bayt** olması, NULL /
büyük negatif INT / 127 bayttan uzun metin); 14/14 kapı yeşil; `sqltest` ve
`lockchk` 64-bit derlemede de yeşil.

### JOIN: ON eşitlik + ek koşul (v3.12, 2026-10-26)

İndekssiz eşitlik join'i bu motorda **hash join**'dir; merge JOIN ölçümle
reddedildi (iki taraf sıralı değil, anahtarlar hash tabanlı, `ORDER BY`
join'den sonra gelir → merge sıralama bedeli öder ve yavaş kalır).

Ölçüm (`tmp64/joinbench`, 10k × 10k satır, 100 farklı anahtar):

| Sorgu | Süre |
|---|---|
| hiç eşleşmeyen join, 0 satır sonuç | **42 ms** (nested loop olsaydı ~6 s) |
| PK `a.id = b.id` | **46 ms** |
| `a.k = b.k`, 1M satır sonuç | 3,2 s (maliyet satır kopyalamada) |
| `ON a.k=b.k AND a.k>1000000` — **eski** kod | **300 s'de bitmedi** |
| `ON a.k=b.k AND a.k>1000000` — **yeni** kod | **5.926 ms** |

Eski kodda hash yolu yalnız ON **tek** `kolon = kolon` iken açılıyordu; kök
`AND` olunca 100M çift üzerinde ifade yorumlanıyordu. Düzeltme: `AND`
ağacının içindeki kolon=kolon eşitliği hash anahtarı olur, ek koşullar
`JoinOnOk`'ta uygulanır (sonuç değişmez). Ek koşul varsa indeks/PK hızlı
yolu kapatılır (o yol `JoinOnOk` çağırmaz → ek koşulu atlardı).

Kalan ölçülmüş fırsat: ON/WHERE yüklemlerinin ilgili tarafa itilmesi
(`a.k > 1000000` solda 0 satır bırakır). Bu ayrı bir maddedir.

Kapı: `sqltest` v3 **2832/0/33**, v2 **3266/0/0** (yeni
`T158_OnEkKosulHash`: INNER/LEFT/FULL/PK/OR kökü/NULL/imkânsız ek koşul);
14/14 kapı yeşil.

### Dosya boyutu: PK satır gövdesinde tek kez (v3.13, 2026-10-26)

Satır içi PK tanımında PK **iki kez** yazılıyordu: gövde başlığında
(`varint pkLen + pk`) ve PK kolonunun yükünde. `.idx` anahtarı
`VDbHashKey` olduğu için PK anahtardan türetilemez; gereksiz olan ikinci
kopyadır.

Ölçüm (`tmp64/rowbytes`, 3 kolon):

| tablo | ort. satır (v3.12) | PK baytları | PK payı |
|---|---|---|---|
| küçük INT PK | 21,8 B | 3,8 B | %17,4 |
| büyük INT PK | 30,7 B | 9,9 B | %32,1 |
| TEXT PK | 36,0 B | 10,0 B | %27,8 |

Yeni biçim (dosya sürümü **5**): `pkLen = 0` + `varint v` → `v = 0` boş
PK, `v ≥ 1` ise PK `v-1`. kolonun değeridir; `pkLen > 0` eski satır içi
biçimdir. Eski dosyalarda `pkLen = 0` **hiç görülmez** (boş PK reddedilir,
PK'siz tablo üretilmiş anahtar taşır → ölçüldü `pkLen = 2`), bu yüzden
ayırt edicidir. Kodlayıcı bu yolu yalnız PK metni kolonun **kanonik**
metniyle birebir aynıysa kullanır; aksi halde satır içi yazar (kayıpsız).

Aynı veri, iki ikili (`tmp64/sizebench`, 50k + 50k satır, kapanmış dosya):

| veri kümesi | v3.12 `.odb` | v3.13 `.odb` | fark |
|---|---|---|---|
| geniş metin (`kayit-NNNNN`) | 5.406.720 B | 4.874.240 B | **−%9,9** |
| dar satır (`t='x'`) | 4.435.968 B | 3.866.624 B | **−%12,8** |

Satır düzeyi: küçük INT PK **21,8 → 19,0 B** (−%12,8), büyük INT PK
**30,7 → 21,9 B** (−%28,7), TEXT PK **36,0 → 27,0 B** (−%25,0). `.idx`
değişmedi (1.089.063 → 1.088.347 B).

**Hücre başlığı sıkıştırma reddedildi:** kolon başına 1 bayt `ctype`,
`ALTER COLUMN TYPE` sonrası eski satırların doğru çözülmesini sağlayan
güvenlik ağıdır; 3 bayt/row için bu garanti bozulmaz (öncelik 1).

Geriye dönük okuma kanıtı: `c02ac06` ikilisiyle (sürüm 4) yazılan dosya
yenide açıldı → başlık **4 → 5**, 100 eski satır satır içi PK ile aynen
okundu, aynı dosyaya 10 yeni satır pk'sız yazıldı (iki biçim yan yana),
`UPDATE` PK'yı korudu, `VACUUM` satırları ham kopyaladı, yeniden açılışta
tüm PK'lar birebir. Eski ikili aynı dosyayı `desteklenmeyen surum: 5`
ile reddetti; salt-okunur açılış yükseltme yapmadı (sürüm 4 kaldı).

Kapı: `sqltest` v3 **2858/0/33**, v2 **3289/0/0** (yeni `T159_PkTekKez`,
26 kontrol); 14/14 kapı yeşil.

Okuma bedeli (aynı veri, iki ikili, QPC 9 koşu medyanı): `SUM(a)` INT pk
0,31 → **0,40 µs/satır**, `SUM(LENGTH(t))` 2,80 → 2,83, `SUM(n)` TEXT pk
0,34 → 0,35. (İlk turda `SUM(a)` 0,45 idi; KeyHash yolundaki satır başına
`IntToStr` ayırması `VdbIntToDecBuf` ile kaldırıldı.)

### İfade değerlendirme: bytecode reddedildi, tip-duyarlı tam sayı yolu (v3.14)

**Ölçülen hipotez çürütmesi.** `tmp64/vmhead` (aynı 5 işlemlik zincir, 50k
satır, QPC 5 koşu): ağaç yorumlayıcı 0,80 µs/satır, **string yığın bytecode
1,07 (+%34, daha yavaş)**, tip-duyarlı Int64 yığını 0,30 (−%63). Maliyet
dağıtımda değil, ara düğümlerde üretilen metinde. `FindColIdx` şüphesi de
çürütüldü: `a+a+a+a` 3,35 vs `1+1+1+1` 3,28 µs/satır (kolon payı ~0,02/işlem)
— bu yüzden indeks önbelleği yapılmadı.

**Yapılan.** `BinaryOpCtype` (tip kararı tek yere alındı, davranış aynı) +
`TryIntEval`: yalnız INT kolon/tam sayı literali `+ - *` (ve tekli `-`)
zincirleri Int64'te yürür, ara metin üretilmez; uygun olmayan her durumda
(NULL, FLOAT/BOOL/metin, bölme/modulo, fonksiyon, CAST, CASE) ağaç yolu
aynen çalışır. Birebir eşdeğerlik: aynı tip kararı, aynı `VDbParseInt`,
aynı Int64 aritmetiği.

**Diferansiyel kanıt.** `tmp64/exprdiff`: 200 sözde-rastgele ifade × 40 satır
(1–3 derinlik, `+ - * / %`, tekli eksi, negatif/büyük değer, `'007'`, `''`,
NULL, sayısal olmayan metin); hızlı yol açık/kapalı iki ikilinin çıktısı
`fc /b` ile **farksız**.

Ölçüm (`tmp64/exprbench`, 50k satır, QPC 5 koşu medyanı):

| sorgu | önce | sonra | fark |
|---|---|---|---|
| `SELECT a` (taban) | 1,88 | 1,84 | nötr |
| `SELECT a+1` | 2,74 | 2,33 | −%15 |
| `SELECT (a*2+1)*3-7` | 4,53 | **2,85** | **−%37** |
| `SELECT ((((a+1)*2)+3)*4)+5` | 5,14 | **3,16** | **−%39** |
| `SELECT a+a+a+a` | 3,35 | 2,33 | −%30 |
| `COUNT(*) WHERE a*2+1 > 50000` | 3,86 | **3,30** | −%15 |
| `COUNT(*) WHERE a > 25000` (ham yol) | 0,44 | 0,46 | nötr |
| `WHERE t LIKE 'kayit-4%'` | 1,02 | 1,06 | nötr |

Kapı: `sqltest` v3 **2874/0/33**, v2 **3305/0/0** (yeni `T160_TamSayiZinciri`,
16 kontrol); 14/14 kapı yeşil.

### Snapshot isolation (v3.15)

**Semantik.** Açık işlemi olan oturum, işlemi başlattığı andaki görüntüyü okur
(v2 ile aynı: `BatchIsMine and Seq > 0`); başka oturumların sonraki commit'leri
görünmez, kendi yazdıkları önceliklidir. Commit sonrası / parti dışı okuma
güncel veriyi görür.

**Yol.** Sayfa düzeyinde sürüm zinciri yerine **bellek içi post-image
penceresi**: commit sırasında başka bir yazma kümesi açıksa, dokunulan
anahtarların commit sonrası hali `(Gen, Present, Value)` olarak `FUndo`'ya;
anahtarın ilk girişinde commit öncesi motor değeri `Base` olarak saklanır.
Okuyucu `StartGen`'ine göre `Gen <= StartGen` olan son post'u, yoksa `Base`'i
kullanır. Post'lar commit öncesi yerel listede toplanır → başarısız commit
sahte geçmiş bırakmaz. `FUndo` yalnız hiç açık yazma kümesi kalmayınca
temizlenir (bellek penceresi = en uzun ortak açık işlem).

**Değişen yollar:** `Get`, `Exists`, `EffectiveCount`/`Count`, `ScanAll`,
`ScanRawIterAll`. Taramada snapshot'ta farklı anahtarlar motor geri çağırımında
atlanır, doğru halleri sonda eklenir. `ScanRawIterAllPaged` (açık partide
`False`) ve `CountTable` (açık partide `-1` → tam tarama) değişmedi. v3'te
zone map devrede değil (`FT.Kv` v2 motoruna bağlı); günlük budama mantıksal
günlükte, `FUndo` bellek içi → etkileşim yok.

**Kanıt.** Yeni kapı `snapchk` (21 kontrol): eski değer, silinen satırın geri
gelmesi, yeni satırın görünmemesi, `Exists`, sabit `Count`, tarama, kendi
yazısı, commit sonrası güncellik, çakışmanın hâlâ yakalanması, parti dışı
okuma ve post zinciri orta durumu (arada başlayan okuyucu). Uygulama öncesi
12/18, sonrası 21/21.

**Eski test düzeltmesi.** `v3sqlchk` "v3.4 çok oturumlu yazma" bölümü A
commit'inden sonra B'nin 4 satır görmesini bekliyordu (READ COMMITTED); yeni
semantikte B kendi görüntüsünde kalır (3 satır), commit'ten sonra başlayan
okuma 4 satır görür. Test güncellendi (`v3sqlchk` 238/0).

**Ölçüm** (`tmp64/exprbench`, 50k satır, QPC 5 koşu medyanı): `SELECT a`
1,84 → 1,84; `a+1` 2,33 → 2,34; `(a*2+1)*3-7` 2,85 → 2,89; 5'li zincir
3,16 → 3,15; ifadeli `COUNT` 3,30 → 3,17; ham `COUNT` 0,46 → 0,44; aralık
1,70 → 1,69; `LIKE` 1,02 → 1,02. Farklar gürültü sınırında (±%2).

**Bilinçli sınırlar.** Yazma yolu değişmedi (ilk commit kazanır); bayat
snapshot'a dayanan bir yazma, çakışan commit ilk yazmadan önce olmuşsa sessizce
commit edilebilir (lost-update) — snapshot yalnız okumayı sabitler. `FUndo`
belleği en uzun açık işlem boyunca büyür. Süreçler arası çok yazarlılık v3.16'da
yapıldı (kilit işlem kapsamlı); yazarlar sıralıdır.

Kapı: `sqltest` v3 **2874/0/33**, v2 **3305/0/0**; `v3sqlchk` **238/0**;
`lockchk` **29/0**; `prochk` **8/0**; **16/16 kapı yeşil**. CI (GitHub Actions)
de aynı **16** kapıyı koşar — `snapchk`/`prochk` v3.17'de eklendi.

### Sürüm çizgisi (2026-10-26)

Bu hat **alpha**'dır: `v3.x` adları yayın sürümü değil çalışma dilimidir.
Kalan kapsam — Bloom filtresi (ölçümle reddedildi), merge JOIN (ölçümle
reddedildi, yerine ON eşitlik+ek koşul hash düzeltmesi yapıldı), dosya
boyutu (**yapıldı**: PK tekrarı kaldırıldı, hücre başlığı gerekçeli
reddedildi), ifade bytecode (**ölçümle reddedildi**; yerine tip-duyarlı tam
sayı yolu yapıldı — bkz. §v3.14), snapshot isolation (**yapıldı** — bkz.
§v3.15) — hepsi tamamlandı ve ürün **v1.0.0** olarak etiketlendi.
`main` = `v3`; iş `v3`te yürür ve her push'ta `main` de ilerletilir. Süreçler
arası çok yazarlılık (aynı dosyaya iki süreç yazması) kapsam dışıdır;
snapshot isolation tek süreç içinde **yapıldı**.
