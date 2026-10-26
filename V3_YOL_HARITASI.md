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
| C | Replication | **v4'te açık.** Sayfa imajı değil **mantıksal grup** taşınır (`VDbReplV3.pas`); dosya tabanlı (`SHIP_DIR`) slot + `PUMP`, `CREATE/DROP REPLICATION SLOT`, `SHOW REPLICATION STATUS/SLOTS`, `START/STOP REPLICATION`. TCP ile replikasyon hâlâ reddedilir. |
| D | v2 uyumu | v2 dosyaları **okunmaz, yazılmaz**. Tek yönlü `MIGRATE TO v3` aracı; kaynak dosya `.v2bak` olarak korunur. |
| E | Otomatik sıkıştırma | v3.0'da `AutoCompactEnabled` **varsayılan False** kalır (H25 kararı korunur). Sayfa motorunda boş sayfa geri kazanımı zaten var. |
| F | P-DUR sözleşmesi | Korunur. SQL commit ve açık `Flush`, `SyncWrite=False` olsa bile fsync eder. |
| G | Batch/transaction semantiği | Korunur: `BeginBatch` / `CommitBatch` / `AbortBatch` / savepoint / `SyncWriteInterval` grup commit. |
| H | v2 kodunun geleceği (2026-10-25) | v2 **legacy read-only**: okuma yolu (`VDbCore`, `VDbTable`, `VDbBackendV2`) ağaçta kalır çünkü göç aracı ve `migchk` kapısı onu derlemek zorunda. v2'ye yeni özellik/iyileştirme yapılmaz; `benchcmp --backend=v2` ve `sqltest --backend=v2` kapsamdan çıkarılır (son yeşil sonuçlar kayıt olarak korunur). |
| I | Göç arayüzü (2026-10-25) | Motor zaten hazır (`VDbMigrate.pas`); kullanıcıya **`vdbmig` CLI** sunulur (`copy` / `verify`, çıkış kodları, `--dry-run`). GUI'ye göç düğmesi eklemek ayrı bir karar konusudur; şimdilik kapsamda değil. |

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

**v3.0 kabul hedefleri (200k satır) — v3.1 sonucu:**

| Metrik | Hedef | Ölçüm yöntemi | v3.0 | v3.1 (2026-10-25) | Durum |
|---|---|---|---|---|---|
| Dosya boyutu | **≤ 11 MB** (≤ 55 B/satır) | `DataFileSize` | sayfa harness **9,76 MB** (48,8 B/satır) + `.idx` 3,20; SQL harness 15,5 MB (77,6) + `.idx` 3,52 → **diskte toplam 19,0 MB** | değişmedi | kısmen |
| Açılış | **≤ 150 ms** | `kv.Open` süresi (3 tekrarın medyanı) | 32 ms (v2: 984) | **27,8 ms** | ✔ |
| `COUNT(*)` | **≤ 16 ms** | sayaç | 62 ms (v2: 31) | **0,1 ms** (canlı sayaç) | ✔ |
| PK nokta | **≤ 7 µs** (gerilemez) | `WHERE id=` | 6,25 µs (v2: 6,25) | **5,13 µs** | ✔ |
| Toplu INSERT | **≤ 5 µs/satır** (gerilemez) | 200k tek batch | 6,64 µs (v2: 4,46) | **5,79 µs** (256 KB'lık uzatma) | sınırda |
| Autocommit INSERT | **≤ 0,55 ms** (gerilemez) | 20k tek satır | 0,557 ms (v2: 0,431) | **0,449 ms** (işlem başına WAL) | ✔ |
| UPDATE/DELETE sonrası şişme | **≤ %5** | 100k UPDATE sonrası dosya artışı | ölçülmedi (VACUUM geri kazanıyor) | ölçülmedi | — |

v3.0'da tutmayan üç metrik v3.1'de kapandı; kalan tek sınır **toplu INSERT**tir
(5,79 µs, hedef 5). Kök neden sayfa imajlı WAL'in 2x yazma hacmidir — tasarım
maliyeti. Autocommit'te kalan fark **dayanıklılık tabanıdır**: tek fsync
0,330 ms (ayrı `fsyncbench` ölçümü), commit başına WAL 63.373 → 8.252 B.
Kök nedenler, ölçümler ve koşular arası sapma `hiztesti.md` §9'da.

**Boyut konusunda dikkat (dürüstlük):** v3 veri dosyası v2'den %19,5 küçük, ama
yanına **`.odb.idx`** (3,52 MB; anahtar → sayfa/slot açılış önbelleği) yazıyor.
`.idx` silinebilir (açılış 79 ms, hedef 150 ms) fakat yok sayılırsa toplam
diskteki kazanç %19,5 değil **%1,2** olur. v3.1 boyut işi **değildir** (dosya
boyutu değişmedi: 15.527.936 B / 77,6 B/satır). Asıl boyut kazancı için sıradaki
sürümde (a) PK dizisinin heap ile aynı anahtarı ikinci kez yazması (hücre
başına 12 B başlık + 4 B slot + ayrı PK girdisi) ve (b) hücre başlığının
sıkıştırılması incelenecek; `.idx` için varsayılan açık/kapalı kararı da
bekliyor (şimdilik: her zaman yazılır).

Not: v3.1'de `COUNT(*)` artık tarama yapmıyor (canlı sayaç, 0,1 ms); hedefin
16 ms olması v3.0'da farkın CPU değil **okunacak bayt** olmasındandı.

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

### v3.1'de yapılanlar (kısa)
- `COUNT(*)` O(1) canlı sayaç + `.idx` özeti
- `.idx` koşulsuz yazılır (50 MB eşiği kaldırıldı)
- İşlem başına WAL çerçevesi (`TxnMark`) + yapısal meta ayrımı
- Toplu dosya büyütme (256 KB) + kapanışta kırpma
- Akışlı / sıfır-kopya tarama; QPC ölçüm altyapısı
- Ayrıntı: "Sprint 4 (v3.1)" bölümü

### v3.1 sonrası: uygulamaların v3'e geçişi (2026-10-25)

Motor hazırdı ama uygulamalar hâlâ `TVDb` somut tipini kullanıyordu. Geçiş
tamamlandı:

| Ne | Durum |
|---|---|
| `VDbFactory.pas` — tek giriş noktası (`VdbOpen`, `VdbOpenOrCreate`, `VdbOpenWithPassword`) | tamam; v3 varsayılan, v2 reddedilir (`AllowV2` yalnız göç) |
| `examples/` 01–06, 09–12 | tamam; hepsi `VdbOpenOrCreate` + `TVTableDb.CreateBackend` |
| `examples/build_all.bat` | tamam; **14/14** derleniyor (yol hatası düzeltildi) |
| `examples/07`, `08` (TCP sunucu/istemci) | **v2'de kalıyor**: `VDbSqlServer` hâlâ `TVDb` kullanıyor; M7 sunucu kapsam dışı (v3.2) |
| `yonetim/` (GUI) | tamam; `FBe: IVdbBackend`, v2 dosyasında `vdbmig` yönlendirmesi |
| `factorychk` kapısı (13 kontrol) + CI adımı | tamam |
| `UYGULAMA_GELISTIRME.md` | tamam; uygulama geliştirici kılavuzu (12 bölüm) |
| `SHOW STATS` + `/metrics` v3'te | tamam; v2 sayaçları yerine `engine`, `live_keys`, `.odb/.wal/.idx` boyutları |
| `sqltest --backend=v3` | **2347 geçen / 0 kalan / 52 atlanan** (v2: 3116/0/0) |
| **`v3.1.1` etiketi** | atıldı ve push edildi (`8bfca69`); CI run `40201040319` **18/18 adım yeşil** |

Geçişte bulunan gerçek hatalar (hepsi veri bütünlüğü/dosya kilidi/erişim):

1. **Boş v3 dosyası açılamıyordu.** `VDbPageHeap.TryLoadIdx` döngü değişkeni
   `LongWord`'dü; `.idx` içinde 0 kayıt varken `High(entries) = -1` →
   `$FFFFFFFF` taşması ve AV. `Integer` yapıldı.
2. **Motor referansı bırakılmıyordu.** FPC 3.2.4'te arayüz **döndüren**
   fonksiyon fazladan referans bırakıyor (`Be := nil` dosyayı kapatmıyordu);
   ayrıca `TVTableDb.Destroy` `FKvB`'yi serbest bırakmıyordu. Giriş noktaları
   `out` parametreye geçti, yıkıcıya `FKvB := nil` eklendi. Ölçüm: probe5/probe6.
3. **`GetMetricsText` v3'te AV veriyordu.** Prometheus `/metrics` ucu koşulsuz
   `FT.Kv.GetReadCacheStats` okuyordu; v3'te `Kv = nil`. Artık motora göre
   dallanıyor; v3'te `engine_info`, `live_keys`, `.wal`/`.idx` boyutu.
4. **`SHOW STATS` v3'te tümden reddediliyordu.** Yönetim komutu topluca
   `Kv = nil` dalında `ecUnsupported`'a düşüyordu; v3 için gerçek metrik yolu
   eklendi (12 satır).
5. **`examples/build_all.bat` 10 örneği derlemiyordu.** `%~dp0` zaten
   `examples\` ile bitiyor, yol `examples\examples\...` oluyordu; `cd`
   başarısız olunca fpc yanlış dizinde koşuyordu (eski `compile.log`'lar
   hatayı gizliyordu).
6. **`sqltest` T117 v3'te AV veriyordu** (yalnız test): v3 dalında `kv2` hiç
   atanmadığı için `finally` içindeki `kv2 <> nil` çöp değere bakıyordu.

Ayrıca beş test (T64, T65, T94, T94c, T105) v3 koşusuna taşındı; tek engelleri
yeniden açılışı elle `TVDb.Create` ile yapmalarıydı. v3 atlanan sayısı
**58 → 52**.

### v3 "bitti" — kapanış kaydı (2026-10-25)

v3 bu noktada uygulama geliştirmeye hazır ilan edildi:

- Motorda bilinen veri kaybı/açık hata yok; 9 kapı + `sqltest` iki motorda
  `kalan=0`.
- CI 18/18 yeşil; **örnekler artık kapıda derleniyor** (12/12), yani
  uygulama geliştiricinin belgesi sessizce çürüyemez.
- `examples/build_all.bat` 14/14 (12 örnek + `sqltest` + `vdbapi`).
- API yüzeyi sabit: yeni uygulamalar `VDbFactory` + `TVTableDb.CreateBackend`
  kullanır, `TVDb`'yi tanımaz.
- Kalan işler v3.2: `SAVEPOINT`/kısmi geri alma, PITR/WAL arşivi,
  replikasyon, zone map, `ALTER DATABASE KEY`, TCP sunucusunda v3.
  Hepsi bugün **açık hata** verir, sessiz yanlış sonuç üretmez.

> **Güncelleme (2026-10-26):** Bu paragraftaki PITR/WAL arşivi maddesi
> **kapandı** (v4 dilimi). Bkz. aşağıdaki "v4 — mantıksal değişim günlüğü
> ve PITR" bölümü. Kalanlar: `SAVEPOINT`, replikasyon, zone map.

CI'da düzeltilen iki kusur (bu kapanışta bulundu):

1. `sqltest --backend=v3` adımının son kontrolü `atlanan=[1-9]` idi; yani
   hiç test atlanmazsa adım **kırmızı** oluyordu. Mantık tersti; kontrol
   "atlanan sayısı raporlanmalı" (`atlanan=\d+`) yapıldı.
2. `examples/` hiçbir kapıdan geçmiyordu. İlk denemede adım
   `fpc.exe bulunamadi (lazRoot=C:\lazarus)` ile düştü: arama
   `bin\i386-win32\fpc.exe` ile sabitlenmişti, CI'daki FPC paketi yalnız
   win64 birimleriyle geliyor. Arama hedef dizininden bağımsız hale getirildi
   (`i386-win32` varsa tercih edilir, yoksa ilk bulunan) ve adım artık
   hatayı **annotation** olarak yayınlıyor — iş logları anonim okunamadığı
   için teşhis bu yolla yapıldı.

### v3.2 ilerlemesi (2026-10-25, ölçülen)

"v3 bitti" ilanı geri alındı; v2 ile işlevsel eşitlik için v3.2 açıldı.
Aşağıdakiler **tamamlandı ve iki motorda da test edildi** (aynı test hem
`--backend=v2` hem `--backend=v3` koşar):

| Konu | Yapılan | Test | Ölçüm |
|---|---|---|---|
| Kısmi geri alma | `IVdbBackend.Savepoint/RollbackToSavepoint/ReleaseSavepoint`; v3'te parti kaplaması üzerinde journal, sema yığını (`TVTableSavepoint`), indeks onarımı | T149 (yinelenen isim, olmayan isim, DDL geri alma, örtük işlem, hedef korunur) | v3 geçti |
| `ALTER DATABASE KEY` | v3: dosya bütünü yeni parola ile yeniden şifrelenir (tmp + `.bak`, anahtar sayısı doğrulamalı, hata→eski kimlik) | T150 (5 doğrulama) | v3 geçti |
| Kolon şifreleme | `.colkey` biçimi v2 ile aynı (`VDbCrypt`); `ENCRYPTED` kolon şifresiz dosyada açık hata | T151 (10 doğrulama) | v3 geçti |
| TCP sunucusu | `VDbSqlServer` artık `IVdbBackend` (`VdbOpenOrCreate`), varsayılan v3 | T106 | v3 geçti |
| Yönetim API (ölçüm) | `DeadBytes`, `DataFileSize`, `AutoCompact*` sözleşmede; v3'te ölü alan = freelist × 4096 | T152 (iki backend) | v3: 12.288 B → dosya 32.768 → 12.288 B |
| Otomatik sıkıştırma | v2 ile aynı varsayılan (KAPALI, %35, 4 MB); commit/autocommit sonrası yalnız eşik aşılınca; hata commit'i bozmaz | T152 | v3 geçti |
| KV depolama | `VDbBackendApi.TVdbBackendKvStore` (`IVDbKvStore` ← `IVdbBackend`) | T153 | v3 geçti |
| Yönetim aracı yolları | PK'siz tablo, sentetik anahtar, `UpdateRowInPlace`, çok kolonlu UNIQUE indeks, `AutoCompact`, `ExecAll`, `VACUUM`, `REINDEX` | T154 | v3 geçti |
| Akışlı top-N | T132 v3'te koşuyor | T132 | v3 geçti |
| Rasgele diferansiyel | 200 sabit tohumlu SELECT; indeksli vs saf tarama | T147 | v3: 200/200, **0 fark** |
| Oturum yalitimi | `FWriteSession` + `BatchIsMine`/`RequireBatchWrite`; v2 ile aynı kural (başka oturum görmez, yazamaz, commit edemez) | T126 (iki backend) | v3 geçti |
| `AS OF SEQUENCE` | Sayfa imajlı WAL'den N'inci commit'in tam görüntüsü: `TVdbPageWal.Recover(MaxCommits)`, `TVdbPageEngine.RecoverLimit`, `TVDbPageStore.CopyBaseImageTo`, `IVdbBackend.ScanAllAt/AsOfMaxSequence`, `TVTableDb.ScanRowsAt`, executor anlık görüntü dalı; geçici kopya, canlı dosyaya yazmaz (şifreli dosyada da çalışır) | T155 (iki backend) + `v3sqlchk` | v3: 2.758/0/33 |

Son ölçüm: `sqltest --backend=v3` **2758 geçen / 0 kalan / 33 atlanan**,
`--backend=v2` **3196 / 0 / 0**. Atlanan 33'ün tamamı v2'nin iç
mekanizmalarına (blok CRC, undo, in-place, WAL kayıt biçimi) bağlı
testlerdir — bunlar v3'te **yok** ve v3'te açık hata verir.

**v3.2'de kalanlar (2026-10-26 itibarıyla):**

1. ~~**Gerçek PITR (`RECOVER TO`) / WAL arşivi (T95).**~~ → **tamamlandı**
   (aşağıdaki "v4" bölümü).
2. ~~**Replikasyon (T95b, T101).**~~ → **tamamlandı** (aşağıdaki v4
   replikasyon bölümü): mantıksal grup taşıma, taban kurulumu, kendi seq
   uzayına yeniden numaralandırma, boşluk/bozukluk/nesil kopması retleri.
3. Zone map (sayfa düzeyinde budama) ve dosya boyu optimizasyonları —
   performans işi, doğruluk riski yok.

### v4 — mantıksal değişim günlüğü ve PITR (2026-10-26)

Tasarım ve sözleşme `VDbChangeLog.pas` başında yazılı. Özet:

| Konu | Yapılan |
|---|---|
| Günlük biçimi | `<db>.log\seg-NNNNNN.vlog` (16 MB rotasyon, yalnız grup sınırında) + `<db>.log\base\b-<seq>-<lsn>.odb` taban imajları. Kayıt = anahtar + eski değer + yeni değer + UTC ms + grup seq. Magic: `VLG1`/`VLR1`/`VLB1`/`VLE1`. **Yarım grup replay edilmez.** |
| Yazma yolu | Grup kapanışı **WAL commit'inden SONRA** yazılır. Günlük yazılamazsa veri kaybı olmaz; yalnız `FLogProblem` işaretlenir ve PITR/replikasyon istekleri net hata verir. Yazma yolu hiçbir durumda başarısız olmaz. |
| Taban (base) | BASE kaydı yeni nesil açar. `Flags` bit0=1 → nesil kopması (`RESTORE`): replay orada **durur**. bit0=0 → saf checkpoint (`VACUUM`, `ALTER KEY`, ilk taban): replay **devam eder**. END kaydı motor LSN'ini taşır; açılışta uyuşmazlıkta nesil kopması yazılır ve öncesi için PITR açıkça reddedilir. |
| `AS OF TIMESTAMP` | Metin **yerel saat** kabul edilir ve UTC'ye çevrilir; `YYYY-MM-DD[ HH:MM[:SS[.mmm]]]`, `T` ayırıcı ve sondaki `Z` kabul. Hedef en eski tabandan önceyse **açık hata**; son kayıttan ileriyse son duruma **kırpılır** ve `Actual*` ile bildirilir. |
| `AS OF VERSION` | Günlük grup sırası (`seq`). Aynı sınır kuralları. |
| `ARCHIVE WAL SET DIR=` | Günlüğün **tam kopyasını** dizine çıkarır (birincil günlüğe dokunmaz); tekrarlandıkça tazeler. `RESET` yok: günlük kalıcıdır, silinirse PITR yeteneği kaybolur. |
| `ARCHIVE WAL LIST` | Günlük kapsamını tek satırda verir: `min_seq`, `max_seq`, `min_time`, `max_time`, `bases`. |
| `RECOVER TO [TIMESTAMP\|NOW]` | **Canlı dosyaya yazmaz.** `<db>.recovered` üretir (taban + ileri replay). Kullanıcı dosyayı açıp doğrular, `RESTORE FROM` ile devreye alır. Yanlış hedefe kurtarma canlı veriyi bozamaz. |
| v2 davranışı | v2'de bu dört komut **yoktur** → net `ecUnsupported`. `AS OF SEQUENCE` v2'de eskisi gibi çalışır. |

Kapılar:

| Kapı | Kontrol | Durum |
|---|---|---|
| `logchk` (10) | Günlük biçimi, yazıcı/okuyucu, CRC, kesik kuyruk, yarım grup, nesil kopması | **28/0** |
| `pitrchk` (11) | 3 fazlı yazım, `AS OF TIMESTAMP/VERSION`, ileri hedef kırpma, `BuildLogSnapshot` → dosya açılıp `Verify` TEMİZ + içerik birebir, kalıcılık, `ArchiveLogSet`, `LogRangeInfo` | **21/0** |
| `v3sqlchk` | SQL düzeyinde PITR: `AS OF TIMESTAMP/VERSION`, `ARCHIVE WAL SET/LIST`, `RECOVER TO`, kurtarma dosyasının gerçekten açılıp `VERIFY` geçmesi, canlı verinin bozulmaması; ayrıca `TestIndexInNegative` regresyonu | **167/0** |

Ölçüm (`pitrbench`, 20.000 satır / 100 commit, tek koşu, QPC):

| Ölçüm | Değer |
|---|---|
| Yazma (günlük açık) | 308 ms → **15,4 µs/satır**, 3,08 ms/commit |
| Günlük boyu | 1.934.517 bayt → **96,5 bayt/satır** |
| `AS OF TIMESTAMP` (tam sayım, 20k satır) | ortalama **556 ms** (3 koşu, 3/3 doğru) |
| `BuildLogSnapshot` (son durum) | **516 ms**, 1.228.800 bayt çıktı |
| `ArchiveLogSet` | **3 ms**, 1.934.517 bayt |

Not: `AS OF TIMESTAMP` her çağrıda taban kopyası + ileri replay yapar; tam
sayımda yüzlerce ms sürer. Hedefe en yakın taban seçimi zaten yapılıyor;
kalan maliyet replay'in kendisi.

### v4 — B+tree sıralı indeks ve aralık sorguları (2026-10-26)

Sıralı indeks artık **bellek içi B+tree**. `VDbBTree.pas` (`TVDbBTree`),
`TVDbSkipList` ile **aynı sözleşmeyi** uygular (aynı metot imzaları, aynı
karşılaştırıcı tipleri) ve `TIdxSkip` içinde damla yerine geçer; motor
tarafında başka hiçbir şey değişmedi.

| Konu | Yapılan |
|---|---|
| Düğüm | Yaprakta 96 anahtar (dolunca 48/48 bölünür), iç düğümde 96 ayırıcı + 97 çocuk. Yapraklar `Next` ile zincirli; aralık taraması zincir üzerinden akar. |
| Ayırıcı | `Entries[i]` = sağ çocuğun (`Children[i+1]`) alt sınır girdisi. Ekleme "E >= ayırıcı → sağa" kuralıyla iner, böylece ayırıcı hep **geçerli bir alt sınır** kalır. |
| Silme | **Yeniden dengelenmez** (birleştirme/ödünç alma yok): girdi yapraktan çıkar, boşalan yaprak ağaçta kalır ve taramada atlanır. Bu "lazy delete" B+tree arama değişmezlerini bozmaz (ayırıcı yalnız aşağı çekilir); veri kaybı riski düşük tutuldu. |
| Rank/sayım | Her düğümde `SubCount`; `RankBefore`/`CountRange` O(log N). `SubCount` bakımı kapıda ayrıca denetlenir. |
| Eş anlamlı | Aynı `Key` + farklı PK girdileri `FullCompare` ile toplam sırada; aralık sınırları anahtar karşılaştırıcısıyla (skiplist ile birebir). |
| Motor bağlantısı | `TIdxSkip.List: TVDbBTree`, `Create(Cmp.FullCompare, 96)`. `.idx` biçimi, WAL, checkpoint, PITR ve göç **değişmedi** (indeks türetilmiş veridir). |

**Ayrıca düzeltilen sorgu tercihi:** `WHERE <indeksli kolon> <op> sabit
ORDER BY <aynı kolon> LIMIT k` sorgusunda eski kod koşulsuz "akışlı top-N"
(full scan) seçiyordu. Artık WHERE sıralama kolonunu sınırlıyorsa önce indeks
dilimi denenir (`VdbSelBoundsCol`; OR/bilinmeyen düğümde eski davranış).
Ölçülen (50.000 satır, `tests/bench/idxbench`): `WHERE n >= 500 ORDER BY n
LIMIT 10` **16,6 → 3,0 ms**.

Kapı — `btreechk` (12), bağımsız oracle + skiplist paritesi:

| Kontrol | Durum |
|---|---|
| `LoadSorted`, rastgele ekleme, mükerrer reddi, `All()` sırası | 30/0 |
| `CollectRange` **64 sınır kombinasyonu** (HasLo/HasHi/LoInc/HiInc), `CountRange` (`= CollectRange uzunluğu`), `RankBefore` 400+400 sorgu | birebir |
| Silme (yarısı + tamamı), eş anlamlı anahtarlar, sayısal karşılaştırıcı (`"9" < "10"` bayt sırası ters) | birebir |
| **Yapı değişmezleri** (`CheckInvariants`): `SubCount`, ayırıcı ≤ sağ alt ağaç alt sınırı, sol alt ağaç < ayırıcı, yaprak zinciri sırası ve toplam sayı | sağlam |
| **Parite**: aynı işlem dizisi skiplist üzerinde; her adımda `All`/aralık/sayım aynı | aynı |

Ölçüm (`btreechk`, 50.000 girdilik kapı koşusu, QPC, tek koşu — 10.100
girdilik yapı üzerinde):

| İşlem | B+tree | skiplist |
|---|---|---|
| `LoadSorted` 10.100 girdi | **0,5 ms** | 1,1 ms |
| 100.000 dar aralık (21 anahtar) | 588,8 ms (5,9 µs/sorgu) | 503,4 ms (5,0 µs/sorgu) |
| 10.000 geniş aralık (401 anahtar) | **278,1 ms** | 306,9 ms |
| 10.100 rastgele ekleme | 8,8 ms | 8,2 ms |

Dürüst sonuç: **toplu yükleme ~2x hızlı, geniş aralık ~%9 hızlı, dar aralık
~%17 yavaş** (düğüm inişinde ~20 anahtar karşılaştırması; skiplist ~12).
Motor düzeyinde fark görünmüyor, çünkü SQL aralık sorgusu satır okuma/kopyalama
ile sınırlı (`idxbench`: `n BETWEEN 100 AND 120`, 1071 satır **2,3 ms** — iki
yapıda da aynı).

`idxbench` (50.000 satır, indeks `ix_n`, QPC, 3 koşu medyanı):

| Sorgu | Süre | Satır |
|---|---|---|
| `WHERE n BETWEEN 100 AND 120` (indekssiz tam tarama) | 60,9 ms | 1071 |
| `WHERE n BETWEEN 100 AND 120` (indeks) | **2,3 ms** | 1071 |
| `WHERE n = 42` | **0,1 ms** | 51 |
| `COUNT(*) WHERE n BETWEEN 100 AND 120` | **0,0 ms** (~0,1 ms) | 1 |
| `ORDER BY n LIMIT 20` | 13,9 ms | 20 |
| `ORDER BY n` (LIMIT yok, 50k satır çıkışı) | 101,8 ms | 50000 |
| `WHERE n >= 500 ORDER BY n LIMIT 10` | **3,0 ms** | 10 |
| `SELECT s ... BETWEEN` kapsayan indeks (`n INCLUDE s`) | **0,6 ms** | 1071 |
| `SELECT s ... BETWEEN` kapsamasız (satır okuma) | 2,1 ms | 1071 |

Not (dürüst sınır): `ORDER BY <indeksli kolon>` **LIMIT yokken** hâlâ tam
tarama + sıralama yapar (101,8 ms). İndeks sırasıyla 50.000 satırı tek tek
okumak rastgele seek ürettiği için daha yavaş kalıyor; bu yol bilinçli olarak
kapalı (`TryIndexOrder` LIMIT/OFFSET yoksa devreye girmez).

### v4'te bulunan ve düzeltilen sessiz yanlış sonuç (indeksli `IN`)

`sqltest` rasgele diferansiyel testi (T147) v4 sırasında **kararsız**
kırmızı verdi: aynı sorgu indeksli tabloda daha az satır dönüyordu. Kök
neden v4'ten önce de vardı, ama nadir tetikleniyordu:

- `-3` gibi negatif sabitler AST'de `TSqlUnaryOpNode(suoNeg)` düğümüdür,
  `TSqlLiteralNode` değil.
- `NarrowRows` indeks dilimi hesabı yalnız `TSqlLiteralNode` arıyordu;
  negatif öğeler **sessizce atlanıyordu**.
- Sonuç: `WHERE n IN (19,17,-3)` dilimi yalnız `[17,19]` oluyor, `n=-3`
  grubunun satırları **hiç okunmadan** sonuçtan düşüyordu. Hata yok,
  uyarı yok — yalnız eksik satır.
- Aynı hata PK üzerindeki `IN (-5, 1)` yolunda ve `= -3` biçiminde de
  vardı (`AsSimple` de literal arıyordu).

Düzeltme: tek bir yardımcı (`VdbInConstText`) hem düz hem negatif sabiti
çözer; **çözemezse daraltma yapılmaz** (güvenli taraf). Kapsanan yollar:
PK `IN`, ikincil indeks `IN` dilimi, `BETWEEN` ve
`=`/`>`/`>=`/`<`/`<=` daraltması.
Kapı: `v3sqlchk TestIndexInNegative` — indeksli satır yolu,
PK yolu ve COUNT yolu birebir; NULL içeren liste daraltmaz.

### v4 — replikasyon: mantıksal grup taşıma (2026-10-26)

Sayfa imajı **taşınmaz**; `<db>.log` mantıksal günlüğünün **tam grupları**
taşınır. Böylece taşınan birim, birincilin commit sınırıdır ve ikincil onu
**tek işlem** olarak uygular: yarım grup hiçbir zaman görünmez.

| Öğe | Karar |
|---|---|
| Taşıma dosyası | `<dest>\<slot>\g-<seq:020d>.vrgp` — 64 baytlık `VRG1` başlık (magic, sürüm, seq, tür, bayrak, veri boyu, CRC) + CRC'li gövde (kayıt çerçeveleri). `.tmp` + rename ile atomik. |
| Taban imajı | `<dest>\<slot>\bases\<ad>` — slotun **ilk** taşımasında birincilin en yeni tabanı kopyalanır ve bir BASE işareti bırakılır. |
| Konum | Yalnız `<db>.repl\<slot>.slot` dosyasında (`last_seq`). Yeniden başlatmada kaybolmaz. |
| Seq uzayı | İkincil gelen grubu **kendi** seq uzayına yeniden numaralandırır (her çerçevenin `Seq` alanı + `END` LSN'i yeniden yazılır, CRC yeniden hesaplanır). İki düğümün seq uzayı çakışmaz; ikincilin kendi PITR'ı tutarlı kalır. |
| Uygulama atomikliği | Grup = tek `BeginBatch`/`CommitBatch`. Uygulama sırasında yerel günlük yazımı `ReplSuspendLog(True)` ile kapalı, sonra `ReplAppendGroup` ile yeniden numaralanmış kayıtlar eklenir. Tekrar uygulama **idempotenttir** (değerler mutlaktır). |
| Retler | Bozuk/eksik dosya (CRC), **sırada boşluk** (grup dosyası silinmiş), nesil kopması taşıyan taban (`Flags bit0=1` → RESTORE) ve TCP ile replikasyon açıkça reddedilir. Boşluk **atlanmaz**: bitişik gruplar uygulanır, boşluktaki ve sonraki gruplar uygulanmaz, çağıran net hata alır. |
| Yazma hatası | `EndGroup` ve `AppendForeignGroup` yazma hatasında segment boyunu geri keser; yırtık kuyruk sonraki grupları gizlemez. |
| v2 | `ReplSupported = False`; `ReplAppendGroup` açık hata verir. Protokol v3 sayfa motorunundur. |

**Bulunan ve düzeltilen gerçek kusur:** ikincil taban kurulumu `RestoreFrom`
kullandığı için günlüğünde **nesil kopması** (`bit0=1`) oluşuyordu.
`LogRangeInfo` en son sürümü **ilk** tabandan replay ederek hesapladığı için
kopmada duruyor ve ikincilin `maxSeq`'ini olduğundan **küçük** bildiriyordu →
`AS OF VERSION` ikincilde taban anını (boş/az veri) döndürüyordu. Düzeltme:
en son sürüm **son** tabandan ileri replay edilerek bulunur (`LogRangeInfo`).
Kopmadan öncesi için PITR yine açıkça reddedilir — bu doğru davranıştır,
ikincil o geçmişe sahip değildir.

Kapı — `replchk` (13): iki **gerçek** veritabanı, SQL katmanı karışmadan ham
KV karşılaştırması.

| Kontrol | Durum |
|---|---|
| Slot yaşam döngüsü (oluştur/tekrar etkisiz/iki etkin slot yok) | 37/0 |
| Taban + grup taşıma, ikincil RESTORE + tek işlem uygulama | ✔ |
| KV düzeyinde birebir (`ScanAll` anahtar **ve** değer) | 200 → 220 anahtar |
| Artımlı devam (2 yeni grup: 50 güncelleme + 10 silme, 30 ekleme) | ✔ |
| Boş PUMP etkisiz (0 grup) | ✔ |
| Yeniden başlatmada konum kalıcı | ✔ |
| Idempotent tekrar (konum 1 geri alınır, veri değişmez) | ✔ |
| Bozuk taşıma dosyası reddi + veri bozulmaz + onarım sonrası devam | ✔ |
| Sırada boşluk reddi (yalnız bitişik grup uygulanır, boşluk atlanmaz) | ✔ |
| Nesil kopması taşınmaz | ✔ |
| İkincil PITR kendi seq uzayında, içerik birincille birebir | ✔ |
| Durdur / durum / sil (olmayan slot reddi) | ✔ |

Ayrıca `v3sqlchk TestReplicationV3` (SQL düzeyi: slot, birincil/ikincil,
artımlı, boş `PUMP`, TCP reddi, yeniden açılış, `DROP`) — **179/0**.

### v3.2 — çok okuyucu / tek yazıcı + busy timeout (2026-10-26)

Kilitleme modeli artık **paylaşımlı okuyucu / tam yazıcı** üzerine kurulu
(rollback-journal kipinin SQLite karşılığı; WAL okuyucu eşzamanlılığı
bilinçli olarak yok):

| Öğe | Karar |
|---|---|
| Dosya açılışı | İki taraf da `fmShareDenyNone` ile açar; **karar veren kilit** `LockFileEx`/`flock`'tur. Önceki `fmShareDenyWrite` OS düzeyinde ikinci açılışı engelliyordu ve busy timeout'a yer bırakmıyordu. |
| Okuyucu | `VDbLockStream(S, AShared=True)` — paylaşımlı kilit. **N okuyucu aynı anda** açılır. |
| Yazar | Tam kilit. Alınamazsa `ABusyMs` boyunca beklenir; sonunda `veritabani mesgul: yazar kilidi ... alinamadi (baska bir yazma oturumu acik)` hatası. |
| Varsayılan busy | **0** (hemen hata) — v2 ve önceki v3 davranışıyla aynı, SQLite'ın varsayılan busy handler'ı gibi. Beklemek isteyen `VdbOpenWithBusyTimeout` / `TVdbBackendV3.Create(..., ABusyMs)` kullanır. |
| Bekleme ölçümü | Gerçek geçen süre (`GetTickCount64`), sabit sayım değil: `Sleep(20)` Windows'ta 31 ms'ye çıktığı için eski sabit sayım `busy=400` isteğini 630 ms'ye uzatıyordu. Ölçülen: `busy=400 → 397 ms`, `busy=350 → 356 ms`, `busy=0 → 1–2 ms`. |
| Salt-okunur oturum | `VdbOpenReadOnly` / `TVdbBackendV3.CreateReadOnly`: **hiç yazmaz**. `IsReadOnly=True`; `Put/BeginBatch/CommitBatch/Compact/RestoreFrom/Rekey` açık hata verir. `<db>.log` **açılmaz** (okuyucu günlük dizini oluşturmaz). |
| WAL ve okuyucu | `TVDbPageWal.Open(AReadOnly)` dosyayı `fmOpenRead` açar, **yaratmaz**. Onaylanmış çerçeveler `InstallReadOnlyPage` ile **bellek katmanına** alınır (`FRoPages`); `LoadFrame` önce bu katmana bakar. Checkpoint/truncate yok. |
| Çökme sonrası okuma | Salt-okunur oturum, WAL'de duran onaylanmış çerçeveleri disk belleğine yazmadan uygular: `.odb` ve `.wal` **bayt bayt değişmez** (kapıda ölçülür). |
| Çok yazarlı | Hâlâ **tek yazıcı**. Çok yazarlı MVCC ayrı (son) dilimdir. |

Kapı — `lockchk` (14): gerçek **çocuk süreçler** (kendini farklı argümanlarla
çalıştırır), yani kilit gerçek işletim sistemi kilididir.

| Kontrol | Durum |
|---|---|
| Aynı anda 2 salt-okunur oturum, 500 satır birebir | 17/0 |
| Okuyucu varken yazar: busy=400 → 397 ms sonra "meşgul" | ✔ |
| İki yazar: busy=0 → 2 ms, busy=350 → 356 ms | ✔ |
| Yazar varken salt-okunur oturum: "meşgul" (paylaşımlı kilit yok) | ✔ |
| Salt-okunur `Put` reddi, `VERIFY` geçer, `<db>.log` oluşmaz | ✔ |
| Yazıcı kapanınca okuyucu 501 satır + son anahtarı görür | ✔ |
| Çökme sonrası WAL katmanından 200 satır, diskte 0 bayt değişim | ✔ |
| 32 bit + 64 bit | yeşil |

**Bulunan ve düzeltilen gerçek kusur (iki tane):**
1. `VdbOpenReadOnly` önce `VdbFamilyOfFile` ile biçim keşfi yapıyordu; o
   yardımcı dosyanın ilk 4 baytını okur. Yazar tam aralık kilidi tutarken bu
   okuma başarısız oluyor ve kullanıcı **yanlış** bir "Veritabani yok" hatası
   alıyordu. Artık biçim doğrulaması motorun kendi açılışında yapılır ve kilit
   hatası doğru mesajla döner.
2. Busy beklemesi sabit `Sleep(20)` sayımıyla ölçülüyordu; Windows zamanlayıcı
   çözünürlüğü hedefi %50'den fazla aşırtıyordu. Gerçek süreye çevrildi.

### v3.2 — `.idx` varint (VER 2) (2026-10-26)

`.idx` kaydı 16 bayttan **değişken uzunluğa** indi: `Key(8) | PageNo(varint) |
Slot(varint)`. Satır anahtarı `VDbHashKey` ile üretilen sanki-rastgele 64 bit
olduğu için anahtar **ham** kalır (varint onu büyütürdü) ve **sıralama
yapılmaz** — heap hash sırası korunur, checkpoint'te ek maliyet yok.

| Ölçüm (`idxchk`, 50.000 satır) | Sonuç |
|---|---|
| `.idx` boyu | 800.064 B → **539.396 B** (−32,6%) |
| satır başına | 16,0 B → **10,8 B** |
| idx ile açılış / tam tarama | 6 ms / 18 ms |
| Kapı | idxchk **19/0** (VER 1 uyumu + varint sınırları) |

Yazan yalnız VER 2 üretir; okuyan VER 1'i de okur. Eski ikili VER 2'yi
reddedip tam tarama yapar (`.idx` türetilmiş veridir; kayıp yok). CRC kodlanmış
bayt akışı üzerinde hesaplanır.

### v3.2 — satır INT varint (2026-10-26)

Satır yükü şeması korundu (`ctype | vlen(i32) | payload`); INT yükü **zigzag
LEB128** oldu. `vlen = 1..7` varint, `vlen = 8` **eski biçim** (ham LE Int64) —
hem okunur hem de 8 bayttan fazla gereken değerler için yazılır, böylece
belirsizlik yok. Eski satırlar okunur; eski ikili yeni satırda INT alanını
görünce satırı açıkça reddeder (sessiz yanlış veri yok).

| Ölçüm (`rowmeas`, 100.000 satır, 6 INT + 2 TEXT) | Önce | Sonra |
|---|---|---|
| `.odb` | 14.131.200 B | **10.752.000 B** (−23,9%) |
| satır başına | 141,3 B | **107,5 B** |
| toplu ekleme / `SUM(a)` / açılış | 1167 / 20 / 3398 ms | 1133 / 19 / 3372 ms |

Tek çözüm noktası `VDbIntFromPayload` (`DecodeRow`, `VDbDecodeRawRowP`,
`VDbRowFromOffsetsP`, `VDbColFromOffsetsP` ve `VDbExecutor`'ın 8 ham-okuma hızlı
yolu). Kanonik olmayan varint reddedilir.

Düzeltilen hata: `V shr 63` Pascal'da **mantıksal** kaydırma olduğu için zigzag
negatiflerde bozuktu (`-9223372036854775807` → −2). Kapı testi yakaladı.

Gerçek veri: 6399 satırlık eski biçimli `mtakip.odb` kopyası eski ve yeni ikili
ile aynı FNV-1a özetini verdi (`1DF4A420FF9A2488`).

Kapı: `v3sqlchk` **186/0** (`rowint`: 12 uç değer, `ORDER BY`, `WHERE`,
`VERIFY`, 1 baytlık alan, elle kurulmuş eski satır, bozuk varint reddi).

### Sıradaki sürüme ertelenen (v4 sonrası)
- Zone map'in sayfa düzeyinde yeniden ele alınması
- Satır gövdesi varint/delta kodlama (F3-1'in kalanı)
- Dosya boyutu (PK'nin ikinci kez yazılması, hücre başlığı sıkıştırma)
- Bloom filtresi, merge JOIN, ifade bytecode
- Çok yazarlı MVCC

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
- [x] 2.8 `MIGRATE TO v3` + `MIGRATE VERIFY` — `VDbMigrate.pas` (KV düzeyinde birebir kopya: sema + satır + dizin kayıtları; SQL yeniden kodlama YOK) ve SQL'de `MIGRATE TO v3 '<dosya>'` / `MIGRATE VERIFY '<dosya>'`. Doğrulama: anahtar sayısı eşitliği + her kaynak anahtarın hedefte **bayt bayt** aynı olması (sayı eşit + tüm anahtarlar bulundu ⇒ küme eşitliği). `.colkey` dosyası da kopyalanır. `migchk` kapısı **13/13**: var olan hedef reddi, v3 kaynaktan göç reddi, SQL yolu, göç sonrası `COUNT/SUM/PK/indeksli arama/ilk-son satır`. **200k satır: 200001 kayıt, fark=0** (kopya 1000 ms, doğrulama 1079 ms); boyut v2 16.201.267 B → v3 13.840.384 B (**%85,4**). **(2026-10-25)** Aynı motor kullanıcıya **`vdbmig` CLI** olarak sunuldu: `copy` / `verify`, sabit çıkış kodları, `--dry-run`, var olan hedefi reddetme, doğrulama tutmazsa karantina; CI'da `vdbmig.lpi` derlenir ve gerçek bir v2 dosyası üzerinde üç kontrol koşar. Ayrıntı: `GOC_V2_V3.md`.
- [x] 2.9 v3 tam `sqltest` koşusu; kalan testler sınıflandırılır (kapsam / hata / v3.1) — koşucu test başına `try/except`'e çevrildi (`TTestRec`/`BuildTests`), `--backend=v2|v3` (bilinmeyen backend `exit 2`). **v2: 3116/3116, atlanan=0**; **v3: 2244 geçen, 0 kalan, 59 ATLA**. ATLA ölçütü: gövdesinde `kv.`/`pkv.`/`myKv`/`TVDb.Create` geçen testler (33+24) + yalnız v2 yönetim komutlarını sınayanlar (T15, T79); ayrıca `T19` içindeki `VACUUM` bölümü. Bu koşu 6 gerçek kusur ortaya çıkardı ve hepsi düzeltildi: (a) zone map yolu `Kv = nil` iken `DataSeqValue` okuyup **sıradan `WHERE int = 7` sorgusunda AV** veriyordu (55+ doğrulama düştü); (b) `VDbJson.VDbImportJson` doğrudan `Tb.Kv.BeginBatch` çağırıyordu (v3'te AV) → `Tb.BeginBatch`; (c) **tablo düzeyi `UNIQUE(...)` parser tarafından yutuluyordu** (v2'de de!) → `TSqlCreateTableStmt.Uniques` + UNIQUE indeks; (d) `ON CONFLICT(<unique hedef>)` hiç uygulanmamıştı → `FindConflictPk` + çakışmanın `CheckConstraints`'ten önce çözülmesi (`ExcludePk`); (e) yönetim komutları `Kv = nil` iken AV → `ecUnsupported`; (f) CI'da `crashtest` 42 dk asıldı (konsolsuz alt süreçte Windows hata kutusu) → `SetErrorMode` + CI'da 300 sn sert sınır. CI'ya `sqltest --backend=v3` kapısı eklendi.
- [x] 2.10 v3 kapsam raporu `V3_KAPSAM.md` — sonuç tablosu, 59 ATLA'nın üç gerekçe grubu (tek tek liste), düzeltilen 6 kusur, v3.0 dışı yeteneklerin sürüm eşlemesi (3.1-3.7), yeniden üretme komutları.

### Sprint 3 — Eşitlik ve kapı (Gün 11-15)

- [x] 3.1 `Verify` v3'te (sayfa CRC + heap bütünlüğü + anahtar dizini) — `TVdbPageEngine.Verify` + `TVDbPageStore.VerifyFreeList`; `IVDbBackend.Verify` üzerinden `VERIFY` SQL komutu v3'te çalışır (v2'de `TVDb.Verify`'e devam). Denetimler: tüm sayfalarda yapı + CRC32, sayfa başlığındaki numara, freelist trunk zinciri (döngü/aralık/tekrar/sayaç), heap hücre başlığı ve **tüm taşma zinciri** (her halka + ilan edilen uzunluk), yinelenen anahtar, dosyadaki anahtar sayısı = bellek dizini. Onaylanmamış WAL çerçevesi varsa önce checkpoint; açık parti/işlemde net ret. Kapılar: `backendchk` **41/41** (sağlıklı dosya, taşma zincirleri, açık parti reddi, bozulma enjeksiyonu), `v3sqlchk` **49/49** (SQL `VERIFY` + işlem içinde ret).
- [x] 3.2 `BACKUP` / `RESTORE` v3'te — yedek = checkpoint sonrası **sayfa imajlarının bayt-bayt kopyası** (tek `.odb`; `.idx`/`.wal` kopyalanmaz). `TVDbPageStore.CopyCommittedTo` meta sayfasını yeniden üretir, `.tmp` + fsync + rename ile yarım yedek bırakmaz; kaynak dosya ikinci kez açılmaz (Windows paylaşım kilidi sorunu yok). `RESTORE`: kaynak `VDB3`/sürüm 3 doğrulanır, motor kapatılır, mevcut dosya `.bak`a taşınır, yeni dosya atomik yerine konur, eski `WAL`/`.idx` silinir, motor yeniden açılır; hata olursa `.bak`tan geri dönülür. SQL katmanı `TVTableDb.ReloadSchema` ile şemayı/indeksleri yeni dosyadan yükler. Kapılar: `backendchk` **52/52** (bağımsız motorla yedek doğrulama, taşma değeri, restore sonrası VERIFY, açık parti reddi, v3 olmayan kaynak reddi), `v3sqlchk` **55/55** (`BACKUP TO` / `RESTORE FROM` + restore sonrası şema/veri/VERIFY). `crashtest` işaret dosyası yarışı da giderildi (**11/11**).
- [x] 3.3 `Compact` (boş sayfa/ölü bayt geri kazanımı); `AutoCompact` varsayılan **False** kalır — v3'te `VACUUM`, canlı kayıtları **yeni ve sıkışık bir dosyaya** yazar (`TVdbPageEngine.ScanAll` → yeni motor `Insert`), `Close` ile checkpoint+`.idx`, sonra dosya **atomik** değiştirilir (eski dosya `.bak`, eski `WAL`/`.idx` silinir, motor yeniden açılır, `TVTableDb.ReloadSchema`). `IVDbBackend.Compact` eklendi (v2 `TVDb.Compact`'a devreder); RESTORE ile ortak `SwapDbFile` (yarım değişimde `.bak`'tan geri dönüş). `VACUUM`/`RESTORE` açık partide reddedilir; yazılan anahtar sayısı kaynakla karşılaştırılır. Ölçülen: 2.500 canlı / 2.000 silinmiş kayıt + 200×6 KB taşma değeri olan dosya **2.039.808 → 200.704 bayt**. `AutoCompact` v3'te yok (v2'de de varsayılan kapalı). Kapılar: `backendchk` **61/61** (boş veritabanı VACUUM'u 4096 bayt), `v3sqlchk` **60/60**, `sqltest` v3 **2252/0/58** (`T15_Bakim` ve `T19` VACUUM bölümü artık v3'te koşar), v2 **3116/3116**; `pagechk`/`storechk`/`heapchk`/`idxchk`/`migchk`/`crashtest` yeşil.
- [x] 3.4 Şifreleme: sayfa düzeyinde AES-GCM — sıra sabit: sayfa imajı → `PageSeal` (CRC32) → **AES-256-GCM zarfı** (`nonce 12 | şifre 4096 | tag 16` = 4124 bayt). AAD = `'VDB3PG' | sayfaNo(4) | tuz(16)`; böylece zarf başka sayfaya/dosyaya taşınamaz ve etiket doğrulanmadan hiçbir düz metin açığa çıkmaz. Meta sayfa 0 **düz metin** kalır (sır tutmaz): bayrak, tuz, PBKDF2 iterasyonu ve 16 baytlık HMAC anahtar doğrulayıcı orada durur. `VDbPageCrypto.pas` eklendi (zarf + tuz + parola türetme + parmak izi). Depo: şifreli dosyada sayfa 1..N `4096 + (no-1)*4124` adresinde; yeni uzatılan sayfa sıfır kabul edilir (şifreli zarf yok). WAL çerçeveleri de aynı zarfla yazılır (başlıkta bayrak/anahtar doğrulayıcı/tuz); çökme sonrası kurtarma anahtarla çözer. API: `TVdbPageEngine.CreateWithKey/CreateWithPassword`, `TVDbBackendV3.CreateWithKey/CreateWithPassword`, `Encrypted`, `KeyFingerprint`; `RESTORE` kaynak/hedef şifreleme biçimi ve anahtar doğrulayıcı eşleşmezse reddeder; `VACUUM` aynı anahtarla yeni dosya üretir. `backendchk` `TestV3Encryption` **21/21** (düz metin sızıntısı yok, anahtarsız/yanlış anahtar net hata, bozuk zarf reddi, şifreli yedek, farklı anahtarlı RESTORE reddi, şifreli WAL + çökme kurtarma, parola modu). Kapılar: `backendchk` **82/82**.
- [x] 3.5 Replikasyon — **v4'te açıldı** (3.5'te bilinçli olarak kapalıydı: `ecUnsupported` + "v3.1: mantiksal gunluk ile gelecek"). Bugünkü davranış: sayfa imajı değil **mantıksal grup** taşınır (`<dest>\<slot>\g-<seq>.vrgp`, 64 B `VRG1` başlık + CRC'li gövde, `.tmp`+rename atomik); slotun ilk taşımasında taban imajı kopyalanır (`bases\`), ikincil onu `RestoreFrom` ile kurar ve grupları **tek işlem** olarak uygular. Konum yalnız `<db>.repl\<slot>.slot` dosyasında (`last_seq`) — yeniden başlatmada kalıcı. İkincil gelen grubu **kendi seq uzayına** yeniden numaralandırır (Seq + END LSN + CRC), böylece kendi PITR'ı tutarlı kalır. Retler: bozuk/eksik dosya, **sırada boşluk** (atlanmaz), nesil kopması (`Flags bit0=1`), TCP. v2'de `ReplSupported=False` + `ReplAppendGroup` açık hata. **Bulunan kusur:** ikincil taban kurulumunun nesil kopması `LogRangeInfo`'yu erken durdurup `maxSeq`'i küçük bildiriyordu → `AS OF VERSION` ikincilde yanlış (taban anı) sonuç. Düzeltme: en son sürüm **son** tabandan replay edilerek bulunur. Kapılar: `replchk` **37/0** (13 grup; iki gerçek DB, ham KV birebir, bozukluk/boşluk/nesil/tekrar senaryoları) + `v3sqlchk TestReplicationV3` **179/0**.
- [x] 3.6 PITR / zaman yolculuğu — **v3.2'de `AS OF SEQUENCE` açıldı.** Sayfa WAL'i mantıksal günlük tutmaz, ama sayfa imajları WAL penceresindeki **herhangi bir commit'in tam veritabanı görüntüsünü** yeniden kurmaya yeter. Uygulama: `TVdbPageWal.Recover(..., MaxCommits)` (ilk N commit'te okumayı keser), `TVdbPageEngine.RecoverLimit` (Open'da sınırlı kurtarma), `TVDbPageStore.CopyBaseImageTo` (son checkpoint tabanının **ham** kopyası; deponun kendi handle'ı üzerinden — dosya tam aralık kilidiyle kilitli olduğu için başka handle'dan okuma Windows'ta 0 bayt döner), `IVdbBackend.ScanAllAt`/`AsOfMaxSequence`, `TVTableDb.ScanRowsAt`, `VDbExecutor.BuildAsOfRows` (nil `Kv` → anlık görüntü yolu). Anlık görüntü **geçici** bir kopyada (`<db>.asof<pid>_<n>`) kurulur; canlı dosyaya yazılmaz, geçici dosyalar silinir. **Sıra numarası anlamı v3'te farklıdır:** v3'te N = WAL penceresindeki **commit** sayısı (v2'de 0 tabanlı kayıt indeksi); sınır aşılırsa son commit'e kırpılır. `AS OF TIMESTAMP/VERSION`, `RECOVER TO`, `ARCHIVE WAL` mantıksal günlük gerektirdiği için hâlâ `ecUnsupported`. Test: `sqltest T155` (iki backend; INSERT/UPDATE/DELETE öncesi-sonrası, filtre/sıra/LIMIT/COUNT, sınır kırpma, alias, yan etkisizlik + geçici dosya artığı yok, checkpoint sonrası açık hata), `v3sqlchk TestPitrUnsupported` (AS OF SEQUENCE okur; VERSION/TIMESTAMP/ARCHIVE/RECOVER reddedilir).
- [x] 3.7 Zone map v3'te **kapalı** (düz tam tarama). Budama yalnız v2'nin ham kayıt yolu (`PrepareRawScan`) ile mümkündür; v3 heap hücre biçiminde yeniden inşa v3.2'ye bırakıldı. Doğrulama `v3sqlchk` `TestZoneMapFallback` **22/22**: 3000 satır, 8 aralık + eşitlik/`IN`/`<>`/karma sorgular Pascal'da hesaplanan beklentiyle birebir; yeniden açılışta aynı sonuç + `VERIFY`. Belgelendi: `V3_KAPSAM.md` §4/§5.
- [x] 3.8 win32 tam kapı: **`kalan=0`**. `backendchk 82/82`, `v3sqlchk 128/128`, `pagechk 21/21`, `storechk 15/15`, `heapchk 20/20`, `idxchk 17/17`, `migchk 13/13`, `crashtest 11/11`; `sqltest` v2 **3116/0/0**, v3 **2252/0/58**.
- [x] 3.9 win64 tam kapı: **`kalan=0`**, iki optimizasyon düzeyinde de (`-O-` ve `-O1`, `ppcrossx64 -Px86_64 -Twin64`). Sekiz kapı win32 ile **aynı** sayılarda yeşil. `sqltest` v2 **3081/0/0**, v3 **2217/0/58** — win32'den **35 kontrol eksik**; eksikliğin tamamı DLL/OpenSSL'e bağlı alt dallardır ve **hata değildir**: `130. Extension/Plugin` (25→8), `179. pgwire TLS/OpenSSL` (10→0), `128. Cross-Platform DLL/C API` (16→13), `131. paralel ABI` (58→53). `sqltest` bu dallarda "vdbapi.dll yok → atlandı" / "TLS testi (OpenSSL DLL bulunamadı)" yazar; bu ortamda yalnız **32 bit** eklenti/OpenSSL ikilileri var. Linux de aynı sayıları verir (3081/2217), yani fark platformdan değil **ikili (binary) yokluğundan** kaynaklanır.
- [x] 3.10 Linux/WSL tam kapı: **`kalan=0`** (Ubuntu 22.04, FPC 3.2.2 x86_64, `/mnt/d` = DrvFs). Sekiz kapı da yeşil; `sqltest` v2 **3081/0/0**, v3 **2217/0/58**. Bu kapı **üç gerçek taşınabilirlik kusuru** ortaya çıkardı ve hepsi düzeltildi (aşağıda).
- [x] 3.11 `crashtest` 11/11 (üç platform), fuzz (T111, 3VL, T147 SQLancer) v3'te temiz — `crashtest` 11/11 (Linux dahil). `T111` v3'te koşar, ama v3'te ham/akışlı yol (`Kv`) olmadığı için oracle'ı zayıflar (aynı yol iki kez). `T147` yalnız v2 yolu sınadığı için ATLA. Bu boşluğu kapatmak için **bağımsız oracle'lı yeni fuzz** eklendi: `v3sqlchk TestFuzzOracle` **8/8** — 400 satır (`a`/`s` NULL dahil), **240 rasgele 3VL yüklemi** (`= <> < <= > >=`, `IS [NOT] NULL`, `IN`/`NOT IN` (listede NULL), `BETWEEN`/`NOT BETWEEN`, `AND`/`OR`/`NOT`, parantez), beklenen küme Pascal'da TRUE/FALSE/UNKNOWN ile hesaplanır; `COUNT(*)` **ve** `ORDER BY id` satır kümesi birebir karşılaştırılır, tohum sabit (tekrarlanabilir). Yeniden açılış sonrası 40 sorgu yine birebir + `VERIFY`.
**.idx politika kararı (2026-10-25, v3.1'de değişti):** v3.0'da varsayılan
**boyuta göre otomatik** idi (`IdxMaxBytes`, 50 MB). **v3.1: eşik kaldırıldı,
`.idx` her zaman yazılır.** Gerekçe: `.idx` türetilmiş ve silinebilir; boyut
sınırı veri güvenliği sağlamıyor, buna karşılık büyük veritabanlarında açılışı
tam taramaya düşürüyordu. `backendchk` bu politikayı 6 kontrolle sınar
(`idxpol)`, `TestV3IdxPolicy`): kapanışta yazılma, hızlı açılış, `.idx` yokken
tam tarama ve **veri kaybı olmaması**.

- [x] 3.12 Ölçüm tablosu `hiztesti.md` + `speedtest.md` + `readme*.md` güncellenir — **yalnız ölçülmüş sayılar**. Üç performans düzeltmesi (aşağıdaki bölüm) ve aynı harness'lı v2↔v3 tablosu (`benchcmp --backend=`, 200k × 3 kolon, üç tekrarın medyanı, art arda aynı makine): veri dosyası **19.278.424 → 15.527.936 B (−%19,5)**, ama **`.odb.idx` 3.520.080 B** ile diskteki toplam **19.278.555 → 19.048.016 B (yalnız −%1,2)**; açılış **984 → 32 ms (31x)**, PK **6,25 µs (eşit)**, parse **3,90 µs (eşit)**, toplu INSERT **4,455 → 6,640 µs**, autocommit **0,431 → 0,557 ms**, `COUNT(*)` **31 → 62 ms**. Dürüst sonuç: **üç metrik geriliyor** (toplu yazım ~1,5x, `COUNT(*)` 2x, tek satır ~1,3x) ve dosya boyutu hedefi yalnız `.odb`'de tutuyor; kök nedenler ve v3.1 planı ölçümle birlikte yazıldı. Sayfa harness'ı (`benchv3`, 32 B değer) ayrı tablo: 9.756.672 B (48,8 B/satır), açılış 16 ms (`.idx`) / 79 ms (tam), yazım 1,88 µs.
- [x] 3.13 `git tag v3.0` + push; CI yeşil — `v3.0` etiketi `2a649df`'e atıldı ve push edildi (CI #28 yeşil: 8 kapı + sqltest v2/v3).

## Sprint 4 (v3.1) — v3.0'da kapanmayan hedefler

v3.0'ın dürüst özeti üç gerileme bırakmıştı: `COUNT(*)` 62 ms, autocommit
0,557 ms, toplu yazım 6,64 µs. Üçü de **ölçümle** kök nedene indirildi ve
kapatıldı; dördüncü iş (dosya uzatma) ölçülen bir maliyetti.

- [x] 4.1 **`COUNT(*)` O(1)** — `TVdbBackendV3` içinde tablo başına **canlı**
  satır sayacı (`FTagCounts`), kalıcı sayaç kaydı yok. Kurulum sırası: açılışta
  `.idx` özeti → boş veritabanında taban 0 → yoksa ilk `COUNT` isteğinde bir kez
  tam tarama (`FTagCountsValid`). `TagAdd`/`MergeTagDeltas` bayrak False iken
  haritayı kirletmez; `AbortBatch` deltaları atar, `CommitBatch` birleştirir.
  Sayaç `.idx`'e gömüldü (`TVdbIdxTagEntry`, başlıkta `TagCount`/`TagCrc`);
  aynı LSN'de yazıldığı için bayatlama ayrı bir doğrulama gerektirmez,
  CRC uyuşmazsa yalnız özet atılır. VACUUM anahtar kümesini koruduğu için
  sayacı **korur**; `SwapDbFile` (RESTORE) geçersiz kılar. **Ölçülen:
  62 ms → 0,1 ms.**
- [x] 4.2 **`.idx` her zaman yazılır** — v3.0'ın 50 MB eşiği kaldırıldı
  (`VDB_V3_IDX_MAX_BYTES`/`IdxMaxBytes` koddan çıktı). `backendchk` 6 kontrol
  (`idxpol`, `TestV3IdxPolicy`).
- [x] 4.3 **WAL'e yalnız işlem başına değişen sayfalar** — kök neden: `Commit`
  "o ana kadar kirli olan **tüm** sayfaları" yazıyordu; sayfalar checkpoint'e
  kadar kirli kaldığı için her autocommit INSERT önceki tüm kirli sayfaları
  yeniden yazıyordu (O(kirli sayfa)/commit). Artık her çerçevede `TxnMark`
  var; commit yalnız `FTxnId` işaretli yerleşik sayfaları + o işlem işaretli
  pending imajlarını yazar. Meta çerçevesi de yalnız `FStructDirty` (sayfa
  sayısı/freelist değişti) iken yazılır; LSN'i commit kaydı taşır.
  **Ölçülen (64 çerçeveli havuz, 2000 tek satır commit): 63.373 → 8.252
  B/commit; fsync'siz commit 0,585 → 0,098 ms.** Ayrı `fsyncbench` aracıyla
  disk fsync tabanı **0,330 ms/islem** (4 KB ve 8 KB aynı) — yani autocommit'te
  kalan süre neredeyse tamamen dayanıklılık bedelidir.
- [x] 4.4 **Toplu dosya uzatma** — her yeni sayfada ayrı `SetSize` yerine
  256 KB'lık parça (`VDB_GROW_BYTES`), kapanışta mantıksal boya kırpma
  (`TrimToLogical`). `Stats.FileBytes` artık **mantıksal** boyu verir; ölçüm
  araçları dosya boyunu kapanıştan sonra okur. **Ölçülen (benchv3, 32 B):
  yazım 1,88 → 1,32 µs/satır** (benchcmp toplu: 6,64 → 5,79 µs).
- [x] 4.5 **Tarama hattı** — `ScanRawIterAll` artık sonuç kümesi biriktirmez,
  satırları doğrudan akıtır (eski yol her satırda `SetLength(+1)`), `ScanAll`
  kapasite ikiye katlar, sıfır-kopya `ScanAllRaw` eklendi (sayfa pinli, hücre
  göstericisi doğrudan). **Ölçülen (benchv3, 200k × 32 B): ham tarama
  12,0 ms (kopyalı) → 9,6 ms (sıfır-kopya).**
- [x] 4.6 **Ölçüm altyapısı** — `benchcmp`/`benchv3` süreleri QPC ile
  mikrosaniye çözünürlüğünde (`GetTickCount64` ~15,6 ms kuantalıyordu; tek
  atımlık `COUNT`/açılış ölçümleri yanıltıcıydı). Yeni `tests/bench/fsyncbench`
  fsync tabanını ölçer.
- [x] 4.7 **Kapılar** — üç platformda `kalan=0`: `backendchk` **108/108**
  (19 yeni sayaç kontrolü: toplu ekleme, tek silme, `AbortBatch`,
  `CommitBatch`, yerinde güncelleme, etiket değişimi, `.idx` özetinden açılış,
  bayat `.idx` reddi + tarama, `.idx` silinmesi, VACUUM, yeniden açılış),
  `v3sqlchk` 128, `pagechk` 21, `storechk` 15, `heapchk` 20, `idxchk` 17,
  `migchk` 13, `crashtest` 11; `sqltest` v2 3116/0/0 (win64+Linux 3081),
  v3 2252/0/58 (2217).

### Sprint 3.12: performans düzeltmeleri (ölçümle bulunan üç darboğaz)

Kabul hedeflerinin üçü tutmuyordu (`toplu INSERT 8,045 µs`, `autocommit 1,168 ms`,
`COUNT(*) 63 ms`). Üçü de ölçümle kök nedene indirildi; ikisi üretim kodunda
düzeltildi, üçüncüsü tasarım maliyeti olarak belgelendi:

1. **`Flush` her autocommit sonrası tam checkpoint yapıyordu** (WAL + tüm kirli
   sayfaların dosyaya yazımı + budama). SQL katmanı `Flush`'ı her satırdan sonra
   çağırıyor. Artık `Flush` = yalnız `Commit(True)`; checkpoint eşikte/açık
   çağrıda/kapanışta/yedekte/VACUUM'da. **1,168 → 0,557 ms/satır.**
2. **Pending sayfa imajları `array of TPending` (kayıt başına 4 KB) idi ve her
   tahliyede `SetLength(+1)` yapılıyordu.** 200k × 64 B yazımda 3.488 tahliye
   = tahliye başına ~75 µs, toplam ~265 ms yalnızca büyütme. İmajlar artık ayrı
   ayrılır, dizi yalnız gösterici tutar, kapasite ikiye katlanır; pending araması
   lineer tarama yerine hash. Motor `Insert` **2,99 → 1,6 µs/anahtar**
   (benchv3 yazımı 2,34 → 1,88 µs/satır).
3. **Parti `TDictionary` dolaşım sırasıyla (rastgele) uygulanıyordu.** Sayfalara
   sıçramalı yazım sıralı yazımdan yavaş. Parti artık **giriş sırasında**
   uygulanır (`FOrder`). Toplu INSERT **8,045 → 6,64 µs/satır**.

Yan bulgu (düzeltildi): parti içinde `Backend.Delete`, `AddOrSetValue`'dan
**sonra** `ContainsKey` sorduğu için hiç olmayan anahtar için de `True`
dönüyordu. `backendchk`'e bu sözleşme için kontrol eklendi (**83/83**).

Ayrıca iki **test kusuru** düzeltildi (üretim kodu değil):
`VEC ANN cizgi kesin kume ile ayni` sorgu noktasını doğrunun tam üzerine
koyuyordu; simetrik noktalar (5/15, 6/14) **tam eşit mesafede** olduğu için K
sınırındaki seçim tanımsızdı ve iki platformda bir kez kırmızı verdi — ikinci
bileşen kaydırıldı. `T09p_SlowQuery` düşük eşik adımında 1 ms'lik ölçüm
kaçarsa kayıt oluşmuyor, test de boş sonuç kümesinde `Rows[0]` okuyup AV
veriyordu — ikisi de koşula bağlandı.

**Gerileme olarak kalan:** `COUNT(*)` v3'te tam tarama (15,5 MB / 62 ms ≈
250 MB/s); v2'de tablo başına sayaçtan O(1). v3.1'de tablo başına canlı satır
sayacı, mantıksal (küçük) WAL çerçevesi ve toplu dosya uzatma (ölçülen:
sayfa başına 45–50 µs tek tek uzatma) hedefleniyor.

### Sprint 3.8-3.10: Linux kapısının bulduğu üç taşınabilirlik kusuru

Bu kapılar yalnız "testleri koşturmak" değildi; Linux'ta (WSL/DrvFs) hiç
görünmeyen üç **gerçek** kusur çıktı. Üçü de ölçümle kök nedene indirildi ve
düzeltildi — Windows davranışı değişmedi (kapılar aynı sayılarda yeşil):

1. **`cthreads` eksikliği (kapıların çoğu daha ilk satırda ölüyordu).**
   FPC/Unix'te `TEvent`/`TThread` kullanan bir programın ilk `uses` birimi
   `cthreads` olmazsa `TEvent.Create` → `ESyncObjectException: Failed to
   create OS basic event with name ""` atıyor. `backendchk`, `migchk`,
   `v3sqlchk`, `pagechk`, `storechk`, `heapchk`, `idxchk`, `crashtest`
   programlarına `{$IFDEF UNIX}cthreads,{$ENDIF}` ilk sıraya eklendi
   (`sqltest`'te zaten vardı). Bu bir test hilesi değil, FPC'nin Unix
   sözleşmesidir: `vdbapi.lpr` de aynı satırı taşır.

2. **Unix'te `TFileStream` = `flock`: canlı dosyayı ikinci kez açmak
   `EAGAIN` veriyordu.** Ölçülen: `VACUUM` (ve `sqltest` T15/T19) Linux'ta
   `EFOpenError: Unable to open file "...odf": Try again` ile düşüyordu.
   `locktest`/`locktest2` repro'ları kesin ayırımı verdi: FPC'nin Unix
   `TFileStream`'i paylaşım moduna göre **flock** uygular; motor dosyayı
   `LOCK_EX` ile tuttuğu için **salt-okunur boy ölçümü bile** ikinci açılışta
   çakışır. Windows'ta paylaşımlı okuma serbest olduğundan kusur görünmez.
   Düzeltme: yeni `VDbSync.VDbFileBytes` — boy ölçümü **açmaz**, `stat()`
   kullanır (Unix) / paylaşımlı okur (Windows). `VACUUM`'un iki boy ölçümü ve
   WAL'in "dosya var mı / yeterince büyük mü" keşfi buna geçti. Ayrıca
   `VDbPageStore.Open` artık ham işletim sistemi hatası yerine **açık kilit
   hatası** verir (`VDbIsSharingViolation` Unix'te FPC'nin `Try again`
   metnini de tanır — glibc metni `Resource temporarily unavailable`).
   Regresyon kapısı: `v3sqlchk` `TestDoubleOpen` **6/6** (ikinci açılış
   reddedilir + açık mesaj, ilk motor çalışmaya devam eder, `VERIFY` geçer,
   kapanıştan sonra açılış serbest).

3. **`crashtest` kill -9 alt süreci ölüyordu (test "geçersiz" sayılıyordu).**
   Ölçülen: Linux'ta `kill -9: alt surec hic commit edemedi (test
   gecersiz)`. Alt sürecin tanı dosyası kök nedeni tek satırda verdi:
   `EXC EFCreateError: Unable to create file "...kill9.marker": Try again`.
   Yani **işaret dosyası** (`TStringList.SaveToFile`/`LoadFromFile`, yine
   flock) yüzünden ölüyordu — motor verisiyle ilgisi yoktu. Düzeltme: işaret
   dosyası motor verisi değildir, kilit gerekmez; Unix'te ham
   `fpOpen/fpRead/fpWrite` (`MarkerRead`/`MarkerWrite`) kullanılır, alt
   süreç ayrıca tanı dosyası bırakır (sessiz ölüm bir daha "gizem" olmaz).
   Sonuç Linux'ta da **11/11**, ölçülen: `commit edilmis 2025 satirin
   TAMAMI yerinde`.

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
  Sıkıştırma (varint) v3.2'ye bırakıldı.

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
7. Sıralı indeks veri yapısı (`btreechk`, 12. kapı) bağımsız oracle'a karşı ve
   skiplist paritesiyle doğrulanır; yapı değişmezleri her koşuda denetlenir.

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
