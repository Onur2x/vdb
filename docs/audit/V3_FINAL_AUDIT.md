# VDB V3 - Derin Denetim ve Sertlestirme Raporu

SKILL3 (VDB V3 Deep Repository Audit, Bug Fixing & Production Hardening)
§18 formatina gore. Tarih: 2026-11-15.

## Summary

- **Depo durumu**: `D:\veritabani`, dal `main`, dosya bicimi **v5**
  (`VDB_FILE_VER = 5`). v4 konteyner calismasi sahibi tarafindan
  DURDURULDU (veri kaybi riski); bicim degismedi.
- **Derleyici**: Free Pascal 3.2.4.
- **Platformlar**: Windows i386 (`C:\lazarus\fpc\3.2.4\bin\i386-win32`) ve
  WSL x86_64 Linux, ayni kaynak, ayni `tests/run_gates.sh`.
- **Denetim kapsami**: SKILL2 §18-28 ve SKILL3 §5-§15, §19. Depolama
  motoru, WAL/kurtarma, islem izolasyonu, B+Tree, SQL yurutucu, guvenlik,
  kaynak sinirlari, performans, tasinabilirlik, belge.
- **Kosulan testler**: `tests/run_gates.sh` - Linux **31 kapi**, Windows
  **30 kapi** (`tls_client` atlanir), tamami PASS.

## Findings

| # | Siddet | Dosya / islev | Kok neden | Duzeltme | Test | Durum |
|---|---|---|---|---|---|---|
| F1 | **KRITIK** | `VDbPageStore.InstallPage` | Tazeleme sirasinda sayfa, `TxnMark` bu isleme ait olmasa da siliniyordu; baska oturumun **onayli** sayfalari kayboluyordu | `TxnMark = FTxnId` kosulu (v3.32) | `multi_writer` MW3/MW4 | KAPALI |
| F2 | **KRITIK** | `VDbPageStore.Close`, `.gen` | Ikinci oturumun kapanisi `.gen` dosyasini siliyordu; iki oturum farkli nesil kimligi tasiyip birbirinin sayfalarini eziyordu | Surec ici referans sayaci `GGenRefCs`/`GenRefAdd`/`GenRefDrop`/`GenRefOthers` (v3.33) | `multi_writer` MW2 | KAPALI |
| F3 | **KRITIK** | `VDbPageEngine.DoCommit` | LSN yalnizca oturum onbelleginden aliniyordu; checkpoint WAL'i kirptiktan sonra iki oturum **ayni LSN**'i uretiyor, kurtarma `lsn <= MinLSN` kayitlarini atlayarak onayli commit'i siliyordu | WAL kuyruk LSN'i (`FTailPos`/`FTailLsn`, `SyncTail`, `TailLsn`) ile tohumlama, sonra `FStore.SetLSN` (v3.34/v3.35) | `multi_writer` MW1 (LSN kesin artan) | KAPALI |
| F4 | **KRITIK** | `VDbPageEngine.DropSideFiles` | Kapanan ikinci oturum, BOS `.wal`'i siliyordu; birinci oturumun acik tutamagi yetim kaliyor, sonraki commit'ler gorunmez oluyordu | `FStore.OtherOpenSessions > 0` iken yan dosyalara dokunma (v3.36) | `multi_writer` MW2/MW4 | KAPALI |
| F5 | **KRITIK** | `VDbPageWal.Commit` | `FAtEnd` bayat konumu guveniyordu; baska oturum araya kayit eklediyse yeni commit eski kaydin **uzerine** yaziyordu (WAL'de sessiz delik) | Her commit `FStream.Seek(0, soEnd)` (v3.36) | `multi_writer` MW1/MW4 | KAPALI |
| F6 | ORTA | `VDbPageStore.ExtendFile` | Sayfa sayaci sinirsizdi; LongWord tasmasi iki farkli sayfaya ayni numarayi verebilirdi (sessiz bozulma) | `VDB_MAX_PAGES` + `VDB_MAX_DB_BYTES` ile kontrollu `ecLimit` (v3.37) | `limits` L5/L6 | KAPALI |
| F7 | ORTA | `VDbPageStore.MarkPageDirty` | Tek islem sinirsiz sayfa kirletebiliyordu (bellek/WAL sisirme) | `VDB_MAX_TXN_PAGES` (1M) `ecLimit` (v3.37) | `limits` L5 | KAPALI |
| F8 | ORTA | `VDbSql.Exec`/`ExecRaw` | Tek SQL cumlesi boyu sinirsizdi; dev bir metin motoru bellek tuketerek cokertiyordu | `VDB_MAX_SQL_STMT` (4 MiB) + `CheckStmtSize` (v3.37) | `limits` L1/L3 | KAPALI |
| F9 | ORTA | `VDbExecutor` cikti buyumesi | LIMIT'siz tam tarama bellek dolana kadar buyuyordu (kontrolsuz OOM) | 2M satirda kontrollu `ecLimit` (v3.37) | `limits` L4 (parser yolu); tam tarama yolu **testsiz** | KISMI |
| F10 | DUSUK | `tests/bench_report` BR11 | Indeks testi id tabani `300000`, BR5 rastgele araligiyla cakisiyordu; sahte "duplicate PK" | Taban `2000000` | `bench_report` 35/0 | KAPALI |

### Kapatilan test bosluklari (SKILL2 §22, SKILL3 §10.1)

- `bench_report` (35 kontrol, 18 kategori, P50/P95/P99, CSV+meta) - yeni.
- `multi_writer` (12 kontrol) - yeni.
- `sql_features` (32 kontrol) - yeni: `SAVEPOINT` / `ROLLBACK TO` /
  `RELEASE SAVEPOINT`, `ON CONFLICT DO NOTHING|DO UPDATE`, `VACUUM`,
  `REINDEX`, `ANALYZE <tablo>`, `WITH` (CTE), `ROW_NUMBER() OVER`,
  `ALTER TABLE ... RENAME TO`.
- `limits` (18 kontrol) - yeni: asiri SQL / asiri INSERT / asiri LIMIT
  kontrollu `ecLimit`, sinir sonrasi veri butunlugu, belgelenen tavanlar.
- `cache_pressure` (8 kontrol) - yeni: 8 sayfalik havuzla ~100 sayfalik
  tablo; tahliye + yeniden yukleme veri kaybetmez, `PoolUsed` havuz boyunu
  asmaz, kirli sayfa tahliyesi commit sonrasi kalicidir (SKILL3 §12.1
  "cache exhaustion").

## Test Results

| Sonuc | Linux | Windows |
|---|---|---|
| PASS (kapi) | **31** | **30** |
| FAIL | 0 | 0 |
| SKIP (`VDB_CRYPTO_DLL` yok) | 2 (`fixtures_openssl`, `selftest_openssl`) | 3 (+`tls_client`) |
| Calistirilmayan | canli PostgreSQL karsilastirmasi (`sql_differential` `pg=not-run`) | ayni |

Kapi toplamlari (ikisi de ayni): sql_stubs 25/0, sql_matrix 61/0,
sql_fuzz 5/0, sql_differential 33/0, crypto_* PASS, wal_crash, kv_wal,
backup_restore 25/0, page_integrity 14/0, btree_integrity 152/0,
perf_baseline 16/0, single_file 35/0, region_stream 13/0, multiproc 17/0,
crash_points 24/0, integrity_check 32/0, cache_metrics 21/0,
format_compat 28/0, portability 29/0, multi_writer 12/0, bench_report 35/0,
sql_features 32/0, limits 18/0, cache_pressure 8/0, server_harden 24/0,
auth_throttle 16/0,
selftest_builtin PASS, tls_client 6/0 (yalniz Linux).

## Remaining Risks

**Bilinen hatalar**: acik kritik hata yok. F9 kismi: LIMIT'siz dev tarama
icin tavan kodda var ama 2M satir ureten bir kapi yok (kapi suresi icin
bilincli olarak disarida).

**Eksik testler** (SKILL3 §12.1'den kalanlar):

| Test | Durum |
|---|---|
| Disk dolu (ENOSPC) | YOK - `wal_crash` T9 yalniz fsync hatasini enjekte eder |
| Bellek tahsis hatasi | YOK |
| WAL tukenmesi | YOK |
| Onbellek tukenmesi / tahliye | VAR (`cache_pressure`: 8 sayfalik havuz, kirli tahliye, yeniden acilis) |
| Asiri baglanti | YOK (`server_harden` yalniz baglama/adres) |
| Asiri islem | YOK |
| Bozuk ag girdisi | YOK |
| Bozuk veritabani / WAL | VAR (`page_integrity`, `integrity_check`, `wal_crash`, `format_compat`) |
| Gecersiz sifreleme anahtari | VAR (`crypto_fixtures`) |
| Sayfa numarasi / yirtik yazma bozulmasi | KISMI (yalniz `Verify`, normal okuma yolunda degil) |
| Sunucu kapanisi | YOK |
| B+Tree disk sayfa bicimi / 1M satir olcek / VACUUM sonrasi parcalanma | YOK |

**Desteklenmeyen ozellikler**: v4 konteyner bicimi (durduruldu), dis
bagimlilik yok (saf native, harici DLL yok - OpenSSL istege bagli).

**Dogrulanmamis platformlar**: yalniz Windows i386 ve Linux x86_64
olculdu; macOS/ARM derlemesi denenmedi.

**Guvenlik sinirlari**: sifreleme (AES-256-GCM, PBKDF2) `crypto_*` ve
`server_harden`/`auth_throttle` ile olculuyor; resmi FIPS/SIL iddiasi
YOKTUR ve bu rapor boyle bir iddia kurmaz. TLS yalniz istege bagli harici
OpenSSL ile, yani varsayilan yapida ag sifrelemesi yok.

**Performans sinirlari**: olcumler tek makine, tek derleyici, `-O1`
kosullarinda; `bench_report` tekrarlanabilir (sabit tohum 20251115) ama
donanimlar arasi karsilastirma icin normallestirilmedi. Canli PostgreSQL
karsilastirmasi kosmadi.

## Production Readiness

**BETA CANDIDATE**

Gerekce: kritik depolama/WAL/islem hatalari kapatildi ve her biri kalici
bir regresyon kapisiyla kilitlendi; iki platformda 30/29 kapi yesil; tek
dosya sozlesmesi, kurtarma ve tasinabilirlik olculdu. Buna karsin disk
dolu, bellek tukenmesi, ag girdisi fuzz'u ve sunucu kapanisi gibi uretim
hatasi yollari test edilmedi; canli PostgreSQL diferansiyeli kosmadi; TLS
varsayilan olarak kapali. Bu nedenle "PRODUCTION CANDIDATE" degil.

Bu siniflandirma bagimsiz dogrulama (harici denetim, resmi sertifika)
olmadigi icin "certified"/"SIL"/"formal compliance" iddiasi icermez.
