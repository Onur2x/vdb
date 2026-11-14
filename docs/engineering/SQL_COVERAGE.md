# SQL kapsam ve davranis matrisi

Bu belge, desteklenen SQL yuzeyinin **yurutulebilir sozlesmesini** kaydeder.
Sozlesme `tests/sql_matrix/sql_matrix.lpr` kapisidir: her satir beklenen
tam sonuc izgarasini (ya da beklenen hata kodunu) soyler. Bir davranis
degisirse kapi kirilir; yani asagidaki tablo "iddia" degil, kosan testtir.

```sh
./tests/run_gates.sh          # sql_matrix dahil tum kapilar
```

Son durum (bu commit): **61 PASS, 0 FAIL**, iki platformda da yesil
(Windows i386 / FPC 3.2.4, WSL x86_64 Linux / FPC 3.2.2).

Izgara bicimi: hucreler `,` ile, satirlar `|` ile ayrilir. `''` = bos kume.

## 1. DDL

| Durum | Beklenen | Plan |
|---|---|---|
| `CREATE TABLE` + PK + INSERT + `SELECT ... WHERE pk` | `ali` | `point_select` |
| `INTEGER` / `REAL` / `TEXT` kolonlari ve degerleri | `7,2.5,x` | `stream_select` |
| `BLOB` kolon tanimi | bos kume | `stream_agg` |
| `CREATE TABLE IF NOT EXISTS` iki kez | bos kume | `stream_agg` |
| `CREATE INDEX` (indekssiz tabloda WHERE) | `a` | `general` |
| `ALTER TABLE ... ADD COLUMN` | `n` | `stream_select` |
| `DROP TABLE` | hatasiz | - |

## 2. DML

| Durum | Beklenen | Plan |
|---|---|---|
| Cok satirli `INSERT` | 3 satir | `stream_agg` |
| Kolon listesiz `INSERT` | `1,a` | `stream_select` |
| `UPDATE ... WHERE` | `z\|b` | `general` |
| `DELETE ... WHERE` | `1\|3` | `general` |
| `INSERT ... SELECT` | `5\|6` | `general` |
| `INSERT ... RETURNING` (tek satir) | `1` | - |
| `INSERT ... RETURNING` (cok satir) | `1\|2` | - |

`RETURNING` INSERT/UPDATE/DELETE'de uygulanmistir (bkz.
`SQL_STUB_SURFACE.md`, R1).

## 3. SELECT

| Durum | Beklenen | Plan |
|---|---|---|
| Sabit ifade `SELECT 1 + 2` | `3` | - |
| Operator onceligi `7 - 2 * 2` | `3` | - |
| `ORDER BY ... DESC` | `3\|2\|1` | `general` |
| `LIMIT` | `1\|2` | `stream_topn` |
| `LIMIT ... OFFSET` | `2\|3` | `stream_topn` |
| `DISTINCT` | `a\|b` | `stream_distinct` |
| `COUNT/SUM/MIN/MAX` | `3,6,1,3` | `stream_agg` |
| `AVG` | `2` | `stream_agg` |
| `WHERE` karsilastirma (`>`, `<>`, `AND`) | `3` | `stream_select` |
| `BETWEEN` | `2\|3\|4` | `general` |
| `IN (liste)` | `1\|3` | `general` |
| `LIKE 'a%'` | `ali\|ayse` | `general` |
| `IS NULL` / `IS NOT NULL` | `2` | `stream_select` |
| `GROUP BY` + `SUM` | `a,3\|b,5` | `stream_groupby` |
| `HAVING SUM(...)` | `b` | `stream_groupby` |
| `INNER JOIN` | `a1,b1` | `stream_join` |
| `LEFT JOIN` (eslesmeyen -> bos) | `1,b1\|2,` | `stream_join` |
| Alt sorgu `IN (SELECT ...)` | `2\|3` | `general` |
| Skaler alt sorgu | `6` | - |
| `UNION` (tekrari atar) | `1\|2\|3` | `general` |
| `UNION ALL` (tekrari korur) | `1\|2\|2\|3` | `general` |
| `CASE WHEN ... THEN ... ELSE ... END` | `diger\|iki\|diger` | `general` |
| `UPPER` / `LOWER` / `LENGTH` | `ABC,abc,3` | `stream_select` |
| `LENGTH/UPPER/LOWER/ABS/ROUND` birlikte | `3,ABC,abc,3,3` | `stream_select` |
| `COALESCE` (NULL -> varsayilan) | `yok\|x` | `stream_select` |
| Cikti alias'i + `ORDER BY` alias | `1\|2` | `general` |
| `WHERE` + agregat | `6` | `stream_groupby` |

## 4. Islem (transaction)

| Durum | Beklenen | Plan |
|---|---|---|
| `BEGIN` + `INSERT` + `COMMIT` | 1 satir kalir | `stream_agg` |
| `BEGIN` + `INSERT` + `ROLLBACK` | yalniz onceki satir | `stream_agg` |

## 5. Hata yollari (gurultulu ret)

| Durum | Hata kodu |
|---|---|
| Olmayan tablo (`SELECT`) | `ecTableNotFound` |
| Olmayan tablo (`INSERT`) | `ecTableNotFound` |
| Olmayan kolon (dolu tablo) | `ecColumnNotFound` |
| PK ihlali | `ecDuplicatePrimaryKey` |
| `NOT NULL` ihlali | `ecNotNullViolation` |
| `UNIQUE` indeks ihlali | `ecUniqueViolation` |
| Sozdizimi hatasi | `ecSyntaxError` |
| `DROP TABLE IF EXISTS` (yok) | sessiz gecer (sozlesme) |
| Bilinmeyen skaler fonksiyon (`SUBSTR`) | `ecUnsupported` |

## 6. Referans dogrulamasi (Phase-5 duzeltmesi)

**Bulunan sessiz yanlis sonuc:** Kolon cozumu satir basina yapildigi icin,
tablo **bos** iken olmayan bir kolon hicbir hata uretmiyordu:

```sql
CREATE TABLE e (id INTEGER, v TEXT);
SELECT yok_kolon FROM e;            -- once: bos kume (hata yok)
SELECT SUM(yok_kolon) FROM e;       -- once: tek satir, BOS hucre
SELECT id FROM e WHERE yok_kolon=1; -- once: bos kume
```

`0 satir` ile `bozuk sorgu` ayirt edilemiyordu; `SUM` ornegi dogrudan yanlis
deger uretiyordu. Duzeltme: `VDbExecutor.ValidateStmtRefs` /
`ValidateExprCols` hazirlik asamasinda (satir okumadan once) secim listesi,
`WHERE`, `GROUP BY`, `HAVING`, `QUALIFY` ve `ORDER BY` referanslarini
kapsama gore dogrular; cozulemeyen ad `ecColumnNotFound` firlatir. View'de
kapsam view'in cikti kolonlaridir. Nitelikli referansta niteleyici bu
tabloya/aliase ait degilse dogrulama atlanir (korelasyonlu alt sorgu).
Alt sorgu dugumlerine inilmez; onlar kendi calistirilmalarinda dogrulanir.

Kapi bunu kilitler:

| Durum | Beklenen |
|---|---|
| `R1` bos tabloda olmayan kolon (`SELECT`) | `ecColumnNotFound` |
| `R2` bos tabloda olmayan kolon (`WHERE`) | `ecColumnNotFound` |
| `R3` bos tabloda olmayan kolon (`SUM`) | `ecColumnNotFound` |
| `R4` bos tabloda olmayan kolon (`GROUP BY`) | `ecColumnNotFound` |
| `R5` bos tabloda olmayan kolon (`ORDER BY`) | `ecColumnNotFound` |
| `R6` view uzerinden olmayan kolon | `ecColumnNotFound` |
| `R7` `GROUP BY` alias | `ecColumnNotFound` (bilinen fark) |
| `R7b` `ORDER BY` alias | calisir |
| `R8` nitelikli referans (`t.id`) | calisir |

## 7. Bilinen farklar ve desteklenmeyen yuzey

Bunlar "hata" degil, **sozlesmenin siniri**dir; hepsi gurultulu davranir
(sessiz yanlis sonuc yok):

- **`GROUP BY` cikti alias'i kabul etmez.** PostgreSQL eder
  (`SELECT n AS k ... GROUP BY k`). VDB'de kolon adi yazilmalidir;
  `ORDER BY` alias'i ise kabul edilir.
- **`SUBSTR` / `SUBSTRING` / `TRIM` yok.** Bilinmeyen skaler fonksiyon
  `ecUnsupported` verir. Var olan skaler fonksiyonlar: `UPPER`, `LOWER`,
  `LENGTH`, `ABS`, `ROUND`, `COALESCE`, `NULLIF`, `CAST`, JSON ve vektor/
  metin arama fonksiyonlari (`SQL_STUB_SURFACE.md` ile birlikte okunmali).
- **`GROUP BY` konum ile (1..N) ve ad ile calisir; alias ile calismaz.**
- Fonksiyon/prosedur/tetikleyici tanimlari yalniz bellekte tutulur ve
  yeniden acilista kaybolur (`SQL_STUB_SURFACE.md`, P2).
- RETURNING'in *tum* alan tipleri metinleserek doner (`TSqlResult.Rows`);
  tipli tuketici `TypedRows` yolunu kullanmalidir.

## 8. Kapsam disi (durust sinirlar)

- **PostgreSQL diferansiyel korpusu var, canli kosum yok.** Beklenen
  degerlerin PostgreSQL karsiligi artik `tests/sql_differential/corpus.txt`
  icinde **kayitli** ve her kosumda olculur (`sql_differential` kapisi);
  bildirilmemis sapma kapiyi kirar. Ancak bu ortamda `psql` yoktur, bu
  yuzden pinli PG degerleri canli PostgreSQL'e karsi **dogrulanmadi**;
  kapi bunu `pg=not-run` olarak acikca raporlar. Ayrinti ve canli kosum
  yolu: `SQL_DIFFERENTIAL.md`.
- **Minimize edilmis regresyon korpusu yok.** `sql_fuzz` kapisi
  ayristiricinin dayanikliligini olcer (surec icinde, sabit tohum), ancak
  bulunan her bozuk girdi kalici bir korpusa indirgenmez.
- **Es zamanlilik / coklu oturum** bu kapinin konusu degil (tek surec,
  tek oturum; `VDbSql` ornek basina).
- Kapi yalnizca burada listelenen durumlari kapsar. "Tam SQL" iddiasi
  yoktur; yeni bir ozellik eklenirse buraya satir eklenmelidir.
