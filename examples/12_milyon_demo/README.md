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
| `ORDER BY bakiye DESC LIMIT 100` | 0,39–0,40 s | akışlı top-N; tam sıralama 48–50 s |
| `ORDER BY ad_soyad ASC LIMIT 100` | 0,66–0,67 s | akışlı top-N, metin anahtar |
| `ORDER BY yas DESC LIMIT 100` | 0,39–0,41 s | akışlı top-N |
| `ORDER BY sehir ASC LIMIT 100` | 0,64–0,66 s | akışlı top-N; ilk indeks yüklemesi atlanır |
| `ORDER BY bakiye DESC LIMIT 100 OFFSET 500` | 0,41 s | akışlı top-N + OFFSET |
| `WHERE sehir = 'Ankara' ORDER BY yas DESC LIMIT 100` | 0,78 s | ham WHERE ön elemesi + top-N |
| `ORDER BY sehir, yas DESC LIMIT 100` | 3,9–4,0 s | çok kolonlu top-N (akış dışı) |
| `GROUP BY sehir` | 3,8–4,5 s | tam tablo |
| Şehir + yaş `COUNT(*)` | 0,83–0,98 s | sıcak indeks |

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
3. **Ham WHERE ön elemesi.** `WHERE sehir = 'Ankara'` gibi güvenli
   koşullar satır çözülmeden önce ham baytlarda elenir; hayatta kalan
   adaylar normal `RowMatches` ile yeniden doğrulanır. Bu sayede filtreli
   sıralama da yaklaşık 0,8 s'de kalır.

`ORDER BY sehir ASC LIMIT 100` artık ikincil indeksin ilk bellek içi
kurulumunu beklemez; ham akışlı top-N ile yaklaşık 0,65 s'de yanıt verir.
`ORDER BY id` ise PK indeks yolunu kullanmaya devam eder.

Çok kolonlu `ORDER BY sehir, yas DESC LIMIT 100`, ifade sıralamaları ve
`LIMIT`siz sıralamalar akışlı top-N kapsamı dışındadır; bunlarda tam sıralama
maliyeti (yaklaşık 4 s veya 48 s) geri döner. `GROUP BY`, `ILIKE` ve indekssiz
tam tarama gerektiren işlemler doğası gereği tüm tabloyu okur.

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
girer. `GROUP BY`, `ILIKE` ve indekssiz tam tarama gerektiren işlemler
doğası gereği tüm tabloyu okur.
