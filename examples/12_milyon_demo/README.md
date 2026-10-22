# Örnek 12 — 1.000.000 Kayıtlı GUI Demo

Bu örnek, VDB motorunu gerçek bir masaüstü uygulamasında gösterir:
Lazarus/LCL formu, `TDBGrid`, sayfalama, filtreler, sıralama, detay paneli,
`GROUP BY` özeti, CRUD ve CSV dışa aktarma.

## Ne gösterir?

- `vdb_buyuk` tablosunda **1.000.000 kayıt** (ilk açılışta üretilir)
- Gerçek `TDBGrid` ve sayfa başına 50/100/250/500 satır
- Ad, şehir, yaş aralığı ve bakiye filtreleri
- Sütun başlığına tıklayarak sıralama (ID, ad, şehir, yaş, bakiye)
- Seçili kaydın detay paneli ve çalıştırılan SQL
- Şehir bazlı özet (`GROUP BY`, `COUNT`, `AVG`)
- Yeni kayıt ekleme, seçili kaydı silme
- Görünen sayfayı CSV olarak dışa aktarma
- TR/EN arayüz

## Şema

```sql
CREATE TABLE vdb_buyuk (
  id           INTEGER PRIMARY KEY,
  ad_soyad     TEXT,
  sehir        TEXT,
  yas          INTEGER,
  bakiye       FLOAT,
  kayit_tarihi TEXT,
  aktif        INTEGER
);
CREATE INDEX idx_buyuk_sehir ON vdb_buyuk (sehir);
```

## Derleme

```bat
cd examples\12_milyon_demo
C:\lazarus\lazbuild.exe -B ornek12.lpi
```

## Çalıştırma

```bat
ornek12.exe
```

İlk açılışta tablo yoksa 1.000.000 kayıt üretme onayı gelir. Üretim tek
transaction içinde 1.000'er satırlık çoklu `INSERT` partileriyle yapılır;
şehir indeksi üretimden sonra oluşturulur. Hazır veritabanı sonraki
açılışlarda doğrudan kullanılır.

Sadece veri üretmek için:

```bat
ornek12.exe --seed-only 1000000
```

Sonuç `seed_result.txt` dosyasına yazılır. Veritabanı klasörü
`milyon_demo_db`, sonuç dosyası `seed_result.txt` üretilen dosyalardır ve
Git tarafından izlenmez.

## Ölçülen değerler

Bu değerler geliştirme makinesinde (Windows, yerel disk, Lazarus/FPC 3.2.4)
alınmıştır; farklı donanımda değişebilir.

| İşlem | Süre | Not |
|---|---:|---|
| 10.000 kayıt üretimi | 507–581 ms | |
| 100.000 kayıt üretimi | 6.508–6.908 ms | DB 13.439.859 bayt |
| 1.000.000 kayıt üretimi | 45.288–70.517 ms | DB 135.393.264 bayt |
| `COUNT(*)` | 83–204 ms | tam tablo |
| PK aralığıyla ilk sayfa | 1.244 ms | indeks ilk yükleme |
| PK aralığıyla sonraki sayfa | 1–2 ms | 100 satır |
| `ORDER BY id LIMIT 100` | 1,2 s / 0,11 s | ilk indeks yüklemesi / sonraki sayfa |
| `ORDER BY id LIMIT 100 OFFSET 500000` | 0,11 s | indeks konumuna atlama |
| `ORDER BY bakiye DESC LIMIT 100` | 0,39–0,40 s | akışlı top-N; tam sıralama 5,0–5,7 s |
| `ORDER BY ad_soyad ASC LIMIT 100` | 0,66–0,67 s | akışlı top-N, metin anahtar |
| `ORDER BY yas DESC LIMIT 100` | 0,39–0,41 s | akışlı top-N |
| `ORDER BY sehir ASC LIMIT 100` | 0,64–0,66 s | akışlı top-N; ilk indeks yüklemesi atlanır |
| `ORDER BY bakiye DESC LIMIT 100 OFFSET 500` | 0,41 s | akışlı top-N + OFFSET |
| `WHERE sehir = 'Ankara' ORDER BY yas DESC LIMIT 100` | 0,78 s | ham WHERE ön elemesi + top-N |
| `ORDER BY sehir, yas DESC LIMIT 100` | 0,67–0,74 s | çok kolonlu akışlı top-N (önce 3,9–4,0 s) |
| `WHERE sehir = 'Ankara' ORDER BY yas DESC, bakiye ASC LIMIT 100` | 0,78–0,80 s | çok kolonlu + WHERE ön elemesi |
| `ORDER BY ad_soyad, yas DESC LIMIT 100` | 0,69 s | çok kolonlu akışlı top-N |
| `ORDER BY bakiye DESC` (LIMIT'siz, tam sıralama) | 5,0–5,7 s | FLOAT anahtar ön çözümü (önce 64,2 s) |
| `ORDER BY yas DESC` (LIMIT'siz) | 4,4–5,3 s | tam sıralama |
| `ORDER BY ad_soyad` (LIMIT'siz) | 6,9 s | tam sıralama |
| `GROUP BY sehir` (`COUNT`, `AVG`) | 0,82–0,90 s | H13 tek pass; önceki 3,8–4,5 s |
| `GROUP BY sehir` (`COUNT`) | 0,79–0,82 s | H13 tek pass |
| `GROUP BY yas` (`COUNT`, `MIN`, `MAX`) | 0,64–0,67 s | H13 tek pass |
| `GROUP BY sehir` (aggregate yok) | 0,78–0,82 s | H13 tek pass |
| `WHERE sehir = 'Ankara' GROUP BY yas` | 0,79–0,81 s | H13 + ham WHERE ön elemesi |
| `GROUP BY sehir HAVING COUNT(*) > 100000` | 0,78 s | H15; önceki 3,8 s |
| `GROUP BY sehir HAVING AVG(yas) > 40` (`SUM(bakiye)` ile) | 0,88 s | H15; önceki 17,3 s |
| `GROUP BY sehir HAVING c > 100000` (alias) | 0,77 s | H15, çıktı alias'ı |
| `GROUP BY sehir HAVING COUNT(*) > 50000 AND MAX(bakiye) > 0` | 0,84 s | H15, çok koşullu |
| `SELECT DISTINCT sehir … ORDER BY sehir` | 0,64 s | H16 tek pass; önceki 6,0 s |
| `SELECT DISTINCT sehir` (`ORDER BY`'sız) | 0,64 s | H16 tek pass; önceki 3,8 s |
| `SELECT DISTINCT yas … ORDER BY yas` | 0,48 s | H16 tek pass; önceki 4,6 s |
| `SELECT DISTINCT id … ORDER BY id` | 1,63 s | H16 tek pass; önceki 5,5 s |
| `COUNT(*) WHERE ad_soyad ILIKE '%a%'` | 0,50–0,56 s | H19 ham kesin; önceki 2,8–3,0 s (ilk 6,2 s) |
| `COUNT(*) WHERE ad_soyad LIKE '%a%'` | 0,44–0,45 s | H19 ham kesin; önceki ~2,0 s |
| `COUNT(*) WHERE ad_soyad ILIKE 'A%'` | 0,44 s | H19 ham kesin |
| `COUNT(*)` + GUI bileşik filtre (`ILIKE` + şehir + yaş + bakiye) | 0,52–0,53 s | H19 ham kesin; önceki 0,92–0,95 s (ilk 15–20 s) |
| `COUNT(*) WHERE ad_soyad NOT LIKE '%a%'` | 0,42–0,50 s | H20 ham boolean ağacı; önceki 2,2 s |
| `COUNT(*) WHERE yas < 25 OR yas > 60` | 0,42 s | H20 ham boolean ağacı; önceki 5,2 s |
| `COUNT(*) WHERE yas BETWEEN 30 AND 50` | 0,42 s | H20 ham boolean ağacı; önceki 3,9 s |
| `COUNT(*) WHERE sehir IN ('Ankara','Izmir')` | 0,42–0,44 s | H20 ham boolean ağacı; önceki 1,14 s |
| `COUNT(*) WHERE sehir='Ankara' AND yas BETWEEN 30 AND 50` | 0,41–0,42 s | H20 ham boolean ağacı; önceki 0,92 s |
| `WHERE yas < 25 OR yas > 60 ORDER BY yas DESC LIMIT 100` | 0,47–0,59 s | H21 ham ağaç + top-N; önceki 8,7–10,5 s |
| `WHERE NOT (yas BETWEEN 30 AND 50) ORDER BY yas DESC LIMIT 100` | 0,48–0,53 s | H21; önceki 6,8–8,9 s |
| `WHERE sehir IN ('Ankara','Izmir') ORDER BY yas DESC LIMIT 100` | 0,47–0,52 s | H21; önceki 3,3–4,2 s |
| `WHERE (yas BETWEEN 30 AND 50) OR bakiye > 9000 ORDER BY yas DESC, id ASC LIMIT 100` | 0,52–0,59 s | H21; önceki 9,8–11,5 s |
| `WHERE yas < 25 OR yas > 60 GROUP BY sehir` | 0,61–0,66 s | H21 + H13; önceki 8,3–9,7 s |
| `WHERE NOT (yas BETWEEN 30 AND 50) GROUP BY sehir` | 0,75–0,77 s | H21 + H13; önceki 7,2–9,4 s |
| `SELECT DISTINCT sehir WHERE yas < 25 OR yas > 60` | 0,56–0,61 s | H21 + H16; önceki 8,4–8,7 s |
| `WHERE yas > 60 ORDER BY yas DESC LIMIT 100` | 0,42 s | H21 `RowMatches` atlama; önceki 1,84–2,05 s |
| `ORDER BY sehir LIMIT 10 OFFSET 100000` | 0,61–0,63 s | H22 canlılık denetimli atlama; önceki 0,86–0,89 s |
| `ORDER BY sehir LIMIT 10 OFFSET 500000` | 1,44–1,48 s | H22; önceki 2,77–2,78 s |
| `COUNT(*) WHERE yas IN (0..2000)` | 0,44 s | H23 sıralı küme; önceki 9,86 s |
| `COUNT(*) WHERE bakiye IN (2000 FLOAT)` | 0,44 s | H23 sıralı küme; önceki 254,9 s |
| `COUNT(*) WHERE yas > 40` | 0,39–0,45 s | H18 ham kesin; önceki 2,75 s |
| `COUNT(*) WHERE aktif = 1` | 0,41–0,44 s | H18 ham kesin; önceki 5,6 s |
| `COUNT(*) WHERE bakiye > 5000` | 0,39–0,41 s | H18 ham kesin; önceki 5,75 s |
| `COUNT(*) WHERE sehir = 'Ankara'` | 0,39–0,44 s | H18; 5 s'lik indeks kurulumu yok, önceki 4,98 s |
| `COUNT(*) WHERE sehir='Ankara' AND yas 30..50` | 0,39–0,42 s | H18 ham kesin; önceki 7,9 s |
| `COUNT(*) WHERE aktif=1 AND bakiye>5000` | 0,42–0,44 s | H18 ham kesin |
| `COUNT(*) WHERE yas 30..50 AND bakiye>=1000` | 0,44 s | H18 ham kesin; önceki 9,5–9,9 s |
| PK aralığı `COUNT(*)` | 0–15 ms / 1,1 s | H3 indeks sayımı (sıcak / ilk yükleme) |

## Sorgu hızı nasıl iyileştirildi?

H12 ile motor `ORDER BY ... LIMIT` sorgularında üç yolu kullanır:

1. **İndeks sırası + erken durma.** PK sıralamasında (`ORDER BY id`)
   satırlar indeks sırasıyla okunur ve `LIMIT` dolunca durulur. `OFFSET`
   verilmişse WHERE yokken satırlar tek tek okunmadan doğrudan indeksteki
   konuma atlanır. Bu yüzden `ORDER BY id LIMIT 100 OFFSET 500000` bile
   yaklaşık 0,1 s sürer.
2. **Ham akışlı top-N.** `bakiye`, `ad_soyad`, `yas`, `sehir` gibi küçük
   `LIMIT`li sıralamalarda motor 1.000.000 satırı string matrisine çevirmez.
   Ham kayıt tamponundan yalnız sıralama anahtarı çıkarılır; PK metni yalnız
   heap'e girecek adaylar için üretilir. Yalnız `LIMIT + OFFSET` kadar en iyi
   satır bellekte tutulur. Bu yol `ORDER BY bakiye DESC LIMIT 100` süresini
   yaklaşık 6 s'den 0,4 s'ye, metin sıralamasını 3,6 s'den 0,66 s'ye indirir.
   H12c ile bu yol **birden fazla sıralama kolonuna** da genişletildi:
   `ORDER BY sehir, yas DESC LIMIT 100` 3,9–4,0 s'den 0,67 s'ye iner. Karma
   yön (`ASC` + `DESC`) ve `NULLS FIRST/LAST` desteklenir; ifade ve alias
   anahtarları genel yola düşer.
3. **Ham WHERE ön elemesi.** `WHERE sehir = 'Ankara'` gibi güvenli
   koşullar satır çözülmeden önce ham baytlarda elenir; hayatta kalan
   adaylar normal `RowMatches` ile yeniden doğrulanır. Bu sayede filtreli
   sıralama da yaklaşık 0,8 s'de kalır.

`ORDER BY sehir ASC LIMIT 100` artık ikincil indeksin ilk bellek içi
kurulumunu beklemez; ham akışlı top-N ile yaklaşık 0,65 s'de yanıt verir.
`ORDER BY id` ise PK indeks yolunu kullanmaya devam eder.

H14 ile `LIMIT` olmayan tam sıralamalarda da darboğaz kaldırıldı: tek kolonlu
`FLOAT` sıralamada değerler satır başına **bir kez** sayıya çevrilir ve
karşılaştırma artık her seferinde metni yeniden ayrıştırmaz. `ORDER BY bakiye
DESC` (1.000.000 satır) 64,2 s'den 5,0–5,7 s'ye iner.

H13 ile tek tablolu `GROUP BY` sorguları da ham akıştan tek pass'te
hesaplanır. 1.000.000 satır önce string matrisine çevrilmez; her satır için
grup anahtarı çıkarılır, hash tablosunda grup bulunur ve `COUNT`, `SUM`,
`AVG`, `MIN`, `MAX` sayaçları doğrudan güncellenir. `WHERE` koşulu güvenli
biçimde ham baytlarda ön elenir. Bu yol `GROUP BY sehir` süresini yaklaşık
3,8–4,5 s'den 0,8 s'ye indirir.

H15 ile `HAVING` de aynı tek pass içinde uygulanır: HAVING'deki
`COUNT`/`SUM`/`AVG`/`MIN`/`MAX` için ek sayaçlar kurulur ve grup satırı
hazırlandıktan sonra koşul değerlendirilir. Böylece `HAVING COUNT(*) > …`
3,8 s yerine yaklaşık 0,78 s, `AVG(yas)`+`SUM(bakiye)` koşulu 17,3 s yerine
yaklaşık 0,88 s sürer. `JOIN`, `DISTINCT`, `DISTINCT`/`FILTER` içeren
aggregate'ler, ifade argümanlı veya metin/BOOL `MIN`/`MAX`, alt sorgu/pencere
içeren `HAVING` ve karmaşık `GROUP BY` biçimleri genel yola düşer; `ILIKE` ve
indekssiz tam tarama gerektiren işlemler doğası gereği tüm tabloyu okur.

H16 ile tek kolonlu `SELECT DISTINCT kolon` sorguları da ham akıştan tek
pass'te tekilleştirilir. Motor tüm satırları string matrisine çevirip
sıralamak yerine yalnız seçilen kolonu çıkarır ve değerleri hash kümesinde
tutar; `ORDER BY` aynı kolon/alias üzerindeyse yalnız tekilleşmiş değerler
sıralanır. `LIMIT/OFFSET` tekilleştirmeden sonra uygulanır. Böylece
`SELECT DISTINCT sehir … ORDER BY sehir` 6,0 s yerine yaklaşık 0,64 s,
`DISTINCT yas` 4,6 s yerine 0,48 s sürer. Çok kolonlu/ifadeli DISTINCT,
JOIN, `GROUP BY`, pencere, set-op ve RLS genel yola düşer; `WHERE` varsa
satır yine `RowMatches` ile doğrulanır. Şifreli kolonlarda değer çözülerek
tekilleştirilir; BOOL sıralaması ise genel yoldaki mevcut davranışı korumak
için akışlı yola alınmaz.

H17 ile tek tablolu saf `COUNT(*)` sorguları `WHERE` ile birlikte ham akıştan
tek pass'te sayılır. Motor tüm satırları string matrisine çevirmez; yalnız
`WHERE`'in referans verdiği kolonları çözer. `AND` ile bağlanan basit sayısal
karşılaştırmalar ve ASCII metin eşitliği ham baytlarda ön elenir; kalan adaylar
tam `EvalBool` ile doğrulanır. H17 tek başına `ILIKE '%a%'` sayımını 6,2 s'den
2,8–3,0 s'ye, GUI'nin bileşik filtre sayımını 15–20 s'den ~0,92 s'ye indirdi;
H19 bu iki durumu sırasıyla 0,50–0,56 s ve 0,52–0,53 s'ye taşıdı. Alt sorgu,
pencere, aggregate, `TS_MATCH`, JOIN, `GROUP BY`,
`DISTINCT`, `ORDER BY`, `LIMIT/OFFSET`, VIEW ve RLS içeren sorgular genel yola
düşer. Ayrıca indeksli sayım yolu (H3) artık farklı kolon/OR/IN/LIKE içeren
`WHERE` için indeks kurmaya çalışmadan H17'ye devreder.

H18 ile `WHERE` **tamamen** ham çözülebilir koşullardan oluşuyorsa (AND'lenen
`INT`/`FLOAT` karşılaştırmaları ve ASCII `TEXT` `=`/`<>`) hiç string çözme ve
`EvalBool` yapılmadan sayılır. `NULL`/boş değerler genel yolla aynı 3-değerli
mantıkla işlenir; tip uyuşmazlığı, UTF-8 kayıt, 2^53 dışı `INT` veya ham
olmayan bir koşul varsa o satır eski çözme+`EvalBool` yoluna düşer. H3 de PK
dışı indeks hazır değilse tüm tabloyu tarayan indeks kurulumunu başlatmaz;
PK sayımları indeks hızlı yolunda kalır. Böylece `yas > 40` 2,75 s yerine
0,39–0,45 s, `aktif = 1` 5,6 s yerine 0,41–0,44 s, `bakiye > 5000` 5,75 s
yerine 0,39–0,41 s, `sehir = 'Ankara'` 4,98 s yerine 0,39–0,44 s sürer ve
ilk şehir filtresindeki ~5 s'lik indeks kurulumu ortadan kalkar.

H19 ile saf ASCII kayıt ve ASCII desende `LIKE`/`ILIKE` de ham baytlarda,
`VDbLikeMatch` ile birebir aynı `%`/`_` geri-izlemesiyle değerlendirilir.
`ILIKE` Türkçe duyarlı küçültmeyi aynen uygular (`I` → UTF-8 `ı`, `A–Z` →
`a–z`); böylece `ILIKE`/`LIKE` içeren WHERE de H18'in string çözmeden sayma
yoluna girer. UTF-8 kayıt, ASCII dışı desen, tip uyuşmazlığı veya uzun satırda
o satır çözme+`EvalBool` yoluna düşer. Böylece `ILIKE '%a%'` 2,8–3,0 s yerine
0,50–0,56 s, `LIKE '%a%'` ~2,0 s yerine 0,44–0,45 s, GUI bileşik filtre
0,92–0,95 s yerine 0,52–0,53 s sürer.

H20 ile saf `COUNT(*)` yolunda WHERE artık yalnız AND zinciri değil, **tam
boolean ağacı** olarak ham baytlardan değerlendirilir. `AND`/`OR`/`NOT` SQL'in üç değerli mantığıyla
(`TRUE`/`FALSE`/`UNKNOWN`) çözülür; `NOT LIKE`, `NOT IN`, `NOT BETWEEN`,
`BETWEEN`, `IN`, `IS NULL`/`IS NOT NULL` ve bunların `OR` ile karışımları
`EvalBool` çağrılmadan sayılır. `IN`, genel yoldaki string eşitliğiyle birebir
aynı kalsın diye yalnız güvenli aralıktaki `INT` ve ASCII `TEXT` için `=` /
`OR` yapraklarına açılır; `FLOAT IN` ve 64+ öğeli listeler bu turda genel yola
düşer (H23 ile tamamlandı). `BETWEEN` iki
karşılaştırmaya açılır; iki sınırdan biri `NULL` ise genel yolun kısa devre
davranışı korunarak sonuç `UNKNOWN` olur. UTF-8 kayıt/desen, 2^53 dışı `INT`
veya tip uyuşmazlığında o satır çözme+`EvalBool` yoluna düşer. Böylece
`NOT LIKE '%a%'` 2,2 s yerine 0,42–0,50 s, `yas < 25 OR yas > 60` 5,2 s
yerine 0,42 s, `yas BETWEEN 30 AND 50` 3,9 s yerine 0,42 s, `sehir IN (...)`
1,14 s yerine 0,42–0,44 s sürer.

H21 bu ham boolean ağacını yalnız `COUNT(*)` ile sınırlı bırakmaz; filtreli
SELECT, H12b/H12c sıralama, H13 `GROUP BY` ve H16 `DISTINCT` yolları da aynı
ağacı kullanır. `rvFalse`/`rvUnknown` satırlar hiç çözülmeden elenir; `rvTrue`
satırı çözülür ama `RowMatches` atlanır; güvenli olmayan yaprakta eski ham ön
eleme + `RowMatches` yoluna düşülür. Bu yüzden `OR`/`NOT`/`BETWEEN`/`IN`
içeren sorgular yalnız eşleşen satırları çözer. 1M demoda
`yas < 25 OR yas > 60 ORDER BY yas DESC LIMIT 100` 8,7–10,5 s yerine
0,47–0,59 s; `NOT (yas BETWEEN 30 AND 50)` 6,8–8,9 s yerine 0,48–0,53 s;
`(yas BETWEEN 30 AND 50) OR bakiye > 9000` 9,8–11,5 s yerine 0,52–0,59 s;
aynı filtrelerle `GROUP BY` 7,2–9,7 s yerine 0,61–0,77 s, `DISTINCT`
7,1–8,7 s yerine 0,56–0,61 s sürer. Basit `WHERE yas > 60` bile
`RowMatches` atlandığı için sıralamada 1,84–2,05 s yerine 0,42 s,
`GROUP BY`'da 1,97–2,06 s yerine 0,52–0,53 s, `DISTINCT`'te 5,59–5,78 s
yerine 0,48–0,50 s olur.

H22, `WHERE` yokken ikincil indeks sırasıyla okunan derin `OFFSET`'te
satırları tam çözmeden indeks girdilerini atlar. Her atlanan girdi için
`FT.Kv.Get` + `VDbPeekRawRowP` ile hafif canlılık denetimi yapılır; eski
şema veya bozuk satırda `FT.ReadRow` ile aynı görünürlük kararına düşülür.
Silinmiş satırların ölü indeks girdileri `OFFSET` sayımını bozmaz. PK yolu ve
`WHERE`'li ikincil indeks yolu değişmez. 1M demoda
`ORDER BY sehir LIMIT 10 OFFSET 100000` 0,86–0,89 s yerine 0,61–0,63 s,
`OFFSET 500000` 2,77–2,78 s yerine 1,44–1,48 s sürer.

H23 `IN`/`NOT IN` listesini kolon tipine göre tek bir sıralı kümede tutar:
`INT`, `FLOAT` ve ASCII `TEXT` için ikili arama yapılır; 64 öğe sınırı
kaldırılmıştır ve satır başına maliyet O(log n)'dir. `NULL`/boş metin öğesi
`UNKNOWN` semantiğini korur (eşleşme yoksa `UNKNOWN`, eşleşme varsa `TRUE`);
ASCII dışı metin, 2^53 dışı `INT`, tip uyuşmazlığı ve NaN genel yola düşer.
2000 öğeli listelerde `yas IN (0..2000)` 9,86 s yerine 0,44 s,
`bakiye IN (2000 FLOAT)` 254,9 s yerine 0,44 s sürer.

> `SUM`/`AVG` kayan noktalı sonuçlarda, akışlı toplama sırası nedeniyle
> genel yola göre son ondalık hanede küçük bir yuvarlama farkı görülebilir;
> bu davranış H6/H12 akışlı toplamalarıyla aynıdır. `COUNT`, `MIN`, `MAX`
> ve tam sayı toplamları bu durumdan etkilenmez.

Demo, ID sıralı sayfalarda `LIMIT/OFFSET` yerine PK aralığını kullanmaya
devam eder; bu, sayfa numarasından bağımsız olarak yalnızca sayfa kadar
satır okur:

```sql
SELECT ... FROM vdb_buyuk
WHERE id >= 1 AND id < 101
ORDER BY id;
```

Şehir filtresi `WHERE sehir = ...` için ham ön eleme kullanılabilir;
filtre sonucu küçük `LIMIT`li bir sıralamaya giriyorsa akışlı top-N devreye
girer. Basit `GROUP BY` sorguları H13 ile tek pass'te, `WHERE`'li saf
`COUNT(*)` sorguları H17 ile tek pass'te tamamlanır; `ILIKE` ve indekssiz tam
tarama gerektiren işlemler doğası gereği tüm tabloyu okur, ancak H17 bu
durumda da satır matrisi kurmaz.
