# Phase 4 - Depolama butunlugu: yedek, geri yukleme, WAL invariantlari

Bu belge, V3 sertlestirmesinin Phase 4 kalemlerinin **hangi kodla** ve
**hangi kapıyla** kanitlandigini kaydeder. Amac iddia degil, kosan kanit:
her satir `tests/run_gates.sh` icinde gercekten kosan bir kapiya baglidir.

## 1. Kapilar

| Kapi | Dosya | Ne dogrular |
|---|---|---|
| `wal_crash` | `tests/wal_crash/wal_crash_matrix.lpr` | WAL cerceve kurtarma matrisi (T1-T13) |
| `kv_wal` | `tests/wal_crash/kv_wal_matrix.lpr` | KV katmani WAL kurtarma matrisi (K1-K8) |
| `backup_restore` | `tests/backup_restore/backup_restore.lpr` | Yedek alma, dogrulama, geri yukleme tatbikati (B0-B24) |

## 2. WAL invariantlari (p4-wal-invariants)

Kod tarafinda ek is GEREKMEDI: invariantlar zaten uygulanmis ve kapilarla
sabitlenmisti. Bu fazdaki katki, kanitla belgeyi eslestirmektir.

`wal_crash` (T1-T13):

| No | Invariant |
|---|---|
| T1 | Commit edilmis cerceveler uygulanir, commit'siz kuyruk ATILIR |
| T2 | Kesik kayit (yarim baslik) -> TornTail; onceki commit uygulanir |
| T3 | CRC bozulmasi -> orada durur, sonrasi yok sayilir |
| T4 | Bozuk magic -> orada durur |
| T5 | Gecersiz PayloadLen -> orada durur |
| T6 | Kurtarma idempotent (iki `Recover` ayni sonucu verir) |
| T7 | Ayni sayfa icin son commit kazanir |
| T8 | Meta sayfa (0) EN SON uygulanir |
| T9 | fsync hatasi -> commit basarisiz + hayalet commit KALMAZ |
| T10 | Guvenli olmayan budama REDDEDILIR |
| T11 | Guvenli budama: govde silinir, `HasContent=False`, HeaderLsn korunur |
| T12 | Farkli veritabani kimligi ile Open -> `EVdbWal` |
| T13 | `CommitCount` dogru |

`kv_wal` (K1-K8): yazma/replay dayanikliligi, yeniden acilista kalicilik,
idempotent replay, kesik kayit, CRC bozulmasi, bozuk magic, DEL+deger
reddi, asiri boyutlu deger reddi.

Ek olarak `VDbMetricsText` (P-184/C-10) kurtarma sirasinda kesik kuyruk
gorulduyse `vdb_v3_wal_torn_tail 1` yayinlar; `VdbOpen` stderr'e acik uyari
yazar. Sessiz veri kaybi boylece gorunur hale gelir.

## 3. Yedek ve geri yukleme (p4-backup-restore)

### API

`IVdbBackend` (`VDbBackendApi.pas:226-239`):

- `Verify(out Report): Boolean` - canli dosyanin tam taranmasi (CRC +
  freelist + heap + tasma).
- `BackupTo(DestPath)` - commit + checkpoint + sayfa imajinin bayt kopyasi.
- `BackupIncrementalTo(BasePath, DestPath, out PagesCopied, out PagesTotal)`.
- `VerifyBackup(Path, out Report): Boolean` - depoyu ACMADAN baslik/meta CRC
  ve her sayfanin `PageVerify` denetimi (sifreli imajda zarf/CRC + anahtar
  dogrulayici).
- `RestoreFrom(SrcPath)` - kaynak imaji atomik olarak yerine koyar
  (`.restore.tmp` + `SwapDbFile`), eski dosyayi `.bak` birakir.

### Bu fazda kapatilan gercek acik

`RestoreFrom` daha once yalnizca **basligi** denetliyordu: magic, surum,
sifreleme bicimi ve anahtar dogrulayici. Sayfa butunlugu denetlenmiyordu;
yani bozuk bir yedek **sessizce** canli dosyanin uzerine yazilabiliyor,
veritabani bir sonraki acilista bozuk sayfalarla aciliyordu. Phase 4'un
"sessiz yanlis sonuc yasak" ilkesine aykiriydi.

Duzeltme (`VDbBackendV3.pas`, `RestoreFrom`): imaj, canli dosyaya
dokunulmadan once `VerifyBackupImage` ile tam taranir; bozuksa
`RESTORE: yedek bozuk: ...` ile reddedilir ve hedef dosya DEGISMEZ.

### Kapi matrisi (`backup_restore`, B0-B24)

| No | Kontrol |
|---|---|
| B0 | Kurulum: 3 satir yazildi |
| B1 | Yedek dosyasi olustu, boyut > 0 |
| B2 | `VerifyBackup` iyi yedegi kabul etti (rapor: sayfa, DbId, LSN) |
| B3 | Kaynak veritabani butun (`Verify`) |
| B4 | Yedek BAGIMSIZ veritabani olarak acilabiliyor, 3 satir |
| B5 | Tek bayt bozulmus yedek REDDEDILDI |
| B6 | Bozulma raporu aciklayici (`yedek bozuk: sayfa N: CRC tutmadi`) |
| B7 | Kesik (truncate) yedek REDDEDILDI (boyut uyusmazligi) |
| B8 | Olmayan kaynak -> restore reddi |
| B9 | Yabanci bicim (rastgele bayt) -> restore reddi |
| B10 | Asiri kisa kaynak -> restore reddi |
| B11 | Kaynak = hedef -> restore reddi |
| B12 | Reddedilen denemeler hedefi bozmadi |
| B13 | Gercek restore sonrasi 3 satir korundu |
| B14 | Restore sonrasi icerik dogru (`alpha`) |
| B15 | Restore edilen veritabani butun (`Verify`) |
| B16 | Restore edilen veritabani yazilabilir (4. satir) |
| B17 | Restore edilen veritabaninin yedegi de gecerli |
| B18 | Ikinci yedek 4 satir tasiyor |
| B19 | Artimli yedek: tabandan fark yoksa sayfa kopyalanmaz |
| B20 | Artimli yedek: degisen sayfa kopyalanir (`PagesCopied > 0`) |
| B21 | Artimli yedek kendi kendine yeterli (dogrulanir) |
| B22 | Artimli yedek 5 satir tasiyor |
| B23 | Bozuk yedekten restore REDDEDILDI |
| B24 | Reddedilen bozuk restore sonrasi hedef saglam |

## 4. Kapsam disi (bilerek, durust sinir)

- **Surec cokmesi ORTASINDA yedek alma** (backup sirasinda `kill -9`)
  kosulmaz; yedek dosyasi checkpoint sonrasi kopya oldugu icin yarim yedek
  senaryosu `VerifyBackup` ile reddedilir, ama bu kapida uretilmez.
- **PITR / log tabanli kurtarma** (v4 `EnsureLogBase` sonrasi) bu fazin
  konusu degil; `RESTORE` nesil kopmasi yarattigi icin onceki zamanlar
  reddedilir (kodda belirtilmis davranis).
- **Artimli yedek zinciri** (taban + N artimli) tek halka ile sinirli
  denenir; coklu halka birlesimi kosulmaz.
- **Sifreli yedekte yanlis anahtar reddi** kodda var (`KeyCheck`), bu
  kapida sifreli veritabani acilmadigi icin kosulmaz.
- **Sayfa/indeks tutarlilik denetimi** (p4-page-index) ayri bir kalemdir;
  bu belge yalnizca yedek/geri yukleme ve WAL invariantlarini kapsar.
- Yedek dosyasi **sikistirilmaz ve sifrelenmez** (mevcut format sayfa
  imajidir); depo disi tasima icin bu bir eksik olarak kaydedilir.

## 5. Yerel kanit

- Windows 11 / FPC 3.2.4 (i386-win32), Git Bash: `backup_restore`
  **25 PASS, 0 FAIL**; tam kapi seti yesil.
- WSL x86_64 Linux / FPC 3.2.2: tam kapi seti yesil (bkz. `CI.md`).

GitHub Actions kosusu depoya her push'ta ayni kapilari kosar; sonuc
`CI.md` "Bilinen sinirlar" bolumunde guncellenir.
