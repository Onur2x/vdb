# 02 — `.odb` / `.wal` Dosya Formatı

> Kaynak: `VDbCore.pas` sabit/kayıt tanımları + `db\` altındaki dosyaların ad/boyut listelemesi.
> Binary içerik açılmadı; ofset tablosu kod tanımlarından alıntıdır.
> **Tazeleme: 06.10.2026** — başlık `Flags` düzeltmesi, `ENCRYPTED` kayıt
> bayrağı, şifreleme biçimi ve gerçek `.wal` biçimi eklendi (eski metinde
> `.wal` "iskelet" olarak geçiyordu).

## Dosya kimliği (16 byte başlık — `TVDbFileHead`)

| Ofset | Boyut | Alan | Değer |
|---|---|---|---|
| 0 | 4 | `Magic` | `$42444F56` (`'VODB'`, little-endian) |
| 4 | 4 | `Ver` | `2` (`VDB_FILE_VER`; eski `1` = `VDB_FILE_VER_OLD`) |
| 8 | 4 | `Flags` | `0` (varsayılan). Tanımlı bit: **`VDB_HFLAG_HAS_ENCRYPTED = 1`** — dosyada en az bir şifreli kayıt var (ilk şifreli yazışta set edilir). Eski belgede yazan `ENCRYPTED=4 / COMPRESSED=8` **kayıt** bayraklarıdır, başlık bayrağı değildir. |
| 12 | 4 | `Crc` | İlk 12 byte'ın CRC32'si |

`VDB_HDR_SIZE = 16`. Kayıtlar hep başlıktan sonra başlar; ham kayıt akışıyla karışmaz.

## Kayıt formatı (`TVDbRecHead`, packed, little-endian)

| Alan | Boyut | Açıklama |
|---|---|---|
| `Magic` | u32 | `$56444231` |
| `Crc` | u32 | `CRC32(seq + key + vallen + flags + value)` |
| `Seq` | u64 | Sıra numarası |
| `Key` | u64 | Anahtar (`UInt64`; tablo satırı için `FNV1a64(lower(table)+#0+pk)`, şema için ayrılmış `0`) |
| `ValLen` | u32 | Değer uzunluğu (`VDB_MAX_VALUE = 16 MB` üst sınır) |
| `Flags` | u8 | `0=PUT`, `1=DEL`, `2=BATCHEND`, **`4=ENCRYPTED`** (PUT ile *birlikte* bit; DEL kaydında geçersizdir — tombstone iceriksizdir). `8=COMPRESSED` tanımlı, kullanılmıyor. |
| `Value` | `ValLen` byte | Ham değer baytları (şifreliyse aşağıdaki biçimde) |

## Kayıt seviyesi şifreleme (Faz D, `VDbCrypt.pas`)

- **Bişim:** `kayit = IV(16) || duzUzunluk(4, LE) || AES-256-CTR(duz) || Tag(32)`,
  `Tag = HMAC-SHA256(K_mac, IV || len || sifreli)` → **encrypt-then-MAC**;
  cozmede once etiket dogrulanir, bozuk kayit asla cozulmez.
- **Anahtar turetimi:** `K_enc = HMAC(master,"VDB-ENC-v1")`,
  `K_mac = HMAC(master,"VDB-MAC-v1")`; parola modunda anahtar
  **PBKDF2-SHA256, 200.000 iterasyon** ile turetilir.
- **`.key` dosyasi (58 bayt, DOSYADA SIR YOK):**
  `'VDBK'(4) | surum(1) | tuzUz(1) | iterasyon(4, LE) | tuz(16) | dogrulayici(32)`.
- **Mixed mode:** sifreleme acikken yazilanlar sifreli, kapaliyken yazilanlar
  duz metin; `Get`/`ScanAll` kaydin KENDI bayragina bakar. `Compact`/`BackupTo`
  bayragi sabitlemez. Basliktaki `HAS_ENCRYPTED` biti "dosyada sifreli kayit
  var" bilgisini tasir (anahtarsiz acan taraf gorsun diye).
- WAL **bilerek duz metin** yazar (tehdit modeli belgeli) — bu yuzden
  `VDbCdc` anahtarsiz calisir.

## Dayanıklılık modeli (Bitcask tarzı çekirdek + opsiyonel WAL)

1. **Append-only:** Yazma hep sona eklenir; yerinde güncelleme yok.
2. **Kayıt başı CRC32:** Bozuk kayıt açılışta tespit edilir, yırtık kuyruk budanır (`Verify` raporlar, dosyayı değiştirmez).
3. **Batch atomikliği:** `COMMIT` tek `fsync` + `BATCHEND` işaretiyle kapanır — ya hep ya hiç; recovery commit'siz kuyruğu geri sarar.
4. **Commit-flush:** Başarılı her `Exec` sonrası kirli bayrak kontrol edilip `Flush` çağrılır (`SyncWrite=False` olsa bile SQL katmanında commit dayanıklıdır).
5. **Kilit:** Aynı `.odb` aynı anda tek işlem tarafından açılır (dosya kilidi); ikinci açış hata koduyla reddedilir.
6. **Bakım:** `Compact` ölü sürümleri temizler (`.bak` bırakır); yedek için `BACKUP` / `EXPORT JSON` kullanılır.

## `.wal` (gerçek biçim — 2026-10-05 itibarıyla)

`<veritabaninin adi>.wal`, `TVDbWalHead` (packed, **21 bayt**) + `Value`:

| Alan | Boyut | Açıklama |
|---|---|---|
| `Magic` | u32 | `VDB_WAL_MAGIC = $57414C52` (`'WALR'`) |
| `Key` | u64 | Anahtar (aynı `FNV1a64`) |
| `Flags` | u8 | **Düz bayrak:** `0=PUT`, `1=DEL` (BATCHEND/Seq **yok**) |
| `ValLen` | u32 | Değer uzunluğu |
| `Crc` | u32 | `RecCrc(0, Key, ValLen, Flags, Value)` |
| `Value` | `ValLen` byte | Satır kodlaması (sema kaydı `VSCH1...` olabilir) |

- **Yazma sırası:** `.wal` (`fsync`) → ana dosya. WAL yazılırsa ana dosya
  yazılmaz; WAL yazılamazsa **işlem hata döner**.
- **Otomatik mod:** `WALEnabled = True` iken her kalıcı yazma (ve
  `CommitBatch` toplu yazımı) önce `.wal`'a girer. `Close` bu bayrağı sıfırlar.
- **Doğrulama:** her kaydın kendi magic + CRC'si var; `ReplayWAL`,
  `WalRecordCount`, `ReadWalEntry` **aynı** kuralları uygular (anlamsız
  bayrak, DEL'de değer taşması, taşan uzunluk, yarım değer, CRC) ve
  bozuk/yırtık kuyruğu **orada keser**.
- **Okuyucular:** `VDbCdc` (olay yakalama) ve `VDbTimeTravel` (önceki değer)
  `TVDb.ReadWalEntry` üzerinden okur; başlık `VDbCore` interface'indedir.
- **Sınır:** `CheckpointWAL`/`ReplayWAL` dosyayı uygulayıp siler → geçmiş
  yalnızca **son checkpoint'ten sonraki** yazılardır.
- `VDbWal.pas` (harici iskelet `WAL_FILE_MAGIC/VER`) **hiçbir proje
  tarafından kullanılmıyor**; fiilî WAL yukarıdadır.

## Sürüm notu

- `v1 -> v2` geçişinde `BATCHEND` (`flags=2`) eklendi. `v1` dosyaları açılışta `v2`'ye yükseltilir (`DetectFormat`/`MigrateLegacy`). Eski sürümlü build `v2` bayrağını "bozuk kayıt" sanıp kırpmaz — dosyayı **açamaz** (temiz hata), veri silinmez.
