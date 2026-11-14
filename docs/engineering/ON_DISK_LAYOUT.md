# Disk üzerindeki yerleşim: "tek dosya" ne demek?

Bu belge, README'lerdeki **"tek dosya (`.odb`)"** ifadesinin ölçülmüş
karşılığını yazar. Amaç iddiayı büyütmek değil, sınırını netleştirmek.

## 1. Üç durum, üç farklı dizin içeriği

| Durum | Dizinde ne var |
|---|---|
| Açık (yazılabilir) | `.odb` + `.wal` + `.gen` |
| **Temiz kapanmış** | **yalnızca `.odb`** |
| Çökmüş / süreç öldürülmüş | `.odb` + dolu `.wal` (+ `.gen`) |

`.idx` açıkken oluşmaz: yalnızca kapanışta, `KeepIdxOnClose` açık ve
checkpoint başarılıysa yazılır. Açılışta varsa okunur (`TryLoadIdx`),
yoksa tam tarama yapılır.

"Tek dosya" ifadesi **temiz kapanmış** veritabanı için doğrudur: motorda
kapanış, yan dosyaları temizler. Çalışırken yan dosyalar vardır, çünkü
çökme kurtarma günlüğü ve süreçler arası kilit/sayacı orada tutulur.

### Ölçüm

`tests/single_file/single_file.lpr` kapısı (35 PASS / 0 FAIL) 200 satırlık
bir veritabanı kurar, kapatır ve dizini sayar:

```
SF3  veritabani.odb var
SF4  kapanıştan sonra artefakt sayısı = 1
SF5  .wal / .idx / .gen / .log hiçbiri yok
```

`perf_baseline` kapısının ürettiği 3000 satırlık veritabanında (süreç
kapandıktan sonra) `dir` çıktısı da tek satırdır: `veritabani.odb`
102.400 B. Önceki sürümde aynı dizinde 5 girdi görünüyordu
(`.odb`, `.odb.wal` 4.096 B, `.odb.idx` 30.099 B, `.odb.gen` 32.792 B,
`.odb.log/`); bu davranış v3.32'de kaldırıldı.

## 2. Açıkken var olan yan dosyalar ne işe yarar?

| Girdi | Ne işe yarar | Kapanışta |
|---|---|---|
| `<ad>.odb` | **asıl veri**: sayfalar, şema, satırlar | kalır |
| `<ad>.odb.wal` | çökme kurtarma günlüğü (commit başına yalnız değişen sayfalar) | **boşsa silinir** |
| `<ad>.odb.idx` | açılış hızlandırma önbelleği; yalnız `KeepIdxOnClose` açıksa yazılır | varsayılan: hiç oluşmaz |
| `<ad>.odb.gen` | süreçler arası değişiklik sayacı, durabil LSN, bayt aralık kilitleri | **silinir** |
| `<ad>.odb.log/` | değişim günlüğü segmentleri (PITR / replikasyon) | varsayılan **hiç oluşmaz** |

Üçü de **veri değildir**; hepsi yeniden üretilebilir:

- **WAL ayrı olmak zorunda.** Çökme güvenliği, veri sayfalarına dokunmadan
  önce değişikliğin dayanıklı bir günlüğe yazılmasını gerektirir. Aynı
  dosyaya yazmak, yarım kalan sayfa yazımını kurtarılamaz hale getirir.
  SQLite da WAL modunda ayrı `-wal` dosyası kullanır.
- **`.idx` bir önbellektir.** Silinmesi veri kaybı değildir; açılışta tam
  tarama yapılır. Kapı bunu ölçer: tek `.odb` kopyası açılır, tüm satırlar
  okunur.
- **`.gen` bir sayaçtır**, changelog değildir (bu ikisi önceden
  karıştırılıyordu). İçinde değişiklik sayacı, durabil LSN ve kilit
  kapsamı vardır. Kapanışta **tam kilit bizdeyken** silinir; sonraki açılış
  aynı kimlikle yeniden üretir ve durabil LSN sıfırdan başlar. Bunun
  maliyeti yalnızca fazladan bir fsync'dir, veri bozulması değil.
- **`.log/` + changelog tabanı artık opt-in.** v3 değişim günlüğü
  (PITR/replikasyon) varsayılan olarak **kapalıdır**; `ChangeLogEnabled`
  açılmadıkça ne `.log/` dizini ne de taban imajı oluşur.

## 3. Kapanış neden yan dosyaları silebiliyor?

`TVdbPageEngine.Close` şu sırayı uygular:

1. `AcquireDataWrite` — süreçler arası **tam kilit** alınır (başka okuyucu
   kalamaz, yani silme güvenli).
2. `Checkpoint(True)` — WAL'deki tüm commit'ler `.odb`'ye yazılır ve
   fsync edilir.
3. `FWal.Close` — WAL tutamacı **kilit altında** kapatılır (Windows açık
   tutamaçlı dosyayı silmez).
4. `DropSideFiles(True)` — `.idx` silinir, `.wal` **boşsa** silinir.

Checkpoint herhangi bir nedenle başarısız olursa (`closeOk = False`) yan
dosyalara **dokunulmaz**: WAL'deki commit'ler tek kurtarma kaynağıdır.

## 4. Çökme senaryosu: yan dosyalar kalır ve kurtarma onları kullanır

Süreç öldürülürse `.wal` dolu kalır. Sonraki açılışta motor WAL'i **önce**
uygular (`Recover`), sonra checkpoint eder. Bu yüzden çökmüş bir
veritabanında **yalnız `.odb` kopyalamak WAL'deki commit'leri kaybeder**.
Canlı yedek için `BACKUP TO` kullan:

```pascal
// Veritabanı açıkken tek dosyalık taşınabilir kopya
Be.BackupTo('yedek.odb');        // tek dosya; yan dosya üretmez
```

`yedek.odb` tek başına açılır (kapıda `SF17`–`SF20`).

## 5. Açılış maliyeti (dürüst taraf)

`.idx` kapanışta silindiği için bir sonraki açılış **tam tarama** yapar.
Bu bilinçli bir değiş tokuştur: dizinde tek dosya karşılığında açılışta
önek taraması. İstenirse davranış kapatılabilir:

| Özellik | Varsayılan | Etkisi |
|---|---|---|
| `KeepIdxOnClose` | `False` | `True`: `.idx` kapanışta kalır, açılış hızlanır, dizinde 2 dosya olur |
| `DropWalOnClose` | `True` | `False`: boş `.wal` kapanışta kalır (SQLite benzeri görünüm) |
| `DropGenOnClose` | `True` | `False`: `.gen` kalır (başka süreçlerle paylaşımlı açılış paterni için) |
| `ChangeLogEnabled` | `False` | `True`: `.log/` + taban imajı oluşur (PITR / replikasyon) |

Yani tek dosya varsayılan, yan dosyalar **opt-in**.

## 6. `BACKUP TO` ve tek dosya

`BACKUP TO` her zaman tek dosya üretir ve ürettiği dosya tek başına açılır
(kapıda `SF17`–`SF19`: 200 satır doğru okunur). Klasör kopyalarken
veritabanı **kapalıysa** yalnız `.odb` yeterlidir; açıkken `BACKUP TO`
kullan.

## 7. Kapsam dışı

- Şifreli veritabanlarında yan dosya yerleşimi bu kapıda denenmez
  (`crypto_*` kapıları ayrı). Not: şifreli modda `.wal` de şifrelenir.
- Ağ/sunucu modunda (`VDbSqlServer`, `VDbPgWire`) dosyalar sunucu
  tarafındadır; istemci hiçbir yan dosya görmez.
- Disk dolması / kısmi yazma senaryoları `page_integrity` ve
  `wal_crash` kapılarındadır.
- Eşzamanlı çok süreçli açılışta `.gen` silme yarışı: kapanış tam kilit
  altında yapıldığı için yarış yok; ancak bir süreç kapanırken diğeri
  açmaya çalışırsa ikincisi kilit bekler (bu davranış `wal_crash` ve
  `page_integrity` kapılarında dolaylı olarak kapsanır).
