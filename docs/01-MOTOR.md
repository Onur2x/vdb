# 01 â€” VDB Motor Birimleri

> Kaynak: `D:\veritabani\*.pas` â€” salt okuma ile Ã§Ä±karÄ±ldÄ±, 04.10.2026.
> **Tazeleme: 06.10.2026** â€” ÅŸifreleme (Faz D), otomatik WAL, F2/F3
> dÃ¼zeltmeleri, `VDbCrypt`/`VDbCdc`/`VDbTimeTravel` eklendikten **ve
> `SELECT ... AS OF SEQUENCE` baÄŸlandÄ±ktan sonra** satÄ±r/byte deÄŸerleri
> yeniden Ã¶lÃ§Ã¼ldÃ¼ (byte = dosya boyutu, satÄ±r = tam satÄ±r sayÄ±sÄ±). HiÃ§bir
> **kaynak dosyasÄ±** deÄŸiÅŸtirilmedi; bu belge yalnÄ±zca envanteri gÃ¼ncellendi.

Veri akÄ±ÅŸÄ±:

```
SQL metni -> VDbParser -> VDbAst -> VDbExecutor -> VDbTable -> VDbCore -> .odb
                                                     |               |
                                                     |               +-> .wal (otomatik WAL: WALEnabled=True)
                                                     |                     |
                                                     |                     +-> VDbCdc  -> TCDCEvent callback / poll (DLL VdbCdcPoll)
                                                     |                     +-> VDbTimeTravel -> GetValueAt/GetRowAt
                                                     +-> AS OF SEQUENCE: BuildAsOfRows
                                                         (WAL'den gecmis goruntu, sonra normal WHERE/ORDER/LIMIT)
```

## Ã‡ekirdek katman

| Birim | SatÄ±r / Byte | GÃ¶rev |
|---|---|---|
| `VDbCore.pas` | 2555 / 84874 | Append-only `UInt64 -> Bytes` KV motor. CRC, dosya-sonu yÄ±rtÄ±k truncate, batch atomikliÄŸi (`BATCHEND`), `fsync`, kilit (`TCriticalSection`). Public: `Open/Close, Put/Get/Exists/Delete, BeginBatch/CommitBatch/AbortBatch, Flush, Count/GetAllKeys/ScanAll, Compact/AutoCompact, Verify, BackupTo`, WAL (`WriteAheadWAL/ReplayWAL/CheckpointWAL/HasWAL/WalRecordCount/WalPath`, **otomatik WAL** `WALEnabled`/`WalAutoCount`, **`ReadWalEntry`** â€” CDC/TimeTravel'Ä±n kullandÄ±ÄŸÄ± doÄŸrulamalÄ± geÃ§miÅŸ okumasÄ±), **kayÄ±t seviyesi ÅŸifreleme** (`SetEncryptionKey/ClearEncryptionKey/CreateKeyFile/OpenKeyFile/KeyPath/EncryptionKeyFingerprint/IsEncrypted/HasEncryptedRecords/RekeyWithPassword`). Sabitler: `VDB_MAGIC=$56444231`, `VDB_FLAG_PUT=0, DEL=1, BATCHEND=2, ENCRYPTED=4, COMPRESSED=8`, `VDB_MAX_VALUE=16 MB`, `VDB_FILE_MAGIC=$42444F56 ('VODB')`, `VDB_FILE_VER=2`, `VDB_HDR_SIZE=16`, `VDB_WAL_MAGIC=$57414C52 ('WALR')`. **`TVDbWalHead` (21 bayt WAL baÅŸlÄ±ÄŸÄ±) artÄ±k interface'te** â€” VDbCdc/VDbTimeTravel aynÄ± biÃ§imde okur. |
| `VDbTable.pas` | 4602 / 160639 | KV Ã¼stÃ¼nde tablo/sema katmanÄ±. `TColDef/TFkDef/TIdxDef`, `VDB_SCHEMA_KEY=0`, `VSCH1` etiketi, constraint + FK (`RESTRICT/CASCADE/SETNULL/SETDEFAULT`), CHECK, bellek-iÃ§i sekonder indeks. Public: `Open/Close, CreateTable/DropTable, AlterAddColumn/DropColumn/RenameColumn/ColumnType/SetDefault/DropDefault/SetNotNull/RenameTable, Insert/BatchInsert, ReadRow/ScanRows/CandidatePks, UpdateWhere/UpdateRowInPlace, Delete/DeleteWhere, CreateIndex/CreateIndexCols/DropIndex/RebuildIndexes, Lock/Unlock`, + **`DecodeRowDataPublic` / `GetTableNameById`** (VDbCdc/VDbTimeTravel iÃ§in ince sarmalayÄ±cÄ±). `PutRow` artÄ±k **elle `WriteAheadWAL` Ã§aÄŸÄ±rmaz**; yazÄ±m `AppendRec` iÃ§inden otomatik WAL'e gider. |
| `VDbCrc32.pas` | 110 / 2937 | Saf Pascal IEEE CRC32 (`VDbCrc32Init/Final/Update/Of/...`). KayÄ±t + dosya baÅŸlÄ±ÄŸÄ± bÃ¼tÃ¼nlÃ¼ÄŸÃ¼. **Yorum kuralÄ± (06.10.2026):** blok yorumu iÃ§ine `{...}` gibi kapanÄ±ÅŸ sÃ¼slÃ¼ ifade yazÄ±lmaz â€” ilk `}` yorumu erken kapatÄ±r ve unit derlenemez (bkz. `DENETIM_VE_YOL_HARITASI.md`, bayat-PPU onarÄ±mÄ±). |
| `VDbSync.pas` | 155 / 4219 | `fsync` + dizin flush + dosya kilidi (`VDbFlushStream/VDbFlushDir/VDbLockStream/UnlockStream`, `VDB_LOCK_EX/NB/UN`). Ã‡ift-aÃ§ma ve crash-kalÄ±cÄ±lÄ±k korumasÄ±. |
| `VDbCrypt.pas` | 763 / 25719 | **KayÄ±t seviyesi ÅŸifreleme (Faz D)**: AES-256-CTR + HMAC-SHA256 (encrypt-then-MAC), PBKDF2 ile parolaâ†’anahtar, `.key` dosyasÄ± (58 bayt, **dosyada sÄ±r yok**), IV HMAC'ten tÃ¼retilir (68-konum dÃ¶ngÃ¼sÃ¼ testi). `VDbCore` `EncryptValue/DecryptValue` ile bunu Ã§aÄŸÄ±rÄ±r. |
| `VDbCdc.pas` | 397 / 10351 | **Change Data Capture**. `.wal`'Ä± `TVDbWalHead` biÃ§iminde okur, satÄ±r Ã§Ã¶zÃ¼p `INSERT/UPDATE/DELETE` olayÄ± Ã¼retir (`TCDCEvent`, `OldValues` bir `FSeen` haritasÄ±ndan). `Start` otomatik WAL'i aÃ§ar; ÅŸema kayÄ±tlarÄ± olay deÄŸildir (`SkippedCount`). **Ä°ki teslim modu (2026-10-06):** `OnChange` atanmÄ±ÅŸsa `Flush` olaylarÄ± callback'e taÅŸÄ±r; **atanmamÄ±ÅŸsa tampon olaylarÄ± tutar** ve `TryPeek`/`TryDequeue` ile istemci (DLL `VdbCdcPoll`) sÄ±rayla Ã§eker. Tampon `MaxPending` (varsayÄ±lan 100000) sÄ±nÄ±rÄ±nÄ± aÅŸarsa en eski olay dÃ¼ÅŸer ve `DroppedCount` artar. |
| `VDbTimeTravel.pas` | 260 / 7014 | **WAL geÃ§miÅŸinden Ã¶nceki deÄŸer**: `GetValueAt/GetRowAt/HistoryCount` (`Seq` = WAL kayÄ±t indeksi), `ParseSnapshotSpec` (yalnÄ±zca metin doÄŸrulamasÄ±; SQL'in `AS OF` kuyruÄŸu `VDbParser.ParseAsOfTail`'de ayrÄ± Ã§Ã¶zÃ¼lÃ¼r). `ExecSnapshot` aktif snapshot'ta `ecUnsupported` verir. DLL tarafÄ±: `VdbValueAt`/`VdbHistoryCount`. |
| `VDbWal.pas` | 81 / 2200 | Harici `.wal` iskeleti (`WAL_FILE_MAGIC/VER`, `WalWriteAhead/WalReplay/WalCheckpoint/WalExists`). `.odb`'yi bozmadan yaz-Ã¶nce-log taslaÄŸÄ±. **HiÃ§bir proje kullanmÄ±yor** â€” gerÃ§ek WAL `VDbCore`'da (`TVDbWalHead`/`WALR`). |
| `VDbTest.pas` | 44 / 909 | WAL duman testi (`RunWalCrashTest(DbPath)`). HiÃ§bir proje kullanmÄ±yor (Ã¶lÃ¼ kod durumunda). |

## SQL katmanÄ±

| Birim | SatÄ±r / Byte | GÃ¶rev |
|---|---|---|
| `VDbSql.pas` | 3193 / 108211 (4.4 ile ~3300) | DÄ±ÅŸ cephe `TVSql`: `Exec(Sql)`, `Exec(Sql,Params)`, `SplitStatements`, `ExecAll`, `AutoTransaction`. Betik bÃ¶lme + otomatik transaction + DB dosya yÃ¶netimi. `ParseWhereGroups` (DNF: OR'lu AND gruplari; 2 tablo hash join WHERE filtrelemesi). `NegOp` (`=` `<->` `<>`). **4.4:** `NegateGroup` De Morgan dagitimi (`Length(G[i])=1`: `NOT (a=1 OR b=2)` -> tek AND grubu `a<>1 AND b<>2`; cok kosullu OR -> `ecUnsupported` acik hata; `ParseNotExpr` (`suoNot`) `ParseCmpExpr`'i sarar; `NotNode(OrNode(...))` AST'de `EvalBool` ile dogrudan cozumlenir). |
| `VDbAst.pas` | 940 / 22729 | Tip-gÃ¼venli AST dÃ¼ÄŸÃ¼m modeli (`TSqlNode/TSqlExprNode`, literal/kolon/binary/unary/IN/subquery/BETWEEN/func/CASE, `TSqlSelect/Insert/Update/Delete`, `CreateTable/AlterTable/DropTable`, `CreateIndex/DropIndex`, TX/Admin/JSON, `TSqlResult`). Her dÃ¼ÄŸÃ¼m alt-aÄŸacÄ± `Destroy`'da temizler. **+ `TSqlAsOfKind` / `TSqlSelectStmt.AsOf/AsOfValue/AsOfText`** (2026-10-06, `AS OF`). |
| `VDbParser.pas` | 2129 / 68188 | Recursive-descent ayrÄ±ÅŸtÄ±rÄ±cÄ±. Tek giriÅŸ: `Parse(ASql,AParams):TSqlStmtNode`. SELECT/WITH/INSERT/UPDATE/DELETE/CREATE/ALTER/DROP/ADMIN/JSON ayrÄ±ÅŸtÄ±rÄ±r. Derinlik sÄ±nÄ±rÄ± (256) F1-22 ile eklendi. **+ `ParseAsOfTail`**: `FROM t [AS] [alias] AS OF SEQUENCE\|VERSION\|TIMESTAMP` (2026-10-06). **+ `CROSS JOIN`** (2026-10-06): `CROSS` JOIN anahtarÄ± `jtInner` olarak Ã§Ã¶zÃ¼lÃ¼r, `ParseJoinClause(.., AllowNoOn)` ile ON opsiyoneldir (yoksa `EvalBool(nil)=True` â†’ cartesius); `CROSS OUTER` reddedilir, ON'suz `INNER/LEFT/... JOIN` hatasÄ± sÃ¼rer. **+ `ParseGroupBy` nitelikli kolon** (2026-10-06): tokenizer noktayÄ± ayrÄ± token verdiÄŸi iÃ§in `GROUP BY m.sehir` artÄ±k `m`+`.`+`sehir` birleÅŸtirilerek okunur (eskiden yalnÄ±z ilk token alÄ±nÄ±p kalan `.sehir` sÃ¶zdizimi hatasÄ± ya da sessiz tek-grup oluyordu). |
| `VDbExecutor.pas` | 3957 / 145952 | AST yÃ¼rÃ¼tÃ¼cÃ¼ `TVSqlExecutor.Execute(Stmt):TSqlResult`. WHERE/ORDER/GROUP/JOIN/WINDOW/UNION, DDL/TX (`DoSort/ExecGroupBy/ExecJoinScan/ComputeWindows`, `VDB_MAX_RESULT_ROWS`). F2-18/19/20 ile tekilleÅŸtirme O(1) hash, pencere kopyasÄ±z sÄ±ralama, IN alt-sorgu kovasÄ±. **+ `BuildAsOfRows`** (2026-10-06): WAL geÃ§miÅŸinden tablo gÃ¶rÃ¼ntÃ¼sÃ¼; JOIN/WITH/TIMESTAMP/VERSION reddi `ecUnsupported`. **+ `JOIN` + `GROUP BY`/aggregate** (2026-10-06): JOIN dalÄ± `ecUnsupported` reddi yerine `ExecGroupBy`'a yÃ¶nlenir (WHERE'i `ExecGroupBy` kendisi uygular); ORDER BY + OFFSET/LIMIT kuyruÄŸu JOIN ve tek-tablo yolu iÃ§in ortak yerel `FinishGroup`'a taÅŸÄ±ndÄ±; `ExecGroupBy` grup anahtarÄ± Ã§Ã¶zÃ¼mÃ¼ birebir metin aramasÄ±ndan `FindColIdx`'e Ã§evrildi (sade/nitelikli yazÄ±m, bulunamazsa hata â€” sessiz tek-grup yok); set-op + aggregate reddi sÃ¼rer. |

## YardÄ±mcÄ± katman

| Birim | SatÄ±r / Byte | GÃ¶rev |
|---|---|---|
| `VDbJson.pas` | 1018 / 29942 | `VDbExportJson(Tb,Path,Table)` / `VDbImportJson(Tb,Path)`, `VDbCtypeName/ByName`. Kanonik sÄ±ralÄ± JSON taÅŸÄ±ma. **F-22:** ozgÄ±rsel JSON ayrÄ±Å¸tÄ±rÄ±cÄ± + `@>` `<@` `?` `?|` `?&` operatorleri. |
| `VDbXml.pas` | 723 / 20130 | **F-23:** XML ayrÄ±Å¸tÄ±rÄ±cÄ± + yol motoru (`/`, `//`, `*`, `[@a='v']`, `[@a]`, `[n]`) + kurma (`XMLELEMENT`/`XMLCONCAT`/`XMLESCAPE`/`XMLPARSE`/`XMLEXTract`/`XMLEXISTS`/`XMLCOUNT`/`XMLATTR`). |
| `VDbRange.pas` | 452 / 16830 | **F-25:** RANGE (aralik) tipi. `TRangeBound` (Lo/Hi/LoIncl/HiIncl/Valid) + ayristirma/kanonik yazim + `&&` `<<` `>>` `&<` `&>` `@>` `<@` `-|-` operatorleri + `RANGE()`/`CONTAINS()` kuruculari. Bos aralik (`EMPTY`) `@>`/`<@` icin her seyi kapsar, diger operatorlerde `False` doner. |
| `VDbSpatial.pas` | 196 / 5740 | **F-24:** `DISTANCE` (Oklid), `HAVERSINE` (kure, km), `IN_CIRCLE`, `IN_BOX`, `IN_POLYGON`/`POINT_IN_POLYGON` (ray casting), `AREA_POLYGON` (Shoelace). Sayi ayrÄ±Å¸tÄ±rmada `VDbParseFloat` kullanÄ±r; ondalÄ±k ayÄ±rÄ±cÄ± **her zaman `.`** (sistem yerel ayarÄ±ndan bagÄ±msÄ±z). |
| `VDbErr.pas` | 133 / 5241 | BaÄŸÄ±msÄ±z hata kodlarÄ± (`TVDbErrorCode`: `ecNone..ecJsonError` ~30 deÄŸer) + `EVDbException(ErrorCode)` + `VDbErrorName`. |
| `VDbText.pas` | 237 / 5973 | TÃ¼rkÃ§e-duyarlÄ± UTF-8 metin (`VDbTrUpper/TrLower/Utf8Length/CompareTr`, `I/Ä±/i/Ä°` Ã§evrimi, TR alfabetik sÄ±ra). |
| `VDbPool.pas` | 251 / 6167 | `.odb` exclusive kilitli olduÄŸu iÃ§in tek motor Ã¼stÃ¼nde N `TVSql` havuzu (`Create(ATableDb,ASize,ATimeoutMs)`, `Acquire/Release/Close`, `Exec`). Paralellik Ã§arpmaz, kuyruk+zaman aÅŸÄ±mÄ± ile sÄ±nÄ±rlar. |
| `VDbDataSet.pas` | 1076 / 31823 | `TDataSet` kÃ¶prÃ¼sÃ¼ `TVDbQuery` (DBGrid/DataSource, tipli alanlar, tek-tablo `Insert/Edit/Post/Delete`) + `VDbDataSetReg.pas` (24 satÄ±r, kayÄ±t birimi). `vdbcomponents.lpk/.pas` runtime paketidir. |

## Guvenlik ve kisit katmani (2026-10-12)

Asagidaki ozellikler sema kaydinda saklanir (`#R`/`#G`/`#L`/`#P` onekli
satirlar), boylece veritabani dosyasi tasindiginda yetkiler de tasinir.

| Ozellik | Yer | Ozet |
|---|---|---|
| **R-18 RBAC** | `VDbTable` (katalog + `RoleCan/RequirePriv`), `VDbParser.ParseRole/ParseGrant`, `VDbExecutor.ExecRole/ExecGrant/ExecSetRole`, `VDbSql.ExecRaw` (`SET ROLE` dali) | `CREATE ROLE [SUPERUSER]`, `DROP ROLE`, `GRANT/REVOKE SELECT|INSERT|UPDATE|DELETE|ALL ON tablo\|* TO/FROM rol`, `SET ROLE rol\|NONE`. Rol belirtilmemisse motor kullanicisi modu (her sey serbest) — yetki sistemi **opt-in**. |
| **R-19 RLS** | `VDbTable` (`TPolicyDef`, `FRlsOn/FPolicies`, `RlsApplies/RlsUsing/RlsCheck`), `VDbParser.ParsePolicy`, `VDbExecutor.ExecPolicy/RlsExprNode/RlsRowVisible/RlsCheckRow/RlsRequireInsert`, `TSqlAlterTableStmt` (`ataEnableRls/ataDisableRls`) | `ALTER TABLE ... ENABLE/DISABLE ROW LEVEL SECURITY`, `CREATE/DROP POLICY ... FOR <cmd> [USING] [WITH CHECK]`. Politika yoksa deny-by-default. Politika ifadesi metin saklanir ve semada **hex**'lenir. |
| **R-11 DEFERRABLE** | `VDbTable` (`SetDeferred/CheckDeferredNow/DoCheckDeferred`, `FDeferredRows`), `VDbCore` (`TDbCommitHook`, `SetBeforeCommit`), `VDbSql.ExecRaw` | `SET CONSTRAINTS [ALL] DEFERRED/IMMEDIATE`. Yalniz **FK** ertelenir; PK/UNIQUE/NOT NULL indeks butunlugu icin aninda. Commit oncesi kanca hicbir kayit yazilmadan calisir. |
| **R-10 CYCLE** | `VDbParser` (`ParseSetOps`), `VDbExecutor` (`RunRecursiveCte/CteIsRecursive/MergeSetOpRows`), `TWithQuery.CycleCol/IsCycleCol/PathCol` | `WITH RECURSIVE ... CYCLE col SET is_cycle USING path`. Delta (semi-naive) degerlendirme; dongulu satir isaretlenir ve zincir kesilir. |

Ayirt edici ayrinti: R-18 ve R-19 **opt-in**'dir — `FCurrentRole = ''` veya
super rol hicbir kisitlama uygulamaz. Bu, mevcut kullanicilarin davranisini
degistirmeden yeni ozellik eklemenin anahtaridir.

## Notlar

- `VDbSql - Kopya (2).pas` diye bir dosya Ã¶nceki oturumlarda anÄ±lmÄ±ÅŸtÄ±; **ÅŸu an `D:\veritabani\` kÃ¶kÃ¼nde bÃ¶yle bir dosya YOK** (listelemede gÃ¶rÃ¼nmÃ¼yor). Envanterde yer almÄ±yor.
- `VDbWal.pas` + `VDbTest.pas` derlenebilir durumda ancak fiilÃ® dayanÄ±klÄ±lÄ±k `.odb`'nin kendi append-only + CRC + `BATCHEND` + aÃ§Ä±lÄ±ÅŸ recovery mekanizmasÄ±ndadÄ±r (ayrÄ±ntÄ± `02-DOSYA-FORMATI.md`).
- API katmanÄ± birimleri (`VDBClient.pas` 926/30326 â€” Delphi/DLL istemcisi, `vdbapi_core.pas` 1754/50074 â€” C ABI Ã§ekirdeÄŸi, `vdbapi.lpr` export listesi) bu belgede deÄŸil **`03-API-DLL.md`**'dedir; `guimain.pas` (533) ve `yonetim\*.pas` GUI katmanÄ±dÄ±r.
- Kripto kaynak kopyasÄ± `dcpcrypt\` altÄ±nda durur (`dcpcrypt2/dcprijndael/dcpsha256/...`); derleme yolu proje dosyalarÄ±nda `C:\lazarus\components\paketler\DCPcrypt` olarak ayarlÄ±dÄ±r.
- Ã–lÃ§Ã¼m notu: satÄ±r sayÄ±larÄ± **boÅŸ satÄ±rlar dahil** tam sayÄ±dÄ±r (PowerShell `Get-Content`). Ekipteki 04.10 tarihli ilk Ã§Ä±karÄ±mda aynÄ± yÃ¶ntem kullanÄ±lmÄ±ÅŸtÄ±r; deÄŸiÅŸmeyen dosyalarda byte deÄŸerleri birebir aynÄ±dÄ±r.

