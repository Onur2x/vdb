# VDB Performans İyileştirme Yol Haritası

> **Amaç:** VDB'nin yavaşlık nedenlerini ölçülebilir biçimde belirlemek ve veri doğruluğunu/çökme dayanıklılığını bozmadan hızlandırmak.
> **Hedef proje:** `Onur2x/vdb` — Free Pascal tabanlı, tek dosyalı ilişkisel veritabanı motoru.
> **Hazırlanma tarihi:** 2026-10-15
> **Bu belge bir uygulama talimatıdır:** Sonraki AI bu dosyadaki aşamaları sırayla uygulamalı; her aşamada test ve ölçüm kanıtı sunmalıdır.

---

## 1. Yönetici özeti

VDB'de hızlandırma için en doğru yaklaşım, varsayımlarla büyük bir yeniden yazım yapmak değil; önce tekrarlanabilir benchmark ve profiler ölçümü kurmak, sonra en pahalı yolları iyileştirmektir.

Depodaki `README.md`, motorun `VDbCore.pas` (append-only KV + kilit + dosya I/O), `VDbTable.pas` (tablo/şema/bellek içi indeks), `VDbExecutor.pas` (SQL yürütme), `VDbParser.pas` ve `VDbSql.pas` katmanlarından oluştuğunu belirtiyor. `docs/01-MOTOR.md` ayrıca PK lazy index, tembel sıralanan ikincil indeks işlemleri ve `SyncWriteInterval` group-commit ayarını belgeliyor.

Kaynakta açıkça belgelenmiş veya doğrulanması gereken başlıca performans riskleri:

1. **Disk yazma ve flush maliyeti:** `VDbCore` her kalıcı yazmada WAL/ana dosya/flush yolundan geçebilir. `SyncWriteInterval` için varsayılanın 0 olduğu ve daha büyük değerlerin flush'ları birleştirdiği belgelenmiş. Bu ayar güvenlik-kalıcılık semantiğiyle birlikte ölçülmeli; sessizce varsayılan değiştirilmemeli.
2. **Tarama ve indeks seçimi:** `VDbTable` PK lazy index ve ikincil indeksler içeriyor. `EXPLAIN` çıktısının gerçek yürütme yoluyla uyuşup uyuşmadığı, seçicilik ve indeks bakımı ölçülmeli.
3. **İndeks kurma/batch yazma:** `VDbTable.pas` içindeki açıklamalar, daha önce dinamik diziye tekrarlanan `SetLength(+1)` ve sıralı ekleme nedeniyle O(N²) davranış oluştuğunu; tembel sıralama + işlem tamponu ile bunun azaltılmasının hedeflendiğini söylüyor. Bu iyileştirmenin halen geçerli olup olmadığı benchmark ile doğrulanmalı.
4. **JOIN, GROUP BY, ORDER BY ve DISTINCT:** `VDbExecutor.pas` çok sayıda SQL yürütme yolunu yönetiyor. Büyük tablolar, çoklu JOIN, yüksek kardinaliteli gruplama ve sıralamada CPU/bellek maliyeti ayrı ayrı ölçülmeli.
5. **Özellik ve test belgeleri arasında tutarsızlık:** README yeni özellikler ve 2026-10-14 tarihli test sonuçları bildirirken `TEST_RAPORU_sqltest_vs_yol_haritasi.md` eski/çelişkili test sayıları ve MVCC konusunda tamamlanmamışlık iddiaları içeriyor. Performans değişikliğine başlamadan önce gerçek test komutları ve mevcut ana dal sonucu kaydedilmeli. Bu durum doğrudan yavaşlığın kanıtı değildir; doğrulama güvenilirliği riskidir.

**Önemli:** Henüz bu raporda herhangi bir performans ölçümü çalıştırıldığı iddia edilmemektedir. Aşağıdaki sayısal hedefler kabul ölçütü/başlangıç hedefidir; mevcut performans sonucu değildir.

---

## 2. Değişmez kurallar

AI uygulayıcısı aşağıdaki kuralları ihlal etmemelidir:

- Her optimizasyon öncesi mevcut davranış için test ve benchmark tabanı oluştur.
- Önce ayrı bir dal aç; doğrudan ana dalda büyük çaplı yeniden yazım yapma.
- Her değişiklik küçük, gözden geçirilebilir ve tek bir performans hipotezini sınayan bir commit olsun.
- SQL sonuçları, NULL davranışı, sıralama kararlılığı, transaction/rollback, benzersizlik, FK/CHECK/trigger, şifreleme, WAL recovery ve dosya formatı geriye uyumluluğu korunmalı.
- Dosya formatını, CRC düzenini, commit atomikliğini veya fsync davranışını sırf hız için değiştirme. Gerekirse ayrı bir tasarım belgesi, migration ve crash-test paketi oluştur.
- Ölçüm olmadan “daha hızlı” kabul etme. Önce/sonra sonuçları, aynı donanım/derleme/parametrelerle karşılaştır.
- Yeni bellek önbelleği eklenecekse geçersizleştirme kurallarını INSERT/UPDATE/DELETE, rollback, DDL, REINDEX, VACUUM/COMPACT ve yeniden açma için test et.
- Güvenlik özelliklerini (AES/HMAC, kimlik doğrulama, izinler) devre dışı bırakarak benchmark kazanımı sunma. Güvenlik açık/kapalı sonuçları ayrı raporlanabilir.
- Benchmark ve test başarısızsa değişikliği geri al veya düzelt; kırmızı testle sonraki aşamaya geçme.

---

## 3. Aşama 0 — Doğrulanabilir başlangıç tabanı (P0)

### 0.1 Depoyu ve derlemeyi kaydet

- Güncel commit SHA, dal adı, işletim sistemi, CPU, RAM, disk türü, FPC/Lazarus sürümü ve derleme bayraklarını raporla.
- `README.md` içindeki gerçek build komutlarını kullan: `lazbuild -B sqltest.lpi`, gerekliyse `vdbapi.lpi` ve sunucu projesi.
- Testleri temiz derlemeden çalıştır. Eski PPU/OBJ dosyalarının sonucu etkilemediğini doğrula.
- README'de bildirilen test sayıları ile gerçek test çıktısını ayrı kaydet. `TEST_RAPORU_sqltest_vs_yol_haritasi.md` eski veya çelişkili olabilir; bunu gerçek komut çıktısına bakmadan doğru kabul etme.

### 0.2 Benchmark programı oluştur

Ayrı, tekrar çalıştırılabilir bir benchmark projesi/komutu ekle. Her test 5 kez çalışsın; ilk ısınma turunu ayrıca göster, sonraki turlarda medyan ve p95 sürelerini raporla. Her senaryoda veri üretimi ile ölçülen sorgu süresini ayrı tut.

Asgari senaryolar:

| ID | İş yükü | Ölçülecek değer |
|---|---|---|
| B01 | 10 bin / 100 bin / 1 milyon satır INSERT; indeks yok | satır/sn, toplam süre |
| B02 | Aynı boyutlarda tekil INSERT, autocommit | işlem/sn, p50/p95 |
| B03 | Çok satırlı INSERT / BatchInsert / transaction | satır/sn, transaction süresi |
| B04 | PK eşitliği ve PK aralığı (BETWEEN) | p50/p95, taranan satır |
| B05 | İndekssiz ve indeksli seçici WHERE | süre, plan, taranan satır |
| B06 | ORDER BY + LIMIT, indeksli/indekssiz | süre, bellek |
| B07 | GROUP BY + COUNT/SUM/AVG | süre, satır sayısı |
| B08 | JOIN: küçük-küçük, küçük-büyük, büyük-büyük | süre, satır sayısı |
| B09 | UPDATE/DELETE: %1, %10, %100 satır | süre, indeks bakım maliyeti |
| B10 | Soğuk açılış, WAL recovery, yeniden açılış | açılış/recovery süresi |
| B11 | İkincil indeks oluşturma / REINDEX | satır/sn, süre, bellek |
| B12 | 1/2/4/8 istemci eşzamanlı okuma-yazma | throughput, p95, lock bekleme |
| B13 | Şifreleme açık/kapalı, aynı iş yükü | ek CPU maliyeti ve gecikme |
| B14 | Dosya büyümesi ve Compact/VACUUM | ölü bayt, dosya boyutu, süre |

Her koşuda motorun sonuçları doğrula: beklenen satır sayısı, checksum/hash, COUNT, min/max ve gerekli SQL doğrulamaları. Sadece süre ölçüp yanlış sonuç veren sürümü başarılı sayma.

### 0.3 Profiling / sayaçlar

- CPU profiler ile en çok zaman harcayan fonksiyonları bul.
- Geçici tanılama sayaçları ekle: disk yazma/okuma sayısı ve baytları, flush/fsync sayısı ve süresi, lock bekleme süresi, satır taraması, indeks adayı sayısı, satır decode sayısı, ifade değerlendirme sayısı, sort karşılaştırmaları ve hash çakışmaları.
- Sayaçlar varsayılan olarak kapalı veya düşük maliyetli olmalı; performans ölçümünü anlamlı ölçüde bozmamalı.
- `EXPLAIN ANALYZE` gerçek satır sayısı, süre ve tarama istatistikleriyle tutarlı mı doğrula. Plan etiketi tek başına yeterli değildir.

**Aşama 0 teslimi:** `benchmarks/README.md`, benchmark kodu, ham CSV/JSON sonuçları ve “en pahalı ilk 10 fonksiyon/işlem” raporu.

---

## 4. Aşama 1 — Yazma yolunu hızlandır (P1)

### 1.1 Transaction ve batch yazmayı ölç ve iyileştir

- Tek satır autocommit ile toplu INSERT'i karşılaştır.
- SQL katmanının otomatik transaction davranışını, `TVTableDb.BatchInsert` ve `TVDb.BeginBatch/CommitBatch` yollarını takip et.
- Batch içinde aynı anahtarın tekrar yazılmasında pending-operation yapılarının gereksiz tarama/kopyalama yapmadığını profiler ile doğrula.
- Her satır için tekrarlanan katalog yazımı, indeks rebuild'i veya gereksiz encode/decode varsa bir defalık işlem/batch kapsamına al; doğruluk ve hata durumlarında rollback korunmalı.
- Uygulama dokümantasyonuna yüksek hızlı toplu yükleme örneği ekle: tek transaction, çok satırlı INSERT veya desteklenen BatchInsert API.

### 1.2 Flush / group commit

- `VDbCore.pas` içindeki `SyncWrite`, `SyncWriteInterval`, `FDirty`, `AppendRec`, `AppendBatchEnd`, `Flush` ve WAL yazma yolunu izleyerek flush sayısını ve maliyetini ölç.
- `SyncWriteInterval=0` ile 1, 5, 10 ms gibi değerleri ayrı test et; yalnızca API'nin gerçek semantiği bu değerleri destekliyorsa kullan.
- Group commit, transaction onayı verildiği anda verinin dayanıklılığı konusunda hangi garantiyi sağlıyor açıkça belgele. Onaylanmış transaction'ı kaybetme riski yaratacak gecikmeli flush değişikliği yapma.
- Batch commit marker, CRC, WAL sırası ve crash recovery için hata enjeksiyon testleri ekle.
- Varsayılan ayarı değiştirmeden önce uyumluluk ve dayanıklılık kararı yazılı olarak gerekçelendir.

### 1.3 Gereksiz disk ve bellek kopyalarını azalt

- `TBytes` kopyaları, kayıt encode/decode, ara string oluşturma ve tekrarlı dosya seek'lerini profiler ile belirle.
- Sadece kanıtlanmış sıcak yollarda buffer reuse veya tek seferlik encode/decode uygula.
- Buffer yaşam süresi, aliasing ve thread güvenliğini test et.
- Kopyasız API'nin dışarıdan değiştirilebilir dahili belleği açığa çıkarmadığından emin ol.

**Kabul ölçütü:** B01/B03/B02 için öncesi-sonrası kıyas; en az %20 iyileşme hedefi yalnızca darboğazın bu yol olduğu kanıtlanırsa aranır. Küçük iş yükü veya okuma sorguları gerilememeli; dayanıklılık testlerinin tümü geçmeli.

---

## 5. Aşama 2 — İndeks ve tarama yolları (P1)

### 2.1 Planlayıcı doğruluğu

- `VDbExecutor.pas` içindeki `IndexUsedByWhere` ve `EXPLAIN` plan kararlarını, `VDbTable.pas` içindeki `CandidatePks`, `ScanRows`, `TryGetMemIndex`, PK lazy index ve ikincil indeks yapılarıyla karşılaştır.
- Eşitlik, IN, BETWEEN, aralık karşılaştırmaları, ORDER BY, bileşik indeks, partial index, expression index ve covering index için ayrı testler yaz.
- Seçici olmayan koşulda tablo taraması indeks taramasından daha ucuz olabilir; her zaman indeks seçme.
- İstatistik yoksa veya bayatsa planlayıcı güvenli bir varsayılan kullanmalı; yanlış satır sayısı tahminlerini ölç.

### 2.2 İndeks maliyeti

- Her INSERT/UPDATE/DELETE sırasında indeks başına kaç operasyon yapıldığını ölç.
- Bir transaction içindeki aynı (anahtar, PK) için son durum yaklaşımının gereksiz ara indeks güncellemelerini gerçekten önlediğini test et.
- `SetLength(+1)` ile her eklemede yeniden tahsis gibi O(N²) kalıplarını sıcak yollarda ara. Dinamik dizilerde amortize büyüme yoksa `TList`, kapasiteyi geometrik artıran tampon veya toplu dizi tahsisi değerlendir.
- Sıralama gerektiren indeks yapılarında ekleme maliyetini, arama hızını ve bellek kullanımını birlikte ölç; veri yapısını benchmark olmadan değiştirme.
- İndeks yeniden kurma işlemini tek tek kayıt eklemek yerine kayıtları toplayıp bir defa sıralama/merge ile kurmanın kazancını ölç.

### 2.3 İndeks geçersizleştirme

Aşağıdaki her olaydan sonra doğru sonuç garantisi ver: INSERT, UPDATE (indeks kolonunun değişmesi/değişmemesi), DELETE, rollback, savepoint rollback, DROP/ALTER TABLE, CREATE/DROP INDEX, REINDEX, VACUUM/COMPACT ve yeniden açılış.

**Kabul ölçütü:** B04/B05/B06/B11 sonuçları ve gerçek taranan satır sayılarıyla kanıtlanmalı. İndeksli sorgular hızlanırken yazma performansı ve sonuç doğruluğu da raporlanmalı.

---

## 6. Aşama 3 — SQL yürütücüsü (P1/P2)

### 3.1 WHERE ifadesi

- Her satır için tekrar tekrar kolon adı arama, ifade ağacı çözümleme, string parse veya tip dönüştürme yapılıyorsa sorgu başında çözümle ve önbelleğe al.
- İfade sonuçlarını yalnızca güvenli olduğu kanıtlanan sabit/parametreli alt ifadeler için sorgu boyunca önbelleğe al; satıra bağlı ifadeleri yanlışlıkla cache'leme.
- Tip uyumlu karşılaştırmaları mümkün olduğunda string'e çevirme ve tekrar parse etme maliyetinden kurtar; NULL ve collation semantiğini koru.

### 3.2 ORDER BY / LIMIT

- LIMIT küçük olduğunda tüm sonuç kümesini sıralamanın yerine top-K heap/selection yaklaşımını değerlendir; OFFSET, çok kolonlu sıralama, ASC/DESC, NULLS FIRST/LAST ve kararlı sıralama semantiği korunmalı.
- İndeks sırası sorgunun ORDER BY şartını tam karşılıyorsa tekrar sıralama yapma.
- Quicksort karşılaştırmalarında pahalı ifade değerlendirmesinin her karşılaştırmada yinelenmediğini kontrol et.

### 3.3 GROUP BY / DISTINCT / UNION

- Grup anahtarını satır başına bir kez hesapla.
- Hash tablosu kapasite büyütme, string birleştirme ve satır kopyalama maliyetini ölç.
- DISTINCT/UNION hash anahtarları NULL, delimiter ve Unicode durumlarında çakışmasız olmalı.
- Büyük ara sonuçlar için bellek üst sınırı ve kontrollü hata davranışı korunsun.

### 3.4 JOIN

- `ExecJoinScan` ve ilişkili JOIN kod yollarını profiler ile ölç. İç içe döngüyle N×M tarama yapılıyorsa, uygun eşitlik JOIN'lerinde hash join veya indeksli nested-loop alternatifini değerlendir.
- JOIN sırasını değiştirmek için tahmini satır sayıları ve seçicilik istatistikleri kullan; dış JOIN semantiğini ve NULL üretimini bozma.
- Hash join için bellek sınırı, hash çakışmaları ve gerekirse fallback davranışı tanımla.
- JOIN sonucu, çoğaltılan satırlar, alias/qualified columns, ON/WHERE ayrımı ve agregasyon için regresyon testleri ekle.

**Kabul ölçütü:** B05–B08 üzerinde önce/sonra ölçümü; büyük veri setinde CPU/bellek ve sonuç eşitliği. İyileştirme yalnızca ilgili iş yükü için raporlanmalı, tüm sorgulara genellenmemeli.

---

## 7. Aşama 4 — Açılış, WAL, dosya boyutu ve bakım (P2)

- Soğuk açılışta tüm kayıtların taranıp taranmadığını, indeksin yeniden kurulup kurulmadığını ve katalog çözümleme maliyetini ölç.
- Açılış için kalıcı indeks/checkpoint gibi bir tasarım önerilecekse sürümleme, atomik dosya değişimi, checksum, crash recovery ve eski dosya uyumluluğu ayrı tasarlanmalı; bu aşamada dosya biçimi değiştirilmemeli.
- Append-only dosyada silinmiş/eski kayıtların yarattığı ölü bayt miktarını ölç. `FDeadBytes`, Compact/AutoCompact tetikleme ve `Compact` maliyetini incele.
- Compact sonrası sonuçların, şifreli kayıt bayraklarının, PK/sekonder indekslerin ve WAL/backup'ın doğru kaldığını doğrula.
- WAL büyümesi, checkpoint ve recovery süresini büyük dosyalarda ölç; checkpoint'in veri kaybı veya tutarsız dosya yaratmadığını crash-test ile doğrula.
- `VDbWal.pas` içindeki harici WAL iskeletinin `docs/01-MOTOR.md` tarafından kullanılmayan kod olarak işaretlendiğini göz önünde bulundur. Gerçek yazma/recovery yolunun `VDbCore.pas` içindeki uygulama olduğu belirtiliyor; yanlış WAL katmanını optimize etme.

**Kabul ölçütü:** B10/B14; 10 bin, 100 bin ve 1 milyon satırla (makine belleği uygunsa) ölçüm. Açılış ve recovery doğruluğu ayrı raporlanmalı.

---

## 8. Aşama 5 — Eşzamanlılık ve TCP sunucusu (P2)

Bu aşamaya yalnızca tek iş parçacıklı ölçümlerdeki başlıca darboğazlar giderildikten sonra geç.

- `TCriticalSection`/DB kilitlerinin kapsamını, bekleme süresini ve kilit altında yapılan disk I/O'yu ölç.
- Kilit kapsamını daraltmadan önce dosya stream'i, indeksler, transaction ve WAL için yarış koşullarını modelle.
- Paralel SELECT veya worker pool'un gerçekten hızlanma sağladığını ölç; iş parçacığı oluşturma, sonuç birleştirme ve kilit maliyeti kazancı aşabilir.
- TCP SQL sunucusunda bağlantı başına parse/prepare, oturum oluşturma, serileştirme ve ağ round-trip maliyetlerini ayrı ölç.
- Prepared statement/connection pool testlerini gerçek eşzamanlı yükte çalıştır; aynı bağlantıda eşzamanlı isteklerin güvenli olup olmadığını belgele.
- Deadlock, starvation, shutdown ve bağlantı kopması testleri ekle.

**Kabul ölçütü:** B12 throughput + p95/p99 gecikme + CPU kullanımı + kilit bekleme ölçümü. Tek istemcide gerileme ve çok istemcide kazanım birlikte gösterilmeli.

---

## 9. Aşama 6 — Sonuçların yayınlanması ve dokümantasyon

Uygulayıcı aşağıdaki dosyaları eklemeli veya güncellemelidir:

- `benchmarks/README.md` — makine, derleme ve çalıştırma yönergeleri.
- `benchmarks/results/baseline.*` ve `benchmarks/results/after.*` — ham sonuçlar (CSV veya JSON).
- `docs/PERFORMANCE.md` — ölçülen darboğazlar, optimizasyonlar, sınırlamalar, güvenli ayarlar.
- `yol_haritasi_hiz.md` — tamamlanan maddeler, commit SHA'ları ve ölçüm kanıtları.
- Gerekirse `README.md` — batch insert ve performans ayarları için doğru kullanım örnekleri.

Her optimizasyon için tablo:

| Alan | Zorunlu içerik |
|---|---|
| Hipotez | Hangi maliyetin baskın olduğu |
| Kanıt | Profil/istatistik ve ilgili fonksiyonlar |
| Değişiklik | Dosya, fonksiyon, commit |
| Önce/sonra | Medyan, p95, throughput, bellek |
| Doğruluk | Test komutu ve sonuç |
| Risk | Kalıcılık, uyumluluk, eşzamanlılık |
| Karar | Kabul / geri al / ek araştırma |

---

## 10. Önceliklendirme tablosu

| Öncelik | İş | Neden |
|---|---|---|
| P0 | Tekrarlanabilir benchmark + profiler | Darboğazı kanıtlar, yanlış optimizasyonu önler |
| P0 | Temiz build ve test tabanı | Sonuçları güvenilir yapar |
| P1 | Batch/autocommit ve flush maliyeti | Disk senkronizasyonu yazma hızını belirleyebilir |
| P1 | İndeks/PK/scan planı doğrulaması | Sık sorgularda tam tablo taramasını azaltabilir |
| P1 | İndeks oluşturma ve indeks bakım maliyeti | Büyük yüklemelerde O(N²) kalıplarını yakalar |
| P1 | WHERE/JOIN/GROUP BY/ORDER BY profiling | Büyük veri kümelerinde CPU ve bellek maliyeti |
| P2 | Açılış, recovery, compact | Büyüyen dosyalarda zaman ve disk kullanımını etkiler |
| P2 | Kilitler, TCP ve paralellik | Çoklu istemci yüküne özgü sorunlar |
| P2 | Dokümantasyon ve sürekli benchmark | Gerilemeleri erken yakalar |

---

## 11. AI uygulayıcı için kesin görev talimatı

1. Önce depodaki güncel kodu oku; bu raporda adı geçen sembollerin güncel dalda varlığını doğrula. Yorum satırlarını uygulama kanıtı sayma.
2. `yol_haritasi_hiz.md` dosyasını değiştirmeden önce mevcut halini ve dal/commit bilgisini kaydet.
3. Aşama 0'ı tamamlamadan büyük kod değişikliği yapma.
4. En pahalı üç darboğazı kanıtlarıyla seç ve her biri için ayrı değişiklik yap.
5. Her değişiklikte testleri ve aynı benchmark'ı yeniden çalıştır; önce/sonra ham sonuçlarını commit'e ekle.
6. Tam test komutlarını, test sayısını, başarısız testleri ve ortam bilgisini raporla. Test çalıştırılamadıysa bunu açıkça belirt; geçmiş rapordan başarı sonucu kopyalama.
7. Veri bütünlüğü, crash recovery veya SQL davranışı değişirse optimizasyonu kabul etme.
8. Bitirince bu raporun sonuna “Uygulama Sonuçları” bölümü ekle: tamamlanan işler, commit SHA'ları, ölçümler, test çıktıları, kalan riskler ve önerilen sonraki adımlar.
9. Benchmark sonucu olmadan “X kat hızlandı” gibi iddialar yazma.
10. Kapsam büyükse güvenli küçük PR/commit'ler halinde ilerle; özellikleri aynı anda topluca yeniden yazma.

## 12. Kaynak dosyalar

- `README.md` — mimari, build komutları, bildirilen testler ve performans özellikleri.
- `VDbCore.pas` — append-only KV, lock, batch, flush, WAL, CRC, encryption ve group commit.
- `VDbTable.pas` — tablo satırları, PK lazy index, ikincil indeksler, batch insert ve indeks bakım yolları.
- `VDbExecutor.pas` — SQL yürütme, WHERE/JOIN/GROUP BY/ORDER BY ve planlama bağlantıları.
- `VDbSql.pas` / `VDbParser.pas` / `VDbAst.pas` — SQL giriş, parse, AST ve transaction akışı.
- `docs/01-MOTOR.md` — motor birimleri ve mimari envanteri.
- `TEST_RAPORU_sqltest_vs_yol_haritasi.md` — test/yol haritası uyumsuzlukları; güncel gerçek test çıktısıyla karşılaştırılmalı.

---

**Başarı tanımı:** VDB daha hızlı olduğu iddia edilen bir motor değil; aynı doğruluk ve dayanıklılık garantilerini korurken, tekrarlanabilir testlerde ölçülebilir biçimde daha hızlı olduğu gösterilen bir motor olmalıdır.
