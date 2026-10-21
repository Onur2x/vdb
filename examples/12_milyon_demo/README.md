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
| `ORDER BY bakiye DESC LIMIT 100` | 5,7–7,0 s | top-N; tam sıralama 48–50 s |
| `ORDER BY ad_soyad ASC LIMIT 100` | 3,6–4,0 s | top-N, indeks yok |
| `ORDER BY yas DESC LIMIT 100` | 5,5–5,8 s | top-N, indeks yok |
| `ORDER BY sehir ASC LIMIT 100` | 5,4 s / 0,41 s | ilk indeks yüklemesi / sonraki |
| `ORDER BY sehir, yas DESC LIMIT 100` | 3,9–4,0 s | top-N |
| `GROUP BY sehir` | 3,8–4,5 s | tam tablo |
| Şehir + yaş `COUNT(*)` | 0,83–0,98 s | sıcak indeks |

## Sorgu hızı nasıl iyileştirildi?

H12 ile motor `ORDER BY ... LIMIT` sorgularında iki yolu kullanır:

1. **İndeks sırası + erken durma.** `ORDER BY id` veya `ORDER BY sehir`
   indeksli bir kolondaysa satırlar indeks sırasıyla okunur ve `LIMIT`
   dolunca durulur. PK sıralamasında `OFFSET` verilmişse WHERE yokken
   satırlar tek tek okunmadan doğrudan indeksteki konuma atlanır. Bu yüzden
   `ORDER BY id LIMIT 100 OFFSET 500000` bile yaklaşık 0,1 s sürer.
2. **Top-N heap.** `bakiye`, `ad_soyad`, `yas` gibi indekssiz kolonlarda
   tüm 1.000.000 satır taranır, ancak yalnız `LIMIT + OFFSET` kadar en iyi
   satır bellekte tutulur. Tam sıralama yerine `O(N log K)` çalışır:
   `bakiye` sıralaması 62 s yerine yaklaşık 6 s'ye iner.

İlk `ORDER BY id`/`ORDER BY sehir` sorgusu indeks kaynağını belleğe
yüklediği için 1–5 s sürebilir; aynı oturumdaki sonraki sayfalar hızlıdır.
`ORDER BY ...` için uygun indeks yoksa motor hâlâ tüm tabloyu tarar;
`LIMIT` yoksa tam sıralama maliyeti (yaklaşık 48 s) geri döner.

Demo, ID sıralı sayfalarda `LIMIT/OFFSET` yerine PK aralığını kullanmaya
devam eder; bu, sayfa numarasından bağımsız olarak yalnızca sayfa kadar
satır okur:

```sql
SELECT ... FROM vdb_buyuk
WHERE id >= 1 AND id < 101
ORDER BY id;
```

Şehir filtresi `idx_buyuk_sehir` indeksini kullanabilir; filtre sonucu
`ORDER BY id` ile sıralanacaksa eşleşen satırlar sıralanır. `GROUP BY`,
`ILIKE` ve indekssiz sıralamalar doğası gereği tam tarama yapar.
