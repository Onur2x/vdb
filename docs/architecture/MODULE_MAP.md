# VDB Modül Haritası (Phase 0 çıktısı)

> Kaynak: kök dizindeki 71 kod dosyasının `uses` grafiği + boyut + kamuya açık yüzey.
> Boyutlar kod incelemesinin ağırlık sırasını da verir: VDbExecutor (825KB) ve VDbTable (475KB) refactor öncelikleridir (skill §5.4 modüler bölme).

## Katmanlar ve sorumluluklar

### 1. SQL yüzeyi
| Modül | Sorumluluk | Boyut |
|---|---|---|
| `VDbParser.pas` | Lexer + parser → AST (`VDbAst.pas` tipleri) | 182KB |
| `VDbSql.pas` | SQL tip/degere dönüşüm yardımcıları | 157KB |
| `VDbExecutor.pas` | Çalıştırma planı, JOIN/agg/window/CTE, DDL yürütme | **825KB** |
| `VDbCost.pas` | CBO maliyet tahmini | 12KB |
| `VDbParallel.pas` | Paralel scan/agg | 17KB |

### 2. İlişkisel çekirdek
| Modül | Sorumluluk | Boyut |
|---|---|---|
| `VDbCore.pas` | TVeritabani sunucusu/schema, transaction/undo/redo koordinasyonu, ReplayWAL | 231KB |
| `VDbTable.pas` | Tablo: şema, heap, index yönetimi, constraint, VIEW/PROC/TRIGGER kaydı | **475KB** |
| `VDbUndo.pas` | Undo log (rollback) | 5KB |
| `VDbTypes.pas` | TVeriTipi, kayıt tipleri | 38KB |
| `VDbErr.pas` | hata kodları/sınıfları (TVeritabaniHatasi) | 50KB |

### 3. Storage (V3 = varsayılan)
| Modül | Sorumluluk |
|---|---|
| `VDbBackendV3.pas` | V3 orkestrasyon: motor seçimi, SQL'in page tarafına köprüsü |
| `VDbPageStore.pas` | Store生命周期: aç/kapat, snapshot/restore, backup, checkpoint, şifreleme bağları |
| `VDbPageEngine.pas` / `VDbPageHeap.pas` / `VDbPage.pas` | sayfa cache, slotted heap, 4KB sayfa formatı, WAL record yapıları |
| `VDbPageWal.pas` | WAL yaz/okut/replay; dirty-page-only commit |
| `VDbPageCrypto.pas` | AES-256-GCM sayfa zarı (nonce12\|ct\|tag16, AAD pageno+salt) |
| `VDbWal.pas` | **v2 legacy** WAL (donmuş) |
| `VDbBTree.pas` / `VDbIdxFile.pas` / `VDbSkipList.pas` / `VDbRange.pas` | index yapıları; `.odb.idx` türetilmiş cache |

### 4. Kripto & güvenlik
`VDbCrypt` (cephes: GCM/CBC/HMAC/SHA/CRC32/CSPRNG) · `VDbCryptoCore` (saf Pascal AES-256/CTR + SHA-256/HMAC çekirdeği) · `VDbKdf` (BLAKE2b+Argon2id) · `VDbCrc32` · `VDbTls` (OpenSSL dinamik wrapper) · `VDbPgWire` (PG sunucu protokolü + SCRAM-SHA-256) — ayrıntı: `docs/engineering/BASELINE.md` §5, kripto planı: `docs/engineering/DCPCRYPT_USAGE_INVENTORY.md`.

### 5. Dağıtık / değişiklik yakalama
`VDbReplication` (v2 snapshot-streaming) · `VDbReplV3` (v3, kısmi) · `VDbCdc` (değişim akışı) · `VDbSync.pas` (kendi cross-process senkron primitifleri — OS bağımlılığı burada) · `VDbChangeLog` (mantıksal log/audit).

### 6. Kullanıcı yüzeyleri
`vdbapi.lpr+vdbapi_core.pas+vdbapi.h` (57-export C ABI, handle tabanlı) · `vdbcli.lpr` · `vdbmig.lpr` (migrasyon aracı) · `vdbserver.lpr` (PG-wire sunucusu; `--user/--tls/--require-tls/--trust/--metrics`) · `VDbNet`+`VDbClient`+`VDbClientNet` (kendi TCP protokolü) · `VDbConsole` · `VDbMetricsHttp` (Prometheus/text) · `VDbMonitor` · `VDbDataSet` (FPC DataSet adaptörü) · `VDbFactory` (dbtype kaydı).

### 7. Tip/serde扩展 tipleri & I/O
`VDbJson` (JSONB) · `VDbXml` · `VDbSpatial` (+H3) · `VDbVector` · `VDbRange` · `VDbTimeTravel` · `VDbText` (full-text?) · `VDbParquet` (56KB, sıfır-bağımlılık Parquet okur/yazar) · `VDbExtension` (eklenti API'si?) · `VDbSqlServer`/`VDbMigrate` (SQL Server kaynağından göç).

### 8. Altyapı
`VDbPlatform` (OS soyutlama) · `VDbMM` (memory manager) · `VDbPool` (connection/page pool?) · `VDbTrace` (trace-id'li log) · `VDbXPrims` (ek primitifler) · `VDbSkipList`.

## Bağımlılık yönü (ihlal edilmemesi gereken kurallar)
- `VDbParser/VDbAst → VDbExecutor → VDbCore/VDbTable → storage` — ters ok yok.
- Kripto **yalnız** `VDbCrypt/VDbKdf/VDbPageCrypto/VDbTls` üzerinden; storage SQL tanımaz.
- Üçüncü-parti kripto bağımlılığı **yoktur**: AES-256/SHA-256/HMAC `VDbCryptoCore`'da, Argon2id/BLAKE2b `VDbKdf`'de saf Pascal'dır (DCPcrypt PHASE-1 adım 4'te kaldırıldı).
- `VDbSync/VDbPlatform` dışındaki unit'ler doğrudan WinAPI çağırmamalı (audit görevi: `Windows`/`Linux` uses taraması — henüz yapılmadı, backlog'da).

## Bilinen teknik borç odakları
1. `VDbExecutor.pas` 825KB tek dosya — skill §5.4 bölme planı behavior-lock ile.
2. `VDbTable.pas` 475KB — şema+depolama+DDL aynı sınıf.
3. Stub yüzeyler (RETURNING/PROC/TRIGGER) — `BASELINE.md` §4.
4. `.s`, `.o`, `.ppu` artifact kirliliği ve karışık depo içeriği (`mtakip/`) — `.gitignore` git kurulunca netleşir.
