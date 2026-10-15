# VDB — Kaynak Koduna Dayalı Performans İyileştirme Planı

Tarih: 2026-10-15  
Depo: `Onur2x/vdb`

> Bu plan, mevcut özellikleri yeniden önermek için değil, mevcut uygulamanın içindeki maliyetli algoritmaları hedeflemek için hazırlandı. CBO, ANALYZE, Parallel Query, PK Lazy Index, Group Commit, index-only/covering index, partial/expression index, batch işlemleri ve connection pool zaten projede bulunuyor. Bunları “eksik özellik” gibi yeniden uygulamayın.

## En önemli sonuç

Kod incelemesinde en somut ilk adaylar:
1. Her tablo taramasında tüm veritabanının KV kayıtlarının taranması.
2. Tarama ve indeks güncelleme döngülerinde her satırda dinamik dizinin yeniden boyutlandırılması.
3. Küçük indeks değişikliklerinde indeks dizisinin tamamının yeniden kurulup sıralanması.
4. Kayıt okumalarında dosyada tekrar tekrar konum değiştirilmesi ve büyük taramalarda rastgele I/O.
5. TCP SQL sunucusunda sorguların seri yürütülmesi; bağlantı havuzunun bunu paralelleştirmemesi.

Bunlar kaynak kodunda görülen adaylardır; henüz benchmark ile ölçülmüş hızlanma iddiası değildir.

---

## 1. P0 — Gerçek darboğazı belirle; mevcut özellikleri tekrar yazma

### 1.1 Üç ayrı maliyet sınıfını ölç

Aynı veri kümesinde ayrı ayrı ölç:
- Tek PK okuması ve PK aralık sorgusu.
- Büyük tek tablo taraması.
- Aynı toplam satır sayısı farklı sayıda tabloya dağıtılmışken tek bir tablonun taranması.
- Bir tabloya 1, 10, 100 ve 1000 satır ekledikten sonra indeksli sorgu.
- 1 satır, %1 satır ve çok sayıda satır güncellemesi/silmesi.
- Aynı SELECT sorgusunun tekrar tekrar çalıştırılması.
- 1, 2, 4, 8 istemciyle TCP üzerinden eşzamanlı sorgu.

Her testte sorgu süresi yanında CPU, tahsis/kopyalama sayısı, dosya okuma sayısı/baytı, seek/konum değiştirme sayısı, indeks girdisi sayısı ve kilit bekleme süresi ölçülsün. Sorgu sonuçları ve satır sayısı doğrulansın.

### 1.2 Mevcut altyapıyı kullan

Projede `SHOW STATS`, `SHOW SLOW QUERIES`, `ANALYZE`, `EXPLAIN`, CBO ve paralel sıralama var. Bunları yeniden kurma. Ancak mevcut metriklerin fonksiyon bazında tahsis, dosya I/O ve kilit beklemesini göstermemesi durumunda yalnızca bu eksik sayaçları ekle.

---

## 2. P1 — Tablo taramasını tüm veritabanını taramaktan çıkar

### Kaynakta görülen durum

`VDbTable.pas` içindeki `TVTableDb.ScanRowsPart` şu yolu izliyor:

1. `FKv.ScanAll(keys, raw)` çağrısı yapıyor.
2. Dönen kayıtları tek tek `DecodeRow` ile çözüyor.
3. `tid <> t.TableId` olan satırları ancak bundan sonra eliyor.
4. Partition pruning de kayıt çözümlendikten sonra uygulanıyor.

Bu nedenle yalnızca bir tablonun satırları istense bile KV katmanındaki tüm aktif kayıtlar üzerinde çalışma yapılabiliyor. Birden çok tablo bulunan veritabanlarında maliyet hedef tablo büyüklüğünden ziyade tüm veritabanı büyüklüğüne yaklaşabilir.

### Yapılacaklar

**Aşama A — düşük riskli çözüm**
- Tablo kimliği başına aktif KV anahtarlarını tutan bir bellek içi tablo-kayıt dizini oluştur.
- Açılış/recovery sırasında bu dizini tek seferde kur; INSERT/DELETE/UPDATE ve transaction rollback yollarında doğru tut.
- Tablo taraması sadece o tabloya ait anahtarları dolaşsın.
- Eski dosyalarla uyumluluğu koru; indeks bellekte yeniden kurulabiliyorsa kalıcı dosya formatını değiştirme.

**Aşama B — daha kapsamlı çözüm**
- KV anahtar düzenini tablo kimliği + PK veya tablo kimliği + iç kayıt kimliğiyle yönlendirilebilir hale getirmeyi değerlendir.
- Mevcut `VDbHashKey(table, pk)` yaklaşımının ve hash çakışması denetiminin geriye uyumluluğunu korumak için bu değişikliği ayrı tasarım/migration çalışması olarak ele al.
- Fiziksel bölümleme yapıldığı varsayılmamalı: belgelerde partitioning davranışsal olarak uygulanıyor; satırlar hâlâ ortak KV alanında duruyor.

### Kabul testi

Aynı hedef tablo 10 bin satır içerirken diğer tablolara toplam 10 bin, 100 bin ve 1 milyon satır ekle. Hedef tablonun tarama süresini karşılaştır. Diğer tablolara kayıt eklenmesi hedef tablonun tarama maliyetini büyük ölçüde artırmamalı.

---

## 3. P1 — Dinamik dizileri her satırda büyütme

### Kaynakta görülen durum 1: `ScanRowsPart`

`VDbTable.pas` içinde satır eklendikçe şu işlemler yapılıyor:

```pascal
SetLength(Pks, n + 1);
SetLength(Rows, n + 1);
Pks[n] := pk;
Rows[n] := vals;
Inc(n);
```

Her eşleşen satırda yeniden boyutlandırma, bellek tahsisi ve olası kopyalama yaratır. Büyük sonuç kümelerinde bu, ciddi bir O(N²) maliyet adayıdır.

### Kaynakta görülen durum 2: `FlushIdxPending`

Aynı birimde `TVTableDb.FlushIdxPending`, mevcut girdileri `keep` dizisine eklerken tekrar tekrar `SetLength(keep, Length(keep) + 1)` kullanıyor. Son durumdaki yeni girdiler eklenirken de aynı örüntü var.

### Yapılacaklar

- `TList<T>` veya geometrik kapasite artıran bir tampon kullan; her eleman eklemesinde kapasiteyi tam bir artırma.
- Uygun olduğu yerde önce üst sınır kapasitesi tahsis edip sonuçta gerçek uzunluğa küçült.
- İç içe dinamik dizilerde (`TStrMatrix`) yalnız dış dizinin değil satır ve hücre stringlerinin de kopyalama maliyetini ölç.
- Sadece bu iki fonksiyonla sınırlı kalma: `VDbTable.pas` ve `VDbExecutor.pas` içinde döngü gövdesinde `SetLength(array, Length(array)+1)` araması yap; her örneği ölçerek sırala.
- Satır sırası, hata durumları, NULL ve transaction semantiğini değiştirme.

### Kabul testi

10 bin / 100 bin / 1 milyon satırlı taramalarda ve büyük indeks güncellemelerinde süre, tahsis sayısı ve tepe bellek kullanımını önce/sonra kıyasla. Büyük N için büyüme davranışının karesel olmaktan uzaklaştığını ölçümle göster.

---

## 4. P1 — İndeks güncellemelerinde tam kopyalama ve tam sıralamayı azalt

### Kaynakta görülen durum

`TVTableDb.FlushIdxPending`:
1. Bekleyen operasyonlardan PK başına son durumu `lastOp` sözlüğünde çıkarıyor.
2. Eski indeksin tamamını dolaşıp değişen PK'leri `keep` dizisinden eliyor.
3. Değişen satırların son durumlarını ekliyor.
4. Tekrar sıralayıp bütün indeksi `FMemIdx` içine koyuyor.

Bu yaklaşım indeksin doğru kalmasını sağlayan mevcut mekanizmadır; fakat indeks büyük ve değişiklik kümesi küçükse iş miktarı değişiklik sayısına göre değil, indeksin tamamına göre büyür. Ayrıca adım 2 ve 3'te tekrarlanan `SetLength` maliyeti var.

### Yapılacaklar — aşamalı

1. Önce kapasite artışı/kopyalama sorununu düzelt.
2. Bekleyen değişiklikleri anahtar sıralı küçük bir diziye çevir ve mevcut sıralı indeksle merge yaklaşımını ölç. Bu, tam indeksi yeniden sort etmekten daha ucuz olabilir.
3. Tekil/small-batch değişikliklerde artımlı ekleme/silme yolunu ölç; mevcut sorted-array yapısında her eklemenin kaydırma maliyetini de hesaba kat.
4. Yalnız benchmark sorted array'in sınırlarını kanıtlarsa B-tree, B+ tree veya başka bir sıralı indeks yapısını prototiple. İlk adımda bütün indeks mimarisini körlemesine değiştirme.
5. UNIQUE, partial, expression, multi-column, INCLUDE/covering indeks davranışlarını; rollback ve concurrent index build catch-up akışını test et.

### Kabul testi

1, 10, 100 ve 10.000 satır güncellemesi; 100 bin ve 1 milyon indeks girdisi için ölçülsün. Küçük değişikliklerin maliyeti tüm indeks boyutuyla orantılı biçimde artıyorsa optimizasyonun bunu azaltması hedeflensin.

---

## 5. P1 — Kayıt okumalarını rastgele I/O ağırlığından çıkar

### Kaynakta görülen durum

`VDbCore.pas` içindeki `TVDb.GetSnapshot` indeks girdisinden konum bulduktan sonra `FS.Position := loc.Offset` ve `Read` çağırıyor. `ScanSnapshot` da `FIndex` üzerinde dolaşıp her kayıt için dosya konumuna gidiyor. Bu, tarama sırasında çok sayıda konum değiştirme ve değer kopyalama anlamına geliyor.

Ayrıca `ScanSnapshot` tüm `Keys`/`Vals` sonuçlarını belleğe materyalize ediyor. `ScanRowsPart` bu dizileri alıp satırları tekrar çözüyor. Büyük taramalarda aynı verinin birden fazla kez taşınıp çözülmesi olası.

### Yapılacaklar

**Kısa vadeli**
- Dosyadan okuma/konum değiştirme ve değer kopyalama sayısını ölç.
- Ardışık veya yakın offset'leri topluca okuyabilen scan yolu prototiple; kayıt CRC/header doğrulamasını koru.
- `ScanSnapshot` → `ScanRowsPart` yolundaki çift kopyalama/çift decode ihtimalini kaldırmak için kontrollü bir iterator/callback API değerlendir.
- Sık erişilen kayıtlar için sınırlı boyutlu row cache veya blok cache prototipi hazırla. Varsayılan bellek üst sınırı ve eviction stratejisi belirle.

**Orta vadeli**
- Append-only kayıt düzeni korunacaksa cache blokları fiziksel offset bazında tasarlanabilir.
- Daha büyük mimari değişiklik olarak sabit boyutlu sayfalar + buffer pool veya LSM/B-tree tabanlı depolama değerlendirilir; bu, dosya formatı ve recovery tasarımını etkileyebileceğinden ayrı dal/benchmark/migration çalışması olmalı.

### Güvenlik ve eşzamanlılık denetimi

`GetSnapshot` yorumunda okuma “lock-free” olarak adlandırılıyor; ancak aynı `TFileStream` nesnesinin `Position` ve `Read` işlemleri kullanılıyor. Birden çok okuyucunun aynı stream üzerinde eşzamanlı çalışması hedefleniyorsa, konumun paylaşımlı olması yarış riski yaratabilir. Bunu gerçek çağrı zincirleri ve testlerle doğrula. Gerekirse offset tabanlı konumsal I/O veya okuyucu başına ayrı handle kullan; snapshot semantiğini bozma.

### Kabul testi

Sıcak/soğuk cache durumunda PK lookup ve full scan ayrı ölçülsün. Bellek kullanımı sınırlı kalsın; encryption, CRC ve corruption detection açıkken sonuçlar birebir aynı olsun.

---

## 6. P1/P2 — SQL parse maliyetini tekrar eden sorgularda azalt

### Kaynakta görülen durum

`VDbSql.pas` içindeki `TVSql.ExecRaw`, normal komutlar için her çağrıda `TVDbParser.Create`, `Parse(Sql, FParams)`, `TVSqlExecutor.Create` ve AST yürütme yapıyor. Prepared statement API'si mevcut olsa da normal `Exec` yolunun her sorguda yeniden parse/plan maliyeti olup olmadığı ayrıca ölçülmeli.

### Yapılacaklar

- Aynı parametreli SELECT'i binlerce kez çalıştırıp parse, plan ve yürütme sürelerini ayrı ölç.
- Güvenli bir prepared-statement/AST cache prototipi oluştur: SQL metni + parametre tipi/şekli + schema version + role/RLS/security context gibi planı etkileyen bağlam cache anahtarıyla uyuşmalı.
- AST'de parametre değerleri değişebilir olmalı; önceki çağrının değerleri veya yetki bağlamı sızmamalı.
- DDL, schema değişimi, role/policy değişimi, collation/extension değişimi ve statement invalidation kurallarını açıkça uygula.
- Parser/AST nesnelerinin thread-safe ve sahiplik açısından güvenli olduğundan emin ol.

### Kabul testi

Tekrarlanan aynı sorgu ve değişen parametreli sorgular karşılaştırılsın. İlk çalıştırma ile sonraki çalıştırmaların parse/plan maliyeti raporlansın; cache invalidation testleri geçsin.

---

## 7. P2 — CBO'yu daha doğru maliyet modeline bağla

CBO ve ANALYZE zaten mevcut. Eksik olan “CBO eklemek” değil, tahminlerin gerçek I/O ve veri dağılımına uyumunu doğrulamak.

### Kaynakta görülen aday

`VDbCost.pas` maliyet modeli sabit `VDB_C_SEQ_ROW`, `VDB_C_IDX_PROBE`, `VDB_C_IDX_FETCH`, `VDB_C_IDX_ONLY` değerleri kullanıyor. `VdbEstimateEqRows` distinct istatistiği yoksa `RowCount div 4` sezgisel tahminine dönüyor. Bu, veri dağılımı çarpık kolonlarda yanlış plan seçimine yol açabilir.

### Yapılacaklar

- `EXPLAIN` tahmin edilen satır sayısını gerçek satır sayısıyla karşılaştıran test seti kur.
- Uniform ve skewed dağılımlar, yüksek NULL oranı, korelasyonlu kolonlar, dar/geniş aralıklar ve farklı indeks kapsama oranları test edilsin.
- Gerekirse histogram, most-common-values ve kolon korelasyonu istatistikleri ekle; önce istatistiklerin depolanması/yenilenmesi ve boyut maliyetini tasarla.
- Maliyet katsayılarını rastgele değiştirme: scan başına gerçek satır/byte, cache hit/miss ve random fetch maliyetini ölçerek kalibre et.
- Çok kolonlu koşullar ve JOIN tahmin hatalarını kaydet; yanlış tahminin kötü plan doğurduğu vakaları regresyon testine dönüştür.

### Kabul testi

Tahmin/gerçek satır oranı, yanlış plan seçimi sayısı ve toplam sorgu gecikmesi raporlansın. Sadece EXPLAIN metninin değişmesi başarı sayılmasın.

---

## 8. P2 — TCP sunucusunun seri yürütüm sınırını ele al

### Kaynakta görülen durum

`VDbPool.pas` bağlantı havuzunun aynı motor üzerinde paralelliği artırmadığını açıkça söylüyor. `yol_haritasi.md` de TCP SQL sunucusunun tek motoru kilit altında seri yürüttüğünü belirtiyor. Daha fazla bağlantı, yalnız başına daha fazla sorgu throughput'u sağlamaz.

### Yapılacaklar

1. TCP sunucusunda accept/parse/execute/serialize/response sürelerini ayrı ölç.
2. Yalnız yanıt yazımı değil, DB erişimindeki gerçek seri bölümün süresini belirle.
3. Önce P1'deki paylaşımlı stream erişimi ve tablo/indeks okuma güvenliğini çöz.
4. Ardından paralel read-only sorgular için snapshot bazlı read context ve okuyucu başına güvenli I/O tasarla; writer/DDL/maintenance işlemlerini güvenli sırada tut.
5. Aynı dosya üzerinde birden çok bağımsız motor açarak kilidi aşmaya çalışma; bu veri bütünlüğünü bozabilir.
6. Writer starvation, DDL, transaction izolasyonu, RLS/RBAC bağlamı, shutdown ve crash recovery testleri ekle.

### Kabul testi

1/2/4/8 istemci için throughput, p50/p95/p99, CPU, lock wait ve doğruluk raporlansın. Tek istemcide ciddi gerileme olmadan eşzamanlı salt-okunur yükte kazanım gösterilmeden “paralellik tamamlandı” denmesin.

---

## 9. Uygulama sırası

| Sıra | İş | Gerekçe |
|---|---|---|
| 1 | ScanRowsPart ve FlushIdxPending içindeki tekrarlanan SetLength kalıplarını düzelt | Küçük ve kaynakta doğrudan görülen algoritmik iyileştirme |
| 2 | Tablo başına aktif anahtar dizini | Tablo taramasının tüm KV alanını dolaşması maliyetini kaldırma |
| 3 | İndeks flush için küçük-delta merge/artımlı güncelleme deneyi | Az sayıda yazmada tam indeks maliyetini azaltma |
| 4 | ScanSnapshot/ScanRowsPart çift materyalizasyonu ve rastgele I/O | Büyük okuma iş yükleri |
| 5 | Aynı SQL için parse/plan cache deneyi | Tekrarlanan kısa sorgularda CPU maliyeti |
| 6 | Gerçek veriye göre CBO kalibrasyonu | Yanlış plan seçimini azaltma |
| 7 | TCP paralel read mimarisi | Daha yüksek riskli mimari çalışma |

Her aşama ayrı commit olsun. Önceki aşamanın doğruluk testleri geçmeden sonraki aşamaya geçilmesin.

---

## 10. AI uygulayıcı için kesin talimat

- Bu rapordaki mevcut kaynak kodu gözlemlerini güncel dalda yeniden doğrula; fonksiyon/algoritma değişmişse raporu güncelle.
- Özellik listesine yeni bir “özellik” eklemek yerine mevcut sıcak yolun algoritmik maliyetini azalt.
- İlk olarak 1. ve 2. sıradaki düşük riskli değişiklikleri uygula; büyük mimari yeniden yazımla başlama.
- Her değişiklik için ham önce/sonra benchmark sonuçlarını ve test komutlarını kaydet.
- MVCC, transaction/savepoint/rollback, unique/FK/check, partial/expression/covering index, concurrent index build, encryption, CRC, WAL recovery, CDC/Time Travel ve dosya uyumluluğu regresyonlarını koru.
- Test çalıştırılamadıysa başarılıymış gibi yazma.
- “10x hızlandı” gibi iddiaları yalnızca aynı ortamda ölçülen sonuçlarla bildir.
- Sonuç raporuna hangi iş yüklerinin hızlandığını, hangilerinin gerilediğini, tepe bellek kullanımını ve kalan riskleri yaz.

**Başarı tanımı:** Yeni bir özellik eklenmesi değil; mevcut VDB kodunun büyük tablolarda daha az gereksiz kayıt taraması, daha az bellek kopyalaması, daha az indeks yeniden inşası ve daha az I/O ile aynı doğru sonuçları üretmesidir.
