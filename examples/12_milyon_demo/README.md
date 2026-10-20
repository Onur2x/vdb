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
| `ORDER BY id LIMIT 100` | 6.024–7.399 ms | Seq Scan + Sort |
| `ORDER BY bakiye DESC LIMIT 100` | 62.565–62.743 ms | 1M satır sıralama |
| `GROUP BY sehir` | 8.917–9.091 ms | tam tablo |
| Şehir + yaş `COUNT(*)` | 816–6.284 ms | soğuk/sıcak indeks |

## Neden bazı sorgular yavaş?

Motor, `ORDER BY ... LIMIT ... OFFSET ...` sorgularında henüz “index order +
erken durma” (top-N / limit pushdown) optimizasyonunu uygulamıyor. Örneğin
`ORDER BY id LIMIT 100 OFFSET 0` planı şöyledir:

```text
Seq Scan on vdb_buyuk
Sort
Limit
```

Bu yüzden her sayfa 1.000.000 satırı tarayıp sıralayabilir. Aynı durum
`bakiye` ve `ad_soyad` sıralamalarında da geçerlidir; `bakiye` sıralaması
yaklaşık 62 saniye sürer.

Demo, **filtresiz ve ID sıralı** sayfalarda bu maliyetten kaçınmak için
`LIMIT/OFFSET` yerine PK aralığı kullanır:

```sql
SELECT ... FROM vdb_buyuk
WHERE id >= 1 AND id < 101
ORDER BY id;
```

Bu sorgu PK indeksini kullanır ve yalnızca sayfa kadar satır okur. Filtre
veya farklı sıralama seçildiğinde motorun mevcut tam tarama davranışı
devreye girer.

Şehir filtresi `idx_buyuk_sehir` indeksini kullanabilir; ancak filtre
sonucu `ORDER BY id` ile sıralanacaksa yine tüm eşleşen satırlar
sıralanabilir. `GROUP BY` ve `ILIKE` da doğası gereği tam tarama yapar.
