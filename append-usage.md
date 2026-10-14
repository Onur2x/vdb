
---

## 7. Adim 4 — Pratik SQL Kodu / Her Ozellik Ne Ile İlgilenir (4.1 → 4.6 + Kalan)

Bu bolum **her kod degisikligi** icin pratik SQL ornegi verir.

### 4.1 CROSS JOIN (CROSS JOIN + ON opsiyonel/parcalama)
```sql
SELECT * FROM ebe CROSS JOIN ebe AS e2;
SELECT * FROM ebe CROSS JOIN ebe AS e2 ON ebe.id = e2.id;
```
- `VDbParser`: `jtCross` zorlar (`CROSS` alias + `AllowNoOn`)
- `VDbExecutor` `ExecSelect`: her sol satir her sag satirla birlesir (O(n·m)); `ON` varsa filtre uygulanir
- `sqltest`: `T08h_CrossJoin` (4 test; 962 + 9 FAIL mutasyon — DNF / hash-joint filtreleme)

### 4.2 JOIN + GROUP BY / Aggregate (`FindColIdx` + `ExecGroupBy` + `FinishGroup`)
```sql
SELECT ebe.ad, COUNT(*) FROM ebe JOIN ebe AS e2 ON ebe.id = e2.id GROUP BY ebe.ad;
SELECT ebe.ad, SUM(s.deger) FROM ebe JOIN stoks s ON ... GROUP BY ebe.ad HAVING SUM(s.deger) > 100;
```
- `FindColIdx`: nitelikli (`ebe.ad`) ve sade (`ad`) kolon referanslari; JOIN'de sade yazim eslesir, eslesmezse `ecColumnNotFound`
- `ExecGroupBy`: `FindColIdx` ile GROUP BY kolonlari cozer; `FinishGroup` her grup icin aggregate hesaplar
- `sqltest`: `T08i_JoinAggregate` + `T09b_HavingAggregate` (982 + 18+5 FAIL mutasyon)

### 4.3 HAVING Direct Aggregate (`ExecGroupBy` eski `raise` silindi; `EvalAggregateValue` + `FAggIdx` + `AggFuncCtype`)
```sql
SELECT ebe.ad, MAX(s.deger) FROM ebe JOIN stoks s ON ... GROUP BY ebe.ad HAVING MAX(s.deger) > 50;
```
- `FAggIdx`: HAVING'deki aggregate icin baglam (grup baglam); `try/finally` ile koruma
- `AggFuncCtype`: `MIN`/`MAX` icin kolon tipini bulur (`VCT_INT` vs `VCT_FLOAT`)
- `EvalAggregateValue`: SELECT + HAVING tek implementasyon; `ExecGroupBy`'den `raise` kaldirilmis
- `sqltest`: 997/0 + 17 FAIL mutasyon

### 4.4 NOT(...) OR (DNF) (`NegateGroup` De Morgan)
```sql
SELECT * FROM ebe WHERE NOT (ad = 'A' OR ad = 'B');
-- NegateGroup -> (ad <> 'A' AND ad <> 'B') (tek kosullu OR)
SELECT * FROM ebe WHERE NOT (x = 1 AND y = 2 OR a = 1);  -- cok kosullu OR -> ecUnsupported (sinir)
```
- `ParseNotExpr`: `NotNode` + `ParseCmpExpr`; `ParseNotExpr` degismedi
- `NegateGroup`: `Length(G[i]) = 1` (tek kosullu OR grubu) De Morgan ile acilir; `Length > 1` `ecUnsupported`
- `VDbSql.pas` `ParseWhereGroups`: hash-join WHERE filtrelemesi; cok kosullu OR DNF temsil edilemez (mimari sinir)
- `sqltest`: `T09c_NotOrDNF` (4 test; 3 OK + 1 OK fix sonra; 1001/0)

### 4.5 WITH (RECURSIVE / ColAliases / DML parser / `MaterializeCtes` / `maxIter=3`)
```sql
WITH RECURSIVE cte(n) AS (
  SELECT 1 UNION ALL SELECT n + 1 FROM cte WHERE n < 3
) SELECT * FROM cte;
-- 4.5: maxIter=3 ile iterative CTE; SubResult + guncellenmis FCteTables ile beslenir

WITH cte(x) AS (SELECT 10 AS x) SELECT * FROM cte;
-- ColAliases: (x) -> R.Fields esleme; FindColIdx CTE mapping partial

WITH cte AS (SELECT * FROM ebe) INSERT INTO ebe SELECT * FROM cte;
-- 4.5: ParseWith parser acik; ParseInsert baglantisi mimari degisiklikle tamamlandi (TSqlInsertStmt.WithQueries)
```
- `VDbParser.pas`: `ParseWith` (`RECURSIVE`, `ColAliases`, DML token izin)
- `VDbExecutor.pas`: `MaterializeCtes` (`maxIter=3`; `ColAliases` -> `R.Fields`; alias mapping)
- `sqltest`: `T09d_With` (RECURSIVE 5 OK, alias 5 OK, INSERT 1 OK); `WITH + INSERT` test 1001/0

### 4.6 WINDOWS (Pencere fonksiyonlari + ROWS/RANGE parser + ComputeWindows basit)
```sql
SELECT ebe.ad, SUM(s.deger) OVER (PARTITION BY ebe.ad) FROM ebe JOIN stoks s ...;
SELECT ebe.ad, SUM(s.deger) OVER (PARTITION BY ebe.ad ORDER BY ebe.id ROWS UNBOUNDED PRECEDING) FROM ebe JOIN stoks s ...;
```
- `ParseOver`: `OVER (...)`, `ORDER BY`, `PARTITION BY`, `ROWS`/`RANGE` (FrameType/FrameStart/FrameEnd eklendi)
- `ComputeWindows`: `PDict` partition -> siralama; `ROW_NUMBER`/`RANK`/`LAG`/`LEAD` dogrudan; aggregate basit birikim `UNBOUNDED PRECEDING -> CURRENT ROW`
- `VDbExecutor.pas`: `AggCtype`, `EvalExpr`, `KeyCtype`, `PartKey`, `KeysEqual`, `DoSort`
- `sqltest`: `Pencere fonksiyonlari` (P5-WIN) 8 OK; `F2-19` siralama dogru

### Kalan (4.6+): PRAGMA / ALTER / VIEW / Alt sorgu
```sql
PRAGMA table_info(ebe);  -- 4.6: admPragma, ExecAdmin case
ALTER TABLE ebe ADD CONSTRAINT chk_1 CHECK (deger >= 0);  -- parser acik (ataAddConstraint)
CREATE VIEW v1 AS SELECT * FROM ebe;  -- parser acik (CREATE VIEW)
SELECT * FROM ebe WHERE EXISTS (SELECT 1 FROM ebe AS e2 WHERE e2.ad = ebe.ad);  -- alt sorgu (SubSelect/SubResult)
```
- `ParseAdmin`: PRAGMA (`admPragma` + `st.PragmaName`); `ExecAdmin` case
- `TSqlAdminStmt`: `PragmaName`; `admPragma` enum
- `DENETIM_VE_YOL_HARITASI.md`: 4.1-4.5 kayitlari; `UYGULAMA_ANALIZ_VE_YOL_HARITASI.md`: 4.1-4.6 notlari
- `build_dll.ps1`: `vdbapi.dll` (11:58:50, ABI 1.1, 54 exports, 1251328 B) — gercek DLL
