# 04 — Veritabanı Dosyaları (`db\`)

> Kaynak: `D:\veritabani\db\` dizin listelemesi, 04.10.2026.
> **Tazeleme: 06.10.2026** — liste yeniden alındı; binary içerik yine açılmadı.

| Dosya | Boyut | Son yazma | Durum |
|---|---|---|---|
| `mtakip.odb` | 7096901 byte (~6,77 MB) | 04.10.2026 21:50 | En büyük dosya; üretim/test ayrımı dosya yöneticisinden doğrulanmalı |
| `veritabani.odb` | 388880 byte (~380 KB) | 05.10.2026 22:50 | Ana çalışma dosyası (`VODB v2` başlığı doğrulanmış). 05.10 22:50 değişimi `cdc_test`'in bu dosyaya yazmasından kaynaklandı (artık geçici klasöre yazar; olay `DENETIM_VE_YOL_HARITASI.md` → *Faz 4* kaydında) |
| `veritabani.odb.onceki` | 381255 byte (~372 KB) | 05.10.2026 22:57 | Kullanıcının bıraktığı önceki sürüm kopyası (geri yükleme/karşılaştırma için); **dokunulmaz** |
| `satis.odb` | 135 byte | 01.10.2026 15:31 | Neredeyse boş test dosyası |
| `satis.odb.bak` | 551 byte | 01.10.2026 15:30 | `satis.odb` yedeği |

`.key` ve `.wal` dosyası **yok** (şifreleme anahtarı kurulu değil, WAL
geçmişi açık değil).

## Notlar

- Biçim: `v2` (`VODB` magic + sürüm + bayrak + başlık CRC, ardından append-only kayıtlar). Ayrıntı: `02-DOSYA-FORMATI.md`.
- Başlık kontrolü (`Magic=VODB`, `Ver=2`) `Verify`/`sqltest` çıktısıyla yapılabilir; bu belge salt dizin listesidir.
- `ESKI\db\` ve `mtakip\data\` altında başka `.odb` kopyaları olabilir; envanter dışı bırakıldı (bu belge yalnız `db\` kökünü kapsar).
- Yedekleme: `BACKUP` / `EXPORT JSON` kullanılır; `Compact` `.bak` bırakır.
- **Test dosyası dokunulmazlığı:** paylaşılan `db\` altındaki dosyalar
  üzerinde yalnız kullanıcı çalışır; otomatik testler (`sqltest`,
  `cdc_test`, `vdbapitest`, `vdbclienttest`, `vdbcrypttest`) kendi
  geçici klasörlerini yaratır.
