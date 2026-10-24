# v3.0 Kapsam Raporu (Sprint 2.9 / 2.10)

Tarih: 2026-10-24 · Dal: `v3` · Motor: sayfa tabanlı v3 (4 KB sayfa, WAL + checkpoint)

Bu rapor `sqltest --backend=v3` koşusunun **ölçülmüş** sonucunu ve v3'te
koşmayan testlerin gerekçelerini kaydeder. Sessiz yeşil yoktur: koşmayan her
test `ATLA` olarak **sayılır ve raporlanır**.

## 1. Sonuç

| Koşu | Komut | Geçen | Kalan | Atlanan |
|---|---|---|---|---|
| v2 (taban çizgisi) | `sqltest <dir> --backend=v2` | **3116** | **0** | 0 |
| v3 (yeni motor) | `sqltest <dir> --backend=v3` | **2244** | **0** | **59** |

v3 koşusunda ayrıca 1 test içi bölüm atlanır: `T19_Olcek` içindeki `VACUUM`
(v3'te karşılığı Sprint 3.3'te gelecek sayfa birleştirme).

`--backend=v3` verilmediğinde program eskisi gibi v2 yolunu kullanır; v2
kapısı CI'da **3116/3116** ile aynen korunur.

Bilinmeyen backend adı reddedilir (`exit 2`).

### Koşucu değişikliği

Eski koşucu tüm testleri **tek bir `try`** içinde çağırıyordu: ilk istisna
kalan tüm testleri durduruyordu. Yeni koşucu her testi kendi `try/except`'inde
koşar (`TTestRec` dizisi + `BuildTests`), böylece tek hata diğerlerini
maskelemez; hata `!! KESILDI (<test>): <sınıf>: <mesaj>` olarak yazılır ve
sayaca eklenir.

## 2. v3'te neden koşmayan testler (59)

Üç grup vardır. Gruplama test gövdesinin gerçekten dokunduğu yüzeye göre
otomatik tarandı (`kv.`, `pkv.`, `myKv`, `TVDb.Create`), iki test ise elle
eklendi (yalnız v2 yönetim komutlarını sınar).

### (a) Gövdesi doğrudan v2 veri dosyası / WAL / arşiv API'sine dokunur — 33

Bunlar `TVDb`'nin `kv.` arayüzünü (WAL kuyruğu, `Verify`, arşiv, zone map,
`.idx` durumu, `DataFileSize` vb.) doğrudan çağırır. v3'te `Kv = nil` olduğu
için test gövdesi anlamsızdır; **arayüzle** koşan eşdeğerleri v3 kapılarında
(`backendchk`, `v3sqlchk`) vardır.

| Test | Dokunduğu yüzey |
|---|---|
| T21_KritikHataDogrulama | `kv.` (3) + VERIFY |
| T24_Dayaniklilik | `kv.` (8) |
| T42_F1_BatchInsertAtomik | `kv.` (1) |
| T46_F2_SemaBozukSatir | `kv.` (4), `myKv` |
| T53_F2_DDLAtomik | `kv.` (3) |
| T64_F2_PKsizTablo | `kv.` (3) |
| T65_F2_UniqueIndex | `kv.` (3) |
| T70_YonetimBakim | `myKv` + VACUUM/REINDEX/AUTOCOMPACT |
| T78_AsofGecmis | `kv.` (15) |
| T92_MVCC_Isoaltion | `kv.` (21) |
| T95_WALArsiv | `kv.` (15) + BACKUP/ARCHIVE/RECOVER/RESTORE |
| T95b_Replication | `kv.` (1) + START REPLICATION |
| T101_TcpReplication | `kv.`, `pkv.` (6) + BACKUP/ARCHIVE |
| T105_ShowStats | `kv.` (2) |
| T122_KvStore | `kv.` (1) |
| T125_KolonSifreleme | `kv.` (17) |
| T132_H12_StreamTopN | `kv.` (1) + VACUUM/BACKUP/VERIFY/SAVEPOINT |
| T36_F1_RecoverKirpma | `myKv` + RECOVER |
| T37_F1_CommitBatchAtomik | `myKv` |
| T43_F1_MigrateLegacy | `myKv` |
| T57_F2_BozukDosya | `myKv` |
| T58_F2_VerifyBATCHEND | `myKv` |
| T59_F2_DizinFlush | `myKv` |
| T60_F2_WALKilit | `myKv` |
| T61_F2_GetDogruluk | `myKv` |
| T63_F2_BozukKayitTespit | `myKv` + RECOVER |
| T69_YonetimAPI | `myKv` |
| T72_WALReplay | `myKv` + RECOVER |
| T73_OtomatikWAL | `myKv` |
| T74_KayitSifreleme | `myKv` (kayıt şifreleme; v3.0'da sayfa şifreleme Sprint 3.4) |
| T75_SifrelemeDayaniklilik | `myKv` |
| T76_ReplayWALSifreleme | `myKv` |
| T77_AlterDatabaseKey | `kv.` (7) |

### (b) Test kendi v2 veritabanını açar (`TVDb.Create`) — 24

Bunlar ayrı bir v2 dosyası açıp v2 motorunun davranışını sınar (H-serisi
hızlandırma testleri, RLS/RBAC kalıcılığı, GENERATED, izolasyon, CBO/MCV,
SQLancer stil diferansiyel). v3 eşdeğerleri `v3sqlchk` (47/47) ve bu koşudaki
SQL testleriyle kapsanır.

`T94_RBAC_Persist`, `T94c_RLS_Persist`, `T117_Generated`, `T126_F42_TxIsolation`,
`T127_H5_BlockCrc`, `T128_H11_Undo`, `T129_H11_InPlace`, `T130_PkRangeCtype`,
`T131_H12_TopN`, `T133_H13_StreamGroupBy`, `T134_H12c_MultiTopN`,
`T135_H14_FloatSort`, `T136_H13_GroupDiff`, `T137_H15_StreamHaving`,
`T138_H16_StreamDistinct`, `T139_H17_StreamFilteredCount`,
`T140_H18_RawExactCount`, `T141_H19_RawLikeCount`, `T142_H20_RawBoolTree`,
`T143_H21_RawTreeSelectPaths`, `T144_H22_DeepOffsetLive`, `T145_H8_MCV`,
`T147_M8_SqlancerStil`, `T148_H25_AutoCompact`

### (c) Yalnız v2 yönetim komutlarını sınar (elle eklendi) — 2

| Test | Komut | v3 karşılığı |
|---|---|---|
| T15_Bakim | VACUUM / REINDEX / VERIFY | Sprint 3.1 (Verify), 3.3 (Compact) |
| T79_Savepoint | SAVEPOINT / ROLLBACK TO | v3.1 (sayfa düzeyi undo) |

v3'te bu komutlar **sessiz geçmez**: `ecUnsupported` +
"v3 sayfa motorunda henüz desteklenmiyor (v3.1)" hatası verir (Sprint 2.7/2.9).

## 3. Bu adımda bulunan ve düzeltilen gerçek hatalar

v3 koşusu yalnız "kapsam" değil, **gerçek kusurlar** ortaya çıkardı:

1. **Zone map `Kv = nil` çökmesi (v3, AV).** `ExecSelect`'in zone-map yolu
   `FT.Kv.DataSeqValue`/`DataEpochValue`/`DataFileSize` alanlarını koşulsuz
   okuyordu. Sonuç: v3'te **sıradan** `WHERE tamsayi = 7` sorgusu erişim
   ihlali veriyordu (55+ doğrulama bu yüzden düşüyordu). Düzeltme: harita
   yalnız `Kv <> nil` iken kullanılır/inşa edilir; v3 tam tarama yapar.
   Kapsam: `T06_Where`, `T07_TipKarsilastirma`, `T08e_CTE`, `T08l_ViewDML`,
   `T09g_AnySomeAll`, `T09o_CoveringIndex`, `T20_CokluKayit`, `T31_F1_NotInNull`,
   `T44_F1_ParserDerinlik`, `T56_F2_AltSorgu`, `T68_F3_CokKolluOndek`,
   `T08k_MatView`, `T09p_SlowQuery`, `T17_Json`, `T23_Blob` hepsi yeşile döndü.

2. **`IMPORT JSON` v3'te AV.** `VDbJson.VDbImportJson` doğrudan
   `Tb.Kv.BeginBatch` çağırıyordu. Düzeltme: `Tb.BeginBatch` (backend-bağımsız).
   `T17_Json` ve `T23_Blob` artık v3'te tam koşar.

3. **Tablo düzeyi `UNIQUE(...)` sessizce yok sayılıyordu (v2'de de).**
   `CREATE TABLE t(a TEXT, b TEXT, UNIQUE(a))` cümlesinde parser `UNIQUE(...)`
   bloğunu **yutup atıyordu**: ne kolon bayrağı ne indeks oluşuyordu, yani
   kısıt hiç uygulanmıyor, tekrar eden değer kabul ediliyordu. Düzeltme:
   `TSqlCreateTableStmt.Uniques` + `CREATE TABLE` sonrası UNIQUE indeks kurulumu.
   Bu bir **veri bütünlüğü** hatasıydı ve her iki motoru da etkiliyordu.

4. **`ON CONFLICT(<unique hedef>)` hiç uygulanmamıştı.** `UpsertRowReturning`
   yalnız PK çakışmasını ele alıyordu; PK'sız tabloda `ON CONFLICT(a) DO UPDATE`
   yeni satır ekliyordu (3. maddedeki kısıt boşluğu bunu maskeliyordu).
   Düzeltme: `FindConflictPk` (indeks varsa aralık araması, yoksa tam tarama) +
   çakışma `CheckConstraints`'ten **önce** çözülür (`ExcludePk` ile satırın
   kendi değeri ihlal sayılmaz). Regresyon: `T10b_Upsert`'e tablo düzeyi
   UNIQUE + UNIQUE hedefli UPSERT kontrolleri eklendi (v2 ve v3'te koşar).

5. **Yönetim komutlarında çökme yerine açık hata.** `Kv = nil` iken
   `VERIFY`/`VACUUM`/`BACKUP`/arşiv/replication/`SHOW STATUS` gibi komutlar
   AV veriyordu. Düzeltme: `ExecAdmin` başında v3 için `ecUnsupported`.

6. **CI'da `crashtest` 42 dakika asıldı** (2.8 koşusu `cancelled`).
   Bir alt süreçte Windows çalışma-zamanı hata kutusu konsolsuz süreçte
   kapanmıyordu. Düzeltme: `crashtest` başında `SetErrorMode`
   (`SEM_NOGPFAULTERRORBOX` vb.) + CI adımında 300 sn sert süre sınırı.

## 4. v3.0 kapsamı dışı (bilinçli) ve planlanan sürüm

| Yetenek | Durum | Sürüm |
|---|---|---|
| `VERIFY` (sayfa CRC + heap) | yok | 3.1 |
| `BACKUP` / `RESTORE` / PITR | yok | 3.2 |
| `VACUUM` / `Compact` / AutoCompact | yok | 3.3 |
| Kayıt/kolon şifreleme (v3 sayfa düzeyi AES-GCM) | yok | 3.4 |
| `START REPLICATION` | yok | 3.5 (v3.1 mantıksal günlük) |
| Zone map | kapalı (tam tarama) | 3.7 |
| `SAVEPOINT` | `ecUnsupported` | v3.1 |
| B+tree / BETWEEN hızlandırma / `.idx` varint | yok | v3.1 |

## 5. Yeniden üretme

```
lazbuild -B sqltest.lpi
sqltest.exe <dir> --backend=v2   # SONUC: gecen=3116 kalan=0 atlanan=0
sqltest.exe <dir2> --backend=v3  # SONUC: gecen=2244 kalan=0 atlanan=59
```

Kapılar (yeniden koşuldu, hepsi yeşil):
`pagechk 21/21`, `storechk 15/15`, `heapchk 20/20`, `idxchk 17/17`,
`crashtest 11/11`, `backendchk 36/36`, `v3sqlchk 47/47`, `migchk 13/13`.
