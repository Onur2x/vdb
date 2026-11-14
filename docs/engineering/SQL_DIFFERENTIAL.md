# PostgreSQL diferansiyel korpusu (Phase 5)

Bu belge `p5-differential` kaleminin hangi dosyayla ve hangi kapıyla
kanıtlandığını kaydeder. Amaç iddia değil, **kayıtlı sözleşme**: her SQL
durumunun PostgreSQL karşısındaki durumu tek bir dosyada yazılıdır ve her
koşumda yeniden ölçülür.

## 1. Dosyalar

| Dosya | Rol |
|---|---|
| `tests/sql_differential/corpus.txt` | Diferansiyel korpus: durum, kurulum, sorgu, pinli PG beklentisi, VDB beklentisi, sapma notu |
| `tests/sql_differential/sql_differential.lpr` | Kapı: VDB'yi koşar, yönetişim kurallarını denetler, isteğe bağlı canlı PG karşılaştırması |
| `tests/run_gates.sh` | `sql_differential` derleme + koşum kapısı |

## 2. Kapı neyi reddeder

Her koşumda üç tür kontrol vardır:

1. **Ölçüm**: VDB, korpustaki kurulum + sorguyu gerçekten koşar; sonuç
   `--VDB` beklentisiyle birebir karşılaştırılır (ızgara ya da
   `error:<kod>`).
2. **`kind=same` tutarlılığı**: `--PG` ile `--VDB` **aynı** olmalıdır. Aynı
   sonucu veren bir durum yanlışlıkla "sapma" diye işaretlenemez.
3. **`kind=diff` yönetişimi**: iki beklenti **farklı** olmalı ve `--NOTE`
   dolu olmalıdır. Bildirilmemiş ya da gerekçesiz bir sapma kapıyı kırar.

Böylece "sessiz davranış değişikliği" imkânsızdır: VDB'nin sonucu değişirse
ya ölçüm kontrolü ya da yönetişim kontrolü FAIL verir; geçmek için korpusun
açıkça güncellenmesi gerekir.

## 3. Canlı PostgreSQL doğrulaması

Korpus, psql'in ızgara biçimiyle **birebir** uyumlu bir betik üretebilir
(`unaligned` + `tuples_only` + `fieldsep=','` + `recordsep='|'`):

```sh
# 1) psql betigini uret
build/gates/sql_differential/sql_differential tests/sql_differential/corpus.txt \
  --emit=pg_corpus.sql

# 2) PostgreSQL uzerinde kos
psql -d postgres -f pg_corpus.sql > pg.out

# 3) ciktiyi pinli degerlerle ve VDB ile karsilastir
build/gates/sql_differential/sql_differential tests/sql_differential/corpus.txt \
  --pg=pg.out
```

`--pg` iki ayrı iddia üretir:

| Kontrol | Ne der |
|---|---|
| `<durum>/pg-pinned` | Canlı PostgreSQL, korpustaki pinli `--PG` değeriyle aynı mı? (sürüm kayması / yazım hatası) |
| `<durum>/pg-live` | Canlı PostgreSQL, VDB ile aynı mı? (yalnız `kind=same` durumlar için) |

VDB'nin hata verdiği durumlar (ör. `SUBSTR`) psql betiğine **alınmaz**;
bunların canlı karşılaştırması yoktur ve raporda sayıları görünür.

### Dürüst sınır

Bu ortamda `psql` **yoktur** (`where psql` ve WSL `command -v psql` boş).
Bu yüzden:

- Varsayılan kapı koşumu PostgreSQL'e **bağlanmaz**. `--PG` değerleri
  PostgreSQL dokümantasyonuna göre yazılmıştır; canlı ölçüm değildir.
- Kapı bunu gizlemez: sonuç satırı `pg=not-run` yazar ve `NOT-RUN pg-live`
  satırı basılır.
- `--emit`/`--pg` yolu **yerelde sentetik bir psql çıktısıyla** uçtan uca
  doğrulanmıştır (55 PASS / 0 FAIL): ayrıştırma, eşleştirme ve iki iddia
  çalışır. Bu, "canlı PostgreSQL'de koştu" kanıtı **değildir**.
- Canlı koşum, `psql` bulunan bir ortamda yapılmalı ve `--PG` değerleri o
  koşumun çıktısıyla tazelenmelidir. O ana kadar bu kalem "korpus + kapı
  hazır, canlı diferansiyel koşulmadı" olarak okunmalıdır.

## 4. Korpus (14 durum)

| Durum | Kind | PG | VDB |
|---|---|---|---|
| `arith_add` | same | `3` | `3` |
| `arith_precedence` | same | `3` | `3` |
| `int_div` | same | `3` | `3` |
| `agg_basic` | same | `3,6,1,3` | `3,6,1,3` |
| `distinct_rows` | same | `a\|b` | `a\|b` |
| `limit_offset` | same | `2\|3` | `2\|3` |
| `empty_where` | same | (boş) | (boş) |
| `coalesce_null` | same | `5` | `5` |
| `like_case_sensitive` | same | `1` | `1` |
| `null_order_asc` | diff | `1\|2\|` | `\|1\|2` |
| `concat_operator` | same | `ab` | `ab` |
| `groupby_alias` | diff | `1,2\|2,1` | `error:ecColumnNotFound` |
| `substr_unsupported` | diff | `bcd` | `error:ecUnsupported` |
| `div_by_zero` | diff | `error:division by zero` | `error:ecMathError` |

Bildirilmiş 4 sapma:

1. **NULL sıralaması** — PostgreSQL ASC'de NULL'ları sona atar (NULLS LAST
   varsayılan); VDB başa alır ve `NULLS LAST` desteklenmez.
2. **`GROUP BY` çıktı alias'ı** — PostgreSQL kabul eder; VDB
   `ecColumnNotFound` ile reddeder (`ORDER BY` alias'ı kabul edilir).
3. **`SUBSTR`/`SUBSTRING`/`TRIM`** — PostgreSQL sunar; VDB
   `ecUnsupported` ile reddeder.
4. **Sıfıra bölme hata kodu** — PostgreSQL SQLSTATE 22012; VDB
   `ecMathError`. İkisi de gürültülüdür, sessiz 0/sonsuz üretimi yoktur.

İlk yazımda iki durum yanlış "sapma" sanılmıştı: `7 / 2` ve `LIKE`
harf duyarlılığı. Ölçüm, VDB'nin bu iki noktada PostgreSQL ile **aynı**
davrandığını gösterdi (`int_div` → `3`, `like_case_sensitive` → `1`) ve
korpus ölçüme göre düzeltildi. Bu, kapının varsayımı değil ölçümü
zorladığının kanıtıdır.

## 5. Kapsam dışı (dürüst sınırlar)

- **Canlı PostgreSQL koşumu** bu depoda yapılmadı (psql yok).
- **Minimize edilmiş regresyon korpusu** (fuzz girdilerinin delta-debugging
  ile küçültülüp kalıcılaştırılması) ayrı bir kalemdir; `sql_fuzz` hâlâ
  yalnız süreç-içi dayanıklılık ölçer.
- **Eşzamanlılık / çoklu oturum** bu kapının konusu değil.
- Korpus "tam SQL" iddiası taşımaz; yeni bir davranış eklenirse buraya satır
  eklenmelidir.
- Tip/kolasyon ayrıntıları (numeric ölçek, tarih biçimleri, unicode
  kolasyon) bu korpusta yoktur.
