# SQL stub yuzeyi - gercek durum ve sinirlar

Bu belge, `BASELINE.md` §4'teki eski stub tablosunun yerine gecen **guncel**
durumu kaydeder. Kural tek cumlede: **uygulanmamis bir yol asla sessizce
yanlis sonuc dondurmez**; ya gercekten calisir ya da `ecUnsupported` /
`ecTableNotFound` ile reddeder. Her satir icin kalici kapi:
`tests/sql_stubs/sql_stubs.lpr` (25 kontrol).

## 1. Ozet tablo

| Yuzey | Durum | Kanit |
|---|---|---|
| `INSERT ... RETURNING` | **UYGULANMIS** | R1 |
| `UPDATE ... RETURNING` | **UYGULANMIS** | R1 |
| `DELETE ... RETURNING` | **UYGULANMIS** | R1 |
| `CREATE/DROP TRIGGER` (BEFORE/AFTER/INSTEAD OF, ROW, WHEN) | **UYGULANMIS** (yalniz bellek) | T1, T2 |
| `CREATE/DROP FUNCTION`, `SELECT f(...)` | **UYGULANMIS** (yalniz bellek) | F1, P1 |
| `CREATE/DROP PROCEDURE`, `CALL p(...)` | **UYGULANMIS** (yalniz bellek) | F1 |
| `TVTableDb.CallProcedure` | **REDDEDER** (`ecUnsupported`) | F2 |
| `TVTableDb.ExecuteFunction` | **REDDEDER** (`ecUnsupported`) | F2 |
| Legacy KV `TVDb.InsertReturning` / `UpsertRowReturning` | **REDDEDER** (`ecUnsupported`) | K1 |

Not: RETURNING, F-35/F-36 gibi "stub" degildir. `VDbExecutor` icindeki
INSERT/UPSERT/UPDATE/DELETE RETURNING dallari `TVTableDb.InsertReturning` /
`UpsertRowReturning` uzerinden gercek satiri doner. `VDbTable.pas` icindeki
eski "(stubs)" yorumlari bu nedenle duzeltildi.

## 2. Duzeltilen sessiz-yanlis-sonuc yollari

Bu maddeler V3 oncesinde **hata vermeden yanlis deger** uretiyordu. Hepsi
artik ya dogru hesapliyor ya da hata atiyor.

### 2.1 BEFORE tetikleyicide `NEW.kolon` hedefi yoksa
`SET NEW.x = ...` yazimi, `x` cumlenin kolon listesinde yoksa **sessizce
yutuluyordu** (atama kayboluyor, islem "basarili" gorunuyordu). Artik iki
kod noktasinda da `ecUnsupported`:
`BEFORE tetikleyici NEW.<kolon>: kolon cumlenin kolon listesinde yok: <tetikleyici>`.
Kanit: T1 `NEW.x` kontrolu.

### 2.2 Trigger `WHEN` kosulu tip bilgisi olmadan
Kosul `EvalExprFor` ile **nil kolon tipiyle** degerlendiriliyordu; bu da
karsilastirmayi metin olarak yapiyordu (`'5' > '100'` -> `True`). Artik
`WhenColTypes` tablo tanimindan kolon tiplerini cozer ve `EvalExpr` tipli
olarak degerlendirir. Tip cozulemezse `VCT_STR`'a duser (metin
karsilastirma) - bu bilinçli bir geri cekilmedir.
Kanit: T1 `WHEN yalan` / `WHEN dogru`.

### 2.3 Taninmayan skaler fonksiyon
Skaler bir fonksiyon adi bilinmiyorsa `Exit(lv)` calisiyordu; yani
`SELECT pf(9)` sonucu **argumanin kendisi** (`9`) oluyordu. Artik
`ecUnsupported: bilinmeyen fonksiyon: <ad>`. Aggregate'ler bu dala
girmez (ayri dugum tipi: `TSqlAggNode`).
Kanit: P1/P2 `pf(9)` -> `1009` (govde `x + 1000`).

### 2.4 Katalog API'sinde bos sonuc
`TVTableDb.CallProcedure` bilinen bir prosedur icin bos `Results`
donduruyordu ("calisti" yanilsamasi). Artik govde calistirmaz ve acikca
SQL yolunu isaret eder:
`prosedur govdesi bu API ile calistirilamaz, SQL yolu kullanin (CALL <ad>(...))`.
`ExecuteFunction` ayni sekilde `SELECT <ad>(...)` yolunu isaret eder.
Kanit: F2.

### 2.5 Bilinmeyen prosedur
Artik `ecTableNotFound: prosedur yok: <ad>` (bos sonuc yok). Kanit: E1.

## 3. Belgelenen sinir: tanimlar yalniz bellekte

Fonksiyon, prosedur ve tetikleyici tanimlari `TVTableDb` icindeki
`FFunctions` / `FProcedures` / `FTriggers` koleksiyonlarinda tutulur.
**Katalog dosyasina yazilmaz.** Veritabani kapatilip yeniden acildiginda:

- tetikleyici ateslenmez (tanim yok),
- fonksiyon cagrisi `ecUnsupported` alir,
- prosedur cagrisi `ecTableNotFound` alir.

Bu bir hata degil, bilinen ve testle sabitlenmis bir sinirdir; kalicilik
(katalog yazimi) bu fazin kapsami disindadir. Kanit: P2.

## 4. Kapsam disi (bilerek yapilmadi)

- Rutin/tetikleyici tanimlarinin katalog dosyasina yazilmasi ve yeniden
  yuklenmesi.
- `TVTableDb.CallProcedure` / `ExecuteFunction` icin bagimsiz govde
  yorumlayicisi (tek yol SQL yurutucusudur; ikinci bir yorumlayici
  surdurulmez).
- Legacy KV `InsertReturning` / `UpsertRowReturning` (SQL RETURNING
  kullanin).

## 5. Kapi

```
tests/sql_stubs/sql_stubs.lpr   -> 25 PASS, 0 FAIL
```

Gruplar: T1/T2 (trigger), F1/F2 (routine + katalog API), R1 (RETURNING),
K1 (legacy KV), P1/P2 (kalicilik siniri), E1 (hata yollari).
