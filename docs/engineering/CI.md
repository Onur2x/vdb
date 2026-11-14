# CI ve kalici kapi kosucusu

Bu belge, V3 sertlestirmesinin **gercekten kosan** kapi kumesini ve CI
matrisini kaydeder. Amac, "geciyor" iddialarini tek bir komuta ve tek bir
CI isine baglamak.

## 1. Tek komut

```sh
./tests/run_gates.sh            # cikti: build/gates/ (yok sayilir)
./tests/run_gates.sh /tmp/vdbk # istege bagli calisma dizini
```

Betik saf `fpc` kullanir (Lazarus IDE/`.lpi` gerekmez), Linux/macOS ile
Windows Git Bash'te ayni sekilde calisir. Tum kapilari **kendisi derler**;
onceden derlenmis ikiliye guvenmez.

Cikis kodu 0 = kosan tum kapilar gecti, 1 = en az biri basarisiz.

## 2. Kosan kapilar

| Kapi | Ne dogrular |
|---|---|
| `sql_stubs` | RETURNING/TRIGGER/FUNCTION/PROCEDURE yuzeyi; sessiz yanlis sonuc yok |
| `sql_matrix` | SQL davranis matrisi: DDL/DML/SELECT/JOIN/agregat/transaction/hata yollari + bos tabloda referans dogrulamasi (bkz. `SQL_COVERAGE.md`) |
| `sql_fuzz` | ayristirici dayaniklilik: 3000 deterministik bozuk girdi, istisna sizintisi/heap buyumesi/sure siniri |
| `sql_differential` | PostgreSQL diferansiyel korpusu + sapma yonetisimi (bkz. `SQL_DIFFERENTIAL.md`) |
| `btree_integrity` | B+Tree silme/denge/doluluk + yaprak zinciri Next/Prev (bkz. `BTREE_INTEGRITY.md`) |
| `crypto_core` | saf Pascal AES/GCM/SHA/HMAC cekirdegi |
| `crypto_base64` | base64 kodlayici/cozucu |
| `fixtures_builtin` | eski `.odb`/anahtar fixture'lari **builtin** provider ile acilir |
| `crypto_kat` | NIST KAT vektorleri (AES-GCM, SHA-256, HMAC, Argon2id, Blake2b) |
| `wal_crash` | WAL yirtik kuyruk/kurtarma matrisi |
| `kv_wal` | KV katmani WAL kurtarma matrisi |
| `backup_restore` | yedek/geri yukleme butunlugu + tatbikat (B0-B24) |
| `page_integrity` | sayfa/heap/freelist bozulma matrisi (I0-I13) |
| `server_harden` | dinleme adresi, `--trust` sinirlari, TLS zorunlulugu |
| `auth_throttle` | SCRAM deneme sinirlama/kilit |
| `selftest_builtin` | provider SelfTest (builtin) |
| `tls_client` | istemci CA + sunucu adi dogrulamasi (OpenSSL varsa) |

Kosullu kapilar:

- `fixtures_openssl`, `selftest_openssl`: yalniz `VDB_CRYPTO_DLL` verilmisse.
- `tls_client`: OpenSSL yuklenemezse kapi **77** ile kendini atlar
  (`SKIP`); bu "gecti" sayilmaz, kosan kapi sayisina da eklenmez.

## 3. CI matrisi

`.github/workflows/ci.yml` — `ubuntu-latest` + `windows-latest`:

1. `actions/checkout`
2. Windows: `gcarreno/setup-lazarus` (Lazarus 4.4 / FPC 3.2.2,
   **commit SHA'sina pinli**; surum yukseltmesi bilincli bir PR'dir).
   Unix: `apt-get install fpc` (Ubuntu deposu, FPC 3.2.2). Linux'ta
   `lazbuild` gerekmez, bu yuzden ucuncu-taraf kurulum action'i yerine
   depo paketi kullanilir; ariza nedeni dogrudan logda gorunur.
3. Surum dokumu (`fpc -iV`, varsa `lazbuild --version`)
4. Windows: `lazbuild vdbapi|vdbcli|vdbmig|vdbserver.lpi`
   Unix: `bash build_lib.sh` (paylasilan kutuphane)
5. `bash tests/run_gates.sh`
6. Basarisizlikta `build/gates/*.log`, `gates.out` ve apt loglari artifact
   olarak yuklenir. Ayrica ilk 10 hata satiri ve kuyruk **check-run
   anotasyonu** olarak yazilir; log indirme yetkisi olmayan bir okuyucu da
   ariza nedenini gorebilir.

`fail-fast: false`: bir platformun kirilmasi digerinin sonucunu gizlemez.

## 4. Kapsam disi (bilerek)

- **`sqltest` (`tests/sql`) yok.** Eski agacla birlikte kaldirildi
  (README'deki komut bu nedenle bayat). SQL davranis kapisi artik
  `sql_stubs` + `sql_matrix`'dir; matrisin kapsami ve bilinen farklari
  `docs/engineering/SQL_COVERAGE.md`'de yazilidir.
- Kapsam/olcum (coverage), SBOM, imzalama ve provenance **bu fazda yok**
  (skill §9.3 ileride). SQL ayristirici fuzz'i (`sql_fuzz`) vardir; diger
  protokol/kapilar icin fuzz yoktur.
- macOS/ARM64 matrisi yok; kod Unix dallari uzerinden tasinabilir
  tutulmustur ama macOS'ta kosulmadi.
- TLS kapisi sertifika uretimi icin `tests/tls_fixtures` (Python
  `gen_certs.py` ile uretilmis, depoya islenmis) kullanir.

## 5. Tasinabilirlik notlari (bu fazda duzeltildi)

Unix derlemesi daha once hic denenmemisti; asagidaki gercek engeller
kaldirildi:

- `VDbMM`: `uses Windows` kosullu; slab ayirma Windows'ta `VirtualAlloc`,
  Unix'te `fpmmap` (64 KB hizalama onek/sonek `fpMunmap` ile iade).
  Eski 32-bit adres varsayimli slab bitmap'i yerine platformdan bagimsiz
  **slab kayit defteri** (acik adresleme hash) kullanilir.
- `VDbSync.VDbEventName`: Unix'te `TEvent` bos adla olusturulamaz
  (`ESyncObjectException`); olay adlari surec-ici benzersiz uretilir.
- `VDbXPrims`: `fcntl` birimi FPC'de yok → `BaseUnix.FpFcntl` + `FLock`;
  POSIX kilit sabitleri platforma gore (`VDB_F_*`) tanimlandi. `shm_open`
  sarmalayicisi FPC 3.2.2'de bulunmadigi icin Linux'ta `/dev/shm`, diger
  Unix'lerde gecici dizin uzerinden `fpOpen`/`fpUnlink` kullanilir.
- `VDbTls`: Unix kutuphane adlari (`libssl.so.3`, `.so.1.1`, `.so`,
  macOS `.dylib`) eklendi; `SIGPIPE` surec duzeyinde yok sayilir (karsi
  taraf el sikismasini kesince OpenSSL yazma yolu sureci oldurmesin).
- Test programlari Unix'te `cthreads` thread driver'ini `uses` eder.
- `tests/run_gates.sh` Git Bash/MSYS altinda `fpc`'ye **native Windows
  yolu** verir (`cygpath -w`). Aksi halde native `fpc.exe` POSIX yolunu
  (`/d/repo`) surucu-goreli (`\d\repo`) sanip `Path does not exist` ile
  duser. Bu, ilk CI kosusunda Windows isini kirian gercek nedendi.
- Betik, kaynak dizindeki eski `gen_fixtures` ikilisini derlemeden once
  siler: bayat ikili `fixtures_builtin` kapisini yanlislikla PASS
  gosterebiliyordu.

## 6. Bilinen sinirlar

- Windows'ta TLS kapisi OpenSSL DLL'lerini `VDB_SSL_DLL`/`VDB_CRYPTO_DLL`
  ile bulur; CI'da bu degiskenler tanimli olmadigi icin kapi 77 ile atlar.
  Bu **TLS dogrulamasinin CI'da kosmadigi** anlamina gelir; yerelde
  kosulmustur (6/6).
- Ilk GitHub Actions kosusu (`a8526b2`, run 433) **basarisiz** oldu:
  `gates (ubuntu-latest)` "Setup FPC / Lazarus" adiminda, `gates
  (windows-latest)` "Build and run gates" adiminda dustu. Windows nedeni
  yerelde birebir yeniden uretildi ve duzeltildi (yukaridaki `cygpath`
  maddesi). Ubuntu nedeninin adim logu anonim erisimle okunamadi
  (GitHub log indirme kimlik dogrulamasi istiyor); bu yuzden o adim
  ucuncu-taraf action'dan bagimsiz, ciktisini acikca loglayan `apt-get`
  kurulumuna cevrildi.
- Ikinci GitHub Actions kosusu (`e1c4654`, run "CI" #43551308899):
  `gates (ubuntu-latest)` **basarisiz**, `gates (windows-latest)` hala
  kosuyordu. Ubuntu'nun dustugu adim artik okunabildi (check-run
  anotasyonu): `BUILD FAIL crypto_fixtures` / `MISSING fixtures_builtin`.
  Kok neden yerelde birebir uretildi: **temiz checkout'ta
  `tests/crypto_fixtures/lib` dizini yoktur ve `fpc -FU` hedef dizini
  kendisi yaratmaz** (`Can't create object file .../lib/VDbCryptoCore.o`).
  WSL'de dizin eski kosulardan kalmis oldugu icin sorun gorunmuyordu.
  Betik artik derlemeden once `mkdir -p "$FI/lib"` yapar. Ayrica
  basarisizlik anotasyonu artik `Error:`/`Fatal:` satirlarini da tasir;
  onceki surum yalniz "BUILD FAIL <ad>" yazdigi icin kok neden gizlenmisti.
- Ucuncu kosu (`7ae62c2`, run 43552816622): `gates (ubuntu-latest)`
  **basarili** (Linux ilk kez yesil); `gates (windows-latest)`
  **basarisiz** — adim 8 "Build and run gates". Anotasyon kok nedeni
  gosterdi: `FAIL scram_verifier.txt: sha256 pini` +
  `AddUser formulu yeniden-turetimi` → `fixtures_builtin (exit 2)`.
  Kok neden yerelde birebir uretildi: Windows runner'da
  `core.autocrlf=true` temiz checkout'ta fixture metnini CRLF'e cevirir
  (666 → 678 bayt); kapi `gen_fixtures verify` kosar (yeniden uretmez) ve
  pin bayt duzeyindedir. Yerelde gorulmemesinin nedeni, dosyanin
  generator tarafindan LF ile yeniden yazilmis olmasiydi. Duzeltme:
  `.gitattributes` icinde `tests/crypto_fixtures/fixtures/** -text`.
  Temiz klonda dogrulandi: duzeltme oncesi 20/2 FAIL (CI ile ayni),
  sonrasi 22/0 PASS.
- Dorduncu kosu (`3997bbe`, run 43555965650): **iki platform da YESIL**
  (Ubuntu + Windows `success`). CRLF duzeltmesi ve `cygpath`
  duzeltmesi boylece CI'da dogrulandi.
- Besinci kosu (`0381d53`, run 43558258898): **iki platform da YESIL**
  (`success`). Bu kosu Phase 4 `backup_restore` kapisini (B0-B24) ilk kez
  CI'da kosturdu.
- Altinci kosu (`a1048e9`, run 43562165305): **iki platform da YESIL**
  (`success`). Bu kosu Phase 4 `page_integrity` kapisini (I0-I13) ilk kez
  CI'da kosturdu; trunk sayfasi yanlis-pozitif duzeltmesi ve `cur`
  Release duzeltmesi CI'da dogrulandi.
- Yedinci kosu (`929348c`, run 43564347378): **iki platform da YESIL**
  (`success`). `sql_differential` kapisi (PostgreSQL korpusu + sapma
  yonetisimi) ilk kez CI'da kosturuldu; yerel kanit Git Bash/Windows
  **15 kapi** PASS (tls_client SKIP), WSL x86_64 Linux **16 kapi** PASS.
  `sql_matrix`: 61 PASS, 0 FAIL (iki platformda).
  `backup_restore`: 25 PASS, 0 FAIL (iki platformda).
  `page_integrity`: 14 PASS, 0 FAIL (iki platformda).
  `sql_differential`: 33 PASS, 0 FAIL, `pg=not-run` (psql yok).
- Sekizinci kosu (bu commit): `btree_integrity` kapisi eklendi; yerel kanit
  Git Bash/Windows **16 kapi** PASS (tls_client SKIP), WSL x86_64 Linux
  **17 kapi** PASS (tls_client 6/0 dahil).
  `btree_integrity`: 152 PASS, 0 FAIL (iki platformda).
