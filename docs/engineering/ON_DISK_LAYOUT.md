# Disk üzerindeki yerleşim: "tek dosya" ne demek?

Bu belge, README'lerdeki **"tek dosya (`.odb`)"** ifadesinin ölçülmüş
karşılığını yazar. Amaç iddiayı büyütmek değil, sınırını netleştirmek.

## 1. Ölçülen gerçek (3000 satırlık veritabanı)

`build/pb/tmp/pb_sql` dizini, `perf_baseline` kapısının ürettiği
veritabanıdır (süreç kapandıktan sonra `dir` çıktısı):

| Girdi | Boyut | Tip | Ne işe yarar |
|---|---|---|---|
| `veritabani.odb` | 102.400 B | dosya | **asıl veri**: sayfalar, şema, satırlar |
| `veritabani.odb.wal` | 4.096 B | dosya | çökme kurtarma günlüğü; checkpoint'te başlığı yeniden yazılır, **silinmez** |
| `veritabani.odb.idx` | 30.099 B | dosya | açılış hızlandırma önbelleği; yoksa tam tarama |
| `veritabani.odb.gen` | 32.792 B | dosya | değişim günlüğü taban imajı (PITR) |
| `veritabani.odb.log` | — | **dizin** | değişim günlüğü segmentleri (PITR / replikasyon) |

Yani çalışan bir veritabanı **tek dosya değil, beş girdidir**. README'deki
"tek dosya" ifadesi bu haliyle yanıltıcıdır ve düzeltilmiştir.

## 2. Ama "veri tek dosyada" iddiası doğru

`tests/single_file/single_file.lpr` kapısı şunu ölçer
(**22 PASS / 0 FAIL**):

| Kontrol | Ne kanıtlar |
|---|---|
| `SF1`–`SF4` | kaynak veritabanı kurulur; çalışırken 5 artefakt oluşur (rapor) |
| `SF5`–`SF7` | yalnız `veritabani.odb` başka bir boş dizine kopyalanır; dizinde **tek** dosya kalır |
| `SF8` | o tek dosya açılır, `COUNT(*) = 200`, satır içeriği birebir aynı |
| `SF9`–`SF10` | o tek dosyaya **yazılabilir** (210 satır), yeniden açılışta doğrulanır |
| `SF11`–`SF13` | `BACKUP TO` çıktısı tek dosyadır ve tek başına açılır (200 satır) |

Kritik nokta `SF9`: yalnız `.odb` varken motor eksik yan dosyaları
**kendisi yeniden üretir** (`.wal`, `.idx`, `.gen`, `.log/`). Yani yan
dosyalar veri değil, **çalışma durumu**dur.

## 3. Neden yan dosyalar ayrı?

- **WAL ayrı olmak zorunda.** Çökme güvenliği, veri sayfalarına dokunmadan
  önce değişikliğin dayanıklı bir günlüğe yazılmasını gerektirir. Aynı
  dosyaya yazmak, yarım kalan sayfa yazımını kurtarılamaz hale getirir.
  SQLite da WAL modunda ayrı `-wal` dosyası kullanır; "tek dosya" yalnız
  rollback-journal modunda ve o modda eşzamanlı okuma kısıtlıdır.
- **`.idx` bir önbellektir.** Silinmesi veri kaybı değildir; açılışta tam
  tarama yapılır (`VDbPageEngine` `.idx` tazeyse taramayı atlar).
- **`.gen` + `.log/` PITR içindir.** v3 değişim günlüğü kalıcıdır
  (`ARCHIVE WAL RESET` v3'te desteklenmez); bu yüzden v3'te bu ikisi
  kapatılamaz. Yalnızca veri taşımak istiyorsan `BACKUP TO` kullan.

## 4. Pratik sonuç: taşınabilir tek dosya

```pascal
// Veritabanı açıkken tek dosyalık taşınabilir kopya
Be.BackupTo('yedek.odb');        // tek dosya; yan dosya üretmez
```

`yedek.odb` tek başına açılır (`SF11`–`SF13`). Klasör kopyalarken ise
**tüm artefaktları** birlikte kopyala; yalnız `.odb` kopyalarsan son
commit'ler WAL'de kaldığı için kaybolur (kapı bunu `SF8` ile tam tersi
yönde — yani "commit edilmiş ve checkpoint edilmiş veri tek dosyada" —
gösterir).

> Dürüst uyarı: `SF8` senaryosu veritabanı **temiz kapandıktan** sonra
> kopyalanır. Açık/çökmüş bir veritabanında yalnız `.odb` kopyalamak
> WAL'deki commit'leri kaybeder. Canlı yedek için `BACKUP TO` kullan.

## 5. Neden "gerçek tek dosya" (yan dosyaları `.odb` içine gömme) yapılmadı

Bu bir format değişikliğidir (v4) ve çökme güvenliği açısından risklidir:
WAL'i ana dosyanın içine koymak, sayfa yazımı ile günlük yazımını aynı
dosyada yarıştırır. Mevcut sözleşme (ayrı WAL + `BACKUP TO` ile tek
dosyalık taşınabilir kopya) hem güvenli hem de SQLite'ın WAL moduyla
aynı davranıştır. Karar kaydı: bu kalem **belge + kapı** olarak
kapatıldı; format değişikliği ayrı bir iş kalemidir.

## 6. Kapsam dışı

- Şifreli veritabanlarında yan dosya yerleşimi bu kapıda denenmez
  (`crypto_*` kapıları ayrı).
- Ağ/sunucu modunda (`VDbSqlServer`, `VDbPgWire`) dosyalar sunucu
  tarafındadır; istemci hiçbir yan dosya görmez.
- Disk dolması / kısmi yazma senaryoları `page_integrity` ve
  `wal_crash` kapılarındadır.
