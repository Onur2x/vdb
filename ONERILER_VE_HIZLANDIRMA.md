# VDB v3 — Yapılacaklar, Öneriler ve Hızlandırma Yol Haritası

**Tarih:** 2026-11-11
**Durum:** v3 dalı, P-152–P-187 uygulandı. Sıfırdan denetim turu (4 alt
ajan) SQL semantiği bulgularını kapattı (P-183, `sqlsemanticschk` kapısı;
kayıt DERINLEMESINE_INCELEME_2.md EK-X) ve depolama kuyruğunu kapattı
(P-184, `incbakchk` kapısı; kayıt EK-Y). Ağ/güvenlik (P-185) kuyruğu
sıradadır. P0-2 ölçülen hedef bandına indi
(toplu DELETE 5.83 → 4.18 µs/satır). P0-6 tamamen kapandı: zone map'li
`COUNT` (P-158, 55 → 1.3 ms), paralel `WHERE`'siz aggregate (P-159, ~1.6x)
ve `WHERE`'li aggregate (P-160, ~7.6x). P0-7'nin iki önerisi motorda zaten
uygulanmış (artımsal tazeleme + süreçler arası grup fsync); P0-9'da ucuz
kazanç yok. P-162 alt-küme `SELECT`'te ara `vals` dizisini kaldırdı
(1 kolon ~%21, 3 kolon ~%13). P-163 tipli sonuç kanalını (`ExecTyped`) ekledi;
ölçüm, metin malzemelemenin P0-10'da varsayıldığı gibi baskın maliyet
olmadığını gösterdi (tipli kanal 1 kolonda eşit, çok kolonda %5-9 daha
yavaş — hücre matrisi bellek trafiği). P-164 P1-1'i kapattı: `.gen`
dosyasına tablo kapsamlı sayaç bölgesi eklendi; iyimser commit yalnız
okuduğu tablonun sayacına bakar, ilgisiz tablo commit'i yanlış abort
üretmez. P-165 kalan iki küçük riski kapattı: özel erişim bayrağı artık
`SHOW STATS`'ta görünür (P1-4) ve savepoint'ler v2/v3 için tek uygulamadan
geçer (P1-5). P-166 dayanıklılık açığını (fsync hatasında hayalet commit)
kapattı ve sınırlı soak kapısını (`soakchk`) ekledi; Unix/macOS paritesi
zaten P-76'dan beri CI'da koşuyor.
**Kaynaklar:** `hiztesti.md` (2026-11-07 SQLite karşılaştırması),
`DERINLEMESINE_INCELEME_2.md` (EK-S/EK-T/EK-U/EK-V/EK-W/EK-X),
`V3_YOL_HARITASI.md` (§7k, §7l, §7o), `readme_tr.md`, doğrudan kod okuması.

Bu belge "ne kaldı, ne hızlandırılır, hangi sırayla" sorusuna kanıtlı cevap
vermek için yazıldı. Her maddede **kanıt → kök neden → öneri → beklenen
kazanç → efor → risk → doğrulama** düzeni var. Tahminler ölçüm değildir;
her madde uygulanmadan önce ve sonra aynı oturumda ölçülmelidir.

---

## 0. Yönetici özeti

Motorun doğruluk ve dayanıklılık tarafı sağlam: 35/35 kapı, `sqltest`
2887/0/33, `commitfailchk` 29/29, sızıntı artığı 4 blok / 53 bayt. Kalan iş
neredeyse tamamen **toplu yazma, analitik tarama ve açılış süresi**.

En yüksek getirili beş iş, bu sırayla:

1. **Toplu INSERT/UPDATE/DELETE yolları** (13x / 13.5x / 56.5x yavaş).
   Önce INSERT'te ifade başına ayrıştırma maliyetini ayır, sonra toplu
   DML için tek geçişli yol ekle.
2. **`ORDER BY ... LIMIT` ve aggregate taramaları** (8.2x / 4.3x / 2.3x).
   Ham akış hızlı yollarının gerçekten devreye girip girmediğini ölç,
   satır başına gereksiz hash/doğrulama işini kaldır.
3. **Yeniden açma: 313 ms → hedef < 50 ms.** Uygulama açılışında her
   başlatmada ödenen bu bedel, komut satırı araçları ve kısa ömürlü
   süreçler için en görünür sorundur.
4. **Zone map ve paralel sorgu v3'te kapalı.** Kod var, `Kv = nil` olduğu
   için hiç çalışmıyor. Bunları sayfa motoruna bağlamak, büyük tablolarda
   tam tarama maliyetini düşürmenin en ucuz yolu.
5. **Global `.gen` yüzünden yanlış abort riski** (EK-S.5 / EK-U.4).
   Performans değil doğruluk borcu, ama çok süreçli kullanımda en can
   sıkıcı senaryo.

---

## 1. Bugünkü durum (kanıtlı)

| Alan | Durum |
|---|---|
| Derleme | FPC 3.2.4, Delphi modu, i386-win32 |
| Sayfa motoru | 4 KB slotted sayfa, WAL, sayfa başına CRC32 |
| Katmanlar | SQL → `VDbParser` → `VDbAst` → `VDbExecutor` → `VDbTable` → `IVdbBackend` (`VDbBackendV3`, `VDbBackendV2`) |
| Kapılar | 38/38 (`tests/gates/runall.sh`) |
| SQL testi | 2887 başarılı / 0 hata / 33 atlanan |
| Commit hata enjeksiyonu | 29/29 (`commitfailchk`) |
| Sızıntı | 0 blok (`leakchk`, heaptrc kapısı) |
| v3'te çalışan ek özellikler | `SAVEPOINT`/`ROLLBACK TO`/`RELEASE`, `VACUUM`, `REINDEX`, `VERIFY`, `ALTER DATABASE KEY`, `EXPLAIN`, PITR (`RECOVER TO`), dosya modunda replikasyon (`VDbReplV3`), FTS (`TS_MATCH`), vektör arama (`VECTOR_DISTANCE` + HNSW) |

**Not:** v3 yetenek listesi P-167 ile düzeltildi; `readme_tr.md` artık
yalnız **TCP sunucusunu v3'te** ve `ARCHIVE WAL RESET`'i "yok" olarak
yazıyor; SAVEPOINT, PITR, dosya modu replikasyonu ve `ALTER DATABASE KEY`
kapı referanslarıyla birlikte çalışan özellik olarak listeleniyor
(`VDbExecutor.pas:19494`, `:21062`, `:20799`, `VDbTable.pas:6615`).

---

## 2. Ölçülen performans (200k satır, 2026-11-07)

Tam tablo `hiztesti.md` içinde. Özet, yavaş olan aşamalar:

| Aşama | VDB | SQLite | Oran | VDB birim maliyet |
|---|---:|---:|---|---:|
| 1. Toplu INSERT (tek transaction) | 2155.47 ms | 165.86 ms | 13.00x yavaş | 10.78 µs/satır |
| 6. `SUM(id), AVG(id)` | 297.74 ms | 69.58 ms | 4.28x yavaş | 59.5 ms/sorgu |
| 7. `GROUP BY yas` | 594.54 ms | 259.25 ms | 2.29x yavaş | 118.9 ms/sorgu |
| 8. `ORDER BY bakiye DESC LIMIT 100` | 2308.61 ms | 280.45 ms | 8.23x yavaş | 461.7 ms/sorgu |
| 9. İndekssiz `WHERE yas > 70` | 343.50 ms | 62.71 ms | 5.48x yavaş | 68.7 ms/sorgu |
| 11. Toplu UPDATE (200k satır) | 1524.76 ms | 113.01 ms | 13.49x yavaş | 7.62 µs/satır |
| 13. Toplu DELETE (20k alt küme) | 286.97 ms | 5.08 ms | 56.49x yavaş | 14.77 µs/satır |
| 14. Yeniden açma (open + close) | 312.96 ms | 0.33 ms | 945.51x yavaş | 312.96 ms/açılış |

VDB'nin önde olduğu yerler (korunmalı, regresyon testine alınmalı):

| Aşama | VDB | SQLite | Oran |
|---|---:|---:|---|
| 3. PK nokta SELECT | 44.30 ms | 99.04 ms | 0.45x hızlı |
| 4. Aralık `BETWEEN` COUNT | 60.94 ms | 104.63 ms | 0.58x hızlı |
| 5. Tam tarama `COUNT(*)` | 0.05 ms | 31.15 ms | 0.002x hızlı |
| 10. PK nokta UPDATE (autocommit) | 1030.70 ms | 3610.38 ms | 0.29x hızlı |
| 12. PK nokta DELETE (autocommit) | 857.70 ms | 3604.53 ms | 0.24x hızlı |

Disk: VDB 17.74 MB (88.69 B/satır) / SQLite 10.29 MB (51.43 B/satır) →
**1.72x** daha büyük.

Satır başına maliyetler karşılaştırıldığında ilginç bir tablo çıkıyor:
indekssiz COUNT 0.34 µs/satır, SUM/AVG 0.30 µs/satır, GROUP BY 0.59 µs/satır,
ama ORDER BY 2.3 µs/satır. Yani **sıralama yolu, aynı taramanın ~7 katı**
maliyetle çalışıyor. Bu, P0-3'ün ana ipucudur.

---

## 3. P0 — Hızlandırma maddeleri

### P0-1. Toplu INSERT: ifade başına ayrıştırma + hazırlık maliyeti

**Kanıt.** `sqlitecmp.lpr:206-224` VDB tarafında her satır için **farklı metinli**
bir `INSERT` üretiyor (`InsertSql(i)`, `:198`), SQLite tarafı ise tek
`sqlite3_prepare_v2` + bind kullanıyor (`:487-509`). Ölçüm 10.78 µs/satır.
Başka aşamalarda aynı ham tarama 0.30-0.34 µs/satır olduğuna göre farkın
büyük kısmı depolama değil, **SQL katmanı**.

**Kök neden hipotezi.** Her `Exec` şu zinciri yürütüyor: plan önbelleği anahtarı
(`VDbSql.pas:3190`, SQL metni + parametre sayısı) → ıskalama → `VDbParser` ile
AST kurulumu (onlarca nesne, çok sayıda `string` ayırma) → `TVSqlExecutor` →
satır yazımı. Aynı metin tekrar etmediği için önbellek hiç tutmuyor.

**Öneri (üç kademe, ayrı ayrı ölçülür):**

1. **Ölçümü adilleştir (motor değişikliği yok).** Aynı testi
   `C.Sq.Exec('INSERT INTO musteri (id,ad,yas,bakiye,notu) VALUES (?,?,?,?,?);',
   [IntToStr(i), 'Musteri_...', ...])` biçiminde koş. `ExecFastParamInsert`
   zaten var (`VDbSql.pas`); bu, 13x'in ne kadarının ayrıştırma olduğunu
   tek başına gösterir. Yeni bir `sqlitecmp2` hedefi olarak ekle, eski testi
   silme (tarihsel karşılaştırma kalsın).
2. **Hazır ifade (prepared statement) genel API'si.** Bugün parametre bağlama
   yalnız `TVSql.Exec(Sql, Params)` üzerinden var; tutamaç döndüren bir
   `Prepare`/`Bind`/`Step` API'si yok. İçeride plan zaten önbellekleniyor;
   dışarıya `IVdbStatement` açmak kullanıcıya "her satırda SQL metni kurma"
   alışkanlığını bırakır. (Efor: orta. Risk: düşük — yeni yüzey, mevcut yol
   aynen kalır.)
3. **Literal INSERT için hızlı ayrıştırıcı.** `ExecFastParamInsert`'in
   yaptığını sabit literalli `INSERT ... VALUES (const, const, ...)` için
   yap: AST kurmadan, tek geçişli bir tarayıcıyla kolon/değer çiftlerini
   çöz ve doğrudan satır yaz. Çok satırlı `VALUES (...),(...)` zaten
   destekli (`TSqlInsertStmt.ValuesRows`); hızlı yol onu da kapsamalı.
   (Efor: düşük-orta. Risk: orta — ayrıştırıcı ile aynı dilbilgisini
   tutmak gerekir; kapı testleriyle karşılaştırmalı doğrula.)

**Beklenen kazanç.** Adım 1 yalnız ölçüm; adım 2-3 ile 10.78 µs/satırın
büyük bölümü 2-4 µs bandına inebilir. Hedef: 13x → 3x altı.

**Durum (P-154, 2026-11-08).** 3. kademe yürürlükteydi
(`ExecFastLiteralInsert`), ancak tek cümlelik literal `INSERT` yine de
`ExecRaw` giriş sarmalayıcısını ödüyordu (`SplitStatements`, ikinci
`Default(TSqlResult)`, iz, yavaş-sorgu işaretleri). `TVSql.Exec` artık tek
cümlelik literal `INSERT`'i doğrudan hızlı şeride veriyor; komut sayacı ve
yavaş sorgu halkası (`RecordCommand`/`NoteSlow`) korunuyor. Ölçüm (20k
satır, 3 kolon, aynı oturum, batch içi): 6.39 → 4.7-4.8 µs/satır (≈ %25).
Ayrıştırma: doğrudan `ExecFastLiteralInsert` çağrısı 2.8 µs/satır; kalan
fark kilit, oturum kimliği, yabancı işlem beklemesi ve sayım maliyeti.

**Doğrulama.** `sqlitecmp` aşama 1 + `sqltest` + INSERT odaklı kapı; aynı
oturumda NEW vs HEAD.

---

### P0-2. Toplu UPDATE (13.5x) ve DELETE (56.5x)

**Kanıt.** Aşama 11: 7.62 µs/satır, aşama 13: 14.77 µs/satır. SQLite 0.57 ve
0.26 µs. Nokta UPDATE/DELETE'te VDB **önde** (0.29x / 0.24x); yani sorun
işlem başına sabit maliyet değil, **satır başına sayfa/WAL işi**.

**Kök neden hipotezi.** Tek `UPDATE`/`DELETE` cümlesi 20k-200k satıra
dokunuyor ve her satır için: eski/yeni sayfa imajı, WAL kaydı, birincil
anahtar `.idx` girişi ve tombstone güncellemesi yapılıyor. Toplu DML
ön-okuma penceresi (P-147) var, ama satır başına yazma hâlâ ayrık.

**Öneri (önce profil, sonra tek tek):**

1. **Maliyet ayrıştırması.** Aynı 20k DELETE'i (a) yalnız WAL kapalı,
   (b) yalnız indeks bakımı kapalı, (c) ikisi de açık olarak ölç.
   Hangi bileşenin baskın olduğunu bilmeden optimize etme. (Kısa vadeli
   `DebugXxx` sayaçları; üretimde kapalı.)
2. **Tek geçişli toplu silme.** PK aralığı (`WHERE id BETWEEN a AND b`)
   biliniyorsa sayfaları sırayla gez, tombstone'ları **sayfa başına bir
   kez** işaretle, indeks girişlerini toplu kaldır, WAL'a sayfa başına tek
   kayıt yaz. `TryIndexOrder` benzeri bir "aralık dilimi" yolu burada da
   kullanılabilir.
3. **Ertelenmiş indeks bakımı.** Bir cümle içinde aynı yaprak sayfaya düşen
   indeks güncellemelerini topla; cümle sonunda tek yazma ile uygula.
4. **Grup commit.** Zaten batch içinde çalışılıyorsa satır başına değil,
   cümle sonunda tek `LogFinish`; autocommit'te ise kısa bir "grup commit"
   penceresi (ör. 1-2 ms) düşünülebilir. **Dikkat:** dayanıklılık sözleşmesi
   değişir; varsayılan kapalı, açıkça istenen bir mod olmalı.

**Beklenen kazanç.** DELETE'te hedef 14.77 → 3-5 µs/satır (3-5x iyileşme);
UPDATE'te 7.62 → 2-3 µs. Bu, 56x'lik uçurumun kapanmasa bile 10x bandına
inmesi demek.

**Doğrulama.** `sqlitecmp` aşama 11/13, `commitfailchk` (rollback hâlâ
doğru mu), `VACUUM`/`VERIFY` sonrası tutarlılık.

**Durum (P-155, 2026-11-08).** 1. kademe (maliyet ayrıştırması) tamamlandı;
`VdbDmlProbe` kancasıyla toplu `UPDATE`/`DELETE` ön-okuma ve yazım fazları
ayrıldı (20k satır, 5 kolon). Bulgu: toplu `DELETE`'te satır başına ~3.4 µs
`FT.Delete` içindeki **ikinci `ReadRow`**'du; gerçek yazım (`IdxDelRow` +
`FKvB.Delete`) yalnız ~0.36 µs. `UPDATE` zaten `PreReadVals` kullanıyordu.
`TVTableDb.DeleteKnown` eklendi: `ExecDelete` ön-okumada satırları zaten
materyalize ettiğinden `ReadRow` tekrarı atlanıyor (tam satır koşuluyla,
aksi hâlde eski yola düşer). Ölçüm (aynı oturum, 20k satır): toplu `DELETE`
5.83 → 4.20 µs/satır (≈ %28); ön-okuma fazı değişmedi (41 ms), yazım fazı
49 → 42 ms. Kalan fark kabuk maliyeti (kilit/oturum/sayım ~0.4) + satır
başına yazım.

**Durum (P-156 sonrası, 2026-11-08) — hedef banda inildi.** Aynı oturumda
20k satırda ayrıştırma tamamlandı: SQL toplu `DELETE` 4.18 µs/satır
(ön-okuma 41.1 ms ≈ 2.06 µs/satır, yazım ≈ 2.1 µs/satır); `FT.Delete`
döngüsü 3.80; tek başına `ReadRow` 3.36; `DeleteKnown` (ön-okuma dışarıda,
saf yazım) 2.01. Belgedeki hedef "14.77 → 3-5 µs/satır" bandı yakalandı,
bu yüzden 2.-4. kademeler (tek geçişli silme, ertelenmiş indeks, grup
commit) **şimdilik açılmıyor**: kalan maliyetin yarısı ön-okuma
materyalizasyonu, diğer yarısı satır başına sayfa/WAL işi; ikisini de
kırmak, çok geçişli bir yeniden yazım ve dayanıklılık sözleşmesi
değişikliği gerektirir. Doğrulama: `sqltest` 3289/0 (VACUUM/VERIFY testleri dâhil),
35/35 kapı (`commitfailchk`, `sqlitecmp` dâhil).

---

### P0-3. `ORDER BY ... LIMIT` (8.2x): önce yolu doğrula, sonra satır maliyetini kırp

**Kanıt.** 461.7 ms / 200k satır = **2.3 µs/satır**; aynı tabloda indekssiz
COUNT 0.34 µs/satır. Aradaki 7 kat, ya hızlı yolun devreye girmediğini ya da
giren yolun satır başına ek iş yaptığını gösterir.

**Mevcut hızlı yol.** `TryStreamOrderLimit` (`VDbExecutor.pas:14260`) tek
kolonlu `ORDER BY` + `LIMIT` için var; `LIMIT+OFFSET ≤ 10000` koşulunda
tercih ediliyor (`:15086`). Heap yalnız K kayıt tutuyor, PK string'i yalnız
kabul edilen adaylar için çözülüyor (`:12243`) — tasarım doğru.

**Olası iki neden.**

1. **Sessiz geri düşüş.** `TryStreamOrderLimit` herhangi bir koşulda `False`
   dönerse genel yol tüm 200k satırı string matrisine çevirip sıralıyor.
   Bugün bunu dışarıdan görmenin yolu yok.
2. **Satır başına doğrulama.** `VdbStreamOrderCb` her satırda
   `VDbPeekRawRowKeyHashTo` çağırıyor (`:12168`) ve bu fonksiyon **tüm
   kolonların** anahtar hash'ini yeniden hesaplıyor. Tarama zaten anahtarı
   backend'den alıyor; bu doğrulama güvenlik ağı olarak değerli ama tam
   taramada pahalı.

**Öneri.**

1. **Görünürlük ekle.** `TSqlResult`'a (veya debug alanına) `PlanUsed`
   bilgisi koy: `stream_topn`, `index_order`, `general_sort`. Bir kapı testi
   bu alanı doğrulasın. Bu, hem bu maddeyi hem gelecekteki regresyonları
   çözer.
2. **Güvenli tarama modu.** Tek tablo, kilitlenmemiş, kendi ürettiği anahtar
   için hash doğrulamasını atlayan bir `ScanRawIterAllTrusted` (veya bayrak)
   ekle. Doğrulama yalnız şüpheli yollarda (yabancı/yanlış hizalı sayfa,
   şema anahtarı, paralel işçi) kalsın.
3. **Genel yola düşüşü daralt.** Düşüş nedenini (kolon tipi uyuşmazlığı,
   `RawTree` kurulamaması, `ScanRawIterAll` başarısızlığı) ayrı ayrı raporla
   ve mümkün olanları hızlı yolda çöz.

**Beklenen kazanç.** 2.3 µs/satır → 0.4-0.6 µs/satır; 8.2x → 2x civarı.
Tek başına en büyük tek kazanç bu olabilir.

**Doğrulama.** `sqlitecmp` aşama 8 + sıralama kapıları; `PlanUsed` sayacı
teste bağlanır.

---

### P0-4. Aggregate ve GROUP BY (4.3x / 2.3x)

**Kanıt.** SUM/AVG 0.30 µs/satır, GROUP BY 0.59 µs/satır; SQLite 0.069 ve
0.26 µs/satır. VDB'nin ham akış aggregate yolu (`VdbAggRawCb`,
`VDbExecutor.pas:8708`) zaten satırları matrise çevirmeden çalışıyor; yani
kazanç alanı dar.

**Öneri.**

1. **Tam sayı anahtarlı GROUP BY sözlüğü.** `yas` gibi `VCT_INT` kolonlarda
   anahtarı string'e çevirip `TDictionary<string,...>` kullanmak yerine
   `TDictionary<Int64,...>` (veya sıralı dizi + ikili arama) kullan. GROUP BY
   farkının büyük kısmı burada.
2. **Yerel akümülatör.** SUM/AVG için değeri `string`e çevirmeden `Int64`/
   `Double` ile biriktir; yalnız sonuç satırında metne çevir. (`VdbAggRawCb`
   bunu kısmen yapıyor; tüm kolon tipleri için tutarlı olduğunu doğrula.)
3. **Satır başına hash doğrulamasını kaldır** (P0-3/2 ile ortak iş).

**Beklenen kazanç.** SUM/AVG 4.3x → ~1.5x; GROUP BY 2.3x → ~1.2x.

---

### P0-5. Yeniden açma: 313 ms (hedef < 50 ms)

**Kanıt.** Aşama 14: 312.96 ms / 0.33 ms. Bu, her süreç başlangıcında ödenen
sabit bedel; kısa ömürlü komut satırı araçlarında kullanıcıya "program
donuyor" gibi görünür.

**Kök neden hipotezi.** Açılışta türetilmiş `.idx` (bu testte 2.19 MB)
yükleniyor, tüm sayfaların CRC'si doğrulanıyor, sayaçlar dolduruluyor ve
WAL kurtarma çalışıyor. `V3_YOL_HARITASI.md §7o.3` yenileme (refresh)
bütçesini Checkpoint 801 µs / Heap.Open 125 µs / Recover 88 µs olarak
veriyor; bunlar refresh için, tam açılış için değil — bu yüzden önce
**açılışın kendi profili** çıkarılmalı.

**Öneri.**

1. **Tembel `.idx` yükleme.** Açılışta yalnız başlık + kök özet okunur;
   bölümler ilk erişimde yüklenir. Nokta araması yapan süreç zaten tüm
   indeksi istiyor olabilir; ama şema sorgusu / `EXPLAIN` / tek tablo
   erişimi istemiyordur.
2. **CRC doğrulamasını ertele.** Tam doğrulama `VERIFY` komutuna ve arka
   plan bakımına taşınabilir; açılışta yalnız "son checkpoint LSN'i +
   sayfa sayısı" kontrol edilir. Dayanıklılık sözleşmesi: bozuk sayfa ilk
   erişimde yakalanır (bugünkü gibi erken değil). Bu bir tercih; belgeye
   yazılmalı.
3. **Kalıcı sayaçlar.** `LoadTagCountsFromIdx` (`VDbBackendV3.pas:3300+`)
   zaten `.idx` özetini kullanıyor; `RebuildTagCounts` tam taramasına
   düşülmediğini bir sayaçla doğrula. Düşülüyorsa bu tek başına 100+ ms
   açıklar.
4. **Okuma ön-okuma (read-ahead).** `.odb` ve `.idx` için sıralı ön-okuma;
   Windows'ta `FILE_FLAG_SEQUENTIAL_SCAN` benzeri ipuçları.

**Beklenen kazanç.** 313 ms → 50 ms altı; "ilk sorgu" toplam süresi belirgin
düşer. Ölçüm: aşama 14 + soğuk/sıcak önbellek ayrımı.

**Durum (P-156, 2026-11-08).** Açılışın kendi profili çıkarıldı:
`TVdbPageEngine.Open` artık `VdbOpenProbe` kancasıyla aşama sürelerini
bildiriyor (depo/WAL/kurtarma/heap/finish; nil iken maliyetsiz). Ölçüm
(200k satır, 15.5 MB `.odb` + 2.19 MB `.idx` — belgedeki 313 ms'lik
aşama 14 ile aynı boyutlar, 5 açılış ortalaması):

| Aşama | Süre |
|---|---|
| `Store.OpenEx` (dosya+başlık) | 0.1 ms |
| `Wal.Open` | 0.5 ms |
| Kurtarma + kilit + flush | 0.0 ms |
| `.idx` yükleme (`TryLoadIdx`) | **26-27 ms** |
| Son flush/truncate + kilit bırakma | 0.0 ms |
| Motor `Open` toplamı | ~27.5 ms |
| Backend sarmalayıcı + değişim günlüğü | ~11 ms |
| `TVTableDb.Open` | 0.1 ms |
| **Toplam yeniden açma** | **~39 ms** |

Yani 50 ms hedefi bu ortamda **zaten karşılanıyor**; 313 ms büyük olasılıkla
P-15x öncesi bir duruma ya da `.idx`'in geçersiz sayılıp tam taramaya
düşüldüğü bir koşuya aitti (`IdxUsed=False` yolunda `Heap.Open` tam tarama
yapar; bu, açılışı 10 katına çıkarabilir). Bugünkü baskın kalem `.idx`
yüklemesi (27 ms ≈ 80 MB/s); buradaki CRC doğrulaması ve parça kopyalama
temel darboğaz. Tembel `.idx` yükleme (öneri 1) hâlâ mümkün ama 50 ms
hedefi için gerekli değil; ileride `.idx` büyüdükçe (milyonlarca satır)
öncelik kazanır. Öneri 3'teki `LoadTagCountsFromIdx` doğrulaması: sayaç
yüklemesi bu ölçümde ek tam tarama tetiklemedi. Doğrulama: 35/35 kapı.

---

### P0-6. Zone map ve paralel sorgu v3'te hiç çalışmıyor

**Kanıt.** `VDbExecutor.pas:9129-9138`, `:9181`, `:9200`: bu yollar `FT.Kv`
üzerinden yürüyor; v3'te `Kv = nil`. `TVDbZoneMap` derleniyor ama pratikte
kullanılmıyor. Paralel sorgu/aggregate da aynı nedenle atlanıyor.

**Öneri.**

1. **Zone map'i `IVdbBackend` sözleşmesine taşı.** Sayfa motoru zaten sayfa
   başına min/max özeti tutabilecek yapıda; `ScanRawIterAllPaged` ile
   sayfa atlama yapılabilir. Kazanç: seçici `WHERE` + büyük tablo.
2. **Paralel tarama.** `ScanRawIterAllPaged` sayfa aralıklarına bölünebildiği
   için iş parçacığı havuzu (`VDbParallel`) doğrudan bağlanabilir. Dikkat:
   sıralı sonuç gerektiren sorgularda birleştirme sırası korunmalı; aggregate
   ve `COUNT` için sıra önemsiz.
3. **Eşik koy.** Küçük tabloda iş parçacığı açmak yavaşlatır; sayfa sayısı
   eşiğinin altında seri kal.

**Beklenen kazanç.** Tam tarama aşamalarında (6/7/9) çekirdek sayısına bağlı
1.5-3x; zone map ile seçici sorgularda daha fazlası.

**Durum (2026-11-08) — kısmen tamamlandı (P-158).** Ölçüm, önerinin 1.
maddesinin büyük ölçüde zaten var olduğunu gösterdi: akışlı `SELECT` yolunda
zone map v3'te çalışıyor (`SELECT id FROM musteri WHERE bakiye < 5000`:
ilk tarama 60.2 ms → sonraki 2.6 ms; 3793 sayfanın 3719'u budandı). Eksik
olan, `WHERE`'li `COUNT(*)`/toplamların ham `ScanRawIterAll` ile sayfa
numarası görmeden taramasıydı. P-158 bu yolu `ScanRawIterAllPaged` +
`VdbStreamCountPageCb` üzerine taşıdı ve haritayı `SELECT` ile aynı
sözleşmeyle (aynı `DataStamp`/bucket sayısı, aynı `VdbZoneAddRow` besleme)
kurup yayınlıyor. Ölçüm (`zonechk`, 200 000 satır): `COUNT(*) WHERE
bakiye < 5000` ilk koşu 55.1 ms (harita inşası), sonraki koşular 0.8-1.3 ms,
`zone_pruned_pages = 3719`, sonuç her koşuda 3999.

**P-159 — paralel aggregate (2026-11-08).** Sayfa deposu önbelleği iş
parçacığı güvenli olmadığı ve `ScanRawIterAll` motor kilidini tarama boyunca
tuttuğu için sayfa G/Ç'si paralelleştirilmedi. Bunun yerine v2'deki desen
v3'e taşındı: satırlar motor kilidi altında TEK seri taramada `TVDbRowBuf`
içine kopyalanır (anlık görüntü korunur), ardından işçiler kendi satır
aralıklarında `VdbAggRawCb` ile agregasyonu koşar. Birleştirme sabit işçi
sırasında yapıldığı için sonuç bit-aynı ve deterministik; `SUM`/`AVG`
`VCT_FLOAT` kolonlarda seri yol korunur (bit-ayni sonuç şartı). 128 MB
tampon bütçesi; eşik `VDB_PAR_AGG_MIN_ROWS` (20 000). Ölçüm (`parprof`,
200 000 satır, aynı oturum): `COUNT(*), SUM(yas), AVG(yas), MIN(id),
MAX(id)` 58-61 ms → 36 ms (~1.6x); tüm değerler aynı.

**P-160 — WHERE'li aggregate (2026-11-08).** `GROUP BY`'sız aggregate'ler
`TryStreamAgg`'e gidiyordu ve bu yol `WHERE` kabul etmediğinden sorgu genel
yolda satır başına `EvalBool` ile çözülüyordu. Artık bu şekiller
`TryStreamGroupBy`'ye yönleniyor: tek örtük grup açılır, `WHERE` P-153'ün ham
üç-değerli ağacıyla (`VdbBuildRawTree`/`VdbEvalRawTree`) değerlendirilir
(rvFalse/rvUnknown elenir, rvTrue için satır çözümüne gerek yok); ağaç
kurulamazsa (ifadeli `WHERE`, `OR` dışı özel durumlar) ya da `WHERE` yoksa
genel/paralel yol korunur. Hiç satır eşleşmeyen kümede SQL'in tek satır
döndürme kuralı için boş grup (`COUNT=0`, diğerleri NULL) `VdbGroupStateInit`
ile kurulur. Saf `COUNT(*)` bu yola alınmaz: zone map'li
`TryStreamFilteredCount` ve canlı sayaç yolu (P-158) çok daha hızlı. Ölçüm
(`parprof`, 200 000 satır, aynı oturum, P-160 öncesi ikiliye karşı):
`COUNT(*), SUM(yas) WHERE yas >= 0` 526-555 ms → ~70 ms (~7.6x); `(b)`,
`(c)`, `(f)` değişmedi. Kenar durum denetimi (`p160chk`: boş küme, NULL
kolon, metin eşitliği, `OR`, `IS NULL`, ifadeli `WHERE`, `ORDER BY`/`LIMIT`,
tekrar çalıştırma) 12/12 geçti. Not: `GROUP BY`'sız `HAVING` parser'da hiç
okunmuyor (yalnız `ParseGroupBy` içinde); bu P-160 öncesinden beri böyle ve
ayrı bir iştir. P0-6 bu haliyle kapanmıştır: zone map (P-158), paralel
`WHERE`'siz aggregate (P-159) ve `WHERE`'li aggregate (P-160).

---

### P0-7. Paralel yazma tavanı (~0.8x)

**Kanıt.** `V3_YOL_HARITASI.md §7l.7`: birden çok yazarın 1.0x'in üstüne
çıkması için iki iş tanımlı — (a) sayfa düzeyinde geçerlilik damgası
(`DropCache` yerine), (b) süreçler arası grup fsync (dayanıklı LSN `.gen`
sayfasında).

**Öneri.** Bu iki işi planlandığı gibi uygula; önce (a), çünkü önbellek
düşürmenin yerine geçen damga, okuma tarafını da hızlandırırı. (b) için
`.gen` sayfasına "son dayanıklı LSN" yaz ve tüm yazarlar tek fsync'i
paylaşsın.

**Risk.** (b) dayanıklılık sözleşmesini değiştirir: bir süreç çökerse diğer
yazarların commit'i de etkilenebilir. Tasarım belgesi + `commitfailchk`
genişletmesi şart.

**Durum (2026-11-08) — iki iş de motorda uygulanmış (v3.28–v3.31); kod
değişikliği gerekmedi.** (a) Artımsal tazeleme: `StoreRefreshed` artık
`ViewLsn`'den sonraki çerçeveleri uygular, sayfa imajlarını `InstallPage` ile
yerinde tazeler ve heap dizinini yalnız değişen sayfalar için
`ReindexPages(FWal.AppliedPages)` ile düzeltir; tam `DropCache` yalnız WAL
budanmışsa (değişiklik veri dosyasında) veya `AS OF` kısmi kurtarmada devreye
girer. (b) Süreçler arası grup fsync: `.gen` sayfasındaki durabil LSN
(`FStore.DurableLsn`) başka bir sürecin başarılı fsync'ini görünür kılar;
`AwaitDurable` lider seçmeden önce ve seçtikten sonra bu değeri yeniden
okuyup beklemeyi atlar (`VDbPageEngine.pas:958-1045`). Doğrulama bu oturumda:
`rfchk` (iki backend, aynı dosya, 200 uzak commit) 200/200 doğru değer;
be2'nin okuması tazeleme dahil ortalama **96,5 µs** (min 82, max 231) — uzak
commit maliyeti artık tam tazeleme değil, delta. Tek dosyada 1,0x tavanı
kırılmadı: sınır tazeleme değil, yazar rezervasyonunun sırayla verilmesi
(mimari; SQLite da aynı sınırın altında kalıyor, bkz. `V3_YOL_HARITASI.md`
§7n.3). P0-7 bu haliyle kapanmıştır.

---

### P0-8. Dosya boyu 1.72x

**Kanıt.** 88.69 B/satır / 51.43 B/satır. Satır verisi ~30 B olsa bile sayfa
doluluk oranı ve tombstone alanı farkı açıklıyor.

**Öneri.**

1. **Doluluk hedefi.** Toplu yüklemede sayfaları %100 doldurmak yerine
   (güncelleme için boşluk bırakmak gerekmiyorsa) daha sıkı paketle;
   ölçülen 1.72x'in ne kadarı boşluk, ne kadarı ek alan — `VACUUM`
   sonrası boyutu ölçerek ayır.
2. **VACUUM sonrası kalıcılık.** `VACUUM` sonrası dosya küçülüyor mu,
   küçülüyorsa ne kadar? Bunu `sqlitecmp`'e 15. aşama olarak ekle.
3. **Alan bazlı sıkıştırma (opsiyonel).** Tekrarlayan `ad`/`notu` metinleri
   için sözlük kodlaması; sayfa başına sözlük. Karmaşıklık yüksek, önce
   1-2'yi bitir.

**Durum (2026-11-08) — ölçüldü, ertelemeye karar verildi.** `vacprof`
(200 001 satır): `.odb` 15 540 224 B + `.idx` 2 193 189 B = 88.67 B/satır.
`VACUUM` sonrası dosya **hiç küçülmedi** (15 540 224 → 15 540 224), yani
boşluk/tombstone kaybı yok. Bütçe: yük 60.42 B/satır (min 52, max 72),
hücre+slot ek yükü 16 B, sayfa başlığı ~1.3 B, `.idx` ~10.97 B. Kalan
büyük kalemler biçim değişikliği ister: hücre başlığındaki 12 B
(`Key`+`Len`) ve indeks kaydı başına ~11 B; ucuz (biçim değiştirmeyen)
kazançlar toplamda ≤%6. Bu nedenle P0-8 şimdilik **ertelendi**; yeniden
açılacaksa önce `.idx` kayıt biçimi (sıralı anahtar ön eki) ele alınmalı.

---

### P0-9. Nokta yolunda ~2 µs'lik commit ek maliyeti

**Kanıt.** `V3_YOL_HARITASI.md §7k.6`: `LogFinish` 9.5 µs, `BeginBatch`
~11 µs, `MaybeCheckpoint` 4.6 µs. Nokta UPDATE/DELETE'te VDB yine önde
(0.29x / 0.24x) ama autocommit'te bu sabit maliyet satır başına ödeniyor.

**Öneri.**

1. `MaybeCheckpoint`'i "parti açıkken bir kez" kuralına bağla (zaten
   öyleyse doğrula; değilse düzelt).
2. `BeginBatch` içinde gereksiz kilit/sayaç işlerini ilk yazmaya ertele.
3. `LogFinish`'te tampon boşsa erken çık.

**Beklenen kazanç.** Nokta işlemlerde %10-20; ölçüm aşama 10/12.

**Durum (2026-11-08) — üç öneri de kodda zaten karşılanmış; ucuz kazanç yok.**
(1) `MaybeCheckpoint` yalnız `Wal.Bytes` eşiğini okur, checkpoint yalnız eşik
aşılınca yapılır. (2) `BeginBatch` rezervasyonu beklemeden dener; alınırsa
seri yol aynen işler, alınamazsa iyimser moda geçip commit'te çakışma
denetler — kilit/sayaç işi ilk yazıya ertelenmiş durumda. (3) `LogFinish`
grup açık değilse (`FLogInGroup=False`) hemen döner. Ölçülen güncel nokta
maliyeti `rwbench` NOKTA **2,90 µs/sorgu** (V3_YOL §7o.2); kalan %12-14'lük
fark fsync/kilit mimarisinden geliyor, satır düzeyinde kırpılabilir bir kalem
yok.

---

### P0-10. Sonuç tipi: her şey `string` (uzun vadeli)

**Kanıt.** `TSqlResult.Rows: TStrMatrix`; okuma yolları sayıları bile metne
çeviriyor. Bu, SQLite'ın yerel `int64`/`double` satır biçimine karşı yapısal
bir dezavantaj ve tüm tarama aşamalarındaki farkın bir parçası.

**Öneri.** Salt-okunur yollar için paralel bir tipli sonuç API'si
(`TRowValues` = variant/union dizisi) ekle; mevcut `Rows` geriye dönük
uyumluluk için kalsın. Büyük refactor; P0-3/4 bittikten sonra değerlendir.

**P-162 — ara `vals` dizisi kaldırıldı (2026-11-08).** Ölçüm, `SELECT` sonucu
metin matrisine malzemelemenin SQLite'ın aynı işinden yavaş olduğunu
doğruladı (200 000 satır, aynı oturum): 1 kolon **385-404 ns/satır**,
3 kolon 500-533, 5 kolon 696-716; SQLite `SELECT k` → `fetchall()` 211,6,
`SELECT k,v` 336,8 ns/satır. Ham `ScanRawIterAll` geri çağrısı ise aynı
tabloda 81 ns/satır olduğundan farkın büyük kısmı hücre çözme + string
ayırma. İlk adımda (`TryStreamSelect`) satır başına ayrılan ara `vals`
dizisi gereksiz yerlerde kaldırıldı: WHERE yoksa ya da ham üç-değerli ağaç
`rvTrue` dediyse (bu durumlarda `RowMatches` zaten koşmuyordu) değerler
`VDbColFromOffsetsP` ile **doğrudan çıktı satırına** çözülüyor. Aynı oturum,
aynı ikili karşılaştırması: 1 kolon 385-404 → **301-317** (≈%21), 3 kolon
500-533 → 434-454 (≈%13), WHERE'li 1 kolon 493-528 → 387-437 (≈%19),
WHERE'li 3 kolon 560-578 → 510-533 (≈%8); `SELECT *` (DirectDecode) yolu
değişmedi. Doğrulama: `selchk` 11/11 (NULL, tekrarli kolon, alias,
LIMIT/OFFSET, OR, seçili olmayan kolonda WHERE, UTF-8, `SELECT *`), kapılar
35/35. Buradan, kalan farkın hücre başına string ayırma + sayı→metin
dönüşümü olduğu varsayılmıştı; P-163 bunu doğrudan ölçtü.

**P-163 — tipli sonuç kanalı `ExecTyped` (2026-11-08).** P0-10'un ilk
halkası: `TSqlResult.TypedRows: TVdbCellMatrix` (hücre = `Kind` + `I`/`F`/`S`)
ve `TVSql.ExecTyped`. `Rows` metin matrisi geriye dönük uyumluluk için
aynen durur. Akışlı `SELECT` hızlı yolu tipli istekte hücreleri **doğrudan
ham yükten** yazar (`VDbColToCellP`); WHERE'li basit kolonlarda da ara
metne dönüş yoktur. İfade/aggregate gibi metin üreten yollar `FieldTypes`
ile hücreye çevrilir (bu alan `point_select`, `stream_agg` ve `SELECT *`
genel yolunda da dolduruldu). İç tüketiciler (`RowMatches`, alt sorgular,
tetikleyiciler) metin yoluyla çalışmaya devam eder; tipli mod yalnız en dış
`Execute` çağrısında etkindir.

Ölçüm (200 000 satır, aynı oturum, `Exec` vs `ExecTyped`, en iyi 3 tur):
1 kolon 60-62 ms / 61-64 ms (fark %0-6, çoğunlukla ~%3), 3 kolon
88-92 ms / 92-95 ms (%3-5), 5 kolon 131-133 ms / 131-144 ms (%0-9),
`WHERE`'li 2 kolon 90-94 ms / 96-104 ms (%3-11). Yani tipli kanal
**hız kazancı sağlamıyor**: dönüşüm
maliyeti sanıldığı kadar büyük değil, buna karşılık `TVdbCell` matrisi
(32 bayt/hücre) metin matrisinden daha fazla bellek trafiği üretiyor.
P0-10'un gerekçesindeki "%1,4-1,8x fark metin malzemelemeden" varsayımı
bu ölçümle **çürütüldü**; kalan fark hücre çözme + hash tarafındadır.
Tipli kanal yine de değerlidir (ağ/pgwire ve gömülü tüketiciler için
yeniden ayrıştırma yok) ve isteğe bağlıdır — varsayılan `Exec` yolu
değişmedi, dolayısıyla mevcut kullanıcılar için regresyon yoktur.

Doğrulama: `typedchk` 12/12 (`stream_select`, `point_select`, genel,
`stream_agg`; NULL, UTF-8, float, `SELECT *`), `selchk` 11/11, kapılar
35/35. Not: `VDbCellFromStr` ondalık ayırıcıyı açıkça `.` verir (motor
float'ı her locale'de noktayla yazar). Kalan P0-10 işi: tüm yollarda
tipli sonuç (aggregate/ifade), kolon-dizili (columnar) hücre yerleşimi
ve pgwire entegrasyonu.

---

## 4. P1 — Doğruluk ve dayanıklılık

### P1-1. Global `.gen` yüzünden yanlış abort (KAPANDI — P-164)

**Sorun.** İyimser işlem (`BeginBatch` yazar rezervasyonunu alamadığında),
okuduğu her anahtarın `.gen` damgasını **global** sayaçla karşılaştırıyordu;
başka bir süreç **ilgisiz** bir tabloya commit etse bile açık parti abort
ediliyordu.

**Çözüm.** `.gen` dosyasının sonuna 4096 QWord'lük **tablo kapsamlı** sayaç
bölgesi eklendi (`VDB_GEN_SCOPE_OFF = 24`, yuva = tablo kimliği `and 4095`).
Eski 24 baytlık önek aynen korunur; eski dosyalar açılışta
`EnsureScopeArea` ile büyütülüp sıfırlanır. Commit (`ApplyBatch`) **önce
global** sayacı, **sonra** değiştirdiği tabloların kapsam sayaçlarını artırır
(`BumpCommitGen`). Nokta okuması kapsamı değerin satır etiketinden (tablo
kimliği) çıkarır: değer okunduktan sonra global sayaç, okuma öncesi örnekle
aynıysa kapsamlı damga güvenlidir (`ObservePointRead`); değiştiyse global
damgaya düşer. Taramada kapsam ilk taramanın tablosuna bağlanır; farklı
tablo, etiketi çözülemeyen satır (`FRowTag < 0`) veya kapsam bölgesi olmayan
dosya (salt-okunur açılış) durumunda eski **global** eşik kullanılır — her
belirsizlik daha temkinli davranışa düşer, veri kaybı yönü yoktur. Anahtar
karma çakışması (iki tablo aynı yuvaya düşerse) yalnız fazladan abort üretir.

**Doğrulama.** `prochk` iki yeni çok süreçli senaryo kazandı: (1) "H" süreci
yazar rezervasyonunu tutar, "R" iyimser moda düşer, tablo 7'den okur, H
tablo 8'e commit eder, R sonra tablo 7'ye commit eder — eski kodda R abort
ediyordu, şimdi **iki commit de geçiyor**; (2) aynı anahtar: R okur, H aynı
anahtara commit eder, R'nin commit'i hâlâ **abort** ediyor (veri kaybı yok).
Ölçüm (`p67diag`, 100 000 satır, aynı oturum): döngü+commit 132,6 → 128,1 ms
(gürültü sınırında, gerileme yok). Kapılar 35/35.

**Uyumluluk notu.** Kapsam sayaçlarını yalnız bu sürüm ilerletir. P1-1
öncesi bir ikili (24 baytlık `.gen`) ile **aynı veritabanına eşzamanlı**
yazılırsa eski ikili kapsam sayacını artırmaz; karışık sürüm eşzamanlı
yazımı desteklenen bir senaryo değildir (tek sürüm çalıştırın).

### P1-2. Unix paritesi (KAPANDI — CI, P-76)

`.github/workflows/ci.yml` zaten **linux-test** ve **macos-test** işlerini
içeriyor (P-76, 2026-11-02): her ikisi de FPC 3.2.2 kurup
`tests/gates/runall.sh` ile **aynı 36 kapıyı** (sqltest dahil) koşar; düşen
kapının günlüğü ek açıklamada yayınlanır. Yani `.gen`/`flock`/atomik
`rename`/fsync davranışı Windows ile aynı kapı tablosu üzerinden Unix'te de
doğrulanıyor. Yerel makinede Linux koşusu yapılamaz; doğrulama CI'a aittir.
Risk tablosundaki "Linux CI yok" notu bu maddede güncelliğini yitirmiştir.

### P1-3. fsync hata enjeksiyonu ve dayanıklılık (KAPANDI — P-166)

**Mevcut taban.** `commitfailchk` grup/tek commit fsync hatasını, WAL geri
kırpmasını ve `FWrittenLsn` monotonluğunu; `crashtest` kill -9, kesik WAL
kuyruğu, bozuk WAL kaydı, torn page (WAL replay onarımı), küçük havuz
baskısını; `storechk` sayfa deposu CRC'sini; `pitrchk` PITR'i doğruluyor.

**Bulunan ve kapatılan kusur (P-166).** fsync hatasıyla **başarısız**
bildirilen bir commit, WAL geri kırpıldıktan sonra motorun belleğinde kirli
sayfa olarak kalıyordu; kapanış/checkpoint bunları veri dosyasına yazınca
istemciye "başarısız" denilen commit **kalıcı** oluyordu (hayalet commit).
Ölçüm: `soakchk` bunu kırmızı yakaladı (fsync hatasından sonra anahtar
yeniden açılışta vardı).

**Çözüm.** `TVdbPageStore.DiscardView` (kirli dahil tüm çerçeveleri atar,
meta sayfayı diskteki durabil imajdan yeniden yükler) +
`TVdbPageEngine.RecoverAfterDurabilityFailure` (WAL'de kalan durabil
kayıtları yeniden uygular, heap dizinini durabil görünümden kurar).
`CommitBatch` durabilite hatasında `FEngCs` altında bu kurtarmayı çağırır;
kurtarma hatası asıl hata metnine eklenir, maskelenmez.

**Yeni kapı.** `soakchk` (P1-3): 16 tur × 300 karışık yazma/silme, tur
başına 40 örnek okuma, her 4 turda kapanıp açma + **tüm** anahtarların
bellek modeliyle birebir karşılaştırılması, sonunda fsync hatası ve
hayalet-commit kontrolü. `commitfailchk` ayrıca "başarısız commit kalıcı
DEĞİL" ve "önceki başarılı commit kalıcı" assert'lerini kazandı. Kapı
`runall.sh` + `ci.yml` + `soakchk.lpi` olarak kaydedildi.

### P1-4. `FExclusiveAccess` uyarısı (KAPANDI — P-165)

**Sorun.** Süreçler arası özel erişim bayrağı (tek süreç varsayımı) açık
unutulursa kilit syscall'ları atlanır ve çok süreçli koruma **sessizce**
kaybolur.

**Çözüm.** v3 `SHOW STATS` çıktısına iki satır eklendi:
`exclusive_access = True|False` her zaman görünür; bayrak açıkken ek bir
`warning` satırı ("exclusive_access acik: surecler arasi kilitler atlaniyor"),
kapalıyken boş `warning` satırı. Satır sayısı v3'te 13 → 15 oldu.

**Doğrulama.** `v3sqlchk` iki yeni assert ekledi (`SHOW STATS` içinde
`exclusive_access` ve `warning` satırları); `sqltest` v3 satır-sayısı
beklentisi 15'e güncellendi. Kapılar 35/35.

### P1-5. İki savepoint yolu (KAPANDI — P-165)

**Sorun.** `admSavepoint`/`admReleaseSavepoint`/`admRollbackToSavepoint`
dallarında v3'te (`FT.Kv = nil`) erken `ecUnsupported` fırlatılıyordu; ayrıca
`FT.Kv` üzerinden giden eski yol v3'te erişilemiyordu.

**Çözüm.** Erken red bloğu kaldırıldı; üç admin dalı da tek uygulamaya,
`TVTableDb.Savepoint/RollbackToSavepoint/ReleaseSavepoint`'e delege edildi.
Bu yöntemler `FKvB` (v3 backend) üzerinden çalıştığı için v2 ve v3 aynı
kodu kullanır.

**Doğrulama.** `v3sqlchk` yeni `TestSavepoint`: `SAVEPOINT s1` → iki ekleme
+ bir güncelleme → `ROLLBACK TO s1` (2 satır, eski değer) → `SAVEPOINT s2` →
`RELEASE s2` → `COMMIT` (3 satır). 247/247.

---

## 5. P2 — Özellik ve ekosistem

| # | Özellik | Not |
|---|---|---|
| P2-1 | **TCP sunucusunda v3** | AÇIK. `readme_tr.md` "yok" yazıyor; `REPLICATION ... TCP` reddediliyor (`VDbExecutor.pas:20799`). Dosya modu replikasyon çalışıyor. v3 için akış katmanı gerekir. |
| P2-2 | **pgwire / PostgreSQL protokolü** | VAR (minimal). `VDbPgWire.pas` (`TVdbPgServer`) basit + genişletilmiş sorgu protokolü, `COPY ... STDIN`, TLS ve SQLSTATE eşlemesini uygular; `sqltest` T116_PgWire kapısı ve `dokuman/usage.md` örneği var. Eksikler: hazır çalıştırılabilir sunucu, parola/`trust` dışı kimlik doğrulama, zengin binary tipler. |
| P2-3 | **Arrow / Parquet dışa aktarım** | ZATEN VAR. `COPY ... TO ... FORMAT ARROW` / `FORMAT PARQUET` ve içe aktarma `VDbArrow.pas` + `VDbParquet.pas` ile çalışıyor (dış bağımlılık yok). |
| P2-4 | **JSON yol fonksiyonları** | ZATEN VAR. `JSON_EXTRACT`, `JSON_VALUE`, `JSON_EXISTS` (`VDbExecutor.pas:2500`). |
| P2-5 | **Çevrim içi/tamamlayıcı yedek** | KISMEN. `BACKUP TO` (çevrim içi kopya) var; LSN tabanlı **artımlı** yedek ve yedekten doğrulama yok. |
| P2-6 | **`EXPLAIN ANALYZE`** | ZATEN VAR. Parser `EXPLAIN [ANALYZE]` kabul eder (`VDbParser.pas:5066`), yürütücü plan + gerçek satır/plan bilgisini üretir. |
| P2-7 | **Sorgu zaman aşımı / iptal** | AÇIK. Yalnız yazar kilidi için `BusyTimeoutMs` var; uzun sorguyu durduran iptal bayrağı/zaman aşımı yok. |
| P2-8 | **FTS ve vektörün SQL yüzeyini genişletme** | KISMEN. BM25 (`VDbText.pas`) ve `VECTOR_DISTANCE` çalışıyor; hibrit (BM25 + vektör) sıralama ve indeks yeniden inşası ergonomisi yok. |

---

## 6. P3 — Test ve altyapı

1. **heaptrc kapısı.** KAPANDI — P-168. `tests/gates/leakchk.lpr` küçük ama
   tipik bir yazma/okuma döngüsünü tamamen serbest bırakır; `runall.sh`
   içindeki `derlegh()` onu `-gh` ile derler ve çıktıda hem
   "SIZINTI KAPISI DOGRULANDI" hem "0 unfreed memory blocks" arar. Aynı
   kontrol Windows CI'da ayrı bir adım olarak koşar.
2. **Linux CI.** KAPANDI (P-76). CI'da `linux-test`/`macos-test` işleri
   `runall.sh`'i baştan sona koşar; Windows'ta her kapı ayrı adımdır.
   Kapı sayısı bugün 38'dir.
3. **A/B performans koşum takımı.** KAPANDI — P-169. `tests/bench/ab.sh`
   BASE ve NEW ikililerini aynı oturumda sırayla (interleave) koşar, her
   turu benzersiz alt dizine yazar, son `en_iyi=` değerlerinin medyanını
   alır ve ±%2 eşiğiyle `REGRESYON` / `IYILESME` / `ESIT` yargısı verir;
   regresyonda çıkış kodu 1'dir. `rm -rf` kullanmaz.
   Kullanım: `ab.sh <base-exe> <new-exe> <dizin> [tur] [desen]`.
4. **Ayrıştırıcı fuzz testi.** KAPANDI — P-170. `tests/gates/parserchk.lpr`
   deterministik tohumla (a) 20 geçerli SQL'lik corpus'u, (b) 60 rastgele
   token dizisini, (c) 1500 geçerli-SQL mutasyonunu ve (d) 5000 katlı
   parantez içeren girdiyi ayrıştırır. Her girdiden sonra parser'ın hâlâ
   kullanılabilir olduğu ayrıca doğrulanır; çökme yok, 16 ms sürer.
5. **Çok süreçli çakışma matrisi.** KAPANDI — P1-1/P-164 ile birlikte.
   `prochk` iki ayrı işlemin aynı dosyaya eşzamanlı yazıp ikisinin de
   commit ettiğini, kapanış checkpoint'inin bayat sayfa yazmadığını ve
   tablo kapsamlı nesil damgalarının yanlış abort üretmediğini sınar;
   `xprocc` ve `lockchk` okuma/yazma pencerelerini kapsar.
6. **Karşılaştırma testinin adil sürümü.** AÇIK — dış bağımlılık.
   `sqlitecmp2`'nin parametreli sürümü yerelde `sqlite3` kurulu olmadığı
   için koşulamıyor; betik ayrı bir iş olarak bekliyor (kapı değildir).

---

## 7. Dokümantasyon borcu

| Dosya | Sorun | Yapılacak |
|---|---|---|
| `readme_tr.md:28-31` | v3'te çalışan SAVEPOINT, PITR, replikasyon, ALTER DATABASE KEY "yok" diye yazıyordu | KAPANDI (P-167): yalnız TCP sunucusu ve `ARCHIVE WAL RESET` "yok"; diğerleri kapı referansıyla listelendi |
| `readme.md` (İngilizce eş) | Aynı bayat liste | KAPANDI (P-167): Türkçe sürümle senkronlandı |
| `hiztesti.md` | 2026-11-07 ölçümü; P0 maddeleri uygulandıkça eskiyecek | Her P0 sonrası yeni ölçüm bölümü ekle, eskisini silme (tarih damgası) |
| `V3_YOL_HARITASI.md` | §7k/§7l/§7o maddeleri bu belgeyle çakışıyor | Bu belgeye yönlendirme; tamamlananları "yapıldı" işaretle |
| `vdb_kapsamli_yol_haritasi.md` | v2 append-only mimarisi için yazılmış | "Tarihsel" başlığı ekle veya arşivle |
| `DERINLEMESINE_INCELEME_2.md` | EK-X kapandı; EK-S/T/U/V/W açık riskler sürüyor | P1 maddeleriyle eşleştir |

---

## 8. Öncelik tablosu

| ID | İş | Etki | Efor | Risk | Sıra |
|---|---|---|---|---|---|
| P0-3 | ORDER BY hızlı yolunu doğrula + güvenli tarama | Çok yüksek (8.2x) | Düşük-orta | Düşük | 1 |
| P0-1 | INSERT hazır ifade + literal hızlı yol | Yüksek (13x) | Orta | Orta | 2 |
| P0-2 | Toplu UPDATE/DELETE tek geçiş | Çok yüksek (56x) | Orta-yüksek | Orta | 3 |
| P0-5 | Açılış 313 ms | Yüksek (görünürlük) | Orta | Orta | 4 |
| P0-4 | Aggregate/GROUP BY tipli akümülatör | Orta-yüksek | Düşük-orta | Düşük | 5 |
| P0-6 | Zone map + paralel tarama | Yüksek (büyük tablo) | Yüksek | Orta-yüksek | 6 |
| P0-9 | Nokta commit maliyeti | Orta (%10-20) | Düşük | Düşük | 7 |
| P1-1 | Global `.gen` yanlış abort | Doğruluk | Yüksek | Yüksek | kapandı (P-164) |
| P0-7 | Paralel yazma tavanı | Yüksek (çok yazar) | Yüksek | Yüksek | 9 |
| P0-8 | Dosya boyu | Orta | Orta | Düşük | 10 |
| P1-4, P1-5 | Görünürlük/savepoint temizliği | Orta | Düşük | Düşük | kapandı (P-165) |
| P1-2 | Unix paritesi | Orta | Orta | Düşük | kapandı (CI, P-76) |
| P1-3 | fsync dayanıklılığı | Orta | Orta | Düşük | kapandı (P-166) |
| P3-1..P3-5 | Test altyapısı | Dolaylı | Orta | Düşük | kapandı (P-168, P-169, P-170) |
| P3-6 | Adil sqlite karşılaştırması | Dolaylı | Orta | Düşük | açık (sqlite3 gerekli) |
| P0-10 | Tipli sonuç API'si | Düşük (P-163 ölçümü: hız kazancı yok) | Orta (columnar/pgwire) | Yüksek | sonra |
| P2-* | Ekosistem | Stratejik | Yüksek | Orta | sonra |

**Uygulama durumu (2026-11-08):** P0-1 (P-154), P0-2 (P-155, hedef banda
indi), P0-3 (P-152), P0-4 (P-153), P0-5 (P-156, ölçüldü; 50 ms hedefi
zaten karşılanıyor) ve P0-6'nın `WHERE`'li `COUNT` ayağı (P-158) tamamlandı.
P0-8 ölçüldü ve ertelendi (`VACUUM` kazancı 0; kalan kalemler biçim
değişikliği). P0-6 tamamen kapandı: paralel aggregate (P-159, `WHERE`'siz
karma agregalar ~1.6x) ve `WHERE`'li aggregate (P-160, örtük tek grup + ham
üç-değerli WHERE ağacı, ~7.6x). P0-7'nin iki önerisi de motorda zaten
uygulanmış (artımsal tazeleme + süreçler arası grup fsync; `rfchk` ile
doğrulandı) ve P0-9'un üç önerisi kodda karşılanmış (ucuz kazanç yok).
P0-10'a giden ilk adım P-162: alt-küme `SELECT`'te ara `vals` dizisi
kaldırıldı (1 kolon ~%21, 3 kolon ~%13 aynı oturum). P-163 tipli sonuç
kanalını (`ExecTyped`) ekledi ve P0-10'un hız gerekçesini ölçümle çürüttü:
tipli kanal 1 kolonda eşit, çok kolonda %5-9 daha yavaş (hücre matrisi
bellek trafiği); kalan fark hücre çözme + hash tarafındadır. P-164 P1-1'i
kapattı: `.gen` dosyasına tablo kapsamlı sayaç bölgesi eklendi, iyimser
commit artık yalnız okuduğu tablonun sayacına bakıyor; ilgisiz tabloya
yapılan commit yanlış abort üretmiyor (`prochk` iki yeni çok süreçli
senaryo, kapılar 35/35, `p67diag` gerilemesi yok). P-165 P1-4 ve P1-5'i
kapattı: özel erişim bayrağı `SHOW STATS`'ta görünür, savepoint'ler tek
uygulamaya (v2/v3 `FKvB`) indirildi ve kapı testiyle doğrulandı. P-166
fsync hatasında hayalet commit'i düzeltti ve `soakchk` kapısını ekledi;
P1-2 (Unix paritesi) ise P-76'dan beri CI'da koşan Linux/macOS işleriyle
karşılanıyor. P-167 readme'deki v3 yetenek listesini düzeltti. P-168
heaptrc sızıntı kapısını (`leakchk`), P-169 standart A/B koşum takımını
(`tests/bench/ab.sh`, ±%2 eşik), P-170 ayrıştırıcı fuzz kapısını
(`parserchk`) ekledi; kapılar 38/38. Açık kalanlar: P0-10'un
columnar/pgwire ayağı, P2 özellikleri ve P3-6 (dış `sqlite3`
bağımlılığı).

---

## 9. Önerilen uygulama sırası

**Sprint A — Ölçüm dürüstlüğü (1-2 gün).**
`PlanUsed` alanı + sayaç, `sqlitecmp2` (parametreli), A/B betiğinin
standartlaşması. Bu sprint kod hızlandırmaz; sonraki her adımın doğru
ölçülmesini sağlar.

**Sprint B — Nokta atışı kazançlar.**
P0-3 (güvenli tarama + düşüş nedenleri), P0-4 (tipli akümülatör, int
sözlük), P0-9 (commit kırpma). Hepsi dar kapsamlı, kapı testleriyle
doğrulanabilir.

**Sprint C — Toplu yazma.**
P0-1 (hazır ifade + literal hızlı yol), ardından P0-2 (toplu silme/güncelleme
tek geçiş). En büyük oran iyileşmesi burada.

**Sprint D — Açılış.**
P0-5; ölçüm önce, sonra tembel `.idx` ve CRC erteleme.

**Sprint E — Ölçek.**
P0-6 (zone map + paralel tarama), P0-7 (paralel yazma), P0-8 (dosya boyu).

**Sprint F — Doğruluk.**
P1-1..P1-5 tamamlandı; her biri kendi kapı testiyle
(`prochk`, `v3sqlchk`, `commitfailchk`, `soakchk`, CI matrisi).

---

## 10. Bilinen ve kabul edilen sınırlar

Bunlar hata değil, bilinçli tasarım tercihleri; belgede açıkça yazılmalı:

* **4 KB sayfa** — daha büyük sayfa daha iyi sıralı okuma verir ama mevcut
  biçim ve kapılar buna göre kurulu; değişiklik büyük bir sürüm işi.
* **Dosya küçülmesi yalnız `VACUUM` ile** — silme sonrası boşluk yerinde
  kalır.
* **Global nesil ile iyimser eşzamanlılık** — yanlış abort olasılığı kabul
  edilmiş (P1-1 bunu daraltmayı öneriyor).
* **v3'te paralel aggregate var (P-159), paralel sayfa G/Ç'si yok**; zone
  map `SELECT` ve `WHERE`'li `COUNT`'ta çalışıyor; `WHERE`'li aggregate'ler
  tek örtük grupta ham ağaçla çözülüyor (P-160).
* **Windows öncelikli** — yerel geliştirme Windows'ta; Unix/macOS paritesi CI'da koşar (P1-2, P-76).
* **TCP sunucusu v3'te yok** — yalnız dosya modu replikasyon.
* **Sonuçlar varsayılan olarak metin matrisi** — isteğe bağlı tipli kanal
  `ExecTyped` var (P-163); aggregate/ifade yolları hâlâ metinden çevrilir,
  columnar yerleşim ve pgwire entegrasyonu yok (P0-10).

---

## 11. Ölçüm disiplini (her madde için zorunlu)

1. **Güvenilir araç:** `p67diag` (VDB sayfa motoru için); `benchcmp` gürültülü,
   tek başına karar verdirmesin.
2. **Aynı oturumda NEW vs HEAD.** Farklı gün/oturum ölçümleri karşılaştırılmaz.
3. **Argümansız bench koşusu yok.** Her koşu dizin/hedef argümanı alır.
4. **%2 ve üzeri regresyon aynı oturumda geri alınır** veya gerekçesiyle
   belgelenir.
5. **Üç tur medyan**, ilk tur ısınma; yayılım (maks-min) raporlanır.
6. **Doğruluk önce:** hız ölçümünden önce `sqltest` + ilgili kapı yeşil
   olmalı. Hızlandırma hiçbir zaman sonuç kümesini değiştirmemeli; değişen
   sonuç varsa iş geri alınır.

---

## 12. Tek cümlelik sonuç

VDB v3 nokta işlemlerde, sayaçlarda ve autocommit tek satır yazmalarında
SQLite'tan hızlı; zone map (P-158), paralel `WHERE`'siz aggregate (P-159),
`WHERE`'li aggregate (P-160), artımsal tazeleme ve süreçler arası grup fsync
(P0-7) artık v3'te çalışıyor. `SELECT` sonucunda kalan fark metin
malzemelemede değil hücre çözme + hash tarafındadır (P-162 ara diziyi
kaldırdı; P-163 tipli kanalı ekledi ve hız kazancı olmadığını ölçtü —
SQLite'ın aynı işinden 1,4-1,8x yavaşlık tipli API ile kapanmıyor). Tek dosyada paralel
yazmada 1,0x tavanı mimari sınırdır; doğruluk borcu artık denetim
kuyruklarındadır (P-185 ağ/güvenlik; SQL semantiği P-183, depolama
P-184 ile kapandı).
