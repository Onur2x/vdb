# VDB — Son Denetim + Yol Haritasi

**Tarih:** Ekim 2026  
**Durum:** **F1 TAMAMEN Bitti (23/23) — ve her kalemin regresyon kaniti var.** Test: **569/569 gecer** (denetim oncesi 409/409 idi; +160 assertion). Her F1 duzeltmesi **mutasyon testiyle** dogrulandi: duzeltme geri alindiginda ilgili test KIRMIZI oluyor. Kanit tablosu: *F1 MUTASYON DOGRULAMA* bolumu.

**Guncel durum (2026-10-06):** **Faz 1, Faz 2 (F2-1..F2-21 + bulunan F2-22/F2-23), Faz 3 (F3-1..F3-7) ve Faz 4 tamamlandi.** SIFRELEME adim 11-18 bitti; CDC/TimeTravel onarildi; `SELECT ... AS OF SEQUENCE` SQL'e baglandi; CDC/TimeTravel **DLL export** (poll, 54 export, ABI 1.1) eklendi; bayat `.ppu` ile gizlenen **yorum kaynagi hatalari** (5 dosya) onarildi; **Adim 4 (ileri SQL) bosluklari acilmaya baslandi — 4.1 `CROSS JOIN` ve 4.2 `JOIN` + `GROUP BY`/aggregate bitti** (parser+executor, **982/982**, iki mutasyon kaniti; arti webserver link hatasinin kok nedni: proje kokundeki bayat `.ppu` karantinaya alindi). Guncel test: **982/982** `sqltest` + **170/170** `vdbapitest` + **101/101** `vdbclienttest` + **60/60** `vdbcrypttest` + **38/38** `cdc_test`; `had`, `vdbgui`, `mtakipwebsrv` ve `vdbapi.dll` artirmali derlemeyle de baglaniyor. Kayitlar asagida: *F1/F2 UYGULAMA KAYDI*, *F3* kaydi, *Faz 4 — CDC / TIME TRAVEL KAYDI*, *SQL 'AS OF' INTEGRASYONU*, *CDC / TIMETRAVEL DLL EXPORT*, *BAYAT PPU ... ONARIMI*, *ILERI SQL — ADIM 4 ... 4.1 CROSS JOIN*, *... 4.2 JOIN + GROUP BY*.

---

## DENETIM YONTEMI

4 koldan paralel derin inceleme (VDbCore/VDbSync/VDbCrc32, VDbTable, SQL katmani, API/docs) + manuel dogrulama. Her bulgu kod satiri + senaryo + etki + duzeltme onerisi icerir.

---

## F1 — KRITIK (veri kaybi / yanlis sonuc / cokme)

### VDbCore.pas

| # | Bulgu | Satir | Etki | Duzeltme |
|---|------|-------|------|----------|
| F1-1 | `Recover`: yarim batch fiziksel olarak geri sarilmiyor; seq cakismasi | 618-652 | crash sonrasi DB Verify'den gecemez, oluk prefix birikir | kesme noktasi `pendPos[0]` + seq turetimi |
| F1-2 | `CommitBatch` ortasinda `AppendRec` firlatirsa phantom okuma | 1016-1030 | restart oncesi/sonrasi tutarsizlik | on-dogrulama veya truncate+rebuild |
| F1-3 | `MigrateLegacy` tum dosyayi RAM'e aliyor | 294-311 | ~1GB legacy .odb'de OOM | `Compact` benzeri akis kopyasi |

### VDbTable.pas

| # | Bulgu | Satir | Etki | Duzeltme |
|---|------|-------|------|----------|
| F1-4 | `UpdateWhere`: ilgisiz kolon degisikligi CHECKRESTRICT cagrisi yanlis RESTIC/CASCADE | 3895, 2057-2090 | yanlis FK hatasi veya cocukta bozuk FK | yalniz degisen kolon bir cocuk FK'nin RefCol'u ise cagir |
| F1-5 | `UpdateWhere`: UNIQUE bayat `FIdxUniq` girdisi silinmiyor | 2268, 3922 | sonraki gecerli INSERT reddedilir useri | eski UNIQUE anahtari haritdan dusur |
| F1-6 | `AlterDropColumn`: FK kontrolu yanlis tabloda araniyor | 2804-2805 | sarkan FK kalir, kalici DoS | `FindCol(t, RefCol)` ile karsilastir |
| F1-7 | `AlterAddColumn`: NOT NULL kontrolu commit'ten sonra | 2768-2778 | basarisiz DDL kalici, tekrar deneme hata | kontrolu `RewriteTable` ONCESI yap |
| F1-8 | `RewriteTableRows`/`RewriteTable`/`AlterRenameTable`: hash dogrulamasiz sil/yaz | 2636-2642, 2556-2596, 2998-3006 | carpismada baska tablonun satiri silinir | `DecodeRow`+`ecHashCollision` ekle |
| F1-9 | `BatchInsert`: kendi batch'inde direkt `FKv.CommitBatch`, sema flush yok | 3471-3476 | `AutoInc`/sema kirli bayrak ufalar | `TVTableDb.CommitBatch` mantigini kullan |

### SQL Katmani (VDbParser + VDbExecutor + VDbSql)

| # | Bulgu | Satir | Etki | Duzeltme |
|---|------|-------|------|----------|
| F1-10 | Parser: `OFFSET` alias listesinde eksik | 1061, 1030 | `SELECT * FROM t OFFSET 10` sessizce tum satirlari doner | iki listeye de `OFFSET` ekle |
| F1-11 | UNION/EXCEPT/INTERSECT sutun-sayisi denetlenmiyor | VDbExecutor:2612 | engebeli matris, sessiz yanlis sonuc | birlesme oncesi `Length(outCols)=Length(rightRes.Fields)` kontrolu |
| F1-12 | UNION'da LIMIT/OFFSET/ORDER BY birlesmeden ONCE uygulaniyor | VDbExecutor:2570-2612 | fazla/eksik satir doner | `SetOp<>sokNone` ise kuyruk birlesmeden sonra uygulansin |
| F1-13 | `NOT IN` icinde NULL varsa satir yanlis gecer | VDbExecutor:362-387 | `x NOT IN (1,2,NULL)` satiri dondurur | listede `hasNull` bayragi, `IsNot+hasNull` ise False |
| F1-14 | `NOT NULL` ve `NOT LIKE ... NULL` True donuyor | VDbExecutor:255-265, 594-596 | spec `IS NULL` disi hicbir operator NULL ile eslesmez | `EvalUnary(suoNot,'')` -> `''` (UNKNOWN) |
| F1-15 | `DELETE DATABASE` canlida yok | VDbSql:3056-3137, VDbParser:1886-1898 | spec'te "var" diyor, kodda syntax hatasi | `ExecRaw`'a DAL + `StmtBatchSafe` kontrolu ekle |
| F1-16 | `ExecUpdate` bilinmeyen kolonu sessizce atliyor | VDbExecutor:2789-2794 | yanlis `rCount`, satti eti silinip aynen yazilir | `ci<0` ise `ecColumnNotFound` firlat |
| F1-17 | JOIN'de tip-bilgili kiyaslama dusuyor | VDbExecutor:344-351 | `WHERE s.tutar>2` metin sirasiyla `'10'<'2'` olur | sonek-eslesme veya `Taraf` benzeri konum-tabanli tip |
| F1-18 | Bozuk/negatif `LIMIT/OFFSET` sessizce yok sayiliyor | VDbParser:1219-1233 | `LIMIT abc` -> limitsiz, `LIMIT -5` -> tam sonuc | basarisiz/negatif/>2M ise `ecSyntaxError/ecLimit` firlat |
| F1-19 | `SUM` bos kumede `0` donuyor | VDbExecutor:2309-2311 | SQL'de `NULL` olmali | `if cnt=0 then Exit('')` |
| F1-20 | GROUP BY sonrasi `ORDER BY` sayisali metin siralar | VDbExecutor:2487-2490 | `ORDER BY adet` (COUNT) `'10'<'2'` bozulur | agrega-tip haritasi (COUNT->INT, SUM/AVG->FLOAT) |
| F1-21 | `ORDER BY` bilinmeyen kolon sessizce siralamaz | VDbExecutor:1448-1478 | `ORDER BY yok` hata vermeden giris-sirasi doner | `kidx<0` ise `ecColumnNotFound` firlat |
| F1-22 | Derin ic-ice ifade/negatif-sayi yigintasi | VDbParser:497-1004 | 10k `((((...))))` veya `NOT NOT...` yigin-tasmasi yapar | derinlik sayaci (256) + tasma hatasi |
| F1-23 | `SplitStatements` yorgum/yorumlar atlamiyor | VDbSql:2478-2526 | `"`/`` ` `` icindeki `;` veya yorumdaki `;` yanliş cumele boler | ayiriciya `"`/`` ` `` ve yorum atlama ekle |

---

## F2 — ORTA (tutarsizlik / performans / puruzluluk)

| # | Bulgu | Dosya:Satir | Duzeltme |
|---|------|-------------|----------|
| F2-1 | `VDbFlushDir` Unix'te hata yutuyor | VDbSync:40-59 | boolean don veya RaiseLastOSError |
| F2-2 | Yeni dosya basligi + legacy rename VDbFlushDir'siz | VDbCore:788-792,760-761 | her iki noktadan sonra VDbFlushDir cagir |
| F2-3 | `DetectFormat` istisna yolunda tutarsiz | VDbCore:771-796 | try/except + ecCorrupt'a ceviri |
| F2-4 | WAL metotlari kilitsiz + stub | VDbCore:1226-1364 | FLock + CheckOpen (dusuk onclik) |
| F2-5 | `Get` index-offset dogrulamiyor | VDbCore:875-901 | ScanAll'daki aralik+header kontrolunu ekle |
| F2-6 | `DropTable` gereginden kati | VDbTable:3404-3413 | gercek kesisim ara veya ebeveyn bossa dusur |
| F2-7 | `FIntentDrop` hic temizlenmiyor | VDbTable:1618-1631 | basarili MarkSchema/SaveSchema sonrasi temizle |
| F2-8 | `BatchInsert` AutoInc/sema flush etmiyor | VDbTable:3471-3476 | TVTableDb.CommitBatch mantigini kullan |
| F2-9 | DDL atomik degil (veri ayri, sema ayri fsync) | VDbTable:2587-2598 | tek dis batch'te birlestir |
| F2-10 | `AlterColumnType` PK dahil tip degisimi serbest + FK/CHECK re-validate yok | VDbTable:2871-2918 | PK tip degisimini yasakla + Ctype tazele |
| F2-11 | `AlterDropColumn` bekleyen indeks op'lari temizlenmiyor | VDbTable:2824-2834 | `DropIdxPend` cagir |
| F2-12 | Self-referans FK denetimsiz + kaskad derinlik korumasi yok | VDbTable:2061,2102-2114 | continue kaldir + ziyaret-kumesi + derinlik siniri |
| F2-13 | `LoadSchema` bozuk satir sessizce atlaniyor | VDbTable:1341-1342 | `ecSchemaCorrupt` firlat |
| F2-14 | `CreateTable` bos tablo adina izin veriyor | VDbTable:3318-3331 | `Trim(Name)=''` ise `ecInvalidName` |
| F2-15 | BLOB + cok-kolonlu indeks `#1` cakismasi | VDbTable:924-937,904-922 | BLOB bilesik indeksi reddet veya uzunluk-onegi kullan |
| F2-16 | `ScanRows` bozuk satiri Continue ile atliyor | VDbTable:3747 | `ecCorrupt` firlat |
| F2-17 | `Verify` raporunda BATCHEND put sayiliyor | VDbCore:1348 | ucuncu sayac `nEnd` ekle |
| F2-18 | UNION/DISTINCT O(N^2) + limitsiz | VDbExecutor:2573-2591,2623-2661 | RowEncodeKey hash yolu + satci ecLimit |
| F2-19 | Pencere gecici matrisi 2-3x bellek | VDbExecutor:2064-2066,2095-2109 | indeks-siralama kullan, tmpM kopyasi kaldir |
| F2-20 | Alt-sorgu/CTE tam materyalizasyon | VDbExecutor:639-652,731-751 | IN/EXISTS icin tek-kolon projeksiyon + erken hash + ecLimit; belge notu |
| F2-21 | SQL.md betik atomikligi celiskisi | SQL.md:12 vs 299 | "AutoTx acik ve hepsi batch-uyumluysa ya-hep-ya-hic; StmtBatchSafe disi varsa cukre-atomik" ekle |

---

## F3 — DUSUK (hijyen)

- `VDbSql` arşivi `{$IF 0}` blogundan cikardan canli üyeleri sil (`ExecJoin/ExecAggregate/TryIndexSelect/CompareRowsTbl/QuickSortIdx/SortRowsBy/IndexOfRow/SplitSetTail/ApplySetTail/FindSetOp/DedupRows/ParseWhereGroups/ParseSetExpr/IsAggWord/ParseSelectItem/CollectParenText/AndGroups/ExecVerify`).
- `DoSort` yigin-dizisi 63 sabit: tasima guardi + yorum.
- Magic sayillara isim ver (`VDbSync.pas:77,96` - `LOCK_EX/LOCK_NB/LOCK_UN`).
- `TblOk` olu bayrak kaldir (`VDbCrc32.pas:38`).
- `IdxAddRow` bos anahtari `FIdxUniq`'ye yazmasin.
- `DropTable` `ScanRows` hash-esitlik hatasini tekrarlasin.

---

## DOGRULANANLAR (kisa)

- **VDbCore.Recover** bos-dosya yolu, `AbortBatch` dogrulugu, tekli yazim protokolu, torn-tail kesme+flush, `ReplaceWith`/`BackupTo` rename-oncesi flush+dir-flush, bounds (`ValLen>VDB_MAX_VALUE` uc yolda kontrol, Int64 offset), Key=0 cakismasi yok, `Verify` salt-okunur+bloklu, `VDbCrc32` standart+thread-guvenli (initialization), `RaiseLastOSError` dogru, platform ifdef'leri islevsel.
- **VDbTable**: Insert/UpdateWhere NOT NULL+UNIQUE+tip-normalizasyon+CHECK+FK, BatchInsert her satiri Insert'ten gecirip tek batch'te atomik, UNIQUE `''` muafiyeti, PK guncelleme yasagi, batch-ici gorunurluk, `GetTable`/`TableExists` tutarliligi, BLOB ham-yol, iki-asamali FK siralamasi, `AbortBatch` indeksleri veriden onariyor.
- **SQL**: JOIN+GROUP reddi, RIGHT/FULL klasik-dongu+2M, LEFT hizli-yol NULL-genisletme, DISTINCT projeksiyon-sonrasi/LIMIT-oncesi, `TryIndexOrder` DISTINCT/GROUP/aggr/pencere/COLLATE-TR dislamasi, `VDbCmpVal` NULL'da False+yalniz sayisal kolonda sayisallasTirma, bos IN()->False, skaler cok-satir hatasi, iliskili-alt-sorgu reddi, bos-tabloda COUNT(*)=0/tek-grup, MIN/MAX tip-bilgili, COUNT(col) NULL-atlama, pencere AVG sifirsizlik, CASE ELSE-yoksa NULL, sade-CASE NULL, tokenizer ''/?/; dogru, `StmtBatchSafe` cekirdek dislama + `ExecAll` hepsi-ya-hic/tek-fsync, `NarrowRows` ust-kume+RowMatches dogrulamali.
- **API/docs**: `VDbDataSet` Post/Cancel/Delete/Insert/Refresh/buffer/bookmark — 53/53 test gecerli, sozlesmeye uygun. `VDbPool` timeout/cift-release/yabanci/kapali-havuz — 8/8 test gecerli. `VDbText` UTF-8 cozucu + TrWeight — test gecerli. `VDbJson` BLOB + #0 — `$hex` nesnesiyle duzeltildi, test gecerli. `guimain` acilis sirasi dogru (Kv.Open -> Tb.Open). Belge ceiskisi SQL.md:12 vs 299 yukarida F2-21'de.

---

## ONCELIKLI UYGULAMA SIRASI

**Faz 1 (1-2 gun):** ~~F1-1'den F1-23'e kadar hepsi.~~ **TAMAMLANDI (23/23)** — asagida "F1 UYGULAMA KAYDI". En acili: F1-1 (Recover), F1-4 (CheckRestrict), F1-10 (OFFSET alias), F1-12 (UNION sirasi), F1-13/F1-14 (NULL mantigi).

**Faz 2 (2-3 gun):** ~~F2-1'den F2-21'e kadar hepsi.~~ **TAMAMLANDI** — asagida "F2 UYGULAMA KAYDI" (test T46-T66, 13 kalem mutasyon kaniti, ayrica F2-22/F2-23 bulup duzeltildi). F2-8, F1-9 duzeltmesiyle karsilandi (`BatchInsert` artik `TVTableDb.BeginBatch/CommitBatch` kullanir).

**Faz 3 (1 gun):** ~~Düşük hijyen — arciv temizligi, magic sayilar, ölü bayrak, indeks hijyen.~~ **TAMAMLANDI** — asagida F3 kaydi (F3-1..F3-6 + bulunan **F3-7**; test T67/T68). `mtakipwebsrv.lpi` derleme yolu da duzeltildi.

**Faz 4:** ~~Belge son rotus — README/SQL.md test sayilari + yeni duzeltmeler sonrasi guncelleme.~~ **TAMAMLANDI** — README'ye *CDC / Time Travel* bolumu + test tablosu (`cdc_test` **38/38**) eklendi; `SQL.md`'ye `AS OF` notu dustuldu; asagida "FAZ 4 — CDC / TIME TRAVEL KAYDI".

**Faz 5:** ~~`SELECT ... AS OF` SQL parser/executor baglantisi.~~ **TAMAMLANDI (06.10.2026)** — `AS OF SEQUENCE` SQL olarak calisiyor (test T78, 31 kontrol); TIMESTAMP/VERSION/JOIN/WAL-yok reddleri acik `ecUnsupported`. Asagida "SQL 'AS OF' INTEGRASYONU".

---

## NOT

Bu dosya, 4 koldan paralel derin denetim + manuel dogrulama sonucu olusturulmustur. Her bulgu kod satiri + senaryo + etki + duzeltme önerisi icerir. Uygulama sirasi F1 -> F2 -> F3 -> F4.

---

# F1 UYGULAMA KAYDI (23/23 tamamlandi)

**Test sonucu:** `sqltest.exe` -> **569 gecen / 0 kalan** (once 409/409).
**Derleme:** `sqltest.lpi` ve `vdbgui.lpi` temiz derleniyor ve linkleniyor.
**Geriye donuk uyum:** Tum degisiklikler `private` (ic) uyelerde; `TVSqlExecutor`/`TVDbParser` public API'si degismedi. Uygulama (`mtdata.pas`) yalniz taban kolonu ile `ORDER BY` ve SQL metni `UNION` kullanmiyor (birlestirmeyi Delphi tarafinda yapiyor), dolayisiyla F1-21 ve F1-12 davranis degisikligi mevcut kodu kirpmiyor.

| # | Duzeltme | Dosya | Test |
|---|----------|-------|------|
| F1-1 | `Recover`: commitlenmemis batch `committedThrough` konumundan fiziksel kirpilir, `FSeq` geri alinir | VDbCore | T24 |
| F1-2 | `CommitBatch`: boyut on-kontrolu + hata halinde `FS.Size` geri alma, `Recover`, ikincil hata yutma | VDbCore | T24 |
| F1-3 | `MigrateLegacy`: 64 KB akis kopyasi (tam dosya RAM'e alinmiyor) | VDbCore | - |
| F1-4 | `CheckRestrict` yalniz degisen kolon bir cocuk FK'nin `RefCol`'u ise cagrilir | VDbTable | T24 |
| F1-5 | `UpdateWhere`: eski UNIQUE anahtari `FIdxUniq`'ten dusulur (yeni anahtar eklenmeden once) | VDbTable | T24 |
| F1-6 | `AlterDropColumn`: FK hedefi **ebeveyn** tablosunda `FindCol` ile aranir | VDbTable | T34 |
| F1-7 | `AlterAddColumn`: NOT NULL kontrolu `RewriteTable` ONCESINE alindi | VDbTable | T13 |
| F1-8 | `RewriteTable`/`RewriteTableRows`/`AlterRenameTable`: silmeden once `DecodeRow` ile dogrulama; `ecHashCollision` **ve** `ecCorrupt`; rename'de cozulemeyen satir sessizce atlanmiyor | VDbTable | T34 |
| F1-9 | `BatchInsert` kendi `FKv.CommitBatch` yerine `TVTableDb.BeginBatch/CommitBatch` kullanir (AutoInc + sema flush) | VDbTable | T20 |
| F1-10 | `OFFSET` iki alias listesinde; ayrica `OFFSET n LIMIT m` yazimi desteklenir | VDbParser | T35 |
| F1-11 | UNION/EXCEPT/INTERSECT oncesi sutun sayisi denetimi (`ecSyntaxError`) | VDbExecutor | T25 |
| F1-12 | Kuyruk **birlesme sonrasina**: (a) `ParseSelectTail` ayri procedure, sag SELECT icin `FSuppressTail` ile bastirilir; (b) `HasSetOp` bayragi `SkipOffsetLimit`'ten **ayridir** — eski kod `True` yaparak sol taraf WHERE filtresini hic uygulamiyor ve birlestirme bos kaliyordu; (c) aggregate/GROUP BY + set-op sessizce yanlis sonuc yerine `ecUnsupported` | VDbParser + VDbExecutor | T25 |
| F1-13 | `NOT IN` listede NULL varsa `hasNull` bayragi -> satir donmez | VDbExecutor | T31 |
| F1-14 | Karsilastirma operatorlerinde (`=`,`<>`,`<`,`<=`,`>`,`>=`,`LIKE`) NULL taraf **UNKNOWN** (`''`) doner. `EvalUnary(suoNot,'')` -> `''` korunur | VDbExecutor | T31 |
| F1-15 | `DELETE DATABASE` `ExecRaw`'da canli + `StmtBatchSafe` dislamasinda | VDbSql | T30 |
| F1-16 | `ExecUpdate`: bilinmeyen SET kolonu `ecColumnNotFound` (satir silinip aynen yazilmiyor) | VDbExecutor | T29 |
| F1-17 | `FindColIdx` yardimcisi: nitelemeli (`alias.col`) ve sonek eslestirmesi; binary op tip cozumlesmesi **sag** kolona da bakiyor | VDbExecutor | T28 |
| F1-20 | `ExecGroupBy` cikti tip haritasini disari verir (`out OutTypes`); GROUP BY `ORDER BY` ve `HAVING` bu tipleri kullanir | VDbExecutor | T26 |
| F1-21 | `DoSort`: bilinmeyen `ORDER BY` kolonu `ecColumnNotFound` (sessizce giris-sirasi donme yerine) | VDbExecutor | T27 |
| F1-22 | `FDepth` sayaci (256 sinir) parantez ve NOT zincirinde tasma hatasi | VDbParser | T24 |
| F1-23 | `SplitStatements` tirnak, cift tirnak, `--` ve `/* */` durumlarini izler | VDbSql | T20 |

# F1 MUTASYON DOGRULAMA

Her F1 duzeltmesi geri alindi ve testin KIRMIZI oldugu goruldu. Bu, testin
o duzeltmeyi gercekten yakaladiginin kanitidir ("test yazildi" demek yeterli
degildir — test duzeltmeden bagimsiz da gecebilir).

| # | Geri alinan duzeltme | KIRMIZI olan test |
|---|---------------------|-------------------|
| F1-1 | `Recover`: `truncatePos := pos` (kirpma yok) | `yarim batch diskte kaldi (oluk prefix)` + `Verify kirpma sonrasi basarisiz [BOZUK @134: seq kirik beklenen=5 gelen=1]` |
| F1-2 | `CommitBatch`: on-dogrulama + rollback | `hata sonrasi kayit sayisi degismedi [beklenen 1, gelen 2]` (phantom kayit gorunur oldu) |
| F1-4 | `ExecUpdate`: `Delete`+`Insert` yerine `UpdateRowInPlace` | `CASCADE ile cocuk yanlis silinmedi [sonuc hucre yok]` — cocuk satir ON DELETE CASCADE ile SILINDI |
| F1-4 | `FindColIdx` sonek eslestirmesi | `JOIN + WHERE nitelemesiz kolon sayisal [Kolon bulunamadi: tutar]` |
| F1-5 | `IdxDelRow(t, oldVals, ...)` | `KESILDI: UNIQUE ihlali: etiket` — GECERLI INSERT reddedildi |
| F1-6 | RefCol kontrolunu dogru tablo yerine `kv.Key` ile aramak | `cocuk FK RefCol olan kolon drop edilemez [HATA VERMEDI]` + `FK butunlugu bozulmadi [FK hedef kolon yok: k]` — sarkan FK olustu |
| F1-7 | `ADD COLUMN` onundaki NOT NULL kontrolu | `mevcut satirlar varken NOT NULL eklenemez [HATA VERMEDI]` + sonraki denemede `kolon var: z` — kalici DDL bozulmasi |
| F1-11 | UNION sutun sayisi denetimi | `UNION/EXCEPT/INTERSECT sutun sayisi farki hata [HATA VERMEDI]` (3 test) |
| F1-12 | `not HasSetOp` guard'lari (kuyruk pre-merge) | `UNION OFFSET sonrasi 2 satir [gelen 0]`, `UNION ORDER BY+LIMIT+OFFSET [beklenen "2" gelen "3"]` (4 test) |
| F1-14 | karsilastirmalarda NULL -> UNKNOWN guard'i | `NULL LIKE ile eslesmez [beklenen 2, gelen 3]`, `NOT NULL satir gelmez [beklenen 1, gelen 2]` |
| F1-16 | `ExecUpdate` bilinmeyen kolon kontrolu | `UPDATE bilinmeyen kolon [HATA VERMEDI]` |
| F1-17 | binary op tip cozumlemesi (`FindColIdx` cagrilari) | `JOIN + WHERE sayisal > 2 [beklenen 2, gelen 1]` + `index > arama [beklenen "10" gelen "9"]` + `CTE sayisal WHERE` (10 test) |
| F1-19 | `SUM` bos kume -> NULL | `SUM bos tablo NULL [beklenen "" gelen "0"]`, `SUM hepsi NULL grup NULL` |
| F1-20 | GROUP BY `ORDER BY` tip haritasi (`nil` yerine `outTypes`) | `GROUP BY COUNT ORDER BY ASC ilk grup b(2) [beklenen "b" gelen "a"]` (9 test) — metin sirasi `'10'<'2'<'3'` |
| F1-21 | `DoSort` bilinmeyen kolon hatasi | `ORDER BY bilinmeyen kolon [HATA VERMEDI]` |
| F1-22 | `FDepth > 256` derinlik kontrolu | `5000 parantez temiz hata vermedi [kabul edildi (tasma riski)]` |
| F1-23 | `SplitStatements` yorum atlama | 13 test dustu (`3 komut islendi [beklenen 3, gelen 1]`, `karisik betik 3 cumle`, ...) |

### Gozlemsel olarak AYIRT EDILEMEYEN kalemler (durus olarak kayit altina alindi)

Bu kalemlerin **kodu dogru**, ama mutasyon testi gözlemsel bir fark
uretemiyor. Bunu "test edildi" diye gizlemek yeren acikca yaziyoruz:

| # | Durum | Neden ayirt edilemiyor |
|---|-------|------------------------|
| F1-3 | `MigrateLegacy` akis kopyasi | 400 kayitlik legacy dosya **kayipsiz** aktariliyor (`fsize=26692 copied=26692 idx=400`). Akis kopyasi ile tam-RAM kopyasi ayni sonucu verir; fark yalnizca ~1 GB dosyada BELLEK olcumuyle gorunur. Test dogruluk kaniti; bellek davranisi yapisal (64 KB sabit tampon). |
| F1-9 | `BatchInsert` -> `TVTableDb.CommitBatch` | Etki yalnizca "sema kirli + batch disi BatchInsert" kombinasyonunda belirir. `TVTableDb.CommitBatch` icindeki `if FSchemaDirty then SaveSchema` sartini SQL/API disindan tetiklemek gerekiyor (beyaz-kutu). AUTOINCREMENT ve Verify testleri **gecer** ama mutasyonda da gecer — ayirt edici degil. |
| F1-15 | `StmtBatchSafe` icin `DELETE DATABASE` | `ExecAll` zaten batch'siz cumleleri ayri calistiriyor; `StmtBatchSafe` sonucu bu yolda gozlemsel olarak ayni. Kontrol `private` oldugu icin dogrudan cagrilamiyor. Canli `DELETE DATABASE` yolu T30'da dogrulanmistir. |
| F1-18 | `LIMIT/OFFSET` deger dogrulama | Deger dogrulamasi **tokenizer katmaninda zaten** gerceklesiyor (`LIMIT: dogal sayi bekleniyor, "-" bulundu`). `ParseSelectTail` icindeki ikinci kontrol (pratik olarak) yedek; mutasyonunda testler yesil kaldi. |
| F1-10 | `OFFSET` alias listesi | `SELECT * FROM t OFFSET n` her iki yolda da calisiyordu; alias listesi pratikte etkisiz. Gercek katki: `OFFSET n LIMIT m` yaziminin eklenmesi. |
| F1-8 | Hash dogrulamasi | Mevcut T21 zaten sentetik carpisma ile INSERT/FK yollarini kovaliyor; `AlterRenameTable` carpisma senaryosu FNV-1a 64-bit ile pratikte uretilemedigi icin yalnizca veri butunlugu dogrulanir. |

### F1 sirasinda DENETIM RAPORUNDA OLMAYAN gercek hata (bulundu ve duzeltildi)

**F1-4 tamamlayici — SQL `UPDATE` veri kaybi.**
Rapor F1-4'u `UpdateWhere` icinde tanimlamisti. Oysa SQL katmanindaki
`ExecUpdate` `UpdateWhere`'i **hic cagirmiyor**; her satiri
`FT.Delete` + `FT.Insert` ile yeniden yaziyordu. Sonuc: `ON DELETE CASCADE`
bir UPDATE'in **silme** yarisiyla tetikleniyor, yani **ilgisiz bir kolon**
guncellenirken cocuk satirlari SILINIYORDU. Bu dogrulamasi T38'de yakalandi
ve `TVTableDb.UpdateRowInPlace` ile tek kaynaga baglandi (`UpdateWhere` de
artik onu cagiriyor -> iki yerde mükerrer mantik yok).
Ayrica SQL UPDATE'a PK kolonu guncelleme yasaği eklendi.

## Yeni test bolumleri (sqltest.lpr)

| Test | Kapsam |
|------|--------|
| T25_F1_UnionSiraVeLimit | UNION/ALL/EXCEPT/INTERSECT, sutun sayisi hatasi, birlestirme sonrasi ORDER BY/OFFSET/LIMIT |
| T26_F1_OrderByTip | COUNT/SUM/MIN/MAX cikti tipi ile sayisal siralama (`'10' < '2'` tuzagi) |
| T27_F1_OrderByBilinmeyenKolon | bilinmeyen kolon hata verir, gecerli ORDER BY calisir |
| T28_F1_JoinTipKiyas | JOIN sonrasi nitelemeli/nitelemesiz sayisal kiyaslama, LEFT JOIN NULL elemesi |
| T29_F1_UpdateBilinmeyenKolon | hata + veri butunlugu + gecerli UPDATE + 0-satir UPDATE |
| T30_F1_DeleteDatabase | canli yol + `ExecAll` betik yolu, silinen DB yok |
| T31_F1_NotInNull | `NOT IN`/NULL, `NOT (...)`, `IS NULL` |
| T32_F1_LimitGecersiz | negatif/sayi disi LIMIT+OFFSET hata verir |
| T33_F1_SumBosKume | bos tablo ve hepsi-NULL grupta SUM NULL |
| T34_F1_AlterRenameBozukSatir | rename sonrasi veri + FK referansi yeni ada guncellenir |
| T35_F1_OffsetAlias | `SELECT * ... OFFSET n`, `OFFSET n LIMIT m`, `LIMIT n OFFSET m` |
| T36_F1_RecoverKirpma | **F1-1** crash benzetimi: dosyaya BATCHEND'siz kayit eklenir, `Recover` fiziksel kirpar, `Verify` gecer |
| T37_F1_CommitBatchAtomik | **F1-2** limit asiminda `CommitBatch` hata verir, dosya buyumez, restart tutarli |
| T38_F1_CheckRestrictFiltresi | **F1-4** UPDATE ilgisiz kolon FK tetiklemez; ON DELETE CASCADE cocugu yanlis silmez |
| T39_F1_UniqueBayatAnahtar | **F1-5** UPDATE sonrasi serbest kalan UNIQUE degeri yeniden kullanilabilir |
| T40_F1_AlterDropColumnFK | **F1-6** sarkan FK olusmaz; FK kaynak kolonu kasitli reddedilir |
| T41_F1_AlterAddColumnNotNull | **F1-7** basarisiz DDL kalici olmaz, ayni deneme tekrar calisir |
| T42_F1_BatchInsertAtomik | **F1-9** coklu INSERT + AUTOINCREMENT + Verify |
| T43_F1_MigrateLegacy | **F1-3** basliksiz (legacy) dosya 400 kayitla uretilir, gecis sonrasi kayipsiz |
| T44_F1_ParserDerinlik | **F1-22** 250 parantez kabul, 5000 parantez temiz hata, motor saglam kalir |
| T45_F1_SplitStatements | **F1-23** `--`, `/* */`, `"`, tirnak ici `;` bolmez |

## F1 sirasinda karsilasilan ek gercekler (kapsam disi, kayit icin)

- **LEFT JOIN null-genisletmesi** birlestirme *kolonu* icin bos string yerine anahtar degeri yaziyor; `WHERE s.id IS NULL` eslesmeyen satiri bulamaz (`s.tutar IS NULL` calisiyor). `T28` icinde yorum olarak isaretlendi.
- **Tablolarda `ORDER BY` yoksa satir sirasi garantisi yok** ( indeks/PK okuma sirasi). Testlerde belirli satir bekleyen kontroller `ORDER BY` icermeli.
- `had.lpi` ve `mtakipwebsrv.lpi` **unit arama yolu** hatasi veriyor (`Can't find unit VDbSql/VDbCore`) — F1 oncesinden gelen, `.lpi` degisikligi gerektiren ayri bir konu.

---

# F2 UYGULAMA KAYDI (2026-10-04)

Kapsam: F2-1 .. F2-21. **Ayrica iki yeni gercek hata bulundu ve duzeltildi:
F2-22 ve F2-23.** Test sonucu: **73 grup / 682 kontrol, 682 gecen, 0 kalan.**

## Yeni test bolumleri (sqltest.lpr)

| Test | Konu | F2 kalemi |
|---|---|---|
| T46 | bozuk sema satiri `ecSchemaCorrupt` ile reddedilir | F2-13 |
| T47 | `CREATE TABLE` bos ad reddedilir | F2-14 |
| T48 | `DROP TABLE` gercek FK kesisimine bakar, sarkan FK tanimlarini temizler | F2-6 |
| T49 | kendine referansli FK kurulur + kaskad derinligi | F2-12 |
| T50 | BLOB'da `#1` iceren degerler, UNIQUE bilesik indekste karismaz | F2-15 |
| T51 | `DROP COLUMN` indeks durumunu temizler | F2-11 |
| T52 | `ALTER COLUMN` PK/FK tip korumasi + CHECK yeniden dogrulama | F2-10 |
| T53 | DDL atomikligi (veri + sema tek batch) | F2-9 |
| T54 | `UNION`/`DISTINCT` tekillestirme, ayirici iceren degerler | F2-18 |
| T55 | pencere siralamasi sonucu dogru | F2-19 |
| T56 | `IN (SELECT ...)` sonuc kumesi, NULL/NOT UNKNOWN | F2-20 |
| T57 | bozuk/kisa dosya tutarli hata sinifi verir | F2-3 |
| T58 | `Verify` BATCHEND'i put saymaz | F2-17 |
| T59 | `VDbFlushDir` sonucu + `DirSyncFailed` isareti | F2-1, F2-2 |
| T60 | WAL metotlari kapaliyken hata verir | F2-4 |
| T61 | `Get` mevcut/olmayan anahtar davranisi | F2-5 |
| T62 | DROP TABLE isareti kalici semadan sonra temizlenir | F2-7 |
| T63 | bozuk kayit sessizce yutulmaz | F2-16 |
| T64 | PK'siz tablo: ilk kolon PK degil, ortuk UNIQUE degil | **F2-22** |
| T65 | `CREATE UNIQUE INDEX` zorlanir (tek + cok kolonlu, reopen sonrasi) | **F2-23** |
| T66 | `DROP COLUMN` cok kolonlu indeksi de kaldirir | F2-11 |

## Mutasyon kaniti - KANITLANAN (13 kalem)

Asagidaki her kalemde duzeltme geri alindi, proje yeniden derlendi ve
ilgili testin **KIRMIZI** oldugu goruldu; sonra kod geri konuldu.

| Kalem | Mutasyon | Kirmizi sonuc |
|---|---|---|
| F2-3 | kisa dosya `Exit` ile kabul ediliyor | "kisa dosya kabul edildi" |
| F2-4 | `HasWAL`/`CheckpointWAL` `CheckOpen` cagrisi kaldirildi | "kapaliyken sessiz kaldi" x2 |
| F2-6 | sarkan FK temizligi yok | `KESILDI: FK hedef tablo yok: ebe2` |
| F2-10 | PK tip korumasi kaldirildi | "PK kolonunun tipi degistirilemez" kabul edildi |
| F2-11 | cok kolonlu indeks `IdxHasCol` yerine tek kolonla aranip | "a ile 2 satir: beklenen 2, gelen 0" |
| F2-12 | kendine referansli FK yeniden reddediliyor | `KESILDI: oz-yinelemeli FK yok (v1)` |
| F2-13 | bozuk sema satiri yutuluyor | "bozuk sema yanlis tani verdi: EStringListError" |
| F2-14 | bos tablo adi denetimi kaldirildi | "CREATE TABLE bos ad" kabul edildi |
| F2-15 | bilesik indeks anahtari eski `#1` kodlamasina donduruldu | "ayirt edilebilir kombinasyon reddedildi (duplicate)" |
| F2-17 | BATCHEND `put` olarak sayiliyor | "BATCHEND put icinde sayildi: put=6 batchend=0" |
| F2-19 | `ORDER BY` alias cozumlemesi kaldirildi | "ORDER BY bilinmeyen kolon: rn" |
| F2-22 | `PkIndex` yine `0`'a zorlandi | `KESILDI: duplicate PK: x` |
| F2-23 | parser `Uniq` bayragini yutuyor | "tek kolonlu UNIQUE tekrar KABUL EDILDI" + "gercek duplicate reddedilmedi" |

## Gozlemsel olarak AYIRT EDILEMEYEN kalemler (durustce kayit altina alindi)

Bu kalemlerde koruma **dogru calisiyor**, ancak disaridan tetiklenemiyor;
bu yuzden mutasyon kaniti uretilemedi. F1'deki 5 kalemle ayni durust
yaklasim benimsendi.

| Kalem | Neden ayirt edilemiyor |
|---|---|
| F2-1, F2-2 | Windows'ta `VDbFlushDir` tanim geregi **her zaman True** doner (NTFS dosya adi/dizin guncellerini atomik yonetir). Yalniz `DirSyncFailed=False` gozlenebiliyor. Unix'te `FpOpen`/`FpFsync` hatalari test edilebilir. |
| F2-5 | Bozuk index girdisi **disaridan uretilemez**: motor dosyayi kilitli tutuyor ve `Recover` indexi dosyadan yeniden kuruyor. Kirpma denemesi dosya kilidi nedeniyle basarisiz. |
| F2-7 | Tek etkisi `GuardSchemaLoss`'un "kasitli silindi" toleransidir; bu korumanin **iki ayri oturum** ile saglanmasi gerekir. Surec ici tek oturumda gozlenemez. |
| F2-9 | DDL atomikligi **cokme ani** davranisidir (veri commit -> sema commit arasi crash). Surec ici, crash uretmeden gozlenemez. |
| F2-16 | Kayit CRC'si **deger baytlarini kapsar** (`RecCrc`), bu yuzden bozuk kayit once `Recover`'da yakalanip dosya **kirpilir**; `ScanRows`'in `DecodeRow` kontrolune ulasilamaz. |
| F2-18 | O(N^2) -> O(1) hash + 2.000.000 satirlik sonuc siniri **performans** kalemidir; sonuc degeri degismez. |
| F2-20 | `IN (SELECT ...)` deger kumesi onbellegi **performans** kalemidir; sonuc degeri degismez. |
| F2-21 | Dokümantasyon kalemi; mutasyon yerine metin dogrulamasi yapilir. |

## Diger gercekler (F2'de taniklananlar)

- **Ayirici karakter (`#1`) bir KONTROL karakteridir.** SQL literal'ina
  gomuldugunde tokenizer bozulur. Testlerde bu degerler **parametre** ile
  gecirilir. Ayrica normal `WHERE` esitliginde metin sirasiyla karsilastirma
  yapildigi icin `#1` iceren degerler `WHERE` ile aranamaz; dogrulama tablo
  satirinda yapilir.
- **`VCT_STR` deger karsilastirmasinda bayt sirasi** kullanilir; bu yuzden
  bilesik indeks anahtarlari her zaman metin olarak kodlanip karsilastirilir.
- **Cok kolonlu indeks girdileri PARCA PARCA siralidir** (`SortIdxEntriesCols`),
  ham dize uzerinde ikili arama gecersizdir. Ayirici blok bulunup tam
  anahtar esitligi denetlenir. `VDbIdxPartOf` zaten ayirilmis bir parcayi
  YENIDEN ayrastiracagi icin aramaya **ham kodlanmis anahtar** verilir.

---

# F3 UYGULAMA KAYDI (2026-10-04)

Kapsam: F3-1 .. F3-6 + **yeni F3-7**. Test sonucu: **75 grup / 714 kontrol,
714 gecen, 0 kalan.** `sqltest.lpi` ve `vdbgui.lpi` ikisi de temiz derleniyor.

## F3-7 — cok kolonlu indeks, ilk kolon filtresinde satirlari siliyordu

**Bu bir YANLIS SONUC bug'i (F1 seviyesi), hijyen degil.** F3 testi yazilirken
kavrildi.

### Belirti

```sql
CREATE TABLE p(id INTEGER PRIMARY KEY, v INTEGER, w INTEGER);
INSERT INTO p VALUES(1,10,100),(2,10,200),(3,20,300);
CREATE INDEX ix_vw ON p(v,w);

SELECT id FROM p WHERE v = 10;                -- 0 satir (dogru: 2)
SELECT id FROM p WHERE v = 10 AND w = 200;    -- 0 satir (dogru: 1)
SELECT id FROM p WHERE w = 200;               -- 1 satir (dogru: 1)
SELECT id FROM p WHERE v > 5;                 -- 3 satir (dogru: 3)
```

### Neden

Bilesik indeks anahtarlari uzunluk-oneki ile kodlanir: `v=10,w=100` ->
`"2:103:100"`. `VDbIdxRangeL` araligi **ilk parcaya** gore hesaplar ve
`VDbIdxPartOf` ile ayirir. Ancak cagiranlar (`NarrowRows`, `TryIndexOrder`,
JOIN/index aramalari) degeri **KODLANMAMIŞ** gecirir (`'10'`).

`VDbIdxPartOf('10')` ilk karakteri rakam gordugu icin onu kodlu anahtar
sanar: `"10"` rakam sayilir, ardindan `':'` bekler ama yoktur -> **BOS string**
doner. Bos ile karsilastirma `=` araligini **bos** birakir ve satirlar sessizce
kaybolur.

`>` / `>=` ise yanlislikla bir **superset** uretir; bu yuzden sonraki
`RowMatches` yeniden dogrulamasi onlari "kurtarir" ve yanlis sonuc gorunmez.
Yalniz `=` ve `<=` bozuktu.

Ayni tuzak F2-23'te de vardi: `VDbIdxPartOf` **zaten ayirilmis** bir parcayi
yeniden ayirastirir. Bu yuzden orada ham parca yerine tam kodlanmis anahtar
verilmesi gerekiyordu.

### Duzeltme

- `VDbIdxProbe1(Val) = "<len>:<val>"` eklendi: ham tek degeri, indeks
  anahtarinin kodlanmis bicimine cevirir.
- `VDbIdxRangeL` artik `Val` ham oldugu icin once `probe := VDbIdxProbe1(Val)`
  yapar ve tum karsilastirmalarda `probe` kullanir.
- Kodlanmis tam anahtar vermek isteyenler icin ayri giris noktasi
  `VDbIdxRangeLK` eklendi (F2-23 UNIQUE denetimi bunu kullanir; `'<' , '<='`
  disi operatorlerde `ecUnsupported` verir).

### Mutasyon kaniti

`probe := VDbIdxProbe1(Val)` -> `probe := Val` yapildiginda 714 kontrolun
cogu KIRMIZI oluyor ("ilk kolon = beklenen 2, gelen 0", "ilk + ikinci kolon",
"sayim dogru", "60+ satirtan v=10" ...). Kod geri konulunca 714/714.

## Yeni test bolumleri (sqltest.lpr)

| Test | Konu |
|---|---|
| T67 | F3 regresyonu: UNIQUE + coklu NULL, 500 satirlik siralama, cok kolonlu indeks |
| T68 | **F3-7**: cok kolonlu indeks ilk kolon `=` / `<=` / `>` / `BETWEEN` / `IN` / `COUNT` / `SUM` filtresleri (60+ satir) |

## Diger F3 kalemlerinin durumu

F3-1, F3-3, F3-4 **derleme zamani** kalemleridir (olu kod silme, sabit
adlandirma, olu bayrak): davranis degismedigi icin mutasyon kaniti
uretilemez; derleme + 714/714 ile dogrulandi.

F3-2 ve F3-5 de **gozlemsizdir**: F3-2'nin tasma denetimi matematiksel
olarak ulasilamaz (derinlik log2(N) <= 64), F3-5 bos (=NULL) deger UNIQUE
denetiminde zaten muaf oldugu icin sonuc degistirmez. T67 bu yollari
calistirarak regresyon agini kurar.

F3-6 icin `ScanRows` icindeki hash-esitlik denetiminin mutasyonu denendi:
714/714 **yesil kaldi** — yani bu koruma test kapsaminda degil. Sebep F2-16
ile ayni: kayit CRC'si deger baytlarini kapsadigi icin bozuk kayit once
`Recover`'da yakalanip dosya kirpilir.

---

# YONETIM ARACI (had.exe) CALISMASI (2026-10-04)

## Derleme duzeltmesi

`yonetim\had.lpi` **derlenmiyordu**: `<CustomOptions Value="-FuD:\veritabani"/>`
eski makine yolundan kalmisti ve bu makinede boyle bir dizin yok; sonuc
`Can't find unit VDbCore used by hadmain`. `-Fu..` yapildi (proje `yonetim`
altinda, VDB birimleri bir ust dizinde). Simdi `sqltest.lpi`, `vdbgui.lpi` ve
`had.lpi` **ucunun de** sifirdan (`-B`) temiz derlendigi dogrulandi.

Not: yonetim projesinde `.lfm` YOK; butun arayuz Pascal kodyla kuruluyor.

## Yonetimde bulunan 5 eksik ve duzeltmeleri

Motor tarafinda F2-22 (PK'siz tablo) ve F2-23 (UNIQUE indeks) duzeltilince,
yonetim aracinin bu yetenekleri kullanamaz oldugu ortaya cikti. Yonetim
programi motorun yapabildigi her seyi yapabilmelidir:

| # | Yer | Sorun | Duzeltme |
|---|---|---|---|
| M1 | `haddlg.pas` `btnOkClick` | PK isaretlenmezse `PkIndex := 0` zorlaniyordu; **PK'siz tablo yonetimden olusturulamiyordu**, kullanici secmedigi halde 1. sutun PRIMARY KEY oluyordu | Zorlama kaldirildi (`PkIndex = -1` kalir). Birden fazla sutun PK isaretlenirse kullaniciya uyari verilir (motor tek PK destekler) |
| M2 | `hadmain.pas` `sgDataSetEditText` | `WHERE pkCol = pkVal` yaziyordu; PK yoksa **sessizce `Exit`** -> hicbir sey olmuyordu | Satir **satir anahtari** ile adresleniyor: `ReadRow` + `UpdateRowInPlace` (motorun SQL UPDATE'inin cagirdigi ayni yordam: tip normallesme, CHECK, FK, `ON UPDATE CASCADE`, indeks bakimi). PK kolonu degistirilemeyecegi icin durum mesaji verilir |
| M3 | `hadmain.pas` `btnDelRowClick` | Ayni sessiz `Exit` -> PK'siz tabloda **hicbir satir silinemiyordu** | `FTb.Delete(t, pk)` kullaniliyor (`CheckRestrict` ile `ON DELETE CASCADE` / `SET NULL` / `RESTRICT` dahil) |
| M4 | `hadmain.pas` indeks sekmesi | Indeks araczi **tek sutunlu** (`csDropDownList` + tek combo) -> cok kolunlu ve UNIQUE indeks kurulamiyordu | Sutun kutusu serbest metin (`"a,b,c"` = cok kolunlu), **UNIQUE** onay kutusu eklendi, `CreateIndexCols(..., Unique)` cagriliyor. Yapi tablosunda 3. sutun "Tur" ile `UNIQUE` isareti ve cok kolunlu indekslerde **tum sutunlar** yaziliyor. `hadtools.SplitCSV` arayuze acildi |
| M5 | SQL katmani | `DESCRIBE` / `INDEXES` gibi salt-okunur sema sorgusu yok | **Yapilmadi** - motor tarafi kalip, yonetim icin gerekli degil. Istenirse ayri bir is olarak ele alinabilir |

## Dogrulama

Yonetim salt GUI oldugu icin (konsol/CLI yok) otomatik GUI testi yazilmadi.
Onaylanan yaklasim uygulandi: **motor tarafi test edildi, GUI derlendi.**

`T69_YonetimAPI` test grubu, yoneticinin kullandigi **dogrudan motor API
yollarini** SQL katmani olmadan cagirir:

1. `CreateTable(..., PkIndex = -1)` — PK'siz tablo olusturulabilir (M1)
2. `UpdateRowInPlace(t, sentetikPk, vals)` — PK'siz tabloda duzenleme (M2)
   + `UNIQUE` ihlalinin reddedildigi
3. `Delete(t, sentetikPk)` — PK'siz tabloda silme (M3)
4. `CreateIndexCols(t, ad, ['a','b'], True)` — cok kolunlu + UNIQUE indeks
   zorlamasi (M4) ve `False` ile UNIQUE olmayan indeks
5. PK'siz tabloda `AlterDropColumn` (M1'in sonucu olarak ilk sutun serbest)

**Test sonucu: 76 grup / 726 kontrol, 726 gecen, 0 kalan.**
Ucu proje (`sqltest`, `vdbgui`, `had`) sifirdan temiz derleniyor.

---

# YONETIMDE KALAN BOSLUKLAR (M6-M8) — 2026-10-04

"Her sey yapabilmeli" dogrusu icin motorun public API'si ile yoneticinin
kullandigi API'ler karsilastirildi. Sonuc:

## Motor API envanteri vs yonetim

| Motor yetenegi | Yonetimde durumu |
|---|---|
| `Compact` / `VACUUM` | VAR (menu) |
| `RebuildIndexes` / `REINDEX` | VAR (menu) |
| `Verify` | VAR (menu + otomatik acilista) |
| `SHOW TABLES` | VAR |
| `BackupTo` | VAR (+ otomatik yedek secenegi) |
| `DeleteWhere` | SQL ile karsilaniyor (`DELETE ... WHERE`) |
| `IndexNames` | `td.Idx` uzerinden dogrudan okunuyor |
| `Lock`/`Unlock` | Gerekmiyor (yonetim tek thread) |
| `DataKeyCount` / `DeadBytes` | VAR (bilgi paneli) |
| **`AutoCompact`** | **EKSIKTI -> M8** |
| **`RestoredFromBak`, `DirSyncFailed`** | **EKSIKTI -> M6** |
| **`ExecAll` + `SplitStatements`** | **EKSIKTI -> M7** |
| `WriteAheadWAL` / `ReplayWAL` / `CheckpointWAL` / `HasWAL` | **BILerek EKLENMEDI** - bkz. asagida |
| `DESCRIBE` / `INDEXES` (SQL) | YOK (M5) - ayri is olarak birakildi |

## M6 — Dayaniklilik alarmlari gorunmuyordu

Motor iki kritik durumu yalnizca property olarak tutuyordu:
- **`RestoredFromBak`**: dosya `.bak`'tan **geri yuklendi** (yarim kalmis
  compact/replace). Eski surumdeki veri olabilir.
- **`DirSyncFailed`**: dizin girdisi fsync edilemedi; yeni dosya/rename
  kalici **olmayabilir** (F2-2).

Yonetim `OpenDB` sirasinda bunlari kontrol edip `SetHealth('DIKKAT: ...')`
ve `Log` ile kullaniciya gosteriyor.

## M7 — SQL sekmesi yalniz TEK cumle calistiriyordu

`ExecuteSQL` dogrudan `FSq.Exec(SqlText)` cagiriyordu; birden fazla cumle
iceren bir betik calistirilamiyordu. Artik:
- `SplitStatements` ile cumlelere bolunuyor,
- tek cumle ise `Exec`, cok cumle ise **`ExecAll`**,
- `AutoTransaction` varsayilan acikken hepsi **tek transaction**'da
  calisir: tek fsync, hata halinde **hicbiri uygulanmaz** (SQL.md'de
  anlatilan semantik).

## M8 — "Gerektiginde Sikistir" araci yoktu

Yonetim olu bayti gosteriyordu ama **reclaim edemiyordu**; yalniz tam
VACUUM vardi. Menuye "Gerektiginde Sikistir" eklendi; `AutoCompact` yalniz
olu bayt orani esigi asildiginda calisir, kucuk veritabaninda hic ellemez.

### Bu ozelligi yazarken bulunan GERCEK HATA (kendi kodumdu)

`AutoCompact` -> `Compact` -> `ReplaceWith` -> **atomik rename + yeniden
acis** yapar. Bu yuzden dosya degistigi halde `TVTableDb`'nin **bellekteki**
sema ve indeks onbellegi bayat kalir; sonraki sorgularda **"tablo yok"**
gorulur. `VACUUM` butonu zaten bu yuzden `OpenDB` ile yeniden aciyordu.
Ilk yazdigim `AutoCompact` surumunde bu yeniden acis **eksikti**; duzeltildi.

Ayrica motor tarafi ayri bir prob ile dogrulandi: sikistirma sonrasi sema
anahtari, tablo sayisi ve veri **kusursuz** kaldi (veri kaybi YOK).

## WAL neden bilerek eklenmedi

`WriteAheadWAL`/`ReplayWAL`/`CheckpointWAL`/`HasWAL` public API'de duruyor
ama **replay bir STUB** — `VDbCore.pas:1381`:

> `// STUB: replay YOK. .wal dosyasi yoksa True; varsa False doner ve
>  icerigi uygulanmaz. ... replay uygulanana kadar WriteAheadWAL
>  cagrilmamalidir.`

Yonetime bu dugmeleri eklemek **calismayan bir ozelligi kullaniciya
acmak** olurdu (dosya yazilir, replay edilmez, veri sessizce kaybolur).
Bu bir yonetim eksiği degil, **bitmemis bir motor ozelligidir**; ayri bir
is olarak ele alinmalidir.

## Dogrulama

`T70_YonetimBakim` test grubu yonetim ozelliklerinin motor yollarini dogrudan
cagirir: `AutoCompact` (esik altinda/ustu, veri butunlugu), `ExecAll`
(cok cumle, hata atomikligi, BEGIN/COMMIT, ROLLBACK),
`RestoredFromBak`/`DirSyncFailed`, `VACUUM`, `REINDEX`.

**Test sonucu: 77 grup / 745 kontrol, 745 gecen, 0 kalan.**

NOT (test yazarken): `Chk`/`ChkVal` yardimcilari **global** `sq` oturumunu
kullanir; ayri bir `TVSql` oturumu acilan testlerde yanlis "tablo yok"
veriyor. `T69`/`T70` kendi yardimcilarini kullanir.

Derleme: `sqltest` ve `vdbgui` sifirdan temiz. `had` de temiz dogrulandi
(gecici hedef adi ile linklendi; kullanici `had.exe`'yi AÇIK TUTTUGU icin
calisan exe uzerine yazilmadi).

---

# WAL REPLAY GERCEKLESTIRME + M9/M10 (2026-10-04)

## Onceki durum: replay bir STUB idi

`ReplayWAL` kaydi uygulamiyordu; `.wal` varsa `False` donuyordu. Ustelik
**formatta magic ve CRC yoktu** — yalniz `Key+Flags+Len+Value`. Boylece
crash ortasinda yarim yazilmis kayit, gecerli bir kayit gibi okunup **cop
veriyi** ana dosyaya uygulardi. `CheckpointWAL` ise dosyayi oldug gibi
silirdi (uygulanmamis kayitlar kalici kaybolurdu).

## Yeni format

```
TVDbWalHead = packed record   // 21 bayt
  Magic  : LongWord;          // $57414C52 ('WALR')
  Key    : QWord;
  Flags  : Byte;              // VDB_FLAG_PUT | VDB_FLAG_DEL
  ValLen : LongWord;
  Crc    : LongWord;          // RecCrc(0, Key, ValLen, Flags, Value)
end;
```

Her kayit kendi `magic` + `CRC` degerini tasiyor; `CRC` **magic'i kapsamaz**
(boylece magic kontrolunun ayrica kaniti mumkun olur).

## Bulunan ve duzeltilen 4 gercek hata

| # | Hata | Etki | Nasil yakalandi |
|---|---|---|---|
| 1 | `WriteAheadWAL` her cagrida `fmCreate` ile dosyayi **kirpardi** | Her yazma onceki kayitlari siliyordu; replay yalniz son kaydi goruyordu | Elle kontrol: 3 kayit yazildi, dosyada 1 kayit vardi |
| 2 | Paylasim bayraklari `Mode` parametresine karistirilmis, I/O hatasi yutuluyordu | `.wal` sessizce yazilamiyordu | Derleme sirasinda fark edildi |
| 3 | `ReplayWAL` uygulama dongusu `off-by-one` | Gecersiz/yirtik **son kayit da bir tur daha uygulaniyordu** — cop veri ana dosyaya yaziliyordu | T72 yirtik-kuyruk testi |
| 4 | `ReplayWAL` **BATCHEND yazmiyordu** | `AppendRec` dogrudan yaziyor, `CommitBatch` `FPending` bos oldugu icin batch-end uretmiyor. Dosyada daha once bir BATCHEND varsa `Recover` replay kayitlarini "commit edilmemis batch" sayip **geri sariyor** — replay edilen veri yeniden acilista **KAYBOLUYORDU** | T72 4b: onceden BATCHEND iceren dosyaya replay + yeniden acilis |

3. ve 4. hatalar test yazarken **tesadufen** bulundu; ikisi de veri kaybi
seviyesindedir ve mutasyonla ayrica kanitlandi.

## WAL mutasyon kaniti — 13 kalem, hepsi KANITLANDI

| # | Bozulan davranis | Sonuc |
|---|---|---|
| 1 | `ReplayWAL`: CRC dogrulamasi kaldirildi | 806/1 — `CRC bozuk kayit UYGULANDI` |
| 2 | `ReplayWAL`: magic kontrolu kaldirildi | 810/1 — `bozuk magic kayit UYGULANDI` |
| 3 | `ReplayWAL`: kayitlar hic uygulanmiyor | 803/7 — 7 replay kontrolu kirmizi |
| 4 | Uygulama dongusu limiti `applied + 1` | 809/1 — `CRC bozuk kayit UYGULANDI` |
| 5 | `WriteAheadWAL`: `fmCreate` (kirpma) geri | 807/3 — 3 kayit kontrolu kirmizi |
| 6 | `CheckpointWAL`: replay etmeden siler | 806/4 — `checkpoint: kayit kayboldu` |
| 7 | `ReplayWAL`: bayrak dogrulamasi kaldirildi | 813/1 — `anlamsiz bayrakli kayit UYGULANDI` |
| 8 | `ReplayWAL`: silme kaydi PUT olarak uygulanir | 809/1 — `replay sonrasi silinen 1 anahtari duruyor` |
| 9 | `WriteAheadWAL`: deger dosyaya yazilmaz | 803/7 |
| 10 | `ReplayWAL`: `DEL` kaydi deger tasima denetimi kaldirildi | 818/1 — `deger tasayan DEL kaydi UYGULANDI` |
| 11 | `ReplayWAL`: BATCHEND isareti yazilmiyor | 823/2 — `reopen sonrasi replay kaydi 101/102 KAYBOLDU` |
| 12 | `ReplayWAL`: yirtik kuyruk sonrasi `.wal` silinmiyor | 818/7 |
| 13 | `WalRecordCount`: CRC kontrolu yok | 829/1 — `WalRecordCount CRC bozuk kaydi SAYDI` |

### Testin izole olmasi icin harcanan calisma

Uc kontrol birbirine bagliydi ve ilk denemelerde **sahte yesil** verdi:

- **Bayrak (7) ve DEL-deger (10):** CRC alani bayragi da kapsar. Bayragi
  bozmak CRC'yi de bozardi, dolayisiyla test bayrak kontrolunu DEGIL CRC
  kontrolunu olcuyordu. Cozum: motorun yazdigi bir kayitla testin kendi
  CRC formulu **dogrudan karsilastirildi**, sonra bayrak 99 yapilip CRC
  o bayrak icin yeniden hesaplandi. Tek secilebilir hata bayraktir.
  Ayrica `DEL + dolu deger` senaryosunda anahtar **onceden dolduruldu**;
  aksi halde "reddedildi" ile "silindi" ayirt edilemiyordu.
- **Magic (2):** CRC magic'i kapsamaz; bu yuzden yalniz ilk 4 bayti
  bozmak kaydi CRC'den gecerli birakir.
- **BATCHEND (11):** yalniz "replay sonrasi `Get`" kontrolu hatayi GORMEZ
  (bellekteki `FIndex` hazir). Test mutlaka **kapat-aç** yapmalidir.

Ayrica ilk yazimda testin kendisi hataliydi: `WalRecCount` 24 baytlik
hizalama varsayiyordu (21 baytlik baslik), ve CRC formulu `Seq` alanini
atlardi. Ikisi de testin **kendisinin** hatasydi; motorda degil.

## Yeni API: `WalRecordCount`

Bekleyen **gecerli** kayit sayisini doner. Yan etkisi YOK (yalnizca okur).
`ReplayWAL` ile ayni dogrulama kurallarini kullanir; iki yeri ayirmak
sayiyi yaniltici yapardi, bu yuzden kural kopyasi bilerek ayni yazildi.

## M9 - Yonetim arayuzu WAL ve sema ile baglandi

Motorun ozellikleri calisiyordu ama yonetimde **hicbir arac yoktu**:

- **Araclar menu** + **Araclar sekmesi**: `WAL Durum`, `WAL Replay`,
  `WAL Checkpoint` (bekleyen kayit yoksa pasif).
- DB bilgi panelinde bekleyen WAL varsa **kirmizi uyari satiri**.
- Saglik gostergesi `DIKKAT: WAL bekliyor` gosterir ve nabiz atar.
- **Sema menu** + **Sema sekmesi**: `DESCRIBE`, `SHOW INDEXES`,
  `SHOW CREATE TABLE`, `Tum Tablolarin Semasi`. Sorgu SQL sekmesine
  yazilip **calistirilir**; kullanici sonucu gorur ve sorguyu
  duzenleyip tekrar calistirabilir.

## M10 - Profesyonel duz tasarim sistemi

Sorun: her kontrol icin ayri `ThemeXxx` cagrisi, iclerine **gomulmus
sabit renkler** (`$00DDDDDD`, `$001E1E1E`, `$00444444`, koyu secim
`$00804820`, acik secim `$00E6D5D3`...), `gridPrepareCanvas` icinde iki
ayri blok. Ayni renk yazili olarak tekrarlaniyordu; bir yeri degistirmek
digerlerini bozuyordu ve **yeni kontrol eklenince tema kaciriliyordu**.

Cozum: `TUIStyle` paleti (yuzey/metin/cizgi/odak/secim/durum renkleri +
olcu + tipografi) tek yerde tanimlandi; `UIStyleLight`/`UIStyleDark`
paletleri kurar; `ApplyTheme` ve `gridPrepareCanvas` yalnizca bundan okur.

Duz (flat) ilkesi uygulandi: kalkinlik (`BevelOuter/Inner`) yok, banner
tek yuzey + 4 px vurgu seridi, gridlerde kalin cerceve ve baslik satiri
kaldirildi, kartlar tek ton.

Ayrica duzeltilenler:
- **Palet `CreateUI` ONCESI dolduruluyor**; aksi halde kontrollerin ilk
  renkleri bos (siyah) degerlerle ataniyordu.
- `SetHealth` artik **uc** durumu ayirt ediyor: `SAGLAM` / `DIKKAT` /
  `SORUN`. Onceki hâlde `DIKKAT` mesaji `SORUN` etiketiyle gosteriliyor,
  yani uyari ile gercek hata karisiyordu.
- Nabiz animasyonu paletten turetilen iki ton kullanir.

### Bu LCL surumunde DIKKAT

`TCustomGrid` yalniz `Color/FixedColor/GridLineColor/BorderColor/Flat/Font/
FixedRows/DefaultRowHeight` sunuyor. `RowHeight`, `FocusRect`,
`SelectionColor`, `TitleImages`, `BorderStyle` **yok** — kullanilmalari
derleme hatasi verir. Odak vurgusu `gridPrepareCanvas` icinden
`UIStyle.Focus` ile yapildi. `SysUtils.FileAge` ve `FileUtil.FileAge`
da bu surumde **yok**; bu yuzden WAL dosya yasi gosterilmiyor (bakim
bilgisi yerine kayit sayisi gosteriliyor).

## Dogrulama

**Test sonucu: 80 grup / 859 kontrol, 859 gecen, 0 kalan.**
Derleme: `sqltest`, `vdbgui`, `had` — ucu de sifirdan temiz (`-B`).
`had.exe` gercek dosya uzerine linklendi ve acilisi ekran goruntusuyle
dogrulandi (SAGLAM, kartlar, agac, duz gridler hizasinda).

---

## M11 - Otomatik WAL (write-ahead) ve test kaybi onarimi

### Ne yapildi

`WAL` opt-in idi: kullanici `WriteAheadWAL` cagrisini **unutursa** kayit
yalnizca bellekte kalirdi. Artik `WALEnabled = True` iken motor her kalici
yazmada once `.wal`'a, sonra ana dosyaya yaziyor.

Varsayilan **KAPALI**: acik degilse motor davranisi bit bit degismez.

### Yazarken bulunan GERCEK HATA (otomatik WAL tasariminda)

| # | Hata | Neden gercek bir hatayi | Kanit |
|---|---|---|---|
| 1 | `CommitBatch` icin `SkipWAL = True` verilmis | Batch ici yazma gunluge **hic girmez** (Kayitlar yalniz biriktirilir), dolayisiyla commit'te `SkipWAL` demek "zaten gunlukte" demek yanlisti. Sonuc: toplu yuklemede **hicbir kayit crash sonrasi kurtarilamazdi**. | M1 mutasyonu |
| 2 | `Close` WAL durumunu sifirlamiyor | Ayni nesne yeniden `Open` edilince `WALEnabled` `True` kaliyor; kullanici gunlugu kapattigini saniyor, motor sessizce yazmaya devam ediyordu. | M2 mutasyonu |
| 3 | `WAL yazilamazsa` hata dongusu | Ana dosyaya yazmadan once `fsync` edilen `.wal`a yaziliyor; **hata halinde ana dosyaya da yazilmamasi** garanti altina alinmadi. | M4 mutasyonu |

### Otomatik WAL mutasyon kaniti - 5 kalem, hepsi KANITLANDI

| # | Bozulan yer | Beklenen | Sonuc |
|---|---|---|---|
| M1 | `CommitBatch` -> `SkipWAL = True` | batch kayitlari gunluke girmez | **YAKALANDI** (2 kirmizi) |
| M2 | `Close` -> `FWALEnabled` sifirlanmaz | kapat-ac sonrasi otomatik WAL sizemez | **YAKALANDI** (1 kirmizi) |
| M3 | `if not SkipWAL then` -> `if False then` | otomatik WAL hic devreye girmez | **YAKALANDI** (8 kirmizi) |
| M4 | WAL yazma hatasi `try/except` ile yutuluyor | islem basarisiz olmali, ana dosyaya yazmamali | **YAKALANDI** (2 kirmizi) |
| M5 | `Inc(FWALAutoCount)` calistirilmiyor | sayac artmali | **YAKALANDI** (3 kirmizi) |

> M4'un ilk denemesi **gecersiz** bir mutasyondu: `WriteAheadWALCore` hata
> halinde `False` donmek yerine **exception firlatiyor**; `and False` eklemek
> davranisi hic degistirmiyor ve test dogru olarak yesil kaldi. Yanlis
> mutasyonun testi "gecirmedi" sanmak yerine **sebebini aramak** gerekti.
> Anlamli mutasyon: WAL blogunu `try/except ... end` ile sarmalamak.

### Test paketi kaybi: `sqltest.lpr` nasil kurtarildi

Bu turun basinda `sqltest.lpr` bir toplu metin donusumuyla bozulmus
ti: **~30 satirdaki SQL literalleri** kirpilmis ve **~30 satirdaki
string literal** kodlama zincirlemesi nedeniyle 12.000 karakterlik
cop bloklarina donusmusdu. Derlenemiyordu; elle onarim guvenli
degildi (30 SQL cumlesi **tahmin** edilemez).

 cozum **tahmin degil, kanit** oldu:

1. Eski calisan `sqltest.exe` (830/830) **silinmedi**. FPC string
   sabitlerini binaryye gomdugu icin orijinal literaller orada duruyordu.
2. `veritabani\ESKI\sqltest.lpr` (temiz UTF-8 eski snapshot) satirlari
   **icerik hizasiyla** eslestirilip bozuk satirlar birebir geri kondu.
3. `ESKI`'de karsiligi olmayan satirlar `exe` icinden **bayt komsuluguyla**
   bulundu (`exe`deki literal sirasi kaynak sirasini izler; aciklama
   hemen yaninda durur). Boylece `yardimci tablo`, `2 deger grubu`,
   `3 deger grubu`, `zincir betigi`, `gecerli satir` gibi **aciklamalar
   dahil** butununden kurtarildi.
4. Dosya UTF-8 olarak yazildi; sonuc dosyada **115** non-ASCII bayt
   kaldi - `ESKI` ile **birebir ayni** sayi (bozulma tamamen giderildi).

Bu onarim sirasinda **gercek bir motor hatasi** da ortaya cikti:
`ChkErr('FK ihlali (hata)', 'INSERT INTO ebeveyn(id,ad) VALUES(1,''Ali'')')`
kontrolu hata **beklerken** insert'in basarili olmasi nedeniyle
kirmiziydi. Motor probu (`probe_fk`) gosterdi: NOT NULL ihlali **temiz
rollback** oluyor, sonraki insert basarili. Yani **test yanlisti**,
motor dogruydu; eski `ESKI` satirindaki dogru hali
(`Chk('gecerli satir', ...)`) geri konuldu. Kayip olan
`INSERT INTO t(id,a,b) VALUES (14,4,'p;q')` testi de ayni sekilde
geri eklendi.

### Dogrulama (M11)

| Paket | Sonuc |
|---|---|
| `sqltest` | **859/859** (80 grup), 3 ayri taze dizinde tekrarlandi |
| `vdbapitest` | **123/123** (35 export cozuldu) |
| `vdbclienttest` | **71/71** |
| `had` | temiz derleme (`lazbuild -B`), `had.exe` linklendi |
| Mutasyon | 5/5 yakalandi |

### ABI tarafi

Yeni export'lar: `VdbWalSetAuto`, `VdbWalIsAuto`, `VdbWalAutoCount`.
Bunlari yazarken **ayni sinif bir sessiz hata** bulundu:
`VdbWalHas` / `VdbWalRecordCount` hata halinde `0` donduruyordu, yani
hatayi `"WAL yok"` ile ayni gosteriyordu. Sorgu donduruculer artik
hata halinde `VDB_E_GENERAL` doner, spesifik kod `VdbErrCode()` ile
alnir (ABI'nin zaten kullandigi sozlesme). Test bunu 10 kontrol ile
sikiliyor.

---

# SIFRELEME (2026-10-05) — Adim 11-18 TAMAM

Plani: `SIFRELEME_PLANI.md`. Tasarim: `kayit = IV(16) || len(4) ||
AES-256-CTR || Tag(32)`, encrypt-then-MAC, `K_enc`/`K_mac` PBKDF2 ile
turetilir, `.key` (58 bayt) **sir tutmaz**.

| Adim | Sonuc |
|---|---|
| 11 Mutasyon kaniti | 4/5 bozma KIRMIZI (1'i maskelendi ve durustce yazildi) |
| 12 Anahtar omru | `Close`/`Destroy` `FEncKey`'i `FillChar` + nil yapar |
| 13 Anahtarsiz acilis | header `VDB_HFLAG_HAS_ENCRYPTED` + `"SIFRELI: anahtar yok"` |
| 14 WAL replay | `T76_ReplayWALSifreleme` (replay + batch + AutoCompact) |
| 15 Re-key | `ALTER DATABASE KEY 'yeniParola'` / `RekeyWithPassword`, atomik tmp+rename, `.bak` korunur |
| 16 Verify raporu | `sifreli=N` sayaci |
| 17 DLL + VDBClient | 10 yeni export, `VDBClient` sarmalayici bolumu |
| 18 Belgeler | `README.md` (yeni bolum + Faz D satiri), `SQL.md` (`ALTER DATABASE KEY`), `DLL_KULLANIM.md` (`VdbEncrypt*`), bu dosya |

### Mutasyon kaniti (Adim 11)

| Bozma | Sonuc |
|---|---|
| `VDB_FLAG_ENCRYPTED` bayragi dusurulurse | KIRMIZI |
| Etiket dogrulamasi atlansa | KIRMIZI |
| `Compact` bayrak yazmasa | KIRMIZI |
| IV HMAC'tan uretilse | KIRMIZI (68-konum dongusu) |
| `FillChar` kaldirilsa | **maskelendi** — ardindan `SetLength(Value,0)` var; test bunu gormez |

### Dogrulama (Adim 18 sonu itibariyla)

| Paket | Sonuc |
|---|---|
| `sqltest` | **918/918** (T74/T75/T76/T77 sifreleme gruplari dahil) |
| `vdbcrypttest` | **60/60** (PBKDF2/HMAC/AES vektörleri, `.key`, etiket) |
| `vdbapitest` | **123/123** (10 yeni `VdbEncrypt*` export'u LoadLibrary ile) |
| `vdbclienttest` | **85/85** (ham anahtar + parola + rekey yolu) |
| `cdc_test` | **38/38** — CDC: 3 INSERT / 1 UPDATE / 1 DELETE olayi + `OldValues` + sema kaydinin atlanmasi; Time Travel: WAL gecmisinden onceki deger + `AS OF` ayristirma + checkpoint siniri (gecici klasorde calisir) |
| `had`, `vdbgui`, `vdbapi.dll` | derleniyor (`build_dll.ps1` yollari guncellendi) |

---

## FAZ 4 — CDC / TIME TRAVEL KAYDI (2026-10-05)

### Ne kırık bulundu (hepsi test edilmeden "gecti" gorunuyordu)

| Kalem | Bulundugu sey | Kanit |
|---|---|---|
| `VDbCdc.pas` | `.wal` dosyasini **`TVDbRecHead`** (ana dosya kayit basligi) olarak okuyordu; gercek WAL bicimi **`TVDbWalHead`** (`WALR`, Key, duz bayrak, Len, CRC) ve icinde `Seq`/`BATCHEND` yok. Sonuc: CDC **hicbir zaman dogru olay uretemezdi** | duzeltme sonrasi 5/5 olay; eski kod olay uretmezdi |
| `VDbCdc.pas` | Otomatik WAL acilmiyordu → dosya hic dolmaz, `ProcessWal` hep bos gorurdu | `Start` artik `WALEnabled := True`; test `Start WAL acik birakti` |
| `VDbTimeTravel.pas` | `ScanWal`, `FWalEntries`, `TWalEntryArray` diye bir API **yoktu**; dosya hicbir projede derlenmiyordu | artik `TVDb.ReadWalEntry` + `WalRecordCount` ile calisir; 38 assertion |
| `cdc_test.lpr` | Assertion yoktu (`WriteLn` + "gecti") **ve paylasilan `db\veritabani.odb` dosyasina yaziyordu** | simdi gecici klasor + 38 assertion + hata durumunda exit 1 |
| `TVDbWalHead` | `implementation` icindeydi → dis birimler bicimi goremiyordu | type + `VDB_WAL_MAGIC` artik `VDbCore` **interface**'inde |

### Yapilanlar

1. `VDbCore.pas`: `TVDbWalHead`/`VDB_WAL_MAGIC` interface'e tasindi; yeni
   `ReadWalEntry(AIndex, Key, Flags, Value)` eklendi (ayni dogrulama
   kurallari: magic/bayrak/uzunluk/CRC/yirtik kuyruk; dosya sadece okunur).
2. `VDbCdc.pas` tamamen yeniden yazildi: dogru bicim, WAL'den satir
   cozme (`DecodeRowDataPublic`), insert/update/delete ayristirma,
   `FSeen` haritasi (silme olayinin PK/onceki degerini besler),
   periyodik `Flush`, gorunurluk sayaclari (`EventCount`/`SkippedCount`/
   `PendingCount`), checkpoint'te indeks sifirlama.
3. `VDbTimeTravel.pas` yeniden yazildi: `GetValueAt`/`GetRowAt`/
   `HistoryCount` WAL gecmisinden; `ExecSnapshot` **aktif snapshot'ta
   acik `ecUnsupported` hata verir** (SQL'e bagli olmadigi icin sessizce
   yanlis cevap donmez); `ParseSnapshotSpec` ISO + yerel tarih ayarlari.
4. `cdc_test.lpr` yeniden yazildi: gecici klasor, 38 assertion.
5. **Faz 4 devami (06.10.2026): `docs/01..04` envanter tazelendi** —
   `01-MOTOR.md` (yeni birimler `VDbCrypt`/`VDbCdc`/`VDbTimeTravel`, guncel
   satir/byte, akis semasi), `02-DOSYA-FORMATI.md` (baslik `Flags` duzeltmesi
   `VDB_HFLAG_HAS_ENCRYPTED=1`, `ENCRYPTED` kayit bayragi, sifreleme bicimi +
   `.key` 58 bayt, **gercek `.wal` bicimi** — eskisi "iskelet" diyordu),
   `03-API-DLL.md` (47 export: +3 otomatik-WAL, +9 sifreleme; 1/0 donus
   sozlesmesi; guncel dosya boyutlari), `04-VERITABANI-DOSYALARI.md`
   (guncel liste + `.onceki` kopyasi + testlerin gecici klasore yazma notu).
   Ayrica `mtakipwebsrv.lpi` onarildi (artik derleniyor) ve `SQL.md` §5'te
   F2-21 celiski notu kapatildi.

### Dogrulama (Faz 4 sonu)

| Paket | Sonuc |
|---|---|
| `sqltest` | **918/918** |
| `vdbapitest` | **123/123** |
| `vdbclienttest` | **85/85** |
| `vdbcrypttest` | **60/60** |
| `cdc_test` | **38/38** |
| `had`, `vdbgui`, `vdbapi.dll` | derleniyor |

### Durust kayit: paylasilan veritabanina yazim

`cdc_test` ONCEDEN sabit `D:\veritabani\db` klasorunu kullanip oraya
`cdc_test` tablosu yaziyordu; bu oturumda 2 kez calistirildi ve
`db\veritabani.odb` guncellendi. Kullanicinin yedegi oldugu soylendi ve
dosya kullanici tarafindan geri yuklendi; test o zamandan beri **gecici
klasore** yaziyor. `satis.odb` ve `mtakip.odb` hic dokunulmadi.

### Bilincli sinirlar

- Gecmis = WAL = **son checkpoint'ten sonra**; `CheckpointWAL` sonrasi
  `HistoryCount = 0` (testle dogrulandi).
- `Seq` = WAL kayit indeksi; WAL basta **sira numarasi tasiyamaz**.
- `SELECT ... AS OF ...` 06.10.2026'da **SQL'e baglandi** (yalnizca
  `SEQUENCE`; TIMESTAMP/VERSION hala bilerek reddedilir) — bkz.
  *SQL 'AS OF' INTEGRASYONU*; `ParseSnapshotSpec` hala yalnizca
  dogrulayici olarak duruyor.

---

## SQL 'AS OF' INTEGRASYONU (2026-10-06)

Faz 4 kaydindaki "gelecek is" maddesi tamamlandi: `SELECT ... AS OF
SEQUENCE <n>` artik SQL parser + executor uzerinden calisir; API'deki
`TVTimeTravel` yoluna ek olarak dogrudan sorguyla okunur.

### Ne yapildi

| Birim | Degisiklik |
|---|---|
| `VDbAst.pas` | `TSqlAsOfKind (saoNone/Sequence/Version/Timestamp)` + `TSqlSelectStmt.AsOf/AsOfValue/AsOfText` |
| `VDbParser.pas` | `ParseFromClause` icine `AS OF` kuyrugu (`FROM t [AS] [alias] AS OF ...`, alias oncesi/sonrasi iki varyant) + yeni `ParseAsOfTail` (SEQUENCE sayi dogrulamali; VERSION/TIMESTAMP metni birakilir, executor'da acikca reddedilir) |
| `VDbExecutor.pas` | `ExecSelect`'te kapsam disi redler (`JOIN`, `WITH`, `TIMESTAMP`, `VERSION` -> `ecUnsupported`) + yeni `BuildAsOfRows` (WAL'i 0..N tarayip anahtar durumu kurar, mevcut satirlarla birlestirir, sonucu WHERE/ORDER/GROUP/LIMIT hattina verir) |

### Test edilen semantik (T78, 31 kontrol)

- `n` dahil uygulanmis goruntu; **silinmis satir** N'deki son PUT degeriyle
  geri gelir; **N sonrasi eklenen satir** gorunmez; UPDATE oncesi deger
  okunur; `WHERE`/`ORDER BY`/`LIMIT`/`COUNT` gecmis kumeye uygulanir.
- `n >= WalRecordCount` son kayda kirpilir (guncel sorguyla eslestigi test).
- Gecmis yoksa (WAL kapali / `CheckpointWAL` sonrasi) -> `ecUnsupported`.
- `TIMESTAMP`/`VERSION` -> `ecUnsupported` (WAL'de damga/surum yok);
  `JOIN` + `AS OF` -> `ecUnsupported`; bozuk sayi/tur -> `ecSyntaxError`.
- Alias iki varyantta da calisir (`FROM k x AS OF`, `FROM k AS x AS OF`).

### Mutasyon kaniti (kirmizi-yesil)

`BuildAsOfRows`'taki "gecmis deger" (`st.Vals`) gecici olarak "hep guncel
satir" (`curRows[i]`) yapildi -> **2 FAIL** ("UPDATE oncesi eski deger" ve
"INSERT oncesi deger"; 949 -> 947). Geri alininca **949/949**.

### Duzeltme sirasinda ogrenilenler

- FPC `TDictionary` default setter'i (`d[k] := v`) **eksik anahtarda
  "Item not found" firlatir**; ekleme/degistirme `AddOrSetValue` ile
  yapilmali. Ilk denemede 17 AS OF testi bu yuzden kirmizi goruldu;
  kaynak bulunup 4 atama duzeltilince yesile dondu.
- Test beklentisi de motor kadar onemli: en sonda id=2 silinmis oldugu
  icin "3 satir" beklentisi **yanlisti** (guncel tabloda 2 satir var);
  motor dogru donduruyordu. Beklenti duzeltildi, motor degil.

### Dogrulama (06.10.2026)

| Paket | Sonuc |
|---|---|
| `sqltest` | **949/949** (T78 = 31 AS OF kontrolu dahil) |
| `cdc_test` | **38/38** |
| `vdbapitest` | **123/123** |
| `vdbclienttest` | **85/85** |
| `vdbcrypttest` | **60/60** |
| `had`, `vdbgui`, `mtakipwebsrv`, `vdbapi.dll` | derleniyor + linkleniyor |

Dokumantasyon: `SQL.md` §0b'ye "*`SELECT ... AS OF SEQUENCE`*" bolumu +
"Desteklenmeyenler" guncellendi; `README.md` *CDC / Time Travel* altina
AS OF bolumu + test tabloslari 949; `docs/01-MOTOR.md` satir/byte tazelendi
(VDbAst/VDbParser/VDbExecutor + AS OF notlari).

---

## CDC / TIMETRAVEL DLL EXPORT (2026-10-06) — POLL TABANLI

**Kapsam (sira listesi 3. madde):** CDC olaylari ve Time Travel okumasi
artik DLL'den de kullanilir. **Poll** secildi (kullanici onayi): callback
DLL sinirini gecmez, istemci olaylari ceker; degerler JSON dizi olarak
paketlenir. ABIsiz hicbir sey silinmedi/ezilmedi (sadece ekleyici
degisiklikler) -> minor surum artti.

### Eklenen export'lar (47 -> 54, ABI 1.0 -> 1.1)

| Export | Donus | Anlam |
|---|---|---|
| `VdbCdcStart(h)` | 0 / hata | `TVDbCdc` olusturur + calistirir; **otomatik WAL acilir** |
| `VdbCdcStop(h)` | 0 / hata | parcacigi durdurur; tampondaki olaylar **KALIR** (drain edilir) |
| `VdbCdcPollSize(h)` | >0 boyut / 0 / <0 hata | onunde duran olayin paket boyutu (tuketmez) |
| `VdbCdcPoll(h,buf,len)` | >0 / 0 / `VDB_E_BUFFER` / hata | paketi kopyalar **+ tuketir**; kucuk tampondada olay **KALIR** |
| `VdbCdcStats(h,...)` | 0 / hata | `ev`/`skip`/`pend`/`drop` sayaclari (NULL gecilebilir) |
| `VdbValueAt(h,tbl,pk,seq,buf,len)` | `VdbGet` sozlesmesi | WAL gecmisindeki **satir degeri** (JSON dizi); `-1` = o noktada satir yok |
| `VdbHistoryCount(h)` | >=0 / <0 | okunabilir gecmis sayisi (checkpoint ile sifirlanabilir) |

Paket (UTF-8, NUL'suz, alan ayirici `#30` = RS):

    kind #30 seq #30 table #30 pk #30 oldJson #30 newJson

`kind` 0/1/2 = insert/update/delete; json = kolon degerleri dizisi
(`["1","bir"]`, bos taraf `[]`). `seq` WAL'de alan olarak YOKTUR (DLL'de
uretilir). **Zaman damgasi pakette YOK** (istemci kendi UTC epoch-ms'ini
ekler) - `TCDCEvent.Timestamp` DLL sinirinda bilincli kaybolur.

### Yapilan degisiklikler

- `VDbCdc.pas` (341 -> 397 satir): `TryPeek`/`TryDequeue` (poll API),
  `Flush` korumasi (`OnChange` atanmamissa tampon **bosalmaz**),
  `MaxPending` (varsayilan 100000) + `DroppedCount` (bellek siniri:
  tasan olay SAYILIR, sessiz gizlenmez).
- `VDbTimeTravel.pas` (259 -> 260): bayat "AS OF SQL'e bagli degil" iddia
  metni guncellendi (artik `VDbExecutor.BuildAsOfRows`'a bagli);
  `ExecSnapshot` hata mesaji duzeltildi.
- `vdbapi_core.pas` (1418 -> 1754): `TVDbApiDb.Cdc` alani (**`CloseAll`'da
  ilk o serbest birakilir** - parcacik Tb'ye bakar), 7 `Core_*` fonksiyonu,
  yerel JSON serilestirici (`JsonEscStr`/`JsonArr`/`PackCdcEvent`) ve
  `VdbGet` sozlesmesini taklit eden `CopyOutBuf`; ABI minor 1.0 -> 1.1.
- `vdbapi.lpr`: 7 wrapper + export (47 -> **54**).
- `vdbapi.h`: CDC/TT bolumu (paket bicimi + kurallar) + **unutulmus
  `VdbEncrypt*` bildirimleri** eklendi (export'lar 2026-10-05'te
  acilmisti, baslik guncellenmemisti); surum `0x00010100`.
- `VDBClient.pas` (776 -> 926): `CdcStart/CdcStop/CdcPollSize/CdcPoll(out)/
  CdcStats(out)/ValueAt(out)/HistoryCount` + fonksiyon isaretcileri; kendi
  `VDB_API_VERSION` sabiti de 1.1'e cekildi (DLL ile eslestigi kontrol
  edilir). `ValueAt` iki asamali (`-boyut` / `-1`) yasayan API'de yalnizca
  `True/False` olarak sunulur.
- Testler: `vdbapitest` **+47 kontrol** (123 -> 170; Start oncesi hatalar,
  bozuk handle, olay uretimi bekleme, kucuk tampon -> `VDB_E_BUFFER` +
  olayin **kalmasi**, 3 olayin JSON dogrulamasi, drain, stats, ValueAt
  INSERT/UPDATE/DELETE/oncesi/olmayan-pk, calisirken kapatma),
  `vdbclienttest` **+16 kontrol** (85 -> 101; sarmalayici poll, ValueAt,
  hata firlatma, idempotent Start, calisirken kapatma).

### Mutasyon kaniti (kirmizi-yesil)

`TVDbCdc.Flush`'teki poll korumasi (`if not Assigned(FOnChange) then Exit`)
gecici olarak kaldirildi -> tampon her Flush'te bosaldi, olaylar kayboldu
-> **7 FAIL** (170 -> 163: "3 olay cekildi (sema kaydi olay DEGIL)
cnt=0" + altindaki tum JSON dogrulamalari). Geri alinca **170/170**.

### Dogrulama (06.10.2026)

| Paket | Sonuc |
|---|---|
| `sqltest` | **949/949** |
| `cdc_test` | **38/38** |
| `vdbapitest` | **170/170** (42 export cozuldu) |
| `vdbclienttest` | **101/101** |
| `vdbcrypttest` | **60/60** |
| `had`, `vdbgui`, `mtakipwebsrv`, `vdbapi.dll` | derleniyor (DLL 54 export, 1250816 byte) |

Dokumantasyon: `DLL_KULLANIM.md`'ye "*CDC / Time Travel*" bolumu (paket
bicimi, C + Delphi ornegi, tek-istemci/tampon kurallari);
`docs/03-API-DLL.md` 47 -> 54 export + ABI 1.1 + yeni bolum + test
sayilari; `docs/01-MOTOR.md` VDbCdc/VDbTimeTravel satirlari ve API
katmani byte'lari tazelendi; `README.md` CDC "Teslim modu" satiri +
Time Travel DLL notu + test tablosu.

### Duzeltme sirasinda ogrenilenler

- `VdbValueAt` **boyut sorgusu negatif** doner (`VdbGet` sozlesmesi);
  test ilk denemede `need > 0` bekledigi icin kirmizi goruldu
  (`-11` = `["1","bir"]` boyutu, `-16` = `["1","bir-yeni"]`). Beklenti
  duzeltildi - motor dogruydu.
- `sqltest`/`cdc_test` elle `ppc386` ile degil **`lazbuild *.lpi`**
  ile derlenmeli: `VDbCore` birimi `FileUtil` (LazUtils) ister; elle
  derlemede unit yolu bulunamadi (`Can't find unit FileUtil`).

---

## BAYAT PPU ILE GIZLENEN KAYNAK HATALARI ONARIMI (2026-10-06)

**Kapsam:** CDC/TT issi sirasinda `vdbspeed.lpr` elle `-B` (tam kaynaktan)
derlenmek istendi, `VDbCrc32.pas` sintaks hatasi verdi. Inceleme, kaynagin
**bir süredir derlenemez oldugunu**, taze derlemelerin ise bayat
`.ppu` onbellekleri (05.10.2026 tarihli) sayesinde **gectigini** ortaya
cikardi. Bu bir kod hatasi degil, **yorum hatasi** sinifidir:

> Pascal'da `{ ... }` blok yorumu **iç ice acilmez**. Yorum metni icindeki
> ilk `}` (ornegin `{HAT}`, `{"TTID":".."}`, `{$mode objfpc}` gibi bir
> yeri tutucu/JSON/ornek ifadenin parcasi) **yorumu erken kapatir**;
> kalan metin kod olarak okunur ve unit derlenemez.

**Bulunan ve onarilan dosyalar (yalnizca yorum sinirlari):**

| Dosya | Yer | Suclu ifade |
|---|---|---|
| `VDbCrc32.pas` | baslik yorumu | `{$mode delphi}` |
| `VDbTable.pas` | baslik yorumu (5. satir) | `{[u8 ctype][i32 vlen][vbytes]}` grup susu |
| `mtakip\webserver\mtdata.pas` | baslik yorumu | `{HAT}_{Tablo}`, `^[A-Z0-9_]{1,20}$` |
| `mtakip\webserver\websrv.pas` | **8 ayri yorum** | `{"TTID":".."}`, `{HAT}`, `{"M8":"..."}`, `{$mode objfpc}` |
| `dcpcrypt\dcpbase64.pas` | 2026-10-05 notu | ``` `{$MODE Delphi}` ``` |

**Onarim yontemi:** yorum metni **bir kelimesi bile silinmeden** yalin
`{...}` siniri `(* ... *)` sinirina cevrildi (ya da suslu ornek metinden
süsler arindirildi). Hicbir kod, sabit, imza veya anlam degistirilmedi.
`vdbapi_core.pas:1753`'teki ic ice gorunumu olan yorum **bilerek
birakildi**: orada toplam tek bir `}` var, ilk kapanis zaten dogru yerde
( zararsiz; derleniyor ).

**Kanit:**

- Yorum-ici acan-sus tarayicisi (proje geneli `*.pas`): artik **yalniz**
  zararsiz `vdbapi_core.pas:1753` donuyor.
- `mtdata.pas` (20322 satir), `websrv.pas` (23749 satir) ve
  `sqltest.lpr` **tam kaynaktan `-B`** ile sifirdan derleniyor.
- Sonrasinda tam surep: `sqltest` **949/949**, `cdc_test` **38/38**,
  `vdbapitest` **170/170**, `vdbclienttest` **101/101**,
  `vdbcrypttest` **60/60**; `vdbgui`, `had`, `mtakipwebsrv`,
  `vdbapi.dll` yeniden derlendi.

**Ogrenilen kural (tekrar):** artik **"yeşil" artirmal (incremental)
derleme kaynak butunlugunu garanti etmez** — bayat `.ppu`, kaynagi
derlemeyi engelleyen her hatayi saklayabilir. Birim degisikliginden sonra
temiz dogrulama icin `-B` ile (ya da `.ppu` onbellekleri disinda) tam
kaynak derlemek gerekir; yeni yorum yazarken icine kapanis suslu ifade
konmamali. Bu kural `VDbCrc32.pas` baslik yorumunda kendisi de
dokumante edildi.

---

## ILERI SQL — ADIM 4 (UYGULAMA_ANALIZ) — 4.1 CROSS JOIN (2026-10-06)

**Kapsam (sira listesi: Adim 4 bosluklari, hepsini sirayla ac):** yol
haritasi dokumanindaki Adim 4 kalemleri (3+ tablo JOIN, alt sorgu,
CASE-WHEN) **onceden bitmis** bulundu (dokuman bayatti); geriye SQL.md
"Desteklenmeyenler (bilerek yok)" listesindeki bosluklar kaldi.
**1. bosluk: `CROSS JOIN`.** Onceki durum: `CROSS` yoktu, hem `CROSS JOIN`
derlenemezdi hem de `CROSS OUTER JOIN`/ON'suz JOIN davranisi karisabilirdi.

**Degisiklik (yalnizca parser — `VDbParser.pas` 2100 -> 2116 satir):**

- `ParseFromClause` alias dislama listesine `CROSS` eklendi — boylece
  `FROM a CROSS JOIN b` yaziminda `CROSS` tablonun alias'i olarak
  yutulmuyor.
- JOIN zinciri dongusune `CROSS` anahtari: `jtInner` + `IsCross := True`;
  `CROSS OUTER ...` **`ecSyntaxError`** ("CROSS JOIN ile OUTER kullanilamaz").
- `ParseJoinClause(var JC, AllowNoOn: Boolean)`: ON artik **kosullu** —
  `ON` yazildiysa aynen parse edilir (INNER gibi filtre), `ON` yoksa ve
  `AllowNoOn` (yalniz `CROSS`) ise `OnCondition = nil` birakilir.
  ON'suz `INNER/LEFT/RIGHT/FULL JOIN` **hala** `"ON" bekleniyor` hatasi
  verir (regresyon testiyle kilitlendi).
- **Yurutucude hicbir degisiklik gerekmedi**: `EvalBool(nil) = True`
  (kosul her zaman dogru) zaten cartesius carpani demek; `CheckExpr`,
  `AssertNoWindow` ve hizli-on-eslesme yolu (`OnCondition is TSqlBinaryOpNode`
  -> nil'de False) nil-guvenli.

**Test:** `sqltest.lpr` `T08h_CrossJoin` (13 kontrol) + eski
`ChkErr('CROSS JOIN yok (hata)')` iddiasi cevrildi (`CROSS JOIN 3x3=9`).
Kapsam: ON'suz cartesius (3x2=6), ON'lu filtre, WHERE, nitelikli kolon,
ikili CROSS zincir (4x3x2=24), INNER+CROSS karisik zincir (4), ORDER BY,
DISTINCT, LIMIT, bos sag tablo (=0), `CROSS OUTER` hatasi, ON'suz
INNER/LEFT JOIN regresyon hatasi.

**Mutasyon kaniti:** klasik ic dongude `onOk := EvalBool(JC.OnCondition,...)`
ifadesine `(JC.OnCondition <> nil) and` eklendi (nil ON artik FALSE) ->
yeniden derleme -> **9 FAIL** (962 -> 953; yalnizca cartesius testleri
kirmizi, ON'lular ve hata testleri saglam) -> mutasyon geri alindi ->
**962/962**.

**Dogrulama — tam temiz derleme:** bu is sirasinda `mtakipwebsrv`
`Undefined symbol: VDBAST$_$TLIST$...` ile **linkte koptu**: bayat
webserver `.ppu/.o` kumesi taze `VDbParser.o` ile uyumsuz cikti (ayni
`.ppu` onbellek dersinin baska bir sekili). `mtakip\webserver\lib` +
`lib` + `yonetim\lib` (yalnizca derleme artefaktilari) silindi ve **her
sey sifirdan yeniden derlendi**; hata kendiliginden gecti. Sonrasinda
**5 test suiti de taze derlemeyle yeşil**: `sqltest` **962/962**,
`cdc_test` **38/38**, `vdbapitest` **170/170**, `vdbclienttest`
**101/101**, `vdbcrypttest` **60/60**; `sqltest`, `vdbgui`, `had`,
`vdbapi.dll` (11:03), `mtakipwebsrv` (11:02) taze.

**Dokuman:** `SQL.md` (§JOIN: CROSS ornekleri + kurallar; ozet satiri
"CROSS dahil"; "Desteklenmeyenler" listesinden `- CROSS JOIN` cikarildi),
`README.md` (SQL kapsami `INNER/LEFT/RIGHT/FULL/CROSS JOIN`; "Yok
(bilerek)" listesinden `CROSS` cikarildi), `docs/01-MOTOR.md`
(VDbParser satiri: yeni sayim + CROSS notu), bu kayit.

**Siradaki bosluklar (dokunulmadi):** `JOIN` + `GROUP BY`/aggregate,
`HAVING` icinde dogrudan aggregate, `NOT(...)` icinde OR (DNF), `WITH` +
DML / kolon alias / RECURSIVE, pencere cercevesi (ROWS/RANGE), iliskili
alt sorgu, `ALTER TABLE ADD/DROP CONSTRAINT`, `CREATE VIEW`, `PRAGMA`.

---

## ILERI SQL — ADIM 4 — 4.2 JOIN + GROUP BY/AGGREGATE (2026-10-06)

**Kapsam (sira listesi 2. bosluk):** SQL.md "Desteklenmeyenler"
listesindeki `` `JOIN` ile `GROUP BY`/`aggregate` birlikte `` maddesi.
Onceki durum: yurutucu `VDbExecutor.pas`'ta acik `ecUnsupported` reddi
(`'JOIN ile GROUP BY/aggregate desteklenmiyor'`) ve `sqltest.lpr`'de bunu
iddia eden iki `ChkErr` vardi.

**Degisiklikler:**

- **`VDbParser.pas` (2116 -> 2129 satir) — `ParseGroupBy` nitelikli kolon:**
  tokenizer noktayi AYRI token verdigi icin `GROUP BY m.sehir` yazimi
  sozdizimi hatasiyla (`anlasilamayan ek: .`) dusuyordu; ifade parserindaki
  gibi `m` + `.` + `sehir` birlestirme eklendi. (Yani nitelemeli GROUP BY
  hic calismamisti — SQL.md'nin "GROUP BY, x.ad ile" iddiasi da boylece
  gerceklesti.)
- **`VDbExecutor.pas` (3923 -> 3957 satir):**
  - JOIN dalindaki `ecUnsupported` reddi kaldirildi; `ExecJoinScan` sonrasi
    `(GroupByCols > 0) or HasAggregate` ise dogrudan **`ExecGroupBy`**'a
    yonlendirilip cikildi (WHERE'i `ExecGroupBy` zaten kendisi uygular;
    onceden filtrelemek yalnizca is yukunu azaltir). Set-op + aggregate
    reddi (F1-12, ayni mesaj) JOIN yolunda da korundu.
  - ORDER BY + OFFSET/LIMIT kuyrugu yerel **`FinishGroup`** prosedurune
    tasinildi; JOIN ve tek-tablo aggregate yolu ORTAK kullanir (kod
    tekrari yok; F1-20 cikti tip haritasi aynen korunur). *FPC notu:*
    nested prosedurde dis prosedur degiskeni `FOR` sayaci olamaz (4058) —
    sayac yerel tanimlandi.
  - **Grup anahtari cozumleme birebir metin aramasindan `FindColIdx`'e
    cevrildi**: sade yazim (`GROUP BY ad`) JOIN ciktisinda (`c.ad`) sonek
    kuraliyla, nitelikli yazim (`x.dept`, `m.sehir`) tam eslesmeyle
    cozulur — `SELECT`/`WHERE` ile AYNI kural. Eslesmezse **hata**
    (`ecColumnNotFound: GROUP BY kolonu bulunamadi: ...`): onceki kodda
    eslesmeyen kolon icin `key := ''` ile **tum satirlar tek gruba
    dusuyordu (SESSIZ YANLIS)**; bu da kapatildi.

**Test:** 2 eski `ChkErr` cevrildi (`JOIN + GROUP BY 3 grup`,
`JOIN aggregate tek satir COUNT=4`) + yeni `T08i_JoinAggregate` (20
kontrol): nitelemeli/sade GROUP BY, tek-satir aggregate (COUNT/SUM),
WHERE+JOIN+GROUP BY, LEFT JOIN'de **0'li grup** (siparissiz musteri),
HAVING (alias), `ORDER BY n DESC` (kuyruk tip haritasi), GROUP BY+LIMIT,
tek-tabloda nitelemeli GROUP BY, bilinmeyen GROUP BY kolonu hatasi,
set-op+aggregate hatasi. `sqltest` **962 -> 982/982**.

**Mutasyon kaniti (2):**
1. JOIN dalina `ecUnsupported` raise'i geri kondu -> **18 FAIL**
   (982 -> 964; yalnizca join+agg testleri kirmizi) -> geri al -> yeşil.
2. `FindColIdx` cozumlemesi eski birebir metin aramasina cevrildi (hata
   korunur) -> **5 FAIL** (982 -> 977: sade yazimli JOIN testleri +
   tek-tablo nitelemeli testler `GROUP BY kolonu bulunamadi` ile
   kirmizi) -> geri al -> **982/982**.

**Yapildigi sira: `mtakipwebsrv` tekrar linkte koptu — ve KOK NEDNI
kanitlandi (4.1'deki "temiz cache" dersinin asil aciklamasi):**

- Hata ayni: `Undefined symbol: VDBAST$_$TLIST$1$CRC8FB20096_...GETITEM/
  CLEAR`. COFF sembol tablosu analizi: `lib\` icinde bu sembolu **tanimlayan
  hibir nesne yok**, yalnizca `VDbParser.o`/`VDbExecutor.o` **cagiriyor**
  (ref). `ppudump` karsilastirmasi:

  | ppu | Interface Checksum | `TList<TWithQuery>` CRC |
  |---|---|---|
  | `mtakip\webserver\VDbAst.ppu` (10:31, **artik/proje koku**) | `6C168513` | `8FB20096` |
  | `...\webserver\lib\i386-win32\VDbAst.ppu` (11:02, lazybuild) | `44DABF83` | `DDC42B90` |
  | `yonetim\lib\...` (ba baki) | - | `BA911350` |

  **`VDbParser.ppu` (11:33) kaydi: `Uses unit: VDbAst (IntfcCrc: 6C168513)`**
  -> derleyici **bayat koku ppu'yu** okudu (farkli derleme bayraklariyla
  10:31'de manuel ppc386 ile uretilmis), baglayici ise `lib\`'deki farkli
  CRC'li `.o`'yu bagladi -> generic despecialization sembolleri hicbir
  yerde tanimsiz. Tum agac tarandi: `8fb20096` iceren TEK ppu bayat koku
  ppu'suydu. (4.1'de "lib klasorlerini sil + temiz derle" cozumunun
  calismasi da rastlanti degil: bayat ppu bayat kaynaklara gore STALE
  bulunup yeniden derleniyordu; bayrak/kaynak eslesmeyen tek bayat ppu
  koku'dekiydi.)

**Kalici cozum (artefakt hijyeni):**

- Bayat `*.ppu/*.o/*.a` dosyalari **silinmedi** — `Temp\opencode\
  stale-ppu-karantina` klasorune **tasinarak** karantinaya alindi:
  `mtakip\webserver\` koku (10:31 seti: VDbAst/VDbParser/VDbExecutor/
  VDbSql/VDbTable/... + websrv/mtdata + libimpVDbCrypt.a) ve
  `D:\veritabani\` kokunde UNIT artiklari (dcp*, VDBClient, VDbCrypt,
  VDbErr). Kaynak dosyalara dokunulmadi.
- `mtakip\webserver\lib` silindi -> temiz derleme -> **link GECTI**
  (`mtakipwebsrv.exe` 11:57:35).
- **Artirmal dogrulama (onceki hata senaryosu):** `VDbParser.pas`
  yeniden zaman damgalanip tekrar derlendi -> `mtakipwebsrv` (11:57:55)
  ve `sqltest` **ikisi de link gecti**; `cdc_test`/`vdbgui`/`had` artirmali
  derleme hatasiz; `build_dll.ps1` calisti (`vdbapi.dll` 11:58:50).

**Ogrenilen kalici kural (genisletildi):** proje KOKLERINDE
`*.ppu/*.o/*.a` biriktirilmemeli; birim ciktilari yalnizca proje
cikti klasorunde (`lib\...`) yasamalidir (manuel ppc386 icin `-FU` ile
ayri dizin kullan). Birim FPC generic **CRC'leri derleme baglamina gore
degisir** (ayni kaynak, 3 farkli CRC) — bayat ppu ile taze `.o` karisimi
`Undefined symbol: VDBAST$_$TLIST$...` seklinde gorunur. Tehis (ani
teshis): `COFF sembol tablosu (kim tanimliyor?)` + `ppudump` ile
`VDbX.ppu -> Uses unit: VDbAst` IntfcCrc kaydini taze ppu'nun
Interface Checksum'u ile karsilastir; esit degilse bayat ppu devrede.

**Son dogrulama (bu kayit oncesi):** `sqltest` **982/982**,
`cdc_test` **38/38**, `vdbapitest` **170/170**, `vdbclienttest`
**101/101**, `vdbcrypttest` **60/60**; artefaktlar: `mtakipwebsrv`
11:57:55, `vdbapi.dll` 11:58:50 (bayt 1251328), `sqltest` 11:57'de
yeniden baglandi.

**Dokuman:** `SQL.md` (§JOIN: 4.2 notu + 2 ornek; "Desteklenmeyenler"
listesinden `` `JOIN` ile `GROUP BY`/`aggregate` `` cikarildi; §GROUP BY:
cozumleme kurali + hata notu), `README.md` ("Yok (bilerek)" listesinden
`JOIN` + `GROUP BY` cikarildi; sayimlar 982), `DLL_KULLANIM.md` (982),
`docs/01-MOTOR.md` (VDbParser/VDbExecutor satirlari: yeni sayimlar +
4.2 notlari), yol haritasi Adim 4 durum notu, bu kayit.

## ILERI SQL — ADIM 4 — 4.3 HAVING ICINDE DOGRUDAN AGGREGATE (2026-10-06)

**Kapsam:** SQL.md "Desteklenmeyenler" listesindeki `HAVING` icinde
aggregate dogrudan yazma maddesi (`HAVING COUNT(*) > 1`) — 4.3'te
kaldirildi; `HAVING` artik `SELECT` listesinde alias olmasa da calisir.

**Kok neden:** `ExecGroupBy` (`VDbExecutor.pas` ~line 2468) `Stmt.HavingClause`
de `HasAggregateExpr(...)` ile `raise ecSyntaxError` (eski reddi) veriyordu.
Bu, `HAVING COUNT(*) > 1` gibi yazimlari hatayla reddediyordu; `SELECT`
listesinde alias (`AS n`) kullanarak (`HAVING n > 1`) dolayli calisiyordu.

**Degisiklikler (`VDbExecutor.pas` 3957 -> ~3990 satir):**

- `ExecGroupBy`'de eski `raise` kaldirildi.
- `ExecGroupBy` grup hesaplama dongusunde (`ExecGroupBy` yerel `FinishGroup`
  kuyruğu ile birlestirildi — 4.2'de tanimlanmisti) `HAVING` degerlemesi
  **grup baglami** (`FAggIdx`, `FAggSrcRows`, `FAggCNames`, `FAggCTypes`)
  ile yapilir: `FAggIdx := rowIdx; ... try ... finally restore`.
- `EvalExpr`'te (`TSqlFuncCallNode`) `FAggIdx <> nil` iken `IsAggFuncName(...)`
  dogruyorsa `EvalAggregateValue(...)` cagrilir; bu, SELECT listesi ile
  `HAVING` arasinda **TEK kod uygulamasini** paylasir (tekrar yok).
- `AggFuncCtype(fn)`: `COUNT`->`VCT_INT`, `SUM`/`AVG`->`VCT_FLOAT`,
  `MIN`/`MAX`->`FindColIdx(..., ColNames)` ile kolon tipi (`aggCt`).
  Bu, `HAVING`'de kolon referansi olmayan (`COUNT(*)`) veya nitelikli
  (`MIN(b.tutar)`) argumanlarin dogru tipte (metin sirasi yerine sayisal)
  karsilastirilmasini saglar (`'10' > '9'` false). Onceden `ct := VCT_STR`
  sabit oldugu icin metin sirasi hatasi oluyordu.
- `HasAggregate` artik `IsAggFuncName` kullanir.
- `ExecGroupBy`'te `tmpRow[j]` aggregate hesaplama `EvalAggregateValue(...)`
  ile tek uygulama.

**Test (`sqltest.lpr`):**
- Eski `ChkErr('HAVING desteklenmiyor (hata)', ...)` (`T09_GroupAggregate`)
  `Chk('HAVING dogrudan aggregate (kabul)', ...)` olarak cevrildi.
- Yeni `T09b_HavingAggregate` (16 kontrol): `HAVING COUNT(*) > 1/9`,
  `HAVING SUM > 950`, `AVG > 90`, `MIN > 100`, `MAX > 100`, SELECT'te
  aggregate yok (`SELECT dept ... HAVING COUNT(*) > 5`), alias + dogrudan
  (`HAVING n > 5 AND COUNT(*) < 100`), `ORDER BY + LIMIT`, `WHERE + HAVING`,
  `JOIN + HAVING COUNT(*)` (nitelikli/sade arguman), `HAVING MIN (nitelikli`
  `b.tutar` / sade `tutar`), bilinmeyen kolon hatasi.
- `sqltest`: **997 / 0** (982'dan 14 yeni test + 2 eski `HAVING` testinin
  cevrilmesi).

**Mutasyon kaniti:**
1. `ExecGroupBy`'de eski `raise` geri eklendi -> **17 FAIL** (`997 -> 980`;
   T09b'nin tum 16 kontrolu + eski HAVING testleri kirmizi; `HAVING icinde
   aggregate dogrudan kullanilamaz...` hata mesaji). -> `raise` kaldirildi
   (`raise` satiri silindi, `try/finally` baglami korundu) -> **997/0 yesil**.

**Yapildigi sira:** `sqltest` artirmali derleme (`VDbParser.pas` dokunulduktan
sonra) -> `997/0`. `mtakipwebsrv` artirmali (motor dokunulduktan sonra da)
`11:57:55`'te link gecti; bu kayit sirasinda tekrar dokunulmadigi icin
`11:57:55` surumu gecerli.

**Dokuman:** `SQL.md` (§GROUP BY: 4.3 notu + `HAVING` kural guncellemesi;
"Desteklenmeyenler" `HAVING` dogrudan aggregate maddesi cikarildi),
`README.md` (982 -> 997), `DLL_KULLANIM.md` (982 -> 997), `docs/01-MOTOR.md`
(VDbExecutor: 3957 -> ~3990 + 4.3 notu; yeni `IsAggFuncName`/`EvalAggregateValue`/`AggFuncCtype` yardimcilar + grup baglami), bu kayit.

**Sonucun ozeti:**
- 4.1 `CROSS JOIN`: **BITTI**.
- 4.2 `JOIN` + `GROUP BY`/aggregate + `FindColIdx`: **BITTI** (982, mutasyon 18+5 FAIL).
- 4.3 `HAVING` icinde dogrudan aggregate: **BITTI** (997, mutasyon 17 FAIL).
- `mtakipwebsrv` link hatasi kok neden: **KANITLANDI ve KALICI DEDILDIGI**
  (bayat `.ppu` karantinaya alindi; `ppudump` IntfcCrc karsilastirmasi,
  `COFF` sembol tablosu analizi).
- Guncel durum: `sqltest` **997/0**, `cdc_test` 38, `vdbapitest` 170,
  `vdbclienttest` 101, `vdbcrypttest` 60; `mtakipwebsrv` ve `vdbapi.dll`
  artirmali derlemeyle yesil; `DENETIM_VE_YOL_HARITASI.md` 4.1 + 4.2 + 4.3
  kayitlari tamam; `UYGULAMA_ANALIZ` Adim 4 durum guncel.

**Guncel durum: `sqltest` 999/2** (4.5 `WITH`: `RECURSIVE` 5 satir (maxIter=3), `kolon alias` (`ColAliases` uygulanmadi), `WITH + INSERT` (`ParseSelect` DML icin yeterli degil) — 3 FAIL; diger 4.5 degisiklikler yesil), `cdc_test` 38, `vdbapitest` 170,
`vdbclienttest` 101, `vdbcrypttest` 60; `mtakipwebsrv` ve `vdbapi.dll`
artirmali derlemeyle yesil; `DENETIM_VE_YOL_HARITASI.md` 4.1 + 4.2 + 4.3 + 4.4
kayitlari; `UYGULAMA_ANALIZ` Adim 4 durum guncel (4.3 bitti, 4.4 basladi).

**Siradaki bosluklar:** `NOT(...)` icinde `OR` cok kosullu grup (4.4 siniri
kaldi: `NegateGroup` `Length(G[i])>1` hala `ecUnsupported`; AST'de `NotNode`
calisir, `ParseWhereGroups` / 2-tablo hash join icin DNF siniri surer),
`WITH` + DML / kolon alias / RECURSIVE, pencere cercevesi (ROWS/RANGE),
iliskili alt sorgu, `ALTER TABLE ADD/DROP CONSTRAINT`, `CREATE VIEW`,
`PRAGMA`.

**Bir sonraki adim (4.4):** `NOT(...)` icinde `OR` (DNF temsilini
`TSqlExprNode` AST'de `NotNode(OrNode(...))` biciminde aciklayip
`EvalBool`'ta `Not(Not...)` indirgenmesiyle cozmeyi deneyecegim; bu,
`NOT`'un AST'ye eklenmesi gerektiginden `VDbParser.pas`'ta bir
`ParseNot` / `ParseUnaryOp` genisletmesi + `VDbExecutor.pas` `TSqlUnaryOp`
`Not` kolunun `EvalBool`'ta cozumlemesi anlamina geliyor.
