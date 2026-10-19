# VDB — Hız ve Modernleşme Yol Haritası

**Tarih:** 2026-10-18
**Temel:** Kaynak kod tam taraması — `VDbCore.pas`, `VDbTable.pas`, `VDbExecutor.pas`, `VDbParser.pas`, `VDbAst.pas`, `VDbCost.pas`, `VDbXPrims.pas`
**Girdi dokümanlar:** `PERFORMANS_YOL_HARITASI.md`, `HIZLANDIRMA_TAKIP.md`, `yol_haritasi_hiz.md`, `vdb_analiz_raporu.md`, `CHANGELOG.md`
**Hedef:** VDB'yi bulk iş yüklerinde SQLite'a yaklaştırmak/geçmek **ve** ekosistem/modern kullanım açısından güncel bir motora dönüştürmek.

> [!IMPORTANT]
> Bu belge **yeni bir motor yazmayı önermez**. Mevcut, test edilmiş çekirdeği korur.
> KR-9 (format v2 / satır sıkıştırma) ve WAL+B-tree tam geçişi burada **kapsam dışıdır**
> (gerekçeleri §5). Her madde ayrı commit, ayrı benchmark; doğruluk testleri geçmeden
> sonraki adıma geçilmez.

---

## 0. Mevcut Durum — Nerede İyiyiz, Nerede Değiliz

Zaten kazanılmış (dokunma, koru):

- PK nokta araması SQLite'ın **2,1x önünde** (hash O(1)) — `0,47x` oran.
- `COUNT(*)` O(1) (KR-1B doğrulanmış-sonuç önbelleği).
- WHERE'siz agrega (`SUM/AVG/MIN/MAX`) allocation-free raw-peek (`ScanRawIter`, KR-8/8c).
- Yazma yolunda tahsis diyeti, batch COMMIT tamponu (P-21), konumsal okuma (P-19).
- Çökme dayanıklılığı: `sqltest 2462/2462`, `crashtest 8/8`.

Hâlâ yavaş (bu belgenin hedefi):

| Aşama (1M satır) | VDB/SQLite | Kök neden (koddan) |
|---|---|---|
| `INSERT` | ~7,7x | satır başına bağımsız KV kaydı + başlık + per-record CRC + FNV anahtar |
| `UPDATE` / `DELETE` | ~15x | UPDATE = yeni kayıt + tombstone; indeks pending-op + flush |
| `COUNT/SUM` (filtreli) | 8–19x | filtreli yol satırları `TStrMatrix`'e maddeliyor, string karşılaştırma |
| `BETWEEN` / `RANGE` | ~15x | sıralı dizi indeks: tembel **tam** rebuild + O(n) kaydırmalı ekleme |
| İndekssiz eşitlik JOIN | yok | sol-derin **iç içe döngü**, hash join yok |

---

## 1. Kök Neden Analizi (koddan doğrulanmış)

### KR-A — Satır yürütümü string tabanlı
`ExecJoinScan` ve filtrelenmiş taramalar satırları `TStrMatrix` (string matrisi) olarak
maddeliyor (`VDbExecutor.pas:4653-4682`, `rRows: TStrMatrix; FT.ScanRows(...)`).
Karşılaştırma `VDbCmpVal` ile string üzerinden.
WHERE'siz agrega için raw-peek hızlı yolu var; **filtre/projeksiyon/join hâlâ string**.
→ Filtreli okuma iş yüklerindeki farkın ana kaynağı.

### KR-B — Join hash tablosu yok
Eşitlik join'inde join kolonu indeksliyse/PK ise nokta-lookup hızlı yolu var
(`VDbExecutor.pas:4824`); aksi halde `for i ... for j ...` → **O(N×M)**
(`VDbExecutor.pas:4653-4682`). Hash join ve bloom/semi-join pushdown yok.

### KR-C — İndeks sıralı dizi
`FMemIdx: TDictionary<Int64, TIdxEntries>` + `SortIdxEntries` + binary search
(`VDbTable.pas:104-122`, `2162`). Nokta aramada hash O(1) (SQLite'ı geçiyor);
ama aralık için tembel **tam** yeniden kurulum + O(n) kaydırmalı ekleme. B-tree/ART yok.

### KR-D — Yazma yolu per-record maliyeti
Satır başına başlık + CRC + FNV anahtar; UPDATE yeni kayıt + tombstone; indeks
pending-op + delta merge. Format değişmeden kazanılabilir alan: blok-grup CRC,
tombstone/update birleştirme, mmap ile kopya azaltma.

---

## 2. HIZ FİKİRLERİ (H)

### H1 — Vektörleştirilmiş (batch) yürütüm
**Sorun:** KR-A. Filtreli SELECT/WHERE her satırı string'e çeviriyor.
**Çözüm:** Filtre/projeksiyonu **raw kayıt baytları** üzerinde 1024'lük batch'lerle çalıştır.
Mevcut `ScanRawIter` (P-18a) ve `VDbPeekRawRow*` altyapısı bunun yarısını zaten yapıyor;
agregadan filtreye genişlet. Kolon değerleri tip-tabanlı ara dizilere (Int64/Float64/offset)
yazılır, string matrisi yalnız **sonuç** aşamasında kurulur.
**Kabul testi:** Filtreli `SELECT ... WHERE x > k` 1M satır öncesi/sonrası; eşit sonuç kümesi.
**Beklenen:** 3–10x (filtreli yolda). **Risk:** Orta.

> **Uygulama durumu (2026-10-18, iki adım):**
>
> **Adım 1 — LIMIT erken-çıkış (genel yol).** ORDER BY / DISTINCT / pencere / QUALIFY / set-op
> **yokken** WHERE filtresi ilk `OFFSET+LIMIT` eşleşen satırı toplar toplamaz **durur**
> (`ExecSelect` filtre döngüsü, `capSel`). Tam tarama sonrası LIMIT uygulanıyordu; artık
> kalan satırlar için `RowMatches` değerlendirilmez. Sonuç **birebir aynı** (sıra + küme).
> İndekssiz 100.000 satır, `WHERE a>=100 AND a<200 LIMIT 50`: **583 → 111 ms (~5,3x)**.
>
> **Adım 2 — Akışlı filtered SELECT (`TryStreamSelect`).** İndekssiz tek tablo, ORDER BY'siz,
> LIMIT'li SELECT'te kayıtlar **ham akıştan** (`ScanRawIterAll`) okunur, `VDbDecodeRawRowP`
> (yeni: `DecodeRow`'un `PByte`+Len sürümü, `VDbTable.pas`) ile **yalnız eşleşen/limit'e yeten
> satırlar** string'e çözülür ve LIMIT dolunca tarama **durur**. Genel yol tüm tabloyu çözüp
> string matrisi kuruyordu. Güvenlik: ikincil indeks varsa veya WHERE PK'ya başvuruyorsa
> (indeks/PK daraltması olabilir) streaming **kullanılmaz**, genel yol aynen çalışır; bozuk
> kayıt/hash çakışmasında `Failed` ile genel yola düşülür (o, aynı net hatayı üretir).
> Ölçüm (indekssiz 100.000 satır):
> `WHERE a>=100 AND a<200 LIMIT 50` **583 → ~10 ms (~58x)**;
> `SELECT id,a FROM t LIMIT 50` (WHERE'siz) **~187 → ~8 ms (~22x)**.
>
> **Adım 3 — Ham-yüklem (raw predicate) batch motoru.** `TryStreamSelect` artık LIMIT'siz de
> çalışır: WHERE'nin **AND zincirindeki** `kolon <op> sayısal-literal` koşulları (INT/FLOAT)
> ham baytlardan (`VDbPeekRawRowP` ofsetleri) değerlendirilir ve **kesinlikle uymayan satır HİÇ
> string'e çözülmez**; uyan adaylar `VDbRowFromOffsetsP` ile çözülüp yine `RowMatches` ile
> doğrulanır (çift kontrol). Bu nedenle yanlış eleme (sessiz satır kaybı) **imkansızdır**: elem
> yalnız "kesin uymuyor" durumunda; NULL→elenir (3-değerli mantık), kayıttaki gerçek alan tipi
> beklenen tipten farklıysa (dinamik tip/eski şema) **hiç filtrelenmez**. BOOL/IN/BETWEEN/
> fonksiyon koşulları ham yoldan geçmez (genel `RowMatches`'ta kalır).
> Ölçüm (indekssiz 100.000 satır, temiz ortam): `WHERE a>=100 AND a<200` (LIMIT'siz, 20.000 eşleşme)
> **583 → 194 ms (~3,0x)**; `WHERE a = 123` **335 → 80 ms (~4,2x)**; `... LIMIT 50` 583 → **10,8 ms
> (~54x)**; `SELECT id,a FROM t LIMIT 50` 187 → **10,2 ms (~18x)**; PK/indeks yolu (0,86 ms) değişmedi.
> (Not: bir ara makine ~2x yavaşladı → dokunulmayan INSERT 8.100→15.978 ms; yukarıdaki sayılar
> makine normale döndükten sonra alındı ve `joinbench` 95→97 ms ile tutarlı.)
>
> **Doğrulama:** `rawchk` diferansiyel testi (INT/FLOAT/TEXT/BOOL/NULL karışık 5.000 satır, 30
> sorgu) akışlı/ham yolu `ORDER BY id` ile zorlanan **genel yolla** karşılaştırır — hepsi birebir
> aynı. Bu test bir hata yakaladı: BOOL kolon `VDbRowFromOffsetsP`'te `-1/0` üretiyordu, oysa
> `DecodeRow` `True/False` üretir → düzeltildi (`BoolToStr(x, True)`).
>
> **Adım 3b — TEXT eşitlik/eşitsizlik ham yüklemi.** `kolon = '<ASCII>'` / `kolon <> '<ASCII>'`
> (yalnız `sltString` literal, `VCT_STR` kolon) ham baytlardan değerlendirilir. Motor metin
> karşılaştırması `VDbCmpVal`'de **bayt düzenidir** (harf-duyarlı, COLLATE yok) ve `''`(NULL) hiçbir
> operatörle eşleşmez → ham yol birebir aynı sözleşmeyi uygular. Güvenlik: literal saf-ASCII değilse
> hiç kurulmaz; kayıttaki alan `VCT_STR` değilse ya da baytlarda >=128 varsa (kod-sayfası farkı
> ihtimali) **filtrelenmez** (`Continue` → genel `RowMatches`). Sıralı (`<`,`>`) metin kıyası
> kurulmaz. Ölçüm: `WHERE b = 'v42'` (100.000 satır, 1031 eşleşme) **291 → 116 ms (~2,5x)**.
> `rawchk` TEXT (ASCII + ASCII-dışı `é` + boş) ve `<>`/karışık durumlarıyla **22/22 birebir**.

> **Adım 3c — sayısal BETWEEN / IN ham yüklemi.** Ham koşu motoru genişletildi:
> sayısal `BETWEEN lo AND hi` (NOT değil) **iki koşuya** açılır (`>= lo`, `<= hi`) — mevcut
> değerlendirici yeniden kullanılır; sayısal `IN (...)` (NOT IN değil, alt sorgu yok, tüm literal
> sayısal) yeni `IsIn` türüyle değerlendirilir. NULL yine hiçbir eşitlikle eşleşmez (ham yol eler).
> Gerçek yürütme yine `RowMatches` ile **çift kontrol** eder → yanlış eleme imkânsız. `rawchk`
> INT/FLOAT BETWEEN, BETWEEN+ek koşul, INT/FLOAT IN, `NOT IN`, `NOT BETWEEN` dahil **29/29
> birebir**. Bu adım gerçek bir hata yakaladı: `TryCond`'un INT/FLOAT/TEXT dalları `IsIn` alanını
> başlatmıyordu → FLOAT koşulları yanlışlıkla IN dalına düşüp 0 satır döndürüyordu; alanlar
> açıkça başlatılarak düzeltildi.

> **Adım 3c ölçüm (`scanbench`, 100.000 satır):** `a BETWEEN 100 AND 199` **169 ms**
> (aynı sınıf `a>=100 AND a<200` 179 ms); `a IN (100,150,200,250)` **69 ms** vs
> ifade sürümü `(a+0) IN (...)` **214 ms** (~3,1x). Yani BETWEEN/IN artık ham batch
> motorundan geçiyor.

> **EK — ifade karşılaştırma tipi hatası (bulundu ve düzeltildi).** Ham-yüklem
> kıyaslaması yapılırken fark edildi: genel `EvalExpr`, iki tarafı da **kolon
> referansı olmayan** karşılaştırmalarda (ör. `(a+0) > 198`, `a BETWEEN 100 AND 199`
> ifade hâli) tip bağlamını daima `VCT_STR` alıyordu → **sözlüksel** kıyas:
> `(a+0) > 198` 77.800 satır döndürüyordu (doğru: 60.200), çünkü `'1990' < '198'`.
> Düz kolon (`a > 198`) doğruydu (ham yol maskeliyordu); hata yalnız ifade
> tarafında ortaya çıkıyordu. Düzeltme: `ExprResultCtype` (aritmetik → INT/FLOAT,
> iç içe ifade/birim eksi/fonksiyon özyinelemeli) eklendi ve **yalnız iki taraf da
> kolon değilken** uygulanıyor (metin kolonunun sayısal literalle kıyası
> değişmez). `BETWEEN` ifade yolu da aynı şekilde düzeltildi. Regresyon: `T07`
> içine `(v+0) > 9`, `(v*1) < 10`, ifade-BETWEEN, birim eksi testleri → `sqltest`
> **2426/2426**, `crashtest 8/8`, `rawchk 29/29` (ifade ile düz kolon birebir),
> `hashchk 80/80`, `mrowchk` ve `cbochk` 0 hata.

> Join yolundaki `MrPush` kopyalama/tampon yeniden kullanımı korunuyor (tek başına nötr ölçüldü).
> NOT: Ölçümlerin bir kısmı, oturum sırasında makine ~2x yavaşladığı için (dokunulmayan INSERT
> 8.100→15.978 ms) mutlak değil **göreli** okunmalı.

### H2 — Hash join + hash GROUP BY
**Sorun:** KR-B. Eşitlik join'inde indeks yoksa O(N×M).
**Çözüm:**
1. Eşitlik join'inde **build-side hash tablosu** (open addressing) → O(N+M).
2. `GROUP BY` için hash agrega (sıralamaya/kaydırmaya gerek kalmadan).
3. Semi-join/`IN (alt sorgu)` için **Bloom filtresi** pushdown.
**Kabul testi:** 10K×10K indekssiz eşitlik join; satır ve değer doğruluğu birebir.
**Beklenen:** İndekssiz join'de O(N×M)→O(N+M); çok tablolu sorgularda büyük fark. **Risk:** Orta.

> **Uygulama durumu (2026-10-18, tamamlandı):** İndeks hızlı yolu UYGULANMAYAN ve ON
> tek eşitlik olan INNER/LEFT join'ler için sağ taraf hash tablosuna konup O(N+M) yapıldı
> (`ExecJoinScan`). Kural: yalnız INNER/LEFT, NULL anahtar eşleşmez, iki kolon aynı ctype,
> USING/NATURAL ve AND'li koşullar klasik yolda kalır; `JoinOnOk` nihai eleyici olarak korunur
> (satır sırası birebir). Ölçüm (`joinbench`, 3000×3000 indekssiz eşitlik, 30.000 eşleşme):
> **24.020 ms → 98 ms (~245x)**. Kapılar: `sqltest 2426/2426`, `crashtest 8/8`.

### H3 — Aralık sorguları için modern indeks (ART / B+tree / skiplist)
**Sorun:** KR-C. `BETWEEN`/`RANGE` ~15x; tembel tam rebuild + O(n) ekleme.
**Çözüm (aşamalı):**
1. Önce **bucket min/max zone map** ekle: aralık sorgusu, hiç dokunması gerekmeyen
   offset bucket'larını atlar (mevcut bucket taramasına doğal ek).
2. Point+range'i birlikte vermek için **ART (Adaptive Radix Tree)** veya **skiplist**
   bellek-içi indeks prototipi. ART: O(k) arama + sıralı iterasyon; string ve int anahtar uyumlu.
3. Mevcut `TIdxEntry` (Key/Pk/Cov) sözleşmesini koru; UNIQUE/partial/expression/covering
   ve concurrent-build catch-up yollarını test et.
**Kabul testi:** 1/10/100/10.000 satır güncelleme + 1M girdili indekste BETWEEN.
**Beklenen:** BETWEEN/RANGE'de büyük kapanma; tam rebuild'in kalkması. **Risk:** Orta-Yüksek.
**Durum (2026-10-18, ölçüm):** Mevcut bellek-içi indeks dilimi (`VDbIdxRangeL`) pratikte çok etkili:
100.000 satırlı tabloda `WHERE a>=100 AND a<200` indekssiz **666 ms** → indeksli **0,51 ms** (~1300x).
Yani H3'ün *kalan* değeri yalnız **indekssiz** tarama (H1) ve indeks *kurma/güncelleme* maliyeti;
sorgu tarafında ART/B+tree kazanımı bu profilde küçük. ART/B+tree hâlâ tasarım.

> **Uygulama durumu — 1. adım: bucket zone map (2026-10-19, TAMAM):**
> Disk biçimine **dokunulmadan**, offset bucket'ı (2 MB, `VDB_RAW_SCAN_SHIFT=21`,
> en çok 8192 bucket) başına INT(8)/FLOAT(8) kolonlar için min/max tutulur.
> Harita **bellek içindedir** ve `(FIdxVer, DataEpoch)` çiftiyle anahtarlanır:
> `FIdxVer` **FIndex güncellemesi TAMAMLANDIKTAN sonra** artar (yarım kalmış
> yazma yüzünden bayat haritanın geçerli sanılması imkânsız); her fiziksel
> yeniden yazma (Compact/Restore/Rekey) `FDataEpoch`'u artırır. Açık batch
> içinde zone map **ne kullanılır ne de inşa edilir** (pending PUT/DELETE'ler
> `FIdxVer`'i artırmaz; görünürlük ayrı test edilir).
> - **İnşa maliyeti ~0:** harita, zone uygun ilk taramanın callback'inde
>   (satır zaten çözülmüşken) doldurulur; ekstra tarama/pass YOK.
> - **Budama:** `ScanRawIterAllZoned` yalnızca `SkipBuckets[b] <> 0` olan
>   bucket'ları **hiç okumaz** (ReadFile + callback yok). Karar yalnızca
>   "bu bucket'ta eşleşen satır OLAMAZ" kanıtı varsa verilir; min/max asla
>   daraltılmaz. Bucket'ta non-NULL değer yoksa (hepsi NULL/boş) karşılaştırma
>   FALSE olduğundan bucket atlanır (3-değerli mantıkla aynı).
> - **Güvenlik:** satırın gerçek tipi beklenenden farklıysa veya FLOAT'ta NaN
>   görülürse ilgili kolon "kullanılamaz" işaretlenir ve o kolon için budama
>   yapılmaz. LIMIT ile erken durulursa yalnızca **tam işlenen ön-ek
>   bucket'lar** "tamam" işaretlenir; kalanlar sonraki taramada okunur.
>   Batch/rollback: harita yalnızca sınırları GENİŞLETEBİLİR; rollback sonrası
>   fazla geniş sınır güvenlidir (yanlış eleme imkânsız).
> - **Ölçüm (`zonechk`, 200.000 satır / ~19 MB, blok önbelleği KAPALI):**
>   aynı kolonda ilk tarama haritayı kurar (normal tam tarama maliyeti),
>   sonraki taramalar: `a = 77777` **163,5 → 31,6 ms (5,2x)**;
>   `f BETWEEN 1000.0 AND 1001.0` **185,4 → 35,4 ms (5,2x)**.
>   Aralık sorgularında taban ~39 ms'dir; bu, A/B fazındaki O(n) indeks
>   dolaşımıdır (zone map yalnız C fazını keser). `<>` ve dağınık kolon
>   budanmaz (beklenen). Doğruluk: tüm şekiller `COUNT(*)` ile birebir;
>   INSERT/UPDATE/DELETE/Compact sonrası sonuçlar doğru (bayat harita
>   kullanılmıyor). **Kapılar:** `sqltest 2426/2426`, `crashtest 8/8`,
>   `rawchk 29/29`, `hashchk 80/80`, `cachechk`/`mmapchk`/`aggchk` birebir.
> **Kalan:** ART/B+tree prototipi (indekssiz taramada A/B fazının O(n)
> dolaşımını da kaldırmak için offset→bucket indeksi veya ART).

### H4 — mmap read yolu (sıfır-kopya)
**Sorun:** KR-D okuma tarafı. Kayıt başına okuma/kopya.
**Çözüm:** Append-only veri dosyasını `MapViewOfFile` (Windows) / `mmap` (POSIX) ile eşle;
`ScanRawIter` geri çağrısına `(PByte, Len)` olarak **haritanın içinden** işaretçi ver.
`VDbXPrims.pas` her iki ilkeli zaten kullanıyor (`CreateFileMapping`/`mmap`, satır 475/571) — yeniden kullan.
Dosya büyümesi/Compact için **güvenli remap** şart; başarısızlıkta mevcut `TFileStream` yolu **birebir** devralır.
**Kabul testi:** Sıcak/soğuk cache, şifreleme + CRC açıkken birebir eş sonuç; tepe bellek sınırlı.
**Beklenen:** Kopyalama/syscall azalması, okuma yolunda belirgin düşüş. **Risk:** Düşük-Orta.

> **Uygulama durumu (2026-10-18, deneysel — varsayılan KAPALI):** `ScanRawIter`'e
> salt-okunur dosya eşlemesi eklendi (`TVDbFileMap`, `VDbMapFileHandle`). Ayrı handle
> yerine **açık `FS.Handle`** üzerinden `CreateFileMapping`/`MapViewOfFile` kullanılır
> (`TFileStream` dosyayı paylaşımsız açtığından ikinci bir `CreateFile` başarısız olur);
> bu sayede eşleme Compact/yeniden-adlandırma sırasında da geçerlidir. Bucket aralığı
> harita içindeyse kayıtlar doğrudan haritadan verilir; herhangi bir hata / aralık-dışı /
> küçük-büyük dosyada mevcut konumsal okuma yolu **birebir** devralır. API:
> `SetReadMapEnabled` / `ReadMapEnabled` / `ReadMapOpens`; eşikler `VDB_MMAP_MIN = 1 MB`,
> `VDB_MMAP_MAX = 2 GB`. **POSIX şimdilik kapalı** (fallback).
> **Doğrulama (`mmapchk`, 120k satır ≈ 5,4 MB):** açık/kapalı **birebir aynı** (satır +
> uzunluk + içerik checksum'ı); UPDATE/DELETE/Compact sonrası da aynı; **şifreli** dosyada
> da aynı (`esleme=2` → mmap yolu gerçekten çalıştı). **Ölçüm:** sıcak cache tam tarama
> **11,3 ms (kapalı) → 17,3 ms (açık)** — mmap **daha yavaş**. Nedeni: eşleme başına
> kurulum + 4 KB'da bir **yumuşak sayfa hatası** (~1600 hata ≈ 5–6 ms); `ReadFile` ise tek
> syscall ile yeniden kullanılan tampona kopyalıyor. Taramalar kayıt-başı CPU'ya bağlı
> olduğundan mmap kazancı yok. **Karar:** doğru ve güvenli (fallback'li) deneysel yol
> olarak **varsayılan KAPALI** bırakıldı; kalıcı (tek sefer kurulup büyümeyle yeniden
> eşlenen) bir harita + `PrefetchVirtualMemory` ileride değerlendirilebilir.
> **Kapılar:** `sqltest 2426/2426`, `crashtest 8/8`, `mmapchk` birebir, `cachechk` birebir.

### H5 — Blok-grup CRC
**Sorun:** Kayıt başına CRC, tarama/verify CPU'sunda pay sahibi.
**Çözüm:** 64 KB blok başına tek CRC (kayıt başlığı sadeleşir). `Verify` zaten bloklu okumaya
geçmişti (`vdb_analiz_raporu.md §2.3`); doğrulamayı da blok seviyesine taşı.
> Not: bu bir **format** dokunuşudur; ayrı dal + migration + tam crashtest zorunlu.
**Beklenen:** Scan/verify CPU'sunda düşüş. **Risk:** Orta.

### H6 — Tek sorgu paralelleştirme
**Sorun:** R-14 paralel sorgu var ama tek büyük agrega/tarama hâlâ seri.
**Çözüm:** Taramayı offset bucket'larına böl (bucket altyapısı var) ve thread pool'a dağıt;
indeks build'ini paralel merge-sort'a çevir (`SortIdxEntries` 1M'de belirgin).
**Kabul testi:** 1/2/4/8 thread ile agrega throughput; tek thread performansı gerilememeli.
**Beklenen:** Tek büyük taramada ~N×. **Risk:** Orta.

> **Uygulama durumu (2026-10-18, tamamlandı — tek tablo agrega):**
> **Kapsam:** `TryStreamAgg` (tek tablo, GROUP BY yok, yalnız COUNT/SUM/AVG/MIN/MAX,
> DISTINCT/FILTER yok). `WHERE/HAVING/ORDER/LIMIT` varsa genel yol kullanılır.
>
> **Tasarım:**
> - `TVDb.PrepareRawScan` adayları **BİR KEZ** toplar (`FIndex` yoğun tabloda doğrudan,
>   seyrek tabloda `FTableKeys`; tek geçiş + counting sort) ve 256 KB offset
>   bucket'larına göre sıralar. `ScanRawPrepared`, işçi başına yalnız
>   `[CandLo, CandHi)` aday dilimini tarar → **işçi başına O(n) FIndex dolaşımı yok**
>   (ilk denemenin ölçeklenmeme nedeni buydu).
> - Eşik: tablo anahtar sayısı **≥ 20.000** ve **≤ 2.000.000** (i386 adres alanı).
>   Altında/üstünde seri yol; tek işçi performansı değişmez.
> - Her işçi **kendi** `TAggIterCtx` kopyasına biriktirir. `FType/FOff/FLen`
>   `VdbAggRawCb` tarafından her satırda yeniden yazıldığından işçi başına AYRI
>   dizidir (paylaşılırsa 8 işçide yanlış değer üretiyordu — düzeltildi).
> - Birleştirme deterministik (işçi sırası sabit). **SUM/AVG `VCT_FLOAT` ise
>   paralel KAPALI** (kayan nokta sırası bit-aynı kalsın); MIN/MAX float serbest.
>   `VCT_INT` toplamı |toplam| < 2^53 için tamdır.
> - Batch (`InBatch`) açıkken `PrepareRawScan` False döner → seri yol (pending
>   op'ların offset'i yok).
>
> **Kök neden düzeltmesi (havuz):** FPC'nin Windows `RTLEvent`'i **auto-reset**;
> tek `SetEvent` yalnızca BİR işçiyi uyandırıyordu, kuyruğu da tek işçi tüketiyordu
> → tüm "paralel" işler (sıralama dahil) fiilen **tek işçide** koşuyordu. Havuz
> Windows'ta **sayma semaforu** (`CreateSemaphore`/`ReleaseSemaphore`, görev başına
> bir token) ile düzeltildi; POSIX yolu eski RTLEvent davranışında bırakıldı.
> Not: aynı değişiklik paralel sıralamayı da gerçekten hızlandırır.
>
> **Ölçüm (`aggchk`, 150.000 satır; sıcak cache, 5 tekrar):**
> | işçi | ms/sorgu | hız |
> |---:|---:|---:|
> | 1 (seri) | 53,0 | 1,00x |
> | 2 | 25,2 | 2,10x |
> | 4 | 16,4 | 3,24x |
> | 8 | 13,0 | 4,08x |
> Aynı koşuda CPU testi 2,45 → 0,58 ms (3,85x), hazır tarama 3,94 → 2,13 ms.
> `PrepareRawScan` maliyeti ~7 ms (tek işçi; Amdahl sınırı ~4,4x).
> **Sonuçlar referansla birebir** (COUNT/COUNT(v)/SUM/AVG/MIN/MAX, tüm işçi
> sayılarında); float SUM/AVG `gorev+=0` (paralel kapalı) ve birebir.
> Dosya eşlemesi (mmap) hazır taramada **varsayılan KAPALI** (`VDB_PREP_USE_MAP=False`):
> açıkken 8 işçi 16,3 ms, kapalıyken 13,0 ms (mmap sayfa hatası maliyeti).
> **Kapılar:** `sqltest` **2247/2247 (kalan=0)**, `crashtest` **8/8**,
> `rawchk` 29/29, `cachechk`/`mmapchk` diferansiyel True.
> **Kapsam dışı bırakılan (sonradan tamamlandı):** indeks build'inin
> (`SortIdxEntries`) paralel merge-sort'a çevrilmesi — bkz. aşağıdaki
> "H6-sort" notu.

> **H6-sort (2026-10-19, TAMAM) — paralel indeks sıralaması:**
> `SortIdxEntries` ve `SortIdxEntriesCols` artık:
> 1. Diziyi `ParallelWorkerCount*2` parçaya böler; her işçi **yalnız kendi
>    aralığını** Hoare hızlı sıralamasıyla sıralar (INT için önceden çözülmüş
>    `Int64` anahtarlar + `NULL` bayrağı da parçalı taşınır).
> 2. Parçalar **tek geçişli k-yönlü min-heap birleştirme** ile birleştirilir
>    (`IdxSortMerge`); kopyalama `n` eleman kadardır, `n log k` karşılaştırma.
> Karşılaştırma kuralları eski yolla **birebir** aynıdır (NULL önce, eşitlikte
> `Pk` `CompareStr`, çok kolonlu `VDbIdxMultiCmp`), sonuç deterministiktir.
> Eşikler: **50.000 ≤ n ≤ 4.000.000** (altında/üstünde seri; üstte birleştirme
> için bellek ikiye katlanmaz). Havuz yoksa `InitThreadPool(0)` ile tembel
> açılır; işçi içinden çağrılırsa `VdbParallelFor` otomatik seri koşar (o
> durumda birleştirme yine doğrudur, sadece gereksizdir).
> Ölçüm/test kancası: `VdbSetSortParallel(False)` → eski seri yol (sonuç
> birebir). **Ölçüm (`sortchk`, 300.000 satır, iki tur):**
> `CREATE INDEX` **708,7 → 515,2 ms (~1,38x)**; indeks içeriği/checksum'lar
> seri ile birebir, `EXPLAIN` indeksi kullanıyor. Kalan süre satır
> okuma/anahtar çıkarma + fsync'tir; sıralamanın payı büyüdükçe (daha büyük
> `n`) oran artar. **Kapılar:** `sqltest 2426/2426`, `crashtest 8/8`.

### H7 — Plan/AST önbelleği (yeniden değerlendir)
**Sorun:** `TVSql.ExecRaw` her çağrıda parse + executor kuruyor (`yol_haritasi_hiz.md §6`).
v0.005'te ertelendi (SQLite tarafı `sqlite3_exec` kullanıyordu) — **reddedilmedi**.
**Çözüm:** SQL metni + şema sürümü + RLS/rol bağlamı anahtarlı sınırlı AST cache;
DDL/rol/policy/collation değişiminde invalidate; parametre değerleri AST'de değiştirilebilir.
**Kabul testi:** Tekrarlı aynı sorgu vs değişen parametreli; invalidation testleri.
**Beklenen:** Kısa tekrarlı sorgularda %30–60 CPU. **Risk:** Düşük-Orta.

> **Uygulama durumu (2026-10-18, tamamlandı):** `TVSql` içine sınırlı plan önbelleği eklendi
> (`FPlanCache`, kapasite 256). Yalnız **parametresiz SELECT**'ler saklanır (view-DML AST'yi
> yerinde değiştirdiği için DML dışta; parametreli çağrıda AST değere bağlı). DDL
> (`CREATE/DROP/ALTER/TRUNCATE/RENAME`) çalışınca önbellek temizlenir. Gözlemlenebilirlik:
> `PlanCacheHits` / `PlanCacheMisses` / `PlanCacheSize` / `ClearPlanCache`.
> **Ölçüm (`selbench`):** parse-baskın `SELECT 1+2` ×50.000: **0,0075 → 0,0030 ms/sorgu (~2,5x)**;
> filtre+sort ×60: **816,9 → 742,1 ms (~%9)** — kalan maliyet tarama/sıralama. Kapılar:
> `sqltest 2426/2426`, `crashtest 8/8`.

### H8 — CBO kalibrasyonu
**Sorun:** `VdbEstimateEqRows` distinct istatistiği yoksa `RowCount div 4` sezgisine düşüyor
(`yol_haritasi_hiz.md §7`); katsayılar sabit.
**Çözüm:** EXPLAIN tahmini vs EXPLAIN ANALYZE gerçeği karşılaştıran test seti; uniform/skewed,
yüksek NULL, korelasyonlu kolon, dar/geniş aralık. Gerekirse histogram/MCV; scan başına
gerçek satır/byte + cache hit/miss ile `VDbCost` katsayılarını kalibre et.
**Kabul testi:** Tahmin/gerçek oranı, yanlış plan sayısı, toplam gecikme.
**Beklenen:** Yanlış plan seçiminin kalkması. **Risk:** Düşük.

> **Uygulama durumu (2026-10-18, tamamlandı):** İki parça:
> (1) **Doğrulama seti** `cbochk` — uniform / çarpık (skew) / yüksek-NULL / korelasyonlu /
> dar-geniş aralık dağıtımlarında `EXPLAIN` tahmini (`rows=N`) ile `EXPLAIN ANALYZE` gerçeğini
> (`Actual Rows`) karşılaştırır, plan türünü (Index/Seq) sabit beklentiyle sınar. **0 hata.**
> Bulgular: eşitlik tahmini uniform/high-NULL/korelasyonlu/küçük-aralıkta oran ≈1,00; **skew**
> (değer 7 ~%50 → est 196, gerçek 5000) distinct-tabanlı tahminin bilinen sınırı (histogram/MCV
> gerekir, ayrı iş — belgelendi).
> (2) **Aralık (range) seçiciliği düzeltmesi:** Gerçek yürütme (`NarrowRows`) dilim boyutunu
> (`bestHi-bestLo`) **tam** bilirken, `EXPLAIN` aralık için sabit `RowCount div 3`e düşüyordu →
> plan metni ile gerçek plan çelişebiliyordu. `ExecExplain.RangeColEst` eklendi: ANALYZE **min/max**
> istatistiğinden uniform kesir `([lo,hi]∩[min,max])/(max-min)` ile tahmin; yalnız sayısal kolon
> (PK ya da indeks öneki) + sayısal sınır; `BETWEEN` dahil. `ince-aral` (`a>=40 AND a<42`, 200
> satır) artık `est=202 / Index` (önceden `est=10000 / Seq`). Kapılar: `sqltest 2426/2426`,
> `crashtest 8/8`.

### H9 — Mikro temizlik
- `TriggersFor` içindeki kalan debug `WriteLn` izleri (v0.008 changelog'da not edilmiş) kaldır.
- Sıcak yolda kalan gereksiz `TStrMatrix`/`SetLength(arr, n+1)` kalıplarını gözden geçir.
**Beklenen:** stdout gürültüsü + küçük CPU/bellek. **Risk:** Sıfır.

### H10 — Yazma yolu: satır başına CPU azaltımı (format değişmeden)
**Sorun:** KR-D. INSERT/UPDATE'te satır başına FNV anahtar kurulumu (`VDbHashKey`),
tip dönüşümü ve `EncodeRow` tahsisi. Grup commit (`SyncWriteInterval`) zaten var;
eksik olan **satır-içi** iş (mevcut yol `VDbTable.pas` Insert/EncodeRow + `VDbHashKey`).
**Çözüm:**
1. Tablo önekini **batch başına BİR KEZ** `VDbHashKeyPrefix` ile hesapla; satırda yalnız
   pk UTF-8 baytlarını `VDbHashKeyBytes` ile tohuma katla — KR-8'in okuma tarafında
   yaptığının **yazma karşılığı** (aynı hash değeri, `hashchk` ile kanıtlanabilir).
2. `EncodeRow` çıktı tamponunu batch boyunca yeniden kullan (`FBatchColMap`/`FBatchTableDef`
   zaten var); satır başına `SetLength` kalksın.
3. Duplicate-PK denetimini batch-içi `FPending` haritasıyla O(1) tut; gereksiz `DecodeRow`'u atla.
**Kabul testi:** 1M INSERT (BEGIN/COMMIT) + 5.000 tekil autocommit INSERT öncesi/sonrası; `checksum` birebir.
**Beklenen:** INSERT 7,7x → ~2–3x. **Risk:** Düşük-Orta.

> **Uygulama durumu (2026-10-18, kısmi — adım 1):** Batch başına BİR KEZ hesaplanan
> `FBatchHashPrefix` eklendi; `Insert` artık saf-ASCII pk'da `VDbHashKeyBytes(prefix, ...)`
> kullanıyor, ASCII dışında genel `VDbHashKey` yolu korunuyor (hash birebir, format değişmedi).
> Ölçüm (`insbench`, 1M INSERT tek tx): **8836 ms → 8199 ms (~%7,2)**. Kapılar:
> `hashchk` 80/80 eşit, `sqltest 2462/2462`, `crashtest 8/8`. Adım 2 (`EncodeRow` tampon
> yeniden kullanımı) **denendi ve geri alındı**: bekleyen `Put` tamponu referansla
> tuttuğu için copy-on-write oluşuyor; 1M INSERT 7920→7934 ms (kazanç yok). Adım 3
> (`FPending` duplicate-PK) zaten vardı.


### H11 — Append-only ölü alan geri kazanımı (free-list / yerinde güncelleme)
**Sorun:** KR-D. UPDATE = yeni kayıt + eski sürüm ölü; DELETE = tombstone; dosya sürekli büyür,
`Compact` şart olur. 1M UPDATE'te ~%25–40 ölü alan birikir.
**Çözüm:** Bir **boş blok listesi (free-list)** tut. Yeni sürüm mevcut bir ölü bloğa sığıyorsa
(boyut ≤ blok kapasitesi) **yerinde** yaz + `FIndex` offset'ini güncelle; sığmazsa append et.
`DeadBytes`/`AutoCompact` eşiği buna göre güncellenir. **Format değişmez** (aynı kayıt
başlığı/CRC/bayrak düzeni); yalnız yazma hedefi seçimi değişir.
**Kabul testi:** 100.000 UPDATE öncesi/sonrası **dosya boyutu + süre**; `crashtest 8/8`;
"bozukta bağır" (hash/CRC) sözleşmesi korunur.
**Beklenen:** Ölü byte ↓, dosya büyümesi ↓, UPDATE'te I/O ↓. **Risk:** Orta (recovery/kuyruk kesme).

### H12 — Sınırlı blok/sayfa önbelleği (LRU/CLOCK) — DB ≫ RAM
**Sorun:** Profil "DB RAM'e sığar" varsayımına dayanıyor (§5). DB > RAM olduğunda
`GetSnapshot` ve taramalar kayıt başına syscall + kopya yapar; mevcut salt-okunur cache'in
tahliye (eviction) stratejisi belirsiz.
**Çözüm:** **Fiziksel offset bazlı**, sabit-bellek tavanlı (örn. 64–256 MB) bir **blok önbelleği**
(LRU veya CLOCK) ekle; sıcak blokları RAM'de tut, soğukta doğrudan oku. Append-only düzeni
değişmez — yalnız okuma yolu. H4 (mmap) ile birlikte düşünülür; mmap yoksa bu devreye girer.
**Kabul testi:** Sıcak/soğuk cache'te PK lookup + full scan; bellek tavanı sabit kalmalı;
şifreleme + CRC açıkken sonuç birebir.
**Beklenen:** DB ≫ RAM iş yükünde belirgin düşüş; RAM-ikametli rejimde nötr. **Risk:** Düşük-Orta.

> **Uygulama durumu (2026-10-18, tamamlandı):** `VDbCore.pas`'e **fiziksel offset tabanlı,
> sabit-bellek tavanlı blok önbelleği (CLOCK)** eklendi. Blok boyutu **8 KB**; varsayılan
> kapasite **1024 blok = 8 MB** (`SetReadCacheBlocks` ile değiştirilir, `0`=kapatır). `GetSnapshot`
> hızlı yolu artık önce önbelleğe bakar: HIT **syscall yapmaz**; MISS'te 8 KB blok okunur
> (kilit **dışında**) ve CLOCK ile yerleştirilir. Yalnızca **TAM** bloklar (dosyadan birebir
> 8 KB okunabildiyse) önbelleğe alınır; dosya append-only olduğundan bu blok bir daha değişmez
> (kısmi son blok ve `>8 KB` kayıtlar devre dışı → eski konumsal yol birebir). Görünürlük/
> tombstone/CRC/şifre-çözme katmanı **DEĞİŞMEZ** (önbellek ham baytları tutar). Geçersizleştirme:
> `Recover` (Open/Reopen + Compact'ın `ReplaceWith`'i), commit hata-sarması (truncate) ve **yerinde
> başlık yazımı** (0. blok). Önbellek için ayrı `FCacheLock` (okuma yolu `FLock` almaz → kilit-sırası
> çevrimi yok); arama O(1) hash (`FCacheMap`), tahliye CLOCK.
> **Ölçüm (`cachechk`, 200.000 satır ≈ 14 MB, 300.000 rastgele PK SELECT):** kapalı **8,38 µs/okuma**;
> açık (dosya sığar) **4,66 µs (~1,80x)**, %99,7 isabet; **varsayılan 8 MB + sıcak 10k çalışma kümesi
> 4,43 µs (~1,89x)**, 605k isabet/89 ıska; tüm-tablo rastgele + 8 MB **7,38 µs (~1,13x)**, %56 isabet;
> aşırı-küçük 16 blok **10,0 µs (~0,84x, geriler)** — bu yüzden 64 KB yerine **8 KB** blok seçildi
> (ıska amplifikasyonu ~8x az). **Şifreli (AES-256-CTR) diferansiyel BİREBİR** (hits=120987/misses=841).
> Kapılar: **`sqltest` kalan=0**, **`crashtest 8/8`**, `rawchk 29/29`, `hashchk 80/80`, `mrowchk 0 hata`,
> `cbochk 0 hata`; UPDATE/DELETE/Compact sonrası doğruluk tam. **Sınırlama:** taramalar zaten bitişik
> okur (bu önbellek onları etkilemez/yarar sağlamaz); çalışma kümesi önbellekten çok büyükse (saf
> rastgele, yerellik yok) küçük bir gerileme olabilir → `SetReadCacheBlocks(0)`.

### H13 — Toplu yükleme yolu (COPY FROM / çok-satırlı VALUES)
**Sorun:** Tek satırlık INSERT'ler autocommit'te bile per-record maliyeti ödüyor; bulk
yükleme için ayrılmış hızlı yol yok.
**Çözüm:** `INSERT ... VALUES (..),(..),...` ve bir **`COPY FROM`/bulk API** için: parse'ı bir kez
yap, şema/tip denetimini batch düzeyinde önbellekle (`FBatchTableDef`/`FBatchColMap` zaten var),
tüm batch'i **tek tampona** kodla, tek `COMMIT` ile bitir. Satır-satır genel yol **birebir** korunur.
**Kabul testi:** 1M satır bulk load öncesi/sonrası; `checksum` birebir; tekil INSERT yolu gerilememeli.
**Beklenen:** Bulk load 3–5x. **Risk:** Düşük.

> **Uygulama durumu (2026-10-18, tamamlandı):** Tek-satır literal INSERT için var olan hızlı
> şerit (`ExecFastLiteralInsert`, P-18c) **çok-satırlı VALUES**'e genişletildi: `INSERT INTO
> t [cols] VALUES (..),(..),..` tümü **tek geçişte** ayrıştırılır (AST/lexer maliyeti yok),
> ardından her satır genel yolun **aynı** semantik kapılarından geçer (`RequirePriv` bir kez,
> satır başına `RlsRequireInsert` + `FT.Insert` → PK/UNIQUE/NOT NULL/CHECK/AutoInc/FK aynı).
> >>1 satır ve batch yoksa genel yol ile aynı **atomiklik**: tümü için `BeginBatch`/`CommitBatch`,
> hata olursa `AbortBatch`. RETURNING/ON CONFLICT/'()'/kolon-değer sayısı uyuşmazlığı/trigger/view
> görülürse şerit kapanır ve genel yol **birebir** çalışır (aynı hatalar).
> **Ölçüm (`insplit`, 200.000 satır, tek tx):** satır-satır `sq.Exec` **1665 ms** → çok-satırlı
> VALUES **~1074 ms (~1,55x)**; parça=1000/5000 en iyi. Doğrudan `tb.Insert` (parse yok) 749 ms —
> yani SQL katmanı farkı ~2,8x'ten ~1,4x'e indi. Kapılar: `sqltest 2426/2426`, `crashtest 8/8`,
> `mrowchk` (diferansiyel içerik + atomik rollback + BEGIN/ROLLBACK/COMMIT + Affected) **0 hata**.
>
> **`COPY FROM` (2026-10-19, tamamlandı):** `VDbSql.ExecRaw` içinde `ExecFastCopy` hızlı şeridi
> eklendi. Sözdizimi:
> `COPY <tablo> [(kolon,...)] FROM '<yol>' [WITH] [(] FORMAT CSV|TEXT [, HEADER]
> [, DELIMITER 'x'] [, NULL 'x'] [, QUOTE 'x'] [)]`.
> **CSV:** RFC4180 — tırnak (`""` kaçışı), tırnak içinde ayırıcı/satır sonu, CRLF/LF/CR, UTF-8 BOM
> atlama. **TEXT:** PostgreSQL benzeri — varsayılan TAB ayırıcı, `\N` NULL, `\t \n \r \b \f \v \\`
> kaçışları. Dosya **tek geçişte** 256 KB tamponla okunur; satırlar `FT.Insert` batch yoluna
> verilir (kolon eşleme önbelleği H10 tohumu aynen kullanılır). **Atomiklik:** batch yoksa tüm
> dosya için `BeginBatch`/`CommitBatch`, hata olursa `AbortBatch`; dosya ortasındaki PK/CHECK
> ihlali hiçbir satırı bırakmaz. Zaten açık batch/BEGIN varsa ona eklenir, kapatılmaz. Var olan
> semantik kapılar korunur: `RequirePriv` bir kez, satır başına `RlsRequireInsert`; INSERT
> tetikleyicisi yoksa satır başına `FireTriggers` çağrıları **tamamen atlanır** (sıcak yol).
> Hatalar dosya + satır numarası ile raporlanır. Görünüm (view) hedefi desteklenmez.
> **Ölçüm (`copybench`, 100.000 satır / 3,5 MB, tek tx):** satır-satır `INSERT` **1036 ms** →
> `COPY FROM` **531 ms (~1,95x)**; 300.000 satır / 10,9 MB: **3553 ms → 1613 ms (~2,20x)**,
> dosya boyutuyla doğrusal, batch belleği tek tx ile sınırlı. **`copychk` 17/17**: CSV/`""`/
> tırnak içi LF/boş alan NULL, TEXT `\N`+`\t`, HEADER, kolon listesi, atomik PK ihlali, yol ve
> seçenek hataları, yeniden açılış kalıcılığı. Kapılar: **`sqltest 2426/2426 (kalan=0)`**,
> **`crashtest 8/8`**.

### H10 — ek not (adım 2/3 yeniden değerlendirme)
> Adım 3 (batch-içi duplicate-PK O(1)) **zaten mevcut**: `FindPending` `FPendingIdx` haritasıyla
> O(1) (`VDbCore.pas:1325`), `Exists` de indeks aramasında O(1). Adım 2 (`EncodeRow` tamponunu
> yeniden kullanma) **uygulanmadı**: batch modunda `Put` kodlanmış `TBytes`'i pending'e *referans*
> olarak tutar (commit'e dek), bu yüzden tamponu satırlar arası yeniden kullanmak COW kopyası
> doğurur ve kazanç sağlamaz; gerçek çözüm WAL/pending'in satır başına bayt kopyalaması olurdu
> (recovery'e dokunur → ayrı iş). Kalıcı darboğaz `insplit`'te ölçülüp belgelendi.

### H14 — Okuyucu-başına handle + konumsal I/O (mmap'siz güvenli yol)
**Sorun:** `GetSnapshot` yorumu "lock-free" diyor ama paylaşılan `TFileStream.Position` + `Read`
kullanıyor; birden çok okuyucuda konum yarışı riski (`yol_haritasi_hiz.md §5`). H4 (mmap) bunu
çözer, ancak mmap'ın uygun/başarılı olmadığı durumda güvenli bir **fallback** şart.
**Çözüm:** Offset tabanlı konumsal okuma (`pread` / `ReadFile`+`OVERLAPPED`) **veya** okuyucu-başına
ayrı dosya handle'ı. Snapshot semantiği, CRC ve şifreleme yolu **birebir** korunur.
**Kabul testi:** 1/2/4/8 eşzamanlı salt-okunur istemci; sonuç birebir; tek istemci performansı gerilemez.
**Beklenen:** Paralel SELECT'in yarışsız ölçeklenmesi (H6/H4'ü tamamlar). **Risk:** Düşük-Orta.

---

## 3. MODERNLEŞME FİKİRLERİ (M)

### M1 — PostgreSQL wire protocol (pgwire)  ⭐ en yüksek kaldıraç
Mevcut SQL çekirdeği hazır. `psql`, JDBC/ODBC, PgAdmin, BI araçları ve ORM'ler
**özel sürücü olmadan** bağlanır. VDBS protokolünün üstüne bir çeviri katmanı.
**Neden:** Tek hamlede tüm ekosistem erişimi.
> **Durum (2026-10-19):** Minimal pgwire v3 sunucusu **yapıldı** — `VDbPgWire.pas`.
> Startup v3, SSL/GSS isteklerine `N`, AuthenticationOk (trust), ParameterStatus,
> BackendKeyData, ReadyForQuery; `Q` basit sorgu (RowDescription tüm alanlar TEXT/OID 25,
> DataRow, CommandComplete), ErrorResponse, `X`. Ayrı portta çalışır; VDbSqlServer'a
> dokunmaz. `T116` 80 test: DDL/DML/SELECT, alan adları, satır değerleri, hata sonrası
> devam, Terminate, yeniden başlatma + kalıcılık + **extended query protocol**
> (Parse/Bind/Describe/Execute/Close/Flush/Sync), prepared statement/portal adları ve
> hata sonrası Sync'e kadar yutma. **M1 parametreleri:** `$1…` SQL katmanında ve
> pgwire'da; `ParameterDescription` gerçek parametre sayısı/OID'lerini bildirir; metin
> yanında int2/int4/int8/float4/float8/bool binary parametreler çözülür; `?` yer
> tutucuları da desteklenir. **COPY (2026-10-19):** basit sorguda
> `COPY <tablo> [(kolon,...)] FROM STDIN [WITH] (...)` akışı geçici dosyaya alınıp
> mevcut atomik `COPY FROM` motoruna devredilir; `COPY ... TO STDOUT` ve `COPY (SELECT ...) TO STDOUT` CSV/TEXT
> satırları üretir (`HEADER`, `DELIMITER`, `FORMAT`). CopyIn/CopyOut/CopyFail
> protokol mesajları ve `COPY n` etiketi desteklenir. `T116` 80 test.
> **Kalan:** SSL/TLS, extended protocol üzerinden COPY, gerçek sonuç tip OID'leri
> (şu an hepsi TEXT) ve binary sonuç formatı.

### M2 — Arrow/Parquet içe-dışa + DuckDB interop
Kolonlu dosya formatı desteği; analitik pipeline'lara/Arrow'a sıfır-kopya aktarım.

### M3 — WASM / edge derlemesi
FPC → WASM; tek dosya DB tarayıcıda/edge'de (OPFS üstünde). PGlite/sql.js sınıfı farklılaştırıcı.

### M4 — Vektör arama (`VECTOR` tipi + HNSW/IVF)
AI çağı; Spatial var ama pgvector tarzı k-NN indeksi yok.

### M5 — Tam metin arama (inverted index + BM25)
`VDbText` Türkçe desteği var; FTS indeksi eksik.

### M6 — Şifreleme modernizasyonu
AES-256-CTR var. Modern: **AEAD (AES-GCM)** ile bütünlük dahil, **Argon2** KDF,
kolon-seviyesi şifreleme, envelope/key-rotation.

> **Uygulama durumu (2026-10-19, AEAD + Argon2 tamam):**
> - **AES-256-GCM (AEAD)** `VDbCrypt.pas`: `'VDBAEAD1' (8) || nonce (12) ||
>   ciphertext || tag (16)`. GHASH/CTR/GF(2^128) saf Pascal; DCPcrypt yalnız
>   AES bloğu sağlar. NIST SP 800-38D vektörleri `gcmchk` ile birebir
>   (boş/16/64 bayt, tag, tamper). Yeni yazımlar, `Compact` ve `REKEY`
>   otomatik AEAD üretir.
> - **Geriye dönük uyum:** eski `IV(16)||len||CTR||HMAC-SHA256` zarfları
>   okunmaya devam eder (`VDbCryptEncryptLegacy` yalnız test/araç içindir).
>   Karışık dosya testi (`T74`) ve `gcmchk` legacy turu geçer.
> - **Argon2id v1.3** yeni `VDbKdf.pas`: BLAKE2b-512 + `H'` + Argon2id
>   (secret/AD destekli). RFC 9106 vektörü `argonchk` ile birebir.
> - **`.key` v2:** `'VDBK'|2|saltLen|t(4)|m(4)|p|salt|verifier`;
>   varsayılan `t=3, m=64 MiB, p=1`. Eski v1 PBKDF2 `.key` dosyaları
>   okunur (`keychk`: v2 yaz/oku, yanlış parola, v1 uyumu). `OutIter`
>   v2'de 0'dır; REKEY yeni anahtarı yeniden türetir.
> - **Kalan:** kolon-seviyesi şifreleme; Argon2 `p>1` paralelliği (RFC
>   vektörü p=4 ile doğrulandı, üretimde p=1).
> **Kapılar:** `sqltest 2426/2426`, `crashtest 8/8`, `gcmchk` 13/13,
> `argonchk` 3/3, `keychk` 12/12.

### M7 — Async sunucu + HTTP/JSON streaming + gRPC
Thread-per-connection yerine event-loop; yüksek eşzamanlılıkta ölçek.

### M8 — CI'da sürekli benchmark + fuzzing + diferansiyel doğrulama
Çökme-dayanıklılığı en güçlü varlık: recovery yolunu **fuzz**'la, `vsbench`/`crashtest`'i
her commit'te regresyon kapısı yap. Ek olarak:
- **Diferansiyel test (SQLite'a karşı):** aynı şema + aynı SQL üretimini iki motorda çalıştır,
  sonuç kümelerini (satır + değer) karşılaştır. Regresyonu "test bitti mi" değil "sonuç
  aynı mı" düzleminde yakalar; tek kişilik projenin en güçlü güvenlik ağıdır.
- **Parser/AST property-based fuzz (SQLancer tarzı):** rastgele ama geçerli SQL üretip
  parse+yürüt; çökme/yanlış-sonuç/bellek sızıntısı ara. `VDbSql.pas` + `VDbParser.pas`
  projenin **en riskli** birimi (`vdb_analiz_raporu.md §2.5`); buradaki en yüksek getirili güvenlik ağı.

> **Durum (2026-10-19):** İki bağımsız oracle ile diferansiyel doğrulama yapıldı.
>
> 1. **Bağımsız 3VL fuzz:** `fuzzchk.dpr`, 400 satırlık INT/FLOAT/TEXT/BOOL/NULL
>    karışık tabloda rastgele WHERE yüklemleri üretir; aynı yüklemi VDB'de ve
>    Pascal'daki bağımsız üç-değerli değerlendiricide çalıştırıp kimlik kümelerini
>    karşılaştırır. `3 seed × 1000 = 3000/3000` birebir.
> 2. **SQLite diferansiyeli:** `sqlite_diff.py` + `vdbbatch.dpr`, aynı şema/satırları
>    ve aynı rastgele WHERE üretimini (NOT'lu bileşik ifadeler dahil) VDB ile
>    Python `sqlite3` üzerinde çalıştırır; `SELECT id ... ORDER BY id` kümeleri
>    karşılaştırılır. `4 seed × 1000 = 4000/4000` birebir. SQLite tarafında
>    `PRAGMA case_sensitive_like=ON` ile LIKE duyarlılığı eşitlenir; boş metin
>    kullanılmaz (VDB'de NULL/boş ayrımı yok).
>
> Bulunan/düzeltilen hatalar: AST `NOT` altında `IN/NOT IN` ve
> `BETWEEN/NOT BETWEEN` ile NULL karşılaştırmalarının UNKNOWN'ı FALSE'a
> indirmesi; `AND/OR`'da 3VL eksikliği; JOIN DNF yolunda `NOT (A AND B)`'nin
> yalnız ilk koşulu değiştirmesi ve `NOT IN`/`NOT BETWEEN` terslerinin eksikliği.
> Regresyon: `T09d` (8 test). Derleme: `fpc -Mdelphi -O2 -Fu. -Fu.\dcpcrypt
> -Fu.\dcpcrypt\Ciphers -Fu.\dcpcrypt\Hashes fuzzchk.dpr` ve aynı bayraklarla
> `vdbbatch.dpr`; çalıştırma: `fuzzchk.exe [sorgu] [seed]` ve
> `python sqlite_diff.py [sorgu] [seed]`. SQLancer tarzı tam SQL üretimi hâlâ yok.

### M9 — Gözlemlenebilirlik: Prometheus metrikleri + OpenTelemetry trace
`SHOW STATS` ve `SHOW SLOW QUERIES` iyi bir başlangıç, ama yapısal değiller.
**Çözüm:** `/metrics` (Prometheus text) uç noktası — sorgu sayısı/latency histogramı, kilit
bekleme, sayfa/önbellek isabet oranı, WAL/fsync sayısı, tahsis. Uzun sorgular için
OpenTelemetry span (parse/plan/execute/fetch aşamaları). Modern işletim ve kapasite planlaması için şart.
**Beklenen:** Üretimde görünürlük. **Risk:** Düşük.

### M10 — `GENERATED ALWAYS` (hesaplı kolon) + tam JSONPath
`->`/`@>`/`?` JSONB operatörleri var, ama tam JSONPath yok; hesaplı/sanal kolon da yok.
**Çözüm:** `GENERATED ALWAYS AS (expr) STORED|VIRTUAL` kolonları ve `jsonb_path_query`
tarzı tam JSONPath desteği. Mevcut expression/partial indeks altyapısıyla uyumlu.
**Beklenen:** Şema ifade gücü + uygulama tarafı yükünün motora taşınması. **Risk:** Orta.
> **Durum (2026-10-19):** JSONPath alt kümesi **yapıldı** — `JSON_EXTRACT(json, path)`,
> `JSON_VALUE(json, path)`, `JSON_EXISTS(json, path)`. Destek: `$`, `.ad`, `["ad"]`,
> `[n]` (negatif sondan), `[a:b]` dilimi, `.*` / `[*]` (ara segment dahil),
> `..ad` / `..*` recursive descent, `[?(@.alan op literal)]` filtresi
> (`= == != < <= > >=`; sayı/metin/bool/null). Çoklu sonuç JSON dizi döner.
> Geçersiz
> JSON/yol hata yükseltmez, `''`/`False` döner. Ek olarak JSON sayı ayrıştırması
> locale'den bağımsız hale getirildi (`1.5` TR locale'de reddediliyordu).
> `T112` 36 test. Ek olarak **`GENERATED ALWAYS AS (expr) [STORED|VIRTUAL]`**
> kolonları **yapıldı** (`T117` 19 test): ifade `ExprToText` ile semada hex olarak
> saklanır (6. alan), `INSERT`/`BatchInsert`/`INSERT ... RETURNING`/`UPDATE`
> yollarında `VDbExprVal` ile hesaplanır ve kolon tipine normalize edilir.
> `STORED` gibi davranır; `VIRTUAL` kabul edilir ama aynı şekilde saklanır.
> Açıkça verilen değer yok sayılır (hesaplanan kazanır). `ALTER TABLE ADD COLUMN
> GENERATED` da desteklenir: mevcut satırlar `RewriteTable` sırasında geriye dönük
> hesaplanır (DDL atomik).
>
> **`GENERATED {ALWAYS | BY DEFAULT} AS IDENTITY`** de **yapıldı**: tamsayı
> kolonlarda `ALWAYS` açık değeri reddeder, `BY DEFAULT` açık değeri kabul edip
> sayacı ilerletir; `INSERT`/`BatchInsert`/`COPY`/`RETURNING` yollarında üretilir,
> `UPDATE`/`ON CONFLICT DO UPDATE` identity değerini değiştiremez. Identity
> bayrağı semada kolon bayrak alanının bit2/bit3'ünde saklanır; eski şemalar
> değişmeden okunur. PK tanımsız tabloda identity kolonu satır anahtarı olur ve
> sayaç yeniden açılışta korunur. `ALTER TABLE ADD COLUMN ... IDENTITY` ve
> `START WITH/INCREMENT BY` seçenekleri desteklenmez. Tam JSONPath
> (union, script ifadeleri, filtre fonksiyonları) hâlâ yok.

### M11 — Depolama motoru soyutlama dikişi (geleceğe hazırlık)
§5, "WAL + B-tree'ye tam geçiş"i kapsam dışı bırakıyor — haklı olarak. Ancak bugün
`VDbCore` ile üst katmanlar arasında temiz bir **depolama arayüzü (arayüz/abstract KV-store)**
dikişi yoksa, ileride bir "Yol B (sayfa + buffer pool)" denemesi tüm kodu riske atar.
**Çözüm:** Yeni motor **yazma**; yalnızca `Put/Get/Delete/Scan` çağrılarını bir arayüz
arkasına al ki ikinci bir backend prototiplenebilsin. Bugünün davranışı ve formatı değişmez.
**Beklenen:** Mimari esneklik (opsiyonel, düşük öncelik). **Risk:** Düşük.

### M12 — Dizin fsync (`VDbFlushDir`) — Linux/ext4 yeniden-adlandırma dayanıklılığı
`VDbSync` dosya içeriğini fsync ediyor, ama `ReplaceWith`/`RenameFile` sonrası **dizin girişi**
fsync edilmiyor (`vdb_analiz_raporu.md §2.2`). Güç kesintisinde rename dizin metasında
kaybolabilir (NTFS journal'ı halleder; Linux ext4 hedefleniyorsa gerekli).
**Çözüm:** `VDbFlushDir(AbsPath)`: POSIX'te dizini `O_RDONLY` aç → `fsync` → kapat.
Windows'ta no-op. `ReplaceWith`/`RestoreFrom` sonrası çağır.
**Beklenen:** Çapraz-platform atomiklik garantisi. **Risk:** Düşük (Windows'ta davranış değişmez).
**Durum (2026-10-18):** ✅ **Zaten uygulanmış** — `VDbFlushDir` (`VDbSync.pas:66`) mevcut ve
`VDbCore` içinde rename/restore yollarından çağrılıyor (bkz. §9).

---

## 4. Öncelik Sırası ve Takvim

| Sıra | Madde | Risk | Beklenen Kazanç | Süre (tahmini) |
|---|---|---|---|---|
| 1 | **H9** debug izi temizliği | Sıfır | Gürültü/küçük CPU | 1 saat |
| 2 | **H8** CBO doğrulama test seti | Düşük | Yanlış planı önler | 1–2 gün |
| 3 | ~~**H4** mmap read yolu~~ ✅ deneysel (vars. KAPALI) | Düşük-Orta | Ölçüm: sıcak cache'te kazanç yok (yumuşak sayfa hatası) | — |
| 4 | **H1** vektörleştirilmiş filtre | Orta | Filtreli okuma 3–10x | 3–5 gün |
| 5 | **H2** hash join + hash GROUP BY | Orta | İndekssiz join O(N×M)→O(N+M) | 3–5 gün |
| 6 | **M1** pgwire — v3 + extended ✅, parametre ✅, TLS kalan | Orta | Ekosistem erişimi | 1–2 hafta |
| 7 | **H3** ART/B+tree + zone map | Orta-Yüksek | **zone map ✅** (nokta/aralık ~4,5x); ART kalan | 1–2 hafta |
| 8 | **H5** blok-grup CRC | Orta (format) | Scan/verify CPU ↓ | 1 hafta |
| 9 | ~~**H6** tek sorgu paralelleştirme~~ ✅ yapıldı (tek tablo agrega; 8 işçi 4,08x) | Orta | Büyük tarama ~N× | 1 hafta |
| 10 | **H7** plan önbelleği | Düşük-Orta | Tekrarlı sorgu CPU ↓ | 2–3 gün |
| 11 | **M4/M5** vektör + FTS | Yüksek | Ürün farklılaştırıcı | 2–4 hafta |
| 12 | **M2/M3/M6/M7/M8** | Değişir | Modernleşme | parça parça |

**Ek maddeler (bu turda eklendi — bkz. §2 H10–H14, §3 M9–M12):**

| Sıra | Madde | Risk | Beklenen Kazanç | Süre (tahmini) |
|---|---|---|---|---|
| 13 | **H10** yazma yolu per-satır CPU | Düşük-Orta | INSERT 7,7x → ~2–3x | 3–4 gün |
| 14 | ~~**H13** bulk load yolu~~ ✅ yapıldı (VALUES ~1,55x; **COPY FROM** 100k ~1,95x / 300k ~2,20x) | Düşük | Bulk yükleme 2–3x | 2–3 gün |
| 15 | **H12** blok/sayfa önbelleği | Düşük-Orta | DB ≫ RAM'de büyük kazanç | 2–3 gün |
| 16 | **H14** okuyucu-başına handle + konumsal I/O | Düşük-Orta | Paralel SELECT ölçekler | 2 gün |
| 17 | **H11** free-list / yerinde güncelleme | Orta | UPDATE I/O + dosya boyutu ↓ | 1 hafta |
| 18 | **M9** gözlemlenebilirlik (metrik+trace) — Prometheus metni ✅, HTTP/OTel kalan | Düşük | Üretim görünürlüğü | 2–3 gün |
| 19 | **M12** dizin fsync (Linux dayanıklılık) | Düşük | Çapraz-platform atomiklik | 1 gün |
| 20 | **M10** GENERATED (STORED) ✅, JSONPath alt kümesi ✅; tam JSONPath kalan | Orta | SQL yüzeyi | 1 hafta |
| 21 | **M11** depolama soyutlama dikişi | Düşük | Geleceğe hazırlık | 1 hafta |

> **Not (kapsam dışı bırakılanlar):** `VDbCrc32.BuildTbl` thread-safety ve `SyncWriteInterval`
> grup commit'i **zaten mevcut** (`VDbCrc32.pas:107` `initialization BuildTbl;`;
> `VDbCore.pas:1596` grup commit) — yeniden önerilmedi.

> H5, H3 ve H11 çekirdek/format/recovery dokunduğu için **ayrı dal** ve tam crashtest ile ilerlemeli.
> M1–M12 özellik/katman maddeleri (M11 dahil) mevcut test setini riske atmaz: M11'de davranış
> ve format birebir korunur; geri kalanı zaten özellik katmanıdır.

---

## 5. Bilinçli Olarak YAPILMAYACAKLAR

- **Format v2 / satır sıkıştırma (KR-9):** reddedildi (2026-10-17). DB RAM-ikametli, darboğaz
  CPU; sıkıştırma I/O'dan kâr getirmez, decode CPU'sunu (peek yolunu) yavaşlatır; blast radius
  devasa ve "asla veri kaybı" ile çelişir. Yeniden açma koşulu: DB kalıcı olarak ≫ RAM
  (10M+ satır, soğuk tarama yaygın) iş yükü **gerçekten** oluşursa ve o zaman **önce v2-lite**.
- **WAL + B-tree'ye tam geçiş:** motor sıfırdan yazılır; `vdb_analiz_raporu.md §4.2`'de
  "Yol A (append-only + page)" önerilmiş — mevcut temeli koru.
- **Ayırıcı-atomicity / CRC / GuardSchemaLoss / FK iki aşamalı denetim / AES-256-GCM
  (eski CTR+HMAC okunur) / WAL+PITR:** davranış sözleşmeleri; dokunulmaz (krş.
  `PERFORMANS_YOL_HARITASI.md §"Kesinlikle Dokunulmaması Gerekenler"`).

---

## 6. Benchmark ve Regresyon Protokolü

Her madde için:

```
Öncesi/sonrası ölçüm (bench1m.dpr / bench_profile.exe / speedtest.exe / vsbench):
  - Süre (ms), throughput (satır/sn, sorgu/sn), tepe RAM
  - Tahsis/kopyalama sayısı, dosya okuma sayısı/baytı, seek sayısı, kilit bekleme
  - Hangi iş yükleri geriledi (varsa)
Regresyon kapısı (pazarlık dışı):
  - sqltest  : 2251/2251
  - crashtest: 8/8   (SyncWriteInterval=0 dayanıklılık sözleşmesi)
  - Şifreleme + CRC + hash-çarpışma/"bozukta bağır" testleri açıkken birebir sonuç
```

"10x hızlandı" gibi iddialar **yalnızca aynı ortamda ölçülen** sonuçlarla raporlanır.
Test çalıştırılamadıysa başarılıymış gibi yazılmaz.

---

## 7. Başarı Tanımı

- Filtreli/join'li okumalarda string maddelemesi asgariye iner; bulk iş yükleri SQLite'a yaklaşır.
- Aralık sorguları tam indeks rebuild'ine bağlı olmaktan çıkar.
- **Yazma yolu** (INSERT/UPDATE/bulk load) per-satır CPU ve ölü-alan maliyetinden kurtulur.
- Motor dış araçlara (pgwire) ve kolonlu/analitik ekosisteme açılır.
- Sonuçlar **SQLite'a karşı diferansiyel testle** bağımsız doğrulanır; üretim davranışı metrik/trace ile görünür olur.
- **Veri kaybı sıfır kalır**; `sqltest`/`crashtest` her adımda yeşil.

---

## 8. Tahmini Etki ve SQLite Projeksiyonu (ÖLÇÜM DEĞİL)

> [!WARNING]
> Bu bölümdeki **tüm sayılar mühendislik tahminidir, ölçüm değildir.** Dayanak: mevcut profil
> ayrıştırmaları (örn. `SUM 285 ms ≈ FLOOR 131 + peek ~109 + aritmetik`), `vsbench run9`
> mutlak süreleri ve koddan çıkan maliyet payları. Kesin değer yalnız §6 protokolüyle
> (`bench1m` / `vsbench` / `speedtest` + `sqltest 2426/2426` + `crashtest 8/8`) doğrulanır.
> Faktörler **konservatif → optimist** aralık olarak verilmiştir.

### 8.1 İş yükü-bazlı projeksiyon

Her satır: maddeler uygulanırsa SQLite'a oran (düşük = iyi). Mutlak süreler aynı makine/§6.

| İş yükü | Ölçülen (run9) | Yalnız §8.2 ekleri | **Tam paket (ekler + §2/§3 planı)** |
|---|---:|---:|---:|
| **INSERT 1M (tx)** | 7,73x | 4,5x → 2,1x | **~1,5–2,5x** |
| **UPDATE 100k** | 15,75x | 6,1x → 2,0x | **~1,5–2x** |
| **DELETE 100k** | 14,89x | 7,4x → 2,7x | **~1,5–2x** |
| **SELECT PK 50.000x** | 0,47x ✅ | 0,32x → 0,23x | **~0,15–0,25x (önde)** |
| **RANGE 2000×100** | 14,77x | 5,9x → 2,2x | **~1,2–2x** |
| **COUNT(*) x10** | 19,53x | 10,9x → 5,7x | **~2–4x** |
| **SUM x5** | 8,79x | 5,0x → 2,3x | **~1,2–2x** |
| **ORDER BY ağır** | ölçülmedi | 2x → 5x iyileşme | (E4) |

**Öne çıkanlar:** RANGE/BETWEEN en çok kapanan (doğal sıralı anahtar + kompakt indeks + 64-bit);
UPDATE/DELETE E-maddeleriyle 15x→~2–7x; PK nokta arama zaten önde ve **3–4x öne** çıkar;
filtresiz COUNT ısınmış cache'te zaten O(1) — tablodaki 19,5x **soğuk x10 ve filtreli** içindir.

### 8.2 Ek öneriler (E) — plan dışı, tahmin aşamasında

Kabul edilirse §2/§3'e `H15+` / `M13+` olarak katlanır. §2/§3 maddeleriyle **kısmen örtüşür**
(E3/E4/E5 çekirdeği birlikte değiştirir; faktörleri çarpmak yanıltıcıdır → ölçmek gerekir).

| ID | Madde | Yol | Faktör (kons.→opt.) | Gerekçe |
|---|---|---|---|---|
| E1 | x86_64 hedef derleme | tümü | 1,15→1,35x | SSE2 float (SUM/BETWEEN), daha çok register |
| E2 | `-O3` / inline / check-off | sayısal sıcak yol | 1,05→1,15x | peek döngüsü, FNV, karşılaştırma |
| E3 | KV anahtar düzeni (hash yerine tablo+PK) | PK/tarama/BETWEEN/INSERT | tarama 1,2→1,5x; **BETWEEN 1,8→3,0x** | kayıt başına FNV + çarpışma okuması kalkar |
| E4 | Kompakt `FIndex` hash tablosu | nokta arama + indeks | 1,10→1,25x; **RAM 2–3x ↓** | cache locality, yük faktörü düşer |
| E5 | Kalıcı indeks / hint file | **yalnız açılış** | 5→20x | O(dosya)→O(indeks) tüm-dosya rescan kalkar |
| E6 | DELETE'te yerinde DEL bayrağı | DELETE | 1,25→1,60x | tombstone kaydı (30B+fsync) yazılmaz |
| E7 | Sabit-genişlik same-offset yama | UPDATE | 1,60→2,50x | re-encode+append+ölü-bayt+indeks kayması yok |
| E8 | Ters FK indeksi | FK'lı tabloda yazma | 1,20→1,60x (FK yoksa ~1,0) | O(tablo×FK)→O(değişen kolon) |
| E9 | Sıralama yolu (binary key, top-N, dış sıralama) | ORDER BY/DISTINCT | 2→5x | string matrisi + tam quicksort kalkar |
| E10 | Şema/kolon arama önbelleği | yazma+okuma | 1,05→1,15x | `VDbNorm`/`FindColIdx` string araması kalkar |
| E11 | Arena/bump allocator | filtre/yürütüm | 1,05→1,15x | FPC refcount churn ↓ |
| E12 | İç columnar depolama | analitik tarama | **3→10x** | yalnız gereken kolon okunur (büyük yeniden yazım) |

> E6/E7, §2 **H11** ile; E9, §2 **H1/H3** ile; E3/E4, §2 **H3** + KR-C ile örtüşür. E3 ve E7
> format/CRC/atomiklik dokunduğu için **ayrı dal + tam crashtest** olmadan merge edilmemeli.

### 8.3 Ayrı eksenler (iş yükü dışı)

- **Açılış/restart (E5):** sorgu throughput'una etkisi yok; 1M satırlık DB'de tüm-dosya rescan
  kalkar → **açılış 5–20x hızlanır** (ölçek dosyayla büyür). Sunucu yeniden başlatmada kritik.
- **Bellek/kapasite (E1+E4):** `FIndex` 16-bayt/slot + 64-bit adres → **RAM 2–3x azalır**,
  4 GB tavan kalkar → aynı RAM'de **~5–10x daha büyük DB**.
- **Analitik (E12, opsiyonel büyük kaldıraç):** iç columnar mod açılırsa `SUM/GROUP BY`
  taramaları **3–10x**; ancak bu bir yeniden yazımdır (ayrı dal).

### 8.4 Belirsizlik / dürüstlük notları

1. **Bunlar tahmin.** Gerçek sayı için her madde ayrı commit + öncesi/sonrası `bench1m`/`vsbench`/
   `speedtest` + `sqltest 2426/2426` + `crashtest 8/8`.
2. **Örtüşme:** E3/E4/E5 çekirdeği birlikte değiştirir; faktörleri çarpmak üst sınır verir, gerçek
   daha düşük çıkar → ölçüm şart.
3. **Adil kıyas:** E1 (64-bit) VDB'ye kazandırırken SQLite da 64-bit derlenirse kazanır →
   **mutlak** kazanç korunur, **orana** katkısı küçülür. §6 "aynı ortam" kuralı geçerli.
4. **COUNT:** ısınmış cache'te O(1); soğukta ilk doğrulama ~757 ms. Tablo **soğuk/filtreli** içindir.
5. **En riskli/yüksek getirili:** E3 ve E7 (format/CRC/atomiklik).

---

## 9. Uygulama Durumu ve Kod Denetimi (2026-10-18)

Bu bölüm, §2/§3'teki **her** maddenin kod karşısındaki gerçek durumunu kaydeder; amaç
maddelerin "eksik" sanılıp tekrar uygulanmasını önlemektir.

**Bu oturumda yapılan ve doğrulananlar:**

| Madde | Durum | Kanıt |
|---|---|---|
| **H9** mikro temizlik | ✅ Yapıldı | `TriggersFor`'daki 4 debug `WriteLn` + kullanılmayan `evstr/evlist` kaldırıldı |
| **H10** yazma yolu | 🟡 Adım 1 yapıldı | batch tohumu; INSERT 8836→8112 ms (~%8); **adım 3 zaten vardı** (`FPendingIdx` O(1)); adım 2 (tampon yeniden kullanımı) denendi: 7920→7934 ms, COW nedeniyle kazanç yok → geri alındı |
| **H13** toplu yükleme | ✅ Yapıldı | `ExecFastLiteralInsert` çok-satırlı VALUES (200k: 1665→~1074 ms, ~1,55x; `mrowchk` 0 hata) + **`COPY FROM`** CSV/TEXT (100k: 1036→531 ms ~1,95x; 300k: 3553→1613 ms ~2,20x; `copychk` 17/17) |
| **H2** hash join | ✅ Yapıldı | indekssiz tek-eşitlik INNER/LEFT; JOIN 24.020→98 ms (~245x) |
| **H7** plan önbelleği | ✅ Yapıldı | parametresiz SELECT AST cache; parse ×0,0075→0,0030 ms (~2,5x), API+DDL invalidation |
| **H1** filtreli SELECT + ham yüklem | ✅ Yapıldı | Adım 1 `capSel` erken-çıkış (~5,3x); Adım 2 `TryStreamSelect` ham akış (LIMIT ~58x); Adım 3 ham-yüklem batch motoru (INT/FLOAT, ~4x); Adım 3b TEXT `=`/`<>` (~2,5x); Adım 3c sayısal BETWEEN/IN (~3,1x, IN vs ifade); `rawchk` diferansiyel 29/29 birebir |
| **EK** ifade tip hatası | ✅ Düzeltildi | `ExprResultCtype`: iki taraf da kolon değilken ifade (aritmetik) sayısal kıyaslanır; `(a+0) > 198` 77.800→60.200; `T07` 5 yeni test; `sqltest 2462/2462` |
| **M10 IDENTITY** | ✅ Yapıldı | `GENERATED {ALWAYS\|BY DEFAULT} AS IDENTITY`; ALWAYS açık değeri reddeder, BY DEFAULT sayacı ilerletir; INSERT/BatchInsert/COPY/RETURNING; UPDATE/upsert değişimi reddeder; sema bayrağı bit2/bit3; `T117` 19 test |
| **M12** dizin fsync | ✅ **Zaten vardı** | `VDbFlushDir` (`VDbSync.pas:66`) + `VDbCore.pas:854,1441,1456,1505,2969,3039,3779` |
| **H14** konumsal I/O | ✅ Yapıldı | `VDbPosRead` (OVERLAPPED/pread) `GetSnapshot` (`VDbCore.pas:1765`, P-19), `ScanRawIter` ve **`ScanSnapshot`** (bucket + kayıt-bazı yollar; `FS.Position` paylaşımı kaldırıldı) |

**Kod denetimi sonucu diğer maddeler:**

| Madde | Durum | Kanıt / Not |
|---|---|---|
| H1 vektörleştirilmiş filtre | ✅ Yapıldı | `TryStreamSelect`: ham akış + LIMIT erken durma + AND-tabanlı ham-yüklem batch eleme (INT/FLOAT + TEXT `=`/`<>`); `rawchk` birebir. (Projeksiyon/`EvalExpr` hâlâ string döndürür — çıktı aşaması; planın "tip-tabanlı ara diziler" optimizasyonu opsiyonel kaldı, sonucu değiştirmez.) |
| H2 hash join | ✅ Yapıldı | indekssiz tek-eşitlik INNER/LEFT (`ExecJoinScan`); indeksli/PK hızlı yolu korunuyor |
| H3 ART/B+tree + zone map | 🟡 Kısmi (zone map ✅) | **Bucket zone map**: INT/FLOAT min/max, 2 MB bucket, disk formatı değişmez, `(FIdxVer,DataEpoch)` invalidation + batch'te kapalı; `a=77777` 163,5→31,6 ms (**5,2x**), float aralık 185,4→35,4 ms (**5,2x**); `zonechk` birebir + INSERT/UPDATE/DELETE/ROLLBACK/Compact güvenliği. `FMemIdx` hash + sıralı dizi (KR-C) indeks dilimi ~1300x. **ART/B+tree hâlâ yok** |
| H4 mmap okuma | 🟡 Deneysel (varsayılan KAPALI) | `ScanRawIter` salt-okunur eşleme (`VDbMapFileHandle`/`SetReadMapEnabled`); sıcak-cache'te mmap **yavaş** (11,3→17,3 ms; yumuşak sayfa hatası); `mmapchk` düz+şifreli+Compact birebir; POSIX kapalı |
| H5 blok-grup CRC | ❌ Yok | per-record CRC (aynı zamanda format girdisi) |
| H6 tek-sorgu paralel | ✅ Yapıldı (agrega + indeks sıralaması) | `PrepareRawScan`/`ScanRawPrepared` (offset bucket, aday bir kez); `TryStreamAgg` işçi başına biriktirici + deterministik birleşim; 150k'da 53,0→13,0 ms (8 işçi, **4,08x**); SUM/AVG FLOAT'ta seri (bit-ayni); havuzun auto-reset `RTLEvent` hatası sayma semaforuyla düzeltildi. **H6-sort:** `SortIdxEntries`/`SortIdxEntriesCols` parçalı hızlı sıralama + k-yönlü heap birleştirme; 300k `CREATE INDEX` 708,7→515,2 ms (~1,38x), seri ile birebir |
| H7 plan önbelleği | ✅ Yapıldı | `TVSql.FPlanCache`; parametresiz SELECT, DDL invalidation, `PlanCacheHits` API |
| H8 CBO test seti | ✅ Yapıldı | `VDbCost.pas` + `cbochk` (tahmin↔gerçek, 5 dağıtım) + aralık seçiciliği (ANALYZE min/max) EXPLAIN'de; skew/MCV hâlâ yok (belgelendi) |
| H11 free-list | ❌ Yok | `DeadBytes`/`AutoCompact` mekanizması var; yerinde geri kazanım yok |
| H12 blok/sayfa önbelleği | ✅ Yapıldı | `VDbCore` blok önbelleği: 8 KB blok, CLOCK, O(1) hash, varsayılan 8 MB (`SetReadCacheBlocks`); `cachechk` sıcak ~1,8x + şifreli birebir; `sqltest` (kalan=0) / `crashtest` (8/8) yeşil. mmap (H4) isteğe bağlı/deneysel |
| H13 toplu yükleme | ✅ Yapıldı | çok-satırlı `VALUES (..),(..)` (AST'siz, atomik; 200k ~1,55x) + `COPY FROM` CSV/TEXT dosya akışı (100k ~1,95x, 300k ~2,20x; `copychk` 17/17, atomik rollback) |
| M1 pgwire | 🟡 Kısmi (parametre ✅) | **pgwire v3** (`VDbPgWire.pas`, ayrı port): startup v3 + SSL reddi, trust auth, ParameterStatus, `Q` basit sorgu, RowDescription/DataRow/CommandComplete, ErrorResponse, Terminate; **extended query** (Parse/Bind/Describe/Execute/Close/Flush/Sync); **`$1…` parametreleri** + `ParameterDescription` (gerçek sayı/OID), metin ve int2/int4/int8/float4/float8/bool binary parametre, `?` yer tutucu; **`COPY ... FROM STDIN` / `TO STDOUT` / `COPY (SELECT ...) TO STDOUT`** (CSV/TEXT, CopyIn/CopyOut/CopyFail, atomik `COPY FROM` motoru); `T116` 80 test. SSL/TLS, extended protocol üzerinden COPY, gerçek sonuç tip OID'leri ve binary sonuç formatı yok |
| M2 Arrow/Parquet | ❌ Yok | — |
| M3 WASM | ❌ Yok | — |
| M4 vektör arama | 🟡 Kısmi | `VDbSpatial.pas` + **`VECTOR_DIM`/`VECTOR_NORM`/`VECTOR_DISTANCE`** (JSON sayı dizisi; cosine/l2/l1/dot; `T113` 10 test) var; ANN (HNSW/IVF) ve `VECTOR(n)` tipi yok — tarama tabanlı |
| M5 FTS/BM25 | 🟡 Kısmi | `VDbText.pas` (ifade/analiz) + **`TO_TSVECTOR`/`TS_MATCH` (AND)/`TS_RANK`** (tokenizasyon + Türkçe küçük harf; `T114` 6 test) var; inverted index/BM25 ve phrase/negation yok |
| M6 AEAD/Argon2 | 🟡 Kısmi (AEAD + Argon2 ✅) | **AES-256-GCM** zarfı (`VDBAEAD1`, 96-bit nonce, 128-bit tag; NIST vektörleri `gcmchk`), eski CTR+HMAC okunur; **Argon2id v1.3** (`VDbKdf.pas`, RFC 9106 vektörü `argonchk`) + `.key` v2 (t=3, 64 MiB, p=1; v1 PBKDF2 okunur, `keychk`). Kolon-seviyesi şifreleme yok |
| M7 async sunucu | 🟡 Kısmi | `VDbSqlServer.pas` thread-per-connection; event-loop yok |
| M8 fuzz + diferansiyel | 🟢 Büyük ölçüde | geniş `sqltest` (2462) + `crashtest` (8/8) + `rawchk` (akışlı↔genel diferansiyel 29/29) + `mrowchk` (H13 diferansiyel+atomiklik 8/8) + `copychk` (COPY 17/17) + **`T111` rasgele 120 WHERE yüklemi** (INT/FLOAT/TEXT/BOOL/NULL; ham vs genel birebir) + **`fuzzchk` bağımsız 3VL fuzz (3×1000, 0 fark)** + **`sqlite_diff.py` SQLite diferansiyeli (4×1000, 0 fark)**. SQLancer tarzı tam SQL üretimi yok |
| M9 gözlemlenebilirlik | 🟡 Kısmi | `SHOW STATS` (6→13 metrik: dosya/bellek/blok önbelleği) + `SHOW SLOW QUERIES` + **`TVSql.GetMetricsText` Prometheus exposition** + **`VDbMetricsHttp` ayrı portta `GET /metrics` HTTP ucu** (404 diğer yollar, `Content-Type: text/plain; version=0.0.4`, `T115` canlı soket testi) var; **OpenTelemetry trace yok** |
| M10 GENERATED + JSONPath | 🟡 Kısmi | JSON operatörleri + **JSONPath alt kümesi** (`JSON_EXTRACT`/`JSON_VALUE`/`JSON_EXISTS`; `$ .ad ["ad"] ['ad'] [n] [a:b] [*] [0,2] ['a','b'] .* ..ad ..*` ve `[?(@.alan op literal)]` filtresi; ara segment joker; `T112` 36 test) + locale-bağımsız JSON sayı ayrıştırma + **GENERATED ALWAYS AS (STORED)** (`T117` 19 test; semada 6. alan, INSERT/BatchInsert/RETURNING/UPDATE ve ALTER ADD'de hesaplanır; mevcut satırlar geriye dönük doldurulur) + **GENERATED {ALWAYS\|BY DEFAULT} AS IDENTITY** (ALWAYS açık değeri reddeder; BY DEFAULT sayacı ilerletir; UPDATE/upsert değişimi reddeder; sema bayrağı bit2/bit3, yeniden açılışta sayaç korunur); tam JSONPath (script/fonksiyon) yok |
| M11 depolama soyutlaması | ❌ Yok | `VDbCore` somut KV; arayüz dikişi yok |

**2026-10-19 ek turu:** H13 `COPY FROM` (CSV/TEXT, atomik, 100k ~1,95x / 300k ~2,20x);
H14 `ScanSnapshot` konumsal I/O (`VDbPosRead`; paylaşımlı `FS.Position` kaldırıldı);
M9 `SHOW STATS` 6→13 metrik + `TVSql.GetMetricsText` (Prometheus metni) + `VDbMetricsHttp`
(`GET /metrics`, ayrı port); M10 JSONPath alt
kümesi (`JSON_EXTRACT`/`JSON_VALUE`/`JSON_EXISTS`) + **union seciciler**
(`[0,2]`, `['a','b']`) + locale-bağımsız JSON sayı ayrıştırma;
M4 `VECTOR_DIM`/`VECTOR_NORM`/`VECTOR_DISTANCE` (cosine/l2/l1/dot); M5 `TO_TSVECTOR`/
`TS_MATCH`/`TS_RANK` (index'siz); M8 rasgele 120 WHERE yüklemi diferansiyeli (`T111`) +
bağımsız 3VL fuzz (`fuzzchk`, 3×1000 sorgu, 0 fark; NOT/NULL/IN/BETWEEN düzeltmeleri) +
SQLite diferansiyeli (`sqlite_diff.py`, 4×1000 sorgu, 0 fark);
M1 pgwire v3 + extended query + `$1…` parametreleri + **`COPY ... FROM STDIN` /
`TO STDOUT` / `COPY (SELECT ...) TO STDOUT`** (CSV/TEXT, CopyIn/CopyOut/CopyFail;
`VDbPgWire.pas`, `T116` 80 test);
M10 `GENERATED ALWAYS AS (…) STORED`
+ JSONPath filtre/recursive/slice/union (`T117` 19 test, `T112` 36 test);
**M10 `GENERATED {ALWAYS|BY DEFAULT} AS IDENTITY`** (ALWAYS açık değeri reddeder,
BY DEFAULT sayacı ilerletir; INSERT/BatchInsert/COPY/RETURNING; UPDATE/upsert
değişimi reddeder; sema bayrağı bit2/bit3, yeniden açılışta sayaç korunur);
**M6 AES-256-GCM AEAD + Argon2id + `.key` v2** (`gcmchk` 13/13, `argonchk` 3/3,
`keychk` 12/12; eski CTR+HMAC ve PBKDF2 uyumlu). Kapılar:
**`sqltest 2462/2462 (kalan=0)`**, **`crashtest 8/8`**, **`copychk` 17/17**,
**`rawchk` 29/29**, **`mrowchk` 0 hata**, **`fuzzchk` 3000/3000**,
**`sqlite_diff` 4000/4000**, `hashchk` 80/80, `zonechk` 0 hata. Kalan büyük işler:
H3 ART/B+tree, H5 blok-grup CRC, H11 free-list, M1 TLS, M2 Arrow/Parquet,
M3 WASM, M6 kolon-seviyesi şifreleme, M7 async, M10 tam JSONPath,
M11 depolama soyutlaması.

**Sonraki oturum öncelikleri (kod-denetimi sonrası):** H3 kalanı (ART/B+tree —
indekssiz taramanın A/B fazındaki O(n) dolaşımını da kaldırmak için), H11 (free-list),
H5 (blok-grup CRC), H10 adım 2 (yalnız WAL/pending bayt-kopyalama değişimiyle anlamlı).
Bunlar mimari/format dokunuşu gerektirir ve her biri ayrı dal + §6 protokolü ister.
(H1 — filtreli SELECT + ham-yüklem, H2, H3 **bucket zone map**, H6 tek-sorgu paralel agrega +
indeks sıralaması, H7, H12 blok önbelleği, H13 çok-satırlı VALUES **+ COPY FROM** ve H9
tamamlandı; H4 mmap **denendi** —
doğru/fallback'li ama sıcak cache'te yavaş, varsayılan kapalı.)

---

*Kaynak: `VDbCore.pas`, `VDbTable.pas`, `VDbExecutor.pas`, `VDbXPrims.pas` doğrudan incelenerek;
`PERFORMANS_YOL_HARITASI.md`, `HIZLANDIRMA_TAKIP.md`, `yol_haritasi_hiz.md`, `vdb_analiz_raporu.md`,
`CHANGELOG.md` temel alınarak hazırlanmıştır.*
