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
| `crypto_core` | saf Pascal AES/GCM/SHA/HMAC cekirdegi |
| `crypto_base64` | base64 kodlayici/cozucu |
| `fixtures_builtin` | eski `.odb`/anahtar fixture'lari **builtin** provider ile acilir |
| `crypto_kat` | NIST KAT vektorleri (AES-GCM, SHA-256, HMAC, Argon2id, Blake2b) |
| `wal_crash` | WAL yirtik kuyruk/kurtarma matrisi |
| `kv_wal` | KV katmani WAL kurtarma matrisi |
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
2. `gcarreno/setup-lazarus` (Lazarus 4.4 / FPC 3.2.2, **commit SHA'sina
   pinli**; surum yukseltmesi bilincli bir PR'dir)
3. Surum dokumu (`fpc -iV`, `lazbuild --version`)
4. Windows: `lazbuild vdbapi|vdbcli|vdbmig|vdbserver.lpi`
   Unix: `./build_lib.sh` (paylasilan kutuphane)
5. `./tests/run_gates.sh`
6. Basarisizlikta `build/gates/*.log` artifact olarak yuklenir

`fail-fast: false`: bir platformun kirilmasi digerinin sonucunu gizlemez.

## 4. Kapsam disi (bilerek)

- **`sqltest` yok.** Depoda `sqltest.lpi`/`tests/sql` bulunmuyor
  (README'deki komut bu nedenle bayat). SQL davranis kapisi olarak bugun
  yalniz `sql_stubs` var; genis SQL regresyon seti ayri bir is kalemidir.
- Kapsam/olcum (coverage), fuzz, performans esikleri, SBOM, imzalama ve
  provenance **bu fazda yok** (skill §9.3 ileride).
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

## 6. Bilinen sinirlar

- Windows'ta TLS kapisi OpenSSL DLL'lerini `VDB_SSL_DLL`/`VDB_CRYPTO_DLL`
  ile bulur; CI'da bu degiskenler tanimli olmadigi icin kapi 77 ile atlar.
  Bu **TLS dogrulamasinin CI'da kosmadigi** anlamina gelir; yerelde
  kosulmustur (6/6).
- GitHub Actions'ta ilk kosu bu depo icin henuz yapilmadi; matris
  tanimi kanit degil, niyettir. Yerel kanit: Windows 11 kapi seti +
  WSL x86_64 Linux kapi seti (bkz. `docs/engineering/BASELINE.md`).
