# RC degerlendirmesi (Phase 8)

Bu belge, V3 sertlestirme programinin **son denetimidir**: ne yapildi, ne
kanitlandi, ne yapilmadi ve bu haliyle ne iddia edilebilir. Amac iyi haber
vermek degil, sinirlari yazmak.

> **Kritik cumle:** Bu bir **kendi kendini degerlendirme**dir. Skill
> §16/15 `RC_INDEPENDENT_REVIEW` **bagimsiz** bir insan incelemesi ister;
> o inceleme **yapilmadi**. Asagidaki her sayi depodaki bir kapiya veya
> bir CI kosusuna baglidir, ama hicbiri disaridan dogrulanmadi.
> README ve `SECURITY.md` bu nedenle "production-ready" demez.

## 1. Kapsam

| Denetlendi | Nasil |
|---|---|
| Kapi kumesi ve ciktisi | `tests/run_gates.sh` (19 kapi), iki platform |
| CI matrisi | `.github/workflows/ci.yml`, GitHub Actions kosulari |
| Kripto yolu | `docs/architecture/CRYPTO_ADR.md` + `crypto_*` kapilari |
| Depolama dayanikliligi | `WAL_RECOVERY_AUDIT.md`, `wal_crash`, `kv_wal` |
| Yedek/geri yukleme | `BACKUP_RESTORE.md`, `backup_restore` (B0-B24) |
| Sayfa/indeks butunlugu | `PAGE_INTEGRITY.md`, `page_integrity` (I0-I13) |
| B+Tree | `BTREE_INTEGRITY.md`, `btree_integrity` (152 kontrol) |
| SQL davranisi | `SQL_COVERAGE.md`, `SQL_DIFFERENTIAL.md`, `sql_matrix`, `sql_differential` |
| Performans | `PERF_BASELINE.md`, `perf_baseline` |
| Tek dosya sozlesmesi | `ON_DISK_LAYOUT.md`, `single_file` (SF1-SF20, 35 kontrol) |
| Sunucu/TLS/auth | `SERVER_HARDENING.md`, `server_harden`, `auth_throttle`, `tls_client` |
| Threat model / riskler | `docs/security/THREAT_MODEL.md` (R-01..R-12) |
| SBOM / lisans / ifsa | `docs/security/SBOM.md`, `vdb.cdx.json`, `NOTICE`, `SECURITY.md` |

Denetlenmeyenler: canli PostgreSQL diferansiyeli (psql yok), macOS/ARM64,
32-bit Linux, gercek disk dolması/guc kesintisi donanimi, bagimsiz sizma
testi, bagimsiz kripto incelemesi.

## 2. Kanit ozeti (bu RC'nin dayandigi gercek)

### 2.1 Kapilar

19 kapi, `tests/run_gates.sh`:

| Kapi | Linux (WSL x86_64) | Windows (Git Bash, i386) |
|---|---|---|
| `sql_stubs` | 25 / 0 | 25 / 0 |
| `sql_matrix` | 61 / 0 | 61 / 0 |
| `sql_fuzz` | 5 / 0 | 5 / 0 |
| `sql_differential` | 33 / 0 (`pg=not-run`) | 33 / 0 (`pg=not-run`) |
| `crypto_core`, `crypto_base64`, `crypto_kat`, `selftest_builtin`, `fixtures_builtin` | PASS | PASS |
| `wal_crash`, `kv_wal` | PASS | PASS |
| `backup_restore` | 25 / 0 | 25 / 0 |
| `page_integrity` | 14 / 0 | 14 / 0 |
| `btree_integrity` | 152 / 0 | 152 / 0 |
| `perf_baseline` | 16 / 0 | 16 / 0 |
| `single_file` | 22 / 0 | 22 / 0 |
| `server_harden` | 24 / 0 | 24 / 0 |
| `auth_throttle` | 16 / 0 | 16 / 0 |
| `tls_client` | 6 / 0 | **SKIP** (OpenSSL DLL yok) |

`fixtures_openssl` / `selftest_openssl` yalniz `VDB_CRYPTO_DLL` verilirse
kosar; bu makinede kosmadi.

### 2.2 CI kosulari (GitHub Actions, iki platform)

| # | Commit | Run | Sonuc |
|---|---|---|---|
| 7 | `929348c` | 43564347378 | success |
| 8 | `7569cc4` | 43567310636 | success |
| 9 | `2bcd8da` | 43568883549 | success |
| 10 | `7ee3cdc` | 43586157557 | success |
| 11 | `c9df6b8` | 43598523216 | success |

`fail-fast: false`; bir platformun kirmizisi digerini gizlemez.

## 3. Skill §16 maddelerinin durumu

| # | Kalem | Durum | Kanit |
|---|---|---|---|
| 1 | `V3_ONLY_POLICY` | tamam | `docs/engineering/BASELINE.md` |
| 2 | `V3_BASELINE_AUDIT` | tamam | `BASELINE.md`, `docs/architecture/MODULE_MAP.md` |
| 3 | `DCPCRYPT_USAGE_INVENTORY` | tamam | `DCPCRYPT_USAGE_INVENTORY.md` |
| 4 | `CRYPTO_ARCHITECTURE_ADR` | tamam | `docs/architecture/CRYPTO_ADR.md` |
| 5 | `CRYPTO_TEST_HARNESS` | tamam | `crypto_kat`, `crypto_fixtures`, `crypto_selftest` |
| 6 | `CRYPTO_PROVIDER_IMPLEMENTATION` | tamam | `VDbCryptoCore.pas` (builtin varsayilan) |
| 7 | `DCPCRYPT_CALLER_MIGRATION` | tamam | `dd4602d` |
| 8 | `DCPCRYPT_DEPENDENCY_REMOVAL` | tamam | kaynakta DCPcrypt yok; `NOTICE`ta yalniz atif |
| 9 | `WAL_RECOVERY_AUDIT` | tamam | `WAL_RECOVERY_AUDIT.md`, `wal_crash`, `kv_wal` |
| 10 | `BACKUP_RESTORE_HARDENING` | tamam | `BACKUP_RESTORE.md`, B0-B24 |
| 11 | `SQL_V3_DIFFERENTIAL` | **kismi** | `sql_matrix` 61 + `sql_differential` 33; canli PG kosusu yok (`pg=not-run`) |
| 12 | `BTREE_INTEGRITY` | tamam | `BTREE_INTEGRITY.md`, 152 kontrol |
| 13 | `SECURITY_HARDENING` | **kismi** | `THREAT_MODEL.md`, `server_harden`, `auth_throttle`, `tls_client`; VDBS tarafi acik (R-01..R-03) |
| 14 | `CI_RELEASE_GATES` | **kismi** | CI matrisi + SBOM var; **imzalama/provenance yok** (yayinlanan ikili yok) |
| 15 | `RC_INDEPENDENT_REVIEW` | **yapilmadi** | bu belge kendi kendini degerlendirmedir |

## 4. "Tek dosya" ile skill'in istedigi arasindaki fark

Skill'in "Single-File Storage Architecture" bolumu **Mode A** der: tum
kalici icerik tek `.odb` icinde, `.odb.log/` gibi disa gorunen yan dosya
yok, WAL **icerde** kalir.

**Durum iki asamali.** Once belgeler gercege gore duzeltildi (yan dosyalar
gizlenmedi); sonra **A** uygulandi: temiz kapanista yan dosyalar silinir ve
dizinde yalnizca `<db>.odb` kalir. Olculen davranis:

| | Skill Mode A | Bu depo (olculen) |
|---|---|---|
| Veri | tek dosya | tek dosya (`.odb`) |
| WAL | `.odb` icinde | `.odb.wal` **acikken**; temiz kapanista silinir |
| Acilis onbellegi | icerde | acikken olusmaz; `KeepIdxOnClose=True` ise `.odb.idx` |
| Degisim gunlugu | icerde | **opt-in**; kapaliyken `.gen`/`.log/` yok |
| Calisirken dosya sayisi | 1 | 3 (`.odb` + `.wal` + `.gen`) |
| Temiz kapanistan sonra | 1 | **1** |

Yani fark artik yalnizca **calisma aninda**: motor acikken WAL ve sayac
dosyasi yaninda durur, kapaninca silinir. Kalici durum tek dosyadir.

**Neden WAL calisirken ayri?** WAL'i veri dosyasinin icine almak yarim
kalan sayfa yazimi ile gunluk kaydini ayni dosyada yaristirir; crash
guvenligi geri gider (SQLite da WAL modunda ayri `-wal` tutar). Bu yuzden
"gercek tek dosya container" (v4 format: gomulu WAL bolgesi) **sahip
karariyla durduruldu** (2026-11-14): veri kaybi riski kabul edilmedi.
Tasarim `V4_CONTAINER_DESIGN.md`'de tarihce olarak duruyor; format
degismedi, `VDB_FILE_VER` hala **5**.

Dolayisiyla bu surum sunu soyleyebilir: *"veri tek `.odb` dosyasindadir;
motor acikken yaninda calisma dosyalari olusur ve temiz kapanista silinir;
tasinabilir tek dosya icin `BACKUP TO` kullanilir."* README'ler bu cumleyi
yazar. **"Calisirken de tek fiziksel dosya" iddiasi bu surumde YOKTUR.**

Mode A bir **RC engeli mi?** Urun davranisi acisindan degil (veri kaybi
yok, kapi var, belge dogru, kapanista tek dosya). Skill'in kabul kriteri
acisindan **kismen karsilanmistir**: kalici durum tek dosya, calisma durumu
degil. "Calisirken de tek dosya" isi sahip karariyla **kapatildi**
(kabul edilmis urun karari, eksik degil).

## 5. Risk register durumu (THREAT_MODEL.md)

Yayin karari icin her risk: **bloklar** (bu haliyle yayinlanmamali) /
**kabul** (bilincli, belgeli) / **acik** (yapilacak).

| Risk | Konu | Karar |
|---|---|---|
| R-01 | VDBS pre-auth mesajinda 1 GB'a kadar ayirma | **Bloklar** — VDBS yalniz guvenilir agda/loopback |
| R-02 | VDBS duz metin parola, TLS yok, sabit zamanli olmayan karsilastirma | **Bloklar** — ayni kosul |
| R-03 | VDBS'te giris denemesi sinirlamasi yok | **Bloklar** — ayni kosul |
| R-04 | idle/query timeout yok | Acik (orta) |
| R-05 | TLS alt surumu pinlenmemis | Acik (orta) |
| R-06 | IP/kullanici kotasi ve sorgu maliyet limiti yok | Acik (orta) |
| R-07 | builtin kripto yan kanal + bagimsiz inceleme yok + heap zeroization garantisi yok | **Kabul** (sahip karari R-5) |
| R-08 | imzalama/provenance yok | **Kabul** (yayinlanan ikili yok) |
| R-09 | denetim izinde kullanici kimligi yok | Acik (dusuk) |
| R-10 | sifreleme varsayilan kapali | **Kabul** |
| R-11 | RBAC/RLS kodu var, kapisi yok | Acik (orta) |
| R-12 | in-process kullanimda RBAC atlanabilir | **Kabul** (belgeli) |

**Sonuc:** R-01/R-02/R-03 **VDBS protokolu** icindir. PG wire tarafi
(SCRAM + throttle + opsiyonel TLS) bu riskleri tasimaz. Yani bu RC,
**gomulu kutuphane** ve **PG wire sunucusu** icin yayina uygundur;
**VDBS sunucusu** icin degildir ve `SECURITY.md` bunu acikca yazar.

## 6. "Unverified" listesi (R-3 kurali)

Asagidaki ozellikler **kodda var** ama mevcut kapilarda **denenmiyor**;
guvenmeden once kapi yazilmalidir. README'ler ayni listeyi yazar:

- `SAVEPOINT` / nested transaction
- `AS OF` / PITR (kod var; `wal_crash` yalniz kurtarma matrisini kosar)
- dosya modu replikasyon
- zone map / budama
- `ALTER DATABASE KEY`
- RBAC / RLS (R-11)
- macOS ve ARM64 derlemeleri
- canli PostgreSQL karsilastirmasi (`pg=not-run`)

Ek olarak **hicbir zaman kosulmadi**: 32-bit disindaki Linux mimarileri,
agir yuk/soak testi (gunler mertebesinde), disk dolmasinin gercek dosya
sistemiyle denenmesi.

## 7. Surum ve iddia

- `VDB_API_VERSION = $00010200` (1.2). Bu RC'de **API kirilmadi**; yeni
  davranis eklenmedi, sertlestirme ve belge yapildi.
- Bu surum icin **ikili yayinlanmadi** (release artifact yok): imzalama ve
  provenance maddeleri bu nedenle bos kaldi (`SBOM.md` §imzalama karari).
- Iddia cumlesi (README/SECURITY ile ayni): *"harici DLL gerektirmeyen,
  saf Free Pascal, verisi tek `.odb` dosyasinda duran bir motor; kapi
  kumesi iki platformda yesil; bagimsiz incelemeden gecmedi,
  production-ready degildir."*

## 8. Yayin oncesi kalan isler (oncelik sirasi)

1. **VDBS**: TLS + sabit zamanli parola karsilastirmasi + giris
   sinirlamasi + mesaj boyu tavani (R-01..R-03).
2. **RBAC/RLS kapisi** (R-11) — kod var, kanit yok.
3. **TLS alt surum pinleme** (R-05) ve idle/query timeout (R-04).
4. **Canli PostgreSQL diferansiyeli**: `psql` olan bir CI isi
   (`pg=not-run` yerine gercek kosum).
5. **Tek dosya Mode A (v4) — KAPATILDI**: sahip karari (2026-11-14) ile
   yapilmayacak. Kalici durum tek dosya (`A`, PHASE-9); calisma aninda yan
   dosya bulunmasi bilincli bir guvenlik tercihidir (bkz.
   `ON_DISK_LAYOUT.md` §3, `V4_CONTAINER_DESIGN.md`).
6. **Imzalama/provenance**: ilk ikili yayinlandiginda Sigstore + SLSA.
7. **Bagimsiz inceleme** (skill §16/15): kripto ve depolama icin.

## 9. Tekrar uretme

```sh
./tests/run_gates.sh                 # 19 kapi, cikti build/gates/
```

Windows (Git Bash) ayni betigi kosar; `tls_client` OpenSSL DLL'i yoksa
kendini atlar. CI'da ayni adim `.github/workflows/ci.yml` icindedir.
