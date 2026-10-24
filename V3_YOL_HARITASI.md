# VDB v3.0 — Sayfa Tabanlı Depolama Planı

**Tarih:** 2026-10-24
**Dal:** `v3` (main'den ayrılır, `v2.3` etiketiyle v2 dondurulur)
**Hedef:** Append-only KV → sayfa tabanlı depolama. Dosya boyutu ve açılış süresi
kökten düzelir; SQL katmanı ve API değişmez.

---

## Kararlar (kullanıcı onaylı)

| # | Konu | Karar |
|---|---|---|
| A | Dosya adı/uzantısı | **Aynı `.odb` adı korunur.** Dosya başında `VDB3` magic + sürüm baytı. v2 dosyası açılırsa net hata: `v2 formatı — MIGRATE TO v3 çalıştır`. `.odb3` uzantısı YOK. |
| B | Aralık sorgusu / sıralı anahtar | **v3.0'a girmez.** v3.0 = hash anahtarlı sayfa yığını (dosya boyutu + açılış kazanır). B+tree / BETWEEN **v3.1**. |
| C | Replication | **v3.0'da kapalı.** `START REPLICATION` çağrısı `ecNotSupported` + açıklayıcı mesaj verir. v3.1'de mantıksal değişim günlüğü ile yeniden yazılır. |
| D | v2 uyumu | v2 dosyaları **okunmaz, yazılmaz**. Tek yönlü `MIGRATE TO v3` aracı; kaynak dosya `.v2bak` olarak korunur. |
| E | Otomatik sıkıştırma | v3.0'da `AutoCompactEnabled` **varsayılan False** kalır (H25 kararı korunur). Sayfa motorunda boş sayfa geri kazanımı zaten var. |
| F | P-DUR sözleşmesi | Korunur. SQL commit ve açık `Flush`, `SyncWrite=False` olsa bile fsync eder. |
| G | Batch/transaction semantiği | Korunur: `BeginBatch` / `CommitBatch` / `AbortBatch` / savepoint / `SyncWriteInterval` grup commit. |

---

## Başlangıç ölçümü (2026-10-24, bu makine, 200.000 satır, 3 kolon)

Bunlar v3'ün kıyaslanacağı gerçek taban çizgisi. Tüm sayılar benim ölçümüm.

| Metrik | VDB v2 (win32) | VDB v2 (win64) | SQLite 3.50.4 64-bit |
|---|---:|---:|---:|
| Dosya boyutu | 19.278.555 B (94 B/satır) | aynı | 5.226.496 B (26 B/satır) |
| Açılış (`kv.Open`) | 1063–1109 ms | 968–985 ms | 6 ms |
| `COUNT(*)` | 31–32 ms | 47 ms | 4 ms |
| PK nokta (`WHERE id=`) | 5,45 µs | 7,00 µs | 43,29 µs (kendi tx) / 1,30 µs (açık tx) |
| PK doğrudan `ReadRow` | 1,55 µs | 2,35 µs | — |
| Toplu INSERT | 4,1–4,2 µs/satır | 4,07 µs/satır | 0,88–1,97 µs/satır |
| Autocommit INSERT | 0,430–0,437 ms | 0,430 ms | 1,84–1,89 ms |
| Ham dosya okuma tavanı | 1119 MB/s | — | — |

**Taban çizgisi ölçümü — `tests/bench/benchcmp` (3 tur, medyan, 2026-10-24):**

| Metrik | VDB win32 | SQLite 3.50.4 |
|---|---:|---:|
| Dosya boyutu | 19.278.424 B (96,4 B/satır) | 5.226.496 B (26,1 B/satır) |
| Açılış | 1063 ms | 6 ms |
| `COUNT(*)` | 31 ms | 4 ms |
| PK nokta | 4,70 µs | 47,09 µs |
| parse-only `SELECT 1` | 3,15 µs | 0,91 µs |
| Toplu INSERT | 4,300 µs/satır | 0,942 µs/satır |
| Autocommit INSERT | 0,435 ms/satır | 1,876 ms/satır |

**v3.0 kabul hedefleri (200k satır):**

| Metrik | Hedef | Ölçüm yöntemi |
|---|---|---|
| Dosya boyutu | **≤ 11 MB** (≤ 55 B/satır) | `DataFileSize` |
| Açılış | **≤ 150 ms** | `kv.Open` süresi (3 tekrarın medyanı) |
| `COUNT(*)` | **≤ 16 ms** | tam tarama |
| PK nokta | **≤ 7 µs** (gerilemez) | `WHERE id=` |
| Toplu INSERT | **≤ 5 µs/satır** (gerilemez) | 200k tek batch |
| Autocommit INSERT | **≤ 0,55 ms** (gerilemez) | 20k tek satır |
| UPDATE/DELETE sonrası şişme | **≤ %5** | 100k UPDATE sonrası dosya artışı |

Not: `COUNT(*)` hedefi 16 ms çünkü ölçüm gösterdi ki fark CPU değil **okunacak bayt**;
dosya yarıya inince tarama da yaklaşık yarıya iner.

---

## Kapsam

### v3.0 içinde
- 4 KB sabit sayfa, slotted-page hücre yerleşimi, sayfa başına CRC32
- Buffer pool (CLOCK, pin/dirty), freelist (trunk page zinciri)
- Sayfa-imajlı WAL + commit kaydı + checkpoint + replay
- Slotted heap: insert / update-in-place / delete / page split / overflow zinciri
- `.odb.idx` hızlı açılış yan dosyası (doğrulanır, bozuksa tam tarama)
- `IVDbBackend` dikişi + `TVDbBackendV2` (sarmalayıcı) + `TVDbBackendV3`
- `MIGRATE TO v3` göç aracı + doğrulama
- Şifreleme: sayfa düzeyinde AES-GCM (`VDBCrypt` yeniden kullanılır)
- `Verify`, `BACKUP`, `Compact` (boş sayfa geri kazanımı)

### v3.1'e ertelenen
- Sıralı anahtar düzeni + B+tree yaprakları → **BETWEEN / aralık sorguları**
- Replication (mantıksal değişim günlüğü)
- Zone map'in sayfa düzeyinde yeniden ele alınması
- Satır gövdesi varint/delta kodlama (F3-1'in kalanı)
- Bloom filtresi, merge JOIN, ifade bytecode

### Kapsam dışı (değişmedi)
- M3 WASM, M7 async sunucu
- WASM/edge, çok yazarlı MVCC

---

## Dokunulacak mevcut dosyalar (envanter)

Sayfa motorunu yazmak kolay; asıl maliyet şu 4 dosyada. Plan bunları hesaba katıyor.

| Dosya | Bugünkü bağ | v3'te yapılacak |
|---|---|---|
| `VDbCore.pas` | `TVDb` = motorun kendisi (6.600 satır) | `TVDb` **korunur** (v2 backend olarak). Yeni `IVDbBackend` arayüzü; `TVDb` onu uygular |
| `VDbTable.pas` | 39 × `FKvStore` (arayüz) + 48 × `FKv.` (somut) | Somut çağrılar arayüze taşınır: `BeginBatch`, `CommitBatch`, `AbortBatch`, `Flush`, `InBatch`, `Exists`, `Count`, `ScanRawIterAll`, `EnsureColumnKey`, `SetBeforeCommit` |
| `VDbSql.pas` / `VDbExecutor.pas` | `TVSql(FKv: TVDb)` | Arayüz tipine geçer; davranış değişmez |
| `VDbReplication.pas` | v2 WAL segmentlerine bağlı | v3.0'da devre dışı + net hata |

8 birimde `TVDb` somut tipi geçiyor: `VDbReplication`, `VDbPgWire`, `VDbPool`,
`vdbapi_core`, `VDbExecutor`, `VDbClientNet`, `VDBClient`, `bench_live`.

---

## Steps

### Sprint 0 — Hazırlık (yarım gün)

- [x] 0.1 `git tag v2.3 && git push origin v2.3` — v2 dondurulur
- [x] 0.2 `git checkout -b v3` + `git push -u origin v3`
- [x] 0.3 `.gitignore`: `YEDEK/`, `--help/`, `bench_live.*` eklenir (şu an untracked)
- [x] 0.4 Bu plan repoya `V3_YOL_HARITASI.md` olarak eklenir (ilerleme buradan işaretlenir)
- [x] 0.5 `vdb_kapsamli_yol_haritasi.md` §1.3 ve §2.2 tabloları yukarıdaki gerçek ölçümlerle değiştirilir (belgedeki 7,7x / 19,5x / "PK'da 2,1x öndeyiz" ifadeleri bugünkü ölçümle çelişiyor)
- [x] 0.6 `sqltest`'e `--backend=v2|v3` anahtarı; v3 yokken testler `ATLA` (v3/bilinmeyen backend → `ATLA`, **exit=2**, yanlış yeşil yok; v2 → 3112/3112 exit=0)
- [x] 0.7 `benchcmp.pas` + `benchcmp.py` repoya `tests/bench/` altına alınır (tekrarlanabilir kıyas takımı, 3 tekrar + medyan)

### Sprint 1 — Sayfa motoru çekirdeği (Gün 1-5)

- [x] 1.1 `VDbPage.pas`: 4 KB sabit sayfa, başlık, slot dizini, CRC32, tip alanı
- [x] 1.2 `pagechk`: 100k rastgele ekle/oku/güncelle/sil, referans map ile birebir; **0 hata** kapısı (21/21, `kalan=0`)
- [x] 1.3 `VDbPageStore.pas`: buffer pool (CLOCK, pin/dirty/LRU), sayfa ayır/serbest bırak (15/15, `storechk`)
- [x] 1.4 `freelist`: trunk page zinciri; silinen sayfa yeniden kullanılır (trunk sızmıyor: boşalınca sayfa olarak geri kazanılır)
- [x] 1.5 `VDbPageHeap.pas`: slotted heap insert/güncelle/sil, >2 KB için overflow zinciri (12 B hücre başlığı, 1000 B üstü taşma zinciri)
- [x] 1.6 Sayfa bölme yerine **yazma sayfası + boş sayfa geri kazanımı**: sayfa dolunca yeni sayfa, sayfa tamamen boşalınca freelist'e döner; doluluk %95,7 (hücre) / %48,8 B satır
- [x] 1.7 `heapchk`: 200k satır + 200k rastgele işlem, **20/20, kalan=0**; INSERT sonrası tüm anahtarlar birebir okunur
- [x] 1.8 `VDbPageWal.pas`: sayfa-imajlı WAL, commit kaydı, checkpoint, replay
- [x] 1.9 `crashtest` v3 backend ile **11/11**; süreç `kill -9` sonrası 0 kayıp
- [x] 1.10 `VDbIdxFile.pas`: `.odb.idx` (key → sayfa, slot), açılışta dosya boyutu + son commit LSN + CRC doğrulaması
- [x] 1.11 Bozuk/bayat/eksik `.idx` → otomatik tam tarama; **veri kaybı yok** testi (`idxchk` 17/17)
- [x] 1.12 Ölçüm: dosya **9,76 MB**, açılış **31 ms** (idx ile) / **63 ms** (tam tarama) — 200k

### Sprint 2 — SQL'e bağlama (Gün 6-10)

- [x] 2.1 `IVDbBackend` arayüzü: `Put/Get/Delete/ScanAll` + `BeginBatch/CommitBatch/AbortBatch/Flush/InBatch/Exists/Count/ScanRawIterAll/EnsureColumnKey/SetBeforeCommit` — `VDbBackendApi.pas` (yalnız `SysUtils`'e bağımlı; v3 backend v2 motorunu link etmez). `TQWordArray/TValArray/TVDbRawCb/TDbCommitHook/TVDbRowTagFunc/IVDbKvStore` buraya taşındı.
- [x] 2.2 `TVDbBackendV2`: mevcut `TVDb`'yi sarmalar — `VDbBackendV2.pas`. `TVDb`'nin taban sınıfı DEĞİŞTİRİLMEDİ (Create/Free ile yönetilen ~50 çağrı yeri var; referans sayılı arayüz use-after-free riski taşır). Arayüz referans saymaz.
- [x] 2.3 `sqltest --backend=v2` hâlâ **3112/3112 (win32)** — dikiş regresyon yapmadı
- [x] 2.4 `TVDbBackendV3`: arayüzü sayfa motoruna bağlar — `VDbBackendV3.pas`, `backendchk` **35/35**. Parti modeli: yazmalar önce bellek kaplamasına, `CommitBatch` motora uygular + `Commit(True)`, `AbortBatch` kaplamayı atar (gerçek geri alma). Checkpoint eşiği `VDB_V3_CHECKPOINT_BYTES = 8 MB` (`Wal.Bytes` ile).
      Checkpoint politikası: commit yalnız WAL'i fsync eder; checkpoint WAL boyu
      eşiği (8 MB) veya boşta/kapanışta yapılır.
- [x] 2.5 `VDbTable.pas` içindeki 48 somut `FKv.` çağrısı arayüze taşınır — `FKvB: IVDbBackend` alanı eklendi, `FKvStore` kaldırıldı; 53 `FKv.`/37 `FKvStore.` çağrısı arayüze taşındı. `FKv` yalnız Verify/Backup/replication gibi henüz arayüzde olmayan çağrılar ve `Kv` özelliği için duruyor.
- [x] 2.6 `TVSql` / `TVExecutor` arayüz tipine geçer; davranış değişmez — `TVTableDb.Backend: IVDbBackend` özelliği eklendi; `FT.Kv.` üzerinden yapılan 30 arayüz karşılığı çağrı (ScanRawIterAll/Get/InBatch/BeginBatch/CommitBatch/Flush) `FT.Backend.` oldu. `Kv` yalnız arayüzde olmayan v2'ye özgü yollar için (Verify/Backup/arşiv/replication/zone-scan/`Dirty`/`FilePath`) kaldı. v2 kapısı **3112/3112**.
- [x] 2.7 SQL katmanı v3 sayfa motoru üzerinde çalışır — `TVTableDb.CreateBackend` + `Kv = nil` korumaları; `v3sqlchk` kapısı (CREATE/INSERT/SELECT/WHERE/ORDER BY/COUNT/SUM/GROUP BY/JOIN/DISTINCT/LIMIT-OFFSET/UPDATE/DELETE, PK/UNIQUE/NOT NULL/CHECK, CREATE INDEX, BEGIN/COMMIT/ROLLBACK, yeniden açılış kalıcılığı, 1200 satır birebir) **47/47**. SAVEPOINT/ROLLBACK TO/RELEASE v3'te `ecUnsupported` (v3.1).
      Bu adım iki gerçek veri kaybı hatası ortaya çıkardı ve düzeltildi:
      (a) `TVdbPageStore.LoadFrame`: WAL tamponundan (pending) yüklenen sayfa artık **kirli** işaretlenir — aksi halde checkpoint onu atlıyor, WAL budanıyordu (sayfa kaybı).
      (b) `TVdbPageEngine.OnMiss`: pending kaydı çerçeveye taşındığında pending'den **düşürülür**; `Checkpoint` yalnız yerleşik olmayan pending imajlarını kurar — aksi halde eski imaj yeni çerçevenin üzerine yazılıyordu (şema kaydı kaybı).
      (c) `AddPending`: pending imajı mühürlenir (CRC), böylece tahliye sonrası okuma doğrulanabilir.
      Regresyon kapısı: `backendchk` → `TestV3SpillReread` (4 çerçeve, iki tur yeniden yazım, 5000 satır birebir) **36/36**.
- [x] 2.8 `MIGRATE TO v3` + `MIGRATE VERIFY` — `VDbMigrate.pas` (KV düzeyinde birebir kopya: sema + satır + dizin kayıtları; SQL yeniden kodlama YOK) ve SQL'de `MIGRATE TO v3 '<dosya>'` / `MIGRATE VERIFY '<dosya>'`. Doğrulama: anahtar sayısı eşitliği + her kaynak anahtarın hedefte **bayt bayt** aynı olması (sayı eşit + tüm anahtarlar bulundu ⇒ küme eşitliği). `.colkey` dosyası da kopyalanır. `migchk` kapısı **13/13**: var olan hedef reddi, v3 kaynaktan göç reddi, SQL yolu, göç sonrası `COUNT/SUM/PK/indeksli arama/ilk-son satır`. **200k satır: 200001 kayıt, fark=0** (kopya 1000 ms, doğrulama 1079 ms); boyut v2 16.201.267 B → v3 13.840.384 B (**%85,4**).
- [x] 2.9 v3 tam `sqltest` koşusu; kalan testler sınıflandırılır (kapsam / hata / v3.1) — koşucu test başına `try/except`'e çevrildi (`TTestRec`/`BuildTests`), `--backend=v2|v3` (bilinmeyen backend `exit 2`). **v2: 3116/3116, atlanan=0**; **v3: 2244 geçen, 0 kalan, 59 ATLA**. ATLA ölçütü: gövdesinde `kv.`/`pkv.`/`myKv`/`TVDb.Create` geçen testler (33+24) + yalnız v2 yönetim komutlarını sınayanlar (T15, T79); ayrıca `T19` içindeki `VACUUM` bölümü. Bu koşu 6 gerçek kusur ortaya çıkardı ve hepsi düzeltildi: (a) zone map yolu `Kv = nil` iken `DataSeqValue` okuyup **sıradan `WHERE int = 7` sorgusunda AV** veriyordu (55+ doğrulama düştü); (b) `VDbJson.VDbImportJson` doğrudan `Tb.Kv.BeginBatch` çağırıyordu (v3'te AV) → `Tb.BeginBatch`; (c) **tablo düzeyi `UNIQUE(...)` parser tarafından yutuluyordu** (v2'de de!) → `TSqlCreateTableStmt.Uniques` + UNIQUE indeks; (d) `ON CONFLICT(<unique hedef>)` hiç uygulanmamıştı → `FindConflictPk` + çakışmanın `CheckConstraints`'ten önce çözülmesi (`ExcludePk`); (e) yönetim komutları `Kv = nil` iken AV → `ecUnsupported`; (f) CI'da `crashtest` 42 dk asıldı (konsolsuz alt süreçte Windows hata kutusu) → `SetErrorMode` + CI'da 300 sn sert sınır. CI'ya `sqltest --backend=v3` kapısı eklendi.
- [x] 2.10 v3 kapsam raporu `V3_KAPSAM.md` — sonuç tablosu, 59 ATLA'nın üç gerekçe grubu (tek tek liste), düzeltilen 6 kusur, v3.0 dışı yeteneklerin sürüm eşlemesi (3.1-3.7), yeniden üretme komutları.

### Sprint 3 — Eşitlik ve kapı (Gün 11-15)

- [x] 3.1 `Verify` v3'te (sayfa CRC + heap bütünlüğü + anahtar dizini) — `TVdbPageEngine.Verify` + `TVDbPageStore.VerifyFreeList`; `IVDbBackend.Verify` üzerinden `VERIFY` SQL komutu v3'te çalışır (v2'de `TVDb.Verify`'e devam). Denetimler: tüm sayfalarda yapı + CRC32, sayfa başlığındaki numara, freelist trunk zinciri (döngü/aralık/tekrar/sayaç), heap hücre başlığı ve **tüm taşma zinciri** (her halka + ilan edilen uzunluk), yinelenen anahtar, dosyadaki anahtar sayısı = bellek dizini. Onaylanmamış WAL çerçevesi varsa önce checkpoint; açık parti/işlemde net ret. Kapılar: `backendchk` **41/41** (sağlıklı dosya, taşma zincirleri, açık parti reddi, bozulma enjeksiyonu), `v3sqlchk` **49/49** (SQL `VERIFY` + işlem içinde ret).
- [x] 3.2 `BACKUP` / `RESTORE` v3'te — yedek = checkpoint sonrası **sayfa imajlarının bayt-bayt kopyası** (tek `.odb`; `.idx`/`.wal` kopyalanmaz). `TVDbPageStore.CopyCommittedTo` meta sayfasını yeniden üretir, `.tmp` + fsync + rename ile yarım yedek bırakmaz; kaynak dosya ikinci kez açılmaz (Windows paylaşım kilidi sorunu yok). `RESTORE`: kaynak `VDB3`/sürüm 3 doğrulanır, motor kapatılır, mevcut dosya `.bak`a taşınır, yeni dosya atomik yerine konur, eski `WAL`/`.idx` silinir, motor yeniden açılır; hata olursa `.bak`tan geri dönülür. SQL katmanı `TVTableDb.ReloadSchema` ile şemayı/indeksleri yeni dosyadan yükler. Kapılar: `backendchk` **52/52** (bağımsız motorla yedek doğrulama, taşma değeri, restore sonrası VERIFY, açık parti reddi, v3 olmayan kaynak reddi), `v3sqlchk` **55/55** (`BACKUP TO` / `RESTORE FROM` + restore sonrası şema/veri/VERIFY). `crashtest` işaret dosyası yarışı da giderildi (**11/11**).
- [ ] 3.3 `Compact` (boş sayfa geri kazanımı); `AutoCompact` varsayılan **False** kalır
- [ ] 3.4 Şifreleme: sayfa düzeyinde AES-GCM; `enc1..enc9` testleri v3'te geçer
- [ ] 3.5 `START REPLICATION` → `ecNotSupported` + "v3.1'de mantıksal günlükle gelecek" mesajı; test bunu doğrular
- [ ] 3.6 PITR / time-travel v3'te çalışır (veya açıkça devre dışı + test)
- [ ] 3.7 Zone map v3'te çalışır (`zonechk` birebir)
- [ ] 3.8 win32 tam kapı: **`kalan=0`**
- [ ] 3.9 win64 (-O1 ve optimizasyonsuz) tam kapı: **`kalan=0`**
- [ ] 3.10 Linux/WSL tam kapı: **`kalan=0`**
- [ ] 3.11 `crashtest` 11/11, fuzz (T111, 3VL, T147 SQLancer) v3'te temiz
- [ ] 3.12 Ölçüm tablosu `hiztesti.md` + `speedtest.md` + `readme*.md` güncellenir — **yalnız ölçülmüş sayılar**
- [ ] 3.13 `git tag v3.0` + push; CI yeşil

---

## Sayfa formatı (Gün 1'de sabitlendi — `VDbPage.pas`)

```
0   ..  23    başlık (24 bayt)
24  ..  ...   slot dizini, yukarı büyür (slot = 4 bayt: Off, Len)
... .. 4091   hücre gövdesi, aşağı büyür
4092 .. 4095  CRC32 (0..4091 üzerinde)
```

Başlık: `Magic('VP') | PageType | Flags | PageNo | SlotCount | FreeSpace |
ContentOff | FragBytes | LSN`. `Slot.Off = 0` → slot boş.

**Üç değişmez kural (sonraki günler bunlara dayanıyor):**

1. **Slot indeksleri kararlıdır.** `PageCompact` yalnızca gövdeyi yeniden
   paketler; slot *i* her zaman aynı hücreyi gösterir. Bu yüzden heap katmanı
   `(sayfaNo, slot)` çiftini güvenle tutabilir. (İlk sürüm slotları yeniden
   numaralandırıyordu; `pagechk` bunu 170 hata ile yakaladı ve düzeltildi.)
2. **CRC yalnızca mühürlemede hesaplanır.** INSERT/UPDATE/DELETE 4 KB CRC
   ödemez; `PageSeal` sayfa diske/WAL'e yazılırken çağrılır. Bellekteki yapı
   denetimi `PageCheckStruct` ile (CRC'siz) yapılır. Aksi halde 200k satırlık
   toplu INSERT'te ~800 MB fazladan CRC hesaplanırdı.
3. **Silme O(1)'dir.** Baytlar yerinde kalır, `FragBytes` ile muhasebe edilir,
   yer gerekince `PageCompact` geri kazanır.

Ölçüm (pagechk): 4096 baytlık sayfaya 100 baytlık **39 hücre** sığdı
(3900 bayt yük, 12 bayt artık) → yük doluluğu **%95,7**. 100.000 rastgele
işlem (25.318 ekle / 25.129 sil / 17.384 güncelle / 5.027 sıkıştır) sonunda
8 sayfanın tamamı referans modelle **birebir** aynı, `kalan=0`.

---

## Depo katmanı (Gün 2-3 — `VDbPageStore.pas`)

Dosya: `sayfa 0 = başlık`, `sayfa 1..N = veri`. Başlık kendi CRC'siyle
korunur; v2 dosyası açılırsa `MIGRATE TO v3` hatası verir.

- **Buffer pool:** CLOCK (ikinci şans), pin/dirty, varsayılan 512 sayfa (2 MB).
  Pinli sayfa tahliye edilemez; tümü pinliyse açık hata.
- **CRC:** yalnızca yazarken (`Flush`/tahliye). Okurken `PageVerify` ile
  denetlenir, bozuk sayfa sessizce kabul edilmez.
- **Freelist:** LIFO, trunk sayfaları 1019 sayfa numarası taşır, dolunca
  yeni trunk başa eklenir. Trunk sayfası VDbPage formatı kullanmaz,
  kendi sihirli sayısı + CRC'si vardır.
- **Trunk yan yükü:** ilk serbest bırakma 1 sayfa büyütür (trunk).
  Trunk boşalınca **sızmaz**; sıradaki ayırmada sayfa olarak geri verilir
  (`storechk` bunu doğruluyor).

Ölçüm (`storechk`, 2000 sayfa): 2000 sayfa yazıldı, 64'lük havuzda
**3936 tahliye** ile geri okundu, desen birebir; 667 sayfa serbest bırakılıp
yeniden ayrıldı, veri sayfası eklenmedi; kapat/aç sonrası CRC'ler geçerli;
bozulmuş veri **ve** başlık sayfası reddedildi; 8'lik havuzda 20.000 rasgele
erişim 0 hata. Sonuç: `gecen=15 kalan=0`.

---

## Heap katmanı (Gün 3-4 — `VDbPageHeap.pas`)

Anahtar `QWord` → değer `TBytes`. Hücre biçimi sayfa içinde:

```
Key 8 B | Len 4 B (bit31 = taşma) | veri (satır içi)  ya da  | ilkTaşmaSayfası 4 B
```

- **Hücre başlığı 12 B**, slot 4 B → satır başına sabit yük **16 B**
  (v2'de ~62 B idi). Sayfa başlığı sayfa başına bir kez ödenir.
- **Taşma:** 1000 B üstü değerler zincir sayfalarına bölünür (parça 4000 B).
  Zincir sayfaları da `VDbPage` formatında (`VDB_PAGE_OVERFLOW`) olduğu için
  CRC ve yapı denetiminden geçer; bozuk zincir **sessizce yanlış veri
  döndürmez**.
- **Dizin:** `key → (sayfa, slot)` açık adresleme tablosu, bellek içinde.
  Açılışta `.odb.idx` taze ise oradan yüklenir (31 ms / 200k), değilse tüm
  heap sayfaları taranır (63 ms) — yedek yol her zaman çalışır.
- **Güncelleme:** aynı boyut + satır içi ise **yerinde** yazılır (slot sabit).
  Boyut değişirse eski değer saklanır, silinir, yeniden eklenir; ekleme
  başarısız olursa eski değer geri konur (veri kaybı yok).
- **Silme:** O(1); baytlar yerinde kalır, sayfa tamamen boşalınca freelist'e
  döner. Slot indeksleri kararlıdır (`PageCompact` slotları yeniden numaralamaz).

Ölçüm (`heapchk`, 200.000 satır × 32 B değer, win32):

| Metrik | Ölçüm |
|---|---|
| Dosya | **9.756.672 B** → satır başına **48,8 B** (v2: 96,4 B) |
| EKLE | **1,54 µs/satır** |
| OKU | **0,65 µs/satır** |
| Heap sayfası | 2381 (200k satır) |

Rastgele işlem matrisi (200k işlem, 5000 anahtar evreni, bağımsız referans
model): 28.894 ekleme, 31.880 güncelleme, 25.548 silme, 29.904 okuma —
**birebir**, `gecen=20 kalan=0`. Kapsam kapısı güncelleme/silme sayısı 0 ise
testi **kırmızı** yapar (boş yeşil engellenir).

Taşma testleri: 1/999/1000/1001/5000/60.000 B değerler birebir; 60.000→50
küçültmede zincir serbest kalır; 1→3000 büyütmede zincir kurulur; bozulmuş
zincir sayfası **açılışta** CRC ile yakalanır.

---

## WAL ve çökme kurtarma (Sprint 1.8–1.9)

`VDbPageWal.pas` + `VDbPageEngine.pas` — **sayfa imajlı, write-ahead** günlük.
Commit öncesi veritabanı dosyasına sayfa **yazılmaz**; sıra:

1. Kirli sayfalar + meta imajı WAL'e çerçeve olarak eklenir,
2. commit kaydı yazılır ve **fsync** edilir (burada durabilirlik tamam),
3. `Checkpoint` ayrı adımdır: imajlar veri dosyasına yazılır, fsync, WAL budanır.

Havuz dolduğunda kirli sayfa `OnSpill` ile WAL tamponuna (bellekte) taşınır;
sonraki okuma `OnMiss` ile diskten değil tampondan karşılanır. Böylece eski
imaj diske sızmaz.

Dosya biçimi: `<db>.wal`, 4096 B başlık (`VWL3`), 20 B kayıt başlığı
(`Magic|LSN|PayloadLen|PageNo|Crc`), 4096 B yüklü `VFW1` çerçeveleri ve
`FWC1` commit kaydı. Meta sayfa (0) de çerçeve olarak loglanır; kurtarmada
**en son** uygulanır (önce dosya uzatılmalı).

Kurtarma yalnız commit kaydıyla kapanmış çerçeveleri uygular; bozuk CRC'li
kayıt veya kesik kuyruk **durur** — yarım işlem yazılmaz. Çerçeve imajları
yazılırken `PageSeal` uygulanır, böylece replay sonrası sayfa CRC'si geçerlidir.

`crashtest` (11/11, `kalan=0`): temel commit/aç, commit edilmemiş atılır,
gerçek `kill -9` (commit edilmiş 28.150 satırın tamamı; kurtarma 5 çerçeve /
7 commit), kesik WAL kuyruğu, bozuk WAL çerçevesi + bozuk sayfa → **açık hata**,
torn page onarımı, 8 sayfalık havuzda 5000 satır, bozuk WAL başlığı.

Testler sırasında bulunan gerçek hatalar: (a) commit sırasında `IsCached`
tahliye tetikleyip yoğun yazımda sayfa kaybettiriyordu → `InstallPage` artık
onbellekteki imajı tazeler, tahliye etmez; (b) sihirli sayısı bozuk sayfa
"freelist trunk" sanılıp sessizce atlanıyordu → `IsTrunkPage` ile ayırt edilir,
aksi halde açık hata; (c) WAL çerçeveleri mühürsüz imaj taşıyordu.

---

## Kalıcı anahtar dizini (`.odb.idx`) ve ölçüm (1.10–1.12)

`VDbIdxFile.pas` + `TVdbHeap.TryLoadIdx/SaveIdx`. Dizin, heap'in bellek
tablosunun (`key → sayfa, slot`) bir kopyasıdır ve **hiçbir zaman veri
kaynağı değildir**:

- Yalnızca temiz kapanışta (checkpoint sonrası) yazılır; `.tmp` + rename ile
  atomik, kesik `.idx` oluşmaz.
- Açılışta üç şey tutmalı: **LSN**, **sayfa sayısı**, **dosya boyu** — ayrıca
  başlık ve kayıt CRC'leri. Biri tutmazsa dosya sessizce yok sayılır ve tam
  tarama yapılır. Veri kaybı mümkün değil, sadece açılış yavaşlar.
- Kayıt 16 B (`Key 8 | PageNo 4 | Slot 2 | Pad 2`) → 200k satırda 3,2 MB.
  Sıkıştırma (varint) v3.1'e bırakıldı.

`idxchk` 17/17: temel yaz/kapat/aç, bozuk idx, kesik idx, bayat idx (eski LSN),
idx yok, sil/güncelle sonrası kapat-aç; her senaryoda **tüm değerler birebir**.

### Ölçüm — 200.000 satır × 32 B değer, win32, `tests/bench/benchv3`, 3 tur medyan

| Metrik | Ölçüm | Hedef |
|---|---|---|
| Veritabanı dosyası | **9.756.672 B** = 48,8 B/satır | ≤ 11 MB ✔ |
| `.idx` | 3.200.064 B = 16,0 B/satır | — |
| Açılış (idx ile) | **31 ms** | ≤ 150 ms ✔ |
| Açılış (tam tarama) | 63 ms | (yedek yol) |
| Toplu yazım + commit + checkpoint | **2,34 µs/satır** | ≤ 5 µs ✔ |
| PK nokta okuma | **0,39 µs/satır** | ≤ 7 µs ✔ |
| WAL (temiz kapanış sonrası) | 4096 B (yalnız başlık) | budanmış ✔ |

En yavaş tek ölçüm 32 ms; ilk turda `.idx` soğuk önbellekten okunduğu için
16–32 ms aralığı görüldü. Tam tarama (yedek yol) 62–78 ms.

---

## Kapılar (pazarlık dışı)

1. v2 dalı bozulmaz: `v2.3` etiketinde `sqltest` **3112/3112 (win32)**, 3077/3077 (win64/Linux).
2. v3.0 yayınlanmadan `kalan=0` üç platformda.
3. `crashtest` 11/11, `idxchk` 17/17 ve P-DUR sözleşmesi: commit ve `Flush` fsync eder.
4. Göç hiçbir senaryoda kaynak `.odb`'yi değiştirmez; `.v2bak` üretir.
5. Bozuk `.idx` hiçbir zaman veri kaybına yol açmaz — yalnız yavaşlar.
6. Rakamlar yalnız aynı ortamda ölçülerek raporlanır.

---

## Riskler ve karşılıkları

| Risk | Olasılık | Karşılık |
|---|---|---|
| Çökme kurtarma hatası (en tehlikeli) | Orta | Sprint 1'de WAL, testlerden **önce**; `kill -9` matrisi 6 senaryo (commit öncesi/sonrası/ortası, checkpoint ortası, torn page, eksik WAL) |
| v2'ye regresyon (dikiş sırasında) | Orta | 2.3 adımı: dikiş sonrası v2 kapısı **aynı gün** koşulur. Sayı düşerse dikiş geri alınır |
| `VDbTable`'daki 48 somut çağrı beklentiden uzun sürer | Yüksek | 2.5 tek gün; taşınamayanlar için ince adaptör (`TVDbBackendV2` içinde `as TVDb`) bırakılır |
| Şifreleme + sayfa CRC çakışması | Orta | Sıra: sayfa imajı → CRC → AES-GCM zarfı. Doğrulama sırası test edilir |
| Kayıp performans (PK/batch) | Orta | Her sprint sonunda ölçüm; hedefin altına düşerse o sprint kapanmaz |
| 15 gün yetmez | Orta-yüksek | Sprint 3 taşarsa **v3.0-beta** yayınlanır: motor + göç hazır, replication ve zone map v3.0'a girer; sürüm ertelenmez, kapsam dürüstçe daraltılır |

---

## "Bitti" tanımı

- Üç platformda `sqltest` `kalan=0`, `crashtest` 11/11
- 200k satır: dosya ≤ 11 MB, açılış ≤ 150 ms, PK ve yazma gerilememiş
- `MIGRATE TO v3` 200k satırda 0 fark
- v2.3 etiketi ve dalı bozulmamış
- Rakamlar dokümanda, ölçümle doğrulanmış
- `v3.0` etiketi push edilmiş, CI yeşil
