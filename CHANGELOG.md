# Degisim gunlugu

Surum numarasi `vdbapi.lpr`/`vdbapi.h` icindeki `VdbApiVersion` ile
birlikte ilerler. Bu dosya yalnizca **kayda deger** degisiklikleri tutar;
commit gecmisi ayrintili kayittir.

## Yayinlanmamis (v3 sertlestirme, 2026-11)

Hedef: harici DLL'siz, saf Pascal bir veritabani oldugu sozlesmesini
korumak; iddialari **kanitlanabilir** hale getirmek. Bu seri "production
ready" iddiasi tasimaz (bkz. `SECURITY.md`, `docs/security/THREAT_MODEL.md`).

### Guvenlik

- **Kripto provider sozlesmesi** (ADR K1): varsayilan `builtin` (saf
  Pascal) provider. OpenSSL yalnizca acikca secilirse kullanilir; sessiz
  fallback yok. DCPcrypt tamamen kaldirildi; yerine `VDbCryptoCore.pas`
  (AES-256-CTR/GCM cekirdegi, SHA-256, HMAC) geldi. AES/SHA cekirdeginin
  kokeni MIT lisansli referans uygulamadir (bkz. `NOTICE`, `p7-sbom`).
- **Sunucu sertlestirme**: dinleme adresi cozumleme fail-closed
  (`VdbResolveListenHost`); `--trust` modunda loopback disi adres
  **reddedilir**; PG wire'da SCRAM-SHA-256, `RequireTls`, giris hiz siniri
  ve kilit (`AuthMaxFailures=5`, `AuthFailureWindowSeconds=60`,
  `AuthLockoutSeconds=30`, `AuthGlobalMaxFailures=200`); bilinmeyen
  kullanici ile yanlis parola ayni hatayi verir.
- **Desteklenmeyen yollar sessiz yanlis sonuc uretmez**: uygulanmamis SQL
  yuzeyi `ecUnsupported` ile reddedilir (`docs/engineering/SQL_STUB_SURFACE.md`).

### Dayaniklilik

- **WAL kurtarma denetimi** ve `wal_crash` matrisi; WAL dosyasi hicbir
  yerde silinmez, checkpoint basligi yeniden yazar.
- **Yedek/geri yukleme**: `RestoreFrom` yazmadan once tam sayfa dogrulamasi
  yapar; `Verify`/`VerifyBackup` yalnizca reddeder, onarmaz. Iki gercek hata
  kapatildi (freelist trunk yanlis pozitifi; bozuk yedek uzerine sessiz
  yazma) — `docs/engineering/BACKUP_RESTORE.md`.
- **Sayfa/indeks butunlugu** kapisi `page_integrity` (I0-I13).

### SQL

- **Davranis matrisi** `sql_matrix` (61 durum) + `ValidateExprCols`
  (bos tabloda sessiz referans hatasi kapatildi) — `SQL_COVERAGE.md`.
- **PostgreSQL diferansiyel korpusu** `sql_differential` + skip governance
  (10 ayni / 4 bildirilmis fark) — `SQL_DIFFERENTIAL.md`. Canli `psql`
  olmadigi icin `pg=not-run`.

### Performans

- **B+Tree silme yeniden dengelenir**: borrow -> merge -> kok cokertme;
  min doluluk yaprak `K div 2`, ic dugum `(K-1) div 2`;
  `CheckInvariants` sikilastirildi (`tests/btree_integrity`, 152 kontrol).
- **`perf_baseline` kapisi**: mutlak sure yerine genis tavan + olceklenme
  orani (karesel bozunma tespiti) — `PERF_BASELINE.md`.

### Belgeler

- **"Tek dosya" ifadesi gercege gore duzeltildi**: veri `<db>.odb` icinde,
  ama calisan bir veritabani `.wal`, `.idx`, `.gen`, `.log/` ile birlikte
  **bes girdidir**. Yalniz `.odb` kopyasi acilir ve yazilabilir (motor eksik
  yan dosyalari yeniden uretir); tasinabilir tek dosya icin `BACKUP TO`.
  `tests/single_file` (22 kontrol) ve `docs/engineering/ON_DISK_LAYOUT.md`.
- README'lerdeki eski/yanlis bilgiler duzeltildi: mimari zincir (v2-only
  anlatimi), derleme komutlari (`sqltest.lpi` yok), ilk sorgu ornegi
  (`TVSql.Create` bir `TVTableDb` alir), export sayisi (57), test tablosu
  (19 kapi Linux / 18 Windows).
- Ozellik listesindeki "kapi testleriyle dogrulanmistir" iddialari
  duzeltildi: `SAVEPOINT`, `AS OF`/PITR, dosya modu replikasyon, zone map
  ve `ALTER DATABASE KEY` **uygulanmistir ama mevcut kapilarca test
  edilmemektedir**.
- Guvenlik belgeleri: `docs/security/THREAT_MODEL.md` (STRIDE + R-01..R-12
  risk kaydi), `SECURITY.md` (GitHub Security Advisories uzerinden ifsa),
  `docs/security/SBOM.md` + CycloneDX 1.5 `vdb.cdx.json`, kok `NOTICE`.
- `docs/engineering/RC_REVIEW.md`: surum adayi degerlendirmesi — kapilarin
  kanitladigi sey, skill §16 kalemlerinin durumu, VDBS risklerinin yayini
  engelledigi nokta ve yayin oncesi kalan isler.

### Altyapi

- CI matrisi Ubuntu + Windows; kapilar `tests/run_gates.sh` uzerinden
  (Unix) ve Git Bash uzerinden kosar. Kapilar `tests/gates`/`tests/sql`
  eski agacindan bagimsizdir.
