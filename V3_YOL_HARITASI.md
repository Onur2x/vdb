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
> ve PITR" bölümü.
>
> **Güncelleme 2 (2026-10-26):** `SAVEPOINT`, replikasyon, zone map ve çok
> oturumlu yazma (MVCC, v3.4) de kapandı; ayrıca açılışta ölçülen 20 s'lik
> değişim günlüğü darboğazı giderildi (v3.5: 39–46 ms). Yol haritasında açık
> madde kalmadı; bilinçli sınırlar "Sıradaki sürüme ertelenen" bölümünde.
>
> **Güncelleme 3 (2026-10-26):** Karar değişti — ertelenen maddeler artık
> **bu hattın kapsamı**. Hat alpha sayılıyor, hepsi bitince ürün
> **v1.0.0** olarak yayınlanacak. `main` de bu hatla birleştirildi
> (aynı commit). Bkz. aşağıdaki "Sürüm çizgisi kararı".

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
| Çok yazarlı | **Süreç içi** çok oturum yazabilir (v3.4: READ COMMITTED, ilk commit kazanır, çakışan commit `yazma cakismasi` ile durur). **Süreçler arası** hâlâ tek yazıcı: dosya kilidi ikinci süreci reddeder. |

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

### v3.3 — sayfa düzeyi zone map (2026-10-26)

v3'te zone map yoktu (v2'ninki ekleme sıralı veri dosyasına bağlıydı). Artık
bucket = **heap sayfa numarası**: her (sayfa, kolon) için min/max tutulur ve
uygun olmayan sayfa **disk okumasından önce** atlanır
(`ScanAllRawPaged` / `ScanRawIterAllPaged`).

- Yalnızca `AND` ile bağlı INT/FLOAT karşılaştırmaları ve `IN`/`BETWEEN`.
- NULL satır min/max'a girmez; hepsi NULL olan sayfa elenebilir.
- Geçerlilik **içerik damgası** ile: damga her motor örneğinde benzersiz
  taban alır ve yalnızca **veri değiştiren commit**'te ilerler (salt-okunur
  commit haritayı boşa çıkarmaz).
- **Commit edilmemiş değişiklik varken harita ne kullanılır ne inşa edilir**
  (aksi halde aynı işlemde yazılan satır kaybolurdu).
- v2 değişmedi: `ScanRawIterAllPaged` `False` döner, tam taramaya düşülür.

| Ölçüm (`zmbench`, 100k satır × 3 kolon) | Değer |
|---|---|
| seçici sorgu, ilk koşu (harita inşası dahil) | 72,2 ms |
| seçici sorgu, harita hazır (medyan) | **0,17 ms** (1525/1527 sayfa atlandı) |
| orta seçicilik (`a > 150000`, 50k satır) | 73,7 → 73,1 ms (kazanç yok) |
| filtresiz (100k satır) | 144,9 ms |

Kazanç yalnızca **seçici** yüklemlerde ve harita kurulduktan sonra; ilk sorgu
tam tarama bedelini öder. Geniş yüklemlerde satır üretimi baskın olduğu için
ölçülebilir kazanç yoktur.

`SHOW STATS` v3'e `zone_pruned_pages` eklendi (metrik satırı 12 → 13).
Kapı: `v3sqlchk` **196/0** (`TestPageZoneMap` 10 kontrol; kirli işlem ve NULL
dahil), diğer 13 kapı yeşil, sqltest v3 2758/0/33, v2 3196/0/0.

### v3.4 — çok oturumlu yazma / MVCC (2026-10-26)

Aynı backend üzerinde **birden çok oturum aynı anda yazabilir**. Okuma READ
COMMITTED; her oturum kendi `TWriteSet`'inde yazar (Map/Order/Before/TagDelta/
Savepoints). Commit'te, **uygulamadan önce**, yazılan anahtarların before-image'ı
güncel motor değeriyle karşılaştırılır: **ilk commit kazanır**, kaybeden
`yazma cakismasi: … (islem geri alindi)` ile durur ve yarım uygulama olmaz.

- GLOBAL duruma dokunan işlemler (`MarkSchema`, `SAVEPOINT`/`ROLLBACK TO`/
  `RELEASE`, `DEFERRABLE` ertelemesi ve bekleyen denetim) çoklu yazmada
  `RequireSoleTxn`/`SoleWriter` ile açık `ecLockConflict` verir.
- Kilit: `FEngCs` motoru ve `FSets`'i serileştirir; işlem
  boyunca tutulmaz. Dosya düzeyi kilit değişmedi. (v3.9: `FEngCs` artık
  `TVdbGate` — sahip/derinlik izler, yeniden giriş varsayıma dayanmaz.)
- Sınır: v3.15'e kadar snapshot isolation ve süreçler arası çok yazarlılık
  yoktu; ikisi de v3.15/v3.16'da yapıldı (bkz. §v3.15, §v3.16).

| Ölçüm (`benchcmp`, 200k × 3 kolon, 3 koşu medyanı) | Değer |
|---|---|
| toplu INSERT, before-image kapalı (A/B) | 6,532 µs/satır |
| toplu INSERT, before-image açık | **7,466 µs/satır** (+%14,3) |
| autocommit INSERT | 1,024 ms |
| açılış | 39,0 ms |

Kapı: `v3sqlchk` **228/0** (`TestMultiSession` 32 kontrol), `sqltest` v3
**2759/0/33**, v2 **3196/0/0**, 14 kapı yeşil.

### v3.5 — açılış darboğazı: 20 s → 39 ms (2026-10-26)

200k satır + 57 MB günlük (600k kayıt) ile açılış **20.043 ms** ölçüldü:
`ScanTail` tüm geçmişi, `LastState` ve `ListBases` her kaydı okuyup CRC'liyordu.
Düzeltme: segment kuyruğu `LogTailState` ile **O(1)** (CRC doğrulamalı; bozuk/
yarım kuyrukta tam tarama), `ListBases` segmenti tek okumada bellek içi tarayıp
yükleri atlıyor (yalnız BASE CRC'li).

| Yer | Önce | Sonra |
|---|---|---|
| `ListBases` | 5.967 ms | 21 ms |
| `LastState` | 7.080 ms | 0 ms |
| toplam açılış | 20.043 ms | **39–46 ms** |

Davranış korunur: bozuk kuyruk tam taramaya düşer, CRC'siz BASE kabul edilmez.
Kapı: günlük 28/0, PITR 21/0, replikasyon 37/0, çökme kurtarma 11/0.

### v3.6 — toplu INSERT: 7,47 → 6,04 µs/satır (2026-10-26)

MVCC çekirdeğinin (v3.4) bedeli ölçüldü: her yazımda before-image için
**motor okuması** ve **üç ayrı sözlüğe** (Map + Order + Before) satır başına
kayıt. Oysa tek yazarlı toplu INSERT'te çakışma **imkânsızdır**.

Ölçülen katman profili (200k satır, 512 sayfa havuz, aynı makine):

| Katman | Önce | Sonra |
|---|---|---|
| backend `Put` (hazırlama) | 2,366 µs | **1,344 µs** |
| `tb.Insert` tam satır yolu | 4,896 µs | **3,748 µs** |
| benchcmp toplu INSERT (commit dâhil) | 7,466 µs | **6,038 µs** |
| v2 (aynı koşu) | 3,877 µs | 3,853 µs |

Fark (v3 − v2) 3,59 → **2,19 µs**.

Düzeltmeler:
1. **Seyrek before-image.** Yazma kümesine `NeedBefore` bayrağı eklendi. Bayrak
   ancak *biz açıkken başka bir oturum commit ederse* (FEngCs altında) True olur;
   o ana kadar satır başına ne motor okuması ne `Before` sözlüğü vardır.
2. **Yabancı anahtar defteri (`FAlien`).** Hızlı yolda yazılan anahtar için
   çakışma, "biz başladıktan sonra başka oturum bu anahtara dokundu mu"
   sorusuna indirgenir; defter bunu commit gen'iyle tutar. Anlam **birebir aynı**:
   commit sonrası yazım (yeni değeri görmüş yazım) hâlâ çakışma sayılmaz —
   `v3sqlchk` 4b senaryosu bunu kilitler.
3. **`OwnSet` tekrarı kaldırıldı.** `Put`, `Get`, `Delete`, `Exists` satır başına
   3–4 kez kilit + oturum sözlüğü arıyordu; artık bir kez.

Kalan fark nerede: hazırlama 3,70 µs (v2: ~3,12) ve commit 2,34 µs (v2: ~0,76).
Commit'in 0,61 µs'si **değişim günlüğü** (PITR/replikasyon özelliğinin bedeli);
kalanı sayfa motoru uygulaması + checkpoint (dayanıklılık).

Kapılar: 14/14 yeşil, `v3sqlchk` **237/0** (9 yeni çok oturum kontrolü),
`sqltest` v3 2759/0/33, v2 3196/0/0.

### v3.7 — SQLite sözdizimi paritesi (2026-10-26)

Eski bir SQLite uygulamasını değiştirmeden çalıştırabilmek için eksik yazımlar
kapatıldı. Hepsi **ayrıştırıcı + yürütücü** katmanında; dosya biçimi değişmedi.

| Yazım | Önce | Şimdi |
|---|---|---|
| `BEGIN TRANSACTION` / `BEGIN WORK` | `anlasilamayan ek: TRANSACTION` | kabul; davranış değişmez |
| `BEGIN IMMEDIATE/DEFERRED/EXCLUSIVE` | sözdizimi hatası | kabul (kilit düzeyi yok sayılır; motor tek yazıcı) |
| `CREATE INDEX IF NOT EXISTS ix ...` | `"ON" bekleniyor` | aynı adlı indeks varsa **sessiz** başarı, tanım korunur |
| `INSERT OR IGNORE` | `"INTO" bekleniyor` | çakışan satır atlanır (= `ON CONFLICT DO NOTHING`) |
| `INSERT OR REPLACE` | `"INTO" bekleniyor` | PK dışı tüm kolonlar yeni satırdan yazılır; verilmeyen kolon DEFAULT/NULL |
| `INSERT OR ABORT/FAIL/ROLLBACK` | sözdizimi hatası | kabul; çakışmada hata (varsayılan davranış) |
| `CREATE TEMP/TEMPORARY TABLE` | sözdizimi hatası | kabul; tablo **kalıcıdır** (§ sınırlar) |
| `CREATE TABLE x AS SELECT ...` | `"(" bekleniyor` | kolonlar kaynak SELECT'ten türetilir, satırlar kopyalanır |
| `UPDATE ... SET ... FROM ...` | `anlasilamayan ek: FROM` | alt sorgu veya tablo kaynağı; JOIN reddedilir |
| `WITH x AS (INSERT/UPDATE/DELETE ...)` | `SELECT bekleniyor` | gövde çalıştırılır; `RETURNING` satırları CTE olur |
| `CREATE TRIGGER ... BEGIN ... END` (`AS`'siz) | `"AS" bekleniyor` | `AS` isteğe bağlı |

Yan düzeltme: `FindColIdx` nitelikli referansı artık **önce tam `alias.kolon`
eşleşmesiyle** arıyor. Önceki tek geçişli arama, dizide niteliksiz ad önce
geldiğinde `x.id` referansını `p.id`'ye bağlıyordu (`UPDATE ... FROM`'da
`x.id = p.id` → `p.id = p.id` olur, **tüm satırlar** eşleşirdi).

Bilinçli sınırlar (sessiz yanlış sonuç yok, açık hata/sınır):
`TEMP` tablo oturum kapanınca **silinmez**; `UPDATE ... FROM` tek kaynak kabul
eder (JOIN reddedilir); `INSERT OR REPLACE ... ON CONFLICT` birlikte reddedilir.

Kapılar: 14/14 yeşil, `v3sqlchk` **237/0**, `sqltest` v3 **2784/0/33**
(önce 2759), v2 **3221/0/0** (önce 3196) — yeni `T156_SqliteParity` 25 kontrol,
iki backend'de de koşar.

### v3.8 — değişim günlüğü budama (2026-10-26)

Ürün kararı: **"30 gün VEYA 2 taban imajı — hangisi daha uzun geçmiş
tutuyorsa"**, tetikleme **checkpoint sonrası otomatik** (ayrı bayrakla,
varsayılan kapalı). Bugüne kadar günlük sınırsız büyüyordu (~100 B/satır).

Kesim noktası iki sınırın **daha eskisidir** (yani daha çok geçmiş korunur):

| Sınır | Anlamı |
|---|---|
| zaman | Grup zamanı `now − KeepDays`'ten eskiyse budanabilir (`KeepDays=0` → kural kapalı) |
| taban | En yeni `KeepBases` taban imajının **en eskisinden** öncesi budanabilir |

Zorunlu alt sınır her zaman **en yeni taban imajının sırasıdır**: ondan
sonraki gruplar canlı durum için gereklidir, silinemez.

Uygulama kuralları (hepsi ölçülmüş, varsayım değil):
1. Silme yalnız **segment düzeyinde önek**: baştan kesintisiz tam segmentler.
2. **Aktif (en son) segment** her zaman korunur (yazıcı ona ekliyor olabilir).
3. **Taban işareti yoksa hiçbir şey silinmez** — kapsama kanıtlanamaz.
4. Okunamayan/bozuk segmentte budama **durur** (o noktadan ileriye dokunulmaz).
5. Silinen segmentlerdeki `BASE` kayıtlarının **imaj dosyaları da** silinir.
6. Otomatik kanca (`LogPruneEnabled=True`) yalnız **süresi dolmuş önek
   varsa** çalışır ve önce o öneği kapsayan **yeni taban imajı** yazar; yoksa
   her checkpoint'te tam dosya kopyası üretmez.

Arayüz (`IVdbBackend`, v2'de açık hata): `LogPruneEnabled` (varsayılan
False), `LogPruneKeepDays` (30), `LogPruneKeepBases` (2),
`LastLogPruneError`, elle `LogPrune(out Segment, TabanDosya, Bayt, Hata)`.
Açık yazma işlemi varken budama reddedilir.

Kapılar: `logchk` **43/0** (önce 28; yeni `TestPrune` 15 kontrol: kesim
noktası, taban koruma, aktif segment, tabansız güvenlik, idempotens, budama
sonrası replay), `backendchk` **115/0** (önce 108; varsayılanlar, elle
budama, açık işlem reddi, checkpoint kancası, v2 stub).

Bilinçli sınırlar: segment içi yeniden yazma yok (tek bir dev segment
budanamaz); budama sonrası kalan en eski tabandan önceki bir ana `AS OF` /
`RECOVER TO` hedefi **açık hatayla** reddedilir; her budama turu bir tam
dosya kopyası (taban imajı) maliyeti taşır.

### v3.9 — motor notları: negatif budama, kilit defteri, tarama hızı (2026-10-26)

Yol haritasında kalan üç motor notu kapatıldı. Üçü de **davranış aynı,
ölçüm/kanıt farklı** türündendi; hiçbiri veri biçimini değiştirmedi.

**1) Bölüm eleme (partition pruning) negatif sabitleri de kapsıyor.**
AST'de `-5` düz literal değil, `TSqlUnaryOpNode(suoNeg)` düğümüdür. Eski
`PartTargetsOf` yalnız `TSqlLiteralNode` kabul ettiği için `k = -5` ve
`k IN (-1,-2)` hiç daraltılmıyordu (sonuç doğru, tarama tüm bölümler).
Artık sabit çözümü tek bir yardımcıdan (`VdbInConstText`) geçiyor — indeks
daraltması da aynı yardımcıyı kullanır, böylece iki yol ayrışamaz.
Ek güvenlik: bölüm numarası hesaplanamazsa (`PartValueOf < 0`) koşul
**katkı vermez**; `-1`'i hedef kümeye koymak hiçbir bölümü taramamak
(satır kaybı) olurdu.

**2) `FEngCs` yeniden girişliliği artık varsayım değil.**
Kilit düz `TCriticalSection`'dı ve iç içe çağrılar (ScanAll → ScanCb →
OwnSet, ApplyBatch → BatchMap) yalnız "kritik bölüm yeniden girişlidir"
varsayımına dayanıyordu. Yeni `TVdbGate`: her iş parçacığı **kendi tuttuğu
kilitlerin yığınını** (`threadvar`) tutar; aynı iş parçacığından giriş
kritik bölüme hiç girmez, başka iş parçacığından giriş normal karşılıklı
dışlamadır. Paylaşılan alanlar (`FDepth`, `FOwner`) kritik bölüm dışında
**hiç okunmaz** — böylece zayıf bellek sıralı platformlarda eski sahip
değerini görüp yanlışlıkla "yeniden giriş" sayma riski de yoktur. `Leave`
sahipsiz çıkışta açık hata verir; iç içe kilit yığını dolarsa yine açık
hata (sessiz kilitlenme yok). `DebugLockDepth` / `DebugLockMaxDepth` ile
test edilebilir hale geldi.

**3) Tarama yolunda satır başına 3 kilit alma kaldırıldı.**
`ScanCb` her satırda `BatchIsMine` + `BatchMap` çağırıyordu; ikisi de
`OwnSet` üzerinden kilit + oturum sözlüğü araması yapıyordu. Artık yazma
kümesi tarama başında **bir kez** çözülür (`FScanSet`), satır başına tek
sözlük araması kalır — kilit hiç alınmaz.

Aynı turda bulunan gerçek eşzamanlılık hatası düzeltildi: `ScanAllAt` ve
PITR taraması **paylaşılan** `FScan*` tamponlarını kilit altında
kullanmıyordu; aynı backend'de eşzamanlı `ScanAll` + `ScanAllAt` (veya iki
`ScanAllAt`) birbirinin sonucunu bozabiliyordu. Tampon bölgesi artık
`FEngCs` altında (geçici motorun kurulum/kapanışı dışarıda).

Ölçüm (`tmp64/scanbench`, 200k satır + açık yazma kümesi, QPC, 3 koşu
medyanı): **45,00 ms → 32,00 ms** (son üç koşu 31–32 ms; önce/sonra aynı
makine, aynı sonda).

Testler: `sqltest` v3 **2801/0/33** (önce 2784) ve v2 **3238/0/0** (önce
3221) — 17 yeni kontrol: HASH'te `k = -3`, yansıtılmış `-3 = k`,
`k IN (-5,-1)`, karışık negatif liste, `EXPLAIN` hedef bölüm sayıları
(1/4, 2/4), RANGE'te negatif değer (1/3). `lockchk` **30/0** (önce 17):
her genel işlemden sonra derinlik 0, iç içe girişin gerçekten kullanıldığı
(`MaxDepth=2`), `ScanAllAt` gerçek taban+WAL yolu, 3 iş parçacığı aynı
backend'de karışık okuma/yazma, `LogPrune` sonrası derinlik.
14/14 kapı yeşil; `lockchk` 64-bit derlemede de **30/0**.

### v3.10 — toplu INSERT: 6,63 → 6,12 µs/satır (2026-10-26)

§9'daki tek ölçülmüş **hız gerilemesi** kapatıldı: v3 toplu INSERT v2'nin
~1,6 katı yavaştı. Bu turda **dosya biçimi değişmedi** — düzeltmeler yazma
yolundaki gereksiz kopya ve sözlük işlemlerini kaldırır; üretilen baytlar
birebir aynıdır.

Kalan fark önce katman katman ölçüldü (200k satır, `tmp64/insprof`,
`tmp64/cmtprof`, 3 koşu medyanı):

| Katman | Ölçüm |
|---|---|
| Sayfa motoru `Insert` döngüsü | 0,484 µs/satır |
| Sayfa motoru `Commit` | 0,545 µs/satır |
| `Checkpoint` | 0,072 µs/satır |
| backend `Put` (hazırlama) | 1,520 µs/satır |
| `tb.Insert` tam satır yolu | 4,277 µs/satır |

Yani fark sayfa motorunda değil, **backend sarmalayıcısında** birikiyordu.
Üç düzeltme:

1. **Değişim günlüğü yerinde kodlanıyor.** `EndGroup` her kayıt için
   `TakePayload` (1 ayırma + 2 kopya) ve `BuildRec` (1 ayırma + kopya)
   çağırıp sonucu üçüncü kez grup tamponuna kopyalıyordu: satır başına
   2 ayırma + 3 kopya. Yeni `PutChangeRecAt` kaydı doğrudan grup tamponuna
   yazar; alan sırası, uzunluklar ve CRC **birebir aynı** kalır. Grup boyutu
   da artık `FGroupBytes`'ten gelir (eskiden grup bir kez daha toplanıyordu).
2. **Etiket farkı ara sözlükten geçmiyor.** `ApplyBatch` sırasında
   `BatchTagDelta`'ya yazılıp hemen ardından `MergeTagDeltas` ile
   `FTagCounts`'a aktarılıyordu — zaten `FEngCs` altındayız, ara durak
   gereksizdi. `FInApply` bayrağıyla fark doğrudan sayaca yazılır; parti
   dışı yollar (autocommit `Put`) davranışını korur.
3. **`Put`'ta tek sözlük araması.** `ContainsKey` + `AddOrSetValue` anahtar
   başına iki tam arama yapıyordu (ölçülen: 0,719 vs 0,595 µs). "Yeni
   anahtar mı" sorusu artık `Count` değişiminden bedava yanıtlanır.

Ölçüm (`tmp64/insprof2`, 200k satır × 3 kolon, commit dâhil, QPC, 3 koşu
medyanı):

| | Önce | Sonra |
|---|---|---|
| hazırlama | 4,269 µs | **4,046 µs** |
| commit | 2,383 µs | **2,076 µs** |
| **TOPLAM** | **6,632 µs** | **6,115 µs** (−%7,8) |
| günlüğün commit içindeki payı | 0,51 µs | **0,21 µs** |

v2 ile aynı süreçte kıyas (`tmp64/inscmp`, 3 koşu medyanı): v3 **6,093** /
v2 **3,822** = **1,60x**. Yani v3 hâlâ v2'den yavaş; kalan farkın büyük
kısmı satır başına **dört kez** çözülen oturum kümesi (`OwnSet`: kilit +
sözlük araması; `InBatch`/`Exists`/`Get`/`Put`) ve v3'ün dayanıklılık
bedelidir (WAL commit + değişim günlüğü). Oturum kümesini kilitsiz
önbelleğe almak ölçülebilir kazanç verirdi, ancak yarış koşulu riski
taşıdığı için **veri güvenliği önceliğine aykırı** bulunup yapılmadı.

Doğrulama: 14/14 kapı yeşil (`logchk` 43/0, `pitrchk` 21/0, `replchk`
37/0 — günlük baytlarının birebir aynı kaldığını bunlar kilitler),
`sqltest` v3 **2801/0/33**, v2 **3238/0/0**, `lockchk` 64-bit **30/0**.

### v3.11 — satır gövdesi varint: dosya −%16, INSERT −%6 (2026-10-26)

Ertelenen listenin ilk maddesi (satır gövdesi varint). Bugüne kadar her
satırda **kolon başına sabit 4 baytlık** uzunluk alanı, pk ve kolon sayısı
için de 2 baytlık alan vardı; 5 kolonlu bir satırda yalnızca uzunluk
alanları 22 bayt tutuyordu. Yeni gövde:

```
v1: [u16 tableId][u16 pkLen][pk][u16 colCount]
    + her kolon: [u8 ctype][i32 vlen][payload]        (vlen = -1 => NULL)
v2: [u16 $FFFF][u16 tableId][varint pkLen][pk][varint colCount]
    + her kolon: [u8 ctype][varint lenCode][payload]  (0 => NULL, aksi
                                                        halde len+1)
```

**Ayırt edici neden `$FFFF` ve neden güvenli:** satırın ilk iki baytı
`$FFFF` ise gövde v2'dir. `$FFFF` bu motorda **hiçbir zaman** geçerli bir
tablo kimliği olamaz (`CreateTable` `FNextId >= $FFFF` reddeder); bu turda
aynı sınır `CreateMaterializedView` için de eklendi (eskiden `Inc(FNextId)`
sonrası atama yüzünden `$FFFF`'e ulaşabiliyordu) ve şema yüklemesi böyle
bir kaydı **açık hatayla** reddediyor. Yani eski bir satırın yanlışlıkla
v2 sanılması mümkün değil — "sessiz yanlış sonuç" yolu kapalı.

**Dosya sürümü 3 → 4.** Bu, ilk planda düşünülmeyen ama zorunlu olan
karar: satır biçimi değiştiği hâlde başlık 3 kalsaydı, **eski bir ikili**
(yeni motorun yazdığı dosyayı) açıp v2 gövdeyi v1 sanarak ya satırları
düşürür ya da yanlış değer üretirdi. Sürüm 4 bu yolu kapatır:
- sürüm 3 dosyalar **açılır**; aynı dosyada v1 ve v2 satırlar bir arada
  okunur (eski satır güncellenince v2 yazılır), ilk **yazılabilir** açılışta
  başlık 4'e yükseltilir (`SaveMeta`);
- salt-okunur açılış yazmadığı için yükseltme yapmaz;
- eski ikili sürüm 4 dosyayı `desteklenmeyen surum: 4` hatasıyla reddeder
  (ölçüldü: v3.10 ikilisi `Check` çağrısında tam bu hatayı verdi);
- `RESTORE` ve `VERIFY` yolları da sürüm 3'ü kabul eder.

Ölçüm (QPC, 3 koşu medyanı, `tmp64/insprof2`, 200k satır × 3 kolon,
commit dâhil):

| | v3.10 | v3.11 |
|---|---|---|
| hazırlama | 4,003 µs | **3,933 µs** |
| commit | 2,128 µs | **1,863 µs** |
| **TOPLAM (log=on)** | **6,157 µs** | **5,771 µs** (−%6,3) |
| TOPLAM (log=off) | 5,673 µs | **5,388 µs** |
| `.odb` boyu | 11.912 KB | **10.040 KB** (−%15,7) |

Tarama hızı değişmedi (`tmp64/scanbench`, 200k satır, 3 koşu medyanı:
32,0 ms → 30–33 ms bandı; fark gürültü içinde). Satır başına kazanç
kolon sayısıyla artar; sabit genişlikli 3 kolonlu satırda 39 → **30 bayt**
(−%23), 7 kolonlu karışık tabloda fiilen 69.632 → 61.440 bayt (−%11,8,
`tmp64/rowfmt`, 500 satır).

Geriye dönük okuma **gerçek bir eski dosyayla** kanıtlandı: `caeb619`
(v3.10) sürümünden ayrı bir worktree'de derlenen ikili 500 satırlık DB
yazdı, yeni ikili aynı dosyada `COUNT=500` ve tüm değerlerin FNV özetinde
**birebir** aynı sonucu verdi. Sonra 250 satır `UPDATE` edilip dosya
karışık biçime (v1 + v2) getirildi: dokunulmayan 250 satırın özeti yine
birebir aynı kaldı.

Testler: `sqltest` v3 **2822/0/33** (önce 2801), v2 **3256/0/0** (önce
3238) — yeni `T157_SatirGovdesi`: elle kurulmuş v1 ve v2 gövdenin aynı
`tid/pk/kolon` değerlerini vermesi, `$FFFF` işaretinin ham taramada
görülmesi, sabit genişlikli satırın **tam 30 bayt** olması, NULL / büyük
negatif INT / 127 bayttan uzun metin (2 baytlık varint) yolları.
14/14 kapı yeşil; `sqltest` ve `lockchk` 64-bit derlemede de yeşil
(2812/0/33 ve 30/0).

### v3.12 — ON eşitlik + ek koşul artık hash yolunda (2026-10-26)

**Bulgu.** İndekssiz eşitlik join'i bu motorda zaten hash join'dir
(`joinbench`, 10k × 10k, hiç eşleşmeyen join 0 satır sonuç: **42 ms** —
nested loop 100M çift olsaydı ~6 s). Ama hash yolu yalnız ON ifadesi
**tek bir `kolon = kolon`** olduğunda açılıyordu. `ON a.k=b.k AND a.x>5`
yazıldığında koşulun kökü `AND` olduğu için hash devre dışı kalıyor ve
sorgu 10k × 10k = 100M çift üzerinde ifade yorumluyordu.

**Ölçüm (izole, `onekchk`, 10k × 10k, 1M aday çift):**

| | eski (cde813d) | yeni |
|---|---|---|
| `ON a.k=b.k AND a.k>1000000` | **300 s'de bitmedi** (araç zaman aşımı) | **5.926 ms** |

**Düzeltme.** `OnEqNode` yardımcısı `AND` ağacının içindeki ilk
`kolon = kolon` düğümünü bulur; bu eşitlik hash anahtarı olur. Ek koşullar
`JoinOnOk` içinde aynen değerlendirilir (nihai eleyici), bu yüzden sonuç
kümesi değişmez. Ek koşul varsa **indeks/PK hızlı yolu kapatılır**: o yol
`JoinOnOk` çağırmadığı için ek koşulu atlardı (sessiz yanlış sonuç riski).

**Kalan maliyet.** 5,9 s, 1M aday çift için ek koşulun çift başına
değerlendirilmesidir; sonuç üretimi (1M satır × 6 kolon kopyası) ayrıca
~3,2 s. Bir sonraki kazanç ON/WHERE yüklemlerinin ilgili tarafa
**itilmesidir** (`a.k > 1000000` solda 0 satır bırakır → iş ~0). Bu,
ölçümle belirlenmiş ayrı bir maddedir; merge JOIN bu iki darboğazın
ikisini de çözmez (bkz. "Sürüm çizgisi kararı", madde 2).

Testler: `sqltest` v3 **2832/0/33**, v2 **3266/0/0**; yeni
`T158_OnEkKosulHash` (INNER / LEFT / FULL / PK / OR kökü / NULL ve
imkânsız ek koşul yolları). 14/14 kapı yeşil.

### v3.13 — PK satır gövdesinde tek kez: satır −%13…%29 (2026-10-26)

**Bulgu (ölçümle doğrulandı).** Satır içi PK tanımında (`id INTEGER
PRIMARY KEY`) PK değeri **iki kez** yazılıyordu: bir kez gövde başlığında
(`varint pkLen + pk baytları`), bir kez de PK kolonunun yükünde. `.idx`
anahtarı `VDbHashKey` olduğu için PK metni anahtardan geri türetilemez;
yani başlıktaki kopya gereksiz **değil** — gereksiz olan *ikinci* kopya.

Ölçüm (`tmp64/rowbytes`, 3000–5000 satır, 3 kolon):

| tablo | ort. satır | PK baytları | PK payı |
|---|---|---|---|
| küçük INT PK (1…5000) | 21,8 B | 3,8 B | %17,4 |
| büyük INT PK (×1.000.003) | 30,7 B | 9,9 B | %32,1 |
| TEXT PK (`SIP-100001`) | 36,0 B | 10,0 B | %27,8 |

**Yeni biçim (dosya sürümü 5).** `pkLen = 0` ise PK gövdede yoktur ve
hemen bir `varint v` gelir: `v = 0` → boş PK, `v ≥ 1` → `v-1`. kolonun
değeri. `pkLen > 0` eski davranıştır (satır içi). Ayırt edicilik
kanıtlandı: boş PK reddedilir ("PK bos olamaz") ve PK'siz tabloda
üretilmiş anahtar yazılır (ölçüldü: `pkLen = 2`), yani **eski dosyalarda
`pkLen = 0` hiç görülmez**. Bu yüzden yeni bir gövde işareti gerekmedi;
`$FFFE` bilinçli olarak kullanılmadı (CreateTable `>= $FFFF` reddettiği
için `$FFFE` geçerli bir **tablo kimliği** olabilir).

**Kayıpsızlık koşulu.** Kodlayıcı bu yolu yalnız PK metni, PK kolonunun
**kanonik** metniyle birebir aynıysa kullanır (INT → `IntToStr`, FLOAT →
`VDbFloatToStr`, BOOL → `BoolToStr`, metin/BLOB → değerin kendisi).
Tutmayan her durumda (ör. NOCASE ile küçültülmüş anahtar, PK olmayan
sentetik anahtar) PK eskisi gibi satır içi yazılır. Çözücü `VdbRowPkOf`
kolon tipini satırın **kendi** `ctype` baytından okur, sema gerekmez.

**Ölçüm — aynı veri, iki ikili (`tmp64/sizebench`, 50k + 50k satır,
kapanmış dosya):**

| veri kümesi | v3.12 `.odb` | v3.13 `.odb` | fark |
|---|---|---|---|
| geniş metin (`kayit-NNNNN`) | 5.406.720 B | 4.874.240 B | **−%9,9** |
| dar satır (`t='x'`) | 4.435.968 B | 3.866.624 B | **−%12,8** |

Satır düzeyinde kazanç daha büyük (PK baytları satırdan düşer, sayfa/
meta veri yükü düşmez): küçük INT PK 21,8 → **19,0 B** (−%12,8), büyük
INT PK 30,7 → **21,9 B** (−%28,7), TEXT PK 36,0 → **27,0 B** (−%25,0).
`.idx` değişmedi (1.089.063 → 1.088.347 B, gürültü).

**Geriye dönük okuma kanıtı (`oldtree` = `c02ac06` ikilisi + `mixedchk`).**
Eski ikiliyle (sürüm 4) yazılan dosya yenide açıldı: başlık **4 → 5**
yükseldi, 100 eski satır `inline=100` olarak aynen okundu, aynı dosyaya
yazılan 10 yeni satır `col=10` oldu (iki biçim yan yana), `UPDATE` ile
yeniden kodlanan satır PK'sını korudu, `VACUUM` satırları **ham kopyalar**
(yeniden kodlamaz: 99 inline + 11 yeni biçim korunur), yeniden açılışta
tüm PK'lar birebir. Eski ikili aynı dosyayı **`desteklenmeyen surum: 5`**
ile reddediyor (sessiz yanlış çözme yok). Salt-okunur açılış yükseltme
**yapmıyor** (sürüm 4 olarak kalır).

**Hücre başlığı sıkıştırma — GEREKÇELİ REDDEDİLDİ.** Kolon başına 1 bayt
`ctype` satırda duruyor (dar satırda 3 bayt ≈ %11–16). Bu bayt, satırın
kendi tipini taşıdığı için `ALTER COLUMN TYPE` sonrası eski satırların
doğru çözülmesini ve karışık şema okumasını sağlıyor (`DecodeRow`
sözleşmesi: "alanlar eski şemaya göre yazılmış olabilir"). Şemaya
güvenmek bu garantiyi bozar; 3 baytlık kazanç için veri kaybı riski
alınmaz (öncelik 1). Aynı gerekçeyle `colCount` varint'i de korundu
(`ALTER ADD COLUMN` sonrası eski satırlarda daha az kolon var).

Testler: `sqltest` v3 **2858/0/33**, v2 **3289/0/0**; yeni `T159_PkTekKez`
(INT/TEXT/unicode PK, PK ilk kolon değil, tablo kısıtı, `INSERT OR
REPLACE`, PK güncellemenin reddi, silme, `ALTER ADD COLUMN`, ikincil
indeks, `VACUUM`, yeniden açma, negatif/büyük Int64 pk, ham biçim
taraması). 14/14 kapı yeşil.

**Okuma yolu (bedeli ölçüldü).** PK artık kolondan çözüldüğü için satır
başına bir ek başlık adımı var. Aynı veri, iki ikili (`tmp64/scantime`,
50k+50k satır, QPC, 9 koşu medyanı):

| sorgu | v3.12 | v3.13 |
|---|---|---|
| `SUM(a)` (INT pk, en hafif yol) | 0,31 µs/satır | **0,40 µs/satır** |
| `SUM(LENGTH(t))` (metin kolonu) | 2,80 µs/satır | 2,83 µs/satır |
| `SUM(n)` (TEXT pk) | 0,34 µs/satır | 0,35 µs/satır |

İlk ölçümde `SUM(a)` 0,45 µs idi: KeyHash hızlı yolu INT pk metnini
`IntToStr` ile satır başına **ayırıyordu**. `VdbIntToDecBuf` (tahsissiz,
yığın tamponu, MinInt64 ve negatif doğru) ile 0,45 → **0,40 µs**. Kalan
fark gerçek iş: pk metni artık kolondan türetiliyor. Gerçek iş yüklerinde
(metin kolonu okunan tarama) fark ölçüm gürültüsünde.

### v3.14 — İfade değerlendirme: bytecode REDDEDİLDİ, tip-duyarlı tam sayı yolu

**Hipotez ve ölçüm.** Yol haritasındaki "ifade bytecode" maddesi, ağaç
yorumlayıcısının dağıtım (dispatch) maliyetinin baskın olduğu varsayımına
dayanıyordu. Motoru değiştirmeden önce tavan kazanç ölçüldü
(`tmp64/vmhead`, aynı 5 işlemlik zincir, 50k satır, QPC, 5 koşu):

| yol | µs/satır | fark |
|---|---|---|
| ağaç yorumlayıcı (bugünkü) | 0,80 | — |
| yığın bytecode (string değerler) | 1,07 | **+%34 (daha yavaş)** |
| tip-duyarlı Int64 yığını | 0,30 | **−%63** |

Sonuç: maliyet dağıtımda değil, **ara düğümlerde üretilen metinde**. String
tutan bir bytecode bu yüzden kazandırmıyor; kazancı veren şey sayısal
zinciri Int64'te yürütüp metne **yalnız sonda** dönmek.

İkinci şüphe de ölçümle çürütüldü: `FindColIdx` (doğrusal `SameText` araması)
sanıldığı kadar pahalı değil — `SELECT a+a+a+a` 3,35 µs/satır,
`SELECT 1+1+1+1` 3,28 µs/satır; dört kolon referansının payı ~0,02 µs/işlem.
Bu yüzden kolon indeksi önbelleği (bayat indeks riski taşıyan bir kestirme)
**yapılmadı**.

**Uygulanan.** `VDbExecutor.pas`:

- `BinaryOpCtype(bin, ColNames, ColTypes)`: ikili işlemin tip kararı
  `EvalExpr` içinden tek yere alındı (F1-17, 4.3, F-24, H-ek kuralları
  aynen). Amaç: hızlı yol ile ağaç yolu **aynı** tip kararını versin.
- `TryIntEval(...)`: yalnız **INT kolon** ve **tam sayı literali** ile
  kurulmuş `+`, `-`, `*` zincirlerini (ve tekli `-`) Int64'te yürütür; ara
  düğümde metin üretmez. Uygun olmayan her durumda `False` döner ve
  `EvalExpr` ağaç yolunu **aynen** kullanır.
- `EvalExpr` başında yalnız bu üç işlem için hızlı yol denenir.

**Birebir eşdeğerlik gerekçesi:** her düğümde tip kararı `BinaryOpCtype` ile
aynı (VCT_INT dışı hiçbir düğüm yola girmiyor); INT kolon değerleri ve
literaller ağaç yolunun da kullandığı `VDbParseInt` ile çözülüyor;
aritmetik Int64'te (taşma davranışı aynı); NULL/sayısal olmayan değer,
FLOAT/BOOL/metin, bölme/modulo, fonksiyon, CAST, CASE → ağaç yolu.

**Diferansiyel kanıt.** `tmp64/exprdiff`: 200 sözde-rastgele ifade
(1–3 derinlik, `+ - * / %`, tekli eksi, negatif ve büyük değerler,
`'007'`, `''`, NULL, sayısal olmayan metin) × 40 satır. Hızlı yol açık ve
kapalı iki ikilinin çıktısı `fc /b` ile karşılaştırıldı: **fark yok**.

**Ölçüm (`tmp64/exprbench`, 50k satır, QPC, 5 koşu medyanı):**

| sorgu | önce | sonra | fark |
|---|---|---|---|
| `SELECT a` (taban, ifade yok) | 1,88 | 1,84 | nötr |
| `SELECT a+1` | 2,74 | 2,33 | −%15 |
| `SELECT (a*2+1)*3-7` | 4,53 | **2,85** | **−%37** |
| `SELECT ((((a+1)*2)+3)*4)+5` | 5,14 | **3,16** | **−%39** |
| `SELECT a+a+a+a` | 3,35 | 2,33 | −%30 |
| `SELECT 1+1+1+1` | 3,28 | 2,44 | −%26 |
| `SELECT a+0+0+0` | 3,73 | 2,69 | −%28 |
| `COUNT(*) WHERE a*2+1 > 50000` | 3,86 | **3,30** | −%15 |
| `SELECT a WHERE a*2+1 > 50000` | 5,46 | 4,96 | −%9 |
| `COUNT(*) WHERE a > 25000` (ham yol) | 0,44 | 0,46 | nötr |
| `SELECT a,t WHERE a>100 AND a<40000` | 1,70 | 1,71 | nötr |
| `WHERE t LIKE 'kayit-4%'` | 1,02 | 1,06 | nötr |
| `CASE WHEN a>25000 ...` (dal hızlı yola girmiyor) | 4,84 | 4,96 | nötr |

İfade içermeyen sorgular değişmedi (beklenen); kazanç tam sayı zinciri olan
projeksiyon ve yüklemlerde.

Testler: `sqltest` v3 **2874/0/33**, v2 **3305/0/0**; yeni `T160_TamSayiZinciri`
(16 kontrol: öncelik, iç içe zincir, tekli/çift eksi, büyük sayı, NULL
zinciri, sayısal metin, `'007'`, Int64 taşması, FLOAT yolunun değişmediği,
ifadeli WHERE/SUM/CASE). 14/14 kapı yeşil.

### v3.15 — Snapshot isolation (okuma izolasyonu)

**Semantik.** Açık işlemi (`BeginBatch`) olan bir oturum, işlemi **başlattığı
andaki** görüntüyü okur; başka oturumların sonradan commit ettiği değişiklikler
o oturuma görünmez. Kendi yazdıkları her zaman önceliklidir. İşlem kapandıktan
sonra (ya da hiç işlem yokken) okuma yine güncel veriyi görür. Bu, v2
motorunun `FSnapshotSeq` davranışıyla aynıdır (`BatchIsMine and Seq > 0`).

**Neden bu tasarım.** v3 sayfa motoru yerinde (in-place) yazar; sayfa düzeyinde
sürüm zinciri kurmak (klasik MVCC) en pahalı yol olurdu. Bunun yerine
**bellek içi post-image penceresi** kullanıldı:

- `TWriteSet.StartGen` zaten vardı (v3.6, `BeginBatch` anındaki `FCommitGen`).
- Bir oturum commit ederken **başka bir yazma kümesi açıksa**, o commit'in
  dokunduğu anahtarların commit **sonrası** hali `FUndo` sözlüğüne
  `(Gen, Present, Value)` olarak yazılır; anahtarın ilk kez girmesinde ayrıca
  commit **öncesi** motor değeri `Base*` olarak saklanır.
- Okuyucu kendi `StartGen`'ine göre seçer: `Gen <= StartGen` olan **son**
  post; hiç yoksa `Base` (yani `StartGen` ilk değişiklikten önceyse, o
  değişiklikten önceki değer).
- `Base` yalnızca ilk post'ta bir kez okunur ve şu değişmez sayesinde her eski
  okuyucu için doğrudur: `StartGen`'i ilk post'un `Gen`'inden küçük olan her
  oturum, arada olan **tüm** commit'ler sırasında açıktı; dolayısıyla aradaki
  her değişikliğin de bir post'u vardır.
- `FUndo` yalnızca **hiç açık yazma kümesi kalmadığında** temizlenir; bellek
  penceresi = en uzun ortak açık işlem.
- Post-image'ler commit **öncesi** yerel bir listede toplanır, `FCommitGen`
  ancak uygulama başarılı olduktan sonra arttığı için **başarısız commit
  sahte geçmiş bırakmaz**.

**Değişen okuma yolları** (`VDbBackendV3.pas`): `Get`, `Exists`,
`EffectiveCount` (→ `Count`), `ScanAll`, `ScanRawIterAll` (+ akan geri
çağırım). Tarama yolunda, snapshot'ta motordan farklı olan anahtarlar motor
geri çağırımında atlanır ve doğru halleri tarama sonunda eklenir (kaplama
mantığının aynısı). `ScanRawIterAllPaged` açık parti varken zaten `False`
döndüğü için değişmedi. `CountTable` açık parti varken `-1` döndürüp tam
taramaya düşürdüğü için değişmedi.

**Hızlı yollar ve zone map.** SQL katmanının ham hızlı yolları
(`COUNT`/agg/group) `ScanRawIterAll` üzerinden gittiği için ikame edilen
satır baytlarını görür — doğru kalır, yalnız snapshot "kirli" iken yavaşlar.
v3'te zone map **devrede değil** (`FT.Kv` v2 motoruna bağlı); bu yüzden
budama ile snapshot etkileşimi v3 için söz konusu değil. Günlük budama
mantıksal günlük üzerinde çalışır, `FUndo` bellek içidir; etkileşim yok.

**Kanıt (yeni kapı `snapchk`, 21 kontrol — hepsi yeşil).**
Tek süreçte `VdbSessionIdFunc` ile üç oturum simüle edilir:
1. Oturum 1 açıkken oturum 2 günceller/siler/ekler → oturum 1 eski değeri,
   silinen satırı ve sabit `Count`'u görür; yeni satır görünmez; tarama eski
   değerleri verir (6 kontrol).
2. Oturum 1 kendi yazdığını görür (2 kontrol).
3. Commit sonrası güncel veri (4 kontrol).
4. Yazma çakışması hâlâ yakalanır (1 kontrol).
5. Parti dışı okuma güncel (1 kontrol).
6. **Post zinciri orta durumu:** oturum 1 (en eski) açıkken aynı anahtar iki
   kez commit edilir; arada başlayan oturum 3 orta değeri, oturum 1 ilk
   değeri, parti dışı okuma son değeri görür (3 kontrol).

Kırmızıdan yeşile: uygulama öncesi `snapchk` 12/18 (snapshot ile ilgili 6
kontrol kırmızı), sonrası 18/18; orta-durum eklenince 21/21.

**Eski test beklentisi düzeltildi.** `v3sqlchk` "v3.4 çok oturumlu yazma"
bölümü A commit ettikten sonra B'nin 4 satır görmesini bekliyordu (READ
COMMITTED). Snapshot isolation ile B kendi görüntüsünde kalır (3 satır) ve
A'nın satırını görmez; commit'ten sonra **başlayan** okuma 4 satır görür.
Test bu semantiğe göre güncellendi (`v3sqlchk` 238/0).

**Ölçüm (`tmp64/exprbench`, 50k satır, QPC 5 koşu medyanı, µs/satır).**
Snapshot temizken (tek yazma oturumu, başka commit yok) okuma yolu yalnız bir
bayrak denetimi ekler:

| sorgu | v3.14 | v3.15 |
|---|---|---|
| `SELECT a` | 1,84 | 1,84 |
| `SELECT a+1` | 2,33 | 2,34 |
| `SELECT (a*2+1)*3-7` | 2,85 | 2,89 |
| 5 işlemlik zincir | 3,16 | 3,15 |
| `COUNT(*) WHERE a*2+1 > 50000` | 3,30 | 3,17 |
| `COUNT(*) WHERE a > 25000` (ham) | 0,46 | 0,44 |
| `SELECT a,t WHERE aralık` | 1,70 | 1,69 |
| `WHERE t LIKE` | 1,02 | 1,02 |

Farklar gürültü sınırında (±%2); ölçülebilir bir yavaşlama yok.

**Testler:** `sqltest` v3 **2874/0/33**, v2 **3305/0/0**; `v3sqlchk`
**238/0**; **15/15 kapı yeşil** (14 eski + yeni `snapchk`).

**Bilinçli sınırlar (dokümante).**
- Yazma yolu değişmedi: **ilk commit kazanır** (`VerifyNoConflict` +
  before-image + `FAlien`). Bir yazma, bayat bir snapshot'a dayanıyorsa ve
  çakışan commit *ilk yazmadan önce* olmuşsa sessizce commit edilebilir
  (klasik lost-update); snapshot yalnız **okuma** görüntüsünü sabitler.
- `FUndo` belleği, en uzun açık işlem boyunca commit edilen satır sayısıyla
  büyür (klasik undo saklama maliyeti). Uzun işlem + yoğun yazma belleği
  şişirebilir; pencere tüm oturumlar kapanınca boşalır.
- Süreçler arası çok yazarlılık kapsam dışı (v3.16'da yapıldı — bkz. §v3.16).

### v3.16 — Süreçler arası çok yazarlılık (tek yazar sırası, veri kaybı yok)

**Hedef:** aynı `.odb` dosyasına birden çok süreç bağlanabilsin ve **sırayla**
yazabilsin; hiçbir commit sessizce kaybolmasın. Model SQLite'a benzer: çok
okuyucu / tek yazar.

**Kilit semantiği ölçülerek belirlendi** (`tmp64/lckprobe`, win32, aynı handle):

| Durum | Sonuç |
|---|---|
| Paylaşımlı bayt-aralığı kilidi tutarken yazma | **`EWriteError`** — paylaşımlı kilit yalnız okumadır, aynı handle bile yazamaz |
| Tam (exclusive) kilit tutarken **başka** handle'dan okuma | **`EReadError`** |

Bu iki gerçek tasarımı belirledi: kilit **oturum boyu değil, işlem (statement)
boyu** tutulur.

**Nasıl çalışır.**
- Açılış: yazan oturum kısa süreliğine **tam kilit** alır (WAL kurtarma, sürüm
  yükseltmesi, meta yazımı), işi bitince **bırakır**. Salt-okunur oturum
  paylaşımlı kilidi oturum boyu tutar (okuma görüntüsü sabit kalır).
- Her motor erişimi tek kapıdan (`FEngCs`) geçer; kapı derinliği 0→1 olduğunda
  **paylaşımlı kilit** alınır, 1→0 olduğunda bırakılır. Yazma girişinde
  paylaşımlı bırakılıp **tam kilit** alınır (`AcquireWrite`), çıkışta tersi
  (`ReleaseWrite`). İki süreç aynı anda yükseltmek isterse ikisi de önce
  paylaşımlıyı bıraktığı için **kilitlenme yok**.
- Önbellek tazeliği: her işlem girişinde `<db>.gen` **8 baytlık değişiklik
  sayacı** okunur. Sayaç değişmediyse hiçbir şey yapılmaz (~2 µs). Değiştiyse
  `DropCache` + meta yeniden yüklenir ve motor WAL görünümünü tazeler
  (`FWal.Close/Open`, varsa çerçeveleri uygula — sayfa imajları idempotent).
- Sayaç **meta sayfaya değil ayrı dosyaya** yazılır: meta sayfaya commit LSN'i
  yazmak taban dosyanın kendi kendine tutarlılığını bozuyordu (sayfalar hâlâ
  WAL'de olabilir; `pitr`/`AS OF SEQUENCE 0` bunu yakaladı).
- **Güvenlik ağı:** sayfa deposunun her yazma ilkeli (`WritePageAt`, `SaveMeta`,
  `GrowTo`, `TrimToLogical`) paylaşımlı kilit altında çağrılırsa kilidi
  **kendiliğinden tam kilide yükseltir** ve işlem sonunda bırakır. Unutulan bir
  yazma yolu `EWriteError` ya da veri kaybı üretmez (bu ağ olmadan `sqltest`
  T159'da `EWriteError` alınmıştı).
- WAL dosyası da paylaşıma açıldı (`fmShareDenyNone`); yazma yine veritabanı
  kilidiyle sıralanır.

**Ölçüm (`tmp64/lockcost`, win32, QPC, 3 koşu en iyisi).**

| İş | Ölçüm |
|---|---|
| `AcquireRead`/`ReleaseRead` (işlem kilidi) | **8,8 µs**/işlem (100.000 çift) |
| `AcquireWrite`/`ReleaseWrite` (+ sayaç) | **15,5 µs**/işlem (2.000 çift) |
| Otomatik commit `Put` (fsync dahil) | 25,5 µs/satır |
| Parti içinde `Put` (200k) | **2,215 µs/satır** (v3.15: 2,34 — gürültü sınırında, **regresyon yok**) |

Kilit maliyeti **işlem başına** ödenir: 50.000 satırlık tek bir `SELECT` bir
kez kilit alır, satır başına ek yük yoktur. Satır başına API döngüsünde
(`Get`/`Put`) işlem başına ~9–16 µs ek maliyet vardır; bu, çok süreçli
güvenliğin bilinçli bedelidir.

**Testler.** `sqltest` v3 **2874/0/33**, v2 **3305/0/0**; `v3sqlchk` **238/0**;
`lockchk` **29/0**; **16/16 kapı yeşil** (15 eski + yeni `prochk`).
`prochk` gerçek iki süreçle yarışır: tohum 5 satır + A 40 + B 40 = **85 satır**,
**eksik=0**; B, A'nın commit'ini görür (`toplam=85`).

**Bilinçli sınırlar (dokümante).**
- **Yazarlar sıralıdır**: bir yazma işlemi açıkken diğer süreçlerin yazma
  girişleri `ABusyMs` boyunca bekler, sonra
  `veritabani mesgul: yazar kilidi %d ms icinde alinamadi ...` hatası alır.
  Uzun bir işlem diğer süreçlerin **okuyucularını da** bekletir.
- `ABusyMs` varsayılanı **0**'dır (hemen hata); çok süreçli kullanımda açıkça
  büyütülmelidir (testte 20.000 ms).
- Adil kuyruk yoktur (aç yazar, sürekli yazan bir sürecin arkasında
  kalabilir).
- Canlı bir veritabanının **sürüm yükseltmesi** (dosya biçimi değişimi) çok
  süreçli kullanımda desteklenmez; yükseltme tek süreçle yapılmalıdır.
- Aynı süreç içindeki çok oturumlu davranış (v3.15 MVCC, ilk commit kazanır)
  değişmedi.


### Sürüm çizgisi kararı (2026-10-26): alpha hattı → **v1.0.0**

Kullanıcı kararı, önceki "v4'e ertele" planını geçersiz kılar:

- **Ayrı bir v4 sürüm çizgisi açılmayacak.** Aşağıdaki maddeler bu hattın
  kapsamıdır ve burada yapılır.
- Bu hat bugün **alpha**'dır: `v3.x` numaraları yayın sürümü değil, çalışma
  dilimi adıdır. Dışarıya sürüm vaadi verilmez.
- Tüm maddeler bitince ürün **v1.0.0** olarak etiketlenir ve ilk yayın
  odur. (Eski v2 kodu ağaçta yalnız **okunur legacy** olarak kalır; göç
  aracı ve `migchk` onu derlemek zorunda.)
- `main` artık `v3` ile **aynı commit**'tedir (fast-forward, 84 commit).
  İş `v3` dalında yürür ve her push'ta `main` de ilerletilir:
  `git push origin v3 v3:main` (tek komut, iki ref). İki dal arasında
  ayrı iş yapılmaz; ayrışma riski bu şekilde sıfırlanır.

Sıra (risk ve ölçülebilir kazanç sırasına göre; her madde ayrı dilim,
kendi kapıları ve ölçümüyle):

1. ~~**Bloom filtresi**~~ — **ÖLÇÜMLE REDDEDİLDİ (2026-10-26).** Gerekçe:
   bu motorda anahtar dizini (`.odb.idx`) açılışta **tamamen belleğe**
   yüklenip açık adresleme tablosuna dönüşüyor; olmayan anahtar araması
   hiç disk erişimi yapmıyor. Ölçüm (`tmp64/pointchk`, 200k satır, 50k
   sorgu): taban `SELECT 1` 3,574 µs, **olmayan** anahtar 3,984 µs →
   probe payı **0,41 µs**; var olan anahtar 19,787 µs (probe + satır
   çözme). Disk erişimi olsaydı 50–100 µs beklenirdi. Bloom en iyi
   durumda bu 0,41 µs'yi atlatır, kendi hash/bit testi maliyeti ~0,05–0,1
   µs + ek bellek ve `.idx` kaydı getirir: net kazanç gürültü altında.
   Nötr karmaşıklık eklememek için yapılmadı. Bloom'un gerçekten
   gerekeceği senaryo, anahtar dizinin **diskte** tutulduğu (bellek içi
   hash yerine B-tree) bir mimaridir; o ayrı bir tasarım kararıdır.
2. ~~**Merge JOIN**~~ — **ÖLÇÜMLE REDDEDİLDİ (2026-10-26); yerine gerçek
   darboğaz düzeltildi.** Ölçüm (`tmp64/joinbench`, 10k × 10k):
   - Hiç eşleşmeyen join (0 satır sonuç) **42 ms** → indekssiz eşitlik
     join'i zaten **hash** yolunda (nested loop 100M çift olsaydı ~6 s).
   - PK üzerinden join **46 ms**, 1M satırlık sonuç üreten join 3,2 s
     (maliyet sonuç satırı kopyalamada, join algoritmasında değil).
   Merge JOIN yalnız "iki taraf da zaten sıralı" durumda O(n+m) sağlar; bu
   motorda anahtarlar hash tabanlı, `ORDER BY` join'den sonra gelir, yani
   merge sıralama bedeli ödemek zorunda kalır ve hash'ten yavaş olur.
   Bunun yerine ölçümün gösterdiği **gerçek hata** düzeltildi (v3.12):
   `ON a.k=b.k AND a.x>5` gibi **eşitlik + ek koşul** içeren ON ifadeleri
   hash yolunu tamamen kapatıyordu; 10k × 10k'da sorgu **300 s'de
   bitmiyordu** (araç zaman aşımı). Artık AND ağacının içindeki
   kolon=kolon eşitliği hash anahtarı olur, ek koşullar `JoinOnOk`'ta
   aynen uygulanır (semantik değişmez; LEFT/FULL/NULL testleri eklendi).
   Aynı sorgu artık **5.926 ms**. Kalan maliyet, 1M aday çift için ek
   koşulun çift başına değerlendirilmesidir; bir sonraki kazanç ON/WHERE
   yüklemlerinin ilgili tarafa **itilmesidir** (ölçülmüş fırsat, ayrı
   madde).
3. ~~**Dosya boyutu**~~ — **YAPILDI (v3.13, 2026-10-26).** PK'nin satır
   gövdesinde ikinci kez yazılması kaldırıldı (`pkLen = 0` + kolon
   indeksi; dosya sürümü 5, eski dosyalar okunur ve ilk yazmada yükseltilir).
   Ölçüm: satır **−%13…%29**, kapanmış `.odb` **−%9,9…%12,8** (aynı veri,
   iki ikili). Hücre başlığı sıkıştırma (`ctype` baytını atmak) **reddedildi**:
   o bayt `ALTER COLUMN TYPE` sonrası karışık şemayı doğru çözen güvenlik
   ağıdır. Ayrıntı: §v3.13.
4. ~~**İfade bytecode**~~ **ÖLÇÜMLE YENİDEN ÇERÇEVELENDİ (v3.14)** —
   string tutan yığın bytecode ağaç yorumlayıcısından **%34 daha yavaş**
   (maliyet dağıtımda değil, ara metin üretiminde). Yerine **tip-duyarlı tam
   sayı yolu** yapıldı: INT kolon/tam sayı literali `+ - *` zincirleri
   Int64'te, ara metin yok (zincirlerde −%26…%39, ifadeli COUNT'ta −%15;
   ağaç yoluyla birebir aynı, diferansiyel kanıtlı). Ayrıntı: §v3.14.
5. ~~**Snapshot isolation**~~ **YAPILDI (v3.15)** — MVCC okuma izolasyonu:
   açık işlemi olan oturum, `BeginBatch` anındaki görüntüyü okur (v2 ile aynı
   semantik). Bellek içi post-image zinciri (`FUndo`), kendi yazıları öncelikli,
   commit çakışma denetimi (ilk commit kazanır) değişmedi. Ölçülen okuma
   maliyeti yok (snapshot temizken tek bayrak denetimi). Ayrıntı: §v3.15.

6. ~~**Süreçler arası çok yazarlılık**~~ **YAPILDI (v3.16)** — aynı `.odb`
   dosyasına birden çok süreç bağlanıp **sırayla** yazar; kilit işlem
   kapsamlıdır, önbellek `<db>.gen` sayacıyla tazelenir, veri kaybı yok
   (`prochk` 8/8, gerçek iki süreç). Yazarlar sıralıdır; uzun işlem diğer
   süreçleri bekletir. Ayrıntı: §v3.16.

### Kapsam dışı (değişmedi)
- M3 WASM, M7 async sunucu, WASM/edge
- ~~**Süreçler arası çok yazarlılık**~~ **v3.16'da yapıldı** (bkz. §v3.16).
  Snapshot isolation hâlâ **tek süreç içinde** çalışır; süreçler arasında
  görünürlük "son commit" düzeyindedir.

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
